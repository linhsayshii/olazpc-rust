import Foundation
import OlazCore
import os

/// Thread-safe, cancellation-safe one-shot gate backing `bootTask` / `qrTask` / `pendingCleanupTask`
/// so recorder and lifecycle waiters complete on every terminal path without leaking tasks.
internal final class CorePhaseGate: Sendable {
    private struct State: @unchecked Sendable {
        var completed = false
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func finish() {
        let pending: [CheckedContinuation<Void, Never>] = state.withLock { st in
            guard !st.completed else { return [] }
            st.completed = true
            let list = Array(st.waiters.values)
            st.waiters.removeAll()
            return list
        }
        for waiter in pending {
            waiter.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        let waiter: CheckedContinuation<Void, Never>? = state.withLock { st in
            st.waiters.removeValue(forKey: id)
        }
        waiter?.resume()
    }

    func wait() async {
        let alreadyDone = state.withLock { $0.completed }
        guard !alreadyDone else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeNow: Bool = state.withLock { st in
                    if st.completed || Task.isCancelled {
                        return true
                    }
                    st.waiters[id] = continuation
                    return false
                }
                if resumeNow {
                    continuation.resume()
                }
            }
        } onCancel: { [weak self] in
            self?.cancelWaiter(id)
        }
    }
}

/// Thread-safe holder for the `CoreEngine` handle, its `@MainActor` change-mirror task, and active
/// lifecycle gates so `ZaloEngine.deinit` (nonisolated), `stopCoreEngine()`, and change-loop exit
/// can cleanly stop the Rust actor and finish all gates without racing or leaking tasks.
final class CoreEngineLifecycle: Sendable {
    enum GateSlot {
        case boot
        case qr
        case cleanup
    }

    private struct State: @unchecked Sendable {
        var core: CoreEngine?
        var changeTask: Task<Void, Never>?
        var isShutDown = false
        var bootGate: CorePhaseGate?
        var qrGate: CorePhaseGate?
        var cleanupGate: CorePhaseGate?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var core: CoreEngine? {
        state.withLock { $0.core }
    }

    var isShutDown: Bool {
        state.withLock { $0.isShutDown }
    }

    /// Installs a freshly created `CoreEngine` and its change-stream task. Returns `false` if
    /// `shutdown()` was already called before installation completed.
    func install(core: CoreEngine, changeTask: Task<Void, Never>) -> Bool {
        state.withLock { st in
            guard !st.isShutDown else { return false }
            st.core = core
            st.changeTask = changeTask
            return true
        }
    }

    /// Replaces the gate in `slot`, finishing any previous gate. Returns `nil` if already shut down.
    func replaceGate(_ slot: GateSlot) -> CorePhaseGate? {
        let (previous, fresh): (CorePhaseGate?, CorePhaseGate?) = state.withLock { st in
            let old: CorePhaseGate?
            switch slot {
            case .boot:
                old = st.bootGate
                st.bootGate = nil
            case .qr:
                old = st.qrGate
                st.qrGate = nil
            case .cleanup:
                old = st.cleanupGate
                st.cleanupGate = nil
            }
            guard !st.isShutDown else { return (old, nil) }
            let next = CorePhaseGate()
            switch slot {
            case .boot: st.bootGate = next
            case .qr: st.qrGate = next
            case .cleanup: st.cleanupGate = next
            }
            return (old, next)
        }
        previous?.finish()
        return fresh
    }

    func hasGate(_ slot: GateSlot) -> Bool {
        state.withLock { st in
            switch slot {
            case .boot: return st.bootGate != nil
            case .qr: return st.qrGate != nil
            case .cleanup: return st.cleanupGate != nil
            }
        }
    }

    func finishGate(_ slot: GateSlot) {
        let gate: CorePhaseGate? = state.withLock { st in
            switch slot {
            case .boot:
                let g = st.bootGate
                st.bootGate = nil
                return g
            case .qr:
                let g = st.qrGate
                st.qrGate = nil
                return g
            case .cleanup:
                let g = st.cleanupGate
                st.cleanupGate = nil
                return g
            }
        }
        gate?.finish()
    }

    func finishAllGates() {
        let gates: [CorePhaseGate] = state.withLock { st in
            let list = [st.bootGate, st.qrGate, st.cleanupGate].compactMap { $0 }
            st.bootGate = nil
            st.qrGate = nil
            st.cleanupGate = nil
            return list
        }
        for gate in gates {
            gate.finish()
        }
    }

    /// Stops the Rust actor, cancels the change-mirror loop, and finishes all active gates.
    /// Safe to call from nonisolated `deinit`.
    func shutdown() {
        let (core, task, gates): (CoreEngine?, Task<Void, Never>?, [CorePhaseGate]) = state.withLock { st in
            st.isShutDown = true
            let c = st.core
            let t = st.changeTask
            let g = [st.bootGate, st.qrGate, st.cleanupGate].compactMap { $0 }
            st.core = nil
            st.changeTask = nil
            st.bootGate = nil
            st.qrGate = nil
            st.cleanupGate = nil
            return (c, t, g)
        }
        task?.cancel()
        core?.stop()
        for gate in gates {
            gate.finish()
        }
    }
}

/// Commands queued on the MainActor while `CoreEngine` completes its one-time async creation.
enum PendingCoreCommand {
    case start
    case refreshQr
    case logOut
    case sessionExpired(String)
}

/// Bridges `olaz-core` host effects onto `ZaloEngine` and `ZaloSessionClient` (ADR-016).
///
/// Every method is called serially in emitted order by `olaz-core`'s host worker; never invoked
/// concurrently. Credential snapshots (`persistSession`, `markExpired`) are never logged.
final class ZaloEngineCoreHost: CoreHost, @unchecked Sendable {
    private weak var engine: ZaloEngine?

