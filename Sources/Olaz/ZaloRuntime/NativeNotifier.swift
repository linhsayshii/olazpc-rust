import AppKit
import Observation
import UniformTypeIdentifiers
@preconcurrency import UserNotifications
import os

private let notifierLog = Logger(subsystem: "app.olaz", category: "notifications")

// MARK: - Pure logic (unit tested in NotificationTests.swift)

/// What the official renderer hands to `$znoti.createNotification(title, options)` — Electron's
/// `Notification` constructor arguments (`HostScripts/notification-adapter.js` forwards the web
/// `Notification(title, {body, icon, tag, silent})` of the official OOAN notifier unchanged).
struct NativeNotificationRequest: Equatable {
    enum Icon: Equatable {
        /// `https://…` avatar (1-1 contact).
        case remote(URL)
        /// `data:image/png;base64,…` (group mosaics are rendered to a canvas by the official code).
        case inline(Data)
        /// Relative asset of the client bundle, e.g. `assets/avatar_stranger_notif.<hash>.png`.
        case bundled(String)
    }

    var title: String
    var body: String
    /// Conversation id (`fromUid` for 1-1, `g…` for groups): the official click handler opens it.
    var tag: String
    var silent: Bool
    var icon: Icon?

    static func parse(_ args: [Any]) -> NativeNotificationRequest? {
        let title = args.string(0) ?? ""
        let options = args.dict(1) ?? [:]
        let body = options["body"] as? String ?? ""
        guard !title.isEmpty || !body.isEmpty else { return nil }
        let tag: String
        switch options["tag"] {
        case let text as String: tag = text
        case let number as NSNumber: tag = number.stringValue
        default: tag = ""
        }
        return NativeNotificationRequest(
            title: title, body: body, tag: tag,
            silent: (options["silent"] as? NSNumber)?.boolValue ?? false,
            icon: (options["icon"] as? String).flatMap(parseIcon)
        )
    }

    static func parseIcon(_ raw: String) -> Icon? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if text.hasPrefix("data:") {
            guard let comma = text.firstIndex(of: ","), text[..<comma].contains(";base64"),
                  let data = Data(base64Encoded: String(text[text.index(after: comma)...])), !data.isEmpty else { return nil }
            return .inline(data)
        }
        if let url = URL(string: text), url.scheme == "https" || url.scheme == "http", url.host() != nil {
            return .remote(url)
        }
        if text.contains("://") { return nil }
        // Relative asset path (strip cache-busting query).
        let path = text.split(separator: "?", maxSplits: 1).first.map(String.init) ?? text
        return path.isEmpty ? nil : .bundled(path)
    }
}

enum NotificationPolicy {
    /// The official client also hides banners while the app is focused (FocusDetector). That detector
    /// is fed from the native window (`NativeNotifier.startFocusBridge`); this is the native backstop for
    /// the one case that must never notify: the user is looking at the very conversation the message is in.
    static func shouldSuppress(appIsActive: Bool, mainWindowVisible: Bool, openConversation: String?,
                               tag: String, userIdleSeconds: TimeInterval, idleThreshold: TimeInterval = 180) -> Bool {
        guard appIsActive, mainWindowVisible, !tag.isEmpty, openConversation == tag else { return false }
        return userIdleSeconds < idleThreshold
    }

    /// The banner's inline "Trả lời" must not send into a hidden chat that is locked, nor while the hidden state is still unknown.
    static func refusesReply(hiddenStateKnown: Bool, conversationLocked: Bool) -> Bool { !hiddenStateKnown || conversationLocked }

    /// Conversations that became hidden between two snapshots (their delivered banners are removed).
    static func newlyHidden(old: Set<String>, new: Set<String>) -> Set<String> { new.subtracting(old) }

    /// Official text for a message whose content must stay hidden (app lock: `STR_PASS_CODE_NOTIFY_MESSAGE`).
    static let hiddenPreviewBody = "Bạn có tin nhắn mới"

    static func body(_ body: String, showsPreview: Bool) -> String { showsPreview ? body : hiddenPreviewBody }

    /// Image type UNNotificationAttachment accepts, sniffed from the bytes (the CDN URLs have no extension).
    static func attachmentType(for data: Data) -> (type: UTType, ext: String)? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return (.png, "png") }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return (.jpeg, "jpg") }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return (.gif, "gif") }
        return nil
    }

    /// Only Zalo CDN hosts over https may be fetched for the notification sound.
    static func isSoundURLAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host() else { return false }
        return MediaLoader.isZaloCDN(host) && url.path().hasSuffix("/sound/noti.mp3")
    }
}

// MARK: - UNUserNotificationCenter bridge

