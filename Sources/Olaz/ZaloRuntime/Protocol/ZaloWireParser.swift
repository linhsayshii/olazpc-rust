import Foundation

/// Sendable wrapper used to pass JSON dictionaries across Swift 6 actor boundaries.
struct ZaloJSONBox: @unchecked Sendable {
    let dict: [String: Any]
    init(_ dict: [String: Any] = [:]) { self.dict = dict }
}

/// Sendable wrapper for arrays of JSON dictionaries across actor boundaries.
struct ZaloJSONArrayBox: @unchecked Sendable {
    let array: [[String: Any]]
    init(_ array: [[String: Any]] = []) { self.array = array }
}

enum ParsedWireEvent: Sendable {
    case message(ChatMessage, StoredMessage)
    case reaction(
        convId: String,
        msgId: String,
        cliMsgId: String,
        senderId: String,
        rType: String,
        rIcon: String,
        eventId: String = "",
        reactClientId: String = "",
        tsMs: Int64 = 0,
        seqId: Int64 = 0,
        senderName: String = ""
    )
    case undo(convId: String, msgId: String, cliMsgId: String)
    case delete(convId: String, msgId: String, cliMsgId: String)
    case typing(convId: String, senderId: String, isGroup: Bool)
    case ignore
}

enum ZaloWireParser {
    // MARK: - Conversation ID Normalization

