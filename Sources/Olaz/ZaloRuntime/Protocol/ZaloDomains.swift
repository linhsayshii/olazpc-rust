import Foundation

/// Authoritative Zalo macOS PC service endpoints (`zpw_ver=695`, `zpw_type=23`)
/// plus live `getServerInfo` / `getLoginInfo` service map discovery and failover.
struct ZaloDomains: Codable, Sendable {
    static let zpwVer = RustCore.clientIdentity.clientVersion
    static let zpwType = RustCore.clientIdentity.clientType
    static let zpwPCType = RustCore.clientIdentity.clientType
    static let zpwWebType = RustCore.clientIdentity.webClientType
    static let userAgent = RustCore.clientIdentity.userAgent
    static let wsOrigin = RustCore.clientIdentity.wsOrigin

    /// Authoritative `zpw_service_map_v3` defaults returned by `wpa.zaloapp.com` for `type=23`.
    static let defaultServiceMapV3: [String: [String]] = [
        "profile": ["https://tt-profile-wpa.zaloapp.com"],
        "friend": ["https://tt-friend-wpa.zaloapp.com"],
        "conversation": ["https://tt-convers-wpa.api.zaloapp.com"],
        "chat": [
            "https://tt-chat3-wpa.api.zaloapp.com",
            "https://tt-chat1-wpa.api.zaloapp.com",
            "https://tt-chat2-wpa.api.zaloapp.com",
            "https://tt-chat4-wpa.api.zaloapp.com",
        ],
        "chat_e2e": [
            "https://tt-chat3-wpa.api.zaloapp.com",
            "https://tt-chat1-wpa.api.zaloapp.com",
            "https://tt-chat2-wpa.api.zaloapp.com",
            "https://tt-chat4-wpa.api.zaloapp.com",
        ],
        "group": ["https://tt-group-wpa.zaloapp.com"],
        "group_e2e": ["https://tt-group-wpa.zaloapp.com"],
        "group_board": ["https://groupboard-wpa.api.zaloapp.com"],
        "group_poll": ["https://tt-group-wpa.zaloapp.com"],
        "group_cloud_message": ["https://tt-group-cm.api.zaloapp.com"],
        "sticker": ["https://tt-sticker-wpa.zaloapp.com"],
        "alias": ["https://tt-alias-wpa.api.zaloapp.com"],
        "label": ["https://label-wpa.api.zaloapp.com"],
        "reaction": ["https://reaction.api.zaloapp.com"],
        "emoji_status": ["https://emoji-status.api.zaloapp.com"],
        "zcloud": ["https://zcld.chat.zalo.me", "https://zcld.api.zaloapp.com"],
        "zcloud_up_file": ["https://tt-zcfiles-wpa.zaloapp.com"],
        "file": ["https://tt-files-wpa.zaloapp.com"],
        "up_file": ["https://tt-nfiles-wpa.zaloapp.com", "https://tt-files-wpa.zaloapp.com"],
        "media_store": ["https://media-wpa.zaloapp.com"],
        "media_store_send2me": ["https://mediasend2me-wpa.zaloapp.com"],
        "voice_call": ["https://voicecall-wpa.zaloapp.com"],
        "znoise": ["https://zwid.api.zalo.me"],
        "friend_lan": ["https://friend-lan-wpa.zaloapp.com"],
        "auto_reply": ["https://autoreply-wpa.api.zaloapp.com"],
        "quick_message": ["https://quickmsg-wpa.api.zaloapp.com"],
    ]

    /// Additional `zpw_service_map_v3` defaults resolved in `candidates(for:)` without altering `defaultServiceMapV3.keys`.
    private static let additionalDefaultServices: [String: [String]] = [
        "friend_board": ["https://friendboard-wpa.chat.zalo.me"],
    ]

    /// Secondary `.chat.zalo.me` fallbacks used only if all `.zaloapp.com` hosts fail.
    static let fallbackHosts: [String: [String]] = [
        "profile": ["https://tt-profile-wpa.chat.zalo.me"],
        "friend": ["https://tt-friend-wpa.chat.zalo.me", "https://tt-profile-wpa.zaloapp.com"],
        "conversation": ["https://tt-convers-wpa.chat.zalo.me"],
        "chat": ["https://tt-chat3-wpa.chat.zalo.me"],
        "chat_e2e": ["https://tt-chat3-wpa.chat.zalo.me"],
        "group": ["https://tt-group-wpa.chat.zalo.me"],
        "group_e2e": ["https://tt-group-wpa.chat.zalo.me"],
        "group_board": ["https://groupboard-wpa.chat.zalo.me", "https://groupboard-wpa.zaloapp.com"],
        "group_poll": ["https://group-poll-wpa.zaloapp.com", "https://group-poll-wpa.chat.zalo.me"],
        "group_cloud_message": ["https://tt-group-cm.chat.zalo.me"],
        "sticker": ["https://tt-sticker-wpa.chat.zalo.me"],
        "alias": ["https://tt-alias-wpa.zaloapp.com", "https://tt-alias-wpa.chat.zalo.me"],
        "label": ["https://label-wpa.zaloapp.com", "https://label-wpa.chat.zalo.me"],
        "reaction": ["https://reaction.chat.zalo.me"],
        "zcloud": ["https://zcld.chat.zalo.me"],
        "file": ["https://tt-files-wpa.chat.zalo.me"],
        "up_file": ["https://tt-files-wpa.zaloapp.com", "https://tt-files-wpa.chat.zalo.me"],
        "voice_call": ["https://voicecall-wpa.chat.zalo.me"],
        "znoise": ["https://tt-profile-wpa.zaloapp.com"],
    ]