/// Renders the official client's notifications as native macOS banners.
///
/// The official renderer decides when to notify (settings, mutes, app focus…) and calls
/// `$znoti.createNotification` / `closeNotification` (channels `_noti_*`, installed on the bridge by
/// `ZaloMainProcess`). This class answers them with `UNUserNotificationCenter` and pushes `_noti_on-show`
/// / `_noti_on-click` / `_noti_on-close` back so the official callbacks run (open conversation, timers).
@MainActor
final class NativeNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NativeNotifier()

    static let messageCategory = "app.olaz.message"
    static let replyAction = "app.olaz.message.reply"
    /// Title of the development renderer window — never the user-facing window.
    private static let debugWindowTitle = "Zalo renderer (debug)"

    weak var engine: ZaloEngine?

    private var focusObservers: [NSObjectProtocol] = []
    private var sounds: [NSSound] = []
    private var attached = false
    private var orphanDrafts = FailedDraftStore()
    private var knownHidden: Set<String> = []

    /// `UNUserNotificationCenter.current()` traps outside an app bundle (tests, `swift run`, probe).
    var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }
    private var center: UNUserNotificationCenter? { isAvailable ? UNUserNotificationCenter.current() : nil }

    // MARK: Native delivery

    func notifyIncomingMessage(title: String, body: String, conversationId: String, avatarURL: URL?, silent: Bool) {
        guard isAvailable, !title.isEmpty || !body.isEmpty else { return }
        let request = NativeNotificationRequest(
            title: title,
            body: body,
            tag: conversationId,
            silent: silent,
            icon: avatarURL.map { .remote($0) }
        )
        let id = UUID().uuidString
        Task { await deliver(request, id: id) }
    }

    /// Drops the banners of a conversation the user has now opened.
    func clearDelivered(conversation id: String) {
        guard isAvailable, !id.isEmpty else { return }
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let ids = delivered.filter { $0.request.content.threadIdentifier == id }.map(\.request.identifier)
            if !ids.isEmpty { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    // MARK: Delivery

    private func deliver(_ request: NativeNotificationRequest, id: String) async {
        guard let center else { return }
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else {
            notifierLog.info("notification dropped: authorization \(status.rawValue)")
            return
        }
        if NotificationPolicy.shouldSuppress(
            appIsActive: NSApp?.isActive ?? false, mainWindowVisible: mainWindow()?.isVisible == true && mainWindow()?.isMiniaturized == false,
            openConversation: engine?.openConversationId, tag: request.tag, userIdleSeconds: Self.userIdleSeconds()) {
            notifierLog.info("notification suppressed: conversation is open and the app is in use")
            return
        }

        let showsPreview = UserDefaults.standard.object(forKey: NotificationSettingsState.previewDefaultsKey) as? Bool ?? true
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = NotificationPolicy.body(request.body, showsPreview: showsPreview)
        content.threadIdentifier = request.tag.isEmpty ? "zalo" : request.tag
        content.categoryIdentifier = Self.messageCategory
        content.userInfo = ["convId": request.tag, "id": id]
        if !request.silent { content.sound = .default }
        if let attachment = await avatarAttachment(for: request.icon) { content.attachments = [attachment] }

        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        } catch {
            notifierLog.error("add notification failed: \(error.localizedDescription, privacy: .public)")
            return
        }
    }

    private func avatarAttachment(for icon: NativeNotificationRequest.Icon?) async -> UNNotificationAttachment? {
        guard let icon else { return nil }
        let data: Data?
        switch icon {
        case .inline(let bytes): data = bytes
        case .bundled: data = nil
        case .remote(let url):
            data = await Self.withTimeout(seconds: 3) {
                guard let file = try? await MediaLoader.shared.localFile(for: url) else { return nil }
                return try? Data(contentsOf: file)
            } ?? nil
        }
        guard let data, let kind = NotificationPolicy.attachmentType(for: data) else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OlazNotifications", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(UUID().uuidString + "." + kind.ext)
        do {
            try data.write(to: file)
            // The center moves the file into its own store; remove stragglers if it did not.
            return try UNNotificationAttachment(identifier: "avatar", url: file,
                                                options: [UNNotificationAttachmentOptionsTypeHintKey: kind.type.identifier])
        } catch {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
    }

    private static func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: Authorization

    enum Authorization { case unavailable, notDetermined, denied, authorized }

    func authorizationStatus() async -> Authorization {
        guard let center else { return .unavailable }
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .authorized
        }
    }

    @discardableResult
    func requestAuthorization() async -> Authorization {
        guard let center else { return .unavailable }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            notifierLog.error("requestAuthorization failed: \(error.localizedDescription, privacy: .public)")
        }
        return await authorizationStatus()
    }

    private func postSendFailure(convId: String) async {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "Chưa gửi được tin nhắn trả lời"
        content.body = "Nội dung được giữ lại trong ô soạn thảo của hội thoại. Mở để gửi lại."
        content.threadIdentifier = convId
        content.userInfo = ["convId": convId]
        do { try await center.add(UNNotificationRequest(identifier: "sendfail-" + UUID().uuidString, content: content, trigger: nil)) }
        catch { notifierLog.error("send-failure notification failed: \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: Lifecycle

    /// Called when the main renderer reports `ready` (first and every later page load).
    func attach(engine: ZaloEngine) {
        self.engine = engine
        for (id, draft) in orphanDrafts.drain() { engine.failedDrafts.stash(draft, for: id) }
        guard isAvailable, !attached else { return }
        attached = true
        let reply = UNTextInputNotificationAction(
            identifier: Self.replyAction, title: "Trả lời", options: [],
            textInputButtonTitle: "Gửi", textInputPlaceholder: "Nhập tin nhắn…")
        let category = UNNotificationCategory(identifier: Self.messageCategory, actions: [reply], intentIdentifiers: [],
                                              options: [.hiddenPreviewsShowTitle])
        center?.setNotificationCategories([category])
        center?.delegate = self
        startFocusBridge()
        observeOpenConversation()
        observeHiddenConversations()
    }

    /// A chat that becomes hidden (here or on another device) takes its banners out of Notification Center.
    private func observeHiddenConversations() {
        guard let engine else { return }
        withObservationTracking {
            _ = engine.conversationActions.hiddenIds
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, let engine = self.engine else { return }
                let hidden = engine.conversationActions.hiddenIds
                for id in NotificationPolicy.newlyHidden(old: self.knownHidden, new: hidden) { self.clearDelivered(conversation: id) }
                self.knownHidden = hidden
                self.observeHiddenConversations()
            }
        }
    }

    private func observeOpenConversation() {
        guard let engine else { return }
        withObservationTracking {
            _ = engine.openConversationId
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if let id = self.engine?.openConversationId { self.clearDelivered(conversation: id) }
                self.observeOpenConversation()
            }
        }
    }

    func syncFocusState() {
        if NSApp?.isActive == true { Task { await engine?.refreshNotificationAuthorization() } }
    }

    private func startFocusBridge() {
        focusObservers = [
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                _ = MainActor.assumeIsolated {
                    Task { await self?.engine?.refreshNotificationAuthorization() }
                }
            }
        ]
    }

    // MARK: Sound (official `noti.mp3`, requested by the renderer's own sound rules)

    func playNotificationSound(_ raw: String) {
        guard let url = URL(string: raw), NotificationPolicy.isSoundURLAllowed(url) else { return }
        Task {
            guard let file = try? await MediaLoader.shared.localFile(for: url),
                  let sound = NSSound(contentsOf: file, byReference: true) else { return }
            sounds.removeAll { !$0.isPlaying }
            sounds.append(sound)
            sound.play()
        }
    }

    // MARK: Helpers

    /// The app's chat window: not the debug renderer, a panel, or the media viewer (which can be key and main too, but
    /// is not where messages are read, and must not be what "bring Olaz to the front" raises).
    private func mainWindow() -> NSWindow? {
        (NSApp?.windows ?? []).first { $0.canBecomeMain && !($0 is NSPanel) && !($0 is MediaViewerWindow) && $0.title != Self.debugWindowTitle }
    }

    func bringAppToFront() {
        NSApp?.activate()
        if let window = mainWindow() {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }

    nonisolated static func userIdleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let identifier = response.notification.request.identifier
        let convId = response.notification.request.content.userInfo["convId"] as? String ?? ""
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
            NativeNotifier.shared.handleResponse(id: identifier, convId: convId, action: action, text: text)
        }
    }

    private func handleResponse(id: String, convId: String, action: String, text: String?) {
        switch action {
        case Self.replyAction:
            if let text, !convId.isEmpty {
                Task {
                    // A locked hidden chat (or an unknown hidden state) is never written to from a banner: the text takes the failure path.
                    let refused = engine.map { NotificationPolicy.refusesReply(hiddenStateKnown: $0.conversationActions.hiddenKnown,
                                                                               conversationLocked: $0.isConversationLocked(convId)) } ?? true
                    if !refused, let engine, await engine.sendText(text, to: convId) { return }
                    let draft = ComposerDraft(text: text)
                    if let engine { engine.failedDrafts.stash(draft, for: convId) } else { orphanDrafts.stash(draft, for: convId) }
                    if !(NSApp?.isActive == true && engine?.openConversationId == convId) { await postSendFailure(convId: convId) }
                }
            }
        case UNNotificationDefaultActionIdentifier:
            bringAppToFront()
            if !convId.isEmpty { engine?.navigationRequest = convId }
            clearDelivered(conversation: convId)
        default:
            break
        }
    }
}
