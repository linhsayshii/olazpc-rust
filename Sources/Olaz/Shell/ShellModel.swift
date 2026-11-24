import SwiftUI

/// What the sidebar picked; decides the content column (list) and the detail column.
enum SidebarDestination: Hashable {
    /// The official default list tab ("Ưu tiên" with the Khác feature on, "Tất cả" without it); Olaz calls it
    /// "Tin nhắn" (`ConversationExtras.inboxTitle`).
    case inbox
    /// Official "Khác" tab (only offered while `ConversationExtras.archivedEnabled`).
    case other
    /// Official "Chưa đọc" tab.
    case unread
    /// The stranger folder (`ConversationExtras.strangerFolderIds`).
    case strangers
    /// Hidden chats: listed only after the PIN was entered.
    case hidden
    /// A "Phân loại" label (official label filter on the default tab). Picked from the label button of the list column;
    /// the sidebar has no row for it and keeps highlighting "Tin nhắn".
    case label(String)
    /// "Cloud của tôi": the self conversation, opened in the inbox list.
    case myCloud
    case zcloud
    case friends, groups, requests, addFriend

    /// Destinations whose content column is a conversation list and whose detail is a chat.
    var isConversationList: Bool {
        switch self {
        case .inbox, .other, .unread, .strangers, .hidden, .label, .myCloud: true
        case .zcloud, .friends, .groups, .requests, .addFriend: false
        }
    }

    /// The sidebar row this destination belongs to: a label filter is a view of the inbox.
    var sidebarRow: SidebarDestination {
        if case .label = self { .inbox } else { self }
    }

    /// For the engine log: never a label id or conversation id in full.
    var logName: String {
        switch self {
        case .label: "label"
        default: "\(self)"
        }
    }

    var isContacts: Bool {
        switch self {
        case .friends, .groups, .requests, .addFriend: true
        default: false
        }
    }

    /// The official ConvListController filter this destination shows, nil when it is not a controller list
    /// (stranger folder and hidden chats are computed in Swift; contacts / zCloud have no list filter).
    func officialFilter(defaultTab: ConversationTypeFilter) -> (tab: ConversationTypeFilter, labelIds: [String])? {
        switch self {
        case .inbox, .myCloud: (defaultTab, [])
        case .other: (.other, [])
        case .unread: (.unread, [])
        case .label(let id): (defaultTab, [id])
        case .strangers, .hidden, .zcloud, .friends, .groups, .requests, .addFriend: nil
        }
    }
}

/// The coach-mark tour shown after setup (and from Trợ giúp ▸ Hướng dẫn sử dụng).
enum TourStep: Int, CaseIterable, Identifiable {
    case mailboxes, search, message, composer, toolbar

    var id: Int { rawValue }
    var next: TourStep? { TourStep(rawValue: rawValue + 1) }
    var previous: TourStep? { TourStep(rawValue: rawValue - 1) }
}

/// Window-level UI state shared by the shell views and the menu-bar commands (one main window).
/// Conversation data stays in `ZaloEngine`; this only holds what the user is looking at.
@MainActor
@Observable
final class ShellModel {
    var destination: SidebarDestination = .inbox
    /// The conversation shown in the detail column (conversation-list destinations).
    var selection: String?
    var columns: NavigationSplitViewVisibility = .all
    /// Conversation info inspector (⌥⌘I).
    var showInspector = false
    /// The window holds the inspector's room: its minimum width includes the inspector, from the end of the widening until the
    /// inspector is hidden. Raising it while the window is still widening would snap the window wide at once.
    var holdsInspectorRoom = false
    /// The signed-in window (set by `MainShellView`), widened for the inspector.
    @ObservationIgnored weak var window: NSWindow?
    /// ⌘K palette.
    var showQuickSwitcher = false
    /// Search text of the conversation list column.
    var search = ""
    /// Hidden chats listed by the "Trò chuyện ẩn" mailbox after the PIN was entered; nil while locked.
    var unlockedHiddenIds: [String]?
    /// Selected row of the contacts lists (friend / group / request id).
    var contactSelection: String?
    /// Selected zCloud screen.
    var cloudRoute: CloudRoute? = .media
    /// Running coach-mark step, nil when no tour is shown.
    var tour: TourStep?
    /// The "Tạo nhóm" sheet, nil when it is not shown.
    var groupCompose: GroupComposeRequest?

