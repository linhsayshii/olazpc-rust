import AppKit
import ImageIO
import UniformTypeIdentifiers

// "Tạo nhóm": the official group compose (modal CREATE_GROUP_COMPOSE) as a native sheet, `Views/CreateGroupSheet.swift`. The picker
// list, the selection rules and the group photo are built here from what the engine already has, the way the official picker builds
// them; creating goes through `HostScripts/group-create-adapter.js` (`window.__zaloGroupCreate`), which runs the official quota check,
// `createGroupV2`, the open of the new conversation, its summary messages and the avatar upload (see the adapter header).

/// Asks the shell to show the compose sheet, with the people already picked (the 1:1 inspector's "Tạo nhóm" starts with that friend).
struct GroupComposeRequest: Identifiable, Equatable {
    let id = UUID()
    var members: [String] = []
}

/// Limits of the official compose (`info()`): `settings.group.max_member`, `group_config`, and the blocked friends.
struct GroupCreateLimits: Equatable, Sendable {
    var maxMembers = 100
    var maxNameLength = 50
    /// `group_config.group_name_regex` (JavaScript source): a name it matches is refused (STR_GROUP_NAME_INVALID).
    var namePattern = "`|~|!|@|#|%|\\*|\\^|\\$"
    var blocked: Set<String> = []
    /// Friends that are official accounts (`isOAType`): never among the recent chats.
    var officialAccounts: Set<String> = []

    init() {}

    init?(json: Any?) {
        guard let root = json as? [String: Any], root["status"] as? String == "ok" else { return nil }
        if let max = (root["maxMembers"] as? NSNumber)?.intValue, max > 0 { maxMembers = max }
        if let length = (root["maxNameLength"] as? NSNumber)?.intValue, length > 0 { maxNameLength = length }
        if let pattern = root["nameRegex"] as? String, !pattern.isEmpty { namePattern = pattern }
        blocked = Set((root["blocked"] as? [Any] ?? []).compactMap { $0 as? String })
        officialAccounts = Set((root["officialAccounts"] as? [Any] ?? []).compactMap { $0 as? String })
    }

    /// The compose's `onChangeGroupName` check. A pattern NSRegularExpression cannot read lets the name through: the renderer checks again.
    func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, let regex = try? NSRegularExpression(pattern: namePattern) else { return true }
        return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) == nil
    }

    /// The name field's `maxLength` (UTF-16 units, like the HTML input).
    func clampedName(_ name: String) -> String {
        guard name.utf16.count > maxNameLength else { return name }
        var result = ""
        for character in name {
            if result.utf16.count + String(character).utf16.count > maxNameLength { break }
            result.append(character)
        }
        return result
    }

    /// STR_MAX_MEM_TOAST.
    var overLimitText: String { "Bạn chỉ có thể tạo nhóm với \(maxMembers) người khác" }
    static let blockedText = "Bỏ chặn để thêm người này"            // STR_UNBLOCK_TO_ADD_TO_GROUP
    static let invalidNameText = "Tên nhóm chứa ký tự không hợp lệ. Vui lòng thử lại."   // STR_GROUP_NAME_INVALID
}

/// The people the compose lists (official member picker `W`): "Trò chuyện gần đây" = the 5 latest 1:1 conversations with friends that
/// are not official accounts, then every friend by name. Hidden chats and My Cloud never show up.
struct GroupComposeRoster: Equatable {
    struct Person: Identifiable, Equatable {
        let id: String
        let name: String
        let avatar: URL?
        let section: String
        let sortKey: String
        /// Folded Zalo name (search matches it too, like the friends list).
        let zaloKey: String
    }

    static let recentLimit = 5
    var recent: [Person] = []
    var friends: [Person] = []

