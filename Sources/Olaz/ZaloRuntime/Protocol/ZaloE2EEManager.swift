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
    static let cmdGetKeyId: UInt16 = 564

    private var runtime: JSRuntime?
    private var loadedUid: String = ""
    private var registrationId: Int = 0
    private var bundlePayload: [String: Any] = [:]
    private var didCheckServerBundleForSession = false
    private var storeDirty = false

    func reset() {
        loadedUid = ""
        registrationId = 0
        bundlePayload = [:]
        didCheckServerBundleForSession = false
        storeDirty = false
    }

    func markDisconnected() {
        didCheckServerBundleForSession = false
    }

    private func ensureRuntime() async throws -> JSRuntime {
        if let existing = runtime { return existing }
        let rt = try JSRuntime(name: "zalo-pc-e2ee")
        try await rt.loadModule("vendor/libsignal-protocol.js")
        try await rt.loadModule("zalo-e2ee.js")
        runtime = rt
        return rt
    }

    func prepare(uid: String, store: ZaloSQLiteStore?) async {
        guard !uid.isEmpty else { return }
        if loadedUid == uid, registrationId > 0, runtime != nil { return }
        do {
            let rt = try await ensureRuntime()
            let savedJSON = (try? await store?.getPreferenceString(key: Self.storePrefKey)) ?? ""
            let res = try await rt.callAsync("ZaloE2EE.pc.initOrRestore", [.string(uid), .string(savedJSON)])
            loadedUid = uid
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
            innerData: ZaloJSONBox(["data": ["platformType": 2]]),
            timeoutSeconds: 8
        )
        let d1 = keyCheck?.dict["data"] as? [String: Any]
        let d2 = d1?["data"] as? [String: Any] ?? d1
        let serverKeyId = Int(JSONLossless.int64(d2?["keyId"]) ?? -1)
        let serverErr = Int(JSONLossless.int64(d2?["err"]) ?? 0)

        if serverKeyId == registrationId && serverErr == 0 {
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
            innerData: ZaloJSONBox(["data": bundlePayload]),
            timeoutSeconds: 10
        )
        let subD1 = submitResp?.dict["data"] as? [String: Any]
        let subD2 = subD1?["data"] as? [String: Any] ?? subD1
        let subCode = JSONLossless.int64(subD2?["err"] ?? submitResp?.dict["error_code"]) ?? (submitResp != nil ? 0 : -1)
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
                    innerData: ZaloJSONBox([
                        "data": [
                            "deviceId": 2,
                            "id": registrationId,
                            "opKeys": opKeys,
                        ]
                    ]),
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
                        _ = await webSocket.sendRequestFrame(
                            cmd: Self.cmdAckInitSession,
                            subCmd: 0,
                            version: 1,
                            innerData: ZaloJSONBox([
                                "data": [
                                    "type": 0,
                                    "uidTo": fromUid,
                                    "data": [["deviceId": devId, "ts": ts]],
                                ]
                            ]),
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
                    innerData: ZaloJSONBox([
                        "data": [
                            "queueName": "",
                            "info": doneAckInfos,
                        ]
                    ]),
                    timeoutSeconds: 6
                )
            }
            await persistStoreIfNeeded(store: store)

        default:
            break
        }
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

    static func envelopeContainsSignalCipher(_ node: Any) -> Bool {
        if let str = node as? String {
            if str.hasPrefix("AzM") || str.hasPrefix("AjM") { return true }
            if str.contains("AzM") || str.contains("AjM") { return true }
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
