import Foundation
import XCTest
@testable import Olaz

final class NotifyRecorderTests: XCTestCase {
    func testNotifyScenarios() async throws {
        try await NotifyRecorderHarness.runDomainSuite(
            domain: "notify",
            scenarios: Self.notifyScenarios()
        )
    }

    // MARK: - Helpers

    private static let baseTs: Int64 = 1_700_000_000_000

    private static func localConv(
        id: String,
        isGroup: Bool = false,
        name: String,
        avatar: String = "",
        members: Int64 = 0,
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
            "unread": .int(0),
            "preview_text": .string(previewText),
            "preview_ts_ms": .int(previewTsMs),
            "preview_from_me": .bool(previewFromMe),
        ])
    }

    private static func emptySyncScripts() -> [CaseJSON] {
        [
            NotifyRecorderHarness.httpScript(
                path: "/api/social/friend/getfriends",
                method: "GET",
                json: .object([
                    "error_code": .int(0),
                    "data": .object(["list": .array([])]),
                ])
            ),
            NotifyRecorderHarness.httpScript(
                path: "/api/group/getlg/v4",
                method: "GET",
                json: .object([
                    "error_code": .int(0),
                    "data": .object(["gridVerMap": .object([:])]),
                ])
            ),
            NotifyRecorderHarness.httpScript(
                path: "/api/friend/requested/list",
                method: "GET",
                json: .object([
                    "error_code": .int(0),
                    "data": .object(["list": .array([])]),
                ])
            ),
            NotifyRecorderHarness.httpScript(
                path: "/api/friend/recommendsv2/list",
                method: "GET",
                json: .object([
                    "error_code": .int(0),
                    "data": .object(["recommItems": .array([])]),
                ])
            ),
        ]
    }

    // MARK: - Scenarios

    private static func notifyScenarios() -> [NotifyRecorderHarness.ScenarioDef] {
        [
            // 1. alias: save (trimmed), clear (empty -> /api/alias/remove), API failure
            NotifyRecorderHarness.ScenarioDef(
                name: "alias",
                seed: NotifyRecorderHarness.readySessionSeed(
                    userId: "2001601",
                    displayName: "Notify User 1",
                    extras: [
                        "now_ms": .int(baseTs),
                        "contacts": .object([
                            "aliases": .object(["3001659": .string("Existing")]),
                        ]),
                    ]
                ),
                server: [
                    NotifyRecorderHarness.loginInfoScript(uid: "2001601", displayName: "Notify User 1"),
                    NotifyRecorderHarness.profileMeScript(uid: "2001601", displayName: "Notify User 1"),
                    NotifyRecorderHarness.httpScript(
                        path: "/api/alias/update",
                        method: "GET",
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                    NotifyRecorderHarness.httpScript(
                        path: "/api/alias/remove",
                        method: "GET",
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                    NotifyRecorderHarness.httpScript(
                        path: "/api/alias/update",
                        method: "GET",
                        status: 500,
                        raw: "alias error"
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("start_bootstrap"), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("save_alias"), "args": .object(["uid": .string("3001650"), "name": .string("  Em Lan  ")])]),
                    .object(["snapshot": .string("after_save")]),
                    .object(["cmd": .string("save_alias"), "args": .object(["uid": .string("3001650"), "name": .string("   ")])]),
                    .object(["snapshot": .string("after_clear")]),
                    .object(["cmd": .string("save_alias"), "args": .object(["uid": .string("3001651"), "name": .string("Fail Alias")])]),
                ]
            ),

            // 2. card_actions: call:back (voice & video), sticker ref (valid + cateId<=0 quirk), bad refs (0_0, x_1, 1_2_3), unsupported
            NotifyRecorderHarness.ScenarioDef(
                name: "card_actions",
                seed: NotifyRecorderHarness.readySessionSeed(
                    userId: "2001601",
                    displayName: "Notify User 2",
                    extras: [
                        "now_ms": .int(baseTs),
                        "next_client_id": .int(630001),
                        "contacts": .object([
                            "cached_profiles": .object([
                                "3001630": .object(["name": .string("Voice Peer"), "avatar": .string("https://cdn.example.invalid/p30.jpg")]),
                                "3001631": .object(["name": .string("Video Peer"), "avatar": .string("https://cdn.example.invalid/p31.jpg")]),
                            ]),
                        ]),
                        "local_conversations": .array([
                            localConv(id: "3001630", name: "Voice Peer"),
                            localConv(id: "3001631", name: "Video Peer"),
                        ]),
                        "local_messages": .array([
                            .object([
                                "id": .string("9001630"),
                                "conv_id": .string("3001630"),
                                "sender_id": .string("3001630"),
                                "sender_name": .string("Voice Peer"),
                                "is_mine": .bool(false),
                                "text": .string("Cuộc gọi thoại"),
                                "kind_tag": .string("call"),
                                "kind": .object(["type": .string("call"), "video": .bool(false), "missed": .bool(true), "duration": .int(0), "title": .string("Cuộc gọi nhỡ"), "detail": .string("")]),
                                "ts_ms": .int(baseTs - 5000),
                            ]),
                            .object([
                                "id": .string("9001631"),
                                "conv_id": .string("3001631"),
                                "sender_id": .string("3001631"),
                                "sender_name": .string("Video Peer"),
                                "is_mine": .bool(false),
                                "text": .string("Cuộc gọi video"),
                                "kind_tag": .string("call"),
                                "kind": .object(["type": .string("call"), "video": .bool(true), "missed": .bool(false), "duration": .int(35), "title": .string("Cuộc gọi video"), "detail": .string("35 giây")]),
                                "ts_ms": .int(baseTs - 4000),
                            ]),
                        ]),
                        "history_freshness": .object([
                            "3001630": .string("up_to_date"),
                            "3001631": .string("up_to_date"),
                        ]),
                    ]
                ),
                server: [
                    NotifyRecorderHarness.loginInfoScript(uid: "2001601", displayName: "Notify User 2"),
                    NotifyRecorderHarness.profileMeScript(uid: "2001601", displayName: "Notify User 2"),
                    NotifyRecorderHarness.httpScript(
                        path: "/api/message/sticker",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("srv_st_1630")])])
                    ),
                    NotifyRecorderHarness.httpScript(
                        path: "/api/message/sticker",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("srv_st_1631")])])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("start_bootstrap"), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3001630")])]),
                    .object(["cmd": .string("card_action"), "args": .object(["conv_id": .string("3001630"), "msg_id": .string("9001630"), "ref": .string("call:back")])]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3001631")])]),
                    .object(["cmd": .string("card_action"), "args": .object(["conv_id": .string("3001631"), "msg_id": .string("9001631"), "ref": .string("call:back")])]),
                    .object(["cmd": .string("card_action"), "args": .object(["conv_id": .string("3001630"), "msg_id": .string("9001630"), "ref": .string("12_34")])]),
                    // Quirk: cateId <= 0 is accepted as long as stickerId > 0
                    .object(["cmd": .string("card_action"), "args": .object(["conv_id": .string("3001630"), "msg_id": .string("9001630"), "ref": .string("0_5")])]),
                    .object(["cmd": .string("card_action"), "args": .object(["conv_id": .string("3001630"), "msg_id": .string("9001630"), "ref": .string("0_0")])]),
                    .object(["cmd": .string("card_action"), "args": .object(["conv_id": .string("3001630"), "msg_id": .string("9001630"), "ref": .string("x_1")])]),
                    .object(["cmd": .string("card_action"), "args": .object(["conv_id": .string("3001630"), "msg_id": .string("9001630"), "ref": .string("1_2_3")])]),
                    .object(["cmd": .string("card_action"), "args": .object(["conv_id": .string("3001630"), "msg_id": .string("9001630"), "ref": .string("unsupported:cmd")])]),
                ]
            ),

            // 3. contact_and_friend: self, friend, fetched profile, fetch failure; prep states (me, friend, requested, requesting, ready); submit ok & failure
            NotifyRecorderHarness.ScenarioDef(
                name: "contact_and_friend",
                seed: NotifyRecorderHarness.readySessionSeed(
                    userId: "2001601",
                    displayName: "Me User",
                    extras: [
                        "now_ms": .int(baseTs),
                        "contacts": .object([
                            "friends": .array([
                                .object([
                                    "id": .string("3001641"),
                                    "name": .string("Friend One"),
                                    "zalo_name": .string("Zalo Friend One"),
                                    "avatar": .string("https://cdn.example.invalid/f1.jpg"),
                                ]),
                            ]),
                            "sent": .array([
                                .object(["id": .string("3001642"), "name": .string("Sent Peer"), "message": .string("Hi")]),
                            ]),
                            "received": .array([
                                .object(["id": .string("3001643"), "name": .string("Received Peer"), "message": .string("Hey")]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    NotifyRecorderHarness.loginInfoScript(uid: "2001601", displayName: "Me User"),
                    NotifyRecorderHarness.profileMeScript(uid: "2001601", displayName: "Me User"),
                    // contactProfile("3001644") -> ok
                    NotifyRecorderHarness.httpScript(
                        path: "/api/social/group/members",
                        method: "POST",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "changed_profiles": .object([
                                    "3001644": .object([
                                        "userId": .string("3001644"),
                                        "displayName": .string("Fetched Stranger"),
                                        "zaloName": .string("Zalo Stranger"),
                                        "avatar": .string("https://cdn.example.invalid/s44.jpg"),
                                    ]),
                                ]),
                                "unchanged_profiles": .object([:]),
                            ]),
                        ])
                    ),
                    // contactProfile("3001645") -> HTTP 500 failure
                    NotifyRecorderHarness.httpScript(
                        path: "/api/social/group/members",
                        method: "POST",
                        status: 500,
                        raw: "profile error"
                    ),
                    // submitFriendRequest ok -> refreshContacts() sync scripts
                    NotifyRecorderHarness.httpScript(
                        path: "/api/friend/sendreq",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                ] + emptySyncScripts() + [
                    // submitFriendRequest failure
                    NotifyRecorderHarness.httpScript(
                        path: "/api/friend/sendreq",
                        method: "POST",
                        status: 500,
                        raw: "sendreq failed"
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("start_bootstrap"), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("contact_card"), "args": .object(["uid": .string("2001601")])]),
                    .object(["cmd": .string("contact_card"), "args": .object(["uid": .string("3001641")])]),
                    .object(["cmd": .string("contact_card"), "args": .object(["uid": .string("3001644")])]),
                    .object(["cmd": .string("contact_profile"), "args": .object(["uid": .string("2001601")])]),
                    .object(["cmd": .string("contact_profile"), "args": .object(["uid": .string("3001641")])]),
                    .object(["cmd": .string("contact_profile"), "args": .object(["uid": .string("3001644")])]),
                    .object(["cmd": .string("contact_profile"), "args": .object(["uid": .string("3001645")])]),
                    .object(["cmd": .string("contact_profile"), "args": .object(["uid": .string("")])]),
                    .object(["cmd": .string("prep_friend"), "args": .object(["uid": .string("2001601"), "via": .string("add")])]),
                    .object(["cmd": .string("prep_friend"), "args": .object(["uid": .string("3001641"), "via": .string("add")])]),
                    .object(["cmd": .string("prep_friend"), "args": .object(["uid": .string("3001642"), "via": .string("card")])]),
                    .object(["cmd": .string("prep_friend"), "args": .object(["uid": .string("3001643"), "via": .string("none")])]),
                    .object(["cmd": .string("prep_friend"), "args": .object(["uid": .string("3001644"), "via": .string("card")])]),
                    .object(["cmd": .string("submit_friend"), "args": .object(["uid": .string("3001644"), "message": .string("Xin chào, mình là Me User.")])]),
                    .object(["cmd": .string("submit_friend"), "args": .object(["uid": .string("3001645"), "message": .string("Hi")])]),
                ]
            ),

            // 4. incoming_decision: muted, notifications off, 1-1 & group title fallbacks, "Người dùng Zalo" skipped, avatar chain + fetchProfiles (ok/fail/empty), preview off, sound off (silent)
            NotifyRecorderHarness.ScenarioDef(
                name: "incoming_decision",
                seed: NotifyRecorderHarness.readySessionSeed(
                    userId: "2001601",
                    displayName: "Notify User 4",
                    extras: [
                        "now_ms": .int(baseTs),
                        "notif_prefs": .object([
                            "enabled": .bool(true),
                            "sound": .bool(true),
                            "shows_preview": .bool(true),
                            "muted_threads": .array([
                                .object(["id": .string("3001620"), "start_time": .int(1_700_000_000), "duration": .int(-1)]),
                            ]),
                        ]),
                        "contacts": .object([
                            "friends": .array([
                                .object(["id": .string("3001622"), "name": .string("Friend Two"), "avatar": .string("https://cdn.example.invalid/friend2.jpg")]),
                                .object(["id": .string("3001625"), "name": .string("Người dùng Zalo"), "avatar": .string("https://cdn.example.invalid/zuser.jpg")]),
                            ]),
                        ]),
                        "local_conversations": .array([
                            localConv(id: "3001620", name: "Muted Peer"),
                            localConv(id: "3001621", name: "Conv Title 1"),
                            localConv(id: "3001622", name: "3001622"),
                            localConv(id: "3001623", name: "3001623", avatar: "https://cdn.example.invalid/conv3.jpg"),
                            localConv(id: "g1625", isGroup: true, name: "Group Five", avatar: "https://cdn.example.invalid/group_ignored.jpg"),
                        ]),
                    ]
                ),
                server: [
                    NotifyRecorderHarness.loginInfoScript(uid: "2001601", displayName: "Notify User 4"),
                    NotifyRecorderHarness.profileMeScript(uid: "2001601", displayName: "Notify User 4"),
                    // fetchProfiles #1 (3001626 in group g1625) -> ok with avatar + name (cached & persisted to SQLite)
                    NotifyRecorderHarness.httpScript(
                        path: "/api/social/group/members",
                        method: "POST",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "changed_profiles": .object([
                                    "3001626": .object([
                                        "userId": .string("3001626"),
                                        "displayName": .string("Fetched Sender 6"),
                                        "avatar": .string("https://cdn.example.invalid/fetched6.jpg"),
                                    ]),
                                ]),
                                "unchanged_profiles": .object([:]),
                            ]),
                        ])
                    ),
                    // fetchProfiles #2 (3001627) -> HTTP 500 failure
                    NotifyRecorderHarness.httpScript(
                        path: "/api/social/group/members",
                        method: "POST",
                        status: 500,
                        raw: "profile fetch error"
                    ),
                    // fetchProfiles #3 (3001628) -> empty avatar, name present
                    NotifyRecorderHarness.httpScript(
                        path: "/api/social/group/members",
                        method: "POST",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "changed_profiles": .object([
                                    "3001628": .object([
                                        "userId": .string("3001628"),
                                        "displayName": .string("No Avatar Eight"),
                                        "avatar": .string(""),
                                    ]),
                                ]),
                                "unchanged_profiles": .object([:]),
                            ]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("start_bootstrap"), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("load_prefs")]),
                    // Batch 1: muted (skipped), title lvl 1 + msg avatar, title lvl 2 + person avatar, title lvl 3 + conv avatar, title lvl 4 (convId fallback)
                    .object([
                        "cmd": .string("incoming"),
                        "args": .object([
                            "messages": .array([
                                .object(["id": .string("m0"), "conv_id": .string("3001620"), "sender_id": .string("3001620"), "sender_name": .string("Muted Peer"), "text": .string("Ignored"), "ts_ms": .int(baseTs + 1000)]),
                                .object(["id": .string("m1"), "conv_id": .string("3001621"), "sender_id": .string("3001621"), "sender_name": .string("Ignored Sender"), "sender_avatar": .string("https://cdn.example.invalid/msg1.jpg"), "text": .string("Tin nhắn 1"), "ts_ms": .int(baseTs + 2000)]),
                                .object(["id": .string("m2"), "conv_id": .string("3001622"), "sender_id": .string("3001622"), "sender_name": .string("Fallback 2"), "text": .string("Tin nhắn 2"), "ts_ms": .int(baseTs + 3000)]),
                                .object(["id": .string("m3"), "conv_id": .string("3001623"), "sender_id": .string("0"), "sender_name": .string("Sender Three"), "text": .string("Tin nhắn 3"), "ts_ms": .int(baseTs + 4000)]),
                                .object(["id": .string("m4"), "conv_id": .string("3001624"), "sender_id": .string("0"), "sender_name": .string(""), "text": .string("Tin nhắn 4"), "ts_ms": .int(baseTs + 5000)]),
                            ]),
                        ]),
                    ]),
                    // Batch 2: Group with "Người dùng Zalo" skipped; Group with fetchProfiles ok; fetchProfiles failure; fetchProfiles empty avatar
                    .object([
                        "cmd": .string("incoming"),
                        "args": .object([
                            "messages": .array([
                                .object(["id": .string("m5"), "conv_id": .string("g1625"), "sender_id": .string("3001625"), "sender_name": .string("Thật Tên 5"), "text": .string("Group msg 5"), "ts_ms": .int(baseTs + 6000)]),
                                .object(["id": .string("m6"), "conv_id": .string("g1625"), "sender_id": .string("3001626"), "sender_name": .string("Fallback 6"), "text": .string("Group msg 6"), "ts_ms": .int(baseTs + 7000)]),
                                .object(["id": .string("m7"), "conv_id": .string("g1627"), "sender_id": .string("3001627"), "sender_name": .string("Sender Seven"), "text": .string("DM msg 7"), "ts_ms": .int(baseTs + 8000)]),
                                .object(["id": .string("m8"), "conv_id": .string("g1628"), "sender_id": .string("3001628"), "sender_name": .string("Fallback 8"), "text": .string("DM msg 8"), "ts_ms": .int(baseTs + 9000)]),
                            ]),
                        ]),
                    ]),
                    // Preview off & Sound off (silent)
                    .object(["cmd": .string("set_preview"), "args": .object(["on": .bool(false)])]),
                    .object(["cmd": .string("set_sound"), "args": .object(["on": .bool(false)])]),
                    .object([
                        "cmd": .string("incoming"),
                        "args": .object([
                            "messages": .array([
                                .object(["id": .string("m9"), "conv_id": .string("3001621"), "sender_id": .string("3001621"), "sender_name": .string("Lan"), "sender_avatar": .string("https://cdn.example.invalid/msg1.jpg"), "text": .string("Secret text"), "ts_ms": .int(baseTs + 10_000)]),
                            ]),
                        ]),
                    ]),
                    // Notifications disabled -> nothing sent
                    .object(["cmd": .string("set_enabled"), "args": .object(["on": .bool(false)])]),
                    .object([
                        "cmd": .string("incoming"),
                        "args": .object([
                            "messages": .array([
                                .object(["id": .string("m10"), "conv_id": .string("3001621"), "sender_id": .string("3001621"), "sender_name": .string("Lan"), "sender_avatar": .string("https://cdn.example.invalid/msg1.jpg"), "text": .string("Suppressed"), "ts_ms": .int(baseTs + 11_000)]),
                            ]),
                        ]),
                    ]),
                ]
            ),

            // 5. invite: preview as member, preview as non-member, bad response; join ok and failure
            NotifyRecorderHarness.ScenarioDef(
                name: "invite",
                seed: NotifyRecorderHarness.readySessionSeed(
                    userId: "2001601",
                    displayName: "Notify User 5",
                    extras: [
                        "now_ms": .int(baseTs),
                        "next_client_id": .int(660001),
                        "contacts": .object([
                            "groups": .array([
                                .object(["id": .string("g1660"), "name": .string("Existing Group"), "members": .int(5)]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    NotifyRecorderHarness.loginInfoScript(uid: "2001601", displayName: "Notify User 5"),
                    NotifyRecorderHarness.profileMeScript(uid: "2001601", displayName: "Notify User 5"),
                    // Preview 1: member
                    NotifyRecorderHarness.httpScript(
                        path: "/api/group/link/detail",
                        method: "GET",
                        json: .object(["error_code": .int(0), "data": .object(["groupId": .string("1660"), "name": .string("Existing Group")])])
                    ),
                    // Preview 2: non-member
                    NotifyRecorderHarness.httpScript(
                        path: "/api/group/link/detail",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "groupId": .string("1661"),
                                "name": .string("Nhóm Mới"),
                                "avt": .string("https://cdn.example.invalid/g1661.jpg"),
                                "totalMember": .int(12),
                                "desc": .string("Mô tả nhóm"),
                            ]),
                        ])
                    ),
                    // Preview 3: bad response (missing data/groupId)
                    NotifyRecorderHarness.httpScript(
                        path: "/api/group/link/detail",
                        method: "GET",
                        status: 500,
                        raw: "bad link"
                    ),
                    // Join ok -> refreshContacts() sync scripts
                    NotifyRecorderHarness.httpScript(
                        path: "/api/group/link/join",
                        method: "GET",
                        json: .object(["error_code": .int(0), "data": .object(["groupId": .string("1661")])])
                    ),
                ] + emptySyncScripts() + [
                    // Join failure
                    NotifyRecorderHarness.httpScript(
                        path: "/api/group/link/join",
                        method: "GET",
                        status: 500,
                        raw: "join failed"
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("start_bootstrap"), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("invite_preview"), "args": .object(["url": .string("https://zalo.me/g/mem1")])]),
                    .object(["cmd": .string("invite_preview"), "args": .object(["url": .string("https://zalo.me/g/new2")])]),
                    .object(["cmd": .string("invite_preview"), "args": .object(["url": .string("https://zalo.me/g/bad3")])]),
                    .object(["cmd": .string("join_group"), "args": .object(["url": .string("https://zalo.me/g/new2")])]),
                    .object(["cmd": .string("join_group"), "args": .object(["url": .string("https://zalo.me/g/bad3")])]),
                ]
            ),

            // 6. mute: each duration incl. forever, expired mute not active, activeMutes order with equal start times, unmute, API failure still updates local state, 1-1 vs group flag
            NotifyRecorderHarness.ScenarioDef(
                name: "mute",
                seed: NotifyRecorderHarness.readySessionSeed(
                    userId: "2001601",
                    displayName: "Notify User 6",
                    extras: [
                        "now_ms": .int(baseTs),
                    ]
                ),
                server: [
                    NotifyRecorderHarness.loginInfoScript(uid: "2001601", displayName: "Notify User 6"),
                    NotifyRecorderHarness.profileMeScript(uid: "2001601", displayName: "Notify User 6"),
                    // 5 mute calls + 1 unmute call + 1 failing mute call
                    NotifyRecorderHarness.httpScript(path: "/api/social/profile/setmute", method: "POST", json: .object(["error_code": .int(0)])),
                    NotifyRecorderHarness.httpScript(path: "/api/social/profile/setmute", method: "POST", json: .object(["error_code": .int(0)])),
                    NotifyRecorderHarness.httpScript(path: "/api/social/profile/setmute", method: "POST", json: .object(["error_code": .int(0)])),
                    NotifyRecorderHarness.httpScript(path: "/api/social/profile/setmute", method: "POST", json: .object(["error_code": .int(0)])),
                    NotifyRecorderHarness.httpScript(path: "/api/social/profile/setmute", method: "POST", json: .object(["error_code": .int(0)])),
                    NotifyRecorderHarness.httpScript(path: "/api/social/profile/setmute", method: "POST", json: .object(["error_code": .int(0)])),
                    NotifyRecorderHarness.httpScript(path: "/api/social/profile/setmute", method: "POST", status: 500, raw: "mute fail"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("start_bootstrap"), "timeout_ms": .int(5000)]),
                    // Equal startTime (1700000000) across g1611, 3001610, 3001609 -> sorted by id
                    .object(["cmd": .string("mute"), "args": .object(["conv_id": .string("g1611"), "duration": .int(2)])]),
                    .object(["cmd": .string("mute"), "args": .object(["conv_id": .string("3001610"), "duration": .int(1)])]),
                    .object(["cmd": .string("mute"), "args": .object(["conv_id": .string("3001609"), "duration": .int(3)])]),
                    // Later startTime (1700000060) for forever mute
                    .object(["cmd": .string("set_now_ms"), "args": .object(["ms": .int(baseTs + 60_000)])]),
                    .object(["cmd": .string("mute"), "args": .object(["conv_id": .string("g1613"), "duration": .int(4)])]),
                    .object(["cmd": .string("mute"), "args": .object(["conv_id": .string("3001612"), "duration": .int(1)])]),
                    .object(["cmd": .string("is_muted"), "args": .object(["conv_id": .string("3001610")])]),
                    .object(["snapshot": .string("all_active")]),
                    // Advance to exact 1h expiry of 3001610 (1700003600) -> 3001610 inactive, 3001612 still active for 60s
                    .object(["cmd": .string("set_now_ms"), "args": .object(["ms": .int(baseTs + 3_600_000)])]),
                    .object(["cmd": .string("is_muted"), "args": .object(["conv_id": .string("3001610")])]),
                    .object(["cmd": .string("is_muted"), "args": .object(["conv_id": .string("g1613")])]),
                    .object(["snapshot": .string("after_1h_expiry")]),
                    // Unmute group g1611
                    .object(["cmd": .string("unmute"), "args": .object(["conv_id": .string("g1611")])]),
                    // Mute API failure -> local state & SQLite mutedThreads still updated
                    .object(["cmd": .string("mute"), "args": .object(["conv_id": .string("3001614"), "duration": .int(4)])]),
                ]
            ),

            // 7. policy: pure NotificationPolicy edges + MuteInfo UTC text helpers
            NotifyRecorderHarness.ScenarioDef(
                name: "policy",
                seed: NotifyRecorderHarness.readySessionSeed(
                    userId: "2001601",
                    displayName: "Policy User",
                    extras: [
                        "now_ms": .int(baseTs),
                    ]
                ),
                server: [],
                steps: [
                    .object(["cmd": .string("policy")]),
                ]
            ),

            // 8. reminders: pin-ref + fallback id, normalize (each repeat), watch change before timeout + timeout (virtual 15s), respond accept/reject ok & fail, responders ("Bạn" + unknown + profile fetch quirk), resetCardState wakes waiters
            NotifyRecorderHarness.ScenarioDef(
                name: "reminders",
                seed: NotifyRecorderHarness.readySessionSeed(
                    userId: "2001601",
                    displayName: "Me User",
                    extras: [
                        "now_ms": .int(baseTs),
                        "contacts": .object([
                            "friends": .array([
                                .object(["id": .string("3001675"), "name": .string("Friend Five"), "avatar": .string("https://cdn.example.invalid/f5.jpg")]),
                            ]),
                        ]),
                        "local_conversations": .array([
                            localConv(id: "g1670", isGroup: true, name: "Reminder Group", members: 5),
                            localConv(id: "3001671", name: "Reminder DM"),
                        ]),
                        "local_messages": .array([
                            .object([
                                "id": .string("9001670"),
                                "conv_id": .string("g1670"),
                                "sender_id": .string("3001675"),
                                "sender_name": .string("Friend Five"),
                                "is_mine": .bool(false),
                                "text": .string("Nhắc hẹn"),
                                "kind_tag": .string("ecard"),
                                "kind": .object([
                                    "type": .string("ecard"),
                                    "style": .string("reminder"),
                                    "title": .string("Card Fallback Title"),
                                    "reminderTitle": .string("Họp tuần"),
                                    "reminderStart": .int(baseTs + 7_200_000),
                                    "reminderRepeat": .string("Không lặp"),
                                ]),
                                "ts_ms": .int(baseTs - 2000),
                            ]),
                        ]),
                        "history_freshness": .object([
                            "g1670": .string("up_to_date"),
                            "3001671": .string("up_to_date"),
                        ]),
                        "pins": .object([
                            "g1670": .object([
                                "convId": .string("g1670"),
                                "ready": .bool(true),
                                "canPin": .bool(true),
                                "limit": .int(5),
                                "items": .array([
                                    .object([
                                        "ref": .string("rem_pinned_1"),
                                        "kind": .int(3),
                                        "title": .string("Họp tuần"),
                                        "sender": .string("Friend Five"),
                                        "thumb": .string(""),
                                        "msgId": .string("9001670"),
                                        "cliMsgId": .string("9001670"),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    NotifyRecorderHarness.loginInfoScript(uid: "2001601", displayName: "Me User"),
                    NotifyRecorderHarness.profileMeScript(uid: "2001601", displayName: "Me User"),
                    // 1. Initial watch g1670/9001670 (pin ref rem_pinned_1), repeat 1 ("Hàng ngày")
                    NotifyRecorderHarness.httpScript(
                        path: "/api/board/topic/getReminder",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "rid": .string("rem_pinned_1"),
                                "title": .string("Họp mỗi ngày"),
                                "startTime": .int(1_700_007_200),
                                "repeat": .int(1),
                                "creatorId": .string("3001675"),
                                "acceptUids": .array([.string("3001675")]),
                                "rejectUids": .array([]),
                            ]),
                        ])
                    ),
                    // 2. Fallback id 9001671 in DM 3001671, repeat 2 ("Hàng tuần"), onlyMe: true
                    NotifyRecorderHarness.httpScript(
                        path: "/api/board/topic/getReminder",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "title": .string("Nhắc riêng"),
                                "startTime": .int(1_700_010_800),
                                "repeatMode": .int(2),
                                "onlyMe": .bool(true),
                            ]),
                        ])
                    ),
                    // 3. Fallback id 9001672 in g1670, repeat 3 ("Hàng tháng"), params JSON string, delStatus: 1 -> deleted
                    NotifyRecorderHarness.httpScript(
                        path: "/api/board/topic/getReminder",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "params": .string(#"{"title":"Họp tháng","startTime":1700014400000,"repeat":3}"#),
                                "delStatus": .int(1),
                            ]),
                        ])
                    ),
                    // 4. respond_reminder accept ok + follow-up getReminder (wakes async watch #1)
                    NotifyRecorderHarness.httpScript(
                        path: "/api/board/topic/updateEventResponse",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                    NotifyRecorderHarness.httpScript(
                        path: "/api/board/topic/getReminder",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "rid": .string("rem_pinned_1"),
                                "title": .string("Họp mỗi ngày"),
                                "startTime": .int(1_700_007_200),
                                "repeat": .int(1),
                                "creatorId": .string("3001675"),
                                "acceptUids": .array([.string("3001675"), .string("2001601")]),
                                "rejectUids": .array([]),
                                "myRes": .int(1),
                            ]),
                        ])
                    ),
                    // 5. Async watch #1 wakes and fetches latest detail
                    NotifyRecorderHarness.httpScript(
                        path: "/api/board/topic/getReminder",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "rid": .string("rem_pinned_1"),
                                "title": .string("Họp mỗi ngày"),
                                "startTime": .int(1_700_007_200),
                                "repeat": .int(1),
                                "creatorId": .string("3001675"),
                                "acceptUids": .array([.string("3001675"), .string("2001601")]),
                                "rejectUids": .array([]),
                                "myRes": .int(1),
                            ]),
                        ])
                    ),
                    // 6. Async watch #2 hits 15s timeout -> fetches detail with repeat 0 (empty repeatLabel)
                    NotifyRecorderHarness.httpScript(
                        path: "/api/board/topic/getReminder",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "rid": .string("rem_pinned_1"),
                                "title": .string("Họp mỗi ngày"),
                                "startTime": .int(1_700_007_200),
                                "repeat": .int(0),
                                "creatorId": .string("3001675"),
                                "acceptUids": .array([.string("3001675"), .string("2001601")]),
                                "rejectUids": .array([]),
                                "myRes": .int(1),
                            ]),
                        ])
                    ),
                    // 7. respond_reminder reject ok + follow-up getReminder
                    NotifyRecorderHarness.httpScript(
                        path: "/api/board/topic/updateEventResponse",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                    NotifyRecorderHarness.httpScript(
                        path: "/api/board/topic/getReminder",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "rid": .string("rem_pinned_1"),
                                "title": .string("Họp mỗi ngày"),
                                "startTime": .int(1_700_007_200),
                                "repeat": .int(0),
                                "creatorId": .string("3001675"),
                                "acceptUids": .array([.string("3001675")]),
                                "rejectUids": .array([.string("2001601")]),
                                "myRes": .int(2),
                            ]),
                        ])
                    ),
                    // 8. respond_reminder accept failure (HTTP 500)
                    NotifyRecorderHarness.httpScript(
                        path: "/api/board/topic/updateEventResponse",
                        method: "POST",
                        status: 500,
                        raw: "rsvp fail"
                    ),
                    // 9. Async watch #3 woken by reset_card_state -> fetches detail
                    NotifyRecorderHarness.httpScript(
                        path: "/api/board/topic/getReminder",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "rid": .string("rem_pinned_1"),
                                "title": .string("Họp mỗi ngày"),
                                "startTime": .int(1_700_007_200),
                                "repeat": .int(0),
                                "creatorId": .string("3001675"),
                                "acceptUids": .array([.string("3001675")]),
                                "rejectUids": .array([.string("2001601")]),
                                "myRes": .int(2),
                            ]),
                        ])
                    ),
                    // 10. reminder_responders -> listResponseEvent + fetchProfiles (3001678 ok, 3001679 missing -> "Người dùng Zalo", self 2001601 -> "Bạn")
                    NotifyRecorderHarness.httpScript(
                        path: "/api/board/topic/listResponseEvent",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "accept": .array([
                                    .string("2001601"),
                                    .string("3001675"),
                                ]),
                                "reject": .array([
                                    .string("3001678"),
                                    .string("3001679"),
                                ]),
                                "acceptTotal": .int(2),
                                "rejectTotal": .int(3),
                                "rejectMore": .int(1),
                            ]),
                        ])
                    ),
                    NotifyRecorderHarness.httpScript(
                        path: "/api/social/group/members",
                        method: "POST",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "changed_profiles": .object([
                                    "3001678": .object([
                                        "userId": .string("3001678"),
                                        "displayName": .string("Fetched Rejecter"),
                                        "avatar": .string("https://cdn.example.invalid/r78.jpg"),
                                    ]),
                                ]),
                                "unchanged_profiles": .object([:]),
                            ]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("start_bootstrap"), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("g1670")])]),
                    // 1. Initial fetch via pin ref (rem_pinned_1), repeat 1 ("Hàng ngày")
                    .object(["cmd": .string("reminder_watch"), "args": .object(["conv_id": .string("g1670"), "msg_id": .string("9001670"), "signature": .string("")])]),
                    // 2. Fallback id 9001671 in DM 3001671, repeat 2 ("Hàng tuần")
                    .object(["cmd": .string("reminder_watch"), "args": .object(["conv_id": .string("3001671"), "msg_id": .string("9001671"), "signature": .string("")])]),
                    // 3. Fallback id 9001672 in g1670, repeat 3 ("Hàng tháng") + deleted
                    .object(["cmd": .string("reminder_watch"), "args": .object(["conv_id": .string("g1670"), "msg_id": .string("9001672"), "signature": .string("")])]),
                    // 4. Watch with matching sig -> suspends; respond_reminder accept wakes it before timeout!
                    .object(["cmd": .string("reminder_watch"), "args": .object(["conv_id": .string("g1670"), "msg_id": .string("9001670"), "signature": .string("rem_pinned_1|Họp mỗi ngày|1700007200000|Hàng ngày||1|0|false|invite"), "async": .bool(true)])]),
                    .object(["cmd": .string("respond_reminder"), "args": .object(["conv_id": .string("g1670"), "msg_id": .string("9001670"), "accept": .bool(true)])]),
                    .object(["cmd": .string("await_reminder_watch")]),
                    // 5. Watch with matching sig -> suspends until virtual 15s timeout!
                    .object(["cmd": .string("reminder_watch"), "args": .object(["conv_id": .string("g1670"), "msg_id": .string("9001670"), "signature": .string("rem_pinned_1|Họp mỗi ngày|1700007200000|Hàng ngày|accept|2|0|false|invite"), "async": .bool(true)])]),
                    .object(["cmd": .string("advance_reminder_ms"), "args": .object(["ms": .int(15_000)])]),
                    .object(["cmd": .string("await_reminder_watch")]),
                    // 6. Respond reject ok & accept fail
                    .object(["cmd": .string("respond_reminder"), "args": .object(["conv_id": .string("g1670"), "msg_id": .string("9001670"), "accept": .bool(false)])]),
                    .object(["cmd": .string("respond_reminder"), "args": .object(["conv_id": .string("g1670"), "msg_id": .string("9001671"), "accept": .bool(true)])]),
                    // 7. Watch with matching sig -> woken by reset_card_state!
                    .object(["cmd": .string("reminder_watch"), "args": .object(["conv_id": .string("g1670"), "msg_id": .string("9001670"), "signature": .string("rem_pinned_1|Họp mỗi ngày|1700007200000|Không lặp|reject|1|1|false|invite"), "async": .bool(true)])]),
                    .object(["cmd": .string("reset_card_state")]),
                    .object(["cmd": .string("await_reminder_watch")]),
                    // 8. Responders ("Bạn", friend, fetched stranger, unknown "Người dùng Zalo")
                    .object(["cmd": .string("reminder_responders"), "args": .object(["conv_id": .string("g1670"), "msg_id": .string("9001670")])]),
                ]
            ),

            // 9. settings: defaults with no store rows, turn off then on (sound follows; authorization denied & notDetermined & default authorized), sound alone, preview off, settings_payload with & without mutes
            NotifyRecorderHarness.ScenarioDef(
                name: "settings",
                seed: NotifyRecorderHarness.readySessionSeed(
                    userId: "2001601",
                    displayName: "Notify User 9",
                    extras: [
                        "now_ms": .int(baseTs),
                        "host_results": .object([
                            "request_notif_auth": .array([
                                .string("denied"),
                                .string("notDetermined"),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    NotifyRecorderHarness.loginInfoScript(uid: "2001601", displayName: "Notify User 9"),
                    NotifyRecorderHarness.profileMeScript(uid: "2001601", displayName: "Notify User 9"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("start_bootstrap"), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("initial_before_load")]),
                    .object(["cmd": .string("load_prefs")]),
                    .object(["snapshot": .string("after_load_defaults")]),
                    .object(["cmd": .string("set_enabled"), "args": .object(["on": .bool(false)])]),
                    .object(["snapshot": .string("after_disable")]),
                    .object(["cmd": .string("set_enabled"), "args": .object(["on": .bool(true)])]),
                    .object(["snapshot": .string("after_enable_denied")]),
                    .object(["cmd": .string("set_enabled"), "args": .object(["on": .bool(false)])]),
                    .object(["cmd": .string("set_enabled"), "args": .object(["on": .bool(true)])]),
                    .object(["snapshot": .string("after_enable_not_determined")]),
                    .object(["cmd": .string("set_enabled"), "args": .object(["on": .bool(false)])]),
                    .object(["cmd": .string("set_enabled"), "args": .object(["on": .bool(true)])]),
                    .object(["snapshot": .string("after_enable_authorized")]),
                    .object(["cmd": .string("set_sound"), "args": .object(["on": .bool(false)])]),
                    .object(["snapshot": .string("after_sound_off")]),
                    .object(["cmd": .string("set_preview"), "args": .object(["on": .bool(false)])]),
                    .object(["snapshot": .string("after_preview_off")]),
                    .object([
                        "cmd": .string("settings_payload"),
                        "args": .object([
                            "json": .object([
                                "kind": .string("settings"),
                                "enabled": .bool(false),
                                "sound": .bool(true),
                                "hasSoundSetting": .bool(false),
                                "mutes": .array([
                                    .object(["id": .string("3001601"), "startTime": .int(1_700_000_000), "duration": .int(3600)]),
                                    .object(["id": .string(""), "startTime": .int(1_700_000_000), "duration": .int(60)]),
                                    .object(["id": .string("g1602")]),
                                ]),
                            ]),
                        ]),
                    ]),
                    .object(["snapshot": .string("after_payload_with_mutes")]),
                    .object([
                        "cmd": .string("settings_payload"),
                        "args": .object([
                            "json": .object([
                                "kind": .string("settings"),
                                "enabled": .bool(true),
                                "mutes": .array([]),
                            ]),
                        ]),
                    ]),
                ]
            ),

            // 10. suggested: birthday e-card vs other message, id fallbacks, > 8 rows capped at 8, API failure gives []
            NotifyRecorderHarness.ScenarioDef(
                name: "suggested",
                seed: NotifyRecorderHarness.readySessionSeed(
                    userId: "2001601",
                    displayName: "Notify User 10",
                    extras: [
                        "now_ms": .int(baseTs),
                        "contacts": .object([
                            "cached_profiles": .object([
                                "3001690": .object(["name": .string("Sticker Suggest Peer"), "avatar": .string("https://cdn.example.invalid/p90.jpg")]),
                            ]),
                        ]),
                        "local_conversations": .array([
                            localConv(id: "3001690", name: "Sticker Suggest Peer"),
                        ]),
                        "local_messages": .array([
                            .object([
                                "id": .string("9001690"),
                                "conv_id": .string("3001690"),
                                "sender_id": .string("3001690"),
                                "sender_name": .string("Sticker Suggest Peer"),
                                "is_mine": .bool(false),
                                "text": .string("[Thiệp]"),
                                "kind_tag": .string("ecard"),
                                "kind": .object(["type": .string("ecard"), "style": .string("birthday"), "title": .string("Chúc mừng sinh nhật")]),
                                "ts_ms": .int(baseTs - 3000),
                            ]),
                            .object([
                                "id": .string("9001691"),
                                "conv_id": .string("3001690"),
                                "sender_id": .string("3001690"),
                                "sender_name": .string("Sticker Suggest Peer"),
                                "is_mine": .bool(false),
                                "text": .string("Chào bạn"),
                                "kind_tag": .string("text"),
                                "kind": .object(["type": .string("text")]),
                                "ts_ms": .int(baseTs - 2000),
                            ]),
                        ]),
                        "history_freshness": .object([
                            "3001690": .string("up_to_date"),
                        ]),
                    ]
                ),
                server: [
                    NotifyRecorderHarness.loginInfoScript(uid: "2001601", displayName: "Notify User 10"),
                    NotifyRecorderHarness.profileMeScript(uid: "2001601", displayName: "Notify User 10"),
                    // 1. Birthday e-card -> "chúc mừng sinh nhật", > 8 rows, id/cateId fallbacks + bad sid skipped
                    NotifyRecorderHarness.httpScript(
                        path: "/api/message/sticker/suggest/stickers",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "sugg_sticker": .array([
                                    .object(["id": .int(101), "cateId": .int(10)]),
                                    .object(["stickerId": .int(102), "cate_id": .int(11)]),
                                    .object(["sticker_id": .int(103), "cateId": .int(12)]),
                                    .object(["id": .int(0), "cateId": .int(12)]),
                                    .object(["id": .int(104)]),
                                    .object(["id": .int(105), "cateId": .int(13)]),
                                    .object(["id": .int(106), "cateId": .int(14)]),
                                    .object(["id": .int(107), "cateId": .int(15)]),
                                    .object(["id": .int(108), "cateId": .int(16)]),
                                    .object(["id": .int(109), "cateId": .int(17)]),
                                ]),
                            ]),
                        ])
                    ),
                    // 2. Non-birthday message -> "xin chào", data.stickers fallback
                    NotifyRecorderHarness.httpScript(
                        path: "/api/message/sticker/suggest/stickers",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "stickers": .array([
                                    .object(["stickerId": .int(201), "cateId": .int(20)]),
                                    .object(["sticker_id": .int(202), "cate_id": .int(21)]),
                                ]),
                            ]),
                        ])
                    ),
                    // 3. API failure -> []
                    NotifyRecorderHarness.httpScript(
                        path: "/api/message/sticker/suggest/stickers",
                        method: "GET",
                        status: 500,
                        raw: "suggest failed"
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("start_bootstrap"), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3001690")])]),
                    .object(["cmd": .string("suggested_stickers"), "args": .object(["conv_id": .string("3001690"), "msg_id": .string("9001690")])]),
                    .object(["cmd": .string("suggested_stickers"), "args": .object(["conv_id": .string("3001690"), "msg_id": .string("9001691")])]),
                    .object(["cmd": .string("suggested_stickers"), "args": .object(["conv_id": .string("3001690"), "msg_id": .string("9001691")])]),
                ]
            ),
        ]
    }
}

