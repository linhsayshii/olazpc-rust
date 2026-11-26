import Foundation
import SQLite3
@testable import Olaz

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

/// Lazily creates one pre-migrated SQLite store (full schema + `ZaloWebKitMigrator.donePrefKey = "1"`,
/// checkpointed into a single `.sqlite3` file) per suite and clones it per scenario.
actor RecorderSQLiteTemplate {
    private let dirURL: URL
    private let templateURL: URL
    private var initialized = false

    init(name: String) {
        self.dirURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-sqlite-template-\(name)-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
        self.templateURL = dirURL.appendingPathComponent("template.sqlite3")
    }

    private func buildTemplate() async throws {
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let store = try ZaloSQLiteStore(path: templateURL.path)
        try await store.setPreferenceString(key: ZaloWebKitMigrator.donePrefKey, value: "1")
        await store.close()
    }

    private func ensureTemplate() async throws {
        if initialized { return }
        try await buildTemplate()
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(templateURL.path, &handle, SQLITE_OPEN_READWRITE, nil)
        if rc == SQLITE_OK, let handle {
            sqlite3_wal_checkpoint_v2(handle, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
            sqlite3_close(handle)
        } else if let handle {
            sqlite3_close(handle)
        }
        initialized = true
    }

    func clone(to destinationURL: URL) async throws {
        try await ensureTemplate()
        let fm = FileManager.default
        try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: templateURL, to: destinationURL)
    }
}
