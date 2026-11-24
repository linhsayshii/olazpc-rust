import Foundation

/// "Tin nhắn nhanh" (official `fetchQuickReplyList` / `createQuickReplyItem` …): a keyword typed after "/" inserts a saved text.
struct QuickMessage: Identifiable, Equatable, Sendable {
    let id: String
    var keyword: String
    var text: String

    /// `list` → {items:[{id, keyword, message:{title, params}}], version}.
    static func list(from data: [String: Any]) -> [QuickMessage] {
        ((data["items"] as? [[String: Any]]) ?? []).compactMap { row in
            let id = JSONLossless.string(row["id"] ?? row["itemId"])
            let keyword = JSONLossless.string(row["keyword"])
            let message = row["message"] as? [String: Any]
            let text = JSONLossless.string(message?["title"] ?? row["message"])
            guard !id.isEmpty, !keyword.isEmpty else { return nil }
            return QuickMessage(id: id, keyword: keyword, text: text)
        }
    }

    /// Official create / update params: {keyword, message:{title, params:""}, type:0, media}.
    static func payload(keyword: String, text: String) -> [String: Any] {
        ["keyword": keyword.trimmingCharacters(in: .whitespacesAndNewlines),
         "message": ["title": text, "params": ""], "type": 0, "media": NSNull()]
    }

    /// Quick messages whose keyword starts with what follows "/" in the draft.
    static func matches(_ draft: String, in all: [QuickMessage]) -> [QuickMessage] {
        guard draft.hasPrefix("/"), !draft.contains("\n") else { return [] }
        let needle = draft.dropFirst().lowercased()
        return all.filter { needle.isEmpty || $0.keyword.lowercased().hasPrefix(needle) }
    }
}

extension ZaloSessionClient {
    func fetchQuickMessagesAPI() async throws -> [QuickMessage] {
        let resp = try await get(service: "quick_message", path: "/api/quickmessage/list",
                                 encryptedPayload: ["version": 0, "lang": 0, "imei": imei])
        return QuickMessage.list(from: resp["data"] as? [String: Any] ?? [:])
    }

    func createQuickMessageAPI(keyword: String, text: String) async throws {
        var p = QuickMessage.payload(keyword: keyword, text: text)
        p["imei"] = imei
        _ = try await get(service: "quick_message", path: "/api/quickmessage/create", encryptedPayload: p)
    }

    func updateQuickMessageAPI(id: String, keyword: String, text: String) async throws {
        var p = QuickMessage.payload(keyword: keyword, text: text)
        p["itemId"] = Int64(id) ?? 0
        _ = try await get(service: "quick_message", path: "/api/quickmessage/update", encryptedPayload: p)
    }

    func deleteQuickMessageAPI(id: String) async throws {
        _ = try await get(service: "quick_message", path: "/api/quickmessage/delete", encryptedPayload: ["itemIds": [Int64(id) ?? 0]])
    }
}

extension ZaloEngine {
    func loadQuickMessages() async {
        do {
            quickMessages = try await sessionClient.fetchQuickMessagesAPI()
        } catch {
            EngineLog.shared.write("quickmessage: list failed")
            if quickMessages == nil { quickMessages = [] }
        }
    }

    /// Creates (no `id`) or edits a quick message, then reads the list again.
    @discardableResult
    func saveQuickMessage(id: String?, keyword: String, text: String) async -> Bool {
        do {
            if let id { try await sessionClient.updateQuickMessageAPI(id: id, keyword: keyword, text: text) }
            else { try await sessionClient.createQuickMessageAPI(keyword: keyword, text: text) }
        } catch {
            EngineLog.shared.write("quickmessage: save failed")
            return false
        }
        await loadQuickMessages()
        return true
    }

    func deleteQuickMessage(_ id: String) async {
        guard (try? await sessionClient.deleteQuickMessageAPI(id: id)) != nil else { return }
        quickMessages?.removeAll { $0.id == id }
    }
}
