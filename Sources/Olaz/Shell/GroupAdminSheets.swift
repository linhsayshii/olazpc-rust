import AppKit
import SwiftUI

/// "Link tham gia nhóm": the group's join link, copy, and (owner / deputies) a new link or turning it off.
struct GroupLinkSheet: View {
    let groupId: String
    let canManage: Bool

    @Environment(ZaloEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var link: GroupLink?
    @State private var loading = true
    @State private var busy = false
    @State private var confirmOff = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Link tham gia nhóm") { dismiss() }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 60)
                } else if let link, link.enabled {
                    Text(link.link)
                        .font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button("Sao chép link", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link.link, forType: .string)
                            CardActionCenter.shared.show("Đã sao chép link", in: ZaloWireParser.groupConvId(groupId))
                        }
                        if canManage {
                            Button("Tạo link mới", systemImage: "arrow.clockwise") { Task { await set(renew: true) } }
                            Button("Tắt link", role: .destructive) { confirmOff = true }
                        }
                    }
                    .disabled(busy)
                } else {
                    Text("Link tham gia nhóm chưa được kích hoạt").foregroundStyle(.secondary)
                    if canManage {
                        Button("Kích hoạt link tham gia nhóm") { Task { await set(renew: true) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(busy)
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 420)
        .task { link = await engine.groupLink(groupId); loading = false }
        .alert("Tắt link tham gia nhóm?", isPresented: $confirmOff) {
            Button("Tắt link", role: .destructive) { Task { await set(renew: false) } }
            Button("Hủy", role: .cancel) {}
        } message: {
            Text("Link hiện tại sẽ không sử dụng được nữa.")
        }
    }

    private func set(renew: Bool) async {
        busy = true
        if let updated = await engine.setGroupLink(groupId, renew: renew) {
            link = renew && updated.link.isEmpty ? await engine.groupLink(groupId) : updated
        }
        busy = false
    }
}

/// "Phê duyệt thành viên mới": the approval mode and the people waiting ("Duyệt" / "Từ chối").
struct GroupApprovalSheet: View {
    let groupId: String
    let approvalOn: Bool
    var onChange: () -> Void = {}

    @Environment(ZaloEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var on = false
    @State private var pending: [GroupPendingMember]?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Phê duyệt thành viên mới") { dismiss() }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Chế độ phê duyệt thành viên mới", isOn: Binding(get: { on }, set: { value in
                    Task {
                        busy = true
                        if await engine.setGroupJoinApproval(groupId, on: value) { on = value; onChange() }
                        busy = false
                    }
                }))
                .disabled(busy)
                Divider()
                if let pending {
                    if pending.isEmpty {
                        Text("Không có thành viên nào đang chờ phê duyệt").foregroundStyle(.secondary)
                    } else {
                        Text("Danh sách cần phê duyệt: \(pending.count) thành viên").font(.system(size: 12, weight: .semibold))
                        ScrollView {
                            VStack(spacing: 8) {
                                ForEach(pending) { person in
                                    HStack(spacing: 10) {
                                        RemoteAvatar(url: person.avatar, name: person.name, size: 28)
                                        Text(person.name.isEmpty ? "Người dùng Zalo" : person.name).lineLimit(1)
                                        Spacer()
                                        Button("Từ chối") { Task { await review(person, approve: false) } }
                                        Button("Duyệt") { Task { await review(person, approve: true) } }
                                            .buttonStyle(.borderedProminent)
                                    }
                                    .disabled(busy)
                                }
                            }
                        }
                        .frame(maxHeight: 260)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 40)
                }
            }
            .padding(16)
        }
        .frame(width: 420)
        .task {
            on = approvalOn
            pending = await engine.groupPendingMembers(groupId) ?? []
        }
    }

    private func review(_ person: GroupPendingMember, approve: Bool) async {
        busy = true
        if await engine.reviewGroupPending(groupId, uids: [person.id], approve: approve) {
            pending?.removeAll { $0.id == person.id }
            onChange()
        }
        busy = false
    }
}
