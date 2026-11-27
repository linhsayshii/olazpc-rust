import AVFoundation
import AppKit
import ImageIO
import OlazCore
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

struct VideoMetadata: Sendable, Equatable {
    var durationMs: Int
    var width: Int
    var height: Int
    var thumbnailData: Data
}

struct OutgoingFileProbeResult: Sendable {
    var exists: Bool = true
    var isDirectory: Bool = false
    var readable: Bool = true
    var size: Int64 = 0
    var mediaType: String? = nil
    var data: Data = Data()
}

extension ZaloEngine {
    // MARK: Attachments

    nonisolated static func isVideoUTType(_ utType: UTType?) -> Bool {
        guard let utType else { return false }
        return utType.conforms(to: .movie)
            || utType.conforms(to: .video)
            || utType.conforms(to: .mpeg4Movie)
            || utType.conforms(to: .quickTimeMovie)
    }

    nonisolated static func isVideoURL(_ url: URL) -> Bool {
        if isVideoUTType(UTType(filenameExtension: url.pathExtension)) {
            return true
        }
        if url.pathExtension.isEmpty && url.isFileURL {
            return VideoPoster.isVideo(url)
        }
        return false
    }

    nonisolated static func extractVideoMetadata(from url: URL) async -> VideoMetadata {
        let asset: AVURLAsset = {
            if url.isFileURL, url.pathExtension.isEmpty, let mime = VideoPoster.mimeType(of: url) {
                return AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: mime])
            }
            return AVURLAsset(url: url)
        }()

        let durationSeconds = (try? await asset.load(.duration).seconds) ?? 0
        let durationMs = (durationSeconds.isFinite && durationSeconds > 0)
            ? Int((durationSeconds * 1000).rounded())
            : 0

        var width = 0
        var height = 0
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (naturalSize, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
            width = max(0, Int(abs(rect.width).rounded()))
            height = max(0, Int(abs(rect.height).rounded()))
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        let targetSeconds = durationMs > 0 ? min(0.1, Double(durationMs) / 2000.0) : 0
        let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)

        let cgImage: CGImage?
        if let first = try? await generator.image(at: targetTime) {
            cgImage = first.image
        } else if targetSeconds > 0, let fallback = try? await generator.image(at: .zero) {
            cgImage = fallback.image
        } else {
            cgImage = nil
        }

        var thumbnailData = Data()
        if let cgImage {
            if width == 0 || height == 0 {
                width = cgImage.width
                height = cgImage.height
            }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            thumbnailData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) ?? Data()
        }

        return VideoMetadata(
            durationMs: durationMs,
            width: width,
            height: height,
            thumbnailData: thumbnailData
        )
    }

    func sendMedia(_ urls: [URL], to id: String) async -> ComposerOutcome {
        if let sendMediaHostHandler {
            let args: [String: Any] = [
                "conv_id": id,
                "paths": urls.map(\.path),
            ]
            _ = traceHost("send_media", args: args)
            return await sendMediaHostHandler(args)
        }
        guard let core = await ensureCoreEngine() else {
            return .failed(ComposerOutcome.genericFailure)
        }
        if !ZaloWireParser.isGroupId(id) {
            let loaded = await e2eeManager.hasLoadedPersistedThreads()
            let threads = e2eeManager.e2eeThreadIdsSync()
            if loaded || !threads.isEmpty {
                core.setE2eeThreads(threads: threads)
            }
        }
        let outcome = await core.sendMediaCore(
            convId: id,
            paths: urls.map(\.path),
            nowMs: nowMs()
        )
        await waitForCoreMirrorDrain()
        return ComposerOutcome(coreRecord: outcome)
    }

    nonisolated static func validateOutgoingFile(_ url: URL, maxBytes: Int64) -> String? {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let vals = exists
            ? (try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]))
            : nil
        let probe = OutgoingFileProbeRecord(
            exists: exists && vals != nil,
            isDir: isDir.boolValue || (vals?.isDirectory == true),
            readable: true,
            size: Int64(vals?.fileSize ?? 0),
            mediaType: nil
        )
        return mediaValidateOutgoingFileProbe(
            name: url.lastPathComponent,
            probe: probe,
            maxBytes: maxBytes
        )
    }

    func sendFiles(_ urls: [URL], to id: String) async -> ComposerOutcome {
        if let sendFilesHostHandler {
            let args: [String: Any] = [
                "conv_id": id,
                "paths": urls.map(\.path),
            ]
            _ = traceHost("send_files", args: args)
            return await sendFilesHostHandler(args)
        }
        guard let core = await ensureCoreEngine() else {
            return .failed(ComposerOutcome.genericFailure)
        }
        if !ZaloWireParser.isGroupId(id) {
            let loaded = await e2eeManager.hasLoadedPersistedThreads()
            let threads = e2eeManager.e2eeThreadIdsSync()
            if loaded || !threads.isEmpty {
                core.setE2eeThreads(threads: threads)
            }
        }
        if let fileLimit = cloud.plan?.fileLimit {
            core.seedMediaCloudFileLimit(limit: fileLimit)
        }
        let outcome = await core.sendFilesCore(
            convId: id,
            paths: urls.map(\.path),
            nowMs: nowMs()
        )
        await waitForCoreMirrorDrain()
        return ComposerOutcome(coreRecord: outcome)
    }

    nonisolated internal static func computeImageDimensions(_ data: Data) -> (width: Int, height: Int) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            return (800, 600)
        }
        return (w, h)
    }

    internal func recordUploadedMessage(
        convId: String,
        msgId: String,
        cliId: String,
        kind: ChatMessage.Kind,
        text: String,
        isE2EE: Bool = false
    ) async {
        let isSelf = (convId == selfConversationId)
        let msg = ChatMessage(
            id: msgId,
            conversationId: convId,
            senderId: profile?.userId ?? "",
            senderName: profile?.displayName ?? "Bạn",
            senderAvatar: profile?.avatar,
            isMine: true,
            kind: kind,
            text: text,
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
                "recall": !isSelf,
                "delete": isSelf ? "plain" : "forMe",
                "pin": ZaloWireParser.isGroupId(convId) && !isSelf,
                "star": "star"
            ]),
            clientId: cliId
        )
        mergeMessageIntoMemory(msg, replacingClientId: cliId)
        if let stored = ZaloWireParser.encodeChatMessage(msg, clientId: cliId) {
            try? await sqliteStore?.saveMessages([stored])
        }
        updateConversationOnMessage(msg, incrementUnread: false)
    }

    // MARK: Danh thiếp

    func myCard() async -> MyCardInfo? {
        guard let core = await ensureCoreEngine() else { return nil }
        guard let rec = try? await core.myCard() else { return nil }
        return MyCardInfo(coreRecord: rec)
    }

    func sendMyCard(to id: String, withPhone: Bool) async -> ComposerOutcome {
        guard let core = await ensureCoreEngine() else {
            return .failed(ComposerOutcome.genericFailure)
        }
        let isE2EE: Bool = ZaloWireParser.isGroupId(id)
            ? false
            : await e2eeManager.isE2EEConversation(id)
        let tsMs = nowMs()
        do {
            let outcome = try await core.sendMyCard(
                convId: id,
                withPhone: withPhone,
                clientId: nil,
                nowMs: tsMs,
                isE2ee: isE2EE
            )
            await waitForCoreMirrorDrain()
            return ComposerOutcome(coreRecord: outcome)
        } catch {
            return .failed(ComposerOutcome.genericFailure)
        }
    }

    // MARK: Nhắc hẹn

    func reminderComposeInfo(for id: String) async -> ReminderComposeInfo? {
        guard let core = await ensureCoreEngine() else { return nil }
        guard let rec = try? await core.reminderComposeInfo(convId: id) else { return nil }
        return ReminderComposeInfo(coreRecord: rec)
    }

    func createReminder(in id: String, title: String, start: Date, repeat rule: ReminderRepeat, pin: Bool) async -> ComposerOutcome {
        guard let core = await ensureCoreEngine() else {
            return .failed("Không tạo được nhắc hẹn. Hãy thử lại.")
        }
        let startMs = Int64((start.timeIntervalSince1970 * 1000).rounded())
        do {
            let outcome = try await core.createReminder(
                convId: id,
                title: title,
                startMs: startMs,
                repeatMode: Int64(rule.rawValue),
                pin: pin
            )
            return ComposerOutcome(coreRecord: outcome)
        } catch {
            return .failed("Không tạo được nhắc hẹn. Hãy thử lại.")
        }
    }

    // MARK: Confirms / Toasts

    func answerComposerConfirm(_ confirm: ComposerConfirm, ok: Bool) {
        guard composerConfirm?.id == confirm.id else { return }
        composerConfirm = nil
        if !isApplyingCoreMirror {
            coreLifecycle.core?.answerComposerConfirm(confirmId: confirm.id, ok: ok)
        }
    }

    func dropComposerConfirms() {
        composerConfirmTask?.cancel()
        composerConfirmTask = nil
        composerConfirm = nil
        queuedComposerConfirms = []
        if !isApplyingCoreMirror {
            coreLifecycle.core?.dropComposerConfirms()
        }
    }

    func handleCompose(state: [String: Any]) {
        guard let event = state["compose"] as? [String: Any] else { return }
        let conversation = (event["convId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if event["kind"] as? String == "toast", let text = event["text"] as? String, !text.isEmpty {
            showActionCard(text, in: conversation)
        }
    }

    func resetComposer() {
        composerConfirmTask?.cancel()
        composerConfirmTask = nil
        composerConfirm = nil
        queuedComposerConfirms = []
        if !isApplyingCoreMirror {
            coreLifecycle.core?.resetComposer()
        }
    }

    func report(_ outcome: ComposerOutcome, in id: String) {
        switch outcome {
        case .failed(let text), .pending(let text): showActionCard(text, in: id.isEmpty ? nil : id)
        case .done, .cancelled: break
        }
    }
}
