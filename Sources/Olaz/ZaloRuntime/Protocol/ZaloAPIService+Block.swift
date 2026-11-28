import Foundation

/// A blocked account (official blocked-friends list), mirrored from `olaz-core` (U9).
struct BlockedUser: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var avatar: URL?

    /// One `/api/friend/blocklistv2` page: {profiles:[{userId, displayName, zaloName, avatar}], has_more, version}.
    static func page(from data: [String: Any]) -> (users: [BlockedUser], hasMore: Bool) {
        let rows = (data["profiles"] as? [[String: Any]]) ?? []
        let users = rows.compactMap { row -> BlockedUser? in
            let id = ZaloWireParser.stripUserPrefix(JSONLossless.string(row["userId"] ?? row["uid"]))
            guard !id.isEmpty, id != "0" else { return nil }
            let name = [row["displayName"], row["zaloName"]].map { JSONLossless.string($0) }.first { !$0.isEmpty } ?? ""
            let avatar = JSONLossless.string(row["avatar"])
            return BlockedUser(id: id, name: name, avatar: avatar.isEmpty ? nil : URL(string: avatar))
        }
        let more = JSONLossless.int64(data["has_more"]) == 1 || (data["has_more"] as? Bool) == true
        return (users, more)
    }
}

extension ZaloSessionClient {
    /// Official `setBlockFriend`: {fid, imei}.
    nonisolated static func blockPayload(uid: String, imei: String) -> [String: Any] {
        ["fid": ZaloWireParser.stripUserPrefix(uid), "imei": imei]
    }
}
