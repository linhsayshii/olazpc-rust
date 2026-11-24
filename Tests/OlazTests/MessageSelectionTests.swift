import Foundation
import Testing
@testable import Olaz

@Suite("Chọn nhiều tin nhắn")
struct MessageSelectionTests {
    private static func message(_ id: String, mine: Bool = true, kind: ChatMessage.Kind = .text, age: TimeInterval = 60) -> ChatMessage {
        ChatMessage(
            id: id, conversationId: "100", senderId: mine ? "1" : "2", senderName: mine ? "Bạn" : "An", senderAvatar: nil,
            isMine: mine, kind: kind, text: "m\(id)", date: Date().addingTimeInterval(-age), status: .sent, quote: nil,
            reactions: [], isE2EE: false, mentions: [], cardButtons: [], suggestsStickers: false,
            menu: MessageMenu(json: ["forward": "ok", "recall": mine, "delete": "forMe"]), clientId: "c\(id)")
    }

    @MainActor private static func engine() throws -> (ZaloEngine, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-select-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let engine = ZaloEngine(dataDirectory: root, useKeychain: false)
        engine.messages["100"] = [
            message("1"), message("2", mine: false), message("3", kind: .system), message("4"), message("5"),
        ]
        return (engine, root)
    }

    @Test @MainActor func toggleAndShiftRange() throws {
        let (engine, root) = try Self.engine()
        defer { try? FileManager.default.removeItem(at: root) }
        engine.beginSelection(engine.messages["100"]![0])
        #expect(engine.messageSelection?.ids == ["1"])
        // SHIFT click: every selectable message between the anchor and the row (the info line is skipped).
        engine.toggleSelection("5", range: true)
        #expect(Set(engine.messageSelection?.ids ?? []) == ["1", "2", "4", "5"])
        engine.toggleSelection("2")
        #expect(engine.selectedMessages().map(\.id) == ["1", "4", "5"])
        engine.toggleSelection("3")
        #expect(engine.selectedMessages().map(\.id) == ["1", "4", "5"])
    }

    @Test @MainActor func recallOnlyWhenAllMine() throws {
        let (engine, root) = try Self.engine()
        defer { try? FileManager.default.removeItem(at: root) }
        engine.beginSelection(engine.messages["100"]![0])
        engine.toggleSelection("4")
        #expect(engine.selectionCanRecall(engine.selectedMessages()))
        engine.toggleSelection("2")
        #expect(!engine.selectionCanRecall(engine.selectedMessages()))
        #expect(engine.selectionCanForward(engine.selectedMessages()))
    }

    @Test @MainActor func deleteManyHidesAllWithOneUndo() throws {
        let (engine, root) = try Self.engine()
        defer { try? FileManager.default.removeItem(at: root) }
        engine.beginSelection(engine.messages["100"]![0])
        engine.toggleSelection("4")
        engine.openConversationId = "100"
        engine.deleteSelection()
        let confirm = try #require(engine.messageConfirm)
        #expect(confirm.message == "Xóa các tin nhắn đã chọn chỉ ở phía bạn?")
        engine.answerMessageConfirm(confirm, ok: true)
        #expect(engine.messageSelection == nil)
        #expect(engine.messages["100"]?.map(\.id) == ["2", "3", "5"])
        #expect(engine.deleteUndo?.count == 2)
        engine.undoDelete()
        #expect(Set(engine.messages["100"]?.map(\.id) ?? []) == ["1", "2", "3", "4", "5"])
    }

    @Test @MainActor func forwardCarriesAllSelected() throws {
        let (engine, root) = try Self.engine()
        defer { try? FileManager.default.removeItem(at: root) }
        engine.beginSelection(engine.messages["100"]![3])
        engine.toggleSelection("1")
        engine.forwardSelection()
        #expect(engine.forwardRequest?.all.map(\.id) == ["1", "4"])
    }
}
