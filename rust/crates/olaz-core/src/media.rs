//! Media upload/download orchestration, single-flight resolver, file-download tracking, and
//! shared-media types & pure helpers (U15, ADR-031).
//!
//! No media file bytes cross FFI: outgoing files are probed/staged on the host by `op_id`, and
//! incoming media/file fetches return local file paths or typed error kinds.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fmt;

use olaz_wire::{ChatMessage, Kind};

use crate::messages::is_valid_url_str;

/// TTL (30 s) for remembered `MediaResolution::Unavailable` verdicts (`MediaResolver.unavailableTTL`).
pub const MEDIA_UNAVAILABLE_TTL_MS: i64 = 30_000;

/// Maximum settled entries before pruning expired entries (`MediaResolver.settled.count > 2000`).
pub const MEDIA_SETTLED_PRUNE_THRESHOLD: usize = 2000;

/// Default maximum concurrent media resolutions (`MediaResolver(maxConcurrent: 3)`).
pub const MEDIA_DEFAULT_MAX_CONCURRENT: usize = 3;

/// Floor (100 MB) for outgoing file size validation (`ZaloEngine.sendFiles`).
pub const OUTGOING_FILE_LIMIT_FLOOR_BYTES: i64 = 100 * 1_048_576;

/// Kind of media requested from `resolve_media` (`MediaKind`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MediaKind {
    Photo,
    VideoThumb,
    Video,
}

impl MediaKind {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Photo => "photo",
            Self::VideoThumb => "videoThumb",
            Self::Video => "video",
        }
    }

    #[must_use]
    pub fn from_str_tag(s: &str) -> Option<Self> {
        match s {
            "photo" => Some(Self::Photo),
            "videoThumb" => Some(Self::VideoThumb),
            "video" => Some(Self::Video),
            _ => None,
        }
    }
}

/// Resolution result for `resolve_media` (`MediaResolution`), unified with U8/U11.
pub use crate::forward::MediaResolutionOutcome as MediaResolution;

/// Resolution result for `resolve_file` (`FileResolution`), unified with U8/U11.
pub use crate::forward::FileResolutionOutcome as FileResolution;

/// Shared-media storage panel category (`SharedMediaKind`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SharedMediaKind {
    Images,
    Files,
    Links,
}

impl SharedMediaKind {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Images => "images",
            Self::Files => "files",
            Self::Links => "links",
        }
    }

    #[must_use]
    pub fn from_str_tag(s: &str) -> Option<Self> {
        match s {
            "images" => Some(Self::Images),
            "files" => Some(Self::Files),
            "links" => Some(Self::Links),
            _ => None,
        }
    }

    /// SQLite `kind_tag` values matching this tab (`ZaloEngine+SharedMedia.swift`).
    #[must_use]
    pub fn kind_tags(self) -> Vec<String> {
        match self {
            Self::Images => vec!["photo".to_owned(), "video".to_owned()],
            Self::Files => vec!["file".to_owned()],
            Self::Links => vec!["link".to_owned()],
        }
    }

    /// In-memory filter predicate matching `SharedMediaKind.accepts(_:)`.
    #[must_use]
    pub fn accepts(self, kind: &Kind) -> bool {
        match (self, kind) {
            (Self::Images, Kind::Photo { .. } | Kind::Video { .. })
            | (Self::Files, Kind::File { .. }) => true,
            (Self::Links, Kind::Link { url, .. }) => url.as_deref().is_some_and(is_valid_url_str),
            _ => false,
        }
    }
}

/// One page of shared-media messages (`SharedMediaPage`).
#[derive(Clone, PartialEq)]
pub struct SharedMediaPage {
    pub items: Vec<ChatMessage>,
    pub cursor: Option<String>,
    pub more: bool,
}

impl fmt::Debug for SharedMediaPage {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SharedMediaPage")
            .field("items", &self.items.len())
            .field("has_cursor", &self.cursor.is_some())
            .field("more", &self.more)
            .finish()
    }
}

/// Mode passed to `read_outgoing_file` host call (`"media"` vs `"file"`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OutgoingFileMode {
    Media,
    File,
}

impl OutgoingFileMode {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Media => "media",
            Self::File => "file",
        }
    }
}

/// Host probe result for an outgoing local file (`OutgoingFileProbeResult`).
#[derive(Clone, PartialEq, Eq)]
pub struct OutgoingFileProbe {
    pub exists: bool,
    pub is_dir: bool,
    pub readable: bool,
    pub size: i64,
    /// Optional explicit media-type hint (`"image"` / `"video"` / `"file"`).
    pub media_type: Option<String>,
}

