import AppKit
import Foundation

// Group calls: the participant picker. The official renderer opens its GROUP_CALL modal (invisible here) for two
// things — the chat header's video button on a group, and the native call helper's "add participant" request.
// HostScripts/call-adapter.js hands both to the app as `{kind:'picker'}` and runs the modal's own `onConfirm` /
// `onCancel` when the user answers (`pickerConfirm` → `callHelper.makeCall(ids, isVideo, true, …)` for a new call,
// `callHelper.sendAddUserResponse(groupId, callees)` for an add-participant request).
//
// The list, the limit and the rules are the renderer's (see the adapter); this file only models and answers.

/// What the renderer's GROUP_CALL modal would show.
struct GroupCallPicker: Equatable, Identifiable {
    struct Member: Equatable, Identifiable {
        let id: String
        var name: String
        var avatar: URL?
    }

    /// Request token (single use).
    let id: String
    /// Group conversation ID (`g<grid>` or `<grid>`).
    var groupId: String
    /// The helper asked to add people to a running call (instead of starting one).
    var adding: Bool
    /// nil: unknown (add-participant: the renderer does not know whether the running call has video).
    var video: Bool?
    var groupName: String
    var groupAvatar: URL?
    /// Official limit: `maxUsers - 1` (10 when the server sends no `maxUsers`).
    var maxSelectable: Int
    /// Already in the call (add-participant): shown ticked and disabled, not counted.
    var existing: Set<String>
    /// Group-privacy notice of the modal header ("Bạn chỉ có thể gọi cho trưởng/phó nhóm.").
    var note: String?
    var members: [Member]

    var title: String { adding ? "Thêm người vào cuộc gọi" : "Tạo cuộc gọi" }
    var confirmTitle: String { adding ? "Thêm" : "Gọi" }
    var searchPlaceholder: String { "Tìm kiếm thành viên" }

    init(id: String, groupId: String = "", adding: Bool, video: Bool?, groupName: String, groupAvatar: URL? = nil, maxSelectable: Int,
         existing: Set<String> = [], note: String? = nil, members: [Member]) {
        self.id = id
        self.groupId = groupId
        self.adding = adding
        self.video = video
        self.groupName = groupName
        self.groupAvatar = groupAvatar
        self.maxSelectable = maxSelectable
        self.existing = existing
        self.note = note
        self.members = members
    }

