import Foundation
import Testing
@testable import Olaz

/// Typing pings, shaped like the official client's `_processRawMessages` input (cmd 602 `data.actions`, where
/// `data` is a JSON object body without its braces).
@MainActor
@Suite struct TypingIndicatorTests {
    private func action(_ act: String, _ body: String) -> [String: Any] {
        ["data": ["actions": [["act_type": "typing", "act": act, "data": body]]]]
    }

    @Test func oneOneTypingOnPhoneAndPC() async {
        let engine = ZaloEngine()
        await engine.processControlEnvelope(action("typing", #""uid":"200","ts":"1700000000000","isPC":0"#), cmd: 602)
        #expect(engine.typingStatus(in: "200") == TypingStatus(name: "Ai đó", onPC: false))
        #expect(engine.typingStatus(in: "200")?.label(isGroup: false) == "Đang soạn tin")

        await engine.processControlEnvelope(action("typing", #""uid":"200","ts":"1700000000001","isPC":1"#), cmd: 602)
        #expect(engine.typingStatus(in: "200")?.label(isGroup: false) == "Đang soạn tin trên máy tính")
    }

    @Test func groupTypingUsesGroupConversationAndName() async {
        let engine = ZaloEngine()
        await engine.processControlEnvelope(
            action("gtyping", #""uid":"200","gid":"555","ts":"1700000000000","isPC":1"#), cmd: 602)
        let status = engine.typingStatus(in: "g555")
        #expect(status?.label(isGroup: true) == "Ai đó đang soạn tin trên máy tính")
        #expect(engine.typingStatus(in: "200") == nil)
    }

    @Test func outgoingThrottleMatchesOfficialTenSeconds() {
        let throttle = OutgoingTypingThrottle()
        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(throttle.shouldSend(in: "200", now: t0))
        #expect(!throttle.shouldSend(in: "200", now: t0.addingTimeInterval(9.9)))
        #expect(throttle.shouldSend(in: "200", now: t0.addingTimeInterval(10)))
    }

    @Test func oneOneTypingTargetsOfficialUserDestType() {
        #expect(ZaloSessionClient.typingDestUser == 3)
    }
}
