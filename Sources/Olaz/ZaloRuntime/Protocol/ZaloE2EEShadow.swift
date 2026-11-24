import Foundation
import OlazCore

/// How the Rust Signal engine (`olaz-signal`, ADR-015) takes part in 1-1 E2EE.
///
/// * `.off`: JavaScriptCore only (the Rust store failed to load, or explicit test mode).
/// * `.shadow` (default): JS stays authoritative and the only writer of
///   `zaloE2EEPCStoreV1`; Rust decrypts a throw-away copy of every incoming cipher and only
///   compares plaintext.
/// * `.authoritative`: `OLAZ_E2EE_RUST=1` or the `olaz.e2eeRust` UserDefaults bool. Rust decrypts,
///   encrypts and persists the same key; JS is not loaded. Flip back off and JS restores from the
///   Rust-written JSON.
enum E2EERustMode: Sendable, Equatable {
    case off, shadow, authoritative

    static let defaultsKey = "olaz.e2eeRust"

    /// Read once per manager.
    static func resolve(
        env: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> E2EERustMode {
        if let flag = env["OLAZ_E2EE_RUST"] { return flag == "1" ? .authoritative : .shadow }
        if defaults.object(forKey: defaultsKey) as? Bool == true { return .authoritative }
        return .shadow
    }
}

/// What the JS decrypt produced, as the shadow comparator sees it.
enum E2EEShadowJS: Sendable {
    case plain(Data)
    case failed
}

enum E2EEShadowVerdict: Equatable, Sendable {
    case match
    /// JS and Rust both refused (a wrong device candidate, a replay): agreement, not logged.
    case bothFailed
    case mismatch(reason: String)
}

/// Counters readable from the engine (`ZaloEngine.e2eeShadowCounters`). Thread safe.
final class E2EEShadowStats: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        var matches = 0
        /// JS and Rust disagree (different plaintext, or one refused).
        var mismatches = 0
        /// Shadow plumbing failures (not a Rust verdict): task failure, snapshot export failure.
        var errors = 0
        /// Not run: too many shadow jobs already in flight.
        var skipped = 0
        var bothFailed = 0
    }

    /// Cap on concurrent shadow jobs; more are skipped so a big history batch cannot pile up work.
    static let maxInFlight = 8

    private let lock = NSLock()
    private var counts = Snapshot()
    private var inFlight = 0

    var snapshot: Snapshot { lock.withLock { counts } }

    var summaryLine: String {
        let s = snapshot
        return "e2ee-shadow: totals matches=\(s.matches) mismatches=\(s.mismatches) errors=\(s.errors) "
            + "skipped=\(s.skipped) bothFailed=\(s.bothFailed)"
    }

    /// Reserves a slot, or counts a skip and returns false.
    func tryBegin() -> Bool {
        lock.withLock {
            if inFlight >= Self.maxInFlight {
                counts.skipped += 1
                return false
            }
            inFlight += 1
            return true
        }
    }

    func finish(_ verdict: E2EEShadowVerdict?) {
        lock.withLock {
            inFlight -= 1
            switch verdict {
            case .match?: counts.matches += 1
            case .bothFailed?: counts.bothFailed += 1
            case .mismatch?: counts.mismatches += 1
            case nil: counts.errors += 1
            }
        }
    }

    /// Releases a slot for a job that never started because the snapshot was unavailable.
    func abandon() { finish(nil) }

    var isIdle: Bool { lock.withLock { inFlight == 0 } }

    /// Test / shutdown helper: waits until every started shadow job has recorded its verdict.
    func waitUntilIdle(timeout: Duration = .seconds(20)) async {
        let deadline = ContinuousClock.now + timeout
        while !isIdle, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

extension ZaloEngine {
    /// Shadow-mode decrypt counters (matches / mismatches / errors), for a debug view or log line.
    var e2eeShadowCounters: E2EEShadowStats.Snapshot { e2eeManager.shadowStats.snapshot }

    /// Writes the counters to the engine log (`e2ee-shadow: totals ...`).
    func logE2EEShadowTotals() {
        EngineLog.shared.write(e2eeManager.shadowStats.summaryLine)
    }
}

enum E2EEShadow {
    /// `prekey` / `whisper` from the first framing byte of the base64 cipher (3 = PreKeyWhisperMessage).
    static func cipherType(_ cipherB64: String) -> String {
        guard cipherB64.count >= 4,
              let head = Data(base64Encoded: String(cipherB64.prefix(4))), let first = head.first else {
            return "unknown"
        }
        return first == 3 ? "prekey" : "whisper"
    }

    /// Short, value-free class of a Rust failure: the `CoreError` case name.
    static func errorKind(_ error: Error) -> String {
        guard let core = error as? CoreError else { return "other" }
        switch core {
        case .Parse: return "parse"
        case .Crypto(let message): return "crypto_\(message)"
        case .Internal: return "internal"
        default: return "other"
        }
    }

    /// Compares the JS outcome with Rust's. `format` is the JS decrypt format (`string` / `uint32`);
    /// JS returned decoded text or a number, so Rust's raw bytes are normalised the same way.
    static func classify(js: E2EEShadowJS, rust: Result<Data, Error>, format: String) -> E2EEShadowVerdict {
        switch (js, rust) {
        case (.plain(let expected), .success(let bytes)):
            return normalise(bytes, format: format) == expected ? .match : .mismatch(reason: "plaintext_differs")
        case (.plain, .failure(let error)):
            return .mismatch(reason: "rust_error_\(errorKind(error))")
        case (.failed, .success):
            return .mismatch(reason: "js_failed_rust_ok")
        case (.failed, .failure):
            return .bothFailed
        }
    }

    /// JS `utf8d.decode` is lossy; `uint32` reads the first 4 bytes little endian.
    static func normalise(_ bytes: Data, format: String) -> Data {
        if format == "uint32" { return Data(bytes.prefix(4)) }
        return Data(String(decoding: bytes, as: UTF8.self).utf8)
    }

    static func jsPlain(text: String) -> E2EEShadowJS { .plain(Data(text.utf8)) }

    static func jsPlain(number: UInt32) -> E2EEShadowJS {
        .plain(Data([UInt8(number & 0xff), UInt8((number >> 8) & 0xff), UInt8((number >> 16) & 0xff), UInt8((number >> 24) & 0xff)]))
    }

    /// The log line for a verdict (`nil` for outcomes that are only counted). Shapes only.
    static func logLine(_ verdict: E2EEShadowVerdict, type: String) -> String? {
        switch verdict {
        case .match: "e2ee-shadow: match type=\(type)"
        case .mismatch(let reason): "e2ee-shadow: mismatch type=\(type) reason=\(reason)"
        case .bothFailed: nil
        }
    }
}
