import AppKit
import SwiftUI

// The chat's message list, AppKit-backed (the approach of Telegram for macOS: a scroll view whose rows have known heights).
//
// A SwiftUI `ScrollView` + `LazyVStack` re-ran lazy placement for every frame of a scroll: measuring, placing and diffing
// the realized rows took ~70% of the main thread while dragging through history (see docs/chat-scroll-perf.md), too much
// for 120 Hz. Here each row is still the SwiftUI `MessageRow`, hosted in its own `NSHostingController`, but:
// - a row is measured once (height for the column width, memoized per message), ahead of the viewport and on idle,
//   never per frame; scrolling only moves layers;
// - rows are placed by plain frames in a flipped document view (no Auto Layout, no lazy-stack diffing);
// - only rows on screen (and a margin) are in the window; hosts are kept per message (LRU) and recycled per kind, so
//   scrolling back re-attaches a ready row and a new row usually re-roots an existing graph of the same shape;
// - nothing else follows the scroll: rows ignore the pointer while the list moves (`ChatScrollActivity`);
// - every change (new page above, new message, a row whose image arrived) keeps the row under the reader's eye where it
//   was, so prepending history never jumps.

/// The reply / react callbacks of the rows (a stable reference, so updating them never re-renders a row).
@MainActor
final class ChatRowActions {
    var reply: (ChatMessage) -> Void = { _ in }
    var react: (String, ChatMessage) -> Void = { _, _ in }
    /// "Chọn nhiều tin nhắn": a click on a row (message id, SHIFT held).
    var select: (String, Bool) -> Void = { _, _ in }
}

/// What one row shows.
struct ChatRowModel: Equatable {
    var row: ChatRow
    var isGroup: Bool
    var isNewest: Bool
    var isHighlighted: Bool
    /// A poll event row that is the newest event of its poll in the list: it carries the poll card (taller).
    var showsPollCard = false
    /// "Chọn nhiều tin nhắn" is on: message rows get a check column (narrower bubbles, so a new height).
    var isSelecting = false
    var isSelected = false

    /// Same height: newest / highlighted / selected only change a background; the poll card and the check column change it.
    func sameLayout(as other: ChatRowModel) -> Bool {
        row == other.row && isGroup == other.isGroup && showsPollCard == other.showsPollCard && isSelecting == other.isSelecting
    }

    /// Rows of one kind share hosts: re-rooting a host with a row of the same structure is a cheap SwiftUI update.
    var reuseKind: Int {
        switch row.kind {
        case .day: 0
        case .message(let m, _, _, _):
            switch m.kind {
            case .text: m.quote == nil ? 1 : 2
            case .photo: 3
            case .sticker: 4
            case .system, .notice, .ecard: 5
            default: 6
            }
        }
    }
}

/// The SwiftUI content of one row: a day separator or a message, with the list's side margins, at its natural height.
///
/// A row whose content changes size on its own (an image arrived, a file card's note) is noticed through its hosting
/// controller's `preferredContentSize`, not a geometry reader: an `onGeometryChange` per row was re-evaluated for every
/// row on every scroll step (~25% of the work of a scroll frame).
struct ChatRowContent: View {
    let model: ChatRowModel
    let actions: ChatRowActions
    let environment: EnvironmentValues

    var body: some View {
        content
            .padding(.horizontal, 16)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.self, environment)
    }

    @ViewBuilder
    private var content: some View {
        switch model.row.kind {
        case .day(let date):
            DaySeparator(date: date)
        case .message(let m, _, _, _) where model.isSelecting && m.isSelectable:
            let actions = actions
            // A plain button (not a tap gesture): clicks and VoiceOver / accessibility "press" both toggle the row.
            Button {
                actions.select(m.id, NSEvent.modifierFlags.contains(.shift))
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: model.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(model.isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .accessibilityHidden(true)
                    messageRow(m).allowsHitTesting(false)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(model.isSelected ? .isSelected : [])
        case .message(let m, _, _, _):
            messageRow(m)
        }
    }

    @ViewBuilder
    private func messageRow(_ m: ChatMessage) -> some View {
        if case .message(_, let first, let last, let status) = model.row.kind {
            let actions = actions
            MessageRow(message: m, isGroup: model.isGroup, firstInGroup: first, lastInGroup: last, showStatus: status,
                       isNewest: model.isNewest,
                       showsPollCard: model.showsPollCard,
                       onReply: { actions.reply($0) },
                       onReact: { actions.react($0, $1) })
                .equatable()
                .background {
                    if model.isHighlighted {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.accentColor.opacity(0.14))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
                            }
                            .padding(.horizontal, -4)
                            .padding(.vertical, 1)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: model.isHighlighted)
        }
    }
}

