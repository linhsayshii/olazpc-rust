//! U15 (`media.jsonl`) test-host helpers, virtual filesystem/container detection, and
//! `MediaSnapshot` JSON encoders for `tests/cases.rs`.

use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::sync::{Arc, Mutex, PoisonError};

use olaz_core::{
    ComposerOutcome, FileFetchOutcome, FileLoadError, FileResolution, MediaCacheHit,
    MediaFetchOutcome, MediaKind, MediaResolution, OutgoingFileProbe, SharedMediaPage,
    UploadFileError, UploadedFileResult, UploadedPhotoResult, UploadedVideoResult, VideoMetadata,
    file_url_path, stable_hash,
};
use olaz_store::Store;
use olaz_wire::{ChatMessage, decode_stored_message, serialize_kind};
use serde_json::{Map, Value, json};
use tokio::sync::oneshot;

pub const MEDIA_DATA_ROOT: &str = "/olaz-media-data";
pub const MEDIA_INPUT_ROOT: &str = "/olaz-media-input";
pub const MEDIA_DOWNLOADS_ROOT: &str = "/olaz-media-downloads";

/// Replaces `<data>`, `<input>`, `<downloads>` with valid POSIX paths so `olaz-wire` URL parsing
/// accepts `file:///olaz-media-data/...`.
pub fn substitute_media_paths(val: &Value) -> Value {
    match val {
        Value::String(s) => Value::String(
            s.replace("<data>", MEDIA_DATA_ROOT)
                .replace("<input>", MEDIA_INPUT_ROOT)
                .replace("<downloads>", MEDIA_DOWNLOADS_ROOT),
        ),
        Value::Array(arr) => Value::Array(arr.iter().map(substitute_media_paths).collect()),
        Value::Object(obj) => Value::Object(
            obj.iter()
                .map(|(k, v)| (k.clone(), substitute_media_paths(v)))
                .collect(),
        ),
        other => other.clone(),
    }
}

/// Replaces virtual roots back with `<data>`, `<input>`, `<downloads>` for Case JSON matching.
pub fn normalize_media_paths(val: &Value) -> Value {
    match val {
        Value::String(s) => Value::String(
            s.replace(MEDIA_DATA_ROOT, "<data>")
                .replace(MEDIA_INPUT_ROOT, "<input>")
                .replace(MEDIA_DOWNLOADS_ROOT, "<downloads>"),
        ),
        Value::Array(arr) => Value::Array(arr.iter().map(normalize_media_paths).collect()),
        Value::Object(obj) => Value::Object(
            obj.iter()
                .map(|(k, v)| (k.clone(), normalize_media_paths(v)))
                .collect(),
        ),
        other => other.clone(),
    }
}

