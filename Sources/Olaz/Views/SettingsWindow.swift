import SwiftUI

/// The Settings window (⌘,): one tab per topic, each a grouped `Form`. The notification, hidden-chat and sticker tabs embed the
/// sections of their own files, which read and write the official client's settings.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Chung", systemImage: "gearshape") {
                SettingsPane(height: 210) { GeneralSettings() }
            }
            Tab("Giao diện", systemImage: "paintpalette") {
                SettingsPane(height: 700) { AppearanceSettings() }
            }
            Tab("Thông báo", systemImage: "bell.badge") {
                SettingsPane(height: 440) { NotificationSettingsView() }
            }
            Tab("Quyền riêng tư", systemImage: "lock") {
                SettingsPane(height: 720) { PrivacySettings() }
            }
            Tab("Sticker", systemImage: "face.smiling") {
                SettingsPane(height: 160) { StickerSettingsSection() }
            }
            Tab("Tài khoản", systemImage: "person.crop.circle") {
                SettingsPane(height: 420) { AccountSettings() }
            }
        }
    }
}

/// One tab's grouped form at the window's fixed width; a tall section list scrolls instead of resizing the window.
private struct SettingsPane<Content: View>: View {
    let height: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .frame(width: 520, height: height)
    }
}

// MARK: - Chung

private struct GeneralSettings: View {
    @AppStorage("olaz.appearance") private var appearance = Appearance.system

