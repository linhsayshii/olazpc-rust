import AppKit
import SwiftUI
import Testing
@testable import Olaz

@Suite(.serialized) @MainActor struct SelectableMessageTextTests {
    static let samples = [
        "ok",
        "Xin chào các bạn, đây là một tin nhắn dài để thử chọn chữ. Link: https://example.com và @Minh ở đây.",
        "Dòng một\nDòng hai\n\nĐoạn mới với chữ có dấu: Ữ Ỹ Ậ ẫ ợ",
        String(repeating: "Tiếng Việt có dấu rất dễ xuống dòng ", count: 12),
    ]

    private func makeHost(text: String = "Xin chào Olaz copy test", allowsSelection: Bool = true)
        -> (window: NSWindow, composer: ComposerTextView.FieldTextView, overlay: MessageTextSelectionView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        window.contentView = root

        let composer = ComposerTextView.FieldTextView(frame: NSRect(x: 16, y: 16, width: 360, height: 32))
        composer.isEditable = true
        composer.isRichText = false
        composer.importsGraphics = false
        root.addSubview(composer)

        let msgText = ChatFormat.messageText(text, mentions: [], mine: false, myId: nil, size: 14, accent: .systemBlue)
        let overlay = MessageTextSelectionView(frame: NSRect(x: 16, y: 120, width: 300, height: 40))
        overlay.config = MessageTextSelection(
            text: { msgText },
            selectionColor: .selectedTextBackgroundColor.withAlphaComponent(0.45),
            allowsSelection: allowsSelection,
            mentionScheme: ChatFormat.mentionScheme,
            onMention: { _ in },
            identity: "m1|\(text)"
        )
        root.addSubview(overlay)

        window.makeFirstResponder(composer)
        return (window, composer, overlay)
    }

    /// Runs `body` inside a private nested `CFRunLoopRunInMode` so `NSApp.postEvent` (which calls
    /// `CFRunLoopStop(CFRunLoopGetMain())`) only stops our nested mode and never prematurely exits
    /// `swiftpm-testing-helper`'s outer `CFRunLoopRun()`.
    private func runInIsolatedMouseTrackingMode(_ body: @escaping @MainActor () -> Void) {
        let mode = CFRunLoopMode("OlazTestMouseTracking" as CFString)
        let mainLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(mainLoop, mode.rawValue) {
            MainActor.assumeIsolated {
                body()
            }
            CFRunLoopStop(mainLoop)
        }
        CFRunLoopRunInMode(mode, 1.0, false)
    }

    @Test func heightMatchesSwiftUIText() {
        for s in Self.samples {
            for width in [180.0, 320.0, 496.0] {
                let mine = ChatFormat.messageText(s, mentions: [], mine: false, myId: nil, size: 14, accent: .systemBlue)
                let old = NSHostingController(rootView: Text(ChatFormat.linkified(s, mine: false))
                    .font(.system(size: 14)).fixedSize(horizontal: false, vertical: true))
                let ref = old.sizeThatFits(in: CGSize(width: width, height: 100_000))
                let new = mine.size(for: width)
                #expect(abs(new.height - ref.height) <= 1, "\(s.prefix(20))… @\(width): \(new.height) vs \(ref.height)")
                #expect(new.width <= width)
            }
        }
    }

    @Test func linksAndMentions() {
        let s = "Hi @Minh xem https://example.com"
        let t = ChatFormat.messageText(s, mentions: [Mention(uid: "42", pos: 3, len: 5)], mine: true, myId: "1",
                                       size: 14, accent: .systemBlue).attributed
        let ns = s as NSString
        #expect(t.attribute(.link, at: ns.range(of: "@Minh").location, effectiveRange: nil) as? URL == URL(string: "zalomention:42"))
        #expect(t.attribute(.link, at: ns.range(of: "https").location, effectiveRange: nil) as? URL == URL(string: "https://example.com"))
        #expect(t.attribute(.link, at: 0, effectiveRange: nil) == nil)
    }

    @Test func myMentionIsNotALink() {
        let t = ChatFormat.messageText("@Me hi", mentions: [Mention(uid: "1", pos: 0, len: 3)], mine: false, myId: "1",
                                       size: 14, accent: .systemBlue).attributed
        #expect(t.attribute(.link, at: 0, effectiveRange: nil) == nil)
        #expect(t.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil)
    }