/// Standard base64 decoder (RFC 4648) used by `media.jsonl` `data_b64` fixtures.
pub fn decode_base64(input: &str) -> Option<Vec<u8>> {
    fn val(b: u8) -> Option<u8> {
        match b {
            b'A'..=b'Z' => Some(b - b'A'),
            b'a'..=b'z' => Some(b - b'a' + 26),
            b'0'..=b'9' => Some(b - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }
    let clean: Vec<u8> = input.bytes().filter(|b| !b.is_ascii_whitespace()).collect();
    if !clean.len().is_multiple_of(4) {
        return None;
    }
    let mut out = Vec::with_capacity(clean.len() / 4 * 3);
    for chunk in clean.chunks_exact(4) {
        let a = val(chunk[0])?;
        let b = val(chunk[1])?;
        out.push((a << 2) | (b >> 4));
        if chunk[2] != b'=' {
            let c = val(chunk[2])?;
            out.push((b << 4) | (c >> 2));
            if chunk[3] != b'=' {
                let d = val(chunk[3])?;
                out.push((c << 6) | d);
            }
        }
    }
    Some(out)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DetectedContainer {
    Jpeg,
    Png,
    Gif,
    Webp,
    Heic,
    Jxl,
    Mp4,
    Unknown,
}

impl DetectedContainer {
    pub fn detect(bytes: &[u8]) -> Self {
        if bytes.len() >= 8 && bytes.starts_with(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A])
        {
            return Self::Png;
        }
        if bytes.len() >= 3 && bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
            return Self::Jpeg;
        }
        if bytes.len() >= 6 && (bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a")) {
            return Self::Gif;
        }
        if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
            return Self::Webp;
        }
        if bytes.len() >= 12 && &bytes[4..8] == b"ftyp" {
            let brand = &bytes[8..12];
            if matches!(brand, b"heic" | b"heix" | b"mif1" | b"msf1") {
                return Self::Heic;
            }
            return Self::Mp4;
        }
        if bytes.len() >= 2 && bytes[0] == 0xFF && bytes[1] == 0x0A {
            return Self::Jxl;
        }
        Self::Unknown
    }

    pub fn media_ext(self, kind: MediaKind) -> &'static str {
        match self {
            Self::Jpeg => "jpg",
            Self::Png => "png",
            Self::Gif => "gif",
            Self::Webp => "webp",
            Self::Heic => "heic",
            Self::Jxl => "jxl",
            Self::Mp4 => "mp4",
            Self::Unknown => {
                if kind == MediaKind::Video {
                    "mp4"
                } else {
                    "jpg"
                }
            }
        }
    }

    pub fn file_ext(self) -> Option<&'static str> {
        match self {
            Self::Jpeg => Some("jpg"),
            Self::Png => Some("png"),
            Self::Gif => Some("gif"),
            Self::Webp => Some("webp"),
            Self::Heic => Some("heic"),
            Self::Jxl => Some("jxl"),
            Self::Mp4 => Some("mp4"),
            Self::Unknown => None,
        }
    }

    pub fn is_video(self) -> bool {
        self == Self::Mp4
    }

    pub fn is_valid_for(self, kind: MediaKind) -> bool {
        match kind {
            MediaKind::Video => self == Self::Mp4,
            MediaKind::Photo => matches!(
                self,
                Self::Jpeg | Self::Png | Self::Gif | Self::Webp | Self::Heic | Self::Jxl
            ),
            MediaKind::VideoThumb => matches!(
                self,
                Self::Jpeg
                    | Self::Png
                    | Self::Gif
                    | Self::Webp
                    | Self::Heic
                    | Self::Jxl
                    | Self::Mp4
            ),
        }
    }
}

/// Virtual filesystem + scripted queues for `media.jsonl` replay.
#[derive(Default)]
pub struct MediaTestState {
    pub active_file_specs: HashMap<String, Value>,
    pub image_dims_queue: VecDeque<Value>,
    pub video_meta_queue: VecDeque<Value>,
    pub upload_photo_queue: VecDeque<Value>,
    pub upload_video_queue: VecDeque<Value>,
    pub upload_file_queue: VecDeque<Value>,
    pub video_poster_queue: VecDeque<Value>,
    pub loader_map: HashMap<String, Value>,
    pub virtual_files: HashMap<String, Vec<u8>>,
    pub allowed_local_paths: HashSet<String>,
    pub held_uploads: Vec<oneshot::Sender<()>>,
}

