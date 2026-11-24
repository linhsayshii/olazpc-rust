import AppKit
import SwiftUI

// The conversation list, AppKit-backed.
//
// A SwiftUI `List` re-diffed every row on each change: one arriving message moves one chat to the top, yet
// `OutlineListCoordinator.diffRows` walked all ~700 `ForEach` items, ~130 ms of main thread per message (offline bench:
// `OLAZ_BENCH_MODE=convlist Olaz --scroll-bench`). Here an `NSTableView` holds the rows; each cell hosts the same SwiftUI
// row views. An update diffs the row ids (moves, inserts, removals) and re-roots only the visible rows whose data changed;
// rows still observe the engine themselves (typing, mute) through their own hosting views.

/// What one line of the conversation table shows.
enum ConversationTableEntry: Equatable, Identifiable {
    /// The folder's banner ("Khác", "Người lạ", unlocked hidden chats).
    case banner
    /// The pinned tiles of the inbox, as one line.
    case pins([ZaloEngine.ConversationSummary])
    /// A section title ("Cuộc trò chuyện" while searching).
    case section(String)
    case conversation(ConversationRowModel)
    case strangerBox

    var id: String {
        switch self {
        case .banner: "\u{1}banner"
        case .pins: "\u{1}pins"
        case .section(let title): "\u{1}section-" + title
        case .conversation(let m): m.conversation.id
        case .strangerBox: ConversationExtras.strangerBoxId
        }
    }

    var conversationId: String? {
        if case .conversation(let m) = self { m.conversation.id } else { nil }
    }

    /// Lines above the rows (no row padding, no separator).
    var isHeader: Bool {
        switch self {
        case .banner, .pins, .section: true
        case .conversation, .strangerBox: false
        }
    }

    /// Lines that read column or engine state the entry does not carry: re-rooted (and re-measured) on every update.
    var refreshesAlways: Bool { conversationId == nil }
}

/// The data of one conversation row (what `ConversationListRow` compares on).
struct ConversationRowModel: Equatable {
    var conversation: ZaloEngine.ConversationSummary
    var label: ConversationExtras.Label?
    var showsPin: Bool
    var unreadMark: Bool
    var isStranger: Bool
    var isSelf: Bool
}

struct ConversationTableView: NSViewRepresentable {
    let entries: [ConversationTableEntry]
    let selection: String?
    /// Fill of the selected line (the Olaz accent).
    let selectionTint: NSColor
    let onSelect: (String) -> Void
    /// A click on a line that cannot be selected (the stranger box).
    let onActivate: (ConversationTableEntry) -> Void
    let swipeActions: (String, NSTableView.RowActionEdge) -> [NSTableViewRowAction]
    let rowContent: (ConversationTableEntry) -> AnyView

    func makeNSView(context: Context) -> NSScrollView {
        let controller = ConversationTableController()
        context.coordinator.controller = controller
        return controller.scrollView
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let controller = context.coordinator.controller else { return }
        controller.onSelect = onSelect
        controller.onActivate = onActivate
        controller.swipeActions = swipeActions
        controller.rowContent = rowContent
        controller.selectionTint = selectionTint
        controller.update(entries: entries, selection: selection, environment: context.environment)
    }

    /// Takes what it is offered (no Auto Layout fitting pass over the rows).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 300, height: proposal.height ?? 300)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        var controller: ConversationTableController?
    }
}

// MARK: - Rows

/// The SwiftUI root of one cell: the row content with the list's environment.
private struct ConversationCellRoot: View {
    let content: AnyView
    let environment: EnvironmentValues
    let header: Bool

    var body: some View {
        content
            .padding(.vertical, header ? 0 : 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.self, environment)
    }
}

@MainActor
private final class ConversationCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("conversation-cell")
    let host: NSHostingView<ConversationCellRoot>
    private(set) var entry: ConversationTableEntry?
    private var content = AnyView(EmptyView())
    private var environment = EnvironmentValues()
    /// Header lines (pinned tiles, banner buttons) take their own clicks; conversation lines leave them to the table.
    var takesClicks = false

    init() {
        host = NSHostingView(rootView: ConversationCellRoot(content: AnyView(EmptyView()), environment: EnvironmentValues(),
                                                            header: false))
        host.sizingOptions = []
        super.init(frame: .zero)
        identifier = Self.identifier
        addSubview(host)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        host.frame = bounds
    }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        takesClicks || super.validateProposedFirstResponder(responder, for: event)
    }

    func configure(_ entry: ConversationTableEntry, content: AnyView, environment: EnvironmentValues) {
        self.entry = entry
        self.content = content
        self.environment = environment
        takesClicks = entry.conversationId == nil
        render()
    }

    private func render() {
        host.rootView = ConversationCellRoot(content: content, environment: environment,
                                             header: entry?.isHeader ?? false)
    }
}

