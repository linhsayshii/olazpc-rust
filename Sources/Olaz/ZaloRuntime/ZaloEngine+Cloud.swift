import Foundation

// zCloud ("Zalo Cloud" sidebar tab of the official client): storage quota & usage, plan, browsing the media /
// files stored in the cloud, download, delete, auto-free-up setting. Bridged to `HostScripts/zcloud-adapter.js`
// (`window.__zaloCloud`; posts {page:'main', zcloud:{…}} — each key replaces that section). Every call runs through
// the official client's own cloud services (see the adapter header).

enum CloudItemKind: String, Sendable, CaseIterable {
    case photo, video, file, voice, other

    var title: String {
        switch self {
        case .photo: "Ảnh"
        case .video: "Video"
        case .file: "File"
        case .voice: "Tin nhắn thoại"
        case .other: "Khác"
        }
    }

    var symbol: String {
        switch self {
        case .photo: "photo.fill"
        case .video: "play.rectangle.fill"
        case .file: "doc.fill"
        case .voice: "waveform"
        case .other: "questionmark.square.fill"
        }
    }
}

/// One media / file item stored in zCloud, as the official ZCloud table describes it.
struct CloudItem: Identifiable, Hashable, Sendable {
    /// Official `zKey`; the adapter resolves items by it.
    let id: String
    let kind: CloudItemKind
    let conversationId: String
    let conversationName: String
    let size: Int64
    let date: Date?
    /// File name as sent (empty for photos / videos / voice messages).
    let title: String
    let ext: String
    let duration: TimeInterval
    let width: Int
    let height: Int
}

struct CloudPage: Sendable {
    var items: [CloudItem] = []
    var hasMore = false
    var error: String?
}

/// Bytes per category (official usage legend: Ảnh / Video / File / Tin nhắn thoại).
struct CloudBreakdown: Equatable, Sendable {
    var photo: Int64 = 0
    var video: Int64 = 0
    var file: Int64 = 0
    var voice: Int64 = 0
    var total: Int64 { photo + video + file + voice }

    func bytes(_ kind: CloudItemKind) -> Int64 {
        switch kind {
        case .photo: photo
        case .video: video
        case .file: file
        case .voice: voice
        case .other: 0
        }
    }
}

struct CloudState: Equatable {
    enum PlanKind: String, Sendable {
        /// Paid zCloud subscription.
        case paid
        /// Free "Cloud của tôi" only.
        case free
        /// Subscription lapsed, data still downloadable for a while.
        case grace
        /// Free again after the grace period.
        case afterGrace
    }

    struct Plan: Equatable, Sendable {
        var kind: PlanKind
        var name: String
        var quota: Int64
        var usage: Int64
        /// Other family members' usage.
        var family: Int64
        var cloudMedia: Int64
        var messageBackup: Int64
        var myCloud: Int64
        var expireAt: Date?
        /// nil when the server does not say.
        var autoRenew: Bool?
        var months: Int
        /// The personal cloud key (from the phone) is available, so contents can be decrypted.
        var hasKey: Bool
        /// What the phone's storage settings back up automatically (cloud-settings `opt_in`).
        var backupMedia: Bool
        var backupMyCloud: Bool
        var backupMessages: Bool
        var fileLimit: Int64

        var remaining: Int64 { max(0, quota - usage - family) }
        var isPaid: Bool { kind == .paid || kind == .grace }
    }

    struct Conversation: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let avatar: URL?
        let isGroup: Bool
        let total: Int64
        let lastActivity: Date?
    }

    struct Settings: Equatable, Sendable {
        var offloadEnabled = false
        /// Plan, cloud key and server flag all allow the feature.
        var offloadAvailable = false
        var lastOffloadAt: Date?
        var lastOffloadSize: Int64 = 0
        var ttlDays = 0
    }

    var plan: Plan?
    var media = CloudBreakdown()
    var myCloudTypes = CloudBreakdown()
    var conversations: [Conversation] = []
    var settings = Settings()
    /// Bumped by the adapter whenever cloud items were added / removed.
    var changed = 0
    var loaded = false
    /// False when the official hidden-chat lookup was not found: conversation-grouped data is withheld (fail closed).
    var hiddenLookup = true
    /// Official My Cloud (send-to-me) conversation id.
    var selfId: String?
}

