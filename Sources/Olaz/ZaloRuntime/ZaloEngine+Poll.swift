import Foundation
import OlazCore

// Group polls (MSG_POLL 26) backed by `olaz-core` (`PollsState` + `PollClock` + pure draft/config models).
// Writes (vote / lock / share / create / pin / unpin) are triggered from explicit actions in `PollViews.swift`.

private func pollJsonObjectString(_ dict: [String: Any]) -> String? {
    guard JSONSerialization.isValidJSONObject(dict),
          let data = try? JSONSerialization.data(withJSONObject: dict),
          let text = String(data: data, encoding: .utf8) else {
        return nil
    }
    return text
}

// MARK: - Poll model

struct PollDetail: Equatable, Sendable, Identifiable {
    struct Option: Equatable, Sendable, Identifiable {
        var id: String
        var content: String
        var votes: Int
        var voted: Bool
        fileprivate var cachedWeight: Double

        init(id: String, content: String, votes: Int, voted: Bool, weight: Double = 0) {
            self.id = id
            self.content = content
            self.votes = votes
            self.voted = voted
            self.cachedWeight = weight
        }

        init(coreRecord r: PollOptionRecord) {
            self.id = r.id
            self.content = r.content
            self.votes = Int(r.votes)
            self.voted = r.voted
            self.cachedWeight = r.weight
        }

        var coreRecord: PollOptionRecord {
            PollOptionRecord(id: id, content: content, votes: Int64(votes), voted: voted, weight: cachedWeight)
        }

        static func == (lhs: Option, rhs: Option) -> Bool {
            lhs.id == rhs.id && lhs.content == rhs.content && lhs.votes == rhs.votes && lhs.voted == rhs.voted
        }
    }

    var id: String
    /// Conversation id ("g…") the poll lives in.
    var groupId: String
    var question: String
    var creator: String
    var creatorName: String
    var created: Date?
    var expires: Date?
    private let expiresMs: Int64?
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
    /// Precomputed in core once per detail update.
    let totalVotes: Int
    /// "Ẩn kết quả khi chưa bình chọn": the numbers are only meaningful after I voted.
    let resultsHidden: Bool
    /// Official `isEnableViewDetail`: voter list is offered when the poll is not anonymous and results are visible.
    let votersVisible: Bool
    private let lockedWithoutExpiry: Bool
    fileprivate let hasDuplicateOptions: Bool
    var options: [Option]

    init(coreRecord r: PollDetailRecord) {
        self.id = r.id
        self.groupId = r.groupId
        self.question = r.question
        self.creator = r.creator
        self.creatorName = r.creatorName
        self.created = r.createdMs.map { Date(timeIntervalSince1970: Double($0) / 1000.0) }
        self.expires = r.expiresMs.map { Date(timeIntervalSince1970: Double($0) / 1000.0) }
        self.expiresMs = r.expiresMs
        self.closed = r.closed
        self.joined = r.joined
        self.multi = r.multi
        self.allowAdd = r.allowAdd
        self.anonymous = r.anonymous
        self.hidePreview = r.hidePreview
        self.voterCount = Int(r.voterCount)
        self.canClose = r.canClose
        self.totalVotes = Int(r.totalVotes)
        self.resultsHidden = r.resultsHidden
        self.votersVisible = r.votersVisible
        self.lockedWithoutExpiry = r.lockedWithoutExpiry
        self.hasDuplicateOptions = r.hasDuplicateOptions
        self.options = r.options.map(Option.init(coreRecord:))
    }

    init?(json: [String: Any]) {
        guard let jsonStr = pollJsonObjectString(json),
              let rec = pollDetailFromJson(json: jsonStr) else {
            return nil
        }
        self.init(coreRecord: rec)
    }

    var coreRecord: PollDetailRecord {
        PollDetailRecord(
            id: id,
            groupId: groupId,
            question: question,
            creator: creator,
            creatorName: creatorName,
            createdMs: created.map { Int64(($0.timeIntervalSince1970 * 1000.0).rounded()) },
            expiresMs: expires.map { Int64(($0.timeIntervalSince1970 * 1000.0).rounded()) },
            closed: closed,
            joined: joined,
            multi: multi,
            allowAdd: allowAdd,
            anonymous: anonymous,
            hidePreview: hidePreview,
            voterCount: Int64(voterCount),
            canClose: canClose,
            totalVotes: Int64(totalVotes),
            resultsHidden: resultsHidden,
            votersVisible: votersVisible,
            lockedWithoutExpiry: lockedWithoutExpiry,
            hasDuplicateOptions: hasDuplicateOptions,
            options: options.map(\.coreRecord)
        )
    }

