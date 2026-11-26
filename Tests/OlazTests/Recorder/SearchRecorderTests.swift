import Foundation
import XCTest
@testable import Olaz

final class SearchRecorderTests: XCTestCase {
    func testSearchScenarios() async throws {
        try await SearchRecorderHarness.runDomainSuite(
            domain: "search",
            scenarios: Self.searchScenarios()
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
        isE2EE: Bool = false,
        quote: CaseJSON? = nil,
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
        if let quote { rawObj["quote"] = quote }
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

    private static func pad3(_ n: Int) -> String {
        String(format: "%03d", n)
    }

    // MARK: - Scenarios

    static func searchScenarios() -> [SearchRecorderHarness.ScenarioDef] {
        [
            // 1. match_kinds: every ChatMessage.Kind with the query in its matching field and one where it is not;
            // recalled and locked E2EE excluded; whitespace-only query.
            SearchRecorderHarness.ScenarioDef(
                name: "match_kinds",
                seed: SearchRecorderHarness.readySessionSeed(
                    userId: "2001401",
                    displayName: "Search User 1",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "history_freshness": .object(["3001401": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3001401", name: "Kinds Peer", previewText: "Kinds", previewTsMs: baseTs + 45_000),
                        ]),
                        "local_messages": .array([
                            // .text
                            storedMsg(id: "mk_01", convId: "3001401", senderId: "3001401", text: "Meet at kestrel gate", tsMs: baseTs + 1_000),
                            storedMsg(id: "mk_02", convId: "3001401", senderId: "3001401", text: "Meet at dawn", tsMs: baseTs + 2_000),
                            // .file
                            storedMsg(
                                id: "mk_03", convId: "3001401", senderId: "3001401", text: "[Tệp]",
                                kind: .object(["type": .string("file"), "name": .string("kestrel_report.pdf"), "size": .int(1024), "url": .string("https://cdn.example.invalid/f1")]),
                                kindTag: "file", tsMs: baseTs + 3_000
                            ),
                            storedMsg(
                                id: "mk_04", convId: "3001401", senderId: "3001401", text: "[Tệp]",
                                kind: .object(["type": .string("file"), "name": .string("other_report.pdf"), "size": .int(1024), "url": .string("https://cdn.example.invalid/kestrel_f2")]),
                                kindTag: "file", tsMs: baseTs + 4_000
                            ),
                            // .link
                            storedMsg(
                                id: "mk_05", convId: "3001401", senderId: "3001401", text: "[Link]",
                                kind: .object(["type": .string("link"), "title": .string("Kestrel Docs"), "url": .string("https://example.invalid/d1"), "thumbnail": .string(""), "description": .string("Plain summary"), "source": .string("example.invalid")]),
                                kindTag: "link", tsMs: baseTs + 5_000
                            ),
                            storedMsg(
                                id: "mk_06", convId: "3001401", senderId: "3001401", text: "[Link]",
                                kind: .object(["type": .string("link"), "title": .string("Plain Docs"), "url": .string("https://example.invalid/d2"), "thumbnail": .string(""), "description": .string("Details about kestrel migration"), "source": .string("example.invalid")]),
                                kindTag: "link", tsMs: baseTs + 6_000
                            ),
                            storedMsg(
                                id: "mk_07", convId: "3001401", senderId: "3001401", text: "[Link]",
                                kind: .object(["type": .string("link"), "title": .string("Plain Docs"), "url": .string("https://example.invalid/kestrel"), "thumbnail": .string(""), "description": .string("Plain summary"), "source": .string("kestrel.invalid")]),
                                kindTag: "link", tsMs: baseTs + 7_000
                            ),
                            // .contactCard
                            storedMsg(
                                id: "mk_08", convId: "3001401", senderId: "3001401", text: "[Danh thiếp]",
                                kind: .object(["type": .string("contactCard"), "name": .string("Kestrel Contact"), "uid": .string("3099001"), "avatar": .string(""), "phone": .string("0900000001"), "qr": .string(""), "oaLink": .string(""), "isOA": .bool(false)]),
                                kindTag: "contactCard", tsMs: baseTs + 8_000
                            ),
                            storedMsg(
                                id: "mk_09", convId: "3001401", senderId: "3001401", text: "[Danh thiếp]",
                                kind: .object(["type": .string("contactCard"), "name": .string("Plain Contact"), "uid": .string("kestrel_uid"), "avatar": .string(""), "phone": .string("kestrel_phone"), "qr": .string(""), "oaLink": .string(""), "isOA": .bool(false)]),
                                kindTag: "contactCard", tsMs: baseTs + 9_000
                            ),
                            // .location
                            storedMsg(
                                id: "mk_10", convId: "3001401", senderId: "3001401", text: "[Vị trí]",
                                kind: .object(["type": .string("location"), "title": .string("Kestrel Cafe"), "address": .string("District 1"), "hasCoordinates": .bool(false), "latitude": .int(0), "longitude": .int(0), "thumbnail": .string("")]),
                                kindTag: "location", tsMs: baseTs + 10_000
                            ),
                            storedMsg(
                                id: "mk_11", convId: "3001401", senderId: "3001401", text: "[Vị trí]",
                                kind: .object(["type": .string("location"), "title": .string("Corner Cafe"), "address": .string("12 Kestrel Street"), "hasCoordinates": .bool(false), "latitude": .int(0), "longitude": .int(0), "thumbnail": .string("")]),
                                kindTag: "location", tsMs: baseTs + 11_000
                            ),
                            storedMsg(
                                id: "mk_12", convId: "3001401", senderId: "3001401", text: "[Vị trí]",
                                kind: .object(["type": .string("location"), "title": .string("Corner Cafe"), "address": .string("District 1"), "hasCoordinates": .bool(false), "latitude": .int(0), "longitude": .int(0), "thumbnail": .string("https://cdn.example.invalid/kestrel_loc.png")]),
                                kindTag: "location", tsMs: baseTs + 12_000
                            ),
                            // .call
                            storedMsg(
                                id: "mk_13", convId: "3001401", senderId: "3001401", text: "[Cuộc gọi]",
                                kind: .object(["type": .string("call"), "video": .bool(false), "missed": .bool(false), "duration": .int(30), "title": .string("Kestrel Call"), "detail": .string("30s")]),
                                kindTag: "call", tsMs: baseTs + 13_000
                            ),
                            storedMsg(
                                id: "mk_14", convId: "3001401", senderId: "3001401", text: "[Cuộc gọi]",
                                kind: .object(["type": .string("call"), "video": .bool(true), "missed": .bool(true), "duration": .int(0), "title": .string("Video Call"), "detail": .string("kestrel missed")]),
                                kindTag: "call", tsMs: baseTs + 14_000
                            ),
                            storedMsg(
                                id: "mk_15", convId: "3001401", senderId: "3001401", text: "[Cuộc gọi]",
                                kind: .object(["type": .string("call"), "video": .bool(false), "missed": .bool(false), "duration": .int(15), "title": .string("Voice Call"), "detail": .string("15s")]),
                                kindTag: "call", tsMs: baseTs + 15_000
                            ),
                            // .ecard
                            storedMsg(
                                id: "mk_16", convId: "3001401", senderId: "3001401", text: "[Thiệp]",
                                kind: .object(["type": .string("ecard"), "style": .string("banner"), "image": .string(""), "thumb": .string(""), "title": .string("Kestrel Card"), "description": .string("Plain"), "actions": .array([]), "avatars": .array([]), "reminderTitle": .string(""), "reminderStart": .int(0), "reminderRepeat": .string("")]),
                                kindTag: "ecard", tsMs: baseTs + 16_000
                            ),
                            storedMsg(
                                id: "mk_17", convId: "3001401", senderId: "3001401", text: "[Thiệp]",
                                kind: .object(["type": .string("ecard"), "style": .string("banner"), "image": .string(""), "thumb": .string(""), "title": .string("Card"), "description": .string("Kestrel wishes"), "actions": .array([]), "avatars": .array([]), "reminderTitle": .string(""), "reminderStart": .int(0), "reminderRepeat": .string("")]),
                                kindTag: "ecard", tsMs: baseTs + 17_000
                            ),
                            storedMsg(
                                id: "mk_18", convId: "3001401", senderId: "3001401", text: "[Thiệp]",
                                kind: .object(["type": .string("ecard"), "style": .string("reminder"), "image": .string(""), "thumb": .string(""), "title": .string("Reminder"), "description": .string("Plain"), "actions": .array([]), "avatars": .array([]), "reminderTitle": .string("Kestrel meeting"), "reminderStart": .int(0), "reminderRepeat": .string("")]),
                                kindTag: "ecard", tsMs: baseTs + 18_000
                            ),
                            storedMsg(
                                id: "mk_19", convId: "3001401", senderId: "3001401", text: "[Thiệp]",
                                kind: .object(["type": .string("ecard"), "style": .string("banner"), "image": .string("https://cdn.example.invalid/kestrel.png"), "thumb": .string(""), "title": .string("Card"), "description": .string("Plain"), "actions": .array([.string("kestrel")]), "avatars": .array([]), "reminderTitle": .string("Daily"), "reminderStart": .int(0), "reminderRepeat": .string("kestrel")]),
                                kindTag: "ecard", tsMs: baseTs + 19_000
                            ),
                            // .oaMessage
                            storedMsg(
                                id: "mk_20", convId: "3001401", senderId: "3001401", text: "[Tin nhắn OA]",
                                kind: .object(["type": .string("oaMessage"), "parts": .array([.object(["header": .bool(true), "title": .string("Kestrel OA"), "description": .string("Summary"), "thumb": .string(""), "url": .string(""), "help": .string("")])])]),
                                kindTag: "oaMessage", tsMs: baseTs + 20_000
                            ),
                            storedMsg(
                                id: "mk_21", convId: "3001401", senderId: "3001401", text: "[Tin nhắn OA]",
                                kind: .object(["type": .string("oaMessage"), "parts": .array([
                                    .object(["header": .bool(true), "title": .string("OA Header"), "description": .string(""), "thumb": .string(""), "url": .string(""), "help": .string("")]),
                                    .object(["header": .bool(false), "title": .string("Row"), "description": .string("Details for kestrel order"), "thumb": .string(""), "url": .string(""), "help": .string("")]),
                                ])]),
                                kindTag: "oaMessage", tsMs: baseTs + 21_000
                            ),
                            storedMsg(
                                id: "mk_22", convId: "3001401", senderId: "3001401", text: "[Tin nhắn OA]",
                                kind: .object(["type": .string("oaMessage"), "parts": .array([.object(["header": .bool(true), "title": .string("OA Header"), "description": .string("Summary"), "thumb": .string(""), "url": .string("https://example.invalid/kestrel"), "help": .string("kestrel_help")])])]),
                                kindTag: "oaMessage", tsMs: baseTs + 22_000
                            ),
                            // .poll
                            storedMsg(
                                id: "mk_23", convId: "3001401", senderId: "3001401", text: "[Bình chọn]",
                                kind: .object(["type": .string("poll"), "question": .string("Choose kestrel?"), "header": .string("Vote"), "anonymous": .bool(false), "pollId": .string("p1"), "conversationId": .string("3001401")]),
                                kindTag: "poll", tsMs: baseTs + 23_000
                            ),
                            storedMsg(
                                id: "mk_24", convId: "3001401", senderId: "3001401", text: "[Bình chọn]",
                                kind: .object(["type": .string("poll"), "question": .string("Choose lunch?"), "header": .string("Kestrel Poll"), "anonymous": .bool(false), "pollId": .string("p2"), "conversationId": .string("3001401")]),
                                kindTag: "poll", tsMs: baseTs + 24_000
                            ),
                            storedMsg(
                                id: "mk_25", convId: "3001401", senderId: "3001401", text: "[Bình chọn]",
                                kind: .object(["type": .string("poll"), "question": .string("Choose lunch?"), "header": .string("Vote"), "anonymous": .bool(false), "pollId": .string("kestrel"), "conversationId": .string("3001401")]),
                                kindTag: "poll", tsMs: baseTs + 25_000
                            ),
                            // .stickerSet
                            storedMsg(
                                id: "mk_26", convId: "3001401", senderId: "3001401", text: "[Bộ sticker]",
                                kind: .object(["type": .string("stickerSet"), "title": .string("Kestrel Pack"), "thumb": .string("")]),
                                kindTag: "stickerSet", tsMs: baseTs + 26_000
                            ),
                            storedMsg(
                                id: "mk_27", convId: "3001401", senderId: "3001401", text: "[Bộ sticker]",
                                kind: .object(["type": .string("stickerSet"), "title": .string("Cute Pack"), "thumb": .string("https://cdn.example.invalid/kestrel.png")]),
                                kindTag: "stickerSet", tsMs: baseTs + 27_000
                            ),
                            // .zinstant
                            storedMsg(
                                id: "mk_28", convId: "3001401", senderId: "3001401", text: "[Thẻ]",
                                kind: .object(["type": .string("zinstant"), "title": .string("Kestrel Instant"), "text": .string("Body"), "thumb": .string("")]),
                                kindTag: "zinstant", tsMs: baseTs + 28_000
                            ),
                            storedMsg(
                                id: "mk_29", convId: "3001401", senderId: "3001401", text: "[Thẻ]",
                                kind: .object(["type": .string("zinstant"), "title": .string("Instant"), "text": .string("Kestrel body"), "thumb": .string("")]),
                                kindTag: "zinstant", tsMs: baseTs + 29_000
                            ),
                            storedMsg(
                                id: "mk_30", convId: "3001401", senderId: "3001401", text: "[Thẻ]",
                                kind: .object(["type": .string("zinstant"), "title": .string("Instant"), "text": .string("Body"), "thumb": .string("https://cdn.example.invalid/kestrel.png")]),
                                kindTag: "zinstant", tsMs: baseTs + 30_000
                            ),
                            // .notice
                            storedMsg(
                                id: "mk_31", convId: "3001401", senderId: "3001401", text: "[Thông báo]",
                                kind: .object(["type": .string("notice"), "symbol": .string("info.circle"), "text": .string("Kestrel joined")]),
                                kindTag: "notice", tsMs: baseTs + 31_000
                            ),
                            storedMsg(
                                id: "mk_32", convId: "3001401", senderId: "3001401", text: "[Thông báo]",
                                kind: .object(["type": .string("notice"), "symbol": .string("kestrel"), "text": .string("Alice joined")]),
                                kindTag: "notice", tsMs: baseTs + 32_000
                            ),
                            // Non-matching kinds (and photo caption via message.text)
                            storedMsg(
                                id: "mk_33", convId: "3001401", senderId: "3001401", text: "Photo kestrel caption",
                                kind: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/p1.jpg"), "width": .int(100), "height": .int(100)]),
                                kindTag: "photo", tsMs: baseTs + 33_000
                            ),
                            storedMsg(
                                id: "mk_34", convId: "3001401", senderId: "3001401", text: "",
                                kind: .object(["type": .string("photo"), "url": .string("https://cdn.example.invalid/kestrel.jpg"), "width": .int(100), "height": .int(100)]),
                                kindTag: "photo", tsMs: baseTs + 34_000
                            ),
                            storedMsg(
                                id: "mk_35", convId: "3001401", senderId: "3001401", text: "",
                                kind: .object(["type": .string("sticker"), "url": .string("https://cdn.example.invalid/kestrel_stk.png")]),
                                kindTag: "sticker", tsMs: baseTs + 35_000
                            ),
                            storedMsg(
                                id: "mk_36", convId: "3001401", senderId: "3001401", text: "",
                                kind: .object(["type": .string("gif"), "url": .string("https://cdn.example.invalid/kestrel.gif")]),
                                kindTag: "gif", tsMs: baseTs + 36_000
                            ),
                            storedMsg(
                                id: "mk_37", convId: "3001401", senderId: "3001401", text: "",
                                kind: .object(["type": .string("video"), "thumbnail": .string("https://cdn.example.invalid/kestrel.jpg"), "duration": .int(10), "url": .string("https://cdn.example.invalid/kestrel.mp4")]),
                                kindTag: "video", tsMs: baseTs + 37_000
                            ),
                            storedMsg(
                                id: "mk_38", convId: "3001401", senderId: "3001401", text: "",
                                kind: .object(["type": .string("voice"), "url": .string("https://cdn.example.invalid/kestrel.aac"), "duration": .int(5)]),
                                kindTag: "voice", tsMs: baseTs + 38_000
                            ),
                            storedMsg(
                                id: "mk_39", convId: "3001401", senderId: "3001401", text: "",
                                kind: .object(["type": .string("placeholder"), "symbol": .string("kestrel"), "text": .string("kestrel placeholder")]),
                                kindTag: "placeholder", tsMs: baseTs + 39_000
                            ),
                            storedMsg(
                                id: "mk_40", convId: "3001401", senderId: "3001401", text: "",
                                kind: .object(["type": .string("system")]),
                                kindTag: "system", tsMs: baseTs + 40_000
                            ),
                            storedMsg(
                                id: "mk_41", convId: "3001401", senderId: "3001401", text: "",
                                kind: .object(["type": .string("unsupported"), "rawType": .string("kestrel")]),
                                kindTag: "unsupported", tsMs: baseTs + 41_000
                            ),
                            // Excluded even when message.text contains query
                            storedMsg(
                                id: "mk_42", convId: "3001401", senderId: "3001401", text: "kestrel recalled",
                                kind: .object(["type": .string("recalled")]),
                                kindTag: "recalled", tsMs: baseTs + 42_000
                            ),
                            storedMsg(
                                id: "mk_43", convId: "3001401", senderId: "3001401", text: "kestrel e2ee locked",
                                kind: .object(["type": .string("placeholder"), "symbol": .string("lock"), "text": .string("locked")]),
                                kindTag: "placeholder", tsMs: baseTs + 43_000, status: "e2ee_locked", isE2EE: true
                            ),
                        ]),
                    ]
                ),
                server: [
                    SearchRecorderHarness.loginInfoScript(uid: "2001401", displayName: "Search User 1"),
                    SearchRecorderHarness.profileMeScript(uid: "2001401", displayName: "Search User 1"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3001401")])]),
                    .object([
                        "cmd": .string("search"),
                        "args": .object(["conv_id": .string("3001401"), "query": .string("kestrel"), "limit": .int(100)]),
                    ]),
                    .object([
                        "cmd": .string("search"),
                        "args": .object(["conv_id": .string("3001401"), "query": .string("   \n\t  ")]),
                    ]),
                ]
            ),

            // 2. match_case_vietnamese: upper/lower case, diacritics (Đ/đ, Ấ), query with surrounding spaces,
            // checked across both in-memory (opened) and SQLite-only (unopened) conversations.
            SearchRecorderHarness.ScenarioDef(
                name: "match_case_vietnamese",
                seed: SearchRecorderHarness.readySessionSeed(
                    userId: "2001402",
                    displayName: "Search User 2",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "history_freshness": .object([
                            "3001402a": .string("up_to_date"),
                            "3001402b": .string("up_to_date"),
                        ]),
                        "local_conversations": .array([
                            localConv(id: "3001402a", name: "VN Mem", previewText: "Đấu ấm", previewTsMs: baseTs + 9_000),
                            localConv(id: "3001402b", name: "VN Store", previewText: "Đà Nẵng", previewTsMs: baseTs + 9_000),
                        ]),
                        "local_messages": .array([
                            storedMsg(id: "vn_m1", convId: "3001402a", senderId: "3001402a", text: "Đấu ấm chiều nay", tsMs: baseTs + 1_000),
                            storedMsg(id: "vn_m2", convId: "3001402a", senderId: "3001402a", text: "đấu ấm mùa đông", tsMs: baseTs + 2_000),
                            storedMsg(id: "vn_m3", convId: "3001402a", senderId: "3001402a", text: "ĐẤU ẤM", tsMs: baseTs + 3_000),
                            storedMsg(id: "vn_m4", convId: "3001402a", senderId: "3001402a", text: "dau am", tsMs: baseTs + 4_000),
                            storedMsg(id: "vn_m5", convId: "3001402a", senderId: "3001402a", text: "Đấu ắm", tsMs: baseTs + 5_000),
                            storedMsg(id: "vn_m6", convId: "3001402a", senderId: "3001402a", text: "Đấu ẩm", tsMs: baseTs + 6_000),
                            storedMsg(id: "vn_m7", convId: "3001402a", senderId: "3001402a", text: "Đà Nẵng cuối tuần", tsMs: baseTs + 7_000),
                            storedMsg(id: "vn_m8", convId: "3001402a", senderId: "3001402a", text: "da nang cuoi tuan", tsMs: baseTs + 8_000),
                            storedMsg(id: "vn_s1", convId: "3001402b", senderId: "3001402b", text: "Đấu ấm chiều nay", tsMs: baseTs + 1_000),
                            storedMsg(id: "vn_s2", convId: "3001402b", senderId: "3001402b", text: "ĐẤU ẤM", tsMs: baseTs + 2_000),
                            storedMsg(id: "vn_s3", convId: "3001402b", senderId: "3001402b", text: "dau am", tsMs: baseTs + 3_000),
                            storedMsg(id: "vn_s4", convId: "3001402b", senderId: "3001402b", text: "Đấu ấn", tsMs: baseTs + 4_000),
                            storedMsg(id: "vn_s5", convId: "3001402b", senderId: "3001402b", text: "đà nẵng xanh", tsMs: baseTs + 5_000),
                            storedMsg(id: "vn_s6", convId: "3001402b", senderId: "3001402b", text: "ĐÁ NẴNG", tsMs: baseTs + 6_000),
                        ]),
                    ]
                ),
                server: [
                    SearchRecorderHarness.loginInfoScript(uid: "2001402", displayName: "Search User 2"),
                    SearchRecorderHarness.profileMeScript(uid: "2001402", displayName: "Search User 2"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3001402a")])]),
                    .object([
                        "cmd": .string("search"),
                        "args": .object(["conv_id": .string("3001402a"), "query": .string("  đấu ẤM  ")]),
                    ]),
                    .object([
                        "cmd": .string("search"),
                        "args": .object(["conv_id": .string("3001402a"), "query": .string("  ĐÀ NẴNG  ")]),
                    ]),
                    .object([
                        "cmd": .string("search"),
                        "args": .object(["conv_id": .string("3001402b"), "query": .string("  đấu ẤM  ")]),
                    ]),
                    .object([
                        "cmd": .string("search"),
                        "args": .object(["conv_id": .string("3001402b"), "query": .string("  ĐÀ NẴNG  ")]),
                    ]),
                ]
            ),

            // 3. search_memory_and_store: matches only in memory, only in the store, in both
            // (memory wins, recalled in memory hides the store copy), store copy keyed by client id.
            SearchRecorderHarness.ScenarioDef(
                name: "search_memory_and_store",
                seed: SearchRecorderHarness.readySessionSeed(
                    userId: "2001403",
                    displayName: "Search User 3",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "history_freshness": .object(["3001403": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3001403", name: "MemStore Peer", previewText: "Chatter 85", previewTsMs: baseTs + 85_000),
                        ]),
                        "local_messages": .array((1...85).map { i in
                            let id: String
                            let clientId: String
                            let text: String
                            var kind: CaseJSON? = nil
                            var kindTag = "text"
                            var status = "sent"
                            var isE2EE = false
                            switch i {
                            case 1:
                                id = "ms_001"; clientId = "cli_ms_001"
                                text = "aurora store recalled"
                                kind = .object(["type": .string("recalled")]); kindTag = "recalled"
                            case 2:
                                id = "ms_002"; clientId = "cli_ms_002"
                                text = "aurora store only"
                            case 3:
                                id = "ms_003"; clientId = "cli_store_keyed"
                                text = "aurora store keyed"
                            case 4:
                                id = "ms_004"; clientId = "cli_ms_004"
                                text = "aurora recalled in mem"
                            case 5:
                                id = "srv_005"; clientId = "cli_005"
                                text = "aurora store twin"
                            case 6:
                                id = "ms_006"; clientId = "cli_ms_006"
                                text = "aurora store locked"
                                kind = .object(["type": .string("placeholder"), "symbol": .string("lock"), "text": .string("locked")])
                                kindTag = "placeholder"; status = "e2ee_locked"; isE2EE = true
                            case 50:
                                id = "ms_050"; clientId = "cli_ms_050"
                                text = "aurora in both"
                            default:
                                id = "ms_\(pad3(i))"; clientId = "cli_ms_\(pad3(i))"
                                text = "Chatter #\(i)"
                            }
                            return storedMsg(
                                id: id,
                                convId: "3001403",
                                clientId: clientId,
                                senderId: "3001403",
                                text: text,
                                kind: kind,
                                kindTag: kindTag,
                                tsMs: baseTs + Int64(i) * 1_000,
                                status: status,
                                isE2EE: isE2EE
                            )
                        }),
                    ]
                ),
                server: [
                    SearchRecorderHarness.loginInfoScript(uid: "2001403", displayName: "Search User 3"),
                    SearchRecorderHarness.profileMeScript(uid: "2001403", displayName: "Search User 3"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    // Opens newest 50 (ts 36s..85s), leaving ts 1s..35s only in the store.
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3001403")])]),
                    // Recalled in memory hides the store copy ms_004 (ts 4s is older than the 25-before-90s window).
                    .object([
                        "cmd": .string("ensure_loaded"),
                        "args": .object([
                            "conv_id": .string("3001403"),
                            "message": .object([
                                "id": .string("ms_004"),
                                "conv_id": .string("3001403"),
                                "sender_id": .string("3001403"),
                                "kind": .object(["type": .string("recalled")]),
                                "text": .string(""),
                                "date_ms": .int(baseTs + 90_000),
                            ]),
                        ]),
                    ]),
                    // Memory copy keyed by clientId cli_005 dedupes and wins over store srv_005 (clientId cli_005).
                    .object([
                        "cmd": .string("ensure_loaded"),
                        "args": .object([
                            "conv_id": .string("3001403"),
                            "message": .object([
                                "id": .string("cli_005"),
                                "client_id": .string("cli_005"),
                                "conv_id": .string("3001403"),
                                "sender_id": .string("2001403"),
                                "is_mine": .bool(true),
                                "kind": .object(["type": .string("text")]),
                                "text": .string("aurora mem twin"),
                                "date_ms": .int(baseTs + 91_000),
                            ]),
                        ]),
                    ]),
                    // Unsaved match only in memory.
                    .object([
                        "cmd": .string("ensure_loaded"),
                        "args": .object([
                            "conv_id": .string("3001403"),
                            "message": .object([
                                "id": .string("ms_mem_only"),
                                "client_id": .string("cli_mem_only"),
                                "conv_id": .string("3001403"),
                                "sender_id": .string("2001403"),
                                "is_mine": .bool(true),
                                "kind": .object(["type": .string("text")]),
                                "text": .string("aurora memory only"),
                                "date_ms": .int(baseTs + 92_000),
                            ]),
                        ]),
                    ]),
                    .object([
                        "cmd": .string("search"),
                        "args": .object(["conv_id": .string("3001403"), "query": .string("aurora")]),
                    ]),
                ]
            ),

            // 4. search_pending_delete: rows hidden by an undo bar excluded from both sources, by id and by client id.
            SearchRecorderHarness.ScenarioDef(
                name: "search_pending_delete",
                seed: SearchRecorderHarness.readySessionSeed(
                    userId: "2001404",
                    displayName: "Search User 4",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "history_freshness": .object(["3001404": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3001404", name: "PendingDel Peer", previewText: "Chatter 60", previewTsMs: baseTs + 60_000),
                        ]),
                        "local_messages": .array((1...60).map { i in
                            let id: String
                            let clientId: String
                            let text: String
                            switch i {
                            case 2:
                                id = "srv_pd_002"; clientId = "cli_pd_twin"
                                text = "comet store by client id"
                            case 50:
                                id = "pd_050"; clientId = "cli_pd_050"
                                text = "comet visible"
                            case 51:
                                id = "pd_051"; clientId = "cli_pd_051"
                                text = "comet pending by id"
                            default:
                                id = "pd_\(pad3(i))"; clientId = "cli_pd_\(pad3(i))"
                                text = "Chatter #\(i)"
                            }
                            return storedMsg(
                                id: id,
                                convId: "3001404",
                                clientId: clientId,
                                senderId: "3001404",
                                text: text,
                                tsMs: baseTs + Int64(i) * 1_000
                            )
                        }),
                    ]
                ),
                server: [
                    SearchRecorderHarness.loginInfoScript(uid: "2001404", displayName: "Search User 4"),
                    SearchRecorderHarness.profileMeScript(uid: "2001404", displayName: "Search User 4"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3001404")])]),
                    .object([
                        "cmd": .string("ensure_loaded"),
                        "args": .object([
                            "conv_id": .string("3001404"),
                            "message": .object([
                                "id": .string("cli_pd_twin"),
                                "client_id": .string("cli_pd_twin"),
                                "conv_id": .string("3001404"),
                                "sender_id": .string("2001404"),
                                "is_mine": .bool(true),
                                "kind": .object(["type": .string("text")]),
                                "text": .string("comet mem twin"),
                                "date_ms": .int(baseTs + 65_000),
                            ]),
                        ]),
                    ]),
                    .object([
                        "cmd": .string("delete_many"),
                        "now_ms": .int(1_700_000_010_000),
                        "args": .object([
                            "conv_id": .string("3001404"),
                            "msg_ids": .array([.string("pd_051"), .string("cli_pd_twin")]),
                        ]),
                    ]),
                    .object([
                        "cmd": .string("answer_confirm"),
                        "now_ms": .int(1_700_000_010_000),
                        "args": .object(["ok": .bool(true)]),
                    ]),
                    .object([
                        "cmd": .string("search"),
                        "args": .object(["conv_id": .string("3001404"), "query": .string("comet")]),
                    ]),
                    .object(["snapshot": .string("during_undo")]),
                    .object([
                        "cmd": .string("undo_delete"),
                        "now_ms": .int(1_700_000_011_000),
                    ]),
                    .object([
                        "cmd": .string("search"),
                        "args": .object(["conv_id": .string("3001404"), "query": .string("comet")]),
                    ]),
                ]
            ),

            // 5. search_order_limit: equal dates ordered by id descending; limit 0, 1, 600 (clamped to 500), default 50.
            SearchRecorderHarness.ScenarioDef(
                name: "search_order_limit",
                seed: SearchRecorderHarness.readySessionSeed(
                    userId: "2001405",
                    displayName: "Search User 5",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "history_freshness": .object(["3001405": .string("up_to_date")]),
                        "local_conversations": .array([
                            localConv(id: "3001405", name: "Limit Peer", previewText: "Unrelated", previewTsMs: baseTs + 510_000),
                        ]),
                        "local_messages": .array(
                            (1...505).map { i in
                                let tsMs: Int64 = (i >= 503) ? (baseTs + 503_000) : (baseTs + Int64(i) * 1_000)
                                let text = (i >= 503) ? "horizon tie" : "horizon item \(i)"
                                return storedMsg(
                                    id: "h_\(pad3(i))",
                                    convId: "3001405",
                                    senderId: "3001405",
                                    text: text,
                                    tsMs: tsMs
                                )
                            } + [
                                storedMsg(
                                    id: "h_506_other",
                                    convId: "3001405",
                                    senderId: "3001405",
                                    text: "unrelated noise",
                                    tsMs: baseTs + 510_000
                                ),
                            ]
                        ),
                    ]
                ),
                server: [
                    SearchRecorderHarness.loginInfoScript(uid: "2001405", displayName: "Search User 5"),
                    SearchRecorderHarness.profileMeScript(uid: "2001405", displayName: "Search User 5"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3001405")])]),
                    .object([
                        "cmd": .string("search"),
                        "args": .object(["conv_id": .string("3001405"), "query": .string("horizon"), "limit": .int(0)]),
                    ]),
                    .object([
                        "cmd": .string("search"),
                        "args": .object(["conv_id": .string("3001405"), "query": .string("horizon"), "limit": .int(1)]),
                    ]),
                    .object([
                        "cmd": .string("search"),
                        "args": .object(["conv_id": .string("3001405"), "query": .string("horizon")]),
                    ]),
                    .object([
                        "cmd": .string("search"),
                        "args": .object(["conv_id": .string("3001405"), "query": .string("horizon"), "limit": .int(600)]),
                    ]),
                ]
            ),

            // 6. ensure_loaded: already loaded; older message loaded from store window (with has_more_history
            // set when older rows exist); pending deletes kept out; message not in store of this conv (merged);
            // of another conv (false).
            SearchRecorderHarness.ScenarioDef(
                name: "ensure_loaded",
                seed: SearchRecorderHarness.readySessionSeed(
                    userId: "2001406",
                    displayName: "Search User 6",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "history_freshness": .object([
                            "3001406a": .string("up_to_date"),
                            "3001406b": .string("up_to_date"),
                        ]),
                        "local_conversations": .array([
                            localConv(id: "3001406a", name: "Ensure A", previewText: "A90", previewTsMs: baseTs + 90_000),
                            localConv(id: "3001406b", name: "Ensure B", previewText: "B35", previewTsMs: baseTs + 35_000),
                        ]),
                        "local_messages": .array(
                            (1...90).map { i in
                                storedMsg(
                                    id: "e_\(pad3(i))",
                                    convId: "3001406a",
                                    senderId: "3001406a",
                                    text: "Conv A #\(i)",
                                    tsMs: baseTs + Int64(i) * 1_000
                                )
                            } + (1...35).map { i in
                                storedMsg(
                                    id: "b_\(pad3(i))",
                                    convId: "3001406b",
                                    senderId: "3001406b",
                                    text: "Conv B #\(i)",
                                    tsMs: baseTs + Int64(i) * 1_000
                                )
                            }
                        ),
                    ]
                ),
                server: [
                    SearchRecorderHarness.loginInfoScript(uid: "2001406", displayName: "Search User 6"),
                    SearchRecorderHarness.profileMeScript(uid: "2001406", displayName: "Search User 6"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    // Loads e_041..e_090 into memory.
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3001406a")])]),
                    // Already loaded -> true.
                    .object([
                        "cmd": .string("ensure_loaded"),
                        "args": .object(["conv_id": .string("3001406a"), "msg_id": .string("e_090")]),
                    ]),
                    // Pending-delete oldest loaded row e_041 so window before e_042 includes e_041 in SQLite.
                    .object([
                        "cmd": .string("delete_many"),
                        "now_ms": .int(1_700_000_010_000),
                        "args": .object(["conv_id": .string("3001406a"), "msg_ids": .array([.string("e_041")])]),
                    ]),
                    .object([
                        "cmd": .string("answer_confirm"),
                        "now_ms": .int(1_700_000_010_000),
                        "args": .object(["ok": .bool(true)]),
                    ]),
                    // Loads window around e_035 (e_010..e_040), keeping pending-deleted e_041 out.
                    .object([
                        "cmd": .string("ensure_loaded"),
                        "args": .object(["conv_id": .string("3001406a"), "msg_id": .string("e_035")]),
                    ]),
                    .object(["snapshot": .string("window_with_pending_delete_kept_out")]),
                    .object([
                        "cmd": .string("undo_delete"),
                        "now_ms": .int(1_700_000_011_000),
                    ]),
                    // Unopened 3001406b: loading around b_032 pulls b_007..b_035 and sets has_more_history = true.
                    .object([
                        "cmd": .string("ensure_loaded"),
                        "args": .object(["conv_id": .string("3001406b"), "msg_id": .string("b_032")]),
                    ]),
                    // Not in store, belongs to 3001406a -> merged, true.
                    .object([
                        "cmd": .string("ensure_loaded"),
                        "args": .object([
                            "conv_id": .string("3001406a"),
                            "message": .object([
                                "id": .string("e_mem_direct"),
                                "conv_id": .string("3001406a"),
                                "sender_id": .string("3001406a"),
                                "kind": .object(["type": .string("text")]),
                                "text": .string("Direct merge"),
                                "date_ms": .int(baseTs + 95_000),
                            ]),
                        ]),
                    ]),
                    // Not in store, belongs to another conversation -> false.
                    .object([
                        "cmd": .string("ensure_loaded"),
                        "args": .object([
                            "conv_id": .string("3001406a"),
                            "message": .object([
                                "id": .string("e_other_conv"),
                                "conv_id": .string("3001499"),
                                "sender_id": .string("3001499"),
                                "kind": .object(["type": .string("text")]),
                                "text": .string("Wrong conv"),
                                "date_ms": .int(baseTs + 96_000),
                            ]),
                        ]),
                    ]),
                ]
            ),

            // 7. load_quoted: quote ids in memory by id and by client id; only in the store (by id and by client id);
            // ids "0" / empty; legacy quote by text (mine only when sender is "Bạn"); recalled candidate skipped; nothing found.
            SearchRecorderHarness.ScenarioDef(
                name: "load_quoted",
                seed: SearchRecorderHarness.readySessionSeed(
                    userId: "2001407",
                    displayName: "Search User 7",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "history_freshness": .object([
                            "3001407a": .string("up_to_date"),
                            "3001407b": .string("up_to_date"),
                        ]),
                        "local_conversations": .array([
                            localConv(id: "3001407a", name: "Quote A", previewText: "Q60", previewTsMs: baseTs + 60_000),
                            localConv(id: "3001407b", name: "Quote B", previewText: "R60", previewTsMs: baseTs + 60_000),
                        ]),
                        "local_messages": .array(
                            (1...60).map { i in
                                let id = "q_\(pad3(i))"
                                let clientId = "cq_\(pad3(i))"
                                var isMine = false
                                var text = "Msg \(i)"
                                var kind: CaseJSON? = nil
                                var kindTag = "text"
                                var quote: CaseJSON? = nil
                                switch i {
                                case 5:
                                    text = "Target in store"
                                case 15:
                                    text = "Target in memory"
                                case 16:
                                    text = "Quoted by cli"
                                case 20:
                                    isMine = false; text = "Legacy shared"
                                case 21:
                                    isMine = true; text = "Legacy shared"
                                case 22:
                                    isMine = false; text = "Legacy shared"
                                case 23:
                                    isMine = true; text = "Legacy shared"
                                    kind = .object(["type": .string("recalled")]); kindTag = "recalled"
                                case 30:
                                    text = "Quote by id"
                                    quote = .object(["senderName": .string("Quote A"), "text": .string("Target in memory"), "msgId": .string("q_015"), "cliMsgId": .string("")])
                                case 31:
                                    text = "Quote by client id"
                                    quote = .object(["senderName": .string("Quote A"), "text": .string("Quoted by cli"), "msgId": .string("0"), "cliMsgId": .string("cq_016")])
                                case 32:
                                    text = "Legacy any sender"
                                    quote = .object(["senderName": .string("Quote A"), "text": .string("  Legacy shared  "), "msgId": .string(""), "cliMsgId": .string("")])
                                case 33:
                                    text = "Legacy mine only"
                                    quote = .object(["senderName": .string("Bạn"), "text": .string("Legacy shared"), "msgId": .string("0"), "cliMsgId": .string("0")])
                                case 34:
                                    text = "Missing keys do not fallback"
                                    quote = .object(["senderName": .string("Quote A"), "text": .string("Legacy shared"), "msgId": .string("missing_id"), "cliMsgId": .string("missing_cli")])
                                case 35:
                                    text = "Legacy empty text"
                                    quote = .object(["senderName": .string("Quote A"), "text": .string("   "), "msgId": .string(""), "cliMsgId": .string("")])
                                case 36:
                                    text = "No quote"
                                case 37:
                                    text = "Quote older store by id"
                                    quote = .object(["senderName": .string("Quote A"), "text": .string("Target in store"), "msgId": .string("q_005"), "cliMsgId": .string("")])
                                default:
                                    break
                                }
                                return storedMsg(
                                    id: id,
                                    convId: "3001407a",
                                    clientId: clientId,
                                    senderId: isMine ? "2001407" : "3001407a",
                                    senderName: isMine ? "Search User 7" : "Quote A",
                                    isMine: isMine,
                                    text: text,
                                    kind: kind,
                                    kindTag: kindTag,
                                    tsMs: baseTs + Int64(i) * 1_000,
                                    quote: quote
                                )
                            } + (1...60).map { i in
                                let id = "r_\(pad3(i))"
                                let clientId = "cr_\(pad3(i))"
                                var text = "Conv B \(i)"
                                var quote: CaseJSON? = nil
                                if i == 5 {
                                    text = "Store target by cli"
                                } else if i == 55 {
                                    text = "Quote store by cli"
                                    quote = .object(["senderName": .string("Quote B"), "text": .string("Store target by cli"), "msgId": .string("0"), "cliMsgId": .string("cr_005")])
                                }
                                return storedMsg(
                                    id: id,
                                    convId: "3001407b",
                                    clientId: clientId,
                                    senderId: "3001407b",
                                    senderName: "Quote B",
                                    text: text,
                                    tsMs: baseTs + Int64(i) * 1_000,
                                    quote: quote
                                )
                            }
                        ),
                    ]
                ),
                server: [
                    SearchRecorderHarness.loginInfoScript(uid: "2001407", displayName: "Search User 7"),
                    SearchRecorderHarness.profileMeScript(uid: "2001407", displayName: "Search User 7"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3001407a")])]),
                    .object(["cmd": .string("load_quoted"), "args": .object(["conv_id": .string("3001407a"), "msg_id": .string("q_030")])]),
                    .object(["cmd": .string("load_quoted"), "args": .object(["conv_id": .string("3001407a"), "msg_id": .string("q_031")])]),
                    .object(["cmd": .string("load_quoted"), "args": .object(["conv_id": .string("3001407a"), "msg_id": .string("q_032")])]),
                    .object(["cmd": .string("load_quoted"), "args": .object(["conv_id": .string("3001407a"), "msg_id": .string("q_033")])]),
                    .object(["cmd": .string("load_quoted"), "args": .object(["conv_id": .string("3001407a"), "msg_id": .string("q_034")])]),
                    .object(["cmd": .string("load_quoted"), "args": .object(["conv_id": .string("3001407a"), "msg_id": .string("q_035")])]),
                    .object(["cmd": .string("load_quoted"), "args": .object(["conv_id": .string("3001407a"), "msg_id": .string("q_036")])]),
                    .object(["cmd": .string("load_quoted"), "args": .object(["conv_id": .string("3001407a"), "msg_id": .string("q_037")])]),
                    .object(["cmd": .string("open"), "args": .object(["id": .string("3001407b")])]),
                    .object(["cmd": .string("load_quoted"), "args": .object(["conv_id": .string("3001407b"), "msg_id": .string("r_055")])]),
                ]
            ),
        ]
    }
}

// MARK: - SearchRecorderHarness

enum SearchRecorderHarness {
    struct ScenarioDef {
        let name: String
        let seed: CaseJSON
        let server: [CaseJSON]
        let steps: [CaseJSON]
        var slow: Bool = false
    }

    enum RecorderError: Error, CustomStringConvertible {
        case invalidSeed(scenario: String, detail: String)
        case invalidStep(scenario: String, detail: String)
        case timeout(scenario: String, detail: String)
        case unscriptedRequest(scenario: String, detail: String)

        var description: String {
            switch self {
            case .invalidSeed(let s, let d): return "[\(s)] Invalid seed: \(d)"
            case .invalidStep(let s, let d): return "[\(s)] Invalid step: \(d)"
            case .timeout(let s, let d): return "[\(s)] Timeout: \(d)"
            case .unscriptedRequest(let s, let d): return "[\(s)] Unscripted request: \(d)"
            }
        }
    }

    static func readySessionSeed(
        userId: String,
        displayName: String = "Search User",
        avatar: String = "https://cdn.example.invalid/me.jpg",
        phone: String = "+84900000100",
        send2MeId: String? = nil,
        zpwEnk: String = "0123456789abcdef",
        zpwSek: String = "saved.200.a0.sek_u14",
        suppress: [String] = ["long_poll"],
        extras: [String: CaseJSON] = [:]
    ) -> CaseJSON {
        MessageRecorderHarness.readySessionSeed(
            userId: userId,
            displayName: displayName,
            avatar: avatar,
            phone: phone,
            send2MeId: send2MeId,
            zpwEnk: zpwEnk,
            zpwSek: zpwSek,
            suppress: suppress,
            wsAuthManual: true,
            extras: extras
        )
    }

    static func loginInfoScript(
        uid: String,
        zpwSek: String = "saved.200.a0.sek_u14",
        displayName: String = "Search User",
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
        displayName: String = "Search User",
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
            .appendingPathComponent("olaz-search-recorder-\(scenario.name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let storage = RecorderStorageIsolation(prefix: "olaz.search-recorder")
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

        var bootstrapLogs: [String] = []
        var sendLogs: [String] = []
        var actionLogs: [String] = []
        var lastSendResult: Bool?
        var results: [String: CaseJSON] = [:]
        var activeActionTask: Task<Void, Never>?

        func installLogHooks(forwardingTo existing: ((String) -> Void)?) {
            EngineLog.shared.onAppend = { rawLine in
                existing?(rawLine)
                if let sp = rawLine.firstIndex(of: " ") {
                    let msg = String(rawLine[rawLine.index(after: sp)...])
                    if msg.hasPrefix("bootstrap: ") { bootstrapLogs.append(msg) }
                    if msg.hasPrefix("sendText ") { sendLogs.append(msg) }
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

        let transitionRecorder = SearchTransitionRecorder(scenarioName: scenario.name) {
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
                            let reachedHeld = await server.waitForHeldHTTPRequests(atLeast: heldBefore + 1, timeoutMs: 2000)
                            if !reachedHeld && !completed {
                                try await waitForCondition(timeoutMs: 2000, description: "async sendText to hold or finish") {
                                    completed || server.heldHTTPCount() > heldBefore
                                }
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
                    case "delete_for_me":
                        _ = await engine.bootTask?.value
                        let convId = args?["conv_id"]?.stringValue ?? ""
                        let msgId = args?["msg_id"]?.stringValue ?? ""
                        let confirmed = args?["confirmed"]?.boolValue ?? false
                        if let msg = findMessageInMemory(convId: convId, msgId: msgId) {
                            engine.deleteForMe(msg, confirmed: confirmed)
                        }
                        await engine.awaitMessageActionTasksForRecording()
                    case "delete_many":
                        _ = await engine.bootTask?.value
                        let convId = args?["conv_id"]?.stringValue ?? ""
                        let msgIds = args?["msg_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
                        let msgs = msgIds.compactMap { findMessageInMemory(convId: convId, msgId: $0) }
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
                    case "answer_confirm":
                        _ = await engine.bootTask?.value
                        let ok = args?["ok"]?.boolValue ?? false
                        if let confirm = engine.messageConfirm {
                            engine.answerMessageConfirm(confirm, ok: ok)
                        }
                        await engine.awaitMessageActionTasksForRecording()
                    case "search":
                        _ = await engine.bootTask?.value
                        let convId = args?["conv_id"]?.stringValue ?? ""
                        let query = args?["query"]?.stringValue ?? ""
                        let matched: [ChatMessage]
                        if let limit = args?["limit"]?.int64Value {
                            matched = await engine.searchMessages(in: convId, query: query, limit: Int(limit))
                        } else {
                            matched = await engine.searchMessages(in: convId, query: query)
                        }
                        results[String(stepIndex)] = .array(matched.map { .string($0.id) })
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
                        results[String(stepIndex)] = .bool(loaded)
                    case "load_quoted":
                        _ = await engine.bootTask?.value
                        let convId = args?["conv_id"]?.stringValue ?? ""
                        let msgId = args?["msg_id"]?.stringValue ?? ""
                        guard let msg = await resolveMessage(convId: convId, msgId: msgId) else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "load_quoted could not find msg_id '\(msgId)' in '\(convId)'")
                        }
                        let quotedId = await engine.loadQuotedMessage(of: msg, in: convId)
                        results[String(stepIndex)] = quotedId.map(CaseJSON.string) ?? .null
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
                    let snap = await SearchSnapshot.capture(
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
                await SearchSnapshot.capture(
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

private final class SearchTransitionRecorder {
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
        let serialized = snap.canonicalString()
        if serialized == lastSerialized { return }
        lastSerialized = serialized
        history.append(snap)
        let pending = waiters
        waiters.removeAll()
        for cont in pending.values { cont.resume() }
    }

    @MainActor
    func advanceSearchToLatestSyncState() {
        recordTransition()
        searchCursor = history.count
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

        func matches(_ snap: CaseJSON) -> Bool {
            guard let phase = snap["phase"] else { return false }
            if let k = targetKind, phase["kind"]?.stringValue != k { return false }
            if let s = targetStep, phase["step"]?.stringValue != s { return false }
            return true
        }

        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while true {
            recordTransition()
            if let hit = (searchCursor..<history.count).first(where: { matches(history[$0]) }) {
                searchCursor = hit + 1
                return
            }
            let remaining = deadline - ContinuousClock.now
            if remaining <= .zero {
                throw SearchRecorderHarness.RecorderError.timeout(
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