impl MediaTestState {
    pub fn from_seed(
        host_results: Option<&Value>,
        existing_download_files: &[String],
        preseeded_media_cache: &[Value],
        allowed_local_files: &[Value],
    ) -> Self {
        let mut st = Self::default();
        if let Some(hr) = host_results.and_then(Value::as_object) {
            if let Some(arr) = hr.get("image_dimensions").and_then(Value::as_array) {
                st.image_dims_queue = arr.iter().cloned().collect();
            }
            if let Some(arr) = hr.get("video_metadata").and_then(Value::as_array) {
                st.video_meta_queue = arr.iter().cloned().collect();
            }
            if let Some(arr) = hr.get("upload_photo").and_then(Value::as_array) {
                st.upload_photo_queue = arr.iter().cloned().collect();
            }
            if let Some(arr) = hr.get("upload_video").and_then(Value::as_array) {
                st.upload_video_queue = arr.iter().cloned().collect();
            }
            if let Some(arr) = hr.get("upload_file").and_then(Value::as_array) {
                st.upload_file_queue = arr.iter().cloned().collect();
            }
            if let Some(arr) = hr.get("video_poster").and_then(Value::as_array) {
                st.video_poster_queue = arr.iter().cloned().collect();
            }
            if let Some(obj) = hr.get("loader_fetch").and_then(Value::as_object) {
                for (k, v) in obj {
                    st.loader_map.insert(k.clone(), v.clone());
                }
            }
        }

        for name in existing_download_files {
            st.virtual_files.insert(
                format!("{MEDIA_DOWNLOADS_ROOT}/{name}"),
                b"downloaded".to_vec(),
            );
        }

        for entry in preseeded_media_cache {
            let Some(key) = entry.get("key").and_then(Value::as_str) else {
                continue;
            };
            let ext = entry.get("ext").and_then(Value::as_str).unwrap_or("png");
            let bytes = extract_fixture_bytes(entry);
            let hash = stable_hash(key);
            st.virtual_files
                .insert(format!("{MEDIA_DATA_ROOT}/MediaCache/{hash}.{ext}"), bytes);
        }

        for entry in allowed_local_files {
            let Some(rel) = entry.get("rel_path").and_then(Value::as_str) else {
                continue;
            };
            let path = format!("{MEDIA_DATA_ROOT}/{rel}");
            let bytes = extract_fixture_bytes(entry);
            st.virtual_files.insert(path.clone(), bytes);
            st.allowed_local_paths.insert(path);
        }

        st
    }

    pub fn register_step_files(&mut self, files: &[Value]) -> Vec<String> {
        let mut paths = Vec::with_capacity(files.len());
        for spec in files {
            let name = spec
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("file.bin");
            let path = format!("{MEDIA_INPUT_ROOT}/{name}");
            self.active_file_specs.insert(path.clone(), spec.clone());
            paths.push(path);
        }
        paths
    }

    pub fn probe_outgoing(&self, path: &str) -> OutgoingFileProbe {
        let Some(spec) = self.active_file_specs.get(path) else {
            return OutgoingFileProbe {
                exists: false,
                is_dir: false,
                readable: false,
                size: 0,
                media_type: None,
            };
        };
        OutgoingFileProbe {
            exists: spec.get("exists").and_then(Value::as_bool).unwrap_or(true),
            is_dir: spec.get("is_dir").and_then(Value::as_bool).unwrap_or(false),
            readable: spec
                .get("readable")
                .and_then(Value::as_bool)
                .unwrap_or(true),
            size: spec.get("size").and_then(Value::as_i64).unwrap_or(1024),
            media_type: spec.get("type").and_then(Value::as_str).map(str::to_owned),
        }
    }

    pub fn pop_image_dims(&mut self) -> (i64, i64) {
        let Some(item) = self.image_dims_queue.pop_front() else {
            return (800, 600);
        };
        let w = item.get("width").and_then(Value::as_i64).unwrap_or(800);
        let h = item.get("height").and_then(Value::as_i64).unwrap_or(600);
        (w, h)
    }

    pub fn pop_video_meta(&mut self) -> VideoMetadata {
        let Some(item) = self.video_meta_queue.pop_front() else {
            return VideoMetadata {
                duration_ms: 0,
                width: 0,
                height: 0,
                has_thumb: false,
            };
        };
        VideoMetadata {
            duration_ms: item.get("duration_ms").and_then(Value::as_i64).unwrap_or(0),
            width: item.get("width").and_then(Value::as_i64).unwrap_or(0),
            height: item.get("height").and_then(Value::as_i64).unwrap_or(0),
            has_thumb: item
                .get("has_thumb")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        }
    }

