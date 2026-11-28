import SwiftUI

/// Conversation info shown in the chat's inspector (⌥⌘I): who it is, quick actions, the members of a group, the
/// polls found in the loaded history, and a preview of the photos / files / links ever shared (the whole list is one
/// "Xem tất cả" away, in `SharedMediaBrowser`). Everything comes from `ZaloEngine`; nothing is invented, and a section
/// with nothing to show says so.
struct ChatInspector: View {
    let conversation: ZaloEngine.ConversationSummary

    @Environment(ZaloEngine.self) private var engine
    @Environment(ShellModel.self) private var shell
    /// Group members from the official @mention suggestions; nil while loading.
    @State private var members: [MentionCandidate]?
    @State private var showAllMembers = false
    @State private var showLabelManager = false
    @State private var pollSheet: PollEntry?
    @State private var showPollCreate = false
    @State private var showRenameGroup = false
    @State private var showAddMembers = false
    @State private var memberToKick: MentionCandidate?
    /// Owner / deputies of the group (from its detail), read with the members.
    @State private var roles = GroupRoles()
    @State private var newOwner: MentionCandidate?
    @State private var memberToBlock: MentionCandidate?
    @State private var showGroupLink = false
    @State private var showApproval = false
    @State private var showReport = false
    @State private var showNote = false
    @State private var confirmLeaveGroup = false
    @State private var leavingGroup = false
    @State private var confirmBlock = false
    @State private var blockBusy = false
    /// Width of the overview's scroll view itself (not of its content, see `SharedMediaGrid`).
    @State private var outerWidth: CGFloat = 300
    /// Photos / files / links ever shared, read from the official media service (the overview shows the newest of each).
    @State private var media: SharedMediaModel
    /// The list shown on the full "Kho lưu trữ" page; nil = the overview.
    @State private var browsing: SharedMediaKind?

    private var id: String { conversation.id }
    private let memberLimit = 8
    private let listLimit = 5

    init(conversation: ZaloEngine.ConversationSummary) {
        self.conversation = conversation
        _media = State(initialValue: SharedMediaModel(conversationId: conversation.id))
    }

