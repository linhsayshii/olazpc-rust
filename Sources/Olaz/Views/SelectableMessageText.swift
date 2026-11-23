import AppKit
import SwiftUI

// Selectable message text.
//
// SwiftUI's `.textSelection(.enabled)` was tried first and does not fit a chat: a click elsewhere never clears the
// selection, and a right-click on the text always shows the system text menu, so the message menu (reply, forward, pin…)
// is gone. A live `NSTextView` per bubble worked but cost the scroll bench ~1 ms of main thread per frame and doubled the
// dropped frames. So the bubble keeps drawing (and sizing) its SwiftUI `Text` exactly as before, with an empty, transparent
// `MessageTextSelectionView` laid over it. Only when the pointer goes down on it does that view put a non-editable
// `NSTextView` with the same text, laid out the same way but drawn in a clear color, on top: AppKit then does drag /
// double-click (word) / triple-click (paragraph) selection, link clicks and ⌘C, and the text view only paints the
// translucent selection highlight over the SwiftUI glyphs. Once nothing is selected any more, the text view goes away.
// - a right-click on the selection offers "Copy"; anywhere else the event goes on to the row's SwiftUI `.contextMenu`;
// - a click anywhere outside the selected text clears it (one shared local event monitor);
// - a click that selects nothing (a link, a tap on the bubble) hands keyboard focus back to where it was (the composer).

/// The AppKit form of one bubble's text (same font, links and mentions as the SwiftUI `Text`), cached by the builder
/// (`ChatFormat.messageText`).
@MainActor
final class MessageText {
    let attributed: NSAttributedString
    private var sizes: [CGFloat: CGSize] = [:]
    private var linkRectsCache: (width: CGFloat, rects: [CGRect])?

    init(_ attributed: NSAttributedString) { self.attributed = attributed }

    /// The same text drawn in a clear color: the overlay text view paints only the selection under it.
    private(set) lazy var invisible: NSAttributedString = {
        let out = NSMutableAttributedString(attributedString: attributed)
        let all = NSRange(location: 0, length: out.length)
        out.removeAttribute(.backgroundColor, range: all)
        out.addAttributes([.foregroundColor: NSColor.clear, .underlineColor: NSColor.clear], range: all)
        return out
    }()

    // One layout stack for every measurement (main thread only).
    private static let storage = NSTextStorage()
    private static let container: NSTextContainer = {
        let c = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        c.lineFragmentPadding = 0
        return c
    }()
    private static let layout: NSLayoutManager = {
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        return manager
    }()

    private static func lay(_ text: NSAttributedString, width: CGFloat) {
        container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        storage.setAttributedString(text)
        layout.ensureLayout(for: container)
    }

    /// The text's natural size wrapped to `width` (its own width if narrower), rounded up to whole points.
    func size(for width: CGFloat) -> CGSize {
        let w = width.isFinite && width > 0 ? width : 100_000
        if let hit = sizes[w] { return hit }
        Self.lay(attributed, width: w)
        let used = Self.layout.usedRect(for: Self.container)
        let size = CGSize(width: min(w, ceil(used.width)), height: ceil(used.height))
        if sizes.count > 8 { sizes.removeAll() }
        sizes[w] = size
        return size
    }

    /// Where the links are when wrapped to `width` (for the pointing-hand cursor).
    func linkRects(width: CGFloat) -> [CGRect] {
        if let cached = linkRectsCache, cached.width == width { return cached.rects }
        var ranges: [NSRange] = []
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            if value != nil { ranges.append(range) }
        }
        var rects: [CGRect] = []
        if !ranges.isEmpty {
            Self.lay(attributed, width: width)
            for range in ranges {
                let glyphs = Self.layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                Self.layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                                    in: Self.container) { rect, _ in rects.append(rect) }
            }
        }
        linkRectsCache = (width, rects)
        return rects
    }
}

