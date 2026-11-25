import Foundation
import XCTest
@testable import Olaz

final class ForwardRecorderTests: XCTestCase {
    func testForwardScenarios() async throws {
        try await ForwardRecorderHarness.runDomainSuite(
            domain: "forward",
            scenarios: Self.forwardScenarios()
        )
    }

    // MARK: - Scenarios

    private static func forwardScenarios() -> [ForwardRecorderHarness.ScenarioDef] {
        []
    }
}

// MARK: - Forward Recorder Harness

@MainActor
private final class ForwardTransitionRecorder {
    private let scenarioName: String
    private let capture: () -> CaseJSON
    private var history: [CaseJSON] = []
    private var searchFromIndex = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(scenarioName: String, capture: @escaping () -> CaseJSON) {
        self.scenarioName = scenarioName
        self.capture = capture
    }

    func recordTransition() {
        history.append(capture())
        if !waiters.isEmpty {
            let pending = waiters
            waiters.removeAll()
            for cont in pending.values {
                cont.resume()
            }
        }
    }

    func advanceSearchToLatestSyncState() {
        recordTransition()
        searchFromIndex = max(0, history.count - 1)
    }

    func cancelWaiters() {
        let pending = waiters
        waiters.removeAll()
        for cont in pending.values {
            cont.resume()
        }
    }

