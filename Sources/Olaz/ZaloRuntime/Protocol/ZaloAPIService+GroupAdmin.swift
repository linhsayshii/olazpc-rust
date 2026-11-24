import Foundation

/// Group administration (official `addGroupAdmin`, `changeGroupOwner`, `blockMember`, `getPendingMember`,
/// `getGroupLinkDetail` …). Every call is on the `group` service; ids are the bare group id.
struct GroupPendingMember: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var avatar: URL?

    /// `pending-mems/list` → {users:[{uid, dpn, avatar}]}.
    static func list(from data: [String: Any]) -> [GroupPendingMember] {
        ((data["users"] as? [[String: Any]]) ?? []).compactMap { row in
            let id = ZaloWireParser.stripUserPrefix(JSONLossless.string(row["uid"] ?? row["id"]))
            guard !id.isEmpty, id != "0" else { return nil }
            let name = [row["dpn"], row["displayName"], row["zaloName"]].map { JSONLossless.string($0) }.first { !$0.isEmpty } ?? ""
            let avatar = JSONLossless.string(row["avatar"])
            return GroupPendingMember(id: id, name: name, avatar: avatar.isEmpty ? nil : URL(string: avatar))
        }
    }
}

/// The group's join link (`link/detail`): {link, expiration_date, enabled}.
struct GroupLink: Equatable, Sendable {
    var link: String
    var enabled: Bool

    static func from(_ data: [String: Any]) -> GroupLink {
        let link = JSONLossless.string(data["link"] ?? data["url"])
        let enabled = JSONLossless.int64(data["enabled"]).map { $0 == 1 } ?? (data["enabled"] as? Bool) ?? !link.isEmpty
        return GroupLink(link: link, enabled: enabled && !link.isEmpty)
    }
}

extension ZaloSessionClient {
    private func groupCall(_ path: String, _ payload: [String: Any], post usePost: Bool = false) async throws -> [String: Any] {
        let resp = usePost
            ? try await post(service: "group", path: path, encryptedPayload: payload)
            : try await get(service: "group", path: path, encryptedPayload: payload)
        return resp["data"] as? [String: Any] ?? [:]
    }

    nonisolated static func membersPayload(groupId: String, members: [String], imei: String?) -> [String: Any] {
        var p: [String: Any] = ["grid": ZaloWireParser.cleanGroupId(groupId), "members": members.map(ZaloWireParser.stripUserPrefix)]
        if let imei { p["imei"] = imei }
        return p
    }

    /// "Thêm phó nhóm" / "Xóa phó nhóm": `admins/add` · `admins/remove` {grid, members, imei}.
    func setGroupAdminAPI(groupId: String, uid: String, admin: Bool) async throws {
        _ = try await groupCall(admin ? "/api/group/admins/add" : "/api/group/admins/remove",
                                Self.membersPayload(groupId: groupId, members: [uid], imei: imei))
    }

    /// "Chuyển quyền trưởng nhóm": POST `change-owner` {grid, newAdminId, imei, language}.
    func changeGroupOwnerAPI(groupId: String, uid: String) async throws {
        _ = try await groupCall("/api/group/change-owner", [
            "grid": ZaloWireParser.cleanGroupId(groupId), "newAdminId": ZaloWireParser.stripUserPrefix(uid),
            "imei": imei, "language": "vi",
        ], post: true)
    }

    /// "Chặn khỏi nhóm" / unblock: `blockedmems/add` · `blockedmems/remove` {grid, members}.
    func setGroupMemberBlockedAPI(groupId: String, uid: String, blocked: Bool) async throws {
        _ = try await groupCall(blocked ? "/api/group/blockedmems/add" : "/api/group/blockedmems/remove",
                                Self.membersPayload(groupId: groupId, members: [uid], imei: nil))
    }

    /// `pending-mems/list` {grid, imei}.
    func fetchGroupPendingAPI(groupId: String) async throws -> [GroupPendingMember] {
        GroupPendingMember.list(from: try await groupCall("/api/group/pending-mems/list",
                                                         ["grid": ZaloWireParser.cleanGroupId(groupId), "imei": imei]))
    }

    /// "Duyệt" / "Từ chối": `pending-mems/review` {grid, members, isApprove}.
    func reviewGroupPendingAPI(groupId: String, uids: [String], approve: Bool) async throws {
        _ = try await groupCall("/api/group/pending-mems/review", [
            "grid": ZaloWireParser.cleanGroupId(groupId), "members": uids.map(ZaloWireParser.stripUserPrefix), "isApprove": approve,
        ])
    }

    /// `link/detail` {grid, imei}.
    func fetchGroupLinkAPI(groupId: String) async throws -> GroupLink {
        GroupLink.from(try await groupCall("/api/group/link/detail", ["grid": ZaloWireParser.cleanGroupId(groupId), "imei": imei]))
    }

    /// "Tạo link mới" `link/new` {grid, imei}; "Tắt link" `link/disable` {grid}.
    func setGroupLinkAPI(groupId: String, renew: Bool) async throws -> GroupLink {
        let grid = ZaloWireParser.cleanGroupId(groupId)
        if renew { return GroupLink.from(try await groupCall("/api/group/link/new", ["grid": grid, "imei": imei])) }
        _ = try await groupCall("/api/group/link/disable", ["grid": grid])
        return GroupLink(link: "", enabled: false)
    }

    /// `setting/update` {…the group's settings, grid, imei} (official `updateGroupSettings` sends them all).
    func updateGroupSettingsAPI(groupId: String, settings: ZaloJSONBox) async throws {
        var p = settings.dict
        p["grid"] = ZaloWireParser.cleanGroupId(groupId)
        p["imei"] = imei
        _ = try await groupCall("/api/group/setting/update", p)
    }
}