/// Draws the separator under conversation lines (inset like the list's, where the text starts) and the selection: a light fill
/// of the Olaz accent (Cài đặt › Màu nhấn), like the official list. The stock selection used the macOS accent while the list had
/// focus and turned grey the moment the chat took it; this one looks the same either way.
private final class ConversationRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("conversation-row")
    var drawsSeparatorLine = false
    static let separatorLeading: CGFloat = 64
    var selectionTint: NSColor = .controlAccentColor {
        didSet { if isSelected, selectionTint != oldValue { needsDisplay = true } }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // The cell starts where the avatar does: the fill keeps a margin around it, the same on both sides of the row.
        let cellX = subviews.first { $0 is ConversationCell }?.frame.minX ?? 10
        let rect = bounds.insetBy(dx: max(4, cellX - 8), dy: 1)
        selectionTint.withAlphaComponent(isDark ? 0.30 : 0.16).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard drawsSeparatorLine, !isSelected, !isNextRowSelected else { return }
        let cellX = subviews.first { $0 is ConversationCell }?.frame.minX ?? 10
        let scale = window?.backingScaleFactor ?? 2
        let line = NSRect(x: cellX + Self.separatorLeading, y: bounds.maxY - 1 / scale,
                          width: max(0, bounds.maxX - cellX - Self.separatorLeading - 10), height: 1 / scale)
        NSColor.separatorColor.setFill()
        line.fill()
    }

    override var isFlipped: Bool { true }
}

// MARK: - Controller

