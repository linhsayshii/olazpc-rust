import CryptoKit
import Foundation

// Native conversation context-menu actions: pin / unpin, "Khác" / "Ưu tiên", mark read / unread, hide / unhide, delete.
// Backed by Zalo Web APIs + SQLite3 local state. Conversation ids, names and PINs never go to the log.

/// Per-conversation facts of the official menu (`render()`); the bit values are the adapter's `F` table.
struct ConversationActionFlags: OptionSet, Sendable {
    let rawValue: Int
    static let pinned = ConversationActionFlags(rawValue: 1)
    static let archived = ConversationActionFlags(rawValue: 2)
    static let hidden = ConversationActionFlags(rawValue: 4)
    /// Not pinnable: no last message, a stranger, an OA that cannot be pinned, or hidden.
    static let cannotPin = ConversationActionFlags(rawValue: 8)
    static let cannotArchive = ConversationActionFlags(rawValue: 16)
    static let cannotMute = ConversationActionFlags(rawValue: 32)
    /// My Cloud (`CONVERSATION_TYPE.CLOUD`).
    static let cannotDelete = ConversationActionFlags(rawValue: 64)
    /// Archived ("Khác") conversation while pinning there is off (`pin_setting.enablePinOther`): neither pin nor unpin is offered.
    static let noPinMenu = ConversationActionFlags(rawValue: 128)
    static let cannotHide = ConversationActionFlags(rawValue: 256)
    static let unreadMark = ConversationActionFlags(rawValue: 512)
}

/// Why a group no longer lists its menu (official `getLeaveType`): only "Xóa hội thoại" is offered.
enum ConversationLeaveType: String, Sendable { case kick, disband }

/// Which official menu is shown: the sidebar row (`Thread`) or the chat header (`ChatBox`, which has no archive, mark-read or delete).
enum ConversationMenuPreset: Sendable { case thread, chatBox }

/// What the official menu offers for one conversation, in official order.
struct ConversationMenuPlan: Equatable {
    enum Pin: Equatable { case pin, unpin }
    enum Archive: Equatable { case moveToOther, moveToFocus }
    enum Read: Equatable { case markRead, markUnread }
    enum Mute: Equatable { case mute, unmute }
    enum Hide: Equatable { case hide, unhide }

    var pin: Pin?
    var archive: Archive?
    var read: Read?
    var mute: Mute?
    var hide: Hide?
    var canDelete = false
    /// "Phân loại" (official `showLabel`).
    var showsLabel = false

    var isEmpty: Bool { pin == nil && archive == nil && read == nil && mute == nil && hide == nil && !canDelete && !showsLabel }

    /// - Parameters:
    ///   - unread: unread message count of the conversation (`smsUnreadCount`).
    ///   - muted: notifications are off for it.
    static func make(id: String, preset: ConversationMenuPreset, state: ConversationActionsState, unread: Int, muted: Bool) -> ConversationMenuPlan {
        let flags = state.flags(for: id)
        var plan = ConversationMenuPlan()
        let isSelf = flags.contains(.cannotDelete)   // My Cloud: the only conversation that can't be deleted
        let thread = preset == .thread

        // A group I was removed from / that was disbanded: ONLY delete (`n&&(i=[],…)`).
        if state.left[id] != nil {
            plan.canDelete = thread && !flags.contains(.cannotDelete)
            return plan
        }

        if !flags.contains(.noPinMenu) {
            if flags.contains(.pinned) { plan.pin = .unpin } else if !flags.contains(.cannotPin) { plan.pin = .pin }
        }
        // `showArchiveChatAction` is only passed by the sidebar list; the item needs the "3" list layout and the feature on.
        if thread, !flags.contains(.cannotArchive) {
            plan.archive = flags.contains(.archived) ? .moveToFocus : .moveToOther
        }
        plan.showsLabel = true
        // Mark read / unread: not for hidden chats nor My Cloud; "đã đọc" when there is something unread or a manual mark.
        if thread, !flags.contains(.hidden), !isSelf {
            if unread > 0 || flags.contains(.unreadMark) { plan.read = .markRead } else if state.markUnreadEnabled { plan.read = .markUnread }
        }
        if muted { plan.mute = .unmute } else if !flags.contains(.cannotMute) { plan.mute = .mute }
        if state.hiddenEnabled {
            if flags.contains(.hidden) { plan.hide = .unhide } else if !flags.contains(.cannotHide) { plan.hide = .hide }
        }
        plan.canDelete = thread && !flags.contains(.cannotDelete)
        return plan
    }
}

