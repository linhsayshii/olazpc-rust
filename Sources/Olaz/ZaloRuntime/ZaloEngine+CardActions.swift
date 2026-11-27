import AppKit
import Foundation
import OlazCore

// Card buttons (e-card actions, suggested stickers, contact card, info-message links, reminder cards), delegated to
// `olaz-core` (U16). Swift retains only UI sheet/navigation views and sticker-category sheet projection.
// Official adapter reference: `HostScripts/card-actions-adapter.js` (`window.__zaloChat.performAction` & co.;
// contract in ChatModels.swift). Requests start only after a click or when a card is shown.
// Message content never goes to the log.
extension ZaloEngine {
    func performCardAction(in conversationId: String, message messageId: String, ref: String) async -> CardActionOutcome {
        guard let core = await ensureCoreEngine() else {
            return .unsupported(CardActionOutcome.defaultUnsupported)
        }
        if let existing = messages[conversationId], !existing.isEmpty {
            core.writeThroughReplaceWindow(convId: conversationId, messages: existing.map(ChatMessageRecord.init(message:)))
        }
        guard let rec = try? await core.performCardAction(
            convId: conversationId,
            msgId: messageId,
            actionRef: ref
        ) else {
            return .unsupported(CardActionOutcome.defaultUnsupported)
        }
        await waitForMirrorVersion(core.currentVersion())
        return Self.mapCardActionOutcomeRecord(rec)
    }

    nonisolated internal static func mapCardActionOutcomeRecord(_ rec: CardActionOutcomeRecord) -> CardActionOutcome {
        CardActionOutcome(coreRecord: rec)
    }

    nonisolated internal static func mapCardActionOutcomeToRecord(_ outcome: CardActionOutcome) -> CardActionOutcomeRecord {
        switch outcome {
        case .done: .done
        case .unsupported(let text): .unsupported(text: text)
        case .locked(let text): .locked(text: text)
        case .failed(let text): .failed(text: text)
        case .pending(let text): .pending(text: text)
        default: .done
        }
    }

    func resetCardState() {
        reminderWatchTimerTasks.values.forEach { $0.cancel() }
        reminderWatchTimerTasks.removeAll()
        coreLifecycle.core?.resetCardState()
    }

    func suggestedStickers(in conversationId: String, message messageId: String) async -> [SuggestedSticker] {
        guard let core = await ensureCoreEngine() else { return [] }
        if let existing = messages[conversationId], !existing.isEmpty {
            core.writeThroughReplaceWindow(convId: conversationId, messages: existing.map(ChatMessageRecord.init(message:)))
        }
        guard let rows = try? await core.suggestedStickers(convId: conversationId, msgId: messageId) else {
            return []
        }
        return rows.compactMap { row in
            guard let url = URL(string: row.url) else { return nil }
            return SuggestedSticker(ref: row.stickerRef, url: url)
        }
    }

    func contactCardState(_ uid: String) async -> (isSelf: Bool, isFriend: Bool) {
        guard let core = await ensureCoreEngine() else {
            let clean = ZaloWireParser.stripUserPrefix(uid)
            return (clean == profile?.userId, contacts.friends.contains { $0.id == clean })
        }
        pushCoreContactsIfRunning()
        guard let res = try? await core.contactCardState(uid: uid) else {
            return (false, false)
        }
        return (res.isSelf, res.isFriend)
    }

    func contactProfile(_ uid: String) async -> ContactProfile? {
        guard let core = await ensureCoreEngine() else { return nil }
        pushCoreIdentitiesIfRunning()
        pushCoreContactsIfRunning()
        guard let rec = try? await core.contactProfile(uid: uid) else { return nil }
        await waitForMirrorVersion(core.currentVersion())
        return ContactProfile(
            uid: rec.uid,
            name: rec.name,
            zaloName: rec.zaloName,
            avatar: rec.avatar.flatMap { $0.isEmpty ? nil : URL(string: $0) },
            bio: rec.bio,
            isSelf: rec.isSelf,
            isFriend: rec.isFriend,
            isOfficialAccount: rec.isOa
        )
    }

