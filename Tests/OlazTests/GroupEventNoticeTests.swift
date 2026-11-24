import Foundation
import Testing
@testable import Olaz

/// cmd 601 group controls become info lines in the chat, worded like the official `_processGroupCtrlEvents_old`.
@Suite("Group event notices")
struct GroupEventNoticeTests {
    private let names = ["100": "Lan", "200": "Minh", "300": "Hoa"]
    private func notice(_ act: String, _ data: [String: Any]) -> String? {
        ZaloWireParser.groupEventNotice(act: act, data: data, myUid: "me") { names[$0] }
    }
    private func members(_ ids: String...) -> [[String: Any]] { ids.map { ["id": $0, "dName": "dn\($0)"] } }

    @Test func addedMembers() {
        #expect(notice("join", ["groupId": "9", "sourceId": "me", "updateMembers": members("100")]) == "Lan được bạn thêm vào nhóm")
        #expect(notice("join", ["groupId": "9", "sourceId": "200", "updateMembers": members("100", "300")]) == "Lan, Hoa được Minh thêm vào nhóm")
        #expect(notice("join", ["groupId": "9", "sourceId": "200", "updateMembers": members("me")]) == "Bạn được Minh thêm vào nhóm")
    }

    @Test func joinedByThemselves() {
        #expect(notice("join", ["groupId": "9", "sourceId": "100", "creatorId": "200", "updateMembers": members("100")]) == "Lan đã tham gia nhóm")
        #expect(notice("join", ["groupId": "9", "sourceId": "me", "creatorId": "200", "updateMembers": members("me")]) == "Bạn vừa tham gia nhóm")
        // The creator "joining" a group it just made: no line.
        #expect(notice("join", ["groupId": "9", "sourceId": "100", "creatorId": "100", "updateMembers": members("100")]) == nil)
    }

    @Test func leftRemovedBlocked() {
        #expect(notice("leave", ["groupId": "9", "sourceId": "100", "updateMembers": members("100")]) == "Lan đã rời khỏi nhóm")
        #expect(notice("remove_member", ["groupId": "9", "sourceId": "me", "updateMembers": members("100")]) == "Lan được bạn xóa khỏi nhóm")
        #expect(notice("remove_member", ["groupId": "9", "sourceId": "200", "updateMembers": members("me")]) == "Bạn được Minh xóa khỏi nhóm")
        #expect(notice("block_member", ["groupId": "9", "sourceId": "me", "updateMembers": members("100")]) == "Lan bị bạn chặn khỏi nhóm này")
        #expect(notice("block_member", ["groupId": "9", "sourceId": "200", "updateMembers": members("100")]) == "Lan bị Minh chặn khỏi nhóm này")
    }

    @Test func renameAndAvatar() {
        #expect(notice("update", ["groupId": "9", "sourceId": "me", "groupName": "Nhà"]) == "Tên nhóm đã đổi thành Nhà")
        #expect(notice("update", ["groupId": "9", "sourceId": "200", "groupName": "Nhà"]) == "Minh đổi tên nhóm thành Nhà")
        #expect(notice("update_avatar", ["groupId": "9", "sourceId": "me"]) == "Ảnh đại diện nhóm đã thay đổi")
        #expect(notice("update_avatar", ["groupId": "9", "sourceId": "200"]) == "Minh đổi ảnh đại diện nhóm")
    }

    @Test func unknownNames() {
        // Not in contacts: the dName the event carries.
        #expect(notice("leave", ["groupId": "9", "sourceId": "555", "updateMembers": [["id": "555", "dName": "Tú"]]]) == "Tú đã rời khỏi nhóm")
        #expect(notice("update", ["groupId": "9", "sourceId": "200"]) == nil)
        #expect(notice("typing", ["groupId": "9"]) == nil)
    }
}
