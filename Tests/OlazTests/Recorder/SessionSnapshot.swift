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
                    obj["message"] = .string(message)
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
        ])
    }

    @MainActor
    static func matchesPredicate(_ engine: ZaloEngine, predicate: CaseJSON) -> Bool {
        guard let wantPhase = predicate["phase"]?.stringValue else { return false }
        let wantStep = predicate["step"]?.stringValue
        switch engine.phase {
        case .starting:
            return wantPhase == "starting"
        case .preparing:
            return wantPhase == "preparing"
        case .login(let login):
            guard wantPhase == "login" else { return false }
            guard let wantStep else { return true }
            switch login.step {
            case .generating: return wantStep == "generating"
            case .waitingScan: return wantStep == "waiting_scan"
            case .waitingConfirm: return wantStep == "waiting_confirm"
            case .expired: return wantStep == "expired"
            case .failed: return wantStep == "failed"
            }
        case .signingIn:
            return wantPhase == "signing_in"
        case .ready:
            return wantPhase == "ready"
        }
    }
}
