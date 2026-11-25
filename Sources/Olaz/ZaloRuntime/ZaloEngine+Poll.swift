import Foundation

// Group polls (MSG_POLL 26), bridged to `HostScripts/poll-adapter.js` (`window.__zaloPoll`; posts
// {page:'main', poll:{id, detail}} / {page:'main', poll:{id, error}}). Everything runs through the official
// GroupPollManager (see the adapter header). Writes (vote / lock / share / create) are only called from explicit
// button presses in `PollViews.swift`.

// MARK: - Poll model

struct PollDetail: Equatable, Sendable, Identifiable {
    struct Option: Equatable, Sendable, Identifiable {
        var id: String
        var content: String
        var votes: Int
        var voted: Bool
    }

    var id: String
    /// Conversation id ("g…") the poll lives in.
    var groupId: String
    var question: String
    var creator: String
    var creatorName: String
    var created: Date?
    var expires: Date?
    var closed: Bool
    /// I have voted (official `joined`).
    var joined: Bool
    var multi: Bool
    var allowAdd: Bool
    var anonymous: Bool
    var hidePreview: Bool
    /// Distinct people who voted.
    var voterCount: Int
    /// Owner / deputy / creator (official `isEnableClose`).
    var canClose: Bool
    var options: [Option]

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        func text(_ key: String) -> String { json[key] as? String ?? "" }
        func flag(_ key: String) -> Bool { (json[key] as? NSNumber)?.boolValue ?? false }
        func date(_ key: String) -> Date? {
            let ms = (json[key] as? NSNumber)?.doubleValue ?? 0
            return ms > 0 && ms < 4_102_444_800_000 ? Date(timeIntervalSince1970: ms / 1000) : nil
        }
        self.id = id
        groupId = text("groupId")
        question = text("question")
        creator = text("creator")
        creatorName = text("creatorName")
        created = date("created")
        expires = date("expired")
        closed = flag("closed")
        joined = flag("joined")
        multi = flag("multi")
        allowAdd = flag("allowAdd")
        anonymous = flag("anonymous")
        hidePreview = flag("hidePreview")
        voterCount = clampedInt((json["voters"] as? NSNumber)?.doubleValue ?? 0)
        canClose = flag("canClose")
        options = (json["options"] as? [[String: Any]] ?? []).compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return Option(id: id, content: row["content"] as? String ?? "",
                          votes: max(0, clampedInt((row["votes"] as? NSNumber)?.doubleValue ?? 0)),
                          voted: (row["voted"] as? NSNumber)?.boolValue ?? false)
        }
    }

    var totalVotes: Int { options.reduce(0) { $0 + $1.votes } }

    func isExpired(at now: Date = .now) -> Bool { expires.map { $0 < now } ?? false }

    /// Votes cannot change any more: closed, expired, or (results hidden until voting) already voted.
    func isVotingLocked(at now: Date = .now) -> Bool { closed || isExpired(at: now) || (hidePreview && joined) }

    /// "Ẩn kết quả khi chưa bình chọn": the numbers are only meaningful after I voted.
    var resultsHidden: Bool { hidePreview && !joined }

    /// Official `isEnableViewDetail`: voter list is offered when the poll is not anonymous and results are visible.
    var votersVisible: Bool { !anonymous && !resultsHidden && totalVotes > 0 }

    func weight(of option: Option) -> Double { totalVotes > 0 ? Double(option.votes) / Double(totalVotes) : 0 }
}

/// What the vote popup edits: which existing options are ticked and the options being added. Mirrors the
/// official reducer (single choice: ticking one unticks the others, added options included).
struct PollVoteDraft: Equatable {
    struct Added: Identifiable, Equatable {
        var id = UUID()
        var text = ""
        var voted = false
    }

    private(set) var selected: Set<String>
    private let original: Set<String>
    private let multi: Bool
    var added: [Added] = []

    init(_ detail: PollDetail) {
        let voted = Set(detail.options.filter(\.voted).map(\.id))
        selected = voted
        original = voted
        multi = detail.multi
    }

    mutating func toggle(_ optionId: String) {
        if selected.contains(optionId) { selected.remove(optionId); return }
        if !multi { selected = []; for i in added.indices { added[i].voted = false } }
        selected.insert(optionId)
    }

