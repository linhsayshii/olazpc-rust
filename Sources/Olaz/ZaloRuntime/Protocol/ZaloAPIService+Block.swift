import Foundation

/// A blocked account (official blocked-friends list).
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

    /// Blocks (or unblocks) messages and calls from a user: `friend /api/friend/block` · `/api/friend/unblock`.
    func setBlockedAPI(uid: String, blocked: Bool) async throws {
        _ = try await post(
            service: "friend",
            path: blocked ? "/api/friend/block" : "/api/friend/unblock",
            encryptedPayload: Self.blockPayload(uid: uid, imei: imei)
        )
    }

    /// Every page of `friend /api/friend/blocklistv2` {page, count, avatar}.
    func fetchBlockedUsersAPI() async throws -> [BlockedUser] {
        var all: [BlockedUser] = []
        var page = 1
        while page <= 20 {
            let resp = try await get(
                service: "friend",
                path: "/api/friend/blocklistv2",
                encryptedPayload: ["page": page, "count": 50, "avatar": 75]
            )
            let parsed = BlockedUser.page(from: resp["data"] as? [String: Any] ?? [:])
            all.append(contentsOf: parsed.users)
            guard parsed.hasMore, !parsed.users.isEmpty else { break }
            page += 1
        }
        return all
    }
}
