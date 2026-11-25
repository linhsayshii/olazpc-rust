import Foundation
import OlazCore
import os

/// Native Zalo PC Signal E2EE coordinator (`deviceId = 2`).
///
/// Runs Zalo's vendored `libsignal-protocol.js` inside an in-process `JSRuntime`,
/// persists identity/prekeys/sessions in `ZaloSQLiteStore` (`zaloE2EEPCStoreV1`),
/// syncs the PC prekey bundle via WebSocket (`cmd 564` / `cmd 540` with `delSS: 0`),
/// answers `INIT_SESSION` (`543`), `SESSION_OFFLINE` (`516`), and `REQUEST_PREKEYS` (`549`),
/// and decrypts incoming 1-1 E2EE wire messages (text, stickers, photos, files, voice, video, quotes).
actor ZaloE2EEManager {
    static let storePrefKey = "zaloE2EEPCStoreV1"
    static let e2eeThreadsPrefKey = "e2eeThreadsV1"

    static let cmdSessionOffline: UInt16 = 516
    static let cmdPushMissE2EE: UInt16 = 535
    static let cmdSubmitBundle: UInt16 = 540
    static let cmdGetBundle: UInt16 = 541
    static let cmdSubmitPreKeys: UInt16 = 542
    static let cmdInitSession: UInt16 = 543
    static let cmdAckInitSession: UInt16 = 544
    static let cmdDoneProcessSession: UInt16 = 545
    static let cmdRequestPreKeys: UInt16 = 549
    static let cmdReceiveOneOne: UInt16 = 551
    static let cmdReceiveGroup: UInt16 = 552
    static let cmdDeliverSeenOneOne: UInt16 = 553
    static let cmdDeleteQueueAckOneOne: UInt16 = 557
    static let cmdGetListUserE2EE: UInt16 = 563
    static let cmdGetKeyId: UInt16 = 564

    private var runtime: JSRuntime?
    /// The Rust Signal store; only set while `effectiveMode == .authoritative` (ADR-015).
    private var rust: CoreSignal?
    private let configuredMode: E2EERustMode
    private var effectiveMode: E2EERustMode
    /// JSON of the JS store as of now (`nil` = stale), the snapshot shadow decrypts run against.
    private var jsSnapshotCache: String?
    nonisolated let shadowStats = E2EEShadowStats()
    private let logSink: @Sendable (String) -> Void
    private struct ThreadCache: Sendable {
        var loadedUid: String = ""
        var e2eeThreads: Set<String> = []
    }
    private let threadCache = OSAllocatedUnfairLock(initialState: ThreadCache())
    private var loadedUid: String = "" {
        didSet {
            let uid = loadedUid
            threadCache.withLock { $0.loadedUid = uid }
        }
    }
    private var registrationId: Int = 0
    private var bundlePayload: [String: Any] = [:]
    private var didCheckServerBundleForSession = false
    private var storeDirty = false
    private var e2eeThreads: Set<String> = [] {
        didSet {
            let threads = e2eeThreads
            threadCache.withLock { $0.e2eeThreads = threads }
        }
    }
    private var peerDeviceMeta: [String: [(deviceId: Int, sessionKey: Int64)]] = [:]
    private var fetchedBundlePeers: Set<String> = []
    /// `cliMsgId.deviceId` already resent after a failed delivery report (official `MAX_RETRY_COUNT` is 1).
    private var resentDeliveries: Set<String> = []
    private var didLoadThreadsFromStore = false
    /// Global id -> uid (`/api/gid/decrypt`), for the owner of an E2EE quote.
    /// `(globalId, candidate uids)` -> (uid, how it was found).
    typealias GlobalIdResolver = @Sendable (String, [String]) async -> (uid: String, via: String)?
    private var globalIdResolver: GlobalIdResolver?

    func setGlobalIdResolver(_ resolver: @escaping GlobalIdResolver) {
        globalIdResolver = resolver
    }

    /// `mode == nil` resolves the flags (`OLAZ_E2EE_RUST`, `olaz.e2eeRust`); tests pass one.
    /// `logSink == nil` writes to the engine log.
    init(mode: E2EERustMode? = nil, logSink: (@Sendable (String) -> Void)? = nil) {
        let resolved = mode ?? E2EERustMode.resolve()
        configuredMode = resolved
        effectiveMode = resolved
        self.logSink = logSink ?? { line in Task { @MainActor in EngineLog.shared.write(line) } }
    }

    var activeMode: E2EERustMode { effectiveMode }

    /// Test hook: the JS store as JS would persist it right now.
    func debugExportJSStore() async -> String? {
        guard let rt = runtime, !loadedUid.isEmpty else { return nil }
        return try? await rt.callAsync("ZaloE2EE.pc.exportStore", [.string(loadedUid)]).stringValue
    }

    var debugHasRustStore: Bool { rust != nil }

    func reset() {
        if configuredMode == .shadow, !shadowStats.isIdle || shadowStats.snapshot != E2EEShadowStats.Snapshot() {
            logSink(shadowStats.summaryLine)
        }
        rust = nil
        effectiveMode = configuredMode
        jsSnapshotCache = nil
        loadedUid = ""
        registrationId = 0
        bundlePayload = [:]
        didCheckServerBundleForSession = false
        storeDirty = false
        e2eeThreads.removeAll()
        peerDeviceMeta.removeAll()
        fetchedBundlePeers.removeAll()
        didLoadThreadsFromStore = false
        resentDeliveries.removeAll()
    }

    func markDisconnected() {
        didCheckServerBundleForSession = false
        fetchedBundlePeers.removeAll()
    }

    func localRegistrationId() -> Int {
        registrationId
    }

    // MARK: - Wire Inner-Data Builders (for `ZaloWebSocket.sendRequestFrame`)

    static func buildGetKeyIdInnerData() -> [String: Any] {
        ["platformType": 2]
    }

    static func buildSubmitBundleInnerData(bundlePayload: [String: Any]) -> [String: Any] {
        bundlePayload
    }

    static func buildSubmitPreKeysInnerData(registrationId: Int, opKeys: [[String: Any]]) -> [String: Any] {
        [
            "deviceId": 2,
            "id": registrationId,
            "opKeys": opKeys,
        ]
    }

    /// Official `ACK_TYPE`.
    static let ackTypeFailed = 0
    static let ackTypeSuccess = 1

    /// Official `sendAckSession`: on success the entry carries `data`, the encrypted `{"subDevice":[...]}` the initiator
    /// decrypts to finish the session (until then it keeps sending PreKey messages); on failure `iid`, our registration id.
    static func buildAckInitSessionInnerData(uidTo: String, deviceId: Int, ts: Int64, cipher: String?, registrationId: Int) -> [String: Any] {
        var entry: [String: Any] = ["deviceId": deviceId, "ts": ts]
        if let cipher { entry["data"] = cipher } else { entry["iid"] = registrationId }
        return [
            "type": cipher == nil ? ackTypeFailed : ackTypeSuccess,
            "uidTo": uidTo,
            "data": [entry],
        ]
    }

    static func buildDoneProcessSessionInnerData(info: [[String: Any]]) -> [String: Any] {
        [
            "queueName": "",
            "info": info,
        ]
    }

    // MARK: - Delivery Reports (official `handleAckMessage` / `resendService.processAck`)

    /// A recipient device reports each E2EE message it got: `err` 0 when it decrypted, negative when it could not
    /// (`errC` says why, e.g. -5 changed device, -7 bad MAC). Failed reports are acked with 557 so the server drops them.
    static func deliverReports(_ payload: [String: Any]) -> [[String: Any]] {
        let data = payload["data"] as? [String: Any] ?? payload
        return data["delivereds"] as? [[String: Any]] ?? []
    }

    /// Shape only: device, error codes and retry count, never ids or uids.
    static func deliverReportSummary(_ entry: [String: Any]) -> String {
        func num(_ key: String) -> String { JSONLossless.int64(entry[key]).map(String.init) ?? "-" }
        return "dev=\(num("deviceId")) err=\(num("err")) errC=\(num("errC")) retry=\(num("retry")) fromDI=\(num("fromDI"))"
    }

    struct ResendRequest: Equatable, Sendable {
        var peerUid: String
        var deviceId: Int
        var cliMsgId: String
        var msgId: String
    }

    /// Official `processRequestResend` gates: a failed decrypt (-1), duplicate (-4) or over-2000-keys (-6) report about a
    /// message this device (2) sent, not resent yet (`retry` 0).
    static func resendRequest(from entry: [String: Any]) -> ResendRequest? {
        let err = JSONLossless.int64(entry["err"]) ?? 0
        guard [-1, -4, -6].contains(err), (JSONLossless.int64(entry["retry"]) ?? 0) == 0 else { return nil }
        if let from = JSONLossless.int64(entry["fromDI"]), from != Int64(localDeviceId) { return nil }
        let delivered = (entry["deliveredUids"] as? [Any])?.first.map { JSONLossless.string($0) } ?? ""
        let peer = ZaloWireParser.stripUserPrefix(delivered.isEmpty ? JSONLossless.string(entry["threadId"]) : delivered)
        let cli = JSONLossless.string(entry["cliMsgId"])
        guard let dev = JSONLossless.int64(entry["deviceId"]), !peer.isEmpty, !cli.isEmpty else { return nil }
        return ResendRequest(peerUid: peer, deviceId: Int(dev), cliMsgId: cli, msgId: JSONLossless.string(entry["msgId"]))
    }

    /// Logs and acks the reports; returns the messages to send again (each message and device once per launch).
    @discardableResult
    func handleDeliverReports(cmd: UInt16, payload: ZaloJSONBox, webSocket: ZaloWebSocket) async -> [ResendRequest] {
        let reports = Self.deliverReports(payload.dict)
        guard !reports.isEmpty else {
            logSink("e2ee deliver: cmd=\(cmd) reports=0 keys=\(payload.dict.keys.sorted().joined(separator: ","))")
            return []
        }
        let failed = reports.filter { (JSONLossless.int64($0["err"]) ?? 0) != 0 }
        let keys = Set(reports.flatMap(\.keys)).sorted().joined(separator: ",")
        logSink("e2ee deliver: cmd=\(cmd) reports=\(reports.count) failed=\(failed.count) keys=\(keys) [\(reports.prefix(8).map(Self.deliverReportSummary).joined(separator: "; "))]")
        guard cmd == Self.cmdDeliverSeenOneOne, !failed.isEmpty else { return [] }
        for start in stride(from: 0, to: failed.count, by: 50) {
            let chunk = Array(failed[start..<min(start + 50, failed.count)])
            let resp = await webSocket.sendRequestFrame(
                cmd: Self.cmdDeleteQueueAckOneOne,
                subCmd: 0,
                version: 1,
                innerData: ZaloJSONBox(["delivereds": chunk]),
                timeoutSeconds: 6
            )
            logSink("e2ee deliver: ack 557 count=\(chunk.count) error_code=\(resp.flatMap { JSONLossless.int64($0.dict["error_code"]) }.map(String.init) ?? "-")")
        }
        var requests: [ResendRequest] = []
        for entry in failed {
            guard let req = Self.resendRequest(from: entry) else { continue }
            let key = "\(req.cliMsgId).\(req.peerUid).\(req.deviceId)"
            guard !resentDeliveries.contains(key) else { continue }
            resentDeliveries.insert(key)
            requests.append(req)
        }
        return requests
    }

    /// INIT_SESSION (543) entry, official `initSessionWith`: the PreKey message carrying `{"subDevice":[...]}`.
    static func buildInitSessionInnerData(uidTo: String, deviceId: Int, cipher: String) -> [String: Any] {
        ["type": 1, "uidTo": uidTo, "data": [["deviceId": deviceId, "data": cipher]]]
    }

    /// Official `checkSessionReinit` -> `initSessionWith(uid, [device], {isReinit})`: a fresh session from the device's
    /// current bundle, announced with INIT_SESSION so the device replaces the one it could not decrypt with.
    func reinitSession(peerUid: String, deviceId: Int, myUid: String, webSocket: ZaloWebSocket, store: ZaloSQLiteStore?) async -> Bool {
        let cleanPeer = ZaloWireParser.stripUserPrefix(peerUid)
        let cleanMe = ZaloWireParser.stripUserPrefix(myUid)
        await prepare(uid: cleanMe, store: store)
        guard runtime != nil || rust != nil, registrationId > 0, !cleanPeer.isEmpty, await webSocket.isAuthed else { return false }
        let resp = await webSocket.sendRequestFrame(
            cmd: Self.cmdGetBundle, subCmd: 0, version: 1,
            innerData: ZaloJSONBox(Self.buildGetBundleInnerData(peerUid: cleanPeer, myUid: nil, isReInit: 1)),
            timeoutSeconds: 8
        )
        let entries = resp.map { Self.parseGetBundleResponse($0.dict) } ?? []
        guard let bundle = entries.first(where: { $0.uid == cleanPeer })?.devices
            .first(where: { Int(JSONLossless.int64($0["deviceId"]) ?? -1) == deviceId }) else {
            logSink("e2ee resend: reinit dev=\(deviceId) no bundle")
            return false
        }
        guard await processPreKeyBundle(myUid: cleanMe, remoteUid: cleanPeer, deviceId: deviceId, bundle: bundle) else {
            logSink("e2ee resend: reinit dev=\(deviceId) bundle failed")
            return false
        }
        storeDirty = true
        let subDevices = Set(await listSessions(remoteUid: cleanMe).map(\.deviceId).filter { $0 != Self.localDeviceId }).sorted()
        let body = "{\"subDevice\":[\(subDevices.map(String.init).joined(separator: ","))]}"
        guard let cipher = await encryptOne(remoteUid: cleanPeer, device: deviceId, text: body) else {
            await persistStoreIfNeeded(store: store)
            return false
        }
        await persistStoreIfNeeded(store: store)
        let ack = await webSocket.sendRequestFrame(
            cmd: Self.cmdInitSession, subCmd: 0, version: 1,
            innerData: ZaloJSONBox(Self.buildInitSessionInnerData(uidTo: cleanPeer, deviceId: deviceId, cipher: cipher)),
            timeoutSeconds: 8
        )
        let code = ack.flatMap { JSONLossless.int64($0.dict["error_code"]) }
        logSink("e2ee resend: reinit dev=\(deviceId) cipher=\(E2EEShadow.cipherType(cipher)) init error_code=\(code.map(String.init) ?? "-")")
        return code == 0
    }

    static func buildGetListUserE2EEInnerData(reqIid: Int = 1) -> [String: Any] {
        ["reqIid": reqIid]
    }

    static func buildGetBundleInnerData(
        peerUid: String,
        myUid: String?,
        isReInit: Int = 0,
        msgInfoNoti: Int = 0,
        isAutoUpgrade: Int = 0
    ) -> [String: Any] {
        let cleanPeer = ZaloWireParser.stripUserPrefix(peerUid)
        let cleanMe = myUid.map(ZaloWireParser.stripUserPrefix) ?? ""
        var uids: [[String: Any]] = [["uid": cleanPeer, "deviceId": -1]]
        if !cleanMe.isEmpty && cleanMe != cleanPeer {
            uids.append(["uid": cleanMe, "deviceId": -1])
        }
        return [
            "uids": uids,
            "isReInit": isReInit,
            "msgInfoNoti": msgInfoNoti,
            "isAutoUpgrade": isAutoUpgrade,
        ]
    }

    static func parseE2EEPeerListResponse(
        _ dict: [String: Any],
        myUid: String = ""
    ) -> (threads: Set<String>, devices: [String: [(deviceId: Int, sessionKey: Int64)]], nextReqIid: Int?) {
        let cleanMe = ZaloWireParser.stripUserPrefix(myUid)
        let d1 = dict["data"] as? [String: Any]
        let d2 = d1?["data"] as? [String: Any] ?? d1 ?? dict
        let rawThreads = d2["threads"] ?? d1?["threads"] ?? dict["threads"]

        var parsedThreads = Set<String>()
        var parsedDevices: [String: [(deviceId: Int, sessionKey: Int64)]] = [:]

        if let arr = rawThreads as? [[String: Any]] {
            for row in arr {
                let rawUid = JSONLossless.string(row["uid"] ?? row["userId"] ?? row["id"])
                let uid = ZaloWireParser.stripUserPrefix(rawUid)
                guard !uid.isEmpty, uid != "0", uid != cleanMe, !ZaloWireParser.isGroupId(uid) else { continue }
                parsedThreads.insert(uid)
                if let devs = row["devices"] as? [[String: Any]] {
                    var devList: [(deviceId: Int, sessionKey: Int64)] = []
                    for d in devs {
                        let di = Int(JSONLossless.int64(d["di"] ?? d["deviceId"]) ?? -1)
                        guard di >= 0 else { continue }
                        let iid = JSONLossless.int64(d["iid"] ?? d["sessionKey"] ?? d["keyId"]) ?? 0
                        if let existingIdx = devList.firstIndex(where: { $0.deviceId == di }) {
                            devList[existingIdx] = (deviceId: di, sessionKey: iid)
                        } else {
                            devList.append((deviceId: di, sessionKey: iid))
                        }
                    }
                    if !devList.isEmpty {
                        parsedDevices[uid] = devList
                    }
                }
            }
        } else if let strArr = rawThreads as? [String] {
            for rawUid in strArr {
                let uid = ZaloWireParser.stripUserPrefix(rawUid)
                guard !uid.isEmpty, uid != "0", uid != cleanMe, !ZaloWireParser.isGroupId(uid) else { continue }
                parsedThreads.insert(uid)
            }
        }

        let hasMore = (JSONLossless.int64(d2["hasMore"] ?? d2["more"]) == 1) || (d2["hasMore"] as? Bool == true)
        let nextCursor = hasMore
            ? JSONLossless.int64(d2["nextReqIid"] ?? d2["reqIid"] ?? d2["lastIid"]).map(Int.init)
            : nil
        return (parsedThreads, parsedDevices, nextCursor)
    }

    static func parseGetBundleResponse(_ dict: [String: Any]) -> [(uid: String, devices: [[String: Any]])] {
        let d1 = dict["data"] as? [String: Any]
        let d2 = d1?["data"] as? [String: Any] ?? d1 ?? dict
        guard let keysArr = (d2["keys"] as? [[String: Any]])
            ?? (d1?["keys"] as? [[String: Any]])
            ?? (dict["keys"] as? [[String: Any]]) else {
            return []
        }
        var out: [(uid: String, devices: [[String: Any]])] = []
        for entry in keysArr {
            let uid = ZaloWireParser.stripUserPrefix(JSONLossless.string(entry["uid"] ?? entry["userId"]))
            guard !uid.isEmpty else { continue }
            let devices: [[String: Any]]
            if let devKeys = entry["keys"] as? [[String: Any]] {
                devices = devKeys
            } else if entry["preKey"] != nil {
                devices = [entry]
            } else {
                devices = []
            }
            out.append((uid: uid, devices: devices))
        }
        return out
    }

    private func ensureRuntime() async throws -> JSRuntime {
        if let existing = runtime { return existing }
        let rt = try JSRuntime(name: "zalo-pc-e2ee")
        try await rt.loadModule("vendor/libsignal-protocol.js")
        try await rt.loadModule("zalo-e2ee.js")
        runtime = rt
        return rt
    }

    func loadPersistedThreads(store: ZaloSQLiteStore?) async {
        guard !didLoadThreadsFromStore, let store else { return }
        if let saved = try? await store.getPreferenceStrings(key: Self.e2eeThreadsPrefKey) {
            for raw in saved {
                let clean = ZaloWireParser.stripUserPrefix(raw)
                if !clean.isEmpty, clean != "0", !ZaloWireParser.isGroupId(clean), clean != loadedUid {
                    e2eeThreads.insert(clean)
                }
            }
            didLoadThreadsFromStore = true
        }
    }

    func prepare(uid: String, store: ZaloSQLiteStore?) async {
        guard !uid.isEmpty, !Task.isCancelled else { return }
        await loadPersistedThreads(store: store)
        guard !Task.isCancelled else { return }
        if loadedUid == uid, registrationId > 0, runtime != nil || rust != nil { return }
        if effectiveMode == .authoritative, await prepareRust(uid: uid, store: store) { return }
        guard !Task.isCancelled else { return }
        do {
            let rt = try await ensureRuntime()
            let savedJSON = (try? await store?.getPreferenceString(key: Self.storePrefKey)) ?? ""
            let res = try await rt.callAsync("ZaloE2EE.pc.initOrRestore", [.string(uid), .string(savedJSON)])
            loadedUid = uid
            jsSnapshotCache = res["storeJSON"]?.stringValue
            e2eeThreads.remove(uid)
            registrationId = res["registrationId"]?.intValue ?? 0
            if let bundleVal = res["bundlePayload"],
               let bundleDict = Self.jsValueToNative(bundleVal) as? [String: Any] {
                bundlePayload = bundleDict
            }
            if let exported = res["storeJSON"]?.stringValue, !exported.isEmpty {
                try? await store?.setPreferenceString(key: Self.storePrefKey, value: exported)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            let msg = error.localizedDescription
            Task { @MainActor in
                EngineLog.shared.write("e2ee: init error \(msg)")
            }
        }
    }

    /// Rust-authoritative init: restores (or generates) the Rust store from the same preference key
    /// the JS path uses and persists its export. Returns false (and drops to the JS path for this
    /// launch) when the Rust store cannot load; JS then reads whatever was last persisted.
    private func prepareRust(uid: String, store: ZaloSQLiteStore?) async -> Bool {
        do {
            let saved = (try? await store?.getPreferenceString(key: Self.storePrefKey)) ?? ""
            let sig = try await signalInitOrRestore(savedJson: saved)
            let exported = try await sig.exportStoreJson()
            let bundleJSON = try await sig.bundlePayloadJson()
            rust = sig
            loadedUid = uid
            e2eeThreads.remove(uid)
            registrationId = Int(sig.registrationId())
            if let data = bundleJSON.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                bundlePayload = dict
            }
            if !exported.isEmpty {
                try? await store?.setPreferenceString(key: Self.storePrefKey, value: exported)
            }
            let restored = sig.restored()
            logSink("e2ee: rust authoritative restored=\(restored)")
            return true
        } catch {
            let kind = E2EEShadow.errorKind(error)
            logSink("e2ee: rust init failed kind=\(kind), using JS for this launch")
            effectiveMode = .off
            return false
        }
    }

    private func exportStoreJSON() async -> String? {
        if let rust { return try? await rust.exportStoreJson() }
        guard let rt = runtime, !loadedUid.isEmpty else { return nil }
        return try? await rt.callAsync("ZaloE2EE.pc.exportStore", [.string(loadedUid)]).stringValue
    }

    private func persistStoreIfNeeded(store: ZaloSQLiteStore?) async {
        guard storeDirty, !loadedUid.isEmpty, runtime != nil || rust != nil, let store else { return }
        storeDirty = false
        if let json = await exportStoreJSON(), !json.isEmpty {
            try? await store.setPreferenceString(key: Self.storePrefKey, value: json)
        }
    }

    nonisolated func e2eeThreadIdsSync() -> [String] {
        threadCache.withLock { cache in
            cache.e2eeThreads.filter { $0 != cache.loadedUid }
        }
    }

    nonisolated func isE2EEConversationSync(_ convId: String) -> Bool {
        let clean = ZaloWireParser.stripUserPrefix(convId)
        guard !clean.isEmpty, !ZaloWireParser.isGroupId(clean) else { return false }
        return threadCache.withLock { cache in
            clean != cache.loadedUid && cache.e2eeThreads.contains(clean)
        }
    }

    func isE2EEConversation(_ convId: String) -> Bool {
        let clean = ZaloWireParser.stripUserPrefix(convId)
        guard !clean.isEmpty, !ZaloWireParser.isGroupId(clean), clean != loadedUid else { return false }
        return e2eeThreads.contains(clean)
    }

    func markE2EEConversation(_ convId: String, enabled: Bool, store: ZaloSQLiteStore?) async {
        let clean = ZaloWireParser.stripUserPrefix(convId)
        guard !clean.isEmpty, !ZaloWireParser.isGroupId(clean), clean != "0", clean != loadedUid else { return }
        let changed: Bool
        if enabled {
            changed = e2eeThreads.insert(clean).inserted
        } else {
            changed = (e2eeThreads.remove(clean) != nil)
        }
        if changed, let store {
            try? await store.setPreferenceStrings(key: Self.e2eeThreadsPrefKey, value: Array(e2eeThreads).sorted())
        }
    }

    func fetchE2EEPeerList(webSocket: ZaloWebSocket, store: ZaloSQLiteStore?, myUid: String? = nil) async {
        guard await webSocket.isAuthed else { return }
        let effectiveUid = myUid.map(ZaloWireParser.stripUserPrefix) ?? loadedUid
        await loadPersistedThreads(store: store)

        var reqIid = 1
        var addedThreads = 0
        for _ in 0..<20 {
            guard let resp = await webSocket.sendRequestFrame(
                cmd: Self.cmdGetListUserE2EE,
                subCmd: 0,
                version: 1,
                innerData: ZaloJSONBox(Self.buildGetListUserE2EEInnerData(reqIid: reqIid)),
                timeoutSeconds: 8
            ) else {
                break
            }
            let d1 = resp.dict["data"] as? [String: Any]
            let d2 = d1?["data"] as? [String: Any] ?? d1
            if let errCode = JSONLossless.int64(d2?["err"] ?? d1?["error_code"] ?? resp.dict["error_code"]), errCode != 0 {
                break
            }
            let parsed = Self.parseE2EEPeerListResponse(resp.dict, myUid: effectiveUid)
            for uid in parsed.threads {
                if e2eeThreads.insert(uid).inserted {
                    addedThreads += 1
                }
            }
            for (uid, devs) in parsed.devices {
                peerDeviceMeta[uid] = devs
            }
            guard let next = parsed.nextReqIid, next > reqIid else { break }
            reqIid = next
        }

        if let store, !e2eeThreads.isEmpty {
            try? await store.setPreferenceStrings(key: Self.e2eeThreadsPrefKey, value: Array(e2eeThreads).sorted())
        }
        let total = e2eeThreads.count
        if total > 0 || addedThreads > 0 {
            Task { @MainActor in
                EngineLog.shared.write("e2ee: peer list total=\(total) added=\(addedThreads)")
            }
        }
    }

    func syncBundleWithServerIfNeeded(
        uid: String,
        webSocket: ZaloWebSocket,
        store: ZaloSQLiteStore?
    ) async {
        guard !uid.isEmpty, !didCheckServerBundleForSession else { return }
        await prepare(uid: uid, store: store)
        guard registrationId > 0, !bundlePayload.isEmpty, await webSocket.isAuthed else { return }

        let keyCheck = await webSocket.sendRequestFrame(
            cmd: Self.cmdGetKeyId,
            subCmd: 0,
            version: 1,
            innerData: ZaloJSONBox(Self.buildGetKeyIdInnerData()),
            timeoutSeconds: 8
        )
        let d1 = keyCheck?.dict["data"] as? [String: Any]
        let d2 = d1?["data"] as? [String: Any] ?? d1
        let serverKeyId = Int(JSONLossless.int64(d2?["keyId"]) ?? -1)
        let serverErr = Int(JSONLossless.int64(d2?["err"] ?? d1?["error_code"] ?? keyCheck?.dict["error_code"]) ?? 0)

        if keyCheck != nil && serverKeyId == registrationId && serverErr == 0 {
            didCheckServerBundleForSession = true
            let regId = registrationId
            Task { @MainActor in
                EngineLog.shared.write("e2ee: server bundle matched keyId=\(regId)")
            }
            return
        }

        let submitResp = await webSocket.sendRequestFrame(
            cmd: Self.cmdSubmitBundle,
            subCmd: 0,
            version: 1,
            innerData: ZaloJSONBox(Self.buildSubmitBundleInnerData(bundlePayload: bundlePayload)),
            timeoutSeconds: 10
        )
        let subD1 = submitResp?.dict["data"] as? [String: Any]
        let subD2 = subD1?["data"] as? [String: Any] ?? subD1
        let subCode = JSONLossless.int64(
            subD2?["err"] ?? subD1?["err"] ?? subD1?["error_code"] ?? submitResp?.dict["error_code"]
        ) ?? (submitResp != nil ? 0 : -1)
        if submitResp != nil && subCode == 0 {
            didCheckServerBundleForSession = true
        }
        let regId = registrationId
        Task { @MainActor in
            EngineLog.shared.write("e2ee: submitted PC bundle keyId=\(regId) serverPrev=\(serverKeyId) code=\(subCode)")
        }
    }

    func handleSignalSocketEvent(
        cmd: UInt16,
        payload: ZaloJSONBox,
        uid: String,
        webSocket: ZaloWebSocket,
        store: ZaloSQLiteStore?
    ) async {
        guard !uid.isEmpty else { return }
        await prepare(uid: uid, store: store)

        switch cmd {
        case Self.cmdRequestPreKeys:
            guard let (opKeys, exported) = await refillPreKeys(uid: uid, count: 40), !opKeys.isEmpty else { return }
            do {
                if !exported.isEmpty {
                    try? await store?.setPreferenceString(key: Self.storePrefKey, value: exported)
                }
                _ = await webSocket.sendRequestFrame(
                    cmd: Self.cmdSubmitPreKeys,
                    subCmd: 0,
                    version: 1,
                    innerData: ZaloJSONBox(Self.buildSubmitPreKeysInnerData(registrationId: registrationId, opKeys: opKeys)),
                    timeoutSeconds: 8
                )
            }

        case Self.cmdInitSession, Self.cmdSessionOffline:
            let dataNode = payload.dict["data"] as? [String: Any] ?? payload.dict
            var sessions: [[String: Any]] = []
            if let arr = dataNode["eesession"] as? [[String: Any]] {
                sessions.append(contentsOf: arr)
            } else if dataNode["sessionData"] != nil {
                sessions.append(dataNode)
            }
            var doneAckInfos: [[String: Any]] = []
            for item in sessions {
                let sData: [String: Any] = {
                    if let d = item["sessionData"] as? [String: Any] { return d }
                    if let s = item["sessionData"] as? String,
                       let d = s.data(using: .utf8),
                       let parsed = JSONLossless.parseObject(d) {
                        return parsed
                    }
                    return item
                }()
                let fromUid = ZaloWireParser.stripUserPrefix(JSONLossless.string(sData["uidFrom"]))
                let devId = Int(JSONLossless.int64(sData["deviceId"]) ?? 0)
                let cipher = JSONLossless.string(sData["data"])
                let gid = JSONLossless.string(item["msgId"] ?? sData["msgId"])
                let ts = JSONLossless.int64(sData["reqServerTs"] ?? sData["ts"]) ?? Int64(Date().timeIntervalSince1970 * 1000)

                if !fromUid.isEmpty && ZaloWireParser.isSignalCiphertext(cipher) {
                    var ackCipher: String?
                    if let _ = await decryptString(uid: uid, senderUid: fromUid, preferredDeviceId: devId, cipher: cipher) {
                        storeDirty = true
                        if fromUid != uid {
                            await markE2EEConversation(fromUid, enabled: true, store: store)
                        }
                        let subDevices = await listSessions(remoteUid: uid).map(\.deviceId).filter { $0 != Self.localDeviceId }
                        let body = "{\"subDevice\":[\(Set(subDevices).sorted().map(String.init).joined(separator: ","))]}"
                        ackCipher = await encryptOne(remoteUid: fromUid, device: devId, text: body)
                    }
                    if fromUid != uid {
                        logSink("e2ee: init session dev=\(devId) cipher=\(E2EEShadow.cipherType(cipher)) ack=\(ackCipher == nil ? "failed" : "success")")
                        _ = await webSocket.sendRequestFrame(
                            cmd: Self.cmdAckInitSession,
                            subCmd: 0,
                            version: 1,
                            innerData: ZaloJSONBox(Self.buildAckInitSessionInnerData(
                                uidTo: fromUid, deviceId: devId, ts: ts, cipher: ackCipher, registrationId: registrationId)),
                            timeoutSeconds: 6
                        )
                    }
                }
                if !gid.isEmpty && !fromUid.isEmpty {
                    doneAckInfos.append([
                        "gid": gid,
                        "cmd": Int(Self.cmdInitSession),
                        "subCmd": 0,
                        "sid": fromUid,
                        "deviceId": devId,
                    ])
                }
            }
            if !doneAckInfos.isEmpty {
                _ = await webSocket.sendRequestFrame(
                    cmd: Self.cmdDoneProcessSession,
                    subCmd: 0,
                    version: 1,
                    innerData: ZaloJSONBox(Self.buildDoneProcessSessionInnerData(info: doneAckInfos)),
                    timeoutSeconds: 6
                )
            }
            await persistStoreIfNeeded(store: store)

        default:
            break
        }
    }

    /// `refillPreKeys` on whichever backend is live: the `opKeys` for upload plus the store JSON to persist.
    private func refillPreKeys(uid: String, count: Int) async -> ([[String: Any]], String)? {
        if let rust {
            guard let keys = try? await rust.refillPreKeys(count: UInt32(count)),
                  let exported = try? await rust.exportStoreJson() else { return nil }
            return (keys.map { ["id": Int($0.id), "key": $0.key] }, exported)
        }
        guard let rt = runtime,
              let res = try? await rt.callAsync("ZaloE2EE.pc.refillPreKeys", [.string(uid), .number(Double(count))]),
              let opKeys = Self.jsValueToNative(res["opKeys"] ?? .null) as? [[String: Any]] else { return nil }
        jsSnapshotCache = nil
        return (opKeys, res["storeJSON"]?.stringValue ?? "")
    }

    // MARK: - Outgoing Sessions & Encryption

    private func listSessions(remoteUid: String) async -> [(deviceId: Int, registrationId: Int)] {
        if let rust, !loadedUid.isEmpty, !remoteUid.isEmpty {
            let rows = (try? await rust.listSessions(remoteUid: remoteUid)) ?? []
            return rows.map { (deviceId: Int($0.deviceId), registrationId: Int($0.registrationId)) }
        }
        guard let rt = runtime, !loadedUid.isEmpty, !remoteUid.isEmpty else { return [] }
        guard let res = try? await rt.callAsync("ZaloE2EE.pc.listSessions", [.string(loadedUid), .string(remoteUid)]),
              let arr = res.arrayValue else {
            return []
        }
        var out: [(deviceId: Int, registrationId: Int)] = []
        for item in arr {
            if let devId = item["deviceId"]?.intValue {
                let regId = item["registrationId"]?.intValue ?? 0
                out.append((deviceId: devId, registrationId: regId))
            }
        }
        return out
    }

    private func processPreKeyBundle(myUid: String, remoteUid: String, deviceId: Int, bundle: [String: Any]) async -> Bool {
        if let rust {
            guard JSONSerialization.isValidJSONObject(bundle),
                  let data = try? JSONSerialization.data(withJSONObject: bundle),
                  let text = String(data: data, encoding: .utf8) else { return false }
            return (try? await rust.processPrekeyBundle(remoteUid: remoteUid, device: UInt32(deviceId), bundleJson: text)) != nil
        }
        guard let rt = runtime else { return false }
        jsSnapshotCache = nil
        let res = try? await rt.callAsync("ZaloE2EE.pc.processPreKeyBundle", [
            .string(myUid),
            .string(remoteUid),
            .number(Double(deviceId)),
            Self.nativeToJSValue(bundle),
        ])
        return res?["ok"]?.boolValue == true
    }

    func ensureSessions(
        forPeer peerUid: String,
        myUid: String,
        webSocket: ZaloWebSocket,
        store: ZaloSQLiteStore?
    ) async -> Bool {
        let cleanPeer = ZaloWireParser.stripUserPrefix(peerUid)
        let cleanMe = ZaloWireParser.stripUserPrefix(myUid)
        guard !cleanPeer.isEmpty, !cleanMe.isEmpty else { return false }

        await prepare(uid: cleanMe, store: store)
        guard runtime != nil || rust != nil, registrationId > 0 else { return false }

        var peerSessions = await listSessions(remoteUid: cleanPeer)
        let mySessions = (cleanPeer == cleanMe) ? [] : await listSessions(remoteUid: cleanMe)

        var needsFetch = peerSessions.isEmpty
        if !needsFetch, let knownDevs = peerDeviceMeta[cleanPeer], !knownDevs.isEmpty {
            for meta in knownDevs {
                guard let open = peerSessions.first(where: { $0.deviceId == meta.deviceId }) else {
                    needsFetch = true
                    break
                }
                if meta.sessionKey > 0 && open.registrationId > 0 && Int64(open.registrationId) != meta.sessionKey {
                    needsFetch = true
                    break
                }
            }
        }
        // Once per launch per peer, check the server's device list and keys: a device that reinstalled or signed in
        // again has a new registration id, and a message on the old session never opens there (official client:
        // devices from the server, stale ones re-initialised). Unchanged devices keep their session.
        if !needsFetch && !fetchedBundlePeers.contains(cleanPeer) && cleanPeer != cleanMe {
            needsFetch = true
        }
        let before = peerSessions.map { "\($0.deviceId)" }.joined(separator: ",")
        guard needsFetch else {
            logSink("e2ee send: sessions devices=[\(before)] own=\(mySessions.count) fetch=no")
            return !peerSessions.isEmpty
        }
        guard await webSocket.isAuthed else { return !peerSessions.isEmpty }
        var rebuilt: [String] = []

        let resp = await webSocket.sendRequestFrame(
            cmd: Self.cmdGetBundle,
            subCmd: 0,
            version: 1,
            innerData: ZaloJSONBox(Self.buildGetBundleInnerData(peerUid: cleanPeer, myUid: cleanMe)),
            timeoutSeconds: 8
        )
        var bundleEntries = resp.map { Self.parseGetBundleResponse($0.dict) } ?? []
        if !bundleEntries.contains(where: { $0.uid == cleanPeer && !$0.devices.isEmpty }) {
            let retryResp = await webSocket.sendRequestFrame(
                cmd: Self.cmdGetBundle,
                subCmd: 0,
                version: 1,
                innerData: ZaloJSONBox(Self.buildGetBundleInnerData(peerUid: cleanPeer, myUid: nil)),
                timeoutSeconds: 8
            )
            if let retryEntries = retryResp.map({ Self.parseGetBundleResponse($0.dict) }), !retryEntries.isEmpty {
                bundleEntries = retryEntries
            }
        }

        for entry in bundleEntries {
            let existingSessions = (entry.uid == cleanPeer) ? peerSessions : await listSessions(remoteUid: entry.uid)
            for bundleObj in entry.devices {
                let devId = Int(JSONLossless.int64(bundleObj["deviceId"]) ?? -1)
                guard devId >= 0 else { continue }
                if entry.uid == cleanMe && devId == 2 { continue }

                let preKeyDict = bundleObj["preKey"] as? [String: Any]
                let iKeyDict = preKeyDict?["iKey"] as? [String: Any]
                let bundleRegId = Int(JSONLossless.int64(iKeyDict?["id"]) ?? 0)
                if bundleRegId > 0,
                   existingSessions.contains(where: { $0.deviceId == devId && $0.registrationId == bundleRegId }) {
                    rebuilt.append("\(entry.uid == cleanPeer ? "peer" : "own"):\(devId):same")
                    continue
                }

                let hadSession = existingSessions.contains { $0.deviceId == devId }
                let processed = await processPreKeyBundle(myUid: cleanMe, remoteUid: entry.uid, deviceId: devId, bundle: bundleObj)
                rebuilt.append("\(entry.uid == cleanPeer ? "peer" : "own"):\(devId):\(hadSession ? "replaced" : "new"):\(processed ? "ok" : "fail")")
                if processed {
                    storeDirty = true
                    if entry.uid == cleanPeer && bundleRegId > 0 {
                        var list = peerDeviceMeta[cleanPeer] ?? []
                        if let idx = list.firstIndex(where: { $0.deviceId == devId }) {
                            list[idx] = (deviceId: devId, sessionKey: Int64(bundleRegId))
                        } else {
                            list.append((deviceId: devId, sessionKey: Int64(bundleRegId)))
                        }
                        peerDeviceMeta[cleanPeer] = list
                    }
                }
            }
        }

        await persistStoreIfNeeded(store: store)
        peerSessions = await listSessions(remoteUid: cleanPeer)
        logSink("e2ee send: sessions before=[\(before)] own=\(mySessions.count) fetch=yes bundles=\(bundleEntries.map { $0.devices.count }) "
                + "processed=[\(rebuilt.joined(separator: ","))] after=[\(peerSessions.map { "\($0.deviceId)" }.joined(separator: ","))]")
        if !peerSessions.isEmpty {
            fetchedBundlePeers.insert(cleanPeer)
        }
        return !peerSessions.isEmpty
    }

    func encryptTextMessage(
        peerUid: String,
        myUid: String,
        text: String,
        quoteText: String? = nil,
        quoteExtras: [String] = [],
        onlyDevice: Int? = nil,
        store: ZaloSQLiteStore?
    ) async -> [(toId: String, platform: Int, registrationId: Int, ciphers: [String])] {
        var values: [JSBridgeValue] = [.string(text)]
        var formats: [String] = ["string"]
        if let quoteText {
            // Official `sendMsgQuote`: text, quote text, then the attach JSON, text styles, owner name, owner global id.
            for value in [quoteText] + quoteExtras {
                values.append(.string(value))
                formats.append("string")
            }
        }
        return await encryptBatch(peerUid: peerUid, myUid: myUid, values: values, formats: formats, onlyDevice: onlyDevice, store: store)
    }

    func encryptStickerMessage(
        peerUid: String,
        myUid: String,
        stickerId: Int,
        cateId: Int,
        stickerType: Int = 7,
        store: ZaloSQLiteStore?
    ) async -> [(toId: String, platform: Int, registrationId: Int, ciphers: [String])] {
        await encryptBatch(
            peerUid: peerUid,
            myUid: myUid,
            values: [.number(Double(stickerId)), .number(Double(cateId)), .number(Double(stickerType))],
            formats: ["uint32", "uint32", "uint32"],
            store: store
        )
    }

    func encryptFileMessage(
        peerUid: String,
        myUid: String,
        e2eSessionB64: String,
        fileMsgParamsJSON: String,
        fileName: String,
        store: ZaloSQLiteStore?
    ) async -> [(toId: String, platform: Int, registrationId: Int, ciphers: [String])] {
        await encryptBatch(
            peerUid: peerUid,
            myUid: myUid,
            values: [
                .string(e2eSessionB64),
                .string(""),
                .string(fileMsgParamsJSON),
                .string(fileName),
                .string(""),
            ],
            formats: ["string", "string", "string", "string", "string"],
            store: store
        )
    }

    private func encryptBatch(
        peerUid: String,
        myUid: String,
        values: [JSBridgeValue],
        formats: [String],
        onlyDevice: Int? = nil,
        store: ZaloSQLiteStore?
    ) async -> [(toId: String, platform: Int, registrationId: Int, ciphers: [String])] {
        let cleanPeer = ZaloWireParser.stripUserPrefix(peerUid)
        let cleanMe = ZaloWireParser.stripUserPrefix(myUid)
        guard !cleanPeer.isEmpty, !cleanMe.isEmpty, !values.isEmpty else { return [] }
        await prepare(uid: cleanMe, store: store)
        guard runtime != nil || rust != nil, registrationId > 0 else { return [] }

        let peerSessions = await listSessions(remoteUid: cleanPeer)
        guard !peerSessions.isEmpty else { return [] }

        var targets: [JSBridgeValue] = peerSessions.map { sess in
            .object(["userId": .string(cleanPeer), "deviceId": .number(Double(sess.deviceId))])
        }
        if let onlyDevice {
            // Resend (official `encryptForAddresses`): just the device that reported the failure.
            targets = peerSessions.filter { $0.deviceId == onlyDevice }.map { sess in
                .object(["userId": .string(cleanPeer), "deviceId": .number(Double(sess.deviceId))])
            }
            guard !targets.isEmpty else { return [] }
        } else if cleanMe != cleanPeer {
            let mySessions = await listSessions(remoteUid: cleanMe).filter { $0.deviceId != 2 }
            for sess in mySessions {
                targets.append(.object(["userId": .string(cleanMe), "deviceId": .number(Double(sess.deviceId))]))
            }
        }

        var output: [(toId: String, platform: Int, registrationId: Int, ciphers: [String])] = []
        let exported: String
        if let rust {
            // Same loop as `ZaloE2EE.pc.encryptBatch`: a target that fails any value is dropped.
            for t in targets {
                guard let uid = t["userId"]?.stringValue, let devId = t["deviceId"]?.intValue else { continue }
                var ciphers: [String] = []
                var regId = 0
                do {
                    for (i, value) in values.enumerated() {
                        let fmt = i < formats.count ? formats[i] : "string"
                        let enc = try await rust.encryptCipher(
                            remoteUid: uid, device: UInt32(devId), plaintext: Self.plainBytes(value, format: fmt))
                        ciphers.append(enc.cipher)
                        regId = enc.registrationId == 0 ? regId : Int(enc.registrationId)
                    }
                } catch { continue }
                output.append((toId: uid, platform: devId, registrationId: regId, ciphers: ciphers))
            }
            exported = (try? await rust.exportStoreJson()) ?? ""
        } else {
            guard let rt = runtime else { return [] }
            jsSnapshotCache = nil
            let fmtArgs = formats.map { JSBridgeValue.string($0) }
            guard let res = try? await rt.callAsync("ZaloE2EE.pc.encryptBatch", [
                .string(cleanMe),
                .array(targets),
                .array(values),
                .array(fmtArgs),
            ]),
            res["ok"]?.boolValue == true,
            let rows = res["results"]?.arrayValue else {
                return []
            }
            exported = res["storeJSON"]?.stringValue ?? ""
            for row in rows {
                guard let uid = row["userId"]?.stringValue,
                      let devId = row["deviceId"]?.intValue,
                      let regId = row["registrationId"]?.intValue,
                      let cipherVals = row["ciphers"]?.arrayValue else {
                    continue
                }
                output.append((toId: uid, platform: devId, registrationId: regId, ciphers: cipherVals.compactMap(\.stringValue)))
            }
        }

        if !exported.isEmpty {
            storeDirty = false
            try? await store?.setPreferenceString(key: Self.storePrefKey, value: exported)
        } else {
            storeDirty = true
            await persistStoreIfNeeded(store: store)
        }

        output = output.filter { $0.ciphers.count == values.count }
        logSink("e2ee send: encrypt values=\(values.count) targets=\(targets.count) out=["
                + output.map { "\($0.toId == cleanPeer ? "peer" : "own"):\($0.platform):"
                    + $0.ciphers.map(E2EEShadow.cipherType).joined(separator: "+") }.joined(separator: ",") + "]")
        guard output.contains(where: { $0.toId == cleanPeer }) else {
            return []
        }
        return output
    }

    /// This client's Signal device id (official `DeviceIds.PC`).
    static let localDeviceId = 2

    /// One UTF-8 value encrypted for one device on whichever backend is live; nil on failure.
    private func encryptOne(remoteUid: String, device: Int, text: String) async -> String? {
        if let rust {
            guard let enc = try? await rust.encryptCipher(remoteUid: remoteUid, device: UInt32(device), plaintext: Data(text.utf8))
            else { return nil }
            storeDirty = true
            return enc.cipher
        }
        guard let rt = runtime else { return nil }
        jsSnapshotCache = nil
        guard let res = try? await rt.callAsync("ZaloE2EE.pc.encryptCipher", [
            .string(loadedUid), .string(remoteUid), .number(Double(device)), .string(text), .string("string"),
        ]), res["ok"]?.boolValue == true, let cipher = res["cipher"]?.stringValue else { return nil }
        storeDirty = true
        return cipher
    }

    /// Plaintext bytes of one batch value as `encryptCipher` frames it: UTF-8 text, or a 4-byte LE uint32.
    private static func plainBytes(_ value: JSBridgeValue, format: String) -> Data {
        if format == "uint32" {
            let n = UInt32(truncatingIfNeeded: Int64(value.numberValue ?? 0))
            return Data([UInt8(n & 0xff), UInt8((n >> 8) & 0xff), UInt8((n >> 16) & 0xff), UInt8((n >> 24) & 0xff)])
        }
        if let s = value.stringValue { return Data(s.utf8) }
        if let n = value.numberValue { return Data(String(Int64(n)).utf8) }
        return Data()
    }

    // MARK: - Envelope Decryption

    func decryptEnvelopeIfNeeded(
        _ rootBox: ZaloJSONBox,
        myUid: String,
        store: ZaloSQLiteStore?
    ) async -> ZaloJSONBox {
        guard !myUid.isEmpty, Self.envelopeContainsSignalCipher(rootBox.dict) else {
            return rootBox
        }
        await prepare(uid: myUid, store: store)
        let transformed = await transformNode(rootBox.dict, myUid: myUid)
        await persistStoreIfNeeded(store: store)
        if let dict = transformed as? [String: Any] {
            return ZaloJSONBox(dict)
        }
        return rootBox
    }

    private func transformNode(_ node: Any, myUid: String) async -> Any {
        if let dict = node as? [String: Any] {
            if Self.looksLikeWireMessage(dict) {
                return await decryptSingleWireMessage(dict, myUid: myUid)
            }
            var out = dict
            for (k, v) in dict {
                if k == "msgs" || k == "groupMsgs" || k == "pageMsgs" || k == "data" || k == "items" {
                    out[k] = await transformNode(v, myUid: myUid)
                } else if let str = v as? String,
                          (k == "data" || k == "msgs"),
                          str.first == "{" || str.first == "[",
                          let raw = str.data(using: .utf8),
                          let parsed = JSONLossless.parseAny(raw) {
                    let dec = await transformNode(parsed, myUid: myUid)
                    if let reserialized = try? JSONSerialization.data(withJSONObject: dec),
                       let reStr = String(data: reserialized, encoding: .utf8) {
                        out[k] = reStr
                    }
                }
            }
            return out
        }
        if let arr = node as? [Any] {
            var out: [Any] = []
            out.reserveCapacity(arr.count)
            for item in arr {
                out.append(await transformNode(item, myUid: myUid))
            }
            return out
        }
        return node
    }

    private func decryptSingleWireMessage(_ raw: [String: Any], myUid: String) async -> [String: Any] {
        let rawUidFrom = ZaloWireParser.stripUserPrefix(JSONLossless.string(raw["uidFrom"] ?? raw["fromUid"]))
        let senderUid = (rawUidFrom.isEmpty || rawUidFrom == "0") ? myUid : rawUidFrom
        let paramsExt = raw["paramsExt"] as? [String: Any]
        let preferredDev: Int? = paramsExt.flatMap { JSONLossless.int64($0["platformType"]).map(Int.init) }

        let msgType = ZaloWireParser.normalizedMsgType(JSONLossless.string(raw["msgType"]))
        var updated = raw

        // Decrypt quote fields if E2EE-encrypted: the text, the owner's name (`fromD`) and the owner, sent as an
        // encrypted global id (official `sendMsgQuote`) that maps back to a uid.
        if var quote = (raw["quote"] as? [String: Any]) {
            var changed = false
            for key in ["msg", "fromD", "attach"] {
                let value = JSONLossless.string(quote[key])
                if ZaloWireParser.isSignalCiphertext(value),
                   let plain = await decryptString(uid: myUid, senderUid: senderUid, preferredDeviceId: preferredDev, cipher: value) {
                    quote[key] = plain
                    changed = true
                }
            }
            // Official `decryptMsgFromServer`: the owner arrives as `gOwnerId`, an encrypted global id; once mapped it
            // becomes `ownerId` and the name shown is the local one for that uid, not the sender's `fromD`.
            let owner = JSONLossless.string(quote["gOwnerId"])
            if ZaloWireParser.isSignalCiphertext(owner),
               let gid = await decryptString(uid: myUid, senderUid: senderUid, preferredDeviceId: preferredDev, cipher: owner) {
                let found = gid.isEmpty ? nil : await globalIdResolver?(gid, [myUid, senderUid])
                // Unresolved: drop the cipher so the name in `fromD` is shown.
                quote["ownerId"] = found?.uid ?? ""
                quote["gOwnerId"] = nil
                changed = true
                logSink("e2ee: quote owner via=\(found?.via ?? "none") keys=\(quote.keys.sorted().joined(separator: ","))")
            }
            if changed {
                updated["quote"] = quote
                updated["isE2EE"] = true
            }
        }

        if let strContent = raw["content"] as? String {
            let decoded = strContent.removingPercentEncoding ?? strContent
            if ZaloWireParser.isSignalCiphertext(strContent) || ZaloWireParser.isSignalCiphertext(decoded) {
                let target = ZaloWireParser.isSignalCiphertext(strContent) ? strContent : decoded
                if let plain = await decryptString(uid: myUid, senderUid: senderUid, preferredDeviceId: preferredDev, cipher: target) {
                    updated["content"] = plain
                    updated["isE2EE"] = true
                }
            }
            return updated
        }

        guard var cDict = raw["content"] as? [String: Any] else {
            return updated
        }

        switch msgType {
        case "chat.sticker":
            let idCipher = JSONLossless.string(cDict["id"])
            if ZaloWireParser.isSignalCiphertext(idCipher),
               let stickerId = await decryptUInt32(uid: myUid, senderUid: senderUid, preferredDeviceId: preferredDev, cipher: idCipher) {
                cDict["id"] = Int(stickerId)
                cDict["stickerId"] = Int(stickerId)
                let catCipher = JSONLossless.string(cDict["catId"])
                if ZaloWireParser.isSignalCiphertext(catCipher),
                   let catId = await decryptUInt32(uid: myUid, senderUid: senderUid, preferredDeviceId: preferredDev, cipher: catCipher) {
                    cDict["catId"] = Int(catId)
                    cDict["cateId"] = Int(catId)
                }
                let typeCipher = JSONLossless.string(cDict["type"])
                if ZaloWireParser.isSignalCiphertext(typeCipher),
                   let stType = await decryptUInt32(uid: myUid, senderUid: senderUid, preferredDeviceId: preferredDev, cipher: typeCipher) {
                    cDict["type"] = Int(stType)
                }
                updated["content"] = cDict
                updated["isE2EE"] = true
            }

        default:
            var changed = false
            for urlKey in ["href", "thumb", "normalUrl", "hdUrl", "oriUrl", "fileUrl"] {
                let rawVal = JSONLossless.string(cDict[urlKey])
                guard !rawVal.isEmpty else { continue }
                if let replaced = await decryptURLOrCipherField(
                    rawVal,
                    uid: myUid,
                    senderUid: senderUid,
                    preferredDeviceId: preferredDev
                ) {
                    cDict[urlKey] = replaced
                    changed = true
                }
            }
            for textKey in ["params", "title", "description", "type"] {
                let rawVal = JSONLossless.string(cDict[textKey])
                guard !rawVal.isEmpty else { continue }
                let unescaped = rawVal.removingPercentEncoding ?? rawVal
                let candidate = ZaloWireParser.isSignalCiphertext(rawVal) ? rawVal : (ZaloWireParser.isSignalCiphertext(unescaped) ? unescaped : "")
                guard !candidate.isEmpty else { continue }
                if let plain = await decryptString(uid: myUid, senderUid: senderUid, preferredDeviceId: preferredDev, cipher: candidate) {
                    cDict[textKey] = (plain == "null") ? "" : plain
                    changed = true
                }
            }
            if changed {
                updated["content"] = cDict
                updated["isE2EE"] = true
            }
        }
        return updated
    }

    private func decryptURLOrCipherField(
        _ rawVal: String,
        uid: String,
        senderUid: String,
        preferredDeviceId: Int?
    ) async -> String? {
        let unescaped = rawVal.removingPercentEncoding ?? rawVal
        if ZaloWireParser.isSignalCiphertext(rawVal) {
            return await decryptString(uid: uid, senderUid: senderUid, preferredDeviceId: preferredDeviceId, cipher: rawVal)
        }
        if ZaloWireParser.isSignalCiphertext(unescaped) {
            return await decryptString(uid: uid, senderUid: senderUid, preferredDeviceId: preferredDeviceId, cipher: unescaped)
        }
        guard var comps = URLComponents(string: rawVal),
              let items = comps.queryItems,
              let idx = items.firstIndex(where: { $0.name == "e2esession" }),
              let sessionCipher = items[idx].value,
              ZaloWireParser.isSignalCiphertext(sessionCipher) else {
            return nil
        }
        guard let plainSession = await decryptString(
            uid: uid,
            senderUid: senderUid,
            preferredDeviceId: preferredDeviceId,
            cipher: sessionCipher
        ) else {
            return nil
        }
        var nextItems = items
        nextItems[idx].value = plainSession
        comps.queryItems = nextItems
        return comps.url?.absoluteString
    }

    private func candidateDevices(preferred: Int?) -> [Int] {
        var list: [Int] = []
        if let p = preferred, (0...3).contains(p) { list.append(p) }
        for d in [0, 2, 1] where !list.contains(d) {
            list.append(d)
        }
        return list
    }

    private func decryptString(uid: String, senderUid: String, preferredDeviceId: Int?, cipher: String) async -> String? {
        guard runtime != nil || rust != nil else { return nil }
        for dev in candidateDevices(preferred: preferredDeviceId) {
            if case .text(let text)? = await decryptOnce(uid: uid, senderUid: senderUid, device: dev, cipher: cipher, format: "string") {
                return text
            }
        }
        return nil
    }

    private enum Plain {
        case text(String)
        case number(UInt32)
    }

    /// One decrypt attempt against one candidate device, on the authoritative backend. In shadow mode a
    /// Rust decrypt of a copy of the pre-decrypt JS store runs off this actor and is only compared.
    private func decryptOnce(uid: String, senderUid: String, device dev: Int, cipher: String, format: String) async -> Plain? {
        if let rust {
            guard let bytes = try? await rust.decryptCipher(senderUid: senderUid, device: UInt32(dev), cipherB64: cipher) else {
                return nil
            }
            storeDirty = true
            if format == "uint32" {
                guard bytes.count >= 4 else { return nil }
                return .number(bytes.prefix(4).enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8 * UInt32($1.offset))) })
            }
            return .text(String(decoding: bytes, as: UTF8.self))
        }
        guard let rt = runtime else { return nil }
        let shadow = await beginShadow(runtime: rt, senderUid: senderUid, device: dev, cipher: cipher)
        let res = try? await rt.callAsync("ZaloE2EE.pc.decryptCipher", [
            .string(uid),
            .string(senderUid),
            .number(Double(dev)),
            .string(cipher),
            .string(format),
        ])
        var plain: Plain?
        if res?["ok"]?.boolValue == true {
            if format == "uint32" {
                if let num = res?["number"]?.numberValue, num >= 0 { plain = .number(UInt32(num)) }
            } else if let text = res?["text"]?.stringValue {
                plain = .text(text)
            }
        }
        if plain != nil {
            storeDirty = true
            jsSnapshotCache = nil
        }
        if let shadow {
            let js: E2EEShadowJS
            switch plain {
            case .text(let t)?: js = E2EEShadow.jsPlain(text: t)
            case .number(let n)?: js = E2EEShadow.jsPlain(number: n)
            case nil: js = .failed
            }
            finishShadow(shadow, js: js, format: format, type: E2EEShadow.cipherType(cipher))
        }
        return plain
    }

    // MARK: Shadow (ADR-015)

    private func jsSnapshot(runtime rt: JSRuntime) async -> String? {
        if let cached = jsSnapshotCache { return cached }
        guard let json = try? await rt.callAsync("ZaloE2EE.pc.exportStore", [.string(loadedUid)]).stringValue,
              !json.isEmpty else { return nil }
        jsSnapshotCache = json
        return json
    }

    /// Starts the Rust decrypt of the same cipher against the store JS has right now (before its own
    /// decrypt). Runs detached on the blocking pool; never throws into the caller.
    private func beginShadow(runtime rt: JSRuntime, senderUid: String, device: Int, cipher: String)
        async -> Task<Result<Data, Error>, Never>? {
        guard effectiveMode == .shadow, device >= 0 else { return nil }
        let stats = shadowStats
        guard stats.tryBegin() else { return nil }
        guard let snapshot = await jsSnapshot(runtime: rt) else {
            stats.abandon()
            return nil
        }
        return Task.detached(priority: .utility) {
            do {
                return .success(Data(try await signalShadowDecrypt(
                    storeJson: snapshot, senderUid: senderUid, device: UInt32(device), cipherB64: cipher)))
            } catch {
                return .failure(error)
            }
        }
    }

    private func finishShadow(_ task: Task<Result<Data, Error>, Never>, js: E2EEShadowJS, format: String, type: String) {
        let stats = shadowStats
        let sink = logSink
        Task.detached(priority: .utility) {
            let verdict = E2EEShadow.classify(js: js, rust: await task.value, format: format)
            if let line = E2EEShadow.logLine(verdict, type: type) { sink(line) }
            stats.finish(verdict)
        }
    }

    private func decryptUInt32(uid: String, senderUid: String, preferredDeviceId: Int?, cipher: String) async -> UInt32? {
        guard runtime != nil || rust != nil else { return nil }
        for dev in candidateDevices(preferred: preferredDeviceId) {
            if case .number(let n)? = await decryptOnce(uid: uid, senderUid: senderUid, device: dev, cipher: cipher, format: "uint32") {
                return n
            }
        }
        return nil
    }

    // MARK: - Fast Pre-Check Helpers

    private static func looksLikeWireMessage(_ dict: [String: Any]) -> Bool {
        dict["content"] != nil && (dict["msgId"] != nil || dict["cliMsgId"] != nil || dict["msgType"] != nil)
    }

    private static let signalCipherPrefixes = [
        "AzM", "AjM",
        "ATMI", "ATMK", "ATMQ", "ATMS", "ATMY", "ATMi", "ATMo", "ATMw",
    ]

    static func envelopeContainsSignalCipher(_ node: Any) -> Bool {
        if let str = node as? String {
            for prefix in signalCipherPrefixes where str.hasPrefix(prefix) || str.contains(prefix) {
                return true
            }
            return false
        }
        if let dict = node as? [String: Any] {
            for (_, v) in dict where envelopeContainsSignalCipher(v) {
                return true
            }
            return false
        }
        if let arr = node as? [Any] {
            for item in arr where envelopeContainsSignalCipher(item) {
                return true
            }
            return false
        }
        return false
    }

    static func nativeToJSValue(_ any: Any) -> JSBridgeValue {
        switch any {
        case is NSNull:
            return .null
        case let s as String:
            return .string(s)
        case let d as Data:
            return .bytes(d)
        case let num as NSNumber:
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return .bool(num.boolValue)
            }
            return .number(num.doubleValue)
        case let arr as [Any]:
            return .array(arr.map(nativeToJSValue))
        case let dict as [String: Any]:
            var out: [String: JSBridgeValue] = [:]
            for (k, v) in dict {
                out[k] = nativeToJSValue(v)
            }
            return .object(out)
        default:
            return .string(String(describing: any))
        }
    }

    private static func jsValueToNative(_ val: JSBridgeValue) -> Any {
        switch val {
        case .null:
            return NSNull()
        case .bool(let b):
            return b
        case .number(let n):
            if n.isFinite && n == n.rounded() && n >= Double(Int64.min / 2) && n <= Double(Int64.max / 2) {
                return Int64(n)
            }
            return n
        case .string(let s):
            return s
        case .bytes(let d):
            return d.base64EncodedString()
        case .array(let arr):
            return arr.map(jsValueToNative)
        case .object(let dict):
            var out: [String: Any] = [:]
            for (k, v) in dict {
                let converted = jsValueToNative(v)
                if !(converted is NSNull) {
                    out[k] = converted
                }
            }
            return out
        }
    }
}
