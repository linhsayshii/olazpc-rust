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
    /// Set when a frame updated queue cursors, serialized on the WS stream after the frame itself.
    var cursorsChanged: [String: ZaloWSQueueCursorSnapshot]? = nil

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

    /// Replaces the mirror with the core's latest snapshot, notifies any observer, and returns the snapshot if changed.
    @discardableResult
    func update(_ entries: [CursorEntry]) -> [String: ZaloWSQueueCursorSnapshot]? {
        let next = Self.snapshots(entries)
        lock.lock()
        let changed = next != cursors
        cursors = next
        let obs = observer
        lock.unlock()
        if changed {
            obs?(next)
            return next
        }
        return nil
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
        if let updated = cursors.update(entries) {
            continuation.yield(ZaloWSEvent(cmd: 0, subCmd: 0, version: 0, payload: [:], cursorsChanged: updated))
        }
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

    private var continuation: AsyncStream<ZaloWSEvent>.Continuation?
    private var completedFileURLs: [String: String] = [:]

    /// Core-owned WebSocket pass-through (U2): when attached, `CoreEngine` owns the socket
    /// lifecycle and this actor forwards feature-domain sends, file-done waits, and cursor queries.
    private var coreEngine: CoreEngine?
    /// Standalone Rust path (ADR-011) kept for tests / probes that start `ZaloWebSocket` directly.
    private var rustSession: WsSession?
    private let rustCursors = RustWSCursorBox()

    init() {}

    func attachCore(_ core: CoreEngine) {
        coreEngine = core
    }

    func detachCore() {
        coreEngine = nil
    }

    static func cursorSnapshots(from entries: [CursorEntry]) -> [String: ZaloWSQueueCursorSnapshot] {
        RustWSCursorBox.snapshots(entries)
    }

    static func cursorEntries(from snapshots: [String: ZaloWSQueueCursorSnapshot]) -> [CursorEntry] {
        RustWSCursorBox.entries(snapshots)
    }

    func syncPersistedCursors(_ entries: [CursorEntry]) {
        rustCursors.update(entries)
    }

    var isAuthed: Bool {
        get async {
            if let core = coreEngine {
                return (try? await core.wsIsAuthed()) ?? false
            }
            guard let session = rustSession else { return false }
            return (try? await session.isAuthed()) ?? false
        }
    }

    func setQueueCursorObserver(_ observer: (@Sendable ([String: ZaloWSQueueCursorSnapshot]) -> Void)?) {
        rustCursors.setObserver(observer)
    }

    func seedQueueCursors(_ snapshots: [String: ZaloWSQueueCursorSnapshot]) {
        rustCursors.seed(snapshots)
        let entries = RustWSCursorBox.entries(snapshots)
        if let core = coreEngine {
            Task { try? await core.wsSeedCursors(cursors: entries) }
            return
        }
        if let session = rustSession {
            Task { try? await session.seedCursors(cursors: entries) }
        }
    }

    func currentQueueCursors() -> [String: ZaloWSQueueCursorSnapshot] {
        rustCursors.current()
    }

    func start(endpoints: [String], zpwSek: String, myUid: String? = nil, selfConvId: String? = nil) -> AsyncStream<ZaloWSEvent> {
        stop(resetCursors: false)
        let (stream, continuation) = AsyncStream.makeStream(of: ZaloWSEvent.self)
        self.continuation = continuation

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

    func stop(resetCursors: Bool = true) {
        if let session = rustSession {
            rustSession = nil
            Task.detached { _ = try? await session.stop(resetCursors: resetCursors) }
        }
        completedFileURLs.removeAll()
        if resetCursors { rustCursors.clear() }
        continuation?.finish()
        continuation = nil
    }

    func waitForFileDone(fileId: String, timeoutSeconds: Double = 12) async -> String? {
        guard !fileId.isEmpty else { return nil }
        if let existing = completedFileURLs[fileId], !existing.isEmpty {
            return existing
        }
        if let core = coreEngine {
            return (try? await core.wsWaitForFileDone(fileId: fileId, timeoutSecs: timeoutSeconds)) ?? nil
        }
        // The core records `file_done` from its own socket; its wait window is fixed (12 s).
        guard let session = rustSession else { return nil }
        return (try? await session.waitForFileDone(fileId: fileId, timeoutSecs: timeoutSeconds)) ?? nil
    }

    func recordFileDone(fileId: String, url: String) {
        guard !fileId.isEmpty, !url.isEmpty else { return }
        completedFileURLs[fileId] = url
        if completedFileURLs.count > 200 {
            completedFileURLs.removeValue(forKey: completedFileURLs.keys.first ?? fileId)
        }
        coreEngine?.wsRecordFileDone(fileId: fileId, url: url)
    }

    func sendFrame(cmd: UInt16, subCmd: UInt8 = 0, version: UInt8 = 1, payloadJSON: Data? = nil) async -> Bool {
        let text = payloadJSON.flatMap { String(data: $0, encoding: .utf8) }
        if let core = coreEngine {
            return (try? await core.wsSendFrame(cmd: cmd, subCmd: subCmd, version: version, payloadJson: text)) ?? false
        }
        guard let session = rustSession else { return false }
        return (try? await session.sendFrame(cmd: cmd, subCmd: subCmd, version: version, payloadJson: text)) ?? false
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
        guard JSONSerialization.isValidJSONObject(innerData.dict),
              let inner = try? JSONSerialization.data(withJSONObject: innerData.dict),
              let innerText = String(data: inner, encoding: .utf8) else { return nil }
        let text: String?
        if let core = coreEngine {
            text = (try? await core.wsSendRequest(
                cmd: cmd, subCmd: subCmd, version: version, reqId: explicitReqId,
                innerDataJson: innerText, timeoutSecs: timeoutSeconds
            )) ?? nil
        } else if let session = rustSession {
            text = (try? await session.sendRequestWithTimeout(
                cmd: cmd, subCmd: subCmd, reqId: explicitReqId, innerDataJson: innerText, timeoutSecs: timeoutSeconds
            )) ?? nil
        } else {
            return nil
        }
        guard let text else { return nil }
        return ZaloJSONBox(JSONLossless.parseObject(string: text) ?? [:])
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
