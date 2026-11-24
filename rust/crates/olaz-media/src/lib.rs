//! Media / download network and disk-cache layer (Swift `MediaLoader`, `DoHResolver`,
//! `PinnedHTTPSClient`, `DownloadManager`, `SecureStream`), wave 5c.
//!
//! * [`MediaCore`]: image bytes (`data`), the files cache (`local_file`), header downloads and
//!   staged downloads with the official client's failure codes.
//! * DNS policy identical to Swift: system DNS first (probed), DoH fallback with dead-host
//!   marking, only for Zalo CDN hosts; the pinned connection is a reqwest client resolving through
//!   the DoH answer while SNI / certificate validation stay on the real hostname.
//! * On-disk layout unchanged (`<stableHash>.<ext>`, `.<id>.part`), see [`cached_file_name`].
//! * Logs are shape-only (ADR-008): never URLs with query strings, headers or bodies.

mod core;
mod doh;
mod error;
mod files;
mod flight;
mod naming;
mod net;
mod secure;

pub use crate::core::{
    DEFAULT_FILES_CACHE_LIMIT, DataRequest, DownloadOutcome, DownloadRequest, DownloadSource,
    FILE_IDLE, FileRequest, HeadersRequest, IMAGE_DEADLINE, IMAGE_IDLE, MAX_FILE_BYTES, MediaCore,
    MediaHooks, MediaOptions, PHOTO_BYTE_CAP,
};
pub use crate::doh::{DEFAULT_ENDPOINTS, DohResolver};
pub use crate::error::{Failure, MediaError, NetKind, ResolveError};
pub use crate::files::{STALE_PART_AGE, trim_files};
pub use crate::flight::ProgressFn;
pub use crate::naming::{
    DOH_HOST_SUFFIXES, cached_file_name, is_zalo_cdn, normalize_url, redirect_headers,
    sanitize_headers, stable_hash,
};
pub use crate::net::{MediaConfig, USER_AGENT};
pub use crate::secure::{
    Algorithm, DecryptError, GCM_ONE_SHOT_CAP, SecureChoice, SecureSpec, encrypt_e2ee_file,
};
