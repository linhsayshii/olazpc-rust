import Foundation
import OlazCore

// Shared media of a conversation ("Kho lưu trữ"), orchestrated by `olaz-core` (ADR-031).
// Everything ever shared comes from Olaz's local SQLite message index (or the in-memory fallback
// when no store is open), newest first.

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
    /// orchestrated by `olaz-core` over `olaz-store` (or in-memory fallback when no store is open).
    func sharedMedia(in conversationId: String, kind: SharedMediaKind, after cursor: String?, limit: Int) async -> SharedMediaPage? {
        let simulateError = simulateSharedMediaStoreErrorOnce
        if simulateError {
            simulateSharedMediaStoreErrorOnce = false
        }
        guard let core = await ensureCoreEngine() else { return nil }
        let page = await core.sharedMediaCore(
            convId: conversationId,
            kind: kind.rawValue,
            afterCursor: cursor,
            limit: UInt32(max(0, limit)),
            simulateStoreError: simulateError
        )
        return page.map(SharedMediaPage.init(coreRecord:))
    }
}
