import Foundation

private actor SyncConcurrencyLimiter {
    private let maxConcurrent: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }

    func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            running = max(0, running - 1)
        }
    }
}

private let syncBatchDownloadLimiter = SyncConcurrencyLimiter(maxConcurrent: 6)
private let syncBatchIngestLimiter = SyncConcurrencyLimiter(maxConcurrent: 2)

struct SyncStage2ProgressState: Sendable, Equatable {
    var activeSyncId: String = ""
    var totalPartitions: Int = 0
    var completedPartitionsBeforeChunk: Int = 0
    var currentChunkPartitionCount: Int = 0
    var chunkIndex: Int = 0
    var totalChunks: Int = 1
    var cumulativeMessagesBeforeChunk: Int = 0
    var cumulativeConvIdsBeforeChunk: Set<String> = []
}

// Phone → PC message transfer (`SyncFull` v2 `cmd 590`/`591` + in-process `JSRuntime` `libzproto` + server catch-up).
extension ZaloEngine {
    func respondToTransfer(accept: Bool) {
        if accept {
            startTransfer()
        } else {
            cancelTransfer()
        }
    }

    /// Hides the transfer overlay while letting any active sync finish in the background.
    func dismissTransfer() {
        Task { [weak self] in
            try? await self?.sqliteStore?.setPreferenceString(key: "didOfferInitialSync", value: "1")
        }
        if transferTask != nil {
            isTransferHidden = true
            transfer = nil
        } else {
            isTransferHidden = false
            transfer = nil
        }
    }

    func cancelTransfer() {
        transferTask?.cancel()
        transferTask = nil
        batchImportTask?.cancel()
        batchImportTask = nil
        activeSyncBatchTasks.values.forEach { $0.cancel() }
        activeSyncBatchTasks = [:]
        isTransferHidden = false
        phoneSyncStatusSignal = nil
        transfer = nil
        Task { [weak self] in
            guard let self else { return }
            try? await self.sqliteStore?.setPreferenceString(key: "didOfferInitialSync", value: "1")
            let activeIds = await self.phoneSync.activeSyncIds()
            await self.phoneSync.resetAll()
            for sid in activeIds {
                await self.ackDeleteSyncSession(syncId: sid, reason: 2)
            }
        }
    }

    internal func offerFirstLoginTransferIfNeeded(forceOffer: Bool = false) async {
        if !traceHost("offer_first_login_transfer", args: ["force": forceOffer]) {
            return
        }
        guard transfer == nil, transferTask == nil else { return }
        if !forceOffer {
            if (try? await sqliteStore?.getPreferenceString(key: "didOfferInitialSync")) == "1" {
                return
            }
            var existingMsgCount = 0
            for list in messages.values {
                existingMsgCount += list.count
                if existingMsgCount >= 20 {
                    try? await sqliteStore?.setPreferenceString(key: "didOfferInitialSync", value: "1")
                    return
                }
            }
        }
        try? await sqliteStore?.setPreferenceString(key: "didOfferInitialSync", value: "1")
        transfer = MessageTransferState(
            phase: .offer,
            progress: nil,
            syncedConversations: 0,
            totalConversations: nil,
            message: "Đồng bộ toàn bộ cuộc trò chuyện và tin nhắn từ Zalo trên điện thoại về máy tính."
        )
    }

    private func ackDeleteSyncSession(syncId: String, reason: Int = 0) async {
        guard !syncId.isEmpty, await webSocket.isAuthed else { return }
        _ = await webSocket.sendRequestFrame(
            cmd: ZaloWebSocket.cmdSyncAckDelete,
            subCmd: 0,
            version: 1,
            innerData: ZaloJSONBox([
                "syncId": syncId,
                "toDevice": 0,
                "reason": reason,
            ]),
            timeoutSeconds: 3
        )
    }

    private func updateTransferUI(_ state: MessageTransferState) {
        guard !isTransferHidden else { return }
        if transfer != state {
            transfer = state
        }
    }

    private func loadAndPersistSyncIdentityKey() async {
        if let store = sqliteStore,
           let savedData = try? await store.getPreferenceData(key: "syncIdentityKey"),
           let savedKey = try? JSONDecoder().decode(ZaloPhoneSyncCoordinator.PersistedIdentityKey.self, from: savedData) {
            await phoneSync.loadIdentityKey(savedKey)
        }
    }

    private func saveCurrentSyncIdentityKey() async {
        guard let store = sqliteStore,
              let key = await phoneSync.currentIdentityKey(),
              let data = try? JSONEncoder().encode(key) else {
            return
        }
        try? await store.setPreferenceData(key: "syncIdentityKey", data: data)
    }

    private func awaitAllActiveSyncBatchTasks() async {
        while !activeSyncBatchTasks.isEmpty && !Task.isCancelled {
            let pending = Array(activeSyncBatchTasks.values)
            for t in pending {
                _ = await t.value
            }
        }
        if let activeBatch = batchImportTask {
            _ = await activeBatch.value
        }
    }

    func startTransfer(requestPhoneSync: Bool = true) {
        transferTask?.cancel()
        batchImportTask?.cancel()
        batchImportTask = nil
        activeSyncBatchTasks.values.forEach { $0.cancel() }
        activeSyncBatchTasks = [:]
        phoneSyncConvTimestamps = [:]
        syncAttemptedProfileUids = []
        syncStage2Progress = SyncStage2ProgressState()
        syncInitialEmptyDB = false
        lastSyncConvFlushAt = .distantPast
        isTransferHidden = false
        phoneSyncStatusSignal = nil
        canStartTransfer = true
        transferStartBlockedReason = nil

        transfer = MessageTransferState(
            phase: .transferring,
            progress: 0.04,
            syncedConversations: 0,
            totalConversations: nil,
            message: "Đang chuẩn bị danh sách hội thoại…",
            stage: "conversationList",
            stageIndex: 1,
            stageCount: 3,
            stageProgress: 0.1,
            receivedMessages: 0,
            errorCode: nil,
            errorName: nil,
            canRetry: false,
            officialTitle: nil,
            officialDescription: nil,
            officialSuggestion: nil
        )

        transferTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isTransferHidden = false
            }

            await self.phoneSync.resetAll()
            await self.loadAndPersistSyncIdentityKey()
            let hadMessagesBeforeSync = (try? await self.sqliteStore?.hasAnyMessages()) ?? true
            self.syncInitialEmptyDB = !hadMessagesBeforeSync

            // Guard against an invalid/kicked session before prompting the phone.
            do {
                _ = try await self.sessionClient.fetchAliases()
            } catch let err as ZaloSessionError where err.isAuthError {
                self.handleSessionExpiredNotice("Phiên đăng nhập không hợp lệ hoặc đã hết hạn. Vui lòng quét mã QR để đăng nhập lại.")
                return
            } catch {}
            if Task.isCancelled { return }

            await self.performContactsSync()
            if Task.isCancelled { return }

