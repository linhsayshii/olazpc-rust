import Foundation
import XCTest
@testable import Olaz

final class PinRecorderTests: XCTestCase {
    func testPinScenarios() async throws {
        try await PinRecorderHarness.runDomain(
            domain: "pins",
            scenarios: Self.pinScenarios()
        )
    }

    // MARK: - Helpers

    private static func seedFriend(
        id: String,
        name: String,
        avatar: String? = nil,
        lastActiveMs: Int64 = 1700000000000,
        online: Bool = false
    ) -> CaseJSON {
        .object([
            "id": .string(id),
            "name": .string(name),
            "zalo_name": .string(name),
            "avatar": avatar.map(CaseJSON.string) ?? .null,
            "last_active_ms": .int(lastActiveMs),
            "online": .bool(online),
            "section": .string(String(name.prefix(1)).uppercased()),
            "sort_key": .string(name.lowercased()),
        ])
    }

    private static func localConv(
        id: String,
        isGroup: Bool = true,
        name: String,
        members: Int64 = 3,
        previewText: String = "",
        previewTsMs: Int64 = 0
    ) -> CaseJSON {
        .object([
            "id": .string(id),
            "is_group": .bool(isGroup),
            "name": .string(name),
            "avatar": .string(""),
            "pinned": .bool(false),
            "members": .int(members),
            "unread": .int(0),
            "preview_text": .string(previewText),
            "preview_ts_ms": .int(previewTsMs),
            "preview_from_me": .bool(false),
        ])
    }

    private static func storedMsg(
        id: String,
        convId: String,
        clientId: String? = nil,
        senderId: String,
        senderName: String,
        isMine: Bool,
        text: String,
        tsMs: Int64,
        status: String = "sent",
        isE2EE: Bool = false,
        kindTag: String = "text",
        kindObj: CaseJSON? = nil
    ) -> CaseJSON {
        let cli = clientId ?? id
        let resolvedKind = kindObj ?? .object(["type": .string(kindTag)])
        return .object([
            "id": .string(id),
            "conv_id": .string(convId),
            "client_id": .string(cli),
            "sender_id": .string(senderId),
            "sender_name": .string(senderName),
            "sender_avatar": .string(""),
            "is_mine": .bool(isMine),
            "text": .string(text),
            "kind_tag": .string(kindTag),
            "ts_ms": .int(tsMs),
            "status": .string(status),
            "raw_json": .object([
                "id": .string(id),
                "conversationId": .string(convId),
                "clientId": .string(cli),
                "senderId": .string(senderId),
                "senderName": .string(senderName),
                "senderAvatar": .string(""),
                "isMine": .bool(isMine),
                "text": .string(text),
                "date": .int(tsMs),
                "status": .string(status),
                "isE2EE": .bool(isE2EE),
                "kind": resolvedKind,
            ]),
        ])
    }

