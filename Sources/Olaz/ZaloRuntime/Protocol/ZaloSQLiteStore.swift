import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum ZaloSQLiteError: Error, LocalizedError, Sendable {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let m): return "SQLite open failed: \(m)"
        case .prepareFailed(let m): return "SQLite prepare failed: \(m)"
        case .stepFailed(let m): return "SQLite step failed: \(m)"
        }
    }
}

struct StoredConversation: Equatable, Sendable {
    var id: String
    var isGroup: Bool
    var name: String
    var avatar: String
    var pinned: Bool
    var members: Int
    var unread: Int
    var previewText: String
    var previewTsMs: Int64
    var previewFromMe: Bool
    var updatedAtMs: Int64
}

struct StoredMessage: Equatable, Sendable {
    var id: String
    var convId: String
    var clientId: String
    var senderId: String
    var senderName: String
    var senderAvatar: String
    var isMine: Bool
    var text: String
    var kindTag: String
    var tsMs: Int64
    var status: String
    var rawJSONData: Data
}

/// Pure Swift SQLite3 local store for Olaz conversations, message history, shared media index, and account preferences.
/// All public inputs and outputs are strictly `Sendable` so Swift 6 actor isolation remains warning-free.
actor ZaloSQLiteStore {
    let path: String
    nonisolated(unsafe) private var db: OpaquePointer?
    nonisolated(unsafe) private var readDb: OpaquePointer?
    private let readLock = NSLock()

    init(path: String) throws {
        self.path = path
        if path != ":memory:" {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            if let handle { sqlite3_close(handle) }
            throw ZaloSQLiteError.openFailed(msg)
        }
        self.db = handle
        try Self.exec(handle, """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        PRAGMA busy_timeout=5000;
        CREATE TABLE IF NOT EXISTS conversations (
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
        CREATE TABLE IF NOT EXISTS preferences (
            key TEXT PRIMARY KEY,
            value_json TEXT NOT NULL
        );
        """)
        if path != ":memory:" {
            var rHandle: OpaquePointer?
            if sqlite3_open_v2(path, &rHandle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
               let rHandle {
                sqlite3_busy_timeout(rHandle, 5000)
                self.readDb = rHandle
            }
        }
    }

    deinit {
        if let readDb { sqlite3_close(readDb) }
        if let db { sqlite3_close(db) }
    }

    func close() {
        readLock.lock()
        if let rHandle = readDb {
            sqlite3_close(rHandle)
            readDb = nil
        }
        readLock.unlock()
        if let handle = db {
            sqlite3_close(handle)
            db = nil
        }
    }

    // MARK: - Conversations

    func saveConversations(_ items: [StoredConversation]) throws {
        guard !items.isEmpty else { return }
        try inTransaction {
            let sql = """
            INSERT INTO conversations(id, is_group, name, avatar, pinned, members, unread, preview_text, preview_ts, preview_from_me, updated_at)
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
                updated_at = excluded.updated_at;
            """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            for c in items {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, c.id)
                sqlite3_bind_int(stmt, 2, c.isGroup ? 1 : 0)
                bindText(stmt, 3, c.name)
                bindText(stmt, 4, c.avatar)
                sqlite3_bind_int(stmt, 5, c.pinned ? 1 : 0)
                sqlite3_bind_int(stmt, 6, Int32(c.members))
                sqlite3_bind_int(stmt, 7, Int32(c.unread))
                bindText(stmt, 8, c.previewText)
                sqlite3_bind_int64(stmt, 9, c.previewTsMs)
                sqlite3_bind_int(stmt, 10, c.previewFromMe ? 1 : 0)
                sqlite3_bind_int64(stmt, 11, c.updatedAtMs)
                try stepDone(stmt)
            }
        }
    }

    func upsertConversation(_ item: StoredConversation) throws {
        try saveConversations([item])
    }

    func loadConversations() throws -> [StoredConversation] {
        let sql = """
        SELECT id, is_group, name, avatar, pinned, members, unread, preview_text, preview_ts, preview_from_me, updated_at
        FROM conversations
        ORDER BY pinned DESC, preview_ts DESC, updated_at DESC;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var out: [StoredConversation] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw ZaloSQLiteError.stepFailed(lastError) }
            out.append(StoredConversation(
                id: columnText(stmt, 0),
                isGroup: sqlite3_column_int(stmt, 1) != 0,
                name: columnText(stmt, 2),
                avatar: columnText(stmt, 3),
                pinned: sqlite3_column_int(stmt, 4) != 0,
                members: Int(sqlite3_column_int(stmt, 5)),
                unread: Int(sqlite3_column_int(stmt, 6)),
                previewText: columnText(stmt, 7),
                previewTsMs: sqlite3_column_int64(stmt, 8),
                previewFromMe: sqlite3_column_int(stmt, 9) != 0,
                updatedAtMs: sqlite3_column_int64(stmt, 10)
            ))
        }
        return out
    }

    func setConversationUnread(id: String, unread: Int) throws {
        let stmt = try prepare("UPDATE conversations SET unread = ?1 WHERE id = ?2;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(max(0, unread)))
        bindText(stmt, 2, id)
        try stepDone(stmt)
    }

    func setConversationPinned(id: String, pinned: Bool) throws {
        let stmt = try prepare("UPDATE conversations SET pinned = ?1 WHERE id = ?2;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, pinned ? 1 : 0)
        bindText(stmt, 2, id)
        try stepDone(stmt)
    }

    func deleteConversation(id: String) throws {
        try inTransaction {
            let s1 = try prepare("DELETE FROM messages WHERE conv_id = ?1;")
            defer { sqlite3_finalize(s1) }
            bindText(s1, 1, id)
            try stepDone(s1)

            let s2 = try prepare("DELETE FROM conversations WHERE id = ?1;")
            defer { sqlite3_finalize(s2) }
            bindText(s2, 1, id)
            try stepDone(s2)
        }
    }

    // MARK: - Messages

    func saveMessages(_ items: [StoredMessage]) throws {
        guard !items.isEmpty else { return }
        try inTransaction {
            let upsertSQL = """
            INSERT INTO messages(id, conv_id, client_id, sender_id, sender_name, sender_avatar, is_mine, text, kind_tag, ts_ms, status, raw_json)
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
                raw_json = excluded.raw_json
            WHERE excluded.status != 'e2ee_locked' OR messages.status = 'e2ee_locked';
            """
            let checkPlainTwinSQL = """
            SELECT 1 FROM messages
            WHERE conv_id = ?1 AND (id = ?2 OR client_id = ?2) AND status != 'e2ee_locked'
            LIMIT 1;
            """
            let deleteStaleTwinSQL = """
            DELETE FROM messages
            WHERE conv_id = ?1 AND id != ?2 AND (id = ?3 OR (client_id = ?3 AND status = 'e2ee_locked'));
            """
            let stmt = try prepare(upsertSQL)
            defer { sqlite3_finalize(stmt) }
            let checkStmt = try prepare(checkPlainTwinSQL)
            defer { sqlite3_finalize(checkStmt) }
            let delStmt = try prepare(deleteStaleTwinSQL)
            defer { sqlite3_finalize(delStmt) }

            for m in items {
                let isLocked = (m.status == "e2ee_locked")
                if !m.clientId.isEmpty {
                    if isLocked {
                        sqlite3_reset(checkStmt)
                        sqlite3_clear_bindings(checkStmt)
                        bindText(checkStmt, 1, m.convId)
                        bindText(checkStmt, 2, m.clientId)
                        if sqlite3_step(checkStmt) == SQLITE_ROW {
                            continue
                        }
                    } else if m.clientId != m.id {
                        sqlite3_reset(delStmt)
                        sqlite3_clear_bindings(delStmt)
                        bindText(delStmt, 1, m.convId)
                        bindText(delStmt, 2, m.id)
                        bindText(delStmt, 3, m.clientId)
                        try stepDone(delStmt)
                    }
                }

                let rawStr = String(data: m.rawJSONData, encoding: .utf8) ?? "{}"
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, m.id)
                bindText(stmt, 2, m.convId)
                bindText(stmt, 3, m.clientId)
                bindText(stmt, 4, m.senderId)
                bindText(stmt, 5, m.senderName)
                bindText(stmt, 6, m.senderAvatar)
                sqlite3_bind_int(stmt, 7, m.isMine ? 1 : 0)
                bindText(stmt, 8, m.text)
                bindText(stmt, 9, m.kindTag)
                sqlite3_bind_int64(stmt, 10, m.tsMs)
                bindText(stmt, 11, m.status)
                bindText(stmt, 12, rawStr)
                try stepDone(stmt)
            }
        }
    }

    /// Scans for any legacy undecrypted Signal ciphertext rows (`AzM...` / `AjM...` / `?eid=AzM...` / `?e2esession=AzM...`),
    /// deletes duplicates that already have a plaintext twin, and converts remaining ones into clean `.placeholder` lock cards.
    @discardableResult
    func repairUndecryptedE2EEMessages() throws -> Int {
        let querySQL = """
        SELECT id, conv_id, client_id, kind_tag, text, raw_json
        FROM messages
        WHERE status != 'e2ee_locked'
          AND (
              text LIKE 'AzM%' OR text LIKE 'AjM%'
              OR raw_json LIKE '%eid=AzM%' OR raw_json LIKE '%eid=AjM%'
              OR raw_json LIKE '%e2esession=AzM%' OR raw_json LIKE '%e2esession=AjM%'
          );
        """
        let stmt = try prepare(querySQL)
        defer { sqlite3_finalize(stmt) }

        struct Candidate {
            let id: String
            let convId: String
            let clientId: String
            let kindTag: String
            let text: String
            let rawJSON: String
        }
        var candidates: [Candidate] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw ZaloSQLiteError.stepFailed(lastError) }
            candidates.append(Candidate(
                id: columnText(stmt, 0),
                convId: columnText(stmt, 1),
                clientId: columnText(stmt, 2),
                kindTag: columnText(stmt, 3),
                text: columnText(stmt, 4),
                rawJSON: columnText(stmt, 5)
            ))
        }

        var repaired = 0
        try inTransaction {
            let twinCheck = try prepare("""
                SELECT text, raw_json FROM messages
                WHERE conv_id = ?1 AND id != ?2 AND (id = ?3 OR client_id = ?3) AND status != 'e2ee_locked'
                LIMIT 5;
            """)
            defer { sqlite3_finalize(twinCheck) }

            let delStmt = try prepare("DELETE FROM messages WHERE conv_id = ?1 AND id = ?2;")
            defer { sqlite3_finalize(delStmt) }

            let updStmt = try prepare("""
                UPDATE messages
                SET text = ?1, kind_tag = 'placeholder', status = 'e2ee_locked', raw_json = ?2
                WHERE conv_id = ?3 AND id = ?4;
            """)
            defer { sqlite3_finalize(updStmt) }

            for c in candidates {
                guard var jsonObj = c.rawJSON.data(using: .utf8).flatMap({ JSONLossless.parseObject($0) }) else {
                    continue
                }
                let kindObj = jsonObj["kind"] as? [String: Any]
                let kindURL = JSONLossless.string(kindObj?["url"])
                let isPoisonedText = ZaloWireParser.isSignalCiphertext(c.text)
                let isPoisonedMedia = ZaloWireParser.isSignalCiphertext(kindURL) || ZaloWireParser.urlHasUndecryptedSignalCipher(kindURL)
                guard isPoisonedText || isPoisonedMedia else { continue }

                // If a real decrypted twin already exists for the same `client_id`, drop the duplicate ciphertext row!
                if !c.clientId.isEmpty {
                    sqlite3_reset(twinCheck)
                    sqlite3_clear_bindings(twinCheck)
                    bindText(twinCheck, 1, c.convId)
                    bindText(twinCheck, 2, c.id)
                    bindText(twinCheck, 3, c.clientId)
                    var hasCleanTwin = false
                    while sqlite3_step(twinCheck) == SQLITE_ROW {
                        let tText = columnText(twinCheck, 0)
                        let tRaw = columnText(twinCheck, 1)
                        if !ZaloWireParser.isSignalCiphertext(tText)
                            && !tRaw.contains("eid=AzM")
                            && !tRaw.contains("eid=AjM") {
                            hasCleanTwin = true
                            break
                        }
                    }
                    if hasCleanTwin {
                        sqlite3_reset(delStmt)
                        sqlite3_clear_bindings(delStmt)
                        bindText(delStmt, 1, c.convId)
                        bindText(delStmt, 2, c.id)
                        try stepDone(delStmt)
                        repaired += 1
                        continue
                    }
                }

                let (placeholderLabel, shortPreview): (String, String) = {
                    switch c.kindTag {
                    case "sticker":
                        return ("Sticker mã hóa đầu cuối — Đồng bộ từ điện thoại để xem", "[Sticker]")
                    case "photo":
                        return ("Hình ảnh mã hóa đầu cuối — Đồng bộ từ điện thoại để xem", "[Hình ảnh]")
                    case "file":
                        return ("Tệp đính kèm mã hóa đầu cuối — Đồng bộ từ điện thoại để xem", "[Tệp đính kèm]")
                    case "video":
                        return ("Video mã hóa đầu cuối — Đồng bộ từ điện thoại để xem", "[Video]")
                    case "voice":
                        return ("Tin nhắn thoại mã hóa đầu cuối — Đồng bộ từ điện thoại để xem", "[Tin nhắn thoại]")
                    default:
                        return ("Tin nhắn mã hóa đầu cuối — Đồng bộ từ điện thoại để xem", "🔒 Tin nhắn mã hóa đầu cuối")
                    }
                }()

                jsonObj["kind"] = [
                    "type": "placeholder",
                    "symbol": "lock.fill",
                    "text": placeholderLabel,
                ]
                jsonObj["text"] = shortPreview
                jsonObj["isE2EE"] = true
                jsonObj["undecryptedE2EE"] = true
                guard let updatedData = try? JSONSerialization.data(withJSONObject: jsonObj),
                      let updatedStr = String(data: updatedData, encoding: .utf8) else {
                    continue
                }

                sqlite3_reset(updStmt)
                sqlite3_clear_bindings(updStmt)
                bindText(updStmt, 1, shortPreview)
                bindText(updStmt, 2, updatedStr)
                bindText(updStmt, 3, c.convId)
                bindText(updStmt, 4, c.id)
                try stepDone(updStmt)
                repaired += 1
            }

            // Also sanitize any conversation preview_text that currently holds raw Signal Base64
            let convStmt = try prepare("SELECT id, preview_text FROM conversations WHERE preview_text LIKE 'AzM%' OR preview_text LIKE 'AjM%';")
            defer { sqlite3_finalize(convStmt) }
            var poisonedConvs: [String] = []
            while sqlite3_step(convStmt) == SQLITE_ROW {
                let cid = columnText(convStmt, 0)
                let pText = columnText(convStmt, 1)
                if ZaloWireParser.isSignalCiphertext(pText) {
                    poisonedConvs.append(cid)
                }
            }
            if !poisonedConvs.isEmpty {
                let fixConv = try prepare("UPDATE conversations SET preview_text = '🔒 Tin nhắn mã hóa đầu cuối' WHERE id = ?1;")
                defer { sqlite3_finalize(fixConv) }
                for cid in poisonedConvs {
                    sqlite3_reset(fixConv)
                    sqlite3_clear_bindings(fixConv)
                    bindText(fixConv, 1, cid)
                    try stepDone(fixConv)
                    repaired += 1
                }
            }
        }
        return repaired
    }

    /// Loads messages for `convId` in chronological ascending order (oldest -> newest).
    /// When `beforeTsMs` is provided, fetches messages strictly older than `beforeTsMs`.
    func messages(convId: String, beforeTsMs: Int64? = nil, limit: Int = 50) throws -> [StoredMessage] {
        let clampedLimit = max(1, min(limit, 500))
        let sql: String
        if beforeTsMs != nil {
            sql = """
            SELECT id, conv_id, client_id, sender_id, sender_name, sender_avatar, is_mine, text, kind_tag, ts_ms, status, raw_json
            FROM messages
            WHERE conv_id = ?1 AND ts_ms < ?2
            ORDER BY ts_ms DESC, id DESC
            LIMIT ?3;
            """
        } else {
            sql = """
            SELECT id, conv_id, client_id, sender_id, sender_name, sender_avatar, is_mine, text, kind_tag, ts_ms, status, raw_json
            FROM messages
            WHERE conv_id = ?1
            ORDER BY ts_ms DESC, id DESC
            LIMIT ?2;
            """
        }
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, convId)
        if let beforeTsMs {
            sqlite3_bind_int64(stmt, 2, beforeTsMs)
            sqlite3_bind_int(stmt, 3, Int32(clampedLimit))
        } else {
            sqlite3_bind_int(stmt, 2, Int32(clampedLimit))
        }
        var desc: [StoredMessage] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw ZaloSQLiteError.stepFailed(lastError) }
            let raw = columnText(stmt, 11)
            desc.append(StoredMessage(
                id: columnText(stmt, 0),
                convId: columnText(stmt, 1),
                clientId: columnText(stmt, 2),
                senderId: columnText(stmt, 3),
                senderName: columnText(stmt, 4),
                senderAvatar: columnText(stmt, 5),
                isMine: sqlite3_column_int(stmt, 6) != 0,
                text: columnText(stmt, 7),
                kindTag: columnText(stmt, 8),
                tsMs: sqlite3_column_int64(stmt, 9),
                status: columnText(stmt, 10),
                rawJSONData: Data(raw.utf8)
            ))
        }
        return desc.reversed()
    }

    func message(convId: String, idOrClientId: String) throws -> StoredMessage? {
        let sql = """
        SELECT id, conv_id, client_id, sender_id, sender_name, sender_avatar, is_mine, text, kind_tag, ts_ms, status, raw_json
        FROM messages
        WHERE conv_id = ?1 AND (id = ?2 OR client_id = ?2)
        LIMIT 1;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, convId)
        bindText(stmt, 2, idOrClientId)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else { throw ZaloSQLiteError.stepFailed(lastError) }
        return StoredMessage(
            id: columnText(stmt, 0),
            convId: columnText(stmt, 1),
            clientId: columnText(stmt, 2),
            senderId: columnText(stmt, 3),
            senderName: columnText(stmt, 4),
            senderAvatar: columnText(stmt, 5),
            isMine: sqlite3_column_int(stmt, 6) != 0,
            text: columnText(stmt, 7),
            kindTag: columnText(stmt, 8),
            tsMs: sqlite3_column_int64(stmt, 9),
            status: columnText(stmt, 10),
            rawJSONData: Data(columnText(stmt, 11).utf8)
        )
    }

    func deleteMessage(convId: String, id: String) throws {
        let stmt = try prepare("DELETE FROM messages WHERE conv_id = ?1 AND (id = ?2 OR client_id = ?2);")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, convId)
        bindText(stmt, 2, id)
        try stepDone(stmt)
    }

    func markRecalled(convId: String, id: String) throws {
        guard let existing = try message(convId: convId, idOrClientId: id),
              var dict = (try? JSONSerialization.jsonObject(with: existing.rawJSONData)) as? [String: Any] else {
            return
        }
        dict["type"] = "recalled"
        dict["kind"] = ["type": "recalled"]
        dict["text"] = ""
        guard let updatedData = try? JSONSerialization.data(withJSONObject: dict) else { return }
        let updated = StoredMessage(
            id: existing.id, convId: existing.convId, clientId: existing.clientId,
            senderId: existing.senderId, senderName: existing.senderName, senderAvatar: existing.senderAvatar,
            isMine: existing.isMine, text: "", kindTag: "recalled", tsMs: existing.tsMs,
            status: existing.status, rawJSONData: updatedData
        )
        try saveMessages([updated])
    }

    func updateMessageReactionsJSON(convId: String, id: String, reactionsJSONData: Data) throws {
        guard let existing = try message(convId: convId, idOrClientId: id),
              var dict = (try? JSONSerialization.jsonObject(with: existing.rawJSONData)) as? [String: Any],
              let reactionsObj = try? JSONSerialization.jsonObject(with: reactionsJSONData) else {
            return
        }
        dict["reactions"] = reactionsObj
        guard let updatedData = try? JSONSerialization.data(withJSONObject: dict) else { return }
        let updated = StoredMessage(
            id: existing.id, convId: existing.convId, clientId: existing.clientId,
            senderId: existing.senderId, senderName: existing.senderName, senderAvatar: existing.senderAvatar,
            isMine: existing.isMine, text: existing.text, kindTag: existing.kindTag, tsMs: existing.tsMs,
            status: existing.status, rawJSONData: updatedData
        )
        try saveMessages([updated])
    }

    /// Queries locally indexed shared-media JSON blobs for `convId` filtered by `kindTags`.
    /// Cursor format: `"<tsMs>|<id>"` for newest-first keyset pagination.
    func sharedMediaRaw(convId: String, kindTags: [String], afterCursor: String?, limit: Int) throws -> (rows: [Data], cursor: String?, more: Bool) {
        guard !kindTags.isEmpty else { return ([], nil, false) }
        let fetchLimit = max(1, min(limit, 200)) + 1
        let placeholders = Array(repeating: "?", count: kindTags.count).joined(separator: ",")
        let cursorParts = afterCursor?.split(separator: "|", maxSplits: 1).map(String.init)
        let cursorTs = cursorParts.flatMap { Int64($0[0]) }
        let cursorId = (cursorParts?.count == 2) ? cursorParts?[1] : nil

        let sql: String
        if cursorTs != nil && cursorId != nil {
            sql = """
            SELECT id, ts_ms, raw_json
            FROM messages
            WHERE conv_id = ? AND kind_tag IN (\(placeholders))
              AND (ts_ms < ? OR (ts_ms = ? AND id < ?))
            ORDER BY ts_ms DESC, id DESC
            LIMIT ?;
            """
        } else {
            sql = """
            SELECT id, ts_ms, raw_json
            FROM messages
            WHERE conv_id = ? AND kind_tag IN (\(placeholders))
            ORDER BY ts_ms DESC, id DESC
            LIMIT ?;
            """
        }

        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var bindIdx: Int32 = 1
        bindText(stmt, bindIdx, convId); bindIdx += 1
        for tag in kindTags {
            bindText(stmt, bindIdx, tag); bindIdx += 1
        }
        if let cursorTs, let cursorId {
            sqlite3_bind_int64(stmt, bindIdx, cursorTs); bindIdx += 1
            sqlite3_bind_int64(stmt, bindIdx, cursorTs); bindIdx += 1
            bindText(stmt, bindIdx, cursorId); bindIdx += 1
        }
        sqlite3_bind_int(stmt, bindIdx, Int32(fetchLimit))

        var collected: [(id: String, ts: Int64, data: Data)] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw ZaloSQLiteError.stepFailed(lastError) }
            let id = columnText(stmt, 0)
            let ts = sqlite3_column_int64(stmt, 1)
            let raw = Data(columnText(stmt, 2).utf8)
            collected.append((id, ts, raw))
        }

        let hasMore = collected.count >= fetchLimit
        let page = Array(collected.prefix(max(1, min(limit, 200))))
        let nextCursor = hasMore ? page.last.map { "\($0.ts)|\($0.id)" } : nil
        return (page.map(\.data), nextCursor, hasMore)
    }

    // MARK: - Preferences

    func getPreferenceData(key: String) throws -> Data? {
        let stmt = try prepare("SELECT value_json FROM preferences WHERE key = ?1 LIMIT 1;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else { throw ZaloSQLiteError.stepFailed(lastError) }
        return Data(columnText(stmt, 0).utf8)
    }

    func setPreferenceData(key: String, data: Data) throws {
        let stmt = try prepare("""
        INSERT INTO preferences(key, value_json) VALUES (?1, ?2)
        ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json;
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        bindText(stmt, 2, String(data: data, encoding: .utf8) ?? "{}")
        try stepDone(stmt)
    }

    func getPreferenceString(key: String) throws -> String? {
        guard let data = try getPreferenceData(key: key) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }

    func setPreferenceString(key: String, value: String) throws {
        let data = try JSONEncoder().encode(value)
        try setPreferenceData(key: key, data: data)
    }

    func getPreferenceBool(key: String, default fallback: Bool = false) throws -> Bool {
        guard let data = try getPreferenceData(key: key) else { return fallback }
        return (try? JSONDecoder().decode(Bool.self, from: data)) ?? fallback
    }

    func setPreferenceBool(key: String, value: Bool) throws {
        let data = try JSONEncoder().encode(value)
        try setPreferenceData(key: key, data: data)
    }

    func getPreferenceStrings(key: String) throws -> [String] {
        guard let data = try getPreferenceData(key: key) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    func setPreferenceStrings(key: String, value: [String]) throws {
        let data = try JSONEncoder().encode(value)
        try setPreferenceData(key: key, data: data)
    }

    func deletePreference(key: String) throws {
        let stmt = try prepare("DELETE FROM preferences WHERE key = ?1;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        try stepDone(stmt)
    }

    nonisolated func readMessagesNow(convId: String, beforeTsMs: Int64? = nil, limit: Int = 50) -> [StoredMessage]? {
        readLock.lock()
        defer { readLock.unlock() }
        guard let handle = readDb else { return nil }
        let clampedLimit = max(1, min(limit, 500))
        let cols = "id, conv_id, client_id, sender_id, sender_name, sender_avatar, is_mine, text, kind_tag, ts_ms, status, raw_json"
        let sql = beforeTsMs != nil
            ? "SELECT \(cols) FROM messages WHERE conv_id = ?1 AND ts_ms < ?2 ORDER BY ts_ms DESC, id DESC LIMIT ?3;"
            : "SELECT \(cols) FROM messages WHERE conv_id = ?1 ORDER BY ts_ms DESC, id DESC LIMIT ?2;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, convId, -1, SQLITE_TRANSIENT)
        if let beforeTsMs {
            sqlite3_bind_int64(stmt, 2, beforeTsMs)
            sqlite3_bind_int(stmt, 3, Int32(clampedLimit))
        } else {
            sqlite3_bind_int(stmt, 2, Int32(clampedLimit))
        }
        var desc: [StoredMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let col: (Int32) -> String = { idx in
                guard let ptr = sqlite3_column_text(stmt, idx) else { return "" }
                return String(cString: ptr)
            }
            let raw = col(11)
            desc.append(StoredMessage(
                id: col(0),
                convId: col(1),
                clientId: col(2),
                senderId: col(3),
                senderName: col(4),
                senderAvatar: col(5),
                isMine: sqlite3_column_int(stmt, 6) != 0,
                text: col(7),
                kindTag: col(8),
                tsMs: sqlite3_column_int64(stmt, 9),
                status: col(10),
                rawJSONData: Data(raw.utf8)
            ))
        }
        return desc.reversed()
    }

    // MARK: - Low-level SQLite Helpers

    private var lastError: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed"
    }

    private func exec(_ sql: String) throws {
        try Self.exec(db, sql)
    }

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        guard let db else { throw ZaloSQLiteError.openFailed("closed") }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(errMsg)
            throw ZaloSQLiteError.stepFailed(msg)
        }
    }

    private func inTransaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try body()
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw ZaloSQLiteError.openFailed("closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw ZaloSQLiteError.prepareFailed(lastError)
        }
        return stmt
    }

    private func bindText(_ stmt: OpaquePointer, _ idx: Int32, _ value: String) {
        sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT)
    }

    private func columnText(_ stmt: OpaquePointer, _ idx: Int32) -> String {
        guard let ptr = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: ptr)
    }

    private func stepDone(_ stmt: OpaquePointer) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw ZaloSQLiteError.stepFailed(lastError)
        }
    }
}
