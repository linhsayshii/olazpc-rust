import Foundation
import Testing
@testable import Olaz

@Suite("Tin quan trọng / khẩn cấp")
struct UrgencyTests {
    @Test func swiftParserReadsUrgency() {
        func parse(_ extra: [String: Any]) -> ChatMessage? {
            var raw: [String: Any] = ["msgId": "8801", "uidFrom": "peer", "idTo": "me", "msgType": "webchat", "ts": 1, "content": "gấp"]
            raw.merge(extra) { _, new in new }
            guard case .message(let msg, let stored) = ZaloWireParser.parseWireMessage(raw, myUid: "me") else { return nil }
            #expect(ZaloWireParser.decodeStoredMessage(stored)?.urgency == msg.urgency)
            return msg
        }
        #expect(parse(["metaData": #"{"urgency":2}"#])?.urgency == 2)
        #expect(parse(["metaData": ["urgency": 1]])?.urgency == 1)
        #expect(parse(["urgency": 1])?.urgency == 1)
        #expect(parse([:])?.urgency == 0)
    }
}
