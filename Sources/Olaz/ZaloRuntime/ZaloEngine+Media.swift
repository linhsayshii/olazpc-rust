import AVFoundation
import Foundation
import ImageIO
import OlazCore
import UniformTypeIdentifiers

/// What the official client's media loader made of a message's photo / video thumbnail / video.
enum MediaResolution: Equatable, Sendable {
    /// A local file (the official `ZaloDownloads` copy) to load.
    case file(URL)
    /// Every source is gone and the message is past the official shelf life (Zalo shows "expired").
    case expired
    /// Could not be loaded now (offline, server error, not synced…); worth a retry.
    case unavailable
    /// This kind of media is not resolved through the official image loader.
    case unsupported

    init(json: Any?) {
        guard let dict = json as? [String: Any], let state = dict["state"] as? String else { self = .unavailable; return }
        switch state {
        case "ok":
            if let path = dict["path"] as? String, path.hasPrefix("/") { self = .file(URL(fileURLWithPath: path)) } else { self = .unavailable }
        case "expired": self = .expired
        case "unsupported": self = .unsupported
        default: self = .unavailable
        }
    }
}

enum MediaKind: String, Sendable {
    case photo
    case videoThumb
    /// The video itself, as the official inline player gets it (downloaded and, for E2EE, decrypted).
    case video
}

/// De-duplicates and throttles `window.__zaloChat.resolveMedia` calls: a screenful of retired CDN links
/// must not start dozens of official downloads at once, and the same message is resolved once.
///
/// Queued work is dropped when every view waiting for it is gone (scrolled away), and the newest request
/// goes first, so photos on screen are not stuck behind off-screen dead ones.
@MainActor
final class MediaResolver {
    static let unavailableTTL: TimeInterval = 30

    private final class Flight: @unchecked Sendable {
        var task: Task<MediaResolution?, Never>!
        var waiters = 0
    }
    private final class Waiter: @unchecked Sendable { var released = false }

    private var settled: [String: (resolution: MediaResolution, until: Date)] = [:]
    private var flights: [String: Flight] = [:]
    private var running = 0
    private var queue: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
    let maxConcurrent: Int
    var now: () -> Date = { Date() }

    init(maxConcurrent: Int = 3) { self.maxConcurrent = maxConcurrent }

    /// The remembered verdict for `key`, if any.
    func known(_ key: String) -> MediaResolution? { settled[key]?.resolution }

    /// Requests waiting for a slot (tests).
    var queuedCount: Int { queue.count }

    /// `force` (the retry button) ignores any remembered verdict except a final "expired": a remembered
    /// "unavailable" is retried, and a remembered file that turned out not to be loadable is looked up again.
    func resolve(key: String, force: Bool = false, run: @escaping @MainActor () async -> MediaResolution) async -> MediaResolution {
        if let known = settled[key], known.until > now() {
            switch known.resolution {
            case .unavailable where force: break
            case .file where force: break
            case .file(let url) where !FileManager.default.fileExists(atPath: url.path): break
            default: return known.resolution
            }
        }
        let flight: Flight
        if let existing = flights[key] {
            flight = existing
        } else {
            flight = Flight()
            flight.task = Task { @MainActor [weak self] () -> MediaResolution? in
                guard let self, await self.acquire() else { return nil }
                defer { self.release() }
                if Task.isCancelled { return nil }
                return await run()
            }
            flights[key] = flight
        }
        flight.waiters += 1
        let waiter = Waiter()
        let outcome = await withTaskCancellationHandler {
            await flight.task.value
        } onCancel: {
            Task { @MainActor in self.leave(key, flight, waiter) }
        }
        leave(key, flight, waiter)
        guard let resolution = outcome else { return .unavailable }          // dropped before it started
        if flights[key] === flight { flights[key] = nil }
        switch resolution {
        case .unavailable: settled[key] = (resolution, now().addingTimeInterval(Self.unavailableTTL))
        case .file, .expired, .unsupported: settled[key] = (resolution, .distantFuture)
        }
        if settled.count > 2000 { settled = settled.filter { $0.value.until > Date() } }
        return resolution
    }

    /// One waiter left; with none remaining the flight is cancelled (it only dies if it has not started).
    private func leave(_ key: String, _ flight: Flight, _ waiter: Waiter) {
        guard !waiter.released else { return }
        waiter.released = true
        flight.waiters -= 1
        if flight.waiters <= 0 {
            if flights[key] === flight { flights[key] = nil }
            flight.task.cancel()
        }
    }

    /// Takes a slot; false when cancelled while queued. Newest waiter is served first.
    private func acquire() async -> Bool {
        if Task.isCancelled { return false }
        if running < maxConcurrent { running += 1; return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                queue.append((id, continuation))
            }
        } onCancel: {
            Task { @MainActor in
                guard let index = self.queue.firstIndex(where: { $0.id == id }) else { return }
                self.queue.remove(at: index).continuation.resume(returning: false)
            }
        }
    }

    private func release() {
        if let next = queue.popLast() { next.continuation.resume(returning: true) } else { running -= 1 }
    }
}