/// Mirror of the adapter's snapshot (rebuilt only when the page's data changes; toasts and unlocks live in `ConversationActionUI`).
struct ConversationActionsState: Equatable {
    /// The full snapshot has arrived (flags, leave types).
    var loaded = false
    /// The hidden-chat part has arrived. It is published before everything else: until then the list must not be shown, because any
    /// conversation could still turn out to be hidden.
    var hiddenKnown = false
    var flags: [String: ConversationActionFlags] = [:]
    var left: [String: ConversationLeaveType] = [:]
    var hiddenEnabled = false
    var hasHiddenPIN = false
    var hiddenIds: Set<String> = []
    var markUnreadEnabled = false
    /// Last `late` outcome (an archive / delete that answered "pending") already shown: the page's epoch and the sequence within it.
    var lateEpoch: Int64 = 0
    var lateSeq = 0

    func flags(for id: String) -> ConversationActionFlags { flags[id] ?? [] }
    func isPinned(_ id: String) -> Bool { flags(for: id).contains(.pinned) }
    func isHidden(_ id: String) -> Bool { hiddenIds.contains(id) || flags(for: id).contains(.hidden) }
    func hasUnreadMark(_ id: String) -> Bool { flags(for: id).contains(.unreadMark) }

    /// Applies a `convActions` payload (the early `{hidden}` shape or the full snapshot).
    mutating func apply(json: [String: Any]) {
        if let hidden = json["hidden"] as? [String: Any] {
            hiddenKnown = true
            hiddenEnabled = (hidden["enabled"] as? NSNumber)?.boolValue ?? false
            hasHiddenPIN = (hidden["hasPin"] as? NSNumber)?.boolValue ?? false
            hiddenIds = Set(hidden["ids"] as? [String] ?? [])
        }
        guard let rawFlags = json["flags"] as? [String: Any] else { return }
        loaded = true
        var next: [String: ConversationActionFlags] = [:]
        for (id, value) in rawFlags {
            if let bits = (value as? NSNumber)?.intValue, bits != 0 { next[id] = ConversationActionFlags(rawValue: bits) }
        }
        flags = next
        var leaves: [String: ConversationLeaveType] = [:]
        for (id, value) in json["left"] as? [String: Any] ?? [:] {
            leaves[id] = (value as? String).flatMap(ConversationLeaveType.init(rawValue:)) ?? .kick
        }
        left = leaves
        markUnreadEnabled = (json["markUnread"] as? NSNumber)?.boolValue ?? false
    }
}

/// Client-side state of the actions: toast, removals, the single hidden conversation unlocked with the PIN. Kept out of
/// `ConversationActionsState` so a toast never re-renders the sidebar list.
@MainActor @Observable
final class ConversationActionUI {
    struct Toast: Equatable, Sendable {
        enum Kind: Sendable { case success, neutral, failure }
        let seq: Int
        let kind: Kind
        let text: String
    }

    /// Conversations that left the list (deleted / hidden): the shell clears the selection when it was one of them.
    struct Removal: Equatable, Sendable {
        let seq: Int
        let ids: Set<String>
    }

    private(set) var toast: Toast?
    private(set) var removal: Removal?
    /// The one hidden conversation opened with the PIN (official `byPassPIN` applies to the opened item only).
    private(set) var unlockedId: String?
    /// Hidden conversations listed by the current PIN search; selecting one unlocks just that one.
    private(set) var pinSearchIds: [String] = []
    private var seq = 0

    func show(_ kind: Toast.Kind, _ text: String) { seq += 1; toast = Toast(seq: seq, kind: kind, text: text) }
    func remove(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        seq += 1; removal = Removal(seq: seq, ids: ids)
        if let unlockedId, ids.contains(unlockedId) { self.unlockedId = nil }
    }
    func unlock(_ id: String) { unlockedId = id }
    func isUnlocked(_ id: String) -> Bool { unlockedId == id }
    func setPinSearch(_ ids: [String]) { if ids != pinSearchIds { pinSearchIds = ids } }
    /// The selection moved to another conversation.
    func dropUnlock() { unlockedId = nil }
    /// Search cleared, app resigned active, PIN reset, logout.
    func relock() { unlockedId = nil; if !pinSearchIds.isEmpty { pinSearchIds = [] } }
    func reset() { relock(); toast = nil; removal = nil }
}