    @Test func doubleClickSelectionClaimsFirstResponderAndEnablesCopy() throws {
        let (window, composer, overlay) = makeHost(text: "Hello Olaz world")
        #expect(window.firstResponder === composer)
        #expect(overlay.textView == nil)

        // Drive real AppKit mouse events on the window-hosted overlay (double-click selects a word).
        let targetInWindow = overlay.convert(NSPoint(x: 12, y: 10), to: nil)
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: targetInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 2,
            pressure: 1
        ))
        let up = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: targetInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 2,
            pressure: 0
        ))
        runInIsolatedMouseTrackingMode {
            NSApp.postEvent(up, atStart: true)
            overlay.mouseDown(with: down)
        }

        let tv = try #require(overlay.textView)
        #expect(tv.selectedRange().length > 0)
        #expect(window.firstResponder === tv)
        #expect(tv.previousFirstResponder === composer)

        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        #expect(tv.validateMenuItem(copyItem))
        #expect(tv.validateUserInterfaceItem(copyItem))
        #expect(!tv.validateMenuItem(pasteItem))

        // Verify plain-text copy writes the selected word (without RTF or invisible/clear styling).
        let pb = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        #expect(tv.writeSelection(to: pb, types: tv.writablePasteboardTypes))
        #expect(pb.string(forType: .string) == "Hello")
        #expect(pb.data(forType: .rtf) == nil)
        #expect(pb.data(forType: .rtfd) == nil)

        // Clearing / tearing down the overlay restores focus to the composer instead of dropping it to nil.
        overlay.deactivate()
        #expect(overlay.textView == nil)
        #expect(window.firstResponder === composer)
    }

    @Test func dragSelectionClaimsFirstResponderAndEscapeRestoresComposer() async throws {
        let (window, composer, overlay) = makeHost(text: "Hello Olaz world")
        #expect(window.firstResponder === composer)
        #expect(overlay.textView == nil)

        let startInWindow = overlay.convert(NSPoint(x: 2, y: 10), to: nil)
        let endInWindow = overlay.convert(NSPoint(x: 80, y: 10), to: nil)
        let now = ProcessInfo.processInfo.systemUptime
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: startInWindow,
            modifierFlags: [],
            timestamp: now,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 10,
            clickCount: 1,
            pressure: 1
        ))
        let drag = try #require(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: endInWindow,
            modifierFlags: [],
            timestamp: now + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 11,
            clickCount: 1,
            pressure: 1
        ))
        let up = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: endInWindow,
            modifierFlags: [],
            timestamp: now + 0.02,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 12,
            clickCount: 1,
            pressure: 0
        ))
        // Queue drag then up (atStart reverses insertion order, so post up first then drag).
        runInIsolatedMouseTrackingMode {
            NSApp.postEvent(up, atStart: true)
            NSApp.postEvent(drag, atStart: true)
            overlay.mouseDown(with: down)
        }

        let tv = try #require(overlay.textView)
        #expect(tv.selectedRange().length > 0)
        #expect(window.firstResponder === tv)

        let pb = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        #expect(tv.writeSelection(to: pb, types: tv.writablePasteboardTypes))
        #expect((pb.string(forType: .string) ?? "").hasPrefix("Hello"))

        // Pressing Esc clears the selection and asynchronously tears down the overlay, restoring composer focus.
        tv.cancelOperation(nil)
        try await Task.sleep(for: .milliseconds(30))
        #expect(overlay.textView == nil)
        #expect(window.firstResponder === composer)
    }

    @Test func plainClickWithoutSelectionKeepsComposerFocusedAndDeactivates() throws {
        let (window, composer, overlay) = makeHost(text: "Tap without drag")
        let tv = try #require(overlay.activate())
        tv.capturePreviousFirstResponder()
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.finishMouseTracking()

        #expect(overlay.textView == nil)
        #expect(window.firstResponder === composer)
    }

    @Test func switchingSelectionBetweenBubblesPreservesComposerForRestore() throws {
        let (window, composer, overlayA) = makeHost(text: "First bubble")
        let msgB = ChatFormat.messageText("Second bubble", mentions: [], mine: false, myId: nil, size: 14, accent: .systemBlue)
        let overlayB = MessageTextSelectionView(frame: NSRect(x: 16, y: 170, width: 300, height: 40))
        overlayB.config = MessageTextSelection(
            text: { msgB },
            selectionColor: .selectedTextBackgroundColor.withAlphaComponent(0.45),
            allowsSelection: true,
            mentionScheme: ChatFormat.mentionScheme,
            onMention: { _ in },
            identity: "m2|Second bubble"
        )
        window.contentView?.addSubview(overlayB)

        // Select in bubble A.
        let tvA = try #require(overlayA.activate())
        tvA.capturePreviousFirstResponder()
        tvA.setSelectedRange(NSRange(location: 0, length: 5))
        tvA.finishMouseTracking()
        #expect(window.firstResponder === tvA)
        #expect(tvA.previousFirstResponder === composer)

        // Select in bubble B while A is still first responder (before A's async deactivate runs).
        let tvB = try #require(overlayB.activate())
        tvB.capturePreviousFirstResponder()
        tvB.setSelectedRange(NSRange(location: 0, length: 6))
        tvB.finishMouseTracking()
        #expect(window.firstResponder === tvB)
        #expect(tvB.previousFirstResponder === composer)

        // A's delayed teardown must not steal focus from B.
        overlayA.deactivate()
        #expect(window.firstResponder === tvB)

        // Deactivating B restores focus to the composer.
        overlayB.deactivate()
        #expect(window.firstResponder === composer)
    }

    @Test func clickingComposerWhileBubbleSelectedDoesNotStealFocusOnDeactivate() throws {
        let (window, composer, overlay) = makeHost(text: "Copy then paste")
        let tv = try #require(overlay.activate())
        tv.capturePreviousFirstResponder()
        tv.setSelectedRange(NSRange(location: 0, length: 4))
        tv.finishMouseTracking()
        #expect(window.firstResponder === tv)

        // User clicks directly into the composer before async teardown fires.
        window.makeFirstResponder(composer)
        #expect(window.firstResponder === composer)

        overlay.deactivate()
        #expect(window.firstResponder === composer)
    }

    @Test func protectedChatBlocksFirstResponderAndCopy() throws {
        let (window, composer, overlay) = makeHost(text: "Protected message", allowsSelection: false)
        let tv = try #require(overlay.activate())
        tv.capturePreviousFirstResponder()
        #expect(!tv.acceptsFirstResponder)

        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        #expect(!tv.validateMenuItem(copyItem))
        #expect(!tv.validateMenuItem(selectAllItem))

        tv.finishMouseTracking()
        #expect(window.firstResponder === composer)
    }
}
