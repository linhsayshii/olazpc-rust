import AppKit
import Foundation

extension ZaloEngine {
    // MARK: - Open / Close / History

    func openConversation(_ id: String) {
        guard !id.isEmpty else { return }
        let changed = openConversationId != id
        openConversationId = id
        if changed { dropMessagePrompts() }
        // Observable writes invalidate every reader even when the value is the same: write only real changes.
        if typing[id] != nil { typing[id] = nil }
        if messages[id] == nil {
            messages[id] = []
        }
        // Synchronous WAL snapshot read (< 0.5ms) so synced local history appears on the very first frame.
        if let syncCached = sqliteStore?.readDecodedMessagesNow(convId: id, limit: 50) {
            let decoded = syncCached.map(\.message)
            // One write for the whole page (a merge per row copied, sorted and published the list 50 times).
            mergeMessagesIntoMemory(decoded.map { (message: $0, clientId: nil) }, in: id)
            if decoded.count >= 45, hasMoreHistory[id] != true {
                hasMoreHistory[id] = true
            }
        }

        let isGrp = ZaloWireParser.isGroupId(id)
        updateCallGateForConversation(id)

        openConversationTask = Task { [weak self] in
            guard let self else { return }
            // 1. Fallback async read for in-memory test DBs without a separate WAL handle.
            if (self.messages[id]?.isEmpty ?? true),
               let cached = try? await self.sqliteStore?.decodedMessages(convId: id, limit: 50) {
                let decoded = cached.map(\.message)
                for msg in decoded { self.mergeMessageIntoMemory(msg) }
                if decoded.count >= 45 {
                    self.hasMoreHistory[id] = true
                }
            }

            // 2. Refresh recent history (and board pins) from server if authenticated. Skipped when this session already
            // knows the store holds the newest message (launch preload probe, or an earlier open of this chat).
            let fetched = self.isRecentHistoryUpToDate(id)
                ? 0
                : await self.fetchAndMergeHistory(convId: id, beforeMsgId: nil, isOld: false, count: 50)
            await self.resolveMissingSenderProfiles(in: id)
            if (fetched > 0 || self.conversations.first(where: { $0.id == id })?.preview == nil),
               let latest = self.messages[id]?.last {
                self.updateConversationOnMessage(latest, incrementUnread: false)
            }
            if isGrp || self.contacts.friends.contains(where: { $0.id == id }) {
                await self.refreshBoardPins(for: id)
            } else {
                EngineLog.shared.write("pins: list skipped (1-1 not in friends)")
            }

            // 3. Mark read locally & remotely.
            if self.traceU4Host("mark_read", args: ["conv_id": id]) {
                self.markRead(id)
            }
        }
    }