    init(engine: ZaloEngine) {
        self.engine = engine
    }

    func loadSavedSession() async -> String? {
        guard let engine else { return nil }
        return await engine.sessionClient.readSavedSessionSnapshotJSON()
    }

    func loadLegacyCookie() async -> LegacyCookieRecord? {
        guard let engine else { return nil }
        return await engine.sessionClient.readLegacyCookie()
    }

    func setPref(key: String, value: String) async {
        guard let engine else { return }
        await engine.waitForCoreMirrorDrain()
        await engine.setSessionPreference(key: key, value: value)
    }

    func prepareStore(userId: String, account: LoginAccountRecord) async {
        guard let engine else { return }
        await engine.sessionClient.syncMirrorFromCoreSession()
        let swiftAccount = ZaloLoginAccount(coreRecord: account)
        await MainActor.run {
            engine.hostNotePrepareStoreStarted()
        }
        await engine.prepareStoreAndLocalCache(for: swiftAccount)
    }

    func loadTransportState() async -> PersistedTransportStateRecord {
        guard let engine else {
            return PersistedTransportStateRecord(pollState: nil, wsCursors: [])
        }
        return await engine.hostLoadTransportState()
    }

    func onWsStarted(endpoints: [String]) async -> Bool {
        guard let engine else { return false }
        await engine.sessionClient.syncMirrorFromCoreSession()
        return await MainActor.run {
            engine.traceHost("start_ws", args: ["endpoints": endpoints])
        }
    }

    func onLongPollStarted() async -> Bool {
        guard let engine else { return false }
        return await MainActor.run {
            engine.traceHost("start_long_poll")
        }
    }

    func startBootstrap() async {
        guard let engine else { return }
        await MainActor.run {
            engine.startBootstrapRefresh()
        }
        await engine.waitForCoreMirrorDrain()
        await MainActor.run {
            engine.noteCoreBootCompleted()
        }
    }

    func offerFirstLoginTransfer(force: Bool) async {
        guard let engine else { return }
        await engine.offerFirstLoginTransferIfNeeded(forceOffer: force)
        await engine.waitForCoreMirrorDrain()
        await MainActor.run {
            engine.noteCoreQRCompleted()
        }
    }

    func resetDomains() async {
        guard let engine else { return }
        let allowReset = await MainActor.run {
            engine.traceHost("reset_domains")
        }
        if allowReset {
            await engine.sessionClient.resetDomainsToDefault()
        }
        await engine.waitForCoreMirrorDrain()
        await MainActor.run {
            engine.noteCoreCleanupCompleted()
        }
    }

    func persistSession(snapshotJson: String) async {
        guard let engine else { return }
        let allowPersist = await MainActor.run {
            engine.traceHost("persist_session")
        }
        await engine.sessionClient.saveSessionFromCore(snapshotJSON: snapshotJson, writeDisk: allowPersist)
    }

    func clearSession() async {
        guard let engine else { return }
        let allowClear = await MainActor.run {
            engine.traceHost("clear_session")
        }
        await engine.hostResetDomains()
        await engine.sessionClient.clearSessionStorage(clearDisk: allowClear, resetDomains: false)
    }

    func markExpired(snapshotJson: String) async {
        guard let engine else { return }
        let allowMarkExpired = await MainActor.run {
            engine.traceHost("mark_expired")
        }
        await engine.hostResetDomains()
        await engine.sessionClient.markExpiredFromCore(snapshotJSON: snapshotJson, persist: allowMarkExpired)
        await engine.waitForCoreMirrorDrain()
        await MainActor.run {
            engine.noteCoreCleanupCompleted()
        }
    }

    // MARK: - Transport Host Effects (U2)

    func persistPollState(state: PollStateRecord) async {
        guard let engine else { return }
        let swiftState = ZaloPollState(coreRecord: state)
        await engine.hostPersistPollState(swiftState)
    }

    func persistWsCursors(cursors: [CursorEntry]) async {
        guard let engine else { return }
        await engine.webSocket.syncPersistedCursors(cursors)
        await engine.persistWSQueueCursors(ZaloWebSocket.cursorSnapshots(from: cursors))
    }

    func applyBatch(
        cmd: UInt16?,
        incrementUnread: Bool,
        notifyIncoming: Bool,
        payloadJson: String
    ) async -> BatchApplyDeltaRecord {
        guard let engine else {
            return BatchApplyDeltaRecord(appliedCount: 0, updates: [], previewOverrides: [], persistConversations: false)
        }
        let box = ZaloJSONBox(JSONLossless.parseObject(string: payloadJson) ?? [:])
        let delta = await engine.hostApplyBatch(
            box: box,
            cmd: cmd,
            incrementUnread: incrementUnread,
            notifyIncoming: notifyIncoming
        )
        if engine.hasTransportSettleTrace {
            await MainActor.run {
                engine.transportSettleTrace?()
            }
        }
        return delta
    }

    func applyParsedEvents(
        cmd: UInt16,
        incrementUnread: Bool,
        notifyIncoming: Bool,
        events: [WireEvent],
        uids: [String],
        payload: CoreWirePayload
    ) async -> BatchApplyDeltaRecord {
        guard let engine else {
            return BatchApplyDeltaRecord(appliedCount: 0, updates: [], previewOverrides: [], persistConversations: false)
        }
        let context = await engine.hostLookupNameContext(uids: uids)
        let resolvedWire = payload.resolve(
            myUid: context.myUid,
            selfConvId: context.selfConvId,
            names: context.names
        ) ?? events
        let parsed = ZaloWireParser.parsedEvents(from: resolvedWire)
        let delta = await engine.hostApplyParsedEvents(
            cmd: cmd,
            incrementUnread: incrementUnread,
            notifyIncoming: notifyIncoming,
            events: parsed
        )
        if engine.hasTransportSettleTrace {
            await MainActor.run {
                engine.transportSettleTrace?()
            }
        }
        return delta
    }

