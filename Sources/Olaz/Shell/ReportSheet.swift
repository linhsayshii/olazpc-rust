import SwiftUI

/// "Báo xấu": the official reasons, a note for "Lý do khác", then the report.
struct ReportSheet: View {
    let conversationId: String
    let name: String

    @Environment(ZaloEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var reason: ReportReason = .sensitive
    @State private var content = ""
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Báo xấu") { dismiss() }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Chọn lý do báo xấu \(name)").font(.system(size: 13, weight: .semibold))
                Picker("", selection: $reason) {
                    ForEach(ReportReason.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if reason == .other {
                    TextField("Nhập lý do", text: $content, axis: .vertical)
                        .lineLimit(3...5)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Spacer()
                    Button("Hủy") { dismiss() }
                    Button("Báo xấu") {
                        Task {
                            busy = true
                            if await engine.report(conversationId, reason: reason, content: content) { dismiss() }
                            busy = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || (reason == .other && content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
            .padding(16)
        }
        .frame(width: 380)
    }
}
