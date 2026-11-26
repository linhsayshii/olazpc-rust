import Foundation
import Observation
import os
import Testing
@testable import Olaz

/// U7 release benchmark: measures MainActor optimistic latency for:
/// 1. `pin-to-visible`: time from calling `ZaloEngine.pinMessage` until the pinned item is visible in `engine.pins[convId]`.
/// 2. `unpin-to-hidden`: time from calling `ZaloEngine.answerMessageConfirm(..., ok: true)` on an unpin confirmation until the item is removed from `engine.pins[convId]`.
/// Run in release mode for real numbers:
///   `OLAZ_BENCH_WARMUP=10 OLAZ_BENCH_ITERS=200 swift test -c release --filter PinLatencyBench`
@Suite(.serialized) struct PinLatencyBenchTests {
    @MainActor
    @Test func pinAndUnpinMainActorLatency() async throws {
        let warmup = ProcessInfo.processInfo.environment["OLAZ_BENCH_WARMUP"].flatMap(Int.init) ?? 5
        let iterations = ProcessInfo.processInfo.environment["OLAZ_BENCH_ITERS"].flatMap(Int.init) ?? 30
        let totalOps = warmup + iterations
        let convId = "g500997"
        let myUid = "2000997"
        let testEnk = Data("0123456789abcdef0123456789abcdef".utf8).base64EncodedString()
        let secretKey = ZaloCrypto.parseSecretKey(testEnk)

        // Build per-iteration alternating server responses:
        // Initial open board: empty. Then for each iteration:
        //   pin createv2 -> board list [t_i] -> unpinv2 -> board list []
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
                            "zpw_sek": .string("sek.bench.u7"),
                            "display_name": .string("Bench User U7"),
                            "send2me_id": .string("9200997"),
                            "zpw_ws": .array([.string("ws://fake")]),
                            "zpw_service_map_v3": .object([
                                "chat": .array([.string("http://fake")]),
                                "group": .array([.string("http://fake")]),
                                "group_board": .array([.string("http://fake")]),
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
                            "displayName": .string("Bench User U7"),
                        ]),
                    ]),
                ]),
            ]),
            // Initial empty board on open
            .object([
                "kind": .string("http"),
                "path": .string("/api/board/pin/list"),
                "method": .string("GET"),
                "response": .object([
                    "status": .int(200),
                    "json": .object([
                        "error_code": .int(0),
                        "data": .object([
                            "boardVersion": .int(1),
                            "pinLimit": .int(3),
                            "items": .array([]),
                        ]),
                    ]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/board/topic/createv2"),
                "method": .string("POST"),
                "repeat": .bool(true),
                "response": .object([
                    "status": .int(200),
                    "json": .object([
                        "error_code": .int(0),
                        "data": .object(["id": .string("t_bench")]),
                    ]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/board/unpinv2"),
                "method": .string("GET"),
                "repeat": .bool(true),
                "response": .object([
                    "status": .int(200),
                    "json": .object([
                        "error_code": .int(0),
                        "data": .object([:]),
                    ]),
                ]),
            ]),
        ]

        let targetId = "8900049"
        for i in 0..<totalOps {
            let vPin = Int64(i * 2 + 2)
            let vUnpin = Int64(i * 2 + 3)
            let topicRef = "t_bench_\(i)"
            serverScript.append(.object([
                "kind": .string("http"),
                "path": .string("/api/board/pin/list"),
                "method": .string("GET"),
                "response": .object([
                    "status": .int(200),
                    "json": .object([
                        "error_code": .int(0),
                        "data": .object([
                            "boardVersion": .int(vPin),
                            "pinLimit": .int(3),
                            "items": .array([
                                .object([
                                    "id": .string(topicRef),
                                    "type": .int(2),
                                    "params": .object([
                                        "title": .string("Bench message #49"),
                                        "senderName": .string("Bench User U7"),
                                        "global_msg_id": .string(targetId),
                                        "client_msg_id": .string("seed_49"),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ]))
            serverScript.append(.object([
                "kind": .string("http"),
                "path": .string("/api/board/pin/list"),
                "method": .string("GET"),
                "response": .object([
                    "status": .int(200),
                    "json": .object([
                        "error_code": .int(0),
                        "data": .object([
                            "boardVersion": .int(vUnpin),
                            "pinLimit": .int(3),
                            "items": .array([]),
                        ]),
                    ]),
                ]),
            ]))
        }

        let server = try FakeZaloServer(serverScript: serverScript, initialSecretKey: secretKey)
        try await server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-pin-bench-\(UUID().uuidString)", isDirectory: true)
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
                isGroup: true,
                name: "Bench Pin Group",
                avatar: "",
                pinned: false,
                members: 3,
                unread: 0,
                previewText: "Bench message #49",
                previewTsMs: baseMs + 49_000,
                previewFromMe: true,
                updatedAtMs: baseMs + 49_000
            ),
        ])
        var seedRows: [StoredMessage] = []
        seedRows.reserveCapacity(50)
        for i in 0..<50 {
            let tsMs = baseMs + Int64(i) * 1000
            let msg = ChatMessage(
                id: "\(8_900_000 + i)",
                conversationId: convId,
                senderId: myUid,
                senderName: "Bench User U7",
                senderAvatar: nil,
                isMine: true,
                kind: .text,
                text: "Bench message #\(i)",
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
            "group_board": [server.baseURLString],
            "profile": [server.baseURLString],
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
                    "group_board": .array([.string(server.baseURLString)]),
                    "profile": .array([.string(server.baseURLString)]),
                ]),
                "preferredHosts": .object([:]),
                "isolated": .bool(true),
            ]),
            "sealedSecretsBase64": .null,
            "expiredAt": .null,
            "plainAccount": .object([
                "userId": .string(myUid),
                "displayName": .string("Bench User U7"),
                "avatar": .string(""),
                "phone": .string(""),
                "send2MeId": .string("9200997"),
                "dkey": .string("dk-bench"),
                "zpwEnk": .string(testEnk),
                "zpwSek": .string("sek.bench.u7"),
            ]),
        ])
        try Data(savedSession.canonicalString().utf8)
            .write(to: root.appendingPathComponent("native-session.json"), options: .atomic)

        let storage = RecorderStorageIsolation(prefix: "olaz.pin-bench")
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
            name == "prepare_store" || name == "refresh_board_pins"
        }

        engine.start()
        _ = await engine.bootTask?.value
        #expect(engine.phase == .ready)
        engine.openConversation(convId)
        await engine.settleForRecording()
        let boardDeadline = ContinuousClock.now + .seconds(5)
        while engine.pins[convId]?.ready != true, ContinuousClock.now < boardDeadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect((engine.messages[convId]?.count ?? 0) == 50)
        #expect(engine.pins[convId]?.ready == true)
        #expect(engine.pins[convId]?.items.isEmpty == true)

        func waitForPinCount(_ targetCount: Int, deadline: ContinuousClock.Instant) async -> Bool {
            while (engine.pins[convId]?.items.count ?? -1) != targetCount {
                if ContinuousClock.now >= deadline { return false }
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    let pending = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: cont)
                    let resumeOnce: @Sendable () -> Void = {
                        pending.withLock { c in
                            let out = c
                            c = nil
                            return out
                        }?.resume()
                    }
                    let timeoutTask = Task {
                        try? await Task.sleep(for: .milliseconds(250))
                        resumeOnce()
                    }
                    let ready = withObservationTracking {
                        (engine.pins[convId]?.items.count ?? -1) == targetCount
                    } onChange: {
                        Task { @MainActor in
                            timeoutTask.cancel()
                            resumeOnce()
                        }
                    }
                    if ready {
                        timeoutTask.cancel()
                        resumeOnce()
                    }
                }
            }
            return true
        }

        let targetMsg = try #require(engine.messages[convId]?.last(where: { $0.id == targetId }))
        var pinSamplesMs: [Double] = []
        var unpinSamplesMs: [Double] = []
        pinSamplesMs.reserveCapacity(iterations)
        unpinSamplesMs.reserveCapacity(iterations)

        for i in 0..<totalOps {
            // 1. Measure pin-to-visible on MainActor
            let pinStart = ContinuousClock.now
            engine.pinMessage(targetMsg)
            let pinReached = await waitForPinCount(1, deadline: pinStart + .seconds(10))
            let pinElapsed = ContinuousClock.now - pinStart
            let pinMs = Double(pinElapsed.components.seconds) * 1000.0
                + Double(pinElapsed.components.attoseconds) / 1e15
            #expect(pinReached, "Timed out waiting for pin-to-visible at iteration \(i)")
            if i >= warmup {
                pinSamplesMs.append(pinMs)
            }
            await engine.awaitMessageActionTasksForRecording()
            await engine.settleForRecording()
            let pinnedItem = try #require(engine.pins[convId]?.items.first)

            // 2. Measure unpin-to-hidden on MainActor
            engine.requestUnpin(pinnedItem, in: convId)
            let confirm = try #require(engine.messageConfirm)
            let unpinStart = ContinuousClock.now
            engine.answerMessageConfirm(confirm, ok: true)
            let unpinReached = await waitForPinCount(0, deadline: unpinStart + .seconds(10))
            let unpinElapsed = ContinuousClock.now - unpinStart
            let unpinMs = Double(unpinElapsed.components.seconds) * 1000.0
                + Double(unpinElapsed.components.attoseconds) / 1e15
            #expect(unpinReached, "Timed out waiting for unpin-to-hidden at iteration \(i)")
            if i >= warmup {
                unpinSamplesMs.append(unpinMs)
            }
            await engine.awaitMessageActionTasksForRecording()
            await engine.settleForRecording()
        }

        func report(_ label: String, _ samples: [Double]) {
            let sorted = samples.sorted()
            let p50 = sorted[sorted.count / 2]
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            let minMs = sorted.first ?? 0
            let maxMs = sorted.last ?? 0
            print(String(
                format: "PERF %@ MainActor (n=%d): p50=%.3f ms  p95=%.3f ms  min=%.3f ms  max=%.3f ms",
                label, sorted.count, p50, p95, minMs, maxMs
            ))
        }

        report("pin-to-visible", pinSamplesMs)
        report("unpin-to-hidden", unpinSamplesMs)

        engine.cancelTasksForRecording()
        await engine.finishTearDownForRecording()
    }
}
