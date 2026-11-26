import AppKit
import Foundation
import OlazCore

// MARK: - Notification settings & per-conversation mute (U16, Rust `olaz-core` owner)

/// How long to silence a conversation (`MuteDuration` raw values match the official menu).
enum MuteDuration: Int, CaseIterable, Identifiable, Sendable {
    case oneHour = 1
    case fourHours = 2
    case until8AM = 3
    case untilReopened = 4

    var id: Int { rawValue }

    /// Official strings `STR_MUTE_ONE_HOURS`, `STR_MUTE_FOUR_HOUR`, `STR_MUTE_TO_8_AM`, `STR_MUTE_NO_LIMIT`.
    var title: String {
        switch self {
        case .oneHour: "Trong 1 giờ"
        case .fourHours: "Trong 4 giờ"
        case .until8AM: "Cho đến 8:00 AM"
        case .untilReopened: "Cho đến khi được mở lại"
        }
    }

    /// When the mute ends, nil = until the user turns notifications back on.
    func expiry(from now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .oneHour: return now.addingTimeInterval(3600)
        case .fourHours: return now.addingTimeInterval(4 * 3600)
        case .until8AM:
            return calendar.nextDate(after: now, matching: DateComponents(hour: 8, minute: 0, second: 0), matchingPolicy: .nextTime)
        case .untilReopened: return nil
        }
    }
}

/// A conversation mute as stored by `olaz-core` (seconds; `duration` -1 = until reopened).
struct MuteInfo: Equatable, Sendable {
    var startTime: TimeInterval
    var duration: TimeInterval

    var isIndefinite: Bool { duration < 0 }
    var until: Date? { isIndefinite ? nil : Date(timeIntervalSince1970: startTime + duration) }

    func isActive(at now: Date = .now) -> Bool {
        guard let until else { return true }
        return until > now
    }

    private func formattedTimeParts(now: Date, calendar: Calendar) -> (hhMm: String?, ddMm: String?) {
        guard let until else { return (nil, nil) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "vi_VN")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        let hm = formatter.string(from: until)
        if calendar.isDate(until, inSameDayAs: now) {
            return (hm, nil)
        }
        formatter.dateFormat = "dd/MM"
        return (hm, formatter.string(from: until))
    }

    /// "Cho đến 14:30" / "Cho đến khi được mở lại" (delegated to `OlazCore.muteInfoFormatDescription`).
    func description(now: Date = .now, calendar: Calendar = .current) -> String {
        let parts = formattedTimeParts(now: now, calendar: calendar)
        return OlazCore.muteInfoFormatDescription(
            startTime: startTime,
            duration: duration,
            hhMm: parts.hhMm,
            ddMmIfOtherDay: parts.ddMm
        )
    }

    /// Menu status line: "Đang tắt đến 14:30" / "Đang tắt đến 14:30 ngày 27/10" / "Đang tắt cho đến khi được mở lại".
    func statusText(now: Date = .now, calendar: Calendar = .current) -> String {
        let parts = formattedTimeParts(now: now, calendar: calendar)
        return OlazCore.muteInfoFormatStatusText(
            startTime: startTime,
            duration: duration,
            hhMm: parts.hhMm,
            ddMmIfOtherDay: parts.ddMm
        )
    }

    static func parse(_ json: [String: Any]) -> (id: String, info: MuteInfo)? {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        let start = (json["startTime"] as? NSNumber)?.doubleValue ?? 0
        let duration = (json["duration"] as? NSNumber)?.doubleValue ?? -1
        return (id, MuteInfo(startTime: start, duration: duration))
    }
}

internal struct NotifyBannerRecord: Equatable, Sendable {
    var title: String
    var body: String
    var convId: String
    var senderId: String
    var senderName: String
    var isGroup: Bool
    var avatarURL: String?
    var silent: Bool
}

/// Notification preferences mirrored from `olaz-core` (`DirtyKey::NotificationSettings`).
struct NotificationSettingsState: Equatable {
    enum Authorization: String, Equatable, Sendable {
        case unknown
        case unavailable
        case notDetermined, denied, authorized

        init(coreRecord: NotifAuthorizationRecord) {
            switch coreRecord {
            case .unknown: self = .unknown
            case .unavailable: self = .unavailable
            case .notDetermined: self = .notDetermined
            case .denied: self = .denied
            case .authorized: self = .authorized
            }
        }