    func prepareFriendRequest(to uid: String, from conversationId: String, via: FriendRequestOrigin) async -> FriendRequestPrep {
        guard let core = await ensureCoreEngine() else { return FriendRequestPrep(state: .error) }
        pushCoreContactsIfRunning()
        let viaRec: FriendRequestOriginRecord = switch via {
        case .add: .add
        case .card: .card
        case .none: .none
        }
        guard let rec = try? await core.prepareFriendRequest(uid: uid, convId: conversationId, via: viaRec) else {
            return FriendRequestPrep(state: .error)
        }
        let state = FriendRequestPrep.State(rawValue: rec.state) ?? .error
        let limit = max(1, min(Int(rec.maxMessage), 500))
        return FriendRequestPrep(state: state, defaultMessage: rec.defaultMessage, maxMessage: limit)
    }

    func submitFriendRequest(to uid: String, message: String) async -> (ok: Bool, text: String, pending: Bool) {
        guard let core = await ensureCoreEngine() else {
            return (false, "Không thể gửi lời mời kết bạn.", false)
        }
        guard let rec = try? await core.submitFriendRequest(uid: uid, message: message) else {
            return (false, "Không thể gửi lời mời kết bạn.", false)
        }
        await waitForMirrorVersion(core.currentVersion())
        return (rec.ok, rec.text, rec.pending)
    }

    // MARK: Native sheets of card actions

    func saveAlias(uid: String, name: String) async -> (ok: Bool, text: String) {
        guard let core = await ensureCoreEngine() else {
            return (false, "Không lưu được tên gợi nhớ.")
        }
        guard let rec = try? await core.saveAlias(uid: uid, name: name) else {
            return (false, "Không lưu được tên gợi nhớ.")
        }
        await waitForMirrorVersion(core.currentVersion())
        return (rec.ok, rec.text)
    }

    func groupInvitePreview(_ url: URL) async -> GroupInvitePreview {
        guard let core = await ensureCoreEngine() else { return GroupInvitePreview() }
        pushCoreContactsIfRunning()
        guard let rec = try? await core.groupInvitePreview(url: url.absoluteString) else {
            return GroupInvitePreview()
        }
        switch rec.state {
        case "member":
            return GroupInvitePreview(json: ["state": "member", "groupId": rec.groupId])
        case "preview":
            let members: [[String: Any]] = rec.members.map { m in
                var row: [String: Any] = ["id": m.id, "name": m.name, "admin": m.admin]
                if let av = m.avatar, !av.isEmpty { row["avatar"] = av }
                return row
            }
            return GroupInvitePreview(json: [
                "state": "preview",
                "groupId": rec.groupId,
                "name": rec.name,
                "avatar": rec.avatar ?? "",
                "totalMember": Int(rec.totalMember),
                "desc": rec.desc,
                "community": rec.community,
                "creatorName": rec.creatorName,
                "members": members,
            ])
        default:
            if rec.text.isEmpty { return GroupInvitePreview() }
            return GroupInvitePreview(json: ["state": "error", "text": rec.text])
        }
    }

    func joinGroup(_ url: URL, previewGroupId: String? = nil) async -> GroupJoinResult {
        guard let core = await ensureCoreEngine() else {
            return GroupJoinResult(state: .error, text: "Vào nhóm không thành công.")
        }
        guard let rec = try? await core.joinGroup(url: url.absoluteString, previewGroupId: previewGroupId) else {
            return GroupJoinResult(state: .error, text: "Vào nhóm không thành công.")
        }
        await waitForMirrorVersion(core.currentVersion())
        let state: GroupJoinResult.State = switch rec.state {
        case "joined": .joined
        case "already": .already
        case "pending": .pending
        default: .error
        }
        return GroupJoinResult(state: state, groupId: rec.groupId, text: rec.text)
    }

    func stickerCategory(_ id: Int) async -> StickerCategory? {
        guard let items = await stickers(inTab: id), !items.isEmpty else { return nil }
        let rows: [[String: Any]] = items.map { ["ref": "\(id)_\($0.stickerId)", "url": $0.url.absoluteString] }
        return StickerCategory(json: ["id": id, "name": "Bộ sticker", "icon": "", "stickers": rows])
    }

    func sendCategorySticker(in conversationId: String, category: Int, sticker: Int) async -> CardActionOutcome {
        let urlStr = ZaloWireParser.stickerCDNURL(cateId: category, stickerId: "\(sticker)")
        let entry = StickerEntry(
            cateId: category,
            stickerId: sticker,
            url: URL(string: urlStr)!,
            animation: nil
        )
        return await sendSticker(entry, in: conversationId, source: .category)
    }

