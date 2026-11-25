import AppKit
import Foundation
@preconcurrency import UserNotifications

// Voice / video calls. The official renderer's call helper does the signalling (HostScripts/call-adapter.js
// drives it: `window.__zaloCall`, posts {page:'main', call:{…}}); `CallBridge` hosts the native call helper
// (ZaloCall, from Olaz's copy of Zalo.app) that draws the call window and handles mic / camera.
//
// Entry points used by the UI (chat header buttons, contact card "Gọi", call-log "Gọi lại"):
//   engine.canCall                                   calls are available
//   engine.startCall(to: uid, video: Bool)           the chat header's own action (groups: video only → participant picker,
//                                                     ZaloEngine+GroupCall.swift)

/// Calls as seen by the interface.
struct CallState: Equatable {
    struct Incoming: Equatable, Identifiable {
        let id = UUID()
        var name: String
        var avatar: URL?
        var group: Bool
        /// Group calls: who started it, when the control event says (shown under the group's name).
        var caller: String?
        var date: Date = .now
    }

    /// Short message shown over the window (call could not start, helper reported a problem).
    struct Notice: Equatable, Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    /// The renderer's call helper was found.
    var rendererReady = false
    /// Official `isSupport()` (server config + OS) and the IPC transport.
    var supported = false
    var videoSupported = false
    /// The renderer is in a call (`isCalling()`).
    var busy = false
    /// The Zalo runtime has the native helper.
    var helperInstalled = CallBridge.isHelperInstalled()
    /// Why the native helper cannot run (missing, failed to start), nil when fine.
    var helperProblem: String?
    var nativeRunning = false
    /// pid of the helper this app started (its window is the call window).
    var nativePID: Int32?
    var nativeState: String?
    /// The open conversation and whether the official header would offer calls for it (`canMakeCallAgain`).
    var conversationId: String?
    var conversationCanCall = false
    /// The open group's call button, by the official header rule (`nil`: no button). Video only.
    var conversationGroup: GroupGate?
    /// The participant picker (the renderer's GROUP_CALL modal) waiting for the user.
    var picker: GroupCallPicker?
    var incoming: Incoming?
    var notice: Notice?
}

/// Header rule for a group, from the renderer: `disabled` = shown but off (remote config -2), `feature` =
/// `enable_group_call_for_user` (without it the official `makeCall` refuses).
struct GroupGate: Equatable {
    var disabled: Bool
    var feature: Bool
}

enum CallAvailability: Equatable {
    case available
    /// Shown disabled, with this tooltip.
    case disabled(String)
    /// Not offered at all (group, own cloud, stranger / OA — like the official header).
    case hidden
}

extension ZaloEngine {
    /// True when the app can place calls.
    var canCall: Bool { call.supported && call.helperInstalled && call.helperProblem == nil }

    internal func updateCallGateForConversation(_ id: String) {
        let isGrp = ZaloWireParser.isGroupId(id)
        call.conversationId = id
        let friendAllowed = !contacts.friendsLoaded || contacts.friends.contains(where: { $0.id == id })
        call.conversationCanCall = !isGrp && id != selfConversationId && friendAllowed
        let groupMembers = conversations.first(where: { $0.id == id })?.members
            ?? contacts.groups.first(where: { $0.id == id })?.members ?? 0
        call.conversationGroup = isGrp ? GroupGate(disabled: groupMembers > 100, feature: true) : nil
    }

    /// Header button state for a conversation.
    func callAvailability(for conversation: ConversationSummary, video: Bool) -> CallAvailability {
        if conversation.id == selfConversationId { return .hidden }
        if conversation.isGroup {
            // The official header has a video button only for groups, shown by the member thresholds of the remote
            // "call" config; the renderer answers for the open conversation.
            guard video, call.conversationId == conversation.id, let gate = call.conversationGroup else { return .hidden }
            if gate.disabled { return .disabled("Cuộc gọi nhóm hiện chưa khả dụng") }
            if !gate.feature, call.supported { return .disabled("Tài khoản này chưa bật gọi nhóm") }
        } else if call.conversationId == conversation.id, !call.conversationCanCall, call.supported {
            // The official header offers calls to friends only; the renderer answers for the open conversation.
            return .hidden
        }
        if !call.helperInstalled { return .disabled("Thiếu trình gọi của Zalo — hãy mở lại \(AppBrand.name)") }
        if let problem = call.helperProblem { return .disabled(problem) }
        if !call.rendererReady { return .disabled("Đang khởi động cuộc gọi…") }
        if !call.supported { return .disabled("Tài khoản này chưa bật gọi điện trên Zalo PC") }
        if video, !call.videoSupported { return .disabled("Tài khoản này chưa bật gọi video") }
        if call.busy { return .disabled("Bạn đang trong một cuộc gọi khác") }
        return .available
    }

