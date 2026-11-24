import Foundation
import CommonCrypto
import CryptoKit

/// Swift stand-in for the download manager of Zalo PC's Electron main process
/// (`main-dist`: `new-download-channel`, class `GYN9`/`DownloadService`).
///
/// The official renderer's `CloudService.downloadWithMultiSrc(...)` (photo loader `loadPC`, video, voice,
/// file downloads, the Zalo Cloud fallback) all end in `$zdownload.sendDownloadRequest({channel, data})`
/// and wait for `{channel: "new-download-file-resp", data}` pushed back on the same channel. Without a
/// main-side answer every official download hangs, so media for messages that have no live CDN link
/// (and the cloud fallback behind it) can never be resolved.
///
/// Wire contract, taken from `main-dist` (`onDone`, `DownloadErrors`):
///   request  new-download-file        data = objDownload {key, downloadFrom, type, data{url, fileName, …},
///                                            options{saveDir, srcAction, maxTTFB, …}}
///            new-download-file-abort  data = {key, downloadFrom}
///            config / quota / ping / scan / priority channels are acknowledged.
///   response new-download-file-resp   data = {downloadError|null, savePath, downloadFrom, key, type, isCached}
///   errors   {name, code, normalize: true}; HTTP status s → `DOWNLOAD_SERVICE_NET_s` / 75000 + s,
///            Chromium net errors → `ERR_*` / 30000 + n (prefix 2 × 15000).
///
/// The bytes come from `MediaLoader` (URLCache, DNS-over-HTTPS fallback, dead-host cache), so the official
/// path and the native image views share one HTTP cache.
@MainActor
final class DownloadManager {
    static let channel = "new-download-channel"
    enum Request {
        static let download = "new-download-file"
        static let abort = "new-download-file-abort"
    }
    static let responseChannel = "new-download-file-resp"

    struct Failure: Equatable, Sendable {
        var name: String
        var code: Int
        var message: String = ""

        var json: [String: Any] {
            var out: [String: Any] = ["name": name, "code": code, "normalize": true]
            if !message.isEmpty { out["message"] = message }
            return out
        }

        static let aborted = Failure(name: "GENERAL_MAIN_CONTROLLER_OBJ_DOWNLOAD_ABORT", code: 1009)
        static let invalidURL = Failure(name: "GENERAL_UI_OBJ_DOWNLOAD_INVALID_URL", code: 9)
        static let saveDirInvalid = Failure(name: "GENERAL_MAIN_CONTROLLER_OBJ_DOWNLOAD_SAVE_DIR_INVALID", code: 1012)
        static let emptyBody = Failure(name: "DOWNLOAD_SERVICE_SINGLE_INVALID_CONTENT_LENGTH", code: 75000 + 5002)
        static let ttfbTimeout = Failure(name: "DOWNLOAD_SERVICE_SINGLE_MAX_TTFB_TIMEOUT", code: 75000 + 5027)
        /// Main aborts with `new Error("File secure decrypt failed")` / forwards the cipher error; both are plain
        /// `Error`s, which `normalizeError` reports as `INS_OF_ERROR_ERR` (14998) with the message.
        static let decryptFailed = Failure(name: "INS_OF_ERROR_ERR", code: 14998, message: "File secure decrypt failed")
        static let tooLarge = Failure(name: "DOWNLOAD_SERVICE_SINGLE_FILE_SIZE_LIMIT_EXCEED", code: 75000 + 5026)
        /// Fallback for anything unrecognised: `DOWNLOAD_SERVICE_SINGLE_DOWNLOAD_ON_EMPTY_ERR`.
        static let unknown = Failure(name: "DOWNLOAD_SERVICE_SINGLE_DOWNLOAD_ON_EMPTY_ERR", code: 75000 + 5025)

        static func http(_ status: Int) -> Failure { Failure(name: "DOWNLOAD_SERVICE_NET_\(status)", code: 75000 + status) }
        static func net(_ name: String, _ number: Int) -> Failure { Failure(name: name, code: 30000 + number) }

