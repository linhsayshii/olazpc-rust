import Foundation
import Network
import OlazCore
import Testing

@testable import Olaz

/// Minimal local HTTP/1.1 server (NWListener). `hang` never answers and counts connections the client closed.
private final class LocalServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "olaz.test.server")
    private let lock = NSLock()
    private var _hits = 0, _closed = 0
    let hang: Bool
    let body: Data
    var hits: Int { lock.lock(); defer { lock.unlock() }; return _hits }
    var closed: Int { lock.lock(); defer { lock.unlock() }; return _closed }
    private(set) var port: UInt16 = 0

    init(body: Data = Data("hello".utf8), hang: Bool = false) throws {
        listener = try NWListener(using: .tcp)
        self.body = body
        self.hang = hang
    }

    func start() async throws {
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            serve(connection)
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { state in
                if case .ready = state, once.first() { c.resume() }
                if case .failed(let e) = state, once.first() { c.resume(throwing: e) }
            }
            listener.start(queue: queue)
        }
        port = listener.port?.rawValue ?? 0
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] data, _, _, error in
            guard data != nil, error == nil else { return }
            lock.lock(); _hits += 1; lock.unlock()
            if hang {
                watchForClose(connection)
                return
            }
            let head = "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func watchForClose(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [self] data, _, isComplete, error in
            if error != nil || isComplete { lock.lock(); _closed += 1; lock.unlock(); return }
            watchForClose(connection)
        }
    }
}

