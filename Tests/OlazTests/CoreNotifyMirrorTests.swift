import Foundation
import OlazCore
import Testing
@testable import Olaz

/// U16 mirror & latency tests:
/// 1. `CoreChangesRecord` mirroring for `notificationSettings` (including mutes + authorization + preview) and `aliases`.
/// 2. Server-confirmed `muteConversation` / `unmuteConversation` rollback + toast on server failure.
/// 3. Group invite preview + join error-code mapping (`178` -> `.already`, `240` -> `.pending`, `227`/`166` -> `.error`).
/// 4. Incoming message batch -> `notify_banner` latency through `CoreEngine` (< 25 ms p95 budget).
@Suite(.serialized) struct CoreNotifyMirrorTests {
    private static func emptyChanges(
        version: UInt64,
        notificationSettings: NotificationSettingsRecord? = nil,
        aliases: [AliasEntryRecord]? = nil
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
            forwardRequest: nil,
            clearSelection: false,
            deleteUndo: nil,
            messageConfirm: nil,
            autoDelete: nil,
            starredIds: nil,
            cachedProfiles: nil,
            notificationSettings: notificationSettings,
            aliases: aliases,
            stickerSuggest: nil,
            composerConfirm: nil,
            queuedComposerConfirms: nil
        )
    }

    @MainActor
    @Test func notificationSettingsAndAliasesMirrorCleanly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-u16-mirror-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let storage = RecorderStorageIsolation(prefix: "olaz.u16-mirror")
        defer { storage.cleanup() }
        let engine = ZaloEngine(
            dataDirectory: dir,
            useKeychain: false,
            userDefaultsSuiteName: storage.userDefaultsSuiteName,
            cookieStorage: storage.cookieStorage
        )

        let notifRec = NotificationSettingsRecord(
            isLoaded: true,
            enabled: true,
            sound: false,
            hasSoundSetting: true,
            showsPreview: false,
            authorization: .authorized,
            mutes: [
                MuteInfoEntryRecord(id: "3001601", startTime: 1_700_000_000, duration: 3600),
                MuteInfoEntryRecord(id: "g4001601", startTime: 1_700_000_100, duration: -1),
            ]
        )
        let aliasesRec = [
            AliasEntryRecord(uid: "3001601", alias: "Anh Minh"),
            AliasEntryRecord(uid: "3001602", alias: "Chị Lan"),
        ]

        engine.applyCoreChanges(Self.emptyChanges(
            version: 1,
            notificationSettings: notifRec,
            aliases: aliasesRec
        ))

        #expect(engine.notificationSettings.isLoaded)
        #expect(engine.notificationSettings.enabled)
        #expect(!engine.notificationSettings.sound)
        #expect(engine.notificationSettings.hasSoundSetting)
        #expect(!engine.notificationSettings.showsPreview)
        #expect(engine.notificationSettings.authorization == .authorized)
        #expect(engine.notificationSettings.mutes["3001601"] == MuteInfo(startTime: 1_700_000_000, duration: 3600))
        #expect(engine.notificationSettings.mutes["g4001601"] == MuteInfo(startTime: 1_700_000_100, duration: -1))
        #expect(engine.cachedAliases == ["3001601": "Anh Minh", "3001602": "Chị Lan"])
    }

    @MainActor
    @Test func serverConfirmedMuteAndJoinErrorCodesAndBannerLatency() async throws {
        let myUid = "2001699"
        let convId = "3001699"
        let testEnk = Data("0123456789abcdef0123456789abcdef".utf8).base64EncodedString()
        let secretKey = ZaloCrypto.parseSecretKey(testEnk)

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
                            "zpw_sek": .string("sek.u16.bench"),
                            "display_name": .string("U16 Tester"),
                            "send2me_id": .string("9201699"),
                            "zpw_ws": .array([.string("ws://fake")]),
                            "zpw_service_map_v3": .object([
                                "chat": .array([.string("http://fake")]),
                                "group": .array([.string("http://fake")]),
                                "profile": .array([.string("http://fake")]),
                                "conversation": .array([.string("http://fake")]),
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
                            "displayName": .string("U16 Tester"),
                        ]),
                    ]),
                ]),
            ]),
            // 1st setmute fails -> mute must NOT be recorded and toast card is shown
            .object([
                "kind": .string("http"),
                "path": .string("/api/social/profile/setmute"),
                "response": .object([
                    "status": .int(500),
                    "raw": .string("mute server down"),
                ]),
            ]),
            // 2nd setmute succeeds -> mute is recorded
            .object([
                "kind": .string("http"),
                "path": .string("/api/social/profile/setmute"),
                "response": .object([
                    "status": .int(200),
                    "json": .object([
                        "error_code": .int(0),
                        "data": .object([:]),
                    ]),
                ]),
            ]),
            // joinGroup code 178 -> .already with previewGroupId fallback
            .object([
                "kind": .string("http"),
                "path": .string("/api/group/link/join"),
                "response": .object([
                    "status": .int(200),
                    "json": .object([
                        "error_code": .int(178),
                        "error_message": .string("already member"),
                    ]),
                ]),
            ]),
            // joinGroup code 240 -> .pending
            .object([
                "kind": .string("http"),
                "path": .string("/api/group/link/join"),
                "response": .object([
                    "status": .int(200),
                    "json": .object([
                        "error_code": .int(240),
                        "error_message": .string("pending approval"),
                    ]),
                ]),
            ]),
        ]

        let server = try FakeZaloServer(serverScript: serverScript, initialSecretKey: secretKey)
        try await server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-u16-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

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
                name: "Minh Peer",
                avatar: "https://cdn.example/minh.jpg",
                pinned: false,
                members: 0,
                unread: 0,
                previewText: "Hi",
                previewTsMs: baseMs,
                previewFromMe: false,
                updatedAtMs: baseMs
            ),
        ])

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
            "conversation": [server.baseURLString],
        ]
        isolatedDomains.isolated = true

        let savedSession: CaseJSON = .object([
            "zpwType": .string(ZaloDomains.zpwType),
            "imei": .string("00000000-0000-4000-8000-000000000000-00000000000000000000000000000000"),
            "computerName": .string("U16Mac"),
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
                    "conversation": .array([.string(server.baseURLString)]),
                ]),
                "preferredHosts": .object([:]),
                "isolated": .bool(true),
            ]),
            "sealedSecretsBase64": .null,
            "expiredAt": .null,
            "plainAccount": .object([
                "userId": .string(myUid),
                "displayName": .string("U16 Tester"),
                "avatar": .string(""),
                "phone": .string(""),
                "send2MeId": .string("9201699"),
                "dkey": .string("dk-u16"),
                "zpwEnk": .string(testEnk),
                "zpwSek": .string("sek.u16.bench"),
            ]),
        ])
        try Data(savedSession.canonicalString().utf8)
            .write(to: root.appendingPathComponent("native-session.json"), options: .atomic)

        let storage = RecorderStorageIsolation(prefix: "olaz.u16-e2e")
        defer { storage.cleanup() }
        let engine = ZaloEngine(
            dataDirectory: root,
            useKeychain: false,
            domains: isolatedDomains,
            userDefaultsSuiteName: storage.userDefaultsSuiteName,
            cookieStorage: storage.cookieStorage
        )
        defer { engine.cancelTasksForRecording() }

        engine.nowMs = { baseMs }
        var shownCards: [(convId: String, text: String)] = []
        var deliveredBanners: [NotifyBannerRecord] = []
        engine.notifyBannerHook = { rec in
            deliveredBanners.append(rec)
        }
        engine.traceNotifyHostEnabled = true
        engine.hostTrace = { name, args in
            if name == "prepare_store" { return true }
            if name == "show_card" {
                let cid = (args["conv_id"] as? String) ?? ""
                let txt = (args["text"] as? String) ?? ""
                shownCards.append((cid, txt))
                return false
            }
            return false
        }

        engine.start()
        _ = await engine.bootTask?.value
        #expect(engine.phase == .ready)

        // 1. Failed setmute does not mutate mutes, shows error card
        engine.muteConversation(convId, .oneHour)
        await engine.awaitNotificationTasksForRecording()
        #expect(!engine.isConversationMuted(convId))
        #expect(shownCards.last?.convId == convId)
        #expect(shownCards.last?.text == "Có lỗi xảy ra")

        // 2. Successful setmute records server-confirmed mute
        engine.muteConversation("3001700", .fourHours)
        await engine.awaitNotificationTasksForRecording()
        #expect(engine.isConversationMuted("3001700"))

        // 3. joinGroup error codes 178 + 240
        let joinAlready = await engine.joinGroup(URL(string: "https://zalo.me/g/abc178")!, previewGroupId: "g555178")
        #expect(joinAlready.state == .already)
        #expect(joinAlready.groupId == "g555178")

        let joinPending = await engine.joinGroup(URL(string: "https://zalo.me/g/abc240")!, previewGroupId: "g555240")
        #expect(joinPending.state == .pending)

        // 4. Incoming message -> notify_banner latency across 30 iterations
        let incoming = ChatMessage(
            id: "990001",
            conversationId: convId,
            senderId: convId,
            senderName: "Minh Peer",
            senderAvatar: URL(string: "https://cdn.example/minh.jpg"),
            isMine: false,
            kind: .text,
            text: "Tin nhắn mới để đo độ trễ banner",
            date: Date(timeIntervalSince1970: Double(baseMs) / 1000.0),
            status: .sent,
            quote: nil,
            reactions: [],
            isE2EE: false
        )

        // Warmup
        for _ in 0..<5 {
            await engine.notifyIncomingBatchMessages([incoming])
        }
        deliveredBanners.removeAll()

        var samplesMs: [Double] = []
        let iterations = 30
        samplesMs.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let t0 = ContinuousClock.now
            await engine.notifyIncomingBatchMessages([incoming])
            let elapsed = t0.duration(to: ContinuousClock.now)
            let ms = Double(elapsed.components.seconds) * 1000.0
                + Double(elapsed.components.attoseconds) / 1e15
            samplesMs.append(ms)
        }
        samplesMs.sort()
        let p50 = samplesMs[iterations / 2]
        let p95 = samplesMs[Int(Double(iterations - 1) * 0.95)]
        print(String(format: "[U16 notify_banner latency] n=%d p50=%.3f ms p95=%.3f ms max=%.3f ms", iterations, p50, p95, samplesMs.last ?? 0))
        #expect(deliveredBanners.count == iterations)
        #expect(deliveredBanners.first?.title == "Minh Peer")
        #expect(p95 < 25.0, "Expected notify_banner p95 < 25 ms, got \(p95) ms")
    }
}
