import CoreGraphics
import Testing
@testable import Olaz

@Suite struct SwipeReplyGestureTests {
    @Test func horizontalLeftSwipePastThresholdReplies() {
        var g = SwipeReplyGesture()
        #expect(g.handle(.began, dx: -2, dy: 0, eligible: true) == .hold)
        #expect(g.handle(.changed, dx: -4, dy: 0.5, eligible: true) == .hold)
        #expect(g.handle(.changed, dx: -4, dy: 0, eligible: true) == .move(-10))
        #expect(g.mode == .swiping)
        #expect(g.handle(.changed, dx: -40, dy: 3, eligible: true) == .move(-50))
        #expect(!g.pastThreshold)
        #expect(g.handle(.changed, dx: -10, dy: 0, eligible: true) == .move(-60))
        #expect(g.pastThreshold)
        #expect(g.handle(.ended, dx: 0, dy: 0, eligible: true) == .end(reply: true))
        // Momentum after the swipe is dropped, then the next gesture starts clean.
        #expect(g.handle(.momentum, dx: -10, dy: 0, eligible: true) == .swallow)
        #expect(g.handle(.momentumEnded, dx: 0, dy: 0, eligible: true) == .swallow)
        #expect(g.mode == .idle)
        #expect(g.handle(.momentum, dx: 0, dy: 5, eligible: true) == .forward)
    }

    @Test func releasingBeforeThresholdOrCancellingDoesNotReply() {
        var g = SwipeReplyGesture()
        _ = g.handle(.began, dx: -10, dy: 0, eligible: true)
        _ = g.handle(.changed, dx: -30, dy: 0, eligible: true)
        #expect(g.handle(.ended, dx: 0, dy: 0, eligible: true) == .end(reply: false))

        _ = g.handle(.began, dx: -10, dy: 0, eligible: true)
        _ = g.handle(.changed, dx: -80, dy: 0, eligible: true)
        #expect(g.handle(.cancelled, dx: 0, dy: 0, eligible: true) == .end(reply: false))
    }

    @Test func swipingBackRightUndoesTheReply() {
        var g = SwipeReplyGesture()
        _ = g.handle(.began, dx: -10, dy: 0, eligible: true)
        _ = g.handle(.changed, dx: -70, dy: 0, eligible: true)
        #expect(g.pastThreshold)
        #expect(g.handle(.changed, dx: 200, dy: 0, eligible: true) == .move(0))
        #expect(g.handle(.ended, dx: 0, dy: 0, eligible: true) == .end(reply: false))
    }

    @Test func verticalScrollIsReplayedAndPassesThrough() {
        var g = SwipeReplyGesture()
        #expect(g.handle(.began, dx: 0, dy: 3, eligible: true) == .hold)
        #expect(g.handle(.changed, dx: -1, dy: 6, eligible: true) == .flush)
        #expect(g.mode == .passing)
        #expect(g.handle(.changed, dx: -30, dy: 2, eligible: true) == .forward)
        #expect(g.handle(.ended, dx: 0, dy: 0, eligible: true) == .forward)
        #expect(g.handle(.momentum, dx: 0, dy: 8, eligible: true) == .forward)
    }

    @Test func diagonalAndRightwardGesturesScroll() {
        var g = SwipeReplyGesture()
        _ = g.handle(.began, dx: -6, dy: -4, eligible: true)
        #expect(g.handle(.changed, dx: -3, dy: -1, eligible: true) == .flush) // 9 vs 5: not clearly horizontal
        var r = SwipeReplyGesture()
        _ = r.handle(.began, dx: 5, dy: 0, eligible: true)
        #expect(r.handle(.changed, dx: 5, dy: 0, eligible: true) == .flush)
    }

    @Test func shortGestureIsReplayedOnRelease() {
        var g = SwipeReplyGesture()
        #expect(g.handle(.began, dx: 0, dy: 1, eligible: true) == .hold)
        #expect(g.handle(.ended, dx: 0, dy: 0, eligible: true) == .flush)
        #expect(g.mode == .idle)
    }

    @Test func ineligibleRowsAndWheelsJustScroll() {
        var g = SwipeReplyGesture()
        #expect(g.handle(.began, dx: -10, dy: 0, eligible: false) == .forward)
        #expect(g.handle(.changed, dx: -80, dy: 0, eligible: false) == .forward)
        #expect(g.handle(.ended, dx: 0, dy: 0, eligible: false) == .forward)
        #expect(g.handle(.other, dx: 0, dy: 10, eligible: false) == .forward)
    }

    @Test func offsetRubberBandsPastThreshold() {
        #expect(SwipeReplyGesture.offset(forTravel: -30) == -30)
        #expect(SwipeReplyGesture.offset(forTravel: -60) == -60)
        #expect(SwipeReplyGesture.offset(forTravel: -80) == -67)
        #expect(SwipeReplyGesture.offset(forTravel: -1000) == -100)
        #expect(SwipeReplyGesture.offset(forTravel: 20) == 0)
    }
}