@Suite(.serialized) struct RustMediaTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("olaz-rmedia-\(UUID().uuidString)")
    }

    // MARK: Swift-golden differential tests (pure helpers)

    @Test func stableHashAndFileNamesMatchSwift() {
        for text in ["a", "", "https://res-zalo.zadn.vn/upload/x.json", "dec1:https://a.zdn.vn/é?x=1"] {
            #expect(mediaStableHash(text: text) == MediaLoader.stableHash(text))
        }
        let urls = ["https://res-zalo.zadn.vn/upload/x.json", "https://a.zdn.vn/p/pic.jpeg?x=1", "https://a.zdn.vn/noext",
                    "https://a.zdn.vn/a.verylongextension99", "https://a.zdn.vn/x.jxl?jxlstatus=1"]
        for text in urls {
            let media = try? #require(ZaloMediaURL.parse(URL(string: text)!))
            let swiftName = MediaLoader.cachedFileName(for: media!)
            let ext = media!.networkURL.pathExtension.filter { $0.isLetter || $0.isNumber }.prefix(8)
            #expect(mediaCachedFileName(seed: media!.networkURL.absoluteString, ext: String(ext)) == swiftName, "\(text)")
        }
        for host in ["res-zalo.zadn.vn", "ZADN.VN", "zadn.vn.evil.com", "notzadn.vn", "chat.zalo.me", "localhost"] {
            #expect(mediaIsZaloCdn(host: host) == MediaLoader.isZaloCDN(host), "\(host)")
        }
    }

    @Test func secureStreamDecryptMatchesSwift() async throws {
        let plain = Data((0..<20_000).map { UInt8($0 % 251) })
        let (cipher, token) = try SecureStream.encryptE2EEFile(plain)
        guard case .stream(let gcm) = SecureStream.parseE2EESession(token) else { Issue.record("parse"); return }
        let rust = try await mediaSecureDecrypt(spec: MediaLoader.secureRecord(gcm), data: cipher)
        #expect(rust == plain)
        #expect(try gcm.decrypt(cipher) == plain)
        // Block CTR (48-byte session): Rust and Swift agree byte for byte, including the pass-through tail.
        let raw = Data((0..<48).map { UInt8($0 &* 5 &+ 1) })
        guard case .stream(let ctr) = SecureStream.parseE2EESession(raw.base64EncodedString(), version: "2") else {
            Issue.record("parse ctr"); return
        }
        let blob = Data((0..<(4096 * 3 + 77)).map { UInt8($0 % 233) })
        #expect(try await mediaSecureDecrypt(spec: MediaLoader.secureRecord(ctr), data: blob) == (try ctr.decrypt(blob)))
        // A bad tag is rejected, not returned as garbage.
        var bad = MediaLoader.secureRecord(gcm)
        bad.tag = Data(repeating: 0, count: 16)
        #expect(try await mediaSecureDecrypt(spec: bad, data: cipher) == nil)
        // Rust encryption decrypts with Swift.
        let enc = try mediaEncryptE2eeFile(plaintext: plain, key: Data(repeating: 7, count: 32), iv: Data(repeating: 9, count: 12))
        guard case .stream(let back) = SecureStream.parseE2EESession(enc.token.base64EncodedString()) else { Issue.record("parse"); return }
        #expect(try back.decrypt(enc.ciphertext) == plain)
    }

    // MARK: Network through MediaLoader on the Rust path (local server)

    @Test func loaderFetchesCachesAndReportsHttpErrors() async throws {
        guard RustCore.isEnabled else { return }
        let server = try LocalServer(body: Data("payload".utf8))
        try await server.start()
        defer { server.stop() }
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let loader = MediaLoader(cacheDirectory: dir, allowPlainHTTP: true)
        let url = URL(string: "http://127.0.0.1:\(server.port)/a.bin")!
        #expect(try await loader.data(for: url) == Data("payload".utf8))
        #expect(try await loader.data(for: url) == Data("payload".utf8))     // second call: URLCache
        #expect(server.hits == 1)
        let seen = Box()
        let file = try await loader.localFile(for: URL(string: "http://127.0.0.1:\(server.port)/b.txt")!, progress: { seen.add($0) })
        #expect(try Data(contentsOf: file) == Data("payload".utf8))
        #expect(file.pathExtension == "txt")
        #expect(seen.last == 1)
        let quarantine = try file.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(quarantine?["LSQuarantineAgentName"] as? String == "Olaz")
        // Same cache layout as the Swift path: <stableHash(networkURL)>.<ext>.
        #expect(file.lastPathComponent == MediaLoader.stableHash("http://127.0.0.1:\(server.port)/b.txt") + ".txt")
        #expect(try await loader.localFile(for: URL(string: "http://127.0.0.1:\(server.port)/b.txt")!) == file)
        #expect(server.hits == 2)
    }

    /// UniFFI does not cancel a Rust future when the Swift task is cancelled; the `MediaCancel` bridge must.
    @Test func cancellingTheSwiftTaskAbortsTheTransfer() async throws {
        guard RustCore.isEnabled else { return }
        let server = try LocalServer(hang: true)
        try await server.start()
        defer { server.stop() }
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let loader = MediaLoader(cacheDirectory: dir, allowPlainHTTP: true)
        let url = URL(string: "http://127.0.0.1:\(server.port)/hang.bin")!
        let task = Task { try await loader.data(for: url, deadline: 60) }
        await pollUntil { server.hits > 0 }
        #expect(server.hits == 1)
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(20))   // well under the 60 s deadline: cancel, not timeout
        await pollUntil { server.closed > 0 }
        #expect(server.closed == 1, "the client connection must be closed after cancel")
    }

    @Test func downloadManagerStagesThroughRust() async throws {
        guard RustCore.isEnabled else { return }
        let server = try LocalServer(body: Data("file-bytes".utf8))
        try await server.start()
        defer { server.stop() }
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let loader = MediaLoader(cacheDirectory: dir, allowPlainHTTP: true)
        let destination = dir.appendingPathComponent("saved/out.bin")
        let job = DownloadManager.Job(url: URL(string: "http://127.0.0.1:\(server.port)/f.bin")!, destination: destination,
                                      type: "File", headers: [:], secure: .none, ttfb: 0,
                                      tempDirectory: dir.appendingPathComponent("tmp"))
        let outcome = await DownloadManager.execute(job, loader: loader)
        #expect(outcome.failure == nil)
        #expect(try Data(contentsOf: destination) == Data("file-bytes".utf8))
        let quarantine = try destination.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(quarantine?["LSQuarantineAgentName"] as? String == "Olaz")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("tmp").path)) ?? []
        #expect(leftovers.isEmpty)
        // Secure "invalid" never saves ciphertext and reports the official code.
        var bad = job
        bad.secure = .invalid
        bad.destination = dir.appendingPathComponent("saved/bad.bin")
        let failed = await DownloadManager.execute(bad, loader: loader)
        #expect(failed.failure?.code == 14998)
        #expect(!FileManager.default.fileExists(atPath: bad.destination.path))
    }

    /// Informational: 200 distinct fetches through `MediaLoader.data` against a local server.
    @Test func parallelFetchBurst() async throws {
        let server = try LocalServer(body: Data(repeating: 1, count: 4096))
        try await server.start()
        defer { server.stop() }
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let loader = MediaLoader(cacheDirectory: dir, allowPlainHTTP: true)
        let port = server.port
        let started = ContinuousClock.now
        let total = await withTaskGroup(of: Int.self) { group in
            for i in 0..<200 {
                group.addTask { (try? await loader.data(for: URL(string: "http://127.0.0.1:\(port)/img/\(i).jpg")!).count) ?? 0 }
            }
            return await group.reduce(0, +)
        }
        let elapsed = ContinuousClock.now - started
        print("PERF media burst 200 fetches rust=\(RustCore.isEnabled) \(elapsed)")
        // The Swift path upgrades http to https (ATS), so only the Rust path can reach the plain local server.
        if RustCore.isEnabled { #expect(total == 200 * 4096) }
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    func add(_ f: Double) { lock.lock(); value = max(value, f); lock.unlock() }
    var last: Double { lock.lock(); defer { lock.unlock() }; return value }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}