    mutating func setAddedVoted(_ id: UUID, _ voted: Bool) {
        guard let at = added.firstIndex(where: { $0.id == id }) else { return }
        if voted && !multi { selected = []; for i in added.indices { added[i].voted = false } }
        added[at].voted = voted
    }

    mutating func addRow() { added.append(Added()) }
    mutating func removeAdded(_ id: UUID) { added.removeAll { $0.id == id } }

    private var filled: [Added] {
        added.map { Added(id: $0.id, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), voted: $0.voted) }.filter { !$0.text.isEmpty }
    }

    /// Anything to send: a changed tick or a new option (official confirm button state).
    var hasChanges: Bool { selected != original || !filled.isEmpty }

    /// Nothing is ticked (existing or added): the official "hide results" confirmation is skipped for this.
    var votesNothing: Bool { selected.isEmpty && !filled.contains(where: \.voted) }

    /// Same trimmed text used twice among the existing and the added options.
    func hasDuplicates(in detail: PollDetail) -> Bool {
        let all = detail.options.map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) } + filled.map(\.text)
        return Set(all).count != all.count
    }

    func isDuplicate(_ id: UUID, in detail: PollDetail) -> Bool {
        guard let row = filled.first(where: { $0.id == id }) else { return false }
        let others = detail.options.map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) } + filled.filter { $0.id != id }.map(\.text)
        return others.contains(row.text)
    }

    /// Arguments of `window.__zaloPoll.vote` (option ids in the poll's own order).
    func request(for detail: PollDetail) -> (newOptions: [[String: Any]], votedIds: [String]) {
        (filled.map { ["voted": $0.voted, "content": $0.text] }, detail.options.map(\.id).filter(selected.contains))
    }

    /// The poll as it would look after this vote (live preview of the bars, like the official popup).
    func applied(to detail: PollDetail) -> PollDetail {
        var next = detail
        for i in next.options.indices {
            let was = detail.options[i].voted, now = selected.contains(detail.options[i].id)
            next.options[i].voted = now
            if was != now { next.options[i].votes = max(0, next.options[i].votes + (now ? 1 : -1)) }
        }
        return next
    }

    var canSubmit: Bool { hasChanges }
}

struct PollVoters: Equatable, Sendable {
    struct User: Identifiable, Equatable, Sendable {
        var id: String { uid }
        var uid: String
        var name: String
        var avatar: URL?
        var isMe: Bool
    }
    struct Group: Identifiable, Equatable, Sendable {
        var id: String
        var content: String
        var votes: Int
        var users: [User]
    }

    /// Anonymous poll / results hidden until I vote: the official client shows no voter list.
    var restricted: Bool
    var groups: [Group]

    init?(json: Any?) {
        guard let object = json as? [String: Any] else { return nil }
        restricted = (object["restricted"] as? NSNumber)?.boolValue ?? false
        groups = (object["groups"] as? [[String: Any]] ?? []).compactMap { row in
            guard let id = row["optionId"] as? String else { return nil }
            let users = (row["users"] as? [[String: Any]] ?? []).compactMap { u -> User? in
                guard let uid = u["uid"] as? String, !uid.isEmpty else { return nil }
                return User(uid: uid, name: u["name"] as? String ?? "", avatar: (u["avatar"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) },
                            isMe: (u["isMe"] as? NSNumber)?.boolValue ?? false)
            }
            return Group(id: id, content: row["content"] as? String ?? "", votes: clampedInt((row["votes"] as? NSNumber)?.doubleValue ?? 0), users: users)
        }
    }
}

/// Official `groupPoll` limits (config) used by the create popup.
struct PollConfig: Equatable, Sendable {
    var minOptions = 2
    var maxOptions = 30
    var maxQuestion = 200
    var maxOption = 120
    var enableAnonymous = true
    var enableHidePreview = true
    /// Options shown on the chat card before "* Còn N lựa chọn khác".
    var displayOptions = 3

    init() {}

    init(json: [String: Any]?) {
        guard let json else { return }
        func count(_ key: String, _ fallback: Int) -> Int {
            let value = clampedInt((json[key] as? NSNumber)?.doubleValue ?? 0)
            return value > 0 ? value : fallback
        }
        minOptions = count("minOptions", minOptions)
        maxOptions = max(minOptions, count("maxOptions", maxOptions))
        maxQuestion = count("maxQuestion", maxQuestion)
        maxOption = count("maxOption", maxOption)
        displayOptions = count("displayOptions", displayOptions)
        enableAnonymous = (json["enableAnonymous"] as? NSNumber)?.boolValue ?? true
        enableHidePreview = (json["enableHidePreview"] as? NSNumber)?.boolValue ?? true
    }
}

