import AppKit
import Foundation

// Card buttons (e-card actions, suggested stickers, contact card, info-message links, reminder cards), bridged to
// `HostScripts/card-actions-adapter.js` (`window.__zaloChat.performAction` & co.; contract in ChatModels.swift).
// Every call runs only after a click or when a card is shown; nothing here is fired on its own. Message content never goes to the log.
extension ZaloEngine {
    func performCardAction(in conversationId: String, message messageId: String, ref: String) async -> CardActionOutcome {
        if ref == "call:back" {
            let msg = messages[conversationId]?.first(where: { $0.id == messageId })
            let isVideo: Bool = {
                if case .call(let video, _, _, _, _) = msg?.kind { return video }
                return false
            }()
            startCall(to: conversationId, video: isVideo)
            return .done
        }
        let parts = ref.split(separator: "_")
        if parts.count == 2, let cateId = Int(parts[0]), let stickerId = Int(parts[1]), stickerId > 0 {
            return await sendCategorySticker(in: conversationId, category: cateId, sticker: stickerId)
        }
        return .unsupported(CardActionOutcome.defaultUnsupported)
    }

    func resetCardState() {
        reminderWatchCache.removeAll()
        let allWaiters = reminderWatchWaiters.values.flatMap(\.values)
        reminderWatchWaiters.removeAll()
        for wake in allWaiters { wake() }
    }

    func suggestedStickers(in conversationId: String, message messageId: String) async -> [SuggestedSticker] {
        let msg = messages[conversationId]?.first(where: { $0.id == messageId })
        let keyword: String = {
            if case .ecard(let card) = msg?.kind, card.style == .birthday {
                return "chúc mừng sinh nhật"
            }
            return "xin chào"
        }()
        guard let box = try? await sessionClient.suggestStickersAPI(keyword: keyword) else { return [] }
        var out: [SuggestedSticker] = []
        for row in box.array.prefix(8) {
            let sid = Int(JSONLossless.int64(row["id"] ?? row["stickerId"] ?? row["sticker_id"]) ?? 0)
            let cate = Int(JSONLossless.int64(row["cateId"] ?? row["cate_id"]) ?? 0)
            guard sid > 0 else { continue }
            let urlStr = ZaloWireParser.stickerCDNURL(cateId: cate, stickerId: "\(sid)")
            if let url = URL(string: urlStr) {
                out.append(SuggestedSticker(ref: "\(cate)_\(sid)", url: url))
            }
        }
        return out
    }

    func contactCardState(_ uid: String) async -> (isSelf: Bool, isFriend: Bool) {
        let clean = ZaloWireParser.normalizeContactUid(uid)
        let myUid = ZaloWireParser.normalizeContactUid(profile?.userId ?? "")
        let isSelf = !clean.isEmpty && clean == myUid
        let isFriend = contacts.friends.contains { $0.id == clean }
        return (isSelf, isFriend)
    }

    func contactProfile(_ uid: String) async -> ContactProfile? {
        let clean = ZaloWireParser.normalizeContactUid(uid)
        guard !clean.isEmpty else { return nil }
        let myUid = ZaloWireParser.normalizeContactUid(profile?.userId ?? "")
        if clean == myUid, let p = profile {
            return ContactProfile(uid: clean, name: p.displayName, avatar: p.avatar, isSelf: true, isFriend: false)
        }
        if let f = contacts.friends.first(where: { $0.id == clean }) {
            return ContactProfile(uid: clean, name: f.name, zaloName: f.zaloName, avatar: f.avatar, isSelf: false, isFriend: true)
        }
        if let box = try? await sessionClient.fetchProfiles(uids: [clean]),
           let row = ZaloWireParser.extractProfilesMap(box.dict)[clean] {
            let name = ZaloWireParser.preferredName(row)
            let zalo = JSONLossless.string(row["zaloName"])
            let avt = JSONLossless.string(row["avatar"] ?? row["avt"])
            return ContactProfile(uid: clean, name: name, zaloName: zalo, avatar: avt.isEmpty ? nil : URL(string: avt))
        }
        return nil
    }

