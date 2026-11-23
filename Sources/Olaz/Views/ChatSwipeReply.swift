import AppKit

// Swipe to reply: a two-finger swipe to the left on a message slides it, shows a reply arrow and, released past the
// threshold, quotes the message in the composer ("Trả lời"), like the context-menu item.
//
// The list's scroll view sees every trackpad scroll first. A gesture is held back (not scrolled) for its first few points
// while its direction is unknown; a clearly horizontal one to the left becomes a swipe, anything else is handed to the
// scroll view with the held events replayed, so vertical scrolling loses nothing. Momentum after a swipe is dropped;
// mouse wheels and momentum of a scroll pass straight through.

/// The decision logic of one gesture (pure, testable): what to do with each scroll event.
struct SwipeReplyGesture {
    enum Phase: Equatable {
        case began, changed, ended, cancelled
        /// Momentum after the fingers lifted, and its last event.
        case momentum, momentumEnded
        /// No phase (mouse wheel), `mayBegin`, anything else.
        case other
    }

    enum Action: Equatable {
        /// Scroll with this event.
        case forward
        /// Keep this event back until the direction is known.
        case hold
        /// Scroll with the held events, then this one.
        case flush
        /// Drop this event.
        case swallow
        /// Move the row to this offset (negative: to the left).
        case move(CGFloat)
        /// The fingers lifted: spring back, replying when past the threshold.
        case end(reply: Bool)
    }

    enum Mode: Equatable { case idle, deciding, swiping, passing, afterSwipe }

    /// Finger travel that triggers the reply.
    static let threshold: CGFloat = 60
    /// Travel after which the direction is decided.
    static let lockDistance: CGFloat = 8
    /// Events held at most before deciding anyway (a very slow start).
    static let maxHeld = 10

    private(set) var mode = Mode.idle
    private var dx: CGFloat = 0
    private var dy: CGFloat = 0
    private var held = 0
    /// Finger travel along x since the swipe began (≤ 0).
    private(set) var travel: CGFloat = 0

    var pastThreshold: Bool { mode == .swiping && -travel >= Self.threshold }

    /// `dx` is the finger's movement (negative: to the left, whatever the scroll direction setting), `dy` the vertical one.
    /// `eligible`: the gesture began over a row that can be replied to.
    mutating func handle(_ phase: Phase, dx fingerDX: CGFloat, dy fingerDY: CGFloat, eligible: Bool) -> Action {
        switch phase {
        case .momentum:
            return mode == .afterSwipe ? .swallow : .forward
        case .momentumEnded:
            guard mode == .afterSwipe else { return .forward }
            mode = .idle
            return .swallow
        case .other:
            return .forward
        case .began:
            dx = 0; dy = 0; held = 0; travel = 0
            guard eligible else { mode = .passing; return .forward }
            mode = .deciding
            return decide(fingerDX, fingerDY)
        case .changed:
            switch mode {
            case .deciding:
                return decide(fingerDX, fingerDY)
            case .swiping:
                travel = min(0, travel + fingerDX)
                return .move(Self.offset(forTravel: travel))
            case .idle, .passing, .afterSwipe:
                return .forward
            }
        case .ended, .cancelled:
            switch mode {
            case .deciding:
                mode = .idle
                return .flush
            case .swiping:
                let reply = phase == .ended && pastThreshold
                mode = .afterSwipe
                return .end(reply: reply)
            case .passing:
                mode = .idle
                return .forward
            case .idle, .afterSwipe:
                return .forward
            }
        }
    }

    private mutating func decide(_ fingerDX: CGFloat, _ fingerDY: CGFloat) -> Action {
        dx += fingerDX
        dy += fingerDY
        held += 1
        let ax = abs(dx), ay = abs(dy)
        guard max(ax, ay) >= Self.lockDistance || held >= Self.maxHeld else { return .hold }
        // Clearly horizontal (well under 30° off the axis) and to the left; everything else scrolls.
        if dx < 0, ax > ay * 2 {
            mode = .swiping
            travel = dx
            return .move(Self.offset(forTravel: travel))
        }
        mode = .passing
        return .flush
    }

    /// The row follows the fingers up to the threshold, then resists (rubber band), never further than 40 pt beyond it.
    static func offset(forTravel travel: CGFloat) -> CGFloat {
        let t = max(0, -travel)
        guard t > threshold else { return -t }
        return -(threshold + min(40, (t - threshold) * 0.35))
    }
}

