import Foundation
import XCTest
@testable import Olaz

final class ForwardRecorderTests: XCTestCase {
    func testForwardScenarios() async throws {
        try await ForwardRecorderHarness.runDomainSuite(
            domain: "forward",
            scenarios: Self.forwardScenarios()
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
        menu: CaseJSON? = nil
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
        if let menu { rawObj["menu"] = menu }

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
        avatar: String = "https://cdn.example.invalid/a.jpg",
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

    private static func forwardScenarios() -> [ForwardRecorderHarness.ScenarioDef] {
        let baseTs: Int64 = 1700000800000
        let okMenu = CaseJSON.object(["forward": .string("ok")])

        return [
            // 1. request_guards: forward available, blocked (card), unavailable (nothing).
            ForwardRecorderHarness.ScenarioDef(
                name: "request_guards",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000801",
                    displayName: "Forward User 1",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "history_freshness": .object(["3000801": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3000801", name: "Alice", previewText: "Available", previewTsMs: baseTs + 3_000),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "9080101",
                                convId: "3000801",
                                senderId: "3000801",
                                text: "Hidden forward",
                                tsMs: baseTs + 1_000,
                                menu: .object(["forward": .string("")])
                            ),
                            storedMsg(
                                id: "9080102",
                                convId: "3000801",
                                senderId: "3000801",
                                text: "Blocked forward",
                                tsMs: baseTs + 2_000,
                                menu: .object(["forward": .string("blocked")])
                            ),
                            storedMsg(
                                id: "9080103",
                                convId: "3000801",
                                senderId: "3000801",
                                text: "Available forward",
                                tsMs: baseTs + 3_000,
                                menu: okMenu
                            ),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000801", displayName: "Forward User 1"),
                    MessageRecorderHarness.profileMeScript(uid: "2000801", displayName: "Forward User 1"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000801")])]),
                    .object(["cmd": .string("request_forward"), "args": .object(["conv_id": .string("3000801"), "msg_id": .string("9080101")])]),
                    .object(["snapshot": .string("after_hidden")]),
                    .object(["cmd": .string("request_forward"), "args": .object(["conv_id": .string("3000801"), "msg_id": .string("9080102")])]),
                    .object(["snapshot": .string("after_blocked")]),
                    .object(["cmd": .string("request_forward"), "args": .object(["conv_id": .string("3000801"), "msg_id": .string("9080103")])]),
                ]
            ),

            // 2. forward_text_link: text; link with url; link without url but text; link with only title;
            // empty text skipped (counts as failure).
            ForwardRecorderHarness.ScenarioDef(
                name: "forward_text_link",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000802",
                    displayName: "Forward User 2",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(8000000000200),
                        "history_freshness": .object(["3000802a": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3000802a", name: "Source 2", previewText: "Empty", previewTsMs: baseTs + 5_000),
                            localConv(id: "3000802b", name: "Target 2"),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "9080201",
                                convId: "3000802a",
                                senderId: "3000802a",
                                text: "Hello forward",
                                tsMs: baseTs + 1_000,
                                menu: okMenu
                            ),
                            storedMsg(
                                id: "9080202",
                                convId: "3000802a",
                                senderId: "3000802a",
                                text: "Ignored link text",
                                kind: .object([
                                    "type": .string("link"),
                                    "title": .string("Example Page"),
                                    "url": .string("https://example.invalid/article"),
                                ]),
                                kindTag: "link",
                                tsMs: baseTs + 2_000,
                                menu: okMenu
                            ),
                            storedMsg(
                                id: "9080203",
                                convId: "3000802a",
                                senderId: "3000802a",
                                text: "Link body text",
                                kind: .object([
                                    "type": .string("link"),
                                    "title": .string("Title Fallback"),
                                ]),
                                kindTag: "link",
                                tsMs: baseTs + 3_000,
                                menu: okMenu
                            ),
                            storedMsg(
                                id: "9080204",
                                convId: "3000802a",
                                senderId: "3000802a",
                                text: "",
                                kind: .object([
                                    "type": .string("link"),
                                    "title": .string("Only Title Link"),
                                ]),
                                kindTag: "link",
                                tsMs: baseTs + 4_000,
                                menu: okMenu
                            ),
                            storedMsg(
                                id: "9080205",
                                convId: "3000802a",
                                senderId: "3000802a",
                                text: "",
                                tsMs: baseTs + 5_000,
                                menu: okMenu
                            ),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000802", displayName: "Forward User 2"),
                    MessageRecorderHarness.profileMeScript(uid: "2000802", displayName: "Forward User 2"),
                    ForwardRecorderHarness.httpScript(
                        path: "/api/message/sms",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9002001")])])
                    ),
                    ForwardRecorderHarness.httpScript(
                        path: "/api/message/sms",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9002002")])])
                    ),
                    ForwardRecorderHarness.httpScript(
                        path: "/api/message/sms",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9002003")])])
                    ),
                    ForwardRecorderHarness.httpScript(
                        path: "/api/message/sms",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9002004")])])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000802a")])]),
                    .object([
                        "cmd": .string("forward"),
                        "now_ms": .int(baseTs + 10_000),
                        "args": .object(["conv_id": .string("3000802a"), "msg_id": .string("9080201"), "targets": .array([.string("3000802b")])]),
                    ]),
                    .object([
                        "cmd": .string("forward"),
                        "now_ms": .int(baseTs + 11_000),
                        "args": .object(["conv_id": .string("3000802a"), "msg_id": .string("9080202"), "targets": .array([.string("3000802b")])]),
                    ]),
                    .object([
                        "cmd": .string("forward"),
                        "now_ms": .int(baseTs + 12_000),
                        "args": .object(["conv_id": .string("3000802a"), "msg_id": .string("9080203"), "targets": .array([.string("3000802b")])]),
                    ]),
                    .object([
                        "cmd": .string("forward"),
                        "now_ms": .int(baseTs + 13_000),
                        "args": .object(["conv_id": .string("3000802a"), "msg_id": .string("9080204"), "targets": .array([.string("3000802b")])]),
                    ]),
                    .object([
                        "cmd": .string("forward"),
                        "now_ms": .int(baseTs + 14_000),
                        "args": .object(["conv_id": .string("3000802a"), "msg_id": .string("9080205"), "targets": .array([.string("3000802b")])]),
                    ]),
                ]
            ),

            // 3. forward_contact_card: with and without phone; to a group, to a 1-1, to self (menu flags differ); API error.
            ForwardRecorderHarness.ScenarioDef(
                name: "forward_contact_card",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000803",
                    displayName: "Forward User 3",
                    send2MeId: "9200803",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(8000000000300),
                        "history_freshness": .object(["3000803a": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3000803a", name: "Source 3", previewText: "[Danh thiếp] Card NoPhone", previewTsMs: baseTs + 2_000),
                            localConv(id: "3000803b", name: "Target Peer 3"),
                            localConv(id: "g500803", isGroup: true, name: "Target Group 3", members: 4),
                            localConv(id: "9200803", name: "Cloud của tôi"),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "9080301",
                                convId: "3000803a",
                                senderId: "3000803a",
                                text: "[Danh thiếp] Card Phone",
                                kind: .object([
                                    "type": .string("contactCard"),
                                    "name": .string("Card Phone"),
                                    "uid": .string("4000801"),
                                    "phone": .string("+84901234567"),
                                ]),
                                kindTag: "contactCard",
                                tsMs: baseTs + 1_000,
                                menu: okMenu
                            ),
                            storedMsg(
                                id: "9080302",
                                convId: "3000803a",
                                senderId: "3000803a",
                                text: "[Danh thiếp] Card NoPhone",
                                kind: .object([
                                    "type": .string("contactCard"),
                                    "name": .string("Card NoPhone"),
                                    "uid": .string("4000802"),
                                ]),
                                kindTag: "contactCard",
                                tsMs: baseTs + 2_000,
                                menu: okMenu
                            ),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000803", displayName: "Forward User 3", send2MeId: "9200803"),
                    MessageRecorderHarness.profileMeScript(uid: "2000803", displayName: "Forward User 3"),
                    ForwardRecorderHarness.httpScript(
                        path: "/api/message/contact",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9003001")])])
                    ),
                    ForwardRecorderHarness.httpScript(
                        path: "/api/group/contact",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9003002")])])
                    ),
                    ForwardRecorderHarness.httpScript(
                        path: "/api/message/contact",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9003003")])])
                    ),
                    ForwardRecorderHarness.httpScript(
                        path: "/api/message/contact",
                        method: "POST",
                        json: .object(["error_code": .int(500), "error_message": .string("contact error")])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000803a")])]),
                    // With phone -> 1-1
                    .object([
                        "cmd": .string("forward"),
                        "now_ms": .int(baseTs + 10_000),
                        "args": .object(["conv_id": .string("3000803a"), "msg_id": .string("9080301"), "targets": .array([.string("3000803b")])]),
                    ]),
                    // Without phone -> group
                    .object([
                        "cmd": .string("forward"),
                        "now_ms": .int(baseTs + 11_000),
                        "args": .object(["conv_id": .string("3000803a"), "msg_id": .string("9080302"), "targets": .array([.string("g500803")])]),
                    ]),
                    // Without phone -> self
                    .object([
                        "cmd": .string("forward"),
                        "now_ms": .int(baseTs + 12_000),
                        "args": .object(["conv_id": .string("3000803a"), "msg_id": .string("9080302"), "targets": .array([.string("9200803")])]),
                    ]),
                    // API error -> 1-1
                    .object([
                        "cmd": .string("forward"),
                        "now_ms": .int(baseTs + 13_000),
                        "args": .object(["conv_id": .string("3000803a"), "msg_id": .string("9080301"), "targets": .array([.string("3000803b")])]),
                    ]),
                ]
            ),

            // 4. forward_media: photo with local file; photo via CDN; photo local send_media fail -> CDN fallback;
            // photo with neither; file resolved and sent; file not resolved; host send failure.
            ForwardRecorderHarness.ScenarioDef(
                name: "forward_media",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000804",
                    displayName: "Forward User 4",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "history_freshness": .object(["3000804a": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3000804a", name: "Source 4", previewText: "[File] report.pdf", previewTsMs: baseTs + 2_000),
                            localConv(id: "3000804b", name: "Target 4"),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "9080401",
                                convId: "3000804a",
                                senderId: "3000804a",
                                text: "[Hình ảnh]",
                                kind: .object([
                                    "type": .string("photo"),
                                    "url": .string("https://cdn.example.invalid/fwd-photo.jpg"),
                                    "width": .int(800),
                                    "height": .int(600),
                                ]),
                                kindTag: "photo",
                                tsMs: baseTs + 1_000,
                                menu: okMenu
                            ),
                            storedMsg(
                                id: "9080402",
                                convId: "3000804a",
                                senderId: "3000804a",
                                text: "[File] report.pdf",
                                kind: .object([
                                    "type": .string("file"),
                                    "name": .string("report.pdf"),
                                    "size": .int(2048),
                                    "url": .string("https://cdn.example.invalid/report.pdf"),
                                ]),
                                kindTag: "file",
                                tsMs: baseTs + 2_000,
                                menu: okMenu
                            ),
                        ]),
                        "host_results": .object([
                            "resolve_media": .array([
                                .object(["state": .string("file"), "path": .string("/fake/local/photo1.jpg")]),
                                .object(["state": .string("unavailable")]),
                                .object(["state": .string("file"), "path": .string("/fake/local/photo3.jpg")]),
                                .object(["state": .string("expired")]),
                            ]),
                            "fetch_media_data": .array([
                                .object(["ok": .bool(true)]),
                                .object(["ok": .bool(true)]),
                                .object(["ok": .bool(false)]),
                            ]),
                            "send_media": .array([
                                .object(["outcome": .string("done")]),
                                .object(["outcome": .string("done")]),
                                .object(["outcome": .string("failed"), "text": .string("local send failed")]),
                                .object(["outcome": .string("done")]),
                            ]),
                            "resolve_file": .array([
                                .object(["state": .string("ready"), "path": .string("/fake/staged/report.pdf")]),
                                .object(["state": .string("expired")]),
                                .object(["state": .string("ready"), "path": .string("/fake/staged/report.pdf")]),
                            ]),
                            "send_files": .array([
                                .object(["outcome": .string("done")]),
                                .object(["outcome": .string("failed"), "text": .string("file send failed")]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000804", displayName: "Forward User 4"),
                    MessageRecorderHarness.profileMeScript(uid: "2000804", displayName: "Forward User 4"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000804a")])]),
                    // Photo 1: local file ok
                    .object([
                        "cmd": .string("forward"),
                        "now_ms": .int(baseTs + 10_000),
                        "args": .object(["conv_id": .string("3000804a"), "msg_id": .string("9080401"), "targets": .array([.string("3000804b")])]),
                    ]),
                    // Photo 2: unavailable -> CDN download -> send_media ok
                    .object([
                        "cmd": .string("forward"),
                        "now_ms": .int(baseTs + 11_000),
                        "args": .object(["conv_id": .string("3000804a"), "msg_id": .string("9080401"), "targets": .array([.string("3000804b")])]),
                    ]),
                    // Photo 3: local file resolves, send_media fails -> CDN fallback -> send_media ok
                    .object([
                        "cmd": .string("forward"),
                        "now_ms": .int(baseTs + 12_000),
                        "args": .object(["conv_id": .string("3000804a"), "msg_id": .string("9080401"), "targets": .array([.string("3000804b")])]),
                    ]),
                    // Photo 4: expired + CDN fails -> failed
                    .object([
                        "cmd": .string("forward"),
                        "now_ms": .int(baseTs + 13_000),
                        "args": .object(["conv_id": .string("3000804a"), "msg_id": .string("9080401"), "targets": .array([.string("3000804b")])]),
                    ]),
                    // File 1: resolved & sent ok
                    .object([
                        "cmd": .string("forward"),
                        "now_ms": .int(baseTs + 14_000),
                        "args": .object(["conv_id": .string("3000804a"), "msg_id": .string("9080402"), "targets": .array([.string("3000804b")])]),
                    ]),
                    // File 2: not resolved (expired)
                    .object([
                        "cmd": .string("forward"),
                        "now_ms": .int(baseTs + 15_000),
                        "args": .object(["conv_id": .string("3000804a"), "msg_id": .string("9080402"), "targets": .array([.string("3000804b")])]),
                    ]),
                    // File 3: resolved, send_files fails
                    .object([
                        "cmd": .string("forward"),
                        "now_ms": .int(baseTs + 16_000),
                        "args": .object(["conv_id": .string("3000804a"), "msg_id": .string("9080402"), "targets": .array([.string("3000804b")])]),
                    ]),
                ]
            ),

            // 5. forward_other_kinds: location with text, and sticker with empty text.
            ForwardRecorderHarness.ScenarioDef(
                name: "forward_other_kinds",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000805",
                    displayName: "Forward User 5",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(8000000000500),
                        "history_freshness": .object(["3000805a": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3000805a", name: "Source 5", previewText: "Sticker", previewTsMs: baseTs + 2_000),
                            localConv(id: "3000805b", name: "Target 5"),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "9080501",
                                convId: "3000805a",
                                senderId: "3000805a",
                                text: "Coffee House - 123 Le Loi",
                                kind: .object([
                                    "type": .string("location"),
                                    "title": .string("Coffee House"),
                                    "address": .string("123 Le Loi"),
                                ]),
                                kindTag: "location",
                                tsMs: baseTs + 1_000,
                                menu: okMenu
                            ),
                            storedMsg(
                                id: "9080502",
                                convId: "3000805a",
                                senderId: "3000805a",
                                text: "",
                                kind: .object([
                                    "type": .string("sticker"),
                                    "url": .string("https://cdn.example.invalid/s1.webp"),
                                ]),
                                kindTag: "sticker",
                                tsMs: baseTs + 2_000,
                                menu: okMenu
                            ),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000805", displayName: "Forward User 5"),
                    MessageRecorderHarness.profileMeScript(uid: "2000805", displayName: "Forward User 5"),
                    ForwardRecorderHarness.httpScript(
                        path: "/api/message/sms",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9005001")])])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000805a")])]),
                    .object([
                        "cmd": .string("forward"),
                        "now_ms": .int(baseTs + 10_000),
                        "args": .object(["conv_id": .string("3000805a"), "msg_id": .string("9080501"), "targets": .array([.string("3000805b")])]),
                    ]),
                    .object([
                        "cmd": .string("forward"),
                        "now_ms": .int(baseTs + 11_000),
                        "args": .object(["conv_id": .string("3000805a"), "msg_id": .string("9080502"), "targets": .array([.string("3000805b")])]),
                    ]),
                ]
            ),

            // 6. multi_target: three targets, one failing; all failing; empty target list.
            ForwardRecorderHarness.ScenarioDef(
                name: "multi_target",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000806",
                    displayName: "Forward User 6",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(8000000000600),
                        "history_freshness": .object(["3000806a": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3000806a", name: "Source 6", previewText: "Multi", previewTsMs: baseTs + 1_000),
                            localConv(id: "3000806b", name: "Target 6B"),
                            localConv(id: "3000806c", name: "Target 6C"),
                            localConv(id: "g500806", isGroup: true, name: "Group 6", members: 3),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "9080601",
                                convId: "3000806a",
                                senderId: "3000806a",
                                text: "Broadcast forward",
                                tsMs: baseTs + 1_000,
                                menu: okMenu
                            ),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000806", displayName: "Forward User 6"),
                    MessageRecorderHarness.profileMeScript(uid: "2000806", displayName: "Forward User 6"),
                    // Partial success (2 of 3 succeed)
                    ForwardRecorderHarness.httpScript(
                        path: "/api/message/sms",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9006001")])])
                    ),
                    ForwardRecorderHarness.httpScript(
                        path: "/api/message/sms",
                        method: "POST",
                        json: .object(["error_code": .int(500), "error_message": .string("target 6C failed")])
                    ),
                    ForwardRecorderHarness.httpScript(
                        path: "/api/group/sendmsg",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9006002")])])
                    ),
                    // All failing
                    ForwardRecorderHarness.httpScript(
                        path: "/api/message/sms",
                        method: "POST",
                        json: .object(["error_code": .int(500), "error_message": .string("fail 1")])
                    ),
                    ForwardRecorderHarness.httpScript(
                        path: "/api/message/sms",
                        method: "POST",
                        json: .object(["error_code": .int(500), "error_message": .string("fail 2")])
                    ),
                    ForwardRecorderHarness.httpScript(
                        path: "/api/group/sendmsg",
                        method: "POST",
                        json: .object(["error_code": .int(500), "error_message": .string("fail 3")])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000806a")])]),
                    .object([
                        "cmd": .string("forward"),
                        "now_ms": .int(baseTs + 10_000),
                        "args": .object(["conv_id": .string("3000806a"), "msg_id": .string("9080601"), "targets": .array([])]),
                    ]),
                    .object(["snapshot": .string("after_empty_targets")]),
                    .object([
                        "cmd": .string("forward"),
                        "now_ms": .int(baseTs + 11_000),
                        "args": .object(["conv_id": .string("3000806a"), "msg_id": .string("9080601"), "targets": .array([.string("3000806b"), .string("3000806c"), .string("g500806")])]),
                    ]),
                    .object(["snapshot": .string("after_partial")]),
                    .object([
                        "cmd": .string("forward"),
                        "now_ms": .int(baseTs + 12_000),
                        "args": .object(["conv_id": .string("3000806a"), "msg_id": .string("9080601"), "targets": .array([.string("3000806b"), .string("3000806c"), .string("g500806")])]),
                    ]),
                ]
            ),

            // 7. selection: two forwardable plus one blocked (card, no request); all forwardable (request with more in order);
            // forward_all success ends the selection, failure keeps it.
            ForwardRecorderHarness.ScenarioDef(
                name: "selection",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000807",
                    displayName: "Forward User 7",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(8000000000700),
                        "history_freshness": .object(["3000807a": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3000807a", name: "Source 7", previewText: "Third", previewTsMs: baseTs + 3_000),
                            localConv(id: "3000807b", name: "Target 7"),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "9080701",
                                convId: "3000807a",
                                senderId: "3000807a",
                                text: "First selectable",
                                tsMs: baseTs + 1_000,
                                menu: okMenu
                            ),
                            storedMsg(
                                id: "9080702",
                                convId: "3000807a",
                                senderId: "3000807a",
                                text: "Blocked selectable",
                                tsMs: baseTs + 2_000,
                                menu: .object(["forward": .string("blocked")])
                            ),
                            storedMsg(
                                id: "9080703",
                                convId: "3000807a",
                                senderId: "3000807a",
                                text: "Third selectable",
                                tsMs: baseTs + 3_000,
                                menu: okMenu
                            ),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000807", displayName: "Forward User 7"),
                    MessageRecorderHarness.profileMeScript(uid: "2000807", displayName: "Forward User 7"),
                    // First forward_all fails for both messages
                    ForwardRecorderHarness.httpScript(
                        path: "/api/message/sms",
                        method: "POST",
                        json: .object(["error_code": .int(500), "error_message": .string("sel fail 1")])
                    ),
                    ForwardRecorderHarness.httpScript(
                        path: "/api/message/sms",
                        method: "POST",
                        json: .object(["error_code": .int(500), "error_message": .string("sel fail 2")])
                    ),
                    // Second forward_all succeeds for both messages
                    ForwardRecorderHarness.httpScript(
                        path: "/api/message/sms",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9007001")])])
                    ),
                    ForwardRecorderHarness.httpScript(
                        path: "/api/message/sms",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9007002")])])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000807a")])]),
                    .object(["cmd": .string("select"), "args": .object(["conv_id": .string("3000807a"), "ids": .array([.string("9080703"), .string("9080701"), .string("9080702")])])]),
                    .object(["cmd": .string("forward_selection")]),
                    .object(["snapshot": .string("after_blocked_selection")]),
                    .object(["cmd": .string("select"), "args": .object(["conv_id": .string("3000807a"), "ids": .array([])])]),
                    .object(["cmd": .string("select"), "args": .object(["conv_id": .string("3000807a"), "ids": .array([.string("9080703"), .string("9080701")])])]),
                    .object(["cmd": .string("forward_selection")]),
                    .object(["snapshot": .string("after_forward_selection")]),
                    .object([
                        "cmd": .string("forward_all"),
                        "now_ms": .int(baseTs + 10_000),
                        "args": .object(["targets": .array([.string("3000807b")])]),
                    ]),
                    .object(["snapshot": .string("after_forward_all_fail")]),
                    .object([
                        "cmd": .string("forward_all"),
                        "now_ms": .int(baseTs + 11_000),
                        "args": .object(["targets": .array([.string("3000807b")])]),
                    ]),
                ]
            ),

            // 8. e2ee_target: forward text into an E2EE 1-1 (goes through the U5 E2EE host call).
            ForwardRecorderHarness.ScenarioDef(
                name: "e2ee_target",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000808",
                    displayName: "Forward User 8",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(8000000000800),
                        "e2ee_threads": .array([.string("3000808b")]),
                        "history_freshness": .object(["3000808a": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3000808a", name: "Source 8", previewText: "Secret text", previewTsMs: baseTs + 1_000),
                            localConv(id: "3000808b", name: "E2EE Peer 8"),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "9080801",
                                convId: "3000808a",
                                senderId: "3000808a",
                                text: "Secret forward",
                                tsMs: baseTs + 1_000,
                                menu: okMenu
                            ),
                        ]),
                        "host_results": .object([
                            "send_e2ee_text": .array([
                                .object([
                                    "msg_id": .string("9008001"),
                                    "cli_msg_id": .string("8000000000800"),
                                    "ts_ms": .int(baseTs + 10_500),
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
                    MessageRecorderHarness.loginInfoScript(uid: "2000808", displayName: "Forward User 8"),
                    MessageRecorderHarness.profileMeScript(uid: "2000808", displayName: "Forward User 8"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000808a")])]),
                    .object([
                        "cmd": .string("forward"),
                        "now_ms": .int(baseTs + 10_000),
                        "args": .object(["conv_id": .string("3000808a"), "msg_id": .string("9080801"), "targets": .array([.string("3000808b")])]),
                    ]),
                    .object(["snapshot": .string("after_e2ee_ok")]),
                    .object([
                        "cmd": .string("forward"),
                        "now_ms": .int(baseTs + 11_000),
                        "args": .object(["conv_id": .string("3000808a"), "msg_id": .string("9080801"), "targets": .array([.string("3000808b")])]),
                    ]),
                ]
            ),

            // 9. forward_contact_card_e2ee: forward contact card (with and without phone) to a 1-1 target
            // in e2ee_threads (records today's Swift plain /api/message/contact behaviour as-is).
            ForwardRecorderHarness.ScenarioDef(
                name: "forward_contact_card_e2ee",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2000809",
                    displayName: "Forward User 9",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(8000000000900),
                        "e2ee_threads": .array([.string("3000809b")]),
                        "history_freshness": .object(["3000809a": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3000809a", name: "Source 9", previewText: "[Danh thiếp] Card NoPhone", previewTsMs: baseTs + 2_000),
                            localConv(id: "3000809b", name: "E2EE Peer 9"),
                        ]),
                        "local_messages": .array([
                            storedMsg(
                                id: "9080901",
                                convId: "3000809a",
                                senderId: "3000809a",
                                text: "[Danh thiếp] Card Phone",
                                kind: .object([
                                    "type": .string("contactCard"),
                                    "name": .string("Card Phone"),
                                    "uid": .string("4000809"),
                                    "phone": .string("+84901234569"),
                                ]),
                                kindTag: "contactCard",
                                tsMs: baseTs + 1_000,
                                menu: okMenu
                            ),
                            storedMsg(
                                id: "9080902",
                                convId: "3000809a",
                                senderId: "3000809a",
                                text: "[Danh thiếp] Card NoPhone",
                                kind: .object([
                                    "type": .string("contactCard"),
                                    "name": .string("Card NoPhone"),
                                    "uid": .string("4000810"),
                                ]),
                                kindTag: "contactCard",
                                tsMs: baseTs + 2_000,
                                menu: okMenu
                            ),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2000809", displayName: "Forward User 9"),
                    MessageRecorderHarness.profileMeScript(uid: "2000809", displayName: "Forward User 9"),
                    ForwardRecorderHarness.httpScript(
                        path: "/api/message/contact",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9009001")])])
                    ),
                    ForwardRecorderHarness.httpScript(
                        path: "/api/message/contact",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9009002")])])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3000809a")])]),
                    .object([
                        "cmd": .string("forward"),
                        "now_ms": .int(baseTs + 10_000),
                        "args": .object(["conv_id": .string("3000809a"), "msg_id": .string("9080901"), "targets": .array([.string("3000809b")])]),
                    ]),
                    .object([
                        "cmd": .string("forward"),
                        "now_ms": .int(baseTs + 11_000),
                        "args": .object(["conv_id": .string("3000809a"), "msg_id": .string("9080902"), "targets": .array([.string("3000809b")])]),
                    ]),
                ]
            ),
        ]
    }
}

