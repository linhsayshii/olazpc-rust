import Foundation
import OlazCore

struct ZaloWSQueue: Hashable, Sendable {
    let cmd: UInt16
    let subCmd: UInt8
}

struct ZaloWSQueueCursorSnapshot: Codable, Equatable, Sendable {
    var lastId: String
    var preIds: [String]
}

/// A plain chat-message envelope the Rust core already parsed (ADR-011): typed events, the contact uids the parse looked
/// names up for, and the core-side payload used to re-parse when Swift's names or uid differ (`WirePayload.resolve`).
struct ZaloWSTypedChat: @unchecked Sendable {
    let events: [ParsedWireEvent]
    let uids: [String]
    let payload: WirePayload
}

struct ZaloWSEvent: @unchecked Sendable {
    let cmd: UInt16
    let subCmd: UInt8
    let version: UInt8
    let payload: [String: Any]
    /// Set (and `payload` empty) when the Rust core delivered the envelope pre-parsed.
    var typed: ZaloWSTypedChat? = nil

    var isChatPushOrPull: Bool {
        switch cmd {
        case ZaloWebSocket.cmdPushMsg11,
             ZaloWebSocket.cmdPushMsgGroup,
             ZaloWebSocket.cmdPullMsg11,
             ZaloWebSocket.cmdPullMsgGroup,
             ZaloWebSocket.cmdPullMsg513,
             ZaloWebSocket.cmdPullMsg514,
             ZaloWebSocket.cmdPullMsg515,
             ZaloWebSocket.cmdPullMsg517,
             ZaloWebSocket.cmdPullMsg518,
             ZaloWebSocket.cmdPushMissMsg,
             ZaloWebSocket.cmdGetMsg,
             ZaloE2EEManager.cmdReceiveOneOne,
             ZaloE2EEManager.cmdReceiveGroup,
             ZaloE2EEManager.cmdPushMissE2EE:
            return true
        default:
            return false
        }
    }

    var isControlEvent: Bool {
        switch cmd {
        case ZaloWebSocket.cmdCtrlPushCtrl,
             ZaloWebSocket.cmdCtrlAction,
             ZaloWebSocket.cmdCtrlPullCtrl,
             ZaloWebSocket.cmdCtrlPullVoip:
            return true
        default:
            return false
        }
    }
}

private final class ZaloWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, Sendable {
    let onClose: @Sendable (Int, String) -> Void

    init(onClose: @escaping @Sendable (Int, String) -> Void) {
        self.onClose = onClose
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        onClose(closeCode.rawValue, text)
    }
}

/// Thread-safe cursor mirror + persistence observer shared by the actor and the Rust listener (which runs on a Rust pool thread).
final class RustWSCursorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cursors: [String: ZaloWSQueueCursorSnapshot] = [:]
    private var observer: (@Sendable ([String: ZaloWSQueueCursorSnapshot]) -> Void)?

    static func snapshots(_ entries: [CursorEntry]) -> [String: ZaloWSQueueCursorSnapshot] {
        var out: [String: ZaloWSQueueCursorSnapshot] = [:]
        for e in entries {
            let last = e.lastId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !last.isEmpty, last != "0", last != "1" else { continue }
            out[e.queueKey] = ZaloWSQueueCursorSnapshot(lastId: last, preIds: e.preIds.filter { !$0.isEmpty })
        }
        return out
    }

    static func entries(_ snapshots: [String: ZaloWSQueueCursorSnapshot]) -> [CursorEntry] {
        snapshots.map { CursorEntry(queueKey: $0.key, lastId: $0.value.lastId, preIds: $0.value.preIds) }
    }

    func setObserver(_ o: (@Sendable ([String: ZaloWSQueueCursorSnapshot]) -> Void)?) {
        lock.lock(); observer = o; lock.unlock()
    }

    func seed(_ snaps: [String: ZaloWSQueueCursorSnapshot]) {
        lock.lock(); defer { lock.unlock() }
        for (k, v) in snaps {
            let last = v.lastId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !last.isEmpty, last != "0", last != "1" else { continue }
            cursors[k] = ZaloWSQueueCursorSnapshot(lastId: last, preIds: v.preIds)
        }
    }

    func current() -> [String: ZaloWSQueueCursorSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return cursors
    }

    func clear() {
        lock.lock(); cursors.removeAll(); lock.unlock()
    }

    /// Replaces the mirror with the core's latest snapshot and notifies the observer when it changed.
    func update(_ entries: [CursorEntry]) {
        let next = Self.snapshots(entries)
        lock.lock()
        let changed = next != cursors
        cursors = next
        let obs = observer
        lock.unlock()
        if changed { obs?(next) }
    }
}

