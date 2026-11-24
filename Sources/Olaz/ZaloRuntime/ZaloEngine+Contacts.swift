import Foundation

// Friends, groups, friend requests, add friend. Bridged to `HostScripts/contacts-adapter.js`
// (`window.__zaloContacts`; posts {page:'main', contacts:{…}} — each key replaces that section).
// Every action runs through the official client's own services (see the adapter header).

struct ContactsState: Equatable {
    struct Friend: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let zaloName: String
        let avatar: URL?
        /// Last activity reported by the official profile, nil when unknown.
        let lastActive: Date?
        let online: Bool
        /// Upper-case Latin initial used for the alphabetical sections ("#" when not a letter).
        let section: String
        /// Diacritic-folded lowercase name for sorting and searching.
        let sortKey: String
    }

    struct Group: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let avatar: URL?
        let members: Int
        let sortKey: String
    }

    struct FriendRequest: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let avatar: URL?
        let message: String
        /// nil when the official client has no timestamp for the request.
        let date: Date?
    }

    struct FoundUser: Equatable, Sendable {
        let id: String
        let name: String
        let zaloName: String
        let avatar: URL?
        let bio: String
        let isFriend: Bool
        let isSelf: Bool
        /// I already sent this person a request.
        var requested: Bool
        /// This person already sent me a request.
        let requesting: Bool
        /// Official default greeting for "find by phone" (editable by the user).
        let defaultMessage: String
        let maxMessage: Int
    }

    struct Search: Equatable, Sendable {
        enum Status: String, Sendable { case idle, searching, found, error }
        var status: Status = .idle
        var error: String?
        var user: FoundUser?
    }

    /// Result of the latest accept / decline / cancel / send action.
    struct Notice: Equatable, Sendable {
        let seq: Int
        let ok: Bool
        let text: String
    }

    var friends: [Friend] = []
    var groups: [Group] = []
    var received: [FriendRequest] = []
    var sent: [FriendRequest] = []
    /// Pending received friend requests (rail badge).
    var pendingRequestCount = 0
    var loadingRequests = false
    var search = Search()
    var notice: Notice?
    /// True once the official friend list has been read at least once.
    var friendsLoaded = false
    var groupsLoaded = false
}

extension ZaloEngine {
    // MARK: Actions

    func refreshContacts() {
        Task { [weak self] in
            await self?.performContactsSync()
        }
    }

