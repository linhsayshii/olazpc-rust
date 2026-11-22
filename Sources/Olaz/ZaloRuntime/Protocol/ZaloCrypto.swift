import AppKit
import CommonCrypto
import CoreImage
import CryptoKit
import Foundation
import Security
import zlib

enum ZaloCryptoError: LocalizedError {
    case invalidKeyLength(Int)
    case invalidPadding
    case invalidBase64
    case cipherFailed(Int32)
    case inflateFailed
    case missingCipherKey
    case invalidGCMBlob(Int)
    case unsupportedEncryption(UInt8)

    var errorDescription: String? {
        switch self {
        case .invalidKeyLength(let n): "Invalid AES key length \(n)"
        case .invalidPadding: "PKCS#7 padding verification failed"
        case .invalidBase64: "Invalid Base64 payload"
        case .cipherFailed(let status): "CommonCrypto failed (\(status))"
        case .inflateFailed: "Failed to decompress payload"
        case .missingCipherKey: "Missing WebSocket cipher key"
        case .invalidGCMBlob(let n): "AES-GCM blob too short (\(n) bytes)"
        case .unsupportedEncryption(let kind): "Unsupported encryption scheme \(kind)"
        }
    }
}

enum ZaloCrypto {
    /// `zsecureSecrets().getParamCipherKey()` — 32 ASCII chars used directly as AES-256-CBC key.
    static let paramCipherKey = Data("3FC4F0D2AB50057BCE0D90D9187A22B1".utf8)
    static let passwordKeyPrefix = "9fc5vEW3"
    static let zeroIV = Data(count: 16)

    // MARK: Digests & Random

    static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func md5Hex(_ string: String) -> String {
        md5Hex(Data(string.utf8))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    static func sha256HexUpper(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02X", $0) }.joined()
    }

    static func randomHex(_ length: Int) -> String {
        guard length > 0 else { return "" }
        let byteCount = (length + 1) / 2
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(length))
    }

