import SwiftUI

/// "Tạo ghi chú": the note text and "Ghim lên đầu trò chuyện".
struct GroupNoteSheet: View {
    let groupId: String

    @Environment(ZaloEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var pin = true
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Tạo ghi chú") { dismiss() }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                TextField("Nhập nội dung ghi chú", text: $text, axis: .vertical)
                    .lineLimit(4...10)
                    .textFieldStyle(.roundedBorder)
                Toggle("Ghim lên đầu trò chuyện", isOn: $pin)
                HStack {
                    Spacer()
                    Button("Hủy") { dismiss() }
                    Button("Tạo ghi chú") {
                        Task {
                            busy = true
                            if await engine.createGroupNote(groupId, text: text.trimmingCharacters(in: .whitespacesAndNewlines), pin: pin) {
                                dismiss()
                            }
                            busy = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
        }
        .frame(width: 400)
    }
}
