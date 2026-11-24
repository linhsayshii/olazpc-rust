//! [`MediaCore`]: image bytes, the files cache, header downloads and staged downloads (Swift
//! `MediaLoader` network + disk half, `DownloadManager.execute/finalize`).

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime};

use tokio::sync::Semaphore;
use url::Url;

use crate::error::{Failure, MediaError};
use crate::files::{
    Cleanup, STALE_PART_AGE, part_file, sync_to_disk, touch, trim_files, unique_id,
};
use crate::flight::{Flights, Output, ProgressFn, ProgressHub};
use crate::naming::{redirect_headers, sanitize_headers};
use crate::net::{MediaConfig, Net, Route, read_body, stream_to_file};
use crate::secure::{SecureChoice, SecureSpec};

/// Overall deadline for an image fetch (Swift `MediaLoader.imageDeadline`).
pub const IMAGE_DEADLINE: Duration = Duration::from_secs(25);
/// Inactivity bound of an image fetch (Swift `timeoutIntervalForRequest = 10`).
pub const IMAGE_IDLE: Duration = Duration::from_secs(10);
/// Files have no total deadline: a transfer fails only after this long without receiving bytes.
pub const FILE_IDLE: Duration = Duration::from_secs(30);
/// Largest file `local_file` will download (Zalo allows up to 1 GB).
pub const MAX_FILE_BYTES: u64 = 2 * 1024 * 1024 * 1024;
/// Size cap for `Caches/Olaz/files`.
pub const DEFAULT_FILES_CACHE_LIMIT: u64 = 2 * 1024 * 1024 * 1024;
/// In-memory bodies (photos) are capped; anything larger streams through files.
pub const PHOTO_BYTE_CAP: u64 = 64 << 20;
const HEADERS_MAX_REDIRECTS: usize = 10;

/// Called with a finished temporary file just before it gets its final name (Swift applies the
/// `com.apple.quarantine` attribute there, so the file is never visible without it).
pub trait MediaHooks: Send + Sync {
    fn before_publish(&self, path: &Path, origin_url: &str);
}

#[derive(Clone)]
pub struct MediaOptions {
    pub files_dir: PathBuf,
    pub files_cache_limit: u64,
    pub max_concurrent: usize,
    /// Allowed gap between image bytes (default [`IMAGE_IDLE`]).
    pub image_idle: Duration,
    /// Allowed gap between file bytes (default [`FILE_IDLE`]).
    pub file_idle: Duration,
}

impl MediaOptions {
    #[must_use]
    pub fn new(files_dir: PathBuf) -> Self {
        Self {
            files_dir,
            files_cache_limit: DEFAULT_FILES_CACHE_LIMIT,
            max_concurrent: 6,
            image_idle: IMAGE_IDLE,
            file_idle: FILE_IDLE,
        }
    }
}

#[derive(Clone)]
pub struct DataRequest {
    /// Clean network URL (Swift `ZaloMediaURL.networkURL`).
    pub url: String,
    /// `/jpg/` fallback for a `.jxl` URL.
    pub fallback_url: Option<String>,
    pub secure: Option<SecureSpec>,
    /// Original URL, the single-flight key of encrypted bodies.
    pub key_seed: String,
    pub deadline: Duration,
}

#[derive(Clone)]
pub struct FileRequest {
    pub url: String,
    pub fallback_url: Option<String>,
    /// Cache file name (`cached_file_name`).
    pub file_name: String,
    pub secure: Option<SecureSpec>,
    /// Origin URL recorded by the quarantine hook.
    pub origin_url: String,
}

#[derive(Clone)]
pub struct HeadersRequest {
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub max_bytes: u64,
    pub ttfb: Option<Duration>,
    /// Where the temporary file is created (the caller moves or deletes the result).
    pub temp_dir: PathBuf,
}

#[derive(Clone)]
pub enum DownloadSource {
    Photo(DataRequest),
    Cached(FileRequest),
    Headers(HeadersRequest),
}

#[derive(Clone)]
pub struct DownloadRequest {
    pub source: DownloadSource,
    pub secure: SecureChoice,
    pub temp_dir: PathBuf,
}

/// Result of [`MediaCore::download_to`]: the staged file (decrypted, not yet quarantined or
/// committed) or the failure the official client would report.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DownloadOutcome {
    pub staged: Option<PathBuf>,
    pub failure: Option<Failure>,
}

enum Step<T> {
    Redirect(Url),
    Done(T),
}

