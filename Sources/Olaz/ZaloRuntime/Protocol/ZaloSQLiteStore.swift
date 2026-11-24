import Foundation
import OlazCore
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

/// A stored message decoded to a `ChatMessage` plus the table columns callers match on (`id`, `client_id`).
struct DecodedMessageRow: Sendable {
    var message: ChatMessage
    var rowId: String
    var rowClientId: String
}

struct StoredCloudConversationSummary: Equatable, Sendable {
    var convId: String
    var convName: String
    var convAvatar: String
    var isGroup: Bool
    var photoBytes: Int64
    var videoBytes: Int64
    var fileBytes: Int64
    var voiceBytes: Int64
    var itemCount: Int
    var lastActivityMs: Int64

    var totalBytes: Int64 { photoBytes + videoBytes + fileBytes + voiceBytes }
}

struct StoredCloudMediaItem: Equatable, Sendable {
    var id: String
    var clientId: String
    var convId: String
    var convName: String
    var kindTag: String
    var text: String
    var tsMs: Int64
    var fileName: String
    var sizeBytes: Int64
    var durationSec: Int
    var width: Int
    var height: Int
    var url: String
}

/// SQLite3 local store for Olaz conversations, message history, shared media index, and account preferences,
/// backed by Rust `CoreStore` (all public inputs/outputs are strictly `Sendable` for warning-free Swift 6 actor isolation).
actor ZaloSQLiteStore {
    let path: String
    nonisolated(unsafe) private var db: OpaquePointer?
    /// Rust store on the same file (ADR-010: same system SQLite, WAL).
    private let core: CoreStore

    init(path: String) throws {
        self.path = path
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            if let handle { sqlite3_close(handle) }
            throw ZaloSQLiteError.openFailed(msg)
        }
        sqlite3_busy_timeout(handle, 5000)
        do {
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
        CREATE INDEX IF NOT EXISTS idx_messages_conv_client ON messages(conv_id, client_id);
        CREATE INDEX IF NOT EXISTS idx_messages_kind_ts ON messages(kind_tag, ts_ms DESC);
        CREATE TABLE IF NOT EXISTS preferences (
            key TEXT PRIMARY KEY,
            value_json TEXT NOT NULL
        );
        """)
            self.core = try CoreStore.open(path: path)
            self.db = handle
        } catch let error as ZaloSQLiteError {
            sqlite3_close(handle)
            throw error
        } catch {
            sqlite3_close(handle)
            throw RustCore.mapError(error)
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    func close() {
        if let handle = db {
            sqlite3_close(handle)
            db = nil
        }
    }

    // MARK: - Conversations

    func saveConversations(_ items: [StoredConversation]) async throws {
        guard !items.isEmpty else { return }
        do { try await core.saveConversations(items: items.map(RustCore.row)) } catch { throw RustCore.mapError(error) }
    }

    func upsertConversation(_ item: StoredConversation) async throws {
        try await saveConversations([item])
    }

    func loadConversations() async throws -> [StoredConversation] {
        do {
            return try await core.loadConversations().map(RustCore.stored)
        } catch { throw RustCore.mapError(error) }
    }

    func setConversationUnread(id: String, unread: Int) async throws {
        do {
            try await core.setConversationUnread(id: id, unread: Int64(max(0, unread)))
        } catch { throw RustCore.mapError(error) }
    }

    func setConversationPinned(id: String, pinned: Bool) async throws {
        do {
            try await core.setConversationPinned(id: id, pinned: pinned)
        } catch { throw RustCore.mapError(error) }
    }

    func deleteConversation(id: String) async throws {
        do {
            try await core.deleteConversation(id: id)
        } catch { throw RustCore.mapError(error) }
    }

    // MARK: - Messages

    func hasAnyMessages() throws -> Bool {
        let stmt = try prepare("SELECT 1 FROM messages LIMIT 1;")
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    func messageIndexNames() throws -> [String] {
        let stmt = try prepare("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'messages';")
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw ZaloSQLiteError.stepFailed(lastError) }
            let name = columnText(stmt, 0)
            if !name.isEmpty { out.append(name) }
        }
        return out
    }

    func saveMessages(_ items: [StoredMessage], skipTwinChecks: Bool = false, preserveExistingReactions: Bool = false) async throws {
        do {
            try await core.saveMessagesWith(
                items: items.map(RustCore.row),
                skipTwinChecks: skipTwinChecks,
                preserveExistingReactions: preserveExistingReactions)
        } catch { throw RustCore.mapError(error) }
    }

    /// One-time migration scrubbing pre-fix corrupted/ghost reactions (entries missing `userCounts`
    /// or containing sentinel keys like `"__legacy__"` / `"unknown"` / placeholder `"Người dùng Zalo"`).
    @discardableResult
    func repairLegacyReactions(myUid: String) async throws -> Int {
        if (try? await getPreferenceString(key: "reactionRepairVersion")) == "2" {
            return 0
        }

        let cleanMyUid = ZaloWireParser.sanitizeProfileUid(myUid) ?? ZaloWireParser.stripUserPrefix(myUid)
        let sentinelKeys: Set<String> = ["", "__legacy__", "unknown", "-1"]

        let stmt = try prepare("""
        SELECT id, conv_id, raw_json
        FROM messages
        WHERE json_valid(raw_json)
          AND COALESCE(json_array_length(raw_json, '$.reactions'), 0) > 0;
        """)
        defer { sqlite3_finalize(stmt) }

        var rows: [(id: String, convId: String, rawJSON: String)] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw ZaloSQLiteError.stepFailed(lastError) }
            rows.append((
                id: columnText(stmt, 0),
                convId: columnText(stmt, 1),
                rawJSON: columnText(stmt, 2)
            ))
        }

        var repaired = 0
        try inTransaction {
            let updStmt = try prepare("UPDATE messages SET raw_json = ?1 WHERE conv_id = ?2 AND id = ?3;")
            defer { sqlite3_finalize(updStmt) }

            for row in rows {
                guard let rawData = row.rawJSON.data(using: .utf8),
                      var obj = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any],
                      let rawReacts = obj["reactions"] as? [[String: Any]] else {
                    continue
                }

                var cleanedReacts: [[String: Any]] = []
                for var react in rawReacts {
                    let typeStr = JSONLossless.string(react["type"]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let numericType = Int(typeStr), numericType < 0 {
                        continue
                    }
                    guard let ucDict = react["userCounts"] as? [String: Any], !ucDict.isEmpty else {
                        // Drop pre-fix legacy rows lacking `userCounts`.
                        continue
                    }

                    var normalizedUC: [String: Int] = [:]
                    for (rawKey, rawVal) in ucDict {
                        let trimmedKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !sentinelKeys.contains(trimmedKey) else { continue }
                        let countVal = Int(JSONLossless.int64(rawVal) ?? 0)
                        guard countVal > 0 else { continue }
                        let canonicalKey: String = {
                            if (trimmedKey == "0" || trimmedKey == "me"), !cleanMyUid.isEmpty {
                                return cleanMyUid
                            }
                            return ZaloWireParser.sanitizeProfileUid(trimmedKey) ?? trimmedKey
                        }()
                        guard !sentinelKeys.contains(canonicalKey) else { continue }
                        normalizedUC[canonicalKey, default: 0] += countVal
                    }

                    let totalCount = normalizedUC.values.reduce(0, +)
                    guard totalCount > 0 else { continue }

                    let includesMe = !cleanMyUid.isEmpty && (normalizedUC[cleanMyUid] ?? 0) > 0
                    let existingNames = (react["names"] as? [String] ?? []).filter {
                        let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        return !t.isEmpty && t != "Người dùng Zalo"
                    }
                    react["userCounts"] = normalizedUC
                    react["count"] = totalCount
                    react["people"] = normalizedUC.count
                    react["includesMe"] = includesMe
                    react["names"] = existingNames
                    cleanedReacts.append(react)
                }

                let changed: Bool = {
                    if cleanedReacts.count != rawReacts.count { return true }
                    guard let oldData = try? JSONSerialization.data(withJSONObject: rawReacts, options: [.sortedKeys]),
                          let newData = try? JSONSerialization.data(withJSONObject: cleanedReacts, options: [.sortedKeys]) else {
                        return true
                    }
                    return oldData != newData
                }()
                guard changed else { continue }

                obj["reactions"] = cleanedReacts
                guard let updatedData = try? JSONSerialization.data(withJSONObject: obj),
                      let updatedStr = String(data: updatedData, encoding: .utf8) else {
                    continue
                }
                sqlite3_reset(updStmt)
                sqlite3_clear_bindings(updStmt)
                bindText(updStmt, 1, updatedStr)
                bindText(updStmt, 2, row.convId)
                bindText(updStmt, 3, row.id)
                try stepDone(updStmt)
                repaired += 1
            }
        }

        try await setPreferenceString(key: "reactionRepairVersion", value: "2")
        return repaired
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
                WHERE conv_id = ?1 AND id = ?3 AND id != ?2 AND status != 'e2ee_locked'
                UNION ALL
                SELECT text, raw_json FROM messages
                WHERE conv_id = ?1 AND client_id = ?3 AND id != ?2 AND status != 'e2ee_locked'
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
    func messages(convId: String, beforeTsMs: Int64? = nil, limit: Int = 50) async throws -> [StoredMessage] {
        do {
            return try await core.messages(convId: convId, beforeTsMs: beforeTsMs, limit: Int64(limit)).map(RustCore.stored)
        } catch { throw RustCore.mapError(error) }
    }

    /// Searches stored messages in `conversationId` case-insensitively using `LIKE ? ESCAPE '\'`,
    /// returning newest-first (`ts_ms DESC`).
    func searchMessages(conversationId: String, query: String, limit: Int = 50) async throws -> [StoredMessage] {
        do {
            return try await core.searchMessages(convId: conversationId, query: query, limit: Int64(limit)).map(RustCore.stored)
        } catch { throw RustCore.mapError(error) }
    }

    /// Loads a context window anchored around a target timestamp (`ts_ms >= targetTsMs`, plus up to
    /// `contextBefore` older messages right before it), stopping before `beforeOldestTsMs` if provided.
    func messagesAround(
        convId: String,
        targetTsMs: Int64,
        beforeOldestTsMs: Int64?,
        contextBefore: Int = 25,
        maxWindow: Int = 3000
    ) async throws -> (messages: [StoredMessage], hasMoreOlder: Bool) {
        do {
            let page = try await core.messagesAround(
                convId: convId,
                targetTsMs: targetTsMs,
                beforeOldestTsMs: beforeOldestTsMs,
                contextBefore: Int64(contextBefore),
                maxWindow: Int64(maxWindow))
            return (page.messages.map(RustCore.stored), page.hasMoreOlder)
        } catch { throw RustCore.mapError(error) }
    }

    func message(convId: String, idOrClientId: String) async throws -> StoredMessage? {
        do {
            return try await core.message(convId: convId, idOrClientId: idOrClientId).map(RustCore.stored)
        } catch { throw RustCore.mapError(error) }
    }

    @discardableResult
    func upgradeMessageId(convId: String, oldId: String, newId: String, clientId: String) async throws -> Bool {
        do {
            return try await core.upgradeMessageId(convId: convId, oldId: oldId, newId: newId, clientId: clientId)
        } catch { throw RustCore.mapError(error) }
    }

    func deleteMessage(convId: String, id: String) async throws {
        do {
            try await core.deleteMessage(convId: convId, id: id)
        } catch { throw RustCore.mapError(error) }
    }

    func markRecalled(convId: String, id: String, cliMsgId: String = "") async throws {
        do {
            try await core.markRecalled(convId: convId, id: id, cliMsgId: cliMsgId)
        } catch { throw RustCore.mapError(error) }
    }

    func updateMessageReactionsJSON(convId: String, id: String, reactionsJSONData: Data) async throws {
        do {
            try await core.updateMessageReactionsJson(convId: convId, id: id, reactionsJson: reactionsJSONData)
        } catch { throw RustCore.mapError(error) }
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

    // MARK: - zCloud Media Aggregation & Queries

    private static let cloudItemSizeSQL = """
    CASE m.kind_tag
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
    END
    """

    /// Aggregates stored photo/video/file/voice media bytes and counts across all persisted conversations.
    func cloudMediaAggregation() throws -> [StoredCloudConversationSummary] {
        let sizeExpr = Self.cloudItemSizeSQL
        let sql = """
        SELECT
            m.conv_id,
            COALESCE(c.name, ''),
            COALESCE(c.avatar, ''),
            COALESCE(c.is_group, 0),
            SUM(CASE WHEN m.kind_tag = 'photo' THEN (\(sizeExpr)) ELSE 0 END) AS photo_bytes,
            SUM(CASE WHEN m.kind_tag = 'video' THEN (\(sizeExpr)) ELSE 0 END) AS video_bytes,
            SUM(CASE WHEN m.kind_tag = 'file' THEN (\(sizeExpr)) ELSE 0 END) AS file_bytes,
            SUM(CASE WHEN m.kind_tag = 'voice' THEN (\(sizeExpr)) ELSE 0 END) AS voice_bytes,
            COUNT(*) AS item_count,
            MAX(m.ts_ms) AS last_ts_ms
        FROM messages m
        LEFT JOIN conversations c ON c.id = m.conv_id
        WHERE m.kind_tag IN ('photo', 'video', 'file', 'voice')
          AND m.status != 'e2ee_locked'
        GROUP BY m.conv_id
        ORDER BY (photo_bytes + video_bytes + file_bytes + voice_bytes) DESC, last_ts_ms DESC;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var out: [StoredCloudConversationSummary] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw ZaloSQLiteError.stepFailed(lastError) }
            let convId = columnText(stmt, 0)
            let isGroupCol = sqlite3_column_type(stmt, 3) != SQLITE_NULL ? (sqlite3_column_int(stmt, 3) != 0) : ZaloWireParser.isGroupId(convId)
            out.append(StoredCloudConversationSummary(
                convId: convId,
                convName: columnText(stmt, 1),
                convAvatar: columnText(stmt, 2),
                isGroup: isGroupCol,
                photoBytes: sqlite3_column_int64(stmt, 4),
                videoBytes: sqlite3_column_int64(stmt, 5),
                fileBytes: sqlite3_column_int64(stmt, 6),
                voiceBytes: sqlite3_column_int64(stmt, 7),
                itemCount: Int(sqlite3_column_int64(stmt, 8)),
                lastActivityMs: sqlite3_column_int64(stmt, 9)
            ))
        }
        return out
    }

    /// Queries stored media items across all (or a single) persisted conversations with SQL-level sorting and pagination.
    func cloudMediaItems(
        convId: String? = nil,
        excludingConvId: String? = nil,
        kindTags: [String] = ["photo", "video", "file", "voice"],
        sortBySize: Bool = false,
        ascending: Bool = false,
        offset: Int = 0,
        limit: Int = 60
    ) throws -> (items: [StoredCloudMediaItem], hasMore: Bool) {
        let validTags = kindTags.filter { ["photo", "video", "file", "voice"].contains($0) }
        guard !validTags.isEmpty, limit > 0 else { return ([], false) }
        let clampedLimit = max(1, min(limit, 500))
        let safeOffset = max(0, offset)
        let fetchLimit = clampedLimit + 1

        var whereClauses = ["m.status != 'e2ee_locked'"]
        let tagPlaceholders = Array(repeating: "?", count: validTags.count).joined(separator: ",")
        whereClauses.append("m.kind_tag IN (\(tagPlaceholders))")
        if let convId, !convId.isEmpty {
            whereClauses.append("m.conv_id = ?")
        } else if let excludingConvId, !excludingConvId.isEmpty {
            whereClauses.append("m.conv_id != ?")
        }

        let dir = ascending ? "ASC" : "DESC"
        let orderClause = sortBySize
            ? "size_bytes \(dir), m.ts_ms DESC, m.id \(dir)"
            : "m.ts_ms \(dir), m.id \(dir)"
        let sizeExpr = Self.cloudItemSizeSQL

        let sql = """
        SELECT
            m.id,
            m.client_id,
            m.conv_id,
            COALESCE(c.name, ''),
            m.kind_tag,
            m.text,
            m.ts_ms,
            CASE WHEN json_valid(m.raw_json) THEN COALESCE(json_extract(m.raw_json, '$.kind.name'), '') ELSE '' END AS file_name,
            (\(sizeExpr)) AS size_bytes,
            CASE WHEN json_valid(m.raw_json) THEN COALESCE(CAST(json_extract(m.raw_json, '$.kind.duration') AS INTEGER), 0) ELSE 0 END AS dur_sec,
            CASE WHEN json_valid(m.raw_json) THEN COALESCE(CAST(json_extract(m.raw_json, '$.kind.width') AS INTEGER), 0) ELSE 0 END AS width_px,
            CASE WHEN json_valid(m.raw_json) THEN COALESCE(CAST(json_extract(m.raw_json, '$.kind.height') AS INTEGER), 0) ELSE 0 END AS height_px,
            CASE WHEN json_valid(m.raw_json) THEN COALESCE(json_extract(m.raw_json, '$.kind.url'), '') ELSE '' END AS media_url
        FROM messages m
        LEFT JOIN conversations c ON c.id = m.conv_id
        WHERE \(whereClauses.joined(separator: " AND "))
        ORDER BY \(orderClause)
        LIMIT ? OFFSET ?;
        """

        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        for tag in validTags {
            bindText(stmt, idx, tag); idx += 1
        }
        if let convId, !convId.isEmpty {
            bindText(stmt, idx, convId); idx += 1
        } else if let excludingConvId, !excludingConvId.isEmpty {
            bindText(stmt, idx, excludingConvId); idx += 1
        }
        sqlite3_bind_int(stmt, idx, Int32(fetchLimit)); idx += 1
        sqlite3_bind_int(stmt, idx, Int32(safeOffset))

        var collected: [StoredCloudMediaItem] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw ZaloSQLiteError.stepFailed(lastError) }
            collected.append(StoredCloudMediaItem(
                id: columnText(stmt, 0),
                clientId: columnText(stmt, 1),
                convId: columnText(stmt, 2),
                convName: columnText(stmt, 3),
                kindTag: columnText(stmt, 4),
                text: columnText(stmt, 5),
                tsMs: sqlite3_column_int64(stmt, 6),
                fileName: columnText(stmt, 7),
                sizeBytes: sqlite3_column_int64(stmt, 8),
                durationSec: max(0, Int(sqlite3_column_int64(stmt, 9))),
                width: max(0, Int(sqlite3_column_int64(stmt, 10))),
                height: max(0, Int(sqlite3_column_int64(stmt, 11))),
                url: columnText(stmt, 12)
            ))
        }
        let hasMore = collected.count > clampedLimit
        return (Array(collected.prefix(clampedLimit)), hasMore)
    }

    /// Returns the subset of `ids` (matching either `id` or `client_id`) already persisted in `convId`.
    func existingMessageIds(convId: String, ids: [String]) async throws -> Set<String> {
        do {
            return Set(try await core.existingMessageIds(convId: convId, ids: ids))
        } catch { throw RustCore.mapError(error) }
    }

    // MARK: - Preferences

    func getPreferenceData(key: String) async throws -> Data? {
        do {
            return try await core.preferenceData(key: key)
        } catch { throw RustCore.mapError(error) }
    }

    func setPreferenceData(key: String, data: Data) async throws {
        do {
            try await core.setPreferenceData(key: key, data: data)
        } catch { throw RustCore.mapError(error) }
    }

    func getPreferenceString(key: String) async throws -> String? {
        guard let data = try await getPreferenceData(key: key) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }

    func setPreferenceString(key: String, value: String) async throws {
        let data = try JSONEncoder().encode(value)
        try await setPreferenceData(key: key, data: data)
    }

    func getPreferenceBool(key: String, default fallback: Bool = false) async throws -> Bool {
        guard let data = try await getPreferenceData(key: key) else { return fallback }
        return (try? JSONDecoder().decode(Bool.self, from: data)) ?? fallback
    }

    func setPreferenceBool(key: String, value: Bool) async throws {
        let data = try JSONEncoder().encode(value)
        try await setPreferenceData(key: key, data: data)
    }

    func getPreferenceStrings(key: String) async throws -> [String] {
        guard let data = try await getPreferenceData(key: key) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    func setPreferenceStrings(key: String, value: [String]) async throws {
        let data = try JSONEncoder().encode(value)
        try await setPreferenceData(key: key, data: data)
    }

    func deletePreference(key: String) async throws {
        do {
            try await core.deletePreference(key: key)
        } catch { throw RustCore.mapError(error) }
    }

    // MARK: - Typed reads / writes (no JSON in Swift)

    private static func decoded(_ rows: [StoredChat]) -> [DecodedMessageRow] {
        rows.map { DecodedMessageRow(message: ChatMessage(record: $0.message), rowId: $0.rowId, rowClientId: $0.rowClientId) }
    }

    /// `messages(...)` decoded to `ChatMessage`s (decoded in the core, no JSON re-parse in Swift).
    func decodedMessages(convId: String, beforeTsMs: Int64? = nil, limit: Int = 50) async throws -> [DecodedMessageRow] {
        do { return Self.decoded(try await core.messagesChat(convId: convId, beforeTsMs: beforeTsMs, limit: Int64(limit))) }
        catch { throw RustCore.mapError(error) }
    }

    /// `message(convId:idOrClientId:)` decoded to a `ChatMessage` (nil when missing or undecodable).
    func decodedMessage(convId: String, idOrClientId: String) async throws -> DecodedMessageRow? {
        do {
            return try await core.messageChat(convId: convId, idOrClientId: idOrClientId).map {
                DecodedMessageRow(message: ChatMessage(record: $0.message), rowId: $0.rowId, rowClientId: $0.rowClientId)
            }
        } catch { throw RustCore.mapError(error) }
    }

    /// `searchMessages(...)` decoded to `ChatMessage`s.
    func decodedSearch(conversationId: String, query: String, limit: Int = 50) async throws -> [DecodedMessageRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !conversationId.isEmpty, !trimmed.isEmpty, limit > 0 else { return [] }
        do { return Self.decoded(try await core.searchMessagesChat(convId: conversationId, query: query, limit: Int64(limit))) }
        catch { throw RustCore.mapError(error) }
    }

    /// `messagesAround(...)` decoded to `ChatMessage`s.
    func decodedMessagesAround(
        convId: String,
        targetTsMs: Int64,
        beforeOldestTsMs: Int64?,
        contextBefore: Int = 25,
        maxWindow: Int = 3000
    ) async throws -> (rows: [DecodedMessageRow], hasMoreOlder: Bool) {
        do {
            let r = try await core.messagesAroundChat(
                convId: convId, targetTsMs: targetTsMs, beforeOldestTsMs: beforeOldestTsMs,
                contextBefore: Int64(contextBefore), maxWindow: Int64(maxWindow))
            return (Self.decoded(r.messages), r.hasMoreOlder)
        } catch { throw RustCore.mapError(error) }
    }

    /// Synchronous first-frame read decoded in the core on its separate read-only connection.
    nonisolated func readDecodedMessagesNow(convId: String, beforeTsMs: Int64? = nil, limit: Int = 50) -> [DecodedMessageRow]? {
        core.readChatMessagesNow(convId: convId, beforeTsMs: beforeTsMs, limit: Int64(limit)).map(Self.decoded)
    }

    /// Saves typed messages (encoded to the canonical row in the core).
    func saveChatMessages(_ items: [ChatMessage], skipTwinChecks: Bool = false, preserveExistingReactions: Bool = false) async throws {
        do {
            try await core.saveChatMessages(
                items: items.map { ChatMessageRecord(message: $0) },
                skipTwinChecks: skipTwinChecks, preserveExistingReactions: preserveExistingReactions)
        } catch { throw RustCore.mapError(error) }
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
