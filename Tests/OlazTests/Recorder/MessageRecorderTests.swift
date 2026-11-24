import Foundation
import XCTest
@testable import Olaz

final class MessageRecorderTests: XCTestCase {
    func testMessagesCases() async throws {
        try await MessageRecorderHarness.runDomainSuite(
            domain: "messages",
            scenarios: Self.messagesScenarios()
        )
    }

    // MARK: - Message Builders

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
        reactions: [CaseJSON]? = nil
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
        if let reactions {
            obj["reactions"] = .array(reactions)
        }
        return .object(obj)
    }

    private static func localConv(
        id: String,
        isGroup: Bool = false,
        name: String,
        avatar: String = "https://cdn.example.invalid/a.jpg",
        members: Int64 = 0,
        unread: Int64 = 0,
        previewText: String = "",
        previewTsMs: Int64 = 0
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
            "preview_from_me": .bool(false),
        ])
    }

    private static func preloadHistoryScript(convId: String, msgs: [CaseJSON]) -> CaseJSON {
        MessageRecorderHarness.httpScript(
            path: "/api/preloadconvers/get-last-msgs",
            method: "GET",
            json: .object([
                "error_code": .int(0),
                "data": .object([
                    "msgs": .object([
                        convId: .array(msgs),
                    ]),
                ]),
            ])
        )
    }

    private static func cloudHistoryScript(
        path: String = "/api/cm/getrecentv2",
        groupMsgs: [CaseJSON],
        isOld: Int64 = 0,
        hasMore: Int64 = 0,
        lastMsgId: String = "0"
    ) -> CaseJSON {
        MessageRecorderHarness.httpScript(
            path: path,
            method: "GET",
            json: .object([
                "error_code": .int(0),
                "data": .object([
                    "groupMsgs": .array(groupMsgs),
                    "isOld": .int(isOld),
                    "hasMore": .int(hasMore),
                    "lastMsgId": .string(lastMsgId),
                ]),
            ])
        )
    }

    // MARK: - Scenarios

    private static func messagesScenarios() -> [MessageRecorderHarness.ScenarioDef] {
        let baseTs: Int64 = 1700000000000
        let lockedCipher = Data([0x03, 0x33, 0x0a] + Array(repeating: UInt8(0x41), count: 37)).base64EncodedString()

        let peer1 = "3000001"
        let sixtyStoredMessages: [CaseJSON] = (1...60).map { idx in
            let id = String(1000 + idx)
            return storedMsg(
                id: id,
                convId: peer1,
                senderId: peer1,
                text: "Msg \(idx)",
                tsMs: baseTs + Int64(idx) * 1000
            )
        }

        let peer6 = "3000006"
        let grp6 = "g500006"
        let self6 = "9200406"
        let store6PeerMsgs: [CaseJSON] = (1...55).map { idx in
            storedMsg(id: String(1100 + idx), convId: peer6, senderId: peer6, text: "P6 \(idx)", tsMs: baseTs + Int64(idx) * 1000)
        }
        let store6GrpMsgs: [CaseJSON] = (1...55).map { idx in
            storedMsg(id: String(1200 + idx), convId: grp6, senderId: peer6, text: "G6 \(idx)", tsMs: baseTs + Int64(idx) * 1000)
        }
        let store6SelfMsgs: [CaseJSON] = (1...55).map { idx in
            storedMsg(id: String(1300 + idx), convId: self6, senderId: "2000406", senderName: "Bạn", senderAvatar: "", isMine: true, text: "S6 \(idx)", tsMs: baseTs + Int64(idx) * 1000)
        }

        let grp7 = "g500007"
        let store7Msgs: [CaseJSON] = (1...46).map { idx in
            storedMsg(id: String(2000 + idx), convId: grp7, senderId: "3000007", text: "G7 \(idx)", tsMs: baseTs + Int64(idx) * 1000)
        }

        let grp8True = "g500008"
        let grp8False = "g500009"
        let self8 = "9200408"
        let peer8 = "3000008"

        return [
            // 1. open_local_cache: 60 stored rows: window holds the newest 50 sorted by date then id,
            // has_more true (>= 45), then the recent fetch unless up to date, markRead host call.
            MessageRecorderHarness.ScenarioDef(
                name: "open_local_cache",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000401",
                    displayName: "Msg User 1",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "local_conversations": .array([
                            localConv(id: peer1, name: "Alice", unread: 1, previewText: "Msg 60", previewTsMs: baseTs + 60_000),
                        ]),
                        "local_messages": .array(sixtyStoredMessages),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000401", displayName: "Msg User 1"),
                    MessageRecorderHarness.profileMeScript(uid: "2000401", displayName: "Msg User 1"),
                    preloadHistoryScript(convId: peer1, msgs: [
                        wireMsg(msgId: "1061", uidFrom: peer1, idTo: "2000401", dName: "Alice", ts: baseTs + 61_000, content: .string("Fresh 61")),
                    ]),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string(peer1)])]),
                ]
            ),

            // 2. open_up_to_date_skips_fetch: freshness upToDate for the id: no history request.
            MessageRecorderHarness.ScenarioDef(
                name: "open_up_to_date_skips_fetch",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000402",
                    displayName: "Msg User 2",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "history_freshness": .object(["3000002": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3000002", name: "Bob", unread: 1, previewText: "Cached 2", previewTsMs: baseTs + 2_000),
                        ]),
                        "local_messages": .array([
                            storedMsg(id: "1001", convId: "3000002", senderId: "3000002", senderName: "Bob", text: "Cached 1", tsMs: baseTs + 1_000),
                            storedMsg(id: "1002", convId: "3000002", senderId: "3000002", senderName: "Bob", text: "Cached 2", tsMs: baseTs + 2_000),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000402", displayName: "Msg User 2"),
                    MessageRecorderHarness.profileMeScript(uid: "2000402", displayName: "Msg User 2"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000002")])]),
                ]
            ),

            // 3. open_empty_store_fetch: no local rows: server page merged and stored.
            MessageRecorderHarness.ScenarioDef(
                name: "open_empty_store_fetch",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000403",
                    displayName: "Msg User 3",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "local_conversations": .array([
                            localConv(id: "3000003", name: "Carol"),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000403", displayName: "Msg User 3"),
                    MessageRecorderHarness.profileMeScript(uid: "2000403", displayName: "Msg User 3"),
                    preloadHistoryScript(convId: "3000003", msgs: [
                        wireMsg(msgId: "2002", uidFrom: "3000003", idTo: "2000403", dName: "Carol", avt: "https://cdn.example.invalid/c.jpg", ts: baseTs + 2_000, content: .string("Second")),
                        wireMsg(msgId: "2001", uidFrom: "3000003", idTo: "2000403", dName: "Carol", avt: "https://cdn.example.invalid/c.jpg", ts: baseTs + 1_000, content: .string("First")),
                    ]),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000003")])]),
                ]
            ),

            // 4. open_fetch_fails: request refused, empty window: has_more false.
            MessageRecorderHarness.ScenarioDef(
                name: "open_fetch_fails",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000404",
                    displayName: "Msg User 4",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "local_conversations": .array([
                            localConv(id: "3000004", name: "Dave"),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000404", displayName: "Msg User 4"),
                    MessageRecorderHarness.profileMeScript(uid: "2000404", displayName: "Msg User 4"),
                    MessageRecorderHarness.httpScript(path: "/api/preloadconvers/get-last-msgs", method: "GET", error: "refused"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000004")])]),
                ]
            ),

            // 5. open_twice: second open adds nothing, no duplicate rows, no extra list write.
            MessageRecorderHarness.ScenarioDef(
                name: "open_twice",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000405",
                    displayName: "Msg User 5",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "local_conversations": .array([
                            localConv(id: "3000005", name: "Eve", previewText: "Local 2", previewTsMs: baseTs + 2_000),
                        ]),
                        "local_messages": .array([
                            storedMsg(id: "1501", convId: "3000005", senderId: "3000005", senderName: "Eve", text: "Local 1", tsMs: baseTs + 1_000),
                            storedMsg(id: "1502", convId: "3000005", senderId: "3000005", senderName: "Eve", text: "Local 2", tsMs: baseTs + 2_000),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000405", displayName: "Msg User 5"),
                    MessageRecorderHarness.profileMeScript(uid: "2000405", displayName: "Msg User 5"),
                    preloadHistoryScript(convId: "3000005", msgs: [
                        wireMsg(msgId: "1503", uidFrom: "3000005", idTo: "2000405", dName: "Eve", avt: "https://cdn.example.invalid/a.jpg", ts: baseTs + 3_000, content: .string("Server 3")),
                    ]),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000005")])]),
                    .object(["snapshot": .string("after_first_open")]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000005")])]),
                ]
            ),

            // 6. load_older_from_store: older rows by beforeTsMs; 1-1 with fewer than 45: has_more false;
            // group and self keep it.
            MessageRecorderHarness.ScenarioDef(
                name: "load_older_from_store",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000406",
                    displayName: "Msg User 6",
                    send2MeId: self6,
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "history_freshness": .object([
                            peer6: .string("up_to_date"),
                            grp6: .string("up_to_date"),
                            self6: .string("up_to_date"),
                        ]),
                        "local_conversations": .array([
                            localConv(id: peer6, name: "Peer 6", previewText: "P6 55", previewTsMs: baseTs + 55_000),
                            localConv(id: grp6, isGroup: true, name: "Group 6", members: 3, previewText: "G6 55", previewTsMs: baseTs + 55_000),
                            localConv(id: self6, name: "Cloud của tôi", previewText: "S6 55", previewTsMs: baseTs + 55_000),
                        ]),
                        "local_messages": .array(store6PeerMsgs + store6GrpMsgs + store6SelfMsgs),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000406", displayName: "Msg User 6", send2MeId: self6),
                    MessageRecorderHarness.profileMeScript(uid: "2000406", displayName: "Msg User 6"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string(peer6)])]),
                    .object(["snapshot": .string("peer_opened")]),
                    .object(["cmd": .string("load_older"), "args": .object(["id": .string(peer6)])]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string(grp6)])]),
                    .object(["cmd": .string("load_older"), "args": .object(["id": .string(grp6)])]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string(self6)])]),
                    .object(["cmd": .string("load_older"), "args": .object(["id": .string(self6)])]),
                ]
            ),

            // 7. load_older_from_server: no older stored rows: cursor is the oldest numeric id;
            // fetched 0: has_more false; history_ticks increments.
            MessageRecorderHarness.ScenarioDef(
                name: "load_older_from_server",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000407",
                    displayName: "Msg User 7",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "history_freshness": .object([grp7: .string("up_to_date")]),
                        "contacts": .object([
                            "friends": .array([
                                .object(["id": .string("3000007"), "name": .string("Alice"), "avatar": .string("https://cdn.example.invalid/a.jpg")]),
                            ]),
                        ]),
                        "local_conversations": .array([
                            localConv(id: grp7, isGroup: true, name: "Group 7", members: 4, previewText: "G7 46", previewTsMs: baseTs + 46_000),
                        ]),
                        "local_messages": .array(store7Msgs),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000407", displayName: "Msg User 7"),
                    MessageRecorderHarness.profileMeScript(uid: "2000407", displayName: "Msg User 7"),
                    cloudHistoryScript(
                        path: "/api/cm/getrecentv2",
                        groupMsgs: [
                            wireMsg(msgId: "2000", uidFrom: "3000007", idTo: grp7, dName: "Alice", avt: "https://cdn.example.invalid/a.jpg", ts: baseTs, content: .string("Older 2000")),
                        ],
                        isOld: 1,
                        hasMore: 0,
                        lastMsgId: "2000"
                    ),
                    cloudHistoryScript(
                        path: "/api/cm/getoldv2",
                        groupMsgs: [],
                        isOld: 1,
                        hasMore: 0,
                        lastMsgId: "0"
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string(grp7)])]),
                    .object(["snapshot": .string("after_open")]),
                    .object(["cmd": .string("load_older"), "args": .object(["id": .string(grp7)])]),
                    .object(["snapshot": .string("after_first_load_older")]),
                    .object(["cmd": .string("load_older"), "args": .object(["id": .string(grp7)])]),
                ]
            ),

            // 8. has_more_rules: group / self with totalParsed >= max(10, count / 2) vs below;
            // 1-1 with fewer than 45 in memory.
            MessageRecorderHarness.ScenarioDef(
                name: "has_more_rules",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000408",
                    displayName: "Msg User 8",
                    send2MeId: self8,
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "contacts": .object([
                            "friends": .array([
                                .object(["id": .string(peer8), "name": .string("Peer 8"), "avatar": .string("https://cdn.example.invalid/p8.jpg")]),
                            ]),
                        ]),
                        "local_conversations": .array([
                            localConv(id: grp8True, isGroup: true, name: "Group >= 25", members: 3),
                            localConv(id: grp8False, isGroup: true, name: "Group < 25", members: 3),
                            localConv(id: self8, name: "Cloud của tôi"),
                            localConv(id: peer8, name: "Peer 8", avatar: "https://cdn.example.invalid/p8.jpg"),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000408", displayName: "Msg User 8", send2MeId: self8),
                    MessageRecorderHarness.profileMeScript(uid: "2000408", displayName: "Msg User 8"),
                    // 25 msgs -> group has_more true
                    cloudHistoryScript(
                        groupMsgs: (1...25).map { i in
                            wireMsg(msgId: String(3100 + i), uidFrom: peer8, idTo: grp8True, dName: "Peer 8", ts: baseTs + Int64(i) * 1000, content: .string("GT \(i)"))
                        }
                    ),
                    // 24 msgs -> group has_more false
                    cloudHistoryScript(
                        groupMsgs: (1...24).map { i in
                            wireMsg(msgId: String(3200 + i), uidFrom: peer8, idTo: grp8False, dName: "Peer 8", ts: baseTs + Int64(i) * 1000, content: .string("GF \(i)"))
                        }
                    ),
                    // 25 msgs -> self has_more true
                    cloudHistoryScript(
                        groupMsgs: (1...25).map { i in
                            wireMsg(msgId: String(3300 + i), uidFrom: "2000408", idTo: self8, ts: baseTs + Int64(i) * 1000, content: .string("Self \(i)"))
                        }
                    ),
                    // 30 msgs in 1-1 (< 45 in memory) -> has_more false
                    preloadHistoryScript(
                        convId: peer8,
                        msgs: (1...30).map { i in
                            wireMsg(msgId: String(3400 + i), uidFrom: peer8, idTo: "2000408", dName: "Peer 8", ts: baseTs + Int64(i) * 1000, content: .string("P8 \(i)"))
                        }
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string(grp8True)])]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string(grp8False)])]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string(self8)])]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string(peer8)])]),
                ]
            ),

            // 9. merge_dedupe: same message by id; by client id replacing the optimistic row;
            // reactions preserved on re-merge, dropped when the incoming kind is recalled.
            MessageRecorderHarness.ScenarioDef(
                name: "merge_dedupe",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000409",
                    displayName: "Msg User 9",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "local_conversations": .array([
                            localConv(id: "3000009", name: "Frank"),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "2001",
                                convId: "3000009",
                                clientId: "cli_2001",
                                senderId: "3000009",
                                senderName: "Frank",
                                text: "Saved 1",
                                tsMs: baseTs + 1_000,
                                reactions: [
                                    .object([
                                        "type": .string("5"),
                                        "key": .string("/-heart"),
                                        "emoji": .string("❤️"),
                                        "image": .string(""),
                                        "count": .int(1),
                                        "includesMe": .bool(false),
                                        "names": .array([.string("Frank")]),
                                        "people": .int(1),
                                    ]),
                                ]
                            ),
                            storedMsg(
                                id: "cli_2002",
                                convId: "3000009",
                                clientId: "cli_2002",
                                senderId: "2000409",
                                senderName: "Bạn",
                                senderAvatar: "",
                                isMine: true,
                                text: "Optimistic 2",
                                tsMs: baseTs + 2_000,
                                status: "sending",
                                reactions: [
                                    .object([
                                        "type": .string("3"),
                                        "key": .string("/-strong"),
                                        "emoji": .string("👍"),
                                        "image": .string(""),
                                        "count": .int(1),
                                        "includesMe": .bool(false),
                                        "names": .array([.string("Frank")]),
                                        "people": .int(1),
                                    ]),
                                ]
                            ),
                            storedMsg(
                                id: "cli_2003",
                                convId: "3000009",
                                clientId: "cli_2003",
                                senderId: "2000409",
                                senderName: "Bạn",
                                senderAvatar: "",
                                isMine: true,
                                text: "Optimistic 3",
                                tsMs: baseTs + 3_000,
                                status: "sending",
                                reactions: [
                                    .object([
                                        "type": .string("5"),
                                        "key": .string("/-heart"),
                                        "emoji": .string("❤️"),
                                        "image": .string(""),
                                        "count": .int(1),
                                        "includesMe": .bool(false),
                                        "names": .array([.string("Frank")]),
                                        "people": .int(1),
                                    ]),
                                ]
                            ),
                            storedMsg(
                                id: "2003",
                                convId: "3000009",
                                clientId: "cli_2003",
                                senderId: "2000409",
                                senderName: "Bạn",
                                senderAvatar: "",
                                isMine: true,
                                text: "Tin nhắn đã được thu hồi",
                                kindTag: "recalled",
                                tsMs: baseTs + 4_000,
                                status: "sent"
                            ),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000409", displayName: "Msg User 9"),
                    MessageRecorderHarness.profileMeScript(uid: "2000409", displayName: "Msg User 9"),
                    preloadHistoryScript(convId: "3000009", msgs: [
                        wireMsg(msgId: "2001", cliMsgId: "cli_2001", uidFrom: "3000009", idTo: "2000409", dName: "Frank", avt: "https://cdn.example.invalid/a.jpg", ts: baseTs + 1_000, content: .string("Updated 1")),
                        wireMsg(msgId: "2002", cliMsgId: "cli_2002", uidFrom: "2000409", idTo: "3000009", ts: baseTs + 2_000, content: .string("Acked 2")),
                    ]),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000009")])]),
                ]
            ),

            // 10. merge_e2ee_placeholder: locked E2EE placeholder arriving with a client id:
            // id rewritten on the existing row; skipped when a decrypted row already holds the client id.
            MessageRecorderHarness.ScenarioDef(
                name: "merge_e2ee_placeholder",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000410",
                    displayName: "Msg User 10",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "local_conversations": .array([
                            localConv(id: "3000010", name: "E2EE Peer"),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "cli_e2ee_1",
                                convId: "3000010",
                                clientId: "cli_e2ee_1",
                                senderId: "2000410",
                                senderName: "Bạn",
                                senderAvatar: "",
                                isMine: true,
                                text: "My plain optimistic",
                                tsMs: baseTs + 1_000,
                                status: "sending",
                                isE2EE: true
                            ),
                            storedMsg(
                                id: "3002",
                                convId: "3000010",
                                clientId: "cli_e2ee_2",
                                senderId: "3000010",
                                senderName: "E2EE Peer",
                                text: "Already decrypted",
                                tsMs: baseTs + 2_000,
                                isE2EE: true
                            ),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000410", displayName: "Msg User 10"),
                    MessageRecorderHarness.profileMeScript(uid: "2000410", displayName: "Msg User 10"),
                    preloadHistoryScript(convId: "3000010", msgs: [
                        wireMsg(msgId: "3001", cliMsgId: "cli_e2ee_1", uidFrom: "2000410", idTo: "3000010", ts: baseTs + 1_000, content: .string(lockedCipher), isE2EE: true),
                        wireMsg(msgId: "3003", cliMsgId: "cli_e2ee_2", uidFrom: "3000010", idTo: "2000410", dName: "E2EE Peer", avt: "https://cdn.example.invalid/a.jpg", ts: baseTs + 2_000, content: .string(lockedCipher), isE2EE: true),
                    ]),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000010")])]),
                ]
            ),

            // 11. merge_order: equal dates ordered by id.
            MessageRecorderHarness.ScenarioDef(
                name: "merge_order",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000411",
                    displayName: "Msg User 11",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "local_conversations": .array([
                            localConv(id: "3000011", name: "Order Peer"),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000411", displayName: "Msg User 11"),
                    MessageRecorderHarness.profileMeScript(uid: "2000411", displayName: "Msg User 11"),
                    preloadHistoryScript(convId: "3000011", msgs: [
                        wireMsg(msgId: "1004", uidFrom: "3000011", idTo: "2000411", dName: "Order Peer", avt: "https://cdn.example.invalid/a.jpg", ts: baseTs + 2_000, content: .string("Later")),
                        wireMsg(msgId: "1003", uidFrom: "3000011", idTo: "2000411", dName: "Order Peer", avt: "https://cdn.example.invalid/a.jpg", ts: baseTs + 1_000, content: .string("Tie C")),
                        wireMsg(msgId: "1001", uidFrom: "3000011", idTo: "2000411", dName: "Order Peer", avt: "https://cdn.example.invalid/a.jpg", ts: baseTs + 1_000, content: .string("Tie A")),
                        wireMsg(msgId: "1002", uidFrom: "3000011", idTo: "2000411", dName: "Order Peer", avt: "https://cdn.example.invalid/a.jpg", ts: baseTs + 1_000, content: .string("Tie B")),
                        wireMsg(msgId: "1000", uidFrom: "3000011", idTo: "2000411", dName: "Order Peer", avt: "https://cdn.example.invalid/a.jpg", ts: baseTs, content: .string("Earlier")),
                    ]),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000011")])]),
                ]
            ),

            // 12. known_sender: sender name and avatar filled from identity when the row lacks them.
            MessageRecorderHarness.ScenarioDef(
                name: "known_sender",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000412",
                    displayName: "Msg User 12",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "history_freshness": .object(["3000012": .string("up_to_date")]),
                        "contacts": .object([
                            "friends": .array([
                                .object([
                                    "id": .string("3000012"),
                                    "name": .string("Known Alice"),
                                    "avatar": .string("https://cdn.example.invalid/known_alice.jpg"),
                                ]),
                                .object([
                                    "id": .string("3000013"),
                                    "name": .string("Known Bob"),
                                    "avatar": .string("https://cdn.example.invalid/known_bob.jpg"),
                                ]),
                            ]),
                        ]),
                        "local_conversations": .array([
                            localConv(id: "3000012", name: "Known Alice", avatar: "https://cdn.example.invalid/known_alice.jpg"),
                            localConv(id: "g500012", isGroup: true, name: "Known Sender Group", members: 3),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "2101",
                                convId: "3000012",
                                senderId: "3000012",
                                senderName: "",
                                senderAvatar: "",
                                text: "Stored missing sender",
                                tsMs: baseTs + 1_000
                            ),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000412", displayName: "Msg User 12"),
                    MessageRecorderHarness.profileMeScript(uid: "2000412", displayName: "Msg User 12"),
                    cloudHistoryScript(groupMsgs: [
                        wireMsg(msgId: "2102", uidFrom: "3000013", idTo: "g500012", ts: baseTs + 2_000, content: .string("Wire missing sender")),
                    ]),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000012")])]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("g500012")])]),
                ]
            ),

            // 13. history_page_events: one page with messages, reactions out of order (applied chronologically),
            // an undo and a delete: host calls for U6 handlers in that order.
            MessageRecorderHarness.ScenarioDef(
                name: "history_page_events",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000413",
                    displayName: "Msg User 13",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "contacts": .object([
                            "friends": .array([
                                .object([
                                    "id": .string("3000013"),
                                    "name": .string("Alice"),
                                    "avatar": .string("https://cdn.example.invalid/a.jpg"),
                                ]),
                            ]),
                        ]),
                        "local_conversations": .array([
                            localConv(id: "g500013", isGroup: true, name: "Events Group", members: 3),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000413", displayName: "Msg User 13"),
                    MessageRecorderHarness.profileMeScript(uid: "2000413", displayName: "Msg User 13"),
                    cloudHistoryScript(groupMsgs: [
                        wireMsg(
                            msgId: "4005",
                            uidFrom: "3000013",
                            idTo: "g500013",
                            ts: baseTs + 5_000,
                            msgType: "chat.undo",
                            content: .object(["globalMsgId": .string("4001"), "cliMsgId": .string("cli_4001")])
                        ),
                        wireMsg(
                            msgId: "4004",
                            uidFrom: "3000013",
                            idTo: "g500013",
                            ts: baseTs + 4_000,
                            msgType: "chat.delete",
                            content: .object(["globalDelMsgId": .string("4001"), "clientDelMsgId": .string("cli_4001")])
                        ),
                        wireMsg(
                            msgId: "4003",
                            uidFrom: "3000013",
                            idTo: "g500013",
                            dName: "Alice",
                            ts: baseTs + 3_000,
                            msgType: "chat.reaction",
                            content: .object([
                                "rIcon": .string("/-heart"),
                                "rType": .int(5),
                                "rMsg": .array([.object(["gMsgID": .string("4001"), "cMsgID": .string("cli_4001")])]),
                            ]),
                            actionId: 20
                        ),
                        wireMsg(
                            msgId: "4002",
                            uidFrom: "3000013",
                            idTo: "g500013",
                            dName: "Alice",
                            ts: baseTs + 2_000,
                            msgType: "chat.reaction",
                            content: .object([
                                "rIcon": .string("/-strong"),
                                "rType": .int(3),
                                "rMsg": .array([.object(["gMsgID": .string("4001"), "cMsgID": .string("cli_4001")])]),
                            ]),
                            actionId: 10
                        ),
                        wireMsg(
                            msgId: "4001",
                            cliMsgId: "cli_4001",
                            uidFrom: "3000013",
                            idTo: "g500013",
                            dName: "Alice",
                            avt: "https://cdn.example.invalid/a.jpg",
                            ts: baseTs + 1_000,
                            content: .string("Target message")
                        ),
                    ]),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("g500013")])]),
                ]
            ),

            // 14. sender_profiles: group window with unknown senders: profile fetch for missing names only.
            MessageRecorderHarness.ScenarioDef(
                name: "sender_profiles",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000414",
                    displayName: "Msg User 14",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "contacts": .object([
                            "friends": .array([
                                .object([
                                    "id": .string("3000014"),
                                    "name": .string("Known Sender"),
                                    "avatar": .string("https://cdn.example.invalid/s14.jpg"),
                                ]),
                            ]),
                        ]),
                        "local_conversations": .array([
                            localConv(id: "g500014", isGroup: true, name: "Group 14", members: 4),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000414", displayName: "Msg User 14"),
                    MessageRecorderHarness.profileMeScript(uid: "2000414", displayName: "Msg User 14"),
                    cloudHistoryScript(groupMsgs: [
                        wireMsg(msgId: "5001", uidFrom: "3000014", idTo: "g500014", ts: baseTs + 1_000, content: .string("From known")),
                        wireMsg(msgId: "5002", uidFrom: "3000015", idTo: "g500014", dName: "Inline Named", avt: "https://cdn.example.invalid/s15.jpg", ts: baseTs + 2_000, content: .string("From inline named")),
                        wireMsg(msgId: "5003", uidFrom: "3000016", idTo: "g500014", ts: baseTs + 3_000, content: .string("From unknown")),
                        wireMsg(msgId: "5004", uidFrom: "2000414", idTo: "g500014", ts: baseTs + 4_000, content: .string("From me")),
                    ]),
                    MessageRecorderHarness.httpScript(
                        path: "/api/social/group/members",
                        method: "POST",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "profiles": .object([
                                    "3000016": .object([
                                        "id": .string("3000016"),
                                        "displayName": .string("Resolved Unknown"),
                                        "avatar": .string("https://cdn.example.invalid/s16.jpg"),
                                    ]),
                                ]),
                            ]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("g500014")])]),
                ]
            ),

            // 15. live_push_open_and_closed: a 501 push into the open window and into a closed one:
            // windows, rows, results handed to U3.
            MessageRecorderHarness.ScenarioDef(
                name: "live_push_open_and_closed",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000415",
                    displayName: "Msg User 15",
                    suppress: ["long_poll"],
                    extras: [
                        "local_conversations": .array([
                            localConv(id: "3000015", name: "Open Peer", unread: 0),
                            localConv(id: "3000016", name: "Closed Peer", unread: 0),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000415", displayName: "Msg User 15"),
                    MessageRecorderHarness.profileMeScript(uid: "2000415", displayName: "Msg User 15"),
                    MessageRecorderHarness.wsScript(),
                    MessageRecorderHarness.wsFrameScript(cmd: 1, payload: .object(["error_code": .int(0)])),
                    preloadHistoryScript(convId: "3000015", msgs: []),
                    MessageRecorderHarness.wsFrameScript(
                        cmd: 501,
                        payload: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "msgs": .array([
                                    wireMsg(msgId: "5101", uidFrom: "3000015", idTo: "2000415", dName: "Open Peer", avt: "https://cdn.example.invalid/a.jpg", ts: baseTs + 1_000, content: .string("Push to open")),
                                ]),
                            ]),
                        ])
                    ),
                    MessageRecorderHarness.wsFrameScript(
                        cmd: 501,
                        payload: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "msgs": .array([
                                    wireMsg(msgId: "5102", uidFrom: "3000016", idTo: "2000415", dName: "Closed Peer", avt: "https://cdn.example.invalid/b.jpg", ts: baseTs + 2_000, content: .string("Push to closed")),
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
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000015")])]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("apply_parsed_events"), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("after_open_push")]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("apply_parsed_events"), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("after_closed_push")]),
                    .object(["cmd": .string("close")]),
                ]
            ),
        ]
    }
}