    /// Starts a 1-1 voice / video call to `uid`, or opens the participant picker for a group video call (`g...`).
    func startCall(to uid: String, video: Bool) {
        guard !uid.isEmpty else { return }
        guard traceHost("start_call", args: ["uid": uid, "video": video]) else { return }
        if uid.hasPrefix("g"), !video {
            showCallNotice("Chỉ gọi video cho nhóm", "Zalo chỉ hỗ trợ gọi video trong nhóm. Hãy chọn nút gọi video.")
            return
        }
        guard canCall else {
            showCallNotice("Chưa thể gọi", call.helperProblem ?? "Cuộc gọi chưa sẵn sàng. Hãy thử lại sau ít giây.")
            return
        }
        if call.busy {
            showCallNotice("Đang trong cuộc gọi", "Hãy kết thúc cuộc gọi hiện tại trước khi gọi tiếp.")
            return
        }

        if ZaloWireParser.isGroupId(uid) {
            guard isEngineStarted || callBridge != nil else { return }
            openGroupCallPickerForOutgoingCall(groupConvId: uid, video: video)
            return
        }

        // Spawn ZaloCall helper on-demand only when starting or receiving a call.
        ensureCallBridgeStartedIfNeeded()
        CallSequence.next += 1
        let cleanUid = ZaloWireParser.stripUserPrefix(uid)
        let targetInfo = lookupPersonInfo(cleanUid)
        let convSummary = conversations.first(where: { $0.id == cleanUid })
        let partnerName = (targetInfo?.name.isEmpty == false)
            ? targetInfo!.name
            : (convSummary?.displayName ?? "Người dùng Zalo")
        let partnerAvatar = (targetInfo?.avatar.isEmpty == false)
            ? targetInfo!.avatar
            : (convSummary?.avatar?.absoluteString ?? "")

        let makeCallJSON = ZaloVoiceCallProtocol.buildMakeCallJSON(
            partners: [(id: cleanUid, name: partnerName, avatar: partnerAvatar)],
            video: video
        )
        EngineLog.shared.write("call: start 1-1 uid=\(cleanUid) video=\(video)")
        callBridge?.sendToNative(json: makeCallJSON, optional: false)
    }

    private func openGroupCallPickerForOutgoingCall(groupConvId: String, video: Bool) {
        let convId = ZaloWireParser.groupConvId(groupConvId)
        let identity = lookupConversationIdentity(convId)
        let summary = conversations.first(where: { $0.id == convId })
        let groupName = !identity.name.isEmpty ? identity.name : (summary?.displayName ?? "Nhóm")
        let groupAvatar = identity.avatar ?? summary?.avatar
        let token = "grp-call-\(UUID().uuidString)"

        Task { @MainActor [weak self] in
            guard let self else { return }
            let members = await self.loadGroupCallMembers(groupConvId: convId)
            guard !members.isEmpty else {
                self.showCallNotice("Chưa thể gọi nhóm", "Không tìm thấy danh sách thành viên trong nhóm để bắt đầu cuộc gọi.")
                return
            }
            self.call.picker = GroupCallPicker(
                id: token,
                groupId: convId,
                adding: false,
                video: video,
                groupName: groupName,
                groupAvatar: groupAvatar,
                maxSelectable: 10,
                existing: [],
                note: nil,
                members: members
            )
            NSApp?.activate()
        }
    }

    // MARK: On-demand Helper Lifecycle & IPC Relay

    internal func currentCallInitJSON() -> String {
        let uid = profile?.userId ?? ""
        let name = profile?.displayName ?? "Người dùng Zalo"
        let avatar = profile?.avatar?.absoluteString ?? ""
        return ZaloVoiceCallProtocol.buildInitJSON(
            uid: uid,
            name: name,
            avatar: avatar,
            dataDirectory: dataDirectory
        )
    }