pub struct MediaCore {
    net: Net,
    flights: Flights,
    slots: Semaphore,
    opts: MediaOptions,
    maintained: AtomicBool,
    hooks: Option<Arc<dyn MediaHooks>>,
}

fn parse_url(text: &str) -> Result<Url, MediaError> {
    Url::parse(text).map_err(|_| MediaError::BadUrl)
}

fn host_of(url: &Url) -> Result<String, MediaError> {
    url.host_str()
        .map(str::to_lowercase)
        .ok_or(MediaError::BadUrl)
}

impl MediaCore {
    pub fn new(
        cfg: MediaConfig,
        opts: MediaOptions,
        hooks: Option<Arc<dyn MediaHooks>>,
    ) -> Arc<Self> {
        let permits = opts.max_concurrent.max(1);
        Arc::new(Self {
            net: Net::new(cfg),
            flights: Flights::default(),
            slots: Semaphore::new(permits),
            opts,
            maintained: AtomicBool::new(false),
            hooks,
        })
    }

    #[must_use]
    pub fn files_dir(&self) -> &Path {
        &self.opts.files_dir
    }

    /// Test hook: has this host been switched to the DoH path?
    #[must_use]
    pub fn uses_doh(&self, host: &str) -> bool {
        self.net.uses_doh(host)
    }

    /// Number of downloads currently running (diagnostics and tests).
    #[must_use]
    pub fn in_flight(&self) -> usize {
        self.flights.len()
    }

    /// Removes the cached file `file_name` (an explicit retry must really download again).
    pub fn evict(&self, file_name: &str) {
        let name = Path::new(file_name).file_name();
        if let Some(name) = name {
            let _ = fs::remove_file(self.opts.files_dir.join(name));
        }
    }

    // MARK: Image bytes

    /// Bytes for the request (de-duplicated, concurrency-capped, with an overall deadline).
    pub async fn data(self: &Arc<Self>, req: DataRequest) -> Result<Arc<Vec<u8>>, MediaError> {
        let key = if req.secure.is_some() {
            format!("d:dec:{}", req.key_seed)
        } else {
            format!("d:{}", req.url)
        };
        let this = Arc::clone(self);
        let out = self
            .flights
            .join(&key, None, move |_hub| async move {
                this.data_flight(req).await.map(Output::Bytes)
            })
            .await?;
        match out {
            Output::Bytes(bytes) => Ok(bytes),
            Output::Path(_) => Err(MediaError::Cancelled),
        }
    }

    async fn data_flight(self: Arc<Self>, req: DataRequest) -> Result<Arc<Vec<u8>>, MediaError> {
        let url = parse_url(&req.url)?;
        let fallback = req.fallback_url.as_deref().map(parse_url).transpose()?;
        let _permit = self
            .slots
            .acquire()
            .await
            .map_err(|_| MediaError::Cancelled)?;
        let work = async {
            let body = match self.fetch_bytes(url).await {
                Ok(body) => body,
                Err(e) if e != MediaError::Cancelled && req.secure.is_none() => match fallback {
                    Some(jpg) => self.fetch_bytes(jpg).await?,
                    None => return Err(e),
                },
                Err(e) => return Err(e),
            };
            match req.secure {
                Some(spec) => {
                    let plain = tokio::task::spawn_blocking(move || spec.decrypt(&body))
                        .await
                        .map_err(|_| MediaError::Cancelled)?
                        .map_err(|_| MediaError::Undecodable)?;
                    Ok(Arc::new(plain))
                }
                None => Ok(Arc::new(body)),
            }
        };
        tokio::time::timeout(req.deadline, work)
            .await
            .map_err(|_| MediaError::TimedOut)?
    }

    async fn fetch_bytes(&self, start: Url) -> Result<Vec<u8>, MediaError> {
        let mut url = start;
        let mut hops_left = Net::max_redirects();
        let idle = self.opts.image_idle;
        loop {
            let host = host_of(&url)?;
            self.net.fail_if_dead(&host)?;
            let hops = hops_left;
            let target = &url;
            let step = self
                .net
                .with_dns_fallback(&host, false, |route| async move {
                    let head = self.net.send(route, target, &[], idle).await?;
                    if let Some(next) = self.net.redirect_target(&head, target, hops) {
                        return Ok(Step::Redirect(next));
                    }
                    if !(200..300).contains(&head.status) {
                        return Err(MediaError::Http(head.status));
                    }
                    let body =
                        read_body(head.response, idle, PHOTO_BYTE_CAP, head.content_length).await?;
                    Ok(Step::Done(body))
                })
                .await?;
            match step {
                Step::Redirect(next) => {
                    url = next;
                    hops_left -= 1;
                }
                Step::Done(body) => return Ok(body),
            }
        }
    }

