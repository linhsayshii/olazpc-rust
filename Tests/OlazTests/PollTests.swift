import Testing
import Foundation
@testable import Olaz

/// Poll JSON shaped like `snapshot` in poll-adapter.js, the vote / create rules of the official popups, and the engine state.
@Suite(.serialized) struct PollTests {
    private func object(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func detail(multi: Bool = true, voted: Set<String> = [], closed: Bool = false, expired: Int = 0, allowAdd: Bool = true,
                        hide: Bool = false, joined: Bool = false, anonymous: Bool = false) throws -> PollDetail {
        let options = ["1": ("Phở", 2), "2": ("Bún", 1), "3": ("Cơm", 0)].sorted { $0.key < $1.key }.map { id, v in
            #"{"id":"\#(id)","content":"\#(v.0)","votes":\#(v.1),"voted":\#(voted.contains(id))}"#
        }.joined(separator: ",")
        let json = #"{"id":"77","groupId":"g9","question":"Ăn gì?","creator":"5","creatorName":"Lan","created":1700000000000,"expired":\#(expired),"closed":\#(closed),"joined":\#(joined),"multi":\#(multi),"allowAdd":\#(allowAdd),"anonymous":\#(anonymous),"hidePreview":\#(hide),"voters":3,"canClose":true,"options":[\#(options)]}"#
        return try #require(PollDetail(json: try object(json)))
    }

    @Test func pollMessageKindCarriesIds() throws {
        let k = ChatMessage.Kind(json: try object(#"{"type":"poll","question":"Ăn gì?","header":"Lan đã bình chọn","anonymous":false,"pollId":"77","conversationId":"g9"}"#))
        #expect(k == .poll(.init(question: "Ăn gì?", header: "Lan đã bình chọn", anonymous: false, pollId: "77", conversationId: "g9")))
        // The previous shape (no ids) still parses.
        #expect(ChatMessage.Kind(json: try object(#"{"type":"poll","question":"Q"}"#)) == .poll(.init(question: "Q")))
    }

    @Test func detailParsing() throws {
        let d = try detail(voted: ["2"], joined: true)
        #expect(d.id == "77" && d.groupId == "g9" && d.question == "Ăn gì?" && d.creatorName == "Lan")
        #expect(d.options.map(\.content) == ["Phở", "Bún", "Cơm"] && d.options[1].voted && !d.options[0].voted)
        #expect(d.totalVotes == 3 && d.voterCount == 3 && d.canClose && d.multi && d.created != nil && d.expires == nil)
        #expect(abs(d.weight(of: d.options[0]) - 2.0 / 3.0) < 0.0001)
        #expect(d.votersVisible && !d.resultsHidden)
        // Missing / mistyped fields degrade, a missing id is rejected.
        #expect(PollDetail(json: ["question": "x"]) == nil)
        let sparse = try #require(PollDetail(json: ["id": "1", "options": [["id": 4, "content": 5], ["id": "5", "votes": -3]]]))
        #expect(sparse.options.map(\.id) == ["5"] && sparse.options[0].votes == 0 && !sparse.multi, "missing allow_multi_choices means single choice")
        #expect(sparse.weight(of: sparse.options[0]) == 0)
    }

    @Test func lockedAndHiddenStates() throws {
        #expect(try detail(closed: true).isVotingLocked())
        let past = Int(Date.now.addingTimeInterval(-60).timeIntervalSince1970 * 1000)
        #expect(try detail(expired: past).isExpired() && detail(expired: past).isVotingLocked())
        let future = Int(Date.now.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        #expect(try !detail(expired: future).isVotingLocked())
        // Results hidden until I vote; after voting the choice is final.
        let hiddenNotJoined = try detail(hide: true)
        #expect(hiddenNotJoined.resultsHidden && !hiddenNotJoined.isVotingLocked() && !hiddenNotJoined.votersVisible)
        #expect(try detail(hide: true, joined: true).isVotingLocked())
        #expect(try !detail(anonymous: true).votersVisible)
    }

    @Test func multiChoiceDraft() throws {
        let d = try detail(voted: ["1"])
        var draft = PollVoteDraft(d)
        #expect(!draft.hasChanges && draft.votesNothing == false)
        draft.toggle("2")
        #expect(draft.hasChanges && draft.request(for: d).votedIds == ["1", "2"])
        draft.toggle("2")
        #expect(!draft.hasChanges && draft.request(for: d).votedIds == ["1"])   // back to the original
        draft.toggle("1")
        #expect(draft.hasChanges && draft.votesNothing && draft.request(for: d).votedIds.isEmpty)   // unvote everything
        let preview = draft.applied(to: d)
        #expect(preview.options[0].votes == 1 && !preview.options[0].voted)
    }

    @Test func singleChoiceDraftReplacesTheTick() throws {
        let d = try detail(multi: false, voted: ["1"])
        var draft = PollVoteDraft(d)
        draft.toggle("3")
        #expect(draft.request(for: d).votedIds == ["3"])
        let preview = draft.applied(to: d)
        #expect(preview.options.map(\.votes) == [1, 1, 1] && preview.options.map(\.voted) == [false, false, true])
        // A ticked new option clears the ticks; ticking an existing one clears the new option's tick.
        draft.addRow()
        let row = try #require(draft.added.first?.id)
        draft.added[0].text = "  Bánh mì "
        draft.setAddedVoted(row, true)
        #expect(draft.request(for: d).votedIds.isEmpty)
        #expect(draft.request(for: d).newOptions.count == 1)
        #expect(draft.request(for: d).newOptions.first?["content"] as? String == "Bánh mì" && draft.request(for: d).newOptions.first?["voted"] as? Bool == true)
        draft.toggle("2")
        #expect(draft.added[0].voted == false && draft.request(for: d).votedIds == ["2"])
    }

    @Test func addedOptionsAreTrimmedAndDeduplicated() throws {
        let d = try detail()
        var draft = PollVoteDraft(d)
        draft.addRow(); draft.addRow()
        #expect(!draft.hasChanges, "empty rows are not a change")
        draft.added[0].text = " Phở "
        #expect(draft.hasChanges && draft.hasDuplicates(in: d) && draft.isDuplicate(draft.added[0].id, in: d))
        draft.added[0].text = "Chè"
        draft.added[1].text = "chè"
        #expect(!draft.hasDuplicates(in: d), "case differs: the official check is exact after trimming")
        draft.added[1].text = "Chè "
        #expect(draft.hasDuplicates(in: d))
        draft.removeAdded(draft.added[1].id)
        #expect(!draft.hasDuplicates(in: d) && draft.request(for: d).newOptions.count == 1)
    }

    @Test func createDraftRules() {
        let config = PollConfig()
        var draft = PollCreateDraft(config: config)
        #expect(draft.options.count == 2 && draft.issue(config: config) == .emptyQuestion)
        draft.question = "  Ăn gì?  "
        #expect(draft.issue(config: config) == .tooFewOptions(2))
        draft.options = ["Phở", " phở", ""]
        #expect(draft.issue(config: config) == nil, "duplicates compare exactly")
        draft.options = ["Phở", " Phở ", "Bún"]
        #expect(draft.issue(config: config) == .duplicate && draft.isDuplicate(at: 1) && !draft.isDuplicate(at: 2))
        draft.options = ["Phở", "", "Bún"]
        #expect(draft.issue(config: config) == nil)
        draft.hasDeadline = true
        draft.deadline = Date.now.addingTimeInterval(-5)
        #expect(draft.issue(config: config) == .pastDeadline)
        draft.deadline = Date.now.addingTimeInterval(600)
        #expect(draft.issue(config: config) == nil)
    }

    @Test func createSpecFollowsOfficialDefaultsAndLimits() {
        var config = PollConfig()
        var draft = PollCreateDraft(config: config)
        draft.question = "Q"
        draft.options = ["A", "B"]
        var spec = draft.spec(config: config, canPin: true)
        #expect(spec["multi"] as? Bool == true && spec["allowAdd"] as? Bool == true && spec["expired"] as? Int == 0)
        #expect(spec["hidePreview"] as? Bool == false && spec["anonymous"] as? Bool == false && spec["pin"] as? Bool == false)
        // "Add option" is sent false while results are hidden; pin needs the permission; switches off in config win.
        draft.hidePreview = true; draft.anonymous = true; draft.pin = true
        spec = draft.spec(config: config, canPin: false)
        #expect(spec["allowAdd"] as? Bool == false && spec["hidePreview"] as? Bool == true && spec["pin"] as? Bool == false)
        config.enableAnonymous = false; config.enableHidePreview = false
        spec = draft.spec(config: config, canPin: true)
        #expect(spec["anonymous"] as? Bool == false && spec["hidePreview"] as? Bool == false && spec["pin"] as? Bool == true)
        // Deadline in ms, text clipped to the configured limits.
        draft.hasDeadline = true
        draft.deadline = Date(timeIntervalSince1970: 1_900_000_000)
        draft.question = String(repeating: "x", count: 300)
        spec = draft.spec(config: config, canPin: true)
        #expect(spec["expired"] as? Int == 1_900_000_000_000 && (spec["question"] as? String)?.count == 200)
    }

    @Test func configAndCapabilitiesParsing() throws {
        let caps = PollCapabilities(json: try object(#"{"ready":true,"canCreate":true,"canPin":false,"config":{"minOptions":3,"maxOptions":10,"maxQuestion":100,"maxOption":50,"enableAnonymous":false,"enableHidePreview":true,"displayOptions":4}}"#))
        #expect(caps.ready && caps.canCreate && !caps.canPin)
        #expect(caps.config == { var c = PollConfig(); c.minOptions = 3; c.maxOptions = 10; c.maxQuestion = 100; c.maxOption = 50; c.enableAnonymous = false; c.displayOptions = 4; return c }())
        #expect(PollCapabilities(json: nil) == PollCapabilities())
        #expect(PollCapabilities(json: "x") == PollCapabilities())
        #expect(PollConfig(json: ["minOptions": 0, "maxOptions": -1]) == PollConfig())
    }

    @Test func votersParsing() throws {
        let voters = try #require(PollVoters(json: try object(#"{"restricted":false,"groups":[{"optionId":"1","content":"Phở","votes":2,"users":[{"uid":"5","name":"Lan","avatar":"https://a/b.jpg","isMe":false},{"uid":"","name":"x"},{"uid":"6","name":"Bạn","avatar":"","isMe":true}]},{"content":"no id"}]}"#)))
        #expect(!voters.restricted && voters.groups.count == 1)
        #expect(voters.groups[0].users.map(\.uid) == ["5", "6"] && voters.groups[0].users[0].avatar == URL(string: "https://a/b.jpg") && voters.groups[0].users[1].avatar == nil)
        #expect(voters.groups[0].users[1].isMe && voters.groups[0].votes == 2)
        #expect(PollVoters(json: nil) == nil && PollVoters(json: 3) == nil)
        #expect(try #require(PollVoters(json: try object(#"{"restricted":true,"groups":[]}"#))).restricted)
    }

    @Test func actionMessages() {
        #expect(PollActionResult(ok: false, error: "closed").message(for: .vote) == "Có lỗi xảy ra do bình chọn đã bị khoá")
        #expect(PollActionResult(ok: false, error: "forbidden").message(for: .create) == "Bạn không đủ quyền tạo bình chọn")
        #expect(PollActionResult(ok: false, error: "forbidden").message(for: .lock) == "Bạn không có quyền khóa bình chọn này")
        #expect(PollActionResult(ok: false, error: "failed").message(for: .lock).contains("khóa bình chọn"))
        #expect(PollActionResult(ok: false, error: nil).message(for: .vote).contains("bình chọn"))
    }

    @Test func friendBoardDefaultHostAndHeal() {
        var domains = ZaloDomains()
        #expect(!ZaloDomains.defaultServiceMapV3.keys.contains("friend_board"))
        #expect(domains.candidates(for: "friend_board") == ["https://friendboard-wpa.chat.zalo.me"])
        domains.rememberWinner(for: "friend_board", host: "https://friendboard-wpa.chat.zalo.me")
        domains.rememberWinner(for: "chat", host: "https://tt-chat3-wpa.chat.zalo.me")
        domains.healFromVerified()
        #expect(domains.preferredHosts["friend_board"] == "https://friendboard-wpa.chat.zalo.me")
        #expect(domains.preferredHosts["chat"] == nil)

        let isolated = ZaloDomains(isolated: true)
        #expect(isolated.candidates(for: "friend_board").isEmpty)
    }

    @MainActor @Test func engineKeepsLatestSnapshotAndFailures() throws {
        let engine = ZaloEngine()
        engine.handlePoll(state: ["page": "main", "poll": ["id": "77", "error": "fetch"]])
        #expect(engine.polls.failed == ["77"] && engine.polls.details.isEmpty)
        let snapshot = try object(#"{"id":"77","groupId":"g9","question":"Q","creator":"5","creatorName":"Lan","created":0,"expired":0,"closed":false,"joined":false,"multi":true,"allowAdd":true,"anonymous":false,"hidePreview":false,"voters":0,"canClose":false,"options":[{"id":"1","content":"A","votes":0,"voted":false}]}"#)
        engine.handlePoll(state: ["page": "main", "poll": ["id": "77", "detail": snapshot]])
        #expect(engine.polls.failed.isEmpty && engine.polls.details["77"]?.options.count == 1)
        // A later failed refresh does not throw away what is shown.
        engine.handlePoll(state: ["page": "main", "poll": ["id": "77", "error": "fetch"]])
        #expect(engine.polls.details["77"] != nil && engine.polls.failed.isEmpty)
        engine.resetPolls()
        #expect(engine.polls == PollStore())
    }

    @MainActor @Test func numericFlagsBridgeLikeSwiftAsBool() throws {
        let engine = ZaloEngine()
        let numericOn = engine.normalizePollDetail(
            [
                "group_id": "500101",
                "question": "Ăn trưa?",
                "creator": "2001001",
                "status": 1,
                "expired_time": 0,
                "is_multi_choice": 1,
                "is_add_new_option": 1,
                "is_anonymous": 1,
                "is_hide_vote_preview": 1,
                "options": [["option_id": 1, "content": "Phở", "voters": []]],
            ],
            id: "9401"
        )
        let detailOn = try #require(PollDetail(json: numericOn))
        #expect(detailOn.multi)
        #expect(detailOn.allowAdd)
        #expect(detailOn.anonymous)
        #expect(detailOn.hidePreview)

        let numericOff = engine.normalizePollDetail(
            [
                "group_id": "500101",
                "question": "Ăn tối?",
                "creator": "2001001",
                "status": 1,
                "expired_time": 0,
                "is_multi_choice": 0,
                "is_add_new_option": 0,
                "is_anonymous": 0,
                "is_hide_vote_preview": 0,
                "options": [["option_id": 1, "content": "Bún", "voters": []]],
            ],
            id: "9402"
        )
        let detailOff = try #require(PollDetail(json: numericOff))
        #expect(!detailOff.multi)
        #expect(!detailOff.allowAdd)
        #expect(!detailOff.anonymous)
        #expect(!detailOff.hidePreview)

        // Numbers outside 0/1 and strings must evaluate to false, matching Swift `as? Bool`.
        let nonBridging = engine.normalizePollDetail(
            [
                "group_id": "500101",
                "question": "Kiểm tra?",
                "creator": "2001001",
                "status": 1,
                "expired_time": 0,
                "is_multi_choice": 2,
                "is_add_new_option": "1",
                "is_anonymous": "true",
                "is_hide_vote_preview": -1,
                "options": [["option_id": 1, "content": "Cơm", "voters": []]],
            ],
            id: "9403"
        )
        let detailNb = try #require(PollDetail(json: nonBridging))
        #expect(!detailNb.multi)
        #expect(!detailNb.allowAdd)
        #expect(!detailNb.anonymous)
        #expect(!detailNb.hidePreview)
    }

    @MainActor @Test func watchPollsWithLargeGidMapBoundsIdentityUpdatesAndMirrorsCachedGroups() async throws {
        let myUid = "2000888"
        let groupId = "500888"
        let convId = "g500888"
        let testEnk = Data("0123456789abcdef0123456789abcdef".utf8).base64EncodedString()
        let secretKey = ZaloCrypto.parseSecretKey(testEnk)

        let serverScript: [CaseJSON] = [
            .object([
                "kind": .string("http"),
                "path": .string("/api/login/getLoginInfo"),
                "response": .object([
                    "status": .int(200),
                    "json": .object([
                        "error_code": .int(0),
                        "data": .object([
                            "uid": .string(myUid),
                            "zpw_enk": .string(testEnk),
                            "zpw_sek": .string("sek.poll.storm"),
                            "display_name": .string("Storm Tester"),
                            "send2me_id": .string("9200888"),
                            "zpw_ws": .array([.string("ws://fake")]),
                            "zpw_service_map_v3": .object([
                                "chat": .array([.string("http://fake")]),
                                "group": .array([.string("http://fake")]),
                                "group_poll": .array([.string("http://fake")]),
                                "profile": .array([.string("http://fake")]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/social/profile/me-v2"),
                "response": .object([
                    "status": .int(200),
                    "json": .object([
                        "error_code": .int(0),
                        "data": .object([
                            "userId": .string(myUid),
                            "displayName": .string("Storm Tester"),
                        ]),
                    ]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/poll/detail"),
                "method": .string("GET"),
                "repeat": .bool(true),
                "response": .object([
                    "status": .int(200),
                    "json": .object([
                        "error_code": .int(0),
                        "data": .object([
                            "group_id": .string(groupId),
                            "question": .string("Ăn gì?"),
                            "creator": .string(myUid),
                            "status": .int(1),
                            "expired_time": .int(0),
                            "is_multi_choice": .int(1),
                            "is_add_new_option": .int(1),
                            "is_anonymous": .int(0),
                            "is_hide_vote_preview": .int(0),
                            "options": .array([
                                .object([
                                    "option_id": .int(1),
                                    "content": .string("Phở"),
                                    "voters": .array([.string(myUid)]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/group/getmg-v2"),
                "method": .string("POST"),
                "repeat": .bool(true),
                "response": .object([
                    "status": .int(200),
                    "json": .object([
                        "error_code": .int(0),
                        "data": .object([
                            "gridInfoMap": .object([
                                groupId: .object([
                                    "groupId": .string(groupId),
                                    "name": .string("Nhóm Poll Stress"),
                                    "creatorId": .string(myUid),
                                    "totalMember": .int(5),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ]

        let server = try FakeZaloServer(serverScript: serverScript, initialSecretKey: secretKey)
        try await server.start()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-poll-storm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let dbURL = root
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(myUid, isDirectory: true)
            .appendingPathComponent("history.sqlite3")
        let seedStore = try ZaloSQLiteStore(path: dbURL.path)
        try await seedStore.setPreferenceString(key: ZaloWebKitMigrator.donePrefKey, value: "1")

        // Seed 2,000 gid -> uid mappings in SQLite to reproduce the production identity table size.
        var gidToUid: [String: String] = [:]
        gidToUid.reserveCapacity(2_000)
        for i in 0..<2_000 {
            gidToUid["gid_\(i)"] = "uid_\(i)"
        }
        let gidData = try JSONSerialization.data(withJSONObject: gidToUid)
        try await seedStore.setPreferenceData(key: "gidToUidMap", data: gidData)
        await seedStore.close()

        var isolatedDomains = ZaloDomains()
        isolatedDomains.auth = server.baseURLString
        isolatedDomains.wpaChat = server.baseURLString
        isolatedDomains.lpChat = server.baseURLString
        isolatedDomains.lpControl = server.baseURLString
        isolatedDomains.ws = [server.wsBaseURLString]
        isolatedDomains.serviceCandidates = [
            "chat": [server.baseURLString],
            "group": [server.baseURLString],
            "group_poll": [server.baseURLString],
            "profile": [server.baseURLString],
        ]
        isolatedDomains.isolated = true

        let savedSession: CaseJSON = .object([
            "zpwType": .string(ZaloDomains.zpwType),
            "imei": .string("00000000-0000-4000-8000-000000000000-00000000000000000000000000000000"),
            "computerName": .string("PollStormMac"),
            "domains": .object([
                "auth": .string(server.baseURLString),
                "wpaChat": .string(server.baseURLString),
                "lpChat": .string(server.baseURLString),
                "lpControl": .string(server.baseURLString),
                "ws": .array([.string(server.wsBaseURLString)]),
                "serviceCandidates": .object([
                    "chat": .array([.string(server.baseURLString)]),
                    "group": .array([.string(server.baseURLString)]),
                    "group_poll": .array([.string(server.baseURLString)]),
                    "profile": .array([.string(server.baseURLString)]),
                ]),
                "preferredHosts": .object([:]),
                "isolated": .bool(true),
            ]),
            "sealedSecretsBase64": .null,
            "expiredAt": .null,
            "plainAccount": .object([
                "userId": .string(myUid),
                "displayName": .string("Storm Tester"),
                "avatar": .string(""),
                "phone": .string(""),
                "send2MeId": .string("9200888"),
                "dkey": .string("dk-poll-storm"),
                "zpwEnk": .string(testEnk),
                "zpwSek": .string("sek.poll.storm"),
            ]),
        ])
        try Data(savedSession.canonicalString().utf8)
            .write(to: root.appendingPathComponent("native-session.json"), options: .atomic)

        let storage = RecorderStorageIsolation(prefix: "olaz.poll-storm")
        let engine = ZaloEngine(
            dataDirectory: root,
            useKeychain: false,
            domains: isolatedDomains,
            userDefaultsSuiteName: storage.userDefaultsSuiteName,
            cookieStorage: storage.cookieStorage
        )
        engine.resetPolls()

        defer {
            engine.onCoreUpdateIdentities = nil
            engine.resetPolls()
            engine.cancelTasksForRecording()
            server.stop()
            storage.cleanup()
            try? FileManager.default.removeItem(at: root)
        }

        var updateIdentitiesCount = 0
        engine.onCoreUpdateIdentities = {
            updateIdentitiesCount += 1
        }
        engine.hostTrace = { name, _ in
            name == "prepare_store"
        }

        engine.start()
        _ = await engine.bootTask?.value
        #expect(engine.phase == .ready)
        #expect(engine.cachedFriendGlobalIds.count == 2_000)
        // Boot + prepareStore must NOT fire didSet per gid entry (<= 2 total pushes).
        #expect(updateIdentitiesCount <= 2)

        let callsBeforePolls = updateIdentitiesCount
        let start = ContinuousClock.now
        for i in 1...20 {
            engine.watchPoll("poll_\(i)", in: convId)
        }
        while !engine.pollRefreshTasks.isEmpty {
            for task in Array(engine.pollRefreshTasks.values) {
                await task.value
            }
        }
        let elapsed = ContinuousClock.now - start

        #expect(engine.polls.details.count == 20)
        #expect(engine.polls.details["poll_1"]?.allowAdd == true)
        #expect(engine.polls.details["poll_1"]?.multi == true)
        #expect(engine.polls.details["poll_1"]?.anonymous == false)
        #expect(engine.polls.details["poll_1"]?.hidePreview == false)
        #expect(engine.cachedGroups[convId]?.name == "Nhóm Poll Stress")
        #expect(engine.cachedGroups[convId]?.members == 5)
        // Zero identity pushes during all 20 watched poll refreshes + group metadata merge.
        #expect(updateIdentitiesCount - callsBeforePolls == 0)
        #expect(elapsed < .seconds(5))

        // Direct store preference sync with 2,000 gid->uid entries must also emit 0 identity pushes.
        let callsBeforeSync = updateIdentitiesCount
        await engine.syncCachedIdentityPreferencesFromStore()
        #expect(updateIdentitiesCount == callsBeforeSync)

        await engine.finishTearDownForRecording()
    }
}