    var body: some View {
        Group {
            if browsing != nil {
                SharedMediaBrowser(conversationId: id, model: media,
                                   kind: Binding(get: { browsing ?? .images }, set: { browsing = $0 }),
                                   close: { browsing = nil })
            } else {
                overview
            }
        }
        // On the container, not the overview: leaving for the storage page must not restart these.
        .task(id: id) { await loadMembers() }
        .task(id: engine.messages(in: id)?.last?.id) { await refreshPreview() }
        .sheet(item: $pollSheet) { poll in
            PollDetailSheet(pollId: poll.pollId, conversationId: id, question: poll.question)
        }
        .sheet(isPresented: $showPollCreate) { PollCreateSheet(conversationId: id) }
        .sheet(isPresented: $showLabelManager) { LabelManagerView() }
        .sheet(isPresented: $showRenameGroup) {
            RenameGroupSheet(groupId: id, currentName: conversation.name)
        }
        .sheet(isPresented: $showAddMembers) {
            AddGroupMembersSheet(
                groupId: id,
                groupName: conversation.displayName,
                existingMemberIds: (members ?? []).map(\.id)
            ) {
                Task { await loadMembers() }
            }
        }
        .sheet(isPresented: $showNote) { GroupNoteSheet(groupId: id) }
        .sheet(isPresented: $showReport) { ReportSheet(conversationId: id, name: conversation.displayName) }
        .sheet(isPresented: $showGroupLink) { GroupLinkSheet(groupId: id, canManage: myRoleCanManage) }
        .sheet(isPresented: $showApproval) {
            GroupApprovalSheet(groupId: id, approvalOn: roles.joinApproval) { Task { await loadMembers() } }
        }
        .alert(
            "Xác nhận chọn trưởng nhóm mới",
            isPresented: Binding(get: { newOwner != nil }, set: { if !$0 { newOwner = nil } }),
            presenting: newOwner
        ) { member in
            Button("Chuyển quyền") {
                newOwner = nil
                Task { if await engine.changeGroupOwner(id, uid: member.id) { await loadMembers() } }
            }
            Button("Hủy", role: .cancel) { newOwner = nil }
        } message: { member in
            Text("\(member.name) sẽ trở thành trưởng nhóm. Bạn sẽ trở thành thành viên bình thường.")
        }
        .alert(
            "Chặn khỏi nhóm",
            isPresented: Binding(get: { memberToBlock != nil }, set: { if !$0 { memberToBlock = nil } }),
            presenting: memberToBlock
        ) { member in
            Button("Chặn", role: .destructive) {
                memberToBlock = nil
                Task { if await engine.blockGroupMember(id, uid: member.id) { await loadMembers() } }
            }
            Button("Hủy", role: .cancel) { memberToBlock = nil }
        } message: { member in
            Text("\(member.name) sẽ bị xóa và không thể tham gia lại nhóm này.")
        }
        .alert(
            "Xóa thành viên?",
            isPresented: Binding(get: { memberToKick != nil }, set: { if !$0 { memberToKick = nil } }),
            presenting: memberToKick
        ) { member in
            Button("Xóa khỏi nhóm", role: .destructive) {
                memberToKick = nil
                Task {
                    if await engine.kickMember(member.id, from: id) {
                        await loadMembers()
                    }
                }
            }
            Button("Hủy", role: .cancel) { memberToKick = nil }
        } message: { member in
            Text("Bạn có chắc muốn xóa \(member.name) khỏi nhóm này?")
        }
        .alert("Chặn tin nhắn và cuộc gọi?", isPresented: $confirmBlock) {
            Button("Chặn", role: .destructive) {
                Task {
                    blockBusy = true
                    await engine.setBlocked(id, blocked: true, name: conversation.displayName)
                    blockBusy = false
                }
            }
            Button("Hủy", role: .cancel) {}
        } message: {
            Text("\(conversation.displayName) sẽ không thể nhắn tin hay gọi điện cho bạn.")
        }
        .task(id: id) {
            if !conversation.isGroup, engine.blockedUsers == nil { await engine.loadBlockedUsers() }
        }
        .alert("Rời khỏi nhóm?", isPresented: $confirmLeaveGroup) {
            Button("Rời nhóm", role: .destructive) {
                Task {
                    leavingGroup = true
                    let ok = await engine.leaveGroup(id)
                    leavingGroup = false
                    if ok {
                        shell.hideInspector()
                    }
                }
            }
            Button("Hủy", role: .cancel) {}
        } message: {
            Text("Bạn sẽ không còn nhận được tin nhắn từ nhóm \"\(conversation.displayName)\" nữa.")
        }
    }

