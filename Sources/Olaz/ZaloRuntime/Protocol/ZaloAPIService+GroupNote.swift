import Foundation

/// "Tạo ghi chú" (official `createGroupTopicv2` with type 0): a note on the group board, optionally pinned on top.
enum GroupNote {
    static func payload(groupId: String, text: String, pin: Bool, imei: String) -> [String: Any] {
        let params = (try? JSONSerialization.data(withJSONObject: ["title": text]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return [
            "grid": ZaloWireParser.cleanGroupId(groupId), "type": 0, "color": -16_777_216, "emoji": "",
            "startTime": -1, "duration": -1, "params": params, "pinAct": pin ? 1 : 0, "repeat": 0, "src": -1, "imei": imei,
        ]
    }
}

extension ZaloSessionClient {
    /// POST `group_board /api/board/topic/createv2`.
    func createGroupNoteAPI(groupId: String, text: String, pin: Bool) async throws {
        _ = try await post(service: "group_board", path: "/api/board/topic/createv2",
                           encryptedPayload: GroupNote.payload(groupId: groupId, text: text, pin: pin, imei: imei))
    }
}

extension ZaloEngine {
    @discardableResult
    func createGroupNote(_ groupId: String, text: String, pin: Bool) async -> Bool {
        let gid = ZaloWireParser.groupConvId(groupId)
        do {
            try await sessionClient.createGroupNoteAPI(groupId: groupId, text: text, pin: pin)
        } catch {
            let code = (error as? ZaloSessionError)?.code
            CardActionCenter.shared.show(code == 166 ? "Chỉ trưởng/phó nhóm được phép tạo ghi chú, nhắc hẹn" : "Không thể tạo ghi chú", in: gid)
            return false
        }
        if pin { await refreshBoardPins(for: gid) }
        CardActionCenter.shared.show("Đã tạo ghi chú", in: gid)
        return true
    }
}
