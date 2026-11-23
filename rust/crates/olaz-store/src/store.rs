use std::collections::{BTreeMap, HashSet};
use std::path::Path;

use rusqlite::functions::FunctionFlags;
use rusqlite::types::ValueRef;
use rusqlite::{Connection, OpenFlags, OptionalExtension, Row, TransactionBehavior, params};
use serde_json::{Map, Value, json};

use crate::error::{Result, StoreError};
use crate::helpers::{
    is_group_id, is_signal_ciphertext, json_int64, json_string, lossless_parse_object,
    sanitize_profile_uid, strip_user_prefix, to_swift_json, trim_ws,
    url_has_undecrypted_signal_cipher,
};
use crate::model::{
    CloudMediaQuery, MessagesAround, SaveOptions, SharedMediaPage, StoredCloudConversationSummary,
    StoredCloudMediaItem, StoredConversation, StoredMessage,
};
use crate::schema::{CLOUD_ITEM_SIZE_SQL, PRAGMAS_SQL, SCHEMA_SQL};

const MESSAGE_COLS: &str = "id, conv_id, client_id, sender_id, sender_name, sender_avatar, is_mine, text, kind_tag, ts_ms, status, raw_json";
const MEMORY_PATH: &str = ":memory:";
const E2EE_PREVIEW: &str = "🔒 Tin nhắn mã hóa đầu cuối";

// ---- row helpers (sqlite3_column_text / column_int semantics) ----

fn col_text(row: &Row<'_>, i: usize) -> rusqlite::Result<String> {
    Ok(match row.get_ref(i)? {
        ValueRef::Null => String::new(),
        ValueRef::Integer(n) => n.to_string(),
        ValueRef::Real(f) => f.to_string(),
        ValueRef::Text(b) | ValueRef::Blob(b) => String::from_utf8_lossy(b).into_owned(),
    })
}

fn col_i64(row: &Row<'_>, i: usize) -> rusqlite::Result<i64> {
    Ok(match row.get_ref(i)? {
        ValueRef::Null | ValueRef::Blob(_) => 0,
        ValueRef::Integer(n) => n,
        ValueRef::Real(f) => f as i64,
        ValueRef::Text(b) => String::from_utf8_lossy(b)
            .trim()
            .parse::<i64>()
            .unwrap_or(0),
    })
}

fn read_stored_message(row: &Row<'_>) -> rusqlite::Result<StoredMessage> {
    Ok(StoredMessage {
        id: col_text(row, 0)?,
        conv_id: col_text(row, 1)?,
        client_id: col_text(row, 2)?,
        sender_id: col_text(row, 3)?,
        sender_name: col_text(row, 4)?,
        sender_avatar: col_text(row, 5)?,
        is_mine: col_i64(row, 6)? != 0,
        text: col_text(row, 7)?,
        kind_tag: col_text(row, 8)?,
        ts_ms: col_i64(row, 9)?,
        status: col_text(row, 10)?,
        raw_json_data: col_text(row, 11)?.into_bytes(),
    })
}

fn placeholders(n: usize) -> String {
    vec!["?"; n].join(",")
}

fn register_search_functions(conn: &Connection) -> rusqlite::Result<()> {
    conn.create_scalar_function(
        "olaz_fold",
        1,
        FunctionFlags::SQLITE_UTF8 | FunctionFlags::SQLITE_DETERMINISTIC,
        |ctx| {
            Ok(match ctx.get_raw(0) {
                ValueRef::Null => String::new(),
                ValueRef::Integer(n) => n.to_string(),
                ValueRef::Real(f) => f.to_string(),
                ValueRef::Text(b) | ValueRef::Blob(b) => String::from_utf8_lossy(b).to_lowercase(),
            })
        },
    )
}

/// Escapes SQLite `LIKE` wildcards (`%`, `_`, `\`) using `\` as the escape character.
#[must_use]
pub fn escape_like_pattern(query: &str) -> String {
    let mut out = String::with_capacity(query.len());
    for ch in query.chars() {
        if matches!(ch, '\\' | '%' | '_') {
            out.push('\\');
        }
        out.push(ch);
    }
    out
}

/// Local SQLite store: conversations, message history, shared-media index, preferences.
///
/// Reads take `&self`, writes `&mut self` (the Swift actor serializes both).
#[derive(Debug)]
pub struct Store {
    path: String,
    conn: Option<Connection>,
    /// Second, read-only handle (Swift `readDb`) for `read_messages_now`; file databases only.
    read_conn: Option<Connection>,
}

impl Store {
    /// Opens (creating if needed) the database at `path`; `":memory:"` is supported.
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let path_ref = path.as_ref();
        let path_str = path_ref.to_string_lossy().into_owned();
        let is_memory = path_str == MEMORY_PATH;
        if !is_memory && let Some(parent) = path_ref.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let flags = OpenFlags::SQLITE_OPEN_CREATE
            | OpenFlags::SQLITE_OPEN_READ_WRITE
            | OpenFlags::SQLITE_OPEN_FULL_MUTEX;
        let conn = Connection::open_with_flags(path_ref, flags)?;
        conn.set_prepared_statement_cache_capacity(128);
        register_search_functions(&conn)?;
        conn.execute_batch(PRAGMAS_SQL)?;
        conn.execute_batch(SCHEMA_SQL)?;