enum CloudFetch: Sendable {
    case ready(CloudFile)
    case expired
    case failed(String)
}

/// A cloud item downloaded (through the official path) to the official zCloud cache.
struct CloudFile: Sendable {
    let url: URL
    let kind: CloudItemKind
    let title: String
    let ext: String
    let size: Int64
    let date: Date?
}

struct CloudActionResult: Sendable {
    var ok: Bool
    /// Keys actually deleted / not deleted (delete only).
    var deleted: [String] = []
    var failed: [String] = []
    var error: String?
}

extension ZaloEngine {
    // MARK: Actions

    func refreshCloud() {
        guard traceU4Host("refresh_cloud") else {
            return
        }
        if let core = coreLifecycle.core {
            cloudRefreshTask = Task { [weak self] in
                if let version = try? await core.refreshCloudAsync() {
                    await self?.waitForMirrorVersion(version)
                }
            }
            return
        }
        if sqliteStore == nil {
            applyCloudSnapshot(sqlSummaries: [], existingIdsByConv: [:])
            return
        }
        cloudRefreshTask = Task { [weak self] in
            await self?.performRefreshCloud()
        }
    }

    func performRefreshCloud() async {
        if let core = coreLifecycle.core {
            if let version = try? await core.refreshCloudAsync() {
                await waitForMirrorVersion(version)
            }
            return
        }
        let serverSnapshot = (await sessionClient.account) != nil
            ? await sessionClient.fetchCloudServerSnapshot()
            : nil
        guard let store = sqliteStore else {
            applyCloudSnapshot(sqlSummaries: [], existingIdsByConv: [:], serverSnapshot: serverSnapshot)
            return
        }
        let sqlSummaries = (try? await store.cloudMediaAggregation()) ?? []
        var existingByConv: [String: Set<String>] = [:]
        for (cid, list) in messages where !list.isEmpty {
            let mediaIds = list.compactMap { msg -> String? in
                switch msg.kind {
                case .photo, .video, .voice, .file: return msg.id
                default: return nil
                }
            }
            if !mediaIds.isEmpty {
                existingByConv[cid] = (try? await store.existingMessageIds(convId: cid, ids: mediaIds)) ?? []
            }
        }
        applyCloudSnapshot(sqlSummaries: sqlSummaries, existingIdsByConv: existingByConv, serverSnapshot: serverSnapshot)
    }

    private func resolveCloudConversationMeta(_ convId: String, fallbackName: String = "", fallbackAvatar: String = "", fallbackIsGroup: Bool? = nil) -> (name: String, avatar: URL?, isGroup: Bool) {
        if let conv = conversations.first(where: { $0.id == convId }) {
            return (conv.displayName, conv.avatar, conv.isGroup)
        }
        let ident = lookupConversationIdentity(convId)
        let isGroup = fallbackIsGroup ?? ZaloWireParser.isGroupId(convId)
        let resolvedName: String = {
            if !ident.name.isEmpty && ident.name != convId { return ident.name }
            if !fallbackName.isEmpty { return fallbackName }
            if convId == selfConversationId { return "Cloud của tôi" }
            return isGroup ? "Nhóm" : (ident.name.isEmpty ? convId : ident.name)
        }()
        let resolvedAvatar = ident.avatar ?? (fallbackAvatar.isEmpty ? nil : URL(string: fallbackAvatar))
        return (resolvedName, resolvedAvatar, isGroup)
    }