    static func == (lhs: PollDetail, rhs: PollDetail) -> Bool {
        lhs.id == rhs.id
            && lhs.groupId == rhs.groupId
            && lhs.question == rhs.question
            && lhs.creator == rhs.creator
            && lhs.creatorName == rhs.creatorName
            && lhs.created == rhs.created
            && lhs.expires == rhs.expires
            && lhs.closed == rhs.closed
            && lhs.joined == rhs.joined
            && lhs.multi == rhs.multi
            && lhs.allowAdd == rhs.allowAdd
            && lhs.anonymous == rhs.anonymous
            && lhs.hidePreview == rhs.hidePreview
            && lhs.voterCount == rhs.voterCount
            && lhs.canClose == rhs.canClose
            && lhs.options == rhs.options
    }

    func isExpired(at now: Date = .now) -> Bool {
        guard let expiresMs else { return false }
        let nowMs = Int64((now.timeIntervalSince1970 * 1000.0).rounded())
        return expiresMs < nowMs
    }

    /// Votes cannot change any more: closed, expired, or (results hidden until voting) already voted.
    func isVotingLocked(at now: Date = .now) -> Bool {
        lockedWithoutExpiry || isExpired(at: now)
    }

    func weight(of option: Option) -> Double {
        option.cachedWeight
    }
}

/// What the vote popup edits: which existing options are ticked and the options being added. Mirrors the
/// official reducer (single choice: ticking one unticks the others, added options included).
struct PollVoteDraft: Equatable {
    struct Added: Identifiable, Equatable {
        var id = UUID()
        var text = ""
        var voted = false
        fileprivate var cachedDuplicate = false

        init(id: UUID = UUID(), text: String = "", voted: Bool = false, isDuplicate: Bool = false) {
            self.id = id
            self.text = text
            self.voted = voted
            self.cachedDuplicate = isDuplicate
        }

        static func == (lhs: Added, rhs: Added) -> Bool {
            lhs.id == rhs.id && lhs.text == rhs.text && lhs.voted == rhs.voted
        }
    }

    private(set) var selected: Set<String>
    private let original: Set<String>
    private let multi: Bool
    private var baseDetail: PollDetail
    private var selectionChanged: Bool
    private var selectionEmpty: Bool
    private var cachedHasChanges: Bool
    private var cachedVotesNothing: Bool
    private var cachedHasDuplicates: Bool
    private var cachedApplied: PollDetail
    private var cachedAdded: [Added] = []
    private var isMutatingFromCore = false

    var added: [Added] {
        get { cachedAdded }
        set {
            cachedAdded = newValue
            if !isMutatingFromCore {
                recomputeInCore()
            }
        }
    }

    init(_ detail: PollDetail) {
        let rec = pollVoteDraftNew(detail: detail.coreRecord)
        baseDetail = detail
        selected = Set(rec.selected)
        original = Set(rec.original)
        multi = rec.multi
        selectionChanged = rec.selectionChanged
        selectionEmpty = rec.selectionEmpty
        cachedHasChanges = rec.hasChanges
        cachedVotesNothing = rec.votesNothing
        cachedHasDuplicates = rec.hasDuplicates
        cachedApplied = rec.applied.map(PollDetail.init(coreRecord:)) ?? detail
        cachedAdded = rec.added.map { row in
            Added(id: UUID(uuidString: row.id) ?? UUID(), text: row.text, voted: row.voted, isDuplicate: row.isDuplicate)
        }
    }

    static func == (lhs: PollVoteDraft, rhs: PollVoteDraft) -> Bool {
        lhs.selected == rhs.selected
            && lhs.original == rhs.original
            && lhs.multi == rhs.multi
            && lhs.cachedAdded == rhs.cachedAdded
    }

