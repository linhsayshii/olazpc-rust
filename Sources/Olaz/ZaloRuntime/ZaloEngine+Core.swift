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

/// Version-fenced MainActor overlay for optimistic U6 message actions (react, delete-for-me,
/// undo-delete, star). Prevents an older `CoreChangesRecord` (`batch.version < resolvedVersion`)
/// from reverting a newer optimistic UI change before core's authoritative batch arrives, while
/// snapshotting suppressed authoritative values so that if core's authoritative batch (including an
/// API error rollback) arrives before `resolveOptimisticOverlay` receives its target version, the
/// authoritative state is immediately reconciled on resolution.
internal struct OptimisticMessageOverlay {
    enum Kind {
        case reaction(msgId: String, clientId: String, reactions: [ChatMessage.Reaction])
        case delete(msgIds: Set<String>, undo: DeleteUndo)
        case undoDelete(restored: [ChatMessage])
        case star(msgId: String, on: Bool)
    }

    let token: UUID
    let convId: String
    var kind: Kind
    var resolvedVersion: UInt64 = .max

    var suppressedVersion: UInt64 = 0
    var suppressedReactions: [ChatMessage.Reaction]?
    var suppressedRestored: [ChatMessage] = []
    var suppressedRemovedIds: Set<String> = []
    var suppressedHasUndo: Bool = false
    var suppressedUndo: DeleteUndo?
    var suppressedStar: (starred: Bool, menuStar: MessageMenu.Star?, inCachedSet: Bool)?
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

    func onBootstrapStarted() async -> Bool {
        guard let engine else { return false }
        let allowBootstrap = await MainActor.run {
            let allowed = engine.traceHost("start_bootstrap")
            if allowed {
                engine.pushCoreIdentitiesIfRunning()
                engine.pushCoreContactsIfRunning()
                engine.pushCoreHistoryFreshnessIfRunning()
            }
            return allowed
        }
        await engine.waitForCoreMirrorDrain()
        await MainActor.run {
            engine.noteCoreBootCompleted()
        }
        return allowBootstrap
    }

    func applyMutes(mutes: [MuteEntryRecord]) async {
        guard let engine else { return }
        await engine.hostApplyBootstrapMutes(mutes)
    }

    func refreshCloud() async {
        guard let engine else { return }
        await engine.syncCachedIdentityPreferencesFromStore()
        await MainActor.run {
            engine.refreshCloud()
        }
    }

    func onBatchReceived(
        cmd: UInt16?,
        incrementUnread: Bool,
        notifyIncoming: Bool,
        payloadJson: String
    ) async -> String? {
        guard let engine else { return nil }
        return await engine.hostOnBatchReceived(
            cmd: cmd,
            incrementUnread: incrementUnread,
            notifyIncoming: notifyIncoming,
            payloadJson: payloadJson
        )
    }

    func onParsedEventsReceived(
        cmd: UInt16,
        incrementUnread: Bool,
        notifyIncoming: Bool,
        events: [WireEvent],
        uids: [String],
        payload: CoreWirePayload
    ) async -> Bool {
        guard let engine else { return false }
        let context = await engine.hostLookupNameContext(uids: uids)
        let resolvedWire = payload.resolve(
            myUid: context.myUid,
            selfConvId: context.selfConvId,
            names: context.names
        ) ?? events
        let parsed = ZaloWireParser.parsedEvents(from: resolvedWire)
        return await MainActor.run {
            engine.traceHost("apply_parsed_events", args: [
                "cmd": Int(cmd),
                "increment_unread": incrementUnread,
                "notify_incoming": notifyIncoming,
                "events": ZaloEngine.serializeParsedWireEvents(parsed),
            ])
        }
    }

    func onOpenConversationSync(convId: String, changed: Bool) async {
        guard let engine else { return }
        await MainActor.run {
            if changed { engine.dropMessagePrompts() }
            if engine.typing[convId] != nil { engine.typing[convId] = nil }
            engine.updateCallGateForConversation(convId)
        }
    }

    func onCloseConversation() async {
        guard let engine else { return }
        await MainActor.run {
            engine.dropMessagePrompts()
        }
    }

    func refreshBoardPins(convId: String) async {
        guard let engine else { return }
        await engine.refreshBoardPins(for: convId)
    }

    func markReadBoundary(convId: String, seenTarget: SeenTargetRecord?) async {
        guard let engine else { return }
        await engine.waitForCoreMirrorDrain()
        await MainActor.run {
            if engine.traceU4Host("mark_read", args: ["conv_id": convId]) {
                if let core = engine.coreLifecycle.core {
                    core.markConversationRead(id: convId, seenTarget: seenTarget)
                } else {
                    engine.markRead(convId)
                }
            }
        }
    }

    func applyRemoteReaction(
        convId: String,
        msgId: String,
        cliMsgId: String,
        senderId: String,
        rType: String,
        rIcon: String,
        eventId: String,
        reactClientId: String,
        senderName: String
    ) async -> Bool {
        guard let engine else { return false }
        guard engine.hasU4HostTrace else { return true }
        await engine.waitForCoreMirrorDrain()
        return await MainActor.run {
            engine.traceU4Host("apply_remote_reaction", args: [
                "conv_id": convId,
                "msg_id": msgId,
                "cli_msg_id": cliMsgId,
                "sender_id": senderId,
                "r_type": rType,
                "r_icon": rIcon,
                "event_id": eventId,
                "react_client_id": reactClientId,
                "sender_name": senderName,
            ])
        }
    }