    private func applyCloudSnapshot(
        sqlSummaries: [StoredCloudConversationSummary],
        existingIdsByConv: [String: Set<String>],
        serverSnapshot: ZaloCloudServerSnapshot? = nil
    ) {
        struct Accumulator {
            var photo: Int64 = 0
            var video: Int64 = 0
            var file: Int64 = 0
            var voice: Int64 = 0
            var lastActivity: Date?
            var fallbackName = ""
            var fallbackAvatar = ""
            var fallbackIsGroup: Bool?

            var total: Int64 { photo + video + file + voice }
        }

        var perConv: [String: Accumulator] = [:]
        for summary in sqlSummaries where !summary.convId.isEmpty {
            var acc = Accumulator()
            acc.photo = summary.photoBytes
            acc.video = summary.videoBytes
            acc.file = summary.fileBytes
            acc.voice = summary.voiceBytes
            acc.lastActivity = summary.lastActivityMs > 0
                ? Date(timeIntervalSince1970: Double(summary.lastActivityMs) / 1000)
                : nil
            acc.fallbackName = summary.convName
            acc.fallbackAvatar = summary.convAvatar
            acc.fallbackIsGroup = summary.isGroup
            perConv[summary.convId] = acc
        }

        for (cid, list) in messages where !cid.isEmpty {
            let persisted = existingIdsByConv[cid] ?? []
            for msg in list where !persisted.contains(msg.id) {
                var acc = perConv[cid] ?? Accumulator()
                let added: Bool
                switch msg.kind {
                case .photo:
                    acc.photo += 150_000
                    added = true
                case .video:
                    acc.video += 1_500_000
                    added = true
                case .voice:
                    acc.voice += 40_000
                    added = true
                case .file(_, let size, _):
                    acc.file += max(0, size)
                    added = true
                default:
                    added = false
                }
                if added {
                    if let l = acc.lastActivity {
                        if msg.date > l { acc.lastActivity = msg.date }
                    } else {
                        acc.lastActivity = msg.date
                    }
                    perConv[cid] = acc
                }
            }
        }

        var next = cloud
        next.loaded = true
        next.selfId = selfConversationId
        next.settings.offloadEnabled = false
        next.settings.offloadAvailable = false

        var mediaBreakdown = CloudBreakdown()
        var myCloudBreakdown = CloudBreakdown()
        var convEntries: [CloudState.Conversation] = []
        let myCloudId = selfConversationId ?? ""

        for (cid, acc) in perConv {
            let conv = conversations.first(where: { $0.id == cid })
            let latest = [acc.lastActivity, conv?.preview?.date].compactMap { $0 }.max()
            if cid == myCloudId && !myCloudId.isEmpty {
                myCloudBreakdown.photo += acc.photo
                myCloudBreakdown.video += acc.video
                myCloudBreakdown.file += acc.file
                myCloudBreakdown.voice += acc.voice
            } else {
                mediaBreakdown.photo += acc.photo
                mediaBreakdown.video += acc.video
                mediaBreakdown.file += acc.file
                mediaBreakdown.voice += acc.voice
            }
            if acc.total > 0 {
                let meta = resolveCloudConversationMeta(
                    cid,
                    fallbackName: acc.fallbackName,
                    fallbackAvatar: acc.fallbackAvatar,
                    fallbackIsGroup: acc.fallbackIsGroup
                )
                convEntries.append(CloudState.Conversation(
                    id: cid,
                    name: meta.name,
                    avatar: meta.avatar,
                    isGroup: meta.isGroup,
                    total: acc.total,
                    lastActivity: latest
                ))
            }
        }

        next.media = mediaBreakdown
        next.myCloudTypes = myCloudBreakdown
        next.conversations = convEntries.sorted { $0.total > $1.total }

        if let serverSnapshot {
            let previousHasKey = next.plan?.hasKey ?? true
            next.plan = CloudState.Plan(
                kind: serverSnapshot.planKind,
                name: serverSnapshot.planName,
                quota: serverSnapshot.quota,
                usage: serverSnapshot.usage,
                family: serverSnapshot.family,
                cloudMedia: serverSnapshot.cloudMedia,
                messageBackup: serverSnapshot.messageBackup,
                myCloud: serverSnapshot.myCloud,
                expireAt: serverSnapshot.expireAt,
                autoRenew: serverSnapshot.autoRenew,
                months: serverSnapshot.months,
                hasKey: previousHasKey,
                backupMedia: serverSnapshot.backupMedia,
                backupMyCloud: serverSnapshot.backupMyCloud,
                backupMessages: serverSnapshot.backupMessages,
                fileLimit: serverSnapshot.fileLimit
            )
        } else if var existingPlan = next.plan {
            if existingPlan.isPaid {
                existingPlan.myCloud = myCloudBreakdown.total
                existingPlan.cloudMedia = mediaBreakdown.total
                existingPlan.usage = myCloudBreakdown.total + mediaBreakdown.total + existingPlan.messageBackup
            } else {
                existingPlan.myCloud = myCloudBreakdown.total
                existingPlan.cloudMedia = 0
                existingPlan.messageBackup = 0
                existingPlan.family = 0
                existingPlan.usage = myCloudBreakdown.total
                if existingPlan.quota <= 0 {
                    existingPlan.quota = 1_073_741_824
                }
            }
            next.plan = existingPlan
        } else {
            next.plan = CloudState.Plan(
                kind: .free,
                name: "Cloud của tôi",
                quota: 1_073_741_824,
                usage: myCloudBreakdown.total,
                family: 0,
                cloudMedia: 0,
                messageBackup: 0,
                myCloud: myCloudBreakdown.total,
                expireAt: nil,
                autoRenew: nil,
                months: 0,
                hasKey: true,
                backupMedia: false,
                backupMyCloud: true,
                backupMessages: true,
                fileLimit: 100 * 1_048_576
            )
        }
        if next != cloud { cloud = next }
    }