        /// Maps a `MediaLoader` / URLSession error to the error the official main process would report.
        static func from(_ error: Error) -> Failure {
            if error is CancellationError { return .aborted }
            if let load = error as? MediaLoader.LoadError {
                switch load {
                case .http(let status): return .http(status)
                case .hostNotFound: return .net("ERR_NAME_NOT_RESOLVED", 34)
                case .timedOut: return .ttfbTimeout
                case .badURL: return .invalidURL
                case .tooLarge: return .tooLarge
                case .undecodable: return .unknown
                }
            }
            if let resolve = error as? DoHResolver.ResolveError {
                if case .notFound = resolve { return .net("ERR_NAME_NOT_RESOLVED", 34) }
                return .net("ERR_NAME_RESOLUTION_FAILED", 63)
            }
            if let urlError = error as? URLError {
                switch urlError.code {
                case .cancelled: return .aborted
                case .cannotFindHost, .dnsLookupFailed: return .net("ERR_NAME_NOT_RESOLVED", 34)
                case .timedOut: return .net("ERR_CONNECTION_TIMED_OUT", 47)
                case .notConnectedToInternet, .networkConnectionLost: return .net("ERR_INTERNET_DISCONNECTED", 35)
                case .cannotConnectToHost: return .net("ERR_CONNECTION_REFUSED", 31)
                case .secureConnectionFailed: return .net("ERR_SSL_PROTOCOL_ERROR", 36)
                default: return .net("ERR_CONNECTION_FAILED", 33)
                }
            }
            return .unknown
        }
    }


    struct Outcome: Sendable {
        var savePath: String?
        var failure: Failure?
        var cached = false
    }

    /// Everything a transfer needs, resolved on the main actor; the transfer itself runs off it.
    struct Job: Sendable {
        var url: URL
        var destination: URL
        var type: String
        var headers: [String: String]
        var secure: SecureStream.Parsed
        /// Time to first byte, seconds (0 = none).
        var ttfb: TimeInterval
        var tempDirectory: URL
        var isPhoto: Bool { type.hasPrefix("Photo") }
    }

    /// In-memory bodies (photos) are capped; anything larger streams through files.
    nonisolated static let photoByteCap = 64 << 20
    /// GCM with a non-12-byte IV cannot stream with our GHASH; such bodies are limited to this size.
    nonisolated static let gcmOneShotCap = 256 << 20
    static let notFoundCapacity = 500

    private let platform: ZaloPlatform
    private let loader: MediaLoader
    let tempDirectory: URL
    private var tasks: [String: [UUID: Task<Void, Never>]] = [:]
    /// URL → until: official "resp cache" for 404s (main: `S.add(404, url, …)`), skipped for Manual downloads.
    private var notFound: [String: Date] = [:]
    static let notFoundTTL: TimeInterval = 600

    init(platform: ZaloPlatform, loader: MediaLoader = .shared, tempDirectory: URL? = nil) {
        self.platform = platform
        self.loader = loader
        self.tempDirectory = tempDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Olaz/download-tmp", isDirectory: true)
        let directory = self.tempDirectory
        Task.detached(priority: .utility) { Self.removeStaleTemps(in: directory) }
    }

