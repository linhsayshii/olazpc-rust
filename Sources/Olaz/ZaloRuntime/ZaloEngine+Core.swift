import Foundation
import OlazCore
import os

/// Thread-safe holder for the `CoreEngine` handle and its `@MainActor` change-mirror task so
/// `ZaloEngine.deinit` (nonisolated) can cleanly stop the Rust actor without racing with init.
final class CoreEngineLifecycle: Sendable {
    private struct State: @unchecked Sendable {
        var core: CoreEngine?
        var changeTask: Task<Void, Never>?
        var isShutDown = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var core: CoreEngine? {
        state.withLock { $0.core }
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

    /// Stops the Rust actor and cancels the change-mirror loop. Safe to call from `deinit`.
    func shutdown() {
        let (core, task): (CoreEngine?, Task<Void, Never>?) = state.withLock { st in
            st.isShutDown = true
            let c = st.core
            let t = st.changeTask
            st.core = nil
            st.changeTask = nil
            return (c, t)
        }
        task?.cancel()
        core?.stop()
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
        let store = await MainActor.run { engine.sqliteStore }
        try? await store?.setPreferenceString(key: key, value: value)
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
    }

    func offerFirstLoginTransfer(force: Bool) async {
        guard let engine else { return }
        await engine.offerFirstLoginTransferIfNeeded(forceOffer: force)
    }

    func resetDomains() async {
        guard let engine else { return }
        await engine.hostResetDomains()
    }

    func persistSession(snapshotJson: String) async {
        guard let engine else { return }
        await engine.sessionClient.saveSessionFromCore(snapshotJSON: snapshotJson)
    }

    func clearSession() async {
        guard let engine else { return }
        await engine.sessionClient.clearSessionStorage()
    }

    func markExpired(snapshotJson: String) async {
        guard let engine else { return }
        await engine.sessionClient.markExpiredFromCore(snapshotJSON: snapshotJson)
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
        if let existingTask = coreInitTask {
            return await existingTask.value
        }

        let initTask = Task<CoreEngine?, Never> { @MainActor [weak self] in
            guard let self else { return nil }
            guard let coreSession = await self.sessionClient.sharedCoreSession() else {
                EngineLog.shared.write("core: failed to create shared CoreSession")
                return nil
            }
            let host = ZaloEngineCoreHost(engine: self)
            guard let core = try? CoreEngine(session: coreSession, host: host) else {
                EngineLog.shared.write("core: failed to start CoreEngine")
                return nil
            }

            let changeTask = Task { @MainActor [weak self, core] in
                while !Task.isCancelled {
                    do {
                        guard let batch = try await core.nextChanges() else { break }
                        guard let self else { break }
                        self.applyCoreChanges(batch)
                    } catch {
                        break
                    }
                }
                self?.failAllMirrorWaiters()
            }

            guard self.coreLifecycle.install(core: core, changeTask: changeTask) else {
                changeTask.cancel()
                core.stop()
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
        if let core = coreLifecycle.core, pendingCoreCommands.isEmpty {
            Self.sendCommand(command, to: core)
            return
        }
        pendingCoreCommands.append(command)
        Task { @MainActor [weak self] in
            _ = await self?.ensureCoreEngine()
        }
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
                clientVersion: "694 (Native)"
            )
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