        var coreRecord: NotifAuthorizationRecord {
            switch self {
            case .unknown: .unknown
            case .unavailable: .unavailable
            case .notDetermined: .notDetermined
            case .denied: .denied
            case .authorized: .authorized
            }
        }
    }

    static let previewDefaultsKey = "olaz.notifications.showsPreview"

    var isLoaded = false
    var enabled = true
    var sound = false
    var hasSoundSetting = false
    var showsPreview = UserDefaults.standard.object(forKey: previewDefaultsKey) as? Bool ?? true
    var authorization: Authorization = .unknown
    var mutes: [String: MuteInfo] = [:]

    func mute(for conversationId: String, now: Date = .now) -> MuteInfo? {
        guard let mute = mutes[conversationId], mute.isActive(at: now) else { return nil }
        return mute
    }

    func isMuted(_ conversationId: String, now: Date = .now) -> Bool { mute(for: conversationId, now: now) != nil }

    func activeMutes(now: Date = .now) -> [(id: String, info: MuteInfo)] {
        mutes.filter { $0.value.isActive(at: now) }
            .map { (id: $0.key, info: $0.value) }
            .sorted { ($0.info.startTime, $0.id) < ($1.info.startTime, $1.id) }
    }

    mutating func apply(settings json: [String: Any]) {
        isLoaded = true
        if let value = json["enabled"] as? NSNumber { enabled = value.boolValue }
        if let value = json["sound"] as? NSNumber { sound = value.boolValue }
        if let value = json["hasSoundSetting"] as? NSNumber { hasSoundSetting = value.boolValue }
        var next: [String: MuteInfo] = [:]
        for entry in json["mutes"] as? [[String: Any]] ?? [] {
            if let parsed = MuteInfo.parse(entry) { next[parsed.id] = parsed.info }
        }
        mutes = next
    }

    mutating func applyCoreRecord(_ record: NotificationSettingsRecord) {
        isLoaded = record.isLoaded
        enabled = record.enabled
        sound = record.sound
        hasSoundSetting = record.hasSoundSetting
        showsPreview = record.showsPreview
        authorization = Authorization(coreRecord: record.authorization)
        var next: [String: MuteInfo] = [:]
        next.reserveCapacity(record.mutes.count)
        for entry in record.mutes {
            next[entry.id] = MuteInfo(startTime: entry.startTime, duration: entry.duration)
        }
        mutes = next
    }
}

extension ZaloEngine {
    // MARK: Actions — settings (thin `CoreEngine` forwarders)

    func setNotificationsEnabled(_ enabled: Bool) {
        notificationSettings.enabled = enabled
        notificationSettings.sound = enabled
        notificationSettings.hasSoundSetting = true
        trackNotificationTask { [weak self] in
            guard let self, let core = await self.ensureCoreEngine() else { return }
            if let v = try? await core.setNotificationsEnabledAndWait(enabled: enabled) {
                await self.waitForMirrorVersion(v)
            }
        }
    }

    func setNotificationSound(_ enabled: Bool) {
        notificationSettings.sound = enabled
        notificationSettings.hasSoundSetting = true
        trackNotificationTask { [weak self] in
            guard let self, let core = await self.ensureCoreEngine() else { return }
            if let v = try? await core.setNotificationSoundAndWait(enabled: enabled) {
                await self.waitForMirrorVersion(v)
            }
        }
    }

    func setMessagePreview(_ shown: Bool) {
        notificationSettings.showsPreview = shown
        userDefaults.set(shown, forKey: NotificationSettingsState.previewDefaultsKey)
        if let core = coreLifecycle.core {
            core.setMessagePreview(shown: shown)
        }
    }

    func notificationSettingsDidAppear() {
        trackNotificationTask { [weak self] in
            await self?.refreshNotificationAuthorization()
        }
    }

    // MARK: Actions — per-conversation mute (server-confirmed via `olaz-core`)

    func isConversationMuted(_ id: String) -> Bool {
        notificationSettings.isMuted(id, now: Date(timeIntervalSince1970: Double(nowMs()) / 1000.0))
    }

