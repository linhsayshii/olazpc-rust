import Testing
import Foundation
@testable import Olaz

// Message context-menu actions: the Swift decoding (menu, outcomes, pins, copy text) and the real `message-actions-adapter.js` in
// JavaScriptCore against fake official modules (dm9D predicates, forward / recall / delete / star services, pin managers).
// Every fixture is synthetic: no real names, ids or URLs.

@Suite struct MessageActionModelTests {
    private func message(_ kind: ChatMessage.Kind, text: String = "", id: String = "m1") -> ChatMessage {
        ChatMessage(id: id, conversationId: "c1", senderId: "u1", senderName: "Test User", senderAvatar: nil, isMine: false, kind: kind, text: text,
                    date: Date(timeIntervalSince1970: 1), status: .sent, quote: nil, reactions: [], isE2EE: false)
    }

    @Test func decodesTheMenu() {
        let menu = MessageMenu(json: ["forward": "blocked", "recall": true, "delete": "forMe", "pin": true, "star": "unstar", "starred": true,
                                      "protected": true, "pinned": true])
        #expect(menu.forward == .blocked && menu.recall && menu.delete == .forMe && menu.pin && menu.star == .unstar)
        #expect(menu.starred && menu.isProtected && menu.pinned)
        let empty = MessageMenu(json: ["forward": "", "delete": "", "star": ""])
        #expect(empty == MessageMenu())
        #expect(MessageMenu(json: NSNull()) == MessageMenu())
        // Parsed from a whole message, and absent for messages that have none (shared media).
        let parsed = ChatMessage(json: ["id": "1", "kind": ["type": "text"], "menu": ["forward": "ok", "delete": "plain", "star": "star"]], fallbackConversation: "c")
        #expect(parsed?.menu.forward == .available && parsed?.menu.delete == .plain && parsed?.menu.star == .star)
        #expect(ChatMessage(json: ["id": "1", "kind": ["type": "text"]], fallbackConversation: "c")?.menu == MessageMenu())
    }

    @Test func decodesOutcomes() {
        #expect(MessageActionOutcome(json: ["status": "done"], failure: "x") == .done(text: nil))
        #expect(MessageActionOutcome(json: ["status": "done", "text": "Đã bỏ đánh dấu tin nhắn"], failure: "x") == .done(text: "Đã bỏ đánh dấu tin nhắn"))
        #expect(MessageActionOutcome(json: ["status": "denied", "text": "Bị chặn"], failure: "x") == .failed("Bị chặn"))
        #expect(MessageActionOutcome(json: ["status": "error"], failure: "Lỗi") == .failed("Lỗi"))
        #expect(MessageActionOutcome(json: nil, failure: "Lỗi") == .failed("Lỗi"))
        #expect(MessageActionOutcome(json: ["status": "pending"], failure: "x") == .pending(CardActionOutcome.defaultPending))
        let confirm = MessageActionOutcome(json: ["status": "confirm", "title": "T", "message": "M", "ok": "Xác nhận", "cancel": "Hủy", "ref": "2:9"], failure: "x")
        #expect(confirm == .confirm(title: "T", message: "M", ok: "Xác nhận", cancel: "Hủy", ref: "2:9"))
    }

    @Test func decodesPinsAndFindsTheirMessages() {
        let list = PinnedList(json: ["ready": true, "canPin": true, "items": [
            ["ref": "2:a", "kind": "message", "title": "[Hình ảnh]", "sender": "Bạn", "thumb": "https://cdn.example.test/t.jpg", "msgId": "900", "cliMsgId": "500"],
            ["ref": "3:77", "kind": "poll", "title": "Ăn gì?"],
            ["ref": "", "kind": "note"],
            ["ref": "0:n", "kind": "weird", "title": "Ghi chú"],
        ]])
        #expect(list.ready && list.canPin && list.items.map(\.ref) == ["2:a", "3:77", "0:n"])
        #expect(list.items[0].thumbnail == URL(string: "https://cdn.example.test/t.jpg") && list.items[2].kind == .note)
        #expect(list.items[0].label == "Tin nhắn" && list.items[1].label == "Bình chọn")
        // Own messages are keyed by the client id, others by the server id.
        let mine = message(.text, id: "500"), theirs = message(.text, id: "900")
        #expect(list.items[0].message(in: [mine])?.id == "500" && list.items[0].message(in: [theirs])?.id == "900")
        #expect(list.items[0].message(in: [message(.text, id: "x")]) == nil && list.items[1].message(in: [mine]) == nil)
    }

    @Test func copyTextFollowsTheKind() {
        #expect(message(.text, text: "Xin chào").copyableText == "Xin chào")
        #expect(message(.text).copyableText == nil)
        #expect(message(.link(title: "T", url: URL(string: "https://site.example.test/a"), thumbnail: nil), text: "[Link] x").copyableText == "https://site.example.test/a")
        #expect(message(.link(title: "T", url: nil, thumbnail: nil), text: "xem nè").copyableText == "xem nè")
        #expect(message(.photo(url: nil, width: 1, height: 1), text: "[Hình ảnh]").copyableText == nil)
        #expect(message(.photo(url: nil, width: 1, height: 1), text: "[Hình ảnh]").caption == nil)
        #expect(message(.photo(url: nil, width: 1, height: 1), text: "Biển").caption == "Biển")
        #expect(message(.file(name: "a.pdf", size: 1, url: nil), text: "[Tệp]").copyableText == nil)
    }
}
