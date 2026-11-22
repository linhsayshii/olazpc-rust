import Foundation

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
    static let cmdGetListUserE2EE: UInt16 = 563
    static let cmdGetKeyId: UInt16 = 564

    private var runtime: JSRuntime?
    private var loadedUid: String = ""
    private var registrationId: Int = 0
    private var bundlePayload: [String: Any] = [:]
    private var didCheckServerBundleForSession = false
    private var storeDirty = false
    private var e2eeThreads: Set<String> = []
    private var peerDeviceMeta: [String: [(deviceId: Int, sessionKey: Int64)]] = [:]
    private var fetchedBundlePeers: Set<String> = []
    private var didLoadThreadsFromStore = false

    func reset() {
        loadedUid = ""
        registrationId = 0
        bundlePayload = [:]
        didCheckServerBundleForSession = false
        storeDirty = false
        e2eeThreads.removeAll()
        peerDeviceMeta.removeAll()
        fetchedBundlePeers.removeAll()
        didLoadThreadsFromStore = false
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

    static func buildAckInitSessionInnerData(uidTo: String, deviceId: Int, ts: Int64) -> [String: Any] {
        [
            "type": 0,
            "uidTo": uidTo,
            "data": [["deviceId": deviceId, "ts": ts]],
        ]
    }

    static func buildDoneProcessSessionInnerData(info: [[String: Any]]) -> [String: Any] {
        [
            "queueName": "",
            "info": info,
        ]
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
        guard !uid.isEmpty else { return }
        await loadPersistedThreads(store: store)
        if loadedUid == uid, registrationId > 0, runtime != nil { return }
        do {
            let rt = try await ensureRuntime()
            let savedJSON = (try? await store?.getPreferenceString(key: Self.storePrefKey)) ?? ""
            let res = try await rt.callAsync("ZaloE2EE.pc.initOrRestore", [.string(uid), .string(savedJSON)])
            loadedUid = uid
            e2eeThreads.remove(uid)
            registrationId = res["registrationId"]?.intValue ?? 0
            if let bundleVal = res["bundlePayload"],
               let bundleDict = Self.jsValueToNative(bundleVal) as? [String: Any] {
                bundlePayload = bundleDict
            }
            if let exported = res["storeJSON"]?.stringValue, !exported.isEmpty {
                try? await store?.setPreferenceString(key: Self.storePrefKey, value: exported)
            }
        } catch {
            let msg = error.localizedDescription
            Task { @MainActor in
                EngineLog.shared.write("e2ee: init error \(msg)")
            }
        }
    }

    private func persistStoreIfNeeded(store: ZaloSQLiteStore?) async {
        guard storeDirty, !loadedUid.isEmpty, let rt = runtime, let store else { return }
        storeDirty = false
        if let val = try? await rt.callAsync("ZaloE2EE.pc.exportStore", [.string(loadedUid)]),
           let json = val.stringValue, !json.isEmpty {
            try? await store.setPreferenceString(key: Self.storePrefKey, value: json)
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
            guard let rt = runtime else { return }
            if let res = try? await rt.callAsync("ZaloE2EE.pc.refillPreKeys", [.string(uid), .number(40)]),
               let opKeys = Self.jsValueToNative(res["opKeys"] ?? .null) as? [[String: Any]],
               !opKeys.isEmpty {
                if let json = res["storeJSON"]?.stringValue, !json.isEmpty {
                    try? await store?.setPreferenceString(key: Self.storePrefKey, value: json)
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
                    if let _ = await decryptString(uid: uid, senderUid: fromUid, preferredDeviceId: devId, cipher: cipher) {
                        storeDirty = true
                        if fromUid != uid {
                            await markE2EEConversation(fromUid, enabled: true, store: store)
                        }
                        _ = await webSocket.sendRequestFrame(
                            cmd: Self.cmdAckInitSession,
                            subCmd: 0,
                            version: 1,
                            innerData: ZaloJSONBox(Self.buildAckInitSessionInnerData(uidTo: fromUid, deviceId: devId, ts: ts)),
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

    // MARK: - Outgoing Sessions & Encryption

    private func listSessions(remoteUid: String) async -> [(deviceId: Int, registrationId: Int)] {
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
        guard let rt = runtime, registrationId > 0 else { return false }

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
        if !needsFetch && !fetchedBundlePeers.contains(cleanPeer) && cleanPeer != cleanMe && mySessions.isEmpty {
            needsFetch = true
        }
        guard needsFetch else { return !peerSessions.isEmpty }
        guard await webSocket.isAuthed else { return !peerSessions.isEmpty }

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
                    continue
                }

                let jsBundle = Self.nativeToJSValue(bundleObj)
                if let res = try? await rt.callAsync("ZaloE2EE.pc.processPreKeyBundle", [
                    .string(cleanMe),
                    .string(entry.uid),
                    .number(Double(devId)),
                    jsBundle,
                ]), res["ok"]?.boolValue == true {
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
        store: ZaloSQLiteStore?
    ) async -> [(toId: String, platform: Int, registrationId: Int, ciphers: [String])] {
        var values: [JSBridgeValue] = [.string(text)]
        var formats: [String] = ["string"]
        if let quoteText {
            values.append(.string(quoteText))
            formats.append("string")
        }
        return await encryptBatch(peerUid: peerUid, myUid: myUid, values: values, formats: formats, store: store)
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
        store: ZaloSQLiteStore?
    ) async -> [(toId: String, platform: Int, registrationId: Int, ciphers: [String])] {
        let cleanPeer = ZaloWireParser.stripUserPrefix(peerUid)
        let cleanMe = ZaloWireParser.stripUserPrefix(myUid)
        guard !cleanPeer.isEmpty, !cleanMe.isEmpty, !values.isEmpty else { return [] }
        await prepare(uid: cleanMe, store: store)
        guard let rt = runtime, registrationId > 0 else { return [] }

        let peerSessions = await listSessions(remoteUid: cleanPeer)
        guard !peerSessions.isEmpty else { return [] }

        var targets: [JSBridgeValue] = peerSessions.map { sess in
            .object(["userId": .string(cleanPeer), "deviceId": .number(Double(sess.deviceId))])
        }
        if cleanMe != cleanPeer {
            let mySessions = await listSessions(remoteUid: cleanMe).filter { $0.deviceId != 2 }
            for sess in mySessions {
                targets.append(.object(["userId": .string(cleanMe), "deviceId": .number(Double(sess.deviceId))]))
            }
        }

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

        if let exported = res["storeJSON"]?.stringValue, !exported.isEmpty {
            storeDirty = false
            try? await store?.setPreferenceString(key: Self.storePrefKey, value: exported)
        } else {
            storeDirty = true
            await persistStoreIfNeeded(store: store)
        }

        var output: [(toId: String, platform: Int, registrationId: Int, ciphers: [String])] = []
        for row in rows {
            guard let uid = row["userId"]?.stringValue,
                  let devId = row["deviceId"]?.intValue,
                  let regId = row["registrationId"]?.intValue,
                  let cipherVals = row["ciphers"]?.arrayValue else {
                continue
            }
            let ciphers = cipherVals.compactMap(\.stringValue)
            guard ciphers.count == values.count else { continue }
            output.append((toId: uid, platform: devId, registrationId: regId, ciphers: ciphers))
        }
        guard output.contains(where: { $0.toId == cleanPeer }) else {
            return []
        }
        return output
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

        // Decrypt quote fields if E2EE-encrypted
        if var quote = (raw["quote"] as? [String: Any]) {
            let qMsg = JSONLossless.string(quote["msg"])
            if ZaloWireParser.isSignalCiphertext(qMsg),
               let plainQ = await decryptString(uid: myUid, senderUid: senderUid, preferredDeviceId: preferredDev, cipher: qMsg) {
                quote["msg"] = plainQ
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
        guard let rt = runtime else { return nil }
        for dev in candidateDevices(preferred: preferredDeviceId) {
            if let res = try? await rt.callAsync("ZaloE2EE.pc.decryptCipher", [
                .string(uid),
                .string(senderUid),
                .number(Double(dev)),
                .string(cipher),
                .string("string"),
            ]), res["ok"]?.boolValue == true, let text = res["text"]?.stringValue {
                storeDirty = true
                return text
            }
        }
        return nil
    }

    private func decryptUInt32(uid: String, senderUid: String, preferredDeviceId: Int?, cipher: String) async -> UInt32? {
        guard let rt = runtime else { return nil }
        for dev in candidateDevices(preferred: preferredDeviceId) {
            if let res = try? await rt.callAsync("ZaloE2EE.pc.decryptCipher", [
                .string(uid),
                .string(senderUid),
                .number(Double(dev)),
                .string(cipher),
                .string("uint32"),
            ]), res["ok"]?.boolValue == true, let num = res["number"]?.numberValue, num >= 0 {
                storeDirty = true
                return UInt32(num)
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
