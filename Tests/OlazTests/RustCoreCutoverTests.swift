import Foundation
import OlazCore
import Testing

@testable import Olaz

/// Rust-core bridge sanity tests (after ADR-017 removed the Swift fallback).
@Suite struct RustCoreCutoverTests {
    private static func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("olaz-cutover-\(UUID().uuidString)")
    }

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

    // MARK: wire parser

    @Test func wireBigIdsSurviveTheBridge() {
        let root: [String: Any] = ["data": ["msgs": [
            ["msgId": "7412345678901234567", "cliMsgId": "7412345678901234568", "uidFrom": "peer", "idTo": "me", "msgType": "webchat", "content": "x", "ts": 1_795_000_000_000]
        ]]]
        let rust = ZaloWireParser.extractBatchEvents(root, myUid: "me")
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
        let sync = ZaloWireParser.extractBatchEvents(root, myUid: "me", nameLookup: Self.lookup)
        let async = await ZaloWireParser.extractBatchEventsAsync(root, myUid: "me", nameLookup: Self.lookup)
        #expect(Self.equalEvents(sync, async))
    }

    // MARK: websocket cursors

    @Test func wsCursorSnapshotRoundTrips() async throws {
        let seed: [String: ZaloWSQueueCursorSnapshot] = [
            "501_0": ZaloWSQueueCursorSnapshot(lastId: "7412345678901234567", preIds: ["7412345678901234560"]),
            "521_0": ZaloWSQueueCursorSnapshot(lastId: "99", preIds: []),
            "510_0": ZaloWSQueueCursorSnapshot(lastId: "1", preIds: [])   // initial cursor: dropped
        ]
        let rustWS = ZaloWebSocket()
        await rustWS.seedQueueCursors(seed)
        let r = await rustWS.currentQueueCursors()
        #expect(r.keys.sorted() == ["501_0", "521_0"])

        // Same preference key / JSON shape the engine persists under `wsQueueCursors`.
        let data = try JSONEncoder().encode(r)
        #expect(try JSONDecoder().decode([String: ZaloWSQueueCursorSnapshot].self, from: data) == r)

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
        let client = ZaloSessionClient(dataDirectory: dir, useKeychain: false)
        #expect(await client.coreApi() == nil)   // no account yet
        await client.updateCredentials(
            account: ZaloLoginAccount(userId: "100", displayName: "An", send2MeId: "999", zpwEnk: "0123456789abcdef", zpwSek: "sek.1.2"),
            secretKey: Data("0123456789abcdef".utf8), zpwSek: "sek.1.2")
        #expect(await client.coreApi() != nil)
    }

    @Test func coreErrorsMapToTheErrorsTheEngineHandles() {
        let auth = RustCore.mapError(CoreError.Session(code: 600, message: "x", isAuth: true))
        #expect((auth as? ZaloSessionError)?.isAuthError == true)
        #expect(RustCore.mapError(CoreError.Network(kind: .timeout, message: "t")) is URLError)
        #expect(RustCore.mapError(CoreError.NotAuthenticated) is ZaloTransportError)
    }

    // MARK: typed history page (wave 5a)

    private static var historyBody: [String: Any] { [
        "error_code": 0,
        "data": [
            "hasMore": 1, "isOld": 0, "lastMsgId": "7412345678901234500",
            "groupMsgs": [
                ["msgId": "7412345678901234567", "cliMsgId": "c1", "uidFrom": "u1", "idTo": "g1", "msgType": "webchat", "content": "Chào nhóm", "ts": 1_795_000_000_000,
                 "quote": ["ownerId": "u1", "msg": "Tin cũ", "fromD": "x"]],
                ["msgId": "7412345678901234568", "cliMsgId": "c2", "uidFrom": "me", "idTo": "g1", "msgType": "chat.photo", "content": ["hd": "https://cdn.example/p.jpg", "title": "Anh"], "ts": 1_795_000_001_000],
                ["msgType": "chat.undo", "uidFrom": "u1", "idTo": "g1", "content": ["globalMsgId": "7412345678901234567", "cliMsgId": "c1"]]
            ]
        ]
    ] }

    @MainActor
    @Test func historyPagePreservesHeadAndEvents() async throws {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: Self.historyBody), as: UTF8.self)
        let rustPage = ZaloHistoryPage(record: try historyRecordFromJson(json: json))
        #expect(rustPage.hasMore)
        #expect(!rustPage.isOld)
        #expect(rustPage.lastMsgId == "7412345678901234500")
        #expect(rustPage.uids == ["me", "u1"])
        for fallback in [("g1", true), ("g:g1", true)] {
            let events = await ZaloWireParser.historyEventsAsync(
                rustPage, myUid: "me", selfConvId: "cloud999", fallbackConvId: fallback.0, isGroupHint: fallback.1, nameLookup: Self.lookup)
            #expect(events.count >= 3)
        }
        // Raw JSON view still yields the whole answer (ids intact).
        let raw = rustPage.box.dict["data"] as? [String: Any]
        #expect(JSONLossless.string(raw?["lastMsgId"]) == "7412345678901234500")
        #expect((raw?["groupMsgs"] as? [[String: Any]])?.count == 3)
    }
}
