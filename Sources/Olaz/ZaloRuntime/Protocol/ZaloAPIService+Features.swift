import CryptoKit
import Foundation

struct FeatureGETRequestSpec: @unchecked Sendable {
    let service: String
    let path: String
    let encryptedPayload: [String: Any]?
}

struct HiddenConversationsSnapshot: Equatable, Sendable {
    var pin: String
    var threadIds: [String]
}

extension ZaloSessionClient {
    // MARK: - Pure Request Builders & Parsers

    static func hiddenPinMD5Hex(_ pin: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(pin.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func buildPinBoardItemRequest(
        groupId: String,
        topicId: String,
        topicType: Int = 3
    ) -> FeatureGETRequestSpec? {
        let cleanGrid = ZaloWireParser.cleanGroupId(groupId)
        let cleanTopic = topicId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanGrid.isEmpty, cleanGrid != "0", !cleanTopic.isEmpty else { return nil }
        return FeatureGETRequestSpec(
            service: "group_board",
            path: "/api/board/pinv2",
            encryptedPayload: [
                "grid": cleanGrid,
                "topicId": cleanTopic,
                "type": topicType
            ]
        )
    }

    static func buildFetchHiddenConversationsRequest(imei: String) -> FeatureGETRequestSpec {
        FeatureGETRequestSpec(
            service: "conversation",
            path: "/api/hiddenconvers/get-all",
            encryptedPayload: ["imei": imei]
        )
    }

    static func parseHiddenConversationsResponse(_ resp: [String: Any]) -> HiddenConversationsSnapshot {
        let dataNode = (resp["data"] as? [String: Any]) ?? resp
        let pin = JSONLossless.string(dataNode["pin"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let rawThreads = (dataNode["threads"] as? [[String: Any]]) ?? []
        var seen = Set<String>()
        var normalizedIds: [String] = []
        normalizedIds.reserveCapacity(rawThreads.count)

        for row in rawThreads {
            let rawId = JSONLossless.string(row["thread_id"] ?? row["threadId"])
            guard !rawId.isEmpty else { continue }
            let isGroup = JSONLossless.bool(row["is_group"] ?? row["isGroup"])
                ?? (JSONLossless.int64(row["is_group"] ?? row["isGroup"]) == 1)
            let normalized: String
            if isGroup {
                normalized = ZaloWireParser.groupConvId(rawId)
            } else {
                normalized = ZaloWireParser.stripUserPrefix(rawId)
            }
            guard !normalized.isEmpty, normalized != "0", normalized != "g0",
                  seen.insert(normalized).inserted else { continue }
            normalizedIds.append(normalized)
        }
        return HiddenConversationsSnapshot(pin: pin, threadIds: normalizedIds)
    }

    static func buildUpdateHiddenPinRequest(pin: String, imei: String) -> FeatureGETRequestSpec? {
        guard !pin.isEmpty else { return nil }
        return FeatureGETRequestSpec(
            service: "conversation",
            path: "/api/hiddenconvers/update-pin",
            encryptedPayload: [
                "new_pin": hiddenPinMD5Hex(pin),
                "imei": imei
            ]
        )
    }

    static func buildResetHiddenPinRequest() -> FeatureGETRequestSpec {
        FeatureGETRequestSpec(
            service: "conversation",
            path: "/api/hiddenconvers/reset",
            encryptedPayload: nil
        )
    }

    static func buildFetchReminderRespondersRequest(reminderId: String) -> FeatureGETRequestSpec? {
        let cleanId = reminderId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else { return nil }
        return FeatureGETRequestSpec(
            service: "group_board",
            path: "/api/board/topic/listResponseEvent",
            encryptedPayload: ["eventId": cleanId]
        )
    }

    // MARK: - Network Calls

    @discardableResult
    func pinBoardItemAPI(groupId: String, topicId: String, topicType: Int = 3) async throws -> ZaloJSONBox {
        guard let spec = Self.buildPinBoardItemRequest(groupId: groupId, topicId: topicId, topicType: topicType) else {
            throw ZaloTransportError.invalidURL("pinv2")
        }
        let resp = try await get(
            service: spec.service,
            path: spec.path,
            encryptedPayload: spec.encryptedPayload
        )
        return ZaloJSONBox(resp)
    }

    func fetchHiddenConversationsAPI() async throws -> HiddenConversationsSnapshot {
        let spec = Self.buildFetchHiddenConversationsRequest(imei: imei)
        let resp = try await get(
            service: spec.service,
            path: spec.path,
            encryptedPayload: spec.encryptedPayload
        )
        return Self.parseHiddenConversationsResponse(resp)
    }

    @discardableResult
    func updateHiddenPinAPI(pin: String) async throws -> ZaloJSONBox {
        guard let spec = Self.buildUpdateHiddenPinRequest(pin: pin, imei: imei) else {
            throw ZaloTransportError.invalidURL("hiddenconvers:update-pin")
        }
        let resp = try await get(
            service: spec.service,
            path: spec.path,
            encryptedPayload: spec.encryptedPayload
        )
        return ZaloJSONBox(resp)
    }

    @discardableResult
    func resetHiddenPinAPI() async throws -> ZaloJSONBox {
        let spec = Self.buildResetHiddenPinRequest()
        let resp = try await get(
            service: spec.service,
            path: spec.path,
            encryptedPayload: spec.encryptedPayload
        )
        return ZaloJSONBox(resp)
    }

    func fetchReminderRespondersAPI(reminderId: String) async throws -> ZaloJSONBox {
        guard let spec = Self.buildFetchReminderRespondersRequest(reminderId: reminderId) else {
            throw ZaloTransportError.invalidURL("listResponseEvent")
        }
        let resp = try await get(
            service: spec.service,
            path: spec.path,
            encryptedPayload: spec.encryptedPayload
        )
        return ZaloJSONBox(resp)
    }
}
