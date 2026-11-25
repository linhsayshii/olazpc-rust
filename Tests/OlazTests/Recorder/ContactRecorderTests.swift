import Foundation
import XCTest
@testable import Olaz

final class ContactRecorderTests: XCTestCase {
    func testContactScenarios() async throws {
        try await ContactRecorderHarness.runDomain(
            domain: "contacts",
            scenarios: Self.contactScenarios()
        )
    }

    // MARK: - Helpers

    private static func emptySyncScripts(
        friends: [CaseJSON]? = nil,
        friendsError: Int? = nil,
        groupsVerMap: [String: CaseJSON]? = nil,
        removedGroups: [String] = [],
        groupsInfoMap: [String: CaseJSON]? = nil,
        groupsListError: Int? = nil,
        sentRows: [CaseJSON]? = nil,
        sentError: Int? = nil,
        recommItems: [CaseJSON]? = nil,
        receivedError: Int? = nil
    ) -> [CaseJSON] {
        var scripts: [CaseJSON] = []
        if let err = friendsError {
            scripts.append(ContactRecorderHarness.httpScript(
                path: "/api/social/friend/getfriends",
                method: "GET",
                status: err,
                json: .object(["error_code": .int(Int64(err)), "error_message": .string("Sync friends error")])
            ))
        } else {
            scripts.append(ContactRecorderHarness.httpScript(
                path: "/api/social/friend/getfriends",
                method: "GET",
                json: .object([
                    "error_code": .int(0),
                    "data": .object(["list": .array(friends ?? [])]),
                ])
            ))
        }

        if let err = groupsListError {
            scripts.append(ContactRecorderHarness.httpScript(
                path: "/api/group/getlg/v4",
                method: "GET",
                status: err,
                json: .object(["error_code": .int(Int64(err)), "error_message": .string("Sync groups error")])
            ))
        } else {
            let verMap = groupsVerMap ?? [:]
            var dataObj: [String: CaseJSON] = ["gridVerMap": .object(verMap)]
            if !removedGroups.isEmpty {
                dataObj["removedsGroup"] = .array(removedGroups.map(CaseJSON.string))
            }
            scripts.append(ContactRecorderHarness.httpScript(
                path: "/api/group/getlg/v4",
                method: "GET",
                json: .object(["error_code": .int(0), "data": .object(dataObj)])
            ))
            let activeIds = verMap.keys.filter { !removedGroups.contains($0) }
            if !activeIds.isEmpty {
                scripts.append(ContactRecorderHarness.httpScript(
                    path: "/api/group/getmg-v2",
                    method: "POST",
                    json: .object([
                        "error_code": .int(0),
                        "data": .object(["gridInfoMap": .object(groupsInfoMap ?? [:])]),
                    ])
                ))
            }
        }

        if let err = sentError {
            scripts.append(ContactRecorderHarness.httpScript(
                path: "/api/friend/requested/list",
                method: "GET",
                status: err,
                json: .object(["error_code": .int(Int64(err)), "error_message": .string("Sync sent error")])
            ))
        } else {
            scripts.append(ContactRecorderHarness.httpScript(
                path: "/api/friend/requested/list",
                method: "GET",
                json: .object([
                    "error_code": .int(0),
                    "data": .object(["list": .array(sentRows ?? [])]),
                ])
            ))
        }

        if let err = receivedError {
            scripts.append(ContactRecorderHarness.httpScript(
                path: "/api/friend/recommendsv2/list",
                method: "GET",
                status: err,
                json: .object(["error_code": .int(Int64(err)), "error_message": .string("Sync received error")])
            ))
        } else {
            scripts.append(ContactRecorderHarness.httpScript(
                path: "/api/friend/recommendsv2/list",
                method: "GET",
                json: .object([
                    "error_code": .int(0),
                    "data": .object(["recommItems": .array(recommItems ?? [])]),
                ])
            ))
        }
        return scripts
    }

    private static func localConv(
        id: String,
        isGroup: Bool = false,
        name: String,
        avatar: String = "",
        members: Int64 = 0,
        unread: Int64 = 0,
        previewText: String = "",
        previewTsMs: Int64 = 0,
        previewFromMe: Bool = false
    ) -> CaseJSON {
        .object([
            "id": .string(id),
            "is_group": .bool(isGroup),
            "name": .string(name),
            "avatar": .string(avatar),
            "pinned": .bool(false),
            "members": .int(members),
            "unread": .int(unread),
            "preview_text": .string(previewText),
            "preview_ts_ms": .int(previewTsMs),
            "preview_from_me": .bool(previewFromMe),
        ])
    }

