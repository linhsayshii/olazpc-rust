import SwiftUI

/// "Chọn nhiều tin nhắn": replaces the composer while messages are being picked (official `Đã chọn: $0$` bar).
struct MessageSelectionBar: View {
    let selection: MessageSelection

    @Environment(ZaloEngine.self) private var engine

    var body: some View {
        let list = engine.selectedMessages()
        let empty = list.isEmpty
        HStack(spacing: 10) {
            Text("Đã chọn: \(list.count)")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
            Spacer(minLength: 8)
            Button("Chia sẻ", systemImage: "arrowshape.turn.up.right") { engine.forwardSelection() }
                .disabled(empty || !engine.selectionCanForward(list))
            if engine.selectionCanRecall(list) {
                Button("Thu hồi", systemImage: "arrow.uturn.backward") { engine.recallSelection() }
            }
            Button("Xóa", systemImage: "trash", role: .destructive) { engine.deleteSelection() }
                .disabled(empty)
            Button("Hủy") { engine.endSelection() }
                .keyboardShortcut(.cancelAction)
        }
        .controlSize(.regular)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.bar)
        .help("Bạn có thể chia sẻ, lưu hoặc xóa các tin nhắn đã chọn. Gợi ý: bấm giữ SHIFT để chọn nhiều tin nhắn liên tiếp.")
    }
}
