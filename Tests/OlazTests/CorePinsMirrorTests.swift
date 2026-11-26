import Foundation
import OlazCore
import Testing
@testable import Olaz

/// Proves that U7 optimistic MainActor pin/unpin updates are version-fenced against older
/// `CoreChangesRecord` board-refresh deltas and never end on (or momentarily revert to) an
/// earlier board list, while core error rollbacks at `>= targetVersion` reconcile authoritatively.
@Suite(.serialized) struct CorePinsMirrorTests {
    private static func pinsChanges(
        version: UInt64,
        pins: PinsSnapshotRecord
    ) -> CoreChangesRecord {
        CoreChangesRecord(
            version: version,
            session: nil,
            conversations: nil,
            conversationFlags: nil,
            conversationExtras: nil,
            conversationUi: nil,
            conversationPrompt: nil,
            windowDeltas: [],
            messagesResetAll: false,
            messageMeta: nil,
            contacts: nil,
            typing: nil,
            deleteUndo: nil,
            messageConfirm: nil,
            autoDelete: nil,
            starredIds: nil,
            cachedProfiles: nil,
            pins: pins
        )
    }

    @MainActor
    private static func makeBootedEngine(
        convId: String = "g500790",
        myUid: String = "2000790",
        serverExtra: [CaseJSON]
    ) async throws -> (engine: ZaloEngine, server: FakeZaloServer, cleanup: () -> Void) {
        let testEnk = Data("0123456789abcdef0123456789abcdef".utf8).base64EncodedString()
        let secretKey = ZaloCrypto.parseSecretKey(testEnk)

        var serverScript: [CaseJSON] = [
            .object([
                "kind": .string("http"),
                "path": .string("/api/login/getLoginInfo"),
                "response": .object([
                    "status": .int(200),
                    "json": .object([
                        "error_code": .int(0),
                        "data": .object([
                            "uid": .string(myUid),
                            "zpw_enk": .string(testEnk),
                            "zpw_sek": .string("sek.mirror.u7"),
                            "display_name": .string("Pin Mirror User"),
                            "send2me_id": .string("9200790"),
                            "zpw_ws": .array([.string("ws://fake")]),
                            "zpw_service_map_v3": .object([
                                "chat": .array([.string("http://fake")]),
                                "group": .array([.string("http://fake")]),
                                "group_board": .array([.string("http://fake")]),
                                "profile": .array([.string("http://fake")]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/social/profile/me-v2"),
                "response": .object([
                    "status": .int(200),
                    "json": .object([
                        "error_code": .int(0),
                        "data": .object([
                            "userId": .string(myUid),
                            "displayName": .string("Pin Mirror User"),
                        ]),
                    ]),
                ]),
            ]),
        ]
        serverScript.append(contentsOf: serverExtra)

        let server = try FakeZaloServer(serverScript: serverScript, initialSecretKey: secretKey)
        try await server.start()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-u7-mirror-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let dbURL = root
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(myUid, isDirectory: true)
            .appendingPathComponent("history.sqlite3")
        let seedStore = try ZaloSQLiteStore(path: dbURL.path)
        try await seedStore.setPreferenceString(key: ZaloWebKitMigrator.donePrefKey, value: "1")
        let baseMs: Int64 = 1_795_000_000_000
        try await seedStore.saveConversations([
            StoredConversation(
                id: convId,
                isGroup: true,
                name: "Pin Group",
                avatar: "",
                pinned: false,
                members: 3,
                unread: 0,
                previewText: "Target message",
                previewTsMs: baseMs + 2_000,
                previewFromMe: true,
                updatedAtMs: baseMs + 2_000
            ),
        ])
        let m1 = ChatMessage(
            id: "9100001",
            conversationId: convId,
            senderId: myUid,
            senderName: "Pin Mirror User",
            senderAvatar: nil,
            isMine: true,
            kind: .text,
            text: "Old pinned",
            date: Date(timeIntervalSince1970: Double(baseMs + 1_000) / 1000.0),
            status: .sent,
            quote: nil,
            reactions: [],
            isE2EE: false,
            clientId: "c9100001"
        )
        let m2 = ChatMessage(
            id: "9100002",
            conversationId: convId,
            senderId: myUid,
            senderName: "Pin Mirror User",
            senderAvatar: nil,
            isMine: true,
            kind: .text,
            text: "Target message",
            date: Date(timeIntervalSince1970: Double(baseMs + 2_000) / 1000.0),
            status: .sent,
            quote: nil,
            reactions: [],
            isE2EE: false,
            clientId: "c9100002"
        )
        let rows = [m1, m2].compactMap { ZaloWireParser.encodeChatMessage($0, clientId: $0.clientId) }
        try await seedStore.saveMessages(rows)

        var isolatedDomains = ZaloDomains()
        isolatedDomains.auth = server.baseURLString
        isolatedDomains.wpaChat = server.baseURLString
        isolatedDomains.lpChat = server.baseURLString
        isolatedDomains.lpControl = server.baseURLString
        isolatedDomains.ws = [server.wsBaseURLString]
        isolatedDomains.serviceCandidates = [
            "chat": [server.baseURLString],
            "group": [server.baseURLString],
            "group_board": [server.baseURLString],
            "profile": [server.baseURLString],
        ]
        isolatedDomains.isolated = true

        let savedSession: CaseJSON = .object([
            "zpwType": .string(ZaloDomains.zpwType),
            "imei": .string("00000000-0000-4000-8000-000000000000-00000000000000000000000000000000"),
            "computerName": .string("MirrorMac"),
            "domains": .object([
                "auth": .string(server.baseURLString),
                "wpaChat": .string(server.baseURLString),
                "lpChat": .string(server.baseURLString),
                "lpControl": .string(server.baseURLString),
                "ws": .array([.string(server.wsBaseURLString)]),
                "serviceCandidates": .object([
                    "chat": .array([.string(server.baseURLString)]),
                    "group": .array([.string(server.baseURLString)]),
                    "group_board": .array([.string(server.baseURLString)]),
                    "profile": .array([.string(server.baseURLString)]),
                ]),
                "preferredHosts": .object([:]),
                "isolated": .bool(true),
            ]),
            "sealedSecretsBase64": .null,
            "expiredAt": .null,
            "plainAccount": .object([
                "userId": .string(myUid),
                "displayName": .string("Pin Mirror User"),
                "avatar": .string(""),
                "phone": .string(""),
                "send2MeId": .string("9200790"),
                "dkey": .string("dk-mirror"),
                "zpwEnk": .string(testEnk),
                "zpwSek": .string("sek.mirror.u7"),
            ]),
        ])
        try Data(savedSession.canonicalString().utf8)
            .write(to: root.appendingPathComponent("native-session.json"), options: .atomic)

        let storage = RecorderStorageIsolation(prefix: "olaz.u7-mirror")
        let engine = ZaloEngine(
            dataDirectory: root,
            useKeychain: false,
            domains: isolatedDomains,
            userDefaultsSuiteName: storage.userDefaultsSuiteName,
            cookieStorage: storage.cookieStorage
        )
        engine.historyFreshness[convId] = .upToDate
        engine.hostTrace = { name, _ in
            name == "prepare_store" || name == "refresh_board_pins"
        }

        engine.start()
        _ = await engine.bootTask?.value
        #expect(engine.phase == .ready)
        engine.openConversation(convId)
        await engine.settleForRecording()
        let boardDeadline = ContinuousClock.now + .seconds(5)
        while engine.pins[convId]?.ready != true, ContinuousClock.now < boardDeadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect((engine.messages[convId]?.count ?? 0) == 2)

        return (engine, server, {
            server.stop()
            storage.cleanup()
            try? FileManager.default.removeItem(at: root)
        })
    }

    @MainActor
    @Test func olderBoardRefreshCannotRevertOptimisticPin() async throws {
        let convId = "g500790"
        let (engine, _, cleanup) = try await Self.makeBootedEngine(
            convId: convId,
            serverExtra: [
                // 1) Initial board refresh on open: 1 existing pin
                .object([
                    "kind": .string("http"),
                    "path": .string("/api/board/pin/list"),
                    "method": .string("GET"),
                    "response": .object([
                        "status": .int(200),
                        "json": .object([
                            "error_code": .int(0),
                            "data": .object([
                                "boardVersion": .int(1),
                                "pinLimit": .int(3),
                                "items": .array([
                                    .object([
                                        "id": .string("t_old"),
                                        "type": .int(2),
                                        "params": .object([
                                            "title": .string("Old pinned"),
                                            "senderName": .string("Pin Mirror User"),
                                            "global_msg_id": .string("9100001"),
                                            "client_msg_id": .string("c9100001"),
                                        ]),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
                // 2) Delayed pin request so stale delta arrives while pin is in-flight
                .object([
                    "kind": .string("http"),
                    "path": .string("/api/board/topic/createv2"),
                    "method": .string("POST"),
                    "delay_ms": .int(100),
                    "response": .object([
                        "status": .int(200),
                        "json": .object([
                            "error_code": .int(0),
                            "data": .object(["id": .string("t_new")]),
                        ]),
                    ]),
                ]),
                // 3) Authoritative post-pin board refresh
                .object([
                    "kind": .string("http"),
                    "path": .string("/api/board/pin/list"),
                    "method": .string("GET"),
                    "response": .object([
                        "status": .int(200),
                        "json": .object([
                            "error_code": .int(0),
                            "data": .object([
                                "boardVersion": .int(2),
                                "pinLimit": .int(3),
                                "items": .array([
                                    .object([
                                        "id": .string("t_new"),
                                        "type": .int(2),
                                        "params": .object([
                                            "title": .string("Target message"),
                                            "senderName": .string("Pin Mirror User"),
                                            "global_msg_id": .string("9100002"),
                                            "client_msg_id": .string("c9100002"),
                                        ]),
                                    ]),
                                    .object([
                                        "id": .string("t_old"),
                                        "type": .int(2),
                                        "params": .object([
                                            "title": .string("Old pinned"),
                                            "senderName": .string("Pin Mirror User"),
                                            "global_msg_id": .string("9100001"),
                                            "client_msg_id": .string("c9100001"),
                                        ]),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ]
        )
        defer { cleanup() }
        defer { engine.cancelTasksForRecording() }

        #expect(engine.pins[convId]?.items.map(\.ref) == ["t_old"])
        let targetMsg = try #require(engine.messages[convId]?.last)
        let olderVersion = engine.appliedMirrorVersion

        // Start pin: optimistic local:9100002 must appear synchronously on MainActor.
        engine.pin(targetMsg)
        #expect(engine.pins[convId]?.items.map(\.ref) == ["local:9100002", "t_old"])

        // Deliver a stale board-refresh delta carrying only [t_old] at olderVersion.
        let stalePins = PinsSnapshotRecord(
            lists: [
                PinnedListEntryRecord(
                    convId: convId,
                    ready: true,
                    canPin: true,
                    limit: 3,
                    items: [
                        PinnedItemRecord(
                            refId: "t_old",
                            kind: "message",
                            title: "Old pinned",
                            sender: "Pin Mirror User",
                            thumbnail: nil,
                            msgId: "9100001",
                            cliMsgId: "c9100001"
                        ),
                    ]
                ),
            ],
            rawTopics: []
        )
        engine.applyCoreChanges(Self.pinsChanges(version: olderVersion, pins: stalePins))

        // Must NOT revert the optimistic pin even momentarily.
        #expect(engine.pins[convId]?.items.map(\.ref) == ["local:9100002", "t_old"])

        // Once core completes the pin + post-pin refresh, authoritative server list settles and overlays drain.
        await engine.awaitMessageActionTasksForRecording()
        await engine.settleForRecording()
        #expect(engine.pins[convId]?.items.map(\.ref) == ["t_new", "t_old"])
        #expect(engine.optimisticMessageOverlays.isEmpty)

        await engine.finishTearDownForRecording()
    }

    @MainActor
    @Test func failedPinRollsBackAuthoritativelyOnError() async throws {
        let convId = "g500790"
        let (engine, _, cleanup) = try await Self.makeBootedEngine(
            convId: convId,
            serverExtra: [
                .object([
                    "kind": .string("http"),
                    "path": .string("/api/board/pin/list"),
                    "method": .string("GET"),
                    "repeat": .bool(true),
                    "response": .object([
                        "status": .int(200),
                        "json": .object([
                            "error_code": .int(0),
                            "data": .object([
                                "boardVersion": .int(1),
                                "pinLimit": .int(3),
                                "items": .array([
                                    .object([
                                        "id": .string("t_old"),
                                        "type": .int(2),
                                        "params": .object([
                                            "title": .string("Old pinned"),
                                            "senderName": .string("Pin Mirror User"),
                                            "global_msg_id": .string("9100001"),
                                            "client_msg_id": .string("c9100001"),
                                        ]),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
                .object([
                    "kind": .string("http"),
                    "path": .string("/api/board/topic/createv2"),
                    "method": .string("POST"),
                    "response": .object([
                        "status": .int(200),
                        "json": .object([
                            "error_code": .int(112),
                            "error_message": .string("Pin failed"),
                        ]),
                    ]),
                ]),
            ]
        )
        defer { cleanup() }
        defer { engine.cancelTasksForRecording() }

        let targetMsg = try #require(engine.messages[convId]?.last)
        engine.pin(targetMsg)
        #expect(engine.pins[convId]?.items.map(\.ref) == ["local:9100002", "t_old"])

        await engine.awaitMessageActionTasksForRecording()
        await engine.settleForRecording()
        #expect(engine.pins[convId]?.items.map(\.ref) == ["t_old"])
        #expect(engine.optimisticMessageOverlays.isEmpty)

        await engine.finishTearDownForRecording()
    }

    @MainActor
    @Test func olderBoardRefreshCannotRevertOptimisticUnpin() async throws {
        let convId = "g500790"
        let (engine, _, cleanup) = try await Self.makeBootedEngine(
            convId: convId,
            serverExtra: [
                .object([
                    "kind": .string("http"),
                    "path": .string("/api/board/pin/list"),
                    "method": .string("GET"),
                    "response": .object([
                        "status": .int(200),
                        "json": .object([
                            "error_code": .int(0),
                            "data": .object([
                                "boardVersion": .int(2),
                                "pinLimit": .int(3),
                                "items": .array([
                                    .object([
                                        "id": .string("t_new"),
                                        "type": .int(2),
                                        "params": .object([
                                            "title": .string("Target message"),
                                            "senderName": .string("Pin Mirror User"),
                                            "global_msg_id": .string("9100002"),
                                            "client_msg_id": .string("c9100002"),
                                        ]),
                                    ]),
                                    .object([
                                        "id": .string("t_old"),
                                        "type": .int(2),
                                        "params": .object([
                                            "title": .string("Old pinned"),
                                            "senderName": .string("Pin Mirror User"),
                                            "global_msg_id": .string("9100001"),
                                            "client_msg_id": .string("c9100001"),
                                        ]),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
                .object([
                    "kind": .string("http"),
                    "path": .string("/api/board/unpinv2"),
                    "method": .string("GET"),
                    "delay_ms": .int(100),
                    "response": .object([
                        "status": .int(200),
                        "json": .object(["error_code": .int(0), "data": .object([:])]),
                    ]),
                ]),
                .object([
                    "kind": .string("http"),
                    "path": .string("/api/board/pin/list"),
                    "method": .string("GET"),
                    "response": .object([
                        "status": .int(200),
                        "json": .object([
                            "error_code": .int(0),
                            "data": .object([
                                "boardVersion": .int(3),
                                "pinLimit": .int(3),
                                "items": .array([
                                    .object([
                                        "id": .string("t_old"),
                                        "type": .int(2),
                                        "params": .object([
                                            "title": .string("Old pinned"),
                                            "senderName": .string("Pin Mirror User"),
                                            "global_msg_id": .string("9100001"),
                                            "client_msg_id": .string("c9100001"),
                                        ]),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ]
        )
        defer { cleanup() }
        defer { engine.cancelTasksForRecording() }

        #expect(engine.pins[convId]?.items.map(\.ref) == ["t_new", "t_old"])
        let itemToUnpin = try #require(engine.pins[convId]?.items.first)
        let olderVersion = engine.appliedMirrorVersion

        engine.requestUnpin(itemToUnpin, in: convId)
        let confirm = try #require(engine.messageConfirm)
        engine.answerMessageConfirm(confirm, ok: true)

        // Optimistically removed immediately on MainActor.
        #expect(engine.pins[convId]?.items.map(\.ref) == ["t_old"])

        // Stale board refresh still containing t_new must NOT resurrect it.
        let stalePins = PinsSnapshotRecord(
            lists: [
                PinnedListEntryRecord(
                    convId: convId,
                    ready: true,
                    canPin: true,
                    limit: 3,
                    items: [
                        PinnedItemRecord(
                            refId: "t_new",
                            kind: "message",
                            title: "Target message",
                            sender: "Pin Mirror User",
                            thumbnail: nil,
                            msgId: "9100002",
                            cliMsgId: "c9100002"
                        ),
                        PinnedItemRecord(
                            refId: "t_old",
                            kind: "message",
                            title: "Old pinned",
                            sender: "Pin Mirror User",
                            thumbnail: nil,
                            msgId: "9100001",
                            cliMsgId: "c9100001"
                        ),
                    ]
                ),
            ],
            rawTopics: []
        )
        engine.applyCoreChanges(Self.pinsChanges(version: olderVersion, pins: stalePins))
        #expect(engine.pins[convId]?.items.map(\.ref) == ["t_old"])

        await engine.awaitMessageActionTasksForRecording()
        await engine.settleForRecording()
        #expect(engine.pins[convId]?.items.map(\.ref) == ["t_old"])
        #expect(engine.optimisticMessageOverlays.isEmpty)

        await engine.finishTearDownForRecording()
    }
}
