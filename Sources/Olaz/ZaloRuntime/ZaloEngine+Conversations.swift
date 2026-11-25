import Foundation
import SwiftUI

// Conversation labels ("Phân loại"), list filters, stranger folder, My Documents id.
// Bridged to `HostScripts/conversations-adapter.js` (`window.__zaloConversations`; posts
// {page:'main', conversationExtras:{…}}). The filters, the label manager and the stranger folder are the
// official client's own (ConvListController, `_label`), see the adapter header for the entry points.

/// Official `FilterType` values the sidebar can request.
enum ConversationTypeFilter: Int, CaseIterable, Identifiable, Sendable {
    case all = 0, unread = 1, focused = 3, other = 4

    var id: Int { rawValue }
    var title: String {
        switch self {
        // The official default tab is "Tất cả" / "Ưu tiên"; Olaz always calls that list "Tin nhắn".
        case .all, .focused: ConversationExtras.inboxTitle
        case .unread: "Chưa đọc"
        case .other: "Khác"
        }
    }
}

struct ConversationExtras: Equatable {
    struct Label: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        /// Hex string as stored by the official client ("#0068ff").
        let colorHex: String
        let convIds: [String]
        var color: Color { Color(hex: colorHex) ?? ZaloTheme.blue }
    }

    struct Limits: Equatable, Sendable {
        var maxLabels = 15
        var maxNameLength = 30
        var palette: [String] = ["#D91B1B", "#F31BC8", "#FF6905", "#FAC000", "#4BC377", "#2AC5BB", "#0068FF", "#6F3FCF"]
    }

    /// The pseudo-row the official list shows for strangers I have not answered (`stranger_box`).
    struct StrangerBox: Equatable, Sendable {
        var chats = 0
        var unreadChats = 0
        var unreadMessages = 0
        var newestId: String?
    }

    /// Result of the latest label action (create / rename / delete / assign).
    struct Notice: Equatable, Sendable {
        let seq: Int
        let ok: Bool
        let text: String
    }

    /// What Olaz's own UI calls the default list (sidebar row, column title, menus), whatever the official tab is named.
    static let inboxTitle = "Tin nhắn"

    /// Official id of the list pseudo-row for the stranger folder.
    static let strangerBoxId = "stranger_box"

    /// True once the official controller has published at least once.
    var loaded = false
    var labels: [Label] = []
    var limits = Limits()
    var archivedEnabled = false
    /// The controller's current filter (echo of what Swift asked for).
    var typeFilter: Int = 0
    var labelFilterIds: [String] = []
    /// Ids of the list the controller computed for the current filter, in display order (may contain `stranger_box`).
    var listIds: [String] = []
    /// Every conversation with a non-friend.
    var strangerIds: Set<String> = []
    /// Folder contents: strangers I have not answered, newest first.
    var strangerFolderIds: [String] = []
    var strangerBox = StrangerBox()
    var unboxStranger = false
    var notice: Notice?

    /// conversation id → label id (a conversation has at most one label).
    var labelByConversation: [String: String] = [:]

    func label(of conversationId: String) -> Label? {
        guard let id = labelByConversation[conversationId] else { return nil }
        return labels.first { $0.id == id }
    }

    /// The label `destination` filters the inbox by; nil for every other destination and for a label that no longer exists.
    func label(filteredBy destination: SidebarDestination) -> Label? {
        guard case .label(let id) = destination else { return nil }
        return labels.first { $0.id == id }
    }

    var tabs: [ConversationTypeFilter] { archivedEnabled ? [.focused, .other, .unread] : [.all, .unread] }
    var defaultTab: ConversationTypeFilter { archivedEnabled ? .focused : .all }
}

extension Color {
    /// "#RRGGBB" / "RRGGBB".
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

extension ZaloEngine {
    // MARK: Actions (delegated to `olaz-core`)

    func setConversationFilter(_ type: ConversationTypeFilter, labelIds: [String] = []) {
        if let core = coreLifecycle.core {
            core.setConversationFilter(filterType: Int32(type.rawValue), labelIds: labelIds)
            return
        }
        let batch = offlineConversationsCore().setConversationFilter(filterType: Int32(type.rawValue), labelIds: labelIds)
        applyCoreChanges(batch)
    }

    func setConversationLabel(_ conversationId: String, labelId: String?) {
        coreLifecycle.core?.setConversationLabel(conversationId: conversationId, labelId: labelId)
    }

    func createConversationLabel(name: String, colorHex: String, conversationIds: [String] = []) {
        coreLifecycle.core?.createConversationLabel(
            name: name,
            colorHex: colorHex,
            conversationIds: conversationIds,
            nowMs: nowMs(),
            rand4: randomTag4()
        )
    }

    func updateConversationLabel(_ id: String, name: String, colorHex: String) {
        coreLifecycle.core?.updateConversationLabel(id: id, name: name, colorHex: colorHex)
    }

    func deleteConversationLabel(_ id: String) {
        coreLifecycle.core?.deleteConversationLabel(id: id)
    }

    func reorderConversationLabels(_ ids: [String]) {
        coreLifecycle.core?.reorderConversationLabels(ids: ids)
    }

    internal func syncConversationLabelsFromServer() async {
        guard let core = await ensureCoreEngine() else { return }
        if let v = try? await core.syncConversationLabels() {
            await waitForMirrorVersion(v)
        }
    }

    internal func rebuildConversationExtras() {
        if let core = coreLifecycle.core {
            core.rebuildConversationExtras()
            return
        }
        let batch = offlineConversationsCore().rebuildConversationExtras()
        applyCoreChanges(batch)
    }

    func handleConversationExtras(state: [String: Any]) {
        let json = Self.jsonString(for: state)
        if let core = coreLifecycle.core {
            core.handleConversationExtras(stateJson: json)
            return
        }
        let batch = offlineConversationsCore().handleConversationExtras(stateJson: json)
        applyCoreChanges(batch)
    }
}