    /// `{kind:'picker', token, add, video, group:{id,name,avatar}, max, existing, note, members:[{id,name,avatar}]}`.
    init?(json: [String: Any]) {
        guard let token = json["token"] as? String, !token.isEmpty else { return nil }
        let group = json["group"] as? [String: Any] ?? [:]
        let rows = (json["members"] as? [[String: Any]] ?? []).compactMap { row -> Member? in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            let name = (row["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return Member(id: id, name: name.isEmpty ? "Người dùng Zalo" : name,
                          avatar: (row["avatar"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) })
        }
        let name = (group["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawGroupId = (group["id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(id: token,
                  groupId: rawGroupId,
                  adding: json["add"] as? Bool ?? false,
                  video: json["video"] as? Bool,
                  groupName: name.isEmpty ? "Nhóm" : name,
                  groupAvatar: (group["avatar"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) },
                  maxSelectable: max(0, (json["max"] as? NSNumber)?.intValue ?? 10),
                  existing: Set((json["existing"] as? [Any] ?? []).compactMap { $0 as? String }),
                  note: (json["note"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                  members: rows)
    }

    /// Official over-limit toast (`STR_MAX_1_MEM_INVITE_TOAST` / `STR_MAX_MEM_INVITE_TOAST`, same text).
    var limitMessage: String { "Bạn chỉ có thể mời \(maxSelectable) người khác" }

    /// Members whose name contains `query` (case / diacritic insensitive; Vietnamese `đ` folds to `d`).
    func members(matching query: String) -> [Member] {
        let needle = Self.fold(query)
        guard !needle.isEmpty else { return members }
        return members.filter { Self.fold($0.name).contains(needle) }
    }

    static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "d")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "vi"))
    }

    /// The modal's `onItemClick`: a new item beyond `max_mem` is refused (the toast shows), removing always works.
    /// Members already in the call and ids that are not in the list never change the selection.
    func toggled(_ memberId: String, in selection: [String]) -> (selection: [String], overLimit: Bool) {
        guard !existing.contains(memberId), members.contains(where: { $0.id == memberId }) else { return (selection, false) }
        if let index = selection.firstIndex(of: memberId) {
            var next = selection
            next.remove(at: index)
            return (next, false)
        }
        if selection.count >= maxSelectable { return (selection, true) }
        return (selection + [memberId], false)
    }
}

extension ZaloEngine {
    internal func loadGroupCallMembers(groupConvId: String) async -> [GroupCallPicker.Member] {
        let convId = ZaloWireParser.groupConvId(groupConvId)
        let cleanGrid = ZaloWireParser.cleanGroupId(convId)
        let myUid = profile?.userId ?? ""

        if cachedGroupDetails[cleanGrid] == nil,
           let gBox = try? await sessionClient.fetchGroupsList(),
           let infoMap = gBox.dict["gridInfoMap"] as? [String: Any] {
            for (rawId, rawInfo) in infoMap {
                guard let info = rawInfo as? [String: Any] else { continue }
                let cid = ZaloWireParser.cleanGroupId(rawId)
                if !cid.isEmpty { cachedGroupDetails[cid] = info }
            }
        }

        var memberIds: [String] = []
        if let groupInfo = cachedGroupDetails[cleanGrid] {
            if let verList = groupInfo["memVerList"] as? [String] {
                memberIds.append(contentsOf: verList.compactMap { $0.split(separator: "_").first.map(String.init) })
            }
            if memberIds.isEmpty, let mems = groupInfo["memIds"] as? [Any] {
                memberIds.append(contentsOf: mems.map(JSONLossless.string))
            }
            if memberIds.isEmpty, let cur = groupInfo["currentMems"] as? [[String: Any]] {
                memberIds.append(contentsOf: cur.map { JSONLossless.string($0["id"] ?? $0["uid"]) })
            }
        }
        let cleanIds = Array(Set(memberIds.map(ZaloWireParser.stripUserPrefix))).filter { !$0.isEmpty && $0 != "0" && $0 != myUid }
        guard !cleanIds.isEmpty else {
            return (groupMemberCache[convId] ?? [])
                .filter { !$0.isAll && $0.id != "-1" && $0.id != myUid }
                .map { GroupCallPicker.Member(id: $0.id, name: $0.name, avatar: $0.avatar) }
        }

        let missing = cleanIds.filter { lookupPersonInfo($0) == nil }
        if !missing.isEmpty {
            for offset in stride(from: 0, to: min(missing.count, 100), by: 50) {
                let slice = Array(missing[offset..<min(offset + 50, missing.count)])
                if let profBox = try? await sessionClient.fetchProfiles(uids: slice) {
                    for (uid, row) in ZaloWireParser.extractProfilesMap(profBox.dict) {
                        let c = ZaloWireParser.stripUserPrefix(uid)
                        let n = JSONLossless.string(row["displayName"] ?? row["dName"] ?? row["zaloName"] ?? row["name"])
                        let a = JSONLossless.string(row["avatar"] ?? row["avt"])
                        if !c.isEmpty, (!n.isEmpty || !a.isEmpty) {
                            cachedProfiles[c] = ZaloWebKitMigrator.CachedProfile(name: n, avatar: a)
                        }
                    }
                }
            }
        }

        return cleanIds.map { uid in
            let info = lookupPersonInfo(uid)
            let name = (info?.name.isEmpty == false) ? info!.name : "Người dùng Zalo"
            let avatar = info.flatMap { $0.avatar.isEmpty ? nil : URL(string: $0.avatar) }
            return GroupCallPicker.Member(id: uid, name: name, avatar: avatar)
        }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func confirmGroupPicker(_ picker: GroupCallPicker, selected: [String]) {
        guard call.picker?.id == picker.id else { return }
        call.picker = nil
        let ids = selected.filter { id in picker.members.contains { $0.id == id } && !picker.existing.contains(id) }
        guard !ids.isEmpty, ids.count <= picker.maxSelectable else { return }

        ensureCallBridgeStartedIfNeeded()
        let memberById = Dictionary(uniqueKeysWithValues: picker.members.map { ($0.id, $0) })
        let cleanGroupId = ZaloWireParser.cleanGroupId(picker.groupId)

        if picker.adding {
            let callees: [[String: Any]] = ids.map { uid in
                [
                    "userId": ZaloWireParser.stripUserPrefix(uid),
                    "avatar": memberById[uid]?.avatar?.absoluteString ?? lookupPersonInfo(uid)?.avatar ?? "",
                ]
            }
            let resp: [String: Any] = [
                "type": "response",
                "command": "addUser",
                "data": [
                    "groupId": cleanGroupId,
                    "calleeIds": callees,
                ],
            ]
            if let data = try? JSONSerialization.data(withJSONObject: resp),
               let json = String(data: data, encoding: .utf8) {
                callBridge?.sendToNative(json: json, optional: false)
            }
        } else {
            let partners: [(id: String, name: String, avatar: String)] = ids.map { uid in
                let m = memberById[uid]
                let info = lookupPersonInfo(uid)
                return (
                    id: ZaloWireParser.stripUserPrefix(uid),
                    name: m?.name ?? info?.name ?? "Người dùng Zalo",
                    avatar: m?.avatar?.absoluteString ?? info?.avatar ?? ""
                )
            }
            let makeCallJSON = ZaloVoiceCallProtocol.buildMakeCallJSON(
                partners: partners,
                video: picker.video ?? true,
                groupInfo: (
                    id: cleanGroupId,
                    name: picker.groupName,
                    avatar: picker.groupAvatar?.absoluteString ?? "",
                    maxUsers: picker.maxSelectable + 1
                )
            )
            callBridge?.sendToNative(json: makeCallJSON, optional: false)
        }
    }

    func cancelGroupPicker(_ picker: GroupCallPicker) {
        guard call.picker?.id == picker.id else { return }
        call.picker = nil
        if picker.adding {
            let resp: [String: Any] = [
                "type": "response",
                "command": "addUser",
                "data": [
                    "groupId": ZaloWireParser.cleanGroupId(picker.groupId),
                    "calleeIds": [] as [[String: Any]],
                ],
            ]
            if let data = try? JSONSerialization.data(withJSONObject: resp),
               let json = String(data: data, encoding: .utf8) {
                callBridge?.sendToNative(json: json, optional: true)
            }
        }
    }
}
