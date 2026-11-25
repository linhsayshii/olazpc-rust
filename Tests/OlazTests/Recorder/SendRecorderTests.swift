import Foundation
import XCTest
@testable import Olaz

final class SendRecorderTests: XCTestCase {
    func testSendScenarios() async throws {
        try await SendRecorderHarness.runDomainSuite(
            domain: "send",
            scenarios: Self.sendScenarios()
        )
    }

    // MARK: - Helpers

    private static func wireMsg(
        msgId: String,
        cliMsgId: String? = nil,
        uidFrom: String,
        idTo: String,
        dName: String? = nil,
        avt: String? = nil,
        ts: Int64,
        msgType: String = "webchat",
        content: CaseJSON,
        isE2EE: Bool? = nil,
        actionId: Int64? = nil
    ) -> CaseJSON {
        var obj: [String: CaseJSON] = [
            "msgId": .string(msgId),
            "cliMsgId": .string(cliMsgId ?? "cli_\(msgId)"),
            "uidFrom": .string(uidFrom),
            "idTo": .string(idTo),
            "ts": .int(ts),
            "msgType": .string(msgType),
            "content": content,
        ]
        if let dName { obj["dName"] = .string(dName) }
        if let avt { obj["avt"] = .string(avt) }
        if let isE2EE { obj["isE2EE"] = .int(isE2EE ? 1 : 0) }
        if let actionId { obj["actionId"] = .int(actionId) }
        return .object(obj)
    }

    private static func storedMsg(
        id: String,
        convId: String,
        clientId: String? = nil,
        senderId: String,
        senderName: String = "Alice",
        senderAvatar: String = "https://cdn.example.invalid/a.jpg",
        isMine: Bool = false,
        text: String,
        kindTag: String = "text",
        tsMs: Int64,
        status: String = "sent",
        isE2EE: Bool = false,
        rawJSON: CaseJSON? = nil
    ) -> CaseJSON {
        var obj: [String: CaseJSON] = [
            "id": .string(id),
            "conv_id": .string(convId),
            "client_id": .string(clientId ?? "cli_\(id)"),
            "sender_id": .string(senderId),
            "sender_name": .string(senderName),
            "sender_avatar": .string(senderAvatar),
            "is_mine": .bool(isMine),
            "text": .string(text),
            "kind_tag": .string(kindTag),
            "ts_ms": .int(tsMs),
            "status": .string(status),
            "is_e2ee": .bool(isE2EE),
        ]
        if let rawJSON {
            obj["raw_json"] = rawJSON
        }
        return .object(obj)
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

    private static func sendScenarios() -> [SendRecorderHarness.ScenarioDef] {
        [
            // 1. send_plain_ok: optimistic row (status sending, menu flags for 1-1), API params,
            // id swap to the server msg id, status sent, row stored, list preview updated, no unread.
            SendRecorderHarness.ScenarioDef(
                name: "send_plain_ok",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000501",
                    displayName: "Send User 1",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(5000000000001),
                        "local_conversations": .array([
                            localConv(
                                id: "3000501",
                                name: "Alice",
                                unread: 0,
                                previewText: "Earlier",
                                previewTsMs: 1700000000000
                            ),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000501", displayName: "Send User 1"),
                    MessageRecorderHarness.profileMeScript(uid: "2000501", displayName: "Send User 1"),
                    SendRecorderHarness.httpScript(
                        path: "/api/message/sms",
                        method: "POST",
                        hold: true,
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "msgId": .string("9001001"),
                            ]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object([
                        "cmd": .string("send_text"),
                        "now_ms": .int(1700000010000),
                        "args": .object([
                            "id": .string("3000501"),
                            "text": .string("Hello Alice"),
                            "async": .bool(true),
                        ]),
                    ]),
                    .object(["snapshot": .string("optimistic")]),
                    .object(["http_release": .int(1)]),
                    .object(["cmd": .string("await_send")]),
                ]
            ),

            // 2. send_group_menu: group conversation: pin allowed in the menu;
            // self conversation: no recall, delete plain.
            SendRecorderHarness.ScenarioDef(
                name: "send_group_menu",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000502",
                    displayName: "Send User 2",
                    send2MeId: "9200502",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(5000000000002),
                        "local_conversations": .array([
                            localConv(id: "g500502", isGroup: true, name: "Group 502", members: 3),
                            localConv(id: "9200502", isGroup: false, name: "Cloud của tôi"),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000502", displayName: "Send User 2", send2MeId: "9200502"),
                    MessageRecorderHarness.profileMeScript(uid: "2000502", displayName: "Send User 2"),
                    SendRecorderHarness.httpScript(
                        path: "/api/group/sendmsg",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9002001")])])
                    ),
                    SendRecorderHarness.httpScript(
                        path: "/api/message/sms",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9002002")])])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object([
                        "cmd": .string("send_text"),
                        "now_ms": .int(1700000020000),
                        "args": .object([
                            "id": .string("g500502"),
                            "text": .string("Hi group"),
                        ]),
                    ]),
                    .object([
                        "cmd": .string("send_text"),
                        "now_ms": .int(1700000021000),
                        "args": .object([
                            "id": .string("9200502"),
                            "text": .string("Note to self"),
                        ]),
                    ]),
                ]
            ),

            // 3. send_quote: quote of a received and of an own message ("Bạn"),
            // empty quoted text ("[Tin nhắn]"), quote ts rounding.
            SendRecorderHarness.ScenarioDef(
                name: "send_quote",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000503",
                    displayName: "Send User 3",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(5000000000003),
                        "history_freshness": .object(["3000503": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(
                                id: "3000503",
                                name: "Bob",
                                previewText: "",
                                previewTsMs: 1700000003000,
                                previewFromMe: true
                            ),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "8003001",
                                convId: "3000503",
                                clientId: "c8003001",
                                senderId: "3000503",
                                senderName: "Bob",
                                isMine: false,
                                text: "Original question",
                                tsMs: 1700000002346,
                                rawJSON: .object([
                                    "id": .string("8003001"),
                                    "conversationId": .string("3000503"),
                                    "clientId": .string("c8003001"),
                                    "senderId": .string("3000503"),
                                    "senderName": .string("Bob"),
                                    "senderAvatar": .string("https://cdn.example.invalid/a.jpg"),
                                    "isMine": .bool(false),
                                    "text": .string("Original question"),
                                    "date": .double(1700000002345.6, raw: "1700000002345.6"),
                                    "status": .string("sent"),
                                    "isE2EE": .bool(false),
                                    "kind": .object(["type": .string("text")]),
                                ])
                            ),
                            storedMsg(
                                id: "8003002",
                                convId: "3000503",
                                clientId: "c8003002",
                                senderId: "2000503",
                                senderName: "Send User 3",
                                isMine: true,
                                text: "",
                                tsMs: 1700000003000
                            ),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000503", displayName: "Send User 3"),
                    MessageRecorderHarness.profileMeScript(uid: "2000503", displayName: "Send User 3"),
                    SendRecorderHarness.httpScript(
                        path: "/api/message/quote",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9003001")])])
                    ),
                    SendRecorderHarness.httpScript(
                        path: "/api/message/quote",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9003002")])])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000503")])]),
                    .object([
                        "cmd": .string("send_text"),
                        "now_ms": .int(1700000030000),
                        "args": .object([
                            "id": .string("3000503"),
                            "text": .string("Replying to Bob"),
                            "quote_id": .string("8003001"),
                        ]),
                    ]),
                    .object([
                        "cmd": .string("send_text"),
                        "now_ms": .int(1700000031000),
                        "args": .object([
                            "id": .string("3000503"),
                            "text": .string("Replying to own empty"),
                            "quote_id": .string("8003002"),
                        ]),
                    ]),
                ]
            ),

