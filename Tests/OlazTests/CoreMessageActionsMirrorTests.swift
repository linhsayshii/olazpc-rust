import Foundation
import OlazCore
import Testing
@testable import Olaz

/// Proves that U6 optimistic MainActor updates (react, delete-for-me, undo-delete) are version-fenced
/// against older core `CoreChangesRecord` deltas and never end on (or momentarily revert to) an
/// earlier state, while core error rollbacks at `>= targetVersion` still reconcile cleanly.
@Suite(.serialized) struct CoreMessageActionsMirrorTests {
    private static func emptyChanges(
        version: UInt64,
        windowDeltas: [WindowDeltaRecord] = [],
        deleteUndo: DeleteUndoUpdateRecord? = nil
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
            messagesResetAll: false,
            messageMeta: nil,
            contacts: nil,
            typing: nil,
            forwardRequest: nil,
            clearSelection: false,
            deleteUndo: deleteUndo,
            messageConfirm: nil,
            autoDelete: nil,
            starredIds: nil,
            cachedProfiles: nil,
            notificationSettings: nil,
            aliases: nil,
            pins: nil,
            cachedGroups: nil,
            polls: nil,
            cloud: nil,
            stickerSuggest: nil,
            composerConfirm: nil,
            queuedComposerConfirms: nil
        )
    }

    @MainActor
    private static func makeBootedEngine(
        convId: String = "3000777",
        myUid: String = "2000777",
        reactErrorCode: Int = 0,
        reactDelayMs: Int = 0
    ) async throws -> (engine: ZaloEngine, server: FakeZaloServer, cleanup: () -> Void) {
        let testEnk = Data("0123456789abcdef0123456789abcdef".utf8).base64EncodedString()
        let secretKey = ZaloCrypto.parseSecretKey(testEnk)

        var reactEntry: [String: CaseJSON] = [
            "kind": .string("http"),
            "path": .string("/api/message/reaction"),
            "method": .string("POST"),
            "repeat": .bool(true),
            "response": .object([
                "status": .int(200),
                "json": .object([
                    "error_code": .int(Int64(reactErrorCode)),
                    "data": .object([:]),
                ]),
            ]),
        ]
        if reactDelayMs > 0 {
            reactEntry["delay_ms"] = .int(Int64(reactDelayMs))
        }

        let serverScript: [CaseJSON] = [
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
                            "zpw_sek": .string("sek.mirror.u6"),
                            "display_name": .string("Mirror User"),
                            "send2me_id": .string("9200777"),
                            "zpw_ws": .array([.string("ws://fake")]),
                            "zpw_service_map_v3": .object([
                                "chat": .array([.string("http://fake")]),
                                "group": .array([.string("http://fake")]),
                                "profile": .array([.string("http://fake")]),
                                "reaction": .array([.string("http://fake")]),
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
                            "displayName": .string("Mirror User"),
                        ]),
                    ]),
                ]),
            ]),
            .object(reactEntry),
        ]

        let server = try FakeZaloServer(serverScript: serverScript, initialSecretKey: secretKey)
        try await server.start()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-u6-mirror-\(UUID().uuidString)", isDirectory: true)
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
                isGroup: false,
                name: "Peer",
                avatar: "",
                pinned: false,
                members: 0,
                unread: 0,
                previewText: "Second",
                previewTsMs: baseMs + 2_000,
                previewFromMe: false,
                updatedAtMs: baseMs + 2_000
            ),
        ])
        let m1 = ChatMessage(
            id: "8200001",
            conversationId: convId,
            senderId: convId,
            senderName: "Peer",
            senderAvatar: nil,
            isMine: false,
            kind: .text,
            text: "First",
            date: Date(timeIntervalSince1970: Double(baseMs + 1_000) / 1000.0),
            status: .sent,
            quote: nil,
            reactions: [],
            isE2EE: false,
            clientId: "c1"
        )
        let m2 = ChatMessage(
            id: "8200002",
            conversationId: convId,
            senderId: convId,
            senderName: "Peer",
            senderAvatar: nil,
            isMine: false,
            kind: .text,
            text: "Second",
            date: Date(timeIntervalSince1970: Double(baseMs + 2_000) / 1000.0),
            status: .sent,
            quote: nil,
            reactions: [],
            isE2EE: false,
            clientId: "c2"
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
            "profile": [server.baseURLString],
            "reaction": [server.baseURLString],
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
                    "profile": .array([.string(server.baseURLString)]),
                    "reaction": .array([.string(server.baseURLString)]),
                ]),
                "preferredHosts": .object([:]),
                "isolated": .bool(true),
            ]),
            "sealedSecretsBase64": .null,
            "expiredAt": .null,
            "plainAccount": .object([
                "userId": .string(myUid),
                "displayName": .string("Mirror User"),
                "avatar": .string(""),
                "phone": .string(""),
                "send2MeId": .string("9200777"),
                "dkey": .string("dk-mirror"),
                "zpwEnk": .string(testEnk),
                "zpwSek": .string("sek.mirror.u6"),
            ]),
        ])
        try Data(savedSession.canonicalString().utf8)
            .write(to: root.appendingPathComponent("native-session.json"), options: .atomic)

        let storage = RecorderStorageIsolation(prefix: "olaz.u6-mirror")
        let engine = ZaloEngine(
            dataDirectory: root,
            useKeychain: false,
            domains: isolatedDomains,
            userDefaultsSuiteName: storage.userDefaultsSuiteName,
            cookieStorage: storage.cookieStorage
        )
        engine.historyFreshness[convId] = .upToDate
        engine.hostTrace = { name, _ in
            name == "prepare_store"
        }

        engine.start()
        _ = await engine.bootTask?.value
        #expect(engine.phase == .ready)
        engine.openConversation(convId)
        await engine.settleForRecording()
        #expect((engine.messages[convId]?.count ?? 0) == 2)

        return (engine, server, {
            server.stop()
            storage.cleanup()
            try? FileManager.default.removeItem(at: root)
        })
    }

    @MainActor
    @Test func olderCorePatchCannotRevertOptimisticReaction() async throws {
        let convId = "3000777"
        let (engine, _, cleanup) = try await Self.makeBootedEngine(convId: convId, reactDelayMs: 80)
        defer { cleanup() }
        defer {
            engine.cancelTasksForRecording()
        }

        let originalMsg = try #require(engine.messages[convId]?.last)
        #expect(originalMsg.reactions.isEmpty)
        let olderVersion = engine.appliedMirrorVersion

        // Start react; optimistic MainActor write runs synchronously before the first suspension point.
        let reactTask = Task { @MainActor in
            await engine.performReact("❤️", to: originalMsg.id, in: convId)
        }
        await Task.yield()

        // Optimistic ❤️ must already be visible while the HTTP request is still in-flight.
        let afterOptimistic = try #require(engine.messages[convId]?.first(where: { $0.id == originalMsg.id }))
        #expect(afterOptimistic.reactions.contains(where: { $0.includesMe && $0.icon.type == "5" }))

        // Deliver a stale CoreChangesRecord carrying the pre-react message (empty reactions).
        let staleBatch = Self.emptyChanges(
            version: olderVersion,
            windowDeltas: [
                .patch(convId: convId, upserts: [ChatMessageRecord(message: originalMsg)], removedIds: []),
            ]
        )
        engine.applyCoreChanges(staleBatch)

        // The stale patch must NOT revert the optimistic ❤️ even momentarily.
        let afterStale = try #require(engine.messages[convId]?.first(where: { $0.id == originalMsg.id }))
        #expect(afterStale.reactions.contains(where: { $0.includesMe && $0.icon.type == "5" }))

        // Let core finish and settle; the mirror must end with ❤️ and zero leaked overlays.
        await reactTask.value
        await engine.settleForRecording()
        let finalMsg = try #require(engine.messages[convId]?.first(where: { $0.id == originalMsg.id }))
        #expect(finalMsg.reactions.contains(where: { $0.includesMe && $0.icon.type == "5" }))
        #expect(engine.optimisticMessageOverlays.isEmpty)

        await engine.finishTearDownForRecording()
    }

    @MainActor
    @Test func failedReactRollsBackAuthoritativelyOnError() async throws {
        let convId = "3000777"
        let (engine, _, cleanup) = try await Self.makeBootedEngine(convId: convId, reactErrorCode: -1)
        defer { cleanup() }
        defer {
            engine.cancelTasksForRecording()
        }

        let originalMsg = try #require(engine.messages[convId]?.last)
        await engine.performReact("❤️", to: originalMsg.id, in: convId)
        await engine.settleForRecording()

        let finalMsg = try #require(engine.messages[convId]?.first(where: { $0.id == originalMsg.id }))
        #expect(finalMsg.reactions.isEmpty)
        #expect(engine.optimisticMessageOverlays.isEmpty)

        await engine.finishTearDownForRecording()
    }

    @MainActor
    @Test func olderCorePatchCannotRevertOptimisticDeleteForMe() async throws {
        let convId = "3000777"
        let (engine, _, cleanup) = try await Self.makeBootedEngine(convId: convId)
        defer { cleanup() }
        defer {
            engine.cancelTasksForRecording()
        }

        let targetMsg = try #require(engine.messages[convId]?.last)
        let olderVersion = engine.appliedMirrorVersion

        // Optimistically delete targetMsg (confirmed).
        engine.deleteForMe(targetMsg, confirmed: true)
        #expect(engine.messages[convId]?.contains(where: { $0.id == targetMsg.id }) == false)
        #expect(engine.deleteUndo?.conversationId == convId)

        // Immediately inject an older CoreChangesRecord that still contains targetMsg and deleteUndo=nil.
        let staleBatch = Self.emptyChanges(
            version: olderVersion,
            windowDeltas: [
                .patch(convId: convId, upserts: [ChatMessageRecord(message: targetMsg)], removedIds: []),
            ],
            deleteUndo: DeleteUndoUpdateRecord(undo: nil)
        )
        engine.applyCoreChanges(staleBatch)

        // Must stay hidden and undo banner must stay visible even immediately after the stale patch.
        #expect(engine.messages[convId]?.contains(where: { $0.id == targetMsg.id }) == false)
        #expect(engine.deleteUndo?.conversationId == convId)

        // After core settles, targetMsg remains deleted and overlays are drained.
        await engine.settleForRecording()
        #expect(engine.messages[convId]?.contains(where: { $0.id == targetMsg.id }) == false)
        #expect(engine.deleteUndo?.conversationId == convId)
        #expect(engine.optimisticMessageOverlays.isEmpty)

        await engine.finishTearDownForRecording()
    }

    @MainActor
    @Test func olderCorePatchCannotRevertOptimisticUndoDelete() async throws {
        let convId = "3000777"
        let (engine, _, cleanup) = try await Self.makeBootedEngine(convId: convId)
        defer { cleanup() }
        defer {
            engine.cancelTasksForRecording()
        }

        let targetMsg = try #require(engine.messages[convId]?.last)
        engine.deleteForMe(targetMsg, confirmed: true)
        await engine.settleForRecording()
        #expect(engine.messages[convId]?.contains(where: { $0.id == targetMsg.id }) == false)
        let preUndoVersion = engine.appliedMirrorVersion
        let staleUndoRec = DeleteUndoSnapshotRecord(
            convId: convId,
            count: 1,
            deadlineMs: engine.nowMs() + 5_000
        )

        // Optimistically undo delete.
        engine.undoDelete()
        #expect(engine.messages[convId]?.contains(where: { $0.id == targetMsg.id }) == true)
        #expect(engine.deleteUndo == nil)

        // Immediately inject an older CoreChangesRecord where targetMsg is still removed and undo is still set.
        let staleBatch = Self.emptyChanges(
            version: preUndoVersion,
            windowDeltas: [
                .patch(convId: convId, upserts: [], removedIds: [targetMsg.id]),
            ],
            deleteUndo: DeleteUndoUpdateRecord(undo: staleUndoRec)
        )
        engine.applyCoreChanges(staleBatch)

        // Must remain restored and deleteUndo must stay nil immediately after the stale patch.
        #expect(engine.messages[convId]?.contains(where: { $0.id == targetMsg.id }) == true)
        #expect(engine.deleteUndo == nil)

        // After core settles, targetMsg remains present, deleteUndo stays nil, and overlays are drained.
        await engine.settleForRecording()
        #expect(engine.messages[convId]?.contains(where: { $0.id == targetMsg.id }) == true)
        #expect(engine.deleteUndo == nil)
        #expect(engine.optimisticMessageOverlays.isEmpty)

        await engine.finishTearDownForRecording()
    }

    @MainActor
    @Test func staleBatchAfterV1DoesNotPoisonSuppressedReaction() async throws {
        let convId = "3000777"
        let (engine, _, cleanup) = try await Self.makeBootedEngine(convId: convId)
        defer { cleanup() }
        defer { engine.cancelTasksForRecording() }

        let originalMsg = try #require(engine.messages[convId]?.last)
        #expect(originalMsg.reactions.isEmpty)
        let v0 = engine.appliedMirrorVersion
        let v1 = v0 + 1

        var heartMsg = originalMsg
        ZaloEngine.mutateReactions(
            &heartMsg.reactions,
            actorUid: "2000777",
            myUid: "2000777",
            isMe: true,
            rType: "5",
            rIcon: "/-heart",
            allowDuplicateSameUser: true,
            nameLookup: { _ in "Bạn" }
        )
        #expect(heartMsg.reactions.contains(where: { $0.includesMe && $0.icon.type == "5" }))

        // Apply optimistic ❤️ on MainActor and open an unresolved overlay (resolvedVersion == .max).
        let token = engine.beginOptimisticReactionOverlay(
            convId: convId,
            msgId: heartMsg.id,
            clientId: heartMsg.clientId,
            reactions: heartMsg.reactions
        )
        if var list = engine.messages[convId], let idx = list.firstIndex(where: { $0.id == heartMsg.id }) {
            list[idx] = heartMsg
            engine.messages[convId] = list
        }

        // Authoritative V1 carrying ❤️ arrives while the overlay is still unresolved.
        engine.applyCoreChanges(Self.emptyChanges(
            version: v1,
            windowDeltas: [
                .patch(convId: convId, upserts: [ChatMessageRecord(message: heartMsg)], removedIds: []),
            ]
        ))
        #expect(engine.appliedMirrorVersion == v1)

        // A stale non-zero batch (v0 < v1) and a version-0 stale batch both arrive AFTER V1
        // carrying the pre-react empty reactions. Neither may poison the V1 suppressed value.
        engine.applyCoreChanges(Self.emptyChanges(
            version: v0,
            windowDeltas: [
                .patch(convId: convId, upserts: [ChatMessageRecord(message: originalMsg)], removedIds: []),
            ]
        ))
        engine.applyCoreChanges(Self.emptyChanges(
            version: 0,
            windowDeltas: [
                .patch(convId: convId, upserts: [ChatMessageRecord(message: originalMsg)], removedIds: []),
            ]
        ))

        let midMsg = try #require(engine.messages[convId]?.first(where: { $0.id == originalMsg.id }))
        #expect(midMsg.reactions.contains(where: { $0.includesMe && $0.icon.type == "5" }))

        // Resolving the overlay at V1 must keep ❤️ (not overwrite with stale []) and drain overlays.
        engine.resolveOptimisticOverlay(token: token, targetVersion: v1)
        let finalMsg = try #require(engine.messages[convId]?.first(where: { $0.id == originalMsg.id }))
        #expect(finalMsg.reactions.contains(where: { $0.includesMe && $0.icon.type == "5" }))
        #expect(engine.optimisticMessageOverlays.isEmpty)

        await engine.finishTearDownForRecording()
    }

    @MainActor
    @Test func outOfOrderNonZeroBatchIsIgnored() async throws {
        let convId = "3000777"
        let (engine, _, cleanup) = try await Self.makeBootedEngine(convId: convId)
        defer { cleanup() }
        defer { engine.cancelTasksForRecording() }

        let originalMsg = try #require(engine.messages[convId]?.last)
        let v0 = max(UInt64(1), engine.appliedMirrorVersion)
        let v1 = v0 + 1
        let v2 = v0 + 2

        var v1Msg = originalMsg
        v1Msg.text = "Authoritative V1"
        ZaloEngine.mutateReactions(
            &v1Msg.reactions,
            actorUid: "2000777",
            myUid: "2000777",
            isMe: true,
            rType: "5",
            rIcon: "/-heart",
            allowDuplicateSameUser: true,
            nameLookup: { _ in "Bạn" }
        )

        // Advance mirror to V1.
        engine.applyCoreChanges(Self.emptyChanges(
            version: v1,
            windowDeltas: [
                .patch(convId: convId, upserts: [ChatMessageRecord(message: v1Msg)], removedIds: []),
            ]
        ))
        #expect(engine.appliedMirrorVersion == v1)

        // Deliver a strictly older non-zero batch (v0 < v1) with stale text, empty reactions, and undo.
        var staleMsg = originalMsg
        staleMsg.text = "Stale V0"
        staleMsg.reactions = []
        let staleUndo = DeleteUndoSnapshotRecord(convId: convId, count: 1, deadlineMs: engine.nowMs() + 5_000)
        engine.applyCoreChanges(Self.emptyChanges(
            version: v0,
            windowDeltas: [
                .patch(convId: convId, upserts: [ChatMessageRecord(message: staleMsg)], removedIds: []),
            ],
            deleteUndo: DeleteUndoUpdateRecord(undo: staleUndo)
        ))

        let afterStale = try #require(engine.messages[convId]?.first(where: { $0.id == originalMsg.id }))
        #expect(engine.appliedMirrorVersion == v1)
        #expect(afterStale.text == "Authoritative V1")
        #expect(afterStale.reactions.contains(where: { $0.includesMe && $0.icon.type == "5" }))
        #expect(engine.deleteUndo == nil)

        // A strictly newer batch (v2 > v1) still applies normally.
        var v2Msg = v1Msg
        v2Msg.text = "Authoritative V2"
        engine.applyCoreChanges(Self.emptyChanges(
            version: v2,
            windowDeltas: [
                .patch(convId: convId, upserts: [ChatMessageRecord(message: v2Msg)], removedIds: []),
            ]
        ))
        let afterV2 = try #require(engine.messages[convId]?.first(where: { $0.id == originalMsg.id }))
        #expect(engine.appliedMirrorVersion == v2)
        #expect(afterV2.text == "Authoritative V2")

        await engine.finishTearDownForRecording()
    }

    @MainActor
    @Test func unrelatedDeltaInSameConversationDoesNotOverwriteSuppressedRollback() async throws {
        let convId = "3000777"
        let (engine, _, cleanup) = try await Self.makeBootedEngine(convId: convId)
        defer { cleanup() }
        defer { engine.cancelTasksForRecording() }

        let firstMsg = try #require(engine.messages[convId]?.first)
        let targetMsg = try #require(engine.messages[convId]?.last)
        #expect(firstMsg.id != targetMsg.id)
        let v0 = engine.appliedMirrorVersion

        // Part A: Failed reaction rollback followed by unrelated append + patch in the same conversation.
        var heartMsg = targetMsg
        ZaloEngine.mutateReactions(
            &heartMsg.reactions,
            actorUid: "2000777",
            myUid: "2000777",
            isMe: true,
            rType: "5",
            rIcon: "/-heart",
            allowDuplicateSameUser: true,
            nameLookup: { _ in "Bạn" }
        )
        let reactToken = engine.beginOptimisticReactionOverlay(
            convId: convId,
            msgId: heartMsg.id,
            clientId: heartMsg.clientId,
            reactions: heartMsg.reactions
        )
        if var list = engine.messages[convId], let idx = list.firstIndex(where: { $0.id == heartMsg.id }) {
            list[idx] = heartMsg
            engine.messages[convId] = list
        }

        // Core rollback arrives at V1 (empty reactions) while overlay is still unresolved.
        let v1 = v0 + 1
        engine.applyCoreChanges(Self.emptyChanges(
            version: v1,
            windowDeltas: [
                .patch(convId: convId, upserts: [ChatMessageRecord(message: targetMsg)], removedIds: []),
            ]
        ))
        // Optimistic ❤️ stays visible until resolved.
        let beforeUnrelated = try #require(engine.messages[convId]?.first(where: { $0.id == targetMsg.id }))
        #expect(beforeUnrelated.reactions.contains(where: { $0.includesMe && $0.icon.type == "5" }))

        // Unrelated delta at V2 in the SAME conversation: edits firstMsg and appends m3, never touching targetMsg.
        var editedFirst = firstMsg
        editedFirst.text = "First (edited)"
        let m3 = ChatMessage(
            id: "8200003",
            conversationId: convId,
            senderId: convId,
            senderName: "Peer",
            senderAvatar: nil,
            isMine: false,
            kind: .text,
            text: "Third",
            date: targetMsg.date.addingTimeInterval(1),
            status: .sent,
            quote: nil,
            reactions: [],
            isE2EE: false,
            clientId: "c3"
        )
        let v2 = v0 + 2
        engine.applyCoreChanges(Self.emptyChanges(
            version: v2,
            windowDeltas: [
                .patch(convId: convId, upserts: [ChatMessageRecord(message: editedFirst)], removedIds: []),
                .append(convId: convId, messages: [ChatMessageRecord(message: m3)]),
            ]
        ))

        // Resolving the reaction overlay at V1 must still roll back to [] (not be overwritten by V2).
        engine.resolveOptimisticOverlay(token: reactToken, targetVersion: v1)
        let rolledBack = try #require(engine.messages[convId]?.first(where: { $0.id == targetMsg.id }))
        #expect(rolledBack.reactions.isEmpty)
        #expect(engine.messages[convId]?.first(where: { $0.id == firstMsg.id })?.text == "First (edited)")
        #expect(engine.messages[convId]?.contains(where: { $0.id == "8200003" }) == true)
        #expect(engine.optimisticMessageOverlays.isEmpty)

        // Part B: Failed delete rollback followed by unrelated append in the same conversation.
        let fakeUndo = DeleteUndo(
            id: UUID().uuidString,
            conversationId: convId,
            count: 1,
            deadline: Date().addingTimeInterval(6)
        )
        let deleteToken = engine.beginOptimisticDeleteOverlay(
            convId: convId,
            messages: [targetMsg],
            undo: fakeUndo
        )
        engine.messages[convId]?.removeAll { $0.id == targetMsg.id }
        engine.deleteUndo = fakeUndo

        // Authoritative V3 restores targetMsg (rollback) and clears deleteUndo while overlay is unresolved.
        let v3 = v0 + 3
        engine.applyCoreChanges(Self.emptyChanges(
            version: v3,
            windowDeltas: [
                .patch(convId: convId, upserts: [ChatMessageRecord(message: targetMsg)], removedIds: []),
            ],
            deleteUndo: DeleteUndoUpdateRecord(undo: nil)
        ))
        #expect(engine.messages[convId]?.contains(where: { $0.id == targetMsg.id }) == false)

        // Unrelated V4 appends m4 in the same conversation without touching targetMsg.
        let m4 = ChatMessage(
            id: "8200004",
            conversationId: convId,
            senderId: convId,
            senderName: "Peer",
            senderAvatar: nil,
            isMine: false,
            kind: .text,
            text: "Fourth",
            date: m3.date.addingTimeInterval(1),
            status: .sent,
            quote: nil,
            reactions: [],
            isE2EE: false,
            clientId: "c4"
        )
        let v4 = v0 + 4
        engine.applyCoreChanges(Self.emptyChanges(
            version: v4,
            windowDeltas: [
                .append(convId: convId, messages: [ChatMessageRecord(message: m4)]),
            ]
        ))

        // Resolving the delete overlay at V3 must still restore targetMsg and clear deleteUndo.
        engine.resolveOptimisticOverlay(token: deleteToken, targetVersion: v3)
        #expect(engine.messages[convId]?.contains(where: { $0.id == targetMsg.id }) == true)
        #expect(engine.messages[convId]?.contains(where: { $0.id == "8200004" }) == true)
        #expect(engine.deleteUndo == nil)
        #expect(engine.optimisticMessageOverlays.isEmpty)

        await engine.finishTearDownForRecording()
    }
}
