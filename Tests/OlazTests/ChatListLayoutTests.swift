import AppKit
import SwiftUI
import Testing
@testable import Olaz

/// The AppKit-backed message list (`ChatListController`): a chat opens at its newest row, an older page prepended above
/// leaves the reader's row where it was, and a new message at the bottom keeps the list at the bottom once scrolled there.
/// Day separators stand in for rows (they need nothing from the environment); heights are measured as in the app.
@MainActor
@Suite struct ChatListLayoutTests {
    private func rows(_ range: ClosedRange<Int>) -> [ChatRow] {
        range.map { ChatRow(id: "r\($0)", kind: .day(Date(timeIntervalSince1970: Double($0) * 86_400))) }
    }

    private func makeList(height: CGFloat = 400) -> ChatListController {
        let list = ChatListController()
        list.scrollView.frame = NSRect(x: 0, y: 0, width: 500, height: height)
        return list
    }

    private func show(_ list: ChatListController, _ rows: [ChatRow], conversation: String = "c1", insets: EdgeInsets = EdgeInsets()) {
        list.update(conversationId: conversation, rows: rows, isGroup: false, newestId: nil, highlightedId: nil,
                    loadingOlder: false, insets: insets, environment: EnvironmentValues())
    }

    @Test func opensAtTheNewestRow() {
        let list = makeList()
        show(list, rows(1...200))
        #expect(list.isAtBottom)
        let last = try! #require(list.offsetOnScreen(of: "r200"))
        #expect(last > 0 && last < 400)
    }

    @Test func prependedPageKeepsTheReadersRowInPlace() throws {
        let list = makeList()
        show(list, rows(100...200))
        list.scrollForTesting(to: 600)
        let before = try #require(list.offsetOnScreen(of: "r120"))
        show(list, rows(50...200))
        let after = try #require(list.offsetOnScreen(of: "r120"))
        #expect(abs(after - before) < 0.5)
        #expect(!list.isAtBottom)
    }

    @Test func staysAtTheBottomWhenTheChatChangesBelowAnotherConversation() throws {
        let list = makeList()
        show(list, rows(1...50))
        #expect(list.isAtBottom)
        // Opening another chat starts at its own bottom, whatever the previous position was.
        list.scrollForTesting(to: 0)
        show(list, rows(300...420), conversation: "c2")
        #expect(list.isAtBottom)
        #expect(list.offsetOnScreen(of: "r1") == nil)
    }

    @Test func rowsAboveTheScreenChangingDoNotMoveWhatIsShown() throws {
        let list = makeList()
        show(list, rows(1...200))
        list.scrollForTesting(to: 3000)
        // A row on screen (rows further away may still get their real height later and move; what is shown may not).
        let shown = try #require((1...200).map { "r\($0)" }.first { (list.offsetOnScreen(of: $0) ?? -1) > 50 })
        let before = try #require(list.offsetOnScreen(of: shown))
        // A row above the screen goes away (deleted message).
        var changed = rows(1...200)
        changed.remove(at: 10)
        show(list, changed)
        let after = try #require(list.offsetOnScreen(of: shown))
        #expect(abs(after - before) < 0.5, "\(shown) before \(before) after \(after) \(list.debugGeometry)")
    }

    /// New messages arriving while the reader is up in the history do not move the rows being read.
    @Test func newMessagesBelowDoNotMoveTheReader() throws {
        let list = makeList()
        show(list, rows(1...200))
        list.scrollForTesting(to: 3000)
        let shown = try #require((1...200).map { "r\($0)" }.first { (list.offsetOnScreen(of: $0) ?? -1) > 50 })
        let before = try #require(list.offsetOnScreen(of: shown))
        show(list, rows(1...205))
        let after = try #require(list.offsetOnScreen(of: shown))
        #expect(abs(after - before) < 0.5)
        #expect(list.offsetOnScreen(of: "r205") != nil)
        #expect(!list.isAtBottom)
    }

    /// The composer and pinned bar take their room after the chat opened: the newest row ends up just above the composer.
    @Test func barsArrivingAfterOpeningKeepTheNewestRowAboveTheComposer() throws {
        let list = makeList(height: 400)
        let all = rows(1...100)
        show(list, all)
        show(list, all, insets: EdgeInsets(top: 32, leading: 0, bottom: 57, trailing: 0))
        #expect(list.isAtBottom)
        let last = try #require(list.offsetOnScreen(of: "r100"))
        #expect(last < 400 - 57 && last > 400 - 57 - 120)
    }
}
