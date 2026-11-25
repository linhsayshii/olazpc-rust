import Foundation
import XCTest
@testable import Olaz

final class CloudRecorderTests: XCTestCase {
    func testCloudScenarios() async throws {
        try await CloudRecorderHarness.runDomainSuite(
            domain: "cloud",
            scenarios: Self.cloudScenarios()
        )
    }

    // MARK: - Helpers

    private static let baseTs: Int64 = 1_700_000_000_000

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
        isE2EE: Bool = false
    ) -> CaseJSON {
        let effectiveClientId = clientId ?? "cli_\(id)"
        let rawObj: [String: CaseJSON] = [
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

    private static func stepMsg(
        id: String,
        convId: String,
        clientId: String? = nil,
        senderId: String,
        senderName: String = "Alice",
        senderAvatar: String = "https://cdn.example.invalid/a.jpg",
        isMine: Bool = false,
        text: String,
        kind: CaseJSON,
        tsMs: Int64,
        status: String = "sent"
    ) -> CaseJSON {
        .object([
            "id": .string(id),
            "conv_id": .string(convId),
            "client_id": .string(clientId ?? "cli_\(id)"),
            "sender_id": .string(senderId),
            "sender_name": .string(senderName),
            "sender_avatar": .string(senderAvatar),
            "is_mine": .bool(isMine),
            "text": .string(text),
            "date_ms": .int(tsMs),
            "status": .string(status),
            "is_e2ee": .bool(false),
            "kind": kind,
        ])
    }

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

    private static func cloudOkScript(path: String, data: CaseJSON) -> CaseJSON {
        CloudRecorderHarness.httpScript(
            path: path,
            method: "GET",
            status: 200,
            json: .object([
                "error_code": .int(0),
                "data": data,
            ])
        )
    }

    private static func cloudErrScript(path: String, status: Int64 = 500, json: CaseJSON? = nil) -> CaseJSON {
        CloudRecorderHarness.httpScript(
            path: path,
            method: "GET",
            status: status,
            json: json ?? .object(["error_code": .int(500), "error_message": .string("server error")])
        )
    }

    // MARK: - Scenarios

    private static func cloudScenarios() -> [CloudRecorderHarness.ScenarioDef] {
        [
            // 1. refresh_signed_out_and_no_store:
            // Signed-out account + no SQLite store produces an empty loaded snapshot with 0 server calls.
            CloudRecorderHarness.ScenarioDef(
                name: "refresh_signed_out_and_no_store",
                seed: CloudRecorderHarness.signedOutSeed(),
                server: [
                    CloudRecorderHarness.httpScript(
                        path: "/api/login/getServerInfo",
                        method: "GET",
                        status: 200,
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                    CloudRecorderHarness.httpScript(
                        path: "/api/login/reqqr",
                        method: "GET",
                        status: 500,
                        json: .object(["error_code": .int(500), "error_message": .string("qr down")])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("login"), "step": .string("failed")]), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("before_refresh")]),
                    .object(["cmd": .string("refresh_cloud")]),
                ]
            ),

            // 2. refresh_server_snapshot:
            // All 6 zCloud endpoints succeeding (paid plan with expiry + family usage),
            // each endpoint failing in turn, and previous plan kept when snapshot is missing.
            CloudRecorderHarness.ScenarioDef(
                name: "refresh_server_snapshot",
                seed: CloudRecorderHarness.readySessionSeed(
                    userId: "2001102",
                    displayName: "Cloud User 2",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "local_conversations": .array([
                            localConv(id: "3001101", name: "Alice", previewText: "Photo", previewTsMs: baseTs + 1000),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "m_p1", convId: "3001101", senderId: "3001101", text: "[Hình ảnh]",
                                kind: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/p1.jpg"), "width": .int(800), "height": .int(600)]),
                                kindTag: "photo", tsMs: baseTs + 1000
                            ),
                            storedMsg(
                                id: "m_self", convId: "92001102", senderId: "2001102", senderName: "Cloud User 2", isMine: true, text: "self.bin",
                                kind: .object(["type": .string("file"), "name": .string("self.bin"), "size": .int(200_000), "url": .string("https://cdn.example.invalid/self.bin")]),
                                kindTag: "file", tsMs: baseTs + 2000
                            ),
                        ]),
                    ]
                ),
                server: [
                    CloudRecorderHarness.loginInfoScript(uid: "2001102", displayName: "Cloud User 2"),
                    CloudRecorderHarness.profileMeScript(uid: "2001102", displayName: "Cloud User 2"),
                    // Refresh 1: all endpoints ok
                    cloudOkScript(
                        path: "/api/getCloudViewerKey",
                        data: .object(["viewer_key": .string("vk_cloud_1"), "enk": .string("MDEyMzQ1Njc4OWFiY2RlZg==")])
                    ),
                    cloudOkScript(
                        path: "/cloudmedia/info/pc/v1/usage-mycloud",
                        data: .object([
                            "plan": .int(0),
                            "quota": .int(107_374_182_400),
                            "usage": .int(5_000_000),
                            "service_usage": .object(["cloud_media": .int(2_000_000), "message_backup": .int(1_000_000), "my_cloud": .int(2_000_000)]),
                        ])
                    ),
                    cloudOkScript(
                        path: "/cloudmedia/info/pc/v2/usage",
                        data: .object([
                            "plan": .int(0),
                            "quota": .int(107_374_182_400),
                            "usage": .int(6_000_000),
                            "service_usage": .object(["cloud_media": .int(3_000_000), "message_backup": .int(1_000_000), "my_cloud": .int(2_000_000)]),
                        ])
                    ),
                    cloudOkScript(
                        path: "/cloudmedia/info/pc/v1/cloud-settings",
                        data: .object(["opt_in": .int(5), "enable_offload": .int(1), "cloud_media_file_size_limit": .int(2_147_483_648)])
                    ),
                    cloudOkScript(
                        path: "/zalocloud/cloudinfopcweb/v1/info",
                        data: .object([
                            "package_name": .object(["vi": .string("zCloud Pro"), "en": .string("zCloud Pro En")]),
                            "subscription_info": .object([
                                "expire_time": .int(1_800_000_000),
                                "auto_renew_product_id": .string("zcloud_pro_yearly"),
                                "cancelled_renew": .bool(false),
                                "duration_months": .int(12),
                            ]),
                        ])
                    ),
                    cloudOkScript(
                        path: "/cloudmedia/info/pc/v1/family-usage",
                        data: .object([
                            "members": .array([
                                .object(["uid": .string("2001102"), "usage": .int(1_000_000)]),
                                .object(["uid": .string("3001199"), "usage": .int(4_000_000)]),
                            ]),
                        ])
                    ),
                    // Refresh 2: /v2/usage fails -> falls back to usage-mycloud
                    cloudOkScript(
                        path: "/cloudmedia/info/pc/v1/usage-mycloud",
                        data: .object([
                            "plan": .int(0),
                            "quota": .int(53_687_091_200),
                            "usage": .int(5_000_000),
                            "service_usage": .object(["cloud_media": .int(2_000_000), "message_backup": .int(1_000_000), "my_cloud": .int(2_000_000)]),
                        ])
                    ),
                    cloudErrScript(path: "/cloudmedia/info/pc/v2/usage"),
                    cloudOkScript(
                        path: "/cloudmedia/info/pc/v1/cloud-settings",
                        data: .object(["opt_in": .int(7), "enable_offload": .int(0), "cloud_media_file_size_limit": .int(1_073_741_824)])
                    ),
                    cloudOkScript(
                        path: "/zalocloud/cloudinfopcweb/v1/info",
                        data: .object([
                            "package_name": .string("zCloud Plus"),
                            "subscription_info": .object([
                                "expire_time": .int(1_850_000_000),
                                "auto_renew_product_id": .string("p1"),
                                "cancelled_renew": .bool(true),
                                "duration_months": .int(6),
                            ]),
                        ])
                    ),
                    cloudOkScript(
                        path: "/cloudmedia/info/pc/v1/family-usage",
                        data: .object([
                            "data": .array([
                                .object(["userId": .string("3001198"), "total": .int(2_500_000)]),
                            ]),
                        ])
                    ),
                    // Refresh 3: /cloud-settings fails (grace plan 100)
                    cloudOkScript(
                        path: "/cloudmedia/info/pc/v1/usage-mycloud",
                        data: .object(["plan": .int(100), "quota": .int(107_374_182_400), "usage": .int(4_500_000)])
                    ),
                    cloudOkScript(
                        path: "/cloudmedia/info/pc/v2/usage",
                        data: .object([
                            "plan": .int(100),
                            "quota": .int(107_374_182_400),
                            "usage": .int(4_500_000),
                            "service_usage": .object(["cloud_media": .int(1_500_000), "message_backup": .int(1_000_000), "my_cloud": .int(2_000_000)]),
                        ])
                    ),
                    cloudErrScript(path: "/cloudmedia/info/pc/v1/cloud-settings"),
                    cloudOkScript(
                        path: "/zalocloud/cloudinfopcweb/v1/info",
                        data: .object(["package_name": .string("IgnoredGraceName")])
                    ),
                    cloudOkScript(path: "/cloudmedia/info/pc/v1/family-usage", data: .object(["members": .array([])])),
                    // Refresh 4: /info fails
                    cloudOkScript(
                        path: "/cloudmedia/info/pc/v1/usage-mycloud",
                        data: .object(["plan": .int(0), "quota": .int(107_374_182_400), "usage": .int(3_500_000)])
                    ),
                    cloudOkScript(
                        path: "/cloudmedia/info/pc/v2/usage",
                        data: .object([
                            "plan": .int(0),
                            "quota": .int(107_374_182_400),
                            "usage": .int(3_500_000),
                            "service_usage": .object(["cloud_media": .int(1_500_000), "message_backup": .int(500_000), "my_cloud": .int(1_500_000)]),
                        ])
                    ),
                    cloudOkScript(
                        path: "/cloudmedia/info/pc/v1/cloud-settings",
                        data: .object(["opt_in": .int(3), "cloud_media_file_size_limit": .int(1_073_741_824)])
                    ),
                    cloudErrScript(path: "/zalocloud/cloudinfopcweb/v1/info"),
                    cloudOkScript(
                        path: "/cloudmedia/info/pc/v1/family-usage",
                        data: .object(["members": .array([.object(["uid": .string("3001199"), "usage": .int(1_000_000)])])])
                    ),
                    // Refresh 5: /family-usage fails (establishes "zCloud Keep" before /usage-mycloud fails)
                    cloudOkScript(
                        path: "/cloudmedia/info/pc/v1/usage-mycloud",
                        data: .object(["plan": .int(0), "quota": .int(107_374_182_400), "usage": .int(3_500_000)])
                    ),
                    cloudOkScript(
                        path: "/cloudmedia/info/pc/v2/usage",
                        data: .object([
                            "plan": .int(0),
                            "quota": .int(107_374_182_400),
                            "usage": .int(3_500_000),
                            "service_usage": .object(["cloud_media": .int(1_500_000), "message_backup": .int(500_000), "my_cloud": .int(1_500_000)]),
                        ])
                    ),
                    cloudOkScript(
                        path: "/cloudmedia/info/pc/v1/cloud-settings",
                        data: .object(["opt_in": .int(7), "cloud_media_file_size_limit": .int(1_073_741_824)])
                    ),
                    cloudOkScript(
                        path: "/zalocloud/cloudinfopcweb/v1/info",
                        data: .object([
                            "package_name": .string("zCloud Keep"),
                            "subscription_info": .object([
                                "expire_time": .int(1_800_000_000),
                                "duration_months": .int(3),
                            ]),
                        ])
                    ),
                    cloudErrScript(path: "/cloudmedia/info/pc/v1/family-usage"),
                    // Refresh 6: /usage-mycloud fails -> server snapshot missing, previous plan kept
                    cloudErrScript(path: "/cloudmedia/info/pc/v1/usage-mycloud"),
                    // Refresh 7: -205 clears cached key, /api/getCloudViewerKey fails -> previous plan kept
                    cloudErrScript(
                        path: "/cloudmedia/info/pc/v1/usage-mycloud",
                        status: 200,
                        json: .object(["error_code": .int(-205), "error_message": .string("expired viewer key")])
                    ),
                    cloudErrScript(path: "/api/getCloudViewerKey"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("refresh_cloud")]),
                    .object(["snapshot": .string("all_ok")]),
                    .object(["cmd": .string("refresh_cloud")]),
                    .object(["snapshot": .string("v2_usage_failed")]),
                    .object(["cmd": .string("refresh_cloud")]),
                    .object(["snapshot": .string("settings_failed")]),
                    .object(["cmd": .string("refresh_cloud")]),
                    .object(["snapshot": .string("info_failed")]),
                    .object(["cmd": .string("refresh_cloud")]),
                    .object(["snapshot": .string("family_failed")]),
                    .object(["cmd": .string("refresh_cloud")]),
                    .object(["snapshot": .string("usage_mycloud_failed")]),
                    .object(["cmd": .string("refresh_cloud")]),
                ]
            ),

            // 3. aggregation:
            // Store totals per kind, unsynced memory rows, dedupe with store, last activity
            // (store vs memory vs preview), name fallbacks (unknown 1-1, group, self), sort by total.
            CloudRecorderHarness.ScenarioDef(
                name: "aggregation",
                seed: CloudRecorderHarness.readySessionSeed(
                    userId: "2001103",
                    displayName: "Cloud User 3",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "local_conversations": .array([
                            localConv(id: "3001131", name: "Alice", previewText: "Old preview", previewTsMs: baseTs + 1000),
                            localConv(id: "3001132", name: "Bob", previewText: "Latest preview", previewTsMs: baseTs + 10_000),
                            localConv(id: "g5001134", isGroup: true, name: "", members: 4, previewText: "Group msg", previewTsMs: baseTs + 2000),
                        ]),
                        "local_messages": .array([
                            // 3001131 (Alice): photo 150k + voice 40k + file 250k = 440k (plus memory photo 150k = 590k)
                            storedMsg(
                                id: "ag_dup", convId: "3001131", senderId: "3001131", text: "[Hình ảnh]",
                                kind: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/ag1.jpg"), "width": .int(100), "height": .int(100)]),
                                kindTag: "photo", tsMs: baseTs + 2000
                            ),
                            storedMsg(
                                id: "ag_voice", convId: "3001131", senderId: "3001131", text: "[Tin nhắn thoại]",
                                kind: .object(["type": .string("voice"), "url": .string("https://cdn.example.invalid/ag1.m4a"), "duration": .int(4)]),
                                kindTag: "voice", tsMs: baseTs + 3000
                            ),
                            storedMsg(
                                id: "ag_file", convId: "3001131", senderId: "3001131", text: "spec.pdf",
                                kind: .object(["type": .string("file"), "name": .string("spec.pdf"), "size": .int(250_000), "url": .string("https://cdn.example.invalid/spec.pdf")]),
                                kindTag: "file", tsMs: baseTs + 4000
                            ),
                            // 3001132 (Bob): video 1.5M, preview is newer
                            storedMsg(
                                id: "ag_vid", convId: "3001132", senderId: "3001132", text: "[Video]",
                                kind: .object(["type": .string("video"), "thumbnail": .string(""), "duration": .int(12), "url": .string("https://cdn.example.invalid/ag.mp4")]),
                                kindTag: "video", tsMs: baseTs + 2000
                            ),
                            // 3001133 (unknown 1-1 not in conversations): file 310k, last_activity from store
                            storedMsg(
                                id: "ag_unk11", convId: "3001133", senderId: "3001133", senderName: "Unknown", text: "notes.txt",
                                kind: .object(["type": .string("file"), "name": .string("notes.txt"), "size": .int(310_000), "url": .string("https://cdn.example.invalid/notes.txt")]),
                                kindTag: "file", tsMs: baseTs + 6000
                            ),
                            // 5001134 (group with empty name in conversations -> "Nhóm"): photo 150k
                            storedMsg(
                                id: "ag_grp_conv", convId: "g5001134", senderId: "3001139", text: "[Hình ảnh]",
                                kind: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/g.jpg"), "width": .int(50), "height": .int(50)]),
                                kindTag: "photo", tsMs: baseTs + 7000
                            ),
                            // 5001136 (group in store only without conversations row -> records COALESCE(c.is_group, 0) bug)
                            storedMsg(
                                id: "ag_grp_noconv", convId: "g5001136", senderId: "3001139", text: "raw.bin",
                                kind: .object(["type": .string("file"), "name": .string("raw.bin"), "size": .int(70_000), "url": .string("https://cdn.example.invalid/raw.bin")]),
                                kindTag: "file", tsMs: baseTs + 6500
                            ),
                            // 92001103 (self conversation -> "Cloud của tôi", goes to my_cloud_types): photo 150k + file 60k = 210k
                            storedMsg(
                                id: "ag_self1", convId: "92001103", senderId: "2001103", isMine: true, text: "[Hình ảnh]",
                                kind: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/s1.jpg"), "width": .int(50), "height": .int(50)]),
                                kindTag: "photo", tsMs: baseTs + 1000
                            ),
                            storedMsg(
                                id: "ag_self2", convId: "92001103", senderId: "2001103", isMine: true, text: "keep.pdf",
                                kind: .object(["type": .string("file"), "name": .string("keep.pdf"), "size": .int(60_000), "url": .string("https://cdn.example.invalid/keep.pdf")]),
                                kindTag: "file", tsMs: baseTs + 1500
                            ),
                        ]),
                    ]
                ),
                server: [
                    CloudRecorderHarness.loginInfoScript(uid: "2001103", displayName: "Cloud User 3"),
                    CloudRecorderHarness.profileMeScript(uid: "2001103", displayName: "Cloud User 3"),
                    cloudErrScript(path: "/api/getCloudViewerKey"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    // Load stored ag_dup into memory -> must NOT double count
                    .object(["cmd": .string("ensure_loaded"), "args": .object(["conv_id": .string("3001131"), "msg_id": .string("ag_dup")])]),
                    // Load memory-only photo into 3001131 -> pushes total to 590k and last_activity to +5000
                    .object([
                        "cmd": .string("ensure_loaded"),
                        "args": .object([
                            "conv_id": .string("3001131"),
                            "message": stepMsg(
                                id: "ag_mem_photo", convId: "3001131", senderId: "3001131", text: "[Hình ảnh]",
                                kind: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/mem.jpg"), "width": .int(200), "height": .int(200)]),
                                tsMs: baseTs + 5000
                            ),
                        ]),
                    ]),
                    // Memory-only group 5001135 (not in conversations/store -> falls back to isGroup=true, name="Nhóm")
                    .object([
                        "cmd": .string("ensure_loaded"),
                        "args": .object([
                            "conv_id": .string("g5001135"),
                            "message": stepMsg(
                                id: "ag_mem_grp_file", convId: "g5001135", senderId: "3001139", text: "grp.pdf",
                                kind: .object(["type": .string("file"), "name": .string("grp.pdf"), "size": .int(90_000), "url": .string("https://cdn.example.invalid/grp.pdf")]),
                                tsMs: baseTs + 8000
                            ),
                        ]),
                    ]),
                    // Non-media text message in memory must not affect totals or last_activity
                    .object([
                        "cmd": .string("ensure_loaded"),
                        "args": .object([
                            "conv_id": .string("g5001135"),
                            "message": stepMsg(
                                id: "ag_mem_grp_txt", convId: "g5001135", senderId: "3001139", text: "ignore me",
                                kind: .object(["type": .string("text")]),
                                tsMs: baseTs + 99_000
                            ),
                        ]),
                    ]),
                    .object(["cmd": .string("refresh_cloud")]),
                ]
            ),

            // 4. list_store_only:
            // Kind filter, all kinds, self excluded only in all-convs list, sort by size and date
            // both directions, tie-breaks by date DESC + id, offset/limit clamps (-1, 0), hasMore.
            CloudRecorderHarness.ScenarioDef(
                name: "list_store_only",
                seed: CloudRecorderHarness.readySessionSeed(
                    userId: "2001104",
                    displayName: "Cloud User 4",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "local_conversations": .array([
                            localConv(id: "3001141", name: "Alice"),
                            localConv(id: "g5001142", isGroup: true, name: "Group B", members: 3),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "ls_1", convId: "3001141", senderId: "3001141", text: "[Hình ảnh]",
                                kind: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/ls1.jpg"), "width": .int(640), "height": .int(480)]),
                                kindTag: "photo", tsMs: baseTs + 1000
                            ),
                            storedMsg(
                                id: "ls_2", convId: "3001141", senderId: "3001141", text: "tie.pdf",
                                kind: .object(["type": .string("file"), "name": .string("tie.pdf"), "size": .int(150_000), "url": .string("https://cdn.example.invalid/tie.pdf")]),
                                kindTag: "file", tsMs: baseTs + 1000
                            ),
                            storedMsg(
                                id: "ls_3", convId: "g5001142", senderId: "3001149", text: "newer_same_size.zip",
                                kind: .object(["type": .string("file"), "name": .string("newer_same_size.zip"), "size": .int(150_000), "url": .string("https://cdn.example.invalid/n.zip")]),
                                kindTag: "file", tsMs: baseTs + 3000
                            ),
                            storedMsg(
                                id: "ls_4", convId: "g5001142", senderId: "3001149", text: "[Video]",
                                kind: .object(["type": .string("video"), "thumbnail": .string(""), "duration": .int(18), "url": .string("https://cdn.example.invalid/ls4.mp4")]),
                                kindTag: "video", tsMs: baseTs + 2000
                            ),
                            storedMsg(
                                id: "ls_5", convId: "3001141", senderId: "3001141", text: "[Tin nhắn thoại]",
                                kind: .object(["type": .string("voice"), "url": .string("https://cdn.example.invalid/ls5.m4a"), "duration": .int(7)]),
                                kindTag: "voice", tsMs: baseTs + 4000
                            ),
                            storedMsg(
                                id: "ls_self", convId: "92001104", senderId: "2001104", isMine: true, text: "[Hình ảnh]",
                                kind: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/self.jpg"), "width": .int(100), "height": .int(100)]),
                                kindTag: "photo", tsMs: baseTs + 5000
                            ),
                        ]),
                    ]
                ),
                server: [
                    CloudRecorderHarness.loginInfoScript(uid: "2001104", displayName: "Cloud User 4"),
                    CloudRecorderHarness.profileMeScript(uid: "2001104", displayName: "Cloud User 4"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    // All convs (self excluded), date DESC
                    .object(["cmd": .string("cloud_list"), "args": .object(["sort_by_size": .bool(false), "ascending": .bool(false), "offset": .int(0), "limit": .int(20)])]),
                    // Self conv explicitly (self included)
                    .object(["cmd": .string("cloud_list"), "args": .object(["conv_id": .string("92001104"), "sort_by_size": .bool(false), "ascending": .bool(false), "offset": .int(0), "limit": .int(20)])]),
                    // Single conv 3001141
                    .object(["cmd": .string("cloud_list"), "args": .object(["conv_id": .string("3001141"), "sort_by_size": .bool(false), "ascending": .bool(false), "offset": .int(0), "limit": .int(20)])]),
                    // Kind filters
                    .object(["cmd": .string("cloud_list"), "args": .object(["kind": .string("photo"), "sort_by_size": .bool(false), "ascending": .bool(false), "offset": .int(0), "limit": .int(20)])]),
                    .object(["cmd": .string("cloud_list"), "args": .object(["kind": .string("video"), "sort_by_size": .bool(false), "ascending": .bool(false), "offset": .int(0), "limit": .int(20)])]),
                    .object(["cmd": .string("cloud_list"), "args": .object(["kind": .string("file"), "sort_by_size": .bool(false), "ascending": .bool(false), "offset": .int(0), "limit": .int(20)])]),
                    .object(["cmd": .string("cloud_list"), "args": .object(["kind": .string("voice"), "sort_by_size": .bool(false), "ascending": .bool(false), "offset": .int(0), "limit": .int(20)])]),
                    .object(["cmd": .string("cloud_list"), "args": .object(["kind": .string("other"), "sort_by_size": .bool(false), "ascending": .bool(false), "offset": .int(0), "limit": .int(20)])]),
                    // Size sorts (DESC & ASC — secondary date remains DESC)
                    .object(["cmd": .string("cloud_list"), "args": .object(["sort_by_size": .bool(true), "ascending": .bool(false), "offset": .int(0), "limit": .int(20)])]),
                    .object(["cmd": .string("cloud_list"), "args": .object(["sort_by_size": .bool(true), "ascending": .bool(true), "offset": .int(0), "limit": .int(20)])]),
                    // Date ASC (tie-break by id ASC)
                    .object(["cmd": .string("cloud_list"), "args": .object(["sort_by_size": .bool(false), "ascending": .bool(true), "offset": .int(0), "limit": .int(20)])]),
                    // Clamps: offset -1 -> 0, limit 0 -> 1
                    .object(["cmd": .string("cloud_list"), "args": .object(["sort_by_size": .bool(false), "ascending": .bool(false), "offset": .int(-1), "limit": .int(0)])]),
                    // Pagination hasMore
                    .object(["cmd": .string("cloud_list"), "args": .object(["sort_by_size": .bool(false), "ascending": .bool(false), "offset": .int(1), "limit": .int(2)])]),
                    .object(["cmd": .string("cloud_list"), "args": .object(["sort_by_size": .bool(false), "ascending": .bool(false), "offset": .int(4), "limit": .int(2)])]),
                    .object(["cmd": .string("cloud_list"), "args": .object(["sort_by_size": .bool(false), "ascending": .bool(false), "offset": .int(10), "limit": .int(2)])]),
                ]
            ),

            // 5. list_memory_merge:
            // Memory-only rows merged with store rows, dedupe, paging across merged list, and no store at all.
            CloudRecorderHarness.ScenarioDef(
                name: "list_memory_merge",
                seed: CloudRecorderHarness.readySessionSeed(
                    userId: "2001105",
                    displayName: "Cloud User 5",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "local_conversations": .array([
                            localConv(id: "3001151", name: "Alice"),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "lm_s1", convId: "3001151", senderId: "3001151", text: "[Hình ảnh]",
                                kind: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/lm1.jpg"), "width": .int(100), "height": .int(100)]),
                                kindTag: "photo", tsMs: baseTs + 1000
                            ),
                            storedMsg(
                                id: "lm_s2", convId: "3001151", senderId: "3001151", text: "store.doc",
                                kind: .object(["type": .string("file"), "name": .string("store.doc"), "size": .int(90_000), "url": .string("https://cdn.example.invalid/store.doc")]),
                                kindTag: "file", tsMs: baseTs + 3000
                            ),
                            storedMsg(
                                id: "lm_sdup", convId: "3001151", senderId: "3001151", text: "[Hình ảnh]",
                                kind: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/dup.jpg"), "width": .int(100), "height": .int(100)]),
                                kindTag: "photo", tsMs: baseTs + 5000
                            ),
                        ]),
                    ]
                ),
                server: [
                    CloudRecorderHarness.loginInfoScript(uid: "2001105", displayName: "Cloud User 5"),
                    CloudRecorderHarness.profileMeScript(uid: "2001105", displayName: "Cloud User 5"),
                    CloudRecorderHarness.httpScript(
                        path: "/api/login/getServerInfo",
                        method: "GET",
                        status: 200,
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                    CloudRecorderHarness.httpScript(
                        path: "/api/login/reqqr",
                        method: "GET",
                        status: 500,
                        json: .object(["error_code": .int(500), "error_message": .string("qr down")])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    // Load existing store row into memory -> must dedupe
                    .object(["cmd": .string("ensure_loaded"), "args": .object(["conv_id": .string("3001151"), "msg_id": .string("lm_sdup")])]),
                    // Memory-only items
                    .object([
                        "cmd": .string("ensure_loaded"),
                        "args": .object([
                            "conv_id": .string("3001151"),
                            "message": stepMsg(
                                id: "lm_m1", convId: "3001151", senderId: "3001151", text: "mem.pdf",
                                kind: .object(["type": .string("file"), "name": .string("mem.pdf"), "size": .int(50_000), "url": .string("https://cdn.example.invalid/mem.pdf")]),
                                tsMs: baseTs + 4000
                            ),
                        ]),
                    ]),
                    .object([
                        "cmd": .string("ensure_loaded"),
                        "args": .object([
                            "conv_id": .string("3001151"),
                            "message": stepMsg(
                                id: "lm_m2", convId: "3001151", senderId: "3001151", text: "[Tin nhắn thoại]",
                                kind: .object(["type": .string("voice"), "url": .string("https://cdn.example.invalid/m2.m4a"), "duration": .int(6)]),
                                tsMs: baseTs + 2000
                            ),
                        ]),
                    ]),
                    .object([
                        "cmd": .string("ensure_loaded"),
                        "args": .object([
                            "conv_id": .string("92001105"),
                            "message": stepMsg(
                                id: "lm_mself", convId: "92001105", senderId: "2001105", isMine: true, text: "[Hình ảnh]",
                                kind: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/ms.jpg"), "width": .int(50), "height": .int(50)]),
                                tsMs: baseTs + 6000
                            ),
                        ]),
                    ]),
                    // Paging across the 5 merged non-self items
                    .object(["cmd": .string("cloud_list"), "args": .object(["sort_by_size": .bool(false), "ascending": .bool(false), "offset": .int(0), "limit": .int(2)])]),
                    .object(["cmd": .string("cloud_list"), "args": .object(["sort_by_size": .bool(false), "ascending": .bool(false), "offset": .int(2), "limit": .int(2)])]),
                    .object(["cmd": .string("cloud_list"), "args": .object(["sort_by_size": .bool(false), "ascending": .bool(false), "offset": .int(4), "limit": .int(2)])]),
                    .object(["cmd": .string("cloud_list"), "args": .object(["sort_by_size": .bool(true), "ascending": .bool(true), "offset": .int(0), "limit": .int(10)])]),
                    .object(["snapshot": .string("merged_with_store")]),
                    // Log out -> drops sqliteStore = nil (no store at all)
                    .object(["cmd": .string("log_out")]),
                    .object(["await": .object(["phase": .string("login"), "step": .string("failed")]), "timeout_ms": .int(5000)]),
                    .object([
                        "cmd": .string("ensure_loaded"),
                        "args": .object([
                            "conv_id": .string("3001151"),
                            "message": stepMsg(
                                id: "ns_1", convId: "3001151", senderId: "3001151", text: "[Hình ảnh]",
                                kind: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/ns1.jpg"), "width": .int(120), "height": .int(80)]),
                                tsMs: baseTs + 7000
                            ),
                        ]),
                    ]),
                    .object([
                        "cmd": .string("ensure_loaded"),
                        "args": .object([
                            "conv_id": .string("3001151"),
                            "message": stepMsg(
                                id: "ns_2", convId: "3001151", senderId: "3001151", text: "nostore.txt",
                                kind: .object(["type": .string("file"), "name": .string("nostore.txt"), "size": .int(12_000), "url": .string("https://cdn.example.invalid/ns2.txt")]),
                                tsMs: baseTs + 8000
                            ),
                        ]),
                    ]),
                    .object(["cmd": .string("cloud_list"), "args": .object(["sort_by_size": .bool(false), "ascending": .bool(false), "offset": .int(0), "limit": .int(1)])]),
                    .object(["cmd": .string("cloud_list"), "args": .object(["sort_by_size": .bool(false), "ascending": .bool(false), "offset": .int(1), "limit": .int(5)])]),
                    .object(["cmd": .string("refresh_cloud")]),
                ]
            ),

            // 6. fetch_and_thumbnail:
            // Bad key, missing message, photo/video (file, expired, unavailable),
            // voice/file (ready, expired, failed), non-fetchable kind, video thumbnail key.
            CloudRecorderHarness.ScenarioDef(
                name: "fetch_and_thumbnail",
                seed: CloudRecorderHarness.readySessionSeed(
                    userId: "2001106",
                    displayName: "Cloud User 6",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "host_results": .object([
                            "resolve_media": .array([
                                .object(["state": .string("file"), "path": .string("/fake/cloud/photo1.jpg")]),
                                .object(["state": .string("expired")]),
                                .object(["state": .string("unavailable")]),
                                .object(["state": .string("file"), "path": .string("/fake/cloud/clip1.mp4")]),
                                .object(["state": .string("expired")]),
                                .object(["state": .string("unavailable")]),
                                .object(["state": .string("file"), "path": .string("/fake/cloud/thumb1.jpg")]),
                                .object(["state": .string("expired")]),
                                .object(["state": .string("unsupported")]),
                                .object(["state": .string("unavailable")]),
                            ]),
                            "resolve_file": .array([
                                .object(["state": .string("ready"), "path": .string("/fake/cloud/voice1.m4a")]),
                                .object(["state": .string("expired")]),
                                .object(["state": .string("failed"), "message": .string("Voice download failed")]),
                                .object(["state": .string("ready"), "path": .string("/fake/cloud/report.pdf")]),
                                .object(["state": .string("expired")]),
                                .object(["state": .string("failed"), "message": .string("File download failed")]),
                            ]),
                        ]),
                        "local_conversations": .array([
                            localConv(id: "3001161", name: "Alice"),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "ft_photo", convId: "3001161", senderId: "3001161", text: "Photo title",
                                kind: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/ft.jpg"), "width": .int(500), "height": .int(400)]),
                                kindTag: "photo", tsMs: baseTs + 1000
                            ),
                            storedMsg(
                                id: "ft_video", convId: "3001161", senderId: "3001161", text: "Video title",
                                kind: .object(["type": .string("video"), "thumbnail": .string(""), "duration": .int(9), "url": .string("https://cdn.example.invalid/ft.mp4")]),
                                kindTag: "video", tsMs: baseTs + 2000
                            ),
                            storedMsg(
                                id: "ft_voice", convId: "3001161", senderId: "3001161", text: "Voice msg",
                                kind: .object(["type": .string("voice"), "url": .string("https://cdn.example.invalid/ft.m4a"), "duration": .int(8)]),
                                kindTag: "voice", tsMs: baseTs + 3000
                            ),
                            storedMsg(
                                id: "ft_file", convId: "3001161", senderId: "3001161", text: "report.pdf",
                                kind: .object(["type": .string("file"), "name": .string("report.pdf"), "size": .int(4096), "url": .string("https://cdn.example.invalid/report.pdf")]),
                                kindTag: "file", tsMs: baseTs + 4000
                            ),
                            storedMsg(
                                id: "ft_text", convId: "3001161", senderId: "3001161", text: "Not downloadable",
                                kind: .object(["type": .string("text")]),
                                kindTag: "text", tsMs: baseTs + 5000
                            ),
                        ]),
                    ]
                ),
                server: [
                    CloudRecorderHarness.loginInfoScript(uid: "2001106", displayName: "Cloud User 6"),
                    CloudRecorderHarness.profileMeScript(uid: "2001106", displayName: "Cloud User 6"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    // Bad key & missing message
                    .object(["cmd": .string("cloud_fetch"), "args": .object(["key": .string("badkey")])]),
                    .object(["cmd": .string("cloud_fetch"), "args": .object(["key": .string("3001161|missing_id|photo")])]),
                    // Photo (file, expired, unavailable)
                    .object(["cmd": .string("cloud_fetch"), "args": .object(["key": .string("3001161|ft_photo|photo")])]),
                    .object(["cmd": .string("cloud_fetch"), "args": .object(["key": .string("3001161|ft_photo|photo")])]),
                    .object(["cmd": .string("cloud_fetch"), "args": .object(["key": .string("3001161|ft_photo|photo")])]),
                    // Video (file, expired, unavailable)
                    .object(["cmd": .string("cloud_fetch"), "args": .object(["key": .string("3001161|ft_video|video")])]),
                    .object(["cmd": .string("cloud_fetch"), "args": .object(["key": .string("3001161|ft_video|video")])]),
                    .object(["cmd": .string("cloud_fetch"), "args": .object(["key": .string("3001161|ft_video|video")])]),
                    // Voice (ready, expired, failed)
                    .object(["cmd": .string("cloud_fetch"), "args": .object(["key": .string("3001161|ft_voice|voice")])]),
                    .object(["cmd": .string("cloud_fetch"), "args": .object(["key": .string("3001161|ft_voice|voice")])]),
                    .object(["cmd": .string("cloud_fetch"), "args": .object(["key": .string("3001161|ft_voice|voice")])]),
                    // File (ready, expired, failed)
                    .object(["cmd": .string("cloud_fetch"), "args": .object(["key": .string("3001161|ft_file|file")])]),
                    .object(["cmd": .string("cloud_fetch"), "args": .object(["key": .string("3001161|ft_file|file")])]),
                    .object(["cmd": .string("cloud_fetch"), "args": .object(["key": .string("3001161|ft_file|file")])]),
                    // Non-fetchable kind
                    .object(["cmd": .string("cloud_fetch"), "args": .object(["key": .string("3001161|ft_text|text")])]),
                    // Thumbnails: bad key, videoThumb, photo expired, non-video kind ("other"), 2-part key
                    .object(["cmd": .string("cloud_thumbnail"), "args": .object(["key": .string("badkey")])]),
                    .object(["cmd": .string("cloud_thumbnail"), "args": .object(["key": .string("3001161|ft_video|video")])]),
                    .object(["cmd": .string("cloud_thumbnail"), "args": .object(["key": .string("3001161|ft_photo|photo")])]),
                    .object(["cmd": .string("cloud_thumbnail"), "args": .object(["key": .string("3001161|ft_photo|other")])]),
                    .object(["cmd": .string("cloud_thumbnail"), "args": .object(["key": .string("3001161|ft_photo")])]),
                ]
            ),

            // 7. delete:
            // Two keys found, one bad key, one missing message; API error still applies local delete; refresh after.
            CloudRecorderHarness.ScenarioDef(
                name: "delete",
                seed: CloudRecorderHarness.readySessionSeed(
                    userId: "2001107",
                    displayName: "Cloud User 7",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "local_conversations": .array([
                            localConv(id: "3001171", name: "Alice", previewText: "Photo", previewTsMs: baseTs + 2000),
                            localConv(id: "g5001172", isGroup: true, name: "Group C", members: 3, previewText: "doc.pdf", previewTsMs: baseTs + 3000),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "del_1", convId: "3001171", clientId: "cli_del_1", senderId: "3001171", text: "[Hình ảnh]",
                                kind: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/d1.jpg"), "width": .int(100), "height": .int(100)]),
                                kindTag: "photo", tsMs: baseTs + 2000
                            ),
                            storedMsg(
                                id: "del_keep", convId: "3001171", clientId: "cli_del_keep", senderId: "3001171", text: "[Tin nhắn thoại]",
                                kind: .object(["type": .string("voice"), "url": .string("https://cdn.example.invalid/dk.m4a"), "duration": .int(3)]),
                                kindTag: "voice", tsMs: baseTs + 1000
                            ),
                            storedMsg(
                                id: "del_2", convId: "g5001172", clientId: "cli_del_2", senderId: "3001179", text: "doc.pdf",
                                kind: .object(["type": .string("file"), "name": .string("doc.pdf"), "size": .int(85_000), "url": .string("https://cdn.example.invalid/d2.pdf")]),
                                kindTag: "file", tsMs: baseTs + 3000
                            ),
                        ]),
                    ]
                ),
                server: [
                    CloudRecorderHarness.loginInfoScript(uid: "2001107", displayName: "Cloud User 7"),
                    CloudRecorderHarness.profileMeScript(uid: "2001107", displayName: "Cloud User 7"),
                    CloudRecorderHarness.httpScript(
                        path: "/api/message/delete",
                        method: "POST",
                        status: 200,
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                    CloudRecorderHarness.httpScript(
                        path: "/api/group/deletemsg",
                        method: "POST",
                        status: 500,
                        json: .object(["error_code": .int(500), "error_message": .string("group delete failed")])
                    ),
                    // Refresh inside cloudDelete (1st delete) and 2nd delete
                    cloudErrScript(path: "/api/getCloudViewerKey"),
                    cloudErrScript(path: "/api/getCloudViewerKey"),
                    cloudErrScript(path: "/api/getCloudViewerKey"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("refresh_cloud")]),
                    .object(["snapshot": .string("before_delete")]),
                    .object([
                        "cmd": .string("cloud_delete"),
                        "args": .object([
                            "keys": .array([
                                .string("3001171|del_1|photo"),
                                .string("g5001172|del_2|file"),
                                .string("badkey"),
                                .string("3001171|missing_id|photo"),
                            ]),
                        ]),
                    ]),
                    .object(["snapshot": .string("after_delete")]),
                    .object([
                        "cmd": .string("cloud_delete"),
                        "args": .object(["keys": .array([.string("badkey")])]),
                    ]),
                ]
            ),

            // 8. offload_and_reset:
            // Offload refused with recorded Vietnamese message; reset_cloud clears CloudState.
            CloudRecorderHarness.ScenarioDef(
                name: "offload_and_reset",
                seed: CloudRecorderHarness.readySessionSeed(
                    userId: "2001108",
                    displayName: "Cloud User 8",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "local_conversations": .array([
                            localConv(id: "3001181", name: "Alice"),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "or_1", convId: "3001181", senderId: "3001181", text: "[Hình ảnh]",
                                kind: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/or1.jpg"), "width": .int(200), "height": .int(200)]),
                                kindTag: "photo", tsMs: baseTs + 1000
                            ),
                        ]),
                    ]
                ),
                server: [
                    CloudRecorderHarness.loginInfoScript(uid: "2001108", displayName: "Cloud User 8"),
                    CloudRecorderHarness.profileMeScript(uid: "2001108", displayName: "Cloud User 8"),
                    cloudOkScript(
                        path: "/api/getCloudViewerKey",
                        data: .object(["viewer_key": .string("vk_8"), "enk": .string("MDEyMzQ1Njc4OWFiY2RlZg==")])
                    ),
                    cloudOkScript(
                        path: "/cloudmedia/info/pc/v1/usage-mycloud",
                        data: .object(["plan": .int(0), "quota": .int(107_374_182_400), "usage": .int(150_000)])
                    ),
                    cloudOkScript(
                        path: "/cloudmedia/info/pc/v2/usage",
                        data: .object([
                            "plan": .int(0),
                            "quota": .int(107_374_182_400),
                            "usage": .int(150_000),
                            "service_usage": .object(["cloud_media": .int(150_000), "message_backup": .int(0), "my_cloud": .int(0)]),
                        ])
                    ),
                    cloudOkScript(
                        path: "/cloudmedia/info/pc/v1/cloud-settings",
                        data: .object(["opt_in": .int(7), "enable_offload": .int(1), "cloud_media_file_size_limit": .int(1_073_741_824)])
                    ),
                    cloudOkScript(
                        path: "/zalocloud/cloudinfopcweb/v1/info",
                        data: .object(["package_name": .string("zCloud Pro")])
                    ),
                    cloudOkScript(path: "/cloudmedia/info/pc/v1/family-usage", data: .object(["members": .array([])])),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("refresh_cloud")]),
                    .object(["snapshot": .string("before_offload")]),
                    .object(["cmd": .string("cloud_set_offload"), "args": .object(["enabled": .bool(true)])]),
                    .object(["snapshot": .string("after_offload")]),
                    .object(["cmd": .string("reset_cloud")]),
                ]
            ),
        ]
    }
}

