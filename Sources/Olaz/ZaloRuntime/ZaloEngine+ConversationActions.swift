import Foundation
import OlazCore

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
    @ObservationIgnored private var isMirroring = false
    @ObservationIgnored internal var onRelock: (() -> Void)?
    @ObservationIgnored internal var onDropUnlock: (() -> Void)?
    @ObservationIgnored internal var onShowToast: ((Toast.Kind, String) -> Bool)?

    func show(_ kind: Toast.Kind, _ text: String) {
        if !isMirroring, let onShowToast, onShowToast(kind, text) {
            return
        }
        seq += 1; toast = Toast(seq: seq, kind: kind, text: text)
    }
    func remove(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        seq += 1; removal = Removal(seq: seq, ids: ids)
        if let unlockedId, ids.contains(unlockedId) { self.unlockedId = nil }
    }
    func unlock(_ id: String) { unlockedId = id }
    func isUnlocked(_ id: String) -> Bool { unlockedId == id }
    func setPinSearch(_ ids: [String]) { if ids != pinSearchIds { pinSearchIds = ids } }
    /// The selection moved to another conversation.
    func dropUnlock() {
        unlockedId = nil
        if !isMirroring { onDropUnlock?() }
    }
    /// Search cleared, app resigned active, PIN reset, logout.
    func relock() {
        unlockedId = nil
        if !pinSearchIds.isEmpty { pinSearchIds = [] }
        if !isMirroring { onRelock?() }
    }
    func reset() {
        isMirroring = true
        defer { isMirroring = false }
        unlockedId = nil
        if !pinSearchIds.isEmpty { pinSearchIds = [] }
        toast = nil
        removal = nil
    }

    internal func applyCoreMirror(_ record: ConversationActionUiRecord) {
        isMirroring = true
        defer { isMirroring = false }
        let nextToast: Toast? = record.toast.map { t in
            let kind: Toast.Kind
            switch t.kind {
            case "success": kind = .success
            case "neutral": kind = .neutral
            default: kind = .failure
            }
            return Toast(seq: Int(t.seq), kind: kind, text: t.text)
        }
        if nextToast != toast {
            toast = nextToast
        }
        let nextRemoval: Removal? = record.removal.map { r in
            Removal(seq: Int(r.seq), ids: Set(r.ids))
        }
        if nextRemoval != removal {
            removal = nextRemoval
        }
        if record.unlockedId != unlockedId {
            unlockedId = record.unlockedId
        }
        if record.pinSearchIds != pinSearchIds {
            pinSearchIds = record.pinSearchIds
        }
        seq = max(seq, Int(record.toast?.seq ?? 0), Int(record.removal?.seq ?? 0))
    }
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
        coreLifecycle.core?.pinConversation(id: id)
    }

    func unpinConversation(_ id: String) {
        coreLifecycle.core?.unpinConversation(id: id)
    }

    func pinBoard(for id: String) async -> PinBoard? {
        guard let core = await ensureCoreEngine() else { return nil }
        guard let record = try? await core.requestPinBoard(id: id) else { return nil }
        return PinBoard(coreRecord: record)
    }

    func pinReplacing(_ unpinIds: [String], pinning id: String) async -> ConversationActionResult {
        guard let core = await ensureCoreEngine() else {
            return ConversationActionResult(ok: false, text: "Ghim hội thoại không thành công.")
        }
        guard let record = try? await core.pinReplacing(unpinIds: unpinIds, pinId: id) else {
            return ConversationActionResult(ok: false, text: "Ghim hội thoại không thành công.")
        }
        await waitForMirrorVersion(core.currentVersion())
        return ConversationActionResult(coreRecord: record)
    }

    // MARK: Archive

    func moveConversation(_ id: String, toOther: Bool) {
        coreLifecycle.core?.moveConversation(id: id, toOther: toOther)
    }

    // MARK: Delete

    func requestDeleteConversation(_ id: String) {
        if let core = coreLifecycle.core {
            core.requestDeleteConversation(id: id)
            return
        }
        conversationPrompt = .delete(id: id)
    }

    func confirmDeleteConversation(_ id: String) {
        let lastCliId = messages[id]?.last?.id ?? ""
        messages[id] = nil
        coreLifecycle.core?.confirmDeleteConversation(id: id, lastCliMsgId: lastCliId)
    }

    // MARK: Read / unread

    func markConversationRead(_ id: String) {
        markRead(id)
    }

    func markConversationUnread(_ id: String) {
        coreLifecycle.core?.markConversationUnread(id: id)
    }

    // MARK: Hidden chats (delegated to `olaz-core`)

    func syncHiddenConversations() async {
        guard let core = await ensureCoreEngine() else { return }
        if let v = try? await core.syncHiddenConversations() {
            await waitForMirrorVersion(v)
        }
    }

    internal func applyServerHiddenConversations(_ snap: HiddenConversationsSnapshot) async {
        guard let core = await ensureCoreEngine() else { return }
        if let v = try? await core.applyServerHiddenConversations(pin: snap.pin, threadIds: snap.threadIds) {
            await waitForMirrorVersion(v)
        }
    }

    func checkHiddenChatPIN(_ pin: String) async -> Bool {
        guard let core = await ensureCoreEngine() else { return false }
        return (try? await core.checkHiddenPin(pin: pin)) ?? false
    }

    func hideConversation(_ id: String, pin: String) async -> ConversationActionResult {
        guard let core = await ensureCoreEngine() else {
            return ConversationActionResult(ok: false, text: "Mã PIN không đúng.", badPIN: true)
        }
        guard let record = try? await core.hideConversation(id: id, pin: pin) else {
            return ConversationActionResult(ok: false, text: "Mã PIN không đúng.", badPIN: true)
        }
        await waitForMirrorVersion(core.currentVersion())
        return ConversationActionResult(coreRecord: record)
    }

    func hideConversation(_ id: String, settingNewPIN pin: String) async -> ConversationActionResult {
        guard let core = await ensureCoreEngine() else {
            return ConversationActionResult(ok: false, text: "Không thể cài mã PIN trò chuyện ẩn.")
        }
        guard let record = try? await core.hideConversationNewPin(id: id, pin: pin) else {
            return ConversationActionResult(ok: false, text: "Không thể cài mã PIN trò chuyện ẩn.")
        }
        await waitForMirrorVersion(core.currentVersion())
        return ConversationActionResult(coreRecord: record)
    }

    func unhideConversation(_ id: String, pin: String?) async -> ConversationActionResult {
        guard let core = await ensureCoreEngine() else {
            return ConversationActionResult(ok: false, text: "Mã PIN không đúng.", badPIN: true)
        }
        guard let record = try? await core.unhideConversation(id: id, pin: pin) else {
            return ConversationActionResult(ok: false, text: "Mã PIN không đúng.", badPIN: true)
        }
        await waitForMirrorVersion(core.currentVersion())
        return ConversationActionResult(coreRecord: record)
    }

    func setHiddenChatPIN(_ pin: String, changed: Bool) async -> ConversationActionResult {
        guard let core = await ensureCoreEngine() else {
            return ConversationActionResult(ok: false, text: changed ? "Không thể đổi mã PIN." : "Không thể cài mã PIN.")
        }
        guard let record = try? await core.setHiddenPin(pin: pin, changed: changed) else {
            return ConversationActionResult(ok: false, text: changed ? "Không thể đổi mã PIN." : "Không thể cài mã PIN.")
        }
        await waitForMirrorVersion(core.currentVersion())
        return ConversationActionResult(coreRecord: record)
    }

    func resetHiddenChatPIN() async -> ConversationActionResult {
        guard let core = await ensureCoreEngine() else {
            return ConversationActionResult(ok: false, text: "Không thể xóa mã PIN.")
        }
        guard let record = try? await core.resetHiddenPin() else {
            return ConversationActionResult(ok: false, text: "Không thể xóa mã PIN.")
        }
        await waitForMirrorVersion(core.currentVersion())
        return ConversationActionResult(coreRecord: record)
    }

    func hiddenConversations(matching query: String) async -> [String]? {
        guard let core = await ensureCoreEngine() else {
            conversationUI.setPinSearch([])
            return nil
        }
        let ids = (try? await core.hiddenSearch(query: query)) ?? nil
        await waitForMirrorVersion(core.currentVersion())
        return ids
    }

    func isConversationLocked(_ id: String) -> Bool {
        conversationActions.isHidden(id) && !conversationUI.isUnlocked(id)
    }

    func unlockFromPINSearch(_ id: String) -> Bool {
        guard conversationUI.pinSearchIds.contains(id) else { return false }
        conversationUI.unlock(id)
        coreLifecycle.core?.unlockFromPinSearch(id: id)
        return true
    }

    func unlockHiddenConversation(_ id: String) {
        conversationUI.unlock(id)
        coreLifecycle.core?.unlockHiddenConversation(id: id)
    }

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
        if let core = coreLifecycle.core {
            core.reportConversationActionResult(result: result.coreRecord)
            return
        }
        let batch = offlineConversationsCore().reportConversationActionResult(result: result.coreRecord)
        applyCoreChanges(batch)
    }

    func resetConversationActions() {
        if let core = coreLifecycle.core {
            core.resetConversationActions()
            return
        }
        let batch = offlineConversationsCore().resetConversationActions()
        applyCoreChanges(batch)
    }

    func republishConversationActions() {
        rebuildConversationFlags()
    }

    internal func rebuildConversationFlags() {
        if let core = coreLifecycle.core {
            core.republishConversationActions()
            return
        }
        let batch = offlineConversationsCore().republishConversationActions()
        applyCoreChanges(batch)
    }

    var isInCall: Bool { call.busy || call.nativeRunning }

    func handleConversationActions(state: [String: Any]) {
        let json = Self.jsonString(for: state)
        if let core = coreLifecycle.core {
            core.handleConversationActions(stateJson: json)
            return
        }
        let batch = offlineConversationsCore().handleConversationActions(stateJson: json)
        applyCoreChanges(batch)
    }
}