            let myUid = self.profile?.userId ?? ""
            if !myUid.isEmpty {
                let ownMap = await self.sessionClient.encryptGlobalIds([myUid])
                if let myGid = ownMap[myUid], !myGid.isEmpty {
                    await self.phoneSync.setOwnGlobalId(myGid)
                }
            }

            var phoneImportedTotal = 0
            var phoneSyncedConvCount = 0
            var plannedPartitionCount = 0
            var msgAckFailureCode: Int64?
            var ussidx = 0

            if requestPhoneSync {
                // Ensure WS is authenticated (wait up to 8s if just connecting) and give transfer_after_login a brief window.
                let wsWaitDeadline = Date().addingTimeInterval(8.0)
                while !(await self.webSocket.isAuthed), Date() < wsWaitDeadline {
                    if Task.isCancelled { return }
                    try? await Task.sleep(for: .milliseconds(200))
                }
                if await self.webSocket.isAuthed, await self.phoneSync.latestTempKey.isEmpty {
                    let tkDeadline = Date().addingTimeInterval(1.0)
                    while await self.phoneSync.latestTempKey.isEmpty, Date() < tkDeadline {
                        if Task.isCancelled { return }
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                }

                let diag = ZaloPhoneSync.diagnostics()
                let wasmReady = await self.phoneSync.prepareWasm()
                let wsAuthed = await self.webSocket.isAuthed
                EngineLog.shared.write("sync-v2: init wasm=\(wasmReady) wasm_bytes=\(diag.wasmBytes) zstd=\(diag.zstdAvailable)(\(diag.zstdBackend ?? "none")) ws=\(wsAuthed)")

                if !wasmReady {
                    self.transferStartBlockedReason = "WASM_UNAVAILABLE"
                    await self.failTransfer(
                        name: "WASM_UNAVAILABLE",
                        synced: 0,
                        total: nil,
                        received: 0
                    )
                    return
                }

                if wasmReady && wsAuthed {
                    let snap = await self.sessionClient.currentSnapshot()
                    var phoneAnswered = false

                    // --- STAGE 1: Sync full conversation list (`type: "conversation"`, `ussidx = 0`) ---
                    self.updateTransferUI(MessageTransferState(
                        phase: .waitingForPhone,
                        progress: 0.06,
                        syncedConversations: 0,
                        totalConversations: nil,
                        message: "Mở Zalo trên điện thoại và bấm “Đồng bộ ngay”.",
                        stage: "confirmMobile",
                        stageIndex: 1,
                        stageCount: 3,
                        stageProgress: 0.05,
                        receivedMessages: 0
                    ))

                    if let convReg = try? await self.phoneSync.registerConversationRequest(
                        deviceName: snap.computerName,
                        ussidx: ussidx
                    ) {
                        ussidx += 1
                        await self.saveCurrentSyncIdentityKey()

                        let ackBox = await self.webSocket.sendRequestFrame(
                            cmd: ZaloWebSocket.cmdSyncRequest,
                            subCmd: 0,
                            version: 1,
                            innerData: convReg.innerData,
                            timeoutSeconds: 12
                        )
                        let ackCode = JSONLossless.int64(ackBox?.dict["error_code"]) ?? -1
                        EngineLog.shared.write("sync-v2: conv request sync=\(String(convReg.syncId.prefix(8))) ack_code=\(ackCode)")

                        if ackBox != nil && ackCode == 0 {
                            let convWait = await self.waitSyncSessionCompletion(
                                syncId: convReg.syncId,
                                unansweredLimit: 120.0,
                                phoneAlreadyAnswered: false
                            )
                            switch convWait.outcome {
                            case .rejected:
                                await self.failTransfer(name: "USER_REJECT_BACKUP", synced: 0, total: nil, received: 0)
                                return
                            case .busy:
                                await self.failTransfer(name: "MOBILE_BUSY", synced: 0, total: nil, received: 0)
                                return
                            case .timedOutUnconfirmed:
                                await self.failTransfer(name: "USER_DONT_CONFIRM", synced: 0, total: nil, received: 0)
                                return
                            case .completed:
                                phoneAnswered = true
                            }
                            await self.awaitAllActiveSyncBatchTasks()
                            let convSnap = await self.phoneSync.requestSnapshot(syncId: convReg.syncId)
                            EngineLog.shared.write("sync-v2: chunk done ussidx=0 msgs=\(convSnap?.importedCount ?? 0) convs=\(self.phoneSyncConvTimestamps.count) reason=\(convWait.reason)")
                            await self.ackDeleteSyncSession(syncId: convReg.syncId, reason: 0)
                            await self.phoneSync.removeRequest(syncId: convReg.syncId)
                        } else {
                            await self.phoneSync.removeRequest(syncId: convReg.syncId)
                        }
                    }

                    if Task.isCancelled { return }

                    // Build ordered conversation list (now enriched by Stage 1 phone conversations!).
                    let selfConv = self.selfConversationId
                    var orderedThreads: [(id: String, isGroup: Bool)] = []
                    var seenKeys = Set<String>()
                    func appendThread(id: String, isGroup: Bool) {
                        guard !id.isEmpty, id != selfConv else { return }
                        let k = "\(isGroup ? "g" : "u"):\(id)"
                        if seenKeys.insert(k).inserted {
                            orderedThreads.append((id: id, isGroup: isGroup))
                        }
                    }
                    for c in self.conversations {
                        appendThread(id: c.id, isGroup: c.isGroup)
                    }
                    for g in self.contacts.groups {
                        appendThread(id: g.id, isGroup: true)
                    }
                    for f in self.contacts.friends {
                        appendThread(id: f.id, isGroup: false)
                    }

                    // Ensure globalIds exist for all 1-1 threads (friends + strangers discovered in Stage 1).
                    let allOneOneUids = orderedThreads.filter { !$0.isGroup }.map(\.id)
                    let missingOneOneUids = allOneOneUids.filter { self.cachedFriendGlobalIds[$0] == nil }
                    if !missingOneOneUids.isEmpty {
                        let encryptedMap = await self.sessionClient.encryptGlobalIds(missingOneOneUids)
                        if !encryptedMap.isEmpty {
                            self.cachedFriendGlobalIds.merge(encryptedMap) { _, new in new }
                            await self.persistGlobalIdCacheToSQLite()
                        }
                    }

                    var groupGlobalIds: [String: String] = [:]
                    for (cleanGrid, info) in self.cachedGroupDetails {
                        let gid = JSONLossless.string(info["globalId"])
                        if !gid.isEmpty {
                            groupGlobalIds[cleanGrid] = gid
                        }
                    }

                    let plan = ZaloPhoneSync.buildPlan(
                        conversations: orderedThreads,
                        userGlobalIds: self.cachedFriendGlobalIds,
                        groupGlobalIds: groupGlobalIds,
                        send2MeId: self.selfConversationId,
                        phoneTimestamps: self.phoneSyncConvTimestamps
                    )
                    plannedPartitionCount = plan.partitions.count
                    EngineLog.shared.write("sync-v2: msg plan_partitions=\(plan.partitions.count) skipped=\(plan.skipped)")

                    // --- STAGE 2: Sync messages (`type: "message"`, `ussidx = 1..N`) ---
                    if !plan.partitions.isEmpty {
                        var effectiveBatchSize = ZaloPhoneSync.partitionsPerRequest
                        var offset = 0
                        var chunkIndex = 0
                        var cumulativeMessages = 0
                        var cumulativeConvs = Set<String>()

                        while offset < plan.partitions.count {
                            if Task.isCancelled { return }
                            guard await self.webSocket.isAuthed else { break }

                            let end = min(offset + effectiveBatchSize, plan.partitions.count)
                            let chunk = Array(plan.partitions[offset..<end])
                            let remainingChunks = max(1, (plan.partitions.count - offset + effectiveBatchSize - 1) / effectiveBatchSize)
                            let totalChunks = chunkIndex + remainingChunks
                            let chunkUssidx = ussidx

                            let reg: (syncId: String, innerData: ZaloJSONBox)
                            do {
                                reg = try await self.phoneSync.registerChunkRequest(
                                    chunk: chunk,
                                    globalIdToUserId: plan.globalIdToUserId,
                                    deviceName: snap.computerName,
                                    ussidx: ussidx
                                )
                                ussidx += 1
                            } catch {
                                EngineLog.shared.write("sync-v2: registerChunk failed \(error.localizedDescription)")
                                break
                            }

                            self.syncStage2Progress = SyncStage2ProgressState(
                                activeSyncId: reg.syncId,
                                totalPartitions: plan.partitions.count,
                                completedPartitionsBeforeChunk: offset,
                                currentChunkPartitionCount: chunk.count,
                                chunkIndex: chunkIndex,
                                totalChunks: totalChunks,
                                cumulativeMessagesBeforeChunk: cumulativeMessages,
                                cumulativeConvIdsBeforeChunk: cumulativeConvs
                            )

                            let ackBox = await self.webSocket.sendRequestFrame(
                                cmd: ZaloWebSocket.cmdSyncRequest,
                                subCmd: 0,
                                version: 1,
                                innerData: reg.innerData,
                                timeoutSeconds: 12
                            )
                            let ackCode = JSONLossless.int64(ackBox?.dict["error_code"]) ?? -1
                            let ackMsg = JSONLossless.string(ackBox?.dict["error_message"])
                            EngineLog.shared.write("sync-v2: msg request sync=\(String(reg.syncId.prefix(8))) ussidx=\(chunkUssidx) parts=\(chunk.count) ack_code=\(ackCode) msg=\(ackMsg)")
                            guard ackBox != nil, ackCode == 0 else {
                                await self.phoneSync.removeRequest(syncId: reg.syncId)
                                if effectiveBatchSize > 10 && ackCode != 211 {
                                    effectiveBatchSize = 10
                                    EngineLog.shared.write("sync-v2: retrying msg request with smaller batchSize=\(effectiveBatchSize)")
                                    continue
                                }
                                msgAckFailureCode = ackCode
                                break
                            }
                            msgAckFailureCode = nil
                            offset = end

                            let initialProg = Self.computeStage2BatchProgress(
                                completedPartitionsBeforeChunk: self.syncStage2Progress.completedPartitionsBeforeChunk,
                                currentChunkPartitions: chunk.count,
                                totalPartitions: plan.partitions.count,
                                batchesCompletedInChunk: 0,
                                expectedBatchesInChunk: nil,
                                previousProgress: self.transfer?.progress
                            )
                            if phoneAnswered {
                                self.updateTransferUI(MessageTransferState(
                                    phase: .transferring,
                                    progress: initialProg.progress,
                                    syncedConversations: cumulativeConvs.count,
                                    totalConversations: plan.partitions.count,
                                    message: "Đang nhận tin nhắn từ điện thoại (\(chunkIndex + 1)/\(totalChunks))…",
                                    stage: "messages",
                                    stageIndex: 2,
                                    stageCount: 3,
                                    stageProgress: initialProg.stageProgress,
                                    receivedMessages: cumulativeMessages
                                ))
                            }

                            let waitResult = await self.waitSyncSessionCompletion(
                                syncId: reg.syncId,
                                unansweredLimit: 120.0,
                                phoneAlreadyAnswered: phoneAnswered
                            )
                            await self.awaitAllActiveSyncBatchTasks()
                            let snapDone = await self.phoneSync.requestSnapshot(syncId: reg.syncId)
                            if let snapDone {
                                cumulativeMessages += snapDone.importedCount
                                phoneImportedTotal = cumulativeMessages
                                cumulativeConvs.formUnion(snapDone.syncedConvIds)
                            }
                            phoneSyncedConvCount = max(phoneSyncedConvCount, cumulativeConvs.count)
                            EngineLog.shared.write("sync-v2: chunk done ussidx=\(chunkUssidx) msgs=\(snapDone?.importedCount ?? 0) convs=\(snapDone?.syncedConversationsCount ?? 0) reason=\(waitResult.reason)")
                            await self.ackDeleteSyncSession(syncId: reg.syncId, reason: 0)
                            await self.phoneSync.removeRequest(syncId: reg.syncId)
                            chunkIndex += 1

                            switch waitResult.outcome {
                            case .rejected:
                                await self.failTransfer(name: "USER_REJECT_BACKUP", synced: phoneSyncedConvCount, total: plan.partitions.count, received: phoneImportedTotal)
                                return
                            case .busy:
                                await self.failTransfer(name: "MOBILE_BUSY", synced: phoneSyncedConvCount, total: plan.partitions.count, received: phoneImportedTotal)
                                return
                            case .timedOutUnconfirmed:
                                await self.failTransfer(name: "USER_DONT_CONFIRM", synced: phoneSyncedConvCount, total: plan.partitions.count, received: phoneImportedTotal)
                                return
                            case .completed:
                                phoneAnswered = true
                            }
                        }
                        self.syncStage2Progress = SyncStage2ProgressState()
                        self.flushSyncedConversationsNow()
                        await self.persistConversationsToSQLite()
                    }
                    await self.phoneSync.resetAll()
                }
            }

            if Task.isCancelled { return }

            // --- STAGE 3: Drain HTTP long-polling + Preload + Fast Group Cloud Batch (`/api/cm/mget`) ---
            var received = phoneImportedTotal
            received += await self.drainChatPolling(maxBatches: 5, notifyIncoming: false)
            if let preloadAll = try? await self.sessionClient.fetchPreloadConversations(threadIds: []) {
                received += await self.applyBatchResponse(preloadAll.dict, incrementUnread: false)
            }

            if let selfId = self.selfConversationId, !selfId.isEmpty {
                received += await self.fetchAndMergeHistory(convId: selfId, beforeMsgId: nil, isOld: false, count: 50)
            }

            let allGroups = self.contacts.groups.map(\.id)
            let groupBatchSize = 8
            for offset in stride(from: 0, to: allGroups.count, by: groupBatchSize) {
                if Task.isCancelled { return }
                let end = min(offset + groupBatchSize, allGroups.count)
                let slice = Array(allGroups[offset..<end])
                let client = self.sessionClient
                let boxes = await withTaskGroup(of: (String, ZaloJSONBox?).self) { group in
                    for gid in slice {
                        group.addTask {
                            return (gid, try? await client.fetchHistory(convId: gid, lastMsgId: nil, count: 50, isOld: false))
                        }
                    }
                    var out: [(String, ZaloJSONBox?)] = []
                    for await pair in group { out.append(pair) }
                    return out
                }
                for (gid, box) in boxes {
                    if let box {
                        received += await self.applyBatchResponse(box.dict, fallbackConvId: gid, isGroupHint: true, incrementUnread: false)
                    }
                }
                let ratio = Double(end) / Double(max(1, allGroups.count))
                self.updateTransferUI(MessageTransferState(
                    phase: .transferring,
                    progress: 0.75 + ratio * 0.22,
                    syncedConversations: max(phoneSyncedConvCount, end),
                    totalConversations: max(1, self.conversations.count),
                    message: "Đang tải lịch sử nhóm & Cloud (\(end)/\(allGroups.count))…",
                    stage: "otherMessages",
                    stageIndex: 3,
                    stageCount: 3,
                    stageProgress: ratio,
                    receivedMessages: received
                ))
            }

            await self.resolveMissingConversationNames()
            self.ensureKnownContactsInConversations()
            self.rebuildConversationFlags()
            self.rebuildConversationExtras()
            await self.persistConversationsToSQLite()
            if Task.isCancelled { return }

            if requestPhoneSync, plannedPartitionCount > 0, phoneImportedTotal == 0, let failCode = msgAckFailureCode {
                await self.failTransfer(
                    name: failCode == 211 ? "MOBILE_BUSY" : "NET_ERROR_\(failCode)",
                    synced: phoneSyncedConvCount,
                    total: plannedPartitionCount,
                    received: received
                )
                return
            }

            self.updateTransferUI(MessageTransferState(
                phase: .finished,
                progress: 1.0,
                syncedConversations: self.conversations.count,
                totalConversations: self.conversations.count,
                message: phoneImportedTotal > 0 ? "Đồng bộ hoàn tất (\(phoneImportedTotal) tin nhắn từ điện thoại)." : "Đồng bộ hoàn tất.",
                stage: nil,
                stageIndex: 3,
                stageCount: 3,
                stageProgress: 1.0,
                receivedMessages: received,
                errorCode: nil,
                errorName: nil,
                canRetry: false,
                officialTitle: nil,
                officialDescription: nil,
                officialSuggestion: nil
            ))
            self.transferTask = nil
        }
    }

    internal enum SyncWaitOutcome: Sendable, Equatable {
        case completed
        case rejected
        case busy
        case timedOutUnconfirmed
    }

    internal enum SyncWaitStepDecision: Sendable, Equatable {
        case keepWaiting(answeredAt: Date?)
        case finished(outcome: SyncWaitOutcome, reason: String)
    }

    nonisolated static func evaluateWaitStep(
        signal: ZaloMobileSyncEvent?,
        snapshot: SyncRequestSnapshot?,
        now: Date,
        start: Date,
        answeredAt: Date?,
        unansweredLimit: TimeInterval = 120.0,
        chunkCeiling: TimeInterval = 180.0,
        idleThreshold: TimeInterval = 4.0,
        emptyChunkTimeout: TimeInterval = 8.0,
        maxIdleAfterActivity: TimeInterval = 15.0
    ) -> SyncWaitStepDecision {
        if case .userRejected? = signal {
            return .finished(outcome: .rejected, reason: "user_rejected")
        }
        if case .mobileBusy? = signal {
            return .finished(outcome: .busy, reason: "mobile_busy")
        }

        let becameAnswered = (signal == .userConfirmed)
            || ((snapshot?.batchesCount ?? 0) > 0)
            || ((snapshot?.inFlightCount ?? 0) > 0)
        let effectiveAnsweredAt = answeredAt ?? (becameAnswered ? now : nil)

        guard let ansAt = effectiveAnsweredAt else {
            if now.timeIntervalSince(start) > unansweredLimit {
                return .finished(outcome: .timedOutUnconfirmed, reason: "unconfirmed_timeout")
            }
            return .keepWaiting(answeredAt: nil)
        }

        let answeredElapsed = now.timeIntervalSince(ansAt)
        if let reqSnap = snapshot {
            if reqSnap.isFulfilled {
                return .finished(outcome: .completed, reason: "fulfilled")
            }
            if reqSnap.inFlightCount == 0 {
                let idle = reqSnap.lastActivity.map { now.timeIntervalSince($0) }
                if reqSnap.batchesCount > 0 {
                    if reqSnap.lastSeen {
                        return .finished(outcome: .completed, reason: "last_seen")
                    }
                    if let idle {
                        if idle > idleThreshold {
                            return .finished(outcome: .completed, reason: "idle_after_batches")
                        }
                    } else if answeredElapsed > idleThreshold {
                        return .finished(outcome: .completed, reason: "idle_after_batches")
                    }
                } else if answeredElapsed > emptyChunkTimeout {
                    if idle == nil || (idle ?? 0) > idleThreshold {
                        return .finished(outcome: .completed, reason: "empty_chunk_timeout")
                    }
                }
            } else {
                // `inFlightCount > 0`: keep waiting while active or within recent activity window, up to ceiling.
                let idle = reqSnap.lastActivity.map { now.timeIntervalSince($0) } ?? answeredElapsed
                if answeredElapsed > chunkCeiling && idle > maxIdleAfterActivity {
                    return .finished(outcome: .completed, reason: "ceiling_timeout")
                }
            }
        } else if answeredElapsed > emptyChunkTimeout {
            return .finished(outcome: .completed, reason: "missing_snapshot")
        }

        if answeredElapsed > chunkCeiling {
            return .finished(outcome: .completed, reason: "ceiling_timeout")
        }
        return .keepWaiting(answeredAt: ansAt)
    }

    nonisolated static func computeStage2BatchProgress(
        completedPartitionsBeforeChunk: Int,
        currentChunkPartitions: Int,
        totalPartitions: Int,
        batchesCompletedInChunk: Int,
        expectedBatchesInChunk: Int?,
        previousProgress: Double?
    ) -> (progress: Double, stageProgress: Double) {
        let safeTotal = max(1, totalPartitions)
        let baseFrac = min(1.0, max(0.0, Double(completedPartitionsBeforeChunk) / Double(safeTotal)))
        let chunkWeight = min(1.0 - baseFrac, max(0.0, Double(currentChunkPartitions) / Double(safeTotal)))
        let intraFrac: Double = {
            if let expected = expectedBatchesInChunk, expected > 0 {
                return min(1.0, max(0.0, Double(batchesCompletedInChunk) / Double(expected)))
            }
            let b = Double(max(0, batchesCompletedInChunk))
            if b <= 0 { return 0.0 }
            return min(0.95, b / (b + 12.0))
        }()
        let stageFrac = min(1.0, max(0.0, baseFrac + chunkWeight * intraFrac))
        let rawProgress = 0.14 + stageFrac * 0.58
        let prevClamped = min(0.72, max(0.14, previousProgress ?? 0.14))
        let progress = min(0.72, max(prevClamped, rawProgress))
        return (progress: progress, stageProgress: stageFrac)
    }

    private func waitSyncSessionCompletion(
        syncId: String,
        unansweredLimit: TimeInterval = 120.0,
        phoneAlreadyAnswered: Bool
    ) async -> (outcome: SyncWaitOutcome, reason: String) {
        let start = Date()
        var answeredAt: Date? = phoneAlreadyAnswered ? start : nil
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(80))
            if Task.isCancelled { return (.completed, "cancelled") }

            let reqSnap = await phoneSync.requestSnapshot(syncId: syncId)
            let decision = Self.evaluateWaitStep(
                signal: phoneSyncStatusSignal,
                snapshot: reqSnap,
                now: Date(),
                start: start,
                answeredAt: answeredAt,
                unansweredLimit: unansweredLimit
            )
            switch decision {
            case .keepWaiting(let nextAnsweredAt):
                answeredAt = nextAnsweredAt
            case .finished(let outcome, let reason):
                return (outcome, reason)
            }
        }
        return (.completed, "cancelled")
    }

    private func failTransfer(name: String, synced: Int, total: Int?, received: Int) async {
        isTransferHidden = false
        let text = Self.transferErrorText(code: nil, name: name)
        transfer = MessageTransferState(
            phase: .failed(text),
            progress: nil,
            syncedConversations: synced,
            totalConversations: total,
            message: text,
            stage: "confirmMobile",
            stageIndex: 2,
            stageCount: 3,
            stageProgress: nil,
            receivedMessages: received,
            errorCode: nil,
            errorName: name,
            canRetry: true
        )
        let activeIds = await phoneSync.activeSyncIds()
        await phoneSync.resetAll()
        for sid in activeIds {
            await ackDeleteSyncSession(syncId: sid, reason: 2)
        }
        transferTask = nil
    }

    internal func persistGlobalIdCacheToSQLite() async {
        guard let store = sqliteStore else { return }
        let gidToUid = await sessionClient.exportedGlobalIdMappings()
        if !gidToUid.isEmpty, let data = try? JSONSerialization.data(withJSONObject: gidToUid) {
            try? await store.setPreferenceData(key: "gidToUidMap", data: data)
        }
    }

    // MARK: - Sync v2 Control Event & Batch Handling

    func processMobileSyncEvents(_ events: [ZaloMobileSyncEvent]) async {
        for ev in events {
            switch ev {
            case .transferAfterLogin(let tempKey):
                await phoneSync.setLatestTempKey(tempKey)
                canStartTransfer = true
                transferStartBlockedReason = nil
                EngineLog.shared.write("sync-v2: transfer_after_login temp_key_len=\(tempKey.count)")
                if transfer == nil && transferTask == nil {
                    await offerFirstLoginTransferIfNeeded(forceOffer: false)
                }

            case .waitingConfirmOnPhone:
                phoneSyncStatusSignal = ev
                if transferTask != nil {
                    updateTransferUI(MessageTransferState(
                        phase: .waitingForPhone,
                        progress: transfer?.progress ?? 0.10,
                        syncedConversations: transfer?.syncedConversations ?? 0,
                        totalConversations: transfer?.totalConversations,
                        message: "Mở Zalo trên điện thoại và chọn Đồng bộ ngay.",
                        stage: "confirmMobile",
                        stageIndex: 1,
                        stageCount: 3,
                        stageProgress: 0.10,
                        receivedMessages: transfer?.receivedMessages ?? 0
                    ))
                }

            case .userConfirmed:
                phoneSyncStatusSignal = .userConfirmed
                if transferTask != nil {
                    updateTransferUI(MessageTransferState(
                        phase: .transferring,
                        progress: max(transfer?.progress ?? 0.12, 0.14),
                        syncedConversations: transfer?.syncedConversations ?? 0,
                        totalConversations: transfer?.totalConversations,
                        message: "Đang nhận dữ liệu tin nhắn từ điện thoại…",
                        stage: "messages",
                        stageIndex: 2,
                        stageCount: 3,
                        stageProgress: 0.15,
                        receivedMessages: transfer?.receivedMessages ?? 0
                    ))
                }

            case .userRejected:
                phoneSyncStatusSignal = .userRejected

            case .mobileBusy:
                phoneSyncStatusSignal = .mobileBusy

            case .uploadBatch(let syncId, let urlStr, let batchType, let idx, let isLast):
                // Strictly ignore stale/unrelated upload_batch events before touching the network!
                guard await phoneSync.hasActiveRequest(syncId: syncId) else {
                    continue
                }
                await phoneSync.noteBatchStarted(syncId: syncId)
                let taskId = UUID()
                let task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer {
                        self.activeSyncBatchTasks.removeValue(forKey: taskId)
                        let coordinator = self.phoneSync
                        Task { await coordinator.noteBatchFinished(syncId: syncId) }
                    }
                    guard !Task.isCancelled else { return }
                    await self.handleIncomingSyncV2Batch(
                        syncId: syncId,
                        urlString: urlStr,
                        batchType: batchType,
                        idx: idx,
                        isLast: isLast
                    )
                }
                activeSyncBatchTasks[taskId] = task
            }
        }
    }

    private func handleIncomingSyncV2Batch(
        syncId: String,
        urlString: String,
        batchType: Int,
        idx: Int,
        isLast: Bool
    ) async {
        guard await phoneSync.hasActiveRequest(syncId: syncId),
              let url = URL(string: urlString) else {
            return
        }
        let myUid = profile?.userId ?? ""
        let client = sessionClient

        let rawBytes: Data
        do {
            rawBytes = try await syncBatchDownloadLimiter.withPermit {
                try await client.downloadSyncBatch(url: url)
            }
        } catch {
            EngineLog.shared.write("sync-v2: batch download error host=\(url.host ?? "-")")
            return
        }

        let result: DecryptedSyncBatchResult
        do {
            result = try await phoneSync.decryptAndParseBatch(
                syncId: syncId,
                rawBytes: rawBytes,
                url: urlString,
                batchType: batchType,
                idx: idx,
                isLast: isLast,
                myUid: myUid
            )
        } catch {
            EngineLog.shared.write("sync-v2: decryptBatch error \(error.localizedDescription)")
            return
        }

        if !result.deferred {
            if result.databaseType == "conversation" {
                await ingestParsedPhoneConversations(result.parsedConversations)
            } else {
                await ingestParsedPhoneMessages(result.parsedMessages)
                if let snap = await phoneSync.requestSnapshot(syncId: syncId), transferTask != nil {
                    let s2 = syncStage2Progress
                    let useS2 = (s2.activeSyncId == syncId && s2.totalPartitions > 0)
                    let prog: (progress: Double, stageProgress: Double) = {
                        if useS2 {
                            let completedCount = (snap.expectedDataBatches != nil) ? snap.completedDataBatchesCount : snap.batchesCount
                            return Self.computeStage2BatchProgress(
                                completedPartitionsBeforeChunk: s2.completedPartitionsBeforeChunk,
                                currentChunkPartitions: s2.currentChunkPartitionCount,
                                totalPartitions: s2.totalPartitions,
                                batchesCompletedInChunk: completedCount,
                                expectedBatchesInChunk: snap.expectedDataBatches,
                                previousProgress: transfer?.progress
                            )
                        }
                        return (max(transfer?.progress ?? 0.15, 0.16), transfer?.stageProgress ?? 0.1)
                    }()
                    let syncedCount = useS2
                        ? s2.cumulativeConvIdsBeforeChunk.union(snap.syncedConvIds).count
                        : max(transfer?.syncedConversations ?? 0, snap.syncedConversationsCount)
                    let totalConvs = useS2 ? s2.totalPartitions : transfer?.totalConversations
                    let receivedMsgs = useS2
                        ? (s2.cumulativeMessagesBeforeChunk + snap.importedCount)
                        : ((transfer?.receivedMessages ?? 0) + result.parsedMessages.count)
                    let msgLabel = (useS2 && s2.totalChunks > 1)
                        ? "Đang nhận tin nhắn từ điện thoại (\(s2.chunkIndex + 1)/\(s2.totalChunks))…"
                        : "Đang nhận dữ liệu tin nhắn từ điện thoại…"
                    updateTransferUI(MessageTransferState(
                        phase: .transferring,
                        progress: prog.progress,
                        syncedConversations: syncedCount,
                        totalConversations: totalConvs,
                        message: msgLabel,
                        stage: "messages",
                        stageIndex: 2,
                        stageCount: 3,
                        stageProgress: prog.stageProgress,
                        receivedMessages: receivedMsgs
                    ))
                }
            }
        }

        for replay in result.replayedBatches {
            if Task.isCancelled { break }
            await handleIncomingSyncV2Batch(
                syncId: syncId,
                urlString: replay.url,
                batchType: replay.batchType,
                idx: replay.idx,
                isLast: replay.isLast
            )
        }
    }

    internal func ingestParsedPhoneConversations(_ protoConvs: [ZaloSyncProtobufParser.ProtoConversation]) async {
        guard !protoConvs.isEmpty else { return }

        for pc in protoConvs where !pc.globalId.isEmpty {
            phoneSyncConvTimestamps[pc.globalId] = max(phoneSyncConvTimestamps[pc.globalId] ?? 0, pc.lastTs)
        }

        var groupGlobalToConvId: [String: String] = [:]
        for (cleanGrid, info) in cachedGroupDetails {
            let gid = JSONLossless.string(info["globalId"])
            if !gid.isEmpty {
                groupGlobalToConvId[gid] = ZaloWireParser.groupConvId(cleanGrid)
            }
        }

        let oneOneGlobalIds = protoConvs.filter { !$0.isGroup }.map(\.globalId)
        let decryptedOneOne = await sessionClient.decryptGlobalIds(oneOneGlobalIds)
        for (gid, uid) in decryptedOneOne {
            cachedFriendGlobalIds[uid] = gid
        }
        await persistGlobalIdCacheToSQLite()

        var updated = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        for pc in protoConvs {
            let convId: String
            if pc.isGroup {
                guard let gId = groupGlobalToConvId[pc.globalId] else { continue }
                convId = gId
            } else {
                guard let uid = decryptedOneOne[pc.globalId], !uid.isEmpty else { continue }
                convId = uid
            }

            let date = pc.lastTs > 0 ? Date(timeIntervalSince1970: Double(pc.lastTs) / 1000.0) : nil
            let identity = lookupConversationIdentity(convId)
            let existing = updated[convId]
            let preview: ConversationSummary.Preview? = {
                if let existingPrev = existing?.preview {
                    if let exDate = existingPrev.date, let newDate = date, newDate > exDate && existingPrev.text.isEmpty {
                        return ConversationSummary.Preview(text: "", date: newDate, fromMe: false)
                    }
                    return existingPrev
                }
                if let date {
                    return ConversationSummary.Preview(text: "", date: date, fromMe: false)
                }
                return nil
            }()

            updated[convId] = ConversationSummary(
                id: convId,
                isGroup: pc.isGroup,
                name: !identity.name.isEmpty ? identity.name : (existing?.name ?? convId),
                avatar: identity.avatar ?? existing?.avatar,
                pinned: cachedPinnedIds.contains(convId),
                members: identity.members > 0 ? identity.members : (existing?.members ?? 0),
                unread: existing?.unread ?? 0,
                preview: preview
            )
        }

        var list = Array(updated.values)
        sortConversations(&list)
        if list != conversations {
            conversations = list
        }
        await resolveMissingConversationNames()
        rebuildConversationFlags()
        rebuildConversationExtras()
        await persistConversationsToSQLite()
    }

    private func buildFastPersonLookupMap(extra: [String: (name: String, avatar: String)]) -> [String: (name: String, avatar: String)] {
        var map: [String: (name: String, avatar: String)] = extra
        for c in conversations where !c.isGroup {
            map[c.id] = (c.displayName, c.avatar?.absoluteString ?? "")
        }
        for (uid, prof) in cachedProfiles {
            let alias = cachedAliases[uid]
            let bestName = (alias?.isEmpty == false) ? alias! : prof.name
            if !bestName.isEmpty || !prof.avatar.isEmpty {
                map[uid] = (bestName, prof.avatar)
            }
        }
        for f in contacts.friends {
            let alias = cachedAliases[f.id]
            let avt = f.avatar?.absoluteString ?? cachedProfiles[f.id]?.avatar ?? ""
            map[f.id] = ((alias?.isEmpty == false) ? alias! : f.name, avt)
        }
        for (uid, alias) in cachedAliases where !alias.isEmpty && map[uid] == nil {
            map[uid] = (alias, "")
        }
        if let me = profile, !me.userId.isEmpty {
            map[me.userId] = ("Bạn", me.avatar?.absoluteString ?? "")
        }
        return map
    }

    internal func flushSyncedConversationsNow() {
        var list = conversations
        sortConversations(&list)
        if list != conversations {
            conversations = list
        }
        rebuildConversationFlags()
        rebuildConversationExtras()
        lastSyncConvFlushAt = Date()
    }

    internal func ingestParsedPhoneMessages(_ parsed: [ParsedPhoneMessage]) async {
        guard !parsed.isEmpty else { return }
        await syncBatchIngestLimiter.acquire()
        await performIngestParsedPhoneMessages(parsed)
        await syncBatchIngestLimiter.release()
    }

    private func performIngestParsedPhoneMessages(_ parsed: [ParsedPhoneMessage]) async {
        // Resolve any group sender / mention / quote global IDs that aren't in cache yet.
        var globalIdsToDecrypt = Set<String>()
        for item in parsed {
            if item.isGroup && !item.isMine && !item.senderGlobalId.isEmpty {
                globalIdsToDecrypt.insert(item.senderGlobalId)
            }
            if let mentions = item.proto.metaData?.mentions {
                for m in mentions where !m.uid.isEmpty && m.uid != "-1" {
                    globalIdsToDecrypt.insert(m.uid)
                }
            }
            if let qOwner = item.proto.metaData?.quote?.ownerId, !qOwner.isEmpty {
                globalIdsToDecrypt.insert(qOwner)
            }
        }
        let gidMap = globalIdsToDecrypt.isEmpty ? [:] : await sessionClient.decryptGlobalIds(Array(globalIdsToDecrypt))

        // Fetch profiles for any newly discovered group member UIDs and persist to cachedProfiles so we never re-fetch them!
        let unknownSenderUids = Array(Set(gidMap.values.compactMap { rawUid -> String? in
            guard let clean = ZaloWireParser.sanitizeProfileUid(rawUid),
                  clean != profile?.userId,
                  !syncAttemptedProfileUids.contains(clean),
                  lookupPersonInfo(clean) == nil else {
                return nil
            }
            return clean
        }))
        let uidsToFetch = Array(unknownSenderUids.prefix(150))
        var extraProfiles: [String: (name: String, avatar: String)] = [:]
        if !uidsToFetch.isEmpty {
            syncAttemptedProfileUids.formUnion(uidsToFetch)
            var profileCacheDirty = false
            for offset in stride(from: 0, to: uidsToFetch.count, by: 50) {
                let slice = Array(uidsToFetch[offset..<min(offset + 50, uidsToFetch.count)])
                if let profBox = try? await sessionClient.fetchProfiles(uids: slice) {
                    for (uid, row) in ZaloWireParser.extractProfilesMap(profBox.dict) {
                        let clean = ZaloWireParser.stripUserPrefix(uid)
                        let n = ZaloWireParser.preferredName(row)
                        let a = JSONLossless.string(row["avatar"] ?? row["avt"])
                        if !clean.isEmpty, (!n.isEmpty || !a.isEmpty) {
                            extraProfiles[clean] = (n, a)
                            cachedProfiles[clean] = ZaloWebKitMigrator.CachedProfile(name: n, avatar: a)
                            profileCacheDirty = true
                        }
                    }
                }
            }
            if profileCacheDirty, let data = try? JSONEncoder().encode(cachedProfiles) {
                try? await sqliteStore?.setPreferenceData(key: "cachedProfiles", data: data)
            }
        }

        let myUid = profile?.userId ?? ""
        let selfConvId = selfConversationId
        let personMap = buildFastPersonLookupMap(extra: extraProfiles)

        // Heavy protobuf → ChatMessage + StoredMessage JSON construction runs completely off @MainActor!
        let built = await Task.detached(priority: .userInitiated) {
            var storedBatch: [StoredMessage] = []
            storedBatch.reserveCapacity(parsed.count)
            var latestByConv: [String: ChatMessage] = [:]
            var messagesByConv: [String: [ChatMessage]] = [:]

            for item in parsed {
                let effectiveSenderUid: String = {
                    if item.isMine { return myUid }
                    if item.isGroup, let mapped = gidMap[item.senderGlobalId], !mapped.isEmpty {
                        return mapped
                    }
                    return item.senderUid
                }()
                let cleanSender = ZaloWireParser.stripUserPrefix(effectiveSenderUid)
                let senderInfo = item.isMine ? nil : personMap[cleanSender]
                let senderAvatar = senderInfo.flatMap { $0.avatar.isEmpty ? nil : URL(string: $0.avatar) }

                guard let (chatMsg, stored) = ZaloSyncProtobufParser.buildChatMessage(
                    from: item.proto,
                    convId: item.convId,
                    senderUid: effectiveSenderUid,
                    senderName: senderInfo?.name ?? "",
                    senderAvatar: senderAvatar,
                    isMine: item.isMine,
                    myUid: myUid,
                    selfConvId: selfConvId,
                    globalIdToUserId: gidMap,
                    nameLookup: { uid in
                        personMap[ZaloWireParser.stripUserPrefix(uid)]
                    }
                ) else {
                    continue
                }
                storedBatch.append(stored)
                messagesByConv[chatMsg.conversationId, default: []].append(chatMsg)
                if latestByConv[chatMsg.conversationId] == nil
                    || chatMsg.date >= (latestByConv[chatMsg.conversationId]?.date ?? .distantPast) {
                    latestByConv[chatMsg.conversationId] = chatMsg
                }
            }
            return (storedBatch: storedBatch, latestByConv: latestByConv, messagesByConv: messagesByConv)
        }.value

        // 1. Persist all messages transactionally to SQLite on its dedicated actor.
        if !built.storedBatch.isEmpty {
            let fastBulk = syncInitialEmptyDB && built.storedBatch.count >= 50
            try? await sqliteStore?.saveMessages(built.storedBatch, skipTwinChecks: fastBulk)
        }

        // 2. Only update in-memory `messages` for open / already-loaded conversations (or when running without SQLite in tests).
        let hasSQLite = (sqliteStore != nil)
        for (convId, incomingList) in built.messagesByConv {
            if !hasSQLite || messages[convId] != nil || openConversationId == convId {
                var byId: [String: ChatMessage] = [:]
                let existing = messages[convId] ?? []
                byId.reserveCapacity(existing.count + incomingList.count)
                for m in existing { byId[m.id] = m }
                for m in incomingList { byId[m.id] = m }
                var combined = Array(byId.values)
                combined.sort { a, b in
                    if a.date != b.date { return a.date < b.date }
                    return a.id < b.id
                }
                let cap = max(existing.count, openConversationId == convId ? 200 : 100)
                if hasSQLite && combined.count > cap {
                    combined = Array(combined.suffix(cap))
                    hasMoreHistory[convId] = true
                }
                messages[convId] = combined
                historyTicks[convId, default: 0] += 1
            } else if incomingList.count >= 45 {
                hasMoreHistory[convId] = true
            }
        }

        // 3. Update sidebar conversation previews in memory, throttling full sort/SQLite flush to every 0.8s.
        if !built.latestByConv.isEmpty {
            var updated = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
            for (convId, latest) in built.latestByConv {
                let isGrp = ZaloWireParser.isGroupId(convId)
                let identity = lookupConversationIdentity(convId)
                let prevText = Self.messagePreviewLabel(latest)
                let prev = ConversationSummary.Preview(text: prevText, date: latest.date, fromMe: latest.isMine)
                let existing = updated[convId]
                let effectivePrev: ConversationSummary.Preview? = {
                    if let old = existing?.preview,
                       !old.text.isEmpty,
                       (old.date ?? .distantPast) > latest.date {
                        return old
                    }
                    return prev
                }()
                let name = !identity.name.isEmpty ? identity.name : (existing?.name ?? convId)
                updated[convId] = ConversationSummary(
                    id: convId,
                    isGroup: isGrp,
                    name: name.isEmpty ? convId : name,
                    avatar: identity.avatar ?? existing?.avatar ?? (!isGrp && !latest.isMine ? latest.senderAvatar : nil),
                    pinned: cachedPinnedIds.contains(convId),
                    members: identity.members > 0 ? identity.members : (existing?.members ?? 0),
                    unread: existing?.unread ?? 0,
                    preview: effectivePrev
                )
            }
            var list = Array(updated.values)
            if Date().timeIntervalSince(lastSyncConvFlushAt) >= 0.8 || !hasSQLite {
                sortConversations(&list)
                conversations = list
                rebuildConversationFlags()
                rebuildConversationExtras()
                lastSyncConvFlushAt = Date()
                await persistConversationsToSQLite()
            } else {
                conversations = list
            }
        }
    }

    /// Why "Đồng bộ ngay" is off, in words, for the official `canSync` result name the adapter reports.
    static func transferBlockedText(_ reason: String) -> String {
        switch reason {
        case "INVALID_STATE", "SYNC_RUNNING": "Zalo đang tự đồng bộ với điện thoại. Bạn có thể đồng bộ lại khi xong."
        case "WORKER_NOT_READY": "Zalo đang chuẩn bị dữ liệu, hãy chờ giây lát."
        case "DB_MIGRATING": "Zalo đang sắp xếp lại dữ liệu trên máy, hãy chờ giây lát."
        case "MOBILE_NOT_SUPPORT": "Zalo trên điện thoại chưa hỗ trợ đồng bộ này. Hãy cập nhật Zalo trên điện thoại."
        case "DISABLED", "SYNC_SRC_DISABLED": "Tài khoản này chưa được Zalo bật đồng bộ tin nhắn từ điện thoại."
        case "NO_PERMISSION": "Thiết bị này chưa được phép đồng bộ tin nhắn."
        case "WASM_UNAVAILABLE": "Thiếu mô-đun giải mã đồng bộ Zalo (libzproto_wasm_bg.wasm). Hãy cài đặt lại ứng dụng Zalo trên Mac rồi thử lại."
        default: "Chưa thể đồng bộ lúc này, hãy thử lại sau."
        }
    }

    /// `{page:'main', transferAvailable:{canStart, reason}}` from the adapter.
    func handleTransferAvailability(state: [String: Any]) {
        let json = state["transferAvailable"] as? [String: Any] ?? [:]
        canStartTransfer = json["canStart"] as? Bool ?? false
        transferStartBlockedReason = json["reason"] as? String
    }

    func handleTransfer(state: [String: Any]) {
        guard let json = state["transfer"] as? [String: Any],
              let phaseName = json["phase"] as? String else {
            transfer = nil
            return
        }
        let errorName = json["errorName"] as? String
        let errorCode = Self.int(json["errorCode"])
        let phase: MessageTransferState.Phase
        switch phaseName {
        case "offer": phase = .offer
        case "waitingForPhone": phase = .waitingForPhone
        case "transferring": phase = .transferring
        case "finished": phase = .finished
        case "failed": phase = .failed(Self.transferErrorText(code: errorCode, name: errorName))
        default:
            EngineLog.shared.write("transfer: unknown phase \(phaseName)")
            return
        }
        func text(_ key: String) -> String? {
            guard let value = json[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        let next = MessageTransferState(
            phase: phase,
            progress: Self.double(json["progress"]).map { min(1, max(0, $0)) },
            syncedConversations: Self.int(json["syncedConversations"]) ?? 0,
            totalConversations: Self.int(json["totalConversations"]),
            message: text("message"),
            stage: text("stage"),
            stageIndex: Self.int(json["stageIndex"]),
            stageCount: Self.int(json["stageCount"]),
            stageProgress: Self.double(json["stageProgress"]).map { min(1, max(0, $0)) },
            receivedMessages: Self.int(json["receivedMessages"]),
            errorCode: errorCode,
            errorName: errorName,
            canRetry: json["canRetry"] as? Bool ?? false,
            officialTitle: text("officialTitle"),
            officialDescription: text("officialDescription"),
            officialSuggestion: text("officialSuggestion")
        )
        if transfer != next { transfer = next }
    }

    private static func int(_ value: Any?) -> Int? {
        if let n = value as? NSNumber, !(value is NSNull) { return n.intValue }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let n = value as? NSNumber, !(value is NSNull) { return n.doubleValue }
        return nil
    }

    /// Vietnamese wording for the official sync error codes (`Wle.c`); unknown codes fall back to the code.
    static func transferErrorText(code: Int?, name: String?) -> String {
        switch name ?? "" {
        case "NO_NETWORK", "ERR_CONNECTION_TIMED_OUT", "REQUEST_SOCKET_CLOSED":
            return "Không có kết nối mạng. Hãy kiểm tra mạng rồi thử lại."
        case "MOBILE_LOW_STORAGE":
            return "Bộ nhớ điện thoại không đủ để đồng bộ."
        case "PC_LOW_STORAGE":
            return "Bộ nhớ trên máy tính không đủ để đồng bộ."
        case "MOBILE_BUSY", "MOBILE_BUSY_SYNCING", "MOBILE_BUSY_MANUAL_BACKUP":
            return "Điện thoại đang bận. Hãy thử lại sau ít phút."
        case "MOBILE_LOGGED_OUT":
            return "Zalo trên điện thoại đã đăng xuất."
        case "USER_REJECT_BACKUP", "MOBILE_USER_CANCELS_SYNC":
            return "Yêu cầu đồng bộ đã bị từ chối trên điện thoại."
        case "USER_DONT_CONFIRM", "SYNC_REQUEST_TIMEOUT_NO_NEED_CONFIRM", "MOBILE_DONT_AUTO_CONFIRM", "REQUEST_TIMEOUT":
            return "Điện thoại chưa xác nhận yêu cầu đồng bộ."
        case "MOBILE_IDLE_TIMEOUT", "WAKE_UP_TIMEOUT":
            return "Zalo trên điện thoại đã ngừng phản hồi. Hãy mở Zalo trên điện thoại rồi thử lại."
        case "BATCH_TIMEOUT", "DOWNLOAD_TIMEOUT":
            return "Quá trình đồng bộ bị gián đoạn do quá thời gian chờ."
        case "CLIENT_NOT_SUPPORT":
            return "Phiên bản Zalo trên điện thoại chưa hỗ trợ đồng bộ này."
        case "WASM_UNAVAILABLE":
            return "Thiếu mô-đun giải mã đồng bộ Zalo (libzproto_wasm_bg.wasm). Hãy cài đặt lại ứng dụng Zalo trên Mac rồi thử lại."
        default:
            if let code { return "Đồng bộ không thành công (mã lỗi \(code))." }
            return "Đồng bộ không thành công."
        }
    }
}

extension MessageTransferState.Phase {
    /// Phase name as used by `transfer-adapter.js` (TransferJSON.phase).
    var adapterName: String {
        switch self {
        case .offer: "offer"
        case .waitingForPhone: "waitingForPhone"
        case .transferring: "transferring"
        case .finished: "finished"
        case .failed: "failed"
        }
    }
}