    /// Leftovers of a crash / force-quit (`*.part` older than ten minutes).
    nonisolated static func removeStaleTemps(in directory: URL, now: Date = Date()) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for url in urls {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > 600 { try? fm.removeItem(at: url) }
        }
    }

    /// Logout / account switch: nothing may keep writing, and a new account must not inherit verdicts.
    func reset() {
        for entries in tasks.values { for task in entries.values { task.cancel() } }
        tasks.removeAll()
        notFound.removeAll()
    }

    // MARK: Download

    func perform(_ request: [String: Any]) async -> Outcome {
        let data = request["data"] as? [String: Any] ?? [:]
        let options = request["options"] as? [String: Any] ?? [:]
        let type = request["type"] as? String ?? ""
        guard let urlString = data["url"] as? String, let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else {
            return Outcome(failure: .invalidURL)
        }
        guard let destination = Self.destination(saveDir: options["saveDir"] as? String, fileName: data["fileName"] as? String),
              platform.isWritable(destination.deletingLastPathComponent().path) else { return Outcome(failure: .saveDirInvalid) }
        let manual = (options["srcAction"] as? String) == "Manual"
        let headers = Self.requestHeaders(request)
        let secure = SecureStream.parse(request["secure"])
        let secureLabel: String
        switch secure { case .none: secureLabel = "no"; case .stream: secureLabel = "yes"; case .invalid: secureLabel = "invalid" }
        EngineLog.shared.write("download type=\(type) host=\(url.host ?? "-") src=\(options["srcAction"] as? String ?? "-") headers=\(headers.keys.sorted().joined(separator: ",")) secure=\(secureLabel)")

        if Self.isUsableFile(destination) { return Outcome(savePath: destination.path, cached: true) }
        if case .invalid = secure { return Outcome(failure: .decryptFailed) }     // ciphertext must never be saved as the media
        if !manual, let until = notFound[urlString] {
            if until > Date() { return Outcome(failure: .http(404)) }
            notFound[urlString] = nil
        }
        let ttfb = (options["maxTTFB"] as? NSNumber)?.doubleValue ?? 0
        let job = Job(url: url, destination: destination, type: type, headers: headers, secure: secure,
                      ttfb: ttfb > 0 ? ttfb / 1000 : 0, tempDirectory: tempDirectory)
        let outcome = await Self.execute(job, loader: loader)
        if outcome.failure?.code == 75404 { rememberNotFound(urlString) }
        return outcome
    }

    var notFoundCount: Int { notFound.count }

    func rememberNotFound(_ url: String) {
        let now = Date()
        if notFound.count >= Self.notFoundCapacity {
            notFound = notFound.filter { $0.value > now }
            if notFound.count >= Self.notFoundCapacity {
                for (key, _) in notFound.sorted(by: { $0.value < $1.value }).prefix(Self.notFoundCapacity / 4) { notFound[key] = nil }
            }
        }
        notFound[url] = now.addingTimeInterval(Self.notFoundTTL)
    }

    /// A previously completed download: a regular, non-empty file (writes are atomic, so never a partial).
    nonisolated static func isUsableFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }

    /// The transfer: fetch → decrypt → quarantine → atomic move. Runs off the main actor; all file I/O and
    /// crypto happen here. Temporary files live in `job.tempDirectory`, never in the user's save folder.
    nonisolated static func execute(_ job: Job, loader: MediaLoader) async -> Outcome {
        await rustExecute(job, core: loader.rustMedia, allowPlainHTTP: loader.allowPlainHTTP)
    }

    /// Moves `staged` over `destination` (replacing an existing file atomically when there is one).
    nonisolated static func commit(_ staged: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: destination)
        }
    }

    /// Headers the renderer asks main to send: `options.headers` [{name, value}] (e.g. Zalo Cloud's
    /// `cloud-viewer-key`) and the `extraHeader` object. Names only are ever logged.
    nonisolated static func requestHeaders(_ request: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        let options = request["options"] as? [String: Any] ?? [:]
        for entry in options["headers"] as? [[String: Any]] ?? [] {
            if let name = entry["name"] as? String, let value = entry["value"] as? String, !name.isEmpty { out[name] = value }
        }
        for (name, value) in request["extraHeader"] as? [String: Any] ?? [:] {
            if let value = value as? String, !name.isEmpty { out[name] = value }
        }
        return out
    }

    /// `saveDir/fileName`, with the name reduced to a single path component.
    nonisolated static func destination(saveDir: String?, fileName: String?) -> URL? {
        guard let saveDir, saveDir.hasPrefix("/") else { return nil }
        var name = ((fileName ?? "") as NSString).lastPathComponent
        name = name.replacingOccurrences(of: "\0", with: "")
        if name.isEmpty || name == "." || name == ".." { name = "no_name" }
        return URL(fileURLWithPath: saveDir, isDirectory: true).appendingPathComponent(name)
    }
}