        let read_conn = if is_memory {
            None
        } else {
            // Swift ignores a failure to open the reader.
            Connection::open_with_flags(
                path_ref,
                OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_FULL_MUTEX,
            )
            .ok()
            .and_then(|c| {
                c.busy_timeout(std::time::Duration::from_millis(5000))
                    .ok()?;
                register_search_functions(&c).ok()?;
                Some(c)
            })
        };
        Ok(Self {
            path: path_str,
            conn: Some(conn),
            read_conn,
        })
    }

    /// Opens a private in-memory database.
    pub fn open_in_memory() -> Result<Self> {
        Self::open(MEMORY_PATH)
    }

    /// Database path as given to [`Store::open`].
    #[must_use]
    pub fn path(&self) -> &str {
        &self.path
    }

    /// Closes both connections; later calls fail with [`StoreError::Closed`].
    pub fn close(&mut self) {
        self.read_conn = None;
        self.conn = None;
    }

    pub(crate) fn db(&self) -> Result<&Connection> {
        self.conn.as_ref().ok_or(StoreError::Closed)
    }

    fn db_mut(&mut self) -> Result<&mut Connection> {
        self.conn.as_mut().ok_or(StoreError::Closed)
    }

    // ---- Conversations ----

    /// Upserts conversations in one transaction (empty name/avatar and zero members never
    /// overwrite; the preview only advances when `preview_ts` is not older).
    pub fn save_conversations(&mut self, items: &[StoredConversation]) -> Result<()> {
        if items.is_empty() {
            return Ok(());
        }
        let tx = self
            .db_mut()?
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        {
            let mut stmt = tx.prepare_cached(
                "INSERT INTO conversations(id, is_group, name, avatar, pinned, members, unread, preview_text, preview_ts, preview_from_me, updated_at)
VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
ON CONFLICT(id) DO UPDATE SET
    is_group = excluded.is_group,
    name = CASE WHEN excluded.name != '' THEN excluded.name ELSE conversations.name END,
    avatar = CASE WHEN excluded.avatar != '' THEN excluded.avatar ELSE conversations.avatar END,
    pinned = excluded.pinned,
    members = CASE WHEN excluded.members > 0 THEN excluded.members ELSE conversations.members END,
    unread = excluded.unread,
    preview_text = CASE WHEN excluded.preview_ts >= conversations.preview_ts THEN excluded.preview_text ELSE conversations.preview_text END,
    preview_ts = CASE WHEN excluded.preview_ts >= conversations.preview_ts THEN excluded.preview_ts ELSE conversations.preview_ts END,
    preview_from_me = CASE WHEN excluded.preview_ts >= conversations.preview_ts THEN excluded.preview_from_me ELSE conversations.preview_from_me END,
    updated_at = excluded.updated_at;",
            )?;
            for c in items {
                stmt.execute(params![
                    c.id,
                    i32::from(c.is_group),
                    c.name,
                    c.avatar,
                    i32::from(c.pinned),
                    c.members,
                    c.unread,
                    c.preview_text,
                    c.preview_ts_ms,
                    i32::from(c.preview_from_me),
                    c.updated_at_ms,
                ])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// Single-row [`Store::save_conversations`].
    pub fn upsert_conversation(&mut self, item: &StoredConversation) -> Result<()> {
        self.save_conversations(std::slice::from_ref(item))
    }

    /// All conversations: pinned first, then newest preview, then newest update.
    pub fn load_conversations(&self) -> Result<Vec<StoredConversation>> {
        let mut stmt = self.db()?.prepare_cached(
            "SELECT id, is_group, name, avatar, pinned, members, unread, preview_text, preview_ts, preview_from_me, updated_at
FROM conversations
ORDER BY pinned DESC, preview_ts DESC, updated_at DESC;",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(StoredConversation {
                id: col_text(r, 0)?,
                is_group: col_i64(r, 1)? != 0,
                name: col_text(r, 2)?,
                avatar: col_text(r, 3)?,
                pinned: col_i64(r, 4)? != 0,
                members: col_i64(r, 5)?,
                unread: col_i64(r, 6)?,
                preview_text: col_text(r, 7)?,
                preview_ts_ms: col_i64(r, 8)?,
                preview_from_me: col_i64(r, 9)? != 0,
                updated_at_ms: col_i64(r, 10)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    /// Sets the unread counter (negative values clamp to 0).
    pub fn set_conversation_unread(&mut self, id: &str, unread: i64) -> Result<()> {
        self.db()?
            .prepare_cached("UPDATE conversations SET unread = ?1 WHERE id = ?2;")?
            .execute(params![unread.max(0), id])?;
        Ok(())
    }

    /// Sets the pinned flag.
    pub fn set_conversation_pinned(&mut self, id: &str, pinned: bool) -> Result<()> {
        self.db()?
            .prepare_cached("UPDATE conversations SET pinned = ?1 WHERE id = ?2;")?
            .execute(params![i32::from(pinned), id])?;
        Ok(())
    }

    /// Deletes a conversation and all of its messages.
    pub fn delete_conversation(&mut self, id: &str) -> Result<()> {
        let tx = self
            .db_mut()?
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.prepare_cached("DELETE FROM messages WHERE conv_id = ?1;")?
            .execute(params![id])?;
        tx.prepare_cached("DELETE FROM conversations WHERE id = ?1;")?
            .execute(params![id])?;
        tx.commit()?;
        Ok(())
    }

    // ---- Messages ----

    /// `SELECT 1 FROM messages LIMIT 1`.
    pub fn has_any_messages(&self) -> Result<bool> {
        let found = self
            .db()?
            .prepare_cached("SELECT 1 FROM messages LIMIT 1;")?
            .query_row([], |_| Ok(()))
            .optional()?;
        Ok(found.is_some())
    }

    /// Names of the indexes on `messages`.
    pub fn message_index_names(&self) -> Result<Vec<String>> {
        let mut stmt = self.db()?.prepare_cached(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'messages';",
        )?;
        let rows = stmt.query_map([], |r| col_text(r, 0))?;
        let mut out = Vec::new();
        for name in rows {
            let name = name?;
            if !name.is_empty() {
                out.push(name);
            }
        }
        Ok(out)
    }

    /// Upserts messages in one transaction, with E2EE locked/plain twin handling.
    pub fn save_messages(&mut self, items: &[StoredMessage]) -> Result<()> {
        self.save_messages_with(items, SaveOptions::default())
    }

    /// [`Store::save_messages`] with explicit `skipTwinChecks` / `preserveExistingReactions`.
    pub fn save_messages_with(&mut self, items: &[StoredMessage], opts: SaveOptions) -> Result<()> {
        if items.is_empty() {
            return Ok(());
        }
        let tx = self
            .db_mut()?
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        save_messages_in(&tx, items, opts)?;
        tx.commit()?;
        Ok(())
    }

    /// Loads messages for `conv_id`, oldest to newest. `before_ts_ms` fetches strictly older rows.
    /// `limit` is clamped to 1...500.
    pub fn messages(
        &self,
        conv_id: &str,
        before_ts_ms: Option<i64>,
        limit: i64,
    ) -> Result<Vec<StoredMessage>> {
        query_messages(self.db()?, conv_id, before_ts_ms, limit)
    }

    /// Case-insensitive (via `olaz_fold`) search in one conversation, newest first.
    /// Skips recalled and E2EE-locked rows; searches `raw_json` caption/title/etc.
    pub fn search_messages(
        &self,
        conversation_id: &str,
        query: &str,
        limit: i64,
    ) -> Result<Vec<StoredMessage>> {
        let trimmed = trim_ws(query);
        if conversation_id.is_empty() || trimmed.is_empty() || limit <= 0 {
            return Ok(Vec::new());
        }
        let clamped = limit.clamp(1, 500);
        let pattern = format!("%{}%", escape_like_pattern(&trimmed.to_lowercase()));
        let mut stmt = self.db()?.prepare_cached(
            r"SELECT id, conv_id, client_id, sender_id, sender_name, sender_avatar, is_mine, text, kind_tag, ts_ms, status, raw_json
FROM messages
WHERE conv_id = ?1
  AND kind_tag != 'recalled'
  AND status != 'e2ee_locked'
  AND (
      olaz_fold(text) LIKE ?2 ESCAPE '\'
      OR (
          json_valid(raw_json)
          AND (
              olaz_fold(COALESCE(json_extract(raw_json, '$.text'), '')) LIKE ?2 ESCAPE '\'
              OR olaz_fold(COALESCE(json_extract(raw_json, '$.caption'), '')) LIKE ?2 ESCAPE '\'
              OR olaz_fold(COALESCE(json_extract(raw_json, '$.body'), '')) LIKE ?2 ESCAPE '\'
              OR olaz_fold(COALESCE(json_extract(raw_json, '$.kind.caption'), '')) LIKE ?2 ESCAPE '\'
              OR olaz_fold(COALESCE(json_extract(raw_json, '$.kind.title'), '')) LIKE ?2 ESCAPE '\'
              OR olaz_fold(COALESCE(json_extract(raw_json, '$.kind.description'), '')) LIKE ?2 ESCAPE '\'
              OR olaz_fold(COALESCE(json_extract(raw_json, '$.kind.name'), '')) LIKE ?2 ESCAPE '\'
              OR olaz_fold(COALESCE(json_extract(raw_json, '$.kind.address'), '')) LIKE ?2 ESCAPE '\'
              OR olaz_fold(COALESCE(json_extract(raw_json, '$.kind.question'), '')) LIKE ?2 ESCAPE '\'
              OR olaz_fold(COALESCE(json_extract(raw_json, '$.kind.header'), '')) LIKE ?2 ESCAPE '\'
              OR olaz_fold(COALESCE(json_extract(raw_json, '$.kind.text'), '')) LIKE ?2 ESCAPE '\'
              OR (
                  kind_tag = 'oaMessage'
                  AND json_type(raw_json, '$.kind.parts') = 'array'
                  AND EXISTS (
                      SELECT 1 FROM json_each(raw_json, '$.kind.parts')
                      WHERE olaz_fold(COALESCE(json_extract(value, '$.title'), '')) LIKE ?2 ESCAPE '\'
                         OR olaz_fold(COALESCE(json_extract(value, '$.description'), '')) LIKE ?2 ESCAPE '\'
                  )
              )
          )
      )
  )
ORDER BY ts_ms DESC, id DESC
LIMIT ?3;",
        )?;
        let rows = stmt.query_map(
            params![conversation_id, pattern, clamped],
            read_stored_message,
        )?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    /// Messages from `target_ts_ms` upward (optionally capped at `before_oldest_ts_ms`) plus
    /// `context_before` earlier ones, chronological. Swift defaults: 25 and 3000.
    pub fn messages_around(
        &self,
        conv_id: &str,
        target_ts_ms: i64,
        before_oldest_ts_ms: Option<i64>,
        context_before: i64,
        max_window: i64,
    ) -> Result<MessagesAround> {
        let conn = self.db()?;
        let clamped_before = context_before.clamp(0, 200);
        let clamped_window = max_window.clamp(1, 5000);

        let mut older_desc: Vec<StoredMessage> = Vec::new();
        if clamped_before > 0 {
            let mut stmt = conn.prepare_cached(&format!(
                "SELECT {MESSAGE_COLS}
FROM messages
WHERE conv_id = ?1 AND ts_ms < ?2
ORDER BY ts_ms DESC, id DESC
LIMIT ?3;"
            ))?;
            let rows = stmt.query_map(
                params![conv_id, target_ts_ms, clamped_before + 1],
                read_stored_message,
            )?;
            for r in rows {
                older_desc.push(r?);
            }
        }
        let before_len = usize::try_from(clamped_before).unwrap_or(0);
        let has_more_older = older_desc.len() > before_len;
        older_desc.truncate(before_len);
        older_desc.reverse();

        let newer_asc: Vec<StoredMessage> = if let Some(cap) = before_oldest_ts_ms {
            let mut stmt = conn.prepare_cached(&format!(
                "SELECT {MESSAGE_COLS}
FROM messages
WHERE conv_id = ?1 AND ts_ms >= ?2 AND ts_ms <= ?3
ORDER BY ts_ms ASC, id ASC
LIMIT ?4;"
            ))?;
            let rows = stmt.query_map(
                params![conv_id, target_ts_ms, cap, clamped_window],
                read_stored_message,
            )?;
            rows.collect::<rusqlite::Result<Vec<_>>>()?
        } else {
            let mut stmt = conn.prepare_cached(&format!(
                "SELECT {MESSAGE_COLS}
FROM messages
WHERE conv_id = ?1 AND ts_ms >= ?2
ORDER BY ts_ms ASC, id ASC
LIMIT ?3;"
            ))?;
            let rows = stmt.query_map(
                params![conv_id, target_ts_ms, clamped_window],
                read_stored_message,
            )?;
            rows.collect::<rusqlite::Result<Vec<_>>>()?
        };
        older_desc.extend(newer_asc);
        Ok(MessagesAround {
            messages: older_desc,
            has_more_older,
        })
    }

    /// Finds a message by `id`, falling back to `client_id`.
    pub fn message(&self, conv_id: &str, id_or_client_id: &str) -> Result<Option<StoredMessage>> {
        message_in(self.db()?, conv_id, id_or_client_id)
    }

    /// Re-keys a message from `old_id` to the server `new_id` (see Swift `upgradeMessageId`).
    /// Returns whether a row changed.
    pub fn upgrade_message_id(
        &mut self,
        conv_id: &str,
        old_id: &str,
        new_id: &str,
        client_id: &str,
    ) -> Result<bool> {
        let tx = self
            .db_mut()?
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let upgraded = perform_upgrade_message_id(&tx, conv_id, old_id, new_id, client_id)?;
        tx.commit()?;
        Ok(upgraded)
    }

    /// Deletes by `id` and by `client_id` (both in one transaction).
    pub fn delete_message(&mut self, conv_id: &str, id: &str) -> Result<()> {
        let tx = self
            .db_mut()?
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.prepare_cached("DELETE FROM messages WHERE conv_id = ?1 AND id = ?2;")?
            .execute(params![conv_id, id])?;
        tx.prepare_cached("DELETE FROM messages WHERE conv_id = ?1 AND client_id = ?2;")?
            .execute(params![conv_id, id])?;
        tx.commit()?;
        Ok(())
    }

    /// Rewrites a stored message as recalled (no-op if missing or `raw_json` is not an object).
    pub fn mark_recalled(&mut self, conv_id: &str, id: &str, cli_msg_id: &str) -> Result<()> {
        let mut lookup = self.message(conv_id, id)?;
        if lookup.is_none() && !cli_msg_id.is_empty() {
            lookup = self.message(conv_id, cli_msg_id)?;
        }
        let Some(existing) = lookup else {
            return Ok(());
        };
        let Ok(Value::Object(mut dict)) = serde_json::from_slice::<Value>(&existing.raw_json_data)
        else {
            return Ok(());
        };
        dict.insert("type".into(), json!("recalled"));
        dict.insert("kind".into(), json!({"type": "recalled"}));
        dict.insert("text".into(), json!(""));
        dict.insert("reactions".into(), json!([]));
        dict.insert("buttons".into(), json!([]));
        dict.remove("quote");
        if let Some(Value::Object(menu)) = dict.get_mut("menu") {
            menu.insert("recall".into(), json!(false));
            menu.insert("forward".into(), json!(""));
            menu.insert("pin".into(), json!(false));
            menu.insert("star".into(), json!(""));
            menu.insert("starred".into(), json!(false));
        }
        let Some(updated) = to_swift_json(&Value::Object(dict)) else {
            return Ok(());
        };
        let msg = StoredMessage {
            text: String::new(),
            kind_tag: "recalled".into(),
            raw_json_data: updated.into_bytes(),
            ..existing
        };
        self.save_messages(&[msg])
    }

    /// Replaces `$.reactions` in the stored `raw_json` (no-op on missing row / invalid JSON).
    pub fn update_message_reactions_json(
        &mut self,
        conv_id: &str,
        id: &str,
        reactions_json: &[u8],
    ) -> Result<()> {
        let Some(existing) = self.message(conv_id, id)? else {
            return Ok(());
        };
        let Ok(Value::Object(mut dict)) = serde_json::from_slice::<Value>(&existing.raw_json_data)
        else {
            return Ok(());
        };
        // `JSONSerialization.jsonObject` without fragments: top level must be array/object.
        let Ok(reactions @ (Value::Array(_) | Value::Object(_))) =
            serde_json::from_slice::<Value>(reactions_json)
        else {
            return Ok(());
        };
        dict.insert("reactions".into(), reactions);
        let Some(updated) = to_swift_json(&Value::Object(dict)) else {
            return Ok(());
        };
        let msg = StoredMessage {
            raw_json_data: updated.into_bytes(),
            ..existing
        };
        self.save_messages(&[msg])
    }

    /// Shared-media JSON blobs for `conv_id` filtered by `kind_tags`, newest first, keyset
    /// paginated with cursor `"<tsMs>|<id>"`.
    pub fn shared_media_raw(
        &self,
        conv_id: &str,
        kind_tags: &[String],
        after_cursor: Option<&str>,
        limit: i64,
    ) -> Result<SharedMediaPage> {
        if kind_tags.is_empty() {
            return Ok(SharedMediaPage::default());
        }
        let page_len = limit.clamp(1, 200);
        let fetch_limit = page_len + 1;
        let tag_ph = placeholders(kind_tags.len());

        // Swift `split(separator: "|", maxSplits: 1)` omits empty subsequences.
        let parts: Vec<&str> = after_cursor
            .map(|c| match c.split_once('|') {
                Some((a, b)) => [a, b].into_iter().filter(|s| !s.is_empty()).collect(),
                None => [c].into_iter().filter(|s| !s.is_empty()).collect(),
            })
            .unwrap_or_default();
        let cursor_ts = parts.first().and_then(|s| s.parse::<i64>().ok());
        let cursor_id = if parts.len() == 2 {
            Some(parts[1])
        } else {
            None
        };

        let mut args: Vec<rusqlite::types::Value> = vec![conv_id.to_owned().into()];
        args.extend(kind_tags.iter().map(|t| t.clone().into()));
        let sql = if let (Some(ts), Some(cid)) = (cursor_ts, cursor_id) {
            args.push(ts.into());
            args.push(ts.into());
            args.push(cid.to_owned().into());
            format!(
                "SELECT id, ts_ms, raw_json
FROM messages
WHERE conv_id = ? AND kind_tag IN ({tag_ph})
  AND (ts_ms < ? OR (ts_ms = ? AND id < ?))
ORDER BY ts_ms DESC, id DESC
LIMIT ?;"
            )
        } else {
            format!(
                "SELECT id, ts_ms, raw_json
FROM messages
WHERE conv_id = ? AND kind_tag IN ({tag_ph})
ORDER BY ts_ms DESC, id DESC
LIMIT ?;"
            )
        };
        args.push(fetch_limit.into());

        let mut stmt = self.db()?.prepare_cached(&sql)?;
        let rows = stmt.query_map(rusqlite::params_from_iter(args), |r| {
            Ok((
                col_text(r, 0)?,
                col_i64(r, 1)?,
                col_text(r, 2)?.into_bytes(),
            ))
        })?;
        let mut collected = rows.collect::<rusqlite::Result<Vec<_>>>()?;

        let more = i64::try_from(collected.len()).unwrap_or(i64::MAX) >= fetch_limit;
        collected.truncate(usize::try_from(page_len).unwrap_or(1));
        let cursor = if more {
            collected.last().map(|(id, ts, _)| format!("{ts}|{id}"))
        } else {
            None
        };
        Ok(SharedMediaPage {
            rows: collected.into_iter().map(|(_, _, d)| d).collect(),
            cursor,
            more,
        })
    }

    // ---- zCloud media ----

    /// Per-conversation media byte totals (photo/video/file/voice), largest first.
    pub fn cloud_media_aggregation(&self) -> Result<Vec<StoredCloudConversationSummary>> {
        let size = CLOUD_ITEM_SIZE_SQL;
        let sql = format!(
            "SELECT
    m.conv_id,
    COALESCE(c.name, ''),
    COALESCE(c.avatar, ''),
    COALESCE(c.is_group, 0),
    SUM(CASE WHEN m.kind_tag = 'photo' THEN ({size}) ELSE 0 END) AS photo_bytes,
    SUM(CASE WHEN m.kind_tag = 'video' THEN ({size}) ELSE 0 END) AS video_bytes,
    SUM(CASE WHEN m.kind_tag = 'file' THEN ({size}) ELSE 0 END) AS file_bytes,
    SUM(CASE WHEN m.kind_tag = 'voice' THEN ({size}) ELSE 0 END) AS voice_bytes,
    COUNT(*) AS item_count,
    MAX(m.ts_ms) AS last_ts_ms
FROM messages m
LEFT JOIN conversations c ON c.id = m.conv_id
WHERE m.kind_tag IN ('photo', 'video', 'file', 'voice')
  AND m.status != 'e2ee_locked'
GROUP BY m.conv_id
ORDER BY (photo_bytes + video_bytes + file_bytes + voice_bytes) DESC, last_ts_ms DESC;"
        );
        let mut stmt = self.db()?.prepare_cached(&sql)?;
        let rows = stmt.query_map([], |r| {
            let conv_id = col_text(r, 0)?;
            let is_group = if matches!(r.get_ref(3)?, ValueRef::Null) {
                is_group_id(&conv_id)
            } else {
                col_i64(r, 3)? != 0
            };
            Ok(StoredCloudConversationSummary {
                conv_name: col_text(r, 1)?,
                conv_avatar: col_text(r, 2)?,
                is_group,
                photo_bytes: col_i64(r, 4)?,
                video_bytes: col_i64(r, 5)?,
                file_bytes: col_i64(r, 6)?,
                voice_bytes: col_i64(r, 7)?,
                item_count: col_i64(r, 8)?,
                last_activity_ms: col_i64(r, 9)?,
                conv_id,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    /// Media items across (or within) conversations with SQL sorting and offset paging.
    /// Returns `(items, has_more)`.
    pub fn cloud_media_items(
        &self,
        q: &CloudMediaQuery,
    ) -> Result<(Vec<StoredCloudMediaItem>, bool)> {
        let valid_tags: Vec<&String> = q
            .kind_tags
            .iter()
            .filter(|t| ["photo", "video", "file", "voice"].contains(&t.as_str()))
            .collect();
        if valid_tags.is_empty() || q.limit <= 0 {
            return Ok((Vec::new(), false));
        }
        let clamped_limit = q.limit.clamp(1, 500);
        let safe_offset = q.offset.max(0);
        let fetch_limit = clamped_limit + 1;

        let mut where_clauses = vec![
            "m.status != 'e2ee_locked'".to_owned(),
            format!("m.kind_tag IN ({})", placeholders(valid_tags.len())),
        ];
        let mut args: Vec<rusqlite::types::Value> =
            valid_tags.iter().map(|t| (*t).clone().into()).collect();
        match (&q.conv_id, &q.excluding_conv_id) {
            (Some(c), _) if !c.is_empty() => {
                where_clauses.push("m.conv_id = ?".into());
                args.push(c.clone().into());
            }
            (_, Some(c)) if !c.is_empty() => {
                where_clauses.push("m.conv_id != ?".into());
                args.push(c.clone().into());
            }
            _ => {}
        }
        args.push(fetch_limit.into());
        args.push(safe_offset.into());

        let dir = if q.ascending { "ASC" } else { "DESC" };
        let order_clause = if q.sort_by_size {
            format!("size_bytes {dir}, m.ts_ms DESC, m.id {dir}")
        } else {
            format!("m.ts_ms {dir}, m.id {dir}")
        };
        let size = CLOUD_ITEM_SIZE_SQL;
        let where_sql = where_clauses.join(" AND ");
        let sql = format!(
            "SELECT
    m.id,
    m.client_id,
    m.conv_id,
    COALESCE(c.name, ''),
    m.kind_tag,
    m.text,
    m.ts_ms,
    CASE WHEN json_valid(m.raw_json) THEN COALESCE(json_extract(m.raw_json, '$.kind.name'), '') ELSE '' END AS file_name,
    ({size}) AS size_bytes,
    CASE WHEN json_valid(m.raw_json) THEN COALESCE(CAST(json_extract(m.raw_json, '$.kind.duration') AS INTEGER), 0) ELSE 0 END AS dur_sec,
    CASE WHEN json_valid(m.raw_json) THEN COALESCE(CAST(json_extract(m.raw_json, '$.kind.width') AS INTEGER), 0) ELSE 0 END AS width_px,
    CASE WHEN json_valid(m.raw_json) THEN COALESCE(CAST(json_extract(m.raw_json, '$.kind.height') AS INTEGER), 0) ELSE 0 END AS height_px,
    CASE WHEN json_valid(m.raw_json) THEN COALESCE(json_extract(m.raw_json, '$.kind.url'), '') ELSE '' END AS media_url
FROM messages m
LEFT JOIN conversations c ON c.id = m.conv_id
WHERE {where_sql}
ORDER BY {order_clause}
LIMIT ? OFFSET ?;"
        );
        let mut stmt = self.db()?.prepare_cached(&sql)?;
        let rows = stmt.query_map(rusqlite::params_from_iter(args), |r| {
            Ok(StoredCloudMediaItem {
                id: col_text(r, 0)?,
                client_id: col_text(r, 1)?,
                conv_id: col_text(r, 2)?,
                conv_name: col_text(r, 3)?,
                kind_tag: col_text(r, 4)?,
                text: col_text(r, 5)?,
                ts_ms: col_i64(r, 6)?,
                file_name: col_text(r, 7)?,
                size_bytes: col_i64(r, 8)?,
                duration_sec: col_i64(r, 9)?.max(0),
                width: col_i64(r, 10)?.max(0),
                height: col_i64(r, 11)?.max(0),
                url: col_text(r, 12)?,
            })
        })?;
        let mut collected = rows.collect::<rusqlite::Result<Vec<_>>>()?;
        let cap = usize::try_from(clamped_limit).unwrap_or(1);
        let has_more = collected.len() > cap;
        collected.truncate(cap);
        Ok((collected, has_more))
    }

    /// Subset of `ids` (matching `id` or `client_id`) already stored in `conv_id`.
    pub fn existing_message_ids(&self, conv_id: &str, ids: &[String]) -> Result<HashSet<String>> {
        let unique: Vec<&String> = ids
            .iter()
            .filter(|s| !s.is_empty())
            .collect::<HashSet<_>>()
            .into_iter()
            .collect();
        let mut found = HashSet::new();
        if conv_id.is_empty() || unique.is_empty() {
            return Ok(found);
        }
        for chunk in unique.chunks(200) {
            let ph = placeholders(chunk.len());
            let sql = format!(
                "SELECT id, client_id
FROM messages
WHERE conv_id = ? AND (id IN ({ph}) OR client_id IN ({ph}));"
            );
            let mut args: Vec<&str> = vec![conv_id];
            args.extend(chunk.iter().map(|s| s.as_str()));
            args.extend(chunk.iter().map(|s| s.as_str()));
            let mut stmt = self.db()?.prepare_cached(&sql)?;
            let rows = stmt.query_map(rusqlite::params_from_iter(args), |r| {
                Ok((col_text(r, 0)?, col_text(r, 1)?))
            })?;
            for row in rows {
                let (row_id, cli_id) = row?;
                if !row_id.is_empty() {
                    found.insert(row_id);
                }
                if !cli_id.is_empty() {
                    found.insert(cli_id);
                }
            }
        }
        Ok(found)
    }

    // ---- Repairs ----

    /// One-time scrub of corrupted/ghost reactions. Returns the number of rewritten rows
    /// (0 when the `reactionRepairVersion` preference is already `"2"`).
    pub fn repair_legacy_reactions(&mut self, my_uid: &str) -> Result<usize> {
        if matches!(self.get_preference_string("reactionRepairVersion"), Ok(Some(v)) if v == "2") {
            return Ok(0);
        }
        let clean_my_uid =
            sanitize_profile_uid(my_uid).unwrap_or_else(|| strip_user_prefix(my_uid));
        let is_sentinel = |k: &str| matches!(k, "" | "__legacy__" | "unknown" | "-1");

        let rows: Vec<(String, String, String)> = {
            let mut stmt = self.db()?.prepare_cached(
                "SELECT id, conv_id, raw_json
FROM messages
WHERE json_valid(raw_json)
  AND COALESCE(json_array_length(raw_json, '$.reactions'), 0) > 0;",
            )?;
            let it = stmt.query_map([], |r| {
                Ok((col_text(r, 0)?, col_text(r, 1)?, col_text(r, 2)?))
            })?;
            it.collect::<rusqlite::Result<Vec<_>>>()?
        };

        let mut repaired = 0usize;
        let tx = self
            .db_mut()?
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        {
            let mut upd = tx.prepare_cached(
                "UPDATE messages SET raw_json = ?1 WHERE conv_id = ?2 AND id = ?3;",
            )?;
            for (id, conv_id, raw) in rows {
                let Ok(Value::Object(mut obj)) = serde_json::from_str::<Value>(&raw) else {
                    continue;
                };
                let Some(Value::Array(raw_arr)) = obj.get("reactions") else {
                    continue;
                };
                let Some(raw_reacts) = raw_arr
                    .iter()
                    .map(|v| v.as_object().cloned())
                    .collect::<Option<Vec<Map<String, Value>>>>()
                else {
                    continue;
                };

                let mut cleaned: Vec<Map<String, Value>> = Vec::new();
                for mut react in raw_reacts.clone() {
                    let type_str = json_string(react.get("type"));
                    if let Ok(n) = trim_ws(&type_str).parse::<i64>()
                        && n < 0
                    {
                        continue;
                    }
                    let Some(Value::Object(uc)) = react.get("userCounts") else {
                        continue;
                    };
                    if uc.is_empty() {
                        continue;
                    }
                    let mut normalized: BTreeMap<String, i64> = BTreeMap::new();
                    for (raw_key, raw_val) in uc {
                        let key = trim_ws(raw_key);
                        if is_sentinel(key) {
                            continue;
                        }
                        let count = json_int64(raw_val).unwrap_or(0);
                        if count <= 0 {
                            continue;
                        }
                        let canonical = if (key == "0" || key == "me") && !clean_my_uid.is_empty() {
                            clean_my_uid.clone()
                        } else {
                            sanitize_profile_uid(key).unwrap_or_else(|| key.to_owned())
                        };
                        if is_sentinel(&canonical) {
                            continue;
                        }
                        *normalized.entry(canonical).or_insert(0) += count;
                    }
                    let total: i64 = normalized.values().sum();
                    if total <= 0 {
                        continue;
                    }
                    let includes_me = !clean_my_uid.is_empty()
                        && normalized.get(&clean_my_uid).copied().unwrap_or(0) > 0;
                    let names: Vec<Value> = match react.get("names") {
                        Some(Value::Array(a)) if a.iter().all(Value::is_string) => a
                            .iter()
                            .filter(|n| {
                                let t = trim_ws(n.as_str().unwrap_or(""));
                                !t.is_empty() && t != "Người dùng Zalo"
                            })
                            .cloned()
                            .collect(),
                        _ => Vec::new(),
                    };
                    let people = normalized.len();
                    let uc_obj: Map<String, Value> =
                        normalized.into_iter().map(|(k, v)| (k, json!(v))).collect();
                    react.insert("userCounts".into(), Value::Object(uc_obj));
                    react.insert("count".into(), json!(total));
                    react.insert("people".into(), json!(people));
                    react.insert("includesMe".into(), json!(includes_me));
                    react.insert("names".into(), Value::Array(names));
                    cleaned.push(react);
                }

                let changed = cleaned.len() != raw_reacts.len() || cleaned != raw_reacts;
                if !changed {
                    continue;
                }
                obj.insert(
                    "reactions".into(),
                    Value::Array(cleaned.into_iter().map(Value::Object).collect()),
                );
                let Some(updated) = to_swift_json(&Value::Object(obj)) else {
                    continue;
                };
                upd.execute(params![updated, conv_id, id])?;
                repaired += 1;
            }
        }
        tx.commit()?;
        self.set_preference_string("reactionRepairVersion", "2")?;
        Ok(repaired)
    }

    /// Converts legacy un-decrypted Signal ciphertext rows to lock placeholders (or deletes them
    /// when a clean twin exists) and sanitizes poisoned conversation previews.
    pub fn repair_undecrypted_e2ee_messages(&mut self) -> Result<usize> {
        struct Candidate {
            id: String,
            conv_id: String,
            client_id: String,
            kind_tag: String,
            text: String,
            raw_json: String,
        }
        let candidates: Vec<Candidate> = {
            let mut stmt = self.db()?.prepare_cached(
                "SELECT id, conv_id, client_id, kind_tag, text, raw_json
FROM messages
WHERE status != 'e2ee_locked'
  AND (
      text LIKE 'AzM%' OR text LIKE 'AjM%'
      OR raw_json LIKE '%eid=AzM%' OR raw_json LIKE '%eid=AjM%'
      OR raw_json LIKE '%e2esession=AzM%' OR raw_json LIKE '%e2esession=AjM%'
  );",
            )?;
            let it = stmt.query_map([], |r| {
                Ok(Candidate {
                    id: col_text(r, 0)?,
                    conv_id: col_text(r, 1)?,
                    client_id: col_text(r, 2)?,
                    kind_tag: col_text(r, 3)?,
                    text: col_text(r, 4)?,
                    raw_json: col_text(r, 5)?,
                })
            })?;
            it.collect::<rusqlite::Result<Vec<_>>>()?
        };

        let mut repaired = 0usize;
        let tx = self
            .db_mut()?
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        {
            let mut twin_check = tx.prepare_cached(
                "SELECT text, raw_json FROM messages
WHERE conv_id = ?1 AND id = ?3 AND id != ?2 AND status != 'e2ee_locked'
UNION ALL
SELECT text, raw_json FROM messages
WHERE conv_id = ?1 AND client_id = ?3 AND id != ?2 AND status != 'e2ee_locked'
LIMIT 5;",
            )?;
            let mut del =
                tx.prepare_cached("DELETE FROM messages WHERE conv_id = ?1 AND id = ?2;")?;
            let mut upd = tx.prepare_cached(
                "UPDATE messages
SET text = ?1, kind_tag = 'placeholder', status = 'e2ee_locked', raw_json = ?2
WHERE conv_id = ?3 AND id = ?4;",
            )?;

            for c in &candidates {
                let Some(mut json_obj) = lossless_parse_object(c.raw_json.as_bytes()) else {
                    continue;
                };
                let kind_url = json_string(json_obj.get("kind").and_then(|k| k.get("url")));
                let poisoned_text = is_signal_ciphertext(&c.text);
                let poisoned_media =
                    is_signal_ciphertext(&kind_url) || url_has_undecrypted_signal_cipher(&kind_url);
                if !(poisoned_text || poisoned_media) {
                    continue;
                }

                if !c.client_id.is_empty() {
                    let twins = twin_check
                        .query_map(params![c.conv_id, c.id, c.client_id], |r| {
                            Ok((col_text(r, 0)?, col_text(r, 1)?))
                        })?
                        .collect::<rusqlite::Result<Vec<_>>>()?;
                    let has_clean_twin = twins.iter().any(|(t_text, t_raw)| {
                        !is_signal_ciphertext(t_text)
                            && !t_raw.contains("eid=AzM")
                            && !t_raw.contains("eid=AjM")
                    });
                    if has_clean_twin {
                        del.execute(params![c.conv_id, c.id])?;
                        repaired += 1;
                        continue;
                    }
                }

                let (label, short_preview) = match c.kind_tag.as_str() {
                    "sticker" => (
                        "Sticker mã hóa đầu cuối — Đồng bộ từ điện thoại để xem",
                        "[Sticker]",
                    ),
                    "photo" => (
                        "Hình ảnh mã hóa đầu cuối — Đồng bộ từ điện thoại để xem",
                        "[Hình ảnh]",
                    ),
                    "file" => (
                        "Tệp đính kèm mã hóa đầu cuối — Đồng bộ từ điện thoại để xem",
                        "[Tệp đính kèm]",
                    ),
                    "video" => (
                        "Video mã hóa đầu cuối — Đồng bộ từ điện thoại để xem",
                        "[Video]",
                    ),
                    "voice" => (
                        "Tin nhắn thoại mã hóa đầu cuối — Đồng bộ từ điện thoại để xem",
                        "[Tin nhắn thoại]",
                    ),
                    _ => (
                        "Tin nhắn mã hóa đầu cuối — Đồng bộ từ điện thoại để xem",
                        E2EE_PREVIEW,
                    ),
                };
                json_obj.insert(
                    "kind".into(),
                    json!({"type": "placeholder", "symbol": "lock.fill", "text": label}),
                );
                json_obj.insert("text".into(), json!(short_preview));
                json_obj.insert("isE2EE".into(), json!(true));
                json_obj.insert("undecryptedE2EE".into(), json!(true));
                let Some(updated) = to_swift_json(&Value::Object(json_obj)) else {
                    continue;
                };
                upd.execute(params![short_preview, updated, c.conv_id, c.id])?;
                repaired += 1;
            }

            // Sanitize conversation previews that hold raw Signal Base64.
            let poisoned_convs: Vec<String> = {
                let mut conv_stmt = tx.prepare_cached(
                    "SELECT id, preview_text FROM conversations WHERE preview_text LIKE 'AzM%' OR preview_text LIKE 'AjM%';",
                )?;
                let it = conv_stmt.query_map([], |r| Ok((col_text(r, 0)?, col_text(r, 1)?)))?;
                let mut v = Vec::new();
                for row in it {
                    let (cid, p_text) = row?;
                    if is_signal_ciphertext(&p_text) {
                        v.push(cid);
                    }
                }
                v
            };
            if !poisoned_convs.is_empty() {
                let mut fix = tx.prepare_cached(&format!(
                    "UPDATE conversations SET preview_text = '{E2EE_PREVIEW}' WHERE id = ?1;"
                ))?;
                for cid in poisoned_convs {
                    fix.execute(params![cid])?;
                    repaired += 1;
                }
            }
        }
        tx.commit()?;
        Ok(repaired)
    }

    // ---- Preferences ----

    /// Raw `value_json` bytes for `key`.
    pub fn get_preference_data(&self, key: &str) -> Result<Option<Vec<u8>>> {
        let v = self
            .db()?
            .prepare_cached("SELECT value_json FROM preferences WHERE key = ?1 LIMIT 1;")?
            .query_row(params![key], |r| col_text(r, 0))
            .optional()?;
        Ok(v.map(String::into_bytes))
    }

    /// Upserts raw `value_json` (invalid UTF-8 is stored as `{}` like Swift).
    pub fn set_preference_data(&mut self, key: &str, data: &[u8]) -> Result<()> {
        let text = String::from_utf8(data.to_vec()).unwrap_or_else(|_| "{}".to_owned());
        self.db()?
            .prepare_cached(
                "INSERT INTO preferences(key, value_json) VALUES (?1, ?2)
ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json;",
            )?
            .execute(params![key, text])?;
        Ok(())
    }

    /// Decodes the preference as a JSON string; `None` if absent or not a string.
    pub fn get_preference_string(&self, key: &str) -> Result<Option<String>> {
        Ok(self
            .get_preference_data(key)?
            .and_then(|d| serde_json::from_slice::<String>(&d).ok()))
    }

    /// Stores a JSON string (Swift `JSONEncoder`, which escapes `/`).
    pub fn set_preference_string(&mut self, key: &str, value: &str) -> Result<()> {
        let json = to_swift_json(&Value::String(value.to_owned())).unwrap_or_default();
        self.set_preference_data(key, json.as_bytes())
    }

    /// Decodes the preference as a JSON bool, else `default`.
    pub fn get_preference_bool(&self, key: &str, default: bool) -> Result<bool> {
        Ok(self
            .get_preference_data(key)?
            .and_then(|d| serde_json::from_slice::<bool>(&d).ok())
            .unwrap_or(default))
    }

    /// Stores a JSON bool.
    pub fn set_preference_bool(&mut self, key: &str, value: bool) -> Result<()> {
        self.set_preference_data(key, serde_json::to_string(&value)?.as_bytes())
    }

    /// Decodes the preference as `[String]`; empty when absent or malformed.
    pub fn get_preference_strings(&self, key: &str) -> Result<Vec<String>> {
        Ok(self
            .get_preference_data(key)?
            .and_then(|d| serde_json::from_slice::<Vec<String>>(&d).ok())
            .unwrap_or_default())
    }

    /// Stores a JSON string array (Swift `JSONEncoder`, which escapes `/`).
    pub fn set_preference_strings(&mut self, key: &str, value: &[String]) -> Result<()> {
        let v = Value::Array(value.iter().cloned().map(Value::String).collect());
        let json = to_swift_json(&v).unwrap_or_default();
        self.set_preference_data(key, json.as_bytes())
    }

    /// Deletes a preference.
    pub fn delete_preference(&mut self, key: &str) -> Result<()> {
        self.db()?
            .prepare_cached("DELETE FROM preferences WHERE key = ?1;")?
            .execute(params![key])?;
        Ok(())
    }

    /// Fast read through the dedicated read-only connection (Swift `readMessagesNow`).
    /// `None` when there is no reader (in-memory DB, closed store, or prepare failure).
    #[must_use]
    pub fn read_messages_now(
        &self,
        conv_id: &str,
        before_ts_ms: Option<i64>,
        limit: i64,
    ) -> Option<Vec<StoredMessage>> {
        query_messages(self.read_conn.as_ref()?, conv_id, before_ts_ms, limit).ok()
    }
}

/// A standalone read-only connection (WAL snapshot reads) for callers that must not wait on the writer's lock, e.g. the
/// synchronous "open a conversation" read. File databases only.
#[derive(Debug)]
pub struct ReadOnlyStore {
    conn: Connection,
}

impl ReadOnlyStore {
    /// `None` when the file cannot be opened read-only (missing, in-memory path).
    #[must_use]
    pub fn open(path: impl AsRef<Path>) -> Option<Self> {
        let path_ref = path.as_ref();
        if path_ref.to_string_lossy() == MEMORY_PATH {
            return None;
        }
        let conn = Connection::open_with_flags(
            path_ref,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_FULL_MUTEX,
        )
        .ok()?;
        conn.busy_timeout(std::time::Duration::from_millis(5000))
            .ok()?;
        register_search_functions(&conn).ok()?;
        conn.set_prepared_statement_cache_capacity(16);
        Some(Self { conn })
    }

    /// Same query as [`Store::read_messages_now`].
    #[must_use]
    pub fn messages_now(
        &self,
        conv_id: &str,
        before_ts_ms: Option<i64>,
        limit: i64,
    ) -> Option<Vec<StoredMessage>> {
        query_messages(&self.conn, conv_id, before_ts_ms, limit).ok()
    }
}

// ---- free functions shared by Store methods (operate on a Connection / Transaction) ----

fn query_messages(
    conn: &Connection,
    conv_id: &str,
    before_ts_ms: Option<i64>,
    limit: i64,
) -> Result<Vec<StoredMessage>> {
    let clamped = limit.clamp(1, 500);
    let mut desc = if let Some(before) = before_ts_ms {
        let mut stmt = conn.prepare_cached(&format!(
            "SELECT {MESSAGE_COLS}
FROM messages
WHERE conv_id = ?1 AND ts_ms < ?2
ORDER BY ts_ms DESC, id DESC
LIMIT ?3;"
        ))?;
        let rows = stmt.query_map(params![conv_id, before, clamped], read_stored_message)?;
        rows.collect::<rusqlite::Result<Vec<_>>>()?
    } else {
        let mut stmt = conn.prepare_cached(&format!(
            "SELECT {MESSAGE_COLS}
FROM messages
WHERE conv_id = ?1
ORDER BY ts_ms DESC, id DESC
LIMIT ?2;"
        ))?;
        let rows = stmt.query_map(params![conv_id, clamped], read_stored_message)?;
        rows.collect::<rusqlite::Result<Vec<_>>>()?
    };
    desc.reverse();
    Ok(desc)
}

fn message_in(
    conn: &Connection,
    conv_id: &str,
    id_or_client_id: &str,
) -> Result<Option<StoredMessage>> {
    let mut stmt = conn.prepare_cached(&format!(
        "SELECT {MESSAGE_COLS}
FROM messages
WHERE conv_id = ?1 AND id = ?2
UNION ALL
SELECT {MESSAGE_COLS}
FROM messages
WHERE conv_id = ?1 AND client_id = ?2 AND id != ?2
LIMIT 1;"
    ))?;
    Ok(stmt
        .query_row(params![conv_id, id_or_client_id], read_stored_message)
        .optional()?)
}

fn save_messages_in(conn: &Connection, items: &[StoredMessage], opts: SaveOptions) -> Result<()> {
    let raw_json_update_expr = if opts.preserve_existing_reactions {
        "CASE
        WHEN excluded.kind_tag != 'recalled'
             AND json_valid(messages.raw_json)
             AND json_valid(excluded.raw_json)
             AND COALESCE(json_array_length(excluded.raw_json, '$.reactions'), 0) = 0
             AND COALESCE(json_array_length(messages.raw_json, '$.reactions'), 0) > 0
        THEN json_set(excluded.raw_json, '$.reactions', json_extract(messages.raw_json, '$.reactions'))
        ELSE excluded.raw_json
    END"
    } else {
        "excluded.raw_json"
    };
    let upsert_sql = format!(
        "INSERT INTO messages(id, conv_id, client_id, sender_id, sender_name, sender_avatar, is_mine, text, kind_tag, ts_ms, status, raw_json)
VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
ON CONFLICT(conv_id, id) DO UPDATE SET
    client_id = CASE WHEN excluded.client_id != '' THEN excluded.client_id ELSE messages.client_id END,
    sender_id = CASE WHEN excluded.sender_id != '' THEN excluded.sender_id ELSE messages.sender_id END,
    sender_name = CASE WHEN excluded.sender_name != '' THEN excluded.sender_name ELSE messages.sender_name END,
    sender_avatar = CASE WHEN excluded.sender_avatar != '' THEN excluded.sender_avatar ELSE messages.sender_avatar END,
    is_mine = excluded.is_mine,
    text = excluded.text,
    kind_tag = excluded.kind_tag,
    ts_ms = CASE WHEN excluded.ts_ms > 0 THEN excluded.ts_ms ELSE messages.ts_ms END,
    status = excluded.status,
    raw_json = {raw_json_update_expr}
WHERE excluded.status != 'e2ee_locked' OR messages.status = 'e2ee_locked';"
    );
    let check_plain_twin_sql = "SELECT id FROM (
    SELECT id FROM messages WHERE conv_id = ?1 AND id = ?2 AND status != 'e2ee_locked'
    UNION ALL
    SELECT id FROM messages WHERE conv_id = ?1 AND client_id = ?2 AND status != 'e2ee_locked'
) LIMIT 1;";
    let delete_stale_id_twin_sql = "DELETE FROM messages
WHERE conv_id = ?1 AND id = ?3 AND id != ?2;";
    let delete_stale_client_twin_sql = "DELETE FROM messages
WHERE conv_id = ?1 AND client_id = ?3 AND id != ?2 AND status = 'e2ee_locked';";

    let mut upsert = conn.prepare_cached(&upsert_sql)?;
    let mut twin = if opts.skip_twin_checks {
        None
    } else {
        Some((
            conn.prepare_cached(check_plain_twin_sql)?,
            conn.prepare_cached(delete_stale_id_twin_sql)?,
            conn.prepare_cached(delete_stale_client_twin_sql)?,
        ))
    };

    for m in items {
        let is_locked = m.status == "e2ee_locked";
        if let Some((check, del_id, del_client)) = twin.as_mut()
            && !m.client_id.is_empty()
        {
            if is_locked {
                let existing = check
                    .query_row(params![m.conv_id, m.client_id], |r| col_text(r, 0))
                    .optional()?;
                if let Some(existing_id) = existing {
                    if existing_id == m.client_id && !m.id.is_empty() && m.id != m.client_id {
                        // Swift: `_ = try? performUpgradeMessageIdInTransaction(...)`
                        let _ = perform_upgrade_message_id(
                            conn,
                            &m.conv_id,
                            &m.client_id,
                            &m.id,
                            &m.client_id,
                        );
                    }
                    continue;
                }
            } else if m.client_id != m.id {
                del_id.execute(params![m.conv_id, m.id, m.client_id])?;
                del_client.execute(params![m.conv_id, m.id, m.client_id])?;
            }
        }
        let raw = std::str::from_utf8(&m.raw_json_data).unwrap_or("{}");
        upsert.execute(params![
            m.id,
            m.conv_id,
            m.client_id,
            m.sender_id,
            m.sender_name,
            m.sender_avatar,
            i32::from(m.is_mine),
            m.text,
            m.kind_tag,
            m.ts_ms,
            m.status,
            raw,
        ])?;
    }
    Ok(())
}

fn perform_upgrade_message_id(
    conn: &Connection,
    conv_id: &str,
    old_id: &str,
    new_id: &str,
    client_id: &str,
) -> Result<bool> {
    if conv_id.is_empty() || old_id.is_empty() || new_id.is_empty() || old_id == new_id {
        return Ok(false);
    }
    let target_exists = conn
        .prepare_cached("SELECT 1 FROM messages WHERE conv_id = ?1 AND id = ?2 LIMIT 1;")?
        .query_row(params![conv_id, new_id], |_| Ok(()))
        .optional()?
        .is_some();
    if target_exists {
        return Ok(false);
    }
    let old_raw = conn
        .prepare_cached(
            "SELECT raw_json FROM messages
WHERE conv_id = ?1 AND id = ?2 AND status != 'e2ee_locked'
LIMIT 1;",
        )?
        .query_row(params![conv_id, old_id], |r| col_text(r, 0))
        .optional()?;
    let Some(old_raw) = old_raw else {
        return Ok(false);
    };
    let updated_raw = match serde_json::from_str::<Value>(&old_raw) {
        Ok(Value::Object(mut obj)) => {
            obj.insert("id".into(), json!(new_id));
            if !client_id.is_empty() {
                obj.insert("clientId".into(), json!(client_id));
            }
            to_swift_json(&Value::Object(obj)).unwrap_or_else(|| old_raw.clone())
        }
        _ => old_raw.clone(),
    };
    let changed = conn
        .prepare_cached(
            "UPDATE messages
SET id = ?1,
    client_id = CASE WHEN ?2 != '' THEN ?2 ELSE client_id END,
    raw_json = ?3
WHERE conv_id = ?4 AND id = ?5 AND status != 'e2ee_locked';",
        )?
        .execute(params![new_id, client_id, updated_raw, conv_id, old_id])?;
    Ok(changed > 0)
}
