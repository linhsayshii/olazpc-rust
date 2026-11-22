import AppKit
import ImageIO
import UniformTypeIdentifiers

// Native composer "+" actions — Ảnh hoặc Video, Tệp, Danh thiếp, Nhắc hẹn.
// Screenshots are handled natively via macOS clipboard paste (⌘V).

/// Result of a composer action.
enum ComposerOutcome: Equatable, Sendable {
    case done
    /// Nothing was picked, or the official client already said why (its toast reached the screen).
    case cancelled
    case failed(String)
    /// Started but not answered in time: it may still happen, so the wording never invites a retry.
    case pending(String)

    static let genericFailure = "Không gửi được. Hãy thử lại."

    init(json: Any?) {
        guard let root = json as? [String: Any], let status = root["status"] as? String else {
            self = .failed(Self.genericFailure)
            return
        }
        let text = (root["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch status {
        case "done": self = .done
        case "cancelled": self = .cancelled
        case "invalid": self = text.map(Self.failed) ?? .cancelled
        case "pending": self = .pending(text ?? CardActionOutcome.defaultPending)
        case "not-open": self = .failed("Cuộc trò chuyện chưa sẵn sàng, hãy thử lại sau giây lát.")
        case "not-ready": self = .failed("Zalo chưa sẵn sàng, hãy thử lại sau giây lát.")
        default: self = .failed(text ?? Self.genericFailure)
        }
    }

    var logName: String {
        switch self {
        case .done: "done"
        case .cancelled: "cancelled"
        case .failed: "failed"
        case .pending: "pending"
        }
    }
}

/// An official confirm asked while a composer action ran (e.g. "Gửi dưới dạng file" for a photo over the limit).
struct ComposerConfirm: Identifiable, Equatable {
    let id: String
    var conversationId: String
    var title: String
    var message: String
    var ok: String
    var cancel: String
}

/// "Chia sẻ" from the screenshot tool: the shot (or its recognised text) waiting for the conversations to send it to.
struct ScreenshotShare: Identifiable, Equatable {
    let id = UUID()
    var image: URL?
    var text: String?
    var conversationId: String
}

/// My own contact card as the official "Gửi danh thiếp" modal would send it.
struct MyCardInfo: Equatable {
    var uid: String
    var name: String
    var avatar: URL?
    /// Display form of my number (official `getPhoneNumberPro`), "" when the profile has none.
    var phone: String
    /// The official "Gửi kèm số điện thoại" choice remembered for this account.
    var withPhone: Bool

    init?(json: Any?) {
        guard let row = json as? [String: Any], let uid = row["uid"] as? String, !uid.isEmpty else { return nil }
        self.uid = uid
        name = row["name"] as? String ?? ""
        avatar = (row["avatar"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        phone = row["phone"] as? String ?? ""
        withPhone = row["withPhone"] as? Bool ?? true
    }
}

/// What the official chat-bar gate and compose modal allow for a conversation.
struct ReminderComposeInfo: Equatable {
    var allowed: Bool
    /// OA conversations have no "Nhắc hẹn" item at all.
    var hidden: Bool
    /// Why it is not allowed (official warning), "" when there is nothing to say.
    var text: String
    var isGroup: Bool
    /// Group reminders are pinned (official default) when I may pin; `pinToggle` = the modal shows the checkbox.
    var canPin: Bool
    var pinToggle: Bool
    var titleMaxChars: Int
    var titleMaxBytes: Int

    init?(json: Any?) {
        guard let row = json as? [String: Any] else { return nil }
        allowed = row["allowed"] as? Bool ?? false
        hidden = row["hidden"] as? Bool ?? false
        text = row["text"] as? String ?? ""
        isGroup = row["isGroup"] as? Bool ?? false
        canPin = row["canPin"] as? Bool ?? false
        pinToggle = row["pinToggle"] as? Bool ?? false
        titleMaxChars = (row["titleMaxChars"] as? NSNumber)?.intValue ?? 3000
        titleMaxBytes = (row["titleMaxBytes"] as? NSNumber)?.intValue ?? 3700
    }

    /// Official limits: fewer than `titleMaxChars` UTF-16 units of raw text and at most `titleMaxBytes` UTF-8 bytes trimmed.
    func titleTooLong(_ raw: String) -> Bool {
        raw.utf16.count >= titleMaxChars || raw.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count > titleMaxBytes
    }
}

/// Repeat choices of the legacy compose modal (the weekday picker, 4, is not reachable there).
enum ReminderRepeat: Int, CaseIterable, Identifiable {
    case none = 0, daily, weekly, monthly
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .none: "Không lặp lại"
        case .daily: "Hàng ngày"
        case .weekly: "Hàng tuần"
        case .monthly: "Hàng tháng"
        }
    }
}

extension ZaloEngine {
    // MARK: Attachments