/// Stream decryption main applies to e2ee / Zalo Cloud ("pcloud") downloads (`main-dist` `getTransformer`):
/// `secure = {type: "e2ee" | "pcloud", cryptography: {alg, key, iv, tag?, type: "block" | "linear", blockSize}}`.
/// * `aes-256-ctr` + block: every `blockSize` bytes are decrypted with a fresh cipher (same key / iv); a
///   trailing partial block is passed through unchanged (`skipOverflow`).
/// * `aes-256-ctr` + linear: one cipher over the whole stream.
/// * `aes-256-gcm` + linear: whole stream, authenticated with `tag` (16 bytes); the output is only
///   released after the tag verifies.
/// Any other algorithm name (including the WebCrypto spellings `AES-GCM` / `AES-CTR`, which Node's
/// `createDecipheriv` rejects) or malformed key / iv makes the official transformer throw — `.invalid`.
struct SecureStream: Sendable {
    enum Algorithm: String, Sendable { case ctr = "aes-256-ctr", gcm = "aes-256-gcm" }
    enum Parsed: Sendable {
        /// No transformer requested (absent, or a `type` main does not decrypt): bytes are saved as received.
        case none
        case stream(SecureStream)
        /// A decryptable `type` with unusable cryptography: the download must fail, not save ciphertext.
        case invalid
    }

    let algorithm: Algorithm
    let key: Data
    let iv: Data
    let tag: Data?
    let block: Bool
    let blockSize: Int

    struct DecryptError: Error {}

    static func parse(_ json: Any?) -> Parsed {
        guard let dict = json as? [String: Any], let type = dict["type"] as? String, type == "e2ee" || type == "pcloud" else { return .none }
        guard let crypto = dict["cryptography"] as? [String: Any],
              let alg = (crypto["alg"] as? String).flatMap(Algorithm.init(rawValue:)),
              let key = bytes(crypto["key"]), key.count == 32, let iv = bytes(crypto["iv"]), !iv.isEmpty else { return .invalid }
        let tag = bytes(crypto["tag"])
        if alg == .gcm, tag?.count != 16 { return .invalid }
        if alg == .ctr, iv.count != 16 { return .invalid }
        let block = (crypto["type"] as? String) == "block"
        if alg == .gcm, block { return .invalid }
        return .stream(SecureStream(algorithm: alg, key: key, iv: iv, tag: tag, block: block,
                                    blockSize: max(16, (crypto["blockSize"] as? NSNumber)?.intValue ?? 4096)))
    }

    init(algorithm: Algorithm, key: Data, iv: Data, tag: Data? = nil, block: Bool, blockSize: Int) {
        self.algorithm = algorithm; self.key = key; self.iv = iv; self.tag = tag; self.block = block; self.blockSize = blockSize
    }

    private static func bytes(_ value: Any?) -> Data? {
        if let data = value as? Data { return data }
        if let text = value as? String { return decodeBase64Flexible(text) }
        if let array = value as? [NSNumber] { return Data(array.map { UInt8(truncatingIfNeeded: $0.intValue) }) }
        return nil
    }

