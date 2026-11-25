import Foundation
import Observation
import os
import Testing
@testable import Olaz

/// U6 release benchmark: measures MainActor optimistic latency for:
/// 1. `react`: time from calling `ZaloEngine.performReact` until the reaction toggle is visible in `engine.messages[convId]`.
/// 2. `delete`: time from calling `ZaloEngine.deleteForMe(..., confirmed: true)` until the row is hidden from `engine.messages[convId]` and `engine.deleteUndo != nil`.
/// Run in release mode for real numbers:
///   `swift test -c release --filter MessageActionLatencyBench`
@Suite(.serialized) struct MessageActionLatencyBenchTests {
    @MainActor
    @Test func reactAndDeleteMainActorLatency() async throws {
        let warmup = ProcessInfo.processInfo.environment["OLAZ_BENCH_WARMUP"].flatMap(Int.init) ?? 5
        let iterations = ProcessInfo.processInfo.environment["OLAZ_BENCH_ITERS"].flatMap(Int.init) ?? 30
        let totalOps = warmup + iterations
        let convId = "3000998"
        let myUid = "2000998"
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
                            "zpw_sek": .string("sek.bench.u6"),
                            "display_name": .string("Bench User U6"),
                            "send2me_id": .string("9200998"),
                            "zpw_ws": .array([.string("ws://fake")]),
                            "zpw_service_map_v3": .object([
                                "chat": .array([.string("http://fake")]),
                                "group": .array([.string("http://fake")]),
                                "profile": .array([.string("http://fake")]),
                                "reaction": .array([.string("http://fake")]),
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
                            "displayName": .string("Bench User U6"),
                        ]),
                    ]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/message/reaction"),
                "method": .string("POST"),
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