/// Whether a message list is moving. Rows ignore the pointer entering them meanwhile: otherwise every row that passes under
/// a resting pointer shows and hides its hover bar (a glass capsule, animated), which was about half of the work of a scroll
/// frame. Hover comes back with the next mouse move once the list has stopped.
@MainActor
enum ChatScrollActivity {
    private(set) static var lastScroll: CFTimeInterval = 0
    static var isScrolling: Bool { CACurrentMediaTime() - lastScroll < 0.15 }
    static func noteScroll() { lastScroll = CACurrentMediaTime() }
}

/// Imperative scrolling for the SwiftUI side (`MessageList`).
@MainActor
final class ChatListCommands {
    fileprivate weak var controller: ChatListController?
    func scrollToBottom(animated: Bool) { controller?.scrollToBottom(animated: animated) }
    /// Brings the row on screen, centered.
    func scrollTo(_ id: String, animated: Bool) { controller?.scrollTo(id, animated: animated) }
}

/// Scroll position the list reports (only when one of the values changed).
struct ChatListMetrics: Equatable {
    /// Distance from the content top to the top of the visible area.
    var top: CGFloat
    var fromBottom: CGFloat
    var content: CGFloat
    var visible: CGFloat
}

struct ChatListView: NSViewRepresentable {
    let conversationId: String
    let rows: [ChatRow]
    let isGroup: Bool
    let newestId: String?
    let highlightedId: String?
    /// "Chọn nhiều tin nhắn" of this conversation, if on.
    var selection: MessageSelection? = nil
    let loadingOlder: Bool
    /// Room the bars over the list take (the list scrolls under them).
    let insets: EdgeInsets
    let commands: ChatListCommands
    let onReply: (ChatMessage) -> Void
    let onReact: (String, ChatMessage) -> Void
    var onSelect: (String, Bool) -> Void = { _, _ in }
    let onMetrics: (ChatListMetrics) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let controller = ChatListController()
        context.coordinator.controller = controller
        commands.controller = controller
        return controller.scrollView
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let controller = context.coordinator.controller else { return }
        commands.controller = controller
        controller.actions.reply = onReply
        controller.actions.react = onReact
        controller.actions.select = onSelect
        controller.onMetrics = onMetrics
        controller.update(conversationId: conversationId, rows: rows, isGroup: isGroup, newestId: newestId,
                          highlightedId: highlightedId, selection: selection, loadingOlder: loadingOlder, insets: insets,
                          environment: context.environment)
    }

    /// Takes whatever it is offered. Without this SwiftUI asks the scroll view for its Auto Layout fitting size, which walks
    /// every row host in the document.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 300, height: proposal.height ?? 300)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.controller?.teardown()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        var controller: ChatListController?
    }
}

// MARK: - Controller

@MainActor
final class ChatListController: NSObject {
    /// Top-left origin, so row frames read like the list.
    final class DocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    private final class Host {
        let controller: NSHostingController<ChatRowContent>
        var id: String = ""
        var model: ChatRowModel
        var lastUse = 0
        var sizeObservation: NSKeyValueObservation?
        init(controller: NSHostingController<ChatRowContent>, model: ChatRowModel) {
            self.controller = controller
            self.model = model
        }
        var view: NSView { controller.view }
    }

    private enum Anchor {
        case bottom
        /// The row and its top relative to the clip origin.
        case row(String, CGFloat)
    }

    let scrollView = ChatScrollView()
    let document = DocumentView()
    let actions = ChatRowActions()
    var onMetrics: ((ChatListMetrics) -> Void)?

    private static let topPadding: CGFloat = 8
    private static let bottomPadding: CGFloat = 8
    private static let spinnerHeight: CGFloat = 36
    private static let hostLimit = 120
    /// Time a tile may spend measuring rows that are not on screen yet.
    private static let measureBudget: CFTimeInterval = 0.003
    private static let attachMargin: CGFloat = 160