    init(friends source: [ContactsState.Friend], conversations: [ZaloEngine.ConversationSummary], selfId: String?,
         officialAccounts: Set<String> = []) {
        let people = source.map(Self.person(_:))
        let byId = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Same order as the friends list: letters A–Z, "#" last, names in a section by their folded form.
        friends = people.sorted { lhs, rhs in
            if lhs.section != rhs.section {
                if lhs.section == "#" { return false }
                if rhs.section == "#" { return true }
                return lhs.section < rhs.section
            }
            return lhs.sortKey.localizedStandardCompare(rhs.sortKey) == .orderedAscending
        }
        let latest = conversations.filter { !$0.isGroup && $0.id != selfId && byId[$0.id] != nil && !officialAccounts.contains($0.id) }
            .sorted { ($0.preview?.date ?? .distantPast) > ($1.preview?.date ?? .distantPast) }
        recent = latest.prefix(Self.recentLimit).compactMap { byId[$0.id] }
    }

    func person(_ id: String) -> Person? { friends.first { $0.id == id } }

    /// A friend the list leaves out (hidden chat), for the chip of a pick handed in by the caller.
    static func person(_ id: String, in friends: [ContactsState.Friend]) -> Person? {
        friends.first { $0.id == id }.map(person(_:))
    }

    private static func person(_ friend: ContactsState.Friend) -> Person {
        Person(id: friend.id, name: friend.name.isEmpty ? "Người dùng Zalo" : friend.name, avatar: friend.avatar, section: friend.section,
               sortKey: friend.sortKey, zaloKey: ZaloEngine.contactFold(friend.zaloName))
    }

    /// Friends whose name contains `query` (case, diacritics and đ folded).
    func matching(_ query: String) -> [Person] {
        let needle = ZaloEngine.contactFold(query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return friends }
        return friends.filter { $0.sortKey.contains(needle) || $0.zaloKey.contains(needle) }
    }

    /// Alphabetical sections of `friends` (the picker's letter titles).
    var sections: [(title: String, people: [Person])] {
        var result: [(title: String, people: [Person])] = []
        for person in friends {
            if result.last?.title == person.section { result[result.count - 1].people.append(person) } else { result.append((person.section, [person])) }
        }
        return result
    }
}

/// The picks of the compose (`onItemClick`): blocked friends and picks beyond the limit are refused; 2 picks enable "Tạo nhóm".
struct GroupComposeSelection: Equatable {
    enum Change: Equatable { case added, removed, overLimit, blocked }
    private(set) var ids: [String] = []

    init(_ ids: [String] = []) { self.ids = ids }

    var canConfirm: Bool { ids.count > 1 }
    func contains(_ id: String) -> Bool { ids.contains(id) }

    @discardableResult
    mutating func toggle(_ id: String, limits: GroupCreateLimits) -> Change {
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
            return .removed
        }
        if limits.blocked.contains(id) { return .blocked }
        if ids.count >= limits.maxMembers { return .overLimit }
        ids.append(id)
        return .added
    }

    /// Drops picks that are no longer allowed (blocked meanwhile, unfriended, hidden).
    mutating func keep(where allowed: (String) -> Bool) { ids.removeAll { !allowed($0) } }
}

/// The group photo: centre square of the picked image, JPEG. Like the official avatar picker, the picked FILE must be 7 KB – 30 MB
/// (`update_avatar.min_size_kb` / `max_local_size`) and the image at least 240×240 (`min_width/min_height`); the upload takes up to
/// 1 MB for a group (`limit_size_group`).
struct GroupAvatarImage: Equatable {
    let jpeg: Data
    let side: Int

    static let minSide = 240
    static let maxSide = 1024
    /// Picked file size bounds (official `min_size_kb` × 1024, `max_local_size` × 10⁶).
    static let minFileBytes = 7 * 1024
    static let maxFileBytes = 30_000_000
    /// Upload size limit of a group avatar.
    static let maxBytes = 1024 * 1024
    static let tooSmallText = "Ảnh đại diện quá nhỏ. Kích thước tối thiểu là 240 x 240."      // update_avatar.min_dimension_error
    static let tooLightText = "Ảnh đại diện quá nhỏ. Dung lượng tối thiểu là 7 KB."           // update_avatar.min_size_error
    static let tooHeavyText = "Đã có lỗi xảy ra. Vui lòng sử dụng ảnh khác hoặc thử lại sau"  // STR_TOAST_UPLOAD_FAILED
    static let unreadableText = "Không đọc được ảnh này. Hãy chọn một ảnh khác."

