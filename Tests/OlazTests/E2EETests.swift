import Testing
import Foundation
@testable import Olaz

@Suite struct JSRuntimeShims {
    @Test func webCryptoSubsetMatchesKnownVectors() async throws {
        let rt = try JSRuntime(name: "test")
        // SHA-256("abc") and HMAC-SHA256(key="key", "The quick brown fox jumps over the lazy dog")
        try await rt.evaluate("""
        globalThis.T = {
          hex: (b) => Array.from(new Uint8Array(b), (x) => x.toString(16).padStart(2, '0')).join(''),
          async sha() { return T.hex(await crypto.subtle.digest('SHA-256', new TextEncoder().encode('abc'))); },
          async mac() {
            const k = await crypto.subtle.importKey('raw', new TextEncoder().encode('key'),
              { name: 'HMAC', hash: { name: 'SHA-256' } }, false, ['sign']);
            return T.hex(await crypto.subtle.sign({ name: 'HMAC' }, k,
              new TextEncoder().encode('The quick brown fox jumps over the lazy dog')));
          },
          async aes() {
            const key = crypto.getRandomValues(new Uint8Array(32)), iv = crypto.getRandomValues(new Uint8Array(16));
            const k = await crypto.subtle.importKey('raw', key, { name: 'AES-CBC' }, false, ['encrypt', 'decrypt']);
            const ct = await crypto.subtle.encrypt({ name: 'AES-CBC', iv }, k, new TextEncoder().encode('xin chào 💙'));
            return new TextDecoder().decode(await crypto.subtle.decrypt({ name: 'AES-CBC', iv }, k, ct));
          },
          timer() { return new Promise((r) => setTimeout(() => r('fired'), 10)); },
        };
        """)
        #expect(try await rt.callAsync("T.sha") == .string("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
        #expect(try await rt.callAsync("T.mac") == .string("f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"))
        #expect(try await rt.callAsync("T.aes") == .string("xin chào 💙"))
        #expect(try await rt.callAsync("T.timer") == .string("fired"))
        #expect(try await rt.evaluate("btoa(atob('AAEC/w=='))") == .string("AAEC/w=="))
    }

    @Test func bytesAndExceptionsCrossTheBridge() async throws {
        let rt = try JSRuntime(name: "test")
        try await rt.evaluate("""
        globalThis.T = {
          rev: (b) => new Uint8Array(b).reverse().subarray(1),   // offset view
          boom() { throw new RangeError('nope'); },
          reject: () => Promise.reject(new Error('later')),
        };
        """)
        #expect(try await rt.callAsync("T.rev", [.bytes(Data([1, 2, 3, 4]))]) == .bytes(Data([3, 2, 1])))
        await #expect(throws: JSRuntimeError.self) { try await rt.callAsync("T.boom") }
        await #expect(throws: JSRuntimeError.self) { try await rt.callAsync("T.reject") }
        await #expect(throws: JSRuntimeError.self) { try await rt.callAsync("T.missing") }
    }
}

@Suite(.serialized) struct SignalE2EETests {
    @Test func roundTripEstablishesSessionThenRatchets() async throws {
        let e2ee = try await SignalE2EE.load()
        try await e2ee.registerIdentity("alice")
        try await e2ee.registerIdentity("bob")
        try await e2ee.registerIdentity("alice") // idempotent

        let first = try await e2ee.encrypt("Chào Bob 👋", from: "alice", to: "bob")
        #expect(first.type == 3)
        #expect(Data(base64Encoded: first.body) != nil)
        #expect(try await e2ee.decrypt(first, at: "bob", from: "alice") == "Chào Bob 👋")

        let reply = try await e2ee.encrypt("Chào Alice!", from: "bob", to: "alice")
        #expect(reply.type == 1)
        #expect(try await e2ee.decrypt(reply, at: "alice", from: "bob") == "Chào Alice!")

        for i in 0..<5 {
            let text = "Tin nhắn số \(i) — mã hóa đầu cuối"
            let env = try await e2ee.encrypt(text, from: "alice", to: "bob")
            #expect(env.type == 1)
            #expect(try await e2ee.decrypt(env, at: "bob", from: "alice") == text)
        }
    }

