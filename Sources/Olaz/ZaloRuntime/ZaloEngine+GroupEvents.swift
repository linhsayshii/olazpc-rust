import Foundation
import OlazCore

extension ZaloEngine {
    /// A group control (member added / left / removed / blocked, rename, avatar, admins): delegated
    /// to `olaz-core` (`Command::HandleGroupEventNotice`), which invalidates group caches, appends
    /// the deduplicated synthetic system message, persists it, and updates the conversation preview.
    func handleGroupEventNotice(act: String, data: [String: Any], ts: Int64) async {
        guard let core = await ensureCoreEngine() else { return }
        let dataJson = Self.jsonString(for: data)
        if let v = try? await core.handleGroupEventNotice(act: act, dataJson: dataJson, ts: ts, nowMs: nowMs()) {
            await waitForMirrorVersion(v)
        }
    }
}