    var image: NSImage? { NSImage(data: jpeg) }
    var base64: String { jpeg.base64EncodedString() }

    /// Reads `url` (EXIF orientation applied), crops the centre square and encodes it, or says why it cannot be used.
    static func make(from url: URL) -> Result<GroupAvatarImage, AvatarError> {
        guard let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return .failure(.unreadable) }
        if bytes < minFileBytes { return .failure(.tooLight) }
        if bytes >= maxFileBytes { return .failure(.tooHeavy) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, width > 0, height > 0
        else { return .failure(.unreadable) }
        let short = min(width, height), long = max(width, height)
        guard short >= minSide else { return .failure(.tooSmall) }
        // Decode no larger than needed for a `maxSide` square (the thumbnail API also applies the EXIF orientation).
        let scale = min(1, Double(maxSide) / Double(short))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(minSide, Int((Double(long) * scale).rounded(.up))),
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return .failure(.unreadable) }
        return make(from: decoded)
    }

    static func make(from image: CGImage) -> Result<GroupAvatarImage, AvatarError> {
        let short = min(image.width, image.height)
        guard short >= minSide else { return .failure(.tooSmall) }
        let crop = CGRect(x: (image.width - short) / 2, y: (image.height - short) / 2, width: short, height: short)
        guard let square = image.cropping(to: crop) else { return .failure(.unreadable) }
        let side = min(short, maxSide)
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return .failure(.unreadable) }
        // JPEG has no alpha: transparent parts become white, as on a light avatar background.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let scaled = context.makeImage() else { return .failure(.unreadable) }
        var quality = 0.9
        var data = jpeg(scaled, quality: quality)
        while let bytes = data, bytes.count > maxBytes, quality > 0.45 {
            quality -= 0.15
            data = jpeg(scaled, quality: quality)
        }
        guard let result = data, result.count <= maxBytes else { return .failure(.unreadable) }
        return .success(GroupAvatarImage(jpeg: result, side: side))
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    enum AvatarError: Error, Equatable {
        case unreadable, tooSmall, tooLight, tooHeavy

        var text: String {
            switch self {
            case .unreadable: GroupAvatarImage.unreadableText
            case .tooSmall: GroupAvatarImage.tooSmallText
            case .tooLight: GroupAvatarImage.tooLightText
            case .tooHeavy: GroupAvatarImage.tooHeavyText
            }
        }
    }
}

/// Answer of group-create-adapter.js `create()`.
enum GroupCreateOutcome: Equatable {
    /// `failed`: picked members the server did not add (its `errorInfo`).
    case created(id: String, failed: [String])
    /// The same group already existed (STR_GROUP_EXISTS); it is opened.
    case exists(id: String, text: String)
    /// Refused before anything was sent (too few members, invalid name…): the sheet stays to fix it. `dropped`: picks that can no
    /// longer be added (blocked, not a friend any more), to be unpicked.
    case invalid(String, dropped: [String] = [])
    /// Refused by the quota check or the server. `title` set: shown as a confirm instead of a note. `closes`: the official compose
    /// closes after it (quota check failures).
    case failed(title: String?, message: String, closes: Bool = false)
    /// No answer in time: the group may still be created, so nothing invites a retry.
    case pending(String)

    static let defaultFailure = "Tạo nhóm không thành công."              // STR_CREATE_GROUP_FAIL
    static let notReadyText = "Ứng dụng chưa sẵn sàng, hãy thử lại sau giây lát."
    static let noAnswerText = "Chưa nhận được phản hồi. Hãy kiểm tra danh sách hội thoại trước khi thử lại."