// MARK: - Shared U16 Recorder Harness (notifications & card actions)

enum NotifyRecorderHarness {
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

    static func readySessionSeed(
        userId: String,
        displayName: String = "Notify User",
        phone: String = "+84900000160",
        send2MeId: String? = nil,
        suppress: [String] = ["ws", "long_poll"],
        extras: [String: CaseJSON] = [:]
    ) -> CaseJSON {
        var mergedExtras: [String: CaseJSON] = [
            "next_client_id": .int(5_000_016_000_100),
        ]
        for (k, v) in extras {
            mergedExtras[k] = v
        }
        return MessageRecorderHarness.readySessionSeed(
            userId: userId,
            displayName: displayName,
            phone: phone,
            send2MeId: send2MeId,
            suppress: suppress,
            extras: mergedExtras
        )
    }

    static func loginInfoScript(
        uid: String,
        zpwSek: String = "saved.200.a0.sek_u16",
        displayName: String = "Notify User",
        send2MeId: String? = nil
    ) -> CaseJSON {
        MessageRecorderHarness.loginInfoScript(
            uid: uid,
            zpwSek: zpwSek,
            displayName: displayName,
            send2MeId: send2MeId
        )
    }

    static func profileMeScript(
        uid: String,
        displayName: String = "Notify User",
        avatar: String = "https://cdn.example.invalid/me.jpg",
        phone: String = "+84900000160"
    ) -> CaseJSON {
        MessageRecorderHarness.profileMeScript(
            uid: uid,
            displayName: displayName,
            avatar: avatar,
            phone: phone
        )
    }

