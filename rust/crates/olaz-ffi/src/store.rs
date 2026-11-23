//! `CoreStore`: the SQLite store (`olaz-store`) as a Swift object.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use olaz_store::{ReadOnlyStore, SaveOptions, Store, StoredConversation, StoredMessage};

use olaz_wire::{ChatMessage, decode_stored_message, encode_chat_message};

use crate::chat::ChatMessageRecord;
use crate::error::CoreError;
use crate::runtime::blocking;

/// One row of the `conversations` table.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ConversationRow {
    pub id: String,
    pub is_group: bool,
    pub name: String,
    pub avatar: String,
    pub pinned: bool,
    pub members: i64,
    pub unread: i64,
    pub preview_text: String,
    pub preview_ts_ms: i64,
    pub preview_from_me: bool,
    pub updated_at_ms: i64,
}

/// One row of the `messages` table. `raw_json` is the UTF-8 canonical message JSON.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MessageRow {
    pub id: String,
    pub conv_id: String,
    pub client_id: String,
    pub sender_id: String,
    pub sender_name: String,
    pub sender_avatar: String,
    pub is_mine: bool,
    pub text: String,
    pub kind_tag: String,
    pub ts_ms: i64,
    pub status: String,
    pub raw_json: Vec<u8>,
}

impl From<StoredConversation> for ConversationRow {
    fn from(c: StoredConversation) -> Self {
        Self {
            id: c.id,
            is_group: c.is_group,
            name: c.name,
            avatar: c.avatar,
            pinned: c.pinned,
            members: c.members,
            unread: c.unread,
            preview_text: c.preview_text,
            preview_ts_ms: c.preview_ts_ms,
            preview_from_me: c.preview_from_me,
            updated_at_ms: c.updated_at_ms,
        }
    }
}

impl From<ConversationRow> for StoredConversation {
    fn from(c: ConversationRow) -> Self {
        Self {
            id: c.id,
            is_group: c.is_group,
            name: c.name,
            avatar: c.avatar,
            pinned: c.pinned,
            members: c.members,
            unread: c.unread,
            preview_text: c.preview_text,
            preview_ts_ms: c.preview_ts_ms,
            preview_from_me: c.preview_from_me,
            updated_at_ms: c.updated_at_ms,
        }
    }
}

impl From<StoredMessage> for MessageRow {
    fn from(m: StoredMessage) -> Self {
        Self {
            id: m.id,
            conv_id: m.conv_id,
            client_id: m.client_id,
            sender_id: m.sender_id,
            sender_name: m.sender_name,
            sender_avatar: m.sender_avatar,
            is_mine: m.is_mine,
            text: m.text,
            kind_tag: m.kind_tag,
            ts_ms: m.ts_ms,
            status: m.status,
            raw_json: m.raw_json_data,
        }
    }
}

impl From<MessageRow> for StoredMessage {
    fn from(m: MessageRow) -> Self {
        Self {
            id: m.id,
            conv_id: m.conv_id,
            client_id: m.client_id,
            sender_id: m.sender_id,
            sender_name: m.sender_name,
            sender_avatar: m.sender_avatar,
            is_mine: m.is_mine,
            text: m.text,
            kind_tag: m.kind_tag,
            ts_ms: m.ts_ms,
            status: m.status,
            raw_json_data: m.raw_json,
        }
    }
}

impl From<olaz_wire::StoredMessage> for MessageRow {
    fn from(m: olaz_wire::StoredMessage) -> Self {
        Self {
            id: m.id,
            conv_id: m.conv_id,
            client_id: m.client_id,
            sender_id: m.sender_id,
            sender_name: m.sender_name,
            sender_avatar: m.sender_avatar,
            is_mine: m.is_mine,
            text: m.text,
            kind_tag: m.kind_tag,
            ts_ms: m.ts_ms,
            status: m.status,
            raw_json: m.raw_json_data,
        }
    }
}