            // 4. send_mentions_styles_urgency: mentions, text styles to textProperties, urgency 1 and 2.
            SendRecorderHarness.ScenarioDef(
                name: "send_mentions_styles_urgency",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000504",
                    displayName: "Send User 4",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(5000000000004),
                        "local_conversations": .array([
                            localConv(id: "g500504", isGroup: true, name: "Group 504", members: 4),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000504", displayName: "Send User 4"),
                    MessageRecorderHarness.profileMeScript(uid: "2000504", displayName: "Send User 4"),
                    SendRecorderHarness.httpScript(
                        path: "/api/group/sendmsg",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9004001")])])
                    ),
                    SendRecorderHarness.httpScript(
                        path: "/api/group/sendmsg",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9004002")])])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object([
                        "cmd": .string("send_text"),
                        "now_ms": .int(1700000040000),
                        "args": .object([
                            "id": .string("g500504"),
                            "text": .string("@Alice @All Hello"),
                            "mentions": .array([
                                .object(["uid": .string("3000504"), "pos": .int(0), "len": .int(6), "is_all": .bool(false)]),
                                .object(["uid": .string("-1"), "pos": .int(7), "len": .int(4), "is_all": .bool(true)]),
                            ]),
                            "styles": .array([
                                .object(["start": .int(12), "len": .int(5), "st": .string("b")]),
                            ]),
                            "urgency": .int(1),
                        ]),
                    ]),
                    .object([
                        "cmd": .string("send_text"),
                        "now_ms": .int(1700000041000),
                        "args": .object([
                            "id": .string("g500504"),
                            "text": .string("Urgent notice"),
                            "styles": .array([
                                .object(["start": .int(0), "len": .int(6), "st": .string("i")]),
                            ]),
                            "urgency": .int(2),
                        ]),
                    ]),
                ]
            ),