    func mobileSync(events: [MobileSyncEventRecord]) async {
        guard let engine, !events.isEmpty else { return }
        let mapped = events.map(ZaloMobileSyncEvent.init(coreRecord:))
        let allowSync = await MainActor.run {
            engine.traceHost("mobile_sync", args: [
                "events": ZaloEngine.serializeMobileSyncEvents(mapped),
            ])
        }
        if allowSync {
            await engine.processMobileSyncEvents(mapped)
        }
    }

    func e2eeSignal(cmd: UInt16, payloadJson: String) async {
        guard let engine else { return }
        let box = ZaloJSONBox(JSONLossless.parseObject(string: payloadJson) ?? [:])
        await engine.hostHandleE2EESignal(cmd: cmd, payload: box)
    }

    func e2eeDeliverReports(cmd: UInt16, payloadJson: String) async {
        guard let engine else { return }
        let box = ZaloJSONBox(JSONLossless.parseObject(string: payloadJson) ?? [:])
        await engine.hostHandleE2EEDeliverReports(cmd: cmd, payload: box)
    }

    func e2eeConnected(uid: String) async {
        guard let engine else { return }
        await engine.hostHandleE2EEConnected(uid: uid)
        if engine.hasTransportSettleTrace {
            await MainActor.run {
                engine.transportSettleTrace?()
            }
        }
    }

    func e2eeDisconnected() async {
        guard let engine else { return }
        let allowDisconnect = await MainActor.run {
            engine.traceHost("e2ee_disconnected")
        }
        if allowDisconnect {
            await engine.e2eeManager.markDisconnected()
        }
        if engine.hasTransportSettleTrace {
            await MainActor.run {
                engine.transportSettleTrace?()
            }
        }
    }

    func voipControl(act: String, rawDataJson: String, dataJson: String) async {
        guard let engine else { return }
        let dataBox = ZaloJSONBox(JSONLossless.parseObject(string: dataJson) ?? [:])
        await engine.hostHandleVoipControl(act: act, rawDataJson: rawDataJson, dataBox: dataBox)
    }

    func showTyping(convId: String, uid: String, onPc: Bool) async {
        guard let engine else { return }
        await MainActor.run {
            if engine.traceHost("show_typing", args: ["conv_id": convId, "uid": uid, "on_pc": onPc]) {
                let name = engine.lookupPersonInfo(uid)?.name ?? "Ai đó"
                engine.showTyping(convId: convId, name: name, onPC: onPc)
            }
        }
    }

    func pinTopic(convId: String) async {
        guard let engine else { return }
        await MainActor.run {
            if engine.traceHost("pin_topic", args: ["conv_id": convId]) {
                engine.handlePinTopicEvent(conversationId: convId)
            }
        }
    }

    func groupNotice(act: String, dataJson: String, ts: Int64) async {
        guard let engine else { return }
        let dataBox = ZaloJSONBox(JSONLossless.parseObject(string: dataJson) ?? [:])
        await engine.hostHandleGroupNotice(act: act, dataBox: dataBox, ts: ts)
    }

    func mute(convId: String, set: Bool, start: Int64, startExplicit: Bool, duration: Int64) async {
        guard let engine else { return }
        await engine.hostApplyMute(
            convId: convId,
            set: set,
            start: start,
            startExplicit: startExplicit,
            duration: duration
        )
    }
}

extension ZaloPollState {
    init(coreRecord record: PollStateRecord) {
        self.init(
            lastActionId: record.lastActionId,
            lastActionIdOther: record.lastActionIdOther,
            queues: Dictionary(uniqueKeysWithValues: record.queues.map {
                ($0.key, ZaloPollQueueCursor(lastId: $0.lastId, ids: $0.ids))
            })
        )
    }

    var coreRecord: PollStateRecord {
        PollStateRecord(
            lastActionId: lastActionId,
            lastActionIdOther: lastActionIdOther,
            queues: queues.keys.sorted().map { key in
                PollQueueRecord(key: key, lastId: queues[key]?.lastId ?? "1", ids: queues[key]?.ids ?? [])
            }
        )
    }
}

extension ZaloMobileSyncEvent {
    init(coreRecord record: MobileSyncEventRecord) {
        switch record {
        case .transferAfterLogin(let tempKey):
            self = .transferAfterLogin(tempKey: tempKey)
        case .waitingConfirmOnPhone(let syncId):
            self = .waitingConfirmOnPhone(syncId: syncId)
        case .userConfirmed:
            self = .userConfirmed
        case .userRejected:
            self = .userRejected
        case .mobileBusy:
            self = .mobileBusy
        case .uploadBatch(let syncId, let url, let batchType, let idx, let isLast):
            self = .uploadBatch(syncId: syncId, url: url, batchType: Int(batchType), idx: Int(idx), isLast: isLast)
        }
    }
}

extension ZaloLoginAccount {
    init(coreRecord record: LoginAccountRecord) {
        self.init(
            userId: record.userId,
            displayName: record.displayName,
            avatar: record.avatar,
            phone: record.phone,
            send2MeId: record.send2meId,
            dkey: record.dkey,
            zpwEnk: record.zpwEnk,
            zpwSek: record.zpwSek,
            needSyncMsg: record.needSyncMsg
        )
    }