/// A stored message decoded in Rust. `row_id` / `row_client_id` are the table columns (callers match on them).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct StoredChat {
    pub message: ChatMessageRecord,
    pub row_id: String,
    pub row_client_id: String,
}

/// Typed `messages_around` result.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct StoredChatAround {
    pub messages: Vec<StoredChat>,
    pub has_more_older: bool,
}

/// `decodeStoredMessage` for a batch: rows whose JSON cannot be decoded are dropped (as Swift's `compactMap`).
fn decode_rows(rows: Vec<StoredMessage>) -> Vec<StoredChat> {
    rows.into_iter()
        .filter_map(|m| {
            let wire = olaz_wire::StoredMessage {
                id: m.id,
                conv_id: m.conv_id,
                client_id: m.client_id,
                sender_id: m.sender_id,
                sender_name: m.sender_name,
                sender_avatar: m.sender_avatar,
                is_mine: m.is_mine,
                text: m.text,
                kind_tag: m.kind_tag,
                ts_ms: m.ts_ms,
                status: m.status,
                raw_json_data: m.raw_json_data,
            };
            let message = decode_stored_message(&wire)?;
            Some(StoredChat {
                message: message.into(),
                row_id: wire.id,
                row_client_id: wire.client_id,
            })
        })
        .collect()
}

/// Result of `messages_around`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MessagesAroundRow {
    pub messages: Vec<MessageRow>,
    pub has_more_older: bool,
}

/// SQLite store handle. Methods are `async` (they run on the blocking pool); `open` is sync but
/// only creates/opens a file, so call it from a background task on first launch.
#[derive(uniffi::Object)]
pub struct CoreStore {
    inner: Arc<Mutex<Store>>,
    /// Separate read-only connection for the synchronous snapshot read (never waits on a writer).
    reader: Option<Mutex<ReadOnlyStore>>,
}

fn lock(m: &Mutex<Store>) -> MutexGuard<'_, Store> {
    // A panic while holding the lock cannot leave SQLite in a half state (transactions roll back).
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

#[uniffi::export]
impl CoreStore {
    /// Opens (creating if needed) the database at `path`; same schema as the Swift app.
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Arc<Self>, CoreError> {
        let store = Store::open(&path)?;
        let reader = ReadOnlyStore::open(&path).map(Mutex::new);
        Ok(Arc::new(Self {
            inner: Arc::new(Mutex::new(store)),
            reader,
        }))
    }

    pub async fn load_conversations(&self) -> Result<Vec<ConversationRow>, CoreError> {
        let db = Arc::clone(&self.inner);
        let rows = blocking(move || lock(&db).load_conversations()).await??;
        Ok(rows.into_iter().map(Into::into).collect())
    }

    pub async fn save_conversations(&self, items: Vec<ConversationRow>) -> Result<(), CoreError> {
        let db = Arc::clone(&self.inner);
        let items: Vec<StoredConversation> = items.into_iter().map(Into::into).collect();
        blocking(move || lock(&db).save_conversations(&items)).await??;
        Ok(())
    }

    /// Messages of `conv_id`, oldest to newest; `before_ts_ms` fetches strictly older rows;
    /// `limit` is clamped to 1...500.
    pub async fn messages(
        &self,
        conv_id: String,
        before_ts_ms: Option<i64>,
        limit: i64,
    ) -> Result<Vec<MessageRow>, CoreError> {
        let db = Arc::clone(&self.inner);
        let rows = blocking(move || lock(&db).messages(&conv_id, before_ts_ms, limit)).await??;
        Ok(rows.into_iter().map(Into::into).collect())
    }

    pub async fn save_messages(&self, items: Vec<MessageRow>) -> Result<(), CoreError> {
        let db = Arc::clone(&self.inner);
        let items: Vec<StoredMessage> = items.into_iter().map(Into::into).collect();
        blocking(move || lock(&db).save_messages(&items)).await??;
        Ok(())
    }

