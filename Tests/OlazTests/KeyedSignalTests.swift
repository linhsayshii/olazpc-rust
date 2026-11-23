import Observation
import Testing
@testable import Olaz

/// Views read the engine's per-conversation dictionaries through `messages(in:)` / `typingName(in:)` /
/// `hasMoreHistory(in:)`: a change in another conversation must not invalidate them.
private final class Flag: @unchecked Sendable {
    private(set) var value = false
    func set() { value = true }
}

@MainActor
@Suite struct KeyedSignalTests {
    /// Runs `read` under observation and reports whether `write` invalidated it.
    private func invalidates(_ read: @escaping () -> Void, by write: () -> Void) -> Bool {
        let fired = Flag()
        withObservationTracking(read) { fired.set() }
        write()
        return fired.value
    }

    @Test func typingInOtherChatDoesNotInvalidate() {
        let engine = ZaloEngine()
        #expect(!invalidates({ _ = engine.typingName(in: "a") }, by: { engine.typing["b"] = "Lan" }))
        #expect(invalidates({ _ = engine.typingName(in: "a") }, by: { engine.typing["a"] = "Lan" }))
        #expect(engine.typingName(in: "a") == "Lan")
    }

    @Test func sameValueWriteDoesNotInvalidate() {
        let engine = ZaloEngine()
        engine.typing["a"] = "Lan"
        #expect(!invalidates({ _ = engine.typingName(in: "a") }, by: { engine.typing["a"] = "Lan" }))
        #expect(invalidates({ _ = engine.typingName(in: "a") }, by: { engine.typing["a"] = nil }))
    }

    @Test func messagesAndHistoryAreObservedPerConversation() {
        let engine = ZaloEngine()
        #expect(!invalidates({ _ = engine.messages(in: "a") }, by: { engine.messages["b"] = [] }))
        #expect(invalidates({ _ = engine.messages(in: "a") }, by: { engine.messages["a"] = [] }))
        #expect(!invalidates({ _ = engine.hasMoreHistory(in: "a") }, by: { engine.hasMoreHistory["b"] = true }))
        #expect(invalidates({ _ = engine.hasMoreHistory(in: "a") }, by: { engine.hasMoreHistory["a"] = true }))
    }
}
