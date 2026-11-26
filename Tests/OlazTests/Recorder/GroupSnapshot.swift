import Foundation
@testable import Olaz

enum GroupSnapshot {
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
        groupLogs: [String] = []
    ) async -> CaseJSON {
        var out = await ContactSnapshot.capture(
            from: engine,
            pinBoard: pinBoard,
            lastActionResult: lastActionResult,
            bootstrapLogs: bootstrapLogs,
            lastSendResult: lastSendResult,
            sendLogs: sendLogs,
            pruneNextExpiryMs: pruneNextExpiryMs,
            actionLogs: actionLogs,
            lookups: lookups,
            lastAliasResult: lastAliasResult
        ).objectValue ?? [:]

        out["cached_group_details"] = .object(engine.cachedGroupDetails.mapValues { CaseJSON.fromAny($0) })

        let memberCacheObj = engine.groupMemberCache.mapValues { list -> CaseJSON in
            .array(list.map { c in
                .object([
                    "id": .string(c.id),
                    "name": .string(c.name),
                    "avatar": c.avatar.map { .string($0.absoluteString) } ?? .null,
                    "is_all": .bool(c.isAll),
                ])
            })
        }
        out["group_member_cache"] = .object(memberCacheObj)

        let cachedGroupsObj = engine.cachedGroups.mapValues { cg -> CaseJSON in
            .object([
                "name": .string(cg.name),
                "avatar": .string(cg.avatar),
                "members": .int(Int64(cg.members)),
            ])
        }
        out["cached_groups"] = .object(cachedGroupsObj)

        var groupIds = Set<String>()
        for cleanGrid in engine.cachedGroupDetails.keys {
            let gid = ZaloWireParser.groupConvId(cleanGrid)
            if !gid.isEmpty { groupIds.insert(gid) }
        }
        for g in engine.contacts.groups where !g.id.isEmpty {
            groupIds.insert(g.id)
        }
        for gid in engine.cachedGroups.keys where !gid.isEmpty {
            groupIds.insert(gid)
        }
        for gid in engine.groupMemberCache.keys where !gid.isEmpty {
            groupIds.insert(gid)
        }
        for conv in engine.conversations where conv.isGroup && !conv.id.isEmpty {
            groupIds.insert(conv.id)
        }
        var rolesObj: [String: CaseJSON] = [:]
        for gid in groupIds.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            let r = engine.groupRoles(gid)
            rolesObj[gid] = .object([
                "owner": .string(r.owner),
                "admins": .array(r.admins.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map(CaseJSON.string)),
                "join_approval": .bool(r.joinApproval),
            ])
        }
        out["group_roles"] = .object(rolesObj)

        out["navigation_request"] = engine.navigationRequest.map(CaseJSON.string) ?? .null
        out["results"] = .object(results)
        out["group_logs"] = .array(groupLogs.map(CaseJSON.string))

        if let store = engine.sqliteStore,
           var storeObj = out["store"]?.objectValue,
           var prefsObj = storeObj["prefs"]?.objectValue {
            var cachedGroupsPref: [String: CaseJSON] = [:]
            if let data = try? await store.getPreferenceData(key: "cachedGroups"),
               let decoded = try? JSONDecoder().decode([String: ZaloWebKitMigrator.CachedGroup].self, from: data) {
                cachedGroupsPref = decoded.mapValues { cg in
                    .object([
                        "name": .string(cg.name),
                        "avatar": .string(cg.avatar),
                        "members": .int(Int64(cg.members)),
                    ])
                }
            }
            prefsObj["cached_groups"] = .object(cachedGroupsPref)
            storeObj["prefs"] = .object(prefsObj)
            out["store"] = .object(storeObj)
        }

        return .object(out)
    }
}
