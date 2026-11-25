import Foundation
@testable import Olaz

enum ContactSnapshot {
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
        lastAliasResult: (ok: Bool, text: String)? = nil
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

        if var msgsObj = out["messages"]?.objectValue {
            for (convId, list) in engine.messages {
                guard let existingArr = msgsObj[convId]?.arrayValue, existingArr.count == list.count else { continue }
                let enriched: [CaseJSON] = zip(list, existingArr).map { m, base in
                    var dict = base.objectValue ?? [:]
                    if let existingReactions = dict["reactions"]?.arrayValue, existingReactions.count == m.reactions.count {
                        let withNames: [CaseJSON] = zip(m.reactions, existingReactions).map { r, rBase in
                            var rDict = rBase.objectValue ?? [:]
                            rDict["names"] = .array(r.names.map(CaseJSON.string))
                            return .object(rDict)
                        }
                        dict["reactions"] = .array(withNames)
                    }
                    return .object(dict)
                }
                msgsObj[convId] = .array(enriched)
            }
            out["messages"] = .object(msgsObj)
        }

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
                    if let reactions = decoded?.reactions,
                       let existingReactions = dict["reactions"]?.arrayValue,
                       existingReactions.count == reactions.count {
                        let withNames: [CaseJSON] = zip(reactions, existingReactions).map { r, rBase in
                            var rDict = rBase.objectValue ?? [:]
                            rDict["names"] = .array(r.names.map(CaseJSON.string))
                            return .object(rDict)
                        }
                        dict["reactions"] = .array(withNames)
                    }
                    return .object(dict)
                }
                storeObj["messages"] = .array(enrichedStoreMsgs)
            }
            out["store"] = .object(storeObj)
        }

        let c = engine.contacts
        let friendsJSON: [CaseJSON] = c.friends.map { f in
            .object([
                "id": .string(f.id),
                "name": .string(f.name),
                "zalo_name": .string(f.zaloName),
                "avatar": f.avatar.map { .string($0.absoluteString) } ?? .null,
                "last_active_ms": f.lastActive.map { .int(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? .null,
                "online": .bool(f.online),
                "section": .string(f.section),
                "sort_key": .string(f.sortKey),
            ])
        }
        let groupsJSON: [CaseJSON] = c.groups.map { g in
            .object([
                "id": .string(g.id),
                "name": .string(g.name),
                "avatar": g.avatar.map { .string($0.absoluteString) } ?? .null,
                "members": .int(Int64(g.members)),
                "sort_key": .string(g.sortKey),
            ])
        }
        func reqJSON(_ r: ContactsState.FriendRequest) -> CaseJSON {
            .object([
                "id": .string(r.id),
                "name": .string(r.name),
                "avatar": r.avatar.map { .string($0.absoluteString) } ?? .null,
                "message": .string(r.message),
                "date_ms": r.date.map { .int(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? .null,
            ])
        }
        let searchUserJSON: CaseJSON = c.search.user.map { u in
            .object([
                "id": .string(u.id),
                "name": .string(u.name),
                "zalo_name": .string(u.zaloName),
                "avatar": u.avatar.map { .string($0.absoluteString) } ?? .null,
                "bio": .string(u.bio),
                "is_friend": .bool(u.isFriend),
                "is_self": .bool(u.isSelf),
                "requested": .bool(u.requested),
                "requesting": .bool(u.requesting),
                "default_message": .string(u.defaultMessage),
                "max_message": .int(Int64(u.maxMessage)),
            ])
        } ?? .null
        let noticeJSON: CaseJSON = c.notice.map { n in
            .object([
                "seq": .int(Int64(n.seq)),
                "ok": .bool(n.ok),
                "text": .string(n.text),
            ])
        } ?? .null

        out["contacts"] = .object([
            "friends": .array(friendsJSON),
            "groups": .array(groupsJSON),
            "received": .array(c.received.map(reqJSON)),
            "sent": .array(c.sent.map(reqJSON)),
            "pending_request_count": .int(Int64(c.pendingRequestCount)),
            "loading_requests": .bool(c.loadingRequests),
            "search": .object([
                "status": .string(c.search.status.rawValue),
                "error": c.search.error.map(CaseJSON.string) ?? .null,
                "user": searchUserJSON,
            ]),
            "notice": noticeJSON,
            "friends_loaded": .bool(c.friendsLoaded),
            "groups_loaded": .bool(c.groupsLoaded),
        ])

        out["blocked_users"] = engine.blockedUsers.map { list in
            .array(list.map { u in
                .object([
                    "id": .string(u.id),
                    "name": .string(u.name),
                    "avatar": u.avatar.map { .string($0.absoluteString) } ?? .null,
                ])
            })
        } ?? .null

        out["aliases"] = .object(engine.cachedAliases.mapValues(CaseJSON.string))
        out["friend_global_ids"] = .object(engine.cachedFriendGlobalIds.mapValues(CaseJSON.string))
        out["cached_group_details"] = .array(
            engine.cachedGroupDetails.keys
                .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
                .map(CaseJSON.string)
        )
        out["lookups"] = .object(lookups)
        out["last_alias_result"] = lastAliasResult.map { res in
            .object([
                "ok": .bool(res.ok),
                "text": .string(res.text),
            ])
        } ?? .null

        return .object(out)
    }
}
