import Foundation
import Network
import OlazCore
import Testing
@testable import Olaz

private final class IMEITestOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func first() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

private final class LoopbackLoginServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "olaz.test.imei-login-server")
    private let lock = NSLock()
    private var _requestLines: [String] = []
    private let reply: @Sendable (String) -> String
    private(set) var port: UInt16 = 0

    var requestLines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _requestLines
    }

    init(reply: @escaping @Sendable (String) -> String) throws {
        self.listener = try NWListener(using: .tcp)
        self.reply = reply
    }

    func start() async throws {
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [self] data, _, _, _ in
                guard let data else { return }
                let text = String(decoding: data, as: UTF8.self)
                let firstLine = text.components(separatedBy: "\r\n").first ?? ""
                lock.lock()
                _requestLines.append(firstLine)
                lock.unlock()
                let body = reply(firstLine)
                let http = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(http.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = IMEITestOnceFlag()
            listener.stateUpdateHandler = { state in
                if case .ready = state, once.first() {
                    cont.resume()
                } else if case .failed(let err) = state, once.first() {
                    cont.resume(throwing: err)
                }
            }
            listener.start(queue: queue)
        }
        port = listener.port?.rawValue ?? 0
    }

    func stop() {
        listener.cancel()
    }

    var baseURL: String { "http://127.0.0.1:\(port)" }
}

@Suite(.serialized) struct PCIMEIRetentionTests {
    private static let imeiDefaultsKey = "olaz.native.pc.imei"
    private static let suffix694 = ZaloCrypto.md5Hex("ZaloPC-darwin-23v694")
    private static let suffix695 = ZaloCrypto.md5Hex("ZaloPC-darwin-23v695")
    private static let stored694IMEI = "123e4567-e89b-42d3-a456-426614174000-\(suffix694)"

    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-imei-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeSuiteName() -> String {
        "olaz.imei.test.\(UUID().uuidString)"
    }

    private static func writeSessionFile(
        in dir: URL,
        zpwType: String?,
        imei: String,
        authBaseURL: String
    ) throws {
        var domains = ZaloDomains()
        domains.auth = authBaseURL
        domains.wpaChat = authBaseURL
        domains.isolated = true
        domains.serviceCandidates["profile"] = [authBaseURL]

        var obj: [String: Any] = [
            "imei": imei,
            "computerName": "TestMac",
            "domains": try JSONSerialization.jsonObject(with: JSONEncoder().encode(domains)),
            "plainAccount": [
                "userId": "100",
                "displayName": "Test",
                "avatar": "",
                "phone": "",
                "send2MeId": "100",
                "dkey": "dk",
                "zpwEnk": "0123456789abcdef",
                "zpwSek": "sek.1.2",
            ],
        ]
        if let zpwType {
            obj["zpwType"] = zpwType
        }
        let data = try JSONSerialization.data(withJSONObject: obj)
        try data.write(to: dir.appendingPathComponent("native-session.json"), options: .atomic)
    }