impl fmt::Debug for OutgoingFileProbe {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("OutgoingFileProbe")
            .field("exists", &self.exists)
            .field("is_dir", &self.is_dir)
            .field("readable", &self.readable)
            .field("size", &self.size)
            .field("media_type", &self.media_type)
            .finish()
    }
}

/// Video metadata returned by host (`VideoMetadata`).
#[derive(Clone, Copy, PartialEq, Eq, Default)]
pub struct VideoMetadata {
    pub duration_ms: i64,
    pub width: i64,
    pub height: i64,
    pub has_thumb: bool,
}

impl fmt::Debug for VideoMetadata {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("VideoMetadata")
            .field("duration_ms", &self.duration_ms)
            .field("width", &self.width)
            .field("height", &self.height)
            .field("has_thumb", &self.has_thumb)
            .finish()
    }
}

/// Host result for `upload_photo` (`UploadedMediaResult`).
#[derive(Clone, PartialEq, Eq)]
pub struct UploadedPhotoResult {
    pub url: String,
    pub msg_id: String,
    pub cli_msg_id: String,
    pub width: i64,
    pub height: i64,
}

impl fmt::Debug for UploadedPhotoResult {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("UploadedPhotoResult")
            .field("has_url", &!self.url.is_empty())
            .field("has_msg_id", &!self.msg_id.is_empty())
            .field("width", &self.width)
            .field("height", &self.height)
            .finish()
    }
}

/// Host result for `upload_video` (`UploadedVideoResult`).
#[derive(Clone, PartialEq, Eq)]
pub struct UploadedVideoResult {
    pub url: String,
    pub thumb_url: String,
    pub msg_id: String,
    pub cli_msg_id: String,
    pub width: i64,
    pub height: i64,
    pub duration_ms: i64,
}

impl fmt::Debug for UploadedVideoResult {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("UploadedVideoResult")
            .field("has_url", &!self.url.is_empty())
            .field("has_thumb", &!self.thumb_url.is_empty())
            .field("has_msg_id", &!self.msg_id.is_empty())
            .field("duration_ms", &self.duration_ms)
            .finish()
    }
}

/// Host result for `upload_file` (`UploadedMediaResult`).
#[derive(Clone, PartialEq, Eq)]
pub struct UploadedFileResult {
    pub url: String,
    pub msg_id: String,
    pub cli_msg_id: String,
}

impl fmt::Debug for UploadedFileResult {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("UploadedFileResult")
            .field("has_url", &!self.url.is_empty())
            .field("has_msg_id", &!self.msg_id.is_empty())
            .finish()
    }
}

/// Typed upload failure returned from `upload_file` (`ZaloSessionError` / `URLError` / other).
#[derive(Clone, PartialEq, Eq)]
pub enum UploadFileError {
    Session { code: i64, message: String },
    Network,
    Other(String),
}

impl fmt::Debug for UploadFileError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Session { code, message } => f
                .debug_struct("Session")
                .field("code", code)
                .field("msg_len", &message.len())
                .finish(),
            Self::Network => f.write_str("Network"),
            Self::Other(m) => f.debug_tuple("Other").field(&m.len()).finish(),
        }
    }
}

/// Cached media hit returned by `media_cache_lookup`.
#[derive(Clone, PartialEq, Eq)]
pub struct MediaCacheHit {
    pub path: String,
    pub is_video: bool,
}

impl fmt::Debug for MediaCacheHit {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("MediaCacheHit")
            .field("is_video", &self.is_video)
            .finish()
    }
}

/// Result of fetching + validating/caching one remote media URL (`loader_fetch_media`).
#[derive(Clone, PartialEq, Eq)]
pub enum MediaFetchOutcome {
    Cached { path: String, is_video: bool },
    PermanentGone,
    Transient,
}

impl fmt::Debug for MediaFetchOutcome {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Cached { is_video, .. } => f
                .debug_struct("Cached")
                .field("is_video", is_video)
                .finish(),
            Self::PermanentGone => f.write_str("PermanentGone"),
            Self::Transient => f.write_str("Transient"),
        }
    }
}

/// Typed load error for `resolve_file` (`MediaLoader.LoadError` / `CancellationError` / other).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FileLoadError {
    Http(u16),
    HostNotFound,
    Undecodable,
    TimedOut,
    TooLarge,
    BadUrl,
    Cancelled,
    Other,
}

