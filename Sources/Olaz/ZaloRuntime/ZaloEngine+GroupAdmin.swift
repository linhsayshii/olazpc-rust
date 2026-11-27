import Foundation
import OlazCore

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
        guard !info.isEmpty,
              JSONSerialization.isValidJSONObject(info),
              let data = try? JSONSerialization.data(withJSONObject: info),
              let json = String(data: data, encoding: .utf8) else {
            return GroupRoles()
        }
        let rec = groupRolesFromJsonFfi(infoJson: json)
        return GroupRoles(owner: rec.owner, admins: Set(rec.admins), joinApproval: rec.joinApproval)
    }
}

extension ZaloEngine {
    func groupRoles(_ groupId: String) -> GroupRoles {
        GroupRoles.from(cachedGroupDetails[ZaloWireParser.cleanGroupId(groupId)] ?? [:])
    }

    @discardableResult
    func setGroupAdmin(_ groupId: String, uid: String, admin: Bool) async -> Bool {
        guard let core = await ensureCoreEngine(),
              let res = try? await core.setGroupAdmin(groupId: groupId, uid: uid, admin: admin, nowMs: nowMs()) else {
            return false
        }
        await waitForMirrorVersion(res.version)
        return res.ok
    }

    @discardableResult
    func changeGroupOwner(_ groupId: String, uid: String) async -> Bool {
        guard let core = await ensureCoreEngine(),
              let res = try? await core.changeGroupOwner(groupId: groupId, uid: uid, nowMs: nowMs()) else {
            return false
        }
        await waitForMirrorVersion(res.version)
        return res.ok
    }

    @discardableResult
    func blockGroupMember(_ groupId: String, uid: String) async -> Bool {
        guard let core = await ensureCoreEngine(),
              let res = try? await core.blockGroupMember(groupId: groupId, uid: uid, nowMs: nowMs()) else {
            return false
        }
        await waitForMirrorVersion(res.version)
        return res.ok
    }

    func groupPendingMembers(_ groupId: String) async -> [GroupPendingMember]? {
        guard let core = await ensureCoreEngine(),
              let res = try? await core.fetchGroupPending(groupId: groupId) else {
            return nil
        }
        await waitForMirrorVersion(res.version)
        return res.members?.map {
            GroupPendingMember(id: $0.id, name: $0.name, avatar: $0.avatar.flatMap(URL.init(string:)))
        }
    }

    @discardableResult
    func reviewGroupPending(_ groupId: String, uids: [String], approve: Bool) async -> Bool {
        guard let core = await ensureCoreEngine(),
              let res = try? await core.reviewGroupPending(groupId: groupId, uids: uids, approve: approve, nowMs: nowMs()) else {
            return false
        }
        await waitForMirrorVersion(res.version)
        return res.ok
    }

    /// "Chế độ phê duyệt thành viên mới": the group's settings with `joinAppr` changed (all of them are sent, as officially).
    @discardableResult
    func setGroupJoinApproval(_ groupId: String, on: Bool) async -> Bool {
        guard let core = await ensureCoreEngine(),
              let res = try? await core.setGroupJoinApproval(groupId: groupId, on: on, nowMs: nowMs()) else {
            return false
        }
        await waitForMirrorVersion(res.version)
        return res.ok
    }

    func groupLink(_ groupId: String) async -> GroupLink? {
        guard let core = await ensureCoreEngine(),
              let res = try? await core.fetchGroupLink(groupId: groupId) else {
            return nil
        }
        await waitForMirrorVersion(res.version)
        return res.link.map { GroupLink(link: $0.link, enabled: $0.enabled) }
    }

    func setGroupLink(_ groupId: String, renew: Bool) async -> GroupLink? {
        guard let core = await ensureCoreEngine(),
              let res = try? await core.setGroupLink(groupId: groupId, renew: renew) else {
            return nil
        }
        await waitForMirrorVersion(res.version)
        return res.link.map { GroupLink(link: $0.link, enabled: $0.enabled) }
    }
}