            // 5. send_ttl: conversation with auto-delete: TTL on the row and the request.
            SendRecorderHarness.ScenarioDef(
                name: "send_ttl",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000505",
                    displayName: "Send User 5",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(5000000000005),
                        "auto_delete": .object(["3000505": .int(86400000)]),
                        "local_conversations": .array([
                            localConv(id: "3000505", name: "AutoDel Peer"),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000505", displayName: "Send User 5"),
                    MessageRecorderHarness.profileMeScript(uid: "2000505", displayName: "Send User 5"),
                    SendRecorderHarness.httpScript(
                        path: "/api/message/sms",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9005001")])])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object([
                        "cmd": .string("send_text"),
                        "now_ms": .int(1700000050000),
                        "args": .object([
                            "id": .string("3000505"),
                            "text": .string("Ephemeral hello"),
                        ]),
                    ]),
                ]
            ),

            // 6. send_empty_or_whitespace: nothing sent, returns false, no row.
            SendRecorderHarness.ScenarioDef(
                name: "send_empty_or_whitespace",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000506",
                    displayName: "Send User 6",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(5000000000006),
                        "local_conversations": .array([
                            localConv(id: "3000506", name: "Peer 506"),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000506", displayName: "Send User 6"),
                    MessageRecorderHarness.profileMeScript(uid: "2000506", displayName: "Send User 6"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object([
                        "cmd": .string("send_text"),
                        "now_ms": .int(1700000060000),
                        "args": .object(["id": .string("3000506"), "text": .string("")]),
                    ]),
                    .object(["snapshot": .string("after_empty")]),
                    .object([
                        "cmd": .string("send_text"),
                        "now_ms": .int(1700000061000),
                        "args": .object(["id": .string("3000506"), "text": .string("   \n\t  ")]),
                    ]),
                ]
            ),

            // 7. send_fail: API error: optimistic row removed, returns false, log shape sendText failed:.
            SendRecorderHarness.ScenarioDef(
                name: "send_fail",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000507",
                    displayName: "Send User 7",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(5000000000007),
                        "local_conversations": .array([
                            localConv(id: "3000507", name: "Fail Peer", previewText: "Old", previewTsMs: 1700000000000),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000507", displayName: "Send User 7"),
                    MessageRecorderHarness.profileMeScript(uid: "2000507", displayName: "Send User 7"),
                    SendRecorderHarness.httpScript(
                        path: "/api/message/sms",
                        method: "POST",
                        hold: true,
                        json: .object(["error_code": .int(112), "error_message": .string("Send failed")])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object([
                        "cmd": .string("send_text"),
                        "now_ms": .int(1700000070000),
                        "args": .object([
                            "id": .string("3000507"),
                            "text": .string("Will fail"),
                            "async": .bool(true),
                        ]),
                    ]),
                    .object(["snapshot": .string("optimistic")]),
                    .object(["http_release": .int(1)]),
                    .object(["cmd": .string("await_send")]),
                ]
            ),

            // 8. send_echo_first: the WS echo of the message arrives before the API reply:
            // the optimistic row is dropped, the echoed copy stands, list updated once.
            SendRecorderHarness.ScenarioDef(
                name: "send_echo_first",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000508",
                    displayName: "Send User 8",
                    suppress: ["long_poll"],
                    wsAuthManual: true,
                    extras: [
                        "next_client_id": .int(5000000000008),
                        "history_freshness": .object(["3000508": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3000508", name: "Echo Peer", previewText: "Before", previewTsMs: 1700000000000),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000508", displayName: "Send User 8"),
                    MessageRecorderHarness.profileMeScript(uid: "2000508", displayName: "Send User 8"),
                    MessageRecorderHarness.wsScript(),
                    MessageRecorderHarness.wsFrameScript(cmd: 1, payload: .object(["error_code": .int(0)])),
                    SendRecorderHarness.httpScript(
                        path: "/api/message/sms",
                        method: "POST",
                        hold: true,
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                    MessageRecorderHarness.wsFrameScript(
                        cmd: 501,
                        payload: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "msgs": .array([
                                    wireMsg(
                                        msgId: "9008001",
                                        cliMsgId: "5000000000008",
                                        uidFrom: "2000508",
                                        idTo: "3000508",
                                        dName: "Send User 8",
                                        ts: 1700000080500,
                                        content: .string("Echo before reply")
                                    ),
                                ]),
                            ]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("start_bootstrap"), "timeout_ms": .int(5000)]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("e2ee_connected"), "timeout_ms": .int(5000)]),
                    .object([
                        "cmd": .string("send_text"),
                        "now_ms": .int(1700000080000),
                        "args": .object([
                            "id": .string("3000508"),
                            "text": .string("Echo before reply"),
                            "async": .bool(true),
                        ]),
                    ]),
                    .object(["snapshot": .string("optimistic")]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("apply_parsed_events"), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("after_echo")]),
                    .object(["http_release": .int(1)]),
                    .object(["cmd": .string("await_send")]),
                ]
            ),

            // 9. send_same_id_dedupe: reply msg id already in the window: no duplicate.
            SendRecorderHarness.ScenarioDef(
                name: "send_same_id_dedupe",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000509",
                    displayName: "Send User 9",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(5000000000009),
                        "history_freshness": .object(["3000509": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3000509", name: "Dedupe Peer", previewText: "Existing", previewTsMs: 1700000000000),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "9009001",
                                convId: "3000509",
                                clientId: "4999999999999",
                                senderId: "2000509",
                                senderName: "Send User 9",
                                isMine: true,
                                text: "Existing",
                                tsMs: 1700000000000
                            ),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000509", displayName: "Send User 9"),
                    MessageRecorderHarness.profileMeScript(uid: "2000509", displayName: "Send User 9"),
                    SendRecorderHarness.httpScript(
                        path: "/api/message/sms",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9009001")])])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000509")])]),
                    .object([
                        "cmd": .string("send_text"),
                        "now_ms": .int(1700000090000),
                        "args": .object([
                            "id": .string("3000509"),
                            "text": .string("Replaces duplicate server id"),
                        ]),
                    ]),
                ]
            ),

            // 10. send_e2ee_conversation: E2EE peer: send_e2ee_text host call with the optimistic row's
            // client id; host success and host failure (row removed).
            SendRecorderHarness.ScenarioDef(
                name: "send_e2ee_conversation",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000510",
                    displayName: "Send User 10",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(5000000000010),
                        "e2ee_threads": .array([.string("3000510")]),
                        "history_freshness": .object(["3000510": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3000510", name: "E2EE Peer", previewText: "Secret prompt", previewTsMs: 1700000000000),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "8010001",
                                convId: "3000510",
                                clientId: "c8010001",
                                senderId: "3000510",
                                senderName: "E2EE Peer",
                                isMine: false,
                                text: "Secret prompt",
                                tsMs: 1700000000000,
                                isE2EE: true
                            ),
                        ]),
                        "host_results": .object([
                            "send_e2ee_text": .array([
                                .object([
                                    "msg_id": .string("9010001"),
                                    "cli_msg_id": .string("5000000000010"),
                                    "ts_ms": .int(1700000100500),
                                ]),
                                .object([
                                    "error": .object([
                                        "code": .int(500),
                                        "message": .string("Signal failure"),
                                        "url": .string("/api/e2ee/pc/message/sms"),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000510", displayName: "Send User 10"),
                    MessageRecorderHarness.profileMeScript(uid: "2000510", displayName: "Send User 10"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000510")])]),
                    .object([
                        "cmd": .string("send_text"),
                        "now_ms": .int(1700000100000),
                        "args": .object([
                            "id": .string("3000510"),
                            "text": .string("Secret reply"),
                            "quote_id": .string("8010001"),
                            "styles": .array([.object(["start": .int(0), "len": .int(6), "st": .string("b")])]),
                            "urgency": .int(1),
                        ]),
                    ]),
                    .object(["snapshot": .string("after_first")]),
                    .object([
                        "cmd": .string("send_text"),
                        "now_ms": .int(1700000101000),
                        "args": .object([
                            "id": .string("3000510"),
                            "text": .string("Second fails"),
                        ]),
                    ]),
                ]
            ),

            // 11. send_resets_typing_throttle: typing sent, then a send, then typing again within 10 s:
            // the second typing goes out.
            SendRecorderHarness.ScenarioDef(
                name: "send_resets_typing_throttle",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000511",
                    displayName: "Send User 11",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(5000000000011),
                        "local_conversations": .array([
                            localConv(id: "3000511", name: "Peer 511"),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000511", displayName: "Send User 11"),
                    MessageRecorderHarness.profileMeScript(uid: "2000511", displayName: "Send User 11"),
                    SendRecorderHarness.httpScript(
                        path: "/api/message/typing",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                    SendRecorderHarness.httpScript(
                        path: "/api/message/sms",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9011001")])])
                    ),
                    SendRecorderHarness.httpScript(
                        path: "/api/message/typing",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object([
                        "cmd": .string("notify_typing"),
                        "now_ms": .int(1700000110000),
                        "args": .object(["id": .string("3000511")]),
                    ]),
                    .object([
                        "cmd": .string("send_text"),
                        "now_ms": .int(1700000112000),
                        "args": .object(["id": .string("3000511"), "text": .string("Reset throttle")]),
                    ]),
                    .object([
                        "cmd": .string("notify_typing"),
                        "now_ms": .int(1700000113000),
                        "args": .object(["id": .string("3000511")]),
                    ]),
                ]
            ),

            // 12. mark_read_unread_and_mark: unread count and an unread mark: both cleared,
            // unread-mark API false, store row unread 0, seen API for the last received message.
            SendRecorderHarness.ScenarioDef(
                name: "mark_read_unread_and_mark",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000512",
                    displayName: "Send User 12",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "history_freshness": .object(["3000512": .string("up_to_date")]),
                        "unread_marks": .array([.string("3000512")]),
                        "local_conversations": .array([
                            localConv(id: "3000512", name: "Unread Peer", unread: 3, previewText: "Unread msg", previewTsMs: 1700000120000),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "8012001",
                                convId: "3000512",
                                clientId: "c8012001",
                                senderId: "3000512",
                                senderName: "Unread Peer",
                                isMine: false,
                                text: "Unread msg",
                                tsMs: 1700000120000
                            ),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000512", displayName: "Send User 12"),
                    MessageRecorderHarness.profileMeScript(uid: "2000512", displayName: "Send User 12"),
                    SendRecorderHarness.httpScript(
                        path: "/api/conv/removeUnreadMark",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                    SendRecorderHarness.httpScript(
                        path: "/api/message/seenv2",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000512")])]),
                    .object(["snapshot": .string("before_mark_read")]),
                    .object([
                        "cmd": .string("mark_read"),
                        "now_ms": .int(1700000121000),
                        "args": .object(["id": .string("3000512")]),
                    ]),
                ]
            ),

            // 13. mark_read_last_mine: last message mine: no seen API.
            SendRecorderHarness.ScenarioDef(
                name: "mark_read_last_mine",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000513",
                    displayName: "Send User 13",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "history_freshness": .object(["3000513": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3000513", name: "Last Mine Peer", unread: 2, previewText: "My msg", previewTsMs: 1700000130000, previewFromMe: true),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "8013001",
                                convId: "3000513",
                                clientId: "c8013001",
                                senderId: "2000513",
                                senderName: "Send User 13",
                                isMine: true,
                                text: "My msg",
                                tsMs: 1700000130000
                            ),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000513", displayName: "Send User 13"),
                    MessageRecorderHarness.profileMeScript(uid: "2000513", displayName: "Send User 13"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000513")])]),
                    .object([
                        "cmd": .string("mark_read"),
                        "now_ms": .int(1700000131000),
                        "args": .object(["id": .string("3000513")]),
                    ]),
                ]
            ),

            // 14. mark_read_nothing: nothing unread: no extras rebuild, seen API still per rule 12/13.
            SendRecorderHarness.ScenarioDef(
                name: "mark_read_nothing",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000514",
                    displayName: "Send User 14",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "history_freshness": .object(["3000514": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3000514", name: "Read Peer", unread: 0, previewText: "Already read", previewTsMs: 1700000140000),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "8014001",
                                convId: "3000514",
                                clientId: "c8014001",
                                senderId: "3000514",
                                senderName: "Read Peer",
                                isMine: false,
                                text: "Already read",
                                tsMs: 1700000140000
                            ),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000514", displayName: "Send User 14"),
                    MessageRecorderHarness.profileMeScript(uid: "2000514", displayName: "Send User 14"),
                    SendRecorderHarness.httpScript(
                        path: "/api/message/seenv2",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000514")])]),
                    .object([
                        "cmd": .string("mark_read"),
                        "now_ms": .int(1700000141000),
                        "args": .object(["id": .string("3000514")]),
                    ]),
                ]
            ),

            // 15. typing_in_1_1_and_group: incoming typing shows and expires
            // (10s in TypingStatus.displaySeconds), onPC flag, group typing by member name.
            SendRecorderHarness.ScenarioDef(
                name: "typing_in_1_1_and_group",
                slow: true,
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000515",
                    displayName: "Send User 15",
                    suppress: ["long_poll"],
                    wsAuthManual: true,
                    extras: [
                        "contacts": .object([
                            "friends_loaded": .bool(true),
                            "groups_loaded": .bool(true),
                            "friends": .array([
                                .object(["id": .string("3000515"), "name": .string("Alice")]),
                                .object(["id": .string("3000516"), "name": .string("Bob")]),
                            ]),
                            "groups": .array([
                                .object(["id": .string("g500515"), "name": .string("Group 515")]),
                            ]),
                        ]),
                        "local_conversations": .array([
                            localConv(id: "3000515", name: "Alice"),
                            localConv(id: "g500515", isGroup: true, name: "Group 515", members: 3),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000515", displayName: "Send User 15"),
                    MessageRecorderHarness.profileMeScript(uid: "2000515", displayName: "Send User 15"),
                    MessageRecorderHarness.wsScript(),
                    MessageRecorderHarness.wsFrameScript(cmd: 1, payload: .object(["error_code": .int(0)])),
                    MessageRecorderHarness.wsFrameScript(
                        cmd: 601,
                        payload: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "controls": .array([
                                    .object([
                                        "act_type": .string("typing"),
                                        "act": .string("typing"),
                                        "data": .object(["uid": .string("3000515"), "isPC": .int(1)]),
                                    ]),
                                    .object([
                                        "act_type": .string("typing"),
                                        "act": .string("gtyping"),
                                        "data": .object(["uid": .string("3000516"), "gid": .string("500515")]),
                                    ]),
                                ]),
                            ]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("start_bootstrap"), "timeout_ms": .int(5000)]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("e2ee_connected"), "timeout_ms": .int(5000)]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("show_typing"), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("show_typing"), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("typing_active")]),
                    .object(["cmd": .string("await_typing_expiry"), "args": .object(["id": .string("3000515")]), "timeout_ms": .int(15000)]),
                    .object(["cmd": .string("await_typing_expiry"), "args": .object(["id": .string("g500515")]), "timeout_ms": .int(15000)]),
                ]
            ),

            // 16. typing_in_state_json: handleTyping(state:) with the official shape.
            SendRecorderHarness.ScenarioDef(
                name: "typing_in_state_json",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000516",
                    displayName: "Send User 16",
                    suppress: ["ws", "long_poll"]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000516", displayName: "Send User 16"),
                    MessageRecorderHarness.profileMeScript(uid: "2000516", displayName: "Send User 16"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object([
                        "cmd": .string("handle_typing"),
                        "now_ms": .int(1700000160000),
                        "args": .object([
                            "state": .object([
                                "typing": .object([
                                    "convId": .string("3000516"),
                                    "name": .string("Charlie"),
                                    "isPC": .bool(true),
                                ]),
                            ]),
                        ]),
                    ]),
                    .object(["snapshot": .string("after_typing_pc")]),
                    .object([
                        "cmd": .string("handle_typing"),
                        "now_ms": .int(1700000161000),
                        "args": .object([
                            "state": .object([
                                "typing": .object([
                                    "convId": .string("g500516"),
                                    "name": .string("Dana"),
                                ]),
                            ]),
                        ]),
                    ]),
                    .object(["snapshot": .string("after_typing_group")]),
                    .object([
                        "cmd": .string("handle_typing"),
                        "now_ms": .int(1700000162000),
                        "args": .object([
                            "state": .object([
                                "other": .string("ignored"),
                            ]),
                        ]),
                    ]),
                ]
            ),

            // 17. typing_out_throttle: two notify_typing 5 s apart: one request; 11 s apart: two.
            SendRecorderHarness.ScenarioDef(
                name: "typing_out_throttle",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000517",
                    displayName: "Send User 17",
                    suppress: ["ws", "long_poll"]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000517", displayName: "Send User 17"),
                    MessageRecorderHarness.profileMeScript(uid: "2000517", displayName: "Send User 17"),
                    SendRecorderHarness.httpScript(
                        path: "/api/message/typing",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                    SendRecorderHarness.httpScript(
                        path: "/api/message/typing",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object([
                        "cmd": .string("notify_typing"),
                        "now_ms": .int(1700000000000),
                        "args": .object(["id": .string("3000517")]),
                    ]),
                    .object([
                        "cmd": .string("notify_typing"),
                        "now_ms": .int(1700000005000),
                        "args": .object(["id": .string("3000517")]),
                    ]),
                    .object(["snapshot": .string("after_5s")]),
                    .object([
                        "cmd": .string("notify_typing"),
                        "now_ms": .int(1700000011000),
                        "args": .object(["id": .string("3000517")]),
                    ]),
                ]
            ),

            // 18. typing_out_pref_off: sendTyping false: no request.
            SendRecorderHarness.ScenarioDef(
                name: "typing_out_pref_off",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000518",
                    displayName: "Send User 18",
                    suppress: ["ws", "long_poll"]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000518", displayName: "Send User 18"),
                    MessageRecorderHarness.profileMeScript(uid: "2000518", displayName: "Send User 18"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object([
                        "cmd": .string("set_pref"),
                        "args": .object(["key": .string(OlazPrefs.sendTyping), "value": .bool(false)]),
                    ]),
                    .object([
                        "cmd": .string("notify_typing"),
                        "now_ms": .int(1700000180000),
                        "args": .object(["id": .string("3000518")]),
                    ]),
                ]
            ),

            // 19. typing_out_not_ready_and_unauthenticated: nothing sent.
            SendRecorderHarness.ScenarioDef(
                name: "typing_out_not_ready_and_unauthenticated",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000519",
                    displayName: "Send User 19",
                    suppress: ["ws", "long_poll"]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000519", displayName: "Send User 19"),
                    MessageRecorderHarness.profileMeScript(uid: "2000519", displayName: "Send User 19"),
                    MessageRecorderHarness.serverInfoScript(),
                    MessageRecorderHarness.reqqrScript(tokenId: "tok_qr_519", qrCnt: "https://zalo.me/qr/test-519"),
                    SendRecorderHarness.httpScript(path: "/api/login/waitScan", error: "timeout"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("clear_client_auth")]),
                    .object([
                        "cmd": .string("notify_typing"),
                        "now_ms": .int(1700000190000),
                        "args": .object(["id": .string("3000519")]),
                    ]),
                    .object(["snapshot": .string("after_unauthenticated")]),
                    .object(["cmd": .string("log_out")]),
                    .object(["await": .object(["phase": .string("login"), "step": .string("waiting_scan")]), "timeout_ms": .int(5000)]),
                    .object([
                        "cmd": .string("notify_typing"),
                        "now_ms": .int(1700000191000),
                        "args": .object(["id": .string("3000529")]),
                    ]),
                ]
            ),

            // 20. typing_out_trim: id with whitespace: trimmed key, empty id ignored.
            SendRecorderHarness.ScenarioDef(
                name: "typing_out_trim",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000520",
                    displayName: "Send User 20",
                    suppress: ["ws", "long_poll"]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000520", displayName: "Send User 20"),
                    MessageRecorderHarness.profileMeScript(uid: "2000520", displayName: "Send User 20"),
                    SendRecorderHarness.httpScript(
                        path: "/api/message/typing",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object([
                        "cmd": .string("notify_typing"),
                        "now_ms": .int(1700000200000),
                        "args": .object(["id": .string("   \n\t  ")]),
                    ]),
                    .object([
                        "cmd": .string("notify_typing"),
                        "now_ms": .int(1700000200000),
                        "args": .object(["id": .string("  3000520  ")]),
                    ]),
                    .object([
                        "cmd": .string("notify_typing"),
                        "now_ms": .int(1700000205000),
                        "args": .object(["id": .string("3000520")]),
                    ]),
                ]
            ),
        ]
    }
}

// MARK: - U5 Recorder Harness (send)

enum SendRecorderHarness {
    struct ScenarioDef {
        let name: String
        let slow: Bool
        let seed: CaseJSON
        let server: [CaseJSON]
        let steps: [CaseJSON]

        init(
            name: String,
            slow: Bool = false,
            seed: CaseJSON,
            server: [CaseJSON],
            steps: [CaseJSON]
        ) {
            self.name = name
            self.slow = slow
            self.seed = seed
            self.server = server
            self.steps = steps
        }
    }

    enum RecorderError: Error, CustomStringConvertible {
        case timeout(scenario: String, detail: String)
        case unscriptedRequest(scenario: String, detail: String)
        case invalidStep(scenario: String, detail: String)
        case hostNotIsolated(scenario: String, detail: String)

        var description: String {
            switch self {
            case .timeout(let scenario, let detail):
                return "\(scenario): RecorderError.timeout: \(detail)"
            case .unscriptedRequest(let scenario, let detail):
                return "\(scenario): RecorderError.unscriptedRequest: \(detail)"
            case .invalidStep(let scenario, let detail):
                return "\(scenario): RecorderError.invalidStep: \(detail)"
            case .hostNotIsolated(let scenario, let detail):
                return "\(scenario): RecorderError.hostNotIsolated: \(detail)"
            }
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
        if hold {
            obj["hold"] = .bool(true)
        }
        if repeatResponse {
            obj["repeat"] = .bool(true)
        }
        return .object(obj)
    }

    static func runDomainSuite(domain: String, scenarios: [ScenarioDef]) async throws {
        let shouldRecord = ProcessInfo.processInfo.environment["OLAZ_RECORD"] == "1"
        let runSlow = shouldRecord || ProcessInfo.processInfo.environment["OLAZ_SLOW_CASES"] == "1"
        let url = CaseFile.casesURL(domain: domain)

        if shouldRecord {
            var recorded: [CaseJSON] = []
            for scenario in scenarios {
                let c = try await recordScenario(domain: domain, scenario, shouldRecord: true)
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

        let knownDiffs = try CaseFile.loadKnownDiffs()
        var usedKnownDiffs = Array(repeating: false, count: knownDiffs.count)
        var executedNames: Set<String> = []

        for scenario in scenarios {
            if scenario.slow && !runSlow {
                print("skipped slow: \(scenario.name)")
                continue
            }
            guard let expected = byName[scenario.name] else {
                XCTFail("Missing recorded case '\(scenario.name)' in \(url.path)")
                continue
            }
            executedNames.insert(scenario.name)
            let actual = try await recordScenario(domain: domain, scenario)
            let diffs = CaseFile.compareCase(
                domain: domain,
                name: scenario.name,
                expected: expected,
                actual: actual,
                knownDiffs: knownDiffs,
                usedKnownDiffs: &usedKnownDiffs
            )
            for diff in diffs {
                XCTFail("\(scenario.name): \(diff)")
            }
        }
        for stale in CaseFile.staleKnownDiffs(
            domain: domain,
            executedNames: executedNames,
            allCaseNames: Set(byName.keys),
            knownDiffs: knownDiffs,
            usedKnownDiffs: usedKnownDiffs
        ) {
            XCTFail(stale)
        }
    }

    @MainActor
    static func recordScenario(domain: String, _ scenario: ScenarioDef, shouldRecord: Bool = false) async throws -> CaseJSON {
        try await RecorderSuiteLock.shared.withLock {
            try await recordScenarioLocked(domain: domain, scenario, shouldRecord: shouldRecord)
        }
    }

    @MainActor
    private static func recordScenarioLocked(domain: String, _ scenario: ScenarioDef, shouldRecord: Bool = false) async throws -> CaseJSON {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-send-recorder-\(scenario.name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let storage = RecorderStorageIsolation(prefix: "olaz.send-recorder")
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
        var lastSendResult: Bool?
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
            case "apply_batch", "apply_parsed_events", "show_typing":
                return true
            case "start_ws":
                return !suppressedTransports.contains("ws")
            case "start_long_poll":
                return !suppressedTransports.contains("long_poll")
            default:
                return false
            }
        }

        let transitionRecorder = SendTransitionRecorder(scenarioName: scenario.name) {
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
                    var keepNowMsForAsyncSend = false
                    defer {
                        if !keepNowMsForAsyncSend {
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
                                keepNowMsForAsyncSend = true
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
                    case "mark_read":
                        _ = await engine.bootTask?.value
                        let id = args?["id"]?.stringValue ?? ""
                        engine.markRead(id)
                        await engine.awaitMarkReadTasksForRecording()
                    case "notify_typing":
                        _ = await engine.bootTask?.value
                        let id = args?["id"]?.stringValue ?? ""
                        engine.notifyTyping(in: id)
                        await engine.awaitNotifyTypingTaskForRecording()
                    case "handle_typing":
                        _ = await engine.bootTask?.value
                        let state = (args?["state"] ?? .object([:])).toFoundation() as? [String: Any] ?? [:]
                        engine.handleTyping(state: state)
                    case "set_pref":
                        let key = args?["key"]?.stringValue ?? ""
                        if !key.isEmpty, let val = args?["value"] {
                            switch val {
                            case .null:
                                engine.userDefaults.removeObject(forKey: key)
                            case .bool(let b):
                                engine.userDefaults.set(b, forKey: key)
                            case .int(let i):
                                engine.userDefaults.set(Int(i), forKey: key)
                            case .string(let s):
                                engine.userDefaults.set(s, forKey: key)
                            default:
                                engine.userDefaults.set(val.toFoundation(), forKey: key)
                            }
                        }
                    case "clear_client_auth":
                        _ = await engine.bootTask?.value
                        await engine.sessionClient.clearAuthForTesting()
                    case "await_typing_expiry":
                        let id = args?["id"]?.stringValue ?? ""
                        let timeoutMs = Int(step["timeout_ms"]?.int64Value ?? 15000)
                        try await waitForCondition(timeoutMs: timeoutMs, description: "typing expiry for '\(id)'") {
                            engine.typing[id] == nil
                        }
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
                    let snap = await SendSnapshot.capture(
                        from: engine,
                        bootstrapLogs: bootstrapLogs,
                        lastSendResult: lastSendResult,
                        sendLogs: sendLogs
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
            await engine.awaitMarkReadTasksForRecording()
            await engine.awaitNotifyTypingTaskForRecording()
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
                await SendSnapshot.capture(
                    from: engine,
                    bootstrapLogs: bootstrapLogs,
                    lastSendResult: lastSendResult,
                    sendLogs: sendLogs
                )
            )
            let requests = server.canonicalRequests().map { normalizeRecordedURLs($0) }

            engine.cancelTasksForRecording()
            engine.transportSettleTrace = nil
            server.stop()
            await engine.finishTearDownForRecording()

            if shouldRecord && server.hadUnscriptedRequest {
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
        if let aliasesObj = contacts["aliases"]?.objectValue {
            var map: [String: String] = [:]
            for (k, v) in aliasesObj {
                if let s = v.stringValue { map[k] = s }
            }
            engine.cachedAliases = map
        }
    }

    private static func assertOnlyLocalFakeHosts(_ domains: ZaloDomains, scenario: String, stage: String) throws {
        guard domains.isolated else {
            throw RecorderError.hostNotIsolated(scenario: scenario, detail: "\(stage): ZaloDomains.isolated must be true")
        }
        var allHosts: [String] = [domains.auth, domains.wpaChat, domains.lpChat, domains.lpControl]
        allHosts.append(contentsOf: domains.ws)
        allHosts.append(contentsOf: domains.serviceCandidates.values.flatMap { $0 })
        allHosts.append(contentsOf: domains.preferredHosts.values)

        let allowedHosts: Set<String> = ["127.0.0.1", "localhost", "fake"]
        for raw in allHosts where !raw.isEmpty {
            let norm = ZaloDomains.normalizeHost(raw)
            guard let host = URL(string: norm)?.host?.lowercased(), allowedHosts.contains(host) else {
                throw RecorderError.hostNotIsolated(scenario: scenario, detail: "\(stage): non-fake host detected '\(raw)'")
            }
        }
    }

    private static func extractInitialSecretKey(from seed: CaseJSON) -> Data? {
        guard let enk = seed["saved_session"]?["plainAccount"]?["zpwEnk"]?.stringValue, !enk.isEmpty else {
            return nil
        }
        let parsed = ZaloCrypto.parseSecretKey(enk)
        return (parsed.count == 16 || parsed.count == 32) ? parsed : nil
    }

    private static func defaultFakeDomainsJSON() -> CaseJSON {
        var candidates: [String: CaseJSON] = [:]
        for key in ZaloDomains.defaultServiceMapV3.keys {
            candidates[key] = .array([.string("http://fake")])
        }
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
}

@MainActor
private final class SendTransitionRecorder {
    private let scenarioName: String
    private let capture: () -> CaseJSON
    private var history: [CaseJSON] = []
    private var searchFromIndex = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(scenarioName: String, capture: @escaping () -> CaseJSON) {
        self.scenarioName = scenarioName
        self.capture = capture
        recordTransition()
    }

    func recordTransition() {
        let state = capture()
        if history.last != state {
            history.append(state)
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
                throw SendRecorderHarness.RecorderError.timeout(
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
