import Testing
import Foundation
@testable import Olaz

/// Wave 6c (ADR-015): Rust Signal engine in shadow mode and as the authoritative backend, driven through
/// `ZaloE2EEManager` with synthetic test keys and a real JavaScriptCore peer. No network, no user data.
private final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ line: String) { lock.withLock { items.append(line) } }
    var lines: [String] { lock.withLock { items } }
}

private let aliceUid = "alice_uid"
private let bobUid = "bob_uid"

/// A JS peer ("Bob", PC device 2) that can encrypt to Alice's PC bundle and decrypt her ciphers.
private struct JSPeer {
    let rt: JSRuntime

    static func make(toward aliceStoreJSON: String) async throws -> JSPeer {
        let rt = try JSRuntime(name: "test-bob-6c")
        try await rt.loadModule("vendor/libsignal-protocol.js")
        try await rt.loadModule("zalo-e2ee.js")
        _ = try await rt.callAsync("ZaloE2EE.pc.initOrRestore", [.string(bobUid), .string("")])
        let parsed = try #require(JSONLossless.parseObject(Data(aliceStoreJSON.utf8)))
        let spk = try #require((parsed["signedPreKeys"] as? [String: Any])?["1"] as? [String: Any])
        let pk = try #require((parsed["preKeys"] as? [String: Any])?["1"] as? [String: Any])
        let identity = try #require(parsed["identity"] as? [String: Any])
        let regId = try #require(parsed["registrationId"])
        let bundle = ZaloE2EEManager.nativeToJSValue([
            "deviceId": 2,
            "preKey": [
                "iKey": ["id": regId, "key": identity["pubKey"] as Any],
                "signature": spk["signature"] as Any,
                "spKey": ["id": 1, "key": spk["pubKey"] as Any],
            ],
            "opKey": ["id": 1, "key": pk["pubKey"] as Any],
        ])
        let res = try await rt.callAsync(
            "ZaloE2EE.pc.processPreKeyBundle", [.string(bobUid), .string(aliceUid), .number(2), bundle])
        #expect(res["ok"]?.boolValue == true)
        return JSPeer(rt: rt)
    }

    func encrypt(_ text: String) async throws -> (cipher: String, type: Int) {
        let r = try await rt.callAsync(
            "ZaloE2EE.pc.encryptCipher",
            [.string(bobUid), .string(aliceUid), .number(2), .string(text), .string("string")])
        return (try #require(r["cipher"]?.stringValue), try #require(r["type"]?.intValue))
    }

    func decrypt(_ cipher: String) async throws -> String? {
        let r = try await rt.callAsync(
            "ZaloE2EE.pc.decryptCipher",
            [.string(bobUid), .string(aliceUid), .number(2), .string(cipher), .string("string")])
        return r["text"]?.stringValue
    }
}

private func envelope(_ cipher: String, id: Int) -> ZaloJSONBox {
    ZaloJSONBox([
        "data": [
            "msgs": [[
                "msgId": "\(id)", "cliMsgId": "\(id)", "uidFrom": bobUid, "idTo": aliceUid,
                "msgType": "webchat", "ts": 1_795_000_000_000 + id, "paramsExt": ["platformType": 2],
                "content": cipher,
            ]]
        ]
    ])
}

private func content(_ box: ZaloJSONBox) -> String? {
    let msgs = (box.dict["data"] as? [String: Any])?["msgs"] as? [[String: Any]]
    return msgs?.first?["content"] as? String
}

/// Alice's side of the conversation on `mgr`: Bob opens with a prekey message, Alice replies, Bob replies.
/// Returns Bob and the three plaintexts Alice saw.
private func converse(_ mgr: ZaloE2EEManager, store: ZaloSQLiteStore, idBase: Int) async throws -> JSPeer {
    await mgr.prepare(uid: aliceUid, store: store)
    let aliceJSON = try #require(try await store.getPreferenceString(key: ZaloE2EEManager.storePrefKey))
    let bob = try await JSPeer.make(toward: aliceJSON)

    let first = try await bob.encrypt("Hello Alice! secret-A")
    #expect(first.type == 3)
    let d1 = await mgr.decryptEnvelopeIfNeeded(envelope(first.cipher, id: idBase + 1), myUid: aliceUid, store: store)
    #expect(content(d1) == "Hello Alice! secret-A")

    let out = await mgr.encryptTextMessage(
        peerUid: bobUid, myUid: aliceUid, text: "Reply secret-B", quoteText: nil, store: store)
    #expect(out.count == 1 && out[0].platform == 2 && out[0].ciphers.count == 1)
    #expect(try await bob.decrypt(out[0].ciphers[0]) == "Reply secret-B")

    let second = try await bob.encrypt("Second secret-C")
    #expect(second.type == 1)
    let d2 = await mgr.decryptEnvelopeIfNeeded(envelope(second.cipher, id: idBase + 2), myUid: aliceUid, store: store)
    #expect(content(d2) == "Second secret-C")
    return bob
}

@Suite(.serialized) struct RustE2EEModeTests {
    @Test func shadowModeCountsMatchesAndNeverWrites() async throws {
        let store = try ZaloSQLiteStore(path: ":memory:")
        let log = LogBox()
        let mgr = ZaloE2EEManager(mode: .shadow, logSink: { log.append($0) })
        _ = try await converse(mgr, store: store, idBase: 100)
        await mgr.shadowStats.waitUntilIdle()

        let snap = mgr.shadowStats.snapshot
        #expect(snap.matches == 2)  // one prekey, one whisper
        #expect(snap.mismatches == 0)
        #expect(snap.errors == 0)
        #expect(await mgr.activeMode == .shadow)
        #expect(await !mgr.debugHasRustStore)

        // JS stayed the only writer: the persisted JSON is exactly what JS exports now.
        let persisted = try #require(try await store.getPreferenceString(key: ZaloE2EEManager.storePrefKey))
        #expect(persisted == (await mgr.debugExportJSStore()))

        // Shapes only: no plaintext, cipher, uid, key material in any line.
        let shadowLines = log.lines.filter { $0.hasPrefix("e2ee-shadow:") }
        #expect(shadowLines.count == 2)
        #expect(shadowLines.contains("e2ee-shadow: match type=prekey"))
        #expect(shadowLines.contains("e2ee-shadow: match type=whisper"))
        let all = log.lines.joined(separator: "\n")
        for secret in ["secret-", "Hello", "Reply", bobUid, aliceUid] {
            #expect(!all.contains(secret))
        }
    }

