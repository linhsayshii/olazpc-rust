import AppKit
import Foundation
import Observation
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
    var conversations: [ConversationSummary] = []
    private(set) var profile: Profile?
    private(set) var signOutNotice: String?
    private(set) var clientVersion: String? = "694 (Native)"
    private(set) var recentLog: [String] = []

    var openConversationId: String?
    var failedDrafts = FailedDraftStore()
    var messages: [String: [ChatMessage]] = [:]
    var hasMoreHistory: [String: Bool] = [:]
    var historyTicks: [String: Int] = [:]
    var typing: [String: String] = [:]
    var transfer: MessageTransferState?
    var canStartTransfer = false
    var transferStartBlockedReason: String?

    var selfConversationId: String?
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
    @ObservationIgnored private var qrTask: Task<Void, Never>?
    @ObservationIgnored private var wsTask: Task<Void, Never>?
    @ObservationIgnored private var lpPollTask: Task<Void, Never>?
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
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
    @ObservationIgnored private var pollState = ZaloPollState()
    @ObservationIgnored internal var typingResetTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored internal var pendingDeletedMessages: [String: ChatMessage] = [:]
    @ObservationIgnored internal var groupMemberCache: [String: [MentionCandidate]] = [:]
    @ObservationIgnored internal var cachedSentRequestsRaw: [[String: Any]] = []
    @ObservationIgnored internal var cachedReceivedRequestsRaw: [[String: Any]] = []
    @ObservationIgnored internal var cachedGroupDetails: [String: [String: Any]] = [:]
    @ObservationIgnored internal var cachedFriendGlobalIds: [String: String] = [:]
    @ObservationIgnored internal var cachedPinnedIds: Set<String> = []
    @ObservationIgnored internal var cachedArchivedIds: Set<String> = []
    @ObservationIgnored internal var cachedStarredIds: Set<String> = []
    @ObservationIgnored internal var cachedUnreadMarks: Set<String> = []
    @ObservationIgnored internal var cachedAliases: [String: String] = [:]
    @ObservationIgnored internal var cachedProfiles: [String: ZaloWebKitMigrator.CachedProfile] = [:]
    @ObservationIgnored internal var cachedGroups: [String: ZaloWebKitMigrator.CachedGroup] = [:]
    @ObservationIgnored internal var cachedActivityRanks: [String: Int64] = [:]
    @ObservationIgnored internal var cachedBoardRawTopics: [String: (version: Int64, topics: [String: [String: Any]])] = [:]
    @ObservationIgnored private var webkitMigrateTask: Task<Void, Never>?

    /// Kept for menu toggle binding compatibility; native engine has no hidden WebKit window.
    var isDebugRendererVisible = false
    /// Remembers user-saved `~/Downloads` destinations keyed by message/file key so file cards reflect saved state across scroll.
    var downloadedFilePaths: [String: URL] = [:]

    /// Strictly side-effect-free initializer so unit tests and previews instantiate safely.
    init(dataDirectory: URL = ZaloPlatform.defaultUserData, useKeychain: Bool = true) {
        self.dataDirectory = dataDirectory
        self.sessionClient = ZaloSessionClient(dataDirectory: dataDirectory, useKeychain: useKeychain)
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
        EngineLog.shared.write("engine: start pure Swift native runtime (zpw_ver=\(ZaloDomains.zpwVer))")
        NativeNotifier.shared.attach(engine: self)
        ZaloRuntime.prepareForLaunch()
        call.helperInstalled = CallBridge.isHelperInstalled()
        call.rendererReady = true
        call.supported = call.helperInstalled
        call.videoSupported = call.helperInstalled

        Task { [weak self] in
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
        Task {
            await phoneSync.resetAll()
            await e2eeManager.reset()
            await webSocket.stop()
            await sessionClient.clearSession()
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
        Task {
            await phoneSync.resetAll()
            await e2eeManager.reset()
            await webSocket.stop()
            await sessionClient.markExpired()
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
        groupMemberCache = [:]
        cachedSentRequestsRaw = []
        cachedReceivedRequestsRaw = []
        cachedGroupDetails = [:]
        cachedFriendGlobalIds = [:]
        phoneSyncConvTimestamps = [:]
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
        phase = .login(LoginState(step: .generating, qrPNG: nil))

        qrTask = Task { [weak self] in
            guard let self else { return }
            do {
                let ticket = try await self.sessionClient.requestQR()
                guard !Task.isCancelled else { return }
                self.phase = .login(LoginState(step: .waitingScan, qrPNG: ticket.pngData))

                let scanned = try await self.sessionClient.waitForQRScan(ticket) { [weak self] rotated in
                    await MainActor.run {
                        guard let self else { return }
                        self.phase = .login(LoginState(step: .waitingScan, qrPNG: rotated.pngData))
                    }
                }
                guard !Task.isCancelled else { return }
                self.phase = .login(LoginState(
                    step: .waitingConfirm(name: scanned.displayName, avatar: scanned.avatar),
                    qrPNG: scanned.activeTicket.pngData
                ))

                _ = try await self.sessionClient.waitForQRConfirm(scanned.activeTicket)
                guard !Task.isCancelled else { return }
                self.phase = .signingIn

                let account = try await self.sessionClient.completeLogin()
                guard !Task.isCancelled else { return }

                self.signOutNotice = nil
                await self.prepareStoreAndLocalCache(for: account)
                try? await self.sqliteStore?.setPreferenceString(key: "didOfferInitialSync", value: "0")
                self.phase = .ready

                let snap = await self.sessionClient.currentSnapshot()
                self.startWebSocketLoop(endpoints: snap.wsEndpoints, zpwSek: snap.zpwSek ?? "")
                self.startLongPollLoop()
                self.startBootstrapRefresh()
                await self.offerFirstLoginTransferIfNeeded(forceOffer: account.needSyncMsg == true)
            } catch is CancellationError {
                return
            } catch let err as ZaloTransportError {
                if case .qrTimeout = err {
                    self.phase = .login(LoginState(step: .expired, qrPNG: nil))
                } else {
                    self.phase = .login(LoginState(step: .failed(err.errorDescription ?? "Đăng nhập thất bại."), qrPNG: nil))
                }
            } catch {
                self.phase = .login(LoginState(step: .failed(error.localizedDescription), qrPNG: nil))
            }
        }
    }

    private func applyAccountProfile(_ account: ZaloLoginAccount) {
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

    private func loadLocalAccountState(from store: ZaloSQLiteStore) async {
        // Self-heal any legacy raw Signal ciphertexts / broken E2EE sticker URLs in SQLite before hydrating UI.
        if let repairedCount = try? await store.repairUndecryptedE2EEMessages(), repairedCount > 0 {
            EngineLog.shared.write("e2ee: repaired \(repairedCount) legacy ciphertext rows")
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
        }

        let hiddenIds = Set((try? await store.getPreferenceStrings(key: "hiddenIds")) ?? [])
        let hiddenHash = try? await store.getPreferenceString(key: "hiddenPinHash")
        var actions = conversationActions
        actions.hiddenKnown = true
        actions.loaded = true
        actions.hiddenEnabled = true
        actions.hasHiddenPIN = (hiddenHash?.isEmpty == false)
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
        if let pins = try? await sessionClient.fetchPinnedConversations() {
            cachedPinnedIds = Set(pins)
            try? await sqliteStore?.setPreferenceStrings(key: "pinnedIds", value: Array(cachedPinnedIds))
        }
        if let archived = try? await sessionClient.fetchArchivedChats() {
            cachedArchivedIds = Set(archived)
            try? await sqliteStore?.setPreferenceStrings(key: "archivedIds", value: Array(cachedArchivedIds))
        }
        if let mutesBox = try? await sessionClient.fetchMuteList() {
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
        await performContactsSync()
        ensureKnownContactsInConversations()
        rebuildConversationFlags()
        rebuildConversationExtras()

        // 2. Drain HTTP long-polling queue (queued recent 1-1 & group messages)
        await drainChatPolling(maxBatches: 4, notifyIncoming: false)

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
            _ = await applyBatchResponse(preloadBox.dict, incrementUnread: false, persistConversations: false)
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
                _ = await applyBatchResponse(chunkBox.dict, incrementUnread: false, persistConversations: false)
            }
        }

        // 4. Fetch recent cloud history for "Cloud của tôi" and active groups concurrently (`/api/cm/getrecentv2`)
        if let selfId = selfConversationId, !selfId.isEmpty,
           let selfHist = try? await sessionClient.fetchHistory(convId: selfId, lastMsgId: nil, count: 50, isOld: false) {
            _ = await applyBatchResponse(
                selfHist.dict,
                fallbackConvId: selfId,
                isGroupHint: false,
                incrementUnread: false,
                persistConversations: false
            )
        }

        let initialGroupIds = Array(orderedGroups.prefix(24))
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
        EngineLog.shared.write("bootstrap: convs=\(conversations.count) friends=\(contacts.friends.count) groups=\(contacts.groups.count)")
    }

    @discardableResult
    internal func drainChatPolling(maxBatches: Int = 3, notifyIncoming: Bool = false) async -> Int {
        var totalEvents = 0
        for _ in 0..<maxBatches {
            guard !Task.isCancelled else { break }
            do {
                let (box, nextState, more) = try await sessionClient.fetchChatFromPolling(state: pollState)
                pollState = nextState
                let syncEvents = ZaloPhoneSync.extractMobileSyncEvents(box.dict)
                if !syncEvents.isEmpty {
                    await processMobileSyncEvents(syncEvents)
                }
                await processControlEnvelope(box.dict)
                let count = await applyBatchResponse(box.dict, incrementUnread: notifyIncoming, notifyIncoming: notifyIncoming)
                totalEvents += count
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
                let fetchedName = JSONLossless.string(row["displayName"] ?? row["dName"] ?? row["zaloName"] ?? row["name"])
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
                let fetchedName = JSONLossless.string(row["displayName"] ?? row["dName"] ?? row["zaloName"] ?? row["name"])
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
        persistConversations: Bool = true
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
        let events = ZaloWireParser.extractBatchEvents(
            effectiveRoot,
            myUid: myUid,
            selfConvId: selfConversationId,
            defaultCmd: defaultCmd,
            fallbackConvId: fallbackConvId,
            isGroupHint: isGroupHint,
            nameLookup: { [weak self] uid in self?.lookupPersonInfo(uid) }
        )
        guard !events.isEmpty else { return 0 }

        var storedBatch: [StoredMessage] = []
        var updatedSummaries = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        var unreadDeltaByConv: [String: Int] = [:]
        var latestByConv: [String: ChatMessage] = [:]
        var incomingForNotice: [ChatMessage] = []

        for ev in events {
            switch ev {
            case .message(let msg, let stored):
                let isLockedE2EE = (stored.status == "e2ee_locked")
                if isLockedE2EE,
                   let memList = messages[msg.conversationId],
                   memList.contains(where: { existing in
                       guard existing.id == msg.id || (!stored.clientId.isEmpty && existing.id == stored.clientId) else {
                           return false
                       }
                       if case .placeholder = existing.kind, existing.isE2EE { return false }
                       return true
                   }) {
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

            case .reaction(let convId, let msgId, let cliMsgId, let senderId, let rType, let rIcon):
                await applyRemoteReaction(convId: convId, msgId: msgId, cliMsgId: cliMsgId, senderId: senderId, rType: rType, rIcon: rIcon)

            case .undo(let convId, let msgId, let cliMsgId):
                await applyRemoteRecall(convId: convId, msgId: msgId, cliMsgId: cliMsgId)

            case .delete(let convId, let msgId, let cliMsgId):
                await applyRemoteDelete(convId: convId, msgId: msgId, cliMsgId: cliMsgId)

            case .typing(let convId, let senderId, _):
                if senderId != myUid {
                    showTyping(convId: convId, name: lookupPersonInfo(senderId)?.name ?? "Ai đó")
                }

            case .ignore:
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
        if !storedBatch.isEmpty {
            try? await sqliteStore?.saveMessages(storedBatch)
        }
        if persistConversations {
            await persistConversationsToSQLite()
        }
        rebuildConversationFlags()
        rebuildConversationExtras()

        if notifyIncoming {
            for msg in incomingForNotice where !isConversationMuted(msg.conversationId) && notificationSettings.enabled {
                let title = conversations.first(where: { $0.id == msg.conversationId })?.displayName ?? msg.senderName
                let body = notificationSettings.showsPreview ? msg.text : "Bạn có tin nhắn mới"
                NativeNotifier.shared.notifyIncomingMessage(
                    title: title,
                    body: body,
                    conversationId: msg.conversationId,
                    avatarURL: msg.senderAvatar,
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
        wsTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.webSocket.start(endpoints: endpoints, zpwSek: zpwSek)
            Task { [weak self] in
                guard let self else { return }
                let deadline = Date().addingTimeInterval(12)
                while !(await self.webSocket.isAuthed) && Date() < deadline && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                if await self.webSocket.isAuthed, let uid = self.profile?.userId, !uid.isEmpty {
                    await self.e2eeManager.syncBundleWithServerIfNeeded(
                        uid: uid,
                        webSocket: self.webSocket,
                        store: self.sqliteStore
                    )
                }
            }
            for await event in stream {
                if Task.isCancelled { break }
                await self.handleWSEvent(event)
            }
        }
    }

    private func handleWSEvent(_ event: ZaloWSEvent) async {
        let payload = event.payload

        // Duplicate login / kicked check
        if let errorCode = JSONLossless.int64(payload["error_code"]), errorCode == 600 || errorCode == -102 {
            handleSessionExpiredNotice("Tài khoản đã đăng xuất hoặc đăng nhập trên thiết bị khác.")
            return
        }

        if event.cmd == ZaloE2EEManager.cmdInitSession
            || event.cmd == ZaloE2EEManager.cmdSessionOffline
            || event.cmd == ZaloE2EEManager.cmdRequestPreKeys {
            if let uid = profile?.userId, !uid.isEmpty {
                await e2eeManager.handleSignalSocketEvent(
                    cmd: event.cmd,
                    payload: ZaloJSONBox(payload),
                    uid: uid,
                    webSocket: webSocket,
                    store: sqliteStore
                )
            }
            return
        }

        if event.cmd == ZaloWebSocket.cmdSyncRequest || event.cmd == ZaloWebSocket.cmdSyncMobileWakeUp {
            let code = JSONLossless.int64(payload["error_code"]) ?? 0
            EngineLog.shared.write("sync-ws: ack cmd=\(event.cmd) code=\(code)")
        }

        let mobileSyncEvents = ZaloPhoneSync.extractMobileSyncEvents(payload)
        if !mobileSyncEvents.isEmpty {
            await processMobileSyncEvents(mobileSyncEvents)
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
        _ = await applyBatchResponse(payload, defaultCmd: event.cmd, incrementUnread: isLivePush, notifyIncoming: isLivePush)
    }

    internal func processControlEnvelope(_ payload: [String: Any], cmd: UInt16 = 0) async {
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
                await handleVoipControlEvent(act: act, rawDataValue: contentObj["data"] ?? actData, parsedData: actData)
            } else if actType == "typing" || act == "typing" || act == "gtyping" {
                let uid = ZaloWireParser.stripUserPrefix(JSONLossless.string(actData["uid"] ?? actData["uidFrom"]))
                let gid = JSONLossless.string(actData["gid"] ?? actData["grid"])
                let convId = (!gid.isEmpty || act == "gtyping") ? ZaloWireParser.groupConvId(gid.isEmpty ? uid : gid) : uid
                if !convId.isEmpty, uid != myUid {
                    let name = lookupPersonInfo(uid)?.name ?? "Ai đó"
                    showTyping(convId: convId, name: name)
                }
            } else if actType == "mute" {
                let rawId = JSONLossless.string(actData["toId"] ?? actData["toid"] ?? actData["id"])
                let muteType = JSONLossless.int64(actData["muteType"]) ?? 1
                let isGrp = muteType == 2 || ZaloWireParser.isGroupId(rawId)
                let convId = isGrp ? ZaloWireParser.groupConvId(rawId) : ZaloWireParser.stripUserPrefix(rawId)
                let duration = JSONLossless.int64(actData["duration"]) ?? -1
                let muteMode = JSONLossless.int64(actData["muteMode"]) ?? 1
                let start = JSONLossless.int64(actData["startTime"] ?? actData["systemTime"]) ?? Int64(Date().timeIntervalSince1970)
                let isSet = (act == "set" || (act != "unset" && JSONLossless.int64(actData["action"]) == 1))
                    && muteMode == 1 && duration != 0
                if !convId.isEmpty {
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

    // MARK: - Shared Helpers for Extensions

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
        if clean == profile?.userId {
            return ("Bạn", profile?.avatar?.absoluteString ?? "")
        }
        let alias = cachedAliases[clean]
        if let f = contacts.friends.first(where: { $0.id == clean }) {
            let avt = f.avatar?.absoluteString ?? cachedProfiles[clean]?.avatar ?? ""
            return (alias?.isEmpty == false ? alias! : f.name, avt)
        }
        if let p = cachedProfiles[clean] {
            let best = (alias?.isEmpty == false) ? alias! : p.name
            if !best.isEmpty || !p.avatar.isEmpty {
                return (best, p.avatar)
            }
        }
        if let alias, !alias.isEmpty {
            return (alias, "")
        }
        if let conv = conversations.first(where: { $0.id == clean }) {
            return (conv.displayName, conv.avatar?.absoluteString ?? "")
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

    internal func mergeMessageIntoMemory(_ rawMsg: ChatMessage, replacingClientId clientId: String? = nil) {
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
        var list = messages[msg.conversationId] ?? []
        let incomingIsLockedPlaceholder: Bool = {
            if case .placeholder = msg.kind, msg.isE2EE { return true }
            return false
        }()
        if let clientId, !clientId.isEmpty, clientId != msg.id {
            if incomingIsLockedPlaceholder {
                if list.contains(where: { existing in
                    guard existing.id == clientId else { return false }
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
            if incomingIsLockedPlaceholder {
                if case .placeholder = list[idx].kind, list[idx].isE2EE {
                    list[idx] = msg
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
            text: Self.messagePreviewLabel(msg),
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

    internal func showTyping(convId: String, name: String) {
        typing[convId] = name
        typingResetTasks[convId]?.cancel()
        typingResetTasks[convId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.typing[convId] = nil
            self?.typingResetTasks[convId] = nil
        }
    }

    internal func applyRemoteReaction(convId: String, msgId: String, cliMsgId: String, senderId: String, rType: String, rIcon: String) async {
        let targetId = !msgId.isEmpty ? msgId : cliMsgId
        guard !targetId.isEmpty else { return }
        let myUid = profile?.userId ?? ""
        let isMe = senderId == myUid || senderId == "0"
        let senderName = isMe ? "Bạn" : (lookupPersonInfo(senderId)?.name ?? ReactionDetail.unknownName)

        var list = messages[convId] ?? []
        guard let idx = list.firstIndex(where: { $0.id == targetId || $0.id == cliMsgId }) else { return }
        var msg = list[idx]

        if rType == "-1" {
            msg.reactions = msg.reactions.compactMap { r in
                var updated = r
                if isMe && updated.includesMe {
                    updated.includesMe = false
                    updated.count = max(0, updated.count - 1)
                    updated.people = max(0, updated.people - 1)
                    updated.names.removeAll { $0 == "Bạn" }
                }
                return updated.count > 0 ? updated : nil
            }
        } else {
            let icon = ZaloWireParser.reactionIcon(rType: rType, rIcon: rIcon)
            if let rIdx = msg.reactions.firstIndex(where: { $0.icon.type == icon.type }) {
                msg.reactions[rIdx].count += 1
                if isMe { msg.reactions[rIdx].includesMe = true }
                if !msg.reactions[rIdx].names.contains(senderName) {
                    msg.reactions[rIdx].names.append(senderName)
                    msg.reactions[rIdx].people = max(msg.reactions[rIdx].people, msg.reactions[rIdx].names.count)
                }
            } else {
                msg.reactions.append(ChatMessage.Reaction(
                    icon: icon,
                    count: 1,
                    includesMe: isMe,
                    names: [senderName],
                    people: 1
                ))
            }
        }
        list[idx] = msg
        messages[convId] = list
        if let stored = ZaloWireParser.encodeChatMessage(msg) {
            try? await sqliteStore?.saveMessages([stored])
        }
    }

    internal func applyRemoteRecall(convId: String, msgId: String, cliMsgId: String) async {
        let targetId = !msgId.isEmpty ? msgId : cliMsgId
        guard !targetId.isEmpty else { return }
        if var list = messages[convId], let idx = list.firstIndex(where: { $0.id == targetId || $0.id == cliMsgId }) {
            list[idx].kind = .recalled
            list[idx].text = ""
            messages[convId] = list
        }
        try? await sqliteStore?.markRecalled(convId: convId, id: targetId)
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
