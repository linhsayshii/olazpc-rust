import AppKit
import SwiftUI
import Testing
@testable import Olaz

@Suite(.serialized) @MainActor struct RemoteImageLoadingTests {
    @Observable final class Input {
        var url: URL?
        var resolve: ((Bool) async -> MediaResolution)?
        init(url: URL?) { self.url = url }
    }

    private final class Events {
        var loaded = 0
        var failed = 0
        var retry: (() -> Void)?
    }

    private struct Probe: View {
        let input: Input
        let events: Events
        var body: some View {
            RemoteImage(url: input.url, maxPixelSize: 64) { Color.clear }
                .resolvingWith { force in await input.resolve?(force) ?? .unsupported }
                .rendering { _ in Color.green.onAppear { events.loaded += 1 } }
                .onFailure { _, retry in Color.red.onAppear { events.failed += 1; events.retry = retry } }
                .frame(width: 64, height: 64)
        }
    }

    private func photo() throws -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Olaz", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("first-load-test-\(UUID().uuidString).png")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)
        return file
    }

    private func host(_ input: Input, events: Events) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 80, height: 80),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Probe(input: input, events: events))
        window.orderBack(nil)
        return window
    }

    @Test func firstUncachedPhotoAppearsWithoutRetry() async throws {
        let file = try photo()
        defer { try? FileManager.default.removeItem(at: file) }
        let input = Input(url: file), events = Events()
        let window = host(input, events: events)
        defer { window.close() }
        #expect(await pollUntil(timeout: 5) { events.loaded > 0 })
        #expect(events.failed == 0)
    }

    @Test func photoURLArrivingLaterRestartsTheLoad() async throws {
        let file = try photo()
        defer { try? FileManager.default.removeItem(at: file) }
        let input = Input(url: nil), events = Events()
        let window = host(input, events: events)
        defer { window.close() }
        try #require(await pollUntil(timeout: 5) { events.failed > 0 })
        input.url = file
        #expect(await pollUntil(timeout: 5) { events.loaded > 0 })
    }

    @Test func cancelledFallbackDoesNotMakeAnAvailablePhotoRequireRetry() async throws {
        let file = try photo()
        defer { try? FileManager.default.removeItem(at: file) }
        let resolver = MediaResolver()
        // A previous row's fallback was interrupted. Cancellation-aware media fetches return
        // unavailable to that old caller; it must not become a verdict for the next visible row.
        let cancelled = Task { @MainActor in
            await resolver.resolve(key: "photo") {
                withUnsafeCurrentTask { $0?.cancel() }
                return .unavailable
            }
        }
        _ = await cancelled.value

        // The original source is absent, but the fallback already has a valid local PNG.
        let input = Input(url: file.appendingPathExtension("missing")), events = Events()
        input.resolve = { force in await resolver.resolve(key: "photo", force: force) { .file(file) } }
        let window = host(input, events: events)
        defer { window.close() }
        try #require(await pollUntil(timeout: 5) { events.loaded > 0 || events.failed > 0 })
        #expect(events.failed == 0)
        #expect(events.loaded > 0)
        // On the broken implementation, the exact same PNG appears immediately on manual retry.
        if let retry = events.retry {
            retry()
            #expect(await pollUntil(timeout: 5) { events.loaded > 0 })
        }
    }
}