    func prepareFriendRequest(to uid: String, from conversationId: String, via: FriendRequestOrigin) async -> FriendRequestPrep {
        let clean = ZaloWireParser.normalizeContactUid(uid)
        let myUid = ZaloWireParser.normalizeContactUid(profile?.userId ?? "")
        if !clean.isEmpty, clean == myUid { return FriendRequestPrep(state: .me) }
        if contacts.friends.contains(where: { $0.id == clean }) { return FriendRequestPrep(state: .friend) }
        if contacts.sent.contains(where: { $0.id == clean }) { return FriendRequestPrep(state: .requested) }
        if contacts.received.contains(where: { $0.id == clean }) { return FriendRequestPrep(state: .requesting) }
        let myName = profile?.displayName ?? "tôi"
        return FriendRequestPrep(state: .ready, defaultMessage: "Xin chào, mình là \(myName).", maxMessage: 150)
    }

    func submitFriendRequest(to uid: String, message: String) async -> (ok: Bool, text: String, pending: Bool) {
        do {
            _ = try await sessionClient.sendFriendRequestAPI(
                toUid: ZaloWireParser.normalizeContactUid(uid),
                message: message
            )
            refreshContacts()
            return (true, "Đã gửi lời mời kết bạn.", false)
        } catch {
            return (false, "Không thể gửi lời mời kết bạn.", false)
        }
    }

    // MARK: Native sheets of card actions

    func saveAlias(uid: String, name: String) async -> (ok: Bool, text: String) {
        guard let core = await ensureCoreEngine(),
              let res = try? await core.saveAlias(uid: uid, name: name) else {
            return (false, "Không lưu được tên gợi nhớ.")
        }
        if let v = try? await core.settle() {
            await waitForMirrorVersion(v)
        }
        return (res.ok, res.text)
    }

    func groupInvitePreview(_ url: URL) async -> GroupInvitePreview {
        guard let box = try? await sessionClient.fetchGroupLinkDetail(link: url.absoluteString),
              let d = box.dict["data"] as? [String: Any] else {
            return GroupInvitePreview()
        }
        let gid = ZaloWireParser.groupConvId(JSONLossless.string(d["groupId"]))
        guard !gid.isEmpty else { return GroupInvitePreview() }
        let alreadyMember = contacts.groups.contains(where: { $0.id == gid })
        if alreadyMember {
            return GroupInvitePreview(json: ["state": "member", "groupId": gid])
        }
        return GroupInvitePreview(json: [
            "state": "preview",
            "groupId": gid,
            "name": JSONLossless.string(d["name"]),
            "avatar": JSONLossless.string(d["avt"]),
            "totalMember": Int(JSONLossless.int64(d["totalMember"]) ?? 0),
            "desc": JSONLossless.string(d["desc"])
        ])
    }

    func joinGroup(_ url: URL) async -> GroupJoinResult {
        do {
            let box = try await sessionClient.joinGroupByLink(link: url.absoluteString)
            let d = box.dict["data"] as? [String: Any] ?? [:]
            let gid = ZaloWireParser.groupConvId(JSONLossless.string(d["groupId"]))
            refreshContacts()
            return GroupJoinResult(state: .joined, groupId: gid, text: "Đã tham gia nhóm.")
        } catch {
            return GroupJoinResult(state: .error, text: "Vào nhóm không thành công.")
        }
    }

    func stickerCategory(_ id: Int) async -> StickerCategory? {
        guard let items = await stickers(inTab: id), !items.isEmpty else { return nil }
        let rows: [[String: Any]] = items.map { ["ref": "\(id)_\($0.stickerId)", "url": $0.url.absoluteString] }
        return StickerCategory(json: ["id": id, "name": "Bộ sticker", "icon": "", "stickers": rows])
    }

    func sendCategorySticker(in conversationId: String, category: Int, sticker: Int) async -> CardActionOutcome {
        let urlStr = ZaloWireParser.stickerCDNURL(cateId: category, stickerId: "\(sticker)")
        let entry = StickerEntry(cateId: category, stickerId: sticker,
                                 url: URL(string: urlStr)!,
                                 animation: nil)
        return await sendSticker(entry, in: conversationId, source: .category)
    }

    private func resolveReminderId(in conversationId: String, messageId: String) -> String {
        if let pinRef = pins[conversationId]?.items.first(where: {
            $0.kind == .reminder && ($0.msgId == messageId || $0.cliMsgId == messageId)
        })?.ref, !pinRef.isEmpty {
            return pinRef
        }
        return messageId
    }

    private func reminderCardContext(in conversationId: String, messageId: String) -> ChatMessage.ECard? {
        guard let msg = messages[conversationId]?.first(where: { $0.id == messageId }),
              case .ecard(let card) = msg.kind else {
            return nil
        }
        return card
    }

