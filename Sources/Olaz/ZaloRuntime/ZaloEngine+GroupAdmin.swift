import Foundation

/// The roles of a group (from its detail): owner and deputies.
struct GroupRoles: Equatable, Sendable {
    var owner: String = ""
    var admins: Set<String> = []
    /// Official `setting.joinAppr`: new members wait for approval.
    var joinApproval = false

    func isOwner(_ uid: String) -> Bool { !uid.isEmpty && uid == owner }
    func isAdmin(_ uid: String) -> Bool { admins.contains(uid) }
    func canManage(_ uid: String) -> Bool { isOwner(uid) || isAdmin(uid) }

    static func from(_ info: [String: Any]) -> GroupRoles {
        var roles = GroupRoles()
        roles.owner = ZaloWireParser.stripUserPrefix(JSONLossless.string(info["creatorId"] ?? info["creator_id"] ?? info["ownerId"]))
        for key in ["adminIds", "admin_ids", "admins"] {
            for raw in (info[key] as? [Any]) ?? [] {
                let uid = ZaloWireParser.stripUserPrefix(JSONLossless.string(raw))
                if !uid.isEmpty, uid != "0", uid != roles.owner { roles.admins.insert(uid) }
            }
        }
        let setting = info["setting"] as? [String: Any] ?? [:]
        roles.joinApproval = JSONLossless.int64(setting["joinAppr"]) == 1
        return roles
    }
}

extension ZaloEngine {
    func groupRoles(_ groupId: String) -> GroupRoles {
        GroupRoles.from(cachedGroupDetails[ZaloWireParser.cleanGroupId(groupId)] ?? [:])
    }

    /// Runs an admin call, shows the official toast, and reads the group again (roles, members).
    private func groupAdminAction(_ groupId: String, ok: String, fail: String, _ call: () async throws -> Void) async -> Bool {
        let gid = ZaloWireParser.groupConvId(groupId)
        do {
            try await call()
        } catch {
            let code = (error as? ZaloSessionError)?.code
            EngineLog.shared.write("group admin: failed code=\(code.map(String.init) ?? "-")")
            showActionCard(code == 166 ? "Chỉ có trưởng/phó nhóm thực hiện được tính năng này." : fail, in: gid)
            return false
        }
        groupMemberCache[gid] = nil
        await refreshGroupMetadata(gid)
        if !ok.isEmpty { showActionCard(ok, in: gid) }
        return true
    }

    @discardableResult
    func setGroupAdmin(_ groupId: String, uid: String, admin: Bool) async -> Bool {
        await groupAdminAction(groupId, ok: admin ? "Đã thêm phó nhóm" : "Đã xóa quyền phó nhóm",
                               fail: admin ? "Thêm quyền phó nhóm không thành công" : "Xóa quyền phó nhóm không thành công") {
            try await sessionClient.setGroupAdminAPI(groupId: groupId, uid: uid, admin: admin)
        }
    }

    @discardableResult
    func changeGroupOwner(_ groupId: String, uid: String) async -> Bool {
        await groupAdminAction(groupId, ok: "Đã chuyển quyền trưởng nhóm", fail: "Có lỗi xảy ra không thể thay đổi trưởng nhóm!") {
            try await sessionClient.changeGroupOwnerAPI(groupId: groupId, uid: uid)
        }
    }

    @discardableResult
    func blockGroupMember(_ groupId: String, uid: String) async -> Bool {
        await groupAdminAction(groupId, ok: "Đã chặn khỏi nhóm", fail: "Chặn thành viên không thành công") {
            try await sessionClient.setGroupMemberBlockedAPI(groupId: groupId, uid: uid, blocked: true)
        }
    }

    func groupPendingMembers(_ groupId: String) async -> [GroupPendingMember]? {
        try? await sessionClient.fetchGroupPendingAPI(groupId: groupId)
    }

    @discardableResult
    func reviewGroupPending(_ groupId: String, uids: [String], approve: Bool) async -> Bool {
        await groupAdminAction(groupId, ok: "", fail: "Không thể thực hiện, vui lòng thử lại") {
            try await sessionClient.reviewGroupPendingAPI(groupId: groupId, uids: uids, approve: approve)
        }
    }

    /// "Chế độ phê duyệt thành viên mới": the group's settings with `joinAppr` changed (all of them are sent, as officially).
    @discardableResult
    func setGroupJoinApproval(_ groupId: String, on: Bool) async -> Bool {
        var settings = (cachedGroupDetails[ZaloWireParser.cleanGroupId(groupId)]?["setting"] as? [String: Any]) ?? [:]
        settings["joinAppr"] = on ? 1 : 0
        let box = ZaloJSONBox(settings)
        return await groupAdminAction(groupId, ok: "", fail: "Không thể thay đổi cài đặt nhóm") {
            try await sessionClient.updateGroupSettingsAPI(groupId: groupId, settings: box)
        }
    }

    func groupLink(_ groupId: String) async -> GroupLink? {
        try? await sessionClient.fetchGroupLinkAPI(groupId: groupId)
    }

    func setGroupLink(_ groupId: String, renew: Bool) async -> GroupLink? {
        do {
            return try await sessionClient.setGroupLinkAPI(groupId: groupId, renew: renew)
        } catch {
            showActionCard("Không thể thực hiện, vui lòng thử lại", in: ZaloWireParser.groupConvId(groupId))
            return nil
        }
    }
}
