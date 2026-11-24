import CryptoKit
import Foundation
import OlazCore

struct SendMessageResult: Sendable {
    var msgId: String
    var cliMsgId: String
    var tsMs: Int64
}

struct UploadedMediaResult: Sendable {
    var url: String
    var msgId: String
    var cliMsgId: String
    var width: Int
    var height: Int
}

struct ZaloSessionSnapshot: Sendable {
    var account: ZaloLoginAccount?
    var wsEndpoints: [String]
    var zpwSek: String?
    var computerName: String = ""
}

struct ZaloPollQueueCursor: Codable, Equatable, Sendable {
    var lastId: String = "1"
    var ids: [String] = []
}

struct ZaloPollState: Codable, Equatable, Sendable {
    var lastActionId: String = "1"
    var lastActionIdOther: String = "1"
    var queues: [String: ZaloPollQueueCursor] = [
        "1": ZaloPollQueueCursor(),
        "2": ZaloPollQueueCursor(),
        "3": ZaloPollQueueCursor(),
    ]

    func encodedParams() -> String {
        var queuesDict: [String: [String: Any]] = [:]
        for k in queues.keys.sorted() {
            if let q = queues[k] {
                queuesDict[k] = ["lastId": q.lastId, "ids": q.ids]
            }
        }
        let queuesB64: String = {
            if let data = try? JSONSerialization.data(withJSONObject: queuesDict, options: [.sortedKeys]) {
                return data.base64EncodedString()
            }
            return Data("{}".utf8).base64EncodedString()
        }()
        let suffix = ZaloSessionClient.urlEncode("\(queuesB64),1")
        return "\(lastActionId),\(lastActionIdOther),\(suffix)"
    }

    @discardableResult
    mutating func applyResponse(_ dataNode: [String: Any]) -> (more: Bool, reset: Bool) {
        let shouldReset = JSONLossless.bool(dataNode["resetLastActionId"]) == true
            || JSONLossless.int64(dataNode["resetLastActionId"]) == 1
        if shouldReset {
            lastActionId = "1"
            lastActionIdOther = "1"
            queues = [
                "1": ZaloPollQueueCursor(),
                "2": ZaloPollQueueCursor(),
                "3": ZaloPollQueueCursor(),
            ]
            return (more: JSONLossless.int64(dataNode["more"]) == 1, reset: true)
        }

        let nextLast = JSONLossless.string(dataNode["lastActionId"])
        if !nextLast.isEmpty { lastActionId = nextLast }
        let nextOther = JSONLossless.string(dataNode["lastActionIdOther"])
        if !nextOther.isEmpty { lastActionIdOther = nextOther }

        if let qStatus = dataNode["queueStatus"] as? [String: Any] {
            for (rawKey, rawVal) in qStatus {
                // Socket-only queue "15" causes repeated loops if persisted in HTTP poll state.
                if rawKey == "15" { continue }
                guard let qDict = rawVal as? [String: Any] else { continue }
                let lastId = JSONLossless.string(qDict["lastId"])
                var ids: [String] = []
                if let rawIds = qDict["ids"] as? [Any] {
                    ids = rawIds.map(JSONLossless.string).filter { !$0.isEmpty }
                }
                queues[rawKey] = ZaloPollQueueCursor(
                    lastId: lastId.isEmpty ? (queues[rawKey]?.lastId ?? "1") : lastId,
                    ids: ids
                )
            }
        }
        return (more: JSONLossless.int64(dataNode["more"]) == 1, reset: false)
    }
}

extension ZaloSessionClient {
    func currentSnapshot() -> ZaloSessionSnapshot {
        ZaloSessionSnapshot(account: account, wsEndpoints: domains.ws, zpwSek: zpwSek, computerName: computerName)
    }

    // MARK: - Contacts & Profiles

    func fetchFriends(page: Int = 1, count: Int = 20000) async throws -> ZaloJSONArrayBox {
        if let core = coreApi() {
            do {
                let rows = RustCore.objects(try await core.fetchFriends(page: Int64(page), count: Int64(count)))
                for row in rows {
                    let uid = ZaloWireParser.stripUserPrefix(JSONLossless.string(row["userId"] ?? row["uid"] ?? row["id"]))
                    let gid = JSONLossless.string(row["globalId"])
                    if !uid.isEmpty && !gid.isEmpty {
                        globalIdToUidCache[gid] = uid
                        uidToGlobalIdCache[uid] = gid
                    }
                }
                return ZaloJSONArrayBox(rows)
            } catch { throw RustCore.mapError(error) }
        }
        let resp = try await get(
            service: "profile",
            path: "/api/social/friend/getfriends",
            encryptedPayload: [
                "incInvalid": 1,
                "page": page,
                "count": count,
                "avatar_size": 160,
                "actiontime": 0,
                "imei": imei
            ]
        )
        let rows: [[String: Any]] = {
            if let direct = resp["data"] as? [[String: Any]] { return direct }
            if let d = resp["data"] as? [String: Any] {
                return (d["list"] as? [[String: Any]]) ?? (d["friends"] as? [[String: Any]]) ?? []
            }
            return []
        }()
        for row in rows {
            let uid = ZaloWireParser.stripUserPrefix(JSONLossless.string(row["userId"] ?? row["uid"] ?? row["id"]))
            let gid = JSONLossless.string(row["globalId"])
            if !uid.isEmpty && !gid.isEmpty {
                globalIdToUidCache[gid] = uid
                uidToGlobalIdCache[uid] = gid
            }
        }
        return ZaloJSONArrayBox(rows)
    }