    pub fn pop_upload_photo(&mut self) -> Result<UploadedPhotoResult, String> {
        let Some(item) = self.upload_photo_queue.pop_front() else {
            return Err("No scripted upload_photo".to_owned());
        };
        if let Some(err) = parse_upload_error_str(&item) {
            return Err(err);
        }
        Ok(UploadedPhotoResult {
            url: item
                .get("url")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
            msg_id: item
                .get("msg_id")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
            cli_msg_id: item
                .get("cli_msg_id")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
            width: item.get("width").and_then(Value::as_i64).unwrap_or(0),
            height: item.get("height").and_then(Value::as_i64).unwrap_or(0),
        })
    }

    pub fn pop_upload_video(&mut self) -> Result<UploadedVideoResult, String> {
        let Some(item) = self.upload_video_queue.pop_front() else {
            return Err("No scripted upload_video".to_owned());
        };
        if let Some(err) = parse_upload_error_str(&item) {
            return Err(err);
        }
        Ok(UploadedVideoResult {
            url: item
                .get("url")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
            thumb_url: item
                .get("thumb_url")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
            msg_id: item
                .get("msg_id")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
            cli_msg_id: item
                .get("cli_msg_id")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
            width: item.get("width").and_then(Value::as_i64).unwrap_or(0),
            height: item.get("height").and_then(Value::as_i64).unwrap_or(0),
            duration_ms: item.get("duration_ms").and_then(Value::as_i64).unwrap_or(0),
        })
    }

    pub fn take_upload_file_spec(&mut self) -> (Option<Value>, Option<oneshot::Receiver<()>>) {
        let Some(item) = self.upload_file_queue.pop_front() else {
            return (None, None);
        };
        let rx = if item.get("hold").and_then(Value::as_bool) == Some(true) {
            let (tx, rx) = oneshot::channel();
            self.held_uploads.push(tx);
            Some(rx)
        } else {
            None
        };
        (Some(item), rx)
    }

    pub fn release_uploads(&mut self, count: usize) {
        for _ in 0..count {
            if self.held_uploads.is_empty() {
                break;
            }
            let tx = self.held_uploads.remove(0);
            let _ = tx.send(());
        }
    }

    pub fn resolve_upload_file_spec(
        item: Option<Value>,
        client_id: Option<&str>,
    ) -> Result<UploadedFileResult, UploadFileError> {
        let Some(item) = item else {
            return Err(UploadFileError::Session {
                code: 500,
                message: "No scripted upload_file".to_owned(),
            });
        };
        if let Some(err) = parse_upload_file_error(&item) {
            return Err(err);
        }
        Ok(UploadedFileResult {
            url: item
                .get("url")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
            msg_id: item
                .get("msg_id")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
            cli_msg_id: item
                .get("cli_msg_id")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .unwrap_or_else(|| client_id.unwrap_or_default().to_owned()),
        })
    }

    pub fn cache_lookup(&mut self, hash_prefix: &str, kind: MediaKind) -> Option<MediaCacheHit> {
        let exts: &[&str] = if kind == MediaKind::Video {
            &["mp4", "mov", "m4v"]
        } else {
            &[
                "jpg", "jpeg", "jxl", "png", "webp", "gif", "heic", "mp4", "bin",
            ]
        };
        for ext in exts {
            let candidate = format!("{MEDIA_DATA_ROOT}/MediaCache/{hash_prefix}.{ext}");
            let Some(bytes) = self.virtual_files.get(&candidate) else {
                continue;
            };
            let container = DetectedContainer::detect(bytes);
            if container.is_valid_for(kind) {
                return Some(MediaCacheHit {
                    path: candidate,
                    is_video: container.is_video(),
                });
            }
            self.virtual_files.remove(&candidate);
        }
        None
    }