    var auth: String = "https://wpa.zaloapp.com"
    var wpaChat: String = "https://wpa.chat.zalo.me"
    var lpChat: String = "https://p4-msg-chat.zaloapp.com"
    var lpControl: String = "https://p4-ctl-chat.zaloapp.com"
    var ws: [String] = [
        "wss://ws1-msg.chat.zalo.me",
        "wss://ws2-msg.chat.zalo.me",
        "wss://ws3-msg.chat.zalo.me",
        "wss://ws4-msg.chat.zalo.me",
    ]
    var serviceCandidates: [String: [String]] = [:]
    var preferredHosts: [String: String] = [:]
    var isolated: Bool = false

    private enum CodingKeys: String, CodingKey {
        case auth, wpaChat, lpChat, lpControl, ws, serviceCandidates, preferredHosts, isolated
    }

    init(isolated: Bool = false) {
        self.isolated = isolated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        auth = try c.decode(String.self, forKey: .auth)
        wpaChat = try c.decode(String.self, forKey: .wpaChat)
        lpChat = try c.decode(String.self, forKey: .lpChat)
        lpControl = try c.decode(String.self, forKey: .lpControl)
        ws = try c.decode([String].self, forKey: .ws)
        serviceCandidates = try c.decode([String: [String]].self, forKey: .serviceCandidates)
        preferredHosts = try c.decode([String: String].self, forKey: .preferredHosts)
        isolated = try c.decodeIfPresent(Bool.self, forKey: .isolated) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(auth, forKey: .auth)
        try c.encode(wpaChat, forKey: .wpaChat)
        try c.encode(lpChat, forKey: .lpChat)
        try c.encode(lpControl, forKey: .lpControl)
        try c.encode(ws, forKey: .ws)
        try c.encode(serviceCandidates, forKey: .serviceCandidates)
        try c.encode(preferredHosts, forKey: .preferredHosts)
        if isolated {
            try c.encode(true, forKey: .isolated)
        }
    }

    /// Clears stale `.chat.zalo.me` HTTP preferred hosts left over from legacy `zpw_type=30` sessions.
    mutating func healFromVerified() {
        for (key, current) in preferredHosts {
            if current.contains(".chat.zalo.me") && key != "zcloud" && key != "friend_board" {
                preferredHosts.removeValue(forKey: key)
            }
        }
        ws = ws.map { $0.replacingOccurrences(of: "-msg.zaloapp.com", with: "-msg.chat.zalo.me") }
    }

    static func canonicalService(_ name: String) -> String {
        switch name {
        case "convers_api": return "conversation"
        case "cloud_msg": return "group_cloud_message"
        default: return name
        }
    }

    static func normalizeHost(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return withScheme.hasSuffix("/") ? String(withScheme.dropLast()) : withScheme
    }

    mutating func applyServerInfo(_ data: [String: Any]) {
        if let lp = firstURL(from: data["zpw_chts_new"]) { lpChat = lp }
        if let ctrl = firstURL(from: data["zpw_ctrs_new"]) { lpControl = ctrl }
        if let wsList = data["zpw_ws"] as? [Any] {
            let parsed = wsList.compactMap { $0 as? String }
                .map { Self.normalizeHost($0) }
                .filter { $0.hasPrefix("wss://") || $0.hasPrefix("ws://") }
            if !parsed.isEmpty { ws = parsed }
        }
        let serviceMap = (data["zpw_service_map_v3"] as? [String: Any])
            ?? (data["zpw_service_map_new"] as? [String: Any])
        if let serviceMap {
            for (rawKey, val) in serviceMap {
                let key = Self.canonicalService(rawKey)
                var hosts: [String] = []
                if let single = val as? String {
                    let h = Self.normalizeHost(single)
                    if !h.isEmpty { hosts.append(h) }
                } else if let arr = val as? [Any] {
                    for item in arr {
                        if let s = item as? String {
                            let h = Self.normalizeHost(s)
                            if !h.isEmpty && !hosts.contains(h) { hosts.append(h) }
                        }
                    }
                }
                if !hosts.isEmpty {
                    serviceCandidates[key] = hosts
                }
            }
        }
    }

    func candidates(for service: String) -> [String] {
        let key = Self.canonicalService(service)
        var list: [String] = []
        func appendUnique(_ raw: String?) {
            guard let raw else { return }
            let h = Self.normalizeHost(raw)
            guard !h.isEmpty, !list.contains(h) else { return }
            list.append(h)
        }
        if let preferred = preferredHosts[key] {
            appendUnique(preferred)
        }
        if let mapped = serviceCandidates[key] {
            for host in mapped { appendUnique(host) }
        }
        if key == "auth" {
            appendUnique(auth)
            appendUnique(wpaChat)
        }
        if !isolated {
            if let defaults = Self.defaultServiceMapV3[key] {
                for host in defaults { appendUnique(host) }
            }
            if let extraDefaults = Self.additionalDefaultServices[key] {
                for host in extraDefaults { appendUnique(host) }
            }
            if let fallbacks = Self.fallbackHosts[key] {
                for host in fallbacks { appendUnique(host) }
            }
        }
        return list
    }

    mutating func rememberWinner(for service: String, host: String) {
        let key = Self.canonicalService(service)
        let norm = Self.normalizeHost(host)
        guard !norm.isEmpty else { return }
        preferredHosts[key] = norm
    }

    private func firstURL(from raw: Any?) -> String? {
        if let s = raw as? String {
            let h = Self.normalizeHost(s)
            return h.isEmpty ? nil : h
        }
        if let arr = raw as? [Any], let first = arr.first as? String {
            let h = Self.normalizeHost(first)
            return h.isEmpty ? nil : h
        }
        return nil
    }
}
