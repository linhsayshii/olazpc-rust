//! `CoreMedia`: the media / download network + disk-cache layer (Swift `MediaLoader` /
//! `DownloadManager` network half) over `olaz-media`.
//!
//! # Cancellation
//!
//! UniFFI's Swift bindings do NOT cancel a Rust future when the awaiting Swift `Task` is
//! cancelled: `uniffiRustCallAsync` only frees the future after it resolved. Every async export
//! therefore takes a [`MediaCancel`]; Swift wraps the call in `withTaskCancellationHandler` and
//! calls `cancel()` from `onCancel`. A cancelled call resolves with `MediaCoreError.cancelled`
//! immediately, and the work future is dropped, which aborts the transfer (the flight table aborts
//! a download when its last waiter leaves) and deletes its temporary files.
//!
//! Errors never carry URLs, headers or paths (ADR-008).

use std::collections::HashMap;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use olaz_media::{
    Algorithm, DataRequest, DownloadRequest, DownloadSource, FileRequest, HeadersRequest,
    MediaConfig, MediaCore, MediaError, MediaHooks, MediaOptions, NetKind, ProgressFn,
    ResolveError, SecureChoice, SecureSpec,
};
use tokio::sync::watch;

use crate::runtime::{blocking, runtime};

/// Class of a transport failure (Swift `URLError` codes the callers branch on).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MediaNetKind {
    CannotFindHost,
    TimedOut,
    NotConnected,
    ConnectionLost,
    CannotConnect,
    SecureFailed,
    Other,
}

/// Error of every `CoreMedia` export; one case per Swift error the callers already handle.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum MediaCoreError {
    #[error("bad url")]
    BadUrl,
    #[error("http {status}")]
    Http { status: u16 },
    #[error("undecodable")]
    Undecodable,
    #[error("timed out")]
    TimedOut,
    #[error("too large")]
    TooLarge,
    #[error("host not found")]
    HostNotFound,
    #[error("cancelled")]
    Cancelled,
    /// DoH answered NXDOMAIN (Swift `DoHResolver.ResolveError.notFound`).
    #[error("doh: not found")]
    DohNotFound,
    /// Every DoH endpoint failed (Swift `ResolveError.allEndpointsFailed`).
    #[error("doh: all endpoints failed")]
    DohAllFailed,
    #[error("network: {kind:?}")]
    Net { kind: MediaNetKind },
    #[error("io: {message}")]
    Io { message: String },
}

impl From<MediaError> for MediaCoreError {
    fn from(e: MediaError) -> Self {
        match e {
            MediaError::BadUrl => Self::BadUrl,
            MediaError::Http(status) => Self::Http { status },
            MediaError::Undecodable => Self::Undecodable,
            MediaError::TimedOut => Self::TimedOut,
            MediaError::TooLarge => Self::TooLarge,
            MediaError::HostNotFound => Self::HostNotFound,
            MediaError::Cancelled => Self::Cancelled,
            MediaError::Resolve(ResolveError::NotFound) => Self::DohNotFound,
            MediaError::Resolve(ResolveError::AllEndpointsFailed) => Self::DohAllFailed,
            MediaError::Net(kind) => Self::Net {
                kind: match kind {
                    NetKind::CannotFindHost => MediaNetKind::CannotFindHost,
                    NetKind::TimedOut => MediaNetKind::TimedOut,
                    NetKind::NotConnected => MediaNetKind::NotConnected,
                    NetKind::ConnectionLost => MediaNetKind::ConnectionLost,
                    NetKind::CannotConnect => MediaNetKind::CannotConnect,
                    NetKind::SecureFailed => MediaNetKind::SecureFailed,
                    NetKind::Other => MediaNetKind::Other,
                },
            },
            MediaError::Io(message) => Self::Io { message },
        }
    }
}

/// Cipher algorithm of a [`MediaSecureRecord`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MediaCipher {
    Aes256Ctr,
    Aes256Gcm,
}

