import Foundation

// Stickers: the picker of the composer and the suggestions while typing, bridged to `HostScripts/sticker-adapter.js`
// (`window.__zaloSticker`; the official entry points are listed in that file's header). Every call goes to the official sticker services.
// Sending runs only from a click on a sticker (picker or suggestion); nothing else here writes. Typed text goes to the JS side only when the
// "Gợi ý Sticker" setting is on, and never for end-to-end encrypted chats. No ids, names or content go to the log.
//
// Swift → JS (all async, see the adapter header for the shapes):
//   categories() → [{id, name, icon, count}]   category(id) → {id, stickers:[{cateId, id, url}]}   search(text) → [Sticker]
//   suggest(convId, text) → [Sticker]   send(convId, {cateId, id}, source) → {status, text?}   suggestSetting() / setSuggestSetting(on)

/// Where a sticker animates from, when it has an animated source (sticker-adapter.js `animOf`): a sprite sheet (`frames` pictures of the
/// sticker side by side, `frameMs` each) or an animated image (a GIF, or the animated WebP of `ext === WEBP` stickers). The still picture is
/// `StickerEntry.url`.
enum StickerAnimation: Hashable, Sendable {
    case sprite(url: URL, frames: Int, frameMs: Int)
    case animated(url: URL)

    init?(json: Any?) {
        guard let row = json as? [String: Any], let url = WebLink.sanitized((row["url"] as? String).flatMap { URL(string: $0) }) else { return nil }
        switch row["kind"] as? String {
        case "sprite":
            let frames = (row["frames"] as? NSNumber).map { clampedInt($0.doubleValue) } ?? 0
            let ms = (row["ms"] as? NSNumber).map { clampedInt($0.doubleValue) } ?? 0
            guard (2...200).contains(frames) else { return nil }
            self = .sprite(url: url, frames: frames, frameMs: min(max(ms, 30), 1000))
        case "gif", "webp": self = .animated(url: url)
        default: return nil
        }
    }
}

/// A sticker as the picker and the suggestion strip draw it; `url` is an http(s) CDN link (the still picture, same endpoint as the chat bubble).
struct StickerEntry: Identifiable, Hashable, Sendable {
    var cateId: Int
    var stickerId: Int
    var url: URL
    var animation: StickerAnimation?
    var id: String { "\(cateId)_\(stickerId)" }

    init(cateId: Int, stickerId: Int, url: URL, animation: StickerAnimation? = nil) {
        self.cateId = cateId
        self.stickerId = stickerId
        self.url = url
        self.animation = animation
    }

    /// Rows that are not a sticker (no ids, no web URL) are dropped; at most `limit` are kept, each sticker once.
    static func list(json: Any?, limit: Int = 500) -> [StickerEntry] {
        var seen = Set<String>()
        var out: [StickerEntry] = []
        for case let row as [String: Any] in (json as? [Any] ?? []) {
            guard let cate = (row["cateId"] as? NSNumber).map({ clampedInt($0.doubleValue) }), cate >= 0,
                  let sticker = (row["id"] as? NSNumber).map({ clampedInt($0.doubleValue) }), sticker > 0,
                  let url = WebLink.sanitized((row["url"] as? String).flatMap { URL(string: $0) }) else { continue }
            let entry = StickerEntry(cateId: cate, stickerId: sticker, url: url, animation: StickerAnimation(json: row["anim"]))
            guard seen.insert(entry.id).inserted else { continue }
            out.append(entry)
            if out.count >= limit { break }
        }
        return out
    }
}

/// One tab of the picker: a downloaded sticker set, or the recent stickers (`recentId`, always first when present).
struct StickerTab: Identifiable, Hashable, Sendable {
    static let recentId = -2

    var id: Int
    var name: String
    var icon: URL?
    var count: Int
    var isRecent: Bool { id == Self.recentId }