// MARK: - Forward Recorder Harness

@MainActor
private final class ForwardTransitionRecorder {
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
                throw ForwardRecorderHarness.RecorderError.timeout(
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

enum ForwardRecorderHarness {
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
            .appendingPathComponent("olaz-forward-recorder-\(scenario.name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let tempPhotoDir = dataDir.appendingPathComponent("fwd-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tempPhotoDir, withIntermediateDirectories: true)

        let storage = RecorderStorageIsolation(prefix: "olaz.forward-recorder")
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
                .replacingString(tempPhotoDir.path, with: "<tmp>")
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

        // Scripted host handlers
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

        let fetchMediaDataQueue = scenario.seed["host_results"]?["fetch_media_data"]?.arrayValue ?? []
        var fetchMediaDataIndex = 0
        if scenario.seed["host_results"]?["fetch_media_data"] != nil {
            engine.fetchMediaDataHostHandler = { _ in
                guard fetchMediaDataIndex < fetchMediaDataQueue.count else {
                    return nil
                }
                let item = fetchMediaDataQueue[fetchMediaDataIndex]
                fetchMediaDataIndex += 1
                if let utf8 = item["data_utf8"]?.stringValue {
                    return Data(utf8.utf8)
                }
                if item["ok"]?.boolValue == true {
                    return Data("fake-cdn-photo-bytes".utf8)
                }
                return nil
            }
        }

        func parseComposerOutcome(_ item: CaseJSON) -> ComposerOutcome {
            switch item["outcome"]?.stringValue ?? "failed" {
            case "done": return .done
            case "cancelled": return .cancelled
            case "pending": return .pending(item["text"]?.stringValue ?? CardActionOutcome.defaultPending)
            default: return .failed(item["text"]?.stringValue ?? ComposerOutcome.genericFailure)
            }
        }

        let sendMediaQueue = scenario.seed["host_results"]?["send_media"]?.arrayValue ?? []
        var sendMediaIndex = 0
        if scenario.seed["host_results"]?["send_media"] != nil {
            engine.sendMediaHostHandler = { _ in
                guard sendMediaIndex < sendMediaQueue.count else {
                    return .failed(ComposerOutcome.genericFailure)
                }
                let item = sendMediaQueue[sendMediaIndex]
                sendMediaIndex += 1
                return parseComposerOutcome(item)
            }
        }

        let sendFilesQueue = scenario.seed["host_results"]?["send_files"]?.arrayValue ?? []
        var sendFilesIndex = 0
        if scenario.seed["host_results"]?["send_files"] != nil {
            engine.sendFilesHostHandler = { _ in
                guard sendFilesIndex < sendFilesQueue.count else {
                    return .failed(ComposerOutcome.genericFailure)
                }
                let item = sendFilesQueue[sendFilesIndex]
                sendFilesIndex += 1
                return parseComposerOutcome(item)
            }
        }

        var fwdPhotoCounter = 0
        engine.forwardTempPhotoURL = {
            fwdPhotoCounter += 1
            return tempPhotoDir.appendingPathComponent("fwd-\(fwdPhotoCounter).jpg")
        }

        var bootstrapLogs: [String] = []
        var sendLogs: [String] = []
        var actionLogs: [String] = []
        var lastSendResult: Bool?
        var results: [String: CaseJSON] = [:]

        func installLogHooks(forwardingTo existing: ((String) -> Void)?) {
            EngineLog.shared.onAppend = { rawLine in
                existing?(rawLine)
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
            case "apply_batch", "apply_parsed_events", "show_typing",
                 "resolve_media", "resolve_file", "fetch_media_data",
                 "send_media", "send_files", "send_e2ee_text":
                return true
            case "start_ws":
                return !suppressedTransports.contains("ws")
            case "start_long_poll":
                return !suppressedTransports.contains("long_poll")
            default:
                return false
            }
        }

        let transitionRecorder = ForwardTransitionRecorder(scenarioName: scenario.name) {
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
            engine.messages[convId]?.first(where: { $0.id == msgId || $0.clientId == msgId })
        }

        do {
            for (stepIndex, step) in scenario.steps.enumerated() {
                if let cmd = step["cmd"]?.stringValue {
                    let args = step["args"]
                    let fixedNowMs = step["now_ms"]?.int64Value
                    var keepNowMsForAsync = false
                    if let fixedNowMs {
                        engine.nowMs = { fixedNowMs }
                    }
                    defer {
                        if fixedNowMs != nil && !keepNowMsForAsync {
                            engine.nowMs = { Int64(Date().timeIntervalSince1970 * 1000) }
                        }
                    }

                    switch cmd {
                    case "start":
                        engine.start()
                        let engineAppend = EngineLog.shared.onAppend
                        installLogHooks(forwardingTo: engineAppend)
                    case "open":
                        _ = await engine.bootTask?.value
                        let id = args?["id"]?.stringValue ?? ""
                        engine.openConversation(id)
                        _ = await engine.openConversationTask?.value
                        await engine.awaitMarkReadTasksForRecording()
                        _ = await engine.persistConversationsTask?.value
                        await engine.settleForRecording()
                    case "close":
                        _ = await engine.bootTask?.value
                        engine.closeConversation()
                        await engine.settleForRecording()
                    case "apply_batch":
                        _ = await engine.bootTask?.value
                        let payloadJSON = substituteRuntimeURLs(args?["payload"] ?? .object([:]))
                        let payloadData = Data(payloadJSON.canonicalString().utf8)
                        let payload = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any] ?? [:]
                        let defaultCmd = UInt16(args?["default_cmd"]?.int64Value ?? 501)
                        let fallbackConvId = args?["fallback_conv_id"]?.stringValue
                        let isGroupHint = args?["is_group_hint"]?.boolValue ?? false
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
                    case "request_forward":
                        _ = await engine.bootTask?.value
                        let convId = args?["conv_id"]?.stringValue ?? ""
                        let msgId = args?["msg_id"]?.stringValue ?? ""
                        guard let msg = findMessage(convId: convId, msgId: msgId) else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "request_forward missing msg \(msgId) in \(convId)")
                        }
                        engine.requestForward(msg)
                    case "select":
                        _ = await engine.bootTask?.value
                        let convId = args?["conv_id"]?.stringValue ?? ""
                        let ids = args?["ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
                        if ids.isEmpty {
                            engine.endSelection()
                        } else {
                            guard let firstMsg = findMessage(convId: convId, msgId: ids[0]) else {
                                throw RecorderError.invalidStep(scenario: scenario.name, detail: "select missing first msg \(ids[0]) in \(convId)")
                            }
                            engine.beginSelection(firstMsg)
                            for id in ids.dropFirst() {
                                engine.toggleSelection(id)
                            }
                        }
                    case "forward_selection":
                        _ = await engine.bootTask?.value
                        engine.forwardSelection()
                    case "forward":
                        _ = await engine.bootTask?.value
                        let convId = args?["conv_id"]?.stringValue ?? ""
                        let msgId = args?["msg_id"]?.stringValue ?? ""
                        let targets = args?["targets"]?.arrayValue?.compactMap(\.stringValue) ?? []
                        guard let msg = findMessage(convId: convId, msgId: msgId) else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "forward missing msg \(msgId) in \(convId)")
                        }
                        let outcome = await engine.forward(msg, to: targets)
                        await engine.settleForRecording()
                        _ = await engine.persistConversationsTask?.value
                        results["\(stepIndex)"] = ForwardSnapshot.encodeOutcome(outcome)
                    case "forward_all":
                        _ = await engine.bootTask?.value
                        let targets = args?["targets"]?.arrayValue?.compactMap(\.stringValue) ?? []
                        let outcome = await engine.forwardAll(to: targets)
                        await engine.settleForRecording()
                        _ = await engine.persistConversationsTask?.value
                        results["\(stepIndex)"] = ForwardSnapshot.encodeOutcome(outcome)
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
                    let snap = await ForwardSnapshot.capture(
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
                await ForwardSnapshot.capture(
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

        if let val = seed["did_offer_initial_sync"]?.stringValue {
            try await store.setPreferenceString(key: "didOfferInitialSync", value: val)
        }
        if let val = seed["history_full_refresh_at"]?.stringValue {
            try await store.setPreferenceString(key: ZaloEngine.fullHistoryRefreshKey, value: val)
        } else if let n = seed["history_full_refresh_at"]?.int64Value {
            try await store.setPreferenceString(key: ZaloEngine.fullHistoryRefreshKey, value: "\(n)")
        }
        if let hiddenPinMD5 = seed["hidden_pin_md5"]?.stringValue {
            try await store.setPreferenceString(key: "hiddenPinMD5", value: hiddenPinMD5)
        }
        if let hiddenPinHash = seed["hidden_pin_hash"]?.stringValue {
            try await store.setPreferenceString(key: "hiddenPinHash", value: hiddenPinHash)
        }
        if let labelsPref = seed["labels_pref"], labelsPref != .null {
            try await store.setPreferenceData(key: "labels", data: Data(labelsPref.canonicalString().utf8))
        }
        if let prefsObj = seed["prefs"]?.objectValue {
            for (k, v) in prefsObj {
                if let s = v.stringValue {
                    try await store.setPreferenceString(key: k, value: s)
                }
            }
        }
        if let pinned = seed["pinned_ids"]?.arrayValue?.compactMap(\.stringValue) {
            try await store.setPreferenceStrings(key: "pinnedIds", value: pinned)
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
        if let archived = seed["archived_ids"]?.arrayValue?.compactMap(\.stringValue) {
            try await store.setPreferenceStrings(key: "archivedIds", value: archived)
        }
        if let aliases = seed["aliases"], aliases != .null {
            try await store.setPreferenceData(key: "aliases", data: Data(aliases.canonicalString().utf8))
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
        if let convs = seed["local_conversations"]?.arrayValue {
            let stored = convs.compactMap { row -> StoredConversation? in
                guard let id = row["id"]?.stringValue else { return nil }
                return StoredConversation(
                    id: id,
                    isGroup: row["is_group"]?.boolValue ?? false,
                    name: row["name"]?.stringValue ?? id,
                    avatar: row["avatar"]?.stringValue ?? "",
                    pinned: row["pinned"]?.boolValue ?? false,
                    members: Int(row["members"]?.int64Value ?? 0),
                    unread: Int(row["unread"]?.int64Value ?? 0),
                    previewText: row["preview_text"]?.stringValue ?? "",
                    previewTsMs: row["preview_ts_ms"]?.int64Value ?? 0,
                    previewFromMe: row["preview_from_me"]?.boolValue ?? false,
                    updatedAtMs: row["updated_at_ms"]?.int64Value ?? 0
                )
            }
            try await store.saveConversations(stored)
        }
        if let msgs = seed["local_messages"]?.arrayValue {
            let stored = msgs.compactMap { row -> StoredMessage? in
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