    private func cloudItem(from msg: ChatMessage, conversationId cid: String, conversationName convName: String) -> CloudItem? {
        let itemKind: CloudItemKind
        var title = msg.text
        var ext = ""
        var size: Int64 = 0
        var dur: Double = 0
        var w = 0
        var h = 0
        switch msg.kind {
        case .photo(_, let pw, let ph):
            itemKind = .photo; size = 150_000; ext = "jpg"; w = pw; h = ph
        case .video(_, let d, _):
            itemKind = .video; size = 1_500_000; ext = "mp4"; dur = Double(d)
        case .voice(_, let d):
            itemKind = .voice; size = 40_000; ext = "m4a"; dur = Double(d)
        case .file(let name, let sz, _):
            itemKind = .file; title = name; size = max(0, sz); ext = URL(fileURLWithPath: name).pathExtension
        default:
            return nil
        }
        return CloudItem(
            id: "\(cid)|\(msg.id)|\(itemKind.rawValue)",
            kind: itemKind,
            conversationId: cid,
            conversationName: convName,
            size: size,
            date: msg.date,
            title: title,
            ext: ext,
            duration: dur,
            width: w,
            height: h
        )
    }

    private func cloudItem(from stored: StoredCloudMediaItem) -> CloudItem? {
        guard let itemKind = CloudItemKind(rawValue: stored.kindTag) else { return nil }
        let convName = resolveCloudConversationMeta(stored.convId, fallbackName: stored.convName).name
        let title: String
        let ext: String
        switch itemKind {
        case .photo:
            title = stored.text
            ext = "jpg"
        case .video:
            title = stored.text
            ext = "mp4"
        case .voice:
            title = stored.text
            ext = "m4a"
        case .file:
            title = stored.fileName.isEmpty ? stored.text : stored.fileName
            ext = URL(fileURLWithPath: title).pathExtension
        case .other:
            return nil
        }
        return CloudItem(
            id: "\(stored.convId)|\(stored.id)|\(itemKind.rawValue)",
            kind: itemKind,
            conversationId: stored.convId,
            conversationName: convName,
            size: stored.sizeBytes,
            date: stored.tsMs > 0 ? Date(timeIntervalSince1970: Double(stored.tsMs) / 1000) : nil,
            title: title,
            ext: ext,
            duration: Double(stored.durationSec),
            width: stored.width,
            height: stored.height
        )
    }

    private static func sortCloudItems(_ items: inout [CloudItem], bySize: Bool, ascending: Bool) {
        items.sort { a, b in
            if bySize {
                if a.size != b.size {
                    return ascending ? (a.size < b.size) : (a.size > b.size)
                }
                let ad = a.date ?? .distantPast
                let bd = b.date ?? .distantPast
                if ad != bd { return ad > bd }
                return ascending ? (a.id < b.id) : (a.id > b.id)
            }
            let ad = a.date ?? .distantPast
            let bd = b.date ?? .distantPast
            if ad != bd {
                return ascending ? (ad < bd) : (ad > bd)
            }
            return ascending ? (a.id < b.id) : (a.id > b.id)
        }
    }

