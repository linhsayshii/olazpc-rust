import Foundation

extension ZaloEngine {
    /// Whether I blocked this 1-1 conversation's user (known once the list is loaded).
    func isBlocked(_ uid: String) -> Bool {
        let clean = ZaloWireParser.stripUserPrefix(uid)
        return blockedUsers?.contains { $0.id == clean } ?? false
    }

    /// Reads the blocked list (Cài đặt ▸ Quyền riêng tư ▸ Tài khoản đã chặn, and the chat banner).
    func loadBlockedUsers() async {
        guard let list = try? await sessionClient.fetchBlockedUsersAPI() else {
            if blockedUsers == nil { blockedUsers = [] }
            return
        }
        blockedUsers = list
    }

    /// "Chặn tin nhắn" / "Bỏ chặn" (official `setBlockFriend`), with the official toasts.
    func setBlocked(_ uid: String, blocked: Bool, name: String = "") async {
        let clean = ZaloWireParser.stripUserPrefix(uid)
        guard !clean.isEmpty else { return }
        let conversation = openConversationId
        do {
            try await sessionClient.setBlockedAPI(uid: clean, blocked: blocked)
            var list = blockedUsers ?? []
            list.removeAll { $0.id == clean }
            if blocked {
                let info = lookupPersonInfo(clean)
                let shown = name.isEmpty ? (info?.name ?? "") : name
                list.insert(BlockedUser(id: clean, name: shown, avatar: info.flatMap { URL(string: $0.avatar) }), at: 0)
            }
            blockedUsers = list
            CardActionCenter.shared.show(blocked ? "Bạn đã chặn tin nhắn và cuộc gọi từ người này" : "Bỏ chặn thành công", in: conversation)
        } catch {
            CardActionCenter.shared.show(
                blocked ? "Chặn bạn không thành công. Vui lòng thử lại sau" : "Bỏ chặn bạn không thành công. Vui lòng thử lại sau",
                in: conversation)
        }
    }
}
