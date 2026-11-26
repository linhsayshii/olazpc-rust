import Foundation
import XCTest
@testable import Olaz

final class MediaRecorderTests: XCTestCase {
    func testMediaScenarios() async throws {
        try await MediaRecorderHarness.runDomainSuite(
            domain: "media",
            scenarios: Self.mediaScenarios()
        )
    }

    // MARK: - Helpers

    static let onePixelPNG = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
        0x42, 0x60, 0x82,
    ])
    private static let onePixelPNGB64 = onePixelPNG.base64EncodedString()

    // Minimal ISO BMFF `ftypmp42` header recognized by `CloudContainer` and `VideoPoster.isVideo`.
    private static let minimalMP4 = Data([
        0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70,
        0x6D, 0x70, 0x34, 0x32, 0x00, 0x00, 0x00, 0x00,
        0x6D, 0x70, 0x34, 0x32, 0x69, 0x73, 0x6F, 0x6D,
    ])
    private static let minimalMP4B64 = minimalMP4.base64EncodedString()

    private static func storedMsg(
        id: String,
        convId: String,
        clientId: String? = nil,
        senderId: String,
        senderName: String = "Alice",
        senderAvatar: String = "https://cdn.example.invalid/a.jpg",
        isMine: Bool = false,
        text: String,
        kind: CaseJSON,
        kindTag: String,
        fallbackURLs: [String] = [],
        tsMs: Int64,
        status: String = "sent",
        isE2EE: Bool = false
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
            "kind": kind,
        ]
        if !fallbackURLs.isEmpty {
            rawObj["fallbacks"] = .array(fallbackURLs.map(CaseJSON.string))
        }

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

    private static func fileSpec(
        name: String,
        type: String? = nil,
        size: Int64 = 1024,
        readable: Bool = true,
        isDir: Bool = false,
        exists: Bool = true
    ) -> CaseJSON {
        var obj: [String: CaseJSON] = [
            "name": .string(name),
            "size": .int(size),
            "readable": .bool(readable),
            "is_dir": .bool(isDir),
            "exists": .bool(exists),
        ]
        if let type {
            obj["type"] = .string(type)
        }
        return .object(obj)
    }

    // MARK: - Scenarios

    static func mediaScenarios() -> [MediaRecorderHarness.ScenarioDef] {
        let baseTs: Int64 = 1_700_000_000_000

        return [
            // 1. send_media_kinds: image, unreadable file in the middle, video, other file;
            // all fail (generic failure); empty URL list and empty conversation id (.cancelled).
            MediaRecorderHarness.ScenarioDef(
                name: "send_media_kinds",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000101",
                    displayName: "Media User 1",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(5000100000001),
                        "history_freshness": .object(["3000101": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3000101", name: "Media Peer 1", previewText: "Init", previewTsMs: baseTs),
                        ]),
                        "host_results": .object([
                            "image_dimensions": .array([
                                .object(["width": .int(1280), "height": .int(720)]),
                                .object(["width": .int(640), "height": .int(480)]),
                            ]),
                            "video_metadata": .array([
                                .object(["duration_ms": .int(2600), "width": .int(1920), "height": .int(1080), "has_thumb": .bool(true)]),
                            ]),
                            "upload_photo": .array([
                                .object([
                                    "url": .string("https://cdn.example.invalid/p1.jpg"),
                                    "msg_id": .string("9001001"),
                                    "cli_msg_id": .string("5001001"),
                                    "width": .int(1280),
                                    "height": .int(720),
                                ]),
                                .object(["error": .string("upload failed")]),
                            ]),
                            "upload_video": .array([
                                .object([
                                    "url": .string("https://cdn.example.invalid/v1.mp4"),
                                    "thumb_url": .string("https://cdn.example.invalid/v1_thumb.jpg"),
                                    "msg_id": .string("9001002"),
                                    "cli_msg_id": .string("5001002"),
                                    "width": .int(1920),
                                    "height": .int(1080),
                                    "duration_ms": .int(2600),
                                ]),
                            ]),
                            "upload_file": .array([
                                .object([
                                    "url": .string("https://cdn.example.invalid/notes.pdf"),
                                    "msg_id": .string("9001003"),
                                    "cli_msg_id": .string("5001003"),
                                ]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000101", displayName: "Media User 1"),
                    MessageRecorderHarness.profileMeScript(uid: "2000101", displayName: "Media User 1"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000101")])]),
                    .object([
                        "cmd": .string("send_media"),
                        "now_ms": .int(baseTs + 10_000),
                        "args": .object([
                            "conv_id": .string("3000101"),
                            "files": .array([
                                fileSpec(name: "photo.jpg", type: "image", size: 2048, readable: true),
                                fileSpec(name: "broken.png", type: "image", size: 512, readable: false),
                                fileSpec(name: "clip.mp4", type: "video", size: 8192, readable: true),
                                fileSpec(name: "notes.pdf", type: "file", size: 4096, readable: true),
                            ]),
                        ]),
                    ]),
                    .object(["snapshot": .string("after_mixed_send")]),
                    .object([
                        "cmd": .string("send_media"),
                        "now_ms": .int(baseTs + 20_000),
                        "args": .object([
                            "conv_id": .string("3000101"),
                            "files": .array([
                                fileSpec(name: "unreadable.jpg", type: "image", size: 100, readable: false),
                                fileSpec(name: "fail.jpg", type: "image", size: 100, readable: true),
                            ]),
                        ]),
                    ]),
                    .object([
                        "cmd": .string("send_media"),
                        "now_ms": .int(baseTs + 30_000),
                        "args": .object([
                            "conv_id": .string("3000101"),
                            "files": .array([]),
                        ]),
                    ]),
                    .object([
                        "cmd": .string("send_media"),
                        "now_ms": .int(baseTs + 40_000),
                        "args": .object([
                            "conv_id": .string(""),
                            "files": .array([
                                fileSpec(name: "a.jpg", type: "image", size: 10, readable: true),
                            ]),
                        ]),
                    ]),
                ]
            ),

            // 2. send_files_validation: folder, missing, unreadable, empty, over 200 MB plan limit,
            // plus empty list and empty conversation id (.cancelled).
            MediaRecorderHarness.ScenarioDef(
                name: "send_files_validation",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000201",
                    displayName: "Media User 2",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(5000200000001),
                        "history_freshness": .object(["3000201": .string("up_to_date")]),
                        "cloud_plan": .object([
                            "kind": .string("paid"),
                            "name": .string("zCloud Pro"),
                            "file_limit": .int(200 * 1_048_576),
                        ]),
                        "local_conversations": .array([
                            localConv(id: "3000201", name: "Validation Peer"),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000201", displayName: "Media User 2"),
                    MessageRecorderHarness.profileMeScript(uid: "2000201", displayName: "Media User 2"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000201")])]),
                    .object([
                        "cmd": .string("send_files"),
                        "now_ms": .int(baseTs + 1_000),
                        "args": .object([
                            "conv_id": .string("3000201"),
                            "files": .array([fileSpec(name: "docs", size: 0, readable: false, isDir: true, exists: true)]),
                        ]),
                    ]),
                    .object([
                        "cmd": .string("send_files"),
                        "now_ms": .int(baseTs + 2_000),
                        "args": .object([
                            "conv_id": .string("3000201"),
                            "files": .array([fileSpec(name: "missing.txt", size: 0, readable: false, isDir: false, exists: false)]),
                        ]),
                    ]),
                    .object([
                        "cmd": .string("send_files"),
                        "now_ms": .int(baseTs + 3_000),
                        "args": .object([
                            "conv_id": .string("3000201"),
                            "files": .array([fileSpec(name: "locked.txt", size: 100, readable: false, isDir: false, exists: true)]),
                        ]),
                    ]),
                    .object([
                        "cmd": .string("send_files"),
                        "now_ms": .int(baseTs + 4_000),
                        "args": .object([
                            "conv_id": .string("3000201"),
                            "files": .array([fileSpec(name: "empty.bin", size: 0, readable: true, isDir: false, exists: true)]),
                        ]),
                    ]),
                    .object([
                        "cmd": .string("send_files"),
                        "now_ms": .int(baseTs + 5_000),
                        "args": .object([
                            "conv_id": .string("3000201"),
                            "files": .array([fileSpec(name: "huge.bin", size: 210 * 1_048_576, readable: true, isDir: false, exists: true)]),
                        ]),
                    ]),
                    .object([
                        "cmd": .string("send_files"),
                        "now_ms": .int(baseTs + 6_000),
                        "args": .object(["conv_id": .string("3000201"), "files": .array([])]),
                    ]),
                    .object([
                        "cmd": .string("send_files"),
                        "now_ms": .int(baseTs + 7_000),
                        "args": .object([
                            "conv_id": .string(""),
                            "files": .array([fileSpec(name: "a.txt", size: 10)]),
                        ]),
                    ]),
                ]
            ),

            // 2b. send_files_floor: 100 MB floor applies when cloud.plan.fileLimit is lower (50 MB).
            MediaRecorderHarness.ScenarioDef(
                name: "send_files_floor",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000202",
                    displayName: "Media User 2b",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(5000250000001),
                        "history_freshness": .object(["3000202": .string("up_to_date")]),
                        "cloud_plan": .object([
                            "kind": .string("free"),
                            "name": .string("Cloud của tôi"),
                            "file_limit": .int(50 * 1_048_576),
                        ]),
                        "local_conversations": .array([
                            localConv(id: "3000202", name: "Floor Peer"),
                        ]),
                        "host_results": .object([
                            "upload_file": .array([
                                .object([
                                    "url": .string("https://cdn.example.invalid/under_floor.bin"),
                                    "msg_id": .string("9002501"),
                                    "cli_msg_id": .string("5000250000001"),
                                ]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000202", displayName: "Media User 2b"),
                    MessageRecorderHarness.profileMeScript(uid: "2000202", displayName: "Media User 2b"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000202")])]),
                    .object([
                        "cmd": .string("send_files"),
                        "now_ms": .int(baseTs + 10_000),
                        "args": .object([
                            "conv_id": .string("3000202"),
                            "files": .array([fileSpec(name: "under_floor.bin", size: 80 * 1_048_576)]),
                        ]),
                    ]),
                    .object([
                        "cmd": .string("send_files"),
                        "now_ms": .int(baseTs + 20_000),
                        "args": .object([
                            "conv_id": .string("3000202"),
                            "files": .array([fileSpec(name: "over_floor.bin", size: 105 * 1_048_576)]),
                        ]),
                    ]),
                ]
            ),

            // 3. send_files_paths: plain 1-1, group, self (menu flags); E2EE 1-1;
            // session errors (msg, -108, -104, 401, other code), network error, other error (optimistic removed);
            // two files where one fails (show_card + .done).
            MediaRecorderHarness.ScenarioDef(
                name: "send_files_paths",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000301",
                    displayName: "Media User 3",
                    send2MeId: "9200301",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(5000300000001),
                        "e2ee_threads": .array([.string("3000302")]),
                        "history_freshness": .object([
                            "3000301": .string("up_to_date"),
                            "3000302": .string("up_to_date"),
                            "g500301": .string("up_to_date"),
                            "9200301": .string("up_to_date"),
                        ]),
                        "local_conversations": .array([
                            localConv(id: "3000301", name: "Plain Peer"),
                            localConv(id: "3000302", name: "E2EE Peer"),
                            localConv(id: "g500301", isGroup: true, name: "File Group", members: 3),
                            localConv(id: "9200301", name: "Cloud của tôi"),
                        ]),
                        "host_results": .object([
                            "upload_file": .array([
                                .object(["url": .string("https://cdn.example.invalid/p.pdf"), "msg_id": .string("9003001"), "cli_msg_id": .string("5000300000001")]),
                                .object(["url": .string("https://cdn.example.invalid/g.pdf"), "msg_id": .string("9003002"), "cli_msg_id": .string("5000300000002")]),
                                .object(["url": .string("https://cdn.example.invalid/s.pdf"), "msg_id": .string("9003003"), "cli_msg_id": .string("5000300000003")]),
                                .object(["url": .string("https://cdn.example.invalid/e.pdf?e2esession=abc"), "msg_id": .string("9003004"), "cli_msg_id": .string("5000300000004")]),
                                .object(["session_error": .object(["code": .int(400), "message": .string("Custom upload error")])]),
                                .object(["session_error": .object(["code": .int(-108), "message": .string("")])]),
                                .object(["session_error": .object(["code": .int(-104), "message": .string("")])]),
                                .object(["session_error": .object(["code": .int(401), "message": .string("")])]),
                                .object(["session_error": .object(["code": .int(503), "message": .string("")])]),
                                .object(["url_error": .int(-1009)]),
                                .object(["error": .string("disk exploded")]),
                                .object(["url": .string("https://cdn.example.invalid/ok1.pdf"), "msg_id": .string("9003012"), "cli_msg_id": .string("5000300000012")]),
                                .object(["session_error": .object(["code": .int(500), "message": .string("Second file rejected")])]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000301", displayName: "Media User 3", send2MeId: "9200301"),
                    MessageRecorderHarness.profileMeScript(uid: "2000301", displayName: "Media User 3"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000301")])]),
                    .object([
                        "cmd": .string("send_files"),
                        "now_ms": .int(baseTs + 1_000),
                        "args": .object(["conv_id": .string("3000301"), "files": .array([fileSpec(name: "plain.pdf", size: 100)])]),
                    ]),
                    .object([
                        "cmd": .string("send_files"),
                        "now_ms": .int(baseTs + 2_000),
                        "args": .object(["conv_id": .string("g500301"), "files": .array([fileSpec(name: "group.pdf", size: 200)])]),
                    ]),
                    .object([
                        "cmd": .string("send_files"),
                        "now_ms": .int(baseTs + 3_000),
                        "args": .object(["conv_id": .string("9200301"), "files": .array([fileSpec(name: "self.pdf", size: 300)])]),
                    ]),
                    .object([
                        "cmd": .string("send_files"),
                        "now_ms": .int(baseTs + 4_000),
                        "args": .object(["conv_id": .string("3000302"), "files": .array([fileSpec(name: "secret.pdf", size: 400)])]),
                    ]),
                    .object(["snapshot": .string("after_success_paths")]),
                    .object([
                        "cmd": .string("send_files"),
                        "now_ms": .int(baseTs + 5_000),
                        "args": .object(["conv_id": .string("3000301"), "files": .array([fileSpec(name: "err_msg.pdf", size: 50)])]),
                    ]),
                    .object([
                        "cmd": .string("send_files"),
                        "now_ms": .int(baseTs + 6_000),
                        "args": .object(["conv_id": .string("3000301"), "files": .array([fileSpec(name: "err108.pdf", size: 50)])]),
                    ]),
                    .object([
                        "cmd": .string("send_files"),
                        "now_ms": .int(baseTs + 7_000),
                        "args": .object(["conv_id": .string("3000301"), "files": .array([fileSpec(name: "err104.pdf", size: 50)])]),
                    ]),
                    .object([
                        "cmd": .string("send_files"),
                        "now_ms": .int(baseTs + 8_000),
                        "args": .object(["conv_id": .string("3000301"), "files": .array([fileSpec(name: "err401.pdf", size: 50)])]),
                    ]),
                    .object([
                        "cmd": .string("send_files"),
                        "now_ms": .int(baseTs + 9_000),
                        "args": .object(["conv_id": .string("3000301"), "files": .array([fileSpec(name: "err503.pdf", size: 50)])]),
                    ]),
                    .object([
                        "cmd": .string("send_files"),
                        "now_ms": .int(baseTs + 10_000),
                        "args": .object(["conv_id": .string("3000301"), "files": .array([fileSpec(name: "neterr.pdf", size: 50)])]),
                    ]),
                    .object([
                        "cmd": .string("send_files"),
                        "now_ms": .int(baseTs + 11_000),
                        "args": .object(["conv_id": .string("3000301"), "files": .array([fileSpec(name: "other.pdf", size: 50)])]),
                    ]),
                    .object(["snapshot": .string("after_all_failures")]),
                    .object([
                        "cmd": .string("send_files"),
                        "now_ms": .int(baseTs + 12_000),
                        "args": .object([
                            "conv_id": .string("3000301"),
                            "files": .array([
                                fileSpec(name: "ok1.pdf", size: 60),
                                fileSpec(name: "fail2.pdf", size: 70),
                            ]),
                        ]),
                    ]),
                ]
            ),

            // 4. record_uploaded: sent row replaces optimistic row by client id;
            // conversation preview updates; unread count does not change. (Also tests ws_auth: "manual".)
            MediaRecorderHarness.ScenarioDef(
                name: "record_uploaded",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000401",
                    displayName: "Media User 4",
                    suppress: ["long_poll"],
                    wsAuthManual: true,
                    extras: [
                        "next_client_id": .int(5000400000001),
                        "history_freshness": .object(["3000401": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3000401", name: "Upload Peer 4", unread: 3, previewText: "Previous msg", previewTsMs: baseTs),
                        ]),
                        "host_results": .object([
                            "upload_file": .array([
                                .object([
                                    "hold": .bool(true),
                                    "url": .string("https://cdn.example.invalid/report.pdf"),
                                    "msg_id": .string("9004001"),
                                    "cli_msg_id": .string("5000400000001"),
                                ]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000401", displayName: "Media User 4"),
                    MessageRecorderHarness.profileMeScript(uid: "2000401", displayName: "Media User 4"),
                    MessageRecorderHarness.wsScript(),
                    MessageRecorderHarness.wsFrameScript(cmd: 1, payload: .object(["error_code": .int(0)])),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("start_bootstrap"), "timeout_ms": .int(5000)]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("e2ee_connected"), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000401")])]),
                    .object([
                        "cmd": .string("send_files"),
                        "now_ms": .int(baseTs + 50_000),
                        "args": .object([
                            "conv_id": .string("3000401"),
                            "async": .bool(true),
                            "files": .array([fileSpec(name: "report.pdf", size: 1234)]),
                        ]),
                    ]),
                    .object(["await_host": .string("upload_file"), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("optimistic")]),
                    .object(["upload_release": .int(1)]),
                    .object(["cmd": .string("await_send")]),
                    .object(["snapshot": .string("after_record")]),
                ]
            ),

            // 5. resolve_media_candidates: each kind pair, mismatch -> .unsupported,
            // duplicate fallback URLs, no URL -> .unavailable, message only in SQLite,
            // message only in another conversation.
            MediaRecorderHarness.ScenarioDef(
                name: "resolve_media_candidates",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000501",
                    displayName: "Media User 5",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "history_freshness": .object([
                            "3000501": .string("up_to_date"),
                            "3000503": .string("up_to_date"),
                        ]),
                        "local_conversations": .array([
                            localConv(id: "3000501", name: "Resolve Peer 1"),
                            localConv(id: "3000502", name: "SQLite Only Peer"),
                            localConv(id: "3000503", name: "Other Conv Peer"),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "m_photo", convId: "3000501", senderId: "3000501", text: "",
                                kind: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/p.png"), "width": .int(1), "height": .int(1)]),
                                kindTag: "photo", tsMs: baseTs + 1000
                            ),
                            storedMsg(
                                id: "m_video", convId: "3000501", senderId: "3000501", text: "",
                                kind: .object(["type": .string("video"), "thumbnail": .string("https://cdn.example.invalid/vt.png"), "duration": .int(5), "url": .string("https://cdn.example.invalid/v.mp4")]),
                                kindTag: "video", tsMs: baseTs + 2000
                            ),
                            storedMsg(
                                id: "m_gif", convId: "3000501", senderId: "3000501", text: "",
                                kind: .object(["type": .string("gif"), "url": .string("https://cdn.example.invalid/g.png")]),
                                kindTag: "gif", tsMs: baseTs + 3000
                            ),
                            storedMsg(
                                id: "m_file", convId: "3000501", senderId: "3000501", text: "f.bin",
                                kind: .object(["type": .string("file"), "name": .string("f.bin"), "size": .int(10), "url": .string("https://cdn.example.invalid/f.bin")]),
                                kindTag: "file", tsMs: baseTs + 4000
                            ),
                            storedMsg(
                                id: "m_dups", convId: "3000501", senderId: "3000501", text: "",
                                kind: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/dup1.png"), "width": .int(1), "height": .int(1)]),
                                kindTag: "photo",
                                fallbackURLs: [
                                    "https://cdn.example.invalid/dup1.png",
                                    "https://cdn.example.invalid/dup2.png",
                                    "https://cdn.example.invalid/dup1.png",
                                    "https://cdn.example.invalid/dup2.png",
                                ],
                                tsMs: baseTs + 5000
                            ),
                            storedMsg(
                                id: "m_nourl", convId: "3000501", senderId: "3000501", text: "",
                                kind: .object(["type": .string("photo"), "url": .string(""), "width": .int(1), "height": .int(1)]),
                                kindTag: "photo", tsMs: baseTs + 6000
                            ),
                            storedMsg(
                                id: "m_sql_photo", convId: "3000502", senderId: "3000502", text: "",
                                kind: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/sql.png"), "width": .int(1), "height": .int(1)]),
                                kindTag: "photo", tsMs: baseTs + 7000
                            ),
                            storedMsg(
                                id: "m_other_conv", convId: "3000503", senderId: "3000503", text: "",
                                kind: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/other.png"), "width": .int(1), "height": .int(1)]),
                                kindTag: "photo", tsMs: baseTs + 8000
                            ),
                        ]),
                        "host_results": .object([
                            "loader_fetch": .object([
                                "https://cdn.example.invalid/p.png": .object(["data_b64": .string(onePixelPNGB64)]),
                                "https://cdn.example.invalid/v.mp4": .object(["data_b64": .string(minimalMP4B64)]),
                                "https://cdn.example.invalid/vt.png": .object(["data_b64": .string(onePixelPNGB64)]),
                                "https://cdn.example.invalid/g.png": .object(["data_b64": .string(onePixelPNGB64)]),
                                "https://cdn.example.invalid/dup1.png": .object(["http_error": .int(500)]),
                                "https://cdn.example.invalid/dup2.png": .object(["data_b64": .string(onePixelPNGB64)]),
                                "https://cdn.example.invalid/sql.png": .object(["data_b64": .string(onePixelPNGB64)]),
                                "https://cdn.example.invalid/other.png": .object(["data_b64": .string(onePixelPNGB64)]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000501", displayName: "Media User 5"),
                    MessageRecorderHarness.profileMeScript(uid: "2000501", displayName: "Media User 5"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000501")])]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000503")])]),
                    // Kind pairs
                    .object(["cmd": .string("resolve_media"), "args": .object(["conv_id": .string("3000501"), "msg_id": .string("m_photo"), "kind": .string("photo")])]),
                    .object(["cmd": .string("resolve_media"), "args": .object(["conv_id": .string("3000501"), "msg_id": .string("m_video"), "kind": .string("video")])]),
                    .object(["cmd": .string("resolve_media"), "args": .object(["conv_id": .string("3000501"), "msg_id": .string("m_video"), "kind": .string("videoThumb")])]),
                    .object(["cmd": .string("resolve_media"), "args": .object(["conv_id": .string("3000501"), "msg_id": .string("m_gif"), "kind": .string("photo")])]),
                    // Kind mismatches -> .unsupported
                    .object(["cmd": .string("resolve_media"), "args": .object(["conv_id": .string("3000501"), "msg_id": .string("m_photo"), "kind": .string("video")])]),
                    .object(["cmd": .string("resolve_media"), "args": .object(["conv_id": .string("3000501"), "msg_id": .string("m_file"), "kind": .string("photo")])]),
                    .object(["cmd": .string("resolve_media"), "args": .object(["conv_id": .string("3000501"), "msg_id": .string("m_photo"), "kind": .string("videoThumb")])]),
                    .object(["cmd": .string("resolve_media"), "args": .object(["conv_id": .string("3000501"), "msg_id": .string("m_gif"), "kind": .string("video")])]),
                    // Duplicate fallbacks (dup1 once -> dup2 once)
                    .object(["cmd": .string("resolve_media"), "args": .object(["conv_id": .string("3000501"), "msg_id": .string("m_dups"), "kind": .string("photo")])]),
                    // No URL -> .unavailable
                    .object(["cmd": .string("resolve_media"), "args": .object(["conv_id": .string("3000501"), "msg_id": .string("m_nourl"), "kind": .string("photo")])]),
                    // SQLite-only conversation 3000502
                    .object(["cmd": .string("resolve_media"), "args": .object(["conv_id": .string("3000502"), "msg_id": .string("m_sql_photo"), "kind": .string("photo")])]),
                    // Message only in another conversation (3000503), queried under 3000501
                    .object(["cmd": .string("resolve_media"), "args": .object(["conv_id": .string("3000501"), "msg_id": .string("m_other_conv"), "kind": .string("photo")])]),
                ]
            ),

            // 6. resolve_media_outcomes: cached hit, cached hit skipped by force;
            // allowed & disallowed file://, ftp:// skipped;
            // all 404 (.expired) + force preserves .expired; 404 then timeout (.unavailable);
            // invalid image body then good fallback; videoThumb whose bytes are a video (poster asked).
            MediaRecorderHarness.ScenarioDef(
                name: "resolve_media_outcomes",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000601",
                    displayName: "Media User 6",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "history_freshness": .object(["3000601": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3000601", name: "Outcomes Peer"),
                        ]),
                        "preseeded_media_cache": .array([
                            .object([
                                "key": .string("3000601|m_cached|photo"),
                                "ext": .string("png"),
                                "data_b64": .string(onePixelPNGB64),
                            ]),
                        ]),
                        "allowed_local_files": .array([
                            .object([
                                "rel_path": .string("allowed/local.png"),
                                "data_b64": .string(onePixelPNGB64),
                            ]),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "m_cached", convId: "3000601", senderId: "3000601", text: "",
                                kind: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/fresh.png"), "width": .int(1), "height": .int(1)]),
                                kindTag: "photo", tsMs: baseTs + 1000
                            ),
                            storedMsg(
                                id: "m_schemes", convId: "3000601", senderId: "3000601", text: "",
                                kind: .object(["type": .string("photo"), "url": .string("ftp://cdn.example.invalid/a.jpg"), "width": .int(1), "height": .int(1)]),
                                kindTag: "photo",
                                fallbackURLs: ["file:///etc/passwd", "file://<data>/allowed/local.png"],
                                tsMs: baseTs + 2000
                            ),
                            storedMsg(
                                id: "m_disallowed", convId: "3000601", senderId: "3000601", text: "",
                                kind: .object(["type": .string("photo"), "url": .string("ftp://cdn.example.invalid/b.jpg"), "width": .int(1), "height": .int(1)]),
                                kindTag: "photo",
                                fallbackURLs: ["file:///etc/passwd"],
                                tsMs: baseTs + 3000
                            ),
                            storedMsg(
                                id: "m_expired", convId: "3000601", senderId: "3000601", text: "",
                                kind: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/gone404.png"), "width": .int(1), "height": .int(1)]),
                                kindTag: "photo",
                                fallbackURLs: ["https://cdn.example.invalid/gone410.png"],
                                tsMs: baseTs + 4000
                            ),
                            storedMsg(
                                id: "m_mixed", convId: "3000601", senderId: "3000601", text: "",
                                kind: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/mixed404.png"), "width": .int(1), "height": .int(1)]),
                                kindTag: "photo",
                                fallbackURLs: ["https://cdn.example.invalid/timeout.png"],
                                tsMs: baseTs + 5000
                            ),
                            storedMsg(
                                id: "m_bad_body", convId: "3000601", senderId: "3000601", text: "",
                                kind: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/corrupt.png"), "width": .int(1), "height": .int(1)]),
                                kindTag: "photo",
                                fallbackURLs: ["https://cdn.example.invalid/good.png"],
                                tsMs: baseTs + 6000
                            ),
                            storedMsg(
                                id: "m_vthumb_mp4", convId: "3000601", senderId: "3000601", text: "",
                                kind: .object(["type": .string("video"), "thumbnail": .string(""), "duration": .int(4), "url": .string("https://cdn.example.invalid/clip_thumb.mp4")]),
                                kindTag: "video", tsMs: baseTs + 7000
                            ),
                        ]),
                        "host_results": .object([
                            "video_poster": .array([
                                .object(["rel_path": .string("MediaCache/poster-vthumb.jpg")]),
                            ]),
                            "loader_fetch": .object([
                                "https://cdn.example.invalid/fresh.png": .object(["data_b64": .string(onePixelPNGB64)]),
                                "https://cdn.example.invalid/gone404.png": .object(["http_error": .int(404)]),
                                "https://cdn.example.invalid/gone410.png": .object(["http_error": .int(410)]),
                                "https://cdn.example.invalid/mixed404.png": .object(["http_error": .int(404)]),
                                "https://cdn.example.invalid/timeout.png": .object(["timed_out": .bool(true)]),
                                "https://cdn.example.invalid/corrupt.png": .object(["data_utf8": .string("not-an-image")]),
                                "https://cdn.example.invalid/good.png": .object(["data_b64": .string(onePixelPNGB64)]),
                                "https://cdn.example.invalid/clip_thumb.mp4": .object(["data_b64": .string(minimalMP4B64)]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000601", displayName: "Media User 6"),
                    MessageRecorderHarness.profileMeScript(uid: "2000601", displayName: "Media User 6"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000601")])]),
                    .object(["cmd": .string("resolve_media"), "args": .object(["conv_id": .string("3000601"), "msg_id": .string("m_cached"), "kind": .string("photo"), "force": .bool(false)])]),
                    .object(["cmd": .string("resolve_media"), "args": .object(["conv_id": .string("3000601"), "msg_id": .string("m_cached"), "kind": .string("photo"), "force": .bool(true)])]),
                    .object(["cmd": .string("resolve_media"), "args": .object(["conv_id": .string("3000601"), "msg_id": .string("m_schemes"), "kind": .string("photo"), "force": .bool(false)])]),
                    .object(["cmd": .string("resolve_media"), "args": .object(["conv_id": .string("3000601"), "msg_id": .string("m_disallowed"), "kind": .string("photo"), "force": .bool(false)])]),
                    .object(["cmd": .string("resolve_media"), "args": .object(["conv_id": .string("3000601"), "msg_id": .string("m_expired"), "kind": .string("photo"), "force": .bool(false)])]),
                    .object(["cmd": .string("resolve_media"), "args": .object(["conv_id": .string("3000601"), "msg_id": .string("m_expired"), "kind": .string("photo"), "force": .bool(true)])]),
                    .object(["cmd": .string("resolve_media"), "args": .object(["conv_id": .string("3000601"), "msg_id": .string("m_mixed"), "kind": .string("photo"), "force": .bool(false)])]),
                    .object(["cmd": .string("resolve_media"), "args": .object(["conv_id": .string("3000601"), "msg_id": .string("m_bad_body"), "kind": .string("photo"), "force": .bool(false)])]),
                    .object(["cmd": .string("resolve_media"), "args": .object(["conv_id": .string("3000601"), "msg_id": .string("m_vthumb_mp4"), "kind": .string("videoThumb"), "force": .bool(false)])]),
                ]
            ),

            // 7. resolve_file: url given; url and name filled from the message;
            // no url (failure text); each loader error text; cancelled.
            MediaRecorderHarness.ScenarioDef(
                name: "resolve_file",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000701",
                    displayName: "Media User 7",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "history_freshness": .object(["3000701": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3000701", name: "File Resolve Peer"),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "m_file_ok", convId: "3000701", senderId: "3000701", text: "Spec:v2.txt",
                                kind: .object(["type": .string("file"), "name": .string("Spec:v2.txt"), "size": .int(120), "url": .string("https://cdn.example.invalid/spec.txt")]),
                                kindTag: "file", tsMs: baseTs + 1000
                            ),
                            storedMsg(
                                id: "m_file_nourl", convId: "3000701", senderId: "3000701", text: "missing.txt",
                                kind: .object(["type": .string("file"), "name": .string("missing.txt"), "size": .int(120), "url": .string("")]),
                                kindTag: "file", tsMs: baseTs + 2000
                            ),
                        ]),
                        "host_results": .object([
                            "loader_fetch": .object([
                                "https://cdn.example.invalid/direct.bin": .object(["data_b64": .string(onePixelPNGB64)]),
                                "https://cdn.example.invalid/spec.txt": .object(["data_utf8": .string("hello spec")]),
                                "https://cdn.example.invalid/e404.pdf": .object(["http_error": .int(404)]),
                                "https://cdn.example.invalid/e410.pdf": .object(["http_error": .int(410)]),
                                "https://cdn.example.invalid/ehost.pdf": .object(["host_not_found": .bool(true)]),
                                "https://cdn.example.invalid/eundec.pdf": .object(["undecodable": .bool(true)]),
                                "https://cdn.example.invalid/etimeout.pdf": .object(["timed_out": .bool(true)]),
                                "https://cdn.example.invalid/elarge.pdf": .object(["too_large": .bool(true)]),
                                "https://cdn.example.invalid/e500.pdf": .object(["http_error": .int(500)]),
                                "https://cdn.example.invalid/ebad.pdf": .object(["bad_url": .bool(true)]),
                                "https://cdn.example.invalid/enet.pdf": .object(["url_error": .int(-1009)]),
                                "https://cdn.example.invalid/ecancel.pdf": .object(["cancelled": .bool(true)]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000701", displayName: "Media User 7"),
                    MessageRecorderHarness.profileMeScript(uid: "2000701", displayName: "Media User 7"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000701")])]),
                    .object(["cmd": .string("resolve_file"), "args": .object(["conv_id": .string(""), "msg_id": .string(""), "name": .string("Report/Q1"), "url": .string("https://cdn.example.invalid/direct.bin"), "force": .bool(false)])]),
                    .object(["cmd": .string("resolve_file"), "args": .object(["conv_id": .string("3000701"), "msg_id": .string("m_file_ok"), "name": .string(""), "force": .bool(true)])]),
                    .object(["cmd": .string("resolve_file"), "args": .object(["conv_id": .string("3000701"), "msg_id": .string("m_file_nourl"), "name": .string("missing.txt"), "force": .bool(false)])]),
                    .object(["cmd": .string("resolve_file"), "args": .object(["name": .string("e404.pdf"), "url": .string("https://cdn.example.invalid/e404.pdf")])]),
                    .object(["cmd": .string("resolve_file"), "args": .object(["name": .string("e410.pdf"), "url": .string("https://cdn.example.invalid/e410.pdf")])]),
                    .object(["cmd": .string("resolve_file"), "args": .object(["name": .string("ehost.pdf"), "url": .string("https://cdn.example.invalid/ehost.pdf")])]),
                    .object(["cmd": .string("resolve_file"), "args": .object(["name": .string("eundec.pdf"), "url": .string("https://cdn.example.invalid/eundec.pdf")])]),
                    .object(["cmd": .string("resolve_file"), "args": .object(["name": .string("etimeout.pdf"), "url": .string("https://cdn.example.invalid/etimeout.pdf")])]),
                    .object(["cmd": .string("resolve_file"), "args": .object(["name": .string("elarge.pdf"), "url": .string("https://cdn.example.invalid/elarge.pdf")])]),
                    .object(["cmd": .string("resolve_file"), "args": .object(["name": .string("e500.pdf"), "url": .string("https://cdn.example.invalid/e500.pdf")])]),
                    .object(["cmd": .string("resolve_file"), "args": .object(["name": .string("ebad.pdf"), "url": .string("https://cdn.example.invalid/ebad.pdf")])]),
                    .object(["cmd": .string("resolve_file"), "args": .object(["name": .string("enet.pdf"), "url": .string("https://cdn.example.invalid/enet.pdf")])]),
                    .object(["cmd": .string("resolve_file"), "args": .object(["name": .string("ecancel.pdf"), "url": .string("https://cdn.example.invalid/ecancel.pdf")])]),
                ]
            ),

            // 8a. shared_media: each kind with cursor and `more`, plus store error (nil).
            MediaRecorderHarness.ScenarioDef(
                name: "shared_media",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000801",
                    displayName: "Media User 8",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "history_freshness": .object(["3000801": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3000801", name: "Shared Peer"),
                        ]),
                        "local_messages": .array([
                            storedMsg(id: "m_img1", convId: "3000801", senderId: "3000801", text: "", kind: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/i1.jpg"), "width": .int(100), "height": .int(100)]), kindTag: "photo", tsMs: baseTs + 1000),
                            storedMsg(id: "m_img2", convId: "3000801", senderId: "3000801", text: "", kind: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/i2.jpg"), "width": .int(200), "height": .int(200)]), kindTag: "photo", tsMs: baseTs + 2000),
                            storedMsg(id: "m_vid3", convId: "3000801", senderId: "3000801", text: "", kind: .object(["type": .string("video"), "thumbnail": .string("https://cdn.example.invalid/vt3.jpg"), "duration": .int(12), "url": .string("https://cdn.example.invalid/v3.mp4")]), kindTag: "video", tsMs: baseTs + 3000),
                            storedMsg(id: "m_file1", convId: "3000801", senderId: "3000801", text: "f1.pdf", kind: .object(["type": .string("file"), "name": .string("f1.pdf"), "size": .int(100), "url": .string("https://cdn.example.invalid/f1.pdf")]), kindTag: "file", tsMs: baseTs + 4000),
                            storedMsg(id: "m_file2", convId: "3000801", senderId: "3000801", text: "f2.pdf", kind: .object(["type": .string("file"), "name": .string("f2.pdf"), "size": .int(200), "url": .string("https://cdn.example.invalid/f2.pdf")]), kindTag: "file", tsMs: baseTs + 5000),
                            storedMsg(id: "m_link1", convId: "3000801", senderId: "3000801", text: "https://example.com/1", kind: .object(["type": .string("link"), "title": .string("Link 1"), "url": .string("https://example.com/1"), "thumbnail": .string(""), "description": .string(""), "source": .string("example.com")]), kindTag: "link", tsMs: baseTs + 6000),
                            storedMsg(id: "m_link2", convId: "3000801", senderId: "3000801", text: "https://example.com/2", kind: .object(["type": .string("link"), "title": .string("Link 2"), "url": .string("https://example.com/2"), "thumbnail": .string(""), "description": .string(""), "source": .string("example.com")]), kindTag: "link", tsMs: baseTs + 7000),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000801", displayName: "Media User 8"),
                    MessageRecorderHarness.profileMeScript(uid: "2000801", displayName: "Media User 8"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("shared_media"), "args": .object(["conv_id": .string("3000801"), "kind": .string("images"), "limit": .int(2)])]),
                    .object(["cmd": .string("shared_media"), "args": .object(["conv_id": .string("3000801"), "kind": .string("images"), "after_prev": .bool(true), "limit": .int(2)])]),
                    .object(["cmd": .string("shared_media"), "args": .object(["conv_id": .string("3000801"), "kind": .string("files"), "limit": .int(1)])]),
                    .object(["cmd": .string("shared_media"), "args": .object(["conv_id": .string("3000801"), "kind": .string("files"), "after_prev": .bool(true), "limit": .int(1)])]),
                    .object(["cmd": .string("shared_media"), "args": .object(["conv_id": .string("3000801"), "kind": .string("links"), "limit": .int(1)])]),
                    .object(["cmd": .string("shared_media"), "args": .object(["conv_id": .string("3000801"), "kind": .string("links"), "after_prev": .bool(true), "limit": .int(1)])]),
                    .object(["cmd": .string("shared_media"), "args": .object(["conv_id": .string("3000801"), "kind": .string("images"), "limit": .int(10), "simulate_store_error": .bool(true)])]),
                ]
            ),

            // 8b. shared_media_no_store: memory fallback when sqliteStore is nil.
            MediaRecorderHarness.ScenarioDef(
                name: "shared_media_no_store",
                seed: .object([
                    "saved_session": .null,
                    "suppress": .array([.string("ws"), .string("long_poll")]),
                    "memory_messages": .object([
                        "3000802": .array([
                            .object(["id": .string("mm_img1"), "conv_id": .string("3000802"), "sender_id": .string("3000802"), "text": .string(""), "kind": .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/mi1.jpg"), "width": .int(10), "height": .int(10)]), "ts_ms": .int(baseTs + 1000)]),
                            .object(["id": .string("mm_vid1"), "conv_id": .string("3000802"), "sender_id": .string("3000802"), "text": .string(""), "kind": .object(["type": .string("video"), "thumbnail": .string(""), "duration": .int(3), "url": .string("https://cdn.example.invalid/mv1.mp4")]), "ts_ms": .int(baseTs + 2000)]),
                            .object(["id": .string("mm_img2"), "conv_id": .string("3000802"), "sender_id": .string("3000802"), "text": .string(""), "kind": .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/mi2.jpg"), "width": .int(20), "height": .int(20)]), "ts_ms": .int(baseTs + 3000)]),
                            .object(["id": .string("mm_file1"), "conv_id": .string("3000802"), "sender_id": .string("3000802"), "text": .string("mf1.pdf"), "kind": .object(["type": .string("file"), "name": .string("mf1.pdf"), "size": .int(50), "url": .string("https://cdn.example.invalid/mf1.pdf")]), "ts_ms": .int(baseTs + 4000)]),
                            .object(["id": .string("mm_link_ok"), "conv_id": .string("3000802"), "sender_id": .string("3000802"), "text": .string("https://example.com/ok"), "kind": .object(["type": .string("link"), "title": .string("OK"), "url": .string("https://example.com/ok"), "thumbnail": .string(""), "description": .string(""), "source": .string("")]), "ts_ms": .int(baseTs + 5000)]),
                            .object(["id": .string("mm_link_nil"), "conv_id": .string("3000802"), "sender_id": .string("3000802"), "text": .string("no url"), "kind": .object(["type": .string("link"), "title": .string("NoURL"), "url": .string(""), "thumbnail": .string(""), "description": .string(""), "source": .string("")]), "ts_ms": .int(baseTs + 6000)]),
                        ]),
                    ]),
                ]),
                server: [],
                steps: [
                    .object(["cmd": .string("shared_media"), "args": .object(["conv_id": .string("3000802"), "kind": .string("images"), "limit": .int(2)])]),
                    .object(["cmd": .string("shared_media"), "args": .object(["conv_id": .string("3000802"), "kind": .string("files"), "limit": .int(5)])]),
                    .object(["cmd": .string("shared_media"), "args": .object(["conv_id": .string("3000802"), "kind": .string("links"), "limit": .int(5)])]),
                ]
            ),

            // 9. file_keys: with ids, url only, name only; a remembered path whose file is gone is forgotten.
            MediaRecorderHarness.ScenarioDef(
                name: "file_keys",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000901",
                    displayName: "Media User 9",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "existing_download_files": .array([.string("exists.pdf")]),
                        "downloaded_file_paths": .object([
                            "3000901|m1": .string("<downloads>/exists.pdf"),
                            "3000901|m2": .string("<downloads>/gone.pdf"),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000901", displayName: "Media User 9"),
                    MessageRecorderHarness.profileMeScript(uid: "2000901", displayName: "Media User 9"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object([
                        "cmd": .string("file_key"),
                        "args": .object([
                            "conv_id": .string("3000901"),
                            "msg_id": .string("m1"),
                            "url": .string("https://cdn.example.invalid/a.pdf"),
                            "name": .string("a.pdf"),
                        ]),
                    ]),
                    .object([
                        "cmd": .string("file_key"),
                        "args": .object([
                            "conv_id": .string("3000901"),
                            "msg_id": .string("m2"),
                            "url": .string("https://cdn.example.invalid/b.pdf"),
                            "name": .string("b.pdf"),
                        ]),
                    ]),
                    .object([
                        "cmd": .string("file_key"),
                        "args": .object([
                            "conv_id": .string(""),
                            "msg_id": .string("m3"),
                            "url": .string("https://cdn.example.invalid/only_url.pdf"),
                            "name": .string("fallback.pdf"),
                        ]),
                    ]),
                    .object([
                        "cmd": .string("file_key"),
                        "args": .object([
                            "conv_id": .string("3000901"),
                            "msg_id": .string(""),
                            "name": .string("only_name.pdf"),
                        ]),
                    ]),
                ]
            ),
        ]
    }
}

// MARK: - Media Recorder Harness

@MainActor
private final class MediaTransitionRecorder {
    private let scenarioName: String
    private let capture: () -> CaseJSON
    private var history: [CaseJSON] = []
    private var searchFromIndex = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    var onChange: (() -> Void)?

    init(scenarioName: String, capture: @escaping () -> CaseJSON) {
        self.scenarioName = scenarioName
        self.capture = capture
    }

    func recordTransition() {
        history.append(capture())
        onChange?()
        if !waiters.isEmpty {
            let pending = waiters
            waiters.removeAll()
            for cont in pending.values {
                cont.resume()
            }
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
                throw MediaRecorderHarness.RecorderError.timeout(
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

enum MediaRecorderHarness {
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

    struct ScenarioDef {
        let name: String
        let seed: CaseJSON
        let server: [CaseJSON]
        let steps: [CaseJSON]
        var slow: Bool = false
    }

    static func runDomainSuite(domain: String, scenarios: [ScenarioDef]) async throws {
        guard !scenarios.isEmpty else { return }
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
        let knownDiffs = try CaseFile.loadKnownDiffs()
        var usedKnownDiffs = Array(repeating: false, count: knownDiffs.count)

        var byName: [String: CaseJSON] = [:]
        for item in existing {
            if let name = item["name"]?.stringValue {
                byName[name] = item
            }
        }
        XCTAssertEqual(byName.count, scenarios.count, "\(domain).jsonl case count mismatch (run with OLAZ_RECORD=1 to regenerate)")

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
            XCTFail("\(domain): stale known-diff entry \(stale)")
        }
    }

    @MainActor
    static func recordScenario(domain: String, _ scenario: ScenarioDef) async throws -> CaseJSON {
        try await RecorderSuiteLock.shared.withLock {
            try await _recordScenarioLocked(domain: domain, scenario)
        }
    }

    @MainActor
    private static func _recordScenarioLocked(domain: String, _ scenario: ScenarioDef) async throws -> CaseJSON {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-media-recorder-\(scenario.name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let inputDir = dataDir.appendingPathComponent("input", isDirectory: true)
        let downloadsDir = dataDir.appendingPathComponent("downloads", isDirectory: true)
        let stagingDir = dataDir.appendingPathComponent("zcloud-preview", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let storage = RecorderStorageIsolation(prefix: "olaz.media-recorder")
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
                .replacingString("<data>", with: dataDir.path)
                .replacingString("<downloads>", with: downloadsDir.path)
                .replacingString("<input>", with: inputDir.path)
        }

        func normalizeRecordedURLs(_ json: CaseJSON) -> CaseJSON {
            json
                .replacingString(baseURL, with: "http://fake")
                .replacingString(wsURL, with: "ws://fake")
                .replacingString(inputDir.path, with: "<input>")
                .replacingString(downloadsDir.path, with: "<downloads>")
                .replacingString(dataDir.path, with: "<data>")
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
        if let planObj = scenario.seed["cloud_plan"]?.objectValue {
            let kind = CloudState.PlanKind(rawValue: planObj["kind"]?.stringValue ?? "free") ?? .free
            engine.cloud.plan = CloudState.Plan(
                kind: kind,
                name: planObj["name"]?.stringValue ?? "Cloud của tôi",
                quota: planObj["quota"]?.int64Value ?? 1_073_741_824,
                usage: 0,
                family: 0,
                cloudMedia: 0,
                messageBackup: 0,
                myCloud: 0,
                expireAt: nil,
                autoRenew: nil,
                months: 0,
                hasKey: true,
                backupMedia: false,
                backupMyCloud: true,
                backupMessages: true,
                fileLimit: planObj["file_limit"]?.int64Value ?? (100 * 1_048_576)
            )
        }
        if let memObj = scenario.seed["memory_messages"]?.objectValue {
            for (convId, arrVal) in memObj {
                guard let arr = arrVal.arrayValue else { continue }
                let msgs: [ChatMessage] = arr.compactMap { item -> ChatMessage? in
                    guard let obj = item.objectValue else { return nil }
                    let id = obj["id"]?.stringValue ?? ""
                    let senderId = obj["sender_id"]?.stringValue ?? ""
                    let text = obj["text"]?.stringValue ?? ""
                    let tsMs = obj["ts_ms"]?.int64Value ?? 0
                    let kindDict = obj["kind"]?.toFoundation() as? [String: Any] ?? ["type": "text"]
                    var raw: [String: Any] = [
                        "id": id,
                        "conversationId": convId,
                        "clientId": "cli_\(id)",
                        "senderId": senderId,
                        "senderName": "Peer",
                        "isMine": false,
                        "text": text,
                        "date": tsMs,
                        "status": "sent",
                        "isE2EE": false,
                        "kind": kindDict,
                    ]
                    if let fallbacks = obj["fallback_urls"]?.arrayValue?.compactMap(\.stringValue) {
                        raw["fallbacks"] = fallbacks
                    }
                    return ChatMessage(json: raw, fallbackConversation: convId)
                }
                engine.messages[convId] = msgs
            }
        }
        if let dlNames = scenario.seed["existing_download_files"]?.arrayValue {
            for name in dlNames.compactMap(\.stringValue) {
                let p = downloadsDir.appendingPathComponent(name)
                try Data("downloaded".utf8).write(to: p, options: .atomic)
            }
        }
        if let dlMap = scenario.seed["downloaded_file_paths"]?.objectValue {
            var paths: [String: URL] = [:]
            for (k, v) in dlMap {
                if let s = v.stringValue {
                    let resolved = substituteRuntimeURLs(.string(s)).stringValue ?? s
                    paths[k] = URL(fileURLWithPath: resolved)
                }
            }
            engine.downloadedFilePaths = paths
        }

        // Seed MediaCache files and allowed local files
        let cacheDir = dataDir.appendingPathComponent("MediaCache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        if let cachedEntries = scenario.seed["preseeded_media_cache"]?.arrayValue {
            for entry in cachedEntries {
                guard let key = entry["key"]?.stringValue else { continue }
                let ext = entry["ext"]?.stringValue ?? "png"
                let bytes: Data
                if let b64 = entry["data_b64"]?.stringValue, let d = Data(base64Encoded: b64) {
                    bytes = d
                } else {
                    bytes = Data((entry["data_utf8"]?.stringValue ?? "").utf8)
                }
                let hash = MediaLoader.stableHash(key)
                try bytes.write(to: cacheDir.appendingPathComponent("\(hash).\(ext)"), options: .atomic)
            }
        }
        var allowedLocalPaths: Set<String> = []
        if let allowedEntries = scenario.seed["allowed_local_files"]?.arrayValue {
            for entry in allowedEntries {
                guard let rel = entry["rel_path"]?.stringValue else { continue }
                let dest = dataDir.appendingPathComponent(rel)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                let bytes: Data
                if let b64 = entry["data_b64"]?.stringValue, let d = Data(base64Encoded: b64) {
                    bytes = d
                } else {
                    bytes = Data((entry["data_utf8"]?.stringValue ?? "").utf8)
                }
                try bytes.write(to: dest, options: .atomic)
                allowedLocalPaths.insert(dest.path)
            }
        }

        // Current step's file specs keyed by `<input>/<name>`
        var activeFileSpecs: [String: CaseJSON] = [:]

        engine.readOutgoingFileHostHandler = { args in
            let path = args["path"] as? String ?? ""
            if let spec = activeFileSpecs[path] {
                return OutgoingFileProbeResult(
                    exists: spec["exists"]?.boolValue ?? true,
                    isDirectory: spec["is_dir"]?.boolValue ?? false,
                    readable: spec["readable"]?.boolValue ?? true,
                    size: spec["size"]?.int64Value ?? 0,
                    mediaType: spec["type"]?.stringValue,
                    data: Data("synthetic".utf8)
                )
            }
            return OutgoingFileProbeResult(exists: false, isDirectory: false, readable: false, size: 0)
        }

        let dimQueue = scenario.seed["host_results"]?["image_dimensions"]?.arrayValue ?? []
        var dimIndex = 0
        engine.imageDimensionsHostHandler = { _ in
            guard dimIndex < dimQueue.count else { return (800, 600) }
            let item = dimQueue[dimIndex]
            dimIndex += 1
            return (Int(item["width"]?.int64Value ?? 800), Int(item["height"]?.int64Value ?? 600))
        }

        let videoMetaQueue = scenario.seed["host_results"]?["video_metadata"]?.arrayValue ?? []
        var videoMetaIndex = 0
        engine.videoMetadataHostHandler = { _ in
            guard videoMetaIndex < videoMetaQueue.count else {
                return VideoMetadata(durationMs: 0, width: 0, height: 0, thumbnailData: Data())
            }
            let item = videoMetaQueue[videoMetaIndex]
            videoMetaIndex += 1
            let hasThumb = item["has_thumb"]?.boolValue ?? false
            return VideoMetadata(
                durationMs: Int(item["duration_ms"]?.int64Value ?? 0),
                width: Int(item["width"]?.int64Value ?? 0),
                height: Int(item["height"]?.int64Value ?? 0),
                thumbnailData: hasThumb ? Data("thumb".utf8) : Data()
            )
        }

        func parseErrorItem(_ item: CaseJSON) -> Error? {
            if let errObj = item["session_error"]?.objectValue {
                return ZaloSessionError(
                    code: Int(errObj["code"]?.int64Value ?? 500),
                    message: errObj["message"]?.stringValue ?? "",
                    url: errObj["url"]?.stringValue ?? "/api/upload"
                )
            }
            if let code = item["url_error"]?.int64Value {
                return URLError(URLError.Code(rawValue: Int(code)))
            }
            if let msg = item["error"]?.stringValue {
                return NSError(domain: "MediaRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
            }
            return nil
        }

        let uploadPhotoQueue = scenario.seed["host_results"]?["upload_photo"]?.arrayValue ?? []
        var uploadPhotoIndex = 0
        engine.uploadPhotoHostHandler = { _ in
            guard uploadPhotoIndex < uploadPhotoQueue.count else {
                throw ZaloSessionError(code: 500, message: "No scripted upload_photo", url: "/api/message/photo_original/send")
            }
            let item = uploadPhotoQueue[uploadPhotoIndex]
            uploadPhotoIndex += 1
            if let err = parseErrorItem(item) { throw err }
            return UploadedMediaResult(
                url: item["url"]?.stringValue ?? "",
                msgId: item["msg_id"]?.stringValue ?? "",
                cliMsgId: item["cli_msg_id"]?.stringValue ?? "",
                width: Int(item["width"]?.int64Value ?? 0),
                height: Int(item["height"]?.int64Value ?? 0)
            )
        }

        let uploadVideoQueue = scenario.seed["host_results"]?["upload_video"]?.arrayValue ?? []
        var uploadVideoIndex = 0
        engine.uploadVideoHostHandler = { _ in
            guard uploadVideoIndex < uploadVideoQueue.count else {
                throw ZaloSessionError(code: 500, message: "No scripted upload_video", url: "/api/message/asyncfile/msg")
            }
            let item = uploadVideoQueue[uploadVideoIndex]
            uploadVideoIndex += 1
            if let err = parseErrorItem(item) { throw err }
            return UploadedVideoResult(
                url: item["url"]?.stringValue ?? "",
                thumbUrl: item["thumb_url"]?.stringValue ?? "",
                msgId: item["msg_id"]?.stringValue ?? "",
                cliMsgId: item["cli_msg_id"]?.stringValue ?? "",
                width: Int(item["width"]?.int64Value ?? 0),
                height: Int(item["height"]?.int64Value ?? 0),
                durationMs: Int(item["duration_ms"]?.int64Value ?? 0)
            )
        }

        var heldUploadWaiters: [CheckedContinuation<Void, Never>] = []
        let uploadFileQueue = scenario.seed["host_results"]?["upload_file"]?.arrayValue ?? []
        var uploadFileIndex = 0
        engine.uploadFileHostHandler = { args in
            guard uploadFileIndex < uploadFileQueue.count else {
                throw ZaloSessionError(code: 500, message: "No scripted upload_file", url: "/api/message/asyncfile/msg")
            }
            let item = uploadFileQueue[uploadFileIndex]
            uploadFileIndex += 1
            if item["hold"]?.boolValue == true {
                await withCheckedContinuation { cont in
                    heldUploadWaiters.append(cont)
                }
            }
            if let err = parseErrorItem(item) { throw err }
            return UploadedMediaResult(
                url: item["url"]?.stringValue ?? "",
                msgId: item["msg_id"]?.stringValue ?? "",
                cliMsgId: item["cli_msg_id"]?.stringValue ?? (args["client_id"] as? String ?? ""),
                width: 0,
                height: 0
            )
        }

        engine.mediaCacheLookupHostHandler = { args in
            let hashPrefix = args["hash_prefix"] as? String ?? ""
            let kindStr = args["kind"] as? String ?? "photo"
            let kind: MediaKind = {
                switch kindStr {
                case "video": return .video
                case "videoThumb": return .videoThumb
                default: return .photo
                }
            }()
            return ZaloEngine.findCachedMediaFile(hashPrefix: hashPrefix, in: cacheDir, kind: kind)
        }

        let posterQueue = scenario.seed["host_results"]?["video_poster"]?.arrayValue ?? []
        var posterIndex = 0
        engine.videoPosterHostHandler = { _ in
            guard posterIndex < posterQueue.count else { return nil }
            let item = posterQueue[posterIndex]
            posterIndex += 1
            guard let rel = item["rel_path"]?.stringValue else { return nil }
            let posterURL = dataDir.appendingPathComponent(rel)
            try? FileManager.default.createDirectory(at: posterURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? MediaRecorderTests.onePixelPNG.write(to: posterURL, options: .atomic)
            return posterURL
        }

        engine.allowedLocalFileHostHandler = { args in
            guard let urlStr = args["url"] as? String, let u = URL(string: urlStr), u.isFileURL else {
                return false
            }
            return allowedLocalPaths.contains(u.path) && FileManager.default.fileExists(atPath: u.path)
        }

        let loaderMap = scenario.seed["host_results"]?["loader_fetch"]?.objectValue ?? [:]
        engine.mediaLoaderFetchHostHandler = { args in
            let urlStr = args["url"] as? String ?? ""
            guard let item = loaderMap[urlStr] else {
                throw MediaLoader.LoadError.http(404)
            }
            if item["cancelled"]?.boolValue == true { throw CancellationError() }
            if item["host_not_found"]?.boolValue == true { throw MediaLoader.LoadError.hostNotFound }
            if item["undecodable"]?.boolValue == true { throw MediaLoader.LoadError.undecodable }
            if item["timed_out"]?.boolValue == true { throw MediaLoader.LoadError.timedOut }
            if item["too_large"]?.boolValue == true { throw MediaLoader.LoadError.tooLarge }
            if item["bad_url"]?.boolValue == true { throw MediaLoader.LoadError.badURL }
            if let status = item["http_error"]?.int64Value { throw MediaLoader.LoadError.http(Int(status)) }
            if let code = item["url_error"]?.int64Value { throw URLError(URLError.Code(rawValue: Int(code))) }
            if let b64 = item["data_b64"]?.stringValue, let d = Data(base64Encoded: b64) {
                return .data(d)
            }
            if let utf8 = item["data_utf8"]?.stringValue {
                return .data(Data(utf8.utf8))
            }
            throw MediaLoader.LoadError.http(500)
        }

        engine.stageFileHostHandler = { source, stem, ext in
            let fileName = ext.map { "\(stem).\($0)" } ?? stem
            let dest = stagingDir.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: source, to: dest)
            return dest
        }

        var bootstrapLogs: [String] = []
        var sendLogs: [String] = []
        var actionLogs: [String] = []
        var results: [String: CaseJSON] = [:]
        var lastSharedMediaCursor: String?
        var activeMediaSendTask: Task<ComposerOutcome, Never>?
        var activeMediaSendStepIndex: Int?

        EngineLog.shared.onAppend = { rawLine in
            if let sp = rawLine.firstIndex(of: " ") {
                let msg = String(rawLine[rawLine.index(after: sp)...])
                if msg.hasPrefix("bootstrap: ") { bootstrapLogs.append(msg) }
                if msg.hasPrefix("sendText ") { sendLogs.append(msg) }
                if msg.hasPrefix("recall failed:") || msg.hasPrefix("react failed:") {
                    actionLogs.append(msg)
                }
            }
        }

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
            case "apply_batch", "apply_parsed_events", "show_typing", "show_card",
                 "read_file", "image_dimensions", "video_metadata", "video_poster",
                 "upload_photo", "upload_video", "upload_file",
                 "media_cache_lookup", "check_local_file", "loader_fetch":
                return true
            case "start_ws":
                return !suppressedTransports.contains("ws")
            case "start_long_poll":
                return !suppressedTransports.contains("long_poll")
            default:
                return false
            }
        }
        await engine.syncSessionClientTrace()

        engine.transportSettleTrace = {
            Task { @MainActor in
                settleCount += 1
                notifySignal()
            }
        }

        let transitionRecorder = MediaTransitionRecorder(scenarioName: scenario.name) {
            normalizeRecordedURLs(SessionSnapshot.capture(from: engine))
        }
        transitionRecorder.onChange = { notifySignal() }
        engine.stateTrace = { [weak transitionRecorder] in
            transitionRecorder?.recordTransition()
        }
        var snapshots: [String: CaseJSON] = [:]

        func waitForCondition(timeoutMs: Int, description: String, _ predicate: @escaping () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
            while !predicate() {
                if Date() >= deadline {
                    throw RecorderError.timeout(scenario: scenario.name, detail: "Timed out waiting for \(description)")
                }
                let remaining = max(0.01, deadline.timeIntervalSinceNow)
                let id = UUID()
                let sleepTask = Task {
                    try? await Task.sleep(for: .seconds(remaining))
                    await MainActor.run {
                        if let cont = signalWaiters.removeValue(forKey: id) {
                            cont.resume()
                        }
                    }
                }
                await withCheckedContinuation { cont in
                    if predicate() {
                        sleepTask.cancel()
                        cont.resume()
                    } else {
                        signalWaiters[id] = cont
                    }
                }
                sleepTask.cancel()
            }
        }

        func makeFileURLs(from stepFiles: [CaseJSON]) -> [URL] {
            var urls: [URL] = []
            for spec in stepFiles {
                let name = spec["name"]?.stringValue ?? "file.bin"
                let url = inputDir.appendingPathComponent(name)
                activeFileSpecs[url.path] = spec
                urls.append(url)
            }
            return urls
        }

        do {
            for (stepIndex, step) in scenario.steps.enumerated() {
                if let cmd = step["cmd"]?.stringValue {
                    let args = step["args"]
                    var keepNowMsForAsync = false
                    if let fixedNow = step["now_ms"]?.int64Value {
                        engine.nowMs = { fixedNow }
                        engine.mediaResolver.now = { Date(timeIntervalSince1970: Double(fixedNow) / 1000.0) }
                    }
                    defer {
                        if step["now_ms"] != nil && !keepNowMsForAsync {
                            engine.nowMs = { Int64(Date().timeIntervalSince1970 * 1000) }
                            engine.mediaResolver.now = { Date() }
                        }
                    }

                    switch cmd {
                    case "start":
                        engine.start()
                        await engine.settleForRecording()
                    case "open":
                        _ = await engine.bootTask?.value
                        let id = args?["id"]?.stringValue ?? ""
                        engine.openConversation(id)
                        _ = await engine.openConversationTask?.value
                        await engine.settleForRecording()
                        await engine.awaitMarkReadTasksForRecording()
                    case "send_media":
                        _ = await engine.bootTask?.value
                        let convId = args?["conv_id"]?.stringValue ?? ""
                        let urls = makeFileURLs(from: args?["files"]?.arrayValue ?? [])
                        let outcome = await engine.sendMedia(urls, to: convId)
                        await engine.settleForRecording()
                        _ = await engine.persistConversationsTask?.value
                        results["\(stepIndex)"] = normalizeRecordedURLs(MediaSnapshot.encodeComposerOutcome(outcome))
                    case "send_files":
                        _ = await engine.bootTask?.value
                        let convId = args?["conv_id"]?.stringValue ?? ""
                        let urls = makeFileURLs(from: args?["files"]?.arrayValue ?? [])
                        let isAsync = args?["async"]?.boolValue ?? false
                        if isAsync {
                            keepNowMsForAsync = true
                            activeMediaSendStepIndex = stepIndex
                            activeMediaSendTask = Task { @MainActor in
                                await engine.sendFiles(urls, to: convId)
                            }
                        } else {
                            let outcome = await engine.sendFiles(urls, to: convId)
                            await engine.settleForRecording()
                            _ = await engine.persistConversationsTask?.value
                            results["\(stepIndex)"] = normalizeRecordedURLs(MediaSnapshot.encodeComposerOutcome(outcome))
                        }
                    case "await_send":
                        if let task = activeMediaSendTask {
                            let outcome = await task.value
                            if let idx = activeMediaSendStepIndex {
                                results["\(idx)"] = normalizeRecordedURLs(MediaSnapshot.encodeComposerOutcome(outcome))
                            }
                            activeMediaSendTask = nil
                            activeMediaSendStepIndex = nil
                        }
                        await engine.settleForRecording()
                        _ = await engine.persistConversationsTask?.value
                        engine.nowMs = { Int64(Date().timeIntervalSince1970 * 1000) }
                        engine.mediaResolver.now = { Date() }
                    case "resolve_media":
                        _ = await engine.bootTask?.value
                        let convId = args?["conv_id"]?.stringValue ?? ""
                        let msgId = args?["msg_id"]?.stringValue ?? ""
                        let kindStr = args?["kind"]?.stringValue ?? "photo"
                        let kind: MediaKind = {
                            switch kindStr {
                            case "video": return .video
                            case "videoThumb": return .videoThumb
                            default: return .photo
                            }
                        }()
                        let force = args?["force"]?.boolValue ?? false
                        let res = await engine.resolveMedia(conversationId: convId, messageId: msgId, kind: kind, force: force)
                        results["\(stepIndex)"] = normalizeRecordedURLs(MediaSnapshot.encodeMediaResolution(res))
                    case "resolve_file":
                        _ = await engine.bootTask?.value
                        let convId = args?["conv_id"]?.stringValue ?? ""
                        let msgId = args?["msg_id"]?.stringValue ?? ""
                        let name = args?["name"]?.stringValue ?? ""
                        let url = args?["url"]?.stringValue.flatMap(URL.init(string:))
                        let force = args?["force"]?.boolValue ?? false
                        let res = await engine.resolveFile(conversationId: convId, messageId: msgId, name: name, url: url, force: force)
                        results["\(stepIndex)"] = normalizeRecordedURLs(MediaSnapshot.encodeFileResolution(res))
                    case "shared_media":
                        _ = await engine.bootTask?.value
                        let convId = args?["conv_id"]?.stringValue ?? ""
                        let kindStr = args?["kind"]?.stringValue ?? "images"
                        let kind: SharedMediaKind = {
                            switch kindStr {
                            case "files": return .files
                            case "links": return .links
                            default: return .images
                            }
                        }()
                        let usePrev = args?["after_prev"]?.boolValue ?? false
                        let after = usePrev ? lastSharedMediaCursor : args?["after"]?.stringValue
                        let limit = Int(args?["limit"]?.int64Value ?? 60)
                        if args?["simulate_store_error"]?.boolValue == true {
                            engine.simulateSharedMediaStoreErrorOnce = true
                        }
                        let page = await engine.sharedMedia(in: convId, kind: kind, after: after, limit: limit)
                        lastSharedMediaCursor = page?.cursor
                        results["\(stepIndex)"] = normalizeRecordedURLs(MediaSnapshot.encodeSharedMediaPage(page))
                    case "file_key":
                        _ = await engine.bootTask?.value
                        let convId = args?["conv_id"]?.stringValue ?? ""
                        let msgId = args?["msg_id"]?.stringValue ?? ""
                        let name = args?["name"]?.stringValue ?? ""
                        let url = args?["url"]?.stringValue.flatMap(URL.init(string:))
                        let key = engine.fileDownloadKey(conversationId: convId, messageId: msgId, url: url, name: name)
                        let remembered = engine.rememberedDownloadedFile(for: key)
                        results["\(stepIndex)"] = normalizeRecordedURLs(.object([
                            "key": .string(key),
                            "path": remembered.map { .string($0.path) } ?? .null,
                        ]))
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
                    }
                } else if let pushCount = step["ws_push"]?.int64Value {
                    let timeoutMs = Int(step["timeout_ms"]?.int64Value ?? 5000)
                    try await server.pushWebSocketActions(count: Int(pushCount), timeoutMs: timeoutMs)
                } else if let releaseCount = step["upload_release"]?.int64Value {
                    for _ in 0..<Int(releaseCount) {
                        if !heldUploadWaiters.isEmpty {
                            heldUploadWaiters.removeFirst().resume()
                        }
                    }
                } else if let label = step["snapshot"]?.stringValue {
                    await engine.settleForRecording()
                    await Task.yield()
                    let snap = await MediaSnapshot.capture(
                        from: engine,
                        bootstrapLogs: bootstrapLogs,
                        sendLogs: sendLogs,
                        actionLogs: actionLogs,
                        results: results
                    )
                    snapshots[label] = normalizeRecordedURLs(snap)
                } else {
                    throw RecorderError.invalidStep(scenario: scenario.name, detail: "Unknown step: \(step.canonicalString())")
                }
            }

            if let task = activeMediaSendTask {
                for cont in heldUploadWaiters { cont.resume() }
                heldUploadWaiters.removeAll()
                let outcome = await task.value
                if let idx = activeMediaSendStepIndex {
                    results["\(idx)"] = normalizeRecordedURLs(MediaSnapshot.encodeComposerOutcome(outcome))
                }
                activeMediaSendTask = nil
            }
            _ = await engine.bootTask?.value
            _ = await engine.openConversationTask?.value
            await engine.awaitMarkReadTasksForRecording()
            _ = await engine.persistConversationsTask?.value
            await server.waitForScriptedRequests(timeoutMs: 2000)
            if !suppressedTransports.contains("ws") {
                try? await Task.sleep(for: .milliseconds(50))
            }
            await engine.settleForRecording()
            await Task.yield()

            let finalState = normalizeRecordedURLs(
                await MediaSnapshot.capture(
                    from: engine,
                    bootstrapLogs: bootstrapLogs,
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

            return .object([
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
            ])
        } catch {
            transitionRecorder.cancelWaiters()
            for cont in heldUploadWaiters { cont.resume() }
            heldUploadWaiters.removeAll()
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

    // MARK: - Seed Helpers

    private static func seedSQLiteStore(userId: String, dataDir: URL, seed: CaseJSON) async throws {
        let dbURL = dataDir
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(userId, isDirectory: true)
            .appendingPathComponent("history.sqlite3")
        let store = try ZaloSQLiteStore(path: dbURL.path)
        try await store.setPreferenceString(key: ZaloWebKitMigrator.donePrefKey, value: "1")

        if let e2eeThreads = seed["e2ee_threads"]?.arrayValue?.compactMap(\.stringValue), !e2eeThreads.isEmpty {
            let data = try JSONEncoder().encode(e2eeThreads)
            try await store.setPreferenceData(key: "e2eeThreadsV1", data: data)
        }
        if let convsJSON = seed["local_conversations"]?.arrayValue {
            let rows: [StoredConversation] = convsJSON.compactMap { item in
                guard let id = item["id"]?.stringValue else { return nil }
                return StoredConversation(
                    id: id,
                    isGroup: item["is_group"]?.boolValue ?? false,
                    name: item["name"]?.stringValue ?? "",
                    avatar: item["avatar"]?.stringValue ?? "",
                    pinned: item["pinned"]?.boolValue ?? false,
                    members: Int(item["members"]?.int64Value ?? 0),
                    unread: Int(item["unread"]?.int64Value ?? 0),
                    previewText: item["preview_text"]?.stringValue ?? "",
                    previewTsMs: item["preview_ts_ms"]?.int64Value ?? 0,
                    previewFromMe: item["preview_from_me"]?.boolValue ?? false,
                    updatedAtMs: item["updated_at_ms"]?.int64Value ?? 0
                )
            }
            if !rows.isEmpty {
                try await store.saveConversations(rows)
            }
        }
        if let msgsJSON = seed["local_messages"]?.arrayValue {
            let rows: [StoredMessage] = msgsJSON.compactMap { item -> StoredMessage? in
                guard let id = item["id"]?.stringValue,
                      let convId = item["conv_id"]?.stringValue else {
                    return nil
                }
                let rawJSONData: Data = {
                    if let rawObj = item["raw_json"], rawObj != .null {
                        return Data(rawObj.canonicalString().utf8)
                    }
                    return Data()
                }()
                return StoredMessage(
                    id: id,
                    convId: convId,
                    clientId: item["client_id"]?.stringValue ?? "",
                    senderId: item["sender_id"]?.stringValue ?? "",
                    senderName: item["sender_name"]?.stringValue ?? "",
                    senderAvatar: item["sender_avatar"]?.stringValue ?? "",
                    isMine: item["is_mine"]?.boolValue ?? false,
                    text: item["text"]?.stringValue ?? "",
                    kindTag: item["kind_tag"]?.stringValue ?? "text",
                    tsMs: item["ts_ms"]?.int64Value ?? 0,
                    status: item["status"]?.stringValue ?? "sent",
                    rawJSONData: rawJSONData
                )
            }
            if !rows.isEmpty {
                try await store.saveMessages(rows)
            }
        }
        await store.close()
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
        return .object([
            "auth": .string("http://fake"),
            "lpChat": .string("http://fake"),
            "lpControl": .string("http://fake"),
            "wpaChat": .string("http://fake"),
            "ws": .array([.string("ws://fake")]),
            "serviceCandidates": .object(candidates),
            "preferredHosts": .object([:]),
            "isolated": .bool(true),
        ])
    }
}
