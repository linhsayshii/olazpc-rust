import Foundation
import Testing
@testable import Olaz

@Suite("Pinned messages")
struct PinTests {
    /// `/api/board/pin/list` data as `fetchBoardPins` boxes it: topics newest first, `params` a JSON string, `pinLimit` from the server.
    private static var groupBoard: [String: Any] { [
        "boardVersion": 7,
        "pinLimit": 3,
        "items": [
            [
                "id": "8812300001", "type": 2, "creatorId": "u1001",
                "params": #"{"senderUid":"1001","msgType":1,"client_msg_id":"1700000000123","global_msg_id":"7401234567890123456","title":"Họp lúc 9h nhé"}"#
            ],
            [
                "id": "8812300002", "type": 3,
                "params": ["title": "Đi ăn gì?"]
            ],
            [
                "id": "8812300003", "type": 2,
                "params": #"{"senderUid":"2002","senderName":"Lan","global_msg_id":"7401234567890000001","client_msg_id":"1699999999000","title":"[Hình ảnh]","thumb":"https://f20-zpc.zdn.vn/jpg/abc.jpg"}"#
            ]
        ]
    ] }

    @Test func boardListParsing() {
        let parsed = ZaloWireParser.parseBoardTopics(Self.groupBoard, convId: "g555") { uid in uid == "1001" ? "Minh" : nil }
        let list = parsed.list
        #expect(list.ready && list.canPin)
        #expect(list.limit == 3)
        #expect(parsed.version == 7)
        #expect(list.items.map(\.ref) == ["8812300001", "8812300002", "8812300003"])
        let first = list.items[0]
        #expect(first.kind == .message && first.title == "Họp lúc 9h nhé" && first.sender == "Minh")
        // 64-bit ids survive (no Double rounding).
        #expect(first.msgId == "7401234567890123456" && first.cliMsgId == "1700000000123")
        #expect(list.items[1].kind == .poll && list.items[1].title == "Đi ăn gì?")
        #expect(list.items[2].sender == "Lan" && list.items[2].thumbnail?.host == "f20-zpc.zdn.vn")
        #expect(parsed.raw["8812300002"] != nil)
    }

    @Test func missingLimitFallsBackToDefault() {
        let parsed = ZaloWireParser.parseBoardTopics(["items": [], "boardVersion": 0, "pinLimit": 0], convId: "12345")
        #expect(parsed.list.limit == ZaloWireParser.defaultPinLimit)
        #expect(parsed.list.items.isEmpty)
    }

    @Test func duplicateAndEmptyIdsAreDropped() {
        let box: [String: Any] = ["items": [["id": "", "type": 2], ["id": "1", "type": 2], ["id": "1", "type": 2]]]
        #expect(ZaloWireParser.parseBoardTopics(box, convId: "g1").list.items.map(\.ref) == ["1"])
    }

    @Test func limitDecision() {
        #expect(PinLimitDecision.decide(count: 0, limit: 3) == .allowed)
        #expect(PinLimitDecision.decide(count: 2, limit: 3) == .allowed)
        #expect(PinLimitDecision.decide(count: 3, limit: 3) == .replaceOldest)
        #expect(PinLimitDecision.decide(count: 5, limit: 3) == .chooseMany(need: 3))
        #expect(PinLimitDecision.decide(count: 9, limit: 0) == .allowed)
    }

    /// cmd 601 group control: {act_type:"group", act:"new_pin_topic", data:{groupId, topic, boardVersion, oldBoardVersion}}.
    @Test func realtimeEventConversation() throws {
        let raw = #"{"groupId":"6543210987654321","topic":{"id":"8812300009","type":2},"boardVersion":8,"oldBoardVersion":7}"#
        let data = try #require(JSONLossless.parseObject(Data(raw.utf8)))
        for act in ["new_pin_topic", "update_pin_topic", "unpin_topic", "reorder_pin_topic"] {
            #expect(ZaloWireParser.pinTopicEventConversation(actType: "group", act: act, data: data) == ZaloWireParser.groupConvId("6543210987654321"))
        }
        #expect(ZaloWireParser.pinTopicEventConversation(actType: "group", act: "join", data: data) == nil)
        #expect(ZaloWireParser.pinTopicEventConversation(actType: "mute", act: "new_pin_topic", data: data) == nil)
        #expect(ZaloWireParser.pinTopicEventConversation(actType: "group", act: "unpin_topic", data: [:]) == nil)
    }

    @Test func pinMatchesLoadedMessageByEitherId() {
        let item = PinnedItem(ref: "1", kind: .message, title: "", sender: "", thumbnail: nil, msgId: "7401234567890123456", cliMsgId: "1700000000123")
        let poll = PinnedItem(ref: "2", kind: .poll, title: "", sender: "", thumbnail: nil, msgId: "7401234567890123456", cliMsgId: "")
        let byServer = ChatMessage.stub(id: "7401234567890123456")
        let byClient = ChatMessage.stub(id: "1700000000123")
        #expect(item.message(in: [byServer])?.id == byServer.id)
        #expect(item.message(in: [byClient])?.id == byClient.id)
        #expect(item.message(in: [ChatMessage.stub(id: "999")]) == nil)
        #expect(poll.message(in: [byServer]) == nil)
    }

    @Test func pinnedListLimitFromJSON() {
        #expect(PinnedList(json: ["ready": true, "limit": 5]).limit == 5)
        #expect(PinnedList(json: ["ready": true]).limit == ZaloWireParser.defaultPinLimit)
    }
}

private extension ChatMessage {
    static func stub(id: String) -> ChatMessage {
        ChatMessage(id: id, conversationId: "g555", senderId: "1001", senderName: "Minh", senderAvatar: nil, isMine: false, kind: .text, text: "x",
                    date: Date(timeIntervalSince1970: 1_700_000_000), status: .sent, quote: nil, reactions: [], isE2EE: false)
    }
}