/// Bridges the Rust `zpw_ws` session into the `AsyncStream<ZaloWSEvent>` the engine consumes. Callbacks arrive on a Rust
/// blocking-pool thread: parse there, yield, return (the engine hops to the MainActor itself).
private final class RustWSListener: WsListener, @unchecked Sendable {
    let continuation: AsyncStream<ZaloWSEvent>.Continuation
    let cursors: RustWSCursorBox

    init(continuation: AsyncStream<ZaloWSEvent>.Continuation, cursors: RustWSCursorBox) {
        self.continuation = continuation
        self.cursors = cursors
    }

    func onEvent(event: WsEventRecord) {
        let payload = JSONLossless.parseObject(string: event.payloadJson) ?? [:]
        if event.cmd == ZaloWebSocket.cmdAuthen {
            // Shape only (ADR-008): the auth result code, never keys.
            let code = JSONLossless.int64(payload["error_code"]) ?? -1
            Task { @MainActor in EngineLog.shared.write("ws: rust auth event error_code=\(code)") }
        }
        continuation.yield(ZaloWSEvent(cmd: event.cmd, subCmd: event.subCmd, version: event.version, payload: payload))
    }

    func onWireEvents(cmd: UInt16, subCmd: UInt8, version: UInt8, events: [WireEvent], uids: [String], payload: WirePayload) {
        let parsed = ZaloWireParser.parsedEvents(from: events)
        continuation.yield(ZaloWSEvent(
            cmd: cmd, subCmd: subCmd, version: version, payload: [:],
            typed: ZaloWSTypedChat(events: parsed, uids: uids, payload: payload)))
    }

    func onCursorsChanged(cursors entries: [CursorEntry]) {
        cursors.update(entries)
    }

    func onStopped() {
        Task { @MainActor in EngineLog.shared.write("ws: rust session stopped") }
        continuation.finish()
    }
}