    internal func resolveMissingSenderProfiles(in convId: String) async {
        guard let list = messages[convId], !list.isEmpty else { return }
        let cleanMyUid = ZaloWireParser.stripUserPrefix(profile?.userId ?? "")
        let sanitizedMyUid = ZaloWireParser.sanitizeProfileUid(cleanMyUid) ?? cleanMyUid
        let sentinelKeys: Set<String> = ["", "0", "me", "__legacy__", "unknown", "-1"]

        var unknownUids: [String] = []
        var seen: Set<String> = []

        func considerUid(_ raw: String, existingName: String = "", hasAvatar: Bool = false) {
            let trimmed = ZaloWireParser.stripUserPrefix(raw)
            let clean = ZaloWireParser.sanitizeProfileUid(trimmed) ?? trimmed
            guard !sentinelKeys.contains(clean),
                  clean != cleanMyUid,
                  clean != sanitizedMyUid,
                  seen.insert(clean).inserted else { return }
            let person = lookupPersonInfo(clean)
            let bestName = (!existingName.isEmpty && existingName != clean && existingName != ReactionDetail.unknownName)
                ? existingName
                : (person?.name ?? "")
            let needsName = bestName.isEmpty || bestName == clean || bestName == ReactionDetail.unknownName
            let needsAvatar = !hasAvatar && (person?.avatar.isEmpty ?? true) && (cachedProfiles[clean]?.avatar.isEmpty ?? true)
            if needsName || needsAvatar {
                unknownUids.append(clean)
            }
        }

        for msg in list {
            if !msg.isMine && !msg.senderId.isEmpty && msg.senderId != "0" && msg.senderId != cleanMyUid {
                considerUid(msg.senderId, existingName: msg.senderName, hasAvatar: msg.senderAvatar != nil)
            }
            for react in msg.reactions {
                for rawUid in react.userCounts.keys {
                    considerUid(rawUid)
                }
            }
        }
        guard !unknownUids.isEmpty else {
            refreshReactionNames(in: convId)
            return
        }

        var cacheUpdated = false
        for offset in stride(from: 0, to: unknownUids.count, by: 50) {
            let chunk = Array(unknownUids[offset..<min(offset + 50, unknownUids.count)])
            guard let box = try? await sessionClient.fetchProfiles(uids: chunk) else { continue }
            let profilesMap = ZaloWireParser.extractProfilesMap(box.dict)
            for (uid, row) in profilesMap {
                let trimmed = ZaloWireParser.stripUserPrefix(uid)
                let clean = ZaloWireParser.sanitizeProfileUid(trimmed) ?? trimmed
                let fetchedName = ZaloWireParser.preferredName(row)
                let avt = JSONLossless.string(row["avatar"] ?? row["avt"])
                if !clean.isEmpty, (!fetchedName.isEmpty || !avt.isEmpty) {
                    cachedProfiles[clean] = ZaloWebKitMigrator.CachedProfile(name: fetchedName, avatar: avt)
                    cacheUpdated = true
                }
            }
        }
        guard cacheUpdated else {
            refreshReactionNames(in: convId)
            return
        }
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
            if !info.name.isEmpty, info.name != clean, info.name != ReactionDetail.unknownName, updatedList[i].senderName != info.name {
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
                try? await sqliteStore?.saveMessages(toPersist, preserveExistingReactions: true)
            }
        }
        refreshReactionNames(in: convId)
    }

    func closeConversation() {
        openConversationId = nil
        dropMessagePrompts()
    }

    func loadOlderMessages(_ id: String) {
        guard !id.isEmpty else { return }
        loadOlderTask = Task { [weak self] in
            guard let self else { return }
            let existing = self.messages[id] ?? []
            let oldest = existing.first
            let beforeTsMs = oldest.map { Int64(($0.date.timeIntervalSince1970 * 1000).rounded()) }

            var addedCount = 0
            if let beforeTsMs {
                let cachedOlder: [DecodedMessageRow]?
                if let syncOlder = self.sqliteStore?.readDecodedMessagesNow(convId: id, beforeTsMs: beforeTsMs, limit: 50) {
                    cachedOlder = syncOlder
                } else {
                    cachedOlder = try? await self.sqliteStore?.decodedMessages(convId: id, beforeTsMs: beforeTsMs, limit: 50)
                }
                if let cachedOlder, !cachedOlder.isEmpty {
                    let decoded = cachedOlder.map(\.message)
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
        guard let page = try? await sessionClient.fetchHistoryPage(convId: convId, lastMsgId: beforeMsgId, count: count, isOld: isOld) else {
            if beforeMsgId == nil {
                if messages[convId] == nil { messages[convId] = [] }
                if messages[convId]?.isEmpty ?? true { hasMoreHistory[convId] = false }
            }
            return 0
        }

        if beforeMsgId == nil { historyFreshness[convId] = .upToDate }
        let myUid = profile?.userId ?? ""
        let isGrp = ZaloWireParser.isGroupId(convId)
        let isSelf = (convId == selfConversationId)
        let events = await ZaloWireParser.historyEventsAsync(
            page,
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
            if case .message(let msg, let stored) = ev {
                if msg.conversationId == convId {
                    totalParsedMessages += 1
                    if !(messages[msg.conversationId]?.contains(where: { $0.id == msg.id }) ?? false) {
                        newVisibleCount += 1
                    }
                }
                storedBatch.append(stored)
                mergeMessageIntoMemory(msg, replacingClientId: stored.clientId)
            }
        }
        if messages[convId] == nil {
            messages[convId] = []
        }
        if !storedBatch.isEmpty {
            try? await sqliteStore?.saveMessages(storedBatch, preserveExistingReactions: true)
        }
        for ev in ZaloWireParser.sortReactionEventsChronologically(events) {
            if case .reaction(let cId, let mid, let cid, let senderId, let rType, let rIcon, let eventId, let reactClientId, _, _, let senderName) = ev {
                await applyRemoteReaction(
                    convId: cId,
                    msgId: mid,
                    cliMsgId: cid,
                    senderId: senderId,
                    rType: rType,
                    rIcon: rIcon,
                    eventId: eventId,
                    reactClientId: reactClientId,
                    senderName: senderName
                )
            }
        }
        for ev in events {
            switch ev {
            case .undo(let cId, let mid, let cid):
                await applyRemoteRecall(convId: cId, msgId: mid, cliMsgId: cid)
            case .delete(let cId, let mid, let cid):
                await applyRemoteDelete(convId: cId, msgId: mid, cliMsgId: cid)
            case .message, .reaction, .typing, .ignore:
                break
            }
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

    func sendText(_ text: String, to id: String, quoting quoteId: String? = nil, mentions: [Mention] = [],
                  styles: [TextStyle] = [], urgency: Int = 0) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !id.isEmpty else { return false }
        resetOutgoingTyping(in: id)

        let quote = quoteId.flatMap { qid in messages[id]?.first(where: { $0.id == qid }) }
        let cliInt = await sessionClient.nextClientId()
        let cliId = "\(cliInt)"
        let myUid = profile?.userId ?? ""
        let myName = profile?.displayName ?? "Bạn"
        let quoteBlock = quote.map {
            ChatMessage.Quote(senderName: $0.isMine ? "Bạn" : $0.senderName, text: $0.text.isEmpty ? "[Tin nhắn]" : $0.text,
                              msgId: $0.id, cliMsgId: $0.clientId)
        }
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
            date: Date(timeIntervalSince1970: Double(nowMs()) / 1000.0),
            status: .sending,
            quote: quoteBlock,
            reactions: [],
            isE2EE: isE2EE,
            mentions: mentions,
            cardButtons: [],
            suggestsStickers: false,
            menu: MessageMenu(json: [
                "forward": "ok",
                "recall": id != selfConversationId,
                "delete": id == selfConversationId ? "plain" : "forMe",
                "pin": ZaloWireParser.isGroupId(id) && id != selfConversationId,
                "star": "star"
            ]),
            clientId: cliId
        )
        // Rich text goes out on the plain path only (E2EE text is sent unstyled).
        if !isE2EE { optimistic.textStyles = styles }
        // "Tin nhắn tự xóa": the conversation's lifetime rides on the message.
        let ttl = isE2EE ? 0 : autoDeleteTTL(id)
        optimistic.ttlMs = ttl
        // "Quan trọng" / "Khẩn cấp" (plain path only, like the styles).
        let urgency = isE2EE ? 0 : urgency
        optimistic.urgency = urgency
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
                if let sendE2EETextHostHandler {
                    let quoteArgs: Any = quote.map { q -> [String: Any] in
                        [
                            "msg_id": q.id,
                            "cli_msg_id": q.clientId,
                            "sender_id": q.senderId,
                            "sender_name": q.senderName,
                            "text": q.text,
                            "ts_ms": quoteTsMs ?? Int64(0),
                        ]
                    } ?? NSNull()
                    let args: [String: Any] = [
                        "conv_id": id,
                        "text": text,
                        "client_id": cliId,
                        "quote": quoteArgs,
                    ]
                    _ = traceHost("send_e2ee_text", args: args)
                    res = try await sendE2EETextHostHandler(args)
                } else {
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
                // The peer decrypts the quoted message's owner as an encrypted global id; without one the whole message
                // fails on their side ("tạm thời chưa hiển thị"), so a quote whose owner has none goes out as a plain text.
                let quoteOwner = quote.map { ZaloWireParser.stripUserPrefix($0.senderId.isEmpty ? myUid : $0.senderId) } ?? ""
                var ownerGlobalId = ""
                if quote != nil, qMsgInt != nil, qMsgInt != 0, !quoteOwner.isEmpty {
                    if let cached = cachedFriendGlobalIds[quoteOwner] {
                        ownerGlobalId = cached
                    } else {
                        ownerGlobalId = await sessionClient.encryptGlobalIds([quoteOwner])[quoteOwner] ?? ""
                    }
                    if ownerGlobalId.isEmpty { EngineLog.shared.write("sendText e2ee: quote owner has no global id, sending without quote") }
                }
                let hasValidQuote = (quote != nil && qMsgInt != nil && qMsgInt != 0 && !ownerGlobalId.isEmpty)
                let quotePlain = hasValidQuote ? (quote!.text.isEmpty ? "[Tin nhắn]" : quote!.text) : nil
                let ownerName = quote.map { $0.isMine ? (profile?.displayName ?? $0.senderName) : $0.senderName } ?? ""
                let encryptedDevices = await e2eeManager.encryptTextMessage(
                    peerUid: id,
                    myUid: myUid,
                    text: text,
                    quoteText: quotePlain,
                    quoteExtras: hasValidQuote ? ["{}", "", ownerName, ownerGlobalId] : [],
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
                        guard let fields = Self.e2eeQuoteFields(
                            ciphers: dev.ciphers, msgId: qMsgInt, cliMsgId: Int64(quote.clientId) ?? qMsgInt,
                            ts: quoteTsMs ?? Int64(Date().timeIntervalSince1970 * 1000)) else { return nil }
                        extra.merge(fields) { _, new in new }
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
                }
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
                    mentions: mentions,
                    textProperties: TextStyle.textProperties(styles),
                    ttl: ttl,
                    urgency: urgency
                )
            }
            // Replace temporary client id with server msgId while avoiding duplicates.
            let finalCliId = res.cliMsgId.isEmpty ? cliId : res.cliMsgId
            // 1-1 E2EE replies carry no msgId (it falls back to the client id); the websocket echo may already have
            // brought the server copy, which then stands for this message.
            if res.msgId == cliId,
               let echoed = messages[id]?.first(where: { $0.clientId == finalCliId && $0.id != cliId }) {
                if var list = messages[id] {
                    list.removeAll { $0.id == cliId }
                    messages[id] = list
                }
                updateConversationOnMessage(echoed, incrementUnread: false)
                return true
            }
            if var list = messages[id] {
                list.removeAll { $0.id == cliId || $0.id == res.msgId }
                optimistic.id = res.msgId
                optimistic.clientId = finalCliId
                optimistic.status = .sent
                list.append(optimistic)
                list.sort { a, b in a.date == b.date ? a.id < b.id : a.date < b.date }
                messages[id] = list
            }
            if let stored = ZaloWireParser.encodeChatMessage(optimistic, clientId: finalCliId) {
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
                        let name = ZaloWireParser.preferredName(row)
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
        guard let msg = messages[conversationId]?.first(where: { $0.id == messageId || $0.clientId == messageId }),
              !msg.reactions.isEmpty else {
            return nil
        }
        let tabsJSON: [[String: Any]] = msg.reactions
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return (Int($0.icon.type) ?? 0) < (Int($1.icon.type) ?? 0)
            }
            .map { r in
                ["type": r.icon.type, "key": r.icon.key, "emoji": r.icon.emoji, "image": r.icon.image, "total": r.count]
            }

        let cleanMyUid = ZaloWireParser.sanitizeProfileUid(profile?.userId ?? "") ?? ZaloWireParser.stripUserPrefix(profile?.userId ?? "")
        let myKey = cleanMyUid.isEmpty ? "me" : cleanMyUid
        let isOneToOnePeer = !ZaloWireParser.isGroupId(conversationId) && conversationId != selfConversationId
        let sentinelKeys: Set<String> = ["", "__legacy__", "unknown", "-1"]

        struct UserAgg {
            var uid: String
            var isMe: Bool
            var fallbackName: String
            var iconsByType: [String: (icon: ReactionIcon, count: Int)] = [:]
            var total: Int = 0
            var firstType: Int = Int.max
        }
        var aggMap: [String: UserAgg] = [:]

        func addReactionEntry(uid: String, isMe: Bool, fallbackName: String, icon: ReactionIcon, count: Int) {
            guard count > 0 else { return }
            var entry = aggMap[uid] ?? UserAgg(uid: uid, isMe: isMe, fallbackName: fallbackName)
            if let existing = entry.iconsByType[icon.type] {
                entry.iconsByType[icon.type] = (icon: existing.icon, count: existing.count + count)
            } else {
                entry.iconsByType[icon.type] = (icon: icon, count: count)
            }
            entry.total += count
            let typeNum = Int(icon.type) ?? Int.max
            if typeNum < entry.firstType { entry.firstType = typeNum }
            aggMap[uid] = entry
        }

        for r in msg.reactions {
            if !r.userCounts.isEmpty {
                for (rawUid, cnt) in r.userCounts where cnt > 0 {
                    let trimmedUid = rawUid.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !sentinelKeys.contains(trimmedUid) else { continue }
                    let normalizedUid = ZaloWireParser.sanitizeProfileUid(trimmedUid) ?? trimmedUid
                    let isMe = (normalizedUid == myKey || trimmedUid == myKey || trimmedUid == "0" || trimmedUid == "me")
                    let canonicalUid = isMe ? myKey : normalizedUid
                    addReactionEntry(uid: canonicalUid, isMe: isMe, fallbackName: ReactionDetail.unknownName, icon: r.icon, count: cnt)
                }
            } else {
                if r.includesMe {
                    addReactionEntry(uid: myKey, isMe: true, fallbackName: "Bạn", icon: r.icon, count: 1)
                }
                let otherNames = r.names.filter {
                    let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    return !t.isEmpty && t != "Bạn" && t != ReactionDetail.unknownName
                }
                if !otherNames.isEmpty {
                    for (idx, name) in otherNames.enumerated() {
                        addReactionEntry(uid: "legacy_\(name)_\(idx)", isMe: false, fallbackName: name, icon: r.icon, count: 1)
                    }
                } else if !r.includesMe {
                    if isOneToOnePeer {
                        let peerUid = ZaloWireParser.sanitizeProfileUid(conversationId) ?? conversationId
                        addReactionEntry(uid: peerUid, isMe: false, fallbackName: ReactionDetail.unknownName, icon: r.icon, count: max(1, r.count))
                    } else {
                        let count = max(1, r.people)
                        for idx in 0..<count {
                            addReactionEntry(uid: "u_\(r.icon.type)_\(idx)", isMe: false, fallbackName: ReactionDetail.unknownName, icon: r.icon, count: 1)
                        }
                    }
                }
            }
        }

        let missingProfileUids = aggMap.values.compactMap { entry -> String? in
            guard !entry.isMe, !entry.uid.hasPrefix("legacy_"), !entry.uid.hasPrefix("u_") else { return nil }
            let info = lookupPersonInfo(entry.uid)
            let nameMissing = info == nil
                || info!.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || info!.name == ReactionDetail.unknownName
                || info!.name == entry.uid
            let avatarMissing = info?.avatar.isEmpty ?? true
            return (nameMissing || avatarMissing) ? entry.uid : nil
        }

        if !missingProfileUids.isEmpty,
           let profBox = try? await sessionClient.fetchProfiles(uids: Array(missingProfileUids.prefix(50))) {
            let profilesMap = ZaloWireParser.extractProfilesMap(profBox.dict)
            var cacheChanged = false
            for (uid, row) in profilesMap {
                let clean = ZaloWireParser.sanitizeProfileUid(uid) ?? ZaloWireParser.stripUserPrefix(uid)
                let fetchedName = ZaloWireParser.preferredName(row)
                let avt = JSONLossless.string(row["avatar"] ?? row["avt"])
                if !clean.isEmpty && (!fetchedName.isEmpty || !avt.isEmpty) {
                    cachedProfiles[clean] = ZaloWebKitMigrator.CachedProfile(name: fetchedName, avatar: avt)
                    cacheChanged = true
                }
            }
            if cacheChanged {
                if let data = try? JSONEncoder().encode(cachedProfiles) {
                    try? await sqliteStore?.setPreferenceData(key: "cachedProfiles", data: data)
                }
                refreshReactionNames(in: conversationId)
            }
        }

        let sortedUsers = aggMap.values.sorted { a, b in
            if a.total != b.total { return a.total > b.total }
            if a.isMe != b.isMe { return a.isMe }
            if a.firstType != b.firstType { return a.firstType < b.firstType }
            return a.uid < b.uid
        }

        let convIdentity = isOneToOnePeer ? lookupConversationIdentity(conversationId) : (name: "", avatar: nil, members: 0)
        let convSummary = isOneToOnePeer ? conversations.first(where: { $0.id == conversationId }) : nil
        let usersJSON: [[String: Any]] = sortedUsers.map { entry in
            let sortedIcons = entry.iconsByType.values.sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                return (Int(a.icon.type) ?? 0) < (Int(b.icon.type) ?? 0)
            }
            let iconsJSON: [[String: Any]] = sortedIcons.map { item in
                [
                    "type": item.icon.type,
                    "key": item.icon.key,
                    "emoji": item.icon.emoji,
                    "image": item.icon.image,
                    "count": item.count
                ]
            }
            let name: String
            let avatar: String
            if entry.isMe {
                name = "Bạn"
                avatar = profile?.avatar?.absoluteString ?? ""
            } else if entry.uid.hasPrefix("legacy_") || entry.uid.hasPrefix("u_") {
                name = entry.fallbackName
                avatar = ""
            } else {
                let info = lookupPersonInfo(entry.uid)
                var candidateName = info?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                var candidateAvatar = info?.avatar ?? ""

                if isOneToOnePeer {
                    if candidateName.isEmpty || candidateName == entry.uid || candidateName == ReactionDetail.unknownName {
                        let identName = convIdentity.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let sumName = convSummary?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let msgPeerName = !msg.isMine ? msg.senderName.trimmingCharacters(in: .whitespacesAndNewlines) : ""
                        for alt in [identName, sumName, msgPeerName] {
                            if !alt.isEmpty && alt != conversationId && alt != entry.uid && alt != ReactionDetail.unknownName {
                                candidateName = alt
                                break
                            }
                        }
                    }
                    if candidateAvatar.isEmpty {
                        candidateAvatar = convIdentity.avatar?.absoluteString
                            ?? convSummary?.avatar?.absoluteString
                            ?? (!msg.isMine ? (msg.senderAvatar?.absoluteString ?? "") : "")
                    }
                }

                name = (!candidateName.isEmpty && candidateName != ReactionDetail.unknownName) ? candidateName : entry.fallbackName
                avatar = candidateAvatar
            }
            return [
                "uid": entry.uid,
                "name": name,
                "avatar": avatar,
                "isMe": entry.isMe,
                "total": entry.total,
                "icons": iconsJSON
            ]
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
            let key = UUID()
            let t = Task { @MainActor [weak self] in
                defer { self?.markReadTasks.removeValue(forKey: key) }
                guard let self else { return }
                try? await self.sqliteStore?.setPreferenceStrings(key: "unreadMarks", value: Array(self.cachedUnreadMarks))
                try? await self.sessionClient.setUnreadMarkAPI(convId: id, unread: false)
            }
            markReadTasks[key] = t
        }
        if extrasChanged {
            rebuildConversationExtras()
        }
        let key = UUID()
        let t = Task { @MainActor [weak self] in
            defer { self?.markReadTasks.removeValue(forKey: key) }
            guard let self else { return }
            try? await self.sqliteStore?.setConversationUnread(id: id, unread: 0)
            if let last = self.messages[id]?.last, !last.isMine {
                await self.sessionClient.sendSeenAPI(convId: id, msgId: last.id, cliMsgId: last.id, senderId: last.senderId)
            }
        }
        markReadTasks[key] = t
    }

    func react(_ emoji: String, to messageId: String, in conversationId: String) {
        Task {
            await performReact(emoji, to: messageId, in: conversationId)
        }
    }

    /// Official "Gỡ": drops every reaction of mine on the message at once (wire: rType -1, rIcon "").
    func removeMyReactions(from messageId: String, in conversationId: String) {
        Task {
            await performReact("", to: messageId, in: conversationId, removeAll: true)
        }
    }

    internal func performReact(_ emoji: String, to messageId: String, in conversationId: String, removeAll: Bool = false) async {
        guard !conversationId.isEmpty, !messageId.isEmpty else { return }
        guard let initialMsg = messages[conversationId]?.first(where: { $0.id == messageId || $0.clientId == messageId }),
              initialMsg.kind != .recalled,
              initialMsg.status != .sending,
              initialMsg.status != .failed else {
            return
        }

        let busyKey = "\(conversationId)|\(initialMsg.id)"
        guard reactionBusyKeys.insert(busyKey).inserted else { return }
        defer { reactionBusyKeys.remove(busyKey) }

        let spec = ZaloWireParser.reactionSpec(forEmoji: emoji)
        if removeAll && !initialMsg.reactions.contains(where: \.includesMe) { return }
        let alreadyMine = removeAll || initialMsg.reactions.contains(where: { $0.includesMe && $0.icon.type == "\(spec.rType)" })
        let effectiveType = alreadyMine ? -1 : spec.rType
        let effectiveIcon = alreadyMine ? "" : spec.rIcon
        let msgType = ZaloWireParser.reactionClientMsgType(for: initialMsg.kind)

        let resolvedIds = await resolveServerAndClientIds(for: initialMsg)
        let effectiveMsgId = resolvedIds.msgId
        let resolvedCliId = resolvedIds.cliMsgId

        var reactClientIdInt = await sessionClient.nextClientId()
        var reactClientId = "\(reactClientIdInt)"
        let myUid = profile?.userId ?? ""

        var previousReactions = initialMsg.reactions
        if var list = messages[conversationId],
           let idx = list.firstIndex(where: {
               $0.id == initialMsg.id || $0.id == effectiveMsgId || (!resolvedCliId.isEmpty && $0.clientId == resolvedCliId)
           }) {
            var updated = list[idx]
            previousReactions = updated.reactions
            Self.mutateReactions(
                &updated.reactions,
                actorUid: myUid,
                myUid: myUid,
                isMe: true,
                rType: "\(effectiveType)",
                rIcon: effectiveIcon,
                allowDuplicateSameUser: true,
                nameLookup: { _ in "Bạn" }
            )
            list[idx] = updated
            messages[conversationId] = list
        }

        let pendingId = UUID()
        pendingLocalReactions.append(PendingLocalReaction(
            id: pendingId,
            convId: conversationId,
            msgId: effectiveMsgId,
            cliMsgId: resolvedCliId,
            rType: "\(effectiveType)",
            reactClientId: reactClientId,
            createdAt: Date()
        ))

        func rollbackOnError() {
            pendingLocalReactions.removeAll { $0.id == pendingId }
            if var list = messages[conversationId],
               let idx = list.firstIndex(where: {
                   $0.id == effectiveMsgId || $0.id == initialMsg.id || (!resolvedCliId.isEmpty && $0.clientId == resolvedCliId)
               }) {
                list[idx].reactions = previousReactions
                messages[conversationId] = list
            }
        }

        do {
            do {
                try await sessionClient.sendReactionAPI(
                    convId: conversationId,
                    msgId: effectiveMsgId,
                    cliMsgId: resolvedCliId,
                    rIcon: effectiveIcon,
                    rType: effectiveType,
                    msgType: msgType,
                    clientId: reactClientIdInt
                )
            } catch let err as ZaloSessionError where !err.isAuthError && msgType != 1 {
                reactClientIdInt = await sessionClient.nextClientId()
                reactClientId = "\(reactClientIdInt)"
                if let pIdx = pendingLocalReactions.firstIndex(where: { $0.id == pendingId }) {
                    pendingLocalReactions[pIdx].reactClientId = reactClientId
                }
                try await sessionClient.sendReactionAPI(
                    convId: conversationId,
                    msgId: effectiveMsgId,
                    cliMsgId: resolvedCliId,
                    rIcon: effectiveIcon,
                    rType: effectiveType,
                    msgType: 1,
                    clientId: reactClientIdInt
                )
            }

            let dedupConv = ZaloWireParser.isGroupId(conversationId)
                ? conversationId
                : (ZaloWireParser.sanitizeProfileUid(conversationId) ?? conversationId)
            var seenKeys = ["\(dedupConv)|\(effectiveMsgId)|cli:\(reactClientId)|\(effectiveType)"]
            if !resolvedCliId.isEmpty && resolvedCliId != effectiveMsgId {
                seenKeys.append("\(dedupConv)|\(resolvedCliId)|cli:\(reactClientId)|\(effectiveType)")
            }
            await recordSeenReactionKeys(seenKeys)

            if let current = messages[conversationId]?.first(where: {
                $0.id == effectiveMsgId || $0.id == initialMsg.id || (!resolvedCliId.isEmpty && $0.clientId == resolvedCliId)
            }), let stored = ZaloWireParser.encodeChatMessage(current) {
                try? await sqliteStore?.saveMessages([stored], preserveExistingReactions: false)
            }
        } catch let err as ZaloSessionError {
            rollbackOnError()
            let msgNote = err.message.isEmpty ? "-" : err.message
            EngineLog.shared.write(
                "react failed: code=\(err.code) msg=\(msgNote) msgId=\(effectiveMsgId) cliId=\(resolvedCliId) msgType=\(msgType)"
            )
            CardActionCenter.shared.show("Không thể thả biểu cảm. Vui lòng thử lại.", in: conversationId)
        } catch {
            rollbackOnError()
            EngineLog.shared.write(
                "react failed: \(error.localizedDescription) msgId=\(effectiveMsgId) cliId=\(resolvedCliId) msgType=\(msgType)"
            )
            CardActionCenter.shared.show("Không thể thả biểu cảm. Vui lòng thử lại.", in: conversationId)
        }
    }

    func handleTyping(state: [String: Any]) {
        if let info = state["typing"] as? [String: Any],
           let convId = info["convId"] as? String,
           let name = info["name"] as? String {
            showTyping(convId: convId, name: name, onPC: info["isPC"] as? Bool ?? false)
        }
    }

    @MainActor
    func notifyTyping(in convId: String) {
        let target = convId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, phase == .ready else { return }
        // Cài đặt ▸ Quyền riêng tư: "Hiển thị trạng thái đang soạn tin" off sends nothing.
        guard userDefaults.object(forKey: OlazPrefs.sendTyping) as? Bool ?? true else { return }
        let now = Date(timeIntervalSince1970: Double(nowMs()) / 1000.0)
        guard OutgoingTypingStore.throttle(for: self).shouldSend(in: target, now: now) else { return }
        let client = sessionClient
        notifyTypingTask = Task {
            guard await client.isAuthenticated else { return }
            await client.sendTypingAPI(convId: target)
        }
    }

    @MainActor
    func resetOutgoingTyping(in convId: String) {
        let target = convId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        OutgoingTypingStore.throttle(for: self).reset(in: target)
    }
}