    private var conversationId: String?
    private var models: [ChatRowModel] = []
    private var heights: [CGFloat] = []
    private var exact: [Bool] = []
    private var tops: [CGFloat] = []
    private var indexById: [String: Int] = [:]
    private var contentHeight: CGFloat = 0
    /// Natural heights, by row id, for the model and width they were measured at (survives list rebuilds).
    private var memo: [String: (model: ChatRowModel, width: CGFloat, height: CGFloat)] = [:]
    private var hosts: [String: Host] = [:]
    private var spare: [Int: [Host]] = [:]
    private var useClock = 0
    private var width: CGFloat = 0
    private var environment = EnvironmentValues()
    private var layoutSignature: [AnyHashable] = []
    private var insets = NSEdgeInsets()
    private var loadingOlder = false
    private var spinnerHost: NSHostingView<AnyView>?
    private var tiling = false
    private var attachedIds: Set<String> = []
    private var applyingUpdate = false
    private var lastMetrics: ChatListMetrics?
    private var lastScrollTime: CFTimeInterval = 0
    private var idleScheduled = false
    private var sizers: [Int: NSHostingController<ChatRowContent>] = [:]
    /// The list is scrolled to its end; it stays there through size changes until the reader scrolls away.
    private var stuckToBottom = true
    private var lastClipSize: NSSize = .zero
    /// A chat was just opened: it shows its newest rows as soon as the list has a width.
    private var needsInitialPosition = false
    /// Swipe to reply: the row being swiped and its horizontal shift.
    private var swipeShift: (id: String, x: CGFloat)?
    private var swipe: ChatSwipeReplyTracker?

    /// The controller of a list's scroll view (benchmark / probes).
    static func forScrollView(_ view: NSScrollView) -> ChatListController? {
        objc_getAssociatedObject(view, &controllerKey) as? ChatListController
    }
    nonisolated(unsafe) private static var controllerKey: UInt8 = 0