// MARK: - Shared U4 Recorder Harness (messages & bootstrap)

enum MessageRecorderHarness {
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
            .appendingPathComponent("olaz-msg-recorder-\(scenario.name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let storage = RecorderStorageIsolation(prefix: "olaz.msg-recorder")
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

        var bootstrapLogs: [String] = []
        func installBootstrapLogHook(forwardingTo existing: ((String) -> Void)?) {
            EngineLog.shared.onAppend = { rawLine in
                existing?(rawLine)
                if let sp = rawLine.firstIndex(of: " ") {
                    let msg = String(rawLine[rawLine.index(after: sp)...])
                    if msg.hasPrefix("bootstrap: ") {
                        bootstrapLogs.append(msg)
                    }
                }
            }
        }
        installBootstrapLogHook(forwardingTo: nil)

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
                // Includes U4 boundaries (`mark_read`, `refresh_board_pins`, `apply_remote_reaction`,
                // `apply_remote_recall`, `apply_remote_delete`, `apply_mutes`, `refresh_cloud`) and
                // `start_bootstrap` / `show_typing` / `offer_first_login_transfer`.
                return false
            }
        }

        let transitionRecorder = MsgTransitionRecorder(scenarioName: scenario.name) {
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
                    defer {
                        engine.nowMs = savedNowMs
                        engine.randomTag4 = savedRandomTag4
                    }
                    switch cmd {
                    case "start":
                        engine.start()
                        let engineAppend = EngineLog.shared.onAppend
                        installBootstrapLogHook(forwardingTo: engineAppend)
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
                    case "load_older":
                        _ = await engine.bootTask?.value
                        let id = args?["id"]?.stringValue ?? ""
                        engine.loadOlderMessages(id)
                        _ = await engine.loadOlderTask?.value
                        _ = await engine.persistConversationsTask?.value
                    case "bootstrap":
                        _ = await engine.bootTask?.value
                        await engine.performBootstrapSync()
                        _ = await engine.persistConversationsTask?.value
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
                    case "ensure_known_contacts":
                        engine.ensureKnownContactsInConversations()
                        engine.rebuildConversationFlags()
                        engine.rebuildConversationExtras()
                    case "resolve_missing_names":
                        await engine.resolveMissingConversationNames()
                    case "update_contacts":
                        if let contactsArg = args {
                            applyContactsSeed(substituteRuntimeURLs(contactsArg), to: engine)
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
                } else if let label = step["snapshot"]?.stringValue {
                    await engine.settleForRecording()
                    await Task.yield()
                    let snap = await MessageSnapshot.capture(
                        from: engine,
                        bootstrapLogs: bootstrapLogs
                    )
                    snapshots[label] = normalizeRecordedURLs(snap)
                } else {
                    throw RecorderError.invalidStep(scenario: scenario.name, detail: "Unknown step: \(step.canonicalString())")
                }
            }

            _ = await engine.bootTask?.value
            _ = await engine.openConversationTask?.value
            _ = await engine.loadOlderTask?.value
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
                await MessageSnapshot.capture(
                    from: engine,
                    bootstrapLogs: bootstrapLogs
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
        // Ensure ZDB migration never scans the host machine's ~/Library/WebKit directory.
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
        if let md5 = seed["hidden_pin_md5"]?.stringValue, !md5.isEmpty {
            try await store.setPreferenceString(key: "hiddenPinMD5", value: md5)
        }
        if let sha = seed["hidden_pin_hash"]?.stringValue, !sha.isEmpty {
            try await store.setPreferenceString(key: "hiddenPinHash", value: sha)
        }
        if let labelsPref = seed["labels_pref"], labelsPref != .null {
            try await store.setPreferenceData(key: "labels", data: Data(labelsPref.canonicalString().utf8))
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

    private static func syntheticIMEI() -> String {
        "00000000-0000-4000-8000-000000000001-\(ZaloCrypto.md5Hex(ZaloDomains.userAgent))"
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

    static func readySessionSeed(
        userId: String,
        displayName: String = "Msg User",
        avatar: String = "https://cdn.example.invalid/me.jpg",
        phone: String = "+84900000100",
        send2MeId: String? = nil,
        zpwEnk: String = "0123456789abcdef",
        zpwSek: String = "saved.200.a0.sek_u4",
        suppress: [String] = ["long_poll"],
        wsAuthManual: Bool = true,
        extras: [String: CaseJSON] = [:]
    ) -> CaseJSON {
        let acct: [String: CaseJSON] = [
            "userId": .string(userId),
            "displayName": .string(displayName),
            "avatar": .string(avatar),
            "phone": .string(phone),
            "send2MeId": .string(send2MeId ?? "9\(userId)"),
            "dkey": .string("dkey_\(userId)"),
            "zpwEnk": .string(zpwEnk),
            "zpwSek": .string(zpwSek),
            "needSyncMsg": .bool(false),
        ]
        let saved: [String: CaseJSON] = [
            "zpwType": .string("23"),
            "imei": .string(syntheticIMEI()),
            "computerName": .string("TestMac"),
            "domains": defaultFakeDomainsJSON(),
            "sealedSecretsBase64": .null,
            "plainAccount": .object(acct),
            "expiredAt": .null,
        ]
        var seedDict: [String: CaseJSON] = [
            "saved_session": .object(saved),
            "domains": defaultFakeDomainsJSON(),
            "legacy_cookie": .null,
            "prefs": .object([:]),
        ]
        if wsAuthManual {
            seedDict["ws_auth"] = .string("manual")
        }
        if !suppress.isEmpty {
            seedDict["suppress"] = .array(suppress.map(CaseJSON.string))
        }
        for (k, v) in extras {
            seedDict[k] = v
        }
        return .object(seedDict)
    }

    static func loginInfoScript(
        uid: String,
        zpwSek: String = "saved.200.a0.sek_u4",
        displayName: String = "Msg User",
        send2MeId: String? = nil
    ) -> CaseJSON {
        var serviceMap: [String: CaseJSON] = [:]
        for key in ZaloDomains.defaultServiceMapV3.keys {
            serviceMap[key] = .array([.string("http://fake")])
        }
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

    static func profileMeScript(
        uid: String,
        displayName: String = "Msg User",
        avatar: String = "https://cdn.example.invalid/me.jpg",
        phone: String = "+84900000100"
    ) -> CaseJSON {
        httpScript(
            path: "/api/social/profile/me-v2",
            json: .object([
                "error_code": .int(0),
                "data": .object([
                    "profile": .object([
                        "userId": .string(uid),
                        "displayName": .string(displayName),
                        "avatar": .string(avatar),
                        "phoneNumber": .string(phone),
                    ]),
                ]),
            ])
        )
    }

    static func serverInfoScript(error: String? = nil) -> CaseJSON {
        if let error {
            return httpScript(path: "/api/login/getServerInfo", error: error)
        }
        return httpScript(
            path: "/api/login/getServerInfo",
            json: .object(["error_code": .int(0), "data": .object([:])])
        )
    }

    static func reqqrScript(
        tokenId: String = "tok_qr_1",
        qrCnt: String = "https://zalo.me/qr/test-1",
        waitScanPath: String = "/api/login/waitScan",
        waitCfirmPath: String = "/api/login/waitCfirm",
        qrTimeout: Int64 = 60,
        qrRetry: Int64 = 1
    ) -> CaseJSON {
        httpScript(
            path: "/api/login/reqqr",
            json: .object([
                "error_code": .int(0),
                "data": .object([
                    "token_id": .string(tokenId),
                    "qr_cnt": .string(qrCnt),
                    "chk_wait_scan": .string("http://fake\(waitScanPath)"),
                    "chk_wait_cfirm": .string("http://fake\(waitCfirmPath)"),
                    "qr_timeout": .int(qrTimeout),
                    "qr_retry": .int(qrRetry),
                ]),
            ])
        )
    }

    static func httpScript(
        path: String,
        method: String = "GET",
        status: Int64 = 200,
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
        if repeatResponse {
            obj["repeat"] = .bool(true)
        }
        return .object(obj)
    }

    static func wsScript(path: String = "/", accept: Bool = true) -> CaseJSON {
        .object([
            "kind": .string("ws"),
            "path": .string(path),
            "accept": .bool(accept),
        ])
    }

    static func wsFrameScript(
        cmd: Int64,
        subCmd: Int64 = 0,
        payload: CaseJSON
    ) -> CaseJSON {
        .object([
            "kind": .string("ws_frame"),
            "cmd": .int(cmd),
            "sub_cmd": .int(subCmd),
            "payload": payload,
        ])
    }
}

@MainActor
private final class MsgTransitionRecorder {
    private(set) var history: [CaseJSON] = []
    private(set) var cursor: Int = 0
    private var searchStart: Int = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private let scenarioName: String
    private let capture: () -> CaseJSON

    init(scenarioName: String, capture: @escaping () -> CaseJSON) {
        self.scenarioName = scenarioName
        self.capture = capture
        self.history.append(capture())
    }

    func recordTransition() {
        let snap = capture()
        if history.last == snap {
            return
        }
        history.append(snap)
        let pending = waiters
        waiters.removeAll()
        for cont in pending.values {
            cont.resume()
        }
    }

    func advanceSearchToLatestSyncState() {
        searchStart = max(searchStart, history.count - 1)
    }

    func cancelWaiters() {
        let pending = waiters
        waiters.removeAll()
        for cont in pending.values {
            cont.resume()
        }
    }

    func awaitPredicate(_ predicate: CaseJSON, timeoutMs: Int) async throws {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while true {
            if searchStart < history.count {
                for idx in searchStart..<history.count {
                    if SessionSnapshot.matchesPredicate(history[idx], predicate: predicate) {
                        cursor = idx
                        searchStart = idx + 1
                        return
                    }
                }
                searchStart = history.count
            }

            let remaining = deadline - ContinuousClock.now
            if remaining <= .zero {
                let lastDesc = (history.last ?? capture()).canonicalString()
                throw MessageRecorderHarness.RecorderError.timeout(
                    scenario: scenarioName,
                    detail: "Timed out waiting for \(predicate.canonicalString()), current: \(lastDesc)"
                )
            }

            let waiterId = UUID()
            let timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: remaining)
                if let cont = self?.waiters.removeValue(forKey: waiterId) {
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
