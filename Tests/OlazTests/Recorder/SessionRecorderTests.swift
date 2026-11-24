import Foundation
import Testing
@testable import Olaz

@Suite(.serialized)
struct SessionRecorderTests {
    @Test
    @MainActor
    func sessionCases() async throws {
        let isRecord = ProcessInfo.processInfo.environment["OLAZ_RECORD"] == "1"
        let runSlow = isRecord || ProcessInfo.processInfo.environment["OLAZ_SLOW_CASES"] == "1"
        let casesURL = CaseFile.casesURL(domain: "session")

        if isRecord {
            var recorded: [CaseJSON] = []
            for scenario in Self.scenarios() {
                let caseJSON = try await Self.recordScenario(scenario)
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
            .appendingPathComponent("olaz-recorder-\(scenario.name)-\(UUID().uuidString)", isDirectory: true)
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

        var hostCalls: [CaseJSON] = []
        engine.hostTrace = { name, args in
            let normalizedArgs = normalizeRecordedURLs(CaseJSON.fromAny(args))
            hostCalls.append(.object([
                "call": .string(name),
                "args": normalizedArgs,
            ]))
            return false
        }

        let transitionRecorder = TransitionRecorder {
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
                        if case .login(let login) = engine.phase,
                           case .waitingScan = login.step,
                           let waitScanPath = scenario.server.first(where: {
                               ($0["path"]?.stringValue ?? "").hasPrefix("/api/login/waitScan")
                           })?["path"]?.stringValue {
                            await server.waitForConsumed(path: waitScanPath, timeoutMs: 2000)
                        }
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
            if case .login(let login) = engine.phase {
                switch login.step {
                case .generating, .waitingScan, .waitingConfirm:
                    break
                case .expired, .failed:
                    _ = await engine.qrTask?.value
                }
            } else {
                _ = await engine.qrTask?.value
            }
            _ = await engine.pendingCleanupTask?.value
            await server.waitForScriptedRequests(timeoutMs: 2000)
            await Task.yield()

            try assertOnlyLocalFakeHosts(await engine.sessionClient.domains, context: "\(scenario.name) final")

            let finalState = normalizeRecordedURLs(SessionSnapshot.capture(from: engine))
            let requests = server.canonicalRequests().map { normalizeRecordedURLs($0) }

            engine.cancelTasksForRecording()
            server.stop()
            await engine.finishTearDownForRecording()

            if server.hadUnscriptedRequest {
                throw RecorderError.unscriptedRequest(scenario.name)
            }

            var caseDict: [String: CaseJSON] = [
                "format": .int(1),
                "domain": .string("session"),
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
            engine.cancelTasksForRecording()
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

    private static func emptySeed() -> CaseJSON {
        .object([
            "saved_session": .null,
            "domains": defaultFakeDomainsJSON(),
            "legacy_cookie": .null,
            "prefs": .object([:]),
        ])
    }

    private static func savedSessionSeed(
        userId: String,
        displayName: String = "Saved Name",
        avatar: String = "https://cdn.example.invalid/saved.jpg",
        phone: String = "+84900000001",
        send2MeId: String? = nil,
        zpwEnk: String = "0123456789abcdef",
        zpwSek: String = "saved.200.a0.sek",
        needSyncMsg: Bool? = false,
        prefs: [String: String] = [:]
    ) -> CaseJSON {
        var acct: [String: CaseJSON] = [
            "userId": .string(userId),
            "displayName": .string(displayName),
            "avatar": .string(avatar),
            "phone": .string(phone),
            "send2MeId": .string(send2MeId ?? userId),
            "dkey": .string("dkey_\(userId)"),
            "zpwEnk": .string(zpwEnk),
            "zpwSek": .string(zpwSek),
        ]
        if let needSyncMsg {
            acct["needSyncMsg"] = .bool(needSyncMsg)
        }
        let saved: CaseJSON = .object([
            "zpwType": .string("23"),
            "imei": .string(syntheticIMEI()),
            "computerName": .string("TestMac"),
            "domains": defaultFakeDomainsJSON(),
            "sealedSecretsBase64": .null,
            "plainAccount": .object(acct),
            "expiredAt": .null,
        ])
        return .object([
            "saved_session": saved,
            "domains": defaultFakeDomainsJSON(),
            "legacy_cookie": .null,
            "prefs": .object(prefs.mapValues(CaseJSON.string)),
        ])
    }

    private static func httpScript(
        path: String,
        method: String = "GET",
        status: Int64 = 200,
        json: CaseJSON? = nil,
        error: String? = nil,
        headers: [String: String] = [:],
        `repeat`: Bool = false
    ) -> CaseJSON {
        var resp: [String: CaseJSON] = [:]
        if let error {
            resp["error"] = .string(error)
        } else {
            resp["status"] = .int(status)
            if !headers.isEmpty {
                resp["headers"] = .object(headers.mapValues(CaseJSON.string))
            }
            if let json {
                resp["json"] = json
            }
        }
        var entry: [String: CaseJSON] = [
            "kind": .string("http"),
            "path": .string(path),
            "method": .string(method),
            "response": .object(resp),
        ]
        if `repeat` {
            entry["repeat"] = .bool(true)
        }
        return .object(entry)
    }

    private static func serverInfoScript(error: String? = nil) -> CaseJSON {
        if let error {
            return httpScript(path: "/api/login/getServerInfo", error: error)
        }
        return httpScript(
            path: "/api/login/getServerInfo",
            json: .object(["error_code": .int(0), "data": .object([:])])
        )
    }

    private static func reqqrScript(
        tokenId: String = "tok_qr_1",
        qrCnt: String = "https://zalo.me/qr/test-1",
        waitScanPath: String = "/api/login/waitScan",
        waitCfirmPath: String = "/api/login/waitCfirm",
        qrTimeout: Int64 = 60,
        qrRetry: Int64 = 1
    ) -> CaseJSON {
        httpScript(
            path: "/api/login/reqqr",
            json: .object([
                "error_code": .int(0),
                "data": .object([
                    "token_id": .string(tokenId),
                    "qr_cnt": .string(qrCnt),
                    "chk_wait_scan": .string("http://fake\(waitScanPath)"),
                    "chk_wait_cfirm": .string("http://fake\(waitCfirmPath)"),
                    "qr_timeout": .int(qrTimeout),
                    "qr_retry": .int(qrRetry),
                ]),
            ])
        )
    }

    private static func loginInfoScript(
        uid: String,
        zpwSek: String,
        needSyncMsg: Bool = false,
        displayName: String = "Logged In User",
        send2MeId: String? = nil
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
                    "send2me_id": .string(send2MeId ?? uid),
                    "need_sync_msg": .bool(needSyncMsg),
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
        displayName: String = "Synced User",
        avatar: String = "https://cdn.example.invalid/synced.jpg",
        phone: String = "+84988888888"
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
            // 1. qr_first_screen
            ScenarioDef(
                name: "qr_first_screen",
                seed: emptySeed(),
                server: [
                    serverInfoScript(),
                    reqqrScript(tokenId: "tok_qr_1", qrCnt: "https://zalo.me/qr/test-1"),
                    httpScript(path: "/api/login/waitScan", error: "timeout"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("login"), "step": .string("generating")]), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("generating")]),
                    .object(["await": .object(["phase": .string("login"), "step": .string("waiting_scan")]), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("waiting_scan")]),
                ]
            ),

            // 2. qr_full_login
            ScenarioDef(
                name: "qr_full_login",
                seed: emptySeed(),
                server: [
                    serverInfoScript(),
                    reqqrScript(tokenId: "tok_qr_2", qrCnt: "https://zalo.me/qr/test-2"),
                    httpScript(
                        path: "/api/login/waitScan",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "display_name": .string("Nguyen Van A"),
                                "avatar": .string("https://cdn.example.invalid/avatar-a.jpg"),
                            ]),
                        ])
                    ),
                    httpScript(
                        path: "/api/login/waitCfirm",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "zpw_sek": .string("qr.200.a0.sek2"),
                                "uid": .string("1000002"),
                                "dkey": .string("dkey_1000002"),
                                "zpw_enk": .string("0123456789abcdef"),
                            ]),
                        ])
                    ),
                    loginInfoScript(uid: "1000002", zpwSek: "qr.200.a0.sek2", needSyncMsg: false, displayName: "Nguyen Van A"),
                    profileMeScript(
                        uid: "1000002",
                        displayName: "Nguyen Van A",
                        avatar: "https://cdn.example.invalid/avatar-a.jpg",
                        phone: "+84900000002"
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("login"), "step": .string("waiting_scan")]), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("waiting_scan")]),
                    .object(["await": .object(["phase": .string("login"), "step": .string("waiting_confirm")]), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("waiting_confirm")]),
                    .object(["await": .object(["phase": .string("signing_in")]), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("signing_in")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                ]
            ),

            // 3. qr_full_login_need_sync
            ScenarioDef(
                name: "qr_full_login_need_sync",
                seed: emptySeed(),
                server: [
                    serverInfoScript(),
                    reqqrScript(tokenId: "tok_qr_3", qrCnt: "https://zalo.me/qr/test-3"),
                    httpScript(
                        path: "/api/login/waitScan",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "display_name": .string("Tran Thi Sync"),
                                "avatar": .string("https://cdn.example.invalid/avatar-3.jpg"),
                            ]),
                        ])
                    ),
                    httpScript(
                        path: "/api/login/waitCfirm",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "zpw_sek": .string("qr.200.a0.sek3"),
                                "uid": .string("1000003"),
                                "dkey": .string("dkey_1000003"),
                                "zpw_enk": .string("0123456789abcdef"),
                            ]),
                        ])
                    ),
                    loginInfoScript(uid: "1000003", zpwSek: "qr.200.a0.sek3", needSyncMsg: true, displayName: "Tran Thi Sync"),
                    profileMeScript(
                        uid: "1000003",
                        displayName: "Tran Thi Sync",
                        avatar: "https://cdn.example.invalid/avatar-3.jpg",
                        phone: "+84900000003"
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                ]
            ),

            // 4. qr_rotated_while_waiting
            ScenarioDef(
                name: "qr_rotated_while_waiting",
                seed: emptySeed(),
                server: [
                    serverInfoScript(),
                    reqqrScript(
                        tokenId: "tok_rot_1",
                        qrCnt: "https://zalo.me/qr/rot-1",
                        waitScanPath: "/api/login/waitScan1",
                        waitCfirmPath: "/api/login/waitCfirm"
                    ),
                    httpScript(
                        path: "/api/login/waitScan1",
                        json: .object([
                            "error_code": .int(-20),
                            "data": .object([
                                "token_id": .string("tok_rot_2"),
                                "qr_cnt": .string("https://zalo.me/qr/rot-2"),
                                "chk_wait_scan": .string("http://fake/api/login/waitScan2"),
                                "chk_wait_cfirm": .string("http://fake/api/login/waitCfirm"),
                                "qr_timeout": .int(60),
                                "qr_retry": .int(1),
                            ]),
                        ])
                    ),
                    httpScript(path: "/api/login/waitScan2", error: "timeout"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("login"), "step": .string("waiting_scan")]), "timeout_ms": .int(5000)]),
                ]
            ),

            // 5. qr_timeout (slow: exercises real ~72s HTTP timeout)
            ScenarioDef(
                name: "qr_timeout",
                slow: true,
                seed: emptySeed(),
                server: [
                    serverInfoScript(),
                    reqqrScript(tokenId: "tok_qr_5", qrCnt: "https://zalo.me/qr/timeout-5"),
                    httpScript(path: "/api/login/waitScan", error: "timeout"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("login"), "step": .string("waiting_scan")]), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("waiting_scan")]),
                    .object(["await": .object(["phase": .string("login"), "step": .string("expired")]), "timeout_ms": .int(80000)]),
                ]
            ),

            // 6. qr_server_error
            ScenarioDef(
                name: "qr_server_error",
                seed: emptySeed(),
                server: [
                    serverInfoScript(),
                    httpScript(
                        path: "/api/login/reqqr",
                        json: .object([
                            "error_code": .int(-1),
                            "error_message": .string(""),
                        ])
                    ),
                    serverInfoScript(),
                    httpScript(
                        path: "/api/login/reqqr",
                        json: .object([
                            "error_code": .int(-2),
                            "error_message": .string("Máy chủ bận."),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("login"), "step": .string("failed")]), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("empty_message")]),
                    .object(["cmd": .string("refresh_qr")]),
                    .object(["await": .object(["phase": .string("login"), "step": .string("failed")]), "timeout_ms": .int(5000)]),
                ]
            ),

            // 7. qr_missing_data
            ScenarioDef(
                name: "qr_missing_data",
                seed: emptySeed(),
                server: [
                    serverInfoScript(),
                    httpScript(
                        path: "/api/login/reqqr",
                        json: .object(["error_code": .int(0)])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("login"), "step": .string("failed")]), "timeout_ms": .int(5000)]),
                ]
            ),

            // 8. qr_network_error
            ScenarioDef(
                name: "qr_network_error",
                seed: emptySeed(),
                server: [
                    serverInfoScript(error: "refused"),
                    httpScript(path: "/api/login/reqqr", error: "refused"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("login"), "step": .string("failed")]), "timeout_ms": .int(5000)]),
                ]
            ),

            // 9. qr_confirm_rejected
            ScenarioDef(
                name: "qr_confirm_rejected",
                seed: emptySeed(),
                server: [
                    serverInfoScript(),
                    reqqrScript(tokenId: "tok_qr_9", qrCnt: "https://zalo.me/qr/test-9"),
                    httpScript(
                        path: "/api/login/waitScan",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "display_name": .string("Nguyen Van B"),
                                "avatar": .string(""),
                            ]),
                        ])
                    ),
                    httpScript(
                        path: "/api/login/waitCfirm",
                        json: .object([
                            "error_code": .int(-30),
                            "error_message": .string("Đăng nhập đã bị từ chối trên điện thoại."),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("login"), "step": .string("waiting_confirm")]), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("waiting_confirm")]),
                    .object(["await": .object(["phase": .string("login"), "step": .string("failed")]), "timeout_ms": .int(5000)]),
                ]
            ),

            // 10. boot_saved_session_valid
            ScenarioDef(
                name: "boot_saved_session_valid",
                seed: savedSessionSeed(
                    userId: "1000010",
                    displayName: "Saved Old Name",
                    avatar: "https://cdn.example.invalid/old-10.jpg",
                    phone: "+84900000010",
                    zpwSek: "saved.200.a0.sek10"
                ),
                server: [
                    loginInfoScript(uid: "1000010", zpwSek: "saved.200.a0.sek10", displayName: "Saved Old Name"),
                    profileMeScript(
                        uid: "1000010",
                        displayName: "Synced Fresh Name",
                        avatar: "https://cdn.example.invalid/new-10.jpg",
                        phone: "+84999999910"
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("ready_before_status")]),
                ]
            ),

            // 11. boot_saved_session_profile_fails
            ScenarioDef(
                name: "boot_saved_session_profile_fails",
                seed: savedSessionSeed(
                    userId: "1000011",
                    displayName: "Saved Stays Name",
                    avatar: "https://cdn.example.invalid/saved-11.jpg",
                    phone: "+84900000011",
                    zpwSek: "saved.200.a0.sek11"
                ),
                server: [
                    loginInfoScript(uid: "1000011", zpwSek: "saved.200.a0.sek11", displayName: "Saved Stays Name"),
                    httpScript(
                        path: "/api/social/profile/me-v2",
                        json: .object([
                            "error_code": .int(-50),
                            "error_message": .string("Profile temporarily unavailable"),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                ]
            ),

            // 12. boot_saved_session_expired
            ScenarioDef(
                name: "boot_saved_session_expired",
                seed: savedSessionSeed(
                    userId: "1000012",
                    displayName: "Expired User",
                    zpwSek: "saved.200.a0.sek12"
                ),
                server: [
                    httpScript(
                        path: "/api/login/getLoginInfo",
                        json: .object([
                            "error_code": .int(600),
                            "error_message": .string("Session expired"),
                        ])
                    ),
                    httpScript(
                        path: "/api/login/getLoginInfo",
                        json: .object([
                            "error_code": .int(600),
                            "error_message": .string("Session expired"),
                        ])
                    ),
                    serverInfoScript(),
                    reqqrScript(tokenId: "tok_qr_12", qrCnt: "https://zalo.me/qr/test-12"),
                    httpScript(path: "/api/login/waitScan", error: "timeout"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("ready_before_status")]),
                    .object(["await": .object(["phase": .string("login"), "step": .string("waiting_scan")]), "timeout_ms": .int(5000)]),
                ]
            ),

            // 13. boot_saved_session_unreachable
            ScenarioDef(
                name: "boot_saved_session_unreachable",
                seed: savedSessionSeed(
                    userId: "1000013",
                    displayName: "Cached Offline User",
                    avatar: "https://cdn.example.invalid/offline-13.jpg",
                    phone: "+84900000013",
                    zpwSek: "saved.200.a0.sek13"
                ),
                server: [
                    httpScript(path: "/api/login/getLoginInfo", error: "refused"),
                    httpScript(path: "/api/login/getLoginInfo", error: "refused"),
                    httpScript(path: "/api/social/profile/me-v2", error: "refused"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                ]
            ),

            // 14. boot_saved_session_empty_user
            ScenarioDef(
                name: "boot_saved_session_empty_user",
                seed: savedSessionSeed(
                    userId: "",
                    displayName: "",
                    avatar: "",
                    phone: "",
                    send2MeId: "",
                    zpwSek: "saved.200.a0.sek14"
                ),
                server: [
                    serverInfoScript(),
                    reqqrScript(tokenId: "tok_qr_14", qrCnt: "https://zalo.me/qr/test-14"),
                    httpScript(path: "/api/login/waitScan", error: "timeout"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("login"), "step": .string("waiting_scan")]), "timeout_ms": .int(5000)]),
                ]
            ),

            // 15. boot_legacy_cookie
            ScenarioDef(
                name: "boot_legacy_cookie",
                seed: .object([
                    "saved_session": .null,
                    "domains": defaultFakeDomainsJSON(),
                    "legacy_cookie": .object([
                        "zpw_sek": .string("legacy.200.a0.sek15"),
                        "imei": .string(syntheticIMEI()),
                    ]),
                    "prefs": .object([:]),
                ]),
                server: [
                    loginInfoScript(uid: "1000015", zpwSek: "legacy.200.a0.sek15", displayName: "Legacy Login Name"),
                    profileMeScript(
                        uid: "1000015",
                        displayName: "Legacy Initial Profile",
                        avatar: "https://cdn.example.invalid/legacy-15a.jpg",
                        phone: "+84900000015"
                    ),
                    loginInfoScript(uid: "1000015", zpwSek: "legacy.200.a0.sek15", displayName: "Legacy Login Name"),
                    profileMeScript(
                        uid: "1000015",
                        displayName: "Legacy Synced Profile",
                        avatar: "https://cdn.example.invalid/legacy-15b.jpg",
                        phone: "+84911111115"
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("ready_before_status")]),
                ]
            ),

            // 16. log_out_from_ready
            ScenarioDef(
                name: "log_out_from_ready",
                seed: savedSessionSeed(
                    userId: "1000016",
                    displayName: "Ready User 16",
                    zpwSek: "saved.200.a0.sek16"
                ),
                server: [
                    loginInfoScript(uid: "1000016", zpwSek: "saved.200.a0.sek16", displayName: "Ready User 16"),
                    profileMeScript(uid: "1000016", displayName: "Ready User 16"),
                    serverInfoScript(),
                    reqqrScript(tokenId: "tok_qr_16", qrCnt: "https://zalo.me/qr/test-16"),
                    httpScript(path: "/api/login/waitScan", error: "timeout"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("log_out")]),
                    .object(["await": .object(["phase": .string("login"), "step": .string("waiting_scan")]), "timeout_ms": .int(5000)]),
                ]
            ),

            // 17. session_expired_mid_session
            ScenarioDef(
                name: "session_expired_mid_session",
                seed: savedSessionSeed(
                    userId: "1000017",
                    displayName: "Ready User 17",
                    zpwSek: "saved.200.a0.sek17"
                ),
                server: [
                    loginInfoScript(uid: "1000017", zpwSek: "saved.200.a0.sek17", displayName: "Ready User 17"),
                    profileMeScript(uid: "1000017", displayName: "Ready User 17"),
                    serverInfoScript(),
                    reqqrScript(tokenId: "tok_qr_17", qrCnt: "https://zalo.me/qr/test-17"),
                    httpScript(path: "/api/login/waitScan", error: "timeout"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("session_expired"), "args": .object(["reason": .string("Phiên hết hạn từ thiết bị khác.")])]),
                    .object(["await": .object(["phase": .string("login"), "step": .string("waiting_scan")]), "timeout_ms": .int(5000)]),
                ]
            ),

            // 18. refresh_qr_clears_notice
            ScenarioDef(
                name: "refresh_qr_clears_notice",
                seed: savedSessionSeed(
                    userId: "1000018",
                    displayName: "Ready User 18",
                    zpwSek: "saved.200.a0.sek18"
                ),
                server: [
                    loginInfoScript(uid: "1000018", zpwSek: "saved.200.a0.sek18", displayName: "Ready User 18"),
                    profileMeScript(uid: "1000018", displayName: "Ready User 18"),
                    serverInfoScript(),
                    reqqrScript(
                        tokenId: "tok_qr_18a",
                        qrCnt: "https://zalo.me/qr/test-18a",
                        waitScanPath: "/api/login/waitScan1",
                        waitCfirmPath: "/api/login/waitCfirm"
                    ),
                    httpScript(path: "/api/login/waitScan1", error: "timeout"),
                    serverInfoScript(),
                    reqqrScript(
                        tokenId: "tok_qr_18b",
                        qrCnt: "https://zalo.me/qr/test-18b",
                        waitScanPath: "/api/login/waitScan2",
                        waitCfirmPath: "/api/login/waitCfirm"
                    ),
                    httpScript(path: "/api/login/waitScan2", error: "timeout"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("session_expired"), "args": .object(["reason": .string("Đã đăng xuất từ nơi khác.")])]),
                    .object(["await": .object(["phase": .string("login"), "step": .string("waiting_scan")]), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("with_notice")]),
                    .object(["cmd": .string("refresh_qr")]),
                    .object(["await": .object(["phase": .string("login"), "step": .string("waiting_scan")]), "timeout_ms": .int(5000)]),
                ]
            ),

            // 19. profile_defaults
            ScenarioDef(
                name: "profile_defaults",
                seed: savedSessionSeed(
                    userId: "1000019",
                    displayName: "",
                    avatar: "",
                    phone: "",
                    send2MeId: "",
                    zpwSek: "saved.200.a0.sek19"
                ),
                server: [
                    loginInfoScript(uid: "1000019", zpwSek: "saved.200.a0.sek19", displayName: "", send2MeId: ""),
                    profileMeScript(uid: "1000019", displayName: "", avatar: "", phone: ""),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                ]
            ),

            // 20. start_twice
            ScenarioDef(
                name: "start_twice",
                seed: savedSessionSeed(
                    userId: "1000020",
                    displayName: "Once Only User",
                    avatar: "https://cdn.example.invalid/user-20.jpg",
                    phone: "+84900000020",
                    zpwSek: "saved.200.a0.sek20"
                ),
                server: [
                    loginInfoScript(uid: "1000020", zpwSek: "saved.200.a0.sek20", displayName: "Once Only User"),
                    profileMeScript(
                        uid: "1000020",
                        displayName: "Once Only User",
                        avatar: "https://cdn.example.invalid/user-20.jpg",
                        phone: "+84900000020"
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("start")]),
                ]
            ),
        ]
    }
}

@MainActor
private final class TransitionRecorder {
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
                throw SessionRecorderTests.RecorderError.timeout(
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