/// Result of an adapter action; `text` is the official toast text.
struct ConversationActionResult: Equatable, Sendable {
    var ok: Bool
    var text: String
    /// Pin refused because the tab is full: the official client opens the "Ghim hội thoại" board instead.
    var full = false
    /// Wrong hidden-chat PIN (`STR_ERROR_POPUP_HIDDEN_ENTER_PIN_INCORRECT`).
    var badPIN = false
    /// A PIN is already set (the caller's view was stale): refused, nothing was changed.
    var pinExists = false
    /// The official client shows this one as a plain message, not a success toast ("Đã chuyển sang mục Khác").
    var neutral = false

    init(ok: Bool, text: String, full: Bool = false, badPIN: Bool = false, pinExists: Bool = false, neutral: Bool = false) {
        self.ok = ok; self.text = text; self.full = full; self.badPIN = badPIN; self.pinExists = pinExists; self.neutral = neutral
    }

    /// Parses the adapter's `{ok, text, full?, badPin?}`; no answer / bad shape is a failure with a plain text.
    init(json: Any?) {
        guard let root = json as? [String: Any], let ok = root["ok"] as? Bool else {
            self.init(ok: false, text: "Chưa nhận được phản hồi. Hãy kiểm tra lại trước khi thử lại.")
            return
        }
        self.init(ok: ok, text: String((root["text"] as? String ?? "").prefix(300)),
                  full: (root["full"] as? Bool) ?? false, badPIN: (root["badPin"] as? Bool) ?? false,
                  pinExists: (root["pinExists"] as? Bool) ?? false, neutral: (root["neutral"] as? Bool) ?? false)
    }
}

/// The full-board dialog of the official client (`POP_PINNED_CONVERSATION`).
struct PinBoard: Equatable, Sendable {
    let tab: Int
    let limit: Int
    let total: Int
    /// How many pins must go before a new one fits (`STR_POPUP_PLEASE_UNPIN`).
    let need: Int
    /// Pinned conversation ids, newest first.
    let items: [String]

    init?(json: Any?) {
        guard let root = json as? [String: Any], let limit = (root["limit"] as? NSNumber)?.intValue, limit > 0 else { return nil }
        tab = (root["tab"] as? NSNumber)?.intValue ?? 0
        self.limit = limit
        total = (root["total"] as? NSNumber)?.intValue ?? 0
        need = (root["need"] as? NSNumber)?.intValue ?? 0
        items = root["items"] as? [String] ?? []
    }

    init(tab: Int, limit: Int, total: Int, need: Int, items: [String]) {
        self.tab = tab; self.limit = limit; self.total = total; self.need = need; self.items = items
    }

    /// The confirm button is enabled once the chosen removals free a slot (`isChanged`).
    func freesSlot(removing count: Int) -> Bool { items.count - count < limit }
}

/// A dialog / sheet a conversation action asks the shell to show.
enum ConversationPrompt: Identifiable, Equatable {
    case delete(id: String)
    case pinBoard(id: String)
    case hide(id: String)
    case unhide(id: String)
    /// Open a hidden conversation (official OPEN_CONV screen).
    case unlock(id: String)

    var id: String {
        switch self {
        case .delete(let id): "delete-\(id)"
        case .pinBoard(let id): "pin-\(id)"
        case .hide(let id): "hide-\(id)"
        case .unhide(let id): "unhide-\(id)"
        case .unlock(let id): "unlock-\(id)"
        }
    }
}

/// Timing rules of the hidden-chat lock (pure, unit tested).
enum HiddenStateGuard {
    /// Waiting for the page's hidden-chat state longer than this shows the explicit "can't read" message instead of the spinner.
    static let stallLimit: TimeInterval = 30
    /// The PIN bypass ends after the app was inactive this long (checked when it becomes active again).
    static let relockAfterInactivity: TimeInterval = 60

    static func isStalled(waitingSince: Date?, now: Date = .now) -> Bool {
        guard let waitingSince else { return false }
        return now.timeIntervalSince(waitingSince) >= stallLimit
    }

    /// A short focus loss (the ZaloCall helper window taking focus, a system dialog) must not relock.
    static func shouldRelock(inactiveFor seconds: TimeInterval) -> Bool { seconds >= relockAfterInactivity }

    static let stalledMessage = "Không đọc được trạng thái trò chuyện ẩn — đang thử lại"
}

