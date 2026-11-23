import AppKit
import SwiftUI
import Testing
@testable import Olaz

/// The AppKit conversation table: row diffing (a chat moving to the top), selection both ways, non-selectable lines.
@MainActor
@Suite struct ConversationTableTests {
    private func summary(_ id: String, unread: Int = 0, text: String = "x") -> ZaloEngine.ConversationSummary {
        .init(id: id, isGroup: id.hasPrefix("g"), name: "Chat \(id)", avatar: nil, pinned: false, members: 0, unread: unread,
              preview: .init(text: text, date: Date(timeIntervalSince1970: 1_000), fromMe: false))
    }

    private func row(_ id: String, unread: Int = 0, text: String = "x") -> ConversationTableEntry {
        .conversation(ConversationRowModel(conversation: summary(id, unread: unread, text: text), label: nil, showsPin: false,
                                           unreadMark: false, isStranger: false, isSelf: false))
    }

    private func controller(_ entries: [ConversationTableEntry], selection: String? = nil) -> ConversationTableController {
        let c = ConversationTableController()
        c.scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
        c.rowContent = { entry in AnyView(Text(entry.id).frame(height: 40)) }
        c.update(entries: entries, selection: selection, environment: EnvironmentValues())
        c.tableView.layoutSubtreeIfNeeded()
        return c
    }

    @Test func messageMovesChatToTopWithoutReloadingTheRest() {
        let ids = (0..<50).map { "\($0)" }
        let c = controller(ids.map { row($0) })
        #expect(c.debugRowCount == 50)
        var next = ids.map { row($0) }
        let moved = next.remove(at: 30)
        next.insert(row("30", unread: 1, text: "mới"), at: 0)
        _ = moved
        c.update(entries: next, selection: nil, environment: EnvironmentValues())
        #expect(c.debugRowCount == 50)
        #expect(c.entries.first?.id == "30")
        #expect(c.entries.map(\.id) == next.map(\.id))
    }

    @Test func selectionFollowsTheChatAcrossMoves() {
        let ids = (0..<10).map { "\($0)" }
        let c = controller(ids.map { row($0) }, selection: "5")
        #expect(c.tableView.selectedRow == 5)
        var next = ids.map { row($0) }
        next.insert(next.remove(at: 8), at: 0)
        c.update(entries: next, selection: "5", environment: EnvironmentValues())
        #expect(c.tableView.selectedRow == 6)
        c.update(entries: next, selection: nil, environment: EnvironmentValues())
        #expect(c.tableView.selectedRow == -1)
    }

    @Test func headerLinesCannotBeSelected() {
        let c = controller([.banner, .section("Cuộc trò chuyện"), row("1"), .strangerBox])
        #expect(c.tableView.delegate?.tableView?(c.tableView, shouldSelectRow: 0) == false)
        #expect(c.tableView.delegate?.tableView?(c.tableView, shouldSelectRow: 1) == false)
        #expect(c.tableView.delegate?.tableView?(c.tableView, shouldSelectRow: 2) == true)
        #expect(c.tableView.delegate?.tableView?(c.tableView, shouldSelectRow: 3) == false)
    }

    @Test func removalsAndInsertionsKeepRowsInSync() {
        let c = controller(["a", "b", "c", "d"].map { row($0) })
        c.update(entries: ["d", "x", "b"].map { row($0) }, selection: nil, environment: EnvironmentValues())
        #expect(c.debugRowCount == 3)
        #expect(c.entries.map(\.id) == ["d", "x", "b"])
    }
}
