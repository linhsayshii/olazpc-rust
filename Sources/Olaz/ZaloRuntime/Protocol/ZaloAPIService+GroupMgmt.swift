import Foundation

struct GroupMgmtRequestSpec: @unchecked Sendable {
    let service: String
    let path: String
    let payload: [String: Any]
}

struct GroupAvatarUploadSpec: @unchecked Sendable {
    let service: String
    let path: String
    let encryptedPayload: [String: Any]
    let fieldName: String
    let fileName: String
    let mimeType: String
}

extension ZaloSessionClient {
    // MARK: - Pure Request Builders

    static func cleanGroupMemberIds(_ memberIds: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        out.reserveCapacity(memberIds.count)
        for raw in memberIds {
            let trimmed = ZaloWireParser.stripUserPrefix(raw)
            let clean: String
            if trimmed.hasPrefix("u"), trimmed.count > 1, trimmed.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) {
                clean = String(trimmed.dropFirst())
            } else {
                clean = trimmed
            }
            guard !clean.isEmpty, clean != "0", seen.insert(clean).inserted else { continue }
            out.append(clean)
        }
        return out
    }

    static func buildUploadGroupAvatarRequest(
        groupId: String,
        side: Int,
        clientId: Int64,
        imei: String
    ) -> GroupAvatarUploadSpec? {
        let cleanGrid = ZaloWireParser.cleanGroupId(groupId)
        guard !cleanGrid.isEmpty, cleanGrid != "0", side > 0 else { return nil }
        return GroupAvatarUploadSpec(
            service: "file",
            path: "/api/group/upavatar",
            encryptedPayload: [
                "grid": cleanGrid,
                "avatarSize": side,
                "clientId": clientId,
                "originWidth": side,
                "originHeight": side,
                "imei": imei
            ],
            fieldName: "fileContent",
            fileName: "avatar.jpg",
            mimeType: "image/jpeg"
        )
    }

    static func buildRenameGroupRequest(
        groupId: String,
        name: String,
        imei: String
    ) -> GroupMgmtRequestSpec? {
        let cleanGrid = ZaloWireParser.cleanGroupId(groupId)
        guard !cleanGrid.isEmpty, cleanGrid != "0" else { return nil }
        return GroupMgmtRequestSpec(
            service: "group",
            path: "/api/group/updateinfo",
            payload: [
                "grid": cleanGrid,
                "gname": name,
                "imei": imei
            ]
        )
    }

    static func buildInviteGroupMembersRequest(
        groupId: String,
        memberIds: [String],
        imei: String
    ) -> GroupMgmtRequestSpec? {
        let cleanGrid = ZaloWireParser.cleanGroupId(groupId)
        let cleanIds = cleanGroupMemberIds(memberIds)
        guard !cleanGrid.isEmpty, cleanGrid != "0", !cleanIds.isEmpty else { return nil }
        return GroupMgmtRequestSpec(
            service: "group",
            path: "/api/group/invite/v2",
            payload: [
                "grid": cleanGrid,
                "members": cleanIds,
                "memberTypes": Array(repeating: -1, count: cleanIds.count),
                "imei": imei,
                "clientLang": "vi"
            ]
        )
    }

    static func buildKickGroupMembersRequest(
        groupId: String,
        memberIds: [String],
        imei: String
    ) -> GroupMgmtRequestSpec? {
        let cleanGrid = ZaloWireParser.cleanGroupId(groupId)
        let cleanIds = cleanGroupMemberIds(memberIds)
        guard !cleanGrid.isEmpty, cleanGrid != "0", !cleanIds.isEmpty else { return nil }
        return GroupMgmtRequestSpec(
            service: "group",
            path: "/api/group/kickout",
            payload: [
                "grid": cleanGrid,
                "members": cleanIds,
                "imei": imei
            ]
        )
    }

    static func buildLeaveGroupRequest(
        groupId: String,
        silent: Bool = false,
        imei: String
    ) -> GroupMgmtRequestSpec? {
        let cleanGrid = ZaloWireParser.cleanGroupId(groupId)
        guard !cleanGrid.isEmpty, cleanGrid != "0" else { return nil }
        return GroupMgmtRequestSpec(
            service: "group",
            path: "/api/group/leave",
            payload: [
                "grids": [cleanGrid],
                "imei": imei,
                "silent": silent ? 1 : 0,
                "language": "vi"
            ]
        )
    }

    // MARK: - Network Calls

    @discardableResult
    func uploadGroupAvatarAPI(groupId: String, jpegData: Data, side: Int) async throws -> ZaloJSONBox {
        guard !jpegData.isEmpty else {
            throw ZaloTransportError.invalidURL("upavatar:empty")
        }
        let cliInt = nextClientId()
        guard let spec = Self.buildUploadGroupAvatarRequest(
            groupId: groupId,
            side: side,
            clientId: cliInt,
            imei: imei
        ) else {
            throw ZaloTransportError.invalidURL("upavatar:groupId")
        }
        let resp = try await postMultipart(
            service: spec.service,
            path: spec.path,
            encryptedPayload: spec.encryptedPayload,
            fieldName: spec.fieldName,
            fileName: spec.fileName,
            mimeType: spec.mimeType,
            chunkData: jpegData
        )
        return ZaloJSONBox(resp)
    }

    @discardableResult
    func renameGroupAPI(groupId: String, name: String) async throws -> ZaloJSONBox {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let spec = Self.buildRenameGroupRequest(groupId: groupId, name: trimmed, imei: imei) else {
            throw ZaloTransportError.invalidURL("updateinfo")
        }
        let resp = try await post(
            service: spec.service,
            path: spec.path,
            encryptedPayload: spec.payload
        )
        return ZaloJSONBox(resp)
    }

    @discardableResult
    func inviteGroupMembersAPI(groupId: String, memberIds: [String]) async throws -> ZaloJSONBox {
        guard let spec = Self.buildInviteGroupMembersRequest(groupId: groupId, memberIds: memberIds, imei: imei) else {
            throw ZaloTransportError.invalidURL("invite")
        }
        let resp = try await post(
            service: spec.service,
            path: spec.path,
            encryptedPayload: spec.payload
        )
        return ZaloJSONBox(resp)
    }

    @discardableResult
    func kickGroupMembersAPI(groupId: String, memberIds: [String]) async throws -> ZaloJSONBox {
        guard let spec = Self.buildKickGroupMembersRequest(groupId: groupId, memberIds: memberIds, imei: imei) else {
            throw ZaloTransportError.invalidURL("kickout")
        }
        let resp = try await post(
            service: spec.service,
            path: spec.path,
            encryptedPayload: spec.payload
        )
        return ZaloJSONBox(resp)
    }

    @discardableResult
    func leaveGroupAPI(groupId: String, silent: Bool = false) async throws -> ZaloJSONBox {
        guard let spec = Self.buildLeaveGroupRequest(groupId: groupId, silent: silent, imei: imei) else {
            throw ZaloTransportError.invalidURL("leave")
        }
        let resp = try await post(
            service: spec.service,
            path: spec.path,
            encryptedPayload: spec.payload
        )
        return ZaloJSONBox(resp)
    }

    /// Fetches `/api/group/getmg-v2` metadata for a single group.
    func fetchGroupDetailAPI(groupId: String) async throws -> ZaloJSONBox {
        let cleanGrid = ZaloWireParser.cleanGroupId(groupId)
        guard !cleanGrid.isEmpty, cleanGrid != "0" else {
            throw ZaloTransportError.invalidURL("getmg-v2")
        }
        let verData = try JSONSerialization.data(withJSONObject: [cleanGrid: 0], options: [])
        let verJSON = String(decoding: verData, as: UTF8.self)
        let resp = try await post(
            service: "group",
            path: "/api/group/getmg-v2",
            encryptedPayload: ["gridVerMap": verJSON, "imei": imei]
        )
        let outer = resp["data"] as? [String: Any] ?? [:]
        let batchData = (outer["data"] as? [String: Any]) ?? outer
        if let gridInfoMap = batchData["gridInfoMap"] as? [String: Any],
           let info = (gridInfoMap[cleanGrid] as? [String: Any]) ?? (gridInfoMap["g\(cleanGrid)"] as? [String: Any]) {
            return ZaloJSONBox(info)
        }
        return ZaloJSONBox([:])
    }
}
