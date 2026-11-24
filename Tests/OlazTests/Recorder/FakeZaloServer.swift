import CryptoKit
import Foundation
import Network
@testable import Olaz

final class FakeZaloServer: @unchecked Sendable {
    struct ScriptEntry: Sendable {
        let kind: String // "http" | "ws"
        let path: String
        let method: String?
        let `repeat`: Bool
        let response: CaseJSON?
        let accept: Bool
        var consumed: Bool = false

        var isRefused: Bool {
            response?["error"]?.stringValue == "refused"
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "olaz.test.fake-zalo-server")
    private let lock = NSLock()
    private var entries: [ScriptEntry]
    private var recordedRequests: [CaseJSON] = []
    private var hasUnscripted = false
    private var sessionSecretKey: Data?
    private var openConnections: [NWConnection] = []
    private var waiters: [() -> Void] = []
    private var refuseNewConnections = false
    private(set) var port: UInt16 = 0
    private var stopped = false

    init(serverScript: [CaseJSON], initialSecretKey: Data? = nil) throws {
        self.entries = serverScript.map { item in
            let kind = item["kind"]?.stringValue ?? "http"
            let path = item["path"]?.stringValue ?? "/"
            let method = item["method"]?.stringValue?.uppercased()
            let rep = item["repeat"]?.boolValue ?? false
            let resp = item["response"]
            let accept = item["accept"]?.boolValue ?? true
            return ScriptEntry(kind: kind, path: path, method: method, repeat: rep, response: resp, accept: accept)
        }
        self.sessionSecretKey = initialSecretKey
        self.listener = try NWListener(using: .tcp)
    }

    var baseURLString: String { "http://127.0.0.1:\(port)" }
    var wsBaseURLString: String { "ws://127.0.0.1:\(port)" }

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
        let pendingWaiters = waiters
        waiters.removeAll()
        lock.unlock()
        listener.cancel()
        for c in conns { c.cancel() }
        for w in pendingWaiters { w() }
    }

    func waitForScriptedRequests(timeoutMs: Int = 2000) async {
        await waitUntil(timeoutMs: timeoutMs) {
            allNonRefusedConsumedLocked()
        }
    }

    func waitForConsumed(path: String, timeoutMs: Int = 2000) async {
        await waitUntil(timeoutMs: timeoutMs) {
            entries.allSatisfy { $0.path != path || $0.repeat || $0.isRefused || $0.consumed }
        }
    }

    private func waitUntil(timeoutMs: Int, conditionLocked: () -> Bool) async {
        func check() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return conditionLocked()
        }
        if check() { return }
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while !check() {
            if ContinuousClock.now >= deadline { break }
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
                    try? await Task.sleep(for: .milliseconds(50))
                    finish()
                }
            }
        }
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
        var rawQuery: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            rawQuery[item.name] = item.value ?? ""
        }

        if headers["upgrade"]?.lowercased() == "websocket" {
            handleWebSocketUpgrade(connection: connection, path: path, rawQuery: rawQuery, headers: headers)
            return
        }

        let paramCipherKey = deriveParamCipherKey(from: rawQuery)
        let decryptedParams = decryptRequestParams(
            method: method,
            rawQuery: rawQuery,
            bodyData: bodyData,
            paramCipherKey: paramCipherKey
        )
        let canonicalQuery = canonicalizeQuery(rawQuery)

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
            cancelListenerIfAllRemainingRefusedThen {
                self.sendHTTP(connection: connection, status: 200, headers: [:], body: Data(#"{"error_code":0,"data":{}}"#.utf8))
            }
            return
        }

        if let errKind = resp["error"]?.stringValue {
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
            cancelListenerIfAllRemainingRefusedThen {
                self.sendHTTP(connection: connection, status: status, headers: finalHeaders, body: Data(rawText.utf8))
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
            cancelListenerIfAllRemainingRefusedThen {
                self.sendHTTP(
                    connection: connection,
                    status: status,
                    headers: finalHeaders,
                    body: bodyData
                )
            }
            return
        }

        cancelListenerIfAllRemainingRefusedThen {
            self.sendHTTP(connection: connection, status: status, headers: finalHeaders, body: Data())
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
        let matched = consumeEntry(kind: "ws", path: path, method: nil)
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
        connection.send(content: Data(handshake.utf8), completion: .contentProcessed { _ in })
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
        lock.unlock()
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
            if path == "/api/social/profile/me-v2" {
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
        "imei", "computer_name", "client_time", "ts", "zcid", "zcid_ext", "signkey", "params"
    ]

    private static let volatileParamKeys: Set<String> = [
        "imei", "computer_name", "client_time", "ts"
    ]

    private func canonicalizeQuery(_ rawQuery: [String: String]) -> [String: CaseJSON] {
        var out: [String: CaseJSON] = [:]
        for (k, v) in rawQuery {
            if Self.volatileQueryKeys.contains(k) {
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
