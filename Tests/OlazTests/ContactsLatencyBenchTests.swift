import Foundation
import OlazCore
import Testing
@testable import Olaz

/// U9 contacts & identity lookup latency benchmark:
/// - Syncs 2,000 friends (Vietnamese diacritic names, `globalId`s, `u`-prefixes) + 500 groups + friend requests
///   through `olaz-core` (`performContactsSync`) and measures end-to-end wall latency.
/// - Measures `@MainActor` latency of 1,000 `lookupPersonInfo` + 1,000 `mentionDisplayName` calls
///   resolved directly from the lazy O(1) mirror caches (zero per-row FFI hops) vs 1,000 direct FFI calls.
@Suite(.serialized) struct ContactsLatencyBenchTests {
    @MainActor
    @Test func contactsSyncAndLookupLatency() async throws {
        let friendCount = ProcessInfo.processInfo.environment["OLAZ_CONTACTS_BENCH_FRIENDS"].flatMap(Int.init) ?? 2_000
        let groupCount = ProcessInfo.processInfo.environment["OLAZ_CONTACTS_BENCH_GROUPS"].flatMap(Int.init) ?? 500
        let warmup = ProcessInfo.processInfo.environment["OLAZ_CONTACTS_BENCH_WARMUP"].flatMap(Int.init) ?? 1
        let iterations = ProcessInfo.processInfo.environment["OLAZ_CONTACTS_BENCH_ITERS"].flatMap(Int.init) ?? 5
        let myUid = "2000995"
        let testEnk = Data("0123456789abcdef0123456789abcdef".utf8).base64EncodedString()
        let secretKey = ZaloCrypto.parseSecretKey(testEnk)

        let familyNames = ["Nguyễn", "Trần", "Lê", "Phạm", "Hoàng", "Đặng", "Bùi", "Đỗ", "Hồ", "Ngô", "Dương", "Lý"]
        let middleNames = ["Văn", "Thị", "Minh", "Đức", "Ngọc", "Thanh", "Quốc", "Hữu", "Xuân", "Ánh"]
        let givenNames = ["Anh", "Bình", "Châu", "Dũng", "Đạt", "Giang", "Hà", "Khánh", "Linh", "Mai", "Nam", "Phúc", "Quân", "Tâm", "Uyên", "Vy"]

        var friendRows: [CaseJSON] = []
        friendRows.reserveCapacity(friendCount)
        for i in 0..<friendCount {
            let uidNum = 3_100_000 + i
            let rawUid = (i % 5 == 0) ? "u\(uidNum)" : "\(uidNum)"
            let fullName = "\(familyNames[i % familyNames.count]) \(middleNames[(i / 3) % middleNames.count]) \(givenNames[(i / 7) % givenNames.count]) \(i)"
            friendRows.append(.object([
                "userId": .string(rawUid),
                "zaloName": .string(fullName),
                "displayName": .string(""),
                "avatar": .string("https://cdn.example.invalid/u/\(uidNum).jpg"),
                "lastActionTime": .int(1_700_000_000_000 + Int64(i) * 1000),
                "isActivePC": .int((i % 4 == 0) ? 1 : 0),
                "globalId": .string("gid_\(uidNum)"),
            ]))
        }

        var verMap: [String: CaseJSON] = [:]
        var infoMap: [String: CaseJSON] = [:]
        verMap.reserveCapacity(groupCount)
        infoMap.reserveCapacity(groupCount)
        for g in 0..<groupCount {
            let gid = "\(5_100_000 + g)"
            verMap[gid] = .int(1)
            infoMap[gid] = .object([
                "name": .string("Nhóm Dự Án \(givenNames[g % givenNames.count]) #\(g)"),
                "avt": .string("https://cdn.example.invalid/g/\(gid).jpg"),
                "totalMember": .int(Int64(5 + (g % 80))),
            ])
        }

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
                            "zpw_sek": .string("sek.contacts.bench"),
                            "display_name": .string("Bench Self"),
                            "send2me_id": .string("9200995"),
                            "zpw_ws": .array([.string("ws://fake")]),
                            "zpw_service_map_v3": .object([
                                "chat": .array([.string("http://fake")]),
                                "friend": .array([.string("http://fake")]),
                                "group": .array([.string("http://fake")]),
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
                            "displayName": .string("Bench Self"),
                        ]),
                    ]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/social/friend/getfriends"),
                "repeat": .bool(true),
                "response": .object([
                    "status": .int(200),
                    "json": .object([
                        "error_code": .int(0),
                        "data": .object(["list": .array(friendRows)]),
                    ]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/group/getlg/v4"),
                "repeat": .bool(true),
                "response": .object([
                    "status": .int(200),
                    "json": .object([
                        "error_code": .int(0),
                        "data": .object(["gridVerMap": .object(verMap)]),
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
                        "data": .object(["gridInfoMap": .object(infoMap)]),
                    ]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/friend/requested/list"),
                "repeat": .bool(true),
                "response": .object([
                    "status": .int(200),
                    "json": .object([
                        "error_code": .int(0),
                        "data": .object(["list": .array([])]),
                    ]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/friend/recommendsv2/list"),
                "repeat": .bool(true),
                "response": .object([
                    "status": .int(200),
                    "json": .object([
                        "error_code": .int(0),
                        "data": .object(["recommItems": .array([])]),
                    ]),
                ]),
            ]),
        ]

        let server = try FakeZaloServer(serverScript: serverScript, initialSecretKey: secretKey)
        try await server.start()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-contacts-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let storage = RecorderStorageIsolation(prefix: "olaz.contacts-bench")
        defer {
            storage.cleanup()
            try? FileManager.default.removeItem(at: root)
        }

        let dbURL = root
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(myUid, isDirectory: true)
            .appendingPathComponent("history.sqlite3")
        let seedStore = try ZaloSQLiteStore(path: dbURL.path)
        try await seedStore.setPreferenceString(key: ZaloWebKitMigrator.donePrefKey, value: "1")
        await seedStore.close()

        var domains = ZaloDomains()
        domains.auth = server.baseURLString
        domains.wpaChat = server.baseURLString
        domains.lpChat = server.baseURLString
        domains.lpControl = server.baseURLString
        domains.ws = [server.wsBaseURLString]
        domains.serviceCandidates = [
            "chat": [server.baseURLString],
            "friend": [server.baseURLString],
            "group": [server.baseURLString],
            "profile": [server.baseURLString],
        ]
        domains.isolated = true

        let savedSession: CaseJSON = .object([
            "zpwType": .string(ZaloDomains.zpwType),
            "imei": .string("00000000-0000-4000-8000-000000000000-00000000000000000000000000000000"),
            "computerName": .string("ContactsBenchMac"),
            "domains": .object([
                "auth": .string(server.baseURLString),
                "wpaChat": .string(server.baseURLString),
                "lpChat": .string(server.baseURLString),
                "lpControl": .string(server.baseURLString),
                "ws": .array([.string(server.wsBaseURLString)]),
                "serviceCandidates": .object([
                    "chat": .array([.string(server.baseURLString)]),
                    "friend": .array([.string(server.baseURLString)]),
                    "group": .array([.string(server.baseURLString)]),
                    "profile": .array([.string(server.baseURLString)]),
                ]),
                "preferredHosts": .object([:]),
                "isolated": .bool(true),
            ]),
            "sealedSecretsBase64": .null,
            "expiredAt": .null,
            "plainAccount": .object([
                "userId": .string(myUid),
                "displayName": .string("Bench Self"),
                "avatar": .string(""),
                "phone": .string(""),
                "send2MeId": .string("9200995"),
                "dkey": .string("dk-cbench"),
                "zpwEnk": .string(testEnk),
                "zpwSek": .string("sek.contacts.bench"),
            ]),
        ])
        try Data(savedSession.canonicalString().utf8)
            .write(to: root.appendingPathComponent("native-session.json"), options: .atomic)

        let engine = ZaloEngine(
            dataDirectory: root,
            useKeychain: false,
            domains: domains,
            userDefaultsSuiteName: storage.userDefaultsSuiteName,
            cookieStorage: storage.cookieStorage
        )
        engine.hostTrace = { name, _ in
            name == "prepare_store"
        }

        engine.start()
        _ = await engine.bootTask?.value
        #expect(engine.phase == .ready)

        func toMs(_ d: Duration) -> Double {
            Double(d.components.seconds) * 1000.0 + Double(d.components.attoseconds) / 1e15
        }

        func summarize(_ label: String, _ samples: [Double]) -> (p50: Double, p95: Double) {
            let sorted = samples.sorted()
            let p50 = sorted[sorted.count / 2]
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            let minMs = sorted.first ?? 0
            let maxMs = sorted.last ?? 0
            print(String(
                format: "PERF %@ (friends=%d, groups=%d, n=%d): p50=%.3f ms  p95=%.3f ms  min=%.3f ms  max=%.3f ms",
                label, friendCount, groupCount, samples.count, p50, p95, minMs, maxMs
            ))
            return (p50, p95)
        }

        // 1. Measure performContactsSync (2,000 friends + 500 groups)
        var syncSamples: [Double] = []
        syncSamples.reserveCapacity(iterations)
        for i in 0..<(warmup + iterations) {
            let start = ContinuousClock.now
            await engine.performContactsSync()
            let elapsed = toMs(ContinuousClock.now - start)
            #expect(engine.contacts.friends.count == friendCount)
            #expect(engine.contacts.groups.count == groupCount)
            if i >= warmup {
                syncSamples.append(elapsed)
            }
        }
        _ = summarize("performContactsSync", syncSamples)

        // 2. Build 1,000 mixed lookup queries (direct UID, u-prefixed UID, globalId, unknown)
        var queries: [String] = []
        queries.reserveCapacity(1_000)
        for q in 0..<1_000 {
            let idx = (q * 7) % max(1, friendCount)
            let uidNum = 3_100_000 + idx
            switch q % 4 {
            case 0: queries.append("\(uidNum)")
            case 1: queries.append("u\(uidNum)")
            case 2: queries.append("gid_\(uidNum)")
            default: queries.append("9999\(q)")
            }
        }

        // Prime lazy dictionary build once, then measure steady-state 1,000 lookups + 1,000 mentions on MainActor.
        _ = engine.lookupPersonInfo(queries[0])
        var localLookupSamples: [Double] = []
        var localMentionSamples: [Double] = []
        var ffiLookupSamples: [Double] = []
        let core = try #require(engine.coreLifecycle.core)

        for i in 0..<(warmup + iterations) {
            let t0 = ContinuousClock.now
            var hitCount = 0
            for q in queries {
                if engine.lookupPersonInfo(q) != nil { hitCount += 1 }
            }
            let localMs = toMs(ContinuousClock.now - t0)
            #expect(hitCount == 750)

            let t1 = ContinuousClock.now
            var mentionHits = 0
            for q in queries {
                if engine.mentionDisplayName(q) != nil { mentionHits += 1 }
            }
            let mentionMs = toMs(ContinuousClock.now - t1)
            #expect(mentionHits == 750)

            let t2 = ContinuousClock.now
            var ffiHits = 0
            for q in queries {
                if core.lookupPersonInfo(uid: q) != nil { ffiHits += 1 }
            }
            let ffiMs = toMs(ContinuousClock.now - t2)
            #expect(ffiHits == 750)

            if i >= warmup {
                localLookupSamples.append(localMs)
                localMentionSamples.append(mentionMs)
                ffiLookupSamples.append(ffiMs)
            }
        }

        let lookupStats = summarize("localMirrorLookupPersonInfo_x1000", localLookupSamples)
        let mentionStats = summarize("localMirrorMentionDisplayName_x1000", localMentionSamples)
        _ = summarize("coreFfiLookupPersonInfo_x1000", ffiLookupSamples)

        // Generous ceiling so debug CI never flakes while verifying O(1) dictionary speed.
        #expect(lookupStats.p50 < 25.0)
        #expect(mentionStats.p50 < 25.0)

        engine.cancelTasksForRecording()
        server.stop()
        await engine.finishTearDownForRecording()
    }
}
