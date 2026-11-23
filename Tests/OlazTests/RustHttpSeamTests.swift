import Foundation
import OlazCore
import Testing
@testable import Olaz

/// Captures the multipart request of the Swift fallback (no network).
private final class CaptureURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var captured: (url: URL, contentType: String, body: Data)?
    static let host = "rust-seam.test.zaloapp.com"

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n > 0 { body.append(contentsOf: buf.prefix(n)) } else { break }
            }
        }
        Self.captured = (request.url!, request.value(forHTTPHeaderField: "Content-Type") ?? "", body)
        let reply = Data(#"{"error_code":0,"data":{"ok":1}}"#.utf8)
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension ZaloSessionClient {
    /// The raw `[String: Any]` answers are not Sendable; tests read them through the engine's `ZaloJSONBox`.
    func postBox(service: String, path: String, payload: [String: Any]) async throws -> ZaloJSONBox {
        ZaloJSONBox(try await post(service: service, path: path, encryptedPayload: payload))
    }

    func multipartBox(file: String, offset: UInt64, length: UInt64?) async throws -> ZaloJSONBox {
        ZaloJSONBox(try await postMultipart(
            service: "file", path: "/api/x/upload", encryptedPayload: ["chunkId": 1],
            fieldName: "chunkContent", fileName: "up.bin", mimeType: "application/octet-stream",
            filePath: file, offset: offset, length: length))
    }
}

@Suite(.serialized) struct RustHttpSeamTests {
    private static func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-seam-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func login(_ client: ZaloSessionClient, domains: ZaloDomains? = nil) async {
        await client.updateCredentials(
            account: ZaloLoginAccount(userId: "100", displayName: "An", send2MeId: "999", zpwEnk: "0123456789abcdef", zpwSek: "sek.1.2"),
            secretKey: Data("0123456789abcdef".utf8), zpwSek: "sek.1.2", domains: domains)
    }

    @Test func coreHttpFollowsTheSameGatingAsCoreApi() async throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = ZaloSessionClient(dataDirectory: dir, useKeychain: false, useRustCore: true)
        #expect(await client.coreHttp() == nil)   // no account yet
        await Self.login(client)
        #expect(await client.coreHttp() != nil)
        #expect(await ZaloSessionClient(dataDirectory: dir, useKeychain: false, useRustCore: false).coreHttp() == nil)
        // A stubbed URLSession (tests) must keep the Swift transport so the stub still sees the requests.
        let stubbed = ZaloSessionClient(dataDirectory: dir, useKeychain: false, urlSession: URLSession(configuration: .ephemeral), useRustCore: true)
        await Self.login(stubbed)
        #expect(await stubbed.coreHttp() == nil)
        #expect(await stubbed.coreApi() == nil)
    }

    @Test func swiftPathStillThrowsNotAuthenticatedWithoutASession() async {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = ZaloSessionClient(dataDirectory: dir, useKeychain: false, useRustCore: true)
        await #expect(throws: ZaloTransportError.self) {
            _ = try await client.postBox(service: "profile", path: "/api/x", payload: [:])
        }
    }

    @Test func coreHttpErrorsMapLikeTheSwiftTransport() async throws {
        let session = try CoreSession(computerName: "Mac")
        let http = CoreHttp(session: session)
        let record = HttpRequestRecord(
            method: .post, service: "profile", path: "/api/x", query: [:], headers: [:],
            payloadJson: #"{"a":1}"#, rawEncrypted: nil, decryptResponse: true)
        do {
            _ = try await http.request(request: record)
            Issue.record("expected an error")
        } catch {
            // No session: fails before any network call.
            #expect(RustCore.mapError(error, path: "/api/x") is ZaloTransportError)
        }
        var bad = record
        bad.payloadJson = "[1]"
        do {
            _ = try await http.request(request: bad)
            Issue.record("expected an error")
        } catch {
            guard case ZaloTransportError.invalidJSON = RustCore.mapError(error) else {
                Issue.record("expected invalidJSON, got \(error)")
                return
            }
        }
    }

    @Test func sessionErrorsCarryThePathAndTimeoutsStayTimeouts() {
        let err = RustCore.mapError(CoreError.Session(code: -5, message: "no", isAuth: false), path: "/api/group/create")
        #expect((err as? ZaloSessionError)?.url == "/api/group/create")
        #expect((err as? ZaloSessionError)?.code == -5)
        let timeout = RustCore.mapError(CoreError.Network(kind: .timeout, message: "t"), quietTimeout: true)
        #expect((timeout as? URLError)?.code == .timedOut)
        let board = RustCore.mapError(CoreError.Session(code: 112, message: "", isAuth: false), path: "/api/board/oneone/list")
        #expect((board as? ZaloSessionError)?.code == 112)
    }

    @Test func swiftFallbackReadsTheFileSliceForMultipart() async throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("up.bin")
        try Data("0123456789".utf8).write(to: file)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CaptureURLProtocol.self]
        let client = ZaloSessionClient(dataDirectory: dir, useKeychain: false, urlSession: URLSession(configuration: config))
        var domains = ZaloDomains()
        domains.serviceCandidates["file"] = ["https://\(CaptureURLProtocol.host)"]
        await Self.login(client, domains: domains)
        let resp = try await client.multipartBox(file: file.path, offset: 2, length: 5)
        #expect(JSONLossless.int64((resp.dict["data"] as? [String: Any])?["ok"]) == 1)
        let captured = try #require(CaptureURLProtocol.captured)
        #expect(captured.contentType.hasPrefix("multipart/form-data; boundary=----OlazBoundary"))
        #expect(captured.body.range(of: Data("23456".utf8)) != nil)
        #expect(captured.body.range(of: Data("0123456".utf8)) == nil)
    }
}
