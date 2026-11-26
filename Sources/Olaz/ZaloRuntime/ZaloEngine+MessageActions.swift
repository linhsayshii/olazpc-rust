import OlazCore
import AppKit

// Message context-menu actions — Chia sẻ, Copy, Thu hồi, Xóa chỉ ở phía tôi, Ghim tin nhắn, Đánh dấu tin nhắn — bridged to
// `HostScripts/message-actions-adapter.js` (`window.__zaloMsgActions`), which runs the official services and says which items each message
// gets (`ChatMessage.menu`). Copy is native (pasteboard). The pinned list of the open conversation arrives as `pins` states.

/// Result of a message action (message-actions-adapter.js `{status, text, …}`).
enum MessageActionOutcome: Equatable, Sendable {
    /// `text`: the official confirmation to show, if the official client shows one.
    case done(text: String?)
    /// The official client would ask first (delete confirm, "Cập nhật danh sách ghim").
    case confirm(title: String, message: String, ok: String, cancel: String, ref: String?)
    case failed(String)
    /// Started but not answered in time: it may still happen, so the wording never invites a retry.
    case pending(String)

    init(json: Any?, failure: String) {
        guard let root = json as? [String: Any], let status = root["status"] as? String else {
            self = .failed(failure)
            return
        }
        let text = (root["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch status {
        case "done": self = .done(text: text)
        case "confirm":
            self = .confirm(title: root["title"] as? String ?? "", message: root["message"] as? String ?? "",
                            ok: root["ok"] as? String ?? "OK", cancel: root["cancel"] as? String ?? "Hủy",
                            ref: (root["ref"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        case "pending": self = .pending(text ?? CardActionOutcome.defaultPending)
        case "not-ready": self = .failed(text ?? "Zalo chưa sẵn sàng, hãy thử lại sau giây lát.")
        case "not-open": self = .failed(text ?? "Cuộc trò chuyện chưa sẵn sàng, hãy thử lại sau giây lát.")
        default: self = .failed(text ?? failure)
        }
    }

    var logName: String {
        switch self {
        case .done: "done"
        case .confirm: "confirm"
        case .failed: "failed"
        case .pending: "pending"
        }
    }
}

/// A confirmation a message action asks for, answered natively.
struct MessageActionConfirm: Identifiable, Equatable {
    enum Action: Equatable {
        case deleteForMe(ChatMessage)
        /// "Chọn nhiều tin nhắn": delete / recall the selected messages.
        case deleteMany([ChatMessage])
        case recallMany([ChatMessage])
        /// Replace the pin `ref` (the oldest) to pin this message.
        case pin(ChatMessage, replacing: String)
        case unpin(ref: String)
    }
    let id = UUID()
    var conversationId: String
    var action: Action
    var title: String
    var message: String
    var ok: String
    var cancel: String = "Hủy"
    var destructive = false
}

/// "N tin nhắn đã xóa · Khôi phục": the official undo window of a delete-for-me.
struct DeleteUndo: Identifiable, Equatable {
    let id: String
    var conversationId: String
    var count: Int
    var deadline: Date
}

/// "Chia sẻ": the message waiting for the conversations to forward it to.
struct ForwardRequest: Identifiable, Equatable {
    let id: UUID
    var conversationId: String
    var message: ChatMessage
    /// "Chọn nhiều tin nhắn": the other selected messages, oldest first, forwarded after `message`.
    var more: [ChatMessage] = []
    var all: [ChatMessage] { [message] + more }

    init(id: UUID = UUID(), conversationId: String, message: ChatMessage, more: [ChatMessage] = []) {
        self.id = id
        self.conversationId = conversationId
        self.message = message
        self.more = more
    }
}

/// One pin of a conversation (official group board topic / 1:1 pin topic), newest first.
struct PinnedItem: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case message, note, link, poll, reminder }
    var ref: String
    var kind: Kind
    var title: String
    var sender: String
    var thumbnail: URL?
    var msgId: String
    var cliMsgId: String
    var id: String { ref }

    /// The official board's label of the pin's type (STR_MSG_PINNED…).
    var label: String {
        switch kind {
        case .message: "Tin nhắn"
        case .note, .link: "Ghi chú"
        case .poll: "Bình chọn"
        case .reminder: "Nhắc hẹn"
        }
    }

    /// The loaded chat message this pin points at (own messages are keyed by client id, others by server id).
    func message(in list: [ChatMessage]) -> ChatMessage? {
        guard kind == .message else { return nil }
        return list.last { (!msgId.isEmpty && $0.id == msgId) || (!cliMsgId.isEmpty && $0.id == cliMsgId) }
    }
}

struct PinnedList: Equatable, Sendable {
    /// The pins could be read (groups with the topic board on, friends with 1:1 pins on).
    var ready = false
    /// I may pin / unpin here (group allowance; friends always).
    var canPin = false
    var items: [PinnedItem] = []
    /// Pins the board holds at most (official `pinLimit`).
    var limit = ZaloWireParser.defaultPinLimit

    init(json: [String: Any]) {
        ready = json["ready"] as? Bool ?? false
        canPin = json["canPin"] as? Bool ?? false
        if let l = json["limit"] as? Int, l > 0 { limit = l }
        items = (json["items"] as? [[String: Any]] ?? []).compactMap { row in
            guard let ref = row["ref"] as? String, !ref.isEmpty else { return nil }
            return PinnedItem(ref: ref, kind: PinnedItem.Kind(rawValue: row["kind"] as? String ?? "") ?? .note,
                              title: row["title"] as? String ?? "", sender: row["sender"] as? String ?? "",
                              thumbnail: (row["thumb"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) },
                              msgId: row["msgId"] as? String ?? "", cliMsgId: row["cliMsgId"] as? String ?? "")
        }
    }
}

extension ChatMessage {
    /// What "Copy tin nhắn" puts on the pasteboard: the text of a text / link message, nil for kinds the official menu copies otherwise.
    var copyableText: String? {
        switch kind {
        case .text: return text.isEmpty ? nil : text
        case .link(let title, let url, _, _, _):
            if !text.isEmpty, !text.hasPrefix("[Link]") { return text }
            return url?.absoluteString ?? (title.isEmpty ? nil : title)
        default: return nil
        }
    }

    /// The caption of a photo / video ("Copy chú thích"); nil when it has none (non-text kinds carry "[Hình ảnh]"-style fallbacks).
    var caption: String? {
        switch kind {
        case .photo, .video: return !text.isEmpty && !text.hasPrefix("[") ? text : nil
        default: return nil
        }
    }
}

extension ZaloEngine {
    // MARK: Copy (native)

    func copyText(_ text: String, in conversationId: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        CardActionCenter.shared.show("Đã sao chép", in: conversationId)
    }

    /// "Copy hình ảnh": the full-resolution picture (the message's hd URL, or the decrypted E2EE file), never the chat thumbnail.
    func copyPhoto(_ message: ChatMessage) {
        guard case .photo(let url, _, _) = message.kind else { return }
        copyPhoto(conversationId: message.conversationId, messageId: message.id, url: message.isE2EE ? nil : url)
    }

    func copyPhoto(conversationId: String, messageId: String, url: URL?) {
        Task {
            guard let original = await photoOriginal(conversationId: conversationId, messageId: messageId, url: url),
                  let image = NSImage(data: original.data) else {
                CardActionCenter.shared.show("Không sao chép được hình ảnh. Hãy thử lại.", in: conversationId)
                return
            }
            let item = NSPasteboardItem()
            if let tiff = image.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
                if let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    item.setData(png, forType: .png)
                }
            }
            if let file = original.file {
                item.setString(file.absoluteString, forType: .fileURL)
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([item])
            CardActionCenter.shared.show("Đã sao chép", in: conversationId)
        }
    }

    /// "Tải về": the original through a save panel (`askLocation`), or straight into Downloads when `false`.
    func downloadPhoto(_ message: ChatMessage, askLocation: Bool = true) {
        guard case .photo(let url, _, _) = message.kind else { return }
        downloadPhoto(conversationId: message.conversationId, messageId: message.id, url: message.isE2EE ? nil : url,
                      date: message.date, askLocation: askLocation)
    }

    func downloadPhoto(conversationId: String, messageId: String, url: URL?, date: Date, askLocation: Bool = true) {
        Task {
            guard let original = await photoOriginal(conversationId: conversationId, messageId: messageId, url: url) else {
                CardActionCenter.shared.show("Không tải được hình ảnh. Hãy thử lại.", in: conversationId)
                return
            }
            // Always a file on disk to copy from: the cached original when there is one, else the downloaded bytes.
            var staged = original.file
            if staged == nil {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-photo-\(UUID().uuidString)")
                guard (try? original.data.write(to: tmp)) != nil else {
                    CardActionCenter.shared.show("Không tải được hình ảnh. Hãy thử lại.", in: conversationId)
                    return
                }
                staged = tmp
            }
            defer { if original.file == nil, let staged { try? FileManager.default.removeItem(at: staged) } }
            guard let staged else { return }
            let name = PhotoSaveName.make(date: date, data: original.data, sourceURL: url)
            if askLocation {
                _ = await ChatFileSavePanel.saveAs(staged: staged, displayName: name)
            } else if (try? ChatFileResolver.saveToDownloads(staged: staged, displayName: name)) != nil {
                CardActionCenter.shared.show("Đã tải ảnh về thư mục Downloads", in: conversationId)
            } else {
                CardActionCenter.shared.show("Không tải được hình ảnh. Hãy thử lại.", in: conversationId)
            }
        }
    }

    /// The photo's full-resolution bytes: the resolver's cached/decrypted local file first, then the CDN URL (never E2EE).
    private func photoOriginal(conversationId: String, messageId: String, url: URL?) async -> (data: Data, file: URL?)? {
        if case .file(let file) = await resolveMedia(conversationId: conversationId, messageId: messageId, kind: .photo),
           MediaLoader.isAllowedLocalFile(file), let data = try? Data(contentsOf: file) {
            return (data, MediaLoader.isOwnLocalFile(file) ? file : nil)
        }
        if let url, url.scheme == "https", let data = try? await MediaLoader.shared.data(for: url) {
            return (data, nil)
        }
        return nil
    }

    // MARK: Chia sẻ

    internal func fetchMediaData(for url: URL) async -> Data? {
        if let fetchMediaDataHostHandler {
            let args: [String: Any] = ["url": url.absoluteString]
            _ = traceHost("fetch_media_data", args: args)
            return await fetchMediaDataHostHandler(args)
        }
        return try? await MediaLoader.shared.data(for: url)
    }

    internal func makeForwardTempPhotoURL() -> URL {
        if let forwardTempPhotoURL {
            return forwardTempPhotoURL()
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("fwd-\(UUID().uuidString.prefix(8)).jpg")
    }

    internal func dismissForwardRequest() {
        forwardRequest = nil
        coreLifecycle.core?.clearForwardRequest()
    }

    func requestForward(_ message: ChatMessage) {
        if let core = coreLifecycle.core {
            core.requestForward(message: ChatMessageRecord(message: message))
            return
        }
        guard message.menu.forward == .available else {
            if message.menu.forward == .blocked { showActionCard("Trò chuyện này đã bật Chặn chia sẻ", in: message.conversationId) }
            return
        }
        forwardRequest = ForwardRequest(conversationId: message.conversationId, message: message)
    }

    func forward(_ message: ChatMessage, to targets: [String]) async -> MessageActionOutcome {
        if let core = coreLifecycle.core {
            core.setE2eeThreads(threads: e2eeManager.e2eeThreadIdsSync())
            do {
                let res = try await core.forward(
                    message: ChatMessageRecord(message: message),
                    targets: targets,
                    nowMs: nowMs()
                )
                await waitForMirrorVersion(res.version)
                return MessageActionOutcome(forwardRecord: res.outcome)
            } catch {
                return .failed("Có lỗi khi chia sẻ tin nhắn")
            }
        }
        guard !targets.isEmpty else { return .failed("Chưa chọn cuộc trò chuyện.") }
        var succeeded = 0
        for target in targets {
            switch message.kind {
            case .text:
                let body = message.text
                if !body.isEmpty, await sendText(body, to: target) { succeeded += 1 }
            case .link(let title, let url, _, _, _):
                let body = url?.absoluteString ?? (message.text.isEmpty ? title : message.text)
                if !body.isEmpty, await sendText(body, to: target) { succeeded += 1 }
            case .contactCard(let card):
                if let res = try? await sessionClient.sendContactCardAPI(convId: target, cardUid: card.uid, phone: card.phone.isEmpty ? nil : card.phone) {
                    let msg = ChatMessage(
                        id: res.msgId, conversationId: target,
                        senderId: profile?.userId ?? "", senderName: profile?.displayName ?? "Bạn", senderAvatar: profile?.avatar,
                        isMine: true, kind: .contactCard(card), text: "[Danh thiếp] \(card.name)",
                        date: Date(timeIntervalSince1970: Double(nowMs()) / 1000.0), status: .sent, quote: nil, reactions: [], isE2EE: false,
                        mentions: [], cardButtons: [], suggestsStickers: false,
                        menu: MessageMenu(json: [
                            "forward": "ok",
                            "recall": target != selfConversationId,
                            "delete": target == selfConversationId ? "plain" : "forMe",
                            "pin": ZaloWireParser.isGroupId(target) && target != selfConversationId,
                            "star": "star"
                        ]),
                        clientId: res.cliMsgId
                    )
                    mergeMessageIntoMemory(msg, replacingClientId: res.cliMsgId)
                    if let stored = ZaloWireParser.encodeChatMessage(msg, clientId: res.cliMsgId) {
                        try? await sqliteStore?.saveMessages([stored])
                    }
                    updateConversationOnMessage(msg, incrementUnread: false)
                    succeeded += 1
                }
            case .photo(let url, _, _):
                if case .file(let local) = await resolveMedia(conversationId: message.conversationId, messageId: message.id, kind: .photo),
                   await sendMedia([local], to: target) == .done {
                    succeeded += 1
                } else if let url, let data = await fetchMediaData(for: url) {
                    let tmp = makeForwardTempPhotoURL()
                    try? data.write(to: tmp, options: .atomic)
                    defer { try? FileManager.default.removeItem(at: tmp) }
                    if await sendMedia([tmp], to: target) == .done { succeeded += 1 }
                }
            case .file(let name, _, let url):
                if case .ready(let staged) = await resolveFile(conversationId: message.conversationId, messageId: message.id, name: name, url: url),
                   await sendFiles([staged], to: target) == .done {
                    succeeded += 1
                }
            default:
                if !message.text.isEmpty, await sendText(message.text, to: target) { succeeded += 1 }
            }
        }
        return succeeded > 0 ? .done(text: "Đã chia sẻ") : .failed("Có lỗi khi chia sẻ tin nhắn")
    }

    func forwardAll(to targets: [String]) async -> MessageActionOutcome {
        if let core = coreLifecycle.core {
            core.setE2eeThreads(threads: e2eeManager.e2eeThreadIdsSync())
            do {
                let res = try await core.forwardAll(targets: targets, nowMs: nowMs())
                await waitForMirrorVersion(res.version)
                return MessageActionOutcome(forwardRecord: res.outcome)
            } catch {
                return .failed("Có lỗi khi chia sẻ tin nhắn")
            }
        }
        guard let request = forwardRequest else {
            return .failed("Có lỗi khi chia sẻ tin nhắn")
        }
        var outcome = MessageActionOutcome.failed("Có lỗi khi chia sẻ tin nhắn")
        for message in request.all {
            let one = await forward(message, to: targets)
            if case .done = outcome { continue }
            outcome = one
        }
        if case .done = outcome, !request.more.isEmpty { endSelection() }
        switch outcome {
        case .done(let text):
            showActionCard(text ?? "Đã chia sẻ tin nhắn", in: request.conversationId)
            if forwardRequest?.id == request.id { forwardRequest = nil }
        case .pending(let text):
            showActionCard(text, in: request.conversationId)
            if forwardRequest?.id == request.id { forwardRequest = nil }
        case .failed, .confirm:
            break
        }
        return outcome
    }

    // MARK: Thu hồi

    func recall(_ message: ChatMessage) {
        Task {
            await performRecall(message)
        }
    }

    nonisolated static func findServerMsgId(in payload: [String: Any], matchingClientId: String) -> String? {
        let targetCli = matchingClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetCli.isEmpty else { return nil }

        func search(_ node: Any, depth: Int) -> String? {
            guard depth < 8 else { return nil }
            if let s = node as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")),
                   let data = trimmed.data(using: .utf8),
                   let parsed = JSONLossless.parseAny(data) {
                    return search(parsed, depth: depth + 1)
                }
                return nil
            }
            if let arr = node as? [Any] {
                for item in arr {
                    if let found = search(item, depth: depth + 1) { return found }
                }
                return nil
            }
            guard let dict = node as? [String: Any] else { return nil }
            let cli = JSONLossless.string(dict["cliMsgId"] ?? dict["clientId"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if cli == targetCli {
                let msgId = JSONLossless.string(dict["msgId"] ?? dict["globalMsgId"] ?? dict["minGlobalMsgId"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !msgId.isEmpty && msgId != "0" && msgId != targetCli {
                    return msgId
                }
            }
            for key in ["data", "msgs", "groupMsgs", "messages", "list"] {
                if let sub = dict[key], let found = search(sub, depth: depth + 1) {
                    return found
                }
            }
            for (k, v) in dict where !["data", "msgs", "groupMsgs", "messages", "list"].contains(k) {
                if (v is [String: Any] || v is [Any] || v is String),
                   let found = search(v, depth: depth + 1) {
                    return found
                }
            }
            return nil
        }

        return search(payload, depth: 0)
    }

    internal func resolveServerAndClientIds(for message: ChatMessage) async -> (msgId: String, cliMsgId: String) {
        let conv = message.conversationId
        var resolvedCliId = message.clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedCliId.isEmpty, let store = sqliteStore,
           let stored = try? await store.message(convId: conv, idOrClientId: message.id) {
            let colCli = stored.clientId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !colCli.isEmpty {
                resolvedCliId = colCli
            } else if let obj = (try? JSONSerialization.jsonObject(with: stored.rawJSONData)) as? [String: Any] {
                let rawCli = JSONLossless.string(obj["clientId"] ?? obj["cliMsgId"]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rawCli.isEmpty { resolvedCliId = rawCli }
            }
        }
        if resolvedCliId.isEmpty {
            resolvedCliId = message.id
        }

        var effectiveMsgId = message.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if effectiveMsgId.isEmpty || effectiveMsgId == resolvedCliId {
            if let store = sqliteStore,
               let stored = try? await store.message(convId: conv, idOrClientId: resolvedCliId),
               !stored.id.isEmpty,
               stored.id != resolvedCliId {
                effectiveMsgId = stored.id
                if var list = messages[conv],
                   let idx = list.firstIndex(where: { $0.id == message.id || $0.clientId == resolvedCliId }) {
                    let oldId = list[idx].id
                    list[idx].id = stored.id
                    if list[idx].clientId.isEmpty {
                        list[idx].clientId = resolvedCliId
                    }
                    messages[conv] = list
                    coreLifecycle.core?.writeThroughUpsertMessage(msg: ChatMessageRecord(message: list[idx]), replacingClientId: oldId)
                }
            } else if let histBox = try? await sessionClient.fetchHistory(convId: conv, lastMsgId: nil, count: 30),
                      let resolved = Self.findServerMsgId(in: histBox.dict, matchingClientId: resolvedCliId) {
                effectiveMsgId = resolved
                if var list = messages[conv],
                   let idx = list.firstIndex(where: { $0.id == message.id || $0.clientId == resolvedCliId }) {
                    let oldId = list[idx].id
                    list[idx].id = resolved
                    if list[idx].clientId.isEmpty {
                        list[idx].clientId = resolvedCliId
                    }
                    messages[conv] = list
                    coreLifecycle.core?.writeThroughUpsertMessage(msg: ChatMessageRecord(message: list[idx]), replacingClientId: oldId)
                }
                _ = try? await sqliteStore?.upgradeMessageId(
                    convId: conv,
                    oldId: message.id,
                    newId: resolved,
                    clientId: resolvedCliId
                )
            }
        }
        if effectiveMsgId.isEmpty {
            effectiveMsgId = resolvedCliId
        }
        return (effectiveMsgId, resolvedCliId)
    }

    internal func performRecall(_ message: ChatMessage) async {
        let conv = message.conversationId
        if let core = coreLifecycle.core {
            let isE2eeThread: Bool? = (message.isE2EE || ZaloWireParser.isGroupId(conv))
                ? nil
                : e2eeManager.isE2EEConversationSync(conv)
            if let v = try? await core.recall(
                convId: conv,
                msgId: message.id,
                isE2eeThread: isE2eeThread,
                nowMs: nowMs()
            ) {
                await waitForMirrorVersion(v)
            }
            return
        }
        guard !conv.isEmpty,
              conv != selfConversationId,
              message.isMine,
              message.kind != .recalled,
              message.status != .sending,
              message.status != .failed else {
            return
        }
        let now = Date(timeIntervalSince1970: Double(nowMs()) / 1000.0)
        if now.timeIntervalSince(message.date) >= 86_400 {
            showActionCard("Bạn chỉ có thể thu hồi tin nhắn đã gửi trong vòng 24 giờ.", in: conv)
            return
        }
        let key = "\(conv)|\(message.id)|recall"
        guard messageActionsBusy.insert(key).inserted else { return }
        defer { messageActionsBusy.remove(key) }

        let (effectiveMsgId, resolvedCliId) = await resolveServerAndClientIds(for: message)

        let primaryIsE2EE = message.isE2EE
        let canTryAlternateRoute: Bool
        if primaryIsE2EE {
            canTryAlternateRoute = true
        } else if ZaloWireParser.isGroupId(conv) {
            canTryAlternateRoute = true
        } else {
            canTryAlternateRoute = await e2eeManager.isE2EEConversation(conv)
        }
        var retriedAlt = false

        do {
            do {
                try await sessionClient.recallMessageAPI(
                    convId: conv,
                    msgId: effectiveMsgId,
                    cliMsgId: resolvedCliId,
                    isE2EE: primaryIsE2EE
                )
            } catch let err as ZaloSessionError where err.code == 112 && canTryAlternateRoute {
                retriedAlt = true
                try await sessionClient.recallMessageAPI(
                    convId: conv,
                    msgId: effectiveMsgId,
                    cliMsgId: resolvedCliId,
                    isE2EE: !primaryIsE2EE
                )
            }
            await applyRemoteRecall(convId: conv, msgId: effectiveMsgId, cliMsgId: resolvedCliId)
        } catch let err as ZaloSessionError {
            let msgNote = err.message.isEmpty ? "-" : err.message
            EngineLog.shared.write(
                "recall failed: code=\(err.code) msg=\(msgNote) primaryE2EE=\(primaryIsE2EE) retriedAlt=\(retriedAlt) sameId=\(effectiveMsgId == resolvedCliId) msgId=\(effectiveMsgId) cliId=\(resolvedCliId)"
            )
            let text = (err.code == 211)
                ? "Tin nhắn đã quá thời hạn thu hồi."
                : "Thu hồi tin nhắn không thành công (mã lỗi \(err.code))."
            showActionCard(text, in: conv)
        } catch is URLError {
            EngineLog.shared.write("recall failed: network error")
            showActionCard("Không có kết nối mạng. Vui lòng kiểm tra và thử lại.", in: conv)
        } catch {
            EngineLog.shared.write("recall failed: \(error.localizedDescription)")
            showActionCard("Thu hồi tin nhắn không thành công.", in: conv)
        }
    }

    // MARK: Xóa chỉ ở phía tôi

    @discardableResult
    internal func applyOptimisticDeleteMirror(_ list: [ChatMessage], nowMs tsMs: Int64) -> UUID? {
        guard let conversation = list.first?.conversationId else { return nil }
        let ids = Set(list.map(\.id))
        let deadline = Date(timeIntervalSince1970: Double(tsMs) / 1000.0).addingTimeInterval(5)
        let undo = DeleteUndo(
            id: deleteUndo?.id ?? UUID().uuidString,
            conversationId: conversation,
            count: list.count,
            deadline: deadline
        )
        let token = beginOptimisticDeleteOverlay(convId: conversation, messages: list, undo: undo)
        if var current = messages[conversation] {
            let prevCount = current.count
            current.removeAll { ids.contains($0.id) }
            if current.count != prevCount {
                isSuppressingDirectMessageSync = true
                messages[conversation] = current
                isSuppressingDirectMessageSync = false
            }
        }
        deleteUndo = undo
        return token
    }

    func deleteForMe(_ message: ChatMessage, confirmed: Bool = false) {
        let conversation = message.conversationId
        if let core = coreLifecycle.core {
            let tsMs = nowMs()
            var overlayToken: UUID?
            if !confirmed && message.menu.delete == .forMe {
                if openConversationId == conversation, messageConfirm == nil {
                    mirroredMessageConfirmCoreId = nil
                    messageConfirm = MessageActionConfirm(
                        conversationId: conversation,
                        action: .deleteForMe(message),
                        title: "Xóa tin nhắn",
                        message: "Tin nhắn sẽ chỉ bị xóa ở phía bạn.",
                        ok: "Xóa",
                        destructive: true
                    )
                }
            } else {
                overlayToken = applyOptimisticDeleteMirror([message], nowMs: tsMs)
            }
            core.deleteForMe(
                convId: conversation,
                msgId: message.id,
                confirmed: confirmed,
                nowMs: tsMs
            )
            if let token = overlayToken {
                scheduleOptimisticOverlayFence(token: token, core: core)
            }
            return
        }
        if !confirmed && message.menu.delete == .forMe {
            ask(MessageActionConfirm(
                conversationId: conversation,
                action: .deleteForMe(message),
                title: "Xóa tin nhắn",
                message: "Tin nhắn sẽ chỉ bị xóa ở phía bạn.",
                ok: "Xóa",
                destructive: true
            ))
            return
        }
        deleteMessages([message])
    }

    /// Hides the messages at once and deletes them on the server when the undo bar times out (one bar for the batch).
    func deleteMessages(_ list: [ChatMessage]) {
        guard let conversation = list.first?.conversationId else { return }
        if let core = coreLifecycle.core {
            let tsMs = nowMs()
            let overlayToken = applyOptimisticDeleteMirror(list, nowMs: tsMs)
            core.deleteMany(
                convId: conversation,
                msgIds: list.map(\.id),
                confirm: false,
                nowMs: tsMs
            )
            if let token = overlayToken {
                scheduleOptimisticOverlayFence(token: token, core: core)
            }
            return
        }
        let undoId = UUID().uuidString
        pendingDeletedMessages[undoId] = list
        let ids = Set(list.map(\.id))
        if var current = messages[conversation] {
            current.removeAll { ids.contains($0.id) }
            messages[conversation] = current
        }
        coreLifecycle.core?.writeThroughRemoveMessages(convId: conversation, ids: Array(ids))
        let now = Date(timeIntervalSince1970: Double(nowMs()) / 1000.0)
        showDeleteUndo(DeleteUndo(
            id: undoId,
            conversationId: conversation,
            count: list.count,
            deadline: now.addingTimeInterval(5)
        ))
    }

    private func showDeleteUndo(_ undo: DeleteUndo) {
        deleteUndoTimerTask?.cancel()
        deleteUndoTimerTask = nil
        if let previous = deleteUndo {
            commitPendingDelete(id: previous.id)
        }
        deleteUndo = undo
        let now = Date(timeIntervalSince1970: Double(nowMs()) / 1000.0)
        let sleepSeconds = max(0.5, undo.deadline.timeIntervalSince(now))
        deleteUndoTimerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(sleepSeconds))
            guard !Task.isCancelled, let self, self.deleteUndo == undo else { return }
            self.deleteUndoTimerTask = nil
            self.deleteUndo = nil
            self.commitPendingDelete(id: undo.id)
        }
    }

    func undoDelete() {
        if let core = coreLifecycle.core {
            let convId = deleteUndo?.conversationId ?? ""
            let restored = convId.isEmpty ? [] : (lastOptimisticDeletedMessages.removeValue(forKey: convId) ?? [])
            var overlayToken: UUID?
            if !convId.isEmpty {
                overlayToken = beginOptimisticUndoDeleteOverlay(convId: convId, restored: restored)
                if !restored.isEmpty {
                    var current = messages[convId] ?? []
                    let existingIds = Set(current.map(\.id))
                    let toAdd = restored.filter { !existingIds.contains($0.id) }
                    if !toAdd.isEmpty {
                        current.append(contentsOf: toAdd)
                        current.sort { a, b in a.date == b.date ? a.id < b.id : a.date < b.date }
                        isSuppressingDirectMessageSync = true
                        messages[convId] = current
                        isSuppressingDirectMessageSync = false
                    }
                }
            }
            deleteUndo = nil
            core.undoDelete()
            if let token = overlayToken {
                scheduleOptimisticOverlayFence(token: token, core: core)
            }
            return
        }
        guard let undo = deleteUndo else { return }
        deleteUndoTimerTask?.cancel()
        deleteUndoTimerTask = nil
        deleteUndo = nil
        if let restored = pendingDeletedMessages.removeValue(forKey: undo.id) {
            for message in restored { mergeMessageIntoMemory(message) }
            showActionCard("Khôi phục thành công", in: undo.conversationId)
        }
    }

    func dismissDeleteUndo() {
        if let core = coreLifecycle.core {
            if let convId = deleteUndo?.conversationId {
                lastOptimisticDeletedMessages.removeValue(forKey: convId)
            }
            deleteUndo = nil
            core.dismissDeleteUndo()
            return
        }
        guard let undo = deleteUndo else { return }
        deleteUndoTimerTask?.cancel()
        deleteUndoTimerTask = nil
        deleteUndo = nil
        commitPendingDelete(id: undo.id)
    }

    private func commitPendingDelete(id: String) {
        guard let list = pendingDeletedMessages.removeValue(forKey: id) else { return }
        trackMessageActionTask { [weak self] in
            guard let self else { return }
            for msg in list {
                let resolvedCliId = msg.clientId.isEmpty ? msg.id : msg.clientId
                try? await self.sessionClient.deleteMessageForMeAPI(
                    convId: msg.conversationId,
                    msgId: msg.id,
                    cliMsgId: resolvedCliId,
                    senderId: msg.senderId
                )
                try? await self.sqliteStore?.deleteMessage(convId: msg.conversationId, id: msg.id)
            }
        }
    }

    // MARK: Đánh dấu tin nhắn

    func setStarred(_ message: ChatMessage, _ on: Bool) {
        if let core = coreLifecycle.core {
            var overlayToken: UUID?
            if !(on && message.menu.star == .blocked) {
                let conv = message.conversationId
                if var list = messages[conv], let idx = list.firstIndex(where: { $0.id == message.id }) {
                    overlayToken = beginOptimisticStarOverlay(convId: conv, msgId: message.id, on: on)
                    list[idx].menu.starred = on
                    list[idx].menu.star = on ? .unstar : .star
                    isSuppressingDirectMessageSync = true
                    messages[conv] = list
                    isSuppressingDirectMessageSync = false
                    if on { cachedStarredIds.insert(message.id) } else { cachedStarredIds.remove(message.id) }
                }
            }
            core.setStarred(convId: message.conversationId, msgId: message.id, on: on)
            if let token = overlayToken {
                scheduleOptimisticOverlayFence(token: token, core: core)
            }
            return
        }
        if on, message.menu.star == .blocked {
            showActionCard("Trò chuyện này đã bật Chặn chia sẻ", in: message.conversationId)
            return
        }
        let conv = message.conversationId
        if var list = messages[conv], let idx = list.firstIndex(where: { $0.id == message.id }) {
            list[idx].menu.starred = on
            list[idx].menu.star = on ? .unstar : .star
            messages[conv] = list
            let updated = list[idx]
            coreLifecycle.core?.writeThroughUpsertMessage(msg: ChatMessageRecord(message: updated), replacingClientId: nil)
            trackMessageActionTask { [weak self] in
                guard let self else { return }
                if on { self.cachedStarredIds.insert(message.id) } else { self.cachedStarredIds.remove(message.id) }
                try? await self.sqliteStore?.setPreferenceStrings(key: "starredIds", value: Array(self.cachedStarredIds))
                if let stored = ZaloWireParser.encodeChatMessage(updated) {
                    try? await self.sqliteStore?.saveMessages([stored])
                }
            }
        }
        showActionCard(on ? "Đã đánh dấu tin nhắn" : "Đã bỏ đánh dấu tin nhắn", in: conv)
    }

    // MARK: Ghim tin nhắn

    func pin(_ message: ChatMessage, replacing ref: String? = nil) {
        let conversation = message.conversationId
        let key = "\(conversation)|\(message.id)|pin"
        guard messageActionsBusy.insert(key).inserted else { return }
        insertPinOptimistically(message, replacing: ref)
        trackMessageActionTask { [weak self] in
            guard let self else { return }
            defer { self.messageActionsBusy.remove(key) }
            do {
                if let ref, !ref.isEmpty {
                    let boardCache = self.cachedBoardRawTopics[conversation]
                    try await self.sessionClient.unpinBoardTopic(
                        convId: conversation,
                        topicId: ref,
                        rawTopic: boardCache?.topics[ref].map { ZaloJSONBox($0) },
                        boardVersion: boardCache?.version ?? 0
                    )
                    await self.refreshBoardPins(for: conversation)
                }
                // Official `getTopicDataFromMessage`: the real server/client id pair (own messages are not keyed by msgId).
                let ids = await self.resolveServerAndClientIds(for: message)
                let me = self.profile?.userId ?? ""
                let senderUid = message.isMine || message.senderId.isEmpty || message.senderId == "0" ? me : message.senderId
                let senderName = message.isMine
                    ? (self.profile?.displayName ?? "")
                    : (self.lookupPersonInfo(message.senderId)?.name ?? message.senderName)
                let params = ZaloWireParser.pinTopicParams(
                    msgId: ids.msgId, cliMsgId: ids.cliMsgId.isEmpty ? ids.msgId : ids.cliMsgId,
                    senderUid: senderUid, senderName: senderName, kind: message.kind, title: message.text)
                _ = try await self.sessionClient.pinBoardMessage(
                    convId: conversation,
                    params: params,
                    boardVersion: self.cachedBoardRawTopics[conversation]?.version ?? 0
                )
                await self.refreshBoardPins(for: conversation)
            } catch {
                EngineLog.shared.write("pins: pin failed group=\(ZaloWireParser.isGroupId(conversation)) replacing=\(ref != nil) \(Self.pinErrorShape(error))")
                await self.refreshBoardPins(for: conversation)
                self.showActionCard("Ghim tin nhắn không thành công.", in: conversation)
            }
        }
    }

    func requestUnpin(_ item: PinnedItem, in conversationId: String) {
        ask(MessageActionConfirm(
            conversationId: conversationId,
            action: .unpin(ref: item.ref),
            title: item.kind == .message ? "Bỏ ghim tin nhắn" : "Bỏ ghim",
            message: item.kind == .message ? "Bạn muốn bỏ ghim tin nhắn?" : "Bạn muốn bỏ ghim nội dung này?",
            ok: "Bỏ ghim",
            destructive: true
        ))
    }

    func ask(_ confirm: MessageActionConfirm) {
        guard openConversationId == confirm.conversationId, messageConfirm == nil else {
            return
        }
        mirroredMessageConfirmCoreId = nil
        messageConfirm = confirm
        if let core = coreLifecycle.core {
            core.askMessageConfirm(confirm: messageConfirmRecord(for: confirm))
        }
    }

    func requestUnpin(_ message: ChatMessage) {
        guard let item = pins[message.conversationId]?.items.first(where: { $0.message(in: [message]) != nil }) else { return }
        requestUnpin(item, in: message.conversationId)
    }

    private func unpin(_ ref: String, in conversationId: String) {
        let key = "\(conversationId)|\(ref)|unpin"
        guard messageActionsBusy.insert(key).inserted else { return }
        let rawTopic = cachedBoardRawTopics[conversationId]?.topics[ref]
        removePinOptimistically(ref, in: conversationId)
        trackMessageActionTask { [weak self] in
            guard let self else { return }
            defer { self.messageActionsBusy.remove(key) }
            do {
                let boardCache = self.cachedBoardRawTopics[conversationId]
                try await self.sessionClient.unpinBoardTopic(
                    convId: conversationId,
                    topicId: ref,
                    rawTopic: rawTopic.map { ZaloJSONBox($0) },
                    boardVersion: boardCache?.version ?? 0
                )
                await self.refreshBoardPins(for: conversationId)
            } catch {
                await self.refreshBoardPins(for: conversationId)
                self.showActionCard("Yêu cầu thực hiện không thành công", in: conversationId)
            }
        }
    }

    func answerMessageConfirm(_ confirm: MessageActionConfirm, ok: Bool) {
        guard messageConfirm?.id == confirm.id else { return }
        messageConfirm = nil
        mirroredMessageConfirmCoreId = nil
        if let core = coreLifecycle.core {
            let tsMs = nowMs()
            var overlayToken: UUID?
            if ok {
                switch confirm.action {
                case .deleteForMe(let message):
                    overlayToken = applyOptimisticDeleteMirror([message], nowMs: tsMs)
                case .deleteMany(let list):
                    endSelection()
                    overlayToken = applyOptimisticDeleteMirror(list, nowMs: tsMs)
                case .recallMany:
                    endSelection()
                case .pin(let message, let replacing):
                    core.answerMessageConfirm(ok: ok, nowMs: tsMs)
                    pin(message, replacing: replacing)
                    return
                case .unpin(let ref):
                    core.answerMessageConfirm(ok: ok, nowMs: tsMs)
                    unpin(ref, in: confirm.conversationId)
                    return
                }
            }
            core.answerMessageConfirm(ok: ok, nowMs: tsMs)
            if let token = overlayToken {
                scheduleOptimisticOverlayFence(token: token, core: core)
            }
            return
        }
        guard ok else { return }
        switch confirm.action {
        case .deleteForMe(let message): deleteForMe(message, confirmed: true)
        case .deleteMany(let list): endSelection(); deleteMessages(list)
        case .recallMany(let list): recallMessages(list)
        case .pin(let message, let replacing): pin(message, replacing: replacing)
        case .unpin(let ref): unpin(ref, in: confirm.conversationId)
        }
    }

    // MARK: Pins of the open conversation

    internal func refreshBoardPins(for convId: String) async {
        guard traceU4Host("refresh_board_pins", args: ["conv_id": convId]) else {
            return
        }
        let group = ZaloWireParser.isGroupId(convId)
        let box: ZaloJSONBox
        do {
            box = try await sessionClient.fetchBoardPins(convId: convId)
        } catch {
            EngineLog.shared.write("pins: list failed group=\(group) \(Self.pinErrorShape(error))")
            return
        }
        let parsed = ZaloWireParser.parseBoardTopics(box.dict, convId: convId) { [weak self] uid in
            self?.lookupPersonInfo(uid)?.name
        }
        EngineLog.shared.write("pins: list ok group=\(group) rows=\((box.dict["items"] as? [Any])?.count ?? -1) items=\(parsed.list.items.count)")
        cachedBoardRawTopics[convId] = (version: parsed.version, topics: parsed.raw)
        if pins[convId] != parsed.list { pins[convId] = parsed.list }
    }

    /// Log shape of a board request error: the server code and the API path, never ids or text.
    nonisolated static func pinErrorShape(_ error: Error) -> String {
        guard let err = error as? ZaloSessionError else { return "error=\(type(of: error))" }
        let path = URL(string: err.url)?.path ?? ""
        return "code=\(err.code) path=\(path)"
    }

    func handlePins(state: [String: Any]) {
        guard let json = state["pins"] as? [String: Any], let conversation = json["convId"] as? String, !conversation.isEmpty else { return }
        let list = PinnedList(json: json)
        if pins[conversation] != list { pins[conversation] = list }
    }

    func rewatchPins() {
        guard let id = openConversationId else { return }
        trackMessageActionTask { [weak self] in
            await self?.refreshBoardPins(for: id)
        }
    }

    func dropMessagePrompts() {
        forwardRequest = nil
        messageConfirm = nil
        mirroredMessageConfirmCoreId = nil
    }

    func resetMessageActions() {
        deleteUndoTimerTask?.cancel()
        deleteUndoTimerTask = nil
        forwardRequest = nil
        messageConfirm = nil
        mirroredMessageConfirmCoreId = nil
        deleteUndo = nil
        pins = [:]
        messageActionsBusy = []
        pendingDeletedMessages = [:]
        optimisticOverlayFenceTasks.values.forEach { $0.cancel() }
        optimisticOverlayFenceTasks.removeAll()
        optimisticMessageOverlays.removeAll()
        lastOptimisticDeletedMessages.removeAll()
    }
}


/// File name for a saved chat photo: "Zalo_yyyyMMdd_HHmmss.ext", the extension from the bytes (the CDN URL often has none).
enum PhotoSaveName {
    nonisolated static func make(date: Date, data: Data, sourceURL: URL?) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return "Zalo_\(f.string(from: date)).\(fileExtension(data: data, sourceURL: sourceURL))"
    }

    nonisolated static func fileExtension(data: Data, sourceURL: URL?) -> String {
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if b.count >= 12, b[0..<4] == [0x52, 0x49, 0x46, 0x46], b[8..<12] == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        if b.count >= 12, b[4..<8] == [0x66, 0x74, 0x79, 0x70], b[8..<12] == [0x68, 0x65, 0x69, 0x63] { return "heic" }
        if let ext = sourceURL?.pathExtension.lowercased(), ["jpg", "jpeg", "png", "gif", "webp", "heic"].contains(ext) { return ext }
        return "jpg"
    }
}
