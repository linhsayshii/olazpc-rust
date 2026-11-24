import CoreGraphics
import Testing
@testable import Olaz

/// Opening the inspector adds its width to the window (the chat keeps its width); closing it gives that width back.
@MainActor @Suite struct InspectorRoomTests {
    let screen = CGRect(x: 0, y: 0, width: 1800, height: 1100)

    @Test func minimumWindowGrowsToTheRightByTheInspectorWidth() {
        let window = CGRect(x: 420, y: 243, width: 960, height: 672)
        let grown = InspectorRoom.frame(for: window, in: screen)
        #expect(grown == CGRect(x: 420, y: 243, width: 1260, height: 672))
    }

    @Test func aWideWindowStillGrowsByTheInspectorWidthOnly() {
        let window = CGRect(x: 100, y: 151, width: 1368, height: 832)
        #expect(InspectorRoom.frame(for: window, in: screen) == CGRect(x: 100, y: 151, width: 1668, height: 832))
    }

    @Test func growingPastTheScreenEdgeMovesTheWindowLeft() {
        let window = CGRect(x: 800, y: 100, width: 960, height: 600)
        let grown = InspectorRoom.frame(for: window, in: screen)
        #expect(grown.width == 1260 && grown.maxX == screen.maxX)
    }

    @Test func neverWiderThanTheScreen() {
        let small = CGRect(x: 0, y: 0, width: 1100, height: 800)
        let grown = InspectorRoom.frame(for: CGRect(x: 50, y: 0, width: 960, height: 600), in: small)
        #expect(grown.width == 1100 && grown.minX == 0)
    }

    @Test func aScreenWideWindowIsLeftAlone() {
        let window = CGRect(x: 0, y: 0, width: 1800, height: 1000)
        #expect(InspectorRoom.frame(for: window, in: screen) == window)
    }

    @Test func closingRestoresTheOriginalFrame() {
        let window = CGRect(x: 800, y: 100, width: 1100, height: 600)
        let grown = InspectorRoom.frame(for: window, in: screen)
        let growth = InspectorRoom.Growth(added: grown.width - window.width, shifted: window.minX - grown.minX)
        #expect(growth.shifted > 0)
        #expect(InspectorRoom.restored(grown, undoing: growth) == window)
    }

    @Test func closingAfterTheUserNarrowedTheWindowStopsAtTheMinimum() {
        let growth = InspectorRoom.Growth(added: 300, shifted: 0)
        let narrowed = CGRect(x: 10, y: 0, width: 1100, height: 600)
        #expect(InspectorRoom.restored(narrowed, undoing: growth) == CGRect(x: 10, y: 0, width: 960, height: 600))
    }
}