    func cloudList(conversationId: String?, kind: CloudItemKind?, sortBySize: Bool, ascending: Bool, offset: Int, limit: Int = 60) async -> CloudPage {
        if let core = coreLifecycle.core {
            if let record = try? await core.cloudList(
                convId: conversationId,
                kind: kind?.coreRecord,
                sortBySize: sortBySize,
                ascending: ascending,
                offset: Int64(offset),
                limit: Int64(limit)
            ) {
                return CloudPage(coreRecord: record)
            }
            return CloudPage(items: [], hasMore: false, error: "Không đọc được dữ liệu zCloud từ bộ nhớ cục bộ.")
        }
        let safeOffset = max(0, offset)
        let safeLimit = max(1, limit)
        let tags: [String] = kind.map { [$0.rawValue] } ?? ["photo", "video", "file", "voice"]
        let excludingSelf = (conversationId == nil) ? selfConversationId : nil

        var unsyncedItems: [CloudItem] = []
        let memoryConvs: [String] = conversationId.map { [$0] } ?? Array(messages.keys).filter { $0 != excludingSelf }
        for cid in memoryConvs {
            let memList = messages[cid] ?? []
            guard !memList.isEmpty else { continue }
            let mediaIds = memList.compactMap { msg -> String? in
                switch msg.kind {
                case .photo, .video, .voice, .file: return msg.id
                default: return nil
                }
            }
            guard !mediaIds.isEmpty else { continue }
            let persisted: Set<String>
            if let store = sqliteStore {
                persisted = (try? await store.existingMessageIds(convId: cid, ids: mediaIds)) ?? []
            } else {
                persisted = []
            }
            let convName = resolveCloudConversationMeta(cid).name
            for msg in memList where !persisted.contains(msg.id) {
                guard let item = cloudItem(from: msg, conversationId: cid, conversationName: convName) else { continue }
                if let kind, kind != item.kind { continue }
                unsyncedItems.append(item)
            }
        }

        if let store = sqliteStore {
            if unsyncedItems.isEmpty {
                guard let page = try? await store.cloudMediaItems(
                    convId: conversationId,
                    excludingConvId: excludingSelf,
                    kindTags: tags,
                    sortBySize: sortBySize,
                    ascending: ascending,
                    offset: safeOffset,
                    limit: safeLimit
                ) else {
                    return CloudPage(items: [], hasMore: false, error: "Không đọc được dữ liệu zCloud từ bộ nhớ cục bộ.")
                }
                let mapped = page.items.compactMap { cloudItem(from: $0) }
                return CloudPage(items: mapped, hasMore: page.hasMore, error: nil)
            }

            let sqlPage = try? await store.cloudMediaItems(
                convId: conversationId,
                excludingConvId: excludingSelf,
                kindTags: tags,
                sortBySize: sortBySize,
                ascending: ascending,
                offset: 0,
                limit: safeOffset + safeLimit
            )
            var merged = (sqlPage?.items ?? []).compactMap { cloudItem(from: $0) }
            var seenIds = Set(merged.map(\.id))
            for item in unsyncedItems where seenIds.insert(item.id).inserted {
                merged.append(item)
            }
            Self.sortCloudItems(&merged, bySize: sortBySize, ascending: ascending)
            let sliced = Array(merged.dropFirst(safeOffset).prefix(safeLimit))
            let hasMore = (sqlPage?.hasMore == true) || ((safeOffset + sliced.count) < merged.count)
            return CloudPage(items: sliced, hasMore: hasMore, error: nil)
        }

        Self.sortCloudItems(&unsyncedItems, bySize: sortBySize, ascending: ascending)
        let sliced = Array(unsyncedItems.dropFirst(safeOffset).prefix(safeLimit))
        let hasMore = (safeOffset + sliced.count) < unsyncedItems.count
        return CloudPage(items: sliced, hasMore: hasMore, error: nil)
    }

