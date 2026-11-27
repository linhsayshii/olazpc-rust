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
    /// The window holds the inspector's room: its minimum width includes the inspector, raised only AFTER the inspector
    /// has presented inside the already-widened window. Raising it in the same SwiftUI update as `showInspector = true`
    /// causes AppKit's `.inspector` to expand the window a second time (+600 pt total, hitting full screen width).
    var holdsInspectorRoom = false
    /// Minimum window width held while `holdsInspectorRoom` is true (capped to the screen's visible width).
    var inspectorMinWidth: CGFloat = InspectorRoom.windowMinWidth
    /// The signed-in window (set by `MainShellView`), widened for the inspector.
    @ObservationIgnored weak var window: NSWindow?
    /// What opening the inspector added to the window, given back when it closes.
    @ObservationIgnored private var inspectorGrowth: InspectorRoom.Growth?
    /// Cancels a deferred `holdsInspectorRoom` update if the inspector closes or re-toggles before the next runloop turn.
    @ObservationIgnored private var inspectorGeneration: UInt64 = 0
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
        hideInspector()
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
        let plan = InspectorRoom.make(in: window)
        inspectorGrowth = plan?.growth
        inspectorGeneration &+= 1
        let gen = inspectorGeneration
        Self.withoutAnimation { showInspector = true }

        // Defer raising `ShellMinimumSize` until after SwiftUI finishes presenting `.inspector` on the current runloop turn;
        // changing the outer `.frame(minWidth:)` in the same update as `showInspector = true` makes AppKit add a second
        // inspector width to the window frame. Also clamp back to `plan.targetFrame` if AppKit nudged the frame during layout.
        let targetFrame = plan?.targetFrame
        let screenWidth = window?.screen?.visibleFrame.width ?? NSScreen.main?.visibleFrame.width
        let minWidth = plan?.minimumWidth ?? InspectorRoom.minimumWidth(holdingInspectorRoom: true, screenWidth: screenWidth)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.inspectorGeneration == gen, self.showInspector else { return }
            if let targetFrame, let window = self.window, !window.styleMask.contains(.fullScreen),
               window.frame != targetFrame {
                window.setFrame(targetFrame, display: true, animate: false)
            }
            self.inspectorMinWidth = minWidth
            self.holdsInspectorRoom = true
        }
    }

    func hideInspector() {
        guard showInspector || holdsInspectorRoom || inspectorGrowth != nil else { return }
        inspectorGeneration &+= 1
        // Consume `inspectorGrowth` before toggling `showInspector` so a synchronous `.onChange(of: showInspector)`
        // re-entry cannot release the growth a second time.
        let growth = inspectorGrowth
        inspectorGrowth = nil
        holdsInspectorRoom = false
        inspectorMinWidth = InspectorRoom.windowMinWidth
        if showInspector {
            Self.withoutAnimation { showInspector = false }
        }
        // The window gives the inspector's width back, so it ends where it was before the inspector opened.
        InspectorRoom.release(growth, in: window)
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

/// The inspector adds its own width to the window, like opening a side panel: the chat keeps the width it had. Closing it gives
/// the width back, so the window returns to the frame it had before. Only when the screen has no room left (a window already as wide
/// as the screen, or full screen) does the inspector take its width from the chat. The window also cannot be made narrower than
/// `windowMinWidthWithInspector` while the inspector shows: a three-column window at its 960 pt minimum would otherwise leave the
/// chat a sliver, where its layout never settles and AppKit crashes on the endless layout passes.
@MainActor
enum InspectorRoom {
    static let windowMinWidth: CGFloat = 960
    /// Width the inspector opens at (its ideal width), added to the window.
    static let inspectorWidth: CGFloat = 300
    static var windowMinWidthWithInspector: CGFloat { windowMinWidth + inspectorWidth }

    /// What opening the inspector did to the window, undone when it closes.
    struct Growth: Equatable {
        /// Width added to the window.
        var added: CGFloat
        /// How far the window moved left to stay on screen.
        var shifted: CGFloat
    }

    /// Complete pure-math plan for opening the inspector on a screen: target window frame, growth to undo on close,
    /// and the minimum width to hold while open (never wider than the screen).
    struct OpenPlan: Equatable {
        var targetFrame: CGRect
        var growth: Growth?
        var minimumWidth: CGFloat
    }

    /// Minimum window width to enforce for the current inspector state, capped to `screenWidth` so a compact display
    /// is never forced wider than its visible frame.
    static func minimumWidth(holdingInspectorRoom: Bool, screenWidth: CGFloat?) -> CGFloat {
        guard holdingInspectorRoom else { return windowMinWidth }
        guard let screenWidth, screenWidth > 0 else { return windowMinWidthWithInspector }
        return max(windowMinWidth, min(windowMinWidthWithInspector, screenWidth))
    }

    /// The window frame with the inspector's width added: growing to the right, moving left only as far as the screen needs, never
    /// wider than the screen. A window that cannot grow is returned unchanged.
    static func frame(for window: CGRect, in screen: CGRect) -> CGRect {
        let width = min(max(window.width + inspectorWidth, windowMinWidthWithInspector), max(window.width, screen.width))
        guard width > window.width else { return window }
        var x = window.minX
        if x + width > screen.maxX { x = screen.maxX - width }
        return CGRect(x: max(screen.minX, x), y: window.minY, width: width, height: window.height)
    }

    /// Pure-function plan for opening the inspector on `window` within `screen`.
    static func planOpen(window: CGRect, in screen: CGRect) -> OpenPlan {
        let target = frame(for: window, in: screen)
        let growth: Growth? = target == window
            ? nil
            : Growth(added: target.width - window.width, shifted: window.minX - target.minX)
        let minWidth = minimumWidth(holdingInspectorRoom: true, screenWidth: screen.width)
        return OpenPlan(targetFrame: target, growth: growth, minimumWidth: minWidth)
    }

    /// The frame after closing: the added width given back and the window moved back to where it was (the user may have moved or
    /// resized it meanwhile, so this works from the current frame), never narrower than `windowMinWidth`.
    static func restored(_ window: CGRect, undoing growth: Growth) -> CGRect {
        let width = max(windowMinWidth, window.width - growth.added)
        let given = max(0, window.width - width)
        // Moves back in proportion to the width given back: all of it when the whole width is returned.
        let x = window.minX + (growth.added > 0 ? growth.shifted * given / growth.added : 0)
        return CGRect(x: x, y: window.minY, width: width, height: window.height)
    }

    /// Widens the shell window for the inspector and returns the open plan; nil when in full screen or no window/screen exists.
    static func make(in window: NSWindow?) -> OpenPlan? {
        guard let window, !window.styleMask.contains(.fullScreen), let screen = window.screen ?? NSScreen.main else { return nil }
        let plan = planOpen(window: window.frame, in: screen.visibleFrame)
        if plan.growth != nil {
            // Synchronous, so AppKit never leaves `NSTableView` stuck in `inLiveResize`; not displayed yet, so the wider window and the
            // inspector reach the screen in the same frame (no frame of a stretched chat first).
            window.setFrame(plan.targetFrame, display: false, animate: false)
        }
        return plan
    }

    /// Gives back the width `growth` added.
    static func release(_ growth: Growth?, in window: NSWindow?) {
        guard let growth, let window, !window.styleMask.contains(.fullScreen) else { return }
        // Lower min widths before shrinking so AppKit never clamps `setFrame` to `windowMinWidthWithInspector`
        // before SwiftUI commits the updated `ShellMinimumSize`.
        if window.minSize.width > windowMinWidth {
            window.minSize.width = windowMinWidth
        }
        if window.contentMinSize.width > windowMinWidth {
            window.contentMinSize.width = windowMinWidth
        }
        let target = restored(window.frame, undoing: growth)
        guard target != window.frame else { return }
        window.setFrame(target, display: false, animate: false)
    }
}