    pub async fn preference_string(&self, key: String) -> Result<Option<String>, CoreError> {
        let db = Arc::clone(&self.inner);
        Ok(blocking(move || lock(&db).get_preference_string(&key)).await??)
    }

    pub async fn set_preference_string(&self, key: String, value: String) -> Result<(), CoreError> {
        let db = Arc::clone(&self.inner);
        blocking(move || lock(&db).set_preference_string(&key, &value)).await??;
        Ok(())
    }
    /// Like `save_messages` with the Swift flags: `skip_twin_checks` (bulk fast path) and
    /// `preserve_existing_reactions`.
    pub async fn save_messages_with(
        &self,
        items: Vec<MessageRow>,
        skip_twin_checks: bool,
        preserve_existing_reactions: bool,
    ) -> Result<(), CoreError> {
        let db = Arc::clone(&self.inner);
        let items: Vec<StoredMessage> = items.into_iter().map(Into::into).collect();
        let opts = SaveOptions {
            skip_twin_checks,
            preserve_existing_reactions,
        };
        blocking(move || lock(&db).save_messages_with(&items, opts)).await??;
        Ok(())
    }

    /// Case-insensitive search in one conversation, newest first (`limit` clamped to 1...500).
    pub async fn search_messages(
        &self,
        conv_id: String,
        query: String,
        limit: i64,
    ) -> Result<Vec<MessageRow>, CoreError> {
        let db = Arc::clone(&self.inner);
        let rows = blocking(move || lock(&db).search_messages(&conv_id, &query, limit)).await??;
        Ok(rows.into_iter().map(Into::into).collect())
    }

    /// Synchronous snapshot read of the newest `limit` messages (oldest first) through the read-only connection,
    /// decoded to typed messages. `None` when there is no reader or the query failed. Takes well under a millisecond
    /// for a screenful, so it is safe on the main thread (it never waits on the writer).
    pub fn read_chat_messages_now(
        &self,
        conv_id: String,
        before_ts_ms: Option<i64>,
        limit: i64,
    ) -> Option<Vec<StoredChat>> {
        let reader = self.reader.as_ref()?;
        let rows = reader
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .messages_now(&conv_id, before_ts_ms, limit)?;
        Some(decode_rows(rows))
    }

    /// [`CoreStore::messages`] decoded to typed messages in Rust (no JSON reaches Swift).
    pub async fn messages_chat(
        &self,
        conv_id: String,
        before_ts_ms: Option<i64>,
        limit: i64,
    ) -> Result<Vec<StoredChat>, CoreError> {
        let db = Arc::clone(&self.inner);
        Ok(blocking(move || {
            Ok::<_, olaz_store::StoreError>(decode_rows(lock(&db).messages(
                &conv_id,
                before_ts_ms,
                limit,
            )?))
        })
        .await??)
    }

    /// [`CoreStore::search_messages`] decoded to typed messages.
    pub async fn search_messages_chat(
        &self,
        conv_id: String,
        query: String,
        limit: i64,
    ) -> Result<Vec<StoredChat>, CoreError> {
        let db = Arc::clone(&self.inner);
        Ok(blocking(move || {
            Ok::<_, olaz_store::StoreError>(decode_rows(
                lock(&db).search_messages(&conv_id, &query, limit)?,
            ))
        })
        .await??)
    }

    /// [`CoreStore::messages_around`] decoded to typed messages.
    pub async fn messages_around_chat(
        &self,
        conv_id: String,
        target_ts_ms: i64,
        before_oldest_ts_ms: Option<i64>,
        context_before: i64,
        max_window: i64,
    ) -> Result<StoredChatAround, CoreError> {
        let db = Arc::clone(&self.inner);
        Ok(blocking(move || {
            let r = lock(&db).messages_around(
                &conv_id,
                target_ts_ms,
                before_oldest_ts_ms,
                context_before,
                max_window,
            )?;
            Ok::<_, olaz_store::StoreError>(StoredChatAround {
                messages: decode_rows(r.messages),
                has_more_older: r.has_more_older,
            })
        })
        .await??)
    }