    override init() {
        super.init()
        objc_setAssociatedObject(scrollView, &Self.controllerKey, self, .OBJC_ASSOCIATION_ASSIGN)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        scrollView.identifier = NSUserInterfaceItemIdentifier("chat-message-list")
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.postsFrameChangedNotifications = true
        document.autoresizingMask = [.width]
        scrollView.documentView = document
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(frameChanged), name: NSView.frameDidChangeNotification, object: scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(rowSizeChanged(_:)), name: Self.rowSizeChangedNotification, object: nil)
        setUpSwipeReply()
    }

    /// Posted by a row whose content changes height on its own (a poll card whose detail arrived), `object` = message id.
    /// `preferredContentSize` of the row host does not report these changes.
    static let rowSizeChangedNotification = Notification.Name("OlazChatRowSizeChanged")

    @objc private func rowSizeChanged(_ note: Notification) {
        guard let id = note.object as? String, indexById[id] != nil, hosts[id] != nil else { return }
        rowContentChanged(id)
    }

    private func setUpSwipeReply() {
        let swipe = ChatSwipeReplyTracker(scrollView: scrollView, document: document)
        swipe.rowAt = { [unowned self] event in self.swipeableRow(at: document.convert(event.locationInWindow, from: nil)) }
        swipe.rowFrame = { [unowned self] id in hosts[id]?.view.superview === document ? rowFrame(id) : nil }
        swipe.setShift = { [unowned self] id, x, animated in shiftRow(id, by: x, animated: animated) }
        swipe.reply = { [unowned self] id in
            guard let i = indexById[id], case .message(let m, _, _, _) = models[i].row.kind else { return }
            actions.reply(m)
        }
        self.swipe = swipe
    }

    /// The message under `point` (document coordinates) when it is on screen and can be replied to (as the context menu's
    /// "Trả lời": bubbles, not notices or recalled messages).
    private func swipeableRow(at point: NSPoint) -> String? {
        let i = firstRow(below: point.y)
        guard i < models.count, tops[i] <= point.y, !models[i].isSelecting,
              case .message(let m, _, _, _) = models[i].row.kind else { return nil }
        switch m.kind {
        case .system, .notice, .ecard, .poll, .recalled: return nil
        default: break
        }
        let id = models[i].row.id
        return hosts[id]?.view.superview === document ? id : nil
    }

    private func rowFrame(_ id: String) -> NSRect? {
        guard let i = indexById[id] else { return nil }
        return NSRect(x: id == swipeShift?.id ? swipeShift?.x ?? 0 : 0, y: tops[i], width: width, height: heights[i])
    }

    private func shiftRow(_ id: String, by x: CGFloat, animated: Bool) {
        swipeShift = x == 0 ? nil : (id, x)
        guard let host = hosts[id], let frame = rowFrame(id) else { return }
        guard animated else { host.view.frame = frame; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            // A little overshoot: the bubble springs back.
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.35, 0.5, 1)
            context.allowsImplicitAnimation = true
            host.view.animator().frame = frame
        }
    }

    func teardown() {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Update from SwiftUI

    func update(conversationId: String, rows: [ChatRow], isGroup: Bool, newestId: String?, highlightedId: String?,
                selection: MessageSelection? = nil, loadingOlder: Bool, insets: EdgeInsets, environment: EnvironmentValues) {
        applyingUpdate = true
        defer { applyingUpdate = false }
        self.environment = environment
        let ns = NSEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0)
        if ns.top != self.insets.top || ns.bottom != self.insets.bottom {
            let anchor = captureAnchor()
            // The bars' room is padding inside the document (NSClipView would clamp the origin with insets of its own).
            self.insets = ns
            scrollView.scrollerInsets = ns
            rebuildTops()
            restore(anchor)
            tile()
        }
        let signature: [AnyHashable] = [environment.olazTextScale, UserDefaults.standard.string(forKey: OlazPrefs.wallpaper) ?? "",
                                        environment.colorScheme == .dark, environment.locale.identifier]
        let environmentChanged = signature != layoutSignature
        if environmentChanged {
            layoutSignature = signature
            memo.removeAll()
        }

        // The newest event of each poll shows its card (official list: one card per poll, under its last event).
        var newestPollEvent: [String: String] = [:]
        for row in rows {
            if case .message(let m, _, _, _) = row.kind, case .poll(let info) = m.kind, !info.pollId.isEmpty {
                newestPollEvent[info.pollId] = m.id
            }
        }
        let newModels = rows.map { row -> ChatRowModel in
            let id: String? = if case .message(let m, _, _, _) = row.kind { m.id } else { nil }
            var showsPollCard = false
            if case .message(let m, _, _, _) = row.kind, case .poll(let info) = m.kind {
                showsPollCard = info.pollId.isEmpty || newestPollEvent[info.pollId] == m.id
            }
            return ChatRowModel(row: row, isGroup: isGroup, isNewest: id != nil && id == newestId,
                                isHighlighted: id != nil && id == highlightedId, showsPollCard: showsPollCard,
                                isSelecting: selection != nil, isSelected: id.map { selection?.contains($0) ?? false } ?? false)
        }

        if conversationId != self.conversationId {
            self.conversationId = conversationId
            resetForConversation()
            self.loadingOlder = loadingOlder
            needsInitialPosition = true
            updateWidth()
            apply(newModels, anchor: nil)
            positionIfNeeded()
            return
        }

        if environmentChanged {
            for host in hosts.values { host.controller.rootView = content(for: host.model, id: host.id) }
            for i in exact.indices { exact[i] = false }
        }
        if loadingOlder == self.loadingOlder, !environmentChanged, applyInPlace(newModels) { return }
        let anchor = captureAnchor(appending: newModels.last?.row.id != models.last?.row.id)
        self.loadingOlder = loadingOlder
        apply(newModels, anchor: anchor)
    }

    /// The common live updates without rebuilding the list: the same rows with some changed (a reaction, a status, the
    /// newest flag), possibly with new rows after them (messages arriving). Returns false when rows were inserted
    /// elsewhere or removed (`apply` handles those).
    private func applyInPlace(_ newModels: [ChatRowModel]) -> Bool {
        guard newModels.count >= models.count else { return false }
        var changed: [Int] = []
        for i in models.indices {
            let old = models[i], new = newModels[i]
            guard old.row.id == new.row.id else { return false }
            if old != new { changed.append(i) }
        }
        let appended = newModels.count - models.count
        guard !changed.isEmpty || appended > 0 else { return true }
        let anchor = captureAnchor(appending: appended > 0)
        var heightChanged = false
        for i in changed {
            let model = newModels[i]
            if !models[i].sameLayout(as: model) {
                exact[i] = false
                heightChanged = true
            }
            models[i] = model
            if let host = hosts[model.row.id] {
                host.model = model
                host.controller.rootView = content(for: model, id: model.row.id)
            }
        }
        for i in models.count..<newModels.count {
            let model = newModels[i]
            indexById[model.row.id] = i
            models.append(model)
            heights.append(Self.estimate(model, width: width))
            exact.append(false)
        }
        if heightChanged || appended > 0 {
            rebuildTops()
            restore(anchor)
        }
        tile()
        return true
    }

    /// Installs a new row list (heights from the memo where the row is unchanged), refreshes hosts whose row changed, and
    /// keeps `anchor` where it was.
    private func apply(_ newModels: [ChatRowModel], anchor: Anchor?) {
        let oldHeights = Dictionary(uniqueKeysWithValues: zip(models.map(\.row.id), heights))
        models = newModels
        indexById = Dictionary(uniqueKeysWithValues: newModels.enumerated().map { ($1.row.id, $0) })
        heights = []
        exact = []
        heights.reserveCapacity(newModels.count)
        exact.reserveCapacity(newModels.count)
        for model in newModels {
            let id = model.row.id
            if let m = memo[id], m.width == width, m.model.sameLayout(as: model) {
                heights.append(m.height)
                exact.append(true)
            } else {
                heights.append(oldHeights[id] ?? Self.estimate(model, width: width))
                exact.append(false)
            }
            if let host = hosts[id], host.model != model {
                host.model = model
                host.controller.rootView = content(for: model, id: id)
            }
        }
        // Hosts of rows that are gone.
        for (id, host) in hosts where indexById[id] == nil {
            recycle(host)
            hosts[id] = nil
        }
        updateSpinner()
        rebuildTops()
        if let anchor { restore(anchor) }
        tile()
    }

    private func resetForConversation() {
        swipe?.cancel()
        for host in hosts.values { recycle(host) }
        hosts.removeAll()
        attachedIds.removeAll()
        memo.removeAll()
        models = []
        heights = []
        exact = []
        tops = []
        indexById = [:]
        lastMetrics = nil
        stuckToBottom = true
    }

    // MARK: Geometry

    private var clip: NSClipView { scrollView.contentView }

    private func rebuildTops() {
        tops.removeAll(keepingCapacity: true)
        tops.reserveCapacity(heights.count)
        var y = insets.top + Self.topPadding + (loadingOlder ? Self.spinnerHeight : 0)
        for h in heights {
            tops.append(y)
            y += h
        }
        contentHeight = y + Self.bottomPadding + insets.bottom
        let size = NSSize(width: clip.bounds.width, height: contentHeight)
        if document.frame.size != size { document.setFrameSize(size) }
    }

    private var minOriginY: CGFloat { 0 }
    private var maxOriginY: CGFloat { max(0, contentHeight - clip.bounds.height) }

    private func setOrigin(_ y: CGFloat) {
        let target = min(max(y, minOriginY), maxOriginY)
        if abs(clip.bounds.origin.y - target) < 0.01 { return }
        clip.setBoundsOrigin(NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(clip)
    }

    /// First row whose bottom is below `y`.
    private func firstRow(below y: CGFloat) -> Int {
        var lo = 0, hi = tops.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if tops[mid] + heights[mid] <= y { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func captureAnchor(appending: Bool = false) -> Anchor? {
        guard !models.isEmpty else { return nil }
        let origin = clip.bounds.origin.y
        // At the bottom, stay there (a row whose image arrived grows upward, the window got taller); a new message is
        // brought in by the caller.
        if !appending, stuckToBottom { return .bottom }
        let visibleTop = origin + insets.top
        let i = min(firstRow(below: visibleTop), models.count - 1)
        return .row(models[i].row.id, tops[i] - origin)
    }

    private func restore(_ anchor: Anchor?) {
        switch anchor {
        case .bottom: setOrigin(maxOriginY)
        case .row(let id, let offset):
            if let i = indexById[id] { setOrigin(tops[i] - offset) }
        case nil: break
        }
    }

    private func updateWidth() {
        let w = clip.bounds.width
        guard w > 0, w != width else { return }
        width = w
        for i in exact.indices { exact[i] = false }
    }

    @objc private func frameChanged() {
        if clip.bounds.size != lastClipSize { resized() }
    }

    /// The clip view changed size. Its bounds already have the new size, so whether the list was at the bottom comes from
    /// `stuckToBottom`, recorded before.
    private func resized() {
        let anchor = captureAnchor()
        lastClipSize = clip.bounds.size
        updateWidth()
        rebuildTops()
        if needsInitialPosition { positionIfNeeded(); return }
        restore(anchor)
        tile()
    }

    private func positionIfNeeded() {
        guard needsInitialPosition, width > 0 else { return }
        needsInitialPosition = false
        measureFromBottom()
        setOrigin(maxOriginY)
        tile()
    }

    @objc private func boundsChanged() {
        guard !tiling else { return }
        if clip.bounds.size != lastClipSize { resized(); return }
        if !applyingUpdate {
            lastScrollTime = CACurrentMediaTime()
            ChatScrollActivity.noteScroll()
        }
        stuckToBottom = maxOriginY - clip.bounds.origin.y < 1
        tile()
    }

    // MARK: Measuring

    private func content(for model: ChatRowModel, id: String) -> ChatRowContent {
        ChatRowContent(model: model, actions: actions, environment: environment)
    }

    private static func pixelRound(_ h: CGFloat) -> CGFloat { (h * 2).rounded(.up) / 2 }

    private func measure(_ i: Int, with controller: NSHostingController<ChatRowContent>) -> CGFloat {
        let h = Self.pixelRound(controller.sizeThatFits(in: CGSize(width: width, height: 100_000)).height)
        let model = models[i]
        memo[model.row.id] = (model, width, h)
        return h
    }

    /// Measures row `i` (with its host when it has one, else a shared sizing host); returns whether its height changed.
    @discardableResult
    private func measureRow(_ i: Int, creatingHost: Bool = false) -> Bool {
        let model = models[i]
        let h: CGFloat
        if let host = creatingHost ? host(for: model) : hosts[model.row.id] {
            h = measure(i, with: host.controller)
        } else {
            let sizer = sizers[model.reuseKind] ?? makeController(model, id: model.row.id)
            sizers[model.reuseKind] = sizer
            sizer.rootView = content(for: model, id: "")
            h = measure(i, with: sizer)
        }
        exact[i] = true
        if abs(h - heights[i]) < 0.25 { return false }
        heights[i] = h
        return true
    }

    /// Opening a chat: the rows that fill the screen from the bottom up get their real heights first.
    private func measureFromBottom() {
        guard width > 0 else { return }
        var filled: CGFloat = 0
        let need = max(clip.bounds.height, 600) * 1.5
        var i = models.count - 1
        while i >= 0, filled < need {
            if !exact[i] { measureRow(i) }
            filled += heights[i]
            i -= 1
        }
        rebuildTops()
    }

    /// A row's content changed size on its own (image loaded, note shown): measured again once the current pass is over.
    private func rowContentChanged(_ id: String) {
        guard pendingRemeasure.insert(id).inserted, pendingRemeasure.count == 1 else { return }
        DispatchQueue.main.async { [weak self] in self?.remeasurePending() }
    }

    private var pendingRemeasure: Set<String> = []

    private func contentSizeChanged(of controller: NSHostingController<ChatRowContent>) {
        guard let host = hosts.values.first(where: { $0.controller === controller }), host.view.superview != nil else { return }
        rowContentChanged(host.id)
    }

    private func remeasurePending() {
        let ids = pendingRemeasure
        pendingRemeasure.removeAll()
        guard !tiling, width > 0 else { return }
        let anchor = captureAnchor()
        var dirty = false
        for id in ids {
            guard let i = indexById[id], hosts[id] != nil else { continue }
            if measureRow(i) { dirty = true }
        }
        guard dirty else { return }
        rebuildTops()
        restore(anchor)
        tile()
    }

    /// Cheap stand-in until a row is measured (only rows far from the screen ever use it).
    private static func estimate(_ model: ChatRowModel, width: CGFloat) -> CGFloat {
        switch model.row.kind {
        case .day: return 44
        case .message(let m, let first, _, _):
            let top: CGFloat = (first ? 8 : 2) + (m.reactions.isEmpty ? 0 : 10)
            switch m.kind {
            case .text:
                let chars = CGFloat(m.text.count)
                let perLine = max(20, (min(width - 32 - 100, 520) - 24) / 7.4)
                return top + 18 + ceil(chars / perLine) * 18 + (m.quote == nil ? 0 : 44)
            case .photo(_, let w, let h):
                guard w > 0, h > 0 else { return top + 180 }
                let scale = min(280 / CGFloat(w), 340 / CGFloat(h), 1.5)
                return top + max(60, CGFloat(h) * scale)
            case .sticker: return top + 130
            case .video: return top + 160
            case .system, .notice: return 40
            default: return top + 64
            }
        }
    }

    // MARK: Tiling

    /// Rows within this distance of the screen are measured and attached ahead of time.
    private var overscan: CGFloat { max(400, clip.bounds.height) }

    private func tile() {
        guard !tiling, width > 0, !models.isEmpty || spinnerHost != nil else { reportMetrics(); return }
        tiling = true
        defer { tiling = false }
        // 1. Real heights for every row about to be shown (a few rows per frame while scrolling into unseen history), measured
        //    with the host that will show them. Rows above the anchor that change height move the origin with them, so
        //    nothing on screen shifts.
        //    Rows that are (nearly) on screen are always measured; those further out within a small time budget per frame, so a
        //    page of history landing above does not cost one long frame.
        let start = CACurrentMediaTime()
        for _ in 0..<4 {
            let b = clip.bounds
            let near = (b.minY - Self.attachMargin)...(b.maxY + Self.attachMargin)
            var i = firstRow(below: b.minY - overscan)
            var dirty = false
            let anchor = captureAnchor()
            while i < models.count, tops[i] < b.maxY + overscan {
                if !exact[i] {
                    let onScreen = near.overlaps(tops[i]...(tops[i] + heights[i]))
                    if onScreen || CACurrentMediaTime() - start < Self.measureBudget {
                        if measureRow(i, creatingHost: true) { dirty = true }
                    }
                }
                i += 1
            }
            guard dirty else { break }
            rebuildTops()
            restore(anchor)
        }
        // 2. Only rows on screen (and a little beyond) are in the window: every hosting view in the window is laid out again
        //    on each scroll step, so the cost of a frame grows with their number. The others keep their host, detached.
        let b = clip.bounds
        useClock += 1
        let lo = b.minY - Self.attachMargin, hi = b.maxY + Self.attachMargin
        var wanted: Set<String> = []
        var i = firstRow(below: lo)
        while i < models.count, tops[i] < hi {
            let host = host(for: models[i])
            host.lastUse = useClock
            let frame = NSRect(x: swipeX(models[i].row.id), y: tops[i], width: width, height: heights[i])
            if host.view.frame != frame { host.view.frame = frame }
            if host.view.superview !== document { document.addSubview(host.view) }
            wanted.insert(models[i].row.id)
            i += 1
        }
        // A little hysteresis, so a row on the edge is not detached and attached again on every small move.
        for id in attachedIds where !wanted.contains(id) {
            guard let host = hosts[id] else { continue }
            if let idx = indexById[id], tops[idx] + heights[idx] > lo - Self.attachMargin, tops[idx] < hi + Self.attachMargin {
                let frame = NSRect(x: swipeX(id), y: tops[idx], width: width, height: heights[idx])
                if host.view.frame != frame { host.view.frame = frame }
                wanted.insert(id)
            } else {
                host.view.removeFromSuperview()
            }
        }
        attachedIds = wanted
        trimHosts()
        if let spinnerHost {
            spinnerHost.frame = NSRect(x: 0, y: insets.top + Self.topPadding, width: width, height: Self.spinnerHeight)
        }
        stuckToBottom = maxOriginY - clip.bounds.origin.y < 1
        reportMetrics()
        scheduleIdleMeasuring()
    }

    private func swipeX(_ id: String) -> CGFloat { id == swipeShift?.id ? swipeShift?.x ?? 0 : 0 }

    private func host(for model: ChatRowModel) -> Host {
        let id = model.row.id
        // A host's row is kept current by `apply`.
        if let host = hosts[id] { return host }
        let host: Host
        if var pool = spare[model.reuseKind], let reused = pool.popLast() {
            spare[model.reuseKind] = pool
            host = reused
            host.model = model
            host.controller.rootView = content(for: model, id: id)
        } else {
            host = Host(controller: makeController(model, id: id, observesSize: true), model: model)
            host.sizeObservation = host.controller.observe(\.preferredContentSize, options: [.new]) { [weak self] controller, _ in
                nonisolated(unsafe) let controller = controller
                MainActor.assumeIsolated { self?.contentSizeChanged(of: controller) }
            }
        }
        host.id = id
        host.lastUse = useClock
        hosts[id] = host
        return host
    }

    private func makeController(_ model: ChatRowModel, id: String, observesSize: Bool = false) -> NSHostingController<ChatRowContent> {
        let controller = NSHostingController(rootView: content(for: model, id: id))
        controller.sizingOptions = observesSize ? [.preferredContentSize] : []
        controller.safeAreaRegions = []
        controller.view.translatesAutoresizingMaskIntoConstraints = true
        controller.view.autoresizingMask = []
        return controller
    }

    /// Keeps a few hosts per kind for the next new rows; drops the rest.
    private func recycle(_ host: Host) {
        host.view.removeFromSuperview()
        attachedIds.remove(host.id)
        let kind = host.model.reuseKind
        if spare[kind, default: []].count < 12 { spare[kind, default: []].append(host) }
    }

    /// Evicts the least recently shown hosts (in batches, so the sort runs rarely), never one shown this pass.
    private func trimHosts() {
        guard hosts.count > Self.hostLimit + 40 else { return }
        let idle = hosts.values.filter { !attachedIds.contains($0.id) }.sorted { $0.lastUse < $1.lastUse }
        for host in idle.prefix(hosts.count - Self.hostLimit) {
            hosts[host.id] = nil
            recycle(host)
        }
    }

    private func updateSpinner() {
        if loadingOlder, spinnerHost == nil {
            let host = NSHostingView(rootView: AnyView(ProgressView().controlSize(.small).frame(maxWidth: .infinity)))
            host.sizingOptions = []
            host.safeAreaRegions = []
            document.addSubview(host)
            spinnerHost = host
        } else if !loadingOlder, let host = spinnerHost {
            host.removeFromSuperview()
            spinnerHost = nil
        }
    }

    /// Measures the rest of the chat in small slices while nothing scrolls, nearest rows first, so scrolling into history
    /// rarely needs to measure anything.
    private func scheduleIdleMeasuring() {
        guard !idleScheduled, exact.contains(false) else { return }
        idleScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.idleScheduled = false
            self.measureIdleSlice()
        }
    }

    private func measureIdleSlice() {
        guard width > 0, !tiling, !models.isEmpty else { return }
        if CACurrentMediaTime() - lastScrollTime < 0.25 { scheduleIdleMeasuring(); return }
        let start = CACurrentMediaTime()
        let center = min(firstRow(below: clip.bounds.midY), models.count - 1)
        var up = center, down = center + 1
        var dirty = false
        let anchor = captureAnchor()
        while CACurrentMediaTime() - start < 0.004, up >= 0 || down < models.count {
            if up >= 0 {
                if !exact[up], measureRow(up) { dirty = true }
                up -= 1
            }
            if down < models.count {
                if !exact[down], measureRow(down) { dirty = true }
                down += 1
            }
        }
        if dirty {
            rebuildTops()
            restore(anchor)
        }
        scheduleIdleMeasuring()
    }

    // MARK: Scrolling

    private func reportMetrics() {
        let b = clip.bounds
        let m = ChatListMetrics(top: b.minY, fromBottom: contentHeight - b.maxY,
                                content: contentHeight - insets.top - insets.bottom, visible: b.height - insets.top - insets.bottom)
        guard m != lastMetrics else { return }
        lastMetrics = m
        guard let onMetrics else { return }
        if applyingUpdate {
            DispatchQueue.main.async { onMetrics(m) }
        } else {
            onMetrics(m)
        }
    }

    func scrollToBottom(animated: Bool) {
        guard !models.isEmpty else { return }
        measureFromBottom()
        animate(to: maxOriginY, animated: animated)
    }

    func scrollTo(_ id: String, animated: Bool) {
        guard let target = indexById[id] else { return }
        // Real heights from here to the target first, so the target lands where it is aimed.
        let current = min(firstRow(below: clip.bounds.midY), models.count - 1)
        let range = min(current, target)...max(current, target)
        let far = range.count > 60
        let anchor = captureAnchor()
        for i in (far ? max(0, target - 15)...min(models.count - 1, target + 15) : range) where !exact[i] { measureRow(i) }
        rebuildTops()
        restore(anchor)
        let visible = clip.bounds.height - insets.top - insets.bottom
        let y = tops[target] + heights[target] / 2 - visible / 2 - insets.top
        animate(to: y, animated: animated && !far)
    }

    private func animate(to y: CGFloat, animated: Bool) {
        let target = min(max(y, minOriginY), maxOriginY)
        guard animated, window != nil else {
            setOrigin(target)
            tile()
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            clip.animator().setBoundsOrigin(NSPoint(x: 0, y: target))
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.scrollView.reflectScrolledClipView(self.clip)
            self.tile()
        }
    }

    private var window: NSWindow? { scrollView.window }

    // MARK: Inspection (tests)

    /// Where row `id` starts, relative to the top of the clip view (nil when there is no such row).
    func offsetOnScreen(of id: String) -> CGFloat? {
        indexById[id].map { tops[$0] - clip.bounds.origin.y }
    }

    /// Geometry summary for the scroll benchmark's log (no message content).
    var debugGeometry: String {
        String(format: "rows=%d content=%.0f clip=%.0f origin=%.1f max=%.1f insets=%.0f/%.0f hosts=%d attached=%d",
               models.count, contentHeight, clip.bounds.height, clip.bounds.origin.y, maxOriginY, insets.top, insets.bottom,
               hosts.count, attachedIds.count)
    }

    /// Scrolled to the end (within a point).
    var isAtBottom: Bool { maxOriginY - clip.bounds.origin.y < 1 }

    /// Scrolls so that the content offset `y` is at the top of the clip view (as a reader would).
    func scrollForTesting(to y: CGFloat) {
        setOrigin(y)
    }
}
