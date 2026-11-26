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

    private struct OriginMainPollVoteDraft {
        struct Added: Identifiable, Equatable {
            var id = UUID()
            var text = ""
            var voted = false
        }
        private(set) var selected: Set<String>
        private let original: Set<String>
        private let multi: Bool
        var added: [Added] = []

        init(_ detail: OriginMainPollDetail) {
            let voted = Set(detail.options.filter(\.voted).map(\.id))
            selected = voted
            original = voted
            multi = detail.multi
        }
        mutating func toggle(_ optionId: String) {
            if selected.contains(optionId) { selected.remove(optionId); return }
            if !multi { selected = []; for i in added.indices { added[i].voted = false } }
            selected.insert(optionId)
        }
        mutating func addRow() { added.append(Added()) }
        private var filled: [Added] {
            added.map { Added(id: $0.id, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), voted: $0.voted) }.filter { !$0.text.isEmpty }
        }
        var hasChanges: Bool { selected != original || !filled.isEmpty }
        var votesNothing: Bool { selected.isEmpty && !filled.contains(where: \.voted) }
        func hasDuplicates(in detail: OriginMainPollDetail) -> Bool {
            let all = detail.options.map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) } + filled.map(\.text)
            return Set(all).count != all.count
        }
        func isDuplicate(_ id: UUID, in detail: OriginMainPollDetail) -> Bool {
            guard let row = filled.first(where: { $0.id == id }) else { return false }
            let others = detail.options.map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) } + filled.filter { $0.id != id }.map(\.text)
            return others.contains(row.text)
        }
        func applied(to detail: OriginMainPollDetail) -> OriginMainPollDetail {
            var next = detail
            for i in next.options.indices {
                let was = detail.options[i].voted, now = selected.contains(detail.options[i].id)
                next.options[i].voted = now
                if was != now { next.options[i].votes = max(0, next.options[i].votes + (now ? 1 : -1)) }
            }
            return next
        }
        var canSubmit: Bool { hasChanges }
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
        draft.addRow()
        draft.added[0].text = "Phương án bổ sung 1"
        draft.setAddedVoted(draft.added[0].id, true)

        var baseDraft = OriginMainPollVoteDraft(baseline)
        baseDraft.toggle("opt_3")
        baseDraft.addRow()
        baseDraft.added[0].text = "Phương án bổ sung 1"
        baseDraft.added[0].voted = true

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

        // Interleaved rounds for PollVoteDraft + votePage render (core vs origin/main)
        var coreSheetSamples: [Double] = []
        var baseSheetSamples: [Double] = []
        var sheetAcc = 0.0
        var baseSheetAcc = 0.0
        for round in 0..<8 {
            let runCore = {
                var acc = 0.0
                for _ in 0..<iterations {
                    let preview = draft.applied(to: detail)
                    for opt in detail.options {
                        let shown = preview.options.first { $0.id == opt.id } ?? opt
                        acc += preview.weight(of: shown)
                    }
                    for row in draft.added where draft.isDuplicate(row.id, in: detail) { acc += 1 }
                    if detail.isVotingLocked(at: fixedNow) { acc += 1 }
                    if detail.resultsHidden { acc += 1 }
                    if detail.votersVisible { acc += 1 }
                    if !draft.votesNothing { acc += 1 }
                    if draft.canSubmit && !draft.hasDuplicates(in: detail) { acc += 1 }
                }
                sheetAcc = acc
            }
            let runBase = {
                var acc = 0.0
                for _ in 0..<iterations {
                    let preview = baseDraft.applied(to: baseline)
                    for opt in baseline.options {
                        let shown = preview.options.first { $0.id == opt.id } ?? opt
                        acc += preview.weight(of: shown)
                    }
                    for row in baseDraft.added where baseDraft.isDuplicate(row.id, in: baseline) { acc += 1 }
                    if baseline.isVotingLocked(at: fixedNow) { acc += 1 }
                    if baseline.resultsHidden { acc += 1 }
                    if baseline.votersVisible { acc += 1 }
                    if !baseDraft.votesNothing { acc += 1 }
                    if baseDraft.canSubmit && !baseDraft.hasDuplicates(in: baseline) { acc += 1 }
                }
                baseSheetAcc = acc
            }
            if round == 0 {
                runCore()
                runBase()
                continue
            }
            if round % 2 == 1 {
                let t1 = ContinuousClock.now; runCore(); let d1 = ContinuousClock.now - t1
                let t2 = ContinuousClock.now; runBase(); let d2 = ContinuousClock.now - t2
                coreSheetSamples.append(Double(d1.components.seconds) * 1000 + Double(d1.components.attoseconds) / 1e15)
                baseSheetSamples.append(Double(d2.components.seconds) * 1000 + Double(d2.components.attoseconds) / 1e15)
            } else {
                let t2 = ContinuousClock.now; runBase(); let d2 = ContinuousClock.now - t2
                let t1 = ContinuousClock.now; runCore(); let d1 = ContinuousClock.now - t1
                baseSheetSamples.append(Double(d2.components.seconds) * 1000 + Double(d2.components.attoseconds) / 1e15)
                coreSheetSamples.append(Double(d1.components.seconds) * 1000 + Double(d1.components.attoseconds) / 1e15)
            }
        }
        let coreVoteSheetMs = coreSheetSamples.sorted()[coreSheetSamples.count / 2]
        let baseVoteSheetMs = baseSheetSamples.sorted()[baseSheetSamples.count / 2]

        // 1,000 iterations in `ms` == per-render `µs` (`ms * 1000 / 1000 == ms`).
        print(Self.row("(e) 1000x PollDetail render (core record fields)", ms: coreDetailMs, note: String(format: "%.3f µs/render", coreDetailMs)))
        print(Self.row("(e) .. before (25658d9 per-getter FFI)", ms: perGetterFfiMs, note: String(format: "%.3f µs/render", perGetterFfiMs)))
        print(Self.row("(e) .. origin/main PollDetail baseline", ms: baseDetailMs, note: String(format: "%.3f µs/render", baseDetailMs)))
        print(Self.row("(e') 1000x PollVoteDraft + votePage render (core)", ms: coreVoteSheetMs, note: String(format: "%.3f µs/render", coreVoteSheetMs)))
        print(Self.row("(e') .. origin/main PollVoteDraft + votePage baseline", ms: baseVoteSheetMs, note: String(format: "%.3f µs/render", baseVoteSheetMs)))
        #expect(abs(coreAcc - baseAcc) < 1e-6 && abs(perGetterAcc - baseAcc) < 1e-6 && abs(sheetAcc - baseSheetAcc) < 1e-6)
        #expect(coreFlags == baseFlags && perGetterFlags == baseFlags && sheetAcc > 0)
    }

    // MARK: (f) U16 incoming notification decision, 200-message burst vs origin/main

    /// Verbatim `origin/main` Swift incoming-notification loop (`ZaloEngine.notifyIncomingBatchMessages`
    /// + `lookupPersonInfo`), returning the banners that would be passed to `NativeNotifier`.
    private struct OriginMainIncomingBaseline {
        let myUid: String
        let conversations: [ZaloEngine.ConversationSummary]
        let friends: [ContactsState.Friend]
        let cachedAliases: [String: String]
        let cachedProfiles: [String: ZaloWebKitMigrator.CachedProfile]
        let friendUidByGlobalId: [String: String]
        let mutes: [String: MuteInfo]
        let enabled: Bool
        let sound: Bool
        let showsPreview: Bool

        private func isMuted(_ convId: String, now: Date) -> Bool {
            guard let info = mutes[convId] else { return false }
            return info.isActive(at: now)
        }

        private func lookupPersonInfo(_ uid: String) -> (name: String, avatar: String)? {
            let clean = ZaloWireParser.stripUserPrefix(uid)
            guard !clean.isEmpty, clean != "0", clean != "-1", clean != "__legacy__", clean != "unknown" else {
                return nil
            }
            var candidates: [String] = [clean]
            if let sanitized = ZaloWireParser.sanitizeProfileUid(clean), sanitized != clean {
                candidates.append(sanitized)
            }
            if let mappedUid = candidates.lazy.compactMap({ self.friendUidByGlobalId[$0] }).first,
               !candidates.contains(mappedUid) {
                candidates.append(mappedUid)
            }

            let cleanMyUid = ZaloWireParser.stripUserPrefix(myUid)
            let sanitizedMyUid = ZaloWireParser.sanitizeProfileUid(cleanMyUid) ?? cleanMyUid
            if !cleanMyUid.isEmpty, candidates.contains(where: { $0 == cleanMyUid || $0 == sanitizedMyUid }) {
                return ("Bạn", "")
            }

            for candidate in candidates {
                let alias = cachedAliases[candidate]
                if let f = friends.first(where: { $0.id == candidate }) {
                    let avt = f.avatar?.absoluteString ?? cachedProfiles[candidate]?.avatar ?? ""
                    return (alias?.isEmpty == false ? alias! : f.name, avt)
                }
                if let p = cachedProfiles[candidate] {
                    let best = (alias?.isEmpty == false) ? alias! : p.name
                    let validBest = (best == ReactionDetail.unknownName) ? "" : best
                    if !validBest.isEmpty || !p.avatar.isEmpty {
                        return (validBest, p.avatar)
                    }
                }
                if let alias, !alias.isEmpty, alias != ReactionDetail.unknownName {
                    return (alias, "")
                }
            }
            for candidate in candidates {
                if let conv = conversations.first(where: { $0.id == candidate }) {
                    let trimmedName = conv.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let validName = (!trimmedName.isEmpty && trimmedName != conv.id && trimmedName != ReactionDetail.unknownName) ? trimmedName : ""
                    let avt = conv.avatar?.absoluteString ?? ""
                    if !validName.isEmpty || !avt.isEmpty {
                        return (validName, avt)
                    }
                }
            }
            return nil
        }

        @MainActor
        func run(_ incoming: [ChatMessage], now: Date) -> [NotifyBannerRecord] {
            var out: [NotifyBannerRecord] = []
            out.reserveCapacity(incoming.count)
            for msg in incoming where !isMuted(msg.conversationId, now: now) && enabled {
                let convId = msg.conversationId
                let isGroup = ZaloWireParser.isGroupId(convId)
                let cleanSenderId = ZaloWireParser.stripUserPrefix(msg.senderId)
                let convSummary = conversations.first(where: { $0.id == convId })
                let person = (!cleanSenderId.isEmpty && cleanSenderId != "0") ? lookupPersonInfo(cleanSenderId) : nil

                let resolvedAvatarURL: URL? = msg.senderAvatar
                    ?? (person?.avatar.isEmpty == false ? URL(string: person!.avatar) : nil)
                    ?? (!isGroup ? convSummary?.avatar : nil)

                let title: String = {
                    if let convName = convSummary?.displayName, !convName.isEmpty, convName != convId {
                        return convName
                    }
                    if let pName = person?.name, !pName.isEmpty, pName != cleanSenderId {
                        return pName
                    }
                    return msg.senderName.isEmpty ? convId : msg.senderName
                }()

                let senderName: String = {
                    if !isGroup {
                        return title
                    }
                    if let pName = person?.name, !pName.isEmpty, pName != cleanSenderId, pName != "Người dùng Zalo" {
                        return pName
                    }
                    return msg.senderName
                }()

                let rawBody = ZaloEngine.messagePreviewLabel(msg)
                let body = showsPreview ? rawBody : NotificationPolicy.hiddenPreviewBody
                out.append(NotifyBannerRecord(
                    title: title,
                    body: body,
                    convId: convId,
                    senderId: cleanSenderId,
                    senderName: senderName,
                    isGroup: isGroup,
                    avatarURL: resolvedAvatarURL?.absoluteString,
                    silent: !sound
                ))
            }
            return out
        }
    }

    @MainActor
    @Test func incomingDecisionBurst200() async throws {
        let fixedNowMs: Int64 = 1_795_000_000_000
        let fixedNowSecs = Double(fixedNowMs) / 1000.0
        let fixedNow = Date(timeIntervalSince1970: fixedNowSecs)
        let dir = Self.tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let storage = RecorderStorageIsolation(prefix: "olaz.u16-perf")
        defer { storage.cleanup() }
        let engine = ZaloEngine(
            dataDirectory: dir,
            useKeychain: false,
            userDefaultsSuiteName: storage.userDefaultsSuiteName,
            cookieStorage: storage.cookieStorage
        )
        defer { engine.cancelTasksForRecording() }
        engine.nowMs = { fixedNowMs }

        // Corpus: 700 conversations (250 groups + 450 1-1), 500 friends, aliases, cachedProfiles, 100 mutes.
        let conversations: [ZaloEngine.ConversationSummary] = (0..<700).map { i in
            let isGroup = i < 250
            let id = isGroup ? "g\(100_000 + i)" : "\(200_000 + i - 250)"
            let name = isGroup ? "Nhóm dự án \(i)" : "Bạn bè \(i - 250)"
            return ZaloEngine.ConversationSummary(
                id: id,
                isGroup: isGroup,
                name: name,
                avatar: URL(string: "https://cdn.example/conv/\(id).jpg"),
                pinned: i % 50 == 0,
                members: isGroup ? 12 + (i % 40) : 2,
                unread: i % 5,
                preview: nil
            )
        }
        let friends: [ContactsState.Friend] = (0..<500).map { i in
            let uid = "\(200_000 + i)"
            return ContactsState.Friend(
                id: uid,
                name: "Người liên hệ \(i)",
                zaloName: "Zalo \(i)",
                avatar: URL(string: "https://cdn.example/friend/\(uid).jpg"),
                lastActive: nil,
                online: i % 4 == 0,
                section: "N",
                sortKey: "nguoi lien he \(i)"
            )
        }
        var aliases: [String: String] = [:]
        var profiles: [String: ZaloWebKitMigrator.CachedProfile] = [:]
        var globalIds: [String: String] = [:]
        for i in 0..<120 {
            let uid = "\(200_000 + i * 3)"
            aliases[uid] = "Biệt danh \(i)"
            globalIds[uid] = "gid_\(uid)"
        }
        for i in 0..<150 {
            let uid = "\(200_500 + i)"
            let name = (i % 10 == 0) ? "Người dùng Zalo" : "Hồ sơ \(i)"
            profiles[uid] = ZaloWebKitMigrator.CachedProfile(name: name, avatar: "https://cdn.example/prof/\(uid).jpg")
        }

        var mutePayloadRows: [[String: Any]] = []
        var mutesMap: [String: MuteInfo] = [:]
        for i in 0..<100 {
            let convId = (i % 2 == 0) ? "g\(100_000 + i)" : "\(200_000 + i)"
            let start: TimeInterval
            let duration: TimeInterval
            if i < 40 {
                // Active indefinite
                start = fixedNowSecs - 1200
                duration = -1
            } else if i < 80 {
                // Active timed (expires in the future)
                start = fixedNowSecs - 600
                duration = 3600
            } else {
                // Expired timed (should notify)
                start = fixedNowSecs - 7200
                duration = 3600
            }
            mutePayloadRows.append(["id": convId, "startTime": start, "duration": duration])
            mutesMap[convId] = MuteInfo(startTime: start, duration: duration)
        }

        let core = try #require(await engine.ensureCoreEngine())
        engine.conversations = conversations
        var contactsState = ContactsState()
        contactsState.friends = friends
        engine.contacts = contactsState
        engine.cachedAliases = aliases
        engine.cachedProfiles = profiles
        engine.cachedFriendGlobalIds = globalIds
        engine.handleNotification(state: [
            "notification": [
                "kind": "settings",
                "enabled": true,
                "sound": true,
                "mutes": mutePayloadRows,
            ]
        ])
        let settled = try await core.settle()
        await engine.waitForMirrorVersion(settled)

        // 200-message burst mixing 1-1, group, muted, expired-mute, aliases, globalIds, cachedProfiles, fallback names.
        let burst: [ChatMessage] = (0..<200).map { i in
            let isGroup = i % 2 == 0
            let convId: String
            let senderId: String
            if i < 40 {
                // Actively muted (20 group + 20 1-1)
                convId = isGroup ? "g\(100_000 + (i / 2) * 2)" : "\(200_000 + (i / 2) * 2 + 1)"
                senderId = "\(200_000 + i)"
            } else if i < 50 {
                // Expired mute (must notify)
                let muteIdx = 80 + (i - 40) * 2
                convId = isGroup ? "g\(100_000 + muteIdx)" : "\(200_000 + muteIdx + 1)"
                senderId = "\(200_000 + 300 + (i - 40))"
            } else if isGroup {
                let gIdx = 100 + (i % 140)
                convId = "g\(100_000 + gIdx)"
                if i % 6 == 0 {
                    // Sender resolved via globalId -> alias/friend
                    let uid = "\(200_000 + ((i / 6) % 100) * 3)"
                    senderId = "gid_\(uid)"
                } else if i % 6 == 2 {
                    // Sender in cachedProfiles (including "Người dùng Zalo" fallback)
                    senderId = "\(200_500 + (i % 150))"
                } else {
                    senderId = "\(200_000 + 200 + (i % 250))"
                }
            } else {
                let cIdx = 100 + (i % 340)
                convId = "\(200_000 + cIdx)"
                senderId = convId
            }

            let kind: ChatMessage.Kind
            let text: String
            switch i % 5 {
            case 0: kind = .text; text = "Tin nhắn burst số \(i) từ hệ thống"
            case 1: kind = .photo(URL(string: "https://cdn.example/img/\(i).jpg")!, thumb: nil, width: 640, height: 480); text = ""
            case 2: kind = .sticker(id: "s\(i)", cateId: "1", preview: nil); text = ""
            case 3: kind = .text; text = "Cuộc họp lúc 15h hôm nay nhé (#\(i))"
            default: kind = .file(name: "bao-cao-\(i).pdf", size: 120_000, url: nil); text = ""
            }

            return ChatMessage(
                id: "9900\(1000 + i)",
                conversationId: convId,
                senderId: senderId,
                senderName: "Tên dây \(i)",
                senderAvatar: (i % 4 == 0) ? URL(string: "https://cdn.example/msg/\(i).jpg") : nil,
                isMine: false,
                kind: kind,
                text: text,
                date: Date(timeIntervalSince1970: fixedNowSecs + Double(i)),
                status: .sent,
                quote: nil,
                reactions: [],
                isE2EE: false
            )
        }

        let baseline = OriginMainIncomingBaseline(
            myUid: "",
            conversations: conversations,
            friends: friends,
            cachedAliases: aliases,
            cachedProfiles: profiles,
            friendUidByGlobalId: Dictionary(globalIds.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a }),
            mutes: mutesMap,
            enabled: true,
            sound: true,
            showsPreview: true
        )

        var coreBanners: [NotifyBannerRecord] = []
        engine.notifyBannerHook = { rec in
            coreBanners.append(rec)
        }
        engine.traceNotifyHostEnabled = true
        engine.hostTrace = { _, _ in false }

        var baseBanners: [NotifyBannerRecord] = []
        var coreSamples: [Double] = []
        var baseSamples: [Double] = []

        for round in 0..<8 {
            let runCore: () async -> Void = {
                coreBanners.removeAll(keepingCapacity: true)
                await engine.notifyIncomingBatchMessages(burst)
            }
            let runBase: () -> Void = {
                baseBanners = baseline.run(burst, now: fixedNow)
            }
            if round == 0 {
                await runCore()
                runBase()
                #expect(coreBanners == baseBanners)
                #expect(coreBanners.count == 160)
                continue
            }
            if round % 2 == 1 {
                let t1 = ContinuousClock.now; await runCore(); let d1 = ContinuousClock.now - t1
                let t2 = ContinuousClock.now; runBase(); let d2 = ContinuousClock.now - t2
                coreSamples.append(Double(d1.components.seconds) * 1000 + Double(d1.components.attoseconds) / 1e15)
                baseSamples.append(Double(d2.components.seconds) * 1000 + Double(d2.components.attoseconds) / 1e15)
            } else {
                let t2 = ContinuousClock.now; runBase(); let d2 = ContinuousClock.now - t2
                let t1 = ContinuousClock.now; await runCore(); let d1 = ContinuousClock.now - t1
                baseSamples.append(Double(d2.components.seconds) * 1000 + Double(d2.components.attoseconds) / 1e15)
                coreSamples.append(Double(d1.components.seconds) * 1000 + Double(d1.components.attoseconds) / 1e15)
            }
        }

        let coreMs = coreSamples.sorted()[coreSamples.count / 2]
        let baseMs = baseSamples.sorted()[baseSamples.count / 2]
        print(Self.row("(f) 200-msg incoming decision burst (Rust core via FFI)", ms: coreMs, note: String(format: "%.1f µs/msg", coreMs * 1000.0 / 200.0)))
        print(Self.row("(f) .. origin/main Swift loop baseline", ms: baseMs, note: String(format: "%.1f µs/msg", baseMs * 1000.0 / 200.0)))
        #expect(coreBanners == baseBanners)
        #expect(coreBanners.count == 160)
    }
}