/// Laid over a bubble's SwiftUI `Text` (same frame): makes it selectable. Costs one empty view until it is clicked.
struct MessageTextSelection: NSViewRepresentable {
    /// Built only when the text is clicked or hovered.
    let text: () -> MessageText
    /// Selection highlight: translucent, the SwiftUI glyphs show through it.
    let selectionColor: NSColor
    /// `false` in a chat with "Chặn chia sẻ": links still work, nothing can be selected or copied.
    let allowsSelection: Bool
    /// A clicked `zalomention:<uid>` link.
    let mentionScheme: String
    let onMention: (String) -> Void
    /// Compared to notice a new text (a recycled row): an active selection is dropped.
    let identity: String

    @Environment(\.openURL) private var openURL

    func makeNSView(context: Context) -> MessageTextSelectionView { MessageTextSelectionView() }

    func updateNSView(_ view: MessageTextSelectionView, context: Context) {
        if view.config?.identity != identity { view.deactivate() }
        view.config = self
        view.textView?.allowsSelection = allowsSelection
    }

    fileprivate func open(_ url: URL) {
        if url.scheme == mentionScheme {
            let uid = String(url.absoluteString.dropFirst(mentionScheme.count + 1))
            if !uid.isEmpty { onMention(uid) }
        } else {
            openURL(url)
        }
    }
}

final class MessageTextSelectionView: NSView, NSTextViewDelegate {
    var config: MessageTextSelection?
    private(set) var textView: MessageTextView?

    override var isFlipped: Bool { true }

    // MARK: The text view, only while clicked / selected

    private func activate() -> MessageTextView? {
        if let textView { return textView }
        guard let config else { return nil }
        // Own TextKit 1 stack: the layout manager paints every selection (focused or not) in the translucent color.
        let storage = NSTextStorage()
        let layout = SelectionLayoutManager()
        layout.selectionColor = config.selectionColor
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: bounds.size)
        layout.addTextContainer(container)
        let view = MessageTextView(frame: bounds, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.importsGraphics = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.isAutomaticLinkDetectionEnabled = false
        view.displaysLinkToolTips = false
        view.usesFindBar = false
        view.allowsUndo = false
        view.autoresizingMask = [.width, .height]
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        view.selectedTextAttributes = [.backgroundColor: config.selectionColor]
        view.allowsSelection = config.allowsSelection
        view.textStorage?.setAttributedString(config.text().invisible)
        view.delegate = self
        view.onEmpty = { [weak self] in self?.deactivate() }
        addSubview(view)
        textView = view
        return view
    }

    func deactivate() {
        guard let view = textView else { return }
        textView = nil
        view.onEmpty = nil
        view.delegate = nil
        if window?.firstResponder === view { window?.makeFirstResponder(nil) }
        view.removeFromSuperview()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { deactivate() }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return false }
        config?.open(url)
        return true
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        guard let view = activate() else { super.mouseDown(with: event); return }
        view.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        // Reached only with no text view on top: the message's own context menu.
        nextResponder?.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    // MARK: Cursor (I-beam on text, pointing hand on links)

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if tracking == nil {
            let area = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateCursor(event)
    }

    private func updateCursor(_ event: NSEvent) {
        guard textView == nil, let config, !ChatScrollActivity.isScrolling else { return }
        let point = convert(event.locationInWindow, from: nil)
        if config.text().linkRects(width: bounds.width).contains(where: { $0.contains(point) }) {
            NSCursor.pointingHand.set()
        } else if config.allowsSelection {
            NSCursor.iBeam.set()
        } else {
            NSCursor.arrow.set()
        }
    }
}

/// Paints the selection of the overlay text view. AppKit draws an unfocused selection (after ⌘C, or once the composer has
/// focus again) in the opaque `unemphasizedSelectedTextBackgroundColor`, ignoring `selectedTextAttributes`, which hid the
/// SwiftUI glyphs under it. The overlay text has no background attribute of its own, so every fill here is the selection.
final class SelectionLayoutManager: NSLayoutManager {
    var selectionColor: NSColor = .selectedTextBackgroundColor.withAlphaComponent(0.45)

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        // `color` is informational only (AppKit has already set it on the context): fill here, blending, not copying.
        selectionColor.setFill()
        let rects = UnsafeBufferPointer(start: rectArray, count: rectCount)
        for rect in rects { rect.fill(using: .sourceOver) }
    }
}