impl FileLoadError {
    /// Matches `ChatFileResolver.isPermanentGone(_:)`.
    #[must_use]
    pub const fn is_permanent_gone(self) -> bool {
        matches!(self, Self::Http(404 | 410) | Self::HostNotFound)
    }

    /// Matches `ChatFileResolver.userMessage(for:)` (+ `CancellationError`).
    #[must_use]
    pub fn user_message(self) -> String {
        match self {
            Self::Http(404 | 410) | Self::HostNotFound => {
                "Tệp đã quá hạn lưu trữ trên máy chủ Zalo.".to_owned()
            }
            Self::Undecodable => "Không giải mã được tệp đính kèm.".to_owned(),
            Self::TimedOut => "Tải tệp quá thời gian chờ. Vui lòng thử lại.".to_owned(),
            Self::TooLarge => "Tệp vượt quá giới hạn dung lượng cho phép.".to_owned(),
            Self::Http(code) => format!("Máy chủ trả lỗi HTTP {code} khi tải tệp."),
            Self::BadUrl => "Liên kết tệp không hợp lệ.".to_owned(),
            Self::Cancelled => "Đã huỷ tải tệp.".to_owned(),
            Self::Other => "Không tải được tệp. Kiểm tra kết nối mạng và thử lại.".to_owned(),
        }
    }
}

/// Result of fetching one remote file for `resolve_file` (`loader_fetch_file`).
#[derive(Clone, PartialEq, Eq)]
pub enum FileFetchOutcome {
    Fetched {
        cached_path: String,
        container_ext: Option<String>,
    },
    Error(FileLoadError),
}

impl fmt::Debug for FileFetchOutcome {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Fetched { container_ext, .. } => f
                .debug_struct("Fetched")
                .field("container_ext", container_ext)
                .finish(),
            Self::Error(e) => f.debug_tuple("Error").field(e).finish(),
        }
    }
}

/// Purpose for an internal `MediaCheckFileExists` effect.
#[derive(Clone, PartialEq, Eq)]
pub enum FileExistsPurpose {
    /// Checking whether a settled `MediaResolution::File` still exists on disk.
    SettledMedia {
        op_id: u64,
        conv_id: String,
        msg_id: String,
        kind: MediaKind,
        force: bool,
        now_ms: i64,
        path: String,
    },
    /// Checking whether a `downloaded_file_paths[key]` file still exists on disk.
    DownloadedFile {
        op_id: u64,
        key: String,
        path: String,
    },
}

impl fmt::Debug for FileExistsPurpose {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::SettledMedia { op_id, kind, .. } => f
                .debug_struct("SettledMedia")
                .field("op_id", op_id)
                .field("kind", kind)
                .finish(),
            Self::DownloadedFile { op_id, .. } => f
                .debug_struct("DownloadedFile")
                .field("op_id", op_id)
                .finish(),
        }
    }
}

/// Remembered verdict in `MediaState::settled`.
#[derive(Clone, PartialEq, Eq)]
pub struct SettledMedia {
    pub resolution: MediaResolution,
    pub until_ms: i64,
}

impl fmt::Debug for SettledMedia {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SettledMedia")
            .field("resolution", &self.resolution)
            .field("until_ms", &self.until_ms)
            .finish()
    }
}

/// Internal phase of an active `resolve_media` single-flight.
#[derive(Clone)]
pub(crate) enum MediaFlightPhase {
    Queued,
    LookupStore,
    CacheLookup {
        candidates: Vec<String>,
        hash_prefix: String,
    },
    CandidateLoop {
        candidates: Vec<String>,
        hash_prefix: String,
        idx: usize,
        saw_permanent_gone: bool,
        saw_transient_error: bool,
    },
}

/// Active single-flight entry for one `(conv_id|msg_id|kind)` key.
#[derive(Clone)]
pub(crate) struct ActiveMediaFlight {
    pub flight_id: u64,
    pub conv_id: String,
    pub msg_id: String,
    pub kind: MediaKind,
    pub force: bool,
    pub now_ms: i64,
    pub waiters: Vec<u64>,
    pub phase: MediaFlightPhase,
}

/// In-flight sequential `send_media` operation.
#[derive(Clone)]
pub(crate) struct PendingSendMedia {
    pub op_id: u64,
    pub conv_id: String,
    pub paths: Vec<String>,
    pub idx: usize,
    pub sent_any: bool,
    pub now_ms: i64,
    pub current_file_name: String,
    pub current_size: i64,
}

