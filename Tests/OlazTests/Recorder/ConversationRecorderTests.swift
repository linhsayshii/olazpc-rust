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

        for scenario in scenarios {
            if scenario.slow && !runSlow {
                print("skipped slow: \(scenario.name)")
                continue
            }
            guard let expected = byName[scenario.name] else {
                XCTFail("Missing recorded case '\(scenario.name)' in \(url.path)")
                continue
            }
            let actual = try await Self.recordScenario(domain: domain, scenario)
            if let diff = CaseJSON.firstDiff(expected: expected, actual: actual) {
                XCTFail("\(scenario.name): \(diff)")
            }
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
    static func recordScenario(domain: String, _ scenario: ScenarioDef) async throws -> CaseJSON {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-conv-recorder-\(scenario.name)-\(UUID().uuidString)", isDirectory: true)
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

        let transitionRecorder = ConvTransitionRecorder {
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
                    throw RecorderError.timeout("\(scenario.name): timed out waiting for \(description)")
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

        func waitForAsyncUIAction(timeoutMs: Int = 5000, prevToastSeq: Int?, trigger: () -> Void) async throws {
            trigger()
            let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
            while true {
                if engine.conversationUI.toast?.seq != prevToastSeq {
                    return
                }
                if case .pinBoard = engine.conversationPrompt {
                    return
                }
                if ContinuousClock.now >= deadline {
                    throw RecorderError.timeout("\(scenario.name): timed out awaiting async conversation UI action")
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        do {
            for step in scenario.steps {
                if let cmd = step["cmd"]?.stringValue {
                    let args = step["args"]
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
                        engine.openConversationId = args?["id"]?.stringValue
                    case "pin":
                        let id = args?["id"]?.stringValue ?? ""
                        let prevSeq = engine.conversationUI.toast?.seq
                        try await waitForAsyncUIAction(prevToastSeq: prevSeq) {
                            engine.pinConversation(id)
                        }
                    case "unpin":
                        let id = args?["id"]?.stringValue ?? ""
                        let prevSeq = engine.conversationUI.toast?.seq
                        try await waitForAsyncUIAction(prevToastSeq: prevSeq) {
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
                        try await waitForAsyncUIAction(prevToastSeq: prevSeq) {
                            engine.moveConversation(id, toOther: toOther)
                        }
                    case "request_delete":
                        let id = args?["id"]?.stringValue ?? ""
                        engine.requestDeleteConversation(id)
                    case "confirm_delete":
                        let id = args?["id"]?.stringValue ?? ""
                        let prevSeq = engine.conversationUI.toast?.seq
                        try await waitForAsyncUIAction(prevToastSeq: prevSeq) {
                            engine.confirmDeleteConversation(id)
                        }
                    case "mark_read":
                        let id = args?["id"]?.stringValue ?? ""
                        engine.markConversationRead(id)
                        await server.waitForScriptedRequests(timeoutMs: 2000)
                        try? await Task.sleep(for: .milliseconds(20))
                    case "mark_unread":
                        let id = args?["id"]?.stringValue ?? ""
                        engine.markConversationUnread(id)
                        await server.waitForScriptedRequests(timeoutMs: 2000)
                        try? await Task.sleep(for: .milliseconds(20))
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
                        engine.createConversationLabel(name: name, colorHex: colorHex, conversationIds: convIds)
                        await server.waitForScriptedRequests(timeoutMs: 2000)
                        try? await Task.sleep(for: .milliseconds(20))
                    case "label_update":
                        let id = args?["id"]?.stringValue ?? ""
                        let name = args?["name"]?.stringValue ?? ""
                        let colorHex = args?["color_hex"]?.stringValue ?? "#0068FF"
                        engine.updateConversationLabel(id, name: name, colorHex: colorHex)
                        await server.waitForScriptedRequests(timeoutMs: 2000)
                        try? await Task.sleep(for: .milliseconds(20))
                    case "label_delete":
                        let id = args?["id"]?.stringValue ?? ""
                        engine.deleteConversationLabel(id)
                        await server.waitForScriptedRequests(timeoutMs: 2000)
                        try? await Task.sleep(for: .milliseconds(20))
                    case "label_assign":
                        let convId = args?["conversation_id"]?.stringValue ?? ""
                        let labelId = args?["label_id"]?.stringValue
                        engine.setConversationLabel(convId, labelId: labelId)
                        await server.waitForScriptedRequests(timeoutMs: 2000)
                        try? await Task.sleep(for: .milliseconds(20))
                    case "label_reorder":
                        let ids = args?["ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
                        engine.reorderConversationLabels(ids)
                        await server.waitForScriptedRequests(timeoutMs: 2000)
                        try? await Task.sleep(for: .milliseconds(20))
                    case "set_filter":
                        let typeVal = Int(args?["type"]?.int64Value ?? 0)
                        let labelIds = args?["label_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
                        if let filter = ConversationTypeFilter(rawValue: typeVal) {
                            engine.setConversationFilter(filter, labelIds: labelIds)
                        }
                    case "sync_labels":
                        await engine.syncConversationLabelsFromServer()
                    case "handle_conversation_extras":
                        let stateObj = args?["state"]?.toFoundation() as? [String: Any] ?? [:]
                        engine.handleConversationExtras(state: stateObj)
                    default:
                        throw RecorderError.invalidStep("Unknown cmd: \(cmd)")
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
                    try await server.pushWebSocketActions(count: Int(pushCount), timeoutMs: timeoutMs)
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
                    throw RecorderError.invalidStep("Unknown step: \(step.canonicalString())")
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

            try assertOnlyLocalFakeHosts(await engine.sessionClient.domains, context: "\(scenario.name) final")

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
                throw RecorderError.unscriptedRequest(scenario.name)
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
                        "date": .double(Double(row["ts_ms"]?.int64Value ?? 0) / 1000.0, raw: String(Double(row["ts_ms"]?.int64Value ?? 0) / 1000.0)),
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

    // MARK: - Domain 1: conversations (Scenario 1 for format check)

    private static func conversationsScenarios() -> [ScenarioDef] {
        [
            // 1. msg_new_conversation_1_1
            ScenarioDef(
                name: "msg_new_conversation_1_1",
                seed: readySessionSeed(
                    userId: "2000101",
                    displayName: "Conv User 1",
                    zpwSek: "saved.200.a0.sek_c1",
                    suppress: ["long_poll"],
                    extras: [
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
                    .object(["await_host": .string("e2ee_connected"), "timeout_ms": .int(5000)]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("apply_parsed_events"), "timeout_ms": .int(5000)]),
                    .object(["snapshot": .string("after_live_push")]),
                    .object(["ws_push": .int(1)]),
                    .object(["await_host": .string("apply_parsed_events"), "timeout_ms": .int(5000)]),
                ]
            ),
        ]
    }

    // MARK: - Domain 2: conversation_actions (Scenario 13 for format check)

    private static func conversationActionsScenarios() -> [ScenarioDef] {
        [
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
        ]
    }
}

@MainActor
private final class ConvTransitionRecorder {
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
