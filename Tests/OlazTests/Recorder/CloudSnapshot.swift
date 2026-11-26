import Foundation
@testable import Olaz

enum CloudSnapshot {
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

        out["cloud"] = encodeCloudState(engine.cloud)
        out["results"] = .object(results)
        return .object(out)
    }

    static func encodeCloudState(_ state: CloudState) -> CaseJSON {
        .object([
            "plan": state.plan.map(encodePlan) ?? .null,
            "media": encodeBreakdown(state.media),
            "my_cloud_types": encodeBreakdown(state.myCloudTypes),
            "conversations": .array(state.conversations.map(encodeConversation)),
            "settings": encodeSettings(state.settings),
            "changed": .int(Int64(state.changed)),
            "loaded": .bool(state.loaded),
            "hidden_lookup": .bool(state.hiddenLookup),
            "self_id": state.selfId.map(CaseJSON.string) ?? .null,
        ])
    }

    static func encodePlan(_ plan: CloudState.Plan) -> CaseJSON {
        .object([
            "kind": .string(plan.kind.rawValue),
            "name": .string(plan.name),
            "quota": .int(plan.quota),
            "usage": .int(plan.usage),
            "family": .int(plan.family),
            "cloud_media": .int(plan.cloudMedia),
            "message_backup": .int(plan.messageBackup),
            "my_cloud": .int(plan.myCloud),
            "expire_at_ms": encodeDateMs(plan.expireAt),
            "auto_renew": plan.autoRenew.map(CaseJSON.bool) ?? .null,
            "months": .int(Int64(plan.months)),
            "has_key": .bool(plan.hasKey),
            "backup_media": .bool(plan.backupMedia),
            "backup_my_cloud": .bool(plan.backupMyCloud),
            "backup_messages": .bool(plan.backupMessages),
            "file_limit": .int(plan.fileLimit),
        ])
    }

    static func encodeBreakdown(_ b: CloudBreakdown) -> CaseJSON {
        .object([
            "photo": .int(b.photo),
            "video": .int(b.video),
            "file": .int(b.file),
            "voice": .int(b.voice),
            "total": .int(b.total),
        ])
    }

    static func encodeConversation(_ c: CloudState.Conversation) -> CaseJSON {
        .object([
            "id": .string(c.id),
            "name": .string(c.name),
            "avatar": c.avatar.map { .string($0.absoluteString) } ?? .null,
            "is_group": .bool(c.isGroup),
            "total": .int(c.total),
            "last_activity_ms": encodeDateMs(c.lastActivity),
        ])
    }

    static func encodeSettings(_ s: CloudState.Settings) -> CaseJSON {
        .object([
            "offload_enabled": .bool(s.offloadEnabled),
            "offload_available": .bool(s.offloadAvailable),
            "last_offload_at_ms": encodeDateMs(s.lastOffloadAt),
            "last_offload_size": .int(s.lastOffloadSize),
            "ttl_days": .int(Int64(s.ttlDays)),
        ])
    }

    static func encodePage(_ page: CloudPage) -> CaseJSON {
        .object([
            "items": .array(page.items.map(encodeItem)),
            "has_more": .bool(page.hasMore),
            "error": page.error.map(CaseJSON.string) ?? .null,
        ])
    }

    static func encodeItem(_ item: CloudItem) -> CaseJSON {
        .object([
            "id": .string(item.id),
            "kind": .string(item.kind.rawValue),
            "conv_id": .string(item.conversationId),
            "conv_name": .string(item.conversationName),
            "size": .int(item.size),
            "date_ms": encodeDateMs(item.date),
            "title": .string(item.title),
            "ext": .string(item.ext),
            "duration": .int(Int64(item.duration.rounded())),
            "width": .int(Int64(item.width)),
            "height": .int(Int64(item.height)),
        ])
    }

    static func encodeFetch(_ fetch: CloudFetch) -> CaseJSON {
        switch fetch {
        case .ready(let file):
            return .object([
                "status": .string("ready"),
                "file": .object([
                    "url": .string(file.url.absoluteString),
                    "kind": .string(file.kind.rawValue),
                    "title": .string(file.title),
                    "ext": .string(file.ext),
                    "size": .int(file.size),
                    "date_ms": encodeDateMs(file.date),
                ]),
            ])
        case .expired:
            return .object([
                "status": .string("expired"),
            ])
        case .failed(let error):
            return .object([
                "status": .string("failed"),
                "error": .string(error),
            ])
        }
    }

    static func encodeMediaResolution(_ res: MediaResolution) -> CaseJSON {
        switch res {
        case .file(let url):
            return .object([
                "state": .string("file"),
                "path": .string(url.path),
            ])
        case .expired:
            return .object(["state": .string("expired")])
        case .unavailable:
            return .object(["state": .string("unavailable")])
        case .unsupported:
            return .object(["state": .string("unsupported")])
        }
    }

    static func encodeActionResult(_ res: CloudActionResult) -> CaseJSON {
        .object([
            "ok": .bool(res.ok),
            "deleted": .array(res.deleted.map(CaseJSON.string)),
            "failed": .array(res.failed.map(CaseJSON.string)),
            "error": res.error.map(CaseJSON.string) ?? .null,
        ])
    }

    private static func encodeDateMs(_ date: Date?) -> CaseJSON {
        date.map { .int(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? .null
    }
}