    /// nil = the list could not be read (not the same as "no sets").
    static func list(json: Any?) -> [StickerTab]? {
        guard let rows = json as? [Any] else { return nil }
        var seen = Set<Int>()
        var out: [StickerTab] = []
        for case let row as [String: Any] in rows {
            guard let id = (row["id"] as? NSNumber).map({ clampedInt($0.doubleValue) }), id >= recentId, seen.insert(id).inserted else { continue }
            out.append(StickerTab(
                id: id, name: String((row["name"] as? String ?? "").prefix(200)),
                icon: WebLink.sanitized((row["icon"] as? String).flatMap { URL(string: $0) }),
                count: max(0, min(10_000, (row["count"] as? NSNumber).map { clampedInt($0.doubleValue) } ?? 0))))
            if out.count >= 200 { break }
        }
        return out
    }
}

/// Where a sticker is sent from; it decides the send source the official client records (106 / 103 / 109 / 101).
enum StickerSource: String, Sendable {
    case category, recent, search, suggestion
}

/// The "Gợi ý Sticker" setting plus the official typing debounce (`sticker_post_typing.debounce`, milliseconds).
struct StickerSuggestSetting: Equatable, Sendable {
    var enabled: Bool
    var debounce: Int

    init?(json: Any?) {
        guard let root = json as? [String: Any], (root["ok"] as? Bool) == true, let enabled = root["enabled"] as? Bool else { return nil }
        self.enabled = enabled
        debounce = max(0, min(2000, (root["debounce"] as? NSNumber).map { clampedInt($0.doubleValue) } ?? 0))
    }
}

/// The composer's sticker suggestions for the text being typed: what was offered, for which text, and whether the user hid it.
/// The strip shows only while the draft still is the text the stickers were found for (a click on stale stickers must never take newer text),
/// and a click takes the whole box first (official `_sendSuggestionSticker` → `_clearBoxChatAndClosePopup`).
struct TypingStickerState: Equatable {
    private(set) var stickers: [StickerEntry] = []
    private(set) var suggestedFor: String?
    /// Esc / × hid the strip; the composer resets it when the draft changes.
    var dismissed = false
    /// The text a send for which no answer came: it may still be on its way, so no strip is offered for that same text again
    /// (typing something else releases it).
    private(set) var held: String?

    /// What a click took from the box: the whole draft (to give back if the send fails) and the text the sticker was suggested for.
    struct Taken: Equatable {
        var draft: ComposerDraft
        var typed: String
    }

    mutating func offer(_ found: [StickerEntry], for text: String) {
        if let held, text == held { stickers = []; suggestedFor = nil; return }
        held = nil
        stickers = found
        suggestedFor = found.isEmpty ? nil : text
    }

    /// A send for `text` did not answer in time: keep the strip away for that text.
    mutating func hold(_ text: String) { held = text }

    func isHeld(_ text: String) -> Bool { held == text }

    /// Empties the strip; a hold stays until a different text gets suggestions.
    mutating func clear() {
        stickers = []
        suggestedFor = nil
    }

    /// `settingEnabled`: nil = not known yet (not a "no").
    func isVisible(draft: String, mentionListOpen: Bool, settingEnabled: Bool?) -> Bool {
        !stickers.isEmpty && suggestedFor == draft && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !dismissed && !mentionListOpen && settingEnabled != false
    }

    /// The click: clears the strip and returns what to send and what to give back. (The composer checks that the strip is showing.)
    mutating func take(_ draft: ComposerDraft) -> Taken {
        let taken = Taken(draft: draft, typed: suggestedFor ?? draft.text)
        clear()
        return taken
    }
}

/// What the composer and the settings page share about the suggestion setting, so a change applies to open chats at once.
@MainActor @Observable final class StickerSuggestState {
    static let shared = StickerSuggestState()
    private(set) var setting: StickerSuggestSetting?
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var loading = false
    /// Never faster than this between keystrokes, whatever the server config says (it is 0 today): typing bursts are coalesced.
    static let minimumDelay = 120
    /// A failed read is not repeated sooner than this (the composer asks on typing; the service may not be resolved yet right after launch).
    static let retryInterval: TimeInterval = 5