    /// Saves typed messages: each is encoded to the canonical JSON row in Rust (`encodeChatMessage`; rows that cannot
    /// be encoded are skipped). Flags as `save_messages_with`.
    pub async fn save_chat_messages(
        &self,
        items: Vec<ChatMessageRecord>,
        skip_twin_checks: bool,
        preserve_existing_reactions: bool,
    ) -> Result<(), CoreError> {
        let db = Arc::clone(&self.inner);
        let opts = SaveOptions {
            skip_twin_checks,
            preserve_existing_reactions,
        };
        blocking(move || {
            let rows: Vec<StoredMessage> = items
                .iter()
                .filter_map(|r| {
                    let msg = ChatMessage::from(r);
                    encode_chat_message(&msg, "")
                })
                .map(|w| StoredMessage {
                    id: w.id,
                    conv_id: w.conv_id,
                    client_id: w.client_id,
                    sender_id: w.sender_id,
                    sender_name: w.sender_name,
                    sender_avatar: w.sender_avatar,
                    is_mine: w.is_mine,
                    text: w.text,
                    kind_tag: w.kind_tag,
                    ts_ms: w.ts_ms,
                    status: w.status,
                    raw_json_data: w.raw_json_data,
                })
                .collect();
            lock(&db).save_messages_with(&rows, opts)
        })
        .await??;
        Ok(())
    }

    /// Window from `target_ts_ms` upward plus `context_before` earlier messages (Swift defaults
    /// 25 / 3000).
    pub async fn messages_around(
        &self,
        conv_id: String,
        target_ts_ms: i64,
        before_oldest_ts_ms: Option<i64>,
        context_before: i64,
        max_window: i64,
    ) -> Result<MessagesAroundRow, CoreError> {
        let db = Arc::clone(&self.inner);
        let r = blocking(move || {
            lock(&db).messages_around(
                &conv_id,
                target_ts_ms,
                before_oldest_ts_ms,
                context_before,
                max_window,
            )
        })
        .await??;
        Ok(MessagesAroundRow {
            messages: r.messages.into_iter().map(Into::into).collect(),
            has_more_older: r.has_more_older,
        })
    }

    /// One message by server id or client id.
    pub async fn message(
        &self,
        conv_id: String,
        id_or_client_id: String,
    ) -> Result<Option<MessageRow>, CoreError> {
        let db = Arc::clone(&self.inner);
        let m = blocking(move || lock(&db).message(&conv_id, &id_or_client_id)).await??;
        Ok(m.map(Into::into))
    }

    pub async fn delete_message(&self, conv_id: String, id: String) -> Result<(), CoreError> {
        let db = Arc::clone(&self.inner);
        blocking(move || lock(&db).delete_message(&conv_id, &id)).await??;
        Ok(())
    }

    pub async fn mark_recalled(
        &self,
        conv_id: String,
        id: String,
        cli_msg_id: String,
    ) -> Result<(), CoreError> {
        let db = Arc::clone(&self.inner);
        blocking(move || lock(&db).mark_recalled(&conv_id, &id, &cli_msg_id)).await??;
        Ok(())
    }

    /// Replaces `$.reactions` of a stored message with `reactions_json` (UTF-8 JSON array).
    pub async fn update_message_reactions_json(
        &self,
        conv_id: String,
        id: String,
        reactions_json: Vec<u8>,
    ) -> Result<(), CoreError> {
        let db = Arc::clone(&self.inner);
        blocking(move || lock(&db).update_message_reactions_json(&conv_id, &id, &reactions_json))
            .await??;
        Ok(())
    }

