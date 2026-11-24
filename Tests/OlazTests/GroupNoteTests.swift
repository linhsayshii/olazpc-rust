import Foundation
import Testing
@testable import Olaz

@Suite("Ghi chú nhóm")
struct GroupNoteTests {
    @Test func notePayload() throws {
        let p = GroupNote.payload(groupId: "g777", text: "Họp 9h", pin: true, imei: "i")
        #expect(p["grid"] as? String == "777")
        #expect(p["type"] as? Int == 0)
        #expect(p["pinAct"] as? Int == 1)
        let params = try #require((p["params"] as? String)?.data(using: .utf8))
        #expect((try JSONSerialization.jsonObject(with: params) as? [String: Any])?["title"] as? String == "Họp 9h")
    }
}

@Suite("Bỏ ghim ghi chú")
struct GroupNoteUnpinTests {
    /// Official `unpinBoardItem` sends `topic: {topicId, topicType}`; a note row keeps its type 0.
    @Test func unpinTopicKeepsNoteType() {
        let row: [String: Any] = ["id": "123", "type": 0, "params": "{\"title\":\"Họp 9h\"}", "creatorId": "9"]
        let topic = ZaloWireParser.friendBoardUnpinTopics(ref: "123", rawTopic: row)[0]
        #expect(Set(topic.keys) == ["topicId", "topicType"])
        #expect(topic["topicId"] as? String == "123")
        #expect(topic["topicType"] as? Int == 0)
    }
}