@MainActor
final class ConversationTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let scrollView = NSScrollView()
    let tableView = NSTableView()
    var onSelect: (String) -> Void = { _ in }
    var onActivate: (ConversationTableEntry) -> Void = { _ in }
    var swipeActions: (String, NSTableView.RowActionEdge) -> [NSTableViewRowAction] = { _, _ in [] }
    var rowContent: (ConversationTableEntry) -> AnyView = { _ in AnyView(EmptyView()) }
    var selectionTint: NSColor = .controlAccentColor {
        didSet {
            guard selectionTint != oldValue else { return }
            tableView.enumerateAvailableRowViews { view, _ in (view as? ConversationRowView)?.selectionTint = selectionTint }
        }
    }

    private(set) var entries: [ConversationTableEntry] = []
    private var environment = EnvironmentValues()
    /// Height of a conversation line (they all reserve two preview lines) and of each header line, for `measuredWidth`.
    private var conversationHeight: CGFloat?
    private var headerHeights: [String: CGFloat] = [:]
    private var measuredWidth: CGFloat = 0
    private var applyingSelection = false
    private let sizer = NSHostingController(rootView: ConversationCellRoot(content: AnyView(EmptyView()),
                                                                         environment: EnvironmentValues(), header: false))

    override init() {
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = .zero
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.focusRingType = .none
        tableView.usesAutomaticRowHeights = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(clicked)
        tableView.setAccessibilityLabel("Danh sách trò chuyện")

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = false
        NotificationCenter.default.addObserver(self, selector: #selector(frameChanged), name: NSView.frameDidChangeNotification,
                                               object: scrollView)
        scrollView.postsFrameChangedNotifications = true
    }

    // MARK: Update

    func update(entries next: [ConversationTableEntry], selection: String?, environment: EnvironmentValues) {
        let envChanged = !Self.sameEnvironment(environment, self.environment)
        self.environment = environment
        if envChanged { conversationHeight = nil; headerHeights = [:] }
        let old = entries
        let oldIds = old.map(\.id)
        let newIds = next.map(\.id)
        entries = next

        if oldIds != newIds {
            apply(newIds.difference(from: oldIds))
        }
        // Re-root the visible lines whose data changed (and every header line, which reads column state).
        let oldById = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let visible = tableView.rows(in: tableView.visibleRect)
        var heightsChanged = IndexSet()
        for row in visible.lowerBound..<min(visible.upperBound, entries.count) {
            let entry = entries[row]
            guard envChanged || entry.refreshesAlways || oldById[entry.id] != entry,
                  let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ConversationCell else { continue }
            cell.configure(entry, content: rowContent(entry), environment: environment)
        }
        if envChanged {
            heightsChanged = IndexSet(integersIn: 0..<entries.count)
        } else {
            // Header lines are measured again, but the table only hears of the ones whose height really changed: noting any row
            // makes it recompute the offsets of all ~700 rows (≈16 ms), and SwiftUI calls this update several times for
            // changes that never touch the list (the inspector opening, the window resizing).
            for (row, entry) in entries.enumerated() where entry.refreshesAlways {
                let before = headerHeights[entry.id]
                headerHeights[entry.id] = nil
                if height(of: entry) != before { heightsChanged.insert(row) }
            }
        }
        if !heightsChanged.isEmpty {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                tableView.noteHeightOfRows(withIndexesChanged: heightsChanged)
            }
        }
        applySelection(selection)
    }

    private func apply(_ diff: CollectionDifference<String>) {
        tableView.beginUpdates()
        var removals = IndexSet()
        var insertions = IndexSet()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removals.insert(offset)
            case .insert(let offset, _, _): insertions.insert(offset)
            }
        }
        if !removals.isEmpty { tableView.removeRows(at: removals, withAnimation: []) }
        if !insertions.isEmpty { tableView.insertRows(at: insertions, withAnimation: []) }
        tableView.endUpdates()
    }

    private func applySelection(_ selection: String?) {
        let wanted = selection.flatMap { id in entries.firstIndex { $0.conversationId == id } }
        let current = tableView.selectedRow >= 0 ? tableView.selectedRow : nil
        guard wanted != current else { return }
        applyingSelection = true
        defer { applyingSelection = false }
        if let wanted {
            tableView.selectRowIndexes(IndexSet(integer: wanted), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
    }

    private static func sameEnvironment(_ a: EnvironmentValues, _ b: EnvironmentValues) -> Bool {
        a.colorScheme == b.colorScheme && a.dynamicTypeSize == b.dynamicTypeSize && a.controlActiveState == b.controlActiveState
    }

    @objc private func frameChanged() {
        let width = tableView.bounds.width
        guard abs(width - measuredWidth) > 0.5 else { return }
        conversationHeight = nil
        headerHeights = [:]
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<entries.count))
        }
    }

    // MARK: Heights

    private func height(of entry: ConversationTableEntry) -> CGFloat {
        let width = max(100, (tableView.tableColumns.first?.width ?? tableView.bounds.width) - 1)
        if abs(width - measuredWidth) > 0.5 {
            measuredWidth = width
            conversationHeight = nil
            headerHeights = [:]
        }
        switch entry {
        case .conversation:
            if let h = conversationHeight { return h }
            let h = measure(entry, width: width)
            conversationHeight = h
            return h
        default:
            if let h = headerHeights[entry.id] { return h }
            let h = measure(entry, width: width)
            headerHeights[entry.id] = h
            return h
        }
    }

    private func measure(_ entry: ConversationTableEntry, width: CGFloat) -> CGFloat {
        sizer.rootView = ConversationCellRoot(content: rowContent(entry), environment: environment,
                                              header: entry.isHeader)
        let size = sizer.sizeThatFits(in: CGSize(width: width, height: 10_000))
        return max(1, ceil(size.height))
    }

    // MARK: Data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < entries.count else { return 1 }
        return height(of: entries[row])
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        let cell = (tableView.makeView(withIdentifier: ConversationCell.identifier, owner: self) as? ConversationCell) ?? ConversationCell()
        let entry = entries[row]
        cell.configure(entry, content: rowContent(entry), environment: environment)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = (tableView.makeView(withIdentifier: ConversationRowView.identifier, owner: self) as? ConversationRowView)
            ?? { let v = ConversationRowView(); v.identifier = ConversationRowView.identifier; return v }()
        var separator = false
        if row < entries.count, case .conversation = entries[row] { separator = true }
        if row < entries.count, case .strangerBox = entries[row] { separator = true }
        view.drawsSeparatorLine = separator
        view.selectionTint = selectionTint
        view.needsDisplay = true
        return view
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        row < entries.count && entries[row].conversationId != nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < entries.count, let id = entries[row].conversationId else { return }
        // After the table's own bookkeeping: the selection reaches SwiftUI, which updates this table again.
        DispatchQueue.main.async { [onSelect] in onSelect(id) }
    }

    func tableView(_ tableView: NSTableView, rowActionsForRow row: Int, edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
        guard row < entries.count, let id = entries[row].conversationId else { return [] }
        return swipeActions(id, edge)
    }

    @objc private func clicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < entries.count, entries[row].conversationId == nil else { return }
        onActivate(entries[row])
    }

    // MARK: Testing

    var debugRowCount: Int { tableView.numberOfRows }
}