struct PollCapabilities: Equatable, Sendable {
    var ready = false
    var canCreate = false
    var canPin = false
    var config = PollConfig()

    init() {}

    init(json: Any?) {
        guard let o = json as? [String: Any] else { return }
        ready = (o["ready"] as? NSNumber)?.boolValue ?? false
        canCreate = (o["canCreate"] as? NSNumber)?.boolValue ?? false
        canPin = (o["canPin"] as? NSNumber)?.boolValue ?? false
        config = PollConfig(json: o["config"] as? [String: Any])
    }
}

/// The "Tạo bình chọn" form (official create popup defaults: multiple choice and "add option" on).
struct PollCreateDraft: Equatable {
    enum Issue: Equatable {
        case emptyQuestion, tooFewOptions(Int), duplicate, pastDeadline
    }

    var question = ""
    var options: [String]
    var hasDeadline = false
    var deadline = Date.now.addingTimeInterval(86_400)
    var pin = false
    var multi = true
    var allowAdd = true
    var hidePreview = false
    var anonymous = false

    init(config: PollConfig = PollConfig()) { options = Array(repeating: "", count: config.minOptions) }

    var trimmedQuestion: String { question.trimmingCharacters(in: .whitespacesAndNewlines) }
    var filledOptions: [String] { options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }

    func isDuplicate(at index: Int) -> Bool {
        guard options.indices.contains(index) else { return false }
        let text = options[index].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return options.enumerated().contains { $0.offset != index && $0.element.trimmingCharacters(in: .whitespacesAndNewlines) == text }
    }

    /// First reason the poll cannot be created yet; nil = ready.
    func issue(config: PollConfig, now: Date = .now) -> Issue? {
        if trimmedQuestion.isEmpty { return .emptyQuestion }
        let filled = filledOptions
        if Set(filled).count != filled.count { return .duplicate }
        if filled.count < config.minOptions { return .tooFewOptions(config.minOptions) }
        if hasDeadline && deadline <= now { return .pastDeadline }
        return nil
    }

    /// "Add option" is meaningless while results are hidden (official create popup disables and sends false).
    var effectiveAllowAdd: Bool { allowAdd && !hidePreview }

    /// Argument of `window.__zaloPoll.create`.
    func spec(config: PollConfig, canPin: Bool) -> [String: Any] {
        [
            "question": String(trimmedQuestion.prefix(config.maxQuestion)),
            "options": filledOptions.map { String($0.prefix(config.maxOption)) },
            "expired": hasDeadline ? Int(deadline.timeIntervalSince1970 * 1000) : 0,
            "pin": pin && canPin, "multi": multi, "allowAdd": effectiveAllowAdd,
            "hidePreview": hidePreview && config.enableHidePreview, "anonymous": anonymous && config.enableAnonymous,
        ]
    }
}

enum PollAction { case vote, lock, share, create, pin, unpin }

struct PollActionResult: Equatable, Sendable {
    var ok: Bool
    var error: String?
    /// The poll was created, but "ghim" was left out (the board is full or could not be checked): pin it from its menu.
    var pinSkipped = false

    /// Official toast / modal texts (lang_vi.json).
    func message(for action: PollAction) -> String {
        switch error {
        case "closed": "Có lỗi xảy ra do bình chọn đã bị khoá"
        case "expired": "Bình chọn đã hết hạn"
        case "network": "Không có mạng, vui lòng kiểm tra lại kết nối và thử lại"
        case "duplicate": "Phương án được thêm đã tồn tại"
        case "forbidden":
            switch action {
            case .create: "Bạn không đủ quyền tạo bình chọn"
            case .pin, .unpin: "Bạn không có quyền thực hiện thao tác này."   // STR_ONLY_ADMIN_INTERACT_PIN_BOARD
            default: "Bạn không có quyền khóa bình chọn này"
            }
        case "limit": "Bảng ghim đã đầy. Hãy bỏ bớt ghim trong Zalo rồi thử lại."
        case "partial": "Đã bỏ ghim cũ nhưng chưa ghim được bình chọn. Vui lòng thử ghim lại."
        case "unknown": "Chưa xác nhận được kết quả. Vui lòng kiểm tra lại bình chọn sau."
        default:
            switch action {
            case .vote: "Có lỗi xảy ra trong quá trình bình chọn."
            case .lock: "Có lỗi xảy ra trong quá trình khóa bình chọn. Vui lòng thử lại."
            case .share: "Có lỗi xảy ra trong quá trình chia sẻ bình chọn. Vui lòng thử lại."
            case .create: "Có lỗi xảy ra trong quá trình tạo bình chọn. Vui lòng kiểm tra lại."
            case .pin: "Ghim bình chọn không thành công. Vui lòng thử lại."
            case .unpin: "Bỏ ghim không thành công. Vui lòng thử lại."
            }
        }
    }
}