    var coreRecord: LoginAccountRecord {
        LoginAccountRecord(
            userId: userId,
            displayName: displayName,
            avatar: avatar,
            phone: phone,
            send2meId: send2MeId,
            dkey: dkey,
            zpwEnk: zpwEnk,
            zpwSek: zpwSek,
            needSyncMsg: needSyncMsg
        )
    }
}

extension ZaloEngine.ConversationSummary {
    nonisolated init(coreRecord record: ConversationSummaryRecord) {
        let preview: Preview? = record.preview.map { p in
            Preview(
                text: p.text,
                date: p.dateMs.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                fromMe: p.fromMe
            )
        }
        self.init(
            id: record.id,
            isGroup: record.isGroup,
            name: record.name,
            avatar: record.avatar.flatMap { $0.isEmpty ? nil : URL(string: $0) },
            pinned: record.pinned,
            members: Int(record.members),
            unread: Int(record.unread),
            preview: preview
        )
    }

    nonisolated var coreRecord: ConversationSummaryRecord {
        let previewRecord: ConversationPreviewRecord? = preview.map { p in
            ConversationPreviewRecord(
                text: p.text,
                dateMs: p.date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) },
                fromMe: p.fromMe
            )
        }
        return ConversationSummaryRecord(
            id: id,
            isGroup: isGroup,
            name: name,
            avatar: avatar?.absoluteString,
            pinned: pinned,
            members: Int64(members),
            unread: Int64(unread),
            preview: previewRecord
        )
    }
}

extension ConversationActionsState {
    init(coreRecord record: ConversationActionsRecord) {
        var nextFlags: [String: ConversationActionFlags] = [:]
        nextFlags.reserveCapacity(record.flags.count)
        for entry in record.flags where entry.bits != 0 {
            nextFlags[entry.id] = ConversationActionFlags(rawValue: Int(entry.bits))
        }
        var nextLeft: [String: ConversationLeaveType] = [:]
        nextLeft.reserveCapacity(record.left.count)
        for entry in record.left {
            nextLeft[entry.id] = ConversationLeaveType(rawValue: entry.kind) ?? .kick
        }
        self.init(
            loaded: record.loaded,
            hiddenKnown: record.hiddenKnown,
            flags: nextFlags,
            left: nextLeft,
            hiddenEnabled: record.hiddenEnabled,
            hasHiddenPIN: record.hasHiddenPin,
            hiddenIds: Set(record.hiddenIds),
            markUnreadEnabled: record.markUnreadEnabled,
            lateEpoch: record.lateEpoch,
            lateSeq: Int(record.lateSeq)
        )
    }
}

extension ConversationExtras {
    mutating func applyCoreRecord(_ record: ConversationExtrasRecord) {
        loaded = record.loaded
        labels = record.labels.map { l in
            Label(id: l.id, name: l.name, colorHex: l.colorHex, convIds: l.convIds)
        }
        archivedEnabled = record.archivedEnabled
        typeFilter = Int(record.typeFilter)
        labelFilterIds = record.labelFilterIds
        listIds = record.listIds
        strangerIds = Set(record.strangerIds)
        strangerFolderIds = record.strangerFolderIds
        strangerBox = StrangerBox(
            chats: Int(record.strangerBox.chats),
            unreadChats: Int(record.strangerBox.unreadChats),
            unreadMessages: Int(record.strangerBox.unreadMessages),
            newestId: record.strangerBox.newestId
        )
        var map: [String: String] = [:]
        map.reserveCapacity(record.labelByConversation.count)
        for entry in record.labelByConversation {
            map[entry.convId] = entry.labelId
        }
        labelByConversation = map
    }
}

extension ConversationPrompt {
    init(coreRecord record: ConversationPromptRecord) {
        switch record {
        case .delete(let id): self = .delete(id: id)
        case .pinBoard(let id): self = .pinBoard(id: id)
        case .hide(let id): self = .hide(id: id)
        case .unhide(let id): self = .unhide(id: id)
        case .unlock(let id): self = .unlock(id: id)
        }
    }

    var coreRecord: ConversationPromptRecord {
        switch self {
        case .delete(let id): return .delete(id: id)
        case .pinBoard(let id): return .pinBoard(id: id)
        case .hide(let id): return .hide(id: id)
        case .unhide(let id): return .unhide(id: id)
        case .unlock(let id): return .unlock(id: id)
        }
    }
}

extension ConversationActionResult {
    init(coreRecord record: ConversationActionResultRecord) {
        self.init(
            ok: record.ok,
            text: record.text,
            full: record.full,
            badPIN: record.badPin,
            pinExists: record.pinExists,
            neutral: record.neutral
        )
    }

    var coreRecord: ConversationActionResultRecord {
        ConversationActionResultRecord(
            ok: ok,
            text: text,
            full: full,
            badPin: badPIN,
            pinExists: pinExists,
            neutral: neutral
        )
    }
}

extension PinBoard {
    init(coreRecord record: PinBoardRecord) {
        self.init(
            tab: Int(record.tab),
            limit: Int(record.limit),
            total: Int(record.total),
            need: Int(record.need),
            items: record.items
        )
    }
}

