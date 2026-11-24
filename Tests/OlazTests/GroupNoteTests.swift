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