    // MARK: Files cache

    /// Downloads into `files_dir/<file_name>` (reused when present) and returns the path. The body
    /// streams to a temporary file (no in-memory buffering), is decrypted on disk when the request
    /// carries a cipher, and only renamed to its final name once complete.
    pub async fn local_file(
        self: &Arc<Self>,
        req: FileRequest,
        progress: Option<ProgressFn>,
    ) -> Result<PathBuf, MediaError> {
        self.start_maintenance();
        let file = self.opts.files_dir.join(&req.file_name);
        if file.exists() {
            touch(&file); // LRU use
            if let Some(p) = &progress {
                p(1.0);
            }
            return Ok(file);
        }
        let key = format!("f:{}", file.display());
        let this = Arc::clone(self);
        let flight_file = file.clone();
        let out = self
            .flights
            .join(&key, progress.clone(), move |hub| async move {
                this.file_flight(req, flight_file, hub)
                    .await
                    .map(Output::Path)
            })
            .await?;
        if let Some(p) = &progress {
            p(1.0);
        }
        self.schedule_trim(Some(file.clone()));
        match out {
            Output::Path(path) => Ok(path),
            Output::Bytes(_) => Err(MediaError::Cancelled),
        }
    }

    async fn file_flight(
        self: Arc<Self>,
        req: FileRequest,
        file: PathBuf,
        hub: Arc<ProgressHub>,
    ) -> Result<PathBuf, MediaError> {
        let dir = self.opts.files_dir.clone();
        tokio::fs::create_dir_all(&dir).await?;
        let url = parse_url(&req.url)?;
        let raw = match self.fetch_file_to_temp(url, &dir, &hub).await {
            Ok(path) => path,
            Err(e) if e != MediaError::Cancelled => match &req.fallback_url {
                Some(jpg) => self.fetch_file_to_temp(parse_url(jpg)?, &dir, &hub).await?,
                None => return Err(e),
            },
            Err(e) => return Err(e),
        };
        let mut cleanup = Cleanup::new();
        cleanup.add(&raw);
        let mut temp = raw.clone();
        if let Some(spec) = req.secure {
            let decrypted = part_file(&dir);
            cleanup.add(&decrypted);
            let (src, dst) = (raw.clone(), decrypted.clone());
            tokio::task::spawn_blocking(move || spec.decrypt_file(&src, &dst))
                .await
                .map_err(|_| MediaError::Cancelled)?
                .map_err(|_| MediaError::Undecodable)?;
            let _ = fs::remove_file(&raw);
            temp = decrypted;
        }
        if file.exists() {
            return Ok(file); // lost a race: the other copy is complete
        }
        let hooks = self.hooks.clone();
        let (publish_src, publish_dst, origin) = (temp.clone(), file.clone(), req.origin_url);
        tokio::task::spawn_blocking(move || {
            // Quarantine before the final name appears, so the file is never visible without it.
            if let Some(hooks) = hooks {
                hooks.before_publish(&publish_src, &origin);
            }
            sync_to_disk(&publish_src);
            match fs::rename(&publish_src, &publish_dst) {
                Ok(()) => Ok(()),
                Err(e) if publish_dst.exists() => {
                    let _ = e;
                    Ok(())
                }
                Err(e) => Err(MediaError::io(&e)),
            }
        })
        .await
        .map_err(|_| MediaError::Cancelled)??;
        Ok(file)
    }

