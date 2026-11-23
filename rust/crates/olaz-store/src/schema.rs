//! Verbatim schema from `ZaloSQLiteStore.init` (Swift). Do not reformat: SQLite
//! stores the statement text in `sqlite_master.sql`, and a database created by
//! either implementation must be indistinguishable from the other's.

/// PRAGMAs executed before the schema, in Swift order.
pub const PRAGMAS_SQL: &str = "PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA busy_timeout=5000;
";

/// `CREATE TABLE` / `CREATE INDEX` statements, in Swift order.
pub const SCHEMA_SQL: &str = r"CREATE TABLE IF NOT EXISTS conversations (
    id TEXT PRIMARY KEY,
    is_group INTEGER NOT NULL DEFAULT 0,
    name TEXT NOT NULL DEFAULT '',
    avatar TEXT NOT NULL DEFAULT '',
    pinned INTEGER NOT NULL DEFAULT 0,
    members INTEGER NOT NULL DEFAULT 0,
    unread INTEGER NOT NULL DEFAULT 0,
    preview_text TEXT NOT NULL DEFAULT '',
    preview_ts INTEGER NOT NULL DEFAULT 0,
    preview_from_me INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS messages (
    id TEXT NOT NULL,
    conv_id TEXT NOT NULL,
    client_id TEXT NOT NULL DEFAULT '',
    sender_id TEXT NOT NULL DEFAULT '',
    sender_name TEXT NOT NULL DEFAULT '',
    sender_avatar TEXT NOT NULL DEFAULT '',
    is_mine INTEGER NOT NULL DEFAULT 0,
    text TEXT NOT NULL DEFAULT '',
    kind_tag TEXT NOT NULL DEFAULT 'text',
    ts_ms INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'sent',
    raw_json TEXT NOT NULL,
    PRIMARY KEY (conv_id, id)
);
CREATE INDEX IF NOT EXISTS idx_messages_conv_ts ON messages(conv_id, ts_ms DESC);
CREATE INDEX IF NOT EXISTS idx_messages_conv_kind_ts ON messages(conv_id, kind_tag, ts_ms DESC);
CREATE INDEX IF NOT EXISTS idx_messages_conv_client ON messages(conv_id, client_id);
CREATE INDEX IF NOT EXISTS idx_messages_kind_ts ON messages(kind_tag, ts_ms DESC);
CREATE TABLE IF NOT EXISTS preferences (
    key TEXT PRIMARY KEY,
    value_json TEXT NOT NULL
);
";

/// SQL snippet computing a media item's byte size from `$.kind.size`, with the
/// per-kind fallbacks the Swift code uses (`cloudItemSizeSQL`).
pub const CLOUD_ITEM_SIZE_SQL: &str = "CASE m.kind_tag
    WHEN 'photo' THEN
        CASE WHEN json_valid(m.raw_json) AND COALESCE(CAST(json_extract(m.raw_json, '$.kind.size') AS INTEGER), 0) > 0
             THEN CAST(json_extract(m.raw_json, '$.kind.size') AS INTEGER)
             ELSE 150000 END
    WHEN 'video' THEN
        CASE WHEN json_valid(m.raw_json) AND COALESCE(CAST(json_extract(m.raw_json, '$.kind.size') AS INTEGER), 0) > 0
             THEN CAST(json_extract(m.raw_json, '$.kind.size') AS INTEGER)
             ELSE 1500000 END
    WHEN 'voice' THEN
        CASE WHEN json_valid(m.raw_json) AND COALESCE(CAST(json_extract(m.raw_json, '$.kind.size') AS INTEGER), 0) > 0
             THEN CAST(json_extract(m.raw_json, '$.kind.size') AS INTEGER)
             ELSE 40000 END
    WHEN 'file' THEN
        CASE WHEN json_valid(m.raw_json) AND COALESCE(CAST(json_extract(m.raw_json, '$.kind.size') AS INTEGER), 0) > 0
             THEN CAST(json_extract(m.raw_json, '$.kind.size') AS INTEGER)
             ELSE 0 END
    ELSE 0
END";