    func load(from engine: ZaloEngine) async {
        if let fresh = await engine.stickerSuggestSetting() { setting = fresh }
    }

    /// Reads the setting when it is not known yet, at most once per `retryInterval` and never twice at once.
    func loadIfNeeded(from engine: ZaloEngine) async {
        guard setting == nil, !loading, lastAttempt.map({ Date().timeIntervalSince($0) >= Self.retryInterval }) ?? true else { return }
        loading = true
        lastAttempt = Date()
        await load(from: engine)
        loading = false
    }

    func apply(_ value: StickerSuggestSetting?) { setting = value }

    func reset() {
        setting = nil
        lastAttempt = nil
    }

    /// Milliseconds to wait after the last keystroke before asking.
    var delay: Int { max(Self.minimumDelay, setting?.debounce ?? 0) }
}

extension ZaloEngine {
    func stickerTabs() async -> [StickerTab]? {
        guard let box = try? await sessionClient.fetchStickerCategories() else { return nil }
        var tabs: [[String: Any]] = []
        if let recents = try? await recentStickersFromSQLite(), !recents.isEmpty {
            tabs.append(["id": StickerTab.recentId, "name": "Gần đây", "icon": "", "count": recents.count])
        }
        for row in box.array {
            let id = Int(JSONLossless.int64(row["id"] ?? row["cateId"]) ?? -1)
            guard id >= 0 else { continue }
            tabs.append([
                "id": id,
                "name": JSONLossless.string(row["name"]),
                "icon": JSONLossless.string(row["iconUrl"] ?? row["icon"]),
                "count": Int(JSONLossless.int64(row["total"] ?? row["count"]) ?? 0)
            ])
        }
        return StickerTab.list(json: tabs)
    }

    func stickers(inTab id: Int) async -> [StickerEntry]? {
        if id == StickerTab.recentId {
            let recents = (try? await recentStickersFromSQLite()) ?? []
            return StickerEntry.list(json: recents)
        }
        guard let box = try? await sessionClient.fetchStickerCategoryDetail(cateId: id) else { return nil }
        let rows: [[String: Any]] = {
            if let direct = box.dict["data"] as? [[String: Any]] {
                return direct
            }
            if let dataNode = box.dict["data"] as? [String: Any] {
                return (dataNode["stickers"] as? [[String: Any]])
                    ?? ((dataNode["\(id)"] as? [String: Any])?["stickers"] as? [[String: Any]])
                    ?? []
            }
            return []
        }()
        let mapped = rows.map { normalizeStickerRow($0, fallbackCateId: id) }
        return StickerEntry.list(json: mapped)
    }

