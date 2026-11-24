import SwiftUI

/// One line of the conversation list.
private enum ListItem: Identifiable {
    case conversation(ZaloEngine.ConversationSummary)
    case strangerBox

    var id: String {
        switch self {
        case .conversation(let c): c.id
        case .strangerBox: ConversationExtras.strangerBoxId
        }
    }
}

/// What the list shows: pinned tiles above the rows (inbox only).
private struct Listing {
    var pins: [ZaloEngine.ConversationSummary] = []
    var rows: [ListItem] = []

    var isEmpty: Bool { pins.isEmpty && rows.isEmpty }

    /// Chats with unread messages in this list (the navigation subtitle).
    var unreadChats: Int {
        let rowChats = rows.reduce(0) { count, item in
            if case .conversation(let c) = item, c.unread > 0 { count + 1 } else { count }
        }
        return rowChats + pins.filter { $0.unread > 0 }.count
    }
}

/// Content column for the conversation mailboxes / labels: search field (and the label filter of the inbox) on top,
/// pinned tiles, then the rows.
struct ConversationListColumn: View {
    @Environment(ZaloEngine.self) private var engine
    @Environment(ShellModel.self) private var shell
    @State private var showLabelManager = false
    /// Swipe buttons take a plain color, not the root `.tint` style.
    @AppStorage(OlazPrefs.accent) private var accent = OlazAccent.blue
    /// Hidden conversations listed because the search text is the PIN.
    @State private var pinMatches: [String] = []
    /// The search text the PIN search last ran for (nil on the first run of this view: re-appearing is not a search change).
    @State private var lastSearch: String?
    /// The hidden-chat state did not arrive for a long while: say so instead of spinning forever (everything stays locked).
    @State private var hiddenStateStalled = false

    private var extras: ConversationExtras { engine.conversationExtras }
    private var query: String { shell.search.trimmingCharacters(in: .whitespaces) }
    private var isSearching: Bool { !query.isEmpty }
    /// The label filtering the inbox, nil when none (or while searching: search spans every chat, so the filter is paused).
    private var activeLabel: ConversationExtras.Label? {
        isSearching ? nil : extras.label(filteredBy: shell.destination)
    }
    /// The label button is offered where the official client filters by label: the inbox and a label itself.
    private var offersLabelFilter: Bool {
        guard extras.loaded else { return false }
        if case .label = destination { return true }
        return destination == .inbox
    }
    /// "Cloud của tôi" is the inbox with the self conversation open; `.myCloud` itself is never a list of its own.
    private var destination: SidebarDestination { shell.destination == .myCloud ? .inbox : shell.destination }
    /// "Trò chuyện ẩn" waiting for its PIN (without a PIN there is nothing to unlock: the plain empty state shows).
    private var isLocked: Bool {
        destination == .hidden && engine.conversationActions.hasHiddenPIN && shell.unlockedHiddenIds == nil && !isSearching
    }

    /// Rows for the current destination. Search looks through every conversation (strangers included); otherwise the
    /// list is exactly what the official ConvListController computed for the active filter.
    private var items: [ListItem] {
        let all = engine.conversations
        if isSearching {
            // Hidden chats only show up when the query is the PIN (official sidebar search).
            let hidden = engine.conversationActions.hiddenIds
            let byPIN = pinMatches.compactMap { id in all.first { $0.id == id } }
            let byName = all.filter { !hidden.contains($0.id) && $0.displayName.localizedCaseInsensitiveContains(query) }
            return (byPIN + byName).map(ListItem.conversation)
        }
        if destination == .hidden {
            return (shell.unlockedHiddenIds ?? []).compactMap { id in all.first { $0.id == id } }.map(ListItem.conversation)
        }
        // Hidden chats are removed in every mode (the controller may still list one right after a local hide).
        let visible = all.filter { !engine.conversationActions.isHidden($0.id) }
        guard extras.loaded else { return visible.map(ListItem.conversation) }
        let byId = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if destination == .strangers {
            return extras.strangerFolderIds.compactMap { byId[$0] }.map(ListItem.conversation)
        }
        return extras.listIds.compactMap { id -> ListItem? in
            if id == ConversationExtras.strangerBoxId { return extras.strangerBox.chats > 0 ? .strangerBox : nil }
            return byId[id].map(ListItem.conversation)
        }
    }

    /// In the inbox the pinned chats leave the rows and become tiles (not while searching: results are plain rows).
    private var listing: Listing {
        let all = items
        guard destination == .inbox, !isSearching else { return Listing(rows: all) }
        var listing = Listing()
        for item in all {
            if case .conversation(let c) = item, engine.conversationActions.isPinned(c.id) {
                listing.pins.append(c)
            } else {
                listing.rows.append(item)
            }
        }
        return listing
    }