/// The list's scroll view: scroll events go through `wheelHandler` (the swipe tracker) when set.
final class ChatScrollView: NSScrollView {
    var wheelHandler: ((NSEvent) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        if let wheelHandler { wheelHandler(event) } else { super.scrollWheel(with: event) }
    }

    /// Scrolls with `event` (bypassing the handler).
    func scroll(with event: NSEvent) { super.scrollWheel(with: event) }
}

/// Drives the swipe for a message list: event routing, the reply arrow, haptics. The list provides the rows.
@MainActor
final class ChatSwipeReplyTracker {
    /// The id of the row under the event that a swipe may reply to, if any.
    var rowAt: (NSEvent) -> String? = { _ in nil }
    /// The frame of a row in the document view.
    var rowFrame: (String) -> NSRect? = { _ in nil }
    /// Shifts a row horizontally (0: back in place).
    var setShift: (String, CGFloat, _ animated: Bool) -> Void = { _, _, _ in }
    var reply: (String) -> Void = { _ in }

    private weak var scrollView: ChatScrollView?
    private weak var document: NSView?
    private var gesture = SwipeReplyGesture()
    private var held: [NSEvent] = []
    private var rowId: String?
    private var wasPast = false
    private lazy var arrow: NSImageView = {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: "arrowshape.turn.up.left.fill", accessibilityDescription: "Trả lời")
        view.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.contentTintColor = .secondaryLabelColor
        view.alphaValue = 0
        view.setAccessibilityElement(false)
        return view
    }()

    init(scrollView: ChatScrollView, document: NSView) {
        self.scrollView = scrollView
        self.document = document
        scrollView.wheelHandler = { [weak self] event in self?.handle(event) }
    }

    /// Puts a swipe in progress back without replying (the chat changed under it).
    func cancel() {
        if let rowId { setShift(rowId, 0, false) }
        rowId = nil
        held.removeAll()
        gesture = SwipeReplyGesture()
        arrow.alphaValue = 0
        arrow.removeFromSuperview()
    }

    private func handle(_ event: NSEvent) {
        let phase = Self.phase(of: event)
        let eligible: Bool
        if phase == .began {
            rowId = event.hasPreciseScrollingDeltas ? rowAt(event) : nil
            eligible = rowId != nil
            held.removeAll()
        } else {
            eligible = rowId != nil
        }
        // The finger's direction: with natural scrolling the content (and the deltas) follow the fingers.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        let action = gesture.handle(phase, dx: event.scrollingDeltaX * sign, dy: event.scrollingDeltaY * sign, eligible: eligible)
        switch action {
        case .forward:
            scrollView?.scroll(with: event)
        case .hold:
            held.append(event)
        case .flush:
            let events = held + [event]
            held.removeAll()
            for e in events { scrollView?.scroll(with: e) }
        case .swallow:
            break
        case .move(let offset):
            held.removeAll()
            show(offset)
        case .end(let reply):
            finish(reply: reply)
        }
    }

    private func show(_ offset: CGFloat) {
        guard let rowId, let frame = rowFrame(rowId), let document else { return }
        setShift(rowId, offset, false)
        let past = gesture.pastThreshold
        if past != wasPast {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            wasPast = past
        }
        if arrow.superview !== document { document.addSubview(arrow) }
        let size: CGFloat = past ? 26 : 22
        // Fixed at the list's right edge (inside its side margin), in the room the row leaves as it slides left.
        arrow.frame = NSRect(x: frame.width - 16 - size, y: frame.midY - size / 2, width: size, height: size)
        arrow.alphaValue = min(1, -offset / SwipeReplyGesture.threshold)
        arrow.contentTintColor = past ? .controlAccentColor : .secondaryLabelColor
    }

    private func finish(reply: Bool) {
        guard let rowId else { return }
        self.rowId = nil
        wasPast = false
        setShift(rowId, 0, true)
        let arrow = arrow
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            arrow.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.gesture.mode != .swiping else { return }
                arrow.removeFromSuperview()
            }
        })
        if reply { self.reply(rowId) }
    }

    static func phase(of event: NSEvent) -> SwipeReplyGesture.Phase {
        let momentum = event.momentumPhase
        if !momentum.isEmpty {
            return momentum.contains(.ended) || momentum.contains(.cancelled) ? .momentumEnded : .momentum
        }
        let phase = event.phase
        if phase.contains(.began) { return .began }
        if phase.contains(.changed) { return .changed }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.cancelled) { return .cancelled }
        return .other
    }
}