    var coreRecord: PollVoteDraftRecord {
        PollVoteDraftRecord(
            selected: selected.sorted(),
            original: original.sorted(),
            multi: multi,
            added: cachedAdded.map {
                AddedPollOptionRecord(
                    id: $0.id.uuidString,
                    text: $0.text,
                    voted: $0.voted,
                    isDuplicate: $0.cachedDuplicate
                )
            },
            selectionChanged: selectionChanged,
            selectionEmpty: selectionEmpty,
            hasChanges: cachedHasChanges,
            votesNothing: cachedVotesNothing,
            hasDuplicates: cachedHasDuplicates,
            applied: cachedApplied.coreRecord
        )
    }

    private mutating func applyCoreRecord(_ rec: PollVoteDraftRecord) {
        isMutatingFromCore = true
        defer { isMutatingFromCore = false }
        selected = Set(rec.selected)
        selectionChanged = rec.selectionChanged
        selectionEmpty = rec.selectionEmpty
        cachedHasChanges = rec.hasChanges
        cachedVotesNothing = rec.votesNothing
        cachedHasDuplicates = rec.hasDuplicates
        if let app = rec.applied {
            cachedApplied = PollDetail(coreRecord: app)
        }
        cachedAdded = rec.added.map { row in
            Added(id: UUID(uuidString: row.id) ?? UUID(), text: row.text, voted: row.voted, isDuplicate: row.isDuplicate)
        }
    }

    private mutating func recomputeInCore() {
        applyCoreRecord(pollVoteDraftRecompute(draft: coreRecord, detail: baseDetail.coreRecord))
    }

    mutating func toggle(_ optionId: String) {
        applyCoreRecord(pollVoteDraftToggle(draft: coreRecord, optionId: optionId, detail: baseDetail.coreRecord))
    }

    mutating func setAddedVoted(_ id: UUID, _ voted: Bool) {
        applyCoreRecord(pollVoteDraftSetAddedVoted(draft: coreRecord, id: id.uuidString, voted: voted, detail: baseDetail.coreRecord))
    }

    mutating func addRow() {
        cachedAdded.append(Added())
        recomputeInCore()
    }

    mutating func removeAdded(_ id: UUID) {
        cachedAdded.removeAll { $0.id == id }
        recomputeInCore()
    }

    /// Anything to send: a changed tick or a new option (official confirm button state).
    var hasChanges: Bool { cachedHasChanges }

    /// Nothing is ticked (existing or added): the official "hide results" confirmation is skipped for this.
    var votesNothing: Bool { cachedVotesNothing }

    /// Same trimmed text used twice among the existing and the added options.
    func hasDuplicates(in detail: PollDetail) -> Bool {
        detail == baseDetail ? cachedHasDuplicates : pollVoteDraftHasDuplicates(draft: coreRecord, detail: detail.coreRecord)
    }

    func isDuplicate(_ id: UUID, in detail: PollDetail) -> Bool {
        if detail == baseDetail {
            return cachedAdded.first { $0.id == id }?.cachedDuplicate ?? false
        }
        return pollVoteDraftIsDuplicate(draft: coreRecord, id: id.uuidString, detail: detail.coreRecord)
    }

    /// Arguments of the vote / add-option request (option ids in the poll's own order).
    func request(for detail: PollDetail) -> (newOptions: [[String: Any]], votedIds: [String]) {
        let req = pollVoteDraftRequest(draft: coreRecord, detail: detail.coreRecord)
        let opts: [[String: Any]] = req.newOptions.map { ["voted": $0.voted, "content": $0.content] }
        return (opts, req.votedIds)
    }

