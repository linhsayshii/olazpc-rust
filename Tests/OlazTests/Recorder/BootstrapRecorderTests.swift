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
        content: CaseJSON
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
        return .object(obj)
    }

    private static func storedMsg(
        id: String,
        convId: String,
        senderId: String,
        senderName: String = "Peer",
        senderAvatar: String = "https://cdn.example.invalid/a.jpg",
        isMine: Bool = false,
        text: String,
        tsMs: Int64
    ) -> CaseJSON {
        .object([
            "id": .string(id),
            "conv_id": .string(convId),
            "client_id": .string("cli_\(id)"),
            "sender_id": .string(senderId),
            "sender_name": .string(senderName),
            "sender_avatar": .string(senderAvatar),
            "is_mine": .bool(isMine),
            "text": .string(text),
            "kind_tag": .string("text"),
            "ts_ms": .int(tsMs),
            "status": .string("sent"),
        ])
    }

    private static func commonBootstrapScripts(
        aliases: [String: String] = [:],
        pins: [String] = [],
        archivedItems: [CaseJSON] = [],
        chatMutes: [CaseJSON] = [],
        groupMutes: [CaseJSON] = [],
        includeMutes: Bool = false,
        includeLongPoll: Bool = true,
        friends: [CaseJSON] = [],
        groups: [(id: String, name: String)] = [],
        longPollMsgs: [CaseJSON] = [],
        repeatResponses: Bool = false
    ) -> [CaseJSON] {
        var aliasItems: [CaseJSON] = []
        for (uid, alias) in aliases.sorted(by: { $0.key < $1.key }) {
            aliasItems.append(.object(["userId": .string(uid), "alias": .string(alias)]))
        }

        var gridVerMap: [String: CaseJSON] = [:]
        var gridInfoMap: [String: CaseJSON] = [:]
        for g in groups {
            gridVerMap[g.id] = .int(1)
            gridInfoMap[g.id] = .object([
                "grid": .string(g.id),
                "name": .string(g.name),
                "avt": .string("https://cdn.example.invalid/g_\(g.id).jpg"),
                "totalMember": .int(5),
            ])
        }

        var lpData: [String: CaseJSON] = ["more": .int(0)]
        if !longPollMsgs.isEmpty {
            lpData["lastActionId"] = .string("14")
            lpData["msgs"] = .array(longPollMsgs)
        }

        var list: [CaseJSON] = [
            MessageRecorderHarness.httpScript(
                path: "/api/alias/list",
                method: "GET",
                json: .object(["error_code": .int(0), "data": .object(["items": .array(aliasItems)])]),
                repeatResponse: repeatResponses
            ),
            MessageRecorderHarness.httpScript(
                path: "/",
                method: "GET",
                json: includeLongPoll
                    ? .object(["error_code": .int(0), "data": .object(lpData)])
                    : .object(["error_code": .int(-1), "error_message": .string("skip lp")]),
                repeatResponse: repeatResponses
            ),
            MessageRecorderHarness.httpScript(
                path: "/api/pinconvers/list",
                method: "GET",
                json: .object(["error_code": .int(0), "data": .array(pins.map(CaseJSON.string))]),
                repeatResponse: repeatResponses
            ),
            MessageRecorderHarness.httpScript(
                path: "/api/archivedchat/list",
                method: "GET",
                json: .object(["error_code": .int(0), "data": .object(["items": .array(archivedItems), "version": .int(1)])]),
                repeatResponse: repeatResponses
            ),
            MessageRecorderHarness.httpScript(
                path: "/api/social/profile/getmute",
                method: "GET",
                json: (includeMutes || !chatMutes.isEmpty || !groupMutes.isEmpty)
                    ? .object(["error_code": .int(0), "data": .object(["chatEntries": .array(chatMutes), "groupChatEntries": .array(groupMutes)])])
                    : .object(["error_code": .int(-1), "error_message": .string("skip mutes")]),
                repeatResponse: repeatResponses
            ),
            MessageRecorderHarness.httpScript(
                path: "/api/convlabel/get",
                method: "GET",
                json: .object(["error_code": .int(0), "data": .object(["labelData": .string("[]"), "version": .int(1)])]),
                repeatResponse: repeatResponses
            ),
            MessageRecorderHarness.httpScript(
                path: "/api/hiddenconvers/get-all",
                method: "GET",
                json: .object(["error_code": .int(0), "data": .object(["threads": .array([]), "pin": .string("")])]),
                repeatResponse: repeatResponses
            ),
            MessageRecorderHarness.httpScript(
                path: "/api/social/friend/getfriends",
                method: "GET",
                json: .object(["error_code": .int(0), "data": .array(friends)]),
                repeatResponse: repeatResponses
            ),
            MessageRecorderHarness.httpScript(
                path: "/api/group/getlg/v4",
                method: "GET",
                json: .object(["error_code": .int(0), "data": .object(["gridVerMap": .object(gridVerMap), "removedsGroup": .array([])])]),
                repeatResponse: repeatResponses
            ),
        ]
        if !groups.isEmpty {
            list.append(
                MessageRecorderHarness.httpScript(
                    path: "/api/group/getmg-v2",
                    method: "POST",
                    json: .object(["error_code": .int(0), "data": .object(["gridInfoMap": .object(gridInfoMap)])]),
                    repeatResponse: repeatResponses || groups.count > 50
                )
            )
        }
        list.append(contentsOf: [
            MessageRecorderHarness.httpScript(
                path: "/api/friend/requested/list",
                method: "GET",
                json: .object(["error_code": .int(0), "data": .array([])]),
                repeatResponse: repeatResponses
            ),
            MessageRecorderHarness.httpScript(
                path: "/api/friend/recommendsv2/list",
                method: "GET",
                json: .object(["error_code": .int(0), "data": .object(["recommItems": .array([])])]),
                repeatResponse: repeatResponses
            ),
        ])
        return list
    }

    private static func emptyRecentCloudScript(repeatResponse: Bool = false) -> CaseJSON {
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
            ]),
            repeatResponse: repeatResponse
        )
    }

    // MARK: - Scenarios (16-25)

    private static func bootstrapScenarios() -> [MessageRecorderHarness.ScenarioDef] {
        let baseTs: Int64 = 1700000000000

        // Scenario 22 data: 55 peers, 55 groups
        let clearUnreads22Peers: [CaseJSON] = (1...55).map { idx in
            .object([
                "idTo": .string(String(3000100 + idx)),
                "lastMsgId": .int(Int64(100 + idx)),
            ])
        }
        let clearUnreads22Groups: [CaseJSON] = [
            .object(["idTo": .string("500102"), "isGroup": .int(1), "lastMsgId": .int(1000)]),
            .object(["idTo": .string("500101"), "isGroup": .int(1), "lastMsgId": .int(500)]),
            .object(["idTo": .string("500155"), "isGroup": .int(1), "lastMsgId": .int(300)]),
            .object(["idTo": .string("500154"), "isGroup": .int(1), "lastMsgId": .int(200)]),
        ]
        let friends22: [CaseJSON] = (1...55).map { idx in
            .object([
                "userId": .string(String(3000100 + idx)),
                "displayName": .string("Peer \(idx)"),
                "avatar": .string("https://cdn.example.invalid/p_\(idx).jpg"),
            ])
        }
        let groups22: [(id: String, name: String)] = (1...55).map { idx in
            (id: String(500100 + idx), name: "Group \(idx)")
        }

        // Scenario 24 data: 26 groups
        let groups24: [(id: String, name: String)] = (1...26).map { idx in
            (id: String(500200 + idx), name: "Grp24 \(idx)")
        }

        return [
            // 16. freshness_probe: preload batch with one conversation whose newest message is stored (upToDate)
            // and one that is not (stale); a later stale is never overwritten by upToDate.
            MessageRecorderHarness.ScenarioDef(
                name: "freshness_probe",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000516",
                    displayName: "Boot User 16",
                    send2MeId: "9200516",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "history_full_refresh_at": .string("1700090000.0"),
                        "contacts": .object([
                            "friends": .array([
                                .object(["id": .string("3000016"), "name": .string("UpToDate Peer"), "avatar": .string("https://cdn.example.invalid/16.jpg")]),
                                .object(["id": .string("3000017"), "name": .string("Stale Peer"), "avatar": .string("https://cdn.example.invalid/17.jpg")]),
                            ]),
                        ]),
                        "local_messages": .array([
                            storedMsg(id: "6001", convId: "3000016", senderId: "3000016", senderName: "UpToDate Peer", text: "Old A", tsMs: baseTs + 1_000),
                            storedMsg(id: "6002", convId: "3000016", senderId: "3000016", senderName: "UpToDate Peer", text: "New A", tsMs: baseTs + 2_000),
                            storedMsg(id: "6101", convId: "3000017", senderId: "3000017", senderName: "Stale Peer", text: "Old B", tsMs: baseTs + 1_000),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000516", displayName: "Boot User 16", send2MeId: "9200516"),
                    MessageRecorderHarness.profileMeScript(uid: "2000516", displayName: "Boot User 16"),
                ] + commonBootstrapScripts() + [
                    MessageRecorderHarness.httpScript(
                        path: "/api/preloadconvers/get-last-msgs",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "msgs": .object([
                                    "3000016": .array([
                                        wireMsg(msgId: "6002", uidFrom: "3000016", idTo: "2000516", dName: "UpToDate Peer", avt: "https://cdn.example.invalid/16.jpg", ts: baseTs + 2_000, content: .string("New A")),
                                    ]),
                                    "3000017": .array([
                                        wireMsg(msgId: "6102", uidFrom: "3000017", idTo: "2000516", dName: "Stale Peer", avt: "https://cdn.example.invalid/17.jpg", ts: baseTs + 2_000, content: .string("New B")),
                                    ]),
                                ]),
                            ]),
                        ])
                    ),
                    emptyRecentCloudScript(),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("bootstrap"), "now_ms": .int(1700100000000)]),
                    .object(["snapshot": .string("after_bootstrap")]),
                    // Now 6102 IS in SQLite, yet re-probing must NEVER overwrite stale with up_to_date.
                    .object([
                        "cmd": .string("apply_batch"),
                        "args": .object([
                            "payload": .object([
                                "data": .object([
                                    "msgs": .object([
                                        "3000017": .array([
                                            wireMsg(msgId: "6102", uidFrom: "3000017", idTo: "2000516", dName: "Stale Peer", avt: "https://cdn.example.invalid/17.jpg", ts: baseTs + 2_000, content: .string("New B")),
                                        ]),
                                    ]),
                                ]),
                            ]),
                            "probe_freshness": .bool(true),
                        ]),
                    ]),
                ]
            ),

            // 17. full_refresh_due: no pref, older than 24 h, and a future timestamp:
            // nothing skipped; pref written with now_ms at the end.
            MessageRecorderHarness.ScenarioDef(
                name: "full_refresh_due",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000517",
                    displayName: "Boot User 17",
                    send2MeId: "9200517",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "local_messages": .array([
                            storedMsg(id: "7001", convId: "g500017", senderId: "3000017", senderName: "Peer", text: "Grp stored", tsMs: baseTs + 1_000),
                            storedMsg(id: "7002", convId: "9200517", senderId: "2000517", senderName: "Bạn", senderAvatar: "", isMine: true, text: "Self stored", tsMs: baseTs + 1_000),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000517", displayName: "Boot User 17", send2MeId: "9200517"),
                    MessageRecorderHarness.profileMeScript(uid: "2000517", displayName: "Boot User 17"),
                ] + commonBootstrapScripts(
                    groups: [(id: "500017", name: "Due Group")],
                    repeatResponses: true
                ) + [
                    MessageRecorderHarness.httpScript(
                        path: "/api/preloadconvers/get-last-msgs",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "msgs": .object([
                                    "g500017": .array([
                                        wireMsg(msgId: "7001", uidFrom: "3000017", idTo: "g500017", dName: "Peer", avt: "https://cdn.example.invalid/a.jpg", ts: baseTs + 1_000, content: .string("Grp stored")),
                                    ]),
                                    "9200517": .array([
                                        wireMsg(msgId: "7002", uidFrom: "2000517", idTo: "9200517", ts: baseTs + 1_000, content: .string("Self stored")),
                                    ]),
                                ]),
                            ]),
                        ]),
                        repeatResponse: true
                    ),
                    emptyRecentCloudScript(repeatResponse: true),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    // 1) No pref -> due
                    .object(["cmd": .string("bootstrap"), "now_ms": .int(1700100000000)]),
                    .object(["snapshot": .string("after_no_pref")]),
                    // 2) Exactly 24h later -> due
                    .object(["cmd": .string("bootstrap"), "now_ms": .int(1700186400000)]),
                    .object(["snapshot": .string("after_24h")]),
                    // 3) Future timestamp (last > now) -> due
                    .object(["cmd": .string("bootstrap"), "now_ms": .int(1700150000000)]),
                ]
            ),

            // 18. full_refresh_not_due: pref 1 h old: up-to-date threads skipped.
            MessageRecorderHarness.ScenarioDef(
                name: "full_refresh_not_due",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000518",
                    displayName: "Boot User 18",
                    send2MeId: "9200518",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "history_full_refresh_at": .string("1700096400.0"),
                        "local_messages": .array([
                            storedMsg(id: "7101", convId: "g500018", senderId: "3000018", senderName: "Peer 18", text: "Grp18", tsMs: baseTs + 1_000),
                            storedMsg(id: "7102", convId: "9200518", senderId: "2000518", senderName: "Bạn", senderAvatar: "", isMine: true, text: "Self18", tsMs: baseTs + 1_000),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000518", displayName: "Boot User 18", send2MeId: "9200518"),
                    MessageRecorderHarness.profileMeScript(uid: "2000518", displayName: "Boot User 18"),
                ] + commonBootstrapScripts(
                    friends: [
                        .object(["userId": .string("3000018"), "displayName": .string("Peer 18"), "avatar": .string("https://cdn.example.invalid/18.jpg")]),
                    ],
                    groups: [
                        (id: "500018", name: "UpToDate Grp"),
                        (id: "500019", name: "Stale Grp"),
                    ]
                ) + [
                    MessageRecorderHarness.httpScript(
                        path: "/api/preloadconvers/get-last-msgs",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "msgs": .object([
                                    "g500018": .array([
                                        wireMsg(msgId: "7101", uidFrom: "3000018", idTo: "g500018", dName: "Peer 18", avt: "https://cdn.example.invalid/18.jpg", ts: baseTs + 1_000, content: .string("Grp18")),
                                    ]),
                                    "g500019": .array([
                                        wireMsg(msgId: "7103", uidFrom: "3000018", idTo: "g500019", dName: "Peer 18", avt: "https://cdn.example.invalid/18.jpg", ts: baseTs + 1_000, content: .string("Grp19")),
                                    ]),
                                    "9200518": .array([
                                        wireMsg(msgId: "7102", uidFrom: "2000518", idTo: "9200518", ts: baseTs + 1_000, content: .string("Self18")),
                                    ]),
                                ]),
                            ]),
                        ]),
                        repeatResponse: true
                    ),
                    // Only g500019 is fetched (g500018 and 9200518 are up to date and skipped).
                    emptyRecentCloudScript(),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("bootstrap"), "now_ms": .int(1700100000000)]),
                ]
            ),

            // 19. aliases_auth_error: alias fetch fails with an auth code:
            // notice "Phiên đăng nhập không hợp lệ hoặc đã hết hạn. Vui lòng quét mã QR để đăng nhập lại.", nothing else requested.
            MessageRecorderHarness.ScenarioDef(
                name: "aliases_auth_error",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000519",
                    displayName: "Boot User 19",
                    send2MeId: "9200519",
                    suppress: ["ws", "long_poll"]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000519", displayName: "Boot User 19", send2MeId: "9200519"),
                    MessageRecorderHarness.profileMeScript(uid: "2000519", displayName: "Boot User 19"),
                    MessageRecorderHarness.httpScript(
                        path: "/api/alias/list",
                        method: "GET",
                        json: .object(["error_code": .int(600), "error_message": .string("Session expired")])
                    ),
                    MessageRecorderHarness.serverInfoScript(),
                    MessageRecorderHarness.reqqrScript(tokenId: "tok_alias_600", qrCnt: "https://zalo.me/qr/alias-600"),
                    MessageRecorderHarness.httpScript(path: "/api/login/waitScan", error: "timeout"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("bootstrap"), "now_ms": .int(1700100000000)]),
                    .object(["await": .object(["phase": .string("login"), "step": .string("waiting_scan")]), "timeout_ms": .int(5000)]),
                ]
            ),

            // 20. pins_archived_mutes: prefs written; mutes handed to U16 host with start fallback now_ms.
            MessageRecorderHarness.ScenarioDef(
                name: "pins_archived_mutes",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000520",
                    displayName: "Boot User 20",
                    send2MeId: "9200520",
                    suppress: ["ws", "long_poll"]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000520", displayName: "Boot User 20", send2MeId: "9200520"),
                    MessageRecorderHarness.profileMeScript(uid: "2000520", displayName: "Boot User 20"),
                ] + commonBootstrapScripts(
                    pins: ["u3000020", "g500020"],
                    archivedItems: [
                        .object(["id": .string("3000021"), "type": .int(0)]),
                        .object(["id": .string("500021"), "type": .int(1)]),
                    ],
                    chatMutes: [
                        .object(["id": .string("3000020"), "duration": .int(3600), "startTime": .int(1700000000)]),
                        .object(["id": .string("3000022"), "duration": .int(-1)]),
                    ],
                    groupMutes: [
                        .object(["id": .string("500020"), "duration": .int(7200)]),
                    ],
                    includeMutes: true,
                    includeLongPoll: false,
                    friends: [
                        .object(["userId": .string("3000020"), "displayName": .string("Pinned Peer 20"), "avatar": .string("https://cdn.example.invalid/p20.jpg")]),
                    ]
                ) + [
                    MessageRecorderHarness.httpScript(
                        path: "/api/preloadconvers/get-last-msgs",
                        method: "GET",
                        json: .object(["error_code": .int(0), "data": .object(["msgs": .object([:])])])
                    ),
                    emptyRecentCloudScript(),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("bootstrap"), "now_ms": .int(1700000200000)]),
                ]
            ),

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
                        json: .object(["error_code": .int(-1), "error_message": .string("skip mutes")])
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
                    emptyRecentCloudScript(),
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
                    emptyRecentCloudScript(),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("bootstrap"), "now_ms": .int(1700000100000)]),
                ]
            ),

            // 22. preload_chunks: peers top 50 by rank plus groups top 50 by pin, rank, id;
            // chunks of 25 in that order.
            MessageRecorderHarness.ScenarioDef(
                name: "preload_chunks",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000522",
                    displayName: "Boot User 22",
                    send2MeId: "9200522",
                    suppress: ["ws", "long_poll"]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000522", displayName: "Boot User 22", send2MeId: "9200522"),
                    MessageRecorderHarness.profileMeScript(uid: "2000522", displayName: "Boot User 22"),
                ] + commonBootstrapScripts(
                    pins: ["g500101", "g500102"],
                    friends: friends22,
                    groups: groups22
                ) + [
                    // Overview response with 55 ranked peers + 4 ranked groups (2 pinned)
                    MessageRecorderHarness.httpScript(
                        path: "/api/preloadconvers/get-last-msgs",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "clearUnreads": .array(clearUnreads22Peers + clearUnreads22Groups),
                            ]),
                        ])
                    ),
                    // 4 chunks of 25
                    MessageRecorderHarness.httpScript(
                        path: "/api/preloadconvers/get-last-msgs",
                        method: "GET",
                        json: .object(["error_code": .int(0), "data": .object(["msgs": .object([:])])]),
                        repeatResponse: true
                    ),
                    emptyRecentCloudScript(repeatResponse: true),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("bootstrap"), "now_ms": .int(1700100000000)]),
                ]
            ),

            // 23. self_cloud_history: fetched when not up to date, skipped when up to date.
            MessageRecorderHarness.ScenarioDef(
                name: "self_cloud_history",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000523",
                    displayName: "Boot User 23",
                    send2MeId: "9200523",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "history_full_refresh_at": .string("1700096400.0"),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000523", displayName: "Boot User 23", send2MeId: "9200523"),
                    MessageRecorderHarness.profileMeScript(uid: "2000523", displayName: "Boot User 23"),
                ] + commonBootstrapScripts(repeatResponses: true) + [
                    // Bootstrap #1 overview: empty -> self 9200523 is not up to date -> fetches getrecentv2
                    MessageRecorderHarness.httpScript(
                        path: "/api/preloadconvers/get-last-msgs",
                        method: "GET",
                        json: .object(["error_code": .int(0), "data": .object(["msgs": .object([:])])])
                    ),
                    MessageRecorderHarness.httpScript(
                        path: "/api/cm/getrecentv2",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "groupMsgs": .array([
                                    wireMsg(msgId: "8002", uidFrom: "2000523", idTo: "9200523", ts: baseTs + 2_000, content: .string("Self note 2")),
                                    wireMsg(msgId: "8001", uidFrom: "2000523", idTo: "9200523", ts: baseTs + 1_000, content: .string("Self note 1")),
                                ]),
                                "isOld": .int(0),
                                "hasMore": .int(0),
                                "lastMsgId": .string("0"),
                            ]),
                        ])
                    ),
                    // Bootstrap #2 overview: returns newest self msg 8002 (now stored) -> 9200523 is upToDate -> skips getrecentv2
                    MessageRecorderHarness.httpScript(
                        path: "/api/preloadconvers/get-last-msgs",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "msgs": .object([
                                    "9200523": .array([
                                        wireMsg(msgId: "8002", uidFrom: "2000523", idTo: "9200523", ts: baseTs + 2_000, content: .string("Self note 2")),
                                    ]),
                                ]),
                            ]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("bootstrap"), "now_ms": .int(1700100000000)]),
                    .object(["snapshot": .string("after_first_bootstrap")]),
                    .object(["cmd": .string("bootstrap"), "now_ms": .int(1700100100000)]),
                ]
            ),

            // 24. group_history: first 24 groups not up to date, 6 concurrent, count 30.
            MessageRecorderHarness.ScenarioDef(
                name: "group_history",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000524",
                    displayName: "Boot User 24",
                    send2MeId: "9200524",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "history_full_refresh_at": .string("1700096400.0"),
                        "contacts": .object([
                            "friends": .array([
                                .object(["id": .string("3000024"), "name": .string("Peer 24"), "avatar": .string("https://cdn.example.invalid/24.jpg")]),
                            ]),
                        ]),
                        "local_messages": .array([
                            storedMsg(id: "9001", convId: "g500201", senderId: "3000024", senderName: "Peer 24", text: "Latest pinned grp", tsMs: baseTs + 1_000),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000524", displayName: "Boot User 24", send2MeId: "9200524"),
                    MessageRecorderHarness.profileMeScript(uid: "2000524", displayName: "Boot User 24"),
                ] + commonBootstrapScripts(
                    pins: ["g500201"],
                    friends: [
                        .object(["userId": .string("3000024"), "displayName": .string("Peer 24"), "avatar": .string("https://cdn.example.invalid/24.jpg")]),
                    ],
                    groups: groups24
                ) + [
                    MessageRecorderHarness.httpScript(
                        path: "/api/preloadconvers/get-last-msgs",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "msgs": .object([
                                    "g500201": .array([
                                        wireMsg(msgId: "9001", uidFrom: "3000024", idTo: "g500201", dName: "Peer 24", avt: "https://cdn.example.invalid/24.jpg", ts: baseTs + 1_000, content: .string("Latest pinned grp")),
                                    ]),
                                ]),
                            ]),
                        ]),
                        repeatResponse: true
                    ),
                    emptyRecentCloudScript(repeatResponse: true),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("bootstrap"), "now_ms": .int(1700100000000)]),
                ]
            ),

            // 25. finalize: names resolved, rows persisted, drain awaited, full-refresh pref, refresh_cloud host call;
            // engine log shapes bootstrap: history full= groups_fetch= up_to_date= and bootstrap: convs= friends= groups=.
            MessageRecorderHarness.ScenarioDef(
                name: "finalize",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000525",
                    displayName: "Boot User 25",
                    send2MeId: "9200525",
                    suppress: ["ws", "long_poll"]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000525", displayName: "Boot User 25", send2MeId: "9200525"),
                    MessageRecorderHarness.profileMeScript(uid: "2000525", displayName: "Boot User 25"),
                ] + commonBootstrapScripts(
                    aliases: ["3000025": "Aliased Peer 25"],
                    friends: [
                        .object(["userId": .string("3000025"), "displayName": .string("Friend 25"), "avatar": .string("https://cdn.example.invalid/f25.jpg")]),
                    ],
                    groups: [(id: "500025", name: "Group 25")],
                    longPollMsgs: [
                        wireMsg(msgId: "9502", uidFrom: "3000025", idTo: "2000525", dName: "Friend 25", avt: "https://cdn.example.invalid/f25.jpg", ts: baseTs + 2_000, content: .string("Drained LP")),
                    ]
                ) + [
                    // Preload overview includes message from unknown peer 3000026 lacking dName/avt -> triggers resolveMissingConversationNames
                    MessageRecorderHarness.httpScript(
                        path: "/api/preloadconvers/get-last-msgs",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "msgs": .object([
                                    "3000026": .array([
                                        wireMsg(msgId: "9503", uidFrom: "3000026", idTo: "2000525", ts: baseTs + 3_000, content: .string("Unknown peer preload")),
                                    ]),
                                ]),
                            ]),
                        ])
                    ),
                    // Chunk 1 ([g500025])
                    MessageRecorderHarness.httpScript(
                        path: "/api/preloadconvers/get-last-msgs",
                        method: "GET",
                        json: .object(["error_code": .int(0), "data": .object(["msgs": .object([:])])])
                    ),
                    // Self cloud history (empty)
                    emptyRecentCloudScript(),
                    // Group g500025 history
                    MessageRecorderHarness.httpScript(
                        path: "/api/cm/getrecentv2",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "groupMsgs": .array([
                                    wireMsg(msgId: "9501", uidFrom: "3000025", idTo: "g500025", dName: "Friend 25", avt: "https://cdn.example.invalid/f25.jpg", ts: baseTs + 1_000, content: .string("Group history msg")),
                                ]),
                                "isOld": .int(0),
                                "hasMore": .int(0),
                                "lastMsgId": .string("0"),
                            ]),
                        ])
                    ),
                    // resolveMissingConversationNames for 3000026
                    MessageRecorderHarness.httpScript(
                        path: "/api/social/group/members",
                        method: "POST",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "profiles": .object([
                                    "3000026": .object([
                                        "id": .string("3000026"),
                                        "displayName": .string("Resolved Peer 26"),
                                        "avatar": .string("https://cdn.example.invalid/p26.jpg"),
                                    ]),
                                ]),
                            ]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("bootstrap"), "now_ms": .int(1700300000000)]),
                ]
            ),
        ]
    }
}
