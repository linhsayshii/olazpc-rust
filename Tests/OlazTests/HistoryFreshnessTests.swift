import Foundation
import Testing
@testable import Olaz

@Suite(.serialized) struct HistoryFreshnessTests {
    private func msg(_ id: String, conv: String, at seconds: TimeInterval) -> ChatMessage {
        ChatMessage(
            id: id,
            conversationId: conv,
            senderId: "100",
            senderName: "An",
            senderAvatar: nil,
            isMine: false,
            kind: .text,
            text: "x",
            date: Date(timeIntervalSince1970: seconds),
            status: .sent,
            quote: nil,
            reactions: [],
            isE2EE: false,
            clientId: ""
        )
    }

    private func event(_ m: ChatMessage) throws -> ParsedWireEvent {
        .message(m, try #require(ZaloWireParser.encodeChatMessage(m)))
    }

    @Test func newestMessageIdPerConversation() throws {
        let events = [
            try event(msg("10", conv: "g1", at: 100)),
            try event(msg("12", conv: "g1", at: 300)),
            try event(msg("11", conv: "g1", at: 200)),
            try event(msg("20", conv: "200", at: 50)),
            try event(msg("21", conv: "200", at: 50)),   // same date: higher id wins
            .ignore,
        ]
        #expect(ZaloEngine.newestMessageIds(in: events) == ["g1": "12", "200": "21"])
    }

    @Test @MainActor func probeMarksStoredNewestAsUpToDateAndNewAsStale() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-fresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = ZaloEngine(dataDirectory: root, useKeychain: false)
        let store = try ZaloSQLiteStore(path: root.appendingPathComponent("history.sqlite3").path)
        engine.sqliteStore = store

        let known = msg("500", conv: "g1", at: 1_000)
        try await store.saveMessages([try #require(ZaloWireParser.encodeChatMessage(known))])

        // g1's newest is already stored; 200 has a message the store never saw.
        await engine.probeHistoryFreshness([try event(known), try event(msg("900", conv: "200", at: 2_000))])
        #expect(engine.isRecentHistoryUpToDate("g1"))
        #expect(!engine.isRecentHistoryUpToDate("200"))
        #expect(!engine.isRecentHistoryUpToDate("g9"))   // not in the preload: unknown, fetch as before

        // A later preload chunk cannot flip a stale thread back to up to date after its rows were stored.
        try await store.saveMessages([try #require(ZaloWireParser.encodeChatMessage(msg("900", conv: "200", at: 2_000)))])
        await engine.probeHistoryFreshness([try event(msg("900", conv: "200", at: 2_000))])
        #expect(!engine.isRecentHistoryUpToDate("200"))
        await store.close()
    }

    @Test @MainActor func dailyFullRefreshIsDueOnceThenSkipped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-fresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = ZaloEngine(dataDirectory: root, useKeychain: false)
        let store = try ZaloSQLiteStore(path: root.appendingPathComponent("history.sqlite3").path)
        engine.sqliteStore = store

        #expect(await engine.beginHistoryFreshnessPass())        // never refreshed: due
        await engine.finishFullHistoryRefresh()
        #expect(await engine.beginHistoryFreshnessPass() == false) // refreshed just now: skip allowed

        // A clock that jumped backwards (stored time in the future) forces a refresh.
        try await store.setPreferenceString(
            key: ZaloEngine.fullHistoryRefreshKey, value: String(Date().timeIntervalSince1970 + 3_600))
        #expect(await engine.beginHistoryFreshnessPass())
        await store.close()
    }
}