    /// The poll as it would look after this vote (live preview of the bars, like the official popup).
    func applied(to detail: PollDetail) -> PollDetail {
        detail == baseDetail ? cachedApplied : PollDetail(coreRecord: pollVoteDraftApplied(draft: coreRecord, detail: detail.coreRecord))
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

    init(coreRecord r: PollVotersRecord) {
        restricted = r.restricted
        groups = r.groups.map { g in
            Group(
                id: g.id,
                content: g.content,
                votes: Int(g.votes),
                users: g.users.map { u in
                    User(
                        uid: u.uid,
                        name: u.name,
                        avatar: u.avatar.flatMap { $0.isEmpty ? nil : URL(string: $0) },
                        isMe: u.isMe
                    )
                }
            )
        }
    }

    init?(json: Any?) {
        guard let object = json as? [String: Any],
              let jsonStr = pollJsonObjectString(object),
              let rec = pollVotersFromJson(json: jsonStr) else {
            return nil
        }
        self.init(coreRecord: rec)
    }
}

/// Official `groupPoll` limits (config) used by the create popup.
struct PollConfig: Equatable, Sendable {
    var minOptions: Int
    var maxOptions: Int
    var maxQuestion: Int
    var maxOption: Int
    var enableAnonymous: Bool
    var enableHidePreview: Bool
    /// Options shown on the chat card before "* Còn N lựa chọn khác".
    var displayOptions: Int

    init(coreRecord r: PollConfigRecord) {
        minOptions = Int(r.minOptions)
        maxOptions = Int(r.maxOptions)
        maxQuestion = Int(r.maxQuestion)
        maxOption = Int(r.maxOption)
        enableAnonymous = r.enableAnonymous
        enableHidePreview = r.enableHidePreview
        displayOptions = Int(r.displayOptions)
    }

    init() {
        self.init(coreRecord: pollConfigDefault())
    }

    init(json: [String: Any]?) {
        let jsonStr = json.flatMap(pollJsonObjectString)
        self.init(coreRecord: pollConfigFromJson(json: jsonStr))
    }

    var coreRecord: PollConfigRecord {
        PollConfigRecord(
            minOptions: Int64(minOptions),
            maxOptions: Int64(maxOptions),
            maxQuestion: Int64(maxQuestion),
            maxOption: Int64(maxOption),
            enableAnonymous: enableAnonymous,
            enableHidePreview: enableHidePreview,
            displayOptions: Int64(displayOptions)
        )
    }
}

struct PollCapabilities: Equatable, Sendable {
    var ready = false
    var canCreate = false
    var canPin = false
    var config = PollConfig()

    init(coreRecord r: PollCapabilitiesRecord) {
        ready = r.ready
        canCreate = r.canCreate
        canPin = r.canPin
        config = PollConfig(coreRecord: r.config)
    }

    init() {}

    init(json: Any?) {
        let jsonStr = (json as? [String: Any]).flatMap(pollJsonObjectString)
        self.init(coreRecord: pollCapabilitiesFromJson(json: jsonStr))
    }
}

/// The "Tạo bình chọn" form (official create popup defaults: multiple choice and "add option" on).
struct PollCreateDraft: Equatable {
    enum Issue: Equatable {
        case emptyQuestion, tooFewOptions(Int), duplicate, pastDeadline

        init(coreRecord r: PollCreateIssueRecord) {
            switch r {
            case .emptyQuestion: self = .emptyQuestion
            case .tooFewOptions(let min): self = .tooFewOptions(Int(min))
            case .duplicate: self = .duplicate
            case .pastDeadline: self = .pastDeadline
            }
        }
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

    var coreRecord: PollCreateDraftRecord {
        PollCreateDraftRecord(
            question: question,
            options: options,
            hasDeadline: hasDeadline,
            deadlineMs: Int64(deadline.timeIntervalSince1970 * 1000.0),
            pin: pin,
            multi: multi,
            allowAdd: allowAdd,
            hidePreview: hidePreview,
            anonymous: anonymous
        )
    }

    var trimmedQuestion: String { question.trimmingCharacters(in: .whitespacesAndNewlines) }
    var filledOptions: [String] { options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }

    func isDuplicate(at index: Int) -> Bool {
        guard index >= 0 else { return false }
        return pollCreateDraftIsDuplicate(draft: coreRecord, index: UInt64(index))
    }

    /// First reason the poll cannot be created yet; nil = ready.
    func issue(config: PollConfig, now: Date = .now) -> Issue? {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000.0)
        return pollCreateDraftIssue(draft: coreRecord, config: config.coreRecord, nowMs: nowMs)
            .map(Issue.init(coreRecord:))
    }

    /// "Add option" is meaningless while results are hidden (official create popup disables and sends false).
    var effectiveAllowAdd: Bool { allowAdd && !hidePreview }

