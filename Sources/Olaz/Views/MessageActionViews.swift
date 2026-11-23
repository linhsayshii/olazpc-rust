import SwiftUI

// Native stand-ins for what the official message menu opens (ZaloEngine+MessageActions.swift): the SHARE_MSG_COMPOSE picker of
// "Chia sẻ", the "N tin nhắn đã xóa · Khôi phục" snackbar, the pinned bar above the chat (official topic banner) and the confirms.
// Attached once to the chat (`messageActionPresenter(conversationId:)`); nothing of one conversation shows in another (the engine drops
// a pending picker / confirm when another conversation opens, and each is presented only in its own conversation).

// MARK: - Chia sẻ

/// The conversations a message is forwarded to — the official SHARE_MSG_COMPOSE picker, native.
struct ForwardSheet: View {
    let request: ForwardRequest

    /// Official `forward_conv_limit` (live config and default: 100).
    static let maxTargets = 100

    @Environment(ZaloEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selected: [String] = []
    @State private var busy = false
    @State private var failure: String?

    private var rows: [ZaloEngine.ConversationSummary] {
        let all = engine.visibleConversations.sorted { ($0.preview?.date ?? .distantPast) > ($1.preview?.date ?? .distantPast) }
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return all }
        return all.filter { title(of: $0).range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Chia sẻ") { dismiss() }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                ForwardPreview(message: request.message)
                TextField("Tìm kiếm hội thoại cần chia sẻ", text: $search).textFieldStyle(.roundedBorder)
            }
            .padding(16)
            List(rows) { conversation in
                row(conversation)
            }
            .listStyle(.plain)
            Divider()
            SheetFooter(message: failure, hint: selected.isEmpty ? "Chọn hội thoại để chia sẻ" : "Đã chọn \(selected.count)",
                        action: "Chia sẻ", busy: busy, disabled: selected.isEmpty, cancel: { dismiss() }) {
                Task { await send() }
            }
        }
        .frame(width: 440, height: 580)
    }

    private func row(_ conversation: ZaloEngine.ConversationSummary) -> some View {
        let isOn = selected.contains(conversation.id)
        return Button {
            if isOn { selected.removeAll { $0 == conversation.id } }
            else if selected.count < Self.maxTargets { selected.append(conversation.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16)).foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                RemoteAvatar(url: conversation.avatar, name: conversation.displayName, size: 30)
                Text(title(of: conversation)).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isOn && selected.count >= Self.maxTargets)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func title(of conversation: ZaloEngine.ConversationSummary) -> String {
        conversation.id == engine.selfConversationId ? "Cloud của tôi" : conversation.displayName
    }

    private func send() async {
        guard !selected.isEmpty, !busy else { return }
        busy = true; failure = nil
        let outcome = await engine.forward(request.message, to: selected)
        busy = false
        switch outcome {
        case .done(let text):
            CardActionCenter.shared.show(text ?? "Đã chia sẻ tin nhắn", in: request.conversationId)
            dismiss()
        case .pending(let text):
            CardActionCenter.shared.show(text, in: request.conversationId)
            dismiss()
        case .failed(let text):
            failure = text
        case .confirm:
            failure = "Có lỗi khi chia sẻ tin nhắn"
        }
    }
}

/// "Nội dung chia sẻ": what is being forwarded, as a small card.
private struct ForwardPreview: View {
    let message: ChatMessage

