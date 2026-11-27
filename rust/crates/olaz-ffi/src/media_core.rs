//! UniFFI records and pure helpers for U15 media upload/download, single-flight resolver,
//! downloaded-file tracking, and shared media (ADR-031).

use olaz_core::{
    FileFetchOutcome, FileLoadError, MediaCacheHit, MediaFetchOutcome, OutgoingFileProbe,
    SharedMediaPage, UploadFileError, UploadedFileResult, UploadedPhotoResult, UploadedVideoResult,
    VideoMetadata, file_download_key, sanitized_file_name, validate_outgoing_file_probe,
};

use crate::chat::ChatMessageRecord;

/// One entry in `downloaded_file_paths` (`key -> path`).
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct DownloadedFilePathEntryRecord {
    pub key: String,
    pub path: String,
}

/// One page of shared-media messages (`SharedMediaPage`).
#[derive(Clone, Debug, uniffi::Record)]
pub struct SharedMediaPageRecord {
    pub items: Vec<ChatMessageRecord>,
    pub cursor: Option<String>,
    pub more: bool,
}

impl From<SharedMediaPage> for SharedMediaPageRecord {
    fn from(p: SharedMediaPage) -> Self {
        Self {
            items: p.items.into_iter().map(ChatMessageRecord::from).collect(),
            cursor: p.cursor,
            more: p.more,
        }
    }
}

/// Host probe result for an outgoing local file.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct OutgoingFileProbeRecord {
    pub exists: bool,
    pub is_dir: bool,
    pub readable: bool,
    pub size: i64,
    pub media_type: Option<String>,
}

impl From<OutgoingFileProbeRecord> for OutgoingFileProbe {
    fn from(r: OutgoingFileProbeRecord) -> Self {
        Self {
            exists: r.exists,
            is_dir: r.is_dir,
            readable: r.readable,
            size: r.size,
            media_type: r.media_type,
        }
    }
}

/// Pixel dimensions returned by `media_image_dimensions`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Record)]
pub struct ImageDimensionsRecord {
    pub width: i64,
    pub height: i64,
}

/// Video metadata returned by `media_video_metadata`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Record)]
pub struct VideoMetadataRecord {
    pub duration_ms: i64,
    pub width: i64,
    pub height: i64,
    pub has_thumb: bool,
}

impl From<VideoMetadataRecord> for VideoMetadata {
    fn from(r: VideoMetadataRecord) -> Self {
        Self {
            duration_ms: r.duration_ms,
            width: r.width,
            height: r.height,
            has_thumb: r.has_thumb,
        }
    }
}

/// Result of `CoreHost::media_upload_photo`.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum UploadPhotoOutcomeRecord {
    Ok {
        url: String,
        msg_id: String,
        cli_msg_id: String,
        width: i64,
        height: i64,
    },
    Err {
        message: String,
    },
}

impl From<UploadPhotoOutcomeRecord> for Result<UploadedPhotoResult, String> {
    fn from(r: UploadPhotoOutcomeRecord) -> Self {
        match r {
            UploadPhotoOutcomeRecord::Ok {
                url,
                msg_id,
                cli_msg_id,
                width,
                height,
            } => Ok(UploadedPhotoResult {
                url,
                msg_id,
                cli_msg_id,
                width,
                height,
            }),
            UploadPhotoOutcomeRecord::Err { message } => Err(message),
        }
    }
}

/// Result of `CoreHost::media_upload_video`.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum UploadVideoOutcomeRecord {
    Ok {
        url: String,
        thumb_url: String,
        msg_id: String,
        cli_msg_id: String,
        width: i64,
        height: i64,
        duration_ms: i64,
    },
    Err {
        message: String,
    },
}

impl From<UploadVideoOutcomeRecord> for Result<UploadedVideoResult, String> {
    fn from(r: UploadVideoOutcomeRecord) -> Self {
        match r {
            UploadVideoOutcomeRecord::Ok {
                url,
                thumb_url,
                msg_id,
                cli_msg_id,
                width,
                height,
                duration_ms,
            } => Ok(UploadedVideoResult {
                url,
                thumb_url,
                msg_id,
                cli_msg_id,
                width,
                height,
                duration_ms,
            }),
            UploadVideoOutcomeRecord::Err { message } => Err(message),
        }
    }
}

/// Result of `CoreHost::media_upload_file`.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum UploadFileOutcomeRecord {
    Ok {
        url: String,
        msg_id: String,
        cli_msg_id: String,
    },
    SessionError {
        code: i64,
        message: String,
    },
    NetworkError,
    OtherError {
        message: String,
    },
}