    static func decodeBase64Flexible(_ raw: String) -> Data? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains("%"), let decoded = s.removingPercentEncoding {
            s = decoded
        }
        s = s.replacingOccurrences(of: "-", with: "+")
             .replacingOccurrences(of: "_", with: "/")
        let rem = s.count % 4
        if rem > 0 { s += String(repeating: "=", count: 4 - rem) }
        return Data(base64Encoded: s, options: .ignoreUnknownCharacters)
    }

    /// Parses Zalo's client-side `e2esession` base64 key (`_getAesKeyFromBase64` in `pc-dist`):
    /// - 60 bytes (`version != "2"`): AES-256-GCM linear (`key = [0..<32]`, `iv = [32..<44]`, `tag = [44..<60]`)
    /// - 48 bytes (`version == "2"` or video 48-byte session): AES-256-CTR 4096-byte block (`key = [0..<32]`, `iv = [32..<48]`)
    static func parseE2EESession(_ base64: String, version: String? = nil) -> Parsed {
        guard !base64.isEmpty else { return .none }
        guard let raw = decodeBase64Flexible(base64) else { return .invalid }
        if version == "2" || raw.count == 48 {
            guard raw.count == 48 else { return .invalid }
            return .stream(SecureStream(
                algorithm: .ctr,
                key: Data(raw[0..<32]),
                iv: Data(raw[32..<48]),
                tag: nil,
                block: true,
                blockSize: 4096
            ))
        }
        guard version == nil || version == "" || version == "1", raw.count == 60 else {
            return .invalid
        }
        return .stream(SecureStream(
            algorithm: .gcm,
            key: Data(raw[0..<32]),
            iv: Data(raw[32..<44]),
            tag: Data(raw[44..<60]),
            block: false,
            blockSize: 4096
        ))
    }

    /// Whole-buffer decryption (photos; bounded by `DownloadManager.photoByteCap`).
    func decrypt(_ data: Data) throws -> Data {
        switch algorithm {
        case .ctr:
            guard iv.count == 16 else { throw DecryptError() }
            if !block { return try Self.ctr(data, key: key, iv: iv) }
            var out = Data(capacity: data.count)
            var offset = 0
            while data.count - offset >= blockSize {
                out.append(try Self.ctr(data.subdata(in: offset..<(offset + blockSize)), key: key, iv: iv))
                offset += blockSize
            }
            if offset < data.count { out.append(data.subdata(in: offset..<data.count)) }   // overflow passes through
            return out
        case .gcm:
            guard !block, let tag, tag.count == 16, iv.count >= 12 else { throw DecryptError() }
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: data, tag: tag)
            return try AES.GCM.open(box, using: SymmetricKey(data: key))
        }
    }

    /// Encrypts plaintext using linear AES-256-GCM and encodes the 60-byte `key(32) + iv(12) + tag(16)` session token as Base64.
    static func encryptE2EEFile(_ plaintext: Data) throws -> (ciphertext: Data, base64Session: String) {
        let key = SymmetricKey(size: .bits256)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        var token = Data(capacity: 60)
        key.withUnsafeBytes { token.append(contentsOf: $0) }
        token.append(contentsOf: nonce)
        token.append(sealed.tag)
        return (Data(sealed.ciphertext), token.base64EncodedString())
    }

    /// Streams `source` → `destination` (created here, removed on any failure) in constant memory.
    /// For GCM the tag is verified before returning, so a caller that only moves `destination` into place
    /// on success never publishes unauthenticated plaintext.
    func decryptFile(at source: URL, to destination: URL) throws {
        let fm = FileManager.default
        var finished = false
        defer { if !finished { try? fm.removeItem(at: destination) } }
        try? fm.removeItem(at: destination)
        guard fm.createFile(atPath: destination.path, contents: nil) else { throw DecryptError() }
        let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }
        let chunkSize = 1 << 20
        switch algorithm {
        case .ctr:
            guard iv.count == 16 else { throw DecryptError() }
            // Block mode: chunk = whole multiple of the block size so every block restarts the cipher.
            let chunk = block ? blockSize * max(1, chunkSize / blockSize) : chunkSize
            let linear = block ? nil : try Cryptor(key: key, iv: iv)
            while let part = try input.read(upToCount: chunk), !part.isEmpty {
                if let linear { try output.write(contentsOf: try linear.update(part)) } else { try output.write(contentsOf: try decrypt(part)) }
            }
        case .gcm:
            guard !block, let tag, tag.count == 16 else { throw DecryptError() }
            if iv.count == 12 {
                var gcm = try GCMStream(key: key, iv: iv)
                while let part = try input.read(upToCount: chunkSize), !part.isEmpty {
                    try output.write(contentsOf: try gcm.update(part))
                }
                guard gcm.verify(tag: tag) else { throw DecryptError() }
            } else {
                // Rare IV length: GHASH-derived counter, not streamed here — bounded one-shot.
                let size = (try? fm.attributesOfItem(atPath: source.path)[.size] as? Int) ?? Int.max
                guard size <= DownloadManager.gcmOneShotCap else { throw DecryptError() }
                try output.write(contentsOf: try decrypt(try Data(contentsOf: source, options: .mappedIfSafe)))
            }
        }
        try output.synchronize()
        finished = true
    }

    private static func ctr(_ data: Data, key: Data, iv: Data) throws -> Data {
        try Cryptor(key: key, iv: iv).update(data)
    }

    /// AES-CTR (big-endian counter, as OpenSSL's `aes-256-ctr`).
    fileprivate final class Cryptor {
        private var ref: CCCryptorRef?
        init(key: Data, iv: Data) throws {
            let status = key.withUnsafeBytes { k in
                iv.withUnsafeBytes { i in
                    CCCryptorCreateWithMode(CCOperation(kCCDecrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                            CCPadding(ccNoPadding), i.baseAddress, k.baseAddress, key.count,
                                            nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &ref)
                }
            }
            guard status == kCCSuccess else { throw DecryptError() }
        }
        deinit { if let ref { CCCryptorRelease(ref) } }
        func update(_ data: Data) throws -> Data {
            var out = Data(count: data.count)
            var moved = 0
            let status = out.withUnsafeMutableBytes { o in
                data.withUnsafeBytes { i in
                    CCCryptorUpdate(ref, i.baseAddress, data.count, o.baseAddress, data.count, &moved)
                }
            }
            guard status == kCCSuccess else { throw DecryptError() }
            return out.prefix(moved)
        }
    }
}

