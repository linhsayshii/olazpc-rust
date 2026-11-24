import Foundation

/// "Tin nhắn tự xóa" (official `getAutoDeleteConvers` / `updateAutoDeleteConvers`).
enum AutoDelete {
    /// The official choices (ms): 1 giờ, 1 ngày, 7 ngày, 14 ngày, 30 ngày; 0 = off.
    static let options: [(ttl: Int64, label: String)] = [
        (0, "Không bao giờ"),
        (3_600_000, "1 giờ"),
        (86_400_000, "1 ngày"),
        (604_800_000, "7 ngày"),
        (1_209_600_000, "14 ngày"),
        (2_592_000_000, "30 ngày"),
    ]

    static func label(_ ttl: Int64) -> String {
        options.first { $0.ttl == ttl }?.label ?? remaining(Double(ttl) / 1000)
    }

    /// "Tự xóa sau $0$": the time left, in the largest whole unit.
    static func remaining(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s >= 86_400 { return "\(s / 86_400) ngày" }
        if s >= 3_600 { return "\(s / 3_600) giờ" }
        if s >= 60 { return "\(s / 60) phút" }
        return "\(max(1, s)) giây"
    }

    /// `data.convers = [{destId, isGroup, ttl}]` → conversation id → ttl (ms), off entries dropped.
    static func settings(from data: [String: Any]) -> [String: Int64] {
        var out: [String: Int64] = [:]
        for row in (data["convers"] as? [[String: Any]]) ?? [] {
            let dest = JSONLossless.string(row["destId"] ?? row["threadId"])
            let isGroup = JSONLossless.int64(row["isGroup"]) == 1 || (row["isGroup"] as? Bool) == true
            let ttl = JSONLossless.int64(row["ttl"]) ?? 0
            guard !dest.isEmpty, ttl > 0 else { continue }
            let id = isGroup ? ZaloWireParser.groupConvId(dest) : ZaloWireParser.stripUserPrefix(dest)
            if !id.isEmpty { out[id] = ttl }
        }
        return out
    }

    /// Official `updateAutoDeleteConvers` params.
    static func updatePayload(convId: String, ttl: Int64) -> [String: Any] {
        let isGroup = ZaloWireParser.isGroupId(convId)
        let thread = isGroup ? ZaloWireParser.cleanGroupId(convId) : ZaloWireParser.stripUserPrefix(convId)
        return ["threadId": thread, "isGroup": isGroup ? 1 : 0, "ttl": ttl, "clientLang": "vi"]
    }
}

extension ZaloSessionClient {
    /// `conversation /api/conv/autodelete/getConvers` {}.
    func fetchAutoDeleteAPI() async throws -> [String: Int64] {
        let resp = try await get(service: "conversation", path: "/api/conv/autodelete/getConvers", encryptedPayload: [:])
        let data = resp["data"] as? [String: Any] ?? [:]
        await EngineLog.shared.write("autodelete: list keys=\(data.keys.sorted()) convers=\((data["convers"] as? [Any])?.count ?? -1)")
        return AutoDelete.settings(from: data)
    }

    /// `conversation /api/conv/autodelete/updateConvers` {threadId, isGroup, ttl, clientLang}.
    func updateAutoDeleteAPI(convId: String, ttl: Int64) async throws {
        _ = try await post(service: "conversation", path: "/api/conv/autodelete/updateConvers",
                           encryptedPayload: AutoDelete.updatePayload(convId: convId, ttl: ttl))
    }
}