extension ZaloEngine {
    /// Ensures the single `CoreEngine` actor and its `@MainActor` change-mirror task are running.
    internal func ensureCoreEngine() async -> CoreEngine? {
        if let existing = coreLifecycle.core {
            return existing
        }
        if coreLifecycle.isShutDown {
            pendingCoreCommands.removeAll()
            failAllMirrorWaiters()
            coreLifecycle.finishAllGates()
            return nil
        }
        if let existingTask = coreInitTask {
            return await existingTask.value
        }

        let initTask = Task<CoreEngine?, Never> { @MainActor [weak self] in
            guard let self else { return nil }
            guard !self.coreLifecycle.isShutDown else {
                self.pendingCoreCommands.removeAll()
                self.failAllMirrorWaiters()
                self.coreLifecycle.finishAllGates()
                return nil
            }
            guard let coreSession = await self.sessionClient.sharedCoreSession() else {
                EngineLog.shared.write("core: failed to create shared CoreSession")
                self.pendingCoreCommands.removeAll()
                self.failAllMirrorWaiters()
                self.coreLifecycle.finishAllGates()
                return nil
            }
            let host = ZaloEngineCoreHost(engine: self)
            guard let core = try? CoreEngine(session: coreSession, host: host) else {
                EngineLog.shared.write("core: failed to start CoreEngine")
                self.pendingCoreCommands.removeAll()
                self.failAllMirrorWaiters()
                self.coreLifecycle.finishAllGates()
                return nil
            }

            let lifecycle = self.coreLifecycle
            let changeTask = Task { @MainActor [weak self, core, lifecycle] in
                defer {
                    lifecycle.finishAllGates()
                    self?.failAllMirrorWaiters()
                }
                while !Task.isCancelled {
                    do {
                        guard let batch = try await core.nextChanges() else { break }
                        guard let self else { break }
                        self.applyCoreChanges(batch)
                    } catch {
                        break
                    }
                }
            }

            await self.webSocket.attachCore(core)
            guard self.coreLifecycle.install(core: core, changeTask: changeTask) else {
                await self.webSocket.detachCore()
                changeTask.cancel()
                core.stop()
                self.pendingCoreCommands.removeAll()
                self.failAllMirrorWaiters()
                self.coreLifecycle.finishAllGates()
                return nil
            }

            if let store = self.sqliteStore {
                core.attachStore(store: store.coreStoreHandle)
            }
            core.updateIdentities(table: self.currentIdentityTableRecord())
            if let openId = self.openConversationId {
                core.setOpenConversation(id: openId)
            }
            if !self.conversations.isEmpty {
                core.syncConversationsSnapshot(list: self.conversations.map(\.coreRecord))
            }

            let queued = self.pendingCoreCommands
            self.pendingCoreCommands.removeAll()
            for cmd in queued {
                Self.sendCommand(cmd, to: core)
            }
            return core
        }

        coreInitTask = initTask
        let result = await initTask.value
        coreInitTask = nil
        return result
    }

    /// Sends a command to `CoreEngine`, preserving FIFO order if `CoreEngine` is still initializing.
    internal func dispatchCoreCommand(_ command: PendingCoreCommand) {
        guard !coreLifecycle.isShutDown else { return }
        armCorePhaseGates(for: command)
        if let core = coreLifecycle.core, pendingCoreCommands.isEmpty {
            Self.sendCommand(command, to: core)
            return
        }
        pendingCoreCommands.append(command)
        Task { @MainActor [weak self] in
            _ = await self?.ensureCoreEngine()
        }
    }

    private func armCorePhaseGates(for command: PendingCoreCommand) {
        switch command {
        case .start:
            if let gate = coreLifecycle.replaceGate(.boot) {
                bootTask = Task { @MainActor in
                    await gate.wait()
                }
            }
        case .refreshQr:
            coreLifecycle.finishGate(.boot)
            if let gate = coreLifecycle.replaceGate(.qr) {
                qrTask = Task { @MainActor in
                    await gate.wait()
                }
            }
        case .logOut, .sessionExpired:
            coreLifecycle.finishGate(.boot)
            if let cleanupGate = coreLifecycle.replaceGate(.cleanup) {
                pendingCleanupTask = Task { @MainActor in
                    await cleanupGate.wait()
                }
            }
            if let qrGate = coreLifecycle.replaceGate(.qr) {
                qrTask = Task { @MainActor in
                    await qrGate.wait()
                }
            }
        }
    }

    internal func noteCoreBootCompleted() {
        coreLifecycle.finishGate(.boot)
    }

    internal func noteCoreQRCompleted() {
        coreLifecycle.finishGate(.qr)
    }

    internal func noteCoreCleanupCompleted() {
        coreLifecycle.finishGate(.cleanup)
    }

    internal func finishAllCorePhaseGates() {
        coreLifecycle.finishAllGates()
    }

    /// Applies an account profile update through `olaz-core` and suspends until the resulting
    /// state change has been reflected in the Swift mirror (`profile`, `selfConversationId`).
    internal func applyCoreAccountProfile(_ account: ZaloLoginAccount) async {
        guard let core = await ensureCoreEngine() else { return }
        guard let targetVersion = try? await core.applyAccountProfile(account: account.coreRecord) else {
            return
        }
        await waitForMirrorVersion(targetVersion)
    }

    /// Stops `CoreEngine` and its change-mirror loop (used in tests and teardown).
    internal func stopCoreEngine() {
        pendingCoreCommands.removeAll()
        coreLifecycle.shutdown()
        let ws = webSocket
        Task { await ws.detachCore() }
        failAllMirrorWaiters()
    }

    internal func hostNotePrepareStoreStarted() {
        // Shape-only hook; keeps MainActor visibility clean if future domains log transitions.
    }

    internal struct CoreNameContext: Sendable {
        let myUid: String
        let selfConvId: String?
        let names: [NameEntry]
    }

    internal func hostLoadTransportState() async -> PersistedTransportStateRecord {
        let cursors = await webSocket.currentQueueCursors()
        return PersistedTransportStateRecord(
            pollState: pollState.coreRecord,
            wsCursors: ZaloWebSocket.cursorEntries(from: cursors)
        )
    }

