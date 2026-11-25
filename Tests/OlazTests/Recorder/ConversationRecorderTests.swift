import Foundation
import XCTest
@testable import Olaz

final class ConversationRecorderTests: XCTestCase {
    func testConversationsCases() async throws {
        try await runDomainSuite(
            domain: "conversations",
            scenarios: Self.conversationsScenarios()
        )
    }

    func testConversationActionsCases() async throws {
        try await runDomainSuite(
            domain: "conversation_actions",
            scenarios: Self.conversationActionsScenarios()
        )
    }

    // MARK: - Suite Runner

    private func runDomainSuite(domain: String, scenarios: [ScenarioDef]) async throws {
        let shouldRecord = ProcessInfo.processInfo.environment["OLAZ_RECORD"] == "1"
        let runSlow = shouldRecord || ProcessInfo.processInfo.environment["OLAZ_SLOW_CASES"] == "1"
        let url = CaseFile.casesURL(domain: domain)

        if shouldRecord {
            var recorded: [CaseJSON] = []
            for scenario in scenarios {
                let c = try await Self.recordScenario(domain: domain, scenario)
                recorded.append(c)
            }
            try CaseFile.write(recorded, to: url)
            return
        }

        let existing = try CaseFile.load(url: url)
        var byName: [String: CaseJSON] = [:]
        for item in existing {
            if let name = item["name"]?.stringValue {
                byName[name] = item
            }
        }
        XCTAssertEqual(byName.count, scenarios.count, "\(domain).jsonl case count mismatch (run with OLAZ_RECORD=1 to regenerate)")

        let knownDiffs = try CaseFile.loadKnownDiffs()
        var usedKnownDiffs = Array(repeating: false, count: knownDiffs.count)
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
            let actual = try await Self.recordScenario(domain: domain, scenario)
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
            XCTFail(stale)
        }
    }

    // MARK: - Harness

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
    static func recordScenario(domain: String, _ scenario: ScenarioDef) async throws -> CaseJSON {
        try await RecorderSuiteLock.shared.withLock {
            try await recordScenarioLocked(domain: domain, scenario)
        }
    }

    @MainActor
    private static func recordScenarioLocked(domain: String, _ scenario: ScenarioDef) async throws -> CaseJSON {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-conv-recorder-\(scenario.name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let storage = RecorderStorageIsolation(prefix: "olaz.conv-recorder")

        defer {
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
        }

        // Seed saved_session file if provided.
        var seededUserId: String?
        if let savedSession = scenario.seed["saved_session"], savedSession != .null {
            seededUserId = savedSession["plainAccount"]?["userId"]?.stringValue
            let sub = substituteRuntimeURLs(savedSession)
            let fileURL = dataDir.appendingPathComponent("native-session.json")
            try Data(sub.canonicalString().utf8).write(to: fileURL, options: .atomic)
        }

        // Seed SQLite store before boot when userId is known.
        if let uid = seededUserId, !uid.isEmpty {
            try await seedSQLiteStore(userId: uid, dataDir: dataDir, seed: substituteRuntimeURLs(scenario.seed))
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
        if let contactsSeed = scenario.seed["contacts"], contactsSeed != .null {
            applyContactsSeed(substituteRuntimeURLs(contactsSeed), to: engine)
        }
        if let openConvId = scenario.seed["open_conversation_id"]?.stringValue, !openConvId.isEmpty {
            engine.openConversationId = openConvId
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
            case "apply_batch", "apply_parsed_events":
                return true
            case "start_ws":
                return !suppressedTransports.contains("ws")
            case "start_long_poll":
                return !suppressedTransports.contains("long_poll")
            default:
                return false
            }
        }

        let transitionRecorder = ConvTransitionRecorder(scenarioName: scenario.name) {
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
        var lastPinBoard: PinBoard?
        var lastActionResult: ConversationActionResult?

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

        func waitForAsyncUIAction(timeoutMs: Int = 5000, prevToastSeq: Int?, prevPrompt: ConversationPrompt?, trigger: () -> Void) async throws {
            trigger()
            let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
            while true {
                if engine.conversationUI.toast?.seq != prevToastSeq {
                    return
                }
                if case .pinBoard = engine.conversationPrompt, engine.conversationPrompt != prevPrompt {
                    return
                }
                if ContinuousClock.now >= deadline {
                    throw RecorderError.timeout(scenario: scenario.name, detail: "timed out awaiting async conversation UI action")
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        do {
            for step in scenario.steps {
                if let cmd = step["cmd"]?.stringValue {
                    let args = step["args"]
                    let savedNowMs = engine.nowMs
                    let savedRandomTag4 = engine.randomTag4
                    if let ms = step["now_ms"]?.int64Value {
                        engine.nowMs = { ms }
                    }
                    if let r4 = step["rand4"]?.stringValue {
                        engine.randomTag4 = { r4 }
                    }
                    defer {
                        engine.nowMs = savedNowMs
                        engine.randomTag4 = savedRandomTag4
                    }
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
                        let reason = args?["reason"]?.stringValue ?? ""
                        engine.handleSessionExpiredNotice(reason)
                        transitionRecorder.advanceSearchToLatestSyncState()
                    case "drain_chat_polling":
                        _ = await engine.bootTask?.value
                        let maxBatches = Int(args?["max_batches"]?.int64Value ?? 3)
                        let notifyIncoming = args?["notify_incoming"]?.boolValue ?? false
                        _ = await engine.drainChatPolling(maxBatches: maxBatches, notifyIncoming: notifyIncoming)
                    case "apply_batch":
                        _ = await engine.bootTask?.value
                        let payload = substituteRuntimeURLs(args?["payload"] ?? .object([:])).toFoundation()
                        let defaultCmd = UInt16(args?["default_cmd"]?.int64Value ?? 0)
                        let fallbackConvId = args?["fallback_conv_id"]?.stringValue
                        let isGroupHint = args?["is_group_hint"]?.boolValue
                        let incrementUnread = args?["increment_unread"]?.boolValue ?? false
                        let notifyIncoming = args?["notify_incoming"]?.boolValue ?? false
                        let persistConvs = args?["persist_conversations"]?.boolValue ?? true
                        _ = await engine.applyBatchResponse(
                            payload,
                            defaultCmd: defaultCmd,
                            fallbackConvId: fallbackConvId,
                            isGroupHint: isGroupHint,
                            incrementUnread: incrementUnread,
                            notifyIncoming: notifyIncoming,
                            persistConversations: persistConvs
                        )
                    case "ensure_known_contacts":
                        engine.ensureKnownContactsInConversations()
                        engine.rebuildConversationFlags()
                        engine.rebuildConversationExtras()
                    case "resolve_missing_names":
                        await engine.resolveMissingConversationNames()
                    case "refresh_mention_previews":
                        await engine.refreshMentionPreviews()
                    case "update_contacts":
                        if let contactsArg = args {
                            applyContactsSeed(substituteRuntimeURLs(contactsArg), to: engine)
                        }
                    case "open_conversation":
                        if args?["load"]?.boolValue == true, let id = args?["id"]?.stringValue {
                            let prevCount = server.httpRequestCount(path: "/api/preloadconvers/get-last-msgs")
                            engine.openConversation(id)
                            await server.waitForHTTPRequests(path: "/api/preloadconvers/get-last-msgs", atLeast: prevCount + 1, timeoutMs: 2000)
                            try? await Task.sleep(for: .milliseconds(40))
                        } else {
                            engine.openConversationId = args?["id"]?.stringValue
                        }
                    case "pin":
                        let id = args?["id"]?.stringValue ?? ""
                        let prevSeq = engine.conversationUI.toast?.seq
                        let prevPrompt = engine.conversationPrompt
                        try await waitForAsyncUIAction(prevToastSeq: prevSeq, prevPrompt: prevPrompt) {
                            engine.pinConversation(id)
                        }
                    case "unpin":
                        let id = args?["id"]?.stringValue ?? ""
                        let prevSeq = engine.conversationUI.toast?.seq
                        let prevPrompt = engine.conversationPrompt
                        try await waitForAsyncUIAction(prevToastSeq: prevSeq, prevPrompt: prevPrompt) {
                            engine.unpinConversation(id)
                        }
                    case "pin_board":
                        let id = args?["id"]?.stringValue ?? ""
                        lastPinBoard = await engine.pinBoard(for: id)
                    case "pin_replacing":
                        let unpinIds = args?["unpin"]?.arrayValue?.compactMap(\.stringValue) ?? []
                        let id = args?["id"]?.stringValue ?? ""
                        lastActionResult = await engine.pinReplacing(unpinIds, pinning: id)
                    case "move":
                        let id = args?["id"]?.stringValue ?? ""
                        let toOther = args?["to_other"]?.boolValue ?? true
                        let prevSeq = engine.conversationUI.toast?.seq
                        let prevPrompt = engine.conversationPrompt
                        try await waitForAsyncUIAction(prevToastSeq: prevSeq, prevPrompt: prevPrompt) {
                            engine.moveConversation(id, toOther: toOther)
                        }
                    case "request_delete":
                        let id = args?["id"]?.stringValue ?? ""
                        engine.requestDeleteConversation(id)
                    case "confirm_delete":
                        let id = args?["id"]?.stringValue ?? ""
                        let prevSeq = engine.conversationUI.toast?.seq
                        let prevPrompt = engine.conversationPrompt
                        try await waitForAsyncUIAction(prevToastSeq: prevSeq, prevPrompt: prevPrompt) {
                            engine.confirmDeleteConversation(id)
                        }
                    case "mark_read":
                        let id = args?["id"]?.stringValue ?? ""
                        let hadUnreadMark = engine.cachedUnreadMarks.contains(id)
                        let prevRemoveCount = server.httpRequestCount(path: "/api/conv/removeUnreadMark")
                        engine.markConversationRead(id)
                        if hadUnreadMark {
                            await server.waitForHTTPRequests(path: "/api/conv/removeUnreadMark", atLeast: prevRemoveCount + 1, timeoutMs: 2000)
                        }
                        try? await Task.sleep(for: .milliseconds(30))
                    case "mark_unread":
                        let id = args?["id"]?.stringValue ?? ""
                        let prevAddCount = server.httpRequestCount(path: "/api/conv/addUnreadMark")
                        engine.markConversationUnread(id)
                        await server.waitForHTTPRequests(path: "/api/conv/addUnreadMark", atLeast: prevAddCount + 1, timeoutMs: 2000)
                        try? await Task.sleep(for: .milliseconds(30))
                    case "hide":
                        let id = args?["id"]?.stringValue ?? ""
                        let pin = args?["pin"]?.stringValue ?? ""
                        lastActionResult = await engine.hideConversation(id, pin: pin)
                    case "hide_new_pin":
                        let id = args?["id"]?.stringValue ?? ""
                        let pin = args?["pin"]?.stringValue ?? ""
                        lastActionResult = await engine.hideConversation(id, settingNewPIN: pin)
                    case "unhide":
                        let id = args?["id"]?.stringValue ?? ""
                        let pin = args?["pin"]?.stringValue
                        lastActionResult = await engine.unhideConversation(id, pin: pin)
                    case "set_pin":
                        let pin = args?["pin"]?.stringValue ?? ""
                        let changed = args?["changed"]?.boolValue ?? false
                        lastActionResult = await engine.setHiddenChatPIN(pin, changed: changed)
                    case "reset_pin":
                        lastActionResult = await engine.resetHiddenChatPIN()
                    case "sync_hidden":
                        await engine.syncHiddenConversations()
                    case "apply_server_hidden":
                        let pin = args?["pin"]?.stringValue ?? ""
                        let ids = args?["thread_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
                        await engine.applyServerHiddenConversations(HiddenConversationsSnapshot(pin: pin, threadIds: ids))
                    case "hidden_search":
                        let query = args?["query"]?.stringValue ?? ""
                        _ = await engine.hiddenConversations(matching: query)
                    case "unlock_from_pin_search":
                        let id = args?["id"]?.stringValue ?? ""
                        _ = engine.unlockFromPINSearch(id)
                    case "relock_hidden":
                        engine.conversationUI.relock()
                    case "handle_conversation_actions":
                        let stateObj = args?["state"]?.toFoundation() as? [String: Any] ?? [:]
                        engine.handleConversationActions(state: stateObj)
                    case "label_create":
                        let name = args?["name"]?.stringValue ?? ""
                        let colorHex = args?["color_hex"]?.stringValue ?? "#0068FF"
                        let convIds = args?["conversation_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
                        let prevLabelCount = server.httpRequestCount(path: "/api/convlabel/update")
                        engine.createConversationLabel(name: name, colorHex: colorHex, conversationIds: convIds)
                        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            await server.waitForHTTPRequests(path: "/api/convlabel/update", atLeast: prevLabelCount + 1, timeoutMs: 2000)
                        }
                        try? await Task.sleep(for: .milliseconds(30))
                    case "label_update":
                        let id = args?["id"]?.stringValue ?? ""
                        let name = args?["name"]?.stringValue ?? ""
                        let colorHex = args?["color_hex"]?.stringValue ?? "#0068FF"
                        let prevLabelCount = server.httpRequestCount(path: "/api/convlabel/update")
                        engine.updateConversationLabel(id, name: name, colorHex: colorHex)
                        await server.waitForHTTPRequests(path: "/api/convlabel/update", atLeast: prevLabelCount + 1, timeoutMs: 2000)
                        try? await Task.sleep(for: .milliseconds(30))
                    case "label_delete":
                        let id = args?["id"]?.stringValue ?? ""
                        let prevLabelCount = server.httpRequestCount(path: "/api/convlabel/update")
                        engine.deleteConversationLabel(id)
                        await server.waitForHTTPRequests(path: "/api/convlabel/update", atLeast: prevLabelCount + 1, timeoutMs: 2000)
                        try? await Task.sleep(for: .milliseconds(30))
                    case "label_assign":
                        let convId = args?["conversation_id"]?.stringValue ?? ""
                        let labelId = args?["label_id"]?.stringValue
                        let prevLabelCount = server.httpRequestCount(path: "/api/convlabel/update")
                        engine.setConversationLabel(convId, labelId: labelId)
                        await server.waitForHTTPRequests(path: "/api/convlabel/update", atLeast: prevLabelCount + 1, timeoutMs: 2000)
                        try? await Task.sleep(for: .milliseconds(30))
                    case "label_reorder":
                        let ids = args?["ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
                        let prevLabelCount = server.httpRequestCount(path: "/api/convlabel/update")
                        engine.reorderConversationLabels(ids)
                        await server.waitForHTTPRequests(path: "/api/convlabel/update", atLeast: prevLabelCount + 1, timeoutMs: 2000)
                        try? await Task.sleep(for: .milliseconds(30))
                    case "set_filter":
                        let typeVal = Int(args?["type"]?.int64Value ?? 0)
                        let labelIds = args?["label_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
                        if let filter = ConversationTypeFilter(rawValue: typeVal) {
                            engine.setConversationFilter(filter, labelIds: labelIds)
                        }
                    case "sync_labels":
                        await engine.syncConversationLabelsFromServer()
                    case "handle_conversation_extras":
                        _ = await engine.bootTask?.value
                        await server.waitForScriptedRequests(timeoutMs: 2000)
                        await engine.settleForRecording()
                        let stateObj = args?["state"]?.toFoundation() as? [String: Any] ?? [:]
                        engine.handleConversationExtras(state: stateObj)
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
                } else if let label = step["snapshot"]?.stringValue {
                    await engine.settleForRecording()
                    await Task.yield()
                    let snap = await ConversationSnapshot.capture(
                        from: engine,
                        pinBoard: lastPinBoard,
                        lastActionResult: lastActionResult
                    )
                    snapshots[label] = normalizeRecordedURLs(snap)
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

            let finalState = normalizeRecordedURLs(
                await ConversationSnapshot.capture(
                    from: engine,
                    pinBoard: lastPinBoard,
                    lastActionResult: lastActionResult
                )
            )
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

    // MARK: - Seed Helpers

    private static func seedSQLiteStore(userId: String, dataDir: URL, seed: CaseJSON) async throws {
        let dbURL = dataDir
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(userId, isDirectory: true)
            .appendingPathComponent("history.sqlite3")
        let store = try ZaloSQLiteStore(path: dbURL.path)
        // Ensure ZDB migration never scans the host machine's ~/Library/WebKit directory.
        try await store.setPreferenceString(key: ZaloWebKitMigrator.donePrefKey, value: "1")

        if let pinned = seed["pinned_ids"]?.arrayValue?.compactMap(\.stringValue) {
            try await store.setPreferenceStrings(key: "pinnedIds", value: pinned)
        }
        if let archived = seed["archived_ids"]?.arrayValue?.compactMap(\.stringValue) {
            try await store.setPreferenceStrings(key: "archivedIds", value: archived)
        }
        if let unreadMarks = seed["unread_marks"]?.arrayValue?.compactMap(\.stringValue) {
            try await store.setPreferenceStrings(key: "unreadMarks", value: unreadMarks)
        }
        if let hidden = seed["hidden_ids"]?.arrayValue?.compactMap(\.stringValue) {
            try await store.setPreferenceStrings(key: "hiddenIds", value: hidden)
        }
        if let md5 = seed["hidden_pin_md5"]?.stringValue, !md5.isEmpty {
            try await store.setPreferenceString(key: "hiddenPinMD5", value: md5)
        }
        if let sha = seed["hidden_pin_hash"]?.stringValue, !sha.isEmpty {
            try await store.setPreferenceString(key: "hiddenPinHash", value: sha)
        }
        if let labelsPref = seed["labels_pref"], labelsPref != .null {
            try await store.setPreferenceData(key: "labels", data: Data(labelsPref.canonicalString().utf8))
        }
        if let ranks = seed["activity_ranks"], ranks != .null {
            try await store.setPreferenceData(key: "activityRanks", data: Data(ranks.canonicalString().utf8))
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
        if let convRows = seed["local_conversations"]?.arrayValue, !convRows.isEmpty {
            let stored: [StoredConversation] = convRows.compactMap { row in
                guard let id = row["id"]?.stringValue else { return nil }
                return StoredConversation(
                    id: id,
                    isGroup: row["is_group"]?.boolValue ?? false,
                    name: row["name"]?.stringValue ?? "",
                    avatar: row["avatar"]?.stringValue ?? "",
                    pinned: row["pinned"]?.boolValue ?? false,
                    members: Int(row["members"]?.int64Value ?? 0),
                    unread: Int(row["unread"]?.int64Value ?? 0),
                    previewText: row["preview_text"]?.stringValue ?? "",
                    previewTsMs: row["preview_ts_ms"]?.int64Value ?? 0,
                    previewFromMe: row["preview_from_me"]?.boolValue ?? false,
                    updatedAtMs: row["updated_at_ms"]?.int64Value ?? 1700000000000
                )
            }
            try await store.saveConversations(stored)
        }
        if let msgRows = seed["local_messages"]?.arrayValue, !msgRows.isEmpty {
            let stored: [StoredMessage] = msgRows.compactMap { row in
                guard let id = row["id"]?.stringValue, let convId = row["conv_id"]?.stringValue else { return nil }
                let rawJSON: Data = {
                    if let rawObj = row["raw_json"], rawObj != .null {
                        return Data(rawObj.canonicalString().utf8)
                    }
                    let fallback: CaseJSON = .object([
                        "id": .string(id),
                        "conversationId": .string(convId),
                        "clientId": .string(row["client_id"]?.stringValue ?? id),
                        "senderId": .string(row["sender_id"]?.stringValue ?? ""),
                        "senderName": .string(row["sender_name"]?.stringValue ?? ""),
                        "senderAvatar": .string(row["sender_avatar"]?.stringValue ?? ""),
                        "isMine": .bool(row["is_mine"]?.boolValue ?? false),
                        "text": .string(row["text"]?.stringValue ?? ""),
                        "date": .int(row["ts_ms"]?.int64Value ?? 0),
                        "kind": .object(["type": .string(row["kind_tag"]?.stringValue ?? "text")]),
                    ])
                    return Data(fallback.canonicalString().utf8)
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
                    status: row["status"]?.stringValue ?? "sent",
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
        if let aliasesObj = contacts["aliases"]?.objectValue {
            var map: [String: String] = [:]
            for (k, v) in aliasesObj {
                if let s = v.stringValue { map[k] = s }
            }
            engine.cachedAliases = map
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
        displayName: String = "Conv User",
        avatar: String = "https://cdn.example.invalid/me.jpg",
        phone: String = "+84900000100",
        send2MeId: String? = nil,
        zpwEnk: String = "0123456789abcdef",
        zpwSek: String = "saved.200.a0.sek_c1",
        suppress: [String] = ["long_poll"],
        extras: [String: CaseJSON] = [:]
    ) -> CaseJSON {
        let acct: [String: CaseJSON] = [
            "userId": .string(userId),
            "displayName": .string(displayName),
            "avatar": .string(avatar),
            "phone": .string(phone),
            "send2MeId": .string(send2MeId ?? "9\(userId)"),
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
            "prefs": .object([:]),
        ]
        if !suppress.isEmpty {
            seedDict["suppress"] = .array(suppress.map(CaseJSON.string))
        }
        for (k, v) in extras {
            seedDict[k] = v
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
        payload: CaseJSON
    ) -> CaseJSON {
        .object([
            "kind": .string("ws_frame"),
            "cmd": .int(cmd),
            "sub_cmd": .int(subCmd),
            "payload": payload,
        ])
    }

    private static func loginInfoScript(uid: String, zpwSek: String, displayName: String, send2MeId: String? = nil) -> CaseJSON {
        httpScript(
            path: "/api/login/getLoginInfo",
            json: .object([
                "error_code": .int(0),
                "data": .object([
                    "uid": .string(uid),
                    "display_name": .string(displayName),
                    "zpw_sek": .string(zpwSek),
                    "zpw_enk": .string("0123456789abcdef"),
                    "dkey": .string("dkey_\(uid)"),
                    "send2me_id": .string(send2MeId ?? "9\(uid)"),
                    "need_sync_msg": .bool(false),
                    "zpw_ws": .array([.string("ws://fake")]),
                    "zpw_service_map_v3": .object([
                        "profile": .array([.string("http://fake")]),
                        "conversation": .array([.string("http://fake")]),
                        "chat": .array([.string("http://fake")]),
                        "group": .array([.string("http://fake")]),
                        "label": .array([.string("http://fake")]),
                    ]),
                ]),
            ])
        )
    }

    private static func profileMeScript(uid: String, displayName: String) -> CaseJSON {
        httpScript(
            path: "/api/social/profile/me-v2",
            json: .object([
                "error_code": .int(0),
                "data": .object([
                    "profile": .object([
                        "userId": .string(uid),
                        "displayName": .string(displayName),
                        "avatar": .string("https://cdn.example.invalid/me.jpg"),
                        "phoneNumber": .string("+84900000100"),
                    ]),
                ]),
            ])
        )
    }

    private static func localConv(
        id: String,
        isGroup: Bool = false,
        name: String,
        avatar: String = "",
        pinned: Bool = false,
        members: Int64 = 0,
        unread: Int64 = 0,
        previewText: String = "",
        previewTsMs: Int64 = 0,
        previewFromMe: Bool = false
    ) -> CaseJSON {
        .object([
            "id": .string(id),
            "is_group": .bool(isGroup),
            "name": .string(name),
            "avatar": .string(avatar),
            "pinned": .bool(pinned),
            "members": .int(members),
            "unread": .int(unread),
            "preview_text": .string(previewText),
            "preview_ts_ms": .int(previewTsMs),
            "preview_from_me": .bool(previewFromMe),
            "updated_at_ms": .int(1700000000000),
        ])
    }

    // MARK: - Helpers for Scenarios

    private static func wireMsg(
        msgId: String,
        cliMsgId: String? = nil,
        uidFrom: String,
        idTo: String,
        dName: String = "",
        avt: String = "",
        msgType: String = "webchat",
        content: CaseJSON,
        ts: Int64,
        mentions: [CaseJSON]? = nil
    ) -> CaseJSON {
        var obj: [String: CaseJSON] = [
            "msgId": .string(msgId),
            "cliMsgId": .string(cliMsgId ?? "c_\(msgId)"),
            "uidFrom": .string(uidFrom),
            "idTo": .string(idTo),
            "dName": .string(dName),
            "avt": .string(avt),
            "msgType": .string(msgType),
            "content": content,
            "ts": .int(ts),
        ]
        if let mentions {
            obj["mentions"] = .array(mentions)
        }
        return .object(obj)
    }

    private static func applyBatchCmd(
        msgs: [CaseJSON],
        defaultCmd: Int64 = 501,
        incrementUnread: Bool = false,
        persistConversations: Bool = true
    ) -> CaseJSON {
        .object([
            "cmd": .string("apply_batch"),
            "args": .object([
                "payload": .object(["data": .object(["msgs": .array(msgs)])]),
                "default_cmd": .int(defaultCmd),
                "increment_unread": .bool(incrementUnread),
                "notify_incoming": .bool(false),
                "persist_conversations": .bool(persistConversations),
            ]),
        ])
    }

    // MARK: - Domain 1: conversations (Scenarios 1-12)

    private static func conversationsScenarios() -> [ScenarioDef] {
        // Valid 40-byte Signal ciphertext stub (msgType=3, version=0x33, tag=0x0A) for undecrypted E2EE placeholder checks.
        let signalCipherStub = "AzMKQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFB"

        // 52 missing-avatar/name local conversations for Scenario 10 (50 + 2 profile chunks)
        var s10Convs: [CaseJSON] = [
            localConv(id: "3000150", name: "", avatar: "", previewText: "Empty name", previewTsMs: 1700000150000),
            localConv(id: "3000151", name: "3000151", avatar: "https://cdn.example.invalid/keep_151.jpg", previewText: "Id name", previewTsMs: 1700000151000),
            localConv(id: "3000152", name: "Người dùng Zalo", avatar: "", previewText: "Placeholder name", previewTsMs: 1700000152000),
            localConv(id: "3000153", name: "Good 153", avatar: "", previewText: "Missing avatar", previewTsMs: 1700000153000),
        ]
        for i in 154...201 {
            let uid = "3000\(i)"
            s10Convs.append(localConv(id: uid, name: "", avatar: "", previewText: "Hi \(i)", previewTsMs: 1700000100000 + Int64(i)))
        }
        var chunk1Profiles: [String: CaseJSON] = [
            "3000150": .object(["userId": .string("3000150"), "zaloName": .string("Resolved 150"), "avatar": .string("https://cdn.example.invalid/p150.jpg")]),
            "3000151": .object(["userId": .string("3000151"), "zaloName": .string("Resolved 151"), "avatar": .string("https://cdn.example.invalid/overwrite_ignored_151.jpg")]),
            "3000152": .object(["userId": .string("3000152"), "zaloName": .string("Server 152"), "avatar": .string("https://cdn.example.invalid/p152.jpg")]),
            "3000153": .object(["userId": .string("3000153"), "zaloName": .string("Server 153"), "avatar": .string("https://cdn.example.invalid/p153.jpg")]),
        ]
        for i in 154...199 {
            let uid = "3000\(i)"
            chunk1Profiles[uid] = .object(["userId": .string(uid), "zaloName": .string("User \(i)"), "avatar": .string("https://cdn.example.invalid/p\(i).jpg")])
        }
        let chunk2Profiles: [String: CaseJSON] = [
            "3000200": .object(["userId": .string("3000200"), "zaloName": .string("User 200"), "avatar": .string("https://cdn.example.invalid/p200.jpg")]),
            "3000201": .object(["userId": .string("3000201"), "zaloName": .string("User 201"), "avatar": .string("https://cdn.example.invalid/p201.jpg")]),
        ]

        return [
            // 1. msg_new_conversation_1_1
            ScenarioDef(
                name: "msg_new_conversation_1_1",
                seed: readySessionSeed(
                    userId: "2000101",
                    displayName: "Conv User 1",
                    zpwSek: "saved.200.a0.sek_c1",
                    suppress: ["long_poll"],
                    extras: [
                        "ws_auth": .string("manual"),
                        "contacts": .object([
                            "friends_loaded": .bool(true),
                            "friends": .array([
                                .object([
                                    "id": .string("3000102"),
                                    "name": .string("Identity Peer Two"),
                                    "avatar": .string("https://cdn.example.invalid/friend_3000102.jpg"),
                                ]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    loginInfoScript(uid: "2000101", zpwSek: "saved.200.a0.sek_c1", displayName: "Conv User 1"),
                    profileMeScript(uid: "2000101", displayName: "Conv User 1"),
                    wsScript(),
                    wsFrameScript(cmd: 1, payload: .object(["error_code": .int(0)])),
                    wsFrameScript(
                        cmd: 501,
                        payload: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "msgs": .array([
                                    .object([
                                        "msgId": .string("m101_1"),
                                        "cliMsgId": .string("c101_1"),
                                        "uidFrom": .string("3000101"),
                                        "idTo": .string("2000101"),
                                        "dName": .string("Wire Peer One"),
                                        "avt": .string("https://cdn.example.invalid/wire_3000101.jpg"),
                                        "msgType": .string("webchat"),
                                        "content": .string("Hello live push"),
                                        "ts": .int(1700000101000),
                                    ]),
                                ]),
                            ]),
                        ])
                    ),
                    wsFrameScript(
                        cmd: 510,
                        payload: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "msgs": .array([
                                    .object([
                                        "msgId": .string("m101_2"),
                                        "cliMsgId": .string("c101_2"),
                                        "uidFrom": .string("3000102"),
                                        "idTo": .string("2000101"),
                                        "dName": .string("Wire Peer Two"),
                                        "avt": .string("https://cdn.example.invalid/wire_3000102.jpg"),
                                        "msgType": .string("webchat"),
                                        "content": .string("Hello pull"),
                                        "ts": .int(1700000102000),
                                    ]),
                                ]),
                            ]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("start_bootstrap"), "timeout_ms": .int(5000)]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("e2ee_connected"), "timeout_ms": .int(5000)]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("apply_parsed_events"), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("after_live_push")]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("apply_parsed_events"), "timeout_ms": .int(5000)]),
                ]
            ),

            // 2. msg_existing_conversation
            ScenarioDef(
                name: "msg_existing_conversation",
                seed: readySessionSeed(
                    userId: "2000102",
                    displayName: "Conv User 2",
                    zpwSek: "saved.200.a0.sek_c2",
                    suppress: ["long_poll"],
                    extras: [
                        "ws_auth": .string("manual"),
                        "local_conversations": .array([
                            localConv(
                                id: "3000103",
                                name: "Peer Three",
                                avatar: "https://cdn.example.invalid/3000103.jpg",
                                previewText: "Initial",
                                previewTsMs: 1700000102000
                            ),
                        ]),
                    ]
                ),
                server: [
                    loginInfoScript(uid: "2000102", zpwSek: "saved.200.a0.sek_c2", displayName: "Conv User 2"),
                    profileMeScript(uid: "2000102", displayName: "Conv User 2"),
                    wsScript(),
                    wsFrameScript(cmd: 1, payload: .object(["error_code": .int(0)])),
                    // 1. Older history on pull (510) -> keeps preview, unread stays 0
                    wsFrameScript(
                        cmd: 510,
                        payload: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "msgs": .array([
                                    wireMsg(msgId: "m102_1", uidFrom: "3000103", idTo: "2000102", content: .string("Older pull"), ts: 1700000101000),
                                ]),
                            ]),
                        ])
                    ),
                    // 2. Older message on live push (501) -> keeps preview, unread becomes 1
                    wsFrameScript(
                        cmd: 501,
                        payload: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "msgs": .array([
                                    wireMsg(msgId: "m102_2", uidFrom: "3000103", idTo: "2000102", content: .string("Older live"), ts: 1700000101500),
                                ]),
                            ]),
                        ])
                    ),
                    // 3. Newer message on pull (510) -> replaces preview, unread stays 1
                    wsFrameScript(
                        cmd: 510,
                        payload: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "msgs": .array([
                                    wireMsg(msgId: "m102_3", uidFrom: "3000103", idTo: "2000102", content: .string("Newer pull"), ts: 1700000104000),
                                ]),
                            ]),
                        ])
                    ),
                    // 4. Newer message on live push (501) -> replaces preview, unread becomes 2
                    wsFrameScript(
                        cmd: 501,
                        payload: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "msgs": .array([
                                    wireMsg(msgId: "m102_4", uidFrom: "3000103", idTo: "2000102", content: .string("Newer live"), ts: 1700000105000),
                                ]),
                            ]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("start_bootstrap"), "timeout_ms": .int(5000)]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("e2ee_connected"), "timeout_ms": .int(5000)]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("apply_parsed_events"), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("after_older_pull")]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("apply_parsed_events"), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("after_older_live")]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("apply_parsed_events"), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("after_newer_pull")]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("apply_parsed_events"), "timeout_ms": .int(5000)]),
                ]
            ),

            // 3. msg_noop
            ScenarioDef(
                name: "msg_noop",
                seed: readySessionSeed(
                    userId: "2000103",
                    displayName: "Conv User 3",
                    zpwSek: "saved.200.a0.sek_c3",
                    suppress: ["long_poll"],
                    extras: [
                        "ws_auth": .string("manual"),
                    ]
                ),
                server: [
                    loginInfoScript(uid: "2000103", zpwSek: "saved.200.a0.sek_c3", displayName: "Conv User 3"),
                    profileMeScript(uid: "2000103", displayName: "Conv User 3"),
                    wsScript(),
                    wsFrameScript(cmd: 1, payload: .object(["error_code": .int(0)])),
                    wsFrameScript(
                        cmd: 501,
                        payload: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "msgs": .array([
                                    wireMsg(msgId: "m103_1", uidFrom: "3000104", idTo: "2000103", dName: "Peer Four", avt: "https://cdn.example.invalid/3000104.jpg", content: .string("Same msg"), ts: 1700000103000),
                                ]),
                            ]),
                        ])
                    ),
                    // Duplicate frame with exact same msgId even with cmd 501 -> noop (no unread increment, same preview & order)
                    wsFrameScript(
                        cmd: 501,
                        payload: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "msgs": .array([
                                    wireMsg(msgId: "m103_1", uidFrom: "3000104", idTo: "2000103", dName: "Peer Four", avt: "https://cdn.example.invalid/3000104.jpg", content: .string("Same msg"), ts: 1700000103000),
                                ]),
                            ]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("start_bootstrap"), "timeout_ms": .int(5000)]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("e2ee_connected"), "timeout_ms": .int(5000)]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("apply_parsed_events"), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("after_first")]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("apply_parsed_events"), "timeout_ms": .int(5000)]),
                ]
            ),

            // 4. order_pinned_date_rank_id
            ScenarioDef(
                name: "order_pinned_date_rank_id",
                seed: readySessionSeed(
                    userId: "2000104",
                    displayName: "Conv User 4",
                    zpwSek: "saved.200.a0.sek_c4",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "pinned_ids": .array([.string("3000110"), .string("3000111")]),
                        "activity_ranks": .object([
                            "3000113": .int(50),
                            "3000114": .int(90),
                            "3000115": .int(40),
                            "3000116": .int(40),
                        ]),
                        "local_conversations": .array([
                            // Pinned but older ts than unpinned
                            localConv(id: "3000110", name: "Pinned Old", pinned: true, previewText: "A", previewTsMs: 1700000100000),
                            // Pinned newer ts -> first overall
                            localConv(id: "3000111", name: "Pinned New", pinned: true, previewText: "B", previewTsMs: 1700000200000),
                            // Unpinned highest ts -> third overall
                            localConv(id: "3000112", name: "Unpinned Newest", pinned: false, previewText: "C", previewTsMs: 1700000900000),
                            // Tie on ts=1700000500000, rank 90 beats rank 50
                            localConv(id: "3000113", name: "Tie Ts Low Rank", pinned: false, previewText: "D", previewTsMs: 1700000500000),
                            localConv(id: "3000114", name: "Tie Ts High Rank", pinned: false, previewText: "E", previewTsMs: 1700000500000),
                            // Tie on ts=1700000300000 and rank=40 -> id asc ("3000115" < "3000116")
                            localConv(id: "3000116", name: "Tie All B", pinned: false, previewText: "F", previewTsMs: 1700000300000),
                            localConv(id: "3000115", name: "Tie All A", pinned: false, previewText: "G", previewTsMs: 1700000300000),
                            // Nil previews -> bottom, sorted by id asc
                            localConv(id: "3000118", name: "No Preview B", pinned: false, previewText: "", previewTsMs: 0),
                            localConv(id: "3000117", name: "No Preview A", pinned: false, previewText: "", previewTsMs: 0),
                        ]),
                    ]
                ),
                server: [
                    loginInfoScript(uid: "2000104", zpwSek: "saved.200.a0.sek_c4", displayName: "Conv User 4"),
                    profileMeScript(uid: "2000104", displayName: "Conv User 4"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                ]
            ),

            // 5. preview_labels
            ScenarioDef(
                name: "preview_labels",
                seed: readySessionSeed(
                    userId: "2000105",
                    displayName: "Conv User 5",
                    zpwSek: "saved.200.a0.sek_c5",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "local_conversations": .array([
                            localConv(id: "3000518", name: "Peer 518", previewText: "", previewTsMs: 0),
                        ]),
                        "local_messages": .array([
                            .object([
                                "id": .string("p18"),
                                "conv_id": .string("3000518"),
                                "client_id": .string("c_p18"),
                                "sender_id": .string("2000105"),
                                "sender_name": .string("Bạn"),
                                "is_mine": .bool(true),
                                "text": .string(""),
                                "kind_tag": .string("recalled"),
                                "ts_ms": .int(1700000518000),
                                "raw_json": .object([
                                    "id": .string("p18"),
                                    "conversationId": .string("3000518"),
                                    "clientId": .string("c_p18"),
                                    "senderId": .string("2000105"),
                                    "senderName": .string("Bạn"),
                                    "isMine": .bool(true),
                                    "text": .string(""),
                                    "date": .int(1700000518000),
                                    "kind": .object(["type": .string("recalled")]),
                                ]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    loginInfoScript(uid: "2000105", zpwSek: "saved.200.a0.sek_c5", displayName: "Conv User 5"),
                    profileMeScript(uid: "2000105", displayName: "Conv User 5"),
                    httpScript(path: "/api/preloadconvers/get-last-msgs", method: "GET", json: .object(["error_code": .int(0), "data": .object([:])])),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    applyBatchCmd(
                        msgs: [
                            // 1. photo
                            wireMsg(msgId: "p1", uidFrom: "3000501", idTo: "2000105", msgType: "chat.photo", content: .object(["href": .string("https://cdn.example.invalid/p.jpg")]), ts: 1700000501000),
                            // 2. video
                            wireMsg(msgId: "p2", uidFrom: "3000502", idTo: "2000105", msgType: "chat.video.msg", content: .object(["href": .string("https://cdn.example.invalid/v.mp4"), "params": .string("{\"duration\":5000}")]), ts: 1700000502000),
                            // 3. sticker
                            wireMsg(msgId: "p3", uidFrom: "3000503", idTo: "2000105", msgType: "chat.sticker", content: .object(["id": .string("1001"), "cateId": .int(10)]), ts: 1700000503000),
                            // 4. gif
                            wireMsg(msgId: "p4", uidFrom: "3000504", idTo: "2000105", msgType: "chat.gif", content: .object(["href": .string("https://cdn.example.invalid/g.gif")]), ts: 1700000504000),
                            // 5. voice
                            wireMsg(msgId: "p5", uidFrom: "3000505", idTo: "2000105", msgType: "chat.voice", content: .object(["href": .string("https://cdn.example.invalid/a.aac"), "params": .string("{\"duration\":3000}")]), ts: 1700000505000),
                            // 6. file with name
                            wireMsg(msgId: "p6", uidFrom: "3000506", idTo: "2000105", msgType: "share.file", content: .object(["title": .string("Q4_Report.pdf"), "href": .string("https://cdn.example.invalid/f.pdf")]), ts: 1700000506000),
                            // 7. file without name
                            wireMsg(msgId: "p7", uidFrom: "3000507", idTo: "2000105", msgType: "share.file", content: .object(["href": .string("https://cdn.example.invalid/noname.bin")]), ts: 1700000507000),
                            // 8. location
                            wireMsg(msgId: "p8", uidFrom: "3000508", idTo: "2000105", msgType: "chat.location.new", content: .object(["params": .string("{\"lat\":10.77,\"lon\":106.7}")]), ts: 1700000508000),
                            // 9. contact card
                            wireMsg(msgId: "p9", uidFrom: "3000509", idTo: "2000105", msgType: "chat.recommended", content: .object(["action": .string("recommened.user"), "params": .string("{\"uid\":\"3000999\",\"userName\":\"Bob\"}")]), ts: 1700000509000),
                            // 10. call voice
                            wireMsg(msgId: "p10", uidFrom: "3000510", idTo: "2000105", msgType: "chat.recommended", content: .object(["action": .string("recommened.calltime"), "params": .string("{\"callType\":1,\"duration\":15}")]), ts: 1700000510000),
                            // 11. call video
                            wireMsg(msgId: "p11", uidFrom: "3000511", idTo: "2000105", msgType: "chat.recommended", content: .object(["action": .string("recommened.calltime"), "params": .string("{\"callType\":2,\"duration\":42}")]), ts: 1700000511000),
                            // 12. poll with question
                            wireMsg(msgId: "p12", uidFrom: "3000512", idTo: "2000105", msgType: "group.poll", content: .object(["action": .string("create"), "params": .string("{\"poll_id\":\"pl1\",\"question\":\"Lunch spot?\"}")]), ts: 1700000512000),
                            // 13. poll without question
                            wireMsg(msgId: "p13", uidFrom: "3000513", idTo: "2000105", msgType: "group.poll", content: .object(["action": .string("create"), "params": .string("{\"poll_id\":\"pl2\"}")]), ts: 1700000513000),
                            // 14. ecard with title & without title
                            wireMsg(msgId: "p14", uidFrom: "3000514", idTo: "2000105", msgType: "chat.ecard", content: .object(["title": .string("Happy Birthday")]), ts: 1700000514000),
                            wireMsg(msgId: "p15", uidFrom: "3000515", idTo: "2000105", msgType: "chat.ecard", content: .object([:]), ts: 1700000515000),
                            // 15. E2EE text placeholder
                            wireMsg(msgId: "p16", uidFrom: "3000516", idTo: "2000105", msgType: "webchat", content: .string(signalCipherStub), ts: 1700000516000),
                            // 16. E2EE sticker placeholder
                            wireMsg(msgId: "p17", uidFrom: "3000517", idTo: "2000105", msgType: "chat.sticker", content: .object(["id": .string(signalCipherStub), "cateId": .int(10)]), ts: 1700000517000),
                            // 18. Unknown wire type
                            wireMsg(msgId: "p19", uidFrom: "3000519", idTo: "2000105", msgType: "custom.unknown", content: .object([:]), ts: 1700000519000),
                            // 19. Text with surrounding whitespace
                            wireMsg(msgId: "p20", uidFrom: "3000520", idTo: "2000105", msgType: "webchat", content: .string("  \n  Trimmed greeting   \t "), ts: 1700000520000),
                        ],
                        defaultCmd: 510
                    ),
                    // 17. Recalled message preview via open_conversation(load: true)
                    .object(["cmd": .string("open_conversation"), "args": .object(["id": .string("3000518"), "load": .bool(true)])]),
                ]
            ),

            // 6. preview_mentions
            ScenarioDef(
                name: "preview_mentions",
                seed: readySessionSeed(
                    userId: "2000106",
                    displayName: "Conv User 6",
                    zpwSek: "saved.200.a0.sek_c6",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "contacts": .object([
                            "friends": .array([
                                .object(["id": .string("3000602"), "name": .string("Friend Two"), "zalo_name": .string("Friend Two")]),
                            ]),
                            "groups": .array([
                                .object(["id": .string("g601"), "name": .string("Mentions Group"), "members": .int(4)]),
                            ]),
                            "aliases": .object(["3000602": .string("Alias Two")]),
                        ]),
                        "local_conversations": .array([
                            localConv(id: "g601", isGroup: true, name: "Mentions Group", members: 4, previewText: "Chào @OldName và @All", previewTsMs: 1700000601000),
                        ]),
                        "local_messages": .array([
                            .object([
                                "id": .string("m601_1"),
                                "conv_id": .string("g601"),
                                "client_id": .string("c601_1"),
                                "sender_id": .string("3000603"),
                                "sender_name": .string("Member Three"),
                                "is_mine": .bool(false),
                                "text": .string("Chào @OldName và @All"),
                                "kind_tag": .string("text"),
                                "ts_ms": .int(1700000601000),
                                "raw_json": .object([
                                    "id": .string("m601_1"),
                                    "conversationId": .string("g601"),
                                    "clientId": .string("c601_1"),
                                    "senderId": .string("3000603"),
                                    "senderName": .string("Member Three"),
                                    "isMine": .bool(false),
                                    "text": .string("Chào @OldName và @All"),
                                    "date": .int(1700000601000),
                                    "kind": .object(["type": .string("text")]),
                                    "mentions": .array([
                                        .object(["uid": .string("3000602"), "pos": .int(5), "len": .int(8), "isAll": .bool(false)]),
                                        .object(["uid": .string("-1"), "pos": .int(17), "len": .int(4), "isAll": .bool(true)]),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    loginInfoScript(uid: "2000106", zpwSek: "saved.200.a0.sek_c6", displayName: "Conv User 6"),
                    profileMeScript(uid: "2000106", displayName: "Conv User 6"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("after_boot_fix")]),
                    // Newer mention message via apply_batch + refresh_mention_previews
                    .object([
                        "cmd": .string("apply_batch"),
                        "args": .object([
                            "payload": .object([
                                "data": .object([
                                    "msgs": .array([
                                        wireMsg(
                                            msgId: "m601_2",
                                            uidFrom: "3000603",
                                            idTo: "g601",
                                            dName: "Member Three",
                                            content: .string("Ping @RawPeer!"),
                                            ts: 1700000602000,
                                            mentions: [
                                                .object(["uid": .string("3000602"), "pos": .int(5), "len": .int(8), "type": .int(0)]),
                                            ]
                                        ),
                                    ]),
                                ]),
                            ]),
                            "default_cmd": .int(521),
                            "increment_unread": .bool(true),
                            "notify_incoming": .bool(false),
                            "persist_conversations": .bool(true),
                        ]),
                    ]),
                    .object(["snapshot": .string("before_refresh_new")]),
                    .object(["cmd": .string("refresh_mention_previews")]),
                ]
            ),

            // 7. group_first_message
            ScenarioDef(
                name: "group_first_message",
                seed: readySessionSeed(
                    userId: "2000107",
                    displayName: "Conv User 7",
                    zpwSek: "saved.200.a0.sek_c7",
                    suppress: ["long_poll"],
                    extras: [
                        "ws_auth": .string("manual"),
                        "contacts": .object([
                            "groups": .array([
                                .object([
                                    "id": .string("g701"),
                                    "name": .string("Design Team"),
                                    "avatar": .string("https://cdn.example.invalid/g701.jpg"),
                                    "members": .int(12),
                                ]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    loginInfoScript(uid: "2000107", zpwSek: "saved.200.a0.sek_c7", displayName: "Conv User 7"),
                    profileMeScript(uid: "2000107", displayName: "Conv User 7"),
                    wsScript(),
                    wsFrameScript(cmd: 1, payload: .object(["error_code": .int(0)])),
                    wsFrameScript(
                        cmd: 521,
                        payload: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "groupMsgs": .array([
                                    wireMsg(
                                        msgId: "m701_1",
                                        uidFrom: "3000702",
                                        idTo: "g701",
                                        dName: "Sender Seven",
                                        avt: "https://cdn.example.invalid/u702.jpg",
                                        content: .string("Welcome to Design Team"),
                                        ts: 1700000701000
                                    ),
                                ]),
                            ]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["await_host": .string("start_bootstrap"), "timeout_ms": .int(5000)]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("e2ee_connected"), "timeout_ms": .int(5000)]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("apply_parsed_events"), "timeout_ms": .int(5000)]),
                ]
            ),

            // 8. self_conversation
            ScenarioDef(
                name: "self_conversation",
                seed: readySessionSeed(
                    userId: "2000108",
                    displayName: "Conv User 8",
                    send2MeId: "92000108",
                    zpwSek: "saved.200.a0.sek_c8",
                    suppress: ["ws", "long_poll"]
                ),
                server: [
                    loginInfoScript(uid: "2000108", zpwSek: "saved.200.a0.sek_c8", displayName: "Conv User 8", send2MeId: "92000108"),
                    profileMeScript(uid: "2000108", displayName: "Conv User 8"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("ensure_known_contacts")]),
                    .object(["snapshot": .string("after_ensure")]),
                    applyBatchCmd(
                        msgs: [
                            wireMsg(msgId: "m801_1", uidFrom: "2000108", idTo: "92000108", content: .string("Self note"), ts: 1700000801000),
                        ],
                        defaultCmd: 501,
                        incrementUnread: true
                    ),
                ]
            ),

            // 9. known_contacts_merge
            ScenarioDef(
                name: "known_contacts_merge",
                seed: readySessionSeed(
                    userId: "2000109",
                    displayName: "Conv User 9",
                    send2MeId: "92000109",
                    zpwSek: "saved.200.a0.sek_c9",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "pinned_ids": .array([.string("3000902"), .string("g902")]),
                        "activity_ranks": .object([
                            "3000903": .int(10),
                            "3000904": .int(0),
                            "g999": .int(99),
                        ]),
                        "contacts": .object([
                            "friends": .array([
                                .object(["id": .string("3000902"), "name": .string("Friend 902"), "zalo_name": .string("Friend 902"), "avatar": .string("https://cdn.example.invalid/902.jpg")]),
                            ]),
                            "groups": .array([
                                .object(["id": .string("g901"), "name": .string("Known Group 901"), "avatar": .string("https://cdn.example.invalid/g901.jpg"), "members": .int(6)]),
                                .object(["id": .string("g902"), "name": .string("Pinned Group 902"), "members": .int(3)]),
                            ]),
                            "aliases": .object(["3000902": .string("Alias 902")]),
                        ]),
                    ]
                ),
                server: [
                    loginInfoScript(uid: "2000109", zpwSek: "saved.200.a0.sek_c9", displayName: "Conv User 9", send2MeId: "92000109"),
                    profileMeScript(uid: "2000109", displayName: "Conv User 9"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("ensure_known_contacts")]),
                    .object(["snapshot": .string("after_first_merge")]),
                    .object([
                        "cmd": .string("update_contacts"),
                        "args": .object([
                            "aliases": .object(["3000902": .string("Updated Alias 902")]),
                            "friends": .array([
                                .object(["id": .string("3000902"), "name": .string("Friend 902"), "zalo_name": .string("Friend 902"), "avatar": .string("https://cdn.example.invalid/902_v2.jpg")]),
                            ]),
                        ]),
                    ]),
                    .object(["cmd": .string("ensure_known_contacts")]),
                ]
            ),

            // 10. resolve_missing_names
            ScenarioDef(
                name: "resolve_missing_names",
                seed: readySessionSeed(
                    userId: "2000110",
                    displayName: "Conv User 10",
                    zpwSek: "saved.200.a0.sek_c10",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "contacts": .object([
                            "aliases": .object(["3000152": .string("Alias Wins 152")]),
                        ]),
                        "local_conversations": .array(s10Convs),
                    ]
                ),
                server: [
                    loginInfoScript(uid: "2000110", zpwSek: "saved.200.a0.sek_c10", displayName: "Conv User 10"),
                    profileMeScript(uid: "2000110", displayName: "Conv User 10"),
                    httpScript(
                        path: "/api/social/group/members",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["profiles": .object(chunk1Profiles)])])
                    ),
                    httpScript(
                        path: "/api/social/group/members",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["profiles": .object(chunk2Profiles)])])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("before_resolve")]),
                    .object(["cmd": .string("resolve_missing_names")]),
                ]
            ),

            // 11. local_cache_load
            ScenarioDef(
                name: "local_cache_load",
                seed: readySessionSeed(
                    userId: "2000111",
                    displayName: "Conv User 11",
                    zpwSek: "saved.200.a0.sek_c11",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "pinned_ids": .array([.string("3001102")]),
                        "archived_ids": .array([.string("3001103")]),
                        "unread_marks": .array([.string("3001101")]),
                        "hidden_ids": .array([.string("3001104")]),
                        "hidden_pin_md5": .string("81dc9bdb52d04dc20036dbd8313ed055"),
                        "labels_pref": .array([
                            .object(["id": .string("lbl_cached"), "name": .string("VIP"), "color": .string("#FF5733"), "convIds": .array([.string("3001101")])]),
                        ]),
                        "contacts": .object([
                            "aliases": .object(["3001101": .string("Local Alias 1")]),
                            "cached_profiles": .object([
                                "3001102": .object(["name": .string("Cached Two"), "avatar": .string("https://cdn.example.invalid/c2.jpg")]),
                            ]),
                        ]),
                        "local_conversations": .array([
                            localConv(id: "3001101", name: "Raw 1", unread: 3, previewText: "Unread one", previewTsMs: 1700001103000),
                            localConv(id: "3001102", name: "Raw 2", pinned: false, previewText: "Pinned via pref", previewTsMs: 1700001101000),
                            localConv(id: "3001103", name: "Archived Three", previewText: "In other", previewTsMs: 1700001102000),
                            localConv(id: "3001104", name: "Hidden Four", previewText: "Secret", previewTsMs: 1700001104000),
                        ]),
                    ]
                ),
                server: [
                    loginInfoScript(uid: "2000111", zpwSek: "saved.200.a0.sek_c11", displayName: "Conv User 11"),
                    profileMeScript(uid: "2000111", displayName: "Conv User 11"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                ]
            ),

            // 12. persist_rows
            ScenarioDef(
                name: "persist_rows",
                seed: readySessionSeed(
                    userId: "2000112",
                    displayName: "Conv User 12",
                    zpwSek: "saved.200.a0.sek_c12",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "pinned_ids": .array([.string("g1202")]),
                        "contacts": .object([
                            "groups": .array([
                                .object(["id": .string("g1202"), "name": .string("Group 1202"), "avatar": .string("https://cdn.example.invalid/g1202.jpg"), "members": .int(9)]),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    loginInfoScript(uid: "2000112", zpwSek: "saved.200.a0.sek_c12", displayName: "Conv User 12"),
                    profileMeScript(uid: "2000112", displayName: "Conv User 12"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    applyBatchCmd(
                        msgs: [
                            wireMsg(msgId: "m1201", uidFrom: "3001201", idTo: "2000112", dName: "Peer 1201", avt: "https://cdn.example.invalid/1201.jpg", content: .string("First ms exact"), ts: 1700001200456),
                            wireMsg(msgId: "m1202", uidFrom: "2000112", idTo: "g1202", content: .string("My group msg"), ts: 1700001201789),
                        ],
                        defaultCmd: 501,
                        incrementUnread: true
                    ),
                ]
            ),

            // 32. recall_preview_via_batch (records existing Swift bug: applyParsedEvents overwrites Pass 2 recall preview back to "Will recall")
            ScenarioDef(
                name: "recall_preview_via_batch",
                seed: readySessionSeed(
                    userId: "2000113",
                    displayName: "Conv User 13",
                    zpwSek: "saved.200.a0.sek_c13",
                    suppress: ["ws", "long_poll"]
                ),
                server: [
                    loginInfoScript(uid: "2000113", zpwSek: "saved.200.a0.sek_c13", displayName: "Conv User 13"),
                    profileMeScript(uid: "2000113", displayName: "Conv User 13"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    applyBatchCmd(
                        msgs: [
                            wireMsg(msgId: "m1301", cliMsgId: "c1301", uidFrom: "3001301", idTo: "2000113", dName: "Peer 1301", avt: "https://cdn.example.invalid/1301.jpg", content: .string("Will recall"), ts: 1700001301000),
                        ],
                        defaultCmd: 501,
                        incrementUnread: true
                    ),
                    .object(["snapshot": .string("before_recall")]),
                    applyBatchCmd(
                        msgs: [
                            wireMsg(msgId: "m1301_undo", uidFrom: "3001301", idTo: "2000113", msgType: "chat.undo", content: .object(["globalMsgId": .string("m1301"), "cliMsgId": .string("c1301")]), ts: 1700001302000),
                        ],
                        defaultCmd: 501
                    ),
                ]
            ),

            // 33. delete_preview_via_batch (records existing Swift behavior: applyRemoteDelete leaves conversation preview unchanged)
            ScenarioDef(
                name: "delete_preview_via_batch",
                seed: readySessionSeed(
                    userId: "2000114",
                    displayName: "Conv User 14",
                    zpwSek: "saved.200.a0.sek_c14",
                    suppress: ["ws", "long_poll"]
                ),
                server: [
                    loginInfoScript(uid: "2000114", zpwSek: "saved.200.a0.sek_c14", displayName: "Conv User 14"),
                    profileMeScript(uid: "2000114", displayName: "Conv User 14"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    applyBatchCmd(
                        msgs: [
                            wireMsg(msgId: "m1401_1", cliMsgId: "c1401_1", uidFrom: "3001401", idTo: "2000114", dName: "Peer 1401", avt: "https://cdn.example.invalid/1401.jpg", content: .string("First msg"), ts: 1700001401000),
                            wireMsg(msgId: "m1401_2", cliMsgId: "c1401_2", uidFrom: "3001401", idTo: "2000114", dName: "Peer 1401", avt: "https://cdn.example.invalid/1401.jpg", content: .string("Latest to delete"), ts: 1700001402000),
                        ],
                        defaultCmd: 501,
                        incrementUnread: true
                    ),
                    .object(["snapshot": .string("before_delete")]),
                    applyBatchCmd(
                        msgs: [
                            wireMsg(msgId: "m1401_del", uidFrom: "3001401", idTo: "2000114", msgType: "chat.delete", content: .object(["globalDelMsgId": .string("m1401_2"), "clientDelMsgId": .string("c1401_2")]), ts: 1700001403000),
                        ],
                        defaultCmd: 501
                    ),
                ]
            ),
        ]
    }

    // MARK: - Domain 2: conversation_actions (Scenarios 13-31)

    private static func conversationActionsScenarios() -> [ScenarioDef] {
        // MD5("1234") = 81dc9bdb52d04dc20036dbd8313ed055
        let pin1234MD5 = "81dc9bdb52d04dc20036dbd8313ed055"

        // 10 pinned + 2 unpinned candidates for Scenarios 15 & 16
        let tenPinnedIds = (1...10).map { String(format: "30002%02d", $0) }
        var s15Convs: [CaseJSON] = tenPinnedIds.enumerated().map { idx, cid in
            localConv(id: cid, name: "Pinned \(idx + 1)", pinned: true, previewText: "P\(idx + 1)", previewTsMs: 1700000200000 + Int64(idx))
        }
        s15Convs.append(localConv(id: "3000299", name: "Unpinned 11th", pinned: false, previewText: "Want pin", previewTsMs: 1700000299000))

        var s16Convs = s15Convs
        s16Convs.append(localConv(id: "3000298", name: "Unpinned 12th", pinned: false, previewText: "Fail replace", previewTsMs: 1700000298000))

        return [
            // 13. pin_ok
            ScenarioDef(
                name: "pin_ok",
                seed: readySessionSeed(
                    userId: "2000213",
                    displayName: "Actions User 13",
                    zpwSek: "saved.200.a0.sek_a13",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "local_conversations": .array([
                            localConv(
                                id: "3000201",
                                name: "Newer Unpinned",
                                avatar: "https://cdn.example.invalid/3000201.jpg",
                                previewText: "Latest",
                                previewTsMs: 1700000200000
                            ),
                            localConv(
                                id: "3000202",
                                name: "Older Target",
                                avatar: "https://cdn.example.invalid/3000202.jpg",
                                previewText: "Earlier",
                                previewTsMs: 1700000100000
                            ),
                        ]),
                    ]
                ),
                server: [
                    loginInfoScript(uid: "2000213", zpwSek: "saved.200.a0.sek_a13", displayName: "Actions User 13"),
                    profileMeScript(uid: "2000213", displayName: "Actions User 13"),
                    httpScript(
                        path: "/api/pinconvers/updatev2",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("before_pin")]),
                    .object(["cmd": .string("pin"), "args": .object(["id": .string("3000202")])]),
                ]
            ),

            // 14. pin_fail
            ScenarioDef(
                name: "pin_fail",
                seed: readySessionSeed(
                    userId: "2000214",
                    displayName: "Actions User 14",
                    zpwSek: "saved.200.a0.sek_a14",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "local_conversations": .array([
                            localConv(id: "3000214", name: "Target 14", previewText: "Msg", previewTsMs: 1700000214000),
                        ]),
                    ]
                ),
                server: [
                    loginInfoScript(uid: "2000214", zpwSek: "saved.200.a0.sek_a14", displayName: "Actions User 14"),
                    profileMeScript(uid: "2000214", displayName: "Actions User 14"),
                    httpScript(
                        path: "/api/pinconvers/updatev2",
                        method: "POST",
                        json: .object(["error_code": .int(-1), "error_message": .string("pin failed")])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("pin"), "args": .object(["id": .string("3000214")])]),
                ]
            ),

            // 15. pin_limit_board
            ScenarioDef(
                name: "pin_limit_board",
                seed: readySessionSeed(
                    userId: "2000215",
                    displayName: "Actions User 15",
                    zpwSek: "saved.200.a0.sek_a15",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "pinned_ids": .array(tenPinnedIds.map(CaseJSON.string)),
                        "local_conversations": .array(s15Convs),
                    ]
                ),
                server: [
                    loginInfoScript(uid: "2000215", zpwSek: "saved.200.a0.sek_a15", displayName: "Actions User 15"),
                    profileMeScript(uid: "2000215", displayName: "Actions User 15"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("pin"), "args": .object(["id": .string("3000299")])]),
                    .object(["cmd": .string("pin_board"), "args": .object(["id": .string("3000299")])]),
                ]
            ),

            // 16. pin_replacing
            ScenarioDef(
                name: "pin_replacing",
                seed: readySessionSeed(
                    userId: "2000216",
                    displayName: "Actions User 16",
                    zpwSek: "saved.200.a0.sek_a16",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "pinned_ids": .array(tenPinnedIds.map(CaseJSON.string)),
                        "local_conversations": .array(s16Convs),
                    ]
                ),
                server: [
                    loginInfoScript(uid: "2000216", zpwSek: "saved.200.a0.sek_a16", displayName: "Actions User 16"),
                    profileMeScript(uid: "2000216", displayName: "Actions User 16"),
                    // Part 1: unpin 2, pin 1 -> 3 successes
                    httpScript(path: "/api/pinconvers/updatev2", method: "POST", json: .object(["error_code": .int(0), "data": .object([:])])),
                    httpScript(path: "/api/pinconvers/updatev2", method: "POST", json: .object(["error_code": .int(0), "data": .object([:])])),
                    httpScript(path: "/api/pinconvers/updatev2", method: "POST", json: .object(["error_code": .int(0), "data": .object([:])])),
                    // Part 2: 1st unpin succeeds, 2nd unpin fails
                    httpScript(path: "/api/pinconvers/updatev2", method: "POST", json: .object(["error_code": .int(0), "data": .object([:])])),
                    httpScript(path: "/api/pinconvers/updatev2", method: "POST", json: .object(["error_code": .int(-1), "error_message": .string("2nd unpin fail")])),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("pin_replacing"), "args": .object(["unpin": .array([.string("3000201"), .string("3000202")]), "id": .string("3000299")])]),
                    .object(["snapshot": .string("after_replace_ok")]),
                    .object(["cmd": .string("pin_replacing"), "args": .object(["unpin": .array([.string("3000203"), .string("3000204")]), "id": .string("3000298")])]),
                ]
            ),

            // 17. unpin_ok
            ScenarioDef(
                name: "unpin_ok",
                seed: readySessionSeed(
                    userId: "2000217",
                    displayName: "Actions User 17",
                    zpwSek: "saved.200.a0.sek_a17",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "pinned_ids": .array([.string("3000251")]),
                        "local_conversations": .array([
                            localConv(id: "3000251", name: "Pinned Older", pinned: true, previewText: "Old", previewTsMs: 1700000100000),
                            localConv(id: "3000252", name: "Unpinned Newer", pinned: false, previewText: "New", previewTsMs: 1700000200000),
                        ]),
                    ]
                ),
                server: [
                    loginInfoScript(uid: "2000217", zpwSek: "saved.200.a0.sek_a17", displayName: "Actions User 17"),
                    profileMeScript(uid: "2000217", displayName: "Actions User 17"),
                    httpScript(path: "/api/pinconvers/updatev2", method: "POST", json: .object(["error_code": .int(0), "data": .object([:])])),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("before_unpin")]),
                    .object(["cmd": .string("unpin"), "args": .object(["id": .string("3000251")])]),
                ]
            ),

            // 18. unpin_fail
            ScenarioDef(
                name: "unpin_fail",
                seed: readySessionSeed(
                    userId: "2000218",
                    displayName: "Actions User 18",
                    zpwSek: "saved.200.a0.sek_a18",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "pinned_ids": .array([.string("3000261")]),
                        "local_conversations": .array([
                            localConv(id: "3000261", name: "Pinned 261", pinned: true, previewText: "Hi", previewTsMs: 1700000261000),
                        ]),
                    ]
                ),
                server: [
                    loginInfoScript(uid: "2000218", zpwSek: "saved.200.a0.sek_a18", displayName: "Actions User 18"),
                    profileMeScript(uid: "2000218", displayName: "Actions User 18"),
                    httpScript(path: "/api/pinconvers/updatev2", method: "POST", json: .object(["error_code": .int(-1), "error_message": .string("unpin failed")])),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("unpin"), "args": .object(["id": .string("3000261")])]),
                ]
            ),

            // 19. move_to_other
            ScenarioDef(
                name: "move_to_other",
                seed: readySessionSeed(
                    userId: "2000219",
                    displayName: "Actions User 19",
                    zpwSek: "saved.200.a0.sek_a19",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "local_conversations": .array([
                            localConv(id: "3000271", name: "Peer 271", previewText: "Inbox", previewTsMs: 1700000271000),
                        ]),
                    ]
                ),
                server: [
                    loginInfoScript(uid: "2000219", zpwSek: "saved.200.a0.sek_a19", displayName: "Actions User 19"),
                    profileMeScript(uid: "2000219", displayName: "Actions User 19"),
                    httpScript(path: "/api/archivedchat/update", method: "POST", json: .object(["error_code": .int(0), "data": .object([:])])),
                    httpScript(path: "/api/archivedchat/update", method: "POST", json: .object(["error_code": .int(0), "data": .object([:])])),
                    httpScript(path: "/api/archivedchat/update", method: "POST", json: .object(["error_code": .int(-1), "error_message": .string("archive fail")])),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("move"), "args": .object(["id": .string("3000271"), "to_other": .bool(true)])]),
                    .object(["snapshot": .string("after_to_other")]),
                    .object(["cmd": .string("move"), "args": .object(["id": .string("3000271"), "to_other": .bool(false)])]),
                    .object(["snapshot": .string("after_to_inbox")]),
                    .object(["cmd": .string("move"), "args": .object(["id": .string("3000271"), "to_other": .bool(true)])]),
                ]
            ),

            // 20. delete
            ScenarioDef(
                name: "delete",
                seed: readySessionSeed(
                    userId: "2000220",
                    displayName: "Actions User 20",
                    zpwSek: "saved.200.a0.sek_a20",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "pinned_ids": .array([.string("3000281")]),
                        "archived_ids": .array([.string("3000281")]),
                        "unread_marks": .array([.string("3000281")]),
                    ]
                ),
                server: [
                    loginInfoScript(uid: "2000220", zpwSek: "saved.200.a0.sek_a20", displayName: "Actions User 20"),
                    profileMeScript(uid: "2000220", displayName: "Actions User 20"),
                    httpScript(path: "/api/message/deleteconver", method: "POST", json: .object(["error_code": .int(0), "data": .object([:])])),
                    httpScript(path: "/api/group/deleteconver", method: "POST", json: .object(["error_code": .int(0), "data": .object([:])])),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    // Seed in-memory engine.messages so deleteconver sends deterministic last msg id
                    applyBatchCmd(
                        msgs: [
                            wireMsg(msgId: "m281_last", uidFrom: "3000281", idTo: "2000220", dName: "Delete Peer", content: .string("Bye 1-1"), ts: 1700000281000),
                            wireMsg(msgId: "m282_last", uidFrom: "3000283", idTo: "g282", dName: "Member", content: .string("Bye grp"), ts: 1700000282000),
                        ],
                        defaultCmd: 501,
                        incrementUnread: true
                    ),
                    .object(["cmd": .string("request_delete"), "args": .object(["id": .string("3000281")])]),
                    .object(["snapshot": .string("prompt_open")]),
                    .object(["cmd": .string("confirm_delete"), "args": .object(["id": .string("3000281")])]),
                    .object(["snapshot": .string("after_delete_1_1")]),
                    .object(["cmd": .string("request_delete"), "args": .object(["id": .string("g282")])]),
                    .object(["cmd": .string("confirm_delete"), "args": .object(["id": .string("g282")])]),
                ]
            ),

            // 21. mark_unread_and_read
            ScenarioDef(
                name: "mark_unread_and_read",
                seed: readySessionSeed(
                    userId: "2000221",
                    displayName: "Actions User 21",
                    zpwSek: "saved.200.a0.sek_a21",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "local_conversations": .array([
                            localConv(id: "3000291", name: "Mark Peer", unread: 0, previewText: "Read me", previewTsMs: 1700000291000),
                        ]),
                    ]
                ),
                server: [
                    loginInfoScript(uid: "2000221", zpwSek: "saved.200.a0.sek_a21", displayName: "Actions User 21"),
                    profileMeScript(uid: "2000221", displayName: "Actions User 21"),
                    httpScript(path: "/api/conv/addUnreadMark", method: "POST", json: .object(["error_code": .int(0), "data": .object([:])])),
                    httpScript(path: "/api/conv/removeUnreadMark", method: "POST", json: .object(["error_code": .int(0), "data": .object([:])])),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("mark_unread"), "args": .object(["id": .string("3000291")])]),
                    .object(["snapshot": .string("after_mark_unread")]),
                    .object(["cmd": .string("mark_read"), "args": .object(["id": .string("3000291")])]),
                ]
            ),

            // 22. hidden_set_pin_and_hide
            ScenarioDef(
                name: "hidden_set_pin_and_hide",
                seed: readySessionSeed(
                    userId: "2000222",
                    displayName: "Actions User 22",
                    zpwSek: "saved.200.a0.sek_a22",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "local_conversations": .array([
                            localConv(id: "3000301", name: "Secret Target", previewText: "Visible at first", previewTsMs: 1700000301000),
                            localConv(id: "3000302", name: "Stay Visible", previewText: "Still here", previewTsMs: 1700000300000),
                        ]),
                    ]
                ),
                server: [
                    loginInfoScript(uid: "2000222", zpwSek: "saved.200.a0.sek_a22", displayName: "Actions User 22"),
                    profileMeScript(uid: "2000222", displayName: "Actions User 22"),
                    httpScript(path: "/api/hiddenconvers/update-pin", method: "GET", json: .object(["error_code": .int(0), "data": .object([:])])),
                    httpScript(path: "/api/hiddenconvers/add-remove", method: "POST", json: .object(["error_code": .int(0), "data": .object([:])])),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("hide_new_pin"), "args": .object(["id": .string("3000301"), "pin": .string("1234")])]),
                    .object(["snapshot": .string("after_first_hide")]),
                    .object(["cmd": .string("hide_new_pin"), "args": .object(["id": .string("3000302"), "pin": .string("5678")])]),
                ]
            ),

            // 23. hidden_wrong_pin
            ScenarioDef(
                name: "hidden_wrong_pin",
                seed: readySessionSeed(
                    userId: "2000223",
                    displayName: "Actions User 23",
                    zpwSek: "saved.200.a0.sek_a23",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "hidden_pin_md5": .string(pin1234MD5),
                        "local_conversations": .array([
                            localConv(id: "3000311", name: "Target 311", previewText: "Msg", previewTsMs: 1700000311000),
                        ]),
                    ]
                ),
                server: [
                    loginInfoScript(uid: "2000223", zpwSek: "saved.200.a0.sek_a23", displayName: "Actions User 23"),
                    profileMeScript(uid: "2000223", displayName: "Actions User 23"),
                    httpScript(path: "/api/hiddenconvers/add-remove", method: "POST", json: .object(["error_code": .int(0), "data": .object([:])])),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("hide"), "args": .object(["id": .string("3000311"), "pin": .string("9999")])]),
                    .object(["snapshot": .string("after_wrong_pin")]),
                    .object(["cmd": .string("hide"), "args": .object(["id": .string("3000311"), "pin": .string("1234")])]),
                ]
            ),

            // 24. hidden_unhide
            ScenarioDef(
                name: "hidden_unhide",
                seed: readySessionSeed(
                    userId: "2000224",
                    displayName: "Actions User 24",
                    zpwSek: "saved.200.a0.sek_a24",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "hidden_ids": .array([.string("3000321")]),
                        "hidden_pin_md5": .string(pin1234MD5),
                        "local_conversations": .array([
                            localConv(id: "3000321", name: "Hidden 321", previewText: "Shh", previewTsMs: 1700000321000),
                        ]),
                    ]
                ),
                server: [
                    loginInfoScript(uid: "2000224", zpwSek: "saved.200.a0.sek_a24", displayName: "Actions User 24"),
                    profileMeScript(uid: "2000224", displayName: "Actions User 24"),
                    httpScript(path: "/api/hiddenconvers/add-remove", method: "POST", json: .object(["error_code": .int(0), "data": .object([:])])),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("unhide"), "args": .object(["id": .string("3000321"), "pin": .string("0000")])]),
                    .object(["snapshot": .string("after_wrong_pin")]),
                    .object(["cmd": .string("unhide"), "args": .object(["id": .string("3000321"), "pin": .string("1234")])]),
                ]
            ),

            // 25. hidden_reset_pin
            ScenarioDef(
                name: "hidden_reset_pin",
                seed: readySessionSeed(
                    userId: "2000225",
                    displayName: "Actions User 25",
                    zpwSek: "saved.200.a0.sek_a25",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "hidden_ids": .array([.string("3000331")]),
                        "hidden_pin_md5": .string(pin1234MD5),
                        "local_conversations": .array([
                            localConv(id: "3000331", name: "Hidden 331", previewText: "Shh", previewTsMs: 1700000331000),
                        ]),
                    ]
                ),
                server: [
                    loginInfoScript(uid: "2000225", zpwSek: "saved.200.a0.sek_a25", displayName: "Actions User 25"),
                    profileMeScript(uid: "2000225", displayName: "Actions User 25"),
                    httpScript(path: "/api/hiddenconvers/update-pin", method: "GET", json: .object(["error_code": .int(0), "data": .object([:])])),
                    httpScript(path: "/api/hiddenconvers/reset", method: "GET", json: .object(["error_code": .int(0), "data": .object([:])])),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("set_pin"), "args": .object(["pin": .string("5678"), "changed": .bool(true)])]),
                    .object(["snapshot": .string("after_change_pin")]),
                    .object(["cmd": .string("reset_pin")]),
                ]
            ),

            // 26. hidden_server_sync
            ScenarioDef(
                name: "hidden_server_sync",
                seed: readySessionSeed(
                    userId: "2000226",
                    displayName: "Actions User 26",
                    zpwSek: "saved.200.a0.sek_a26",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "local_conversations": .array([
                            localConv(id: "3000341", name: "Peer 341", previewText: "One", previewTsMs: 1700000341000),
                            localConv(id: "g3000342", isGroup: true, name: "Group 342", previewText: "Two", previewTsMs: 1700000342000),
                        ]),
                    ]
                ),
                server: [
                    loginInfoScript(uid: "2000226", zpwSek: "saved.200.a0.sek_a26", displayName: "Actions User 26"),
                    profileMeScript(uid: "2000226", displayName: "Actions User 26"),
                    httpScript(
                        path: "/api/hiddenconvers/get-all",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "pin": .string(pin1234MD5),
                                "threads": .array([
                                    .object(["thread_id": .string("3000341"), "is_group": .int(0)]),
                                    .object(["thread_id": .string("3000342"), "is_group": .int(1)]),
                                ]),
                            ]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("sync_hidden")]),
                    .object(["snapshot": .string("after_server_sync")]),
                    .object(["cmd": .string("apply_server_hidden"), "args": .object(["pin": .string(""), "thread_ids": .array([])])]),
                ]
            ),

            // 27. hidden_search_unlock
            ScenarioDef(
                name: "hidden_search_unlock",
                seed: readySessionSeed(
                    userId: "2000227",
                    displayName: "Actions User 27",
                    zpwSek: "saved.200.a0.sek_a27",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "hidden_ids": .array([.string("3000351")]),
                        "hidden_pin_md5": .string(pin1234MD5),
                        "local_conversations": .array([
                            localConv(id: "3000351", name: "Hidden 351", previewText: "Locked", previewTsMs: 1700000351000),
                        ]),
                    ]
                ),
                server: [
                    loginInfoScript(uid: "2000227", zpwSek: "saved.200.a0.sek_a27", displayName: "Actions User 27"),
                    profileMeScript(uid: "2000227", displayName: "Actions User 27"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("hidden_search"), "args": .object(["query": .string("12")])]),
                    .object(["snapshot": .string("short_query")]),
                    .object(["cmd": .string("hidden_search"), "args": .object(["query": .string("9999")])]),
                    .object(["snapshot": .string("wrong_query")]),
                    .object(["cmd": .string("hidden_search"), "args": .object(["query": .string("1234")])]),
                    .object(["snapshot": .string("matched_query")]),
                    .object(["cmd": .string("unlock_from_pin_search"), "args": .object(["id": .string("3000351")])]),
                    .object(["snapshot": .string("after_unlock")]),
                    .object(["cmd": .string("relock_hidden")]),
                ]
            ),

            // 28. actions_state_json
            ScenarioDef(
                name: "actions_state_json",
                seed: readySessionSeed(
                    userId: "2000228",
                    displayName: "Actions User 28",
                    zpwSek: "saved.200.a0.sek_a28",
                    suppress: ["ws", "long_poll"]
                ),
                server: [
                    loginInfoScript(uid: "2000228", zpwSek: "saved.200.a0.sek_a28", displayName: "Actions User 28"),
                    profileMeScript(uid: "2000228", displayName: "Actions User 28"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object([
                        "cmd": .string("handle_conversation_actions"),
                        "args": .object([
                            "state": .object([
                                "convActions": .object([
                                    "loaded": .bool(true),
                                    "hiddenKnown": .bool(true),
                                    "hiddenEnabled": .bool(true),
                                    "hasHiddenPin": .bool(true),
                                    "hiddenIds": .array([.string("3000362")]),
                                    "markUnreadEnabled": .bool(true),
                                    "flags": .object([
                                        "3000361": .int(513), // pinned + unreadMark
                                        "3000362": .int(6),   // archived + hidden
                                    ]),
                                    "left": .object(["g363": .string("leaving")]),
                                    "epoch": .int(42),
                                    "late": .object([
                                        "seq": .int(3),
                                        "text": .string("Đã bỏ ẩn trò chuyện"),
                                        "ok": .bool(true),
                                        "neutral": .bool(false),
                                        "removedId": .string("3000362"),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]
            ),

            // 29. labels_crud
            ScenarioDef(
                name: "labels_crud",
                seed: readySessionSeed(
                    userId: "2000229",
                    displayName: "Actions User 29",
                    zpwSek: "saved.200.a0.sek_a29",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "archived_ids": .array([.string("3000373")]),
                        "unread_marks": .array([.string("3000372")]),
                        "local_conversations": .array([
                            localConv(id: "3000371", name: "Conv 371", previewText: "Focused 1", previewTsMs: 1700000373000),
                            localConv(id: "3000372", name: "Conv 372", previewText: "Focused 2 unread", previewTsMs: 1700000372000),
                            localConv(id: "3000373", name: "Conv 373", previewText: "Archived 3", previewTsMs: 1700000371000),
                        ]),
                    ]
                ),
                server: [
                    loginInfoScript(uid: "2000229", zpwSek: "saved.200.a0.sek_a29", displayName: "Actions User 29"),
                    profileMeScript(uid: "2000229", displayName: "Actions User 29"),
                    // 6 label_* updates (create x2, assign, update, reorder, delete)
                    httpScript(path: "/api/convlabel/update", method: "POST", json: .object(["error_code": .int(0), "data": .object([:])])),
                    httpScript(path: "/api/convlabel/update", method: "POST", json: .object(["error_code": .int(0), "data": .object([:])])),
                    httpScript(path: "/api/convlabel/update", method: "POST", json: .object(["error_code": .int(0), "data": .object([:])])),
                    httpScript(path: "/api/convlabel/update", method: "POST", json: .object(["error_code": .int(0), "data": .object([:])])),
                    httpScript(path: "/api/convlabel/update", method: "POST", json: .object(["error_code": .int(0), "data": .object([:])])),
                    httpScript(path: "/api/convlabel/update", method: "POST", json: .object(["error_code": .int(0), "data": .object([:])])),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object([
                        "cmd": .string("label_create"),
                        "args": .object(["name": .string("VIP"), "color_hex": .string("#FF5733"), "conversation_ids": .array([.string("3000371")])]),
                        "now_ms": .int(1700000300000),
                        "rand4": .string("A1B2"),
                    ]),
                    .object(["snapshot": .string("after_create_1")]),
                    .object([
                        "cmd": .string("label_create"),
                        "args": .object(["name": .string("Work"), "color_hex": .string("#0068FF"), "conversation_ids": .array([])]),
                        "now_ms": .int(1700000300500),
                        "rand4": .string("C3D4"),
                    ]),
                    .object(["cmd": .string("label_assign"), "args": .object(["conversation_id": .string("3000372"), "label_id": .string("lbl_1700000300500_C3D4")])]),
                    .object(["cmd": .string("label_update"), "args": .object(["id": .string("lbl_1700000300000_A1B2"), "name": .string("VIP Plus"), "color_hex": .string("#33CC66")])]),
                    .object(["cmd": .string("label_reorder"), "args": .object(["ids": .array([.string("lbl_1700000300500_C3D4"), .string("lbl_1700000300000_A1B2")])])]),
                    .object(["cmd": .string("set_filter"), "args": .object(["type": .int(0), "label_ids": .array([.string("lbl_1700000300000_A1B2")])])]),
                    .object(["snapshot": .string("filtered_by_label")]),
                    .object(["cmd": .string("set_filter"), "args": .object(["type": .int(4), "label_ids": .array([])])]),
                    .object(["snapshot": .string("filtered_other")]),
                    .object(["cmd": .string("set_filter"), "args": .object(["type": .int(1), "label_ids": .array([])])]),
                    .object(["snapshot": .string("filtered_unread")]),
                    .object(["cmd": .string("set_filter"), "args": .object(["type": .int(3), "label_ids": .array([])])]),
                    .object(["cmd": .string("label_delete"), "args": .object(["id": .string("lbl_1700000300000_A1B2")])]),
                ]
            ),

            // 30. labels_server_sync
            ScenarioDef(
                name: "labels_server_sync",
                seed: readySessionSeed(
                    userId: "2000230",
                    displayName: "Actions User 30",
                    zpwSek: "saved.200.a0.sek_a30",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "local_conversations": .array([
                            localConv(id: "3000381", name: "Peer 381", previewText: "Hi", previewTsMs: 1700000381000),
                            localConv(id: "g382", isGroup: true, name: "Group 382", previewText: "Yo", previewTsMs: 1700000382000),
                        ]),
                    ]
                ),
                server: [
                    loginInfoScript(uid: "2000230", zpwSek: "saved.200.a0.sek_a30", displayName: "Actions User 30"),
                    profileMeScript(uid: "2000230", displayName: "Actions User 30"),
                    httpScript(
                        path: "/api/convlabel/get",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "version": .int(5),
                                "labelData": .array([
                                    .object(["id": .string("l_cust"), "textKey": .string("STR_LABEL_CUSTOMER"), "color": .string("#FF6600"), "offset": .int(0), "conversations": .array([.string("u3000381")])]),
                                    .object(["id": .string("l_fam"), "textKey": .string("STR_LABEL_FAMILY"), "color": .string("#00AA44"), "offset": .int(1), "conversations": .array([])]),
                                    .object(["id": .string("l_wrk"), "textKey": .string("STR_LABEL_WORK"), "color": .string("#0068FF"), "offset": .int(2), "conversations": .array([.string("g382")])]),
                                    .object(["id": .string("l_frd"), "textKey": .string("STR_LABEL_FRIENDS"), "color": .string("#9933FF"), "offset": .int(3), "conversations": .array([])]),
                                    .object(["id": .string("l_rpl"), "textKey": .string("STR_LABEL_REPLY_LATER"), "color": .string("#FFCC00"), "offset": .int(4), "conversations": .array([])]),
                                    .object(["id": .string("l_col"), "textKey": .string("STR_LABEL_COLLEAGUE"), "color": .string("#0099CC"), "offset": .int(5), "conversations": .array([])]),
                                    .object(["id": .string("l_custom"), "text": .string("Priority Custom"), "color": .string("#EE1144"), "offset": .int(6), "conversations": .array([])]),
                                ]),
                            ]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object(["cmd": .string("sync_labels")]),
                ]
            ),

            // 31. extras_state_json
            ScenarioDef(
                name: "extras_state_json",
                seed: readySessionSeed(
                    userId: "2000231",
                    displayName: "Actions User 31",
                    zpwSek: "saved.200.a0.sek_a31",
                    suppress: ["ws", "long_poll"]
                ),
                server: [
                    loginInfoScript(uid: "2000231", zpwSek: "saved.200.a0.sek_a31", displayName: "Actions User 31"),
                    profileMeScript(uid: "2000231", displayName: "Actions User 31"),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")]), "timeout_ms": .int(5000)]),
                    .object([
                        "cmd": .string("handle_conversation_extras"),
                        "args": .object([
                            "state": .object([
                                "conversationExtras": .object([
                                    "selfConversationId": .string("92000231_override"),
                                    "archivedEnabled": .bool(false),
                                ]),
                            ]),
                        ]),
                    ]),
                ]
            ),
        ]
    }
}

@MainActor
private final class ConvTransitionRecorder {
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
                throw ConversationRecorderTests.RecorderError.timeout(
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
