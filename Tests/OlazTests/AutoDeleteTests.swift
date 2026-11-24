import Foundation
import Testing
@testable import Olaz

@Suite("Tin nhắn tự xóa")
struct AutoDeleteTests {
    @Test func settingsFromConvers() {
        let map = AutoDelete.settings(from: ["convers": [
            ["destId": "200", "isGroup": 0, "ttl": 86_400_000],
            ["destId": "3993665107146848278", "isGroup": 1, "ttl": 3_600_000],
            ["destId": "300", "isGroup": 0, "ttl": 0],
        ]])
        #expect(map == ["200": 86_400_000, "g3993665107146848278": 3_600_000])
    }

    @Test func updatePayloadMatchesOfficial() {
        let p = AutoDelete.updatePayload(convId: "g123", ttl: 604_800_000)
        #expect(p["threadId"] as? String == "123")
        #expect(p["isGroup"] as? Int == 1)
        #expect(p["ttl"] as? Int64 == 604_800_000)
        #expect(AutoDelete.updatePayload(convId: "200", ttl: 0)["isGroup"] as? Int == 0)
    }

    @Test func labels() {
        #expect(AutoDelete.label(86_400_000) == "1 ngày")
        #expect(AutoDelete.remaining(2 * 86_400 + 5) == "2 ngày")
        #expect(AutoDelete.remaining(90 * 60) == "1 giờ")
        #expect(AutoDelete.remaining(30) == "30 giây")
    }

    @Test func swiftParserKeepsTtl() {
        let evt = ZaloWireParser.parseWireMessage(
            ["msgId": "8701", "uidFrom": "peer", "idTo": "me", "msgType": "webchat", "ts": 1000, "ttl": 86_400_000, "content": "hẹn"],
            myUid: "me")
        guard case .message(let msg, let stored) = evt else { Issue.record("expected message"); return }
        #expect(msg.ttlMs == 86_400_000)
        #expect(msg.expiresAt == msg.date.addingTimeInterval(86_400))
        #expect(ZaloWireParser.decodeStoredMessage(stored)?.ttlMs == 86_400_000)
    }

    @Test @MainActor func pruneRemovesExpired() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-ttl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = ZaloEngine(dataDirectory: root, useKeychain: false)
        func msg(_ id: String, age: TimeInterval, ttl: Int64) -> ChatMessage {
            var m = ChatMessage(id: id, conversationId: "200", senderId: "2", senderName: "An", senderAvatar: nil, isMine: false,
                                kind: .text, text: id, date: Date().addingTimeInterval(-age), status: .sent, quote: nil,
                                reactions: [], isE2EE: false)
            m.ttlMs = ttl
            return m
        }
        engine.messages["200"] = [msg("old", age: 7200, ttl: 3_600_000), msg("new", age: 60, ttl: 3_600_000), msg("keep", age: 9999, ttl: 0)]
        let next = engine.pruneExpiredMessages(in: "200")
        #expect(engine.messages["200"]?.map(\.id) == ["new", "keep"])
        #expect(next != nil)
    }
}
