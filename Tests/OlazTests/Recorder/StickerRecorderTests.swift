import Foundation
import XCTest
@testable import Olaz

final class StickerRecorderTests: XCTestCase {
    func testStickerScenarios() async throws {
        try await StickerRecorderHarness.runDomainSuite(
            domain: "stickers",
            scenarios: Self.stickerScenarios()
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

    private static func recentRow(
        id: Int64,
        cateId: Int64,
        type: Int64 = 7,
        url: String? = nil
    ) -> CaseJSON {
        .object([
            "id": .int(id),
            "cateId": .int(cateId),
            "type": .int(type),
            "url": .string(url ?? "https://cdn.example.invalid/stickers/\(cateId)/\(id).png"),
        ])
    }

    // MARK: - Scenarios

    private static func stickerScenarios() -> [StickerRecorderHarness.ScenarioDef] {
        [
            // 1a. tabs: without recents; API failure, catalog download failure fallback,
            // filtering (id <= 0, exCateIds, "test" name, blank name), iconUrl/thumbImg/icon,
            // totalImage/total/default 16, < 5 not cached, >= 5 cached (no second HTTP).
            StickerRecorderHarness.ScenarioDef(
                name: "tabs",
                seed: StickerRecorderHarness.readySessionSeed(
                    userId: "2001301",
                    displayName: "Sticker User 1"
                ),
                server: [
                    StickerRecorderHarness.loginInfoScript(uid: "2001301", displayName: "Sticker User 1"),
                    StickerRecorderHarness.profileMeScript(uid: "2001301", displayName: "Sticker User 1"),
                    // Call 1: API failure
                    StickerRecorderHarness.httpScript(
                        path: "/api/message/sticker/category/list/v2",
                        method: "GET",
                        json: .object(["error_code": .int(112), "error_message": .string("Sticker API error")])
                    ),
                    // Call 2: dataUrl download fails -> fallback to builtinPack only
                    StickerRecorderHarness.httpScript(
                        path: "/api/message/sticker/category/list/v2",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "exCateIds": .array([]),
                                "dataUrl": .string("http://fake/sticker/catalog-fail.json"),
                            ]),
                        ])
                    ),
                    StickerRecorderHarness.httpScript(
                        path: "/sticker/catalog-fail.json",
                        method: "GET",
                        status: 500,
                        raw: "download error"
                    ),
                    // Call 3: < 5 valid downloaded packs -> filtered, sorted desc by id, not cached
                    StickerRecorderHarness.httpScript(
                        path: "/api/message/sticker/category/list/v2",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "exCateIds": .array([.int(102)]),
                                "dataUrl": .string("http://fake/sticker/catalog-small.json"),
                            ]),
                        ])
                    ),
                    StickerRecorderHarness.httpScript(
                        path: "/sticker/catalog-small.json",
                        method: "GET",
                        json: .array([
                            .object(["id": .int(0), "name": .string("Zero id")]),
                            .object(["id": .int(102), "name": .string("Excluded pack")]),
                            .object(["id": .int(103), "name": .string("Test Pack")]),
                            .object(["id": .int(104), "name": .string("   ")]),
                            .object(["id": .int(101), "name": .string("Pack A"), "iconUrl": .string("http://cdn.example.invalid/a.png"), "totalImage": .int(24)]),
                            .object(["id": .int(105), "name": .string("Pack B"), "thumbImg": .string("https://cdn.example.invalid/b.png"), "total": .int(12)]),
                            .object(["id": .int(106), "name": .string("Pack C"), "icon": .string("https://cdn.example.invalid/c.png")]),
                        ])
                    ),
                    // Call 4: >= 5 valid downloaded packs -> cached for Call 5
                    StickerRecorderHarness.httpScript(
                        path: "/api/message/sticker/category/list/v2",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "exCateIds": .array([]),
                                "dataUrl": .string("http://fake/sticker/catalog-full.json"),
                            ]),
                        ])
                    ),
                    StickerRecorderHarness.httpScript(
                        path: "/sticker/catalog-full.json",
                        method: "GET",
                        json: .array([
                            .object(["id": .int(201), "name": .string("Full 1"), "iconUrl": .string("https://cdn.example.invalid/f1.png"), "total": .int(10)]),
                            .object(["id": .int(202), "name": .string("Full 2"), "iconUrl": .string("https://cdn.example.invalid/f2.png"), "total": .int(15)]),
                            .object(["id": .int(203), "name": .string("Full 3"), "iconUrl": .string("https://cdn.example.invalid/f3.png"), "total": .int(20)]),
                            .object(["id": .int(204), "name": .string("Full 4"), "iconUrl": .string("https://cdn.example.invalid/f4.png"), "total": .int(25)]),
                            .object(["id": .int(205), "name": .string("Full 5"), "iconUrl": .string("https://cdn.example.invalid/f5.png"), "total": .int(30)]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("sticker_tabs")]),
                    .object(["cmd": .string("sticker_tabs")]),
                    .object(["cmd": .string("sticker_tabs")]),
                    .object(["cmd": .string("sticker_tabs")]),
                    // Call 5: hits cachedStickerCategories (0 HTTP requests)
                    .object(["cmd": .string("sticker_tabs")]),
                ]
            ),

            // 1b. tabs_with_recents: recent tab (-2) comes first when SQLite recentStickers is non-empty.
            StickerRecorderHarness.ScenarioDef(
                name: "tabs_with_recents",
                seed: StickerRecorderHarness.readySessionSeed(
                    userId: "2001311",
                    displayName: "Sticker User 1b",
                    extras: [
                        "recent_stickers": .array([
                            recentRow(id: 501, cateId: 10),
                            recentRow(id: 502, cateId: 10),
                        ]),
                    ]
                ),
                server: [
                    StickerRecorderHarness.loginInfoScript(uid: "2001311", displayName: "Sticker User 1b"),
                    StickerRecorderHarness.profileMeScript(uid: "2001311", displayName: "Sticker User 1b"),
                    StickerRecorderHarness.httpScript(
                        path: "/api/message/sticker/category/list/v2",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "exCateIds": .array([]),
                                "dataUrl": .string("http://fake/sticker/catalog-rec.json"),
                            ]),
                        ])
                    ),
                    StickerRecorderHarness.httpScript(
                        path: "/sticker/catalog-rec.json",
                        method: "GET",
                        json: .array([
                            .object(["id": .int(301), "name": .string("Cat 301"), "iconUrl": .string("https://cdn.example.invalid/301.png"), "total": .int(16)]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("sticker_tabs")]),
                ]
            ),

            // 2. tab_detail: recent tab (-2), builtin tab (0), data as array, data.stickers,
            // data["<id>"].stickers, none ({}), and API failure.
            StickerRecorderHarness.ScenarioDef(
                name: "tab_detail",
                seed: StickerRecorderHarness.readySessionSeed(
                    userId: "2001302",
                    displayName: "Sticker User 2",
                    extras: [
                        "recent_stickers": .array([
                            recentRow(id: 801, cateId: 5),
                            recentRow(id: 802, cateId: 6),
                        ]),
                    ]
                ),
                server: [
                    StickerRecorderHarness.loginInfoScript(uid: "2001302", displayName: "Sticker User 2"),
                    StickerRecorderHarness.profileMeScript(uid: "2001302", displayName: "Sticker User 2"),
                    // Shape 1: data as array
                    StickerRecorderHarness.httpScript(
                        path: "/api/message/sticker/category/sticker_detail",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .array([
                                .object(["id": .int(11), "cateId": .int(10), "stickerUrl": .string("https://cdn.example.invalid/s11.png")]),
                            ]),
                        ])
                    ),
                    // Shape 2: data.stickers
                    StickerRecorderHarness.httpScript(
                        path: "/api/message/sticker/category/sticker_detail",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "stickers": .array([
                                    .object(["id": .int(21), "stickerUrl": .string("https://cdn.example.invalid/s21.png")]),
                                ]),
                            ]),
                        ])
                    ),
                    // Shape 3: data["<id>"].stickers
                    StickerRecorderHarness.httpScript(
                        path: "/api/message/sticker/category/sticker_detail",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "30": .object([
                                    "stickers": .array([
                                        .object(["id": .int(31), "stickerUrl": .string("https://cdn.example.invalid/s31.png")]),
                                    ]),
                                ]),
                            ]),
                        ])
                    ),
                    // Shape 4: data empty object (none)
                    StickerRecorderHarness.httpScript(
                        path: "/api/message/sticker/category/sticker_detail",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([:]),
                        ])
                    ),
                    // Failure
                    StickerRecorderHarness.httpScript(
                        path: "/api/message/sticker/category/sticker_detail",
                        method: "GET",
                        json: .object(["error_code": .int(112), "error_message": .string("Detail fail")])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("stickers_in_tab"), "args": .object(["id": .int(-2)])]),
                    .object(["cmd": .string("stickers_in_tab"), "args": .object(["id": .int(0)])]),
                    .object(["cmd": .string("stickers_in_tab"), "args": .object(["id": .int(10)])]),
                    .object(["cmd": .string("stickers_in_tab"), "args": .object(["id": .int(20)])]),
                    .object(["cmd": .string("stickers_in_tab"), "args": .object(["id": .int(30)])]),
                    .object(["cmd": .string("stickers_in_tab"), "args": .object(["id": .int(40)])]),
                    .object(["cmd": .string("stickers_in_tab"), "args": .object(["id": .int(50)])]),
                ]
            ),

            // 3. normalize: explicit url vs CDN url (default cate 0 and non-0), id/cateId fallbacks,
            // sprite http->https rewrite, invalid frame counts (1, 201), duration clamping (0->120, 10->30, 2000->1000).
            StickerRecorderHarness.ScenarioDef(
                name: "normalize",
                seed: StickerRecorderHarness.readySessionSeed(
                    userId: "2001303",
                    displayName: "Sticker User 3"
                ),
                server: [
                    StickerRecorderHarness.loginInfoScript(uid: "2001303", displayName: "Sticker User 3"),
                    StickerRecorderHarness.profileMeScript(uid: "2001303", displayName: "Sticker User 3"),
                    StickerRecorderHarness.httpScript(
                        path: "/api/message/sticker/category/sticker_detail",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .array([
                                // Explicit stickerUrl + http sprite + duration 0 (-> 120)
                                .object([
                                    "id": .int(1),
                                    "cateId": .int(77),
                                    "stickerUrl": .string("https://cdn.example.invalid/explicit.png"),
                                    "stickerSpriteUrl": .string("http://cdn.example.invalid/sprite1.png"),
                                    "totalFrames": .int(8),
                                    "duration": .int(0),
                                ]),
                                // Fallback stickerId / cate_id + url key + frames 1 (rejected) + CDN check skipped
                                .object([
                                    "stickerId": .int(2),
                                    "cate_id": .int(77),
                                    "url": .string("https://cdn.example.invalid/alturl.png"),
                                    "stickerSpriteUrl": .string("https://cdn.example.invalid/sprite2.png"),
                                    "totalFrames": .int(1),
                                    "duration": .int(60),
                                ]),
                                // CDN fallback URL (no explicit url) + frames 201 (rejected)
                                .object([
                                    "sticker_id": .int(3),
                                    "stickerSpriteUrl": .string("https://cdn.example.invalid/sprite3.png"),
                                    "totalFrames": .int(201),
                                    "duration": .int(60),
                                ]),
                                // Duration 10 -> clamped to 30
                                .object([
                                    "id": .int(4),
                                    "stickerSpriteUrl": .string("https://cdn.example.invalid/sprite4.png"),
                                    "totalFrames": .int(2),
                                    "duration": .int(10),
                                ]),
                                // Duration 2000 -> clamped to 1000
                                .object([
                                    "id": .int(5),
                                    "stickerSpriteUrl": .string("https://cdn.example.invalid/sprite5.png"),
                                    "totalFrames": .int(200),
                                    "duration": .int(2000),
                                ]),
                                // Default cate 0 CDN URL
                                .object([
                                    "id": .int(6),
                                    "cateId": .int(0),
                                ]),
                            ]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("stickers_in_tab"), "args": .object(["id": .int(77)])]),
                ]
            ),

            // 4. search_and_suggest: empty text; results capped at 40 / 30; suggestion setting off;
            // E2EE 1-1 gets none (no HTTP); group always asks; API failures give nil / [].
            StickerRecorderHarness.ScenarioDef(
                name: "search_and_suggest",
                seed: StickerRecorderHarness.readySessionSeed(
                    userId: "2001304",
                    displayName: "Sticker User 4",
                    extras: [
                        "e2ee_threads": .array([.string("3001304")]),
                        "local_conversations": .array([
                            localConv(id: "3001304", name: "E2EE Peer 4"),
                            localConv(id: "3001314", name: "Plain Peer 4"),
                            localConv(id: "g501304", isGroup: true, name: "Group 4", members: 3),
                        ]),
                    ]
                ),
                server: [
                    StickerRecorderHarness.loginInfoScript(uid: "2001304", displayName: "Sticker User 4"),
                    StickerRecorderHarness.profileMeScript(uid: "2001304", displayName: "Sticker User 4"),
                    // Search 45 rows -> capped at 40
                    StickerRecorderHarness.httpScript(
                        path: "/api/message/sticker/search",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .array((1...45).map { i in
                                .object(["id": .int(Int64(i)), "cateId": .int(10)])
                            }),
                        ])
                    ),
                    // Search failure -> nil
                    StickerRecorderHarness.httpScript(
                        path: "/api/message/sticker/search",
                        method: "GET",
                        json: .object(["error_code": .int(112), "error_message": .string("Search fail")])
                    ),
                    // Suggest 35 rows via sugg_sticker on plain 1-1 -> capped at 30
                    StickerRecorderHarness.httpScript(
                        path: "/api/message/sticker/suggest/stickers",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "sugg_sticker": .array((1...35).map { i in
                                    .object(["id": .int(Int64(100 + i)), "cateId": .int(20)])
                                }),
                            ]),
                        ])
                    ),
                    // Suggest on group -> always asks (data.stickers)
                    StickerRecorderHarness.httpScript(
                        path: "/api/message/sticker/suggest/stickers",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "stickers": .array([
                                    .object(["id": .int(201), "cateId": .int(21)]),
                                ]),
                            ]),
                        ])
                    ),
                    // Suggest failure -> []
                    StickerRecorderHarness.httpScript(
                        path: "/api/message/sticker/suggest/stickers",
                        method: "GET",
                        json: .object(["error_code": .int(112), "error_message": .string("Suggest fail")])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    // Empty / whitespace -> [] without HTTP
                    .object(["cmd": .string("search_stickers"), "args": .object(["text": .string("   ")])]),
                    // Search 45 -> capped at 40
                    .object(["cmd": .string("search_stickers"), "args": .object(["text": .string(" chào ")])]),
                    // Search API error -> nil
                    .object(["cmd": .string("search_stickers"), "args": .object(["text": .string("fail")])]),
                    // E2EE 1-1 suggest -> [] without HTTP
                    .object(["cmd": .string("typing_suggestions"), "args": .object(["conv_id": .string("3001304"), "text": .string("hi")])]),
                    // Plain 1-1 suggest -> capped at 30
                    .object(["cmd": .string("typing_suggestions"), "args": .object(["conv_id": .string("3001314"), "text": .string("hi")])]),
                    // Group suggest -> asks server even with group id
                    .object(["cmd": .string("typing_suggestions"), "args": .object(["conv_id": .string("g501304"), "text": .string("team")])]),
                    // Suggest API failure -> []
                    .object(["cmd": .string("typing_suggestions"), "args": .object(["conv_id": .string("3001314"), "text": .string("err")])]),
                    // Turn setting off -> empty without HTTP
                    .object(["cmd": .string("set_sticker_suggest"), "args": .object(["enabled": .bool(false)])]),
                    .object(["cmd": .string("typing_suggestions"), "args": .object(["conv_id": .string("3001314"), "text": .string("hi")])]),
                ]
            ),

            // 5. send_sticker: plain 1-1, group, self conversation (menu flags),
            // E2EE ok / e2ee_failed / error, plain API failure,
            // recents move to front, dedupe by id, cap at 30 (seeded with 30 recents).
            StickerRecorderHarness.ScenarioDef(
                name: "send_sticker",
                seed: StickerRecorderHarness.readySessionSeed(
                    userId: "2001305",
                    displayName: "Sticker User 5",
                    send2MeId: "9201305",
                    extras: [
                        "next_client_id": .int(5000013050001),
                        "e2ee_threads": .array([.string("3001315")]),
                        "recent_stickers": .array((1...30).map { i in
                            recentRow(id: Int64(1000 + i), cateId: 1)
                        }),
                        "local_conversations": .array([
                            localConv(id: "3001305", name: "Plain Peer 5"),
                            localConv(id: "g501305", isGroup: true, name: "Group 5", members: 4),
                            localConv(id: "9201305", name: "Cloud của tôi"),
                            localConv(id: "3001315", name: "E2EE Peer 5"),
                        ]),
                        "host_results": .object([
                            "send_e2ee_sticker": .array([
                                .object([
                                    "msg_id": .string("9013004"),
                                    "cli_msg_id": .string("5000013050004"),
                                    "ts_ms": .int(1700000504000),
                                ]),
                                .string("e2ee_failed"),
                                .object([
                                    "error": .object([
                                        "code": .int(500),
                                        "message": .string("E2EE sticker API fail"),
                                        "url": .string("/api/e2ee/pc/message/sticker"),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    StickerRecorderHarness.loginInfoScript(uid: "2001305", displayName: "Sticker User 5", send2MeId: "9201305"),
                    StickerRecorderHarness.profileMeScript(uid: "2001305", displayName: "Sticker User 5"),
                    // 1-1 plain ok
                    StickerRecorderHarness.httpScript(
                        path: "/api/message/sticker",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9013001")])])
                    ),
                    // Group plain ok
                    StickerRecorderHarness.httpScript(
                        path: "/api/group/sticker",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9013002")])])
                    ),
                    // Self plain ok
                    StickerRecorderHarness.httpScript(
                        path: "/api/message/sticker",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9013003")])])
                    ),
                    // Plain 1-1 API fail
                    StickerRecorderHarness.httpScript(
                        path: "/api/message/sticker",
                        method: "POST",
                        json: .object(["error_code": .int(112), "error_message": .string("Sticker send failed")])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    // Plain 1-1: new sticker id 2001 pushes out oldest (1030), cap remains 30
                    .object([
                        "cmd": .string("send_sticker"),
                        "now_ms": .int(1700000501000),
                        "args": .object([
                            "conv_id": .string("3001305"),
                            "sticker": .object(["cate_id": .int(2), "id": .int(2001), "url": .string("https://cdn.example.invalid/stickers/2/2001.png")]),
                            "source": .string("category"),
                        ]),
                    ]),
                    // Group: existing recent id 1015 moves to front (deduped), count still 30
                    .object([
                        "cmd": .string("send_sticker"),
                        "now_ms": .int(1700000502000),
                        "args": .object([
                            "conv_id": .string("g501305"),
                            "sticker": .object(["cate_id": .int(1), "id": .int(1015), "url": .string("https://cdn.example.invalid/stickers/1/1015.png")]),
                            "source": .string("recent"),
                        ]),
                    ]),
                    // Self conversation: recall false, delete plain
                    .object([
                        "cmd": .string("send_sticker"),
                        "now_ms": .int(1700000503000),
                        "args": .object([
                            "conv_id": .string("9201305"),
                            "sticker": .object(["cate_id": .int(3), "id": .int(2002), "url": .string("https://cdn.example.invalid/stickers/3/2002.png")]),
                            "source": .string("search"),
                        ]),
                    ]),
                    // E2EE ok
                    .object([
                        "cmd": .string("send_sticker"),
                        "now_ms": .int(1700000504000),
                        "args": .object([
                            "conv_id": .string("3001315"),
                            "sticker": .object(["cate_id": .int(4), "id": .int(2003), "url": .string("https://cdn.example.invalid/stickers/4/2003.png")]),
                            "source": .string("suggestion"),
                            "typed": .string("chào"),
                            "index": .int(0),
                        ]),
                    ]),
                    // E2EE pre-send Signal failure
                    .object([
                        "cmd": .string("send_sticker"),
                        "now_ms": .int(1700000505000),
                        "args": .object([
                            "conv_id": .string("3001315"),
                            "sticker": .object(["cate_id": .int(4), "id": .int(2004), "url": .string("https://cdn.example.invalid/stickers/4/2004.png")]),
                            "source": .string("category"),
                        ]),
                    ]),
                    // E2EE API error
                    .object([
                        "cmd": .string("send_sticker"),
                        "now_ms": .int(1700000506000),
                        "args": .object([
                            "conv_id": .string("3001315"),
                            "sticker": .object(["cate_id": .int(4), "id": .int(2005), "url": .string("https://cdn.example.invalid/stickers/4/2005.png")]),
                            "source": .string("category"),
                        ]),
                    ]),
                    // Plain API error
                    .object([
                        "cmd": .string("send_sticker"),
                        "now_ms": .int(1700000507000),
                        "args": .object([
                            "conv_id": .string("3001305"),
                            "sticker": .object(["cate_id": .int(2), "id": .int(2006), "url": .string("https://cdn.example.invalid/stickers/2/2006.png")]),
                            "source": .string("category"),
                        ]),
                    ]),
                ]
            ),

            // 6. suggest_setting: default on, turn off, turn on.
            StickerRecorderHarness.ScenarioDef(
                name: "suggest_setting",
                seed: StickerRecorderHarness.readySessionSeed(
                    userId: "2001306",
                    displayName: "Sticker User 6"
                ),
                server: [
                    StickerRecorderHarness.loginInfoScript(uid: "2001306", displayName: "Sticker User 6"),
                    StickerRecorderHarness.profileMeScript(uid: "2001306", displayName: "Sticker User 6"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("start_bootstrap"), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("sticker_setting")]),
                    .object(["snapshot": .string("default")]),
                    .object(["cmd": .string("set_sticker_suggest"), "args": .object(["enabled": .bool(false)])]),
                    .object(["cmd": .string("sticker_setting")]),
                    .object(["snapshot": .string("after_off")]),
                    .object(["cmd": .string("set_sticker_suggest"), "args": .object(["enabled": .bool(true)])]),
                    .object(["cmd": .string("sticker_setting")]),
                ]
            ),

            // 7a. my_card: not signed in; signed in with phone; send with and without phone; API failure.
            StickerRecorderHarness.ScenarioDef(
                name: "my_card",
                seed: StickerRecorderHarness.readySessionSeed(
                    userId: "2001307",
                    displayName: "Card User 7",
                    phone: "+84900001307",
                    extras: [
                        "next_client_id": .int(5000013070001),
                        "local_conversations": .array([
                            localConv(id: "3001307", name: "Card Peer 7"),
                            localConv(id: "g501307", isGroup: true, name: "Card Group 7", members: 3),
                        ]),
                    ]
                ),
                server: [
                    StickerRecorderHarness.loginInfoScript(uid: "2001307", displayName: "Card User 7"),
                    StickerRecorderHarness.profileMeScript(uid: "2001307", displayName: "Card User 7", phone: "+84900001307"),
                    // 1-1 with phone
                    StickerRecorderHarness.httpScript(
                        path: "/api/message/contact",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9013701")])])
                    ),
                    // Group without phone
                    StickerRecorderHarness.httpScript(
                        path: "/api/group/contact",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9013702")])])
                    ),
                    // API failure
                    StickerRecorderHarness.httpScript(
                        path: "/api/message/contact",
                        method: "POST",
                        json: .object(["error_code": .int(112), "error_message": .string("Contact card failed")])
                    ),
                ],
                steps: [
                    // Before start -> profile is nil (not signed in)
                    .object(["cmd": .string("my_card")]),
                    .object([
                        "cmd": .string("send_my_card"),
                        "args": .object(["conv_id": .string("3001307"), "with_phone": .bool(true)]),
                    ]),
                    .object(["snapshot": .string("signed_out")]),
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("my_card")]),
                    .object([
                        "cmd": .string("send_my_card"),
                        "now_ms": .int(1700000701000),
                        "args": .object(["conv_id": .string("3001307"), "with_phone": .bool(true)]),
                    ]),
                    .object([
                        "cmd": .string("send_my_card"),
                        "now_ms": .int(1700000702000),
                        "args": .object(["conv_id": .string("g501307"), "with_phone": .bool(false)]),
                    ]),
                    .object([
                        "cmd": .string("send_my_card"),
                        "now_ms": .int(1700000703000),
                        "args": .object(["conv_id": .string("3001307"), "with_phone": .bool(true)]),
                    ]),
                ]
            ),

            // 7b. my_card_no_phone: signed in without phone -> with_phone: false; sending omits phone.
            StickerRecorderHarness.ScenarioDef(
                name: "my_card_no_phone",
                seed: StickerRecorderHarness.readySessionSeed(
                    userId: "2001317",
                    displayName: "Card User NoPhone",
                    phone: "",
                    extras: [
                        "next_client_id": .int(5000013170001),
                        "local_conversations": .array([
                            localConv(id: "3001317", name: "Card Peer 7b"),
                        ]),
                    ]
                ),
                server: [
                    StickerRecorderHarness.loginInfoScript(uid: "2001317", displayName: "Card User NoPhone"),
                    StickerRecorderHarness.profileMeScript(uid: "2001317", displayName: "Card User NoPhone", phone: ""),
                    StickerRecorderHarness.httpScript(
                        path: "/api/message/contact",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9013711")])])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("my_card")]),
                    .object([
                        "cmd": .string("send_my_card"),
                        "now_ms": .int(1700000711000),
                        "args": .object(["conv_id": .string("3001317"), "with_phone": .bool(true)]),
                    ]),
                ]
            ),

            // 7c. my_card_e2ee: E2EE 1-1 thread, signed in, send with and without phone (today goes plain).
            StickerRecorderHarness.ScenarioDef(
                name: "my_card_e2ee",
                seed: StickerRecorderHarness.readySessionSeed(
                    userId: "2001327",
                    displayName: "Card User E2EE",
                    phone: "+84900001327",
                    extras: [
                        "next_client_id": .int(5000013270001),
                        "e2ee_threads": .array([.string("3001327")]),
                        "local_conversations": .array([
                            localConv(id: "3001327", name: "Card E2EE Peer 7c"),
                        ]),
                    ]
                ),
                server: [
                    StickerRecorderHarness.loginInfoScript(uid: "2001327", displayName: "Card User E2EE"),
                    StickerRecorderHarness.profileMeScript(uid: "2001327", displayName: "Card User E2EE", phone: "+84900001327"),
                    // With phone (plain path today)
                    StickerRecorderHarness.httpScript(
                        path: "/api/message/contact",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9013721")])])
                    ),
                    // Without phone (plain path today)
                    StickerRecorderHarness.httpScript(
                        path: "/api/message/contact",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["msgId": .string("9013722")])])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object([
                        "cmd": .string("send_my_card"),
                        "now_ms": .int(1700000721000),
                        "args": .object(["conv_id": .string("3001327"), "with_phone": .bool(true)]),
                    ]),
                    .object([
                        "cmd": .string("send_my_card"),
                        "now_ms": .int(1700000722000),
                        "args": .object(["conv_id": .string("3001327"), "with_phone": .bool(false)]),
                    ]),
                ]
            ),

            // 8. reminders: info for 1-1, group, self; create ok with each repeat mode (0,1,2,3) and pin; failure text.
            StickerRecorderHarness.ScenarioDef(
                name: "reminders",
                seed: StickerRecorderHarness.readySessionSeed(
                    userId: "2001308",
                    displayName: "Reminder User 8",
                    send2MeId: "9201308",
                    extras: [
                        "local_conversations": .array([
                            localConv(id: "3001308", name: "Reminder Peer 8"),
                            localConv(id: "g501308", isGroup: true, name: "Reminder Group 8", members: 5),
                            localConv(id: "9201308", name: "Cloud của tôi"),
                        ]),
                    ]
                ),
                server: [
                    StickerRecorderHarness.loginInfoScript(uid: "2001308", displayName: "Reminder User 8", send2MeId: "9201308"),
                    StickerRecorderHarness.profileMeScript(uid: "2001308", displayName: "Reminder User 8"),
                    // 1-1 create (repeat 0)
                    StickerRecorderHarness.httpScript(
                        path: "/api/board/oneone/create",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["id": .string("rem_1")])])
                    ),
                    // Group create (repeat 1, pin false)
                    StickerRecorderHarness.httpScript(
                        path: "/api/board/topic/createv2",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["id": .string("rem_2")])])
                    ),
                    // Group create (repeat 2, pin true)
                    StickerRecorderHarness.httpScript(
                        path: "/api/board/topic/createv2",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["id": .string("rem_3")])])
                    ),
                    // Group create (repeat 3, pin true)
                    StickerRecorderHarness.httpScript(
                        path: "/api/board/topic/createv2",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["id": .string("rem_4")])])
                    ),
                    // Failure
                    StickerRecorderHarness.httpScript(
                        path: "/api/board/topic/createv2",
                        method: "POST",
                        json: .object(["error_code": .int(112), "error_message": .string("Reminder fail")])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("reminder_info"), "args": .object(["conv_id": .string("3001308")])]),
                    .object(["cmd": .string("reminder_info"), "args": .object(["conv_id": .string("g501308")])]),
                    .object(["cmd": .string("reminder_info"), "args": .object(["conv_id": .string("9201308")])]),
                    .object([
                        "cmd": .string("create_reminder"),
                        "args": .object([
                            "conv_id": .string("3001308"),
                            "title": .string("One-one call"),
                            "start_ms": .int(1700001000000),
                            "repeat": .int(0),
                            "pin": .bool(true),
                        ]),
                    ]),
                    .object([
                        "cmd": .string("create_reminder"),
                        "args": .object([
                            "conv_id": .string("g501308"),
                            "title": .string("Daily standup"),
                            "start_ms": .int(1700002000000),
                            "repeat": .int(1),
                            "pin": .bool(false),
                        ]),
                    ]),
                    .object([
                        "cmd": .string("create_reminder"),
                        "args": .object([
                            "conv_id": .string("g501308"),
                            "title": .string("Weekly sync"),
                            "start_ms": .int(1700003000000),
                            "repeat": .int(2),
                            "pin": .bool(true),
                        ]),
                    ]),
                    .object([
                        "cmd": .string("create_reminder"),
                        "args": .object([
                            "conv_id": .string("g501308"),
                            "title": .string("Monthly review"),
                            "start_ms": .int(1700004000000),
                            "repeat": .int(3),
                            "pin": .bool(true),
                        ]),
                    ]),
                    .object([
                        "cmd": .string("create_reminder"),
                        "args": .object([
                            "conv_id": .string("g501308"),
                            "title": .string("Will fail"),
                            "start_ms": .int(1700005000000),
                            "repeat": .int(0),
                            "pin": .bool(false),
                        ]),
                    ]),
                ]
            ),

            // 9. confirm_queue: answer shown confirm with one queued (next shows after 300 ms virtual time),
            // answer a stale confirm (ignored), drop all, composer report.
            StickerRecorderHarness.ScenarioDef(
                name: "confirm_queue",
                seed: StickerRecorderHarness.readySessionSeed(
                    userId: "2001309",
                    displayName: "Confirm User 9",
                    extras: [
                        "composer_confirm": .object([
                            "id": .string("c1"),
                            "conv_id": .string("3001309"),
                            "title": .string("Gửi dạng tệp?"),
                            "message": .string("Ảnh 1 quá lớn"),
                            "ok": .string("Gửi tệp"),
                            "cancel": .string("Huỷ"),
                        ]),
                        "queued_composer_confirms": .array([
                            .object([
                                "id": .string("c2"),
                                "conv_id": .string("3001309"),
                                "title": .string("Gửi dạng tệp?"),
                                "message": .string("Ảnh 2 quá lớn"),
                                "ok": .string("Gửi tệp"),
                                "cancel": .string("Huỷ"),
                            ]),
                            .object([
                                "id": .string("c3"),
                                "conv_id": .string("3001309"),
                                "title": .string("Gửi dạng tệp?"),
                                "message": .string("Ảnh 3 quá lớn"),
                                "ok": .string("Gửi tệp"),
                                "cancel": .string("Huỷ"),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    StickerRecorderHarness.loginInfoScript(uid: "2001309", displayName: "Confirm User 9"),
                    StickerRecorderHarness.profileMeScript(uid: "2001309", displayName: "Confirm User 9"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("start_bootstrap"), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("initial")]),
                    // Stale confirm ignored
                    .object([
                        "cmd": .string("answer_confirm"),
                        "args": .object([
                            "confirm": .object([
                                "id": .string("stale_99"),
                                "conv_id": .string("3001309"),
                                "title": .string("Old"),
                                "message": .string("Old"),
                                "ok": .string("OK"),
                                "cancel": .string("Cancel"),
                            ]),
                            "ok": .bool(true),
                        ]),
                    ]),
                    .object(["snapshot": .string("after_stale")]),
                    // Answer active c1 (with ok: false — Swift ignores ok)
                    .object(["cmd": .string("answer_confirm"), "args": .object(["ok": .bool(false)])]),
                    .object(["cmd": .string("advance_confirm_ms"), "args": .object(["ms": .int(299)])]),
                    .object(["snapshot": .string("at_299ms")]),
                    .object(["cmd": .string("advance_confirm_ms"), "args": .object(["ms": .int(1)])]),
                    .object(["snapshot": .string("at_300ms")]),
                    .object(["cmd": .string("drop_confirms")]),
                    .object(["snapshot": .string("after_drop")]),
                    .object([
                        "cmd": .string("composer_report"),
                        "args": .object([
                            "conv_id": .string("3001309"),
                            "outcome": .object(["status": .string("failed"), "text": .string("Không gửi được. Hãy thử lại.")]),
                        ]),
                    ]),
                ]
            ),
        ]
    }
}

// MARK: - Shared U13 Recorder Harness (stickers & composer)

enum StickerRecorderHarness {
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
        displayName: String = "Sticker User",
        phone: String = "+84900000100",
        send2MeId: String? = nil,
        suppress: [String] = ["ws", "long_poll"],
        extras: [String: CaseJSON] = [:]
    ) -> CaseJSON {
        var mergedExtras: [String: CaseJSON] = [
            "next_client_id": .int(5_000_013_000_100),
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
        zpwSek: String = "saved.200.a0.sek_u13",
        displayName: String = "Sticker User",
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
        displayName: String = "Sticker User",
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
    static func recordScenario(domain: String, _ scenario: ScenarioDef, shouldRecord: Bool = false) async throws -> CaseJSON {
        try await RecorderSuiteLock.shared.withLock {
            try await recordScenarioLocked(domain: domain, scenario, shouldRecord: shouldRecord)
        }
    }

    @MainActor
    private static func recordScenarioLocked(domain: String, _ scenario: ScenarioDef, shouldRecord: Bool = false) async throws -> CaseJSON {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-stickers-recorder-\(scenario.name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let storage = RecorderStorageIsolation(prefix: "olaz.stickers-recorder")
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
        let confirmClock = VirtualConfirmClock()
        engine.resetStickers()
        engine.resetComposer()
        engine.composerConfirmSleep = { ms in
            await confirmClock.sleep(ms: ms)
        }
        await engine.sessionClient.setRawDownloadURLTransform { url in
            if url.scheme == "https",
               let host = url.host,
               host == "127.0.0.1" || host == "localhost",
               var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                comps.scheme = "http"
                return comps.url ?? url
            }
            return url
        }

        defer {
            EngineLog.shared.onAppend = nil
            confirmClock.cancelAll()
            engine.resetStickers()
            engine.resetComposer()
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
        if let activeConfirm = scenario.seed["composer_confirm"], activeConfirm != .null {
            engine.composerConfirm = decodeConfirm(substituteRuntimeURLs(activeConfirm))
        }
        if let queuedArr = scenario.seed["queued_composer_confirms"]?.arrayValue {
            engine.queuedComposerConfirms = queuedArr.compactMap { decodeConfirm(substituteRuntimeURLs($0)) }
        }

        let e2eeStickerQueue = scenario.seed["host_results"]?["send_e2ee_sticker"]?.arrayValue ?? []
        var e2eeStickerIndex = 0
        if scenario.seed["host_results"]?["send_e2ee_sticker"] != nil {
            engine.sendE2EEStickerHostHandler = { args in
                guard e2eeStickerIndex < e2eeStickerQueue.count else {
                    throw ZaloSessionError(code: 500, message: "No scripted send_e2ee_sticker result", url: "/api/e2ee/pc/message/sticker")
                }
                let item = e2eeStickerQueue[e2eeStickerIndex]
                e2eeStickerIndex += 1
                if item.stringValue == "e2ee_failed" || item["status"]?.stringValue == "e2ee_failed" {
                    return nil
                }
                if let errObj = item["error"]?.objectValue {
                    let code = Int(errObj["code"]?.int64Value ?? 500)
                    let msg = errObj["message"]?.stringValue ?? "E2EE error"
                    let url = errObj["url"]?.stringValue ?? "/api/e2ee/pc/message/sticker"
                    throw ZaloSessionError(code: code, message: msg, url: url)
                }
                if let errMsg = item["error"]?.stringValue {
                    throw ZaloSessionError(code: 500, message: errMsg, url: "/api/e2ee/pc/message/sticker")
                }
                let cliId = args["client_id"] as? String ?? ""
                let msgId = item["msg_id"]?.stringValue ?? cliId
                let cliMsgId = item["cli_msg_id"]?.stringValue ?? cliId
                let tsMs = item["ts_ms"]?.int64Value ?? engine.nowMs()
                return SendMessageResult(msgId: msgId, cliMsgId: cliMsgId, tsMs: tsMs)
            }
        }

        let e2eeContactCardQueue = scenario.seed["host_results"]?["send_e2ee_contact_card"]?.arrayValue ?? []
        let hasScriptedContactCard = scenario.seed["host_results"]?["send_e2ee_contact_card"] != nil
        var e2eeContactCardIndex = 0
        engine.sendE2EEContactCardHostHandler = { args in
            let cliId = args["client_id"] as? String ?? ""
            if hasScriptedContactCard {
                guard e2eeContactCardIndex < e2eeContactCardQueue.count else {
                    throw ZaloSessionError(code: 500, message: "No scripted send_e2ee_contact_card result", url: "/api/e2ee/pc/message/forward")
                }
                let item = e2eeContactCardQueue[e2eeContactCardIndex]
                e2eeContactCardIndex += 1
                if let errObj = item["error"]?.objectValue {
                    let code = Int(errObj["code"]?.int64Value ?? 500)
                    let msg = errObj["message"]?.stringValue ?? "E2EE error"
                    let url = errObj["url"]?.stringValue ?? "/api/e2ee/pc/message/forward"
                    throw ZaloSessionError(code: code, message: msg, url: url)
                }
                if let errMsg = item["error"]?.stringValue {
                    throw ZaloSessionError(code: 500, message: errMsg, url: "/api/e2ee/pc/message/forward")
                }
                let msgId = item["msg_id"]?.stringValue ?? cliId
                let cliMsgId = item["cli_msg_id"]?.stringValue ?? cliId
                let tsMs = item["ts_ms"]?.int64Value ?? 0
                return SendMessageResult(msgId: msgId, cliMsgId: cliMsgId, tsMs: tsMs)
            }
            // Deterministic fallback when unscripted (matches Rust test harness for U13 item 13.3).
            return SendMessageResult(msgId: cliId, cliMsgId: cliId, tsMs: 0)
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

        let transitionRecorder = StickerTransitionRecorder(scenarioName: scenario.name) {
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
            for (stepIndex, step) in scenario.steps.enumerated() {
                if let cmd = step["cmd"]?.stringValue {
                    let args = step["args"]
                    let savedNowMs = engine.nowMs
                    if let ms = step["now_ms"]?.int64Value {
                        engine.nowMs = { ms }
                    }
                    defer {
                        engine.nowMs = savedNowMs
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
                    case "sticker_tabs":
                        let tabs = await engine.stickerTabs()
                        results["\(stepIndex)"] = normalizeRecordedURLs(StickerSnapshot.encodeStickerTabs(tabs))
                    case "stickers_in_tab":
                        guard let tabId = args?["id"]?.int64Value else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "stickers_in_tab requires args.id")
                        }
                        let list = await engine.stickers(inTab: Int(tabId))
                        results["\(stepIndex)"] = normalizeRecordedURLs(StickerSnapshot.encodeStickers(list))
                    case "search_stickers":
                        let text = args?["text"]?.stringValue ?? ""
                        let list = await engine.searchStickers(text)
                        results["\(stepIndex)"] = normalizeRecordedURLs(StickerSnapshot.encodeStickers(list))
                    case "typing_suggestions":
                        guard let convId = args?["conv_id"]?.stringValue else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "typing_suggestions requires args.conv_id")
                        }
                        let text = args?["text"]?.stringValue ?? ""
                        let list = await engine.typingStickerSuggestions(in: convId, text: text)
                        results["\(stepIndex)"] = normalizeRecordedURLs(StickerSnapshot.encodeStickers(list))
                    case "send_sticker":
                        guard let convId = args?["conv_id"]?.stringValue,
                              let stObj = args?["sticker"],
                              let cateId = stObj["cate_id"]?.int64Value,
                              let stickerId = stObj["id"]?.int64Value,
                              let urlStr = stObj["url"]?.stringValue,
                              let stickerURL = URL(string: urlStr) else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "send_sticker requires conv_id and sticker")
                        }
                        let sourceStr = args?["source"]?.stringValue ?? "category"
                        let source = StickerSource(rawValue: sourceStr) ?? .category
                        let typed = args?["typed"]?.stringValue
                        let index = Int(args?["index"]?.int64Value ?? -1)
                        let entry = StickerEntry(cateId: Int(cateId), stickerId: Int(stickerId), url: stickerURL)
                        let outcome = await engine.sendSticker(entry, in: convId, source: source, typed: typed, index: index)
                        await engine.settleForRecording()
                        results["\(stepIndex)"] = normalizeRecordedURLs(StickerSnapshot.encodeCardActionOutcome(outcome))
                    case "sticker_setting":
                        let setting = await engine.stickerSuggestSetting()
                        results["\(stepIndex)"] = StickerSnapshot.encodeSuggestSetting(setting)
                    case "set_sticker_suggest":
                        guard let enabled = args?["enabled"]?.boolValue else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "set_sticker_suggest requires args.enabled")
                        }
                        let setting = await engine.setStickerSuggest(enabled: enabled)
                        results["\(stepIndex)"] = StickerSnapshot.encodeSuggestSetting(setting)
                    case "my_card":
                        let info = await engine.myCard()
                        results["\(stepIndex)"] = normalizeRecordedURLs(StickerSnapshot.encodeMyCard(info))
                    case "send_my_card":
                        guard let convId = args?["conv_id"]?.stringValue,
                              let withPhone = args?["with_phone"]?.boolValue else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "send_my_card requires conv_id and with_phone")
                        }
                        if engine.phase == .ready {
                            try await waitForCondition(timeoutMs: 5000, description: "boot idle (start_bootstrap) before send_my_card") {
                                hostCalls.contains { $0["call"]?.stringValue == "start_bootstrap" }
                            }
                            await engine.settleForRecording()
                        }
                        let outcome = await engine.sendMyCard(to: convId, withPhone: withPhone)
                        await engine.settleForRecording()
                        results["\(stepIndex)"] = normalizeRecordedURLs(StickerSnapshot.encodeComposerOutcome(outcome))
                    case "reminder_info":
                        guard let convId = args?["conv_id"]?.stringValue else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "reminder_info requires args.conv_id")
                        }
                        let info = await engine.reminderComposeInfo(for: convId)
                        results["\(stepIndex)"] = StickerSnapshot.encodeReminderInfo(info)
                    case "create_reminder":
                        guard let convId = args?["conv_id"]?.stringValue,
                              let title = args?["title"]?.stringValue,
                              let startMs = args?["start_ms"]?.int64Value,
                              let repeatRaw = args?["repeat"]?.int64Value,
                              let repeatRule = ReminderRepeat(rawValue: Int(repeatRaw)),
                              let pin = args?["pin"]?.boolValue else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "create_reminder requires conv_id, title, start_ms, repeat, pin")
                        }
                        let start = Date(timeIntervalSince1970: Double(startMs) / 1000.0)
                        let outcome = await engine.createReminder(in: convId, title: title, start: start, repeat: repeatRule, pin: pin)
                        results["\(stepIndex)"] = StickerSnapshot.encodeComposerOutcome(outcome)
                    case "answer_confirm":
                        guard let ok = args?["ok"]?.boolValue else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "answer_confirm requires args.ok")
                        }
                        let confirm: ComposerConfirm? = {
                            if let explicit = args?["confirm"], explicit != .null {
                                return decodeConfirm(substituteRuntimeURLs(explicit))
                            }
                            return engine.composerConfirm
                        }()
                        guard let confirm else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "answer_confirm has no active confirm")
                        }
                        let expectsPromoteTimer = (engine.composerConfirm?.id == confirm.id) && !engine.queuedComposerConfirms.isEmpty
                        engine.answerComposerConfirm(confirm, ok: ok)
                        await engine.settleForRecording()
                        if expectsPromoteTimer {
                            await confirmClock.waitForTimerRegistration()
                        }
                    case "advance_confirm_ms":
                        guard let ms = args?["ms"]?.int64Value else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "advance_confirm_ms requires args.ms")
                        }
                        let fired = confirmClock.advance(by: ms)
                        if fired {
                            try await waitForCondition(timeoutMs: 2000, description: "composer confirm promotion") {
                                engine.composerConfirm != nil
                            }
                        }
                        await engine.settleForRecording()
                    case "drop_confirms":
                        engine.dropComposerConfirms()
                        await engine.settleForRecording()
                    case "composer_report":
                        let convId = args?["conv_id"]?.stringValue ?? ""
                        let outcomeObj = args?["outcome"]?.toFoundation() as? [String: Any]
                        let outcome = ComposerOutcome(json: outcomeObj)
                        engine.report(outcome, in: convId)
                    default:
                        throw RecorderError.invalidStep(scenario: scenario.name, detail: "Unknown cmd '\(cmd)'")
                    }
                } else if let predicate = step["await"] {
                    let timeoutMs = Int(step["timeout_ms"]?.int64Value ?? 5000)
                    transitionRecorder.advanceSearchToLatestSyncState()
                    try await transitionRecorder.awaitPredicate(predicate, timeoutMs: timeoutMs)
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
                    let snap = await StickerSnapshot.capture(
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
                await StickerSnapshot.capture(
                    from: engine,
                    bootstrapLogs: bootstrapLogs,
                    lastSendResult: lastSendResult,
                    sendLogs: sendLogs,
                    actionLogs: actionLogs,
                    results: results
                )
            )
            let requests = server.canonicalRequests().map { normalizeRecordedURLs($0) }

            await engine.sessionClient.setRawDownloadURLTransform(nil)
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
            await engine.sessionClient.setRawDownloadURLTransform(nil)
            engine.cancelTasksForRecording()
            engine.transportSettleTrace = nil
            server.stop()
            await engine.finishTearDownForRecording()
            throw error
        }
    }

    // MARK: - Seed & Script Helpers

    private static func decodeConfirm(_ json: CaseJSON) -> ComposerConfirm? {
        guard let obj = json.objectValue,
              let id = obj["id"]?.stringValue else { return nil }
        return ComposerConfirm(
            id: id,
            conversationId: obj["conv_id"]?.stringValue ?? "",
            title: obj["title"]?.stringValue ?? "",
            message: obj["message"]?.stringValue ?? "",
            ok: obj["ok"]?.stringValue ?? "OK",
            cancel: obj["cancel"]?.stringValue ?? "Cancel"
        )
    }

    private static func seedSQLiteStore(userId: String, dataDir: URL, seed: CaseJSON) async throws {
        let dbURL = dataDir
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(userId, isDirectory: true)
            .appendingPathComponent("history.sqlite3")
        let store = try ZaloSQLiteStore(path: dbURL.path)
        try await store.setPreferenceString(key: ZaloWebKitMigrator.donePrefKey, value: "1")

        if let e2eeThreads = seed["e2ee_threads"]?.arrayValue?.compactMap(\.stringValue) {
            try await store.setPreferenceStrings(key: "e2eeThreadsV1", value: e2eeThreads)
        }
        if let recents = seed["recent_stickers"], recents != .null {
            try await store.setPreferenceData(key: "recentStickers", data: Data(recents.canonicalString().utf8))
        }
        if let suggest = seed["sticker_suggest"]?.boolValue {
            try await store.setPreferenceBool(key: "stickerSuggest", value: suggest)
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
        if let aliasesObj = contacts["aliases"]?.objectValue {
            var map: [String: String] = [:]
            for (k, v) in aliasesObj {
                if let s = v.stringValue { map[k] = s }
            }
            engine.cachedAliases = map
        }
    }
}

