//! SQLite store for Olaz (port of `ZaloSQLiteStore.swift`).
//!
//! Same on-disk format as the Swift app (ADR-006): identical `CREATE` statements,
//! PRAGMAs and queries, so a database written by either implementation opens in
//! the other. [`Store`] owns a `rusqlite::Connection` (`Send`, not `Sync`); the
//! async/actor wrapper lives in a later layer.

mod error;
mod helpers;
pub mod model;
pub mod schema;
pub mod search_text;
mod store;

pub use error::{Result, StoreError};
pub use model::{
    CloudMediaQuery, MessagesAround, SaveOptions, SharedMediaPage, StoredCloudConversationSummary,
    StoredCloudMediaItem, StoredConversation, StoredMessage,
};
pub use search_text::{
    fold_search_text, folded_contains, is_swift_whitespace_or_newline, search_text_contains_folded,
    trim_search_query,
};
pub use store::{ReadOnlyStore, Store};

#[cfg(test)]
mod tests;