/// In-flight sequential `send_files` operation.
#[derive(Clone)]
pub(crate) struct PendingSendFiles {
    pub op_id: u64,
    pub conv_id: String,
    pub paths: Vec<String>,
    pub idx: usize,
    pub max_bytes: i64,
    pub is_group: bool,
    pub is_e2ee: bool,
    pub sent_any: bool,
    pub last_failure: Option<String>,
    pub now_ms: i64,
    pub current_file_name: String,
    pub current_size: i64,
    pub current_client_id: Option<String>,
}

/// In-flight `resolve_file` operation.
#[derive(Clone)]
pub(crate) struct PendingResolveFile {
    pub op_id: u64,
    pub conv_id: String,
    pub msg_id: String,
    pub name: String,
    pub force: bool,
    pub request_token: u64,
    pub cached_path: Option<String>,
}

/// Media domain state owned by `CoreState` (U15).
#[derive(Clone)]
pub struct MediaState {
    pub settled: HashMap<String, SettledMedia>,
    pub max_concurrent: usize,
    pub downloaded_file_paths: BTreeMap<String, String>,
    /// Optional seeded cloud file limit (for tests/seeds before `cloud.snapshot.plan` is loaded).
    pub seeded_cloud_file_limit: Option<i64>,

    pub(crate) running: usize,
    pub(crate) queue: Vec<String>,
    pub(crate) flights: HashMap<String, ActiveMediaFlight>,
    pub(crate) flight_id_to_key: HashMap<u64, String>,
    pub(crate) next_flight_id: u64,

    pub(crate) pending_send_media: HashMap<u64, PendingSendMedia>,
    pub(crate) pending_send_files: HashMap<u64, PendingSendFiles>,
    pub(crate) pending_resolve_files: HashMap<u64, PendingResolveFile>,
}

impl Default for MediaState {
    fn default() -> Self {
        Self {
            settled: HashMap::new(),
            max_concurrent: MEDIA_DEFAULT_MAX_CONCURRENT,
            downloaded_file_paths: BTreeMap::new(),
            seeded_cloud_file_limit: None,
            running: 0,
            queue: Vec::new(),
            flights: HashMap::new(),
            flight_id_to_key: HashMap::new(),
            next_flight_id: 0,
            pending_send_media: HashMap::new(),
            pending_send_files: HashMap::new(),
            pending_resolve_files: HashMap::new(),
        }
    }
}

impl MediaState {
    pub(crate) fn alloc_flight_id(&mut self) -> u64 {
        self.next_flight_id = self.next_flight_id.saturating_add(1);
        self.next_flight_id
    }

    /// Remembered verdict for `key`, ignoring TTL (matches `MediaResolver.known(_:)`).
    #[must_use]
    pub fn known(&self, key: &str) -> Option<&MediaResolution> {
        self.settled.get(key).map(|e| &e.resolution)
    }

    /// Number of queued flights waiting for a concurrency slot (`MediaResolver.queuedCount`).
    #[must_use]
    pub fn queued_count(&self) -> usize {
        self.queue.len()
    }

    /// Effective outgoing file size limit in bytes (`max(cloud.plan?.fileLimit ?? 0, 100 MB)`).
    #[must_use]
    pub fn effective_file_limit(&self, cloud_plan_limit: Option<i64>) -> i64 {
        cloud_plan_limit
            .or(self.seeded_cloud_file_limit)
            .unwrap_or(0)
            .max(OUTGOING_FILE_LIMIT_FLOOR_BYTES)
    }
}

impl fmt::Debug for MediaState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("MediaState")
            .field("settled_count", &self.settled.len())
            .field("running", &self.running)
            .field("queued", &self.queue.len())
            .field("flights", &self.flights.len())
            .field("downloaded_file_paths", &self.downloaded_file_paths.len())
            .field("pending_send_media", &self.pending_send_media.len())
            .field("pending_send_files", &self.pending_send_files.len())
            .field("pending_resolve_files", &self.pending_resolve_files.len())
            .finish()
    }
}

// MARK: - Pure helpers

/// FNV-1a 64-bit hash formatted as unpadded lowercase hex (`MediaLoader.stableHash`).
#[must_use]
pub fn stable_hash(text: &str) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in text.bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{hash:x}")
}

/// Extracts the last path component of a filesystem path or URL-like path.
#[must_use]
pub fn last_path_component(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    match trimmed.rsplit_once('/') {
        Some((_, tail)) if !tail.is_empty() => tail.to_owned(),
        _ => trimmed.to_owned(),
    }
}

