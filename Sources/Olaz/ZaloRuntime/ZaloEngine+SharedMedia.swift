import Foundation

// Shared media of a conversation ("Kho lưu trữ"), bridged to `HostScripts/media-store-adapter.js` (`window.__zaloMediaStore`).
// Everything ever shared comes from the official media service (its local DB plus the sources the account allows), not from the
// messages loaded in the chat box.
// Swift → JS : page(convId, kind, cursor, limit) → Promise<{items:[ChatMessageJSON], cursor: string|null, more: Bool} | null>
//   Items are ordinary chat messages (photo / video / file / link kinds, same ids as the loaded copy of the message), newest first.
//   `cursor` is what the next page is asked after (nil on the first); `more` false at the end. null = service unavailable / failed.

/// What the three lists of the storage panel hold.
enum SharedMediaKind: String, CaseIterable, Identifiable, Sendable {
    case images, files, links

    var id: String { rawValue }

    /// Whether a chat message belongs in this list (the same split the official panel makes by message type).
    func accepts(_ kind: ChatMessage.Kind) -> Bool {
        switch (self, kind) {
        case (.images, .photo), (.images, .video), (.files, .file): true
        case (.links, .link(_, let url, _, _, _)): url != nil
        default: false
        }
    }
}

/// One page of a shared-media list.
struct SharedMediaPage: Equatable, Sendable {
    var items: [ChatMessage]
    /// Pass back as `after` to read the next (older) page.
    var cursor: String?
    var more: Bool

    init(items: [ChatMessage], cursor: String?, more: Bool) {
        self.items = items
        self.cursor = cursor
        self.more = more
    }

    /// Parses what `page()` resolves to; nil for anything that is not a page (the adapter answers null when the service is unavailable).
    init?(json: Any?, conversationId: String) {
        guard let root = json as? [String: Any], let rows = root["items"] as? [[String: Any]] else { return nil }
        items = rows.compactMap { ChatMessage(json: $0, fallbackConversation: conversationId) }
        cursor = (root["cursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        more = (root["more"] as? NSNumber)?.boolValue ?? false
    }
}

/// Where the pages come from: the engine, or a stand-in in tests.
@MainActor
protocol SharedMediaSource: AnyObject {
    func sharedMedia(in conversationId: String, kind: SharedMediaKind, after cursor: String?, limit: Int) async -> SharedMediaPage?
}

extension ZaloEngine: SharedMediaSource {
    /// A page of the photos / videos, files or links ever shared in `conversationId`, older than `cursor` (nil = the newest),
    /// backed by Olaz's local SQLite message index.
    func sharedMedia(in conversationId: String, kind: SharedMediaKind, after cursor: String?, limit: Int) async -> SharedMediaPage? {
        guard let store = sqliteStore else {
            // Fall back to in-memory loaded messages if store is not open.
            let mem = (messages[conversationId] ?? [])
                .filter { kind.accepts($0.kind) }
                .sorted { $0.date > $1.date }
            return SharedMediaPage(items: Array(mem.prefix(limit)), cursor: nil, more: false)
        }
        let tags: [String] = switch kind {
        case .images: ["photo", "video"]
        case .files: ["file"]
        case .links: ["link"]
        }
        guard let page = try? await store.sharedMediaRaw(convId: conversationId, kindTags: tags, afterCursor: cursor, limit: limit) else {
            return nil
        }
        let items = page.rows.compactMap { data -> ChatMessage? in
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            return ChatMessage(json: json, fallbackConversation: conversationId)
        }
        return SharedMediaPage(items: items, cursor: page.cursor, more: page.more)
    }
}