/// Whether the group's board lets me pin, and whether this poll is pinned (poll-adapter.js `pinState`; official board topics).
/// Not `ready` = unknown / not offered (not a group, topic board unavailable): the pin item is hidden and nothing is guessed.
struct PollPinState: Equatable, Sendable {
    var ready = false
    /// Official `isEnablePin`: owner / deputy, or members when the group allows setting topics.
    var canPin = false
    var pinned = false
    /// Pinned topics the board holds at most (`pinLimit`).
    var limit = 0

    init() {}

    init(json: Any?) {
        guard let o = json as? [String: Any] else { return }
        ready = (o["ready"] as? NSNumber)?.boolValue ?? false
        canPin = (o["canPin"] as? NSNumber)?.boolValue ?? false
        pinned = (o["pinned"] as? NSNumber)?.boolValue ?? false
        limit = max(0, clampedInt((o["limit"] as? NSNumber)?.doubleValue ?? 0))
    }

    /// The menu offers "Ghim" / "Bỏ ghim" (official: only with `isEnablePin`).
    var offersPin: Bool { ready && canPin }
}

/// The board is full: the official "Cập nhật danh sách ghim" dialog, asked natively. Confirming replaces the oldest pin.
struct PollPinConfirm: Equatable, Sendable {
    /// Identifies the exact topic that would go (sent back with the confirmation).
    var ref: String
    var limit: Int
    var kind: String
    var title: String

    init(ref: String, limit: Int, kind: String, title: String) {
        self.ref = ref
        self.limit = limit
        self.kind = kind
        self.title = title
    }

    init?(json: Any?) {
        guard let o = json as? [String: Any], let ref = o["ref"] as? String, !ref.isEmpty else { return nil }
        self.ref = ref
        limit = max(0, clampedInt((o["limit"] as? NSNumber)?.doubleValue ?? 0))
        let replace = o["replace"] as? [String: Any]
        kind = replace?["kind"] as? String ?? ""
        title = replace?["title"] as? String ?? ""
    }

    /// STR_ONLY_PIN_MAX_CONTENT + STR_DIRECTION_PIN_LIMIT, then the pin that goes.
    var message: String {
        let label: String
        switch kind {
        case "poll": label = "Bình chọn"
        case "reminder": label = "Nhắc hẹn"
        case "message": label = "Tin nhắn"
        default: label = "Ghi chú"
        }
        let head = limit > 0 ? "Đã đạt giới hạn \(limit) ghim. " : ""
        return head + "Ghim cũ dưới đây sẽ được bỏ để cập nhật nội dung mới.\n" + (title.isEmpty ? label : "\(label): \(title)")
    }
}

enum PollPinOutcome: Equatable, Sendable {
    case done
    case needsConfirmation(PollPinConfirm)
    case failed(PollActionResult)
}

struct PollStore: Equatable {
    var details: [String: PollDetail] = [:]
    /// Board state per poll (read when a card / the sheet is on screen).
    var pins: [String: PollPinState] = [:]
    /// Polls whose last read failed (the card offers a retry).
    var failed: Set<String> = []
}

// MARK: - Engine

@MainActor
internal enum PollClock {
    static var refreshTasks: [String: Task<Void, Never>] = [:]
    /// Poll event messages already answered with a refresh (each message once).
    static var seenMessages: Set<String> = []
    /// Polls on screen (id → conversation): re-registered with the page after a WebContent reload.
    static var watched: [String: String] = [:]
    static var lastAttempt: [String: Date] = [:]
    static var didEvictWatched = false
}

