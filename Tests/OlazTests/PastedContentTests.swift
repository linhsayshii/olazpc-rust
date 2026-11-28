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
        let pb = pasteboard(with: .png, data: png)
        #expect(PastedContent.canRead(from: pb))
        let result = PastedContent.read(from: pb)
        guard case .image(let data) = result else {
            Issue.record("Expected an image from an image-only PNG pasteboard")
            return
        }
        #expect(NSImage(data: data) != nil)
    }

    @Test func readsImageOnlyTIFFAsPNG() throws {
        let tiff = try #require(sampleImage().representation(using: .tiff, properties: [:]))
        let pb = pasteboard(with: .tiff, data: tiff)
        #expect(PastedContent.canRead(from: pb))
        let result = PastedContent.read(from: pb)
        guard case .image(let data) = result else {
            Issue.record("Expected an image from an image-only TIFF pasteboard")
            return
        }
        #expect(NSImage(data: data) != nil)
        #expect(data.starts(with: [0x89, 0x50, 0x4e, 0x47]))
    }

    @Test func pngImageWithStringPrefersImage() throws {
        let png = try #require(sampleImage().representation(using: .png, properties: [:]))
        let pb = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pb.declareTypes([.string, .png, .html], owner: nil)
        pb.setString("https://example.com/photo.png", forType: .string)
        pb.setString("<img src=\"https://example.com/photo.png\">", forType: .html)
        pb.setData(png, forType: .png)

        #expect(PastedContent.canRead(from: pb))
        guard case .image(let data) = PastedContent.read(from: pb) else {
            Issue.record("Expected image attachment when pasteboard carries PNG + URL string (browser Copy Image)")
            return
        }
        #expect(NSImage(data: data) != nil)
    }

    @Test func tiffImageWithStringPrefersImage() throws {
        let tiff = try #require(sampleImage().representation(using: .tiff, properties: [:]))
        let pb = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pb.declareTypes([.string, .tiff], owner: nil)
        pb.setString("https://example.com/image.jpg", forType: .string)
        pb.setData(tiff, forType: .tiff)

        #expect(PastedContent.canRead(from: pb))
        guard case .image(let data) = PastedContent.read(from: pb) else {
            Issue.record("Expected image attachment when pasteboard carries TIFF + URL string (Safari Copy Image)")
            return
        }
        #expect(NSImage(data: data) != nil)
        #expect(data.starts(with: [0x89, 0x50, 0x4e, 0x47]))
    }

    @Test func jpegImageWithStringPrefersImage() throws {
        let jpeg = try #require(sampleImage().representation(using: .jpeg, properties: [:]))
        let jpegType = NSPasteboard.PasteboardType("public.jpeg")
        let pb = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pb.declareTypes([.string, jpegType], owner: nil)
        pb.setString("photo.jpg", forType: .string)
        pb.setData(jpeg, forType: jpegType)

        #expect(PastedContent.canRead(from: pb))
        guard case .image(let data) = PastedContent.read(from: pb) else {
            Issue.record("Expected image attachment when pasteboard carries JPEG + string")
            return
        }
        #expect(NSImage(data: data) != nil)
        #expect(data.starts(with: [0x89, 0x50, 0x4e, 0x47]))
    }

    @Test func plainTextOnlyFallsBackToTextPaste() {
        let pb = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pb.declareTypes([.string], owner: nil)
        pb.setString("xin chào mọi người", forType: .string)

        #expect(!PastedContent.canRead(from: pb))
        #expect(PastedContent.read(from: pb) == nil)
    }

    @Test func webURLStringFallsBackToTextPaste() {
        let pb = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pb.declareTypes([.string, .URL], owner: nil)
        pb.setString("https://example.com", forType: .string)
        pb.setString("https://example.com", forType: .URL)

        #expect(!PastedContent.canRead(from: pb))
        #expect(PastedContent.read(from: pb) == nil)
    }

    @Test func pdfFlavorWithTextStaysTextPaste() {
        let pb = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pb.declareTypes([.string, .pdf], owner: nil)
        pb.setString("copied from PDF", forType: .string)
        pb.setData(Data("%PDF-1.4\n%%EOF".utf8), forType: .pdf)

        #expect(!PastedContent.canRead(from: pb))
        #expect(PastedContent.read(from: pb) == nil)
    }

    @Test func corruptImageWithTextFallsBackToTextPaste() {
        let pb = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pb.declareTypes([.string, .png], owner: nil)
        pb.setString("fallback text", forType: .string)
        pb.setData(Data("not-a-valid-png".utf8), forType: .png)

        #expect(PastedContent.read(from: pb) == nil)
    }

    @Test func readsImageFileURLs() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pasted-image-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let png = try #require(sampleImage().representation(using: .png, properties: [:]))
        try png.write(to: url)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        #expect(pasteboard.writeObjects([url as NSURL]))

        #expect(PastedContent.canRead(from: pasteboard))
        guard case .files(let urls) = PastedContent.read(from: pasteboard) else {
            Issue.record("Expected a file URL from an image file pasteboard")
            return
        }
        #expect(urls == [url])
    }

    @Test func fileURLTakesPrecedenceOverFilenameTextAndIcon() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pasted-finder-file-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("document".utf8).write(to: url)
        let iconTiff = try #require(sampleImage().representation(using: .tiff, properties: [:]))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.declareTypes([.string, .tiff, .fileURL], owner: nil)
        #expect(pasteboard.setString(url.lastPathComponent, forType: .string))
        #expect(pasteboard.setData(iconTiff, forType: .tiff))
        #expect(pasteboard.setString(url.absoluteString, forType: .fileURL))

        #expect(PastedContent.canRead(from: pasteboard))
        guard case .files(let urls) = PastedContent.read(from: pasteboard) else {
            Issue.record("Expected the file URL to take precedence over its filename string and icon TIFF")
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

        #expect(PastedContent.canRead(from: pasteboard))
        guard case .files(let urls) = PastedContent.read(from: pasteboard) else {
            Issue.record("Expected a file URL from a non-image file pasteboard")
            return
        }
        #expect(urls == [url])
    }

    @MainActor
    @Test func composerFieldTextViewValidatesAndPastesImageOnlyClipboard() throws {
        let png = try #require(sampleImage().representation(using: .png, properties: [:]))
        let pb = pasteboard(with: .png, data: png)

        let tv = ComposerTextView.FieldTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        tv.isEditable = true
        tv.isRichText = false
        tv.importsGraphics = false
        tv.pasteboardProvider = { pb }

        var pasted: PastedContent?
        tv.onPasteAttachment = { pasted = $0 }

        let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        #expect(tv.validateMenuItem(pasteItem))
        #expect(tv.validateUserInterfaceItem(pasteItem))

        tv.paste(nil)
        guard case .image(let data) = pasted else {
            Issue.record("Expected FieldTextView.paste to forward image-only clipboard to onPasteAttachment")
            return
        }
        #expect(NSImage(data: data) != nil)
    }

    @MainActor
    @Test func composerFieldTextViewPastesPlainTextIntoField() {
        let pb = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pb.declareTypes([.string], owner: nil)
        pb.setString("hello composer", forType: .string)

        let tv = ComposerTextView.FieldTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        tv.isEditable = true
        tv.isRichText = false
        tv.importsGraphics = false
        tv.pasteboardProvider = { pb }

        var attachmentCalled = false
        tv.onPasteAttachment = { _ in attachmentCalled = true }

        tv.paste(nil)
        #expect(!attachmentCalled)
        #expect(tv.string == "hello composer")
    }
}