    func cloudThumbnail(for key: String) async -> MediaResolution {
        if let core = coreLifecycle.core {
            guard let record = try? await core.cloudThumbnail(key: key) else { return .unavailable }
            return MediaResolution(coreRecord: record)
        }
        let parts = key.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return .unavailable }
        let kind: MediaKind = (parts.count >= 3 && parts[2] == "video") ? .videoThumb : .photo
        return await resolveMedia(conversationId: parts[0], messageId: parts[1], kind: kind)
    }

    func cloudFetch(_ key: String) async -> CloudFetch {
        if let core = coreLifecycle.core {
            guard let record = try? await core.cloudFetch(key: key) else {
                return .failed("Không tải được nội dung này lúc này. Vui lòng thử lại sau.")
            }
            return CloudFetch(coreRecord: record)
        }
        let parts = key.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return .failed("Không tìm thấy tệp.") }
        let cid = parts[0]
        let mid = parts[1]
        guard let msg = await findMessageForMedia(conversationId: cid, messageId: mid) else {
            return .failed("Không tìm thấy tệp.")
        }
        switch msg.kind {
        case .photo:
            switch await resolveMedia(conversationId: cid, messageId: mid, kind: .photo) {
            case .file(let local):
                let sz = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int64) ?? 0
                return .ready(CloudFile(url: local, kind: .photo, title: msg.text, ext: local.pathExtension, size: sz, date: msg.date))
            case .expired:
                return .expired
            default:
                break
            }
        case .video:
            switch await resolveMedia(conversationId: cid, messageId: mid, kind: .video) {
            case .file(let local):
                let sz = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int64) ?? 0
                return .ready(CloudFile(url: local, kind: .video, title: msg.text, ext: local.pathExtension, size: sz, date: msg.date))
            case .expired:
                return .expired
            default:
                break
            }
        case .voice(let url, _):
            switch await resolveFile(conversationId: cid, messageId: mid, name: "Tin nhắn thoại.m4a", url: url) {
            case .ready(let local):
                let sz = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int64) ?? 0
                return .ready(CloudFile(url: local, kind: .voice, title: msg.text, ext: local.pathExtension, size: sz, date: msg.date))
            case .expired:
                return .expired
            case .failed(let err):
                return .failed(err)
            }
        case .file(let name, let size, let url):
            switch await resolveFile(conversationId: cid, messageId: mid, name: name, url: url) {
            case .ready(let local):
                let actualSize = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int64) ?? size
                return .ready(CloudFile(url: local, kind: .file, title: name, ext: local.pathExtension, size: actualSize, date: msg.date))
            case .expired:
                return .expired
            case .failed(let err):
                return .failed(err)
            }
        default:
            break
        }
        return .failed("Không tải được nội dung này lúc này. Vui lòng thử lại sau.")
    }

    func cloudDelete(_ keys: [String]) async -> CloudActionResult {
        if let core = coreLifecycle.core {
            guard let record = try? await core.cloudDelete(keys: keys) else {
                await waitForCoreMirrorDrain()
                return CloudActionResult(ok: false, deleted: [], failed: keys)
            }
            await waitForCoreMirrorDrain()
            return CloudActionResult(coreRecord: record)
        }
        var deleted: [String] = []
        for key in keys {
            let parts = key.split(separator: "|", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { continue }
            let cid = parts[0], mid = parts[1]
            if let msg = await findMessageForMedia(conversationId: cid, messageId: mid) {
                try? await sessionClient.deleteMessageForMeAPI(convId: cid, msgId: mid, cliMsgId: mid, senderId: msg.senderId)
                await applyRemoteDelete(convId: cid, msgId: mid, cliMsgId: mid)
                deleted.append(key)
            }
        }
        await performRefreshCloud()
        return CloudActionResult(ok: !deleted.isEmpty, deleted: deleted, failed: keys.filter { !deleted.contains($0) })
    }

    func cloudSetOffload(_ enabled: Bool) async -> CloudActionResult {
        if let core = coreLifecycle.core {
            guard let record = try? await core.cloudSetOffload(enabled: enabled) else {
                await waitForCoreMirrorDrain()
                return CloudActionResult(
                    ok: false,
                    error: "Tự động giải phóng dung lượng zCloud hiện chưa được hỗ trợ trên Olaz. Vui lòng quản lý trên Zalo điện thoại."
                )
            }
            await waitForCoreMirrorDrain()
            return CloudActionResult(coreRecord: record)
        }
        var next = cloud
        next.settings.offloadEnabled = false
        next.settings.offloadAvailable = false
        if next != cloud { cloud = next }
        return CloudActionResult(
            ok: false,
            error: "Tự động giải phóng dung lượng zCloud hiện chưa được hỗ trợ trên Olaz. Vui lòng quản lý trên Zalo điện thoại."
        )
    }

    func resetCloud() {
        cloud = CloudState()
        coreLifecycle.core?.resetCloud()
        CloudThumbnails.shared.reset()
        CloudFiles.purgeAll()
    }

    func handleCloud(state: [String: Any]) {}
}