extension ZaloEngine {
    func watchPoll(_ id: String, in conversationId: String) {
        guard !id.isEmpty else { return }
        PollClock.watched[id] = conversationId
        if PollClock.watched.count > 500, let drop = PollClock.watched.keys.first(where: { $0 != id }) {
            PollClock.watched[drop] = nil
            PollClock.lastAttempt[drop] = nil
            PollClock.didEvictWatched = true
        }
        guard polls.details[id] == nil else { return }
        let now = Date(timeIntervalSince1970: Double(nowMs()) / 1000.0)
        if let last = PollClock.lastAttempt[id], now.timeIntervalSince(last) < 5 { return }
        PollClock.lastAttempt[id] = now
        polls.failed.remove(id)
        refreshPoll(id)
    }

    func retryPoll(_ id: String, in conversationId: String) {
        PollClock.lastAttempt[id] = Date(timeIntervalSince1970: Double(nowMs()) / 1000.0)
        polls.failed.remove(id)
        refreshPoll(id)
    }

    func rewatchPolls() {
        for (id, _) in PollClock.watched { refreshPoll(id) }
    }

    func refreshPoll(_ id: String) {
        guard !id.isEmpty else { return }
        trackPollTask { [weak self] in
            guard let self else { return }
            guard let box = try? await sessionClient.fetchPollDetail(pollId: id),
                  let dataNode = box.dict["data"] as? [String: Any] else {
                if polls.details[id] == nil { polls.failed.insert(id) }
                return
            }
            let gid = resolvePollGroupId(id: id, payload: dataNode, explicit: nil)
            let cleanGrid = ZaloWireParser.cleanGroupId(gid)
            if !gid.isEmpty, !cleanGrid.isEmpty,
               cachedGroupDetails[cleanGrid] == nil,
               await sessionClient.isAuthenticated {
                await refreshGroupMetadata(gid)
            }
            let normalized = normalizePollDetail(dataNode, id: id, groupId: gid)
            if let detail = PollDetail(json: normalized) {
                polls.failed.remove(id)
                if polls.details[id] != detail { polls.details[id] = detail }
            } else if polls.details[id] == nil {
                polls.failed.insert(id)
            }
        }
    }

    internal func resolvePollGroupId(id: String, payload: [String: Any], explicit: String?) -> String {
        let candidates: [String] = [
            explicit ?? "",
            JSONLossless.string(payload["group_id"] ?? payload["groupId"] ?? payload["grid"]),
            PollClock.watched[id] ?? "",
            polls.details[id]?.groupId ?? ""
        ]
        for raw in candidates {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "0", trimmed != "g0" else { continue }
            let gid = ZaloWireParser.groupConvId(trimmed)
            if !gid.isEmpty { return gid }
        }
        for (convId, list) in messages where ZaloWireParser.isGroupId(convId) {
            if list.contains(where: {
                if case .poll(let info) = $0.kind { return info.pollId == id }
                return false
            }) {
                return ZaloWireParser.groupConvId(convId)
            }
        }
        return ""
    }

    internal func isGroupAdminOrCreator(_ uid: String, inGroup groupId: String) -> Bool {
        let cleanUid = ZaloWireParser.sanitizeProfileUid(uid) ?? ZaloWireParser.stripUserPrefix(uid)
        guard !cleanUid.isEmpty, cleanUid != "0" else { return false }
        let cleanGrid = ZaloWireParser.cleanGroupId(groupId)
        let convId = ZaloWireParser.groupConvId(groupId)
        let info = (!cleanGrid.isEmpty ? cachedGroupDetails[cleanGrid] : nil)
            ?? (!convId.isEmpty ? cachedGroupDetails[convId] : nil)
        guard let info else { return false }

        var privileged = Set<String>()
        func addCandidate(_ raw: Any?) {
            let str = JSONLossless.string(raw)
            let norm = ZaloWireParser.sanitizeProfileUid(str) ?? ZaloWireParser.stripUserPrefix(str)
            if !norm.isEmpty, norm != "0" { privileged.insert(norm) }
        }

        for key in ["creatorId", "creator_id", "ownerId", "owner_id", "creator"] {
            addCandidate(info[key])
        }
        for key in ["adminIds", "admin_ids", "admins", "deputies", "deputyIds"] {
            if let arr = info[key] as? [Any] {
                arr.forEach(addCandidate)
            }
        }
        if let cur = info["currentMems"] as? [[String: Any]] {
            for mem in cur {
                let isAdmin = (JSONLossless.bool(mem["isAdmin"]) == true)
                    || (JSONLossless.bool(mem["isCreator"]) == true)
                if isAdmin {
                    addCandidate(mem["id"] ?? mem["uid"])
                }
            }
        }
        return privileged.contains(cleanUid)
    }