    @Test func switchModeIsAuthoritativeAndJSCanReadItsStore() async throws {
        let store = try ZaloSQLiteStore(path: ":memory:")
        let log = LogBox()
        let mgr = ZaloE2EEManager(mode: .authoritative, logSink: { log.append($0) })
        let bob = try await converse(mgr, store: store, idBase: 200)
        #expect(await mgr.activeMode == .authoritative)
        #expect(await mgr.debugHasRustStore)
        #expect(await mgr.debugExportJSStore() == nil)  // the JS runtime was never loaded
        #expect(mgr.shadowStats.snapshot == E2EEShadowStats.Snapshot())

        // Rust wrote the same preference key, in the shape JS restores.
        let persisted = try #require(try await store.getPreferenceString(key: ZaloE2EEManager.storePrefKey))
        let json = try #require(JSONLossless.parseObject(Data(persisted.utf8)))
        #expect(json["version"] as? Int == 1)
        let probe = try JSRuntime(name: "test-js-reader")
        try await probe.loadModule("vendor/libsignal-protocol.js")
        try await probe.loadModule("zalo-e2ee.js")
        let restored = try await probe.callAsync("ZaloE2EE.pc.initOrRestore", [.string(aliceUid), .string(persisted)])
        #expect(restored["restored"]?.boolValue == true)
        let sessions = try await probe.callAsync("ZaloE2EE.pc.listSessions", [.string(aliceUid), .string(bobUid)])
        #expect(sessions.arrayValue?.contains { $0["deviceId"]?.intValue == 2 } == true)

        // A sticker-style uint32 batch also goes through Rust.
        let sticker = await mgr.encryptStickerMessage(
            peerUid: bobUid, myUid: aliceUid, stickerId: 55123, cateId: 88, store: store)
        #expect(sticker.count == 1 && sticker[0].ciphers.count == 3)
        let n = try await bob.rt.callAsync("ZaloE2EE.pc.decryptCipher", [
            .string(bobUid), .string(aliceUid), .number(2), .string(sticker[0].ciphers[0]), .string("uint32"),
        ])
        #expect(n["number"]?.intValue == 55123)
        #expect(!log.lines.joined().contains("secret-"))
    }

