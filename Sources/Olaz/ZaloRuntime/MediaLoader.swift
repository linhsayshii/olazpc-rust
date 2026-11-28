import Foundation
import AppKit
import ImageIO
import os
import CoreServices
import OlazCore

/// `NSImage` is not `Sendable`; images handed out by the loader are immutable after creation.
struct SendableImage: @unchecked Sendable {
    let image: NSImage
}

/// Loads Zalo CDN media (avatars, photos, stickers, voice, files).
///
/// 1. Disk+memory `URLCache` lookup.
/// 2. Network fetch, DNS policy (system resolver probe + DoH fallback with pinned TLS), concurrency cap,
///    deadlines, and cached file downloads via Rust `CoreMedia` (`olaz-media`).
/// Decoded (downsampled) images are kept in an `NSCache`; concurrent requests for the same URL share
/// one download, which is cancelled when every waiter cancels. Downloads are capped at 6 concurrent.
actor MediaLoader {
    /// Cache root for `shared` (nil: ~/Library/Caches/Olaz). Set only by the offline scroll benchmark, before first use, so a
    /// benchmark run never touches the real caches.
    nonisolated(unsafe) static var sharedCacheDirectory: URL?
    static let shared = MediaLoader(cacheDirectory: sharedCacheDirectory)

    enum LoadError: Error, LocalizedError {
        case badURL
        case http(Int)
        case undecodable
        case timedOut
        case tooLarge
        /// The CDN host does not exist (authoritative NXDOMAIN): nothing to retry.
        case hostNotFound
        var errorDescription: String? {
            switch self {
            case .badURL: "Unsupported media URL"
            case .http(let code): "Media request failed with HTTP \(code)"
            case .undecodable: "Media data is not a decodable image"
            case .timedOut: "Media download timed out"
            case .tooLarge: "Media file is too large"
            case .hostNotFound: "Media host no longer exists"
            }
        }
    }

    /// Hosts for which the DoH fallback is allowed (so arbitrary hosts embedded in message content
    /// cannot bypass the user's own DNS / hosts-file blocking).
    static let dohHostSuffixes = ["zadn.vn", "zdn.vn", "dlfl.vn", "zalo.me", "zaloapp.com", "zingcdn.me", "zalo.vn", "zing.vn"]

    nonisolated static func isZaloCDN(_ host: String) -> Bool {
        let host = host.lowercased()
        return dohHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Where `localFile` stores completed downloads (and `.part` temp files). Derived from the injected
    /// cache directory so tests never touch the user's real cache.
    nonisolated let filesDirectory: URL
    /// Rust media engine (network + files cache).
    nonisolated let rustMedia: CoreMedia
    /// Tests only: local servers speak plain http (production always upgrades to https).
    nonisolated let allowPlainHTTP: Bool
    private let urlCache: URLCache
    private var flights: [String: FlightBase] = [:]
    private var failures: [String: Date] = [:]

    private static let failureBackoff: TimeInterval = 20
    static let imageDeadline: TimeInterval = 25
    /// Files have no total deadline: a transfer fails only after this long without receiving any bytes.
    static let fileIdleTimeout: TimeInterval = 30
    /// Largest file `localFile` will download (Zalo allows up to 1 GB).
    static let maxFileBytes = 2 * 1024 * 1024 * 1024
    /// Size cap for Caches/Olaz/files; least recently used files are evicted beyond it.
    static let defaultFilesCacheLimit = 2 * 1024 * 1024 * 1024

    init(cacheDirectory: URL? = nil, maxConcurrentDownloads: Int = 6,
         filesCacheLimit: Int = MediaLoader.defaultFilesCacheLimit, allowPlainHTTP: Bool = false) {
        self.allowPlainHTTP = allowPlainHTTP
        if let cacheDirectory {
            filesDirectory = cacheDirectory.appendingPathComponent("files", isDirectory: true)
        } else {
            filesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Olaz/files", isDirectory: true)
        }
        let directory = cacheDirectory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Olaz/media", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 400 << 20, directory: directory)
        rustMedia = CoreMedia(options: MediaCoreOptions(
            preferredLanguages: Locale.preferredLanguages,
            filesDir: filesDirectory.path, filesCacheLimit: UInt64(filesCacheLimit),
            maxConcurrent: UInt32(maxConcurrentDownloads), allowPlainHttp: allowPlainHTTP,
            dohEndpoints: nil, fileIdleSecs: Self.fileIdleTimeout, imageIdleSecs: 10),
            hook: QuarantineHook())
    }


    // MARK: Decoded-image memory cache (synchronous access for views)

    private final class CachedImage: @unchecked Sendable {
        let image: NSImage
        init(_ image: NSImage) { self.image = image }
    }

    /// NSCache is thread-safe but not annotated `Sendable`.
    private final class MemoryCache: @unchecked Sendable {
        private let cache: NSCache<NSString, CachedImage> = {
            let cache = NSCache<NSString, CachedImage>()
            cache.countLimit = 600
            cache.totalCostLimit = 160 << 20
            return cache
        }()
        private let lock = NSLock()
        private var stills: Set<URL> = []       // URLs known to be single-frame (skip animation checks)
        func object(forKey key: NSString) -> CachedImage? { cache.object(forKey: key) }
        func setObject(_ object: CachedImage, forKey key: NSString, cost: Int) {
            cache.setObject(object, forKey: key, cost: cost)
        }
        func markStill(_ url: URL) { lock.lock(); if stills.count > 5000 { stills.removeAll() }; stills.insert(url); lock.unlock() }
        func isStill(_ url: URL) -> Bool { lock.lock(); defer { lock.unlock() }; return stills.contains(url) }
    }

    private static let memory = MemoryCache()

    static func pixelBucket(_ maxPixelSize: CGFloat) -> Int {
        max(64, Int((maxPixelSize / 32).rounded(.up)) * 32)
    }

    private static func imageKey(_ url: URL, _ pixels: Int) -> String { "\(url.absoluteString)#\(pixels)" }

    /// Already-decoded image, if any; lets views render without a placeholder flash.
    nonisolated static func cachedImage(for url: URL, maxPixelSize: CGFloat) -> NSImage? {
        memory.object(forKey: imageKey(url, pixelBucket(maxPixelSize)) as NSString)?.image
    }

    nonisolated static func cachedAnimatedImage(for url: URL) -> NSImage? {
        memory.object(forKey: imageKey(url, 0) as NSString)?.image
    }

    /// True when a previous check found `url` to be a single-frame image.
    nonisolated static func isKnownStill(_ url: URL) -> Bool { memory.isStill(url) }

    // MARK: Shared in-flight work (cancelled when every waiter cancels)

    private class FlightBase: @unchecked Sendable {
        var waiters = 0
        func cancel() {}
    }
    private final class Flight<T: Sendable>: FlightBase, @unchecked Sendable {
        let task: Task<T, Error>
        init(_ task: Task<T, Error>) {
            self.task = task
        }
        override func cancel() { task.cancel() }
    }
    private final class Waiter: @unchecked Sendable { var released = false }

    private func join<T: Sendable>(key: String, start: @escaping @Sendable () async throws -> T) async throws -> T {
        let flight: Flight<T>
        if let existing = flights[key] as? Flight<T> {
            flight = existing
        } else {
            flight = Flight(Task { try await start() })
            flights[key] = flight
        }
        flight.waiters += 1
        let waiter = Waiter()
        defer {
            release(waiter, flight, key)
        }
        return try await withTaskCancellationHandler {
            try await flight.task.value
        } onCancel: {
            Task { await self.release(waiter, flight, key) }
        }
    }

    private func release(_ waiter: Waiter, _ flight: FlightBase, _ key: String) {
        guard !waiter.released else { return }
        waiter.released = true
        flight.waiters -= 1
        if flight.waiters <= 0 {
            if flights[key] === flight { flights[key] = nil }
            flight.cancel()
        }
    }

    // MARK: Images

    /// Decoded image whose longest side is at most `maxPixelSize` pixels. Nil on failure.
    ///
    /// `cache: false` keeps the result out of the shared memory cache (the viewer's full-size photos: one 48 MP decode is
    /// ~113 MB and would evict most thumbnails and avatars). Concurrent callers still share one download and decode;
    /// uncached ones are told apart in the flight table so a cached caller never joins a flight that skips the store.
    func image(for url: URL, maxPixelSize: CGFloat, cache: Bool = true) async -> SendableImage? {
        let pixels = Self.pixelBucket(maxPixelSize)
        let key = Self.imageKey(url, pixels)
        if let hit = Self.memory.object(forKey: key as NSString) { return SendableImage(image: hit.image) }
        if let until = failures[key], until > Date() { return nil }
        do {
            return try await join(key: (cache ? "i:" : "i!:") + key) { [self] in
                do {
                    let data = try await self.data(for: url)
                    var decoded = await Task.detached(priority: .userInitiated, operation: {
                        Self.decode(data, maxPixelSize: pixels)
                    }).value
                    if decoded == nil, let jpgURL = ZaloMediaURL.parse(url)?.jxlTranscodedURL,
                       let fallbackData = try? await self.data(for: jpgURL) {
                        decoded = await Task.detached(priority: .userInitiated, operation: {
                            Self.decode(fallbackData, maxPixelSize: pixels)
                        }).value
                    }
                    guard let decoded else { throw LoadError.undecodable }
                    if cache {
                        let cost = Int(decoded.size.width * decoded.size.height) * 4
                        Self.memory.setObject(CachedImage(decoded), forKey: key as NSString, cost: cost)
                    }
                    return SendableImage(image: decoded)
                } catch {
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    MediaDiagnostics.report(url: url, error: error, kind: "image")
                    await self.noteFailure(key)
                    throw error
                }
            }
        } catch {
            return nil
        }
    }

    /// Multi-frame (GIF/APNG/WebP) image with all frames, or nil if the data is a still image / failed.
    func animatedImage(for url: URL) async -> SendableImage? {
        let key = Self.imageKey(url, 0)
        if let hit = Self.memory.object(forKey: key as NSString) { return SendableImage(image: hit.image) }
        if Self.memory.isStill(url) { return nil }
        if let until = failures[key], until > Date() { return nil }
        do {
            return try await join(key: "a:" + key) { [self] () -> SendableImage? in
                do {
                    let data = try await self.data(for: url)
                    guard let image = await Task.detached(priority: .userInitiated, operation: {
                        Self.decodeAnimated(data)
                    }).value else {
                        Self.memory.markStill(url)
                        return nil
                    }
                    Self.memory.setObject(CachedImage(image), forKey: key as NSString, cost: data.count * 4)
                    return SendableImage(image: image)
                } catch {
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    await self.noteFailure(key)
                    throw error
                }
            }
        } catch {
            return nil
        }
    }

    private func noteFailure(_ key: String) {
        failures[key] = Date().addingTimeInterval(Self.failureBackoff)
    }

    /// Drops the short failure backoff for `url` (an explicit retry must really try again).
    func forgetFailures(for url: URL) {
        let prefix = url.absoluteString + "#"
        for key in failures.keys where key.hasPrefix(prefix) { failures[key] = nil }
    }

    nonisolated static func decodeAnimated(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 1 else { return nil }
        return NSImage(data: data)
    }

    /// Decodes `data`, downsampling so the longest side is at most `maxPixelSize`. A photo stored rotated (EXIF orientation)
    /// is turned upright either way: the full-size path would leave it sideways.
    nonisolated static func decode(_ data: Data, maxPixelSize: Int) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0 else { return nil }
        var longest = 0
        var rotated = false
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            if let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
                longest = max(w, h)
            }
            rotated = (props[kCGImagePropertyOrientation] as? Int).map { $0 != 1 } ?? false
        }
        let cgImage: CGImage?
        if longest > maxPixelSize || rotated {
            cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                // Unknown source size (no pixel properties): the cap itself, never a 1 px thumbnail.
                kCGImageSourceThumbnailMaxPixelSize: longest > 0 ? min(maxPixelSize, longest) : maxPixelSize,
            ] as CFDictionary)
        } else {
            cgImage = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        guard let decoded = cgImage else { return nil }
        let image = displayReady(decoded)
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    // MARK: Display-ready pixels

    /// The color space of the screen the app is on. Core Animation shows an image in any other space through a converted
    /// copy it keeps as long as the image lives, so every cached thumbnail cost twice its pixels (measured: ~165 MB of
    /// `CoreAnimation` copies next to ~160 MB of decoded thumbnails after scrolling a chat with many photos).
    private static let displaySpace = OSAllocatedUnfairLock<CGColorSpace?>(initialState: nil)
    @MainActor private static var displaySpaceObservers: [NSObjectProtocol] = []

    /// Keeps `displaySpace` on the screen of the key window (launch, display changes, a window moving to another screen).
    @MainActor static func trackDisplayColorSpace() {
        func update() {
            let screen = NSApp.keyWindow?.screen ?? NSScreen.main
            let space = screen?.colorSpace?.cgColorSpace
            displaySpace.withLock { current in
                if current != space { current = space }
            }
        }
        update()
        guard displaySpaceObservers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSApplication.didChangeScreenParametersNotification, NSWindow.didChangeScreenNotification,
                     NSWindow.didBecomeKeyNotification] {
            displaySpaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { update() }
            })
        }
    }

    /// For tests and the scroll bench.
    nonisolated static func setDisplayColorSpace(_ space: CGColorSpace?) { displaySpace.withLock { $0 = space } }

    /// `image` drawn once, off the main thread, in the screen's color space and the little-endian BGRA layout Core Animation
    /// uses as is. Images it cannot improve on (no known screen, more than 8 bits per component, non-RGB screens) stay as
    /// they are.
    nonisolated static func displayReady(_ image: CGImage) -> CGImage {
        guard let space = displaySpace.withLock({ $0 }), space.model == .rgb, image.bitsPerComponent <= 8 else { return image }
        let alpha = image.alphaInfo
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        if image.colorSpace == space, image.bitsPerPixel == 32, order == .byteOrder32Little,
           alpha == .premultipliedFirst || alpha == .noneSkipFirst { return image }
        let opaque = alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast
        let info = CGBitmapInfo.byteOrder32Little.rawValue
            | (opaque ? CGImageAlphaInfo.noneSkipFirst : CGImageAlphaInfo.premultipliedFirst).rawValue
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else { return image }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    // MARK: Raw data

    /// Bytes for `url` (cached, de-duplicated, concurrency-capped, with an overall deadline).
    func data(for url: URL, deadline: TimeInterval = MediaLoader.imageDeadline) async throws -> Data {
        if url.isFileURL {
            // Files the official download path wrote under ZaloDownloads (`resolveMedia`), or our own caches.
            guard Self.isAllowedLocalFile(url) else { throw LoadError.badURL }
            return try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url, options: .mappedIfSafe)
            }.value
        }
        guard let media = ZaloMediaURL.parse(url, allowPlainHTTP: allowPlainHTTP) else { throw LoadError.badURL }
        switch media.encryption {
        case .invalid:
            throw LoadError.undecodable
        case .stream:
            let sep = media.networkURL.query == nil ? "?" : "&"
            let cacheURL = URL(string: media.networkURL.absoluteString + sep + "_olaz_dec=" + Self.stableHash(media.originalURL.absoluteString)) ?? media.networkURL
            if let cached = urlCache.cachedResponse(for: URLRequest(url: cacheURL)) { return cached.data }
            return try await join(key: "d:dec:" + media.originalURL.absoluteString) { [self] in
                let plain = try await Self.rustData(self.rustMedia, media: media, deadline: deadline)
                await self.store(plain, for: cacheURL, contentType: nil)
                return plain
            }
        case .none:
            let cleanURL = media.networkURL
            if let cached = urlCache.cachedResponse(for: URLRequest(url: cleanURL)) { return cached.data }
            return try await join(key: "d:" + cleanURL.absoluteString) { [self] in
                let data = try await Self.rustData(self.rustMedia, media: media, deadline: deadline)
                await self.store(data, for: cleanURL, contentType: nil)
                return data
            }
        }
    }

    // MARK: Requests with custom headers

    /// GET with caller-supplied headers (Zalo Cloud downloads carry `cloud-viewer-key`), streamed to a
    /// temporary file that the caller moves into place (and must delete on failure paths it handles).
    func downloadWithHeaders(_ url: URL, headers: [String: String], maxBytes: Int = MediaLoader.maxFileBytes,
                             ttfb: TimeInterval? = nil, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        try await Self.rustHeaders(rustMedia, url: url, headers: headers, maxBytes: maxBytes, ttfb: ttfb, progress: progress)
    }

    // MARK: Local files

    /// Roots `file://` media may be read from: Olaz's data directory (the official client's
    /// `ZaloDownloads`) and its caches.
    nonisolated(unsafe) static var allowedLocalRoots: [String] = [
        ZaloPlatform.defaultUserData.resolvingSymlinksInPath().path,
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Olaz", isDirectory: true).resolvingSymlinksInPath().path,
    ]

    /// SwiftZalo's data directory (before the move to Olaz). The migrated message database still points at files the
    /// official client downloaded there (the migration clones, it does not move), so they stay readable, but never deletable.
    nonisolated static let legacyLocalRoots: [String] = [
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftZalo/ZaloData", isDirectory: true).resolvingSymlinksInPath().path,
    ]

    /// A `file://` URL media may be read from: Olaz's own roots and the legacy one.
    nonisolated static func isAllowedLocalFile(_ url: URL) -> Bool {
        isLocalFile(url, under: allowedLocalRoots + legacyLocalRoots)
    }

    /// A file Olaz may also delete (a corrupt download to fetch again): its own roots only.
    nonisolated static func isOwnLocalFile(_ url: URL) -> Bool {
        isLocalFile(url, under: allowedLocalRoots)
    }

    private nonisolated static func isLocalFile(_ url: URL, under roots: [String]) -> Bool {
        guard url.isFileURL else { return false }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return roots.contains { path.hasPrefix($0 + "/") }
    }

    /// Only ever called with complete (framed) bodies.
    private func store(_ data: Data, for url: URL, contentType: String?) {
        guard let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": contentType ?? "application/octet-stream",
            "Content-Length": String(data.count),
        ]) else { return }
        urlCache.storeCachedResponse(CachedURLResponse(response: http, data: data, userInfo: nil, storagePolicy: .allowed),
                                     for: URLRequest(url: url))
    }

    // MARK: Files (voice, documents, video)

    private nonisolated static func cachedFileLocation(for media: ZaloMediaURL, in directory: URL) -> URL {
        let ext = media.networkURL.pathExtension.filter { $0.isLetter || $0.isNumber }.prefix(8)
        let seed: String
        if case .stream = media.encryption {
            seed = "dec1:" + media.originalURL.absoluteString
        } else {
            seed = media.networkURL.absoluteString
        }
        let name = Self.stableHash(seed) + (ext.isEmpty ? "" : "." + ext)
        return directory.appendingPathComponent(name)
    }

    nonisolated static func cachedFileName(for media: ZaloMediaURL) -> String {
        cachedFileLocation(for: media, in: URL(fileURLWithPath: "/")).lastPathComponent
    }

    func evictCachedFile(for url: URL) {
        guard !url.isFileURL, let media = ZaloMediaURL.parse(url) else { return }
        let file = Self.cachedFileLocation(for: media, in: filesDirectory)
        try? FileManager.default.removeItem(at: file)
        forgetFailures(for: url)
    }

    /// Downloads `url` through the same DoH-capable path and stores it under
    /// Caches/Olaz/files/<hash>.<ext> (reused when present). Returns the file URL.
    ///
    /// The body is streamed to a temporary file (no in-memory buffering, no 50 MB cap; the limit is
    /// `maxFileBytes`), decrypted on disk when `url` carries `?e2esession=...`, and only renamed to its
    /// final name once complete, so a truncated or cancelled download never leaves a partial file behind.
    /// There is no total deadline, only a 30 s stall timeout. `progress` (called on arbitrary threads, 0...1) is optional.
    func localFile(for url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        if url.isFileURL {
            guard Self.isAllowedLocalFile(url), FileManager.default.fileExists(atPath: url.path) else {
                throw LoadError.badURL
            }
            progress?(1)
            return url
        }
        guard let media = ZaloMediaURL.parse(url, allowPlainHTTP: allowPlainHTTP) else { throw LoadError.badURL }
        if case .invalid = media.encryption { throw LoadError.undecodable }
        let file = Self.cachedFileLocation(for: media, in: filesDirectory)
        let path = try await Self.rustLocalFile(rustMedia, media: media, fileName: file.lastPathComponent, progress: progress)
        progress?(1)
        return URL(fileURLWithPath: path)
    }

    /// Marks a downloaded file with `com.apple.quarantine` so Gatekeeper vets it when opened.
    nonisolated static func applyQuarantine(to file: URL, origin: URL) {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "Olaz",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
            kLSQuarantineOriginURLKey as String: origin,
        ]
        var target = file
        try? target.setResourceValues(values)
    }

    /// FNV-1a 64-bit, hex (stable across launches, unlike `hashValue`).
    nonisolated static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }

    /// Test hook: has this host been switched to the DoH path?
    func usesDoH(host: String) -> Bool {
        rustMedia.usesDoh(host: host)
    }
}
