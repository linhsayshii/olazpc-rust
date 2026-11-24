import Foundation

@MainActor
extension ZaloEngine {
    internal func traceHost(_ name: String, args: [String: Any] = [:]) -> Bool {
        hostTrace?(name, args) ?? true
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
        stateTrace = nil
        EngineLog.shared.onAppend = nil
        bootTask?.cancel()
        qrTask?.cancel()
        wsTask?.cancel()
        lpPollTask?.cancel()
        bootstrapTask?.cancel()
        transferTask?.cancel()
    }

    internal func finishTearDownForRecording() async {
        await sessionClient.setSessionTrace(nil)
        _ = await bootTask?.value
        _ = await qrTask?.value
        _ = await pendingCleanupTask?.value
    }
}