    /// Normalized create-poll spec dictionary.
    func spec(config: PollConfig, canPin: Bool) -> [String: Any] {
        let raw = pollCreateDraftSpecJson(draft: coreRecord, config: config.coreRecord, canPin: canPin)
        return JSONLossless.parseObject(string: raw) ?? [:]
    }
}

enum PollAction {
    case vote, lock, share, create, pin, unpin

    var coreRecord: PollActionRecord {
        switch self {
        case .vote: return .vote
        case .lock: return .lock
        case .share: return .share
        case .create: return .create
        case .pin: return .pin
        case .unpin: return .unpin
        }
    }
}

struct PollActionResult: Equatable, Sendable {
    var ok: Bool
    var error: String?
    /// The poll was created, but "ghim" was left out (the board is full or could not be checked): pin it from its menu.
    var pinSkipped = false

    init(ok: Bool, error: String? = nil, pinSkipped: Bool = false) {
        self.ok = ok
        self.error = error
        self.pinSkipped = pinSkipped
    }

    init(coreRecord r: PollActionResultRecord) {
        self.ok = r.ok
        self.error = r.error
        self.pinSkipped = r.pinSkipped
    }

    var coreRecord: PollActionResultRecord {
        PollActionResultRecord(ok: ok, error: error, pinSkipped: pinSkipped)
    }

    /// Official toast / modal texts (lang_vi.json).
    func message(for action: PollAction) -> String {
        pollActionResultMessage(result: coreRecord, action: action.coreRecord)
    }
}

/// Whether the group's board lets me pin, and whether this poll is pinned.
/// Not `ready` = unknown / not offered (not a group, topic board unavailable): the pin item is hidden and nothing is guessed.
struct PollPinState: Equatable, Sendable {
    var ready = false
    /// Official `isEnablePin`: owner / deputy, or members when the group allows setting topics.
    var canPin = false
    var pinned = false
    /// Pinned topics the board holds at most (`pinLimit`).
    var limit = 0

    init(coreRecord r: PollPinStateRecord) {
        ready = r.ready
        canPin = r.canPin
        pinned = r.pinned
        limit = Int(r.limit)
    }

    init() {}

    init(json: Any?) {
        let jsonStr = (json as? [String: Any]).flatMap(pollJsonObjectString)
        self.init(coreRecord: pollPinStateFromJson(json: jsonStr))
    }

    var coreRecord: PollPinStateRecord {
        PollPinStateRecord(ready: ready, canPin: canPin, pinned: pinned, limit: Int64(limit))
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

    init(coreRecord r: PollPinConfirmRecord) {
        self.ref = r.refId
        self.limit = Int(r.limit)
        self.kind = r.kind
        self.title = r.title
    }

    init?(json: Any?) {
        let jsonStr = (json as? [String: Any]).flatMap(pollJsonObjectString)
        guard let rec = pollPinConfirmFromJson(json: jsonStr) else { return nil }
        self.init(coreRecord: rec)
    }

    var coreRecord: PollPinConfirmRecord {
        PollPinConfirmRecord(refId: ref, limit: Int64(limit), kind: kind, title: title)
    }

    /// STR_ONLY_PIN_MAX_CONTENT + STR_DIRECTION_PIN_LIMIT, then the pin that goes.
    var message: String {
        pollPinConfirmMessage(confirm: coreRecord)
    }
}

enum PollPinOutcome: Equatable, Sendable {
    case done
    case needsConfirmation(PollPinConfirm)
    case failed(PollActionResult)

    init(coreRecord r: PollPinOutcomeRecord) {
        switch r {
        case .done:
            self = .done
        case .needsConfirmation(let confirm):
            self = .needsConfirmation(PollPinConfirm(coreRecord: confirm))
        case .failed(let result):
            self = .failed(PollActionResult(coreRecord: result))
        }
    }
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
    /// Poll event messages already answered with a refresh (each message once, FIFO-capped at 2,000 in `olaz-core`).
    static var seenMessages: Set<String> = []
    static var seenMessagesOrder: [String] = []
    /// Polls on screen (id → conversation).
    static var watched: [String: String] = [:]
    static var lastAttempt: [String: Date] = [:]
    static var didEvictWatched = false
    static var pendingRefresh: [String: UInt64] = [:]
    static var nextDebounceSeq: UInt64 = 0
}

extension ZaloEngine {
    internal func drainCorePollWork(_ core: CoreEngine) async {
        switch phase {
        case .login, .signingIn:
            if let v = try? await core.settle() {
                await waitForMirrorVersion(v)
            }
        default:
            if let v = try? await core.waitIdle() {
                await waitForMirrorVersion(v)
            }
        }
    }

