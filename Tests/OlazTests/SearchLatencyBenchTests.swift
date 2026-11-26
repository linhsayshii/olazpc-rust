import Foundation
import OlazCore
import Testing
@testable import Olaz

/// U14 release benchmark: measures `searchMessages` and `ensureMessageLoaded` latency on a seeded
/// conversation (default 200 msgs in normal `swift test`; set `OLAZ_SEARCH_BENCH_MSGS=10000` and
/// `OLAZ_SEARCH_BENCH_ITERS=30` in release mode for the 10k-message A/B benchmark).
@Suite(.serialized) struct SearchLatencyBenchTests {
    @MainActor
    @Test func searchAndEnsureLoadedLatency() async throws {
        let totalMessages = ProcessInfo.processInfo.environment["OLAZ_SEARCH_BENCH_MSGS"].flatMap(Int.init) ?? 200
        let warmup = ProcessInfo.processInfo.environment["OLAZ_SEARCH_BENCH_WARMUP"].flatMap(Int.init) ?? 2
        let iterations = ProcessInfo.processInfo.environment["OLAZ_SEARCH_BENCH_ITERS"].flatMap(Int.init) ?? 5
        let convId = "3000888"
        let myUid = "2000888"
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
                            "zpw_sek": .string("sek.bench.1"),
                            "display_name": .string("Bench User"),
                            "send2me_id": .string("9200888"),
                            "zpw_ws": .array([.string("ws://fake")]),
                            "zpw_service_map_v3": .object([
                                "chat": .array([.string("http://fake")]),
                                "group": .array([.string("http://fake")]),
                                "profile": .array([.string("http://fake")]),
                                "file": .array([.string("http://fake")]),
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
                            "displayName": .string("Bench User"),
                        ]),
                    ]),
                ]),
            ]),
        ]

        let server = try FakeZaloServer(serverScript: serverScript, initialSecretKey: secretKey)
        try await server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-search-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dbURL = root
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(myUid, isDirectory: true)
            .appendingPathComponent("history.sqlite3")
        let seedStore = try ZaloSQLiteStore(path: dbURL.path)
        try await seedStore.setPreferenceString(key: ZaloWebKitMigrator.donePrefKey, value: "1")
        let baseMs: Int64 = 1_795_000_000_000
        try await seedStore.saveConversations([
            StoredConversation(
                id: convId,
                isGroup: false,
                name: "Bench Peer",
                avatar: "",
                pinned: false,
                members: 0,
                unread: 0,
                previewText: "Regular chatter #\(totalMessages - 1)",
                previewTsMs: baseMs + Int64(totalMessages - 1) * 1000,
                previewFromMe: true,
                updatedAtMs: baseMs + Int64(totalMessages - 1) * 1000
            ),
        ])

        var seedRows: [StoredMessage] = []
        seedRows.reserveCapacity(totalMessages)
        var targetOlderMessage: ChatMessage?
        let targetIndex = max(10, totalMessages - 600) // ~600 messages back from tip (outside initial 50 window, within maxWindow 3000)
        for i in 0..<totalMessages {
            let tsMs = baseMs + Int64(i) * 1000
            let isMine = (i % 2 != 0)
            let text: String
            if i == targetIndex {
                text = "Release milestone ĐẶC BIỆT target #\(i)"
            } else if i % 200 == 0 {
                text = "Release milestone #\(i) cập nhật sản phẩm"
            } else if i % 250 == 17 {
                text = "Họp nhóm sáng thứ hai #\(i)"
            } else {
                text = "Regular conversation chatter message number #\(i) with ordinary words"
            }
            let msg = ChatMessage(
                id: "\(7_000_000 + i)",
                conversationId: convId,
                senderId: isMine ? myUid : convId,
                senderName: isMine ? "Bench User" : "Bench Peer",
                senderAvatar: nil,
                isMine: isMine,
                kind: .text,
                text: text,
                date: Date(timeIntervalSince1970: Double(tsMs) / 1000.0),
                status: .sent,
                quote: nil,
                reactions: [],
                isE2EE: false,
                clientId: "seed_\(i)"
            )
            if i == targetIndex {
                targetOlderMessage = msg
            }
            if let encoded = ZaloWireParser.encodeChatMessage(msg, clientId: "seed_\(i)") {
                seedRows.append(encoded)
            }
        }
        try await seedStore.saveMessages(seedRows)
        let targetMsg = try #require(targetOlderMessage)

        var isolatedDomains = ZaloDomains()
        isolatedDomains.auth = server.baseURLString
        isolatedDomains.wpaChat = server.baseURLString
        isolatedDomains.lpChat = server.baseURLString
        isolatedDomains.lpControl = server.baseURLString
        isolatedDomains.ws = [server.wsBaseURLString]
        isolatedDomains.serviceCandidates = [
            "chat": [server.baseURLString],
            "group": [server.baseURLString],
            "profile": [server.baseURLString],
            "file": [server.baseURLString],
        ]
        isolatedDomains.isolated = true

        let savedSession: CaseJSON = .object([
            "zpwType": .string(ZaloDomains.zpwType),
            "imei": .string("00000000-0000-4000-8000-000000000000-00000000000000000000000000000000"),
            "computerName": .string("BenchMac"),
            "domains": .object([
                "auth": .string(server.baseURLString),
                "wpaChat": .string(server.baseURLString),
                "lpChat": .string(server.baseURLString),
                "lpControl": .string(server.baseURLString),
                "ws": .array([.string(server.wsBaseURLString)]),
                "serviceCandidates": .object([
                    "chat": .array([.string(server.baseURLString)]),
                    "group": .array([.string(server.baseURLString)]),
                    "profile": .array([.string(server.baseURLString)]),
                    "file": .array([.string(server.baseURLString)]),
                ]),
                "preferredHosts": .object([:]),
                "isolated": .bool(true),
            ]),
            "sealedSecretsBase64": .null,
            "expiredAt": .null,
            "plainAccount": .object([
                "userId": .string(myUid),
                "displayName": .string("Bench User"),
                "avatar": .string(""),
                "phone": .string(""),
                "send2MeId": .string("9200888"),
                "dkey": .string("dk-bench"),
                "zpwEnk": .string(testEnk),
                "zpwSek": .string("sek.bench.1"),
            ]),
        ])
        try Data(savedSession.canonicalString().utf8)
            .write(to: root.appendingPathComponent("native-session.json"), options: .atomic)

        let storage = RecorderStorageIsolation(prefix: "olaz.search-bench")
        defer { storage.cleanup() }
        let engine = ZaloEngine(
            dataDirectory: root,
            useKeychain: false,
            domains: isolatedDomains,
            userDefaultsSuiteName: storage.userDefaultsSuiteName,
            cookieStorage: storage.cookieStorage
        )
        engine.historyFreshness[convId] = .upToDate
        engine.hostTrace = { name, _ in
            name == "prepare_store"
        }

        engine.start()
        _ = await engine.bootTask?.value
        #expect(engine.phase == .ready)
        engine.openConversation(convId)
        await engine.settleForRecording()
        let initialWindow = engine.messages[convId] ?? []
        #expect(initialWindow.count == min(50, totalMessages))

        func summarize(_ label: String, _ samples: [Double]) {
            let sorted = samples.sorted()
            let p50 = sorted[sorted.count / 2]
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            let minMs = sorted.first ?? 0
            let maxMs = sorted.last ?? 0
            print(String(
                format: "PERF %@ (msgs=%d, n=%d): p50=%.3f ms  p95=%.3f ms  min=%.3f ms  max=%.3f ms",
                label, totalMessages, samples.count, p50, p95, minMs, maxMs
            ))
        }

        // 1. ASCII query across full 10k store + memory
        var asciiSamples: [Double] = []
        asciiSamples.reserveCapacity(iterations)
        for i in 0..<(warmup + iterations) {
            let start = ContinuousClock.now
            let hits = await engine.searchMessages(in: convId, query: "release milestone", limit: 50)
            let elapsed = ContinuousClock.now - start
            #expect(!hits.isEmpty)
            if i >= warmup {
                asciiSamples.append(Double(elapsed.components.seconds) * 1000.0 + Double(elapsed.components.attoseconds) / 1e15)
            }
        }
        summarize("searchMessages[ascii]", asciiSamples)

        // 2. Vietnamese / Unicode query across full 10k store + memory
        var uniSamples: [Double] = []
        uniSamples.reserveCapacity(iterations)
        for i in 0..<(warmup + iterations) {
            let start = ContinuousClock.now
            let hits = await engine.searchMessages(in: convId, query: "họp nhóm", limit: 50)
            let elapsed = ContinuousClock.now - start
            #expect(!hits.isEmpty)
            if i >= warmup {
                uniSamples.append(Double(elapsed.components.seconds) * 1000.0 + Double(elapsed.components.attoseconds) / 1e15)
            }
        }
        summarize("searchMessages[unicode]", uniSamples)

        // 3. ensureMessageLoaded jumping ~600 messages back from tip (cold window each iteration)
        var ensureSamples: [Double] = []
        ensureSamples.reserveCapacity(iterations)
        for i in 0..<(warmup + iterations) {
            // Reset window back to initial newest 50 in both Swift mirror and Rust core
            engine.messages[convId] = initialWindow
            engine.coreLifecycle.core?.writeThroughReplaceWindow(
                convId: convId,
                messages: initialWindow.map(ChatMessageRecord.init(message:))
            )
            await engine.settleForRecording()
            #expect(engine.messages[convId]?.contains(where: { $0.id == targetMsg.id }) == false)

            let start = ContinuousClock.now
            let loaded = await engine.ensureMessageLoaded(targetMsg, in: convId)
            let elapsed = ContinuousClock.now - start
            #expect(loaded)
            #expect(engine.messages[convId]?.contains(where: { $0.id == targetMsg.id }) == true)
            if i >= warmup {
                ensureSamples.append(Double(elapsed.components.seconds) * 1000.0 + Double(elapsed.components.attoseconds) / 1e15)
            }
        }
        summarize("ensureMessageLoaded[cold-600]", ensureSamples)

        engine.cancelTasksForRecording()
        await engine.finishTearDownForRecording()
    }
}
