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
    // MARK: Actions

    func setConversationFilter(_ type: ConversationTypeFilter, labelIds: [String] = []) {
        conversationExtras.typeFilter = type.rawValue
        conversationExtras.labelFilterIds = labelIds
        rebuildConversationExtras()
    }

    func setConversationLabel(_ conversationId: String, labelId: String?) {
        var next = conversationExtras
        next.labels = next.labels.map { existing in
            var ids = existing.convIds.filter { $0 != conversationId }
            if let labelId, existing.id == labelId, !ids.contains(conversationId) {
                ids.append(conversationId)
            }
            return ConversationExtras.Label(id: existing.id, name: existing.name, colorHex: existing.colorHex, convIds: ids)
        }
        var map: [String: String] = [:]
        for label in next.labels {
            for conv in label.convIds { map[conv] = label.id }
        }
        next.labelByConversation = map
        conversationExtras = next
        rebuildConversationExtras()
        Task { await saveLabelsPreference() }
    }

    func createConversationLabel(name: String, colorHex: String, conversationIds: [String] = []) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var next = conversationExtras
        let id = "lbl_\(nowMs())_\(randomTag4())"
        let label = ConversationExtras.Label(id: id, name: trimmed, colorHex: colorHex, convIds: conversationIds)
        next.labels.append(label)
        var map = next.labelByConversation
        for conv in conversationIds { map[conv] = id }
        next.labelByConversation = map
        conversationExtras = next
        rebuildConversationExtras()
        Task { await saveLabelsPreference() }
    }

    func updateConversationLabel(_ id: String, name: String, colorHex: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var next = conversationExtras
        if let idx = next.labels.firstIndex(where: { $0.id == id }) {
            let existing = next.labels[idx]
            next.labels[idx] = ConversationExtras.Label(id: existing.id, name: trimmed, colorHex: colorHex, convIds: existing.convIds)
            conversationExtras = next
            rebuildConversationExtras()
            Task { await saveLabelsPreference() }
        }
    }

    func deleteConversationLabel(_ id: String) {
        var next = conversationExtras
        next.labels.removeAll { $0.id == id }
        var map: [String: String] = [:]
        for label in next.labels {
            for conv in label.convIds { map[conv] = label.id }
        }
        next.labelByConversation = map
        next.labelFilterIds.removeAll { $0 == id }
        conversationExtras = next
        rebuildConversationExtras()
        Task { await saveLabelsPreference() }
    }

    func reorderConversationLabels(_ ids: [String]) {
        var next = conversationExtras
        let byId = Dictionary(uniqueKeysWithValues: next.labels.map { ($0.id, $0) })
        var ordered = ids.compactMap { byId[$0] }
        let orderedSet = Set(ids)
        for lbl in next.labels where !orderedSet.contains(lbl.id) {
            ordered.append(lbl)
        }
        next.labels = ordered
        conversationExtras = next
        Task { await saveLabelsPreference() }
    }

    // MARK: Persistence & List Filtering

    internal func loadLabelsPreference(from store: ZaloSQLiteStore) async {
        guard let data = try? await store.getPreferenceData(key: "labels"),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return
        }
        var next = conversationExtras
        next.labels = rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return ConversationExtras.Label(
                id: id,
                name: row["name"] as? String ?? "",
                colorHex: row["color"] as? String ?? "#0068FF",
                convIds: row["convIds"] as? [String] ?? []
            )
        }
        var map: [String: String] = [:]
        for label in next.labels {
            for conv in label.convIds { map[conv] = label.id }
        }
        next.labelByConversation = map
        conversationExtras = next
    }

    private func saveLabelsPreference() async {
        let serializedLocal: [[String: Any]] = conversationExtras.labels.map { l in
            ["id": l.id, "name": l.name, "color": l.colorHex, "convIds": l.convIds]
        }
        if let store = sqliteStore,
           let data = try? JSONSerialization.data(withJSONObject: serializedLocal, options: [.sortedKeys]) {
            try? await store.setPreferenceData(key: "labels", data: data)
        }
        // Sync to Zalo server (`/api/convlabel/update`) so labels stay consistent across devices.
        let serverArray: [[String: Any]] = conversationExtras.labels.enumerated().map { idx, l in
            [
                "id": Int(l.id) ?? l.id,
                "text": l.name,
                "color": l.colorHex,
                "conversations": l.convIds,
                "offset": idx
            ]
        }
        if let serverBytes = try? JSONSerialization.data(withJSONObject: serverArray, options: [.sortedKeys]),
           let serverJSON = String(data: serverBytes, encoding: .utf8) {
            try? await sessionClient.updateConversationLabels(labelDataJSON: serverJSON)
        }
    }

    internal func syncConversationLabelsFromServer() async {
        guard let box = try? await sessionClient.fetchConversationLabels() else { return }
        let rawLabelData = box.dict["labelData"]
        let rows: [[String: Any]] = {
            if let arr = rawLabelData as? [[String: Any]] { return arr }
            if let str = rawLabelData as? String,
               let d = str.data(using: .utf8) {
                if let arr = JSONLossless.parseAny(d) as? [[String: Any]] { return arr }
                if let map = JSONLossless.parseObject(d) {
                    return map.values.compactMap { $0 as? [String: Any] }
                }
            }
            if let map = rawLabelData as? [String: Any] {
                return map.values.compactMap { $0 as? [String: Any] }
            }
            return []
        }()
        guard !rows.isEmpty else { return }

        let sortedRows = rows.sorted { (JSONLossless.int64($0["offset"]) ?? 0) < (JSONLossless.int64($1["offset"]) ?? 0) }
        var parsedLabels: [ConversationExtras.Label] = []
        for row in sortedRows {
            let id = JSONLossless.string(row["id"])
            guard !id.isEmpty else { continue }
            let rawText = JSONLossless.string(row["text"] ?? row["name"])
            let textKey = JSONLossless.string(row["textKey"])
            let resolvedName = rawText.isEmpty ? Self.localizedDefaultLabelName(textKey) : rawText
            guard !resolvedName.isEmpty else { continue }
            let color = JSONLossless.string(row["color"]).isEmpty ? "#0068FF" : JSONLossless.string(row["color"])
            let convs = ((row["conversations"] as? [Any]) ?? (row["convIds"] as? [Any]) ?? [])
                .map { ZaloWireParser.normalizeThreadIdFromList(JSONLossless.string($0)) }
                .filter { !$0.isEmpty }
            parsedLabels.append(ConversationExtras.Label(id: id, name: resolvedName, colorHex: color, convIds: convs))
        }
        guard !parsedLabels.isEmpty else { return }

        var next = conversationExtras
        next.labels = parsedLabels
        var map: [String: String] = [:]
        for label in parsedLabels {
            for cid in label.convIds { map[cid] = label.id }
        }
        next.labelByConversation = map
        conversationExtras = next
        rebuildConversationExtras()

        if let store = sqliteStore {
            let serialized: [[String: Any]] = parsedLabels.map { l in
                ["id": l.id, "name": l.name, "color": l.colorHex, "convIds": l.convIds]
            }
            if let data = try? JSONSerialization.data(withJSONObject: serialized, options: [.sortedKeys]) {
                try? await store.setPreferenceData(key: "labels", data: data)
            }
        }
    }

    private static func localizedDefaultLabelName(_ key: String) -> String {
        switch key {
        case "STR_LABEL_CUSTOMER": "Khách hàng"
        case "STR_LABEL_FAMILY": "Gia đình"
        case "STR_LABEL_WORK": "Công việc"
        case "STR_LABEL_FRIENDS": "Bạn bè"
        case "STR_LABEL_REPLY_LATER": "Trả lời sau"
        case "STR_LABEL_COLLEAGUE": "Đồng nghiệp"
        default: key
        }
    }

    internal func rebuildConversationExtras() {
        var next = conversationExtras
        next.loaded = true
        next.archivedEnabled = true

        let visible = conversations.filter { !conversationActions.isHidden($0.id) }
        let friendIds = Set(contacts.friends.map(\.id))
        var computedStrangers: Set<String> = []
        var strangerFolder: [String] = []
        var unreadStrangerChats = 0
        var unreadStrangerMessages = 0
        var newestStrangerId: String?

        if contacts.friendsLoaded {
            for conv in visible where !conv.isGroup && conv.id != selfConversationId && !friendIds.contains(conv.id) {
                computedStrangers.insert(conv.id)
                let lastFromMe = conv.preview?.fromMe ?? false
                if !lastFromMe || conv.unread > 0 {
                    strangerFolder.append(conv.id)
                    if newestStrangerId == nil { newestStrangerId = conv.id }
                    if conv.unread > 0 {
                        unreadStrangerChats += 1
                        unreadStrangerMessages += conv.unread
                    }
                }
            }
        }
        next.strangerIds = computedStrangers
        next.strangerFolderIds = strangerFolder
        next.strangerBox = ConversationExtras.StrangerBox(
            chats: strangerFolder.count,
            unreadChats: unreadStrangerChats,
            unreadMessages: unreadStrangerMessages,
            newestId: newestStrangerId
        )

        let strangerSet = Set(strangerFolder)
        let filter = ConversationTypeFilter(rawValue: next.typeFilter)
        var filtered: [ConversationSummary]
        switch filter {
        case .other:
            filtered = visible.filter { cachedArchivedIds.contains($0.id) }
        case .unread:
            filtered = visible.filter { $0.unread > 0 || cachedUnreadMarks.contains($0.id) }
        case .focused:
            filtered = visible.filter { !cachedArchivedIds.contains($0.id) }
        case .all, .none:
            filtered = visible
        }

        if !next.labelFilterIds.isEmpty {
            let labelSet = Set(next.labelFilterIds)
            filtered = filtered.filter { conv in
                if let assigned = next.labelByConversation[conv.id] {
                    return labelSet.contains(assigned)
                }
                return false
            }
            next.listIds = filtered.map(\.id)
        } else if (filter == .focused || filter == .all || filter == nil) && !strangerSet.isEmpty {
            var ids: [String] = []
            var emittedBox = false
            for conv in filtered {
                if strangerSet.contains(conv.id) && !cachedPinnedIds.contains(conv.id) {
                    if !emittedBox {
                        ids.append(ConversationExtras.strangerBoxId)
                        emittedBox = true
                    }
                    continue
                }
                ids.append(conv.id)
            }
            next.listIds = ids
        } else {
            next.listIds = filtered.map(\.id)
        }
        if next != conversationExtras { conversationExtras = next }
    }

    func handleConversationExtras(state: [String: Any]) {
        guard let json = state["conversationExtras"] as? [String: Any] else { return }
        var next = conversationExtras
        next.loaded = true
        if let id = json["selfConversationId"] as? String, !id.isEmpty { selfConversationId = id }
        if let flag = json["archivedEnabled"] as? Bool { next.archivedEnabled = flag }
        if next != conversationExtras { conversationExtras = next }
    }
}