    internal func armLocalPollDebounceTask(pollId: String, seq: UInt64, delayMs: UInt64) {
        PollClock.refreshTasks[pollId]?.cancel()
        let clampedMs = Int(min(delayMs, UInt64(Int.max)))
        PollClock.refreshTasks[pollId] = Task { @MainActor [weak self] in
            let completed: Bool
            if let sleepSeam = self?.pollDebounceSleep {
                completed = await sleepSeam(clampedMs)
            } else {
                try? await Task.sleep(for: .milliseconds(clampedMs))
                completed = !Task.isCancelled
            }
            guard completed, !Task.isCancelled, PollClock.pendingRefresh[pollId] == seq else {
                return
            }
            PollClock.pendingRefresh.removeValue(forKey: pollId)
            PollClock.refreshTasks.removeValue(forKey: pollId)
            guard let self else { return }
            let ts = self.nowMs()
            if let core = self.coreLifecycle.core {
                core.firePollDebounce(pollId: pollId, seq: seq, nowMs: ts)
                self.trackPollTask { [weak self] in
                    await self?.drainCorePollWork(core)
                }
            } else {
                self.trackPollTask { [weak self] in
                    guard let self, let core = await self.ensureCoreEngine() else { return }
                    core.firePollDebounce(pollId: pollId, seq: seq, nowMs: ts)
                    await self.drainCorePollWork(core)
                }
            }
        }
    }

    func watchPoll(_ id: String, in conversationId: String) {
        guard !id.isEmpty else { return }
        let ts = nowMs()
        if let core = coreLifecycle.core {
            core.watchPoll(id: id, convId: conversationId, nowMs: ts)
            trackPollTask { [weak self] in
                await self?.drainCorePollWork(core)
            }
        } else {
            trackPollTask { [weak self] in
                guard let self, let core = await self.ensureCoreEngine() else { return }
                core.watchPoll(id: id, convId: conversationId, nowMs: ts)
                await self.drainCorePollWork(core)
            }
        }
    }

    func retryPoll(_ id: String, in conversationId: String) {
        let ts = nowMs()
        if let core = coreLifecycle.core {
            core.retryPoll(id: id, convId: conversationId, nowMs: ts)
            trackPollTask { [weak self] in
                await self?.drainCorePollWork(core)
            }
        } else {
            trackPollTask { [weak self] in
                guard let self, let core = await self.ensureCoreEngine() else { return }
                core.retryPoll(id: id, convId: conversationId, nowMs: ts)
                await self.drainCorePollWork(core)
            }
        }
    }

    func rewatchPolls() {
        let ts = nowMs()
        if let core = coreLifecycle.core {
            core.rewatchPolls(nowMs: ts)
            trackPollTask { [weak self] in
                await self?.drainCorePollWork(core)
            }
        } else {
            trackPollTask { [weak self] in
                guard let self, let core = await self.ensureCoreEngine() else { return }
                core.rewatchPolls(nowMs: ts)
                await self.drainCorePollWork(core)
            }
        }
    }

    func refreshPoll(_ id: String) {
        guard !id.isEmpty else { return }
        let ts = nowMs()
        if let core = coreLifecycle.core {
            core.refreshPoll(id: id, nowMs: ts)
            trackPollTask { [weak self] in
                await self?.drainCorePollWork(core)
            }
        } else {
            trackPollTask { [weak self] in
                guard let self, let core = await self.ensureCoreEngine() else { return }
                core.refreshPoll(id: id, nowMs: ts)
                await self.drainCorePollWork(core)
            }
        }
    }