    static func randomSalt(_ length: Int = 8) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789".utf8)
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(decoding: bytes.map { alphabet[Int($0) % alphabet.count] }, as: UTF8.self)
    }

    // MARK: AES-CBC (Zero IV, strict PKCS#7)

    static func encodeAES(key: Data, plaintext: String) throws -> String {
        try encodeAES(key: key, data: Data(plaintext.utf8))
    }

    static func encodeAES(key: Data, data: Data) throws -> String {
        let ct = try aesCBCCrypt(data, key: key, iv: zeroIV, encrypt: true)
        return ct.base64EncodedString()
    }

    static func encodeAESHexUpper(key: Data, plaintext: String) throws -> String {
        let ct = try aesCBCCrypt(Data(plaintext.utf8), key: key, iv: zeroIV, encrypt: true)
        return ct.map { String(format: "%02X", $0) }.joined()
    }

    static func decodeAES(key: Data, base64: String) throws -> String {
        let data = try decodeAESData(key: key, base64: base64)
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeAESData(key: Data, base64: String) throws -> Data {
        let trimmed = base64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters) else {
            throw ZaloCryptoError.invalidBase64
        }
        return try aesCBCCrypt(raw, key: key, iv: zeroIV, encrypt: false)
    }

    static func aesCBCCrypt(_ input: Data, key: Data, iv: Data = zeroIV, encrypt: Bool) throws -> Data {
        guard key.count == 16 || key.count == 32 else { throw ZaloCryptoError.invalidKeyLength(key.count) }
        guard iv.count == kCCBlockSizeAES128 else { throw ZaloCryptoError.cipherFailed(Int32(kCCParamError)) }
        if !encrypt {
            guard !input.isEmpty, input.count % kCCBlockSizeAES128 == 0 else {
                throw ZaloCryptoError.invalidPadding
            }
            // Decrypt with NoPadding then verify strict PKCS#7 to match OpenSSL / Node.
            var out = Data(count: input.count)
            var moved = 0
            let status = out.withUnsafeMutableBytes { o in
                input.withUnsafeBytes { i in
                    key.withUnsafeBytes { k in
                        iv.withUnsafeBytes { v in
                            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                    CCOptions(0), k.baseAddress, key.count, v.baseAddress,
                                    i.baseAddress, input.count, o.baseAddress, input.count, &moved)
                        }
                    }
                }
            }
            guard status == kCCSuccess, moved == input.count else {
                throw ZaloCryptoError.cipherFailed(status)
            }
            guard let pad = out.last, (1...kCCBlockSizeAES128).contains(Int(pad)),
                  out.suffix(Int(pad)).allSatisfy({ $0 == pad }) else {
                throw ZaloCryptoError.invalidPadding
            }
            return out.prefix(out.count - Int(pad))
        } else {
            var out = Data(count: input.count + kCCBlockSizeAES128)
            var moved = 0
            let capacity = out.count
            let status = out.withUnsafeMutableBytes { o in
                input.withUnsafeBytes { i in
                    key.withUnsafeBytes { k in
                        iv.withUnsafeBytes { v in
                            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                                    CCOptions(kCCOptionPKCS7Padding), k.baseAddress, key.count, v.baseAddress,
                                    i.baseAddress, input.count, o.baseAddress, capacity, &moved)
                        }
                    }
                }
            }
            guard status == kCCSuccess else { throw ZaloCryptoError.cipherFailed(status) }
            return out.prefix(moved)
        }
    }

    /// Parses `zpw_enk`: 16/32 raw ASCII bytes directly, or Base64 decoding to 16/32 bytes.
    static func parseSecretKey(_ zpwEnk: String) -> Data {
        let trimmed = zpwEnk.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.utf8.count == 16 || trimmed.utf8.count == 32 {
            return Data(trimmed.utf8)
        }
        if let decoded = Data(base64Encoded: trimmed), decoded.count == 16 || decoded.count == 32 {
            return decoded
        }
        return Data(trimmed.utf8)
    }

    static func decodeCloudKey(_ base64Key: String) throws -> Data {
        let trimmed = base64Key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters) else {
            throw ZaloCryptoError.invalidBase64
        }
        guard key.count == 16 || key.count == 32 else {
            throw ZaloCryptoError.invalidKeyLength(key.count)
        }
        return key
    }

    /// Encrypts zCloud payloads using AES-CBC (PKCS#7) with a random 16-byte IV prepended (`IV || ciphertext`).
    static func encodeCloudAES(base64Key: String, plaintext: String) throws -> String {
        let key = try decodeCloudKey(base64Key)
        var ivBytes = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        let status = SecRandomCopyBytes(kSecRandomDefault, ivBytes.count, &ivBytes)
        guard status == errSecSuccess else {
            throw ZaloCryptoError.cipherFailed(status)
        }
        let iv = Data(ivBytes)
        let cipher = try aesCBCCrypt(Data(plaintext.utf8), key: key, iv: iv, encrypt: true)
        return (iv + cipher).base64EncodedString()
    }

    /// Decrypts zCloud AES-CBC Base64 payloads where the first 16 bytes are the random IV.
    static func decodeCloudAES(base64Key: String, base64Cipher: String) throws -> String {
        let key = try decodeCloudKey(base64Key)
        let trimmed = base64Cipher.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters) else {
            throw ZaloCryptoError.invalidBase64
        }
        guard raw.count > kCCBlockSizeAES128 else {
            throw ZaloCryptoError.invalidPadding
        }
        let iv = Data(raw.prefix(kCCBlockSizeAES128))
        let cipher = Data(raw.dropFirst(kCCBlockSizeAES128))
        let plain = try aesCBCCrypt(cipher, key: key, iv: iv, encrypt: false)
        return String(decoding: plain, as: UTF8.self)
    }

    // MARK: Signkey & PasswordCipher

    /// `getSignKey(tag, params)` = `md5("zsecure" + tag + sortedKeys.map { params[k] }.joined())`.
    static func signKey(tag: String, params: [String: String]) -> String {
        let sorted = params.keys.sorted()
        var buffer = "zsecure" + tag
        for key in sorted {
            buffer.append(params[key] ?? "")
        }
        return md5Hex(buffer)
    }

    static func encryptPassword(phone: String, imei: String, password: String, salt: String) throws -> String {
        let hex = Array(sha256HexUpper("\(passwordKeyPrefix)-\(phone)-\(imei)-\(salt)"))
        let even = stride(from: 0, to: hex.count, by: 2).map { hex[$0] }
        let odd = stride(from: 1, to: hex.count, by: 2).map { hex[$0] }
        let enk = String(even.prefix(16)) + String(odd.reversed().prefix(16))
        let plain = salt + String(password.reversed())
        return try encodeAES(key: Data(enk.utf8), plaintext: plain)
    }

    // MARK: ParamCipher v2

    struct ParamCipher: Sendable {
        let zcid: String
        let zcidExt: String
        let encryptKey: String

        init(apiType: String, imei: String, firstLaunchTimeMs: Int64) throws {
            let plain = "\(apiType),\(imei),\(firstLaunchTimeMs)"
            self.zcid = try ZaloCrypto.encodeAESHexUpper(key: ZaloCrypto.paramCipherKey, plaintext: plain)
            self.zcidExt = ZaloCrypto.randomHex(10)

            let md5Upper = Array(ZaloCrypto.md5Hex(zcidExt).uppercased())
            let zcidChars = Array(zcid)
            let nEven = stride(from: 0, to: md5Upper.count, by: 2).map { md5Upper[$0] }
            let aEven = stride(from: 0, to: zcidChars.count, by: 2).map { zcidChars[$0] }
            let aOdd = stride(from: 1, to: zcidChars.count, by: 2).map { zcidChars[$0] }

            self.encryptKey = String(nEven.prefix(8))
                + String(aEven.prefix(12))
                + String(aOdd.reversed().prefix(12))
        }

        var keyData: Data { Data(encryptKey.utf8) }

        func encryptPayload(_ payloadJSON: String) throws -> String {
            try ZaloCrypto.encodeAES(key: keyData, plaintext: payloadJSON)
        }

        func encryptPayload(_ payload: [String: Any]) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [])
            return try encryptPayload(String(decoding: data, as: UTF8.self))
        }

        func buildSignedParams(apiType: String, clientVersion: String, payload: [String: Any], tag: String) throws -> [String: String] {
            let encrypted = try encryptPayload(payload)
            var map: [String: String] = [
                "zcid": zcid,
                "zcid_ext": zcidExt,
                "enc_ver": "v2",
                "params": encrypted,
                "type": apiType,
                "client_version": clientVersion,
            ]
            map["signkey"] = ZaloCrypto.signKey(tag: tag, params: map)
            return map
        }
    }

    // MARK: WebSocket AES-GCM + Zlib/Gzip

    static func percentDecode(_ s: String) -> String {
        let bytes = Array(s.utf8)
        var out = Data()
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x25, i + 2 < bytes.count,
               let hi = hexNibble(bytes[i + 1]), let lo = hexNibble(bytes[i + 2]) {
                out.append((hi << 4) | lo)
                i += 3
                continue
            }
            out.append(bytes[i])
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 97...102: return byte - 87
        case 65...70: return byte - 55
        default: return nil
        }
    }

    static func inflateZlibOrGzip(_ data: Data, maxBytes: Int = 64 * 1024 * 1024) throws -> Data {
        guard !data.isEmpty else { return Data() }
        // windowBits 47 enables automatic gzip + zlib header detection; -15 is raw deflate.
        for windowBits: Int32 in [47, -15] {
            if let inflated = try? inflate(data, windowBits: windowBits, maxBytes: maxBytes), !inflated.isEmpty {
                return inflated
            }
        }
        throw ZaloCryptoError.inflateFailed
    }

    private static func inflate(_ input: Data, windowBits: Int32, maxBytes: Int) throws -> Data {
        var capacity = min(maxBytes, max(65_536, input.count * 8))
        while true {
            var output = Data(count: capacity)
            var stream = z_stream()
            guard inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw ZaloCryptoError.inflateFailed
            }
            let status: Int32 = output.withUnsafeMutableBytes { dst in
                input.withUnsafeBytes { src in
                    stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: UInt8.self).baseAddress)
                    stream.avail_in = uInt(input.count)
                    stream.next_out = dst.bindMemory(to: UInt8.self).baseAddress
                    stream.avail_out = uInt(capacity)
                    return zlib.inflate(&stream, Z_FINISH)
                }
            }
            let totalOut = Int(stream.total_out)
            let needsMore = stream.avail_out == 0 && (status == Z_BUF_ERROR || status == Z_OK)
            inflateEnd(&stream)
            if status == Z_STREAM_END {
                output.count = totalOut
                return output
            }
            if !needsMore || capacity >= maxBytes {
                throw ZaloCryptoError.inflateFailed
            }
            capacity = min(maxBytes, capacity * 2)
        }
    }

    /// AES-GCM with 16-byte nonce: `iv(16) | aad(16) | ciphertext || tag(16)`.
    static func gcmDecrypt16(key: Data, blob: Data) throws -> Data {
        guard blob.count >= 48 else { throw ZaloCryptoError.invalidGCMBlob(blob.count) }
        let iv = blob.prefix(16)
        let aad = blob.dropFirst(16).prefix(16)
        let cipherAndTag = blob.dropFirst(32)
        let ct = cipherAndTag.dropLast(16)
        let tag = cipherAndTag.suffix(16)
        let nonce = try AES.GCM.Nonce(data: iv)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
    }

    static func gcmEncrypt16(key: Data, plaintext: Data, iv: Data, aad: Data) throws -> Data {
        guard iv.count == 16, aad.count == 16 else { throw ZaloCryptoError.invalidGCMBlob(iv.count) }
        let nonce = try AES.GCM.Nonce(data: iv)
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: nonce, authenticating: aad)
        return iv + aad + sealed.ciphertext + sealed.tag
    }

    static func decryptWSFrame(cipherKey: Data?, encrypt: UInt8, dataField: String) throws -> Data {
        switch encrypt {
        case 0:
            return Data(dataField.utf8)
        case 1:
            guard let raw = Data(base64Encoded: dataField, options: .ignoreUnknownCharacters) else {
                throw ZaloCryptoError.invalidBase64
            }
            return try inflateZlibOrGzip(raw)
        case 2:
            guard let key = cipherKey, !key.isEmpty else { throw ZaloCryptoError.missingCipherKey }
            let decoded = percentDecode(dataField)
            guard let raw = Data(base64Encoded: decoded, options: .ignoreUnknownCharacters) else {
                throw ZaloCryptoError.invalidBase64
            }
            let plain = try gcmDecrypt16(key: key, blob: raw)
            return try inflateZlibOrGzip(plain)
        case 3:
            guard let key = cipherKey, !key.isEmpty else { throw ZaloCryptoError.missingCipherKey }
            let decoded = percentDecode(dataField)
            guard let raw = Data(base64Encoded: decoded, options: .ignoreUnknownCharacters) else {
                throw ZaloCryptoError.invalidBase64
            }
            return try gcmDecrypt16(key: key, blob: raw)
        default:
            throw ZaloCryptoError.unsupportedEncryption(encrypt)
        }
    }

    // MARK: QR PNG Rendering

    static func generateQRPNG(payload: String, size: CGFloat = 280) -> Data? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator"),
              let payloadData = payload.data(using: .utf8) else { return nil }
        filter.setValue(payloadData, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let extent = output.extent.integral
        let quietModules: CGFloat = 4
        let totalModules = max(extent.width, extent.height) + quietModules * 2
        let scale = max(4, floor(size / max(1, totalModules)))
        let side = Int(totalModules * scale)
        let pad = Int(quietModules * scale)

        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.interpolationQuality = .none
        ctx.draw(cgImage, in: CGRect(x: pad, y: pad, width: side - pad * 2, height: side - pad * 2))
        guard let finalImage = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: finalImage).representation(using: .png, properties: [:])
    }
}

