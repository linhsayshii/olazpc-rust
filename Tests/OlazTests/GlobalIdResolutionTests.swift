import Foundation
import os
import Testing
@testable import Olaz

@Suite(.serialized) struct GlobalIdResolutionTests {
    @Test func largeSyncBatchSurvivesURIAndHeaderLimits() async throws {
        let key = Data("0123456789abcdef".utf8)
        let ids = (1...200).map { String(format: "%032x", $0) }
        let expected = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, String(1000 + $0.offset)) })
        let sizes = OSAllocatedUnfairLock<[Int]>(initialState: [])
        let server = try FakeZaloServer { req in
            guard req.path == "/api/gid/decrypt", req.method == "GET",
                  let payload = req.decodeEncryptedParams(key: key),
                  let text = payload["globalUids"] as? String,
                  let chunk = try? JSONDecoder().decode([String].self, from: Data(text.utf8)) else {
                return .json(400, [:])
            }
            sizes.withLock { $0.append(chunk.count) }
            // A conservative proxy limit; HTTP/2 counts :path toward header limits too.
            if req.query.utf8.count > 8192 { return .json(414, [:]) }
            if chunk.count > 12 { return .json(431, [:]) }
            let map = Dictionary(uniqueKeysWithValues: chunk.compactMap { id in expected[id].map { (id, $0) } })
            return .json(200, ["error_code": 0, "data": map])
        }
        try await server.start()
        defer { server.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gid-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = ZaloSessionClient(dataDirectory: dir, useKeychain: false)
        await client.updateCredentials(
            account: ZaloLoginAccount(userId: "100", displayName: "Fixture", send2MeId: "999", zpwEnk: "0123456789abcdef", zpwSek: "fixture"),
            secretKey: key, zpwSek: "fixture", domains: server.domains(for: ["profile"]))
        let resolved = await client.decryptGlobalIds(ids)
        #expect(resolved == expected)
        #expect(sizes.withLock { $0.contains(where: { $0 <= 12 }) })
        let before = sizes.withLock { $0.count }
        #expect(await client.decryptGlobalIds(ids) == expected)
        #expect(sizes.withLock { $0.count } == before)
    }

    @Test func encryptUsesArrayPayloadAndPopulatesTheReverseCache() async throws {
        let key = Data("0123456789abcdef".utf8)
        let uids = (1...60).map(String.init)
        let expected = Dictionary(uniqueKeysWithValues: uids.map { ($0, String(repeating: "x", count: 28) + String(format: "%04d", Int($0)!)) })
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let server = try FakeZaloServer { req in
            calls.withLock { $0 += 1 }
            guard req.path == "/api/gid/encrypt", req.method == "GET",
                  let chunk = req.decodeEncryptedParams(key: key)?["noiseUids"] as? [String] else {
                return .json(400, [:])
            }
            if chunk.count > 10 { return .json(414, [:]) }
            let map = Dictionary(uniqueKeysWithValues: chunk.compactMap { uid in expected[uid].map { (uid, $0) } })
            return .json(200, ["error_code": 0, "data": map])
        }
        try await server.start()
        defer { server.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gid-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = ZaloSessionClient(dataDirectory: dir, useKeychain: false)
        await client.updateCredentials(
            account: ZaloLoginAccount(userId: "100", displayName: "Fixture", send2MeId: "999", zpwEnk: "0123456789abcdef", zpwSek: "fixture"),
            secretKey: key, zpwSek: "fixture", domains: server.domains(for: ["profile"]))
        #expect(await client.encryptGlobalIds(uids) == expected)
        let before = calls.withLock { $0 }
        #expect(await client.decryptGlobalIds(Array(expected.values)) == Dictionary(uniqueKeysWithValues: expected.map { ($0.value, $0.key) }))
        #expect(calls.withLock { $0 } == before)
    }

}
