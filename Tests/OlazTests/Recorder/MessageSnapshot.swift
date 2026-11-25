import Foundation
@testable import Olaz

enum MessageSnapshot {
    @MainActor
    static func capture(
        from engine: ZaloEngine,
        pinBoard: PinBoard? = nil,
        lastActionResult: ConversationActionResult? = nil,
        bootstrapLogs: [String] = []
    ) async -> CaseJSON {
        var out = await ConversationSnapshot.capture(
            from: engine,
            pinBoard: pinBoard,
            lastActionResult: lastActionResult
        ).objectValue ?? [:]

        // 1. open_conversation_id
        out["open_conversation_id"] = engine.openConversationId.map(CaseJSON.string) ?? .null

        // 2. messages (per conversation, preserving in-memory window order)
        var msgsObj: [String: CaseJSON] = [:]
        for (convId, list) in engine.messages {
            let items: [CaseJSON] = list.map { m in
                let reactionsJSON: [CaseJSON] = m.reactions.map { r in
                    let icon = r.icon.emoji.isEmpty
                        ? (r.icon.key.isEmpty ? r.icon.type : r.icon.key)
                        : r.icon.emoji
                    return .object([
                        "icon": .string(icon),
                        "count": .int(Int64(r.count)),
                        "includes_me": .bool(r.includesMe),
                    ])
                }
                return .object([
                    "id": .string(m.id),
                    "client_id": .string(m.clientId),
                    "conv_id": .string(m.conversationId),
                    "sender_id": .string(m.senderId),
                    "sender_name": .string(m.senderName),
                    "sender_avatar": m.senderAvatar.map { .string($0.absoluteString) } ?? .null,
                    "date_ms": .int(Int64((m.date.timeIntervalSince1970 * 1000).rounded())),
                    "is_mine": .bool(m.isMine),
                    "kind_tag": .string(ZaloWireParser.serializeKind(m.kind).1),
                    "text": .string(m.text),
                    "is_e2ee": .bool(m.isE2EE),
                    "reactions": .array(reactionsJSON),
                ])
            }
            msgsObj[convId] = .array(items)
        }
        out["messages"] = .object(msgsObj)

        // 3. has_more_history
        out["has_more_history"] = .object(engine.hasMoreHistory.mapValues(CaseJSON.bool))

        // 4. history_ticks
        out["history_ticks"] = .object(engine.historyTicks.mapValues { .int(Int64($0)) })

        // 5. history_freshness
        out["history_freshness"] = .object(engine.historyFreshness.mapValues { f in
            switch f {
            case .upToDate: return .string("up_to_date")
            case .stale: return .string("stale")
            }
        })

        // 6. bootstrap_logs
        out["bootstrap_logs"] = .array(bootstrapLogs.map(CaseJSON.string))

        // 7. augment store with store.messages and U4 store.prefs keys
        if let store = engine.sqliteStore, var storeObj = out["store"]?.objectValue {
            let storedMsgs = ((try? await store.loadAllMessages()) ?? []).sorted { a, b in
                if a.convId != b.convId {
                    return a.convId.utf8.lexicographicallyPrecedes(b.convId.utf8)
                }
                if a.tsMs != b.tsMs {
                    return a.tsMs < b.tsMs
                }
                return a.id.utf8.lexicographicallyPrecedes(b.id.utf8)
            }
            let msgRowsJSON: [CaseJSON] = storedMsgs.map { row in
                .object([
                    "id": .string(row.id),
                    "conv_id": .string(row.convId),
                    "client_id": .string(row.clientId),
                    "sender_id": .string(row.senderId),
                    "sender_name": .string(row.senderName),
                    "sender_avatar": .string(row.senderAvatar),
                    "is_mine": .bool(row.isMine),
                    "text": .string(row.text),
                    "kind_tag": .string(row.kindTag),
                    "ts_ms": .int(row.tsMs),
                    "status": .string(row.status),
                ])
            }
            storeObj["messages"] = .array(msgRowsJSON)

            var prefsObj = storeObj["prefs"]?.objectValue ?? [:]
            let fullRefreshAt = try? await store.getPreferenceString(key: ZaloEngine.fullHistoryRefreshKey)
            prefsObj["history_full_refresh_at"] = (fullRefreshAt?.isEmpty == false) ? .string(fullRefreshAt!) : .null

            let ranksData = try? await store.getPreferenceData(key: "activityRanks")
            prefsObj["activity_ranks"] = ranksData.flatMap { try? CaseJSON.parse($0) } ?? .object([:])

            let aliasesData = try? await store.getPreferenceData(key: "aliases")
            prefsObj["aliases"] = aliasesData.flatMap { try? CaseJSON.parse($0) } ?? .object([:])

            storeObj["prefs"] = .object(prefsObj)
            out["store"] = .object(storeObj)
        }

        return .object(out)
    }
}
