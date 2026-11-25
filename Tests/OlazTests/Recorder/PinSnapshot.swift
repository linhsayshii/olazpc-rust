import Foundation
@testable import Olaz

enum PinSnapshot {
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
        pinLogs: [String] = []
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

        out["pins"] = .object(engine.pins.mapValues { PollSnapshot.encodePinnedList($0) })

        let rawTopicsObj = engine.cachedBoardRawTopics.mapValues { entry in
            CaseJSON.object([
                "version": .int(entry.version),
                "topic_ids": .array(
                    entry.topics.keys
                        .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
                        .map(CaseJSON.string)
                ),
            ])
        }
        out["cached_board_raw_topics"] = .object(rawTopicsObj)
        out["pin_logs"] = .array(pinLogs.map(CaseJSON.string))

        return .object(out)
    }
}
