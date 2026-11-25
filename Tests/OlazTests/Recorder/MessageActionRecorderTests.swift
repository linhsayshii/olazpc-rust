import Foundation
import XCTest
@testable import Olaz

final class MessageActionRecorderTests: XCTestCase {
    func testMessageActionScenarios() async throws {
        try await MessageActionRecorderHarness.runDomainSuite(
            domain: "message_actions",
            scenarios: Self.messageActionScenarios()
        )
    }

    // MARK: - Helpers

    private static func storedMsg(
        id: String,
        convId: String,
        clientId: String? = nil,
        senderId: String,
        senderName: String = "Alice",
        senderAvatar: String = "https://cdn.example.invalid/a.jpg",
        isMine: Bool = false,
        text: String,
        kind: CaseJSON? = nil,
        kindTag: String = "text",
        tsMs: Int64,
        status: String = "sent",
        isE2EE: Bool = false,
        reactions: CaseJSON? = nil,
        menu: CaseJSON? = nil,
        quote: CaseJSON? = nil,
        buttons: CaseJSON? = nil,
        ttl: Int64? = nil
    ) -> CaseJSON {
        let effectiveClientId = clientId ?? "cli_\(id)"
        var rawObj: [String: CaseJSON] = [
            "id": .string(id),
            "conversationId": .string(convId),
            "clientId": .string(effectiveClientId),
            "senderId": .string(senderId),
            "senderName": .string(senderName),
            "senderAvatar": .string(senderAvatar),
            "isMine": .bool(isMine),
            "text": .string(text),
            "date": .int(tsMs),
            "status": .string(status),
            "isE2EE": .bool(isE2EE),
            "kind": kind ?? .object(["type": .string(kindTag)]),
        ]
        if let reactions { rawObj["reactions"] = reactions }
        if let menu { rawObj["menu"] = menu }
        if let quote { rawObj["quote"] = quote }
        if let buttons { rawObj["buttons"] = buttons }
        if let ttl { rawObj["ttl"] = .int(ttl) }

        return .object([
            "id": .string(id),
            "conv_id": .string(convId),
            "client_id": .string(effectiveClientId),
            "sender_id": .string(senderId),
            "sender_name": .string(senderName),
            "sender_avatar": .string(senderAvatar),
            "is_mine": .bool(isMine),
            "text": .string(text),
            "kind_tag": .string(kindTag),
            "ts_ms": .int(tsMs),
            "status": .string(status),
            "raw_json": .object(rawObj),
        ])
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

    // MARK: - Scenarios

    private static func messageActionScenarios() -> [MessageActionRecorderHarness.ScenarioDef] {
        [
            // 1. react_add: new reaction on a received message: optimistic count, request params
            // (rIcon, rType, msgType, client id), stored row, seen keys.
            MessageActionRecorderHarness.ScenarioDef(
                name: "react_add",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000601",
                    displayName: "Action User 1",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(6000000000001),
                        "history_freshness": .object(["3000601": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(
                                id: "3000601",
                                name: "Alice",
                                previewText: "React to me",
                                previewTsMs: 1700000001000
                            ),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "9001001",
                                convId: "3000601",
                                clientId: "c9001001",
                                senderId: "3000601",
                                senderName: "Alice",
                                isMine: false,
                                text: "React to me",
                                tsMs: 1700000001000
                            ),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000601", displayName: "Action User 1"),
                    MessageRecorderHarness.profileMeScript(uid: "2000601", displayName: "Action User 1"),
                    MessageActionRecorderHarness.httpScript(
                        path: "/api/message/reaction",
                        method: "POST",
                        hold: true,
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000601")])]),
                    .object([
                        "cmd": .string("react"),
                        "now_ms": .int(1700000010000),
                        "args": .object([
                            "conv_id": .string("3000601"),
                            "msg_id": .string("9001001"),
                            "emoji": .string("❤️"),
                            "async": .bool(true),
                        ]),
                    ]),
                    .object(["snapshot": .string("optimistic")]),
                    .object(["http_release": .int(1)]),
                    .object(["cmd": .string("await_action")]),
                ]
            ),

            // 2. react_toggle_off: same emoji again: rType -1, empty icon, count drops.
            MessageActionRecorderHarness.ScenarioDef(
                name: "react_toggle_off",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000602",
                    displayName: "Action User 2",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(6000000000010),
                        "history_freshness": .object(["3000602": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3000602", name: "Bob", previewText: "Toggle me", previewTsMs: 1700000001000),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "9002001",
                                convId: "3000602",
                                clientId: "c9002001",
                                senderId: "3000602",
                                senderName: "Bob",
                                isMine: false,
                                text: "Toggle me",
                                tsMs: 1700000001000,
                                reactions: .array([
                                    .object([
                                        "type": .string("5"),
                                        "key": .string("/-heart"),
                                        "emoji": .string("❤️"),
                                        "image": .string(""),
                                        "count": .int(2),
                                        "includesMe": .bool(true),
                                        "names": .array([.string("Bạn"), .string("Bob")]),
                                        "people": .int(2),
                                        "userCounts": .object([
                                            "2000602": .int(1),
                                            "3000602": .int(1),
                                        ]),
                                    ]),
                                ])
                            ),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000602", displayName: "Action User 2"),
                    MessageRecorderHarness.profileMeScript(uid: "2000602", displayName: "Action User 2"),
                    MessageActionRecorderHarness.httpScript(
                        path: "/api/message/reaction",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000602")])]),
                    .object([
                        "cmd": .string("react"),
                        "now_ms": .int(1700000010000),
                        "args": .object([
                            "conv_id": .string("3000602"),
                            "msg_id": .string("9002001"),
                            "emoji": .string("❤️"),
                        ]),
                    ]),
                ]
            ),

            // 3. react_remove_all: remove_my_reactions with and without a reaction of mine (no request when none).
            MessageActionRecorderHarness.ScenarioDef(
                name: "react_remove_all",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000603",
                    displayName: "Action User 3",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(6000000000020),
                        "history_freshness": .object(["3000603": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3000603", name: "Carol", previewText: "Remove mine", previewTsMs: 1700000002000),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "9003001",
                                convId: "3000603",
                                clientId: "c9003001",
                                senderId: "3000603",
                                senderName: "Carol",
                                isMine: false,
                                text: "Has mine and others",
                                tsMs: 1700000001000,
                                reactions: .array([
                                    .object([
                                        "type": .string("5"),
                                        "key": .string("/-heart"),
                                        "emoji": .string("❤️"),
                                        "image": .string(""),
                                        "count": .int(2),
                                        "includesMe": .bool(true),
                                        "names": .array([.string("Bạn"), .string("Carol")]),
                                        "people": .int(2),
                                        "userCounts": .object(["2000603": .int(1), "3000603": .int(1)]),
                                    ]),
                                    .object([
                                        "type": .string("3"),
                                        "key": .string("/-strong"),
                                        "emoji": .string("👍"),
                                        "image": .string(""),
                                        "count": .int(1),
                                        "includesMe": .bool(true),
                                        "names": .array([.string("Bạn")]),
                                        "people": .int(1),
                                        "userCounts": .object(["2000603": .int(1)]),
                                    ]),
                                ])
                            ),
                            storedMsg(
                                id: "9003002",
                                convId: "3000603",
                                clientId: "c9003002",
                                senderId: "3000603",
                                senderName: "Carol",
                                isMine: false,
                                text: "Only others",
                                tsMs: 1700000002000,
                                reactions: .array([
                                    .object([
                                        "type": .string("5"),
                                        "key": .string("/-heart"),
                                        "emoji": .string("❤️"),
                                        "image": .string(""),
                                        "count": .int(1),
                                        "includesMe": .bool(false),
                                        "names": .array([.string("Carol")]),
                                        "people": .int(1),
                                        "userCounts": .object(["3000603": .int(1)]),
                                    ]),
                                ])
                            ),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000603", displayName: "Action User 3"),
                    MessageRecorderHarness.profileMeScript(uid: "2000603", displayName: "Action User 3"),
                    MessageActionRecorderHarness.httpScript(
                        path: "/api/message/reaction",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000603")])]),
                    .object([
                        "cmd": .string("remove_my_reactions"),
                        "now_ms": .int(1700000010000),
                        "args": .object(["conv_id": .string("3000603"), "msg_id": .string("9003001")]),
                    ]),
                    .object([
                        "cmd": .string("remove_my_reactions"),
                        "now_ms": .int(1700000011000),
                        "args": .object(["conv_id": .string("3000603"), "msg_id": .string("9003002")]),
                    ]),
                ]
            ),

            // 4. react_guards: recalled, sending, failed, unknown message: nothing.
            MessageActionRecorderHarness.ScenarioDef(
                name: "react_guards",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000604",
                    displayName: "Action User 4",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(6000000000030),
                        "history_freshness": .object(["3000604": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3000604", name: "Dan", previewText: "Recalled", previewTsMs: 1700000001000),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "9004001",
                                convId: "3000604",
                                clientId: "c9004001",
                                senderId: "3000604",
                                senderName: "Dan",
                                isMine: false,
                                text: "",
                                kind: .object(["type": .string("recalled")]),
                                kindTag: "recalled",
                                tsMs: 1700000001000
                            ),
                            storedMsg(
                                id: "9004002",
                                convId: "3000604",
                                clientId: "c9004002",
                                senderId: "2000604",
                                senderName: "Action User 4",
                                isMine: true,
                                text: "Failed row",
                                tsMs: 1700000002000,
                                status: "failed"
                            ),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000604", displayName: "Action User 4"),
                    MessageRecorderHarness.profileMeScript(uid: "2000604", displayName: "Action User 4"),
                    MessageActionRecorderHarness.httpScript(
                        path: "/api/message/sms",
                        method: "POST",
                        hold: true,
                        json: .object(["error_code": .int(500), "error_message": .string("fail send")])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000604")])]),
                    .object([
                        "cmd": .string("send_text"),
                        "now_ms": .int(1700000005000),
                        "args": .object([
                            "id": .string("3000604"),
                            "text": .string("Will fail"),
                            "async": .bool(true),
                        ]),
                    ]),
                    // Recalled, sending, unknown
                    .object(["cmd": .string("react"), "now_ms": .int(1700000006000), "args": .object(["conv_id": .string("3000604"), "msg_id": .string("9004001"), "emoji": .string("❤️")])]),
                    .object(["cmd": .string("react"), "now_ms": .int(1700000006000), "args": .object(["conv_id": .string("3000604"), "msg_id": .string("6000000000030"), "emoji": .string("❤️")])]),
                    .object(["cmd": .string("react"), "now_ms": .int(1700000006000), "args": .object(["conv_id": .string("3000604"), "msg_id": .string("unknown_msg"), "emoji": .string("❤️")])]),
                    .object(["http_release": .int(1)]),
                    .object(["cmd": .string("await_send")]),
                    // Seeded failed row
                    .object(["cmd": .string("react"), "now_ms": .int(1700000007000), "args": .object(["conv_id": .string("3000604"), "msg_id": .string("9004002"), "emoji": .string("❤️")])]),
                ]
            ),

            // 5. react_retry_msgtype: first request fails with a non-auth code on a non-text kind:
            // second request with msgType 1 and a new client id; auth error: no retry.
            MessageActionRecorderHarness.ScenarioDef(
                name: "react_retry_msgtype",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000605",
                    displayName: "Action User 5",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(6000000000040),
                        "history_freshness": .object(["3000605": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3000605", name: "Eve", previewText: "[Hình ảnh]", previewTsMs: 1700000002000),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "9005001",
                                convId: "3000605",
                                clientId: "c9005001",
                                senderId: "3000605",
                                senderName: "Eve",
                                isMine: false,
                                text: "",
                                kind: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/p1.jpg")]),
                                kindTag: "photo",
                                tsMs: 1700000001000
                            ),
                            storedMsg(
                                id: "9005002",
                                convId: "3000605",
                                clientId: "c9005002",
                                senderId: "3000605",
                                senderName: "Eve",
                                isMine: false,
                                text: "",
                                kind: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/p2.jpg")]),
                                kindTag: "photo",
                                tsMs: 1700000002000
                            ),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000605", displayName: "Action User 5"),
                    MessageRecorderHarness.profileMeScript(uid: "2000605", displayName: "Action User 5"),
                    // 1st photo: non-auth error (112) -> retry with msgType 1 -> ok
                    MessageActionRecorderHarness.httpScript(
                        path: "/api/message/reaction",
                        method: "POST",
                        json: .object(["error_code": .int(112), "error_message": .string("invalid msgType")])
                    ),
                    MessageActionRecorderHarness.httpScript(
                        path: "/api/message/reaction",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                    // 2nd photo: auth error (600) -> no retry
                    MessageActionRecorderHarness.httpScript(
                        path: "/api/message/reaction",
                        method: "POST",
                        json: .object(["error_code": .int(600), "error_message": .string("session expired")])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000605")])]),
                    .object([
                        "cmd": .string("react"),
                        "now_ms": .int(1700000010000),
                        "args": .object(["conv_id": .string("3000605"), "msg_id": .string("9005001"), "emoji": .string("❤️")]),
                    ]),
                    .object([
                        "cmd": .string("react"),
                        "now_ms": .int(1700000011000),
                        "args": .object(["conv_id": .string("3000605"), "msg_id": .string("9005002"), "emoji": .string("👍")]),
                    ]),
                ]
            ),

            // 6. react_fail_rollback: both fail: reactions restored, show_card text, log shape `react failed: code=`.
            MessageActionRecorderHarness.ScenarioDef(
                name: "react_fail_rollback",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000606",
                    displayName: "Action User 6",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(6000000000050),
                        "history_freshness": .object(["3000606": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3000606", name: "Frank", previewText: "[Hình ảnh]", previewTsMs: 1700000001000),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "9006001",
                                convId: "3000606",
                                clientId: "c9006001",
                                senderId: "3000606",
                                senderName: "Frank",
                                isMine: false,
                                text: "",
                                kind: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/p3.jpg")]),
                                kindTag: "photo",
                                tsMs: 1700000001000,
                                reactions: .array([
                                    .object([
                                        "type": .string("5"),
                                        "key": .string("/-heart"),
                                        "emoji": .string("❤️"),
                                        "image": .string(""),
                                        "count": .int(1),
                                        "includesMe": .bool(false),
                                        "names": .array([.string("Frank")]),
                                        "people": .int(1),
                                        "userCounts": .object(["3000606": .int(1)]),
                                    ]),
                                ])
                            ),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000606", displayName: "Action User 6"),
                    MessageRecorderHarness.profileMeScript(uid: "2000606", displayName: "Action User 6"),
                    MessageActionRecorderHarness.httpScript(
                        path: "/api/message/reaction",
                        method: "POST",
                        json: .object(["error_code": .int(500), "error_message": .string("server error 1")])
                    ),
                    MessageActionRecorderHarness.httpScript(
                        path: "/api/message/reaction",
                        method: "POST",
                        json: .object(["error_code": .int(502), "error_message": .string("server error 2")])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000606")])]),
                    .object([
                        "cmd": .string("react"),
                        "now_ms": .int(1700000010000),
                        "args": .object(["conv_id": .string("3000606"), "msg_id": .string("9006001"), "emoji": .string("❤️")]),
                    ]),
                ]
            ),

            // 7. react_resolve_ids: message with only a client id: store lookup; not stored: history fetch
            // and findServerMsgId (nested data string, msgs list, globalMsgId), id upgraded in window and store.
            MessageActionRecorderHarness.ScenarioDef(
                name: "react_resolve_ids",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000607",
                    displayName: "Action User 7",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(6000000000060),
                        "history_freshness": .object(["3000607": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3000607", name: "Grace", previewText: "Client id only", previewTsMs: 1700000002000),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "9007001",
                                convId: "3000607",
                                clientId: "c9007001",
                                senderId: "2000607",
                                senderName: "Action User 7",
                                isMine: true,
                                text: "Stored has server id",
                                tsMs: 1700000001000
                            ),
                            storedMsg(
                                id: "c9007002",
                                convId: "3000607",
                                clientId: "c9007002",
                                senderId: "3000607",
                                senderName: "Grace",
                                isMine: false,
                                text: "Needs history lookup",
                                tsMs: 1700000002000
                            ),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000607", displayName: "Action User 7"),
                    MessageRecorderHarness.profileMeScript(uid: "2000607", displayName: "Action User 7"),
                    // Reaction for msg 1 (resolved from store)
                    MessageActionRecorderHarness.httpScript(
                        path: "/api/message/reaction",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                    // History lookup for msg 2 (nested data string -> msgs -> globalMsgId)
                    MessageActionRecorderHarness.httpScript(
                        path: "/api/preloadconvers/get-last-msgs",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .string("{\"msgs\":[{\"cliMsgId\":\"c9007002\",\"globalMsgId\":\"9007002\"}]}"),
                        ])
                    ),
                    // Reaction for msg 2 (resolved from history)
                    MessageActionRecorderHarness.httpScript(
                        path: "/api/message/reaction",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    // Inject msg 1 with only client id into in-memory window via apply_batch without calling open
                    // so resolveServerAndClientIds exercises the store lookup path for msg 1,
                    // and load msg 2 (with id == client_id in store) into memory via apply_batch.
                    .object([
                        "cmd": .string("apply_batch"),
                        "args": .object([
                            "payload": .object([
                                "msgs": .array([
                                    .object([
                                        "msgId": .string("c9007001"),
                                        "cliMsgId": .string("c9007001"),
                                        "uidFrom": .string("2000607"),
                                        "idTo": .string("3000607"),
                                        "dName": .string("Action User 7"),
                                        "ts": .int(1700000001000),
                                        "msgType": .string("webchat"),
                                        "content": .string("Stored has server id"),
                                    ]),
                                    .object([
                                        "msgId": .string("c9007002"),
                                        "cliMsgId": .string("c9007002"),
                                        "uidFrom": .string("3000607"),
                                        "idTo": .string("2000607"),
                                        "dName": .string("Grace"),
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
                    .object(["snapshot": .string("before_react")]),
                    .object([
                        "cmd": .string("react"),
                        "now_ms": .int(1700000010000),
                        "args": .object(["conv_id": .string("3000607"), "msg_id": .string("c9007001"), "emoji": .string("❤️")]),
                    ]),
                    .object([
                        "cmd": .string("react"),
                        "now_ms": .int(1700000011000),
                        "args": .object(["conv_id": .string("3000607"), "msg_id": .string("c9007002"), "emoji": .string("👍")]),
                    ]),
                ]
            ),
        ]
    }
}

// MARK: - Message Action Recorder Harness

@MainActor
private final class MessageActionTransitionRecorder {
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
        history.append(capture())
        if !waiters.isEmpty {
            let pending = waiters
            waiters.removeAll()
            for cont in pending.values {
                cont.resume()
            }
        }
    }

    func advanceSearchToLatestSyncState() {
        recordTransition()
        searchFromIndex = max(0, history.count - 1)
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
                throw MessageActionRecorderHarness.RecorderError.timeout(
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

enum MessageActionRecorderHarness {
    enum RecorderError: Error, CustomStringConvertible {
        case timeout(scenario: String, detail: String)
        case unscriptedRequest(scenario: String, detail: String)
        case invalidStep(scenario: String, detail: String)
        case invalidSeed(scenario: String, detail: String)
        case hostNotIsolated(scenario: String, detail: String)

        var description: String {
            switch self {
            case .timeout(let scenario, let detail):
                return "\(scenario): RecorderError.timeout: \(detail)"
            case .unscriptedRequest(let scenario, let detail):
                return "\(scenario): RecorderError.unscriptedRequest: \(detail)"
            case .invalidStep(let scenario, let detail):
                return "\(scenario): RecorderError.invalidStep: \(detail)"
            case .invalidSeed(let scenario, let detail):
                return "\(scenario): RecorderError.invalidSeed: \(detail)"
            case .hostNotIsolated(let scenario, let detail):
                return "\(scenario): RecorderError.hostNotIsolated: \(detail)"
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
        status: Int64 = 200,
        hold: Bool = false,
        json: CaseJSON? = nil,
        error: String? = nil,
        repeatResponse: Bool = false
    ) -> CaseJSON {
        var resp: [String: CaseJSON] = [:]
        if let error {
            resp["error"] = .string(error)
        } else {
            resp["status"] = .int(status)
            if let json {
                resp["json"] = json
            }
        }
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

    static func runDomainSuite(domain: String, scenarios: [ScenarioDef]) async throws {
        let shouldRecord = ProcessInfo.processInfo.environment["OLAZ_RECORD"] == "1"
        let runSlow = shouldRecord || ProcessInfo.processInfo.environment["OLAZ_SLOW_CASES"] == "1"
        let url = CaseFile.casesURL(domain: domain)

        if shouldRecord {
            var recorded: [CaseJSON] = []
            for scenario in scenarios {
                let c = try await recordScenario(domain: domain, scenario)
                recorded.append(c)
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
        XCTAssertEqual(byName.count, scenarios.count, "\(domain).jsonl case count mismatch (run with OLAZ_RECORD=1 to regenerate)")

        for scenario in scenarios {
            if scenario.slow && !runSlow {
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
            .appendingPathComponent("olaz-action-recorder-\(scenario.name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let storage = RecorderStorageIsolation(prefix: "olaz.action-recorder")
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

        let e2eeQueue = scenario.seed["host_results"]?["send_e2ee_text"]?.arrayValue ?? []
        var e2eeIndex = 0
        if scenario.seed["host_results"]?["send_e2ee_text"] != nil {
            engine.sendE2EETextHostHandler = { args in
                guard e2eeIndex < e2eeQueue.count else {
                    throw ZaloSessionError(code: 500, message: "No scripted send_e2ee_text result", url: "/api/e2ee/pc/message/sms")
                }
                let item = e2eeQueue[e2eeIndex]
                e2eeIndex += 1
                if let errObj = item["error"]?.objectValue {
                    let code = Int(errObj["code"]?.int64Value ?? 500)
                    let msg = errObj["message"]?.stringValue ?? "E2EE error"
                    let url = errObj["url"]?.stringValue ?? "/api/e2ee/pc/message/sms"
                    throw ZaloSessionError(code: code, message: msg, url: url)
                }
                if let errMsg = item["error"]?.stringValue {
                    throw ZaloSessionError(code: 500, message: errMsg, url: "/api/e2ee/pc/message/sms")
                }
                let cliId = args["client_id"] as? String ?? ""
                let msgId = item["msg_id"]?.stringValue ?? cliId
                let cliMsgId = item["cli_msg_id"]?.stringValue ?? cliId
                let tsMs = item["ts_ms"]?.int64Value ?? engine.nowMs()
                return SendMessageResult(msgId: msgId, cliMsgId: cliMsgId, tsMs: tsMs)
            }
        }

        var bootstrapLogs: [String] = []
        var sendLogs: [String] = []
        var actionLogs: [String] = []
        var lastSendResult: Bool?
        var pruneNextExpiryMs: Int64?
        var activeActionTask: Task<Void, Never>?

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
            case "apply_batch", "apply_parsed_events",
                 "apply_remote_reaction", "apply_remote_recall", "apply_remote_delete":
                return true
            case "start_ws":
                return !suppressedTransports.contains("ws")
            case "start_long_poll":
                return !suppressedTransports.contains("long_poll")
            default:
                return false
            }
        }

        let transitionRecorder = MessageActionTransitionRecorder(scenarioName: scenario.name) {
            normalizeRecordedURLs(SessionSnapshot.capture(from: engine))
        }
        engine.stateTrace = { [weak transitionRecorder] in
            transitionRecorder?.recordTransition()
        }
        engine.transportSettleTrace = {
            settleCount += 1
            notifySignal()
        }

        var snapshots: [String: CaseJSON] = [:]

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

        func findMessage(convId: String, msgId: String) -> ChatMessage? {
            engine.messages[convId]?.first { $0.id == msgId || $0.clientId == msgId }
        }

        do {
            for step in scenario.steps {
                if let cmd = step["cmd"]?.stringValue {
                    let args = step["args"]
                    let savedNowMs = engine.nowMs
                    let savedRandomTag4 = engine.randomTag4
                    if let ms = step["now_ms"]?.int64Value {
                        engine.nowMs = { ms }
                    }
                    if let r4 = step["rand4"]?.stringValue {
                        engine.randomTag4 = { r4 }
                    }
                    var keepNowMsForAsync = false
                    defer {
                        if !keepNowMsForAsync {
                            engine.nowMs = savedNowMs
                        }
                        engine.randomTag4 = savedRandomTag4
                    }
                    switch cmd {
                    case "start":
                        engine.start()
                        let engineAppend = EngineLog.shared.onAppend
                        installLogHooks(forwardingTo: engineAppend)
                        transitionRecorder.advanceSearchToLatestSyncState()
                    case "refresh_qr":
                        engine.refreshQR()
                        transitionRecorder.advanceSearchToLatestSyncState()
                    case "log_out":
                        _ = await engine.bootTask?.value
                        engine.logOut()
                        transitionRecorder.advanceSearchToLatestSyncState()
                    case "session_expired":
                        _ = await engine.bootTask?.value
                        let reason = args?["reason"]?.stringValue ?? ""
                        engine.handleSessionExpiredNotice(reason)
                        transitionRecorder.advanceSearchToLatestSyncState()
                    case "drain_chat_polling":
                        _ = await engine.bootTask?.value
                        let maxBatches = Int(args?["max_batches"]?.int64Value ?? 3)
                        let notifyIncoming = args?["notify_incoming"]?.boolValue ?? false
                        _ = await engine.drainChatPolling(maxBatches: maxBatches, notifyIncoming: notifyIncoming)
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
                    case "send_text":
                        _ = await engine.bootTask?.value
                        let id = args?["id"]?.stringValue ?? ""
                        let text = args?["text"]?.stringValue ?? ""
                        let quoteId = args?["quote_id"]?.stringValue
                        let mentions: [Mention] = (args?["mentions"]?.arrayValue ?? []).compactMap { m in
                            guard let uid = m["uid"]?.stringValue else { return nil }
                            return Mention(
                                uid: uid,
                                pos: Int(m["pos"]?.int64Value ?? 0),
                                len: Int(m["len"]?.int64Value ?? 0),
                                isAll: m["is_all"]?.boolValue ?? false
                            )
                        }
                        let styles: [TextStyle] = (args?["styles"]?.arrayValue ?? []).compactMap { s in
                            guard let st = s["st"]?.stringValue else { return nil }
                            return TextStyle(
                                start: Int(s["start"]?.int64Value ?? 0),
                                len: Int(s["len"]?.int64Value ?? 0),
                                st: st
                            )
                        }
                        let urgency = Int(args?["urgency"]?.int64Value ?? 0)
                        let isAsync = args?["async"]?.boolValue ?? false
                        if isAsync {
                            let heldBefore = server.heldHTTPCount()
                            var completed = false
                            let task = Task { @MainActor in
                                let ok = await engine.sendText(
                                    text,
                                    to: id,
                                    quoting: quoteId,
                                    mentions: mentions,
                                    styles: styles,
                                    urgency: urgency
                                )
                                completed = true
                                notifySignal()
                                return ok
                            }
                            engine.activeSendTask = task
                            let reachedHeld = await server.waitForHeldHTTPRequests(atLeast: heldBefore + 1, timeoutMs: 2000)
                            if !reachedHeld && !completed {
                                try await waitForCondition(timeoutMs: 2000, description: "async send_text to hold or finish") {
                                    completed || server.heldHTTPCount() > heldBefore
                                }
                            }
                            if completed {
                                lastSendResult = await task.value
                                engine.activeSendTask = nil
                                _ = await engine.persistConversationsTask?.value
                            } else {
                                keepNowMsForAsync = true
                            }
                        } else {
                            let ok = await engine.sendText(
                                text,
                                to: id,
                                quoting: quoteId,
                                mentions: mentions,
                                styles: styles,
                                urgency: urgency
                            )
                            lastSendResult = ok
                            _ = await engine.persistConversationsTask?.value
                        }
                    case "await_send":
                        if let task = engine.activeSendTask {
                            lastSendResult = await task.value
                            engine.activeSendTask = nil
                        }
                        _ = await engine.persistConversationsTask?.value
                        engine.nowMs = { Int64(Date().timeIntervalSince1970 * 1000) }
                    case "react":
                        _ = await engine.bootTask?.value
                        let convId = args?["conv_id"]?.stringValue ?? ""
                        let msgId = args?["msg_id"]?.stringValue ?? ""
                        let emoji = args?["emoji"]?.stringValue ?? ""
                        let isAsync = args?["async"]?.boolValue ?? false
                        if isAsync {
                            let heldBefore = server.heldHTTPCount()
                            var completed = false
                            let task = Task { @MainActor in
                                await engine.performReact(emoji, to: msgId, in: convId)
                                completed = true
                                notifySignal()
                            }
                            activeActionTask = task
                            let reachedHeld = await server.waitForHeldHTTPRequests(atLeast: heldBefore + 1, timeoutMs: 2000)
                            if !reachedHeld && !completed {
                                try await waitForCondition(timeoutMs: 2000, description: "async react to hold or finish") {
                                    completed || server.heldHTTPCount() > heldBefore
                                }
                            }
                            if completed {
                                await task.value
                                activeActionTask = nil
                            } else {
                                keepNowMsForAsync = true
                            }
                        } else {
                            await engine.performReact(emoji, to: msgId, in: convId)
                        }
                    case "await_action":
                        if let task = activeActionTask {
                            await task.value
                            activeActionTask = nil
                        }
                        await engine.awaitMessageActionTasksForRecording()
                        engine.nowMs = { Int64(Date().timeIntervalSince1970 * 1000) }
                    case "remove_my_reactions":
                        _ = await engine.bootTask?.value
                        let convId = args?["conv_id"]?.stringValue ?? ""
                        let msgId = args?["msg_id"]?.stringValue ?? ""
                        await engine.performReact("", to: msgId, in: convId, removeAll: true)
                    case "recall":
                        _ = await engine.bootTask?.value
                        let convId = args?["conv_id"]?.stringValue ?? ""
                        let msgId = args?["msg_id"]?.stringValue ?? ""
                        if let msg = findMessage(convId: convId, msgId: msgId) {
                            await engine.performRecall(msg)
                        }
                        _ = await engine.persistConversationsTask?.value
                    case "recall_many":
                        _ = await engine.bootTask?.value
                        let convId = args?["conv_id"]?.stringValue ?? ""
                        let msgIds = args?["msg_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
                        let useConfirm = args?["confirm"]?.boolValue ?? true
                        let msgs = msgIds.compactMap { findMessage(convId: convId, msgId: $0) }
                        if useConfirm {
                            if let first = msgs.first {
                                engine.beginSelection(first)
                                for m in msgs.dropFirst() {
                                    engine.toggleSelection(m.id)
                                }
                                engine.recallSelection()
                            }
                        } else {
                            engine.recallMessages(msgs)
                            await engine.awaitMessageActionTasksForRecording()
                        }
                    case "delete_for_me":
                        _ = await engine.bootTask?.value
                        let convId = args?["conv_id"]?.stringValue ?? ""
                        let msgId = args?["msg_id"]?.stringValue ?? ""
                        let confirmed = args?["confirmed"]?.boolValue ?? false
                        if let msg = findMessage(convId: convId, msgId: msgId) {
                            engine.deleteForMe(msg, confirmed: confirmed)
                        }
                        await engine.awaitMessageActionTasksForRecording()
                    case "delete_many":
                        _ = await engine.bootTask?.value
                        let convId = args?["conv_id"]?.stringValue ?? ""
                        let msgIds = args?["msg_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
                        let msgs = msgIds.compactMap { findMessage(convId: convId, msgId: $0) }
                        if let first = msgs.first {
                            engine.beginSelection(first)
                            for m in msgs.dropFirst() {
                                engine.toggleSelection(m.id)
                            }
                            engine.deleteSelection()
                        }
                    case "undo_delete":
                        _ = await engine.bootTask?.value
                        engine.undoDelete()
                    case "dismiss_delete_undo":
                        _ = await engine.bootTask?.value
                        engine.dismissDeleteUndo()
                        await engine.awaitMessageActionTasksForRecording()
                    case "await_delete_undo_expiry":
                        let timeoutMs = Int(step["timeout_ms"]?.int64Value ?? 8000)
                        try await waitForCondition(timeoutMs: timeoutMs, description: "deleteUndo expiry") {
                            engine.deleteUndo == nil
                        }
                        await engine.awaitMessageActionTasksForRecording()
                    case "answer_confirm":
                        _ = await engine.bootTask?.value
                        let ok = args?["ok"]?.boolValue ?? false
                        if let confirm = engine.messageConfirm {
                            engine.answerMessageConfirm(confirm, ok: ok)
                        }
                        await engine.awaitMessageActionTasksForRecording()
                    case "star":
                        _ = await engine.bootTask?.value
                        let convId = args?["conv_id"]?.stringValue ?? ""
                        let msgId = args?["msg_id"]?.stringValue ?? ""
                        let on = args?["on"]?.boolValue ?? true
                        if let msg = findMessage(convId: convId, msgId: msgId) {
                            engine.setStarred(msg, on)
                        }
                        await engine.awaitMessageActionTasksForRecording()
                    case "load_auto_delete":
                        _ = await engine.bootTask?.value
                        await engine.loadAutoDelete()
                    case "set_auto_delete":
                        _ = await engine.bootTask?.value
                        let convId = args?["conv_id"]?.stringValue ?? ""
                        let ttl = args?["ttl"]?.int64Value ?? 0
                        await engine.setAutoDelete(convId, ttl: ttl)
                        _ = await engine.persistConversationsTask?.value
                    case "prune_expired":
                        _ = await engine.bootTask?.value
                        let convId = args?["conv_id"]?.stringValue ?? ""
                        let nextExpiry = engine.pruneExpiredMessages(in: convId)
                        pruneNextExpiryMs = nextExpiry.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
                        await engine.awaitMessageActionTasksForRecording()
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
                    let snap = await MessageActionSnapshot.capture(
                        from: engine,
                        bootstrapLogs: bootstrapLogs,
                        lastSendResult: lastSendResult,
                        sendLogs: sendLogs,
                        pruneNextExpiryMs: pruneNextExpiryMs,
                        actionLogs: actionLogs
                    )
                    snapshots[label] = normalizeRecordedURLs(snap)
                } else {
                    throw RecorderError.invalidStep(scenario: scenario.name, detail: "Unknown step: \(step.canonicalString())")
                }
            }

            _ = await engine.bootTask?.value
            _ = await engine.openConversationTask?.value
            _ = await engine.loadOlderTask?.value
            if let task = engine.activeSendTask {
                lastSendResult = await task.value
                engine.activeSendTask = nil
            }
            if let task = activeActionTask {
                await task.value
                activeActionTask = nil
            }
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
                await MessageActionSnapshot.capture(
                    from: engine,
                    bootstrapLogs: bootstrapLogs,
                    lastSendResult: lastSendResult,
                    sendLogs: sendLogs,
                    pruneNextExpiryMs: pruneNextExpiryMs,
                    actionLogs: actionLogs
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
            activeActionTask?.cancel()
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
        if let refreshAt = seed["history_full_refresh_at"], refreshAt != .null {
            let val: String? = refreshAt.stringValue ?? refreshAt.int64Value.map(String.init)
            if let val, !val.isEmpty {
                try await store.setPreferenceString(key: ZaloEngine.fullHistoryRefreshKey, value: val)
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
            if let gids = contacts["friend_global_ids"], gids != .null {
                try await store.setPreferenceData(key: "gidToUidMap", data: Data(gids.canonicalString().utf8))
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
