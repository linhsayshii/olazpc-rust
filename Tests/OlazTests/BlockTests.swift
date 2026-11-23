import Foundation
import Testing
@testable import Olaz

/// Blocked accounts (official `getBlockFriends` → `/api/friend/blocklistv2`, `setBlockFriend` → `/api/friend/(un)block`).
@Suite("Blocked accounts")
struct BlockTests {
    @Test func blockListPage() throws {
        let raw = #"{"profiles":[{"userId":"7401234567890123456","displayName":"Lan","zaloName":"Lan Nguyễn","avatar":"https://s120-ava-talk.zadn.vn/a.jpg","isFr":1},{"userId":"","displayName":"x"},{"userId":"200","zaloName":"Minh","avatar":""}],"has_more":1,"version":3}"#
        let data = try #require(JSONLossless.parseObject(Data(raw.utf8)))
        let page = BlockedUser.page(from: data)
        #expect(page.hasMore)
        #expect(page.users.map(\.id) == ["7401234567890123456", "200"])
        #expect(page.users[0].name == "Lan" && page.users[0].avatar?.host == "s120-ava-talk.zadn.vn")
        #expect(page.users[1].name == "Minh" && page.users[1].avatar == nil)
        #expect(BlockedUser.page(from: ["profiles": []]).hasMore == false)
    }

    @Test func blockPayload() {
        #expect(ZaloSessionClient.blockPayload(uid: "200", imei: "i") as NSDictionary == ["fid": "200", "imei": "i"] as NSDictionary)
    }
}
