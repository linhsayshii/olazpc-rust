import Foundation
import Testing
@testable import Olaz

@Suite(.serialized)
struct TransportRecorderTests {
    @Test
    @MainActor
    func transportCases() async throws {
        let isRecord = ProcessInfo.processInfo.environment["OLAZ_RECORD"] == "1"
        let runSlow = isRecord || ProcessInfo.processInfo.environment["OLAZ_SLOW_CASES"] == "1"
        let casesURL = CaseFile.casesURL(domain: "transport")

        if isRecord {
            var recorded: [CaseJSON] = []
            for scenario in Self.scenarios() {
                let startClock = ContinuousClock.now
                let caseJSON = try await Self.recordScenario(scenario)
                let elapsed = ContinuousClock.now - startClock
                print("recorded \(scenario.name) in \(elapsed)")
                recorded.append(caseJSON)
            }
            try CaseFile.write(recorded, to: casesURL)
        } else {
            let committed = try CaseFile.load(url: casesURL)
            #expect(!committed.isEmpty, "No committed cases found at \(casesURL.path)")

            let byName = Dictionary(uniqueKeysWithValues: committed.compactMap { item -> (String, CaseJSON)? in
                guard let name = item["name"]?.stringValue else { return nil }
                return (name, item)
            })
            let expectedScenarios = Self.scenarios()
            #expect(committed.count == expectedScenarios.count, "Committed case count \(committed.count) != scenario count \(expectedScenarios.count)")

            for scenario in expectedScenarios {
                let expected = try #require(byName[scenario.name], "Missing committed case for \(scenario.name)")
                if scenario.slow && !runSlow {
                    print("skipped slow: \(scenario.name)")
                    continue
                }
                let actual = try await Self.recordScenario(scenario)
                if let diff = CaseJSON.firstDiff(expected: expected, actual: actual) {
                    Issue.record("\(scenario.name): \(diff)")
                }
            }
        }
    }

    // MARK: - Scenario Runner

    struct ScenarioDef {
        let name: String
        let slow: Bool
        let seed: CaseJSON
        let server: [CaseJSON]
        let steps: [CaseJSON]

        init(
            name: String,
            slow: Bool = false,
            seed: CaseJSON,
            server: [CaseJSON],
            steps: [CaseJSON]
        ) {
            self.name = name
            self.slow = slow
            self.seed = seed
            self.server = server
            self.steps = steps
        }
    }

    enum RecorderError: Error, CustomStringConvertible {
        case timeout(scenario: String, detail: String)
        case unscriptedRequest(scenario: String)
        case invalidStep(scenario: String, detail: String)
        case hostNotIsolated(scenario: String, detail: String)

        var description: String {
            switch self {
            case .timeout(let scenario, let detail):
                return "\(scenario): RecorderError.timeout: \(detail)"
            case .unscriptedRequest(let scenario):
                return "\(scenario): RecorderError.unscriptedRequest"
            case .invalidStep(let scenario, let detail):
                return "\(scenario): RecorderError.invalidStep: \(detail)"
            case .hostNotIsolated(let scenario, let detail):
                return "\(scenario): RecorderError.hostNotIsolated: \(detail)"
            }
        }
    }

    @MainActor
    static func recordScenario(_ scenario: ScenarioDef) async throws -> CaseJSON {
        try await RecorderSuiteLock.shared.withLock {
            try await recordScenarioLocked(scenario)
        }
    }

