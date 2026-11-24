import AppKit
import Foundation

/// One Olaz process per data directory. Two processes on the same `ZaloData/` share one SQLite Signal session store:
/// each advances the ratchet on its own copy, so peers fail to decrypt ("Đã xảy ra lỗi. Nhờ … gửi lại tin nhắn"),
/// and the two WebSocket sessions keep kicking each other. The lock is an `flock` held for the process lifetime;
/// the kernel drops it when the process exits or crashes, so a stale file never blocks a launch.
enum InstanceLock {
    /// Kept open for the process lifetime; closing it releases the lock.
    nonisolated(unsafe) private static var heldFD: Int32 = -1

    static var lockURL: URL {
        ZaloPlatform.defaultUserData.deletingLastPathComponent().appendingPathComponent("instance.lock")
    }

    /// True when this process now holds the lock (or already held it). False when another process holds it.
    @discardableResult
    static func acquire(at url: URL = lockURL) -> Bool {
        if heldFD >= 0 { return true }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return true }   // Can't create the file: don't block the user over it.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        heldFD = fd
        return true
    }

    /// Releases the lock (tests only; the app keeps it until exit).
    static func release() {
        guard heldFD >= 0 else { return }
        flock(heldFD, LOCK_UN)
        close(heldFD)
        heldFD = -1
    }

    /// GUI launch: if another Olaz holds the data, bring it forward, explain, and quit this one.
    @MainActor
    static func ensureSingleAppInstance() {
        guard !acquire() else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me }
        if let other = others.first {
            other.activate()
        } else {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate()
            let alert = NSAlert()
            alert.messageText = "\(AppBrand.name) đang mở"
            alert.informativeText = "Một cửa sổ \(AppBrand.name) khác đang dùng dữ liệu và phiên đăng nhập này. Chạy hai bản cùng lúc sẽ làm hỏng tin nhắn mã hoá, nên bản này sẽ đóng lại."
            alert.addButton(withTitle: "Đóng")
            alert.runModal()
        }
        exit(0)
    }
}
