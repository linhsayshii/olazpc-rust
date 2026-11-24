import Foundation

/// Account privacy settings (official `PrivacySettingsConfig`, `getSettings` / `setSettings` on the auth host).
enum PrivacyKey: String, CaseIterable, Sendable {
    case showOnlineStatus = "show_online_status"
    case displaySeenStatus = "display_seen_status"

    var title: String {
        switch self {
        case .showOnlineStatus: "Hiển thị trạng thái truy cập"
        case .displaySeenStatus: "Hiện trạng thái \"Đã xem\""
        }
    }

    /// Settings come as 0/1 or booleans; a missing key reads as on (the official default).
    static func value(_ raw: Any?) -> Bool? {
        if let b = raw as? Bool { return b }
        if let n = JSONLossless.int64(raw) { return n != 0 }
        return nil
    }
}

extension ZaloSessionClient {
    /// `auth /api/setting/me`: the account's settings.
    func fetchPrivacyAPI() async throws -> [PrivacyKey: Bool] {
        let resp = try await get(service: "auth", path: "/api/setting/me")
        let data = resp["data"] as? [String: Any] ?? [:]
        var out: [PrivacyKey: Bool] = [:]
        for key in PrivacyKey.allCases { out[key] = PrivacyKey.value(data[key.rawValue]) ?? true }
        return out
    }

    /// `auth /api/setting/update` {key: 0/1} (official `setSettings` sends only the changed keys).
    func updatePrivacyAPI(_ key: PrivacyKey, on: Bool) async throws {
        _ = try await get(service: "auth", path: "/api/setting/update", encryptedPayload: [key.rawValue: on ? 1 : 0])
    }
}

extension ZaloEngine {
    func loadPrivacy() async {
        privacy = (try? await sessionClient.fetchPrivacyAPI()) ?? privacy ?? [:]
    }

    func setPrivacy(_ key: PrivacyKey, on: Bool) async {
        do {
            try await sessionClient.updatePrivacyAPI(key, on: on)
            var map = privacy ?? [:]
            map[key] = on
            privacy = map
        } catch {
            EngineLog.shared.write("privacy: update failed \(key.rawValue)")
        }
    }
}
