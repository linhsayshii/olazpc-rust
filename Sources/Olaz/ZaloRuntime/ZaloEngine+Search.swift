import OlazCore
import Foundation

extension ZaloEngine {
    /// Returns `true` when `message` matches `query` case-insensitively across its text/caption/card content.
    nonisolated static func messageMatchesSearchQuery(_ message: ChatMessage, query: String) -> Bool {
        coreMessageMatchesSearchQuery(message: ChatMessageRecord(message: message), query: query)
    }

    // U6: bridge until U6 moves pending-deleted message state into olaz-core.
    private func pendingDeletedSearchKeys(in convId: String) -> [String] {
        var keys: [String] = []
        var seen = Set<String>()
        for msg in pendingDeletedMessages.values.joined() where msg.conversationId == convId {
            if !msg.id.isEmpty, seen.insert(msg.id).inserted {
                keys.append(msg.id)
            }
            if !msg.clientId.isEmpty, seen.insert(msg.clientId).inserted {
                keys.append(msg.clientId)
            }
        }
        return keys
    }

    /// Searches in-memory messages and SQLite history for `convId`, deduplicated by message/client ID and ordered newest-first.
    func searchMessages(in convId: String, query: String, limit: Int = 50) async -> [ChatMessage] {
        // U6: bridge pendingDeletedMessages into core until U6 owns pending deletes.
        let pendingDeletedKeys = pendingDeletedSearchKeys(in: convId)
        if let core = coreLifecycle.core {
            guard let res = try? await core.searchMessages(
                convId: convId,
                query: query,
                limit: Int64(limit),
                pendingDeletedKeys: pendingDeletedKeys
            ) else {
                return []
            }
            await waitForMirrorVersion(res.settledVersion)
            return res.messages.map(ChatMessage.init(record:))
        }

        // Offline fallback for unit tests that construct ZaloEngine without calling start().
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !convId.isEmpty, !trimmed.isEmpty, limit > 0 else { return [] }
        let clampedLimit = max(1, min(limit, 500))

        let pendingDeletedIds = Set(pendingDeletedKeys)
        let inMemory = messages[convId] ?? []
        var memoryKeys = Set<String>()
        memoryKeys.reserveCapacity(inMemory.count * 2)
        for msg in inMemory {
            memoryKeys.insert(msg.id)
            if !msg.clientId.isEmpty { memoryKeys.insert(msg.clientId) }
        }

        var results: [ChatMessage] = []
        var seenIds = Set<String>()

        for msg in inMemory {
            if pendingDeletedIds.contains(msg.id)
                || (!msg.clientId.isEmpty && pendingDeletedIds.contains(msg.clientId)) {
                continue
            }
            guard Self.messageMatchesSearchQuery(msg, query: trimmed) else { continue }
            if seenIds.insert(msg.id).inserted {
                if !msg.clientId.isEmpty { seenIds.insert(msg.clientId) }
                results.append(msg)
            }
        }

        let storedMatches = (try? await sqliteStore?.decodedSearch(conversationId: convId, query: trimmed, limit: clampedLimit)) ?? []
        for row in storedMatches {
            let storedId = row.rowId, storedClientId = row.rowClientId
            if pendingDeletedIds.contains(storedId) || (!storedClientId.isEmpty && pendingDeletedIds.contains(storedClientId)) {
                continue
            }
            if seenIds.contains(storedId) || (!storedClientId.isEmpty && seenIds.contains(storedClientId)) {
                continue
            }
            if memoryKeys.contains(storedId) || (!storedClientId.isEmpty && memoryKeys.contains(storedClientId)) {
                seenIds.insert(storedId)
                if !storedClientId.isEmpty { seenIds.insert(storedClientId) }
                continue
            }
            let decoded = row.message
            if case .recalled = decoded.kind { continue }
            if case .placeholder = decoded.kind, decoded.isE2EE { continue }
            if !Self.messageMatchesSearchQuery(decoded, query: trimmed) { continue }

            seenIds.insert(storedId)
            seenIds.insert(decoded.id)
            if !storedClientId.isEmpty { seenIds.insert(storedClientId) }
            if !decoded.clientId.isEmpty { seenIds.insert(decoded.clientId) }
            results.append(decoded)
        }

        results.sort { a, b in
            if a.date != b.date { return a.date > b.date }
            return a.id > b.id
        }
        return Array(results.prefix(clampedLimit))
    }