/// Streaming AES-256-GCM decryption for 96-bit IVs: CTR from `IV || 2` plus GHASH over the ciphertext
/// (NIST SP 800-38D, empty AAD). `verify` compares the tag in constant time.
struct GCMStream {
    private let cipher: SecureStream.Cryptor
    private var ghash: GHASH
    private let tagMask: [UInt8]
    private var length: UInt64 = 0
    private var pending = [UInt8]()           // ciphertext bytes not yet a whole 16-byte GHASH block

    init(key: Data, iv: Data) throws {
        var hashKey = [UInt8](repeating: 0, count: 16)
        try Self.aesECB(key: key, input: [UInt8](repeating: 0, count: 16), output: &hashKey)
        var j0 = [UInt8](iv) + [0, 0, 0, 1]
        var mask = [UInt8](repeating: 0, count: 16)
        try Self.aesECB(key: key, input: j0, output: &mask)
        j0[15] = 2
        cipher = try SecureStream.Cryptor(key: key, iv: Data(j0))
        ghash = GHASH(h: hashKey)
        tagMask = mask
    }

    private static func aesECB(key: Data, input: [UInt8], output: inout [UInt8]) throws {
        var moved = 0
        let status = key.withUnsafeBytes { k in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                    k.baseAddress, key.count, nil, input, 16, &output, 16, &moved)
        }
        guard status == kCCSuccess, moved == 16 else { throw SecureStream.DecryptError() }
    }

    mutating func update(_ ciphertext: Data) throws -> Data {
        length += UInt64(ciphertext.count)
        pending.append(contentsOf: ciphertext)
        let whole = pending.count - pending.count % 16
        if whole > 0 {
            pending.withUnsafeBufferPointer { ghash.absorb($0.baseAddress!, count: whole) }
            pending.removeFirst(whole)
        }
        return try cipher.update(ciphertext)
    }

    mutating func verify(tag: Data) -> Bool {
        if !pending.isEmpty {
            var block = pending + [UInt8](repeating: 0, count: 16 - pending.count)
            block.withUnsafeMutableBufferPointer { ghash.absorb($0.baseAddress!, count: 16) }
            pending.removeAll()
        }
        var lengths = [UInt8](repeating: 0, count: 16)          // AAD bits (0) || ciphertext bits, big endian
        let bits = length &* 8
        for i in 0..<8 { lengths[8 + i] = UInt8(truncatingIfNeeded: bits >> UInt64(56 - 8 * i)) }
        lengths.withUnsafeBufferPointer { ghash.absorb($0.baseAddress!, count: 16) }
        let digest = ghash.digest()
        var difference: UInt8 = 0
        for i in 0..<16 { difference |= (digest[i] ^ tagMask[i]) ^ tag[tag.startIndex + i] }
        return difference == 0
    }
}