    func sendMedia(_ urls: [URL], to id: String) async -> ComposerOutcome {
        guard !urls.isEmpty, !id.isEmpty else { return .cancelled }
        var sentAny = false
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let utType = UTType(filenameExtension: url.pathExtension)
            let isImage = utType?.conforms(to: .image) ?? false
            do {
                if isImage {
                    let dims = imageDimensions(data)
                    let res = try await sessionClient.uploadAndSendPhoto(
                        convId: id, fileName: url.lastPathComponent, data: data, width: dims.width, height: dims.height
                    )
                    await recordUploadedMessage(
                        convId: id, msgId: res.msgId, cliId: res.cliMsgId,
                        kind: .photo(url: URL(string: res.url), width: res.width, height: res.height),
                        text: ""
                    )
                } else {
                    let res = try await sessionClient.uploadAndSendFile(
                        convId: id, fileName: url.lastPathComponent, data: data, webSocket: webSocket
                    )
                    await recordUploadedMessage(
                        convId: id, msgId: res.msgId, cliId: res.cliMsgId,
                        kind: .file(name: url.lastPathComponent, size: Int64(data.count), url: URL(string: res.url)),
                        text: url.lastPathComponent
                    )
                }
                sentAny = true
            } catch {
                EngineLog.shared.write("sendMedia failed: \(error.localizedDescription)")
            }
        }
        return sentAny ? .done : .failed(ComposerOutcome.genericFailure)
    }