    private var overview: some View {
        let loaded = engine.messages(in: id) ?? []
        return ScrollView {
            VStack(spacing: 20) {
                header
                actions
                if conversation.isGroup {
                    groupBoard(LoadedPolls(messages: loaded).polls)
                    groupManagementSection
                    membersSection
                }
                mediaSection(preview(.images, loaded))
                filesSection(preview(.files, loaded))
                linksSection(preview(.links, loaded))
                if conversation.isGroup {
                    autoDeleteSection
                    leaveGroupSection
                } else if id != engine.selfConversationId {
                    securitySection
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { outerWidth = $0 }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 6) {
            RemoteAvatar(url: conversation.avatar, name: conversation.displayName, size: 76)
                .padding(.top, 14)
            HStack(spacing: 5) {
                Text(conversation.displayName)
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if engine.canEditAlias(for: id, isGroup: conversation.isGroup) {
                    Button {
                        shell.editAlias(draft: engine.aliasDraft(for: id, fallbackName: conversation.displayName), conversationId: id)
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(AliasDraft.menuTitle)
                    .accessibilityLabel(AliasDraft.menuTitle)
                }
                MutedBell(conversationId: id, size: 12)
            }
            if let subtitle {
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String? {
        if id == engine.selfConversationId { return "Chỉ mình bạn thấy" }
        if conversation.isGroup { return conversation.members > 0 ? "\(conversation.members) thành viên" : "Nhóm" }
        if engine.contacts.friends.contains(where: { $0.id == id }) { return "Bạn bè" }
        return engine.contacts.friendsLoaded ? "Chưa là bạn" : nil
    }

    // MARK: Actions

    private var actions: some View {
        let state = engine.conversationActions
        let muted = engine.isConversationMuted(id)
        let plan = ConversationMenuPlan.make(id: id, preset: .chatBox, state: state, unread: 0, muted: muted)
        return GlassEffectContainer(spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                if !state.loaded || plan.mute != nil {
                    if muted {
                        ActionSlot("Bật thông báo") {
                            Button { engine.unmuteConversation(id) } label: { actionGlyph("bell") }
                                .glassAction()
                        }
                    } else {
                        ActionSlot("Tắt thông báo") {
                            Menu {
                                ForEach(MuteDuration.allCases) { duration in
                                    Button(duration.title) { engine.muteConversation(id, duration) }
                                }
                            } label: { actionGlyph("bell.slash") }
                                .glassAction()
                        }
                    }
                }
                switch plan.pin {
                case .pin:
                    ActionSlot("Ghim") {
                        Button { engine.pinConversation(id) } label: { actionGlyph("pin") }.glassAction()
                    }
                case .unpin:
                    ActionSlot("Bỏ ghim") {
                        Button { engine.unpinConversation(id) } label: { actionGlyph("pin.slash") }.glassAction()
                    }
                case nil:
                    EmptyView()
                }
                // Official 1:1 info panel button STR_BTN_CREATE_CONVERSATION_GROUP ("Tạo nhóm trò chuyện", shortened for the slot),
                // with this friend already picked.
                if !conversation.isGroup, id != engine.selfConversationId, engine.contacts.friends.contains(where: { $0.id == id }) {
                    ActionSlot("Tạo nhóm") {
                        Button { shell.composeGroup(with: [id]) } label: { actionGlyph("person.2.badge.plus") }
                            .glassAction()
                            .help("Tạo nhóm với \(conversation.displayName)")
                    }
                }
                ActionSlot("Thêm") {
                    Menu {
                        ConversationActionsMenu(conversationId: id, preset: .thread, showLabelManager: $showLabelManager)
                    } label: { actionGlyph("ellipsis") }
                        .glassAction()
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func actionGlyph(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 16)).frame(width: 22, height: 22)
    }

    // MARK: Group

    private func groupBoard(_ polls: [LoadedPolls.Poll]) -> some View {
        section("Bảng tin nhóm") {
            list {
                row(symbol: "note.text.badge.plus", title: "Tạo ghi chú") { showNote = true }
                Divider().padding(.leading, 40)
                row(symbol: "plus.circle", title: "Tạo bình chọn") { showPollCreate = true }
                ForEach(polls.prefix(listLimit)) { poll in
                    Divider().padding(.leading, 40)
                    row(symbol: "chart.bar.fill", title: poll.question.isEmpty ? "Bình chọn" : poll.question, lines: 2) {
                        pollSheet = PollEntry(pollId: poll.id, question: poll.question)
                    }
                }
                if polls.isEmpty {
                    Divider().padding(.leading, 40)
                    emptyLine("Chưa có bình chọn trong nội dung đã tải")
                }
            }
        }
    }

    private var groupManagementSection: some View {
        section("Quản lý nhóm") {
            list {
                row(symbol: "pencil", title: "Đổi tên nhóm") { showRenameGroup = true }
                Divider().padding(.leading, 40)
                row(symbol: "person.badge.plus", title: "Thêm thành viên") { showAddMembers = true }
                Divider().padding(.leading, 40)
                row(symbol: "link", title: "Link tham gia nhóm") { showGroupLink = true }
                if myRoleCanManage {
                    Divider().padding(.leading, 40)
                    row(symbol: "person.crop.circle.badge.checkmark", title: "Phê duyệt thành viên mới",
                        subtitle: roles.joinApproval ? "Đang bật" : "Đang tắt") { showApproval = true }
                }
            }
        }
    }

    /// 1-1 "Thiết lập bảo mật": block / unblock messages and calls (official `setBlockFriend`).
    /// "Tin nhắn tự xóa" (official `STR_VANISH_MSGS`): the lifetime of new messages in this conversation.
    private var autoDeleteRow: some View {
        let ttl = engine.autoDeleteTTL(id)
        return Menu {
            ForEach(AutoDelete.options, id: \.ttl) { option in
                Button {
                    Task { await engine.setAutoDelete(id, ttl: option.ttl) }
                } label: {
                    let title = option.plan.map { "\(option.label)  ·  \($0)" } ?? option.label
                    if option.ttl == ttl { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "timer").font(.system(size: 14)).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Tin nhắn tự xóa").font(.system(size: 13, weight: .medium))
                    Text(ttl > 0 ? AutoDelete.label(ttl) : "Không bao giờ").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 38)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .disabled(engine.autoDelete == nil)
        .help("Tin nhắn sẽ tự xóa sau khoảng thời gian bạn cài đặt")
        .task(id: id) { if engine.autoDelete == nil { await engine.loadAutoDelete() } }
    }

    private var autoDeleteSection: some View {
        section("Thiết lập bảo mật") {
            list {
                autoDeleteRow
                Divider().padding(.leading, 40)
                reportRow
            }
        }
    }

    private var reportRow: some View {
        row(symbol: "exclamationmark.triangle", title: "Báo xấu") { showReport = true }
    }

    private var securitySection: some View {
        let blocked = engine.isBlocked(id)
        return section("Thiết lập bảo mật") {
            list {
                autoDeleteRow
                Divider().padding(.leading, 40)
                reportRow
                Divider().padding(.leading, 40)
                Button {
                    if blocked {
                        Task { blockBusy = true; await engine.setBlocked(id, blocked: false); blockBusy = false }
                    } else {
                        confirmBlock = true
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: blocked ? "hand.raised.slash" : "hand.raised")
                            .font(.system(size: 14))
                            .frame(width: 18)
                        if blockBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(blocked ? "Bỏ chặn" : "Chặn tin nhắn").font(.system(size: 13, weight: .medium))
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(blocked ? Color.primary : Color.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(minHeight: 38)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(blockBusy || engine.blockedUsers == nil)
            }
        }
    }

    private var leaveGroupSection: some View {
        list {
            Button(role: .destructive) {
                confirmLeaveGroup = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 14))
                        .frame(width: 18)
                    if leavingGroup {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Rời nhóm").font(.system(size: 13, weight: .medium))
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.red)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(minHeight: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(leavingGroup)
        }
    }

    @ViewBuilder
    private var membersSection: some View {
        if let members, !members.isEmpty {
            let shown = showAllMembers ? members : Array(members.prefix(memberLimit))
            let toggleAction: (() -> Void)? = members.count > memberLimit ? { showAllMembers.toggle() } : nil
            section(
                "Thành viên",
                trailing: conversation.members > 0 ? "\(conversation.members)" : nil,
                actionTitle: showAllMembers ? "Thu gọn" : "Xem tất cả",
                seeAll: toggleAction
            ) {
                list {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, member in
                        let canKick = !member.isAll && member.id != "-1" && (myUid.isEmpty || member.id != myUid)
                        if index > 0 { Divider().padding(.leading, 46) }
                        HStack(spacing: 8) {
                            Button { engine.openContactConversation(member.id) } label: {
                                HStack(spacing: 10) {
                                    RemoteAvatar(url: member.avatar, name: member.name, size: 26)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(member.name).font(.system(size: 13)).lineLimit(1)
                                        if let role = roleLabel(member.id) {
                                            Text(role).font(.system(size: 11)).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Nhắn tin với \(member.name)")

                            if canKick {
                                Menu {
                                    Button("Nhắn tin", systemImage: "bubble.left") {
                                        engine.openContactConversation(member.id)
                                    }
                                    Divider()
                                    adminItems(member)
                                    Button("Xóa khỏi nhóm", systemImage: "person.badge.minus", role: .destructive) {
                                        memberToKick = member
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 24, height: 24)
                                        .contentShape(Rectangle())
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .help("Quản lý thành viên")
                                .accessibilityLabel("Tùy chọn cho \(member.name)")
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 38)
                        .contextMenu {
                            Button("Nhắn tin", systemImage: "bubble.left") {
                                engine.openContactConversation(member.id)
                            }
                            if canKick {
                                Divider()
                                adminItems(member)
                                Button("Xóa khỏi nhóm", systemImage: "person.badge.minus", role: .destructive) {
                                    memberToKick = member
                                }
                            }
                        }
                    }
                    if !showAllMembers && conversation.members > shown.count {
                        Divider()
                        emptyLine("và \(conversation.members - shown.count) thành viên khác")
                    }
                }
            }
        } else if members == nil {
            section("Thành viên") {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 40)
            }
        }
    }

    private func loadMembers() async {
        members = nil
        guard conversation.isGroup else { members = []; return }
        let found = await engine.loadGroupMembers(in: id)
        guard !Task.isCancelled else { return }
        members = found.filter { !$0.isAll && $0.id != "-1" }
        roles = engine.groupRoles(id)
    }

    private var myUid: String { ZaloWireParser.stripUserPrefix(engine.profile?.userId ?? "") }
    private var myRoleCanManage: Bool { roles.canManage(myUid) }

    private func roleLabel(_ uid: String) -> String? {
        roles.isOwner(uid) ? "Trưởng nhóm" : roles.isAdmin(uid) ? "Phó nhóm" : nil
    }

    /// Official member menu: the owner adjusts deputies and hands the group over; owner / deputies block members.
    @ViewBuilder
    private func adminItems(_ member: MentionCandidate) -> some View {
        let iAmOwner = roles.isOwner(myUid)
        if iAmOwner {
            if roles.isAdmin(member.id) {
                Button("Xóa phó nhóm", systemImage: "person.badge.minus") {
                    Task { if await engine.setGroupAdmin(id, uid: member.id, admin: false) { await loadMembers() } }
                }
            } else {
                Button("Thêm phó nhóm", systemImage: "person.badge.shield.checkmark") {
                    Task { if await engine.setGroupAdmin(id, uid: member.id, admin: true) { await loadMembers() } }
                }
            }
            Button("Chuyển quyền trưởng nhóm", systemImage: "crown") { newOwner = member }
        }
        if myRoleCanManage, !roles.isOwner(member.id), iAmOwner || !roles.isAdmin(member.id) {
            Button("Chặn khỏi nhóm", systemImage: "hand.raised", role: .destructive) { memberToBlock = member }
        }
    }

    // MARK: Shared content

    private func preview(_ kind: SharedMediaKind, _ loaded: [ChatMessage]) -> [ChatMessage] {
        media.preview(kind, loaded: loaded)
    }

    /// The first read starts at once; later ones (a new newest message) wait a second so a burst of messages reads the store once.
    private func refreshPreview() async {
        if media.hasLoaded {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
        }
        await media.refresh(using: engine)
    }

    /// What stands in for an empty list: a spinner while the first read is out, a retry when it failed (not knowing is not "nothing shared"),
    /// else the "nothing here" line.
    @ViewBuilder
    private func emptyOrLoading(_ kind: SharedMediaKind, _ text: String) -> some View {
        let feed = media.feed(kind)
        if feed.isPending {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 38)
        } else if feed.didFail {
            failureLine(kind)
        } else {
            emptyLine(text)
        }
    }

    /// The first read of a list failed: say so, with a retry. (Shown under whatever the loaded messages already gave, too.)
    private func failureLine(_ kind: SharedMediaKind) -> some View {
        HStack(spacing: 8) {
            Text("Không tải được").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Thử lại") { Task { await media.retry(kind, using: engine) } }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.tint)
        }
        .frame(maxWidth: .infinity, minHeight: 38)
        .padding(.horizontal, 12)
    }

    /// "Xem tất cả" is there when the list has something to show, and when it could not be read (the full page has the retry too).
    private func seeAll(_ kind: SharedMediaKind, hasItems: Bool) -> (() -> Void)? {
        hasItems || media.feed(kind).didFail ? { browsing = kind } : nil
    }

    private func mediaSection(_ items: [ChatMessage]) -> some View {
        section("Ảnh và video", seeAll: seeAll(.images, hasItems: !items.isEmpty)) {
            if items.isEmpty {
                list { emptyOrLoading(.images, "Chưa có ảnh hoặc video") }
            } else {
                let tile = max(48, ((SharedMediaGrid.contentWidth(outer: outerWidth, inset: 16) - 8) / 3).rounded(.down))
                VStack(spacing: 6) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(tile), spacing: 4), count: 3), spacing: 4) {
                        ForEach(items) { message in
                            SharedMediaTile(message: message, conversationId: id, side: tile)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if media.feed(.images).didFail { list { failureLine(.images) } }
                }
            }
        }
    }

    private func filesSection(_ files: [ChatMessage]) -> some View {
        section("Tệp", seeAll: seeAll(.files, hasItems: !files.isEmpty)) {
            list {
                if files.isEmpty {
                    emptyOrLoading(.files, "Chưa có tệp")
                } else {
                    ForEach(Array(files.enumerated()), id: \.element.id) { index, message in
                        if index > 0 { Divider().padding(.leading, 12) }
                        SharedFileRow(message: message)
                    }
                    if media.feed(.files).didFail {
                        Divider()
                        failureLine(.files)
                    }
                }
            }
        }
    }

    private func linksSection(_ links: [ChatMessage]) -> some View {
        section("Liên kết", seeAll: seeAll(.links, hasItems: !links.isEmpty)) {
            list {
                if links.isEmpty {
                    emptyOrLoading(.links, "Chưa có liên kết")
                } else {
                    ForEach(Array(links.enumerated()), id: \.element.id) { index, message in
                        if index > 0 { Divider().padding(.leading, 40) }
                        SharedLinkRow(message: message)
                    }
                    if media.feed(.links).didFail {
                        Divider()
                        failureLine(.links)
                    }
                }
            }
        }
    }

    // MARK: Building blocks

    /// `trailing`: a quiet value (the member count); `seeAll`: the "Xem tất cả" button of a list that continues on the storage page.
    private func section<Content: View>(
        _ title: String,
        trailing: String? = nil,
        actionTitle: String = "Xem tất cả",
        seeAll: (() -> Void)? = nil,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 12)).foregroundStyle(.tertiary) }
                if let seeAll {
                    Button(actionTitle, action: seeAll)
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 4)
            content()
        }
    }

    private func list<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        InspectorList(content: content)
    }

    private func row(symbol: String, title: String, subtitle: String = "", lines: Int = 1, action: @escaping () -> Void) -> some View {
        InspectorRow(symbol: symbol, title: title, subtitle: subtitle, lines: lines, action: action)
    }

    private func emptyLine(_ text: String) -> some View {
        InspectorEmptyLine(text)
    }
}

// MARK: - Pieces

/// A round glass action with its caption underneath.
private struct ActionSlot<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 5) {
            content
            Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(minWidth: 58)
    }
}

private extension View {
    /// Round glass button (also for a `Menu`), the style of the composer's controls.
    func glassAction() -> some View {
        menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
    }
}

private struct PollEntry: Identifiable {
    let pollId: String
    let question: String
    var id: String { pollId }
}

/// Polls found in the loaded part of the history, newest first (the poll board has no store of its own to page through).
private struct LoadedPolls {
    struct Poll: Identifiable {
        let id: String
        let question: String
    }

    var polls: [Poll] = []

    init(messages: [ChatMessage]) {
        var seenPolls: Set<String> = []
        for message in messages.reversed() {
            if case .poll(let info) = message.kind, !info.pollId.isEmpty, seenPolls.insert(info.pollId).inserted {
                polls.append(Poll(id: info.pollId, question: info.question))
            }
        }
    }
}

// MARK: - Group Management Sheets

private struct RenameGroupSheet: View {
    let groupId: String
    let currentName: String

    @Environment(ZaloEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private let limits = GroupCreateLimits()

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && trimmedName != currentName.trimmingCharacters(in: .whitespacesAndNewlines) && !saving
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("Đổi tên nhóm")
                .font(.system(size: 16, weight: .semibold))
            TextField("Nhập tên nhóm...", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: Capsule())
                .focused($focused)
                .disabled(saving)
                .onChange(of: name) { _, typed in
                    let clamped = limits.clampedName(typed)
                    if clamped != typed { name = clamped }
                }
                .onSubmit { save() }
            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 10) {
                Button("Hủy") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button {
                    save()
                } label: {
                    if saving {
                        ProgressView().controlSize(.small).frame(width: 56)
                    } else {
                        Text("Lưu")
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 360)
        .onAppear {
            name = limits.clampedName(currentName)
            focused = true
            DispatchQueue.main.async { focused = true }
        }
    }

    private func save() {
        guard canSave else { return }
        saving = true
        error = nil
        let target = trimmedName
        Task {
            let ok = await engine.renameGroup(groupId, to: target)
            saving = false
            if ok {
                dismiss()
            } else {
                error = "Không thể đổi tên nhóm. Vui lòng thử lại."
            }
        }
    }
}

private struct AddGroupMembersSheet: View {
    let groupId: String
    let groupName: String
    let existingMemberIds: [String]
    var onAdded: () -> Void

    @Environment(ZaloEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selected: [String] = []
    @State private var saving = false
    @State private var error: String?
    @FocusState private var searchFocused: Bool

    private var excludedIds: Set<String> {
        var ids = Set(existingMemberIds)
        ids.formUnion(engine.groupMemberIds(in: groupId))
        if let myUid = engine.profile?.userId {
            ids.insert(ZaloWireParser.stripUserPrefix(myUid))
        }
        return ids
    }

    private var availablePeople: [GroupComposeRoster.Person] {
        let excluded = excludedIds
        let roster = GroupComposeRoster(
            friends: engine.visibleFriends,
            conversations: engine.visibleConversations,
            selfId: engine.selfConversationId
        )
        let source = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? roster.friends
            : roster.matching(query)
        return source.filter { !excluded.contains($0.id) }
    }

    var body: some View {
        let people = availablePeople
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text("Thêm thành viên")
                    .font(.system(size: 16, weight: .semibold))
                Text(groupName)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.top, 18)
            .padding(.bottom, 12)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Tìm bạn bè...", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule())
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()

            if !engine.contacts.friendsLoaded {
                ProgressView("Đang tải danh sách bạn bè…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if people.isEmpty {
                ContentUnavailableView(
                    query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Không còn bạn bè để thêm"
                        : "Không tìm thấy",
                    systemImage: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "person.2"
                        : "magnifyingglass"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(people) { person in
                            memberRow(person)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }

            Divider()

            VStack(spacing: 8) {
                if let error {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    Text(selected.isEmpty ? "Chọn thành viên muốn thêm" : "Đã chọn \(selected.count)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Button("Hủy") { dismiss() }
                        .buttonStyle(.glass)
                        .keyboardShortcut(.cancelAction)
                        .disabled(saving)
                    Button {
                        invite()
                    } label: {
                        if saving {
                            ProgressView().controlSize(.small).frame(width: 56)
                        } else {
                            Text("Thêm")
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || saving)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 420, height: 560)
        .task {
            if !engine.contacts.friendsLoaded {
                await engine.performContactsSync()
            }
        }
        .onAppear {
            searchFocused = true
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    private func memberRow(_ person: GroupComposeRoster.Person) -> some View {
        let checked = selected.contains(person.id)
        return Button {
            if let idx = selected.firstIndex(of: person.id) {
                selected.remove(at: idx)
            } else {
                selected.append(person.id)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(checked ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.6)))
                RemoteAvatar(url: person.avatar, name: person.name, size: 34)
                Text(person.name)
                    .font(.system(size: 14))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }

    private func invite() {
        guard !selected.isEmpty, !saving else { return }
        saving = true
        error = nil
        let targetIds = selected
        Task {
            let ok = await engine.inviteMembers(targetIds, to: groupId)
            saving = false
            if ok {
                onAdded()
                dismiss()
            } else {
                error = "Không thể thêm thành viên. Vui lòng thử lại."
            }
        }
    }
}
