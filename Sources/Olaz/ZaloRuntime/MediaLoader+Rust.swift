import Foundation
import OlazCore

/// Rust-core (`CoreMedia`) bridge of `MediaLoader` / `DownloadManager`: network, disk cache, DoH + pinned TLS,
/// stream decryption and staging run in `olaz-media`. Swift keeps decode, the memory/URL caches and quarantine.
/// UniFFI does not cancel a Rust future when the Swift task is cancelled, so every call passes a `MediaCancel`.

/// Applies `com.apple.quarantine` to a finished temp file before Rust gives it its final name.
final class QuarantineHook: MediaPublishHook {
    func beforePublish(path: String, originUrl: String) {
        MediaLoader.applyQuarantine(to: URL(fileURLWithPath: path), origin: URL(string: originUrl) ?? URL(fileURLWithPath: path))
    }
}

private final class ProgressAdapter: MediaProgress, @unchecked Sendable {
    private let lock = NSLock()
    private var best = 0.0
    private let handler: @Sendable (Double) -> Void
    init(_ handler: @escaping @Sendable (Double) -> Void) { self.handler = handler }
    func onProgress(fraction: Double) {
        lock.lock()
        if fraction == 0 { best = 0 } else if fraction < best { lock.unlock(); return } else { best = fraction }
        lock.unlock()
        handler(fraction)
    }
}

extension MediaLoader {
    /// Runs `body` with a cancel token that fires when the surrounding Swift task is cancelled.
    static func rustCancellable<T: Sendable>(_ body: @Sendable (MediaCancel) async throws -> T) async throws -> T {
        let token = MediaCancel()
        return try await withTaskCancellationHandler {
            try await body(token)
        } onCancel: {
            token.cancel()
        }
    }

    /// The Swift error the existing callers already handle for a Rust media failure.
    static func map(_ failure: MediaCoreError) -> Error {
        switch failure {
        case .BadUrl: return LoadError.badURL
        case .Http(let status): return LoadError.http(Int(status))
        case .Undecodable: return LoadError.undecodable
        case .TimedOut: return LoadError.timedOut
        case .TooLarge: return LoadError.tooLarge
        case .HostNotFound: return LoadError.hostNotFound
        case .Cancelled: return CancellationError()
        case .DohNotFound: return DoHResolver.ResolveError.notFound("")
        case .DohAllFailed: return DoHResolver.ResolveError.allEndpointsFailed("")
        case .Net(let kind):
            switch kind {
            case .cannotFindHost: return URLError(.cannotFindHost)
            case .timedOut: return URLError(.timedOut)
            case .notConnected: return URLError(.notConnectedToInternet)
            case .connectionLost: return URLError(.networkConnectionLost)
            case .cannotConnect: return URLError(.cannotConnectToHost)
            case .secureFailed: return URLError(.secureConnectionFailed)
            case .other: return URLError(.unknown)
            }
        case .Io: return URLError(.cannotWriteToFile)
        }
    }

    private static func call<T: Sendable>(_ body: @Sendable (MediaCancel) async throws -> T) async throws -> T {
        do { return try await rustCancellable(body) } catch let failure as MediaCoreError { throw map(failure) }
    }

    static func secureRecord(_ stream: SecureStream) -> MediaSecureRecord {
        MediaSecureRecord(cipher: stream.algorithm == .ctr ? .aes256Ctr : .aes256Gcm, key: stream.key, iv: stream.iv,
                          tag: stream.tag, block: stream.block, blockSize: UInt64(stream.blockSize))
    }

    static func secureChoice(_ parsed: SecureStream.Parsed) -> MediaSecureChoice {
        switch parsed {
        case .none: return .none
        case .stream(let s): return .stream(spec: secureRecord(s))
        case .invalid: return .invalid
        }
    }

    static func dataRequest(_ media: ZaloMediaURL, deadline: TimeInterval) -> MediaDataRequest {
        var secure: MediaSecureRecord?
        if case .stream(let s) = media.encryption { secure = secureRecord(s) }
        return MediaDataRequest(url: media.networkURL.absoluteString,
                                fallbackUrl: secure == nil ? media.jxlTranscodedURL?.absoluteString : nil,
                                secure: secure, keySeed: media.originalURL.absoluteString, deadlineSecs: deadline)
    }

