import AppKit
import CoreGraphics
import SwiftUI
import Testing
@testable import Olaz

/// Opening the inspector adds its width to the window (the chat keeps its width); closing it gives that width back.
@MainActor @Suite(.serialized) struct InspectorRoomTests {
    let screen = CGRect(x: 0, y: 0, width: 1800, height: 1100)

    // MARK: - Pure geometry

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

    @Test func minimumWidthCapsToCompactScreenWidth() {
        #expect(InspectorRoom.minimumWidth(holdingInspectorRoom: false, screenWidth: 1800) == 960)
        #expect(InspectorRoom.minimumWidth(holdingInspectorRoom: false, screenWidth: 1100) == 960)
        #expect(InspectorRoom.minimumWidth(holdingInspectorRoom: true, screenWidth: 1800) == 1260)
        #expect(InspectorRoom.minimumWidth(holdingInspectorRoom: true, screenWidth: 1100) == 1100)
        #expect(InspectorRoom.minimumWidth(holdingInspectorRoom: true, screenWidth: 900) == 960)
        #expect(InspectorRoom.minimumWidth(holdingInspectorRoom: true, screenWidth: nil) == 1260)
    }

    @Test func planOpenComputesGrowthAndCappedMinWidth() {
        let compactScreen = CGRect(x: 0, y: 0, width: 1100, height: 800)
        let plan = InspectorRoom.planOpen(window: CGRect(x: 50, y: 20, width: 960, height: 640), in: compactScreen)
        #expect(plan.targetFrame == CGRect(x: 0, y: 20, width: 1100, height: 640))
        #expect(plan.growth == InspectorRoom.Growth(added: 140, shifted: 50))
        #expect(plan.minimumWidth == 1100)

        let fullPlan = InspectorRoom.planOpen(window: CGRect(x: 0, y: 0, width: 1800, height: 1000), in: screen)
        #expect(fullPlan.targetFrame == CGRect(x: 0, y: 0, width: 1800, height: 1000))
        #expect(fullPlan.growth == nil)
        #expect(fullPlan.minimumWidth == 1260)
    }

    @Test func secondaryMonitorOriginIsRespected() {
        let secondary = CGRect(x: 1800, y: 0, width: 1440, height: 900)
        let window = CGRect(x: 2040, y: 100, width: 1100, height: 680)
        let plan = InspectorRoom.planOpen(window: window, in: secondary)
        #expect(plan.targetFrame == CGRect(x: 1840, y: 100, width: 1400, height: 680))
        #expect(plan.growth == InspectorRoom.Growth(added: 300, shifted: 200))
        #expect(InspectorRoom.restored(plan.targetFrame, undoing: plan.growth!) == window)
    }

    // MARK: - AppKit / SwiftUI split-view + inspector integration

    private struct ShellInspectorHarnessView: View {
        @Bindable var shell: ShellModel

