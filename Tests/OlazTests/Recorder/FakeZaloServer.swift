import CryptoKit
import Foundation
import Network
import zlib
@testable import Olaz

final class FakeZaloServer: @unchecked Sendable {
    struct HTTPRequest: Sendable {
        let method: String
        let path: String
        let query: String
        let rawQuery: [String: String]
        let headers: [String: String]
        let body: Data

        func header(_ name: String) -> String? {
            headers[name.lowercased()]
        }

        func decodeEncryptedParams(key: Data) -> [String: Any]? {
            for raw in [query, String(decoding: body, as: UTF8.self)] {
                if let part = raw.split(separator: "&").first(where: { $0.hasPrefix("params=") }) {
                    let encoded = String(part.dropFirst("params=".count))
                    let decoded = encoded.removingPercentEncoding ?? encoded
                    if let plain = try? ZaloCrypto.decodeAES(key: key, base64: decoded),
                       let obj = JSONLossless.parseObject(Data(plain.utf8)) {
                        return obj
                    }
                }
            }
            return nil
        }

        func decodeEncryptedParamsQuery(key: Data) -> [String: Any]? {
            guard let part = query.split(separator: "&").first(where: { $0.hasPrefix("params=") }) else {
                return nil
            }
            let encoded = String(part.dropFirst("params=".count))
            let decoded = encoded.removingPercentEncoding ?? encoded
            guard let plain = try? ZaloCrypto.decodeAES(key: key, base64: decoded),
                  let obj = JSONLossless.parseObject(Data(plain.utf8)) else {
                return nil
            }
            return obj
        }

        func decodeEncryptedParamsBody(key: Data) -> [String: Any]? {
            let bodyStr = String(decoding: body, as: UTF8.self)
            guard let part = bodyStr.split(separator: "&").first(where: { $0.hasPrefix("params=") }) else {
                return nil
            }
            let encoded = String(part.dropFirst("params=".count))
            let decoded = encoded.removingPercentEncoding ?? encoded
            guard let plain = try? ZaloCrypto.decodeAES(key: key, base64: decoded),
                  let obj = JSONLossless.parseObject(Data(plain.utf8)) else {
                return nil
            }
            return obj
        }
    }

    struct HTTPResponse: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data

