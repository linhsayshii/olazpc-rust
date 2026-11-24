import Foundation

/// GIF search and send (official `searchGif` / `getGifTrending` on the sticker host, `sendGif` on the file host).
struct GifItem: Identifiable, Equatable, Sendable {
    let id: String
    var url: URL
    var thumb: URL
    var width: Int
    var height: Int

    /// A result row; the fields differ between endpoints, so several names are read.
    static func from(_ row: [String: Any]) -> GifItem? {
        func str(_ keys: [String]) -> String { keys.map { JSONLossless.string(row[$0]) }.first { !$0.isEmpty } ?? "" }
        func nested(_ key: String) -> [String: Any]? { row[key] as? [String: Any] }
        // Official rows: {id, original|hd|normal|preview: {url, width, height}}.
        let original = nested("original") ?? nested("hd") ?? nested("normal") ?? nested("gif")
        let small = nested("preview") ?? nested("normal")
        let flat = str(["url", "gifUrl", "gif_url", "href", "link"])
        let urlStr = flat.isEmpty ? JSONLossless.string(original?["url"]) : flat
        let flatThumb = str(["thumb", "thumbUrl", "thumb_url", "still"])
        let thumbStr = flatThumb.isEmpty ? JSONLossless.string(small?["url"]) : flatThumb
        guard let url = URL(string: urlStr), !urlStr.isEmpty else { return nil }
        let width = Int(JSONLossless.int64(row["width"] ?? original?["width"]) ?? 200)
        let height = Int(JSONLossless.int64(row["height"] ?? original?["height"]) ?? 200)
        let id = str(["id", "contentId", "content_id"])
        return GifItem(id: id.isEmpty ? urlStr : id, url: url, thumb: URL(string: thumbStr) ?? url,
                       width: max(1, width), height: max(1, height))
    }

    static func list(from resp: [String: Any]) -> [GifItem] {
        let data = resp["data"]
        let rows: [[String: Any]] = (data as? [[String: Any]])
            ?? ((data as? [String: Any]).flatMap { ($0["data_list"] ?? $0["gifs"] ?? $0["data"] ?? $0["items"] ?? $0["list"]) as? [[String: Any]] })
            ?? []
        return rows.compactMap(from)
    }
}

extension ZaloSessionClient {
    /// `sticker /api/message/giphy/search` {keyword, offset, limit}, or trending {offset, limit, imei} for an empty query.
    func searchGifAPI(_ keyword: String, offset: Int = 0, limit: Int = 24) async throws -> [GifItem] {
        let q = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let resp = q.isEmpty
            ? try await get(service: "sticker", path: "/api/message/giphy/trending", encryptedPayload: ["offset": offset, "limit": limit, "imei": imei])
            : try await get(service: "sticker", path: "/api/message/giphy/search", encryptedPayload: ["keyword": q, "offset": offset, "limit": limit])
        let items = GifItem.list(from: resp)
        if items.isEmpty {
            let data = resp["data"]
            let shape = (data as? [String: Any]).map { "dict keys=\($0.keys.sorted())" }
                ?? (data as? [Any]).map { "array n=\($0.count) first=\((($0.first as? [String: Any])?.keys.sorted()) ?? [])" } ?? "none"
            await EngineLog.shared.write("gif: empty parse data=\(shape)")
        }
        return items
    }

    /// Official `sendGif`: `file /api/message/gif` · `/api/group/gif` {thumb, width, height, msg, type 0, href, contentId, toid|grid, clientId}.
    func sendGifAPI(convId: String, gif: GifItem, clientId: Int64) async throws {
        let isGroup = ZaloWireParser.isGroupId(convId)
        var p: [String: Any] = [
            "thumb": gif.thumb.absoluteString, "width": gif.width, "height": gif.height, "msg": "", "type": 0,
            "href": gif.url.absoluteString, "contentId": gif.id, "clientId": "\(clientId)", "imei": imei, "ttl": 0,
        ]
        if isGroup {
            p["grid"] = ZaloWireParser.cleanGroupId(convId)
            p["visibility"] = 0
        } else {
            p["toid"] = ZaloWireParser.stripUserPrefix(convId)
        }
        _ = try await get(service: "file", path: isGroup ? "/api/group/gif" : "/api/message/gif", encryptedPayload: p)
    }
}

extension ZaloEngine {
    func searchGifs(_ keyword: String) async -> [GifItem] {
        (try? await sessionClient.searchGifAPI(keyword)) ?? []
    }

    /// Sends a GIF; the message itself arrives back over the socket like any own message.
    @discardableResult
    func sendGif(_ gif: GifItem, to convId: String) async -> Bool {
        let cli = await sessionClient.nextClientId()
        do {
            try await sessionClient.sendGifAPI(convId: convId, gif: gif, clientId: cli)
            return true
        } catch {
            EngineLog.shared.write("gif: send failed")
            CardActionCenter.shared.show("Không gửi được GIF", in: convId)
            return false
        }
    }
}