/// Per-conversation outgoing typing throttle (10 s) stored outside `ZaloEngine` so engine state stays decoupled.
@MainActor
final class OutgoingTypingThrottle {
    /// The official client sends at most one typing ping per 10 s (`functionTyping`).
    static let defaultInterval: TimeInterval = 10

    let interval: TimeInterval
    private var lastSentByConv: [String: Date] = [:]

    init(interval: TimeInterval = OutgoingTypingThrottle.defaultInterval) {
        self.interval = interval
    }

    func shouldSend(in convId: String, now: Date = Date()) -> Bool {
        let key = convId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        if let last = lastSentByConv[key], now.timeIntervalSince(last) < interval {
            return false
        }
        lastSentByConv[key] = now
        return true
    }

    func reset(in convId: String) {
        let key = convId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        lastSentByConv.removeValue(forKey: key)
    }

    func resetAll() {
        lastSentByConv.removeAll()
    }

    func lastSentDate(for convId: String) -> Date? {
        let key = convId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return lastSentByConv[key]
    }
}

@MainActor
private enum OutgoingTypingStore {
    private static let byEngine = NSMapTable<ZaloEngine, OutgoingTypingThrottle>.weakToStrongObjects()

    static func throttle(for engine: ZaloEngine) -> OutgoingTypingThrottle {
        if let existing = byEngine.object(forKey: engine) {
            return existing
        }
        let created = OutgoingTypingThrottle()
        byEngine.setObject(created, forKey: engine)
        return created
    }
}