    /// Instantiates and connects VNG's signed `ZaloCall` helper strictly on demand.
    internal func ensureCallBridgeStartedIfNeeded() {
        guard call.helperInstalled else {
            call.helperProblem = "Không tìm thấy ZaloCall helper (/Applications/Zalo.app)"
            return
        }
        guard isEngineStarted || callBridge != nil else { return }
        if callBridge == nil {
            let bridge = CallBridge(emit: { [weak self] channel, args in
                self?.relayCallSignal(channel: channel, args: args)
            })
            bridge.onEvent = { [weak self] event in
                self?.handleCall(event: event)
            }
            callBridge = bridge
        }
        // Set init payload synchronously BEFORE any sendToNative so `native-ready` ALWAYS sends `init` first!
        callBridge?.setInit(json: currentCallInitJSON())
        if (profile?.userId ?? "").isEmpty {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let snap = await self.sessionClient.currentSnapshot()
                if let acc = snap.account, !acc.userId.isEmpty {
                    let refreshed = ZaloVoiceCallProtocol.buildInitJSON(
                        uid: acc.userId,
                        name: acc.displayName,
                        avatar: acc.avatar,
                        dataDirectory: self.dataDirectory
                    )
                    self.callBridge?.setInit(json: refreshed)
                }
            }
        }
    }

    internal func relayCallSignal(channel: String, args: [Any]) {
        switch channel {
        case "call-send-signal":
            guard !args.isEmpty else { return }
            let cmd = Int(JSONLossless.int64(args[0]) ?? 0)
            let params: [String: Any] = {
                if args.count > 1, let dict = args[1] as? [String: Any] { return dict }
                if args.count > 1, let str = args[1] as? String,
                   let d = str.data(using: .utf8), let parsed = JSONLossless.parseObject(d) {
                    return parsed
                }
                return [:]
            }()
            guard cmd > 0 else { return }
            let paramsBox = ZaloJSONBox(params)
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let (resp, activate) = try await self.sessionClient.sendVoiceCallSignal(command: cmd, params: paramsBox)
                    if activate {
                        NSApp?.activate()
                    }
                    let errCode = JSONLossless.int64(resp.dict["error_code"]) ?? -1
                    EngineLog.shared.write("call: signal cmd=\(cmd) err=\(errCode)")
                    if errCode == 0 {
                        let recvJSON = ZaloVoiceCallProtocol.buildRecvSignalJSON(command: cmd, data: resp.dict["data"])
                        self.callBridge?.sendToNative(json: recvJSON, optional: false)
                    } else if cmd == 401 || cmd == 12433 {
                        let errMsg = JSONLossless.string(resp.dict["error_message"])
                        if !errMsg.isEmpty {
                            self.showCallNotice("Chưa gọi được", errMsg)
                        }
                    }
                } catch {
                    EngineLog.shared.write("call: signal cmd=\(cmd) error=\(error.localizedDescription)")
                }
            }

        case "call-request":
            let cmdName = JSONLossless.string(args.first)
            let reqData: [String: Any] = (args.count > 1 ? args[1] as? [String: Any] : nil) ?? [:]
            handleHelperCallRequest(command: cmdName, data: reqData)

        case "call-update":
            let cmdName = JSONLossless.string(args.first)
            let updData: [String: Any] = (args.count > 1 ? args[1] as? [String: Any] : nil) ?? [:]
            handleHelperCallUpdate(command: cmdName, data: updData)

        default:
            break
        }
    }

    private func handleHelperCallRequest(command: String, data: [String: Any]) {
        switch command {
        case "serverTime":
            let resp: [String: Any] = [
                "type": "response",
                "command": "serverTime",
                "data": ["timestamp": Int64(Date().timeIntervalSince1970 * 1000)],
            ]
            if let raw = try? JSONSerialization.data(withJSONObject: resp),
               let json = String(data: raw, encoding: .utf8) {
                callBridge?.sendToNative(json: json, optional: false)
            }

        case "getAliasName":
            let noisedId = JSONLossless.string(data["noisedId"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !noisedId.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let alias = await self.resolveCallAliasName(for: noisedId)
                let resp: [String: Any] = [
                    "type": "response",
                    "command": "getAliasName",
                    "data": [
                        "noisedId": noisedId,
                        "aliasName": alias,
                    ],
                ]
                if let raw = try? JSONSerialization.data(withJSONObject: resp),
                   let json = String(data: raw, encoding: .utf8) {
                    self.callBridge?.sendToNative(json: json, optional: true)
                }
            }

        case "addUser", "addFriend":
            NSApp?.activate()
            let rawGroupId = JSONLossless.string(data["groupId"])
            let rawPartners = (data["partners"] as? [Any] ?? data["calleeIds"] as? [Any] ?? []).map(JSONLossless.string).filter { !$0.isEmpty }
            let maxUsers = Int(JSONLossless.int64(data["maxUsers"]) ?? 11)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let resolved = await self.sessionClient.resolveNoisedCallIds(
                    fids: rawPartners,
                    gids: rawGroupId.isEmpty ? [] : [rawGroupId]
                )
                let cleanGroup = resolved.groups[rawGroupId] ?? ZaloWireParser.cleanGroupId(rawGroupId)
                guard !cleanGroup.isEmpty else { return }
                let groupConvId = ZaloWireParser.groupConvId(cleanGroup)
                var existingSet = Set<String>()
                for p in rawPartners {
                    existingSet.insert(ZaloWireParser.stripUserPrefix(resolved.friends[p] ?? p))
                }
                let members = await self.loadGroupCallMembers(groupConvId: groupConvId)
                let identity = self.lookupConversationIdentity(groupConvId)
                self.call.picker = GroupCallPicker(
                    id: "add-user-\(UUID().uuidString)",
                    groupId: groupConvId,
                    adding: true,
                    video: nil,
                    groupName: identity.name.isEmpty ? "Nhóm" : identity.name,
                    groupAvatar: identity.avatar,
                    maxSelectable: max(1, maxUsers - 1),
                    existing: existingSet,
                    note: nil,
                    members: members
                )
            }

        default:
            break
        }
    }

    private func handleHelperCallUpdate(command: String, data: [String: Any]) {
        switch command {
        case "listDevice":
            let initJSON = currentCallInitJSON()
            callBridge?.setInit(json: initJSON)
            callBridge?.sendToNative(json: initJSON, optional: true)
        default:
            break
        }
    }

    struct IncomingCallMetadata: Sendable, Equatable {
        var isGroup: Bool
        var callerCandidateIds: [String]
        var groupCandidateIds: [String]
        var inlineCallerName: String
        var inlineGroupName: String
        var inlineAvatar: String
        var inlineGroupAvatar: String
    }

    private nonisolated static func parseNestedObject(_ raw: Any?) -> [String: Any]? {
        if let dict = raw as? [String: Any] { return dict }
        if let s = raw as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{"),
               let data = trimmed.data(using: .utf8),
               let obj = JSONLossless.parseObject(data) {
                return obj
            }
        }
        return nil
    }

    private nonisolated static func normalizeCandidateUserId(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("u"), trimmed.count > 1, trimmed.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    nonisolated static func isMeaningfulPersonName(_ name: String, rawUid: String = "") -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "Người dùng Zalo" else { return false }
        if !rawUid.isEmpty && trimmed == rawUid { return false }
        return true
    }

    nonisolated static func extractIncomingCallMetadata(act: String, parsedData: [String: Any]) -> IncomingCallMetadata {
        var objs: [[String: Any]] = [parsedData]
        for nestedKey in ["data", "extendData", "groupInfo"] {
            if let nested = parseNestedObject(parsedData[nestedKey]) {
                objs.append(nested)
            }
        }

        func firstString(_ keys: [String]) -> String {
            for key in keys {
                for obj in objs {
                    let s = JSONLossless.string(obj[key]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty { return s }
                }
            }
            return ""
        }

        var rawGroupIds: [String] = []
        var seenGroupIds = Set<String>()
        func appendGroupId(_ raw: String) {
            let clean = ZaloWireParser.cleanGroupId(raw)
            guard !clean.isEmpty, clean != "0", seenGroupIds.insert(clean).inserted else { return }
            rawGroupIds.append(clean)
        }

        for key in ["groupId", "grid", "gid", "groupID"] {
            for obj in objs {
                let s = JSONLossless.string(obj[key]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { appendGroupId(s) }
            }
        }
        for obj in objs {
            let uidN = JSONLossless.string(obj["uidN"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if ZaloWireParser.isGroupId(uidN) {
                appendGroupId(uidN)
            }
        }

        let isGroup = (act == "group_request") || !rawGroupIds.isEmpty

        var callerCandidates: [String] = []
        var seenCallerIds = Set<String>()
        func appendCallerId(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "0", !ZaloWireParser.isGroupId(trimmed) else { return }
            let normalized = normalizeCandidateUserId(trimmed)
            if !normalized.isEmpty, normalized != "0", seenCallerIds.insert(normalized).inserted {
                callerCandidates.append(normalized)
            }
            if trimmed != normalized, seenCallerIds.insert(trimmed).inserted {
                callerCandidates.append(trimmed)
            }
        }

        for key in ["uidN", "fromUid", "uid", "uidFrom", "callerId", "hostCall", "fromId", "partnerId"] {
            for obj in objs {
                let raw = JSONLossless.string(obj[key])
                if !raw.isEmpty { appendCallerId(raw) }
            }
        }

        var callerNameKeys = ["callerName", "dName", "displayName", "fromDName", "partnerName"]
        if !isGroup {
            callerNameKeys.append("name")
        }
        let inlineCallerName = firstString(callerNameKeys)
        var groupNameKeys = ["groupName", "gName", "grName", "groupname"]
        if isGroup {
            groupNameKeys.append("name")
        }
        let inlineGroupName = firstString(groupNameKeys)
        let inlineAvatar = firstString(["avatar", "callerAvatar", "avt"])
        let inlineGroupAvatar = firstString(["groupAvatar", "gAvatar", "grAvatar"])

        return IncomingCallMetadata(
            isGroup: isGroup,
            callerCandidateIds: callerCandidates,
            groupCandidateIds: rawGroupIds,
            inlineCallerName: inlineCallerName,
            inlineGroupName: inlineGroupName,
            inlineAvatar: inlineAvatar,
            inlineGroupAvatar: inlineGroupAvatar
        )
    }

    private func resolvePersonFromCandidates(_ candidates: [String]) -> (uid: String, name: String, avatar: String)? {
        var bestAvatar = ""
        for rawUid in candidates {
            let uid = Self.normalizeCandidateUserId(rawUid)
            guard !uid.isEmpty else { continue }
            if let info = lookupPersonInfo(uid) {
                if bestAvatar.isEmpty && !info.avatar.isEmpty {
                    bestAvatar = info.avatar
                }
                if Self.isMeaningfulPersonName(info.name, rawUid: uid) {
                    return (uid, info.name, info.avatar.isEmpty ? bestAvatar : info.avatar)
                }
            }
            if let mappedUid = cachedFriendGlobalIds.first(where: { $0.value == rawUid || $0.value == uid })?.key,
               let info = lookupPersonInfo(mappedUid),
               Self.isMeaningfulPersonName(info.name, rawUid: mappedUid) {
                return (mappedUid, info.name, info.avatar.isEmpty ? bestAvatar : info.avatar)
            }
        }
        return nil
    }

    internal func resolveCallAliasName(for noisedId: String) async -> String {
        let trimmed = noisedId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let alias = cachedAliases[trimmed], Self.isMeaningfulPersonName(alias, rawUid: trimmed) {
            return alias
        }
        if let local = resolvePersonFromCandidates([trimmed]) {
            return cachedAliases[local.uid] ?? local.name
        }
        var candidates: [String] = [trimmed]
        let znoise = await sessionClient.resolveNoisedCallIds(fids: [trimmed], gids: [])
        if let mapped = znoise.friends[trimmed], !mapped.isEmpty {
            candidates.insert(mapped, at: 0)
        }
        let dec = await sessionClient.decryptGlobalIds([trimmed])
        if let mapped = dec[trimmed], !mapped.isEmpty {
            candidates.insert(mapped, at: 0)
        }
        if let resolved = resolvePersonFromCandidates(candidates) {
            return cachedAliases[resolved.uid] ?? resolved.name
        }
        let profileUids = candidates.compactMap { ZaloWireParser.sanitizeProfileUid($0) }
        if !profileUids.isEmpty,
           let profBox = try? await sessionClient.fetchProfiles(uids: profileUids) {
            for (uid, row) in ZaloWireParser.extractProfilesMap(profBox.dict) {
                let c = ZaloWireParser.stripUserPrefix(uid)
                let n = ZaloWireParser.preferredName(row)
                let a = JSONLossless.string(row["avatar"] ?? row["avt"])
                if !c.isEmpty, (!n.isEmpty || !a.isEmpty) {
                    cachedProfiles[c] = ZaloWebKitMigrator.CachedProfile(name: n, avatar: a)
                }
            }
            if let resolved = resolvePersonFromCandidates(candidates) {
                return cachedAliases[resolved.uid] ?? resolved.name
            }
        }
        return ""
    }

    internal func handleVoipControlEvent(
        act: String,
        rawDataValue: Any?,
        parsedData: [String: Any],
        launchHelperIfNeeded: Bool = true
    ) async {
        let trimmedAct = act.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAct.isEmpty else { return }

        let isIncomingRequest = (trimmedAct == "request" || trimmedAct == "group_request")
        if isIncomingRequest {
            let rawTs = JSONLossless.int64(parsedData["ts"] ?? parsedData["timestamp"] ?? parsedData["serverTime"]) ?? 0
            if rawTs > 0 {
                let tsMs = rawTs < 10_000_000_000 ? rawTs * 1000 : rawTs
                let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                if nowMs - tsMs > 60_000 {
                    EngineLog.shared.write("call: ignored stale voip \(trimmedAct) ageMs=\(nowMs - tsMs)")
                    return
                }
            }
        }

        // Official `OU7N` passes parsed JSON object in `data` (`"{" == e.data[0] || "[" == e.data[0] ? JSON.parse(e.data) : e.data`).
        let normalizedData: Any = {
            if !parsedData.isEmpty { return parsedData }
            if let s = rawDataValue as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if (t.hasPrefix("{") || t.hasPrefix("[")),
                   let d = t.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: d) {
                    return obj
                }
                return s
            }
            return rawDataValue ?? [:]
        }()

        var voipCtrl: [String: Any] = [
            "act_type": "voip",
            "act": trimmedAct,
            "data": normalizedData,
        ]

        if isIncomingRequest {
            let wasBusy = call.busy
            voipCtrl["inCallStatus"] = wasBusy ? "zalo" : NSNull()

            let meta = Self.extractIncomingCallMetadata(act: trimmedAct, parsedData: parsedData)
            let isGroup = meta.isGroup
            var resolvedCaller = resolvePersonFromCandidates(meta.callerCandidateIds)
            var resolvedGroupIds = meta.groupCandidateIds

            var allCandidates = meta.callerCandidateIds
            if resolvedCaller == nil && !meta.callerCandidateIds.isEmpty {
                let decrypted = await sessionClient.decryptGlobalIds(meta.callerCandidateIds)
                var newlyMapped: [String] = []
                for cand in meta.callerCandidateIds {
                    if let mapped = decrypted[cand], !mapped.isEmpty, !allCandidates.contains(mapped) {
                        newlyMapped.append(mapped)
                    }
                }
                if !newlyMapped.isEmpty {
                    allCandidates = newlyMapped + allCandidates
                    resolvedCaller = resolvePersonFromCandidates(allCandidates)
                }
            }

            if (resolvedCaller == nil && !allCandidates.isEmpty) || (isGroup && !meta.groupCandidateIds.isEmpty) {
                let znoise = await sessionClient.resolveNoisedCallIds(
                    fids: resolvedCaller == nil ? allCandidates : [],
                    gids: meta.groupCandidateIds
                )
                var mappedCallers: [String] = []
                for cand in allCandidates {
                    if let mapped = znoise.friends[cand], !mapped.isEmpty, !allCandidates.contains(mapped) {
                        mappedCallers.append(mapped)
                    }
                }
                if !mappedCallers.isEmpty {
                    allCandidates = mappedCallers + allCandidates
                    if resolvedCaller == nil {
                        resolvedCaller = resolvePersonFromCandidates(allCandidates)
                    }
                }
                for (i, gid) in resolvedGroupIds.enumerated() {
                    if let mapped = znoise.groups[gid], !mapped.isEmpty {
                        resolvedGroupIds[i] = ZaloWireParser.cleanGroupId(mapped)
                    }
                }
            }

            if resolvedCaller == nil {
                var seenFetch = Set<String>()
                let profileFetchUids = allCandidates.compactMap { raw -> String? in
                    guard let uid = ZaloWireParser.sanitizeProfileUid(raw), seenFetch.insert(uid).inserted else { return nil }
                    return uid
                }
                if !profileFetchUids.isEmpty,
                   let profBox = try? await sessionClient.fetchProfiles(uids: profileFetchUids) {
                    for (uid, row) in ZaloWireParser.extractProfilesMap(profBox.dict) {
                        let c = ZaloWireParser.stripUserPrefix(uid)
                        let n = ZaloWireParser.preferredName(row)
                        let a = JSONLossless.string(row["avatar"] ?? row["avt"])
                        if !c.isEmpty, (!n.isEmpty || !a.isEmpty) {
                            cachedProfiles[c] = ZaloWebKitMigrator.CachedProfile(name: n, avatar: a)
                        }
                    }
                    resolvedCaller = resolvePersonFromCandidates(allCandidates)
                }
            }

            let callerName: String = {
                if let resolvedCaller, Self.isMeaningfulPersonName(resolvedCaller.name, rawUid: resolvedCaller.uid) {
                    return resolvedCaller.name
                }
                if Self.isMeaningfulPersonName(meta.inlineCallerName) {
                    return meta.inlineCallerName
                }
                return ""
            }()
            let callerAvatar: String = {
                if let resolvedCaller, !resolvedCaller.avatar.isEmpty {
                    return resolvedCaller.avatar
                }
                return meta.inlineAvatar
            }()

            if !wasBusy, call.helperInstalled, call.helperProblem == nil {
                let incoming: CallState.Incoming = {
                    if isGroup {
                        var gName = ""
                        var gAvatar: URL?
                        for rawGroupId in resolvedGroupIds {
                            let gConvId = ZaloWireParser.groupConvId(rawGroupId)
                            guard !gConvId.isEmpty else { continue }
                            let gIdent = lookupConversationIdentity(gConvId)
                            if gName.isEmpty && Self.isMeaningfulPersonName(gIdent.name, rawUid: gConvId) {
                                gName = gIdent.name
                            }
                            if gAvatar == nil {
                                gAvatar = gIdent.avatar
                            }
                            if gName.isEmpty, let conv = conversations.first(where: { $0.id == gConvId }) {
                                if Self.isMeaningfulPersonName(conv.name, rawUid: gConvId) {
                                    gName = conv.name
                                }
                                if gAvatar == nil {
                                    gAvatar = conv.avatar
                                }
                            }
                            if !gName.isEmpty { break }
                        }
                        if gName.isEmpty && Self.isMeaningfulPersonName(meta.inlineGroupName) {
                            gName = meta.inlineGroupName
                        }
                        let title = !gName.isEmpty ? gName : (!callerName.isEmpty ? callerName : "Cuộc gọi nhóm")
                        let avt = gAvatar
                            ?? (meta.inlineGroupAvatar.isEmpty ? nil : URL(string: meta.inlineGroupAvatar))
                            ?? (callerAvatar.isEmpty ? nil : URL(string: callerAvatar))
                        return CallState.Incoming(
                            name: title,
                            avatar: avt,
                            group: true,
                            caller: (!gName.isEmpty && !callerName.isEmpty) ? callerName : nil
                        )
                    } else {
                        let title = !callerName.isEmpty ? callerName : "Một người bạn"
                        return CallState.Incoming(
                            name: title,
                            avatar: callerAvatar.isEmpty ? nil : URL(string: callerAvatar),
                            group: false,
                            caller: nil
                        )
                    }
                }()
                call.incoming = incoming
                announceIncomingCall(incoming)
                scheduleIncomingExpiry(incoming.id)
            }

            let keyList = parsedData.keys.sorted().joined(separator: ",")
            EngineLog.shared.write("call: recv incoming voip act=\(trimmedAct) group=\(isGroup) busy=\(wasBusy) resolved=\(!callerName.isEmpty) keys=\(keyList)")
            if launchHelperIfNeeded {
                ensureCallBridgeStartedIfNeeded()
                let ctrlJSON = ZaloVoiceCallProtocol.buildControlJSON(voipPayload: voipCtrl)
                callBridge?.sendToNative(json: ctrlJSON, optional: false)
            }
        } else {
            let terminalActs: Set<String> = ["answer", "cancel", "endcall", "group_answer", "group_cancel", "group_endcall", "finish"]
            if terminalActs.contains(trimmedAct) {
                call.incoming = nil
            }
            if launchHelperIfNeeded, callBridge != nil {
                let ctrlJSON = ZaloVoiceCallProtocol.buildControlJSON(voipPayload: voipCtrl)
                EngineLog.shared.write("call: forward voip control act=\(trimmedAct)")
                callBridge?.sendToNative(json: ctrlJSON, optional: true)
            }
        }
    }

    func handleCall(event: CallBridge.Event) {
        var next = call
        switch event {
        case .helperUnavailable(let reason):
            next.helperProblem = reason
            next.nativeRunning = false
            next.nativePID = nil
            next.helperInstalled = CallBridge.isHelperInstalled()
        case .helperStarted(let pid):
            next.helperProblem = nil
            next.nativeRunning = true
            next.nativePID = pid
        case .ready:
            next.helperProblem = nil
            next.nativeRunning = true
        case .exited:
            next.nativeRunning = false
            next.nativePID = nil
            next.nativeState = nil
            next.busy = false
            next.incoming = nil
            callBridge = nil
        case .callState(let state):
            next.nativeState = state
            next.busy = (state != "free")
            if state == "free" {
                next.incoming = nil
                // Reap helper promptly once call ends so 0 idle helpers remain.
                callBridge?.reset()
            }
        case .popup(let header, let content):
            if !content.isEmpty || !header.isEmpty {
                next.notice = CallState.Notice(title: header.isEmpty ? "Cuộc gọi Zalo" : header, message: content)
            }
        }
        if next != call { call = next }
    }

    /// `{page:'main', call:{kind, …}}` from call-adapter.js.
    func handleCall(state: [String: Any]) {
        guard let json = state["call"] as? [String: Any] else { return }
        var next = call
        switch json["kind"] as? String {
        case "status":
            next.rendererReady = json["ready"] as? Bool ?? false
            next.supported = json["supported"] as? Bool ?? false
            next.videoSupported = json["video"] as? Bool ?? false
            next.busy = json["busy"] as? Bool ?? false
            if let conv = json["conv"] as? [String: Any], let id = conv["id"] as? String {
                next.conversationId = id
                next.conversationCanCall = conv["can"] as? Bool ?? false
                next.conversationGroup = (conv["group"] as? [String: Any]).map {
                    GroupGate(disabled: $0["disabled"] as? Bool ?? false, feature: $0["feature"] as? Bool ?? false)
                }
            } else {
                next.conversationId = nil
                next.conversationCanCall = false
                next.conversationGroup = nil
            }
        case "open":
            // The call is allowed: show the conversation (the chat box action needs it open).
            if let id = json["uid"] as? String, !id.isEmpty, openConversationId != id { navigationRequest = id }
        case "result":
            if let result = json["result"] as? String,
               let message = Self.callFailureMessage(result, group: json["group"] as? Bool ?? false) {
                next.notice = CallState.Notice(title: "Chưa gọi được", message: message)
            }
        case "incoming":
            let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let group = json["group"] as? Bool ?? false
            let busy = json["busy"] as? Bool ?? false
            guard !busy else { break } // the official client auto-declines while in a call; nothing rings
            // Only when the helper can actually ring.
            guard call.helperInstalled, call.helperProblem == nil else { break }
            let caller = (json["caller"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // A group call is announced by the group's name; when only the caller is known, that name stands in.
            let incoming = CallState.Incoming(name: name ?? caller ?? (group ? "Cuộc gọi nhóm" : "Một người bạn"),
                                              avatar: (json["avatar"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) },
                                              group: group,
                                              caller: group && name != nil ? caller : nil)
            next.incoming = incoming
            announceIncomingCall(incoming)
            scheduleIncomingExpiry(incoming.id)
        case "picker":
            if let picker = GroupCallPicker(json: json) {
                next.picker = picker
                // Like the official request handler (`$zwindow.focus()`): the helper asked while its own window may be in front.
                NSApp?.activate()
            }
        case "pickerClosed":
            if next.picker?.id == json["token"] as? String { next.picker = nil }
        default:
            break
        }
        if next != call { call = next }
    }

    static func callFailureMessage(_ result: String, group: Bool = false) -> String? {
        if group, result == "unavailable" {
            return "Zalo không cho phép gọi nhóm này (nhóm có quá nhiều thành viên hoặc tài khoản chưa bật gọi nhóm)."
        }
        switch result {
        case "started": return nil
        case "busy": return "Bạn đang trong một cuộc gọi khác."
        case "offline": return "Không có kết nối mạng."
        case "unavailable": return "Zalo không cho phép gọi cho cuộc trò chuyện này (chỉ gọi được cho bạn bè)."
        case "unsupported": return "Tài khoản này chưa bật gọi điện trên Zalo PC."
        case "not-open", "not-ready": return "Cuộc trò chuyện chưa sẵn sàng. Hãy thử lại sau ít giây."
        case "invalid": return "Danh sách người tham gia không hợp lệ. Hãy chọn lại."
        default: return "Đã có lỗi khi bắt đầu cuộc gọi."
        }
    }

    func showCallNotice(_ title: String, _ message: String) {
        call.notice = CallState.Notice(title: title, message: message)
    }

    // MARK: Incoming calls

    /// The native helper shows the ringing window. This adds a banner in the app and, when the app is in the
    /// background, a macOS notification (the official renderer shows nothing for incoming calls itself).
    private func announceIncomingCall(_ incoming: CallState.Incoming) {
        guard NativeNotifier.shared.isAvailable, !(NSApp?.isActive ?? true) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Cuộc gọi đến"
        content.body = "\(incoming.name) đang gọi cho bạn"
        content.threadIdentifier = "zalo-call"
        Task {
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional else { return }
            try? await center.add(UNNotificationRequest(identifier: "call-" + incoming.id.uuidString, content: content, trigger: nil))
        }
    }

    private func scheduleIncomingExpiry(_ id: UUID) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard let self, self.call.incoming?.id == id else { return }
            self.call.incoming = nil
        }
    }

    /// Brings the native call window to the front (ringing / in-call).
    func showCallWindow() {
        // Our own child only — never another ZaloCall (e.g. the official Zalo's).
        guard let pid = call.nativePID else { return }
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
    }
}

/// Sequence numbers for `startCall` results (extensions cannot hold stored properties).
@MainActor
private enum CallSequence {
    static var next = 0
}