    pub fn check_local_file(&self, url: &str) -> (bool, String, bool) {
        let path = file_url_path(url);
        if self.allowed_local_paths.contains(&path)
            && let Some(bytes) = self.virtual_files.get(&path)
        {
            let is_video = DetectedContainer::detect(bytes).is_video();
            return (true, path, is_video);
        }
        (false, String::new(), false)
    }

    pub fn loader_fetch_media(
        &mut self,
        url: &str,
        kind: MediaKind,
        hash_prefix: &str,
    ) -> MediaFetchOutcome {
        let Some(item) = self.loader_map.get(url).cloned() else {
            return MediaFetchOutcome::PermanentGone;
        };
        if let Some(err) = parse_file_load_error(&item) {
            return if err.is_permanent_gone() {
                MediaFetchOutcome::PermanentGone
            } else {
                MediaFetchOutcome::Transient
            };
        }
        let bytes = extract_fixture_bytes(&item);
        if bytes.is_empty() {
            return MediaFetchOutcome::Transient;
        }
        let container = DetectedContainer::detect(&bytes);
        if !container.is_valid_for(kind) {
            return MediaFetchOutcome::Transient;
        }
        let ext = container.media_ext(kind);
        let dest = format!("{MEDIA_DATA_ROOT}/MediaCache/{hash_prefix}.{ext}");
        self.virtual_files.insert(dest.clone(), bytes);
        MediaFetchOutcome::Cached {
            path: dest,
            is_video: container.is_video(),
        }
    }

    pub fn pop_video_poster(&mut self) -> Option<String> {
        let item = self.video_poster_queue.pop_front()?;
        let rel = item.get("rel_path").and_then(Value::as_str)?;
        let path = format!("{MEDIA_DATA_ROOT}/{rel}");
        self.virtual_files
            .insert(path.clone(), b"\x89PNG\r\n\x1a\n".to_vec());
        Some(path)
    }

    pub fn loader_fetch_file(&mut self, url: &str) -> FileFetchOutcome {
        let Some(item) = self.loader_map.get(url).cloned() else {
            return FileFetchOutcome::Error(FileLoadError::Http(404));
        };
        if let Some(err) = parse_file_load_error(&item) {
            return FileFetchOutcome::Error(err);
        }
        let bytes = extract_fixture_bytes(&item);
        let container = DetectedContainer::detect(&bytes);
        let hash = stable_hash(url);
        let path = format!("{MEDIA_DATA_ROOT}/FilesCache/{hash}");
        self.virtual_files.insert(path.clone(), bytes);
        FileFetchOutcome::Fetched {
            cached_path: path,
            container_ext: container.file_ext().map(str::to_owned),
        }
    }

    pub fn stage_file(
        &mut self,
        source_path: &str,
        stem: &str,
        ext: Option<&str>,
    ) -> Option<String> {
        let file_name = match ext {
            Some(e) if !e.is_empty() => format!("{stem}.{e}"),
            _ => stem.to_owned(),
        };
        let dest = format!("{MEDIA_DATA_ROOT}/zcloud-preview/{file_name}");
        let bytes = self
            .virtual_files
            .get(source_path)
            .cloned()
            .unwrap_or_default();
        self.virtual_files.insert(dest.clone(), bytes);
        Some(dest)
    }
}

fn extract_fixture_bytes(entry: &Value) -> Vec<u8> {
    if let Some(b64) = entry.get("data_b64").and_then(Value::as_str)
        && let Some(bytes) = decode_base64(b64)
    {
        return bytes;
    }
    if let Some(utf8) = entry.get("data_utf8").and_then(Value::as_str) {
        return utf8.as_bytes().to_vec();
    }
    Vec::new()
}