// MARK: - CloudRecorderHarness

enum CloudRecorderHarness {
    struct ScenarioDef {
        let name: String
        let seed: CaseJSON
        let server: [CaseJSON]
        let steps: [CaseJSON]
        let slow: Bool

        init(
            name: String,
            seed: CaseJSON,
            server: [CaseJSON],
            steps: [CaseJSON],
            slow: Bool = false
        ) {
            self.name = name
            self.seed = seed
            self.server = server
            self.steps = steps
            self.slow = slow
        }
    }

    enum RecorderError: Error, CustomStringConvertible {
        case timeout(scenario: String, detail: String)
        case unscriptedRequest(scenario: String, detail: String)
        case invalidStep(scenario: String, detail: String)
        case invalidSeed(scenario: String, detail: String)

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
            }
        }
    }

    static func readySessionSeed(
        userId: String,
        displayName: String = "Cloud User",
        suppress: [String] = ["ws", "long_poll"],
        extras: [String: CaseJSON] = [:]
    ) -> CaseJSON {
        var mergedExtras: [String: CaseJSON] = [
            "next_client_id": .int(6_000_000_000_100),
        ]
        for (k, v) in extras {
            mergedExtras[k] = v
        }
        return MessageRecorderHarness.readySessionSeed(
            userId: userId,
            displayName: displayName,
            suppress: suppress,
            extras: mergedExtras
        )
    }

    static func signedOutSeed(suppress: [String] = ["ws", "long_poll"]) -> CaseJSON {
        .object([
            "domains": defaultFakeDomainsJSON(),
            "ws_auth": .string("manual"),
            "suppress": .array(suppress.map(CaseJSON.string)),
            "next_client_id": .int(6_000_000_000_100),
            "prefs": .object([:]),
        ])
    }

    static func loginInfoScript(
        uid: String,
        zpwSek: String = "saved.200.a0.sek_u11",
        displayName: String = "Cloud User",
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
        displayName: String = "Cloud User",
        avatar: String = "https://cdn.example.invalid/me.jpg",
        phone: String = "+84900000100"
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
        json: CaseJSON,
        hold: Bool = false,
        repeatResponse: Bool = false
    ) -> CaseJSON {
        var obj: [String: CaseJSON] = [
            "kind": .string("http"),
            "path": .string(path),
            "method": .string(method),
            "response": .object([
                "status": .int(status),
                "json": json,
            ]),
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
            .appendingPathComponent("olaz-cloud-recorder-\(scenario.name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let storage = RecorderStorageIsolation(prefix: "olaz.cloud-recorder")
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

        let resolveMediaQueue = scenario.seed["host_results"]?["resolve_media"]?.arrayValue ?? []
        var resolveMediaIndex = 0
        if scenario.seed["host_results"]?["resolve_media"] != nil {
            engine.resolveMediaHostHandler = { _ in
                guard resolveMediaIndex < resolveMediaQueue.count else {
                    return .unavailable
                }
                let item = resolveMediaQueue[resolveMediaIndex]
                resolveMediaIndex += 1
                switch item["state"]?.stringValue ?? "unavailable" {
                case "file", "ok":
                    if let path = item["path"]?.stringValue, path.hasPrefix("/") {
                        return .file(URL(fileURLWithPath: path))
                    }
                    return .unavailable
                case "expired":
                    return .expired
                case "unsupported":
                    return .unsupported
                default:
                    return .unavailable
                }
            }
        }

        let resolveFileQueue = scenario.seed["host_results"]?["resolve_file"]?.arrayValue ?? []
        var resolveFileIndex = 0
        if scenario.seed["host_results"]?["resolve_file"] != nil {
            engine.resolveFileHostHandler = { _ in
                guard resolveFileIndex < resolveFileQueue.count else {
                    return .failed("No scripted resolve_file result")
                }
                let item = resolveFileQueue[resolveFileIndex]
                resolveFileIndex += 1
                switch item["state"]?.stringValue ?? "failed" {
                case "ready":
                    if let path = item["path"]?.stringValue, !path.isEmpty {
                        return .ready(URL(fileURLWithPath: path))
                    }
                    return .failed("Missing staged path")
                case "expired":
                    return .expired
                default:
                    return .failed(item["message"]?.stringValue ?? "Không tải được tệp.")
                }
            }
        }

        var bootstrapLogs: [String] = []
        var sendLogs: [String] = []
        var actionLogs: [String] = []
        var lastSendResult: Bool?
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
        var allowRefreshCloud = false
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
                 "apply_remote_reaction", "apply_remote_recall", "apply_remote_delete",
                 "resolve_media", "resolve_file":
                return true
            case "refresh_cloud":
                return allowRefreshCloud
            case "start_ws":
                return !suppressedTransports.contains("ws")
            case "start_long_poll":
                return !suppressedTransports.contains("long_poll")
            default:
                return false
            }
        }

        let transitionRecorder = CloudTransitionRecorder(scenarioName: scenario.name) {
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

        func findMessageInMemory(convId: String, msgId: String) -> ChatMessage? {
            engine.messages[convId]?.first { $0.id == msgId || $0.clientId == msgId }
        }

        func resolveMessage(convId: String, msgId: String) async -> ChatMessage? {
            if let hit = findMessageInMemory(convId: convId, msgId: msgId) {
                return hit
            }
            if let row = try? await engine.sqliteStore?.decodedMessage(convId: convId, idOrClientId: msgId) {
                return row.message
            }
            return nil
        }

        func decodeStepMessage(_ msgJSON: CaseJSON, fallbackConvId: String) -> ChatMessage? {
            let sub = substituteRuntimeURLs(msgJSON)
            guard var dict = sub.toFoundation() as? [String: Any] else { return nil }
            if dict["conversationId"] == nil, let cid = dict["conv_id"] { dict["conversationId"] = cid }
            if dict["clientId"] == nil, let cid = dict["client_id"] { dict["clientId"] = cid }
            if dict["senderId"] == nil, let sid = dict["sender_id"] { dict["senderId"] = sid }
            if dict["senderName"] == nil, let sname = dict["sender_name"] { dict["senderName"] = sname }
            if dict["senderAvatar"] == nil, let savt = dict["sender_avatar"] { dict["senderAvatar"] = savt }
            if dict["isMine"] == nil, let mine = dict["is_mine"] { dict["isMine"] = mine }
            if dict["isE2EE"] == nil, let e2ee = dict["is_e2ee"] { dict["isE2EE"] = e2ee }
            if dict["date"] == nil, let dms = dict["date_ms"] { dict["date"] = dms }
            if let kindStr = dict["kind"] as? String {
                dict["kind"] = ["type": kindStr]
            }
            return ChatMessage(json: dict, fallbackConversation: fallbackConvId)
        }

        do {
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
                    case "log_out":
                        _ = await engine.bootTask?.value
                        engine.logOut()
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
                    case "send_text":
                        _ = await engine.bootTask?.value
                        let id = args?["id"]?.stringValue ?? ""
                        let text = args?["text"]?.stringValue ?? ""
                        let quoteId = args?["quote_id"]?.stringValue
                        let urgency = Int(args?["urgency"]?.int64Value ?? 0)
                        let isAsync = args?["async"]?.boolValue ?? false
                        if isAsync {
                            let heldBefore = server.heldHTTPCount()
                            var completed = false
                            let task = Task { @MainActor in
                                let ok = await engine.sendText(text, to: id, quoting: quoteId, urgency: urgency)
                                completed = true
                                notifySignal()
                                return ok
                            }
                            engine.activeSendTask = task
                            try await waitForCondition(timeoutMs: 3000, description: "held HTTP request for send_text") {
                                completed || server.heldHTTPCount() > heldBefore
                            }
                            if completed {
                                lastSendResult = await task.value
                                engine.activeSendTask = nil
                            } else {
                                keepNowMsForAsync = true
                            }
                        } else {
                            lastSendResult = await engine.sendText(text, to: id, quoting: quoteId, urgency: urgency)
                            _ = await engine.persistConversationsTask?.value
                        }
                    case "await_send":
                        if let task = engine.activeSendTask {
                            lastSendResult = await task.value
                            engine.activeSendTask = nil
                        }
                        _ = await engine.persistConversationsTask?.value
                        engine.nowMs = { Int64(Date().timeIntervalSince1970 * 1000) }
                    case "ensure_loaded":
                        _ = await engine.bootTask?.value
                        let convId = args?["conv_id"]?.stringValue ?? ""
                        var target: ChatMessage?
                        if let msgObj = args?["message"] {
                            target = decodeStepMessage(msgObj, fallbackConvId: convId)
                        } else if let msgId = args?["msg_id"]?.stringValue {
                            target = await resolveMessage(convId: convId, msgId: msgId)
                        }
                        guard let msg = target else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "ensure_loaded could not resolve target message")
                        }
                        let loaded = await engine.ensureMessageLoaded(msg, in: convId)
                        await engine.settleForRecording()
                        results[String(stepIndex)] = .bool(loaded)
                    case "refresh_cloud":
                        _ = await engine.bootTask?.value
                        allowRefreshCloud = true
                        defer { allowRefreshCloud = false }
                        engine.refreshCloud()
                        await engine.awaitCloudTasksForRecording()
                    case "cloud_list":
                        _ = await engine.bootTask?.value
                        let convId = args?["conv_id"]?.stringValue
                        let kind = args?["kind"]?.stringValue.flatMap(CloudItemKind.init(rawValue:))
                        let sortBySize = args?["sort_by_size"]?.boolValue ?? false
                        let ascending = args?["ascending"]?.boolValue ?? false
                        let offset = Int(args?["offset"]?.int64Value ?? 0)
                        let limit = Int(args?["limit"]?.int64Value ?? 60)
                        let page = await engine.cloudList(
                            conversationId: convId,
                            kind: kind,
                            sortBySize: sortBySize,
                            ascending: ascending,
                            offset: offset,
                            limit: limit
                        )
                        results[String(stepIndex)] = CloudSnapshot.encodePage(page)
                    case "cloud_fetch":
                        _ = await engine.bootTask?.value
                        let key = args?["key"]?.stringValue ?? ""
                        let fetch = await engine.cloudFetch(key)
                        results[String(stepIndex)] = normalizeRecordedURLs(CloudSnapshot.encodeFetch(fetch))
                    case "cloud_thumbnail":
                        _ = await engine.bootTask?.value
                        let key = args?["key"]?.stringValue ?? ""
                        let thumb = await engine.cloudThumbnail(for: key)
                        results[String(stepIndex)] = CloudSnapshot.encodeMediaResolution(thumb)
                    case "cloud_delete":
                        _ = await engine.bootTask?.value
                        let keys = args?["keys"]?.arrayValue?.compactMap(\.stringValue) ?? []
                        let res = await engine.cloudDelete(keys)
                        await engine.settleForRecording()
                        _ = await engine.persistConversationsTask?.value
                        results[String(stepIndex)] = CloudSnapshot.encodeActionResult(res)
                    case "cloud_set_offload":
                        _ = await engine.bootTask?.value
                        let enabled = args?["enabled"]?.boolValue ?? false
                        let res = await engine.cloudSetOffload(enabled)
                        results[String(stepIndex)] = CloudSnapshot.encodeActionResult(res)
                    case "reset_cloud":
                        _ = await engine.bootTask?.value
                        engine.resetCloud()
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
                    let snap = await CloudSnapshot.capture(
                        from: engine,
                        bootstrapLogs: bootstrapLogs,
                        lastSendResult: lastSendResult,
                        sendLogs: sendLogs,
                        actionLogs: actionLogs,
                        results: results
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
            await engine.awaitMessageActionTasksForRecording()
            await engine.awaitCloudTasksForRecording()
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
                await CloudSnapshot.capture(
                    from: engine,
                    bootstrapLogs: bootstrapLogs,
                    lastSendResult: lastSendResult,
                    sendLogs: sendLogs,
                    actionLogs: actionLogs,
                    results: results
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
                        "kind": .object(["type": .string(row["kind_tag"]?.stringValue ?? "text")]),
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

private final class CloudTransitionRecorder {
    private let scenarioName: String
    private let captureState: @MainActor () -> CaseJSON
    private var history: [CaseJSON] = []
    private var lastSerialized: String?
    private var searchCursor = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(scenarioName: String, captureState: @escaping @MainActor () -> CaseJSON) {
        self.scenarioName = scenarioName
        self.captureState = captureState
    }

    @MainActor
    func recordTransition() {
        let snap = captureState()
        let key = snap.canonicalString()
        if key == lastSerialized { return }
        lastSerialized = key
        history.append(snap)
        let pending = waiters
        waiters.removeAll()
        for cont in pending.values { cont.resume() }
    }

    @MainActor
    func advanceSearchToLatestSyncState() {
        recordTransition()
        searchCursor = max(0, history.count - 1)
    }

    @MainActor
    func cancelWaiters() {
        let pending = waiters
        waiters.removeAll()
        for cont in pending.values { cont.resume() }
    }

    @MainActor
    func awaitPredicate(_ pred: CaseJSON, timeoutMs: Int) async throws {
        let targetKind = pred["phase"]?.stringValue
        let targetStep = pred["step"]?.stringValue

        func matches(_ state: CaseJSON) -> Bool {
            guard let phase = state["phase"],
                  let kind = phase["kind"]?.stringValue else { return false }
            if let targetKind, kind != targetKind { return false }
            if let targetStep, phase["step"]?.stringValue != targetStep { return false }
            return true
        }

        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while true {
            recordTransition()
            if let idx = (searchCursor..<history.count).first(where: { matches(history[$0]) }) {
                searchCursor = idx + 1
                return
            }
            let remaining = deadline - ContinuousClock.now
            if remaining <= .zero {
                throw CloudRecorderHarness.RecorderError.timeout(
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