    /// Ensures an older search match is loaded into `messages[convId]` so `MessageList` can scroll to it.
    @discardableResult
    func ensureMessageLoaded(_ message: ChatMessage, in convId: String) async -> Bool {
        // U6: bridge pendingDeletedMessages into core until U6 owns pending deletes.
        let pendingDeletedKeys = pendingDeletedSearchKeys(in: convId)
        if let core = coreLifecycle.core {
            guard let res = try? await core.ensureMessageLoaded(
                convId: convId,
                message: ChatMessageRecord(message: message),
                pendingDeletedKeys: pendingDeletedKeys
            ) else {
                return false
            }
            await waitForMirrorVersion(res.settledVersion)
            return res.loaded
        }

        // Offline fallback for unit tests that construct ZaloEngine without calling start().
        guard !convId.isEmpty else { return false }
        if messages[convId]?.contains(where: { $0.id == message.id }) == true {
            return true
        }

        let targetTsMs = Int64((message.date.timeIntervalSince1970 * 1000).rounded())
        let oldestTsMs = messages[convId]?.first.map { Int64(($0.date.timeIntervalSince1970 * 1000).rounded()) }
        let pendingDeletedIds = Set(pendingDeletedKeys)

        if let store = sqliteStore,
           let window = try? await store.decodedMessagesAround(
               convId: convId,
               targetTsMs: targetTsMs,
               beforeOldestTsMs: oldestTsMs
           ) {
            mergeMessagesIntoMemory(
                window.rows
                    .filter {
                        !pendingDeletedIds.contains($0.rowId)
                            && ($0.rowClientId.isEmpty || !pendingDeletedIds.contains($0.rowClientId))
                    }
                    .map { (message: $0.message, clientId: $0.rowClientId) },
                in: convId)
            if window.hasMoreOlder {
                hasMoreHistory[convId] = true
            }
        }

        let isPendingDeleted = pendingDeletedIds.contains(message.id)
            || (!message.clientId.isEmpty && pendingDeletedIds.contains(message.clientId))
        if !isPendingDeleted,
           messages[convId]?.contains(where: { $0.id == message.id }) != true,
           (message.conversationId == convId || message.conversationId.isEmpty) {
            mergeMessageIntoMemory(message)
        }
        return messages[convId]?.contains(where: { $0.id == message.id }) == true
    }

    /// The id of the message `message` quotes, loaded into memory so the list can scroll to it (nil when not found).
    /// Quotes carry the original's ids; quotes stored by older builds have none and match the newest earlier message
    /// with the same text (and sender, when it is "Bạn").
    func loadQuotedMessage(of message: ChatMessage, in convId: String) async -> String? {
        // U6: bridge pendingDeletedMessages into core until U6 owns pending deletes.
        let pendingDeletedKeys = pendingDeletedSearchKeys(in: convId)
        if let core = coreLifecycle.core {
            guard let res = try? await core.loadQuotedMessage(
                convId: convId,
                message: ChatMessageRecord(message: message),
                pendingDeletedKeys: pendingDeletedKeys
            ) else {
                return nil
            }
            await waitForMirrorVersion(res.settledVersion)
            return res.messageId
        }

        // Offline fallback for unit tests that construct ZaloEngine without calling start().
        guard let quote = message.quote else { return nil }
        let pendingDeletedIds = Set(pendingDeletedKeys)
        let keys = [quote.msgId, quote.cliMsgId].filter { !$0.isEmpty && $0 != "0" }
        let list = messages[convId] ?? []
        for key in keys {
            if let hit = list.first(where: { $0.id == key || $0.clientId == key }) {
                if case .recalled = hit.kind { return nil }
                if pendingDeletedIds.contains(hit.id)
                    || (!hit.clientId.isEmpty && pendingDeletedIds.contains(hit.clientId)) {
                    return nil
                }
                return hit.id
            }
        }
        if let store = sqliteStore {
            for key in keys {
                if let row = try? await store.decodedMessage(convId: convId, idOrClientId: key) {
                    if case .recalled = row.message.kind { continue }
                    if pendingDeletedIds.contains(row.rowId)
                        || (!row.rowClientId.isEmpty && pendingDeletedIds.contains(row.rowClientId)) {
                        continue
                    }
                    if await ensureMessageLoaded(row.message, in: convId) {
                        return row.message.id
                    }
                }
            }
        }
        guard keys.isEmpty else { return nil }
        let text = quote.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let mineOnly = quote.senderName == "Bạn"
        return list.last(where: { m in
            m.id != message.id && m.date <= message.date && m.kind != .recalled
                && !pendingDeletedIds.contains(m.id)
                && (m.clientId.isEmpty || !pendingDeletedIds.contains(m.clientId))
                && m.text.trimmingCharacters(in: .whitespacesAndNewlines) == text
                && (!mineOnly || m.isMine)
        })?.id
    }
}