    // Ticks: a view observing one of these performs the action when it changes.
    /// Focus the list search field (⌘F in the list, ⌥⌘F).
    private(set) var searchFocusTick = 0
    /// Reply to the last incoming message of the open chat (⌘R).
    private(set) var replyTick = 0
    /// Open / close the in-conversation search of the open chat (its toolbar button).
    private(set) var chatSearchTick = 0

    func focusSearch() { searchFocusTick += 1 }

    /// Shows the "Tạo nhóm" sheet with `members` already picked.
    func composeGroup(with members: [String] = []) { groupCompose = GroupComposeRequest(members: members) }
    func replyToLatest() { replyTick += 1 }
    func toggleChatSearch() { chatSearchTick += 1 }

    /// Shows a conversation: keeps the current list when it is a conversation list, otherwise goes to the inbox.
    func open(conversation id: String) {
        if !destination.isConversationList || destination == .hidden { destination = .inbox }
        search = ""
        selection = id
    }

    /// Back to a fresh window: the model outlives the sign-in, so a logout (or the next account's QR sign-in) must not
    /// inherit the previous account's open chat, search, unlocked hidden mailbox or running tour.
    func reset() {
        selection = nil
        destination = .inbox
        search = ""
        unlockedHiddenIds = nil
        contactSelection = nil
        cloudRoute = .media
        tour = nil
        showQuickSwitcher = false
        showInspector = false
        holdsInspectorRoom = false
        groupCompose = nil
    }

    func toggleSidebar() {
        withAnimation(.smooth(duration: 0.3)) { columns = columns == .all ? .doubleColumn : .all }
    }

    /// Shows or hides the inspector at once, like the official info panel (no slide). The split view lays the inspector over
    /// the detail column and hands it a trailing safe-area inset; animated, that inset changed every frame, so the chat re-measured
    /// its rows and the inspector re-laid out its content on each of them (~35 fps for a quarter second, then a jump). Without
    /// animation it is one layout pass.
    func toggleInspector() {
        guard destination.isConversationList, selection != nil, !showInspector else { hideInspector(); return }
        // The window widens first (synchronously), so the inspector takes its width from the window, never from the chat.
        InspectorRoom.make(in: window) { [weak self] in
            guard let self else { return }
            holdsInspectorRoom = true
            Self.withoutAnimation { showInspector = true }
        }
    }

    func hideInspector() {
        holdsInspectorRoom = false
        Self.withoutAnimation { showInspector = false }
    }

    private static func withoutAnimation(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }

    // MARK: Tour

    func startTour() {
        destination = .inbox
        search = ""
        showQuickSwitcher = false
        columns = .all
        tour = .mailboxes
    }

    func advanceTour() { tour = tour?.next }
    func retreatTour() { if let previous = tour?.previous { tour = previous } }
    func endTour() { tour = nil }
}

/// The inspector takes its width from the window, never from the chat: a three-column window at its 960 pt minimum would otherwise
/// leave the chat a sliver (sidebar + list + inspector ≈ 876 pt), where its layout never settles and AppKit crashes on the endless
/// layout passes. So the window is widened before the inspector opens, and cannot be made narrower than this while it shows.
@MainActor
enum InspectorRoom {
    static let windowMinWidth: CGFloat = 960
    /// Room the inspector needs on top of `windowMinWidth` (its ideal width).
    static let inspectorWidth: CGFloat = 300
    static var windowMinWidthWithInspector: CGFloat { windowMinWidth + inspectorWidth }

    /// The window frame that gives the inspector its room: wider by what is missing, growing to the right and moving left only as far as
    /// the screen needs. A frame already wide enough is returned unchanged.
    static func frame(for window: CGRect, in screen: CGRect) -> CGRect {
        let width = min(max(window.width, windowMinWidthWithInspector), screen.width)
        guard width > window.width else { return window }
        var x = window.minX
        if x + width > screen.maxX { x = screen.maxX - width }
        return CGRect(x: max(screen.minX, x), y: window.minY, width: width, height: window.height)
    }

    /// Widens the shell window for the inspector, then runs `completion`; with nothing to widen (a window already wide enough, or a
    /// full-screen one, which is as wide as it gets) it just runs `completion`.
    static func make(in window: NSWindow?, completion: @escaping @MainActor () -> Void) {
        guard let window, !window.styleMask.contains(.fullScreen), let screen = window.screen ?? NSScreen.main else { completion(); return }
        let target = frame(for: window.frame, in: screen.visibleFrame)
        guard target != window.frame else { completion(); return }
        // Apply the frame synchronously before showing the inspector column so AppKit never leaves `NSTableView` stuck in `inLiveResize`.
        window.setFrame(target, display: true, animate: false)
        completion()
    }
}