    func awaitPredicate(_ pred: CaseJSON, timeoutMs: Int) async throws {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        let targetKind = pred["phase"]?.stringValue
        let targetStep = pred["step"]?.stringValue

        func matches(_ state: CaseJSON) -> Bool {
            guard let phase = state["phase"],
                  let kind = phase["kind"]?.stringValue else { return false }
            if let targetKind, kind != targetKind { return false }
            if let targetStep, phase["step"]?.stringValue != targetStep { return false }
            return true
        }

        while true {
            recordTransition()
            if let hit = (searchFromIndex..<history.count).first(where: { matches(history[$0]) }) {
                searchFromIndex = hit + 1
                return
            }
            let remaining = deadline - ContinuousClock.now
            if remaining <= .zero {
                throw ForwardRecorderHarness.RecorderError.timeout(
                    scenario: scenarioName,
                    detail: "timed out awaiting \(pred.canonicalString()); latest phase: \(history.last?["phase"]?.canonicalString() ?? "none")"
                )
            }
            let waiterId = UUID()
            let timeoutTask = Task { @MainActor in
                try? await Task.sleep(for: min(remaining, .milliseconds(50)))
                if let cont = self.waiters.removeValue(forKey: waiterId) {
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

enum ForwardRecorderHarness {
    enum RecorderError: Error, CustomStringConvertible {
        case timeout(scenario: String, detail: String)
        case unscriptedRequest(scenario: String, detail: String)
        case invalidStep(scenario: String, detail: String)
        case invalidSeed(scenario: String, detail: String)
        case hostNotIsolated(scenario: String, detail: String)

        var description: String {
            switch self {
            case .timeout(let scenario, let detail):
                return "\(scenario): RecorderError.timeout: \(detail)"
            case .unscriptedRequest(let scenario, let detail):
                return "\(scenario): RecorderError.unscriptedRequest: \(detail)"
            case .invalidStep(let scenario, let detail):
                return "\(scenario): RecorderError.invalidStep: \(detail)"
            case .invalidSeed(let scenario, let detail):
                return "\(scenario): RecorderError.invalidSeed: \(detail)"
            case .hostNotIsolated(let scenario, let detail):
                return "\(scenario): RecorderError.hostNotIsolated: \(detail)"
            }
        }
    }

    struct ScenarioDef {
        let name: String
        let seed: CaseJSON
        let server: [CaseJSON]
        let steps: [CaseJSON]
        let slow: Bool

        init(name: String, seed: CaseJSON, server: [CaseJSON], steps: [CaseJSON], slow: Bool = false) {
            self.name = name
            self.seed = seed
            self.server = server
            self.steps = steps
            self.slow = slow
        }
    }

    static func httpScript(
        path: String,
        method: String = "GET",
        status: Int64 = 200,
        hold: Bool = false,
        json: CaseJSON? = nil,
        error: String? = nil,
        repeatResponse: Bool = false
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
        var obj: [String: CaseJSON] = [
            "kind": .string("http"),
            "path": .string(path),
            "method": .string(method),
            "response": .object(resp),
        ]
        if hold { obj["hold"] = .bool(true) }
        if repeatResponse { obj["repeat"] = .bool(true) }
        return .object(obj)
    }

    static func runDomainSuite(domain: String, scenarios: [ScenarioDef]) async throws {
        guard !scenarios.isEmpty else { return }
        let shouldRecord = ProcessInfo.processInfo.environment["OLAZ_RECORD"] == "1"
        let runSlow = shouldRecord || ProcessInfo.processInfo.environment["OLAZ_SLOW_CASES"] == "1"
        let url = CaseFile.casesURL(domain: domain)

        if shouldRecord {
            var recorded: [CaseJSON] = []
            for scenario in scenarios {
                let c = try await recordScenario(domain: domain, scenario)
                recorded.append(c)
            }
            try CaseFile.write(recorded, to: url)
            return
        }

        let existing = try CaseFile.load(url: url)
        let knownDiffs = try CaseFile.loadKnownDiffs()
        var usedKnownDiffs = Array(repeating: false, count: knownDiffs.count)

        var byName: [String: CaseJSON] = [:]
        for item in existing {
            if let name = item["name"]?.stringValue {
                byName[name] = item
            }
        }
        XCTAssertEqual(byName.count, scenarios.count, "\(domain).jsonl case count mismatch (run with OLAZ_RECORD=1 to regenerate)")

        var executedNames: Set<String> = []
        for scenario in scenarios {
            if scenario.slow && !runSlow {
                print("skipped slow: \(scenario.name)")
                continue
            }
            guard let expected = byName[scenario.name] else {
                XCTFail("Missing recorded case '\(scenario.name)' in \(url.path)")
                continue
            }
            executedNames.insert(scenario.name)
            let actual = try await recordScenario(domain: domain, scenario)
            let diffs = CaseFile.compareCase(
                domain: domain,
                name: scenario.name,
                expected: expected,
                actual: actual,
                knownDiffs: knownDiffs,
                usedKnownDiffs: &usedKnownDiffs
            )
            for diff in diffs {
                XCTFail("\(scenario.name): \(diff)")
            }
        }

        for stale in CaseFile.staleKnownDiffs(
            domain: domain,
            executedNames: executedNames,
            allCaseNames: Set(byName.keys),
            knownDiffs: knownDiffs,
            usedKnownDiffs: usedKnownDiffs
        ) {
            XCTFail("\(domain): stale known-diff entry \(stale)")
        }
    }

    @MainActor
    static func recordScenario(domain: String, _ scenario: ScenarioDef) async throws -> CaseJSON {
        try await RecorderSuiteLock.shared.withLock {
            try await _recordScenarioLocked(domain: domain, scenario)
        }
    }

    @MainActor
    private static func _recordScenarioLocked(domain: String, _ scenario: ScenarioDef) async throws -> CaseJSON {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-forward-recorder-\(scenario.name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let tempPhotoDir = dataDir.appendingPathComponent("fwd-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tempPhotoDir, withIntermediateDirectories: true)

        let storage = RecorderStorageIsolation(prefix: "olaz.forward-recorder")
        EngineLog.shared.onAppend = nil

        defer {
            EngineLog.shared.onAppend = nil
            storage.cleanup()
            try? FileManager.default.removeItem(at: dataDir)
        }

        let initialSecretKey = extractInitialSecretKey(from: scenario.seed)
        let wsAuthManual = scenario.seed["ws_auth"]?.stringValue == "manual"
        let server = try FakeZaloServer(
            serverScript: scenario.server,
            initialSecretKey: initialSecretKey,
            wsAuthManual: wsAuthManual
        )
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
                .replacingString(tempPhotoDir.path, with: "<tmp>")
        }

        var seededUserId: String?
        if let savedSession = scenario.seed["saved_session"], savedSession != .null {
            seededUserId = savedSession["plainAccount"]?["userId"]?.stringValue
            let sub = substituteRuntimeURLs(savedSession)
            let fileURL = dataDir.appendingPathComponent("native-session.json")
            try Data(sub.canonicalString().utf8).write(to: fileURL, options: .atomic)
        }

        if let uid = seededUserId, !uid.isEmpty {
            try await seedSQLiteStore(userId: uid, dataDir: dataDir, seed: substituteRuntimeURLs(scenario.seed))
        }

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
        if let nextClientId = scenario.seed["next_client_id"]?.int64Value {
            await engine.sessionClient.seedNextClientId(nextClientId)
        }
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
        if let contactsSeed = scenario.seed["contacts"], contactsSeed != .null {
            applyContactsSeed(substituteRuntimeURLs(contactsSeed), to: engine)
        }
        if let openConvId = scenario.seed["open_conversation_id"]?.stringValue, !openConvId.isEmpty {
            engine.openConversationId = openConvId
        }
        if let freshnessObj = scenario.seed["history_freshness"]?.objectValue {
            var map: [String: HistoryFreshness] = [:]
            for (k, v) in freshnessObj {
                switch v.stringValue {
                case "up_to_date": map[k] = .upToDate
                case "stale": map[k] = .stale
                default: break
                }
            }
            engine.historyFreshness = map
        }
        if let autoDelObj = scenario.seed["auto_delete"]?.objectValue {
            var map: [String: Int64] = [:]
            for (k, v) in autoDelObj {
                if let ttl = v.int64Value, ttl > 0 {
                    map[k] = ttl
                }
            }
            engine.autoDelete = map
        }

        // Scripted host handlers
        let e2eeQueue = scenario.seed["host_results"]?["send_e2ee_text"]?.arrayValue ?? []
        var e2eeIndex = 0
        if scenario.seed["host_results"]?["send_e2ee_text"] != nil {
            engine.sendE2EETextHostHandler = { args in
                guard e2eeIndex < e2eeQueue.count else {
                    throw ZaloSessionError(code: 500, message: "No scripted send_e2ee_text result", url: "/api/e2ee/pc/message/sms")
                }
                let item = e2eeQueue[e2eeIndex]
                e2eeIndex += 1
                if let errObj = item["error"]?.objectValue {
                    let code = Int(errObj["code"]?.int64Value ?? 500)
                    let msg = errObj["message"]?.stringValue ?? "E2EE error"
                    let url = errObj["url"]?.stringValue ?? "/api/e2ee/pc/message/sms"
                    throw ZaloSessionError(code: code, message: msg, url: url)
                }
                if let errMsg = item["error"]?.stringValue {
                    throw ZaloSessionError(code: 500, message: errMsg, url: "/api/e2ee/pc/message/sms")
                }
                let cliId = args["client_id"] as? String ?? ""
                let msgId = item["msg_id"]?.stringValue ?? cliId
                let cliMsgId = item["cli_msg_id"]?.stringValue ?? cliId
                let tsMs = item["ts_ms"]?.int64Value ?? engine.nowMs()
                return SendMessageResult(msgId: msgId, cliMsgId: cliMsgId, tsMs: tsMs)
            }
        }

        let resolveMediaQueue = scenario.seed["host_results"]?["resolve_media"]?.arrayValue ?? []
        var resolveMediaIndex = 0
        if scenario.seed["host_results"]?["resolve_media"] != nil {
            engine.resolveMediaHostHandler = { _ in
                guard resolveMediaIndex < resolveMediaQueue.count else {
                    return .unavailable
                }
                let item = resolveMediaQueue[resolveMediaIndex]
                resolveMediaIndex += 1
                switch item["state"]?.stringValue ?? "unavailable" {
                case "file", "ok":
                    if let path = item["path"]?.stringValue, path.hasPrefix("/") {
                        return .file(URL(fileURLWithPath: path))
                    }
                    return .unavailable
                case "expired":
                    return .expired
                case "unsupported":
                    return .unsupported
                default:
                    return .unavailable
                }
            }
        }

        let resolveFileQueue = scenario.seed["host_results"]?["resolve_file"]?.arrayValue ?? []
        var resolveFileIndex = 0
        if scenario.seed["host_results"]?["resolve_file"] != nil {
            engine.resolveFileHostHandler = { _ in
                guard resolveFileIndex < resolveFileQueue.count else {
                    return .failed("No scripted resolve_file result")
                }
                let item = resolveFileQueue[resolveFileIndex]
                resolveFileIndex += 1
                switch item["state"]?.stringValue ?? "failed" {
                case "ready":
                    if let path = item["path"]?.stringValue, !path.isEmpty {
                        return .ready(URL(fileURLWithPath: path))
                    }
                    return .failed("Missing staged path")
                case "expired":
                    return .expired
                default:
                    return .failed(item["message"]?.stringValue ?? "Không tải được tệp.")
                }
            }
        }

        let fetchMediaDataQueue = scenario.seed["host_results"]?["fetch_media_data"]?.arrayValue ?? []
        var fetchMediaDataIndex = 0
        if scenario.seed["host_results"]?["fetch_media_data"] != nil {
            engine.fetchMediaDataHostHandler = { _ in
                guard fetchMediaDataIndex < fetchMediaDataQueue.count else {
                    return nil
                }
                let item = fetchMediaDataQueue[fetchMediaDataIndex]
                fetchMediaDataIndex += 1
                if let utf8 = item["data_utf8"]?.stringValue {
                    return Data(utf8.utf8)
                }
                if item["ok"]?.boolValue == true {
                    return Data("fake-cdn-photo-bytes".utf8)
                }
                return nil
            }
        }

        func parseComposerOutcome(_ item: CaseJSON) -> ComposerOutcome {
            switch item["outcome"]?.stringValue ?? "failed" {
            case "done": return .done
            case "cancelled": return .cancelled
            case "pending": return .pending(item["text"]?.stringValue ?? CardActionOutcome.defaultPending)
            default: return .failed(item["text"]?.stringValue ?? ComposerOutcome.genericFailure)
            }
        }

        let sendMediaQueue = scenario.seed["host_results"]?["send_media"]?.arrayValue ?? []
        var sendMediaIndex = 0
        if scenario.seed["host_results"]?["send_media"] != nil {
            engine.sendMediaHostHandler = { _ in
                guard sendMediaIndex < sendMediaQueue.count else {
                    return .failed(ComposerOutcome.genericFailure)
                }
                let item = sendMediaQueue[sendMediaIndex]
                sendMediaIndex += 1
                return parseComposerOutcome(item)
            }
        }

        let sendFilesQueue = scenario.seed["host_results"]?["send_files"]?.arrayValue ?? []
        var sendFilesIndex = 0
        if scenario.seed["host_results"]?["send_files"] != nil {
            engine.sendFilesHostHandler = { _ in
                guard sendFilesIndex < sendFilesQueue.count else {
                    return .failed(ComposerOutcome.genericFailure)
                }
                let item = sendFilesQueue[sendFilesIndex]
                sendFilesIndex += 1
                return parseComposerOutcome(item)
            }
        }

        var fwdPhotoCounter = 0
        engine.forwardTempPhotoURL = {
            fwdPhotoCounter += 1
            return tempPhotoDir.appendingPathComponent("fwd-\(fwdPhotoCounter).jpg")
        }

        var bootstrapLogs: [String] = []
        var sendLogs: [String] = []
        var actionLogs: [String] = []
        var lastSendResult: Bool?
        var results: [String: CaseJSON] = [:]

        EngineLog.shared.onAppend = { rawLine in
            if let sp = rawLine.firstIndex(of: " ") {
                let msg = String(rawLine[rawLine.index(after: sp)...])
                if msg.hasPrefix("bootstrap: ") { bootstrapLogs.append(msg) }
                if msg.hasPrefix("sendText ") { sendLogs.append(msg) }
                if msg.hasPrefix("recall failed:") || msg.hasPrefix("react failed:") {
                    actionLogs.append(msg)
                }
            }
        }

        let suppressedTransports = Set(
            scenario.seed["suppress"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )

        var hostCalls: [CaseJSON] = []
        var hostSettleTargets: [Int] = []
        var hostCursor = 0
        var settleCount = 0
        var signalWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        func notifySignal() {
            let pending = signalWaiters
            signalWaiters.removeAll()
            for cont in pending.values {
                cont.resume()
            }
        }

        engine.traceU4HostEnabled = true
        engine.hostTrace = { name, args in
            let normalizedArgs = normalizeRecordedURLs(CaseJSON.fromAny(args))
            hostCalls.append(.object([
                "call": .string(name),
                "args": normalizedArgs,
            ]))
            hostSettleTargets.append(settleCount)
            notifySignal()
            switch name {
            case "prepare_store":
                return true
            case "apply_batch", "apply_parsed_events", "show_typing",
                 "resolve_media", "resolve_file", "fetch_media_data",
                 "send_media", "send_files", "send_e2ee_text":
                return true
            case "start_ws":
                return !suppressedTransports.contains("ws")
            case "start_long_poll":
                return !suppressedTransports.contains("long_poll")
            default:
                return false
            }
        }

        let transitionRecorder = ForwardTransitionRecorder(scenarioName: scenario.name) {
            normalizeRecordedURLs(SessionSnapshot.capture(from: engine))
        }
        engine.stateTrace = { [weak transitionRecorder] in
            transitionRecorder?.recordTransition()
        }
        engine.transportSettleTrace = {
            settleCount += 1
            notifySignal()
        }

        var snapshots: [String: CaseJSON] = [:]

        func waitForCondition(timeoutMs: Int, description: String, _ predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
            while !predicate() {
                let remaining = deadline - ContinuousClock.now
                if remaining <= .zero {
                    throw RecorderError.timeout(scenario: scenario.name, detail: "timed out waiting for \(description)")
                }
                let waiterId = UUID()
                let timeoutTask = Task { @MainActor in
                    try? await Task.sleep(for: min(remaining, .milliseconds(25)))
                    if let cont = signalWaiters.removeValue(forKey: waiterId) {
                        cont.resume()
                    }
                }
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    signalWaiters[waiterId] = cont
                }
                timeoutTask.cancel()
            }
        }

        func findMessage(convId: String, msgId: String) -> ChatMessage? {
            engine.messages[convId]?.first(where: { $0.id == msgId || $0.clientId == msgId })
        }

        do {
            for (stepIndex, step) in scenario.steps.enumerated() {
                if let cmd = step["cmd"]?.stringValue {
                    let args = step["args"]
                    let fixedNowMs = step["now_ms"]?.int64Value
                    var keepNowMsForAsync = false
                    if let fixedNowMs {
                        engine.nowMs = { fixedNowMs }
                    }
                    defer {
                        if fixedNowMs != nil && !keepNowMsForAsync {
                            engine.nowMs = { Int64(Date().timeIntervalSince1970 * 1000) }
                        }
                    }

                    switch cmd {
                    case "start":
                        engine.start()
                    case "open":
                        _ = await engine.bootTask?.value
                        let id = args?["id"]?.stringValue ?? ""
                        engine.openConversation(id)
                        _ = await engine.openConversationTask?.value
                        await engine.awaitMarkReadTasksForRecording()
                        _ = await engine.persistConversationsTask?.value
                        await engine.settleForRecording()
                    case "close":
                        _ = await engine.bootTask?.value
                        engine.closeConversation()
                        await engine.settleForRecording()
                    case "apply_batch":
                        _ = await engine.bootTask?.value
                        let payloadJSON = substituteRuntimeURLs(args?["payload"] ?? .object([:]))
                        let payloadData = Data(payloadJSON.canonicalString().utf8)
                        let payload = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any] ?? [:]
                        let defaultCmd = UInt16(args?["default_cmd"]?.int64Value ?? 501)
                        let fallbackConvId = args?["fallback_conv_id"]?.stringValue
                        let isGroupHint = args?["is_group_hint"]?.boolValue ?? false
                        let incrementUnread = args?["increment_unread"]?.boolValue ?? false
                        let notifyIncoming = args?["notify_incoming"]?.boolValue ?? false
                        let persistConvs = args?["persist_conversations"]?.boolValue ?? true
                        let probeFreshness = args?["probe_freshness"]?.boolValue ?? false
                        _ = await engine.applyBatchResponse(
                            payload,
                            defaultCmd: defaultCmd,
                            fallbackConvId: fallbackConvId,
                            isGroupHint: isGroupHint,
                            incrementUnread: incrementUnread,
                            notifyIncoming: notifyIncoming,
                            persistConversations: persistConvs,
                            probeFreshness: probeFreshness
                        )
                        _ = await engine.persistConversationsTask?.value
                    case "send_text":
                        _ = await engine.bootTask?.value
                        let id = args?["id"]?.stringValue ?? ""
                        let text = args?["text"]?.stringValue ?? ""
                        let quoteId = args?["quote_id"]?.stringValue
                        let mentions: [Mention] = (args?["mentions"]?.arrayValue ?? []).compactMap { m in
                            guard let uid = m["uid"]?.stringValue else { return nil }
                            return Mention(
                                uid: uid,
                                pos: Int(m["pos"]?.int64Value ?? 0),
                                len: Int(m["len"]?.int64Value ?? 0),
                                isAll: m["is_all"]?.boolValue ?? false
                            )
                        }
                        let styles: [TextStyle] = (args?["styles"]?.arrayValue ?? []).compactMap { s in
                            guard let st = s["st"]?.stringValue else { return nil }
                            return TextStyle(
                                start: Int(s["start"]?.int64Value ?? 0),
                                len: Int(s["len"]?.int64Value ?? 0),
                                st: st
                            )
                        }
                        let urgency = Int(args?["urgency"]?.int64Value ?? 0)
                        let isAsync = args?["async"]?.boolValue ?? false
                        if isAsync {
                            let heldBefore = server.heldHTTPCount()
                            var completed = false
                            let task = Task { @MainActor in
                                let ok = await engine.sendText(
                                    text,
                                    to: id,
                                    quoting: quoteId,
                                    mentions: mentions,
                                    styles: styles,
                                    urgency: urgency
                                )
                                completed = true
                                notifySignal()
                                return ok
                            }
                            engine.activeSendTask = task
                            let reachedHeld = await server.waitForHeldHTTPRequests(atLeast: heldBefore + 1, timeoutMs: 2000)
                            if !reachedHeld && !completed {
                                try await waitForCondition(timeoutMs: 2000, description: "async send_text to hold or finish") {
                                    completed || server.heldHTTPCount() > heldBefore
                                }
                            }
                            if completed {
                                lastSendResult = await task.value
                                engine.activeSendTask = nil
                                _ = await engine.persistConversationsTask?.value
                            } else {
                                keepNowMsForAsync = true
                            }
                        } else {
                            let ok = await engine.sendText(
                                text,
                                to: id,
                                quoting: quoteId,
                                mentions: mentions,
                                styles: styles,
                                urgency: urgency
                            )
                            lastSendResult = ok
                            _ = await engine.persistConversationsTask?.value
                        }
                    case "await_send":
                        if let task = engine.activeSendTask {
                            lastSendResult = await task.value
                            engine.activeSendTask = nil
                        }
                        _ = await engine.persistConversationsTask?.value
                        engine.nowMs = { Int64(Date().timeIntervalSince1970 * 1000) }
                    case "request_forward":
                        _ = await engine.bootTask?.value
                        let convId = args?["conv_id"]?.stringValue ?? ""
                        let msgId = args?["msg_id"]?.stringValue ?? ""
                        guard let msg = findMessage(convId: convId, msgId: msgId) else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "request_forward missing msg \(msgId) in \(convId)")
                        }
                        engine.requestForward(msg)
                    case "select":
                        _ = await engine.bootTask?.value
                        let convId = args?["conv_id"]?.stringValue ?? ""
                        let ids = args?["ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
                        if ids.isEmpty {
                            engine.endSelection()
                        } else {
                            guard let firstMsg = findMessage(convId: convId, msgId: ids[0]) else {
                                throw RecorderError.invalidStep(scenario: scenario.name, detail: "select missing first msg \(ids[0]) in \(convId)")
                            }
                            engine.beginSelection(firstMsg)
                            for id in ids.dropFirst() {
                                engine.toggleSelection(id)
                            }
                        }
                    case "forward_selection":
                        _ = await engine.bootTask?.value
                        engine.forwardSelection()
                    case "forward":
                        _ = await engine.bootTask?.value
                        let convId = args?["conv_id"]?.stringValue ?? ""
                        let msgId = args?["msg_id"]?.stringValue ?? ""
                        let targets = args?["targets"]?.arrayValue?.compactMap(\.stringValue) ?? []
                        guard let msg = findMessage(convId: convId, msgId: msgId) else {
                            throw RecorderError.invalidStep(scenario: scenario.name, detail: "forward missing msg \(msgId) in \(convId)")
                        }
                        let outcome = await engine.forward(msg, to: targets)
                        await engine.settleForRecording()
                        _ = await engine.persistConversationsTask?.value
                        results["\(stepIndex)"] = ForwardSnapshot.encodeOutcome(outcome)
                    case "forward_all":
                        _ = await engine.bootTask?.value
                        let targets = args?["targets"]?.arrayValue?.compactMap(\.stringValue) ?? []
                        let outcome = await engine.forwardAll(to: targets)
                        await engine.settleForRecording()
                        _ = await engine.persistConversationsTask?.value
                        results["\(stepIndex)"] = ForwardSnapshot.encodeOutcome(outcome)
                    default:
                        throw RecorderError.invalidStep(scenario: scenario.name, detail: "Unknown cmd: \(cmd)")
                    }
                } else if let pred = step["await"] {
                    let timeoutMs = Int(step["timeout_ms"]?.int64Value ?? 5000)
                    try await transitionRecorder.awaitPredicate(pred, timeoutMs: timeoutMs)
                } else if let targetCall = step["await_host"]?.stringValue {
                    let timeoutMs = Int(step["timeout_ms"]?.int64Value ?? 5000)
                    var matchedIdx: Int?
                    try await waitForCondition(timeoutMs: timeoutMs, description: "host call '\(targetCall)'") {
                        if let idx = (hostCursor..<hostCalls.count).first(where: {
                            hostCalls[$0]["call"]?.stringValue == targetCall
                        }) {
                            matchedIdx = idx
                            return true
                        }
                        return false
                    }
                    if let idx = matchedIdx {
                        hostCursor = idx + 1
                        if targetCall == "apply_parsed_events" || targetCall == "apply_batch" {
                            let targetSettle = hostSettleTargets[idx] + 1
                            try await waitForCondition(timeoutMs: timeoutMs, description: "settle after '\(targetCall)'") {
                                settleCount >= targetSettle
                            }
                        }
                    }
                } else if let pushCount = step["ws_push"]?.int64Value {
                    let timeoutMs = Int(step["timeout_ms"]?.int64Value ?? 5000)
                    do {
                        try await server.pushWebSocketActions(count: Int(pushCount), timeoutMs: timeoutMs)
                    } catch {
                        throw RecorderError.timeout(scenario: scenario.name, detail: "\(error)")
                    }
                } else if let releaseCount = step["http_release"]?.int64Value {
                    let timeoutMs = Int(step["timeout_ms"]?.int64Value ?? 5000)
                    do {
                        try await server.releaseHeldHTTPResponses(count: Int(releaseCount), timeoutMs: timeoutMs)
                    } catch {
                        throw RecorderError.timeout(scenario: scenario.name, detail: "\(error)")
                    }
                } else if let label = step["snapshot"]?.stringValue {
                    await engine.settleForRecording()
                    await Task.yield()
                    let snap = await ForwardSnapshot.capture(
                        from: engine,
                        bootstrapLogs: bootstrapLogs,
                        lastSendResult: lastSendResult,
                        sendLogs: sendLogs,
                        actionLogs: actionLogs,
                        results: results
                    )
                    snapshots[label] = normalizeRecordedURLs(snap)
                } else {
                    throw RecorderError.invalidStep(scenario: scenario.name, detail: "Unknown step: \(step.canonicalString())")
                }
            }

            _ = await engine.bootTask?.value
            _ = await engine.openConversationTask?.value
            _ = await engine.loadOlderTask?.value
            if let task = engine.activeSendTask {
                lastSendResult = await task.value
                engine.activeSendTask = nil
            }
            await engine.awaitMarkReadTasksForRecording()
            await engine.awaitNotifyTypingTaskForRecording()
            await engine.awaitMessageActionTasksForRecording()
            _ = await engine.persistConversationsTask?.value
            _ = await engine.pendingCleanupTask?.value
            await server.waitForScriptedRequests(timeoutMs: 2000)
            if !suppressedTransports.contains("ws") {
                try? await Task.sleep(for: .milliseconds(50))
            }
            await engine.settleForRecording()
            await Task.yield()

            try assertOnlyLocalFakeHosts(await engine.sessionClient.domains, scenario: scenario.name, stage: "final")

            let finalState = normalizeRecordedURLs(
                await ForwardSnapshot.capture(
                    from: engine,
                    bootstrapLogs: bootstrapLogs,
                    lastSendResult: lastSendResult,
                    sendLogs: sendLogs,
                    actionLogs: actionLogs,
                    results: results
                )
            )
            let requests = server.canonicalRequests().map { normalizeRecordedURLs($0) }

            engine.cancelTasksForRecording()
            engine.transportSettleTrace = nil
            server.stop()
            await engine.finishTearDownForRecording()

            if server.hadUnscriptedRequest {
                let unscripted = requests.filter { $0["unscripted"]?.boolValue == true }
                throw RecorderError.unscriptedRequest(scenario: scenario.name, detail: CaseJSON.array(unscripted).canonicalString())
            }

            var caseDict: [String: CaseJSON] = [
                "format": .int(1),
                "domain": .string(domain),
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
            let pending = signalWaiters
            signalWaiters.removeAll()
            for cont in pending.values { cont.resume() }
            engine.cancelTasksForRecording()
            engine.transportSettleTrace = nil
            server.stop()
            await engine.finishTearDownForRecording()
            throw error
        }
    }

    // MARK: - Seed & Script Helpers

    private static func seedSQLiteStore(userId: String, dataDir: URL, seed: CaseJSON) async throws {
        let dbURL = dataDir
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(userId, isDirectory: true)
            .appendingPathComponent("history.sqlite3")
        let store = try ZaloSQLiteStore(path: dbURL.path)
        try await store.setPreferenceString(key: ZaloWebKitMigrator.donePrefKey, value: "1")

        if let val = seed["did_offer_initial_sync"]?.stringValue {
            try await store.setPreferenceString(key: "didOfferInitialSync", value: val)
        }
        if let val = seed["history_full_refresh_at"]?.stringValue {
            try await store.setPreferenceString(key: ZaloEngine.fullHistoryRefreshKey, value: val)
        } else if let n = seed["history_full_refresh_at"]?.int64Value {
            try await store.setPreferenceString(key: ZaloEngine.fullHistoryRefreshKey, value: "\(n)")
        }
        if let hiddenPinMD5 = seed["hidden_pin_md5"]?.stringValue {
            try await store.setPreferenceString(key: "hiddenPinMD5", value: hiddenPinMD5)
        }
        if let hiddenPinHash = seed["hidden_pin_hash"]?.stringValue {
            try await store.setPreferenceString(key: "hiddenPinHash", value: hiddenPinHash)
        }
        if let labelsPref = seed["labels_pref"], labelsPref != .null {
            try await store.setPreferenceData(key: "labels", data: Data(labelsPref.canonicalString().utf8))
        }
        if let prefsObj = seed["prefs"]?.objectValue {
            for (k, v) in prefsObj {
                if let s = v.stringValue {
                    try await store.setPreferenceString(key: k, value: s)
                }
            }
        }
        if let pinned = seed["pinned_ids"]?.arrayValue?.compactMap(\.stringValue) {
            try await store.setPreferenceStrings(key: "pinnedIds", value: pinned)
        }
        if let unreadMarks = seed["unread_marks"]?.arrayValue?.compactMap(\.stringValue) {
            try await store.setPreferenceStrings(key: "unreadMarks", value: unreadMarks)
        }
        if let hidden = seed["hidden_ids"]?.arrayValue?.compactMap(\.stringValue) {
            try await store.setPreferenceStrings(key: "hiddenIds", value: hidden)
        }
        if let starred = seed["starred_ids"]?.arrayValue?.compactMap(\.stringValue) {
            try await store.setPreferenceStrings(key: "starredIds", value: starred)
        }
        if let seenReactions = seed["seen_reaction_event_ids"]?.arrayValue?.compactMap(\.stringValue) {
            try await store.setPreferenceStrings(key: "seenReactionEventIds", value: seenReactions)
        }
        if let e2eeThreads = seed["e2ee_threads"]?.arrayValue?.compactMap(\.stringValue) {
            try await store.setPreferenceStrings(key: "e2eeThreadsV1", value: e2eeThreads)
        }
        if let ranks = seed["activity_ranks"], ranks != .null {
            try await store.setPreferenceData(key: "activityRanks", data: Data(ranks.canonicalString().utf8))
        }
        if let archived = seed["archived_ids"]?.arrayValue?.compactMap(\.stringValue) {
            try await store.setPreferenceStrings(key: "archivedIds", value: archived)
        }
        if let aliases = seed["aliases"], aliases != .null {
            try await store.setPreferenceData(key: "aliases", data: Data(aliases.canonicalString().utf8))
        }
        if let contacts = seed["contacts"] {
            if let aliases = contacts["aliases"], aliases != .null {
                try await store.setPreferenceData(key: "aliases", data: Data(aliases.canonicalString().utf8))
            }
            if let profiles = contacts["cached_profiles"], profiles != .null {
                try await store.setPreferenceData(key: "cachedProfiles", data: Data(profiles.canonicalString().utf8))
            }
            if let groups = contacts["cached_groups"], groups != .null {
                try await store.setPreferenceData(key: "cachedGroups", data: Data(groups.canonicalString().utf8))
            }
            if let gids = contacts["friend_global_ids"], gids != .null {
                try await store.setPreferenceData(key: "gidToUidMap", data: Data(gids.canonicalString().utf8))
            }
        }
        if let convs = seed["local_conversations"]?.arrayValue {
            let stored = convs.compactMap { row -> StoredConversation? in
                guard let id = row["id"]?.stringValue else { return nil }
                return StoredConversation(
                    id: id,
                    isGroup: row["is_group"]?.boolValue ?? false,
                    name: row["name"]?.stringValue ?? id,
                    avatar: row["avatar"]?.stringValue ?? "",
                    pinned: row["pinned"]?.boolValue ?? false,
                    members: Int(row["members"]?.int64Value ?? 0),
                    unread: Int(row["unread"]?.int64Value ?? 0),
                    previewText: row["preview_text"]?.stringValue ?? "",
                    previewTsMs: row["preview_ts_ms"]?.int64Value ?? 0,
                    previewFromMe: row["preview_from_me"]?.boolValue ?? false,
                    updatedAtMs: row["updated_at_ms"]?.int64Value ?? 0
                )
            }
            try await store.saveConversations(stored)
        }
        if let msgs = seed["local_messages"]?.arrayValue {
            let stored = msgs.compactMap { row -> StoredMessage? in
                guard let id = row["id"]?.stringValue, let convId = row["conv_id"]?.stringValue else { return nil }
                let status = row["status"]?.stringValue ?? "sent"
                let rawJSON: Data = {
                    if let rawObj = row["raw_json"], rawObj != .null {
                        return Data(rawObj.canonicalString().utf8)
                    }
                    var obj: [String: CaseJSON] = [
                        "id": .string(id),
                        "conversationId": .string(convId),
                        "clientId": .string(row["client_id"]?.stringValue ?? id),
                        "senderId": .string(row["sender_id"]?.stringValue ?? ""),
                        "senderName": .string(row["sender_name"]?.stringValue ?? ""),
                        "senderAvatar": .string(row["sender_avatar"]?.stringValue ?? ""),
                        "isMine": .bool(row["is_mine"]?.boolValue ?? false),
                        "text": .string(row["text"]?.stringValue ?? ""),
                        "date": .int(row["ts_ms"]?.int64Value ?? 0),
                        "status": .string(status),
                        "isE2EE": .bool(row["is_e2ee"]?.boolValue ?? false),
                        "kind": .object(["type": .string(row["kind_tag"]?.stringValue ?? "text")]),
                    ]
                    if let reactions = row["reactions"], reactions != .null {
                        obj["reactions"] = reactions
                    }
                    return Data(CaseJSON.object(obj).canonicalString().utf8)
                }()
                return StoredMessage(
                    id: id,
                    convId: convId,
                    clientId: row["client_id"]?.stringValue ?? id,
                    senderId: row["sender_id"]?.stringValue ?? "",
                    senderName: row["sender_name"]?.stringValue ?? "",
                    senderAvatar: row["sender_avatar"]?.stringValue ?? "",
                    isMine: row["is_mine"]?.boolValue ?? false,
                    text: row["text"]?.stringValue ?? "",
                    kindTag: row["kind_tag"]?.stringValue ?? "text",
                    tsMs: row["ts_ms"]?.int64Value ?? 0,
                    status: status,
                    rawJSONData: rawJSON
                )
            }
            try await store.saveMessages(stored)
        }
        await store.close()
    }

    @MainActor
    private static func applyContactsSeed(_ contacts: CaseJSON, to engine: ZaloEngine) {
        if let loaded = contacts["friends_loaded"]?.boolValue {
            engine.contacts.friendsLoaded = loaded
        }
        if let loaded = contacts["groups_loaded"]?.boolValue {
            engine.contacts.groupsLoaded = loaded
        }
        if let friendsArr = contacts["friends"]?.arrayValue {
            engine.contacts.friends = friendsArr.compactMap { row in
                guard let id = row["id"]?.stringValue else { return nil }
                let name = row["name"]?.stringValue ?? id
                let zaloName = row["zalo_name"]?.stringValue ?? name
                let avatar = row["avatar"]?.stringValue.flatMap(URL.init(string:))
                let lastActive = row["last_active_ms"]?.int64Value.map { Date(timeIntervalSince1970: Double($0) / 1000.0) }
                let online = row["online"]?.boolValue ?? false
                let section = row["section"]?.stringValue ?? String(name.prefix(1)).uppercased()
                let sortKey = row["sort_key"]?.stringValue ?? name.lowercased()
                return ContactsState.Friend(
                    id: id,
                    name: name,
                    zaloName: zaloName,
                    avatar: avatar,
                    lastActive: lastActive,
                    online: online,
                    section: section.isEmpty ? "#" : section,
                    sortKey: sortKey
                )
            }
        }
        if let groupsArr = contacts["groups"]?.arrayValue {
            engine.contacts.groups = groupsArr.compactMap { row in
                guard let id = row["id"]?.stringValue else { return nil }
                let name = row["name"]?.stringValue ?? id
                let avatar = row["avatar"]?.stringValue.flatMap(URL.init(string:))
                let members = Int(row["members"]?.int64Value ?? 0)
                let sortKey = row["sort_key"]?.stringValue ?? name.lowercased()
                return ContactsState.Group(
                    id: id,
                    name: name,
                    avatar: avatar,
                    members: members,
                    sortKey: sortKey
                )
            }
        }
    }

    private static func extractInitialSecretKey(from seed: CaseJSON) -> Data? {
        guard let enk = seed["saved_session"]?["plainAccount"]?["zpwEnk"]?.stringValue,
              !enk.isEmpty else { return nil }
        let key = ZaloCrypto.parseSecretKey(enk)
        return (key.count == 16 || key.count == 32) ? key : nil
    }

    private static func defaultFakeDomainsJSON() -> CaseJSON {
        var candidates: [String: CaseJSON] = [:]
        for key in ZaloDomains.defaultServiceMapV3.keys {
            candidates[key] = .array([.string("http://fake")])
        }
        return .object([
            "auth": .string("http://fake"),
            "lpChat": .string("http://fake"),
            "lpControl": .string("http://fake"),
            "wpaChat": .string("http://fake"),
            "ws": .array([.string("ws://fake")]),
            "serviceCandidates": .object(candidates),
            "preferredHosts": .object([:]),
            "isolated": .bool(true),
        ])
    }

    private static func assertOnlyLocalFakeHosts(_ domains: ZaloDomains, scenario: String, stage: String) throws {
        let urls = [domains.auth, domains.lpChat, domains.lpControl, domains.wpaChat]
            + domains.ws
            + domains.serviceCandidates.values.flatMap { $0 }
            + domains.preferredHosts.values
        for raw in urls {
            guard let parsed = URL(string: raw),
                  let host = parsed.host?.lowercased(),
                  host == "127.0.0.1" || host == "localhost" || host == "fake" else {
                throw RecorderError.invalidSeed(scenario: scenario, detail: "Non-local host '\(raw)' at \(stage)")
            }
        }
        guard domains.isolated else {
            throw RecorderError.invalidSeed(scenario: scenario, detail: "domains.isolated must be true at \(stage)")
        }
    }
}