    var body: some View {
        Section("Chế độ giao diện") {
            Picker("Chế độ", selection: $appearance) {
                ForEach(Appearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        // Only a bundled app has a version; a bare `swift run` binary has none to show.
        if let version = Self.version {
            Section("Về \(AppBrand.name)") {
                LabeledContent("Phiên bản", value: version)
            }
        }
    }

    private static var version: String? {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case (let short?, let build?) where short != build: return "\(short) (\(build))"
        default: return short
        }
    }
}

// MARK: - Quyền riêng tư

/// Hidden-chat setup. The official section only exists once the adapter published and the feature is on, so the tab says why
/// it is empty otherwise.
private struct PrivacySettings: View {
    @Environment(ZaloEngine.self) private var engine

    var body: some View {
        let state = engine.conversationActions
        if state.loaded, state.hiddenEnabled {
            HiddenChatSettingsSection()
        } else {
            Section("Thiết lập ẩn trò chuyện") {
                Text(state.loaded ? "Tính năng ẩn trò chuyện chưa được bật cho tài khoản này." : "Đang tải thiết lập từ Zalo…")
                    .foregroundStyle(.secondary)
            }
        }
        AccountPrivacySection()
        QuickMessagesSection()
        BlockedUsersSection()
    }
}

/// "Quản lý tin nhắn nhanh": add, edit and delete; in a chat, "/" + keyword inserts one.
private struct QuickMessagesSection: View {
    @Environment(ZaloEngine.self) private var engine
    @State private var keyword = ""
    @State private var text = ""
    @State private var editing: String?
    @State private var busy = false

    var body: some View {
        Section("Tin nhắn nhanh") {
            if let items = engine.quickMessages {
                if items.isEmpty { Text("Chưa có tin nhắn nhanh nào.").foregroundStyle(.secondary) }
                ForEach(items) { item in
                    HStack {
                        Text("/\(item.keyword)").fontWeight(.semibold)
                        Text(item.text).lineLimit(1).foregroundStyle(.secondary)
                        Spacer()
                        Button("Sửa") { editing = item.id; keyword = item.keyword; text = item.text }
                        Button("Xóa", role: .destructive) { Task { await engine.deleteQuickMessage(item.id) } }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
            HStack {
                TextField("Phím tắt", text: $keyword).frame(width: 110)
                TextField("Nội dung tin nhắn", text: $text)
                Button(editing == nil ? "Tạo mới" : "Lưu") {
                    Task {
                        busy = true
                        if await engine.saveQuickMessage(id: editing, keyword: keyword, text: text) {
                            keyword = ""; text = ""; editing = nil
                        }
                        busy = false
                    }
                }
                .disabled(busy || keyword.trimmingCharacters(in: .whitespaces).isEmpty || text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .task { if engine.quickMessages == nil { await engine.loadQuickMessages() } }
    }
}

/// Official privacy toggles: online status and "Đã xem" on the server, the typing indicator here.
private struct AccountPrivacySection: View {
    @Environment(ZaloEngine.self) private var engine
    @AppStorage(OlazPrefs.sendTyping) private var sendTyping = true

    var body: some View {
        Section("Quyền riêng tư") {
            ForEach(PrivacyKey.allCases, id: \.self) { key in
                Toggle(key.title, isOn: Binding(
                    get: { engine.privacy?[key] ?? true },
                    set: { value in Task { await engine.setPrivacy(key, on: value) } }))
                .disabled(engine.privacy == nil)
            }
            Toggle("Hiển thị trạng thái đang soạn tin", isOn: $sendTyping)
        }
        .task { if engine.privacy == nil { await engine.loadPrivacy() } }
    }
}

/// "Tài khoản đã chặn" (official Cài đặt ▸ Quyền riêng tư ▸ Danh sách chặn): who I blocked, with "Bỏ chặn".
private struct BlockedUsersSection: View {
    @Environment(ZaloEngine.self) private var engine
    @State private var busy: String?

    var body: some View {
        Section("Tài khoản đã chặn") {
            if let users = engine.blockedUsers {
                if users.isEmpty {
                    Text("Bạn chưa chặn tài khoản nào.").foregroundStyle(.secondary)
                }
                ForEach(users) { user in
                    HStack(spacing: 10) {
                        RemoteImage(url: user.avatar, contentMode: .fill, maxPixelSize: 64) {
                            Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.tertiary)
                        }
                        .frame(width: 28, height: 28)
                        .clipShape(Circle())
                        Text(user.name.isEmpty ? "Người dùng Zalo" : user.name)
                        Spacer()
                        if busy == user.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Bỏ chặn") {
                                Task { busy = user.id; await engine.setBlocked(user.id, blocked: false); busy = nil }
                            }
                        }
                    }
                }
            } else {
                Text("Đang tải…").foregroundStyle(.secondary)
            }
        }
        .task { await engine.loadBlockedUsers() }
    }
}

// MARK: - Tài khoản

private struct AccountSettings: View {
    @Environment(ZaloEngine.self) private var engine

    var body: some View {
        Section {
            HStack(spacing: 14) {
                if let profile = engine.profile {
                    RemoteAvatar(url: profile.avatar, name: profile.displayName, size: 52)
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.profile?.displayName ?? "Chưa đăng nhập")
                        .font(.system(size: 15, weight: .semibold))
                    if let phone = engine.profile?.phone, !phone.isEmpty {
                        Text(phone).font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("Tài khoản Zalo").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
        Section("Sao lưu & đồng bộ") {
            LabeledContent("Đồng bộ tin nhắn từ điện thoại") {
                Button("Đồng bộ ngay") { engine.startTransfer() }
                    .disabled(!engine.canStartTransfer)
            }
            if let reason = engine.transferStartBlockedReason {
                Text(ZaloEngine.transferBlockedText(reason)).font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("Engine") {
            LabeledContent("Giao thức") { Text("Zalo PC \(engine.clientVersion ?? "—") (mã chính thức)") }
            LabeledContent("Hội thoại") { Text(engine.conversationActions.hiddenKnown ? "\(engine.visibleConversations.count)" : "—") }
            if engine.attestEnforced {
                Label(ZaloEngine.attestWarningText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        Section {
            Button("Đăng xuất", role: .destructive) { engine.logOut() }
                .disabled(engine.profile == nil)
        }
    }
}