    @Test func safetyNumberIsSixtyDigitsAndSymmetric() async throws {
        let e2ee = try await SignalE2EE.load()
        try await e2ee.registerIdentity("me")
        try await e2ee.registerIdentity("minh-anh")
        let ab = try await e2ee.safetyNumber("me", "minh-anh")
        let ba = try await e2ee.safetyNumber("minh-anh", "me")
        let digits = ab.filter { !$0.isWhitespace }
        #expect(digits.count == 60)
        #expect(digits.allSatisfy { $0.isNumber })
        #expect(ab.split(separator: " ").count == 12)
        #expect(ab == ba)
    }

    @Test func tamperedCiphertextIsRejected() async throws {
        let e2ee = try await SignalE2EE.load()
        try await e2ee.registerIdentity("carol")
        try await e2ee.registerIdentity("dave")
        let setup = try await e2ee.encrypt("hello", from: "carol", to: "dave")
        _ = try await e2ee.decrypt(setup, at: "dave", from: "carol")
        _ = try await e2ee.decrypt(try await e2ee.encrypt("ack", from: "dave", to: "carol"), at: "carol", from: "dave")

        var envelope = try await e2ee.encrypt("bí mật", from: "carol", to: "dave")
        #expect(envelope.type == 1)
        var bytes = try #require(Data(base64Encoded: envelope.body))
        bytes[bytes.count / 2] ^= 0x5A
        envelope.body = bytes.base64EncodedString()
        await #expect(throws: (any Error).self) {
            try await e2ee.decrypt(envelope, at: "dave", from: "carol")
        }
    }
}