    static func cleanGroupId(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("group_") {
            s = String(s.dropFirst(6))
        } else if (s.hasPrefix("g") || s.hasPrefix("G")), s.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) {
            s = String(s.dropFirst())
        }
        return s
    }

    static func groupConvId(_ raw: String) -> String {
        let clean = cleanGroupId(raw)
        return (clean.isEmpty || clean == "0") ? "" : "g\(clean)"
    }

    static func isGroupId(_ id: String) -> Bool {
        if id.hasPrefix("group_") {
            let rest = id.dropFirst(6)
            return !rest.isEmpty && rest != "0"
        }
        return id.hasPrefix("g") && id.count > 1 && id != "g0" && id.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func stripUserPrefix(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sanitizeProfileUid(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let underscoreIdx = s.firstIndex(of: "_") {
            let suffix = s[s.index(after: underscoreIdx)...]
            guard !suffix.isEmpty, suffix.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                return nil
            }
            s = String(s[..<underscoreIdx])
        }
        if s.hasPrefix("u") {
            let rest = s.dropFirst()
            if !rest.isEmpty && rest.allSatisfy({ $0.isASCII && $0.isNumber }) {
                s = String(rest)
            }
        }
        guard !s.isEmpty, s != "0", !s.allSatisfy({ $0 == "0" }),
              (1...24).contains(s.count),
              s.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        return s
    }

    /// Strips Zalo's `"u"` prefix used specifically by pin/archive list APIs (`["u12345", "g678"]`).
    static func normalizeThreadIdFromList(_ id: String) -> String {
        if id.hasPrefix("u"), id.count > 1, id.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) {
            return String(id.dropFirst())
        }
        if id.hasPrefix("g") || id.hasPrefix("group_") {
            return groupConvId(id)
        }
        return id
    }

    // MARK: - Reactions

    static func reactionSpec(forEmoji emoji: String) -> (rIcon: String, rType: Int) {
        let normalized = emoji
            .replacingOccurrences(of: "\u{FE0F}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalized {
        case "👍", "/-strong": return ("/-strong", 3)
        case "❤", "/-heart": return ("/-heart", 5)
        case "😆", ":>": return (":>", 0)
        case "😮", ":o": return (":o", 32)
        case "😢", ":-((" , ":-(": return (":-((" , 2)
        case "😡", "😠", ":-h": return (":-h", 20)
        default: return ("/-strong", 3)
        }
    }

    static func reactionIcon(rType: String, rIcon: String = "") -> ReactionIcon? {
        let t = rType.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = rIcon.trimmingCharacters(in: .whitespacesAndNewlines)
        if let numericType = Int(t), numericType < 0 {
            return nil
        }
        switch (t, k) {
        case ("3", _), (_, "/-strong"):
            return ReactionIcon(type: "3", key: "/-strong", emoji: "👍")
        case ("5", _), (_, "/-heart"):
            return ReactionIcon(type: "5", key: "/-heart", emoji: "❤️")
        case ("0", _), (_, ":>"):
            return ReactionIcon(type: "0", key: ":>", emoji: "😆")
        case ("32", _), (_, ":o"):
            return ReactionIcon(type: "32", key: ":o", emoji: "😮")
        case ("2", _), (_, ":-(("), (_, ":-("):
            return ReactionIcon(type: "2", key: ":-((" , emoji: "😢")
        case ("20", _), (_, ":-h"):
            return ReactionIcon(type: "20", key: ":-h", emoji: "😡")
        default:
            guard !k.isEmpty else { return nil }
            let fallbackType = t.isEmpty ? k : t
            return ReactionIcon(type: fallbackType, key: k, emoji: k)
        }
    }

    static func reactionClientMsgType(for kind: ChatMessage.Kind) -> Int {
        switch kind {
        case .text: return 1
        case .voice: return 31
        case .photo: return 32
        case .sticker: return 36
        case .link, .contactCard: return 38
        case .location: return 43
        case .video: return 44
        case .file: return 46
        case .gif: return 49
        default: return 1
        }
    }

    // MARK: - Wire Message Parsing

    static func stickerCDNURL(cateId: Int, stickerId: String) -> String {
        let sidStr = stickerId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sidStr.isEmpty else { return "" }
        if cateId == 0, let sid = Int(sidStr), (1...30).contains(sid) {
            return "https://stc-chat.zdn.vn/images/stickers/default/thumb/\(sid).png"
        }
        return "https://api.zaloapp.com/api/emoticon/sticker/webpc?eid=\(sidStr)&size=130"
    }

    static func normalizedMsgType(_ rawType: String) -> String {
        switch rawType.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1": return "webchat"
        case "2": return "chat.photo"
        case "3": return "chat.voice"
        case "4": return "chat.video.msg"
        case "5": return "chat.sticker"
        case "19": return "share.file"
        case "24": return "chat.location.new"
        case "31": return "chat.undo"
        default: return rawType
        }
    }

    static func zdbMsgType(for code: Int) -> String {
        switch code {
        case 1: return "webchat"
        case 2, 11, 12: return "chat.photo"
        case 3: return "chat.voice"
        case 4: return "chat.sticker"
        case 5: return "chat.doodle"
        case 6: return "chat.recommended"
        case 7: return "chat.gif"
        case 17: return "chat.location.new"
        case 18: return "chat.video.msg"
        case 19, 23: return "share.file"
        case 20, 25: return "chat.ecard"
        case 21: return "chat.list.action"
        case 26: return "group.poll"
        case 52: return "chat.webcontent"
        case 53: return "chat.webcontent.v2"
        case 2511, -4: return "group.event"
        default: return "webchat"
        }
    }

    static func previewLabel(for kindTag: String, text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        switch kindTag {
        case "photo": return "[Hình ảnh]"
        case "video": return "[Video]"
        case "sticker": return "[Sticker]"
        case "gif": return "[GIF]"
        case "voice": return "[Tin nhắn thoại]"
        case "file": return "[Tệp đính kèm]"
        case "location": return "[Vị trí]"
        case "contactCard": return "[Danh thiếp]"
        case "call": return "Cuộc gọi thoại"
        case "poll": return "[Bình chọn]"
        case "ecard": return "[Thiệp]"
        case "recalled": return "Tin nhắn đã được thu hồi"
        default: return "[Tin nhắn]"
        }
    }

    static func parseWireMessage(
        _ raw: [String: Any],
        myUid: String,
        cmd: UInt16 = 0,
        fallbackConvId: String? = nil,
        isGroupHint: Bool? = nil,
        selfConvId: String? = nil,
        nameLookup: ((String) -> (name: String, avatar: String)?)? = nil
    ) -> ParsedWireEvent {
        let uidFrom = stripUserPrefix(JSONLossless.string(raw["uidFrom"] ?? raw["senderId"]))
        let idToRaw = JSONLossless.string(raw["idTo"] ?? raw["toId"] ?? raw["convId"] ?? raw["grid"])
        let msgId = JSONLossless.string(raw["msgId"] ?? raw["globalMsgId"] ?? raw["id"])
        let cliMsgId = JSONLossless.string(raw["cliMsgId"] ?? raw["clientId"])
        let rawMsgType = JSONLossless.string(raw["msgType"] ?? raw["type"])
        let msgType = normalizedMsgType(rawMsgType)

        let sanitizedFallback: String? = {
            guard let f = fallbackConvId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !f.isEmpty, f != "0", f != "g0" else { return nil }
            return f
        }()

        let inferredGroup: Bool = {
            if let isGroupHint { return isGroupHint }
            if cmd == ZaloWebSocket.cmdPushMsgGroup || cmd == ZaloWebSocket.cmdPullMsgGroup { return true }
            if isGroupId(idToRaw) { return true }
            if let sanitizedFallback, isGroupId(sanitizedFallback) { return true }
            if let msgGroup = raw["isGroup"] as? Bool { return msgGroup }
            if let grid = raw["grid"] as? String, !grid.isEmpty, cleanGroupId(grid) != "0" { return true }
            return false
        }()

        let cleanIdTo = cleanGroupId(idToRaw)
        let isExplicitSelfCloud = (
            selfConvId != nil
            && !selfConvId!.isEmpty
            && (sanitizedFallback == selfConvId || cleanIdTo == selfConvId)
        )
        let isSelfCloudEnvelope = isExplicitSelfCloud || (
            !inferredGroup
            && (idToRaw == "0" || idToRaw.isEmpty)
            && (uidFrom == "0" || uidFrom.isEmpty)
        )

        let isMine = isSelfCloudEnvelope
            || uidFrom == myUid
            || uidFrom == "0"
            || (raw["isMine"] as? Bool == true)

        let convId: String = {
            if isExplicitSelfCloud, let selfConvId {
                return selfConvId
            }
            if inferredGroup {
                let rawGroup = (!idToRaw.isEmpty && idToRaw != "0") ? idToRaw : (sanitizedFallback ?? "")
                let g = groupConvId(rawGroup)
                if !g.isEmpty { return g }
                if let sanitizedFallback, isGroupId(sanitizedFallback) { return sanitizedFallback }
            }
            if isSelfCloudEnvelope {
                return firstNonEmpty(selfConvId, sanitizedFallback, myUid)
            }
            if let selfConvId, !selfConvId.isEmpty,
               (idToRaw == selfConvId || (uidFrom == myUid && idToRaw == myUid)) {
                return selfConvId
            }
            if isMine {
                if !idToRaw.isEmpty && idToRaw != "0" && idToRaw != myUid {
                    return stripUserPrefix(idToRaw)
                }
                if let sanitizedFallback {
                    return stripUserPrefix(sanitizedFallback)
                }
                return firstNonEmpty(selfConvId, myUid)
            }
            if !uidFrom.isEmpty && uidFrom != "0" && uidFrom != myUid {
                return uidFrom
            }
            if let sanitizedFallback {
                return stripUserPrefix(sanitizedFallback)
            }
            return stripUserPrefix(idToRaw)
        }()

        guard !convId.isEmpty && convId != "0" && convId != "g0" else { return .ignore }

        // Content may arrive as a string, parsed JSON dict, or array of photo items (`MSG.PHOTO_GROUP`).
        let rawContent = raw["content"]
        let contentDict: [String: Any]? = {
            if let dict = rawContent as? [String: Any] { return dict }
            if let arr = rawContent as? [[String: Any]], let first = arr.first { return first }
            if let str = rawContent as? String {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) {
                    return JSONLossless.parseObject(data)
                }
                if trimmed.hasPrefix("["), let data = trimmed.data(using: .utf8),
                   let arr = JSONLossless.parseAny(data) as? [[String: Any]], let first = arr.first {
                    return first
                }
            }
            return nil
        }()
        let contentParams: [String: Any]? = {
            if let p = contentDict?["params"] as? [String: Any] { return p }
            if let pStr = contentDict?["params"] as? String,
               let pData = pStr.data(using: .utf8) {
                return JSONLossless.parseObject(pData)
            }
            return nil
        }()

        // Control message types
        switch msgType {
        case "chat.undo":
            let undoMsgId = JSONLossless.string(contentDict?["globalMsgId"] ?? raw["globalMsgId"] ?? msgId)
            let undoCliId = JSONLossless.string(contentDict?["cliMsgId"] ?? raw["cliMsgId"] ?? cliMsgId)
            return .undo(convId: convId, msgId: undoMsgId, cliMsgId: undoCliId)

        case "chat.delete":
            let delMsgId = JSONLossless.string(contentDict?["globalDelMsgId"] ?? contentDict?["globalMsgId"] ?? msgId)
            let delCliId = JSONLossless.string(contentDict?["clientDelMsgId"] ?? contentDict?["cliMsgId"] ?? cliMsgId)
            return .delete(convId: convId, msgId: delMsgId, cliMsgId: delCliId)

        case "chat.reaction":
            let rMsgRaw: Any? = {
                guard let rawRMsg = contentDict?["rMsg"] else { return nil }
                if let str = rawRMsg as? String {
                    let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                    if (trimmed.hasPrefix("[") || trimmed.hasPrefix("{")),
                       let data = trimmed.data(using: .utf8),
                       let parsed = JSONLossless.parseAny(data) {
                        return parsed
                    }
                }
                return rawRMsg
            }()
            let targetMsgId: String
            let targetCliId: String
            if let rMsgs = (rMsgRaw as? [[String: Any]]) ?? (rMsgRaw as? [Any])?.compactMap({ $0 as? [String: Any] }),
               let first = rMsgs.first {
                targetMsgId = JSONLossless.string(first["gMsgID"] ?? first["msgId"] ?? first["globalMsgId"])
                targetCliId = JSONLossless.string(first["cMsgID"] ?? first["cliMsgId"] ?? first["clientId"])
            } else if let single = rMsgRaw as? [String: Any] {
                targetMsgId = JSONLossless.string(single["gMsgID"] ?? single["msgId"] ?? single["globalMsgId"])
                targetCliId = JSONLossless.string(single["cMsgID"] ?? single["cliMsgId"] ?? single["clientId"])
            } else {
                let scalarRMsg = (rMsgRaw is String) ? JSONLossless.string(rMsgRaw) : ""
                targetMsgId = firstNonEmpty(
                    JSONLossless.string(contentDict?["gMsgID"] ?? contentDict?["msgId"] ?? contentDict?["globalMsgId"]),
                    scalarRMsg
                )
                targetCliId = JSONLossless.string(contentDict?["cMsgID"] ?? contentDict?["cliMsgId"] ?? contentDict?["clientId"])
            }
            let rIcon = JSONLossless.string(contentDict?["rIcon"])
            let rType = JSONLossless.string(contentDict?["rType"])
            guard (!targetMsgId.isEmpty || !targetCliId.isEmpty),
                  (!rType.isEmpty || !rIcon.isEmpty) else {
                return .ignore
            }
            let eventId = firstNonEmpty(JSONLossless.string(raw["actionId"]), msgId, cliMsgId)
            let reactionSender = firstNonEmpty(
                uidFrom,
                stripUserPrefix(JSONLossless.string(raw["fromUid"] ?? contentDict?["uidFrom"] ?? contentDict?["fromUid"]))
            )
            let reactionTsMs = optionalTimestampMs(raw["ts"] ?? raw["time"] ?? raw["sendTime"] ?? contentDict?["ts"])
            let reactionSeqId = JSONLossless.int64(raw["actionId"] ?? raw["msgId"] ?? raw["cliMsgId"]) ?? 0
            let reactionSenderName = JSONLossless.string(raw["dName"] ?? raw["senderName"] ?? contentDict?["dName"])
            return .reaction(
                convId: convId,
                msgId: targetMsgId,
                cliMsgId: targetCliId,
                senderId: reactionSender,
                rType: rType,
                rIcon: rIcon,
                eventId: eventId,
                reactClientId: cliMsgId,
                tsMs: reactionTsMs,
                seqId: reactionSeqId,
                senderName: reactionSenderName
            )

        default:
            break
        }

        let stableId: String = {
            if !msgId.isEmpty && msgId != "0" { return msgId }
            if !cliMsgId.isEmpty { return cliMsgId }
            return "\(Int64(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(6))"
        }()

        let tsMs = normalizeTimestampMs(raw["ts"] ?? raw["time"] ?? raw["sendTime"] ?? raw["date"])

        let lookup = (uidFrom.isEmpty || uidFrom == "0") ? nil : nameLookup?(uidFrom)
        let wireSenderName = JSONLossless.string(raw["dName"] ?? raw["senderName"])
        let resolvedContactName: String = {
            guard let n = lookup?.name, !n.isEmpty, n != uidFrom, n != "Người dùng Zalo" else { return "" }
            return n
        }()
        let senderName = firstNonEmpty(
            isMine ? "Bạn" : resolvedContactName,
            wireSenderName,
            lookup?.name,
            isMine ? "Bạn" : "Người dùng Zalo"
        )
        let senderAvatar = firstNonEmpty(
            lookup?.avatar,
            JSONLossless.string(raw["avt"] ?? raw["senderAvatar"])
        )

        var textBody = ""
        var kindDict: [String: Any] = ["type": "text"]
        var kindTag = "text"
        var buttonsArray: [[String: Any]] = []
        var suggestsStickers = false

        switch msgType {
        case "", "webchat", "chat.text" where JSONLossless.string(contentDict?["action"]) == "msginfo.actionlist":
            // Info notices (pin / unpin … synced from the phone): a system line, like under `chat.recommended`.
            kindDict = ["type": "system"]
            kindTag = "system"
            textBody = firstNonEmpty(JSONLossless.string(contentDict?["title"]), JSONLossless.string(contentDict?["description"]), "Thông báo hệ thống")

        case "", "webchat", "chat.text":
            if let str = rawContent as? String, contentDict == nil {
                textBody = str
            } else if JSONLossless.string(contentDict?["action"]) == "rtf" {
                textBody = firstNonEmpty(
                    JSONLossless.string(contentParams?["text"]),
                    JSONLossless.string(contentDict?["title"]),
                    JSONLossless.string(contentDict?["description"])
                )
            } else {
                textBody = JSONLossless.string(contentDict?["title"] ?? contentDict?["msg"] ?? contentDict?["text"] ?? raw["text"])
            }
            kindDict = ["type": "text"]
            kindTag = "text"

        case "chat.photo", "chat.doodle":
            let photoCandidates = Self.uniqueNonEmptyStrings([
                JSONLossless.string(contentParams?["hd"]),
                JSONLossless.string(contentParams?["hdUrl"]),
                JSONLossless.string(contentDict?["hd"]),
                JSONLossless.string(contentDict?["hdUrl"]),
                JSONLossless.string(contentParams?["rawUrl"]),
                JSONLossless.string(contentDict?["oriUrl"]),
                JSONLossless.string(contentDict?["rawUrl"]),
                JSONLossless.string(contentDict?["normalUrl"]),
                JSONLossless.string(contentDict?["href"]),
                JSONLossless.string(contentDict?["url"]),
                JSONLossless.string(contentDict?["fileUrl"]),
                JSONLossless.string(contentDict?["thumb"]),
                JSONLossless.string(contentDict?["thumbUrl"]),
                JSONLossless.string(contentParams?["thumb"]),
            ])
            let urlStr = photoCandidates.first ?? ""
            let fallbackStrs = Array(photoCandidates.dropFirst())
            let w = JSONLossless.int64(contentParams?["width"] ?? contentDict?["width"]) ?? 0
            let h = JSONLossless.int64(contentParams?["height"] ?? contentDict?["height"]) ?? 0
            textBody = firstNonEmpty(
                JSONLossless.string(contentDict?["title"]),
                JSONLossless.string(contentDict?["description"])
            )
            if textBody == "[Hình ảnh]" { textBody = "" }
            var pDict: [String: Any] = ["type": "photo", "url": urlStr, "width": Int(w), "height": Int(h)]
            if !fallbackStrs.isEmpty { pDict["fallbacks"] = fallbackStrs }
            kindDict = pDict
            kindTag = "photo"

        case "chat.sticker":
            let stickerId = JSONLossless.string(contentDict?["id"] ?? contentDict?["stickerId"] ?? contentParams?["id"] ?? contentParams?["stickerId"])
            let cateId = Int(JSONLossless.int64(contentDict?["catId"] ?? contentDict?["cateId"] ?? contentParams?["catId"] ?? contentParams?["cateId"]) ?? -1)
            let urlStr = firstNonEmpty(
                JSONLossless.string(contentDict?["stickerUrl"]),
                JSONLossless.string(contentDict?["href"]),
                stickerCDNURL(cateId: cateId, stickerId: stickerId)
            )
            kindDict = ["type": "sticker", "url": urlStr]
            kindTag = "sticker"
            textBody = "[Sticker]"

        case "chat.gif":
            let urlStr = firstNonEmpty(
                JSONLossless.string(contentDict?["href"]),
                JSONLossless.string(contentDict?["oriUrl"]),
                JSONLossless.string(contentDict?["hd"]),
                JSONLossless.string(contentDict?["hdUrl"]),
                JSONLossless.string(contentDict?["normalUrl"]),
                JSONLossless.string(contentDict?["thumb"]),
                JSONLossless.string(contentDict?["thumbUrl"])
            )
            kindDict = ["type": "gif", "url": urlStr]
            kindTag = "gif"
            textBody = "[GIF]"

        case "chat.video.msg":
            let videoCandidates = Self.uniqueNonEmptyStrings([
                JSONLossless.string(contentDict?["href"]),
                JSONLossless.string(contentDict?["fileUrl"]),
                JSONLossless.string(contentDict?["videoUrl"]),
                JSONLossless.string(contentDict?["url"]),
                JSONLossless.string(contentDict?["oriUrl"]),
                JSONLossless.string(contentDict?["hd"]),
                JSONLossless.string(contentDict?["hdUrl"]),
                JSONLossless.string(contentDict?["normalUrl"]),
                JSONLossless.string(contentParams?["fileUrl"]),
                JSONLossless.string(contentParams?["hd"]),
                JSONLossless.string(contentParams?["href"]),
            ])
            let urlStr = videoCandidates.first ?? ""
            let fallbackStrs = Array(videoCandidates.dropFirst())
            let thumbStr = firstNonEmpty(
                JSONLossless.string(contentDict?["thumb"]),
                JSONLossless.string(contentDict?["thumbUrl"]),
                JSONLossless.string(contentParams?["thumb"])
            )
            let durRaw = (JSONLossless.int64(contentParams?["duration"] ?? contentDict?["duration"]) ?? 0)
            let durSec = durRaw > 10_000 ? Int(durRaw / 1000) : Int(durRaw)
            textBody = JSONLossless.string(contentDict?["title"])
            var vDict: [String: Any] = ["type": "video", "thumbnail": thumbStr, "duration": durSec, "url": urlStr]
            if !fallbackStrs.isEmpty { vDict["fallbacks"] = fallbackStrs }
            kindDict = vDict
            kindTag = "video"

        case "chat.voice":
            let urlStr = firstNonEmpty(
                JSONLossless.string(contentDict?["href"]),
                JSONLossless.string(contentDict?["oriUrl"]),
                JSONLossless.string(contentDict?["voiceUrl"]),
                JSONLossless.string(contentDict?["fileUrl"]),
                JSONLossless.string(contentParams?["m4a"])
            )
            let durRaw = JSONLossless.int64(contentParams?["duration"] ?? contentDict?["duration"]) ?? 0
            let durSec = durRaw > 10_000 ? Int(durRaw / 1000) : Int(durRaw)
            kindDict = ["type": "voice", "url": urlStr, "duration": durSec]
            kindTag = "voice"
            textBody = "[Tin nhắn thoại]"

        case "share.file":
            let urlStr = firstNonEmpty(
                JSONLossless.string(contentDict?["href"]),
                JSONLossless.string(contentDict?["fileUrl"]),
                JSONLossless.string(contentDict?["url"]),
                JSONLossless.string(contentParams?["href"]),
                JSONLossless.string(contentParams?["fileUrl"]),
                JSONLossless.string(contentParams?["url"])
            )
            let rawTitle = firstNonEmpty(
                JSONLossless.string(contentDict?["title"]),
                JSONLossless.string(contentParams?["fileName"]),
                "Tệp đính kèm"
            )
            let rawExt = JSONLossless.string(contentParams?["fileExt"] ?? contentDict?["fileExt"])
            let fileName = Self.normalizedFileName(rawTitle, fileExt: rawExt)
            let size = JSONLossless.int64(contentParams?["fileSize"] ?? contentDict?["fileSize"]) ?? 0
            kindDict = ["type": "file", "name": fileName, "size": size, "url": urlStr]
            kindTag = "file"
            textBody = fileName

        case "chat.recommended":
            let action = JSONLossless.string(contentDict?["action"])
            switch action {
            case "recommened.link", "recommended.link":
                let urlStr = JSONLossless.string(contentDict?["href"])
                let title = firstNonEmpty(JSONLossless.string(contentDict?["title"]), urlStr)
                let thumb = JSONLossless.string(contentDict?["thumb"])
                let desc = JSONLossless.string(contentDict?["description"])
                let src = JSONLossless.string(contentParams?["src"] ?? contentDict?["src"])
                kindDict = ["type": "link", "title": title, "url": urlStr, "thumbnail": thumb, "description": desc, "source": src]
                kindTag = "link"
                textBody = title
            case "recommened.user", "recommened.vip", "recommended.user":
                let rawParamsStr = (contentDict?["params"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let plainParamUid = (contentParams == nil && !rawParamsStr.isEmpty && !rawParamsStr.hasPrefix("{")) ? stripUserPrefix(rawParamsStr) : ""
                let cardUid = firstNonEmpty(JSONLossless.string(contentParams?["uid"]), plainParamUid, JSONLossless.string(contentDict?["title"]))
                let cardName = firstNonEmpty(
                    JSONLossless.string(contentParams?["userName"]),
                    plainParamUid.isEmpty ? "" : JSONLossless.string(contentDict?["title"]),
                    JSONLossless.string(contentDict?["description"]),
                    cardUid
                )
                let avatar = JSONLossless.string(contentDict?["thumb"] ?? contentParams?["avatar"])
                let phone = JSONLossless.string(contentParams?["phone"])
                let qr = JSONLossless.string(contentParams?["qr"])
                let oaLink = JSONLossless.string(contentParams?["oaLink"])
                let isOA = action == "recommened.vip"
                kindDict = ["type": "contactCard", "name": cardName, "uid": cardUid, "avatar": avatar, "phone": phone, "qr": qr, "oaLink": oaLink, "isOA": isOA]
                kindTag = "contactCard"
                textBody = "[Danh thiếp] \(cardName)"
            case "recommened.calltime", "recommened.misscall":
                let missed = action == "recommened.misscall"
                let callType = JSONLossless.int64(contentParams?["callType"] ?? contentParams?["type"]) ?? 0
                let isVideo = callType == 2 || JSONLossless.string(contentParams?["callType"]).lowercased().contains("video")
                let dur = Int(JSONLossless.int64(contentParams?["duration"]) ?? 0)
                let title = isVideo ? (missed ? "Cuộc gọi video nhỡ" : "Cuộc gọi video") : (missed ? "Cuộc gọi nhỡ" : "Cuộc gọi thoại")
                kindDict = ["type": "call", "video": isVideo, "missed": missed, "duration": dur, "title": title, "detail": ""]
                kindTag = "call"
                textBody = title
                buttonsArray = [["ref": "call:back", "label": "Gọi lại", "enabled": true]]
            case "rtf":
                kindDict = ["type": "text"]
                kindTag = "text"
                textBody = firstNonEmpty(JSONLossless.string(contentParams?["text"]), JSONLossless.string(contentDict?["title"]), JSONLossless.string(contentDict?["description"]))
            case "msginfo.actionlist":
                kindDict = ["type": "system"]
                kindTag = "system"
                textBody = firstNonEmpty(JSONLossless.string(contentDict?["title"]), JSONLossless.string(contentDict?["description"]), "Thông báo hệ thống")
            default:
                let urlStr = JSONLossless.string(contentDict?["href"])
                let title = JSONLossless.string(contentDict?["title"])
                if !urlStr.isEmpty {
                    kindDict = ["type": "link", "title": title.isEmpty ? urlStr : title, "url": urlStr, "thumbnail": JSONLossless.string(contentDict?["thumb"]), "description": JSONLossless.string(contentDict?["description"]), "source": ""]
                    kindTag = "link"
                    textBody = title.isEmpty ? urlStr : title
                } else {
                    kindDict = ["type": "text"]
                    textBody = firstNonEmpty(title, JSONLossless.string(contentDict?["description"]), "[Tin nhắn]")
                }
            }

        case "chat.location.new", "chat.location":
            let lat = Self.doubleValue(contentParams?["lat"] ?? contentParams?["latitude"] ?? contentDict?["lat"]) ?? 0
            let lon = Self.doubleValue(contentParams?["lon"] ?? contentParams?["lo"] ?? contentParams?["lng"] ?? contentParams?["longitude"] ?? contentDict?["lo"] ?? contentDict?["lon"]) ?? 0
            let title = firstNonEmpty(JSONLossless.string(contentParams?["locationName"]), JSONLossless.string(contentDict?["title"]), "Vị trí")
            let address = JSONLossless.string(contentParams?["address"] ?? contentDict?["description"])
            let thumb = JSONLossless.string(contentDict?["thumb"])
            kindDict = [
                "type": "location",
                "title": title,
                "address": address,
                "hasCoordinates": (lat != 0 || lon != 0),
                "latitude": lat,
                "longitude": lon,
                "thumbnail": thumb
            ]
            kindTag = "location"
            textBody = title

        case "chat.ecard":
            let action = JSONLossless.string(contentDict?["action"])
            let style: String = {
                if action.contains("reminder") { return "reminder" }
                if action.contains("birthday") { return "birthday" }
                if action.contains("friend") { return "friend" }
                return "banner"
            }()
            let title = JSONLossless.string(contentDict?["title"])
            let desc = JSONLossless.string(contentDict?["description"])
            let image = JSONLossless.string(contentDict?["href"])
            let thumb = JSONLossless.string(contentDict?["thumb"])
            suggestsStickers = (contentParams?["stickerList"] as? [Any])?.isEmpty == false || style == "friend" || style == "birthday"
            kindDict = [
                "type": "ecard",
                "style": style,
                "image": image,
                "thumb": thumb,
                "title": title,
                "description": desc,
                "reminderTitle": JSONLossless.string(contentParams?["topicTitle"] ?? title),
                "reminderStart": (JSONLossless.int64(contentParams?["startTime"]) ?? 0),
                "reminderRepeat": JSONLossless.string(contentParams?["repeatLabel"])
            ]
            kindTag = "ecard"
            textBody = firstNonEmpty(title, desc, "[Thiệp]")

        case "group.poll", "chat.poll":
            let pollId = JSONLossless.string(contentParams?["poll_id"] ?? contentParams?["pollId"] ?? contentDict?["pollId"])
            let question = firstNonEmpty(JSONLossless.string(contentParams?["question"] ?? contentDict?["title"]), "Bình chọn")
            // Official `_onMessageInfoEvent`: actor + verb of `content.action` + question (params).
            let verb: String = [
                "create": "tạo cuộc bình chọn mới", "share": "chia sẻ cuộc bình chọn", "vote": "tham gia cuộc bình chọn",
                "update": "đổi lựa chọn trong cuộc bình chọn", "close": "khóa bình chọn"
            ][JSONLossless.string(contentDict?["action"])] ?? ""
            let actor = isMine ? "Bạn" : JSONLossless.string(contentParams?["dName"])
            let header = firstNonEmpty(
                JSONLossless.string(contentDict?["description"]),
                (!verb.isEmpty && !actor.isEmpty) ? "\(actor) \(verb): \(question)" : ""
            )
            kindDict = [
                "type": "poll",
                "question": question,
                "header": header,
                "anonymous": (contentParams?["is_anonymous"] as? NSNumber)?.boolValue ?? false,
                "pollId": pollId,
                "conversationId": convId
            ]
            kindTag = "poll"
            textBody = question

        case "group.event", "chat.sys":
            let title = firstNonEmpty(JSONLossless.string(contentDict?["title"]), JSONLossless.string(contentDict?["description"]), "Thông báo hệ thống")
            kindDict = ["type": "system"]
            kindTag = "system"
            textBody = title

        case "chat.list.action":
            let items = (rawContent as? [[String: Any]]) ?? (contentDict?["items"] as? [[String: Any]]) ?? []
            let firstItem = items.first ?? contentDict
            let title = JSONLossless.string(firstItem?["title"])
            let desc = JSONLossless.string(firstItem?["description"])
            let combined = (!title.isEmpty && !desc.isEmpty && title != desc) ? "\(title)\n\(desc)" : firstNonEmpty(title, desc, "[Thông báo]")
            kindDict = ["type": "text"]
            kindTag = "text"
            textBody = combined

        case "chat.webcontent", "chat.webcontent.v2":
            var zTitle = firstNonEmpty(JSONLossless.string(contentDict?["title"]), JSONLossless.string(contentDict?["description"]))
            if zTitle.isEmpty,
               let zMsgStr = contentDict?["zinstant_msg"] as? String,
               let zData = zMsgStr.data(using: .utf8),
               let zObj = JSONLossless.parseObject(zData),
               let custom = (zObj["customMsg"] as? [String: Any])?["msg"] as? [String: Any] {
                zTitle = firstNonEmpty(JSONLossless.string(custom["vi"]), JSONLossless.string(custom["en"]))
            }
            if zTitle.isEmpty,
               let custom = (contentParams?["customMsg"] as? [String: Any])?["msg"] as? [String: Any] {
                zTitle = firstNonEmpty(JSONLossless.string(custom["vi"]), JSONLossless.string(custom["en"]))
            }
            kindDict = ["type": "text"]
            kindTag = "text"
            textBody = firstNonEmpty(zTitle, "[Thẻ thông tin]")

        default:
            if let str = rawContent as? String, contentDict == nil, !str.isEmpty {
                kindDict = ["type": "text"]
                kindTag = "text"
                textBody = str
            } else {
                kindDict = ["type": "unsupported", "rawType": msgType]
                kindTag = "unsupported"
                textBody = firstNonEmpty(JSONLossless.string(contentDict?["title"]), JSONLossless.string(contentDict?["description"]), "[\(msgType)]")
            }
        }

        // Mentions
        var mentionsArray: [[String: Any]] = []
        if let rawMentions = (raw["mentions"] as? [[String: Any]]) ?? (contentDict?["mentions"] as? [[String: Any]]) {
            for m in rawMentions {
                let mUid = stripUserPrefix(JSONLossless.string(m["uid"]))
                guard !mUid.isEmpty else { continue }
                let pos = Int(JSONLossless.int64(m["pos"]) ?? 0)
                let len = Int(JSONLossless.int64(m["len"]) ?? 0)
                let isAll = (JSONLossless.int64(m["type"]) == 1) || mUid == "-1" || (m["isAll"] as? Bool == true)
                mentionsArray.append(["uid": mUid, "pos": pos, "len": len, "isAll": isAll])
            }
        }

        // Quote
        var quoteDict: [String: Any]?
        if let q = raw["quote"] as? [String: Any] {
            let qOwner = stripUserPrefix(JSONLossless.string(q["ownerId"] ?? q["senderId"]))
            let qLookupName: String = {
                guard !qOwner.isEmpty, qOwner != "0",
                      let n = nameLookup?(qOwner)?.name, !n.isEmpty, n != qOwner, n != "Người dùng Zalo" else {
                    return ""
                }
                return n
            }()
            let rawQName = firstNonEmpty(
                qOwner == myUid ? "Bạn" : qLookupName,
                JSONLossless.string(q["fromD"] ?? q["senderName"]),
                qOwner == myUid ? "Bạn" : "Người dùng Zalo"
            )
            let qName = Self.isSignalCiphertext(rawQName) ? (qOwner == myUid ? "Bạn" : "Người dùng Zalo") : rawQName
            let rawQText = firstNonEmpty(JSONLossless.string(q["msg"] ?? q["text"]), "[Tin nhắn]")
            let qText = Self.isSignalCiphertext(rawQText) ? "[Tin nhắn mã hóa đầu cuối]" : rawQText
            if !qName.isEmpty || !qText.isEmpty {
                quoteDict = ["senderName": qName, "text": qText]
            }
        }

        // Detect any E2EE payload whose Signal ciphertext could not be decrypted on this device yet
        // (e.g. encrypted to a previous PC prekey before phone sync ran) so raw Base64 / broken sticker URLs never leak!
        var isE2EEFlag = msgType.contains("e2ee")
            || (raw["isE2EE"] as? Bool == true)
            || (JSONLossless.int64(raw["e2eeStatus"]) == 1)
        var isUndecryptedE2EE = false

        let kindURLStr = JSONLossless.string(kindDict["url"])
        let kindFileNameStr = JSONLossless.string(kindDict["name"])
        if kindTag == "text" && Self.isSignalCiphertext(textBody) {
            isE2EEFlag = true
            isUndecryptedE2EE = true
            kindDict = [
                "type": "placeholder",
                "symbol": "lock.fill",
                "text": "Tin nhắn mã hóa đầu cuối — Đồng bộ từ điện thoại để xem",
            ]
            kindTag = "placeholder"
            textBody = "🔒 Tin nhắn mã hóa đầu cuối"
        } else if kindTag == "sticker" && (Self.isSignalCiphertext(kindURLStr) || Self.urlHasUndecryptedSignalCipher(kindURLStr)) {
            isE2EEFlag = true
            isUndecryptedE2EE = true
            kindDict = [
                "type": "placeholder",
                "symbol": "lock.fill",
                "text": "Sticker mã hóa đầu cuối — Đồng bộ từ điện thoại để xem",
            ]
            kindTag = "placeholder"
            textBody = "[Sticker]"
        } else if ["photo", "video", "voice", "file", "gif"].contains(kindTag)
                    && (Self.isSignalCiphertext(kindURLStr) || Self.urlHasUndecryptedSignalCipher(kindURLStr) || Self.isSignalCiphertext(kindFileNameStr)) {
            isE2EEFlag = true
            isUndecryptedE2EE = true
            let mediaTitle: String = {
                switch kindTag {
                case "photo": return "Hình ảnh"
                case "video": return "Video"
                case "voice": return "Tin nhắn thoại"
                case "file": return "Tệp đính kèm"
                case "gif": return "GIF"
                default: return "Nội dung"
                }
            }()
            kindDict = [
                "type": "placeholder",
                "symbol": "lock.fill",
                "text": "\(mediaTitle) mã hóa đầu cuối — Đồng bộ từ điện thoại để xem",
            ]
            kindTag = "placeholder"
            textBody = "[\(mediaTitle)]"
        } else if Self.isSignalCiphertext(textBody) {
            isE2EEFlag = true
            textBody = ""
        }

        // Context menu defaults
        let canRecall = isMine
            && !isSelfCloudEnvelope
            && !["call", "system", "notice", "recalled", "placeholder"].contains(kindTag)
        let menuDict: [String: Any] = [
            "forward": isUndecryptedE2EE ? "blocked" : "ok",
            "recall": canRecall,
            "delete": isSelfCloudEnvelope ? "plain" : "forMe",
            "pin": inferredGroup && !isSelfCloudEnvelope && !isUndecryptedE2EE,
            "star": "star",
            "starred": false,
            "pinned": false,
            "protected": false
        ]

        var canonical: [String: Any] = [
            "id": stableId,
            "clientId": cliMsgId,
            "conversationId": convId,
            "senderId": uidFrom,
            "senderName": senderName,
            "senderAvatar": senderAvatar,
            "isMine": isMine,
            "kind": kindDict,
            "text": textBody,
            "date": tsMs,
            "status": "sent",
            "reactions": [],
            "isE2EE": isE2EEFlag,
            "mentions": mentionsArray,
            "buttons": buttonsArray,
            "stickers": suggestsStickers,
            "menu": menuDict
        ]
        if isUndecryptedE2EE {
            canonical["undecryptedE2EE"] = true
        }
        if let quoteDict { canonical["quote"] = quoteDict }

        guard let rawJSONData = try? JSONSerialization.data(withJSONObject: canonical, options: []),
              let chatMessage = ChatMessage(json: canonical, fallbackConversation: convId) else {
            return .ignore
        }

        let stored = StoredMessage(
            id: stableId,
            convId: convId,
            clientId: cliMsgId,
            senderId: uidFrom,
            senderName: senderName,
            senderAvatar: senderAvatar,
            isMine: isMine,
            text: textBody,
            kindTag: kindTag,
            tsMs: tsMs,
            status: isUndecryptedE2EE ? "e2ee_locked" : "sent",
            rawJSONData: rawJSONData
        )
        return .message(chatMessage, stored)
    }

    // MARK: - Signal E2EE Ciphertext Detection

    /// Returns `true` when `raw` is a Zalo Signal v3 wire ciphertext (`[0x01..0x03, 0x33, <protobuf tag>, ...]`, e.g. `AzM...` / `AjM...`).
    static func isSignalCiphertext(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 52, trimmed.count <= 16_384 else { return false }
        guard !trimmed.contains(where: { $0.isWhitespace }) else { return false }
        let candidate = trimmed.removingPercentEncoding ?? trimmed
        guard let bytes = Data(base64Encoded: candidate), bytes.count >= 40 else { return false }
        let msgType = bytes[0]
        let version = bytes[1]
        let firstProtoTag = bytes[2]
        guard (msgType == 1 || msgType == 2 || msgType == 3), version == 0x33 else {
            return false
        }
        let validTags: Set<UInt8> = [0x08, 0x0A, 0x10, 0x12, 0x18, 0x22, 0x28, 0x30]
        return validTags.contains(firstProtoTag)
    }

    /// Returns `true` when a sticker or CDN URL still carries an un-decrypted Signal ciphertext in `eid` or `e2esession`.
    static func urlHasUndecryptedSignalCipher(_ rawURL: String) -> Bool {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let comps = URLComponents(string: trimmed), let items = comps.queryItems {
            for item in items where item.name == "eid" || item.name == "e2esession" {
                if let val = item.value, isSignalCiphertext(val) {
                    return true
                }
            }
        }
        for marker in ["eid=AzM", "eid=AjM", "e2esession=AzM", "e2esession=AjM"] {
            if trimmed.contains(marker) { return true }
        }
        return false
    }

    // MARK: - Canonical StoredMessage <-> ChatMessage Round-Trip

    static func uniqueNonEmptyStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in values {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }

    static func normalizedFileName(_ rawTitle: String, fileExt: String) -> String {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var ext = fileExt.trimmingCharacters(in: .whitespacesAndNewlines)
        while ext.hasPrefix(".") { ext.removeFirst() }
        ext = ext.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !ext.isEmpty else { return title.isEmpty ? "Tệp đính kèm" : title }
        let base = title.isEmpty ? "Tệp đính kèm" : title
        if base.lowercased().hasSuffix("." + ext.lowercased()) {
            return base
        }
        return base + "." + ext
    }

    static func decodeStoredMessage(_ stored: StoredMessage) -> ChatMessage? {
        guard let dict = (try? JSONSerialization.jsonObject(with: stored.rawJSONData)) as? [String: Any],
              var msg = ChatMessage(json: dict, fallbackConversation: stored.convId) else {
            return nil
        }
        if msg.clientId.isEmpty && !stored.clientId.isEmpty {
            msg.clientId = stored.clientId
        }
        return msg
    }

    static func encodeChatMessage(_ msg: ChatMessage, clientId: String = "") -> StoredMessage? {
        let effectiveClientId = clientId.isEmpty ? msg.clientId : clientId
        var (kindDict, kindTag) = serializeKind(msg.kind)
        if !msg.fallbackURLs.isEmpty {
            kindDict["fallbacks"] = msg.fallbackURLs.map(\.absoluteString)
        }
        let reactionsArr: [[String: Any]] = msg.reactions.map { r in
            var dict: [String: Any] = [
                "type": r.icon.type,
                "key": r.icon.key,
                "emoji": r.icon.emoji,
                "image": r.icon.image,
                "count": r.count,
                "includesMe": r.includesMe,
                "names": r.names,
                "people": r.people
            ]
            if !r.userCounts.isEmpty {
                dict["userCounts"] = r.userCounts
            }
            return dict
        }
        let mentionsArr: [[String: Any]] = msg.mentions.map { m in
            ["uid": m.uid, "pos": m.pos, "len": m.len, "isAll": m.isAll]
        }
        let buttonsArr: [[String: Any]] = msg.cardButtons.map { b in
            ["ref": b.ref, "label": b.label, "enabled": b.enabled, "help": b.help]
        }
        let menuDict: [String: Any] = [
            "forward": msg.menu.forward == .available ? "ok" : (msg.menu.forward == .blocked ? "blocked" : ""),
            "recall": msg.menu.recall,
            "delete": msg.menu.delete?.rawValue ?? "",
            "pin": msg.menu.pin,
            "star": msg.menu.star?.rawValue ?? "",
            "starred": msg.menu.starred,
            "pinned": msg.menu.pinned,
            "protected": msg.menu.isProtected
        ]
        var canonical: [String: Any] = [
            "id": msg.id,
            "clientId": effectiveClientId,
            "conversationId": msg.conversationId,
            "senderId": msg.senderId,
            "senderName": msg.senderName,
            "senderAvatar": msg.senderAvatar?.absoluteString ?? "",
            "isMine": msg.isMine,
            "kind": kindDict,
            "text": msg.text,
            "date": Int64((msg.date.timeIntervalSince1970 * 1000).rounded()),
            "status": msg.status.rawValue,
            "reactions": reactionsArr,
            "isE2EE": msg.isE2EE,
            "mentions": mentionsArr,
            "buttons": buttonsArr,
            "stickers": msg.suggestsStickers,
            "menu": menuDict
        ]
        if let quote = msg.quote {
            canonical["quote"] = ["senderName": quote.senderName, "text": quote.text]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: canonical, options: []) else { return nil }
        return StoredMessage(
            id: msg.id,
            convId: msg.conversationId,
            clientId: effectiveClientId,
            senderId: msg.senderId,
            senderName: msg.senderName,
            senderAvatar: msg.senderAvatar?.absoluteString ?? "",
            isMine: msg.isMine,
            text: msg.text,
            kindTag: kindTag,
            tsMs: Int64((msg.date.timeIntervalSince1970 * 1000).rounded()),
            status: msg.status.rawValue,
            rawJSONData: data
        )
    }

    static func serializeKind(_ kind: ChatMessage.Kind) -> ([String: Any], String) {
        switch kind {
        case .text:
            return (["type": "text"], "text")
        case .photo(let url, let w, let h):
            return (["type": "photo", "url": url?.absoluteString ?? "", "width": w, "height": h], "photo")
        case .sticker(let url):
            return (["type": "sticker", "url": url?.absoluteString ?? ""], "sticker")
        case .gif(let url):
            return (["type": "gif", "url": url?.absoluteString ?? ""], "gif")
        case .video(let thumb, let duration, let url):
            return (["type": "video", "thumbnail": thumb?.absoluteString ?? "", "duration": duration, "url": url?.absoluteString ?? ""], "video")
        case .voice(let url, let duration):
            return (["type": "voice", "url": url?.absoluteString ?? "", "duration": duration], "voice")
        case .file(let name, let size, let url):
            return (["type": "file", "name": name, "size": size, "url": url?.absoluteString ?? ""], "file")
        case .link(let title, let url, let thumb, let desc, let src):
            return ([
                "type": "link", "title": title, "url": url?.absoluteString ?? "",
                "thumbnail": thumb?.absoluteString ?? "", "description": desc, "source": src
            ], "link")
        case .contactCard(let c):
            return ([
                "type": "contactCard", "name": c.name, "uid": c.uid,
                "avatar": c.avatar?.absoluteString ?? "", "phone": c.phone,
                "qr": c.qr?.absoluteString ?? "", "oaLink": c.oaLink, "isOA": c.isOfficialAccount
            ], "contactCard")
        case .location(let info):
            return ([
                "type": "location", "title": info.title, "address": info.address,
                "hasCoordinates": info.coordinate != nil,
                "latitude": info.coordinate?.latitude ?? 0,
                "longitude": info.coordinate?.longitude ?? 0,
                "thumbnail": info.thumbnail?.absoluteString ?? ""
            ], "location")
        case .call(let video, let missed, let duration, let title, let detail):
            return (["type": "call", "video": video, "missed": missed, "duration": duration, "title": title, "detail": detail], "call")
        case .ecard(let card):
            return ([
                "type": "ecard", "style": card.style.rawValue,
                "image": card.image?.absoluteString ?? "", "thumb": card.thumb?.absoluteString ?? "",
                "title": card.title, "description": card.description,
                "actions": card.actions, "avatars": card.avatars.map(\.absoluteString),
                "reminderTitle": card.reminderTitle,
                "reminderStart": card.reminderStart.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0,
                "reminderRepeat": card.reminderRepeat
            ], "ecard")
        case .oaMessage(let parts):
            let rows: [[String: Any]] = parts.map { p in
                ["header": p.isHeader, "title": p.title, "description": p.description,
                 "thumb": p.thumb?.absoluteString ?? "", "url": p.url?.absoluteString ?? "", "help": p.help]
            }
            return (["type": "oaMessage", "parts": rows], "oaMessage")
        case .poll(let poll):
            return ([
                "type": "poll", "question": poll.question, "header": poll.header,
                "anonymous": poll.anonymous, "pollId": poll.pollId, "conversationId": poll.conversationId
            ], "poll")
        case .stickerSet(let title, let thumb):
            return (["type": "stickerSet", "title": title, "thumb": thumb?.absoluteString ?? ""], "stickerSet")
        case .zinstant(let title, let text, let thumb):
            return (["type": "zinstant", "title": title, "text": text, "thumb": thumb?.absoluteString ?? ""], "zinstant")
        case .notice(let symbol, let text):
            return (["type": "notice", "symbol": symbol, "text": text], "notice")
        case .placeholder(let symbol, let text):
            return (["type": "placeholder", "symbol": symbol, "text": text], "placeholder")
        case .system:
            return (["type": "system"], "system")
        case .recalled:
            return (["type": "recalled"], "recalled")
        case .unsupported(let rawType):
            return (["type": "unsupported", "rawType": rawType], "unsupported")
        }
    }

    static func normalizeTimestampMs(_ value: Any?) -> Int64 {
        guard let raw = JSONLossless.int64(value), raw > 0 else {
            return Int64(Date().timeIntervalSince1970 * 1000)
        }
        if raw < 10_000_000_000 { return raw * 1000 }
        return raw
    }

    static func optionalTimestampMs(_ value: Any?) -> Int64 {
        guard let raw = JSONLossless.int64(value), raw > 0 else {
            return 0
        }
        if raw < 10_000_000_000 { return raw * 1000 }
        return raw
    }

    /// Returns `.reaction` events sorted ascending chronologically within each `(convId, targetMsg)` group
    /// so newest-first batch deliveries apply reactions before unreactions.
    static func sortReactionEventsChronologically(_ events: [ParsedWireEvent]) -> [ParsedWireEvent] {
        struct IndexedReaction {
            let index: Int
            let groupKey: String
            let tsMs: Int64
            let seqId: Int64
            let event: ParsedWireEvent
        }
        var grouped: [String: [IndexedReaction]] = [:]
        var groupOrder: [String] = []
        for (idx, ev) in events.enumerated() {
            guard case .reaction(let convId, let msgId, let cliMsgId, _, _, _, _, _, let tsMs, let seqId, _) = ev else {
                continue
            }
            let targetKey = !msgId.isEmpty ? msgId : cliMsgId
            let key = "\(convId)|\(targetKey)"
            if grouped[key] == nil {
                groupOrder.append(key)
            }
            grouped[key, default: []].append(IndexedReaction(index: idx, groupKey: key, tsMs: tsMs, seqId: seqId, event: ev))
        }
        var out: [ParsedWireEvent] = []
        for key in groupOrder {
            guard let items = grouped[key] else { continue }
            let sorted: [IndexedReaction]
            if items.allSatisfy({ $0.tsMs > 0 }) {
                sorted = items.sorted {
                    if $0.tsMs != $1.tsMs { return $0.tsMs < $1.tsMs }
                    if $0.seqId != $1.seqId { return $0.seqId < $1.seqId }
                    return $0.index < $1.index
                }
            } else if items.allSatisfy({ $0.seqId > 0 }) {
                sorted = items.sorted {
                    if $0.seqId != $1.seqId { return $0.seqId < $1.seqId }
                    return $0.index < $1.index
                }
            } else {
                sorted = items
            }
            out.append(contentsOf: sorted.map(\.event))
        }
        return out
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        for v in values {
            if let v, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return v }
        }
        return ""
    }

    // MARK: - Profiles & Batch Envelope Extraction

    static func extractProfilesMap(_ resp: [String: Any]) -> [String: [String: Any]] {
        let dataNode = resp["data"]
        var result: [String: [String: Any]] = [:]

        func normalizeUid(_ candidate: String) -> String {
            let trimmed = stripUserPrefix(candidate)
            return sanitizeProfileUid(trimmed) ?? trimmed
        }

        func ingestDictMap(_ map: [String: Any]) {
            for (k, v) in map {
                if let row = v as? [String: Any] {
                    let uid = normalizeUid(firstNonEmpty(JSONLossless.string(row["userId"] ?? row["uid"] ?? row["id"]), k))
                    if !uid.isEmpty { result[uid] = row }
                }
            }
        }
        func ingestArray(_ rows: [[String: Any]]) {
            for row in rows {
                let uid = normalizeUid(JSONLossless.string(row["userId"] ?? row["uid"] ?? row["id"]))
                if !uid.isEmpty { result[uid] = row }
            }
        }

        if let dataDict = dataNode as? [String: Any] {
            var matchedContainer = false
            for key in ["profiles", "unchanged_profiles", "changed_profiles", "list"] {
                if let profilesDict = dataDict[key] as? [String: Any] {
                    ingestDictMap(profilesDict)
                    matchedContainer = true
                } else if let profilesArr = dataDict[key] as? [[String: Any]] {
                    ingestArray(profilesArr)
                    matchedContainer = true
                }
            }
            if !matchedContainer {
                ingestDictMap(dataDict)
            }
        } else if let dataArr = dataNode as? [[String: Any]] {
            ingestArray(dataArr)
        }
        return result
    }

    static func extractBatchEvents(
        _ root: Any,
        myUid: String,
        selfConvId: String? = nil,
        defaultCmd: UInt16 = 0,
        fallbackConvId: String? = nil,
        isGroupHint: Bool? = nil,
        nameLookup: ((String) -> (name: String, avatar: String)?)? = nil,
        useRustCore: Bool = RustCore.isEnabled
    ) -> [ParsedWireEvent] {
        if useRustCore,
           let rust = rustExtractBatchEvents(
               root, myUid: myUid, selfConvId: selfConvId, defaultCmd: defaultCmd,
               fallbackConvId: fallbackConvId, isGroupHint: isGroupHint, nameLookup: nameLookup
           ) {
            return rust
        }
        var events: [ParsedWireEvent] = []

        func unwrapValue(_ v: Any) -> Any {
            if let s = v as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if (t.hasPrefix("{") || t.hasPrefix("[")),
                   let data = t.data(using: .utf8),
                   let parsed = JSONLossless.parseAny(data) {
                    return parsed
                }
            }
            return v
        }

        func ingestReactions(from list: [[String: Any]], isGroup: Bool, fallbackHint: String?) {
            for r in list {
                let cRaw = unwrapValue(r["content"] as Any)
                let cDict = cRaw as? [String: Any]
                let sender = stripUserPrefix(JSONLossless.string(
                    r["uidFrom"] ?? r["fromUid"] ?? r["senderId"] ?? cDict?["uidFrom"] ?? cDict?["fromUid"]
                ))
                let toRaw = JSONLossless.string(r["idTo"] ?? r["toId"] ?? r["grid"] ?? r["groupId"] ?? fallbackHint)
                let cleanTo = stripUserPrefix(toRaw)
                let convId: String = {
                    if isGroup {
                        let g = groupConvId(toRaw)
                        return g.isEmpty ? (fallbackHint ?? "") : g
                    }
                    if sender == myUid || sender == "0" || sender.isEmpty {
                        if toRaw == "0" || toRaw.isEmpty || (selfConvId != nil && (cleanTo == selfConvId || cleanTo == myUid)) {
                            return firstNonEmpty(selfConvId, fallbackHint, (toRaw == "0" || toRaw.isEmpty) ? nil : cleanTo)
                        }
                        return cleanTo
                    }
                    return sender
                }()
                guard !convId.isEmpty else { continue }
                let msgId = JSONLossless.string(cDict?["gMsgID"] ?? cDict?["msgId"] ?? cDict?["globalMsgId"])
                let cliMsgId = JSONLossless.string(cDict?["cMsgID"] ?? cDict?["cliMsgId"] ?? cDict?["clientId"])
                let rIcon = JSONLossless.string(cDict?["rIcon"] ?? r["rIcon"])
                let rType = JSONLossless.string(cDict?["rType"] ?? r["rType"])
                guard !rType.isEmpty || !rIcon.isEmpty else { continue }

                let baseEventId = firstNonEmpty(
                    JSONLossless.string(r["actionId"]),
                    JSONLossless.string(r["msgId"]),
                    JSONLossless.string(r["cliMsgId"])
                )
                let reactClientId = JSONLossless.string(r["cliMsgId"] ?? r["clientId"])
                let tsMs = optionalTimestampMs(r["ts"] ?? r["time"] ?? r["sendTime"] ?? cDict?["ts"])
                let seqId = JSONLossless.int64(r["actionId"] ?? r["msgId"] ?? r["cliMsgId"]) ?? 0
                let senderName = JSONLossless.string(r["dName"] ?? r["senderName"] ?? cDict?["dName"])

                let rMsgRaw = cDict?["rMsg"].map { unwrapValue($0) }
                let rMsgs: [[String: Any]] = (rMsgRaw as? [[String: Any]])
                    ?? (rMsgRaw as? [Any])?.compactMap { $0 as? [String: Any] }
                    ?? ((rMsgRaw as? [String: Any]).map { [$0] } ?? [])

                if !rMsgs.isEmpty {
                    for rm in rMsgs {
                        let gid = JSONLossless.string(rm["gMsgID"] ?? rm["msgId"] ?? rm["globalMsgId"] ?? msgId)
                        let cid = JSONLossless.string(rm["cMsgID"] ?? rm["cliMsgId"] ?? rm["clientId"] ?? cliMsgId)
                        guard !gid.isEmpty || !cid.isEmpty else { continue }
                        events.append(.reaction(
                            convId: convId,
                            msgId: gid,
                            cliMsgId: cid,
                            senderId: sender,
                            rType: rType,
                            rIcon: rIcon,
                            eventId: baseEventId,
                            reactClientId: reactClientId,
                            tsMs: tsMs,
                            seqId: seqId,
                            senderName: senderName
                        ))
                    }
                } else if !msgId.isEmpty || !cliMsgId.isEmpty {
                    events.append(.reaction(
                        convId: convId,
                        msgId: msgId,
                        cliMsgId: cliMsgId,
                        senderId: sender,
                        rType: rType,
                        rIcon: rIcon,
                        eventId: baseEventId,
                        reactClientId: reactClientId,
                        tsMs: tsMs,
                        seqId: seqId,
                        senderName: senderName
                    ))
                }
            }
        }

        func walk(_ node: Any, hintConv: String?, hintGroup: Bool?, depth: Int) {
            guard depth < 8 else { return }
            let val = unwrapValue(node)

            if let arr = val as? [Any] {
                for el in arr {
                    walk(el, hintConv: hintConv, hintGroup: hintGroup, depth: depth + 1)
                }
                return
            }

            guard let dict = val as? [String: Any] else { return }

            if let dataVal = dict["data"] {
                let unwrappedData = unwrapValue(dataVal)
                if unwrappedData is [String: Any] || unwrappedData is [Any] {
                    walk(unwrappedData, hintConv: hintConv, hintGroup: hintGroup, depth: depth + 1)
                }
            }

            // Live reactions arrays (`reacts`, `reactGroups`)
            if let reacts = dict["reacts"] as? [[String: Any]] {
                ingestReactions(from: reacts, isGroup: false, fallbackHint: hintConv)
            }
            if let reactGroups = dict["reactGroups"] as? [[String: Any]] {
                ingestReactions(from: reactGroups, isGroup: true, fallbackHint: hintConv)
            }

            // Derive thread hint if this dict is a thread wrapper
            let rawThreadId = JSONLossless.string(dict["threadId"] ?? dict["groupId"] ?? dict["grid"] ?? dict["peerId"] ?? dict["userId"] ?? dict["uid"])
            let validThreadId = (!rawThreadId.isEmpty && rawThreadId != "0" && cleanGroupId(rawThreadId) != "0") ? rawThreadId : ""
            let rawGroupField = JSONLossless.string(dict["groupId"] ?? dict["grid"])
            let hasValidGroupField = !rawGroupField.isEmpty && cleanGroupId(rawGroupField) != "0"
            let wrapperIsGroup: Bool? = {
                if let t = JSONLossless.int64(dict["type"] ?? dict["convType"]) {
                    if t == 1 { return true }
                    if t == 0 { return false }
                }
                if let b = JSONLossless.bool(dict["isGroup"]) { return b }
                if hasValidGroupField || isGroupId(validThreadId) { return true }
                return hintGroup
            }()
            let nextConvHint: String? = {
                if !validThreadId.isEmpty {
                    if wrapperIsGroup == true || validThreadId.hasPrefix("g") || validThreadId.hasPrefix("group_") {
                        let g = groupConvId(validThreadId)
                        if !g.isEmpty { return g }
                    } else {
                        let u = stripUserPrefix(validThreadId)
                        if !u.isEmpty && u != "0" { return u }
                    }
                }
                return hintConv
            }()

            // Check if this dict itself looks like a single wire message
            let hasMessageFields = dict["msgId"] != nil
                || dict["globalMsgId"] != nil
                || dict["cliMsgId"] != nil
                || dict["msgType"] != nil
                || (dict["content"] != nil && (dict["uidFrom"] != nil || dict["idTo"] != nil || dict["senderId"] != nil))
            if hasMessageFields {
                let ev = parseWireMessage(
                    dict,
                    myUid: myUid,
                    cmd: defaultCmd,
                    fallbackConvId: nextConvHint ?? fallbackConvId,
                    isGroupHint: wrapperIsGroup ?? hintGroup,
                    selfConvId: selfConvId,
                    nameLookup: nameLookup
                )
                if case .ignore = ev {} else {
                    events.append(ev)
                }
            }

            // Check array containers
            var handledArrayContainer = false
            for key in ["groupMsgs", "pageMsgs", "conversations", "threads", "allmsgs", "messages", "items", "list"] {
                if let sub = dict[key] {
                    handledArrayContainer = true
                    let keyIsGroup: Bool?
                    if key == "groupMsgs" {
                        keyIsGroup = (nextConvHint != nil && nextConvHint == selfConvId) ? false : true
                    } else {
                        keyIsGroup = hintGroup ?? wrapperIsGroup
                    }
                    walk(sub, hintConv: nextConvHint, hintGroup: keyIsGroup, depth: depth + 1)
                }
            }
            if let msgsVal = dict["msgs"] {
                let unwrappedMsgs = unwrapValue(msgsVal)
                if let arr = unwrappedMsgs as? [Any] {
                    handledArrayContainer = true
                    let msgsIsGroup: Bool? = wrapperIsGroup ?? (dict["groupMsgs"] != nil ? false : nil)
                    walk(arr, hintConv: nextConvHint, hintGroup: msgsIsGroup, depth: depth + 1)
                } else if let map = unwrappedMsgs as? [String: Any] {
                    handledArrayContainer = true
                    for (k, listVal) in map {
                        let kIsGrp = k.hasPrefix("g") || k.hasPrefix("group_") || isGroupId(k)
                        let kConv = kIsGrp ? groupConvId(k) : stripUserPrefix(k)
                        walk(listVal, hintConv: kConv, hintGroup: kIsGrp, depth: depth + 1)
                    }
                }
            }

            // Direct nested lastMsg / message
            for key in ["lastMsg", "message"] {
                if let sub = dict[key] as? [String: Any] {
                    walk(sub, hintConv: nextConvHint, hintGroup: wrapperIsGroup, depth: depth + 1)
                }
            }
            _ = handledArrayContainer
        }

        walk(root, hintConv: fallbackConvId, hintGroup: isGroupHint, depth: 0)
        return events
    }
}
