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

    private(set) var phase: Phase = .starting {
        didSet { stateTrace?() }
    }
    var conversations: [ConversationSummary] = []
    private(set) var profile: Profile? {
        didSet { stateTrace?() }
    }
    private(set) var signOutNotice: String? {
        didSet { stateTrace?() }
    }
    private(set) var clientVersion: String? = "694 (Native)"
    private(set) var recentLog: [String] = []

    var openConversationId: String?
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

    var selfConversationId: String? {
        didSet { stateTrace?() }
    }
    var navigationRequest: String?
    var conversationExtras = ConversationExtras()
    var conversationActions = ConversationActionsState()
    let conversationUI = ConversationActionUI()
    var conversationPrompt: ConversationPrompt?
    var contacts = ContactsState()
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
    @ObservationIgnored internal var sqliteStore: ZaloSQLiteStore?
    @ObservationIgnored internal var callBridge: CallBridge?

    @ObservationIgnored private var started = false
    internal var isEngineStarted: Bool { started }
    @ObservationIgnored internal var hostTrace: ((String, [String: Any]) -> Bool)?
    @ObservationIgnored internal var stateTrace: (() -> Void)?
    @ObservationIgnored internal var transportSettleTrace: (() -> Void)?
    @ObservationIgnored internal var recordedQRPayload: String?
    @ObservationIgnored internal var recordedSessionPrefs: [String: String] = [:]
    @ObservationIgnored internal var pendingCleanupTask: Task<Void, Never>?
    @ObservationIgnored internal var bootTask: Task<Void, Never>?
    @ObservationIgnored internal var qrTask: Task<Void, Never>?
    @ObservationIgnored internal var wsTask: Task<Void, Never>?
    @ObservationIgnored internal var lpPollTask: Task<Void, Never>?
    @ObservationIgnored internal var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored internal var transferTask: Task<Void, Never>?
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
    @ObservationIgnored internal var cachedFriendGlobalIds: [String: String] = [:] { didSet { friendUidByGlobalId = nil } }
    /// `cachedFriendGlobalIds` reversed (global id → uid), built on first use: looking a sender up scanned the whole map for every
    /// message (50 per chat opened, ~25 ms of main thread).
    @ObservationIgnored private var friendUidByGlobalId: [String: String]?
    @ObservationIgnored internal var cachedPinnedIds: Set<String> = []
    @ObservationIgnored internal var cachedArchivedIds: Set<String> = []
    @ObservationIgnored internal var cachedStarredIds: Set<String> = []
    @ObservationIgnored internal var cachedUnreadMarks: Set<String> = []
    @ObservationIgnored internal var cachedAliases: [String: String] = [:]
    @ObservationIgnored internal var cachedProfiles: [String: ZaloWebKitMigrator.CachedProfile] = [:]
    @ObservationIgnored internal var cachedGroups: [String: ZaloWebKitMigrator.CachedGroup] = [:]
    @ObservationIgnored internal var cachedActivityRanks: [String: Int64] = [:]
    /// Per-conversation result of the launch preload probe (see `ZaloEngine+HistoryFreshness.swift`).
    @ObservationIgnored internal var historyFreshness: [String: HistoryFreshness] = [:]
    @ObservationIgnored internal var historyFullRefreshDue = false
    @ObservationIgnored internal var cachedBoardRawTopics: [String: (version: Int64, topics: [String: [String: Any]])] = [:]
    @ObservationIgnored internal var cachedHiddenPinHash: String?
    @ObservationIgnored internal var cachedHiddenPinMD5: String?
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
        domains: ZaloDomains = ZaloDomains()
    ) {
        self.dataDirectory = dataDirectory
        self.sessionClient = ZaloSessionClient(dataDirectory: dataDirectory, useKeychain: useKeychain, domains: domains)
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

        bootTask = Task { [weak self] in
            await self?.bootSession()
        }
    }

    func retryRuntimeSetup() {
        refreshQR()
    }

    func refreshQR() {
        qrTask?.cancel()
        qrTask = nil
        signOutNotice = nil
        startQRLoginFlow()
    }

    func logOut() {
        EngineLog.shared.write("engine: logOut")
        qrTask?.cancel(); qrTask = nil
        wsTask?.cancel(); wsTask = nil
        lpPollTask?.cancel(); lpPollTask = nil
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
        let allowClear = traceHost("clear_session")
        let allowResetDomains = traceHost("reset_domains")
        pendingCleanupTask = Task {
            await phoneSync.resetAll()
            await e2eeManager.reset()
            await webSocket.stop()
            await sessionClient.clearSession(clearDisk: allowClear, resetDomains: allowResetDomains)
            await sqliteStore?.close()
        }
        sqliteStore = nil
        resetSessionState()
        failedDrafts = FailedDraftStore()
        signOutNotice = nil
        startQRLoginFlow()
    }

    internal func handleSessionExpiredNotice(_ reason: String) {
        qrTask?.cancel(); qrTask = nil
        wsTask?.cancel(); wsTask = nil
        lpPollTask?.cancel(); lpPollTask = nil
        bootstrapTask?.cancel(); bootstrapTask = nil
        transferTask?.cancel(); transferTask = nil
        batchImportTask?.cancel(); batchImportTask = nil
        activeSyncBatchTasks.values.forEach { $0.cancel() }
        activeSyncBatchTasks = [:]
        webkitMigrateTask?.cancel(); webkitMigrateTask = nil
        let allowMarkExpired = traceHost("mark_expired")
        pendingCleanupTask = Task {
            await phoneSync.resetAll()
            await e2eeManager.reset()
            await webSocket.stop()
            await sessionClient.markExpired(persist: allowMarkExpired)
            await sqliteStore?.close()
        }
        sqliteStore = nil
        resetSessionState()
        failedDrafts = FailedDraftStore()
        signOutNotice = reason
        startQRLoginFlow()
    }

    private func resetSessionState() {
        pollState = ZaloPollState()
        conversations = []
        profile = nil
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
        selfConversationId = nil
        navigationRequest = nil
        conversationExtras = ConversationExtras()
        resetConversationActions()
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

    // MARK: - Boot & QR Flow

    private func bootSession() async {
        await syncSessionClientTrace()
        let restoredSaved = await sessionClient.loadSavedSession()
        let restoredCookie = restoredSaved ? false : await sessionClient.tryRestoreLegacyCookieSession()

        guard restoredSaved || restoredCookie else {
            EngineLog.shared.write("engine: no saved session, starting QR login")
            startQRLoginFlow()
            return
        }

        let snap = await sessionClient.currentSnapshot()
        guard let account = snap.account, !account.userId.isEmpty else {
            startQRLoginFlow()
            return
        }

        await prepareStoreAndLocalCache(for: account)
        phase = .ready

        let status = await sessionClient.sessionStatus()
        switch status {
        case .valid:
            EngineLog.shared.write("engine: session valid, syncing online")
            await sessionClient.syncProfileMe()
            let updatedSnap = await sessionClient.currentSnapshot()
            if let updatedAcc = updatedSnap.account {
                applyAccountProfile(updatedAcc)
            }
            startWebSocketLoop(endpoints: updatedSnap.wsEndpoints, zpwSek: updatedSnap.zpwSek ?? "")
            startLongPollLoop()
            startBootstrapRefresh()

        case .expired:
            EngineLog.shared.write("engine: session expired")
            handleSessionExpiredNotice("Phiên đăng nhập đã hết hạn. Vui lòng quét mã QR để đăng nhập lại.")

        case .unreachable:
            EngineLog.shared.write("engine: offline/unreachable, using SQLite cache and starting WS reconnect loop")
            startWebSocketLoop(endpoints: snap.wsEndpoints, zpwSek: snap.zpwSek ?? "")
            startLongPollLoop()
            startBootstrapRefresh()
        }
    }

    private func startQRLoginFlow() {
        qrTask?.cancel()
        recordedQRPayload = nil
        phase = .login(LoginState(step: .generating, qrPNG: nil))

        qrTask = Task { [weak self] in
            guard let self else { return }
            await self.syncSessionClientTrace()
            do {
                let ticket = try await self.sessionClient.requestQR()
                guard !Task.isCancelled else { return }
                self.recordedQRPayload = ticket.qrPayload
                self.phase = .login(LoginState(step: .waitingScan, qrPNG: ticket.pngData))

                let scanned = try await self.sessionClient.waitForQRScan(ticket) { [weak self] rotated in
                    await MainActor.run {
                        guard let self else { return }
                        self.recordedQRPayload = rotated.qrPayload
                        self.phase = .login(LoginState(step: .waitingScan, qrPNG: rotated.pngData))
                    }
                }
                guard !Task.isCancelled else { return }
                self.recordedQRPayload = scanned.activeTicket.qrPayload
                self.phase = .login(LoginState(
                    step: .waitingConfirm(name: scanned.displayName, avatar: scanned.avatar),
                    qrPNG: scanned.activeTicket.pngData
                ))

                _ = try await self.sessionClient.waitForQRConfirm(scanned.activeTicket)
                guard !Task.isCancelled else { return }
                self.recordedQRPayload = nil
                self.phase = .signingIn

                let account = try await self.sessionClient.completeLogin()
                guard !Task.isCancelled else { return }

                self.signOutNotice = nil
                await self.prepareStoreAndLocalCache(for: account)
                await self.setSessionPreference(key: "didOfferInitialSync", value: "0")
                self.phase = .ready

                let snap = await self.sessionClient.currentSnapshot()
                self.startWebSocketLoop(endpoints: snap.wsEndpoints, zpwSek: snap.zpwSek ?? "")
                self.startLongPollLoop()
                self.startBootstrapRefresh()
                await self.offerFirstLoginTransferIfNeeded(forceOffer: account.needSyncMsg == true)
            } catch is CancellationError {
                return
            } catch let err as ZaloTransportError {
                self.recordedQRPayload = nil
                if case .qrTimeout = err {
                    self.phase = .login(LoginState(step: .expired, qrPNG: nil))
                } else {
                    self.phase = .login(LoginState(step: .failed(err.errorDescription ?? "Đăng nhập thất bại."), qrPNG: nil))
                }
            } catch {
                self.recordedQRPayload = nil
                self.phase = .login(LoginState(step: .failed(error.localizedDescription), qrPNG: nil))
            }
        }
    }

    internal func applyAccountProfile(_ account: ZaloLoginAccount) {
        profile = Profile(
            userId: account.userId,
            displayName: account.displayName.isEmpty ? "Người dùng Zalo" : account.displayName,
            avatar: account.avatar.isEmpty ? nil : URL(string: account.avatar),
            phone: account.phone.isEmpty ? nil : account.phone
        )
        selfConversationId = account.send2MeId.isEmpty ? account.userId : account.send2MeId
        clientVersion = "694 (Native)"
    }

    private func prepareStoreAndLocalCache(for account: ZaloLoginAccount) async {
        applyAccountProfile(account)
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
            let selfId = selfConversationId ?? account.send2MeId
            let migResult = await ZaloWebKitMigrator.migrateBootstrapIfNeeded(
                account: account,
                selfConvId: selfId,
                into: store,
                existingAliases: preAliases,
                existingPinnedIds: prePinned
            )

            await loadLocalAccountState(from: store)

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

    internal func loadLocalAccountState(from store: ZaloSQLiteStore) async {
        // Self-heal any legacy raw Signal ciphertexts / broken E2EE sticker URLs / corrupted legacy reactions in SQLite before hydrating UI.
        if let repairedCount = try? await store.repairUndecryptedE2EEMessages(), repairedCount > 0 {
            EngineLog.shared.write("e2ee: repaired \(repairedCount) legacy ciphertext rows")
        }
        if let repairedReactCount = try? await store.repairLegacyReactions(myUid: profile?.userId ?? ""), repairedReactCount > 0 {
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
        if let myUid = profile?.userId, !myUid.isEmpty {
            let mgr = e2eeManager
            Task.detached(priority: .utility) {
                await mgr.prepare(uid: myUid, store: store)
            }
        }

        // Load identity & preference caches first so conversation hydration resolves aliases & profiles immediately.
        cachedPinnedIds = Set((try? await store.getPreferenceStrings(key: "pinnedIds")) ?? [])
        cachedArchivedIds = Set((try? await store.getPreferenceStrings(key: "archivedIds")) ?? [])
        cachedStarredIds = Set((try? await store.getPreferenceStrings(key: "starredIds")) ?? [])
        cachedUnreadMarks = Set((try? await store.getPreferenceStrings(key: "unreadMarks")) ?? [])

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

        // Rescue any misrouted 1-1 messages from legacy "g0" before deleting ghost rows.
        let ghostSelfGroupId = (selfConversationId?.isEmpty == false) ? "g\(selfConversationId!)" : ""
        let ghostIds: Set<String> = ghostSelfGroupId.isEmpty ? ["g0", "0"] : ["g0", "0", ghostSelfGroupId]
        if let g0Msgs = try? await store.messages(convId: "g0", limit: 200), !g0Msgs.isEmpty {
            let myUid = profile?.userId ?? ""
            var rescued: [StoredMessage] = []
            for var m in g0Msgs where !m.isMine && !m.senderId.isEmpty && m.senderId != "0" && m.senderId != myUid {
                let peerId = ZaloWireParser.stripUserPrefix(m.senderId)
                guard !peerId.isEmpty, peerId != "0", !ZaloWireParser.isGroupId(peerId) else { continue }
                m.convId = peerId
                if let info = lookupPersonInfo(peerId) {
                    if !info.name.isEmpty { m.senderName = info.name }
                    if !info.avatar.isEmpty { m.senderAvatar = info.avatar }
                }
                if var obj = (try? JSONSerialization.jsonObject(with: m.rawJSONData)) as? [String: Any] {
                    obj["conversationId"] = peerId
                    obj["senderName"] = m.senderName
                    obj["senderAvatar"] = m.senderAvatar
                    if let updatedRaw = try? JSONSerialization.data(withJSONObject: obj) {
                        m.rawJSONData = updatedRaw
                    }
                }
                rescued.append(m)
            }
            if !rescued.isEmpty {
                try? await store.saveMessages(rescued)
                for m in rescued {
                    let ident = lookupConversationIdentity(m.convId)
                    let conv = StoredConversation(
                        id: m.convId,
                        isGroup: false,
                        name: ident.name.isEmpty ? m.senderName : ident.name,
                        avatar: ident.avatar?.absoluteString ?? m.senderAvatar,
                        pinned: cachedPinnedIds.contains(m.convId),
                        members: 0,
                        unread: 0,
                        previewText: ZaloWireParser.previewLabel(for: m.kindTag, text: m.text),
                        previewTsMs: m.tsMs,
                        previewFromMe: false,
                        updatedAtMs: m.tsMs
                    )
                    try? await store.upsertConversation(conv)
                }
            }
        }

        if let savedConvs = try? await store.loadConversations() {
            for ghost in ghostIds where savedConvs.contains(where: { $0.id == ghost }) {
                try? await store.deleteConversation(id: ghost)
            }
            var summaries: [ConversationSummary] = savedConvs
                .filter { !ghostIds.contains($0.id) }
                .map { c in
                    let ident = lookupConversationIdentity(c.id)
                    let effectiveName: String = {
                        if !ident.name.isEmpty && ident.name != c.id { return ident.name }
                        return c.name.isEmpty ? c.id : c.name
                    }()
                    let effectiveAvatar = ident.avatar ?? (c.avatar.isEmpty ? nil : URL(string: c.avatar))
                    let effectiveMembers = ident.members > 0 ? ident.members : c.members
                    return ConversationSummary(
                        id: c.id,
                        isGroup: c.isGroup,
                        name: effectiveName,
                        avatar: effectiveAvatar,
                        pinned: cachedPinnedIds.contains(c.id) || c.pinned,
                        members: effectiveMembers,
                        unread: c.unread,
                        preview: c.previewTsMs > 0 || !c.previewText.isEmpty
                            ? ConversationSummary.Preview(
                                text: c.previewText,
                                date: c.previewTsMs > 0 ? Date(timeIntervalSince1970: Double(c.previewTsMs) / 1000) : nil,
                                fromMe: c.previewFromMe
                            )
                            : nil
                    )
                }
            sortConversations(&summaries)
            conversations = summaries
            await refreshMentionPreviews()
        }

        let hiddenIds = Set((try? await store.getPreferenceStrings(key: "hiddenIds")) ?? [])
        let hiddenHash = try? await store.getPreferenceString(key: "hiddenPinHash")
        let hiddenMD5 = try? await store.getPreferenceString(key: "hiddenPinMD5")
        cachedHiddenPinHash = (hiddenHash?.isEmpty == false) ? hiddenHash : nil
        cachedHiddenPinMD5 = (hiddenMD5?.isEmpty == false) ? hiddenMD5 : nil
        var actions = conversationActions
        actions.hiddenKnown = true
        actions.loaded = true
        actions.hiddenEnabled = true
        actions.hasHiddenPIN = (cachedHiddenPinHash != nil) || (cachedHiddenPinMD5 != nil)
        actions.hiddenIds = hiddenIds
        actions.markUnreadEnabled = true
        conversationActions = actions
        rebuildConversationFlags()

        await loadLabelsPreference(from: store)
        await loadNotificationPreferences(from: store)
        rebuildConversationExtras()
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
        if let pins = pinsResult {
            cachedPinnedIds = Set(pins)
            try? await sqliteStore?.setPreferenceStrings(key: "pinnedIds", value: Array(cachedPinnedIds))
        }
        if let archived = archivedResult {
            cachedArchivedIds = Set(archived)
            try? await sqliteStore?.setPreferenceStrings(key: "archivedIds", value: Array(cachedArchivedIds))
        }
        if let mutesBox = mutesResult {
            var map = notificationSettings.mutes
            for entry in mutesBox.array {
                let idRaw = JSONLossless.string(entry["id"])
                guard !idRaw.isEmpty else { continue }
                let typeVal = JSONLossless.int64(entry["type"]) ?? 1
                let normId = typeVal == 2 ? ZaloWireParser.groupConvId(idRaw) : ZaloWireParser.stripUserPrefix(idRaw)
                let dur = (JSONLossless.int64(entry["duration"]).map(Double.init)) ?? -1
                let start = (JSONLossless.int64(entry["startTime"]).map(Double.init)) ?? Date().timeIntervalSince1970
                map[normId] = MuteInfo(startTime: start, duration: dur)
            }
            notificationSettings.mutes = map
            await saveNotificationPreferences()
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
        defer { transportSettleTrace?() }
        var totalEvents = 0
        for _ in 0..<maxBatches {
            guard !Task.isCancelled else { break }
            do {
                let (box, nextState, more) = try await sessionClient.fetchChatFromPolling(state: pollState)
                if nextState != pollState {
                    pollState = nextState
                    await persistPollState()
                }
                let syncEvents = ZaloPhoneSync.extractMobileSyncEvents(box.dict)
                if !syncEvents.isEmpty {
                    if traceHost("mobile_sync", args: ["events": Self.serializeMobileSyncEvents(syncEvents)]) {
                        await processMobileSyncEvents(syncEvents)
                    }
                }
                await processControlEnvelope(box.dict)
                if traceHost("apply_batch", args: [
                    "cmd": 0,
                    "increment_unread": notifyIncoming,
                    "notify_incoming": notifyIncoming,
                    "payload": box.dict,
                ]) {
                    let count = await applyBatchResponse(box.dict, incrementUnread: notifyIncoming, notifyIncoming: notifyIncoming)
                    totalEvents += count
                }
                if !more { break }
            } catch let err as ZaloSessionError where err.isAuthError {
                handleSessionExpiredNotice("Phiên đăng nhập đã hết hạn hoặc bị đăng xuất.")
                break
            } catch {
                break
            }
        }
        return totalEvents
    }

    private func startLongPollLoop() {
        if !traceHost("start_long_poll") {
            return
        }
        lpPollTask?.cancel()
        lpPollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                if Task.isCancelled { break }
                _ = await self.drainChatPolling(maxBatches: 2, notifyIncoming: true)
            }
        }
    }

    internal func resolveMissingConversationNames() async {
        let missingUids = conversations.compactMap { conv -> String? in
            guard !conv.isGroup, conv.id != selfConversationId else { return nil }
            let trimmed = conv.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == conv.id || trimmed == "Người dùng Zalo" || conv.avatar == nil {
                return conv.id
            }
            return nil
        }
        guard !missingUids.isEmpty else { return }
        var profilesCacheChanged = false
        for offset in stride(from: 0, to: missingUids.count, by: 50) {
            let chunk = Array(missingUids[offset..<min(offset + 50, missingUids.count)])
            guard let box = try? await sessionClient.fetchProfiles(uids: chunk) else { continue }
            let profilesMap = ZaloWireParser.extractProfilesMap(box.dict)
            guard !profilesMap.isEmpty else { continue }
            for (uid, row) in profilesMap {
                let clean = ZaloWireParser.stripUserPrefix(uid)
                let fetchedName = ZaloWireParser.preferredName(row)
                let avt = JSONLossless.string(row["avatar"] ?? row["avt"])
                if !clean.isEmpty, (!fetchedName.isEmpty || !avt.isEmpty) {
                    cachedProfiles[clean] = ZaloWebKitMigrator.CachedProfile(name: fetchedName, avatar: avt)
                    profilesCacheChanged = true
                }
            }
            var list = conversations
            var changed = false
            for i in list.indices {
                guard !list[i].isGroup, let row = profilesMap[list[i].id] else { continue }
                let alias = cachedAliases[list[i].id]
                let fetchedName = ZaloWireParser.preferredName(row)
                let bestName = (alias?.isEmpty == false) ? alias! : fetchedName
                let avt = JSONLossless.string(row["avatar"] ?? row["avt"])
                if !bestName.isEmpty && list[i].name != bestName {
                    list[i].name = bestName
                    changed = true
                }
                if !avt.isEmpty && list[i].avatar == nil {
                    list[i].avatar = URL(string: avt)
                    changed = true
                }
            }
            if changed {
                conversations = list
            }
        }
        if profilesCacheChanged, let data = try? JSONEncoder().encode(cachedProfiles) {
            try? await sqliteStore?.setPreferenceData(key: "cachedProfiles", data: data)
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
        return await applyParsedEvents(
            events, incrementUnread: incrementUnread, notifyIncoming: notifyIncoming, persistConversations: persistConversations)
    }

    /// Applies parsed wire events: persists messages, applies reactions / recalls / deletes / typing, refreshes the
    /// conversation list and raises notifications. Shared by the JSON path (`applyBatchResponse`) and the typed path.
    @discardableResult
    internal func applyParsedEvents(
        _ events: [ParsedWireEvent],
        incrementUnread: Bool = false,
        notifyIncoming: Bool = false,
        persistConversations: Bool = true
    ) async -> Int {
        let myUid = profile?.userId ?? ""
        guard !events.isEmpty else { return 0 }

        var storedBatch: [StoredMessage] = []
        var updatedSummaries = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
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
                await applyRemoteRecall(convId: convId, msgId: msgId, cliMsgId: cliMsgId)

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

        if !latestByConv.isEmpty {
            var pollMsgs: [ChatMessage] = []
            for (convId, latest) in latestByConv {
                pollMsgs.append(latest)
                let isGrp = ZaloWireParser.isGroupId(convId)
                let info = lookupConversationIdentity(convId)
                let prevText = Self.messagePreviewLabel(latest)
                let prev = ConversationSummary.Preview(text: prevText, date: latest.date, fromMe: latest.isMine)
                let existing = updatedSummaries[convId]
                let delta = unreadDeltaByConv[convId] ?? 0
                let bestName = !info.name.isEmpty ? info.name : (!latest.isMine && !isGrp ? latest.senderName : (existing?.name ?? convId))
                let effectivePrev: ConversationSummary.Preview? = {
                    if let existingPrev = existing?.preview,
                       (existingPrev.date ?? .distantPast) > latest.date {
                        return existingPrev
                    }
                    return prev
                }()
                updatedSummaries[convId] = ConversationSummary(
                    id: convId,
                    isGroup: isGrp,
                    name: bestName.isEmpty ? convId : bestName,
                    avatar: info.avatar ?? existing?.avatar ?? (!isGrp && !latest.isMine ? latest.senderAvatar : nil),
                    pinned: cachedPinnedIds.contains(convId),
                    members: info.members > 0 ? info.members : (existing?.members ?? 0),
                    unread: (existing?.unread ?? 0) + delta,
                    preview: effectivePrev
                )
            }
            notePollMessages(pollMsgs)
        }

        var list = Array(updatedSummaries.values)
        sortConversations(&list)
        if list != conversations {
            conversations = list
        }
        if persistConversations {
            await persistConversationsToSQLite()
        }
        rebuildConversationFlags()
        rebuildConversationExtras()

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
        return events.count
    }

    internal func ensureKnownContactsInConversations() {
        var existing = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        if let selfId = selfConversationId, !selfId.isEmpty, existing[selfId] == nil {
            existing[selfId] = ConversationSummary(
                id: selfId, isGroup: false, name: "Cloud của tôi", avatar: nil,
                pinned: cachedPinnedIds.contains(selfId), members: 0, unread: 0, preview: nil
            )
        }
        for grp in contacts.groups where existing[grp.id] == nil {
            existing[grp.id] = ConversationSummary(
                id: grp.id, isGroup: true, name: grp.name, avatar: grp.avatar,
                pinned: cachedPinnedIds.contains(grp.id), members: grp.members, unread: 0, preview: nil
            )
        }
        for pinnedId in cachedPinnedIds where existing[pinnedId] == nil {
            let info = lookupConversationIdentity(pinnedId)
            existing[pinnedId] = ConversationSummary(
                id: pinnedId,
                isGroup: ZaloWireParser.isGroupId(pinnedId),
                name: info.name.isEmpty ? pinnedId : info.name,
                avatar: info.avatar,
                pinned: true,
                members: info.members,
                unread: 0,
                preview: nil
            )
        }
        let knownGroupSet = Set(contacts.groups.map(\.id))
        for (activeId, rank) in cachedActivityRanks where rank > 0 && existing[activeId] == nil {
            let isGrp = ZaloWireParser.isGroupId(activeId)
            if isGrp && !knownGroupSet.contains(activeId) && !contacts.groups.isEmpty {
                continue
            }
            let info = lookupConversationIdentity(activeId)
            existing[activeId] = ConversationSummary(
                id: activeId,
                isGroup: isGrp,
                name: info.name.isEmpty ? activeId : info.name,
                avatar: info.avatar,
                pinned: cachedPinnedIds.contains(activeId),
                members: info.members,
                unread: 0,
                preview: nil
            )
        }
        // Apply updated friend/alias/group metadata to existing entries
        for (id, var summary) in existing {
            let info = lookupConversationIdentity(id)
            if !info.name.isEmpty && summary.name != info.name {
                summary.name = info.name
            }
            if let av = info.avatar { summary.avatar = av }
            if info.members > 0 { summary.members = info.members }
            summary.pinned = cachedPinnedIds.contains(id)
            existing[id] = summary
        }
        var list = Array(existing.values)
        sortConversations(&list)
        if list != conversations {
            conversations = list
        }
    }

    private func startWebSocketLoop(endpoints: [String], zpwSek: String) {
        wsTask?.cancel()
        guard !zpwSek.isEmpty else { return }
        if !traceHost("start_ws", args: ["endpoints": endpoints]) {
            return
        }
        wsTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.webSocket.start(
                endpoints: endpoints, zpwSek: zpwSek, myUid: self.profile?.userId, selfConvId: self.selfConversationId)
            let authWatchTask = Task { [weak self] in
                guard let self else { return }
                var wasAuthed = false
                while !Task.isCancelled {
                    let nowAuthed = await self.webSocket.isAuthed
                    if wasAuthed && !nowAuthed {
                        if self.traceHost("e2ee_disconnected") {
                            await self.e2eeManager.markDisconnected()
                        }
                        self.transportSettleTrace?()
                    }
                    if !wasAuthed && nowAuthed, let uid = self.profile?.userId, !uid.isEmpty {
                        if self.traceHost("e2ee_connected", args: ["uid": uid]) {
                            await self.e2eeManager.syncBundleWithServerIfNeeded(
                                uid: uid,
                                webSocket: self.webSocket,
                                store: self.sqliteStore
                            )
                            await self.e2eeManager.fetchE2EEPeerList(
                                webSocket: self.webSocket,
                                store: self.sqliteStore,
                                myUid: uid
                            )
                        }
                        self.transportSettleTrace?()
                    }
                    wasAuthed = nowAuthed
                    try? await Task.sleep(for: .milliseconds(nowAuthed ? 500 : 250))
                }
            }
            defer { authWatchTask.cancel() }
            for await event in stream {
                if Task.isCancelled { break }
                if let updated = event.cursorsChanged {
                    await self.persistWSQueueCursors(updated)
                    self.transportSettleTrace?()
                    continue
                }
                await self.handleWSEvent(event)
            }
        }
    }

    private func handleWSEvent(_ event: ZaloWSEvent) async {
        defer { transportSettleTrace?() }
        if let typed = event.typed {
            await handleTypedChatEvent(event, typed)
            return
        }
        let payload = event.payload

        // Duplicate login / kicked check
        if let errorCode = JSONLossless.int64(payload["error_code"]), errorCode == 600 || errorCode == -102 {
            handleSessionExpiredNotice("Tài khoản đã đăng xuất hoặc đăng nhập trên thiết bị khác.")
            return
        }

        if event.cmd == ZaloWebSocket.cmdAuthen {
            return
        }

        if event.cmd == ZaloE2EEManager.cmdInitSession
            || event.cmd == ZaloE2EEManager.cmdSessionOffline
            || event.cmd == ZaloE2EEManager.cmdRequestPreKeys {
            if let uid = profile?.userId, !uid.isEmpty {
                if traceHost("e2ee_signal", args: ["cmd": Int(event.cmd), "payload": payload]) {
                    await e2eeManager.handleSignalSocketEvent(
                        cmd: event.cmd,
                        payload: ZaloJSONBox(payload),
                        uid: uid,
                        webSocket: webSocket,
                        store: sqliteStore
                    )
                }
            }
            return
        }

        if event.cmd == ZaloE2EEManager.cmdDeliverSeenOneOne {
            if traceHost("e2ee_deliver_reports", args: ["cmd": Int(event.cmd), "payload": payload]) {
                let resends = await e2eeManager.handleDeliverReports(cmd: event.cmd, payload: ZaloJSONBox(payload), webSocket: webSocket)
                for request in resends { await resendE2EEMessage(request) }
            }
            return
        }

        if event.cmd == ZaloWebSocket.cmdSyncRequest || event.cmd == ZaloWebSocket.cmdSyncMobileWakeUp {
            let code = JSONLossless.int64(payload["error_code"]) ?? 0
            EngineLog.shared.write("sync-ws: ack cmd=\(event.cmd) code=\(code)")
        }

        let mobileSyncEvents = ZaloPhoneSync.extractMobileSyncEvents(payload)
        if !mobileSyncEvents.isEmpty {
            if traceHost("mobile_sync", args: ["events": Self.serializeMobileSyncEvents(mobileSyncEvents)]) {
                await processMobileSyncEvents(mobileSyncEvents)
            }
        }

        // Control action events (typing, mute, voip, etc.)
        await processControlEnvelope(payload, cmd: event.cmd)

        // Extract chat message arrays & reactions from push/pull envelopes (only notify banners on live push 501/521/551/552)
        let isLivePush = (
            event.cmd == ZaloWebSocket.cmdPushMsg11
            || event.cmd == ZaloWebSocket.cmdPushMsgGroup
            || event.cmd == ZaloE2EEManager.cmdReceiveOneOne
            || event.cmd == ZaloE2EEManager.cmdReceiveGroup
        )
        if traceHost("apply_batch", args: [
            "cmd": Int(event.cmd),
            "increment_unread": isLivePush,
            "notify_incoming": isLivePush,
            "payload": payload,
        ]) {
            _ = await applyBatchResponse(payload, defaultCmd: event.cmd, incrementUnread: isLivePush, notifyIncoming: isLivePush)
        }
    }

    /// Rust-core hot path: a plain chat envelope arrives parsed. The core guarantees nothing else in it needs the JSON
    /// (no error code, E2EE cipher, control or sync item), so only name resolution and the batch apply remain.
    private func handleTypedChatEvent(_ event: ZaloWSEvent, _ typed: ZaloWSTypedChat) async {
        let myUid = profile?.userId ?? ""
        var names: [NameEntry] = []
        for uid in typed.uids {
            if let hit = lookupPersonInfo(uid) { names.append(NameEntry(uid: uid, name: hit.name, avatar: hit.avatar)) }
        }
        let selfConv = selfConversationId
        let payload = typed.payload
        var events = typed.events
        // nil = the core parsed with exactly this uid and these names; otherwise re-parse with them (off the MainActor).
        if let fresh = await Task.detached(priority: .userInitiated, operation: {
            payload.resolve(myUid: myUid, selfConvId: selfConv, names: names).map { ZaloWireParser.parsedEvents(from: $0) }
        }).value {
            events = fresh
        }
        let isLivePush = (
            event.cmd == ZaloWebSocket.cmdPushMsg11
            || event.cmd == ZaloWebSocket.cmdPushMsgGroup
        )
        if traceHost("apply_parsed_events", args: [
            "cmd": Int(event.cmd),
            "increment_unread": isLivePush,
            "notify_incoming": isLivePush,
            "events": Self.serializeParsedWireEvents(events),
        ]) {
            _ = await applyParsedEvents(events, incrementUnread: isLivePush, notifyIncoming: isLivePush)
        }
    }

    internal func processControlEnvelope(_ payload: [String: Any], cmd: UInt16 = 0) async {
        for done in ZaloWebSocket.extractFileDoneEvents(payload) {
            await webSocket.recordFileDone(fileId: done.fileId, url: done.url)
        }
        let dataNode = payload["data"] as? [String: Any] ?? payload
        let myUid = profile?.userId ?? ""

        var controlItems: [[String: Any]] = []
        if let controls = dataNode["controls"] as? [[String: Any]] { controlItems.append(contentsOf: controls) }
        if let actions = dataNode["actions"] as? [[String: Any]] { controlItems.append(contentsOf: actions) }
        if let dataArr = payload["data"] as? [[String: Any]] {
            for item in dataArr {
                if let sub = item["controls"] as? [[String: Any]] {
                    controlItems.append(contentsOf: sub)
                } else {
                    controlItems.append(item)
                }
            }
        }
        if controlItems.isEmpty,
           cmd == ZaloWebSocket.cmdCtrlPullVoip || JSONLossless.string(dataNode["act_type"]) == "voip" {
            controlItems.append(dataNode)
        }

        if payload["encrypt"] != nil {
            // The frame body was not decoded (the envelope came through). Shapes only, never ids or bodies.
            EngineLog.shared.write("ctrl: undecoded cmd=\(cmd) encrypt=\(JSONLossless.int64(payload["encrypt"]) ?? -1) data=\(payload["data"] is String ? "string" : "other")")
        }

        for ctrl in controlItems {
            let contentObj: [String: Any] = {
                if let c = ctrl["content"] as? [String: Any] { return c }
                if let s = ctrl["content"] as? String, let d = s.data(using: .utf8), let p = JSONLossless.parseObject(d) { return p }
                return ctrl
            }()
            let actType = JSONLossless.string(contentObj["act_type"] ?? ctrl["act_type"])
            let act = JSONLossless.string(contentObj["act"] ?? ctrl["act"] ?? ctrl["action"])
            let actData: [String: Any] = {
                if let d = contentObj["data"] as? [String: Any] { return d }
                if let s = contentObj["data"] as? String {
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    let wrapped = (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")) ? trimmed : "{\(trimmed)}"
                    if let d = wrapped.data(using: .utf8), let p = JSONLossless.parseObject(d) {
                        return p
                    }
                }
                return contentObj
            }()

            if actType == "voip" || cmd == ZaloWebSocket.cmdCtrlPullVoip {
                let rawDataValue: Any = contentObj["data"] ?? actData
                if traceHost("voip_control", args: ["act": act, "raw_data": rawDataValue, "data": actData]) {
                    await handleVoipControlEvent(act: act, rawDataValue: rawDataValue, parsedData: actData)
                }
            } else if actType == "typing" || act == "typing" || act == "gtyping" {
                let uid = ZaloWireParser.stripUserPrefix(JSONLossless.string(actData["uid"] ?? actData["uidFrom"]))
                let gid = JSONLossless.string(actData["gid"] ?? actData["grid"])
                let convId = (!gid.isEmpty || act == "gtyping") ? ZaloWireParser.groupConvId(gid.isEmpty ? uid : gid) : uid
                // Shapes only, once per distinct shape: key names and the isPC flag, never ids.
                let shape = "\(act) keys=\(actData.keys.sorted().joined(separator: ",")) isPC=\(actData["isPC"].map { "\($0)" } ?? "nil")"
                if Self.loggedTypingShapes.insert(shape).inserted { EngineLog.shared.write("typing: shape \(shape)") }
                if !convId.isEmpty, uid != myUid {
                    let onPC = JSONLossless.int64(actData["isPC"]) == 1
                    if traceHost("show_typing", args: ["conv_id": convId, "uid": uid, "on_pc": onPC]) {
                        let name = lookupPersonInfo(uid)?.name ?? "Ai đó"
                        showTyping(convId: convId, name: name, onPC: onPC)
                    }
                }
            } else if case let pinConvs = ZaloWireParser.pinTopicEventConversations(actType: actType, act: act, data: actData), !pinConvs.isEmpty {
                for pinConv in pinConvs {
                    if traceHost("pin_topic", args: ["conv_id": pinConv]) {
                        handlePinTopicEvent(conversationId: pinConv)
                    }
                }
            } else if actType == "group", ZaloWireParser.groupEventNoticeActs.contains(act) {
                let ts = JSONLossless.int64(ctrl["ts"] ?? contentObj["ts"] ?? actData["ts"]) ?? 0
                if traceHost("group_notice", args: ["act": act, "data": actData, "ts": ts]) {
                    await handleGroupEventNotice(act: act, data: actData, ts: ts)
                }
            } else if actType == "mute" {
                let rawId = JSONLossless.string(actData["toId"] ?? actData["toid"] ?? actData["id"])
                let muteType = JSONLossless.int64(actData["muteType"]) ?? 1
                let isGrp = muteType == 2 || ZaloWireParser.isGroupId(rawId)
                let convId = isGrp ? ZaloWireParser.groupConvId(rawId) : ZaloWireParser.stripUserPrefix(rawId)
                let duration = JSONLossless.int64(actData["duration"]) ?? -1
                let muteMode = JSONLossless.int64(actData["muteMode"]) ?? 1
                let explicitStart = JSONLossless.int64(actData["startTime"] ?? actData["systemTime"])
                let start = explicitStart ?? Int64(Date().timeIntervalSince1970)
                let isSet = (act == "set" || (act != "unset" && JSONLossless.int64(actData["action"]) == 1))
                    && muteMode == 1 && duration != 0
                if !convId.isEmpty {
                    let startArg: Any = (explicitStart == nil && hostTrace != nil) ? "<volatile>" : start
                    if traceHost("mute", args: ["conv_id": convId, "set": isSet, "start": startArg, "duration": duration]) {
                        if isSet {
                            notificationSettings.mutes[convId] = MuteInfo(startTime: Double(start), duration: Double(duration))
                        } else {
                            notificationSettings.mutes.removeValue(forKey: convId)
                        }
                        await saveNotificationPreferences()
                    }
                }
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
        guard let store = sqliteStore else { return }
        for conv in conversations where conv.isGroup && (conv.preview?.text.contains("@") ?? false) {
            guard let latest = (try? await store.decodedMessages(convId: conv.id, limit: 1))?.last?.message,
                  !latest.mentions.isEmpty,
                  let idx = conversations.firstIndex(where: { $0.id == conv.id }),
                  let preview = conversations[idx].preview,
                  preview.text == Self.messagePreviewLabel(latest) else { continue }
            let text = conversationPreviewText(latest)
            guard text != preview.text else { continue }
            conversations[idx].preview?.text = text
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
        var list = conversations
        let isGrp = ZaloWireParser.isGroupId(msg.conversationId)
        let preview = ConversationSummary.Preview(
            text: conversationPreviewText(msg),
            date: msg.date,
            fromMe: msg.isMine
        )
        if let idx = list.firstIndex(where: { $0.id == msg.conversationId }) {
            var item = list[idx]
            if (item.preview?.date ?? .distantPast) <= msg.date {
                item.preview = preview
            }
            if incrementUnread {
                item.unread += 1
            }
            // Nothing changed (re-merged history, an open without new messages): leave the list, its order and the store alone,
            // so the conversation list is not re-diffed for nothing.
            if item == list[idx] { return }
            list[idx] = item
        } else {
            let identity = lookupConversationIdentity(msg.conversationId)
            list.append(ConversationSummary(
                id: msg.conversationId,
                isGroup: isGrp,
                name: identity.name.isEmpty ? msg.senderName : identity.name,
                avatar: identity.avatar ?? msg.senderAvatar,
                pinned: cachedPinnedIds.contains(msg.conversationId),
                members: identity.members,
                unread: incrementUnread ? 1 : 0,
                preview: preview
            ))
        }
        sortConversations(&list)
        conversations = list
        rebuildConversationFlags()
        rebuildConversationExtras()
        Task { await persistConversationsToSQLite() }
    }

    internal func sortConversations(_ list: inout [ConversationSummary]) {
        list.sort { a, b in
            if a.pinned != b.pinned { return a.pinned }
            let ad = a.preview?.date ?? .distantPast
            let bd = b.preview?.date ?? .distantPast
            if ad != bd { return ad > bd }
            let ra = cachedActivityRanks[a.id] ?? 0
            let rb = cachedActivityRanks[b.id] ?? 0
            if ra != rb { return ra > rb }
            return a.id < b.id
        }
    }

    internal func persistConversationsToSQLite() async {
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

    internal func applyRemoteRecall(convId: String, msgId: String, cliMsgId: String) async {
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

            if wasLast, let convIdx = conversations.firstIndex(where: { $0.id == convId }) {
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

        if !updatedPreview,
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
        let targetId = !msgId.isEmpty ? msgId : cliMsgId
        guard !targetId.isEmpty else { return }
        if var list = messages[convId] {
            list.removeAll { $0.id == targetId || $0.id == cliMsgId }
            messages[convId] = list
        }
        try? await sqliteStore?.deleteMessage(convId: convId, id: targetId)
    }

    nonisolated static func listOrder(_ conversations: [ConversationSummary]) -> [ConversationSummary] {
        conversations.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            let ad = a.preview?.date ?? .distantPast
            let bd = b.preview?.date ?? .distantPast
            if ad != bd { return ad > bd }
            return a.id < b.id
        }
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