@Suite(.serialized) struct ZaloPCE2EETests {
    @Test func pcRoundTripProcessPreKeyBundleEncryptAndDecrypt() async throws {
        let rt = try JSRuntime(name: "test-pc-roundtrip")
        try await rt.loadModule("vendor/libsignal-protocol.js")
        try await rt.loadModule("zalo-e2ee.js")

        let aliceInit = try await rt.callAsync("ZaloE2EE.pc.initOrRestore", [.string("alice_pc"), .string("")])
        let bobInit = try await rt.callAsync("ZaloE2EE.pc.initOrRestore", [.string("bob_pc"), .string("")])

        let aliceRegId = try #require(aliceInit["registrationId"]?.intValue)
        let bobRegId = try #require(bobInit["registrationId"]?.intValue)
        #expect(aliceRegId > 0)
        #expect(bobRegId > 0)

        let aliceBundle = try #require(aliceInit["bundlePayload"])
        #expect(aliceBundle["delSS"]?.intValue == 0)
        #expect(aliceBundle["key"]?["deviceId"]?.intValue == 2)

        // Bob establishes a session with Alice PC (deviceId = 2) from Alice's bundlePayload.
        let procRes = try await rt.callAsync("ZaloE2EE.pc.processPreKeyBundle", [
            .string("bob_pc"),
            .string("alice_pc"),
            .number(2),
            aliceBundle,
        ])
        #expect(procRes["ok"]?.boolValue == true)
        #expect(procRes["registrationId"]?.intValue == aliceRegId)

        let hasSess = try await rt.callAsync("ZaloE2EE.pc.hasSession", [.string("bob_pc"), .string("alice_pc"), .number(2)])
        #expect(hasSess.boolValue == true)

        let sessList = try await rt.callAsync("ZaloE2EE.pc.listSessions", [.string("bob_pc"), .string("alice_pc")])
        let sessRows = try #require(sessList.arrayValue)
        #expect(sessRows.count == 1)
        #expect(sessRows[0]["deviceId"]?.intValue == 2)
        #expect(sessRows[0]["registrationId"]?.intValue == aliceRegId)

        // 1. Bob encrypts string #1 -> PreKeyWhisperMessage (type 3), Alice decrypts exact plaintext.
        let enc1 = try await rt.callAsync("ZaloE2EE.pc.encryptCipher", [
            .string("bob_pc"),
            .string("alice_pc"),
            .number(2),
            .string("Xin chào Alice từ PC! 🔒"),
            .string("string"),
        ])
        #expect(enc1["ok"]?.boolValue == true)
        #expect(enc1["type"]?.intValue == 3)
        let cipher1 = try #require(enc1["cipher"]?.stringValue)
        #expect(cipher1.hasPrefix("AzM"))
        #expect(ZaloWireParser.isSignalCiphertext(cipher1))

        let dec1 = try await rt.callAsync("ZaloE2EE.pc.decryptCipher", [
            .string("alice_pc"),
            .string("bob_pc"),
            .number(2),
            .string(cipher1),
            .string("string"),
        ])
        #expect(dec1["ok"]?.boolValue == true)
        #expect(dec1["text"]?.stringValue == "Xin chào Alice từ PC! 🔒")

        // 2. Alice replies -> ratcheted WhisperMessage (type 1), Bob decrypts exact plaintext.
        let encReply = try await rt.callAsync("ZaloE2EE.pc.encryptCipher", [
            .string("alice_pc"),
            .string("bob_pc"),
            .number(2),
            .string("Chào Bob, ratchet ok!"),
            .string("string"),
        ])
        #expect(encReply["ok"]?.boolValue == true)
        #expect(encReply["type"]?.intValue == 1)
        let cipherReply = try #require(encReply["cipher"]?.stringValue)
        #expect(ZaloWireParser.isSignalCiphertext(cipherReply))
        #expect(ZaloE2EEManager.envelopeContainsSignalCipher(["content": cipherReply]))

        let decReply = try await rt.callAsync("ZaloE2EE.pc.decryptCipher", [
            .string("bob_pc"),
            .string("alice_pc"),
            .number(2),
            .string(cipherReply),
            .string("string"),
        ])
        #expect(decReply["ok"]?.boolValue == true)
        #expect(decReply["text"]?.stringValue == "Chào Bob, ratchet ok!")

        // 3. Bob sends uint32 sticker fields via encryptBatch (skipping missing device 9 cleanly) -> Alice decrypts exact uint32s.
        let batchRes = try await rt.callAsync("ZaloE2EE.pc.encryptBatch", [
            .string("bob_pc"),
            .array([
                .object(["userId": .string("alice_pc"), "deviceId": .number(2)]),
                .object(["userId": .string("alice_pc"), "deviceId": .number(9)]),
            ]),
            .array([.number(34840), .number(420), .number(7)]),
            .array([.string("uint32"), .string("uint32"), .string("uint32")]),
        ])
        #expect(batchRes["ok"]?.boolValue == true)
        let batchRows = try #require(batchRes["results"]?.arrayValue)
        #expect(batchRows.count == 1)
        #expect(batchRows[0]["deviceId"]?.intValue == 2)
        let rawCiphers = try #require(batchRows[0]["ciphers"]?.arrayValue)
        let stickerCiphers = rawCiphers.compactMap(\.stringValue)
        #expect(stickerCiphers.count == 3)

        var decodedNums: [Int] = []
        for c in stickerCiphers {
            let d = try await rt.callAsync("ZaloE2EE.pc.decryptCipher", [
                .string("alice_pc"),
                .string("bob_pc"),
                .number(2),
                .string(c),
                .string("uint32"),
            ])
            #expect(d["ok"]?.boolValue == true)
            decodedNums.append(try #require(d["number"]?.intValue))
        }
        #expect(decodedNums == [34840, 420, 7])
    }

    @Test func e2eeManagerOutgoingTextAndStickerRoundTripWithSQLite() async throws {
        let storeAlice = try ZaloSQLiteStore(path: ":memory:")
        let mgrAlice = ZaloE2EEManager()
        await mgrAlice.prepare(uid: "alice_uid", store: storeAlice)

        // Bob builds a session to Alice's PC bundle in an independent runtime and sends an initial message.
        let aliceStoreJSON = try #require(try await storeAlice.getPreferenceString(key: ZaloE2EEManager.storePrefKey))
        let bobRT = try JSRuntime(name: "test-bob-mgr")
        try await bobRT.loadModule("vendor/libsignal-protocol.js")
        try await bobRT.loadModule("zalo-e2ee.js")
        let bobInit = try await bobRT.callAsync("ZaloE2EE.pc.initOrRestore", [.string("bob_uid"), .string("")])
        let bobBundle = try #require(bobInit["bundlePayload"])
        _ = bobBundle

        // Extract Alice's bundlePayload from her store to give to Bob via processPreKeyBundle.
        let aliceParsed = try #require(JSONLossless.parseObject(Data(aliceStoreJSON.utf8)))
        let spk = try #require((aliceParsed["signedPreKeys"] as? [String: Any])?["1"] as? [String: Any])
        let pk = try #require((aliceParsed["preKeys"] as? [String: Any])?["1"] as? [String: Any])
        let identity = try #require(aliceParsed["identity"] as? [String: Any])
        let regId = try #require(aliceParsed["registrationId"])
        let zBundle = ZaloE2EEManager.nativeToJSValue([
            "deviceId": 2,
            "preKey": [
                "iKey": ["id": regId, "key": identity["pubKey"] as Any],
                "signature": spk["signature"] as Any,
                "spKey": ["id": 1, "key": spk["pubKey"] as Any],
            ],
            "opKey": ["id": 1, "key": pk["pubKey"] as Any],
        ])
        let bobProc = try await bobRT.callAsync("ZaloE2EE.pc.processPreKeyBundle", [.string("bob_uid"), .string("alice_uid"), .number(2), zBundle])
        #expect(bobProc["ok"]?.boolValue == true)

        let bobFirst = try await bobRT.callAsync("ZaloE2EE.pc.encryptCipher", [
            .string("bob_uid"), .string("alice_uid"), .number(2), .string("Hello Alice!"), .string("string"),
        ])
        let bobCipher = try #require(bobFirst["cipher"]?.stringValue)

        let decryptedBox = await mgrAlice.decryptEnvelopeIfNeeded(ZaloJSONBox([
            "data": [
                "msgs": [[
                    "msgId": "1001",
                    "cliMsgId": "1001",
                    "uidFrom": "bob_uid",
                    "idTo": "alice_uid",
                    "msgType": "webchat",
                    "ts": 1_795_000_000_000,
                    "paramsExt": ["platformType": 2],
                    "content": bobCipher,
                ]]
            ]
        ]), myUid: "alice_uid", store: storeAlice)
        let decryptedEvents = ZaloWireParser.extractBatchEvents(decryptedBox.dict, myUid: "alice_uid")
        #expect(decryptedEvents.count == 1)

        // Now Alice has an open session with Bob (device 2) and can encrypt outgoing text + quote + sticker!
        let textTargets = await mgrAlice.encryptTextMessage(
            peerUid: "bob_uid",
            myUid: "alice_uid",
            text: "Reply from Alice",
            quoteText: "Hello Alice!",
            quoteExtras: ["{}", "", "Bob", "gid-bob"],
            store: storeAlice
        )
        #expect(textTargets.count == 1)
        #expect(textTargets[0].toId == "bob_uid")
        #expect(textTargets[0].platform == 2)
        // Official quote layout: text, quote, attach, styles, owner name, owner global id.
        #expect(textTargets[0].ciphers.count == 6)

        let decText = try await bobRT.callAsync("ZaloE2EE.pc.decryptCipher", [
            .string("bob_uid"), .string("alice_uid"), .number(2), .string(textTargets[0].ciphers[0]), .string("string"),
        ])
        let decQuote = try await bobRT.callAsync("ZaloE2EE.pc.decryptCipher", [
            .string("bob_uid"), .string("alice_uid"), .number(2), .string(textTargets[0].ciphers[1]), .string("string"),
        ])
        #expect(decText["text"]?.stringValue == "Reply from Alice")
        #expect(decQuote["text"]?.stringValue == "Hello Alice!")
        // The peer never decrypts the attach cipher (index 2) of a text quote: later ones must still open.
        let decOwner = try await bobRT.callAsync("ZaloE2EE.pc.decryptCipher", [
            .string("bob_uid"), .string("alice_uid"), .number(2), .string(textTargets[0].ciphers[5]), .string("string"),
        ])
        let decName = try await bobRT.callAsync("ZaloE2EE.pc.decryptCipher", [
            .string("bob_uid"), .string("alice_uid"), .number(2), .string(textTargets[0].ciphers[4]), .string("string"),
        ])
        #expect(decOwner["text"]?.stringValue == "gid-bob")
        #expect(decName["text"]?.stringValue == "Bob")
        let fields = try #require(ZaloEngine.e2eeQuoteFields(ciphers: textTargets[0].ciphers, msgId: 9001, cliMsgId: 7001, ts: 5))
        #expect(fields["qmsgOwner"] as? String == textTargets[0].ciphers[5])
        #expect(fields["qmsgOwnerDName"] as? String == textTargets[0].ciphers[4])
        #expect(fields["qmsg"] as? String == textTargets[0].ciphers[1])
        #expect(fields["textProperties"] as? String == textTargets[0].ciphers[3])
        #expect(fields["qmsgAttach"] == nil)
        #expect(fields["qmsgCliId"] as? Int64 == 7001)
        #expect(ZaloEngine.e2eeQuoteFields(ciphers: Array(textTargets[0].ciphers.prefix(2)), msgId: 1, cliMsgId: 1, ts: 1) == nil)

        let stickerTargets = await mgrAlice.encryptStickerMessage(
            peerUid: "bob_uid",
            myUid: "alice_uid",
            stickerId: 55123,
            cateId: 88,
            store: storeAlice
        )
        #expect(stickerTargets.count == 1)
        #expect(stickerTargets[0].ciphers.count == 3)
        let decSid = try await bobRT.callAsync("ZaloE2EE.pc.decryptCipher", [
            .string("bob_uid"), .string("alice_uid"), .number(2), .string(stickerTargets[0].ciphers[0]), .string("uint32"),
        ])
        let decCat = try await bobRT.callAsync("ZaloE2EE.pc.decryptCipher", [
            .string("bob_uid"), .string("alice_uid"), .number(2), .string(stickerTargets[0].ciphers[1]), .string("uint32"),
        ])
        let decType = try await bobRT.callAsync("ZaloE2EE.pc.decryptCipher", [
            .string("bob_uid"), .string("alice_uid"), .number(2), .string(stickerTargets[0].ciphers[2]), .string("uint32"),
        ])
        #expect(decSid["number"]?.intValue == 55123)
        #expect(decCat["number"]?.intValue == 88)
        #expect(decType["number"]?.intValue == 7)

        // Bob replies quoting Alice: text, quote text, owner name and owner global id all arrive encrypted.
        func bobEncrypt(_ text: String) async throws -> String {
            let r = try await bobRT.callAsync("ZaloE2EE.pc.encryptCipher", [
                .string("bob_uid"), .string("alice_uid"), .number(2), .string(text), .string("string"),
            ])
            return try #require(r["cipher"]?.stringValue)
        }
        let cText = try await bobEncrypt("Đúng rồi")
        let cQuote = try await bobEncrypt("Reply from Alice")
        let cName = try await bobEncrypt("Alice")
        let cOwner = try await bobEncrypt("gid-alice")
        await mgrAlice.setGlobalIdResolver { gid, candidates in
            gid == "gid-alice" && candidates.first == "alice_uid" ? ("alice_uid", "own") : nil
        }
        let quoted = await mgrAlice.decryptEnvelopeIfNeeded(ZaloJSONBox([
            "data": ["msgs": [[
                "msgId": "1002", "cliMsgId": "1002", "uidFrom": "bob_uid", "idTo": "alice_uid", "msgType": "chat.quote",
                "ts": 1_795_000_001_000, "paramsExt": ["platformType": 2], "content": cText,
                "quote": ["msg": cQuote, "fromD": cName, "gOwnerId": cOwner, "globalMsgId": 1001],
            ]]]
        ]), myUid: "alice_uid", store: storeAlice)
        let q = try #require(((quoted.dict["data"] as? [String: Any])?["msgs"] as? [[String: Any]])?.first?["quote"] as? [String: Any])
        #expect(q["msg"] as? String == "Reply from Alice")
        #expect(q["fromD"] as? String == "Alice")
        #expect(q["ownerId"] as? String == "alice_uid")
        #expect(q["gOwnerId"] == nil)
        // The parser then shows the local name ("Bạn" for our own message), not the sender's nickname for us.
        guard case .message(let parsed, _)? = ZaloWireParser.extractBatchEvents(quoted.dict, myUid: "alice_uid").first else {
            Issue.record("quote reply did not parse as a message"); return
        }
        #expect(parsed.quote?.senderName == "Bạn")
    }
}
