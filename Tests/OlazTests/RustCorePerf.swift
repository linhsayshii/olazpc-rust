import Foundation
import OlazCore
import Testing

@testable import Olaz

/// Benchmarks for the Rust chat hot paths. Informational (prints a table, asserts row counts): run in release for real numbers,
///   `swift test -c release --filter RustCorePerf`
@Suite(.serialized) struct RustCorePerf {
    private static func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("olaz-perf-\(UUID().uuidString)")
    }

    private static let lookup: @Sendable (String) -> (name: String, avatar: String)? = { uid in
        uid == "u1" ? (name: "An", avatar: "https://ava.example/an.jpg") : nil
    }

    private static func wireMessage(_ i: Int) -> [String: Any] {
        [
            "msgId": "\(9_000_000_000_000_000 + i)", "cliMsgId": "\(1_000_000 + i)", "uidFrom": i % 2 == 0 ? "u1" : "me",
            "idTo": i % 2 == 0 ? "me" : "u1", "msgType": "webchat", "content": "Tin nhắn số \(i) xin chào", "ts": 1_795_000_000_000 + i * 1000
        ]
    }

    /// Median wall time (ms) of `body` over `runs` runs after one warm-up.
    private static func median(_ runs: Int = 7, _ body: () -> Void) -> Double {
        if let loops = ProcessInfo.processInfo.environment["OLAZ_PERF_LOOPS"].flatMap(Int.init) {   // profiling aid
            for _ in 0..<loops { body() }
        }
        body()
        var samples: [Double] = []
        for _ in 0..<runs {
            let t = ContinuousClock.now
            body()
            let d = ContinuousClock.now - t
            samples.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
        }
        return samples.sorted()[samples.count / 2]
    }

    private static func medianAsync(_ runs: Int = 5, setup: () async throws -> Void = {}, _ body: () async throws -> Void) async rethrows -> Double {
        try await setup()
        try await body()
        var samples: [Double] = []
        for _ in 0..<runs {
            try await setup()
            let t = ContinuousClock.now
            try await body()
            let d = ContinuousClock.now - t
            samples.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
        }
        return samples.sorted()[samples.count / 2]
    }

    private static func row(_ label: String, ms: Double, note: String = "") -> String {
        String(format: "PERF %-62@ %8.2f ms%@", label as NSString, ms, (note.isEmpty ? "" : "  (\(note))") as NSString)
    }

    /// What the Rust path did before typed records: the core's events, then `ChatMessage` rebuilt by re-parsing each stored
    /// raw JSON in Swift (`decodeStoredMessage`).
    private static func legacyMessages(_ events: [WireEvent]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        for case .message(let m, let s) in events {
            let stored = StoredMessage(
                id: m.id, convId: m.conversationId, clientId: m.clientId, senderId: m.senderId, senderName: m.senderName,
                senderAvatar: s.senderAvatar, isMine: m.isMine, text: m.text, kindTag: s.kindTag, tsMs: m.dateMs,
                status: "sent", rawJSONData: s.rawJson)
            if let chat = ZaloWireParser.decodeStoredMessage(stored) { out.append(chat) }
        }
        return out
    }

    // MARK: (a) 2,000 realtime message events, decrypted ws payload -> Swift ChatMessage values

    @Test func realtimeEvents2000() throws {
        let payloads: [Data] = try (0..<2000).map { try JSONSerialization.data(withJSONObject: ["data": ["msgs": [Self.wireMessage($0)]]]) }
        var rustCount = 0
        let probe = WireParseProbe(myUid: "me", selfConvId: nil)
        let rust = Self.median {
            var n = 0
            for data in payloads {
                guard let env = probe.parse(payload: data, cmd: 501) else { continue }
                var events = ZaloWireParser.parsedEvents(from: env.events)
                var names: [NameEntry] = []
                for uid in env.uids { if let hit = Self.lookup(uid) { names.append(NameEntry(uid: uid, name: hit.name, avatar: hit.avatar)) } }
                if let fresh = env.payload.resolve(myUid: "me", selfConvId: nil, names: names) {
                    events = ZaloWireParser.parsedEvents(from: fresh)
                }
                if case .message = events.first ?? .ignore { n += 1 }
            }
            rustCount = n
        }
        var legacyCount = 0
        let legacy = Self.median {
            var n = 0
            for data in payloads {
                guard let dict = JSONLossless.parseObject(data),
                      let input = ZaloWireParser.rustBatchInput(dict, myUid: "me", selfConvId: nil, defaultCmd: 501, fallbackConvId: nil, isGroupHint: nil, nameLookup: Self.lookup),
                      let events = try? parseWireBatch(json: input.json, myUid: input.myUid, options: input.options) else { continue }
                n += Self.legacyMessages(events).count
            }
            legacyCount = n
        }
        print(Self.row("(a) 2000 realtime events -> ChatMessage (1 msg each)", ms: rust))
        print(Self.row("(a) .. Rust route before 4a (JSON re-parse in Swift)", ms: legacy))
        #expect(rustCount == 2000 && legacyCount == 2000)
    }

    // MARK: (b) history batch of 2,000

    @Test func historyBatch2000() throws {
        let root: [String: Any] = ["data": ["msgs": (0..<2000).map { Self.wireMessage($0) }]]
        let data = try JSONSerialization.data(withJSONObject: root)
        var rustEvents: [ParsedWireEvent] = []
        let names = [NameEntry(uid: "u1", name: "An", avatar: "https://ava.example/an.jpg")]
        let rust = Self.median {
            guard let events = try? parseWireBatchBytes(json: data, myUid: "me", options: WireOptions(cmd: 0, names: names)) else { return }
            rustEvents = ZaloWireParser.parsedEvents(from: events)
        }
        let viaDict = Self.median {
            guard let dict = JSONLossless.parseObject(data),
                  let input = ZaloWireParser.rustBatchInput(dict, myUid: "me", selfConvId: nil, defaultCmd: 0, fallbackConvId: nil, isGroupHint: nil, nameLookup: Self.lookup) else { return }
            _ = ZaloWireParser.rustParseBatch(input)
        }
        var legacyCount = 0
        let legacy = Self.median {
            guard let dict = JSONLossless.parseObject(data),
                  let input = ZaloWireParser.rustBatchInput(dict, myUid: "me", selfConvId: nil, defaultCmd: 0, fallbackConvId: nil, isGroupHint: nil, nameLookup: Self.lookup),
                  let events = try? parseWireBatch(json: input.json, myUid: input.myUid, options: input.options) else { return }
            legacyCount = Self.legacyMessages(events).count
        }
        let jsonText = String(decoding: data, as: UTF8.self)
        var typedCount = 0
        let typedPage = Self.median {
            guard let record = try? historyRecordFromJson(json: jsonText) else { return }
            var resolved: [NameEntry] = []
            for uid in record.uids { if let hit = Self.lookup(uid) { resolved.append(NameEntry(uid: uid, name: hit.name, avatar: hit.avatar)) } }
            typedCount = ZaloWireParser.parsedEvents(from: record.batch.events(myUid: "me", options: WireOptions(cmd: 0, names: resolved))).count
        }
        print(Self.row("(b'') history page 2000: typed HistoryBatch (wave 5a)", ms: typedPage))
        print(Self.row("(b) history batch 2000: bytes -> ChatMessage", ms: rust))
        print(Self.row("(b) .. Rust route before 4a (dict -> JSON -> core -> JSON decode)", ms: legacy))
        print(Self.row("(b') history batch 2000: dict -> JSON -> core", ms: viaDict))
        #expect(typedCount == 2000 && legacyCount == 2000 && rustEvents.count == 2000)
    }

    // MARK: (c) save 2,000 + load 50 per conversation

    @Test func saveAndLoad2000() async throws {
        let convs = 40
        var msgs: [[String: Any]] = []
        for c in 0..<convs {
            for j in 0..<50 {
                let i = c * 50 + j
                msgs.append(["msgId": "\(9_000_000_000_000_000 + i)", "cliMsgId": "\(1_000_000 + i)", "uidFrom": "peer\(c)", "idTo": "me", "msgType": "webchat",
                             "content": "Tin nhắn số \(i) xin chào", "ts": 1_795_000_000_000 + i * 1000])
            }
        }
        let events = ZaloWireParser.extractBatchEvents(["data": ["msgs": msgs]], myUid: "me")
        let stored: [StoredMessage] = events.compactMap { if case .message(_, let s) = $0 { s } else { nil } }
        let chats: [ChatMessage] = events.compactMap { if case .message(let m, _) = $0 { m } else { nil } }
        #expect(stored.count == 2000 && chats.count == 2000)
        let convIds = (0..<convs).map { "peer\($0)" }

        func fresh() throws -> (ZaloSQLiteStore, URL) {
            let dir = Self.tempDir()
            return (try ZaloSQLiteStore(path: dir.appendingPathComponent("p.db").path), dir)
        }
        var dirs: [URL] = []
        defer { for d in dirs { try? FileManager.default.removeItem(at: d) } }

        var store: ZaloSQLiteStore! = nil

        func saveTime(typed: Bool) async throws -> Double {
            try await Self.medianAsync(setup: {
                let (s, d) = try fresh(); dirs.append(d); store = s
            }, {
                if typed { try await store.saveChatMessages(chats) } else { try await store.saveMessages(stored) }
            })
        }
        let rustSave = try await saveTime(typed: false)
        let rustTypedSave = try await saveTime(typed: true)
        print(Self.row("(c) save 2000 rows (StoredMessage -> store)", ms: rustSave))
        print(Self.row("(c) save 2000 typed (ChatMessage -> store, Rust encodes)", ms: rustTypedSave))

        // Load: 50 newest per conversation, decoded to ChatMessage.
        let (rustStore, d2) = try fresh(); dirs.append(d2)
        try await rustStore.saveMessages(stored)
        var rustLoaded = 0, rustSyncLoaded = 0, legacyLoaded = 0
        let legacyLoad = try await Self.medianAsync {
            var n = 0
            for c in convIds { n += try await rustStore.messages(convId: c, limit: 50).compactMap { ZaloWireParser.decodeStoredMessage($0) }.count }
            legacyLoaded = n
        }
        let rustLoad = try await Self.medianAsync {
            var n = 0
            for c in convIds { n += try await rustStore.decodedMessages(convId: c, limit: 50).count }
            rustLoaded = n
        }
        let rustSync = Self.median { var n = 0; for c in convIds { n += rustStore.readDecodedMessagesNow(convId: c, limit: 50)?.count ?? 0 }; rustSyncLoaded = n }
        print(Self.row("(c) load 50 x 40 conversations -> ChatMessage (async)", ms: rustLoad))
        print(Self.row("(c) load 50 x 40 conversations -> ChatMessage (sync first-frame)", ms: rustSync))
        print(Self.row("(c) .. Rust route before 4a (rows + JSON decode in Swift)", ms: legacyLoad))
        #expect(legacyLoaded == 2000 && rustLoaded == 2000 && rustSyncLoaded == 2000)
    }

    // MARK: (d) conversation list, 700 rows

    @Test func conversationList700() async throws {
        let items = (0..<700).map { i in
            StoredConversation(id: "conv\(i)", isGroup: i % 3 == 0, name: "Hội thoại \(i)", avatar: "https://cdn.example/\(i).jpg", pinned: i % 50 == 0, members: i,
                               unread: i % 5, previewText: "Tin cuối cùng của \(i)", previewTsMs: 1_795_000_000_000 + Int64(i), previewFromMe: i % 2 == 0, updatedAtMs: 1_795_000_000_000 + Int64(i))
        }
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rustStore = try ZaloSQLiteStore(path: dir.appendingPathComponent("p.db").path)
        try await rustStore.saveConversations(items)
        var b = 0
        let rust = try await Self.medianAsync { b = try await rustStore.loadConversations().count }
        print(Self.row("(d) load 700 conversations", ms: rust))
        #expect(b == 700)
    }

    // MARK: (e) poll detail render path: 10 options, 200 voters, 1,000 iterations

    private struct OriginMainPollDetail {
        struct Option {
            var id: String
            var content: String
            var votes: Int
            var voted: Bool
        }
        var id: String
        var groupId: String
        var question: String
        var creator: String
        var creatorName: String
        var created: Date?
        var expires: Date?
        var closed: Bool
        var joined: Bool
        var multi: Bool
        var allowAdd: Bool
        var anonymous: Bool
        var hidePreview: Bool
        var voterCount: Int
        var canClose: Bool
        var options: [Option]

        var totalVotes: Int { options.reduce(0) { $0 + $1.votes } }
        func isExpired(at now: Date) -> Bool { expires.map { $0 < now } ?? false }
        func isVotingLocked(at now: Date) -> Bool { closed || isExpired(at: now) || (hidePreview && joined) }
        var resultsHidden: Bool { hidePreview && !joined }
        var votersVisible: Bool { !anonymous && !resultsHidden && totalVotes > 0 }
        func weight(of option: Option) -> Double { totalVotes > 0 ? Double(option.votes) / Double(totalVotes) : 0 }
    }

    @Test func pollRender10Options200Voters() throws {
        let rawOptions: [[String: Any]] = (0..<10).map { i in
            [
                "id": "opt_\(i + 1)",
                "content": "Phương án lựa chọn số \(i + 1) cho cuộc họp nhóm tuần này",
                "votes": 16 + i,
                "voted": i < 2
            ]
        }
        let rawJson: [String: Any] = [
            "id": "poll_9001",
            "groupId": "g_8800112233",
            "question": "Tuần này nhóm mình họp offline ở địa điểm nào thuận tiện nhất?",
            "creator": "1000000001",
            "creatorName": "Nguyễn Thị Lan",
            "created": 1_700_000_000_000,
            "expired": 1_900_000_000_000,
            "closed": false,
            "joined": true,
            "multi": true,
            "allowAdd": true,
            "anonymous": false,
            "hidePreview": false,
            "voters": 200,
            "canClose": true,
            "options": rawOptions
        ]
        let detail = try #require(PollDetail(json: rawJson))
        let baseline = OriginMainPollDetail(
            id: detail.id, groupId: detail.groupId, question: detail.question,
            creator: detail.creator, creatorName: detail.creatorName,
            created: detail.created, expires: detail.expires,
            closed: detail.closed, joined: detail.joined, multi: detail.multi,
            allowAdd: detail.allowAdd, anonymous: detail.anonymous, hidePreview: detail.hidePreview,
            voterCount: detail.voterCount, canClose: detail.canClose,
            options: detail.options.map { .init(id: $0.id, content: $0.content, votes: $0.votes, voted: $0.voted) }
        )
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        var draft = PollVoteDraft(detail)
        draft.toggle("opt_3")

        let iterations = 1_000
        var coreAcc = 0.0
        var coreFlags = 0
        let coreDetailMs = Self.median {
            var acc = 0.0
            var flags = 0
            for _ in 0..<iterations {
                for opt in detail.options {
                    acc += detail.weight(of: opt)
                }
                acc += Double(detail.totalVotes)
                if detail.isVotingLocked(at: fixedNow) { flags &+= 1 }
                if detail.resultsHidden { flags &+= 2 }
                if detail.votersVisible { flags &+= 4 }
            }
            coreAcc = acc
            coreFlags = flags
        }

        var perGetterAcc = 0.0
        var perGetterFlags = 0
        let perGetterFfiMs = Self.median {
            var acc = 0.0
            var flags = 0
            for _ in 0..<iterations {
                for opt in detail.options {
                    acc += pollDetailOptionWeight(detail: detail.coreRecord, option: opt.coreRecord)
                }
                acc += Double(pollDetailTotalVotes(detail: detail.coreRecord))
                let nowMs = Int64((fixedNow.timeIntervalSince1970 * 1000.0).rounded())
                if pollDetailIsVotingLocked(detail: detail.coreRecord, nowMs: nowMs) { flags &+= 1 }
                if pollDetailResultsHidden(detail: detail.coreRecord) { flags &+= 2 }
                if pollDetailVotersVisible(detail: detail.coreRecord) { flags &+= 4 }
            }
            perGetterAcc = acc
            perGetterFlags = flags
        }

        var baseAcc = 0.0
        var baseFlags = 0
        let baseDetailMs = Self.median {
            var acc = 0.0
            var flags = 0
            for _ in 0..<iterations {
                for opt in baseline.options {
                    acc += baseline.weight(of: opt)
                }
                acc += Double(baseline.totalVotes)
                if baseline.isVotingLocked(at: fixedNow) { flags &+= 1 }
                if baseline.resultsHidden { flags &+= 2 }
                if baseline.votersVisible { flags &+= 4 }
            }
            baseAcc = acc
            baseFlags = flags
        }

        var sheetAcc = 0.0
        let coreVoteSheetMs = Self.median {
            var acc = 0.0
            for _ in 0..<iterations {
                let preview = draft.applied(to: detail)
                for opt in detail.options {
                    let shown = preview.options.first { $0.id == opt.id } ?? opt
                    acc += preview.weight(of: shown)
                }
                if detail.isVotingLocked(at: fixedNow) { acc += 1 }
                if detail.resultsHidden { acc += 1 }
                if detail.votersVisible { acc += 1 }
                if draft.canSubmit && !draft.hasDuplicates(in: detail) { acc += 1 }
            }
            sheetAcc = acc
        }

        // 1,000 iterations in `ms` == per-render `µs` (`ms * 1000 / 1000 == ms`).
        print(Self.row("(e) 1000x PollDetail render (core record fields)", ms: coreDetailMs, note: String(format: "%.3f µs/render", coreDetailMs)))
        print(Self.row("(e) .. before (25658d9 per-getter FFI)", ms: perGetterFfiMs, note: String(format: "%.3f µs/render", perGetterFfiMs)))
        print(Self.row("(e) .. origin/main PollDetail baseline", ms: baseDetailMs, note: String(format: "%.3f µs/render", baseDetailMs)))
        print(Self.row("(e') 1000x PollVoteDraft + PollDetail votePage render", ms: coreVoteSheetMs, note: String(format: "%.3f µs/render", coreVoteSheetMs)))
        #expect(abs(coreAcc - baseAcc) < 1e-6 && abs(perGetterAcc - baseAcc) < 1e-6)
        #expect(coreFlags == baseFlags && perGetterFlags == baseFlags && sheetAcc > 0)
    }
}
