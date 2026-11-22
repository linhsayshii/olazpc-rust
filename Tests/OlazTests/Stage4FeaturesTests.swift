import Foundation
import os
import Testing
@testable import Olaz

private final class MockStage4URLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data) -> (Int, [String: Any])
    static let handlers = OSAllocatedUnfairLock<[String: Handler]>(initialState: [:])

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return handlers.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let host = url.host,
              let handler = Self.handlers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        var bodyData = request.httpBody ?? Data()
        if bodyData.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n > 0 { bodyData.append(contentsOf: buf.prefix(n)) } else { break }
            }
        }
        let (status, jsonObj) = handler(request, bodyData)
        let respData = (try? JSONSerialization.data(withJSONObject: jsonObj)) ?? Data("{}".utf8)
        let http = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: respData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite struct Stage4FeaturesTests {
    private struct RecordedHTTP: Sendable {
        let method: String
        let host: String
        let path: String
        let query: String
        let hasParamsQuery: Bool
        let payload: ZaloJSONBox
    }

    private func makeMockClient(
        root: URL,
        key: Data,
        routes: @escaping @Sendable (RecordedHTTP) -> (Int, [String: Any])
    ) async -> (client: ZaloSessionClient, host: String, recorded: OSAllocatedUnfairLock<[RecordedHTTP]>) {
        let host = "mock-stage4-\(UUID().uuidString.lowercased()).invalid"
        let recorded = OSAllocatedUnfairLock<[RecordedHTTP]>(initialState: [])

        @Sendable func decodeParams(_ encoded: String) -> [String: Any] {
            let unescaped = encoded.removingPercentEncoding ?? encoded
            guard let plain = try? ZaloCrypto.decodeAES(key: key, base64: unescaped),
                  let obj = JSONLossless.parseObject(Data(plain.utf8)) else {
                return [:]
            }
            return obj
        }

        MockStage4URLProtocol.handlers.withLock { map in
            map[host] = { req, bodyData in
                let path = req.url?.path ?? ""
                let query = req.url?.query ?? ""
                var hasParams = false
                var payload: [String: Any] = [:]
                if let paramsPart = query.split(separator: "&").first(where: { $0.hasPrefix("params=") }) {
                    hasParams = true
                    payload = decodeParams(String(paramsPart.dropFirst("params=".count)))
                }
                if payload.isEmpty {
                    let bodyStr = String(decoding: bodyData, as: UTF8.self)
                    if let paramsPart = bodyStr.split(separator: "&").first(where: { $0.hasPrefix("params=") }) {
                        payload = decodeParams(String(paramsPart.dropFirst("params=".count)))
                    }
                }
                let call = RecordedHTTP(
                    method: req.httpMethod ?? "GET",
                    host: req.url?.host ?? "",
                    path: path,
                    query: query,
                    hasParamsQuery: hasParams,
                    payload: ZaloJSONBox(payload)
                )
                recorded.withLock { $0.append(call) }
                return routes(call)
            }
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockStage4URLProtocol.self]
        let client = ZaloSessionClient(dataDirectory: root, useKeychain: false, urlSession: URLSession(configuration: config))
        var domains = ZaloDomains()
        for svc in ["group_board", "conversation", "group_poll", "profile", "group", "label", "chat"] {
            domains.serviceCandidates[svc] = ["https://\(host)"]
        }
        var account = ZaloLoginAccount()
        account.userId = "100"
        account.displayName = "Minh"
        account.send2MeId = "999"
        await client.updateCredentials(account: account, secretKey: key, zpwSek: "sek.1.2", domains: domains)
        return (client, host, recorded)
    }

    @MainActor
    private func makeMockEngine(
        root: URL,
        key: Data,
        routes: @escaping @Sendable (RecordedHTTP) -> (Int, [String: Any])
    ) async throws -> (engine: ZaloEngine, store: ZaloSQLiteStore, host: String, recorded: OSAllocatedUnfairLock<[RecordedHTTP]>) {
        let host = "mock-stage4-eng-\(UUID().uuidString.lowercased()).invalid"
        let recorded = OSAllocatedUnfairLock<[RecordedHTTP]>(initialState: [])

        @Sendable func decodeParams(_ encoded: String) -> [String: Any] {
            let unescaped = encoded.removingPercentEncoding ?? encoded
            guard let plain = try? ZaloCrypto.decodeAES(key: key, base64: unescaped),
                  let obj = JSONLossless.parseObject(Data(plain.utf8)) else {
                return [:]
            }
            return obj
        }

        MockStage4URLProtocol.handlers.withLock { map in
            map[host] = { req, bodyData in
                let path = req.url?.path ?? ""
                let query = req.url?.query ?? ""
                var hasParams = false
                var payload: [String: Any] = [:]
                if let paramsPart = query.split(separator: "&").first(where: { $0.hasPrefix("params=") }) {
                    hasParams = true
                    payload = decodeParams(String(paramsPart.dropFirst("params=".count)))
                }
                if payload.isEmpty {
                    let bodyStr = String(decoding: bodyData, as: UTF8.self)
                    if let paramsPart = bodyStr.split(separator: "&").first(where: { $0.hasPrefix("params=") }) {
                        payload = decodeParams(String(paramsPart.dropFirst("params=".count)))
                    }
                }
                let call = RecordedHTTP(
                    method: req.httpMethod ?? "GET",
                    host: req.url?.host ?? "",
                    path: path,
                    query: query,
                    hasParamsQuery: hasParams,
                    payload: ZaloJSONBox(payload)
                )
                recorded.withLock { $0.append(call) }
                return routes(call)
            }
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockStage4URLProtocol.self]
        let engine = ZaloEngine(dataDirectory: root, useKeychain: false, urlSession: URLSession(configuration: config))
        let store = try ZaloSQLiteStore(path: root.appendingPathComponent("history.sqlite3").path)
        engine.sqliteStore = store

        var domains = ZaloDomains()
        for svc in ["group_board", "conversation", "group_poll", "profile", "group", "label", "chat"] {
            domains.serviceCandidates[svc] = ["https://\(host)"]
        }
        var account = ZaloLoginAccount()
        account.userId = "100"
        account.displayName = "Minh"
        account.avatar = "https://cdn.example/me.jpg"
        account.send2MeId = "999"
        engine.applyAccountProfile(account)
        await engine.sessionClient.updateCredentials(account: account, secretKey: key, zpwSek: "sek.1.2", domains: domains)
        return (engine, store, host, recorded)
    }

    // MARK: 1. Feature Request Builders & Network Payloads

    @Test func pinBoardItemBuilderAndNetworkPayload() async throws {
        let spec = try #require(ZaloSessionClient.buildPinBoardItemRequest(groupId: "g998877", topicId: "poll_42"))
        #expect(spec.service == "group_board")
        #expect(spec.path == "/api/board/pinv2")
        #expect(spec.encryptedPayload?["grid"] as? String == "998877")
        #expect(spec.encryptedPayload?["topicId"] as? String == "poll_42")
        #expect(spec.encryptedPayload?["type"] as? Int == 3)
        #expect(ZaloSessionClient.buildPinBoardItemRequest(groupId: "g0", topicId: "poll_42") == nil)
        #expect(ZaloSessionClient.buildPinBoardItemRequest(groupId: "g998877", topicId: "  ") == nil)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-s4-pin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let key = Data("0123456789abcdef".utf8)
        let (client, host, recorded) = await makeMockClient(root: root, key: key) { _ in
            (200, ["error_code": 0, "data": ["ok": true]])
        }
        defer { _ = MockStage4URLProtocol.handlers.withLock { $0.removeValue(forKey: host) } }

        _ = try await client.pinBoardItemAPI(groupId: "g998877", topicId: "poll_42", topicType: 3)
        let calls = recorded.withLock { $0 }
        #expect(calls.count == 1)
        #expect(calls[0].method == "GET")
        #expect(calls[0].path == "/api/board/pinv2")
        #expect(JSONLossless.string(calls[0].payload.dict["grid"]) == "998877")
        #expect(JSONLossless.string(calls[0].payload.dict["topicId"]) == "poll_42")
        #expect(JSONLossless.int64(calls[0].payload.dict["type"]) == 3)
    }

    @Test func hiddenConversationsBuildersParserAndNetworkPayloads() async throws {
        let imei = "test-imei-hidden"
        let getAllSpec = ZaloSessionClient.buildFetchHiddenConversationsRequest(imei: imei)
        #expect(getAllSpec.service == "conversation")
        #expect(getAllSpec.path == "/api/hiddenconvers/get-all")
        #expect(getAllSpec.encryptedPayload?["imei"] as? String == imei)

        let parsed = ZaloSessionClient.parseHiddenConversationsResponse([
            "error_code": 0,
            "data": [
                "pin": "81DC9BDB52D04DC20036DBD8313ED055",
                "threads": [
                    ["thread_id": "201", "is_group": 0],
                    ["thread_id": "777", "is_group": 1],
                    ["thread_id": "g888", "is_group": true],
                    ["thread_id": "777", "is_group": 1],
                    ["thread_id": "0", "is_group": 0]
                ]
            ]
        ])
        #expect(parsed.pin == "81dc9bdb52d04dc20036dbd8313ed055")
        #expect(parsed.threadIds == ["201", "g777", "g888"])

        let updateSpec = try #require(ZaloSessionClient.buildUpdateHiddenPinRequest(pin: "1234", imei: imei))
        #expect(updateSpec.service == "conversation")
        #expect(updateSpec.path == "/api/hiddenconvers/update-pin")
        #expect(updateSpec.encryptedPayload?["new_pin"] as? String == "81dc9bdb52d04dc20036dbd8313ed055")
        #expect(updateSpec.encryptedPayload?["imei"] as? String == imei)
        #expect(ZaloSessionClient.buildUpdateHiddenPinRequest(pin: "", imei: imei) == nil)

        let resetSpec = ZaloSessionClient.buildResetHiddenPinRequest()
        #expect(resetSpec.service == "conversation")
        #expect(resetSpec.path == "/api/hiddenconvers/reset")
        #expect(resetSpec.encryptedPayload == nil)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-s4-hidden-net-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let key = Data("0123456789abcdef".utf8)
        let (client, host, recorded) = await makeMockClient(root: root, key: key) { call in
            if call.path == "/api/hiddenconvers/get-all" {
                return (200, [
                    "error_code": 0,
                    "data": [
                        "pin": "81dc9bdb52d04dc20036dbd8313ed055",
                        "threads": [
                            ["thread_id": "555", "is_group": 1],
                            ["thread_id": "222", "is_group": 0]
                        ]
                    ]
                ])
            }
            return (200, ["error_code": 0, "data": [:]])
        }
        defer { _ = MockStage4URLProtocol.handlers.withLock { $0.removeValue(forKey: host) } }

        let snap = try await client.fetchHiddenConversationsAPI()
        #expect(snap.pin == "81dc9bdb52d04dc20036dbd8313ed055")
        #expect(snap.threadIds == ["g555", "222"])
        _ = try await client.updateHiddenPinAPI(pin: "1234")
        _ = try await client.resetHiddenPinAPI()

        let calls = recorded.withLock { $0 }
        #expect(calls.count == 3)
        #expect(calls[0].path == "/api/hiddenconvers/get-all" && calls[0].hasParamsQuery)
        #expect(calls[1].path == "/api/hiddenconvers/update-pin" && calls[1].hasParamsQuery)
        #expect(JSONLossless.string(calls[1].payload.dict["new_pin"]) == "81dc9bdb52d04dc20036dbd8313ed055")
        #expect(calls[2].path == "/api/hiddenconvers/reset" && !calls[2].hasParamsQuery)
    }

    @Test func reminderRespondersBuilderAndNetworkPayload() async throws {
        let spec = try #require(ZaloSessionClient.buildFetchReminderRespondersRequest(reminderId: "evt_99"))
        #expect(spec.service == "group_board")
        #expect(spec.path == "/api/board/topic/listResponseEvent")
        #expect(spec.encryptedPayload?["eventId"] as? String == "evt_99")
        #expect(ZaloSessionClient.buildFetchReminderRespondersRequest(reminderId: "  ") == nil)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-s4-rmd-net-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let key = Data("0123456789abcdef".utf8)
        let (client, host, recorded) = await makeMockClient(root: root, key: key) { _ in
            (200, ["error_code": 0, "data": ["accept": ["100", "201"], "reject": ["202"]]])
        }
        defer { _ = MockStage4URLProtocol.handlers.withLock { $0.removeValue(forKey: host) } }

        _ = try await client.fetchReminderRespondersAPI(reminderId: "evt_99")
        let calls = recorded.withLock { $0 }
        #expect(calls.count == 1)
        #expect(calls[0].method == "GET")
        #expect(calls[0].path == "/api/board/topic/listResponseEvent")
        #expect(JSONLossless.string(calls[0].payload.dict["eventId"]) == "evt_99")
    }

    // MARK: 2. Poll Pin, Post-Create Pin & Admin canClose

    @MainActor
    @Test func pollCanCloseAllowsPollCreatorAndGroupCreatorOrAdmin() throws {
        let engine = ZaloEngine()
        var acc = ZaloLoginAccount()
        acc.userId = "100"
        engine.applyAccountProfile(acc)

        // 1. Poll creator can close even without group admin info
        let ownPoll = try #require(PollDetail(json: engine.normalizePollDetail([
            "question": "Q1",
            "creator": "100",
            "group_id": "555",
            "options": []
        ], id: "p1")))
        #expect(ownPoll.canClose)
        #expect(ownPoll.groupId == "g555")

        // 2. Group creator can close another member's poll
        engine.cachedGroupDetails["555"] = [
            "creatorId": "100",
            "adminIds": ["300"]
        ]
        let creatorClose = try #require(PollDetail(json: engine.normalizePollDetail([
            "question": "Q2",
            "creator": "200",
            "group_id": "555",
            "options": []
        ], id: "p2")))
        #expect(creatorClose.canClose)

        // 3. Group deputy/admin can close another member's poll
        engine.cachedGroupDetails["555"] = [
            "creatorId": "999",
            "adminIds": ["100", "300"]
        ]
        let adminClose = try #require(PollDetail(json: engine.normalizePollDetail([
            "question": "Q3",
            "creator": "200",
            "group_id": "555",
            "options": []
        ], id: "p3")))
        #expect(adminClose.canClose)

        // 4. Ordinary member cannot close another member's poll
        engine.cachedGroupDetails["555"] = [
            "creatorId": "999",
            "adminIds": ["300"]
        ]
        let memberClose = try #require(PollDetail(json: engine.normalizePollDetail([
            "question": "Q4",
            "creator": "200",
            "group_id": "555",
            "options": []
        ], id: "p4")))
        #expect(!memberClose.canClose)
    }

    @MainActor
    @Test func pollPinBoardFullReplacementAndCreateWithPin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-s4-poll-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let key = Data("0123456789abcdef".utf8)
        let pinBoardFull = OSAllocatedUnfairLock<Bool>(initialState: false)
        let pinnedRefs = OSAllocatedUnfairLock<[String]>(initialState: ["old_1", "old_2", "old_3", "old_4", "old_5"])

        let (engine, _, host, recorded) = try await makeMockEngine(root: root, key: key) { call in
            switch call.path {
            case "/api/board/pinv2":
                let tid = JSONLossless.string(call.payload.dict["topicId"])
                if pinBoardFull.withLock({ $0 }) {
                    return (200, ["error_code": 1005, "error_message": "Board pin limit reached"])
                }
                pinnedRefs.withLock { refs in
                    if !refs.contains(tid) { refs.insert(tid, at: 0) }
                }
                return (200, ["error_code": 0, "data": ["ok": true]])
            case "/api/board/unpinv2":
                if let topic = call.payload.dict["topic"] as? [String: Any] {
                    let tid = JSONLossless.string(topic["id"])
                    pinnedRefs.withLock { refs in refs.removeAll { $0 == tid } }
                }
                return (200, ["error_code": 0, "data": ["ok": true]])
            case "/api/board/pin/list":
                let refs = pinnedRefs.withLock { $0 }
                let items: [[String: Any]] = refs.map { ref in
                    ["id": ref, "type": 3, "params": ["title": "Poll \(ref)"]]
                }
                return (200, ["error_code": 0, "data": ["boardVersion": 7, "topics": items]])
            case "/api/poll/create":
                return (200, ["error_code": 0, "data": ["poll_id": "901"]])
            default:
                return (200, ["error_code": 0, "data": [:]])
            }
        }
        defer { _ = MockStage4URLProtocol.handlers.withLock { $0.removeValue(forKey: host) } }

        // Direct pin success
        let okOutcome = await engine.pinPoll("poll_1", in: "g555")
        #expect(okOutcome == .done)
        #expect(engine.polls.pins["poll_1"]?.pinned == true)

        // Full board returns needsConfirmation with oldest pin ref ("old_5")
        pinBoardFull.withLock { $0 = true }
        let fullOutcome = await engine.pinPoll("poll_6", in: "g555")
        guard case .needsConfirmation(let confirm) = fullOutcome else {
            Issue.record("Expected needsConfirmation when board is full")
            return
        }
        #expect(confirm.ref == "old_5")
        #expect(confirm.kind == "poll")

        // Confirming replacement unpins old_5 then pins poll_6
        pinBoardFull.withLock { $0 = false }
        let replaceOutcome = await engine.pinPoll("poll_6", in: "g555", confirming: confirm.ref)
        #expect(replaceOutcome == .done)
        #expect(engine.polls.pins["poll_6"]?.pinned == true)
        let paths = recorded.withLock { $0.map(\.path) }
        #expect(paths.contains("/api/board/unpinv2"))

        // createPoll with draft.pin = true pins the created poll
        var draft = PollCreateDraft()
        draft.question = "Ăn trưa?"
        draft.options = ["Phở", "Bún"]
        draft.pin = true
        let createRes = await engine.createPoll(in: "g555", draft: draft, config: PollConfig(), canPin: true)
        #expect(createRes.ok && !createRes.pinSkipped)
        #expect(engine.polls.pins["901"]?.pinned == true)

        // When board is full during createPoll, poll succeeds with pinSkipped = true
        pinBoardFull.withLock { $0 = true }
        let skippedRes = await engine.createPoll(in: "g555", draft: draft, config: PollConfig(), canPin: true)
        #expect(skippedRes.ok && skippedRes.pinSkipped)
    }

    // MARK: 3. Hidden Chat Server PIN Sync, MD5 Verification & Offline Fallback

    @MainActor
    @Test func hiddenChatServerSyncAndOfflineFallback() async throws {
        // Part A: Unauthenticated offline SHA-256 behavior preserved
        let offlineRoot = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-s4-offline-pin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: offlineRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: offlineRoot) }

        let offlineEngine = ZaloEngine(dataDirectory: offlineRoot, useKeychain: false)
        let offlineStore = try ZaloSQLiteStore(path: offlineRoot.appendingPathComponent("history.sqlite3").path)
        offlineEngine.sqliteStore = offlineStore

        let setOffline = await offlineEngine.setHiddenChatPIN("1234", changed: false)
        #expect(setOffline.ok)
        #expect(await offlineEngine.checkHiddenChatPIN("1234") == true)
        #expect(await offlineEngine.checkHiddenChatPIN("0000") == false)
        #expect((try await offlineStore.getPreferenceString(key: "hiddenPinHash"))?.isEmpty == false)
        #expect((try await offlineStore.getPreferenceString(key: "hiddenPinMD5")) == nil)

        // Part B: Authenticated server sync, MD5 verification, update-pin & reset
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-s4-hidden-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let key = Data("0123456789abcdef".utf8)
        let (engine, store, host, recorded) = try await makeMockEngine(root: root, key: key) { call in
            switch call.path {
            case "/api/hiddenconvers/get-all":
                return (200, [
                    "error_code": 0,
                    "data": [
                        "pin": ZaloSessionClient.hiddenPinMD5Hex("4321"),
                        "threads": [
                            ["thread_id": "201", "is_group": 0],
                            ["thread_id": "777", "is_group": 1]
                        ]
                    ]
                ])
            case "/api/hiddenconvers/update-pin", "/api/hiddenconvers/reset":
                return (200, ["error_code": 0, "data": [:]])
            default:
                return (200, ["error_code": 0, "data": [:]])
            }
        }
        defer { _ = MockStage4URLProtocol.handlers.withLock { $0.removeValue(forKey: host) } }

        engine.conversations = [
            ZaloEngine.ConversationSummary(id: "201", isGroup: false, name: "An", avatar: nil, pinned: false, members: 0, unread: 0, preview: nil),
            ZaloEngine.ConversationSummary(id: "g777", isGroup: true, name: "Nhóm B", avatar: nil, pinned: false, members: 3, unread: 0, preview: nil),
            ZaloEngine.ConversationSummary(id: "300", isGroup: false, name: "Bình", avatar: nil, pinned: false, members: 0, unread: 0, preview: nil)
        ]

        await engine.syncHiddenConversations()
        #expect(engine.conversationActions.hasHiddenPIN == true)
        #expect(engine.conversationActions.hiddenIds == ["201", "g777"])
        #expect(engine.conversationActions.flags(for: "201").contains(.hidden))
        #expect(engine.conversationActions.flags(for: "g777").contains(.hidden))
        #expect(engine.visibleConversations.map(\.id) == ["300"])
        #expect(await engine.checkHiddenChatPIN("4321") == true)
        #expect(await engine.checkHiddenChatPIN("1234") == false)

        let updateRes = await engine.setHiddenChatPIN("5678", changed: true)
        #expect(updateRes.ok)
        #expect(await engine.checkHiddenChatPIN("5678") == true)
        #expect(await engine.checkHiddenChatPIN("4321") == false)

        let resetRes = await engine.resetHiddenChatPIN()
        #expect(resetRes.ok)
        #expect(engine.conversationActions.hasHiddenPIN == false)
        #expect(engine.conversationActions.hiddenIds.isEmpty)
        #expect(engine.visibleConversations.map(\.id) == ["201", "g777", "300"])
        #expect((try await store.getPreferenceString(key: "hiddenPinMD5")) == nil)
        #expect((try await store.getPreferenceString(key: "hiddenPinHash")) == nil)

        let paths = recorded.withLock { $0.map(\.path) }
        #expect(paths.contains("/api/hiddenconvers/get-all"))
        #expect(paths.contains("/api/hiddenconvers/update-pin"))
        #expect(paths.contains("/api/hiddenconvers/reset"))
    }

    // MARK: 4. Reminder Watch, RSVP & Responders Enrichment

    @MainActor
    @Test func reminderWatchAndRespondersEnrichment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-s4-rmd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let key = Data("0123456789abcdef".utf8)
        let accepted = OSAllocatedUnfairLock<Bool>(initialState: false)
        let (engine, _, host, _) = try await makeMockEngine(root: root, key: key) { call in
            switch call.path {
            case "/api/board/topic/getReminder":
                let isAcc = accepted.withLock { $0 }
                return (200, [
                    "error_code": 0,
                    "data": [
                        "id": "rem_1",
                        "creatorId": "201",
                        "startTime": 1_760_000_000_000 as Int64,
                        "repeat": 2,
                        "params": #"{"title":"Họp tuần"}"#,
                        "acceptUids": isAcc ? ["201", "100"] : ["201"],
                        "rejectUids": ["202"],
                        "myRes": isAcc ? 1 : 0
                    ]
                ])
            case "/api/board/topic/updateEventResponse":
                accepted.withLock { $0 = true }
                return (200, ["error_code": 0, "data": ["ok": true]])
            case "/api/board/topic/listResponseEvent":
                return (200, [
                    "error_code": 0,
                    "data": [
                        "accept": ["100", "201"],
                        "reject": [["uid": "202"]]
                    ]
                ])
            default:
                return (200, ["error_code": 0, "data": [:]])
            }
        }
        defer { _ = MockStage4URLProtocol.handlers.withLock { $0.removeValue(forKey: host) } }

        engine.contacts.friends = [
            ContactsState.Friend(
                id: "201",
                name: "Lan",
                zaloName: "lan",
                avatar: URL(string: "https://cdn.example/lan.jpg"),
                lastActive: nil,
                online: false,
                section: "L",
                sortKey: "lan"
            )
        ]
        engine.cachedProfiles["202"] = ZaloWebKitMigrator.CachedProfile(name: "Hùng", avatar: "https://cdn.example/hung.jpg")

        let initial = try #require(await engine.reminderWatch(in: "g555", message: "rem_1", signature: ""))
        #expect(initial.id == "rem_1")
        #expect(initial.title == "Họp tuần")
        #expect(initial.repeatLabel == "Hàng tuần")
        #expect(initial.creatorName == "Lan")
        #expect(initial.acceptedCount == 1 && initial.rejectedCount == 1)
        #expect(initial.mine == nil)

        let rsvp = await engine.respondToReminder(in: "g555", message: "rem_1", accept: true)
        #expect(rsvp.ok)
        #expect(rsvp.snapshot?.mine == .accept)
        #expect(rsvp.snapshot?.acceptedCount == 2)

        let responders = try #require(await engine.reminderResponders(in: "g555", message: "rem_1"))
        #expect(responders.acceptTotal == 2 && responders.rejectTotal == 1)
        #expect(responders.accept.map(\.uid) == ["100", "201"])
        #expect(responders.accept[0].isMe && responders.accept[0].name == "Bạn")
        #expect(responders.accept[0].avatar == URL(string: "https://cdn.example/me.jpg"))
        #expect(responders.accept[1].name == "Lan")
        #expect(responders.accept[1].avatar == URL(string: "https://cdn.example/lan.jpg"))
        #expect(responders.reject[0].uid == "202" && responders.reject[0].name == "Hùng")
        #expect(responders.reject[0].avatar == URL(string: "https://cdn.example/hung.jpg"))
    }

    // MARK: 5. SQLite-Backed zCloud Aggregation & Honest Offload

    private func storedMedia(
        id: String,
        convId: String,
        kind: ChatMessage.Kind,
        text: String = "",
        tsMs: Int64,
        status: ChatMessage.Status = .sent,
        isE2EE: Bool = false
    ) throws -> StoredMessage {
        let msg = ChatMessage(
            id: id,
            conversationId: convId,
            senderId: "201",
            senderName: "Lan",
            senderAvatar: nil,
            isMine: false,
            kind: kind,
            text: text,
            date: Date(timeIntervalSince1970: Double(tsMs) / 1000),
            status: status,
            quote: nil,
            reactions: [],
            isE2EE: isE2EE,
            mentions: [],
            cardButtons: [],
            suggestsStickers: false
        )
        var stored = try #require(ZaloWireParser.encodeChatMessage(msg))
        if isE2EE {
            stored.status = "e2ee_locked"
        }
        return stored
    }

    @MainActor
    @Test func sqliteCloudAggregationPaginationAndHonestOffload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-s4-cloud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = ZaloEngine(dataDirectory: root, useKeychain: false)
        let store = try ZaloSQLiteStore(path: root.appendingPathComponent("history.sqlite3").path)
        engine.sqliteStore = store
        var acc = ZaloLoginAccount()
        acc.userId = "100"
        acc.send2MeId = "999"
        engine.applyAccountProfile(acc)

        try await store.saveConversations([
            StoredConversation(id: "101", isGroup: false, name: "An", avatar: "", pinned: false, members: 0, unread: 0, previewText: "", previewTsMs: 4000, previewFromMe: false, updatedAtMs: 4000),
            StoredConversation(id: "g202", isGroup: true, name: "Dự án X", avatar: "", pinned: false, members: 5, unread: 0, previewText: "", previewTsMs: 3000, previewFromMe: false, updatedAtMs: 3000),
            StoredConversation(id: "999", isGroup: false, name: "Cloud của tôi", avatar: "", pinned: false, members: 0, unread: 0, previewText: "", previewTsMs: 2000, previewFromMe: true, updatedAtMs: 2000)
        ])

        try await store.saveMessages([
            try storedMedia(id: "m_photo", convId: "101", kind: .photo(url: URL(string: "https://cdn.example/p.jpg"), width: 800, height: 600), tsMs: 1000),
            try storedMedia(id: "m_file", convId: "g202", kind: .file(name: "Spec.pdf", size: 500_000, url: URL(string: "https://cdn.example/spec.pdf")), text: "Spec.pdf", tsMs: 2000),
            try storedMedia(id: "m_video", convId: "g202", kind: .video(thumbnail: nil, duration: 12, url: URL(string: "https://cdn.example/v.mp4")), tsMs: 3000),
            try storedMedia(id: "m_voice", convId: "999", kind: .voice(url: URL(string: "https://cdn.example/a.m4a"), duration: 5), tsMs: 2500),
            // Locked E2EE placeholder must not be counted
            try storedMedia(id: "m_locked", convId: "101", kind: .photo(url: nil, width: 0, height: 0), tsMs: 5000, isE2EE: true)
        ])

        // Keep conversations unloaded from memory except one synced duplicate + one unsynced in-memory message
        let syncedPhoto = try #require(ZaloWireParser.decodeStoredMessage(
            try storedMedia(id: "m_photo", convId: "101", kind: .photo(url: URL(string: "https://cdn.example/p.jpg"), width: 800, height: 600), tsMs: 1000)
        ))
        let unsyncedFile = ChatMessage(
            id: "m_unsynced",
            conversationId: "101",
            senderId: "100",
            senderName: "Bạn",
            senderAvatar: nil,
            isMine: true,
            kind: .file(name: "Draft.zip", size: 250_000, url: nil),
            text: "Draft.zip",
            date: Date(timeIntervalSince1970: 6),
            status: .sending,
            quote: nil,
            reactions: [],
            isE2EE: false,
            mentions: [],
            cardButtons: [],
            suggestsStickers: false
        )
        engine.messages["101"] = [syncedPhoto, unsyncedFile]

        await engine.performRefreshCloud()
        #expect(engine.cloud.loaded)
        // Media (non-MyCloud): photo 150k + file (500k + 250k) + video 1.5M = 2.4M (syncedPhoto not double-counted!)
        #expect(engine.cloud.media.photo == 150_000)
        #expect(engine.cloud.media.file == 750_000)
        #expect(engine.cloud.media.video == 1_500_000)
        #expect(engine.cloud.media.voice == 0)
        #expect(engine.cloud.myCloudTypes.voice == 40_000)
        #expect(engine.cloud.conversations.map(\.id) == ["g202", "101", "999"])
        #expect(engine.cloud.conversations[0].name == "Dự án X")
        #expect(engine.cloud.conversations[0].total == 2_000_000)
        #expect(engine.cloud.conversations[1].total == 400_000)

        // cloudList returns SQLite-persisted items from unloaded conversations + unsynced in-memory items
        let allPage = await engine.cloudList(conversationId: nil, kind: nil, sortBySize: true, ascending: false, offset: 0, limit: 10)
        #expect(allPage.items.map(\.id) == [
            "g202|m_video|video",
            "g202|m_file|file",
            "101|m_unsynced|file",
            "101|m_photo|photo"
        ])
        #expect(allPage.items.last?.width == 800 && allPage.items.last?.height == 600)

        let groupFiles = await engine.cloudList(conversationId: "g202", kind: .file, sortBySize: false, ascending: false, offset: 0, limit: 10)
        #expect(groupFiles.items.count == 1)
        #expect(groupFiles.items[0].title == "Spec.pdf")
        #expect(groupFiles.items[0].size == 500_000)

        // cloudFetch resolves SQLite-only items even when the conversation is not loaded in memory
        let cacheDir = root.appendingPathComponent("MediaCache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let photoHash = MediaLoader.stableHash("g202|m_sqlite_photo|photo")
        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52])
        try pngHeader.write(to: cacheDir.appendingPathComponent("\(photoHash).png"))
        try await store.saveMessages([
            try storedMedia(id: "m_sqlite_photo", convId: "g202", kind: .photo(url: URL(string: "https://cdn.example/g202.png"), width: 100, height: 100), tsMs: 3500)
        ])
        if case .ready(let cloudFile) = await engine.cloudFetch("g202|m_sqlite_photo|photo") {
            #expect(cloudFile.kind == .photo)
            #expect(cloudFile.size == Int64(pngHeader.count))
        } else {
            Issue.record("Expected cloudFetch to resolve SQLite-persisted photo")
        }

        let missingFetch = await engine.cloudFetch("g202|does_not_exist|file")
        if case .failed(let msg) = missingFetch {
            #expect(msg == "Không tìm thấy tệp.")
        } else {
            Issue.record("Expected missing item fetch to fail")
        }

        // Honest offload: never fakes enabled = true or ok = true
        let offloadRes = await engine.cloudSetOffload(true)
        #expect(!offloadRes.ok)
        #expect((offloadRes.error ?? "").isEmpty == false)
        #expect(engine.cloud.settings.offloadEnabled == false)
        #expect(engine.cloud.settings.offloadAvailable == false)
    }
}