    static func fileRequest(_ media: ZaloMediaURL, fileName: String) -> MediaFileRequest {
        var secure: MediaSecureRecord?
        if case .stream(let s) = media.encryption { secure = secureRecord(s) }
        return MediaFileRequest(url: media.networkURL.absoluteString, fallbackUrl: media.jxlTranscodedURL?.absoluteString,
                                fileName: fileName, secure: secure, originUrl: media.networkURL.absoluteString)
    }

    static func rustData(_ core: CoreMedia, media: ZaloMediaURL, deadline: TimeInterval) async throws -> Data {
        let request = dataRequest(media, deadline: deadline)
        return try await call { try await core.data(request: request, cancel: $0) }
    }

    static func rustLocalFile(_ core: CoreMedia, media: ZaloMediaURL, fileName: String,
                              progress: (@Sendable (Double) -> Void)?) async throws -> String {
        let request = fileRequest(media, fileName: fileName)
        let adapter = progress.map { ProgressAdapter($0) }
        return try await call { try await core.localFile(request: request, progress: adapter, cancel: $0) }
    }

    static func rustHeaders(_ core: CoreMedia, url: URL, headers: [String: String], maxBytes: Int, ttfb: TimeInterval?,
                            progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        let request = MediaHeadersRequest(url: url.absoluteString, headers: headers, maxBytes: UInt64(max(0, maxBytes)),
                                          ttfbSecs: ttfb, tempDir: FileManager.default.temporaryDirectory.path)
        let adapter = progress.map { ProgressAdapter($0) }
        let path = try await call { try await core.downloadWithHeaders(request: request, progress: adapter, cancel: $0) }
        return URL(fileURLWithPath: path)
    }
}

extension DownloadManager {
    nonisolated static func failure(_ record: MediaFailureRecord) -> Failure {
        Failure(name: record.name, code: Int(record.code), message: record.message)
    }

    /// Rust transfer (fetch, decrypt, stage), then quarantine and atomic commit here.
    nonisolated static func rustExecute(_ job: Job, core: CoreMedia, allowPlainHTTP: Bool) async -> Outcome {
        let source: MediaDownloadSource
        if job.headers.isEmpty {
            guard let media = ZaloMediaURL.parse(job.url, allowPlainHTTP: allowPlainHTTP) else { return Outcome(failure: .invalidURL) }
            if job.isPhoto {
                source = .photo(request: MediaLoader.dataRequest(media, deadline: max(MediaLoader.imageDeadline, job.ttfb)))
            } else {
                source = .cached(request: MediaLoader.fileRequest(media, fileName: MediaLoader.cachedFileName(for: media)))
            }
        } else {
            source = .headers(request: MediaHeadersRequest(
                url: job.url.absoluteString, headers: job.headers,
                maxBytes: UInt64(job.isPhoto ? photoByteCap : MediaLoader.maxFileBytes),
                ttfbSecs: job.ttfb > 0 ? job.ttfb : nil, tempDir: job.tempDirectory.path))
        }
        let request = MediaDownloadRequest(source: source, secure: MediaLoader.secureChoice(job.secure),
                                           tempDir: job.tempDirectory.path)
        let outcome: MediaDownloadOutcome
        do {
            outcome = try await MediaLoader.rustCancellable { try await core.downloadTo(request: request, progress: nil, cancel: $0) }
        } catch { return Outcome(failure: .aborted) }
        if let record = outcome.failure { return Outcome(failure: failure(record)) }
        guard let stagedPath = outcome.stagedPath else { return Outcome(failure: .unknown) }
        let staged = URL(fileURLWithPath: stagedPath)
        if Task.isCancelled { try? FileManager.default.removeItem(at: staged); return Outcome(failure: .aborted) }
        do {
            try FileManager.default.createDirectory(at: job.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            MediaLoader.applyQuarantine(to: staged, origin: job.url)       // before the final name appears
            try commit(staged, to: job.destination)
            return Outcome(savePath: job.destination.path)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            return Outcome(failure: Failure.from(error))
        }
    }
}