/// Official texts of the delete confirmation (`STR_CONV_DEL_CONFIRM_L_1/_L_2`, `STR_CONFIRM_YES`, `STR_CONFIRM_NO`);
/// the alert takes line 1 as its title and line 2 as its message.
enum ConversationActionText {
    static let deleteLine1 = "Toàn bộ nội dung trò chuyện sẽ bị xóa vĩnh viễn."
    static let deleteLine2 = "Bạn có chắc chắn muốn xóa?"
    static let deleteConfirm = "Xóa"
    static let deleteCancel = "Không"
}

extension ZaloEngine {
    // MARK: Pin

    func pinConversation(_ id: String) {
        Task { [weak self] in
            guard let self else { return }
            let pinnedCount = cachedPinnedIds.count
            if !cachedPinnedIds.contains(id), pinnedCount >= 10 {
                conversationPrompt = .pinBoard(id: id)
                return
            }
            do {
                try await sessionClient.updatePinnedConversation(convId: id, pinned: true)
                cachedPinnedIds.insert(id)
                applyPinStatus(id: id, pinned: true)
                try? await sqliteStore?.setPreferenceStrings(key: "pinnedIds", value: Array(cachedPinnedIds))
                try? await sqliteStore?.setConversationPinned(id: id, pinned: true)
                report(ConversationActionResult(ok: true, text: "Đã ghim hội thoại"))
            } catch {
                report(ConversationActionResult(ok: false, text: "Ghim hội thoại không thành công."))
            }
        }
    }

