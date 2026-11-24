import Foundation

/// Cross-suite async mutex shared by every `*RecorderTests` harness (`SessionRecorderTests`,
/// `TransportRecorderTests`, and future domain recorders).
///
/// `@Suite(.serialized)` only serializes tests within a single suite; Swift Testing runs distinct
/// suites concurrently in the same process. Acquiring `RecorderSuiteLock.shared.withLock` around
/// each recorded scenario guarantees that only one recorder scenario (and its `FakeZaloServer`,
/// `ZaloEngine`, and process singletons such as `EngineLog.shared`) is active at a time.
actor RecorderSuiteLock {
    static let shared = RecorderSuiteLock()

    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            isLocked = false
        }
    }

    /// Runs `operation` while holding the cross-suite recorder lock, preserving the caller's
    /// actor isolation (`@MainActor` stays on MainActor) and releasing before returning or throwing.
    func withLock<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ operation: () async throws -> T
    ) async rethrows -> T {
        await acquire()
        do {
            let result = try await operation()
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }
}

/// Per-scenario isolated `UserDefaults` suite and in-memory `HTTPCookieStorage` so recorder
/// tests never read or mutate `UserDefaults.standard` or `HTTPCookieStorage.shared`.
struct RecorderStorageIsolation: @unchecked Sendable {
    let userDefaultsSuiteName: String
    let cookieStorage: HTTPCookieStorage

    init(prefix: String = "olaz.recorder") {
        self.userDefaultsSuiteName = "\(prefix).\(UUID().uuidString)"
        let ephemeral = URLSessionConfiguration.ephemeral
        self.cookieStorage = ephemeral.httpCookieStorage ?? HTTPCookieStorage()
    }

    var userDefaults: UserDefaults {
        UserDefaults(suiteName: userDefaultsSuiteName)!
    }

    func cleanup() {
        for cookie in cookieStorage.cookies ?? [] {
            cookieStorage.deleteCookie(cookie)
        }
        UserDefaults(suiteName: userDefaultsSuiteName)?.removePersistentDomain(forName: userDefaultsSuiteName)
    }
}