/// Validates an outgoing file probe in the exact order of `ZaloEngine.sendFiles` /
/// `ZaloEngine.validateOutgoingFile`.
#[must_use]
pub fn validate_outgoing_file_probe(
    name: &str,
    probe: &OutgoingFileProbe,
    max_bytes: i64,
) -> Option<String> {
    if probe.is_dir {
        return Some(format!(
            "Chưa hỗ trợ gửi thư mục ({name}). Hãy nén thành .zip trước."
        ));
    }
    if !probe.exists {
        return Some(format!("Không đọc được tệp {name}."));
    }
    if probe.size <= 0 {
        return Some(format!("Tệp {name} rỗng (0 byte) nên không thể gửi."));
    }
    if max_bytes > 0 && probe.size > max_bytes {
        let limit_mb = (max_bytes / 1_048_576).max(1);
        return Some(format!("Tệp {name} vượt quá giới hạn {limit_mb} MB."));
    }
    if !probe.readable {
        return Some(format!("Không đọc được tệp {name}."));
    }
    None
}

/// Formats an `UploadFileError` into the exact user-facing Vietnamese string (`ZaloEngine.sendFiles`).
#[must_use]
pub fn format_upload_file_error(file_name: &str, error: &UploadFileError) -> String {
    match error {
        UploadFileError::Session { code, message } => {
            if !message.is_empty() {
                message.clone()
            } else if *code == -108 || *code == -104 || *code == 401 {
                "Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại.".to_owned()
            } else {
                format!("Gửi tệp {file_name} thất bại (mã {code}).")
            }
        }
        UploadFileError::Network => {
            "Không có kết nối mạng. Vui lòng kiểm tra và thử lại.".to_owned()
        }
        UploadFileError::Other(_) => format!("Không thể gửi tệp {file_name}."),
    }
}

/// Classifies a file extension as image when `probe.media_type` is absent.
#[must_use]
pub fn is_image_extension(file_name: &str) -> bool {
    let ext = swift_path_extension(file_name).to_ascii_lowercase();
    matches!(
        ext.as_str(),
        "jpg"
            | "jpeg"
            | "png"
            | "gif"
            | "webp"
            | "heic"
            | "heif"
            | "bmp"
            | "tif"
            | "tiff"
            | "ico"
            | "jxl"
            | "avif"
            | "svg"
            | "raw"
            | "dng"
    )
}

/// Classifies a file extension as video (`ZaloEngine.isVideoURL`) when `probe.media_type` is absent.
#[must_use]
pub fn is_video_extension(file_name: &str) -> bool {
    let ext = swift_path_extension(file_name).to_ascii_lowercase();
    matches!(
        ext.as_str(),
        "mp4"
            | "mov"
            | "m4v"
            | "avi"
            | "mkv"
            | "webm"
            | "3gp"
            | "3g2"
            | "flv"
            | "wmv"
            | "ts"
            | "mts"
            | "m2ts"
            | "mpeg"
            | "mpg"
            | "ogv"
    )
}

/// Computes `NSString.pathExtension` on a single filename (no directory separators).
#[must_use]
pub fn swift_path_extension(file_name: &str) -> &str {
    match file_name.rfind('.') {
        Some(idx) if idx > 0 && idx + 1 < file_name.len() => &file_name[idx + 1..],
        _ => "",
    }
}

/// Exact port of `ChatFileResolver.sanitizedFileName(_:fallbackExtension:)`.
#[must_use]
pub fn sanitized_file_name(raw_name: &str, fallback_extension: Option<&str>) -> String {
    let mut clean: String = raw_name
        .chars()
        .filter(|&c| c != '\0')
        .map(|c| match c {
            '/' | '\\' | ':' => '-',
            other => other,
        })
        .collect();
    clean = clean.trim().to_owned();
    while clean.starts_with('.') {
        clean.remove(0);
    }
    if clean.is_empty() || clean == "." || clean == ".." {
        clean = "Tệp đính kèm".to_owned();
    }
    let own_ext = swift_path_extension(&clean);
    if own_ext.is_empty()
        && let Some(fb) = fallback_extension
    {
        let trimmed_fb = fb.trim_matches(|c| c == '.' || c == ' ');
        if !trimmed_fb.is_empty() {
            clean.push('.');
            clean.push_str(trimmed_fb);
        }
    }
    clean
}

/// Splits a sanitized filename into `(clean_stem, clean_ext)` for `CloudFiles.stage`.
#[must_use]
pub fn split_sanitized_stem_ext(safe_full: &str) -> (String, Option<String>) {
    let ext = swift_path_extension(safe_full);
    let stem = if ext.is_empty() {
        safe_full
    } else {
        &safe_full[..safe_full.len() - ext.len() - 1]
    };
    let clean_stem = if stem.is_empty() {
        "Tệp đính kèm".to_owned()
    } else {
        stem.to_owned()
    };
    let clean_ext = if ext.is_empty() {
        None
    } else {
        Some(ext.to_owned())
    };
    (clean_stem, clean_ext)
}

