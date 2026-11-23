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
            for msg in decoded { mergeMessageIntoMemory(msg) }
            if decoded.count >= 45, hasMoreHistory[id] != true {
                hasMoreHistory[id] = true
            }
        }

        let isGrp = ZaloWireParser.isGroupId(id)
        updateCallGateForConversation(id)

        Task { [weak self] in
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
                let fetchedName = JSONLossless.string(row["displayName"] ?? row["dName"] ?? row["zaloName"] ?? row["name"])
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
        Task { [weak self] in
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
        let events = await ZaloWireParser.extractBatchEventsAsync(
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

    func sendText(_ text: String, to id: String, quoting quoteId: String? = nil, mentions: [Mention] = []) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !id.isEmpty else { return false }
        resetOutgoingTyping(in: id)

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
            menu: MessageMenu(json: [
                "forward": "ok",
                "recall": id != selfConversationId,
                "delete": id == selfConversationId ? "plain" : "forMe",
                "pin": ZaloWireParser.isGroupId(id) && id != selfConversationId,
                "star": "star"
            ]),
            clientId: cliId
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
            let finalCliId = res.cliMsgId.isEmpty ? cliId : res.cliMsgId
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
                let fetchedName = JSONLossless.string(row["displayName"] ?? row["dName"] ?? row["zaloName"] ?? row["name"])
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
        Task {
            await performReact(emoji, to: messageId, in: conversationId)
        }
    }

    internal func performReact(_ emoji: String, to messageId: String, in conversationId: String) async {
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
        let alreadyMine = initialMsg.reactions.contains(where: { $0.includesMe && $0.icon.type == "\(spec.rType)" })
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
            showTyping(convId: convId, name: name)
        }
    }

    @MainActor
    func notifyTyping(in convId: String) {
        let target = convId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, phase == .ready else { return }
        guard OutgoingTypingStore.throttle(for: self).shouldSend(in: target) else { return }
        let client = sessionClient
        Task {
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

/// Per-conversation outgoing typing throttle (~3.5s) stored outside `ZaloEngine` so engine state stays decoupled.
@MainActor
final class OutgoingTypingThrottle {
    static let defaultInterval: TimeInterval = 3.5

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
