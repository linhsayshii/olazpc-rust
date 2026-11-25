import Foundation
import XCTest
@testable import Olaz

final class PollRecorderTests: XCTestCase {
    func testPollScenarios() async throws {
        try await PollRecorderHarness.runDomain(
            domain: "polls",
            scenarios: Self.pollScenarios()
        )
    }

    func testPollClockIsolation() async throws {
        guard ProcessInfo.processInfo.environment["OLAZ_RECORD"] != "1" else { return }
        try await PollRecorderHarness.runDomain(
            domain: "polls",
            scenarios: Self.pollScenarios()
        )
        await MainActor.run {
            PollClock.watched["stale_poll"] = "g0"
            PollClock.lastAttempt["stale_poll"] = Date(timeIntervalSince1970: 1000)
            PollClock.seenMessages.insert("stale_msg")
            PollClock.didEvictWatched = true
        }
        try await PollRecorderHarness.runDomain(
            domain: "polls",
            scenarios: Self.pollScenarios()
        )
        await MainActor.run {
            XCTAssertTrue(PollClock.watched.isEmpty)
            XCTAssertTrue(PollClock.lastAttempt.isEmpty)
            XCTAssertTrue(PollClock.seenMessages.isEmpty)
            XCTAssertTrue(PollClock.refreshTasks.isEmpty)
            XCTAssertFalse(PollClock.didEvictWatched)
        }
    }

    // MARK: - Helpers

    private static func seedFriend(id: String, name: String, avatar: String? = nil) -> CaseJSON {
        .object([
            "id": .string(id),
            "name": .string(name),
            "zalo_name": .string(name),
            "avatar": avatar.map(CaseJSON.string) ?? .null,
            "last_active_ms": .null,
            "online": .bool(false),
            "section": .string(String(name.prefix(1)).uppercased()),
            "sort_key": .string(name.lowercased()),
        ])
    }

    private static func pollMessageRow(
        id: String,
        convId: String,
        pollId: String,
        question: String,
        tsMs: Int64
    ) -> CaseJSON {
        .object([
            "id": .string(id),
            "conv_id": .string(convId),
            "client_id": .string(id),
            "sender_id": .string("3001001"),
            "sender_name": .string("An Nguyễn"),
            "sender_avatar": .string(""),
            "is_mine": .bool(false),
            "text": .string(question),
            "kind_tag": .string("poll"),
            "ts_ms": .int(tsMs),
            "status": .string("sent"),
            "raw_json": .object([
                "id": .string(id),
                "conversationId": .string(convId),
                "clientId": .string(id),
                "senderId": .string("3001001"),
                "senderName": .string("An Nguyễn"),
                "senderAvatar": .string(""),
                "isMine": .bool(false),
                "text": .string(question),
                "date": .int(tsMs),
                "status": .string("sent"),
                "isE2EE": .bool(false),
                "kind": .object([
                    "type": .string("poll"),
                    "question": .string(question),
                    "header": .string(""),
                    "anonymous": .bool(false),
                    "pollId": .string(pollId),
                    "conversationId": .string(convId),
                ]),
            ]),
        ])
    }

    private static func pollDetailPayload(
        groupIdKey: String? = "group_id",
        groupIdValue: String? = "500101",
        question: String = "Ăn trưa gì?",
        creator: String = "2001001",
        status: Int64 = 1,
        expiredTimeSec: Int64 = 1700086400,
        multi: Bool = true,
        allowAdd: Bool = true,
        anonymous: Bool = false,
        hidePreview: Bool = false,
        options: [CaseJSON] = []
    ) -> CaseJSON {
        var data: [String: CaseJSON] = [
            "question": .string(question),
            "creator": .string(creator),
            "status": .int(status),
            "expired_time": .int(expiredTimeSec),
            "is_multi_choice": .bool(multi),
            "is_add_new_option": .bool(allowAdd),
            "is_anonymous": .bool(anonymous),
            "is_hide_vote_preview": .bool(hidePreview),
            "options": .array(options),
        ]
        if let groupIdKey, let groupIdValue {
            data[groupIdKey] = .string(groupIdValue)
        }
        return .object([
            "error_code": .int(0),
            "data": .object(data),
        ])
    }

    // MARK: - Scenarios

