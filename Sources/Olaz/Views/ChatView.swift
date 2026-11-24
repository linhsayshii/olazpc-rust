import SwiftUI
import UniformTypeIdentifiers

/// Native chat pane for one conversation. All data comes from `ZaloEngine`.
///
/// The view stays alive when another chat is opened (`ConversationDetail` gives it no `.id`): rebuilding the whole chat, its
/// safe-area bars and composer, made AppKit re-tile the window toolbar and recompute the key-view loop on every switch. The
/// per-chat pieces below (message list, composer, read tracker) carry `.id(conversation.id)` instead, and the chat's own state
/// is reset in `startConversation()`.
struct ChatView: View {
    let conversation: ZaloEngine.ConversationSummary

    @Environment(ZaloEngine.self) private var engine
    @Environment(ShellModel.self) private var shell

    @State private var draft = ""
    @State private var draftMentions: [Mention] = []
    @State private var draftStyles: [TextStyle] = []
    @State private var draftUrgency = 0
    @State private var replyTo: ChatMessage?
    @State private var focusTick = 0
    @State private var sendTick = 0
    @State private var notice: SendNotice?
    /// A loaded message to bring on screen (a pin of the pinned bar or a search match).
    @State private var jumpTarget: String?
    @State private var searchOpen = false
    @State private var searchQuery = ""
    @State private var searchMatches: [ChatMessage] = []
    @State private var searchMatchIndex = 0
    @State private var searchSearching = false
    @State private var searchFocusTick = 0
    @State private var searchTask: Task<Void, Never>?
    @State private var jumpTask: Task<Void, Never>?
    @State private var jumpGeneration = 0
    @State private var highlightedMessageId: String?
    @State private var isDropTargeted = false

    private enum SendNotice { case restored, like }

    private var id: String { conversation.id }

