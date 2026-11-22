import AppKit
import Foundation

extension ZaloEngine {
    // MARK: - Open / Close / History

    func openConversation(_ id: String) {
        guard !id.isEmpty else { return }
        let changed = openConversationId != id
        openConversationId = id
        if changed { dropMessagePrompts() }
        typing[id] = nil
        if messages[id] == nil {
            messages[id] = []
        }
        // Synchronous WAL snapshot read (< 0.5ms) so synced local history appears on the very first frame.
        if let syncCached = sqliteStore?.readMessagesNow(convId: id, limit: 50) {
            let decoded = syncCached.compactMap { ZaloWireParser.decodeStoredMessage($0) }
            for msg in decoded { mergeMessageIntoMemory(msg) }
            if decoded.count >= 45 {
                hasMoreHistory[id] = true
            }
        }

        let isGrp = ZaloWireParser.isGroupId(id)
        updateCallGateForConversation(id)

        Task { [weak self] in
            guard let self else { return }
            // 1. Fallback async read for in-memory test DBs without a separate WAL handle.
            if (self.messages[id]?.isEmpty ?? true),
               let cached = try? await self.sqliteStore?.messages(convId: id, limit: 50) {
                let decoded = cached.compactMap { ZaloWireParser.decodeStoredMessage($0) }
                for msg in decoded { self.mergeMessageIntoMemory(msg) }
                if decoded.count >= 45 {
                    self.hasMoreHistory[id] = true
                }
            }

            // 2. Refresh recent history (and board pins) from server if authenticated.
            let fetched = await self.fetchAndMergeHistory(convId: id, beforeMsgId: nil, isOld: false, count: 50)
            await self.resolveMissingSenderProfiles(in: id)
            if (fetched > 0 || self.conversations.first(where: { $0.id == id })?.preview == nil),
               let latest = self.messages[id]?.last {
                self.updateConversationOnMessage(latest, incrementUnread: false)
            }
            if isGrp || self.contacts.friends.contains(where: { $0.id == id }) {
                await self.refreshBoardPins(for: id)
            }

            // 3. Mark read locally & remotely.
            self.markRead(id)
        }
    }

    internal func resolveMissingSenderProfiles(in convId: String) async {
        guard let list = messages[convId], !list.isEmpty else { return }
        let myUid = profile?.userId ?? ""
        var unknownUids: [String] = []
        var seen: Set<String> = []
        for msg in list where !msg.isMine && !msg.senderId.isEmpty && msg.senderId != "0" && msg.senderId != myUid {
            let clean = ZaloWireParser.stripUserPrefix(msg.senderId)
            guard !clean.isEmpty, seen.insert(clean).inserted else { continue }
            let needsName = msg.senderName.isEmpty || msg.senderName == clean || msg.senderName == "Người dùng Zalo"
            let needsAvatar = msg.senderAvatar == nil && (cachedProfiles[clean]?.avatar.isEmpty ?? true)
            if needsName || needsAvatar {
                unknownUids.append(clean)
            }
        }
        guard !unknownUids.isEmpty else { return }

        var cacheUpdated = false
        for offset in stride(from: 0, to: unknownUids.count, by: 50) {
            let chunk = Array(unknownUids[offset..<min(offset + 50, unknownUids.count)])
            guard let box = try? await sessionClient.fetchProfiles(uids: chunk) else { continue }
            let profilesMap = ZaloWireParser.extractProfilesMap(box.dict)
            for (uid, row) in profilesMap {
                let clean = ZaloWireParser.stripUserPrefix(uid)
                let fetchedName = JSONLossless.string(row["displayName"] ?? row["dName"] ?? row["zaloName"] ?? row["name"])
                let avt = JSONLossless.string(row["avatar"] ?? row["avt"])
                if !clean.isEmpty, (!fetchedName.isEmpty || !avt.isEmpty) {
                    cachedProfiles[clean] = ZaloWebKitMigrator.CachedProfile(name: fetchedName, avatar: avt)
                    cacheUpdated = true
                }
            }
        }
        guard cacheUpdated else { return }
        if let data = try? JSONEncoder().encode(cachedProfiles) {
            try? await sqliteStore?.setPreferenceData(key: "cachedProfiles", data: data)
        }

        guard var updatedList = messages[convId] else { return }
        var toPersist: [StoredMessage] = []
        var modified = false
        for i in updatedList.indices where !updatedList[i].isMine {
            let clean = ZaloWireParser.stripUserPrefix(updatedList[i].senderId)
            guard let info = lookupPersonInfo(clean) else { continue }
            var rowChanged = false
            if !info.name.isEmpty, info.name != clean, updatedList[i].senderName != info.name {
                updatedList[i].senderName = info.name
                rowChanged = true
            }
            if updatedList[i].senderAvatar == nil, !info.avatar.isEmpty, let url = URL(string: info.avatar) {
                updatedList[i].senderAvatar = url
                rowChanged = true
            }
            if rowChanged {
                modified = true
                if let stored = ZaloWireParser.encodeChatMessage(updatedList[i]) {
                    toPersist.append(stored)
                }
            }
        }
        if modified {
            messages[convId] = updatedList
            if !toPersist.isEmpty {
                try? await sqliteStore?.saveMessages(toPersist)
            }
        }
    }