    /// Re-keys a local message to its server id; true when a row changed.
    pub async fn upgrade_message_id(
        &self,
        conv_id: String,
        old_id: String,
        new_id: String,
        client_id: String,
    ) -> Result<bool, CoreError> {
        let db = Arc::clone(&self.inner);
        Ok(
            blocking(move || lock(&db).upgrade_message_id(&conv_id, &old_id, &new_id, &client_id))
                .await??,
        )
    }

    /// The subset of `ids` already stored for `conv_id` (server or client ids).
    pub async fn existing_message_ids(
        &self,
        conv_id: String,
        ids: Vec<String>,
    ) -> Result<Vec<String>, CoreError> {
        let db = Arc::clone(&self.inner);
        let set = blocking(move || lock(&db).existing_message_ids(&conv_id, &ids)).await??;
        let mut out: Vec<String> = set.into_iter().collect();
        out.sort();
        Ok(out)
    }

    pub async fn upsert_conversation(&self, item: ConversationRow) -> Result<(), CoreError> {
        let db = Arc::clone(&self.inner);
        let item: StoredConversation = item.into();
        blocking(move || lock(&db).upsert_conversation(&item)).await??;
        Ok(())
    }

    pub async fn set_conversation_unread(&self, id: String, unread: i64) -> Result<(), CoreError> {
        let db = Arc::clone(&self.inner);
        blocking(move || lock(&db).set_conversation_unread(&id, unread)).await??;
        Ok(())
    }

    pub async fn set_conversation_pinned(&self, id: String, pinned: bool) -> Result<(), CoreError> {
        let db = Arc::clone(&self.inner);
        blocking(move || lock(&db).set_conversation_pinned(&id, pinned)).await??;
        Ok(())
    }

    pub async fn delete_conversation(&self, id: String) -> Result<(), CoreError> {
        let db = Arc::clone(&self.inner);
        blocking(move || lock(&db).delete_conversation(&id)).await??;
        Ok(())
    }

    /// Raw JSON bytes of a preference (any type), or `None`.
    pub async fn preference_data(&self, key: String) -> Result<Option<Vec<u8>>, CoreError> {
        let db = Arc::clone(&self.inner);
        Ok(blocking(move || lock(&db).get_preference_data(&key)).await??)
    }

    pub async fn set_preference_data(&self, key: String, data: Vec<u8>) -> Result<(), CoreError> {
        let db = Arc::clone(&self.inner);
        blocking(move || lock(&db).set_preference_data(&key, &data)).await??;
        Ok(())
    }

    /// The preference as a JSON bool, else `default_value`.
    pub async fn preference_bool(
        &self,
        key: String,
        default_value: bool,
    ) -> Result<bool, CoreError> {
        let db = Arc::clone(&self.inner);
        Ok(blocking(move || lock(&db).get_preference_bool(&key, default_value)).await??)
    }

    pub async fn set_preference_bool(&self, key: String, value: bool) -> Result<(), CoreError> {
        let db = Arc::clone(&self.inner);
        blocking(move || lock(&db).set_preference_bool(&key, value)).await??;
        Ok(())
    }

    /// The preference as `[String]` (empty when absent or malformed).
    pub async fn preference_strings(&self, key: String) -> Result<Vec<String>, CoreError> {
        let db = Arc::clone(&self.inner);
        Ok(blocking(move || lock(&db).get_preference_strings(&key)).await??)
    }

    pub async fn set_preference_strings(
        &self,
        key: String,
        value: Vec<String>,
    ) -> Result<(), CoreError> {
        let db = Arc::clone(&self.inner);
        blocking(move || lock(&db).set_preference_strings(&key, &value)).await??;
        Ok(())
    }

    pub async fn delete_preference(&self, key: String) -> Result<(), CoreError> {
        let db = Arc::clone(&self.inner);
        blocking(move || lock(&db).delete_preference(&key)).await??;
        Ok(())
    }
}