    internal func normalizePollDetail(_ d: [String: Any], id: String, groupId explicitGroupId: String? = nil) -> [String: Any] {
        let myUid = ZaloWireParser.stripUserPrefix(profile?.userId ?? "")
        let creatorId = ZaloWireParser.stripUserPrefix(JSONLossless.string(d["creator"]))
        let resolvedGroupId = resolvePollGroupId(id: id, payload: d, explicit: explicitGroupId)
        let isPollCreator = !myUid.isEmpty && creatorId == myUid
        let isGroupPrivileged = !myUid.isEmpty && !resolvedGroupId.isEmpty && isGroupAdminOrCreator(myUid, inGroup: resolvedGroupId)
        let optionsRaw = (d["options"] as? [[String: Any]]) ?? []
        var totalVoters = Set<String>()
        var options: [[String: Any]] = []
        for opt in optionsRaw {
            let optId = JSONLossless.string(opt["option_id"] ?? opt["id"])
            let voters = (opt["voters"] as? [Any] ?? []).map { ZaloWireParser.stripUserPrefix(JSONLossless.string($0)) }.filter { !$0.isEmpty }
            voters.forEach { totalVoters.insert($0) }
            options.append([
                "id": optId,
                "content": JSONLossless.string(opt["content"]),
                "votes": voters.count,
                "voted": !myUid.isEmpty && voters.contains(myUid),
                "voters": voters
            ])
        }
        return [
            "id": id,
            "groupId": resolvedGroupId,
            "question": JSONLossless.string(d["question"]),
            "creator": creatorId,
            "creatorName": lookupPersonInfo(creatorId)?.name ?? "Thành viên",
            "multi": d["is_multi_choice"] as? Bool ?? false,
            "allowAdd": d["is_add_new_option"] as? Bool ?? false,
            "anonymous": d["is_anonymous"] as? Bool ?? false,
            "hidePreview": d["is_hide_vote_preview"] as? Bool ?? false,
            "closed": (JSONLossless.int64(d["status"]) == 0),
            "expired": (JSONLossless.int64(d["expired_time"]) ?? 0) * 1000,
            "voters": totalVoters.count,
            "canClose": isPollCreator || isGroupPrivileged,
            "joined": !myUid.isEmpty && totalVoters.contains(myUid),
            "options": options
        ]
    }

    func pollVoters(_ id: String) async -> PollVoters? {
        guard let box = try? await sessionClient.fetchPollDetail(pollId: id),
              let d = box.dict["data"] as? [String: Any] else { return nil }
        let anonymous = d["is_anonymous"] as? Bool ?? false
        let myUid = profile?.userId ?? ""
        let optionsRaw = (d["options"] as? [[String: Any]]) ?? []
        let groups: [[String: Any]] = optionsRaw.map { opt in
            let voters = (opt["voters"] as? [Any] ?? []).map { ZaloWireParser.stripUserPrefix(JSONLossless.string($0)) }
            let users: [[String: Any]] = anonymous ? [] : voters.map { uid in
                let info = lookupPersonInfo(uid)
                return ["uid": uid, "name": info?.name ?? ReactionDetail.unknownName, "avatar": info?.avatar ?? "", "isMe": uid == myUid]
            }
            return [
                "optionId": JSONLossless.string(opt["option_id"] ?? opt["id"]),
                "content": JSONLossless.string(opt["content"]),
                "votes": voters.count,
                "users": users
            ]
        }
        return PollVoters(json: ["restricted": anonymous, "groups": groups])
    }

    @discardableResult
    func refreshPollPin(_ id: String, in conversationId: String) async -> PollPinState {
        let isGroup = ZaloWireParser.isGroupId(conversationId)
        if isGroup, pins[conversationId] == nil, await sessionClient.isAuthenticated {
            await refreshBoardPins(for: conversationId)
        }
        let board = pins[conversationId]?.items ?? []
        let isPinned = board.contains { $0.kind == .poll && $0.ref == id }
        let state = PollPinState(json: ["ready": isGroup, "canPin": isGroup, "pinned": isPinned, "limit": 5])
        if (state.ready || polls.pins[id] == nil), polls.pins[id] != state { polls.pins[id] = state }
        return polls.pins[id] ?? state
    }