    func applyRemoteRecall(
        convId: String,
        msgId: String,
        cliMsgId: String,
        updateConversationPreview: Bool
    ) async -> Bool {
        guard let engine else { return false }
        guard engine.hasU4HostTrace else { return true }
        await engine.waitForCoreMirrorDrain()
        return await MainActor.run {
            engine.traceU4Host("apply_remote_recall", args: [
                "conv_id": convId,
                "msg_id": msgId,
                "cli_msg_id": cliMsgId,
            ])
        }
    }

    func applyRemoteDelete(
        convId: String,
        msgId: String,
        cliMsgId: String,
        updateConversationPreview: Bool
    ) async -> Bool {
        guard let engine else { return false }
        guard engine.hasU4HostTrace else { return true }
        await engine.waitForCoreMirrorDrain()
        return await MainActor.run {
            engine.traceU4Host("apply_remote_delete", args: [
                "conv_id": convId,
                "msg_id": msgId,
                "cli_msg_id": cliMsgId,
            ])
        }
    }

    func decryptEnvelope(payloadJson: String) async -> String {
        guard let engine else { return payloadJson }
        return await engine.hostDecryptEnvelope(payloadJson: payloadJson)
    }

    func markE2eeConversations(convIds: [String]) async {
        guard let engine else { return }
        for cid in convIds {
            await engine.e2eeManager.markE2EEConversation(cid, enabled: true, store: engine.sqliteStore)
        }
    }

    func notePollMessages(messages: [ChatMessageRecord]) async {
        guard let engine, !messages.isEmpty else { return }
        let mapped = messages.map(ChatMessage.init(record:))
        await MainActor.run {
            engine.notePollMessages(mapped)
        }
    }

    func notifyIncomingMessages(messages: [ChatMessageRecord]) async {
        guard let engine, !messages.isEmpty else { return }
        let mapped = messages.map(ChatMessage.init(record:))
        await engine.notifyIncomingBatchMessages(mapped)
    }

    func showBatchTyping(convId: String, senderId: String) async {
        guard let engine else { return }
        await MainActor.run {
            let name = engine.lookupPersonInfo(senderId)?.name ?? "Ai đó"
            engine.showTyping(convId: convId, name: name)
        }
    }

    func transportBatchSettled() async {
        guard let engine, engine.hasTransportSettleTrace else { return }
        await engine.waitForCoreMirrorDrain()
        await MainActor.run {
            engine.transportSettleTrace?()
        }
    }