actor ZaloWebSocket {
    static let cmdAuthen: UInt16 = 1
    static let cmdPing: UInt16 = 2
    static let cmdPingActive: UInt16 = 4
    static let subKeepConnection: UInt8 = 1
    static let subKeepActive: UInt8 = 2

    static let cmdCtrlPushCtrl: UInt16 = 601
    static let cmdCtrlAction: UInt16 = 602
    static let cmdCtrlPullCtrl: UInt16 = 603
    static let cmdCtrlPullVoip: UInt16 = 604

    static let cmdPushMsg11: UInt16 = 501
    static let cmdPullMsg11: UInt16 = 510
    static let cmdPullMsgGroup: UInt16 = 511
    static let cmdPullMsg513: UInt16 = 513
    static let cmdPullMsg514: UInt16 = 514
    static let cmdPullMsg515: UInt16 = 515
    static let cmdPullMsg517: UInt16 = 517
    static let cmdPullMsg518: UInt16 = 518
    static let cmdPushMsgGroup: UInt16 = 521
    static let cmdVerifyMsg: UInt16 = 532
    static let cmdHasMsg: UInt16 = 533
    static let cmdPushMissMsg: UInt16 = 534
    static let cmdGetMsg: UInt16 = 570
    static let cmdSyncRequest: UInt16 = 590
    static let cmdSyncAckDelete: UInt16 = 591
    static let cmdSyncMobileWakeUp: UInt16 = 592

    private struct QueueCursor {
        var lastId: Any
        var preIds: Any
    }

    private var urlSession: URLSession?
    private var task: URLSessionWebSocketTask?
    private var runnerTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var continuation: AsyncStream<ZaloWSEvent>.Continuation?
    private var cipherKey: Data?
    private var authed = false
    private var reqCounter: UInt64 = 1
    private var stopped = true
    private var completedFileURLs: [String: String] = [:]
    private var fileWaiters: [String: [CheckedContinuation<String?, Never>]] = [:]
    private var requestWaiters: [String: CheckedContinuation<ZaloJSONBox?, Never>] = [:]
    private var queueCursors: [String: QueueCursor] = [:]
    private var onQueueCursorsChanged: (@Sendable ([String: ZaloWSQueueCursorSnapshot]) -> Void)?

    /// Rust path (ADR-011): the socket, framing, auth, pings, queue pulls and cursors live in the core.
    private let useRustCore: Bool
    private var rustSession: WsSession?
    private let rustCursors = RustWSCursorBox()

    init(useRustCore: Bool = RustCore.isEnabled) {
        self.useRustCore = useRustCore
    }

    var isAuthed: Bool {
        get async {
            if useRustCore {
                guard let session = rustSession else { return false }
                return (try? await session.isAuthed()) ?? false
            }
            return authed
        }
    }

    func setQueueCursorObserver(_ observer: (@Sendable ([String: ZaloWSQueueCursorSnapshot]) -> Void)?) {
        onQueueCursorsChanged = observer
        if useRustCore { rustCursors.setObserver(observer) }
    }

    func seedQueueCursors(_ snapshots: [String: ZaloWSQueueCursorSnapshot]) {
        if useRustCore {
            rustCursors.seed(snapshots)
            if let session = rustSession {
                let entries = RustWSCursorBox.entries(snapshots)
                Task { try? await session.seedCursors(cursors: entries) }
            }
            return
        }
        for (qkey, snap) in snapshots {
            let trimmed = snap.lastId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "0", trimmed != "1" else { continue }
            let lastIdVal: Any = Int64(trimmed) ?? trimmed
            queueCursors[qkey] = QueueCursor(lastId: lastIdVal, preIds: snap.preIds)
        }
    }

    func currentQueueCursors() -> [String: ZaloWSQueueCursorSnapshot] {
        if useRustCore { return rustCursors.current() }
        var out: [String: ZaloWSQueueCursorSnapshot] = [:]
        for (qkey, cursor) in queueCursors {
            let lastStr = JSONLossless.string(cursor.lastId).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lastStr.isEmpty, lastStr != "0", lastStr != "1" else { continue }
            let pre = (cursor.preIds as? [Any])?.map(JSONLossless.string).filter { !$0.isEmpty } ?? []
            out[qkey] = ZaloWSQueueCursorSnapshot(lastId: lastStr, preIds: pre)
        }
        return out
    }

    func start(endpoints: [String], zpwSek: String, myUid: String? = nil, selfConvId: String? = nil) -> AsyncStream<ZaloWSEvent> {
        stop(resetCursors: false)
        stopped = false
        let (stream, continuation) = AsyncStream.makeStream(of: ZaloWSEvent.self)
        self.continuation = continuation

        if useRustCore {
            let listener = RustWSListener(continuation: continuation, cursors: rustCursors)
            let config = WsConfigRecord(
                endpoints: endpoints.isEmpty ? ZaloDomains().ws : endpoints,
                zpwSek: zpwSek,
                seedCursors: RustWSCursorBox.entries(rustCursors.current()),
                eventCapacity: nil,
                myUid: myUid,
                selfConvId: selfConvId
            )
            do {
                rustSession = try wsStart(config: config, listener: listener)
                let count = config.endpoints.count
                Task { @MainActor in EngineLog.shared.write("ws: rust core started endpoints=\(count)") }
            } catch {
                Task { @MainActor in EngineLog.shared.write("ws: rust core start failed") }
                continuation.finish()
                self.continuation = nil
            }
            return stream
        }

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        let delegate = ZaloWebSocketDelegate { code, reason in
            Task { @MainActor in
                EngineLog.shared.write("ws: close frame code=\(code) reason=\(reason.prefix(80))")
            }
        }
        self.urlSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        let list = endpoints.isEmpty ? ZaloDomains().ws : endpoints
        runnerTask = Task { [weak self] in
            await self?.runLoop(endpoints: list, zpwSek: zpwSek)
        }
        return stream
    }

    func stop(resetCursors: Bool = true) {
        stopped = true
        if useRustCore {
            if let session = rustSession {
                rustSession = nil
                Task.detached { _ = try? await session.stop(resetCursors: resetCursors) }
            }
            for (_, list) in fileWaiters { for cont in list { cont.resume(returning: nil) } }
            fileWaiters.removeAll()
            completedFileURLs.removeAll()
            if resetCursors { rustCursors.clear() }
            continuation?.finish()
            continuation = nil
            return
        }
        pingTask?.cancel()
        pingTask = nil
        runnerTask?.cancel()
        runnerTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        cipherKey = nil
        authed = false
        for (_, list) in fileWaiters {
            for cont in list { cont.resume(returning: nil) }
        }
        fileWaiters.removeAll()
        completedFileURLs.removeAll()
        for (_, cont) in requestWaiters {
            cont.resume(returning: nil)
        }
        requestWaiters.removeAll()
        if resetCursors {
            queueCursors.removeAll()
        }
        continuation?.finish()
        continuation = nil
    }

    func waitForFileDone(fileId: String, timeoutSeconds: Double = 12) async -> String? {
        guard !fileId.isEmpty else { return nil }
        if let existing = completedFileURLs[fileId], !existing.isEmpty {
            return existing
        }
        if useRustCore {
            // The core records `file_done` from its own socket; its wait window is fixed (12 s).
            guard let session = rustSession else { return nil }
            return (try? await session.waitForFileDone(fileId: fileId, timeoutSecs: timeoutSeconds)) ?? nil
        }
        return await withCheckedContinuation { continuation in
            var waiters = fileWaiters[fileId] ?? []
            waiters.append(continuation)
            fileWaiters[fileId] = waiters
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                await self?.timeoutFileWaiters(fileId: fileId)
            }
        }
    }

    private func timeoutFileWaiters(fileId: String) {
        guard let list = fileWaiters.removeValue(forKey: fileId) else { return }
        for cont in list { cont.resume(returning: nil) }
    }

    func recordFileDone(fileId: String, url: String) {
        guard !fileId.isEmpty, !url.isEmpty else { return }
        completedFileURLs[fileId] = url
        if completedFileURLs.count > 200 {
            completedFileURLs.removeValue(forKey: completedFileURLs.keys.first ?? fileId)
        }
        if let list = fileWaiters.removeValue(forKey: fileId) {
            for cont in list { cont.resume(returning: url) }
        }
    }

    func sendFrame(cmd: UInt16, subCmd: UInt8 = 0, version: UInt8 = 1, payloadJSON: Data? = nil) async -> Bool {
        if useRustCore {
            guard let session = rustSession else { return false }
            let text = payloadJSON.flatMap { String(data: $0, encoding: .utf8) }
            return (try? await session.sendFrame(cmd: cmd, subCmd: subCmd, version: version, payloadJson: text)) ?? false
        }
        guard authed, let task else { return false }
        let frame = Self.encodeFrame(cmd: cmd, subCmd: subCmd, version: version, payloadJSON: payloadJSON)
        do {
            try await task.send(.data(frame))
            return true
        } catch {
            return false
        }
    }

    /// Encodes a `requestAsyncV2`-compatible binary frame (`{"data": innerData, "reqId": reqId}`).
    static func encodeRequestFrame(
        cmd: UInt16,
        subCmd: UInt8 = 0,
        version: UInt8 = 1,
        reqId: String,
        innerData: [String: Any]
    ) -> Data? {
        let bodyDict: [String: Any] = [
            "data": innerData,
            "reqId": reqId,
        ]
        guard let payloadJSON = try? JSONSerialization.data(withJSONObject: bodyDict, options: []) else {
            return nil
        }
        return encodeFrame(cmd: cmd, subCmd: subCmd, version: version, payloadJSON: payloadJSON)
    }

    /// Sends a `requestAsyncV2`-compatible request frame (`{"data": ..., "reqId": "req_..."}`) and awaits its response.
    func sendRequestFrame(
        cmd: UInt16,
        subCmd: UInt8 = 0,
        version: UInt8 = 1,
        reqId explicitReqId: String? = nil,
        innerData: ZaloJSONBox,
        timeoutSeconds: Double = 10
    ) async -> ZaloJSONBox? {
        if useRustCore {
            guard let session = rustSession,
                  JSONSerialization.isValidJSONObject(innerData.dict),
                  let inner = try? JSONSerialization.data(withJSONObject: innerData.dict),
                  let innerText = String(data: inner, encoding: .utf8) else { return nil }
            guard let text = (try? await session.sendRequestWithTimeout(
                cmd: cmd, subCmd: subCmd, reqId: explicitReqId, innerDataJson: innerText, timeoutSecs: timeoutSeconds
            )) ?? nil else { return nil }
            return ZaloJSONBox(JSONLossless.parseObject(string: text) ?? [:])
        }
        guard authed, let task else { return nil }
        let reqId = explicitReqId ?? nextReqId()
        guard let frame = Self.encodeRequestFrame(
            cmd: cmd,
            subCmd: subCmd,
            version: version,
            reqId: reqId,
            innerData: innerData.dict
        ) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            requestWaiters[reqId] = continuation
            Task { [weak self] in
                do {
                    try await task.send(.data(frame))
                } catch {
                    await self?.finishRequestWaiter(reqId: reqId, result: nil)
                    return
                }
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                await self?.finishRequestWaiter(reqId: reqId, result: nil)
            }
        }
    }

    private func finishRequestWaiter(reqId: String, result: ZaloJSONBox?) {
        guard let cont = requestWaiters.removeValue(forKey: reqId) else { return }
        cont.resume(returning: result)
    }

    // MARK: Frame Codec

    static func encodeFrame(cmd: UInt16, subCmd: UInt8, version: UInt8, payloadJSON: Data?) -> Data {
        var out = Data()
        out.append(version)
        var leCmd = cmd.littleEndian
        withUnsafeBytes(of: &leCmd) { out.append(contentsOf: $0) }
        out.append(subCmd)
        if let payloadJSON, !payloadJSON.isEmpty {
            out.append(payloadJSON)
        }
        return out
    }

    static func encodeFrame(cmd: UInt16, subCmd: UInt8, version: UInt8, data: [String: Any]?) -> Data {
        let jsonData = data.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: []) }
        return encodeFrame(cmd: cmd, subCmd: subCmd, version: version, payloadJSON: jsonData)
    }

    static func decodeFrame(_ data: Data) -> (version: UInt8, cmd: UInt16, subCmd: UInt8, envelope: [String: Any])? {
        guard data.count >= 4 else { return nil }
        let version = data[data.startIndex]
        let b1 = UInt16(data[data.startIndex + 1])
        let b2 = UInt16(data[data.startIndex + 2])
        let cmd = b1 | (b2 << 8)
        let subCmd = data[data.startIndex + 3]
        let body = data.dropFirst(4)
        if body.isEmpty {
            return (version, cmd, subCmd, [:])
        }
        guard let envelope = JSONLossless.parseObject(Data(body)) else { return nil }
        return (version, cmd, subCmd, envelope)
    }

    static func buildSocketURL(base: String, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> URL? {
        let parts = base.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let hostPart = String(parts[0])
        let existingQuery = parts.count > 1 ? String(parts[1]) : nil

        let afterScheme = hostPart.components(separatedBy: "://").dropFirst().first ?? hostPart
        let pathPrefix = afterScheme.contains("/") ? hostPart : "\(hostPart)/"
        var full = "\(pathPrefix)?"
        if let existingQuery, !existingQuery.isEmpty {
            full += "\(existingQuery)&"
        }
        full += "zpw_ver=\(ZaloDomains.zpwVer)&zpw_type=\(ZaloDomains.zpwType)&t=\(nowMs)"
        return URL(string: full)
    }

    /// Parses only the queue pairs declared by the server in `auth.data.ctrl_qCmds` and `auth.data.qCmds`.
    static func queuesFromAuth(_ auth: [String: Any]) -> [ZaloWSQueue] {
        guard let data = auth["data"] as? [String: Any] else { return [] }
        var seen = Set<ZaloWSQueue>()
        var result: [ZaloWSQueue] = []
        for key in ["ctrl_qCmds", "qCmds"] {
            guard let items = data[key] as? [[String: Any]] else { continue }
            for item in items {
                guard let cmdInt = JSONLossless.int64(item["cmd"]), cmdInt >= 0, cmdInt <= Int64(UInt16.max) else { continue }
                let subInt = JSONLossless.int64(item["subCmd"]) ?? 0
                let pair = ZaloWSQueue(cmd: UInt16(cmdInt), subCmd: UInt8(clamping: max(0, subInt)))
                if seen.insert(pair).inserted {
                    result.append(pair)
                }
            }
        }
        return result
    }

    static func pullFrame(cmd: UInt16, subCmd: UInt8, reqId: String, lastId: Any = 1, preIds: Any = []) -> Data {
        let isFirst = (JSONLossless.int64(lastId) == 1)
        return encodeFrame(cmd: cmd, subCmd: subCmd, version: 1, data: [
            "first": isFirst,
            "reqId": reqId,
            "lastId": lastId,
            "preIds": preIds,
        ])
    }

    static func pullNextFrame(cmd: UInt16, subCmd: UInt8, reqId: String, lastId: Any, preIds: Any) -> Data {
        encodeFrame(cmd: cmd, subCmd: subCmd, version: 1, data: [
            "first": false,
            "reqId": reqId,
            "lastId": lastId,
            "preIds": preIds,
        ])
    }

    // MARK: Connection Loop

    private func runLoop(endpoints: [String], zpwSek: String) async {
        var backoffSeconds: Double = 2
        var endpointIdx = 0

        while !stopped, !Task.isCancelled {
            let endpoint = endpoints[endpointIdx % endpoints.count]
            let connectedAt = Date()
            await runSingleSession(endpoint: endpoint, zpwSek: zpwSek)
            if stopped || Task.isCancelled { break }
            if Date().timeIntervalSince(connectedAt) > 30 {
                backoffSeconds = 2
            } else {
                backoffSeconds = min(30, backoffSeconds * 2)
            }
            endpointIdx += 1
            try? await Task.sleep(for: .seconds(backoffSeconds))
        }
    }

    private func runSingleSession(endpoint: String, zpwSek: String) async {
        guard let url = Self.buildSocketURL(base: endpoint), let urlSession else { return }
        var req = URLRequest(url: url)
        req.setValue("zpw_sek=\(zpwSek); _zlang=vi", forHTTPHeaderField: "Cookie")
        req.setValue(zpwSek, forHTTPHeaderField: "zpw_sek")
        req.setValue(ZaloDomains.wsOrigin, forHTTPHeaderField: "Origin")
        req.setValue(ZaloDomains.userAgent, forHTTPHeaderField: "User-Agent")

        let wsTask = urlSession.webSocketTask(with: req)
        self.task = wsTask
        self.cipherKey = nil
        self.authed = false
        let hostLabel = url.host ?? "-"
        Task { @MainActor in EngineLog.shared.write("ws: connecting host=\(hostLabel) type=\(ZaloDomains.zpwType)") }
        wsTask.resume()

        defer {
            pingTask?.cancel()
            pingTask = nil
            wsTask.cancel(with: .goingAway, reason: nil)
            if self.task === wsTask { self.task = nil }
            self.authed = false
            let pendingKeys = Array(self.requestWaiters.keys)
            for reqId in pendingKeys {
                self.finishRequestWaiter(reqId: reqId, result: nil)
            }
        }

        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { break }
                await self?.sendPing()
            }
        }

        while !stopped, !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await wsTask.receive()
            } catch {
                let code = wsTask.closeCode.rawValue
                Task { @MainActor in
                    EngineLog.shared.write("ws: disconnected host=\(hostLabel) closeCode=\(code)")
                }
                break
            }
            switch message {
            case .data(let data):
                await handleBinaryFrame(data, task: wsTask)
            case .string:
                break
            @unknown default:
                break
            }
        }
    }

    private func sendPing() async {
        guard authed, let task else { return }
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        let frame = Self.encodeFrame(cmd: Self.cmdPing, subCmd: Self.subKeepConnection, version: 1, data: ["eventId": ms])
        try? await task.send(.data(frame))
    }

    private func nextReqId() -> String {
        let id = "req_\(reqCounter)"
        reqCounter += 1
        return id
    }

    private func handleBinaryFrame(_ data: Data, task: URLSessionWebSocketTask) async {
        guard let (version, cmd, subCmd, envelope) = Self.decodeFrame(data) else { return }
        let encrypt = UInt8(clamping: max(0, JSONLossless.int64(envelope["encrypt"]) ?? 0))

        if cmd == Self.cmdAuthen {
            if let keyB64 = envelope["key"] as? String, !keyB64.isEmpty {
                cipherKey = Data(base64Encoded: keyB64)
            }
            let rawData = envelope["data"] as? String ?? ""
            guard let plainData = try? ZaloCrypto.decryptWSFrame(cipherKey: cipherKey, encrypt: encrypt, dataField: rawData),
                  let auth = JSONLossless.parseObject(plainData) else {
                Task { @MainActor in EngineLog.shared.write("ws: auth decrypt failed") }
                task.cancel(with: .policyViolation, reason: nil)
                return
            }
            let authCode = JSONLossless.int64(auth["error_code"]) ?? -1
            guard authCode == 0 else {
                Task { @MainActor in EngineLog.shared.write("ws: auth rejected error_code=\(authCode)") }
                continuation?.yield(ZaloWSEvent(cmd: cmd, subCmd: subCmd, version: version, payload: auth))
                task.cancel(with: .policyViolation, reason: nil)
                return
            }
            authed = true
            let queues = Self.queuesFromAuth(auth)
            let qCount = queues.count
            Task { @MainActor in EngineLog.shared.write("ws: authed queues=\(qCount)") }
            continuation?.yield(ZaloWSEvent(cmd: cmd, subCmd: subCmd, version: version, payload: auth))
            for queue in queues {
                let qkey = "\(queue.cmd)_\(queue.subCmd)"
                let cursor = queueCursors[qkey]
                let pull = Self.pullFrame(
                    cmd: queue.cmd,
                    subCmd: queue.subCmd,
                    reqId: nextReqId(),
                    lastId: cursor?.lastId ?? 1,
                    preIds: cursor?.preIds ?? []
                )
                try? await task.send(.data(pull))
            }
            return
        }

        let payload: [String: Any]
        if encrypt == 0 {
            payload = envelope
        } else if let rawData = envelope["data"] as? String,
                  let plainData = try? ZaloCrypto.decryptWSFrame(cipherKey: cipherKey, encrypt: encrypt, dataField: rawData),
                  let decoded = JSONLossless.parseObject(plainData) {
            payload = decoded
        } else {
            payload = envelope
        }

        // Resolve any pending requestAsyncV2 waiter matching `reqId`.
        let payloadDataDict = payload["data"] as? [String: Any]
        let replyReqId = JSONLossless.string(payloadDataDict?["reqId"] ?? payload["reqId"] ?? envelope["reqId"])
        if !replyReqId.isEmpty, requestWaiters[replyReqId] != nil {
            finishRequestWaiter(reqId: replyReqId, result: ZaloJSONBox(payload))
        }

        for done in Self.extractFileDoneEvents(payload) {
            recordFileDone(fileId: done.fileId, url: done.url)
        }

        if cmd == Self.cmdHasMsg,
           let payloadData = payloadDataDict,
           let qid = payloadData["queueId"],
           let ids = payloadData["ids"] {
            let getReq = Self.encodeFrame(cmd: Self.cmdGetMsg, subCmd: 0, version: 1, data: [
                "queueId": qid,
                "ids": ids,
                "lastId": "1",
                "reqId": nextReqId(),
            ])
            try? await task.send(.data(getReq))
        }

        // Update queue cursor across reconnects so offline queues aren't replayed from 1.
        if let payloadData = payloadDataDict {
            let qkey = "\(cmd)_\(subCmd)"
            let qStatus = (payloadData["queueStatus"] as? [String: Any])?[qkey] as? [String: Any]
            let shouldReset = JSONLossless.bool(payloadData["resetLastActionId"]) == true
                || JSONLossless.int64(payloadData["resetLastActionId"]) == 1
            if shouldReset {
                if queueCursors.removeValue(forKey: qkey) != nil {
                    onQueueCursorsChanged?(currentQueueCursors())
                }
            } else {
                let candidateLastId: Any? = payloadData["lastActionId"]
                    ?? qStatus?["lastId"]
                    ?? Self.highestActionId(in: payloadData).map { $0 as Any }
                let preIds: Any = qStatus?["ids"] ?? []
                if let candidateLastId,
                   !JSONLossless.string(candidateLastId).isEmpty,
                   JSONLossless.string(candidateLastId) != "0" {
                    let prev = currentQueueCursors()
                    queueCursors[qkey] = QueueCursor(lastId: candidateLastId, preIds: preIds)
                    let updated = currentQueueCursors()
                    if updated != prev {
                        onQueueCursorsChanged?(updated)
                    }
                }
                if JSONLossless.int64(payloadData["more"]) == 1 {
                    let lastId: Any = candidateLastId ?? queueCursors[qkey]?.lastId ?? 1
                    let nextPull = Self.pullNextFrame(cmd: cmd, subCmd: subCmd, reqId: nextReqId(), lastId: lastId, preIds: preIds)
                    try? await task.send(.data(nextPull))
                }
            }
        }

        continuation?.yield(ZaloWSEvent(cmd: cmd, subCmd: subCmd, version: version, payload: payload))
    }

    static func highestActionId(in payloadData: [String: Any]) -> String? {
        var maxVal: Int64 = 0
        var maxStr: String?
        for key in ["actions", "controls", "msgs", "groupMsgs", "reacts", "reactGroups"] {
            guard let rows = payloadData[key] as? [[String: Any]] else { continue }
            for row in rows {
                let raw = row["actionId"] ?? row["actId"] ?? row["id"]
                let str = JSONLossless.string(raw)
                if let num = JSONLossless.int64(raw), num > maxVal {
                    maxVal = num
                    maxStr = str
                }
            }
        }
        return maxStr
    }

    static func extractFileDoneEvents(_ payload: [String: Any]) -> [(fileId: String, url: String)] {
        let dataNode = payload["data"] as? [String: Any] ?? payload
        var candidates: [[String: Any]] = []
        if let controls = dataNode["controls"] as? [[String: Any]] {
            candidates.append(contentsOf: controls)
        }
        if let actions = dataNode["actions"] as? [[String: Any]] {
            candidates.append(contentsOf: actions)
        }
        if let dataArr = payload["data"] as? [[String: Any]] {
            for item in dataArr {
                if let sub = item["controls"] as? [[String: Any]] {
                    candidates.append(contentsOf: sub)
                } else {
                    candidates.append(item)
                }
            }
        }
        if candidates.isEmpty {
            candidates.append(dataNode)
        }

        var results: [(fileId: String, url: String)] = []
        for item in candidates {
            let contentObj: [String: Any] = {
                if let c = item["content"] as? [String: Any] { return c }
                if let cStr = item["content"] as? String,
                   let cData = cStr.data(using: .utf8),
                   let parsed = JSONLossless.parseObject(cData) {
                    return parsed
                }
                return item
            }()
            let actType = JSONLossless.string(contentObj["act_type"] ?? contentObj["actType"])
            guard actType == "file_done" || actType == "video_done" else { continue }
            let dObj: [String: Any] = {
                if let d = contentObj["data"] as? [String: Any] { return d }
                if let dStr = contentObj["data"] as? String,
                   let dData = dStr.data(using: .utf8),
                   let parsed = JSONLossless.parseObject(dData) {
                    return parsed
                }
                return contentObj
            }()
            let fileId = JSONLossless.string(dObj["fileId"] ?? contentObj["fileId"])
            let nestedData = dObj["data"] as? [String: Any]
            let url = JSONLossless.string(nestedData?["url"] ?? dObj["url"] ?? dObj["fileUrl"])
            if !fileId.isEmpty && !url.isEmpty {
                results.append((fileId: fileId, url: url))
            }
        }
        return results
    }
}