/// GHASH with Shoup's 4-bit tables (the layout used by mbed TLS).
struct GHASH {
    private var hl = [UInt64](repeating: 0, count: 16)
    private var hh = [UInt64](repeating: 0, count: 16)
    private var yh: UInt64 = 0, yl: UInt64 = 0
    private static let last4: [UInt64] = [0x0000, 0x1c20, 0x3840, 0x2460, 0x7080, 0x6ca0, 0x48c0, 0x54e0,
                                          0xe100, 0xfd20, 0xd940, 0xc560, 0x9180, 0x8da0, 0xa9c0, 0xb5e0]

    private static func load(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        (0..<8).reduce(0) { ($0 << 8) | UInt64(bytes[offset + $1]) }
    }

    init(h: [UInt8]) {
        var vh = Self.load(h, 0), vl = Self.load(h, 8)
        hl[8] = vl; hh[8] = vh
        var i = 4
        while i > 0 {
            let t: UInt64 = (vl & 1) &* 0xe1000000
            vl = (vh << 63) | (vl >> 1)
            vh = (vh >> 1) ^ (t << 32)
            hl[i] = vl; hh[i] = vh
            i >>= 1
        }
        i = 2
        while i <= 8 {
            let ih = hh[i], il = hl[i]
            for j in 1..<i { hh[i + j] = ih ^ hh[j]; hl[i + j] = il ^ hl[j] }
            i *= 2
        }
    }

    /// `count` must be a multiple of 16.
    mutating func absorb(_ bytes: UnsafePointer<UInt8>, count: Int) {
        var offset = 0
        while offset < count {
            var x = [UInt8](repeating: 0, count: 16)
            var xh = yh, xl = yl
            for k in 0..<8 { x[k] = UInt8(truncatingIfNeeded: xh >> UInt64(56 - 8 * k)) ^ bytes[offset + k] }
            for k in 0..<8 { x[8 + k] = UInt8(truncatingIfNeeded: xl >> UInt64(56 - 8 * k)) ^ bytes[offset + 8 + k] }
            multiply(x, &xh, &xl)
            yh = xh; yl = xl
            offset += 16
        }
    }

    private func multiply(_ x: [UInt8], _ zhOut: inout UInt64, _ zlOut: inout UInt64) {
        var lo = Int(x[15] & 0xf)
        var zh = hh[lo], zl = hl[lo]
        for i in stride(from: 15, through: 0, by: -1) {
            lo = Int(x[i] & 0xf)
            let hi = Int((x[i] >> 4) & 0xf)
            if i != 15 {
                let rem = Int(zl & 0xf)
                zl = (zh << 60) | (zl >> 4)
                zh >>= 4
                zh ^= Self.last4[rem] << 48
                zh ^= hh[lo]; zl ^= hl[lo]
            }
            let rem = Int(zl & 0xf)
            zl = (zh << 60) | (zl >> 4)
            zh >>= 4
            zh ^= Self.last4[rem] << 48
            zh ^= hh[hi]; zl ^= hl[hi]
        }
        zhOut = zh; zlOut = zl
    }