    func performContactsSync() async {
        contacts.loadingRequests = true
        defer { self.contacts.loadingRequests = false }

        async let friendsResp = try? sessionClient.fetchFriends(page: 1, count: 20000)
        async let groupsResp = try? sessionClient.fetchGroupsList()
        async let sentResp = try? sessionClient.fetchSentFriendRequests()
        async let receivedResp = try? sessionClient.fetchReceivedFriendRequests()

        let (fBox, gBox, sBox, rBox) = await (friendsResp, groupsResp, sentResp, receivedResp)
        var next = contacts

        if let fBox {
            var mappedFriends: [ContactsState.Friend] = []
            var friendGlobalMap: [String: String] = [:]
            for row in fBox.array {
                let uid = ZaloWireParser.stripUserPrefix(JSONLossless.string(row["userId"] ?? row["uid"] ?? row["id"]))
                guard !uid.isEmpty else { continue }
                let globalId = JSONLossless.string(row["globalId"])
                if !globalId.isEmpty {
                    friendGlobalMap[uid] = globalId
                }
                let display = ZaloWireParser.preferredName(row)
                let zaloName = JSONLossless.string(row["zaloName"])
                let avt = JSONLossless.string(row["avatar"] ?? row["avt"])
                let lastAct = (JSONLossless.int64(row["lastActionTime"]).map(Double.init)) ?? 0
                let norm: [String: Any] = [
                    "id": uid,
                    "name": display.isEmpty ? zaloName : display,
                    "zaloName": zaloName,
                    "avatar": avt,
                    "lastActive": lastAct,
                    "online": (JSONLossless.int64(row["isActivePC"]) == 1) || (row["online"] as? Bool == true)
                ]
                if let friend = Self.contactFriend(norm) {
                    mappedFriends.append(friend)
                }
            }
            if !friendGlobalMap.isEmpty {
                cachedFriendGlobalIds.merge(friendGlobalMap) { _, new in new }
            }
            next.friends = mappedFriends.sorted {
                if $0.section != $1.section {
                    if $0.section == "#" { return false }
                    if $1.section == "#" { return true }
                    return $0.section < $1.section
                }
                return $0.sortKey.localizedStandardCompare($1.sortKey) == .orderedAscending
            }
            next.friendsLoaded = true
        }

        if let gBox {
            let infoMap = (gBox.dict["gridInfoMap"] as? [String: Any]) ?? [:]
            var mappedGroups: [ContactsState.Group] = []
            var groupDetailCache: [String: [String: Any]] = [:]
            for (rawId, rawInfo) in infoMap {
                guard let info = rawInfo as? [String: Any] else { continue }
                let cleanId = ZaloWireParser.cleanGroupId(rawId)
                guard !cleanId.isEmpty else { continue }
                groupDetailCache[cleanId] = info
                let convId = ZaloWireParser.groupConvId(cleanId)
                let name = JSONLossless.string(info["name"])
                let avt = JSONLossless.string(info["avt"] ?? info["fullAvt"])
                let members = Int(JSONLossless.int64(info["totalMember"] ?? info["total"])
                    ?? Int64((info["memVerList"] as? [Any])?.count ?? (info["memIds"] as? [Any])?.count ?? 0))
                if let grp = Self.contactGroup([
                    "id": convId,
                    "name": name,
                    "avatar": avt,
                    "members": members
                ]) {
                    mappedGroups.append(grp)
                }
            }
            cachedGroupDetails = groupDetailCache
            next.groups = mappedGroups.sorted { $0.sortKey.localizedStandardCompare($1.sortKey) == .orderedAscending }
            next.groupsLoaded = true
        }

        if let rBox {
            cachedReceivedRequestsRaw = rBox.array
            next.received = rBox.array.compactMap { row -> ContactsState.FriendRequest? in
                let uid = ZaloWireParser.stripUserPrefix(JSONLossless.string(row["userId"] ?? row["uid"] ?? row["fromUid"]))
                guard !uid.isEmpty else { return nil }
                return Self.contactRequest([
                    "id": uid,
                    "name": JSONLossless.string(row["displayName"] ?? row["zaloName"]),
                    "avatar": JSONLossless.string(row["avatar"] ?? row["avt"]),
                    "message": JSONLossless.string(row["message"] ?? row["msg"]),
                    "time": JSONLossless.int64(row["time"] ?? row["ts"]) ?? 0
                ])
            }
            next.pendingRequestCount = next.received.count
        }

        if let sBox {
            cachedSentRequestsRaw = sBox.array
            next.sent = sBox.array.compactMap { row -> ContactsState.FriendRequest? in
                let uid = ZaloWireParser.stripUserPrefix(JSONLossless.string(row["userId"] ?? row["uid"] ?? row["toUid"]))
                guard !uid.isEmpty else { return nil }
                return Self.contactRequest([
                    "id": uid,
                    "name": JSONLossless.string(row["displayName"] ?? row["zaloName"]),
                    "avatar": JSONLossless.string(row["avatar"] ?? row["avt"]),
                    "message": JSONLossless.string(row["message"] ?? row["msg"]),
                    "time": JSONLossless.int64(row["time"] ?? row["ts"]) ?? 0
                ])
            }
        }

        if next != contacts { contacts = next }
        if let openId = openConversationId {
            updateCallGateForConversation(openId)
        }
        ensureKnownContactsInConversations()
        rebuildConversationFlags()
        rebuildConversationExtras()
        refreshReactionNames()
    }

