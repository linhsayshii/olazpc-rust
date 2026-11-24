import Foundation

/// Skips re-downloading recent history the store already holds.
///
/// The launch preload returns each active thread's newest message. If that message was already stored before the
/// preload ran, nothing newer arrived while Olaz was closed (the long-poll drain runs first and fills the queue in
/// order), so the recent-history fetch for that thread would only re-download rows we have. Edits, recalls and
/// reactions on older messages still arrive through the long-poll queue and the WebSocket. Once a day the bootstrap
/// ignores this and refreshes everything, in case one of those was missed.
enum HistoryFreshness: Equatable, Sendable {
    /// The server's newest message for the thread was already stored locally.
    case upToDate
    /// The server has a message the store did not have: fetch recent history to fill the gap.
    case stale
}

extension ZaloEngine {
    static let fullHistoryRefreshInterval: TimeInterval = 24 * 60 * 60
    static let fullHistoryRefreshKey = "historyFullRefreshAt"

    /// The newest message id per conversation in a batch of parsed events (by date, then id).
    nonisolated static func newestMessageIds(in events: [ParsedWireEvent]) -> [String: String] {
        var newest: [String: ChatMessage] = [:]
        for ev in events {
            guard case .message(let msg, _) = ev, !msg.id.isEmpty, !msg.conversationId.isEmpty else { continue }
            if let cur = newest[msg.conversationId],
               cur.date > msg.date || (cur.date == msg.date && cur.id >= msg.id) {
                continue
            }
            newest[msg.conversationId] = msg
        }
        return newest.mapValues(\.id)
    }

    /// Records, before the events are stored, whether each conversation's newest message was already in the store.
    internal func probeHistoryFreshness(_ events: [ParsedWireEvent]) async {
        guard let store = sqliteStore else { return }
        for (convId, msgId) in Self.newestMessageIds(in: events) {
            guard historyFreshness[convId] != .stale else { continue }
            let found = (try? await store.existingMessageIds(convId: convId, ids: [msgId])) ?? []
            historyFreshness[convId] = found.contains(msgId) ? .upToDate : .stale
        }
    }

    /// True when the recent-history fetch for `convId` can be skipped: this session saw the server's newest message
    /// for it and it was already stored, or this session already fetched its recent history.
    internal func isRecentHistoryUpToDate(_ convId: String) -> Bool {
        historyFreshness[convId] == .upToDate
    }

    /// Starts a bootstrap: returns true when the daily full refresh is due (then nothing is skipped this launch).
    internal func beginHistoryFreshnessPass() async -> Bool {
        historyFreshness = [:]
        let now = Date().timeIntervalSince1970
        let last = (try? await sqliteStore?.getPreferenceString(key: Self.fullHistoryRefreshKey)).flatMap { $0 }.flatMap(Double.init) ?? 0
        let due = now - last >= Self.fullHistoryRefreshInterval || last > now
        historyFullRefreshDue = due
        return due
    }

    /// Marks the daily full refresh done once the bootstrap fetched everything.
    internal func finishFullHistoryRefresh() async {
        guard historyFullRefreshDue else { return }
        historyFullRefreshDue = false
        try? await sqliteStore?.setPreferenceString(
            key: Self.fullHistoryRefreshKey, value: String(Date().timeIntervalSince1970))
    }
}
