//! Error type for the store (mirrors `ZaloSQLiteError` plus the cases rusqlite needs).

/// Result alias used across the crate.
pub type Result<T> = std::result::Result<T, StoreError>;

/// Failures surfaced by [`crate::Store`].
#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    /// The store was closed (`Store::close`); Swift threw `openFailed("closed")`.
    #[error("SQLite store is closed")]
    Closed,
    /// Any SQLite failure (open, prepare, step).
    #[error("SQLite error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    /// Creating the parent directory of the database file failed.
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    /// JSON (de)serialization failure for preference values.
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),
}
