import Observation

/// Per-key observation for a dictionary held by the `@Observable` engine.
///
/// Observation tracks a dictionary property as one value: a view that reads `engine.messages[id]` is invalidated whenever
/// *any* conversation's messages change. Views that read through `track(_:)` (and the untracked backing storage) are
/// invalidated only when their own key changes. The engine calls `changed(from:to:)` from the property's `didSet`.
@MainActor
final class KeyedSignal {
    @MainActor @Observable
    final class Slot {
        var tick = 0
    }

    /// One slot per key some view has read; keys nobody watches cost nothing on writes.
    private var slots: [String: Slot] = [:]

    /// Registers the current observation scope (a view body) on `key` alone.
    func track(_ key: String) {
        let slot: Slot
        if let existing = slots[key] {
            slot = existing
        } else {
            slot = Slot()
            slots[key] = slot
        }
        _ = slot.tick
    }

    /// Bumps the slot of every watched key whose value differs between `old` and `new`.
    func changed<Value: Equatable>(from old: [String: Value], to new: [String: Value]) {
        for (key, slot) in slots where old[key] != new[key] {
            slot.tick &+= 1
        }
    }
}
