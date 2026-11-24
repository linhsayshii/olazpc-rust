import CryptoKit
import Foundation
import OlazCore
import Security

enum ZaloSessionStatus: Equatable, Sendable {
    case valid
    case expired
    case unreachable
}

struct ZaloSessionError: LocalizedError, Sendable {
    let code: Int
    let message: String
    let url: String

    static let authErrorCodes: Set<Int> = [600, -102]

    var isAuthError: Bool { Self.authErrorCodes.contains(code) }

    var errorDescription: String? {
        if url.isEmpty {
            return "Zalo error \(code): \(message)"
        }
        return "Zalo error \(code): \(message) (\(url))"
    }
}

enum ZaloTransportError: LocalizedError, Sendable {
    case notAuthenticated
    case invalidURL(String)
    case httpError(Int, String)
    case invalidJSON
    case qrFailed(String)
    case qrTimeout
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: "Chưa đăng nhập Zalo."
        case .invalidURL(let raw): "URL không hợp lệ: \(raw)"
        case .httpError(let status, _): "Lỗi máy chủ HTTP \(status)."
        case .invalidJSON: "Phản hồi máy chủ không đúng định dạng."
        case .qrFailed(let msg): msg
        case .qrTimeout: "Mã QR đã hết hạn."
        case .cancelled: "Đã hủy."
        }
    }
}

struct ZaloQRTicket: Sendable {
    var tokenId: String
    var qrPayload: String
    var base64PNG: String?
    var pngData: Data?
    var chkWaitScan: String
    var chkWaitCfirm: String
    var qrTimeoutSeconds: Int
    var qrRetry: Int
}

struct ZaloLoginAccount: Codable, Equatable, Sendable {
    var userId: String = ""
    var displayName: String = ""
    var avatar: String = ""
    var phone: String = ""
    var send2MeId: String = ""
    var dkey: String = ""
    var zpwEnk: String = ""
    var zpwSek: String = ""
    var needSyncMsg: Bool?
}

private struct StoredNativeSession: Codable {
    var zpwType: String?
    var imei: String
    var computerName: String
    var domains: ZaloDomains
    var sealedSecretsBase64: String?
    var plainAccount: ZaloLoginAccount?
    var expiredAt: TimeInterval?
}

