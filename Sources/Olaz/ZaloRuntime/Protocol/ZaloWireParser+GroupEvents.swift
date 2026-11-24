import Foundation

// Group controls (cmd 601, `act_type:"group"`) the official client turns into info lines in the chat
// (`_processGroupCtrlEvents_old` → `addGroupEventMessages`): the server sends no message for them.
extension ZaloWireParser {
    /// The official info line for a group control, or nil when the act shows none.
    /// `data`: {groupId, sourceId, creatorId?, groupName?, updateMembers:[{id, dName}]}; `name` resolves a contact name.
    static func groupEventNotice(
        act: String, data: [String: Any], myUid: String, name: (String) -> String?
    ) -> String? {
        let me = stripUserPrefix(myUid)
        func isMe(_ uid: String) -> Bool { !uid.isEmpty && (uid == me || uid == "0") }
        func display(_ uid: String, fallback: String) -> String {
            if isMe(uid) { return "Bạn" }
            return name(uid).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        }
        // Official: my own entry first, the others named by their local name, else the event's dName.
        var members: [(id: String, name: String)] = ((data["updateMembers"] as? [[String: Any]]) ?? []).map { m in
            let id = stripUserPrefix(JSONLossless.string(m["id"]))
            return (id, display(id, fallback: JSONLossless.string(m["dName"])))
        }
        if let mine = members.firstIndex(where: { isMe($0.id) }) { members.insert(members.remove(at: mine), at: 0) }
        let names = members.map(\.name).filter { !$0.isEmpty }.joined(separator: ", ")
        let sourceId = stripUserPrefix(JSONLossless.string(data["sourceId"]))
        let byMe = isMe(sourceId)
        let source = display(sourceId, fallback: "")

        switch act {
        case "join":
            guard !members.isEmpty else { return nil }
            if members.count == 1, members[0].id == sourceId {
                let creator = stripUserPrefix(JSONLossless.string(data["creatorId"]))
                guard creator != members[0].id else { return nil }
                return isMe(members[0].id) ? "Bạn vừa tham gia nhóm" : "\(members[0].name) đã tham gia nhóm"
            }
            return byMe ? "\(names) được bạn thêm vào nhóm" : "\(names) được \(source) thêm vào nhóm"
        case "leave":
            guard let first = members.first else { return nil }
            return "\(first.name) đã rời khỏi nhóm"
        case "remove_member":
            guard !names.isEmpty else { return nil }
            return byMe ? "\(names) được bạn xóa khỏi nhóm" : "\(names) được \(source) xóa khỏi nhóm"
        case "block_member":
            guard !names.isEmpty else { return nil }
            return byMe ? "\(names) bị bạn chặn khỏi nhóm này" : "\(names) bị \(source) chặn khỏi nhóm này"
        case "update":
            let groupName = JSONLossless.string(data["groupName"])
            guard data["groupName"] != nil, !groupName.isEmpty else { return nil }
            return byMe ? "Tên nhóm đã đổi thành \(groupName)" : "\(source) đổi tên nhóm thành \(groupName)"
        case "update_avatar":
            return byMe ? "Ảnh đại diện nhóm đã thay đổi" : "\(source) đổi ảnh đại diện nhóm"
        case "add_admin":
            guard !names.isEmpty else { return nil }
            return "\(names) đã được bổ nhiệm thành phó nhóm"
        case "remove_admin":
            guard !names.isEmpty else { return nil }
            return "\(names) đã không còn là phó nhóm"
        case "change_owner":
            guard let first = members.first else { return nil }
            return isMe(first.id) ? "Bạn trở thành trưởng nhóm." : "\(first.name) trở thành trưởng nhóm."
        default:
            return nil
        }
    }

    static let groupEventNoticeActs: Set<String> = [
        "join", "leave", "remove_member", "block_member", "update", "update_avatar", "add_admin", "remove_admin", "change_owner"
    ]
}