    func searchStickers(_ text: String) async -> [StickerEntry]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let box = try? await sessionClient.searchStickersAPI(keyword: trimmed, limit: 40) else { return nil }
        let mapped = box.array.map { normalizeStickerRow($0, fallbackCateId: 0) }
        return StickerEntry.list(json: mapped, limit: 40)
    }

    func typingStickerSuggestions(in conversationId: String, text: String) async -> [StickerEntry] {
        guard StickerSuggestState.shared.setting?.enabled != false else { return [] }
        if !ZaloWireParser.isGroupId(conversationId), await e2eeManager.isE2EEConversation(conversationId) {
            return []
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let box = try? await sessionClient.suggestStickersAPI(keyword: trimmed) else { return [] }
        let mapped = box.array.map { normalizeStickerRow($0, fallbackCateId: 0) }
        return StickerEntry.list(json: mapped, limit: 30)
    }

    func sendSticker(_ sticker: StickerEntry, in conversationId: String, source: StickerSource, typed: String? = nil, index: Int = -1) async -> CardActionOutcome {
        do {
            var isE2EE = false
            if !ZaloWireParser.isGroupId(conversationId) {
                isE2EE = await e2eeManager.isE2EEConversation(conversationId)
            }
            let res: SendMessageResult
            if isE2EE {
                if let sendE2EEStickerHostHandler {
                    let cliInt = await sessionClient.nextClientId()
                    let cliId = "\(cliInt)"
                    let args: [String: Any] = [
                        "conv_id": conversationId,
                        "cate_id": sticker.cateId,
                        "sticker_id": sticker.stickerId,
                        "client_id": cliId,
                    ]
                    _ = traceHost("send_e2ee_sticker", args: args)
                    guard let hostRes = try await sendE2EEStickerHostHandler(args) else {
                        return .failed("Không gửi được sticker mã hóa đầu cuối.")
                    }
                    res = hostRes
                } else {
                let myUid = profile?.userId ?? ""
                guard !myUid.isEmpty,
                      await e2eeManager.ensureSessions(forPeer: conversationId, myUid: myUid, webSocket: webSocket, store: sqliteStore) else {
                    EngineLog.shared.write("sendSticker e2ee failed: no open Signal session for peer=\(conversationId)")
                    return .failed("Không gửi được sticker mã hóa đầu cuối.")
                }
                let encryptedDevices = await e2eeManager.encryptStickerMessage(
                    peerUid: conversationId,
                    myUid: myUid,
                    stickerId: sticker.stickerId,
                    cateId: sticker.cateId,
                    stickerType: 7,
                    store: sqliteStore
                )
                guard !encryptedDevices.isEmpty else {
                    EngineLog.shared.write("sendSticker e2ee failed: encryption produced no peer payloads for peer=\(conversationId)")
                    return .failed("Không gửi được sticker mã hóa đầu cuối.")
                }
                let senderIid = await e2eeManager.localRegistrationId()
                let imei = await sessionClient.imei
                let cliInt = await sessionClient.nextClientId()
                let listParams: [[String: Any]] = encryptedDevices.compactMap { dev in
                    guard dev.ciphers.count >= 3 else { return nil }
                    let extra: [String: Any] = [
                        "stickerId": dev.ciphers[0],
                        "cateId": dev.ciphers[1],
                        "type": dev.ciphers[2],
                        "zsource": 101,
                    ]
                    return ZaloSessionClient.buildE2EEListParamEntry(
                        toId: dev.toId,
                        platform: dev.platform,
                        clientId: cliInt,
                        imei: imei,
                        registrationId: dev.registrationId,
                        senderIid: senderIid,
                        extraFields: extra
                    )
                }
                guard !listParams.isEmpty else {
                    EngineLog.shared.write("sendSticker e2ee failed: empty listParams for peer=\(conversationId)")
                    return .failed("Không gửi được sticker mã hóa đầu cuối.")
                }
                res = try await sessionClient.sendE2EEMessageAPI(
                    endpoint: "sticker",
                    threadId: conversationId,
                    isGroup: false,
                    clientId: cliInt,
                    listParams: ZaloJSONArrayBox(listParams)
                )
                }
            } else {
                res = try await sessionClient.sendStickerAPI(convId: conversationId, cateId: sticker.cateId, stickerId: sticker.stickerId)
            }
            let msg = ChatMessage(
                id: res.msgId,
                conversationId: conversationId,
                senderId: profile?.userId ?? "",
                senderName: profile?.displayName ?? "Bạn",
                senderAvatar: profile?.avatar,
                isMine: true,
                kind: .sticker(url: sticker.url),
                text: "[Sticker]",
                date: Date(timeIntervalSince1970: Double(nowMs()) / 1000.0),
                status: .sent,
                quote: nil,
                reactions: [],
                isE2EE: isE2EE,
                mentions: [],
                cardButtons: [],
                suggestsStickers: false,
                menu: MessageMenu(json: [
                    "forward": "ok",
                    "recall": conversationId != selfConversationId,
                    "delete": conversationId == selfConversationId ? "plain" : "forMe",
                    "pin": false,
                    "star": "star"
                ]),
                clientId: res.cliMsgId
            )
            mergeMessageIntoMemory(msg, replacingClientId: res.cliMsgId)
            if let stored = ZaloWireParser.encodeChatMessage(msg, clientId: res.cliMsgId) {
                try? await sqliteStore?.saveMessages([stored])
            }
            updateConversationOnMessage(msg, incrementUnread: false)
            await saveRecentSticker(sticker)
            return .done
        } catch {
            EngineLog.shared.write("sendSticker failed: \(error.localizedDescription)")
            return .failed("Không gửi được sticker. Hãy thử lại.")
        }
    }

    func stickerSuggestSetting() async -> StickerSuggestSetting? {
        let enabled = (try? await sqliteStore?.getPreferenceBool(key: "stickerSuggest", default: true)) ?? true
        return StickerSuggestSetting(json: ["ok": true, "enabled": enabled, "debounce": 180])
    }

    func setStickerSuggest(enabled: Bool) async -> StickerSuggestSetting? {
        try? await sqliteStore?.setPreferenceBool(key: "stickerSuggest", value: enabled)
        let now = await stickerSuggestSetting()
        StickerSuggestState.shared.apply(now)
        return now
    }

    func resetStickers() {
        StickerSuggestState.shared.reset()
    }

    private func normalizeStickerRow(_ row: [String: Any], fallbackCateId: Int) -> [String: Any] {
        let id = Int(JSONLossless.int64(row["id"] ?? row["stickerId"] ?? row["sticker_id"]) ?? 0)
        let cate = Int(JSONLossless.int64(row["cateId"] ?? row["cate_id"]) ?? Int64(fallbackCateId))
        let explicitUrl = JSONLossless.string(row["stickerUrl"] ?? row["url"])
        let urlStr = explicitUrl.isEmpty
            ? ZaloWireParser.stickerCDNURL(cateId: cate, stickerId: "\(id)")
            : explicitUrl
        var out: [String: Any] = [
            "id": id,
            "cateId": cate,
            "type": Int(JSONLossless.int64(row["type"]) ?? 7),
            "url": urlStr
        ]
        let sprite = JSONLossless.string(row["stickerSpriteUrl"]).replacingOccurrences(of: "http://", with: "https://")
        let frames = Int(JSONLossless.int64(row["totalFrames"]) ?? 0)
        if sprite.hasPrefix("https://"), (2...200).contains(frames) {
            let dur = Int(JSONLossless.int64(row["duration"]) ?? 120)
            out["anim"] = [
                "kind": "sprite",
                "url": sprite,
                "frames": frames,
                "ms": max(30, min(1000, dur > 0 ? dur : 120))
            ]
        }
        return out
    }

    private func recentStickersFromSQLite() async throws -> [[String: Any]] {
        guard let store = sqliteStore,
              let data = try await store.getPreferenceData(key: "recentStickers"),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return rows
    }

    private func saveRecentSticker(_ sticker: StickerEntry) async {
        guard let store = sqliteStore else { return }
        var rows = (try? await recentStickersFromSQLite()) ?? []
        rows.removeAll { (JSONLossless.int64($0["id"]) == Int64(sticker.stickerId)) }
        rows.insert([
            "id": sticker.stickerId,
            "cateId": sticker.cateId,
            "type": 7,
            "url": sticker.url.absoluteString
        ], at: 0)
        if rows.count > 30 { rows = Array(rows.prefix(30)) }
        if let data = try? JSONSerialization.data(withJSONObject: rows) {
            try? await store.setPreferenceData(key: "recentStickers", data: data)
        }
    }
}