actor ZaloSessionClient {
    let dataDirectory: URL
    private let useKeychain: Bool
    /// Rust chat path (ADR-011). Swift stays the owner of Keychain persistence; the core session mirrors our state.
    private var coreSession: CoreSession?
    private var coreApiHandle: CoreApi?
    private var coreHttpHandle: CoreHttp?
    private var coreRawHandle: CoreRawHttp?
    private var corePushedSnapshot = ""
    /// True once `CoreEngine` owns the shared `CoreSession` (ADR-016). While owned, Swift reads
    /// from the shared `CoreSession` instead of overwriting it from Swift fields.
    private var coreOwned = false

    var domains = ZaloDomains()
    var imei: String
    var computerName: String
    var secretKey: Data?
    var zpwSek: String?
    var account: ZaloLoginAccount?
    var expiredAt: TimeInterval?
    var archivedVersion: Int64 = 0
    var labelVersion: Int64 = 0
    var cachedStickerCategories: [[String: Any]]?
    var globalIdToUidCache: [String: String] = [:]
    var uidToGlobalIdCache: [String: String] = [:]
    var cloudViewerKey: String?
    var cloudEnk: String?

    private var serverSelfG: Int = 0
    private var serverQrForm: Int = 0
    private var needsPCTypeUpgrade: Bool = false
    private var lastClientIdMs: Int64 = 0
    private var sessionTrace: (@MainActor @Sendable (String) -> Bool)?

    private static let keychainIdentifier = "olaz.native.session"
    private static let imeiDefaultsKey = "olaz.native.pc.imei"

    init(
        dataDirectory: URL = ZaloPlatform.defaultUserData,
        useKeychain: Bool = true,
        domains: ZaloDomains = ZaloDomains()
    ) {
        self.dataDirectory = dataDirectory
        self.useKeychain = useKeychain
        self.domains = domains
        self.computerName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

        let expectedSuffix = ZaloCrypto.md5Hex(ZaloDomains.userAgent)
        let storedIMEI = UserDefaults.standard.string(forKey: Self.imeiDefaultsKey)
        if let storedIMEI, storedIMEI.count == 69, storedIMEI.hasSuffix(expectedSuffix) {
            self.imei = storedIMEI
        } else {
            let fresh = Self.generateIMEI()
            UserDefaults.standard.set(fresh, forKey: Self.imeiDefaultsKey)
            self.imei = fresh
        }
    }

    static func generateIMEI() -> String {
        let uuid = UUID().uuidString.lowercased()
        let uaMD5 = ZaloCrypto.md5Hex(ZaloDomains.userAgent)
        return "\(uuid)-\(uaMD5)"
    }

    var isAuthenticated: Bool {
        guard let account, !account.userId.isEmpty,
              let sek = zpwSek, !sek.isEmpty,
              let secretKey, secretKey.count == 16 || secretKey.count == 32 else {
            return false
        }
        return true
    }

    var sessionFileURL: URL {
        dataDirectory.appendingPathComponent("native-session.json")
    }

    private var vaultKeyURL: URL {
        dataDirectory.appendingPathComponent(".session-vault.key")
    }

    private static let vaultMagic: UInt8 = 0x4A
    private static let vaultInfo = Data("OlazLocalVaultKDF".utf8)

    private func loadOrCreateVaultKey(create: Bool) throws -> Data {
        if let existing = try? Data(contentsOf: vaultKeyURL), existing.count == 32 {
            return existing
        }
        guard create else { throw ZaloTransportError.notAuthenticated }
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw ZaloTransportError.notAuthenticated }
        try key.write(to: vaultKeyURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vaultKeyURL.path)
        return key
    }

    private func sealWithVaultKey(_ plain: Data) throws -> Data {
        let root = try loadOrCreateVaultKey(create: true)
        var iv = Data(count: 16)
        var salt = Data(count: 16)
        _ = iv.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: root), salt: salt, info: Self.vaultInfo, outputByteCount: 64)
        let okmBytes = okm.withUnsafeBytes { Data($0) }
        let enc = okmBytes.prefix(32)
        let mac = okmBytes.suffix(32)
        let ct = try AESCBC.crypt(plain, key: enc, iv: iv, encrypt: true)
        let tag = Data(HMAC<SHA256>.authenticationCode(for: ct + iv + salt, using: SymmetricKey(data: mac)))
        return Data([Self.vaultMagic]) + iv + salt + ct + tag
    }

    private func unsealWithVaultKey(_ sealed: Data) -> Data? {
        guard sealed.count >= 65, sealed.first == Self.vaultMagic,
              let root = try? loadOrCreateVaultKey(create: false) else {
            return nil
        }
        let bytes = [UInt8](sealed)
        let iv = Data(bytes[1..<17])
        let salt = Data(bytes[17..<33])
        let ct = Data(bytes[33..<(bytes.count - 32)])
        let tag = Data(bytes.suffix(32))
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: root), salt: salt, info: Self.vaultInfo, outputByteCount: 64)
        let okmBytes = okm.withUnsafeBytes { Data($0) }
        let enc = okmBytes.prefix(32)
        let mac = okmBytes.suffix(32)
        guard HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: ct + iv + salt, using: SymmetricKey(data: mac)) else {
            return nil
        }
        return try? AESCBC.crypt(ct, key: enc, iv: iv, encrypt: false)
    }

    /// The `CoreApi` over a `CoreSession` restored from our live state, or `nil` (Swift path, or no usable session).
    /// The snapshot is rebuilt from the current fields and pushed only when it changed, so credential / domain updates
    /// made anywhere in this class (login, `applyLoginConfig`, `updateCredentials`, `markExpired`) reach the core on
    /// the next call. The account is carried in the clear inside the in-memory snapshot only; Rust never persists it.
    func coreApi() -> CoreApi? {
        syncCoreSession() ? coreApiHandle : nil
    }

    /// The generic signed-request seam (`get` / `post` / `postMultipart`) over the same core session as `coreApi()`.
    func coreHttp() -> CoreHttp? {
        syncCoreSession() ? coreHttpHandle : nil
    }

    /// The session-free raw HTTP seam (`rawRequest`, downloads). It needs no account: the QR
    /// login flow uses it before one exists, and Swift passes its own `zpwSek` on every call so there is one owner.
    private func coreRaw() throws -> CoreRawHttp {
        if let coreRawHandle { return coreRawHandle }
        do {
            let created = try CoreRawHttp()
            coreRawHandle = created
            return created
        } catch {
            throw RustCore.mapError(error)
        }
    }

    /// Returns the single shared `CoreSession` owned by `CoreEngine` (ADR-016), creating it with
    /// this client's IMEI, computer name, and any non-default domains if needed.
    func sharedCoreSession() -> CoreSession? {
        if let existing = coreSession {
            if !coreOwned {
                _ = syncCoreSession()
            }
            coreOwned = true
            return existing
        }
        let customDomainsJSON: String? = {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let current = try? encoder.encode(domains),
                  let defaults = try? encoder.encode(ZaloDomains()),
                  current != defaults else {
                return nil
            }
            return String(data: current, encoding: .utf8)
        }()
        guard let created = try? CoreSession.withConfig(
            imei: imei,
            computerName: computerName,
            domainsJson: customDomainsJSON
        ) else {
            return nil
        }
        coreSession = created
        coreApiHandle = CoreApi(session: created)
        coreHttpHandle = CoreHttp(session: created)
        coreOwned = true
        corePushedSnapshot = ""
        if let account {
            let snapshot = StoredNativeSession(
                zpwType: ZaloDomains.zpwType,
                imei: imei,
                computerName: computerName,
                domains: domains,
                sealedSecretsBase64: nil,
                plainAccount: account,
                expiredAt: expiredAt
            )
            if let data = try? JSONEncoder().encode(snapshot),
               let json = String(data: data, encoding: .utf8) {
                _ = try? created.restore(snapshotJson: json)
            }
        }
        return created
    }

    /// Creates the core session on first use and pushes our current state into it when it changed.
    private func syncCoreSession() -> Bool {
        if coreOwned {
            guard let coreSession else { return false }
            return coreSession.isAuthenticated()
        }
        guard let account else { return false }
        let snapshot = StoredNativeSession(
            zpwType: ZaloDomains.zpwType,
            imei: imei,
            computerName: computerName,
            domains: domains,
            sealedSecretsBase64: nil,
            plainAccount: account,
            expiredAt: expiredAt
        )
        guard let data = try? JSONEncoder().encode(snapshot), let json = String(data: data, encoding: .utf8) else { return false }
        if coreSession == nil {
            guard let created = try? CoreSession(computerName: computerName) else { return false }
            coreSession = created
            coreApiHandle = CoreApi(session: created)
            coreHttpHandle = CoreHttp(session: created)
            corePushedSnapshot = ""
        }
        guard let coreSession else { return false }
        if json != corePushedSnapshot {
            guard (try? coreSession.restore(snapshotJson: json)) == true else { return false }
            corePushedSnapshot = json
        }
        return true
    }

    func commonParams() -> String {
        "zpw_ver=\(ZaloDomains.zpwVer)&zpw_type=\(ZaloDomains.zpwType)"
    }

    func nextClientId() -> Int64 {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let next = now > lastClientIdMs ? now : (lastClientIdMs + 1)
        lastClientIdMs = next
        return next
    }

    func updateCredentials(account: ZaloLoginAccount, secretKey: Data, zpwSek: String, domains: ZaloDomains? = nil) {
        var updated = account
        if updated.zpwSek.isEmpty && !zpwSek.isEmpty {
            updated.zpwSek = zpwSek
        }
        if updated.zpwEnk.isEmpty && (secretKey.count == 16 || secretKey.count == 32) {
            updated.zpwEnk = secretKey.base64EncodedString()
        }
        self.account = updated
        self.secretKey = secretKey
        self.zpwSek = zpwSek
        if let domains { self.domains = domains }
        self.expiredAt = nil
        self.cloudViewerKey = nil
        self.cloudEnk = nil
        if coreOwned, let coreSession {
            let snapshot = StoredNativeSession(
                zpwType: ZaloDomains.zpwType,
                imei: imei,
                computerName: computerName,
                domains: self.domains,
                sealedSecretsBase64: nil,
                plainAccount: updated,
                expiredAt: nil
            )
            if let data = try? JSONEncoder().encode(snapshot),
               let json = String(data: data, encoding: .utf8) {
                _ = try? coreSession.restore(snapshotJson: json)
            }
        }
    }

    func seedGlobalIdMappings(_ map: [String: String]) {
        for (gid, uid) in map where !gid.isEmpty && !uid.isEmpty {
            globalIdToUidCache[gid] = uid
            uidToGlobalIdCache[uid] = gid
        }
    }

    func exportedGlobalIdMappings() -> [String: String] {
        globalIdToUidCache
    }

    // MARK: CoreHost Persistence & Mirror (ADR-016)

    /// Reads `native-session.json` and unseals any vault/Keychain account into `plainAccount`
    /// so `CoreEngine` can restore it into the shared `CoreSession`. Never logs credentials.
    func readSavedSessionSnapshotJSON() -> String? {
        guard let data = try? Data(contentsOf: sessionFileURL),
              var stored = try? JSONDecoder().decode(StoredNativeSession.self, from: data) else {
            return nil
        }
        if let sealedB64 = stored.sealedSecretsBase64,
           let sealedData = Data(base64Encoded: sealedB64) {
            var loadedAccount: ZaloLoginAccount?
            if sealedData.first == Self.vaultMagic,
               let unsealed = unsealWithVaultKey(sealedData),
               let decoded = try? JSONDecoder().decode(ZaloLoginAccount.self, from: unsealed) {
                loadedAccount = decoded
            } else if sealedData.first == 0x49, useKeychain,
                      let unsealed = try? KeychainCipher().decrypt(identifier: Self.keychainIdentifier, items: [sealedData]).first,
                      let decoded = try? JSONDecoder().decode(ZaloLoginAccount.self, from: unsealed) {
                loadedAccount = decoded
            }
            guard let loadedAccount else { return nil }
            stored.plainAccount = loadedAccount
            stored.sealedSecretsBase64 = nil
        }
        guard let encoded = try? JSONEncoder().encode(stored),
              let json = String(data: encoded, encoding: .utf8) else {
            return nil
        }
        return json
    }

    /// Reads any legacy WKWebView `zpw_sek` cookie and `olaz.imei` default for migration on boot.
    func readLegacyCookie() -> LegacyCookieRecord? {
        guard let authURL = URL(string: domains.auth),
              let sek = HTTPCookieStorage.shared.cookies(for: authURL)?
                .first(where: { $0.name == "zpw_sek" && !$0.value.isEmpty })?.value else {
            return nil
        }
        let legacyIMEI = UserDefaults.standard.string(forKey: "olaz.imei").flatMap { $0.count == 69 ? $0 : nil }
        return LegacyCookieRecord(zpwSek: sek, imei: legacyIMEI)
    }

    /// Persists a `CoreSession` snapshot to `native-session.json` (sealing credentials with the
    /// local vault key when `useKeychain` is true) and refreshes transitional Swift mirror fields.
    func saveSessionFromCore(snapshotJSON: String, writeDisk: Bool = true) {
        guard let raw = snapshotJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(StoredNativeSession.self, from: raw) else {
            return
        }
        applyMirror(from: decoded)
        guard writeDisk else { return }
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            var sealedB64: String?
            var plain: ZaloLoginAccount? = decoded.plainAccount
            if useKeychain, let acc = decoded.plainAccount,
               let encodedAcc = try? JSONEncoder().encode(acc),
               let sealed = try? sealWithVaultKey(encodedAcc) {
                sealedB64 = sealed.base64EncodedString()
                plain = nil
            }
            let stored = StoredNativeSession(
                zpwType: decoded.zpwType ?? ZaloDomains.zpwType,
                imei: decoded.imei,
                computerName: decoded.computerName,
                domains: decoded.domains,
                sealedSecretsBase64: sealedB64,
                plainAccount: plain,
                expiredAt: decoded.expiredAt
            )
            let data = try JSONEncoder().encode(stored)
            try data.write(to: sessionFileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionFileURL.path)
        } catch {
            // File write errors match legacy `try? saveSession()` behavior without logging credentials.
        }
    }

    /// Persists an expired `CoreSession` snapshot (with `expiredAt` already set by Rust).
    func markExpiredFromCore(snapshotJSON: String, persist: Bool = true) {
        saveSessionFromCore(snapshotJSON: snapshotJSON, writeDisk: persist)
    }

    /// Removes persisted session files and cookies and clears transitional Swift mirror fields.
    /// Does not touch `coreSession` (already cleared by `olaz-core`).
    func clearSessionStorage(clearDisk: Bool = true, resetDomains: Bool = true) {
        corePushedSnapshot = ""
        // U17: remove when ZaloAPIService is gone
        account = nil
        zpwSek = nil
        secretKey = nil
        expiredAt = nil
        cloudViewerKey = nil
        cloudEnk = nil
        globalIdToUidCache.removeAll()
        uidToGlobalIdCache.removeAll()
        if resetDomains {
            domains = ZaloDomains()
        }
        if clearDisk {
            try? FileManager.default.removeItem(at: sessionFileURL)
            for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.name == "zpw_sek" {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
    }

    /// Resets the transitional Swift `domains` mirror to default live endpoints.
    func resetDomainsToDefault() {
        domains = ZaloDomains()
    }

    /// Refreshes transitional Swift mirror fields from the shared `CoreSession` snapshot so
    /// Swift-owned feature calls reading `sessionClient.account` / `domains` / `zpwSek` stay current.
    func syncMirrorFromCoreSession() {
        guard let json = try? coreSession?.snapshotJson(),
              let raw = json.data(using: .utf8),
              let stored = try? JSONDecoder().decode(StoredNativeSession.self, from: raw) else {
            return
        }
        applyMirror(from: stored)
    }

    // U17: remove when ZaloAPIService is gone
    private func applyMirror(from stored: StoredNativeSession) {
        if !stored.imei.isEmpty {
            self.imei = stored.imei
        }
        if !stored.computerName.isEmpty {
            self.computerName = stored.computerName
        }
        self.domains = stored.domains
        self.expiredAt = stored.expiredAt
        if let acc = stored.plainAccount {
            self.account = acc
            self.zpwSek = acc.zpwSek.isEmpty ? nil : acc.zpwSek
            let parsed = ZaloCrypto.parseSecretKey(acc.zpwEnk)
            self.secretKey = (parsed.count == 16 || parsed.count == 32) ? parsed : nil
        } else {
            self.account = nil
            self.zpwSek = nil
            self.secretKey = nil
        }
    }

    // MARK: Persistence

    func setSessionTrace(_ trace: (@MainActor @Sendable (String) -> Bool)?) {
        self.sessionTrace = trace
    }

    private func persistSessionIfAllowed() async {
        if let sessionTrace, !(await sessionTrace("persist_session")) {
            return
        }
        try? saveSession()
    }

    func saveSession() throws {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        var sealedB64: String?
        var plain: ZaloLoginAccount? = account
        if useKeychain, let account, let encoded = try? JSONEncoder().encode(account),
           let sealed = try? sealWithVaultKey(encoded) {
            sealedB64 = sealed.base64EncodedString()
            plain = nil
        }
        let stored = StoredNativeSession(
            zpwType: ZaloDomains.zpwType,
            imei: imei,
            computerName: computerName,
            domains: domains,
            sealedSecretsBase64: sealedB64,
            plainAccount: plain,
            expiredAt: expiredAt
        )
        let data = try JSONEncoder().encode(stored)
        try data.write(to: sessionFileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionFileURL.path)
    }

    func loadSavedSession() -> Bool {
        guard let data = try? Data(contentsOf: sessionFileURL),
              let stored = try? JSONDecoder().decode(StoredNativeSession.self, from: data) else {
            return false
        }

        let savedType = stored.zpwType ?? ZaloDomains.zpwWebType
        self.needsPCTypeUpgrade = (savedType != ZaloDomains.zpwType)
        if self.needsPCTypeUpgrade {
            Task { @MainActor in
                EngineLog.shared.write("session: loaded legacy zpw_type=\(savedType), will verify PC zpw_type=\(ZaloDomains.zpwType) compatibility")
            }
            if stored.imei.count == 69 {
                self.imei = stored.imei
            }
        } else {
            let expectedSuffix = ZaloCrypto.md5Hex(ZaloDomains.userAgent)
            if stored.imei.count == 69, stored.imei.hasSuffix(expectedSuffix) {
                self.imei = stored.imei
            }
        }
        if !stored.computerName.isEmpty {
            self.computerName = stored.computerName
        }
        self.domains = stored.domains
        self.domains.healFromVerified()
        self.expiredAt = stored.expiredAt

        var loadedAccount: ZaloLoginAccount?
        if let sealedB64 = stored.sealedSecretsBase64,
           let sealedData = Data(base64Encoded: sealedB64) {
            if sealedData.first == Self.vaultMagic,
               let unsealed = unsealWithVaultKey(sealedData),
               let decoded = try? JSONDecoder().decode(ZaloLoginAccount.self, from: unsealed) {
                loadedAccount = decoded
            } else if sealedData.first == 0x49, useKeychain,
                      let unsealed = try? KeychainCipher().decrypt(identifier: Self.keychainIdentifier, items: [sealedData]).first,
                      let decoded = try? JSONDecoder().decode(ZaloLoginAccount.self, from: unsealed) {
                loadedAccount = decoded
            }
        } else if let plain = stored.plainAccount {
            loadedAccount = plain
        }

        guard let loadedAccount, !loadedAccount.zpwSek.isEmpty, !loadedAccount.zpwEnk.isEmpty else {
            return false
        }
        let key = ZaloCrypto.parseSecretKey(loadedAccount.zpwEnk)
        guard key.count == 16 || key.count == 32 else { return false }

        self.account = loadedAccount
        self.zpwSek = loadedAccount.zpwSek
        self.secretKey = key
        return true
    }

    /// Migrates an existing `zpw_sek` cookie from Olaz's legacy WKWebView/HTTPCookieStorage if present (only if minted for PC `type=23`).
    func tryRestoreLegacyCookieSession() async -> Bool {
        let authURL = URL(string: domains.auth)!
        guard let sek = HTTPCookieStorage.shared.cookies(for: authURL)?.first(where: { $0.name == "zpw_sek" && !$0.value.isEmpty })?.value else {
            return false
        }
        if let legacyIMEI = UserDefaults.standard.string(forKey: "olaz.imei"), legacyIMEI.count == 69 {
            self.imei = legacyIMEI
        }
        self.zpwSek = sek
        do {
            _ = try await completeLogin()
            return isAuthenticated
        } catch {
            self.zpwSek = nil
            self.account = nil
            self.secretKey = nil
            return false
        }
    }

    func markExpired(persist: Bool = true) {
        self.expiredAt = Date().timeIntervalSince1970
        if persist {
            try? saveSession()
        }
    }

    func clearSession(clearDisk: Bool = true, resetDomains: Bool = true) {
        coreSession?.clearSession()
        corePushedSnapshot = ""
        account = nil
        zpwSek = nil
        secretKey = nil
        expiredAt = nil
        cloudViewerKey = nil
        cloudEnk = nil
        globalIdToUidCache.removeAll()
        uidToGlobalIdCache.removeAll()
        if resetDomains {
            domains = ZaloDomains()
        }
        if clearDisk {
            try? FileManager.default.removeItem(at: sessionFileURL)
            for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.name == "zpw_sek" {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
    }

    // MARK: Pre-Login Server Discovery & QR Login Flow (`zpw_type=23`)

    @discardableResult
    func fetchServerInfo() async throws -> [String: Any] {
        var params: [String: String] = [
            "imei": imei,
            "type": ZaloDomains.zpwType,
            "client_version": ZaloDomains.zpwVer,
            "computer_name": computerName,
            "sp_mtn": "-1",
            "bkt": "-1",
        ]
        params["signkey"] = ZaloCrypto.signKey(tag: "getserverinfo", params: params)
        let query = Self.sortedQueryString(params)
        guard let url = URL(string: "\(domains.auth)/api/login/getServerInfo?\(query)") else {
            throw ZaloTransportError.invalidURL("getServerInfo")
        }
        let (status, data, _) = try await rawRequest(method: "GET", url: url)
        guard status == 200, let json = JSONLossless.parseObject(data) else {
            throw ZaloTransportError.httpError(status, "")
        }
        domains.applyServerInfo(json)
        let settings = (json["setttings"] as? [String: Any]) ?? (json["settings"] as? [String: Any])
        if let trusted = settings?["trusted_device"] as? [String: Any] {
            serverQrForm = Int(JSONLossless.int64(trusted["qr_format_trust_device"]) ?? 0)
            serverSelfG = Int(JSONLossless.int64(trusted["self_g"]) ?? 0)
        }
        return json
    }

    func requestQR(language: String = "vi") async throws -> ZaloQRTicket {
        _ = try? await fetchServerInfo()

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let nowSec = nowMs / 1000
        let cipher = try ZaloCrypto.ParamCipher(apiType: ZaloDomains.zpwType, imei: imei, firstLaunchTimeMs: nowMs)
        let payload: [String: Any] = [
            "language": language,
            "client_time": nowSec,
            "imei": imei,
            "computer_name": computerName,
            "logged_uids": "",
            "self_g": serverSelfG,
            "qr_form": serverQrForm,
        ]
        let signed = try cipher.buildSignedParams(
            apiType: ZaloDomains.zpwType,
            clientVersion: ZaloDomains.zpwVer,
            payload: payload,
            tag: "reqqr"
        )
        let query = Self.sortedQueryString(signed)
        guard let url = URL(string: "\(domains.auth)/api/login/reqqr?\(query)") else {
            throw ZaloTransportError.invalidURL("reqqr")
        }
        let (status, data, _) = try await rawRequest(method: "GET", url: url)
        guard status == 200 else {
            throw ZaloTransportError.httpError(status, String(decoding: data.prefix(200), as: UTF8.self))
        }
        guard let rawJSON = JSONLossless.parseObject(data) else {
            throw ZaloTransportError.invalidJSON
        }
        let json = maybeDecrypt(rawJSON, key: cipher.keyData)
        let code = JSONLossless.int64(json["error_code"]).map(Int.init) ?? 0
        if code != 0 {
            let msg = JSONLossless.string(json["error_message"])
            throw ZaloSessionError(code: code, message: msg.isEmpty ? "Không tạo được mã QR" : msg, url: url.path)
        }
        guard let d = json["data"] as? [String: Any] else {
            throw ZaloTransportError.qrFailed("Máy chủ không trả về dữ liệu QR.")
        }
        return try Self.parseQRTicket(from: d)
    }

    private static func parseQRTicket(from d: [String: Any], fallbackCfirm: String = "") throws -> ZaloQRTicket {
        let tokenId = JSONLossless.string(d["token_id"] ?? d["ntk"])
        let qrPayload = JSONLossless.string(d["qr_cnt"])
        let rawBase64 = (d["base64_qr"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let base64PNG: String? = rawBase64.map { b64 in
            if let comma = b64.firstIndex(of: ","), b64.hasPrefix("data:image") {
                return String(b64[b64.index(after: comma)...])
            }
            return b64
        }
        let chkScan = JSONLossless.string(d["chk_wait_scan"])
        let chkCfirmRaw = JSONLossless.string(d["chk_wait_cfirm"])
        let chkCfirm = chkCfirmRaw.isEmpty ? fallbackCfirm : chkCfirmRaw
        let timeout = JSONLossless.int64(d["qr_timeout"]).map(Int.init) ?? 180
        let retry = JSONLossless.int64(d["qr_retry"]).map(Int.init) ?? 3

        guard !chkScan.isEmpty else {
            throw ZaloTransportError.qrFailed("Thiếu endpoint chờ quét QR.")
        }

        var png: Data?
        if let base64PNG, let decoded = Data(base64Encoded: base64PNG, options: [.ignoreUnknownCharacters]) {
            png = decoded
        } else if !qrPayload.isEmpty {
            png = ZaloCrypto.generateQRPNG(payload: qrPayload)
        }
        guard png != nil || !qrPayload.isEmpty else {
            throw ZaloTransportError.qrFailed("Không tạo được ảnh mã QR.")
        }

        return ZaloQRTicket(
            tokenId: tokenId,
            qrPayload: qrPayload,
            base64PNG: base64PNG,
            pngData: png,
            chkWaitScan: chkScan,
            chkWaitCfirm: chkCfirm,
            qrTimeoutSeconds: timeout,
            qrRetry: retry
        )
    }

    func waitForQRScan(
        _ ticket: ZaloQRTicket,
        onTicketRotated: (@Sendable (ZaloQRTicket) async -> Void)? = nil
    ) async throws -> (displayName: String, avatar: URL?, activeTicket: ZaloQRTicket) {
        var current = ticket
        var deadline = Date().addingTimeInterval(TimeInterval(max(60, current.qrTimeoutSeconds * max(1, current.qrRetry))))
        var errorAttempts = 0

        while Date() < deadline {
            try Task.checkCancellation()
            let separator = current.chkWaitScan.contains("?") ? "&" : "?"
            guard let url = URL(string: "\(current.chkWaitScan)\(separator)lang=vi") else {
                throw ZaloTransportError.invalidURL(current.chkWaitScan)
            }
            let reqTimeout = TimeInterval(max(70, current.qrTimeoutSeconds + 12))
            let status: Int
            let data: Data
            do {
                let resp = try await rawRequest(method: "GET", url: url, timeout: reqTimeout)
                status = resp.0
                data = resp.1
            } catch let urlErr as URLError where urlErr.code == .timedOut || urlErr.code == .networkConnectionLost {
                if Date() < deadline {
                    try await Task.sleep(for: .milliseconds(500))
                    continue
                }
                throw ZaloTransportError.qrTimeout
            }

            if status == 408 {
                try await Task.sleep(for: .milliseconds(500))
                continue
            }
            guard status == 200 else {
                throw ZaloTransportError.httpError(status, String(decoding: data.prefix(200), as: UTF8.self))
            }
            if let json = JSONLossless.parseObject(data) {
                let code = JSONLossless.int64(json["error_code"]).map(Int.init) ?? 0
                if code == 0, let d = json["data"] as? [String: Any] {
                    let name = JSONLossless.string(d["display_name"] ?? d["displayName"])
                    let avatarStr = JSONLossless.string(d["avatar"])
                    return (name, avatarStr.isEmpty ? nil : URL(string: avatarStr), current)
                } else if code == -20, let d = json["data"] as? [String: Any],
                          let rotated = try? Self.parseQRTicket(from: d, fallbackCfirm: current.chkWaitCfirm) {
                    // Multi-layer QR verification on untrusted device: rotate to second QR seamlessly.
                    current = rotated
                    deadline = Date().addingTimeInterval(TimeInterval(max(90, rotated.qrTimeoutSeconds * max(1, rotated.qrRetry))))
                    errorAttempts = 0
                    Task { @MainActor in
                        EngineLog.shared.write("login: rotated to multi-layer second QR")
                    }
                    await onTicketRotated?(rotated)
                    continue
                } else if code == 8 || code == 13 || code == -13 {
                    // Long-poll cycle timeout on server; keep polling until overall deadline.
                    try await Task.sleep(for: .milliseconds(500))
                    continue
                } else if code != 0 {
                    errorAttempts += 1
                    if errorAttempts > max(1, current.qrRetry) {
                        let msg = JSONLossless.string(json["error_message"])
                        throw ZaloTransportError.qrFailed(msg.isEmpty ? "Mã QR đã hết hạn (mã \(code))." : msg)
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(600))
        }
        throw ZaloTransportError.qrTimeout
    }

    func waitForQRConfirm(_ ticket: ZaloQRTicket) async throws -> String {
        guard !ticket.chkWaitCfirm.isEmpty, let url = URL(string: ticket.chkWaitCfirm) else {
            throw ZaloTransportError.qrFailed("Thiếu endpoint xác nhận QR.")
        }
        let deadline = Date().addingTimeInterval(TimeInterval(max(120, ticket.qrTimeoutSeconds)))
        let reqTimeout = TimeInterval(max(70, ticket.qrTimeoutSeconds + 12))

        while Date() < deadline {
            try Task.checkCancellation()
            let status: Int
            let data: Data
            let cookieSek: String?
            do {
                let resp = try await rawRequest(method: "GET", url: url, timeout: reqTimeout)
                status = resp.0
                data = resp.1
                cookieSek = resp.2
            } catch let urlErr as URLError where urlErr.code == .timedOut || urlErr.code == .networkConnectionLost {
                if Date() < deadline {
                    try await Task.sleep(for: .milliseconds(500))
                    continue
                }
                throw ZaloTransportError.qrTimeout
            }

            if status == 408 {
                try await Task.sleep(for: .milliseconds(500))
                continue
            }
            guard status == 200 else {
                throw ZaloTransportError.httpError(status, String(decoding: data.prefix(200), as: UTF8.self))
            }
            guard let json = JSONLossless.parseObject(data) else {
                throw ZaloTransportError.invalidJSON
            }
            let code = JSONLossless.int64(json["error_code"]).map(Int.init) ?? 0
            if code == 0 {
                let sek = cookieSek ?? Self.extractZpwSek(from: json)
                guard Self.isValidZpwSek(sek), let sek else {
                    throw ZaloTransportError.qrFailed("Xác nhận QR thành công nhưng thiếu phiên zpw_sek.")
                }
                self.zpwSek = sek
                if let d = json["data"] as? [String: Any] {
                    applyLoginConfig(d)
                }
                return sek
            } else if code == 18012 || code == -13 || code == 13 || code == 8 {
                // Scanned; waiting for user to tap Confirm on phone.
                try await Task.sleep(for: .milliseconds(700))
                continue
            } else {
                let msg = JSONLossless.string(json["error_message"])
                throw ZaloTransportError.qrFailed(msg.isEmpty ? "Đăng nhập bị từ chối (mã \(code))." : msg)
            }
        }
        throw ZaloTransportError.qrTimeout
    }

    func getLoginInfo(zpwType: String = ZaloDomains.zpwType) async throws -> [String: Any] {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let cipher = try ZaloCrypto.ParamCipher(apiType: zpwType, imei: imei, firstLaunchTimeMs: nowMs)
        let payload: [String: Any] = [
            "imei": imei,
            "computer_name": computerName,
            "language": "vi",
            "ts": nowMs,
        ]
        let signed = try cipher.buildSignedParams(
            apiType: zpwType,
            clientVersion: ZaloDomains.zpwVer,
            payload: payload,
            tag: "getlogininfo"
        )
        let query = Self.sortedQueryString(signed)
        var lastError: Error = ZaloTransportError.notAuthenticated

        for host in [domains.auth, domains.wpaChat] {
            guard let url = URL(string: "\(host)/api/login/getLoginInfo?\(query)&nretry=0") else { continue }
            do {
                let (status, data, cookieSek) = try await rawRequest(method: "GET", url: url)
                guard status == 200 else {
                    lastError = ZaloTransportError.httpError(status, "")
                    continue
                }
                guard let raw = JSONLossless.parseObject(data) else {
                    lastError = ZaloTransportError.invalidJSON
                    continue
                }
                let decrypted = maybeDecrypt(raw, key: cipher.keyData)
                let code = JSONLossless.int64(decrypted["error_code"]).map(Int.init) ?? 0
                if code == 0 {
                    if !Self.isValidZpwSek(self.zpwSek), let cookieSek, Self.isValidZpwSek(cookieSek) {
                        self.zpwSek = cookieSek
                    }
                    return decrypted
                }
                lastError = ZaloSessionError(code: code, message: JSONLossless.string(decrypted["error_message"]), url: url.path)
                if ZaloSessionError.authErrorCodes.contains(code) { throw lastError }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func completeLogin() async throws -> ZaloLoginAccount {
        let info = try await getLoginInfo(zpwType: ZaloDomains.zpwType)
        if let cfg = info["data"] as? [String: Any] {
            applyLoginConfig(cfg)
        }
        let sekDots = (zpwSek ?? "").filter { $0 == "." }.count
        let keyLen = secretKey?.count ?? 0
        let wsCount = domains.ws.count
        Task { @MainActor in
            EngineLog.shared.write("login: complete type=\(ZaloDomains.zpwType) key_len=\(keyLen) sek_dots=\(sekDots) ws=\(wsCount)")
        }
        _ = await syncProfileMe()
        guard let account, !account.userId.isEmpty, Self.isValidZpwSek(zpwSek) else {
            throw ZaloTransportError.notAuthenticated
        }
        self.expiredAt = nil
        await persistSessionIfAllowed()
        return account
    }

    func applyLoginConfig(_ cfg: [String: Any]) {
        let acctDict = cfg["account"] as? [String: Any]
        let uid = [cfg["uid"], cfg["userId"], acctDict?["userId"], acctDict?["uid"], cfg["dkey"]]
            .map(JSONLossless.string)
            .first(where: { !$0.isEmpty }) ?? ""
        let dkey = JSONLossless.string(cfg["dkey"])
        let enk = JSONLossless.string(cfg["zpw_enk"])
        let send2Me = JSONLossless.string(cfg["send2me_id"])
        let sek = [cfg["zpw_sek"], acctDict?["zpw_sek"]]
            .map(JSONLossless.string)
            .first(where: { Self.isValidZpwSek($0) }) ?? ""
        let profileSettings = (cfg["settings"] as? [String: Any])?["profile"] as? [String: Any]
        let name = [acctDict?["display_name"], cfg["display_name"], profileSettings?["name"]]
            .map(JSONLossless.string)
            .first(where: { !$0.isEmpty }) ?? ""
        let hasPcClient = JSONLossless.int64(cfg["has_pc_client"])
        let needSyncFlag = JSONLossless.bool(cfg["need_sync_msg"] ?? cfg["needSyncMsg"])

        if !enk.isEmpty {
            let parsed = ZaloCrypto.parseSecretKey(enk)
            if parsed.count == 16 || parsed.count == 32 {
                self.secretKey = parsed
            }
        }
        if Self.isValidZpwSek(sek) {
            self.zpwSek = sek
        }

        var current = self.account ?? ZaloLoginAccount()
        if !uid.isEmpty { current.userId = uid }
        if !dkey.isEmpty { current.dkey = dkey }
        if !enk.isEmpty { current.zpwEnk = enk }
        if Self.isValidZpwSek(sek) { current.zpwSek = sek }
        else if !Self.isValidZpwSek(current.zpwSek), let existingSek = self.zpwSek, Self.isValidZpwSek(existingSek) {
            current.zpwSek = existingSek
        }
        if !name.isEmpty { current.displayName = name }
        if !send2Me.isEmpty { current.send2MeId = send2Me }
        if let needSyncFlag {
            current.needSyncMsg = needSyncFlag
        } else if let hasPcClient {
            current.needSyncMsg = (hasPcClient == 0)
        }
        self.account = current
        self.domains.applyServerInfo(cfg)
        self.expiredAt = nil
    }

    // MARK: Session Status & Profile

    func sessionStatus() async -> ZaloSessionStatus {
        guard account != nil, zpwSek != nil, secretKey != nil else { return .expired }
        do {
            let info = try await getLoginInfo(zpwType: ZaloDomains.zpwType)
            if let cfg = info["data"] as? [String: Any] {
                applyLoginConfig(cfg)
                needsPCTypeUpgrade = false
                await persistSessionIfAllowed()
                return .valid
            }
        } catch let err as ZaloSessionError {
            if needsPCTypeUpgrade || err.isAuthError {
                Task { @MainActor in
                    EngineLog.shared.write("session: getLoginInfo(type=\(ZaloDomains.zpwType)) rejected code=\(err.code), requiring fresh PC QR login")
                }
                return .expired
            }
        } catch {
            if needsPCTypeUpgrade {
                return .unreachable
            }
        }
        do {
            let resp = try await get(
                service: "profile",
                path: "/api/social/profile/me-v2",
                queryParams: ["os": "8"],
                encryptedPayload: ["avatar_size": 160, "imei": imei]
            )
            let code = JSONLossless.int64(resp["error_code"]).map(Int.init)
            guard let code else { return .unreachable }
            if code == 0 { return .valid }
            return ZaloSessionError.authErrorCodes.contains(code) ? .expired : .unreachable
        } catch let err as ZaloSessionError {
            return err.isAuthError ? .expired : .unreachable
        } catch {
            return .unreachable
        }
    }

    @discardableResult
    func syncProfileMe() async -> ZaloLoginAccount? {
        guard let resp = try? await get(
            service: "profile",
            path: "/api/social/profile/me-v2",
            queryParams: ["os": "8"],
            encryptedPayload: ["avatar_size": 160, "imei": imei]
        ) else {
            return nil
        }
        let dataNode = resp["data"] as? [String: Any]
        guard let profile = (dataNode?["profile"] as? [String: Any]) ?? (resp["profile"] as? [String: Any]) else {
            return nil
        }
        let uid = JSONLossless.string(profile["userId"] ?? profile["uid"])
        let name = JSONLossless.string(profile["displayName"] ?? profile["zaloName"])
        let avatar = JSONLossless.string(profile["avatar"] ?? profile["avt"])
        let phone = JSONLossless.string(profile["phoneNumber"] ?? profile["phone"])

        var updated = self.account ?? ZaloLoginAccount()
        if !uid.isEmpty { updated.userId = uid }
        if !name.isEmpty { updated.displayName = name }
        if !avatar.isEmpty { updated.avatar = avatar }
        if !phone.isEmpty { updated.phone = phone }
        if let sek = self.zpwSek, !sek.isEmpty { updated.zpwSek = sek }
        self.account = updated
        await persistSessionIfAllowed()
        return updated
    }

    // MARK: Authenticated Requests

    func get(
        service: String,
        path: String,
        queryParams: [String: String] = [:],
        headers: [String: String] = [:],
        encryptedPayload: [String: Any]? = nil,
        rawEncryptedString: String? = nil,
        decryptResponse: Bool = true
    ) async throws -> [String: Any] {
        guard let http = coreHttp() else { throw ZaloTransportError.notAuthenticated }
        return try await coreRequest(
            http, method: .get, service: service, path: path, queryParams: queryParams, headers: headers,
            payload: encryptedPayload, rawEncrypted: rawEncryptedString, decryptResponse: decryptResponse)
    }

    // MARK: Rust generic seam (get / post / postMultipart)

    private func coreRecord(
        method: HttpMethod,
        service: String,
        path: String,
        queryParams: [String: String],
        headers: [String: String],
        payload: [String: Any]?,
        rawEncrypted: String?,
        decryptResponse: Bool
    ) throws -> HttpRequestRecord {
        // Same bytes `encodedParams` would encrypt; Rust parses them with exact 64-bit integers.
        let payloadJSON = try payload.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: []), as: UTF8.self) }
        return HttpRequestRecord(
            method: method, service: service, path: path, query: queryParams, headers: headers,
            payloadJson: payloadJSON, rawEncrypted: rawEncrypted, decryptResponse: decryptResponse)
    }

    private func coreRequest(
        _ http: CoreHttp,
        method: HttpMethod,
        service: String,
        path: String,
        queryParams: [String: String],
        headers: [String: String],
        payload: [String: Any]?,
        rawEncrypted: String?,
        decryptResponse: Bool
    ) async throws -> [String: Any] {
        let record = try coreRecord(
            method: method, service: service, path: path, queryParams: queryParams, headers: headers,
            payload: payload, rawEncrypted: rawEncrypted, decryptResponse: decryptResponse)
        do {
            return try Self.coreAnswer(try await http.request(request: record))
        } catch { throw RustCore.mapError(error, path: path) }
    }

    /// The core returns the whole decoded answer (`error_code`, `data` already decrypted) as lossless JSON text.
    private static func coreAnswer(_ json: String) throws -> [String: Any] {
        guard let object = JSONLossless.parseObject(string: json) else { throw ZaloTransportError.invalidJSON }
        return object
    }

    /// `postMultipart` with the file part read from disk (`length` bytes from `offset`, to EOF when `nil`).
    func postMultipart(
        service: String,
        path: String,
        queryParams: [String: String] = [:],
        encryptedPayload: [String: Any],
        fieldName: String,
        fileName: String,
        mimeType: String,
        filePath: String,
        offset: UInt64 = 0,
        length: UInt64? = nil
    ) async throws -> [String: Any] {
        guard let http = coreHttp() else { throw ZaloTransportError.notAuthenticated }
        let record = try coreRecord(
            method: .post, service: service, path: path, queryParams: queryParams, headers: [:],
            payload: encryptedPayload, rawEncrypted: nil, decryptResponse: true)
        let part = UploadPartRecord(fieldName: fieldName, fileName: fileName, mimeType: mimeType)
        do {
            return try Self.coreAnswer(
                try await http.postMultipartFile(request: record, part: part, filePath: filePath, offset: offset, length: length))
        } catch { throw RustCore.mapError(error, path: path) }
    }

    func rawDownloadData(url: URL, timeout: TimeInterval = 20) async throws -> Data {
        let raw = try coreRaw()
        do { return try await raw.download(url: url.absoluteString, timeoutSecs: timeout) }
        catch { throw RustCore.mapError(error, quietTimeout: true) }
    }

    func downloadSyncBatch(url: URL, timeout: TimeInterval = 45) async throws -> Data {
        let raw = try coreRaw()
        do {
            return try await raw.downloadSyncBatch(
                url: url.absoluteString, timeoutSecs: timeout, zpwSek: zpwSek, userId: account?.userId)
        } catch {
            if case CoreError.Http(let status) = error {
                let host = url.host ?? "-"
                Task { @MainActor in
                    EngineLog.shared.write("sync-v2: batch download failed http=\(status) host=\(host)")
                }
            }
            throw RustCore.mapError(error, quietTimeout: true)
        }
    }

    func post(
        service: String,
        path: String,
        queryParams: [String: String] = [:],
        headers: [String: String] = [:],
        encryptedPayload: [String: Any],
        decryptResponse: Bool = true
    ) async throws -> [String: Any] {
        guard let http = coreHttp() else { throw ZaloTransportError.notAuthenticated }
        return try await coreRequest(
            http, method: .post, service: service, path: path, queryParams: queryParams, headers: headers,
            payload: encryptedPayload, rawEncrypted: nil, decryptResponse: decryptResponse)
    }

    func postMultipart(
        service: String,
        path: String,
        queryParams: [String: String] = [:],
        encryptedPayload: [String: Any],
        fieldName: String,
        fileName: String,
        mimeType: String,
        chunkData: Data
    ) async throws -> [String: Any] {
        guard let http = coreHttp() else { throw ZaloTransportError.notAuthenticated }
        let record = try coreRecord(
            method: .post, service: service, path: path, queryParams: queryParams, headers: [:],
            payload: encryptedPayload, rawEncrypted: nil, decryptResponse: true)
        let part = UploadPartRecord(fieldName: fieldName, fileName: fileName, mimeType: mimeType)
        do {
            return try Self.coreAnswer(try await http.postMultipart(request: record, part: part, data: chunkData))
        } catch { throw RustCore.mapError(error, path: path) }
    }

    static func shouldFailover(_ error: Error) -> Bool {
        if error is ZaloSessionError { return false }
        if let transport = error as? ZaloTransportError {
            if case .httpError(let status, _) = transport { return status == 404 || status >= 500 }
            return false
        }
        return error is URLError
    }

    func maybeDecrypt(_ response: [String: Any], key: Data?) -> [String: Any] {
        Self.unwrapDecryptedResponse(response, key: key)
    }

    static func unwrapDecryptedResponse(_ response: [String: Any], key: Data?) -> [String: Any] {
        var out = response
        if let dataStr = out["data"] as? String {
            let trimmed = dataStr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                if let parsed = trimmed.data(using: .utf8).flatMap(JSONLossless.parseAny) {
                    out["data"] = parsed
                }
                return out
            }
            if let key, key.count == 16 || key.count == 32,
               let plain = try? ZaloCrypto.decodeAES(key: key, base64: trimmed),
               let plainData = plain.data(using: .utf8),
               let decoded = JSONLossless.parseAny(plainData) {
                if var dict = decoded as? [String: Any], dict["error_code"] != nil || dict["data"] != nil {
                    if let nestedStr = dict["data"] as? String {
                        let nestedTrimmed = nestedStr.trimmingCharacters(in: .whitespacesAndNewlines)
                        if (nestedTrimmed.hasPrefix("{") || nestedTrimmed.hasPrefix("[")),
                           let nestedParsed = nestedTrimmed.data(using: .utf8).flatMap(JSONLossless.parseAny) {
                            dict["data"] = nestedParsed
                        } else if let nestedPlain = try? ZaloCrypto.decodeAES(key: key, base64: nestedTrimmed),
                                  let nestedPlainData = nestedPlain.data(using: .utf8),
                                  let nestedDecoded = JSONLossless.parseAny(nestedPlainData) {
                            dict["data"] = nestedDecoded
                        }
                    }
                    return dict
                }
                out["data"] = decoded
            }
        }
        return out
    }

    func rawRequest(
        method: String,
        url: URL,
        body: Data? = nil,
        contentType: String? = nil,
        timeout: TimeInterval? = nil,
        extraHeaders: [String: String] = [:]
    ) async throws -> (Int, Data, String?) {
        let raw = try coreRaw()
        let record = RawRequestRecord(
            method: method.uppercased() == "POST" ? .post : .get, url: url.absoluteString, body: body,
            contentType: contentType, timeoutSecs: timeout, headers: extraHeaders, zpwSek: zpwSek)
        do {
            let out = try await raw.request(request: record)
            return (Int(out.status), out.body, out.zpwSekCookie)
        } catch { throw RustCore.mapError(error, quietTimeout: true) }
    }

    static func isValidZpwSek(_ candidate: String?) -> Bool {
        guard let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw != "EXPIRED",
              raw != "deleted",
              raw != "null",
              raw.contains(".") else {
            return false
        }
        return true
    }

    static func extractZpwSek(from json: [String: Any]) -> String? {
        let dataDict = json["data"] as? [String: Any]
        let accountDict = dataDict?["account"] as? [String: Any]
        for container in [json, dataDict, accountDict].compactMap({ $0 }) {
            if let val = container["zpw_sek"] as? String {
                let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
                if isValidZpwSek(trimmed) {
                    return trimmed
                }
            }
        }
        return nil
    }

    static func urlEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    static func sortedQueryString(_ params: [String: String]) -> String {
        params.keys.sorted().map { key in
            "\(key)=\(urlEncode(params[key] ?? ""))"
        }.joined(separator: "&")
    }
}
