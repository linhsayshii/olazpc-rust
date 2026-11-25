import Foundation
import OlazCore

@MainActor
extension ZaloEngine {
    internal func traceHost(_ name: String, args: @autoclosure () -> [String: Any] = [:]) -> Bool {
        guard let hostTrace else { return true }
        return hostTrace(name, args())
    }

    internal func traceU4Host(_ name: String, args: @autoclosure () -> [String: Any] = [:]) -> Bool {
        guard traceU4HostEnabled else { return true }
        return traceHost(name, args: args())
    }

    internal func showActionCard(_ text: String, in conversationId: String?) {
        if traceHost("show_card", args: ["conv_id": conversationId ?? NSNull(), "text": text]) {
            CardActionCenter.shared.show(text, in: conversationId)
        }
    }

    internal func trackContactsTask(_ body: @escaping @MainActor () async -> Void) {
        let key = UUID()
        let task = Task { @MainActor [weak self] in
            defer { self?.contactsTasks.removeValue(forKey: key) }
            await body()
        }
        contactsTasks[key] = task
    }

    internal func trackMessageActionTask(_ body: @escaping @MainActor () async -> Void) {
        let key = UUID()
        let task = Task { @MainActor [weak self] in
            defer { self?.messageActionTasks.removeValue(forKey: key) }
            await body()
        }
        messageActionTasks[key] = task
    }

    internal func trackPollTask(_ body: @escaping @MainActor () async -> Void) {
        let key = UUID()
        let task = Task { @MainActor [weak self] in
            defer { self?.pollRefreshTasks.removeValue(forKey: key) }
            await body()
        }
        pollRefreshTasks[key] = task
    }

    internal func syncSessionClientTrace() async {
        guard hostTrace != nil else {
            await sessionClient.setSessionTrace(nil)
            return
        }
        await sessionClient.setSessionTrace { [weak self] name in
            self?.hostTrace?(name, [:]) ?? true
        }
    }

    internal func setSessionPreference(key: String, value: String) async {
        recordedSessionPrefs[key] = value
        try? await sqliteStore?.setPreferenceString(key: key, value: value)
    }

    internal func cancelTasksForRecording() {
        hostTrace = nil
        sendE2EETextHostHandler = nil
        resolveMediaHostHandler = nil
        resolveFileHostHandler = nil
        fetchMediaDataHostHandler = nil
        sendMediaHostHandler = nil
        sendFilesHostHandler = nil
        forwardTempPhotoURL = nil
        traceU4HostEnabled = false
        stateTrace = nil
        EngineLog.shared.onAppend = nil
        stopCoreEngine()
        bootTask?.cancel()
        qrTask?.cancel()
        transferTask?.cancel()
        openConversationTask?.cancel()
        loadOlderTask?.cancel()
        persistConversationsTask?.cancel()
        notifyTypingTask?.cancel()
        markReadTasks.values.forEach { $0.cancel() }
        markReadTasks.removeAll()
        activeSendTask?.cancel()
        deleteUndoTimerTask?.cancel()
        deleteUndoTimerTask = nil
        messageActionTasks.values.forEach { $0.cancel() }
        messageActionTasks.removeAll()
        contactsTasks.values.forEach { $0.cancel() }
        contactsTasks.removeAll()
        pollDebounceSleep = nil
        resetPolls()
        pollRefreshTasks.values.forEach { $0.cancel() }
        cloudRefreshTask?.cancel()
        cloudRefreshTask = nil
        typingResetTasks.values.forEach { $0.cancel() }
        typingResetTasks = [:]
    }

    internal func settleForRecording() async {
        let core: CoreEngine?
        if let existing = coreLifecycle.core {
            core = existing
        } else if let initTask = coreInitTask {
            core = await initTask.value
        } else {
            return
        }
        guard let core else { return }
        guard let version = try? await core.settle() else { return }
        await waitForMirrorVersion(version)
    }

    internal func awaitMarkReadTasksForRecording() async {
        await settleForRecording()
        while !markReadTasks.isEmpty {
            let tasks = Array(markReadTasks.values)
            markReadTasks.removeAll()
            for task in tasks { _ = await task.value }
        }
        if let core = coreLifecycle.core {
            if phase == .ready, activeSendTask == nil {
                if let v = try? await core.waitIdle() {
                    await waitForMirrorVersion(v)
                }
            } else if let v = try? await core.settle() {
                await waitForMirrorVersion(v)
            }
        }
        _ = await persistConversationsTask?.value
    }

    internal func awaitNotifyTypingTaskForRecording() async {
        let task = notifyTypingTask
        notifyTypingTask = nil
        _ = await task?.value
        if let core = coreLifecycle.core {
            if phase == .ready, activeSendTask == nil {
                if let v = try? await core.waitIdle() {
                    await waitForMirrorVersion(v)
                }
            } else if let v = try? await core.settle() {
                await waitForMirrorVersion(v)
            }
        }
    }

    internal func awaitMessageActionTasksForRecording() async {
        while !messageActionTasks.isEmpty {
            let tasks = Array(messageActionTasks.values)
            messageActionTasks.removeAll()
            for task in tasks { _ = await task.value }
        }
        _ = await persistConversationsTask?.value
    }

    internal func awaitContactsTasksForRecording() async {
        while !contactsTasks.isEmpty {
            let tasks = Array(contactsTasks.values)
            contactsTasks.removeAll()
            for task in tasks { _ = await task.value }
        }
        await awaitMessageActionTasksForRecording()
    }