    /// Resolves global noised IDs (`Sync2` `convId` / `senderId`) into PC user IDs via `/api/gid/decrypt`.
    func decryptGlobalIds(_ rawGlobalIds: [String]) async -> [String: String] {
        let unique = Array(Set(rawGlobalIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        guard !unique.isEmpty else { return [:] }

        var resolved: [String: String] = [:]
        var missing: [String] = []
        for gid in unique {
            if let hit = globalIdToUidCache[gid] {
                resolved[gid] = hit
            } else {
                missing.append(gid)
            }
        }
        guard !missing.isEmpty else { return resolved }

        for offset in stride(from: 0, to: missing.count, by: 200) {
            let chunk = Array(missing[offset..<min(offset + 200, missing.count)])
            guard let jsonBytes = try? JSONSerialization.data(withJSONObject: chunk),
                  let jsonStr = String(data: jsonBytes, encoding: .utf8),
                  let resp = try? await get(
                      service: "profile",
                      path: "/api/gid/decrypt",
                      encryptedPayload: ["globalUids": jsonStr]
                  ) else {
                continue
            }
            let mapNode = (resp["data"] as? [String: Any]) ?? [:]
            for (rawGid, rawUid) in mapNode {
                let uid = ZaloWireParser.stripUserPrefix(JSONLossless.string(rawUid))
                if !rawGid.isEmpty && !uid.isEmpty {
                    globalIdToUidCache[rawGid] = uid
                    uidToGlobalIdCache[uid] = rawGid
                    resolved[rawGid] = uid
                }
            }
        }
        return resolved
    }

    /// Resolves PC user IDs into global noised IDs via `/api/gid/encrypt`.
    func encryptGlobalIds(_ rawUids: [String]) async -> [String: String] {
        let unique = Array(Set(rawUids.map(ZaloWireParser.stripUserPrefix).filter { !$0.isEmpty }))
        guard !unique.isEmpty else { return [:] }

        var resolved: [String: String] = [:]
        var missing: [String] = []
        for uid in unique {
            if let hit = uidToGlobalIdCache[uid] {
                resolved[uid] = hit
            } else {
                missing.append(uid)
            }
        }
        guard !missing.isEmpty else { return resolved }

        for offset in stride(from: 0, to: missing.count, by: 200) {
            let chunk = Array(missing[offset..<min(offset + 200, missing.count)])
            guard let resp = try? await get(
                service: "profile",
                path: "/api/gid/encrypt",
                encryptedPayload: ["noiseUids": chunk]
            ) else {
                continue
            }
            let mapNode = (resp["data"] as? [String: Any]) ?? [:]
            for (rawUid, rawGid) in mapNode {
                let uid = ZaloWireParser.stripUserPrefix(rawUid)
                let gid = JSONLossless.string(rawGid)
                if !uid.isEmpty && !gid.isEmpty {
                    uidToGlobalIdCache[uid] = gid
                    globalIdToUidCache[gid] = uid
                    resolved[uid] = gid
                }
            }
        }
        return resolved
    }

    func fetchGroupsList() async throws -> ZaloJSONBox {
        if let core = coreApi() {
            do {
                return ZaloJSONBox(RustCore.object(try await core.fetchGroupsList()))
            } catch { throw RustCore.mapError(error) }
        }
        let listResp = try await get(service: "group", path: "/api/group/getlg/v4")
        let outerData = listResp["data"] as? [String: Any] ?? [:]
        let dataDict = (outerData["data"] as? [String: Any]) ?? outerData
        let gridVerMap = (dataDict["gridVerMap"] as? [String: Any]) ?? [:]
        let removedSet = Set((dataDict["removedsGroup"] as? [Any] ?? []).map(JSONLossless.string))
        let allIds = Array(gridVerMap.keys).filter { !$0.isEmpty && !removedSet.contains($0) }
        var combinedInfo: [String: Any] = [:]

        // Fetch group details in batches of 50.
        var offset = 0
        while offset < allIds.count {
            let chunk = Array(allIds[offset..<min(offset + 50, allIds.count)])
            offset += 50
            var chunkVer: [String: Int] = [:]
            for id in chunk { chunkVer[id] = 0 }
            if let verData = try? JSONSerialization.data(withJSONObject: chunkVer),
               let verJSON = String(data: verData, encoding: .utf8),
               let batchResp = try? await post(
                   service: "group",
                   path: "/api/group/getmg-v2",
                   encryptedPayload: ["gridVerMap": verJSON, "imei": imei]
               ),
               let outerBatch = batchResp["data"] as? [String: Any] {
                let batchData = (outerBatch["data"] as? [String: Any]) ?? outerBatch
                if let gridInfoMap = batchData["gridInfoMap"] as? [String: Any] {
                    for (k, v) in gridInfoMap {
                        combinedInfo[k] = v
                    }
                }
            }
        }
        return ZaloJSONBox(["gridVerMap": gridVerMap, "gridInfoMap": combinedInfo])
    }

    func fetchProfiles(uids: [String]) async throws -> ZaloJSONBox {
        if let core = coreApi() {
            var seen = Set<String>()
            let clean = uids.compactMap { raw -> String? in
                guard let uid = ZaloWireParser.sanitizeProfileUid(raw), seen.insert(uid).inserted else { return nil }
                return uid
            }
            guard !clean.isEmpty else { return ZaloJSONBox([:]) }
            do {
                return ZaloJSONBox(RustCore.object(try await core.fetchProfiles(uids: clean)))
            } catch { throw RustCore.mapError(error) }
        }
        var seen = Set<String>()
        var clean: [String] = []
        clean.reserveCapacity(uids.count)
        for raw in uids {
            if let uid = ZaloWireParser.sanitizeProfileUid(raw), seen.insert(uid).inserted {
                clean.append(uid)
            }
        }
        guard !clean.isEmpty else { return ZaloJSONBox([:]) }

        var mergedProfiles: [String: [String: Any]] = [:]
        for offset in stride(from: 0, to: clean.count, by: 50) {
            let chunk = Array(clean[offset..<min(offset + 50, clean.count)])
            let chunkMap = try await fetchProfileChunk(chunk)
            for (uid, row) in chunkMap {
                mergedProfiles[uid] = row
            }
        }
        return ZaloJSONBox(["data": ["profiles": mergedProfiles]])
    }

    private func fetchProfileChunk(_ chunk: [String]) async throws -> [String: [String: Any]] {
        guard !chunk.isEmpty else { return [:] }
        let pver = chunk.map { "\($0)_0" }
        do {
            let resp = try await post(
                service: "profile",
                path: "/api/social/group/members",
                encryptedPayload: ["friend_pversion_map": pver]
            )
            return ZaloWireParser.extractProfilesMap(resp)
        } catch let primaryErr as ZaloSessionError {
            if primaryErr.isAuthError { throw primaryErr }
            do {
                let fallbackResp = try await post(
                    service: "profile",
                    path: "/api/social/friend/getprofiles/v2",
                    encryptedPayload: [
                        "phonebook_version": 0,
                        "friend_pversion_map": pver,
                        "avatar_size": 160,
                        "language": "vi",
                        "show_online_status": 0,
                        "imei": imei
                    ]
                )
                return ZaloWireParser.extractProfilesMap(fallbackResp)
            } catch let fallbackErr as ZaloSessionError {
                if fallbackErr.isAuthError { throw fallbackErr }
                if fallbackErr.code == 114 || primaryErr.code == 114 {
                    if chunk.count > 1 {
                        let mid = chunk.count / 2
                        let left = try await fetchProfileChunk(Array(chunk[..<mid]))
                        let right = try await fetchProfileChunk(Array(chunk[mid...]))
                        var merged = left
                        for (uid, row) in right {
                            merged[uid] = row
                        }
                        return merged
                    }
                    // Single invalid/deleted UID should not poison the rest of a batch.
                    return [:]
                }
                throw fallbackErr
            }
        }
    }

    func fetchAliases() async throws -> [String: String] {
        if let core = coreApi() {
            do {
                return try await core.fetchAliases()
            } catch { throw RustCore.mapError(error) }
        }
        var result: [String: String] = [:]
        let pageSize = 100
        for page in 1...20 {
            let resp = try await get(
                service: "alias",
                path: "/api/alias/list",
                encryptedPayload: ["page": page, "count": pageSize, "imei": imei]
            )
            let dataNode = resp["data"]
            let rows: [[String: Any]] = {
                if let arr = dataNode as? [[String: Any]] { return arr }
                if let d = dataNode as? [String: Any] {
                    return (d["items"] as? [[String: Any]])
                        ?? (d["aliases"] as? [[String: Any]])
                        ?? (d["list"] as? [[String: Any]])
                        ?? []
                }
                return []
            }()
            for row in rows {
                let uid = ZaloWireParser.stripUserPrefix(JSONLossless.string(row["userId"] ?? row["uid"] ?? row["friendId"] ?? row["id"]))
                let alias = JSONLossless.string(row["alias"] ?? row["aliasName"] ?? row["name"]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !uid.isEmpty && !alias.isEmpty {
                    result[uid] = alias
                }
            }
            if rows.count < pageSize { break }
        }
        return result
    }

    func fetchSentFriendRequests() async throws -> ZaloJSONArrayBox {
        let resp = try await get(
            service: "friend",
            path: "/api/friend/requested/list",
            encryptedPayload: ["page": 1, "count": 100, "avatar_size": 120]
        )
        let rows = (resp["data"] as? [[String: Any]]) ?? ((resp["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
        return ZaloJSONArrayBox(rows)
    }

    /// Received friend requests. The official client has no `received/list` endpoint (it 404s on every host): it reads
    /// `recommendsv2/list` (cmd 11437, params `{imei}`) and keeps the `recommItems` whose `dataInfo.recommType == 2`.
    func fetchReceivedFriendRequests() async throws -> ZaloJSONArrayBox {
        let resp = try await get(
            service: "friend",
            path: "/api/friend/recommendsv2/list",
            encryptedPayload: ["imei": imei]
        )
        return ZaloJSONArrayBox(Self.receivedFriendRequestRows(resp["data"]))
    }

    /// Flattens `recommendsv2/list` items with `recommType == 2` into the row shape the contacts sync reads
    /// (`userId`, `displayName`, `zaloName`, `avatar`, `message`, `time`), newest first like the official list.
    static func receivedFriendRequestRows(_ data: Any?) -> [[String: Any]] {
        let items = ((data as? [String: Any])?["recommItems"] as? [[String: Any]]) ?? []
        var rows: [[String: Any]] = []
        for item in items {
            guard let info = item["dataInfo"] as? [String: Any], JSONLossless.int64(info["recommType"]) == 2 else { continue }
            var row = info
            let recomm = info["recommInfo"] as? [String: Any]
            row["message"] = JSONLossless.string(recomm?["message"] ?? info["message"])
            row["time"] = JSONLossless.int64(info["recommTime"] ?? info["friendRequestFetchTime"]) ?? 0
            rows.append(row)
        }
        return rows.sorted { (JSONLossless.int64($0["time"]) ?? 0) > (JSONLossless.int64($1["time"]) ?? 0) }
    }

    static func normalizePhoneForLookup(_ raw: String) -> String {
        let digits = String(raw.filter { $0.isASCII && $0.isNumber })
        if digits.hasPrefix("0") {
            return "84" + digits.dropFirst()
        }
        return digits
    }

    func searchFriendByPhone(_ phone: String) async throws -> ZaloJSONBox {
        let normalized = Self.normalizePhoneForLookup(phone)
        let resp = try await get(
            service: "friend",
            path: "/api/friend/profile/get",
            encryptedPayload: [
                "phone": normalized.isEmpty ? phone : normalized,
                "avatar_size": 240,
                "language": "vi",
                "imei": imei,
                "reqSrc": 40
            ]
        )
        return ZaloJSONBox(resp)
    }

    func sendFriendRequestAPI(toUid: String, message: String) async throws -> ZaloJSONBox {
        let resp = try await post(
            service: "friend",
            path: "/api/friend/sendreq",
            encryptedPayload: [
                "toid": ZaloWireParser.stripUserPrefix(toUid),
                "msg": message,
                "reqsrc": 30,
                "imei": imei,
                "language": "vi"
            ]
        )
        return ZaloJSONBox(resp)
    }

    func acceptFriendRequestAPI(uid: String) async throws -> ZaloJSONBox {
        let resp = try await post(
            service: "friend",
            path: "/api/friend/accept",
            encryptedPayload: ["fid": ZaloWireParser.stripUserPrefix(uid), "language": "vi", "imei": imei]
        )
        return ZaloJSONBox(resp)
    }

    func rejectFriendRequestAPI(uid: String) async throws -> ZaloJSONBox {
        let resp = try await post(
            service: "friend",
            path: "/api/friend/reject",
            encryptedPayload: ["fid": ZaloWireParser.stripUserPrefix(uid), "imei": imei]
        )
        return ZaloJSONBox(resp)
    }

    func cancelFriendRequestAPI(uid: String) async throws -> ZaloJSONBox {
        let resp = try await post(
            service: "friend",
            path: "/api/friend/undo",
            encryptedPayload: ["fid": ZaloWireParser.stripUserPrefix(uid), "imei": imei]
        )
        return ZaloJSONBox(resp)
    }

    func setAliasAPI(uid: String, alias: String) async throws -> ZaloJSONBox {
        let cleanUid = ZaloWireParser.stripUserPrefix(uid)
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let resp = try await get(
                service: "alias",
                path: "/api/alias/remove",
                encryptedPayload: ["friendId": cleanUid]
            )
            return ZaloJSONBox(resp)
        } else {
            let resp = try await get(
                service: "alias",
                path: "/api/alias/update",
                encryptedPayload: ["friendId": cleanUid, "alias": trimmed, "imei": imei]
            )
            return ZaloJSONBox(resp)
        }
    }

    // MARK: - Conversations, Pins, Archive, Mute, Polling, History

    func fetchChatFromPolling(state: ZaloPollState) async throws -> (box: ZaloJSONBox, nextState: ZaloPollState, more: Bool) {
        if let core = coreApi() {
            do {
                let record = PollStateRecord(
                    lastActionId: state.lastActionId,
                    lastActionIdOther: state.lastActionIdOther,
                    queues: state.queues.keys.sorted().map { key in
                        PollQueueRecord(key: key, lastId: state.queues[key]?.lastId ?? "1", ids: state.queues[key]?.ids ?? [])
                    })
                let out = try await core.fetchChatFromPolling(state: record)
                var next = ZaloPollState()
                next.lastActionId = out.nextState.lastActionId
                next.lastActionIdOther = out.nextState.lastActionIdOther
                next.queues = Dictionary(uniqueKeysWithValues: out.nextState.queues.map {
                    ($0.key, ZaloPollQueueCursor(lastId: $0.lastId, ids: $0.ids))
                })
                return (ZaloJSONBox(RustCore.object(out.rawJson)), next, out.more)
            } catch { throw RustCore.mapError(error, quietTimeout: true) }
        }
        let ts = Int64(Date().timeIntervalSince1970)
        let base = ZaloDomains.normalizeHost(domains.lpChat)
        guard let url = URL(string: "\(base)/?\(commonParams())&params=\(state.encodedParams())&ts=\(ts)") else {
            throw ZaloTransportError.invalidURL(domains.lpChat)
        }
        let resp = try await rawGetJSON(url: url, timeout: 12, decryptResponse: true)
        let dataNode = resp["data"] as? [String: Any] ?? resp
        var updated = state
        let outcome = updated.applyResponse(dataNode)
        return (ZaloJSONBox(resp), updated, outcome.more)
    }

    func fetchPinnedConversations() async throws -> [String] {
        if let core = coreApi() {
            do {
                return try await core.fetchPinnedConversations()
            } catch { throw RustCore.mapError(error) }
        }
        let resp = try await get(service: "conversation", path: "/api/pinconvers/list", encryptedPayload: nil)
        let rawIds: [String] = {
            if let list = resp["data"] as? [Any] {
                return list.map(JSONLossless.string).filter { !$0.isEmpty }
            }
            if let dict = resp["data"] as? [String: Any] {
                let arr = (dict["conversations"] as? [Any]) ?? (dict["items"] as? [Any]) ?? []
                return arr.map(JSONLossless.string).filter { !$0.isEmpty }
            }
            return []
        }()
        return rawIds.map { ZaloWireParser.normalizeThreadIdFromList($0) }
    }

    func updatePinnedConversation(convId: String, pinned: Bool) async throws {
        let wireId = ZaloWireParser.isGroupId(convId) ? ZaloWireParser.groupConvId(convId) : "u\(ZaloWireParser.stripUserPrefix(convId))"
        _ = try await post(
            service: "conversation",
            path: "/api/pinconvers/updatev2",
            encryptedPayload: [
                "actionType": pinned ? 1 : 2,
                "conversations": [wireId],
                "tab": 0
            ]
        )
    }

    func fetchArchivedChats() async throws -> [String] {
        if let core = coreApi() {
            do {
                let ids = try await core.fetchArchivedChats()
                archivedVersion = core.archivedVersion()
                return ids
            } catch { throw RustCore.mapError(error) }
        }
        let resp = try await get(
            service: "label",
            path: "/api/archivedchat/list",
            encryptedPayload: ["version": 0, "imei": imei]
        )
        let d = resp["data"] as? [String: Any] ?? [:]
        if let ver = JSONLossless.int64(d["version"]) {
            self.archivedVersion = ver
        }
        var result: [String] = []
        if let items = d["items"] as? [[String: Any]] {
            for item in items {
                let rawId = JSONLossless.string(item["id"])
                guard !rawId.isEmpty else { continue }
                let typeVal = JSONLossless.int64(item["type"]) ?? 0
                if typeVal == 1 || ZaloWireParser.isGroupId(rawId) {
                    result.append(ZaloWireParser.groupConvId(rawId))
                } else {
                    result.append(ZaloWireParser.normalizeThreadIdFromList(rawId))
                }
            }
        } else if let rawIds = (d["conversations"] as? [String]) ?? (resp["data"] as? [String]) {
            result = rawIds.map { ZaloWireParser.normalizeThreadIdFromList($0) }
        }
        return result
    }

    func updateArchivedChat(convId: String, archived: Bool) async throws {
        let isGroup = ZaloWireParser.isGroupId(convId)
        let cleanId = isGroup ? ZaloWireParser.cleanGroupId(convId) : ZaloWireParser.stripUserPrefix(convId)
        _ = try await post(
            service: "label",
            path: "/api/archivedchat/update",
            encryptedPayload: [
                "ids": [["id": cleanId, "type": isGroup ? 1 : 0]],
                "version": archivedVersion,
                "actionType": archived ? 0 : 1,
                "imei": imei
            ]
        )
    }

    func fetchConversationLabels() async throws -> ZaloJSONBox {
        if let core = coreApi() {
            do {
                let box = ZaloJSONBox(RustCore.object(try await core.fetchConversationLabels()))
                labelVersion = core.labelVersion()
                return box
            } catch { throw RustCore.mapError(error) }
        }
        let resp = try await get(
            service: "label",
            path: "/api/convlabel/get",
            encryptedPayload: ["imei": imei]
        )
        let d = resp["data"] as? [String: Any] ?? [:]
        if let ver = JSONLossless.int64(d["version"]) {
            self.labelVersion = ver
        }
        return ZaloJSONBox(d)
    }

    func updateConversationLabels(labelDataJSON: String) async throws {
        let resp = try await post(
            service: "label",
            path: "/api/convlabel/update",
            encryptedPayload: [
                "labelData": labelDataJSON,
                "version": labelVersion,
                "imei": imei
            ]
        )
        if let d = resp["data"] as? [String: Any], let ver = JSONLossless.int64(d["version"]) {
            self.labelVersion = ver
        }
    }

    func setUnreadMarkAPI(convId: String, unread: Bool) async throws {
        if let core = coreApi() {
            do {
                try await core.setUnreadMark(convId: convId, unread: unread)
                return
            } catch { throw RustCore.mapError(error) }
        }
        let isGroup = ZaloWireParser.isGroupId(convId)
        let cleanId = isGroup ? ZaloWireParser.cleanGroupId(convId) : ZaloWireParser.stripUserPrefix(convId)
        let convsGroup: [String] = isGroup ? [cleanId] : []
        let convsUser: [String] = isGroup ? [] : [cleanId]
        let path: String
        let inner: [String: Any]
        if unread {
            path = "/api/conv/addUnreadMark"
            inner = [
                "convsGroup": convsGroup,
                "convsUser": convsUser,
                "imei": imei
            ]
        } else {
            path = "/api/conv/removeUnreadMark"
            inner = [
                "convsGroup": convsGroup,
                "convsUser": convsUser,
                "convsGroupData": [],
                "convsUserData": []
            ]
        }
        let innerData = try JSONSerialization.data(withJSONObject: inner, options: [])
        let innerStr = String(decoding: innerData, as: UTF8.self)
        _ = try await post(
            service: "conversation",
            path: path,
            encryptedPayload: ["param": innerStr]
        )
    }

    func setHiddenConversationAPI(convId: String, hidden: Bool) async {
        let isGroup = ZaloWireParser.isGroupId(convId)
        let cleanId = isGroup ? ZaloWireParser.cleanGroupId(convId) : ZaloWireParser.stripUserPrefix(convId)
        let entry: [[String: Any]] = [["thread_id": cleanId, "is_group": isGroup ? 1 : 0]]
        let entryStr = (try? JSONSerialization.data(withJSONObject: entry)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let addStr = hidden ? entryStr : "[]"
        let delStr = hidden ? "[]" : entryStr
        _ = try? await post(
            service: "conversation",
            path: "/api/hiddenconvers/add-remove",
            encryptedPayload: ["del_threads": delStr, "add_threads": addStr, "imei": imei]
        )
    }

    func deleteConversationAPI(convId: String, lastCliMsgId: String = "") async {
        let isGroup = ZaloWireParser.isGroupId(convId)
        let cleanId = isGroup ? ZaloWireParser.cleanGroupId(convId) : ZaloWireParser.stripUserPrefix(convId)
        let cliId = lastCliMsgId.isEmpty ? "\(nextClientId())" : lastCliMsgId
        if isGroup {
            _ = try? await post(
                service: "group",
                path: "/api/group/deleteconver",
                encryptedPayload: [
                    "grid": cleanId,
                    "cliMsgId": cliId,
                    "conver": [String: Any](),
                    "onlyMe": 1,
                    "imei": imei
                ]
            )
        } else {
            _ = try? await post(
                service: "chat",
                path: "/api/message/deleteconver",
                encryptedPayload: [
                    "toid": cleanId,
                    "cliMsgId": cliId,
                    "conver": [String: Any](),
                    "onlyMe": 1,
                    "imei": imei
                ]
            )
        }
    }

    func fetchMuteList() async throws -> ZaloJSONArrayBox {
        if let core = coreApi() {
            do {
                return ZaloJSONArrayBox(RustCore.objects(try await core.fetchMuteList()))
            } catch { throw RustCore.mapError(error) }
        }
        let resp = try await get(service: "profile", path: "/api/social/profile/getmute", encryptedPayload: ["imei": imei])
        let d = resp["data"] as? [String: Any] ?? [:]
        var normalized: [[String: Any]] = []
        if let peerEntries = d["chatEntries"] as? [[String: Any]] {
            for var row in peerEntries {
                row["type"] = 1
                normalized.append(row)
            }
        }
        if let grpEntries = d["groupChatEntries"] as? [[String: Any]] {
            for var row in grpEntries {
                row["type"] = 2
                normalized.append(row)
            }
        }
        if normalized.isEmpty {
            let fallback = (d["chats"] as? [[String: Any]]) ?? (resp["data"] as? [[String: Any]]) ?? []
            normalized.append(contentsOf: fallback)
        }
        return ZaloJSONArrayBox(normalized)
    }

    func setMuteAPI(convId: String, isGroup: Bool, durationSeconds: Int, unmute: Bool) async throws {
        let cleanId = isGroup ? ZaloWireParser.cleanGroupId(convId) : ZaloWireParser.stripUserPrefix(convId)
        _ = try await post(
            service: "profile",
            path: "/api/social/profile/setmute",
            encryptedPayload: [
                "toid": cleanId,
                "duration": unmute ? 0 : durationSeconds,
                "action": unmute ? 3 : 1,
                "startTime": Int64(Date().timeIntervalSince1970),
                "muteType": isGroup ? 2 : 1,
                "imei": imei
            ]
        )
    }

    func fetchPreloadConversations(threadIds: [String] = []) async throws -> ZaloJSONBox {
        if let core = coreApi() {
            do {
                return ZaloJSONBox(RustCore.object(try await core.fetchPreloadConversations(threadIds: threadIds)))
            } catch { throw RustCore.mapError(error) }
        }
        var mapDict: [String: String] = [:]
        for rawId in threadIds.prefix(25) {
            if ZaloWireParser.isGroupId(rawId) {
                let clean = ZaloWireParser.cleanGroupId(rawId)
                if !clean.isEmpty { mapDict["\(clean)_1"] = "1" }
            } else {
                let clean = ZaloWireParser.stripUserPrefix(rawId)
                if !clean.isEmpty { mapDict["\(clean)_0"] = "1" }
            }
        }
        let mapJSON: String = {
            if mapDict.isEmpty { return "{}" }
            if let data = try? JSONSerialization.data(withJSONObject: mapDict, options: [.sortedKeys]) {
                return String(decoding: data, as: UTF8.self)
            }
            return "{}"
        }()
        let resp = try await get(
            service: "conversation",
            path: "/api/preloadconvers/get-last-msgs",
            encryptedPayload: [
                "threadIdLocalMsgId": mapJSON,
                "imei": imei
            ]
        )
        return ZaloJSONBox(resp)
    }

    func fetchGroupCloudFirstLogin(groupIds: [String], nretry: Int = 0) async throws -> ZaloJSONBox {
        let cleanIds = groupIds.map(ZaloWireParser.cleanGroupId).filter { !$0.isEmpty }
        guard !cleanIds.isEmpty else { return ZaloJSONBox(["error_code": 0, "data": [:]]) }
        let resp = try await get(
            service: "group_cloud_message",
            path: "/api/cm/mget",
            headers: ["nretry": "\(nretry)"],
            encryptedPayload: ["groupIds": cleanIds]
        )
        return ZaloJSONBox(resp)
    }

    /// History as a typed page: on the Rust path the answer stays in the core (no JSON in Swift, see `ZaloHistoryPage`);
    /// on the Swift path it wraps the dictionary the Swift walk produces.
    func fetchHistoryPage(convId: String, lastMsgId: String?, count: Int = 50, isOld: Bool? = nil) async throws -> ZaloHistoryPage {
        if let core = coreApi() {
            do {
                let h = try await core.fetchHistory(convId: convId, lastMsgId: lastMsgId, count: Int64(count), isOld: isOld)
                return ZaloHistoryPage(record: h)
            } catch { throw RustCore.mapError(error) }
        }
        return ZaloHistoryPage(box: try await fetchHistorySwift(convId: convId, lastMsgId: lastMsgId, count: count, isOld: isOld))
    }

    /// History as a raw dictionary, for callers that read raw fields or feed `applyBatchResponse`.
    func fetchHistory(convId: String, lastMsgId: String?, count: Int = 50, isOld: Bool? = nil) async throws -> ZaloJSONBox {
        try await fetchHistoryPage(convId: convId, lastMsgId: lastMsgId, count: count, isOld: isOld).box
    }

    private func fetchHistorySwift(convId: String, lastMsgId: String?, count: Int, isOld: Bool?) async throws -> ZaloJSONBox {
        let isGroup = ZaloWireParser.isGroupId(convId)
        let cleanId = isGroup ? ZaloWireParser.cleanGroupId(convId) : ZaloWireParser.stripUserPrefix(convId)
        let isSelfCloud = !isGroup && (
            cleanId == account?.send2MeId
            || (cleanId == account?.userId && !(account?.send2MeId.isEmpty ?? true))
        )
        let hasValidCursor = lastMsgId != nil && !lastMsgId!.isEmpty && lastMsgId != "0"

        // 1-1 peer conversations do not live in `/api/cm/*`; fetch recent messages via `get-last-msgs`.
        if !isGroup && !isSelfCloud {
            if isOld == true || hasValidCursor { return ZaloJSONBox(["error_code": 0, "data": ["msgs": []]]) }
            return try await fetchPreloadConversations(threadIds: [convId])
        }

        let cloudId: String = {
            if isSelfCloud, let send2Me = account?.send2MeId, !send2Me.isEmpty {
                return send2Me
            }
            return cleanId
        }()
        if isOld == true && !hasValidCursor {
            return ZaloJSONBox(["error_code": 0, "data": ["msgs": []]])
        }
        if !hasValidCursor && isOld == nil {
            cloudIsOldByConv[cloudId] = false
        }

        var currentIsOld = isOld ?? (hasValidCursor ? (cloudIsOldByConv[cloudId] ?? false) : false)
        var currentCursor = hasValidCursor ? lastMsgId! : "9223372036854775807"
        var accumulatedMsgs: [[String: Any]] = []
        var lastResponse: [String: Any] = ["error_code": 0, "data": ["groupMsgs": []]]
        var finalHasMore = false
        var finalLastMsgId = "0"
        let minTargetCount = min(20, max(1, count))

        func buildCloudPayload(cursorId: String, srcVal: Int) -> [String: Any] {
            var p: [String: Any] = [
                "groupId": cloudId,
                "globalMsgId": cursorId,
                "count": count,
                "msgIds": [],
                "imei": imei,
                "src": srcVal
            ]
            if isSelfCloud { p["isOA"] = 1 }
            return p
        }

        for attempt in 0..<8 {
            let path = currentIsOld ? "/api/cm/getoldv2" : "/api/cm/getrecentv2"
            let srcVal = attempt == 0 ? (hasValidCursor ? 3 : 1) : 2
            let resp: [String: Any]
            do {
                resp = try await get(
                    service: "group_cloud_message",
                    path: path,
                    headers: ["nretry": "\(attempt)"],
                    encryptedPayload: buildCloudPayload(cursorId: currentCursor, srcVal: srcVal)
                )
            } catch {
                if attempt == 0 { throw error }
                break
            }

            lastResponse = resp
            guard let d = resp["data"] as? [String: Any] else { break }
            let pageMsgs = (d["groupMsgs"] as? [[String: Any]]) ?? []
            accumulatedMsgs.append(contentsOf: pageMsgs)

            let serverIsOld = JSONLossless.int64(d["isOld"]) == 1 || (d["isOld"] as? Bool == true)
            let serverHasMore = JSONLossless.int64(d["hasMore"]) == 1 || (d["hasMore"] as? Bool == true)
            let rawLast = JSONLossless.string(d["lastMsgId"])

            cloudIsOldByConv[cloudId] = serverIsOld
            currentIsOld = serverIsOld
            finalHasMore = serverHasMore
            finalLastMsgId = rawLast

            if !serverHasMore
                || accumulatedMsgs.count >= minTargetCount
                || rawLast.isEmpty
                || rawLast == "0"
                || rawLast == currentCursor {
                break
            }
            currentCursor = rawLast
        }

        var outData = (lastResponse["data"] as? [String: Any]) ?? [:]
        outData["groupMsgs"] = accumulatedMsgs
        outData["isOld"] = currentIsOld ? 1 : 0
        outData["hasMore"] = finalHasMore ? 1 : 0
        outData["lastMsgId"] = finalLastMsgId
        lastResponse["data"] = outData
        return ZaloJSONBox(lastResponse)
    }

    // MARK: - Messaging, Quote, Typing, Seen, Reaction, Delete, Recall

    func sendTextAPI(
        convId: String,
        text: String,
        cliMsgId: String,
        quoteMsgId: String? = nil,
        quoteCliMsgId: String? = nil,
        quoteOwnerId: String? = nil,
        quoteText: String? = nil,
        quoteTsMs: Int64? = nil,
        mentions: [Mention] = [],
        textProperties: String? = nil,
        ttl: Int64 = 0,
        urgency: Int = 0
    ) async throws -> SendMessageResult {
        if let core = coreApi() {
            do {
                let r = try await core.sendText(args: SendTextRecord(
                    convId: convId, text: text, cliMsgId: cliMsgId, quoteMsgId: quoteMsgId, quoteCliMsgId: quoteCliMsgId,
                    quoteOwnerId: quoteOwnerId, quoteText: quoteText, quoteTsMs: quoteTsMs,
                    mentions: mentions.map { MentionRecord(uid: $0.uid, pos: Int64($0.pos), len: Int64($0.len), isAll: $0.isAll) },
                    textProperties: textProperties, ttl: ttl, urgency: Int64(urgency)))
                return SendMessageResult(msgId: r.msgId, cliMsgId: r.cliMsgId, tsMs: r.tsMs)
            } catch { throw RustCore.mapError(error) }
        }
        let isGroup = ZaloWireParser.isGroupId(convId)
        let cleanId = isGroup ? ZaloWireParser.cleanGroupId(convId) : ZaloWireParser.stripUserPrefix(convId)
        let cliInt = Int64(cliMsgId) ?? nextClientId()
        let cliStr = "\(cliInt)"
        let qMsgInt = quoteMsgId.flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let hasQuote = qMsgInt != nil && qMsgInt != 0

        let mentionStr: String? = {
            guard isGroup, !mentions.isEmpty else { return nil }
            let mentionObjs: [[String: Any]] = mentions.map { m in
                ["uid": m.isAll ? "-1" : ZaloWireParser.stripUserPrefix(m.uid), "pos": m.pos, "len": m.len, "type": m.isAll ? 1 : 0]
            }
            guard let mData = try? JSONSerialization.data(withJSONObject: mentionObjs),
                  let mStr = String(data: mData, encoding: .utf8) else { return nil }
            return mStr
        }()

        func buildPlainPayload() -> [String: Any] {
            var payload: [String: Any] = [
                "message": text,
                "clientId": cliInt,
                "imei": imei,
                "ttl": ttl
            ]
            if let textProperties { payload["textProperties"] = textProperties }
            if urgency > 0 { payload["metaData"] = ["urgency": urgency] }
            if isGroup {
                payload["grid"] = cleanId
                payload["visibility"] = 0
                if let mentionStr { payload["mentionInfo"] = mentionStr }
            } else {
                payload["toid"] = cleanId
            }
            return payload
        }

        let service = isGroup ? "group" : "chat"
        var resp: [String: Any]?
        if hasQuote, let qMsgInt {
            var qPayload: [String: Any] = [
                "message": text,
                "clientId": cliInt,
                "qmsgOwner": ZaloWireParser.stripUserPrefix(quoteOwnerId ?? account?.userId ?? ""),
                "qmsgId": qMsgInt,
                "qmsgCliId": Int64(quoteCliMsgId ?? "") ?? qMsgInt,
                "qmsgType": 1,
                "qmsg": quoteText ?? "",
                "qmsgTs": quoteTsMs ?? Int64(Date().timeIntervalSince1970 * 1000),
                "ttl": ttl,
                "zsource": 101,
                "imei": imei
            ]
            if let textProperties { qPayload["textProperties"] = textProperties }
            if urgency > 0 { qPayload["metaData"] = ["urgency": urgency] }
            if isGroup {
                qPayload["grid"] = cleanId
                qPayload["visibility"] = 0
                qPayload["language"] = "vi"
                qPayload["qmsgAttach"] = "{}"
                if let mentionStr { qPayload["mentionInfo"] = mentionStr }
            } else {
                qPayload["toid"] = cleanId
            }
            let quotePath = isGroup ? "/api/group/quote" : "/api/message/quote"
            resp = try? await post(service: service, path: quotePath, encryptedPayload: qPayload)
        }

        if resp == nil {
            let plainPath = isGroup ? "/api/group/sendmsg" : "/api/message/sms"
            resp = try await post(service: service, path: plainPath, encryptedPayload: buildPlainPayload())
        }

        let d = resp?["data"] as? [String: Any] ?? [:]
        let serverMsgId = JSONLossless.string(d["msgId"])
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return SendMessageResult(
            msgId: serverMsgId.isEmpty ? cliStr : serverMsgId,
            cliMsgId: cliStr,
            tsMs: nowMs
        )
    }

    /// Official `VERSION_MSG` (text, sticker, file, photo, link, gif: `{version:0, compat_version:0}`). A receiver drops
    /// any message whose `compat_version` is above the one it knows before decrypting it: Zalo PC 26.10 shows a text sent
    /// with 1 as failed while the phone still opens it.
    static let e2eeMsgVersion = 0
    static let e2eeMsgCompatVersion = 0

    static func buildE2EEExtJSON(
        registrationId: Int,
        senderRegistrationId: Int,
        version: Int = e2eeMsgVersion,
        compatVersion: Int = e2eeMsgCompatVersion,
        retry: Int = 0
    ) -> String {
        // Official `buildE2eeParams` / `_enrichAdditionalParams`: iid and sender_iid only when known.
        var obj: [String: Any] = [
            "version": version,
            "compat_version": compatVersion,
        ]
        if registrationId > 0 { obj["iid"] = registrationId }
        if senderRegistrationId > 0 { obj["sender_iid"] = senderRegistrationId }
        if retry > 0 { obj["retry"] = retry }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    static func buildE2EEListParamEntry(
        toId: String,
        platform: Int,
        clientId: Int64,
        imei: String,
        registrationId: Int,
        senderIid: Int,
        ttl: Int = 0,
        useLegacyE2EEKey: Bool = false,
        version: Int = e2eeMsgVersion,
        compatVersion: Int = e2eeMsgCompatVersion,
        retry: Int = 0,
        extraFields: [String: Any] = [:]
    ) -> [String: Any] {
        let extJSON = buildE2EEExtJSON(
            registrationId: registrationId,
            senderRegistrationId: senderIid,
            version: version,
            compatVersion: compatVersion,
            retry: retry
        )
        var entry: [String: Any] = [
            "toId": ZaloWireParser.stripUserPrefix(toId),
            "platform": platform,
            "clientId": clientId,
            "imei": imei,
            "ttl": ttl,
            useLegacyE2EEKey ? "e2ee" : "e2eeExt": extJSON,
        ]
        for (k, v) in extraFields {
            entry[k] = v
        }
        return entry
    }

    static func buildFileMsgParamsJSON(md5Hex: String, fileExt: String, fileSize: Int64) -> String {
        let obj: [String: Any] = [
            "checksum": md5Hex,
            "checksumSha": "",
            "fType": 1,
            "fdata": "{}",
            "fileExt": fileExt,
            "fileSize": fileSize,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    static func buildE2EEFileListParamEntry(
        toId: String,
        platform: Int,
        clientId: Int64,
        imei: String,
        registrationId: Int,
        senderIid: Int,
        rawFileUrl: String,
        fileId: String,
        cipherSession: String,
        cipherParams: String,
        cipherFileName: String,
        cipherThumb: String,
        ttl: Int = 0
    ) -> [String: Any] {
        let sep = rawFileUrl.contains("?") ? "&e2esession=" : "?e2esession="
        let fidVal: Any = Int64(fileId) ?? fileId
        return buildE2EEListParamEntry(
            toId: toId,
            platform: platform,
            clientId: clientId,
            imei: imei,
            registrationId: registrationId,
            senderIid: senderIid,
            ttl: ttl,
            version: 0,
            compatVersion: 0,
            extraFields: [
                "fileId": fidVal,
                "fileUrl": "\(rawFileUrl)\(sep)\(cipherSession)",
                "prmE2EE": cipherParams,
                "fileName": cipherFileName,
                "thumb": cipherThumb,
            ]
        )
    }

    static func buildAsyncFileMsgPayload(
        cleanConvId: String,
        isGroup: Bool,
        fileId: String,
        fileUrl: String,
        fileName: String,
        ext: String,
        fileSize: Int,
        checksum: String,
        clientId: Int64,
        imei: String
    ) -> (path: String, payload: [String: Any]) {
        let fidVal: Any = Int64(fileId) ?? fileId
        var sendPayload: [String: Any] = [
            "fileId": fidVal,
            "checksum": checksum,
            "checksumSha": "",
            "extension": ext,
            "totalSize": fileSize,
            "fileName": fileName,
            "clientId": clientId,
            "fType": 1,
            "fileCount": 0,
            "fdata": "{}",
            "ttl": 0,
            "imei": imei,
        ]
        if !fileUrl.isEmpty {
            sendPayload["fileUrl"] = fileUrl
        }
        if isGroup {
            sendPayload["grid"] = cleanConvId
            return ("/api/group/asyncfile/msg", sendPayload)
        } else {
            sendPayload["toid"] = cleanConvId
            return ("/api/message/asyncfile/msg", sendPayload)
        }
    }

    static func buildE2EEMessageRequestPayload(
        endpoint: String,
        threadId: String,
        isGroup: Bool,
        clientId: Int64,
        listParams: [[String: Any]],
        destType: Int = 3
    ) -> (service: String, path: String, payload: [String: Any]) {
        let cleanId = isGroup ? ZaloWireParser.cleanGroupId(threadId) : ZaloWireParser.stripUserPrefix(threadId)
        if isGroup {
            var payload = listParams.first ?? [:]
            payload["clientId"] = clientId
            return ("group_e2e", "/api/e2ee/pc/group/\(endpoint)", payload)
        }
        let listStr = (try? JSONSerialization.data(withJSONObject: listParams, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let payload: [String: Any] = [
            "listParams": listStr,
            "destType": destType,
            "threadId": cleanId,
            "clientId": clientId,
        ]
        return ("chat_e2e", "/api/e2ee/pc/message/\(endpoint)", payload)
    }

    static func extractE2EESendResponse(_ resp: [String: Any]) -> (msgId: String, tsMs: Int64?) {
        let d = resp["data"] as? [String: Any]
        let nested = d?["data"] as? [String: Any]
        var dicts: [[String: Any]] = []
        if let d { dicts.append(d) }
        if let nested { dicts.append(nested) }
        if let arr = d?["data"] as? [[String: Any]] {
            dicts.append(contentsOf: arr)
        }
        dicts.append(resp)

        var msgId = ""
        for dict in dicts where msgId.isEmpty {
            for key in ["minGlobalMsgId", "msgId", "globalMsgId"] {
                let candidate = JSONLossless.string(dict[key]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty && candidate != "0" {
                    msgId = candidate
                    break
                }
            }
        }

        var tsMs: Int64?
        for dict in dicts {
            if let rawTs = JSONLossless.int64(dict["ts"] ?? dict["sendDttm"]), rawTs > 0 {
                tsMs = rawTs < 10_000_000_000 ? rawTs * 1000 : rawTs
                break
            }
        }
        return (msgId, tsMs)
    }

    func sendE2EEMessageAPI(
        endpoint: String,
        threadId: String,
        isGroup: Bool,
        clientId: Int64,
        listParams: ZaloJSONArrayBox,
        destType: Int = 3
    ) async throws -> SendMessageResult {
        let spec = Self.buildE2EEMessageRequestPayload(
            endpoint: endpoint,
            threadId: threadId,
            isGroup: isGroup,
            clientId: clientId,
            listParams: listParams.array,
            destType: destType
        )
        let resp = try await post(
            service: spec.service,
            path: spec.path,
            encryptedPayload: spec.payload
        )
        let extracted = Self.extractE2EESendResponse(resp)
        do {
            let path = spec.path
            let code = JSONLossless.int64(resp["error_code"]).map(String.init) ?? "-"
            let entries = listParams.array.count
            let ext = (listParams.array.first?["e2eeExt"] as? String).flatMap { JSONLossless.parseObject(Data($0.utf8)) }
            let versions = ext.map { "\(JSONLossless.int64($0["version"]) ?? -1)/\(JSONLossless.int64($0["compat_version"]) ?? -1)" } ?? "-"
            Task { @MainActor in
                EngineLog.shared.write("e2ee send: post path=\(path) entries=\(entries) version=\(versions) error_code=\(code) msgId=\(!extracted.msgId.isEmpty)")
            }
        }
        if extracted.msgId.isEmpty {
            // Shapes only (key names), never values: the message keeps its clientId until the WS echo.
            let dataKeys = (resp["data"] as? [String: Any]).map { $0.keys.sorted().joined(separator: ",") }
                ?? String(describing: type(of: resp["data"] ?? NSNull()))
            let path = spec.path
            Task { @MainActor in
                EngineLog.shared.write("e2ee send: no server msgId path=\(path) dataKeys=\(dataKeys)")
            }
        }
        let cliStr = "\(clientId)"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return SendMessageResult(
            msgId: extracted.msgId.isEmpty ? cliStr : extracted.msgId,
            cliMsgId: cliStr,
            tsMs: extracted.tsMs ?? nowMs
        )
    }

    /// Official `DEST_TYPING.USER` (`PAGE` = 5 is for official accounts). 0 is not a valid value: the peer shows nothing.
    static let typingDestUser = 3

    func sendTypingAPI(convId: String) async {
        if let core = coreApi() {
            try? await core.sendTyping(convId: convId)
            return
        }
        let isGroup = ZaloWireParser.isGroupId(convId)
        let cleanId = isGroup ? ZaloWireParser.cleanGroupId(convId) : ZaloWireParser.stripUserPrefix(convId)
        let service = isGroup ? "group" : "chat"
        let path = isGroup ? "/api/group/typing" : "/api/message/typing"
        let payload: [String: Any] = isGroup
            ? ["grid": cleanId, "imei": imei]
            : ["toid": cleanId, "destType": Self.typingDestUser, "imei": imei]
        _ = try? await post(service: service, path: path, encryptedPayload: payload)
    }

    func sendSeenAPI(convId: String, msgId: String, cliMsgId: String, senderId: String) async {
        if let core = coreApi() {
            try? await core.sendSeen(convId: convId, msgId: msgId, cliMsgId: cliMsgId, senderId: senderId)
            return
        }
        let isGroup = ZaloWireParser.isGroupId(convId)
        let cleanId = isGroup ? ZaloWireParser.cleanGroupId(convId) : ZaloWireParser.stripUserPrefix(convId)
        let trimmedMsg = msgId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty, !trimmedMsg.isEmpty else { return }
        let cmi = cliMsgId.isEmpty ? trimmedMsg : cliMsgId
        let msgInfos: [String: Any] = isGroup
            ? ["data": [["gmi": trimmedMsg, "cmi": cmi]], "grid": cleanId]
            : ["data": [["gmi": trimmedMsg, "cmi": cmi]], "senderId": cleanId]
        guard let infoData = try? JSONSerialization.data(withJSONObject: msgInfos),
              let infoStr = String(data: infoData, encoding: .utf8) else { return }
        let service = isGroup ? "group" : "chat"
        let path = isGroup ? "/api/group/seenv2" : "/api/message/seenv2"
        var payload: [String: Any] = ["msgInfos": infoStr]
        if isGroup { payload["imei"] = imei }
        _ = try? await post(service: service, path: path, encryptedPayload: payload)
    }

    struct ReactionRequestSpec: @unchecked Sendable {
        let service: String
        let path: String
        let payload: [String: Any]
        let clientId: Int64
    }

    static func buildReactionRequest(
        convId: String,
        msgId: String,
        cliMsgId: String,
        rIcon: String,
        rType: Int,
        msgType: Int,
        clientId: Int64,
        imei: String
    ) -> ReactionRequestSpec {
        let isGroup = ZaloWireParser.isGroupId(convId)
        let cleanId = isGroup ? ZaloWireParser.cleanGroupId(convId) : ZaloWireParser.stripUserPrefix(convId)
        let gMsgVal: Any = Int64(msgId) ?? msgId
        let cMsgInt = Int64(cliMsgId) ?? Int64(msgId) ?? clientId
        let innerDict: [String: Any] = [
            "rMsg": [["gMsgID": gMsgVal, "cMsgID": cMsgInt, "msgType": msgType]],
            "rIcon": rIcon,
            "rType": rType,
            "source": 6
        ]
        let innerData = (try? JSONSerialization.data(withJSONObject: innerDict, options: [.withoutEscapingSlashes]))
            ?? Data("{}".utf8)
        let innerStr = String(decoding: innerData, as: UTF8.self)
        let path = isGroup ? "/api/group/reaction" : "/api/message/reaction"
        var payload: [String: Any] = [
            "react_list": [[
                "message": innerStr,
                "clientId": clientId
            ]]
        ]
        if isGroup {
            payload["grid"] = cleanId
            payload["imei"] = imei
        } else {
            payload["toid"] = cleanId
        }
        return ReactionRequestSpec(service: "reaction", path: path, payload: payload, clientId: clientId)
    }

    @discardableResult
    func sendReactionAPI(
        convId: String,
        msgId: String,
        cliMsgId: String,
        rIcon: String,
        rType: Int,
        msgType: Int = 1,
        clientId: Int64? = nil
    ) async throws -> Int64 {
        if let core = coreApi() {
            do {
                return try await core.sendReaction(
                    convId: convId, msgId: msgId, cliMsgId: cliMsgId, rIcon: rIcon, rType: Int64(rType),
                    msgType: Int64(msgType), clientId: clientId)
            } catch { throw RustCore.mapError(error) }
        }
        let nowInt = clientId ?? nextClientId()
        let spec = Self.buildReactionRequest(
            convId: convId,
            msgId: msgId,
            cliMsgId: cliMsgId,
            rIcon: rIcon,
            rType: rType,
            msgType: msgType,
            clientId: nowInt,
            imei: imei
        )
        _ = try await post(service: spec.service, path: spec.path, encryptedPayload: spec.payload)
        return spec.clientId
    }

    struct RecallRequestSpec: @unchecked Sendable {
        let service: String
        let path: String
        let payload: [String: Any]
    }

    static func buildRecallMessageRequest(
        convId: String,
        msgId: String,
        cliMsgId: String,
        clientId: Int64,
        isE2EE: Bool,
        imei: String,
        visibility: Int = 0,
        destType: Int = 3
    ) -> RecallRequestSpec {
        let isGroup = ZaloWireParser.isGroupId(convId)
        let cleanId = isGroup ? ZaloWireParser.cleanGroupId(convId) : ZaloWireParser.stripUserPrefix(convId)
        let effectiveCliUndo = cliMsgId.isEmpty ? msgId : cliMsgId
        var payload: [String: Any] = [
            "msgId": msgId,
            "clientId": clientId,
            "cliMsgIdUndo": effectiveCliUndo,
        ]
        if isGroup {
            payload["grid"] = cleanId
            payload["visibility"] = visibility
            payload["imei"] = imei
            return RecallRequestSpec(
                service: isE2EE ? "group_e2e" : "group",
                path: isE2EE ? "/api/e2ee/pc/group/undoMsg" : "/api/group/undomsg",
                payload: payload
            )
        }
        payload["toid"] = cleanId
        if isE2EE {
            payload["destType"] = destType
            return RecallRequestSpec(
                service: "chat_e2e",
                path: "/api/e2ee/pc/message/undo",
                payload: payload
            )
        }
        return RecallRequestSpec(
            service: "chat",
            path: "/api/message/undo",
            payload: payload
        )
    }

    func recallMessageAPI(convId: String, msgId: String, cliMsgId: String, isE2EE: Bool = false) async throws {
        if let core = coreApi() {
            do {
                try await core.recallMessage(convId: convId, msgId: msgId, cliMsgId: cliMsgId, isE2ee: isE2EE)
                return
            } catch { throw RustCore.mapError(error) }
        }
        let spec = Self.buildRecallMessageRequest(
            convId: convId,
            msgId: msgId,
            cliMsgId: cliMsgId,
            clientId: nextClientId(),
            isE2EE: isE2EE,
            imei: imei
        )
        _ = try await post(service: spec.service, path: spec.path, encryptedPayload: spec.payload)
    }

    func deleteMessageForMeAPI(convId: String, msgId: String, cliMsgId: String, senderId: String) async throws {
        if let core = coreApi() {
            do {
                try await core.deleteMessageForMe(convId: convId, msgId: msgId, cliMsgId: cliMsgId, senderId: senderId)
                return
            } catch { throw RustCore.mapError(error) }
        }
        let isGroup = ZaloWireParser.isGroupId(convId)
        let cleanId = isGroup ? ZaloWireParser.cleanGroupId(convId) : ZaloWireParser.stripUserPrefix(convId)
        let msgDel: [String: Any] = [
            "cliMsgId": cliMsgId.isEmpty ? msgId : cliMsgId,
            "globalMsgId": msgId,
            "ownerId": ZaloWireParser.stripUserPrefix(senderId.isEmpty ? (account?.userId ?? "") : senderId),
            "destId": cleanId
        ]
        var payload: [String: Any] = [
            "cliMsgId": nextClientId(),
            "msgs": [msgDel],
            "onlyMe": 1,
            "imei": imei
        ]
        if isGroup {
            payload["grid"] = cleanId
            _ = try await post(service: "group", path: "/api/group/deletemsg", encryptedPayload: payload)
        } else {
            payload["toid"] = cleanId
            _ = try await post(service: "chat", path: "/api/message/delete", encryptedPayload: payload)
        }
    }

    func sendContactCardAPI(convId: String, cardUid: String, phone: String?) async throws -> SendMessageResult {
        let isGroup = ZaloWireParser.isGroupId(convId)
        let cleanId = isGroup ? ZaloWireParser.cleanGroupId(convId) : ZaloWireParser.stripUserPrefix(convId)
        let cliInt = nextClientId()
        let cliId = "\(cliInt)"
        var payload: [String: Any] = [
            "contactId": ZaloWireParser.stripUserPrefix(cardUid),
            "clientId": cliInt,
            "ttl": 0,
            "imei": imei
        ]
        if let phone, !phone.isEmpty {
            payload["phone"] = phone
        }
        let path: String
        let service: String
        if isGroup {
            payload["grid"] = cleanId
            payload["visibility"] = 0
            service = "group"
            path = "/api/group/contact"
        } else {
            payload["toId"] = cleanId
            service = "chat"
            path = "/api/message/contact"
        }
        let resp = try await post(service: service, path: path, encryptedPayload: payload)
        let d = resp["data"] as? [String: Any] ?? [:]
        let msgId = JSONLossless.string(d["msgId"])
        return SendMessageResult(
            msgId: msgId.isEmpty ? cliId : msgId,
            cliMsgId: cliId,
            tsMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    // MARK: - Uploads (Photos & Files)

    private static func mimeType(forFileName fileName: String) -> String {
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "pdf": return "application/pdf"
        case "txt", "log", "md": return "text/plain"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        default: return "application/octet-stream"
        }
    }

    private static func extractUploadedMsgId(from resp: [String: Any]?) -> String {
        guard let resp else { return "" }
        let d = resp["data"] as? [String: Any]
        let nested = d?["data"] as? [String: Any]
        for dict in [d, nested, resp].compactMap({ $0 }) {
            for key in ["msgId", "globalMsgId", "minGlobalMsgId"] {
                let candidate = JSONLossless.string(dict[key]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty && candidate != "0" {
                    return candidate
                }
            }
        }
        return ""
    }

    func uploadAndSendPhoto(
        convId: String,
        fileName: String,
        data: Data,
        width: Int,
        height: Int
    ) async throws -> UploadedMediaResult {
        let isGroup = ZaloWireParser.isGroupId(convId)
        let cleanId = isGroup ? ZaloWireParser.cleanGroupId(convId) : ZaloWireParser.stripUserPrefix(convId)
        let cliInt = nextClientId()
        let cliId = "\(cliInt)"
        let chunkSize = 1024 * 1024
        let totalChunk = max(1, (data.count + chunkSize - 1) / chunkSize)
        let w = width > 0 ? width : 800
        let h = height > 0 ? height : 600
        let mime = Self.mimeType(forFileName: fileName)
        var uploadDataDict: [String: Any] = [:]

        for chunkIndex in 0..<totalChunk {
            let start = chunkIndex * chunkSize
            let end = min(start + chunkSize, data.count)
            let slice = data.subdata(in: start..<end)
            var encPayload: [String: Any] = [
                "totalChunk": totalChunk,
                "fileName": fileName,
                "clientId": cliInt,
                "totalSize": data.count,
                "imei": imei,
                "isE2EE": 0,
                "jxl": 0,
                "chunkId": chunkIndex + 1
            ]
            if isGroup {
                encPayload["grid"] = cleanId
            } else {
                encPayload["toid"] = cleanId
            }
            let uploadPath = isGroup ? "/api/group/photo_original/upload" : "/api/message/photo_original/upload"
            let resp = try? await postMultipart(
                service: "file",
                path: uploadPath,
                queryParams: ["type": isGroup ? "11" : "2"],
                encryptedPayload: encPayload,
                fieldName: "chunkContent",
                fileName: fileName,
                mimeType: mime,
                chunkData: slice
            )
            if let d = resp?["data"] as? [String: Any],
               !(JSONLossless.string(d["normalUrl"]).isEmpty && JSONLossless.string(d["hdUrl"]).isEmpty && JSONLossless.string(d["oriUrl"]).isEmpty) {
                uploadDataDict = d
            }
        }

        let normalUrl = JSONLossless.string(uploadDataDict["normalUrl"] ?? uploadDataDict["hdUrl"] ?? uploadDataDict["oriUrl"])
        let hdUrl = JSONLossless.string(uploadDataDict["hdUrl"]).isEmpty ? normalUrl : JSONLossless.string(uploadDataDict["hdUrl"])
        let thumbUrl = JSONLossless.string(uploadDataDict["thumbUrl"]).isEmpty ? normalUrl : JSONLossless.string(uploadDataDict["thumbUrl"])
        let photoId = JSONLossless.string(uploadDataDict["photoId"] ?? uploadDataDict["clientFileId"])

        var sendResp: [String: Any]?
        if !photoId.isEmpty && !normalUrl.isEmpty {
            let pidVal: Any = Int64(photoId) ?? photoId
            var sendPayload: [String: Any] = [
                "photoId": pidVal,
                "clientId": cliInt,
                "desc": "",
                "width": w,
                "height": h,
                "rawUrl": normalUrl,
                "hdUrl": hdUrl,
                "thumbUrl": thumbUrl,
                "oriUrl": normalUrl,
                "normalUrl": normalUrl,
                "hdSize": data.count,
                "zsource": -1,
                "ttl": 0,
                "jcp": "{\"convertible\":true}",
                "imei": imei
            ]
            if isGroup {
                sendPayload["grid"] = cleanId
                sendPayload["visibility"] = 0
            } else {
                sendPayload["toid"] = cleanId
            }
            let sendPath = isGroup ? "/api/group/photo_original/send" : "/api/message/photo_original/send"
            sendResp = try? await post(service: "file", path: sendPath, encryptedPayload: sendPayload)
        }

        if sendResp == nil {
            var singleBody: [String: Any] = [
                "clientId": cliInt,
                "desc": "",
                "width": w,
                "height": h,
                "imei": imei
            ]
            if isGroup {
                singleBody["grid"] = cleanId
                singleBody["visibility"] = 0
            } else {
                singleBody["toid"] = cleanId
            }
            let singlePath = isGroup ? "/api/group/sendpt" : "/api/message/photo"
            sendResp = try await postMultipart(
                service: "file",
                path: singlePath,
                queryParams: ["type": isGroup ? "11" : "2"],
                encryptedPayload: singleBody,
                fieldName: "fileContent",
                fileName: fileName,
                mimeType: mime,
                chunkData: data
            )
        }

        let d = sendResp?["data"] as? [String: Any] ?? [:]
        let msgId = Self.extractUploadedMsgId(from: sendResp)
        let finalUrl = hdUrl.isEmpty ? JSONLossless.string(d["hdUrl"] ?? d["normalUrl"] ?? d["url"]) : hdUrl
        return UploadedMediaResult(
            url: finalUrl,
            msgId: msgId.isEmpty ? cliId : msgId,
            cliMsgId: cliId,
            width: w,
            height: h
        )
    }

    private func uploadFileChunks(
        convId: String,
        fileName: String,
        data: Data,
        clientId: Int64,
        isE2EE: Bool,
        webSocket: ZaloWebSocket?
    ) async throws -> (fileId: String, fileUrl: String) {
        let payloadData = Data(data)
        let isGroup = ZaloWireParser.isGroupId(convId)
        let cleanId = isGroup ? ZaloWireParser.cleanGroupId(convId) : ZaloWireParser.stripUserPrefix(convId)
        let chunkSize = 1024 * 1024
        let totalChunk = max(1, (payloadData.count + chunkSize - 1) / chunkSize)
        let mime = Self.mimeType(forFileName: fileName)
        var fileId = ""
        var fileUrl = ""

        for chunkIndex in 0..<totalChunk {
            let start = chunkIndex * chunkSize
            let end = min(start + chunkSize, payloadData.count)
            let slice = payloadData.subdata(in: start..<end)
            var encPayload: [String: Any] = [
                "totalChunk": totalChunk,
                "fileName": fileName,
                "clientId": clientId,
                "totalSize": payloadData.count,
                "imei": imei,
                "isE2EE": isE2EE ? 1 : 0,
                "chunkId": chunkIndex + 1,
            ]
            if isGroup {
                encPayload["grid"] = cleanId
            } else {
                encPayload["toid"] = cleanId
            }
            let uploadPath = isGroup ? "/api/group/asyncfile/upload" : "/api/message/asyncfile/upload"
            let resp = try await postMultipart(
                service: "file",
                path: uploadPath,
                queryParams: ["type": isGroup ? "11" : "2"],
                encryptedPayload: encPayload,
                fieldName: "chunkContent",
                fileName: fileName,
                mimeType: mime,
                chunkData: slice
            )
            if let d = resp["data"] as? [String: Any] {
                let fid = JSONLossless.string(d["fileId"])
                let url = JSONLossless.string(d["fileUrl"] ?? d["url"])
                if !fid.isEmpty { fileId = fid }
                if !url.isEmpty { fileUrl = url }
            }
        }

        if fileUrl.isEmpty, !fileId.isEmpty, let webSocket {
            for _ in 0..<20 where !(await webSocket.isAuthed) {
                try? await Task.sleep(for: .milliseconds(150))
            }
            if await webSocket.isAuthed {
                fileUrl = await webSocket.waitForFileDone(fileId: fileId, timeoutSeconds: 15) ?? ""
            }
        }
        return (fileId, fileUrl)
    }

    func uploadAndSendFile(
        convId: String,
        fileName: String,
        data: Data,
        clientId: Int64? = nil,
        webSocket: ZaloWebSocket? = nil
    ) async throws -> UploadedMediaResult {
        let isGroup = ZaloWireParser.isGroupId(convId)
        let cleanId = isGroup ? ZaloWireParser.cleanGroupId(convId) : ZaloWireParser.stripUserPrefix(convId)
        let cliInt = clientId ?? nextClientId()
        let cliId = "\(cliInt)"
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        let mime = Self.mimeType(forFileName: fileName)
        let checksum = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()

        var fileId = ""
        var fileUrl = ""
        var capturedError: Error?

        do {
            let uploaded = try await uploadFileChunks(
                convId: convId,
                fileName: fileName,
                data: data,
                clientId: cliInt,
                isE2EE: false,
                webSocket: webSocket
            )
            fileId = uploaded.fileId
            fileUrl = uploaded.fileUrl
        } catch let sessionErr as ZaloSessionError {
            if sessionErr.code == -108 || sessionErr.code == -104 || sessionErr.code == 401 {
                throw sessionErr
            }
            capturedError = sessionErr
        } catch {
            capturedError = error
        }

        var sendResp: [String: Any]?
        if !fileId.isEmpty && !fileUrl.isEmpty {
            let msgSpec = Self.buildAsyncFileMsgPayload(
                cleanConvId: cleanId,
                isGroup: isGroup,
                fileId: fileId,
                fileUrl: fileUrl,
                fileName: fileName,
                ext: ext,
                fileSize: data.count,
                checksum: checksum,
                clientId: cliInt,
                imei: imei
            )
            do {
                sendResp = try await post(service: "file", path: msgSpec.path, encryptedPayload: msgSpec.payload)
            } catch let sessionErr as ZaloSessionError {
                if sessionErr.code == -108 || sessionErr.code == -104 || sessionErr.code == 401 {
                    throw sessionErr
                }
                capturedError = sessionErr
            } catch {
                capturedError = error
            }
        }

        if sendResp == nil {
            if data.count <= 10 * 1024 * 1024 {
                var shareBody: [String: Any] = ["clientId": cliId]
                if isGroup { shareBody["grid"] = cleanId } else { shareBody["toid"] = cleanId }
                let sharePath = isGroup ? "/api/group/sharefile_full" : "/api/message/sharefile_full"
                sendResp = try await postMultipart(
                    service: "file",
                    path: sharePath,
                    queryParams: ["type": isGroup ? "11" : "2"],
                    encryptedPayload: shareBody,
                    fieldName: "fileContent",
                    fileName: fileName,
                    mimeType: mime,
                    chunkData: data
                )
            } else if let capturedError {
                throw capturedError
            } else {
                throw ZaloSessionError(code: -1, message: "Tải tệp lên thất bại.", url: "/api/message/asyncfile/upload")
            }
        }

        let d = sendResp?["data"] as? [String: Any] ?? [:]
        let msgId = Self.extractUploadedMsgId(from: sendResp)
        let finalUrl = fileUrl.isEmpty ? JSONLossless.string(d["fileUrl"] ?? d["url"] ?? d["href"]) : fileUrl
        return UploadedMediaResult(
            url: finalUrl,
            msgId: msgId.isEmpty ? cliId : msgId,
            cliMsgId: cliId,
            width: 0,
            height: 0
        )
    }

    func uploadAndSendE2EEFile(
        convId: String,
        fileName: String,
        plaintextData: Data,
        clientId: Int64? = nil,
        e2eeManager: ZaloE2EEManager,
        store: ZaloSQLiteStore?,
        webSocket: ZaloWebSocket
    ) async throws -> UploadedMediaResult {
        guard !ZaloWireParser.isGroupId(convId) else {
            throw ZaloSessionError(code: -1, message: "Chưa hỗ trợ gửi file mã hóa trong nhóm.", url: "/api/e2ee/pc/message/file")
        }
        guard let myUid = account?.userId, !myUid.isEmpty else {
            throw ZaloSessionError(code: -108, message: "Chưa đăng nhập.", url: "/api/e2ee/pc/message/file")
        }
        let ready = await e2eeManager.ensureSessions(
            forPeer: convId,
            myUid: myUid,
            webSocket: webSocket,
            store: store
        )
        guard ready else {
            throw ZaloSessionError(code: -1, message: "Chưa có phiên mã hóa đầu cuối với người nhận.", url: "/api/e2ee/pc/message/file")
        }

        let encrypted = try SecureStream.encryptE2EEFile(plaintextData)
        let cliInt = clientId ?? nextClientId()
        let uploaded = try await uploadFileChunks(
            convId: convId,
            fileName: fileName,
            data: encrypted.ciphertext,
            clientId: cliInt,
            isE2EE: true,
            webSocket: webSocket
        )
        guard !uploaded.fileId.isEmpty, !uploaded.fileUrl.isEmpty else {
            throw ZaloSessionError(code: -1, message: "Không nhận được liên kết tải tệp mã hóa.", url: "/api/message/asyncfile/upload")
        }

        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        let checksum = Insecure.MD5.hash(data: plaintextData).map { String(format: "%02x", $0) }.joined()
        let fileMsgParams = Self.buildFileMsgParamsJSON(
            md5Hex: checksum,
            fileExt: ext,
            fileSize: Int64(plaintextData.count)
        )
        let encryptedDevices = await e2eeManager.encryptFileMessage(
            peerUid: convId,
            myUid: myUid,
            e2eSessionB64: encrypted.base64Session,
            fileMsgParamsJSON: fileMsgParams,
            fileName: fileName,
            store: store
        )
        guard !encryptedDevices.isEmpty else {
            throw ZaloSessionError(code: -1, message: "Không thể mã hóa thông tin tệp đầu cuối.", url: "/api/e2ee/pc/message/file")
        }

        let senderIid = await e2eeManager.localRegistrationId()
        let listParams: [[String: Any]] = encryptedDevices.compactMap { dev in
            guard dev.ciphers.count >= 5 else { return nil }
            return Self.buildE2EEFileListParamEntry(
                toId: dev.toId,
                platform: dev.platform,
                clientId: cliInt,
                imei: imei,
                registrationId: dev.registrationId,
                senderIid: senderIid,
                rawFileUrl: uploaded.fileUrl,
                fileId: uploaded.fileId,
                cipherSession: dev.ciphers[0],
                cipherParams: dev.ciphers[2],
                cipherFileName: dev.ciphers[3],
                cipherThumb: dev.ciphers[4]
            )
        }
        guard !listParams.isEmpty else {
            throw ZaloSessionError(code: -1, message: "Không thể đóng gói tệp mã hóa đầu cuối.", url: "/api/e2ee/pc/message/file")
        }

        let sendResult = try await sendE2EEMessageAPI(
            endpoint: "file",
            threadId: convId,
            isGroup: false,
            clientId: cliInt,
            listParams: ZaloJSONArrayBox(listParams)
        )
        let sep = uploaded.fileUrl.contains("?") ? "&e2esession=" : "?e2esession="
        return UploadedMediaResult(
            url: "\(uploaded.fileUrl)\(sep)\(encrypted.base64Session)",
            msgId: sendResult.msgId,
            cliMsgId: sendResult.cliMsgId,
            width: 0,
            height: 0
        )
    }

    // MARK: - Stickers

    func fetchStickerCategories() async throws -> ZaloJSONArrayBox {
        let builtinPack: [String: Any] = [
            "id": 0,
            "name": "Củ hành",
            "iconUrl": "https://stc-chat.zdn.vn/images/stickers/default/thumb/1.png",
            "total": 30
        ]
        if let cached = cachedStickerCategories, !cached.isEmpty {
            return ZaloJSONArrayBox(cached)
        }

        let resp = try await get(
            service: "sticker",
            path: "/api/message/sticker/category/list/v2",
            rawEncryptedString: ""
        )
        let d = resp["data"] as? [String: Any] ?? [:]
        let exIds = Set((d["exCateIds"] as? [Any] ?? []).compactMap(JSONLossless.int64))
        let dataUrlStr = JSONLossless.string(d["dataUrl"])
            .replacingOccurrences(of: "http://", with: "https://")
        let catalogURLString = dataUrlStr.isEmpty ? "https://zalo-api.zadn.vn/api/emoticon/pcweb/getAllCate" : dataUrlStr

        var packs: [[String: Any]] = [builtinPack]
        if let url = URL(string: catalogURLString),
           let rawBytes = try? await rawDownloadData(url: url, timeout: 20) {
            let plainData: Data = {
                if rawBytes.count >= 2, rawBytes[0] == 0x1F, rawBytes[1] == 0x8B,
                   let inflated = try? ZaloCrypto.inflateZlibOrGzip(rawBytes) {
                    return inflated
                }
                return rawBytes
            }()
            if let arr = (try? JSONSerialization.jsonObject(with: plainData)) as? [[String: Any]] {
                var downloaded: [[String: Any]] = []
                for item in arr {
                    guard let id = JSONLossless.int64(item["id"]), id > 0, !exIds.contains(id) else { continue }
                    let name = JSONLossless.string(item["name"]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if name.isEmpty || name.lowercased().contains("test") { continue }
                    let icon = JSONLossless.string(item["iconUrl"] ?? item["thumbImg"] ?? item["icon"])
                        .replacingOccurrences(of: "http://", with: "https://")
                    let total = JSONLossless.int64(item["totalImage"] ?? item["total"]) ?? 16
                    downloaded.append([
                        "id": Int(id),
                        "name": name,
                        "iconUrl": icon,
                        "total": Int(total)
                    ])
                }
                downloaded.sort { (JSONLossless.int64($0["id"]) ?? 0) > (JSONLossless.int64($1["id"]) ?? 0) }
                packs.append(contentsOf: downloaded)
                if downloaded.count >= 5 {
                    cachedStickerCategories = packs
                }
            }
        }
        return ZaloJSONArrayBox(packs)
    }

    func fetchStickerCategoryDetail(cateId: Int) async throws -> ZaloJSONBox {
        if cateId == 0 {
            let rows: [[String: Any]] = (1...30).map { sid in
                [
                    "id": sid,
                    "cateId": 0,
                    "type": 7,
                    "stickerUrl": "https://stc-chat.zdn.vn/images/stickers/default/thumb/\(sid).png"
                ]
            }
            return ZaloJSONBox(["error_code": 0, "data": rows])
        }
        let resp = try await get(
            service: "sticker",
            path: "/api/message/sticker/category/sticker_detail",
            encryptedPayload: ["cid": "\(cateId)"]
        )
        return ZaloJSONBox(resp)
    }

    func searchStickersAPI(keyword: String, limit: Int = 40) async throws -> ZaloJSONArrayBox {
        let resp = try await get(
            service: "sticker",
            path: "/api/message/sticker/search",
            encryptedPayload: ["keyword": keyword, "limit": limit, "srcType": 0, "imei": imei]
        )
        if let direct = resp["data"] as? [[String: Any]] {
            return ZaloJSONArrayBox(direct)
        }
        let list = ((resp["data"] as? [String: Any])?["stickers"] as? [[String: Any]]) ?? []
        return ZaloJSONArrayBox(list)
    }

    func suggestStickersAPI(keyword: String) async throws -> ZaloJSONArrayBox {
        let resp = try await get(
            service: "sticker",
            path: "/api/message/sticker/suggest/stickers",
            encryptedPayload: ["keyword": keyword, "gif": 1, "guggy": 0, "imei": imei]
        )
        if let d = resp["data"] as? [String: Any] {
            if let sugg = d["sugg_sticker"] as? [[String: Any]], !sugg.isEmpty {
                return ZaloJSONArrayBox(sugg)
            }
            if let stickers = d["stickers"] as? [[String: Any]] {
                return ZaloJSONArrayBox(stickers)
            }
        }
        let direct = resp["data"] as? [[String: Any]] ?? []
        return ZaloJSONArrayBox(direct)
    }

    func sendStickerAPI(convId: String, cateId: Int, stickerId: Int, stickerType: Int = 7) async throws -> SendMessageResult {
        let isGroup = ZaloWireParser.isGroupId(convId)
        let cleanId = isGroup ? ZaloWireParser.cleanGroupId(convId) : ZaloWireParser.stripUserPrefix(convId)
        let cliInt = nextClientId()
        let cliId = "\(cliInt)"
        var payload: [String: Any] = [
            "stickerId": stickerId,
            "cateId": cateId,
            "type": stickerType,
            "clientId": cliInt,
            "zsource": 101,
            "imei": imei,
            "ttl": 0
        ]
        if isGroup {
            payload["grid"] = cleanId
        } else {
            payload["toid"] = cleanId
        }
        let path = isGroup ? "/api/group/sticker" : "/api/message/sticker"
        let service = isGroup ? "group" : "chat"
        let resp = try await post(service: service, path: path, encryptedPayload: payload)
        let d = resp["data"] as? [String: Any] ?? [:]
        let msgId = JSONLossless.string(d["msgId"])
        return SendMessageResult(
            msgId: msgId.isEmpty ? cliId : msgId,
            cliMsgId: cliId,
            tsMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    // MARK: - Groups & Invite Links

    func createGroupAPI(name: String, members: [String]) async throws -> ZaloJSONBox {
        let cleanMembers = members.map(ZaloWireParser.stripUserPrefix).filter { !$0.isEmpty }
        let cliInt = nextClientId()
        let resp = try await get(
            service: "group",
            path: "/api/group/create/v2",
            encryptedPayload: [
                "clientId": cliInt,
                "gname": name,
                "gdesc": NSNull(),
                "members": cleanMembers,
                "nameChanged": 1,
                "createLink": 1,
                "clientLang": "vi",
                "imei": imei,
                "groupType": NSNull()
            ]
        )
        return ZaloJSONBox(resp)
    }

    func fetchGroupLinkDetail(link: String) async throws -> ZaloJSONBox {
        let resp = try await get(
            service: "group",
            path: "/api/group/link/detail",
            encryptedPayload: ["link": link, "avatar_size": 120, "member_avatar_size": 120, "mpage": 1]
        )
        return ZaloJSONBox(resp)
    }

    func joinGroupByLink(link: String) async throws -> ZaloJSONBox {
        let resp = try await get(
            service: "group",
            path: "/api/group/link/join",
            encryptedPayload: ["link": link, "clientId": nextClientId()]
        )
        return ZaloJSONBox(resp)
    }

    // MARK: - Board Pins, Polls, Reminders

    /// 1-1 pins live on `friend_board` (official `getListOneOnOnePinTopics`, cmd 12065); `group_board /api/board/oneone/*`
    /// is the 1-1 *reminder* board, not the pinned bar.
    func fetchBoardPins(convId: String) async throws -> ZaloJSONBox {
        let isGroup = ZaloWireParser.isGroupId(convId)
        if !isGroup {
            let resp = try await get(
                service: "friend_board",
                path: "/api/friendboard/list",
                encryptedPayload: ["conversationId": ZaloWireParser.stripUserPrefix(convId), "version": 0]
            )
            return ZaloJSONBox(ZaloWireParser.friendBoardListBox(resp))
        }
        let grid = ZaloWireParser.cleanGroupId(convId)
        let resp = try await get(
            service: "group_board",
            path: "/api/board/pin/list",
            encryptedPayload: ["groupId": grid, "boardVersion": 0, "imei": imei]
        )
        let d = resp["data"] as? [String: Any] ?? [:]
        let items = (d["topics"] as? [[String: Any]]) ?? (d["items"] as? [[String: Any]]) ?? []
        let ver = JSONLossless.int64(d["boardVersion"] ?? d["version"]) ?? 0
        // Official topic controller keeps `pinLimit` of this response as the board's limit.
        let limit = JSONLossless.int64(d["pinLimit"] ?? d["pin_limit"]) ?? 0
        return ZaloJSONBox(["items": items, "boardVersion": ver, "pinLimit": limit])
    }

    /// Pins a message topic. `params` = `ZaloWireParser.pinTopicParams` (official `getTopicDataFromMessage`).
    /// Group: `group_board /api/board/topic/createv2`; 1-1: `friend_board /api/friendboard/create` (cmd 12067).
    func pinBoardMessage(convId: String, params: [String: Any], boardVersion: Int64 = 0) async throws -> ZaloJSONBox {
        let paramsStr = (try? JSONSerialization.data(withJSONObject: params)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let isGroup = ZaloWireParser.isGroupId(convId)
        if !isGroup {
            let topic: [String: Any] = [
                "type": 2,
                "color": -16_777_216,
                "emoji": "",
                "startTime": -1,
                "duration": -1,
                "params": paramsStr,
                "pinAct": 1,
                "isCreated": true,
                "src": -1
            ]
            let resp = try await get(
                service: "friend_board",
                path: "/api/friendboard/create",
                encryptedPayload: [
                    "conversationId": ZaloWireParser.stripUserPrefix(convId),
                    "topic": topic,
                    "version": boardVersion,
                    "lang": "vi"
                ]
            )
            return ZaloJSONBox(resp)
        }
        let grid = ZaloWireParser.cleanGroupId(convId)
        let resp = try await post(
            service: "group_board",
            path: "/api/board/topic/createv2",
            encryptedPayload: [
                "grid": grid,
                "type": 2,
                "color": -16_777_216,
                "emoji": "",
                "startTime": -1,
                "duration": -1,
                "params": paramsStr,
                "pinAct": 1,
                "repeat": 0,
                "src": -1,
                "imei": imei
            ]
        )
        return ZaloJSONBox(resp)
    }

    /// Group: `group_board /api/board/unpinv2`; 1-1: `friend_board /api/friendboard/multi_unpin` (cmd 12069).
    func unpinBoardTopic(convId: String, topicId: String, rawTopic: ZaloJSONBox? = nil, boardVersion: Int64 = 0) async throws {
        let isGroup = ZaloWireParser.isGroupId(convId)
        if !isGroup {
            _ = try await get(
                service: "friend_board",
                path: "/api/friendboard/multi_unpin",
                encryptedPayload: [
                    "conversationId": ZaloWireParser.stripUserPrefix(convId),
                    "topics": ZaloWireParser.friendBoardUnpinTopics(ref: topicId, rawTopic: rawTopic?.dict),
                    "version": boardVersion,
                    "lang": "vi"
                ]
            )
            return
        }
        let grid = ZaloWireParser.cleanGroupId(convId)
        // Official `unpinBoardItem`: `topic` is {topicId, topicType} (the raw board row gets code 114).
        let topicPayload: [String: Any] = ZaloWireParser.friendBoardUnpinTopics(ref: topicId, rawTopic: rawTopic?.dict)[0]
        _ = try await get(
            service: "group_board",
            path: "/api/board/unpinv2",
            encryptedPayload: [
                "grid": grid,
                "topic": topicPayload,
                "boardVersion": boardVersion,
                "imei": imei
            ]
        )
    }

    func fetchPollDetail(pollId: String) async throws -> ZaloJSONBox {
        let pidVal: Any = Int64(pollId) ?? pollId
        let resp = try await get(
            service: "group_poll",
            path: "/api/poll/detail",
            encryptedPayload: ["poll_id": pidVal, "imei": imei]
        )
        return ZaloJSONBox(resp)
    }

    func createPollAPI(
        convId: String,
        question: String,
        options: [String],
        expiredTimeMs: Int64,
        allowMulti: Bool,
        allowAdd: Bool,
        hideVotePreview: Bool,
        isAnonymous: Bool
    ) async throws -> ZaloJSONBox {
        let grid = ZaloWireParser.cleanGroupId(convId)
        let resp = try await post(
            service: "group_poll",
            path: "/api/poll/create",
            encryptedPayload: [
                "group_id": grid,
                "question": question,
                "options": options,
                "expired_time": expiredTimeMs,
                "allow_multi_choices": allowMulti,
                "allow_add_new_option": allowAdd,
                "is_multi_choice": allowMulti,
                "is_add_new_option": allowAdd,
                "is_hide_vote_preview": hideVotePreview,
                "is_anonymous": isAnonymous,
                "poll_type": 0,
                "src": 1,
                "imei": imei
            ]
        )
        return ZaloJSONBox(resp)
    }

    func votePollAPI(pollId: String, optionIds: [String]) async throws -> ZaloJSONBox {
        let pidVal: Any = Int64(pollId) ?? pollId
        let intIds = optionIds.compactMap { Int64($0) }
        let resp = try await get(
            service: "group_poll",
            path: "/api/poll/vote",
            encryptedPayload: ["poll_id": pidVal, "option_ids": intIds, "imei": imei]
        )
        return ZaloJSONBox(resp)
    }

    func addPollOptionAPI(pollId: String, newOptions: ZaloJSONArrayBox, votedIds: [String] = []) async throws -> ZaloJSONBox {
        let pidVal: Any = Int64(pollId) ?? pollId
        let intVoted = votedIds.compactMap { Int64($0) }
        let resp = try await get(
            service: "group_poll",
            path: "/api/poll/option/add",
            encryptedPayload: [
                "poll_id": pidVal,
                "new_options": newOptions.array,
                "voted_option_ids": intVoted
            ]
        )
        return ZaloJSONBox(resp)
    }

    func lockPollAPI(pollId: String) async throws -> ZaloJSONBox {
        let pidVal: Any = Int64(pollId) ?? pollId
        let resp = try await post(
            service: "group_poll",
            path: "/api/poll/end",
            encryptedPayload: ["poll_id": pidVal, "imei": imei]
        )
        return ZaloJSONBox(resp)
    }

    func sharePollAPI(pollId: String) async throws -> ZaloJSONBox {
        let pidVal: Any = Int64(pollId) ?? pollId
        let resp = try await post(
            service: "group_poll",
            path: "/api/poll/share",
            encryptedPayload: ["poll_id": pidVal, "imei": imei]
        )
        return ZaloJSONBox(resp)
    }

    func createReminderAPI(convId: String, title: String, startTimeMs: Int64, repeatMode: Int, pin: Bool) async throws -> ZaloJSONBox {
        let isGroup = ZaloWireParser.isGroupId(convId)
        let cleanId = isGroup ? ZaloWireParser.cleanGroupId(convId) : ZaloWireParser.stripUserPrefix(convId)
        if !isGroup {
            let objDict: [String: Any] = [
                "toUid": cleanId,
                "type": 0,
                "color": -16_777_216,
                "emoji": "⏰",
                "startTime": startTimeMs,
                "duration": -1,
                "params": ["title": title, "setTitle": true],
                "needPin": false,
                "repeat": repeatMode
            ]
            let objStr = (try? JSONSerialization.data(withJSONObject: objDict)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let resp = try await post(
                service: "group_board",
                path: "/api/board/oneone/create",
                encryptedPayload: ["objectData": objStr, "imei": imei]
            )
            return ZaloJSONBox(resp)
        }
        let paramsStr = (try? JSONSerialization.data(withJSONObject: ["title": title, "setTitle": true])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let resp = try await post(
            service: "group_board",
            path: "/api/board/topic/createv2",
            encryptedPayload: [
                "grid": cleanId,
                "type": 0,
                "color": -16_777_216,
                "emoji": "⏰",
                "startTime": startTimeMs,
                "duration": -1,
                "params": paramsStr,
                "pinAct": pin ? 1 : 2,
                "repeat": repeatMode,
                "src": 1,
                "imei": imei
            ]
        )
        return ZaloJSONBox(resp)
    }

    func fetchReminderDetail(convId: String, reminderId: String) async throws -> ZaloJSONBox {
        let resp = try await get(
            service: "group_board",
            path: "/api/board/topic/getReminder",
            encryptedPayload: ["eventId": reminderId, "imei": imei]
        )
        return ZaloJSONBox(resp)
    }

    func respondReminderAPI(convId: String, reminderId: String, accept: Bool) async throws -> ZaloJSONBox {
        let grid = ZaloWireParser.cleanGroupId(convId)
        let resp = try await post(
            service: "group_board",
            path: "/api/board/topic/updateEventResponse",
            encryptedPayload: [
                "grid": grid,
                "type": accept ? 1 : 2,
                "eventId": reminderId,
                "imei": imei
            ]
        )
        return ZaloJSONBox(resp)
    }

    // MARK: - Voice & Video Call Signalling (`voice_call` / `/api/voicecall/*` + `/api/znoise`)

    func sendVoiceCallSignal(
        command: Int,
        params: ZaloJSONBox
    ) async throws -> (response: ZaloJSONBox, activateApp: Bool) {
        guard let spec = ZaloVoiceCallProtocol.buildSignalRequest(
            command: command,
            params: params.dict,
            imei: imei
        ) else {
            return (ZaloJSONBox(["error_code": -1, "error_message": "unsupported_call_command_\(command)"]), false)
        }
        let resp = try await get(
            service: "voice_call",
            path: spec.path,
            encryptedPayload: spec.payload
        )
        return (ZaloJSONBox(resp), spec.activateApp)
    }

    static func parseNoisedCallIdsResponse(
        _ resp: [String: Any],
        requestedFids: [String],
        requestedGids: [String]
    ) -> (friends: [String: String], groups: [String: String]) {
        let d = (resp["data"] as? [String: Any]) ?? resp
        func decodeMap(_ raw: Any?, requested: [String]) -> [String: String] {
            var map: [String: String] = [:]
            if let dict = raw as? [String: Any] {
                for (k, v) in dict {
                    let s = JSONLossless.string(v).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !k.isEmpty, !s.isEmpty, s != "0" {
                        map[k] = s
                    }
                }
            } else if let arr = raw as? [Any] {
                for (idx, item) in arr.enumerated() where idx < requested.count {
                    let reqKey = requested[idx]
                    let s = JSONLossless.string(item).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !reqKey.isEmpty, !s.isEmpty, s != "0" {
                        map[reqKey] = s
                    }
                }
            }
            return map
        }
        return (
            decodeMap(d["fids"], requested: requestedFids),
            decodeMap(d["gids"], requested: requestedGids)
        )
    }

    func resolveNoisedCallIds(fids: [String], gids: [String]) async -> (friends: [String: String], groups: [String: String]) {
        let cleanFids = fids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let cleanGids = gids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleanFids.isEmpty || !cleanGids.isEmpty else { return ([:], [:]) }

        let encodedFids: [Any] = cleanFids.map { Int64($0).map { $0 as Any } ?? ($0 as Any) }
        let encodedGids: [Any] = cleanGids.map { Int64($0).map { $0 as Any } ?? ($0 as Any) }

        var postPayload: [String: Any] = [:]
        if !encodedFids.isEmpty { postPayload["fids"] = encodedFids }
        if !encodedGids.isEmpty { postPayload["gids"] = encodedGids }

        if let resp = try? await post(
            service: "znoise",
            path: "/api/znoise",
            encryptedPayload: postPayload
        ) {
            let parsed = Self.parseNoisedCallIdsResponse(resp, requestedFids: cleanFids, requestedGids: cleanGids)
            if !parsed.friends.isEmpty || !parsed.groups.isEmpty {
                return parsed
            }
        }

        let getPayload: [String: Any] = ["fids": cleanFids, "gids": cleanGids]
        if let fallbackResp = try? await get(
            service: "profile",
            path: "/api/znoise",
            encryptedPayload: getPayload
        ) {
            return Self.parseNoisedCallIdsResponse(fallbackResp, requestedFids: cleanFids, requestedGids: cleanGids)
        }
        return ([:], [:])
    }
}

enum ZaloVoiceCallProtocol {
    struct SignalRequestSpec: @unchecked Sendable {
        let path: String
        let payload: [String: Any]
        let activateApp: Bool
    }

    private static func compact(_ pairs: [(String, Any?)]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in pairs {
            guard let v, !(v is NSNull) else { continue }
            out[k] = v
        }
        return out
    }

    private static func isTruthyExtendData(_ raw: Any?) -> Bool {
        guard let raw, !(raw is NSNull) else { return false }
        if let s = raw as? String { return !s.isEmpty }
        if let b = raw as? Bool { return b }
        if let d = raw as? [String: Any] { return !d.isEmpty }
        return true
    }

    /// Exact `OU7N.handleSendSignal` + `fBUP` command → endpoint & payload mapping for VNG's `ZaloCall` helper.
    static func buildSignalRequest(command: Int, params n: [String: Any], imei: String) -> SignalRequestSpec? {
        switch command {
        case 401:
            return SignalRequestSpec(
                path: "/api/voicecall/requestcall",
                payload: compact([
                    ("calleeId", n["calleeId"]),
                    ("callId", n["callId"]),
                    ("codec", n["codec"] ?? "[]"),
                    ("typeRequest", n["type"]),
                    ("imei", imei),
                ]),
                activateApp: false
            )
        case 416:
            var pairs: [(String, Any?)] = [
                ("calleeId", n["calleeId"]),
                ("rtcpAddress", n["rtcpAddress"]),
                ("rtpAddress", n["rtpAddress"]),
                ("codec", n["codec"]),
                ("session", n["session"]),
                ("callId", n["callId"]),
                ("imei", imei),
            ]
            if isTruthyExtendData(n["extendData"]) {
                pairs.append(("extendData", n["extendData"]))
                pairs.append(("subCommand", 3))
            }
            return SignalRequestSpec(path: "/api/voicecall/request", payload: compact(pairs), activateApp: false)

        case 407:
            return SignalRequestSpec(
                path: "/api/voicecall/ringring",
                payload: compact([
                    ("callerId", n["callerId"]),
                    ("callId", n["callId"]),
                    ("status", 0),
                    ("imei", imei),
                ]),
                activateApp: false
            )
        case 408:
            return SignalRequestSpec(
                path: "/api/voicecall/answerack",
                payload: compact([
                    ("calleeId", n["calleeId"]),
                    ("callId", n["callId"]),
                    ("status", 0),
                    ("imei", imei),
                ]),
                activateApp: false
            )
        case 402:
            var pairs: [(String, Any?)] = [
                ("callerId", n["callerId"]),
                ("callId", n["callId"]),
                ("status", n["status"]),
                ("codec", n["codec"] ?? ""),
                ("rtcpAddress", n["rtcpAddress"]),
                ("rtpAddress", n["rtpAddress"]),
                ("session_id", n["session"]),
            ]
            if isTruthyExtendData(n["extendData"]) {
                pairs.append(("extendData", n["extendData"]))
                pairs.append(("subCommand", 3))
            }
            return SignalRequestSpec(path: "/api/voicecall/answer", payload: compact(pairs), activateApp: true)

        case 405:
            return SignalRequestSpec(
                path: "/api/voicecall/cancel",
                payload: compact([
                    ("callerId", n["toId"]),
                    ("callId", n["callId"]),
                    ("callType", n["callType"]),
                    ("status", 0),
                    ("imei", imei),
                ]),
                activateApp: false
            )
        case 406:
            return SignalRequestSpec(
                path: "/api/voicecall/logendcall",
                payload: compact([
                    ("call_id", n["callId"]),
                    ("partner_id", n["partnerId"]),
                    ("status", n["status"]),
                    ("logdata", n["data"]),
                    ("duration", n["duration"]),
                    ("role", n["role"]),
                    ("imei", imei),
                ]),
                activateApp: false
            )
        case 409:
            return SignalRequestSpec(
                path: "/api/voicecall/endcall",
                payload: compact([
                    ("uidTo", n["toId"]),
                    ("callId", n["callId"]),
                    ("status", 3),
                    ("imei", imei),
                ]),
                activateApp: false
            )
        case 411:
            return SignalRequestSpec(path: "/api/voicecall/holdreq", payload: compact([("toId", n["toId"])]), activateApp: false)
        case 412:
            return SignalRequestSpec(path: "/api/voicecall/holdresp", payload: compact([("toId", n["toId"])]), activateApp: false)
        case 413:
            return SignalRequestSpec(path: "/api/voicecall/unholdreq", payload: compact([("toId", n["toId"])]), activateApp: false)
        case 414:
            return SignalRequestSpec(path: "/api/voicecall/unholdresp", payload: compact([("toId", n["toId"])]), activateApp: false)

        case 12006:
            return SignalRequestSpec(
                path: "/api/voicecall/conf",
                payload: compact([
                    ("calleeId", n["calleeId"]),
                    ("callId", n["callId"]),
                    ("isOnCam", n["isOnCam"]),
                    ("isOnMic", n["isOnMic"]),
                    ("data", n["data"]),
                ]),
                activateApp: false
            )
        case 12064:
            return SignalRequestSpec(
                path: "/api/voicecall/requestsharescreen",
                payload: compact([
                    ("uidTo", n["uidTo"]),
                    ("callId", n["callId"]),
                    ("status", n["status"]),
                ]),
                activateApp: false
            )
        case 12433:
            return SignalRequestSpec(
                path: "/api/voicecall/group/requestcall",
                payload: compact([
                    ("groupId", n["groupId"]),
                    ("callId", n["callId"]),
                    ("typeRequest", n["typeRequest"]),
                    ("data", n["data"]),
                    ("partners", n["partners"]),
                ]),
                activateApp: false
            )
        case 12434:
            return SignalRequestSpec(
                path: "/api/voicecall/group/request",
                payload: compact([
                    ("calleeId", n["calleeId"]),
                    ("callId", n["callId"]),
                    ("callType", n["callType"]),
                    ("data", n["data"]),
                    ("session", n["session"]),
                    ("partners", n["partners"]),
                    ("groupId", n["groupId"]),
                ]),
                activateApp: false
            )
        case 12435:
            return SignalRequestSpec(
                path: "/api/voicecall/group/adduser",
                payload: compact([
                    ("calleeId", n["calleeId"]),
                    ("callId", n["callId"]),
                    ("callType", n["callType"]),
                    ("hostCall", n["hostCall"]),
                    ("data", n["data"]),
                    ("session", n["session"]),
                    ("partners", n["partners"]),
                ]),
                activateApp: false
            )
        case 12436:
            return SignalRequestSpec(
                path: "/api/voicecall/group/answer",
                payload: compact([
                    ("calleeId", n["calleeId"]),
                    ("callId", n["callId"]),
                    ("callType", n["callType"]),
                    ("hostCall", n["hostCall"]),
                    ("data", n["data"]),
                    ("partners", n["partners"]),
                ]),
                activateApp: true
            )
        case 12437:
            return SignalRequestSpec(
                path: "/api/voicecall/group/cancel",
                payload: compact([
                    ("calleeId", n["calleeId"]),
                    ("callId", n["callId"]),
                    ("callType", n["callType"]),
                    ("hostCall", n["hostCall"]),
                    ("data", n["data"]),
                    ("partners", n["partners"]),
                ]),
                activateApp: false
            )
        case 12438:
            return SignalRequestSpec(
                path: "/api/voicecall/group/endcall",
                payload: compact([
                    ("calleeId", n["calleeId"]),
                    ("callId", n["callId"]),
                    ("callType", n["callType"]),
                    ("hostCall", n["hostCall"]),
                    ("data", n["data"]),
                    ("partners", n["partners"]),
                ]),
                activateApp: false
            )
        case 12439:
            return SignalRequestSpec(
                path: "/api/voicecall/group/ringring",
                payload: compact([
                    ("calleeId", n["calleeId"]),
                    ("callId", n["callId"]),
                    ("callType", n["callType"]),
                    ("hostCall", n["hostCall"]),
                    ("data", n["data"]),
                    ("partners", n["partners"]),
                ]),
                activateApp: false
            )
        case 12445:
            return SignalRequestSpec(
                path: "/api/voicecall/group/state",
                payload: compact([
                    ("callId", n["callId"]),
                    ("hostCall", n["hostCall"]),
                    ("callType", n["callType"]),
                ]),
                activateApp: false
            )
        case 12446:
            return SignalRequestSpec(
                path: "/api/voicecall/group/finish",
                payload: compact([
                    ("callId", n["callId"]),
                    ("callType", n["callType"]),
                    ("data", n["data"]),
                    ("duration", n["duration"]),
                    ("hostCall", n["hostCall"]),
                    ("partners", n["partners"]),
                    ("status", n["status"]),
                    ("joinTime", n["joinTime"]),
                ]),
                activateApp: false
            )
        case 12447:
            return SignalRequestSpec(
                path: "/api/voicecall/group/notify",
                payload: compact([
                    ("callId", n["callId"]),
                    ("hostCall", n["hostCall"]),
                    ("callType", n["callType"]),
                    ("status", n["status"]),
                    ("data", n["data"]),
                ]),
                activateApp: false
            )
        case 12097:
            return SignalRequestSpec(
                path: "/api/voicecall/group/ping",
                payload: compact([
                    ("callId", n["callId"]),
                    ("hostCall", n["hostCall"]),
                    ("userId", n["userId"]),
                    ("callstate", n["callState"]),
                    ("audiostate", n["audioState"]),
                    ("videostate", n["videoState"]),
                    ("params", n["params"]),
                ]),
                activateApp: false
            )
        case 12098:
            return SignalRequestSpec(
                path: "/api/voicecall/group/broadcast",
                payload: compact([
                    ("callId", n["callId"]),
                    ("hostCall", n["hostCall"]),
                    ("userId", n["userId"]),
                    ("callstate", n["callState"]),
                    ("audiostate", n["audioState"]),
                    ("videostate", n["videoState"]),
                    ("params", n["params"]),
                ]),
                activateApp: false
            )
        case 12043:
            return SignalRequestSpec(
                path: "/api/voicecall/group/join",
                payload: compact([
                    ("userId", n["userId"]),
                    ("callId", n["callId"]),
                    ("hostCall", n["hostCall"]),
                    ("status", n["status"]),
                    ("srcJoinCall", n["srcJoinCall"]),
                    ("audiostate", n["audioState"]),
                    ("videostate", n["videoState"]),
                    ("data", n["data"]),
                ]),
                activateApp: false
            )
        case 12044:
            return SignalRequestSpec(
                path: "/api/voicecall/group/sharescreen",
                payload: compact([
                    ("userId", n["userId"]),
                    ("callId", n["callId"]),
                    ("hostCall", n["hostCall"]),
                    ("status", n["status"]),
                    ("audiostate", n["audioState"]),
                    ("videostate", n["videoState"]),
                    ("data", n["data"]),
                ]),
                activateApp: false
            )
        default:
            return nil
        }
    }

    static func buildInitJSON(uid: String, name: String, avatar: String, dataDirectory: URL) -> String {
        let logDir = dataDirectory.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        var sys = utsname()
        uname(&sys)
        let release = withUnsafePointer(to: &sys.release) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        #if arch(arm64)
        let arch = "arm64"
        let cpuDesc = "Apple Silicon;2400"
        #else
        let arch = "x64"
        let cpuDesc = "Intel;2400"
        #endif
        let osInfo = "Darwin_\(release)_darwin_\(arch);\(cpuDesc)"

        let dict: [String: Any] = [
            "type": "update",
            "command": "init",
            "data": [
                "local": [
                    "id": uid,
                    "avatar": avatar,
                    "name": name.isEmpty ? "Người dùng Zalo" : name,
                ],
                "osInfo": osInfo,
                "mainWindowId": uid,
                "logPath": logDir.appendingPathComponent("call.log").path,
                "zrtcLogPath": logDir.appendingPathComponent("zrtc.log").path,
                "dumpPath": logDir.appendingPathComponent("crash.dmp").path,
                "clientVersion": ZaloDomains.zpwVer,
                "language": "vi",
                "timeoutMakeCall2ZRtp": 30_000,
                "enablePreviewDeviceOutgoing": true,
                "enablePreviewDeviceIncall": true,
                "enableUnstableConnecting": true,
                "autoAudioInput": true,
                "autoAudioOutput": true,
                "defaultAudInputDevice": NSNull(),
                "defaultAudOutputDevice": NSNull(),
                "defaultVidDevice": NSNull(),
                "receiveCallWhileNoMicrophoneDetected": true,
                "receiveCallWhileNoSpeakerDetected": true,
            ] as [String: Any],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    static func buildMakeCallJSON(
        partners: [(id: String, name: String, avatar: String)],
        video: Bool,
        groupInfo: (id: String, name: String, avatar: String, maxUsers: Int)? = nil
    ) -> String {
        let partnerList: [[String: Any]] = partners.map { p in
            [
                "id": ZaloWireParser.stripUserPrefix(p.id),
                "avatar": p.avatar,
                "name": p.name.isEmpty ? "Người dùng Zalo" : p.name,
            ]
        }
        let callType: Int = {
            if groupInfo != nil {
                return video ? 6 : 5
            }
            return video ? 3 : 1
        }()
        var dataDict: [String: Any] = [
            "partner": partnerList,
            "type": callType,
        ]
        if let g = groupInfo {
            dataDict["groupInfo"] = [
                "id": ZaloWireParser.cleanGroupId(g.id),
                "name": g.name.isEmpty ? "Nhóm" : g.name,
                "avatar": g.avatar,
                "maxUsers": max(2, g.maxUsers),
            ]
        }
        let root: [String: Any] = [
            "type": "request",
            "command": "makeCall",
            "data": dataDict,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    static func buildRecvSignalJSON(command: Int, data: Any?) -> String {
        var root: [String: Any] = [
            "type": "recvSignal",
            "command": command,
        ]
        if let data, !(data is NSNull) {
            root["data"] = data
        }
        guard let raw = try? JSONSerialization.data(withJSONObject: root),
              let json = String(data: raw, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    static func buildControlJSON(voipPayload: [String: Any]) -> String {
        let root: [String: Any] = [
            "type": "control",
            "data": voipPayload,
        ]
        guard let raw = try? JSONSerialization.data(withJSONObject: root),
              let json = String(data: raw, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}

/// One history answer. Rust path: the core keeps the parsed body (`HistoryBatch`) and Swift reads the paging head and the
/// typed events from it, never a JSON dictionary (`box` re-materialises one only for callers that need raw fields).
/// Swift path: wraps the dictionary.
struct ZaloHistoryPage: @unchecked Sendable {
    let hasMore: Bool
    let isOld: Bool
    let lastMsgId: String
    /// Sender / quote-owner uids a parse looks contact names up for (Rust path only).
    let uids: [String]
    let rustBatch: HistoryBatch?
    private let swiftBox: ZaloJSONBox?

    init(record: HistoryRecord) {
        hasMore = record.hasMore
        isOld = record.isOld
        lastMsgId = record.lastMsgId
        uids = record.uids
        rustBatch = record.batch
        swiftBox = nil
    }

    init(box: ZaloJSONBox) {
        let data = box.dict["data"] as? [String: Any]
        func flag(_ v: Any?) -> Bool { JSONLossless.int64(v) == 1 || (v as? Bool) == true }
        hasMore = flag(data?["hasMore"])
        isOld = flag(data?["isOld"])
        lastMsgId = JSONLossless.string(data?["lastMsgId"])
        uids = []
        rustBatch = nil
        swiftBox = box
    }

    /// The raw answer (`{error_code, data}`); on the Rust path this crosses the bridge as JSON, so use it sparingly.
    var box: ZaloJSONBox {
        if let swiftBox { return swiftBox }
        guard let rustBatch else { return ZaloJSONBox() }
        return ZaloJSONBox(RustCore.object(rustBatch.rawJson()))
    }
}