    // The body reads nothing of `engine.messages` / `engine.typing`: those change for every conversation, and re-running this
    // body rebuilds the whole toolbar. The parts that show messages observe them in their own views below.
    var body: some View {
        @Bindable var shell = shell
        ChatMessagesPane(
            conversation: conversation,
            sendTick: sendTick,
            jumpTarget: $jumpTarget,
            highlightedMessageId: highlightedMessageId,
            onReply: reply
        )
        .background {
            ChatWallpaperBackground()
            Button("") { openSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            ChatReadTracker(conversation: conversation)
                .id(id)
        }
        .safeAreaBar(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if searchOpen {
                    MessageSearchBar(
                        query: $searchQuery,
                        matchIndex: searchMatchIndex,
                        matchCount: searchMatches.count,
                        isSearching: searchSearching,
                        focusTick: searchFocusTick,
                        onPrevious: { stepMatch(+1) },
                        onNext: { stepMatch(-1) },
                        onSubmit: { submitSearch() },
                        onClose: closeSearch
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                PinnedBar(conversationId: id, open: openPin)
            }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            if let selection = engine.messageSelection, selection.conversationId == id {
                MessageSelectionBar(selection: selection)
            } else if !conversation.isGroup, engine.isBlocked(id) {
                // Official: a blocked user's chat offers "Bỏ chặn" instead of the composer.
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised").foregroundStyle(.secondary)
                    Text("Bỏ chặn để gửi tin nhắn tới người này.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Bỏ chặn") { Task { await engine.setBlocked(id, blocked: false) } }
                        .buttonStyle(.borderedProminent)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(.bar)
            } else {
            ChatComposer(
                name: conversation.displayName,
                conversationId: id,
                isGroup: conversation.isGroup,
                draft: $draft,
                mentions: $draftMentions,
                styles: $draftStyles,
                urgency: $draftUrgency,
                replyTo: $replyTo,
                focusTick: focusTick,
                send: send,
                sendLike: {
                    sendTick += 1
                    let (engine, id) = (engine, id)
                    Task { if await !engine.sendText("👍", to: id) { notice = .like } }
                })
            .id(id)
            }
        }
        .task(id: id) {
            if !conversation.isGroup, engine.blockedUsers == nil { await engine.loadBlockedUsers() }
        }
        .task(id: id) {
            // "Tin nhắn tự xóa": the setting for the composer, then messages leave the chat when their time is over.
            if engine.autoDelete == nil { await engine.loadAutoDelete() }
            while !Task.isCancelled {
                let next = engine.pruneExpiredMessages(in: id)
                let wait = min(60, max(1, next.map { $0.timeIntervalSinceNow + 0.5 } ?? 60))
                try? await Task.sleep(for: .seconds(wait))
            }
        }
        .onChange(of: id) { _, _ in
            if engine.messageSelection != nil { engine.endSelection() }
        }
        .alert("Chưa gửi được tin nhắn", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice == .like ? "Không gửi được biểu tượng 👍. Hãy thử lại." : "Nội dung đã được trả lại vào ô soạn thảo. Hãy thử gửi lại.")
        }
        .cardActionPresenter()
        .messageActionPresenter(conversationId: id)
        .onAppear { startConversation() }
        .onChange(of: id) { _, _ in
            resetForAnotherConversation()
            startConversation()
        }
        .onChange(of: engine.failedDrafts.revision) { _, _ in restoreFailedDraft() }
        // ⌘R: reply to the newest incoming message.
        .onChange(of: shell.chatSearchTick) { _, _ in toggleSearch() }
        .onChange(of: shell.replyTick) { _, _ in
            if let newest = engine.messages(in: id)?.last(where: { !$0.isMine && !$0.kind.isStandalone && $0.kind != .recalled }) { reply(newest) }
        }
        .onChange(of: searchQuery) { _, newValue in
            scheduleSearch(for: newValue)
        }
        .onDisappear {
            searchTask?.cancel()
            jumpTask?.cancel()
        }
        .overlay {
            if isDropTargeted && !id.isEmpty {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        VStack(spacing: 10) {
                            Image(systemName: "arrow.down.doc.fill")
                                .font(.system(size: 32, weight: .semibold))
                                .foregroundStyle(.tint)
                            Text("Thả để gửi vào \(conversation.displayName)")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Ảnh, video hoặc tài liệu")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(24)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(.tint.opacity(0.45), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    }
                    .padding(16)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let targetId = id
        guard !targetId.isEmpty else { return false }
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }

        Task {
            var urls: [URL] = []
            for provider in fileProviders {
                if let url = await Self.loadDroppedFileURL(from: provider) {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return }
            let mediaURLs = urls.filter { Self.isMediaURL($0) }
            let fileURLs = urls.filter { !Self.isMediaURL($0) }
            if !mediaURLs.isEmpty {
                let outcome = await engine.sendMedia(mediaURLs, to: targetId)
                engine.report(outcome, in: targetId)
            }
            if !fileURLs.isEmpty {
                let outcome = await engine.sendFiles(fileURLs, to: targetId)
                engine.report(outcome, in: targetId)
            }
        }
        return true
    }

    private static func isMediaURL(_ url: URL) -> Bool {
        if let ut = UTType(filenameExtension: url.pathExtension), ut.conforms(to: .image) {
            return true
        }
        return ZaloEngine.isVideoURL(url)
    }

    private static func loadDroppedFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let str = String(data: data, encoding: .utf8),
                   let url = URL(string: str) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let nsurl = item as? NSURL {
                    continuation.resume(returning: nsurl as URL)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func startConversation() {
        focusTick += 1
        restoreFailedDraft()
    }

    /// What a freshly created chat view would start with (the view is reused for the next conversation).
    private func resetForAnotherConversation() {
        searchTask?.cancel()
        searchTask = nil
        jumpTask?.cancel()
        jumpTask = nil
        draft = ""
        draftMentions = []
        draftStyles = []
        draftUrgency = 0
        replyTo = nil
        notice = nil
        jumpTarget = nil
        searchOpen = false
        searchQuery = ""
        searchMatches = []
        searchMatchIndex = 0
        searchSearching = false
        highlightedMessageId = nil
        isDropTargeted = false
    }

    private func reply(_ message: ChatMessage) {
        replyTo = message
        focusTick += 1
    }

    /// A pin of the pinned bar: its message when it is loaded, a poll's detail, otherwise its full text.
    private func openPin(_ item: PinnedItem) {
        switch item.kind {
        case .message:
            // Loads it from the local store when it is older than the shown page, then scrolls there and flashes it.
            jumpGeneration += 1
            let gen = jumpGeneration
            jumpTask?.cancel()
            jumpTask = Task {
                guard let target = await engine.loadPinnedMessage(item, in: id) else {
                    if !Task.isCancelled {
                        CardActionCenter.shared.show("Tin nhắn đã ghim chưa được tải. Kéo lên để xem tin nhắn cũ hơn.", in: id)
                    }
                    return
                }
                guard !Task.isCancelled, gen == jumpGeneration else { return }
                try? await Task.sleep(for: .milliseconds(20))
                guard !Task.isCancelled, gen == jumpGeneration else { return }
                highlightedMessageId = target
                jumpTarget = target
                try? await Task.sleep(for: .seconds(1.6))
                if !searchOpen, gen == jumpGeneration, highlightedMessageId == target { highlightedMessageId = nil }
            }
        case .poll:
            if let pollId = item.ref.split(separator: ":").last.map(String.init), !pollId.isEmpty {
                CardActionCenter.shared.poll = PollRequest(conversationId: id, pollId: pollId)
            }
        case .note, .link, .reminder:
            CardActionCenter.shared.show(item.title.isEmpty ? item.label : item.title, in: id)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Untrimmed draft: the engine re-bases mention offsets when it trims.
        let (sentDraft, sentMentions, sentReply, sentStyles, sentUrgency) = (draft, draftMentions, replyTo, draftStyles, draftUrgency)
        draft = ""
        draftMentions = []
        draftStyles = []
        draftUrgency = 0
        replyTo = nil
        sendTick += 1
        let (engine, id) = (engine, id)
        Task {
            guard await !engine.sendText(sentDraft, to: id, quoting: sentReply?.id, mentions: sentMentions, styles: sentStyles,
                                         urgency: sentUrgency) else { return }
            // Nothing was sent. The view may be gone by now (conversation switched): the engine keeps the text and the
            // composer shown for this conversation takes it back (`restoreFailedDraft`).
            engine.failedDrafts.stash(ComposerDraft(text: sentDraft, mentions: sentMentions, replyTo: sentReply), for: id)
        }
    }

    /// Puts a failed draft back after whatever is in the composer now (typed meanwhile, or restored earlier);
    /// a reply target chosen meanwhile wins.
    private func restoreFailedDraft() {
        guard let (failed, showsNotice) = engine.failedDrafts.takeWithNotice(for: id) else { return }
        let merged = ComposerDraft(text: draft, mentions: draftMentions, replyTo: replyTo).appending(failed)
        draft = merged.text
        draftMentions = merged.mentions
        replyTo = merged.replyTo
        if showsNotice { notice = .restored }
    }

    // MARK: In-conversation search

    private func openSearch() {
        if !searchOpen {
            withAnimation(.snappy(duration: 0.2)) { searchOpen = true }
        }
        searchFocusTick += 1
    }

    private func toggleSearch() {
        if searchOpen { closeSearch() } else { openSearch() }
    }

    private func closeSearch() {
        searchTask?.cancel()
        searchTask = nil
        jumpTask?.cancel()
        jumpTask = nil
        searchMatches = []
        searchMatchIndex = 0
        searchQuery = ""
        searchSearching = false
        highlightedMessageId = nil
        withAnimation(.snappy(duration: 0.2)) { searchOpen = false }
        focusTick += 1
    }

    private func scheduleSearch(for rawQuery: String) {
        searchTask?.cancel()
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchSearching = false
            searchMatches = []
            searchMatchIndex = 0
            highlightedMessageId = nil
            return
        }
        searchSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await executeSearch(trimmed)
        }
    }

    private func submitSearch() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !searchMatches.isEmpty && !searchSearching {
            stepMatch(+1)
            return
        }
        searchTask?.cancel()
        searchSearching = true
        searchTask = Task {
            await executeSearch(trimmed)
        }
    }

    private func executeSearch(_ trimmed: String) async {
        let found = await engine.searchMessages(in: id, query: trimmed, limit: 100)
        guard !Task.isCancelled else { return }
        searchSearching = false
        searchMatches = found
        searchMatchIndex = 0
        if let first = found.first {
            jumpToSearchMatch(first)
        } else {
            highlightedMessageId = nil
        }
    }

    private func stepMatch(_ delta: Int) {
        guard !searchMatches.isEmpty else { return }
        let count = searchMatches.count
        searchMatchIndex = (searchMatchIndex + delta + count) % count
        jumpToSearchMatch(searchMatches[searchMatchIndex])
    }

    private func jumpToSearchMatch(_ message: ChatMessage) {
        jumpGeneration += 1
        let gen = jumpGeneration
        jumpTask?.cancel()
        highlightedMessageId = message.id
        jumpTask = Task {
            let ready = await engine.ensureMessageLoaded(message, in: id)
            guard !Task.isCancelled, gen == jumpGeneration else { return }
            if ready {
                // Allow SwiftUI one layout pass to materialize newly prepended rows before scrolling.
                try? await Task.sleep(for: .milliseconds(20))
                guard !Task.isCancelled, gen == jumpGeneration else { return }
                jumpTarget = message.id
            }
        }
    }
}

// MARK: - Toolbar

extension View {
    /// The chat column's toolbar. Applied by `ConversationDetail` outside the chat's `.id(conversation.id)`, so switching chats
    /// updates the same toolbar items in place: recreating them (NSToolbar item views, menus, layout) was the largest single cost
    /// of opening a chat.
    func chatToolbar(conversation: ZaloEngine.ConversationSummary) -> some View {
        modifier(ChatToolbarModifier(conversation: conversation))
    }
}

private struct ChatToolbarModifier: ViewModifier {
    let conversation: ZaloEngine.ConversationSummary
    @Environment(ShellModel.self) private var shell
    /// Width of the chat column; the header's room in the toolbar is what the buttons leave of it.
    @State private var columnWidth: CGFloat = 400

    /// Toolbar room kept free of the header: the call buttons, search button, the info button and the "⋯" menu with their spacing.
    private static let toolbarButtonsRoom: CGFloat = 270

    func body(content: Content) -> some View {
        content
            .toolbar {
                // macOS 27 lays the detail column's toolbar items out from its leading edge, so the header (avatar, name, subtitle)
                // is the first item, like Mail's, and the flexible spacer keeps the buttons at the trailing edge. A toolbar item has a
                // fixed ideal width, so the header is capped at what the column leaves beside the buttons, or a long name would push
                // them into the overflow menu; the name truncates instead.
                ToolbarItem(placement: .primaryAction) {
                    ChatHeaderTitle(conversation: conversation)
                        .frame(maxWidth: max(0, columnWidth - Self.toolbarButtonsRoom), alignment: .leading)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.flexible, placement: .primaryAction)
                ToolbarItemGroup(placement: .primaryAction) {
                    ChatCallButtons(conversation: conversation)
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        shell.toggleChatSearch()
                    } label: {
                        Label("Tìm kiếm tin nhắn", systemImage: "magnifyingglass")
                    }
                    .help("Tìm tin nhắn (⌘F)")
                    .accessibilityLabel("Tìm tin nhắn")
                    Button {
                        shell.toggleInspector()
                    } label: {
                        Label("Thông tin", systemImage: "sidebar.right")
                    }
                    .help("Thông tin (⌥⌘I)")
                    .tourAnchor(.toolbar, arrowEdge: .bottom)
                    ConversationHeaderMenu(conversationId: conversation.id)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                if columnWidth != width { columnWidth = width }
            }
    }
}

// MARK: - Pieces that observe the messages

/// Loading / empty state or the message list: the part of the chat that changes with `engine.messages`.
private struct ChatMessagesPane: View {
    let conversation: ZaloEngine.ConversationSummary
    let sendTick: Int
    @Binding var jumpTarget: String?
    let highlightedMessageId: String?
    let onReply: (ChatMessage) -> Void

    @Environment(ZaloEngine.self) private var engine

    var body: some View {
        Group {
            if let loaded = engine.messages(in: conversation.id) {
                if loaded.isEmpty {
                    ContentUnavailableView {
                        Label("Chưa có tin nhắn", systemImage: "bubble.left")
                    } description: {
                        Text("Tin nhắn cũ nằm trên điện thoại của bạn. Đồng bộ để xem lịch sử trò chuyện với \(conversation.displayName) trên máy tính.")
                    } actions: {
                        if engine.canStartTransfer {
                            Button("Đồng bộ tin nhắn", systemImage: "iphone.and.arrow.forward") { engine.startTransfer() }
                                .buttonStyle(.glassProminent)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tourAnchor(.message, arrowEdge: .trailing)
                } else {
                    MessageList(
                        conversation: conversation,
                        scrollToBottomTick: sendTick,
                        jumpTarget: $jumpTarget,
                        highlightedMessageId: highlightedMessageId,
                        onReply: onReply
                    )
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Đang tải tin nhắn…").font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tourAnchor(.message, arrowEdge: .trailing)
            }
        }
    }
}

/// Avatar, name and subtitle: the first toolbar item of the chat column. A view of its own so typing / new messages update
/// this item in place instead of re-running `ChatView.body` (which rebuilds every toolbar item).
private struct ChatHeaderTitle: View {
    let conversation: ZaloEngine.ConversationSummary
    @Environment(ZaloEngine.self) private var engine

    private var id: String { conversation.id }

    var body: some View {
        let subtitle = subtitle(last: engine.messages(in: id)?.last)
        HStack(spacing: 10) {
            RemoteAvatar(url: conversation.avatar, name: conversation.displayName, size: 30)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text(conversation.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    MutedBell(conversationId: id, size: 11)
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(engine.typingStatus(in: id) != nil ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func subtitle(last: ChatMessage?) -> String {
        if let who = engine.typingStatus(in: id) { return who.label(isGroup: conversation.isGroup) + "…" }
        if conversation.isGroup, conversation.members > 0 { return "\(conversation.members) thành viên" }
        if last?.isE2EE == true { return "Mã hóa đầu cuối" }
        return ""
    }
}

/// Marks the open chat read when something new arrives while it is on screen (invisible; lives in the chat's background).
private struct ChatReadTracker: View {
    let conversation: ZaloEngine.ConversationSummary
    @Environment(ZaloEngine.self) private var engine
    @Environment(\.scenePhase) private var scenePhase
    @State private var lastMarkedId: String?

    private var id: String { conversation.id }

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .onAppear { markReadIfNeeded(last: engine.messages(in: id)?.last, newIncomingOnly: false) }
            .onChange(of: engine.messages(in: id)?.last?.id) { _, _ in markReadIfNeeded(last: engine.messages(in: id)?.last, newIncomingOnly: true) }
            .onChange(of: conversation.unread) { _, _ in markReadIfNeeded(last: engine.messages(in: id)?.last, newIncomingOnly: false) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { markReadIfNeeded(last: engine.messages(in: id)?.last, newIncomingOnly: false) }
            }
    }

    /// Marks read only when there is something unread: `unread > 0`, or an incoming
    /// last message whose id has not been marked yet. Avoids redundant server round trips.
    private func markReadIfNeeded(last: ChatMessage?, newIncomingOnly: Bool) {
        guard scenePhase == .active, engine.openConversationId == id else { return }
        if let last, !last.isMine, last.id != lastMarkedId, newIncomingOnly || conversation.unread > 0 {
            lastMarkedId = last.id
            engine.markRead(id)
        } else if !newIncomingOnly, conversation.unread > 0 {
            engine.markRead(id)
        }
        if lastMarkedId == nil { lastMarkedId = last?.id }
    }
}

// MARK: - Inline search bar

private struct MessageSearchBar: View {
    @Binding var query: String
    let matchIndex: Int
    let matchCount: Int
    let isSearching: Bool
    let focusTick: Int
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onSubmit: () -> Void
    let onClose: () -> Void

    @FocusState private var focused: Bool

    private var hasQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Tìm tin nhắn trong cuộc trò chuyện", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit(onSubmit)
                .onExitCommand(perform: onClose)
                .onKeyPress(.upArrow) {
                    guard matchCount > 0 else { return .ignored }
                    onPrevious()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    guard matchCount > 0 else { return .ignored }
                    onNext()
                    return .handled
                }

            if !query.isEmpty {
                Button {
                    query = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Xoá nội dung tìm kiếm")
                .accessibilityLabel("Xoá nội dung tìm kiếm")
            }

            if hasQuery {
                Group {
                    if isSearching {
                        ProgressView().controlSize(.mini)
                    } else if matchCount == 0 {
                        Text("Không tìm thấy")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(matchIndex + 1) / \(matchCount)")
                            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize()
            }

            Divider().frame(height: 14)

            Button(action: onPrevious) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11.5, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(matchCount > 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .disabled(matchCount == 0)
            .help("Tin nhắn cũ hơn (↑)")
            .accessibilityLabel("Kết quả cũ hơn")

            Button(action: onNext) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11.5, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(matchCount > 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .disabled(matchCount == 0)
            .help("Tin nhắn mới hơn (↓)")
            .accessibilityLabel("Kết quả mới hơn")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11.5, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Đóng tìm kiếm (Esc)")
            .accessibilityLabel("Đóng tìm kiếm")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .onExitCommand(perform: onClose)
        .onAppear {
            focused = true
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: focusTick) { _, _ in
            focused = true
            DispatchQueue.main.async { focused = true }
        }
    }
}

// MARK: - Row model (memoized)

struct ChatRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case day(Date)
        case message(ChatMessage, first: Bool, last: Bool, status: Bool)
    }
    /// Prefix of a day separator's id; the rest is the id of the day's first message.
    static let dayPrefix = "day-"
    let id: String
    let kind: Kind
}

/// Rebuilds rows only when the message array actually changed.
private final class RowCache {
    private var source: [ChatMessage] = []
    private var rows: [ChatRow] = []

    func rows(for msgs: [ChatMessage]) -> [ChatRow] {
        if msgs == source { return rows }
        source = msgs
        rows = Self.build(msgs)
        return rows
    }

    private static func build(_ msgs: [ChatMessage]) -> [ChatRow] {
        let cal = ChatFormat.calendar
        let days = msgs.map { cal.startOfDay(for: $0.date) }
        // Notices / e-cards are not bubbles: they never carry the status line and do not take part in grouping.
        let lastMineId = msgs.last(where: { $0.isMine && !$0.kind.isStandalone })?.id
        func grouped(_ i: Int, _ j: Int) -> Bool {
            let a = msgs[i], b = msgs[j]
            if a.kind.isStandalone || b.kind.isStandalone { return false }
            return a.senderId == b.senderId && a.isMine == b.isMine
                && abs(b.date.timeIntervalSince(a.date)) < 300 && days[i] == days[j]
        }
        var out: [ChatRow] = []
        out.reserveCapacity(msgs.count + 8)
        for i in msgs.indices {
            let m = msgs[i]
            if i == 0 || days[i - 1] != days[i] {
                out.append(ChatRow(id: ChatRow.dayPrefix + m.id, kind: .day(m.date)))
            }
            let first = i == 0 || !grouped(i - 1, i)
            let last = i == msgs.count - 1 || !grouped(i, i + 1)
            out.append(ChatRow(id: m.id, kind: .message(m, first: first, last: last, status: m.id == lastMineId)))
        }
        return out
    }
}

// MARK: - Message list

/// The rows of the open chat in `ChatListView` (AppKit-backed, see there), plus the logic around them: older pages when the
/// reader nears the top, following new messages, jumps to a pin / search match, and the "scroll to newest" button.
private struct MessageList: View {
    let conversation: ZaloEngine.ConversationSummary
    let scrollToBottomTick: Int
    @Binding var jumpTarget: String?
    var highlightedMessageId: String?
    var onReply: (ChatMessage) -> Void

    @Environment(ZaloEngine.self) private var engine
    @Environment(ShellModel.self) private var shell

    @State private var cache = RowCache()
    @State private var commands = ChatListCommands()
    @State private var atTop = false
    @State private var nearBottom = true
    @State private var lastContentHeight: CGFloat = 0
    @State private var loadingOlder = false
    @State private var olderTask: Task<Void, Never>?
    /// False from the moment an older page lands until the reader leaves the top: one page per pull, like the official
    /// client, instead of paging on and on while the kept position still reads as "at the top".
    @State private var olderArmed = true
    /// Room the bars (pinned bar, composer, toolbar) take over the list; the list scrolls under them.
    @State private var insets = EdgeInsets()

    private var id: String { conversation.id }

    var body: some View {
        let msgs = engine.messages(in: id) ?? []
        let rows = cache.rows(for: msgs)
        let hasMore = engine.hasMoreHistory(in: id) ?? false
        let newestId = msgs.last?.id
        let engine = engine
        let id = id
        Color.clear
            .overlay {
                ChatListView(
                    conversationId: id, rows: rows, isGroup: conversation.isGroup, newestId: newestId,
                    highlightedId: highlightedMessageId,
                    selection: engine.messageSelection?.conversationId == id ? engine.messageSelection : nil,
                    loadingOlder: loadingOlder, insets: insets, commands: commands,
                    onReply: onReply,
                    onReact: { emoji, msg in engine.react(emoji, to: msg.id, in: id) },
                    onSelect: { msgId, range in engine.toggleSelection(msgId, range: range) },
                    onMetrics: { m in metricsChanged(m, hasMore: hasMore, count: msgs.count) })
                // Vertical only: the list scrolls under the top/bottom bars, but not under the inspector on the side
                // (it would keep its old width there and centered rows would be cut off).
                .ignoresSafeArea(edges: .vertical)
                // The part of the list the bars cover (it is drawn under them, edge to edge).
                .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets = $0 }
            }
            .onChange(of: atTop) { _, _ in maybeLoadOlder(hasMore: hasMore, count: msgs.count) }
            .onChange(of: olderArmed) { _, _ in maybeLoadOlder(hasMore: hasMore, count: msgs.count) }
            .onChange(of: hasMore) { _, now in
                if !now { loadingOlder = false; olderTask?.cancel() }
                maybeLoadOlder(hasMore: now, count: msgs.count)
            }
            .onChange(of: msgs.first?.id) { old, _ in
                // Older history was prepended (the list keeps the reader's row in place): wait for the reader to leave the
                // top again before the next page.
                guard let old, let idx = msgs.firstIndex(where: { $0.id == old }), idx > 0 else { return }
                olderArmed = false
            }
            .onChange(of: engine.historyTicks[id] ?? 0) { _, _ in
                // An older page arrived but every message in it is a hidden card: ask for the next one.
                loadingOlder = false
                olderTask?.cancel()
                maybeLoadOlder(hasMore: hasMore, count: msgs.count)
            }
            .onChange(of: msgs.count) { _, _ in
                loadingOlder = false
                olderTask?.cancel()
                maybeLoadOlder(hasMore: hasMore, count: msgs.count)
            }
            .onChange(of: msgs.last?.id) { old, _ in
                guard old != nil else { return }
                if nearBottom || msgs.last?.isMine == true { commands.scrollToBottom(animated: true) }
            }
            .onChange(of: scrollToBottomTick) { _, _ in commands.scrollToBottom(animated: true) }
            .onChange(of: jumpTarget) { _, target in
                guard let target else { return }
                jumpTarget = nil
                commands.scrollTo(target, animated: true)
            }
            // The tour's message step points at the newest row: make sure it is on screen.
            .onChange(of: shell.tour) { _, step in if step == .message { commands.scrollToBottom(animated: true) } }
            .onAppear { showInitialPosition() }
            // The list (and its scroll view) is reused for the next chat: start over as a new list would.
            .onChange(of: id) { _, _ in
                olderTask?.cancel()
                olderTask = nil
                loadingOlder = false
                atTop = false
                nearBottom = true
                lastContentHeight = 0
                // Disarmed until the list has left the top band once (the metrics re-arm it).
                olderArmed = false
                showInitialPosition()
            }
            .onDisappear { olderTask?.cancel() }
            .overlay(alignment: .bottomTrailing) {
                if !nearBottom {
                    Button {
                        commands.scrollToBottom(animated: true)
                    } label: {
                        Image(systemName: "chevron.down").font(.system(size: 13, weight: .bold))
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .padding(14)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("Cuộn xuống tin nhắn mới nhất")
                }
            }
            .animation(.snappy(duration: 0.2), value: nearBottom)
    }

    private func metricsChanged(_ m: ChatListMetrics, hasMore: Bool, count: Int) {
        // Older history is asked for about a screen before the top, so it is usually there before the reader is.
        let band = max(120, m.visible)
        let top = m.top < band
        // Re-armed once the reader is away from the top, or when the history is too short to ever leave the top band.
        if !olderArmed, !top || m.content - m.visible < band { olderArmed = true }
        if top != atTop { atTop = top }
        // Only scrolling (not content growth) changes "near bottom".
        if abs(m.content - lastContentHeight) < 1 {
            let near = m.fromBottom < 160
            if near != nearBottom { nearBottom = near }
        }
        if lastContentHeight != m.content { lastContentHeight = m.content }
    }

    /// A chat opens at its newest message, or at the message a pin / search asked for.
    private func showInitialPosition() {
        PerfProbe.appearedChat = id
        if let pending = jumpTarget {
            jumpTarget = nil
            DispatchQueue.main.async { commands.scrollTo(pending, animated: false) }
        } else if highlightedMessageId == nil {
            commands.scrollToBottom(animated: false)
        }
    }

    private func maybeLoadOlder(hasMore: Bool, count: Int) {
        guard atTop, olderArmed, hasMore, !loadingOlder, count > 0 else { return }
        olderTask?.cancel()
        olderTask = Task {
            try? await Task.sleep(for: .milliseconds(150)) // debounce
            guard !Task.isCancelled, atTop, olderArmed, engine.hasMoreHistory(in: id) == true else { return }
            loadingOlder = true
            engine.loadOlderMessages(id)
            try? await Task.sleep(for: .seconds(6)) // give up the spinner if nothing arrives
            if !Task.isCancelled { loadingOlder = false }
        }
    }
}

// MARK: - Day separator

/// "Hôm nay 09:41" in a small glass capsule; the time is the day's first loaded message.
struct DaySeparator: View {
    let date: Date
    var body: some View {
        HStack(spacing: 4) {
            Text(ChatFormat.daySeparator(date)).fontWeight(.semibold)
            Text(ChatFormat.time(date))
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 11).padding(.vertical, 4)
        .glassEffect(.regular, in: Capsule())
        .frame(maxWidth: .infinity)
        .padding(.top, 14).padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