impl From<UploadFileOutcomeRecord> for Result<UploadedFileResult, UploadFileError> {
    fn from(r: UploadFileOutcomeRecord) -> Self {
        match r {
            UploadFileOutcomeRecord::Ok {
                url,
                msg_id,
                cli_msg_id,
            } => Ok(UploadedFileResult {
                url,
                msg_id,
                cli_msg_id,
            }),
            UploadFileOutcomeRecord::SessionError { code, message } => {
                Err(UploadFileError::Session { code, message })
            }
            UploadFileOutcomeRecord::NetworkError => Err(UploadFileError::Network),
            UploadFileOutcomeRecord::OtherError { message } => Err(UploadFileError::Other(message)),
        }
    }
}

/// Cached media hit returned by `CoreHost::media_cache_lookup`.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct MediaCacheHitRecord {
    pub path: String,
    pub is_video: bool,
}

impl From<MediaCacheHitRecord> for MediaCacheHit {
    fn from(r: MediaCacheHitRecord) -> Self {
        Self {
            path: r.path,
            is_video: r.is_video,
        }
    }
}

/// Result of `CoreHost::media_check_local_file`.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct LocalFileCheckRecord {
    pub allowed: bool,
    pub path: String,
    pub is_video: bool,
}

/// Result of `CoreHost::media_loader_fetch_media`.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum MediaFetchOutcomeRecord {
    Cached { path: String, is_video: bool },
    PermanentGone,
    Transient,
}

impl From<MediaFetchOutcomeRecord> for MediaFetchOutcome {
    fn from(r: MediaFetchOutcomeRecord) -> Self {
        match r {
            MediaFetchOutcomeRecord::Cached { path, is_video } => Self::Cached { path, is_video },
            MediaFetchOutcomeRecord::PermanentGone => Self::PermanentGone,
            MediaFetchOutcomeRecord::Transient => Self::Transient,
        }
    }
}

/// Typed load error kind for `resolve_file`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum FileLoadErrorKindRecord {
    Http { code: u16 },
    HostNotFound,
    Undecodable,
    TimedOut,
    TooLarge,
    BadUrl,
    Cancelled,
    Other,
}

impl From<FileLoadErrorKindRecord> for FileLoadError {
    fn from(r: FileLoadErrorKindRecord) -> Self {
        match r {
            FileLoadErrorKindRecord::Http { code } => Self::Http(code),
            FileLoadErrorKindRecord::HostNotFound => Self::HostNotFound,
            FileLoadErrorKindRecord::Undecodable => Self::Undecodable,
            FileLoadErrorKindRecord::TimedOut => Self::TimedOut,
            FileLoadErrorKindRecord::TooLarge => Self::TooLarge,
            FileLoadErrorKindRecord::BadUrl => Self::BadUrl,
            FileLoadErrorKindRecord::Cancelled => Self::Cancelled,
            FileLoadErrorKindRecord::Other => Self::Other,
        }
    }
}

/// Result of `CoreHost::media_loader_fetch_file`.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum FileFetchOutcomeRecord {
    Fetched {
        cached_path: String,
        container_ext: Option<String>,
    },
    Error {
        kind: FileLoadErrorKindRecord,
    },
}

impl From<FileFetchOutcomeRecord> for FileFetchOutcome {
    fn from(r: FileFetchOutcomeRecord) -> Self {
        match r {
            FileFetchOutcomeRecord::Fetched {
                cached_path,
                container_ext,
            } => Self::Fetched {
                cached_path,
                container_ext,
            },
            FileFetchOutcomeRecord::Error { kind } => Self::Error(kind.into()),
        }
    }
}

// MARK: - Pure UniFFI free helpers

#[uniffi::export]
#[must_use]
pub fn media_file_download_key(
    conv_id: String,
    msg_id: String,
    url: Option<String>,
    name: String,
) -> String {
    file_download_key(&conv_id, &msg_id, url.as_deref(), &name)
}

#[uniffi::export]
#[must_use]
pub fn media_sanitized_file_name(raw_name: String, fallback_extension: Option<String>) -> String {
    sanitized_file_name(&raw_name, fallback_extension.as_deref())
}

#[uniffi::export]
#[must_use]
pub fn media_validate_outgoing_file_probe(
    name: String,
    probe: OutgoingFileProbeRecord,
    max_bytes: i64,
) -> Option<String> {
    let p: OutgoingFileProbe = probe.into();
    validate_outgoing_file_probe(&name, &p, max_bytes)
}

#[uniffi::export]
#[must_use]
pub fn media_file_load_error_is_permanent_gone(kind: FileLoadErrorKindRecord) -> bool {
    FileLoadError::from(kind).is_permanent_gone()
}

#[uniffi::export]
#[must_use]
pub fn media_file_load_error_user_message(kind: FileLoadErrorKindRecord) -> String {
    FileLoadError::from(kind).user_message()
}