    internal func resolvePollGroupId(id: String, payload: [String: Any], explicit: String?) -> String {
        var hits: [PollWatchedEntryRecord] = []
        for convId in messages.keys.sorted() where ZaloWireParser.isGroupId(convId) {
            if let list = messages[convId], list.contains(where: {
                if case .poll(let info) = $0.kind { return info.pollId == id }
                return false
            }) {
                hits.append(PollWatchedEntryRecord(pollId: id, convId: convId))
            }
        }
        return resolvePollGroupIdFfi(
            pollId: id,
            payloadJson: Self.jsonString(for: payload),
            explicitGroupId: explicit,
            watchedGroupId: PollClock.watched[id],
            previousDetailGroupId: polls.details[id]?.groupId,
            groupWindowPollHits: hits
        )
    }

    internal func isGroupAdminOrCreator(_ uid: String, inGroup groupId: String) -> Bool {
        isGroupAdminOrCreatorFfi(uid: uid, groupId: groupId, contacts: currentContactsStateRecord())
    }

    internal func normalizePollDetail(_ d: [String: Any], id: String, groupId explicitGroupId: String? = nil) -> [String: Any] {
        let resolvedGroupId = resolvePollGroupId(id: id, payload: d, explicit: explicitGroupId)
        guard let rec = normalizePollDetailFfi(
            payloadJson: Self.jsonString(for: d),
            pollId: id,
            resolvedGroupId: resolvedGroupId,
            myUid: profile?.userId ?? "",
            myAvatar: profile?.avatar?.absoluteString,
            contacts: currentContactsStateRecord(),
            identities: currentIdentityTableRecord()
        ) else {
            return [:]
        }
        let raw = pollDetailToJson(detail: rec)
        return JSONLossless.parseObject(string: raw) ?? [:]
    }

    func pollVoters(_ id: String) async -> PollVoters? {
        guard let core = await ensureCoreEngine() else { return nil }
        pushCoreIdentitiesIfRunning()
        pushCoreContactsIfRunning()
        guard let out = try? await core.pollVoters(id: id) else { return nil }
        await waitForMirrorVersion(out.version)
        return out.voters.map(PollVoters.init(coreRecord:))
    }

    @discardableResult
    func refreshPollPin(_ id: String, in conversationId: String) async -> PollPinState {
        guard let core = await ensureCoreEngine() else { return PollPinState() }
        guard let out = try? await core.refreshPollPin(id: id, convId: conversationId) else {
            return polls.pins[id] ?? PollPinState()
        }
        await waitForMirrorVersion(out.version)
        return PollPinState(coreRecord: out.state)
    }

    internal static func mapPollPinError(_ error: Error, partial: Bool = false) -> PollActionResult {
        if let err = error as? ZaloSessionError {
            return PollActionResult(
                coreRecord: mapPollPinSessionErrorFfi(
                    code: Int64(err.code),
                    message: err.message,
                    partial: partial
                )
            )
        }
        let isNet = (error is ZaloTransportError) || (error is URLError)
        return PollActionResult(
            coreRecord: mapPollPinTransportErrorFfi(isNetworkOrTransport: isNet, partial: partial)
        )
    }

    func pinPoll(_ id: String, in conversationId: String, confirming ref: String? = nil) async -> PollPinOutcome {
        guard let core = await ensureCoreEngine() else {
            return .failed(PollActionResult(ok: false, error: "network"))
        }
        guard let out = try? await core.pinPoll(id: id, convId: conversationId, confirming: ref) else {
            return .failed(PollActionResult(ok: false, error: nil))
        }
        await waitForMirrorVersion(out.version)
        return PollPinOutcome(coreRecord: out.outcome)
    }

    func unpinPoll(_ id: String, in conversationId: String) async -> PollActionResult {
        guard let core = await ensureCoreEngine() else {
            return PollActionResult(ok: false, error: "network")
        }
        guard let out = try? await core.unpinPoll(id: id, convId: conversationId) else {
            return PollActionResult(ok: false, error: "network")
        }
        await waitForMirrorVersion(out.version)
        return PollActionResult(coreRecord: out.result)
    }

    func pollCapabilities(in conversationId: String) async -> PollCapabilities {
        if let core = coreLifecycle.core,
           let out = try? await core.pollCapabilities(convId: conversationId) {
            await waitForMirrorVersion(out.version)
            return PollCapabilities(coreRecord: out.capabilities)
        }
        return PollCapabilities(coreRecord: pollCapabilitiesForConversation(convId: conversationId))
    }

