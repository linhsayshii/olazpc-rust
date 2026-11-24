import Foundation

/// "Báo xấu" (official `reportUser`): a person (type 2) or a group (type 14) with a reason.
enum ReportReason: Int, CaseIterable, Identifiable, Sendable {
    case sensitive = 1, annoying = 2, fraud = 3, other = 0
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .sensitive: "Nội dung nhạy cảm"
        case .annoying: "Làm phiền"
        case .fraud: "Lừa đảo"
        case .other: "Lý do khác"
        }
    }

    /// Official `_sendRequest` params: {uidTo (bare id), type, reason, content, imei}.
    static func payload(convId: String, reason: ReportReason, content: String, imei: String) -> [String: Any] {
        let isGroup = ZaloWireParser.isGroupId(convId)
        return [
            "uidTo": isGroup ? ZaloWireParser.cleanGroupId(convId) : ZaloWireParser.stripUserPrefix(convId),
            "type": isGroup ? 14 : 2,
            "reason": reason.rawValue,
            "content": content.trimmingCharacters(in: .whitespacesAndNewlines),
            "imei": imei,
        ]
    }
}

extension ZaloSessionClient {
    /// POST `profile /api/social/profile/reportabuse`.
    func reportAPI(convId: String, reason: ReportReason, content: String) async throws {
        _ = try await post(service: "profile", path: "/api/social/profile/reportabuse",
                           encryptedPayload: ReportReason.payload(convId: convId, reason: reason, content: content, imei: imei))
    }
}

extension ZaloEngine {
    @discardableResult
    func report(_ convId: String, reason: ReportReason, content: String) async -> Bool {
        do {
            try await sessionClient.reportAPI(convId: convId, reason: reason, content: content)
            CardActionCenter.shared.show("Báo xấu thành công", in: convId)
            return true
        } catch {
            CardActionCenter.shared.show("Không thể báo xấu, vui lòng thử lại", in: convId)
            return false
        }
    }
}
