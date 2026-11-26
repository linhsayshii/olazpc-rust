import Foundation
import OlazCore
import Testing

@testable import Olaz

@Suite struct CoreMessagesMirrorTests {
    private static func makeMessageRecord(
        id: String,
        convId: String = "3000901",
        text: String,
        dateMs: Int64,
        isMine: Bool = false
    ) -> ChatMessageRecord {
        let msg = ChatMessage(
            id: id,
            conversationId: convId,
            senderId: isMine ? "2000001" : convId,
            senderName: isMine ? "Bạn" : "Alice",
            senderAvatar: nil,
            isMine: isMine,
            kind: .text,
            text: text,
            date: Date(timeIntervalSince1970: Double(dateMs) / 1000.0),
            status: .sent,
            quote: nil,
            reactions: [],
            isE2EE: false
        )
        return ChatMessageRecord(message: msg)
    }

    private static func emptyChanges(
        version: UInt64,
        windowDeltas: [WindowDeltaRecord] = [],
        messagesResetAll: Bool = false,
        messageMeta: MessageMetaRecord? = nil,
        contacts: ContactsStateRecord? = nil
    ) -> CoreChangesRecord {
        CoreChangesRecord(
            version: version,
            session: nil,
            conversations: nil,
            conversationFlags: nil,
            conversationExtras: nil,
            conversationUi: nil,
            conversationPrompt: nil,
            windowDeltas: windowDeltas,
            messagesResetAll: messagesResetAll,
            messageMeta: messageMeta,
            contacts: contacts,
            typing: nil,
            deleteUndo: nil,
            messageConfirm: nil,
            autoDelete: nil,
            starredIds: nil,
            cachedProfiles: nil,
            cloud: nil
        )
    }

    @MainActor
    @Test func windowDeltasResetAppendPatchAndResetAll() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-u4-mirror-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = ZaloEngine(dataDirectory: dir, useKeychain: false)
        let convId = "3000901"

        // 1. Reset populates window from scratch.
        let m1 = Self.makeMessageRecord(id: "1001", convId: convId, text: "First", dateMs: 1_700_000_001_000)
        let m2 = Self.makeMessageRecord(id: "1002", convId: convId, text: "Second", dateMs: 1_700_000_002_000)
        engine.applyCoreChanges(Self.emptyChanges(
            version: 1,
            windowDeltas: [.reset(convId: convId, messages: [m1, m2])]
        ))
        #expect(engine.messages[convId]?.map(\.id) == ["1001", "1002"])
        #expect(engine.messages[convId]?.map(\.text) == ["First", "Second"])

        // 2. Append adds strictly newer messages without duplicating existing IDs.
        let m3 = Self.makeMessageRecord(id: "1003", convId: convId, text: "Third", dateMs: 1_700_000_003_000)
        engine.applyCoreChanges(Self.emptyChanges(
            version: 2,
            windowDeltas: [.append(convId: convId, messages: [m2, m3])]
        ))
        #expect(engine.messages[convId]?.map(\.id) == ["1001", "1002", "1003"])

        // 3. Patch updates existing messages in place, inserts out-of-order upserts sorted, and deletes removed IDs.
        let m2Edited = Self.makeMessageRecord(id: "1002", convId: convId, text: "Second (edited)", dateMs: 1_700_000_002_000)
        let m1b = Self.makeMessageRecord(id: "1001b", convId: convId, text: "Between", dateMs: 1_700_000_001_500)
        engine.applyCoreChanges(Self.emptyChanges(
            version: 3,
            windowDeltas: [.patch(convId: convId, upserts: [m2Edited, m1b], removedIds: ["1001"])]
        ))
        #expect(engine.messages[convId]?.map(\.id) == ["1001b", "1002", "1003"])
        #expect(engine.messages[convId]?[1].text == "Second (edited)")

        // 4. Meta + Contacts mirror.
        engine.applyCoreChanges(Self.emptyChanges(
            version: 4,
            messageMeta: MessageMetaRecord(
                hasMoreHistory: [BoolMapEntry(convId: convId, value: true)],
                historyTicks: [TickMapEntry(convId: convId, tick: 2)],
                historyFreshness: [FreshnessMapEntry(convId: convId, freshness: .upToDate)]
            ),
            contacts: ContactsStateRecord(
                friends: [FriendEntryRecord(
                    id: convId,
                    name: "Alice",
                    zaloName: "Alice Z",
                    avatar: "https://cdn.example.invalid/a.jpg",
                    lastActiveMs: 1_700_000_000_000,
                    online: true,
                    section: "A",
                    sortKey: "alice"
                )],
                groups: [],
                received: [],
                sent: [],
                pendingRequestCount: 0,
                friendsLoaded: true,
                groupsLoaded: true,
                loadingRequests: false,
                groupDetailsJson: [],
                receivedRawJson: nil,
                sentRawJson: nil,
                friendGlobalIds: [StringPairEntry(key: convId, value: "gid_alice")]
            )
        ))
        #expect(engine.hasMoreHistory[convId] == true)
        #expect(engine.historyTicks[convId] == 2)
        #expect(engine.historyFreshness[convId] == .upToDate)
        #expect(engine.contacts.friends.count == 1)
        #expect(engine.contacts.friends.first?.name == "Alice")
        #expect(engine.contacts.friendsLoaded == true)
        #expect(engine.cachedFriendGlobalIds[convId] == "gid_alice")

        // 5. messagesResetAll clears windows and message metadata.
        engine.applyCoreChanges(Self.emptyChanges(version: 5, messagesResetAll: true))
        #expect(engine.messages.isEmpty)
        #expect(engine.hasMoreHistory.isEmpty)
        #expect(engine.historyTicks.isEmpty)
        #expect(engine.historyFreshness.isEmpty)
    }
}
