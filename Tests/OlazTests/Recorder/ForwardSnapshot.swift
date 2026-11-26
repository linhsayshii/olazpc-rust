import Foundation
@testable import Olaz

enum ForwardSnapshot {
    @MainActor
    static func capture(
        from engine: ZaloEngine,
        pinBoard: PinBoard? = nil,
        lastActionResult: ConversationActionResult? = nil,
        bootstrapLogs: [String] = [],
        lastSendResult: Bool? = nil,
        sendLogs: [String] = [],
        pruneNextExpiryMs: Int64? = nil,
        actionLogs: [String] = [],
        results: [String: CaseJSON] = [:]
    ) async -> CaseJSON {
        var out = await MessageActionSnapshot.capture(
            from: engine,
            pinBoard: pinBoard,
            lastActionResult: lastActionResult,
            bootstrapLogs: bootstrapLogs,
            lastSendResult: lastSendResult,
            sendLogs: sendLogs,
            pruneNextExpiryMs: pruneNextExpiryMs,
            actionLogs: actionLogs
        ).objectValue ?? [:]

        out["forward_request"] = engine.forwardRequest.map { req in
            .object([
                "conv_id": .string(req.conversationId),
                "msg_id": .string(req.message.id),
                "more": .array(req.more.map { .string($0.id) }),
            ])
        } ?? .null

        out["selection"] = engine.messageSelection.map { sel in
            .object([
                "conv_id": .string(sel.conversationId),
                "ids": .array(sel.ids.map(CaseJSON.string)),
                "anchor": sel.anchor.map(CaseJSON.string) ?? .null,
            ])
        } ?? .null

        out["results"] = .object(results)

        return .object(out)
    }

    static func encodeOutcome(_ outcome: MessageActionOutcome) -> CaseJSON {
        switch outcome {
        case .done(let text):
            return .object([
                "status": .string("done"),
                "text": text.map(CaseJSON.string) ?? .null,
            ])
        case .pending(let text):
            return .object([
                "status": .string("pending"),
                "text": .string(text),
            ])
        case .failed(let text):
            return .object([
                "status": .string("failed"),
                "text": .string(text),
            ])
        case .confirm(let title, let message, let ok, let cancel, let ref):
            return .object([
                "status": .string("confirm"),
                "title": .string(title),
                "message": .string(message),
                "ok": .string(ok),
                "cancel": .string(cancel),
                "ref": ref.map(CaseJSON.string) ?? .null,
            ])
        }
    }
}
