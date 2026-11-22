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
    let id = UUID()
    var conversationId: String
    var message: ChatMessage
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

    init(json: [String: Any]) {
        ready = json["ready"] as? Bool ?? false
        canPin = json["canPin"] as? Bool ?? false
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

    func copyPhoto(_ message: ChatMessage) {
        guard case .photo(let url, _, _) = message.kind else { return }
        let conversation = message.conversationId
        Task {
            var data: Data?
            if case .file(let file) = await resolveMedia(conversationId: conversation, messageId: message.id, kind: .photo),
               MediaLoader.isAllowedLocalFile(file) {
                data = try? Data(contentsOf: file)
            }
            if data == nil, !message.isE2EE, let url, url.scheme == "https" {
                data = try? await MediaLoader.shared.data(for: url)
            }
            guard let data, let image = NSImage(data: data) else {
                CardActionCenter.shared.show("Không sao chép được hình ảnh. Hãy thử lại.", in: conversation)
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            CardActionCenter.shared.show("Đã sao chép", in: conversation)
        }
    }

    // MARK: Chia sẻ

    func requestForward(_ message: ChatMessage) {
        guard message.menu.forward == .available else {
            if message.menu.forward == .blocked { CardActionCenter.shared.show("Trò chuyện này đã bật Chặn chia sẻ", in: message.conversationId) }
            return
        }
        forwardRequest = ForwardRequest(conversationId: message.conversationId, message: message)
    }

    func forward(_ message: ChatMessage, to targets: [String]) async -> MessageActionOutcome {
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
                        date: Date(), status: .sent, quote: nil, reactions: [], isE2EE: false,
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
                } else if let url, let data = try? await MediaLoader.shared.data(for: url) {
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fwd-\(UUID().uuidString.prefix(8)).jpg")
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
                    list[idx].id = stored.id
                    if list[idx].clientId.isEmpty {
                        list[idx].clientId = resolvedCliId
                    }
                    messages[conv] = list
                }
            } else if let histBox = try? await sessionClient.fetchHistory(convId: conv, lastMsgId: nil, count: 30),
                      let resolved = Self.findServerMsgId(in: histBox.dict, matchingClientId: resolvedCliId) {
                effectiveMsgId = resolved
                if var list = messages[conv],
                   let idx = list.firstIndex(where: { $0.id == message.id || $0.clientId == resolvedCliId }) {
                    list[idx].id = resolved
                    if list[idx].clientId.isEmpty {
                        list[idx].clientId = resolvedCliId
                    }
                    messages[conv] = list
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
        guard !conv.isEmpty,
              conv != selfConversationId,
              message.isMine,
              message.kind != .recalled,
              message.status != .sending,
              message.status != .failed else {
            return
        }
        if Date().timeIntervalSince(message.date) >= 86_400 {
            CardActionCenter.shared.show("Bạn chỉ có thể thu hồi tin nhắn đã gửi trong vòng 24 giờ.", in: conv)
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
            CardActionCenter.shared.show(text, in: conv)
        } catch is URLError {
            EngineLog.shared.write("recall failed: network error")
            CardActionCenter.shared.show("Không có kết nối mạng. Vui lòng kiểm tra và thử lại.", in: conv)
        } catch {
            EngineLog.shared.write("recall failed: \(error.localizedDescription)")
            CardActionCenter.shared.show("Thu hồi tin nhắn không thành công.", in: conv)
        }
    }

    // MARK: Xóa chỉ ở phía tôi

    func deleteForMe(_ message: ChatMessage, confirmed: Bool = false) {
        let conversation = message.conversationId
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
        let undoId = UUID().uuidString
        pendingDeletedMessages[undoId] = message
        if var list = messages[conversation] {
            list.removeAll { $0.id == message.id }
            messages[conversation] = list
        }
        showDeleteUndo(DeleteUndo(
            id: undoId,
            conversationId: conversation,
            count: 1,
            deadline: Date().addingTimeInterval(5)
        ))
    }

    private func showDeleteUndo(_ undo: DeleteUndo) {
        if let previous = deleteUndo {
            commitPendingDelete(id: previous.id)
        }
        deleteUndo = undo
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.5, undo.deadline.timeIntervalSinceNow)))
            guard let self, self.deleteUndo == undo else { return }
            self.deleteUndo = nil
            self.commitPendingDelete(id: undo.id)
        }
    }

    func undoDelete() {
        guard let undo = deleteUndo else { return }
        deleteUndo = nil
        if let restored = pendingDeletedMessages.removeValue(forKey: undo.id) {
            mergeMessageIntoMemory(restored)
            CardActionCenter.shared.show("Khôi phục thành công", in: undo.conversationId)
        }
    }

    func dismissDeleteUndo() {
        guard let undo = deleteUndo else { return }
        deleteUndo = nil
        commitPendingDelete(id: undo.id)
    }

    private func commitPendingDelete(id: String) {
        guard let msg = pendingDeletedMessages.removeValue(forKey: id) else { return }
        let resolvedCliId = msg.clientId.isEmpty ? msg.id : msg.clientId
        Task {
            try? await sessionClient.deleteMessageForMeAPI(
                convId: msg.conversationId,
                msgId: msg.id,
                cliMsgId: resolvedCliId,
                senderId: msg.senderId
            )
            try? await sqliteStore?.deleteMessage(convId: msg.conversationId, id: msg.id)
        }
    }

    // MARK: Đánh dấu tin nhắn

    func setStarred(_ message: ChatMessage, _ on: Bool) {
        if on, message.menu.star == .blocked {
            CardActionCenter.shared.show("Trò chuyện này đã bật Chặn chia sẻ", in: message.conversationId)
            return
        }
        let conv = message.conversationId
        if var list = messages[conv], let idx = list.firstIndex(where: { $0.id == message.id }) {
            list[idx].menu.starred = on
            list[idx].menu.star = on ? .unstar : .star
            messages[conv] = list
            let updated = list[idx]
            Task {
                if on { cachedStarredIds.insert(message.id) } else { cachedStarredIds.remove(message.id) }
                try? await sqliteStore?.setPreferenceStrings(key: "starredIds", value: Array(cachedStarredIds))
                if let stored = ZaloWireParser.encodeChatMessage(updated) {
                    try? await sqliteStore?.saveMessages([stored])
                }
            }
        }
        CardActionCenter.shared.show(on ? "Đã đánh dấu tin nhắn" : "Đã bỏ đánh dấu tin nhắn", in: conv)
    }

    // MARK: Ghim tin nhắn

    func pin(_ message: ChatMessage, replacing ref: String? = nil) {
        let conversation = message.conversationId
        let key = "\(conversation)|\(message.id)|pin"
        guard messageActionsBusy.insert(key).inserted else { return }
        Task {
            defer { messageActionsBusy.remove(key) }
            do {
                if let ref, !ref.isEmpty {
                    let boardCache = cachedBoardRawTopics[conversation]
                    try await sessionClient.unpinBoardTopic(
                        convId: conversation,
                        topicId: ref,
                        rawTopic: boardCache?.topics[ref].map { ZaloJSONBox($0) },
                        boardVersion: boardCache?.version ?? 0
                    )
                }
                _ = try await sessionClient.pinBoardMessage(
                    convId: conversation,
                    msgId: message.id,
                    cliMsgId: message.id,
                    senderId: message.senderId,
                    text: message.text
                )
                await refreshBoardPins(for: conversation)
            } catch {
                CardActionCenter.shared.show("Ghim tin nhắn không thành công.", in: conversation)
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

    private func ask(_ confirm: MessageActionConfirm) {
        guard openConversationId == confirm.conversationId, messageConfirm == nil else {
            return
        }
        messageConfirm = confirm
    }

    func requestUnpin(_ message: ChatMessage) {
        guard let item = pins[message.conversationId]?.items.first(where: { $0.message(in: [message]) != nil }) else { return }
        requestUnpin(item, in: message.conversationId)
    }

    private func unpin(_ ref: String, in conversationId: String) {
        let key = "\(conversationId)|\(ref)|unpin"
        guard messageActionsBusy.insert(key).inserted else { return }
        Task {
            defer { messageActionsBusy.remove(key) }
            do {
                let boardCache = cachedBoardRawTopics[conversationId]
                try await sessionClient.unpinBoardTopic(
                    convId: conversationId,
                    topicId: ref,
                    rawTopic: boardCache?.topics[ref].map { ZaloJSONBox($0) },
                    boardVersion: boardCache?.version ?? 0
                )
                await refreshBoardPins(for: conversationId)
            } catch {
                CardActionCenter.shared.show("Yêu cầu thực hiện không thành công", in: conversationId)
            }
        }
    }

    func answerMessageConfirm(_ confirm: MessageActionConfirm, ok: Bool) {
        guard messageConfirm?.id == confirm.id else { return }
        messageConfirm = nil
        guard ok else { return }
        switch confirm.action {
        case .deleteForMe(let message): deleteForMe(message, confirmed: true)
        case .pin(let message, let replacing): pin(message, replacing: replacing)
        case .unpin(let ref): unpin(ref, in: confirm.conversationId)
        }
    }

    // MARK: Pins of the open conversation

    internal func refreshBoardPins(for convId: String) async {
        guard let box = try? await sessionClient.fetchBoardPins(convId: convId) else {
            return
        }
        let rawRows = (box.dict["items"] as? [[String: Any]]) ?? []
        let boardVer = JSONLossless.int64(box.dict["boardVersion"]) ?? 0
        var rawMap: [String: [String: Any]] = [:]
        let items: [[String: Any]] = rawRows.compactMap { row in
            let ref = JSONLossless.string(row["id"] ?? row["topicId"] ?? row["topic_id"])
            guard !ref.isEmpty else { return nil }
            rawMap[ref] = row
            let params: [String: Any] = {
                if let p = row["params"] as? [String: Any] { return p }
                if let pStr = row["params"] as? String,
                   let pData = pStr.data(using: .utf8),
                   let parsed = JSONLossless.parseObject(pData) {
                    return parsed
                }
                return [:]
            }()
            let topicType = JSONLossless.int64(row["type"]) ?? 2
            let kindStr: String = {
                if topicType == 3 { return "poll" }
                if topicType == 0 || topicType == 1 { return "reminder" }
                return "message"
            }()
            let senderUid = ZaloWireParser.stripUserPrefix(JSONLossless.string(params["senderUid"] ?? params["senderId"] ?? row["creatorId"]))
            let resolvedSender = !senderUid.isEmpty ? (lookupPersonInfo(senderUid)?.name ?? "") : ""
            return [
                "ref": ref,
                "kind": kindStr,
                "title": JSONLossless.string(params["title"] ?? params["content"] ?? params["msg"] ?? params["message"] ?? params["description"] ?? row["title"] ?? row["content"]),
                "sender": JSONLossless.string(params["senderName"] ?? params["sender_name"] ?? params["dName"] ?? params["fromName"] ?? row["creatorName"]).isEmpty
                    ? resolvedSender
                    : JSONLossless.string(params["senderName"] ?? params["sender_name"] ?? params["dName"] ?? params["fromName"] ?? row["creatorName"]),
                "thumb": JSONLossless.string(params["thumb"]),
                "msgId": JSONLossless.string(params["globalMsgId"] ?? params["global_msg_id"] ?? params["msgId"] ?? params["msg_id"]),
                "cliMsgId": JSONLossless.string(params["cliMsgId"] ?? params["client_msg_id"])
            ]
        }
        cachedBoardRawTopics[convId] = (version: boardVer, topics: rawMap)
        let list = PinnedList(json: ["convId": convId, "ready": true, "canPin": true, "items": items])
        if pins[convId] != list { pins[convId] = list }
    }

    func handlePins(state: [String: Any]) {
        guard let json = state["pins"] as? [String: Any], let conversation = json["convId"] as? String, !conversation.isEmpty else { return }
        let list = PinnedList(json: json)
        if pins[conversation] != list { pins[conversation] = list }
    }

    func rewatchPins() {
        guard let id = openConversationId else { return }
        Task { await refreshBoardPins(for: id) }
    }

    func dropMessagePrompts() {
        forwardRequest = nil
        messageConfirm = nil
    }

    func resetMessageActions() {
        forwardRequest = nil
        messageConfirm = nil
        deleteUndo = nil
        pins = [:]
        messageActionsBusy = []
        pendingDeletedMessages = [:]
    }
}