    internal static func mapPollPinError(_ error: Error, partial: Bool = false) -> PollActionResult {
        if partial {
            return PollActionResult(ok: false, error: "partial")
        }
        if let err = error as? ZaloSessionError {
            let msg = err.message.lowercased()
            if err.code == 1005 || err.code == 1010 || err.code == 201
                || msg.contains("limit") || msg.contains("max") || msg.contains("full")
                || msg.contains("giới hạn") || msg.contains("tối đa") {
                return PollActionResult(ok: false, error: "limit")
            }
            if err.code == 112 || err.code == 114 || err.code == 200 || err.code == 403
                || msg.contains("permission") || msg.contains("forbidden") || msg.contains("admin")
                || msg.contains("quyền") || msg.contains("not allowed") {
                return PollActionResult(ok: false, error: "forbidden")
            }
            return PollActionResult(ok: false, error: nil)
        }
        if error is ZaloTransportError || error is URLError {
            return PollActionResult(ok: false, error: "network")
        }
        return PollActionResult(ok: false, error: nil)
    }

    func pinPoll(_ id: String, in conversationId: String, confirming ref: String? = nil) async -> PollPinOutcome {
        guard ZaloWireParser.isGroupId(conversationId), !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed(PollActionResult(ok: false, error: "forbidden"))
        }
        let didUnpinOld: Bool
        if let ref, !ref.isEmpty {
            let boardCache = cachedBoardRawTopics[conversationId]
            do {
                try await sessionClient.unpinBoardTopic(
                    convId: conversationId,
                    topicId: ref,
                    rawTopic: boardCache?.topics[ref].map { ZaloJSONBox($0) },
                    boardVersion: boardCache?.version ?? 0
                )
            } catch {
                return .failed(Self.mapPollPinError(error))
            }
            didUnpinOld = true
        } else {
            didUnpinOld = false
        }