    private func wakeReminderWaiters(for key: String) {
        guard let waiters = reminderWatchWaiters.removeValue(forKey: key) else { return }
        for wake in waiters.values { wake() }
    }

    private func waitForReminderChange(key: String, timeoutSeconds: Double = 15) async -> Bool {
        guard !Task.isCancelled else { return false }
        let waiterId = UUID()
        let result: Bool? = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
                let gate = OnceGate<Bool>(continuation)
                let wake: @Sendable () -> Void = { gate.resume(true) }
                reminderWatchWaiters[key, default: [:]][waiterId] = wake
                Task {
                    try? await Task.sleep(for: .seconds(timeoutSeconds))
                    await MainActor.run {
                        self.reminderWatchWaiters[key]?.removeValue(forKey: waiterId)
                        if self.reminderWatchWaiters[key]?.isEmpty == true {
                            self.reminderWatchWaiters.removeValue(forKey: key)
                        }
                    }
                    gate.resume(nil)
                }
            }
        } onCancel: {
            Task { @MainActor in
                if let wake = self.reminderWatchWaiters[key]?.removeValue(forKey: waiterId) {
                    if self.reminderWatchWaiters[key]?.isEmpty == true {
                        self.reminderWatchWaiters.removeValue(forKey: key)
                    }
                    wake()
                }
            }
        }
        return result ?? false
    }

    internal func normalizeReminderSnapshot(
        from responseDict: [String: Any],
        conversationId: String,
        reminderId: String,
        fallbackCard: ChatMessage.ECard? = nil
    ) -> ReminderSnapshot? {
        let data = (responseDict["data"] as? [String: Any]) ?? responseDict
        if data.isEmpty, fallbackCard == nil { return nil }

        let params: [String: Any] = {
            if let p = data["params"] as? [String: Any] { return p }
            if let pStr = data["params"] as? String,
               let parsed = JSONLossless.parseObject(string: pStr) {
                return parsed
            }
            return [:]
        }()

        func firstNonEmpty(_ values: String?...) -> String {
            for v in values {
                if let v, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return v }
            }
            return ""
        }

        let rid = firstNonEmpty(
            JSONLossless.string(data["rid"] ?? data["eventId"] ?? data["reminderId"] ?? data["id"] ?? data["topicId"]),
            reminderId
        )
        let title = firstNonEmpty(
            JSONLossless.string(data["title"] ?? data["topicTitle"]),
            JSONLossless.string(params["title"] ?? params["topicTitle"]),
            fallbackCard?.reminderTitle,
            fallbackCard?.title
        )
        let rawStart = JSONLossless.int64(data["startTime"] ?? data["start"] ?? params["startTime"]) ?? 0
        let startMs: Int64 = {
            if rawStart > 0 {
                return rawStart < 10_000_000_000 ? rawStart * 1000 : rawStart
            }
            if let d = fallbackCard?.reminderStart {
                return Int64((d.timeIntervalSince1970 * 1000).rounded())
            }
            return 0
        }()

        let explicitRepeat = firstNonEmpty(
            data["repeatLabel"] as? String,
            data["repeat"] as? String,
            params["repeatLabel"] as? String
        )
        let repeatLabel: String = {
            if !explicitRepeat.isEmpty { return explicitRepeat }
            if let mode = JSONLossless.int64(data["repeat"] ?? data["repeatMode"] ?? params["repeat"]) {
                switch mode {
                case 1: return "Hàng ngày"
                case 2: return "Hàng tuần"
                case 3: return "Hàng tháng"
                default: break
                }
            }
            return fallbackCard?.reminderRepeat ?? ""
        }()

        let creatorUid = ZaloWireParser.stripUserPrefix(JSONLossless.string(data["creatorId"] ?? data["creator"] ?? data["uid"]))
        let creatorName = firstNonEmpty(
            JSONLossless.string(data["creatorName"]),
            !creatorUid.isEmpty ? lookupPersonInfo(creatorUid)?.name : nil
        )
        let isGroup = JSONLossless.bool(data["isGroup"]) ?? ZaloWireParser.isGroupId(conversationId)
        let onlyMe = JSONLossless.bool(data["onlyMe"] ?? data["isOnlyMe"]) ?? false
        let deleted = (JSONLossless.bool(data["deleted"] ?? data["isDeleted"]) == true)
            || (JSONLossless.int64(data["delStatus"]) == 1)
            || (JSONLossless.int64(data["status"]) == -1)

        func extractUidSet(_ raw: Any?) -> [String] {
            guard let arr = raw as? [Any] else { return [] }
            return arr.compactMap { item in
                let rawId: String
                if let dict = item as? [String: Any] {
                    rawId = JSONLossless.string(dict["uid"] ?? dict["userId"] ?? dict["id"])
                } else {
                    rawId = JSONLossless.string(item)
                }
                let clean = ZaloWireParser.stripUserPrefix(rawId)
                return clean.isEmpty ? nil : clean
            }
        }

        let acceptUids = extractUidSet(data["acceptUids"] ?? data["accept"])
        let rejectUids = extractUidSet(data["rejectUids"] ?? data["reject"])
        let acceptedCount = max(0, Int(JSONLossless.int64(
            data["accepted"] ?? data["acceptedCount"] ?? data["acceptCount"] ?? data["numAccept"] ?? data["totalAccept"] ?? data["totalJoin"]
        ) ?? Int64(acceptUids.count)))
        let rejectedCount = max(0, Int(JSONLossless.int64(
            data["rejected"] ?? data["rejectedCount"] ?? data["rejectCount"] ?? data["numReject"] ?? data["totalReject"] ?? data["totalDecline"]
        ) ?? Int64(rejectUids.count)))

        let myUid = ZaloWireParser.stripUserPrefix(profile?.userId ?? "")
        let mineStr: String = {
            if let explicit = data["mine"] as? String, explicit == "accept" || explicit == "reject" {
                return explicit
            }
            if let res = JSONLossless.int64(data["myRes"] ?? data["myResponse"] ?? data["userResponse"] ?? data["responseType"]) {
                if res == 1 { return "accept" }
                if res == 2 { return "reject" }
            }
            if !myUid.isEmpty {
                if acceptUids.contains(myUid) { return "accept" }
                if rejectUids.contains(myUid) { return "reject" }
            }
            return ""
        }()

        let canRsvp = JSONLossless.bool(data["canRsvp"]) ?? (isGroup && !onlyMe && !deleted)
        let canView = JSONLossless.bool(data["canView"]) ?? !deleted
        let variantStr = firstNonEmpty(data["variant"] as? String, "invite")
        let explicitSig = JSONLossless.string(data["sig"])
        let sig = explicitSig.isEmpty
            ? "\(rid)|\(title)|\(startMs)|\(repeatLabel)|\(mineStr)|\(acceptedCount)|\(rejectedCount)|\(deleted)|\(variantStr)"
            : explicitSig

        return ReminderSnapshot(json: [
            "variant": variantStr,
            "rid": rid,
            "title": title,
            "start": Double(startMs),
            "repeat": repeatLabel,
            "creatorName": creatorName,
            "onlyMe": onlyMe,
            "isGroup": isGroup,
            "mine": mineStr,
            "accepted": acceptedCount,
            "rejected": rejectedCount,
            "canRsvp": canRsvp,
            "canView": canView,
            "deleted": deleted,
            "sig": sig
        ])
    }

    func reminderWatch(in conversationId: String, message messageId: String, signature: String) async -> ReminderSnapshot? {
        let eventId = resolveReminderId(in: conversationId, messageId: messageId)
        guard !eventId.isEmpty else { return nil }
        let key = "\(conversationId)|\(messageId)"
        if !signature.isEmpty,
           let cached = reminderWatchCache[key],
           cached.sig == signature {
            _ = await waitForReminderChange(key: key, timeoutSeconds: 15)
            if Task.isCancelled { return nil }
        }
        guard let box = try? await sessionClient.fetchReminderDetail(convId: conversationId, reminderId: eventId) else {
            return nil
        }
        let card = reminderCardContext(in: conversationId, messageId: messageId)
        guard let snap = normalizeReminderSnapshot(
            from: box.dict,
            conversationId: conversationId,
            reminderId: eventId,
            fallbackCard: card
        ) else {
            return nil
        }
        reminderWatchCache[key] = (sig: snap.sig, snapshot: snap)
        return snap
    }

    func respondToReminder(in conversationId: String, message messageId: String, accept: Bool) async -> (ok: Bool, text: String, snapshot: ReminderSnapshot?) {
        let eventId = resolveReminderId(in: conversationId, messageId: messageId)
        do {
            _ = try await sessionClient.respondReminderAPI(convId: conversationId, reminderId: eventId, accept: accept)
            let key = "\(conversationId)|\(messageId)"
            var updated: ReminderSnapshot?
            if let box = try? await sessionClient.fetchReminderDetail(convId: conversationId, reminderId: eventId) {
                let card = reminderCardContext(in: conversationId, messageId: messageId)
                updated = normalizeReminderSnapshot(
                    from: box.dict,
                    conversationId: conversationId,
                    reminderId: eventId,
                    fallbackCard: card
                )
            }
            if let updated {
                reminderWatchCache[key] = (sig: updated.sig, snapshot: updated)
            } else {
                reminderWatchCache.removeValue(forKey: key)
            }
            wakeReminderWaiters(for: key)
            return (true, accept ? "Đã xác nhận tham gia." : "Đã từ chối.", updated)
        } catch {
            return (false, "Không thực hiện được thao tác.", nil)
        }
    }

    private func extractResponderBuckets(from responseDict: [String: Any]) -> (
        accept: [(uid: String, name: String, avatar: String)],
        reject: [(uid: String, name: String, avatar: String)],
        acceptTotal: Int,
        rejectTotal: Int,
        acceptMore: Int,
        rejectMore: Int
    )? {
        let data: [String: Any]
        if let d = responseDict["data"] as? [String: Any] {
            data = d
        } else if responseDict["data"] is [Any] {
            data = responseDict
        } else if !responseDict.isEmpty {
            data = responseDict
        } else {
            return nil
        }

        func parseEntry(_ raw: Any) -> (uid: String, name: String, avatar: String, type: Int?)? {
            if let dict = raw as? [String: Any] {
                let uid = ZaloWireParser.stripUserPrefix(JSONLossless.string(
                    dict["uid"] ?? dict["userId"] ?? dict["user_id"] ?? dict["id"]
                ))
                guard !uid.isEmpty, uid != "0" else { return nil }
                let name = ZaloWireParser.preferredName(dict)
                let avatar = JSONLossless.string(dict["avatar"] ?? dict["avt"])
                let rType = JSONLossless.int64(dict["type"] ?? dict["responseType"] ?? dict["status"]).map(Int.init)
                return (uid, name, avatar, rType)
            }
            let uid = ZaloWireParser.stripUserPrefix(JSONLossless.string(raw))
            guard !uid.isEmpty, uid != "0" else { return nil }
            return (uid, "", "", nil)
        }

        var acceptRaw: [(uid: String, name: String, avatar: String)] = []
        var rejectRaw: [(uid: String, name: String, avatar: String)] = []

        if let arr = (data["accept"] as? [Any]) ?? (data["accepts"] as? [Any]) ?? (data["acceptUids"] as? [Any]) ?? (data["join"] as? [Any]) {
            for item in arr {
                if let e = parseEntry(item) { acceptRaw.append((e.uid, e.name, e.avatar)) }
            }
        }
        if let arr = (data["reject"] as? [Any]) ?? (data["rejects"] as? [Any]) ?? (data["rejectUids"] as? [Any]) ?? (data["decline"] as? [Any]) {
            for item in arr {
                if let e = parseEntry(item) { rejectRaw.append((e.uid, e.name, e.avatar)) }
            }
        }
        if acceptRaw.isEmpty && rejectRaw.isEmpty,
           let combined = (data["responses"] as? [Any]) ?? (data["items"] as? [Any]) ?? (data["list"] as? [Any]) ?? (responseDict["data"] as? [Any]) {
            for item in combined {
                guard let e = parseEntry(item) else { continue }
                if e.type == 2 {
                    rejectRaw.append((e.uid, e.name, e.avatar))
                } else {
                    acceptRaw.append((e.uid, e.name, e.avatar))
                }
            }
        }

        let acceptTotal = max(acceptRaw.count, Int(JSONLossless.int64(data["acceptTotal"] ?? data["totalAccept"] ?? data["numAccept"]) ?? Int64(acceptRaw.count)))
        let rejectTotal = max(rejectRaw.count, Int(JSONLossless.int64(data["rejectTotal"] ?? data["totalReject"] ?? data["numReject"]) ?? Int64(rejectRaw.count)))
        let acceptMore = max(0, Int(JSONLossless.int64(data["acceptMore"]) ?? 0))
        let rejectMore = max(0, Int(JSONLossless.int64(data["rejectMore"]) ?? 0))
        return (acceptRaw, rejectRaw, acceptTotal, rejectTotal, acceptMore, rejectMore)
    }

    internal func buildReminderResponders(from responseDict: [String: Any]) -> ReminderResponders? {
        guard let buckets = extractResponderBuckets(from: responseDict) else { return nil }
        let myUid = ZaloWireParser.stripUserPrefix(profile?.userId ?? "")

        func enrich(_ entries: [(uid: String, name: String, avatar: String)]) -> [[String: Any]] {
            entries.map { entry in
                let isMe = !myUid.isEmpty && entry.uid == myUid
                let local = lookupPersonInfo(entry.uid)
                let resolvedName: String = {
                    if let n = local?.name, !n.isEmpty { return n }
                    if !entry.name.isEmpty { return entry.name }
                    return isMe ? "Bạn" : "Người dùng Zalo"
                }()
                let resolvedAvatar: String = {
                    if let a = local?.avatar, !a.isEmpty { return a }
                    return entry.avatar
                }()
                return [
                    "uid": entry.uid,
                    "name": resolvedName,
                    "avatar": resolvedAvatar,
                    "isMe": isMe
                ]
            }
        }

        return ReminderResponders(json: [
            "ok": true,
            "accept": enrich(buckets.accept),
            "reject": enrich(buckets.reject),
            "acceptTotal": buckets.acceptTotal,
            "rejectTotal": buckets.rejectTotal,
            "acceptMore": buckets.acceptMore,
            "rejectMore": buckets.rejectMore
        ])
    }

    func reminderResponders(in conversationId: String, message messageId: String) async -> ReminderResponders? {
        let eventId = resolveReminderId(in: conversationId, messageId: messageId)
        guard !eventId.isEmpty,
              let box = try? await sessionClient.fetchReminderRespondersAPI(reminderId: eventId) else {
            return nil
        }
        if let buckets = extractResponderBuckets(from: box.dict) {
            let allEntries = buckets.accept + buckets.reject
            let missingUids = Array(Set(allEntries.compactMap { entry -> String? in
                guard lookupPersonInfo(entry.uid) == nil, entry.name.isEmpty else { return nil }
                return entry.uid
            })).prefix(50)
            if !missingUids.isEmpty, await sessionClient.isAuthenticated,
               let profBox = try? await sessionClient.fetchProfiles(uids: Array(missingUids)) {
                var nextProfiles = cachedProfiles
                for (uid, row) in ZaloWireParser.extractProfilesMap(profBox.dict) {
                    let clean = ZaloWireParser.stripUserPrefix(uid)
                    let name = ZaloWireParser.preferredName(row)
                    let avatar = JSONLossless.string(row["avatar"] ?? row["avt"])
                    if !clean.isEmpty, (!name.isEmpty || !avatar.isEmpty) {
                        nextProfiles[clean] = ZaloWebKitMigrator.CachedProfile(name: name, avatar: avatar)
                    }
                }
                if nextProfiles != cachedProfiles {
                    cachedProfiles = nextProfiles
                }
            }
        }
        return buildReminderResponders(from: box.dict)
    }
}