    func sendFiles(_ urls: [URL], to id: String) async -> ComposerOutcome {
        guard !urls.isEmpty, !id.isEmpty else { return .cancelled }
        var sentAny = false
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                let res = try await sessionClient.uploadAndSendFile(
                    convId: id, fileName: url.lastPathComponent, data: data, webSocket: webSocket
                )
                await recordUploadedMessage(
                    convId: id, msgId: res.msgId, cliId: res.cliMsgId,
                    kind: .file(name: url.lastPathComponent, size: Int64(data.count), url: URL(string: res.url)),
                    text: url.lastPathComponent
                )
                sentAny = true
            } catch {
                EngineLog.shared.write("sendFiles failed: \(error.localizedDescription)")
            }
        }
        return sentAny ? .done : .failed(ComposerOutcome.genericFailure)
    }

    private func imageDimensions(_ data: Data) -> (width: Int, height: Int) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            return (800, 600)
        }
        return (w, h)
    }

    private func recordUploadedMessage(convId: String, msgId: String, cliId: String, kind: ChatMessage.Kind, text: String) async {
        let msg = ChatMessage(
            id: msgId,
            conversationId: convId,
            senderId: profile?.userId ?? "",
            senderName: profile?.displayName ?? "Bạn",
            senderAvatar: profile?.avatar,
            isMine: true,
            kind: kind,
            text: text,
            date: Date(),
            status: .sent,
            quote: nil,
            reactions: [],
            isE2EE: false,
            mentions: [],
            cardButtons: [],
            suggestsStickers: false,
            menu: MessageMenu(json: ["forward": "ok", "recall": true, "delete": "forMe", "pin": ZaloWireParser.isGroupId(convId), "star": "star"])
        )
        mergeMessageIntoMemory(msg)
        if let stored = ZaloWireParser.encodeChatMessage(msg, clientId: cliId) {
            try? await sqliteStore?.saveMessages([stored])
        }
        updateConversationOnMessage(msg, incrementUnread: false)
    }

    // MARK: Danh thiếp

    func myCard() async -> MyCardInfo? {
        guard let profile else { return nil }
        return MyCardInfo(json: [
            "uid": profile.userId,
            "name": profile.displayName,
            "avatar": profile.avatar?.absoluteString ?? "",
            "phone": profile.phone ?? "",
            "withPhone": !(profile.phone?.isEmpty ?? true)
        ])
    }

    func sendMyCard(to id: String, withPhone: Bool) async -> ComposerOutcome {
        guard let profile else { return .failed("Chưa đăng nhập.") }
        do {
            let res = try await sessionClient.sendContactCardAPI(
                convId: id,
                cardUid: profile.userId,
                phone: withPhone ? profile.phone : nil
            )
            let card = ChatMessage.ContactCard(
                name: profile.displayName,
                uid: profile.userId,
                avatar: profile.avatar,
                phone: withPhone ? (profile.phone ?? "") : ""
            )
            await recordUploadedMessage(
                convId: id, msgId: res.msgId, cliId: res.cliMsgId,
                kind: .contactCard(card), text: "[Danh thiếp] \(profile.displayName)"
            )
            return .done
        } catch {
            return .failed(ComposerOutcome.genericFailure)
        }
    }

    // MARK: Nhắc hẹn

    func reminderComposeInfo(for id: String) async -> ReminderComposeInfo? {
        let isGroup = ZaloWireParser.isGroupId(id)
        return ReminderComposeInfo(json: [
            "allowed": id != selfConversationId,
            "hidden": false,
            "text": "",
            "isGroup": isGroup,
            "canPin": isGroup,
            "pinToggle": isGroup,
            "titleMaxChars": 3000,
            "titleMaxBytes": 3700
        ])
    }

    func createReminder(in id: String, title: String, start: Date, repeat rule: ReminderRepeat, pin: Bool) async -> ComposerOutcome {
        do {
            _ = try await sessionClient.createReminderAPI(
                convId: id,
                title: title,
                startTimeMs: Int64((start.timeIntervalSince1970 * 1000).rounded()),
                repeatMode: rule.rawValue,
                pin: pin
            )
            return .done
        } catch {
            return .failed("Không tạo được nhắc hẹn. Hãy thử lại.")
        }
    }

    // MARK: Confirms / Toasts

    func answerComposerConfirm(_ confirm: ComposerConfirm, ok: Bool) {
        guard composerConfirm?.id == confirm.id else { return }
        composerConfirm = nil
        guard !queuedComposerConfirms.isEmpty else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, self.composerConfirm == nil, !self.queuedComposerConfirms.isEmpty else { return }
            self.composerConfirm = self.queuedComposerConfirms.removeFirst()
        }
    }

    func dropComposerConfirms() {
        composerConfirm = nil
        queuedComposerConfirms = []
    }

    func handleCompose(state: [String: Any]) {
        guard let event = state["compose"] as? [String: Any] else { return }
        let conversation = (event["convId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if event["kind"] as? String == "toast", let text = event["text"] as? String, !text.isEmpty {
            CardActionCenter.shared.show(text, in: conversation)
        }
    }

    func resetComposer() {
        dropComposerConfirms()
    }

    func report(_ outcome: ComposerOutcome, in id: String) {
        switch outcome {
        case .failed(let text), .pending(let text): CardActionCenter.shared.show(text, in: id.isEmpty ? nil : id)
        case .done, .cancelled: break
        }
    }
}