    @Test func switchingOffLetsJSContinueFromTheRustWrittenStore() async throws {
        let store = try ZaloSQLiteStore(path: ":memory:")
        let rustMgr = ZaloE2EEManager(mode: .authoritative, logSink: { _ in })
        let bob = try await converse(rustMgr, store: store, idBase: 300)

        // Flag off: a fresh manager (JS only) restores from what Rust persisted.
        let jsMgr = ZaloE2EEManager(mode: .off, logSink: { _ in })
        await jsMgr.prepare(uid: aliceUid, store: store)
        #expect(await !jsMgr.debugHasRustStore)

        let third = try await bob.encrypt("Third secret-D")
        let d3 = await jsMgr.decryptEnvelopeIfNeeded(envelope(third.cipher, id: 303), myUid: aliceUid, store: store)
        #expect(content(d3) == "Third secret-D")

        let out = await jsMgr.encryptTextMessage(
            peerUid: bobUid, myUid: aliceUid, text: "JS reply secret-E", quoteText: nil, store: store)
        #expect(out.count == 1)
        #expect(try await bob.decrypt(out[0].ciphers[0]) == "JS reply secret-E")

        // And back on: Rust reads the JS-rewritten store and keeps going.
        let rustAgain = ZaloE2EEManager(mode: .authoritative, logSink: { _ in })
        let fourth = try await bob.encrypt("Fourth secret-F")
        let d4 = await rustAgain.decryptEnvelopeIfNeeded(envelope(fourth.cipher, id: 304), myUid: aliceUid, store: store)
        #expect(content(d4) == "Fourth secret-F")
    }

    @Test func corruptSavedStoreFallsBackToJSWithoutOverwriting() async throws {
        let store = try ZaloSQLiteStore(path: ":memory:")
        try await store.setPreferenceString(key: ZaloE2EEManager.storePrefKey, value: "{not json at all")
        let log = LogBox()
        let mgr = ZaloE2EEManager(mode: .authoritative, logSink: { log.append($0) })
        await mgr.prepare(uid: aliceUid, store: store)
        #expect(await !mgr.debugHasRustStore)
        #expect(await mgr.activeMode == .off)
        #expect(log.lines.contains { $0.hasPrefix("e2ee: rust init failed kind=") })
    }

    @Test func modeResolutionHonoursFlags() throws {
        let suite = "olaz.test.e2eeRust.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(E2EERustMode.resolve(rustCoreEnabled: true, env: [:], defaults: defaults) == .shadow)
        #expect(E2EERustMode.resolve(rustCoreEnabled: false, env: ["OLAZ_E2EE_RUST": "1"], defaults: defaults) == .off)
        #expect(E2EERustMode.resolve(rustCoreEnabled: true, env: ["OLAZ_E2EE_RUST": "1"], defaults: defaults) == .authoritative)
        #expect(E2EERustMode.resolve(rustCoreEnabled: true, env: ["OLAZ_E2EE_RUST": "0"], defaults: defaults) == .shadow)
        defaults.set(true, forKey: E2EERustMode.defaultsKey)
        #expect(E2EERustMode.resolve(rustCoreEnabled: true, env: [:], defaults: defaults) == .authoritative)
        #expect(E2EERustMode.resolve(rustCoreEnabled: false, env: [:], defaults: defaults) == .off)
    }

    @Test func shadowComparatorClassifiesWithoutLeakingValues() {
        let text = Data("hello".utf8)
        #expect(E2EEShadow.classify(js: .plain(text), rust: .success(text), format: "string") == .match)
        #expect(E2EEShadow.classify(js: .plain(text), rust: .success(Data("other".utf8)), format: "string")
            == .mismatch(reason: "plaintext_differs"))
        #expect(E2EEShadow.classify(js: .failed, rust: .success(text), format: "string")
            == .mismatch(reason: "js_failed_rust_ok"))
        #expect(E2EEShadow.classify(js: .failed, rust: .failure(CancellationError()), format: "string") == .bothFailed)
        #expect(E2EEShadow.classify(js: .plain(text), rust: .failure(CancellationError()), format: "string")
            == .mismatch(reason: "rust_error_other"))
        #expect(E2EEShadow.classify(js: E2EEShadow.jsPlain(number: 55123),
                                    rust: .success(Data([0x53, 0xd7, 0, 0, 9, 9])), format: "uint32") == .match)
        let line = E2EEShadow.logLine(.mismatch(reason: "plaintext_differs"), type: "whisper")
        #expect(line == "e2ee-shadow: mismatch type=whisper reason=plaintext_differs")
        #expect(E2EEShadow.logLine(.bothFailed, type: "prekey") == nil)
        #expect(E2EEShadow.cipherType("AzMohGkIATAB") == "prekey")
        #expect(E2EEShadow.cipherType("ATMKIQUmoM6y") == "whisper")

        let stats = E2EEShadowStats()
        for v: E2EEShadowVerdict? in [.match, .match, .mismatch(reason: "x"), .bothFailed, nil] {
            #expect(stats.tryBegin())
            stats.finish(v)
        }
        #expect(stats.snapshot == .init(matches: 2, mismatches: 1, errors: 1, skipped: 0, bothFailed: 1))
        for _ in 0..<E2EEShadowStats.maxInFlight { #expect(stats.tryBegin()) }
        #expect(!stats.tryBegin())
        #expect(stats.snapshot.skipped == 1)
    }
}
