import AppKit
import Foundation
import Observation
import OlazCore
import os

private let engineLog = Logger(subsystem: "app.olaz", category: "engine")

/// Pure Swift Native Protocol Engine for Olaz (`URLSession` + `URLSessionWebSocketTask` `zpw_ws` +
/// `SQLite3` + `CryptoKit`/`CommonCrypto`). Zero `WKWebView`, zero Node, zero idle helpers.
@MainActor
@Observable
final class ZaloEngine {
    enum Phase: Equatable {
        case starting
        case preparing(RuntimeSetup)
        case login(LoginState)
        case signingIn
        case ready
    }

    struct RuntimeSetup: Equatable {
        var step: ZaloRuntimeInstaller.Step = .looking
        var failure: String?
    }

    struct LoginState: Equatable {
        enum Step: Equatable {
            case generating
            case waitingScan
            case waitingConfirm(name: String, avatar: URL?)
            case expired
            case failed(String)
        }
        var step: Step = .generating
        var qrPNG: Data?
    }

    struct Profile: Equatable {
        var userId: String
        var displayName: String
        var avatar: URL?
        var phone: String?
    }

    struct ConversationSummary: Identifiable, Equatable {
        struct Preview: Equatable {
            var text: String
            var date: Date?
            var fromMe: Bool
        }
        var id: String
        var isGroup: Bool
        var name: String
        var avatar: URL?
        var pinned: Bool
        var members: Int
        var unread: Int
        var preview: Preview?

        var displayName: String { name.isEmpty ? (isGroup ? "Nhóm" : "Người dùng Zalo") : name }
    }

    private(set) var phase: Phase = .starting
    var conversations: [ConversationSummary] = [] {
        didSet {
            if !isApplyingCoreMirror {
                coreLifecycle.core?.syncConversationsSnapshot(list: conversations.map(\.coreRecord))
            }
        }
    }
    private(set) var profile: Profile?
    private(set) var signOutNotice: String?
    private(set) var clientVersion: String? = "694 (Native)"
    private(set) var recentLog: [String] = []

    var openConversationId: String? {
        didSet {
            if !isApplyingCoreMirror {
                coreLifecycle.core?.setOpenConversation(id: openConversationId)
            }
        }
    }
    var failedDrafts = FailedDraftStore()
    var messages: [String: [ChatMessage]] = [:] {
        didSet { messageSignal.changed(from: oldValue, to: messages) }
    }
    /// Accounts I blocked (messages and calls), from `/api/friend/blocklistv2`; nil until loaded.
    var blockedUsers: [BlockedUser]?
    /// "Tin nhắn tự xóa" per conversation (ms); nil until loaded.
    var autoDelete: [String: Int64]?
    /// Account privacy settings (Cài đặt ▸ Quyền riêng tư); nil until loaded.
    var privacy: [PrivacyKey: Bool]?
    /// "Tin nhắn nhanh"; nil until loaded.
    var quickMessages: [QuickMessage]?
    var hasMoreHistory: [String: Bool] = [:] {
        didSet { hasMoreSignal.changed(from: oldValue, to: hasMoreHistory) }
    }
    var historyTicks: [String: Int] = [:]
    var typing: [String: TypingStatus] = [:] {
        didSet { typingSignal.changed(from: oldValue, to: typing) }
    }
    // Per-conversation observation of the three dictionaries above (see `KeyedSignal`). Views read them through
    // `messages(in:)`, `hasMoreHistory(in:)` and `typingName(in:)` so a change in one chat does not re-render another.
    @ObservationIgnored let messageSignal = KeyedSignal()
    @ObservationIgnored let hasMoreSignal = KeyedSignal()
    @ObservationIgnored let typingSignal = KeyedSignal()
    var transfer: MessageTransferState?
    var canStartTransfer = false
    var transferStartBlockedReason: String?

    var selfConversationId: String?
    var navigationRequest: String?
    var conversationExtras = ConversationExtras()
    var conversationActions = ConversationActionsState()
    let conversationUI = ConversationActionUI()
    var conversationPrompt: ConversationPrompt? {
        didSet {
            if !isApplyingCoreMirror {
                if let core = coreLifecycle.core {
                    core.setConversationPrompt(prompt: conversationPrompt?.coreRecord)
                } else if let offline = offlineConvCore {
                    _ = offline.setConversationPrompt(prompt: conversationPrompt?.coreRecord)
                }
            }
        }
    }
    var contacts = ContactsState() { didSet { pushCoreIdentitiesIfRunning() } }
    var notificationSettings = NotificationSettingsState()
    var cloud = CloudState()
    var call = CallState()
    var polls = PollStore()
    var composerConfirm: ComposerConfirm?
    @ObservationIgnored internal var queuedComposerConfirms: [ComposerConfirm] = []

    var forwardRequest: ForwardRequest?
    /// "Chọn nhiều tin nhắn" in progress (one conversation at a time).
    var messageSelection: MessageSelection?
    var messageConfirm: MessageActionConfirm?
    var deleteUndo: DeleteUndo?
    var pins: [String: PinnedList] = [:]
    @ObservationIgnored internal var messageActionsBusy: Set<String> = []

    @ObservationIgnored internal let mediaResolver = MediaResolver()
    @ObservationIgnored internal let sessionClient: ZaloSessionClient
    @ObservationIgnored internal let webSocket = ZaloWebSocket()
    @ObservationIgnored internal let dataDirectory: URL
    @ObservationIgnored internal var sqliteStore: ZaloSQLiteStore? {
        didSet {
            if let core = coreLifecycle.core {
                if let store = sqliteStore {
                    core.attachStore(store: store.coreStoreHandle)
                } else {
                    core.detachStore()
                }
            }
        }
    }
    @ObservationIgnored internal var callBridge: CallBridge?

    @ObservationIgnored private var started = false
    internal var isEngineStarted: Bool { started }
    @ObservationIgnored internal let coreLifecycle = CoreEngineLifecycle()
    @ObservationIgnored internal var coreInitTask: Task<CoreEngine?, Never>?
    @ObservationIgnored internal var pendingCoreCommands: [PendingCoreCommand] = []
    @ObservationIgnored internal var appliedMirrorVersion: UInt64 = 0
    @ObservationIgnored internal var isApplyingCoreMirror = false
    @ObservationIgnored internal var offlineConvCore: CoreOfflineConversations?
    @ObservationIgnored internal var mirrorVersionWaiters: [(target: UInt64, continuation: CheckedContinuation<Void, Never>)] = []
    @ObservationIgnored internal var cachedQRPayload: String?
    @ObservationIgnored internal var cachedQRPNG: Data?
    @ObservationIgnored internal var hostTrace: ((String, [String: Any]) -> Bool)?
    @ObservationIgnored internal var traceU4HostEnabled: Bool = false
    @ObservationIgnored internal var stateTrace: (() -> Void)?
    @ObservationIgnored private let transportSettleTraceActive = OSAllocatedUnfairLock<Bool>(initialState: false)
    nonisolated internal var hasTransportSettleTrace: Bool {
        transportSettleTraceActive.withLock { $0 }
    }
    @ObservationIgnored internal var transportSettleTrace: (() -> Void)? {
        didSet {
            let active = transportSettleTrace != nil
            transportSettleTraceActive.withLock { $0 = active }
        }
    }
    @ObservationIgnored internal var nowMs: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    @ObservationIgnored internal var randomTag4: () -> String = { String(UUID().uuidString.prefix(4)) }
    @ObservationIgnored internal var recordedQRPayload: String?
    @ObservationIgnored internal var recordedSessionPrefs: [String: String] = [:]
    @ObservationIgnored internal var pendingCleanupTask: Task<Void, Never>?
    @ObservationIgnored internal var bootTask: Task<Void, Never>?
    @ObservationIgnored internal var qrTask: Task<Void, Never>?
    @ObservationIgnored internal var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored internal var transferTask: Task<Void, Never>?
    @ObservationIgnored internal var openConversationTask: Task<Void, Never>?
    @ObservationIgnored internal var loadOlderTask: Task<Void, Never>?
    @ObservationIgnored internal var persistConversationsTask: Task<Void, Never>?
    @ObservationIgnored internal var batchImportTask: Task<Void, Never>?
    @ObservationIgnored internal var activeSyncBatchTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored internal var lastSyncConvFlushAt: Date = .distantPast
    @ObservationIgnored internal var phoneSyncConvTimestamps: [String: UInt64] = [:]
    @ObservationIgnored internal var syncAttemptedProfileUids: Set<String> = []
    @ObservationIgnored internal var syncStage2Progress = SyncStage2ProgressState()
    @ObservationIgnored internal var syncInitialEmptyDB = false
    @ObservationIgnored internal let phoneSync = ZaloPhoneSyncCoordinator()
    @ObservationIgnored internal let e2eeManager = ZaloE2EEManager()
    @ObservationIgnored internal var isTransferHidden = false
    @ObservationIgnored internal var phoneSyncStatusSignal: ZaloMobileSyncEvent?
    @ObservationIgnored internal var pollState = ZaloPollState()
    @ObservationIgnored internal var typingResetTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored internal var pendingDeletedMessages: [String: [ChatMessage]] = [:]
    internal struct PendingLocalReaction {
        let id: UUID
        let convId: String
        let msgId: String
        let cliMsgId: String
        let rType: String
        var reactClientId: String
        let createdAt: Date
    }
    @ObservationIgnored internal var pendingLocalReactions: [PendingLocalReaction] = []
    @ObservationIgnored internal var seenReactionEventIds: Set<String> = []
    @ObservationIgnored internal var seenReactionEventOrder: [String] = []
    @ObservationIgnored internal var reactionBusyKeys: Set<String> = []
    @ObservationIgnored internal var groupMemberCache: [String: [MentionCandidate]] = [:]
    @ObservationIgnored internal var cachedSentRequestsRaw: [[String: Any]] = []
    @ObservationIgnored internal var cachedReceivedRequestsRaw: [[String: Any]] = []
    @ObservationIgnored internal var cachedGroupDetails: [String: [String: Any]] = [:]
    @ObservationIgnored internal var cachedFriendGlobalIds: [String: String] = [:] { didSet { friendUidByGlobalId = nil; pushCoreIdentitiesIfRunning() } }
    /// `cachedFriendGlobalIds` reversed (global id → uid), built on first use: looking a sender up scanned the whole map for every
    /// message (50 per chat opened, ~25 ms of main thread).
    @ObservationIgnored private var friendUidByGlobalId: [String: String]?
    @ObservationIgnored internal var cachedPinnedIds: Set<String> = []
    @ObservationIgnored internal var cachedArchivedIds: Set<String> = []
    @ObservationIgnored internal var cachedStarredIds: Set<String> = []
    @ObservationIgnored internal var cachedUnreadMarks: Set<String> = []
    @ObservationIgnored internal var cachedAliases: [String: String] = [:] { didSet { pushCoreIdentitiesIfRunning() } }
    @ObservationIgnored internal var cachedProfiles: [String: ZaloWebKitMigrator.CachedProfile] = [:] { didSet { pushCoreIdentitiesIfRunning() } }
    @ObservationIgnored internal var cachedGroups: [String: ZaloWebKitMigrator.CachedGroup] = [:] { didSet { pushCoreIdentitiesIfRunning() } }
    @ObservationIgnored internal var cachedActivityRanks: [String: Int64] = [:] { didSet { pushCoreIdentitiesIfRunning() } }
    /// Per-conversation result of the launch preload probe (see `ZaloEngine+HistoryFreshness.swift`).
    @ObservationIgnored internal var historyFreshness: [String: HistoryFreshness] = [:]
    @ObservationIgnored internal var historyFullRefreshDue = false
    @ObservationIgnored internal var cachedBoardRawTopics: [String: (version: Int64, topics: [String: [String: Any]])] = [:]