@MainActor
private final class VirtualConfirmClock {
    private struct TimerEntry {
        let id: UUID
        let fireAtMs: Int64
        let cont: CheckedContinuation<Bool, Never>
    }

    var currentMs: Int64 = 1_700_000_000_000
    private var timers: [TimerEntry] = []
    private var registrationWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep(ms: Int) async -> Bool {
        let targetMs = currentMs + Int64(ms)
        let timerId = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    cont.resume(returning: false)
                } else {
                    self.timers.append(TimerEntry(id: timerId, fireAtMs: targetMs, cont: cont))
                    let waiters = self.registrationWaiters
                    self.registrationWaiters.removeAll()
                    for w in waiters { w.resume() }
                }
            }
        } onCancel: {
            Task { @MainActor in
                if let idx = self.timers.firstIndex(where: { $0.id == timerId }) {
                    let entry = self.timers.remove(at: idx)
                    entry.cont.resume(returning: false)
                }
            }
        }
    }

    func waitForTimerRegistration() async {
        if !timers.isEmpty { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if !self.timers.isEmpty {
                cont.resume()
            } else {
                self.registrationWaiters.append(cont)
            }
        }
    }

    @discardableResult
    func advance(by ms: Int64) -> Bool {
        currentMs += ms
        var ready: [TimerEntry] = []
        var kept: [TimerEntry] = []
        for entry in timers {
            if entry.fireAtMs <= currentMs {
                ready.append(entry)
            } else {
                kept.append(entry)
            }
        }
        timers = kept
        for entry in ready {
            entry.cont.resume(returning: true)
        }
        return !ready.isEmpty
    }

    func cancelAll() {
        let pending = timers
        timers.removeAll()
        for entry in pending {
            entry.cont.resume(returning: false)
        }
        let waiters = registrationWaiters
        registrationWaiters.removeAll()
        for w in waiters { w.resume() }
    }
}

@MainActor
private final class StickerTransitionRecorder {
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
                throw StickerRecorderHarness.RecorderError.timeout(
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