    /// Downloads `start` into a fresh `.part` file in `dir`; leaves no file on failure.
    async fn fetch_file_to_temp(
        &self,
        start: Url,
        dir: &Path,
        hub: &Arc<ProgressHub>,
    ) -> Result<PathBuf, MediaError> {
        let mut url = start;
        let mut hops_left = Net::max_redirects();
        let idle = self.opts.file_idle;
        loop {
            let host = host_of(&url)?;
            self.net.fail_if_dead(&host)?;
            let hops = hops_left;
            let target = &url;
            let step = self
                .net
                .with_dns_fallback(&host, true, |route| async move {
                    hub.reset();
                    let head = self
                        .net
                        .send(route, target, &[], idle)
                        .await
                        .map_err(|e| stall_for(route, e))?;
                    if let Some(next) = self.net.redirect_target(&head, target, hops) {
                        return Ok(Step::Redirect(next));
                    }
                    if !(200..300).contains(&head.status) {
                        return Err(MediaError::Http(head.status));
                    }
                    let temp = part_file(dir);
                    let mut guard = Cleanup::new();
                    guard.add(&temp);
                    let stall = if route == Route::Doh {
                        MediaError::TimedOut
                    } else {
                        MediaError::Net(crate::error::NetKind::TimedOut)
                    };
                    stream_to_file(
                        head.response,
                        &temp,
                        idle,
                        None,
                        MAX_FILE_BYTES,
                        stall,
                        |r, t| hub.report(r, t),
                    )
                    .await?;
                    guard.forget(&temp);
                    Ok(Step::Done(temp))
                })
                .await?;
            match step {
                Step::Redirect(next) => {
                    url = next;
                    hops_left -= 1;
                }
                Step::Done(path) => return Ok(path),
            }
        }
    }

    fn start_maintenance(self: &Arc<Self>) {
        if !self.maintained.swap(true, Ordering::AcqRel) {
            self.schedule_trim(None);
        }
    }

    fn schedule_trim(&self, keep: Option<PathBuf>) {
        let (dir, limit) = (self.opts.files_dir.clone(), self.opts.files_cache_limit);
        tokio::task::spawn_blocking(move || {
            trim_files(
                &dir,
                limit,
                keep.as_deref(),
                STALE_PART_AGE,
                SystemTime::now(),
            );
        });
    }

    // MARK: Requests with custom headers

    /// GET with caller-supplied headers (Zalo Cloud downloads carry `cloud-viewer-key`), streamed
    /// to a temporary file in `req.temp_dir` that the caller moves into place (and deletes on the
    /// failure paths it handles). System route only (DoH cannot carry the headers), no URL cache;
    /// capped at `max_bytes`, stalls fail after 30 s without data and `ttfb` bounds the wait for
    /// the first byte only. Sensitive headers are dropped when a redirect changes host.
    pub async fn download_with_headers(
        self: &Arc<Self>,
        req: HeadersRequest,
        progress: Option<ProgressFn>,
    ) -> Result<PathBuf, MediaError> {
        let parsed = parse_url(&req.url)?;
        let mut url = crate::naming::normalize_url(&parsed, self.net.cfg.allow_plain_http)
            .ok_or(MediaError::BadUrl)?;
        let origin_host = host_of(&url)?;
        self.net.fail_if_dead(&origin_host)?;
        let cfg = Arc::clone(&self.net.cfg);
        let mut headers = sanitize_headers(&req.headers, &url, |h| cfg.is_cdn(h));
        let hub = ProgressHub::default();
        let observer = progress.map(|p| hub.add(p));
        let started = tokio::time::Instant::now();
        let first = req.ttfb;
        let idle = self.opts.file_idle;
        let mut hops_left = HEADERS_MAX_REDIRECTS;
        let result = async {
            loop {
                let remaining = first.map(|f| f.saturating_sub(started.elapsed()));
                let head_wait = remaining.map_or(idle, |r| r.min(idle));
                let head = self
                    .net
                    .send(Route::System, &url, &headers, head_wait)
                    .await
                    .map_err(|e| {
                        if e == MediaError::Net(crate::error::NetKind::TimedOut)
                            && remaining.is_some_and(|r| r <= idle)
                        {
                            MediaError::TimedOut
                        } else {
                            e
                        }
                    })?;
                if let Some(next) = self.net.redirect_target(&head, &url, hops_left) {
                    headers = redirect_headers(&headers, &origin_host, &next);
                    url = next;
                    hops_left -= 1;
                    continue;
                }
                if !(200..300).contains(&head.status) {
                    return Err(MediaError::Http(head.status));
                }
                tokio::fs::create_dir_all(&req.temp_dir).await?;
                let temp = part_file(&req.temp_dir);
                let mut guard = Cleanup::new();
                guard.add(&temp);
                let first_wait = first.map(|f| f.saturating_sub(started.elapsed()));
                stream_to_file(
                    head.response,
                    &temp,
                    idle,
                    first_wait,
                    req.max_bytes,
                    MediaError::Net(crate::error::NetKind::TimedOut),
                    |r, t| hub.report(r, t),
                )
                .await?;
                guard.forget(&temp);
                return Ok(temp);
            }
        }
        .await;
        if let Some(id) = observer {
            hub.remove(id);
        }
        result
    }