    @MainActor
    private static func recordScenarioLocked(_ scenario: ScenarioDef) async throws -> CaseJSON {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-transport-recorder-\(scenario.name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let storage = RecorderStorageIsolation(prefix: "olaz.transport-recorder")

        defer {
            storage.cleanup()
            try? FileManager.default.removeItem(at: dataDir)
        }

        let initialSecretKey = extractInitialSecretKey(from: scenario.seed)
        let server = try FakeZaloServer(serverScript: scenario.server, initialSecretKey: initialSecretKey)
        try await server.start()

        let baseURL = server.baseURLString
        let wsURL = server.wsBaseURLString

        func substituteRuntimeURLs(_ json: CaseJSON) -> CaseJSON {
            json
                .replacingString("http://fake", with: baseURL)
                .replacingString("ws://fake", with: wsURL)
        }

        func normalizeRecordedURLs(_ json: CaseJSON) -> CaseJSON {
            json
                .replacingString(baseURL, with: "http://fake")
                .replacingString(wsURL, with: "ws://fake")
        }

        // Seed saved_session file if provided.
        if let savedSession = scenario.seed["saved_session"], savedSession != .null {
            let sub = substituteRuntimeURLs(savedSession)
            let fileURL = dataDir.appendingPathComponent("native-session.json")
            try Data(sub.canonicalString().utf8).write(to: fileURL, options: .atomic)
        }

        // Seed legacy_cookie if provided.
        if let cookieSeed = scenario.seed["legacy_cookie"], cookieSeed != .null {
            if let sek = cookieSeed["zpw_sek"]?.stringValue,
               let cookieURL = URL(string: baseURL),
               let cookie = HTTPCookie(properties: [
                   .domain: cookieURL.host ?? "127.0.0.1",
                   .path: "/",
                   .name: "zpw_sek",
                   .value: sek,
                   .originURL: cookieURL,
               ]) {
                storage.cookieStorage.setCookie(cookie)
            }
            if let imei = cookieSeed["imei"]?.stringValue {
                storage.userDefaults.set(imei, forKey: "olaz.imei")
            }
        }

        // Decode seed.domains and enforce local-only fake hosts + isolated=true.
        let domainsJSON = substituteRuntimeURLs(scenario.seed["domains"] ?? defaultFakeDomainsJSON())
        let domainsData = Data(domainsJSON.canonicalString().utf8)
        let domains = try JSONDecoder().decode(ZaloDomains.self, from: domainsData)
        try assertOnlyLocalFakeHosts(domains, scenario: scenario.name, stage: "initial seed")

        let engine = ZaloEngine(
            dataDirectory: dataDir,
            useKeychain: false,
            domains: domains,
            userDefaultsSuiteName: storage.userDefaultsSuiteName,
            cookieStorage: storage.cookieStorage
        )
        if let prefsObj = scenario.seed["prefs"]?.objectValue {
            for (k, v) in prefsObj {
                if let s = v.stringValue {
                    engine.recordedSessionPrefs[k] = s
                }
            }
        }
        if let pollSeed = scenario.seed["poll_state"], pollSeed != .null {
            let decoded = try JSONDecoder().decode(ZaloPollState.self, from: Data(pollSeed.canonicalString().utf8))
            engine.pollState = decoded
        }
        if let cursorsSeed = scenario.seed["ws_cursors"], cursorsSeed != .null {
            let decoded = try JSONDecoder().decode([String: ZaloWSQueueCursorSnapshot].self, from: Data(cursorsSeed.canonicalString().utf8))
            await engine.webSocket.seedQueueCursors(decoded)
        }

        let suppressedTransports = Set(
            scenario.seed["suppress"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )

        var hostCalls: [CaseJSON] = []
        var hostCursor = 0
        var hostWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        func notifyHostSignal() {
            let pending = hostWaiters
            hostWaiters.removeAll()
            for cont in pending.values {
                cont.resume()
            }
        }

        engine.hostTrace = { name, args in
            let normalizedArgs = normalizeRecordedURLs(CaseJSON.fromAny(args))
            hostCalls.append(.object([
                "call": .string(name),
                "args": normalizedArgs,
            ]))
            notifyHostSignal()
            switch name {
            case "start_ws":
                return !suppressedTransports.contains("ws")
            case "start_long_poll":
                return !suppressedTransports.contains("long_poll")
            default:
                return false
            }
        }

        let transitionRecorder = TransportTransitionRecorder(scenarioName: scenario.name) {
            normalizeRecordedURLs(SessionSnapshot.capture(from: engine))
        }
        engine.stateTrace = { [weak transitionRecorder] in
            transitionRecorder?.recordTransition()
        }

        var snapshots: [String: CaseJSON] = [:]

        do {
            for step in scenario.steps {
                if let cmd = step["cmd"]?.stringValue {
                    switch cmd {
                    case "start":
                        engine.start()
                        transitionRecorder.advanceSearchToLatestSyncState()
                    case "refresh_qr":
                        engine.refreshQR()
                        transitionRecorder.advanceSearchToLatestSyncState()
                    case "log_out":
                        _ = await engine.bootTask?.value
                        engine.logOut()
                        transitionRecorder.advanceSearchToLatestSyncState()
                    case "session_expired":
                        _ = await engine.bootTask?.value
                        let reason = step["args"]?["reason"]?.stringValue ?? ""
                        engine.handleSessionExpiredNotice(reason)
                        transitionRecorder.advanceSearchToLatestSyncState()
                    case "drain_chat_polling":
                        _ = await engine.bootTask?.value
                        let maxBatches = Int(step["args"]?["max_batches"]?.int64Value ?? 3)
                        let notifyIncoming = step["args"]?["notify_incoming"]?.boolValue ?? false
                        _ = await engine.drainChatPolling(maxBatches: maxBatches, notifyIncoming: notifyIncoming)
                    default:
                        throw RecorderError.invalidStep(scenario: scenario.name, detail: "Unknown cmd: \(cmd)")
                    }
                } else if let pred = step["await"] {
                    let timeoutMs = Int(step["timeout_ms"]?.int64Value ?? 5000)
                    try await transitionRecorder.awaitPredicate(pred, timeoutMs: timeoutMs)
                } else if let targetCall = step["await_host"]?.stringValue {
                    let timeoutMs = Int(step["timeout_ms"]?.int64Value ?? 5000)
                    let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
                    while true {
                        if let matchIdx = (hostCursor..<hostCalls.count).first(where: {
                            hostCalls[$0]["call"]?.stringValue == targetCall
                        }) {
                            hostCursor = matchIdx + 1
                            break
                        }
                        let remaining = deadline - ContinuousClock.now
                        if remaining <= .zero {
                            let recorded = hostCalls.compactMap { $0["call"]?.stringValue }
                            throw RecorderError.timeout(
                                scenario: scenario.name,
                                detail: "timed out awaiting host call '\(targetCall)' from cursor \(hostCursor), hostCalls=\(recorded)"
                            )
                        }
                        let waiterId = UUID()
                        let timeoutTask = Task { @MainActor in
                            try? await Task.sleep(for: remaining)
                            if let cont = hostWaiters.removeValue(forKey: waiterId) {
                                cont.resume()
                            }
                        }
                        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                            hostWaiters[waiterId] = cont
                        }
                        timeoutTask.cancel()
                    }
                } else if let pushCount = step["ws_push"]?.int64Value {
                    let timeoutMs = Int(step["timeout_ms"]?.int64Value ?? 5000)
                    do {
                        try await server.pushWebSocketActions(count: Int(pushCount), timeoutMs: timeoutMs)
                    } catch {
                        throw RecorderError.timeout(scenario: scenario.name, detail: "\(error)")
                    }
                } else if let label = step["snapshot"]?.stringValue {
                    await engine.settleForRecording()
                    snapshots[label] = transitionRecorder.currentCursorSnapshot()
                } else {
                    throw RecorderError.invalidStep(scenario: scenario.name, detail: "Unknown step: \(step.canonicalString())")
                }
            }

            _ = await engine.bootTask?.value
            _ = await engine.pendingCleanupTask?.value
            await server.waitForScriptedRequests(timeoutMs: 2000)
            if !suppressedTransports.contains("ws") {
                try? await Task.sleep(for: .milliseconds(50))
            }
            await engine.settleForRecording()
            await Task.yield()

            try assertOnlyLocalFakeHosts(await engine.sessionClient.domains, scenario: scenario.name, stage: "final")

            let finalState = normalizeRecordedURLs(SessionSnapshot.capture(from: engine))
            let requests = server.canonicalRequests().map { normalizeRecordedURLs($0) }

            engine.cancelTasksForRecording()
            engine.transportSettleTrace = nil
            server.stop()
            await engine.finishTearDownForRecording()

            if server.hadUnscriptedRequest {
                throw RecorderError.unscriptedRequest(scenario: scenario.name)
            }

            var caseDict: [String: CaseJSON] = [
                "format": .int(1),
                "domain": .string("transport"),
                "name": .string(scenario.name),
                "seed": scenario.seed,
                "server": .array(scenario.server),
                "steps": .array(scenario.steps),
                "expect": .object([
                    "snapshots": .object(snapshots),
                    "final": finalState,
                    "requests": .array(requests),
                    "host": .array(hostCalls),
                ]),
            ]
            if scenario.slow {
                caseDict["slow"] = .bool(true)
            }
            return .object(caseDict)
        } catch {
            transitionRecorder.cancelWaiters()
            let pending = hostWaiters
            hostWaiters.removeAll()
            for cont in pending.values { cont.resume() }
            engine.cancelTasksForRecording()
            engine.transportSettleTrace = nil
            server.stop()
            await engine.finishTearDownForRecording()
            throw error
        }
    }

    private static func assertOnlyLocalFakeHosts(_ domains: ZaloDomains, scenario: String, stage: String) throws {
        guard domains.isolated else {
            throw RecorderError.hostNotIsolated(scenario: scenario, detail: "\(stage): ZaloDomains.isolated must be true")
        }
        var allHosts: [String] = [domains.auth, domains.wpaChat, domains.lpChat, domains.lpControl]
        allHosts.append(contentsOf: domains.ws)
        allHosts.append(contentsOf: domains.serviceCandidates.values.flatMap { $0 })
        allHosts.append(contentsOf: domains.preferredHosts.values)

        let allowedHosts: Set<String> = ["127.0.0.1", "localhost", "fake"]
        for raw in allHosts where !raw.isEmpty {
            let norm = ZaloDomains.normalizeHost(raw)
            guard let host = URL(string: norm)?.host?.lowercased(), allowedHosts.contains(host) else {
                throw RecorderError.hostNotIsolated(scenario: scenario, detail: "\(stage): non-fake host detected '\(raw)'")
            }
        }
    }

    private static func extractInitialSecretKey(from seed: CaseJSON) -> Data? {
        guard let enk = seed["saved_session"]?["plainAccount"]?["zpwEnk"]?.stringValue, !enk.isEmpty else {
            return nil
        }
        let parsed = ZaloCrypto.parseSecretKey(enk)
        return (parsed.count == 16 || parsed.count == 32) ? parsed : nil
    }

    // MARK: - Helpers & Scenarios

    private static func syntheticIMEI() -> String {
        "00000000-0000-4000-8000-000000000001-\(ZaloCrypto.md5Hex(ZaloDomains.userAgent))"
    }

    private static func defaultFakeDomainsJSON() -> CaseJSON {
        var candidates: [String: CaseJSON] = [:]
        for key in ZaloDomains.defaultServiceMapV3.keys {
            candidates[key] = .array([.string("http://fake")])
        }
        return .object([
            "auth": .string("http://fake"),
            "wpaChat": .string("http://fake"),
            "lpChat": .string("http://fake"),
            "lpControl": .string("http://fake"),
            "ws": .array([.string("ws://fake")]),
            "serviceCandidates": .object(candidates),
            "preferredHosts": .object([:]),
            "isolated": .bool(true),
        ])
    }

    private static func defaultPollState() -> CaseJSON {
        .object([
            "lastActionId": .string("10"),
            "lastActionIdOther": .string("20"),
            "queues": .object([
                "1": .object(["lastId": .string("100"), "ids": .array([])]),
                "2": .object(["lastId": .string("1"), "ids": .array([])]),
                "3": .object(["lastId": .string("1"), "ids": .array([])]),
            ]),
        ])
    }

    private static func readySessionSeed(
        userId: String,
        displayName: String = "Transport User",
        avatar: String = "https://cdn.example.invalid/transport.jpg",
        phone: String = "+84900000100",
        send2MeId: String? = nil,
        zpwEnk: String = "0123456789abcdef",
        zpwSek: String = "saved.200.a0.sek_t1",
        pollState: CaseJSON? = nil,
        wsCursors: CaseJSON? = nil,
        suppress: [String] = [],
        prefs: [String: String] = [:]
    ) -> CaseJSON {
        let acct: [String: CaseJSON] = [
            "userId": .string(userId),
            "displayName": .string(displayName),
            "avatar": .string(avatar),
            "phone": .string(phone),
            "send2MeId": .string(send2MeId ?? userId),
            "dkey": .string("dkey_\(userId)"),
            "zpwEnk": .string(zpwEnk),
            "zpwSek": .string(zpwSek),
            "needSyncMsg": .bool(false),
        ]
        let saved: CaseJSON = .object([
            "zpwType": .string("23"),
            "imei": .string(syntheticIMEI()),
            "computerName": .string("TestMac"),
            "domains": defaultFakeDomainsJSON(),
            "sealedSecretsBase64": .null,
            "plainAccount": .object(acct),
            "expiredAt": .null,
        ])
        var seedDict: [String: CaseJSON] = [
            "saved_session": saved,
            "domains": defaultFakeDomainsJSON(),
            "legacy_cookie": .null,
            "prefs": .object(prefs.mapValues(CaseJSON.string)),
        ]
        if !suppress.isEmpty {
            seedDict["suppress"] = .array(suppress.map(CaseJSON.string))
        }
        if let pollState {
            seedDict["poll_state"] = pollState
        }
        if let wsCursors {
            seedDict["ws_cursors"] = wsCursors
        }
        return .object(seedDict)
    }

    private static func httpScript(
        path: String,
        method: String = "GET",
        status: Int64 = 200,
        json: CaseJSON? = nil,
        error: String? = nil
    ) -> CaseJSON {
        var resp: [String: CaseJSON] = [:]
        if let error {
            resp["error"] = .string(error)
        } else {
            resp["status"] = .int(status)
            if let json {
                resp["json"] = json
            }
        }
        return .object([
            "kind": .string("http"),
            "path": .string(path),
            "method": .string(method),
            "response": .object(resp),
        ])
    }

    private static func wsScript(path: String = "/", accept: Bool = true) -> CaseJSON {
        .object([
            "kind": .string("ws"),
            "path": .string(path),
            "accept": .bool(accept),
        ])
    }

    private static func wsFrameScript(
        cmd: Int64,
        subCmd: Int64 = 0,
        payload: CaseJSON,
        encrypt: Int64? = nil,
        delayMs: Int64? = nil
    ) -> CaseJSON {
        var obj: [String: CaseJSON] = [
            "kind": .string("ws_frame"),
            "cmd": .int(cmd),
            "sub_cmd": .int(subCmd),
            "payload": payload,
        ]
        if let encrypt {
            obj["encrypt"] = .int(encrypt)
        }
        if let delayMs {
            obj["delay_ms"] = .int(delayMs)
        }
        return .object(obj)
    }

    private static func wsCloseScript(delayMs: Int64? = nil) -> CaseJSON {
        var obj: [String: CaseJSON] = [
            "kind": .string("ws_close"),
        ]
        if let delayMs {
            obj["delay_ms"] = .int(delayMs)
        }
        return .object(obj)
    }

    private static func qrFallbackScripts(tokenId: String) -> [CaseJSON] {
        [
            httpScript(
                path: "/api/login/getServerInfo",
                json: .object(["error_code": .int(0), "data": .object([:])])
            ),
            httpScript(
                path: "/api/login/reqqr",
                json: .object([
                    "error_code": .int(0),
                    "data": .object([
                        "token_id": .string(tokenId),
                        "qr_cnt": .string("https://zalo.me/qr/\(tokenId)"),
                        "chk_wait_scan": .string("http://fake/api/login/waitScan"),
                        "chk_wait_cfirm": .string("http://fake/api/login/waitCfirm"),
                        "qr_timeout": .int(60),
                        "qr_retry": .int(1),
                    ]),
                ])
            ),
            httpScript(path: "/api/login/waitScan", error: "timeout"),
        ]
    }

    private static func loginInfoScript(
        uid: String,
        zpwSek: String,
        displayName: String = "Transport User"
    ) -> CaseJSON {
        httpScript(
            path: "/api/login/getLoginInfo",
            json: .object([
                "error_code": .int(0),
                "data": .object([
                    "uid": .string(uid),
                    "dkey": .string("dkey_\(uid)"),
                    "zpw_enk": .string("0123456789abcdef"),
                    "zpw_sek": .string(zpwSek),
                    "display_name": .string(displayName),
                    "send2me_id": .string(uid),
                    "need_sync_msg": .bool(false),
                    "zpw_service_map_v3": .object([
                        "profile": .array([.string("http://fake")]),
                    ]),
                    "zpw_ws": .array([.string("ws://fake")]),
                ]),
            ])
        )
    }

    private static func profileMeScript(
        uid: String,
        displayName: String = "Transport User",
        avatar: String = "https://cdn.example.invalid/transport.jpg",
        phone: String = "+84900000100"
    ) -> CaseJSON {
        httpScript(
            path: "/api/social/profile/me-v2",
            json: .object([
                "error_code": .int(0),
                "data": .object([
                    "profile": .object([
                        "userId": .string(uid),
                        "displayName": .string(displayName),
                        "avatar": .string(avatar),
                        "phoneNumber": .string(phone),
                    ]),
                ]),
            ])
        )
    }

    private static func standardWSStartSteps() -> [CaseJSON] {
        [
            .object(["cmd": .string("start")]),
            .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
            .object(["await_host": .string("e2ee_connected"), "timeout_ms": .int(5000)]),
        ]
    }

    static func scenarios() -> [ScenarioDef] {
        [
            // 1. ws_starts_after_ready
            ScenarioDef(
                name: "ws_starts_after_ready",
                seed: readySessionSeed(
                    userId: "2000001",
                    displayName: "WS User 1",
                    zpwSek: "saved.200.a0.sek_ws1",
                    suppress: ["long_poll"]
                ),
                server: [
                    loginInfoScript(uid: "2000001", zpwSek: "saved.200.a0.sek_ws1", displayName: "WS User 1"),
                    profileMeScript(uid: "2000001", displayName: "WS User 1"),
                    wsScript(),
                    wsFrameScript(cmd: 1, payload: .object(["error_code": .int(0)])),
                ],
                steps: standardWSStartSteps()
            ),

            // 2. ws_kicked_600
            ScenarioDef(
                name: "ws_kicked_600",
                seed: readySessionSeed(
                    userId: "2000002",
                    displayName: "WS User 2",
                    zpwSek: "saved.200.a0.sek_ws2",
                    suppress: ["long_poll"]
                ),
                server: [
                    loginInfoScript(uid: "2000002", zpwSek: "saved.200.a0.sek_ws2", displayName: "WS User 2"),
                    profileMeScript(uid: "2000002", displayName: "WS User 2"),
                    wsScript(),
                    wsFrameScript(cmd: 1, payload: .object(["error_code": .int(0)])),
                    wsFrameScript(cmd: 501, payload: .object(["error_code": .int(600), "data": .object([:])])),
                ] + qrFallbackScripts(tokenId: "tok_ws_600"),
                steps: standardWSStartSteps() + [
                    .object(["ws_push": .int(1)]),
                    .object(["await": .object(["phase": .string("login"), "step": .string("waiting_scan")]), "timeout_ms": .int(5000)]),
                ]
            ),

            // 3. ws_kicked_minus_102
            ScenarioDef(
                name: "ws_kicked_minus_102",
                seed: readySessionSeed(
                    userId: "2000003",
                    displayName: "WS User 3",
                    zpwSek: "saved.200.a0.sek_ws3",
                    suppress: ["long_poll"]
                ),
                server: [
                    loginInfoScript(uid: "2000003", zpwSek: "saved.200.a0.sek_ws3", displayName: "WS User 3"),
                    profileMeScript(uid: "2000003", displayName: "WS User 3"),
                    wsScript(),
                    wsFrameScript(cmd: 1, payload: .object(["error_code": .int(0)])),
                    wsFrameScript(cmd: 501, payload: .object(["error_code": .int(-102), "data": .object([:])])),
                ] + qrFallbackScripts(tokenId: "tok_ws_m102"),
                steps: standardWSStartSteps() + [
                    .object(["ws_push": .int(1)]),
                    .object(["await": .object(["phase": .string("login"), "step": .string("waiting_scan")]), "timeout_ms": .int(5000)]),
                ]
            ),

            // 4. ws_authen_ignored
            ScenarioDef(
                name: "ws_authen_ignored",
                seed: readySessionSeed(
                    userId: "2000004",
                    displayName: "WS User 4",
                    zpwSek: "saved.200.a0.sek_ws4",
                    suppress: ["long_poll"]
                ),
                server: [
                    loginInfoScript(uid: "2000004", zpwSek: "saved.200.a0.sek_ws4", displayName: "WS User 4"),
                    profileMeScript(uid: "2000004", displayName: "WS User 4"),
                    wsScript(),
                    wsFrameScript(cmd: 1, payload: .object(["error_code": .int(0)])),
                    wsFrameScript(cmd: 1, payload: .object(["error_code": .int(0), "data": .object(["extra": .string("ignored")])])),
                ],
                steps: standardWSStartSteps() + [
                    .object(["ws_push": .int(1)]),
                ]
            ),

            // 5. ws_e2ee_signal
            ScenarioDef(
                name: "ws_e2ee_signal",
                seed: readySessionSeed(
                    userId: "2000005",
                    displayName: "WS User 5",
                    zpwSek: "saved.200.a0.sek_ws5",
                    suppress: ["long_poll"]
                ),
                server: [
                    loginInfoScript(uid: "2000005", zpwSek: "saved.200.a0.sek_ws5", displayName: "WS User 5"),
                    profileMeScript(uid: "2000005", displayName: "WS User 5"),
                    wsScript(),
                    wsFrameScript(cmd: 1, payload: .object(["error_code": .int(0)])),
                    wsFrameScript(cmd: 543, payload: .object(["error_code": .int(0), "data": .object(["uid": .string("3000051")])])),
                    wsFrameScript(cmd: 516, payload: .object(["error_code": .int(0), "data": .object(["uid": .string("3000052")])])),
                    wsFrameScript(cmd: 549, payload: .object(["error_code": .int(0), "data": .object(["uid": .string("3000053")])])),
                ],
                steps: standardWSStartSteps() + [
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("e2ee_signal"), "timeout_ms": .int(5000)]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("e2ee_signal"), "timeout_ms": .int(5000)]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("e2ee_signal"), "timeout_ms": .int(5000)]),
                ]
            ),

            // 6. ws_deliver_reports
            ScenarioDef(
                name: "ws_deliver_reports",
                seed: readySessionSeed(
                    userId: "2000006",
                    displayName: "WS User 6",
                    zpwSek: "saved.200.a0.sek_ws6",
                    suppress: ["long_poll"]
                ),
                server: [
                    loginInfoScript(uid: "2000006", zpwSek: "saved.200.a0.sek_ws6", displayName: "WS User 6"),
                    profileMeScript(uid: "2000006", displayName: "WS User 6"),
                    wsScript(),
                    wsFrameScript(cmd: 1, payload: .object(["error_code": .int(0)])),
                    wsFrameScript(cmd: 553, payload: .object([
                        "error_code": .int(0),
                        "data": .object([
                            "deliver": .array([
                                .object(["msgId": .string("m601"), "uid": .string("3000061")]),
                            ]),
                        ]),
                    ])),
                ],
                steps: standardWSStartSteps() + [
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("e2ee_deliver_reports"), "timeout_ms": .int(5000)]),
                ]
            ),

            // 7. ws_sync_ack
            ScenarioDef(
                name: "ws_sync_ack",
                seed: readySessionSeed(
                    userId: "2000007",
                    displayName: "WS User 7",
                    zpwSek: "saved.200.a0.sek_ws7",
                    suppress: ["long_poll"]
                ),
                server: [
                    loginInfoScript(uid: "2000007", zpwSek: "saved.200.a0.sek_ws7", displayName: "WS User 7"),
                    profileMeScript(uid: "2000007", displayName: "WS User 7"),
                    wsScript(),
                    wsFrameScript(cmd: 1, payload: .object(["error_code": .int(0)])),
                    wsFrameScript(cmd: 590, payload: .object([
                        "error_code": .int(0),
                        "data": .object([
                            "controls": .array([
                                .object([
                                    "act_type": .string("typing"),
                                    "act": .string("typing"),
                                    "data": .object(["uid": .string("3000070")]),
                                ]),
                            ]),
                        ]),
                    ])),
                    wsFrameScript(cmd: 592, payload: .object([
                        "error_code": .int(100),
                        "data": .object([
                            "msgs": .array([
                                .object(["msgId": .string("702"), "uidFrom": .string("3000070"), "content": .string("sync wake")]),
                            ]),
                        ]),
                    ])),
                ],
                steps: standardWSStartSteps() + [
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("show_typing"), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("apply_batch"), "timeout_ms": .int(5000)]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("apply_batch"), "timeout_ms": .int(5000)]),
                ]
            ),

            // 8. ws_mobile_sync
            ScenarioDef(
                name: "ws_mobile_sync",
                seed: readySessionSeed(
                    userId: "2000008",
                    displayName: "WS User 8",
                    zpwSek: "saved.200.a0.sek_ws8",
                    suppress: ["long_poll"]
                ),
                server: [
                    loginInfoScript(uid: "2000008", zpwSek: "saved.200.a0.sek_ws8", displayName: "WS User 8"),
                    profileMeScript(uid: "2000008", displayName: "WS User 8"),
                    wsScript(),
                    wsFrameScript(cmd: 1, payload: .object(["error_code": .int(0)])),
                    wsFrameScript(cmd: 501, payload: .object([
                        "error_code": .int(0),
                        "data": .object([
                            "controls": .array([
                                .object([
                                    "act_type": .string("transfer_msg"),
                                    "act": .string("transfer_after_login"),
                                    "data": .object(["temp_key": .string("tk_ws_8")]),
                                ]),
                                .object([
                                    "act_type": .string("typing"),
                                    "act": .string("typing"),
                                    "data": .object(["uid": .string("3000080")]),
                                ]),
                            ]),
                            "msgs": .array([]),
                        ]),
                    ])),
                ],
                steps: standardWSStartSteps() + [
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("mobile_sync"), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("show_typing"), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("apply_batch"), "timeout_ms": .int(5000)]),
                ]
            ),

            // 9. ws_typing
            ScenarioDef(
                name: "ws_typing",
                seed: readySessionSeed(
                    userId: "2000009",
                    displayName: "WS User 9",
                    zpwSek: "saved.200.a0.sek_ws9",
                    suppress: ["long_poll"]
                ),
                server: [
                    loginInfoScript(uid: "2000009", zpwSek: "saved.200.a0.sek_ws9", displayName: "WS User 9"),
                    profileMeScript(uid: "2000009", displayName: "WS User 9"),
                    wsScript(),
                    wsFrameScript(cmd: 1, payload: .object(["error_code": .int(0)])),
                    wsFrameScript(cmd: 601, payload: .object([
                        "error_code": .int(0),
                        "data": .object([
                            "controls": .array([
                                .object(["act_type": .string("typing"), "act": .string("typing"), "data": .object(["uid": .string("u3000091"), "isPC": .int(1)])]),
                                .object(["act_type": .string("typing"), "act": .string("gtyping"), "data": .object(["uid": .string("3000092"), "gid": .string("990092")])]),
                                .object(["act_type": .string("typing"), "act": .string("gtyping"), "data": .object(["uid": .string("3000093")])]),
                                .object(["act_type": .string("typing"), "act": .string("typing"), "data": .object(["uid": .string("2000009"), "isPC": .int(1)])]),
                            ]),
                        ]),
                    ])),
                ],
                steps: standardWSStartSteps() + [
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("apply_batch"), "timeout_ms": .int(5000)]),
                ]
            ),

            // 10. ws_voip
            ScenarioDef(
                name: "ws_voip",
                seed: readySessionSeed(
                    userId: "2000010",
                    displayName: "WS User 10",
                    zpwSek: "saved.200.a0.sek_ws10",
                    suppress: ["long_poll"]
                ),
                server: [
                    loginInfoScript(uid: "2000010", zpwSek: "saved.200.a0.sek_ws10", displayName: "WS User 10"),
                    profileMeScript(uid: "2000010", displayName: "WS User 10"),
                    wsScript(),
                    wsFrameScript(cmd: 1, payload: .object(["error_code": .int(0)])),
                    wsFrameScript(cmd: 601, payload: .object([
                        "error_code": .int(0),
                        "data": .object([
                            "controls": .array([
                                .object([
                                    "act_type": .string("voip"),
                                    "act": .string("cancel"),
                                    "data": .object(["callId": .string("c101"), "uid": .string("3000101")]),
                                ]),
                            ]),
                        ]),
                    ])),
                    wsFrameScript(cmd: 604, payload: .object([
                        "error_code": .int(0),
                        "data": .object([
                            "act": .string("reject"),
                            "callId": .string("c102"),
                            "uid": .string("3000102"),
                        ]),
                    ])),
                ],
                steps: standardWSStartSteps() + [
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("voip_control"), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("apply_batch"), "timeout_ms": .int(5000)]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("voip_control"), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("apply_batch"), "timeout_ms": .int(5000)]),
                ]
            ),

            // 11. ws_pin_topic
            ScenarioDef(
                name: "ws_pin_topic",
                seed: readySessionSeed(
                    userId: "2000011",
                    displayName: "WS User 11",
                    zpwSek: "saved.200.a0.sek_ws11",
                    suppress: ["long_poll"]
                ),
                server: [
                    loginInfoScript(uid: "2000011", zpwSek: "saved.200.a0.sek_ws11", displayName: "WS User 11"),
                    profileMeScript(uid: "2000011", displayName: "WS User 11"),
                    wsScript(),
                    wsFrameScript(cmd: 1, payload: .object(["error_code": .int(0)])),
                    wsFrameScript(cmd: 601, payload: .object([
                        "error_code": .int(0),
                        "data": .object([
                            "controls": .array([
                                .object([
                                    "act_type": .string("fr"),
                                    "act": .string("pin_force_sync"),
                                    "data": .object([
                                        "conversationIds": .array([.string("u3000111"), .string("u3000112")]),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ])),
                ],
                steps: standardWSStartSteps() + [
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("apply_batch"), "timeout_ms": .int(5000)]),
                ]
            ),

            // 12. ws_group_notice
            ScenarioDef(
                name: "ws_group_notice",
                seed: readySessionSeed(
                    userId: "2000012",
                    displayName: "WS User 12",
                    zpwSek: "saved.200.a0.sek_ws12",
                    suppress: ["long_poll"]
                ),
                server: [
                    loginInfoScript(uid: "2000012", zpwSek: "saved.200.a0.sek_ws12", displayName: "WS User 12"),
                    profileMeScript(uid: "2000012", displayName: "WS User 12"),
                    wsScript(),
                    wsFrameScript(cmd: 1, payload: .object(["error_code": .int(0)])),
                    wsFrameScript(cmd: 601, payload: .object([
                        "error_code": .int(0),
                        "data": .object([
                            "controls": .array([
                                .object([
                                    "act_type": .string("group"),
                                    "act": .string("join"),
                                    "ts": .int(1700000001000),
                                    "data": .object(["groupId": .string("880121"), "sourceId": .string("3000121")]),
                                ]),
                                .object([
                                    "act_type": .string("group"),
                                    "act": .string("update"),
                                    "data": .object([
                                        "groupId": .string("880122"),
                                        "sourceId": .string("3000122"),
                                        "groupName": .string("Renamed Group"),
                                        "ts": .int(1700000002000),
                                    ]),
                                ]),
                                .object([
                                    "act_type": .string("group"),
                                    "act": .string("unknown_notice"),
                                    "ts": .int(1700000003000),
                                    "data": .object(["groupId": .string("880123")]),
                                ]),
                            ]),
                        ]),
                    ])),
                ],
                steps: standardWSStartSteps() + [
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("apply_batch"), "timeout_ms": .int(5000)]),
                ]
            ),

            // 13. ws_mute
            ScenarioDef(
                name: "ws_mute",
                seed: readySessionSeed(
                    userId: "2000013",
                    displayName: "WS User 13",
                    zpwSek: "saved.200.a0.sek_ws13",
                    suppress: ["long_poll"]
                ),
                server: [
                    loginInfoScript(uid: "2000013", zpwSek: "saved.200.a0.sek_ws13", displayName: "WS User 13"),
                    profileMeScript(uid: "2000013", displayName: "WS User 13"),
                    wsScript(),
                    wsFrameScript(cmd: 1, payload: .object(["error_code": .int(0)])),
                    wsFrameScript(cmd: 601, payload: .object([
                        "error_code": .int(0),
                        "data": .object([
                            "controls": .array([
                                .object([
                                    "act_type": .string("mute"),
                                    "act": .string("set"),
                                    "data": .object([
                                        "toId": .string("u3000131"),
                                        "muteType": .int(1),
                                        "duration": .int(3600),
                                        "muteMode": .int(1),
                                        "startTime": .int(1700000100),
                                    ]),
                                ]),
                                .object([
                                    "act_type": .string("mute"),
                                    "act": .string("unset"),
                                    "data": .object([
                                        "toid": .string("3000132"),
                                        "muteType": .int(1),
                                        "duration": .int(-1),
                                        "systemTime": .int(1700000200),
                                    ]),
                                ]),
                                .object([
                                    "act_type": .string("mute"),
                                    "act": .string("set"),
                                    "data": .object([
                                        "toId": .string("3000133"),
                                        "muteType": .int(1),
                                        "duration": .int(3600),
                                        "muteMode": .int(2),
                                    ]),
                                ]),
                                .object([
                                    "act_type": .string("mute"),
                                    "act": .string("set"),
                                    "data": .object([
                                        "id": .string("880134"),
                                        "muteType": .int(2),
                                        "duration": .int(0),
                                        "muteMode": .int(1),
                                        "startTime": .int(1700000300),
                                    ]),
                                ]),
                                .object([
                                    "act_type": .string("mute"),
                                    "act": .string(""),
                                    "data": .object([
                                        "toId": .string("g880135"),
                                        "muteType": .int(1),
                                        "action": .int(1),
                                        "duration": .int(7200),
                                        "startTime": .int(1700000400),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ])),
                ],
                steps: standardWSStartSteps() + [
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("apply_batch"), "timeout_ms": .int(5000)]),
                ]
            ),

            // 14. ws_controls_shapes
            ScenarioDef(
                name: "ws_controls_shapes",
                seed: readySessionSeed(
                    userId: "2000014",
                    displayName: "WS User 14",
                    zpwSek: "saved.200.a0.sek_ws14",
                    suppress: ["long_poll"]
                ),
                server: [
                    loginInfoScript(uid: "2000014", zpwSek: "saved.200.a0.sek_ws14", displayName: "WS User 14"),
                    profileMeScript(uid: "2000014", displayName: "WS User 14"),
                    wsScript(),
                    wsFrameScript(cmd: 1, payload: .object(["error_code": .int(0)])),
                    wsFrameScript(cmd: 601, payload: .object([
                        "error_code": .int(0),
                        "data": .object([
                            "controls": .array([
                                .object([
                                    "content": .string(#"{"act_type":"typing","act":"typing","data":"\"uid\":\"3000141\",\"isPC\":1"}"#),
                                ]),
                            ]),
                            "actions": .array([
                                .object([
                                    "act_type": .string("mute"),
                                    "act": .string("set"),
                                    "data": .object([
                                        "toId": .string("3000142"),
                                        "duration": .int(60),
                                        "startTime": .int(1700000500),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ])),
                    wsFrameScript(cmd: 601, payload: .object([
                        "error_code": .int(0),
                        "data": .array([
                            .object([
                                "controls": .array([
                                    .object([
                                        "act_type": .string("typing"),
                                        "act": .string("typing"),
                                        "data": .object(["uid": .string("3000143")]),
                                    ]),
                                ]),
                            ]),
                            .object([
                                "act_type": .string("group"),
                                "act": .string("new_pin_topic"),
                                "data": .object(["groupId": .string("880144")]),
                            ]),
                        ]),
                    ])),
                ],
                steps: standardWSStartSteps() + [
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("apply_batch"), "timeout_ms": .int(5000)]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("apply_batch"), "timeout_ms": .int(5000)]),
                ]
            ),

            // 15. ws_live_vs_pull
            ScenarioDef(
                name: "ws_live_vs_pull",
                seed: readySessionSeed(
                    userId: "2000015",
                    displayName: "WS User 15",
                    zpwSek: "saved.200.a0.sek_ws15",
                    suppress: ["long_poll"]
                ),
                server: [
                    loginInfoScript(uid: "2000015", zpwSek: "saved.200.a0.sek_ws15", displayName: "WS User 15"),
                    profileMeScript(uid: "2000015", displayName: "WS User 15"),
                    wsScript(),
                    wsFrameScript(cmd: 1, payload: .object(["error_code": .int(0)])),
                    wsFrameScript(cmd: 501, payload: .object(["error_code": .int(0), "data": .object(["controls": .array([]), "msgs": .array([])])])),
                    wsFrameScript(cmd: 521, payload: .object(["error_code": .int(0), "data": .object(["controls": .array([]), "groupMsgs": .array([])])])),
                    wsFrameScript(cmd: 510, payload: .object(["error_code": .int(0), "data": .object(["controls": .array([]), "msgs": .array([])])])),
                    wsFrameScript(cmd: 511, payload: .object(["error_code": .int(0), "data": .object(["controls": .array([]), "groupMsgs": .array([])])])),
                    wsFrameScript(cmd: 532, payload: .object(["error_code": .int(0), "data": .object(["msgs": .array([])])])),
                ],
                steps: standardWSStartSteps() + [
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("apply_batch"), "timeout_ms": .int(5000)]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("apply_batch"), "timeout_ms": .int(5000)]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("apply_batch"), "timeout_ms": .int(5000)]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("apply_batch"), "timeout_ms": .int(5000)]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("apply_batch"), "timeout_ms": .int(5000)]),
                ]
            ),

            // 16. ws_typed_chat
            ScenarioDef(
                name: "ws_typed_chat",
                seed: readySessionSeed(
                    userId: "2000016",
                    displayName: "WS User 16",
                    zpwSek: "saved.200.a0.sek_ws16",
                    suppress: ["long_poll"]
                ),
                server: [
                    loginInfoScript(uid: "2000016", zpwSek: "saved.200.a0.sek_ws16", displayName: "WS User 16"),
                    profileMeScript(uid: "2000016", displayName: "WS User 16"),
                    wsScript(),
                    wsFrameScript(cmd: 1, payload: .object(["error_code": .int(0)])),
                    wsFrameScript(cmd: 501, payload: .object([
                        "error_code": .int(0),
                        "data": .object([
                            "msgs": .array([
                                .object([
                                    "msgId": .string("1601"),
                                    "cliMsgId": .string("1601"),
                                    "uidFrom": .string("3000160"),
                                    "idTo": .string("2000016"),
                                    "dName": .string("Peer Alice"),
                                    "msgType": .string("webchat"),
                                    "ts": .int(1700001601000),
                                    "content": .string("hello typed"),
                                ]),
                                .object([
                                    "msgId": .string("1602"),
                                    "cliMsgId": .string("1602"),
                                    "uidFrom": .string("2000016"),
                                    "idTo": .string("3000160"),
                                    "dName": .string(""),
                                    "msgType": .string("webchat"),
                                    "ts": .int(1700001602000),
                                    "content": .string("from phone"),
                                ]),
                            ]),
                        ]),
                    ])),
                ],
                steps: standardWSStartSteps() + [
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("apply_parsed_events"), "timeout_ms": .int(5000)]),
                ]
            ),

            // 17. ws_auth_watch
            ScenarioDef(
                name: "ws_auth_watch",
                seed: readySessionSeed(
                    userId: "2000017",
                    displayName: "WS User 17",
                    zpwSek: "saved.200.a0.sek_ws17",
                    suppress: ["long_poll"]
                ),
                server: [
                    loginInfoScript(uid: "2000017", zpwSek: "saved.200.a0.sek_ws17", displayName: "WS User 17"),
                    profileMeScript(uid: "2000017", displayName: "WS User 17"),
                    wsScript(),
                    wsFrameScript(cmd: 1, payload: .object(["error_code": .int(0)])),
                    wsCloseScript(),
                    wsScript(),
                    wsFrameScript(cmd: 1, payload: .object(["error_code": .int(0)])),
                ],
                steps: standardWSStartSteps() + [
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("e2ee_disconnected"), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("e2ee_connected"), "timeout_ms": .int(8000)]),
                ]
            ),

            // 18. ws_cursors
            ScenarioDef(
                name: "ws_cursors",
                seed: readySessionSeed(
                    userId: "2000018",
                    displayName: "WS User 18",
                    zpwSek: "saved.200.a0.sek_ws18",
                    wsCursors: .object([
                        "510_0": .object([
                            "lastId": .string("100"),
                            "preIds": .array([.string("99")]),
                        ]),
                        "603_0": .object([
                            "lastId": .string("200"),
                            "preIds": .array([]),
                        ]),
                    ]),
                    suppress: ["long_poll"]
                ),
                server: [
                    loginInfoScript(uid: "2000018", zpwSek: "saved.200.a0.sek_ws18", displayName: "WS User 18"),
                    profileMeScript(uid: "2000018", displayName: "WS User 18"),
                    wsScript(),
                    wsFrameScript(cmd: 1, payload: .object([
                        "error_code": .int(0),
                        "data": .object([
                            "ctrl_qCmds": .array([
                                .object(["cmd": .int(603), "subCmd": .int(0)]),
                            ]),
                            "qCmds": .array([
                                .object(["cmd": .int(510), "subCmd": .int(0)]),
                            ]),
                        ]),
                    ])),
                    wsFrameScript(cmd: 510, subCmd: 0, payload: .object([
                        "error_code": .int(0),
                        "data": .object([
                            "controls": .array([]),
                            "lastActionId": .string("105"),
                            "queueStatus": .object([
                                "510_0": .object([
                                    "lastId": .string("105"),
                                    "ids": .array([.string("104")]),
                                ]),
                            ]),
                        ]),
                    ])),
                ],
                steps: standardWSStartSteps() + [
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("apply_batch"), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("persist_ws_cursors"), "timeout_ms": .int(5000)]),
                ]
            ),

            // 19. ws_stopped_on_logout
            ScenarioDef(
                name: "ws_stopped_on_logout",
                seed: readySessionSeed(
                    userId: "2000019",
                    displayName: "WS User 19",
                    zpwSek: "saved.200.a0.sek_ws19",
                    suppress: ["long_poll"]
                ),
                server: [
                    loginInfoScript(uid: "2000019", zpwSek: "saved.200.a0.sek_ws19", displayName: "WS User 19"),
                    profileMeScript(uid: "2000019", displayName: "WS User 19"),
                    wsScript(),
                    wsFrameScript(cmd: 1, payload: .object(["error_code": .int(0)])),
                ] + qrFallbackScripts(tokenId: "tok_ws_19") + [
                    wsFrameScript(cmd: 601, payload: .object([
                        "error_code": .int(0),
                        "data": .object([
                            "controls": .array([
                                .object([
                                    "act_type": .string("typing"),
                                    "act": .string("typing"),
                                    "data": .object(["uid": .string("3000190")]),
                                ]),
                            ]),
                        ]),
                    ])),
                ],
                steps: standardWSStartSteps() + [
                    .object(["cmd": .string("log_out")]),
                    .object(["await": .object(["phase": .string("login"), "step": .string("waiting_scan")]), "timeout_ms": .int(5000)]),
                    .object(["ws_push": .int(1)]),
                ]
            ),

            // 20. lp_tick
            ScenarioDef(
                name: "lp_tick",
                seed: readySessionSeed(
                    userId: "2000020",
                    displayName: "LP User 20",
                    zpwSek: "saved.200.a0.sek_lp20",
                    pollState: defaultPollState(),
                    suppress: ["ws"]
                ),
                server: [
                    loginInfoScript(uid: "2000020", zpwSek: "saved.200.a0.sek_lp20", displayName: "LP User 20"),
                    profileMeScript(uid: "2000020", displayName: "LP User 20"),
                    httpScript(
                        path: "/",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "lastActionId": .string("11"),
                                "more": .int(1),
                                "queueStatus": .object([
                                    "1": .object(["lastId": .string("101"), "ids": .array([])]),
                                ]),
                            ]),
                        ])
                    ),
                    httpScript(
                        path: "/",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "lastActionId": .string("12"),
                                "more": .int(1),
                                "queueStatus": .object([
                                    "1": .object(["lastId": .string("102"), "ids": .array([])]),
                                ]),
                            ]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("persist_poll_state"), "timeout_ms": .int(8000)]),
                    .object(["await_host": .string("apply_batch"), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("persist_poll_state"), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("apply_batch"), "timeout_ms": .int(5000)]),
                ]
            ),

            // 21. lp_state_persist
            ScenarioDef(
                name: "lp_state_persist",
                seed: readySessionSeed(
                    userId: "2000021",
                    displayName: "LP User 21",
                    zpwSek: "saved.200.a0.sek_lp21",
                    pollState: defaultPollState(),
                    suppress: ["ws"]
                ),
                server: [
                    loginInfoScript(uid: "2000021", zpwSek: "saved.200.a0.sek_lp21", displayName: "LP User 21"),
                    profileMeScript(uid: "2000021", displayName: "LP User 21"),
                    // Batch 1: identical state -> no persist_poll_state emitted.
                    httpScript(
                        path: "/",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "more": .int(1),
                            ]),
                        ])
                    ),
                    // Batch 2: lastActionId changes -> persist_poll_state emitted before apply_batch.
                    httpScript(
                        path: "/",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "lastActionId": .string("11"),
                                "more": .int(0),
                            ]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("apply_batch"), "timeout_ms": .int(8000)]),
                    .object(["await_host": .string("persist_poll_state"), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("apply_batch"), "timeout_ms": .int(5000)]),
                ]
            ),

            // 22. lp_auth_error
            ScenarioDef(
                name: "lp_auth_error",
                seed: readySessionSeed(
                    userId: "2000022",
                    displayName: "LP User 22",
                    zpwSek: "saved.200.a0.sek_lp22",
                    pollState: defaultPollState(),
                    suppress: ["ws"]
                ),
                server: [
                    loginInfoScript(uid: "2000022", zpwSek: "saved.200.a0.sek_lp22", displayName: "LP User 22"),
                    profileMeScript(uid: "2000022", displayName: "LP User 22"),
                    httpScript(
                        path: "/",
                        json: .object(["error_code": .int(600), "error_message": .string("Session kicked")])
                    ),
                ] + qrFallbackScripts(tokenId: "tok_lp_22"),
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["await": .object(["phase": .string("login"), "step": .string("waiting_scan")]), "timeout_ms": .int(8000)]),
                ]
            ),

            // 23. lp_other_error
            ScenarioDef(
                name: "lp_other_error",
                seed: readySessionSeed(
                    userId: "2000023",
                    displayName: "LP User 23",
                    zpwSek: "saved.200.a0.sek_lp23",
                    pollState: defaultPollState(),
                    suppress: ["ws"]
                ),
                server: [
                    loginInfoScript(uid: "2000023", zpwSek: "saved.200.a0.sek_lp23", displayName: "LP User 23"),
                    profileMeScript(uid: "2000023", displayName: "LP User 23"),
                    // Tick 1 (~4s): TCP reset ends tick 1 cleanly; tick 2 (~8s) retries and succeeds.
                    httpScript(path: "/", error: "reset"),
                    httpScript(
                        path: "/",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "lastActionId": .string("11"),
                                "more": .int(0),
                            ]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("persist_poll_state"), "timeout_ms": .int(12000)]),
                    .object(["await_host": .string("apply_batch"), "timeout_ms": .int(5000)]),
                ]
            ),

            // 24. lp_mobile_sync_and_controls
            ScenarioDef(
                name: "lp_mobile_sync_and_controls",
                seed: readySessionSeed(
                    userId: "2000024",
                    displayName: "LP User 24",
                    zpwSek: "saved.200.a0.sek_lp24",
                    pollState: defaultPollState(),
                    suppress: ["ws"]
                ),
                server: [
                    loginInfoScript(uid: "2000024", zpwSek: "saved.200.a0.sek_lp24", displayName: "LP User 24"),
                    profileMeScript(uid: "2000024", displayName: "LP User 24"),
                    httpScript(
                        path: "/",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "lastActionId": .string("11"),
                                "more": .int(0),
                                "controls": .array([
                                    .object([
                                        "act_type": .string("transfer_msg"),
                                        "act": .string("transfer_after_login"),
                                        "data": .object(["temp_key": .string("tk_lp_24")]),
                                    ]),
                                    .object([
                                        "act_type": .string("typing"),
                                        "act": .string("typing"),
                                        "data": .object(["uid": .string("3000240")]),
                                    ]),
                                ]),
                                "msgs": .array([
                                    .object([
                                        "msgId": .string("2401"),
                                        "uidFrom": .string("3000240"),
                                        "content": .string("hello lp"),
                                    ]),
                                ]),
                            ]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("mobile_sync"), "timeout_ms": .int(8000)]),
                    .object(["await_host": .string("show_typing"), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("apply_batch"), "timeout_ms": .int(5000)]),
                ]
            ),

            // 25. lp_stopped_on_logout
            ScenarioDef(
                name: "lp_stopped_on_logout",
                seed: readySessionSeed(
                    userId: "2000025",
                    displayName: "LP User 25",
                    zpwSek: "saved.200.a0.sek_lp25",
                    pollState: defaultPollState(),
                    suppress: ["ws"]
                ),
                server: [
                    loginInfoScript(uid: "2000025", zpwSek: "saved.200.a0.sek_lp25", displayName: "LP User 25"),
                    profileMeScript(uid: "2000025", displayName: "LP User 25"),
                ] + qrFallbackScripts(tokenId: "tok_lp_25"),
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("log_out")]),
                    .object(["await": .object(["phase": .string("login"), "step": .string("waiting_scan")]), "timeout_ms": .int(5000)]),
                ]
            ),

            // 26. drain_command
            ScenarioDef(
                name: "drain_command",
                seed: readySessionSeed(
                    userId: "2000026",
                    displayName: "LP User 26",
                    zpwSek: "saved.200.a0.sek_lp26",
                    pollState: defaultPollState(),
                    suppress: ["ws", "long_poll"]
                ),
                server: [
                    loginInfoScript(uid: "2000026", zpwSek: "saved.200.a0.sek_lp26", displayName: "LP User 26"),
                    profileMeScript(uid: "2000026", displayName: "LP User 26"),
                    httpScript(
                        path: "/",
                        json: .object(["error_code": .int(0), "data": .object(["lastActionId": .string("11"), "more": .int(1)])])
                    ),
                    httpScript(
                        path: "/",
                        json: .object(["error_code": .int(0), "data": .object(["lastActionId": .string("12"), "more": .int(1)])])
                    ),
                    httpScript(
                        path: "/",
                        json: .object(["error_code": .int(0), "data": .object(["lastActionId": .string("13"), "more": .int(1)])])
                    ),
                    httpScript(
                        path: "/",
                        json: .object(["error_code": .int(0), "data": .object(["lastActionId": .string("14"), "more": .int(0)])])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("drain_chat_polling"), "args": .object(["max_batches": .int(4), "notify_incoming": .bool(false)])]),
                ]
            ),
        ]
    }
}

