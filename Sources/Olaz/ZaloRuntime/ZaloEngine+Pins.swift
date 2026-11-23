import Foundation

// "Ghim tin nhắn": the conversation's pin board (official group board topics, 1:1 "oneone" board).
//
// Official client (app.asar, topic controller):
//   list   GET  group_board /api/board/pin/list {groupId, boardVersion, imei} → {topics|items, boardVersion, pinLimit}
//               GET  group_board /api/board/oneone/list {objectData:{uid, board_type, page, count, last_id, last_type}}
//   pin    POST group_board /api/board/topic/createv2 (type 2 = message topic, pinAct 1) · /api/board/oneone/create
//   unpin  GET  group_board /api/board/unpinv2 {grid, topic, boardVersion} · POST /api/board/oneone/remove
//   limit  `pinLimit` of the list response (stored as `gr_topics__pin_limit`; client default = config `group_topics.pin_limit` || 10).
//          `checkPinTopic`: topics.count >= pinLimit → the "Cập nhật danh sách ghim" modal: one over → confirm replacing the
//          oldest (STR_ONLY_PIN_MAX_CONTENT + STR_DIRECTION_PIN_LIMIT), several over → pick pins to drop (STR_DIRECTION_MULTI_UNPIN_*).
//   realtime  cmd 601 control, content {act_type:"group", act, data:{groupId, topic, oldTopic, boardVersion, oldBoardVersion}},
//          act ∈ new_pin_topic / update_pin_topic / unpin_topic / reorder_pin_topic. The official client applies it when the
//          versions line up and re-fetches the board otherwise; we always re-fetch (one GET, the board is small).
//   chat line  update_topic MSG_TOPIC: "<name> ghim một tin nhắn thành thông báo nhóm" (STR_INFO_MSG_PIN_MESSAGE),
//          unpin: "bỏ ghim một tin nhắn" (STR_INFO_MSG_UNPIN_MESSAGE).

/// What pinning one more topic needs when the board holds `count` of at most `limit`.
enum PinLimitDecision: Equatable, Sendable {
    case allowed
    /// One over: the official confirm drops the oldest pin (the last of the newest-first list).
    case replaceOldest
    /// Several over (the limit was lowered): pick at least `need` pins to drop first.
    case chooseMany(need: Int)

    static func decide(count: Int, limit: Int) -> PinLimitDecision {
        guard limit > 0, count >= limit else { return .allowed }
        let need = count - limit + 1
        return need == 1 ? .replaceOldest : .chooseMany(need: need)
    }
}

extension ZaloWireParser {
    /// Pins a board holds when the list response carries no `pinLimit`.
    static let defaultPinLimit = 3

    /// Group control acts that change a conversation's pin board.
    static let pinTopicActs: Set<String> = ["new_pin_topic", "update_pin_topic", "unpin_topic", "reorder_pin_topic"]

    /// The conversation whose board a control event changed, or nil when it is not a pin event.
    static func pinTopicEventConversation(actType: String, act: String, data: [String: Any]) -> String? {
        guard actType.isEmpty || actType == "group", pinTopicActs.contains(act) else { return nil }
        let gid = JSONLossless.string(data["groupId"] ?? data["grid"] ?? data["gid"])
        guard !gid.isEmpty, gid != "0" else { return nil }
        return groupConvId(gid)
    }

    /// A topic's `params` (an object, or a JSON string of one).
    static func boardTopicParams(_ row: [String: Any]) -> [String: Any] {
        if let p = row["params"] as? [String: Any] { return p }
        if let s = row["params"] as? String, let d = s.data(using: .utf8), let p = JSONLossless.parseObject(d) { return p }
        return [:]
    }

    /// The board list (`fetchBoardPins` box: {items, boardVersion, pinLimit}) as the pinned bar's list, newest first,
    /// plus the raw topics by id (sent back verbatim by `unpinv2`).
    static func parseBoardTopics(
        _ box: [String: Any],
        convId: String,
        senderName: (String) -> String? = { _ in nil }
    ) -> (list: PinnedList, raw: [String: [String: Any]], version: Int64) {
        let rows = (box["items"] as? [[String: Any]]) ?? []
        let version = JSONLossless.int64(box["boardVersion"]) ?? 0
        let limit = Int(JSONLossless.int64(box["pinLimit"]) ?? 0)
        var raw: [String: [String: Any]] = [:]
        let items: [[String: Any]] = rows.compactMap { row in
            let ref = JSONLossless.string(row["id"] ?? row["topicId"] ?? row["topic_id"])
            guard !ref.isEmpty, raw[ref] == nil else { return nil }
            raw[ref] = row
            let params = boardTopicParams(row)
            let kind: String
            switch JSONLossless.int64(row["type"]) ?? 2 {
            case 3: kind = "poll"
            case 0, 1: kind = "reminder"
            default: kind = "message"
            }
            let senderUid = stripUserPrefix(JSONLossless.string(params["senderUid"] ?? params["senderId"] ?? row["creatorId"]))
            var sender = JSONLossless.string(params["senderName"] ?? params["sender_name"] ?? params["dName"] ?? params["fromName"] ?? row["creatorName"])
            if sender.isEmpty, !senderUid.isEmpty { sender = senderName(senderUid) ?? "" }
            let title = JSONLossless.string(
                params["title"] ?? params["linkCaption"] ?? params["content"] ?? params["msg"] ?? params["message"]
                    ?? params["description"] ?? row["title"] ?? row["content"]
            )
            return [
                "ref": ref,
                "kind": kind,
                "title": title,
                "sender": sender,
                "thumb": JSONLossless.string(params["thumb"]),
                "msgId": JSONLossless.string(params["globalMsgId"] ?? params["global_msg_id"] ?? params["msgId"] ?? params["msg_id"]),
                "cliMsgId": JSONLossless.string(params["cliMsgId"] ?? params["client_msg_id"])
            ]
        }
        let list = PinnedList(json: [
            "convId": convId, "ready": true, "canPin": true, "items": items,
            "limit": limit > 0 ? limit : defaultPinLimit
        ])
        return (list, raw, version)
    }
}

