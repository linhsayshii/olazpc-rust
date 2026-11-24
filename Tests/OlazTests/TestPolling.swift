import Foundation

/// Waits until `condition` holds, polling every 10 ms, for at most `timeout` seconds; returns whether it held.
/// Use instead of fixed sleeps or short retry loops: it costs nothing when the condition is met quickly, and the large
/// budget absorbs CI runners that starve the main actor for seconds while other suites run in parallel.
@discardableResult
func pollUntil(isolation: isolated (any Actor)? = #isolation, timeout: Double = 30, _ condition: () -> Bool) async -> Bool {
    let end = Date.now.addingTimeInterval(timeout)
    while !condition() {
        if Date.now >= end { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}