// MARK: - Lossless JSON Parsing (preserves > 53-bit Zalo numeric IDs)

enum JSONLossless {
    /// Parses JSON `Data` into Foundation objects while converting any bare integer literal of 15+ digits
    /// (outside string quotes) into a JSON string so 64-bit Zalo IDs never suffer IEEE-754 rounding.
    static func parseObject(_ data: Data) -> [String: Any]? {
        let safeData = quoteLargeIntegerLiterals(in: data)
        return (try? JSONSerialization.jsonObject(with: safeData, options: [.fragmentsAllowed])) as? [String: Any]
    }

    static func parseAny(_ data: Data) -> Any? {
        let safeData = quoteLargeIntegerLiterals(in: data)
        return try? JSONSerialization.jsonObject(with: safeData, options: [.fragmentsAllowed])
    }

    static func parseObject(string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return parseObject(data)
    }

    static func quoteLargeIntegerLiterals(in data: Data) -> Data {
        let bytes = [UInt8](data)
        var out = Data()
        out.reserveCapacity(bytes.count + 64)
        var i = 0
        var inString = false
        var escaped = false

        while i < bytes.count {
            let b = bytes[i]
            if inString {
                out.append(b)
                if escaped {
                    escaped = false
                } else if b == 0x5C { // '\'
                    escaped = true
                } else if b == 0x22 { // '"'
                    inString = false
                }
                i += 1
                continue
            }

            if b == 0x22 { // '"'
                inString = true
                out.append(b)
                i += 1
                continue
            }

            // Detect start of integer literal (optional '-' followed by >= 15 ASCII digits, not preceded/followed by '.')
            let isDigit = (0x30...0x39).contains(b)
            let prevByte = i > 0 ? bytes[i - 1] : 0
            if isDigit && !isNumberContinuation(prevByte) {
                var end = i
                while end < bytes.count && (0x30...0x39).contains(bytes[end]) { end += 1 }
                let nextByte = end < bytes.count ? bytes[end] : 0
                let len = end - i
                if len >= 15 && nextByte != 0x2E && nextByte != 0x65 && nextByte != 0x45 {
                    out.append(0x22)
                    out.append(contentsOf: bytes[i..<end])
                    out.append(0x22)
                    i = end
                    continue
                }
            }

            out.append(b)
            i += 1
        }
        return out
    }

    private static func isNumberContinuation(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || byte == 0x2E || byte == 0x65 || byte == 0x45 || byte == 0x2D
    }

    static func string(_ value: Any?) -> String {
        switch value {
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        default: return ""
        }
    }

    static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let n as NSNumber: return n.int64Value
        case let s as String: return Int64(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let b as Bool: return b
        case let n as NSNumber: return n.intValue != 0
        case let s as String:
            let lower = s.lowercased()
            if lower == "true" || lower == "1" { return true }
            if lower == "false" || lower == "0" { return false }
            return nil
        default: return nil
        }
    }
}
