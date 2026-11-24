import Foundation
import OlazCore

/// Flag and shared helpers for the Rust core cutover (rust/DECISIONS.md ADR-011). The Swift path is the opt-out fallback;
/// `OLAZ_RUST_CORE` / the `olaz.rustCore` UserDefaults bool (default on, ADR-012) routes the chat path (store, wire parser, `zpw_ws`
/// socket, chat HTTP calls) through the `OlazCore` UniFFI module. Read once at launch.
enum RustCore {
    static let defaultsKey = "olaz.rustCore"

    /// On by default since the live check of 2026-11-23 (ADR-012). Opt out with `OLAZ_RUST_CORE=0`
    /// or `defaults write app.olaz.mac olaz.rustCore -bool false`.
    static let isEnabled: Bool = {
        if let env = ProcessInfo.processInfo.environment["OLAZ_RUST_CORE"] { return env != "0" }
        return UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }()

    // MARK: Errors

    /// Maps a Rust-core error to the Swift error the engine already reacts to (`ZaloSessionError.isAuthError` re-login,
    /// `URLError` for connectivity, `ZaloTransportError` for the rest). Messages never carry tokens or bodies (ADR-008).
    /// `path` (request path, no host or query) is carried into `ZaloSessionError.url` like the Swift path does.
    /// `quietTimeout` skips the log line for a network timeout: the HTTP long-poll times out by design when the server
    /// has nothing to say, and the Swift path never logged it.
    static func mapError(_ error: Error, path: String = "", quietTimeout: Bool = false) -> Error {
        guard let core = error as? CoreError else { return error }
        // Shape only (ADR-008): error case name and numeric code, never messages.
        let shape: String?
        switch core {
        case .Session(let code, _, let isAuth):
            // Expected board notices (pin disabled / empty): the Swift path skipped the log line too.
            let expectedBoardNotice = path.contains("/api/board/")
                && (code == 112 || code == 265 || (path.contains("/oneone/list") && code == -1))
            shape = expectedBoardNotice ? nil : "session code=\(code) auth=\(isAuth)"
        case .Http(let status): shape = "http status=\(status)"
        case .Network(let kind, _): shape = quietTimeout && kind == .timeout ? nil : "network \(kind)"
        default: shape = "\(core)".split(separator: "(").first.map(String.init) ?? "other"
        }
        if let shape {
            let logged = path.isEmpty ? shape : "\(shape) path=\(path)"
            Task { @MainActor in EngineLog.shared.write("rust: error \(logged)") }
        }
        switch core {
        case .Session(let code, let message, _):
            return ZaloSessionError(code: Int(code), message: message, url: path)
        case .Network(let kind, _):
            switch kind {
            case .timeout: return URLError(.timedOut)
            case .connectionLost: return URLError(.networkConnectionLost)
            case .other: return URLError(.cannotConnectToHost)
            }
        case .Http(let status): return ZaloTransportError.httpError(Int(status), "")
        case .NotAuthenticated: return ZaloTransportError.notAuthenticated
        case .Qr(let message): return ZaloTransportError.qrFailed(message)
        case .QrTimeout: return ZaloTransportError.qrTimeout
        case .Cancelled: return CancellationError()
        case .Parse: return ZaloTransportError.invalidJSON
        case .Store(let message): return ZaloSQLiteError.stepFailed(message)
        case .Crypto(let message), .Ws(let message), .Internal(let message):
            return ZaloSQLiteError.stepFailed(message)
        }
    }

    // MARK: Row conversion

    static func row(_ m: StoredMessage) -> OlazCore.MessageRow {
        OlazCore.MessageRow(
            id: m.id, convId: m.convId, clientId: m.clientId, senderId: m.senderId, senderName: m.senderName,
            senderAvatar: m.senderAvatar, isMine: m.isMine, text: m.text, kindTag: m.kindTag, tsMs: m.tsMs,
            status: m.status, rawJson: m.rawJSONData)
    }

    static func stored(_ r: OlazCore.MessageRow) -> StoredMessage {
        StoredMessage(
            id: r.id, convId: r.convId, clientId: r.clientId, senderId: r.senderId, senderName: r.senderName,
            senderAvatar: r.senderAvatar, isMine: r.isMine, text: r.text, kindTag: r.kindTag, tsMs: r.tsMs,
            status: r.status, rawJSONData: r.rawJson)
    }

    static func row(_ c: StoredConversation) -> OlazCore.ConversationRow {
        OlazCore.ConversationRow(
            id: c.id, isGroup: c.isGroup, name: c.name, avatar: c.avatar, pinned: c.pinned, members: Int64(c.members),
            unread: Int64(c.unread), previewText: c.previewText, previewTsMs: c.previewTsMs,
            previewFromMe: c.previewFromMe, updatedAtMs: c.updatedAtMs)
    }

    static func stored(_ r: OlazCore.ConversationRow) -> StoredConversation {
        StoredConversation(
            id: r.id, isGroup: r.isGroup, name: r.name, avatar: r.avatar, pinned: r.pinned, members: Int(r.members),
            unread: Int(r.unread), previewText: r.previewText, previewTsMs: r.previewTsMs,
            previewFromMe: r.previewFromMe, updatedAtMs: r.updatedAtMs)
    }

    // MARK: JSON helpers

    /// Parses the lossless JSON text the core returns (64-bit ids come back as strings).
    static func object(_ json: String) -> [String: Any] {
        JSONLossless.parseObject(string: json) ?? [:]
    }

    static func objects(_ blobs: [String]) -> [[String: Any]] {
        blobs.compactMap { JSONLossless.parseObject(string: $0) }
    }
}