    static func httpScript(
        path: String,
        method: String,
        status: Int64 = 200,
        json: CaseJSON? = nil,
        raw: String? = nil,
        hold: Bool = false,
        repeatResponse: Bool = false
    ) -> CaseJSON {
        var respObj: [String: CaseJSON] = [
            "status": .int(status),
        ]
        if let json { respObj["json"] = json }
        if let raw { respObj["raw"] = .string(raw) }
        var obj: [String: CaseJSON] = [
            "kind": .string("http"),
            "path": .string(path),
            "method": .string(method),
            "response": .object(respObj),
        ]
        if hold { obj["hold"] = .bool(true) }
        if repeatResponse { obj["repeat"] = .bool(true) }
        return .object(obj)
    }

    @MainActor
    static func runDomainSuite(domain: String, scenarios: [ScenarioDef]) async throws {
        let shouldRecord = ProcessInfo.processInfo.environment["OLAZ_RECORD"] == "1"
        let runSlow = shouldRecord || ProcessInfo.processInfo.environment["OLAZ_SLOW_CASES"] == "1"
        let url = CaseFile.casesURL(domain: domain)

        let sortedScenarios = scenarios.sorted {
            $0.name.utf8.lexicographicallyPrecedes($1.name.utf8)
        }

        if shouldRecord {
            var recorded: [CaseJSON] = []
            recorded.reserveCapacity(sortedScenarios.count)
            for scenario in sortedScenarios {
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
        XCTAssertEqual(byName.count, sortedScenarios.count, "\(domain).jsonl case count mismatch (run with OLAZ_RECORD=1 to regenerate)")

        let knownDiffs = try CaseFile.loadKnownDiffs()
        var usedKnownDiffs = Array(repeating: false, count: knownDiffs.count)
        var executedNames = Set<String>()

        for scenario in sortedScenarios {
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
            for d in diffs {
                XCTFail("\(scenario.name): \(d)")
            }
        }

        let allCaseNames = Set(byName.keys)
        let stale = CaseFile.staleKnownDiffs(
            domain: domain,
            executedNames: executedNames,
            allCaseNames: allCaseNames,
            knownDiffs: knownDiffs,
            usedKnownDiffs: usedKnownDiffs
        )
        for s in stale {
            XCTFail(s)
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
            .appendingPathComponent("olaz-notify-recorder-\(scenario.name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let storage = RecorderStorageIsolation(prefix: "olaz.notify-recorder")
        EngineLog.shared.onAppend = nil
        CardActionCenter.shared.reset()

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

        if let showsPreview = scenario.seed["notif_prefs"]?["shows_preview"]?.boolValue,
           let defaults = UserDefaults(suiteName: storage.userDefaultsSuiteName) {
            defaults.set(showsPreview, forKey: NotificationSettingsState.previewDefaultsKey)
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

        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(secondsFromGMT: 0)!
        engine.notificationCalendar = utcCal

        let reminderClock = VirtualReminderClock()
        engine.reminderWatchSleep = { seconds in
            await reminderClock.sleep(seconds: seconds)
        }

        var baselineNowMs = scenario.seed["now_ms"]?.int64Value
        if let initialNowMs = baselineNowMs {
            engine.nowMs = { initialNowMs }
        }

        var banners: [NotifyBannerRecord] = []
        engine.notifyBannerHook = { record in
            var norm = record
            if let av = norm.avatarURL {
                norm.avatarURL = av.replacingOccurrences(of: baseURL, with: "http://fake")
            }
            banners.append(norm)
        }

        let notifAuthQueue = scenario.seed["host_results"]?["request_notif_auth"]?.arrayValue ?? []
        var notifAuthIndex = 0
        engine.requestNotifAuthHostHandler = {
            let raw: String
            if notifAuthIndex < notifAuthQueue.count {
                raw = notifAuthQueue[notifAuthIndex].stringValue ?? "authorized"
                notifAuthIndex += 1
            } else {
                raw = "authorized"
            }
            return NotificationSettingsState.Authorization(rawValue: raw) ?? .authorized
        }

        defer {
            EngineLog.shared.onAppend = nil
            reminderClock.cancelAll()
            CardActionCenter.shared.reset()
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
        if let pinsObj = scenario.seed["pins"]?.objectValue {
            for (convId, listVal) in pinsObj {
                if let listDict = toFoundationDict(listVal) {
                    engine.pins[convId] = PinnedList(json: listDict)
                }
            }
        }

        var bootstrapLogs: [String] = []
        var sendLogs: [String] = []
        var actionLogs: [String] = []
        let lastSendResult: Bool? = nil
        var results: [String: CaseJSON] = [:]

        func installLogHooks(forwardingTo prev: ((String) -> Void)?) {
            EngineLog.shared.onAppend = { rawLine in
                prev?(rawLine)
                if let sp = rawLine.firstIndex(of: " ") {
                    let msg = String(rawLine[rawLine.index(after: sp)...])
                    if msg.hasPrefix("bootstrap: ") { bootstrapLogs.append(msg) }
                    if msg.hasPrefix("sendText ") { sendLogs.append(msg) }
                    if msg.hasPrefix("recall failed:") || msg.hasPrefix("react failed:") {
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
        engine.traceNotifyHostEnabled = true
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

        let transitionRecorder = NotifyTransitionRecorder(scenarioName: scenario.name) {
            normalizeRecordedURLs(SessionSnapshot.capture(from: engine))
        }
        engine.transportSettleTrace = {
            settleCount += 1
            transitionRecorder.recordTransition()
            notifySignal()
        }

        func waitForCondition(timeoutMs: Int, description: String, _ pred: @escaping @MainActor () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
            while !pred() {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 {
                    throw RecorderError.timeout(scenario: scenario.name, detail: "Timed out waiting for \(description)")
                }
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    let id = UUID()
                    signalWaiters[id] = cont
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(min(25, max(1, Int(remaining * 1000)))))
                        if let c = signalWaiters.removeValue(forKey: id) {
                            c.resume()
                        }
                    }
                }
            }
        }

        func decodeIncomingMessage(_ json: CaseJSON) -> ChatMessage? {
            guard var dict = toFoundationDict(substituteRuntimeURLs(json)) else { return nil }
            let convId = dict["conv_id"] as? String ?? ""
            if dict["conversationId"] == nil { dict["conversationId"] = convId }
            if dict["senderId"] == nil, let sid = dict["sender_id"] { dict["senderId"] = sid }
            if dict["senderName"] == nil, let sname = dict["sender_name"] { dict["senderName"] = sname }
            if dict["senderAvatar"] == nil, let savt = dict["sender_avatar"] { dict["senderAvatar"] = savt }
            if dict["isMine"] == nil, let mine = dict["is_mine"] { dict["isMine"] = mine }
            if dict["isE2EE"] == nil, let e2ee = dict["is_e2ee"] { dict["isE2EE"] = e2ee }
            if dict["date"] == nil, let dms = dict["ts_ms"] ?? dict["date_ms"] { dict["date"] = dms }
            if let kindStr = dict["kind"] as? String {
                dict["kind"] = ["type": kindStr]
            } else if dict["kind"] == nil {
                dict["kind"] = ["type": "text"]
            }
            return ChatMessage(json: dict, fallbackConversation: convId)
        }

        var snapshots: [String: CaseJSON] = [:]
        var activeWatchTask: Task<CaseJSON, Never>?
        var activeWatchStepIndex: Int?
        var activeWatchSettled = true

        do {
            for (stepIndex, step) in scenario.steps.enumerated() {
                if let cmd = step["cmd"]?.stringValue {
                    let args = step["args"]
                    let savedNowMs = engine.nowMs
                    if let ms = step["now_ms"]?.int64Value {
                        engine.nowMs = { ms }
                    }
                    var keepBaselineNowMs = false
                    defer {
                        if !keepBaselineNowMs {
                            engine.nowMs = savedNowMs
                        }
                    }

                    switch cmd {
                    case "start":
                        engine.start()
                        let engineAppend = EngineLog.shared.onAppend
                        installLogHooks(forwardingTo: engineAppend)
                        transitionRecorder.recordTransition()
                    case "open":
                        guard let convId = args?["id"]?.stringValue, !convId.isEmpty else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "open requires args.id")
                        }
                        engine.openConversation(convId)
                        _ = await engine.openConversationTask?.value
                        await engine.settleForRecording()
                    case "close":
                        engine.closeConversation()
                        await engine.settleForRecording()
                    case "set_now_ms":
                        guard let ms = args?["ms"]?.int64Value else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "set_now_ms requires args.ms")
                        }
                        baselineNowMs = ms
                        engine.nowMs = { ms }
                        keepBaselineNowMs = true
                    case "set_enabled":
                        guard let on = args?["on"]?.boolValue else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "set_enabled requires args.on")
                        }
                        engine.setNotificationsEnabled(on)
                        await engine.awaitNotificationTasksForRecording()
                    case "set_sound":
                        guard let on = args?["on"]?.boolValue else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "set_sound requires args.on")
                        }
                        engine.setNotificationSound(on)
                        await engine.awaitNotificationTasksForRecording()
                    case "set_preview":
                        guard let on = args?["on"]?.boolValue else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "set_preview requires args.on")
                        }
                        engine.setMessagePreview(on)
                    case "mute":
                        guard let convId = args?["conv_id"]?.stringValue,
                              let rawDur = args?["duration"]?.int64Value,
                              let dur = MuteDuration(rawValue: Int(rawDur)) else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "mute requires conv_id and duration (1..4)")
                        }
                        engine.muteConversation(convId, dur)
                        await engine.awaitNotificationTasksForRecording()
                    case "unmute":
                        guard let convId = args?["conv_id"]?.stringValue else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "unmute requires conv_id")
                        }
                        engine.unmuteConversation(convId)
                        await engine.awaitNotificationTasksForRecording()
                    case "is_muted":
                        guard let convId = args?["conv_id"]?.stringValue else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "is_muted requires conv_id")
                        }
                        results["\(stepIndex)"] = .bool(engine.isConversationMuted(convId))
                    case "settings_payload":
                        guard let jsonObj = args?["json"], let dict = toFoundationDict(jsonObj) else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "settings_payload requires args.json")
                        }
                        engine.handleNotification(state: ["notification": dict])
                    case "load_prefs":
                        if let store = engine.sqliteStore {
                            await engine.loadNotificationPreferences(from: store)
                        }
                    case "incoming":
                        let rawMsgs = args?["messages"]?.arrayValue ?? []
                        let msgs = rawMsgs.compactMap(decodeIncomingMessage)
                        await engine.notifyIncomingBatchMessages(msgs)
                        await engine.awaitNotificationTasksForRecording()
                    case "card_action":
                        guard let convId = args?["conv_id"]?.stringValue,
                              let msgId = args?["msg_id"]?.stringValue,
                              let ref = args?["ref"]?.stringValue else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "card_action requires conv_id, msg_id, ref")
                        }
                        let outcome = await engine.performCardAction(in: convId, message: msgId, ref: ref)
                        await engine.settleForRecording()
                        results["\(stepIndex)"] = normalizeRecordedURLs(StickerSnapshot.encodeCardActionOutcome(outcome))
                    case "suggested_stickers":
                        guard let convId = args?["conv_id"]?.stringValue,
                              let msgId = args?["msg_id"]?.stringValue else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "suggested_stickers requires conv_id, msg_id")
                        }
                        let list = await engine.suggestedStickers(in: convId, message: msgId)
                        results["\(stepIndex)"] = normalizeRecordedURLs(NotifySnapshot.encodeSuggestedStickers(list))
                    case "contact_card":
                        guard let uid = args?["uid"]?.stringValue else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "contact_card requires args.uid")
                        }
                        let state = await engine.contactCardState(uid)
                        results["\(stepIndex)"] = .object([
                            "is_self": .bool(state.isSelf),
                            "is_friend": .bool(state.isFriend),
                        ])
                    case "contact_profile":
                        guard let uid = args?["uid"]?.stringValue else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "contact_profile requires args.uid")
                        }
                        let prof = await engine.contactProfile(uid)
                        results["\(stepIndex)"] = normalizeRecordedURLs(NotifySnapshot.encodeContactProfile(prof))
                    case "prep_friend":
                        guard let uid = args?["uid"]?.stringValue else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "prep_friend requires args.uid")
                        }
                        let convId = args?["conv_id"]?.stringValue ?? ""
                        let viaRaw = args?["via"]?.stringValue ?? "add"
                        let via = FriendRequestOrigin(rawValue: viaRaw) ?? .add
                        let prep = await engine.prepareFriendRequest(to: uid, from: convId, via: via)
                        results["\(stepIndex)"] = NotifySnapshot.encodeFriendRequestPrep(prep)
                    case "submit_friend":
                        guard let uid = args?["uid"]?.stringValue,
                              let msg = args?["message"]?.stringValue else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "submit_friend requires uid, message")
                        }
                        let res = await engine.submitFriendRequest(to: uid, message: msg)
                        await engine.awaitContactsTasksForRecording()
                        results["\(stepIndex)"] = .object([
                            "ok": .bool(res.ok),
                            "text": .string(res.text),
                            "pending": .bool(res.pending),
                        ])
                    case "save_alias":
                        guard let uid = args?["uid"]?.stringValue,
                              let name = args?["name"]?.stringValue else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "save_alias requires uid, name")
                        }
                        let res = await engine.saveAlias(uid: uid, name: name)
                        results["\(stepIndex)"] = .object([
                            "ok": .bool(res.ok),
                            "text": .string(res.text),
                        ])
                    case "invite_preview":
                        guard let urlStr = args?["url"]?.stringValue,
                              let url = URL(string: urlStr) else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "invite_preview requires args.url")
                        }
                        let preview = await engine.groupInvitePreview(url)
                        results["\(stepIndex)"] = normalizeRecordedURLs(NotifySnapshot.encodeGroupInvitePreview(preview))
                    case "join_group":
                        guard let urlStr = args?["url"]?.stringValue,
                              let url = URL(string: urlStr) else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "join_group requires args.url")
                        }
                        let res = await engine.joinGroup(url)
                        await engine.awaitContactsTasksForRecording()
                        results["\(stepIndex)"] = normalizeRecordedURLs(NotifySnapshot.encodeGroupJoinResult(res))
                    case "reminder_watch":
                        guard let convId = args?["conv_id"]?.stringValue,
                              let msgId = args?["msg_id"]?.stringValue,
                              let signature = args?["signature"]?.stringValue else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "reminder_watch requires conv_id, msg_id, signature")
                        }
                        let isAsync = args?["async"]?.boolValue ?? false
                        if isAsync {
                            guard activeWatchTask == nil else {
                                throw RecorderError.invalidStep(scenario: scenario.name, detail: "concurrent async reminder_watch not supported")
                            }
                            let prevRegistered = reminderClock.registeredCount
                            activeWatchStepIndex = stepIndex
                            activeWatchSettled = false
                            activeWatchTask = Task { @MainActor in
                                defer {
                                    activeWatchSettled = true
                                    notifySignal()
                                }
                                let snap = await engine.reminderWatch(in: convId, message: msgId, signature: signature)
                                return normalizeRecordedURLs(NotifySnapshot.encodeReminderSnapshot(snap))
                            }
                            try await waitForCondition(timeoutMs: 2000, description: "reminder_watch waiter registration") {
                                reminderClock.registeredCount > prevRegistered || activeWatchSettled
                            }
                        } else {
                            let snap = await engine.reminderWatch(in: convId, message: msgId, signature: signature)
                            results["\(stepIndex)"] = normalizeRecordedURLs(NotifySnapshot.encodeReminderSnapshot(snap))
                        }
                    case "advance_reminder_ms":
                        guard let ms = args?["ms"]?.int64Value else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "advance_reminder_ms requires args.ms")
                        }
                        reminderClock.advance(byMs: ms)
                        await Task.yield()
                        await Task.yield()
                    case "await_reminder_watch":
                        guard let task = activeWatchTask, let watchStep = activeWatchStepIndex else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "await_reminder_watch has no active watch task")
                        }
                        let snapJSON = await task.value
                        results["\(watchStep)"] = snapJSON
                        activeWatchTask = nil
                        activeWatchStepIndex = nil
                    case "respond_reminder":
                        guard let convId = args?["conv_id"]?.stringValue,
                              let msgId = args?["msg_id"]?.stringValue,
                              let accept = args?["accept"]?.boolValue else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "respond_reminder requires conv_id, msg_id, accept")
                        }
                        let res = await engine.respondToReminder(in: convId, message: msgId, accept: accept)
                        results["\(stepIndex)"] = .object([
                            "ok": .bool(res.ok),
                            "text": .string(res.text),
                            "snapshot": normalizeRecordedURLs(NotifySnapshot.encodeReminderSnapshot(res.snapshot)),
                        ])
                    case "reminder_responders":
                        guard let convId = args?["conv_id"]?.stringValue,
                              let msgId = args?["msg_id"]?.stringValue else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "reminder_responders requires conv_id, msg_id")
                        }
                        let responders = await engine.reminderResponders(in: convId, message: msgId)
                        results["\(stepIndex)"] = normalizeRecordedURLs(NotifySnapshot.encodeReminderResponders(responders))
                    case "reset_card_state":
                        engine.resetCardState()
                        await Task.yield()
                    case "policy":
                        let refNow = Date(timeIntervalSince1970: Double(engine.nowMs()) / 1000.0)
                        let cal = engine.notificationCalendar
                        let suppressMap: [String: CaseJSON] = [
                            "baseline": .bool(NotificationPolicy.shouldSuppress(appIsActive: true, mainWindowVisible: true, openConversation: "5", tag: "5", userIdleSeconds: 4)),
                            "inactive_app": .bool(NotificationPolicy.shouldSuppress(appIsActive: false, mainWindowVisible: true, openConversation: "5", tag: "5", userIdleSeconds: 4)),
                            "hidden_window": .bool(NotificationPolicy.shouldSuppress(appIsActive: true, mainWindowVisible: false, openConversation: "5", tag: "5", userIdleSeconds: 4)),
                            "other_conv": .bool(NotificationPolicy.shouldSuppress(appIsActive: true, mainWindowVisible: true, openConversation: "6", tag: "5", userIdleSeconds: 4)),
                            "empty_tag": .bool(NotificationPolicy.shouldSuppress(appIsActive: true, mainWindowVisible: true, openConversation: "5", tag: "", userIdleSeconds: 4)),
                            "nil_open": .bool(NotificationPolicy.shouldSuppress(appIsActive: true, mainWindowVisible: true, openConversation: nil, tag: "5", userIdleSeconds: 4)),
                            "idle_179": .bool(NotificationPolicy.shouldSuppress(appIsActive: true, mainWindowVisible: true, openConversation: "5", tag: "5", userIdleSeconds: 179)),
                            "idle_180": .bool(NotificationPolicy.shouldSuppress(appIsActive: true, mainWindowVisible: true, openConversation: "5", tag: "5", userIdleSeconds: 180)),
                        ]
                        let refusesMap: [String: CaseJSON] = [
                            "known_unlocked": .bool(NotificationPolicy.refusesReply(hiddenStateKnown: true, conversationLocked: false)),
                            "known_locked": .bool(NotificationPolicy.refusesReply(hiddenStateKnown: true, conversationLocked: true)),
                            "unknown_unlocked": .bool(NotificationPolicy.refusesReply(hiddenStateKnown: false, conversationLocked: false)),
                            "unknown_locked": .bool(NotificationPolicy.refusesReply(hiddenStateKnown: false, conversationLocked: true)),
                        ]
                        let newlyHiddenAdded = NotificationPolicy.newlyHidden(old: ["1", "2"], new: ["2", "3", "4"])
                            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
                            .map(CaseJSON.string)
                        let newlyHiddenSame = NotificationPolicy.newlyHidden(old: ["1"], new: ["1"])
                            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
                            .map(CaseJSON.string)
                        let bodyMap: [String: CaseJSON] = [
                            "preview_on": .string(NotificationPolicy.body("Mẹ: xin chào", showsPreview: true)),
                            "preview_off": .string(NotificationPolicy.body("Mẹ: xin chào", showsPreview: false)),
                        ]
                        let refNowSec = Double(engine.nowMs()) / 1000.0
                        let mIndef = MuteInfo(startTime: refNowSec, duration: -1)
                        let mSameDay = MuteInfo(startTime: refNowSec, duration: 3600)
                        let mNextDay = MuteInfo(startTime: refNowSec, duration: 35200)
                        let muteTexts: [String: CaseJSON] = [
                            "indefinite_desc": .string(mIndef.description(now: refNow, calendar: cal)),
                            "indefinite_status": .string(mIndef.statusText(now: refNow, calendar: cal)),
                            "same_day_desc": .string(mSameDay.description(now: refNow, calendar: cal)),
                            "same_day_status": .string(mSameDay.statusText(now: refNow, calendar: cal)),
                            "next_day_desc": .string(mNextDay.description(now: refNow, calendar: cal)),
                            "next_day_status": .string(mNextDay.statusText(now: refNow, calendar: cal)),
                        ]
                        results["\(stepIndex)"] = .object([
                            "should_suppress": .object(suppressMap),
                            "refuses_reply": .object(refusesMap),
                            "newly_hidden_added": .array(newlyHiddenAdded),
                            "newly_hidden_unchanged": .array(newlyHiddenSame),
                            "body": .object(bodyMap),
                            "mute_texts": .object(muteTexts),
                        ])
                    default:
                        throw RecorderError.invalidStep(scenario: scenario.name, detail: "Unknown cmd '\(cmd)'")
                    }
                } else if let predicate = step["await"] {
                    let timeoutMs = Int(step["timeout_ms"]?.int64Value ?? 5000)
                    transitionRecorder.recordTransition()
                    try await transitionRecorder.awaitPredicate(predicate, timeoutMs: timeoutMs)
                } else if let targetCall = step["await_host"]?.stringValue {
                    let timeoutMs = Int(step["timeout_ms"]?.int64Value ?? 5000)
                    let startCursor = hostCursor
                    var matchedIdx: Int?
                    try await waitForCondition(timeoutMs: timeoutMs, description: "host call '\(targetCall)'") {
                        if let idx = (startCursor..<hostCalls.count).first(where: {
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
                } else if let count = step["ws_push"]?.int64Value {
                    let timeoutMs = Int(step["timeout_ms"]?.int64Value ?? 5000)
                    try await server.pushWebSocketActions(count: Int(count), timeoutMs: timeoutMs)
                } else if let count = step["http_release"]?.int64Value {
                    let timeoutMs = Int(step["timeout_ms"]?.int64Value ?? 5000)
                    try await server.releaseHeldHTTPResponses(count: Int(count), timeoutMs: timeoutMs)
                } else if let label = step["snapshot"]?.stringValue {
                    let snap = await NotifySnapshot.capture(
                        from: engine,
                        bootstrapLogs: bootstrapLogs,
                        lastSendResult: lastSendResult,
                        sendLogs: sendLogs,
                        actionLogs: actionLogs,
                        banners: banners,
                        results: results
                    )
                    snapshots[label] = normalizeRecordedURLs(snap)
                } else {
                    throw RecorderError.invalidStep(scenario: scenario.name, detail: "Unknown step \(step.canonicalString())")
                }
            }
        } catch let err as RecorderError {
            throw err
        } catch {
            XCTFail("\(scenario.name): \(error)")
            throw error
        }

        if let pendingWatch = activeWatchTask {
            pendingWatch.cancel()
            reminderClock.cancelAll()
            _ = await pendingWatch.value
        }

        await engine.settleForRecording()

        let finalSnap = normalizeRecordedURLs(
            await NotifySnapshot.capture(
                from: engine,
                bootstrapLogs: bootstrapLogs,
                lastSendResult: lastSendResult,
                sendLogs: sendLogs,
                actionLogs: actionLogs,
                banners: banners,
                results: results
            )
        )
        let recordedRequests = server.canonicalRequests().map { normalizeRecordedURLs($0) }

        engine.cancelTasksForRecording()
        engine.transportSettleTrace = nil
        server.stop()
        await engine.finishTearDownForRecording()

        if server.hadUnscriptedRequest {
            let unscripted = recordedRequests.filter { $0["unscripted"]?.boolValue == true }
            throw RecorderError.unscriptedRequest(scenario: scenario.name, detail: CaseJSON.array(unscripted).canonicalString())
        }

        return .object([
            "format": .int(1),
            "domain": .string(domain),
            "name": .string(scenario.name),
            "seed": scenario.seed,
            "server": .array(scenario.server),
            "steps": .array(scenario.steps),
            "expect": .object([
                "snapshots": .object(snapshots),
                "final": finalSnap,
                "requests": .array(recordedRequests),
                "host": .array(hostCalls),
            ]),
        ])
    }

    // MARK: - Seed & Clock Helpers

    @MainActor
    private final class VirtualReminderClock {
        private struct Waiter {
            let id: UUID
            var remainingMs: Int64
            let continuation: CheckedContinuation<Bool, Never>
        }

        private var waiters: [Waiter] = []
        private(set) var registeredCount: Int = 0

        var hasWaiter: Bool { !waiters.isEmpty }

        func sleep(seconds: Double) async -> Bool {
            let ms = max(1, Int64((seconds * 1000).rounded()))
            return await withCheckedContinuation { cont in
                registeredCount += 1
                waiters.append(Waiter(id: UUID(), remainingMs: ms, continuation: cont))
            }
        }

        func advance(byMs delta: Int64) {
            var remaining: [Waiter] = []
            var due: [CheckedContinuation<Bool, Never>] = []
            for var w in waiters {
                w.remainingMs -= delta
                if w.remainingMs <= 0 {
                    due.append(w.continuation)
                } else {
                    remaining.append(w)
                }
            }
            waiters = remaining
            for cont in due {
                cont.resume(returning: true)
            }
        }

        func cancelAll() {
            let all = waiters
            waiters.removeAll()
            for w in all {
                w.continuation.resume(returning: false)
            }
        }
    }

    private static func seedSQLiteStore(userId: String, dataDir: URL, seed: CaseJSON) async throws {
        let dbURL = dataDir
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(userId, isDirectory: true)
            .appendingPathComponent("history.sqlite3")
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = try ZaloSQLiteStore(path: dbURL.path)
        try await store.setPreferenceString(key: ZaloWebKitMigrator.donePrefKey, value: "1")

        if let notifPrefs = seed["notif_prefs"], notifPrefs != .null {
            if let enabled = notifPrefs["enabled"]?.boolValue {
                try await store.setPreferenceBool(key: "notifEnabled", value: enabled)
            }
            if let sound = notifPrefs["sound"]?.boolValue {
                try await store.setPreferenceBool(key: "notifSound", value: sound)
            }
            if let mutesArr = notifPrefs["muted_threads"]?.arrayValue {
                let rows: [[String: Any]] = mutesArr.compactMap { row in
                    guard let id = row["id"]?.stringValue, !id.isEmpty else { return nil }
                    let startTime = (row["start_time"]?.toFoundation() as? NSNumber)?.doubleValue ?? 0
                    let duration = (row["duration"]?.toFoundation() as? NSNumber)?.doubleValue ?? -1
                    return ["id": id, "startTime": startTime, "duration": duration]
                }
                if let data = try? JSONSerialization.data(withJSONObject: rows) {
                    try await store.setPreferenceData(key: "mutedThreads", data: data)
                }
            }
        }

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
                    updatedAtMs: row["updated_at_ms"]?.int64Value ?? 1_700_000_000_000
                )
            }
            if !stored.isEmpty {
                try await store.saveConversations(stored)
            }
        }

        if let msgRows = seed["local_messages"]?.arrayValue, !msgRows.isEmpty {
            let stored: [StoredMessage] = msgRows.compactMap { row in
                guard let id = row["id"]?.stringValue, let convId = row["conv_id"]?.stringValue else { return nil }
                let status = row["status"]?.stringValue ?? "sent"
                let kindObj = (row["kind"] != nil && row["kind"] != .null)
                    ? row["kind"]!
                    : .object(["type": .string(row["kind_tag"]?.stringValue ?? "text")])
                let rawJSON: Data = {
                    if let rawObj = row["raw_json"], rawObj != .null {
                        return Data(rawObj.canonicalString().utf8)
                    }
                    let obj: [String: CaseJSON] = [
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
                        "kind": kindObj,
                    ]
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
            if !stored.isEmpty {
                try await store.saveMessages(stored)
            }
        }
        await store.close()
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

    private static func extractInitialSecretKey(from seed: CaseJSON) -> Data? {
        guard let enk = seed["saved_session"]?["plainAccount"]?["zpwEnk"]?.stringValue,
              !enk.isEmpty else {
            return nil
        }
        let parsed = ZaloCrypto.parseSecretKey(enk)
        return (parsed.count == 16 || parsed.count == 32) ? parsed : nil
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
                throw RecorderError.hostNotIsolated(scenario: scenario, detail: "Non-local host '\(raw)' at \(stage)")
            }
        }
        guard domains.isolated else {
            throw RecorderError.hostNotIsolated(scenario: scenario, detail: "domains.isolated must be true at \(stage)")
        }
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
        func decodeRequests(_ arr: [CaseJSON]?) -> [ContactsState.FriendRequest] {
            (arr ?? []).compactMap { row in
                guard let id = row["id"]?.stringValue else { return nil }
                let name = row["name"]?.stringValue ?? id
                let avatar = row["avatar"]?.stringValue.flatMap(URL.init(string:))
                let message = row["message"]?.stringValue ?? ""
                let date = row["date_ms"]?.int64Value.map { Date(timeIntervalSince1970: Double($0) / 1000.0) }
                return ContactsState.FriendRequest(
                    id: id,
                    name: name,
                    avatar: avatar,
                    message: message,
                    date: date
                )
            }
        }
        if let recArr = contacts["received"]?.arrayValue {
            engine.contacts.received = decodeRequests(recArr)
        }
        if let sentArr = contacts["sent"]?.arrayValue {
            engine.contacts.sent = decodeRequests(sentArr)
        }
    }

    private static func toFoundationDict(_ json: CaseJSON) -> [String: Any]? {
        json.toFoundation() as? [String: Any]
    }
}