    private static func pollScenarios() -> [PollRecorderHarness.ScenarioDef] {
        // 1. refresh_ok
        let s1 = PollRecorderHarness.ScenarioDef(
            name: "refresh_ok",
            seed: MessageRecorderHarness.readySessionSeed(
                userId: "2001001",
                displayName: "Polls User",
                suppress: ["ws", "long_poll"],
                extras: [
                    "contacts": .object([
                        "friends": .array([
                            seedFriend(id: "3001001", name: "An Nguyễn", avatar: "https://cdn.example.invalid/an.jpg"),
                        ]),
                        "friends_loaded": .bool(true),
                        "groups_loaded": .bool(true),
                    ]),
                    "cached_group_details": .object([
                        "500101": .object([
                            "groupId": .string("500101"),
                            "name": .string("Nhóm Bình Chọn"),
                            "creatorId": .string("3001001"),
                            "totalMember": .int(4),
                        ]),
                    ]),
                ]
            ),
            server: [
                MessageRecorderHarness.loginInfoScript(uid: "2001001", displayName: "Polls User"),
                MessageRecorderHarness.profileMeScript(uid: "2001001", displayName: "Polls User"),
                // 9101: creator me, multi-option voters with prefixed ids, distinct voter_count = 2 across 3 votes (1/4, 2/4? Wait: 1/2 + 1/2? Wait: opt1=2, opt2=2 => totalVotes=4, weights 0.5, 0.5!)
                PollRecorderHarness.httpScript(
                    path: "/api/poll/detail",
                    method: "GET",
                    json: pollDetailPayload(
                        groupIdKey: "group_id",
                        groupIdValue: "500101",
                        question: "Họp lúc mấy giờ?",
                        creator: "u2001001",
                        status: 1,
                        expiredTimeSec: 1700086400,
                        multi: true,
                        allowAdd: true,
                        anonymous: false,
                        hidePreview: false,
                        options: [
                            .object(["option_id": .int(1), "content": .string("9h sáng"), "voters": .array([.string("u2001001"), .string("u3001001")])]),
                            .object(["id": .string("2"), "content": .string("14h chiều"), "voters": .array([.string("3001001"), .string("3001002")])]),
                        ]
                    )
                ),
                // 9102: creator other (3001001), closed, anonymous, hide_preview, me not joined -> resultsHidden: true, votersVisible: false
                PollRecorderHarness.httpScript(
                    path: "/api/poll/detail",
                    method: "GET",
                    json: pollDetailPayload(
                        groupIdKey: "group_id",
                        groupIdValue: "g500101",
                        question: "Bình chọn kín",
                        creator: "3001001",
                        status: 0,
                        expiredTimeSec: 1700001000,
                        multi: false,
                        allowAdd: false,
                        anonymous: true,
                        hidePreview: true,
                        options: [
                            .object(["option_id": .int(10), "content": .string("Đồng ý"), "voters": .array([.string("3001001")])]),
                            .object(["option_id": .int(11), "content": .string("Không"), "voters": .array([.string("3001002"), .string("3001003"), .string("3001004")])]),
                        ]
                    )
                ),
                // 9103: creator unknown (3009999 -> "Thành viên"), no expiry, hide_preview=true & joined=true -> resultsHidden: false, votersVisible: true (1/2, 1/2)
                PollRecorderHarness.httpScript(
                    path: "/api/poll/detail",
                    method: "GET",
                    json: pollDetailPayload(
                        groupIdKey: "group_id",
                        groupIdValue: "500101",
                        question: "Câu hỏi từ người lạ",
                        creator: "3009999",
                        status: 1,
                        expiredTimeSec: 0,
                        multi: false,
                        allowAdd: false,
                        anonymous: false,
                        hidePreview: true,
                        options: [
                            .object(["option_id": .int(20), "content": .string("A"), "voters": .array([.string("2001001")])]),
                            .object(["option_id": .int(21), "content": .string("B"), "voters": .array([.string("3009999")])]),
                        ]
                    )
                ),
            ],
            steps: [
                .object(["cmd": .string("start")]),
                .object(["await": .object(["phase": .string("ready")])]),
                .object(["cmd": .string("refresh_poll"), "args": .object(["id": .string("9101")])]),
                .object(["cmd": .string("refresh_poll"), "args": .object(["id": .string("9102")])]),
                .object(["cmd": .string("refresh_poll"), "args": .object(["id": .string("9103")])]),
            ]
        )

        // 2. refresh_group_resolution
        let s2 = PollRecorderHarness.ScenarioDef(
            name: "refresh_group_resolution",
            seed: MessageRecorderHarness.readySessionSeed(
                userId: "2001001",
                displayName: "Polls User",
                suppress: ["ws", "long_poll"],
                extras: [
                    "contacts": .object([
                        "friends": .array([
                            seedFriend(id: "3001001", name: "An Nguyễn", avatar: "https://cdn.example.invalid/an.jpg"),
                        ]),
                    ]),
                    "local_conversations": .array([
                        .object([
                            "id": .string("g500205"),
                            "is_group": .bool(true),
                            "name": .string("Nhóm Scan Window"),
                            "avatar": .string(""),
                            "pinned": .bool(false),
                            "members": .int(2),
                            "unread": .int(0),
                            "preview_text": .string(""),
                            "preview_ts_ms": .int(0),
                            "preview_from_me": .bool(false),
                        ]),
                    ]),
                    "local_messages": .array([
                        pollMessageRow(id: "m9205", convId: "g500205", pollId: "9205", question: "Poll trong window", tsMs: 1700001000000),
                    ]),
                    "history_freshness": .object([
                        "g500205": .string("up_to_date"),
                    ]),
                    "cached_group_details": .object([
                        // Pre-present -> should NOT fetch getmg-v2
                        "500201": .object([
                            "groupId": .string("500201"),
                            "name": .string("Nhóm Đã Cache"),
                            "creatorId": .string("2001001"),
                            "totalMember": .int(3),
                        ]),
                    ]),
                    "polls": .object([
                        "details": .object([
                            // Seed previous detail for 9204 so previous detail fallback resolves g500201 without getmg-v2
                            "9204": .object([
                                "id": .string("9204"),
                                "groupId": .string("g500201"),
                                "question": .string("Cũ"),
                                "creator": .string("3001001"),
                                "creatorName": .string("An"),
                                "closed": .bool(false),
                                "joined": .bool(false),
                                "multi": .bool(false),
                                "allowAdd": .bool(false),
                                "anonymous": .bool(false),
                                "hidePreview": .bool(false),
                                "voters": .int(0),
                                "canClose": .bool(false),
                                "options": .array([]),
                            ]),
                        ]),
                    ]),
                    "poll_clock": .object([
                        // Watched map fallback for 9203 (500202 not cached -> will fetch getmg-v2)
                        "watched": .object(["9203": .string("g500202")]),
                    ]),
                ]
            ),
            server: [
                MessageRecorderHarness.loginInfoScript(uid: "2001001", displayName: "Polls User"),
                MessageRecorderHarness.profileMeScript(uid: "2001001", displayName: "Polls User"),
                // 9201: group_id present (500201 cached -> NO getmg-v2)
                PollRecorderHarness.httpScript(
                    path: "/api/poll/detail",
                    method: "GET",
                    json: pollDetailPayload(groupIdKey: "group_id", groupIdValue: "500201", question: "Via group_id")
                ),
                // 9202: grid = "500202" (missing cache -> fetch getmg-v2!)
                PollRecorderHarness.httpScript(
                    path: "/api/poll/detail",
                    method: "GET",
                    json: .object([
                        "error_code": .int(0),
                        "data": .object([
                            "grid": .string("500202"),
                            "question": .string("Via grid"),
                            "creator": .string("2001001"),
                            "status": .int(1),
                            "expired_time": .int(0),
                            "options": .array([]),
                        ]),
                    ])
                ),
                PollRecorderHarness.httpScript(
                    path: "/api/group/getmg-v2",
                    method: "POST",
                    json: .object([
                        "error_code": .int(0),
                        "data": .object([
                            "gridInfoMap": .object([
                                "500202": .object([
                                    "groupId": .string("500202"),
                                    "name": .string("Nhóm 500202"),
                                    "creatorId": .string("2001001"),
                                    "totalMember": .int(2),
                                ]),
                            ]),
                        ]),
                    ])
                ),
                // 9203: payload has "g0", resolved from PollClock.watched -> g500202 (now cached -> NO getmg-v2)
                PollRecorderHarness.httpScript(
                    path: "/api/poll/detail",
                    method: "GET",
                    json: pollDetailPayload(groupIdKey: "groupId", groupIdValue: "g0", question: "Via watched")
                ),
                // 9204: no group id in payload, not in watched -> resolved from previous detail g500201 (cached -> NO getmg-v2)
                PollRecorderHarness.httpScript(
                    path: "/api/poll/detail",
                    method: "GET",
                    json: pollDetailPayload(groupIdKey: nil, groupIdValue: nil, question: "Via previous detail")
                ),
                // 9205: resolved from open group window messages -> g500205 (not cached -> fetch getmg-v2)
                PollRecorderHarness.httpScript(
                    path: "/api/poll/detail",
                    method: "GET",
                    json: pollDetailPayload(groupIdKey: nil, groupIdValue: nil, question: "Via window scan")
                ),
                PollRecorderHarness.httpScript(
                    path: "/api/group/getmg-v2",
                    method: "POST",
                    json: .object([
                        "error_code": .int(0),
                        "data": .object([
                            "gridInfoMap": .object([
                                "500205": .object([
                                    "groupId": .string("500205"),
                                    "name": .string("Nhóm Scan Window"),
                                    "creatorId": .string("3001001"),
                                    "totalMember": .int(2),
                                ]),
                            ]),
                        ]),
                    ])
                ),
                // 9206: no group id anywhere -> group_id "" (NO getmg-v2)
                PollRecorderHarness.httpScript(
                    path: "/api/poll/detail",
                    method: "GET",
                    json: pollDetailPayload(groupIdKey: "groupId", groupIdValue: "0", question: "No group")
                ),
            ],
            steps: [
                .object(["cmd": .string("start")]),
                .object(["await": .object(["phase": .string("ready")])]),
                .object(["cmd": .string("open"), "args": .object(["id": .string("g500205")])]),
                .object(["cmd": .string("refresh_poll"), "args": .object(["id": .string("9201")])]),
                .object(["cmd": .string("refresh_poll"), "args": .object(["id": .string("9202")])]),
                .object(["cmd": .string("refresh_poll"), "args": .object(["id": .string("9203")])]),
                .object(["cmd": .string("refresh_poll"), "args": .object(["id": .string("9204")])]),
                .object(["cmd": .string("refresh_poll"), "args": .object(["id": .string("9205")])]),
                .object(["cmd": .string("refresh_poll"), "args": .object(["id": .string("9206")])]),
                .object([
                    "cmd": .string("poll_model_checks"),
                    "args": .object([
                        "checks": .array([
                            .object(["kind": .string("resolve_group_explicit"), "poll_id": .string("9299"), "explicit": .string("500201")]),
                            .object(["kind": .string("resolve_group_explicit"), "poll_id": .string("9299"), "explicit": .string("0"), "payload_group": .string("500202")]),
                        ]),
                    ]),
                ]),
            ]
        )

        // 3. refresh_fail
        let s3 = PollRecorderHarness.ScenarioDef(
            name: "refresh_fail",
            seed: MessageRecorderHarness.readySessionSeed(
                userId: "2001001",
                displayName: "Polls User",
                suppress: ["ws", "long_poll"],
                extras: [
                    "cached_group_details": .object([
                        "500301": .object(["groupId": .string("500301"), "name": .string("Nhóm 3")]),
                    ]),
                ]
            ),
            server: [
                MessageRecorderHarness.loginInfoScript(uid: "2001001", displayName: "Polls User"),
                MessageRecorderHarness.profileMeScript(uid: "2001001", displayName: "Polls User"),
                // 1. 9301 HTTP 500 -> failed
                PollRecorderHarness.httpScript(
                    path: "/api/poll/detail",
                    method: "GET",
                    status: 500,
                    raw: "Server Error"
                ),
                // 2. 9302 missing data -> failed
                PollRecorderHarness.httpScript(
                    path: "/api/poll/detail",
                    method: "GET",
                    json: .object(["error_code": .int(0)])
                ),
                // 3. 9301 later success -> clears failed & saves detail
                PollRecorderHarness.httpScript(
                    path: "/api/poll/detail",
                    method: "GET",
                    json: pollDetailPayload(groupIdKey: "group_id", groupIdValue: "500301", question: "Phục hồi")
                ),
                // 4. 9301 fails again -> already has detail, NOT added to failed
                PollRecorderHarness.httpScript(
                    path: "/api/poll/detail",
                    method: "GET",
                    status: 500,
                    raw: "Server Error"
                ),
            ],
            steps: [
                .object(["cmd": .string("start")]),
                .object(["await": .object(["phase": .string("ready")])]),
                .object(["cmd": .string("refresh_poll"), "args": .object(["id": .string("9301")])]),
                .object(["cmd": .string("refresh_poll"), "args": .object(["id": .string("9302")])]),
                .object(["snapshot": .string("both_failed")]),
                .object(["cmd": .string("refresh_poll"), "args": .object(["id": .string("9301")])]),
                .object(["snapshot": .string("recovered_9301")]),
                .object(["cmd": .string("refresh_poll"), "args": .object(["id": .string("9301")])]),
            ]
        )

        // 4. watch_rules
        var preSeededWatched: [String: CaseJSON] = [:]
        var preSeededDetails: [String: CaseJSON] = [:]
        for i in 1...497 {
            let pid = String(format: "w%03d", i)
            preSeededWatched[pid] = .string("g500401")
            preSeededDetails[pid] = .object([
                "id": .string(pid),
                "groupId": .string("g500401"),
                "question": .string("Poll \(pid)"),
                "creator": .string("2001001"),
                "creatorName": .string("Polls User"),
                "closed": .bool(false),
                "joined": .bool(false),
                "multi": .bool(false),
                "allowAdd": .bool(false),
                "anonymous": .bool(false),
                "hidePreview": .bool(false),
                "voters": .int(0),
                "canClose": .bool(true),
                "options": .array([]),
            ])
        }
        preSeededDetails["9400"] = .object([
            "id": .string("9400"),
            "groupId": .string("g500401"),
            "question": .string("Đã tải sẵn"),
            "creator": .string("2001001"),
            "creatorName": .string("Polls User"),
            "closed": .bool(false),
            "joined": .bool(false),
            "multi": .bool(false),
            "allowAdd": .bool(false),
            "anonymous": .bool(false),
            "hidePreview": .bool(false),
            "voters": .int(0),
            "canClose": .bool(true),
            "options": .array([]),
        ])

        // rewatchPolls will hit 500 entries if we call it after 501st; instead call rewatch_polls BEFORE seeding 500?
        // Actually in watch_rules we only need rewatch_polls when watched is small, OR rewatch_polls with repeat: true!
        // Let's test rewatch_polls with 2 entries in state_and_reset or in watch_rules? Wait: if we seed 497 entries,
        // rewatch_polls would fetch 500 times! Instead let's seed NO bulk entries at start: watch 9400, 9401, 9402, test rewatch_polls (3 requests),
        // and use a helper cmd step or seed? Wait: why not have `seed_watched_bulk` or put 501st-watch at end using a `seed_watched_entries`?
        // Actually let's check FORMAT.md: if we have `rewatch_polls` tested cleanly with 2 watched polls in `watch_rules`? Wait: if `watch_rules` seeds 497 watched entries, `rewatch_polls` would make 500 HTTP calls!
        // Wait: why not test `rewatch_polls` with 2 polls using `repeat: true`? No, 500 HTTP calls slows tests!
        // Even better: add a `watch_bulk` or test `rewatch_polls` in `state_and_reset` (or in `watch_rules` before `watch_poll` of 500? Wait: `watch_poll` only skips refresh when `details[id] != nil`).
        // Wait: `PollRecorderHarness` can support `rewatch_polls` in `state_and_reset` (with 1–2 watched polls) OR in `watch_rules` we don't even need 497 requests for `rewatch_polls` if `rewatch_polls` runs in `state_and_reset` (and we ALSO test it with 2 polls)! Wait: let's check Scenario 4 in u12-polls/index.md:
        // "4. watch_rules: already loaded (no request), within 5 s of last attempt (no request), after 5 s (request), 501st watched poll drops one."
        // Look! Scenario 4 doesn't require `rewatch_polls` inside Scenario 4 — we can test `rewatch_polls` in Scenario 14 (`state_and_reset`, right before `reset_polls`, with 2 watched polls)! That keeps Scenario 4 super fast and clean!
        let s4 = PollRecorderHarness.ScenarioDef(
            name: "watch_rules",
            seed: MessageRecorderHarness.readySessionSeed(
                userId: "2001001",
                displayName: "Polls User",
                suppress: ["ws", "long_poll"],
                extras: [
                    "cached_group_details": .object([
                        "500401": .object(["groupId": .string("500401"), "name": .string("Nhóm 4")]),
                    ]),
                    "polls": .object([
                        "details": .object(preSeededDetails),
                    ]),
                    "poll_clock": .object([
                        "watched": .object(preSeededWatched),
                    ]),
                    "watched_check_ids": .array([.string("9400"), .string("9401"), .string("9402"), .string("9499")]),
                ]
            ),
            server: [
                MessageRecorderHarness.loginInfoScript(uid: "2001001", displayName: "Polls User"),
                MessageRecorderHarness.profileMeScript(uid: "2001001", displayName: "Polls User"),
                // 1. 9401 initial watch_poll fails
                PollRecorderHarness.httpScript(path: "/api/poll/detail", method: "GET", status: 500, raw: "Fail 1"),
                // 2. 9401 after 5s succeeds
                PollRecorderHarness.httpScript(
                    path: "/api/poll/detail",
                    method: "GET",
                    json: pollDetailPayload(groupIdKey: "group_id", groupIdValue: "500401", question: "9401 sau 5s")
                ),
                // 3. 9402 watch_poll fails, then retry_poll immediately bypasses 5s throttle and succeeds
                PollRecorderHarness.httpScript(path: "/api/poll/detail", method: "GET", status: 500, raw: "Fail 2"),
                PollRecorderHarness.httpScript(
                    path: "/api/poll/detail",
                    method: "GET",
                    json: pollDetailPayload(groupIdKey: "group_id", groupIdValue: "500401", question: "9402 retry")
                ),
                // 4. 9499 is 501st watched poll -> evicts one, fetches 9499
                PollRecorderHarness.httpScript(
                    path: "/api/poll/detail",
                    method: "GET",
                    json: pollDetailPayload(groupIdKey: "group_id", groupIdValue: "500401", question: "Poll thứ 501")
                ),
            ],
            steps: [
                .object(["cmd": .string("start")]),
                .object(["await": .object(["phase": .string("ready")])]),
                // 9400 already loaded -> watched=498, NO request
                .object(["cmd": .string("watch_poll"), "now_ms": .int(1700010000000), "args": .object(["id": .string("9400"), "conv_id": .string("g500401")])]),
                // 9401 first watch -> watched=499, request fails
                .object(["cmd": .string("watch_poll"), "now_ms": .int(1700010000000), "args": .object(["id": .string("9401"), "conv_id": .string("g500401")])]),
                // 9401 within 5s (4.999s) -> throttled, NO request
                .object(["cmd": .string("watch_poll"), "now_ms": .int(1700010004999), "args": .object(["id": .string("9401"), "conv_id": .string("g500401")])]),
                .object(["snapshot": .string("throttled_within_5s")]),
                // 9401 at exactly 5.000s -> allowed, succeeds
                .object(["cmd": .string("watch_poll"), "now_ms": .int(1700010005000), "args": .object(["id": .string("9401"), "conv_id": .string("g500401")])]),
                // 9402 watch fails, retry_poll 1s later bypasses throttle -> watched=500
                .object(["cmd": .string("watch_poll"), "now_ms": .int(1700010006000), "args": .object(["id": .string("9402"), "conv_id": .string("g500401")])]),
                .object(["cmd": .string("retry_poll"), "now_ms": .int(1700010007000), "args": .object(["id": .string("9402"), "conv_id": .string("g500401")])]),
                .object(["snapshot": .string("at_500_before_eviction")]),
                // 9499 is 501st -> evicts one, watched_count stays 500, watched becomes null, watched_contains populated
                .object(["cmd": .string("watch_poll"), "now_ms": .int(1700010008000), "args": .object(["id": .string("9499"), "conv_id": .string("g500401")])]),
            ]
        )


        // 5. can_close
        let s5 = PollRecorderHarness.ScenarioDef(
            name: "can_close",
            seed: MessageRecorderHarness.readySessionSeed(
                userId: "2001001",
                displayName: "Polls User",
                suppress: ["ws", "long_poll"],
                extras: [
                    "contacts": .object([
                        "friends": .array([
                            seedFriend(id: "3001001", name: "An Nguyễn", avatar: "https://cdn.example.invalid/an.jpg"),
                        ]),
                    ]),
                    "cached_group_details": .object([
                        "500501": .object(["groupId": .string("500501"), "creatorId": .string("2001001")]),
                        "500502": .object(["groupId": .string("500502"), "creator_id": .string("2001001")]),
                        "500503": .object(["groupId": .string("500503"), "ownerId": .string("2001001")]),
                        "500504": .object(["groupId": .string("500504"), "owner_id": .string("2001001")]),
                        "500505": .object(["groupId": .string("500505"), "creator": .string("2001001")]),
                        "500506": .object(["groupId": .string("500506"), "adminIds": .array([.string("2001001")])]),
                        "500507": .object(["groupId": .string("500507"), "admin_ids": .array([.string("2001001")])]),
                        "500508": .object(["groupId": .string("500508"), "admins": .array([.string("2001001")])]),
                        "500509": .object(["groupId": .string("500509"), "deputies": .array([.string("2001001")])]),
                        "500510": .object(["groupId": .string("500510"), "deputyIds": .array([.string("2001001")])]),
                        "500511": .object(["groupId": .string("500511"), "currentMems": .array([
                            .object(["id": .string("2001001"), "isAdmin": .bool(true)]),
                            .object(["id": .string("3001001"), "isAdmin": .bool(false)]),
                        ])]),
                        "500512": .object(["groupId": .string("500512"), "currentMems": .array([
                            .object(["uid": .string("2001001"), "isCreator": .bool(true)]),
                        ])]),
                        "500513": .object(["groupId": .string("500513"), "creatorId": .string("3001001"), "currentMems": .array([
                            .object(["id": .string("2001001"), "isAdmin": .bool(false), "isCreator": .bool(false)]),
                        ])]),
                    ]),
                ]
            ),
            server: [
                MessageRecorderHarness.loginInfoScript(uid: "2001001", displayName: "Polls User"),
                MessageRecorderHarness.profileMeScript(uid: "2001001", displayName: "Polls User"),
                PollRecorderHarness.httpScript(path: "/api/poll/detail", method: "GET", json: pollDetailPayload(groupIdKey: "group_id", groupIdValue: "500501", question: "Key creatorId", creator: "3001001")),
                PollRecorderHarness.httpScript(path: "/api/poll/detail", method: "GET", json: pollDetailPayload(groupIdKey: "group_id", groupIdValue: "500502", question: "Key creator_id", creator: "3001001")),
                PollRecorderHarness.httpScript(path: "/api/poll/detail", method: "GET", json: pollDetailPayload(groupIdKey: "group_id", groupIdValue: "500503", question: "Key ownerId", creator: "3001001")),
                PollRecorderHarness.httpScript(path: "/api/poll/detail", method: "GET", json: pollDetailPayload(groupIdKey: "group_id", groupIdValue: "500504", question: "Key owner_id", creator: "3001001")),
                PollRecorderHarness.httpScript(path: "/api/poll/detail", method: "GET", json: pollDetailPayload(groupIdKey: "group_id", groupIdValue: "500505", question: "Key creator", creator: "3001001")),
                PollRecorderHarness.httpScript(path: "/api/poll/detail", method: "GET", json: pollDetailPayload(groupIdKey: "group_id", groupIdValue: "500506", question: "Key adminIds", creator: "3001001")),
                PollRecorderHarness.httpScript(path: "/api/poll/detail", method: "GET", json: pollDetailPayload(groupIdKey: "group_id", groupIdValue: "500507", question: "Key admin_ids", creator: "3001001")),
                PollRecorderHarness.httpScript(path: "/api/poll/detail", method: "GET", json: pollDetailPayload(groupIdKey: "group_id", groupIdValue: "500508", question: "Key admins", creator: "3001001")),
                PollRecorderHarness.httpScript(path: "/api/poll/detail", method: "GET", json: pollDetailPayload(groupIdKey: "group_id", groupIdValue: "500509", question: "Key deputies", creator: "3001001")),
                PollRecorderHarness.httpScript(path: "/api/poll/detail", method: "GET", json: pollDetailPayload(groupIdKey: "group_id", groupIdValue: "500510", question: "Key deputyIds", creator: "3001001")),
                PollRecorderHarness.httpScript(path: "/api/poll/detail", method: "GET", json: pollDetailPayload(groupIdKey: "group_id", groupIdValue: "500511", question: "currentMems isAdmin", creator: "3001001")),
                PollRecorderHarness.httpScript(path: "/api/poll/detail", method: "GET", json: pollDetailPayload(groupIdKey: "group_id", groupIdValue: "500512", question: "currentMems isCreator", creator: "3001001")),
                PollRecorderHarness.httpScript(path: "/api/poll/detail", method: "GET", json: pollDetailPayload(groupIdKey: "group_id", groupIdValue: "500513", question: "Plain member false", creator: "3001001")),
                PollRecorderHarness.httpScript(path: "/api/poll/detail", method: "GET", json: pollDetailPayload(groupIdKey: "group_id", groupIdValue: "500513", question: "Poll creator true", creator: "2001001")),
            ],
            steps: [
                .object(["cmd": .string("start")]),
                .object(["await": .object(["phase": .string("ready")])]),
                .object(["cmd": .string("refresh_poll"), "args": .object(["id": .string("9501")])]),
                .object(["cmd": .string("refresh_poll"), "args": .object(["id": .string("9502")])]),
                .object(["cmd": .string("refresh_poll"), "args": .object(["id": .string("9503")])]),
                .object(["cmd": .string("refresh_poll"), "args": .object(["id": .string("9504")])]),
                .object(["cmd": .string("refresh_poll"), "args": .object(["id": .string("9505")])]),
                .object(["cmd": .string("refresh_poll"), "args": .object(["id": .string("9506")])]),
                .object(["cmd": .string("refresh_poll"), "args": .object(["id": .string("9507")])]),
                .object(["cmd": .string("refresh_poll"), "args": .object(["id": .string("9508")])]),
                .object(["cmd": .string("refresh_poll"), "args": .object(["id": .string("9509")])]),
                .object(["cmd": .string("refresh_poll"), "args": .object(["id": .string("9510")])]),
                .object(["cmd": .string("refresh_poll"), "args": .object(["id": .string("9511")])]),
                .object(["cmd": .string("refresh_poll"), "args": .object(["id": .string("9512")])]),
                .object(["cmd": .string("refresh_poll"), "args": .object(["id": .string("9513")])]),
                .object(["cmd": .string("refresh_poll"), "args": .object(["id": .string("9514")])]),
                .object([
                    "cmd": .string("poll_model_checks"),
                    "args": .object([
                        "checks": .array([
                            .object(["kind": .string("is_group_admin"), "uid": .string("0"), "group_id": .string("500501")]),
                            .object(["kind": .string("is_group_admin"), "uid": .string(""), "group_id": .string("500501")]),
                            .object(["kind": .string("is_group_admin"), "uid": .string("u2001001"), "group_id": .string("500501")]),
                            .object(["kind": .string("is_group_admin"), "uid": .string("2001001"), "group_id": .string("599999")]),
                        ]),
                    ]),
                ]),
            ]
        )

        // 6. voters
        let s6 = PollRecorderHarness.ScenarioDef(
            name: "voters",
            seed: MessageRecorderHarness.readySessionSeed(
                userId: "2001001",
                displayName: "Polls User",
                suppress: ["ws", "long_poll"],
                extras: [
                    "contacts": .object([
                        "friends": .array([
                            seedFriend(id: "3001001", name: "An Nguyễn", avatar: "https://cdn.example.invalid/an.jpg"),
                        ]),
                    ]),
                ]
            ),
            server: [
                MessageRecorderHarness.loginInfoScript(uid: "2001001", displayName: "Polls User"),
                MessageRecorderHarness.profileMeScript(uid: "2001001", displayName: "Polls User"),
                // 9601: named voters (self unprefixed & prefixed, known friend, unknown id)
                PollRecorderHarness.httpScript(
                    path: "/api/poll/detail",
                    method: "GET",
                    json: pollDetailPayload(
                        groupIdKey: "group_id",
                        groupIdValue: "500601",
                        question: "Ai đi?",
                        anonymous: false,
                        options: [
                            .object(["option_id": .int(1), "content": .string("Có"), "voters": .array([.string("2001001"), .string("u3001001"), .string("3009999")])]),
                            .object(["option_id": .int(2), "content": .string("Không"), "voters": .array([])]),
                        ]
                    )
                ),
                // 9602: anonymous -> restricted=true, users=[]
                PollRecorderHarness.httpScript(
                    path: "/api/poll/detail",
                    method: "GET",
                    json: pollDetailPayload(
                        groupIdKey: "group_id",
                        groupIdValue: "500601",
                        question: "Ẩn danh",
                        anonymous: true,
                        options: [
                            .object(["option_id": .int(10), "content": .string("A"), "voters": .array([.string("2001001"), .string("3001001")])]),
                        ]
                    )
                ),
                // 9603: server error -> nil
                PollRecorderHarness.httpScript(
                    path: "/api/poll/detail",
                    method: "GET",
                    status: 500,
                    raw: "Voter error"
                ),
            ],
            steps: [
                .object(["cmd": .string("start")]),
                .object(["await": .object(["phase": .string("ready")])]),
                .object(["cmd": .string("poll_voters"), "args": .object(["id": .string("9601")])]),
                .object(["cmd": .string("poll_voters"), "args": .object(["id": .string("9602")])]),
                .object(["cmd": .string("poll_voters"), "args": .object(["id": .string("9603")])]),
            ]
        )

        // 7. pin_state
        let s7 = PollRecorderHarness.ScenarioDef(
            name: "pin_state",
            seed: MessageRecorderHarness.readySessionSeed(
                userId: "2001001",
                displayName: "Polls User",
                suppress: ["ws", "long_poll"]
            ),
            server: [
                MessageRecorderHarness.loginInfoScript(uid: "2001001", displayName: "Polls User"),
                MessageRecorderHarness.profileMeScript(uid: "2001001", displayName: "Polls User"),
            ],
            steps: [
                .object(["cmd": .string("start")]),
                .object(["await": .object(["phase": .string("ready")])]),
                // Group without board cache -> emits refresh_board_pins host call
                .object(["cmd": .string("refresh_poll_pin"), "args": .object(["id": .string("9701"), "conv_id": .string("g500701")])]),
                .object(["snapshot": .string("uncached_group")]),
                // Board updated via pins_state with 9701 pinned -> no host call, pinned=true
                .object([
                    "cmd": .string("pins_state"),
                    "args": .object([
                        "json": .object([
                            "pins": .object([
                                "convId": .string("g500701"),
                                "ready": .bool(true),
                                "canPin": .bool(true),
                                "limit": .int(5),
                                "items": .array([
                                    .object(["ref": .string("9701"), "kind": .string("poll"), "title": .string("Poll A"), "sender": .string("Polls User")]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
                .object(["cmd": .string("refresh_poll_pin"), "args": .object(["id": .string("9701"), "conv_id": .string("g500701")])]),
                .object(["snapshot": .string("pinned_in_board")]),
                // Board updated without 9701 -> pinned=false
                .object([
                    "cmd": .string("pins_state"),
                    "args": .object([
                        "json": .object([
                            "pins": .object([
                                "convId": .string("g500701"),
                                "ready": .bool(true),
                                "canPin": .bool(true),
                                "limit": .int(5),
                                "items": .array([]),
                            ]),
                        ]),
                    ]),
                ]),
                .object(["cmd": .string("refresh_poll_pin"), "args": .object(["id": .string("9701"), "conv_id": .string("g500701")])]),
                // 1-1 conv on new poll 9702 -> ready=false, can_pin=false
                .object(["cmd": .string("refresh_poll_pin"), "args": .object(["id": .string("9702"), "conv_id": .string("3001001")])]),
                // 1-1 conv on 9701 (already ready=true) -> keeps existing ready state
                .object(["cmd": .string("refresh_poll_pin"), "args": .object(["id": .string("9701"), "conv_id": .string("3001001")])]),
                .object([
                    "cmd": .string("poll_model_checks"),
                    "args": .object([
                        "checks": .array([
                            .object(["kind": .string("poll_capabilities"), "conv_id": .string("g500701")]),
                            .object(["kind": .string("poll_capabilities"), "conv_id": .string("3001001")]),
                        ]),
                    ]),
                ]),
            ]
        )

        // 8. pin_flows
        let s8 = PollRecorderHarness.ScenarioDef(
            name: "pin_flows",
            seed: MessageRecorderHarness.readySessionSeed(
                userId: "2001001",
                displayName: "Polls User",
                suppress: ["ws", "long_poll"],
                extras: [
                    "pins": .object([
                        "g500801": .object([
                            "ready": .bool(true),
                            "canPin": .bool(true),
                            "limit": .int(5),
                            "items": .array([
                                .object(["ref": .string("9811"), "kind": .string("note"), "title": .string("Ghi chú 1"), "sender": .string("An")]),
                                .object(["ref": .string("9812"), "kind": .string("note"), "title": .string("Ghi chú 2"), "sender": .string("An")]),
                                .object(["ref": .string("9813"), "kind": .string("reminder"), "title": .string("Nhắc 3"), "sender": .string("An")]),
                                .object(["ref": .string("9814"), "kind": .string("message"), "title": .string("Tin 4"), "sender": .string("An")]),
                                .object(["ref": .string("9800"), "kind": .string("poll"), "title": .string("Poll cũ nhất"), "sender": .string("An")]),
                            ]),
                        ]),
                        "g500802": .object([
                            "ready": .bool(true),
                            "canPin": .bool(true),
                            "limit": .int(5),
                            "items": .array([]),
                        ]),
                    ]),
                    "board_raw_topics": .object([
                        "g500801": .object([
                            "version": .int(7),
                            "topics": .object([
                                "9800": .object(["id": .string("9800"), "type": .int(3)]),
                            ]),
                        ]),
                    ]),
                ]
            ),
            server: [
                MessageRecorderHarness.loginInfoScript(uid: "2001001", displayName: "Polls User"),
                MessageRecorderHarness.profileMeScript(uid: "2001001", displayName: "Polls User"),
                // Step 3: pin 9801 in g500802 -> ok
                PollRecorderHarness.httpScript(path: "/api/board/pinv2", method: "GET", json: .object(["error_code": .int(0), "data": .object([:])])),
                // Step 4: pin 9802 in g500801 -> limit 1005 -> needsConfirmation(ref: 9800)
                PollRecorderHarness.httpScript(path: "/api/board/pinv2", method: "GET", json: .object(["error_code": .int(1005), "error_message": .string("Board full")])),
                // Step 5: confirm replace 9800 with 9802 -> unpinv2 ok + pinv2 ok
                PollRecorderHarness.httpScript(path: "/api/board/unpinv2", method: "GET", json: .object(["error_code": .int(0), "data": .object([:])])),
                PollRecorderHarness.httpScript(path: "/api/board/pinv2", method: "GET", json: .object(["error_code": .int(0), "data": .object([:])])),
                // Step 6: confirm replace -> unpin fails (112 forbidden)
                PollRecorderHarness.httpScript(path: "/api/board/unpinv2", method: "GET", json: .object(["error_code": .int(112), "error_message": .string("No permission")])),
                // Step 7: confirm replace -> unpin ok, pin fails -> partial
                PollRecorderHarness.httpScript(path: "/api/board/unpinv2", method: "GET", json: .object(["error_code": .int(0), "data": .object([:])])),
                PollRecorderHarness.httpScript(path: "/api/board/pinv2", method: "GET", json: .object(["error_code": .int(999), "error_message": .string("Something failed")])),
                // Step 8: HTTP 500 -> network
                PollRecorderHarness.httpScript(path: "/api/board/pinv2", method: "GET", status: 500, raw: "Bad Gateway"),
                // Step 9: code 114 -> forbidden
                PollRecorderHarness.httpScript(path: "/api/board/pinv2", method: "GET", json: .object(["error_code": .int(114), "error_message": .string("Denied")])),
                // Step 10: message "Không có quyền" -> forbidden
                PollRecorderHarness.httpScript(path: "/api/board/pinv2", method: "GET", json: .object(["error_code": .int(999), "error_message": .string("Không có quyền")])),
                // Step 11: unhandled session code -> error=nil
                PollRecorderHarness.httpScript(path: "/api/board/pinv2", method: "GET", json: .object(["error_code": .int(999), "error_message": .string("Unknown failure")])),
                // Step 12: pin 9800 (same as oldest.ref) hits code 1010 -> failed limit (not needsConfirmation)
                PollRecorderHarness.httpScript(path: "/api/board/pinv2", method: "GET", json: .object(["error_code": .int(1010), "error_message": .string("Max pins")])),
            ],
            steps: [
                .object(["cmd": .string("start")]),
                .object(["await": .object(["phase": .string("ready")])]),
                // 1-1 -> forbidden
                .object(["cmd": .string("pin_poll"), "args": .object(["id": .string("9801"), "conv_id": .string("3001001")])]),
                // Blank id -> forbidden
                .object(["cmd": .string("pin_poll"), "args": .object(["id": .string("   "), "conv_id": .string("g500802")])]),
                // Pin ok
                .object(["cmd": .string("pin_poll"), "args": .object(["id": .string("9801"), "conv_id": .string("g500802")])]),
                // Limit confirmation
                .object(["cmd": .string("pin_poll"), "args": .object(["id": .string("9802"), "conv_id": .string("g500801")])]),
                // Confirm replace ok
                .object(["cmd": .string("pin_poll"), "args": .object(["id": .string("9802"), "conv_id": .string("g500801"), "confirming": .string("9800")])]),
                // Replace unpin fail
                .object(["cmd": .string("pin_poll"), "args": .object(["id": .string("9803"), "conv_id": .string("g500801"), "confirming": .string("9800")])]),
                // Replace pin fail -> partial
                .object(["cmd": .string("pin_poll"), "args": .object(["id": .string("9803"), "conv_id": .string("g500801"), "confirming": .string("9800")])]),
                // HTTP 500 -> network
                .object(["cmd": .string("pin_poll"), "args": .object(["id": .string("9804"), "conv_id": .string("g500802")])]),
                // Code 114 -> forbidden
                .object(["cmd": .string("pin_poll"), "args": .object(["id": .string("9804"), "conv_id": .string("g500802")])]),
                // Vietnamese permission -> forbidden
                .object(["cmd": .string("pin_poll"), "args": .object(["id": .string("9804"), "conv_id": .string("g500802")])]),
                // Generic session error -> nil
                .object(["cmd": .string("pin_poll"), "args": .object(["id": .string("9804"), "conv_id": .string("g500802")])]),
                // Same oldest ref -> failed limit
                .object(["cmd": .string("pin_poll"), "args": .object(["id": .string("9800"), "conv_id": .string("g500801")])]),
                // Remaining mapPollPinError + PollPinConfirm.message branches
                .object([
                    "cmd": .string("poll_model_checks"),
                    "args": .object([
                        "checks": .array([
                            .object(["kind": .string("map_pin_error"), "code": .int(201), "message": .string("")]),
                            .object(["kind": .string("map_pin_error"), "code": .int(999), "message": .string("Đã đạt giới hạn")]),
                            .object(["kind": .string("map_pin_error"), "code": .int(999), "message": .string("Tối đa 5 ghim")]),
                            .object(["kind": .string("map_pin_error"), "code": .int(999), "message": .string("Max reached")]),
                            .object(["kind": .string("map_pin_error"), "code": .int(999), "message": .string("Board is full")]),
                            .object(["kind": .string("map_pin_error"), "code": .int(999), "message": .string("At limit")]),
                            .object(["kind": .string("map_pin_error"), "code": .int(200), "message": .string("")]),
                            .object(["kind": .string("map_pin_error"), "code": .int(403), "message": .string("")]),
                            .object(["kind": .string("map_pin_error"), "code": .int(999), "message": .string("Missing permission")]),
                            .object(["kind": .string("map_pin_error"), "code": .int(999), "message": .string("Action forbidden")]),
                            .object(["kind": .string("map_pin_error"), "code": .int(999), "message": .string("Only admin")]),
                            .object(["kind": .string("map_pin_error"), "code": .int(999), "message": .string("Not allowed here")]),
                            .object(["kind": .string("map_pin_error"), "other": .bool(true)]),
                            .object(["kind": .string("pin_confirm_message"), "ref": .string("p1"), "limit": .int(5), "pin_kind": .string("poll"), "title": .string("Họp")]),
                            .object(["kind": .string("pin_confirm_message"), "ref": .string("r1"), "limit": .int(5), "pin_kind": .string("reminder"), "title": .string("Nhắc")]),
                            .object(["kind": .string("pin_confirm_message"), "ref": .string("m1"), "limit": .int(5), "pin_kind": .string("message"), "title": .string("Tin")]),
                            .object(["kind": .string("pin_confirm_message"), "ref": .string("n1"), "limit": .int(0), "pin_kind": .string("note"), "title": .string("")]),
                        ]),
                    ]),
                ]),
            ]
        )

        var s9Login = MessageRecorderHarness.loginInfoScript(uid: "2001001", displayName: "Polls User")
        if var resp = s9Login["response"]?.objectValue,
           var json = resp["json"]?.objectValue,
           var data = json["data"]?.objectValue,
           var svc = data["zpw_service_map_v3"]?.objectValue {
            svc["friend_board"] = .array([.string("http://fake")])
            data["zpw_service_map_v3"] = .object(svc)
            json["data"] = .object(data)
            resp["json"] = .object(json)
            if var obj = s9Login.objectValue {
                obj["response"] = .object(resp)
                s9Login = .object(obj)
            }
        }

        // 9. unpin
        let s9 = PollRecorderHarness.ScenarioDef(
            name: "unpin",
            seed: MessageRecorderHarness.readySessionSeed(
                userId: "2001001",
                displayName: "Polls User",
                suppress: ["ws", "long_poll"],
                extras: [
                    "pins": .object([
                        "g500901": .object([
                            "ready": .bool(true),
                            "canPin": .bool(true),
                            "limit": .int(5),
                            "items": .array([
                                .object(["ref": .string("9901"), "kind": .string("poll"), "title": .string("Ghim nhóm"), "sender": .string("Polls User")]),
                            ]),
                        ]),
                    ]),
                    "board_raw_topics": .object([
                        "g500901": .object([
                            "version": .int(3),
                            "topics": .object([
                                "9901": .object(["id": .string("9901"), "type": .int(3)]),
                            ]),
                        ]),
                    ]),
                ]
            ),
            server: [
                s9Login,
                MessageRecorderHarness.profileMeScript(uid: "2001001", displayName: "Polls User"),
                // Group unpin ok
                PollRecorderHarness.httpScript(path: "/api/board/unpinv2", method: "GET", json: .object(["error_code": .int(0), "data": .object([:])])),
                // 1-1 unpin ok
                PollRecorderHarness.httpScript(path: "/api/friendboard/multi_unpin", method: "GET", json: .object(["error_code": .int(0), "data": .object([:])])),
                // Group unpin fail -> network
                PollRecorderHarness.httpScript(path: "/api/board/unpinv2", method: "GET", status: 500, raw: "Fail"),
            ],
            steps: [
                .object(["cmd": .string("start")]),
                .object(["await": .object(["phase": .string("ready")])]),
                .object(["cmd": .string("unpin_poll"), "args": .object(["id": .string("9901"), "conv_id": .string("g500901")])]),
                .object(["cmd": .string("unpin_poll"), "args": .object(["id": .string("9902"), "conv_id": .string("3001001")])]),
                .object(["cmd": .string("unpin_poll"), "args": .object(["id": .string("9901"), "conv_id": .string("g500901")])]),
            ]
        )


        // 10. vote
        let s10 = PollRecorderHarness.ScenarioDef(
            name: "vote",
            seed: MessageRecorderHarness.readySessionSeed(
                userId: "2001001",
                displayName: "Polls User",
                suppress: ["ws", "long_poll"],
                extras: [
                    "cached_group_details": .object([
                        "501001": .object(["groupId": .string("501001"), "creatorId": .string("2001001")]),
                    ]),
                    "polls": .object([
                        "details": .object([
                            "1001": .object([
                                "id": .string("1001"),
                                "groupId": .string("g501001"),
                                "question": .string("Chọn món"),
                                "creator": .string("2001001"),
                                "creatorName": .string("Bạn"),
                                "closed": .bool(false),
                                "joined": .bool(true),
                                "multi": .bool(true),
                                "allowAdd": .bool(true),
                                "anonymous": .bool(false),
                                "hidePreview": .bool(false),
                                "voters": .int(2),
                                "canClose": .bool(true),
                                "options": .array([
                                    .object(["id": .string("1"), "content": .string("Phở"), "votes": .int(1), "voted": .bool(false)]),
                                    .object(["id": .string("2"), "content": .string("Bún"), "votes": .int(2), "voted": .bool(true)]),
                                ]),
                            ]),
                            "1002": .object([
                                "id": .string("1002"),
                                "groupId": .string("g501001"),
                                "question": .string("Một lựa chọn"),
                                "creator": .string("2001001"),
                                "creatorName": .string("Bạn"),
                                "closed": .bool(false),
                                "joined": .bool(true),
                                "multi": .bool(false),
                                "allowAdd": .bool(true),
                                "anonymous": .bool(false),
                                "hidePreview": .bool(false),
                                "voters": .int(1),
                                "canClose": .bool(true),
                                "options": .array([
                                    .object(["id": .string("10"), "content": .string("Đỏ"), "votes": .int(1), "voted": .bool(true)]),
                                    .object(["id": .string("11"), "content": .string("Xanh"), "votes": .int(0), "voted": .bool(false)]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]
            ),
            server: [
                MessageRecorderHarness.loginInfoScript(uid: "2001001", displayName: "Polls User"),
                MessageRecorderHarness.profileMeScript(uid: "2001001", displayName: "Polls User"),
                // Step 1: plain vote on 1001 -> vote OK + refresh detail
                PollRecorderHarness.httpScript(path: "/api/poll/vote", method: "GET", json: .object(["error_code": .int(0), "data": .object([:])])),
                PollRecorderHarness.httpScript(
                    path: "/api/poll/detail",
                    method: "GET",
                    json: pollDetailPayload(
                        groupIdKey: "group_id",
                        groupIdValue: "501001",
                        question: "Chọn món",
                        creator: "2001001",
                        options: [
                            .object(["option_id": .int(1), "content": .string("Phở"), "voters": .array([.string("3001001"), .string("2001001")])]),
                            .object(["option_id": .int(2), "content": .string("Bún"), "voters": .array([.string("3001001"), .string("2001001")])]),
                        ]
                    )
                ),
                // Step 2: add option on 1001 -> option/add OK + refresh detail
                PollRecorderHarness.httpScript(path: "/api/poll/option/add", method: "GET", json: .object(["error_code": .int(0), "data": .object([:])])),
                PollRecorderHarness.httpScript(
                    path: "/api/poll/detail",
                    method: "GET",
                    json: pollDetailPayload(
                        groupIdKey: "group_id",
                        groupIdValue: "501001",
                        question: "Chọn món",
                        creator: "2001001",
                        options: [
                            .object(["option_id": .int(1), "content": .string("Phở"), "voters": .array([.string("3001001"), .string("2001001")])]),
                            .object(["option_id": .int(2), "content": .string("Bún"), "voters": .array([.string("3001001"), .string("2001001")])]),
                            .object(["option_id": .int(3), "content": .string("Bún chả"), "voters": .array([.string("2001001")])]),
                        ]
                    )
                ),
                // Step 3: single-choice vote on 1002 fails -> network
                PollRecorderHarness.httpScript(path: "/api/poll/vote", method: "GET", status: 500, raw: "Vote error"),
            ],
            steps: [
                .object(["cmd": .string("start")]),
                .object(["await": .object(["phase": .string("ready")])]),
                .object([
                    "cmd": .string("vote_poll"),
                    "args": .object([
                        "id": .string("1001"),
                        "conv_id": .string("g501001"),
                        "detail_from": .string("state"),
                        "draft": .object(["toggle": .array([.string("1")])]),
                    ]),
                ]),
                .object(["snapshot": .string("after_plain_vote")]),
                .object([
                    "cmd": .string("vote_poll"),
                    "args": .object([
                        "id": .string("1001"),
                        "conv_id": .string("g501001"),
                        "detail_from": .string("state"),
                        "draft": .object([
                            "added": .array([
                                .object(["text": .string("  Bún chả  "), "voted": .bool(true)]),
                                .object(["text": .string("   "), "voted": .bool(false)]),
                            ]),
                        ]),
                    ]),
                ]),
                .object([
                    "cmd": .string("vote_poll"),
                    "args": .object([
                        "id": .string("1002"),
                        "conv_id": .string("g501001"),
                        "detail_from": .string("state"),
                        "draft": .object(["toggle": .array([.string("11")])]),
                    ]),
                ]),
                .object([
                    "cmd": .string("poll_model_checks"),
                    "args": .object([
                        "checks": .array([
                            .object(["kind": .string("vote_draft_branches")]),
                            .object(["kind": .string("detail_branches")]),
                        ]),
                    ]),
                ]),
            ]
        )

        // 11. lock_share
        let s11 = PollRecorderHarness.ScenarioDef(
            name: "lock_share",
            seed: MessageRecorderHarness.readySessionSeed(
                userId: "2001001",
                displayName: "Polls User",
                suppress: ["ws", "long_poll"],
                extras: [
                    "cached_group_details": .object([
                        "501101": .object(["groupId": .string("501101"), "creatorId": .string("2001001")]),
                    ]),
                    "polls": .object([
                        "details": .object([
                            "1101": .object([
                                "id": .string("1101"),
                                "groupId": .string("g501101"),
                                "question": .string("Khoá & chia sẻ"),
                                "creator": .string("2001001"),
                                "creatorName": .string("Bạn"),
                                "closed": .bool(false),
                                "joined": .bool(false),
                                "multi": .bool(true),
                                "allowAdd": .bool(true),
                                "anonymous": .bool(false),
                                "hidePreview": .bool(false),
                                "voters": .int(0),
                                "canClose": .bool(true),
                                "options": .array([
                                    .object(["id": .string("1"), "content": .string("Có"), "votes": .int(0), "voted": .bool(false)]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]
            ),
            server: [
                MessageRecorderHarness.loginInfoScript(uid: "2001001", displayName: "Polls User"),
                MessageRecorderHarness.profileMeScript(uid: "2001001", displayName: "Polls User"),
                // lock ok + refresh
                PollRecorderHarness.httpScript(path: "/api/poll/end", method: "POST", json: .object(["error_code": .int(0), "data": .object([:])])),
                PollRecorderHarness.httpScript(
                    path: "/api/poll/detail",
                    method: "GET",
                    json: pollDetailPayload(groupIdKey: "group_id", groupIdValue: "501101", question: "Khoá & chia sẻ", creator: "2001001", status: 0)
                ),
                // lock fail
                PollRecorderHarness.httpScript(path: "/api/poll/end", method: "POST", status: 500, raw: "Lock fail"),
                // share ok
                PollRecorderHarness.httpScript(path: "/api/poll/share", method: "POST", json: .object(["error_code": .int(0), "data": .object([:])])),
                // share fail
                PollRecorderHarness.httpScript(path: "/api/poll/share", method: "POST", status: 500, raw: "Share fail"),
            ],
            steps: [
                .object(["cmd": .string("start")]),
                .object(["await": .object(["phase": .string("ready")])]),
                .object(["cmd": .string("lock_poll"), "args": .object(["id": .string("1101"), "conv_id": .string("g501101")])]),
                .object(["snapshot": .string("after_lock_ok")]),
                .object(["cmd": .string("lock_poll"), "args": .object(["id": .string("1101"), "conv_id": .string("g501101")])]),
                .object(["cmd": .string("share_poll"), "args": .object(["id": .string("1101"), "conv_id": .string("g501101")])]),
                .object(["cmd": .string("share_poll"), "args": .object(["id": .string("1101"), "conv_id": .string("g501101")])]),
            ]
        )

        // 12. create
        let s12 = PollRecorderHarness.ScenarioDef(
            name: "create",
            seed: MessageRecorderHarness.readySessionSeed(
                userId: "2001001",
                displayName: "Polls User",
                suppress: ["ws", "long_poll"],
                extras: [
                    "pins": .object([
                        "g501201": .object([
                            "ready": .bool(true),
                            "canPin": .bool(true),
                            "limit": .int(5),
                            "items": .array([]),
                        ]),
                    ]),
                ]
            ),
            server: [
                MessageRecorderHarness.loginInfoScript(uid: "2001001", displayName: "Polls User"),
                MessageRecorderHarness.profileMeScript(uid: "2001001", displayName: "Polls User"),
                // Step A: create + pin ok
                PollRecorderHarness.httpScript(path: "/api/poll/create", method: "POST", json: .object(["error_code": .int(0), "data": .object(["poll_id": .string("1201")])])),
                PollRecorderHarness.httpScript(path: "/api/board/pinv2", method: "GET", json: .object(["error_code": .int(0), "data": .object([:])])),
                // Step B: create without canPin (no pinv2)
                PollRecorderHarness.httpScript(path: "/api/poll/create", method: "POST", json: .object(["error_code": .int(0), "data": .object(["pollId": .string("1202")])])),
                // Step C: create with pin=true, created id missing -> pinSkipped
                PollRecorderHarness.httpScript(path: "/api/poll/create", method: "POST", json: .object(["error_code": .int(0), "data": .object([:])])),
                // Step D: create with id=1204, pin fails -> pinSkipped
                PollRecorderHarness.httpScript(path: "/api/poll/create", method: "POST", json: .object(["error_code": .int(0), "data": .object(["id": .int(1204)])])),
                PollRecorderHarness.httpScript(path: "/api/board/pinv2", method: "GET", status: 500, raw: "Pin fail"),
                // Step E: forbidden code 112
                PollRecorderHarness.httpScript(path: "/api/poll/create", method: "POST", json: .object(["error_code": .int(112), "error_message": .string("Denied")])),
                // Step F: forbidden code 114
                PollRecorderHarness.httpScript(path: "/api/poll/create", method: "POST", json: .object(["error_code": .int(114), "error_message": .string("Denied")])),
                // Step G: forbidden code 403
                PollRecorderHarness.httpScript(path: "/api/poll/create", method: "POST", json: .object(["error_code": .int(403), "error_message": .string("Denied")])),
                // Step H: forbidden by message "quyền"
                PollRecorderHarness.httpScript(path: "/api/poll/create", method: "POST", json: .object(["error_code": .int(999), "error_message": .string("Thiếu quyền")])),
                // Step I: other session code -> network
                PollRecorderHarness.httpScript(path: "/api/poll/create", method: "POST", json: .object(["error_code": .int(999), "error_message": .string("Other error")])),
                // Step J: HTTP 500 -> network
                PollRecorderHarness.httpScript(path: "/api/poll/create", method: "POST", status: 500, raw: "Create fail"),
            ],
            steps: [
                .object(["cmd": .string("start")]),
                .object(["await": .object(["phase": .string("ready")])]),
                // A: trimmed/truncated question & options, deadline on, config disables hidePreview/anonymous, hidePreview forces allowAdd=false, pin ok
                .object([
                    "cmd": .string("create_poll"),
                    "args": .object([
                        "conv_id": .string("g501201"),
                        "can_pin": .bool(true),
                        "config": .object([
                            "minOptions": .int(2),
                            "maxOptions": .int(5),
                            "maxQuestion": .int(10),
                            "maxOption": .int(6),
                            "enableAnonymous": .bool(false),
                            "enableHidePreview": .bool(false),
                        ]),
                        "draft": .object([
                            "question": .string("  1234567890EXTRA  "),
                            "options": .array([.string("  ABCDEFGH  "), .string(""), .string("12345678")]),
                            "has_deadline": .bool(true),
                            "deadline_ms": .int(1700090000000),
                            "pin": .bool(true),
                            "multi": .bool(false),
                            "allow_add": .bool(true),
                            "hide_preview": .bool(true),
                            "anonymous": .bool(true),
                        ]),
                    ]),
                ]),
                // B: deadline off, hidePreview/anonymous enabled, hidePreview=false, pin requested without canPin
                .object([
                    "cmd": .string("create_poll"),
                    "args": .object([
                        "conv_id": .string("g501201"),
                        "can_pin": .bool(false),
                        "config": .null,
                        "draft": .object([
                            "question": .string("Câu hỏi bình chọn"),
                            "options": .array([.string("A"), .string("B")]),
                            "has_deadline": .bool(false),
                            "pin": .bool(true),
                            "multi": .bool(true),
                            "allow_add": .bool(true),
                            "hide_preview": .bool(false),
                            "anonymous": .bool(true),
                        ]),
                    ]),
                ]),
                // C: missing created id -> pinSkipped
                .object([
                    "cmd": .string("create_poll"),
                    "args": .object([
                        "conv_id": .string("g501201"),
                        "can_pin": .bool(true),
                        "draft": .object([
                            "question": .string("Thiếu id"),
                            "options": .array([.string("1"), .string("2")]),
                            "pin": .bool(true),
                        ]),
                    ]),
                ]),
                // D: pin failing after create -> pinSkipped
                .object([
                    "cmd": .string("create_poll"),
                    "args": .object([
                        "conv_id": .string("g501201"),
                        "can_pin": .bool(true),
                        "draft": .object([
                            "question": .string("Ghim lỗi"),
                            "options": .array([.string("1"), .string("2")]),
                            "pin": .bool(true),
                        ]),
                    ]),
                ]),
                // E-J: error mappings
                .object(["cmd": .string("create_poll"), "args": .object(["conv_id": .string("g501201"), "can_pin": .bool(false), "draft": .object(["question": .string("E1"), "options": .array([.string("A"), .string("B")])])])]),
                .object(["cmd": .string("create_poll"), "args": .object(["conv_id": .string("g501201"), "can_pin": .bool(false), "draft": .object(["question": .string("E2"), "options": .array([.string("A"), .string("B")])])])]),
                .object(["cmd": .string("create_poll"), "args": .object(["conv_id": .string("g501201"), "can_pin": .bool(false), "draft": .object(["question": .string("E3"), "options": .array([.string("A"), .string("B")])])])]),
                .object(["cmd": .string("create_poll"), "args": .object(["conv_id": .string("g501201"), "can_pin": .bool(false), "draft": .object(["question": .string("E4"), "options": .array([.string("A"), .string("B")])])])]),
                .object(["cmd": .string("create_poll"), "args": .object(["conv_id": .string("g501201"), "can_pin": .bool(false), "draft": .object(["question": .string("E5"), "options": .array([.string("A"), .string("B")])])])]),
                .object(["cmd": .string("create_poll"), "args": .object(["conv_id": .string("g501201"), "can_pin": .bool(false), "draft": .object(["question": .string("E6"), "options": .array([.string("A"), .string("B")])])])]),
                // Pure model checks for PollConfig, PollCreateDraft.issue/isDuplicate, PollActionResult.message(for:)
                .object([
                    "cmd": .string("poll_model_checks"),
                    "args": .object([
                        "checks": .array([
                            .object(["kind": .string("create_draft_branches")]),
                            .object(["kind": .string("poll_config_branches")]),
                            .object(["kind": .string("action_result_messages")]),
                        ]),
                    ]),
                ]),
            ]
        )

        // 13. note_messages
        let s13 = PollRecorderHarness.ScenarioDef(
            name: "note_messages",
            seed: MessageRecorderHarness.readySessionSeed(
                userId: "2001001",
                displayName: "Polls User",
                suppress: ["ws", "long_poll"],
                extras: [
                    "cached_group_details": .object([
                        "501301": .object(["groupId": .string("501301"), "creatorId": .string("2001001")]),
                    ]),
                    "polls": .object([
                        "details": .object([
                            "1301": .object([
                                "id": .string("1301"),
                                "groupId": .string("g501301"),
                                "question": .string("Ban đầu"),
                                "creator": .string("2001001"),
                                "creatorName": .string("Bạn"),
                                "closed": .bool(false),
                                "joined": .bool(false),
                                "multi": .bool(false),
                                "allowAdd": .bool(false),
                                "anonymous": .bool(false),
                                "hidePreview": .bool(false),
                                "voters": .int(0),
                                "canClose": .bool(true),
                                "options": .array([]),
                            ]),
                        ]),
                    ]),
                ]
            ),
            server: [
                MessageRecorderHarness.loginInfoScript(uid: "2001001", displayName: "Polls User"),
                MessageRecorderHarness.profileMeScript(uid: "2001001", displayName: "Polls User"),
                PollRecorderHarness.httpScript(
                    path: "/api/poll/detail",
                    method: "GET",
                    json: pollDetailPayload(groupIdKey: "group_id", groupIdValue: "501301", question: "Đã cập nhật sau 1.5s")
                ),
            ],
            steps: [
                .object(["cmd": .string("start")]),
                .object(["await": .object(["phase": .string("ready")])]),
                // m1 fresh (< 120s) on loaded 1301 -> schedules 1.5s debounce
                .object([
                    "cmd": .string("note_poll_messages"),
                    "now_ms": .int(1700010000000),
                    "args": .object([
                        "conv_id": .string("g501301"),
                        "ids": .array([
                            .object(["id": .string("pm1"), "poll_id": .string("1301"), "date_ms": .int(1700009990000)]),
                        ]),
                    ]),
                ]),
                .object(["snapshot": .string("debouncing_1301")]),
                // Duplicate pm1, stale pm3 (exact 120s cutoff), unloaded 1302 pm4, plus fresh pm2 after 500ms -> resets debounce to 1.5s
                .object(["cmd": .string("advance_ms"), "args": .object(["ms": .int(500)])]),
                .object([
                    "cmd": .string("note_poll_messages"),
                    "now_ms": .int(1700010000500),
                    "args": .object([
                        "conv_id": .string("g501301"),
                        "ids": .array([
                            .object(["id": .string("pm1"), "poll_id": .string("1301"), "date_ms": .int(1700009990000)]),
                            .object(["id": .string("pm3_old"), "poll_id": .string("1301"), "date_ms": .int(1700009880500)]),
                            .object(["id": .string("pm4_unloaded"), "poll_id": .string("1302"), "date_ms": .int(1700010000400)]),
                            .object(["id": .string("pm2"), "poll_id": .string("1301"), "date_ms": .int(1700010000400)]),
                        ]),
                    ]),
                ]),
                .object(["snapshot": .string("debounce_reset_at_500ms")]),
                // Advance 1000ms (total 1500ms from t=0, only 1000ms from reset) -> must NOT fire yet
                .object(["cmd": .string("advance_ms"), "args": .object(["ms": .int(1000)])]),
                .object(["snapshot": .string("still_pending_before_1500ms_from_reset")]),
                // Advance 500ms -> fires ONE refresh
                .object(["cmd": .string("advance_ms"), "args": .object(["ms": .int(500)])]),
            ]
        )

        // 14. state_and_reset
        let twoThousandSeen: [CaseJSON] = (1...2000).map { .string(String(format: "sm%04d", $0)) }
        let s14 = PollRecorderHarness.ScenarioDef(
            name: "state_and_reset",
            seed: MessageRecorderHarness.readySessionSeed(
                userId: "2001001",
                displayName: "Polls User",
                suppress: ["ws", "long_poll"],
                extras: [
                    "cached_group_details": .object([
                        "501401": .object(["groupId": .string("501401"), "creatorId": .string("2001001")]),
                    ]),
                    "poll_clock": .object([
                        "seen_messages": .array(twoThousandSeen),
                    ]),
                ]
            ),
            server: [
                MessageRecorderHarness.loginInfoScript(uid: "2001001", displayName: "Polls User"),
                MessageRecorderHarness.profileMeScript(uid: "2001001", displayName: "Polls User"),
                // watch_poll 1403 fails
                PollRecorderHarness.httpScript(path: "/api/poll/detail", method: "GET", status: 500, raw: "Watch fail"),
                // rewatch_polls fetches 1403 and succeeds
                PollRecorderHarness.httpScript(
                    path: "/api/poll/detail",
                    method: "GET",
                    json: pollDetailPayload(groupIdKey: "group_id", groupIdValue: "501401", question: "Rewatched 1403")
                ),
            ],
            steps: [
                .object(["cmd": .string("start")]),
                .object(["await": .object(["phase": .string("ready")])]),
                // handlePoll(state:) detail shape for 1401
                .object([
                    "cmd": .string("poll_state"),
                    "args": .object([
                        "json": .object([
                            "poll": .object([
                                "id": .string("1401"),
                                "detail": .object([
                                    "id": .string("1401"),
                                    "groupId": .string("g501401"),
                                    "question": .string("Từ adapter state"),
                                    "creator": .string("2001001"),
                                    "creatorName": .string("Bạn"),
                                    "closed": .bool(false),
                                    "joined": .bool(false),
                                    "multi": .bool(true),
                                    "allowAdd": .bool(true),
                                    "anonymous": .bool(false),
                                    "hidePreview": .bool(false),
                                    "voters": .int(0),
                                    "canClose": .bool(true),
                                    "options": .array([
                                        .object(["id": .string("1"), "content": .string("Một"), "votes": .int(0), "voted": .bool(false)]),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
                // handlePoll(state:) error shape on unloaded 1402 -> failed
                .object([
                    "cmd": .string("poll_state"),
                    "args": .object([
                        "json": .object([
                            "poll": .object([
                                "id": .string("1402"),
                                "error": .string("not_found"),
                            ]),
                        ]),
                    ]),
                ]),
                // handlePoll(state:) error shape on already loaded 1401 -> NOT added to failed
                .object([
                    "cmd": .string("poll_state"),
                    "args": .object([
                        "json": .object([
                            "poll": .object([
                                "id": .string("1401"),
                                "error": .string("transient"),
                            ]),
                        ]),
                    ]),
                ]),
                // watch_poll 1403 fails, then rewatch_polls retries and loads it
                .object(["cmd": .string("watch_poll"), "now_ms": .int(1700010000000), "args": .object(["id": .string("1403"), "conv_id": .string("g501401")])]),
                .object(["cmd": .string("rewatch_polls"), "now_ms": .int(1700010001000), "args": .object([:])]),
                // note_poll_messages hits >2000 seenMessages cap -> resets seenMessages to [pm_cap], parks pending debounce on 1401
                .object([
                    "cmd": .string("note_poll_messages"),
                    "now_ms": .int(1700010002000),
                    "args": .object([
                        "conv_id": .string("g501401"),
                        "ids": .array([
                            .object(["id": .string("pm_cap"), "poll_id": .string("1401"), "date_ms": .int(1700010001500)]),
                        ]),
                    ]),
                ]),
                .object(["snapshot": .string("before_reset")]),
                // reset_polls clears polls, watched, lastAttempt, seenMessages, and cancels pending debounce
                .object(["cmd": .string("reset_polls")]),
                .object(["cmd": .string("advance_ms"), "args": .object(["ms": .int(2000)])]),
            ]
        )

        return [s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11, s12, s13, s14]
    }
}

// MARK: - Virtual Debounce Clock

@MainActor
private final class VirtualPollClock {
    private struct TimerEntry {
        let id: UUID
        let fireAtMs: Int64
        let cont: CheckedContinuation<Bool, Never>
    }

    var currentMs: Int64 = 1_700_000_000_000
    private var timers: [TimerEntry] = []

    func sleep(ms: Int) async -> Bool {
        let targetMs = currentMs + Int64(ms)
        let timerId = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    cont.resume(returning: false)
                } else {
                    self.timers.append(TimerEntry(id: timerId, fireAtMs: targetMs, cont: cont))
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

    func advance(by ms: Int64) {
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
    }

    func cancelAll() {
        let pending = timers
        timers.removeAll()
        for entry in pending {
            entry.cont.resume(returning: false)
        }
    }
}

// MARK: - Harness

enum PollRecorderHarness {
    enum RecorderError: Error, CustomStringConvertible {
        case timeout(scenario: String, detail: String)
        case unscriptedRequest(scenario: String, detail: String)
        case invalidSeed(scenario: String, detail: String)
        case invalidStep(scenario: String, detail: String)

        var description: String {
            switch self {
            case .timeout(let s, let d): return "[\(s)] timeout: \(d)"
            case .unscriptedRequest(let s, let d): return "[\(s)] unscripted HTTP request(s): \(d)"
            case .invalidSeed(let s, let d): return "[\(s)] invalid seed: \(d)"
            case .invalidStep(let s, let d): return "[\(s)] invalid step: \(d)"
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
        status: Int = 200,
        json: CaseJSON? = nil,
        raw: String? = nil,
        error: String? = nil,
        hold: Bool = false,
        repeatResponse: Bool = false
    ) -> CaseJSON {
        var resp: [String: CaseJSON] = ["status": .int(Int64(status))]
        if let json { resp["json"] = json }
        if let raw { resp["raw"] = .string(raw) }
        if let error { resp["error"] = .string(error) }
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

    private static var shouldRecord: Bool {
        ProcessInfo.processInfo.environment["OLAZ_RECORD"] == "1"
    }

    private static var shouldRunSlowCases: Bool {
        shouldRecord || ProcessInfo.processInfo.environment["OLAZ_SLOW_CASES"] == "1"
    }

    @MainActor
    static func runDomain(domain: String, scenarios: [ScenarioDef]) async throws {
        let sorted = scenarios.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
        let url = CaseFile.casesURL(domain: domain)

        if shouldRecord {
            var recorded: [CaseJSON] = []
            recorded.reserveCapacity(sorted.count)
            for scenario in sorted {
                recorded.append(try await recordScenario(domain: domain, scenario))
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
        XCTAssertEqual(byName.count, sorted.count, "\(domain).jsonl case count mismatch (run with OLAZ_RECORD=1 to regenerate)")

        for scenario in sorted {
            if scenario.slow && !shouldRunSlowCases {
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
            .appendingPathComponent("olaz-poll-recorder-\(scenario.name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let storage = RecorderStorageIsolation(prefix: "olaz.poll-recorder")
        EngineLog.shared.onAppend = nil

        let virtualClock = VirtualPollClock()

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

        func toFoundationDict(_ json: CaseJSON) -> [String: Any]? {
            let sub = substituteRuntimeURLs(json)
            return (try? JSONSerialization.jsonObject(with: Data(sub.canonicalString().utf8))) as? [String: Any]
        }

        let seededUserId = scenario.seed["saved_session"]?["plainAccount"]?["userId"]?.stringValue
        if let saved = scenario.seed["saved_session"], saved != .null {
            let sub = substituteRuntimeURLs(saved)
            let fileURL = dataDir.appendingPathComponent("native-session.json")
            try Data(sub.canonicalString().utf8).write(to: fileURL, options: .atomic)
        }

        if let uid = seededUserId, !uid.isEmpty {
            try await seedSQLiteStore(userId: uid, dataDir: dataDir, seed: substituteRuntimeURLs(scenario.seed))
        }

        let domainsJSON = substituteRuntimeURLs(scenario.seed["domains"] ?? defaultFakeDomainsJSON())
        let domains = try JSONDecoder().decode(ZaloDomains.self, from: Data(domainsJSON.canonicalString().utf8))
        try assertOnlyLocalFakeHosts(domains, scenario: scenario.name, stage: "initial seed")

        let engine = ZaloEngine(
            dataDirectory: dataDir,
            useKeychain: false,
            domains: domains,
            userDefaultsSuiteName: storage.userDefaultsSuiteName,
            cookieStorage: storage.cookieStorage
        )
        engine.resetPolls()
        engine.nowMs = { virtualClock.currentMs }
        engine.pollDebounceSleep = { ms in
            await virtualClock.sleep(ms: ms)
        }

        defer {
            EngineLog.shared.onAppend = nil
            virtualClock.cancelAll()
            engine.resetPolls()
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
        if let detailsObj = scenario.seed["cached_group_details"]?.objectValue {
            var seededDetails: [String: [String: Any]] = [:]
            for (k, v) in detailsObj {
                if let parsed = toFoundationDict(v) {
                    seededDetails[k] = parsed
                }
            }
            engine.cachedGroupDetails = seededDetails
        }
        if let memberCacheObj = scenario.seed["group_member_cache"]?.objectValue {
            var seededCache: [String: [MentionCandidate]] = [:]
            for (gid, arrVal) in memberCacheObj {
                let arr = substituteRuntimeURLs(arrVal).arrayValue ?? []
                seededCache[gid] = arr.compactMap { row in
                    guard let id = row["id"]?.stringValue else { return nil }
                    let name = row["name"]?.stringValue ?? ""
                    let avt = row["avatar"]?.stringValue.flatMap(URL.init(string:))
                    let isAll = row["is_all"]?.boolValue ?? false
                    return MentionCandidate(id: id, name: name, avatar: avt, isAll: isAll)
                }
            }
            engine.groupMemberCache = seededCache
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
        if let pollsSeed = scenario.seed["polls"], pollsSeed != .null {
            if let detailsObj = pollsSeed["details"]?.objectValue {
                for (pid, dVal) in detailsObj {
                    if let dDict = toFoundationDict(dVal), let d = PollDetail(json: dDict) {
                        engine.polls.details[pid] = d
                    }
                }
            }
            if let failedArr = pollsSeed["failed"]?.arrayValue {
                engine.polls.failed = Set(failedArr.compactMap(\.stringValue))
            }
            if let pinsObj = pollsSeed["pins"]?.objectValue {
                for (pid, pVal) in pinsObj {
                    if var pDict = toFoundationDict(pVal) {
                        if pDict["canPin"] == nil, let snake = pDict["can_pin"] {
                            pDict["canPin"] = snake
                        }
                        engine.polls.pins[pid] = PollPinState(json: pDict)
                    }
                }
            }
        }
        if let pinsObj = scenario.seed["pins"]?.objectValue {
            for (convId, listVal) in pinsObj {
                if let listDict = toFoundationDict(listVal) {
                    engine.pins[convId] = PinnedList(json: listDict)
                }
            }
        }
        if let rawTopicsObj = scenario.seed["board_raw_topics"]?.objectValue {
            for (convId, entry) in rawTopicsObj {
                let version = entry["version"]?.int64Value ?? 0
                var topicsMap: [String: [String: Any]] = [:]
                if let tObj = entry["topics"]?.objectValue {
                    for (tid, tVal) in tObj {
                        if let tDict = toFoundationDict(tVal) {
                            topicsMap[tid] = tDict
                        }
                    }
                }
                engine.cachedBoardRawTopics[convId] = (version: version, topics: topicsMap)
            }
        }
        if let clockSeed = scenario.seed["poll_clock"], clockSeed != .null {
            if let watchedObj = clockSeed["watched"]?.objectValue {
                for (pid, convVal) in watchedObj {
                    if let convId = convVal.stringValue {
                        PollClock.watched[pid] = convId
                    }
                }
            }
            if let attemptObj = clockSeed["last_attempt_ms"]?.objectValue {
                for (pid, msVal) in attemptObj {
                    if let ms = msVal.int64Value {
                        PollClock.lastAttempt[pid] = Date(timeIntervalSince1970: Double(ms) / 1000.0)
                    }
                }
            }
            if let seenArr = clockSeed["seen_messages"]?.arrayValue {
                PollClock.seenMessages = Set(seenArr.compactMap(\.stringValue))
            }
        }

        let watchedCheckIds = scenario.seed["watched_check_ids"]?.arrayValue?.compactMap(\.stringValue)

        var bootstrapLogs: [String] = []
        var sendLogs: [String] = []
        var actionLogs: [String] = []
        var groupLogs: [String] = []
        var results: [String: CaseJSON] = [:]

        EngineLog.shared.onAppend = { rawLine in
            if let sp = rawLine.firstIndex(of: " ") {
                let msg = String(rawLine[rawLine.index(after: sp)...])
                if msg.hasPrefix("bootstrap: ") { bootstrapLogs.append(msg) }
                if msg.hasPrefix("sendText ") { sendLogs.append(msg) }
                if msg.hasPrefix("react failed") || msg.hasPrefix("recall failed") || msg.hasPrefix("autodelete: ") {
                    actionLogs.append(msg)
                }
                if msg.hasPrefix("group create failed: ")
                    || msg.hasPrefix("group avatar upload failed: ")
                    || msg.hasPrefix("rename group failed: ")
                    || msg.hasPrefix("invite group members failed: ")
                    || msg.hasPrefix("kick group member failed: ")
                    || msg.hasPrefix("leave group failed: ")
                    || msg.hasPrefix("group admin: failed code=")
                {
                    groupLogs.append(msg)
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
            case "apply_batch", "apply_parsed_events":
                return true
            case "start_ws":
                return !suppressedTransports.contains("ws")
            case "start_long_poll":
                return !suppressedTransports.contains("long_poll")
            default:
                return false
            }
        }

        let transitionRecorder = PollTransitionRecorder(scenarioName: scenario.name) {
            normalizeRecordedURLs(await PollSnapshot.capture(from: engine, watchedCheckIds: watchedCheckIds))
        }

        engine.stateTrace = { [weak transitionRecorder] in
            transitionRecorder?.recordTransition()
        }
        engine.transportSettleTrace = {
            settleCount += 1
            notifySignal()
        }

        @MainActor
        func waitForCondition(timeoutMs: Int, description: String, _ predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
            while !predicate() {
                let remaining = deadline - ContinuousClock.now
                if remaining <= .zero {
                    throw RecorderError.timeout(scenario: scenario.name, detail: "timed out waiting for \(description)")
                }
                let waiterId = UUID()
                let timeoutTask = Task { @MainActor in
                    try? await Task.sleep(for: min(remaining, .milliseconds(50)))
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

        transitionRecorder.recordTransition()

        var snapshots: [String: CaseJSON] = [:]

        for (stepIndex, step) in scenario.steps.enumerated() {
            if let cmd = step["cmd"]?.stringValue {
                let args = step["args"]
                if let stepNowMs = step["now_ms"]?.int64Value {
                    virtualClock.currentMs = stepNowMs
                }

                switch cmd {
                case "start":
                    engine.start()
                case "open":
                    _ = await engine.bootTask?.value
                    let id = args?["id"]?.stringValue ?? ""
                    engine.openConversation(id)
                    _ = await engine.openConversationTask?.value
                    await engine.awaitContactsTasksForRecording()
                    _ = await engine.persistConversationsTask?.value
                case "close":
                    _ = await engine.bootTask?.value
                    engine.closeConversation()
                case "watch_poll":
                    _ = await engine.bootTask?.value
                    let id = args?["id"]?.stringValue ?? ""
                    let convId = args?["conv_id"]?.stringValue ?? ""
                    engine.watchPoll(id, in: convId)
                    await engine.awaitPollTasksForRecording()
                case "retry_poll":
                    _ = await engine.bootTask?.value
                    let id = args?["id"]?.stringValue ?? ""
                    let convId = args?["conv_id"]?.stringValue ?? ""
                    engine.retryPoll(id, in: convId)
                    await engine.awaitPollTasksForRecording()
                case "rewatch_polls":
                    _ = await engine.bootTask?.value
                    engine.rewatchPolls()
                    await engine.awaitPollTasksForRecording()
                case "refresh_poll":
                    _ = await engine.bootTask?.value
                    let id = args?["id"]?.stringValue ?? ""
                    engine.refreshPoll(id)
                    await engine.awaitPollTasksForRecording()
                case "poll_voters":
                    _ = await engine.bootTask?.value
                    let id = args?["id"]?.stringValue ?? ""
                    let voters = await engine.pollVoters(id)
                    results["\(stepIndex)"] = normalizeRecordedURLs(voters.map { v in
                        .object([
                            "restricted": .bool(v.restricted),
                            "groups": .array(v.groups.map { g in
                                .object([
                                    "id": .string(g.id),
                                    "content": .string(g.content),
                                    "votes": .int(Int64(g.votes)),
                                    "users": .array(g.users.map { u in
                                        .object([
                                            "uid": .string(u.uid),
                                            "name": .string(u.name),
                                            "avatar": u.avatar.map { .string($0.absoluteString) } ?? .null,
                                            "is_me": .bool(u.isMe),
                                        ])
                                    }),
                                ])
                            }),
                        ])
                    } ?? .null)
                case "refresh_poll_pin":
                    _ = await engine.bootTask?.value
                    let id = args?["id"]?.stringValue ?? ""
                    let convId = args?["conv_id"]?.stringValue ?? ""
                    let pinState = await engine.refreshPollPin(id, in: convId)
                    results["\(stepIndex)"] = PollSnapshot.encodePollPinState(pinState)
                case "pin_poll":
                    _ = await engine.bootTask?.value
                    let id = args?["id"]?.stringValue ?? ""
                    let convId = args?["conv_id"]?.stringValue ?? ""
                    let confirming = args?["confirming"]?.stringValue
                    let outcome = await engine.pinPoll(id, in: convId, confirming: confirming)
                    await engine.awaitPollTasksForRecording()
                    let outcomeJSON: CaseJSON
                    switch outcome {
                    case .done:
                        outcomeJSON = .object(["status": .string("done")])
                    case .needsConfirmation(let confirm):
                        outcomeJSON = .object([
                            "status": .string("needs_confirmation"),
                            "ref": .string(confirm.ref),
                            "limit": .int(Int64(confirm.limit)),
                            "kind": .string(confirm.kind),
                            "title": .string(confirm.title),
                            "message": .string(confirm.message),
                        ])
                    case .failed(let res):
                        outcomeJSON = .object([
                            "status": .string("failed"),
                            "ok": .bool(res.ok),
                            "error": res.error.map(CaseJSON.string) ?? .null,
                            "pin_skipped": .bool(res.pinSkipped),
                            "message": .string(res.message(for: .pin)),
                        ])
                    }
                    results["\(stepIndex)"] = outcomeJSON
                case "unpin_poll":
                    _ = await engine.bootTask?.value
                    let id = args?["id"]?.stringValue ?? ""
                    let convId = args?["conv_id"]?.stringValue ?? ""
                    let res = await engine.unpinPoll(id, in: convId)
                    await engine.awaitPollTasksForRecording()
                    results["\(stepIndex)"] = .object([
                        "ok": .bool(res.ok),
                        "error": res.error.map(CaseJSON.string) ?? .null,
                        "pin_skipped": .bool(res.pinSkipped),
                        "message": .string(res.message(for: .unpin)),
                    ])
                case "vote_poll":
                    _ = await engine.bootTask?.value
                    let id = args?["id"]?.stringValue ?? ""
                    let convId = args?["conv_id"]?.stringValue ?? ""
                    let detail: PollDetail? = {
                        if args?["detail_from"]?.stringValue == "state" {
                            return engine.polls.details[id]
                        }
                        if let df = args?["detail_from"], let dict = toFoundationDict(df) {
                            return PollDetail(json: dict)
                        }
                        return engine.polls.details[id]
                    }()
                    guard let detail else {
                        throw RecorderError.invalidStep(scenario: scenario.name, detail: "vote_poll missing detail for \(id)")
                    }
                    var draft = PollVoteDraft(detail)
                    if let toggles = args?["draft"]?["toggle"]?.arrayValue {
                        for item in toggles {
                            if let optId = item.stringValue {
                                draft.toggle(optId)
                            }
                        }
                    }
                    if let addedArr = args?["draft"]?["added"]?.arrayValue {
                        for item in addedArr {
                            draft.addRow()
                            let idx = draft.added.count - 1
                            draft.added[idx].text = item["text"]?.stringValue ?? ""
                            let voted = item["voted"]?.boolValue ?? false
                            draft.setAddedVoted(draft.added[idx].id, voted)
                        }
                    }
                    let req = draft.request(for: detail)
                    let applied = draft.applied(to: detail)
                    let hasChanges = draft.hasChanges
                    let votesNothing = draft.votesNothing
                    let hasDuplicates = draft.hasDuplicates(in: detail)
                    let canSubmit = draft.canSubmit
                    let res = await engine.votePoll(id, in: convId, draft: draft, detail: detail)
                    await engine.awaitPollTasksForRecording()
                    results["\(stepIndex)"] = .object([
                        "ok": .bool(res.ok),
                        "error": res.error.map(CaseJSON.string) ?? .null,
                        "pin_skipped": .bool(res.pinSkipped),
                        "message": .string(res.message(for: .vote)),
                        "request": .object([
                            "new_options": CaseJSON.fromAny(req.newOptions),
                            "voted_ids": .array(req.votedIds.map(CaseJSON.string)),
                        ]),
                        "applied": PollSnapshot.encodeDetail(applied),
                        "has_changes": .bool(hasChanges),
                        "votes_nothing": .bool(votesNothing),
                        "has_duplicates": .bool(hasDuplicates),
                        "can_submit": .bool(canSubmit),
                    ])
                case "lock_poll":
                    _ = await engine.bootTask?.value
                    let id = args?["id"]?.stringValue ?? ""
                    let convId = args?["conv_id"]?.stringValue ?? ""
                    let res = await engine.lockPoll(id, in: convId)
                    await engine.awaitPollTasksForRecording()
                    results["\(stepIndex)"] = .object([
                        "ok": .bool(res.ok),
                        "error": res.error.map(CaseJSON.string) ?? .null,
                        "pin_skipped": .bool(res.pinSkipped),
                        "message": .string(res.message(for: .lock)),
                    ])
                case "share_poll":
                    _ = await engine.bootTask?.value
                    let id = args?["id"]?.stringValue ?? ""
                    let convId = args?["conv_id"]?.stringValue ?? ""
                    let res = await engine.sharePoll(id, in: convId)
                    results["\(stepIndex)"] = .object([
                        "ok": .bool(res.ok),
                        "error": res.error.map(CaseJSON.string) ?? .null,
                        "pin_skipped": .bool(res.pinSkipped),
                        "message": .string(res.message(for: .share)),
                    ])
                case "create_poll":
                    _ = await engine.bootTask?.value
                    let convId = args?["conv_id"]?.stringValue ?? ""
                    let canPin = args?["can_pin"]?.boolValue ?? false
                    let cfg: PollConfig = {
                        if let cVal = args?["config"], cVal != .null, let cDict = toFoundationDict(cVal) {
                            return PollConfig(json: cDict)
                        }
                        return PollConfig()
                    }()
                    var draft = PollCreateDraft(config: cfg)
                    if let dObj = args?["draft"] {
                        draft.question = dObj["question"]?.stringValue ?? ""
                        if let opts = dObj["options"]?.arrayValue {
                            draft.options = opts.compactMap(\.stringValue)
                        }
                        draft.hasDeadline = dObj["has_deadline"]?.boolValue ?? false
                        if let dlMs = dObj["deadline_ms"]?.int64Value {
                            draft.deadline = Date(timeIntervalSince1970: Double(dlMs) / 1000.0)
                        }
                        draft.pin = dObj["pin"]?.boolValue ?? false
                        draft.multi = dObj["multi"]?.boolValue ?? true
                        draft.allowAdd = dObj["allow_add"]?.boolValue ?? true
                        draft.hidePreview = dObj["hide_preview"]?.boolValue ?? false
                        draft.anonymous = dObj["anonymous"]?.boolValue ?? false
                    }
                    let spec = draft.spec(config: cfg, canPin: canPin)
                    let res = await engine.createPoll(in: convId, draft: draft, config: cfg, canPin: canPin)
                    await engine.awaitPollTasksForRecording()
                    results["\(stepIndex)"] = .object([
                        "ok": .bool(res.ok),
                        "error": res.error.map(CaseJSON.string) ?? .null,
                        "pin_skipped": .bool(res.pinSkipped),
                        "message": .string(res.message(for: .create)),
                        "spec": CaseJSON.fromAny(spec),
                    ])
                case "note_poll_messages":
                    _ = await engine.bootTask?.value
                    let convId = args?["conv_id"]?.stringValue ?? ""
                    let items = args?["ids"]?.arrayValue ?? []
                    let incoming: [ChatMessage] = items.map { row in
                        let msgId = row["id"]?.stringValue ?? ""
                        let pollId = row["poll_id"]?.stringValue ?? ""
                        let dateMs = row["date_ms"]?.int64Value ?? 0
                        let question = row["question"]?.stringValue ?? "Poll"
                        return ChatMessage(
                            id: msgId,
                            conversationId: convId,
                            senderId: "3001001",
                            senderName: "An",
                            senderAvatar: nil,
                            isMine: false,
                            kind: .poll(ChatMessage.PollInfo(
                                question: question,
                                header: "",
                                anonymous: false,
                                pollId: pollId,
                                conversationId: convId
                            )),
                            text: question,
                            date: Date(timeIntervalSince1970: Double(dateMs) / 1000.0),
                            status: .sent,
                            quote: nil,
                            reactions: [],
                            isE2EE: false,
                            mentions: [],
                            cardButtons: [],
                            suggestsStickers: false,
                            menu: MessageMenu(),
                            clientId: msgId
                        )
                    }
                    engine.notePollMessages(incoming)
                    await Task.yield()
                case "advance_ms":
                    _ = await engine.bootTask?.value
                    let ms = args?["ms"]?.int64Value ?? 0
                    virtualClock.advance(by: ms)
                    await Task.yield()
                    await Task.yield()
                    await engine.awaitPollTasksForRecording()
                case "poll_state":
                    _ = await engine.bootTask?.value
                    if let jVal = args?["json"], let dict = toFoundationDict(jVal) {
                        engine.handlePoll(state: dict)
                    }
                case "pins_state":
                    _ = await engine.bootTask?.value
                    if let jVal = args?["json"], let dict = toFoundationDict(jVal) {
                        engine.handlePins(state: dict)
                    }
                case "reset_polls":
                    _ = await engine.bootTask?.value
                    virtualClock.cancelAll()
                    engine.resetPolls()
                    await Task.yield()
                case "poll_model_checks":
                    _ = await engine.bootTask?.value
                    let checks = args?["checks"]?.arrayValue ?? []
                    var checkResults: [CaseJSON] = []
                    for check in checks {
                        let kind = check["kind"]?.stringValue ?? ""
                        switch kind {
                        case "resolve_group_explicit":
                            let pollId = check["poll_id"]?.stringValue ?? ""
                            let explicit = check["explicit"]?.stringValue
                            var payload: [String: Any] = [:]
                            if let pg = check["payload_group"]?.stringValue {
                                payload["group_id"] = pg
                            }
                            let resolved = engine.resolvePollGroupId(id: pollId, payload: payload, explicit: explicit)
                            checkResults.append(.object([
                                "kind": .string(kind),
                                "resolved": .string(resolved),
                            ]))
                        case "is_group_admin":
                            let uid = check["uid"]?.stringValue ?? ""
                            let groupId = check["group_id"]?.stringValue ?? ""
                            let ok = engine.isGroupAdminOrCreator(uid, inGroup: groupId)
                            checkResults.append(.object([
                                "kind": .string(kind),
                                "uid": .string(uid),
                                "group_id": .string(groupId),
                                "ok": .bool(ok),
                            ]))
                        case "poll_capabilities":
                            let convId = check["conv_id"]?.stringValue ?? ""
                            let caps = await engine.pollCapabilities(in: convId)
                            checkResults.append(.object([
                                "kind": .string(kind),
                                "conv_id": .string(convId),
                                "ready": .bool(caps.ready),
                                "can_create": .bool(caps.canCreate),
                                "can_pin": .bool(caps.canPin),
                            ]))
                        case "map_pin_error":
                            let err: Error = {
                                if check["other"]?.boolValue == true {
                                    return NSError(domain: "PollTest", code: 1)
                                }
                                let code = Int(check["code"]?.int64Value ?? 999)
                                let msg = check["message"]?.stringValue ?? ""
                                return ZaloSessionError(code: code, message: msg, url: "http://fake")
                            }()
                            let res = ZaloEngine.mapPollPinError(err)
                            checkResults.append(.object([
                                "kind": .string(kind),
                                "ok": .bool(res.ok),
                                "error": res.error.map(CaseJSON.string) ?? .null,
                            ]))
                        case "pin_confirm_message":
                            let ref = check["ref"]?.stringValue ?? ""
                            let limit = Int(check["limit"]?.int64Value ?? 0)
                            let pinKind = check["pin_kind"]?.stringValue ?? ""
                            let title = check["title"]?.stringValue ?? ""
                            let confirm = PollPinConfirm(ref: ref, limit: limit, kind: pinKind, title: title)
                            checkResults.append(.object([
                                "kind": .string(kind),
                                "message": .string(confirm.message),
                            ]))
                        case "vote_draft_branches":
                            let zeroDetail = PollDetail(json: [
                                "id": "vd1",
                                "groupId": "g1",
                                "question": "Single",
                                "multi": false,
                                "options": [
                                    ["id": "1", "content": "One", "votes": 0, "voted": false],
                                    ["id": "2", "content": "Two", "votes": 1, "voted": true],
                                ],
                            ])!
                            var vd = PollVoteDraft(zeroDetail)
                            let noChange = vd.hasChanges
                            let initialVotesNothing = vd.votesNothing
                            vd.addRow()
                            let r0 = vd.added[0].id
                            vd.added[0].text = "  One  "
                            vd.setAddedVoted(r0, true) // clears selected "2" because single-choice
                            let afterAddSelect = vd.request(for: zeroDetail)
                            let dupRow = vd.isDuplicate(r0, in: zeroDetail)
                            let hasDups = vd.hasDuplicates(in: zeroDetail)
                            vd.toggle("1") // single-choice clears added[0].voted!
                            let afterToggle1 = vd.request(for: zeroDetail)
                            vd.removeAdded(r0)
                            let afterRemove = vd.votesNothing
                            vd.toggle("1") // unticks "1" -> votes nothing
                            let finalVotesNothing = vd.votesNothing
                            checkResults.append(.object([
                                "kind": .string(kind),
                                "initial_no_change": .bool(!noChange),
                                "initial_votes_nothing": .bool(initialVotesNothing),
                                "after_add_voted_ids": .array(afterAddSelect.votedIds.map(CaseJSON.string)),
                                "dup_row": .bool(dupRow),
                                "has_dups": .bool(hasDups),
                                "after_toggle_added_voted": CaseJSON.fromAny(afterToggle1.newOptions),
                                "after_remove_votes_nothing": .bool(afterRemove),
                                "final_votes_nothing": .bool(finalVotesNothing),
                            ]))
                        case "detail_branches":
                            let zeroVotes = PollDetail(json: [
                                "id": "db1",
                                "groupId": "g1",
                                "question": "Empty",
                                "expired": 1_700_010_000_000,
                                "closed": false,
                                "hidePreview": true,
                                "joined": true,
                                "options": [["id": "1", "content": "A", "votes": 0, "voted": false]],
                            ])!
                            let beforeExp = Date(timeIntervalSince1970: 1_700_009_999)
                            let afterExp = Date(timeIntervalSince1970: 1_700_010_001)
                            let w0 = zeroVotes.weight(of: zeroVotes.options[0])
                            checkResults.append(.object([
                                "kind": .string(kind),
                                "weight_zero": .double(w0, raw: String(w0)),
                                "expired_before": .bool(zeroVotes.isExpired(at: beforeExp)),
                                "expired_after": .bool(zeroVotes.isExpired(at: afterExp)),
                                "locked_before": .bool(zeroVotes.isVotingLocked(at: beforeExp)),
                            ]))
                        case "create_draft_branches":
                            func issueTag(_ issue: PollCreateDraft.Issue?) -> String {
                                switch issue {
                                case .none: return "none"
                                case .emptyQuestion: return "empty_question"
                                case .duplicate: return "duplicate"
                                case .tooFewOptions(let n): return "too_few_options(\(n))"
                                case .pastDeadline: return "past_deadline"
                                }
                            }
                            let cfg = PollConfig(json: ["minOptions": 2])
                            let refNow = Date(timeIntervalSince1970: 1_700_010_000)
                            var d = PollCreateDraft(config: cfg)
                            let emptyIssue = issueTag(d.issue(config: cfg, now: refNow))
                            d.question = "Q?"
                            d.options = ["A", "A"]
                            let dup0 = d.isDuplicate(at: 0)
                            let dupOOB = d.isDuplicate(at: 99)
                            let dupIssue = issueTag(d.issue(config: cfg, now: refNow))
                            d.options = ["A", ""]
                            let fewIssue = issueTag(d.issue(config: cfg, now: refNow))
                            d.options = ["A", "B"]
                            d.hasDeadline = true
                            d.deadline = refNow
                            let pastIssue = issueTag(d.issue(config: cfg, now: refNow))
                            d.deadline = refNow.addingTimeInterval(60)
                            let okIssue = d.issue(config: cfg, now: refNow) == nil
                            checkResults.append(.object([
                                "kind": .string(kind),
                                "empty": .string(emptyIssue),
                                "dup0": .bool(dup0),
                                "dup_oob": .bool(dupOOB),
                                "dup": .string(dupIssue),
                                "too_few": .string(fewIssue),
                                "past": .string(pastIssue),
                                "valid": .bool(okIssue),
                            ]))
                        case "poll_config_branches":
                            let cfg = PollConfig(json: [
                                "minOptions": 4,
                                "maxOptions": 2,
                                "maxQuestion": 0,
                                "maxOption": -5,
                                "displayOptions": 0,
                                "enableAnonymous": false,
                                "enableHidePreview": false,
                            ])
                            let caps = PollCapabilities(json: [
                                "ready": true,
                                "canCreate": true,
                                "canPin": false,
                                "config": ["minOptions": 3],
                            ])
                            checkResults.append(.object([
                                "kind": .string(kind),
                                "min_options": .int(Int64(cfg.minOptions)),
                                "max_options": .int(Int64(cfg.maxOptions)),
                                "max_question": .int(Int64(cfg.maxQuestion)),
                                "max_option": .int(Int64(cfg.maxOption)),
                                "display_options": .int(Int64(cfg.displayOptions)),
                                "caps_min": .int(Int64(caps.config.minOptions)),
                            ]))
                        case "action_result_messages":
                            let cases: [(String?, PollAction)] = [
                                ("closed", .vote),
                                ("expired", .vote),
                                ("network", .vote),
                                ("duplicate", .vote),
                                ("forbidden", .create),
                                ("forbidden", .pin),
                                ("forbidden", .unpin),
                                ("forbidden", .lock),
                                ("limit", .pin),
                                ("partial", .pin),
                                ("unknown", .vote),
                                (nil, .vote),
                                (nil, .lock),
                                (nil, .share),
                                (nil, .create),
                                (nil, .pin),
                                (nil, .unpin),
                            ]
                            let msgs = cases.map { err, act in
                                CaseJSON.string(PollActionResult(ok: false, error: err).message(for: act))
                            }
                            checkResults.append(.object([
                                "kind": .string(kind),
                                "messages": .array(msgs),
                            ]))
                        default:
                            checkResults.append(.object(["kind": .string(kind)]))
                        }
                    }
                    results["\(stepIndex)"] = .array(checkResults)
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
                try await server.pushWebSocketActions(count: Int(pushCount), timeoutMs: timeoutMs)
            } else if let releaseCount = step["http_release"]?.int64Value {
                let timeoutMs = Int(step["timeout_ms"]?.int64Value ?? 5000)
                try await server.releaseHeldHTTPResponses(count: Int(releaseCount), timeoutMs: timeoutMs)
            } else if let label = step["snapshot"]?.stringValue {
                await engine.settleForRecording()
                await engine.awaitPollTasksForRecording()
                await Task.yield()
                let snap = await PollSnapshot.capture(
                    from: engine,
                    bootstrapLogs: bootstrapLogs,
                    sendLogs: sendLogs,
                    actionLogs: actionLogs,
                    results: results,
                    groupLogs: groupLogs,
                    watchedCheckIds: watchedCheckIds
                )
                snapshots[label] = normalizeRecordedURLs(snap)
            } else {
                throw RecorderError.invalidStep(scenario: scenario.name, detail: "Unknown step: \(step.canonicalString())")
            }
        }

        _ = await engine.bootTask?.value
        _ = await engine.openConversationTask?.value
        _ = await engine.loadOlderTask?.value
        await engine.awaitContactsTasksForRecording()
        await engine.awaitMarkReadTasksForRecording()
        await engine.awaitNotifyTypingTaskForRecording()
        await engine.awaitMessageActionTasksForRecording()
        await engine.awaitPollTasksForRecording()
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
            await PollSnapshot.capture(
                from: engine,
                bootstrapLogs: bootstrapLogs,
                sendLogs: sendLogs,
                actionLogs: actionLogs,
                results: results,
                groupLogs: groupLogs,
                watchedCheckIds: watchedCheckIds
            )
        )
        let requests = server.canonicalRequests().map { normalizeRecordedURLs($0) }

        virtualClock.cancelAll()
        engine.resetPolls()
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
    }

    @MainActor
    private static func seedSQLiteStore(userId: String, dataDir: URL, seed: CaseJSON) async throws {
        let dbURL = dataDir
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(userId, isDirectory: true)
            .appendingPathComponent("history.sqlite3")
        let store = try ZaloSQLiteStore(path: dbURL.path)
        try await store.setPreferenceString(key: ZaloWebKitMigrator.donePrefKey, value: "1")
        if let prefs = seed["prefs"]?.objectValue {
            for (k, v) in prefs {
                if let s = v.stringValue {
                    try await store.setPreferenceString(key: k, value: s)
                }
            }
        }
        if let arr = seed["pinned_ids"]?.arrayValue {
            try await store.setPreferenceStrings(key: "pinnedIds", value: arr.compactMap(\.stringValue))
        }
        if let arr = seed["archived_ids"]?.arrayValue {
            try await store.setPreferenceStrings(key: "archivedIds", value: arr.compactMap(\.stringValue))
        }
        if let arr = seed["unread_marks"]?.arrayValue {
            try await store.setPreferenceStrings(key: "unreadMarks", value: arr.compactMap(\.stringValue))
        }
        if let arr = seed["hidden_ids"]?.arrayValue {
            try await store.setPreferenceStrings(key: "hiddenIds", value: arr.compactMap(\.stringValue))
        }
        if let ranks = seed["activity_ranks"]?.objectValue {
            var dict: [String: Int] = [:]
            for (k, v) in ranks {
                if let n = v.int64Value { dict[k] = Int(n) }
            }
            if !dict.isEmpty, let data = try? JSONSerialization.data(withJSONObject: dict) {
                try await store.setPreferenceData(key: "activityRanks", data: data)
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
            if let gidMap = contacts["gid_to_uid_map"]?.objectValue {
                let raw = gidMap.compactMapValues(\.stringValue)
                if !raw.isEmpty, let data = try? JSONSerialization.data(withJSONObject: raw) {
                    try await store.setPreferenceData(key: "gidToUidMap", data: data)
                }
            } else if let fg = contacts["friend_global_ids"]?.objectValue {
                var inverted: [String: String] = [:]
                for (uid, gidVal) in fg {
                    if let gid = gidVal.stringValue { inverted[gid] = uid }
                }
                if !inverted.isEmpty, let data = try? JSONSerialization.data(withJSONObject: inverted) {
                    try await store.setPreferenceData(key: "gidToUidMap", data: data)
                }
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
            "friend_board": .array([.string("http://fake")]),
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
            "isolated": .bool(true),
            "ws": .array([.string("ws://fake/ws")]),
            "services": .object(fakeServices),
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

private final class PollTransitionRecorder: @unchecked Sendable {
    private let scenarioName: String
    private let captureState: @MainActor () async -> CaseJSON
    private var history: [CaseJSON] = []
    private var lastSerialized: String?
    private var searchFromIndex = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(scenarioName: String, captureState: @escaping @MainActor () async -> CaseJSON) {
        self.scenarioName = scenarioName
        self.captureState = captureState
    }

    @MainActor
    func recordTransition() {
        Task { @MainActor in
            let state = await captureState()
            let canonical = state.canonicalString()
            if canonical == self.lastSerialized {
                return
            }
            self.lastSerialized = canonical
            self.history.append(state)
            let pending = self.waiters
            self.waiters.removeAll()
            for cont in pending.values {
                cont.resume()
            }
        }
    }

    @MainActor
    func cancelWaiters() {
        let pending = waiters
        waiters.removeAll()
        for cont in pending.values {
            cont.resume()
        }
    }

    @MainActor
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
                throw PollRecorderHarness.RecorderError.timeout(
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