    internal func hostPersistPollState(_ state: ZaloPollState) async {
        pollState = state
        await persistPollState()
    }

    internal func hostApplyBatch(
        box: ZaloJSONBox,
        cmd: UInt16?,
        incrementUnread: Bool,
        notifyIncoming: Bool
    ) async -> BatchApplyDeltaRecord {
        let cmdArg: Any = cmd.map { Int($0) } ?? NSNull()
        guard traceHost("apply_batch", args: [
            "cmd": cmdArg,
            "increment_unread": incrementUnread,
            "notify_incoming": notifyIncoming,
            "payload": box.dict,
        ]) else {
            return BatchApplyDeltaRecord(appliedCount: 0, updates: [], previewOverrides: [], persistConversations: false)
        }
        return await applyBatchResponseCollectingDelta(
            box.dict,
            defaultCmd: cmd ?? 0,
            incrementUnread: incrementUnread,
            notifyIncoming: notifyIncoming
        )
    }

    internal func hostApplyParsedEvents(
        cmd: UInt16,
        incrementUnread: Bool,
        notifyIncoming: Bool,
        events: [ParsedWireEvent]
    ) async -> BatchApplyDeltaRecord {
        guard traceHost("apply_parsed_events", args: [
            "cmd": Int(cmd),
            "increment_unread": incrementUnread,
            "notify_incoming": notifyIncoming,
            "events": ZaloEngine.serializeParsedWireEvents(events),
        ]) else {
            return BatchApplyDeltaRecord(appliedCount: 0, updates: [], previewOverrides: [], persistConversations: false)
        }
        return await applyParsedEventsCollectingDelta(
            events,
            incrementUnread: incrementUnread,
            notifyIncoming: notifyIncoming
        )
    }

    internal func hostLookupNameContext(uids: [String]) -> CoreNameContext {
        var names: [NameEntry] = []
        names.reserveCapacity(uids.count)
        for uid in uids {
            if let hit = lookupPersonInfo(uid) {
                names.append(NameEntry(uid: uid, name: hit.name, avatar: hit.avatar))
            }
        }
        return CoreNameContext(
            myUid: profile?.userId ?? "",
            selfConvId: selfConversationId,
            names: names
        )
    }

    internal func hostHandleE2EESignal(cmd: UInt16, payload: ZaloJSONBox) async {
        guard traceHost("e2ee_signal", args: ["cmd": Int(cmd), "payload": payload.dict]) else { return }
        guard let uid = profile?.userId, !uid.isEmpty else { return }
        await e2eeManager.handleSignalSocketEvent(
            cmd: cmd,
            payload: payload,
            uid: uid,
            webSocket: webSocket,
            store: sqliteStore
        )
    }

    internal func hostHandleE2EEDeliverReports(cmd: UInt16, payload: ZaloJSONBox) async {
        guard traceHost("e2ee_deliver_reports", args: ["cmd": Int(cmd), "payload": payload.dict]) else { return }
        let resends = await e2eeManager.handleDeliverReports(
            cmd: cmd,
            payload: payload,
            webSocket: webSocket
        )
        for request in resends {
            await resendE2EEMessage(request)
        }
    }

    internal func hostHandleE2EEConnected(uid: String) async {
        let effectiveUid = uid.isEmpty ? (profile?.userId ?? "") : uid
        guard !effectiveUid.isEmpty else { return }
        guard traceHost("e2ee_connected", args: ["uid": effectiveUid]) else { return }
        await e2eeManager.syncBundleWithServerIfNeeded(
            uid: effectiveUid,
            webSocket: webSocket,
            store: sqliteStore
        )
        await e2eeManager.fetchE2EEPeerList(
            webSocket: webSocket,
            store: sqliteStore,
            myUid: effectiveUid
        )
    }

