import Foundation
import OlazCore

extension ZaloEngine {
    /// Whether I blocked this 1-1 conversation's user (known once the list is loaded).
    func isBlocked(_ uid: String) -> Bool {
        let clean = ZaloWireParser.stripUserPrefix(uid)
        let sanitized = ZaloWireParser.sanitizeProfileUid(clean) ?? clean
        return blockedUsers?.contains { u in
            let uc = ZaloWireParser.stripUserPrefix(u.id)
            let us = ZaloWireParser.sanitizeProfileUid(uc) ?? uc
            return uc == clean || us == sanitized
        } ?? false
    }

    /// Reads the blocked list (Cài đặt ▸ Quyền riêng tư ▸ Tài khoản đã chặn, and the chat banner).
    func loadBlockedUsers() async {
        guard let core = await ensureCoreEngine() else { return }
        if let v = try? await core.loadBlockedUsers() {
            await waitForMirrorVersion(v)
        }
    }

    /// "Chặn tin nhắn" / "Bỏ chặn" (official `setBlockFriend`), with the official toasts.
    func setBlocked(_ uid: String, blocked: Bool, name: String = "") async {
        guard let core = await ensureCoreEngine() else { return }
        if let v = try? await core.setBlocked(uid: uid, blocked: blocked, name: name) {
            await waitForMirrorVersion(v)
        }
    }
}