    func muteConversation(_ id: String, _ duration: MuteDuration) {
        let currentMs = nowMs()
        let now = Date(timeIntervalSince1970: Double(currentMs) / 1000.0)
        let until = duration.expiry(from: now, calendar: notificationCalendar)
        let sec = Int64(until.map { Int($0.timeIntervalSince(now)) } ?? -1)
        trackNotificationTask { [weak self] in
            guard let self, let core = await self.ensureCoreEngine() else { return }
            if let v = try? await core.muteConversationAndWait(
                convId: id,
                durationSecs: sec,
                nowMs: currentMs
            ) {
                await self.waitForMirrorVersion(v)
            }
        }
    }

    func unmuteConversation(_ id: String) {
        let currentMs = nowMs()
        trackNotificationTask { [weak self] in
            guard let self, let core = await self.ensureCoreEngine() else { return }
            if let v = try? await core.unmuteConversationAndWait(convId: id, nowMs: currentMs) {
                await self.waitForMirrorVersion(v)
            }
        }
    }

    // MARK: SQLite persistence

    internal func loadNotificationPreferences(from store: ZaloSQLiteStore) async {
        if let core = await ensureCoreEngine() {
            core.attachStore(store: store.coreStoreHandle)
            if let v = try? await core.loadNotificationPreferences() {
                await waitForMirrorVersion(v)
            }
            return
        }
        var next = notificationSettings
        next.isLoaded = true
        next.enabled = (try? await store.getPreferenceBool(key: "notifEnabled", default: true)) ?? true
        next.sound = (try? await store.getPreferenceBool(key: "notifSound", default: true)) ?? true
        next.hasSoundSetting = true
        if let data = try? await store.getPreferenceData(key: "mutedThreads"),
           let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            var mutes: [String: MuteInfo] = [:]
            for row in rows {
                if let parsed = MuteInfo.parse(row) { mutes[parsed.id] = parsed.info }
            }
            next.mutes = mutes
        }
        notificationSettings = next
    }

    internal func saveNotificationPreferences() async {
        guard let store = sqliteStore else { return }
        try? await store.setPreferenceBool(key: "notifEnabled", value: notificationSettings.enabled)
        try? await store.setPreferenceBool(key: "notifSound", value: notificationSettings.sound)
        let serialized: [[String: Any]] = notificationSettings.mutes.map { id, info in
            ["id": id, "startTime": info.startTime, "duration": info.duration]
        }
        if let data = try? JSONSerialization.data(withJSONObject: serialized) {
            try? await store.setPreferenceData(key: "mutedThreads", data: data)
        }
    }

    // MARK: macOS authorization

    @discardableResult
    func requestNotificationAuthorization() async -> NotificationSettingsState.Authorization {
        let mapped: NotificationSettingsState.Authorization
        if !traceNotifyHost("request_notif_auth"), let handler = requestNotifAuthHostHandler {
            mapped = await handler()
        } else {
            let result = await NativeNotifier.shared.requestAuthorization()
            mapped = Self.mapNativeAuthorization(result)
        }
        if notificationSettings.authorization != mapped {
            notificationSettings.authorization = mapped
        }
        coreLifecycle.core?.setInitialNotificationAuth(auth: mapped.coreRecord)
        return notificationSettings.authorization
    }

    func refreshNotificationAuthorization() async {
        let mapped = Self.mapNativeAuthorization(await NativeNotifier.shared.authorizationStatus())
        if notificationSettings.authorization != mapped {
            notificationSettings.authorization = mapped
        }
        coreLifecycle.core?.setInitialNotificationAuth(auth: mapped.coreRecord)
    }

    func openSystemNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func mapNativeAuthorization(_ status: NativeNotifier.Authorization) -> NotificationSettingsState.Authorization {
        switch status {
        case .unavailable: .unavailable
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        }
    }

    // MARK: Adapter settings payload

    func handleNotification(state: [String: Any]) {
        guard let payload = state["notification"] as? [String: Any],
              payload["kind"] as? String == "settings" else { return }
        var next = notificationSettings
        next.apply(settings: payload)
        if next != notificationSettings { notificationSettings = next }
        if let core = coreLifecycle.core {
            core.handleNotificationSettingsPayload(payloadJson: Self.jsonString(for: payload))
        }
    }
}