        static func json(_ status: Int = 200, _ obj: [String: Any], headers: [String: String] = [:]) -> HTTPResponse {
            let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
            return HTTPResponse(status: status, headers: headers, body: data)
        }
    }

    struct ScriptEntry: Sendable {
        let kind: String // "http" | "ws" | "ws_frame" | "ws_close"
        let path: String
        let method: String?
        let `repeat`: Bool
        let hold: Bool
        let response: CaseJSON?
        let accept: Bool
        let cmd: UInt16
        let subCmd: UInt8
        let payload: CaseJSON?
        let encrypt: UInt8?
        let key: String?
        let delayMs: Int?
        var claimed: Bool = false
        var consumed: Bool = false

        var isRefused: Bool {
            response?["error"]?.stringValue == "refused"
        }
    }

    enum ServerError: Error, CustomStringConvertible {
        case wsPushTimeout(String)
        case noScriptedWSAction(String)
        case httpReleaseTimeout(String)

        var description: String {
            switch self {
            case .wsPushTimeout(let msg): return "FakeZaloServer.wsPushTimeout: \(msg)"
            case .noScriptedWSAction(let msg): return "FakeZaloServer.noScriptedWSAction: \(msg)"
            case .httpReleaseTimeout(let msg): return "FakeZaloServer.httpReleaseTimeout: \(msg)"
            }
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "olaz.test.fake-zalo-server")
    private let lock = NSLock()
    private var entries: [ScriptEntry]
    private let customHTTPHandler: (@Sendable (HTTPRequest) -> HTTPResponse)?
    private var recordedRequests: [CaseJSON] = []
    private var hasUnscripted = false
    private var sessionSecretKey: Data?
    private var openConnections: [NWConnection] = []
    private var activeWSConnection: NWConnection?
    private var activeWSCipherKey: Data?
    private var hadWSUpgrade = false
    private var heldHTTPResponses: [@Sendable () -> Void] = []
    private var waiters: [() -> Void] = []
    private var refuseNewConnections = false
    private let wsAuthManual: Bool
    private(set) var port: UInt16 = 0
    private var stopped = false

    private static let defaultWSCipherKeyB64 = Data("0123456789abcdef0123456789abcdef".utf8).base64EncodedString()
    private static let fixedWSIV = Data("0123456789abcdef".utf8)
    private static let fixedWSAAD = Data("fedcba9876543210".utf8)

    init(serverScript: [CaseJSON], initialSecretKey: Data? = nil, wsAuthManual: Bool = false) throws {
        self.entries = serverScript.map { item in
            let kind = item["kind"]?.stringValue ?? "http"
            let path = item["path"]?.stringValue ?? "/"
            let method = item["method"]?.stringValue?.uppercased()
            let rep = item["repeat"]?.boolValue ?? false
            let hold = item["hold"]?.boolValue ?? false
            let resp = item["response"]
            let accept = item["accept"]?.boolValue ?? true
            let cmd = UInt16(clamping: max(0, item["cmd"]?.int64Value ?? 0))
            let subCmd = UInt8(clamping: max(0, item["sub_cmd"]?.int64Value ?? 0))
            let payload = item["payload"]
            let encrypt = item["encrypt"]?.int64Value.map { UInt8(clamping: max(0, $0)) }
            let key = item["key"]?.stringValue
            let delayMs = item["delay_ms"]?.int64Value.map { Int(max(0, $0)) }
            return ScriptEntry(
                kind: kind,
                path: path,
                method: method,
                repeat: rep,
                hold: hold,
                response: resp,
                accept: accept,
                cmd: cmd,
                subCmd: subCmd,
                payload: payload,
                encrypt: encrypt,
                key: key,
                delayMs: delayMs
            )
        }
        self.customHTTPHandler = nil
        self.sessionSecretKey = initialSecretKey
        self.wsAuthManual = wsAuthManual
        self.listener = try NWListener(using: .tcp)
    }

    init(httpHandler: @escaping @Sendable (HTTPRequest) -> HTTPResponse) throws {
        self.entries = []
        self.customHTTPHandler = httpHandler
        self.sessionSecretKey = nil
        self.wsAuthManual = false
        self.listener = try NWListener(using: .tcp)
    }

    var baseURLString: String { "http://127.0.0.1:\(port)" }
    var wsBaseURLString: String { "ws://127.0.0.1:\(port)" }

    func domains(for services: [String]) -> ZaloDomains {
        var domains = ZaloDomains(isolated: true)
        for svc in services {
            domains.serviceCandidates[ZaloDomains.canonicalService(svc)] = [baseURLString]
        }
        return domains
    }

    func updateSecretKey(_ key: Data) {
        lock.lock()
        sessionSecretKey = key
        lock.unlock()
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.first() { cont.resume() }
                case .failed(let err):
                    if once.first() { cont.resume(throwing: err) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        port = listener.port?.rawValue ?? 0
        await cancelListenerIfAllRemainingRefused()
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let conns = openConnections
        openConnections.removeAll()
        activeWSConnection = nil
        activeWSCipherKey = nil
        heldHTTPResponses.removeAll()
        let pendingWaiters = waiters
        waiters.removeAll()
        lock.unlock()
        listener.cancel()
        for c in conns { c.cancel() }
        for w in pendingWaiters { w() }
    }

    func waitForScriptedRequests(timeoutMs: Int = 2000) async {
        _ = await waitUntil(timeoutMs: timeoutMs) {
            allNonRefusedConsumedLocked()
        }
    }

    func waitForConsumed(path: String, timeoutMs: Int = 2000) async {
        _ = await waitUntil(timeoutMs: timeoutMs) {
            entries.allSatisfy { ($0.kind != "http" && $0.kind != "ws") || $0.path != path || $0.repeat || $0.isRefused || $0.consumed }
        }
    }

    func httpRequestCount(path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests.filter {
            $0["kind"]?.stringValue == "http" && $0["path"]?.stringValue == path
        }.count
    }

    func waitForHTTPRequests(path: String, atLeast: Int, timeoutMs: Int = 2000) async {
        _ = await waitUntil(timeoutMs: timeoutMs) {
            recordedRequests.filter {
                $0["kind"]?.stringValue == "http" && $0["path"]?.stringValue == path
            }.count >= atLeast
        }
    }

    func heldHTTPCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return heldHTTPResponses.count
    }

    @discardableResult
    func waitForHeldHTTPRequests(atLeast: Int, timeoutMs: Int = 2000) async -> Bool {
        await waitUntil(timeoutMs: timeoutMs) {
            heldHTTPResponses.count >= atLeast
        }
    }

    func releaseHeldHTTPResponses(count: Int, timeoutMs: Int = 5000) async throws {
        guard count > 0 else { return }
        for idx in 0..<count {
            let reached = await waitUntil(timeoutMs: timeoutMs) {
                !heldHTTPResponses.isEmpty || stopped
            }
            guard reached else {
                throw ServerError.httpReleaseTimeout("Timed out waiting for held HTTP response \(idx + 1)/\(count)")
            }
            let action = popNextHeldHTTPResponse()
            action?()
        }
    }

    private func popNextHeldHTTPResponse() -> (@Sendable () -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return heldHTTPResponses.isEmpty ? nil : heldHTTPResponses.removeFirst()
    }

    private func enqueueOrRunHTTPResponse(hold: Bool, _ sendAction: @escaping @Sendable () -> Void) {
        guard hold else {
            sendAction()
            return
        }
        lock.lock()
        let pendingWaiters: [() -> Void]
        if stopped {
            pendingWaiters = waiters
            waiters.removeAll()
            lock.unlock()
            for w in pendingWaiters { w() }
            return
        }
        heldHTTPResponses.append(sendAction)
        pendingWaiters = waiters
        waiters.removeAll()
        lock.unlock()
        for w in pendingWaiters { w() }
    }

    private enum WSPushTarget {
        case ready(index: Int, entry: ScriptEntry, connection: NWConnection)
        case droppedAfterLogout(index: Int)
        case missingAction
    }

    private func resolveWSPushTargetLocked() -> WSPushTarget? {
        guard let actionIdx = entries.firstIndex(where: {
            ($0.kind == "ws_frame" || $0.kind == "ws_close") && !$0.consumed && !$0.claimed
        }) else {
            return .missingAction
        }
        let hasPrecedingWS = entries[..<actionIdx].contains {
            $0.kind == "ws" && !$0.consumed && !$0.repeat
        }
        if hasPrecedingWS {
            return nil
        }
        if let conn = activeWSConnection {
            return .ready(index: actionIdx, entry: entries[actionIdx], connection: conn)
        }
        let hasRemainingWS = entries.contains {
            $0.kind == "ws" && !$0.consumed && !$0.repeat
        }
        if hadWSUpgrade && !hasRemainingWS {
            return .droppedAfterLogout(index: actionIdx)
        }
        return nil
    }

    private func claimNextWSPushTarget() -> WSPushTarget? {
        lock.lock()
        let target = resolveWSPushTargetLocked()
        var pendingWaiters: [() -> Void] = []
        switch target {
        case .ready(let idx, _, _):
            entries[idx].claimed = true
        case .droppedAfterLogout(let idx):
            entries[idx].consumed = true
            pendingWaiters = waiters
            waiters.removeAll()
        case .missingAction, nil:
            break
        }
        lock.unlock()
        for w in pendingWaiters { w() }
        return target
    }

    private func prepareWSFrameBytesIfRunning(entry: ScriptEntry) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return nil }
        var nextCipherKey = activeWSCipherKey
        let frameBytes = encodeZaloWSFrame(entry: entry, cipherKey: &nextCipherKey)
        activeWSCipherKey = nextCipherKey
        return frameBytes
    }

    private func isStoppedSync() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// Sends the next `count` scripted `ws_frame` / `ws_close` entries (only the initial `cmd == 1` auth reply
    /// right after `"ws"` is auto-sent on connect).
    func pushWebSocketActions(count: Int, timeoutMs: Int = 5000) async throws {
        guard count > 0 else { return }
        for stepOffset in 0..<count {
            let reached = await waitUntil(timeoutMs: timeoutMs) {
                resolveWSPushTargetLocked() != nil
            }
            guard reached else {
                throw ServerError.wsPushTimeout("Timed out waiting for active WS connection on ws_push item \(stepOffset + 1)/\(count)")
            }

            switch claimNextWSPushTarget() {
            case .ready(let idx, let entry, let conn):
                try await performScheduledWSAction(index: idx, entry: entry, on: conn)
            case .droppedAfterLogout:
                break
            case .missingAction:
                throw ServerError.noScriptedWSAction("No remaining ws_frame/ws_close entry for ws_push item \(stepOffset + 1)/\(count)")
            case nil:
                throw ServerError.wsPushTimeout("WS connection unavailable on ws_push item \(stepOffset + 1)/\(count)")
            }
        }
    }

    private func performScheduledWSAction(index: Int, entry: ScriptEntry, on connection: NWConnection) async throws {
        if let delayMs = entry.delayMs, delayMs > 0 {
            try await Task.sleep(for: .milliseconds(delayMs))
        }
        guard !isStoppedSync() else { return }

        if entry.kind == "ws_close" {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                self.sendWebSocketFrame(on: connection, opcode: 0x8, payload: Data([0x03, 0xE8])) {
                    connection.cancel()
                    self.clearActiveWSConnectionIfMatching(connection)
                    self.markWebSocketActionConsumed(index)
                    cont.resume()
                }
            }
            return
        }

        guard let frameBytes = prepareWSFrameBytesIfRunning(entry: entry) else { return }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.sendWebSocketFrame(on: connection, opcode: 0x2, payload: frameBytes) {
                self.markWebSocketActionConsumed(index)
                cont.resume()
            }
        }
    }

    private func clearActiveWSConnectionIfMatching(_ connection: NWConnection) {
        lock.lock()
        if activeWSConnection === connection {
            activeWSConnection = nil
            activeWSCipherKey = nil
        }
        let pendingWaiters = waiters
        waiters.removeAll()
        lock.unlock()
        for w in pendingWaiters { w() }
    }

    @discardableResult
    private func waitUntil(timeoutMs: Int, conditionLocked: () -> Bool) async -> Bool {
        func check() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return conditionLocked()
        }
        if check() { return true }
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while !check() {
            let remaining = deadline - ContinuousClock.now
            if remaining <= .zero { return false }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let once = OnceFlag()
                let finish: @Sendable () -> Void = {
                    if once.first() { cont.resume() }
                }
                lock.lock()
                if conditionLocked() {
                    lock.unlock()
                    finish()
                    return
                }
                waiters.append(finish)
                lock.unlock()

                Task {
                    try? await Task.sleep(for: min(remaining, .milliseconds(50)))
                    finish()
                }
            }
        }
        return true
    }

    private func allNonRefusedConsumedLocked() -> Bool {
        entries.allSatisfy { $0.repeat || $0.isRefused || $0.consumed }
    }

    func canonicalRequests() -> [CaseJSON] {
        lock.lock()
        let copy = recordedRequests
        lock.unlock()
        return copy.sorted { a, b in
            let ka = a["kind"]?.stringValue ?? ""
            let kb = b["kind"]?.stringValue ?? ""
            if ka != kb { return ka.utf8.lexicographicallyPrecedes(kb.utf8) }
            let pa = a["path"]?.stringValue ?? ""
            let pb = b["path"]?.stringValue ?? ""
            if pa != pb { return pa.utf8.lexicographicallyPrecedes(pb.utf8) }
            return a.canonicalString().utf8.lexicographicallyPrecedes(b.canonicalString().utf8)
        }
    }

    var hadUnscriptedRequest: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasUnscripted
    }

    private func handleConnection(_ connection: NWConnection) {
        lock.lock()
        let shouldRefuse = stopped || refuseNewConnections
        if !shouldRefuse {
            openConnections.append(connection)
        }
        lock.unlock()
        if shouldRefuse {
            connection.forceCancel()
            return
        }
        connection.start(queue: queue)
        readHTTPRequest(on: connection, buffer: Data())
    }

    private func readHTTPRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var acc = buffer
            if let data { acc.append(data) }
            if let headerEnd = acc.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = acc[..<headerEnd.lowerBound]
                let headerText = String(decoding: headerData, as: UTF8.self)
                let contentLength = self.parseContentLength(from: headerText)
                let bodyStart = headerEnd.upperBound
                let availableBody = acc.count - bodyStart
                if availableBody >= contentLength || isComplete {
                    let bodyData = acc[bodyStart..<min(acc.count, bodyStart + contentLength)]
                    self.processParsedHTTPRequest(
                        connection: connection,
                        headerText: headerText,
                        bodyData: Data(bodyData)
                    )
                    return
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.readHTTPRequest(on: connection, buffer: acc)
        }
    }

    private func parseContentLength(from headerText: String) -> Int {
        for line in headerText.split(separator: "\r\n", omittingEmptySubsequences: false).dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if name == "content-length" {
                let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                return Int(val) ?? 0
            }
        }
        return 0
    }

    private func processParsedHTTPRequest(connection: NWConnection, headerText: String, bodyData: Data) {
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else {
            connection.cancel()
            return
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else {
            connection.cancel()
            return
        }
        let method = parts[0].uppercased()
        let rawTarget = parts[1]

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }

        let components = URLComponents(string: "http://127.0.0.1\(rawTarget.hasPrefix("/") ? rawTarget : "/\(rawTarget)")")
        let path = components?.path ?? rawTarget
        let rawQueryString = rawTarget.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        var rawQuery: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            rawQuery[item.name] = item.value ?? ""
        }

        if let customHTTPHandler {
            let req = HTTPRequest(
                method: method,
                path: path,
                query: rawQueryString,
                rawQuery: rawQuery,
                headers: headers,
                body: bodyData
            )
            let resp = customHTTPHandler(req)
            sendHTTP(connection: connection, status: resp.status, headers: resp.headers, body: resp.body)
            return
        }

        if headers["upgrade"]?.lowercased() == "websocket" {
            handleWebSocketUpgrade(connection: connection, path: path, rawQuery: rawQuery, headers: headers)
            return
        }

        let paramCipherKey = deriveParamCipherKey(from: rawQuery)
        let isLongPollQuery = path == "/" && paramCipherKey == nil && rawQuery["params"] != nil
        let decryptedParams: CaseJSON? = isLongPollQuery ? nil : decryptRequestParams(
            method: method,
            rawQuery: rawQuery,
            bodyData: bodyData,
            paramCipherKey: paramCipherKey
        )
        let canonicalQuery = canonicalizeQuery(rawQuery, keepPlainParams: isLongPollQuery)

        let matched = consumeEntry(kind: "http", path: path, method: method)

        var reqDict: [String: CaseJSON] = [
            "kind": .string("http"),
            "path": .string(path),
            "method": .string(method),
            "query": .object(canonicalQuery),
            "params": decryptedParams ?? .null,
        ]
        if matched == nil {
            reqDict["unscripted"] = .bool(true)
        }
        recordRequest(.object(reqDict), unscripted: matched == nil)

        guard let entry = matched else {
            let fallback = #"{"error_code":0,"data":{}}"#
            sendHTTP(connection: connection, status: 200, headers: [:], body: Data(fallback.utf8))
            return
        }

        guard let resp = entry.response else {
            enqueueOrRunHTTPResponse(hold: entry.hold) {
                self.cancelListenerIfAllRemainingRefusedThen {
                    self.sendHTTP(connection: connection, status: 200, headers: [:], body: Data(#"{"error_code":0,"data":{}}"#.utf8))
                }
            }
            return
        }

        if let errKind = resp["error"]?.stringValue {
            enqueueOrRunHTTPResponse(hold: entry.hold) {
                switch errKind {
                case "reset":
                    connection.forceCancel()
                case "timeout":
                    // Hold open without replying until client times out or server stops.
                    break
                case "refused":
                    connection.forceCancel()
                default:
                    connection.forceCancel()
                }
            }
            return
        }

        let status = Int(resp["status"]?.int64Value ?? 200)
        var respHeaders: [String: String] = [:]
        if let hdrObj = resp["headers"]?.objectValue {
            for (k, v) in hdrObj {
                if let s = v.stringValue { respHeaders[k] = s }
            }
        }
        let finalHeaders = respHeaders

        if let rawText = resp["raw"]?.stringValue {
            enqueueOrRunHTTPResponse(hold: entry.hold) {
                self.cancelListenerIfAllRemainingRefusedThen {
                    self.sendHTTP(connection: connection, status: status, headers: finalHeaders, body: Data(rawText.utf8))
                }
            }
            return
        }

        if let jsonVal = resp["json"] {
            let substituted = substituteFakeURLs(jsonVal)
            let bodyJSON = prepareResponseJSON(
                substituted,
                path: path,
                paramCipherKey: paramCipherKey
            )
            let bodyData = Data(bodyJSON.canonicalString().utf8)
            enqueueOrRunHTTPResponse(hold: entry.hold) {
                self.cancelListenerIfAllRemainingRefusedThen {
                    self.sendHTTP(
                        connection: connection,
                        status: status,
                        headers: finalHeaders,
                        body: bodyData
                    )
                }
            }
            return
        }

        enqueueOrRunHTTPResponse(hold: entry.hold) {
            self.cancelListenerIfAllRemainingRefusedThen {
                self.sendHTTP(connection: connection, status: status, headers: finalHeaders, body: Data())
            }
        }
    }

    private func shouldStopListenerLocked() -> Bool {
        let remaining = entries.filter { !$0.consumed && !$0.repeat }
        return !remaining.isEmpty && remaining.allSatisfy { $0.isRefused }
    }

    private func markRefusedIfAllRemainingRefused() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let shouldStop = shouldStopListenerLocked()
        if shouldStop {
            refuseNewConnections = true
        }
        return shouldStop
    }

    private func cancelListenerIfAllRemainingRefusedThen(_ completion: @escaping @Sendable () -> Void) {
        guard markRefusedIfAllRemainingRefused() else {
            completion()
            return
        }
        let once = OnceFlag()
        listener.stateUpdateHandler = { state in
            if case .cancelled = state, once.first() {
                completion()
            }
        }
        listener.cancel()
        queue.asyncAfter(deadline: .now() + .milliseconds(50)) {
            if once.first() {
                completion()
            }
        }
    }

    private func cancelListenerIfAllRemainingRefused() async {
        guard markRefusedIfAllRemainingRefused() else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                if case .cancelled = state, once.first() {
                    cont.resume()
                }
            }
            listener.cancel()
            queue.asyncAfter(deadline: .now() + .milliseconds(100)) {
                if once.first() { cont.resume() }
            }
        }
    }

    private func handleWebSocketUpgrade(
        connection: NWConnection,
        path: String,
        rawQuery: [String: String],
        headers: [String: String]
    ) {
        let canonicalQuery = canonicalizeQuery(rawQuery)
        let (matched, autoAuthFrame) = consumeWebSocketEntry(path: path)
        var reqDict: [String: CaseJSON] = [
            "kind": .string("ws_connect"),
            "path": .string(path),
            "query": .object(canonicalQuery),
        ]
        if matched == nil {
            reqDict["unscripted"] = .bool(true)
        }
        recordRequest(.object(reqDict), unscripted: matched == nil)

        guard let entry = matched, entry.accept, let key = headers["sec-websocket-key"] else {
            sendHTTP(connection: connection, status: 403, headers: [:], body: Data())
            return
        }
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        let acceptKey = Data(digest).base64EncodedString()
        let handshake = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(acceptKey)\r\n\r\n"
        connection.send(content: Data(handshake.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            self.lock.lock()
            self.activeWSConnection = connection
            self.activeWSCipherKey = nil
            self.hadWSUpgrade = true
            let pendingWaiters = self.waiters
            self.waiters.removeAll()
            self.lock.unlock()
            for w in pendingWaiters { w() }

            self.readWebSocketFrames(on: connection, buffer: Data())

            if let (authIndex, authEntry) = autoAuthFrame {
                let sendAuth: @Sendable () -> Void = { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    let isStoppedNow = self.stopped || self.activeWSConnection !== connection
                    if isStoppedNow {
                        self.lock.unlock()
                        return
                    }
                    var nextKey = self.activeWSCipherKey
                    let frameBytes = self.encodeZaloWSFrame(entry: authEntry, cipherKey: &nextKey)
                    self.activeWSCipherKey = nextKey
                    self.lock.unlock()
                    self.sendWebSocketFrame(on: connection, opcode: 0x2, payload: frameBytes) {
                        self.markWebSocketActionConsumed(authIndex)
                    }
                }
                if let delayMs = authEntry.delayMs, delayMs > 0 {
                    self.queue.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: sendAuth)
                } else {
                    sendAuth()
                }
            }
        })
    }

    private func consumeWebSocketEntry(path: String) -> (ScriptEntry?, (Int, ScriptEntry)?) {
        lock.lock()
        var foundIndex: Int?
        for i in entries.indices {
            if entries[i].consumed { continue }
            if entries[i].kind != "ws" { continue }
            if entries[i].path != path { continue }
            if !entries[i].repeat {
                entries[i].consumed = true
            }
            foundIndex = i
            break
        }
        var autoAuthFrame: (Int, ScriptEntry)?
        if !wsAuthManual, let wsIdx = foundIndex, entries[wsIdx].accept {
            let nextIdx = wsIdx + 1
            if entries.indices.contains(nextIdx),
               !entries[nextIdx].consumed,
               !entries[nextIdx].claimed,
               entries[nextIdx].kind == "ws_frame",
               entries[nextIdx].cmd == 1 {
                entries[nextIdx].claimed = true
                autoAuthFrame = (nextIdx, entries[nextIdx])
            }
        }
        let matched = foundIndex.map { entries[$0] }
        let pendingWaiters = waiters
        waiters.removeAll()
        lock.unlock()
        for w in pendingWaiters { w() }
        return (matched, autoAuthFrame)
    }

    private func markWebSocketActionConsumed(_ index: Int) {
        lock.lock()
        if index < entries.count {
            entries[index].consumed = true
        }
        let pendingWaiters = waiters
        waiters.removeAll()
        lock.unlock()
        for w in pendingWaiters { w() }
    }

    private func encodeZaloWSFrame(entry: ScriptEntry, cipherKey: inout Data?) -> Data {
        let cmd = entry.cmd
        let subCmd = entry.subCmd
        let payloadJSON = entry.payload ?? .object([:])
        let payloadString = payloadJSON.canonicalString()
        let payloadData = Data(payloadString.utf8)

        let encrypt: UInt8 = {
            if let explicit = entry.encrypt { return explicit }
            if cmd == 1 || cmd == 602 { return 0 }
            if let k = cipherKey, k.count == 16 || k.count == 32 { return 2 }
            return 1
        }()

        let envelope: CaseJSON = {
            if cmd == 1 {
                let keyB64: String? = {
                    if let explicitKey = entry.key {
                        return explicitKey.isEmpty ? nil : explicitKey
                    }
                    return Self.defaultWSCipherKeyB64
                }()
                if let keyB64, let parsed = Data(base64Encoded: keyB64) {
                    cipherKey = parsed
                } else {
                    cipherKey = nil
                }
                let encodedData: String = {
                    switch encrypt {
                    case 0:
                        return payloadString
                    case 1:
                        return (try? Self.compressZlib(payloadData).base64EncodedString()) ?? ""
                    case 2:
                        guard let k = cipherKey,
                              let compressed = try? Self.compressZlib(payloadData),
                              let gcm = try? ZaloCrypto.gcmEncrypt16(key: k, plaintext: compressed, iv: Self.fixedWSIV, aad: Self.fixedWSAAD) else {
                            return ""
                        }
                        return gcm.base64EncodedString()
                    case 3:
                        guard let k = cipherKey,
                              let gcm = try? ZaloCrypto.gcmEncrypt16(key: k, plaintext: payloadData, iv: Self.fixedWSIV, aad: Self.fixedWSAAD) else {
                            return ""
                        }
                        return gcm.base64EncodedString()
                    default:
                        return payloadString
                    }
                }()
                var obj: [String: CaseJSON] = [
                    "encrypt": .int(Int64(encrypt)),
                    "data": .string(encodedData),
                ]
                if let keyB64 {
                    obj["key"] = .string(keyB64)
                }
                return .object(obj)
            }

            switch encrypt {
            case 0:
                return .object([
                    "encrypt": .int(0),
                    "data": .string(payloadString),
                ])
            case 1:
                let b64 = (try? Self.compressZlib(payloadData).base64EncodedString()) ?? ""
                return .object([
                    "encrypt": .int(1),
                    "data": .string(b64),
                ])
            case 2:
                if let k = cipherKey,
                   let compressed = try? Self.compressZlib(payloadData),
                   let gcm = try? ZaloCrypto.gcmEncrypt16(key: k, plaintext: compressed, iv: Self.fixedWSIV, aad: Self.fixedWSAAD) {
                    return .object([
                        "encrypt": .int(2),
                        "data": .string(gcm.base64EncodedString()),
                    ])
                }
                let b64 = (try? Self.compressZlib(payloadData).base64EncodedString()) ?? ""
                return .object([
                    "encrypt": .int(1),
                    "data": .string(b64),
                ])
            case 3:
                if let k = cipherKey,
                   let gcm = try? ZaloCrypto.gcmEncrypt16(key: k, plaintext: payloadData, iv: Self.fixedWSIV, aad: Self.fixedWSAAD) {
                    return .object([
                        "encrypt": .int(3),
                        "data": .string(gcm.base64EncodedString()),
                    ])
                }
                return .object([
                    "encrypt": .int(0),
                    "data": .string(payloadString),
                ])
            default:
                return .object([
                    "encrypt": .int(Int64(encrypt)),
                    "data": .string(payloadString),
                ])
            }
        }()

        var out = Data([
            1, // FRAME_VERSION
            UInt8(cmd & 0xFF),
            UInt8((cmd >> 8) & 0xFF),
            subCmd,
        ])
        out.append(Data(envelope.canonicalString().utf8))
        return out
    }

    private func sendWebSocketFrame(
        on connection: NWConnection,
        opcode: UInt8,
        payload: Data,
        completion: (@Sendable () -> Void)? = nil
    ) {
        var frame = Data()
        frame.append(0x80 | (opcode & 0x0F))
        let len = payload.count
        if len <= 125 {
            frame.append(UInt8(len))
        } else if len <= 65535 {
            frame.append(126)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(127)
            let u64 = UInt64(len)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((u64 >> shift) & 0xFF))
            }
        }
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { _ in
            completion?()
        })
    }

    private func readWebSocketFrames(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var acc = buffer
            if let data { acc.append(data) }

            while acc.count >= 2 {
                let b0 = acc[acc.startIndex]
                let b1 = acc[acc.index(after: acc.startIndex)]
                let opcode = b0 & 0x0F
                let masked = (b1 & 0x80) != 0
                let len7 = Int(b1 & 0x7F)
                var headerLen = 2
                var payloadLen = len7

                if len7 == 126 {
                    guard acc.count >= headerLen + 2 else { break }
                    let hi = Int(acc[acc.startIndex + headerLen])
                    let lo = Int(acc[acc.startIndex + headerLen + 1])
                    payloadLen = (hi << 8) | lo
                    headerLen += 2
                } else if len7 == 127 {
                    guard acc.count >= headerLen + 8 else { break }
                    var len64: UInt64 = 0
                    for i in 0..<8 {
                        len64 = (len64 << 8) | UInt64(acc[acc.startIndex + headerLen + i])
                    }
                    guard len64 <= UInt64(Int.max) else {
                        self.clearActiveWSConnectionIfMatching(connection)
                        connection.cancel()
                        return
                    }
                    payloadLen = Int(len64)
                    headerLen += 8
                }

                var maskKey: [UInt8] = []
                if masked {
                    guard acc.count >= headerLen + 4 else { break }
                    maskKey = Array(acc[(acc.startIndex + headerLen)..<(acc.startIndex + headerLen + 4)])
                    headerLen += 4
                }

                guard acc.count >= headerLen + payloadLen else { break }
                var payload = Data(acc[(acc.startIndex + headerLen)..<(acc.startIndex + headerLen + payloadLen)])
                acc.removeFirst(headerLen + payloadLen)

                if masked {
                    for i in 0..<payload.count {
                        payload[i] ^= maskKey[i % 4]
                    }
                }

                switch opcode {
                case 0x1, 0x2:
                    self.recordInboundWSFrame(payload)
                case 0x8:
                    let closePayload = payload.count >= 2 ? Data(payload.prefix(2)) : Data([0x03, 0xE8])
                    self.sendWebSocketFrame(on: connection, opcode: 0x8, payload: closePayload) {
                        self.clearActiveWSConnectionIfMatching(connection)
                        connection.cancel()
                    }
                    return
                case 0x9:
                    self.sendWebSocketFrame(on: connection, opcode: 0xA, payload: payload)
                default:
                    break
                }
            }

            if isComplete || error != nil {
                self.clearActiveWSConnectionIfMatching(connection)
                connection.cancel()
                return
            }
            self.readWebSocketFrames(on: connection, buffer: acc)
        }
    }

    private func recordInboundWSFrame(_ payload: Data) {
        guard payload.count >= 4 else { return }
        let base = payload.startIndex
        let cmd = UInt16(payload[base + 1]) | (UInt16(payload[base + 2]) << 8)
        let subCmd = payload[base + 3]
        // Keepalive pings (cmd 2 and cmd 4) depend on wall time; exclude them.
        if cmd == 2 || cmd == 4 { return }

        let bodyData = Data(payload[(base + 4)...])
        let decodedPayload: CaseJSON
        if bodyData.isEmpty {
            decodedPayload = .object([:])
        } else if let parsed = try? CaseJSON.parse(bodyData) {
            decodedPayload = canonicalizeWSSendPayload(parsed)
        } else {
            decodedPayload = .string("<binary>")
        }

        recordRequest(.object([
            "kind": .string("ws_send"),
            "cmd": .int(Int64(cmd)),
            "sub_cmd": .int(Int64(subCmd)),
            "payload": decodedPayload,
        ]), unscripted: false)
    }

    private static func compressZlib(_ input: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit_(&stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ZaloCryptoError.inflateFailed
        }
        defer { deflateEnd(&stream) }
        var output = Data(count: max(64, input.count + 64))
        var status: Int32 = Z_OK
        input.withUnsafeBytes { src in
            stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(input.count)
            repeat {
                if Int(stream.total_out) >= output.count {
                    output.count *= 2
                }
                let currentOut = Int(stream.total_out)
                let avail = output.count - currentOut
                status = output.withUnsafeMutableBytes { dst in
                    stream.next_out = dst.bindMemory(to: UInt8.self).baseAddress?.advanced(by: currentOut)
                    stream.avail_out = uInt(avail)
                    return deflate(&stream, Z_FINISH)
                }
            } while status == Z_OK
        }
        guard status == Z_STREAM_END else {
            throw ZaloCryptoError.inflateFailed
        }
        output.count = Int(stream.total_out)
        return output
    }

    private func consumeEntry(kind: String, path: String, method: String?) -> ScriptEntry? {
        lock.lock()
        var found: ScriptEntry?
        for i in entries.indices {
            if entries[i].consumed { continue }
            if entries[i].kind != kind { continue }
            if entries[i].path != path { continue }
            if let expectedMethod = entries[i].method, let actualMethod = method, expectedMethod != actualMethod {
                continue
            }
            if !entries[i].repeat {
                entries[i].consumed = true
            }
            found = entries[i]
            break
        }
        let pendingWaiters = waiters
        waiters.removeAll()
        lock.unlock()
        for w in pendingWaiters { w() }
        return found
    }

    private func recordRequest(_ req: CaseJSON, unscripted: Bool) {
        lock.lock()
        recordedRequests.append(req)
        if unscripted { hasUnscripted = true }
        let pendingWaiters = waiters
        waiters.removeAll()
        lock.unlock()
        for w in pendingWaiters { w() }
    }

    private func sendHTTP(connection: NWConnection, status: Int, headers: [String: String], body: Data) {
        var head = "HTTP/1.1 \(status) \(statusReason(status))\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func statusReason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 408: return "Request Timeout"
        case 500: return "Internal Server Error"
        default: return "Status \(status)"
        }
    }

    private func substituteFakeURLs(_ val: CaseJSON) -> CaseJSON {
        val
            .replacingString("http://fake", with: baseURLString)
            .replacingString("ws://fake", with: wsBaseURLString)
    }

    private func deriveParamCipherKey(from query: [String: String]) -> Data? {
        guard let zcid = query["zcid"], !zcid.isEmpty,
              let zcidExt = query["zcid_ext"], !zcidExt.isEmpty else {
            return nil
        }
        let md5Upper = Array(ZaloCrypto.md5Hex(zcidExt).uppercased())
        let zcidChars = Array(zcid)
        let nEven = stride(from: 0, to: md5Upper.count, by: 2).map { md5Upper[$0] }
        let aEven = stride(from: 0, to: zcidChars.count, by: 2).map { zcidChars[$0] }
        let aOdd = stride(from: 1, to: zcidChars.count, by: 2).map { zcidChars[$0] }
        let encryptKey = String(nEven.prefix(8))
            + String(aEven.prefix(12))
            + String(aOdd.reversed().prefix(12))
        return Data(encryptKey.utf8)
    }

    private func decryptRequestParams(
        method: String,
        rawQuery: [String: String],
        bodyData: Data,
        paramCipherKey: Data?
    ) -> CaseJSON? {
        var encryptedParams = rawQuery["params"]
        if encryptedParams == nil && method == "POST", !bodyData.isEmpty {
            let bodyStr = String(decoding: bodyData, as: UTF8.self)
            for pair in bodyStr.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 && kv[0] == "params" {
                    encryptedParams = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                }
            }
        }
        guard let cipherB64 = encryptedParams, !cipherB64.isEmpty else { return nil }

        let key: Data? = {
            if let paramCipherKey { return paramCipherKey }
            lock.lock()
            defer { lock.unlock() }
            return sessionSecretKey
        }()
        guard let key, key.count == 16 || key.count == 32,
              let plain = try? ZaloCrypto.decodeAES(key: key, base64: cipherB64),
              let parsed = try? CaseJSON.parse(plain) else {
            return .string("<undecryptable>")
        }
        return canonicalizeParams(parsed)
    }

    private func prepareResponseJSON(_ json: CaseJSON, path: String, paramCipherKey: Data?) -> CaseJSON {
        guard var obj = json.objectValue else { return json }

        // Learn zpw_enk from getLoginInfo so subsequent session-encrypted endpoints can use it.
        if path == "/api/login/getLoginInfo",
           let dataObj = obj["data"]?.objectValue,
           let enk = dataObj["zpw_enk"]?.stringValue, !enk.isEmpty {
            let parsed = ZaloCrypto.parseSecretKey(enk)
            if parsed.count == 16 || parsed.count == 32 {
                updateSecretKey(parsed)
            }
        }

        let errorCode = obj["error_code"]?.int64Value ?? 0
        let shouldEncryptData: Data? = {
            guard errorCode == 0 else { return nil }
            if path == "/api/login/reqqr" || path == "/api/login/getLoginInfo" {
                return paramCipherKey
            }
            if path == "/api/social/profile/me-v2" || path == "/" {
                lock.lock()
                defer { lock.unlock() }
                return sessionSecretKey
            }
            return nil
        }()

        if let key = shouldEncryptData,
           let dataVal = obj["data"],
           case .object = dataVal {
            if let enc = try? ZaloCrypto.encodeAES(key: key, plaintext: dataVal.canonicalString()) {
                obj["data"] = .string(enc)
            }
        }
        return .object(obj)
    }

    private static let volatileQueryKeys: Set<String> = [
        "imei", "computer_name", "client_time", "ts", "t", "zcid", "zcid_ext", "signkey", "params"
    ]

    private static let volatileParamKeys: Set<String> = [
        "imei", "computer_name", "client_time", "ts"
    ]

    private static let volatileWSSendKeys: Set<String> = [
        "ts", "client_time", "timestamp"
    ]

    private func canonicalizeQuery(_ rawQuery: [String: String], keepPlainParams: Bool = false) -> [String: CaseJSON] {
        var out: [String: CaseJSON] = [:]
        for (k, v) in rawQuery {
            if k == "params" && keepPlainParams {
                out[k] = .string(v)
            } else if Self.volatileQueryKeys.contains(k) {
                out[k] = .string("<volatile>")
            } else {
                out[k] = .string(v)
            }
        }
        return out
    }

    private func canonicalizeParams(_ val: CaseJSON) -> CaseJSON {
        guard let obj = val.objectValue else { return val }
        var out: [String: CaseJSON] = [:]
        for (k, v) in obj {
            if Self.volatileParamKeys.contains(k) {
                out[k] = .string("<volatile>")
            } else {
                out[k] = v
            }
        }
        return .object(out)
    }

    private func canonicalizeWSSendPayload(_ val: CaseJSON) -> CaseJSON {
        switch val {
        case .object(let obj):
            var out: [String: CaseJSON] = [:]
            for (k, v) in obj {
                if Self.volatileWSSendKeys.contains(k) {
                    out[k] = .string("<volatile>")
                } else {
                    out[k] = canonicalizeWSSendPayload(v)
                }
            }
            return .object(out)
        case .array(let arr):
            return .array(arr.map { canonicalizeWSSendPayload($0) })
        default:
            return val
        }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
