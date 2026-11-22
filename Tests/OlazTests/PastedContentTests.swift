import AppKit
import Testing
@testable import Olaz

@Suite struct PastedContentTests {
    private func sampleImage() throws -> NSBitmapImageRep {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        rep.setColor(.systemBlue, atX: 0, y: 0)
        rep.setColor(.systemRed, atX: 1, y: 1)
        return rep
    }

    private func pasteboard(with type: NSPasteboard.PasteboardType, data: Data) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.declareTypes([type], owner: nil)
        pasteboard.setData(data, forType: type)
        return pasteboard
    }

    @Test func readsImageOnlyPNG() throws {
        let png = try #require(sampleImage().representation(using: .png, properties: [:]))
        let result = PastedContent.read(from: pasteboard(with: .png, data: png))
        guard case .image(let data) = result else {
            Issue.record("Expected an image from an image-only PNG pasteboard")
            return
        }
        #expect(NSImage(data: data) != nil)
    }

    @Test func readsImageOnlyTIFFAsPNG() throws {
        let tiff = try #require(sampleImage().representation(using: .tiff, properties: [:]))
        let result = PastedContent.read(from: pasteboard(with: .tiff, data: tiff))
        guard case .image(let data) = result else {
            Issue.record("Expected an image from an image-only TIFF pasteboard")
            return
        }
        #expect(NSImage(data: data) != nil)
        #expect(data.starts(with: [0x89, 0x50, 0x4e, 0x47]))
    }

    @Test func textAndImageUsesNormalTextPaste() throws {
        let png = try #require(sampleImage().representation(using: .png, properties: [:]))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.declareTypes([.string, .png], owner: nil)
        pasteboard.setString("keep this text", forType: .string)
        pasteboard.setData(png, forType: .png)

        if let content = PastedContent.read(from: pasteboard) {
            Issue.record("Text-plus-image paste should fall back to normal text paste, got \(content)")
        }
    }

    @Test func readsImageFileURLs() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pasted-image-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let png = try #require(sampleImage().representation(using: .png, properties: [:]))
        try png.write(to: url)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        #expect(pasteboard.writeObjects([url as NSURL]))

        guard case .files(let urls) = PastedContent.read(from: pasteboard) else {
            Issue.record("Expected a file URL from an image file pasteboard")
            return
        }
        #expect(urls == [url])
    }

    @Test func fileURLTakesPrecedenceOverFilenameText() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pasted-finder-file-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("document".utf8).write(to: url)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.declareTypes([.string, .fileURL], owner: nil)
        #expect(pasteboard.setString(url.lastPathComponent, forType: .string))
        #expect(pasteboard.setString(url.absoluteString, forType: .fileURL))

        guard case .files(let urls) = PastedContent.read(from: pasteboard) else {
            Issue.record("Expected the file URL to take precedence over its filename string")
            return
        }
        #expect(urls == [url])
    }

    @Test func readsNonImageFileURLs() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pasted-document-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("document".utf8).write(to: url)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        #expect(pasteboard.writeObjects([url as NSURL]))

        guard case .files(let urls) = PastedContent.read(from: pasteboard) else {
            Issue.record("Expected a file URL from a non-image file pasteboard")
            return
        }
        #expect(urls == [url])
    }
}