    @ObservationIgnored internal var reminderWatchCache: [String: (sig: String, snapshot: ReminderSnapshot)] = [:]
    @ObservationIgnored internal var reminderWatchWaiters: [String: [UUID: @Sendable () -> Void]] = [:]
    @ObservationIgnored private var webkitMigrateTask: Task<Void, Never>?

    /// Kept for menu toggle binding compatibility; native engine has no hidden WebKit window.
    var isDebugRendererVisible = false
    /// Remembers user-saved `~/Downloads` destinations keyed by message/file key so file cards reflect saved state across scroll.
    var downloadedFilePaths: [String: URL] = [:]

    /// Strictly side-effect-free initializer so unit tests and previews instantiate safely.
    init(
        dataDirectory: URL = ZaloPlatform.defaultUserData,
        useKeychain: Bool = true,
        domains: ZaloDomains = ZaloDomains(),
        userDefaultsSuiteName: String? = nil,
        cookieStorage: HTTPCookieStorage = .shared
    ) {
        self.dataDirectory = dataDirectory
        self.sessionClient = ZaloSessionClient(
            dataDirectory: dataDirectory,
            useKeychain: useKeychain,
            domains: domains,
            userDefaultsSuiteName: userDefaultsSuiteName,
            cookieStorage: cookieStorage
        )
        self.conversationUI.onRelock = { [weak self] in
            self?.coreLifecycle.core?.relockHidden()
        }
        self.conversationUI.onDropUnlock = { [weak self] in
            self?.coreLifecycle.core?.dropHiddenUnlock()
        }
        self.conversationUI.onShowToast = { [weak self] kind, text in
            guard let self, let core = self.coreLifecycle.core else { return false }
            let result: ConversationActionResult
            switch kind {
            case .success: result = ConversationActionResult(ok: true, text: text)
            case .neutral: result = ConversationActionResult(ok: true, text: text, neutral: true)
            case .failure: result = ConversationActionResult(ok: false, text: text)
            }
            core.reportConversationActionResult(result: result.coreRecord)
            return true
        }
    }

    deinit {
        coreLifecycle.shutdown()
    }