    private static func pinScenarios() -> [PinRecorderHarness.ScenarioDef] {
        [
            // 1. board_group: every topic type, duplicate/empty ids, id key fallbacks,
            // params object vs JSON string, every sender & title fallback, lookup, pinLimit present vs absent.
            PinRecorderHarness.ScenarioDef(
                name: "board_group",
                seed: PinRecorderHarness.readySessionSeed(
                    userId: "2000701",
                    displayName: "Pin User 1",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "contacts": .object([
                            "friends": .array([
                                seedFriend(id: "3000701", name: "An Nguyễn"),
                            ]),
                            "aliases": .object([
                                "3000702": .string("Bình Alias"),
                            ]),
                            "cached_profiles": .object([
                                "3000703": .object(["name": .string("Chi Profile"), "avatar": .string("")]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    PinRecorderHarness.loginInfoScript(uid: "2000701", displayName: "Pin User 1"),
                    MessageRecorderHarness.profileMeScript(uid: "2000701", displayName: "Pin User 1"),
                    // First refresh: every type + id keys + duplicate/empty + params object/string + sender/title fallbacks + pinLimit: 5
                    PinRecorderHarness.httpScript(
                        path: "/api/board/pin/list",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "boardVersion": .int(7),
                                "pinLimit": .int(5),
                                "topics": .array([
                                    // Empty id -> dropped
                                    .object(["id": .string(""), "type": .int(2), "title": .string("Dropped Empty")]),
                                    // Message (type 2), params as JSON string, senderName + title + thumb + globalMsgId + cliMsgId
                                    .object([
                                        "id": .string("t1"),
                                        "type": .int(2),
                                        "params": .string("{\"senderName\":\"Tên 1\",\"title\":\"Tiêu đề 1\",\"thumb\":\"https://cdn.example.invalid/t1.jpg\",\"globalMsgId\":\"900101\",\"cliMsgId\":\"c900101\"}"),
                                    ]),
                                    // Duplicate id "t1" -> dropped
                                    .object([
                                        "id": .string("t1"),
                                        "type": .int(2),
                                        "title": .string("Duplicate Ignored"),
                                    ]),
                                    // Poll (type 3), topicId key, params object, sender_name + linkCaption + global_msg_id + client_msg_id
                                    .object([
                                        "topicId": .string("t2"),
                                        "type": .int(3),
                                        "params": .object([
                                            "sender_name": .string("Tên 2"),
                                            "linkCaption": .string("Link Caption 2"),
                                            "global_msg_id": .string("900102"),
                                            "client_msg_id": .string("c900102"),
                                        ]),
                                    ]),
                                    // Note (type 0), topic_id key, dName + content + msgId
                                    .object([
                                        "topic_id": .string("t3"),
                                        "type": .int(0),
                                        "params": .object([
                                            "dName": .string("Tên 3"),
                                            "content": .string("Note Content 3"),
                                            "msgId": .string("900103"),
                                        ]),
                                    ]),
                                    // Reminder (type 1), fromName + msg + msg_id
                                    .object([
                                        "id": .string("t4"),
                                        "type": .int(1),
                                        "params": .object([
                                            "fromName": .string("Tên 4"),
                                            "msg": .string("Reminder Msg 4"),
                                            "msg_id": .string("900104"),
                                        ]),
                                    ]),
                                    // Unknown type 99 -> falls back to message; creatorName + params.message
                                    .object([
                                        "id": .string("t5"),
                                        "type": .int(99),
                                        "creatorName": .string("Tên 5"),
                                        "params": .object([
                                            "message": .string("Fallback Message 5"),
                                        ]),
                                    ]),
                                    // Sender by lookup via params.senderUid (friends), params.description
                                    .object([
                                        "id": .string("t6"),
                                        "type": .int(2),
                                        "params": .object([
                                            "senderUid": .string("u3000701"),
                                            "description": .string("Description 6"),
                                        ]),
                                    ]),
                                    // Sender by lookup via params.senderId (aliases), row.title fallback
                                    .object([
                                        "id": .string("t7"),
                                        "type": .int(0),
                                        "title": .string("Row Title 7"),
                                        "params": .object([
                                            "senderId": .string("3000702"),
                                        ]),
                                    ]),
                                    // Sender by lookup via row.creatorId (cached_profiles), row.content fallback
                                    .object([
                                        "id": .string("t8"),
                                        "type": .int(0),
                                        "creatorId": .string("3000703"),
                                        "content": .string("Row Content 8"),
                                    ]),
                                ]),
                            ]),
                        ])
                    ),
                    // Second refresh: pinLimit absent -> defaults to 3; items & version keys fallback
                    PinRecorderHarness.httpScript(
                        path: "/api/board/pin/list",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "version": .int(8),
                                "items": .array([
                                    .object([
                                        "id": .string("t9"),
                                        "type": .int(2),
                                        "params": .object(["title": .string("Default Limit")]),
                                    ]),
                                ]),
                            ]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("refresh_board"), "args": .object(["conv_id": .string("g500701")])]),
                    .object(["snapshot": .string("with_limit_5")]),
                    .object(["cmd": .string("refresh_board"), "args": .object(["conv_id": .string("g500701")])]),
                ]
            ),

            // 2. board_friend: 1-1 board in every friendBoardListBox shape
            // (data string, array, object with topics + pin_limit, "[]")
            PinRecorderHarness.ScenarioDef(
                name: "board_friend",
                seed: PinRecorderHarness.readySessionSeed(
                    userId: "2000702",
                    displayName: "Pin User 2",
                    suppress: ["ws", "long_poll"]
                ),
                server: [
                    PinRecorderHarness.loginInfoScript(uid: "2000702", displayName: "Pin User 2"),
                    MessageRecorderHarness.profileMeScript(uid: "2000702", displayName: "Pin User 2"),
                    // 1) data as JSON string of {data:[...], version:4, pinLimit:4}
                    PinRecorderHarness.httpScript(
                        path: "/api/friendboard/list",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .string("{\"data\":[{\"id\":9100001,\"type\":2,\"params\":\"{\\\"senderUid\\\":\\\"0\\\",\\\"client_msg_id\\\":\\\"1700001\\\",\\\"global_msg_id\\\":\\\"7400001\\\",\\\"msg_type\\\":1,\\\"title\\\":\\\"Ghim 1-1\\\"}\"}],\"version\":4,\"pinLimit\":4}"),
                        ])
                    ),
                    // 2) data as array -> version 0, limit default 3
                    PinRecorderHarness.httpScript(
                        path: "/api/friendboard/list",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .array([
                                .object([
                                    "id": .string("9100002"),
                                    "type": .int(2),
                                    "params": .object(["global_msg_id": .string("7400002"), "title": .string("Array shape")]),
                                ]),
                            ]),
                        ])
                    ),
                    // 3) data as object with topics + pin_limit + version
                    PinRecorderHarness.httpScript(
                        path: "/api/friendboard/list",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "version": .int(9),
                                "pin_limit": .int(6),
                                "topics": .array([
                                    .object([
                                        "id": .string("9100003"),
                                        "type": .int(0),
                                        "params": .object(["title": .string("Topics shape")]),
                                    ]),
                                ]),
                            ]),
                        ])
                    ),
                    // 4) data as "[]" -> empty items, version 0, limit 3
                    PinRecorderHarness.httpScript(
                        path: "/api/friendboard/list",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .string("[]"),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("refresh_board"), "args": .object(["conv_id": .string("3000702")])]),
                    .object(["snapshot": .string("data_string")]),
                    .object(["cmd": .string("refresh_board"), "args": .object(["conv_id": .string("3000702")])]),
                    .object(["snapshot": .string("data_array")]),
                    .object(["cmd": .string("refresh_board"), "args": .object(["conv_id": .string("3000702")])]),
                    .object(["snapshot": .string("data_topics")]),
                    .object(["cmd": .string("refresh_board"), "args": .object(["conv_id": .string("3000702")])]),
                ]
            ),

            // 3. board_fail: list error keeps board & raw cache unchanged, logs pinErrorShape
            PinRecorderHarness.ScenarioDef(
                name: "board_fail",
                seed: PinRecorderHarness.readySessionSeed(
                    userId: "2000703",
                    displayName: "Pin User 3",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "pins": .object([
                            "g500703": .object([
                                "convId": .string("g500703"),
                                "ready": .bool(true),
                                "canPin": .bool(true),
                                "limit": .int(3),
                                "items": .array([
                                    .object([
                                        "ref": .string("88301"),
                                        "kind": .string("message"),
                                        "title": .string("Giữ nguyên"),
                                        "sender": .string("An"),
                                        "msgId": .string("90301"),
                                        "cliMsgId": .string("c90301"),
                                    ]),
                                ]),
                            ]),
                        ]),
                        "board_raw_topics": .object([
                            "g500703": .object([
                                "version": .int(3),
                                "topics": .object([
                                    "88301": .object(["id": .string("88301"), "type": .int(2)]),
                                ]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    PinRecorderHarness.loginInfoScript(uid: "2000703", displayName: "Pin User 3"),
                    MessageRecorderHarness.profileMeScript(uid: "2000703", displayName: "Pin User 3"),
                    PinRecorderHarness.httpScript(
                        path: "/api/board/pin/list",
                        method: "GET",
                        json: .object(["error_code": .int(114), "error_message": .string("board unavailable")])
                    ),
                    PinRecorderHarness.httpScript(
                        path: "/api/friendboard/list",
                        method: "GET",
                        json: .object(["error_code": .int(500), "error_message": .string("friend board error")])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("refresh_board"), "args": .object(["conv_id": .string("g500703")])]),
                    .object(["cmd": .string("refresh_board"), "args": .object(["conv_id": .string("3000703")])]),
                ]
            ),

            // 4. pin_allowed: optimistic item first (local:<id>), request params (own vs received vs senderId=0),
            // board version from cache, refresh after (group + 1-1).
            PinRecorderHarness.ScenarioDef(
                name: "pin_allowed",
                seed: PinRecorderHarness.readySessionSeed(
                    userId: "2000704",
                    displayName: "Pin User 4",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "contacts": .object([
                            "friends": .array([
                                seedFriend(id: "3000704", name: "An Nguyễn"),
                            ]),
                            "cached_profiles": .object([
                                "3000704": .object(["name": .string("An Nguyễn"), "avatar": .string("https://cdn.example.invalid/an.jpg")]),
                            ]),
                        ]),
                        "history_freshness": .object([
                            "g500704": .string("up_to_date"),
                            "3000704": .string("up_to_date"),
                        ]),
                        "local_conversations": .array([
                            localConv(id: "g500704", isGroup: true, name: "Nhóm Ghim", previewText: "Tin nhóm", previewTsMs: 1700000002000),
                            localConv(id: "3000704", isGroup: false, name: "An Nguyễn", members: 2, previewText: "Tin 1-1", previewTsMs: 1700000003000),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "90401",
                                convId: "g500704",
                                clientId: "c90401",
                                senderId: "2000704",
                                senderName: "Old Name",
                                isMine: true,
                                text: "Ảnh đẹp",
                                tsMs: 1700000001000,
                                kindTag: "photo",
                                kindObj: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/p.jpg"), "width": .int(100), "height": .int(100)])
                            ),
                            storedMsg(
                                id: "90402",
                                convId: "g500704",
                                clientId: "c90402",
                                senderId: "3000704",
                                senderName: "Fallback Sender",
                                isMine: false,
                                text: "Tin từ bạn",
                                tsMs: 1700000002000
                            ),
                            storedMsg(
                                id: "90403",
                                convId: "3000704",
                                clientId: "c90403",
                                senderId: "0",
                                senderName: "Khách",
                                isMine: false,
                                text: "Tin sender zero",
                                tsMs: 1700000003000
                            ),
                        ]),
                    ]
                ),
                server: [
                    PinRecorderHarness.loginInfoScript(uid: "2000704", displayName: "Pin User 4"),
                    MessageRecorderHarness.profileMeScript(uid: "2000704", displayName: "Pin User 4"),
                    // open g500704 -> initial board refresh (version 10, limit 5)
                    PinRecorderHarness.httpScript(
                        path: "/api/board/pin/list",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "boardVersion": .int(10),
                                "pinLimit": .int(5),
                                "topics": .array([
                                    .object(["id": .string("t_init"), "type": .int(2), "params": .object(["title": .string("Cũ")])]),
                                ]),
                            ]),
                        ])
                    ),
                    // pin m1 (held so optimistic state can be snapshotted)
                    PinRecorderHarness.httpScript(
                        path: "/api/board/topic/createv2",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["id": .string("t_90401")])]),
                        hold: true
                    ),
                    // refresh after pin m1
                    PinRecorderHarness.httpScript(
                        path: "/api/board/pin/list",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "boardVersion": .int(11),
                                "pinLimit": .int(5),
                                "topics": .array([
                                    .object(["id": .string("t_90401"), "type": .int(2), "params": .object(["global_msg_id": .string("90401"), "title": .string("Ảnh đẹp"), "senderName": .string("Pin User 4")])]),
                                    .object(["id": .string("t_init"), "type": .int(2), "params": .object(["title": .string("Cũ")])]),
                                ]),
                            ]),
                        ])
                    ),
                    // pin m2 (friend sender looked up)
                    PinRecorderHarness.httpScript(
                        path: "/api/board/topic/createv2",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["id": .string("t_90402")])])
                    ),
                    // refresh after pin m2
                    PinRecorderHarness.httpScript(
                        path: "/api/board/pin/list",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "boardVersion": .int(12),
                                "pinLimit": .int(5),
                                "topics": .array([
                                    .object(["id": .string("t_90402"), "type": .int(2), "params": .object(["global_msg_id": .string("90402"), "title": .string("Tin từ bạn"), "senderName": .string("An Nguyễn")])]),
                                    .object(["id": .string("t_90401"), "type": .int(2), "params": .object(["global_msg_id": .string("90401"), "title": .string("Ảnh đẹp"), "senderName": .string("Pin User 4")])]),
                                    .object(["id": .string("t_init"), "type": .int(2), "params": .object(["title": .string("Cũ")])]),
                                ]),
                            ]),
                        ])
                    ),
                    // open 3000704 -> initial friend board refresh (version 2)
                    PinRecorderHarness.httpScript(
                        path: "/api/friendboard/list",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object(["data": .array([]), "version": .int(2), "pinLimit": .int(3)]),
                        ])
                    ),
                    // pin m3 in 1-1 -> uses cached board version 2
                    PinRecorderHarness.httpScript(
                        path: "/api/friendboard/create",
                        method: "GET",
                        json: .object(["error_code": .int(0), "data": .object(["id": .string("ft_90403")])])
                    ),
                    // refresh 1-1 board after pin m3
                    PinRecorderHarness.httpScript(
                        path: "/api/friendboard/list",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "version": .int(3),
                                "pinLimit": .int(3),
                                "data": .array([
                                    .object(["id": .string("ft_90403"), "type": .int(2), "params": .object(["global_msg_id": .string("90403"), "title": .string("Tin sender zero"), "senderName": .string("Khách")])]),
                                ]),
                            ]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("g500704")])]),
                    .object([
                        "cmd": .string("pin"),
                        "args": .object(["conv_id": .string("g500704"), "msg_id": .string("90401"), "async": .bool(true)]),
                    ]),
                    .object(["snapshot": .string("optimistic_own")]),
                    .object(["http_release": .int(1)]),
                    .object(["cmd": .string("await_action")]),
                    .object(["snapshot": .string("after_group_own")]),
                    .object([
                        "cmd": .string("pin_message"),
                        "args": .object(["conv_id": .string("g500704"), "msg_id": .string("90402")]),
                    ]),
                    .object(["snapshot": .string("after_group_friend")]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000704")])]),
                    .object([
                        "cmd": .string("pin_message"),
                        "args": .object(["conv_id": .string("3000704"), "msg_id": .string("90403")]),
                    ]),
                ]
            ),

            // 5. pin_limit: replace-oldest confirm, ok unpins oldest + refreshes + pins + refreshes,
            // cancel does nothing, limit lowered by two -> choose-many card only,
            // confirm blocked while another confirm is shown or in closed conversation.
            PinRecorderHarness.ScenarioDef(
                name: "pin_limit",
                seed: PinRecorderHarness.readySessionSeed(
                    userId: "2000705",
                    displayName: "Pin User 5",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "open_conversation_id": .string("g500705"),
                        "pins": .object([
                            "g500705": .object([
                                "convId": .string("g500705"),
                                "ready": .bool(true),
                                "canPin": .bool(true),
                                "limit": .int(2),
                                "items": .array([
                                    .object(["ref": .string("t_501"), "kind": .string("message"), "title": .string("Mới nhất"), "sender": .string("An"), "msgId": .string("90500")]),
                                    .object(["ref": .string("t_502"), "kind": .string("message"), "title": .string("Ghim cũ nhất"), "sender": .string("Bình"), "msgId": .string("90499")]),
                                ]),
                            ]),
                            "g500706": .object([
                                "convId": .string("g500706"),
                                "ready": .bool(true),
                                "canPin": .bool(true),
                                "limit": .int(1),
                                "items": .array([
                                    .object(["ref": .string("t_600"), "kind": .string("note"), "title": .string("Closed pin"), "sender": .string("An")]),
                                ]),
                            ]),
                        ]),
                        "board_raw_topics": .object([
                            "g500705": .object([
                                "version": .int(5),
                                "topics": .object([
                                    "t_501": .object(["id": .string("t_501"), "type": .int(2)]),
                                    "t_502": .object(["id": .string("t_502"), "type": .int(2)]),
                                ]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    PinRecorderHarness.loginInfoScript(uid: "2000705", displayName: "Pin User 5"),
                    MessageRecorderHarness.profileMeScript(uid: "2000705", displayName: "Pin User 5"),
                    // unpin t_502
                    PinRecorderHarness.httpScript(
                        path: "/api/board/unpinv2",
                        method: "GET",
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                    // refresh after unpin
                    PinRecorderHarness.httpScript(
                        path: "/api/board/pin/list",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "boardVersion": .int(6),
                                "pinLimit": .int(2),
                                "topics": .array([
                                    .object(["id": .string("t_501"), "type": .int(2), "params": .object(["global_msg_id": .string("90500"), "title": .string("Mới nhất")])]),
                                ]),
                            ]),
                        ])
                    ),
                    // pin 90501
                    PinRecorderHarness.httpScript(
                        path: "/api/board/topic/createv2",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["id": .string("t_503")])])
                    ),
                    // refresh after pin
                    PinRecorderHarness.httpScript(
                        path: "/api/board/pin/list",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "boardVersion": .int(7),
                                "pinLimit": .int(2),
                                "topics": .array([
                                    .object(["id": .string("t_503"), "type": .int(2), "params": .object(["global_msg_id": .string("90501"), "title": .string("Tin thay thế")])]),
                                    .object(["id": .string("t_501"), "type": .int(2), "params": .object(["global_msg_id": .string("90500"), "title": .string("Mới nhất")])]),
                                ]),
                            ]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object([
                        "cmd": .string("apply_batch"),
                        "args": .object([
                            "payload": .object([
                                "msgs": .array([
                                    .object([
                                        "msgId": .string("90501"),
                                        "cliMsgId": .string("c90501"),
                                        "uidFrom": .string("2000705"),
                                        "idTo": .string("g500705"),
                                        "dName": .string("Pin User 5"),
                                        "ts": .int(1700000010000),
                                        "msgType": .string("webchat"),
                                        "content": .string("Tin thay thế"),
                                    ]),
                                    .object([
                                        "msgId": .string("90502"),
                                        "cliMsgId": .string("c90502"),
                                        "uidFrom": .string("2000705"),
                                        "idTo": .string("g500705"),
                                        "dName": .string("Pin User 5"),
                                        "ts": .int(1700000011000),
                                        "msgType": .string("webchat"),
                                        "content": .string("Tin khác"),
                                    ]),
                                    .object([
                                        "msgId": .string("90601"),
                                        "cliMsgId": .string("c90601"),
                                        "uidFrom": .string("2000705"),
                                        "idTo": .string("g500706"),
                                        "dName": .string("Pin User 5"),
                                        "ts": .int(1700000012000),
                                        "msgType": .string("webchat"),
                                        "content": .string("Tin closed"),
                                    ]),
                                ]),
                            ]),
                            "default_cmd": .int(502),
                            "increment_unread": .bool(false),
                            "notify_incoming": .bool(false),
                            "persist_conversations": .bool(false),
                        ]),
                    ]),
                    // At limit (2/2) -> replaceOldest confirm
                    .object(["cmd": .string("pin_message"), "args": .object(["conv_id": .string("g500705"), "msg_id": .string("90501")])]),
                    .object(["snapshot": .string("confirm_replace")]),
                    // Another pin_message while confirm is shown -> ignored
                    .object(["cmd": .string("pin_message"), "args": .object(["conv_id": .string("g500705"), "msg_id": .string("90502")])]),
                    // Cancel confirm
                    .object(["cmd": .string("answer_confirm"), "args": .object(["ok": .bool(false)])]),
                    .object(["snapshot": .string("after_cancel")]),
                    // Closed conversation -> ignored
                    .object(["cmd": .string("pin_message"), "args": .object(["conv_id": .string("g500706"), "msg_id": .string("90601")])]),
                    // Trigger replaceOldest again & confirm ok
                    .object(["cmd": .string("pin_message"), "args": .object(["conv_id": .string("g500705"), "msg_id": .string("90501")])]),
                    .object(["cmd": .string("answer_confirm"), "args": .object(["ok": .bool(true)])]),
                    .object(["snapshot": .string("after_replace")]),
                    // Limit lowered by two (3 items > limit 1 -> chooseMany(need: 3))
                    .object([
                        "cmd": .string("pins_state"),
                        "args": .object([
                            "json": .object([
                                "pins": .object([
                                    "convId": .string("g500705"),
                                    "ready": .bool(true),
                                    "canPin": .bool(true),
                                    "limit": .int(1),
                                    "items": .array([
                                        .object(["ref": .string("t_a"), "kind": .string("note"), "title": .string("A")]),
                                        .object(["ref": .string("t_b"), "kind": .string("note"), "title": .string("B")]),
                                        .object(["ref": .string("t_c"), "kind": .string("note"), "title": .string("C")]),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                    .object(["cmd": .string("pin_message"), "args": .object(["conv_id": .string("g500705"), "msg_id": .string("90502")])]),
                ]
            ),

            // 6. pin_fail: create error + replace-unpin error (log shape, refresh, show_card),
            // busy key blocks a second tap while in-flight.
            PinRecorderHarness.ScenarioDef(
                name: "pin_fail",
                seed: PinRecorderHarness.readySessionSeed(
                    userId: "2000706",
                    displayName: "Pin User 6",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "open_conversation_id": .string("g500706"),
                        "pins": .object([
                            "g500706": .object([
                                "convId": .string("g500706"),
                                "ready": .bool(true),
                                "canPin": .bool(true),
                                "limit": .int(5),
                                "items": .array([
                                    .object(["ref": .string("t_601"), "kind": .string("message"), "title": .string("Existing"), "sender": .string("An"), "msgId": .string("90600")]),
                                ]),
                            ]),
                        ]),
                        "board_raw_topics": .object([
                            "g500706": .object([
                                "version": .int(4),
                                "topics": .object([
                                    "t_601": .object(["id": .string("t_601"), "type": .int(2)]),
                                ]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    PinRecorderHarness.loginInfoScript(uid: "2000706", displayName: "Pin User 6"),
                    MessageRecorderHarness.profileMeScript(uid: "2000706", displayName: "Pin User 6"),
                    // 1) createv2 fails (held so busy key blocks a second tap)
                    PinRecorderHarness.httpScript(
                        path: "/api/board/topic/createv2",
                        method: "POST",
                        json: .object(["error_code": .int(500), "error_message": .string("pin server fail")]),
                        hold: true
                    ),
                    // refresh after createv2 error
                    PinRecorderHarness.httpScript(
                        path: "/api/board/pin/list",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "boardVersion": .int(4),
                                "pinLimit": .int(5),
                                "topics": .array([
                                    .object(["id": .string("t_601"), "type": .int(2), "params": .object(["global_msg_id": .string("90600"), "title": .string("Existing"), "senderName": .string("An")])]),
                                ]),
                            ]),
                        ])
                    ),
                    // 2) replace unpin fails
                    PinRecorderHarness.httpScript(
                        path: "/api/board/unpinv2",
                        method: "GET",
                        json: .object(["error_code": .int(114), "error_message": .string("unpin failed")])
                    ),
                    // refresh after replace-unpin error
                    PinRecorderHarness.httpScript(
                        path: "/api/board/pin/list",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "boardVersion": .int(4),
                                "pinLimit": .int(5),
                                "topics": .array([
                                    .object(["id": .string("t_601"), "type": .int(2), "params": .object(["global_msg_id": .string("90600"), "title": .string("Existing"), "senderName": .string("An")])]),
                                ]),
                            ]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object([
                        "cmd": .string("apply_batch"),
                        "args": .object([
                            "payload": .object([
                                "msgs": .array([
                                    .object([
                                        "msgId": .string("90601"),
                                        "cliMsgId": .string("c90601"),
                                        "uidFrom": .string("2000706"),
                                        "idTo": .string("g500706"),
                                        "dName": .string("Pin User 6"),
                                        "ts": .int(1700000010000),
                                        "msgType": .string("webchat"),
                                        "content": .string("Fail pin"),
                                    ]),
                                    .object([
                                        "msgId": .string("90602"),
                                        "cliMsgId": .string("c90602"),
                                        "uidFrom": .string("2000706"),
                                        "idTo": .string("g500706"),
                                        "dName": .string("Pin User 6"),
                                        "ts": .int(1700000011000),
                                        "msgType": .string("webchat"),
                                        "content": .string("Fail replace"),
                                    ]),
                                ]),
                            ]),
                            "default_cmd": .int(502),
                            "increment_unread": .bool(false),
                            "notify_incoming": .bool(false),
                            "persist_conversations": .bool(false),
                        ]),
                    ]),
                    // Start async pin while createv2 is held
                    .object([
                        "cmd": .string("pin"),
                        "args": .object(["conv_id": .string("g500706"), "msg_id": .string("90601"), "async": .bool(true)]),
                    ]),
                    // Second tap while busy -> blocked cleanly (no extra HTTP)
                    .object([
                        "cmd": .string("pin"),
                        "args": .object(["conv_id": .string("g500706"), "msg_id": .string("90601"), "async": .bool(true)]),
                    ]),
                    .object(["snapshot": .string("busy_held")]),
                    .object(["http_release": .int(1)]),
                    .object(["cmd": .string("await_action")]),
                    .object(["snapshot": .string("after_create_fail")]),
                    // Replace-unpin error
                    .object([
                        "cmd": .string("pin"),
                        "args": .object(["conv_id": .string("g500706"), "msg_id": .string("90602"), "replacing": .string("t_601")]),
                    ]),
                ]
            ),

            // 7. pin_resolve_ids: message with only a client id: store lookup & history fetch paths
            // (U6 resolution) reach pinBoardMessage request params.
            PinRecorderHarness.ScenarioDef(
                name: "pin_resolve_ids",
                seed: PinRecorderHarness.readySessionSeed(
                    userId: "2000707",
                    displayName: "Pin User 7",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "contacts": .object([
                            "friends": .array([
                                seedFriend(id: "3000707", name: "Dũng", avatar: "https://cdn.example.invalid/dung.jpg"),
                            ]),
                            "cached_profiles": .object([
                                "3000707": .object(["name": .string("Dũng"), "avatar": .string("https://cdn.example.invalid/dung.jpg")]),
                            ]),
                        ]),
                        "open_conversation_id": .string("3000707"),
                        "history_freshness": .object(["3000707": .string("up_to_date")]),
                        "pins": .object([
                            "3000707": .object([
                                "convId": .string("3000707"),
                                "ready": .bool(true),
                                "canPin": .bool(true),
                                "limit": .int(3),
                                "items": .array([]),
                            ]),
                        ]),
                        "board_raw_topics": .object([
                            "3000707": .object(["version": .int(1), "topics": .object([:])]),
                        ]),
                        "local_conversations": .array([
                            localConv(id: "3000707", isGroup: false, name: "Dũng", members: 2, previewText: "Init", previewTsMs: 1700000001000),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "90701",
                                convId: "3000707",
                                clientId: "c90701",
                                senderId: "2000707",
                                senderName: "Pin User 7",
                                isMine: true,
                                text: "Stored server id",
                                tsMs: 1700000001000
                            ),
                            storedMsg(
                                id: "c90702",
                                convId: "3000707",
                                clientId: "c90702",
                                senderId: "3000707",
                                senderName: "Dũng",
                                isMine: false,
                                text: "Needs history lookup",
                                tsMs: 1700000002000
                            ),
                        ]),
                    ]
                ),
                server: [
                    PinRecorderHarness.loginInfoScript(uid: "2000707", displayName: "Pin User 7"),
                    MessageRecorderHarness.profileMeScript(uid: "2000707", displayName: "Pin User 7"),
                    // Pin 1 (store resolution -> 90701)
                    PinRecorderHarness.httpScript(
                        path: "/api/friendboard/create",
                        method: "GET",
                        json: .object(["error_code": .int(0), "data": .object(["id": .string("ft_701")])])
                    ),
                    PinRecorderHarness.httpScript(
                        path: "/api/friendboard/list",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "version": .int(2),
                                "pinLimit": .int(3),
                                "data": .array([
                                    .object(["id": .string("ft_701"), "type": .int(2), "params": .object(["global_msg_id": .string("90701"), "client_msg_id": .string("c90701"), "title": .string("Stored server id")])]),
                                ]),
                            ]),
                        ])
                    ),
                    // History lookup for c90702
                    PinRecorderHarness.httpScript(
                        path: "/api/preloadconvers/get-last-msgs",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .string(#"{"msgs":[{"cliMsgId":"c90702","globalMsgId":"90702"}]}"#),
                        ])
                    ),
                    // Pin 2 (history resolution -> 90702)
                    PinRecorderHarness.httpScript(
                        path: "/api/friendboard/create",
                        method: "GET",
                        json: .object(["error_code": .int(0), "data": .object(["id": .string("ft_702")])])
                    ),
                    PinRecorderHarness.httpScript(
                        path: "/api/friendboard/list",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "version": .int(3),
                                "pinLimit": .int(3),
                                "data": .array([
                                    .object(["id": .string("ft_702"), "type": .int(2), "params": .object(["global_msg_id": .string("90702"), "client_msg_id": .string("c90702"), "title": .string("Needs history lookup")])]),
                                    .object(["id": .string("ft_701"), "type": .int(2), "params": .object(["global_msg_id": .string("90701"), "client_msg_id": .string("c90701"), "title": .string("Stored server id")])]),
                                ]),
                            ]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object([
                        "cmd": .string("apply_batch"),
                        "args": .object([
                            "payload": .object([
                                "msgs": .array([
                                    .object([
                                        "msgId": .string("c90701"),
                                        "cliMsgId": .string("c90701"),
                                        "uidFrom": .string("2000707"),
                                        "idTo": .string("3000707"),
                                        "dName": .string("Pin User 7"),
                                        "ts": .int(1700000001000),
                                        "msgType": .string("webchat"),
                                        "content": .string("Stored server id"),
                                    ]),
                                    .object([
                                        "msgId": .string("c90702"),
                                        "cliMsgId": .string("c90702"),
                                        "uidFrom": .string("3000707"),
                                        "idTo": .string("2000707"),
                                        "dName": .string("Dũng"),
                                        "ts": .int(1700000002000),
                                        "msgType": .string("webchat"),
                                        "content": .string("Needs history lookup"),
                                    ]),
                                ]),
                            ]),
                            "default_cmd": .int(501),
                            "increment_unread": .bool(false),
                            "notify_incoming": .bool(false),
                            "persist_conversations": .bool(false),
                        ]),
                    ]),
                    .object(["cmd": .string("pin"), "args": .object(["conv_id": .string("3000707"), "msg_id": .string("c90701")])]),
                    .object(["snapshot": .string("after_store_resolve")]),
                    .object(["cmd": .string("pin"), "args": .object(["conv_id": .string("3000707"), "msg_id": .string("c90702")])]),
                ]
            ),

            // 8. unpin_flow: request_unpin texts for message vs note, confirm optimistic removal,
            // raw topic in request, refresh, failure refresh + card, request_unpin_message on/off board.
            PinRecorderHarness.ScenarioDef(
                name: "unpin_flow",
                seed: PinRecorderHarness.readySessionSeed(
                    userId: "2000708",
                    displayName: "Pin User 8",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "open_conversation_id": .string("g500708"),
                        "pins": .object([
                            "g500708": .object([
                                "convId": .string("g500708"),
                                "ready": .bool(true),
                                "canPin": .bool(true),
                                "limit": .int(3),
                                "items": .array([
                                    .object(["ref": .string("t_msg"), "kind": .string("message"), "title": .string("Tin ghim"), "sender": .string("An"), "msgId": .string("90801"), "cliMsgId": .string("c90801")]),
                                    .object(["ref": .string("t_note"), "kind": .string("note"), "title": .string("Ghi chú ghim"), "sender": .string("An")]),
                                ]),
                            ]),
                        ]),
                        "board_raw_topics": .object([
                            "g500708": .object([
                                "version": .int(6),
                                "topics": .object([
                                    "t_msg": .object(["id": .string("t_msg"), "type": .int(2)]),
                                    "t_note": .object(["id": .string("t_note"), "type": .int(0)]),
                                ]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    PinRecorderHarness.loginInfoScript(uid: "2000708", displayName: "Pin User 8"),
                    MessageRecorderHarness.profileMeScript(uid: "2000708", displayName: "Pin User 8"),
                    // 1) Unpin t_note (held to capture optimistic removal)
                    PinRecorderHarness.httpScript(
                        path: "/api/board/unpinv2",
                        method: "GET",
                        json: .object(["error_code": .int(0), "data": .object([:])]),
                        hold: true
                    ),
                    // refresh after t_note unpin
                    PinRecorderHarness.httpScript(
                        path: "/api/board/pin/list",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "boardVersion": .int(7),
                                "pinLimit": .int(3),
                                "topics": .array([
                                    .object(["id": .string("t_msg"), "type": .int(2), "params": .object(["global_msg_id": .string("90801"), "cliMsgId": .string("c90801"), "title": .string("Tin ghim"), "senderName": .string("An")])]),
                                ]),
                            ]),
                        ])
                    ),
                    // 2) Unpin t_msg -> fails
                    PinRecorderHarness.httpScript(
                        path: "/api/board/unpinv2",
                        method: "GET",
                        json: .object(["error_code": .int(500), "error_message": .string("unpin error")])
                    ),
                    // refresh after failure restores t_msg
                    PinRecorderHarness.httpScript(
                        path: "/api/board/pin/list",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "boardVersion": .int(7),
                                "pinLimit": .int(3),
                                "topics": .array([
                                    .object(["id": .string("t_msg"), "type": .int(2), "params": .object(["global_msg_id": .string("90801"), "cliMsgId": .string("c90801"), "title": .string("Tin ghim"), "senderName": .string("An")])]),
                                ]),
                            ]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object([
                        "cmd": .string("apply_batch"),
                        "args": .object([
                            "payload": .object([
                                "msgs": .array([
                                    .object([
                                        "msgId": .string("90801"),
                                        "cliMsgId": .string("c90801"),
                                        "uidFrom": .string("2000708"),
                                        "idTo": .string("g500708"),
                                        "dName": .string("Pin User 8"),
                                        "ts": .int(1700000010000),
                                        "msgType": .string("webchat"),
                                        "content": .string("Tin ghim"),
                                    ]),
                                    .object([
                                        "msgId": .string("90802"),
                                        "cliMsgId": .string("c90802"),
                                        "uidFrom": .string("2000708"),
                                        "idTo": .string("g500708"),
                                        "dName": .string("Pin User 8"),
                                        "ts": .int(1700000011000),
                                        "msgType": .string("webchat"),
                                        "content": .string("Tin chưa ghim"),
                                    ]),
                                ]),
                            ]),
                            "default_cmd": .int(502),
                            "increment_unread": .bool(false),
                            "notify_incoming": .bool(false),
                            "persist_conversations": .bool(false),
                        ]),
                    ]),
                    // request_unpin for message
                    .object(["cmd": .string("request_unpin"), "args": .object(["conv_id": .string("g500708"), "ref": .string("t_msg")])]),
                    .object(["snapshot": .string("confirm_unpin_message")]),
                    .object(["cmd": .string("answer_confirm"), "args": .object(["ok": .bool(false)])]),
                    // request_unpin for note -> confirm ok (async held)
                    .object(["cmd": .string("request_unpin"), "args": .object(["conv_id": .string("g500708"), "ref": .string("t_note")])]),
                    .object(["snapshot": .string("confirm_unpin_note")]),
                    .object(["cmd": .string("answer_confirm"), "args": .object(["ok": .bool(true), "async": .bool(true)])]),
                    .object(["snapshot": .string("optimistic_removed")]),
                    .object(["http_release": .int(1)]),
                    .object(["cmd": .string("await_action")]),
                    .object(["snapshot": .string("after_unpin_note")]),
                    // Unpin failure
                    .object(["cmd": .string("request_unpin"), "args": .object(["conv_id": .string("g500708"), "ref": .string("t_msg")])]),
                    .object(["cmd": .string("answer_confirm"), "args": .object(["ok": .bool(true)])]),
                    .object(["snapshot": .string("after_unpin_fail")]),
                    // request_unpin_message for message on board -> opens confirm, cancel
                    .object(["cmd": .string("request_unpin_message"), "args": .object(["conv_id": .string("g500708"), "msg_id": .string("90801")])]),
                    .object(["snapshot": .string("confirm_from_message")]),
                    .object(["cmd": .string("answer_confirm"), "args": .object(["ok": .bool(false)])]),
                    // request_unpin_message for message NOT on board -> no-op
                    .object(["cmd": .string("request_unpin_message"), "args": .object(["conv_id": .string("g500708"), "msg_id": .string("90802")])]),
                ]
            ),

            // 9. can_pin_rules: board missing / not ready / cannot pin, E2EE, each excluded kind,
            // sending / failed, normal message, plus is_pinned (message vs poll).
            PinRecorderHarness.ScenarioDef(
                name: "can_pin_rules",
                seed: PinRecorderHarness.readySessionSeed(
                    userId: "2000709",
                    displayName: "Pin User 9",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "history_freshness": .object([
                            "g500709": .string("up_to_date"),
                        ]),
                        "local_conversations": .array([
                            localConv(id: "g500709", isGroup: true, name: "Nhóm CanPin", previewText: "Poll", previewTsMs: 1700000011000),
                        ]),
                        "local_messages": .array([
                            storedMsg(id: "90901", convId: "g500709", senderId: "2000709", senderName: "Pin User 9", isMine: true, text: "Tin đã ghim", tsMs: 1700000001000),
                            storedMsg(
                                id: "90902",
                                convId: "g500709",
                                senderId: "2000709",
                                senderName: "Pin User 9",
                                isMine: true,
                                text: "Ảnh thường",
                                tsMs: 1700000002000,
                                kindTag: "photo",
                                kindObj: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/p9.jpg"), "width": .int(80), "height": .int(80)])
                            ),
                            storedMsg(id: "90903", convId: "g500709", senderId: "2000709", senderName: "Pin User 9", isMine: true, text: "E2EE", tsMs: 1700000003000, isE2EE: true),
                            storedMsg(id: "90904", convId: "g500709", senderId: "2000709", senderName: "Pin User 9", isMine: true, text: "", tsMs: 1700000004000, kindTag: "recalled"),
                            storedMsg(
                                id: "90905",
                                convId: "g500709",
                                senderId: "2000709",
                                senderName: "Pin User 9",
                                isMine: true,
                                text: "",
                                tsMs: 1700000005000,
                                kindTag: "call",
                                kindObj: .object(["type": .string("call"), "video": .bool(false), "missed": .bool(true), "duration": .int(0), "title": .string("Cuộc gọi nhỡ"), "detail": .string("")])
                            ),
                            storedMsg(
                                id: "90906",
                                convId: "g500709",
                                senderId: "2000709",
                                senderName: "Pin User 9",
                                isMine: true,
                                text: "",
                                tsMs: 1700000006000,
                                kindTag: "placeholder",
                                kindObj: .object(["type": .string("placeholder"), "symbol": .string("lock"), "text": .string("Chờ giải mã")])
                            ),
                            storedMsg(id: "90907", convId: "g500709", senderId: "2000709", senderName: "Pin User 9", isMine: true, text: "Hệ thống", tsMs: 1700000007000, kindTag: "system"),
                            storedMsg(
                                id: "90908",
                                convId: "g500709",
                                senderId: "2000709",
                                senderName: "Pin User 9",
                                isMine: true,
                                text: "",
                                tsMs: 1700000008000,
                                kindTag: "notice",
                                kindObj: .object(["type": .string("notice"), "symbol": .string("info.circle"), "text": .string("Thông báo")])
                            ),
                            storedMsg(id: "90909", convId: "g500709", senderId: "2000709", senderName: "Pin User 9", isMine: true, text: "Đang gửi", tsMs: 1700000009000, status: "sending"),
                            storedMsg(id: "90910", convId: "g500709", senderId: "2000709", senderName: "Pin User 9", isMine: true, text: "Gửi lỗi", tsMs: 1700000010000, status: "failed"),
                            storedMsg(
                                id: "90911",
                                convId: "g500709",
                                senderId: "2000709",
                                senderName: "Pin User 9",
                                isMine: true,
                                text: "Bình chọn",
                                tsMs: 1700000011000,
                                kindTag: "poll",
                                kindObj: .object(["type": .string("poll"), "question": .string("Bình chọn?"), "header": .string(""), "anonymous": .bool(false), "pollId": .string("p909"), "conversationId": .string("g500709")])
                            ),
                        ]),
                        "pins": .object([
                            "g_not_ready": .object([
                                "convId": .string("g_not_ready"),
                                "ready": .bool(false),
                                "canPin": .bool(true),
                                "limit": .int(3),
                                "items": .array([]),
                            ]),
                            "g_cant_pin": .object([
                                "convId": .string("g_cant_pin"),
                                "ready": .bool(true),
                                "canPin": .bool(false),
                                "limit": .int(3),
                                "items": .array([]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    PinRecorderHarness.loginInfoScript(uid: "2000709", displayName: "Pin User 9"),
                    MessageRecorderHarness.profileMeScript(uid: "2000709", displayName: "Pin User 9"),
                    PinRecorderHarness.httpScript(
                        path: "/api/board/pin/list",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "boardVersion": .int(1),
                                "pinLimit": .int(3),
                                "topics": .array([
                                    .object(["id": .string("t_p1"), "type": .int(2), "params": .object(["global_msg_id": .string("90901"), "title": .string("Tin đã ghim")])]),
                                    .object(["id": .string("t_poll"), "type": .int(3), "params": .object(["global_msg_id": .string("90911"), "title": .string("Bình chọn")])]),
                                ]),
                            ]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("g500709")])]),
                    .object([
                        "cmd": .string("apply_batch"),
                        "args": .object([
                            "payload": .object([
                                "msgs": .array([
                                    .object([
                                        "msgId": .string("90920"),
                                        "cliMsgId": .string("c90920"),
                                        "uidFrom": .string("2000709"),
                                        "idTo": .string("g_missing"),
                                        "dName": .string("Pin User 9"),
                                        "ts": .int(1700000012000),
                                        "msgType": .string("webchat"),
                                        "content": .string("Missing board"),
                                    ]),
                                    .object([
                                        "msgId": .string("90921"),
                                        "cliMsgId": .string("c90921"),
                                        "uidFrom": .string("2000709"),
                                        "idTo": .string("g_not_ready"),
                                        "dName": .string("Pin User 9"),
                                        "ts": .int(1700000013000),
                                        "msgType": .string("webchat"),
                                        "content": .string("Not ready"),
                                    ]),
                                    .object([
                                        "msgId": .string("90922"),
                                        "cliMsgId": .string("c90922"),
                                        "uidFrom": .string("2000709"),
                                        "idTo": .string("g_cant_pin"),
                                        "dName": .string("Pin User 9"),
                                        "ts": .int(1700000014000),
                                        "msgType": .string("webchat"),
                                        "content": .string("Cant pin"),
                                    ]),
                                ]),
                            ]),
                            "default_cmd": .int(502),
                            "increment_unread": .bool(false),
                            "notify_incoming": .bool(false),
                            "persist_conversations": .bool(false),
                        ]),
                    ]),
                    .object(["cmd": .string("can_pin"), "args": .object(["conv_id": .string("g_missing"), "msg_id": .string("90920")])]),
                    .object(["cmd": .string("can_pin"), "args": .object(["conv_id": .string("g_not_ready"), "msg_id": .string("90921")])]),
                    .object(["cmd": .string("can_pin"), "args": .object(["conv_id": .string("g_cant_pin"), "msg_id": .string("90922")])]),
                    .object(["cmd": .string("can_pin"), "args": .object(["conv_id": .string("g500709"), "msg_id": .string("90901")])]),
                    .object(["cmd": .string("can_pin"), "args": .object(["conv_id": .string("g500709"), "msg_id": .string("90902")])]),
                    .object(["cmd": .string("can_pin"), "args": .object(["conv_id": .string("g500709"), "msg_id": .string("90903")])]),
                    .object(["cmd": .string("can_pin"), "args": .object(["conv_id": .string("g500709"), "msg_id": .string("90904")])]),
                    .object(["cmd": .string("can_pin"), "args": .object(["conv_id": .string("g500709"), "msg_id": .string("90905")])]),
                    .object(["cmd": .string("can_pin"), "args": .object(["conv_id": .string("g500709"), "msg_id": .string("90906")])]),
                    .object(["cmd": .string("can_pin"), "args": .object(["conv_id": .string("g500709"), "msg_id": .string("90907")])]),
                    .object(["cmd": .string("can_pin"), "args": .object(["conv_id": .string("g500709"), "msg_id": .string("90908")])]),
                    .object(["cmd": .string("can_pin"), "args": .object(["conv_id": .string("g500709"), "msg_id": .string("90909")])]),
                    .object(["cmd": .string("can_pin"), "args": .object(["conv_id": .string("g500709"), "msg_id": .string("90910")])]),
                    .object(["cmd": .string("can_pin"), "args": .object(["conv_id": .string("g500709"), "msg_id": .string("90911")])]),
                    .object(["cmd": .string("is_pinned"), "args": .object(["conv_id": .string("g500709"), "msg_id": .string("90901")])]),
                    .object(["cmd": .string("is_pinned"), "args": .object(["conv_id": .string("g500709"), "msg_id": .string("90902")])]),
                    .object(["cmd": .string("is_pinned"), "args": .object(["conv_id": .string("g500709"), "msg_id": .string("90911")])]),
                ]
            ),

            // 10. load_pinned: already in window, older only in SQLite loaded via ensureMessageLoaded
            // (by msgId and by cliMsgId), not found, non-message kind.
            PinRecorderHarness.ScenarioDef(
                name: "load_pinned",
                seed: PinRecorderHarness.readySessionSeed(
                    userId: "2000710",
                    displayName: "Pin User 10",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "open_conversation_id": .string("g500710"),
                        "local_messages": .array([
                            storedMsg(id: "91001", convId: "g500710", clientId: "c91001", senderId: "2000710", senderName: "Pin User 10", isMine: true, text: "Cũ 1", tsMs: 1700000001000),
                            storedMsg(id: "91002", convId: "g500710", clientId: "c91002", senderId: "2000710", senderName: "Pin User 10", isMine: true, text: "Cũ 2 (msgId)", tsMs: 1700000002000),
                            storedMsg(id: "91003", convId: "g500710", clientId: "c91003", senderId: "2000710", senderName: "Pin User 10", isMine: true, text: "Cũ 3", tsMs: 1700000003000),
                            storedMsg(id: "91101", convId: "g500711", clientId: "c91101", senderId: "2000710", senderName: "Pin User 10", isMine: true, text: "Cũ 4 (cliMsgId)", tsMs: 1700000001000),
                        ]),
                        "pins": .object([
                            "g500710": .object([
                                "convId": .string("g500710"),
                                "ready": .bool(true),
                                "canPin": .bool(true),
                                "limit": .int(5),
                                "items": .array([
                                    .object(["ref": .string("t_mem"), "kind": .string("message"), "title": .string("In window"), "msgId": .string("91010"), "cliMsgId": .string("c91010")]),
                                    .object(["ref": .string("t_by_msg"), "kind": .string("message"), "title": .string("By msgId"), "msgId": .string("91002"), "cliMsgId": .string("")]),
                                    .object(["ref": .string("t_missing"), "kind": .string("message"), "title": .string("Missing"), "msgId": .string("91999"), "cliMsgId": .string("c91999")]),
                                    .object(["ref": .string("t_note"), "kind": .string("note"), "title": .string("Note"), "msgId": .string("91010"), "cliMsgId": .string("c91010")]),
                                ]),
                            ]),
                            "g500711": .object([
                                "convId": .string("g500711"),
                                "ready": .bool(true),
                                "canPin": .bool(true),
                                "limit": .int(5),
                                "items": .array([
                                    .object(["ref": .string("t_by_cli"), "kind": .string("message"), "title": .string("By cliMsgId"), "msgId": .string(""), "cliMsgId": .string("c91101")]),
                                ]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    PinRecorderHarness.loginInfoScript(uid: "2000710", displayName: "Pin User 10"),
                    MessageRecorderHarness.profileMeScript(uid: "2000710", displayName: "Pin User 10"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object([
                        "cmd": .string("apply_batch"),
                        "args": .object([
                            "payload": .object([
                                "msgs": .array([
                                    .object([
                                        "msgId": .string("91010"),
                                        "cliMsgId": .string("c91010"),
                                        "uidFrom": .string("2000710"),
                                        "idTo": .string("g500710"),
                                        "dName": .string("Pin User 10"),
                                        "ts": .int(1700000010000),
                                        "msgType": .string("webchat"),
                                        "content": .string("Trong cửa sổ"),
                                    ]),
                                    .object([
                                        "msgId": .string("91110"),
                                        "cliMsgId": .string("c91110"),
                                        "uidFrom": .string("2000710"),
                                        "idTo": .string("g500711"),
                                        "dName": .string("Pin User 10"),
                                        "ts": .int(1700000010000),
                                        "msgType": .string("webchat"),
                                        "content": .string("Trong cửa sổ 2"),
                                    ]),
                                ]),
                            ]),
                            "default_cmd": .int(502),
                            "increment_unread": .bool(false),
                            "notify_incoming": .bool(false),
                            "persist_conversations": .bool(false),
                        ]),
                    ]),
                    .object(["snapshot": .string("before_load")]),
                    .object(["cmd": .string("load_pinned"), "args": .object(["conv_id": .string("g500710"), "ref": .string("t_mem")])]),
                    .object(["cmd": .string("load_pinned"), "args": .object(["conv_id": .string("g500710"), "ref": .string("t_by_msg")])]),
                    .object(["snapshot": .string("after_by_msg")]),
                    .object(["cmd": .string("load_pinned"), "args": .object(["conv_id": .string("g500711"), "ref": .string("t_by_cli")])]),
                    .object(["cmd": .string("load_pinned"), "args": .object(["conv_id": .string("g500710"), "ref": .string("t_missing")])]),
                    .object(["cmd": .string("load_pinned"), "args": .object(["conv_id": .string("g500710"), "ref": .string("t_note")])]),
                ]
            ),

            // 11. pin_events: every group & fr act, conversationIds list, 0 / empty ids,
            // acts not in sets, open conversation refreshed vs closed dropped, log shape.
            PinRecorderHarness.ScenarioDef(
                name: "pin_events",
                seed: PinRecorderHarness.readySessionSeed(
                    userId: "2000711",
                    displayName: "Pin User 11",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "contacts": .object([
                            "friends": .array([
                                seedFriend(id: "3000711", name: "An Nguyễn", avatar: "https://cdn.example.invalid/an11.jpg"),
                            ]),
                        ]),
                        "open_conversation_id": .string("g500711"),
                        "history_freshness": .object([
                            "g500711": .string("up_to_date"),
                            "3000711": .string("up_to_date"),
                        ]),
                        "local_conversations": .array([
                            localConv(id: "3000711", isGroup: false, name: "An Nguyễn", members: 2, previewText: "Hi", previewTsMs: 1700000001000),
                        ]),
                        "pins": .object([
                            "g500711": .object(["convId": .string("g500711"), "ready": .bool(true), "canPin": .bool(true), "limit": .int(3), "items": .array([])]),
                            "g500712": .object([
                                "convId": .string("g500712"),
                                "ready": .bool(true),
                                "canPin": .bool(true),
                                "limit": .int(3),
                                "items": .array([.object(["ref": .string("t_old"), "kind": .string("note"), "title": .string("Old")])]),
                            ]),
                            "3000711": .object([
                                "convId": .string("3000711"),
                                "ready": .bool(true),
                                "canPin": .bool(true),
                                "limit": .int(3),
                                "items": .array([.object(["ref": .string("ft_old"), "kind": .string("message"), "title": .string("Old 1-1")])]),
                            ]),
                            "3000712": .object([
                                "convId": .string("3000712"),
                                "ready": .bool(true),
                                "canPin": .bool(true),
                                "limit": .int(3),
                                "items": .array([.object(["ref": .string("ft_old2"), "kind": .string("message"), "title": .string("Old 1-1 2")])]),
                            ]),
                        ]),
                        "board_raw_topics": .object([
                            "g500712": .object([
                                "version": .int(2),
                                "topics": .object([
                                    "t_old": .object(["id": .string("t_old"), "type": .int(0)]),
                                ]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    PinRecorderHarness.loginInfoScript(uid: "2000711", displayName: "Pin User 11"),
                    MessageRecorderHarness.profileMeScript(uid: "2000711", displayName: "Pin User 11"),
                    // 1) new_pin_topic on open g500711
                    PinRecorderHarness.httpScript(
                        path: "/api/board/pin/list",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "boardVersion": .int(10),
                                "pinLimit": .int(3),
                                "topics": .array([
                                    .object(["id": .string("t_ev1"), "type": .int(2), "params": .object(["title": .string("Ev 1")])]),
                                ]),
                            ]),
                        ])
                    ),
                    // 2) unpin_topic on open g500711
                    PinRecorderHarness.httpScript(
                        path: "/api/board/pin/list",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object(["boardVersion": .int(11), "pinLimit": .int(3), "topics": .array([])]),
                        ])
                    ),
                    // 3) reorder_pin_topic on open g500711
                    PinRecorderHarness.httpScript(
                        path: "/api/board/pin/list",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "boardVersion": .int(12),
                                "pinLimit": .int(3),
                                "topics": .array([
                                    .object(["id": .string("t_ev2"), "type": .int(0), "params": .object(["title": .string("Ev 2")])]),
                                ]),
                            ]),
                        ])
                    ),
                    // 4) open 3000711 -> initial friend board refresh
                    PinRecorderHarness.httpScript(
                        path: "/api/friendboard/list",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object(["version": .int(1), "pinLimit": .int(3), "data": .array([])]),
                        ])
                    ),
                    // 5) fr pin_create on open 3000711 -> refresh
                    PinRecorderHarness.httpScript(
                        path: "/api/friendboard/list",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "version": .int(2),
                                "pinLimit": .int(3),
                                "data": .array([
                                    .object(["id": .string("ft_ev1"), "type": .int(2), "params": .object(["title": .string("Friend Ev 1")])]),
                                ]),
                            ]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    // Group acts: open refreshed, closed dropped
                    .object(["cmd": .string("pin_event"), "args": .object(["act_type": .string("group"), "act": .string("new_pin_topic"), "data": .object(["groupId": .string("500711")])])]),
                    .object(["snapshot": .string("after_open_group_event")]),
                    .object(["cmd": .string("pin_event"), "args": .object(["act_type": .string(""), "act": .string("update_pin_topic"), "data": .object(["grid": .string("g500712")])])]),
                    .object(["snapshot": .string("after_closed_group_event")]),
                    .object(["cmd": .string("pin_event"), "args": .object(["act_type": .string("group"), "act": .string("unpin_topic"), "data": .object(["gid": .string("500711")])])]),
                    .object(["cmd": .string("pin_event"), "args": .object(["act_type": .string("group"), "act": .string("reorder_pin_topic"), "data": .object(["groupId": .string("500711")])])]),
                    // fr acts on closed 1-1s + conversationIds list with "0" and ""
                    .object(["cmd": .string("pin_event"), "args": .object(["act_type": .string("fr"), "act": .string("pin_create"), "data": .object(["conversationId": .string(" 3000711 ")])])]),
                    .object(["cmd": .string("pin_event"), "args": .object(["act_type": .string("fr"), "act": .string("pin_unpin"), "data": .object(["conversationId": .string("3000712")])])]),
                    .object(["cmd": .string("pin_event"), "args": .object(["act_type": .string("fr"), "act": .string("pin_reorder"), "data": .object(["conversationId": .string("3000711")])])]),
                    .object(["cmd": .string("pin_event"), "args": .object(["act_type": .string("fr"), "act": .string("pin_force_sync"), "data": .object(["conversationIds": .array([.string("3000711"), .string("0"), .string(""), .string("3000712")])])])]),
                    // Non-matching acts and invalid ids -> []
                    .object(["cmd": .string("pin_event"), "args": .object(["act_type": .string("group"), "act": .string("join"), "data": .object(["groupId": .string("500711")])])]),
                    .object(["cmd": .string("pin_event"), "args": .object(["act_type": .string("fr"), "act": .string("add"), "data": .object(["conversationId": .string("3000711")])])]),
                    .object(["cmd": .string("pin_event"), "args": .object(["act_type": .string("other"), "act": .string("new_pin_topic"), "data": .object(["groupId": .string("500711")])])]),
                    .object(["cmd": .string("pin_event"), "args": .object(["act_type": .string("group"), "act": .string("new_pin_topic"), "data": .object(["groupId": .string("0")])])]),
                    .object(["cmd": .string("pin_event"), "args": .object(["act_type": .string("group"), "act": .string("new_pin_topic"), "data": .object(["groupId": .string("")])])]),
                    .object(["cmd": .string("pin_event"), "args": .object(["act_type": .string("fr"), "act": .string("pin_create"), "data": .object(["conversationId": .string("0")])])]),
                    // Open 1-1 and receive fr pin_create -> refreshed
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000711")])]),
                    .object(["cmd": .string("pin_event"), "args": .object(["act_type": .string("fr"), "act": .string("pin_create"), "data": .object(["conversationId": .string("3000711")])])]),
                ]
            ),

            // 12. pins_state: adapter state shape; invalid/empty ignored; same list twice -> no change; updated list applied.
            PinRecorderHarness.ScenarioDef(
                name: "pins_state",
                seed: PinRecorderHarness.readySessionSeed(
                    userId: "2000712",
                    displayName: "Pin User 12",
                    suppress: ["ws", "long_poll"]
                ),
                server: [
                    PinRecorderHarness.loginInfoScript(uid: "2000712", displayName: "Pin User 12"),
                    MessageRecorderHarness.profileMeScript(uid: "2000712", displayName: "Pin User 12"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    // Invalid / empty convId -> ignored
                    .object(["cmd": .string("pins_state"), "args": .object(["json": .object([:])])]),
                    .object(["cmd": .string("pins_state"), "args": .object(["json": .object(["pins": .object(["convId": .string("")])])])]),
                    .object([
                        "cmd": .string("pins_state"),
                        "args": .object([
                            "json": .object([
                                "pins": .object([
                                    "convId": .string("g500712"),
                                    "ready": .bool(true),
                                    "canPin": .bool(true),
                                    "limit": .int(4),
                                    "items": .array([
                                        .object([
                                            "ref": .string("t_s1"),
                                            "kind": .string("message"),
                                            "title": .string("Tin adapter"),
                                            "sender": .string("An"),
                                            "thumb": .string("https://cdn.example.invalid/s1.jpg"),
                                            "msgId": .string("91201"),
                                            "cliMsgId": .string("c91201"),
                                        ]),
                                        .object([
                                            "ref": .string("t_s2"),
                                            "kind": .string("reminder"),
                                            "title": .string("Nhắc hẹn"),
                                            "sender": .string("Bình"),
                                        ]),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                    .object(["snapshot": .string("after_first")]),
                    // Exact same list again -> unchanged
                    .object([
                        "cmd": .string("pins_state"),
                        "args": .object([
                            "json": .object([
                                "pins": .object([
                                    "convId": .string("g500712"),
                                    "ready": .bool(true),
                                    "canPin": .bool(true),
                                    "limit": .int(4),
                                    "items": .array([
                                        .object([
                                            "ref": .string("t_s1"),
                                            "kind": .string("message"),
                                            "title": .string("Tin adapter"),
                                            "sender": .string("An"),
                                            "thumb": .string("https://cdn.example.invalid/s1.jpg"),
                                            "msgId": .string("91201"),
                                            "cliMsgId": .string("c91201"),
                                        ]),
                                        .object([
                                            "ref": .string("t_s2"),
                                            "kind": .string("reminder"),
                                            "title": .string("Nhắc hẹn"),
                                            "sender": .string("Bình"),
                                        ]),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                    .object(["snapshot": .string("after_same")]),
                    // Updated list
                    .object([
                        "cmd": .string("pins_state"),
                        "args": .object([
                            "json": .object([
                                "pins": .object([
                                    "convId": .string("g500712"),
                                    "ready": .bool(true),
                                    "canPin": .bool(false),
                                    "limit": .int(2),
                                    "items": .array([]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]
            ),
        ]
    }
}

private enum PinRecorderHarness {
    struct ScenarioDef {
        let name: String
        let seed: CaseJSON
        let server: [CaseJSON]
        let steps: [CaseJSON]
        var slow: Bool = false
    }

    enum RecorderError: Error, CustomStringConvertible {
        case timeout(scenario: String, detail: String)
        case invalidSeed(scenario: String, detail: String)
        case invalidStep(scenario: String, detail: String)

        var description: String {
            switch self {
            case .timeout(let s, let d): return "PinRecorder timeout [\(s)]: \(d)"
            case .invalidSeed(let s, let d): return "PinRecorder invalidSeed [\(s)]: \(d)"
            case .invalidStep(let s, let d): return "PinRecorder invalidStep [\(s)]: \(d)"
            }
        }
    }

    static func httpScript(
        path: String,
        method: String = "GET",
        json: CaseJSON,
        hold: Bool = false,
        repeatResponse: Bool = false
    ) -> CaseJSON {
        var obj: [String: CaseJSON] = [
            "kind": .string("http"),
            "path": .string(path),
            "method": .string(method),
            "response": .object([
                "status": .int(200),
                "json": json,
            ]),
        ]
        if hold { obj["hold"] = .bool(true) }
        if repeatResponse { obj["repeat"] = .bool(true) }
        return .object(obj)
    }

    static func loginInfoScript(
        uid: String,
        zpwSek: String = "saved.200.a0.sek_u4",
        displayName: String = "Pin User",
        send2MeId: String? = nil
    ) -> CaseJSON {
        var serviceMap: [String: CaseJSON] = [:]
        for key in ZaloDomains.defaultServiceMapV3.keys {
            serviceMap[key] = .array([.string("http://fake")])
        }
        serviceMap["friend_board"] = .array([.string("http://fake")])
        return httpScript(
            path: "/api/login/getLoginInfo",
            json: .object([
                "error_code": .int(0),
                "data": .object([
                    "uid": .string(uid),
                    "display_name": .string(displayName),
                    "zpw_sek": .string(zpwSek),
                    "zpw_enk": .string("0123456789abcdef"),
                    "dkey": .string("dkey_\(uid)"),
                    "send2me_id": .string(send2MeId ?? "9\(uid)"),
                    "need_sync_msg": .bool(false),
                    "zpw_ws": .array([.string("ws://fake")]),
                    "zpw_service_map_v3": .object(serviceMap),
                ]),
            ])
        )
    }

    static func readySessionSeed(
        userId: String,
        displayName: String = "Pin User",
        avatar: String = "https://cdn.example.invalid/me.jpg",
        phone: String = "+84900000100",
        send2MeId: String? = nil,
        zpwEnk: String = "0123456789abcdef",
        zpwSek: String = "saved.200.a0.sek_u4",
        suppress: [String] = ["long_poll"],
        wsAuthManual: Bool = true,
        extras: [String: CaseJSON] = [:]
    ) -> CaseJSON {
        let base = MessageRecorderHarness.readySessionSeed(
            userId: userId,
            displayName: displayName,
            avatar: avatar,
            phone: phone,
            send2MeId: send2MeId,
            zpwEnk: zpwEnk,
            zpwSek: zpwSek,
            suppress: suppress,
            wsAuthManual: wsAuthManual,
            extras: extras
        )
        var dict = base.objectValue ?? [:]
        let domains = defaultFakeDomainsJSON()
        dict["domains"] = domains
        if var saved = dict["saved_session"]?.objectValue {
            saved["domains"] = domains
            dict["saved_session"] = .object(saved)
        }
        return .object(dict)
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
            .appendingPathComponent("olaz-pin-recorder-\(scenario.name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let storage = RecorderStorageIsolation(prefix: "olaz.pin-recorder")
        EngineLog.shared.onAppend = nil

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

        func toFoundationDict(_ json: CaseJSON) -> [String: Any]? {
            let sub = substituteRuntimeURLs(json)
            return (try? JSONSerialization.jsonObject(with: Data(sub.canonicalString().utf8))) as? [String: Any]
        }

        let seededUserId = scenario.seed["saved_session"]?["plainAccount"]?["userId"]?.stringValue
        if let saved = scenario.seed["saved_session"], saved != .null {
            let sub = substituteRuntimeURLs(saved)
            let fileURL = dataDir.appendingPathComponent("native-session.json")
            try Data(sub.canonicalString().utf8).write(to: fileURL, options: .atomic)
        }

        if let uid = seededUserId, !uid.isEmpty {
            try await seedSQLiteStore(userId: uid, dataDir: dataDir, seed: substituteRuntimeURLs(scenario.seed))
        }

        let domainsJSON = substituteRuntimeURLs(scenario.seed["domains"] ?? defaultFakeDomainsJSON())
        let domains = try JSONDecoder().decode(ZaloDomains.self, from: Data(domainsJSON.canonicalString().utf8))
        try assertOnlyLocalFakeHosts(domains, scenario: scenario.name, stage: "initial seed")

        let engine = ZaloEngine(
            dataDirectory: dataDir,
            useKeychain: false,
            domains: domains,
            userDefaultsSuiteName: storage.userDefaultsSuiteName,
            cookieStorage: storage.cookieStorage
        )

        defer {
            EngineLog.shared.onAppend = nil
            engine.cancelTasksForRecording()
            engine.transportSettleTrace = nil
            server.stop()
            storage.cleanup()
            try? FileManager.default.removeItem(at: dataDir)
        }

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
        if let detailsObj = scenario.seed["cached_group_details"]?.objectValue {
            var seededDetails: [String: [String: Any]] = [:]
            for (k, v) in detailsObj {
                if let parsed = toFoundationDict(v) {
                    seededDetails[k] = parsed
                }
            }
            engine.cachedGroupDetails = seededDetails
        }
        if let memberCacheObj = scenario.seed["group_member_cache"]?.objectValue {
            var seededCache: [String: [MentionCandidate]] = [:]
            for (gid, arrVal) in memberCacheObj {
                let arr = substituteRuntimeURLs(arrVal).arrayValue ?? []
                seededCache[gid] = arr.compactMap { row in
                    guard let id = row["id"]?.stringValue else { return nil }
                    let name = row["name"]?.stringValue ?? ""
                    let avt = row["avatar"]?.stringValue.flatMap(URL.init(string:))
                    let isAll = row["is_all"]?.boolValue ?? false
                    return MentionCandidate(id: id, name: name, avatar: avt, isAll: isAll)
                }
            }
            engine.groupMemberCache = seededCache
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
        if let pinsObj = scenario.seed["pins"]?.objectValue {
            for (convId, listVal) in pinsObj {
                if let listDict = toFoundationDict(listVal) {
                    engine.pins[convId] = PinnedList(json: listDict)
                }
            }
        }
        if let rawTopicsObj = scenario.seed["board_raw_topics"]?.objectValue {
            for (convId, entry) in rawTopicsObj {
                let version = entry["version"]?.int64Value ?? 0
                var topicsMap: [String: [String: Any]] = [:]
                if let tObj = entry["topics"]?.objectValue {
                    for (tid, tVal) in tObj {
                        if let tDict = toFoundationDict(tVal) {
                            topicsMap[tid] = tDict
                        }
                    }
                }
                engine.cachedBoardRawTopics[convId] = (version: version, topics: topicsMap)
            }
        }

        var bootstrapLogs: [String] = []
        var sendLogs: [String] = []
        var actionLogs: [String] = []
        var groupLogs: [String] = []
        var pinLogs: [String] = []
        var results: [String: CaseJSON] = [:]

        func installLogHooks(forwardingTo engineAppend: ((String) -> Void)?) {
            EngineLog.shared.onAppend = { rawLine in
                engineAppend?(rawLine)
                if let sp = rawLine.firstIndex(of: " ") {
                    let msg = String(rawLine[rawLine.index(after: sp)...])
                    if msg.hasPrefix("bootstrap: ") { bootstrapLogs.append(msg) }
                    if msg.hasPrefix("sendText ") { sendLogs.append(msg) }
                    if msg.hasPrefix("react failed") || msg.hasPrefix("recall failed") || msg.hasPrefix("autodelete: ") {
                        actionLogs.append(msg)
                    }
                    if msg.hasPrefix("group create failed: ")
                        || msg.hasPrefix("group avatar upload failed: ")
                        || msg.hasPrefix("rename group failed: ")
                        || msg.hasPrefix("invite group members failed: ")
                        || msg.hasPrefix("kick group member failed: ")
                        || msg.hasPrefix("leave group failed: ")
                        || msg.hasPrefix("group admin: failed code=")
                    {
                        groupLogs.append(msg)
                    }
                    if msg.hasPrefix("pins: ") {
                        pinLogs.append(msg)
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
            case "refresh_board_pins", "pin_topic":
                return true
            case "start_ws":
                return !suppressedTransports.contains("ws")
            case "start_long_poll":
                return !suppressedTransports.contains("long_poll")
            default:
                return false
            }
        }

        let transitionRecorder = PinTransitionRecorder(scenarioName: scenario.name) {
            normalizeRecordedURLs(await PinSnapshot.capture(from: engine))
        }

        engine.stateTrace = { [weak transitionRecorder] in
            transitionRecorder?.recordTransition()
        }
        engine.transportSettleTrace = {
            settleCount += 1
            notifySignal()
        }

        @MainActor
        func waitForCondition(timeoutMs: Int, description: String, _ predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
            while !predicate() {
                let remaining = deadline - ContinuousClock.now
                if remaining <= .zero {
                    throw RecorderError.timeout(scenario: scenario.name, detail: "timed out waiting for \(description)")
                }
                let waiterId = UUID()
                let timeoutTask = Task { @MainActor in
                    try? await Task.sleep(for: min(remaining, .milliseconds(25)))
                    if let cont = signalWaiters.removeValue(forKey: waiterId) {
                        cont.resume()
                    }
                }
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    signalWaiters[waiterId] = cont
                }
                timeoutTask.cancel()
            }
        }

        @MainActor
        func findMessage(convId: String, msgId: String) -> ChatMessage? {
            engine.messages[convId]?.first { $0.id == msgId || $0.clientId == msgId }
        }

        transitionRecorder.recordTransition()

        var snapshots: [String: CaseJSON] = [:]

        for (stepIndex, step) in scenario.steps.enumerated() {
            if let cmd = step["cmd"]?.stringValue {
                let args = step["args"]
                let savedNowMs = engine.nowMs
                if let ms = step["now_ms"]?.int64Value {
                    engine.nowMs = { ms }
                }
                var keepNowMsForAsync = false
                defer {
                    if !keepNowMsForAsync {
                        engine.nowMs = savedNowMs
                    }
                }
                switch cmd {
                case "start":
                    engine.start()
                    let engineAppend = EngineLog.shared.onAppend
                    installLogHooks(forwardingTo: engineAppend)
                    transitionRecorder.advanceSearchToLatestSyncState()
                case "open":
                    _ = await engine.bootTask?.value
                    let id = args?["id"]?.stringValue ?? ""
                    engine.openConversation(id)
                    _ = await engine.openConversationTask?.value
                    _ = await engine.persistConversationsTask?.value
                case "close":
                    engine.closeConversation()
                case "apply_batch":
                    _ = await engine.bootTask?.value
                    let payload = substituteRuntimeURLs(args?["payload"] ?? .object([:])).toFoundation()
                    let defaultCmd = UInt16(args?["default_cmd"]?.int64Value ?? 0)
                    let fallbackConvId = args?["fallback_conv_id"]?.stringValue
                    let isGroupHint = args?["is_group_hint"]?.boolValue
                    let incrementUnread = args?["increment_unread"]?.boolValue ?? false
                    let notifyIncoming = args?["notify_incoming"]?.boolValue ?? false
                    let persistConvs = args?["persist_conversations"]?.boolValue ?? true
                    let probeFreshness = args?["probe_freshness"]?.boolValue ?? false
                    _ = await engine.applyBatchResponse(
                        payload,
                        defaultCmd: defaultCmd,
                        fallbackConvId: fallbackConvId,
                        isGroupHint: isGroupHint,
                        incrementUnread: incrementUnread,
                        notifyIncoming: notifyIncoming,
                        persistConversations: persistConvs,
                        probeFreshness: probeFreshness
                    )
                    _ = await engine.persistConversationsTask?.value
                case "refresh_board":
                    _ = await engine.bootTask?.value
                    let convId = args?["conv_id"]?.stringValue ?? ""
                    await engine.refreshBoardPins(for: convId)
                case "pin_message":
                    _ = await engine.bootTask?.value
                    let convId = args?["conv_id"]?.stringValue ?? ""
                    let msgId = args?["msg_id"]?.stringValue ?? ""
                    guard let msg = findMessage(convId: convId, msgId: msgId) else {
                        throw RecorderError.invalidStep(scenario: scenario.name, detail: "pin_message missing msg \(msgId) in \(convId)")
                    }
                    engine.pinMessage(msg)
                    await engine.awaitMessageActionTasksForRecording()
                case "pin":
                    _ = await engine.bootTask?.value
                    let convId = args?["conv_id"]?.stringValue ?? ""
                    let msgId = args?["msg_id"]?.stringValue ?? ""
                    let replacing = args?["replacing"]?.stringValue
                    let isAsync = args?["async"]?.boolValue ?? false
                    guard let msg = findMessage(convId: convId, msgId: msgId) else {
                        throw RecorderError.invalidStep(scenario: scenario.name, detail: "pin missing msg \(msgId) in \(convId)")
                    }
                    if isAsync {
                        let heldBefore = server.heldHTTPCount()
                        let tasksBefore = engine.messageActionTasks.count
                        engine.pin(msg, replacing: replacing)
                        if engine.messageActionTasks.count > tasksBefore {
                            let reachedHeld = await server.waitForHeldHTTPRequests(atLeast: heldBefore + 1, timeoutMs: 2000)
                            if !reachedHeld && !engine.messageActionTasks.isEmpty {
                                try await waitForCondition(timeoutMs: 2000, description: "pin held HTTP") {
                                    server.heldHTTPCount() > heldBefore || engine.messageActionTasks.isEmpty
                                }
                            }
                        }
                        if !engine.messageActionTasks.isEmpty {
                            keepNowMsForAsync = true
                        }
                    } else {
                        engine.pin(msg, replacing: replacing)
                        await engine.awaitMessageActionTasksForRecording()
                    }
                case "await_action":
                    await engine.awaitMessageActionTasksForRecording()
                    engine.nowMs = { Int64(Date().timeIntervalSince1970 * 1000) }
                case "request_unpin":
                    _ = await engine.bootTask?.value
                    let convId = args?["conv_id"]?.stringValue ?? ""
                    let ref = args?["ref"]?.stringValue ?? ""
                    guard let item = engine.pins[convId]?.items.first(where: { $0.ref == ref }) else {
                        throw RecorderError.invalidStep(scenario: scenario.name, detail: "request_unpin missing ref \(ref) in \(convId)")
                    }
                    engine.requestUnpin(item, in: convId)
                case "request_unpin_message":
                    _ = await engine.bootTask?.value
                    let convId = args?["conv_id"]?.stringValue ?? ""
                    let msgId = args?["msg_id"]?.stringValue ?? ""
                    guard let msg = findMessage(convId: convId, msgId: msgId) else {
                        throw RecorderError.invalidStep(scenario: scenario.name, detail: "request_unpin_message missing msg \(msgId) in \(convId)")
                    }
                    engine.requestUnpin(msg)
                case "answer_confirm":
                    _ = await engine.bootTask?.value
                    let ok = args?["ok"]?.boolValue ?? false
                    let isAsync = args?["async"]?.boolValue ?? false
                    if let confirm = engine.messageConfirm {
                        if isAsync {
                            let heldBefore = server.heldHTTPCount()
                            let tasksBefore = engine.messageActionTasks.count
                            engine.answerMessageConfirm(confirm, ok: ok)
                            if engine.messageActionTasks.count > tasksBefore {
                                let reachedHeld = await server.waitForHeldHTTPRequests(atLeast: heldBefore + 1, timeoutMs: 2000)
                                if !reachedHeld && !engine.messageActionTasks.isEmpty {
                                    try await waitForCondition(timeoutMs: 2000, description: "answer_confirm held HTTP") {
                                        server.heldHTTPCount() > heldBefore || engine.messageActionTasks.isEmpty
                                    }
                                }
                            }
                            if !engine.messageActionTasks.isEmpty {
                                keepNowMsForAsync = true
                            }
                        } else {
                            engine.answerMessageConfirm(confirm, ok: ok)
                            await engine.awaitMessageActionTasksForRecording()
                        }
                    }
                case "load_pinned":
                    _ = await engine.bootTask?.value
                    let convId = args?["conv_id"]?.stringValue ?? ""
                    let ref = args?["ref"]?.stringValue ?? ""
                    guard let item = engine.pins[convId]?.items.first(where: { $0.ref == ref }) else {
                        throw RecorderError.invalidStep(scenario: scenario.name, detail: "load_pinned missing ref \(ref) in \(convId)")
                    }
                    let res = await engine.loadPinnedMessage(item, in: convId)
                    results["\(stepIndex)"] = res.map(CaseJSON.string) ?? .null
                case "pin_event":
                    _ = await engine.bootTask?.value
                    let actType = args?["act_type"]?.stringValue ?? ""
                    let act = args?["act"]?.stringValue ?? ""
                    let dataDict = toFoundationDict(args?["data"] ?? .object([:])) ?? [:]
                    let convs = ZaloWireParser.pinTopicEventConversations(actType: actType, act: act, data: dataDict)
                    results["\(stepIndex)"] = .array(convs.map(CaseJSON.string))
                    for cid in convs {
                        engine.handlePinTopicEvent(conversationId: cid)
                    }
                    await engine.awaitMessageActionTasksForRecording()
                case "pins_state":
                    _ = await engine.bootTask?.value
                    let stateDict = toFoundationDict(args?["json"] ?? .object([:])) ?? [:]
                    engine.handlePins(state: stateDict)
                case "can_pin":
                    _ = await engine.bootTask?.value
                    let convId = args?["conv_id"]?.stringValue ?? ""
                    let msgId = args?["msg_id"]?.stringValue ?? ""
                    guard let msg = findMessage(convId: convId, msgId: msgId) else {
                        throw RecorderError.invalidStep(scenario: scenario.name, detail: "can_pin missing msg \(msgId) in \(convId)")
                    }
                    results["\(stepIndex)"] = .bool(engine.canPinMessage(msg))
                case "is_pinned":
                    _ = await engine.bootTask?.value
                    let convId = args?["conv_id"]?.stringValue ?? ""
                    let msgId = args?["msg_id"]?.stringValue ?? ""
                    guard let msg = findMessage(convId: convId, msgId: msgId) else {
                        throw RecorderError.invalidStep(scenario: scenario.name, detail: "is_pinned missing msg \(msgId) in \(convId)")
                    }
                    results["\(stepIndex)"] = .bool(engine.isPinned(msg))
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
                try await server.pushWebSocketActions(count: Int(pushCount), timeoutMs: timeoutMs)
            } else if let releaseCount = step["http_release"]?.int64Value {
                let timeoutMs = Int(step["timeout_ms"]?.int64Value ?? 5000)
                try await server.releaseHeldHTTPResponses(count: Int(releaseCount), timeoutMs: timeoutMs)
            } else if let label = step["snapshot"]?.stringValue {
                await engine.settleForRecording()
                await Task.yield()
                let snap = await PinSnapshot.capture(
                    from: engine,
                    bootstrapLogs: bootstrapLogs,
                    sendLogs: sendLogs,
                    actionLogs: actionLogs,
                    results: results,
                    groupLogs: groupLogs,
                    pinLogs: pinLogs
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

        let finalState = normalizeRecordedURLs(await PinSnapshot.capture(
            from: engine,
            bootstrapLogs: bootstrapLogs,
            sendLogs: sendLogs,
            actionLogs: actionLogs,
            results: results,
            groupLogs: groupLogs,
            pinLogs: pinLogs
        ))

        let requests = server.canonicalRequests().map { normalizeRecordedURLs($0) }

        engine.cancelTasksForRecording()
        engine.transportSettleTrace = nil
        server.stop()
        await engine.finishTearDownForRecording()

        if server.hadUnscriptedRequest {
            let unscripted = requests.filter { $0["unscripted"]?.boolValue == true }
            XCTFail("\(scenario.name): unscripted request reached fake server: \(CaseJSON.array(unscripted).canonicalString())")
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
    }

    @MainActor
    private static func seedSQLiteStore(userId: String, dataDir: URL, seed: CaseJSON) async throws {
        let dbURL = dataDir
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(userId, isDirectory: true)
            .appendingPathComponent("history.sqlite3")
        let store = try ZaloSQLiteStore(path: dbURL.path)
        try await store.setPreferenceString(key: ZaloWebKitMigrator.donePrefKey, value: "1")
        if let prefs = seed["prefs"]?.objectValue {
            for (k, v) in prefs {
                if let s = v.stringValue {
                    try await store.setPreferenceString(key: k, value: s)
                }
            }
        }
        if let arr = seed["pinned_ids"]?.arrayValue {
            try await store.setPreferenceStrings(key: "pinnedIds", value: arr.compactMap(\.stringValue))
        }
        if let arr = seed["archived_ids"]?.arrayValue {
            try await store.setPreferenceStrings(key: "archivedIds", value: arr.compactMap(\.stringValue))
        }
        if let arr = seed["unread_marks"]?.arrayValue {
            try await store.setPreferenceStrings(key: "unreadMarks", value: arr.compactMap(\.stringValue))
        }
        if let arr = seed["hidden_ids"]?.arrayValue {
            try await store.setPreferenceStrings(key: "hiddenIds", value: arr.compactMap(\.stringValue))
        }
        if let ranks = seed["activity_ranks"]?.objectValue {
            var dict: [String: Int] = [:]
            for (k, v) in ranks {
                if let n = v.int64Value { dict[k] = Int(n) }
            }
            if !dict.isEmpty, let data = try? JSONSerialization.data(withJSONObject: dict) {
                try await store.setPreferenceData(key: "activityRanks", data: data)
            }
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
            if let gidMap = contacts["gid_to_uid_map"]?.objectValue {
                let raw = gidMap.compactMapValues(\.stringValue)
                if !raw.isEmpty, let data = try? JSONSerialization.data(withJSONObject: raw) {
                    try await store.setPreferenceData(key: "gidToUidMap", data: data)
                }
            } else if let fg = contacts["friend_global_ids"]?.objectValue {
                var inverted: [String: String] = [:]
                for (uid, gidVal) in fg {
                    if let gid = gidVal.stringValue { inverted[gid] = uid }
                }
                if !inverted.isEmpty, let data = try? JSONSerialization.data(withJSONObject: inverted) {
                    try await store.setPreferenceData(key: "gidToUidMap", data: data)
                }
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
    }

    private static func extractInitialSecretKey(from seed: CaseJSON) -> Data? {
        guard let enk = seed["saved_session"]?["plainAccount"]?["zpwEnk"]?.stringValue,
              !enk.isEmpty else { return nil }
        let key = ZaloCrypto.parseSecretKey(enk)
        return (key.count == 16 || key.count == 32) ? key : nil
    }

    private static func defaultFakeDomainsJSON() -> CaseJSON {
        var candidates: [String: CaseJSON] = [:]
        for key in ZaloDomains.defaultServiceMapV3.keys {
            candidates[key] = .array([.string("http://fake")])
        }
        candidates["friend_board"] = .array([.string("http://fake")])
        return .object([
            "auth": .string("http://fake"),
            "wpaChat": .string("http://fake"),
            "lpChat": .string("http://fake"),
            "lpControl": .string("http://fake"),
            "ws": .array([.string("ws://fake")]),
            "serviceCandidates": .object(candidates),
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

private final class PinTransitionRecorder: @unchecked Sendable {
    private let scenarioName: String
    private let captureState: @MainActor () async -> CaseJSON
    private var history: [CaseJSON] = []
    private var lastSerialized: String?
    private var searchFromIndex = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(scenarioName: String, captureState: @escaping @MainActor () async -> CaseJSON) {
        self.scenarioName = scenarioName
        self.captureState = captureState
    }

    @MainActor
    func advanceSearchToLatestSyncState() {
        recordTransition()
        searchFromIndex = max(0, history.count - 1)
    }

    @MainActor
    func recordTransition() {
        Task { @MainActor in
            let snap = await captureState()
            let serialized = snap.canonicalString()
            if serialized != lastSerialized {
                lastSerialized = serialized
                history.append(snap)
                let pending = waiters
                waiters.removeAll()
                for cont in pending.values {
                    cont.resume()
                }
            }
        }
    }

    @MainActor
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
                throw PinRecorderHarness.RecorderError.timeout(
                    scenario: scenarioName,
                    detail: "timed out awaiting \(pred.canonicalString()); latest phase: \(history.last?["phase"]?.canonicalString() ?? "none")"
                )
            }
            let waiterId = UUID()
            let timeoutTask = Task { @MainActor in
                try? await Task.sleep(for: min(remaining, .milliseconds(25)))
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