enum MediaLoaderFetchResult: Sendable {
    case data(Data)
    case file(URL)
}

enum FileResolution: Equatable, Sendable {
    /// Local staged file bearing the sanitized real filename and extension.
    case ready(URL)
    /// File is no longer on Zalo's CDN (`HTTP 404/410` or retired host).
    case expired
    /// Transient or decode failure with user-facing Vietnamese explanation.
    case failed(String)
}

enum ChatFileResolver {
    nonisolated static func sanitizedFileName(_ rawName: String, fallbackExtension: String? = nil) -> String {
        mediaSanitizedFileName(rawName: rawName, fallbackExtension: fallbackExtension)
    }

    nonisolated static func isPermanentGone(_ error: Error) -> Bool {
        mediaFileLoadErrorIsPermanentGone(kind: FileLoadErrorKindRecord(error: error))
    }

    nonisolated static func userMessage(for error: Error) -> String {
        mediaFileLoadErrorUserMessage(kind: FileLoadErrorKindRecord(error: error))
    }

    nonisolated static func resolve(
        name: String,
        url: URL?,
        force: Bool = false,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> FileResolution {
        guard let remoteURL = url else {
            return .failed("Tin nhắn không có đường dẫn tải tệp.")
        }
        if force, !remoteURL.isFileURL {
            await MediaLoader.shared.evictCachedFile(for: remoteURL)
        }
        let cachedFile: URL
        do {
            cachedFile = try await MediaLoader.shared.localFile(for: remoteURL, progress: progress)
        } catch is CancellationError {
            return .failed("Đã huỷ tải tệp.")
        } catch {
            if isPermanentGone(error) {
                return .expired
            }
            return .failed(userMessage(for: error))
        }

        let container = CloudContainer(fileAt: cachedFile)
        let safeFull = sanitizedFileName(name, fallbackExtension: container.fileExtension)
        let ext = (safeFull as NSString).pathExtension
        let stem = ext.isEmpty ? safeFull : (safeFull as NSString).deletingPathExtension

        if let staged = await MainActor.run(body: {
            CloudFiles.stage(cachedFile, name: stem.isEmpty ? "Tệp đính kèm" : stem, ext: ext.isEmpty ? nil : ext)
        }) {
            return .ready(staged)
        }
        return .ready(cachedFile)
    }

    /// Copies `staged` into `~/Downloads/<uniqueSafeName>` without overwriting existing files.
    nonisolated static func saveToDownloads(
        staged: URL,
        displayName: String,
        downloadsDirectory: URL? = nil
    ) throws -> URL {
        let fm = FileManager.default
        let dir = downloadsDirectory ?? fm.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let container = CloudContainer(fileAt: staged)
        let fallbackExt = staged.pathExtension.isEmpty ? container.fileExtension : staged.pathExtension
        let safeName = sanitizedFileName(displayName, fallbackExtension: fallbackExt)
        let ext = (safeName as NSString).pathExtension
        let stem = ext.isEmpty ? safeName : (safeName as NSString).deletingPathExtension

        var candidate = dir.appendingPathComponent(safeName)
        var counter = 1
        while fm.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            candidate = dir.appendingPathComponent(numbered)
            counter += 1
        }

        try fm.copyItem(at: staged, to: candidate)
        let origin = URL(string: "https://chat.zalo.me/")!
        MediaLoader.applyQuarantine(to: candidate, origin: origin)
        return candidate
    }
}

extension ZaloEngine {
    internal func findMessageForMedia(conversationId: String, messageId: String) async -> ChatMessage? {
        if !conversationId.isEmpty,
           let mem = self.messages[conversationId]?.first(where: { $0.id == messageId }) {
            return mem
        }
        if !conversationId.isEmpty,
           let store = self.sqliteStore,
           let row = try? await store.decodedMessage(convId: conversationId, idOrClientId: messageId) {
            return row.message
        }
        for list in self.messages.values {
            if let hit = list.first(where: { $0.id == messageId }) {
                return hit
            }
        }
        return nil
    }

    internal nonisolated static func mediaExtension(for container: CloudContainer, fallbackKind: MediaKind) -> String {
        switch container {
        case .jpeg: return "jpg"
        case .jxl, .png, .gif, .webp, .heic, .mp4, .m4a:
            return container.rawValue
        default:
            return fallbackKind == .video ? "mp4" : "jpg"
        }
    }