    init(json: Any?) {
        guard let root = json as? [String: Any], let status = root["status"] as? String else {
            self = .failed(title: nil, message: Self.defaultFailure)
            return
        }
        let text = (root["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let id = root["convId"] as? String ?? ""
        switch status {
        case "created" where !id.isEmpty:
            self = .created(id: id, failed: (root["failed"] as? [Any] ?? []).compactMap { $0 as? String })
        case "exists" where !id.isEmpty:
            self = .exists(id: id, text: text ?? "Nhóm bạn vừa tạo đã tồn tại")
        case "invalid": self = .invalid(text ?? Self.defaultFailure, dropped: (root["dropped"] as? [Any] ?? []).compactMap { $0 as? String })
        case "pending": self = .pending(text ?? Self.noAnswerText)
        case "not-ready": self = .failed(title: nil, message: text ?? Self.notReadyText)
        case "busy": self = .failed(title: nil, message: text ?? Self.defaultFailure)
        default:
            self = .failed(title: (root["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }, message: text ?? Self.defaultFailure,
                           closes: root["close"] as? Bool ?? false)
        }
    }

    var logName: String {
        switch self {
        case .created: "created"
        case .exists: "exists"
        case .invalid: "invalid"
        case .failed: "failed"
        case .pending: "pending"
        }
    }
}

extension ZaloEngine {
    func groupCreateLimits() async -> GroupCreateLimits? {
        GroupCreateLimits()
    }

    func groupCreateLimitsWhenReady(attempts: Int = 20) async -> GroupCreateLimits? {
        GroupCreateLimits()
    }

    func createGroup(name: String, members: [String], avatar: GroupAvatarImage?) async -> GroupCreateOutcome {
        do {
            let box = try await sessionClient.createGroupAPI(name: name, members: members)
            let d = box.dict["data"] as? [String: Any] ?? [:]
            let rawGid = JSONLossless.string(d["groupId"])
            let gid = ZaloWireParser.groupConvId(rawGid)
            guard !gid.isEmpty else {
                return .failed(title: nil, message: GroupCreateOutcome.defaultFailure)
            }
            let failed = (d["rejectedMembers"] as? [Any] ?? []).map(JSONLossless.string).filter { !$0.isEmpty }
            let failedSet = Set(ZaloSessionClient.cleanGroupMemberIds(failed))
            let myUid = ZaloWireParser.stripUserPrefix(profile?.userId ?? "")
            var initialIds = ZaloSessionClient.cleanGroupMemberIds(members).filter { !failedSet.contains($0) }
            if !myUid.isEmpty && !initialIds.contains(myUid) {
                initialIds.insert(myUid, at: 0)
            }
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let initialName = trimmedName.isEmpty ? "Nhóm" : trimmedName
            applyGroupMetadataUpdate(
                gid: gid,
                name: initialName,
                avatar: nil,
                memberCount: max(1, initialIds.count),
                memberIds: initialIds
            )

            var avatarUploadFailed = false
            if let avatar {
                do {
                    let upBox = try await sessionClient.uploadGroupAvatarAPI(groupId: gid, jpegData: avatar.jpeg, side: avatar.side)
                    let upData = upBox.dict["data"] as? [String: Any] ?? [:]
                    let avtStr = JSONLossless.string(upData["avatar"] ?? upData["avt"] ?? upData["fullAvt"] ?? upData["url"])
                    if !avtStr.isEmpty, let avtURL = URL(string: avtStr) {
                        applyGroupMetadataUpdate(gid: gid, name: nil, avatar: avtURL, memberCount: nil, memberIds: nil)
                    }
                } catch {
                    avatarUploadFailed = true
                    EngineLog.shared.write("group avatar upload failed: \(error.localizedDescription)")
                }
            }

            await refreshGroupMetadata(gid)
            refreshContacts()
            await openCreatedGroup(gid)
            if !failed.isEmpty && avatarUploadFailed {
                conversationUI.show(.neutral, Self.notAddedText(failed.map(contactName(_:))) + " Chưa tải lên được ảnh đại diện.")
            } else if !failed.isEmpty {
                conversationUI.show(.neutral, Self.notAddedText(failed.map(contactName(_:))))
            } else if avatarUploadFailed {
                conversationUI.show(.neutral, "Đã tạo nhóm nhưng chưa tải lên được ảnh đại diện.")
            }
            return .created(id: gid, failed: failed)
        } catch {
            EngineLog.shared.write("group create failed: \(error.localizedDescription)")
            return .failed(title: nil, message: GroupCreateOutcome.defaultFailure)
        }
    }

    func renameGroup(_ groupId: String, to name: String) async -> Bool {
        let gid = ZaloWireParser.groupConvId(groupId)
        let cleanGrid = ZaloWireParser.cleanGroupId(groupId)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gid.isEmpty, !cleanGrid.isEmpty, cleanGrid != "0", !trimmed.isEmpty else { return false }

        do {
            _ = try await sessionClient.renameGroupAPI(groupId: gid, name: trimmed)
            applyGroupMetadataUpdate(gid: gid, name: trimmed, avatar: nil, memberCount: nil, memberIds: nil)
            await persistSingleGroupConversation(gid)
            conversationUI.show(.success, "Đã đổi tên nhóm")
            return true
        } catch {
            EngineLog.shared.write("rename group failed: \(error.localizedDescription)")
            conversationUI.show(.failure, "Không thể đổi tên nhóm.")
            return false
        }
    }

    func inviteMembers(_ memberIds: [String], to groupId: String) async -> Bool {
        let gid = ZaloWireParser.groupConvId(groupId)
        let cleanGrid = ZaloWireParser.cleanGroupId(groupId)
        let myUid = ZaloWireParser.stripUserPrefix(profile?.userId ?? "")
        let cleanIds = ZaloSessionClient.cleanGroupMemberIds(memberIds).filter { $0 != myUid }
        guard !gid.isEmpty, !cleanGrid.isEmpty, cleanGrid != "0", !cleanIds.isEmpty else { return false }

        do {
            let box = try await sessionClient.inviteGroupMembersAPI(groupId: gid, memberIds: cleanIds)
            let d = box.dict["data"] as? [String: Any] ?? [:]
            let rawRejected = (d["errorMem"] as? [Any])
                ?? (d["errorMembers"] as? [Any])
                ?? (d["rejectedMembers"] as? [Any])
                ?? []
            let rejectedSet = Set(ZaloSessionClient.cleanGroupMemberIds(rawRejected.map(JSONLossless.string)))
            let added = cleanIds.filter { !rejectedSet.contains($0) }
            guard !added.isEmpty else {
                conversationUI.show(.failure, "Không thể thêm thành viên vào nhóm.")
                return false
            }

            let existingIds = groupMemberIds(in: gid)
            var mergedIds = existingIds
            var newlyAddedCount = 0
            for uid in added where !mergedIds.contains(uid) {
                mergedIds.append(uid)
                newlyAddedCount += 1
            }
            let currentCount = conversations.first(where: { $0.id == gid })?.members
                ?? contacts.groups.first(where: { $0.id == gid })?.members
                ?? existingIds.count
            let nextCount = max(mergedIds.count, currentCount + newlyAddedCount)

            groupMemberCache.removeValue(forKey: gid)
            applyGroupMetadataUpdate(gid: gid, name: nil, avatar: nil, memberCount: nextCount, memberIds: mergedIds)
            await persistSingleGroupConversation(gid)
            await refreshGroupMetadata(gid)

            if !rejectedSet.isEmpty {
                conversationUI.show(.neutral, Self.notAddedText(Array(rejectedSet).map(contactName(_:))))
            } else {
                conversationUI.show(.success, "Đã thêm thành viên vào nhóm")
            }
            return true
        } catch {
            EngineLog.shared.write("invite group members failed: \(error.localizedDescription)")
            conversationUI.show(.failure, "Không thể thêm thành viên vào nhóm.")
            return false
        }
    }

    func kickMember(_ memberId: String, from groupId: String) async -> Bool {
        let gid = ZaloWireParser.groupConvId(groupId)
        let cleanGrid = ZaloWireParser.cleanGroupId(groupId)
        guard let cleanMember = ZaloSessionClient.cleanGroupMemberIds([memberId]).first,
              !gid.isEmpty, !cleanGrid.isEmpty, cleanGrid != "0" else {
            return false
        }
        if let myUid = profile?.userId, !myUid.isEmpty, cleanMember == ZaloWireParser.stripUserPrefix(myUid) {
            return false
        }

        do {
            _ = try await sessionClient.kickGroupMembersAPI(groupId: gid, memberIds: [cleanMember])
            if var cached = groupMemberCache[gid] {
                cached.removeAll { $0.id == cleanMember }
                groupMemberCache[gid] = cached
            }
            let currentIds = groupMemberIds(in: gid)
            let updatedIds = currentIds.filter { $0 != cleanMember }
            let hadMember = currentIds.contains(cleanMember)
            let currentCount = conversations.first(where: { $0.id == gid })?.members
                ?? contacts.groups.first(where: { $0.id == gid })?.members
                ?? currentIds.count
            let nextCount = (hadMember || currentIds.isEmpty) ? max(1, currentCount - 1) : max(1, updatedIds.count)

            applyGroupMetadataUpdate(
                gid: gid,
                name: nil,
                avatar: nil,
                memberCount: nextCount,
                memberIds: currentIds.isEmpty ? nil : updatedIds
            )
            await persistSingleGroupConversation(gid)
            await refreshGroupMetadata(gid)
            conversationUI.show(.success, "Đã xóa thành viên khỏi nhóm")
            return true
        } catch {
            EngineLog.shared.write("kick group member failed: \(error.localizedDescription)")
            conversationUI.show(.failure, "Không thể xóa thành viên.")
            return false
        }
    }

    func leaveGroup(_ groupId: String, silent: Bool = false) async -> Bool {
        let gid = ZaloWireParser.groupConvId(groupId)
        let cleanGrid = ZaloWireParser.cleanGroupId(groupId)
        guard !gid.isEmpty, !cleanGrid.isEmpty, cleanGrid != "0" else { return false }

        do {
            _ = try await sessionClient.leaveGroupAPI(groupId: gid, silent: silent)
            contacts.groups.removeAll { $0.id == gid }
            cachedGroupDetails.removeValue(forKey: cleanGrid)
            groupMemberCache.removeValue(forKey: gid)
            cachedGroups.removeValue(forKey: gid)
            messages.removeValue(forKey: gid)
            coreLifecycle.core?.writeThroughRemoveWindow(convId: gid)
            hasMoreHistory.removeValue(forKey: gid)
            historyTicks.removeValue(forKey: gid)
            typing.removeValue(forKey: gid)
            pins.removeValue(forKey: gid)
            if openConversationId == gid {
                openConversationId = nil
                dropMessagePrompts()
            }
            if let core = coreLifecycle.core, let v = try? await core.removeLocalConversation(id: gid) {
                await waitForMirrorVersion(v)
            } else {
                conversations.removeAll { $0.id == gid }
                cachedPinnedIds.remove(gid)
                cachedArchivedIds.remove(gid)
                cachedUnreadMarks.remove(gid)
                conversationUI.remove([gid])
                rebuildConversationFlags()
                rebuildConversationExtras()
                try? await sqliteStore?.deleteConversation(id: gid)
            }

            await persistCachedGroupsPreference()
            conversationUI.show(.success, "Đã rời nhóm")
            return true
        } catch {
            EngineLog.shared.write("leave group failed: \(error.localizedDescription)")
            conversationUI.show(.failure, "Không thể rời nhóm.")
            return false
        }
    }

    /// Extracts all known user IDs for a group from cached detail / member cache.
    func groupMemberIds(in groupId: String) -> [String] {
        let gid = ZaloWireParser.groupConvId(groupId)
        let cleanGrid = ZaloWireParser.cleanGroupId(groupId)
        var raw: [String] = []
        if let groupInfo = cachedGroupDetails[cleanGrid] {
            if let verList = groupInfo["memVerList"] as? [String] {
                raw.append(contentsOf: verList.compactMap { $0.split(separator: "_").first.map(String.init) })
            }
            if let mems = groupInfo["memIds"] as? [Any] {
                raw.append(contentsOf: mems.map(JSONLossless.string))
            }
            if let cur = groupInfo["currentMems"] as? [[String: Any]] {
                raw.append(contentsOf: cur.map { JSONLossless.string($0["id"] ?? $0["uid"]) })
            }
        }
        if let cached = groupMemberCache[gid] {
            raw.append(contentsOf: cached.filter { !$0.isAll && $0.id != "-1" }.map(\.id))
        }
        return ZaloSessionClient.cleanGroupMemberIds(raw)
    }

    /// Loads group members for the inspector (excluding self and `@All`), fetching group detail if missing.
    func loadGroupMembers(in groupId: String) async -> [MentionCandidate] {
        let gid = ZaloWireParser.groupConvId(groupId)
        let cleanGrid = ZaloWireParser.cleanGroupId(groupId)
        guard !gid.isEmpty else { return [] }

        if cachedGroupDetails[cleanGrid] == nil {
            await refreshGroupMetadata(gid)
        }
        let viaMention = await mentionCandidates(in: gid, query: "", excluding: []).filter { !$0.isAll && $0.id != "-1" }
        if !viaMention.isEmpty {
            return viaMention
        }

        let myUid = ZaloWireParser.stripUserPrefix(profile?.userId ?? "")
        let knownIds = groupMemberIds(in: gid).filter { $0 != myUid }
        guard !knownIds.isEmpty else { return [] }
        let fallback = knownIds.map { uid -> MentionCandidate in
            let info = lookupPersonInfo(uid)
            let name = (info?.name.isEmpty == false) ? info!.name : "Người dùng Zalo"
            let avatar = info.flatMap { $0.avatar.isEmpty ? nil : URL(string: $0.avatar) }
            return MentionCandidate(id: uid, name: name, avatar: avatar, isAll: false)
        }
        groupMemberCache[gid] = [MentionCandidate(id: "-1", name: "All", avatar: nil, isAll: true)] + fallback
        return fallback
    }

    internal func refreshGroupMetadata(_ groupId: String) async {
        let gid = ZaloWireParser.groupConvId(groupId)
        let cleanGrid = ZaloWireParser.cleanGroupId(groupId)
        guard !gid.isEmpty, !cleanGrid.isEmpty,
              let box = try? await sessionClient.fetchGroupDetailAPI(groupId: gid),
              !box.dict.isEmpty else {
            return
        }
        let info = box.dict
        cachedGroupDetails[cleanGrid] = info
        let serverName = JSONLossless.string(info["name"])
        let avtStr = JSONLossless.string(info["avt"] ?? info["fullAvt"])
        let avtURL = avtStr.isEmpty ? nil : URL(string: avtStr)
        var rawMemberIds: [String] = []
        if let verList = info["memVerList"] as? [String] {
            rawMemberIds.append(contentsOf: verList.compactMap { $0.split(separator: "_").first.map(String.init) })
        }
        if rawMemberIds.isEmpty, let mems = info["memIds"] as? [Any] {
            rawMemberIds.append(contentsOf: mems.map(JSONLossless.string))
        }
        if rawMemberIds.isEmpty, let cur = info["currentMems"] as? [[String: Any]] {
            rawMemberIds.append(contentsOf: cur.map { JSONLossless.string($0["id"] ?? $0["uid"]) })
        }
        let cleanMemberIds = ZaloSessionClient.cleanGroupMemberIds(rawMemberIds)
        let memberCount = Int(JSONLossless.int64(info["totalMember"] ?? info["total"]) ?? Int64(cleanMemberIds.count))
        groupMemberCache.removeValue(forKey: gid)
        applyGroupMetadataUpdate(
            gid: gid,
            name: serverName.isEmpty ? nil : serverName,
            avatar: avtURL,
            memberCount: memberCount > 0 ? memberCount : nil,
            memberIds: cleanMemberIds.isEmpty ? nil : cleanMemberIds
        )
        await persistSingleGroupConversation(gid)
    }

    private func applyGroupMetadataUpdate(
        gid: String,
        name: String?,
        avatar: URL?,
        memberCount: Int?,
        memberIds: [String]?
    ) {
        let cleanGrid = ZaloWireParser.cleanGroupId(gid)
        var detail = cachedGroupDetails[cleanGrid] ?? [:]
        if let name, !name.isEmpty { detail["name"] = name }
        if let avatar { detail["avt"] = avatar.absoluteString }
        if let memberCount, memberCount > 0 { detail["totalMember"] = memberCount }
        if let memberIds {
            detail["memIds"] = memberIds
            detail["memVerList"] = memberIds.map { "\($0)_0" }
            if detail["currentMems"] != nil {
                detail["currentMems"] = memberIds.map { ["id": $0] }
            }
        }
        cachedGroupDetails[cleanGrid] = detail

        if let idx = contacts.groups.firstIndex(where: { $0.id == gid }) {
            let old = contacts.groups[idx]
            let nextName = (name?.isEmpty == false) ? name! : old.name
            let nextAvatar = avatar ?? old.avatar
            let nextMembers = memberCount ?? old.members
            contacts.groups[idx] = ContactsState.Group(
                id: gid,
                name: nextName,
                avatar: nextAvatar,
                members: nextMembers,
                sortKey: Self.contactFold(nextName)
            )
        } else {
            let nextName = (name?.isEmpty == false) ? name! : "Nhóm"
            contacts.groups.append(ContactsState.Group(
                id: gid,
                name: nextName,
                avatar: avatar,
                members: memberCount ?? 1,
                sortKey: Self.contactFold(nextName)
            ))
        }
        contacts.groups.sort { $0.sortKey.localizedStandardCompare($1.sortKey) == .orderedAscending }

        var convList = conversations
        if let idx = convList.firstIndex(where: { $0.id == gid }) {
            if let name, !name.isEmpty { convList[idx].name = name }
            if let avatar { convList[idx].avatar = avatar }
            if let memberCount, memberCount > 0 { convList[idx].members = memberCount }
        } else {
            convList.append(ConversationSummary(
                id: gid,
                isGroup: true,
                name: (name?.isEmpty == false) ? name! : "Nhóm",
                avatar: avatar,
                pinned: cachedPinnedIds.contains(gid),
                members: memberCount ?? 1,
                unread: 0,
                preview: nil
            ))
        }
        sortConversations(&convList)
        conversations = convList

        let existingCached = cachedGroups[gid]
        cachedGroups[gid] = ZaloWebKitMigrator.CachedGroup(
            name: (name?.isEmpty == false) ? name! : (existingCached?.name ?? ""),
            avatar: avatar?.absoluteString ?? existingCached?.avatar ?? "",
            members: memberCount ?? existingCached?.members ?? 0
        )

        rebuildConversationFlags()
        rebuildConversationExtras()
    }

    private func persistSingleGroupConversation(_ gid: String) async {
        await persistCachedGroupsPreference()
        guard let store = sqliteStore,
              let summary = conversations.first(where: { $0.id == gid }) else { return }
        let stored = StoredConversation(
            id: summary.id,
            isGroup: summary.isGroup,
            name: summary.name,
            avatar: summary.avatar?.absoluteString ?? "",
            pinned: summary.pinned,
            members: summary.members,
            unread: summary.unread,
            previewText: summary.preview?.text ?? "",
            previewTsMs: Int64(((summary.preview?.date?.timeIntervalSince1970 ?? 0) * 1000).rounded()),
            previewFromMe: summary.preview?.fromMe ?? false,
            updatedAtMs: nowMs()
        )
        try? await store.upsertConversation(stored)
    }

    private func persistCachedGroupsPreference() async {
        guard let store = sqliteStore,
              let data = try? JSONEncoder().encode(cachedGroups) else { return }
        try? await store.setPreferenceData(key: "cachedGroups", data: data)
    }

    /// "Chưa thêm được A, B và 3 người khác vào nhóm."
    nonisolated static func notAddedText(_ names: [String]) -> String {
        let shown = names.prefix(3).joined(separator: ", ")
        let rest = names.count - min(names.count, 3)
        return "Chưa thêm được " + (rest > 0 ? "\(shown) và \(rest) người khác" : shown) + " vào nhóm."
    }

    private func contactName(_ id: String) -> String {
        contacts.friends.first { $0.id == id }?.name ?? "Người dùng Zalo"
    }

    private func openCreatedGroup(_ id: String) async {
        for _ in 0..<30 where !conversations.contains(where: { $0.id == id }) && !contacts.groups.contains(where: { $0.id == id }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        navigationRequest = id
    }
}
