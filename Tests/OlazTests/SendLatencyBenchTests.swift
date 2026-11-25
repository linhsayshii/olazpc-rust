import Foundation
import Observation
import os
import Testing
@testable import Olaz

/// U5 release benchmark: measures send-to-row-visible latency on the MainActor (time from calling
/// `ZaloEngine.sendText` until the optimistic `.sending` row is visible in `engine.messages[convId]`).
/// Run in release mode for real numbers:
///   `swift test -c release --filter SendLatencyBench`
@Suite(.serialized) struct SendLatencyBenchTests {
    @MainActor
    @Test func sendToRowVisibleMainActorLatency() async throws {
        let warmup = ProcessInfo.processInfo.environment["OLAZ_BENCH_WARMUP"].flatMap(Int.init) ?? 5
        let iterations = ProcessInfo.processInfo.environment["OLAZ_BENCH_ITERS"].flatMap(Int.init) ?? 30
        let totalSends = warmup + iterations
        let convId = "3000999"
        let myUid = "2000999"
        let testEnk = Data("0123456789abcdef0123456789abcdef".utf8).base64EncodedString()
        let secretKey = ZaloCrypto.parseSecretKey(testEnk)

        var serverScript: [CaseJSON] = [
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
                            "send2me_id": .string("9200999"),
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
        for i in 0..<totalSends {
            serverScript.append(.object([
                "kind": .string("http"),
                "path": .string("/api/message/sms"),
                "method": .string("POST"),
                "response": .object([
                    "status": .int(200),
                    "json": .object([
                        "error_code": .int(0),
                        "data": .object([
                            "msgId": .string("\(9_900_000 + i)"),
                        ]),
                    ]),
                ]),
            ]))
        }

        let server = try FakeZaloServer(serverScript: serverScript, initialSecretKey: secretKey)
        try await server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-send-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Seed realistic 50-message SQLite conversation window before boot.
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
                previewText: "Seed message #49",
                previewTsMs: baseMs + 49_000,
                previewFromMe: true,
                updatedAtMs: baseMs + 49_000
            ),
        ])
        var seedRows: [StoredMessage] = []
        seedRows.reserveCapacity(50)
        for i in 0..<50 {
            let tsMs = baseMs + Int64(i) * 1000
            let isMine = (i % 2 != 0)
            let msg = ChatMessage(
                id: "\(8_000_000 + i)",
                conversationId: convId,
                senderId: isMine ? myUid : convId,
                senderName: isMine ? "Bench User" : "Bench Peer",
                senderAvatar: nil,
                isMine: isMine,
                kind: .text,
                text: "Seed message #\(i)",
                date: Date(timeIntervalSince1970: Double(tsMs) / 1000.0),
                status: .sent,
                quote: nil,
                reactions: [],
                isE2EE: false,
                clientId: "seed_\(i)"
            )
            if let encoded = ZaloWireParser.encodeChatMessage(msg, clientId: "seed_\(i)") {
                seedRows.append(encoded)
            }
        }
        try await seedStore.saveMessages(seedRows)

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
                "send2MeId": .string("9200999"),
                "dkey": .string("dk-bench"),
                "zpwEnk": .string(testEnk),
                "zpwSek": .string("sek.bench.1"),
            ]),
        ])
        try Data(savedSession.canonicalString().utf8)
            .write(to: root.appendingPathComponent("native-session.json"), options: .atomic)

        let storage = RecorderStorageIsolation(prefix: "olaz.send-bench")
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
        #expect((engine.messages[convId]?.count ?? 0) == 50)

        /// Wait on MainActor using Observation tracking until `engine.messages[convId]` has at least `targetCount` rows.
        func waitForRowVisible(targetCount: Int) async {
            while (engine.messages[convId]?.count ?? 0) < targetCount {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    let pending = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: cont)
                    let current = withObservationTracking {
                        engine.messages[convId]?.count ?? 0
                    } onChange: {
                        Task { @MainActor in
                            pending.withLock { c in
                                let out = c
                                c = nil
                                return out
                            }?.resume()
                        }
                    }
                    if current >= targetCount {
                        pending.withLock { c in
                            let out = c
                            c = nil
                            return out
                        }?.resume()
                    }
                }
            }
        }

        var samplesMs: [Double] = []
        samplesMs.reserveCapacity(iterations)

        for i in 0..<totalSends {
            let expectedCount = (engine.messages[convId]?.count ?? 0) + 1
            let text = "Bench send #\(i)"
            let start = ContinuousClock.now
            let sendTask = Task { @MainActor in
                await engine.sendText(text, to: convId)
            }
            await waitForRowVisible(targetCount: expectedCount)
            let elapsed = ContinuousClock.now - start
            let ms = Double(elapsed.components.seconds) * 1000.0
                + Double(elapsed.components.attoseconds) / 1e15
            let ok = await sendTask.value
            #expect(ok)
            if i >= warmup {
                samplesMs.append(ms)
            }
        }

        let sorted = samplesMs.sorted()
        let p50 = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let minMs = sorted.first ?? 0
        let maxMs = sorted.last ?? 0
        print(String(
            format: "PERF send-to-row-visible MainActor (n=%d): p50=%.3f ms  p95=%.3f ms  min=%.3f ms  max=%.3f ms",
            iterations, p50, p95, minMs, maxMs
        ))
        #expect(engine.messages[convId]?.count == 50 + totalSends)

        engine.cancelTasksForRecording()
        await engine.finishTearDownForRecording()
    }
}
