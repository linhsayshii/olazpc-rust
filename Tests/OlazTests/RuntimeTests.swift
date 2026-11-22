import Testing
import Foundation
@testable import Olaz

/// `CryptoBridge` must reproduce Node's crypto byte-for-byte on CommonCrypto/CryptoKit.
@MainActor
@Suite struct CryptoBridgeParity {
    @Test func zcidEncryptMatchesNode() throws {
        let out = try CryptoBridge.oneShot(encrypting: true, [
            "23,abc-imei,1792963077777", "aes-256-cbc", "3FC4F0D2AB50057BCE0D90D9187A22B1", NSNull(),
            ["key": "utf-8", "input": "utf-8", "output": "hex"],
        ])
        #expect(out as? String == "a1a69db6a344da4d883865c637f979495dd86112a4534347b462259bfdeb641b")
    }

    @Test func paramsRoundTripBase64() throws {
        let key = "DE71B7D4C57C0749158CB90D5E431AE3"
        let encrypted = try CryptoBridge.oneShot(encrypting: true, [
            "{\"language\":\"vi\"}", "aes-256-cbc", key, NSNull(), ["key": "utf-8", "input": "utf-8", "output": "base64"],
        ])
        #expect(encrypted as? String == "V5p1S6tTwaE91W8UDCagn9vVP9wUQ3QzA04wG7xh+5E=")
        let decrypted = try CryptoBridge.oneShot(encrypting: false, [
            encrypted, "aes-256-cbc", key, NSNull(), ["key": "utf-8", "input": "base64", "output": "utf-8"],
        ])
        #expect(decrypted as? String == "{\"language\":\"vi\"}")
    }

    @Test func streamingCTRAndGCM() throws {
        let ctr = try CryptoBridge.CipherSession(encrypting: true, algorithm: "aes-128-ctr", key: Data(repeating: 7, count: 16), iv: Data(repeating: 1, count: 16))
        var ctrData = try ctr.update(Data("hello zalo ctr mode!".utf8))
        ctrData.append(try ctr.final())
        let ctrOut = CryptoBridge.encode(ctrData, encoding: "hex") as? String
        #expect(ctrOut == "324a84ef5fc3a21b11456b948b319aab1c6e924d")

        let gcm = try CryptoBridge.CipherSession(encrypting: true, algorithm: "aes-256-gcm", key: Data(repeating: 3, count: 32), iv: Data(repeating: 9, count: 12))
        _ = try gcm.update(Data("gcm payload".utf8))
        let sealedData = try gcm.final()
        let sealed = CryptoBridge.encode(sealedData, encoding: "hex") as? String
        #expect(sealed == "636b00fbfe1c3505e56f0c")
        let tag = gcm.authTag
        #expect(tag?.map { String(format: "%02x", $0) }.joined() == "377ee9d6cfa423566629c0cfbb8eb885")
    }

    @Test func hashes() throws {
        let md5 = try CryptoBridge.digest("md5", Data("841630ae41f".utf8))
        #expect(CryptoBridge.encode(md5, encoding: "hex") as? String == "d9e97c18b27cd54e969268d9b39e8680")
        let sha256 = try CryptoBridge.digest("sha256", Data("zalo".utf8))
        #expect(CryptoBridge.encode(sha256, encoding: "base64") as? String == "PpYUHCFwTpavYlfqQcD8aQzgUEyFKdxCTciyRbY0PA8=")
    }

    @Test func badDecryptThrows() {
        #expect(throws: (any Error).self) {
            _ = try CryptoBridge.oneShot(encrypting: false, [
                "AAAAAAAAAAAAAAAAAAAAAA==", "aes-256-cbc", "DE71B7D4C57C0749158CB90D5E431AE3", NSNull(),
                ["key": "utf-8", "input": "base64", "output": "utf-8"],
            ])
        }
    }
}