    var body: some View {
        HStack(spacing: 10) {
            if let thumbnail {
                RemoteImage(url: thumbnail, contentMode: .fill, maxPixelSize: 120) { Rectangle().fill(.quaternary) }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Nội dung chia sẻ").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(message.text.isEmpty ? "Tin nhắn" : message.text).font(.system(size: 12.5)).lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private var thumbnail: URL? {
        switch message.kind {
        case .photo(let url, _, _): message.isE2EE ? nil : url
        case .video(let thumbnail, _, _): thumbnail
        case .gif(let url), .sticker(let url): url
        case .link(_, _, let thumbnail, _, _): thumbnail
        default: nil
        }
    }
}

// MARK: - Pinned bar

/// The conversation's pins above its messages, Telegram style: one pin at a time with a segmented indicator; clicking jumps to
/// it and steps to the next (older) pin, sliding the text; the list button opens every pin ("Danh sách ghim") with unpin.
struct PinnedBar: View {
    let conversationId: String
    var open: (PinnedItem) -> Void

    @Environment(ZaloEngine.self) private var engine
    /// Index into the newest-first items of the pin shown.
    @State private var index = 0
    /// The text slides up when stepping to an older pin, down when going back.
    @State private var towardOlder = true
    @State private var listShown = false
    @State private var hovered = false

    private static let motion = Animation.snappy(duration: 0.3, extraBounce: 0.04)

    var body: some View {
        let list = engine.pins[conversationId]
        let items = list?.ready == true ? list?.items ?? [] : []
        ZStack {
            if !items.isEmpty, let list {
                bar(items: items, list: list)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Self.motion, value: items.isEmpty)
        .animation(Self.motion, value: items.map(\.ref))
        .onChange(of: items.map(\.ref)) { old, new in
            // A new pin shows itself (newest first); otherwise keep the shown pin where it still is.
            if let first = new.first, !old.contains(first) {
                towardOlder = false
                index = 0
            } else if let shown = old.indices.contains(index) ? old[index] : nil, let at = new.firstIndex(of: shown) {
                index = at
            } else {
                index = min(index, max(0, new.count - 1))
            }
        }
        .onChange(of: conversationId) { _, _ in
            index = 0
            listShown = false
        }
    }

    @ViewBuilder
    private func bar(items: [PinnedItem], list: PinnedList) -> some View {
        let current = items[min(index, items.count - 1)]
        HStack(spacing: 10) {
            PinSegmentIndicator(count: items.count, position: items.count - 1 - min(index, items.count - 1))
            Button { activate(current, items: items) } label: {
                HStack(spacing: 8) {
                    ZStack(alignment: .leading) {
                        PinBarContent(item: current, number: items.count > 1 ? items.count - min(index, items.count - 1) : nil)
                            .id(current.ref)
                            .transition(.asymmetric(
                                insertion: .move(edge: towardOlder ? .bottom : .top).combined(with: .opacity),
                                removal: .move(edge: towardOlder ? .top : .bottom).combined(with: .opacity)
                            ))
                    }
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .clipped()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(items.count > 1 ? "Xem tin nhắn · bấm tiếp để xem ghim khác" : (current.title.isEmpty ? current.label : current.title))
            .contextMenu {
                Button(current.kind == .message ? "Xem tin nhắn" : "Xem", systemImage: "arrow.right.circle") { open(current) }
                if items.count > 1 {
                    Button("Danh sách ghim (\(items.count))", systemImage: "list.bullet") { listShown = true }
                }
                if list.canPin {
                    Divider()
                    Button("Bỏ ghim", systemImage: "pin.slash", role: .destructive) { engine.requestUnpin(current, in: conversationId) }
                }
            }
            if items.count > 1 {
                Button { listShown.toggle() } label: {
                    Image(systemName: "list.bullet").font(.system(size: 13, weight: .medium)).frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Danh sách ghim (\(items.count))")
                .popover(isPresented: $listShown, arrowEdge: .bottom) {
                    PinListPopover(conversationId: conversationId, canPin: list.canPin) { item in
                        listShown = false
                        if let at = items.firstIndex(of: item) { step(to: at) }
                        open(item)
                    }
                }
            } else if list.canPin {
                Button { engine.requestUnpin(current, in: conversationId) } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Bỏ ghim")
            }
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
        .background(hovered ? AnyShapeStyle(.primary.opacity(0.04)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tin nhắn đã ghim")
    }

    /// Jump to the shown pin, then show the next older one (wrapping to the newest), as Telegram does.
    private func activate(_ item: PinnedItem, items: [PinnedItem]) {
        open(item)
        guard items.count > 1 else { return }
        step(to: (min(index, items.count - 1) + 1) % items.count)
    }

    private func step(to target: Int) {
        guard target != index else { return }
        towardOlder = target > index
        withAnimation(Self.motion) { index = target }
    }
}

/// The shown pin: "Tin nhắn đã ghim #n" over its text, with a thumbnail for media.
private struct PinBarContent: View {
    let item: PinnedItem
    let number: Int?

    var body: some View {
        HStack(spacing: 8) {
            if let thumbnail = item.thumbnail {
                RemoteImage(url: thumbnail, contentMode: .fill, maxPixelSize: 80) { Rectangle().fill(.quaternary) }
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(heading).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.tint).lineLimit(1)
                Text(line).font(.system(size: 12.5)).lineLimit(1)
            }
        }
    }

    private var heading: String {
        let base = item.kind == .message ? "Tin nhắn đã ghim" : item.label
        return number.map { "\(base) #\($0)" } ?? base
    }

    private var line: String {
        let text = item.title.isEmpty ? item.label : item.title
        return item.sender.isEmpty ? text : "\(item.sender): \(text)"
    }
}

/// Telegram's pinned indicator: one segment per pin, the shown one lit; the lit segment glides between positions.
struct PinSegmentIndicator: View {
    let count: Int
    /// 0 = top segment.
    let position: Int

    var body: some View {
        let n = max(1, count)
        GeometryReader { geo in
            let gap: CGFloat = n > 1 ? 2 : 0
            let segment = max(2, (geo.size.height - gap * CGFloat(n - 1)) / CGFloat(n))
            ZStack(alignment: .top) {
                VStack(spacing: gap) {
                    ForEach(0..<n, id: \.self) { _ in Capsule().fill(.tint.opacity(0.28)) }
                }
                Capsule().fill(.tint)
                    .frame(height: segment)
                    .offset(y: CGFloat(min(max(0, position), n - 1)) * (segment + gap))
            }
        }
        .frame(width: 2.5, height: 30)
        .animation(.snappy(duration: 0.3), value: position)
        .animation(.snappy(duration: 0.3), value: count)
        .accessibilityHidden(true)
    }
}

/// "Danh sách ghim (N)": every pin, newest first; a row opens its pin, "Bỏ ghim" asks to unpin it.
private struct PinListPopover: View {
    let conversationId: String
    let canPin: Bool
    var open: (PinnedItem) -> Void
    @Environment(ZaloEngine.self) private var engine

    var body: some View {
        let items = engine.pins[conversationId]?.items ?? []
        VStack(alignment: .leading, spacing: 0) {
            Text("Danh sách ghim (\(items.count))")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
            ForEach(items) { item in
                PinListRow(item: item, canPin: canPin, open: { open(item) }) {
                    engine.requestUnpin(item, in: conversationId)
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .padding(.bottom, 8)
        .frame(width: 340)
        .animation(.snappy(duration: 0.25), value: items.map(\.ref))
    }
}

private struct PinListRow: View {
    let item: PinnedItem
    let canPin: Bool
    var open: () -> Void
    var unpin: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(.tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title.isEmpty ? item.label : item.title).font(.system(size: 12.5)).lineLimit(2)
                Text(item.sender.isEmpty ? item.label : "\(item.label) của \(item.sender)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if canPin {
                Button("Bỏ ghim", action: unpin)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .opacity(hovered ? 1 : 0.6)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(hovered ? AnyShapeStyle(.primary.opacity(0.06)) : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private var icon: String {
        switch item.kind {
        case .message: "text.bubble"
        case .note, .link: "note.text"
        case .poll: "chart.bar"
        case .reminder: "alarm"
        }
    }
}

// MARK: - Undo of a delete

/// "N tin nhắn đã xóa · Khôi phục (s)": the official snackbar of a delete-for-me, counting down to its deadline.
private struct DeleteUndoBar: View {
    let undo: DeleteUndo
    @Environment(ZaloEngine.self) private var engine

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Int(undo.deadline.timeIntervalSince(context.date).rounded(.up)))
            HStack(spacing: 10) {
                Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(.secondary)
                Text("\(undo.count) tin nhắn đã xóa").font(.system(size: 12.5, weight: .medium))
                Button("Khôi phục (\(left))") { engine.undoDelete() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                Button("Đóng", systemImage: "xmark") { engine.dismissDeleteUndo() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Xóa ngay")
            }
            .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 6)
            .glassEffect(.regular, in: Capsule())
        }
    }
}

// MARK: - Presenter

private struct MessageActionPresenter: ViewModifier {
    let conversationId: String
    @Environment(ZaloEngine.self) private var engine

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { engine.forwardRequest?.conversationId == conversationId ? engine.forwardRequest : nil },
                                 set: { engine.forwardRequest = $0 })) { request in
                ForwardSheet(request: request).cardNoticeOverlay()
            }
            // Answered only by its buttons (the dismissal binding must not answer first and turn an OK into a cancel).
            .alert(engine.messageConfirm?.title ?? "", isPresented: Binding(get: { engine.messageConfirm?.conversationId == conversationId }, set: { _ in }),
                   presenting: engine.messageConfirm) { confirm in
                Button(confirm.ok, role: confirm.destructive ? .destructive : nil) { engine.answerMessageConfirm(confirm, ok: true) }
                Button(confirm.cancel, role: .cancel) { engine.answerMessageConfirm(confirm, ok: false) }
            } message: { confirm in
                Text(confirm.message)
            }
            .overlay(alignment: .bottom) {
                if let undo = engine.deleteUndo, undo.conversationId == conversationId {
                    DeleteUndoBar(undo: undo)
                        .padding(.bottom, 84)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.snappy, value: engine.deleteUndo)
    }
}

extension View {
    /// Hosts the forward picker, the confirms and the delete undo of message actions (attach once, to the chat).
    func messageActionPresenter(conversationId: String) -> some View {
        modifier(MessageActionPresenter(conversationId: conversationId))
    }
}