    // MARK: Reminders (delegated to `olaz-core`)

    private static func mapReminderSnapshotRecord(_ rec: ReminderSnapshotRecord) -> ReminderSnapshot {
        var snap = ReminderSnapshot()
        snap.variant = ReminderSnapshot.Variant(rawValue: rec.variant) ?? .hidden
        snap.id = rec.id
        snap.title = rec.title
        snap.start = rec.startMs.map { Date(timeIntervalSince1970: Double($0) / 1000.0) }
        snap.repeatLabel = rec.repeatLabel
        snap.creatorName = rec.creatorName
        snap.onlyMe = rec.onlyMe
        snap.isGroup = rec.isGroup
        snap.mine = ReminderSnapshot.Answer(rawValue: rec.mine)
        snap.acceptedCount = Int(rec.acceptedCount)
        snap.rejectedCount = Int(rec.rejectedCount)
        snap.canRsvp = rec.canRsvp
        snap.canView = rec.canView
        snap.deleted = rec.deleted
        snap.sig = rec.sig
        return snap
    }

    func reminderWatch(in conversationId: String, message messageId: String, signature: String) async -> ReminderSnapshot? {
        guard let core = await ensureCoreEngine() else { return nil }
        pushCoreIdentitiesIfRunning()
        pushCoreContactsIfRunning()
        pushCorePinsIfRunning(for: conversationId)
        if let existing = messages[conversationId], !existing.isEmpty {
            core.writeThroughReplaceWindow(convId: conversationId, messages: existing.map(ChatMessageRecord.init(message:)))
        }
        guard let rec = try? await core.reminderWatch(
            convId: conversationId,
            msgId: messageId,
            signature: signature
        ) else {
            return nil
        }
        return Self.mapReminderSnapshotRecord(rec)
    }

    func respondToReminder(in conversationId: String, message messageId: String, accept: Bool) async -> (ok: Bool, text: String, snapshot: ReminderSnapshot?) {
        guard let core = await ensureCoreEngine() else {
            return (false, "Không thực hiện được thao tác.", nil)
        }
        pushCoreIdentitiesIfRunning()
        pushCoreContactsIfRunning()
        pushCorePinsIfRunning(for: conversationId)
        if let existing = messages[conversationId], !existing.isEmpty {
            core.writeThroughReplaceWindow(convId: conversationId, messages: existing.map(ChatMessageRecord.init(message:)))
        }
        guard let rec = try? await core.respondReminder(
            convId: conversationId,
            msgId: messageId,
            accept: accept
        ) else {
            return (false, "Không thực hiện được thao tác.", nil)
        }
        return (rec.ok, rec.text, rec.snapshot.map(Self.mapReminderSnapshotRecord))
    }

    func reminderResponders(in conversationId: String, message messageId: String) async -> ReminderResponders? {
        guard let core = await ensureCoreEngine() else { return nil }
        pushCoreIdentitiesIfRunning()
        pushCoreContactsIfRunning()
        pushCorePinsIfRunning(for: conversationId)
        if let existing = messages[conversationId], !existing.isEmpty {
            core.writeThroughReplaceWindow(convId: conversationId, messages: existing.map(ChatMessageRecord.init(message:)))
        }
        guard let rec = try? await core.reminderResponders(convId: conversationId, msgId: messageId) else {
            return nil
        }
        await waitForMirrorVersion(core.currentVersion())
        let mapPeople: ([ReminderResponderPersonRecord]) -> [[String: Any]] = { list in
            list.map { p in
                [
                    "uid": p.uid,
                    "name": p.name,
                    "avatar": p.avatar ?? "",
                    "isMe": p.isMe,
                ]
            }
        }
        return ReminderResponders(json: [
            "ok": true,
            "accept": mapPeople(rec.accept),
            "reject": mapPeople(rec.reject),
            "acceptTotal": Int(rec.acceptTotal),
            "rejectTotal": Int(rec.rejectTotal),
            "acceptMore": Int(rec.acceptMore),
            "rejectMore": Int(rec.rejectMore),
        ])
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