/// A parsed, usable stream cipher (Swift `SecureStream`).
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct MediaSecureRecord {
    pub cipher: MediaCipher,
    pub key: Vec<u8>,
    pub iv: Vec<u8>,
    pub tag: Option<Vec<u8>>,
    pub block: bool,
    pub block_size: u64,
}

impl std::fmt::Debug for MediaSecureRecord {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MediaSecureRecord").finish_non_exhaustive()
    }
}

impl From<MediaSecureRecord> for SecureSpec {
    fn from(r: MediaSecureRecord) -> Self {
        Self {
            algorithm: match r.cipher {
                MediaCipher::Aes256Ctr => Algorithm::Ctr,
                MediaCipher::Aes256Gcm => Algorithm::Gcm,
            },
            key: r.key,
            iv: r.iv,
            tag: r.tag,
            block: r.block,
            block_size: usize::try_from(r.block_size).unwrap_or(4096),
        }
    }
}

/// What a request asked for (Swift `SecureStream.Parsed`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum MediaSecureChoice {
    None,
    Stream { spec: MediaSecureRecord },
    Invalid,
}

impl From<MediaSecureChoice> for SecureChoice {
    fn from(c: MediaSecureChoice) -> Self {
        match c {
            MediaSecureChoice::None => Self::None,
            MediaSecureChoice::Stream { spec } => Self::Stream(spec.into()),
            MediaSecureChoice::Invalid => Self::Invalid,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct MediaDataRequest {
    /// Clean network URL (Swift `ZaloMediaURL.networkURL`).
    pub url: String,
    /// `/jpg/` fallback of a `.jxl` URL.
    pub fallback_url: Option<String>,
    pub secure: Option<MediaSecureRecord>,
    /// Original URL, single-flight key of encrypted bodies.
    pub key_seed: String,
    pub deadline_secs: f64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MediaFileRequest {
    pub url: String,
    pub fallback_url: Option<String>,
    /// Cache file name: `media_cached_file_name(seed, ext)`.
    pub file_name: String,
    pub secure: Option<MediaSecureRecord>,
    /// Origin URL handed to the publish hook (quarantine).
    pub origin_url: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct MediaHeadersRequest {
    pub url: String,
    pub headers: HashMap<String, String>,
    pub max_bytes: u64,
    pub ttfb_secs: Option<f64>,
    /// Directory for the temporary result file.
    pub temp_dir: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum MediaDownloadSource {
    /// In-memory photo bytes (`data`), written straight into staging.
    Photo { request: MediaDataRequest },
    /// The shared files cache (`local_file`); the cache file is copied, never moved.
    Cached { request: MediaFileRequest },
    /// Caller headers (`download_with_headers`); the temporary file is moved into staging.
    Headers { request: MediaHeadersRequest },
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct MediaDownloadRequest {
    pub source: MediaDownloadSource,
    pub secure: MediaSecureChoice,
    pub temp_dir: String,
}

/// The failure the official client would report (Swift `DownloadManager.Failure`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MediaFailureRecord {
    pub name: String,
    pub code: i64,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MediaDownloadOutcome {
    /// Decrypted file in `temp_dir`, ready to quarantine and commit. `None` on failure.
    pub staged_path: Option<String>,
    pub failure: Option<MediaFailureRecord>,
}

/// Tunables of a [`CoreMedia`]. Production passes the defaults (`allow_plain_http: false`, no
/// DoH override); tests point it at local servers.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct MediaCoreOptions {
    #[uniffi(default = [])]
    pub preferred_languages: Vec<String>,
    pub files_dir: String,
    pub files_cache_limit: u64,
    pub max_concurrent: u32,
    pub allow_plain_http: bool,
    pub doh_endpoints: Option<Vec<String>>,
    /// Allowed gap between file bytes (production: 30 s).
    pub file_idle_secs: f64,
    /// Allowed gap between image bytes (production: 10 s).
    pub image_idle_secs: f64,
}

/// Progress receiver (0...1), implemented in Swift. Called from tokio's blocking pool, in order,
/// throttled to ~0.5% steps. Return quickly.
#[uniffi::export(with_foreign)]
pub trait MediaProgress: Send + Sync {
    fn on_progress(&self, fraction: f64);
}

/// Called with a finished temporary file just before it gets its final name (Swift applies the
/// `com.apple.quarantine` attribute). Runs on tokio's blocking pool.
#[uniffi::export(with_foreign)]
pub trait MediaPublishHook: Send + Sync {
    fn before_publish(&self, path: String, origin_url: String);
}

struct HookAdapter(Arc<dyn MediaPublishHook>);

impl MediaHooks for HookAdapter {
    fn before_publish(&self, path: &Path, origin_url: &str) {
        self.0
            .before_publish(path.to_string_lossy().into_owned(), origin_url.to_owned());
    }
}

/// Cancels the calls it was passed to. Create one per call, `cancel()` it from the Swift task's
/// `onCancel`. Cancelling a finished call is harmless.
#[derive(uniffi::Object)]
pub struct MediaCancel {
    tx: watch::Sender<bool>,
}

#[uniffi::export]
impl MediaCancel {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            tx: watch::channel(false).0,
        })
    }

    pub fn cancel(&self) {
        self.tx.send_replace(true); // stores the flag even before the call subscribed
    }
}

impl MediaCancel {
    async fn cancelled(&self) {
        let mut rx = self.tx.subscribe();
        let _ = rx.wait_for(|c| *c).await;
    }
}

/// Aborts the spawned task when the awaiting future is dropped.
struct AbortOnDrop(tokio::task::AbortHandle);
impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// Runs `work` on the runtime (reqwest / timers need a tokio context), racing it with `cancel`.
async fn run_cancellable<T, F>(cancel: Arc<MediaCancel>, work: F) -> Result<T, MediaCoreError>
where
    T: Send + 'static,
    F: Future<Output = Result<T, MediaCoreError>> + Send + 'static,
{
    let rt = runtime().map_err(|e| MediaCoreError::Io {
        message: e.to_string(),
    })?;
    let handle = rt.spawn(async move {
        tokio::select! {
            result = work => result,
            () = cancel.cancelled() => Err(MediaCoreError::Cancelled),
        }
    });
    let _guard = AbortOnDrop(handle.abort_handle());
    handle.await.unwrap_or(Err(MediaCoreError::Cancelled))
}

/// Delivers progress to the Swift receiver in order on the blocking pool, never on a runtime
/// worker (the callback may be slow).
fn forward_progress(callback: Option<Arc<dyn MediaProgress>>) -> Option<ProgressFn> {
    let callback = callback?;
    let (tx, rx) = std::sync::mpsc::channel::<f64>();
    drop(runtime().ok()?.spawn_blocking(move || {
        while let Ok(fraction) = rx.recv() {
            callback.on_progress(fraction);
        }
    }));
    let tx = std::sync::Mutex::new(tx);
    Some(Arc::new(move |fraction: f64| {
        if let Ok(tx) = tx.lock() {
            let _ = tx.send(fraction);
        }
    }))
}

fn secs(value: f64) -> Duration {
    Duration::from_secs_f64(value.clamp(0.0, 86_400.0 * 7.0))
}

fn data_request(r: MediaDataRequest) -> DataRequest {
    DataRequest {
        url: r.url,
        fallback_url: r.fallback_url,
        secure: r.secure.map(Into::into),
        key_seed: r.key_seed,
        deadline: secs(r.deadline_secs),
    }
}

fn file_request(r: MediaFileRequest) -> FileRequest {
    FileRequest {
        url: r.url,
        fallback_url: r.fallback_url,
        file_name: r.file_name,
        secure: r.secure.map(Into::into),
        origin_url: r.origin_url,
    }
}

fn headers_request(r: MediaHeadersRequest) -> HeadersRequest {
    let mut headers: Vec<(String, String)> = r.headers.into_iter().collect();
    headers.sort(); // HashMap order is arbitrary (ADR-009); keep the wire order deterministic
    HeadersRequest {
        url: r.url,
        headers,
        max_bytes: r.max_bytes,
        ttfb: r.ttfb_secs.filter(|s| *s > 0.0).map(secs),
        temp_dir: PathBuf::from(r.temp_dir),
    }
}

/// The media / download engine of one `MediaLoader`.
#[derive(uniffi::Object)]
pub struct CoreMedia {
    core: Arc<MediaCore>,
}

#[uniffi::export]
impl CoreMedia {
    #[uniffi::constructor]
    pub fn new(options: MediaCoreOptions, hook: Option<Arc<dyn MediaPublishHook>>) -> Arc<Self> {
        let mut cfg = MediaConfig {
            allow_plain_http: options.allow_plain_http,
            preferred_languages: options.preferred_languages,
            ..MediaConfig::default()
        };
        if let Some(endpoints) = options.doh_endpoints {
            cfg.doh_endpoints = endpoints;
        }
        let mut opts = MediaOptions::new(PathBuf::from(options.files_dir));
        opts.files_cache_limit = options.files_cache_limit;
        opts.max_concurrent = usize::try_from(options.max_concurrent).unwrap_or(6);
        opts.file_idle = secs(options.file_idle_secs);
        opts.image_idle = secs(options.image_idle_secs);
        let hooks = hook.map(|h| Arc::new(HookAdapter(h)) as Arc<dyn MediaHooks>);
        Arc::new(Self {
            core: MediaCore::new(cfg, opts, hooks),
        })
    }

    /// Image bytes (de-duplicated, concurrency-capped, with an overall deadline).
    pub async fn data(
        &self,
        request: MediaDataRequest,
        cancel: Arc<MediaCancel>,
    ) -> Result<Vec<u8>, MediaCoreError> {
        let core = Arc::clone(&self.core);
        let bytes = run_cancellable(cancel, async move {
            core.data(data_request(request))
                .await
                .map_err(MediaCoreError::from)
        })
        .await?;
        Ok(Arc::try_unwrap(bytes).unwrap_or_else(|shared| (*shared).clone()))
    }

    /// Downloads into the files cache (reused when present) and returns the path.
    pub async fn local_file(
        &self,
        request: MediaFileRequest,
        progress: Option<Arc<dyn MediaProgress>>,
        cancel: Arc<MediaCancel>,
    ) -> Result<String, MediaCoreError> {
        let core = Arc::clone(&self.core);
        let progress = forward_progress(progress);
        let path = run_cancellable(cancel, async move {
            core.local_file(file_request(request), progress)
                .await
                .map_err(MediaCoreError::from)
        })
        .await?;
        Ok(path.to_string_lossy().into_owned())
    }

    /// GET with caller headers into a temporary file in `request.temp_dir`.
    pub async fn download_with_headers(
        &self,
        request: MediaHeadersRequest,
        progress: Option<Arc<dyn MediaProgress>>,
        cancel: Arc<MediaCancel>,
    ) -> Result<String, MediaCoreError> {
        let core = Arc::clone(&self.core);
        let progress = forward_progress(progress);
        let path = run_cancellable(cancel, async move {
            core.download_with_headers(headers_request(request), progress)
                .await
                .map_err(MediaCoreError::from)
        })
        .await?;
        Ok(path.to_string_lossy().into_owned())
    }

    /// Fetch, decrypt and stage a download. Never throws: failures come back as the official
    /// client's error record (`MediaFailureRecord`).
    pub async fn download_to(
        &self,
        request: MediaDownloadRequest,
        progress: Option<Arc<dyn MediaProgress>>,
        cancel: Arc<MediaCancel>,
    ) -> MediaDownloadOutcome {
        let core = Arc::clone(&self.core);
        let progress = forward_progress(progress);
        let temp_dir = PathBuf::from(&request.temp_dir);
        let source = match request.source {
            MediaDownloadSource::Photo { request } => DownloadSource::Photo(data_request(request)),
            MediaDownloadSource::Cached { request } => {
                DownloadSource::Cached(file_request(request))
            }
            MediaDownloadSource::Headers { request } => {
                DownloadSource::Headers(headers_request(request))
            }
        };
        let req = DownloadRequest {
            source,
            secure: request.secure.into(),
            temp_dir,
        };
        let result = run_cancellable(
            cancel,
            async move { Ok(core.download_to(req, progress).await) },
        )
        .await;
        match result {
            Ok(outcome) => MediaDownloadOutcome {
                staged_path: outcome.staged.map(|p| p.to_string_lossy().into_owned()),
                failure: outcome.failure.map(|f| MediaFailureRecord {
                    name: f.name,
                    code: f.code,
                    message: f.message,
                }),
            },
            Err(_) => {
                let f = olaz_media::Failure::aborted();
                MediaDownloadOutcome {
                    staged_path: None,
                    failure: Some(MediaFailureRecord {
                        name: f.name,
                        code: f.code,
                        message: f.message,
                    }),
                }
            }
        }
    }

    /// Removes the cached file `file_name` (an explicit retry must download again).
    pub fn evict(&self, file_name: String) {
        self.core.evict(&file_name);
    }

    /// Has this host been switched to the DoH path?
    pub fn uses_doh(&self, host: String) -> bool {
        self.core.uses_doh(&host)
    }
}

/// FNV-1a 64-bit, hex (`MediaLoader.stableHash`).
#[uniffi::export]
#[must_use]
pub fn media_stable_hash(text: String) -> String {
    olaz_media::stable_hash(&text)
}

/// `<hash(seed)>.<ext>` cache file name (`MediaLoader.cachedFileLocation`).
#[uniffi::export]
#[must_use]
pub fn media_cached_file_name(seed: String, ext: String) -> String {
    olaz_media::cached_file_name(&seed, &ext)
}

/// Zalo CDN host test (`MediaLoader.isZaloCDN`).
#[uniffi::export]
#[must_use]
pub fn media_is_zalo_cdn(host: String) -> bool {
    olaz_media::is_zalo_cdn(&host)
}

/// One-shot stream decryption (`SecureStream.decrypt`) on the blocking pool; `None` when the
/// cipher or tag is bad.
#[uniffi::export]
pub async fn media_secure_decrypt(
    spec: MediaSecureRecord,
    data: Vec<u8>,
) -> Result<Option<Vec<u8>>, crate::CoreError> {
    let spec: SecureSpec = spec.into();
    blocking(move || spec.decrypt(&data).ok()).await
}

/// Linear AES-256-GCM file encryption (`SecureStream.encryptE2EEFile`) with caller-provided random
/// `key` (32) and `iv` (12): returns `(ciphertext, 60-byte session token)`.
#[uniffi::export]
pub fn media_encrypt_e2ee_file(
    plaintext: Vec<u8>,
    key: Vec<u8>,
    iv: Vec<u8>,
) -> Result<MediaEncrypted, crate::CoreError> {
    let bad = || crate::CoreError::Crypto {
        message: "invalid key or iv length".to_owned(),
    };
    let key: [u8; 32] = key.try_into().map_err(|_| bad())?;
    let iv: [u8; 12] = iv.try_into().map_err(|_| bad())?;
    let (ciphertext, token) =
        olaz_media::encrypt_e2ee_file(&plaintext, &key, &iv).map_err(|e| {
            crate::CoreError::Crypto {
                message: e.to_string(),
            }
        })?;
    Ok(MediaEncrypted { ciphertext, token })
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MediaEncrypted {
    pub ciphertext: Vec<u8>,
    pub token: Vec<u8>,
}
