import SwiftUI

/// "GIF": trending at first, a search field, a click sends.
struct GifPicker: View {
    let conversationId: String
    var done: () -> Void = {}

    @Environment(ZaloEngine.self) private var engine
    @State private var query = ""
    @State private var items: [GifItem]?
    @State private var sending: String?

    var body: some View {
        VStack(spacing: 8) {
            TextField("Tìm kiếm GIF", text: $query).textFieldStyle(.roundedBorder)
                .onSubmit { Task { await load() } }
            if let items {
                if items.isEmpty {
                    Text("Không tìm thấy GIF").foregroundStyle(.secondary).frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                            ForEach(items) { gif in
                                Button {
                                    Task {
                                        sending = gif.id
                                        if await engine.sendGif(gif, to: conversationId) { done() }
                                        sending = nil
                                    }
                                } label: {
                                    AsyncImage(url: gif.thumb) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: { Color.primary.opacity(0.06) }
                                    .frame(width: 96, height: 96)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay { if sending == gif.id { ProgressView().controlSize(.small) } }
                                }
                                .buttonStyle(.plain)
                                .disabled(sending != nil)
                            }
                        }
                    }
                }
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .padding(10)
        .frame(width: 340, height: 380)
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(query.isEmpty ? 0 : 400))
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    private func load() async {
        items = await engine.searchGifs(query)
    }
}