/// Exact port of `ZaloEngine.fileDownloadKey(conversationId:messageId:url:name:)`.
#[must_use]
pub fn file_download_key(conv_id: &str, msg_id: &str, url: Option<&str>, name: &str) -> String {
    if !conv_id.is_empty() && !msg_id.is_empty() {
        return format!("{conv_id}|{msg_id}");
    }
    if let Some(u) = url
        && !u.is_empty()
    {
        return u.to_owned();
    }
    name.to_owned()
}

/// Extracts deduplicated candidate URLs for `(kind, msg)` (`ZaloEngine.resolveMedia`).
///
/// Returns `None` when `(kind, msg.kind)` is an unsupported pair (caller yields `.unsupported`).
/// Returns `Some(vec)` where an empty `vec` yields `.unavailable`.
pub fn extract_media_candidates(kind: MediaKind, msg: &ChatMessage) -> Option<Vec<String>> {
    let mut raw: Vec<&str> = Vec::new();
    match (kind, &msg.kind) {
        (MediaKind::Photo, Kind::Photo { url, .. }) => {
            if let Some(u) = url.as_deref()
                && !u.is_empty()
            {
                raw.push(u);
            }
            for fb in &msg.fallback_urls {
                if !fb.is_empty() {
                    raw.push(fb.as_str());
                }
            }
        }
        (MediaKind::Video, Kind::Video { url, .. }) => {
            if let Some(u) = url.as_deref()
                && !u.is_empty()
            {
                raw.push(u);
            }
            for fb in &msg.fallback_urls {
                if !fb.is_empty() {
                    raw.push(fb.as_str());
                }
            }
        }
        (MediaKind::VideoThumb, Kind::Video { thumbnail, url, .. }) => {
            if let Some(t) = thumbnail.as_deref()
                && !t.is_empty()
            {
                raw.push(t);
            }
            if let Some(v) = url.as_deref()
                && !v.is_empty()
            {
                raw.push(v);
            }
            for fb in &msg.fallback_urls {
                if !fb.is_empty() {
                    raw.push(fb.as_str());
                }
            }
        }
        (MediaKind::Photo, Kind::Gif { url }) => {
            if let Some(u) = url.as_deref()
                && !u.is_empty()
            {
                raw.push(u);
            }
            for fb in &msg.fallback_urls {
                if !fb.is_empty() {
                    raw.push(fb.as_str());
                }
            }
        }
        _ => return None,
    }

    let mut seen = HashSet::with_capacity(raw.len());
    let mut out = Vec::with_capacity(raw.len());
    for candidate in raw {
        if seen.insert(candidate) {
            out.push(candidate.to_owned());
        }
    }
    Some(out)
}

/// Pure in-memory shared-media fallback when no SQLite store is attached
/// (`ZaloEngine+SharedMedia.swift`).
#[must_use]
pub fn shared_media_memory(
    messages: &[ChatMessage],
    kind: SharedMediaKind,
    limit: usize,
) -> SharedMediaPage {
    let mut matched: Vec<ChatMessage> = messages
        .iter()
        .filter(|m| kind.accepts(&m.kind))
        .cloned()
        .collect();
    // Swift `sorted { $0.date > $1.date }` is stable descending by date_ms.
    matched.sort_by_key(|a| std::cmp::Reverse(a.date_ms));
    matched.truncate(limit);
    SharedMediaPage {
        items: matched,
        cursor: None,
        more: false,
    }
}

/// URL scheme classifier for `resolve_media` candidates.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CandidateScheme {
    File,
    Http,
    Other,
}

#[must_use]
pub fn classify_candidate_scheme(url: &str) -> CandidateScheme {
    let Some((scheme, _)) = url.split_once(':') else {
        return CandidateScheme::Other;
    };
    if scheme.eq_ignore_ascii_case("file") {
        CandidateScheme::File
    } else if scheme.eq_ignore_ascii_case("https") || scheme.eq_ignore_ascii_case("http") {
        CandidateScheme::Http
    } else {
        CandidateScheme::Other
    }
}