fn parse_upload_error_str(item: &Value) -> Option<String> {
    if let Some(obj) = item.get("session_error").and_then(Value::as_object) {
        let code = obj.get("code").and_then(Value::as_i64).unwrap_or(500);
        let msg = obj
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or_default();
        return Some(format!("Zalo error {code}: {msg}"));
    }
    if let Some(code) = item.get("url_error").and_then(Value::as_i64) {
        return Some(format!("URLError({code})"));
    }
    if let Some(msg) = item.get("error").and_then(Value::as_str) {
        return Some(msg.to_owned());
    }
    None
}

fn parse_upload_file_error(item: &Value) -> Option<UploadFileError> {
    if let Some(obj) = item.get("session_error").and_then(Value::as_object) {
        let code = obj.get("code").and_then(Value::as_i64).unwrap_or(500);
        let message = obj
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        return Some(UploadFileError::Session { code, message });
    }
    if item.get("url_error").and_then(Value::as_i64).is_some() {
        return Some(UploadFileError::Network);
    }
    if let Some(msg) = item.get("error").and_then(Value::as_str) {
        return Some(UploadFileError::Other(msg.to_owned()));
    }
    None
}

fn parse_file_load_error(item: &Value) -> Option<FileLoadError> {
    if item.get("cancelled").and_then(Value::as_bool) == Some(true) {
        return Some(FileLoadError::Cancelled);
    }
    if item.get("host_not_found").and_then(Value::as_bool) == Some(true) {
        return Some(FileLoadError::HostNotFound);
    }
    if item.get("undecodable").and_then(Value::as_bool) == Some(true) {
        return Some(FileLoadError::Undecodable);
    }
    if item.get("timed_out").and_then(Value::as_bool) == Some(true) {
        return Some(FileLoadError::TimedOut);
    }
    if item.get("too_large").and_then(Value::as_bool) == Some(true) {
        return Some(FileLoadError::TooLarge);
    }
    if item.get("bad_url").and_then(Value::as_bool) == Some(true) {
        return Some(FileLoadError::BadUrl);
    }
    if let Some(status) = item.get("http_error").and_then(Value::as_u64) {
        return Some(FileLoadError::Http(u16::try_from(status).unwrap_or(500)));
    }
    if item.get("url_error").and_then(Value::as_i64).is_some() {
        return Some(FileLoadError::Other);
    }
    None
}

// MARK: - MediaSnapshot JSON encoders

pub fn encode_composer_outcome(outcome: &ComposerOutcome) -> Value {
    match outcome {
        ComposerOutcome::Done => json!({ "status": "done" }),
        ComposerOutcome::Cancelled => json!({ "status": "cancelled" }),
        ComposerOutcome::Failed(text) => json!({ "status": "failed", "text": text }),
        ComposerOutcome::Pending(text) => json!({ "status": "pending", "text": text }),
    }
}

pub fn encode_media_resolution(res: &MediaResolution) -> Value {
    match res {
        MediaResolution::File(path) => json!({ "state": "file", "path": path }),
        MediaResolution::Expired => json!({ "state": "expired" }),
        MediaResolution::Unavailable => json!({ "state": "unavailable" }),
        MediaResolution::Unsupported => json!({ "state": "unsupported" }),
    }
}

pub fn encode_file_resolution(res: &FileResolution) -> Value {
    match res {
        FileResolution::Ready(path) => json!({ "state": "ready", "path": path }),
        FileResolution::Expired => json!({ "state": "expired" }),
        FileResolution::Failed(text) => json!({ "state": "failed", "text": text }),
    }
}

pub fn encode_shared_media_page(page: Option<&SharedMediaPage>) -> Value {
    let Some(page) = page else {
        return Value::Null;
    };
    let items: Vec<Value> = page
        .items
        .iter()
        .map(|m| {
            let (kind_map, kind_tag) = serialize_kind(&m.kind);
            json!({
                "id": m.id,
                "conv_id": m.conversation_id,
                "kind_tag": kind_tag,
                "kind_detail": Value::Object(kind_map),
                "text": m.text,
                "date_ms": m.date_ms,
            })
        })
        .collect();
    json!({
        "items": items,
        "cursor": page.cursor,
        "more": page.more,
    })
}

