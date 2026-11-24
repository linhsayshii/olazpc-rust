import Foundation

/// "Tin nhắn tự xóa": the per-conversation lifetime of new messages, and the removal of messages past theirs.
extension ZaloEngine {
    /// The conversation's lifetime for new messages (ms, 0 = off).
    func autoDeleteTTL(_ convId: String) -> Int64 {
        autoDelete?[convId] ?? 0
    }

    func loadAutoDelete() async {
        guard let map = try? await sessionClient.fetchAutoDeleteAPI() else {
            if autoDelete == nil { autoDelete = [:] }
            return
        }
        autoDelete = map
    }

    /// "Cài đặt tin nhắn tự xóa": sets it on the server, then the official info line ("Bạn đã đặt thời gian tự xóa…").
    func setAutoDelete(_ convId: String, ttl: Int64) async {
        guard !convId.isEmpty, autoDeleteTTL(convId) != ttl else { return }
        do {
            try await sessionClient.updateAutoDeleteAPI(convId: convId, ttl: ttl)
        } catch {
            EngineLog.shared.write("autodelete: update failed \(type(of: error))")
            CardActionCenter.shared.show("Không thể cài đặt tin nhắn tự xóa", in: convId)
            return
        }
        var map = autoDelete ?? [:]
        map[convId] = ttl > 0 ? ttl : nil
        autoDelete = map
        let text = ttl > 0
            ? "Bạn đã đặt thời gian tự xóa cho tin nhắn là \(AutoDelete.label(ttl))."
            : "Bạn đã tắt tin nhắn tự xóa."
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        let msg = ChatMessage(
            id: "ttl-\(convId)-\(ms)", conversationId: convId, senderId: "", senderName: "", senderAvatar: nil, isMine: false,
            kind: .system, text: text, date: Date(timeIntervalSince1970: Double(ms) / 1000), status: .sent,
            quote: nil, reactions: [], isE2EE: false
        )
        mergeMessageIntoMemory(msg)
        if let stored = ZaloWireParser.encodeChatMessage(msg, clientId: msg.id) {
            try? await sqliteStore?.saveMessages([stored])
        }
        updateConversationOnMessage(msg, incrementUnread: false)
    }

    /// Removes the conversation's messages whose lifetime is over (memory and store); returns the next expiry, if any.
    @discardableResult
    func pruneExpiredMessages(in convId: String, now: Date = Date()) -> Date? {
        guard let list = messages[convId], list.contains(where: { $0.ttlMs > 0 }) else { return nil }
        let expired = list.filter { ($0.expiresAt ?? .distantFuture) <= now }
        if !expired.isEmpty {
            let ids = Set(expired.map(\.id))
            messages[convId] = list.filter { !ids.contains($0.id) }
            let store = sqliteStore
            Task {
                for m in expired { try? await store?.deleteMessage(convId: convId, id: m.id) }
            }
        }
        return (messages[convId] ?? []).compactMap(\.expiresAt).min()
    }
}
