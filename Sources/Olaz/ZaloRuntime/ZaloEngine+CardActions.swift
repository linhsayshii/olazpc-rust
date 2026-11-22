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

    func resetCardState() {}

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
        let clean = ZaloWireParser.stripUserPrefix(uid)
        let isSelf = clean == profile?.userId
        let isFriend = contacts.friends.contains { $0.id == clean }
        return (isSelf, isFriend)
    }

    func contactProfile(_ uid: String) async -> ContactProfile? {
        let clean = ZaloWireParser.stripUserPrefix(uid)
        guard !clean.isEmpty else { return nil }
        if clean == profile?.userId, let p = profile {
            return ContactProfile(uid: clean, name: p.displayName, avatar: p.avatar, isSelf: true, isFriend: false)
        }
        if let f = contacts.friends.first(where: { $0.id == clean }) {
            return ContactProfile(uid: clean, name: f.name, zaloName: f.zaloName, avatar: f.avatar, isSelf: false, isFriend: true)
        }
        if let box = try? await sessionClient.fetchProfiles(uids: [clean]),
           let row = ZaloWireParser.extractProfilesMap(box.dict)[clean] {
            let name = JSONLossless.string(row["displayName"] ?? row["dName"] ?? row["zaloName"] ?? row["name"])
            let zalo = JSONLossless.string(row["zaloName"])
            let avt = JSONLossless.string(row["avatar"] ?? row["avt"])
            return ContactProfile(uid: clean, name: name, zaloName: zalo, avatar: avt.isEmpty ? nil : URL(string: avt))
        }
        return nil
    }

    func prepareFriendRequest(to uid: String, from conversationId: String, via: FriendRequestOrigin) async -> FriendRequestPrep {
        let clean = ZaloWireParser.stripUserPrefix(uid)
        if clean == profile?.userId { return FriendRequestPrep(state: .me) }
        if contacts.friends.contains(where: { $0.id == clean }) { return FriendRequestPrep(state: .friend) }
        if contacts.sent.contains(where: { $0.id == clean }) { return FriendRequestPrep(state: .requested) }
        if contacts.received.contains(where: { $0.id == clean }) { return FriendRequestPrep(state: .requesting) }
        let myName = profile?.displayName ?? "tôi"
        return FriendRequestPrep(state: .ready, defaultMessage: "Xin chào, mình là \(myName).", maxMessage: 150)
    }

    func submitFriendRequest(to uid: String, message: String) async -> (ok: Bool, text: String, pending: Bool) {
        do {
            _ = try await sessionClient.sendFriendRequestAPI(toUid: uid, message: message)
            refreshContacts()
            return (true, "Đã gửi lời mời kết bạn.", false)
        } catch {
            return (false, "Không thể gửi lời mời kết bạn.", false)
        }
    }

    // MARK: Native sheets of card actions

    func saveAlias(uid: String, name: String) async -> (ok: Bool, text: String) {
        let clean = ZaloWireParser.stripUserPrefix(uid)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await sessionClient.setAliasAPI(uid: clean, alias: trimmed)
            if trimmed.isEmpty { cachedAliases.removeValue(forKey: clean) } else { cachedAliases[clean] = trimmed }
            if let data = try? JSONSerialization.data(withJSONObject: cachedAliases) {
                try? await sqliteStore?.setPreferenceData(key: "aliases", data: data)
            }
            return (true, trimmed.isEmpty ? "Đã xóa tên gợi nhớ." : "Đã lưu tên gợi nhớ.")
        } catch {
            return (false, "Không lưu được tên gợi nhớ.")
        }
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

    func reminderWatch(in conversationId: String, message messageId: String, signature: String) async -> ReminderSnapshot? {
        nil
    }

    func respondToReminder(in conversationId: String, message messageId: String, accept: Bool) async -> (ok: Bool, text: String, snapshot: ReminderSnapshot?) {
        do {
            _ = try await sessionClient.respondReminderAPI(convId: conversationId, reminderId: messageId, accept: accept)
            return (true, accept ? "Đã xác nhận tham gia." : "Đã từ chối.", nil)
        } catch {
            return (false, "Không thực hiện được thao tác.", nil)
        }
    }

    func reminderResponders(in conversationId: String, message messageId: String) async -> ReminderResponders? {
        nil
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
