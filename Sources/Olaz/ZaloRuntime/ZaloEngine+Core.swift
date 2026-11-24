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

    func startWs(endpoints: [String], zpwSek: String) async {
        guard let engine else { return }
        await engine.sessionClient.syncMirrorFromCoreSession()
        await MainActor.run {
            engine.startWebSocketLoop(endpoints: endpoints, zpwSek: zpwSek)
        }
    }

    func startLongPoll() async {
        guard let engine else { return }
        await MainActor.run {
            engine.startLongPollLoop()
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

            guard self.coreLifecycle.install(core: core, changeTask: changeTask) else {
                changeTask.cancel()
                core.stop()
                self.pendingCoreCommands.removeAll()
                self.failAllMirrorWaiters()
                self.coreLifecycle.finishAllGates()
                return nil
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
        failAllMirrorWaiters()
    }

    internal func hostNotePrepareStoreStarted() {
        // Shape-only hook; keeps MainActor visibility clean if future domains log transitions.
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

        if batch.version > appliedMirrorVersion {
            appliedMirrorVersion = batch.version
        }
        resumeMirrorWaiters(upTo: appliedMirrorVersion)
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

    private func waitForMirrorVersion(_ target: UInt64) async {
        guard appliedMirrorVersion < target else { return }
        await withCheckedContinuation { continuation in
            if appliedMirrorVersion >= target {
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