/// Enriches a U6/MessageAction snapshot with `MediaSnapshot` fields (`kind_detail`,
/// `fallback_urls`, `cloud_file_limit`, `downloaded_file_paths`, `results`).
pub fn enrich_media_snapshot(
    obj: &mut Map<String, Value>,
    windows: &HashMap<String, Vec<ChatMessage>>,
    store_arc: Option<Arc<Mutex<Store>>>,
    cloud_file_limit: Option<i64>,
    downloaded_file_paths: &BTreeMap<String, String>,
    results: &Map<String, Value>,
) {
    if let Some(Value::Object(msgs_obj)) = obj.get_mut("messages") {
        for (conv_id, list) in windows {
            if let Some(Value::Array(arr)) = msgs_obj.get_mut(conv_id)
                && arr.len() == list.len()
            {
                for (m, base) in list.iter().zip(arr.iter_mut()) {
                    if let Value::Object(dict) = base {
                        let (kind_map, _) = serialize_kind(&m.kind);
                        dict.insert("kind_detail".to_owned(), Value::Object(kind_map));
                        dict.insert(
                            "fallback_urls".to_owned(),
                            Value::Array(
                                m.fallback_urls
                                    .iter()
                                    .map(|u| Value::String(u.clone()))
                                    .collect(),
                            ),
                        );
                    }
                }
            }
        }
    }

    if let Some(store_arc) = store_arc
        && let Some(Value::Object(store_obj)) = obj.get_mut("store")
        && let Some(Value::Array(arr)) = store_obj.get_mut("messages")
    {
        let mut stored_msgs = store_arc
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .load_all_messages()
            .unwrap_or_default();
        stored_msgs.sort_by(|a, b| {
            a.conv_id
                .as_bytes()
                .cmp(b.conv_id.as_bytes())
                .then_with(|| a.ts_ms.cmp(&b.ts_ms))
                .then_with(|| a.id.as_bytes().cmp(b.id.as_bytes()))
        });
        if arr.len() == stored_msgs.len() {
            for (row, base) in stored_msgs.iter().zip(arr.iter_mut()) {
                if let Value::Object(dict) = base {
                    let wire_row = olaz_wire::StoredMessage {
                        id: row.id.clone(),
                        conv_id: row.conv_id.clone(),
                        client_id: row.client_id.clone(),
                        sender_id: row.sender_id.clone(),
                        sender_name: row.sender_name.clone(),
                        sender_avatar: row.sender_avatar.clone(),
                        is_mine: row.is_mine,
                        text: row.text.clone(),
                        kind_tag: row.kind_tag.clone(),
                        ts_ms: row.ts_ms,
                        status: row.status.clone(),
                        raw_json_data: row.raw_json_data.clone(),
                    };
                    if let Some(decoded) = decode_stored_message(&wire_row) {
                        let (kind_map, _) = serialize_kind(&decoded.kind);
                        dict.insert("kind_detail".to_owned(), Value::Object(kind_map));
                        dict.insert(
                            "fallback_urls".to_owned(),
                            Value::Array(
                                decoded
                                    .fallback_urls
                                    .iter()
                                    .map(|u| Value::String(u.clone()))
                                    .collect(),
                            ),
                        );
                    } else {
                        dict.insert("kind_detail".to_owned(), Value::Null);
                        dict.insert("fallback_urls".to_owned(), Value::Array(Vec::new()));
                    }
                }
            }
        }
    }

    obj.insert(
        "cloud_file_limit".to_owned(),
        cloud_file_limit.map_or(Value::Null, Value::from),
    );
    let mut dl_map = Map::new();
    for (k, v) in downloaded_file_paths {
        dl_map.insert(k.clone(), Value::String(v.clone()));
    }
    obj.insert("downloaded_file_paths".to_owned(), Value::Object(dl_map));
    obj.insert("results".to_owned(), Value::Object(results.clone()));
}
