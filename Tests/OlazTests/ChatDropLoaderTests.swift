import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Olaz

@MainActor @Suite struct ChatDropLoaderTests {
    private func makeStagingRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-drop-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeNonTempDirectory() throws -> URL {
        let caches = try #require(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        let dir = caches.appendingPathComponent("olaz-drop-nontemp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sampleBitmap() throws -> NSBitmapImageRep {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        rep.setColor(NSColor(deviceRed: 0, green: 0.4, blue: 1, alpha: 1), atX: 0, y: 0)
        rep.setColor(NSColor(deviceRed: 0, green: 0.8, blue: 0.2, alpha: 1), atX: 3, y: 3)
        return rep
    }

    private func samplePNG() throws -> Data {
        try #require(sampleBitmap().representation(using: .png, properties: [:]))
    }

    private func sampleTIFF() throws -> Data {
        try #require(sampleBitmap().representation(using: .tiff, properties: [:]))
    }

    // MARK: - Acceptance

    @Test func acceptsFileURLImageMovieAndPDFButRejectsPlainText() throws {
        let png = try samplePNG()

        let fileProvider = NSItemProvider(contentsOf: URL(fileURLWithPath: "/tmp/example.txt"))
        let pngProvider = NSItemProvider()
        pngProvider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { cb in
            cb(png, nil)
            return nil
        }
        let movieProvider = NSItemProvider()
        movieProvider.registerDataRepresentation(forTypeIdentifier: UTType.quickTimeMovie.identifier, visibility: .all) { cb in
            cb(Data([0x00, 0x00, 0x00, 0x18]), nil)
            return nil
        }
        let pdfProvider = NSItemProvider()
        pdfProvider.registerDataRepresentation(forTypeIdentifier: UTType.pdf.identifier, visibility: .all) { cb in
            cb(Data("%PDF-1.4".utf8), nil)
            return nil
        }
        let textProvider = NSItemProvider(object: "plain dragged text" as NSString)

        if let fileProvider { #expect(ChatDropLoader.canAccept(fileProvider)) }
        #expect(ChatDropLoader.canAccept(pngProvider))
        #expect(ChatDropLoader.canAccept(movieProvider))
        #expect(ChatDropLoader.canAccept(pdfProvider))
        #expect(!ChatDropLoader.canAccept(textProvider))
    }

    // MARK: - Finder fileURL drops (no-copy pass-through outside temp, staged inside temp)

    @Test func nonTempFinderFilesPassThroughWithoutCopyAndPreserveMediaSplit() async throws {
        let stagingRoot = try makeStagingRoot()
        let finderDir = try makeNonTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: stagingRoot)
            try? FileManager.default.removeItem(at: finderDir)
        }

        #expect(!ChatDropLoader.isEphemeralLocation(finderDir))

        let pngData = try samplePNG()
        let mp4Data = Data("fake-mp4-bytes".utf8)
        let pdfData = Data("%PDF-1.4\nbody".utf8)

        let pngURL = finderDir.appendingPathComponent("photo.png")
        let mp4URL = finderDir.appendingPathComponent("clip.mp4")
        let pdfURL = finderDir.appendingPathComponent("report.pdf")
        try pngData.write(to: pngURL)
        try mp4Data.write(to: mp4URL)
        try pdfData.write(to: pdfURL)

        let providers = [pngURL, mp4URL, pdfURL].map { NSItemProvider(object: $0 as NSURL) }
        let staged = await ChatDropLoader.stage(providers, stagingRoot: stagingRoot)

        #expect(staged.count == 3)
        #expect(staged[0] == ChatDropLoader.StagedFile(url: pngURL, ownedDirectory: nil))
        #expect(staged[0].isMedia)
        #expect(staged[1] == ChatDropLoader.StagedFile(url: mp4URL, ownedDirectory: nil))
        #expect(staged[1].isMedia)
        #expect(staged[2] == ChatDropLoader.StagedFile(url: pdfURL, ownedDirectory: nil))
        #expect(!staged[2].isMedia)