    internal func hostHandleVoipControl(act: String, rawDataJson: String, dataBox: ZaloJSONBox) async {
        let rawValue: Any = {
            if let obj = JSONLossless.parseObject(string: rawDataJson) {
                return obj
            }
            if let data = rawDataJson.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                return parsed
            }
            return dataBox.dict
        }()
        guard traceHost("voip_control", args: ["act": act, "raw_data": rawValue, "data": dataBox.dict]) else { return }
        await handleVoipControlEvent(act: act, rawDataValue: rawValue, parsedData: dataBox.dict)
    }

    internal func hostHandleGroupNotice(act: String, dataBox: ZaloJSONBox, ts: Int64) async {
        guard traceHost("group_notice", args: ["act": act, "data": dataBox.dict, "ts": ts]) else { return }
        await handleGroupEventNotice(act: act, data: dataBox.dict, ts: ts)
    }

    internal func hostApplyMute(
        convId: String,
        set: Bool,
        start: Int64,
        startExplicit: Bool,
        duration: Int64
    ) async {
        guard !convId.isEmpty else { return }
        let startArg: Any = (!startExplicit && hostTrace != nil) ? "<volatile>" : start
        guard traceHost("mute", args: [
            "conv_id": convId,
            "set": set,
            "start": startArg,
            "duration": duration,
        ]) else {
            return
        }
        if set {
            notificationSettings.mutes[convId] = MuteInfo(startTime: Double(start), duration: Double(duration))
        } else {
            notificationSettings.mutes.removeValue(forKey: convId)
        }
        await saveNotificationPreferences()
    }

    private static func sendCommand(_ command: PendingCoreCommand, to core: CoreEngine) {
        switch command {
        case .start:
            core.start()
        case .refreshQr:
            core.refreshQr()
        case .logOut:
            core.logOut()
        case .sessionExpired(let reason):
            core.handleSessionExpiredNotice(reason: reason)
        }
    }

    internal func applyCoreChanges(_ batch: CoreChangesRecord) {
        if let session = batch.session {
            let qrPayload: String?
            if case .login(let login) = session.phase {
                qrPayload = login.qrPayload
            } else {
                qrPayload = nil
            }
            let mappedPhase = mapPhase(session.phase)
            let mappedProfile = session.profile.map { rec in
                Profile(
                    userId: rec.userId,
                    displayName: rec.displayName,
                    avatar: rec.avatar.flatMap(URL.init(string:)),
                    phone: rec.phone
                )
            }
            applySessionMirror(
                phase: mappedPhase,
                profile: mappedProfile,
                signOutNotice: session.signOutNotice,
                selfConversationId: session.selfConversationId,
                clientVersion: "694 (Native)",
                qrPayload: qrPayload
            )

            // Update lifecycle gates when boot hands off to QR or QR reaches a terminal failure/expiry.
            if case .login(let login) = mappedPhase {
                if coreLifecycle.hasGate(.boot) {
                    coreLifecycle.finishGate(.boot)
                    switch login.step {
                    case .generating, .waitingScan, .waitingConfirm:
                        if !coreLifecycle.hasGate(.qr), let qrGate = coreLifecycle.replaceGate(.qr) {
                            qrTask = Task { @MainActor in
                                await qrGate.wait()
                            }
                        }
                    case .expired, .failed:
                        break
                    }
                }
                switch login.step {
                case .expired, .failed:
                    coreLifecycle.finishGate(.qr)
                case .generating, .waitingScan, .waitingConfirm:
                    break
                }
            }
        }

        isApplyingCoreMirror = true
        defer { isApplyingCoreMirror = false }

        if let convRecords = batch.conversations {
            let mapped = convRecords.map(ConversationSummary.init(coreRecord:))
            if mapped != conversations {
                conversations = mapped
            }
        }
        if let flagsRecord = batch.conversationFlags {
            let mapped = ConversationActionsState(coreRecord: flagsRecord)
            if mapped != conversationActions {
                conversationActions = mapped
            }
            var pinned: Set<String> = []
            var archived: Set<String> = []
            var unreadMarks: Set<String> = []
            for (id, flags) in mapped.flags {
                if flags.contains(.pinned) { pinned.insert(id) }
                if flags.contains(.archived) { archived.insert(id) }
                if flags.contains(.unreadMark) { unreadMarks.insert(id) }
            }
            cachedPinnedIds = pinned
            cachedArchivedIds = archived
            cachedUnreadMarks = unreadMarks
        }
        if let extrasRecord = batch.conversationExtras {
            var next = conversationExtras
            next.applyCoreRecord(extrasRecord)
            if next != conversationExtras {
                conversationExtras = next
            }
        }
        if let uiRecord = batch.conversationUi {
            conversationUI.applyCoreMirror(uiRecord)
        }
        if let promptUpdate = batch.conversationPrompt {
            let mapped = promptUpdate.prompt.map(ConversationPrompt.init(coreRecord:))
            if mapped != conversationPrompt {
                conversationPrompt = mapped
            }
        }

        if batch.version > appliedMirrorVersion {
            appliedMirrorVersion = batch.version
        }
        resumeMirrorWaiters(upTo: appliedMirrorVersion)
    }

    // MARK: - U3 Conversations Core Bridge Helpers

    internal func currentIdentityTableRecord() -> IdentityTableRecord {
        IdentityTableRecord(
            friends: contacts.friends.map {
                FriendIdentityRecord(id: $0.id, name: $0.name, avatar: $0.avatar?.absoluteString)
            },
            groups: contacts.groups.map {
                GroupIdentityRecord(id: $0.id, name: $0.name, avatar: $0.avatar?.absoluteString, members: Int64($0.members))
            },
            friendsLoaded: contacts.friendsLoaded,
            groupsLoaded: contacts.groupsLoaded,
            aliases: cachedAliases.map { StringPairEntry(key: $0.key, value: $0.value) },
            cachedProfiles: cachedProfiles.map { CachedProfileEntry(uid: $0.key, name: $0.value.name, avatar: $0.value.avatar) },
            cachedGroups: cachedGroups.map {
                CachedGroupEntry(gid: $0.key, name: $0.value.name, avatar: $0.value.avatar, members: Int64($0.value.members))
            },
            activityRanks: cachedActivityRanks.map { RankEntry(convId: $0.key, rank: $0.value) },
            friendGlobalIds: cachedFriendGlobalIds.map { StringPairEntry(key: $0.key, value: $0.value) }
        )
    }

    internal func pushCoreIdentitiesIfRunning() {
        guard !isApplyingCoreMirror, let core = coreLifecycle.core else { return }
        core.updateIdentities(table: currentIdentityTableRecord())
    }

    internal func offlineConversationsCore() -> CoreOfflineConversations {
        let offline: CoreOfflineConversations
        if let existing = offlineConvCore {
            offline = existing
        } else {
            let created = CoreOfflineConversations()
            offlineConvCore = created
            offline = created
        }
        offline.syncContext(
            identities: currentIdentityTableRecord(),
            myUid: profile?.userId ?? "",
            myAvatar: profile?.avatar?.absoluteString,
            selfConvId: selfConversationId,
            openConvId: openConversationId
        )
        offline.syncConversations(list: conversations.map(\.coreRecord))
        return offline
    }

    internal func commitBatchDeltaToCore(_ delta: BatchApplyDeltaRecord) async {
        guard delta.appliedCount > 0 || !delta.updates.isEmpty || !delta.previewOverrides.isEmpty else { return }
        if let core = coreLifecycle.core {
            if let v = try? await core.applyBatchDelta(delta: delta) {
                await waitForMirrorVersion(v)
            }
            return
        }
        let overrideIds = Set(delta.previewOverrides.map(\.convId))
        var beforePreviews: [String: ConversationSummary.Preview?] = [:]
        if !overrideIds.isEmpty {
            for conv in conversations where overrideIds.contains(conv.id) {
                beforePreviews[conv.id] = conv.preview
            }
        }
        let batch = offlineConversationsCore().applyBatchDelta(delta: delta)
        applyCoreChanges(batch)
        if delta.persistConversations {
            await persistConversationsToSQLite()
            for id in overrideIds {
                guard let conv = conversations.first(where: { $0.id == id }) else { continue }
                let prevBefore = beforePreviews[id] ?? nil
                if prevBefore != conv.preview {
                    let previewText = conv.preview?.text ?? ""
                    let previewTsMs = conv.preview?.date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? 0
                    let previewFromMe = conv.preview?.fromMe ?? false
                    try? await sqliteStore?.setConversationPreview(
                        id: id,
                        previewText: previewText,
                        previewTsMs: previewTsMs,
                        previewFromMe: previewFromMe
                    )
                }
            }
        }
    }

    internal func messagePreviewInputRecord(for msg: ChatMessage) -> MessagePreviewInputRecord {
        MessagePreviewInputRecord(
            convId: msg.conversationId,
            text: msg.text,
            mentions: msg.mentions.map {
                MentionInputRecord(uid: $0.uid, pos: Int64($0.pos), len: Int64($0.len), isAll: $0.isAll)
            },
            previewLabel: Self.messagePreviewLabel(msg),
            dateMs: Int64((msg.date.timeIntervalSince1970 * 1000).rounded()),
            isMine: msg.isMine,
            senderName: msg.senderName,
            senderAvatar: msg.senderAvatar?.absoluteString
        )
    }

    internal static func jsonString(for dict: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    private func mapPhase(_ record: PhaseRecord) -> Phase {
        switch record {
        case .starting:
            return .starting
        case .signingIn:
            return .signingIn
        case .ready:
            return .ready
        case .login(let login):
            let png = resolveQRPNG(payload: login.qrPayload, serverPNG: login.qrPng)
            let step: LoginState.Step
            switch login.step {
            case .generating:
                step = .generating
            case .waitingScan:
                step = .waitingScan
            case .waitingConfirm(let name, let avatar):
                step = .waitingConfirm(name: name, avatar: avatar.flatMap(URL.init(string:)))
            case .expired:
                step = .expired
            case .failed(let reason):
                step = .failed(Self.renderFailReason(reason))
            }
            return .login(LoginState(step: step, qrPNG: png))
        }
    }

    private func resolveQRPNG(payload: String?, serverPNG: Data?) -> Data? {
        if let serverPNG {
            return serverPNG
        }
        guard let payload, !payload.isEmpty else {
            cachedQRPayload = nil
            cachedQRPNG = nil
            return nil
        }
        if cachedQRPayload == payload, let cachedQRPNG {
            return cachedQRPNG
        }
        let generated = ZaloCrypto.generateQRPNG(payload: payload)
        cachedQRPayload = payload
        cachedQRPNG = generated
        return generated
    }

    /// Renders a typed `FailReasonRecord` from `olaz-core` into the exact locale-aware message
    /// Swift displays today (`RustCore.mapError(...).localizedDescription` for `.core`).
    nonisolated internal static func renderFailReason(_ reason: FailReasonRecord) -> String {
        switch reason {
        case .text(let message):
            return message
        case .core(let kind):
            switch kind {
            case .network(let netKind):
                return RustCore.mapError(CoreError.Network(kind: netKind, message: "")).localizedDescription
            case .session(let code, let message, let url):
                let isAuth = ZaloSessionError.authErrorCodes.contains(Int(code))
                return RustCore.mapError(
                    CoreError.Session(code: code, message: message, isAuth: isAuth),
                    path: url
                ).localizedDescription
            case .http(let status):
                return RustCore.mapError(CoreError.Http(status: status)).localizedDescription
            case .invalidJson:
                return RustCore.mapError(CoreError.Parse(message: "")).localizedDescription
            case .notAuthenticated:
                return RustCore.mapError(CoreError.NotAuthenticated).localizedDescription
            case .crypto(let message):
                return RustCore.mapError(CoreError.Crypto(message: message)).localizedDescription
            }
        }
    }

    internal func waitForCoreMirrorDrain() async {
        guard let target = coreLifecycle.core?.currentVersion() else { return }
        await waitForMirrorVersion(target)
    }

    internal func waitForMirrorVersion(_ target: UInt64) async {
        guard appliedMirrorVersion < target, !coreLifecycle.isShutDown else { return }
        await withCheckedContinuation { continuation in
            if appliedMirrorVersion >= target || coreLifecycle.isShutDown {
                continuation.resume()
                return
            }
            mirrorVersionWaiters.append((target: target, continuation: continuation))
        }
    }

    private func resumeMirrorWaiters(upTo version: UInt64) {
        guard !mirrorVersionWaiters.isEmpty else { return }
        var remaining: [(target: UInt64, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in mirrorVersionWaiters {
            if waiter.target <= version {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        mirrorVersionWaiters = remaining
    }

    internal func failAllMirrorWaiters() {
        guard !mirrorVersionWaiters.isEmpty else { return }
        let waiters = mirrorVersionWaiters
        mirrorVersionWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume()
        }
    }
}