/// Strips `file://` prefix for local path reporting (test/host convenience).
#[must_use]
pub fn file_url_path(url: &str) -> String {
    if let Some(rest) = url.strip_prefix("file://") {
        rest.to_owned()
    } else if url.len() >= 7 && url[..7].eq_ignore_ascii_case("file://") {
        url[7..].to_owned()
    } else {
        url.to_owned()
    }
}

#[cfg(test)]
mod tests {
    use olaz_wire::{ChatMessage, Kind, MessageMenu, Status};

    use super::*;

    fn empty_msg(id: &str, date_ms: i64, kind: Kind, fallbacks: Vec<&str>) -> ChatMessage {
        ChatMessage {
            id: id.to_owned(),
            conversation_id: "c1".to_owned(),
            sender_id: String::new(),
            sender_name: String::new(),
            sender_avatar: None,
            is_mine: false,
            kind,
            text: String::new(),
            date_ms,
            status: Status::Sent,
            quote: None,
            reactions: Vec::new(),
            is_e2ee: false,
            mentions: Vec::new(),
            card_buttons: Vec::new(),
            suggests_stickers: false,
            menu: MessageMenu::default(),
            fallback_urls: fallbacks.into_iter().map(str::to_owned).collect(),
            client_id: String::new(),
            text_styles: Vec::new(),
            ttl_ms: 0,
            urgency: 0,
        }
    }

    fn msg_with_kind(kind: Kind, fallbacks: Vec<&str>) -> ChatMessage {
        empty_msg("m1", 0, kind, fallbacks)
    }

    #[test]
    fn stable_hash_matches_swift_media_loader() {
        assert_eq!(stable_hash("3000501|m_photo|photo"), "96444c262377e092");
        assert_eq!(stable_hash("3000501|m_video|video"), "712d4b6b149c53da");
        assert_eq!(
            stable_hash("3000501|m_video|videoThumb"),
            "e3b7f2f9fc905a6a"
        );
        assert_eq!(stable_hash("3000601|m_cached|photo"), "37cb8a6d2fa50453");
    }

    #[test]
    fn sanitized_file_name_matches_chat_file_resolver() {
        assert_eq!(
            sanitized_file_name("Report/Q1", Some("png")),
            "Report-Q1.png"
        );
        assert_eq!(
            sanitized_file_name("Spec:v2.txt", Some("png")),
            "Spec-v2.txt"
        );
        assert_eq!(sanitized_file_name("...hidden", Some("pdf")), "hidden.pdf");
        assert_eq!(
            sanitized_file_name("   ...  ", Some("bin")),
            "Tệp đính kèm.bin"
        );
        assert_eq!(sanitized_file_name("a\\b\0c", None), "a-bc");
        assert_eq!(
            split_sanitized_stem_ext("Report-Q1.png"),
            ("Report-Q1".to_owned(), Some("png".to_owned()))
        );
        assert_eq!(
            split_sanitized_stem_ext("noext"),
            ("noext".to_owned(), None)
        );
    }

    #[test]
    fn validate_outgoing_file_probe_checks_all_branches_in_order() {
        let dir = OutgoingFileProbe {
            exists: true,
            is_dir: true,
            readable: false,
            size: 0,
            media_type: None,
        };
        assert_eq!(
            validate_outgoing_file_probe("docs", &dir, 100 * 1_048_576).as_deref(),
            Some("Chưa hỗ trợ gửi thư mục (docs). Hãy nén thành .zip trước.")
        );

        let missing = OutgoingFileProbe {
            exists: false,
            is_dir: false,
            readable: false,
            size: 0,
            media_type: None,
        };
        assert_eq!(
            validate_outgoing_file_probe("missing.txt", &missing, 100 * 1_048_576).as_deref(),
            Some("Không đọc được tệp missing.txt.")
        );

        let empty = OutgoingFileProbe {
            exists: true,
            is_dir: false,
            readable: true,
            size: 0,
            media_type: None,
        };
        assert_eq!(
            validate_outgoing_file_probe("empty.bin", &empty, 100 * 1_048_576).as_deref(),
            Some("Tệp empty.bin rỗng (0 byte) nên không thể gửi.")
        );

        let huge = OutgoingFileProbe {
            exists: true,
            is_dir: false,
            readable: true,
            size: 210 * 1_048_576,
            media_type: None,
        };
        assert_eq!(
            validate_outgoing_file_probe("huge.bin", &huge, 200 * 1_048_576).as_deref(),
            Some("Tệp huge.bin vượt quá giới hạn 200 MB.")
        );

        let locked = OutgoingFileProbe {
            exists: true,
            is_dir: false,
            readable: false,
            size: 100,
            media_type: None,
        };
        assert_eq!(
            validate_outgoing_file_probe("locked.txt", &locked, 100 * 1_048_576).as_deref(),
            Some("Không đọc được tệp locked.txt.")
        );

        let ok = OutgoingFileProbe {
            exists: true,
            is_dir: false,
            readable: true,
            size: 1024,
            media_type: None,
        };
        assert_eq!(
            validate_outgoing_file_probe("ok.txt", &ok, 100 * 1_048_576),
            None
        );
    }