    func closeConversation() {
        openConversationId = nil
        dropMessagePrompts()
    }

    func loadOlderMessages(_ id: String) {
        guard !id.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            let existing = self.messages[id] ?? []
            let oldest = existing.first
            let beforeTsMs = oldest.map { Int64(($0.date.timeIntervalSince1970 * 1000).rounded()) }

            var addedCount = 0
            if let beforeTsMs {
                let cachedOlder: [StoredMessage]?
                if let syncOlder = self.sqliteStore?.readMessagesNow(convId: id, beforeTsMs: beforeTsMs, limit: 50) {
                    cachedOlder = syncOlder
                } else {
                    cachedOlder = try? await self.sqliteStore?.messages(convId: id, beforeTsMs: beforeTsMs, limit: 50)
                }
                if let cachedOlder, !cachedOlder.isEmpty {
                    let decoded = cachedOlder.compactMap { ZaloWireParser.decodeStoredMessage($0) }
                    for msg in decoded {
                        if !(self.messages[id]?.contains(where: { $0.id == msg.id }) ?? false) {
                            addedCount += 1
                        }
                        self.mergeMessageIntoMemory(msg)
                    }
                    if cachedOlder.count < 45 && !ZaloWireParser.isGroupId(id) && id != self.selfConversationId {
                        self.hasMoreHistory[id] = false
                    }
                }
            }

            if addedCount == 0 {
                let cursor: String? = oldest.flatMap { msg in
                    Int64(msg.id).map(String.init)
                }
                let fetched = await self.fetchAndMergeHistory(convId: id, beforeMsgId: cursor, isOld: nil, count: 50)
                if fetched == 0 {
                    self.hasMoreHistory[id] = false
                }
            }
            await self.resolveMissingSenderProfiles(in: id)
            self.historyTicks[id, default: 0] += 1
        }
    }

    @discardableResult
    internal func fetchAndMergeHistory(convId: String, beforeMsgId: String?, isOld: Bool? = nil, count: Int = 50) async -> Int {
        guard let box = try? await sessionClient.fetchHistory(convId: convId, lastMsgId: beforeMsgId, count: count, isOld: isOld) else {
            if beforeMsgId == nil {
                if messages[convId] == nil { messages[convId] = [] }
                if messages[convId]?.isEmpty ?? true { hasMoreHistory[convId] = false }
            }
            return 0
        }

        let myUid = profile?.userId ?? ""
        let isGrp = ZaloWireParser.isGroupId(convId)
        let isSelf = (convId == selfConversationId)
        let events = ZaloWireParser.extractBatchEvents(
            box.dict,
            myUid: myUid,
            selfConvId: selfConversationId,
            fallbackConvId: (isGrp || isSelf) ? convId : nil,
            isGroupHint: isGrp ? true : (isSelf ? false : nil),
            nameLookup: { [weak self] uid in self?.lookupPersonInfo(uid) }
        )

        var storedBatch: [StoredMessage] = []
        var newVisibleCount = 0
        var totalParsedMessages = 0

        for ev in events {
            switch ev {
            case .message(let msg, let stored):
                if msg.conversationId == convId {
                    totalParsedMessages += 1
                    if !(messages[msg.conversationId]?.contains(where: { $0.id == msg.id }) ?? false) {
                        newVisibleCount += 1
                    }
                }
                storedBatch.append(stored)
                mergeMessageIntoMemory(msg, replacingClientId: stored.clientId)
            case .reaction(let cId, let mid, let cid, let senderId, let rType, let rIcon):
                await applyRemoteReaction(convId: cId, msgId: mid, cliMsgId: cid, senderId: senderId, rType: rType, rIcon: rIcon)
            case .undo(let cId, let mid, let cid):
                await applyRemoteRecall(convId: cId, msgId: mid, cliMsgId: cid)
            case .delete(let cId, let mid, let cid):
                await applyRemoteDelete(convId: cId, msgId: mid, cliMsgId: cid)
            case .typing, .ignore:
                break
            }
        }
        if messages[convId] == nil {
            messages[convId] = []
        }
        if !storedBatch.isEmpty {
            try? await sqliteStore?.saveMessages(storedBatch)
        }
        let isSelfCloud = convId == selfConversationId
        if isGrp || isSelfCloud {
            if totalParsedMessages >= max(10, count / 2) {
                hasMoreHistory[convId] = true
            } else if (messages[convId]?.count ?? 0) < 45 {
                hasMoreHistory[convId] = false
            }
        } else if (messages[convId]?.count ?? 0) < 45 {
            hasMoreHistory[convId] = false
        }
        return newVisibleCount
    }

    // MARK: - Send Text / Mentions

    func sendText(_ text: String, to id: String, quoting quoteId: String? = nil, mentions: [Mention] = []) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !id.isEmpty else { return false }

        let quote = quoteId.flatMap { qid in messages[id]?.first(where: { $0.id == qid }) }
        let cliInt = await sessionClient.nextClientId()
        let cliId = "\(cliInt)"
        let myUid = profile?.userId ?? ""
        let myName = profile?.displayName ?? "Bạn"
        let quoteBlock = quote.map { ChatMessage.Quote(senderName: $0.isMine ? "Bạn" : $0.senderName, text: $0.text.isEmpty ? "[Tin nhắn]" : $0.text) }
        var isE2EE = false
        if !ZaloWireParser.isGroupId(id) {
            isE2EE = await e2eeManager.isE2EEConversation(id)
        }

        var optimistic = ChatMessage(
            id: cliId,
            conversationId: id,
            senderId: myUid,
            senderName: myName,
            senderAvatar: profile?.avatar,
            isMine: true,
            kind: .text,
            text: text,
            date: Date(),
            status: .sending,
            quote: quoteBlock,
            reactions: [],
            isE2EE: isE2EE,
            mentions: mentions,
            cardButtons: [],
            suggestsStickers: false,
            menu: MessageMenu(json: ["forward": "ok", "recall": true, "delete": "forMe", "pin": ZaloWireParser.isGroupId(id), "star": "star"])
        )
        mergeMessageIntoMemory(optimistic)

        func removeOptimistic() {
            if var list = messages[id] {
                list.removeAll { $0.id == cliId }
                messages[id] = list
            }
        }

        do {
            let quoteTsMs = quote.map { Int64(($0.date.timeIntervalSince1970 * 1000).rounded()) }
            let res: SendMessageResult
            if isE2EE {
                guard !myUid.isEmpty else {
                    EngineLog.shared.write("sendText e2ee failed: missing local uid")
                    removeOptimistic()
                    return false
                }
                let ready = await e2eeManager.ensureSessions(
                    forPeer: id,
                    myUid: myUid,
                    webSocket: webSocket,
                    store: sqliteStore
                )
                guard ready else {
                    EngineLog.shared.write("sendText e2ee failed: no open Signal session for peer=\(id)")
                    removeOptimistic()
                    return false
                }

                let qMsgInt = quote.flatMap { Int64($0.id.trimmingCharacters(in: .whitespacesAndNewlines)) }
                let hasValidQuote = (quote != nil && qMsgInt != nil && qMsgInt != 0)
                let quotePlain = hasValidQuote ? (quote!.text.isEmpty ? "[Tin nhắn]" : quote!.text) : nil
                let encryptedDevices = await e2eeManager.encryptTextMessage(
                    peerUid: id,
                    myUid: myUid,
                    text: text,
                    quoteText: quotePlain,
                    store: sqliteStore
                )
                guard !encryptedDevices.isEmpty else {
                    EngineLog.shared.write("sendText e2ee failed: encryption produced no peer payloads for peer=\(id)")
                    removeOptimistic()
                    return false
                }

                let senderIid = await e2eeManager.localRegistrationId()
                let imei = await sessionClient.imei
                let listParams: [[String: Any]] = encryptedDevices.compactMap { dev in
                    guard let msgCipher = dev.ciphers.first else { return nil }
                    var extra: [String: Any] = ["message": msgCipher]
                    if hasValidQuote, let qMsgInt, let quote {
                        let rawOwner = quote.senderId.isEmpty ? myUid : quote.senderId
                        extra["qmsgOwner"] = ZaloWireParser.stripUserPrefix(rawOwner)
                        extra["qmsgId"] = qMsgInt
                        extra["qmsgCliId"] = qMsgInt
                        extra["qmsgType"] = 1
                        extra["qmsg"] = dev.ciphers.count > 1 ? dev.ciphers[1] : ""
                        extra["qmsgTs"] = quoteTsMs ?? Int64(Date().timeIntervalSince1970 * 1000)
                        extra["zsource"] = 101
                    }
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
                    EngineLog.shared.write("sendText e2ee failed: empty listParams for peer=\(id)")
                    removeOptimistic()
                    return false
                }
                res = try await sessionClient.sendE2EEMessageAPI(
                    endpoint: hasValidQuote ? "quote" : "sms",
                    threadId: id,
                    isGroup: false,
                    clientId: cliInt,
                    listParams: ZaloJSONArrayBox(listParams)
                )
            } else {
                res = try await sessionClient.sendTextAPI(
                    convId: id,
                    text: text,
                    cliMsgId: cliId,
                    quoteMsgId: quote?.id,
                    quoteCliMsgId: quote?.id,
                    quoteOwnerId: quote?.senderId,
                    quoteText: quote?.text,
                    quoteTsMs: quoteTsMs,
                    mentions: mentions
                )
            }
            // Replace temporary client id with server msgId while avoiding duplicates.
            if var list = messages[id] {
                list.removeAll { $0.id == cliId || $0.id == res.msgId }
                optimistic.id = res.msgId
                optimistic.status = .sent
                list.append(optimistic)
                list.sort { a, b in a.date == b.date ? a.id < b.id : a.date < b.date }
                messages[id] = list
            }
            if let stored = ZaloWireParser.encodeChatMessage(optimistic, clientId: cliId) {
                try? await sqliteStore?.saveMessages([stored])
            }
            updateConversationOnMessage(optimistic, incrementUnread: false)
            return true
        } catch {
            EngineLog.shared.write("sendText failed: \(error.localizedDescription)")
            removeOptimistic()
            return false
        }
    }

    func mentionCandidates(in id: String, query: String, excluding: [String] = []) async -> [MentionCandidate] {
        guard ZaloWireParser.isGroupId(id) else { return [] }
        let cleanGroup = ZaloWireParser.cleanGroupId(id)
        let excludedSet = Set(excluding)

        if groupMemberCache[id] == nil {
            var candidates: [MentionCandidate] = [
                MentionCandidate(id: "-1", name: "All", avatar: nil, isAll: true)
            ]
            if let groupInfo = cachedGroupDetails[cleanGroup] {
                var memberIds: [String] = []
                if let verList = groupInfo["memVerList"] as? [String] {
                    memberIds.append(contentsOf: verList.compactMap { $0.split(separator: "_").first.map(String.init) })
                }
                if memberIds.isEmpty, let mems = groupInfo["memIds"] as? [Any] {
                    memberIds.append(contentsOf: mems.map(JSONLossless.string))
                }
                if memberIds.isEmpty, let cur = groupInfo["currentMems"] as? [[String: Any]] {
                    memberIds.append(contentsOf: cur.map { JSONLossless.string($0["id"] ?? $0["uid"]) })
                }
                let myUid = profile?.userId ?? ""
                let cleanIds = Array(Set(memberIds.map(ZaloWireParser.stripUserPrefix))).filter { !$0.isEmpty && $0 != myUid }
                if let profBox = try? await sessionClient.fetchProfiles(uids: Array(cleanIds.prefix(50))) {
                    let profilesMap = ZaloWireParser.extractProfilesMap(profBox.dict)
                    for uid in cleanIds {
                        guard let row = profilesMap[uid] else { continue }
                        let name = JSONLossless.string(row["dName"] ?? row["displayName"] ?? row["zaloName"] ?? row["name"])
                        let avt = JSONLossless.string(row["avatar"] ?? row["avt"])
                        if !name.isEmpty {
                            candidates.append(MentionCandidate(id: uid, name: name, avatar: avt.isEmpty ? nil : URL(string: avt), isAll: false))
                        }
                    }
                }
            }
            groupMemberCache[id] = candidates
        }

        let needle = Self.contactFold(query).trimmingCharacters(in: .whitespacesAndNewlines)
        return (groupMemberCache[id] ?? []).filter { candidate in
            guard !excludedSet.contains(candidate.id) else { return false }
            if needle.isEmpty { return true }
            return Self.contactFold(candidate.name).contains(needle)
        }
    }

    // MARK: - Reactions & Read Receipts

    func reactors(for messageId: String, in conversationId: String) async -> ReactionDetail? {
        guard let msg = messages[conversationId]?.first(where: { $0.id == messageId }), !msg.reactions.isEmpty else {
            return nil
        }
        let tabsJSON: [[String: Any]] = msg.reactions
            .sorted { $0.count > $1.count }
            .map { r in
                ["type": r.icon.type, "key": r.icon.key, "emoji": r.icon.emoji, "image": r.icon.image, "total": r.count]
            }

        var usersJSON: [[String: Any]] = []
        let myUid = profile?.userId ?? "me"
        if msg.reactions.contains(where: \.includesMe) {
            let myIcons: [[String: Any]] = msg.reactions.filter(\.includesMe).map { r in
                ["type": r.icon.type, "key": r.icon.key, "emoji": r.icon.emoji, "image": r.icon.image, "count": 1]
            }
            usersJSON.append([
                "uid": myUid,
                "name": "Bạn",
                "avatar": profile?.avatar?.absoluteString ?? "",
                "isMe": true,
                "total": myIcons.count,
                "icons": myIcons
            ])
        }
        if let first = msg.reactions.first, !first.includesMe {
            for (idx, name) in first.names.enumerated() where name != "Bạn" {
                usersJSON.append([
                    "uid": "u_\(idx)",
                    "name": name,
                    "avatar": "",
                    "isMe": false,
                    "total": 1,
                    "icons": [["type": first.icon.type, "key": first.icon.key, "emoji": first.icon.emoji, "image": first.icon.image, "count": 1]]
                ])
            }
        }
        return ReactionDetail(json: ["tabs": tabsJSON, "users": usersJSON])
    }

    func reactionImage(_ path: String) -> NSImage? {
        nil
    }

    func markRead(_ id: String) {
        guard !id.isEmpty else { return }
        var extrasChanged = false
        if let idx = conversations.firstIndex(where: { $0.id == id }), conversations[idx].unread > 0 {
            conversations[idx].unread = 0
            extrasChanged = true
        }
        let hadUnreadMark = cachedUnreadMarks.remove(id) != nil
        if hadUnreadMark {
            rebuildConversationFlags()
            extrasChanged = true
            Task {
                try? await sqliteStore?.setPreferenceStrings(key: "unreadMarks", value: Array(cachedUnreadMarks))
                try? await sessionClient.setUnreadMarkAPI(convId: id, unread: false)
            }
        }
        if extrasChanged {
            rebuildConversationExtras()
        }
        Task {
            try? await sqliteStore?.setConversationUnread(id: id, unread: 0)
            if let last = messages[id]?.last, !last.isMine {
                await sessionClient.sendSeenAPI(convId: id, msgId: last.id, cliMsgId: last.id, senderId: last.senderId)
            }
        }
    }

    func react(_ emoji: String, to messageId: String, in conversationId: String) {
        let spec = ZaloWireParser.reactionSpec(forEmoji: emoji)
        let msg = messages[conversationId]?.first(where: { $0.id == messageId })
        let isSticker = { if case .sticker = msg?.kind { return true }; return false }()
        let alreadyMine = msg?.reactions.contains(where: { $0.includesMe && $0.icon.type == "\(spec.rType)" }) ?? false
        let effectiveType = alreadyMine ? -1 : spec.rType
        let effectiveIcon = alreadyMine ? "" : spec.rIcon
        let cliId = messageId

        Task {
            do {
                try await sessionClient.sendReactionAPI(
                    convId: conversationId,
                    msgId: messageId,
                    cliMsgId: cliId,
                    rIcon: effectiveIcon,
                    rType: effectiveType,
                    isSticker: isSticker
                )
                await applyRemoteReaction(
                    convId: conversationId,
                    msgId: messageId,
                    cliMsgId: cliId,
                    senderId: profile?.userId ?? "0",
                    rType: "\(effectiveType)",
                    rIcon: effectiveIcon
                )
            } catch {
                EngineLog.shared.write("react failed: \(error.localizedDescription)")
            }
        }
    }

    func handleTyping(state: [String: Any]) {
        if let info = state["typing"] as? [String: Any],
           let convId = info["convId"] as? String,
           let name = info["name"] as? String {
            showTyping(convId: convId, name: name)
        }
    }
}
