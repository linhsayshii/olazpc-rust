import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Olaz

@Suite("GIF")
struct GifTests {
    @Test func parsesOfficialRows() {
        let items = GifItem.list(from: ["data": ["has_more": true, "data_list": [
            ["id": "abc", "original": ["url": "https://g/o.gif", "width": 480, "height": 270],
             "preview": ["url": "https://g/p.gif", "width": 100, "height": 56], "normal": ["url": "https://g/n.gif"]],
            ["id": "bad"],
        ]]])
        #expect(items.count == 1)
        #expect(items.first?.url.absoluteString == "https://g/o.gif")
        #expect(items.first?.thumb.absoluteString == "https://g/p.gif")
        #expect(items.first?.width == 480 && items.first?.height == 270)
    }

    @Test func displaySizeUsesMetadataWhenPresentAndFallsBackToFixedBox() {
        // Missing or non-positive metadata reserves the fixed 4:3 box so row height never jumps on load.
        #expect(GifView.displaySize(width: 0, height: 0) == GifView.fallbackSize)
        #expect(GifView.displaySize(width: -10, height: 200) == GifView.fallbackSize)
        #expect(GifView.displaySize(width: 300, height: 0) == GifView.fallbackSize)

        // Fallback still respects a narrower max box.
        let narrowFallback = GifView.displaySize(width: 0, height: 0, maxSize: CGSize(width: 120, height: 120))
        #expect(narrowFallback.width == 120)
        #expect(abs(narrowFallback.height - 90) < 0.01)

        // Landscape 16:9 fits within 260×260 preserving aspect ratio.
        let landscape = GifView.displaySize(width: 480, height: 270)
        #expect(abs(landscape.width - 260) < 0.01)
        #expect(abs(landscape.height - 146.25) < 0.01)

        // Portrait 9:16 fits within 260×260 preserving aspect ratio.
        let portrait = GifView.displaySize(width: 270, height: 480)
        #expect(abs(portrait.width - 146.25) < 0.01)
        #expect(abs(portrait.height - 260) < 0.01)

        // Square fits cleanly at maxSize.
        let square = GifView.displaySize(width: 480, height: 480)
        #expect(square == CGSize(width: 260, height: 260))

        // Small GIF upscales at most 1.5x; tiny GIF clamps to minSize.
        #expect(GifView.displaySize(width: 100, height: 100) == CGSize(width: 150, height: 150))
        #expect(GifView.displaySize(width: 20, height: 20) == GifView.minSize)

        // Extreme aspect ratios never exceed maxSize on either axis.
        let ultraWide = GifView.displaySize(width: 1000, height: 50)
        #expect(ultraWide.width == 260 && ultraWide.height == 60)
        let ultraTall = GifView.displaySize(width: 50, height: 1000)
        #expect(ultraTall.width == 80 && ultraTall.height == 260)
    }

    @Test func animatedImageFittedSizePreservesAspectRatioUnderPartialProposals() {
        // Regression: ChatRowContent applies .fixedSize(horizontal: false, vertical: true),
        // proposing (width: 260, height: nil). Previously replacingUnspecifiedDimensions returned
        // (260, 480) for a 480×480 GIF, overflowing the bubble into neighbouring rows.
        let square = AnimatedImageView.fittedSize(
            imageSize: CGSize(width: 480, height: 480),
            proposal: ProposedViewSize(width: 260, height: nil),
            contentMode: .fit
        )
        #expect(square == CGSize(width: 260, height: 260))

        let landscape = AnimatedImageView.fittedSize(
            imageSize: CGSize(width: 480, height: 270),
            proposal: ProposedViewSize(width: 260, height: nil),
            contentMode: .fit
        )
        #expect(abs(landscape.width - 260) < 0.01)
        #expect(abs(landscape.height - 146.25) < 0.01)

        // Bounded 240×180 box fits every aspect ratio strictly within its bounds.
        let fitSquare = AnimatedImageView.fittedSize(
            imageSize: CGSize(width: 480, height: 480),
            proposal: ProposedViewSize(width: 240, height: 180),
            contentMode: .fit
        )
        #expect(fitSquare == CGSize(width: 180, height: 180))

        let fitPortrait = AnimatedImageView.fittedSize(
            imageSize: CGSize(width: 270, height: 480),
            proposal: ProposedViewSize(width: 240, height: 180),
            contentMode: .fit
        )
        #expect(abs(fitPortrait.width - 101.25) < 0.01)
        #expect(abs(fitPortrait.height - 180) < 0.01)

        let fitHeightOnly = AnimatedImageView.fittedSize(
            imageSize: CGSize(width: 480, height: 270),
            proposal: ProposedViewSize(width: nil, height: 180),
            contentMode: .fit
        )
        #expect(abs(fitHeightOnly.width - 320) < 0.01)
        #expect(abs(fitHeightOnly.height - 180) < 0.01)

        // Special proposals never produce infinity or NaN.
        #expect(AnimatedImageView.fittedSize(imageSize: CGSize(width: 300, height: 200), proposal: .infinity, contentMode: .fit) == CGSize(width: 300, height: 200))
        #expect(AnimatedImageView.fittedSize(imageSize: CGSize(width: 300, height: 200), proposal: .unspecified, contentMode: .fit) == CGSize(width: 300, height: 200))
        #expect(AnimatedImageView.fittedSize(imageSize: CGSize(width: 300, height: 200), proposal: .zero, contentMode: .fit) == .zero)
        #expect(AnimatedImageView.fittedSize(imageSize: CGSize(width: 300, height: 200), proposal: ProposedViewSize(width: 240, height: 180), contentMode: .fill) == CGSize(width: 240, height: 180))
        #expect(AnimatedImageView.fittedSize(imageSize: .zero, proposal: .infinity, contentMode: .fit) == .zero)
    }