    func digest() -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: yh >> UInt64(56 - 8 * $0)) } + (0..<8).map { UInt8(truncatingIfNeeded: yl >> UInt64(56 - 8 * $0)) }
    }
}

/// Parses Zalo CDN URLs carrying client-side `?e2esession=...` / `&version=...` / `?jxlstatus=1` metadata
/// (`parseE2eeProtocol`, `removeJxlSignature`, and `transcode` in `pc-dist`).
struct ZaloMediaURL: Sendable {
    let originalURL: URL
    /// Clean HTTPS URL sent over the wire (`jxlstatus` and `e2esession`/`version`/`cloudkeyversion` stripped).
    let networkURL: URL
    /// Stream cipher parsed from `e2esession` (`.none` when unencrypted, `.invalid` when malformed).
    let encryption: SecureStream.Parsed
    /// When `originalURL` is a non-encrypted `/jxl/.../*.jxl` URL, the `/jpg/.../*.jpg` fallback URL.
    let jxlTranscodedURL: URL?

    /// `allowPlainHTTP` keeps `http` (local test servers only); production always upgrades to https.
    static func parse(_ url: URL, allowPlainHTTP: Bool = false) -> ZaloMediaURL? {
        let rawString = url.absoluteString
        guard !rawString.isEmpty else { return nil }

        // Extract query parameters across both `&` and accidental secondary `?` separators (`...jxl?jxlstatus=1?e2esession=...`).
        var params: [String: String] = [:]
        if let firstQ = rawString.firstIndex(of: "?") {
            let afterQ = rawString[rawString.index(after: firstQ)...]
            let tail = afterQ.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? afterQ
            for token in tail.split(whereSeparator: { $0 == "&" || $0 == "?" }) {
                let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let name = parts.first, !name.isEmpty else { continue }
                let value = parts.count > 1 ? String(parts[1]) : ""
                params[String(name)] = value
            }
        }

        let encryption: SecureStream.Parsed
        if let sessionVal = params["e2esession"] {
            if sessionVal.isEmpty {
                encryption = .invalid
            } else {
                encryption = SecureStream.parseE2EESession(sessionVal, version: params["version"])
            }
        } else {
            encryption = .none
        }

        // Strip `?e2esession...` tail if appended directly, and filter client-only query params.
        var baseString = rawString
        if let e2eRange = baseString.range(of: "?e2esession") {
            baseString = String(baseString[..<e2eRange.lowerBound])
        }
        guard var components = URLComponents(string: baseString),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false else {
            return nil
        }
        if scheme == "http", !allowPlainHTTP { components.scheme = "https" }

        let strippedKeys: Set<String> = ["jxlstatus", "e2esession", "version", "cloudkeyversion"]
        if let existingItems = components.percentEncodedQueryItems {
            let kept = existingItems.filter { !strippedKeys.contains($0.name.lowercased()) }
            components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        }
        guard let networkURL = components.url else { return nil }

        let jxlTranscodedURL: URL?
        if case .none = encryption,
           networkURL.path.lowercased().hasSuffix(".jxl") || params["jxlstatus"] == "1" {
            var jpgComp = components
            var p = jpgComp.path
            if p.contains("/jxl/") {
                p = p.replacingOccurrences(of: "/jxl/", with: "/jpg/")
            }
            if p.lowercased().hasSuffix(".jxl") {
                p = String(p.dropLast(4)) + ".jpg"
            }
            jpgComp.path = p
            let candidate = jpgComp.url
            jxlTranscodedURL = (candidate != networkURL) ? candidate : nil
        } else {
            jxlTranscodedURL = nil
        }

        return ZaloMediaURL(
            originalURL: url,
            networkURL: networkURL,
            encryption: encryption,
            jxlTranscodedURL: jxlTranscodedURL
        )
    }
}
