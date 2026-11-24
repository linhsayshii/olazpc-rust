import Foundation
import OlazCore
import Testing

@testable import Olaz

/// Swift path vs Rust path on the chat hot paths, from the same inputs. Informational (prints a table, asserts only
/// that both paths agree): run in release for real numbers,
///   `swift test -c release --filter RustCorePerf`
/// (debug numbers measure Swift without optimization and are not comparable).
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

    private static func row(_ label: String, swift: Double, rust: Double, note: String = "") -> String {
        String(format: "PERF %-62@ swift %8.2f ms | rust %8.2f ms | %@%@", label as NSString, swift, rust,
               (rust <= swift ? "rust faster x\(String(format: "%.2f", swift / max(rust, 0.001)))" : "RUST SLOWER x\(String(format: "%.2f", rust / max(swift, 0.001)))") as NSString,
               (note.isEmpty ? "" : "  (\(note))") as NSString)
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
        var swiftCount = 0, rustCount = 0
        let swift = Self.median {
            var n = 0
            for data in payloads {
                guard let dict = JSONLossless.parseObject(data) else { continue }
                for case .message(let m, _) in ZaloWireParser.extractBatchEvents(dict, myUid: "me", defaultCmd: 501, nameLookup: Self.lookup, useRustCore: false) { _ = m; n += 1 }
            }
            swiftCount = n
        }
        // Rust arm: what the socket task + listener + engine do per envelope (parse in the core with the session name
        // table, Swift resolves uids and confirms with `resolve`, then maps records to ChatMessage values).
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
        // Before 4a: listener parsed the payload JSON into a dict (`onEvent`), then dict -> JSON -> core -> JSON decode.
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
        print(Self.row("(a) 2000 realtime events -> ChatMessage (1 msg each)", swift: swift, rust: rust))
        print(Self.row("(a) .. vs the Rust route before 4a (JSON re-parse in Swift)", swift: swift, rust: legacy))
        #expect(swiftCount == 2000 && rustCount == 2000 && legacyCount == 2000)
    }

    // MARK: (b) history batch of 2,000

    @Test func historyBatch2000() throws {
        let root: [String: Any] = ["data": ["msgs": (0..<2000).map { Self.wireMessage($0) }]]
        let data = try JSONSerialization.data(withJSONObject: root)
        var swiftEvents: [ParsedWireEvent] = [], rustEvents: [ParsedWireEvent] = []
        let swift = Self.median {
            guard let dict = JSONLossless.parseObject(data) else { return }
            swiftEvents = ZaloWireParser.extractBatchEvents(dict, myUid: "me", nameLookup: Self.lookup, useRustCore: false)
        }
        let names = [NameEntry(uid: "u1", name: "An", avatar: "https://ava.example/an.jpg")]
        let rust = Self.median {
            guard let events = try? parseWireBatchBytes(json: data, myUid: "me", options: WireOptions(cmd: 0, names: names)) else { return }
            rustEvents = ZaloWireParser.parsedEvents(from: events)
        }
        // The engine's current history route: Swift dict -> JSON text -> core (what 4a replaced on the realtime path only).
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
        // Wave 5a: the engine's history route now: the core keeps the parsed answer (`HistoryBatch`), Swift resolves names and
        // maps typed events. The body parse stands in for the HTTP answer the core already holds; no dict, no JSON text.
        let jsonText = String(decoding: data, as: UTF8.self)
        var typedCount = 0
        let typedPage = Self.median {
            guard let record = try? historyRecordFromJson(json: jsonText) else { return }
            var resolved: [NameEntry] = []
            for uid in record.uids { if let hit = Self.lookup(uid) { resolved.append(NameEntry(uid: uid, name: hit.name, avatar: hit.avatar)) } }
            typedCount = ZaloWireParser.parsedEvents(from: record.batch.events(myUid: "me", options: WireOptions(cmd: 0, names: resolved))).count
        }
        print(Self.row("(b'') history page 2000: typed HistoryBatch (wave 5a)", swift: swift, rust: typedPage, note: "vs Swift bytes -> dict -> walk"))
        print(Self.row("(b'') .. vs the previous engine route (dict -> JSON -> core)", swift: viaDict, rust: typedPage))
        #expect(typedCount == 2000)
        print(Self.row("(b) history batch 2000: bytes -> ChatMessage", swift: swift, rust: rust))
        print(Self.row("(b) .. vs the Rust route before 4a (dict -> JSON -> core -> JSON decode)", swift: swift, rust: legacy))
        #expect(legacyCount == 2000)
        print(Self.row("(b') history batch 2000: dict -> JSON -> core (engine HTTP route)", swift: swift, rust: viaDict, note: "dict already parsed in Swift"))
        #expect(swiftEvents.count == 2000 && rustEvents.count == 2000)
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
        let events = ZaloWireParser.extractBatchEvents(["data": ["msgs": msgs]], myUid: "me", useRustCore: false)
        let stored: [StoredMessage] = events.compactMap { if case .message(_, let s) = $0 { s } else { nil } }
        let chats: [ChatMessage] = events.compactMap { if case .message(let m, _) = $0 { m } else { nil } }
        #expect(stored.count == 2000 && chats.count == 2000)
        let convIds = (0..<convs).map { "peer\($0)" }

        func fresh(rust: Bool) throws -> (ZaloSQLiteStore, URL) {
            let dir = Self.tempDir()
            return (try ZaloSQLiteStore(path: dir.appendingPathComponent("p.db").path, useRustCore: rust), dir)
        }
        var dirs: [URL] = []
        defer { for d in dirs { try? FileManager.default.removeItem(at: d) } }

        var store: ZaloSQLiteStore! = nil

        func saveTime(rust: Bool, typed: Bool) async throws -> Double {
            try await Self.medianAsync(setup: {
                let (s, d) = try fresh(rust: rust); dirs.append(d); store = s
            }, {
                if typed { try await store.saveChatMessages(chats) } else { try await store.saveMessages(stored) }
            })
        }
        let swiftSave = try await saveTime(rust: false, typed: false)
        let rustSave = try await saveTime(rust: true, typed: false)
        let rustTypedSave = try await saveTime(rust: true, typed: true)
        let swiftTypedSave = try await saveTime(rust: false, typed: true)
        print(Self.row("(c) save 2000 rows (StoredMessage -> store)", swift: swiftSave, rust: rustSave))
        print(Self.row("(c) save 2000 typed (ChatMessage -> store, Rust encodes)", swift: swiftTypedSave, rust: rustTypedSave, note: "swift column = encodeChatMessage + save"))

        // Load: 50 newest per conversation, decoded to ChatMessage.
        let (swiftStore, d1) = try fresh(rust: false); dirs.append(d1)
        let (rustStore, d2) = try fresh(rust: true); dirs.append(d2)
        try await swiftStore.saveMessages(stored)
        try await rustStore.saveMessages(stored)
        var swiftLoaded = 0, rustLoaded = 0, rustSyncLoaded = 0, swiftSyncLoaded = 0, legacyLoaded = 0
        let legacyLoad = try await Self.medianAsync {
            var n = 0
            for c in convIds { n += try await rustStore.messages(convId: c, limit: 50).compactMap { ZaloWireParser.decodeStoredMessage($0) }.count }
            legacyLoaded = n
        }
        let swiftLoad = try await Self.medianAsync {
            var n = 0
            for c in convIds { n += try await swiftStore.decodedMessages(convId: c, limit: 50).count }
            swiftLoaded = n
        }
        let rustLoad = try await Self.medianAsync {
            var n = 0
            for c in convIds { n += try await rustStore.decodedMessages(convId: c, limit: 50).count }
            rustLoaded = n
        }
        let swiftSync = Self.median { var n = 0; for c in convIds { n += swiftStore.readDecodedMessagesNow(convId: c, limit: 50)?.count ?? 0 }; swiftSyncLoaded = n }
        let rustSync = Self.median { var n = 0; for c in convIds { n += rustStore.readDecodedMessagesNow(convId: c, limit: 50)?.count ?? 0 }; rustSyncLoaded = n }
        print(Self.row("(c) load 50 x 40 conversations -> ChatMessage (async)", swift: swiftLoad, rust: rustLoad))
        print(Self.row("(c) load 50 x 40 conversations -> ChatMessage (sync first-frame)", swift: swiftSync, rust: rustSync))
        print(Self.row("(c) .. vs the Rust route before 4a (rows + JSON decode in Swift)", swift: swiftLoad, rust: legacyLoad))
        #expect(legacyLoaded == 2000 && swiftLoaded == 2000 && rustLoaded == 2000 && swiftSyncLoaded == 2000 && rustSyncLoaded == 2000)
    }

    // MARK: (d) conversation list, 700 rows

    @Test func conversationList700() async throws {
        let items = (0..<700).map { i in
            StoredConversation(id: "conv\(i)", isGroup: i % 3 == 0, name: "Hội thoại \(i)", avatar: "https://cdn.example/\(i).jpg", pinned: i % 50 == 0, members: i,
                               unread: i % 5, previewText: "Tin cuối cùng của \(i)", previewTsMs: 1_795_000_000_000 + Int64(i), previewFromMe: i % 2 == 0, updatedAtMs: 1_795_000_000_000 + Int64(i))
        }
        let dirA = Self.tempDir(), dirB = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dirA); try? FileManager.default.removeItem(at: dirB) }
        let swiftStore = try ZaloSQLiteStore(path: dirA.appendingPathComponent("p.db").path, useRustCore: false)
        let rustStore = try ZaloSQLiteStore(path: dirB.appendingPathComponent("p.db").path, useRustCore: true)
        try await swiftStore.saveConversations(items)
        try await rustStore.saveConversations(items)
        var a = 0, b = 0
        let swift = try await Self.medianAsync { a = try await swiftStore.loadConversations().count }
        let rust = try await Self.medianAsync { b = try await rustStore.loadConversations().count }
        print(Self.row("(d) load 700 conversations", swift: swift, rust: rust))
        #expect(a == 700 && b == 700)
    }
}
