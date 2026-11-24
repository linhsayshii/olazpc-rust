import Foundation
import Testing
@testable import Olaz

@Suite("Quản trị nhóm")
struct GroupAdminTests {
    @Test func rolesFromDetail() {
        let roles = GroupRoles.from([
            "creatorId": "100", "adminIds": ["200", "100", "300"], "setting": ["joinAppr": 1, "blockName": 0],
        ])
        #expect(roles.owner == "100")
        #expect(roles.admins == ["200", "300"])
        #expect(roles.joinApproval)
        #expect(roles.canManage("200") && !roles.canManage("400"))
    }

    @Test func pendingAndLinkParsing() {
        let pending = GroupPendingMember.list(from: ["users": [
            ["uid": "500", "dpn": "Lan", "avatar": "https://a/b.jpg"], ["uid": "0", "dpn": "x"],
        ]])
        #expect(pending.map(\.id) == ["500"])
        #expect(pending.first?.name == "Lan")
        #expect(GroupLink.from(["link": "https://zalo.me/g/abc", "enabled": 1]) == GroupLink(link: "https://zalo.me/g/abc", enabled: true))
        #expect(GroupLink.from(["link": "", "enabled": 0]).enabled == false)
    }

    @Test func membersPayloadUsesBareIds() {
        let p = ZaloSessionClient.membersPayload(groupId: "g777", members: ["200"], imei: "i")
        #expect(p["grid"] as? String == "777")
        #expect(p["members"] as? [String] == ["200"])
        #expect(p["imei"] as? String == "i")
        #expect(ZaloSessionClient.membersPayload(groupId: "777", members: ["1"], imei: nil)["imei"] == nil)
    }
}
