import Foundation

/// The photos of one conversation, oldest first, that the viewer's arrow keys step through.
/// Fed from the shared-media index (newest-first pages); the clicked photo is always in the list, even before any page arrived.
struct PhotoGallery: Equatable {
    private(set) var items: [MediaViewerItem]
    private(set) var index: Int
    /// An older page can still be read.
    private(set) var hasMoreOlder = false
    private(set) var cursor: String?

    /// How close to the oldest loaded photo the next page is asked for.
    static let prefetchDistance = 3

    init(current: MediaViewerItem) {
        items = [current]
        index = 0
    }

    var current: MediaViewerItem { items[index] }
    /// 1-based position among the loaded photos, oldest = 1.
    var position: Int { index + 1 }
    var count: Int { items.count }
    var hasOlder: Bool { index > 0 }
    var hasNewer: Bool { index < items.count - 1 }
    var shouldLoadOlder: Bool { hasMoreOlder && index < Self.prefetchDistance }

    /// Up / Left. Returns the new current item, nil at the oldest loaded photo.
    @discardableResult mutating func older() -> MediaViewerItem? {
        guard hasOlder else { return nil }
        index -= 1
        return current
    }

    /// Down / Right. Returns the new current item, nil at the newest photo.
    @discardableResult mutating func newer() -> MediaViewerItem? {
        guard hasNewer else { return nil }
        index += 1
        return current
    }

    /// The photos either side of the current one, for preloading.
    var neighbours: [MediaViewerItem] {
        [index - 1, index + 1].filter { items.indices.contains($0) }.map { items[$0] }
    }

    /// Merges a page of messages (any order, videos and duplicates allowed). Keeps the current photo selected.
    mutating func merge(page: SharedMediaPage, selfName: String = "Bạn") {
        let currentKey = Self.key(current)
        var byKey: [String: MediaViewerItem] = [:]
        for item in items { byKey[Self.key(item)] = item }
        for message in page.items {
            guard let item = MediaViewerItem(photoMessage: message, selfName: selfName) else { continue }
            // The clicked photo already carries the exact display data; keep it.
            if byKey[Self.key(item)] == nil { byKey[Self.key(item)] = item }
        }
        items = byKey.values.sorted { ($0.date, $0.messageId) < ($1.date, $1.messageId) }
        index = items.firstIndex { Self.key($0) == currentKey } ?? 0
        // Pages are read in order, each after the previous cursor: the latest one says where the next starts.
        cursor = page.cursor
        hasMoreOlder = page.more && page.cursor != nil
    }

    private static func key(_ item: MediaViewerItem) -> String { item.messageId }
}

extension MediaViewerItem {
    /// A viewer item for a photo message (nil for any other kind, or a photo without a link).
    init?(photoMessage message: ChatMessage, selfName: String = "Bạn") {
        guard case .photo(let url, let width, let height) = message.kind, url != nil else { return nil }
        self.init(media: .photo(url: url, width: width, height: height,
                                encrypted: message.isE2EE || url?.absoluteString.contains("e2esession") == true),
                  conversationId: message.conversationId, messageId: message.id,
                  senderName: message.isMine ? selfName : message.senderName, date: message.date)
    }
}