    internal nonisolated static func isValidMediaFile(_ url: URL, kind: MediaKind) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let container = CloudContainer(fileAt: url)
        switch kind {
        case .video:
            return container == .mp4 || container == .m4a || VideoPoster.isVideo(url)
        case .photo:
            if container == .jpeg || container == .png || container == .gif || container == .webp || container == .heic || container == .jxl {
                return true
            }
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 {
                return true
            }
            return false
        case .videoThumb:
            if VideoPoster.isVideo(url) { return true }
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 {
                return true
            }
            return false
        }
    }

    internal nonisolated static func findCachedMediaFile(hashPrefix: String, in directory: URL, kind: MediaKind) -> URL? {
        let fm = FileManager.default
        let exts = kind == .video ? ["mp4", "mov", "m4v"] : ["jpg", "jpeg", "jxl", "png", "webp", "gif", "heic", "mp4", "bin"]
        for ext in exts {
            let candidate = directory.appendingPathComponent("\(hashPrefix).\(ext)")
            guard fm.fileExists(atPath: candidate.path) else { continue }
            if isValidMediaFile(candidate, kind: kind) {
                return candidate
            } else {
                // Self-heal corrupted raw-ciphertext files cached before e2esession decryption was enabled.
                try? fm.removeItem(at: candidate)
            }
        }
        return nil
    }

    /// Downloads and caches media from CDN URLs into Olaz's local `MediaCache/` directory,
    /// orchestrated by `olaz-core` (single-flight 3-slot LIFO + 30 s `Unavailable` TTL, ADR-031).
    func resolveMedia(conversationId: String, messageId: String, kind: MediaKind = .photo, force: Bool = false) async -> MediaResolution {
        if let resolveMediaHostHandler {
            let args: [String: Any] = [
                "conv_id": conversationId,
                "msg_id": messageId,
                "kind": kind.rawValue,
            ]
            _ = traceHost("resolve_media", args: args)
            return await resolveMediaHostHandler(args)
        }
        guard let core = await ensureCoreEngine() else { return .unavailable }
        let res = await core.resolveMediaCore(
            convId: conversationId,
            msgId: messageId,
            kind: kind.rawValue,
            force: force,
            nowMs: nowMs()
        )
        return MediaResolution(coreRecord: res)
    }

    /// Downloads, decrypts (`?e2esession=...`), and stages a file attachment with its sanitized real filename + extension,
    /// orchestrated by `olaz-core` (ADR-031).
    func resolveFile(
        conversationId: String = "",
        messageId: String = "",
        name: String,
        url: URL?,
        force: Bool = false,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> FileResolution {
        if let resolveFileHostHandler {
            let args: [String: Any] = [
                "conv_id": conversationId,
                "msg_id": messageId,
                "name": name,
                "url": url?.absoluteString ?? NSNull(),
            ]
            _ = traceHost("resolve_file", args: args)
            return await resolveFileHostHandler(args)
        }
        guard let core = await ensureCoreEngine() else {
            return .failed("Không tải được tệp. Kiểm tra kết nối mạng và thử lại.")
        }
        let token = mediaHostIO.registerProgress(progress)
        defer { mediaHostIO.unregisterProgress(token: token) }
        let res = await core.resolveFileCore(
            convId: conversationId,
            msgId: messageId,
            name: name,
            url: url?.absoluteString,
            force: force,
            requestToken: token
        )
        return FileResolution(coreRecord: res)
    }

    func fileDownloadKey(conversationId: String, messageId: String, url: URL?, name: String) -> String {
        mediaFileDownloadKey(
            convId: conversationId,
            msgId: messageId,
            url: url?.absoluteString,
            name: name
        )
    }

    func rememberedDownloadedFile(for key: String) -> URL? {
        guard let url = downloadedFilePaths[key] else { return nil }
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        downloadedFilePaths.removeValue(forKey: key)
        return nil
    }

    func resetMedia() {
        mediaHostIO.releaseAll()
        downloadedFilePaths = [:]
        if !isApplyingCoreMirror {
            coreLifecycle.core?.resetMedia()
        }
    }
}

extension MediaResolution {
    var logName: String {
        switch self {
        case .file: "file"
        case .expired: "expired"
        case .unavailable: "unavailable"
        case .unsupported: "unsupported"
        }
    }
}

/// First-frame poster for a video file sitting where a thumbnail image was expected.
enum VideoPoster {
    /// ISO-BMFF (`ftyp` box at offset 4: mp4/mov/3gp) — never a decodable image.
    nonisolated static func isVideo(_ file: URL) -> Bool { mimeType(of: file) != nil }

    /// Container MIME type from the `ftyp` major brand; AVFoundation goes by the (here: `.jpg`) extension otherwise.
    nonisolated static func mimeType(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 12), head.count == 12,
              head[4..<8].elementsEqual("ftyp".utf8) else { return nil }
        let brand = String(decoding: head[8..<12], as: UTF8.self)
        if brand == "qt  " { return "video/quicktime" }
        if brand.hasPrefix("3g") { return "video/3gpp" }
        return "video/mp4"
    }

    /// `<file>.poster.jpg` next to the video, generated once.
    nonisolated static func poster(for video: URL) async -> URL? {
        let poster = video.appendingPathExtension("poster.jpg")
        let fm = FileManager.default
        func modified(_ url: URL) -> Date? { (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date }
        if let made = modified(poster), let source = modified(video), made >= source { return poster }

        guard let mime = mimeType(of: video) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video, options: [AVURLAssetOverrideMIMETypeKey: mime]))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1040, height: 1040)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        guard let (image, _) = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)) else { return nil }

        let temp = poster.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).poster.part")
        guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { try? fm.removeItem(at: temp); return nil }
        try? fm.removeItem(at: poster)
        do { try fm.moveItem(at: temp, to: poster) } catch { try? fm.removeItem(at: temp); return nil }
        return poster
    }
}