/// How the add-friend form was reached; it decides which request source the official client records (card-actions-adapter.js).
enum FriendRequestOrigin: String, Sendable {
    /// The contact card's KẾT BẠN (`_onAddFriend`).
    case add
    /// The profile opened by tapping the card (`_showUserInfo` with the e-card source).
    case card
    /// A profile action (`action.open.profile`): no source is recorded.
    case none
}

/// A JSON value from the page, handed back from a timed call (read once on the main actor).
struct JSBox: @unchecked Sendable { let value: Any? }

/// Result of a call that may never answer; nil = the time ran out (the late answer is dropped).
private final class OnceGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }
    func resume(_ value: T?) {
        lock.lock()
        let next = continuation
        continuation = nil
        lock.unlock()
        next?.resume(returning: value)
    }
}

/// Runs `operation`; if it has not answered after `seconds`, returns nil and ignores its late answer.
@MainActor
func raceTimeout<T: Sendable>(_ seconds: Double, _ operation: @escaping @MainActor () async -> T) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let gate = OnceGate(continuation)
        Task { @MainActor in gate.resume(await operation()) }
        Task { try? await Task.sleep(for: .seconds(seconds)); gate.resume(nil) }
    }
}

extension CardActionOutcome {
    /// Status word for the log (never the message text).
    var logName: String {
        switch self {
        case .done: "done"
        case .openChat: "openChat"
        case .openProfile: "openProfile"
        case .openURL: "openURL"
        case .copy: "copy"
        case .present: "present"
        case .unsupported: "unsupported"
        case .locked: "locked"
        case .failed: "failed"
        case .pending: "pending"
        }
    }
}