    private static func hexDecode(_ hex: String) -> Data? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = hexVal(chars[i]), let lo = hexVal(chars[i + 1]) else { return nil }
            out.append((hi << 4) | lo)
            i += 2
        }
        return out
    }

    private static func hexVal(_ b: UInt8) -> UInt8? {
        switch b {
        case 48...57: return b - 48
        case 65...70: return b - 55
        case 97...102: return b - 87
        default: return nil
        }
    }

    private static func extractIMEIFromLoginInfoRequest(_ requestLine: String) throws -> (zcidPlain: String, payloadIMEI: String, clientVersion: String) {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2,
              let comps = URLComponents(string: "http://127.0.0.1\(parts[1])"),
              let items = comps.queryItems else {
            throw ZaloTransportError.invalidJSON
        }
        var query: [String: String] = [:]
        for item in items {
            query[item.name] = item.value ?? ""
        }
        let zcid = try #require(query["zcid"])
        let zcidExt = try #require(query["zcid_ext"])
        let encParams = try #require(query["params"])
        let clientVersion = try #require(query["client_version"])

        let zcidData = try #require(hexDecode(zcid))
        let zcidPlainData = try ZaloCrypto.aesCBCCrypt(zcidData, key: ZaloCrypto.paramCipherKey, encrypt: false)
        let zcidPlain = String(decoding: zcidPlainData, as: UTF8.self)

        let md5Upper = Array(ZaloCrypto.md5Hex(zcidExt).uppercased())
        let zcidChars = Array(zcid)
        let nEven = stride(from: 0, to: md5Upper.count, by: 2).map { md5Upper[$0] }
        let aEven = stride(from: 0, to: zcidChars.count, by: 2).map { zcidChars[$0] }
        let aOdd = stride(from: 1, to: zcidChars.count, by: 2).map { zcidChars[$0] }
        let keyStr = String(nEven.prefix(8)) + String(aEven.prefix(12)) + String(aOdd.reversed().prefix(12))
        let plainParams = try ZaloCrypto.decodeAES(key: Data(keyStr.utf8), base64: encParams)
        let payload = try #require(JSONLossless.parseObject(string: plainParams))
        let payloadIMEI = try #require(payload["imei"] as? String)
        return (zcidPlain, payloadIMEI, clientVersion)
    }

    @Test func isValidPCIMEIValidatesShapeNotCurrentUASuffix() {
        #expect(ZaloSessionClient.isValidPCIMEI(Self.stored694IMEI))
        #expect(ZaloSessionClient.isValidPCIMEI(ZaloSessionClient.generateIMEI()))
        #expect(!ZaloSessionClient.isValidPCIMEI("short"))
        #expect(!ZaloSessionClient.isValidPCIMEI(Self.stored694IMEI.uppercased()))
        #expect(!ZaloSessionClient.isValidPCIMEI("\(String(repeating: "a", count: 36))-\(String(repeating: "0", count: 32))"))
        #expect(!ZaloSessionClient.isValidPCIMEI("123e4567-e89b-42d3-a456-426614174000-\(String(repeating: "g", count: 32))"))
    }

    @Test func emptyAndMalformedUserDefaultsMint695IMEI() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Empty UserDefaults -> mints fresh IMEI with 695 suffix and stores it.
        let emptySuite = Self.makeSuiteName()
        defer { UserDefaults(suiteName: emptySuite)?.removePersistentDomain(forName: emptySuite) }
        let freshClient = ZaloSessionClient(dataDirectory: dir, useKeychain: false, userDefaultsSuiteName: emptySuite)
        let minted = await freshClient.imei
        #expect(ZaloSessionClient.isValidPCIMEI(minted))
        #expect(minted.hasSuffix("-\(Self.suffix695)"))
        #expect(UserDefaults(suiteName: emptySuite)?.string(forKey: Self.imeiDefaultsKey) == minted)

        // Malformed stored values -> rejected, mints a fresh 695 IMEI and overwrites UserDefaults.
        let malformedSamples = [
            "short",
            Self.stored694IMEI.uppercased(),
            "\(String(repeating: "x", count: 36))-\(String(repeating: "y", count: 32))",
            "\(String(repeating: "a", count: 36))-\(String(repeating: "0", count: 32))",
        ]
        for bad in malformedSamples {
            let suite = Self.makeSuiteName()
            defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            UserDefaults(suiteName: suite)?.set(bad, forKey: Self.imeiDefaultsKey)
            let client = ZaloSessionClient(dataDirectory: dir, useKeychain: false, userDefaultsSuiteName: suite)
            let imei = await client.imei
            #expect(imei != bad)
            #expect(ZaloSessionClient.isValidPCIMEI(imei))
            #expect(imei.hasSuffix("-\(Self.suffix695)"))
            #expect(UserDefaults(suiteName: suite)?.string(forKey: Self.imeiDefaultsKey) == imei)
        }
    }

    @Test func stored694IMEISurvivesInitRestoreAndGetLoginInfoInSwiftAndCore() async throws {
        let server = try LoopbackLoginServer { _ in
            #"{"error_code":0,"data":{"uid":"100","zpw_enk":"0123456789abcdef","zpw_sek":"sek.1.2","display_name":"Test"}}"#
        }
        try await server.start()
        defer { server.stop() }

        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. Init preserves a stored 694 IMEI from UserDefaults["olaz.native.pc.imei"].
        let suiteWith694 = Self.makeSuiteName()
        defer { UserDefaults(suiteName: suiteWith694)?.removePersistentDomain(forName: suiteWith694) }
        UserDefaults(suiteName: suiteWith694)?.set(Self.stored694IMEI, forKey: Self.imeiDefaultsKey)
        let initClient = ZaloSessionClient(dataDirectory: dir, useKeychain: false, userDefaultsSuiteName: suiteWith694)
        #expect(await initClient.imei == Self.stored694IMEI)
        #expect(UserDefaults(suiteName: suiteWith694)?.string(forKey: Self.imeiDefaultsKey) == Self.stored694IMEI)

        // 2. Restore from native-session.json (zpwType == "23") keeps the 694 IMEI even when UserDefaults was empty,
        // and sends it unchanged on getLoginInfo (Swift path).
        try Self.writeSessionFile(in: dir, zpwType: "23", imei: Self.stored694IMEI, authBaseURL: server.baseURL)
        let emptySuite = Self.makeSuiteName()
        defer { UserDefaults(suiteName: emptySuite)?.removePersistentDomain(forName: emptySuite) }
        let restoreClient = ZaloSessionClient(dataDirectory: dir, useKeychain: false, userDefaultsSuiteName: emptySuite)
        #expect(await restoreClient.imei != Self.stored694IMEI)
        #expect(await restoreClient.loadSavedSession())
        #expect(await restoreClient.imei == Self.stored694IMEI)
        #expect(await restoreClient.sessionStatus() == .valid)

        let swiftReq = try #require(server.requestLines.first(where: { $0.contains("/api/login/getLoginInfo") }))
        let swiftParsed = try Self.extractIMEIFromLoginInfoRequest(swiftReq)
        #expect(swiftParsed.clientVersion == "695")
        #expect(swiftParsed.payloadIMEI == Self.stored694IMEI)
        #expect(swiftParsed.zcidPlain.hasPrefix("23,\(Self.stored694IMEI),"))

        // 3. Rust CoreSession.restore also keeps the 694 IMEI and sends it unchanged on sessionStatus -> getLoginInfo.
        let snapshotJSON = try #require(await restoreClient.readSavedSessionSnapshotJSON())
        let coreSession = try CoreSession.withConfig(
            imei: ZaloSessionClient.generateIMEI(),
            computerName: "TestMac",
            domainsJson: nil
        )
        #expect(try coreSession.restore(snapshotJson: snapshotJSON))
        let countBefore = server.requestLines.count
        let status = try await coreSession.sessionStatus()
        #expect(status == .valid)
        let coreReq = try #require(server.requestLines.dropFirst(countBefore).first(where: { $0.contains("/api/login/getLoginInfo") }))
        let coreParsed = try Self.extractIMEIFromLoginInfoRequest(coreReq)
        #expect(coreParsed.clientVersion == "695")
        #expect(coreParsed.payloadIMEI == Self.stored694IMEI)
        #expect(coreParsed.zcidPlain.hasPrefix("23,\(Self.stored694IMEI),"))
    }

    @Test func malformedSessionIMEIAndLegacyType30RestoreBehaviors() async throws {
        let server = try LoopbackLoginServer { _ in
            #"{"error_code":5,"error_message":"legacy rejected"}"#
        }
        try await server.start()
        defer { server.stop() }

        // 1. Malformed IMEI in a type-23 native-session.json is ignored; newly minted 695 IMEI is kept.
        let dirBad = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dirBad) }
        let badIMEI = "\(String(repeating: "x", count: 36))-\(String(repeating: "y", count: 32))"
        try Self.writeSessionFile(in: dirBad, zpwType: "23", imei: badIMEI, authBaseURL: server.baseURL)
        let badSuite = Self.makeSuiteName()
        defer { UserDefaults(suiteName: badSuite)?.removePersistentDomain(forName: badSuite) }
        let badClient = ZaloSessionClient(dataDirectory: dirBad, useKeychain: false, userDefaultsSuiteName: badSuite)
        let minted = await badClient.imei
        #expect(minted.hasSuffix("-\(Self.suffix695)"))
        #expect(await badClient.loadSavedSession())
        #expect(await badClient.imei == minted)

        // 2. Legacy type-30 session still migrates via needsPCTypeUpgrade: rejected getLoginInfo -> .expired without me-v2 probe.
        let dirLegacy = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dirLegacy) }
        let webIMEI = "123e4567-e89b-42d3-a456-426614174000-\(ZaloCrypto.md5Hex("Mozilla/5.0 WebLegacy"))"
        try Self.writeSessionFile(in: dirLegacy, zpwType: "30", imei: webIMEI, authBaseURL: server.baseURL)
        let legacySuite = Self.makeSuiteName()
        defer { UserDefaults(suiteName: legacySuite)?.removePersistentDomain(forName: legacySuite) }
        let legacyClient = ZaloSessionClient(dataDirectory: dirLegacy, useKeychain: false, userDefaultsSuiteName: legacySuite)
        #expect(await legacyClient.loadSavedSession())
        #expect(await legacyClient.imei == webIMEI)
        let reqsBefore = server.requestLines.count
        let status = await legacyClient.sessionStatus()
        #expect(status == .expired)
        let newReqs = Array(server.requestLines.dropFirst(reqsBefore))
        #expect(newReqs.allSatisfy { $0.contains("/api/login/getLoginInfo") })
        #expect(!newReqs.contains(where: { $0.contains("/api/social/profile/me-v2") }))
    }
}
