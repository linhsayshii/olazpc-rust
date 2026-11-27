import Foundation
import OlazCore
import Testing
@testable import Olaz

@Suite struct CoreSessionMirrorTests {
    @Test @MainActor func applyAccountProfileRoundTripsThroughCoreEngineMirror() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-core-mirror-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = ZaloEngine(dataDirectory: dir, useKeychain: false)
        defer { engine.stopCoreEngine() }

        #expect(engine.phase == .starting)
        #expect(engine.profile == nil)

        await engine.applyAccountProfile(ZaloLoginAccount(
            userId: "u42",
            displayName: "",
            avatar: "",
            phone: "",
            send2MeId: ""
        ))

        #expect(engine.profile?.userId == "u42")
        #expect(engine.profile?.displayName == "Người dùng Zalo")
        #expect(engine.profile?.avatar == nil)
        #expect(engine.profile?.phone == nil)
        #expect(engine.selfConversationId == "u42")
        #expect(engine.clientVersion == "695 (Native)")

        await engine.applyAccountProfile(ZaloLoginAccount(
            userId: "u42",
            displayName: "Minh Anh",
            avatar: "https://cdn.example.test/avt.jpg",
            phone: "+84901234567",
            send2MeId: "s2m-42"
        ))

        #expect(engine.profile?.displayName == "Minh Anh")
        #expect(engine.profile?.avatar == URL(string: "https://cdn.example.test/avt.jpg"))
        #expect(engine.profile?.phone == "+84901234567")
        #expect(engine.selfConversationId == "s2m-42")
    }

    @Test func renderFailReasonMatchesRustCoreMapError() {
        #expect(
            ZaloEngine.renderFailReason(.text(message: "Đăng nhập đã bị từ chối trên điện thoại."))
                == "Đăng nhập đã bị từ chối trên điện thoại."
        )
        #expect(
            ZaloEngine.renderFailReason(.core(kind: .network(kind: .other)))
                == RustCore.mapError(CoreError.Network(kind: .other, message: "")).localizedDescription
        )
        #expect(
            ZaloEngine.renderFailReason(.core(kind: .session(
                code: -1,
                message: "Không tạo được mã QR",
                url: "/api/login/reqqr"
            ))) == "Zalo error -1: Không tạo được mã QR (/api/login/reqqr)"
        )
        #expect(
            ZaloEngine.renderFailReason(.core(kind: .http(status: 502)))
                == "Lỗi máy chủ HTTP 502."
        )
    }

    @Test @MainActor func nextChangesDeliveryLatencyMeasurement() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-core-latency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = ZaloEngine(dataDirectory: dir, useKeychain: false)
        defer { engine.stopCoreEngine() }

        // Warm up CoreEngine creation and the first next_changes() poll.
        await engine.applyAccountProfile(ZaloLoginAccount(userId: "warmup", displayName: "Warmup"))
        #expect(engine.profile?.userId == "warmup")

        let iterations = 100
        let clock = ContinuousClock()
        var samplesUs: [Double] = []
        samplesUs.reserveCapacity(iterations)

        for i in 0..<iterations {
            let start = clock.now
            await engine.applyAccountProfile(ZaloLoginAccount(
                userId: "bench-\(i)",
                displayName: "User \(i)"
            ))
            let elapsed = start.duration(to: clock.now)
            let secs = Double(elapsed.components.seconds)
            let attos = Double(elapsed.components.attoseconds) / 1e18
            samplesUs.append((secs + attos) * 1_000_000.0)
        }

        #expect(engine.profile?.userId == "bench-\(iterations - 1)")
        let sorted = samplesUs.sorted()
        let minUs = sorted.first ?? 0
        let p50Us = sorted[sorted.count / 2]
        let p95Us = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let maxUs = sorted.last ?? 0
        print(String(
            format: "PERF next_changes delivery (n=%d): min=%.1f us p50=%.1f us p95=%.1f us max=%.1f us",
            iterations, minUs, p50Us, p95Us, maxUs
        ))
        // Generous sanity cap so debug builds never flake while catching real stalls.
        #expect(p50Us < 50_000.0)
    }

    @Test @MainActor func phaseGateTasksCompleteAcrossStartLogOutRefreshExpiryAndTeardown() async throws {
        let testEnk = Data("0123456789abcdef0123456789abcdef".utf8).base64EncodedString()
        let serverScript: [CaseJSON] = [
            // 1. Saved-session boot -> ready
            .object([
                "kind": .string("http"),
                "path": .string("/api/login/getLoginInfo"),
                "response": .object([
                    "status": .int(200),
                    "json": .object([
                        "error_code": .int(0),
                        "data": .object([
                            "uid": .string("9001"),
                            "zpw_enk": .string(testEnk),
                            "zpw_sek": .string("sek.boot.9001"),
                            "display_name": .string("Gate User"),
                            "send2me_id": .string("9001"),
                            "zpw_ws": .array([.string("ws://fake")]),
                            "zpw_service_map_v3": .object([
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
                            "userId": .string("9001"),
                            "displayName": .string("Gate User"),
                        ]),
                    ]),
                ]),
            ]),
            // 2. Log out -> QR waitingScan (stalled waitScan1, later replaced by refreshQR)
            .object([
                "kind": .string("http"),
                "path": .string("/api/login/getServerInfo"),
                "response": .object([
                    "status": .int(200),
                    "json": .object(["error_code": .int(0), "data": .object([:])]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/login/reqqr"),
                "response": .object([
                    "status": .int(200),
                    "json": .object([
                        "error_code": .int(0),
                        "data": .object([
                            "token_id": .string("tok-logout"),
                            "qr_cnt": .string("https://zalo.me/qr/gate-logout"),
                            "chk_wait_scan": .string("http://fake/api/login/waitScan1"),
                            "chk_wait_cfirm": .string("http://fake/api/login/waitCfirm"),
                            "qr_timeout": .int(180),
                            "qr_retry": .int(1),
                        ]),
                    ]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/login/waitScan1"),
                "response": .object(["error": .string("timeout")]),
            ]),
            // 3. Refresh QR -> server error -> terminal .failed
            .object([
                "kind": .string("http"),
                "path": .string("/api/login/getServerInfo"),
                "response": .object([
                    "status": .int(200),
                    "json": .object(["error_code": .int(0), "data": .object([:])]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/login/reqqr"),
                "response": .object([
                    "status": .int(200),
                    "json": .object([
                        "error_code": .int(-2),
                        "error_message": .string("Máy chủ bận."),
                    ]),
                ]),
            ]),
            // 4. Session expired -> QR waitingScan (stalled waitScan2, then stopped)
            .object([
                "kind": .string("http"),
                "path": .string("/api/login/getServerInfo"),
                "response": .object([
                    "status": .int(200),
                    "json": .object(["error_code": .int(0), "data": .object([:])]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/login/reqqr"),
                "response": .object([
                    "status": .int(200),
                    "json": .object([
                        "error_code": .int(0),
                        "data": .object([
                            "token_id": .string("tok-expired"),
                            "qr_cnt": .string("https://zalo.me/qr/gate-expired"),
                            "chk_wait_scan": .string("http://fake/api/login/waitScan2"),
                            "chk_wait_cfirm": .string("http://fake/api/login/waitCfirm"),
                            "qr_timeout": .int(180),
                            "qr_retry": .int(1),
                        ]),
                    ]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/login/waitScan2"),
                "response": .object(["error": .string("timeout")]),
            ]),
        ]

        let secretKey = ZaloCrypto.parseSecretKey(testEnk)
        let server = try FakeZaloServer(serverScript: serverScript, initialSecretKey: secretKey)
        try await server.start()
        defer { server.stop() }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-core-gates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var isolatedDomains = ZaloDomains()
        isolatedDomains.auth = server.baseURLString
        isolatedDomains.wpaChat = server.baseURLString
        isolatedDomains.ws = [server.wsBaseURLString]
        isolatedDomains.serviceCandidates = ["profile": [server.baseURLString]]
        isolatedDomains.isolated = true

        let savedSession: CaseJSON = .object([
            "zpwType": .string(ZaloDomains.zpwType),
            "imei": .string("00000000-0000-4000-8000-000000000000-00000000000000000000000000000000"),
            "computerName": .string("TestMac"),
            "domains": .object([
                "auth": .string(server.baseURLString),
                "wpaChat": .string(server.baseURLString),
                "lpChat": .string(server.baseURLString),
                "lpControl": .string(server.baseURLString),
                "ws": .array([.string(server.wsBaseURLString)]),
                "serviceCandidates": .object([
                    "profile": .array([.string(server.baseURLString)]),
                ]),
                "preferredHosts": .object([:]),
                "isolated": .bool(true),
            ]),
            "sealedSecretsBase64": .null,
            "expiredAt": .null,
            "plainAccount": .object([
                "userId": .string("9001"),
                "displayName": .string("Gate User"),
                "avatar": .string(""),
                "phone": .string(""),
                "send2MeId": .string("9001"),
                "dkey": .string("dk-9001"),
                "zpwEnk": .string(testEnk),
                "zpwSek": .string("sek.boot.9001"),
            ]),
        ])
        let sessionURL = dir.appendingPathComponent("native-session.json")
        try Data(savedSession.canonicalString().utf8).write(to: sessionURL)

        let storage = RecorderStorageIsolation(prefix: "olaz.core-mirror")
        defer { storage.cleanup() }
        let engine = ZaloEngine(
            dataDirectory: dir,
            useKeychain: false,
            domains: isolatedDomains,
            userDefaultsSuiteName: storage.userDefaultsSuiteName,
            cookieStorage: storage.cookieStorage
        )
        // Stub out side-effecting host hooks (SQLite/WS/bootstrap) to keep the test isolated and fast.
        engine.hostTrace = { _, _ in false }

        // 1. Start -> saved session boot reaches .ready and finishes bootTask.
        engine.start()
        let bootTask = try #require(engine.bootTask)
        try await awaitTaskWithinTimeout(bootTask, label: "bootTask")
        #expect(engine.phase == .ready)

        // 2. Log out -> cleanupTask finishes via resetDomains; qrTask starts waitingScan.
        engine.logOut()
        let logOutCleanupTask = try #require(engine.pendingCleanupTask)
        let logOutQrTask = try #require(engine.qrTask)
        try await awaitTaskWithinTimeout(logOutCleanupTask, label: "logOutCleanupTask")
        try await waitForPhase(engine, timeoutMs: 30_000) {
            if case .login(let l) = $0, case .waitingScan = l.step { return true }
            return false
        }

        // 3. Refresh QR replaces logOutQrTask (which must complete) and new qrTask completes on .failed.
        engine.refreshQR()
        let refreshQrTask = try #require(engine.qrTask)
        try await awaitTaskWithinTimeout(logOutQrTask, label: "replaced logOutQrTask")
        try await awaitTaskWithinTimeout(refreshQrTask, label: "failed refreshQrTask")
        if case .login(let login) = engine.phase, case .failed = login.step {
            // expected terminal .failed
        } else {
            Issue.record("expected .login(.failed) after refreshQR error, got \(engine.phase)")
        }

        // 4. Session expired -> cleanupTask finishes via markExpired; stop() finishes waiting qrTask.
        engine.handleSessionExpiredNotice("Phiên hết hạn.")
        let expiredCleanupTask = try #require(engine.pendingCleanupTask)
        let expiredQrTask = try #require(engine.qrTask)
        try await awaitTaskWithinTimeout(expiredCleanupTask, label: "expiredCleanupTask")
        try await waitForPhase(engine, timeoutMs: 30_000) {
            if case .login(let l) = $0, case .waitingScan = l.step { return true }
            return false
        }

        engine.stopCoreEngine()
        try await awaitTaskWithinTimeout(expiredQrTask, label: "expiredQrTask on stop()")

        // 5. Engine deinit without stopCoreEngine() must also finish any armed gate task.
        let deinitServer = try FakeZaloServer(serverScript: [
            .object([
                "kind": .string("http"),
                "path": .string("/api/login/getServerInfo"),
                "response": .object([
                    "status": .int(200),
                    "json": .object(["error_code": .int(0), "data": .object([:])]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/login/reqqr"),
                "response": .object([
                    "status": .int(200),
                    "json": .object([
                        "error_code": .int(0),
                        "data": .object([
                            "token_id": .string("tok-deinit"),
                            "qr_cnt": .string("https://zalo.me/qr/gate-deinit"),
                            "chk_wait_scan": .string("http://fake/api/login/waitScanDeinit"),
                            "chk_wait_cfirm": .string("http://fake/api/login/waitCfirm"),
                            "qr_timeout": .int(180),
                            "qr_retry": .int(1),
                        ]),
                    ]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/login/waitScanDeinit"),
                "response": .object(["error": .string("timeout")]),
            ]),
        ])
        try await deinitServer.start()
        defer { deinitServer.stop() }

        let deinitDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-core-deinit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: deinitDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: deinitDir) }

        var deinitDomains = ZaloDomains()
        deinitDomains.auth = deinitServer.baseURLString
        deinitDomains.wpaChat = deinitServer.baseURLString
        deinitDomains.ws = [deinitServer.wsBaseURLString]
        deinitDomains.isolated = true

        var deinitBootTask: Task<Void, Never>?
        var deinitQrTask: Task<Void, Never>?
        do {
            let deinitStorage = RecorderStorageIsolation(prefix: "olaz.core-deinit")
            defer { deinitStorage.cleanup() }
            let ephemeral = ZaloEngine(
                dataDirectory: deinitDir,
                useKeychain: false,
                domains: deinitDomains,
                userDefaultsSuiteName: deinitStorage.userDefaultsSuiteName,
                cookieStorage: deinitStorage.cookieStorage
            )
            ephemeral.hostTrace = { _, _ in false }
            ephemeral.start()
            deinitBootTask = ephemeral.bootTask
            try await waitForPhase(ephemeral, timeoutMs: 30_000) {
                if case .login(let l) = $0, case .waitingScan = l.step { return true }
                return false
            }
            deinitQrTask = ephemeral.qrTask
        }
        // `ephemeral` is now deallocated; deinit must have finished both boot and QR gate tasks.
        try await awaitTaskWithinTimeout(try #require(deinitBootTask), label: "deinitBootTask")
        try await awaitTaskWithinTimeout(try #require(deinitQrTask), label: "deinitQrTask")
    }

    @MainActor
    private func awaitTaskWithinTimeout(_ task: Task<Void, Never>, label: String, timeoutMs: Int = 30_000) async throws {
        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await task.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(timeoutMs))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(completed, "Gate task '\(label)' did not complete within \(timeoutMs)ms")
    }

    @MainActor
    private func waitForPhase(
        _ engine: ZaloEngine,
        timeoutMs: Int,
        predicate: (ZaloEngine.Phase) -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while !predicate(engine.phase) {
            if ContinuousClock.now >= deadline {
                Issue.record("Timed out waiting for phase; current: \(engine.phase)")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