    #[test]
    fn file_download_key_prefers_conv_and_msg_then_url_then_name() {
        assert_eq!(
            file_download_key("3000901", "m1", Some("https://x/a.pdf"), "a.pdf"),
            "3000901|m1"
        );
        assert_eq!(
            file_download_key("", "m3", Some("https://x/only_url.pdf"), "fallback.pdf"),
            "https://x/only_url.pdf"
        );
        assert_eq!(
            file_download_key("3000901", "", None, "only_name.pdf"),
            "only_name.pdf"
        );
    }

    #[test]
    fn extract_media_candidates_dedupes_and_rejects_mismatches() {
        let photo = msg_with_kind(
            Kind::Photo {
                url: Some("https://cdn/1.png".to_owned()),
                width: 1,
                height: 1,
            },
            vec![
                "https://cdn/1.png",
                "https://cdn/2.png",
                "https://cdn/1.png",
            ],
        );
        assert_eq!(
            extract_media_candidates(MediaKind::Photo, &photo),
            Some(vec![
                "https://cdn/1.png".to_owned(),
                "https://cdn/2.png".to_owned(),
            ])
        );
        assert_eq!(extract_media_candidates(MediaKind::Video, &photo), None);
        assert_eq!(
            extract_media_candidates(MediaKind::VideoThumb, &photo),
            None
        );

        let video = msg_with_kind(
            Kind::Video {
                thumbnail: Some("https://cdn/t.png".to_owned()),
                duration: 5,
                url: Some("https://cdn/v.mp4".to_owned()),
            },
            vec!["https://cdn/v.mp4", "https://cdn/fb.mp4"],
        );
        assert_eq!(
            extract_media_candidates(MediaKind::VideoThumb, &video),
            Some(vec![
                "https://cdn/t.png".to_owned(),
                "https://cdn/v.mp4".to_owned(),
                "https://cdn/fb.mp4".to_owned(),
            ])
        );
        assert_eq!(
            extract_media_candidates(MediaKind::Video, &video),
            Some(vec![
                "https://cdn/v.mp4".to_owned(),
                "https://cdn/fb.mp4".to_owned(),
            ])
        );
        assert_eq!(extract_media_candidates(MediaKind::Photo, &video), None);

        let gif = msg_with_kind(
            Kind::Gif {
                url: Some("https://cdn/g.gif".to_owned()),
            },
            vec![],
        );
        assert_eq!(
            extract_media_candidates(MediaKind::Photo, &gif),
            Some(vec!["https://cdn/g.gif".to_owned()])
        );
        assert_eq!(extract_media_candidates(MediaKind::Video, &gif), None);
    }

    #[test]
    fn shared_media_memory_filters_links_without_url_and_sorts_newest_first() {
        let m1 = empty_msg(
            "1",
            100,
            Kind::Link {
                title: "OK".to_owned(),
                url: Some("https://example.com".to_owned()),
                thumbnail: None,
                description: String::new(),
                source: String::new(),
            },
            vec![],
        );
        let m2 = empty_msg(
            "2",
            200,
            Kind::Link {
                title: "NoURL".to_owned(),
                url: None,
                thumbnail: None,
                description: String::new(),
                source: String::new(),
            },
            vec![],
        );
        let page = shared_media_memory(&[m1, m2], SharedMediaKind::Links, 10);
        assert_eq!(page.items.len(), 1);
        assert_eq!(page.items[0].id, "1");
        assert!(!page.more);
        assert_eq!(page.cursor, None);
    }

    #[test]
    fn file_load_error_messages_match_swift() {
        assert!(FileLoadError::Http(404).is_permanent_gone());
        assert!(FileLoadError::Http(410).is_permanent_gone());
        assert!(FileLoadError::HostNotFound.is_permanent_gone());
        assert!(!FileLoadError::Http(500).is_permanent_gone());
        assert_eq!(
            FileLoadError::Http(500).user_message(),
            "Máy chủ trả lỗi HTTP 500 khi tải tệp."
        );
        assert_eq!(FileLoadError::Cancelled.user_message(), "Đã huỷ tải tệp.");
    }
}
