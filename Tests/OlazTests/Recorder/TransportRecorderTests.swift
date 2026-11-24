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
                let caseJSON = try await Self.recordScenario(scenario)
                recorded.append(caseJSON)
            }
            try CaseFile.write(recorded, to: casesURL)
        } else {
            guard FileManager.default.fileExists(atPath: casesURL.path) else {
                // Part 1 skeleton before transport.jsonl is committed: verify scenarios record cleanly.
                for scenario in Self.scenarios() {
                    if scenario.slow && !runSlow {
                        print("skipped slow: \(scenario.name)")
                        continue
                    }
                    _ = try await Self.recordScenario(scenario)
                }
                return
            }

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
        let allowWS: Bool
        let allowLongPoll: Bool
        let allowBootstrap: Bool
        let expectedSettles: Int
        let waitForHostCalls: [String]
        let settleTimeoutMs: Int

        init(
            name: String,
            slow: Bool = false,
            seed: CaseJSON,
            server: [CaseJSON],
            steps: [CaseJSON],
            allowWS: Bool = false,
            allowLongPoll: Bool = false,
            allowBootstrap: Bool = false,
            expectedSettles: Int = 0,
            waitForHostCalls: [String] = [],
            settleTimeoutMs: Int = 8000
        ) {
            self.name = name
            self.slow = slow
            self.seed = seed
            self.server = server
            self.steps = steps
            self.allowWS = allowWS
            self.allowLongPoll = allowLongPoll
            self.allowBootstrap = allowBootstrap
            self.expectedSettles = expectedSettles
            self.waitForHostCalls = waitForHostCalls
            self.settleTimeoutMs = settleTimeoutMs
        }
    }

    enum RecorderError: Error, CustomStringConvertible {
        case timeout(String)
        case unscriptedRequest(String)
        case invalidStep(String)
        case hostNotIsolated(String)

        var description: String {
            switch self {
            case .timeout(let msg): return "RecorderError.timeout: \(msg)"
            case .unscriptedRequest(let name): return "RecorderError.unscriptedRequest: \(name)"
            case .invalidStep(let msg): return "RecorderError.invalidStep: \(msg)"
            case .hostNotIsolated(let msg): return "RecorderError.hostNotIsolated: \(msg)"
            }
        }
    }

    @MainActor
    static func recordScenario(_ scenario: ScenarioDef) async throws -> CaseJSON {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-transport-recorder-\(scenario.name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let savedLegacyIMEI = UserDefaults.standard.object(forKey: "olaz.imei")
        let savedNativeIMEI = UserDefaults.standard.object(forKey: "olaz.native.pc.imei")
        deleteZpwSekCookies()

        defer {
            deleteZpwSekCookies()
            if let savedLegacyIMEI {
                UserDefaults.standard.set(savedLegacyIMEI, forKey: "olaz.imei")
            } else {
                UserDefaults.standard.removeObject(forKey: "olaz.imei")
            }
            if let savedNativeIMEI {
                UserDefaults.standard.set(savedNativeIMEI, forKey: "olaz.native.pc.imei")
            } else {
                UserDefaults.standard.removeObject(forKey: "olaz.native.pc.imei")
            }
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
                HTTPCookieStorage.shared.setCookie(cookie)
            }
            if let imei = cookieSeed["imei"]?.stringValue {
                UserDefaults.standard.set(imei, forKey: "olaz.imei")
            }
        }

        // Decode seed.domains and enforce local-only fake hosts + isolated=true.
        let domainsJSON = substituteRuntimeURLs(scenario.seed["domains"] ?? defaultFakeDomainsJSON())
        let domainsData = Data(domainsJSON.canonicalString().utf8)
        let domains = try JSONDecoder().decode(ZaloDomains.self, from: domainsData)
        try assertOnlyLocalFakeHosts(domains, context: "\(scenario.name) initial seed")

        let engine = ZaloEngine(dataDirectory: dataDir, useKeychain: false, domains: domains)
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

        var hostCalls: [CaseJSON] = []
        var settleCount = 0
        var settleWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        func notifyTransportSignal() {
            let pending = settleWaiters
            settleWaiters.removeAll()
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
            notifyTransportSignal()
            switch name {
            case "start_ws":
                return scenario.allowWS
            case "start_long_poll":
                return scenario.allowLongPoll
            case "start_bootstrap":
                return scenario.allowBootstrap
            default:
                return false
            }
        }

        engine.transportSettleTrace = {
            settleCount += 1
            notifyTransportSignal()
        }

        let transitionRecorder = TransportTransitionRecorder {
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
                    default:
                        throw RecorderError.invalidStep("Unknown cmd: \(cmd)")
                    }
                } else if let pred = step["await"] {
                    let timeoutMs = Int(step["timeout_ms"]?.int64Value ?? 5000)
                    try await transitionRecorder.awaitPredicate(pred, timeoutMs: timeoutMs)
                } else if let label = step["snapshot"]?.stringValue {
                    snapshots[label] = transitionRecorder.currentCursorSnapshot()
                } else {
                    throw RecorderError.invalidStep("Unknown step: \(step.canonicalString())")
                }
            }

            _ = await engine.bootTask?.value
            _ = await engine.pendingCleanupTask?.value
            await server.waitForScriptedRequests(timeoutMs: scenario.settleTimeoutMs)

            // Wait until transport event handlers & expected host calls settle on MainActor.
            let settleDeadline = ContinuousClock.now + .milliseconds(scenario.settleTimeoutMs)
            func isSettled() -> Bool {
                guard settleCount >= scenario.expectedSettles else { return false }
                let recordedNames = hostCalls.compactMap { $0["call"]?.stringValue }
                for requiredCall in scenario.waitForHostCalls {
                    if !recordedNames.contains(requiredCall) { return false }
                }
                return true
            }
            while !isSettled() {
                let remaining = settleDeadline - ContinuousClock.now
                if remaining <= .zero {
                    throw RecorderError.timeout(
                        "\(scenario.name): transport did not settle (settleCount=\(settleCount)/\(scenario.expectedSettles), hostCalls=\(hostCalls.compactMap { $0["call"]?.stringValue }))"
                    )
                }
                let waiterId = UUID()
                let timeoutTask = Task { @MainActor in
                    try? await Task.sleep(for: remaining)
                    if let cont = settleWaiters.removeValue(forKey: waiterId) {
                        cont.resume()
                    }
                }
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    settleWaiters[waiterId] = cont
                }
                timeoutTask.cancel()
            }

            await Task.yield()

            try assertOnlyLocalFakeHosts(await engine.sessionClient.domains, context: "\(scenario.name) final")

            let finalState = normalizeRecordedURLs(SessionSnapshot.capture(from: engine))
            let requests = server.canonicalRequests().map { normalizeRecordedURLs($0) }

            engine.cancelTasksForRecording()
            engine.transportSettleTrace = nil
            server.stop()
            await engine.finishTearDownForRecording()

            if server.hadUnscriptedRequest {
                throw RecorderError.unscriptedRequest(scenario.name)
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
            let pending = settleWaiters
            settleWaiters.removeAll()
            for cont in pending.values { cont.resume() }
            engine.cancelTasksForRecording()
            engine.transportSettleTrace = nil
            server.stop()
            await engine.finishTearDownForRecording()
            throw error
        }
    }

    private static func assertOnlyLocalFakeHosts(_ domains: ZaloDomains, context: String) throws {
        guard domains.isolated else {
            throw RecorderError.hostNotIsolated("\(context): ZaloDomains.isolated must be true")
        }
        var allHosts: [String] = [domains.auth, domains.wpaChat, domains.lpChat, domains.lpControl]
        allHosts.append(contentsOf: domains.ws)
        allHosts.append(contentsOf: domains.serviceCandidates.values.flatMap { $0 })
        allHosts.append(contentsOf: domains.preferredHosts.values)

        let allowedHosts: Set<String> = ["127.0.0.1", "localhost", "fake"]
        for raw in allHosts where !raw.isEmpty {
            let norm = ZaloDomains.normalizeHost(raw)
            guard let host = URL(string: norm)?.host?.lowercased(), allowedHosts.contains(host) else {
                throw RecorderError.hostNotIsolated("\(context): non-fake host detected '\(raw)'")
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

    private static func deleteZpwSekCookies() {
        for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.name == "zpw_sek" {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
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

    static func scenarios() -> [ScenarioDef] {
        [
            // 1. ws_starts_after_ready
            ScenarioDef(
                name: "ws_starts_after_ready",
                seed: readySessionSeed(
                    userId: "2000001",
                    displayName: "WS User 1",
                    zpwSek: "saved.200.a0.sek_ws1"
                ),
                server: [
                    loginInfoScript(uid: "2000001", zpwSek: "saved.200.a0.sek_ws1", displayName: "WS User 1"),
                    profileMeScript(uid: "2000001", displayName: "WS User 1"),
                    wsScript(path: "/", accept: true),
                    wsFrameScript(
                        cmd: 1,
                        subCmd: 0,
                        payload: .object([
                            "error_code": .int(0),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                ],
                allowWS: true,
                allowLongPoll: false,
                expectedSettles: 1,
                waitForHostCalls: ["e2ee_connected"]
            ),

            // 20. lp_tick
            ScenarioDef(
                name: "lp_tick",
                seed: readySessionSeed(
                    userId: "2000020",
                    displayName: "LP User 20",
                    zpwSek: "saved.200.a0.sek_lp20",
                    pollState: .object([
                        "lastActionId": .string("10"),
                        "lastActionIdOther": .string("20"),
                        "queues": .object([
                            "1": .object(["lastId": .string("100"), "ids": .array([])]),
                            "2": .object(["lastId": .string("1"), "ids": .array([])]),
                            "3": .object(["lastId": .string("1"), "ids": .array([])]),
                        ]),
                    ])
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
                                    "1": .object([
                                        "lastId": .string("101"),
                                        "ids": .array([]),
                                    ]),
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
                                    "1": .object([
                                        "lastId": .string("102"),
                                        "ids": .array([]),
                                    ]),
                                ]),
                            ]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                ],
                allowWS: false,
                allowLongPoll: true,
                expectedSettles: 1,
                waitForHostCalls: ["apply_batch", "persist_poll_state"],
                settleTimeoutMs: 10000
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
    private let capture: () -> CaseJSON

    init(capture: @escaping () -> CaseJSON) {
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
                    "Timed out waiting for \(predicate.canonicalString()), current: \(lastDesc)"
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
