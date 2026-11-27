import Foundation
import OlazCore

// Group controls (cmd 601, `act_type:"group"`) the official client turns into info lines in the chat
// (`_processGroupCtrlEvents_old` → `addGroupEventMessages`): delegated to `olaz-wire::group_event_notice`.
extension ZaloWireParser {
    /// The official info line for a group control, or nil when the act shows none.
    /// `data`: {groupId, sourceId, creatorId?, groupName?, updateMembers:[{id, dName}]}; `name` resolves a contact name.
    static func groupEventNotice(
        act: String, data: [String: Any], myUid: String, name: (String) -> String?
    ) -> String? {
        guard JSONSerialization.isValidJSONObject(data),
              let raw = try? JSONSerialization.data(withJSONObject: data),
              let dataJson = String(data: raw, encoding: .utf8) else {
            return nil
        }
        var seen = Set<String>()
        var resolved: [StringPairEntry] = []
        func record(_ rawUid: Any?) {
            let uid = stripUserPrefix(JSONLossless.string(rawUid))
            guard !uid.isEmpty, seen.insert(uid).inserted else { return }
            if let display = name(uid), !display.isEmpty {
                resolved.append(StringPairEntry(key: uid, value: display))
            }
        }
        record(data["sourceId"])
        for member in (data["updateMembers"] as? [[String: Any]]) ?? [] {
            record(member["id"])
        }
        return groupEventNoticeFfi(act: act, dataJson: dataJson, myUid: myUid, resolvedNames: resolved)
    }

    static let groupEventNoticeActs: Set<String> = [
        "join", "leave", "remove_member", "block_member", "update", "update_avatar", "add_admin", "remove_admin", "change_owner"
    ]
}
