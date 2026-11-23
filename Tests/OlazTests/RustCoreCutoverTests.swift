import Foundation
import OlazCore
import Testing

@testable import Olaz

/// Runs the same inputs through the Swift path and the Rust-core path (ADR-011) and asserts equal Swift-side results.
@Suite struct RustCoreCutoverTests {
    // MARK: helpers

    private static func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("olaz-cutover-\(UUID().uuidString)")
    }

    /// A comparable rendering of a parsed event (`ChatMessage` is Equatable, `ParsedWireEvent` is not).
    private static func render(_ ev: ParsedWireEvent) -> String {
        switch ev {
        case .message(let chat, let stored):
            let raw = (try? JSONSerialization.jsonObject(with: stored.rawJSONData)) as? NSDictionary
            return "message \(chat) | \(stored.id) \(stored.convId) \(stored.clientId) \(stored.senderId) \(stored.senderName) "
                + "\(stored.senderAvatar) \(stored.isMine) \(stored.text) \(stored.kindTag) \(stored.tsMs) \(stored.status) | "
                + "raw=\(raw?.description ?? "nil")"
        default:
            return "\(ev)"
        }
    }

    private static func equalEvents(_ a: [ParsedWireEvent], _ b: [ParsedWireEvent]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            switch (x, y) {
            case (.message(let c1, let s1), .message(let c2, let s2)):
                guard c1 == c2, s1.id == s2.id, s1.convId == s2.convId, s1.clientId == s2.clientId, s1.senderId == s2.senderId,
                      s1.senderName == s2.senderName, s1.senderAvatar == s2.senderAvatar, s1.isMine == s2.isMine,
                      s1.text == s2.text, s1.kindTag == s2.kindTag, s1.tsMs == s2.tsMs, s1.status == s2.status else { return false }
                let r1 = (try? JSONSerialization.jsonObject(with: s1.rawJSONData)) as? NSDictionary
                let r2 = (try? JSONSerialization.jsonObject(with: s2.rawJSONData)) as? NSDictionary
                guard let r1, let r2, r1.isEqual(r2) else { return false }
            default:
                guard Self.render(x) == Self.render(y) else { return false }
            }
        }
        return true
    }

    private static let lookup: @Sendable (String) -> (name: String, avatar: String)? = { uid in
        uid == "u1" ? (name: "An", avatar: "https://ava.example/an.jpg") : nil
    }

    // MARK: flag

    @Test func flagFollowsEnvironment() {
        if ProcessInfo.processInfo.environment["OLAZ_RUST_CORE"] == "1" {
            #expect(RustCore.isEnabled)
        }
    }

    // MARK: wire parser

    @Test func wireBatchMatchesSwiftParser() {
        let root: [String: Any] = [
            "error_code": 0,
            "data": [
                [
                    "threadId": "thread_ignored",
                    "type": 0,
                    "msgs": [
                        ["msgId": "201", "uidFrom": "0", "idTo": "0", "msgType": 1, "content": "Cloud note", "ts": 1000],
                        ["msgId": "202", "uidFrom": "peer1", "idTo": "0", "msgType": 5, "content": #"{"catId":0,"id":3,"type":7}"#, "ts": 2000],
                        ["msgId": "203", "uidFrom": "peer1", "idTo": "0", "msgType": "chat.recommended",
                         "content": ["action": "recommened.user", "title": "Nguyen Van B", "params": "777888", "thumb": "https://cdn.example/a.jpg"], "ts": 3000],
                        ["msgId": "204", "uidFrom": "peer1", "idTo": "0", "msgType": 31, "content": ["globalMsgId": "202"], "ts": 4000],
                        ["msgId": "205", "cliMsgId": "c205", "uidFrom": "u1", "idTo": "me123", "msgType": "webchat", "content": "Xin chào", "ts": 5000,
                         "quote": ["ownerId": "u1", "msg": "Tin cũ", "fromD": "x"]],
                        ["msgId": "206", "cliMsgId": "c206", "uidFrom": "me123", "idTo": "u1", "msgType": "chat.photo",
                         "content": ["hd": "https://cdn.example/p.jpg", "title": "Anh"], "ts": 6000],
                        ["msgId": "207", "cliMsgId": "c207", "uidFrom": "u1", "idTo": "me123", "msgType": "chat.recommended",
                         "content": ["action": "recommened.link", "href": "https://example.com", "title": "Example"], "ts": 7000],
                        ["msgType": "chat.delete", "uidFrom": "u1", "idTo": "me123", "content": ["globalMsgId": "205", "cliMsgId": "c205"]]
                    ]
                ]
            ]
        ]
        let swift = ZaloWireParser.extractBatchEvents(root, myUid: "me123", selfConvId: "cloud999", nameLookup: Self.lookup, useRustCore: false)
        let rust = ZaloWireParser.extractBatchEvents(root, myUid: "me123", selfConvId: "cloud999", nameLookup: Self.lookup, useRustCore: true)
        #expect(!swift.isEmpty)
        #expect(Self.equalEvents(swift, rust))
        if !Self.equalEvents(swift, rust) {
            for (a, b) in zip(swift, rust) where Self.render(a) != Self.render(b) {
                print("DIFF swift:", Self.render(a)); print("DIFF rust: ", Self.render(b))
            }
        }
        // The pre-resolved name table reaches the Rust parser.
        let named = rust.compactMap { ev -> ChatMessage? in if case .message(let m, _) = ev, m.id == "205" { return m } else { return nil } }.first
        #expect(named?.senderName == "An")
    }

    @Test func wireReactionUndoAndGroupHintMatchSwiftParser() {
        let root: [String: Any] = [
            "data": [
                "reactGroups": [
                    ["uidFrom": "peer2", "idTo": "999", "ts": 1234,
                     "content": ["rIcon": "/-heart", "rType": 5, "rMsg": [["gMsgID": "300", "cMsgID": "300"]]]]
                ],
                "reacts": [
                    ["uidFrom": "peer3", "idTo": "me123", "content": ["rIcon": "/-strong", "rType": 3, "rMsg": [["gMsgID": "301", "cMsgID": "c301"]]]]
                ],
                "groupMsgs": [
                    ["msgId": "310", "cliMsgId": "c310", "uidFrom": "peer2", "idTo": "999", "msgType": "webchat", "content": "nhóm", "ts": 2000],
                    ["msgType": "chat.undo", "uidFrom": "peer2", "idTo": "999", "content": ["globalMsgId": "310", "cliMsgId": "c310"]]
                ]
            ]
        ]
        let swift = ZaloWireParser.extractBatchEvents(root, myUid: "me123", selfConvId: "cloud999", defaultCmd: ZaloWebSocket.cmdPushMsgGroup, useRustCore: false)
        let rust = ZaloWireParser.extractBatchEvents(root, myUid: "me123", selfConvId: "cloud999", defaultCmd: ZaloWebSocket.cmdPushMsgGroup, useRustCore: true)
        #expect(swift.count >= 4)
        #expect(Self.equalEvents(swift, rust))
        let sortedSwift = ZaloWireParser.sortReactionEventsChronologically(swift).map(Self.render)
        let sortedRust = ZaloWireParser.sortReactionEventsChronologically(rust).map(Self.render)
        #expect(sortedSwift == sortedRust)
    }

    @Test func wireBigIdsSurviveTheBridge() {
        let root: [String: Any] = ["data": ["msgs": [
            ["msgId": "7412345678901234567", "cliMsgId": "7412345678901234568", "uidFrom": "peer", "idTo": "me", "msgType": "webchat", "content": "x", "ts": 1_795_000_000_000]
        ]]]
        let rust = ZaloWireParser.extractBatchEvents(root, myUid: "me", useRustCore: true)
        guard case .message(let msg, let stored)? = rust.first else {
            Issue.record("expected a message"); return
        }
        #expect(msg.id == "7412345678901234567")
        #expect(stored.clientId == "7412345678901234568")
    }

    @MainActor
    @Test func asyncBatchEntryPointMatchesSync() async {
        let root: [String: Any] = ["data": ["msgs": [
            ["msgId": "1", "cliMsgId": "c1", "uidFrom": "u1", "idTo": "me", "msgType": "webchat", "content": "hi", "ts": 1000]
        ]]]
        let sync = ZaloWireParser.extractBatchEvents(root, myUid: "me", nameLookup: Self.lookup, useRustCore: true)
        let async = await ZaloWireParser.extractBatchEventsAsync(root, myUid: "me", nameLookup: Self.lookup, useRustCore: true)
        let swift = await ZaloWireParser.extractBatchEventsAsync(root, myUid: "me", nameLookup: Self.lookup, useRustCore: false)
        #expect(Self.equalEvents(sync, async))
        #expect(Self.equalEvents(sync, swift))
    }

    // MARK: store

    @Test func storeRoundTripMatchesAcrossPaths() async throws {
        let dirSwift = Self.tempDir(), dirRust = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dirSwift); try? FileManager.default.removeItem(at: dirRust) }
        let swiftStore = try ZaloSQLiteStore(path: dirSwift.appendingPathComponent("t.db").path, useRustCore: false)
        let rustStore = try ZaloSQLiteStore(path: dirRust.appendingPathComponent("t.db").path, useRustCore: true)

        let convs = [
            StoredConversation(id: "u1", isGroup: false, name: "An", avatar: "", pinned: false, members: 0, unread: 2, previewText: "Hi", previewTsMs: 1000, previewFromMe: false, updatedAtMs: 1000),
            StoredConversation(id: "g2", isGroup: true, name: "Team", avatar: "a", pinned: true, members: 5, unread: 0, previewText: "Yo", previewTsMs: 500, previewFromMe: true, updatedAtMs: 500)
        ]
        let events = ZaloWireParser.extractBatchEvents(["data": ["msgs": [
            ["msgId": "101", "cliMsgId": "c1", "uidFrom": "u1", "idTo": "me", "msgType": "webchat", "content": "Tin 1", "ts": 1000],
            ["msgId": "102", "cliMsgId": "c2", "uidFrom": "me", "idTo": "u1", "msgType": "chat.photo", "content": ["hd": "https://cdn.example/p.jpg", "title": "Anh"], "ts": 2000],
            ["msgId": "103", "cliMsgId": "c3", "uidFrom": "u1", "idTo": "me", "msgType": "chat.recommended", "content": ["action": "recommened.link", "href": "https://example.com", "title": "Example"], "ts": 3000]
        ]]], myUid: "me", useRustCore: false)
        let stored: [StoredMessage] = events.compactMap { if case .message(_, let s) = $0 { s } else { nil } }
        #expect(stored.count == 3)

        for store in [swiftStore, rustStore] {
            try await store.saveConversations(convs)
            try await store.saveMessages(stored)
            try await store.setPreferenceStrings(key: "pinnedIds", value: ["g2"])
            try await store.setPreferenceBool(key: "flag", value: true)
            try await store.markRecalled(convId: "u1", id: "101")
            try await store.updateMessageReactionsJSON(convId: "u1", id: "102", reactionsJSONData: Data(#"[{"type":"5","key":"/-heart","emoji":"❤️","image":"","count":1,"includesMe":true,"names":["Bạn"],"people":1,"userCounts":{"me":1}}]"#.utf8))
            try await store.deleteMessage(convId: "u1", id: "103")
        }
        #expect(try await swiftStore.loadConversations() == rustStore.loadConversations())
        #expect(try await swiftStore.messages(convId: "u1", limit: 10).map(\.id) == ["101", "102"])
        let a = try await swiftStore.messages(convId: "u1", limit: 10)
        let b = try await rustStore.messages(convId: "u1", limit: 10)
        #expect(a.count == b.count)
        for (x, y) in zip(a, b) {
            #expect(x.id == y.id && x.kindTag == y.kindTag && x.text == y.text && x.tsMs == y.tsMs && x.status == y.status)
            let rx = try JSONSerialization.jsonObject(with: x.rawJSONData) as? NSDictionary
            let ry = try JSONSerialization.jsonObject(with: y.rawJSONData) as? NSDictionary
            #expect(rx?.isEqual(ry) == true)
        }
        #expect(try await rustStore.messages(convId: "u1", beforeTsMs: 1_500_000, limit: 5).map(\.id) == ["101"])
        #expect(try await rustStore.getPreferenceStrings(key: "pinnedIds") == ["g2"])
        #expect(try await rustStore.getPreferenceBool(key: "flag") == true)
        #expect(try await rustStore.existingMessageIds(convId: "u1", ids: ["101", "c2", "nope"]) == swiftStore.existingMessageIds(convId: "u1", ids: ["101", "c2", "nope"]))
        #expect(try await rustStore.searchMessages(conversationId: "u1", query: "anh").count == swiftStore.searchMessages(conversationId: "u1", query: "anh").count)

        // Mixed paths share one file (ADR-010): a Swift-only handle reads what the Rust handle wrote.
        let sharedPath = dirRust.appendingPathComponent("t.db").path
        let swiftReader = try ZaloSQLiteStore(path: sharedPath, useRustCore: false)
        #expect(try await swiftReader.messages(convId: "u1", limit: 10).map(\.id) == ["101", "102"])
    }

    // MARK: websocket cursors

    @Test func wsCursorSnapshotRoundTripsThroughBothPaths() async throws {
        let seed: [String: ZaloWSQueueCursorSnapshot] = [
            "501_0": ZaloWSQueueCursorSnapshot(lastId: "7412345678901234567", preIds: ["7412345678901234560"]),
            "521_0": ZaloWSQueueCursorSnapshot(lastId: "99", preIds: []),
            "510_0": ZaloWSQueueCursorSnapshot(lastId: "1", preIds: [])   // initial cursor: dropped by both paths
        ]
        let swiftWS = ZaloWebSocket(useRustCore: false)
        let rustWS = ZaloWebSocket(useRustCore: true)
        await swiftWS.seedQueueCursors(seed)
        await rustWS.seedQueueCursors(seed)
        let s = await swiftWS.currentQueueCursors()
        let r = await rustWS.currentQueueCursors()
        #expect(s == r)
        #expect(r.keys.sorted() == ["501_0", "521_0"])

        // Same preference key / JSON shape the engine persists under `wsQueueCursors`.
        let data = try JSONEncoder().encode(r)
        #expect(try JSONDecoder().decode([String: ZaloWSQueueCursorSnapshot].self, from: data) == s)

        // Core -> Swift: cursor updates reach the observer exactly when they change.
        final class Sink: @unchecked Sendable { var seen: [[String: ZaloWSQueueCursorSnapshot]] = [] }
        let sink = Sink()
        let box = RustWSCursorBox()
        box.setObserver { sink.seen.append($0) }
        let entries = [CursorEntry(queueKey: "501_0", lastId: "42", preIds: ["41"])]
        box.update(entries)
        box.update(entries)   // unchanged: no second notification
        #expect(sink.seen.count == 1)
        #expect(sink.seen.first?["501_0"] == ZaloWSQueueCursorSnapshot(lastId: "42", preIds: ["41"]))
        #expect(RustWSCursorBox.entries(box.current()) == entries)
    }

    // MARK: session bridge

    @Test func sessionClientPushesLiveStateToTheCore() async throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = ZaloSessionClient(dataDirectory: dir, useKeychain: false, useRustCore: true)
        #expect(await client.coreApi() == nil)   // no account yet: Swift path reports notAuthenticated
        await client.updateCredentials(
            account: ZaloLoginAccount(userId: "100", displayName: "An", send2MeId: "999", zpwEnk: "0123456789abcdef", zpwSek: "sek.1.2"),
            secretKey: Data("0123456789abcdef".utf8), zpwSek: "sek.1.2")
        #expect(await client.coreApi() != nil)
        let swiftOnly = ZaloSessionClient(dataDirectory: dir, useKeychain: false, useRustCore: false)
        #expect(await swiftOnly.coreApi() == nil)
    }

    @Test func coreErrorsMapToTheErrorsTheEngineHandles() {
        let auth = RustCore.mapError(CoreError.Session(code: 600, message: "x", isAuth: true))
        #expect((auth as? ZaloSessionError)?.isAuthError == true)
        #expect(RustCore.mapError(CoreError.Network(kind: .timeout, message: "t")) is URLError)
        #expect(RustCore.mapError(CoreError.NotAuthenticated) is ZaloTransportError)
    }

    // MARK: typed path (no JSON re-parse in Swift)

    /// One wire message of each kind the parser produces, plus reactions' targets, quote, mentions, e2ee placeholder and a
    /// recall: the typed core path must equal the Swift parser (ChatMessage and canonical row JSON).
    private static var kindFixtures: [String: Any] {
        let cipher = "AzMIARIgmPWlMdiC4wZ0hVUkXfJNMGeaKzuZQHfDCq7xsZVv2DMYASAAKhBRjyzr+XbYlKSf6RJpDsNYYEQQBKQD3BpgD3Z3lXe7e0yLmZm/Bpf2gTLm1y6lcAsaZnlYFuE="
        let msgs: [[String: Any]] = [
            ["msgId": "1001", "cliMsgId": "c1001", "uidFrom": "u1", "idTo": "me", "msgType": "webchat", "content": "Chào @An và mọi người", "ts": 1_000,
             "mentions": [["uid": "u1", "pos": 5, "len": 3, "type": 0], ["uid": "-1", "pos": 12, "len": 9, "type": 1]],
             "quote": ["ownerId": "u1", "msg": "Tin cũ", "fromD": "An cũ"]],
            ["msgId": "1002", "cliMsgId": "c1002", "uidFrom": "me", "idTo": "u1", "msgType": "chat.photo",
             "content": ["hd": "https://cdn.example/p.jpg", "normalUrl": "https://cdn.example/n.jpg", "title": "Ảnh đẹp", "params": ["width": 640, "height": 480]], "ts": 2_000],
            ["msgId": "1003", "cliMsgId": "c1003", "uidFrom": "u1", "idTo": "me", "msgType": "chat.sticker", "content": ["id": 3, "catId": 0, "type": 7], "ts": 3_000],
            ["msgId": "1004", "cliMsgId": "c1004", "uidFrom": "u1", "idTo": "me", "msgType": "chat.gif", "content": ["href": "https://cdn.example/a.gif"], "ts": 4_000],
            ["msgId": "1005", "cliMsgId": "c1005", "uidFrom": "u1", "idTo": "me", "msgType": "chat.video.msg",
             "content": ["href": "https://cdn.example/v.mp4", "thumb": "https://cdn.example/v.jpg", "title": "Clip", "params": ["duration": 12_000]], "ts": 5_000],
            ["msgId": "1006", "cliMsgId": "c1006", "uidFrom": "u1", "idTo": "me", "msgType": "chat.voice",
             "content": ["href": "https://cdn.example/v.m4a", "params": ["duration": 3_000]], "ts": 6_000],
            ["msgId": "1007", "cliMsgId": "c1007", "uidFrom": "u1", "idTo": "me", "msgType": "share.file",
             "content": ["title": "báo cáo", "href": "https://cdn.example/f.pdf", "params": ["fileExt": "pdf", "fileSize": "123456"]], "ts": 7_000],
            ["msgId": "1008", "cliMsgId": "c1008", "uidFrom": "u1", "idTo": "me", "msgType": "chat.recommended",
             "content": ["action": "recommened.link", "href": "https://example.com/x", "title": "Ví dụ", "description": "Mô tả", "thumb": "https://cdn.example/t.jpg"], "ts": 8_000],
            ["msgId": "1009", "cliMsgId": "c1009", "uidFrom": "u1", "idTo": "me", "msgType": "chat.recommended",
             "content": ["action": "recommened.link", "href": "file:///etc/passwd", "title": "bad"], "ts": 9_000],
            ["msgId": "1010", "cliMsgId": "c1010", "uidFrom": "u1", "idTo": "me", "msgType": "chat.recommended",
             "content": ["action": "recommened.user", "title": "Nguyễn Văn B", "params": "777888", "thumb": "https://cdn.example/a.jpg"], "ts": 10_000],
            ["msgId": "1011", "cliMsgId": "c1011", "uidFrom": "u1", "idTo": "me", "msgType": "chat.location.new",
             "content": ["title": "Quán", "description": "Hà Nội", "params": ["lat": 21.0285, "lon": 105.8542, "locationName": "Quán cà phê"]], "ts": 11_000],
            ["msgId": "1012", "cliMsgId": "c1012", "uidFrom": "u1", "idTo": "me", "msgType": "chat.recommended",
             "content": ["action": "recommened.misscall", "params": ["duration": 0]], "ts": 12_000],
            ["msgId": "1013", "cliMsgId": "c1013", "uidFrom": "u1", "idTo": "me", "msgType": "chat.ecard",
             "content": ["action": "ecard.reminder", "title": "Họp", "description": "10h", "href": "https://cdn.example/e.png", "params": ["startTime": 1_795_000_000_000, "topicTitle": "Họp nhóm", "repeatLabel": "Hằng ngày"]], "ts": 13_000],
            ["msgId": "1014", "cliMsgId": "c1014", "uidFrom": "u1", "idTo": "me", "msgType": "chat.poll",
             "content": ["question": "Ăn gì?", "description": "An đã bình chọn", "params": ["poll_id": "77", "is_anonymous": false]], "ts": 14_000],
            ["msgId": "1015", "cliMsgId": "c1015", "uidFrom": "u1", "idTo": "me", "msgType": "chat.sys", "content": ["title": "Nhóm đổi tên"], "ts": 15_000],
            ["msgId": "1016", "cliMsgId": "c1016", "uidFrom": "u1", "idTo": "me", "msgType": "chat.webcontent", "content": ["title": "Zinstant", "description": "d", "thumb": "https://cdn.example/z.png"], "ts": 16_000],
            ["msgId": "1017", "cliMsgId": "c1017", "uidFrom": "u1", "idTo": "me", "msgType": "webchat", "content": cipher, "ts": 17_000],
            ["msgId": "1018", "cliMsgId": "c1018", "uidFrom": "u1", "idTo": "me", "msgType": "chat.mystery", "content": ["title": "lạ"], "ts": 18_000],
            ["msgId": "1019", "cliMsgId": "c1019", "uidFrom": "u1", "idTo": "me", "msgType": "chat.sticker", "content": ["id": cipher, "catId": cipher, "type": cipher], "ts": 19_000],
            ["msgType": "chat.undo", "uidFrom": "u1", "idTo": "me", "content": ["globalMsgId": "1001", "cliMsgId": "c1001"]]
        ]
        return ["data": ["msgs": msgs]]
    }

    @Test func typedWireKindsMatchSwiftParser() {
        let root = Self.kindFixtures
        let swift = ZaloWireParser.extractBatchEvents(root, myUid: "me", selfConvId: "cloud999", nameLookup: Self.lookup, useRustCore: false)
        let rust = ZaloWireParser.extractBatchEvents(root, myUid: "me", selfConvId: "cloud999", nameLookup: Self.lookup, useRustCore: true)
        #expect(swift.count >= 19)
        #expect(Self.equalEvents(swift, rust))
        if !Self.equalEvents(swift, rust) {
            for (a, b) in zip(swift, rust) where Self.render(a) != Self.render(b) {
                print("DIFF swift:", Self.render(a)); print("DIFF rust: ", Self.render(b))
            }
        }
        // Every message kind of the fixture set is covered.
        var tags = Set<String>()
        for case .message(_, let stored) in rust { tags.insert(stored.kindTag) }
        for tag in ["text", "photo", "sticker", "gif", "video", "voice", "file", "link", "contactCard", "location", "call", "ecard", "poll", "system", "placeholder", "unsupported"] {
            #expect(tags.contains(tag), "kind \(tag) missing from fixtures (got \(tags.sorted()))")
        }
    }

    /// Canonical stored rows with every field shape (reactions incl. ghosts, quotes, mentions, menus, buttons, odd URLs).
    private static func storedFixtureRows() -> [StoredMessage] {
        func row(_ id: String, _ ts: Int64, kind: String = "text", _ json: [String: Any]) -> StoredMessage {
            var dict = json
            dict["id"] = id; dict["clientId"] = dict["clientId"] ?? "cli\(id)"; dict["conversationId"] = "u1"; dict["date"] = ts
            dict["kind"] = dict["kind"] ?? ["type": kind]
            let raw = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
            return StoredMessage(id: id, convId: "u1", clientId: dict["clientId"] as? String ?? "", senderId: "u1", senderName: "An", senderAvatar: "", isMine: false,
                                 text: dict["text"] as? String ?? "", kindTag: (dict["kind"] as? [String: Any])?["type"] as? String ?? "text", tsMs: ts, status: "sent", rawJSONData: raw)
        }
        let heart: [String: Any] = ["type": "5", "key": "/-heart", "emoji": "❤️", "image": "", "count": 3, "includesMe": true, "names": ["Bạn", "An"], "people": 2, "userCounts": ["me": 1, "u1": 2]]
        let ghost: [String: Any] = ["type": "3", "key": "/-strong", "emoji": "👍", "image": "", "count": 1, "includesMe": false, "names": ["Người dùng Zalo"], "people": 1]
        let sentinel: [String: Any] = ["type": "0", "key": ":>", "emoji": "😆", "count": 2, "includesMe": false, "names": ["Lan"], "people": 1, "userCounts": ["__legacy__": 2]]
        let menu: [String: Any] = ["forward": "ok", "recall": true, "delete": "forMe", "pin": true, "star": "unstar", "starred": true, "pinned": true, "protected": true]
        return [
            row("2001", 1_000, ["text": "xin chào", "senderAvatar": "https://ava.example/a.jpg", "isMine": true, "status": "delivered", "reactions": [heart, ghost, sentinel],
                              "mentions": [["uid": "u2", "pos": 1, "len": 3, "isAll": false], ["uid": "", "pos": 0, "len": 1]], "menu": menu,
                              "quote": ["senderName": "An", "text": "tin cũ"], "isE2EE": true, "buttons": [["ref": "b1", "label": "  Mở  ", "enabled": true, "help": "h"], ["ref": "", "label": "x"]], "stickers": true]),
            row("2002", 2_000, kind: "photo", ["kind": ["type": "photo", "url": "https://cdn.example/p.jpg", "width": 640.0, "height": 480, "fallbacks": ["https://cdn.example/n.jpg", "", "ht tp://bad url"]], "text": "Ảnh"]),
            row("2003", 3_000, kind: "sticker", ["kind": ["type": "sticker", "url": "  https://cdn.example/s.png "], "text": "[Sticker]"]),
            row("2004", 4_000, kind: "link", ["kind": ["type": "link", "title": "T", "url": "javascript:alert(1)", "thumbnail": "https://cdn.example/t.jpg", "description": "d", "source": "s"]]),
            row("2005", 5_000, kind: "link", ["kind": ["type": "link", "title": "T", "url": "https://example.com/ok", "thumbnail": "", "description": "d", "source": "example.com"]]),
            row("2006", 6_000, kind: "file", ["kind": ["type": "file", "name": "a.pdf", "size": 1.5e9, "url": "https://cdn.example/a.pdf"], "text": "a.pdf"]),
            row("2007", 7_000, kind: "location", ["kind": ["type": "location", "title": "Quán", "address": "Hà Nội", "hasCoordinates": true, "latitude": 21.03, "longitude": 105.85, "thumbnail": "https://cdn.example/m.png"]]),
            row("2008", 8_000, kind: "location", ["kind": ["type": "location", "title": "Sai", "address": "", "hasCoordinates": true, "latitude": 999.0, "longitude": 105.85, "thumbnail": ""]]),
            row("2009", 9_000, kind: "ecard", ["kind": ["type": "ecard", "style": "birthday", "image": "https://cdn.example/e.png", "thumb": "", "title": "SN", "description": "d", "actions": ["a", "", "b"], "avatars": ["https://cdn.example/1.png", "bad url"], "reminderTitle": "r", "reminderStart": 5.0e12, "reminderRepeat": ""]]),
            row("2010", 10_000, kind: "ecard", ["kind": ["type": "ecard", "style": "weird", "title": "x", "reminderStart": 1_795_000_000_000.0]]),
            row("2011", 11_000, kind: "oaMessage", ["kind": ["type": "oaMessage", "parts": [["header": true, "title": "Tiêu đề", "description": "d", "thumb": "https://cdn.example/h.png", "url": "https://oa.example/1", "help": ""], ["title": "", "thumb": ""], ["header": false, "title": "Dòng", "url": "file:///x"]]]]),
            row("2012", 12_000, kind: "poll", ["kind": ["type": "poll", "question": "Q", "header": "H", "anonymous": true, "pollId": "9", "conversationId": "u1"]]),
            row("2013", 13_000, kind: "call", ["kind": ["type": "call", "video": true, "missed": true, "duration": 65, "title": "Bạn bị nhỡ", "detail": "1 phút"]]),
            row("2014", 14_000, kind: "contactCard", ["kind": ["type": "contactCard", "name": "B", "uid": "77", "avatar": "https://cdn.example/b.png", "phone": "0900", "qr": "", "oaLink": "", "isOA": true]]),
            row("2015", 15_000, kind: "placeholder", ["kind": ["type": "placeholder", "symbol": "", "text": "🔒 Tin nhắn mã hóa"], "isE2EE": true]),
            row("2016", 16_000, kind: "notice", ["kind": ["type": "notice", "symbol": "", "text": "Thông báo"]]),
            row("2017", 17_000, kind: "recalled", ["text": "", "reactions": []]),
            row("2018", 18_000, kind: "unsupported", ["kind": ["type": "unsupported", "rawType": "chat.x"]]),
            row("2019", 19_000, kind: "video", ["kind": ["type": "video", "thumbnail": "https://cdn.example/v.jpg", "duration": 12, "url": "https://cdn.example/v.mp4"]]),
            row("2020", 20_000, kind: "voice", ["kind": ["type": "voice", "url": "https://cdn.example/v.m4a", "duration": 3]]),
            row("2021", 21_000, kind: "zinstant", ["kind": ["type": "zinstant", "title": "Z", "text": "t", "thumb": "https://cdn.example/z.png"]]),
            row("2022", 22_000, kind: "stickerSet", ["kind": ["type": "stickerSet", "title": "Bộ", "thumb": ""]]),
            row("2023", 23_000, kind: "gif", ["kind": ["type": "gif", "url": "https://cdn.example/a.gif"]]),
            row("2024", 24_000, kind: "system", ["text": "Nhóm đổi tên"]),
            StoredMessage(id: "2025", convId: "u1", clientId: "cli2025", senderId: "u1", senderName: "An", senderAvatar: "", isMine: false, text: "hỏng", kindTag: "text", tsMs: 25_000, status: "sent", rawJSONData: Data("not json".utf8)),
            // No clientId in the raw JSON: decode falls back to the column.
            StoredMessage(id: "2026", convId: "u1", clientId: "colcli", senderId: "u1", senderName: "An", senderAvatar: "", isMine: false, text: "t", kindTag: "text", tsMs: 26_000, status: "sent",
                          rawJSONData: Data(#"{"id":"2026","conversationId":"u1","kind":{"type":"text"},"text":"t","date":26000}"#.utf8))
        ]
    }

    @Test func typedStoreReadsMatchSwiftDecode() async throws {
        let dirSwift = Self.tempDir(), dirRust = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dirSwift); try? FileManager.default.removeItem(at: dirRust) }
        let swiftStore = try ZaloSQLiteStore(path: dirSwift.appendingPathComponent("t.db").path, useRustCore: false)
        let rustStore = try ZaloSQLiteStore(path: dirRust.appendingPathComponent("t.db").path, useRustCore: true)
        let rows = Self.storedFixtureRows()
        for store in [swiftStore, rustStore] { try await store.saveMessages(rows) }

        func same(_ a: [DecodedMessageRow], _ b: [DecodedMessageRow]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { $0.message == $1.message && $0.rowId == $1.rowId && $0.rowClientId == $1.rowClientId }
        }
        func firstDiff(_ a: [DecodedMessageRow], _ b: [DecodedMessageRow]) -> String {
            for (x, y) in zip(a, b) where x.message != y.message { return "swift \(x.message)\nrust  \(y.message)" }
            return "count \(a.count) vs \(b.count)"
        }
        let a = try await swiftStore.decodedMessages(convId: "u1", limit: 100)
        let b = try await rustStore.decodedMessages(convId: "u1", limit: 100)
        #expect(a.count == rows.count - 1)   // the corrupt row drops on both paths
        #expect(same(a, b), "\(firstDiff(a, b))")
        let sa = swiftStore.readDecodedMessagesNow(convId: "u1", beforeTsMs: 20_500, limit: 100)
        let sb = rustStore.readDecodedMessagesNow(convId: "u1", beforeTsMs: 20_500, limit: 100)
        #expect(sa != nil && sb != nil && same(sa ?? [], sb ?? []))
        let na = swiftStore.readDecodedMessagesNow(convId: "u1", limit: 5)
        let nb = rustStore.readDecodedMessagesNow(convId: "u1", limit: 5)
        #expect(na != nil && nb != nil && same(na ?? [], nb ?? []))
        let qa = try await swiftStore.decodedSearch(conversationId: "u1", query: "xin", limit: 10)
        let qb = try await rustStore.decodedSearch(conversationId: "u1", query: "xin", limit: 10)
        #expect(same(qa, qb))
        let wa = try await swiftStore.decodedMessagesAround(convId: "u1", targetTsMs: 5_000, beforeOldestTsMs: nil, contextBefore: 2, maxWindow: 6)
        let wb = try await rustStore.decodedMessagesAround(convId: "u1", targetTsMs: 5_000, beforeOldestTsMs: nil, contextBefore: 2, maxWindow: 6)
        #expect(same(wa.rows, wb.rows) && wa.hasMoreOlder == wb.hasMoreOlder)
    }

    @Test func chatMessageRecordRoundTripsAndSavesLikeSwift() async throws {
        let decoded = Self.storedFixtureRows().compactMap { ZaloWireParser.decodeStoredMessage($0) }
        #expect(decoded.count == Self.storedFixtureRows().count - 1)
        for m in decoded {
            // record -> ChatMessage is the identity on values the Swift decoder produced (fallback URLs / URLs survive).
            let back = ChatMessage(record: ChatMessageRecord(message: m))
            #expect(back == m, "record round trip changed \(m.id)")
        }
        let dirSwift = Self.tempDir(), dirRust = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dirSwift); try? FileManager.default.removeItem(at: dirRust) }
        let swiftStore = try ZaloSQLiteStore(path: dirSwift.appendingPathComponent("t.db").path, useRustCore: false)
        let rustStore = try ZaloSQLiteStore(path: dirRust.appendingPathComponent("t.db").path, useRustCore: true)
        try await swiftStore.saveChatMessages(decoded)
        try await rustStore.saveChatMessages(decoded)
        let a = try await swiftStore.messages(convId: "u1", limit: 100)
        let b = try await rustStore.messages(convId: "u1", limit: 100)
        #expect(a.count == b.count && a.count == decoded.count)
        for (x, y) in zip(a, b) {
            #expect(x.id == y.id && x.kindTag == y.kindTag && x.text == y.text && x.tsMs == y.tsMs && x.clientId == y.clientId)
            let rx = try JSONSerialization.jsonObject(with: x.rawJSONData) as? NSDictionary
            let ry = try JSONSerialization.jsonObject(with: y.rawJSONData) as? NSDictionary
            #expect(rx?.isEqual(ry) == true, "row \(x.id) differs: \(String(decoding: x.rawJSONData, as: UTF8.self)) vs \(String(decoding: y.rawJSONData, as: UTF8.self))")
        }
    }
}
