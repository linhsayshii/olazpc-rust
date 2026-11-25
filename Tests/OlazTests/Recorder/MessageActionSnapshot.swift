import Foundation
@testable import Olaz

enum MessageActionSnapshot {
    @MainActor
    static func capture(
        from engine: ZaloEngine,
        pinBoard: PinBoard? = nil,
        lastActionResult: ConversationActionResult? = nil,
        bootstrapLogs: [String] = [],
        lastSendResult: Bool? = nil,
        sendLogs: [String] = [],
        pruneNextExpiryMs: Int64? = nil,
        actionLogs: [String] = []
    ) async -> CaseJSON {
        var out = await SendSnapshot.capture(
            from: engine,
            pinBoard: pinBoard,
            lastActionResult: lastActionResult,
            bootstrapLogs: bootstrapLogs,
            lastSendResult: lastSendResult,
            sendLogs: sendLogs
        ).objectValue ?? [:]

        if var msgsObj = out["messages"]?.objectValue {
            for (convId, list) in engine.messages {
                guard let existingArr = msgsObj[convId]?.arrayValue, existingArr.count == list.count else { continue }
                let enriched: [CaseJSON] = zip(list, existingArr).map { m, base in
                    var dict = base.objectValue ?? [:]
                    dict["buttons"] = .array(m.cardButtons.map { b in
                        .object([
                            "ref": .string(b.ref),
                            "label": .string(b.label),
                            "enabled": .bool(b.enabled),
                            "help": .string(b.help),
                        ])
                    })
                    return .object(dict)
                }
                msgsObj[convId] = .array(enriched)
            }
            out["messages"] = .object(msgsObj)
        }

        out["delete_undo"] = engine.deleteUndo.map { undo in
            .object([
                "conv_id": .string(undo.conversationId),
                "count": .int(Int64(undo.count)),
                "deadline_ms": .int(Int64((undo.deadline.timeIntervalSince1970 * 1000).rounded())),
            ])
        } ?? .null

        out["message_confirm"] = engine.messageConfirm.map { confirm in
            let actionName: String = {
                switch confirm.action {
                case .deleteForMe: return "delete_for_me"
                case .deleteMany: return "delete_many"
                case .recallMany: return "recall_many"
                case .pin: return "pin"
                case .unpin: return "unpin"
                }
            }()
            return .object([
                "conv_id": .string(confirm.conversationId),
                "action": .string(actionName),
                "title": .string(confirm.title),
                "message": .string(confirm.message),
                "ok": .string(confirm.ok),
                "destructive": .bool(confirm.destructive),
            ])
        } ?? .null

        out["auto_delete"] = engine.autoDelete.map { map in
            .object(map.mapValues { .int($0) })
        } ?? .null

        out["starred_ids"] = .array(
            engine.cachedStarredIds
                .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
                .map(CaseJSON.string)
        )

        out["prune_next_expiry_ms"] = pruneNextExpiryMs.map(CaseJSON.int) ?? .null

        out["cached_profiles"] = .object(engine.cachedProfiles.mapValues { p in
            .object([
                "name": .string(p.name),
                "avatar": .string(p.avatar),
            ])
        })

        out["action_logs"] = .array(actionLogs.map(CaseJSON.string))

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
            if let existingStoreMsgs = storeObj["messages"]?.arrayValue,
               existingStoreMsgs.count == storedMsgs.count {
                let enrichedStoreMsgs: [CaseJSON] = zip(storedMsgs, existingStoreMsgs).map { row, base in
                    var dict = base.objectValue ?? [:]
                    let decoded = ZaloWireParser.decodeStoredMessage(row)
                    let reactionsJSON: [CaseJSON] = (decoded?.reactions ?? []).map { r in
                        let icon = r.icon.emoji.isEmpty
                            ? (r.icon.key.isEmpty ? r.icon.type : r.icon.key)
                            : r.icon.emoji
                        return .object([
                            "icon": .string(icon),
                            "count": .int(Int64(r.count)),
                            "includes_me": .bool(r.includesMe),
                        ])
                    }
                    dict["reactions"] = .array(reactionsJSON)
                    dict["starred"] = .bool(decoded?.menu.starred ?? false)
                    return .object(dict)
                }
                storeObj["messages"] = .array(enrichedStoreMsgs)
            }

            var prefsObj = storeObj["prefs"]?.objectValue ?? [:]
            let starredIds = ((try? await store.getPreferenceStrings(key: "starredIds")) ?? [])
                .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            prefsObj["starred_ids"] = .array(starredIds.map(CaseJSON.string))

            let seenIds = (try? await store.getPreferenceStrings(key: "seenReactionEventIds")) ?? []
            prefsObj["seen_reaction_event_ids"] = .array(seenIds.map(CaseJSON.string))

            storeObj["prefs"] = .object(prefsObj)
            out["store"] = .object(storeObj)
        }

        return .object(out)
    }
}