@MainActor
private final class TransportTransitionRecorder {
    private(set) var history: [CaseJSON] = []
    private(set) var cursor: Int = 0
    private var searchStart: Int = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private let scenarioName: String
    private let capture: () -> CaseJSON

    init(scenarioName: String, capture: @escaping () -> CaseJSON) {
        self.scenarioName = scenarioName
        self.capture = capture
        self.history.append(capture())
    }

    func recordTransition() {
        let snap = capture()
        if history.last == snap {
            return
        }
        history.append(snap)
        let pending = waiters
        waiters.removeAll()
        for cont in pending.values {
            cont.resume()
        }
    }

    func advanceSearchToLatestSyncState() {
        searchStart = max(searchStart, history.count - 1)
    }

    func currentCursorSnapshot() -> CaseJSON {
        history[cursor]
    }

    func cancelWaiters() {
        let pending = waiters
        waiters.removeAll()
        for cont in pending.values {
            cont.resume()
        }
    }

    func awaitPredicate(_ predicate: CaseJSON, timeoutMs: Int) async throws {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while true {
            if searchStart < history.count {
                for idx in searchStart..<history.count {
                    if SessionSnapshot.matchesPredicate(history[idx], predicate: predicate) {
                        cursor = idx
                        searchStart = idx + 1
                        return
                    }
                }
                searchStart = history.count
            }

            let remaining = deadline - ContinuousClock.now
            if remaining <= .zero {
                let lastDesc = (history.last ?? capture()).canonicalString()
                throw TransportRecorderTests.RecorderError.timeout(
                    scenario: scenarioName,
                    detail: "Timed out waiting for \(predicate.canonicalString()), current: \(lastDesc)"
                )
            }

            let waiterId = UUID()
            let timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: remaining)
                if let cont = self?.waiters.removeValue(forKey: waiterId) {
                    cont.resume()
                }
            }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                waiters[waiterId] = cont
            }
            timeoutTask.cancel()
        }
    }
}
