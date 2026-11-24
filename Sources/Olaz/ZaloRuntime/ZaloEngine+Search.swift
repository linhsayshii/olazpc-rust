import Foundation

extension ZaloEngine {
    /// Returns `true` when `message` matches `query` case-insensitively across its text/caption/card content.
    nonisolated static func messageMatchesSearchQuery(_ message: ChatMessage, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if case .recalled = message.kind { return false }
        if case .placeholder = message.kind, message.isE2EE { return false }

        let needle = trimmed.lowercased()
        if message.text.lowercased().contains(needle) { return true }

        switch message.kind {
        case .file(let name, _, _):
            return name.lowercased().contains(needle)
        case .link(let title, _, _, let description, _):
            return title.lowercased().contains(needle) || description.lowercased().contains(needle)
        case .contactCard(let card):
            return card.name.lowercased().contains(needle)
        case .location(let info):
            return info.title.lowercased().contains(needle) || info.address.lowercased().contains(needle)
        case .call(_, _, _, let title, let detail):
            return title.lowercased().contains(needle) || detail.lowercased().contains(needle)
        case .ecard(let card):
            return card.title.lowercased().contains(needle)
                || card.description.lowercased().contains(needle)
                || card.reminderTitle.lowercased().contains(needle)
        case .oaMessage(let parts):
            return parts.contains {
                $0.title.lowercased().contains(needle) || $0.description.lowercased().contains(needle)
            }
        case .poll(let poll):
            return poll.question.lowercased().contains(needle) || poll.header.lowercased().contains(needle)
        case .stickerSet(let title, _):
            return title.lowercased().contains(needle)
        case .zinstant(let title, let text, _):
            return title.lowercased().contains(needle) || text.lowercased().contains(needle)
        case .notice(_, let text):
            return text.lowercased().contains(needle)
        case .text, .photo, .sticker, .gif, .video, .voice, .placeholder, .system, .recalled, .unsupported:
            return false
        }
    }

    /// Searches in-memory messages and SQLite history for `convId`, deduplicated by message/client ID and ordered newest-first.
    func searchMessages(in convId: String, query: String, limit: Int = 50) async -> [ChatMessage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !convId.isEmpty, !trimmed.isEmpty, limit > 0 else { return [] }
        let clampedLimit = max(1, min(limit, 500))

        let pendingDeletedIds = Set(
            pendingDeletedMessages.values.joined()
                .filter { $0.conversationId == convId }
                .map(\.id)
        )
        let inMemory = messages[convId] ?? []
        var memoryById: [String: ChatMessage] = [:]
        memoryById.reserveCapacity(inMemory.count)
        for msg in inMemory {
            memoryById[msg.id] = msg
        }

        var results: [ChatMessage] = []
        var seenIds = Set<String>()

        for msg in inMemory {
            guard !pendingDeletedIds.contains(msg.id) else { continue }
            guard Self.messageMatchesSearchQuery(msg, query: trimmed) else { continue }
            if seenIds.insert(msg.id).inserted {
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
            // If the live in-memory list already holds this message (e.g., recalled in memory), trust memory state.
            if memoryById[storedId] != nil || (!storedClientId.isEmpty && memoryById[storedClientId] != nil) {
                seenIds.insert(storedId)
                if !storedClientId.isEmpty { seenIds.insert(storedClientId) }
                continue
            }
            let decoded = row.message
            if case .recalled = decoded.kind { continue }
            if case .placeholder = decoded.kind, decoded.isE2EE { continue }

            seenIds.insert(storedId)
            seenIds.insert(decoded.id)
            if !storedClientId.isEmpty { seenIds.insert(storedClientId) }
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
        guard !convId.isEmpty else { return false }
        if messages[convId]?.contains(where: { $0.id == message.id }) == true {
            return true
        }

        let targetTsMs = Int64((message.date.timeIntervalSince1970 * 1000).rounded())
        let oldestTsMs = messages[convId]?.first.map { Int64(($0.date.timeIntervalSince1970 * 1000).rounded()) }

        if let store = sqliteStore,
           let window = try? await store.decodedMessagesAround(
               convId: convId,
               targetTsMs: targetTsMs,
               beforeOldestTsMs: oldestTsMs
           ) {
            let pendingDeletedIds = Set(
                pendingDeletedMessages.values.joined()
                    .filter { $0.conversationId == convId }
                    .map(\.id)
            )
            mergeMessagesIntoMemory(
                window.rows
                    .filter { !pendingDeletedIds.contains($0.rowId) }
                    .map { (message: $0.message, clientId: $0.rowClientId) },
                in: convId)
            if window.hasMoreOlder {
                hasMoreHistory[convId] = true
            }
        }

        if messages[convId]?.contains(where: { $0.id == message.id }) != true,
           (message.conversationId == convId || message.conversationId.isEmpty) {
            mergeMessageIntoMemory(message)
        }
        return messages[convId]?.contains(where: { $0.id == message.id }) == true
    }

    /// The id of the message `message` quotes, loaded into memory so the list can scroll to it (nil when not found).
    /// Quotes carry the original's ids; quotes stored by older builds have none and match the newest earlier message
    /// with the same text (and sender, when it is "Bạn").
    func loadQuotedMessage(of message: ChatMessage, in convId: String) async -> String? {
        guard let quote = message.quote else { return nil }
        let keys = [quote.msgId, quote.cliMsgId].filter { !$0.isEmpty && $0 != "0" }
        let list = messages[convId] ?? []
        for key in keys {
            if let hit = list.first(where: { $0.id == key || $0.clientId == key }) { return hit.id }
        }
        if let store = sqliteStore {
            for key in keys {
                if let row = try? await store.decodedMessage(convId: convId, idOrClientId: key),
                   await ensureMessageLoaded(row.message, in: convId) {
                    return row.message.id
                }
            }
        }
        guard keys.isEmpty else { return nil }
        let text = quote.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let mineOnly = quote.senderName == "Bạn"
        return list.last(where: { m in
            m.id != message.id && m.date <= message.date && m.kind != .recalled
                && m.text.trimmingCharacters(in: .whitespacesAndNewlines) == text
                && (!mineOnly || m.isMine)
        })?.id
    }
}