        do {
            _ = try await sessionClient.pinBoardItemAPI(groupId: conversationId, topicId: id, topicType: 3)
            await refreshBoardPins(for: conversationId)
            await refreshPollPin(id, in: conversationId)
            return .done
        } catch {
            if didUnpinOld {
                return .failed(Self.mapPollPinError(error, partial: true))
            }
            let mapped = Self.mapPollPinError(error)
            if mapped.error == "limit" {
                await refreshBoardPins(for: conversationId)
                let items = pins[conversationId]?.items ?? []
                if let oldest = items.last, oldest.ref != id {
                    return .needsConfirmation(PollPinConfirm(
                        ref: oldest.ref,
                        limit: max(items.count, 5),
                        kind: oldest.kind.rawValue,
                        title: oldest.title
                    ))
                }
            }
            return .failed(mapped)
        }
    }

    func unpinPoll(_ id: String, in conversationId: String) async -> PollActionResult {
        do {
            let boardCache = cachedBoardRawTopics[conversationId]
            try await sessionClient.unpinBoardTopic(
                convId: conversationId,
                topicId: id,
                rawTopic: boardCache?.topics[id].map { ZaloJSONBox($0) },
                boardVersion: boardCache?.version ?? 0
            )
            await refreshBoardPins(for: conversationId)
            await refreshPollPin(id, in: conversationId)
            return PollActionResult(ok: true)
        } catch {
            return PollActionResult(ok: false, error: "network")
        }
    }

    func pollCapabilities(in conversationId: String) async -> PollCapabilities {
        let isGroup = ZaloWireParser.isGroupId(conversationId)
        return PollCapabilities(json: ["ready": isGroup, "canCreate": isGroup, "canPin": isGroup])
    }

    func votePoll(_ id: String, in conversationId: String, draft: PollVoteDraft, detail: PollDetail) async -> PollActionResult {
        let request = draft.request(for: detail)
        do {
            if !request.newOptions.isEmpty {
                _ = try await sessionClient.addPollOptionAPI(
                    pollId: id,
                    newOptions: ZaloJSONArrayBox(request.newOptions),
                    votedIds: request.votedIds
                )
            } else {
                _ = try await sessionClient.votePollAPI(pollId: id, optionIds: request.votedIds)
            }
            refreshPoll(id)
            return PollActionResult(ok: true)
        } catch {
            return PollActionResult(ok: false, error: "network")
        }
    }

    func lockPoll(_ id: String, in conversationId: String) async -> PollActionResult {
        do {
            _ = try await sessionClient.lockPollAPI(pollId: id)
            refreshPoll(id)
            return PollActionResult(ok: true)
        } catch {
            return PollActionResult(ok: false, error: "network")
        }
    }

    func sharePoll(_ id: String, in conversationId: String) async -> PollActionResult {
        do {
            _ = try await sessionClient.sharePollAPI(pollId: id)
            return PollActionResult(ok: true)
        } catch {
            return PollActionResult(ok: false, error: "network")
        }
    }

    func createPoll(in conversationId: String, draft: PollCreateDraft, config: PollConfig, canPin: Bool) async -> PollActionResult {
        do {
            let expiredMs = draft.hasDeadline ? Int64(draft.deadline.timeIntervalSince1970 * 1000) : 0
            let box = try await sessionClient.createPollAPI(
                convId: conversationId,
                question: String(draft.trimmedQuestion.prefix(config.maxQuestion)),
                options: draft.filledOptions.map { String($0.prefix(config.maxOption)) },
                expiredTimeMs: expiredMs,
                allowMulti: draft.multi,
                allowAdd: draft.effectiveAllowAdd,
                hideVotePreview: draft.hidePreview && config.enableHidePreview,
                isAnonymous: draft.anonymous && config.enableAnonymous
            )
            if draft.pin && canPin {
                let dataNode = (box.dict["data"] as? [String: Any]) ?? box.dict
                let createdPollId = JSONLossless.string(
                    dataNode["poll_id"] ?? dataNode["pollId"] ?? dataNode["id"]
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                if createdPollId.isEmpty {
                    return PollActionResult(ok: true, pinSkipped: true)
                }
                let pinOutcome = await pinPoll(createdPollId, in: conversationId)
                if case .done = pinOutcome {
                    return PollActionResult(ok: true)
                }
                return PollActionResult(ok: true, pinSkipped: true)
            }
            return PollActionResult(ok: true)
        } catch let err as ZaloSessionError {
            let msg = err.message.lowercased()
            if err.code == 112 || err.code == 114 || err.code == 403
                || msg.contains("permission") || msg.contains("forbidden") || msg.contains("quyền") {
                return PollActionResult(ok: false, error: "forbidden")
            }
            return PollActionResult(ok: false, error: "network")
        } catch {
            return PollActionResult(ok: false, error: "network")
        }
    }

    func notePollMessages(_ incoming: [ChatMessage]) {
        let now = Date(timeIntervalSince1970: Double(nowMs()) / 1000.0)
        for message in incoming {
            guard case .poll(let info) = message.kind, !info.pollId.isEmpty, polls.details[info.pollId] != nil,
                  message.date > now.addingTimeInterval(-120), PollClock.seenMessages.insert(message.id).inserted else { continue }
            if PollClock.seenMessages.count > 2000 { PollClock.seenMessages = [message.id] }
            let id = info.pollId
            PollClock.refreshTasks[id]?.cancel()
            PollClock.refreshTasks[id] = Task { [weak self] in
                let completed: Bool
                if let sleepSeam = self?.pollDebounceSleep {
                    completed = await sleepSeam(1500)
                } else {
                    try? await Task.sleep(for: .milliseconds(1500))
                    completed = !Task.isCancelled
                }
                guard completed, !Task.isCancelled else { return }
                PollClock.refreshTasks[id] = nil
                self?.refreshPoll(id)
            }
        }
    }

    func handlePoll(state: [String: Any]) {
        guard let json = state["poll"] as? [String: Any], let id = json["id"] as? String else { return }
        if let detail = (json["detail"] as? [String: Any]).flatMap(PollDetail.init(json:)) {
            polls.failed.remove(id)
            if polls.details[id] != detail { polls.details[id] = detail }
        } else if json["error"] != nil, polls.details[id] == nil {
            polls.failed.insert(id)
        }
    }

    func resetPolls() {
        polls = PollStore()
        PollClock.refreshTasks.values.forEach { $0.cancel() }
        PollClock.refreshTasks = [:]
        PollClock.seenMessages = []
        PollClock.watched = [:]
        PollClock.lastAttempt = [:]
        PollClock.didEvictWatched = false
    }
}