@MainActor
private final class NotifyTransitionRecorder {
    private let scenarioName: String
    private let captureSnapshot: () -> CaseJSON
    private var history: [CaseJSON] = []

    init(scenarioName: String, captureSnapshot: @escaping () -> CaseJSON) {
        self.scenarioName = scenarioName
        self.captureSnapshot = captureSnapshot
    }

    func recordTransition() {
        let snap = captureSnapshot()
        if history.last != snap {
            history.append(snap)
        }
    }

    func awaitPredicate(_ predicate: CaseJSON, timeoutMs: Int) async throws {
        recordTransition()
        if history.contains(where: { Self.matches($0, predicate: predicate) }) {
            return
        }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
            recordTransition()
            if history.contains(where: { Self.matches($0, predicate: predicate) }) {
                return
            }
        }
        throw NotifyRecorderHarness.RecorderError.timeout(
            scenario: scenarioName,
            detail: "Timed out waiting for \(predicate.canonicalString())"
        )
    }

    private static func matches(_ snapshot: CaseJSON, predicate: CaseJSON) -> Bool {
        guard let expectedPhase = predicate["phase"]?.stringValue,
              let phase = snapshot["phase"],
              phase["kind"]?.stringValue == expectedPhase else {
            return false
        }
        if let expectedStep = predicate["step"]?.stringValue {
            return phase["step"]?.stringValue == expectedStep
        }
        return true
    }
}