        let server = try FakeZaloServer(serverScript: serverScript, initialSecretKey: secretKey)
        try await server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-action-bench-\(UUID().uuidString)", isDirectory: true)
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
                id: "\(8_100_000 + i)",
                conversationId: convId,
                senderId: isMine ? myUid : convId,
                senderName: isMine ? "Bench User U6" : "Bench Peer",
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
            "reaction": [server.baseURLString],
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
                    "reaction": .array([.string(server.baseURLString)]),
                ]),
                "preferredHosts": .object([:]),
                "isolated": .bool(true),
            ]),
            "sealedSecretsBase64": .null,
            "expiredAt": .null,
            "plainAccount": .object([
                "userId": .string(myUid),
                "displayName": .string("Bench User U6"),
                "avatar": .string(""),
                "phone": .string(""),
                "send2MeId": .string("9200998"),
                "dkey": .string("dk-bench"),
                "zpwEnk": .string(testEnk),
                "zpwSek": .string("sek.bench.u6"),
            ]),
        ])
        try Data(savedSession.canonicalString().utf8)
            .write(to: root.appendingPathComponent("native-session.json"), options: .atomic)

        let storage = RecorderStorageIsolation(prefix: "olaz.action-bench")
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

        let targetId = "\(8_100_049)"

        // 1. React MainActor optimistic latency (toggle ❤️ on/off each iteration).
        func waitForReactMine(expected: Bool) async {
            while (engine.messages[convId]?.last(where: { $0.id == targetId })?.reactions.contains(where: \.includesMe) ?? false) != expected {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    let pending = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: cont)
                    let current = withObservationTracking {
                        engine.messages[convId]?.last(where: { $0.id == targetId })?.reactions.contains(where: \.includesMe) ?? false
                    } onChange: {
                        Task { @MainActor in
                            pending.withLock { c in
                                let out = c
                                c = nil
                                return out
                            }?.resume()
                        }
                    }
                    if current == expected {
                        pending.withLock { c in
                            let out = c
                            c = nil
                            return out
                        }?.resume()
                    }
                }
            }
        }

        var reactSamplesMs: [Double] = []
        reactSamplesMs.reserveCapacity(iterations)
        for i in 0..<totalOps {
            let wantMine = (i % 2 == 0)
            let start = ContinuousClock.now
            let task = Task { @MainActor in
                await engine.performReact("❤️", to: targetId, in: convId)
            }
            await waitForReactMine(expected: wantMine)
            let elapsed = ContinuousClock.now - start
            let ms = Double(elapsed.components.seconds) * 1000.0
                + Double(elapsed.components.attoseconds) / 1e15
            await task.value
            if i >= warmup {
                reactSamplesMs.append(ms)
            }
        }

        // 2. Delete-for-me MainActor optimistic latency (delete confirmed -> undo to restore 50 rows).
        func waitForDeleteVisible(targetCount: Int) async {
            while (engine.messages[convId]?.count ?? 0) != targetCount || engine.deleteUndo == nil {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    let pending = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: cont)
                    let ready = withObservationTracking {
                        (engine.messages[convId]?.count ?? 0) == targetCount && engine.deleteUndo != nil
                    } onChange: {
                        Task { @MainActor in
                            pending.withLock { c in
                                let out = c
                                c = nil
                                return out
                            }?.resume()
                        }
                    }
                    if ready {
                        pending.withLock { c in
                            let out = c
                            c = nil
                            return out
                        }?.resume()
                    }
                }
            }
        }

        var deleteSamplesMs: [Double] = []
        deleteSamplesMs.reserveCapacity(iterations)
        for i in 0..<totalOps {
            guard let msg = engine.messages[convId]?.last(where: { $0.id == targetId }) else {
                Issue.record("Missing target message at iteration \(i)")
                break
            }
            let start = ContinuousClock.now
            engine.deleteForMe(msg, confirmed: true)
            await waitForDeleteVisible(targetCount: 49)
            let elapsed = ContinuousClock.now - start
            let ms = Double(elapsed.components.seconds) * 1000.0
                + Double(elapsed.components.attoseconds) / 1e15
            if i >= warmup {
                deleteSamplesMs.append(ms)
            }
            engine.undoDelete()
            await engine.settleForRecording()
            #expect((engine.messages[convId]?.count ?? 0) == 50)
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

        report("react-to-visible", reactSamplesMs)
        report("delete-to-hidden", deleteSamplesMs)

        // 3. Burst of 200 remote reaction events in a row (direct + live batch).
        let burstCount = ProcessInfo.processInfo.environment["OLAZ_BENCH_BURST"].flatMap(Int.init) ?? 200
        let burstStartDirect = ContinuousClock.now
        for i in 0..<burstCount {
            let msgIdx = i % 50
            let msgId = "\(8_100_000 + msgIdx)"
            let rType = (i % 2 == 0) ? "5" : "3"
            let rIcon = (i % 2 == 0) ? "/-heart" : "/-strong"
            await engine.applyRemoteReaction(
                convId: convId,
                msgId: msgId,
                cliMsgId: "seed_\(msgIdx)",
                senderId: convId,
                rType: rType,
                rIcon: rIcon,
                eventId: "burst_direct_\(i)",
                reactClientId: "rcli_d_\(i)",
                senderName: "Bench Peer"
            )
        }
        let directElapsed = ContinuousClock.now - burstStartDirect
        let directTotalMs = Double(directElapsed.components.seconds) * 1000.0
            + Double(directElapsed.components.attoseconds) / 1e15
        print(String(
            format: "PERF remote-react-burst-direct (n=%d): total=%.2f ms  avg=%.3f ms/ev",
            burstCount, directTotalMs, directTotalMs / Double(max(1, burstCount))
        ))

        var batchEvents: [ParsedWireEvent] = []
        batchEvents.reserveCapacity(burstCount)
        for i in 0..<burstCount {
            let msgIdx = i % 50
            let msgId = "\(8_100_000 + msgIdx)"
            let rType = (i % 2 == 0) ? "5" : "3"
            let rIcon = (i % 2 == 0) ? "/-heart" : "/-strong"
            batchEvents.append(.reaction(
                convId: convId,
                msgId: msgId,
                cliMsgId: "seed_\(msgIdx)",
                senderId: convId,
                rType: rType,
                rIcon: rIcon,
                eventId: "burst_batch_\(i)",
                reactClientId: "rcli_b_\(i)",
                tsMs: baseMs + 100_000 + Int64(i),
                seqId: Int64(i + 1),
                senderName: "Bench Peer"
            ))
        }
        let burstStartBatch = ContinuousClock.now
        _ = await engine.applyParsedEvents(batchEvents)
        let batchElapsed = ContinuousClock.now - burstStartBatch
        let batchTotalMs = Double(batchElapsed.components.seconds) * 1000.0
            + Double(batchElapsed.components.attoseconds) / 1e15
        print(String(
            format: "PERF remote-react-burst-batch (n=%d): total=%.2f ms  avg=%.3f ms/ev",
            burstCount, batchTotalMs, batchTotalMs / Double(max(1, burstCount))
        ))

        engine.cancelTasksForRecording()
        await engine.finishTearDownForRecording()
    }
}
