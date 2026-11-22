import CommonCrypto
import CryptoKit
import Foundation
import Security

struct KeychainSupportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension Array where Element == Any {
    func string(_ i: Int) -> String? { i < count ? self[i] as? String : nil }
    func dict(_ i: Int) -> [String: Any]? { i < count ? self[i] as? [String: Any] : nil }
    func int(_ i: Int) -> Int? { i < count ? (self[i] as? NSNumber)?.intValue : nil }
    func bool(_ i: Int) -> Bool? { i < count ? (self[i] as? NSNumber)?.boolValue : nil }
    func data(_ i: Int) -> Data? {
        guard i < count else { return nil }
        if let d = self[i] as? Data { return d }
        if let s = self[i] as? String { return Data(s.utf8) }
        return nil
    }
}

// MARK: - zsafe-storage (main `tGN0`)

/// String vault backed by `<userData>/zsafe-storage.json`: values at `zsskd.<key>`,
/// AES-256-CBC with main's fixed key/IV (cipher version `zsskv = "2"`).
@MainActor
struct SafeStorage {
    let platform: ZaloPlatform
    private static let key = Data("d9c07b9de9915af401607d3f360211ac".utf8)
    private static let iv = Data([155, 72, 37, 195, 9, 217, 80, 42, 145, 102, 171, 75, 214, 176, 134, 18])

    func execute(_ method: String, _ args: [Any]) throws -> Any? {
        switch method {
        case "encryptString": return try encrypt(args.string(0) ?? "")
        case "decryptString": return try decrypt(args.string(0) ?? "")
        case "get":
            guard let key = args.string(0), !key.contains(".") else { return nil }
            let store = platform.readStore("zsafe-storage")
            guard let sealed = (store["zsskd"] as? [String: Any])?[key] as? String else { return nil }
            return try? decrypt(sealed)
        case "set":
            guard let key = args.string(0), !key.contains(".") else { return nil }
            var store = platform.readStore("zsafe-storage")
            var values = store["zsskd"] as? [String: Any] ?? [:]
            if let value = args.string(1) { values[key] = try encrypt(value) } else { values.removeValue(forKey: key) }
            store["zsskd"] = values
            store["zsskv"] = "2"
            try platform.writeStore("zsafe-storage", store)
            return nil
        default:
            throw KeychainSupportError(message: "zsafestorage: unknown method \(method)")
        }
    }

    private func encrypt(_ plain: String) throws -> String {
        try AESCBC.crypt(Data(plain.utf8), key: Self.key, iv: Self.iv, encrypt: true).base64EncodedString()
    }

    private func decrypt(_ sealed: String) throws -> String {
        let data = try AESCBC.crypt(Data(base64Encoded: sealed) ?? Data(), key: Self.key, iv: Self.iv, encrypt: false)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Keychain cipher (HKDF-SHA256 + AES-256-CBC + HMAC-SHA256)

/// Seals sensitive secrets using a 32-byte root key stored in the macOS Keychain.
/// Each sealed item is `[0x49][iv16][salt16][ct][hmac32]` with HKDF-SHA256(root, salt, "ZprotocolSecureKDF").
struct KeychainCipher: Sendable {
    private static let info = Data("ZprotocolSecureKDF".utf8)
    private static let typeRaw: UInt8 = 0x49

    init(platform: ZaloPlatform? = nil) {}

    func encrypt(identifier: String, items: [Data]) throws -> [Data] {
        let root = try rootKey(identifier, create: true)
        return try items.map { plain in
            let salt = Self.random(16), iv = Self.random(16)
            let (enc, mac) = Self.derive(root, salt)
            let ct = try AESCBC.crypt(plain, key: enc, iv: iv, encrypt: true)
            let tag = Data(HMAC<SHA256>.authenticationCode(for: ct + iv + salt, using: SymmetricKey(data: mac)))
            return Data([Self.typeRaw]) + iv + salt + ct + tag
        }
    }

    func decrypt(identifier: String, items: [Data]) throws -> [Data] {
        let root = try rootKey(identifier, create: false)
        return try items.map { sealed in
            guard sealed.count >= 65 else { throw KeychainSupportError(message: "Invalid encrypted data length") }
            let bytes = [UInt8](sealed)
            let iv = Data(bytes[1..<17]), salt = Data(bytes[17..<33])
            let ct = Data(bytes[33..<(bytes.count - 32)]), tag = Data(bytes.suffix(32))
            let (enc, mac) = Self.derive(root, salt)
            guard HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: ct + iv + salt, using: SymmetricKey(data: mac)) else {
                throw KeychainSupportError(message: "Invalid MAC")
            }
            return try AESCBC.crypt(ct, key: enc, iv: iv, encrypt: false)
        }
    }

    private static func derive(_ root: Data, _ salt: Data) -> (Data, Data) {
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: root), salt: salt, info: info, outputByteCount: 64)
        let bytes = okm.withUnsafeBytes { Data($0) }
        return (bytes.prefix(32), bytes.suffix(32))
    }

    private static func random(_ n: Int) -> Data {
        var data = Data(count: n)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        return data
    }

    private func rootKey(_ identifier: String, create: Bool) throws -> Data {
        let account = "zprotocol.\(identifier.lowercased())"
        switch Keychain.read(account: account) {
        case .found(let existing): return existing
        case .failed(let status): throw KeychainSupportError(message: "Keychain read failed (\(status))")
        case .notFound: break
        }
        guard create else { throw KeychainSupportError(message: "No secret for \(identifier)") }
        let key = Self.random(32)
        try Keychain.write(account: account, data: key)
        return key
    }
}

enum Keychain {
    static let service = "app.olaz.secure"
    static let legacyService = "dev.swiftzalo.secure"

    enum Lookup {
        case found(Data)
        case notFound
        case failed(OSStatus)
    }

    static func read(account: String) -> Lookup {
        let current = read(account: account, service: service)
        guard case .notFound = current else { return current }
        let legacy = read(account: account, service: legacyService)
        if case .found(let data) = legacy { try? write(account: account, data: data) }
        return legacy
    }

    private static func read(account: String, service: String) -> Lookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return (result as? Data).map(Lookup.found) ?? .failed(errSecDecode)
        case errSecItemNotFound: return .notFound
        default: return .failed(status)
        }
    }

    static func write(account: String, data: Data) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainSupportError(message: "Keychain write failed (\(status))") }
    }

    static func deleteAll() {
        for service in [service, legacyService] {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        }
    }
}

enum AESCBC {
    static func crypt(_ input: Data, key: Data, iv: Data, encrypt: Bool) throws -> Data {
        var out = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { o in
            input.withUnsafeBytes { i in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding), k.baseAddress, key.count, v.baseAddress,
                                i.baseAddress, input.count, o.baseAddress, outCount, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw KeychainSupportError(message: "bad decrypt") }
        return out.prefix(moved)
    }
}