final class MessageTextView: NSTextView {
    var allowsSelection = true {
        didSet { if !allowsSelection { clearSelection() } }
    }
    /// Called once nothing is selected any more (outside a click's tracking): the overlay removes this view.
    var onEmpty: (() -> Void)?
    private var tracking = false

    func clearSelection() {
        guard selectedRange().length > 0 else { return }
        setSelectedRange(NSRange(location: 0, length: 0))
    }

    private var hasSelection: Bool { selectedRange().length > 0 }

    // MARK: Selection

    override func selectionRange(forProposedRange proposedCharRange: NSRange, granularity: NSSelectionGranularity) -> NSRange {
        guard allowsSelection else { return NSRange(location: proposedCharRange.location, length: 0) }
        return super.selectionRange(forProposedRange: proposedCharRange, granularity: granularity)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if hasSelection {
            SelectionOwner.claim(self)
        } else if !tracking {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.hasSelection, !self.tracking else { return }
                self.onEmpty?()
            }
        }
    }

    /// Never scroll the chat list to "reveal" a selection.
    override func scrollRangeToVisible(_ range: NSRange) {}

    override func cancelOperation(_ sender: Any?) { clearSelection() }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        let previous = window?.firstResponder
        tracking = true
        super.mouseDown(with: event)  // tracks the click / drag until mouse up (link clicks included)
        tracking = false
        guard !hasSelection else { return }
        // A plain click selects nothing: focus goes back where it was (e.g. the composer) and the overlay goes away.
        if let previous, previous !== self, window?.firstResponder === self { window?.makeFirstResponder(previous) }
        onEmpty?()
    }

    override func rightMouseDown(with event: NSEvent) {
        if hasSelection, selectionContains(event) {
            super.rightMouseDown(with: event)  // shows `menu(for:)`
        } else {
            let next = superview?.nextResponder
            clearSelection()
            onEmpty?()
            next?.rightMouseDown(with: event)  // the message's own context menu
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard hasSelection, allowsSelection else { return nil }
        let menu = NSMenu()
        let copy = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "c")
        copy.target = self
        menu.addItem(copy)
        return menu
    }

    private func selectionContains(_ event: NSEvent) -> Bool {
        guard let layout = layoutManager, let container = textContainer else { return false }
        let point = convert(event.locationInWindow, from: nil)
        let glyphs = layout.glyphRange(forCharacterRange: selectedRange(), actualCharacterRange: nil)
        var hit = false
        layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                       in: container) { rect, stop in
            if rect.insetBy(dx: -2, dy: -2).contains(point) { hit = true; stop.pointee = true }
        }
        return hit
    }

    // MARK: Copy

    /// Plain text only: pasting a bubble's text must not bring its fonts or colors along.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) { return allowsSelection && hasSelection }
        return super.validateMenuItem(item)
    }
}

/// The one message text view holding a selection. A mouse click anywhere outside it (another bubble, the composer, the
/// sidebar) clears that selection, as in a web page; the monitor lives as long as the app and costs one check per click.
@MainActor
private enum SelectionOwner {
    private static weak var owner: MessageTextView?
    private static var monitor: Any?

    static func claim(_ view: MessageTextView) {
        if let previous = owner, previous !== view { previous.clearSelection() }
        owner = view
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            MainActor.assumeIsolated {
                if let view = owner {
                    let inside = event.window === view.window
                        && view.bounds.contains(view.convert(event.locationInWindow, from: nil))
                    if !inside { owner = nil; view.clearSelection() }
                }
            }
            return event
        }
    }
}