    // MARK: Staged downloads (DownloadManager.execute + finalize)

    /// The transfer: fetch -> decrypt -> stage. The result is a decrypted file in `temp_dir` that
    /// the caller quarantines and commits atomically; nothing is ever written to the destination
    /// here. Temporaries are always removed.
    pub async fn download_to(
        self: &Arc<Self>,
        req: DownloadRequest,
        progress: Option<ProgressFn>,
    ) -> DownloadOutcome {
        match self.download_inner(req, progress).await {
            Ok(path) => DownloadOutcome {
                staged: Some(path),
                failure: None,
            },
            Err(failure) => DownloadOutcome {
                staged: None,
                failure: Some(failure),
            },
        }
    }

    async fn download_inner(
        self: &Arc<Self>,
        req: DownloadRequest,
        progress: Option<ProgressFn>,
    ) -> Result<PathBuf, Failure> {
        let fail = |e: &MediaError| Failure::from_error(e);
        let mut cleanup = Cleanup::new();
        let spec = match &req.secure {
            SecureChoice::None => None,
            SecureChoice::Stream(spec) => Some(spec.clone()),
            SecureChoice::Invalid => return Err(Failure::decrypt_failed()), // never save ciphertext
        };
        enum Fetched {
            Bytes(Arc<Vec<u8>>),
            File(PathBuf, bool),
        }
        let fetched = match req.source {
            DownloadSource::Photo(data) => {
                Fetched::Bytes(self.data(data).await.map_err(|e| fail(&e))?)
            }
            DownloadSource::Cached(file) => Fetched::File(
                self.local_file(file, progress)
                    .await
                    .map_err(|e| fail(&e))?,
                false,
            ),
            DownloadSource::Headers(headers) => {
                let raw = self
                    .download_with_headers(headers, progress)
                    .await
                    .map_err(|e| fail(&e))?;
                cleanup.add(&raw);
                Fetched::File(raw, true)
            }
        };
        let temp_dir = req.temp_dir.clone();
        tokio::fs::create_dir_all(&temp_dir)
            .await
            .map_err(|e| fail(&e.into()))?;
        let staged = temp_dir.join(format!("{}.part", unique_id()));
        cleanup.add(&staged);
        match fetched {
            Fetched::Bytes(bytes) => {
                if bytes.is_empty() {
                    return Err(Failure::empty_body());
                }
                if bytes.len() as u64 > PHOTO_BYTE_CAP {
                    return Err(Failure::too_large());
                }
                let target = staged.clone();
                let written = tokio::task::spawn_blocking(move || -> Result<(), Failure> {
                    match spec {
                        Some(spec) => {
                            let plain = spec
                                .decrypt(&bytes)
                                .map_err(|_| Failure::decrypt_failed())?;
                            fs::write(&target, plain)
                        }
                        None => fs::write(&target, bytes.as_slice()),
                    }
                    .map_err(|e| Failure::from_error(&MediaError::io(&e)))
                })
                .await
                .map_err(|_| Failure::aborted())?;
                written?;
            }
            Fetched::File(raw, ours) => {
                let (src, dst) = (raw, staged.clone());
                let result = tokio::task::spawn_blocking(move || -> Result<(), Failure> {
                    if let Some(spec) = spec {
                        return spec
                            .decrypt_file(&src, &dst)
                            .map_err(|_| Failure::decrypt_failed());
                    }
                    let io = |e: std::io::Error| Failure::from_error(&MediaError::io(&e));
                    if ours {
                        fs::rename(&src, &dst)
                            .or_else(|_| {
                                fs::copy(&src, &dst).map(|_| ()) // other volume: copy, the guard removes the source
                            })
                            .map_err(io)
                    } else {
                        fs::copy(&src, &dst).map(|_| ()).map_err(io) // shared cache file: never moved
                    }
                })
                .await
                .map_err(|_| Failure::aborted())?;
                result?;
            }
        }
        let size = tokio::fs::metadata(&staged).await.map_or(0, |m| m.len());
        if size == 0 {
            return Err(Failure::empty_body());
        }
        cleanup.forget(&staged);
        Ok(staged)
    }
}

fn stall_for(route: Route, error: MediaError) -> MediaError {
    // The pinned (DoH) client reported a header-phase stall as `LoadError.timedOut` for files.
    if route == Route::Doh && error == MediaError::Net(crate::error::NetKind::TimedOut) {
        MediaError::TimedOut
    } else {
        error
    }
}