        // Nothing should have been copied into stagingRoot.
        let stagingContents = try FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)
        #expect(stagingContents.isEmpty)

        // Cleanup leaves original Finder files untouched.
        ChatDropLoader.cleanup(staged)
        #expect(FileManager.default.fileExists(atPath: pngURL.path))
        #expect(FileManager.default.fileExists(atPath: mp4URL.path))
        #expect(FileManager.default.fileExists(atPath: pdfURL.path))
    }

    @Test func directoryDropPassesThroughWithoutOwnedStagingAndCleanupLeavesItIntact() async throws {
        let stagingRoot = try makeStagingRoot()
        let folder = try makeStagingRoot()
        defer {
            try? FileManager.default.removeItem(at: stagingRoot)
            try? FileManager.default.removeItem(at: folder)
        }

        let provider = NSItemProvider(object: folder as NSURL)
        let staged = await ChatDropLoader.stage([provider], stagingRoot: stagingRoot)

        #expect(staged.count == 1)
        #expect(staged[0].url.standardizedFileURL == folder.standardizedFileURL)
        #expect(staged[0].ownedDirectory == nil)
        #expect(!staged[0].isMedia)

        ChatDropLoader.cleanup(staged)
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: - Ephemeral temp files & file representations (macOS floating screenshot thumbnail / NSFilePromiseProvider)

    @Test func ephemeralFileRepresentationSurvivesDeletionWhenCallbackReturns() async throws {
        let stagingRoot = try makeStagingRoot()
        let ephemeralDir = try makeStagingRoot()
        defer {
            try? FileManager.default.removeItem(at: stagingRoot)
            try? FileManager.default.removeItem(at: ephemeralDir)
        }

        let pngData = try samplePNG()
        let ephemeralFile = ephemeralDir.appendingPathComponent("Screenshot 2026-11-26 at 18.00.00.png")

        let provider = NSItemProvider()
        provider.suggestedName = "Screenshot 2026-11-26 at 18.00.00"
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            try? pngData.write(to: ephemeralFile)
            completion(ephemeralFile, false, nil)
            // Simulate AppKit/NSFilePromiseReceiver deleting the promised file immediately after callback returns.
            try? FileManager.default.removeItem(at: ephemeralFile)
            return nil
        }

        #expect(ChatDropLoader.canAccept(provider))
        let staged = await ChatDropLoader.stage([provider], stagingRoot: stagingRoot)

        #expect(!FileManager.default.fileExists(atPath: ephemeralFile.path))
        let file = try #require(staged.first)
        #expect(file.isMedia)
        #expect(file.ownedDirectory != nil)
        #expect(file.url.pathExtension.lowercased() == "png")
        #expect(FileManager.default.fileExists(atPath: file.url.path))
        #expect(try Data(contentsOf: file.url) == pngData)

        ChatDropLoader.cleanup(staged)
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }

    @Test func tempFileURLIsStagedAndSurvivesSourceDeletionAfterDrop() async throws {
        let stagingRoot = try makeStagingRoot()
        let ephemeralDir = try makeStagingRoot()
        defer {
            try? FileManager.default.removeItem(at: stagingRoot)
            try? FileManager.default.removeItem(at: ephemeralDir)
        }

        let pngData = try samplePNG()
        let transientFile = ephemeralDir.appendingPathComponent("transient-shot.png")
        try pngData.write(to: transientFile)

        #expect(ChatDropLoader.isEphemeralLocation(transientFile))

        let provider = NSItemProvider(object: transientFile as NSURL)
        let staged = await ChatDropLoader.stage([provider], stagingRoot: stagingRoot)

        // Delete the original source file right after staging (simulating a floating thumbnail dismissing
        // before the async network upload finishes).
        try FileManager.default.removeItem(at: transientFile)

        let file = try #require(staged.first)
        #expect(file.isMedia)
        #expect(file.ownedDirectory != nil)
        #expect(file.url.path.hasPrefix(stagingRoot.path))
        #expect(file.url.lastPathComponent == "transient-shot.png")
        #expect(FileManager.default.fileExists(atPath: file.url.path))
        #expect(try Data(contentsOf: file.url) == pngData)

        ChatDropLoader.cleanup(staged)
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }

    // MARK: - Stale staging sweep

    @Test func stageSweepsBackdatedStagingDirectoriesOlderThan24Hours() async throws {
        let stagingRoot = try makeStagingRoot()
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        let staleDir = stagingRoot.appendingPathComponent("stale-\(UUID().uuidString)", isDirectory: true)
        let freshDir = stagingRoot.appendingPathComponent("fresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staleDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: freshDir, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: staleDir.appendingPathComponent("shot.png"))
        try Data("new".utf8).write(to: freshDir.appendingPathComponent("shot.png"))

        let twentyFiveHoursAgo = Date().addingTimeInterval(-25 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: twentyFiveHoursAgo], ofItemAtPath: staleDir.path)

        _ = await ChatDropLoader.stage([], stagingRoot: stagingRoot)

        #expect(!FileManager.default.fileExists(atPath: staleDir.path))
        #expect(FileManager.default.fileExists(atPath: freshDir.path))
    }

    // MARK: - In-memory image & movie drags

    @Test func imageDataOnlyPNGProviderStagesAsMediaPNG() async throws {
        let stagingRoot = try makeStagingRoot()
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        let pngData = try samplePNG()
        let provider = NSItemProvider()
        provider.suggestedName = "Clipped Shot"
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { cb in
            cb(pngData, nil)
            return nil
        }

        let staged = await ChatDropLoader.stage([provider], stagingRoot: stagingRoot)
        let file = try #require(staged.first)
        #expect(file.isMedia)
        #expect(file.url.lastPathComponent == "Clipped Shot.png")
        #expect(try Data(contentsOf: file.url) == pngData)

        ChatDropLoader.cleanup(staged)
    }

    @Test func tiffOnlyImageDataProviderTranscodesToPNG() async throws {
        let stagingRoot = try makeStagingRoot()
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        let tiffData = try sampleTIFF()
        let provider = NSItemProvider()
        provider.suggestedName = "Preview Capture"
        provider.registerDataRepresentation(forTypeIdentifier: UTType.tiff.identifier, visibility: .all) { cb in
            cb(tiffData, nil)
            return nil
        }

        let staged = await ChatDropLoader.stage([provider], stagingRoot: stagingRoot)
        let file = try #require(staged.first)
        #expect(file.isMedia)
        #expect(file.url.pathExtension.lowercased() == "png")
        let bytes = try Data(contentsOf: file.url)
        #expect(bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(NSImage(data: bytes) != nil)

        ChatDropLoader.cleanup(staged)
    }

    @Test func nsImageObjectProviderStagesAsValidPNG() async throws {
        let stagingRoot = try makeStagingRoot()
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        let image = try #require(NSImage(data: samplePNG()))
        let provider = NSItemProvider(object: image)

        #expect(ChatDropLoader.canAccept(provider))
        let staged = await ChatDropLoader.stage([provider], stagingRoot: stagingRoot)
        let file = try #require(staged.first)
        #expect(file.isMedia)
        #expect(file.url.pathExtension.lowercased() == "png")
        let bytes = try Data(contentsOf: file.url)
        #expect(bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(NSImage(data: bytes) != nil)

        ChatDropLoader.cleanup(staged)
    }

    @Test func screenRecordingMovieFileRepresentationStagesAsMediaMov() async throws {
        let stagingRoot = try makeStagingRoot()
        let ephemeralDir = try makeStagingRoot()
        defer {
            try? FileManager.default.removeItem(at: stagingRoot)
            try? FileManager.default.removeItem(at: ephemeralDir)
        }

        let movieBytes = Data("quicktime-recording-payload".utf8)
        let tempMov = ephemeralDir.appendingPathComponent("Screen Recording.mov")

        let provider = NSItemProvider()
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.quickTimeMovie.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            try? movieBytes.write(to: tempMov)
            completion(tempMov, false, nil)
            try? FileManager.default.removeItem(at: tempMov)
            return nil
        }

        let staged = await ChatDropLoader.stage([provider], stagingRoot: stagingRoot)
        let file = try #require(staged.first)
        #expect(file.isMedia)
        #expect(file.url.pathExtension.lowercased() == "mov")
        #expect(try Data(contentsOf: file.url) == movieBytes)

        ChatDropLoader.cleanup(staged)
    }

    @Test func plainTextProviderReturnsEmpty() async throws {
        let stagingRoot = try makeStagingRoot()
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        let provider = NSItemProvider(object: "hello world" as NSString)
        let staged = await ChatDropLoader.stage([provider], stagingRoot: stagingRoot)
        #expect(staged.isEmpty)
    }

    @Test func multiRepresentationProviderPrefersPNGOverTIFF() throws {
        let png = try samplePNG()
        let tiff = try sampleTIFF()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.tiff.identifier, visibility: .all) { cb in
            cb(tiff, nil)
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { cb in
            cb(png, nil)
            return nil
        }

        #expect(ChatDropLoader.preferredMediaOrFileTypeIdentifier(for: provider) == UTType.png.identifier)
    }
}
