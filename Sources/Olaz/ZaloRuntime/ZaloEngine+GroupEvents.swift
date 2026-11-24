import Foundation

extension ZaloEngine {
    /// A group control (member added / left / removed / blocked, rename, avatar, admins): the official client writes an
    /// info line into the chat itself, since the server sends no message for it. Stored like any message, under an id
    /// built from the event, so a replayed control does not add the line twice. The member cache is dropped so the
    /// inspector reads the new member list.
    func handleGroupEventNotice(act: String, data: [String: Any], ts: Int64) async {
        let rawGroupId = JSONLossless.string(data["groupId"] ?? data["group_id"] ?? data["grid"])
        guard !rawGroupId.isEmpty, rawGroupId != "0" else { return }
        let convId = ZaloWireParser.groupConvId(rawGroupId)
        if ["join", "leave", "remove_member", "block_member", "add_admin", "remove_admin", "change_owner"].contains(act) {
            groupMemberCache[convId] = nil
            cachedGroupDetails[ZaloWireParser.cleanGroupId(rawGroupId)] = nil
        }
        let myUid = profile?.userId ?? ""
        guard let text = ZaloWireParser.groupEventNotice(act: act, data: data, myUid: myUid, name: { [weak self] uid in
            self?.lookupPersonInfo(uid)?.name
        }) else { return }
        // Seconds or milliseconds on the wire; fall back to now.
        let ms = ts > 100_000_000_000 ? ts : (ts > 0 ? ts * 1000 : Int64(Date().timeIntervalSince1970 * 1000))
        let members = ((data["updateMembers"] as? [[String: Any]]) ?? []).map { JSONLossless.string($0["id"]) }.joined(separator: ",")
        let id = "gevt-\(ZaloWireParser.cleanGroupId(rawGroupId))-\(act)-\(ms)-\(members)"
        if messages[convId]?.contains(where: { $0.id == id }) == true { return }
        let msg = ChatMessage(
            id: id, conversationId: convId, senderId: "", senderName: "", senderAvatar: nil, isMine: false,
            kind: .system, text: text, date: Date(timeIntervalSince1970: Double(ms) / 1000), status: .sent,
            quote: nil, reactions: [], isE2EE: false
        )
        mergeMessageIntoMemory(msg)
        if let stored = ZaloWireParser.encodeChatMessage(msg, clientId: id) {
            try? await sqliteStore?.saveMessages([stored])
        }
        updateConversationOnMessage(msg, incrementUnread: false)
    }
}
