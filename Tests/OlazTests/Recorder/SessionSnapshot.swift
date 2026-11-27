import Foundation
@testable import Olaz

enum SessionSnapshot {
    @MainActor
    static func capture(from engine: ZaloEngine) -> CaseJSON {
        let phaseObj: CaseJSON = {
            switch engine.phase {
            case .starting:
                return .object(["kind": .string("starting")])
            case .preparing(let setup):
                return .object([
                    "kind": .string("preparing"),
                    "failure": setup.failure.map(CaseJSON.string) ?? .null,
                ])
            case .login(let login):
                var obj: [String: CaseJSON] = [
                    "kind": .string("login"),
                    "qr": login.qrPNG != nil ? (engine.recordedQRPayload.map(CaseJSON.string) ?? .null) : .null,
                ]
                switch login.step {
                case .generating:
                    obj["step"] = .string("generating")
                case .waitingScan:
                    obj["step"] = .string("waiting_scan")
                case .waitingConfirm(let name, let avatar):
                    obj["step"] = .string("waiting_confirm")
                    obj["name"] = .string(name)
                    obj["avatar"] = avatar.map { .string($0.absoluteString) } ?? .null
                case .expired:
                    obj["step"] = .string("expired")
                case .failed(let message):
                    obj["step"] = .string("failed")
                    obj["message"] = .string(Self.canonicalizeNSURLErrorMessage(message))
                }
                return .object(obj)
            case .signingIn:
                return .object(["kind": .string("signing_in")])
            case .ready:
                return .object(["kind": .string("ready")])
            }
        }()

        let profileVal: CaseJSON = {
            guard let p = engine.profile else { return .null }
            return .object([
                "user_id": .string(p.userId),
                "display_name": .string(p.displayName),
                "avatar": p.avatar.map { .string($0.absoluteString) } ?? .null,
                "phone": p.phone.map(CaseJSON.string) ?? .null,
            ])
        }()

        let prefsObj: [String: CaseJSON] = engine.recordedSessionPrefs.mapValues { .string($0) }

        return .object([
            "phase": phaseObj,
            "profile": profileVal,
            "sign_out_notice": engine.signOutNotice.map(CaseJSON.string) ?? .null,
            "self_conversation_id": engine.selfConversationId.map(CaseJSON.string) ?? .null,
            "prefs": .object(prefsObj),
            "attest_enforced": .bool(engine.attestEnforced),
        ])
    }

    static func matchesPredicate(_ snapshot: CaseJSON, predicate: CaseJSON) -> Bool {
        guard let wantPhase = predicate["phase"]?.stringValue,
              let snapPhase = snapshot["phase"],
              snapPhase["kind"]?.stringValue == wantPhase
        else {
            return false
        }
        guard let wantStep = predicate["step"]?.stringValue else {
            return true
        }
        return snapPhase["step"]?.stringValue == wantStep
    }

    @MainActor
    static func matchesPredicate(_ engine: ZaloEngine, predicate: CaseJSON) -> Bool {
        matchesPredicate(capture(from: engine), predicate: predicate)
    }

    /// Normalizes host-locale-localized `NSURLErrorDomain` fallback strings (e.g. Vietnamese macOS
    /// `"Không thể hoàn tất tác vụ. (Lỗi NSURLErrorDomain -1004.)"`) to Foundation's canonical English
    /// `"The operation couldn’t be completed. (NSURLErrorDomain error -1004.)"` so recordings replay
    /// deterministically across any macOS UI language while keeping non-`NSURLErrorDomain` messages verbatim.
    private static func canonicalizeNSURLErrorMessage(_ message: String) -> String {
        guard message.contains("NSURLErrorDomain"),
              let match = message.firstMatch(of: /NSURLErrorDomain(?: error)? (-?\d+)/)
        else {
            return message
        }
        return "The operation couldn\u{2019}t be completed. (NSURLErrorDomain error \(match.1).)"
    }
}