    var body: some View {
        let listing = self.listing
        VStack(spacing: 0) {
            header
                .padding(.top, 6)
            content(listing)
        }
        .sheet(isPresented: $showLabelManager) { LabelManagerView() }
            .background { pinShortcuts(listing.pins) }
            .task(id: shell.search) {
                pinMatches = query.count == 4 ? (await engine.hiddenConversations(matching: query) ?? []) : []
                // The search text really changed (not this view re-appearing) and no longer is the PIN: the bypass of an earlier result ends.
                // Not while the mailbox itself is unlocked: that lives until "Khoá" or a minute away.
                if let lastSearch, lastSearch != shell.search, pinMatches.isEmpty, shell.unlockedHiddenIds == nil { engine.conversationUI.relock() }
                lastSearch = shell.search
            }
            .task(id: engine.conversationActions.hiddenKnown) {
                hiddenStateStalled = false
                guard !engine.conversationActions.hiddenKnown else { return }
                try? await Task.sleep(for: .seconds(HiddenStateGuard.stallLimit))
                if !Task.isCancelled, !engine.conversationActions.hiddenKnown { hiddenStateStalled = true }
            }
    }

    // MARK: Header

    /// Search field with the label button beside it, and the active label's chip below. Pinned above every state.
    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ConversationListSearchField()
                if offersLabelFilter {
                    ConversationListLabelFilter(showLabelManager: $showLabelManager)
                        .disabled(isSearching)
                }
                CreateGroupButton()
            }
            if let label = activeLabel {
                HStack(spacing: 0) {
                    ConversationListLabelChip(label: label) { shell.destination = .inbox }
                    Spacer(minLength: 0)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.smooth(duration: 0.2), value: activeLabel?.id)
    }

    // MARK: Content

    @ViewBuilder private func content(_ listing: Listing) -> some View {
        if engine.conversations.isEmpty || !engine.conversationActions.hiddenKnown {
            ConversationListLoading(stalled: hiddenStateStalled && !engine.conversationActions.hiddenKnown)
        } else if isLocked {
            ConversationListLocked()
        } else if listing.isEmpty {
            VStack(spacing: 0) {
                if destination == .hidden, shell.unlockedHiddenIds != nil { banner.padding(.horizontal, 12) }
                ConversationListEmpty(destination: destination, searchText: isSearching ? query : nil)
                    .fillColumn()
            }
            // Fills the column so the search bar stays at the top instead of hugging a centered empty state.
            .fillColumn()
        } else {
            list(listing)
        }
    }

    private func list(_ listing: Listing) -> some View {
        ConversationTableView(
            entries: entries(listing),
            selection: shell.selection,
            selectionTint: NSColor(accent.color),
            onSelect: { shell.selection = $0 },
            onActivate: { _ in },
            swipeActions: swipeActions,
            rowContent: rowContent)
    }

    /// The lines of the table: banner, pinned tiles, then the rows (under a section title while searching).
    private func entries(_ listing: Listing) -> [ConversationTableEntry] {
        var out: [ConversationTableEntry] = []
        out.reserveCapacity(listing.rows.count + 3)
        if !isSearching, hasBanner { out.append(.banner) }
        if !listing.pins.isEmpty { out.append(.pins(listing.pins)) }
        if isSearching { out.append(.section("Cuộc trò chuyện")) }
        let actions = engine.conversationActions
        let selfId = engine.selfConversationId
        let pinGlyph = !(destination == .inbox && !isSearching)
        for item in listing.rows {
            switch item {
            case .conversation(let c):
                out.append(.conversation(ConversationRowModel(
                    conversation: c,
                    label: extras.label(of: c.id),
                    showsPin: pinGlyph && actions.isPinned(c.id),
                    unreadMark: actions.hasUnreadMark(c.id),
                    isStranger: destination != .strangers && extras.strangerIds.contains(c.id),
                    isSelf: c.id == selfId)))
            case .strangerBox:
                out.append(.strangerBox)
            }
        }
        return out
    }

    private func rowContent(_ entry: ConversationTableEntry) -> AnyView {
        switch entry {
        case .banner:
            return AnyView(banner.padding(.top, 4).padding(.bottom, 8))
        case .pins(let pins):
            return AnyView(ConversationListPinGrid(pins: pins, showLabelManager: $showLabelManager).padding(.top, 2).padding(.bottom, 6))
        case .section(let title):
            return AnyView(Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.top, 6).padding(.bottom, 2))
        case .conversation(let m):
            return AnyView(
                ConversationListRow(conversation: m.conversation, label: m.label, showsPin: m.showsPin, unreadMark: m.unreadMark,
                                    isStranger: m.isStranger, isSelf: m.isSelf)
                    .equatable()
                    .contextMenu {
                        ConversationActionsMenu(conversationId: m.conversation.id, preset: .thread, showLabelManager: $showLabelManager)
                    })
        case .strangerBox:
            return AnyView(StrangerBoxRow(box: extras.strangerBox,
                                          newest: extras.strangerBox.newestId.flatMap { id in engine.conversations.first { $0.id == id && !engine.conversationActions.isHidden(id) } }) {
                shell.search = ""
                shell.destination = .strangers
            }.padding(.vertical, 5))
        }
    }

    /// Leading "Ghim" / "Bỏ ghim" and trailing "Đã đọc" / "Chưa đọc", offered exactly when the context menu offers them.
    private func swipeActions(_ id: String, _ edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
        let state = engine.conversationActions
        guard state.loaded, let conversation = engine.conversations.first(where: { $0.id == id }) else { return [] }
        let plan = ConversationMenuPlan.make(id: id, preset: .thread, state: state, unread: conversation.unread,
                                             muted: engine.isConversationMuted(id))
        func action(_ title: String, _ symbol: String, _ color: NSColor, _ run: @escaping () -> Void) -> NSTableViewRowAction {
            let a = NSTableViewRowAction(style: .regular, title: title) { _, _ in run() }
            a.backgroundColor = color
            a.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            return a
        }
        let engine = engine
        switch edge {
        case .leading:
            switch plan.pin {
            case .pin: return [action("Ghim", "pin.fill", .systemOrange) { engine.pinConversation(id) }]
            case .unpin: return [action("Bỏ ghim", "pin.slash.fill", .systemOrange) { engine.unpinConversation(id) }]
            case nil: return []
            }
        case .trailing:
            let accent = NSColor(self.accent.color)
            switch plan.read {
            case .markRead: return [action("Đã đọc", "envelope.open.fill", accent) { engine.markConversationRead(id) }]
            case .markUnread: return [action("Chưa đọc", "envelope.badge.fill", accent) { engine.markConversationUnread(id) }]
            case nil: return []
            }
        @unknown default:
            return []
        }
    }

    /// ⌘1…⌘9 open the pinned tiles while the list is on screen.
    private func pinShortcuts(_ pins: [ZaloEngine.ConversationSummary]) -> some View {
        ForEach(Array(pins.prefix(9).enumerated()), id: \.element.id) { index, conversation in
            Button("") { shell.selection = conversation.id }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: Chrome

    private var title: String {
        switch destination {
        case .inbox, .myCloud, .label: ConversationExtras.inboxTitle
        case .other: ConversationTypeFilter.other.title
        case .unread: ConversationTypeFilter.unread.title
        case .strangers: "Người lạ"
        case .hidden: "Trò chuyện ẩn"
        default: ConversationExtras.inboxTitle
        }
    }

    private func subtitle(_ listing: Listing) -> String {
        guard !isLocked, !engine.conversations.isEmpty, engine.conversationActions.hiddenKnown else { return activeLabel?.name ?? "" }
        let unread = listing.unreadChats
        let status = unread > 0 ? "\(unread) cuộc trò chuyện chưa đọc" : "Đã đọc hết"
        // "Gia đình · 2 cuộc trò chuyện chưa đọc": the label filter is named in the subtitle of "Tin nhắn".
        return activeLabel.map { "\($0.name) · \(status)" } ?? status
    }

    private var hasBanner: Bool {
        switch destination {
        case .strangers, .other: true
        case .hidden: shell.unlockedHiddenIds != nil
        default: false
        }
    }

    @ViewBuilder private var banner: some View {
        switch destination {
        case .strangers:
            ConversationListBanner(symbol: "shield.lefthalf.filled", lead: "Tin nhắn từ người lạ",
                                   message: "Người gửi chưa có trong danh bạ. Trả lời để chuyển vào \(ConversationExtras.inboxTitle).\nLưu ý rủi ro lừa đảo từ người lạ.",
                                   separator: "\n")
        case .other:
            ConversationListBanner(symbol: "archivebox", lead: "Khác",
                                   message: "giữ các nhóm đông người và tin ít quan trọng, không làm phiền bạn.")
        case .hidden:
            ConversationListBanner(symbol: "lock.open", lead: "Đang mở khoá.",
                                   message: "Tự khoá lại khi bạn rời \(AppBrand.name) một phút.",
                                   actionTitle: "Khoá", action: relockHidden)
        default:
            EmptyView()
        }
    }

    /// "Khoá": forget the PIN bypass and leave a hidden chat that is still open.
    private func relockHidden() {
        shell.unlockedHiddenIds = nil
        engine.conversationUI.relock()
        if let selected = shell.selection, engine.conversationActions.isHidden(selected) { shell.selection = nil }
    }
}

/// "Tạo nhóm" beside the search field, where the official list header has its "Tạo nhóm chat" button. Same glass circle as the label filter.
private struct CreateGroupButton: View {
    @Environment(ShellModel.self) private var shell

    var body: some View {
        Button { shell.composeGroup() } label: {
            Image(systemName: "person.2.badge.plus")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .glassEffect(.regular.interactive(), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Tạo nhóm trò chuyện (⇧⌘N)")
        .accessibilityLabel("Tạo nhóm")
    }
}