    func votePoll(_ id: String, in conversationId: String, draft: PollVoteDraft, detail: PollDetail) async -> PollActionResult {
        guard let core = await ensureCoreEngine() else {
            return PollActionResult(ok: false, error: "network")
        }
        let ts = nowMs()
        guard let out = try? await core.votePoll(
            id: id,
            convId: conversationId,
            draft: draft.coreRecord,
            detail: detail.coreRecord,
            nowMs: ts
        ) else {
            return PollActionResult(ok: false, error: "network")
        }
        await waitForMirrorVersion(out.version)
        trackPollTask { [weak self] in
            await self?.drainCorePollWork(core)
        }
        return PollActionResult(coreRecord: out.result)
    }

    func lockPoll(_ id: String, in conversationId: String) async -> PollActionResult {
        guard let core = await ensureCoreEngine() else {
            return PollActionResult(ok: false, error: "network")
        }
        let ts = nowMs()
        guard let out = try? await core.lockPoll(id: id, convId: conversationId, nowMs: ts) else {
            return PollActionResult(ok: false, error: "network")
        }
        await waitForMirrorVersion(out.version)
        trackPollTask { [weak self] in
            await self?.drainCorePollWork(core)
        }
        return PollActionResult(coreRecord: out.result)
    }

    func sharePoll(_ id: String, in conversationId: String) async -> PollActionResult {
        guard let core = await ensureCoreEngine() else {
            return PollActionResult(ok: false, error: "network")
        }
        guard let out = try? await core.sharePoll(id: id, convId: conversationId) else {
            return PollActionResult(ok: false, error: "network")
        }
        await waitForMirrorVersion(out.version)
        return PollActionResult(coreRecord: out.result)
    }

    func createPoll(in conversationId: String, draft: PollCreateDraft, config: PollConfig, canPin: Bool) async -> PollActionResult {
        guard let core = await ensureCoreEngine() else {
            return PollActionResult(ok: false, error: "network")
        }
        guard let out = try? await core.createPoll(
            convId: conversationId,
            draft: draft.coreRecord,
            config: config.coreRecord,
            canPin: canPin
        ) else {
            return PollActionResult(ok: false, error: "network")
        }
        await waitForMirrorVersion(out.version)
        return PollActionResult(coreRecord: out.result)
    }

    func notePollMessages(_ incoming: [ChatMessage]) {
        let notices: [PollMessageNoticeRecord] = incoming.compactMap { msg in
            guard case .poll(let info) = msg.kind, !info.pollId.isEmpty else { return nil }
            return PollMessageNoticeRecord(
                msgId: msg.id,
                pollId: info.pollId,
                convId: msg.conversationId,
                dateMs: Int64((msg.date.timeIntervalSince1970 * 1000.0).rounded())
            )
        }
        guard !notices.isEmpty else { return }
        let ts = nowMs()
        let plan = applyNotePollMessagesFfi(
            mirror: currentPollsMirrorRecord(),
            notices: notices,
            nowMs: ts
        )
        applyPollsMirror(plan.mirror)
        for arm in plan.armed {
            armLocalPollDebounceTask(pollId: arm.pollId, seq: arm.seq, delayMs: arm.delayMs)
        }
        coreLifecycle.core?.notePollMessages(notices: notices, nowMs: ts, hostAlreadyArmed: true)
    }

    func handlePoll(state: [String: Any]) {
        let stateJson = Self.jsonString(for: state)
        if let updated = applyPollStateEventFfi(mirror: currentPollsMirrorRecord(), stateJson: stateJson) {
            applyPollsMirror(updated)
        }
        coreLifecycle.core?.handlePollState(stateJson: stateJson)
    }

    func resetPolls() {
        localPollSyncEpoch &+= 1
        polls = PollStore()
        PollClock.refreshTasks.values.forEach { $0.cancel() }
        PollClock.refreshTasks = [:]
        PollClock.seenMessages = []
        PollClock.seenMessagesOrder = []
        PollClock.watched = [:]
        PollClock.lastAttempt = [:]
        PollClock.didEvictWatched = false
        PollClock.pendingRefresh = [:]
        PollClock.nextDebounceSeq = 0
        coreLifecycle.core?.resetPolls(syncEpoch: localPollSyncEpoch)
    }
}