extension ZaloEngine {
    /// The open board pins this message.
    func isPinned(_ message: ChatMessage) -> Bool {
        pins[message.conversationId]?.items.contains { $0.message(in: [message]) != nil } ?? false
    }

    /// 1:1 chats pin to the oneone board once it could be read (the parsed menu offers "Ghim" in groups only).
    func canPinMessage(_ message: ChatMessage) -> Bool {
        guard let list = pins[message.conversationId], list.ready, list.canPin, !message.isE2EE else { return false }
        switch message.kind {
        case .recalled, .call, .placeholder, .system, .notice: return false
        default: return message.status != .sending && message.status != .failed
        }
    }

    /// "Ghim tin nhắn" from the message menu: the official limit check first (`checkPinTopic`), then the pin.
    func pinMessage(_ message: ChatMessage) {
        let conversation = message.conversationId
        guard !isPinned(message) else { return }
        let list = pins[conversation]
        let items = list?.items ?? []
        let limit = list?.limit ?? ZaloWireParser.defaultPinLimit
        switch PinLimitDecision.decide(count: items.count, limit: limit) {
        case .allowed:
            pin(message)
        case .replaceOldest:
            guard let oldest = items.last, openConversationId == conversation, messageConfirm == nil else { return }
            let what = oldest.title.isEmpty ? oldest.label : "\(oldest.label): \(oldest.title)"
            messageConfirm = MessageActionConfirm(
                conversationId: conversation,
                action: .pin(message, replacing: oldest.ref),
                title: "Cập nhật danh sách ghim",
                message: "Đã đạt giới hạn \(limit) ghim. Ghim cũ dưới đây sẽ được bỏ để cập nhật nội dung mới.\n\(what)",
                ok: "Xác nhận"
            )
        case .chooseMany(let need):
            CardActionCenter.shared.show(
                "Đã đạt giới hạn \(limit) ghim. Vui lòng chọn ít nhất \(need) ghim cần bỏ để cập nhật ghim mới.",
                in: conversation
            )
        }
    }

    /// Shows the pin at once (newest first, the replaced one gone); the board re-fetch that follows the request settles it.
    internal func insertPinOptimistically(_ message: ChatMessage, replacing ref: String?) {
        let conversation = message.conversationId
        guard var list = pins[conversation] else { return }
        if let ref { list.items.removeAll { $0.ref == ref } }
        let item = PinnedItem(
            ref: "local:\(message.id)", kind: .message, title: Self.messagePreviewLabel(message),
            sender: message.isMine ? "Bạn" : (lookupPersonInfo(message.senderId)?.name ?? ""),
            thumbnail: nil, msgId: message.id, cliMsgId: message.id
        )
        list.items.insert(item, at: 0)
        pins[conversation] = list
    }

    internal func removePinOptimistically(_ ref: String, in conversationId: String) {
        guard var list = pins[conversationId] else { return }
        list.items.removeAll { $0.ref == ref }
        pins[conversationId] = list
    }

    /// Loads the pinned message into the open chat (from the local store when it is older than what is shown); its row id, or nil.
    func loadPinnedMessage(_ item: PinnedItem, in conversationId: String) async -> String? {
        if let loaded = item.message(in: messages[conversationId] ?? []) { return loaded.id }
        guard item.kind == .message, let store = sqliteStore else { return nil }
        for key in [item.msgId, item.cliMsgId] where !key.isEmpty {
            if let row = try? await store.decodedMessage(convId: conversationId, idOrClientId: key) {
                if await ensureMessageLoaded(row.message, in: conversationId) { return row.message.id }
            }
        }
        return nil
    }

    /// A pin control event: re-read the board of the open chat; others are dropped so their next open reads it fresh.
    func handlePinTopicEvent(conversationId: String) {
        if openConversationId == conversationId {
            Task { await refreshBoardPins(for: conversationId) }
        } else {
            pins[conversationId] = nil
        }
    }
}