    private static func contactScenarios() -> [ContactRecorderHarness.ScenarioDef] {
        [
            // 1. sync_full
            ContactRecorderHarness.ScenarioDef(
                name: "sync_full",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000901",
                    displayName: "Contacts User 1",
                    suppress: ["ws", "long_poll"]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000901", displayName: "Contacts User 1"),
                    MessageRecorderHarness.profileMeScript(uid: "2000901", displayName: "Contacts User 1"),
                ] + emptySyncScripts(
                    friends: [
                        .object([
                            "userId": .string("u3000901"),
                            "zaloName": .string("Đào Anh"),
                            "displayName": .string("Phone Đào"),
                            "avatar": .string("https://cdn.example.invalid/f1.jpg"),
                            "lastActionTime": .int(1700000001000),
                            "isActivePC": .int(1),
                            "globalId": .string("gid_3000901"),
                        ]),
                        .object([
                            "uid": .string("3000902"),
                            "displayName": .string("Ánh Tuyết"),
                            "zaloName": .string(""),
                            "avt": .string("https://cdn.example.invalid/f2.jpg"),
                            "lastActionTime": .int(0),
                            "online": .bool(true),
                            "globalId": .string("gid_3000902"),
                        ]),
                        .object([
                            "id": .string("3000903"),
                            "zaloName": .string("Dương Bình"),
                            "displayName": .string(""),
                            "avatar": .string(""),
                            "isActivePC": .int(0),
                        ]),
                        .object([
                            "userId": .string("3000904"),
                            "zaloName": .string("99Shop"),
                            "displayName": .string(""),
                            "avatar": .string(""),
                        ]),
                        .object([
                            "userId": .string("3000905"),
                            "zaloName": .string("🎉 Party"),
                            "avatar": .string(""),
                        ]),
                        .object([
                            "userId": .string("3000906"),
                            "zaloName": .string(""),
                            "displayName": .string(""),
                            "avatar": .string(""),
                        ]),
                    ],
                    groupsVerMap: [
                        "500901": .int(1),
                        "g500902": .int(1),
                        "group_500903": .int(1),
                        "500904": .int(1),
                        "500905": .int(1),
                        "500999": .int(1),
                    ],
                    removedGroups: ["500999"],
                    groupsInfoMap: [
                        "500901": .object([
                            "name": .string("Nhóm Đỏ"),
                            "avt": .string("https://cdn.example.invalid/g1.jpg"),
                            "totalMember": .int(12),
                        ]),
                        "g500902": .object([
                            "name": .string("Nhóm Áo"),
                            "fullAvt": .string("https://cdn.example.invalid/g2.jpg"),
                            "total": .int(8),
                        ]),
                        "group_500903": .object([
                            "name": .string("Nhóm Bầu"),
                            "memVerList": .array([.string("1"), .string("2"), .string("3")]),
                        ]),
                        "500904": .object([
                            "name": .string("Nhóm Cúc"),
                            "memIds": .array([.string("1"), .string("2")]),
                        ]),
                        "500905": .object([
                            "name": .string("Nhóm Dừa"),
                        ]),
                    ],
                    sentRows: [
                        .object([
                            "toUid": .string("u3000911"),
                            "displayName": .string("Sent One"),
                            "avt": .string("https://cdn.example.invalid/s1.jpg"),
                            "msg": .string("Xin chào 1"),
                            "ts": .int(1700000005000),
                        ]),
                        .object([
                            "uid": .string("3000912"),
                            "zaloName": .string("Sent Two"),
                            "avatar": .string(""),
                            "message": .string("Xin chào 2"),
                            "time": .int(0),
                        ]),
                    ],
                    recommItems: [
                        .object([
                            "dataInfo": .object([
                                "recommType": .int(1),
                                "userId": .string("3000999"),
                                "displayName": .string("Ignored Suggestion"),
                                "recommTime": .int(1700000009000),
                            ]),
                        ]),
                        .object([
                            "dataInfo": .object([
                                "recommType": .int(2),
                                "userId": .string("3000913"),
                                "displayName": .string("Rec Older"),
                                "avatar": .string("https://cdn.example.invalid/r1.jpg"),
                                "recommInfo": .object(["message": .string("Kết bạn nhé")]),
                                "friendRequestFetchTime": .int(1700000003000),
                            ]),
                        ]),
                        .object([
                            "dataInfo": .object([
                                "recommType": .int(2),
                                "uid": .string("u3000914"),
                                "zaloName": .string("Rec Newer"),
                                "avt": .string("https://cdn.example.invalid/r2.jpg"),
                                "message": .string("Mình là Rec"),
                                "recommTime": .int(1700000007000),
                            ]),
                        ]),
                    ]
                ),
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("contacts_sync")]),
                ]
            ),

            // 2. sync_partial_failures
            ContactRecorderHarness.ScenarioDef(
                name: "sync_partial_failures",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000902",
                    displayName: "Contacts User 2",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "contacts": .object([
                            "friends_loaded": .bool(true),
                            "groups_loaded": .bool(true),
                            "friends": .array([
                                .object([
                                    "id": .string("3000920"),
                                    "name": .string("Seed Friend"),
                                    "zalo_name": .string("Seed Friend"),
                                    "section": .string("S"),
                                    "sort_key": .string("seed friend"),
                                ]),
                            ]),
                            "groups": .array([
                                .object([
                                    "id": .string("g500920"),
                                    "name": .string("Seed Group"),
                                    "members": .int(4),
                                    "sort_key": .string("seed group"),
                                ]),
                            ]),
                            "received": .array([
                                .object(["id": .string("3000921"), "name": .string("Seed Rec"), "message": .string("Hi")]),
                            ]),
                            "sent": .array([
                                .object(["id": .string("3000922"), "name": .string("Seed Sent"), "message": .string("Yo")]),
                            ]),
                            "pending_request_count": .int(1),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000902", displayName: "Contacts User 2"),
                    MessageRecorderHarness.profileMeScript(uid: "2000902", displayName: "Contacts User 2"),
                ]
                + emptySyncScripts(
                    friendsError: 500,
                    groupsVerMap: ["500921": .int(1)],
                    groupsInfoMap: ["500921": .object(["name": .string("Group Step 1"), "totalMember": .int(5)])],
                    sentRows: [.object(["userId": .string("3000923"), "zaloName": .string("Sent Step 1"), "message": .string("S1"), "time": .int(1700000010000)])],
                    recommItems: [.object(["dataInfo": .object(["recommType": .int(2), "userId": .string("3000924"), "zaloName": .string("Rec Step 1"), "message": .string("R1"), "recommTime": .int(1700000011000)])])]
                )
                + emptySyncScripts(
                    friends: [.object(["userId": .string("3000925"), "zaloName": .string("Friend Step 2")])],
                    groupsListError: 500,
                    sentRows: [.object(["userId": .string("3000926"), "zaloName": .string("Sent Step 2"), "message": .string("S2"), "time": .int(1700000012000)])],
                    recommItems: [.object(["dataInfo": .object(["recommType": .int(2), "userId": .string("3000927"), "zaloName": .string("Rec Step 2"), "message": .string("R2"), "recommTime": .int(1700000013000)])])]
                )
                + emptySyncScripts(
                    friends: [.object(["userId": .string("3000928"), "zaloName": .string("Friend Step 3")])],
                    groupsVerMap: ["500922": .int(1)],
                    groupsInfoMap: ["500922": .object(["name": .string("Group Step 3"), "totalMember": .int(6)])],
                    sentError: 500,
                    recommItems: [.object(["dataInfo": .object(["recommType": .int(2), "userId": .string("3000929"), "zaloName": .string("Rec Step 3"), "message": .string("R3"), "recommTime": .int(1700000014000)])])]
                )
                + emptySyncScripts(
                    friends: [.object(["userId": .string("3000930"), "zaloName": .string("Friend Step 4")])],
                    groupsVerMap: ["500923": .int(1)],
                    groupsInfoMap: ["500923": .object(["name": .string("Group Step 4"), "totalMember": .int(7)])],
                    sentRows: [.object(["userId": .string("3000931"), "zaloName": .string("Sent Step 4"), "message": .string("S4"), "time": .int(1700000015000)])],
                    receivedError: 500
                ),
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("contacts_sync")]),
                    .object(["snapshot": .string("friends_failed")]),
                    .object(["cmd": .string("contacts_sync")]),
                    .object(["snapshot": .string("groups_failed")]),
                    .object(["cmd": .string("contacts_sync")]),
                    .object(["snapshot": .string("sent_failed")]),
                    .object(["cmd": .string("contacts_sync")]),
                ]
            ),

            // 3. sync_followups
            ContactRecorderHarness.ScenarioDef(
                name: "sync_followups",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000903",
                    displayName: "Contacts User 3",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "open_conversation_id": .string("3000901"),
                        "history_freshness": .object(["3000901": .string("up_to_date")]),
                        "contacts": .object([
                            "cached_profiles": .object([
                                "3000901": .object(["name": .string("Old Alice"), "avatar": .string("")]),
                            ]),
                        ]),
                        "pinned_ids": .array([.string("3000901")]),
                        "activity_ranks": .object(["3000902": .int(100)]),
                        "local_conversations": .array([
                            localConv(
                                id: "3000901",
                                name: "Old Alice",
                                unread: 0,
                                previewText: "Hello",
                                previewTsMs: 1700000001000
                            ),
                            localConv(
                                id: "3000999",
                                name: "Stranger X",
                                unread: 2,
                                previewText: "Ping",
                                previewTsMs: 1700000002000,
                                previewFromMe: false
                            ),
                        ]),
                        "local_messages": .array([
                            .object([
                                "id": .string("9100001"),
                                "conv_id": .string("3000901"),
                                "client_id": .string("c9100001"),
                                "sender_id": .string("3000901"),
                                "sender_name": .string("Old Alice"),
                                "is_mine": .bool(false),
                                "text": .string("Hello"),
                                "ts_ms": .int(1700000001000),
                                "reactions": .array([
                                    .object([
                                        "emoji": .string("❤️"),
                                        "key": .string("/-heart"),
                                        "type": .string("5"),
                                        "count": .int(2),
                                        "includesMe": .bool(true),
                                        "names": .array([]),
                                        "people": .int(2),
                                        "userCounts": .object([
                                            "2000903": .int(1),
                                            "3000902": .int(1),
                                        ]),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000903", displayName: "Contacts User 3"),
                    MessageRecorderHarness.profileMeScript(uid: "2000903", displayName: "Contacts User 3"),
                    ContactRecorderHarness.httpScript(
                        path: "/api/social/group/members",
                        method: "POST",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "changed_profiles": .object([
                                    "3000901": .object([
                                        "userId": .string("3000901"),
                                        "displayName": .string("Old Alice"),
                                        "zaloName": .string("Old Alice"),
                                        "avatar": .string(""),
                                    ]),
                                ]),
                            ]),
                        ])
                    ),
                ] + emptySyncScripts(
                    friends: [
                        .object([
                            "userId": .string("3000901"),
                            "zaloName": .string("New Alice"),
                            "avatar": .string("https://cdn.example.invalid/alice_new.jpg"),
                        ]),
                        .object([
                            "userId": .string("3000902"),
                            "zaloName": .string("New Bob"),
                            "avatar": .string("https://cdn.example.invalid/bob_new.jpg"),
                        ]),
                    ],
                    groupsVerMap: ["500930": .int(1)],
                    groupsInfoMap: [
                        "500930": .object([
                            "name": .string("Followup Group"),
                            "avt": .string("https://cdn.example.invalid/grp_new.jpg"),
                            "totalMember": .int(9),
                        ]),
                    ]
                ),
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000901")])]),
                    .object(["snapshot": .string("before_sync")]),
                    .object(["cmd": .string("contacts_sync")]),
                ]
            ),

            // 4. sync_global_ids
            ContactRecorderHarness.ScenarioDef(
                name: "sync_global_ids",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000904",
                    displayName: "Contacts User 4",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "contacts": .object([
                            "friend_global_ids": .object(["3000900": .string("gid_old_3000900")]),
                            "cached_profiles": .object([
                                "3000900": .object(["name": .string("Pre Existing"), "avatar": .string("")]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000904", displayName: "Contacts User 4"),
                    MessageRecorderHarness.profileMeScript(uid: "2000904", displayName: "Contacts User 4"),
                ] + emptySyncScripts(
                    friends: [
                        .object([
                            "userId": .string("3000900"),
                            "zaloName": .string("Updated Global Zero"),
                            "globalId": .string("gid_new_3000900"),
                        ]),
                        .object([
                            "userId": .string("3000901"),
                            "zaloName": .string("Global Friend One"),
                            "avatar": .string("https://cdn.example.invalid/gfriend1.jpg"),
                            "globalId": .string("gid_3000901"),
                        ]),
                    ]
                ),
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("contacts_sync")]),
                    .object(["snapshot": .string("after_sync")]),
                    .object(["cmd": .string("lookup"), "args": .object(["uid": .string("gid_3000901")])]),
                    .object(["cmd": .string("lookup"), "args": .object(["uid": .string("gid_new_3000900")])]),
                    .object(["cmd": .string("lookup"), "args": .object(["uid": .string("gid_old_3000900")])]),
                ]
            ),

            // 5. request_accept
            ContactRecorderHarness.ScenarioDef(
                name: "request_accept",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000905",
                    displayName: "Contacts User 5",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "contacts": .object([
                            "received": .array([
                                .object([
                                    "id": .string("3000913"),
                                    "name": .string("Rec Older"),
                                    "avatar": .string("https://cdn.example.invalid/r1.jpg"),
                                    "message": .string("Kết bạn nhé"),
                                    "date_ms": .int(1700000003000),
                                ]),
                                .object([
                                    "id": .string("3000914"),
                                    "name": .string("Rec Newer"),
                                    "message": .string("Xin chào"),
                                    "date_ms": .int(1700000007000),
                                ]),
                            ]),
                            "pending_request_count": .int(2),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000905", displayName: "Contacts User 5"),
                    MessageRecorderHarness.profileMeScript(uid: "2000905", displayName: "Contacts User 5"),
                    ContactRecorderHarness.httpScript(
                        path: "/api/friend/accept",
                        method: "POST",
                        status: 500,
                        json: .object(["error_code": .int(500), "error_message": .string("Accept error")])
                    ),
                    ContactRecorderHarness.httpScript(
                        path: "/api/friend/accept",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                ] + emptySyncScripts(
                    friends: [
                        .object([
                            "userId": .string("3000913"),
                            "zaloName": .string("Rec Older"),
                            "avatar": .string("https://cdn.example.invalid/r1.jpg"),
                        ]),
                    ],
                    recommItems: [
                        .object([
                            "dataInfo": .object([
                                "recommType": .int(2),
                                "userId": .string("3000914"),
                                "zaloName": .string("Rec Newer"),
                                "message": .string("Xin chào"),
                                "recommTime": .int(1700000007000),
                            ]),
                        ]),
                    ]
                ),
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("accept_request"), "args": .object(["id": .string("3000913")])]),
                    .object(["snapshot": .string("after_fail")]),
                    .object(["cmd": .string("accept_request"), "args": .object(["id": .string("3000913")])]),
                ]
            ),

            // 6. request_decline
            ContactRecorderHarness.ScenarioDef(
                name: "request_decline",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000906",
                    displayName: "Contacts User 6",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "contacts": .object([
                            "received": .array([
                                .object([
                                    "id": .string("3000913"),
                                    "name": .string("Rec Older"),
                                    "message": .string("Kết bạn nhé"),
                                    "date_ms": .int(1700000003000),
                                ]),
                                .object([
                                    "id": .string("3000914"),
                                    "name": .string("Rec Newer"),
                                    "message": .string("Xin chào"),
                                    "date_ms": .int(1700000007000),
                                ]),
                            ]),
                            "pending_request_count": .int(2),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000906", displayName: "Contacts User 6"),
                    MessageRecorderHarness.profileMeScript(uid: "2000906", displayName: "Contacts User 6"),
                    ContactRecorderHarness.httpScript(
                        path: "/api/friend/reject",
                        method: "POST",
                        status: 500,
                        json: .object(["error_code": .int(500), "error_message": .string("Reject error")])
                    ),
                    ContactRecorderHarness.httpScript(
                        path: "/api/friend/reject",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("decline_request"), "args": .object(["id": .string("3000913")])]),
                    .object(["snapshot": .string("after_fail")]),
                    .object(["cmd": .string("decline_request"), "args": .object(["id": .string("3000913")])]),
                ]
            ),

            // 7. request_cancel
            ContactRecorderHarness.ScenarioDef(
                name: "request_cancel",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000907",
                    displayName: "Contacts User 7",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "contacts": .object([
                            "sent": .array([
                                .object([
                                    "id": .string("3000911"),
                                    "name": .string("Sent One"),
                                    "message": .string("Xin chào 1"),
                                    "date_ms": .int(1700000005000),
                                ]),
                                .object([
                                    "id": .string("3000912"),
                                    "name": .string("Sent Two"),
                                    "message": .string("Xin chào 2"),
                                    "date_ms": .int(1700000006000),
                                ]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000907", displayName: "Contacts User 7"),
                    MessageRecorderHarness.profileMeScript(uid: "2000907", displayName: "Contacts User 7"),
                    ContactRecorderHarness.httpScript(
                        path: "/api/friend/undo",
                        method: "POST",
                        status: 500,
                        json: .object(["error_code": .int(500), "error_message": .string("Cancel error")])
                    ),
                    ContactRecorderHarness.httpScript(
                        path: "/api/friend/undo",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("cancel_request"), "args": .object(["id": .string("3000911")])]),
                    .object(["snapshot": .string("after_fail")]),
                    .object(["cmd": .string("cancel_request"), "args": .object(["id": .string("3000911")])]),
                ]
            ),

            // 8. request_send
            ContactRecorderHarness.ScenarioDef(
                name: "request_send",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000908",
                    displayName: "Contacts User 8",
                    suppress: ["ws", "long_poll"]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000908", displayName: "Contacts User 8"),
                    MessageRecorderHarness.profileMeScript(uid: "2000908", displayName: "Contacts User 8"),
                    ContactRecorderHarness.httpScript(
                        path: "/api/friend/sendreq",
                        method: "POST",
                        status: 500,
                        json: .object(["error_code": .int(500), "error_message": .string("Send error")])
                    ),
                    ContactRecorderHarness.httpScript(
                        path: "/api/friend/sendreq",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                ] + emptySyncScripts(
                    sentRows: [
                        .object([
                            "toUid": .string("3000915"),
                            "zaloName": .string("Requested User"),
                            "msg": .string("Xin chào 915"),
                            "ts": .int(1700000018000),
                        ]),
                    ]
                ),
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("send_request"), "args": .object(["id": .string("3000915"), "message": .string("Xin chào 915")])]),
                    .object(["snapshot": .string("after_fail")]),
                    .object(["cmd": .string("send_request"), "args": .object(["id": .string("3000915"), "message": .string("Xin chào 915")])]),
                ]
            ),

            // 9. find_phone
            ContactRecorderHarness.ScenarioDef(
                name: "find_phone",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000909",
                    displayName: "Contacts User 9",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "contacts": .object([
                            "friends": .array([
                                .object([
                                    "id": .string("3000941"),
                                    "name": .string("Friend One"),
                                    "zalo_name": .string("Friend One"),
                                ]),
                            ]),
                            "sent": .array([
                                .object([
                                    "id": .string("3000942"),
                                    "name": .string("Sent Target"),
                                    "message": .string("Hi"),
                                ]),
                            ]),
                            "received": .array([
                                .object([
                                    "id": .string("3000943"),
                                    "name": .string("Recv Target"),
                                    "message": .string("Hello"),
                                ]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000909", displayName: "Contacts User 9"),
                    MessageRecorderHarness.profileMeScript(uid: "2000909", displayName: "Contacts User 9"),
                    // 1. stranger (held so we can snapshot searching)
                    ContactRecorderHarness.httpScript(
                        path: "/api/friend/profile/get",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "uid": .string("u3000940"),
                                "display_name": .string("Stranger Found"),
                                "zalo_name": .string("Stranger Zalo"),
                                "avatar": .string("https://cdn.example.invalid/s940.jpg"),
                                "status": .string("Bio 940"),
                            ]),
                        ]),
                        hold: true
                    ),
                    // 2. friend
                    ContactRecorderHarness.httpScript(
                        path: "/api/friend/profile/get",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "userId": .string("3000941"),
                                "displayName": .string("Friend One"),
                                "zaloName": .string("Friend One"),
                            ]),
                        ])
                    ),
                    // 3. self
                    ContactRecorderHarness.httpScript(
                        path: "/api/friend/profile/get",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "uid": .string("2000909"),
                                "display_name": .string("Contacts User 9"),
                                "zalo_name": .string("Contacts User 9"),
                            ]),
                        ])
                    ),
                    // 4. requested (sent)
                    ContactRecorderHarness.httpScript(
                        path: "/api/friend/profile/get",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "uid": .string("3000942"),
                                "zalo_name": .string("Sent Target"),
                            ]),
                        ])
                    ),
                    // 5. requesting (received)
                    ContactRecorderHarness.httpScript(
                        path: "/api/friend/profile/get",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "uid": .string("3000943"),
                                "zalo_name": .string("Recv Target"),
                            ]),
                        ])
                    ),
                    // 6. not found (empty uid)
                    ContactRecorderHarness.httpScript(
                        path: "/api/friend/profile/get",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([:]),
                        ])
                    ),
                    // 7. request error
                    ContactRecorderHarness.httpScript(
                        path: "/api/friend/profile/get",
                        method: "GET",
                        status: 500,
                        json: .object([
                            "error_code": .int(500),
                            "error_message": .string("Phone lookup failed"),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("find_by_phone"), "args": .object(["phone": .string("   \t\n  ")])]),
                    .object(["snapshot": .string("blank_ignored")]),
                    .object(["cmd": .string("find_by_phone"), "args": .object(["phone": .string(" 0901234561 "), "async": .bool(true)])]),
                    .object(["snapshot": .string("searching")]),
                    .object(["http_release": .int(1)]),
                    .object(["cmd": .string("await_contacts")]),
                    .object(["snapshot": .string("found_stranger")]),
                    .object(["cmd": .string("reset_search")]),
                    .object(["snapshot": .string("after_reset")]),
                    .object(["cmd": .string("find_by_phone"), "args": .object(["phone": .string("0901234562")])]),
                    .object(["snapshot": .string("found_friend")]),
                    .object(["cmd": .string("find_by_phone"), "args": .object(["phone": .string("0901234563")])]),
                    .object(["snapshot": .string("found_self")]),
                    .object(["cmd": .string("find_by_phone"), "args": .object(["phone": .string("0901234564")])]),
                    .object(["snapshot": .string("found_sent")]),
                    .object(["cmd": .string("find_by_phone"), "args": .object(["phone": .string("0901234565")])]),
                    .object(["snapshot": .string("found_received")]),
                    .object(["cmd": .string("find_by_phone"), "args": .object(["phone": .string("0901234566")])]),
                    .object(["snapshot": .string("not_found")]),
                    .object(["cmd": .string("find_by_phone"), "args": .object(["phone": .string("0901234567")])]),
                ]
            ),

            // 10. contacts_state
            ContactRecorderHarness.ScenarioDef(
                name: "contacts_state",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000910",
                    displayName: "Contacts User 10",
                    suppress: ["ws", "long_poll"]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000910", displayName: "Contacts User 10"),
                    MessageRecorderHarness.profileMeScript(uid: "2000910", displayName: "Contacts User 10"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object([
                        "cmd": .string("contacts_state"),
                        "args": .object([
                            "json": .object([
                                "contacts": .object([
                                    "friends": .array([
                                        .object([
                                            "id": .string("3000951"),
                                            "name": .string("Adapter Friend"),
                                            "zaloName": .string("Adapter Friend"),
                                            "avatar": .string("https://cdn.example.invalid/af1.jpg"),
                                            "lastActive": .int(1700000001000),
                                            "online": .bool(true),
                                        ]),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                    .object(["snapshot": .string("friends_only")]),
                    .object([
                        "cmd": .string("contacts_state"),
                        "args": .object([
                            "json": .object([
                                "contacts": .object([
                                    "groups": .array([
                                        .object([
                                            "id": .string("g500951"),
                                            "name": .string("Adapter Group"),
                                            "avatar": .string("https://cdn.example.invalid/ag1.jpg"),
                                            "members": .int(15),
                                        ]),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                    .object(["snapshot": .string("groups_only")]),
                    .object([
                        "cmd": .string("contacts_state"),
                        "args": .object([
                            "json": .object([
                                "contacts": .object([
                                    "received": .array([
                                        .object([
                                            "id": .string("3000952"),
                                            "name": .string("Adapter Rec"),
                                            "message": .string("Hi"),
                                            "time": .int(1700000002000),
                                        ]),
                                    ]),
                                    "sent": .array([
                                        .object([
                                            "id": .string("3000953"),
                                            "name": .string("Adapter Sent"),
                                            "message": .string("Yo"),
                                            "time": .int(1700000003000),
                                        ]),
                                    ]),
                                    "pendingRequestCount": .int(-4),
                                    "loading": .object(["requests": .bool(true)]),
                                ]),
                            ]),
                        ]),
                    ]),
                    .object(["snapshot": .string("requests_clamped")]),
                    .object([
                        "cmd": .string("contacts_state"),
                        "args": .object([
                            "json": .object([
                                "contacts": .object([
                                    "search": .object([
                                        "status": .string("found"),
                                        "user": .object([
                                            "id": .string("3000954"),
                                            "name": .string("Search Hit"),
                                            "zaloName": .string("Search Hit"),
                                            "avatar": .string("https://cdn.example.invalid/sh1.jpg"),
                                            "bio": .string("Hello bio"),
                                            "isFriend": .bool(false),
                                            "isSelf": .bool(false),
                                            "requested": .bool(true),
                                            "requesting": .bool(false),
                                            "defaultMessage": .string("Xin chào"),
                                            "maxMessage": .int(150),
                                        ]),
                                    ]),
                                    "notice": .object([
                                        "seq": .int(4),
                                        "ok": .bool(true),
                                        "text": .string("Adapter notice"),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                    .object(["snapshot": .string("search_and_notice")]),
                    .object([
                        "cmd": .string("contacts_state"),
                        "args": .object([
                            "json": .object([
                                "contacts": .object([
                                    "friends": .array([
                                        .object([
                                            "id": .string("3000955"),
                                            "name": .string("Combined Friend"),
                                            "zaloName": .string("Combined Friend"),
                                        ]),
                                    ]),
                                    "groups": .array([
                                        .object([
                                            "id": .string("g500952"),
                                            "name": .string("Combined Group"),
                                            "members": .int(7),
                                        ]),
                                    ]),
                                    "received": .array([
                                        .object([
                                            "id": .string("3000956"),
                                            "name": .string("Combined Rec"),
                                            "message": .string("M1"),
                                        ]),
                                    ]),
                                    "sent": .array([
                                        .object([
                                            "id": .string("3000957"),
                                            "name": .string("Combined Sent"),
                                            "message": .string("M2"),
                                        ]),
                                    ]),
                                    "pendingRequestCount": .int(2),
                                    "loading": .object(["requests": .bool(false)]),
                                    "search": .object(["status": .string("error"), "error": .string("Search err")]),
                                    "notice": .object(["seq": .int(5), "ok": .bool(false), "text": .string("Combined err")]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]
            ),

            // 11. lookup_rules
            ContactRecorderHarness.ScenarioDef(
                name: "lookup_rules",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000911",
                    displayName: "Contacts User 11",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "contacts": .object([
                            "friends": .array([
                                .object([
                                    "id": .string("3000961"),
                                    "name": .string("Friend Name One"),
                                    "zalo_name": .string("Friend Name One"),
                                ]),
                                .object([
                                    "id": .string("3000962"),
                                    "name": .string("Friend With Avatar"),
                                    "zalo_name": .string("Friend With Avatar"),
                                    "avatar": .string("https://cdn.example.invalid/friend_avt.jpg"),
                                ]),
                            ]),
                            "aliases": .object([
                                "3000961": .string("Alias Over Friend"),
                                "3000964": .string("Alias Over Unknown"),
                            ]),
                            "cached_profiles": .object([
                                "3000961": .object([
                                    "name": .string("Profile Name One"),
                                    "avatar": .string("https://cdn.example.invalid/profile_avt1.jpg"),
                                ]),
                                "3000962": .object([
                                    "name": .string("Profile Name Two"),
                                    "avatar": .string("https://cdn.example.invalid/profile_avt2.jpg"),
                                ]),
                                "3000963": .object([
                                    "name": .string("Cached Profile Only"),
                                    "avatar": .string("https://cdn.example.invalid/profile_avt3.jpg"),
                                ]),
                                "3000964": .object([
                                    "name": .string("Người dùng Zalo"),
                                    "avatar": .string(""),
                                ]),
                                "3000965": .object([
                                    "name": .string("Người dùng Zalo"),
                                    "avatar": .string(""),
                                ]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000911", displayName: "Contacts User 11"),
                    MessageRecorderHarness.profileMeScript(uid: "2000911", displayName: "Contacts User 11"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("lookup"), "args": .object(["uid": .string("")])]),
                    .object(["cmd": .string("lookup"), "args": .object(["uid": .string("0")])]),
                    .object(["cmd": .string("lookup"), "args": .object(["uid": .string("-1")])]),
                    .object(["cmd": .string("lookup"), "args": .object(["uid": .string("__legacy__")])]),
                    .object(["cmd": .string("lookup"), "args": .object(["uid": .string("unknown")])]),
                    .object(["cmd": .string("lookup"), "args": .object(["uid": .string("2000911")])]),
                    .object(["cmd": .string("lookup"), "args": .object(["uid": .string("u2000911")])]),
                    .object(["cmd": .string("lookup"), "args": .object(["uid": .string("3000961")])]),
                    .object(["cmd": .string("lookup"), "args": .object(["uid": .string("u3000961")])]),
                    .object(["cmd": .string("lookup"), "args": .object(["uid": .string("3000962")])]),
                    .object(["cmd": .string("lookup"), "args": .object(["uid": .string("3000963")])]),
                    .object(["cmd": .string("lookup"), "args": .object(["uid": .string("3000964")])]),
                    .object(["cmd": .string("lookup"), "args": .object(["uid": .string("3000965")])]),
                    .object(["cmd": .string("lookup"), "args": .object(["uid": .string("3000998")])]),
                ]
            ),

            // 12. mention_names
            ContactRecorderHarness.ScenarioDef(
                name: "mention_names",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000912",
                    displayName: "Contacts User 12",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "contacts": .object([
                            "friends": .array([
                                .object([
                                    "id": .string("3000971"),
                                    "name": .string("Alias Target"),
                                    "zalo_name": .string("Alias Target"),
                                ]),
                                .object([
                                    "id": .string("3000972"),
                                    "name": .string("Bạn"),
                                    "zalo_name": .string("Bạn"),
                                ]),
                                .object([
                                    "id": .string("3000973"),
                                    "name": .string("Người dùng Zalo"),
                                    "zalo_name": .string("Người dùng Zalo"),
                                ]),
                                .object([
                                    "id": .string("3000974"),
                                    "name": .string("3000974"),
                                    "zalo_name": .string("3000974"),
                                ]),
                                .object([
                                    "id": .string("3000975"),
                                    "name": .string("Plain Friend"),
                                    "zalo_name": .string("Plain Friend"),
                                ]),
                            ]),
                            "aliases": .object([
                                "3000971": .string("Bí danh"),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000912", displayName: "Contacts User 12"),
                    MessageRecorderHarness.profileMeScript(uid: "2000912", displayName: "Contacts User 12"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("mention_name"), "args": .object(["uid": .string("2000912")])]),
                    .object(["cmd": .string("mention_name"), "args": .object(["uid": .string("u2000912")])]),
                    .object(["cmd": .string("mention_name"), "args": .object(["uid": .string("-1")])]),
                    .object(["cmd": .string("mention_name"), "args": .object(["uid": .string("3000999")])]),
                    .object(["cmd": .string("mention_name"), "args": .object(["uid": .string("3000974")])]),
                    .object(["cmd": .string("mention_name"), "args": .object(["uid": .string("3000972")])]),
                    .object(["cmd": .string("mention_name"), "args": .object(["uid": .string("3000973")])]),
                    .object(["cmd": .string("mention_name"), "args": .object(["uid": .string("3000971")])]),
                    .object(["cmd": .string("mention_name"), "args": .object(["uid": .string("3000975")])]),
                ]
            ),

            // 13. blocked_load
            ContactRecorderHarness.ScenarioDef(
                name: "blocked_load",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000913",
                    displayName: "Contacts User 13",
                    suppress: ["ws", "long_poll"]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000913", displayName: "Contacts User 13"),
                    MessageRecorderHarness.profileMeScript(uid: "2000913", displayName: "Contacts User 13"),
                    // 1. fail from nil -> []
                    ContactRecorderHarness.httpScript(
                        path: "/api/friend/blocklistv2",
                        method: "GET",
                        status: 500,
                        json: .object(["error_code": .int(500), "error_message": .string("Block list failed")])
                    ),
                    // 2. page 1 with has_more=1
                    ContactRecorderHarness.httpScript(
                        path: "/api/friend/blocklistv2",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "has_more": .int(1),
                                "profiles": .array([
                                    .object([
                                        "userId": .string("u3000981"),
                                        "displayName": .string("Blocked One"),
                                        "avatar": .string("https://cdn.example.invalid/b1.jpg"),
                                    ]),
                                    .object([
                                        "uid": .string("3000982"),
                                        "zaloName": .string("Blocked Two"),
                                    ]),
                                ]),
                            ]),
                        ])
                    ),
                    // 3. page 2 with has_more=0
                    ContactRecorderHarness.httpScript(
                        path: "/api/friend/blocklistv2",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "has_more": .int(0),
                                "profiles": .array([
                                    .object([
                                        "userId": .string("3000983"),
                                        "displayName": .string(""),
                                        "zaloName": .string(""),
                                    ]),
                                ]),
                            ]),
                        ])
                    ),
                    // 4. fail when already loaded -> kept
                    ContactRecorderHarness.httpScript(
                        path: "/api/friend/blocklistv2",
                        method: "GET",
                        status: 500,
                        json: .object(["error_code": .int(500), "error_message": .string("Block list failed again")])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("load_blocked")]),
                    .object(["snapshot": .string("fail_from_nil")]),
                    .object(["cmd": .string("load_blocked")]),
                    .object(["snapshot": .string("loaded_two_pages")]),
                    .object(["cmd": .string("load_blocked")]),
                ]
            ),

            // 14. blocked_set
            ContactRecorderHarness.ScenarioDef(
                name: "blocked_set",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000914",
                    displayName: "Contacts User 14",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "open_conversation_id": .string("3000981"),
                        "blocked_users": .array([
                            .object([
                                "id": .string("3000980"),
                                "name": .string("Existing Blocked"),
                                "avatar": .null,
                            ]),
                        ]),
                        "contacts": .object([
                            "friends": .array([
                                .object([
                                    "id": .string("3000981"),
                                    "name": .string("Alice Identity"),
                                    "zalo_name": .string("Alice Identity"),
                                    "avatar": .string("https://cdn.example.invalid/a981.jpg"),
                                ]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000914", displayName: "Contacts User 14"),
                    MessageRecorderHarness.profileMeScript(uid: "2000914", displayName: "Contacts User 14"),
                    ContactRecorderHarness.httpScript(path: "/api/friend/block", method: "POST", json: .object(["error_code": .int(0), "data": .object([:])])),
                    ContactRecorderHarness.httpScript(path: "/api/friend/block", method: "POST", json: .object(["error_code": .int(0), "data": .object([:])])),
                    ContactRecorderHarness.httpScript(path: "/api/friend/unblock", method: "POST", json: .object(["error_code": .int(0), "data": .object([:])])),
                    ContactRecorderHarness.httpScript(path: "/api/friend/block", method: "POST", json: .object(["error_code": .int(0), "data": .object([:])])),
                    ContactRecorderHarness.httpScript(path: "/api/friend/block", method: "POST", json: .object(["error_code": .int(0), "data": .object([:])])),
                    ContactRecorderHarness.httpScript(path: "/api/friend/block", method: "POST", json: .object(["error_code": .int(0), "data": .object([:])])),
                    ContactRecorderHarness.httpScript(path: "/api/friend/block", method: "POST", status: 500, json: .object(["error_code": .int(500), "error_message": .string("Block failed")])),
                    ContactRecorderHarness.httpScript(path: "/api/friend/unblock", method: "POST", status: 500, json: .object(["error_code": .int(500), "error_message": .string("Unblock failed")])),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("set_blocked"), "args": .object(["uid": .string("3000981"), "blocked": .bool(true), "name": .string("Explicit Blocked")])]),
                    .object(["snapshot": .string("block_with_name")]),
                    .object(["cmd": .string("set_blocked"), "args": .object(["uid": .string("3000980"), "blocked": .bool(true), "name": .string("")])]),
                    .object(["snapshot": .string("block_existing_to_front")]),
                    .object(["cmd": .string("set_blocked"), "args": .object(["uid": .string("3000981"), "blocked": .bool(false), "name": .string("")])]),
                    .object(["snapshot": .string("unblock")]),
                    .object(["cmd": .string("set_blocked"), "args": .object(["uid": .string("3000981"), "blocked": .bool(true), "name": .string("")])]),
                    .object(["snapshot": .string("block_identity_name")]),
                    .object(["cmd": .string("set_blocked"), "args": .object(["uid": .string("3000982"), "blocked": .bool(true), "name": .string("")])]),
                    .object(["snapshot": .string("block_empty_name")]),
                    .object(["cmd": .string("set_blocked"), "args": .object(["uid": .string("u3000983"), "blocked": .bool(true), "name": .string("Prefixed User")])]),
                    .object(["snapshot": .string("block_prefixed")]),
                    .object(["cmd": .string("set_blocked"), "args": .object(["uid": .string("3000984"), "blocked": .bool(true), "name": .string("Fail Block")])]),
                    .object(["snapshot": .string("block_fail")]),
                    .object(["cmd": .string("set_blocked"), "args": .object(["uid": .string("3000980"), "blocked": .bool(false), "name": .string("")])]),
                ]
            ),

            // 15. alias_save
            ContactRecorderHarness.ScenarioDef(
                name: "alias_save",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000915",
                    displayName: "Contacts User 15",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "contacts": .object([
                            "friends": .array([
                                .object([
                                    "id": .string("3000991"),
                                    "name": .string("Original Friend"),
                                    "zalo_name": .string("Original Friend"),
                                    "avatar": .string("https://cdn.example.invalid/f991.jpg"),
                                ]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000915", displayName: "Contacts User 15"),
                    MessageRecorderHarness.profileMeScript(uid: "2000915", displayName: "Contacts User 15"),
                    ContactRecorderHarness.httpScript(path: "/api/alias/update", method: "GET", json: .object(["error_code": .int(0), "data": .object([:])])),
                    ContactRecorderHarness.httpScript(path: "/api/alias/update", method: "GET", json: .object(["error_code": .int(0), "data": .object([:])])),
                    ContactRecorderHarness.httpScript(path: "/api/alias/remove", method: "GET", json: .object(["error_code": .int(0), "data": .object([:])])),
                    ContactRecorderHarness.httpScript(path: "/api/alias/update", method: "GET", status: 500, json: .object(["error_code": .int(500), "error_message": .string("Alias failed")])),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("save_alias"), "args": .object(["uid": .string("3000991"), "name": .string("  Tên Gợi Nhớ 1  ")])]),
                    .object(["cmd": .string("lookup"), "args": .object(["uid": .string("3000991")])]),
                    .object(["snapshot": .string("after_set")]),
                    .object(["cmd": .string("save_alias"), "args": .object(["uid": .string("3000991"), "name": .string("Tên Gợi Nhớ 2")])]),
                    .object(["cmd": .string("lookup"), "args": .object(["uid": .string("3000991")])]),
                    .object(["snapshot": .string("after_change")]),
                    .object(["cmd": .string("save_alias"), "args": .object(["uid": .string("3000991"), "name": .string("   ")])]),
                    .object(["cmd": .string("lookup"), "args": .object(["uid": .string("3000991")])]),
                    .object(["snapshot": .string("after_clear")]),
                    .object(["cmd": .string("save_alias"), "args": .object(["uid": .string("3000991"), "name": .string("Will Fail")])]),
                    .object(["cmd": .string("lookup"), "args": .object(["uid": .string("3000991")])]),
                ]
            ),
        ]
    }
}

// MARK: - ContactRecorderHarness

@MainActor
private final class ContactTransitionRecorder {
    private let scenarioName: String
    private let capture: () -> CaseJSON
    private var history: [CaseJSON] = []
    private var searchFromIndex = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(scenarioName: String, capture: @escaping () -> CaseJSON) {
        self.scenarioName = scenarioName
        self.capture = capture
    }

    func recordTransition() {
        let snap = capture()
        if history.last != snap {
            history.append(snap)
        }
        let pending = waiters
        waiters.removeAll()
        for cont in pending.values {
            cont.resume()
        }
    }

    func cancelWaiters() {
        let pending = waiters
        waiters.removeAll()
        for cont in pending.values {
            cont.resume()
        }
    }

    func awaitPredicate(_ pred: CaseJSON, timeoutMs: Int) async throws {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        let targetKind = pred["phase"]?.stringValue
        let targetStep = pred["step"]?.stringValue

        func matches(_ state: CaseJSON) -> Bool {
            guard let phase = state["phase"],
                  let kind = phase["kind"]?.stringValue else { return false }
            if let targetKind, kind != targetKind { return false }
            if let targetStep, phase["step"]?.stringValue != targetStep { return false }
            return true
        }

        while true {
            recordTransition()
            if let hit = (searchFromIndex..<history.count).first(where: { matches(history[$0]) }) {
                searchFromIndex = hit + 1
                return
            }
            let remaining = deadline - ContinuousClock.now
            if remaining <= .zero {
                throw ContactRecorderHarness.RecorderError.timeout(
                    scenario: scenarioName,
                    detail: "timed out awaiting \(pred.canonicalString()); latest phase: \(history.last?["phase"]?.canonicalString() ?? "none")"
                )
            }
            let waiterId = UUID()
            let timeoutTask = Task { @MainActor in
                try? await Task.sleep(for: min(remaining, .milliseconds(50)))
                if let cont = self.waiters.removeValue(forKey: waiterId) {
                    cont.resume()
                }
            }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                waiters[waiterId] = cont
            }
            timeoutTask.cancel()
        }
    }
}

enum ContactRecorderHarness {
    enum RecorderError: Error, CustomStringConvertible {
        case timeout(scenario: String, detail: String)
        case unscriptedRequest(scenario: String, detail: String)
        case invalidSeed(scenario: String, detail: String)
        case invalidStep(scenario: String, detail: String)

        var description: String {
            switch self {
            case .timeout(let s, let d): return "[\(s)] timeout: \(d)"
            case .unscriptedRequest(let s, let d): return "[\(s)] unscripted HTTP request(s): \(d)"
            case .invalidSeed(let s, let d): return "[\(s)] invalid seed: \(d)"
            case .invalidStep(let s, let d): return "[\(s)] invalid step: \(d)"
            }
        }
    }

    struct ScenarioDef {
        let name: String
        let seed: CaseJSON
        let server: [CaseJSON]
        let steps: [CaseJSON]
        let slow: Bool

        init(name: String, seed: CaseJSON, server: [CaseJSON], steps: [CaseJSON], slow: Bool = false) {
            self.name = name
            self.seed = seed
            self.server = server
            self.steps = steps
            self.slow = slow
        }
    }

    static func httpScript(
        path: String,
        method: String = "GET",
        status: Int = 200,
        json: CaseJSON? = nil,
        raw: String? = nil,
        error: String? = nil,
        hold: Bool = false,
        repeatResponse: Bool = false
    ) -> CaseJSON {
        var resp: [String: CaseJSON] = ["status": .int(Int64(status))]
        if let json { resp["json"] = json }
        if let raw { resp["raw"] = .string(raw) }
        if let error { resp["error"] = .string(error) }
        var obj: [String: CaseJSON] = [
            "kind": .string("http"),
            "path": .string(path),
            "method": .string(method),
            "response": .object(resp),
        ]
        if hold { obj["hold"] = .bool(true) }
        if repeatResponse { obj["repeat"] = .bool(true) }
        return .object(obj)
    }

    private static var shouldRecord: Bool {
        ProcessInfo.processInfo.environment["OLAZ_RECORD"] == "1"
    }

    private static var shouldRunSlowCases: Bool {
        shouldRecord || ProcessInfo.processInfo.environment["OLAZ_SLOW_CASES"] == "1"
    }

    @MainActor
    static func runDomain(domain: String, scenarios: [ScenarioDef]) async throws {
        let sorted = scenarios.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
        let url = CaseFile.casesURL(domain: domain)

        if shouldRecord {
            var recorded: [CaseJSON] = []
            recorded.reserveCapacity(sorted.count)
            for scenario in sorted {
                recorded.append(try await recordScenario(domain: domain, scenario))
            }
            try CaseFile.write(recorded, to: url)
            return
        }

        let existing = try CaseFile.load(url: url)
        var byName: [String: CaseJSON] = [:]
        for item in existing {
            if let name = item["name"]?.stringValue {
                byName[name] = item
            }
        }
        XCTAssertEqual(byName.count, sorted.count, "\(domain).jsonl case count mismatch (run with OLAZ_RECORD=1 to regenerate)")

        for scenario in sorted {
            if scenario.slow && !shouldRunSlowCases {
                print("skipped slow: \(scenario.name)")
                continue
            }
            guard let expected = byName[scenario.name] else {
                XCTFail("Missing recorded case '\(scenario.name)' in \(url.path)")
                continue
            }
            let actual = try await recordScenario(domain: domain, scenario)
            if let diff = CaseJSON.firstDiff(expected: expected, actual: actual) {
                XCTFail("\(scenario.name): \(diff)")
            }
        }
    }

    @MainActor
    static func recordScenario(domain: String, _ scenario: ScenarioDef) async throws -> CaseJSON {
        try await RecorderSuiteLock.shared.withLock {
            try await recordScenarioLocked(domain: domain, scenario)
        }
    }

    @MainActor
    private static func recordScenarioLocked(domain: String, _ scenario: ScenarioDef) async throws -> CaseJSON {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-contact-recorder-\(scenario.name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let storage = RecorderStorageIsolation(prefix: "olaz.contact-recorder")
        EngineLog.shared.onAppend = nil

        defer {
            EngineLog.shared.onAppend = nil
            storage.cleanup()
            try? FileManager.default.removeItem(at: dataDir)
        }

        let initialSecretKey = extractInitialSecretKey(from: scenario.seed)
        let wsAuthManual = scenario.seed["ws_auth"]?.stringValue == "manual"
        let server = try FakeZaloServer(
            serverScript: scenario.server,
            initialSecretKey: initialSecretKey,
            wsAuthManual: wsAuthManual
        )
        try await server.start()

        let baseURL = server.baseURLString
        let wsURL = server.wsBaseURLString

        func substituteRuntimeURLs(_ json: CaseJSON) -> CaseJSON {
            json
                .replacingString("http://fake", with: baseURL)
                .replacingString("ws://fake", with: wsURL)
        }

        func normalizeRecordedURLs(_ json: CaseJSON) -> CaseJSON {
            json
                .replacingString(baseURL, with: "http://fake")
                .replacingString(wsURL, with: "ws://fake")
        }

        var seededUserId: String?
        if let savedSession = scenario.seed["saved_session"], savedSession != .null {
            seededUserId = savedSession["plainAccount"]?["userId"]?.stringValue
            let sub = substituteRuntimeURLs(savedSession)
            let fileURL = dataDir.appendingPathComponent("native-session.json")
            try Data(sub.canonicalString().utf8).write(to: fileURL, options: .atomic)
        }

        if let uid = seededUserId, !uid.isEmpty {
            try await seedSQLiteStore(userId: uid, dataDir: dataDir, seed: substituteRuntimeURLs(scenario.seed))
        }

        let domainsJSON = substituteRuntimeURLs(scenario.seed["domains"] ?? defaultFakeDomainsJSON())
        let domainsData = Data(domainsJSON.canonicalString().utf8)
        let domains = try JSONDecoder().decode(ZaloDomains.self, from: domainsData)
        try assertOnlyLocalFakeHosts(domains, scenario: scenario.name, stage: "initial seed")

        let engine = ZaloEngine(
            dataDirectory: dataDir,
            useKeychain: false,
            domains: domains,
            userDefaultsSuiteName: storage.userDefaultsSuiteName,
            cookieStorage: storage.cookieStorage
        )
        if let nextClientId = scenario.seed["next_client_id"]?.int64Value {
            await engine.sessionClient.seedNextClientId(nextClientId)
        }
        if let prefsObj = scenario.seed["prefs"]?.objectValue {
            for (k, v) in prefsObj {
                if let s = v.stringValue {
                    engine.recordedSessionPrefs[k] = s
                }
            }
        }
        if let pollSeed = scenario.seed["poll_state"], pollSeed != .null {
            let decoded = try JSONDecoder().decode(ZaloPollState.self, from: Data(pollSeed.canonicalString().utf8))
            engine.pollState = decoded
        }
        if let cursorsSeed = scenario.seed["ws_cursors"], cursorsSeed != .null {
            let decoded = try JSONDecoder().decode([String: ZaloWSQueueCursorSnapshot].self, from: Data(cursorsSeed.canonicalString().utf8))
            await engine.webSocket.seedQueueCursors(decoded)
        }
        if let contactsSeed = scenario.seed["contacts"], contactsSeed != .null {
            applyContactsSeed(substituteRuntimeURLs(contactsSeed), to: engine)
        }
        if let blockedSeed = scenario.seed["blocked_users"], blockedSeed != .null {
            if let arr = blockedSeed.arrayValue {
                engine.blockedUsers = arr.compactMap { row in
                    guard let id = row["id"]?.stringValue else { return nil }
                    let name = row["name"]?.stringValue ?? ""
                    let avt = row["avatar"]?.stringValue.flatMap { URL(string: substituteRuntimeURLs(.string($0)).stringValue ?? $0) }
                    return BlockedUser(id: id, name: name, avatar: avt)
                }
            }
        }
        if let openConvId = scenario.seed["open_conversation_id"]?.stringValue, !openConvId.isEmpty {
            engine.openConversationId = openConvId
        }
        if let freshnessObj = scenario.seed["history_freshness"]?.objectValue {
            var map: [String: HistoryFreshness] = [:]
            for (k, v) in freshnessObj {
                switch v.stringValue {
                case "up_to_date": map[k] = .upToDate
                case "stale": map[k] = .stale
                default: break
                }
            }
            engine.historyFreshness = map
        }
        if let autoDelObj = scenario.seed["auto_delete"]?.objectValue {
            var map: [String: Int64] = [:]
            for (k, v) in autoDelObj {
                if let ttl = v.int64Value, ttl > 0 {
                    map[k] = ttl
                }
            }
            engine.autoDelete = map
        }

        var bootstrapLogs: [String] = []
        var sendLogs: [String] = []
        var actionLogs: [String] = []
        var lookups: [String: CaseJSON] = [:]
        var lastAliasResult: (ok: Bool, text: String)?

        func installLogHooks(forwardingTo existing: ((String) -> Void)?) {
            EngineLog.shared.onAppend = { rawLine in
                existing?(rawLine)
                if let sp = rawLine.firstIndex(of: " ") {
                    let msg = String(rawLine[rawLine.index(after: sp)...])
                    if msg.hasPrefix("bootstrap: ") {
                        bootstrapLogs.append(msg)
                    }
                    if msg.hasPrefix("sendText ") {
                        sendLogs.append(msg)
                    }
                    if msg.hasPrefix("react failed") || msg.hasPrefix("recall failed") || msg.hasPrefix("autodelete: ") {
                        actionLogs.append(msg)
                    }
                }
            }
        }
        installLogHooks(forwardingTo: nil)

        let suppressedTransports = Set(
            scenario.seed["suppress"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )

        var hostCalls: [CaseJSON] = []
        var hostSettleTargets: [Int] = []
        var hostCursor = 0
        var settleCount = 0
        var signalWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        func notifySignal() {
            let pending = signalWaiters
            signalWaiters.removeAll()
            for cont in pending.values {
                cont.resume()
            }
        }

        engine.traceU4HostEnabled = true
        engine.hostTrace = { name, args in
            let normalizedArgs = normalizeRecordedURLs(CaseJSON.fromAny(args))
            hostCalls.append(.object([
                "call": .string(name),
                "args": normalizedArgs,
            ]))
            hostSettleTargets.append(settleCount)
            notifySignal()
            switch name {
            case "prepare_store":
                return true
            case "apply_batch", "apply_parsed_events":
                return true
            case "start_ws":
                return !suppressedTransports.contains("ws")
            case "start_long_poll":
                return !suppressedTransports.contains("long_poll")
            default:
                return false
            }
        }

        let transitionRecorder = ContactTransitionRecorder(scenarioName: scenario.name) {
            normalizeRecordedURLs(SessionSnapshot.capture(from: engine))
        }
        engine.stateTrace = { [weak transitionRecorder] in
            transitionRecorder?.recordTransition()
        }
        engine.transportSettleTrace = {
            settleCount += 1
            notifySignal()
        }

        func waitForCondition(timeoutMs: Int, description: String, _ pred: @MainActor () -> Bool) async throws {
            let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
            while !pred() {
                let remaining = deadline - ContinuousClock.now
                if remaining <= .zero {
                    throw RecorderError.timeout(scenario: scenario.name, detail: "Timed out waiting for \(description)")
                }
                let waitId = UUID()
                let sleeper = Task { @MainActor in
                    try? await Task.sleep(for: remaining)
                    if let cont = signalWaiters.removeValue(forKey: waitId) {
                        cont.resume()
                    }
                }
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    signalWaiters[waitId] = cont
                }
                sleeper.cancel()
            }
        }

        var snapshots: [String: CaseJSON] = [:]

        do {
            for (stepIndex, step) in scenario.steps.enumerated() {
                if let cmd = step["cmd"]?.stringValue {
                    let args = step["args"]?.objectValue
                    var keepNowMsForAsync = false
                    if let stepNowMs = step["now_ms"]?.int64Value {
                        engine.nowMs = { stepNowMs }
                    }
                    defer {
                        if !keepNowMsForAsync && step["now_ms"] != nil {
                            engine.nowMs = { Int64(Date().timeIntervalSince1970 * 1000) }
                        }
                    }

                    switch cmd {
                    case "start":
                        let priorLogHook = EngineLog.shared.onAppend
                        engine.start()
                        installLogHooks(forwardingTo: priorLogHook)
                    case "open":
                        _ = await engine.bootTask?.value
                        let id = args?["id"]?.stringValue ?? ""
                        engine.openConversation(id)
                        _ = await engine.openConversationTask?.value
                        _ = await engine.persistConversationsTask?.value
                    case "close":
                        engine.closeConversation()
                    case "contacts_sync":
                        _ = await engine.bootTask?.value
                        await engine.performContactsSync()
                        await engine.awaitContactsTasksForRecording()
                    case "accept_request":
                        _ = await engine.bootTask?.value
                        let id = args?["id"]?.stringValue ?? ""
                        engine.acceptFriendRequest(id)
                        await engine.awaitContactsTasksForRecording()
                    case "decline_request":
                        _ = await engine.bootTask?.value
                        let id = args?["id"]?.stringValue ?? ""
                        engine.declineFriendRequest(id)
                        await engine.awaitContactsTasksForRecording()
                    case "cancel_request":
                        _ = await engine.bootTask?.value
                        let id = args?["id"]?.stringValue ?? ""
                        engine.cancelFriendRequest(id)
                        await engine.awaitContactsTasksForRecording()
                    case "send_request":
                        _ = await engine.bootTask?.value
                        let id = args?["id"]?.stringValue ?? ""
                        let message = args?["message"]?.stringValue ?? ""
                        engine.sendFriendRequest(to: id, message: message)
                        await engine.awaitContactsTasksForRecording()
                    case "find_by_phone":
                        _ = await engine.bootTask?.value
                        let phone = args?["phone"]?.stringValue ?? ""
                        let isAsync = args?["async"]?.boolValue ?? false
                        if isAsync {
                            let heldBefore = server.heldHTTPCount()
                            engine.findFriend(byPhone: phone)
                            let reachedHeld = await server.waitForHeldHTTPRequests(atLeast: heldBefore + 1, timeoutMs: 2000)
                            if !reachedHeld && !engine.contactsTasks.isEmpty {
                                try await waitForCondition(timeoutMs: 2000, description: "async find_by_phone to hold or finish") {
                                    engine.contactsTasks.isEmpty || server.heldHTTPCount() > heldBefore
                                }
                            }
                            if engine.contactsTasks.isEmpty {
                                await engine.awaitContactsTasksForRecording()
                            } else {
                                keepNowMsForAsync = true
                            }
                        } else {
                            engine.findFriend(byPhone: phone)
                            await engine.awaitContactsTasksForRecording()
                        }
                    case "await_contacts":
                        await engine.awaitContactsTasksForRecording()
                        engine.nowMs = { Int64(Date().timeIntervalSince1970 * 1000) }
                    case "reset_search":
                        _ = await engine.bootTask?.value
                        engine.resetFriendSearch()
                    case "contacts_state":
                        _ = await engine.bootTask?.value
                        let rawJSON = substituteRuntimeURLs(args?["json"] ?? args?["state"] ?? .object([:]))
                        let stateObj = (try? JSONSerialization.jsonObject(with: Data(rawJSON.canonicalString().utf8)) as? [String: Any]) ?? [:]
                        engine.handleContacts(state: stateObj)
                    case "lookup":
                        _ = await engine.bootTask?.value
                        let uid = args?["uid"]?.stringValue ?? ""
                        if let info = engine.lookupPersonInfo(uid) {
                            lookups["\(stepIndex)"] = normalizeRecordedURLs(.object([
                                "name": .string(info.name),
                                "avatar": .string(info.avatar),
                            ]))
                        } else {
                            lookups["\(stepIndex)"] = .null
                        }
                    case "mention_name":
                        _ = await engine.bootTask?.value
                        let uid = args?["uid"]?.stringValue ?? ""
                        if let name = engine.mentionDisplayName(uid) {
                            lookups["\(stepIndex)"] = .object([
                                "name": .string(name),
                                "avatar": .string(""),
                            ])
                        } else {
                            lookups["\(stepIndex)"] = .null
                        }
                    case "load_blocked":
                        _ = await engine.bootTask?.value
                        await engine.loadBlockedUsers()
                    case "set_blocked":
                        _ = await engine.bootTask?.value
                        let uid = args?["uid"]?.stringValue ?? ""
                        let blocked = args?["blocked"]?.boolValue ?? true
                        let name = args?["name"]?.stringValue ?? ""
                        await engine.setBlocked(uid, blocked: blocked, name: name)
                    case "save_alias":
                        _ = await engine.bootTask?.value
                        let uid = args?["uid"]?.stringValue ?? ""
                        let name = args?["name"]?.stringValue ?? ""
                        lastAliasResult = await engine.saveAlias(uid: uid, name: name)
                    case "clear_client_auth":
                        _ = await engine.bootTask?.value
                        await engine.sessionClient.clearAuthForTesting()
                    default:
                        throw RecorderError.invalidStep(scenario: scenario.name, detail: "Unknown cmd: \(cmd)")
                    }
                } else if let pred = step["await"] {
                    let timeoutMs = Int(step["timeout_ms"]?.int64Value ?? 5000)
                    try await transitionRecorder.awaitPredicate(pred, timeoutMs: timeoutMs)
                } else if let targetCall = step["await_host"]?.stringValue {
                    let timeoutMs = Int(step["timeout_ms"]?.int64Value ?? 5000)
                    var matchedIdx: Int?
                    try await waitForCondition(timeoutMs: timeoutMs, description: "host call '\(targetCall)'") {
                        if let idx = (hostCursor..<hostCalls.count).first(where: {
                            hostCalls[$0]["call"]?.stringValue == targetCall
                        }) {
                            matchedIdx = idx
                            return true
                        }
                        return false
                    }
                    if let idx = matchedIdx {
                        hostCursor = idx + 1
                        if targetCall == "apply_parsed_events" || targetCall == "apply_batch" {
                            let targetSettle = hostSettleTargets[idx] + 1
                            try await waitForCondition(timeoutMs: timeoutMs, description: "settle after '\(targetCall)'") {
                                settleCount >= targetSettle
                            }
                        }
                    }
                } else if let pushCount = step["ws_push"]?.int64Value {
                    let timeoutMs = Int(step["timeout_ms"]?.int64Value ?? 5000)
                    do {
                        try await server.pushWebSocketActions(count: Int(pushCount), timeoutMs: timeoutMs)
                    } catch {
                        throw RecorderError.timeout(scenario: scenario.name, detail: "\(error)")
                    }
                } else if let releaseCount = step["http_release"]?.int64Value {
                    let timeoutMs = Int(step["timeout_ms"]?.int64Value ?? 5000)
                    do {
                        try await server.releaseHeldHTTPResponses(count: Int(releaseCount), timeoutMs: timeoutMs)
                    } catch {
                        throw RecorderError.timeout(scenario: scenario.name, detail: "\(error)")
                    }
                } else if let label = step["snapshot"]?.stringValue {
                    await engine.settleForRecording()
                    await Task.yield()
                    let snap = await ContactSnapshot.capture(
                        from: engine,
                        bootstrapLogs: bootstrapLogs,
                        sendLogs: sendLogs,
                        actionLogs: actionLogs,
                        lookups: lookups,
                        lastAliasResult: lastAliasResult
                    )
                    snapshots[label] = normalizeRecordedURLs(snap)
                } else {
                    throw RecorderError.invalidStep(scenario: scenario.name, detail: "Unknown step: \(step.canonicalString())")
                }
            }

            _ = await engine.bootTask?.value
            _ = await engine.openConversationTask?.value
            _ = await engine.loadOlderTask?.value
            await engine.awaitContactsTasksForRecording()
            await engine.awaitMarkReadTasksForRecording()
            await engine.awaitNotifyTypingTaskForRecording()
            await engine.awaitMessageActionTasksForRecording()
            _ = await engine.persistConversationsTask?.value
            _ = await engine.pendingCleanupTask?.value
            await server.waitForScriptedRequests(timeoutMs: 2000)
            if !suppressedTransports.contains("ws") {
                try? await Task.sleep(for: .milliseconds(50))
            }
            await engine.settleForRecording()
            await Task.yield()

            try assertOnlyLocalFakeHosts(await engine.sessionClient.domains, scenario: scenario.name, stage: "final")

            let finalState = normalizeRecordedURLs(
                await ContactSnapshot.capture(
                    from: engine,
                    bootstrapLogs: bootstrapLogs,
                    sendLogs: sendLogs,
                    actionLogs: actionLogs,
                    lookups: lookups,
                    lastAliasResult: lastAliasResult
                )
            )
            let requests = server.canonicalRequests().map { normalizeRecordedURLs($0) }

            engine.cancelTasksForRecording()
            engine.transportSettleTrace = nil
            server.stop()
            await engine.finishTearDownForRecording()

            if server.hadUnscriptedRequest {
                let unscripted = requests.filter { $0["unscripted"]?.boolValue == true }
                throw RecorderError.unscriptedRequest(scenario: scenario.name, detail: CaseJSON.array(unscripted).canonicalString())
            }

            var caseDict: [String: CaseJSON] = [
                "format": .int(1),
                "domain": .string(domain),
                "name": .string(scenario.name),
                "seed": scenario.seed,
                "server": .array(scenario.server),
                "steps": .array(scenario.steps),
                "expect": .object([
                    "snapshots": .object(snapshots),
                    "final": finalState,
                    "requests": .array(requests),
                    "host": .array(hostCalls),
                ]),
            ]
            if scenario.slow {
                caseDict["slow"] = .bool(true)
            }
            return .object(caseDict)
        } catch {
            transitionRecorder.cancelWaiters()
            let pending = signalWaiters
            signalWaiters.removeAll()
            for cont in pending.values { cont.resume() }
            engine.cancelTasksForRecording()
            engine.transportSettleTrace = nil
            server.stop()
            await engine.finishTearDownForRecording()
            throw error
        }
    }

    // MARK: - Seed & Script Helpers

    private static func seedSQLiteStore(userId: String, dataDir: URL, seed: CaseJSON) async throws {
        let dbURL = dataDir
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(userId, isDirectory: true)
            .appendingPathComponent("history.sqlite3")
        let store = try ZaloSQLiteStore(path: dbURL.path)
        try await store.setPreferenceString(key: ZaloWebKitMigrator.donePrefKey, value: "1")

        if let pinned = seed["pinned_ids"]?.arrayValue?.compactMap(\.stringValue) {
            try await store.setPreferenceStrings(key: "pinnedIds", value: pinned)
        }
        if let archived = seed["archived_ids"]?.arrayValue?.compactMap(\.stringValue) {
            try await store.setPreferenceStrings(key: "archivedIds", value: archived)
        }
        if let unreadMarks = seed["unread_marks"]?.arrayValue?.compactMap(\.stringValue) {
            try await store.setPreferenceStrings(key: "unreadMarks", value: unreadMarks)
        }
        if let hidden = seed["hidden_ids"]?.arrayValue?.compactMap(\.stringValue) {
            try await store.setPreferenceStrings(key: "hiddenIds", value: hidden)
        }
        if let starred = seed["starred_ids"]?.arrayValue?.compactMap(\.stringValue) {
            try await store.setPreferenceStrings(key: "starredIds", value: starred)
        }
        if let seenReactions = seed["seen_reaction_event_ids"]?.arrayValue?.compactMap(\.stringValue) {
            try await store.setPreferenceStrings(key: "seenReactionEventIds", value: seenReactions)
        }
        if let e2eeThreads = seed["e2ee_threads"]?.arrayValue?.compactMap(\.stringValue) {
            try await store.setPreferenceStrings(key: "e2eeThreadsV1", value: e2eeThreads)
        }
        if let ranks = seed["activity_ranks"], ranks != .null {
            try await store.setPreferenceData(key: "activityRanks", data: Data(ranks.canonicalString().utf8))
        }
        if let contacts = seed["contacts"] {
            if let aliases = contacts["aliases"], aliases != .null {
                try await store.setPreferenceData(key: "aliases", data: Data(aliases.canonicalString().utf8))
            }
            if let profiles = contacts["cached_profiles"], profiles != .null {
                try await store.setPreferenceData(key: "cachedProfiles", data: Data(profiles.canonicalString().utf8))
            }
            if let groups = contacts["cached_groups"], groups != .null {
                try await store.setPreferenceData(key: "cachedGroups", data: Data(groups.canonicalString().utf8))
            }
            if let gidMap = contacts["gid_to_uid_map"], gidMap != .null {
                try await store.setPreferenceData(key: "gidToUidMap", data: Data(gidMap.canonicalString().utf8))
            } else if let gids = contacts["friend_global_ids"]?.objectValue {
                var inverted: [String: CaseJSON] = [:]
                for (uid, gidVal) in gids {
                    if let gid = gidVal.stringValue, !gid.isEmpty, !uid.isEmpty {
                        inverted[gid] = .string(uid)
                    }
                }
                try await store.setPreferenceData(key: "gidToUidMap", data: Data(CaseJSON.object(inverted).canonicalString().utf8))
            }
        }
        if let convRows = seed["local_conversations"]?.arrayValue, !convRows.isEmpty {
            let stored: [StoredConversation] = convRows.compactMap { row in
                guard let id = row["id"]?.stringValue else { return nil }
                return StoredConversation(
                    id: id,
                    isGroup: row["is_group"]?.boolValue ?? false,
                    name: row["name"]?.stringValue ?? "",
                    avatar: row["avatar"]?.stringValue ?? "",
                    pinned: row["pinned"]?.boolValue ?? false,
                    members: Int(row["members"]?.int64Value ?? 0),
                    unread: Int(row["unread"]?.int64Value ?? 0),
                    previewText: row["preview_text"]?.stringValue ?? "",
                    previewTsMs: row["preview_ts_ms"]?.int64Value ?? 0,
                    previewFromMe: row["preview_from_me"]?.boolValue ?? false,
                    updatedAtMs: row["updated_at_ms"]?.int64Value ?? 1700000000000
                )
            }
            try await store.saveConversations(stored)
        }
        if let msgRows = seed["local_messages"]?.arrayValue, !msgRows.isEmpty {
            let stored: [StoredMessage] = msgRows.compactMap { row in
                guard let id = row["id"]?.stringValue, let convId = row["conv_id"]?.stringValue else { return nil }
                let status = row["status"]?.stringValue ?? "sent"
                let rawJSON: Data = {
                    if let rawObj = row["raw_json"], rawObj != .null {
                        return Data(rawObj.canonicalString().utf8)
                    }
                    var obj: [String: CaseJSON] = [
                        "id": .string(id),
                        "conversationId": .string(convId),
                        "clientId": .string(row["client_id"]?.stringValue ?? id),
                        "senderId": .string(row["sender_id"]?.stringValue ?? ""),
                        "senderName": .string(row["sender_name"]?.stringValue ?? ""),
                        "senderAvatar": .string(row["sender_avatar"]?.stringValue ?? ""),
                        "isMine": .bool(row["is_mine"]?.boolValue ?? false),
                        "text": .string(row["text"]?.stringValue ?? ""),
                        "date": .int(row["ts_ms"]?.int64Value ?? 0),
                        "status": .string(status),
                        "isE2EE": .bool(row["is_e2ee"]?.boolValue ?? false),
                        "kind": .object(["type": .string(row["kind_tag"]?.stringValue ?? "text")]),
                    ]
                    if let reactions = row["reactions"], reactions != .null {
                        obj["reactions"] = reactions
                    }
                    return Data(CaseJSON.object(obj).canonicalString().utf8)
                }()
                return StoredMessage(
                    id: id,
                    convId: convId,
                    clientId: row["client_id"]?.stringValue ?? id,
                    senderId: row["sender_id"]?.stringValue ?? "",
                    senderName: row["sender_name"]?.stringValue ?? "",
                    senderAvatar: row["sender_avatar"]?.stringValue ?? "",
                    isMine: row["is_mine"]?.boolValue ?? false,
                    text: row["text"]?.stringValue ?? "",
                    kindTag: row["kind_tag"]?.stringValue ?? "text",
                    tsMs: row["ts_ms"]?.int64Value ?? 0,
                    status: status,
                    rawJSONData: rawJSON
                )
            }
            try await store.saveMessages(stored)
        }
        await store.close()
    }

    @MainActor
    private static func applyContactsSeed(_ contacts: CaseJSON, to engine: ZaloEngine) {
        if let loaded = contacts["friends_loaded"]?.boolValue {
            engine.contacts.friendsLoaded = loaded
        }
        if let loaded = contacts["groups_loaded"]?.boolValue {
            engine.contacts.groupsLoaded = loaded
        }
        if let count = contacts["pending_request_count"]?.int64Value {
            engine.contacts.pendingRequestCount = Int(count)
        }
        if let loading = contacts["loading_requests"]?.boolValue {
            engine.contacts.loadingRequests = loading
        }
        if let friendsArr = contacts["friends"]?.arrayValue {
            engine.contacts.friends = friendsArr.compactMap { row in
                guard let id = row["id"]?.stringValue else { return nil }
                let name = row["name"]?.stringValue ?? id
                let zaloName = row["zalo_name"]?.stringValue ?? name
                let avatar = row["avatar"]?.stringValue.flatMap(URL.init(string:))
                let lastActive = row["last_active_ms"]?.int64Value.map { Date(timeIntervalSince1970: Double($0) / 1000.0) }
                let online = row["online"]?.boolValue ?? false
                let section = row["section"]?.stringValue ?? String(name.prefix(1)).uppercased()
                let sortKey = row["sort_key"]?.stringValue ?? name.lowercased()
                return ContactsState.Friend(
                    id: id,
                    name: name,
                    zaloName: zaloName,
                    avatar: avatar,
                    lastActive: lastActive,
                    online: online,
                    section: section.isEmpty ? "#" : section,
                    sortKey: sortKey
                )
            }
        }
        if let groupsArr = contacts["groups"]?.arrayValue {
            engine.contacts.groups = groupsArr.compactMap { row in
                guard let id = row["id"]?.stringValue else { return nil }
                let name = row["name"]?.stringValue ?? id
                let avatar = row["avatar"]?.stringValue.flatMap(URL.init(string:))
                let members = Int(row["members"]?.int64Value ?? 0)
                let sortKey = row["sort_key"]?.stringValue ?? name.lowercased()
                return ContactsState.Group(
                    id: id,
                    name: name,
                    avatar: avatar,
                    members: members,
                    sortKey: sortKey
                )
            }
        }
        func parseReq(_ row: CaseJSON) -> ContactsState.FriendRequest? {
            guard let id = row["id"]?.stringValue else { return nil }
            let name = row["name"]?.stringValue ?? ""
            let avatar = row["avatar"]?.stringValue.flatMap(URL.init(string:))
            let message = row["message"]?.stringValue ?? ""
            let date = row["date_ms"]?.int64Value.map { Date(timeIntervalSince1970: Double($0) / 1000.0) }
            return ContactsState.FriendRequest(id: id, name: name, avatar: avatar, message: message, date: date)
        }
        if let receivedArr = contacts["received"]?.arrayValue {
            engine.contacts.received = receivedArr.compactMap(parseReq)
        }
        if let sentArr = contacts["sent"]?.arrayValue {
            engine.contacts.sent = sentArr.compactMap(parseReq)
        }
        if let searchObj = contacts["search"], searchObj != .null {
            let status = ContactsState.Search.Status(rawValue: searchObj["status"]?.stringValue ?? "") ?? .idle
            let error = searchObj["error"]?.stringValue
            var user: ContactsState.FoundUser?
            if let u = searchObj["user"], u != .null, let id = u["id"]?.stringValue {
                user = ContactsState.FoundUser(
                    id: id,
                    name: u["name"]?.stringValue ?? "",
                    zaloName: u["zalo_name"]?.stringValue ?? "",
                    avatar: u["avatar"]?.stringValue.flatMap(URL.init(string:)),
                    bio: u["bio"]?.stringValue ?? "",
                    isFriend: u["is_friend"]?.boolValue ?? false,
                    isSelf: u["is_self"]?.boolValue ?? false,
                    requested: u["requested"]?.boolValue ?? false,
                    requesting: u["requesting"]?.boolValue ?? false,
                    defaultMessage: u["default_message"]?.stringValue ?? "",
                    maxMessage: Int(u["max_message"]?.int64Value ?? 150)
                )
            }
            engine.contacts.search = ContactsState.Search(status: status, error: error, user: user)
        }
        if let noticeObj = contacts["notice"], noticeObj != .null,
           let seq = noticeObj["seq"]?.int64Value {
            engine.contacts.notice = ContactsState.Notice(
                seq: Int(seq),
                ok: noticeObj["ok"]?.boolValue ?? false,
                text: noticeObj["text"]?.stringValue ?? ""
            )
        }
    }

    private static func extractInitialSecretKey(from seed: CaseJSON) -> Data? {
        guard let enk = seed["saved_session"]?["plainAccount"]?["zpwEnk"]?.stringValue,
              !enk.isEmpty else { return nil }
        let key = ZaloCrypto.parseSecretKey(enk)
        return (key.count == 16 || key.count == 32) ? key : nil
    }

    private static func defaultFakeDomainsJSON() -> CaseJSON {
        let fakeServices: [String: CaseJSON] = [
            "alias": .array([.string("http://fake")]),
            "auto_reply": .array([.string("http://fake")]),
            "chat": .array([.string("http://fake")]),
            "chat_e2e": .array([.string("http://fake")]),
            "conversation": .array([.string("http://fake")]),
            "emoji_status": .array([.string("http://fake")]),
            "file": .array([.string("http://fake")]),
            "friend": .array([.string("http://fake")]),
            "friend_lan": .array([.string("http://fake")]),
            "group": .array([.string("http://fake")]),
            "group_board": .array([.string("http://fake")]),
            "group_cloud_message": .array([.string("http://fake")]),
            "group_e2e": .array([.string("http://fake")]),
            "group_poll": .array([.string("http://fake")]),
            "label": .array([.string("http://fake")]),
            "media_store": .array([.string("http://fake")]),
            "media_store_send2me": .array([.string("http://fake")]),
            "profile": .array([.string("http://fake")]),
            "quick_message": .array([.string("http://fake")]),
            "reaction": .array([.string("http://fake")]),
            "sticker": .array([.string("http://fake")]),
            "up_file": .array([.string("http://fake")]),
            "voice_call": .array([.string("http://fake")]),
            "zcloud": .array([.string("http://fake")]),
            "zcloud_up_file": .array([.string("http://fake")]),
            "znoise": .array([.string("http://fake")]),
        ]
        return .object([
            "auth": .string("http://fake"),
            "lpChat": .string("http://fake"),
            "lpControl": .string("http://fake"),
            "wpaChat": .string("http://fake"),
            "ws": .array([.string("ws://fake")]),
            "serviceCandidates": .object(fakeServices),
            "preferredHosts": .object([:]),
            "isolated": .bool(true),
        ])
    }

    private static func assertOnlyLocalFakeHosts(_ domains: ZaloDomains, scenario: String, stage: String) throws {
        let urls = [domains.auth, domains.lpChat, domains.lpControl, domains.wpaChat]
            + domains.ws
            + domains.serviceCandidates.values.flatMap { $0 }
            + domains.preferredHosts.values
        for raw in urls {
            guard let parsed = URL(string: raw),
                  let host = parsed.host?.lowercased(),
                  host == "127.0.0.1" || host == "localhost" || host == "fake" else {
                throw RecorderError.invalidSeed(scenario: scenario, detail: "Non-local host '\(raw)' at \(stage)")
            }
        }
        guard domains.isolated else {
            throw RecorderError.invalidSeed(scenario: scenario, detail: "domains.isolated must be true at \(stage)")
        }
    }
}