    /// Writes the session mirror fields exclusively from `olaz-core` change batches (ADR-016).
    internal func applySessionMirror(
        phase: Phase,
        profile: Profile?,
        signOutNotice: String?,
        selfConversationId: String?,
        clientVersion: String?,
        qrPayload: String? = nil
    ) {
        var traceChanged = false
        if self.recordedQRPayload != qrPayload {
            self.recordedQRPayload = qrPayload
            traceChanged = true
        }
        if self.phase != phase {
            self.phase = phase
            traceChanged = true
        }
        if self.profile != profile {
            self.profile = profile
            traceChanged = true
        }
        if self.signOutNotice != signOutNotice {
            self.signOutNotice = signOutNotice
            traceChanged = true
        }
        if self.selfConversationId != selfConversationId {
            self.selfConversationId = selfConversationId
            traceChanged = true
        }
        if self.clientVersion != clientVersion { self.clientVersion = clientVersion }
        if traceChanged {
            stateTrace?()
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        EngineLog.shared.onAppend = { [weak self] line in
            self?.recentLog.append(line)
            if let count = self?.recentLog.count, count > 200 {
                self?.recentLog.removeFirst(count - 200)
            }
        }
        EngineLog.shared.write("engine: start native runtime core=rust (zpw_ver=\(ZaloDomains.zpwVer))")
        NativeNotifier.shared.attach(engine: self)
        ZaloRuntime.prepareForLaunch()
        call.helperInstalled = CallBridge.isHelperInstalled()
        call.rendererReady = true
        call.supported = call.helperInstalled
        call.videoSupported = call.helperInstalled

        dispatchCoreCommand(.start)
    }

    func retryRuntimeSetup() {
        refreshQR()
    }

    func refreshQR() {
        dispatchCoreCommand(.refreshQr)
    }

    func logOut() {
        EngineLog.shared.write("engine: logOut")
        dispatchCoreCommand(.logOut)
    }

    internal func handleSessionExpiredNotice(_ reason: String) {
        dispatchCoreCommand(.sessionExpired(reason))
    }

    /// Tears down all Swift-owned domains and closes SQLite when requested by `CoreHost.resetDomains()`.
    /// Session mirror fields (`phase`, `profile`, `signOutNotice`, `selfConversationId`) are owned by Rust.
    internal func hostResetDomains() async {
        bootstrapTask?.cancel(); bootstrapTask = nil
        transferTask?.cancel(); transferTask = nil
        batchImportTask?.cancel(); batchImportTask = nil
        activeSyncBatchTasks.values.forEach { $0.cancel() }
        activeSyncBatchTasks = [:]
        webkitMigrateTask?.cancel(); webkitMigrateTask = nil
        typingResetTasks.values.forEach { $0.cancel() }
        typingResetTasks = [:]

        callBridge?.shutdown()
        callBridge = nil
        let oldStore = sqliteStore
        sqliteStore = nil
        resetSessionState()
        failedDrafts = FailedDraftStore()

        await phoneSync.resetAll()
        await e2eeManager.reset()
        await webSocket.stop()
        await oldStore?.close()
    }

    private func resetSessionState() {
        isApplyingCoreMirror = true
        defer { isApplyingCoreMirror = false }
        offlineConvCore = nil
        pollState = ZaloPollState()
        conversations = []
        openConversationId = nil
        messages = [:]
        hasMoreHistory = [:]
        historyTicks = [:]
        typing = [:]
        transfer = nil
        canStartTransfer = false
        transferStartBlockedReason = nil
        syncAttemptedProfileUids = []
        syncStage2Progress = SyncStage2ProgressState()
        syncInitialEmptyDB = false
        navigationRequest = nil
        conversationExtras = ConversationExtras()
        conversationActions = ConversationActionsState()
        conversationPrompt = nil
        conversationUI.reset()
        contacts = ContactsState()
        notificationSettings = NotificationSettingsState()
        call = CallState()
        call.helperInstalled = CallBridge.isHelperInstalled()
        call.rendererReady = true
        call.supported = call.helperInstalled
        call.videoSupported = call.helperInstalled
        resetComposer()
        resetMessageActions()
        resetPolls()
        resetStickers()
        resetCardState()
        resetCloud()
        pendingDeletedMessages = [:]
        pendingLocalReactions = []
        seenReactionEventIds = []
        seenReactionEventOrder = []
        reactionBusyKeys = []
        groupMemberCache = [:]
        cachedSentRequestsRaw = []
        cachedReceivedRequestsRaw = []
        cachedGroupDetails = [:]
        cachedFriendGlobalIds = [:]
        phoneSyncConvTimestamps = [:]
        historyFreshness = [:]
        historyFullRefreshDue = false
        isTransferHidden = false
        phoneSyncStatusSignal = nil
        cachedPinnedIds = []
        cachedArchivedIds = []
        cachedStarredIds = []
        cachedUnreadMarks = []
        cachedAliases = [:]
        cachedBoardRawTopics = [:]
        failedDrafts = FailedDraftStore()
    }

    internal func applyAccountProfile(_ account: ZaloLoginAccount) async {
        await applyCoreAccountProfile(account)
    }

    internal func prepareStoreAndLocalCache(for account: ZaloLoginAccount) async {
        canStartTransfer = true
        transferStartBlockedReason = nil
        if !traceHost("prepare_store", args: ["user_id": account.userId]) {
            return
        }
        let dbURL = dataDirectory
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(account.userId, isDirectory: true)
            .appendingPathComponent("history.sqlite3")
        do {
            let store = try ZaloSQLiteStore(path: dbURL.path)
            self.sqliteStore = store

            var preAliases: [String: String] = [:]
            if let aliasesData = try? await store.getPreferenceData(key: "aliases"),
               let dict = (try? JSONSerialization.jsonObject(with: aliasesData)) as? [String: String] {
                preAliases = dict
            }
            let prePinned = Set((try? await store.getPreferenceStrings(key: "pinnedIds")) ?? [])
            let selfId = account.send2MeId.isEmpty ? account.userId : account.send2MeId
            let migResult = await ZaloWebKitMigrator.migrateBootstrapIfNeeded(
                account: account,
                selfConvId: selfId,
                into: store,
                existingAliases: preAliases,
                existingPinnedIds: prePinned
            )

            await loadLocalAccountState(from: store, account: account)

            if let migResult, let cursor = migResult.remainingCursorRecordID {
                let profilesCopy = self.cachedProfiles
                let aliasesCopy = self.cachedAliases
                let dbPath = migResult.dbPath
                webkitMigrateTask?.cancel()
                webkitMigrateTask = Task.detached(priority: .utility) {
                    _ = await ZaloWebKitMigrator.migrateRemainingMessages(
                        dbPath: dbPath,
                        startBeforeRecordID: cursor,
                        account: account,
                        selfConvId: selfId,
                        aliases: aliasesCopy,
                        profiles: profilesCopy,
                        into: store
                    )
                }
            }
        } catch {
            EngineLog.shared.write("sqlite open error: \(error.localizedDescription)")
        }

        // Load notification authorization status right after sign-in.
        let status = await NativeNotifier.shared.authorizationStatus()
        applyInitialNotificationAuth(status)
    }

    private func applyInitialNotificationAuth(_ status: NativeNotifier.Authorization) {
        switch status {
        case .unavailable: notificationSettings.authorization = .unavailable
        case .notDetermined: notificationSettings.authorization = .notDetermined
        case .denied: notificationSettings.authorization = .denied
        case .authorized: notificationSettings.authorization = .authorized
        }
    }

    internal func loadLocalAccountState(from store: ZaloSQLiteStore, account: ZaloLoginAccount? = nil) async {
        let effectiveMyUid = account?.userId ?? profile?.userId ?? ""
        // Self-heal any legacy raw Signal ciphertexts / broken E2EE sticker URLs / corrupted legacy reactions in SQLite before hydrating UI.
        if let repairedCount = try? await store.repairUndecryptedE2EEMessages(), repairedCount > 0 {
            EngineLog.shared.write("e2ee: repaired \(repairedCount) legacy ciphertext rows")
        }
        if let repairedReactCount = try? await store.repairLegacyReactions(myUid: effectiveMyUid), repairedReactCount > 0 {
            EngineLog.shared.write("reactions: repaired \(repairedReactCount) legacy rows")
        }
        if let savedSeen = try? await store.getPreferenceStrings(key: "seenReactionEventIds"), !savedSeen.isEmpty {
            let capped = Array(savedSeen.suffix(1000))
            seenReactionEventOrder = capped
            seenReactionEventIds = Set(capped)
        }
        if let pollData = try? await store.getPreferenceData(key: "pollState"),
           let savedPoll = try? JSONDecoder().decode(ZaloPollState.self, from: pollData) {
            pollState = savedPoll
        }
        if let wsData = try? await store.getPreferenceData(key: "wsQueueCursors"),
           let savedCursors = try? JSONDecoder().decode([String: ZaloWSQueueCursorSnapshot].self, from: wsData) {
            await webSocket.seedQueueCursors(savedCursors)
        }
        await e2eeManager.loadPersistedThreads(store: store)
        let client = sessionClient
        // The owner of an E2EE quote is nearly always one of the two people in the chat: their global ids come from
        // `/api/gid/encrypt` (cached), the same call that builds our own quotes; anyone else goes through `/api/gid/decrypt`.
        await e2eeManager.setGlobalIdResolver { gid, candidates in
            let known = await client.encryptGlobalIds(candidates)
            for (index, uid) in candidates.map(ZaloWireParser.stripUserPrefix).enumerated() where known[uid] == gid {
                return (uid, index == 0 ? "own" : "sender")
            }
            if let uid = await client.decryptGlobalIds([gid])[gid] { return (uid, "decrypt") }
            return nil
        }
        if !effectiveMyUid.isEmpty {
            let myUid = effectiveMyUid
            let mgr = e2eeManager
            Task.detached(priority: .utility) {
                await mgr.prepare(uid: myUid, store: store)
            }
        }

        // Load identity & non-U3 preference caches; U3 conversations/actions/labels/hidden state are hydrated by `olaz-core`.
        cachedStarredIds = Set((try? await store.getPreferenceStrings(key: "starredIds")) ?? [])

        if let aliasesData = try? await store.getPreferenceData(key: "aliases"),
           let dict = (try? JSONSerialization.jsonObject(with: aliasesData)) as? [String: String] {
            cachedAliases = dict
        }
        if let profData = try? await store.getPreferenceData(key: "cachedProfiles"),
           let decoded = try? JSONDecoder().decode([String: ZaloWebKitMigrator.CachedProfile].self, from: profData) {
            cachedProfiles = decoded
        }
        if let grpData = try? await store.getPreferenceData(key: "cachedGroups"),
           let decoded = try? JSONDecoder().decode([String: ZaloWebKitMigrator.CachedGroup].self, from: grpData) {
            cachedGroups = decoded
        }
        if let ranksData = try? await store.getPreferenceData(key: "activityRanks"),
           let rawRanks = (try? JSONSerialization.jsonObject(with: ranksData)) as? [String: Any] {
            var parsed: [String: Int64] = [:]
            for (k, v) in rawRanks {
                if let val = JSONLossless.int64(v), val > 0 { parsed[k] = val }
            }
            cachedActivityRanks = parsed
        }
        if let gidData = try? await store.getPreferenceData(key: "gidToUidMap"),
           let gidToUid = (try? JSONSerialization.jsonObject(with: gidData)) as? [String: String] {
            await sessionClient.seedGlobalIdMappings(gidToUid)
            for (gid, uid) in gidToUid where !gid.isEmpty && !uid.isEmpty {
                cachedFriendGlobalIds[uid] = gid
            }
        }

        pushCoreIdentitiesIfRunning()
        await loadNotificationPreferences(from: store)
    }

    // MARK: - Online Bootstrap & WebSocket Loop

    func startBootstrapRefresh() {
        if !traceHost("start_bootstrap") {
            return
        }
        bootstrapTask?.cancel()
        bootstrapTask = Task { [weak self] in
            await self?.performBootstrapSync()
        }
    }

    func performBootstrapSync() async {
        // 1. Aliases, Pins, Archived, Mutes, Contacts (check auth error immediately on first call)
        do {
            let aliases = try await sessionClient.fetchAliases()
            if !aliases.isEmpty {
                cachedAliases.merge(aliases) { _, new in new }
                if let data = try? JSONSerialization.data(withJSONObject: cachedAliases) {
                    try? await sqliteStore?.setPreferenceData(key: "aliases", data: data)
                }
            }
        } catch let err as ZaloSessionError where err.isAuthError {
            handleSessionExpiredNotice("Phiên đăng nhập không hợp lệ hoặc đã hết hạn. Vui lòng quét mã QR để đăng nhập lại.")
            return
        } catch {}

        // 2. New messages first: drain the HTTP long-polling queue (queued recent 1-1 & group messages) alongside the
        // metadata below, so what arrived while Olaz was closed shows up without waiting on contacts/labels. It runs
        // concurrently because an empty queue holds the long-poll request open for ~12 s. Nothing below waits for it:
        // the drain only adds rows, so a freshness probe that runs before it at worst sees a thread as stale (and fetches
        // it as before), and whatever is still queued is stored by the drain itself.
        let fullRefresh = await beginHistoryFreshnessPass()
        async let drained = drainChatPolling(maxBatches: 4, notifyIncoming: false)

        // Pins, archived and mutes are independent reads: fetch them together.
        async let pinsFetch = try? sessionClient.fetchPinnedConversations()
        async let archivedFetch = try? sessionClient.fetchArchivedChats()
        async let mutesFetch = try? sessionClient.fetchMuteList()
        let (pinsResult, archivedResult, mutesResult) = await (pinsFetch, archivedFetch, mutesFetch)
        if pinsResult != nil || archivedResult != nil {
            if let pins = pinsResult {
                cachedPinnedIds = Set(pins)
            }
            if let archived = archivedResult {
                cachedArchivedIds = Set(archived)
            }
            if let core = coreLifecycle.core,
               let v = try? await core.applyBootstrapPinArchive(pinnedIds: pinsResult, archivedIds: archivedResult) {
                await waitForMirrorVersion(v)
            }
        }
        if let mutesBox = mutesResult {
            var parsedMutes: [(convId: String, start: Double, duration: Double)] = []
            for entry in mutesBox.array {
                let idRaw = JSONLossless.string(entry["id"])
                guard !idRaw.isEmpty else { continue }
                let typeVal = JSONLossless.int64(entry["type"]) ?? 1
                let normId = typeVal == 2 ? ZaloWireParser.groupConvId(idRaw) : ZaloWireParser.stripUserPrefix(idRaw)
                let dur = (JSONLossless.int64(entry["duration"]).map(Double.init)) ?? -1
                let start = (JSONLossless.int64(entry["startTime"]).map(Double.init)) ?? (Double(nowMs()) / 1000.0)
                parsedMutes.append((convId: normId, start: start, duration: dur))
            }
            let serializedMutes: [[String: Any]] = parsedMutes.map {
                [
                    "conv_id": $0.convId,
                    "start": Int64($0.start),
                    "duration": Int64($0.duration),
                ]
            }
            if traceU4Host("apply_mutes", args: ["mutes": serializedMutes]) {
                var map = notificationSettings.mutes
                for m in parsedMutes {
                    map[m.convId] = MuteInfo(startTime: m.start, duration: m.duration)
                }
                notificationSettings.mutes = map
                await saveNotificationPreferences()
            }
        }

        await syncConversationLabelsFromServer()
        await syncHiddenConversations()
        await performContactsSync()
        ensureKnownContactsInConversations()
        rebuildConversationFlags()
        rebuildConversationExtras()

        // 3. Preload active threads + last messages (`threadIdLocalMsgId: "{}"` + 25-thread batches)
        var groupActivityRank: [String: Int64] = [:]
        let knownGroupIds = Set(contacts.groups.map(\.id))
        let myUid = profile?.userId ?? ""
        if let preloadBox = try? await sessionClient.fetchPreloadConversations(threadIds: []) {
            if let pd = preloadBox.dict["data"] as? [String: Any],
               let clearUnreads = pd["clearUnreads"] as? [[String: Any]] {
                for row in clearUnreads {
                    let rawId = JSONLossless.string(row["idTo"] ?? row["threadId"] ?? row["uid"])
                    let lastMid = JSONLossless.int64(row["lastMsgId"]) ?? 0
                    guard !rawId.isEmpty, rawId != "0", lastMid > 0 else { continue }
                    let isGrpFlag = (JSONLossless.int64(row["isGroup"]) == 1) || (row["isGroup"] as? Bool == true)
                    let gCandidate = ZaloWireParser.groupConvId(rawId)
                    if isGrpFlag || knownGroupIds.contains(gCandidate) {
                        guard !gCandidate.isEmpty, gCandidate != "g0", gCandidate != "g\(selfConversationId ?? "")" else { continue }
                        cachedActivityRanks[gCandidate] = max(cachedActivityRanks[gCandidate] ?? 0, lastMid)
                        groupActivityRank[gCandidate] = max(groupActivityRank[gCandidate] ?? 0, lastMid)
                    } else {
                        let peerId = ZaloWireParser.stripUserPrefix(rawId)
                        guard !peerId.isEmpty, peerId != "0", peerId != myUid else { continue }
                        cachedActivityRanks[peerId] = max(cachedActivityRanks[peerId] ?? 0, lastMid)
                    }
                }
                if !cachedActivityRanks.isEmpty,
                   let data = try? JSONSerialization.data(withJSONObject: cachedActivityRanks) {
                    try? await sqliteStore?.setPreferenceData(key: "activityRanks", data: data)
                }
            }
            _ = await applyBatchResponse(
                preloadBox.dict, incrementUnread: false, persistConversations: false, probeFreshness: !fullRefresh)
        }
        ensureKnownContactsInConversations()
        let orderedGroups = contacts.groups.map(\.id).sorted { a, b in
            let pinA = cachedPinnedIds.contains(a)
            let pinB = cachedPinnedIds.contains(b)
            if pinA != pinB { return pinA && !pinB }
            let rankA = groupActivityRank[a] ?? 0
            let rankB = groupActivityRank[b] ?? 0
            if rankA != rankB { return rankA > rankB }
            return a < b
        }
        let orderedPeers = cachedActivityRanks
            .filter { !ZaloWireParser.isGroupId($0.key) }
            .sorted { $0.value > $1.value }
            .map(\.key)
        let targetIds = (orderedPeers.prefix(50) + orderedGroups.prefix(50))
        var idx = targetIds.startIndex
        while idx < targetIds.endIndex {
            let end = targetIds.index(idx, offsetBy: 25, limitedBy: targetIds.endIndex) ?? targetIds.endIndex
            let chunk = Array(targetIds[idx..<end])
            idx = end
            if let chunkBox = try? await sessionClient.fetchPreloadConversations(threadIds: chunk) {
                _ = await applyBatchResponse(
                    chunkBox.dict, incrementUnread: false, persistConversations: false, probeFreshness: !fullRefresh)
            }
        }

        // 4. Fetch recent cloud history for "Cloud của tôi" and active groups concurrently (`/api/cm/getrecentv2`)
        if let selfId = selfConversationId, !selfId.isEmpty, !isRecentHistoryUpToDate(selfId),
           let selfHist = try? await sessionClient.fetchHistory(convId: selfId, lastMsgId: nil, count: 50, isOld: false) {
            _ = await applyBatchResponse(
                selfHist.dict,
                fallbackConvId: selfId,
                isGroupHint: false,
                incrementUnread: false,
                persistConversations: false
            )
        }

        // Groups whose newest message the store already had are skipped (see `ZaloEngine+HistoryFreshness.swift`).
        let initialGroupIds = Array(orderedGroups.prefix(24)).filter { !isRecentHistoryUpToDate($0) }
        EngineLog.shared.write("bootstrap: history full=\(fullRefresh) groups_fetch=\(initialGroupIds.count) up_to_date=\(historyFreshness.values.filter { $0 == .upToDate }.count)")
        for gOffset in stride(from: 0, to: initialGroupIds.count, by: 6) {
            let slice = Array(initialGroupIds[gOffset..<min(gOffset + 6, initialGroupIds.count)])
            let client = self.sessionClient
            let batchResults = await withTaskGroup(of: (String, ZaloJSONBox?).self) { group in
                for gid in slice {
                    group.addTask {
                        let box = try? await client.fetchHistory(convId: gid, lastMsgId: nil, count: 30, isOld: false)
                        return (gid, box)
                    }
                }
                var out: [(String, ZaloJSONBox?)] = []
                for await pair in group { out.append(pair) }
                return out
            }
            for (gid, histBox) in batchResults {
                if let histBox {
                    _ = await applyBatchResponse(
                        histBox.dict,
                        fallbackConvId: gid,
                        isGroupHint: true,
                        incrementUnread: false,
                        persistConversations: false
                    )
                }
            }
        }

        // 5. Resolve any placeholder names and finalize inbox state
        await resolveMissingConversationNames()
        ensureKnownContactsInConversations()
        rebuildConversationFlags()
        rebuildConversationExtras()
        await persistConversationsToSQLite()
        _ = await drained
        await finishFullHistoryRefresh()
        refreshCloud()
        EngineLog.shared.write("bootstrap: convs=\(conversations.count) friends=\(contacts.friends.count) groups=\(contacts.groups.count)")
    }

    @discardableResult
    internal func drainChatPolling(maxBatches: Int = 3, notifyIncoming: Bool = false) async -> Int {
        guard maxBatches > 0, let core = await ensureCoreEngine() else { return 0 }
        return Int((try? await core.drainChatPolling(
            maxBatches: UInt32(maxBatches),
            notifyIncoming: notifyIncoming
        )) ?? 0)
    }

    internal func resolveMissingConversationNames() async {
        guard let core = await ensureCoreEngine() else { return }
        if let v = try? await core.resolveMissingNames() {
            await waitForMirrorVersion(v)
        }
        if let store = sqliteStore,
           let profData = try? await store.getPreferenceData(key: "cachedProfiles"),
           let decoded = try? JSONDecoder().decode([String: ZaloWebKitMigrator.CachedProfile].self, from: profData) {
            isApplyingCoreMirror = true
            cachedProfiles = decoded
            isApplyingCoreMirror = false
        }
    }

    @discardableResult
    internal func applyBatchResponse(
        _ root: Any,
        defaultCmd: UInt16 = 0,
        fallbackConvId: String? = nil,
        isGroupHint: Bool? = nil,
        incrementUnread: Bool = false,
        notifyIncoming: Bool = false,
        persistConversations: Bool = true,
        probeFreshness: Bool = false
    ) async -> Int {
        let delta = await applyBatchResponseCollectingDelta(
            root,
            defaultCmd: defaultCmd,
            fallbackConvId: fallbackConvId,
            isGroupHint: isGroupHint,
            incrementUnread: incrementUnread,
            notifyIncoming: notifyIncoming,
            persistConversations: persistConversations,
            probeFreshness: probeFreshness
        )
        await commitBatchDeltaToCore(delta)
        return Int(delta.appliedCount)
    }

    internal func applyBatchResponseCollectingDelta(
        _ root: Any,
        defaultCmd: UInt16 = 0,
        fallbackConvId: String? = nil,
        isGroupHint: Bool? = nil,
        incrementUnread: Bool = false,
        notifyIncoming: Bool = false,
        persistConversations: Bool = true,
        probeFreshness: Bool = false
    ) async -> BatchApplyDeltaRecord {
        let myUid = profile?.userId ?? ""
        let effectiveRoot: Any
        if let rootDict = root as? [String: Any], !myUid.isEmpty {
            effectiveRoot = (await e2eeManager.decryptEnvelopeIfNeeded(
                ZaloJSONBox(rootDict),
                myUid: myUid,
                store: sqliteStore
            )).dict
        } else {
            effectiveRoot = root
        }
        let events = await ZaloWireParser.extractBatchEventsAsync(
            effectiveRoot,
            myUid: myUid,
            selfConvId: selfConversationId,
            defaultCmd: defaultCmd,
            fallbackConvId: fallbackConvId,
            isGroupHint: isGroupHint,
            nameLookup: { [weak self] uid in self?.lookupPersonInfo(uid) }
        )
        if probeFreshness { await probeHistoryFreshness(events) }
        return await applyParsedEventsCollectingDelta(
            events,
            incrementUnread: incrementUnread,
            notifyIncoming: notifyIncoming,
            persistConversations: persistConversations
        )
    }

    /// Applies parsed wire events: persists messages, applies reactions / recalls / deletes / typing, commits the
    /// resulting conversation delta to `olaz-core`, and raises notifications.
    @discardableResult
    internal func applyParsedEvents(
        _ events: [ParsedWireEvent],
        incrementUnread: Bool = false,
        notifyIncoming: Bool = false,
        persistConversations: Bool = true
    ) async -> Int {
        let delta = await applyParsedEventsCollectingDelta(
            events,
            incrementUnread: incrementUnread,
            notifyIncoming: notifyIncoming,
            persistConversations: persistConversations
        )
        await commitBatchDeltaToCore(delta)
        return Int(delta.appliedCount)
    }

    /// Applies message/reaction/recall/delete/typing side effects and returns the conversation delta for `olaz-core`.
    internal func applyParsedEventsCollectingDelta(
        _ events: [ParsedWireEvent],
        incrementUnread: Bool = false,
        notifyIncoming: Bool = false,
        persistConversations: Bool = true
    ) async -> BatchApplyDeltaRecord {
        let myUid = profile?.userId ?? ""
        guard !events.isEmpty else {
            return BatchApplyDeltaRecord(appliedCount: 0, updates: [], persistConversations: false)
        }

        var storedBatch: [StoredMessage] = []
        var unreadDeltaByConv: [String: Int] = [:]
        var latestByConv: [String: ChatMessage] = [:]
        var incomingForNotice: [ChatMessage] = []
        var markedE2EEInBatch: Set<String> = []

        // Pass 1: ingest and persist messages first so reaction/undo/delete events in the same batch
        // always find their target message and are never overwritten by the message upsert.
        for ev in events {
            if case .message(let msg, let stored) = ev {
                if msg.isE2EE,
                   !ZaloWireParser.isGroupId(msg.conversationId),
                   msg.conversationId != selfConversationId,
                   markedE2EEInBatch.insert(msg.conversationId).inserted {
                    await e2eeManager.markE2EEConversation(msg.conversationId, enabled: true, store: sqliteStore)
                }
                let isLockedE2EE = (stored.status == "e2ee_locked")
                if isLockedE2EE,
                   let memList = messages[msg.conversationId],
                   let readable = memList.first(where: { existing in
                       guard existing.id == msg.id || (!stored.clientId.isEmpty && existing.id == stored.clientId) else {
                           return false
                       }
                       if case .placeholder = existing.kind, existing.isE2EE { return false }
                       return true
                   }) {
                    // Keep the readable copy, but adopt the server msgId from the undecryptable echo of our
                    // own send: recall/react need the real global id (sending the clientId fails with 112).
                    if readable.id != msg.id, !msg.id.isEmpty, readable.id == stored.clientId {
                        mergeMessageIntoMemory(msg, replacingClientId: stored.clientId)
                        storedBatch.append(stored)
                    }
                    continue
                }
                let alreadyKnown = messages[msg.conversationId]?.contains(where: { $0.id == msg.id }) ?? false
                storedBatch.append(stored)
                mergeMessageIntoMemory(msg, replacingClientId: stored.clientId)
                if latestByConv[msg.conversationId] == nil || msg.date >= (latestByConv[msg.conversationId]?.date ?? .distantPast) {
                    latestByConv[msg.conversationId] = msg
                }
                if incrementUnread && !alreadyKnown && !msg.isMine && msg.conversationId != openConversationId {
                    unreadDeltaByConv[msg.conversationId, default: 0] += 1
                    incomingForNotice.append(msg)
                }
            }
        }
        if !storedBatch.isEmpty {
            try? await sqliteStore?.saveMessages(storedBatch, preserveExistingReactions: true)
        }

        // Pass 2: apply reactions chronologically (per target message), then recalls, deletes, and typing events.
        for ev in ZaloWireParser.sortReactionEventsChronologically(events) {
            if case .reaction(let convId, let msgId, let cliMsgId, let senderId, let rType, let rIcon, let eventId, let reactClientId, _, _, let senderName) = ev {
                await applyRemoteReaction(
                    convId: convId,
                    msgId: msgId,
                    cliMsgId: cliMsgId,
                    senderId: senderId,
                    rType: rType,
                    rIcon: rIcon,
                    eventId: eventId,
                    reactClientId: reactClientId,
                    senderName: senderName
                )
            }
        }
        for ev in events {
            switch ev {
            case .undo(let convId, let msgId, let cliMsgId):
                await applyRemoteRecall(convId: convId, msgId: msgId, cliMsgId: cliMsgId, updateConversationPreview: false)

            case .delete(let convId, let msgId, let cliMsgId):
                await applyRemoteDelete(convId: convId, msgId: msgId, cliMsgId: cliMsgId)

            case .typing(let convId, let senderId, _):
                if senderId != myUid {
                    showTyping(convId: convId, name: lookupPersonInfo(senderId)?.name ?? "Ai đó")
                }

            case .message, .reaction, .ignore:
                break
            }
        }

        var updates: [ConvMessageDeltaRecord] = []
        if !latestByConv.isEmpty {
            var pollMsgs: [ChatMessage] = []
            pollMsgs.reserveCapacity(latestByConv.count)
            updates.reserveCapacity(latestByConv.count)
            for (convId, latest) in latestByConv {
                pollMsgs.append(latest)
                updates.append(ConvMessageDeltaRecord(
                    convId: convId,
                    previewText: Self.messagePreviewLabel(latest),
                    previewDateMs: Int64((latest.date.timeIntervalSince1970 * 1000).rounded()),
                    previewFromMe: latest.isMine,
                    isMine: latest.isMine,
                    senderName: latest.senderName,
                    senderAvatar: latest.senderAvatar?.absoluteString,
                    unreadDelta: Int64(unreadDeltaByConv[convId] ?? 0)
                ))
            }
            notePollMessages(pollMsgs)
        }

        if notifyIncoming {
            for msg in incomingForNotice where !isConversationMuted(msg.conversationId) && notificationSettings.enabled {
                let convId = msg.conversationId
                let isGroup = ZaloWireParser.isGroupId(convId)
                let cleanSenderId = ZaloWireParser.stripUserPrefix(msg.senderId)
                let convSummary = conversations.first(where: { $0.id == convId })
                var person = (!cleanSenderId.isEmpty && cleanSenderId != "0") ? lookupPersonInfo(cleanSenderId) : nil

                var resolvedAvatarURL: URL? = msg.senderAvatar
                    ?? (person?.avatar.isEmpty == false ? URL(string: person!.avatar) : nil)
                    ?? (!isGroup ? convSummary?.avatar : nil)

                if resolvedAvatarURL == nil, !cleanSenderId.isEmpty, cleanSenderId != "0" {
                    if let profBox = try? await sessionClient.fetchProfiles(uids: [cleanSenderId]) {
                        let profilesMap = ZaloWireParser.extractProfilesMap(profBox.dict)
                        if let row = profilesMap[cleanSenderId] {
                            let fetchedName = ZaloWireParser.preferredName(row)
                            let avt = JSONLossless.string(row["avatar"] ?? row["avt"])
                            if !fetchedName.isEmpty || !avt.isEmpty {
                                cachedProfiles[cleanSenderId] = ZaloWebKitMigrator.CachedProfile(name: fetchedName, avatar: avt)
                                if let data = try? JSONEncoder().encode(cachedProfiles) {
                                    try? await sqliteStore?.setPreferenceData(key: "cachedProfiles", data: data)
                                }
                            }
                            if !avt.isEmpty, let url = URL(string: avt) {
                                resolvedAvatarURL = url
                            }
                            person = lookupPersonInfo(cleanSenderId)
                        }
                    }
                }

                let title: String = {
                    if let convName = convSummary?.displayName, !convName.isEmpty, convName != convId {
                        return convName
                    }
                    if let pName = person?.name, !pName.isEmpty, pName != cleanSenderId {
                        return pName
                    }
                    return msg.senderName.isEmpty ? convId : msg.senderName
                }()

                let senderName: String = {
                    if !isGroup {
                        return title
                    }
                    if let pName = person?.name, !pName.isEmpty, pName != cleanSenderId, pName != "Người dùng Zalo" {
                        return pName
                    }
                    return msg.senderName
                }()

                let rawBody = Self.messagePreviewLabel(msg)
                let body = notificationSettings.showsPreview ? rawBody : NotificationPolicy.hiddenPreviewBody
                NativeNotifier.shared.notifyIncomingMessage(
                    title: title,
                    body: body,
                    conversationId: convId,
                    senderId: cleanSenderId,
                    senderName: senderName,
                    isGroup: isGroup,
                    avatarURL: resolvedAvatarURL,
                    silent: !notificationSettings.sound
                )
            }
        }
        return BatchApplyDeltaRecord(
            appliedCount: UInt32(events.count),
            updates: updates,
            persistConversations: persistConversations
        )
    }

    internal func ensureKnownContactsInConversations() {
        if let core = coreLifecycle.core {
            core.ensureKnownContacts()
            return
        }
        let batch = offlineConversationsCore().ensureKnownContacts()
        applyCoreChanges(batch)
    }

    /// Classifies a control envelope through `olaz-core` (`classify_control_envelope`) and dispatches
    /// each resulting route to its Swift domain handler.
    internal func processControlEnvelope(_ payload: [String: Any], cmd: UInt16 = 0) async {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonText = String(data: data, encoding: .utf8) else {
            return
        }
        let routes = classifyControlEnvelope(
            cmd: cmd,
            payloadJson: jsonText,
            myUid: profile?.userId ?? "",
            nowUnixSecs: Int64(Date().timeIntervalSince1970)
        )
        for route in routes {
            switch route {
            case .recordFileDone(let fileId, let url):
                await webSocket.recordFileDone(fileId: fileId, url: url)
            case .logUndecodedControl(let routeCmd, let encrypt, let dataIsString):
                EngineLog.shared.write("ctrl: undecoded cmd=\(routeCmd) encrypt=\(encrypt) data=\(dataIsString ? "string" : "other")")
            case .voipControl(let act, let rawDataJson, let dataJson):
                let dataBox = ZaloJSONBox(JSONLossless.parseObject(string: dataJson) ?? [:])
                await hostHandleVoipControl(act: act, rawDataJson: rawDataJson, dataBox: dataBox)
            case .logTypingShape(let shape):
                if Self.loggedTypingShapes.insert(shape).inserted {
                    EngineLog.shared.write("typing: shape \(shape)")
                }
            case .showTyping(let convId, let uid, let onPc):
                if traceHost("show_typing", args: ["conv_id": convId, "uid": uid, "on_pc": onPc]) {
                    let name = lookupPersonInfo(uid)?.name ?? "Ai đó"
                    showTyping(convId: convId, name: name, onPC: onPc)
                }
            case .pinTopic(let convId):
                if traceHost("pin_topic", args: ["conv_id": convId]) {
                    handlePinTopicEvent(conversationId: convId)
                }
            case .groupNotice(let act, let dataJson, let ts):
                let dataBox = ZaloJSONBox(JSONLossless.parseObject(string: dataJson) ?? [:])
                await hostHandleGroupNotice(act: act, dataBox: dataBox, ts: ts)
            case .mute(let convId, let set, let start, let startExplicit, let duration):
                await hostApplyMute(
                    convId: convId,
                    set: set,
                    start: start,
                    startExplicit: startExplicit,
                    duration: duration
                )
            }
        }
    }

    // MARK: - Shared Helpers for Extensions

    /// The list preview of `msg`: `messagePreviewLabel` with its @mentions showing the member's current name (alias first),
    /// as in the chat.
    internal func conversationPreviewText(_ msg: ChatMessage) -> String {
        let label = Self.messagePreviewLabel(msg)
        guard !msg.mentions.isEmpty, label == msg.text.trimmingCharacters(in: .whitespacesAndNewlines) else { return label }
        return ChatFormat.renamingMentions(msg.text, mentions: msg.mentions, name: { self.mentionDisplayName($0) })
            .text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stored list previews hold the text as sent: redo those that may carry an @mention from the newest stored message.
    internal func refreshMentionPreviews() async {
        guard let core = await ensureCoreEngine() else { return }
        if let v = try? await core.refreshMentionPreviews() {
            await waitForMirrorVersion(v)
        }
    }

    internal static func messagePreviewLabel(_ msg: ChatMessage) -> String {
        let trimmed = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        switch msg.kind {
        case .photo: return "[Hình ảnh]"
        case .video: return "[Video]"
        case .sticker: return "[Sticker]"
        case .gif: return "[GIF]"
        case .voice: return "[Tin nhắn thoại]"
        case .file(let name, _, _): return name.isEmpty ? "[Tệp đính kèm]" : name
        case .location: return "[Vị trí]"
        case .contactCard(let c): return "[Danh thiếp] \(c.name)"
        case .call(let video, _, _, let title, _): return title.isEmpty ? (video ? "Cuộc gọi video" : "Cuộc gọi thoại") : title
        case .poll(let p): return p.question.isEmpty ? "[Bình chọn]" : p.question
        case .ecard(let e): return e.title.isEmpty ? "[Thiệp]" : e.title
        case .placeholder(_, let pText): return pText.contains("Sticker") ? "[Sticker]" : "🔒 Tin nhắn mã hóa đầu cuối"
        case .recalled: return "Tin nhắn đã được thu hồi"
        default: return "[Tin nhắn]"
        }
    }

    internal func lookupPersonInfo(_ uid: String) -> (name: String, avatar: String)? {
        let clean = ZaloWireParser.stripUserPrefix(uid)
        guard !clean.isEmpty, clean != "0", clean != "-1", clean != "__legacy__", clean != "unknown" else {
            return nil
        }
        var candidates: [String] = [clean]
        if let sanitized = ZaloWireParser.sanitizeProfileUid(clean), sanitized != clean {
            candidates.append(sanitized)
        }
        if friendUidByGlobalId == nil {
            friendUidByGlobalId = Dictionary(cachedFriendGlobalIds.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        }
        if let mappedUid = candidates.lazy.compactMap({ self.friendUidByGlobalId?[$0] }).first,
           !candidates.contains(mappedUid) {
            candidates.append(mappedUid)
        }

        let cleanMyUid = ZaloWireParser.stripUserPrefix(profile?.userId ?? "")
        let sanitizedMyUid = ZaloWireParser.sanitizeProfileUid(cleanMyUid) ?? cleanMyUid
        if !cleanMyUid.isEmpty, candidates.contains(where: { $0 == cleanMyUid || $0 == sanitizedMyUid }) {
            return ("Bạn", profile?.avatar?.absoluteString ?? "")
        }

        for candidate in candidates {
            let alias = cachedAliases[candidate]
            if let f = contacts.friends.first(where: { $0.id == candidate }) {
                let avt = f.avatar?.absoluteString ?? cachedProfiles[candidate]?.avatar ?? ""
                return (alias?.isEmpty == false ? alias! : f.name, avt)
            }
            if let p = cachedProfiles[candidate] {
                let best = (alias?.isEmpty == false) ? alias! : p.name
                let validBest = (best == ReactionDetail.unknownName) ? "" : best
                if !validBest.isEmpty || !p.avatar.isEmpty {
                    return (validBest, p.avatar)
                }
            }
            if let alias, !alias.isEmpty, alias != ReactionDetail.unknownName {
                return (alias, "")
            }
        }
        for candidate in candidates {
            if let conv = conversations.first(where: { $0.id == candidate }) {
                let trimmedName = conv.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let validName = (!trimmedName.isEmpty && trimmedName != conv.id && trimmedName != ReactionDetail.unknownName) ? trimmedName : ""
                let avt = conv.avatar?.absoluteString ?? ""
                if !validName.isEmpty || !avt.isEmpty {
                    return (validName, avt)
                }
            }
        }
        return nil
    }

    internal func lookupConversationIdentity(_ convId: String) -> (name: String, avatar: URL?, members: Int) {
        if convId == selfConversationId {
            return ("Cloud của tôi", nil, 0)
        }
        if ZaloWireParser.isGroupId(convId) {
            if let g = contacts.groups.first(where: { $0.id == convId }) {
                return (g.name, g.avatar, g.members)
            }
            if let cg = cachedGroups[convId] {
                return (
                    cg.name.isEmpty ? convId : cg.name,
                    cg.avatar.isEmpty ? nil : URL(string: cg.avatar),
                    cg.members
                )
            }
            return (convId, nil, 0)
        }
        let clean = ZaloWireParser.stripUserPrefix(convId)
        let alias = cachedAliases[clean]
        if let f = contacts.friends.first(where: { $0.id == clean }) {
            let avt = f.avatar ?? cachedProfiles[clean].flatMap { $0.avatar.isEmpty ? nil : URL(string: $0.avatar) }
            return ((alias?.isEmpty == false) ? alias! : f.name, avt, 0)
        }
        if let p = cachedProfiles[clean] {
            let bestName = (alias?.isEmpty == false) ? alias! : p.name
            let avt = p.avatar.isEmpty ? nil : URL(string: p.avatar)
            return (bestName, avt, 0)
        }
        if let alias, !alias.isEmpty {
            return (alias, nil, 0)
        }
        return ("", nil, 0)
    }

    /// The sender's current name / avatar from the contact caches, for a message about to enter memory.
    private func withKnownSender(_ rawMsg: ChatMessage) -> ChatMessage {
        var msg = rawMsg
        if !msg.isMine, !msg.senderId.isEmpty, msg.senderId != "0",
           let info = lookupPersonInfo(msg.senderId) {
            if !info.name.isEmpty, info.name != msg.senderId, info.name != "Người dùng Zalo" {
                msg.senderName = info.name
            }
            if msg.senderAvatar == nil, !info.avatar.isEmpty, let url = URL(string: info.avatar) {
                msg.senderAvatar = url
            }
        }
        return msg
    }

    /// Many messages of one chat at once (a jump to an old pin / search match loads up to thousands): one write and one
    /// sort, instead of `mergeMessageIntoMemory` per row (an array copy, a sort and an observer invalidation each, which
    /// froze the main thread). Rows that may replace or match a row already in memory still go through the single merge.
    internal func mergeMessagesIntoMemory(_ rows: [(message: ChatMessage, clientId: String?)], in convId: String) {
        var known = Set<String>()
        for m in messages[convId] ?? [] {
            known.insert(m.id)
            if !m.clientId.isEmpty { known.insert(m.clientId) }
        }
        var fresh: [ChatMessage] = []
        var colliding: [(message: ChatMessage, clientId: String?)] = []
        fresh.reserveCapacity(rows.count)
        for row in rows {
            let m = row.message
            let keys = [m.id, m.clientId, row.clientId ?? ""].filter { !$0.isEmpty }
            if m.conversationId != convId || keys.contains(where: known.contains) {
                colliding.append(row)
                continue
            }
            known.formUnion(keys)
            fresh.append(withKnownSender(m))
        }
        if !fresh.isEmpty {
            var list = messages[convId] ?? []
            list.append(contentsOf: fresh)
            list.sort { a, b in
                if a.date != b.date { return a.date < b.date }
                return a.id < b.id
            }
            messages[convId] = list
        }
        for row in colliding { mergeMessageIntoMemory(row.message, replacingClientId: row.clientId) }
    }

    internal func mergeMessageIntoMemory(_ rawMsg: ChatMessage, replacingClientId clientId: String? = nil) {
        var msg = withKnownSender(rawMsg)
        var list = messages[msg.conversationId] ?? []
        let originalCount = list.count
        let incomingIsLockedPlaceholder: Bool = {
            if case .placeholder = msg.kind, msg.isE2EE { return true }
            return false
        }()
        let resolvedClientId = (clientId?.isEmpty == false) ? clientId : (msg.clientId.isEmpty ? nil : msg.clientId)
        var preservedReactions: [ChatMessage.Reaction] = []
        if let existingById = list.first(where: { $0.id == msg.id }) {
            if !existingById.reactions.isEmpty {
                preservedReactions = existingById.reactions
            }
            if msg.clientId.isEmpty && !existingById.clientId.isEmpty {
                msg.clientId = existingById.clientId
            }
        } else if let cid = resolvedClientId,
                  let existingByCli = list.first(where: { $0.id == cid || $0.clientId == cid }) {
            if !existingByCli.reactions.isEmpty {
                preservedReactions = existingByCli.reactions
            }
            if msg.clientId.isEmpty {
                msg.clientId = existingByCli.clientId.isEmpty ? cid : existingByCli.clientId
            }
        }
        if msg.reactions.isEmpty && !preservedReactions.isEmpty && msg.kind != .recalled {
            msg.reactions = preservedReactions
        }
        if let clientId, !clientId.isEmpty, clientId != msg.id {
            if incomingIsLockedPlaceholder {
                if let idx = list.firstIndex(where: { existing in
                    guard existing.id == clientId else { return false }
                    if case .placeholder = existing.kind, existing.isE2EE { return false }
                    return true
                }) {
                    list[idx].id = msg.id
                    if list[idx].clientId.isEmpty {
                        list[idx].clientId = clientId
                    }
                    messages[msg.conversationId] = list
                    return
                }
                if list.contains(where: { existing in
                    guard existing.clientId == clientId && existing.id != clientId else { return false }
                    if case .placeholder = existing.kind, existing.isE2EE { return false }
                    return true
                }) {
                    return
                }
            } else {
                list.removeAll { $0.id == clientId }
            }
        }
        if let idx = list.firstIndex(where: { $0.id == msg.id }) {
            // The same message again (history refresh, WAL re-read): no write, so observers (the open chat) are not invalidated.
            let untouched = list.count == originalCount
            if untouched, list[idx] == msg { return }
            if incomingIsLockedPlaceholder {
                if case .placeholder = list[idx].kind, list[idx].isE2EE {
                    list[idx] = msg
                } else if untouched {
                    return
                }
            } else {
                list[idx] = msg
            }
        } else if let last = list.last,
                  (last.date < msg.date || (last.date == msg.date && last.id < msg.id)) {
            list.append(msg)
        } else {
            list.append(msg)
            list.sort { a, b in
                if a.date != b.date { return a.date < b.date }
                return a.id < b.id
            }
        }
        messages[msg.conversationId] = list
    }

    internal func updateConversationOnMessage(_ msg: ChatMessage, incrementUnread: Bool) {
        let input = messagePreviewInputRecord(for: msg)
        if let core = coreLifecycle.core {
            core.updateConversationOnMessage(msg: input, incrementUnread: incrementUnread)
            return
        }
        let batch = offlineConversationsCore().updateConversationOnMessage(msg: input, incrementUnread: incrementUnread)
        applyCoreChanges(batch)
        if batch.conversations != nil {
            persistConversationsTask = Task { await persistConversationsToSQLite() }
        }
    }

    internal func sortConversations(_ list: inout [ConversationSummary]) {
        let ranks = cachedActivityRanks.map { RankEntry(convId: $0.key, rank: $0.value) }
        list = sortConversationsOrder(items: list.map(\.coreRecord), activityRanks: ranks)
            .map(ConversationSummary.init(coreRecord:))
    }

    internal func persistConversationsToSQLite() async {
        if let core = coreLifecycle.core {
            if let v = try? await core.persistConversations() {
                await waitForMirrorVersion(v)
            }
            return
        }
        guard let store = sqliteStore else { return }
        let rows = conversations.map { c in
            StoredConversation(
                id: c.id,
                isGroup: c.isGroup,
                name: c.name,
                avatar: c.avatar?.absoluteString ?? "",
                pinned: c.pinned,
                members: c.members,
                unread: c.unread,
                previewText: c.preview?.text ?? "",
                previewTsMs: Int64(((c.preview?.date?.timeIntervalSince1970 ?? 0) * 1000).rounded()),
                previewFromMe: c.preview?.fromMe ?? false,
                updatedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
            )
        }
        try? await store.saveConversations(rows)
    }

    @MainActor static var loggedTypingShapes: Set<String> = []

    internal func showTyping(convId: String, name: String, onPC: Bool = false) {
        let status = TypingStatus(name: name, onPC: onPC)
        if typing[convId] != status { typing[convId] = status }
        typingResetTasks[convId]?.cancel()
        typingResetTasks[convId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(TypingStatus.displaySeconds))
            guard !Task.isCancelled else { return }
            self?.typing[convId] = nil
            self?.typingResetTasks[convId] = nil
        }
    }

    internal func persistPollState() async {
        guard traceHost("persist_poll_state", args: ["state": Self.serializePollState(pollState)]) else { return }
        guard let store = sqliteStore,
              let data = try? JSONEncoder().encode(pollState) else { return }
        try? await store.setPreferenceData(key: "pollState", data: data)
    }

    internal func persistWSQueueCursors(_ cursors: [String: ZaloWSQueueCursorSnapshot]) async {
        guard traceHost("persist_ws_cursors", args: ["cursors": Self.serializeWSQueueCursors(cursors)]) else { return }
        guard let store = sqliteStore,
              let data = try? JSONEncoder().encode(cursors) else { return }
        try? await store.setPreferenceData(key: "wsQueueCursors", data: data)
    }

    internal func recordSeenReactionKeys(_ keys: [String]) async {
        var insertedAny = false
        for rawKey in keys {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            if seenReactionEventIds.insert(key).inserted {
                seenReactionEventOrder.append(key)
                insertedAny = true
            }
        }
        guard insertedAny else { return }
        if seenReactionEventOrder.count > 1000 {
            let overflow = seenReactionEventOrder.count - 1000
            let evicted = seenReactionEventOrder.prefix(overflow)
            seenReactionEventOrder.removeFirst(overflow)
            for old in evicted {
                seenReactionEventIds.remove(old)
            }
        }
        try? await sqliteStore?.setPreferenceStrings(key: "seenReactionEventIds", value: seenReactionEventOrder)
    }

    internal func refreshReactionNames(in targetConvId: String? = nil) {
        let myUid = ZaloWireParser.sanitizeProfileUid(profile?.userId ?? "") ?? ZaloWireParser.stripUserPrefix(profile?.userId ?? "")
        let convKeys = targetConvId.map { [$0] } ?? Array(messages.keys)
        var changedRows: [StoredMessage] = []

        for convId in convKeys {
            guard var list = messages[convId] else { continue }
            var listChanged = false
            for idx in list.indices where !list[idx].reactions.isEmpty {
                var msg = list[idx]
                var reactionsChanged = false
                for rIdx in msg.reactions.indices {
                    var r = msg.reactions[rIdx]
                    var orderedUids = Array(r.userCounts.keys).filter {
                        !$0.isEmpty && $0 != "__legacy__" && $0 != "unknown" && $0 != "-1" && (r.userCounts[$0] ?? 0) > 0
                    }.sorted()
                    if r.includesMe, !myUid.isEmpty {
                        orderedUids.removeAll { $0 == myUid || $0 == "0" || $0 == "me" }
                        orderedUids.insert(myUid, at: 0)
                    }
                    guard !orderedUids.isEmpty else { continue }
                    var refreshed: [String] = []
                    for uid in orderedUids where refreshed.count < 3 {
                        if uid == myUid || uid == "0" || uid == "me" {
                            refreshed.append("Bạn")
                        } else if let name = lookupPersonInfo(uid)?.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                  !name.isEmpty, name != ReactionDetail.unknownName, name != uid {
                            refreshed.append(name)
                        }
                    }
                    if refreshed != r.names {
                        r.names = refreshed
                        msg.reactions[rIdx] = r
                        reactionsChanged = true
                    }
                }
                if reactionsChanged {
                    list[idx] = msg
                    listChanged = true
                    if let stored = ZaloWireParser.encodeChatMessage(msg) {
                        changedRows.append(stored)
                    }
                }
            }
            if listChanged {
                messages[convId] = list
            }
        }

        if !changedRows.isEmpty, let store = sqliteStore {
            Task {
                try? await store.saveMessages(changedRows, preserveExistingReactions: false)
            }
        }
    }

    internal static func mutateReactions(
        _ reactions: inout [ChatMessage.Reaction],
        actorUid: String,
        myUid: String,
        isMe: Bool,
        rType: String,
        rIcon: String,
        allowDuplicateSameUser: Bool,
        nameLookup: (String) -> String
    ) {
        let trimmedType = rType.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIcon = rIcon.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedType.isEmpty || !trimmedIcon.isEmpty else { return }

        let cleanMyUid = ZaloWireParser.sanitizeProfileUid(myUid) ?? ZaloWireParser.stripUserPrefix(myUid)
        let myKey = cleanMyUid.isEmpty ? "me" : cleanMyUid
        let cleanActor = ZaloWireParser.stripUserPrefix(actorUid)
        let normalizedActor = isMe ? myKey : (ZaloWireParser.sanitizeProfileUid(cleanActor) ?? cleanActor)
        let sentinelKeys: Set<String> = ["", "__legacy__", "unknown", "-1"]
        if !isMe && sentinelKeys.contains(normalizedActor) {
            return
        }

        func rebuildDerivedFields(_ reaction: inout ChatMessage.Reaction) {
            reaction.userCounts = reaction.userCounts.filter { !sentinelKeys.contains($0.key) && $0.value > 0 }
            let totalCount = reaction.userCounts.values.reduce(0, +)
            reaction.count = totalCount
            reaction.includesMe = (reaction.userCounts[myKey] ?? 0) > 0
            reaction.people = reaction.userCounts.count

            var orderedUids = Array(reaction.userCounts.keys).sorted()
            if reaction.includesMe {
                orderedUids.removeAll { $0 == myKey }
                orderedUids.insert(myKey, at: 0)
            }
            var rebuiltNames: [String] = []
            for uid in orderedUids where rebuiltNames.count < 3 {
                if uid == myKey {
                    rebuiltNames.append("Bạn")
                } else {
                    let resolved = nameLookup(uid).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !resolved.isEmpty && resolved != ReactionDetail.unknownName && resolved != uid {
                        rebuiltNames.append(resolved)
                    }
                }
            }
            reaction.names = rebuiltNames
        }

        let isRemoval = trimmedType == "-1" || ((Int(trimmedType) ?? 0) < 0)
        if isRemoval {
            reactions = reactions.compactMap { existing in
                var r = existing
                if !r.userCounts.isEmpty {
                    r.userCounts.removeValue(forKey: "__legacy__")
                    r.userCounts.removeValue(forKey: "unknown")
                    if isMe {
                        r.userCounts.removeValue(forKey: myKey)
                        r.userCounts.removeValue(forKey: "0")
                        r.userCounts.removeValue(forKey: "me")
                    } else {
                        r.userCounts.removeValue(forKey: normalizedActor)
                        if cleanActor != normalizedActor {
                            r.userCounts.removeValue(forKey: cleanActor)
                        }
                    }
                    rebuildDerivedFields(&r)
                    return r.count > 0 ? r : nil
                } else {
                    let hadKnownPeople = existing.people > 0
                    if isMe {
                        guard r.includesMe else { return r }
                        r.includesMe = false
                        r.names.removeAll { $0 == "Bạn" }
                        r.people = max(0, existing.people - 1)
                        r.count = (hadKnownPeople && r.people == 0) ? 0 : max(0, existing.count - 1)
                    } else {
                        let actorName = nameLookup(normalizedActor).trimmingCharacters(in: .whitespacesAndNewlines)
                        let matchedName = !actorName.isEmpty && r.names.contains(actorName)
                        if matchedName || (!r.includesMe && r.people <= 1) {
                            if matchedName {
                                r.names.removeAll { $0 == actorName }
                            }
                            r.people = max(0, existing.people - 1)
                            r.count = (hadKnownPeople && r.people == 0) ? 0 : max(0, existing.count - 1)
                        }
                    }
                    return r.count > 0 ? r : nil
                }
            }
            return
        }

        guard let icon = ZaloWireParser.reactionIcon(rType: trimmedType, rIcon: trimmedIcon) else {
            return
        }

        if let rIdx = reactions.firstIndex(where: { $0.icon.type == icon.type }) {
            var r = reactions[rIdx]
            if r.userCounts.isEmpty && r.count > 0 && r.includesMe {
                r.userCounts[myKey] = 1
            }
            if allowDuplicateSameUser || r.userCounts[normalizedActor] == nil {
                r.userCounts[normalizedActor, default: 0] += 1
            }
            rebuildDerivedFields(&r)
            reactions[rIdx] = r
        } else {
            var created = ChatMessage.Reaction(
                icon: icon,
                count: 1,
                includesMe: isMe,
                names: [],
                people: 1,
                userCounts: [normalizedActor: 1]
            )
            rebuildDerivedFields(&created)
            reactions.append(created)
        }
    }

    internal func applyRemoteReaction(
        convId: String,
        msgId: String,
        cliMsgId: String,
        senderId: String,
        rType: String,
        rIcon: String,
        eventId: String = "",
        reactClientId: String = "",
        senderName: String = ""
    ) async {
        guard traceU4Host("apply_remote_reaction", args: [
            "conv_id": convId,
            "msg_id": msgId,
            "cli_msg_id": cliMsgId,
            "sender_id": senderId,
            "r_type": rType,
            "r_icon": rIcon,
            "event_id": eventId,
            "react_client_id": reactClientId,
            "sender_name": senderName,
        ]) else {
            return
        }
        let trimmedConv = convId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMsg = msgId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCli = cliMsgId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedType = rType.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIcon = rIcon.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEventId = eventId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReactCli = reactClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWireSenderName = senderName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedConv.isEmpty,
              (!trimmedMsg.isEmpty || !trimmedCli.isEmpty),
              (!trimmedType.isEmpty || !trimmedIcon.isEmpty) else {
            return
        }

        let sanitizedConv = ZaloWireParser.isGroupId(trimmedConv)
            ? trimmedConv
            : (ZaloWireParser.sanitizeProfileUid(trimmedConv) ?? trimmedConv)
        let dedupConv = sanitizedConv
        let targetKey = !trimmedMsg.isEmpty ? trimmedMsg : trimmedCli

        var candidateDedupKeys: [String] = []
        if !trimmedEventId.isEmpty {
            candidateDedupKeys.append("\(dedupConv)|\(targetKey)|\(trimmedEventId)|\(trimmedType)")
        }
        if !trimmedReactCli.isEmpty {
            if !trimmedMsg.isEmpty {
                candidateDedupKeys.append("\(dedupConv)|\(trimmedMsg)|cli:\(trimmedReactCli)|\(trimmedType)")
            }
            if !trimmedCli.isEmpty && trimmedCli != trimmedMsg {
                candidateDedupKeys.append("\(dedupConv)|\(trimmedCli)|cli:\(trimmedReactCli)|\(trimmedType)")
            }
        }
        if candidateDedupKeys.contains(where: { seenReactionEventIds.contains($0) }) {
            return
        }
        await recordSeenReactionKeys(candidateDedupKeys)

        let myUid = profile?.userId ?? ""
        let sanitizedMyUid = ZaloWireParser.sanitizeProfileUid(myUid) ?? ZaloWireParser.stripUserPrefix(myUid)
        let cleanSender = ZaloWireParser.stripUserPrefix(senderId)
        if cleanSender == "-1" { return }
        let sanitizedSender = ZaloWireParser.sanitizeProfileUid(cleanSender)
        let isMe = (!myUid.isEmpty && (cleanSender == myUid || sanitizedSender == sanitizedMyUid))
            || cleanSender == "0"
            || cleanSender.isEmpty

        if !isMe {
            let canonicalActor = sanitizedSender ?? cleanSender
            if !canonicalActor.isEmpty,
               !trimmedWireSenderName.isEmpty,
               trimmedWireSenderName != ReactionDetail.unknownName,
               trimmedWireSenderName != canonicalActor {
                let existing = lookupPersonInfo(canonicalActor)
                if existing == nil || existing?.name.isEmpty == true || existing?.name == canonicalActor {
                    let existingAvatar = existing?.avatar ?? cachedProfiles[canonicalActor]?.avatar ?? ""
                    cachedProfiles[canonicalActor] = ZaloWebKitMigrator.CachedProfile(name: trimmedWireSenderName, avatar: existingAvatar)
                }
            }
        }

        let now = Date()
        pendingLocalReactions.removeAll { now.timeIntervalSince($0.createdAt) > 20 }
        if isMe, let matchIdx = pendingLocalReactions.firstIndex(where: { pending in
            guard pending.convId == trimmedConv || pending.convId == sanitizedConv else { return false }
            let msgMatches = (!trimmedMsg.isEmpty && (pending.msgId == trimmedMsg || pending.cliMsgId == trimmedMsg))
                || (!trimmedCli.isEmpty && (pending.msgId == trimmedCli || pending.cliMsgId == trimmedCli))
            guard msgMatches else { return false }
            if !trimmedReactCli.isEmpty && pending.reactClientId == trimmedReactCli {
                return true
            }
            return pending.rType == trimmedType
        }) {
            pendingLocalReactions.remove(at: matchIdx)
            return
        }

        func matchesMessage(_ m: ChatMessage) -> Bool {
            if !trimmedMsg.isEmpty && (m.id == trimmedMsg || m.clientId == trimmedMsg) {
                return true
            }
            if !trimmedCli.isEmpty && (m.id == trimmedCli || m.clientId == trimmedCli) {
                return true
            }
            return false
        }

        let memoryConvKey: String? = {
            if messages[trimmedConv]?.contains(where: matchesMessage) == true { return trimmedConv }
            if sanitizedConv != trimmedConv, messages[sanitizedConv]?.contains(where: matchesMessage) == true { return sanitizedConv }
            return nil
        }()

        if let convKey = memoryConvKey,
           var list = messages[convKey],
           let idx = list.firstIndex(where: matchesMessage) {
            var msg = list[idx]
            Self.mutateReactions(
                &msg.reactions,
                actorUid: cleanSender,
                myUid: myUid,
                isMe: isMe,
                rType: trimmedType,
                rIcon: trimmedIcon,
                allowDuplicateSameUser: !trimmedEventId.isEmpty,
                nameLookup: { [weak self] uid in
                    self?.lookupPersonInfo(uid)?.name ?? ""
                }
            )
            list[idx] = msg
            messages[convKey] = list
            if let stored = ZaloWireParser.encodeChatMessage(msg) {
                try? await sqliteStore?.saveMessages([stored], preserveExistingReactions: false)
            }
            return
        }

        if let store = sqliteStore {
            let convCandidates = (sanitizedConv == trimmedConv) ? [trimmedConv] : [trimmedConv, sanitizedConv]
            var storedRow: DecodedMessageRow?
            for candidateConv in convCandidates where storedRow == nil {
                if !trimmedMsg.isEmpty {
                    storedRow = try? await store.decodedMessage(convId: candidateConv, idOrClientId: trimmedMsg)
                }
                if storedRow == nil && !trimmedCli.isEmpty {
                    storedRow = try? await store.decodedMessage(convId: candidateConv, idOrClientId: trimmedCli)
                }
            }
            if var decoded = storedRow?.message {
                Self.mutateReactions(
                    &decoded.reactions,
                    actorUid: cleanSender,
                    myUid: myUid,
                    isMe: isMe,
                    rType: trimmedType,
                    rIcon: trimmedIcon,
                    allowDuplicateSameUser: !trimmedEventId.isEmpty,
                    nameLookup: { [weak self] uid in
                        self?.lookupPersonInfo(uid)?.name ?? ""
                    }
                )
                if let updated = ZaloWireParser.encodeChatMessage(decoded) {
                    try? await store.saveMessages([updated], preserveExistingReactions: false)
                }
            }
        }
    }

    internal func applyRemoteRecall(convId: String, msgId: String, cliMsgId: String, updateConversationPreview: Bool = true) async {
        guard traceU4Host("apply_remote_recall", args: [
            "conv_id": convId,
            "msg_id": msgId,
            "cli_msg_id": cliMsgId,
        ]) else {
            return
        }
        let targetId = !msgId.isEmpty ? msgId : cliMsgId
        guard !targetId.isEmpty else { return }

        var updatedPreview = false
        if var list = messages[convId],
           let idx = list.firstIndex(where: {
               (!msgId.isEmpty && ($0.id == msgId || $0.clientId == msgId))
                   || (!cliMsgId.isEmpty && ($0.clientId == cliMsgId || $0.id == cliMsgId))
           }) {
            let recalledId = list[idx].id
            let wasLast = (idx == list.count - 1)
            let msgDate = list[idx].date
            let msgFromMe = list[idx].isMine

            list[idx].kind = .recalled
            list[idx].text = ""
            list[idx].reactions = []
            list[idx].quote = nil
            list[idx].cardButtons = []
            list[idx].menu.recall = false
            list[idx].menu.forward = .hidden
            list[idx].menu.pin = false
            list[idx].menu.star = nil
            list[idx].menu.starred = false
            messages[convId] = list

            if cachedStarredIds.remove(recalledId) != nil {
                try? await sqliteStore?.setPreferenceStrings(key: "starredIds", value: Array(cachedStarredIds))
            }

            if updateConversationPreview, wasLast, let convIdx = conversations.firstIndex(where: { $0.id == convId }) {
                var conv = conversations[convIdx]
                if (conv.preview?.date ?? .distantPast) <= msgDate.addingTimeInterval(1) {
                    conv.preview = ConversationSummary.Preview(
                        text: "Tin nhắn đã được thu hồi",
                        date: conv.preview?.date ?? msgDate,
                        fromMe: conv.preview?.fromMe ?? msgFromMe
                    )
                    conversations[convIdx] = conv
                    updatedPreview = true
                }
            }
        }

        try? await sqliteStore?.markRecalled(convId: convId, id: targetId, cliMsgId: cliMsgId)

        if updateConversationPreview, !updatedPreview,
           let convIdx = conversations.firstIndex(where: { $0.id == convId }),
           let latest = try? await sqliteStore?.messages(convId: convId, limit: 1).first,
           latest.kindTag == "recalled" {
            let latestDate = Date(timeIntervalSince1970: Double(latest.tsMs) / 1000)
            var conv = conversations[convIdx]
            if conv.preview?.text != "Tin nhắn đã được thu hồi",
               (conv.preview?.date ?? .distantPast) <= latestDate.addingTimeInterval(1) {
                conv.preview = ConversationSummary.Preview(
                    text: "Tin nhắn đã được thu hồi",
                    date: conv.preview?.date ?? latestDate,
                    fromMe: conv.preview?.fromMe ?? latest.isMine
                )
                conversations[convIdx] = conv
                updatedPreview = true
            }
        }

        if updatedPreview {
            await persistConversationsToSQLite()
        }
    }

    internal func applyRemoteDelete(convId: String, msgId: String, cliMsgId: String) async {
        guard traceU4Host("apply_remote_delete", args: [
            "conv_id": convId,
            "msg_id": msgId,
            "cli_msg_id": cliMsgId,
        ]) else {
            return
        }
        let targetId = !msgId.isEmpty ? msgId : cliMsgId
        guard !targetId.isEmpty else { return }
        if var list = messages[convId] {
            list.removeAll { $0.id == targetId || $0.id == cliMsgId }
            messages[convId] = list
        }
        try? await sqliteStore?.deleteMessage(convId: convId, id: targetId)
    }

    nonisolated static func listOrder(_ conversations: [ConversationSummary]) -> [ConversationSummary] {
        sortConversationsOrder(items: conversations.map(\.coreRecord), activityRanks: [])
            .map(ConversationSummary.init(coreRecord:))
    }
}

// MARK: - Per-conversation reads for views

extension ZaloEngine {
    /// `messages[id]`, observed for this conversation only.
    func messages(in id: String) -> [ChatMessage]? {
        messageSignal.track(id)
        return _messages[id]
    }

    /// `hasMoreHistory[id]`, observed for this conversation only.
    func hasMoreHistory(in id: String) -> Bool? {
        hasMoreSignal.track(id)
        return _hasMoreHistory[id]
    }

    /// Who is typing in `id` (`typing[id]`), observed for this conversation only.
    func typingStatus(in id: String) -> TypingStatus? {
        typingSignal.track(id)
        return _typing[id]
    }
}