    func acceptFriendRequest(_ id: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await sessionClient.acceptFriendRequestAPI(uid: id)
                bumpContactsNotice(ok: true, text: "Đã chấp nhận lời mời kết bạn.")
                refreshContacts()
            } catch {
                bumpContactsNotice(ok: false, text: "Không thể chấp nhận lời mời.")
            }
        }
    }

    func declineFriendRequest(_ id: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await sessionClient.rejectFriendRequestAPI(uid: id)
                contacts.received.removeAll { $0.id == id }
                contacts.pendingRequestCount = contacts.received.count
                bumpContactsNotice(ok: true, text: "Đã từ chối lời mời kết bạn.")
            } catch {
                bumpContactsNotice(ok: false, text: "Không thể từ chối lời mời.")
            }
        }
    }

    func cancelFriendRequest(_ id: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await sessionClient.cancelFriendRequestAPI(uid: id)
                contacts.sent.removeAll { $0.id == id }
                bumpContactsNotice(ok: true, text: "Đã thu hồi lời mời kết bạn.")
            } catch {
                bumpContactsNotice(ok: false, text: "Không thể thu hồi lời mời.")
            }
        }
    }

    func findFriend(byPhone phone: String) {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        contacts.search = ContactsState.Search(status: .searching)
        Task { [weak self] in
            guard let self else { return }
            do {
                let resp = try await sessionClient.searchFriendByPhone(trimmed)
                let d = (resp.dict["data"] as? [String: Any]) ?? resp.dict
                let uid = ZaloWireParser.stripUserPrefix(JSONLossless.string(d["uid"] ?? d["userId"]))
                guard !uid.isEmpty else {
                    contacts.search = ContactsState.Search(status: .error, error: "Không tìm thấy người dùng với số điện thoại này.")
                    return
                }
                let isSelf = uid == profile?.userId
                let isFriend = contacts.friends.contains(where: { $0.id == uid })
                let requested = contacts.sent.contains(where: { $0.id == uid })
                let requesting = contacts.received.contains(where: { $0.id == uid })
                let myName = profile?.displayName ?? "tôi"
                let found = Self.contactSearch([
                    "status": "found",
                    "user": [
                        "id": uid,
                        "name": JSONLossless.string(d["display_name"] ?? d["displayName"] ?? d["zalo_name"]),
                        "zaloName": JSONLossless.string(d["zalo_name"] ?? d["zaloName"]),
                        "avatar": JSONLossless.string(d["avatar"]),
                        "bio": JSONLossless.string(d["status"]),
                        "isFriend": isFriend,
                        "isSelf": isSelf,
                        "requested": requested,
                        "requesting": requesting,
                        "defaultMessage": "Xin chào, mình là \(myName).",
                        "maxMessage": 150
                    ]
                ])
                contacts.search = found
            } catch {
                contacts.search = ContactsState.Search(status: .error, error: error.localizedDescription)
            }
        }
    }

    func resetFriendSearch() {
        if contacts.search != ContactsState.Search() { contacts.search = ContactsState.Search() }
    }

    func sendFriendRequest(to id: String, message: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await sessionClient.sendFriendRequestAPI(toUid: id, message: message)
                bumpContactsNotice(ok: true, text: "Đã gửi lời mời kết bạn.")
                refreshContacts()
            } catch {
                bumpContactsNotice(ok: false, text: "Không thể gửi lời mời kết bạn.")
            }
        }
    }

    /// Opens the 1-1 or group conversation with `id` (the shell observes `navigationRequest`).
    func openContactConversation(_ id: String) { navigationRequest = id }

    private func bumpContactsNotice(ok: Bool, text: String) {
        let nextSeq = (contacts.notice?.seq ?? 0) + 1
        contacts.notice = ContactsState.Notice(seq: nextSeq, ok: ok, text: text)
    }

    // MARK: State

    func handleContacts(state: [String: Any]) {
        guard let json = state["contacts"] as? [String: Any] else { return }
        var next = contacts
        if let rows = json["friends"] as? [[String: Any]] {
            next.friends = rows.compactMap(Self.contactFriend)
            next.friendsLoaded = true
        }
        if let rows = json["groups"] as? [[String: Any]] {
            next.groups = rows.compactMap(Self.contactGroup)
            next.groupsLoaded = true
        }
        if let rows = json["received"] as? [[String: Any]] { next.received = rows.compactMap(Self.contactRequest) }
        if let rows = json["sent"] as? [[String: Any]] { next.sent = rows.compactMap(Self.contactRequest) }
        if let count = (json["pendingRequestCount"] as? NSNumber)?.intValue { next.pendingRequestCount = max(0, count) }
        if let loading = json["loading"] as? [String: Any], let flag = loading["requests"] as? Bool { next.loadingRequests = flag }
        if let search = json["search"] as? [String: Any] { next.search = Self.contactSearch(search) }
        if let notice = json["notice"] as? [String: Any], let seq = (notice["seq"] as? NSNumber)?.intValue {
            next.notice = ContactsState.Notice(seq: seq, ok: notice["ok"] as? Bool ?? false, text: notice["text"] as? String ?? "")
        }
        if next != contacts { contacts = next }
    }

    /// Lower-cased, diacritic-folded text (Vietnamese đ/Đ included) for searching and sorting.
    nonisolated static func contactFold(_ text: String) -> String {
        text.replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "D")
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "vi"))
            .lowercased()
    }

    private static func url(_ value: Any?) -> URL? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return URL(string: text)
    }

    private static func contactFriend(_ json: [String: Any]) -> ContactsState.Friend? {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (json["zaloName"] as? String) ?? ""
        let key = contactFold(name).trimmingCharacters(in: .whitespacesAndNewlines)
        let first = key.first.map { String($0).uppercased() } ?? "#"
        let section = first.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) } ? first : "#"
        let last = (json["lastActive"] as? NSNumber)?.doubleValue ?? 0
        return ContactsState.Friend(
            id: id, name: name, zaloName: json["zaloName"] as? String ?? "",
            avatar: url(json["avatar"]),
            lastActive: last > 0 ? Date(timeIntervalSince1970: last / 1000) : nil,
            online: json["online"] as? Bool ?? false,
            section: section, sortKey: key
        )
    }

    private static func contactGroup(_ json: [String: Any]) -> ContactsState.Group? {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        let name = json["name"] as? String ?? ""
        return ContactsState.Group(
            id: id, name: name, avatar: url(json["avatar"]),
            members: (json["members"] as? NSNumber)?.intValue ?? 0,
            sortKey: contactFold(name)
        )
    }

    private static func contactRequest(_ json: [String: Any]) -> ContactsState.FriendRequest? {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        let time = (json["time"] as? NSNumber)?.doubleValue ?? 0
        return ContactsState.FriendRequest(
            id: id, name: json["name"] as? String ?? "", avatar: url(json["avatar"]),
            message: json["message"] as? String ?? "",
            date: time > 0 ? Date(timeIntervalSince1970: time / 1000) : nil
        )
    }

    private static func contactSearch(_ json: [String: Any]) -> ContactsState.Search {
        let status = ContactsState.Search.Status(rawValue: json["status"] as? String ?? "") ?? .idle
        var search = ContactsState.Search(status: status, error: json["error"] as? String, user: nil)
        if let u = json["user"] as? [String: Any], let id = u["id"] as? String, !id.isEmpty {
            search.user = ContactsState.FoundUser(
                id: id, name: u["name"] as? String ?? "", zaloName: u["zaloName"] as? String ?? "",
                avatar: url(u["avatar"]), bio: u["bio"] as? String ?? "",
                isFriend: u["isFriend"] as? Bool ?? false, isSelf: u["isSelf"] as? Bool ?? false,
                requested: u["requested"] as? Bool ?? false, requesting: u["requesting"] as? Bool ?? false,
                defaultMessage: u["defaultMessage"] as? String ?? "",
                maxMessage: (u["maxMessage"] as? NSNumber)?.intValue ?? 150
            )
        }
        return search
    }
}

extension ZaloEngine {
    /// Name an @mention of `uid` shows (official `getMemberFriendlyName` -> `getDName`: alias, else the Zalo name);
    /// nil keeps the text as sent (me, everyone, or nobody known).
    func mentionDisplayName(_ uid: String) -> String? {
        let clean = ZaloWireParser.stripUserPrefix(uid)
        guard !clean.isEmpty, clean != "-1", clean != ZaloWireParser.stripUserPrefix(profile?.userId ?? ""),
              let name = lookupPersonInfo(clean)?.name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, name != clean, name != "Bạn", name != ReactionDetail.unknownName else { return nil }
        return name
    }
}