    @Test @MainActor func gifViewReservesStableHeightUnderRowSizing() {
        let controller = NSHostingController(rootView:
            GifView(url: nil)
                .fixedSize(horizontal: false, vertical: true)
        )
        let normal = controller.sizeThatFits(in: CGSize(width: 500, height: 100_000))
        #expect(abs(normal.width - GifView.fallbackSize.width) < 0.5)
        #expect(abs(normal.height - GifView.fallbackSize.height) < 0.5)

        // Narrow chat column shrinks the GIF box proportionally instead of overflowing horizontally.
        let narrow = controller.sizeThatFits(in: CGSize(width: 160, height: 100_000))
        #expect(abs(narrow.width - 160) < 0.5)
        #expect(abs(narrow.height - 120) < 0.5)

        // Metadata dimensions reserve the fitted aspect ratio directly.
        let sized = NSHostingController(rootView:
            GifView(url: nil, width: 480, height: 270)
                .fixedSize(horizontal: false, vertical: true)
        )
        let measured = sized.sizeThatFits(in: CGSize(width: 500, height: 100_000))
        #expect(abs(measured.width - 260) < 0.5)
        #expect(abs(measured.height - 146.25) < 0.5)
    }

    @Test @MainActor func animatedImageViewClipsAndFitsInsideHostedBox() {
        // Under .fixedSize(horizontal: false, vertical: true), .frame(maxWidth: 260, maxHeight: 260)
        // proposes (260, nil). A 480×270 GIF must fit to 260×146.25 (not 260×270), and a 480×480 GIF
        // must fit to 260×260 (not 260×480).
        let landscape = NSImage(size: NSSize(width: 480, height: 270))
        let landscapeHost = NSHostingController(rootView:
            AnimatedImageView(image: landscape, contentMode: .fit)
                .frame(maxWidth: 260, maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
        )
        let landscapeSize = landscapeHost.sizeThatFits(in: CGSize(width: 500, height: 100_000))
        #expect(abs(landscapeSize.width - 260) < 0.5)
        #expect(abs(landscapeSize.height - 146.25) < 0.5)

        let square = NSImage(size: NSSize(width: 480, height: 480))
        let squareHost = NSHostingController(rootView:
            AnimatedImageView(image: square, contentMode: .fit)
                .frame(maxWidth: 260, maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
        )
        let squareSize = squareHost.sizeThatFits(in: CGSize(width: 500, height: 100_000))
        #expect(abs(squareSize.width - 260) < 0.5)
        #expect(abs(squareSize.height - 260) < 0.5)

        // Container clips to bounds and lays out its imageView strictly inside its frame.
        let container = AnimatedImageView.Container(frame: NSRect(x: 0, y: 0, width: 240, height: 180))
        container.fill = false
        container.imageView.image = square
        container.layout()
        #expect(container.clipsToBounds)
        #expect(container.layer?.masksToBounds == true)
        #expect(container.bounds.contains(container.imageView.frame))
        #expect(abs(container.imageView.frame.width - 180) < 0.5)
        #expect(abs(container.imageView.frame.height - 180) < 0.5)
    }

    @Test @MainActor func gifRowsDoNotOverlapDaySeparatorOrNeighboursInChatList() throws {
        let engine = ZaloEngine()
        var env = EnvironmentValues()
        env[ZaloEngine.self] = engine

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let gif1 = ChatMessage(
            id: "g1", conversationId: "c1", senderId: "me", senderName: "Bạn",
            isMine: true, kind: .gif(url: nil), text: "[GIF]", date: t0, status: .sent,
            reactions: [], isE2EE: false
        )
        let gif2 = ChatMessage(
            id: "g2", conversationId: "c1", senderId: "u2", senderName: "An",
            isMine: false, kind: .gif(url: nil), text: "[GIF]", date: t0.addingTimeInterval(30), status: .sent,
            reactions: [], isE2EE: false
        )
        let rows: [ChatRow] = [
            ChatRow(id: "day1", kind: .day(t0)),
            ChatRow(id: "g1", kind: .message(gif1, first: true, last: true, status: false)),
            ChatRow(id: "g2", kind: .message(gif2, first: true, last: true, status: false)),
        ]

        let list = ChatListController()
        list.scrollView.frame = NSRect(x: 0, y: 0, width: 500, height: 600)
        list.update(conversationId: "c1", rows: rows, isGroup: false, newestId: "g2", highlightedId: nil,
                    loadingOlder: false, insets: EdgeInsets(), environment: env)

        let dayFrame = try #require(list.rowFrameForTesting(of: "day1"))
        let g1Frame = try #require(list.rowFrameForTesting(of: "g1"))
        let g2Frame = try #require(list.rowFrameForTesting(of: "g2"))

        #expect(g1Frame.height >= GifView.fallbackSize.height)
        #expect(g2Frame.height >= GifView.fallbackSize.height)
        #expect(dayFrame.maxY <= g1Frame.minY + 0.5)
        #expect(g1Frame.maxY <= g2Frame.minY + 0.5)
    }
}
