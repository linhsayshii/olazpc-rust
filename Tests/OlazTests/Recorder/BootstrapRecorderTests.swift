import Foundation
import XCTest
@testable import Olaz

final class BootstrapRecorderTests: XCTestCase {
    func testBootstrapCases() async throws {
        try await MessageRecorderHarness.runDomainSuite(
            domain: "bootstrap",
            scenarios: Self.bootstrapScenarios()
        )
    }

    // MARK: - Scenarios

    private static func bootstrapScenarios() -> [MessageRecorderHarness.ScenarioDef] {
        [
            // 21. preload_ranks: clearUnreads rows: group by flag or known id, peers excluding self,
            // 0, g0 and the self group; max rank kept; activityRanks pref.
            MessageRecorderHarness.ScenarioDef(
                name: "preload_ranks",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000501",
                    displayName: "Boot User 1",
                    send2MeId: "92000501",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "activity_ranks": .object([
                            "3000001": .int(50),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000501", displayName: "Boot User 1", send2MeId: "92000501"),
                    MessageRecorderHarness.profileMeScript(uid: "2000501", displayName: "Boot User 1"),
                    MessageRecorderHarness.httpScript(
                        path: "/api/alias/list",
                        method: "GET",
                        json: .object(["error_code": .int(0), "data": .object(["items": .array([])])])
                    ),
                    MessageRecorderHarness.httpScript(
                        path: "/",
                        method: "GET",
                        json: .object(["error_code": .int(0), "data": .object(["more": .int(0)])])
                    ),
                    MessageRecorderHarness.httpScript(
                        path: "/api/pinconvers/list",
                        method: "GET",
                        json: .object(["error_code": .int(0), "data": .array([])])
                    ),
                    MessageRecorderHarness.httpScript(
                        path: "/api/archivedchat/list",
                        method: "GET",
                        json: .object(["error_code": .int(0), "data": .object(["items": .array([]), "version": .int(1)])])
                    ),
                    MessageRecorderHarness.httpScript(
                        path: "/api/social/profile/getmute",
                        method: "GET",
                        json: .object(["error_code": .int(0), "data": .object(["chatEntries": .array([]), "groupChatEntries": .array([])])])
                    ),
                    MessageRecorderHarness.httpScript(
                        path: "/api/convlabel/get",
                        method: "GET",
                        json: .object(["error_code": .int(0), "data": .object(["labelData": .string("[]"), "version": .int(1)])])
                    ),
                    MessageRecorderHarness.httpScript(
                        path: "/api/hiddenconvers/get-all",
                        method: "GET",
                        json: .object(["error_code": .int(0), "data": .object(["threads": .array([]), "pin": .string("")])])
                    ),
                    MessageRecorderHarness.httpScript(
                        path: "/api/social/friend/getfriends",
                        method: "GET",
                        json: .object(["error_code": .int(0), "data": .array([])])
                    ),
                    MessageRecorderHarness.httpScript(
                        path: "/api/group/getlg/v4",
                        method: "GET",
                        json: .object(["error_code": .int(0), "data": .object(["gridVerMap": .object(["500001": .int(1)]), "removedsGroup": .array([])])])
                    ),
                    MessageRecorderHarness.httpScript(
                        path: "/api/group/getmg-v2",
                        method: "POST",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "gridInfoMap": .object([
                                    "500001": .object([
                                        "grid": .string("500001"),
                                        "name": .string("Known Group"),
                                        "avt": .string("https://cdn.example.invalid/g1.jpg"),
                                        "totalMember": .int(5),
                                    ]),
                                ]),
                            ]),
                        ])
                    ),
                    MessageRecorderHarness.httpScript(
                        path: "/api/friend/requested/list",
                        method: "GET",
                        json: .object(["error_code": .int(0), "data": .array([])])
                    ),
                    MessageRecorderHarness.httpScript(
                        path: "/api/friend/recommendsv2/list",
                        method: "GET",
                        json: .object(["error_code": .int(0), "data": .object(["recommItems": .array([])])])
                    ),
                    // Preload overview with clearUnreads covering all filter/rank rules:
                    MessageRecorderHarness.httpScript(
                        path: "/api/preloadconvers/get-last-msgs",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "clearUnreads": .array([
                                    // Existing seeded rank 50 vs incoming 30 -> keep max 50
                                    .object(["idTo": .string("3000001"), "lastMsgId": .int(30)]),
                                    // Peer 3000002 appears twice -> keep max 90
                                    .object(["idTo": .string(" 3000002 "), "lastMsgId": .int(70)]),
                                    .object(["threadId": .string("3000002"), "lastMsgId": .int(90)]),
                                    // Exclusions: self uid, "0", "g0", self group, non-positive rank
                                    .object(["idTo": .string("2000501"), "lastMsgId": .int(99)]),
                                    .object(["idTo": .string("0"), "lastMsgId": .int(88)]),
                                    .object(["idTo": .string("g0"), "isGroup": .int(1), "lastMsgId": .int(77)]),
                                    .object(["idTo": .string("92000501"), "isGroup": .int(1), "lastMsgId": .int(66)]),
                                    .object(["idTo": .string("3000003"), "lastMsgId": .int(0)]),
                                    // Group by explicit flag
                                    .object(["idTo": .string("500002"), "isGroup": .int(1), "lastMsgId": .int(120)]),
                                    // Group by known id (no isGroup flag, known in contacts.groups)
                                    .object(["uid": .string("500001"), "lastMsgId": .int(110)]),
                                ]),
                            ]),
                        ])
                    ),
                    // Preload chunk for [3000002, 3000001, g500001]:
                    MessageRecorderHarness.httpScript(
                        path: "/api/preloadconvers/get-last-msgs",
                        method: "GET",
                        json: .object(["error_code": .int(0), "data": .object(["msgs": .object([:])])])
                    ),
                    // Self cloud history:
                    MessageRecorderHarness.httpScript(
                        path: "/api/cm/getrecentv2",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "groupMsgs": .array([]),
                                "isOld": .int(0),
                                "hasMore": .int(0),
                                "lastMsgId": .string("0"),
                            ]),
                        ])
                    ),
                    // Resolve missing conversation names for peers added from preload clearUnreads:
                    MessageRecorderHarness.httpScript(
                        path: "/api/social/group/members",
                        method: "POST",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "profiles": .object([
                                    "3000001": .object([
                                        "id": .string("3000001"),
                                        "displayName": .string("Peer 1"),
                                        "avatar": .string("https://cdn.example.invalid/p1.jpg"),
                                    ]),
                                    "3000002": .object([
                                        "id": .string("3000002"),
                                        "displayName": .string("Peer 2"),
                                        "avatar": .string("https://cdn.example.invalid/p2.jpg"),
                                    ]),
                                ]),
                            ]),
                        ])
                    ),
                    // Known group history (g500001):
                    MessageRecorderHarness.httpScript(
                        path: "/api/cm/getrecentv2",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "groupMsgs": .array([]),
                                "isOld": .int(0),
                                "hasMore": .int(0),
                                "lastMsgId": .string("0"),
                            ]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("bootstrap"), "now_ms": .int(1700000100000)]),
                ]
            ),
        ]
    }
}