    func unpinConversation(_ id: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await sessionClient.updatePinnedConversation(convId: id, pinned: false)
                cachedPinnedIds.remove(id)
                applyPinStatus(id: id, pinned: false)
                try? await sqliteStore?.setPreferenceStrings(key: "pinnedIds", value: Array(cachedPinnedIds))
                try? await sqliteStore?.setConversationPinned(id: id, pinned: false)
                report(ConversationActionResult(ok: true, text: "Đã bỏ ghim hội thoại"))
            } catch {
                report(ConversationActionResult(ok: false, text: "Bỏ ghim không thành công."))
            }
        }
    }

    private func applyPinStatus(id: String, pinned: Bool) {
        var list = conversations
        if let idx = list.firstIndex(where: { $0.id == id }) {
            list[idx].pinned = pinned
        }
        sortConversations(&list)
        conversations = list
        rebuildConversationFlags()
        rebuildConversationExtras()
    }

    func pinBoard(for id: String) async -> PinBoard? {
        let items = conversations.filter { cachedPinnedIds.contains($0.id) || $0.pinned }.map(\.id)
        let limit = 10
        let need = max(1, items.count - limit + 1)
        return PinBoard(tab: 0, limit: limit, total: items.count, need: need, items: items)
    }

    func pinReplacing(_ unpinIds: [String], pinning id: String) async -> ConversationActionResult {
        do {
            for old in unpinIds {
                try await sessionClient.updatePinnedConversation(convId: old, pinned: false)
                cachedPinnedIds.remove(old)
                applyPinStatus(id: old, pinned: false)
                try? await sqliteStore?.setConversationPinned(id: old, pinned: false)
            }
            try await sessionClient.updatePinnedConversation(convId: id, pinned: true)
            cachedPinnedIds.insert(id)
            applyPinStatus(id: id, pinned: true)
            try? await sqliteStore?.setPreferenceStrings(key: "pinnedIds", value: Array(cachedPinnedIds))
            try? await sqliteStore?.setConversationPinned(id: id, pinned: true)
            let res = ConversationActionResult(ok: true, text: "Đã ghim hội thoại")
            report(res)
            return res
        } catch {
            let res = ConversationActionResult(ok: false, text: "Ghim hội thoại không thành công.")
            report(res)
            return res
        }
    }

    // MARK: Archive

    func moveConversation(_ id: String, toOther: Bool) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await sessionClient.updateArchivedChat(convId: id, archived: toOther)
                if toOther { cachedArchivedIds.insert(id) } else { cachedArchivedIds.remove(id) }
                try? await sqliteStore?.setPreferenceStrings(key: "archivedIds", value: Array(cachedArchivedIds))
                rebuildConversationFlags()
                rebuildConversationExtras()
                let text = toOther ? "Đã chuyển sang mục Khác" : "Đã chuyển về Hộp thư đến"
                report(ConversationActionResult(ok: true, text: text, neutral: toOther))
            } catch {
                report(ConversationActionResult(ok: false, text: "Không thể chuyển cuộc trò chuyện."))
            }
        }
    }

    // MARK: Delete

    func requestDeleteConversation(_ id: String) {
        conversationPrompt = .delete(id: id)
    }

    func confirmDeleteConversation(_ id: String) {
        let lastCliId = messages[id]?.last?.id ?? ""
        Task { [weak self] in
            guard let self else { return }
            await sessionClient.deleteConversationAPI(convId: id, lastCliMsgId: lastCliId)
            try? await sqliteStore?.deleteConversation(id: id)
            conversations.removeAll { $0.id == id }
            messages[id] = nil
            cachedPinnedIds.remove(id)
            cachedArchivedIds.remove(id)
            cachedUnreadMarks.remove(id)
            conversationUI.remove([id])
            rebuildConversationFlags()
            rebuildConversationExtras()
            report(ConversationActionResult(ok: true, text: "Đã xóa hội thoại"))
        }
    }

    // MARK: Read / unread

    func markConversationRead(_ id: String) {
        markRead(id)
    }

    func markConversationUnread(_ id: String) {
        cachedUnreadMarks.insert(id)
        rebuildConversationFlags()
        rebuildConversationExtras()
        Task {
            try? await sqliteStore?.setPreferenceStrings(key: "unreadMarks", value: Array(cachedUnreadMarks))
            try? await sessionClient.setUnreadMarkAPI(convId: id, unread: true)
        }
    }

    // MARK: Hidden chats (server MD5 PIN sync + local SHA-256 fallback + SQLite)

    private static func hashPIN(_ pin: String) -> String {
        let digest = SHA256.hash(data: Data("olaz-hidden-pin:\(pin)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func storedHiddenPinDigests() async -> (md5: String?, sha256: String?) {
        if let store = sqliteStore {
            let md5 = try? await store.getPreferenceString(key: "hiddenPinMD5")
            let sha = try? await store.getPreferenceString(key: "hiddenPinHash")
            return (
                md5?.isEmpty == false ? md5 : nil,
                sha?.isEmpty == false ? sha : nil
            )
        }
        return (
            cachedHiddenPinMD5?.isEmpty == false ? cachedHiddenPinMD5 : nil,
            cachedHiddenPinHash?.isEmpty == false ? cachedHiddenPinHash : nil
        )
    }

    func syncHiddenConversations() async {
        guard await sessionClient.isAuthenticated else { return }
        guard let snap = try? await sessionClient.fetchHiddenConversationsAPI() else { return }
        await applyServerHiddenConversations(snap)
    }

    internal func applyServerHiddenConversations(_ snap: HiddenConversationsSnapshot) async {
        let serverPin = snap.pin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let serverHiddenIds = Set(snap.threadIds.filter { !$0.isEmpty && $0 != selfConversationId })
        let oldHiddenIds = conversationActions.hiddenIds

        if !serverPin.isEmpty {
            let prevMD5 = (try? await sqliteStore?.getPreferenceString(key: "hiddenPinMD5")) ?? cachedHiddenPinMD5
            if prevMD5?.lowercased() != serverPin {
                cachedHiddenPinHash = nil
                try? await sqliteStore?.deletePreference(key: "hiddenPinHash")
            }
            cachedHiddenPinMD5 = serverPin
            try? await sqliteStore?.setPreferenceString(key: "hiddenPinMD5", value: serverPin)
        } else {
            cachedHiddenPinMD5 = nil
            cachedHiddenPinHash = nil
            try? await sqliteStore?.deletePreference(key: "hiddenPinMD5")
            try? await sqliteStore?.deletePreference(key: "hiddenPinHash")
        }
        try? await sqliteStore?.setPreferenceStrings(key: "hiddenIds", value: Array(serverHiddenIds))

        var next = conversationActions
        next.hiddenKnown = true
        next.hiddenEnabled = true
        next.hasHiddenPIN = !serverPin.isEmpty
        next.hiddenIds = serverHiddenIds
        conversationActions = next

        let newlyHidden = serverHiddenIds.subtracting(oldHiddenIds)
        if !newlyHidden.isEmpty {
            conversationUI.remove(newlyHidden)
        }
        rebuildConversationFlags()
        rebuildConversationExtras()
    }

    func checkHiddenChatPIN(_ pin: String) async -> Bool {
        let digests = await storedHiddenPinDigests()
        if let md5Stored = digests.md5 {
            return ZaloSessionClient.hiddenPinMD5Hex(pin) == md5Stored.lowercased()
        }
        if let shaStored = digests.sha256 {
            return Self.hashPIN(pin) == shaStored
        }
        return false
    }

    func hideConversation(_ id: String, pin: String) async -> ConversationActionResult {
        guard await checkHiddenChatPIN(pin) else {
            return ConversationActionResult(ok: false, text: "Mã PIN không đúng.", badPIN: true)
        }
        conversationActions.hiddenIds.insert(id)
        try? await sqliteStore?.setPreferenceStrings(key: "hiddenIds", value: Array(conversationActions.hiddenIds))
        await sessionClient.setHiddenConversationAPI(convId: id, hidden: true)
        conversationUI.remove([id])
        rebuildConversationFlags()
        rebuildConversationExtras()
        return ConversationActionResult(ok: true, text: "Đã ẩn trò chuyện")
    }

    private func syncAndPersistHiddenPin(_ pin: String) async -> Bool {
        if await sessionClient.isAuthenticated {
            do {
                _ = try await sessionClient.updateHiddenPinAPI(pin: pin)
            } catch {
                return false
            }
            let md5 = ZaloSessionClient.hiddenPinMD5Hex(pin)
            cachedHiddenPinMD5 = md5
            try? await sqliteStore?.setPreferenceString(key: "hiddenPinMD5", value: md5)
        }
        let hash = Self.hashPIN(pin)
        cachedHiddenPinHash = hash
        try? await sqliteStore?.setPreferenceString(key: "hiddenPinHash", value: hash)
        conversationActions.hasHiddenPIN = true
        return true
    }

    func hideConversation(_ id: String, settingNewPIN pin: String) async -> ConversationActionResult {
        let existing = await storedHiddenPinDigests()
        if conversationActions.hasHiddenPIN || existing.md5 != nil || existing.sha256 != nil {
            conversationActions.hasHiddenPIN = true
            return ConversationActionResult(ok: false, text: "Mã PIN đã được thiết lập trước đó.", pinExists: true)
        }
        guard await syncAndPersistHiddenPin(pin) else {
            return ConversationActionResult(ok: false, text: "Không thể cài mã PIN trò chuyện ẩn.")
        }
        conversationActions.hiddenIds.insert(id)
        try? await sqliteStore?.setPreferenceStrings(key: "hiddenIds", value: Array(conversationActions.hiddenIds))
        await sessionClient.setHiddenConversationAPI(convId: id, hidden: true)
        conversationUI.remove([id])
        rebuildConversationFlags()
        rebuildConversationExtras()
        return ConversationActionResult(ok: true, text: "Đã ẩn trò chuyện")
    }

    func unhideConversation(_ id: String, pin: String?) async -> ConversationActionResult {
        if let pin, !(await checkHiddenChatPIN(pin)) {
            return ConversationActionResult(ok: false, text: "Mã PIN không đúng.", badPIN: true)
        }
        conversationActions.hiddenIds.remove(id)
        try? await sqliteStore?.setPreferenceStrings(key: "hiddenIds", value: Array(conversationActions.hiddenIds))
        await sessionClient.setHiddenConversationAPI(convId: id, hidden: false)
        rebuildConversationFlags()
        rebuildConversationExtras()
        return ConversationActionResult(ok: true, text: "Đã bỏ ẩn trò chuyện")
    }

    func setHiddenChatPIN(_ pin: String, changed: Bool) async -> ConversationActionResult {
        guard await syncAndPersistHiddenPin(pin) else {
            return ConversationActionResult(ok: false, text: changed ? "Không thể đổi mã PIN." : "Không thể cài mã PIN.")
        }
        rebuildConversationFlags()
        rebuildConversationExtras()
        return ConversationActionResult(ok: true, text: changed ? "Đã đổi mã PIN" : "Đã cài mã PIN")
    }

    func resetHiddenChatPIN() async -> ConversationActionResult {
        if await sessionClient.isAuthenticated {
            do {
                _ = try await sessionClient.resetHiddenPinAPI()
            } catch {
                return ConversationActionResult(ok: false, text: "Không thể xóa mã PIN.")
            }
        }
        let formerlyHidden = conversationActions.hiddenIds
        conversationActions.hiddenIds.removeAll()
        conversationActions.hasHiddenPIN = false
        cachedHiddenPinHash = nil
        cachedHiddenPinMD5 = nil
        try? await sqliteStore?.deletePreference(key: "hiddenPinHash")
        try? await sqliteStore?.deletePreference(key: "hiddenPinMD5")
        try? await sqliteStore?.setPreferenceStrings(key: "hiddenIds", value: [])
        conversationUI.remove(formerlyHidden)
        conversationUI.relock()
        rebuildConversationFlags()
        rebuildConversationExtras()
        return ConversationActionResult(ok: true, text: "Đã xóa mã PIN")
    }

    func hiddenConversations(matching query: String) async -> [String]? {
        guard conversationActions.hiddenEnabled, query.count == 4, await checkHiddenChatPIN(query) else {
            conversationUI.setPinSearch([])
            return nil
        }
        let ids = Array(conversationActions.hiddenIds)
        conversationUI.setPinSearch(ids)
        return ids
    }

    func isConversationLocked(_ id: String) -> Bool {
        conversationActions.isHidden(id) && !conversationUI.isUnlocked(id)
    }

    func unlockFromPINSearch(_ id: String) -> Bool {
        guard conversationUI.pinSearchIds.contains(id) else { return false }
        conversationUI.unlock(id)
        return true
    }

    func unlockHiddenConversation(_ id: String) { conversationUI.unlock(id) }

    // MARK: Hidden chats elsewhere in the app

    var visibleFriends: [ContactsState.Friend] {
        conversationActions.hiddenKnown ? contacts.friends.filter { !conversationActions.isHidden($0.id) } : []
    }

    var visibleGroups: [ContactsState.Group] {
        conversationActions.hiddenKnown ? contacts.groups.filter { !conversationActions.isHidden($0.id) } : []
    }

    var visibleConversations: [ConversationSummary] {
        conversationActions.hiddenKnown ? conversations.filter { !conversationActions.isHidden($0.id) } : []
    }

    // MARK: Feedback

    func report(_ result: ConversationActionResult) {
        guard !result.text.isEmpty, !result.full, !result.pinExists else { return }
        conversationUI.show(result.ok ? (result.neutral ? .neutral : .success) : .failure, result.text)
    }

    func resetConversationActions() {
        conversationActions = ConversationActionsState()
        conversationPrompt = nil
        cachedHiddenPinHash = nil
        cachedHiddenPinMD5 = nil
        conversationUI.reset()
    }

    func republishConversationActions() {
        rebuildConversationFlags()
    }

    internal func rebuildConversationFlags() {
        var next = conversationActions
        next.hiddenKnown = true
        next.loaded = true
        next.hiddenEnabled = true
        next.markUnreadEnabled = true
        var nextFlags: [String: ConversationActionFlags] = [:]
        for c in conversations {
            var f: ConversationActionFlags = []
            if cachedPinnedIds.contains(c.id) || c.pinned { f.insert(.pinned) }
            if cachedArchivedIds.contains(c.id) { f.insert(.archived) }
            if next.hiddenIds.contains(c.id) { f.insert(.hidden) }
            if cachedUnreadMarks.contains(c.id) { f.insert(.unreadMark) }
            if c.id == selfConversationId {
                f.formUnion([.cannotDelete, .cannotHide, .cannotArchive])
            }
            if !f.isEmpty { nextFlags[c.id] = f }
        }
        next.flags = nextFlags
        if next != conversationActions { conversationActions = next }
    }

    var isInCall: Bool { call.busy || call.nativeRunning }

    func handleConversationActions(state: [String: Any]) {
        guard let json = state["convActions"] as? [String: Any] else { return }
        var next = conversationActions
        next.apply(json: json)
        let epoch = (json["epoch"] as? NSNumber)?.int64Value ?? next.lateEpoch
        if epoch != next.lateEpoch { next.lateEpoch = epoch; next.lateSeq = 0 }
        if let late = json["late"] as? [String: Any], let seq = (late["seq"] as? NSNumber)?.intValue, seq > next.lateSeq {
            next.lateSeq = seq
            let text = late["text"] as? String ?? ""
            let ok = late["ok"] as? Bool ?? false
            if !text.isEmpty { conversationUI.show(ok ? ((late["neutral"] as? Bool) == true ? .neutral : .success) : .failure, text) }
            if let removed = late["removedId"] as? String, !removed.isEmpty { conversationUI.remove([removed]) }
        }
        if next != conversationActions { conversationActions = next }
    }
}