extension ZaloEngine {
    /// Quote fields of one device's E2EE `/api/e2ee/pc/message/quote` entry, as the official `sendMsgQuote` builds them
    /// from the ciphers of [text, quote text, attach JSON, text styles, owner name, owner global id]. The attach cipher
    /// is not sent for a text quote (official `transformQuoteMessage`). Nil when a cipher is missing.
    nonisolated static func e2eeQuoteFields(ciphers: [String], msgId: Int64, cliMsgId: Int64, ts: Int64) -> [String: Any]? {
        guard ciphers.count >= 6 else { return nil }
        return [
            "qmsg": ciphers[1],
            "textProperties": ciphers[3],
            "qmsgOwnerDName": ciphers[4],
            "qmsgOwner": ciphers[5],
            "qmsgId": msgId,
            "qmsgCliId": cliMsgId,
            "qmsgType": 1,
            "qmsgTs": ts,
        ]
    }
}

extension ZaloEngine {
    /// Official `processRequestResend` -> `_doResend`: a device reported it could not decrypt one of our messages, so
    /// rebuild the session to that device and send the same message (same cliMsgId) to it alone, with `e2ee.retry = 1`.
    /// Text messages only for now; the log keeps shapes (device, kind, codes), never ids or text.
    func resendE2EEMessage(_ request: ZaloE2EEManager.ResendRequest) async {
        let myUid = profile?.userId ?? ""
        let peer = request.peerUid
        guard !myUid.isEmpty,
              let message = (messages[peer] ?? []).first(where: { msg in
                  msg.isMine && (msg.clientId == request.cliMsgId || (!request.msgId.isEmpty && msg.id == request.msgId))
              }) else {
            EngineLog.shared.write("e2ee resend: skip dev=\(request.deviceId) reason=message-not-loaded")
            return
        }
        guard case .text = message.kind, message.quote == nil, !message.text.isEmpty else {
            EngineLog.shared.write("e2ee resend: skip dev=\(request.deviceId) reason=unsupported-kind")
            return
        }
        guard await e2eeManager.reinitSession(
            peerUid: peer, deviceId: request.deviceId, myUid: myUid, webSocket: webSocket, store: sqliteStore) else {
            EngineLog.shared.write("e2ee resend: skip dev=\(request.deviceId) reason=reinit-failed")
            return
        }
        let encrypted = await e2eeManager.encryptTextMessage(
            peerUid: peer, myUid: myUid, text: message.text, onlyDevice: request.deviceId, store: sqliteStore)
        guard let device = encrypted.first, let cipher = device.ciphers.first,
              let clientId = Int64(request.cliMsgId) else {
            EngineLog.shared.write("e2ee resend: skip dev=\(request.deviceId) reason=encrypt-failed")
            return
        }
        let entry = ZaloSessionClient.buildE2EEListParamEntry(
            toId: device.toId,
            platform: device.platform,
            clientId: clientId,
            imei: await sessionClient.imei,
            registrationId: device.registrationId,
            senderIid: await e2eeManager.localRegistrationId(),
            retry: 1,
            extraFields: ["message": cipher]
        )
        do {
            _ = try await sessionClient.sendE2EEMessageAPI(
                endpoint: "sms", threadId: peer, isGroup: false, clientId: clientId, listParams: ZaloJSONArrayBox([entry]))
            EngineLog.shared.write("e2ee resend: sent dev=\(request.deviceId) cipher=\(E2EEShadow.cipherType(cipher))")
        } catch {
            EngineLog.shared.write("e2ee resend: post failed dev=\(request.deviceId) error=\(type(of: error))")
        }
    }
}
