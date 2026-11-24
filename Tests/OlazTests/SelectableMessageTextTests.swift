import AppKit
import SwiftUI
import Testing
@testable import Olaz

@Suite @MainActor struct SelectableMessageTextTests {
    static let samples = [
        "ok",
        "Xin chào các bạn, đây là một tin nhắn dài để thử chọn chữ. Link: https://example.com và @Minh ở đây.",
        "Dòng một\nDòng hai\n\nĐoạn mới với chữ có dấu: Ữ Ỹ Ậ ẫ ợ",
        String(repeating: "Tiếng Việt có dấu rất dễ xuống dòng ", count: 12),
    ]

    @Test func heightMatchesSwiftUIText() {
        for s in Self.samples {
            for width in [180.0, 320.0, 496.0] {
                let mine = ChatFormat.messageText(s, mentions: [], mine: false, myId: nil, size: 14, accent: .systemBlue)
                let old = NSHostingController(rootView: Text(ChatFormat.linkified(s, mine: false))
                    .font(.system(size: 14)).fixedSize(horizontal: false, vertical: true))
                let ref = old.sizeThatFits(in: CGSize(width: width, height: 100_000))
                let new = mine.size(for: width)
                #expect(abs(new.height - ref.height) <= 1, "\(s.prefix(20))… @\(width): \(new.height) vs \(ref.height)")
                #expect(new.width <= width)
            }
        }
    }

    @Test func linksAndMentions() {
        let s = "Hi @Minh xem https://example.com"
        let t = ChatFormat.messageText(s, mentions: [Mention(uid: "42", pos: 3, len: 5)], mine: true, myId: "1",
                                       size: 14, accent: .systemBlue).attributed
        let ns = s as NSString
        #expect(t.attribute(.link, at: ns.range(of: "@Minh").location, effectiveRange: nil) as? URL == URL(string: "zalomention:42"))
        #expect(t.attribute(.link, at: ns.range(of: "https").location, effectiveRange: nil) as? URL == URL(string: "https://example.com"))
        #expect(t.attribute(.link, at: 0, effectiveRange: nil) == nil)
    }

    @Test func myMentionIsNotALink() {
        let t = ChatFormat.messageText("@Me hi", mentions: [Mention(uid: "1", pos: 0, len: 3)], mine: false, myId: "1",
                                       size: 14, accent: .systemBlue).attributed
        #expect(t.attribute(.link, at: 0, effectiveRange: nil) == nil)
        #expect(t.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil)
    }
}
