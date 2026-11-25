import Foundation
@testable import Olaz

enum PollSnapshot {
    static func encodeDetail(_ d: PollDetail) -> CaseJSON {
        .object([
            "id": .string(d.id),
            "group_id": .string(d.groupId),
            "question": .string(d.question),
            "creator": .string(d.creator),
            "creator_name": .string(d.creatorName),
            "created_ms": d.created.map { .int(Int64(($0.timeIntervalSince1970 * 1000.0).rounded())) } ?? .null,
            "expires_ms": d.expires.map { .int(Int64(($0.timeIntervalSince1970 * 1000.0).rounded())) } ?? .null,
            "closed": .bool(d.closed),
            "joined": .bool(d.joined),
            "multi": .bool(d.multi),
            "allow_add": .bool(d.allowAdd),
            "anonymous": .bool(d.anonymous),
            "hide_preview": .bool(d.hidePreview),
            "voter_count": .int(Int64(d.voterCount)),
            "can_close": .bool(d.canClose),
            "total_votes": .int(Int64(d.totalVotes)),
            "results_hidden": .bool(d.resultsHidden),
            "voters_visible": .bool(d.votersVisible),
            "options": .array(d.options.map { opt in
                let w = d.weight(of: opt)
                return .object([
                    "id": .string(opt.id),
                    "content": .string(opt.content),
                    "votes": .int(Int64(opt.votes)),
                    "voted": .bool(opt.voted),
                    "weight": .double(w, raw: String(w)),
                ])
            }),
        ])
    }

    static func encodePollPinState(_ p: PollPinState) -> CaseJSON {
        .object([
            "ready": .bool(p.ready),
            "can_pin": .bool(p.canPin),
            "pinned": .bool(p.pinned),
            "limit": .int(Int64(p.limit)),
            "offers_pin": .bool(p.offersPin),
        ])
    }

    static func encodePinnedList(_ list: PinnedList) -> CaseJSON {
        .object([
            "ready": .bool(list.ready),
            "can_pin": .bool(list.canPin),
            "limit": .int(Int64(list.limit)),
            "items": .array(list.items.map { item in
                .object([
                    "ref": .string(item.ref),
                    "kind": .string(item.kind.rawValue),
                    "title": .string(item.title),
                    "sender": .string(item.sender),
                    "thumbnail": item.thumbnail.map { .string($0.absoluteString) } ?? .null,
                    "msg_id": .string(item.msgId),
                    "cli_msg_id": .string(item.cliMsgId),
                ])
            }),
        ])
    }

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
        lookups: [String: CaseJSON] = [:],
        lastAliasResult: (ok: Bool, text: String)? = nil,
        results: [String: CaseJSON] = [:],
        groupLogs: [String] = [],
        watchedCheckIds: [String]? = nil
    ) async -> CaseJSON {
        var out = await GroupSnapshot.capture(
            from: engine,
            pinBoard: pinBoard,
            lastActionResult: lastActionResult,
            bootstrapLogs: bootstrapLogs,
            lastSendResult: lastSendResult,
            sendLogs: sendLogs,
            pruneNextExpiryMs: pruneNextExpiryMs,
            actionLogs: actionLogs,
            lookups: lookups,
            lastAliasResult: lastAliasResult,
            results: results,
            groupLogs: groupLogs
        ).objectValue ?? [:]

        let detailsObj = engine.polls.details.mapValues { encodeDetail($0) }
        let failedArr = engine.polls.failed
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            .map(CaseJSON.string)
        let pollPinsObj = engine.polls.pins.mapValues { encodePollPinState($0) }

        out["polls"] = .object([
            "details": .object(detailsObj),
            "failed": .array(failedArr),
            "pins": .object(pollPinsObj),
        ])

        out["pins"] = .object(engine.pins.mapValues { encodePinnedList($0) })

        let maskWatched = PollClock.didEvictWatched
        let watchedVal: CaseJSON = maskWatched
            ? .null
            : .array(PollClock.watched.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map(CaseJSON.string))

        let watchedContainsVal: CaseJSON = {
            guard maskWatched, let checkIds = watchedCheckIds else { return .null }
            var map: [String: CaseJSON] = [:]
            for id in checkIds {
                map[id] = .bool(PollClock.watched[id] != nil)
            }
            return .object(map)
        }()

        let checkSet = Set(watchedCheckIds ?? [])
        var lastAttemptObj: [String: CaseJSON] = [:]
        for (id, date) in PollClock.lastAttempt {
            if maskWatched && !checkSet.contains(id) { continue }
            lastAttemptObj[id] = .int(Int64((date.timeIntervalSince1970 * 1000.0).rounded()))
        }

        let pendingRefreshArr = PollClock.refreshTasks.keys
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            .map(CaseJSON.string)

        out["poll_clock"] = .object([
            "watched": watchedVal,
            "watched_count": .int(Int64(PollClock.watched.count)),
            "watched_contains": watchedContainsVal,
            "last_attempt_ms": .object(lastAttemptObj),
            "seen_messages_count": .int(Int64(PollClock.seenMessages.count)),
            "pending_refresh_ids": .array(pendingRefreshArr),
        ])

        return .object(out)
    }
}