        var body: some View {
            NavigationSplitView(columnVisibility: $shell.columns) {
                Color.clear
                    .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 300)
            } content: {
                Color.clear
                    .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 440)
            } detail: {
                Color.clear
                    .frame(minWidth: 0, idealWidth: 400, maxWidth: .infinity, minHeight: 0, idealHeight: 600, maxHeight: .infinity)
            }
            .inspector(isPresented: $shell.showInspector) {
                Color.clear
                    .inspectorColumnWidth(min: 260, ideal: InspectorRoom.inspectorWidth, max: 440)
            }
            .onChange(of: shell.showInspector) { _, shown in
                if !shown { shell.hideInspector() }
            }
            .frame(
                minWidth: shell.holdsInspectorRoom ? shell.inspectorMinWidth : InspectorRoom.windowMinWidth,
                minHeight: 620
            )
        }
    }

    private func pumpMainRunLoop(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func settleUI(_ milliseconds: Int = 140) async throws {
        // Pump AppKit first so SwiftUI commits the immediate `showInspector` layout pass,
        // yield MainActor so `DispatchQueue.main.async` executes, then pump once more so `ShellMinimumSize` commits.
        pumpMainRunLoop(0.05)
        try await Task.sleep(for: .milliseconds(max(20, milliseconds / 3)))
        pumpMainRunLoop(0.06)
    }

    private func makeHostedWindow(shell: ShellModel, frame: CGRect) async throws -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ShellInspectorHarnessView(shell: shell))
        window.setFrame(frame, display: true)
        window.orderFront(nil)
        shell.window = window
        try await settleUI(120)
        window.setFrame(frame, display: true)
        try await settleUI(80)
        return window
    }

    @Test func togglingInspectorAddsOnlyInspectorWidthAndRestoresCleanly() async throws {
        let visible = try #require(NSScreen.main?.visibleFrame)
        guard visible.width >= InspectorRoom.windowMinWidthWithInspector + 200 else { return }

        let shell = ShellModel()
        shell.destination = .inbox
        shell.selection = "conv-1"

        let start = CGRect(x: visible.minX + 40, y: visible.minY + 40, width: 960, height: 672)
        let window = try await makeHostedWindow(shell: shell, frame: start)
        defer { window.close() }

        // Open inspector: must grow by +300 pt (to 1260), NOT +600 pt or full screen width.
        shell.toggleInspector()
        try await settleUI(140)
        #expect(shell.showInspector)
        #expect(shell.holdsInspectorRoom)
        #expect(abs(window.frame.width - 1260) <= 1)
        #expect(abs(window.frame.minX - start.minX) <= 1)
        #expect(abs(window.minSize.width - 1260) <= 1)

        // Close inspector: must restore exact original frame and lower minSize back to 960.
        shell.toggleInspector()
        try await settleUI(140)
        #expect(!shell.showInspector)
        #expect(!shell.holdsInspectorRoom)
        #expect(abs(window.frame.width - start.width) <= 1)
        #expect(abs(window.frame.minX - start.minX) <= 1)
        #expect(abs(window.minSize.width - 960) <= 1)

        // Second cycle must remain identical (no compounding drift).
        shell.toggleInspector()
        try await settleUI(140)
        #expect(abs(window.frame.width - 1260) <= 1)
        shell.toggleInspector()
        try await settleUI(140)
        #expect(abs(window.frame.width - start.width) <= 1)
    }

    @Test func togglingInspectorNearRightEdgeShiftsLeftAndRestores() async throws {
        let visible = try #require(NSScreen.main?.visibleFrame)
        guard visible.width >= 1500 else { return }

        let shell = ShellModel()
        shell.destination = .inbox
        shell.selection = "conv-1"

        let startWidth: CGFloat = 1100
        let start = CGRect(x: visible.maxX - startWidth, y: visible.minY + 40, width: startWidth, height: 672)
        let window = try await makeHostedWindow(shell: shell, frame: start)
        defer { window.close() }

        shell.toggleInspector()
        try await settleUI(140)
        #expect(abs(window.frame.width - (startWidth + InspectorRoom.inspectorWidth)) <= 1)
        #expect(abs(window.frame.maxX - visible.maxX) <= 1)

        shell.toggleInspector()
        try await settleUI(140)
        #expect(abs(window.frame.width - start.width) <= 1)
        #expect(abs(window.frame.minX - start.minX) <= 1)
    }

    @Test func togglingInspectorOnWideWindowGrowsOnlyByInspectorWidthAndRestores() async throws {
        let visible = try #require(NSScreen.main?.visibleFrame)
        guard visible.width >= 1750 else { return }

        let shell = ShellModel()
        shell.destination = .inbox
        shell.selection = "conv-1"

        let start = CGRect(x: visible.minX + 40, y: visible.minY + 40, width: 1368, height: 672)
        let window = try await makeHostedWindow(shell: shell, frame: start)
        defer { window.close() }

        shell.toggleInspector()
        try await settleUI(140)
        #expect(abs(window.frame.width - 1668) <= 1)
        #expect(abs(window.frame.minX - start.minX) <= 1)

        shell.toggleInspector()
        try await settleUI(140)
        #expect(abs(window.frame.width - start.width) <= 1)
        #expect(abs(window.frame.minX - start.minX) <= 1)
    }

    @Test func togglingInspectorOnScreenWideWindowLeavesFrameUnchanged() async throws {
        let visible = try #require(NSScreen.main?.visibleFrame)
        guard visible.width >= InspectorRoom.windowMinWidthWithInspector else { return }

        let shell = ShellModel()
        shell.destination = .inbox
        shell.selection = "conv-1"

        let start = CGRect(x: visible.minX, y: visible.minY + 40, width: visible.width, height: 672)
        let window = try await makeHostedWindow(shell: shell, frame: start)
        defer { window.close() }

        shell.toggleInspector()
        try await settleUI(140)
        #expect(shell.showInspector)
        #expect(abs(window.frame.width - visible.width) <= 1)
        #expect(abs(window.frame.minX - visible.minX) <= 1)

        shell.toggleInspector()
        try await settleUI(140)
        #expect(!shell.showInspector)
        #expect(abs(window.frame.width - visible.width) <= 1)
    }

    @Test func rapidToggleCancelsDeferredInspectorRoomHold() async throws {
        let visible = try #require(NSScreen.main?.visibleFrame)
        guard visible.width >= InspectorRoom.windowMinWidthWithInspector + 200 else { return }

        let shell = ShellModel()
        shell.destination = .inbox
        shell.selection = "conv-1"

        let start = CGRect(x: visible.minX + 40, y: visible.minY + 40, width: 1000, height: 672)
        let window = try await makeHostedWindow(shell: shell, frame: start)
        defer { window.close() }

        // Open and immediately close before the deferred main-queue block runs.
        shell.toggleInspector()
        shell.hideInspector()
        try await settleUI(140)

        #expect(!shell.showInspector)
        #expect(!shell.holdsInspectorRoom)
        #expect(abs(window.frame.width - start.width) <= 1)
        #expect(abs(window.minSize.width - 960) <= 1)
    }
}
