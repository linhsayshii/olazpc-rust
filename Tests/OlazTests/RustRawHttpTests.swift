import Foundation
import Network
import OlazCore
import Testing
@testable import Olaz

/// Local HTTP/1.1 server: `reply` maps the raw request text to the full raw response. The Swift URLSession path cannot
/// reach a plain-http host (ATS), so a request that lands here proves it went through the Rust transport.
private final class RawServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "olaz.test.raw-server")
    private let lock = NSLock()
    private var _requests: [String] = []
    private let reply: @Sendable (String) -> String
    private(set) var port: UInt16 = 0
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return _requests }

    init(reply: @escaping @Sendable (String) -> String) throws {
        listener = try NWListener(using: .tcp)
        self.reply = reply
    }

    func start() async throws {
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [self] data, _, _, _ in
                guard let data else { return }
                let text = String(decoding: data, as: UTF8.self)
                lock.lock(); _requests.append(text); lock.unlock()
                connection.send(content: Data(reply(text).utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                if case .ready = state, once.first() { c.resume() }
                if case .failed(let e) = state, once.first() { c.resume(throwing: e) }
            }
            listener.start(queue: queue)
        }
        port = listener.port?.rawValue ?? 0
    }

    func stop() { listener.cancel() }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

private func response(_ status: String, headers: [String] = [], body: String = "") -> String {
    let extra = headers.map { "\($0)\r\n" }.joined()
    return "HTTP/1.1 \(status)\r\n\(extra)Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
}

@Suite(.serialized) struct RustRawHttpTests {
    private static func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-raw-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func loggedIn(_ dir: URL) async -> ZaloSessionClient {
        let client = ZaloSessionClient(dataDirectory: dir, useKeychain: false)
        await client.updateCredentials(
            account: ZaloLoginAccount(userId: "100", displayName: "An", send2MeId: "999", zpwEnk: "0123456789abcdef", zpwSek: "sek.1.2"),
            secretKey: Data("0123456789abcdef".utf8), zpwSek: "sek.1.2")
        return client
    }

    @Test func rawRequestGoesThroughRustAndKeepsStatusBodyHeadersAndCookie() async throws {
        let server = try RawServer { _ in
            response("202 Accepted", headers: ["Set-Cookie: zpw_sek=fresh.7.8; Path=/; HttpOnly", "Set-Cookie: other=1"], body: "{\"ok\":1}")
        }
        try await server.start()
        defer { server.stop() }
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = await Self.loggedIn(dir)
        let (status, data, cookie) = try await client.rawRequest(
            method: "POST", url: server.url("/api/x?a=1"), body: Data("k=v".utf8),
            contentType: "application/x-www-form-urlencoded", timeout: 5, extraHeaders: ["cloud-viewer-key": "vk"])
        #expect(status == 202)
        #expect(String(decoding: data, as: UTF8.self) == "{\"ok\":1}")
        #expect(cookie == "fresh.7.8")
        let sent = try #require(server.requests.first).lowercased()
        #expect(sent.hasPrefix("post /api/x?a=1 "))
        #expect(sent.contains("cloud-viewer-key: vk"))
        #expect(sent.contains("content-type: application/x-www-form-urlencoded"))
        #expect(sent.contains("user-agent: zalopc"))
        #expect(sent.hasSuffix("k=v"))
        // 127.0.0.1 is not a Zalo host: the session cookie must not leak to it.
        #expect(!sent.contains("zpw_sek"))
    }

    @Test func rawRequestDoesNotMapStatusToAnError() async throws {
        let server = try RawServer { _ in response("500 Internal Server Error", body: "boom") }
        try await server.start()
        defer { server.stop() }
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = ZaloSessionClient(dataDirectory: dir, useKeychain: false)   // no account: login-time use
        let (status, data, cookie) = try await client.rawRequest(method: "GET", url: server.url("/p"))
        #expect(status == 500)
        #expect(String(decoding: data, as: UTF8.self) == "boom")
        #expect(cookie == nil)
    }

    @Test func rawRequestMapsTransportFailuresLikeURLSession() async throws {
        let server = try RawServer { _ in response("200 OK") }
        try await server.start()
        let url = server.url("/p")
        server.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = ZaloSessionClient(dataDirectory: dir, useKeychain: false)
        do {
            _ = try await client.rawRequest(method: "GET", url: url, timeout: 2)
            Issue.record("expected a connection error")
        } catch {
            #expect(error is URLError)
        }
    }

    @Test func rawDownloadDataReturnsBytesAndMapsHttpErrors() async throws {
        let server = try RawServer { req in
            req.contains("/missing") ? response("404 Not Found") : response("200 OK", body: "payload")
        }
        try await server.start()
        defer { server.stop() }
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = await Self.loggedIn(dir)
        let data = try await client.rawDownloadData(url: server.url("/f"), timeout: 5)
        #expect(String(decoding: data, as: UTF8.self) == "payload")
        let sent = try #require(server.requests.first).lowercased()
        #expect(sent.contains("user-agent: zalopc"))
        #expect(!sent.contains("cookie"))
        do {
            _ = try await client.rawDownloadData(url: server.url("/missing"), timeout: 5)
            Issue.record("expected an http error")
        } catch ZaloTransportError.httpError(let status, _) {
            #expect(status == 404)
        }
    }

    @Test func downloadSyncBatchRetriesWithTheSessionCookieOn401() async throws {
        let server = try RawServer { req in
            req.lowercased().contains("cookie: zpw_sek=sek.1.2; zpw_uin=100") ? response("200 OK", body: "batch") : response("401 Unauthorized")
        }
        try await server.start()
        defer { server.stop() }
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = await Self.loggedIn(dir)
        let data = try await client.downloadSyncBatch(url: server.url("/b"), timeout: 5)
        #expect(String(decoding: data, as: UTF8.self) == "batch")
        #expect(server.requests.count == 2)

        let anon = ZaloSessionClient(dataDirectory: dir, useKeychain: false)
        do {
            _ = try await anon.downloadSyncBatch(url: server.url("/b"), timeout: 5)
            Issue.record("expected an http error")
        } catch ZaloTransportError.httpError(let status, _) {
            #expect(status == 401)
        }
    }
}