    func engineLog(message: String) async {
        await MainActor.run {
            EngineLog.shared.write(message)
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
        await engine.waitForCoreMirrorDrain()
        await MainActor.run {
            if engine.traceHost("show_typing", args: ["conv_id": convId, "uid": uid, "on_pc": onPc]),
               engine.coreLifecycle.core == nil {
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

    func sendE2eeText(
        convId: String,
        text: String,
        clientId: String,
        quote: E2eeQuoteArgRecord?
    ) async -> E2eeSendOutcomeRecord {
        guard let engine else { return .aborted }
        return await engine.hostSendE2EEText(
            convId: convId,
            text: text,
            clientId: clientId,
            quote: quote
        )
    }

    func showCard(convId: String, text: String) async {
        guard let engine else { return }
        await engine.waitForCoreMirrorDrain()
        await MainActor.run {
            engine.showActionCard(text, in: convId)
        }
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

            await self.sessionClient.attachCoreApi(core.sharedApi())
            if let store = self.sqliteStore {
                core.attachStore(store: store.coreStoreHandle)
            }
            core.updateIdentities(table: self.currentIdentityTableRecord())
            if !self.seenReactionEventOrder.isEmpty {
                core.seedSeenReactionKeys(keys: self.seenReactionEventOrder)
            }
            self.pushCoreContactsIfRunning()
            self.pushCoreHistoryFreshnessIfRunning()
            if let openId = self.openConversationId {
                core.setOpenConversation(id: openId)
            }
            if !self.conversations.isEmpty {
                core.syncConversationsSnapshot(list: self.conversations.map(\.coreRecord))
            }
            if !self.messages.isEmpty {
                for (convId, list) in self.messages {
                    core.writeThroughReplaceWindow(convId: convId, messages: list.map(ChatMessageRecord.init(message:)))
                }
            }
            if !self.hasMoreHistory.isEmpty {
                for (convId, hasMore) in self.hasMoreHistory {
                    core.writeThroughSetHasMore(convId: convId, hasMore: hasMore)
                }
            }
            let sendTypingEnabled = self.userDefaults.object(forKey: OlazPrefs.sendTyping) as? Bool ?? true
            core.setSendTypingEnabled(enabled: sendTypingEnabled)
            if let autoDel = self.autoDelete {
                for (convId, ttl) in autoDel where ttl > 0 {
                    core.setAutoDeleteTtl(convId: convId, ttlMs: ttl)
                }
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

        if !optimisticMessageOverlays.isEmpty {
            optimisticMessageOverlays.removeAll { $0.resolvedVersion <= batch.version }
        }

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

        if batch.messagesResetAll {
            if !messages.isEmpty { messages = [:] }
            if !hasMoreHistory.isEmpty { hasMoreHistory = [:] }
            if !historyTicks.isEmpty { historyTicks = [:] }
            historyFreshness = [:]
        }

        if !batch.windowDeltas.isEmpty {
            for delta in batch.windowDeltas {
                switch delta {
                case .reset(let convId, let records):
                    let mapped = records.map(ChatMessage.init(record:))
                    if messages[convId] != mapped {
                        messages[convId] = mapped
                    }
                case .append(let convId, let records):
                    let mapped = records.map(ChatMessage.init(record:))
                    var list = messages[convId] ?? []
                    let existingIds = Set(list.map(\.id))
                    let fresh = mapped.filter { !existingIds.contains($0.id) }
                    if !fresh.isEmpty {
                        list.append(contentsOf: fresh)
                        messages[convId] = list
                    } else if messages[convId] == nil {
                        messages[convId] = []
                    }
                case .patch(let convId, let upserts, let removedIds):
                    var list = messages[convId] ?? []
                    var changed = false
                    if !removedIds.isEmpty {
                        let rm = Set(removedIds)
                        let prevCount = list.count
                        list.removeAll { rm.contains($0.id) }
                        if list.count != prevCount { changed = true }
                    }
                    for rec in upserts {
                        let msg = ChatMessage(record: rec)
                        if let idx = list.firstIndex(where: { $0.id == msg.id }) {
                            if list[idx] != msg {
                                list[idx] = msg
                                changed = true
                            }
                        } else {
                            list.append(msg)
                            list.sort { a, b in
                                if a.date != b.date { return a.date < b.date }
                                return a.id < b.id
                            }
                            changed = true
                        }
                    }
                    if changed {
                        messages[convId] = list
                    }
                }
            }
        }

        if let meta = batch.messageMeta {
            var nextHasMore: [String: Bool] = [:]
            nextHasMore.reserveCapacity(meta.hasMoreHistory.count)
            for entry in meta.hasMoreHistory {
                nextHasMore[entry.convId] = entry.value
            }
            if nextHasMore != hasMoreHistory {
                hasMoreHistory = nextHasMore
            }

            var nextTicks: [String: Int] = [:]
            nextTicks.reserveCapacity(meta.historyTicks.count)
            for entry in meta.historyTicks {
                nextTicks[entry.convId] = Int(entry.tick)
            }
            if nextTicks != historyTicks {
                historyTicks = nextTicks
            }

            var nextFreshness: [String: HistoryFreshness] = [:]
            nextFreshness.reserveCapacity(meta.historyFreshness.count)
            for entry in meta.historyFreshness {
                switch entry.freshness {
                case .upToDate: nextFreshness[entry.convId] = .upToDate
                case .stale: nextFreshness[entry.convId] = .stale
                }
            }
            historyFreshness = nextFreshness
        }

        if let cRec = batch.contacts {
            applyContactsMirror(cRec)
        }

        if let typingEntries = batch.typing {
            var nextTyping: [String: TypingStatus] = [:]
            nextTyping.reserveCapacity(typingEntries.count)
            for entry in typingEntries {
                nextTyping[entry.convId] = TypingStatus(name: entry.name, onPC: entry.onPc)
            }
            if nextTyping != typing {
                typing = nextTyping
            }
        }

        if let undoUpdate = batch.deleteUndo {
            if let rec = undoUpdate.undo {
                let next = DeleteUndo(
                    id: deleteUndo?.id ?? UUID().uuidString,
                    conversationId: rec.convId,
                    count: Int(rec.count),
                    deadline: Date(timeIntervalSince1970: Double(rec.deadlineMs) / 1000.0)
                )
                if deleteUndo != next {
                    deleteUndo = next
                }
            } else if deleteUndo != nil {
                deleteUndo = nil
            }
        }

        if let confirmUpdate = batch.messageConfirm {
            if let rec = confirmUpdate.confirm {
                if mirroredMessageConfirmCoreId != rec.id {
                    if let mappedAction = mapMessageConfirmAction(rec.action, convId: rec.convId) {
                        if let existing = messageConfirm,
                           mirroredMessageConfirmCoreId == nil,
                           existing.conversationId == rec.convId,
                           existing.action == mappedAction,
                           existing.title == rec.title,
                           existing.message == rec.message,
                           existing.ok == rec.ok,
                           existing.destructive == rec.destructive {
                            mirroredMessageConfirmCoreId = rec.id
                        } else {
                            mirroredMessageConfirmCoreId = rec.id
                            messageConfirm = MessageActionConfirm(
                                conversationId: rec.convId,
                                action: mappedAction,
                                title: rec.title,
                                message: rec.message,
                                ok: rec.ok,
                                destructive: rec.destructive
                            )
                        }
                    }
                }
            } else {
                mirroredMessageConfirmCoreId = nil
                if messageConfirm != nil {
                    messageConfirm = nil
                }
            }
        }

        if let autoDelUpdate = batch.autoDelete {
            if let entries = autoDelUpdate.entries {
                var next: [String: Int64] = [:]
                next.reserveCapacity(entries.count)
                for entry in entries {
                    next[entry.convId] = entry.ttlMs
                }
                if autoDelete != next {
                    autoDelete = next
                }
            } else if autoDelete != nil {
                autoDelete = nil
            }
        }

        if let starred = batch.starredIds {
            let next = Set(starred)
            if cachedStarredIds != next {
                cachedStarredIds = next
            }
        }

        if let profiles = batch.cachedProfiles {
            var next: [String: ZaloWebKitMigrator.CachedProfile] = [:]
            next.reserveCapacity(profiles.count)
            for entry in profiles {
                next[entry.uid] = ZaloWebKitMigrator.CachedProfile(name: entry.name, avatar: entry.avatar)
            }
            cachedProfiles = next
        }

        if !optimisticMessageOverlays.isEmpty {
            reapplyActiveOptimisticOverlays(for: batch)
        }

        if batch.version > appliedMirrorVersion {
            appliedMirrorVersion = batch.version
        }
        resumeMirrorWaiters(upTo: appliedMirrorVersion)
    }

    // MARK: - U6 Version-Fenced Optimistic Overlays

    @discardableResult
    internal func beginOptimisticReactionOverlay(
        convId: String,
        msgId: String,
        clientId: String,
        reactions: [ChatMessage.Reaction]
    ) -> UUID {
        let token = UUID()
        optimisticMessageOverlays.append(OptimisticMessageOverlay(
            token: token,
            convId: convId,
            kind: .reaction(msgId: msgId, clientId: clientId, reactions: reactions)
        ))
        return token
    }

    @discardableResult
    internal func beginOptimisticDeleteOverlay(
        convId: String,
        messages deleted: [ChatMessage],
        undo: DeleteUndo
    ) -> UUID {
        let token = UUID()
        lastOptimisticDeletedMessages[convId] = deleted
        optimisticMessageOverlays.removeAll { overlay in
            guard overlay.convId == convId else { return false }
            if case .undoDelete = overlay.kind { return true }
            return false
        }
        optimisticMessageOverlays.append(OptimisticMessageOverlay(
            token: token,
            convId: convId,
            kind: .delete(msgIds: Set(deleted.map(\.id)), undo: undo)
        ))
        return token
    }

    @discardableResult
    internal func beginOptimisticUndoDeleteOverlay(
        convId: String,
        restored: [ChatMessage]
    ) -> UUID {
        let token = UUID()
        optimisticMessageOverlays.removeAll { overlay in
            guard overlay.convId == convId else { return false }
            if case .delete = overlay.kind { return true }
            return false
        }
        optimisticMessageOverlays.append(OptimisticMessageOverlay(
            token: token,
            convId: convId,
            kind: .undoDelete(restored: restored)
        ))
        return token
    }

    @discardableResult
    internal func beginOptimisticStarOverlay(
        convId: String,
        msgId: String,
        on: Bool
    ) -> UUID {
        let token = UUID()
        optimisticMessageOverlays.append(OptimisticMessageOverlay(
            token: token,
            convId: convId,
            kind: .star(msgId: msgId, on: on)
        ))
        return token
    }

    internal func scheduleOptimisticOverlayFence(token: UUID, core: CoreEngine) {
        Task { @MainActor [weak self, core] in
            if let v = try? await core.settle() {
                self?.resolveOptimisticOverlay(token: token, targetVersion: v)
            } else {
                self?.cancelOptimisticOverlay(token: token)
            }
        }
    }

    internal func cancelOptimisticOverlay(token: UUID) {
        optimisticMessageOverlays.removeAll { $0.token == token }
    }

    internal func resolveOptimisticOverlay(token: UUID, targetVersion: UInt64) {
        guard let idx = optimisticMessageOverlays.firstIndex(where: { $0.token == token }) else { return }
        if appliedMirrorVersion < targetVersion {
            optimisticMessageOverlays[idx].resolvedVersion = targetVersion
            return
        }
        let overlay = optimisticMessageOverlays.remove(at: idx)
        guard overlay.suppressedVersion >= targetVersion else { return }
        isApplyingCoreMirror = true
        isSuppressingDirectMessageSync = true
        defer {
            isSuppressingDirectMessageSync = false
            isApplyingCoreMirror = false
        }
        switch overlay.kind {
        case .reaction(let msgId, let clientId, _):
            if let authReactions = overlay.suppressedReactions,
               var list = messages[overlay.convId],
               let msgIdx = list.firstIndex(where: { $0.id == msgId || (!clientId.isEmpty && $0.clientId == clientId) }),
               list[msgIdx].reactions != authReactions {
                list[msgIdx].reactions = authReactions
                messages[overlay.convId] = list
            }
        case .delete:
            if !overlay.suppressedRestored.isEmpty {
                var list = messages[overlay.convId] ?? []
                let existing = Set(list.map(\.id))
                let toAdd = overlay.suppressedRestored.filter { !existing.contains($0.id) }
                if !toAdd.isEmpty {
                    list.append(contentsOf: toAdd)
                    list.sort { a, b in a.date == b.date ? a.id < b.id : a.date < b.date }
                    messages[overlay.convId] = list
                }
            }
            if overlay.suppressedHasUndo, deleteUndo != overlay.suppressedUndo {
                deleteUndo = overlay.suppressedUndo
            }
        case .undoDelete:
            if !overlay.suppressedRemovedIds.isEmpty, var list = messages[overlay.convId] {
                let prev = list.count
                list.removeAll { overlay.suppressedRemovedIds.contains($0.id) }
                if list.count != prev { messages[overlay.convId] = list }
            }
            if overlay.suppressedHasUndo, deleteUndo != overlay.suppressedUndo {
                deleteUndo = overlay.suppressedUndo
            }
        case .star(let msgId, _):
            if let authStar = overlay.suppressedStar {
                if var list = messages[overlay.convId],
                   let msgIdx = list.firstIndex(where: { $0.id == msgId }) {
                    if list[msgIdx].menu.starred != authStar.starred || list[msgIdx].menu.star != authStar.menuStar {
                        list[msgIdx].menu.starred = authStar.starred
                        list[msgIdx].menu.star = authStar.menuStar
                        messages[overlay.convId] = list
                    }
                }
                if authStar.inCachedSet {
                    cachedStarredIds.insert(msgId)
                } else {
                    cachedStarredIds.remove(msgId)
                }
            }
        }
    }

    private func reapplyActiveOptimisticOverlays(for batch: CoreChangesRecord) {
        var touchedConvs: Set<String> = []
        if !batch.messagesResetAll {
            for delta in batch.windowDeltas {
                switch delta {
                case .reset(let convId, _), .append(let convId, _), .patch(let convId, _, _):
                    touchedConvs.insert(convId)
                }
            }
        }
        for i in optimisticMessageOverlays.indices {
            let overlay = optimisticMessageOverlays[i]
            guard batch.version < overlay.resolvedVersion else { continue }
            let convTouched = batch.messagesResetAll || touchedConvs.contains(overlay.convId)
            switch overlay.kind {
            case .reaction(let msgId, let clientId, let expectedReactions):
                if convTouched,
                   var list = messages[overlay.convId],
                   let idx = list.firstIndex(where: { $0.id == msgId || (!clientId.isEmpty && $0.clientId == clientId) }) {
                    optimisticMessageOverlays[i].suppressedVersion = max(optimisticMessageOverlays[i].suppressedVersion, batch.version)
                    optimisticMessageOverlays[i].suppressedReactions = list[idx].reactions
                    if list[idx].reactions != expectedReactions {
                        list[idx].reactions = expectedReactions
                        messages[overlay.convId] = list
                    }
                }
            case .delete(let msgIds, let expectedUndo):
                if convTouched, var list = messages[overlay.convId] {
                    let present = list.filter { msgIds.contains($0.id) }
                    optimisticMessageOverlays[i].suppressedVersion = max(optimisticMessageOverlays[i].suppressedVersion, batch.version)
                    optimisticMessageOverlays[i].suppressedRestored = present
                    if !present.isEmpty {
                        list.removeAll { msgIds.contains($0.id) }
                        messages[overlay.convId] = list
                    }
                }
                if batch.deleteUndo != nil {
                    optimisticMessageOverlays[i].suppressedVersion = max(optimisticMessageOverlays[i].suppressedVersion, batch.version)
                    optimisticMessageOverlays[i].suppressedHasUndo = true
                    optimisticMessageOverlays[i].suppressedUndo = deleteUndo
                    if deleteUndo != expectedUndo {
                        deleteUndo = expectedUndo
                    }
                }
            case .undoDelete(let restored):
                if convTouched {
                    var list = messages[overlay.convId] ?? []
                    let existingIds = Set(list.map(\.id))
                    let missing = restored.filter { !existingIds.contains($0.id) }
                    optimisticMessageOverlays[i].suppressedVersion = max(optimisticMessageOverlays[i].suppressedVersion, batch.version)
                    optimisticMessageOverlays[i].suppressedRemovedIds = Set(missing.map(\.id))
                    if !missing.isEmpty {
                        list.append(contentsOf: missing)
                        list.sort { a, b in a.date == b.date ? a.id < b.id : a.date < b.date }
                        messages[overlay.convId] = list
                    }
                }
                if batch.deleteUndo != nil {
                    optimisticMessageOverlays[i].suppressedVersion = max(optimisticMessageOverlays[i].suppressedVersion, batch.version)
                    optimisticMessageOverlays[i].suppressedHasUndo = true
                    optimisticMessageOverlays[i].suppressedUndo = deleteUndo
                    if deleteUndo != nil {
                        deleteUndo = nil
                    }
                }
            case .star(let msgId, let on):
                if convTouched,
                   var list = messages[overlay.convId],
                   let idx = list.firstIndex(where: { $0.id == msgId }) {
                    optimisticMessageOverlays[i].suppressedVersion = max(optimisticMessageOverlays[i].suppressedVersion, batch.version)
                    optimisticMessageOverlays[i].suppressedStar = (
                        list[idx].menu.starred,
                        list[idx].menu.star,
                        cachedStarredIds.contains(msgId)
                    )
                    let targetMenuStar: MessageMenu.Star = on ? .unstar : .star
                    if list[idx].menu.starred != on || list[idx].menu.star != targetMenuStar {
                        list[idx].menu.starred = on
                        list[idx].menu.star = targetMenuStar
                        messages[overlay.convId] = list
                    }
                }
                if batch.starredIds != nil {
                    optimisticMessageOverlays[i].suppressedVersion = max(optimisticMessageOverlays[i].suppressedVersion, batch.version)
                    if optimisticMessageOverlays[i].suppressedStar == nil {
                        let cur = messages[overlay.convId]?.first(where: { $0.id == msgId })
                        optimisticMessageOverlays[i].suppressedStar = (
                            cur?.menu.starred ?? on,
                            cur?.menu.star,
                            cachedStarredIds.contains(msgId)
                        )
                    }
                    if on {
                        cachedStarredIds.insert(msgId)
                    } else {
                        cachedStarredIds.remove(msgId)
                    }
                }
            }
        }
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


    internal func mapMessageConfirmAction(_ action: MessageConfirmActionRecord, convId: String) -> MessageActionConfirm.Action? {
        let list = messages[convId] ?? []
        func find(_ id: String) -> ChatMessage? {
            list.first { $0.id == id || $0.clientId == id }
        }
        switch action {
        case .deleteForMe(let msgId):
            return find(msgId).map(MessageActionConfirm.Action.deleteForMe)
        case .deleteMany(let msgIds):
            let resolved = msgIds.compactMap(find)
            return resolved.isEmpty ? nil : .deleteMany(resolved)
        case .recallMany(let msgIds):
            let resolved = msgIds.compactMap(find)
            return resolved.isEmpty ? nil : .recallMany(resolved)
        case .pin(let msgId, let replacingRef):
            return find(msgId).map { .pin($0, replacing: replacingRef ?? "") }
        case .unpin(let topicRef):
            return .unpin(ref: topicRef)
        }
    }

    internal func messageConfirmRecord(for confirm: MessageActionConfirm) -> MessageConfirmRecord {
        let actionRecord: MessageConfirmActionRecord
        switch confirm.action {
        case .deleteForMe(let msg):
            actionRecord = .deleteForMe(msgId: msg.id)
        case .deleteMany(let list):
            actionRecord = .deleteMany(msgIds: list.map(\.id))
        case .recallMany(let list):
            actionRecord = .recallMany(msgIds: list.map(\.id))
        case .pin(let msg, let replacing):
            actionRecord = .pin(msgId: msg.id, replacingRef: replacing.isEmpty ? nil : replacing)
        case .unpin(let ref):
            actionRecord = .unpin(topicRef: ref)
        }
        return MessageConfirmRecord(
            id: 0,
            convId: confirm.conversationId,
            action: actionRecord,
            title: confirm.title,
            message: confirm.message,
            ok: confirm.ok,
            destructive: confirm.destructive
        )
    }

    internal func syncAutoDeleteToCore(from oldValue: [String: Int64]?, to newValue: [String: Int64]?) {
        guard !isApplyingCoreMirror, let core = coreLifecycle.core else { return }
        let oldMap = oldValue ?? [:]
        let newMap = newValue ?? [:]
        for convId in oldMap.keys where newMap[convId] == nil {
            core.setAutoDeleteTtl(convId: convId, ttlMs: 0)
        }
        for (convId, ttl) in newMap where oldMap[convId] != ttl {
            core.setAutoDeleteTtl(convId: convId, ttlMs: ttl)
        }
    }

    internal func hostSendE2EEText(
        convId id: String,
        text: String,
        clientId cliId: String,
        quote: E2eeQuoteArgRecord?
    ) async -> E2eeSendOutcomeRecord {
        do {
            let res: SendMessageResult
            if let sendE2EETextHostHandler {
                let quoteArgs: Any = quote.map { q -> [String: Any] in
                    [
                        "msg_id": q.msgId,
                        "cli_msg_id": q.cliMsgId,
                        "sender_id": q.senderId,
                        "sender_name": q.senderName,
                        "text": q.text,
                        "ts_ms": q.tsMs,
                    ]
                } ?? NSNull()
                let args: [String: Any] = [
                    "conv_id": id,
                    "text": text,
                    "client_id": cliId,
                    "quote": quoteArgs,
                ]
                _ = traceHost("send_e2ee_text", args: args)
                res = try await sendE2EETextHostHandler(args)
            } else {
                let myUid = profile?.userId ?? ""
                guard !myUid.isEmpty else {
                    EngineLog.shared.write("sendText e2ee failed: missing local uid")
                    return .aborted
                }
                let ready = await e2eeManager.ensureSessions(
                    forPeer: id,
                    myUid: myUid,
                    webSocket: webSocket,
                    store: sqliteStore
                )
                guard ready else {
                    EngineLog.shared.write("sendText e2ee failed: no open Signal session for peer=\(id)")
                    return .aborted
                }

                let cliInt: Int64
                if let parsed = Int64(cliId) {
                    cliInt = parsed
                } else {
                    cliInt = await sessionClient.nextClientId()
                }
                let qMsgInt = quote.flatMap { Int64($0.msgId.trimmingCharacters(in: .whitespacesAndNewlines)) }
                let quoteOwner = quote.map { ZaloWireParser.stripUserPrefix($0.senderId.isEmpty ? myUid : $0.senderId) } ?? ""
                var ownerGlobalId = ""
                if quote != nil, qMsgInt != nil, qMsgInt != 0, !quoteOwner.isEmpty {
                    if let cached = cachedFriendGlobalIds[quoteOwner] {
                        ownerGlobalId = cached
                    } else {
                        ownerGlobalId = await sessionClient.encryptGlobalIds([quoteOwner])[quoteOwner] ?? ""
                    }
                    if ownerGlobalId.isEmpty {
                        EngineLog.shared.write("sendText e2ee: quote owner has no global id, sending without quote")
                    }
                }
                let hasValidQuote = (quote != nil && qMsgInt != nil && qMsgInt != 0 && !ownerGlobalId.isEmpty)
                let quotePlain = hasValidQuote ? (quote!.text.isEmpty ? "[Tin nhắn]" : quote!.text) : nil
                let ownerName = quote.map {
                    let senderClean = ZaloWireParser.stripUserPrefix($0.senderId)
                    let isMineQuote = !myUid.isEmpty && (senderClean == myUid || $0.senderId == myUid)
                    return isMineQuote ? (profile?.displayName ?? $0.senderName) : $0.senderName
                } ?? ""
                let encryptedDevices = await e2eeManager.encryptTextMessage(
                    peerUid: id,
                    myUid: myUid,
                    text: text,
                    quoteText: quotePlain,
                    quoteExtras: hasValidQuote ? ["{}", "", ownerName, ownerGlobalId] : [],
                    store: sqliteStore
                )
                guard !encryptedDevices.isEmpty else {
                    EngineLog.shared.write("sendText e2ee failed: encryption produced no peer payloads for peer=\(id)")
                    return .aborted
                }

                let senderIid = await e2eeManager.localRegistrationId()
                let imei = await sessionClient.imei
                let listParams: [[String: Any]] = encryptedDevices.compactMap { dev in
                    guard let msgCipher = dev.ciphers.first else { return nil }
                    var extra: [String: Any] = ["message": msgCipher]
                    if hasValidQuote, let qMsgInt, let quote {
                        guard let fields = Self.e2eeQuoteFields(
                            ciphers: dev.ciphers,
                            msgId: qMsgInt,
                            cliMsgId: Int64(quote.cliMsgId) ?? qMsgInt,
                            ts: quote.tsMs
                        ) else { return nil }
                        extra.merge(fields) { _, new in new }
                    }
                    return ZaloSessionClient.buildE2EEListParamEntry(
                        toId: dev.toId,
                        platform: dev.platform,
                        clientId: cliInt,
                        imei: imei,
                        registrationId: dev.registrationId,
                        senderIid: senderIid,
                        extraFields: extra
                    )
                }
                guard !listParams.isEmpty else {
                    EngineLog.shared.write("sendText e2ee failed: empty listParams for peer=\(id)")
                    return .aborted
                }
                res = try await sessionClient.sendE2EEMessageAPI(
                    endpoint: hasValidQuote ? "quote" : "sms",
                    threadId: id,
                    isGroup: false,
                    clientId: cliInt,
                    listParams: ZaloJSONArrayBox(listParams)
                )
            }
            return .sent(msgId: res.msgId, cliMsgId: res.cliMsgId, tsMs: res.tsMs)
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    internal func syncDirectMessageChangesToCore(from oldValue: [String: [ChatMessage]], to newValue: [String: [ChatMessage]]) {
        guard !isApplyingCoreMirror, !isSuppressingDirectMessageSync, let core = coreLifecycle.core else { return }
        for convId in oldValue.keys where newValue[convId] == nil {
            core.writeThroughRemoveWindow(convId: convId)
        }
        for (convId, list) in newValue where oldValue[convId] != list {
            core.writeThroughReplaceWindow(convId: convId, messages: list.map(ChatMessageRecord.init(message:)))
        }
    }

    internal func pushCoreIdentitiesIfRunning() {
        guard !isApplyingCoreMirror, let core = coreLifecycle.core else { return }
        core.updateIdentities(table: currentIdentityTableRecord())
    }

    internal func currentContactsStateRecord() -> ContactsStateRecord {
        ContactsStateRecord(
            friends: contacts.friends.map {
                FriendEntryRecord(
                    id: $0.id,
                    name: $0.name,
                    zaloName: $0.zaloName,
                    avatar: $0.avatar?.absoluteString,
                    lastActiveMs: $0.lastActive.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) },
                    online: $0.online,
                    section: $0.section,
                    sortKey: $0.sortKey
                )
            },
            groups: contacts.groups.map {
                GroupEntryRecord(
                    id: $0.id,
                    name: $0.name,
                    avatar: $0.avatar?.absoluteString,
                    members: Int64($0.members),
                    sortKey: $0.sortKey
                )
            },
            received: contacts.received.map {
                FriendRequestEntryRecord(
                    id: $0.id,
                    name: $0.name,
                    avatar: $0.avatar?.absoluteString,
                    message: $0.message,
                    timeMs: $0.date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
                )
            },
            sent: contacts.sent.map {
                FriendRequestEntryRecord(
                    id: $0.id,
                    name: $0.name,
                    avatar: $0.avatar?.absoluteString,
                    message: $0.message,
                    timeMs: $0.date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
                )
            },
            pendingRequestCount: Int64(contacts.pendingRequestCount),
            friendsLoaded: contacts.friendsLoaded,
            groupsLoaded: contacts.groupsLoaded,
            loadingRequests: contacts.loadingRequests,
            groupDetailsJson: cachedGroupDetails.map {
                StringPairEntry(key: $0.key, value: Self.jsonString(for: $0.value))
            },
            receivedRawJson: cachedReceivedRequestsRaw.isEmpty ? nil : Self.jsonArrayString(for: cachedReceivedRequestsRaw),
            sentRawJson: cachedSentRequestsRaw.isEmpty ? nil : Self.jsonArrayString(for: cachedSentRequestsRaw),
            friendGlobalIds: cachedFriendGlobalIds.map { StringPairEntry(key: $0.key, value: $0.value) }
        )
    }

    internal func pushCoreContactsIfRunning() {
        guard !isApplyingCoreMirror, let core = coreLifecycle.core else { return }
        core.seedContacts(contacts: currentContactsStateRecord())
    }

    internal func pushCoreHistoryFreshnessIfRunning() {
        guard !isApplyingCoreMirror, let core = coreLifecycle.core else { return }
        let entries = historyFreshness.map { key, val -> FreshnessMapEntry in
            let rec: HistoryFreshnessRecord = (val == .upToDate) ? .upToDate : .stale
            return FreshnessMapEntry(convId: key, freshness: rec)
        }
        core.seedHistoryFreshness(entries: entries)
    }

    internal func applyContactsMirror(_ cRec: ContactsStateRecord) {
        var next = contacts
        next.friends = cRec.friends.map { f in
            ContactsState.Friend(
                id: f.id,
                name: f.name,
                zaloName: f.zaloName,
                avatar: f.avatar.flatMap(URL.init(string:)),
                lastActive: f.lastActiveMs.map { Date(timeIntervalSince1970: Double($0) / 1000.0) },
                online: f.online,
                section: f.section,
                sortKey: f.sortKey
            )
        }
        next.groups = cRec.groups.map { g in
            ContactsState.Group(
                id: g.id,
                name: g.name,
                avatar: g.avatar.flatMap(URL.init(string:)),
                members: Int(g.members),
                sortKey: g.sortKey
            )
        }
        next.received = cRec.received.map { r in
            ContactsState.FriendRequest(
                id: r.id,
                name: r.name,
                avatar: r.avatar.flatMap(URL.init(string:)),
                message: r.message,
                date: r.timeMs.map { Date(timeIntervalSince1970: Double($0) / 1000.0) }
            )
        }
        next.sent = cRec.sent.map { r in
            ContactsState.FriendRequest(
                id: r.id,
                name: r.name,
                avatar: r.avatar.flatMap(URL.init(string:)),
                message: r.message,
                date: r.timeMs.map { Date(timeIntervalSince1970: Double($0) / 1000.0) }
            )
        }
        next.pendingRequestCount = Int(cRec.pendingRequestCount)
        next.friendsLoaded = cRec.friendsLoaded
        next.groupsLoaded = cRec.groupsLoaded
        next.loadingRequests = cRec.loadingRequests
        if next != contacts {
            contacts = next
        }

        if !cRec.groupDetailsJson.isEmpty {
            var details = cachedGroupDetails
            for pair in cRec.groupDetailsJson {
                if let parsed = JSONLossless.parseObject(string: pair.value) {
                    details[pair.key] = parsed
                }
            }
            cachedGroupDetails = details
        }
        if let recRaw = cRec.receivedRawJson,
           let data = recRaw.data(using: .utf8),
           let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            cachedReceivedRequestsRaw = arr
        }
        if let sentRaw = cRec.sentRawJson,
           let data = sentRaw.data(using: .utf8),
           let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            cachedSentRequestsRaw = arr
        }
        if !cRec.friendGlobalIds.isEmpty {
            var nextUids = cachedFriendGlobalIds
            var gidToUid: [String: String] = [:]
            for pair in cRec.friendGlobalIds where !pair.key.isEmpty && !pair.value.isEmpty {
                nextUids[pair.key] = pair.value
                gidToUid[pair.value] = pair.key
            }
            if nextUids != cachedFriendGlobalIds {
                cachedFriendGlobalIds = nextUids
            }
            if !gidToUid.isEmpty {
                let client = sessionClient
                Task { await client.seedGlobalIdMappings(gidToUid) }
            }
        }
    }

    internal func hostApplyBootstrapMutes(_ mutes: [MuteEntryRecord]) async {
        let serializedMutes: [[String: Any]] = mutes.map {
            [
                "conv_id": $0.convId,
                "start": $0.start,
                "duration": $0.duration,
            ]
        }
        if traceU4Host("apply_mutes", args: ["mutes": serializedMutes]) {
            var map = notificationSettings.mutes
            for m in mutes {
                map[m.convId] = MuteInfo(startTime: Double(m.start), duration: Double(m.duration))
            }
            notificationSettings.mutes = map
            await saveNotificationPreferences()
        }
    }

    internal func hostOnBatchReceived(
        cmd: UInt16?,
        incrementUnread: Bool,
        notifyIncoming: Bool,
        payloadJson: String
    ) async -> String? {
        let dict = JSONLossless.parseObject(string: payloadJson) ?? [:]
        let cmdArg: Any = cmd.map { Int($0) } ?? NSNull()
        guard traceHost("apply_batch", args: [
            "cmd": cmdArg,
            "increment_unread": incrementUnread,
            "notify_incoming": notifyIncoming,
            "payload": dict,
        ]) else {
            return nil
        }
        return await hostDecryptEnvelope(payloadJson: payloadJson, parsedDict: dict)
    }

    internal func hostDecryptEnvelope(payloadJson: String, parsedDict: [String: Any]? = nil) async -> String {
        let myUid = profile?.userId ?? ""
        guard !myUid.isEmpty else { return payloadJson }
        let dict = parsedDict ?? JSONLossless.parseObject(string: payloadJson) ?? [:]
        let decrypted = await e2eeManager.decryptEnvelopeIfNeeded(
            ZaloJSONBox(dict),
            myUid: myUid,
            store: sqliteStore
        )
        return Self.jsonString(for: decrypted.dict)
    }

    internal func syncCachedIdentityPreferencesFromStore() async {
        guard let store = sqliteStore else { return }
        let aliasesData = try? await store.getPreferenceData(key: "aliases")
        let profData = try? await store.getPreferenceData(key: "cachedProfiles")
        let grpData = try? await store.getPreferenceData(key: "cachedGroups")
        let ranksData = try? await store.getPreferenceData(key: "activityRanks")
        let gidData = try? await store.getPreferenceData(key: "gidToUidMap")

        isApplyingCoreMirror = true
        defer { isApplyingCoreMirror = false }

        if let aliasesData,
           let dict = (try? JSONSerialization.jsonObject(with: aliasesData)) as? [String: String] {
            cachedAliases = dict
        }
        if let profData,
           let decoded = try? JSONDecoder().decode([String: ZaloWebKitMigrator.CachedProfile].self, from: profData) {
            cachedProfiles = decoded
        }
        if let grpData,
           let decoded = try? JSONDecoder().decode([String: ZaloWebKitMigrator.CachedGroup].self, from: grpData) {
            cachedGroups = decoded
        }
        if let ranksData,
           let rawRanks = (try? JSONSerialization.jsonObject(with: ranksData)) as? [String: Any] {
            var parsed: [String: Int64] = [:]
            for (k, v) in rawRanks {
                if let val = JSONLossless.int64(v), val > 0 { parsed[k] = val }
            }
            cachedActivityRanks = parsed
        }
        if let gidData,
           let gidToUid = (try? JSONSerialization.jsonObject(with: gidData)) as? [String: String] {
            await sessionClient.seedGlobalIdMappings(gidToUid)
            for (gid, uid) in gidToUid where !gid.isEmpty && !uid.isEmpty {
                cachedFriendGlobalIds[uid] = gid
            }
        }
    }

    internal static func jsonArrayString(for array: [[String: Any]]) -> String {
        guard JSONSerialization.isValidJSONObject(array),
              let data = try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return str
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

    internal func commitPreviewOverrideToCore(_ overrideRec: ConvPreviewOverrideRecord) async {
        if let core = coreLifecycle.core {
            if let v = try? await core.applyPreviewOverride(overrideRec: overrideRec) {
                await waitForMirrorVersion(v)
            }
            return
        }
        let prevBefore = conversations.first(where: { $0.id == overrideRec.convId })?.preview
        let batch = offlineConversationsCore().applyPreviewOverride(overrideRec: overrideRec)
        applyCoreChanges(batch)
        await persistConversationsToSQLite()
        if let conv = conversations.first(where: { $0.id == overrideRec.convId }), prevBefore != conv.preview {
            let previewText = conv.preview?.text ?? ""
            let previewTsMs = conv.preview?.date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? 0
            let previewFromMe = conv.preview?.fromMe ?? false
            try? await sqliteStore?.setConversationPreview(
                id: overrideRec.convId,
                previewText: previewText,
                previewTsMs: previewTsMs,
                previewFromMe: previewFromMe
            )
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
