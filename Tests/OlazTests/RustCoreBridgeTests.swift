import Foundation
import OlazCore
import Testing

/// Proves the UniFFI bridge to the Rust core (`rust/crates/olaz-ffi`): version, store, wire parser, crypto helpers.
@Suite struct RustCoreBridgeTests {
    @Test func versionIsExposed() {
        #expect(!coreVersion().isEmpty)
    }

    @Test func storeSavesAndLoadsMessageWith64BitId() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-core-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CoreStore.open(path: dir.appendingPathComponent("t.db").path)
        let row = MessageRow(
            id: "7412345678901234567", convId: "c1", clientId: "cli", senderId: "u1", senderName: "An",
            senderAvatar: "", isMine: false, text: "xin chào", kindTag: "text", tsMs: 1_795_000_000_000,
            status: "sent", rawJson: Data(#"{"id":"7412345678901234567"}"#.utf8))
        try await store.saveMessages(items: [row])
        let loaded = try await store.messages(convId: "c1", beforeTsMs: nil, limit: 50)
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == "7412345678901234567")
        #expect(loaded.first?.text == "xin chào")

        try await store.setPreferenceString(key: "k", value: "v")
        #expect(try await store.preferenceString(key: "k") == "v")
        #expect(try await store.loadConversations().isEmpty)
    }

    @Test func parsesWireEventKeepingBigIds() throws {
        let json = #"{"msgId":7412345678901234567,"cliMsgId":7412345678901234568,"uidFrom":"peer","idTo":"me","msgType":"webchat","content":"hi","ts":1795000000000}"#
        let event = try parseWireEvent(json: json, myUid: "me", options: WireOptions())
        guard case let .message(message, stored) = event else {
            Issue.record("expected a message event")
            return
        }
        #expect(message.id == "7412345678901234567")
        #expect(message.clientId == "7412345678901234568")
        #expect(stored.kindTag == "text")
        #expect(!stored.locked)
        #expect(String(decoding: stored.rawJson, as: UTF8.self).contains("7412345678901234567"))
        #expect(throws: CoreError.self) { try parseWireEvent(json: "[1]", myUid: "me", options: WireOptions()) }
    }

    @Test func cryptoHelpers() throws {
        #expect(try decryptWsFrame(cipherKey: nil, encrypt: 0, dataField: "abc") == Data("abc".utf8))
        #expect(throws: CoreError.self) { try inflate(data: Data([1, 2, 3])) }
    }
    // MARK: session

    private static let fakeSnapshot = """
        {"zpwType":"23","imei":"imei-test","computerName":"Mac test","domains":{},
         "plainAccount":{"userId":"100","displayName":"An","avatar":"","phone":"","send2MeId":"999",
                         "dkey":"","zpwEnk":"0123456789abcdef","zpwSek":"sek.1.2"},
         "expiredAt":null,"sealedSecretsBase64":null}
        """

    @Test func sessionRestoresAndSnapshotsRoundTrip() throws {
        let session = try CoreSession(computerName: "Mac")
        #expect(!session.isAuthenticated())
        #expect(try session.restore(snapshotJson: Self.fakeSnapshot))
        #expect(session.isAuthenticated())
        let snapshot = try session.snapshotJson()
        let object = try #require(try JSONSerialization.jsonObject(with: Data(snapshot.utf8)) as? [String: Any])
        #expect(object["computerName"] as? String == "Mac test")
        let account = try #require(object["plainAccount"] as? [String: Any])
        #expect(account["userId"] as? String == "100")

        let other = try CoreSession(computerName: "Other")
        #expect(try other.restore(snapshotJson: snapshot))
        #expect(try other.snapshotJson() == snapshot)

        session.markExpired()
        let expired = try #require(try JSONSerialization.jsonObject(with: Data(try session.snapshotJson().utf8)) as? [String: Any])
        #expect((expired["expiredAt"] as? Double ?? 0) > 0)
        session.clearSession()
        #expect(!session.isAuthenticated())
    }

    @Test func sessionRestoreRejectsGarbage() throws {
        let session = try CoreSession(computerName: "Mac")
        #expect(throws: CoreError.self) { try session.restore(snapshotJson: "not json") }
        let noCookie = Self.fakeSnapshot.replacingOccurrences(of: "sek.1.2", with: "")
        #expect(try !session.restore(snapshotJson: noCookie))
    }

    @Test func apiWithoutCookieThrowsAuthError() async throws {
        let api = CoreApi(session: try CoreSession(computerName: "Mac"))
        do {
            _ = try await api.fetchPinnedConversations()
            Issue.record("expected an error")
        } catch let CoreError.Session(code, _, isAuth) {
            #expect(code == 600)
            #expect(isAuth)
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(pollStateInitial().queues.count == 3)
    }

    @Test func storeChatPathMethods() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-core-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CoreStore.open(path: dir.appendingPathComponent("t.db").path)
        func row(_ id: String, _ ts: Int64) -> MessageRow {
            MessageRow(
                id: id, convId: "c1", clientId: "cli\(id)", senderId: "u1", senderName: "An", senderAvatar: "",
                isMine: false, text: "Xin chào", kindTag: "text", tsMs: ts, status: "sent",
                rawJson: Data(#"{"id":"\#(id)","text":"Xin chào","reactions":[]}"#.utf8))
        }
        try await store.saveMessages(items: [row("100", 1_795_000_000_000), row("101", 1_795_000_001_000)])
        #expect(try await store.message(convId: "c1", idOrClientId: "100") != nil)
        #expect(try await store.message(convId: "c1", idOrClientId: "zzz") == nil)
        #expect(try await store.existingMessageIds(convId: "c1", ids: ["100", "999"]).contains("100"))
        #expect(try await store.searchMessages(convId: "c1", query: "xin", limit: 10).count == 2)
        let around = try await store.messagesAround(
            convId: "c1", targetTsMs: 1_795_000_000_000, beforeOldestTsMs: nil, contextBefore: 25, maxWindow: 3000)
        #expect(around.messages.count == 2)
        #expect(try await store.upgradeMessageId(convId: "c1", oldId: "101", newId: "5000", clientId: "cli101"))
        try await store.deleteMessage(convId: "c1", id: "5000")
        #expect(try await store.message(convId: "c1", idOrClientId: "5000") == nil)
        try await store.updateMessageReactionsJson(convId: "c1", id: "100", reactionsJson: Data("[]".utf8))
        try await store.markRecalled(convId: "c1", id: "100", cliMsgId: "")

        try await store.upsertConversation(item: ConversationRow(
            id: "c1", isGroup: false, name: "An", avatar: "", pinned: false, members: 0, unread: 0,
            previewText: "", previewTsMs: 0, previewFromMe: false, updatedAtMs: 1))
        try await store.setConversationUnread(id: "c1", unread: 2)
        try await store.setConversationPinned(id: "c1", pinned: true)
        let conv = try #require(try await store.loadConversations().first)
        #expect(conv.unread == 2 && conv.pinned)

        try await store.setPreferenceBool(key: "b", value: true)
        #expect(try await store.preferenceBool(key: "b", defaultValue: false))
        try await store.setPreferenceStrings(key: "s", value: ["a", "b"])
        #expect(try await store.preferenceStrings(key: "s") == ["a", "b"])
        try await store.setPreferenceData(key: "d", data: Data(#"{"x":1}"#.utf8))
        #expect(try await store.preferenceData(key: "d") == Data(#"{"x":1}"#.utf8))
        try await store.deletePreference(key: "d")
        #expect(try await store.preferenceData(key: "d") == nil)
    }
}
