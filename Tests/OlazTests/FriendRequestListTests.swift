import Foundation
import Testing
@testable import Olaz

struct FriendRequestListTests {
    @Test func keepsOnlyFriendRequestsNewestFirst() throws {
        let json = #"""
        {"recommItems":[
          {"dataInfo":{"userId":"111","displayName":"A","avatar":"a.jpg","recommType":1,"recommTime":5}},
          {"dataInfo":{"userId":"222","displayName":"B","zaloName":"b","avatar":"b.jpg","recommType":2,
                       "recommTime":100,"recommInfo":{"message":"Xin chào","source":3}}},
          {"dataInfo":{"userId":"8000000000000000001","displayName":"C","recommType":2,"recommTime":300}},
          {"noData":true}
        ]}
        """#
        let data = try #require(JSONLossless.parseObject(string: json))
        let rows = ZaloSessionClient.receivedFriendRequestRows(data)
        #expect(rows.map { JSONLossless.string($0["userId"]) } == ["8000000000000000001", "222"])
        #expect(JSONLossless.string(rows[1]["message"]) == "Xin chào")
        #expect(JSONLossless.int64(rows[1]["time"]) == 100)
        #expect(JSONLossless.string(rows[0]["message"]) == "")
    }

    @Test func missingItemsGiveEmptyList() {
        #expect(ZaloSessionClient.receivedFriendRequestRows(nil).isEmpty)
        #expect(ZaloSessionClient.receivedFriendRequestRows(["recommItems": "x"]).isEmpty)
    }
}
