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
        var next = cloud
        next.loaded = true
        next.selfId = selfConversationId
        var mediaBreakdown = CloudBreakdown()
        var myCloudBreakdown = CloudBreakdown()
        var convEntries: [CloudState.Conversation] = []
        let myCloudId = selfConversationId ?? ""

        for conv in conversations {
            let list = messages[conv.id] ?? []
            var totalBytes: Int64 = 0
            var latest: Date? = conv.preview?.date
            for msg in list {
                if let l = latest { if msg.date > l { latest = msg.date } } else { latest = msg.date }
                switch msg.kind {
                case .photo:
                    let sz: Int64 = 150_000
                    totalBytes += sz
                    if conv.id == myCloudId { myCloudBreakdown.photo += sz } else { mediaBreakdown.photo += sz }
                case .video:
                    let sz: Int64 = 1_500_000
                    totalBytes += sz
                    if conv.id == myCloudId { myCloudBreakdown.video += sz } else { mediaBreakdown.video += sz }
                case .voice:
                    let sz: Int64 = 40_000
                    totalBytes += sz
                    if conv.id == myCloudId { myCloudBreakdown.voice += sz } else { mediaBreakdown.voice += sz }
                case .file(_, let size, _):
                    let sz = max(0, size)
                    totalBytes += sz
                    if conv.id == myCloudId { myCloudBreakdown.file += sz } else { mediaBreakdown.file += sz }
                default:
                    break
                }
            }
            if totalBytes > 0 {
                convEntries.append(CloudState.Conversation(
                    id: conv.id, name: conv.displayName, avatar: conv.avatar,
                    isGroup: conv.isGroup, total: totalBytes, lastActivity: latest
                ))
            }
        }
        next.media = mediaBreakdown
        next.myCloudTypes = myCloudBreakdown
        next.conversations = convEntries.sorted { $0.total > $1.total }
        let totalUsed = myCloudBreakdown.total + mediaBreakdown.total
        if var existingPlan = next.plan {
            existingPlan.usage = max(existingPlan.usage, totalUsed)
            existingPlan.myCloud = max(existingPlan.myCloud, myCloudBreakdown.total)
            existingPlan.cloudMedia = max(existingPlan.cloudMedia, mediaBreakdown.total)
            next.plan = existingPlan
        } else {
            next.plan = CloudState.Plan(
                kind: .free,
                name: "Cloud của tôi",
                quota: 1_073_741_824,
                usage: totalUsed,
                family: 0,
                cloudMedia: mediaBreakdown.total,
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

    func cloudList(conversationId: String?, kind: CloudItemKind?, sortBySize: Bool, ascending: Bool, offset: Int, limit: Int = 60) async -> CloudPage {
        var items: [CloudItem] = []
        let targetConvs = conversationId.map { [$0] } ?? conversations.map(\.id)
        for cid in targetConvs {
            let convName = conversations.first(where: { $0.id == cid })?.displayName ?? cid
            for msg in messages[cid] ?? [] {
                let itemKind: CloudItemKind
                var title = msg.text
                var ext = ""
                var size: Int64 = 0
                var dur: Double = 0
                switch msg.kind {
                case .photo:
                    itemKind = .photo; size = 150_000; ext = "jpg"
                case .video(_, let d, _):
                    itemKind = .video; size = 1_500_000; ext = "mp4"; dur = Double(d)
                case .voice(_, let d):
                    itemKind = .voice; size = 40_000; ext = "m4a"; dur = Double(d)
                case .file(let name, let sz, _):
                    itemKind = .file; title = name; size = sz; ext = URL(fileURLWithPath: name).pathExtension
                default:
                    continue
                }
                if let kind, kind != itemKind { continue }
                items.append(CloudItem(
                    id: "\(cid)|\(msg.id)|\(itemKind.rawValue)",
                    kind: itemKind,
                    conversationId: cid,
                    conversationName: convName,
                    size: size,
                    date: msg.date,
                    title: title,
                    ext: ext,
                    duration: dur,
                    width: 0,
                    height: 0
                ))
            }
        }
        items.sort { a, b in
            if sortBySize {
                return ascending ? (a.size < b.size) : (a.size > b.size)
            }
            let ad = a.date ?? .distantPast
            let bd = b.date ?? .distantPast
            return ascending ? (ad < bd) : (ad > bd)
        }
        let sliced = Array(items.dropFirst(offset).prefix(limit))
        let hasMore = (offset + sliced.count) < items.count
        return CloudPage(items: sliced, hasMore: hasMore, error: nil)
    }

    func cloudThumbnail(for key: String) async -> MediaResolution {
        let parts = key.split(separator: "|").map(String.init)
        guard parts.count >= 2 else { return .unavailable }
        let kind: MediaKind = (parts.count >= 3 && parts[2] == "video") ? .videoThumb : .photo
        return await resolveMedia(conversationId: parts[0], messageId: parts[1], kind: kind)
    }

    func cloudFetch(_ key: String) async -> CloudFetch {
        let parts = key.split(separator: "|").map(String.init)
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
        var deleted: [String] = []
        for key in keys {
            let parts = key.split(separator: "|").map(String.init)
            guard parts.count >= 2 else { continue }
            let cid = parts[0], mid = parts[1]
            if let msg = messages[cid]?.first(where: { $0.id == mid }) {
                try? await sessionClient.deleteMessageForMeAPI(convId: cid, msgId: mid, cliMsgId: mid, senderId: msg.senderId)
                await applyRemoteDelete(convId: cid, msgId: mid, cliMsgId: mid)
                deleted.append(key)
            }
        }
        refreshCloud()
        return CloudActionResult(ok: !deleted.isEmpty, deleted: deleted, failed: keys.filter { !deleted.contains($0) })
    }

    func cloudSetOffload(_ enabled: Bool) async -> CloudActionResult {
        var next = cloud
        next.settings.offloadEnabled = enabled
        cloud = next
        return CloudActionResult(ok: true)
    }

    func resetCloud() {
        cloud = CloudState()
        CloudThumbnails.shared.reset()
        CloudFiles.purgeAll()
    }

    func handleCloud(state: [String: Any]) {}
}
