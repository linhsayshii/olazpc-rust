import Foundation
import Testing
@testable import Olaz

@Suite("Báo xấu và quyền riêng tư")
struct ReportPrivacyTests {
    @Test func reportPayload() {
        let person = ReportReason.payload(convId: "200", reason: .fraud, content: " ", imei: "i")
        #expect(person["uidTo"] as? String == "200")
        #expect(person["type"] as? Int == 2)
        #expect(person["reason"] as? Int == 3)
        #expect(person["content"] as? String == "")
        let group = ReportReason.payload(convId: "g777", reason: .other, content: "spam", imei: "i")
        #expect(group["uidTo"] as? String == "777")
        #expect(group["type"] as? Int == 14)
        #expect(group["reason"] as? Int == 0)
    }

    @Test func privacyValues() {
        #expect(PrivacyKey.value(0) == false)
        #expect(PrivacyKey.value(1) == true)
        #expect(PrivacyKey.value(false) == false)
        #expect(PrivacyKey.value(nil) == nil)
    }
}