    internal func awaitPollTasksForRecording() async {
        while !pollRefreshTasks.isEmpty {
            let tasks = Array(pollRefreshTasks.values)
            pollRefreshTasks.removeAll()
            for task in tasks { _ = await task.value }
        }
        _ = await persistConversationsTask?.value
    }

    internal func awaitCloudTasksForRecording() async {
        while let task = cloudRefreshTask {
            cloudRefreshTask = nil
            _ = await task.value
        }
        _ = await persistConversationsTask?.value
    }

    internal func finishTearDownForRecording() async {
        await sessionClient.setSessionTrace(nil)
        _ = await bootTask?.value
        _ = await qrTask?.value
        _ = await openConversationTask?.value
        _ = await loadOlderTask?.value
        _ = await activeSendTask?.value
        _ = await notifyTypingTask?.value
        while !markReadTasks.isEmpty {
            let tasks = Array(markReadTasks.values)
            markReadTasks.removeAll()
            for task in tasks { _ = await task.value }
        }
        while !contactsTasks.isEmpty {
            let tasks = Array(contactsTasks.values)
            contactsTasks.removeAll()
            for task in tasks { _ = await task.value }
        }
        while !messageActionTasks.isEmpty {
            let tasks = Array(messageActionTasks.values)
            messageActionTasks.removeAll()
            for task in tasks { _ = await task.value }
        }
        while !pollRefreshTasks.isEmpty {
            let tasks = Array(pollRefreshTasks.values)
            pollRefreshTasks.removeAll()
            for task in tasks { _ = await task.value }
        }
        _ = await cloudRefreshTask?.value
        _ = await persistConversationsTask?.value
        _ = await pendingCleanupTask?.value
    }

    internal static func serializeMobileSyncEvents(_ events: [ZaloMobileSyncEvent]) -> [[String: Any]] {
        events.map { ev in
            switch ev {
            case .transferAfterLogin(let tempKey):
                return ["kind": "transfer_after_login", "temp_key": tempKey]
            case .waitingConfirmOnPhone(let syncId):
                return ["kind": "waiting_confirm_on_phone", "sync_id": syncId]
            case .userConfirmed:
                return ["kind": "user_confirmed"]
            case .userRejected:
                return ["kind": "user_rejected"]
            case .mobileBusy:
                return ["kind": "mobile_busy"]
            case .uploadBatch(let syncId, let url, let batchType, let idx, let isLast):
                return [
                    "kind": "upload_batch",
                    "sync_id": syncId,
                    "url": url,
                    "batch_type": batchType,
                    "idx": idx,
                    "is_last": isLast,
                ]
            }
        }
    }

    internal static func serializeParsedWireEvents(_ events: [ParsedWireEvent]) -> [[String: Any]] {
        events.map { ev in
            switch ev {
            case .message(let msg, let stored):
                return [
                    "kind": "message",
                    "conv_id": msg.conversationId,
                    "msg_id": msg.id,
                    "client_id": stored.clientId,
                    "sender_id": msg.senderId,
                    "sender_name": msg.senderName,
                    "sender_avatar": msg.senderAvatar?.absoluteString ?? NSNull(),
                    "is_mine": msg.isMine,
                    "kind_tag": stored.kindTag,
                    "text": msg.text,
                    "ts_ms": stored.tsMs,
                    "status": stored.status,
                    "is_e2ee": msg.isE2EE,
                ]
            case .reaction(
                let convId, let msgId, let cliMsgId, let senderId,
                let rType, let rIcon, let eventId, let reactClientId,
                let tsMs, let seqId, let senderName
            ):
                return [
                    "kind": "reaction",
                    "conv_id": convId,
                    "msg_id": msgId,
                    "cli_msg_id": cliMsgId,
                    "sender_id": senderId,
                    "sender_name": senderName,
                    "r_type": rType,
                    "r_icon": rIcon,
                    "event_id": eventId,
                    "react_client_id": reactClientId,
                    "ts_ms": tsMs,
                    "seq_id": seqId,
                ]
            case .undo(let convId, let msgId, let cliMsgId):
                return [
                    "kind": "undo",
                    "conv_id": convId,
                    "msg_id": msgId,
                    "cli_msg_id": cliMsgId,
                ]
            case .delete(let convId, let msgId, let cliMsgId):
                return [
                    "kind": "delete",
                    "conv_id": convId,
                    "msg_id": msgId,
                    "cli_msg_id": cliMsgId,
                ]
            case .typing(let convId, let senderId, let isGroup):
                return [
                    "kind": "typing",
                    "conv_id": convId,
                    "sender_id": senderId,
                    "is_group": isGroup,
                ]
            case .ignore:
                return ["kind": "ignore"]
            }
        }
    }

    internal static func serializePollState(_ state: ZaloPollState) -> [String: Any] {
        [
            "lastActionId": state.lastActionId,
            "lastActionIdOther": state.lastActionIdOther,
            "queues": state.queues.mapValues { ["lastId": $0.lastId, "ids": $0.ids] },
        ]
    }

    internal static func serializeWSQueueCursors(_ cursors: [String: ZaloWSQueueCursorSnapshot]) -> [String: Any] {
        cursors.mapValues { ["lastId": $0.lastId, "preIds": $0.preIds] }
    }
}
