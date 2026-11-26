import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Stages dragged attachments (Finder files, macOS floating screenshot/screen-recording thumbnails,
/// file promises, and raw image drags) into Olaz-owned temporary files synchronously inside each
/// `NSItemProvider` completion callback so ephemeral system temp files never vanish before upload.
/// Regular Finder files outside temp locations pass through untouched with no copy.
enum ChatDropLoader {
    /// Content types accepted by `ChatView.onDrop`.
    /// - `.fileURL`: Finder files of any kind (images, videos, documents, folders).
    /// - `.image` / `.movie` / `.pdf`: macOS floating screenshot/recording thumbnails (`NSFilePromiseProvider`)
    ///   and dragged image/video representations. Deliberately excludes `.plainText` / `.data` so text drags
    ///   never trigger the attachment drop overlay.
    static let supportedTypes: [UTType] = [.fileURL, .image, .movie, .pdf]

    /// Maximum age for staged directories left behind by `.pending` uploads before being swept.
    static let stagingRetentionInterval: TimeInterval = 24 * 60 * 60

    struct StagedFile: Equatable, Sendable {
        let url: URL
        /// Olaz-owned staging subdirectory holding `url`; nil for pass-through items (non-temp Finder files
        /// and directories) that must never be deleted on cleanup.
        let ownedDirectory: URL?

        var isMedia: Bool { ChatDropLoader.isMediaURL(url) }
    }

    nonisolated static var defaultStagingRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("olaz-drops", isDirectory: true)
    }

    nonisolated static func canAccept(_ provider: NSItemProvider) -> Bool {
        supportedTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
    }

    nonisolated static func isMediaURL(_ url: URL) -> Bool {
        if let ut = UTType(filenameExtension: url.pathExtension), ut.conforms(to: .image) {
            return true
        }
        return ZaloEngine.isVideoURL(url)
    }

    /// True when `url` resides inside a system temp directory where drag sources (such as floating
    /// screenshot thumbnails or promised files) may delete the file before an upload finishes.
    nonisolated static func isEphemeralLocation(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let roots = [
            FileManager.default.temporaryDirectory,
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            URL(fileURLWithPath: "/private/var/folders", isDirectory: true),
            URL(fileURLWithPath: "/var/folders", isDirectory: true),
        ].map { $0.resolvingSymlinksInPath().standardizedFileURL.path }

        return roots.contains { root in
            let prefix = root.hasSuffix("/") ? root : root + "/"
            return resolved == root || resolved.hasPrefix(prefix)
        }
    }

    nonisolated static func cleanup(_ files: [StagedFile]) {
        for dir in Set(files.compactMap(\.ownedDirectory)) {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Best-effort cleanup of stale staging subdirectories (e.g. left by `.pending` sends) older than `maxAge`.
    nonisolated static func sweepExpiredStaging(
        in stagingRoot: URL = defaultStagingRoot,
        maxAge: TimeInterval = stagingRetentionInterval,
        now: Date = .now
    ) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let cutoff = now.addingTimeInterval(-maxAge)
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                  values.isDirectory == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else {
                continue
            }
            try? fm.removeItem(at: entry)
        }
    }

    @MainActor
    static func stage(_ providers: [NSItemProvider], stagingRoot: URL = defaultStagingRoot) async -> [StagedFile] {
        sweepExpiredStaging(in: stagingRoot)
        var staged: [StagedFile] = []
        for provider in providers {
            if let file = await stageOne(provider, stagingRoot: stagingRoot) {
                staged.append(file)
            }
        }
        return staged
    }

    @MainActor
    private static func stageOne(_ provider: NSItemProvider, stagingRoot: URL) async -> StagedFile? {
        let suggestedName = provider.suggestedName

        // 1. Regular file URLs (Finder drops and file-backed drags). Non-temp Finder files pass through untouched
        //    (no copy); only URLs under temp locations are copied synchronously inside the callback.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let file = await loadFromFileURL(provider, suggestedName: suggestedName, stagingRoot: stagingRoot) {
                return file
            }
        }

        // 2. File promises (macOS floating screenshot/recording thumbnails) and in-memory image/media drags.
        guard let typeId = preferredMediaOrFileTypeIdentifier(for: provider) else { return nil }

        if let file = await loadFromFileRepresentation(provider, typeId: typeId, suggestedName: suggestedName, stagingRoot: stagingRoot) {
            return file
        }
        if let file = await loadFromDataRepresentation(provider, typeId: typeId, suggestedName: suggestedName, stagingRoot: stagingRoot) {
            return file
        }
        return await loadFromItem(provider, typeId: typeId, suggestedName: suggestedName, stagingRoot: stagingRoot)
    }

    // MARK: - Provider loading

    @MainActor
    private static func loadFromFileURL(
        _ provider: NSItemProvider,
        suggestedName: String?,
        stagingRoot: URL
    ) async -> StagedFile? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let url = Self.extractFileURL(from: item) else {
                    continuation.resume(returning: nil)
                    return
                }
                guard Self.isEphemeralLocation(url) else {
                    continuation.resume(returning: StagedFile(url: url, ownedDirectory: nil))
                    return
                }
                let staged = Self.stageFileOnDisk(
                    from: url,
                    suggestedName: suggestedName,
                    typeId: nil,
                    convertTiffToPNG: false,
                    stagingRoot: stagingRoot
                )
                continuation.resume(returning: staged)
            }
        }
    }

    @MainActor
    private static func loadFromFileRepresentation(
        _ provider: NSItemProvider,
        typeId: String,
        suggestedName: String?,
        stagingRoot: URL
    ) async -> StagedFile? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeId) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                // AppKit deletes `url` as soon as this completion handler returns, so stage synchronously here.
                let staged = Self.stageFileOnDisk(
                    from: url,
                    suggestedName: suggestedName,
                    typeId: typeId,
                    convertTiffToPNG: true,
                    stagingRoot: stagingRoot
                )
                continuation.resume(returning: staged)
            }
        }
    }

    @MainActor
    private static func loadFromDataRepresentation(
        _ provider: NSItemProvider,
        typeId: String,
        suggestedName: String?,
        stagingRoot: URL
    ) async -> StagedFile? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: typeId) { data, _ in
                guard let data, !data.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                let staged = Self.stageData(data, typeId: typeId, suggestedName: suggestedName, stagingRoot: stagingRoot)
                continuation.resume(returning: staged)
            }
        }
    }

    @MainActor
    private static func loadFromItem(
        _ provider: NSItemProvider,
        typeId: String,
        suggestedName: String?,
        stagingRoot: URL
    ) async -> StagedFile? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeId, options: nil) { item, _ in
                if let url = Self.extractFileURL(from: item) {
                    let staged = Self.stageFileOnDisk(
                        from: url,
                        suggestedName: suggestedName,
                        typeId: typeId,
                        convertTiffToPNG: true,
                        stagingRoot: stagingRoot
                    )
                    continuation.resume(returning: staged)
                    return
                }
                if let data = item as? Data, !data.isEmpty {
                    let staged = Self.stageData(data, typeId: typeId, suggestedName: suggestedName, stagingRoot: stagingRoot)
                    continuation.resume(returning: staged)
                    return
                }
                if let image = item as? NSImage,
                   let tiff = image.tiffRepresentation,
                   let png = Self.encodePNG(from: tiff) {
                    let staged = Self.writeStagedBytes(
                        png,
                        preferredName: suggestedName,
                        defaultStem: "Screenshot",
                        extensionOverride: "png",
                        stagingRoot: stagingRoot
                    )
                    continuation.resume(returning: staged)
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - Type selection & synchronous staging

    nonisolated static func preferredMediaOrFileTypeIdentifier(for provider: NSItemProvider) -> String? {
        let registered = provider.registeredTypeIdentifiers

        // Prefer web-ready photo formats first so multi-representation drags (e.g. PNG + TIFF) keep PNG.
        let preferredImages: [UTType] = [.png, .jpeg, .webP, .gif, .heic]
        for type in preferredImages where registered.contains(type.identifier) {
            return type.identifier
        }
        if let otherConcreteImage = registered.first(where: { id in
            guard let ut = UTType(id) else { return false }
            return ut.conforms(to: .image) && ut != .image && ut != .tiff
        }) {
            return otherConcreteImage
        }
        if registered.contains(UTType.tiff.identifier) {
            return UTType.tiff.identifier
        }

        let preferredMovies: [UTType] = [.mpeg4Movie, .quickTimeMovie]
        for type in preferredMovies where registered.contains(type.identifier) {
            return type.identifier
        }
        if let otherConcreteMovie = registered.first(where: { id in
            guard let ut = UTType(id) else { return false }
            return ut.conforms(to: .movie) && ut != .movie
        }) {
            return otherConcreteMovie
        }

        if registered.contains(UTType.pdf.identifier) {
            return UTType.pdf.identifier
        }

        for fallback in [UTType.png, .jpeg, .image, .movie, .pdf] {
            if provider.hasItemConformingToTypeIdentifier(fallback.identifier) {
                return fallback.identifier
            }
        }
        return nil
    }

    private nonisolated static func extractFileURL(from item: NSSecureCoding?) -> URL? {
        let url: URL?
        if let data = item as? Data, let str = String(data: data, encoding: .utf8) {
            url = URL(string: str)
        } else if let direct = item as? URL {
            url = direct
        } else if let nsurl = item as? NSURL {
            url = nsurl as URL
        } else {
            url = nil
        }
        guard let url, url.isFileURL else { return nil }
        return url
    }

    private nonisolated static func stageFileOnDisk(
        from sourceURL: URL,
        suggestedName: String?,
        typeId: String?,
        convertTiffToPNG: Bool,
        stagingRoot: URL
    ) -> StagedFile? {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDir) else {
            return nil
        }
        if isDir.boolValue {
            // Preserve Finder folder drops as-is so `ZaloEngine.validateOutgoingFile` reports the folder notice.
            return StagedFile(url: sourceURL, ownedDirectory: nil)
        }

        // Non-Finder image drags (including `NSItemProvider(object: NSImage)`) can write raw TIFF bytes even into
        // a temp file named `.png` or `.jpeg`. Sniff the file header and transcode TIFF to real PNG bytes.
        let sourceExt = sourceURL.pathExtension.lowercased()
        let needsTiffTranscode = convertTiffToPNG && (
            sourceExt == "tiff" || sourceExt == "tif" || (isImageType(typeId) && isTIFFFile(at: sourceURL))
        )
        if needsTiffTranscode,
           let raw = try? Data(contentsOf: sourceURL),
           let png = encodePNG(from: raw) {
            let base = sourceURL.deletingPathExtension().lastPathComponent
            if let staged = writeStagedBytes(
                png,
                preferredName: base.isEmpty ? suggestedName : base,
                defaultStem: "Screenshot",
                extensionOverride: "png",
                stagingRoot: stagingRoot
            ) {
                return staged
            }
        }

        let fallbackExt = fallbackExtension(for: typeId)
        let preferred = sourceURL.lastPathComponent
        let fileName = resolvedFileName(
            preferred: preferred,
            suggestedName: suggestedName,
            defaultStem: isImageType(typeId) ? "Screenshot" : "Attachment",
            fallbackExtension: fallbackExt,
            forceExtension: nil
        )
        let runDir = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
            let dest = runDir.appendingPathComponent(fileName)
            do {
                try FileManager.default.copyItem(at: sourceURL, to: dest)
            } catch {
                let data = try Data(contentsOf: sourceURL)
                try data.write(to: dest, options: .atomic)
            }
            return StagedFile(url: dest, ownedDirectory: runDir)
        } catch {
            try? FileManager.default.removeItem(at: runDir)
            return nil
        }
    }

    private nonisolated static func stageData(
        _ data: Data,
        typeId: String,
        suggestedName: String?,
        stagingRoot: URL
    ) -> StagedFile? {
        if isImageType(typeId) {
            if let webExt = detectWebImageExtension(data) {
                return writeStagedBytes(
                    data,
                    preferredName: suggestedName,
                    defaultStem: "Screenshot",
                    extensionOverride: webExt,
                    stagingRoot: stagingRoot
                )
            }
            if let png = encodePNG(from: data) {
                return writeStagedBytes(
                    png,
                    preferredName: suggestedName,
                    defaultStem: "Screenshot",
                    extensionOverride: "png",
                    stagingRoot: stagingRoot
                )
            }
        }
        let ext = fallbackExtension(for: typeId) ?? "bin"
        return writeStagedBytes(
            data,
            preferredName: suggestedName,
            defaultStem: isImageType(typeId) ? "Screenshot" : "Attachment",
            extensionOverride: ext,
            stagingRoot: stagingRoot
        )
    }

    private nonisolated static func writeStagedBytes(
        _ data: Data,
        preferredName: String?,
        defaultStem: String,
        extensionOverride: String,
        stagingRoot: URL
    ) -> StagedFile? {
        let fileName = resolvedFileName(
            preferred: nil,
            suggestedName: preferredName,
            defaultStem: defaultStem,
            fallbackExtension: extensionOverride,
            forceExtension: extensionOverride
        )
        let runDir = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
            let dest = runDir.appendingPathComponent(fileName)
            try data.write(to: dest, options: .atomic)
            return StagedFile(url: dest, ownedDirectory: runDir)
        } catch {
            try? FileManager.default.removeItem(at: runDir)
            return nil
        }
    }

    private nonisolated static func isImageType(_ typeId: String?) -> Bool {
        guard let typeId, let ut = UTType(typeId) else { return false }
        return ut.conforms(to: .image)
    }

    private nonisolated static func isTIFFFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
        let bytes = [UInt8](head)
        // Little-endian TIFF ("II*\0") or big-endian TIFF ("MM\0*").
        return (bytes[0] == 0x49 && bytes[1] == 0x49 && bytes[2] == 0x2A && bytes[3] == 0x00)
            || (bytes[0] == 0x4D && bytes[1] == 0x4D && bytes[2] == 0x00 && bytes[3] == 0x2A)
    }

    private nonisolated static func fallbackExtension(for typeId: String?) -> String? {
        guard let typeId, let ut = UTType(typeId) else { return nil }
        if let ext = ut.preferredFilenameExtension, !ext.isEmpty { return ext }
        if ut.conforms(to: .image) { return "png" }
        if ut.conforms(to: .movie) { return "mov" }
        if ut.conforms(to: .pdf) { return "pdf" }
        return nil
    }

    private nonisolated static func resolvedFileName(
        preferred: String?,
        suggestedName: String?,
        defaultStem: String,
        fallbackExtension: String?,
        forceExtension: String?
    ) -> String {
        let raw = sanitizeComponent(preferred) ?? sanitizeComponent(suggestedName) ?? defaultStem
        if let forceExtension, !forceExtension.isEmpty {
            let currentExt = (raw as NSString).pathExtension.lowercased()
            if currentExt == forceExtension.lowercased() { return raw }
            let stem = (raw as NSString).deletingPathExtension
            let cleanStem = sanitizeComponent(stem) ?? defaultStem
            return "\(cleanStem).\(forceExtension)"
        }
        let currentExt = (raw as NSString).pathExtension
        if currentExt.isEmpty, let fallbackExtension, !fallbackExtension.isEmpty {
            return "\(raw).\(fallbackExtension)"
        }
        return raw
    }

    private nonisolated static func sanitizeComponent(_ value: String?) -> String? {
        guard let value else { return nil }
        let last = (value as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !last.isEmpty, last != ".", last != ".." else { return nil }
        return last
    }

    private nonisolated static func detectWebImageExtension(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 4, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
            return "png"
        }
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return "jpg"
        }
        if bytes.count >= 4, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x38 {
            return "gif"
        }
        if bytes.count >= 12,
           bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
            return "webp"
        }
        return nil
    }

    private nonisolated static func encodePNG(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
