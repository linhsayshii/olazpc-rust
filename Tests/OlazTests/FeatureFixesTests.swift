import Foundation
import os
import Testing
@testable import Olaz

@Suite struct IncomingCallDisplayTests {
    @Test func extractIncomingCallMetadataPrioritizesUidNAndNestedGroupPayload() {
        let oneToOne = ZaloEngine.extractIncomingCallMetadata(
            act: "request",
            parsedData: [
                "uidN": "u987654321",
                "fromUid": "111222333",
                "callerName": "Minh Anh",
                "avatar": "https://cdn.example.test/avt.jpg"
            ]
        )
        #expect(!oneToOne.isGroup)
        #expect(oneToOne.callerCandidateIds.first == "987654321")
        #expect(oneToOne.callerCandidateIds.contains("111222333"))
        #expect(oneToOne.inlineCallerName == "Minh Anh")
        #expect(oneToOne.inlineAvatar == "https://cdn.example.test/avt.jpg")

        let groupMeta = ZaloEngine.extractIncomingCallMetadata(
            act: "group_request",
            parsedData: [
                "uidN": "g777888",
                "data": #"{"callerId":"u555666","groupName":"Gia Đình Nhỏ"}"#,
                "groupInfo": [
                    "grid": "777888",
                    "groupAvatar": "https://cdn.example.test/group.jpg"
                ]
            ]
        )
        #expect(groupMeta.isGroup)
        #expect(groupMeta.groupCandidateIds.contains("777888"))
        #expect(groupMeta.callerCandidateIds.contains("555666"))
        #expect(groupMeta.inlineGroupName == "Gia Đình Nhỏ")
        #expect(groupMeta.inlineGroupAvatar == "https://cdn.example.test/group.jpg")
    }

    @Test func parseNoisedCallIdsHandlesPositionalArraysAndDicts() {
        let arrayResp: [String: Any] = [
            "error_code": 0,
            "data": [
                "fids": [1001, "0", 1003],
                "gids": ["g2001", ""]
            ]
        ]
        let arrayParsed = ZaloSessionClient.parseNoisedCallIdsResponse(
            arrayResp,
            requestedFids: ["n1", "n2", "n3"],
            requestedGids: ["gn1", "gn2"]
        )
        #expect(arrayParsed.friends == ["n1": "1001", "n3": "1003"])
        #expect(arrayParsed.groups == ["gn1": "g2001"])

        let dictResp: [String: Any] = [
            "data": [
                "fids": ["noiseA": "8801", "noiseB": "0"],
                "gids": ["gnoiseA": "9901"]
            ]
        ]
        let dictParsed = ZaloSessionClient.parseNoisedCallIdsResponse(
            dictResp,
            requestedFids: ["noiseA", "noiseB"],
            requestedGids: ["gnoiseA"]
        )
        #expect(dictParsed.friends == ["noiseA": "8801"])
        #expect(dictParsed.groups == ["gnoiseA": "9901"])
    }

    @Test @MainActor func voipControlResolvesRealCallerAndGroupNamesInsteadOfPlaceholder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-call-fix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = ZaloEngine(dataDirectory: root, useKeychain: false)
        engine.call.helperInstalled = true
        engine.call.helperProblem = nil
        engine.call.busy = false
        engine.contacts.friends = [
            ContactsState.Friend(
                id: "200",
                name: "Minh Anh",
                zaloName: "Minh Anh",
                avatar: URL(string: "https://cdn.example.test/ma.jpg"),
                lastActive: nil,
                online: true,
                section: "M",
                sortKey: "minh anh"
            )
        ]
        engine.conversations = [
            ZaloEngine.ConversationSummary(
                id: "g777",
                isGroup: true,
                name: "Nhóm Thân Thiết",
                avatar: URL(string: "https://cdn.example.test/grp.jpg"),
                pinned: false,
                members: 4,
                unread: 0,
                preview: nil
            )
        ]

        // 1. 1-1 incoming call resolves real friend name, not "Một người bạn"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        await engine.handleVoipControlEvent(
            act: "request",
            rawDataValue: nil,
            parsedData: ["uidN": "u200", "ts": nowMs],
            launchHelperIfNeeded: false
        )
        #expect(engine.call.incoming?.name == "Minh Anh")
        #expect(engine.call.incoming?.group == false)
        #expect(engine.call.incoming?.avatar == URL(string: "https://cdn.example.test/ma.jpg"))

        // 2. Group incoming call shows group name + caller
        await engine.handleVoipControlEvent(
            act: "group_request",
            rawDataValue: nil,
            parsedData: ["groupId": "777", "callerId": "200", "ts": nowMs],
            launchHelperIfNeeded: false
        )
        #expect(engine.call.incoming?.group == true)
        #expect(engine.call.incoming?.name == "Nhóm Thân Thiết")
        #expect(engine.call.incoming?.caller == "Minh Anh")

        // 3. Alias lookup prefers cachedAliases over profile displayName
        #expect(await engine.resolveCallAliasName(for: "200") == "Minh Anh")
        engine.cachedAliases["200"] = "Em Gái"
        #expect(await engine.resolveCallAliasName(for: "200") == "Em Gái")

        // Clean up incoming banner
        await engine.handleVoipControlEvent(act: "cancel", rawDataValue: nil, parsedData: [:], launchHelperIfNeeded: false)
        #expect(engine.call.incoming == nil)
    }
}

@Suite(.serialized) struct MessageRecallTests {
    @Test func chatMessagePreservesClientIdThroughJSONAndSQLiteRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-recall-sql-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try ZaloSQLiteStore(path: root.appendingPathComponent("history.sqlite3").path)
        let parsed = ChatMessage(
            json: [
                "id": "srv_9001",
                "clientId": "cli_1700001",
                "kind": ["type": "text"],
                "text": "Tin nhắn cần lưu cliId",
                "isMine": true
            ],
            fallbackConversation: "300"
        )
        let msg = try #require(parsed)
        #expect(msg.id == "srv_9001")
        #expect(msg.clientId == "cli_1700001")

        let stored = try #require(ZaloWireParser.encodeChatMessage(msg))
        #expect(stored.clientId == "cli_1700001")
        try await store.saveMessages([stored])

        let fetched = try #require(try await store.message(convId: "300", idOrClientId: "srv_9001"))
        let decoded = try #require(ZaloWireParser.decodeStoredMessage(fetched))
        #expect(decoded.id == "srv_9001")
        #expect(decoded.clientId == "cli_1700001")
    }

    @Test func myCloudWireMessageExcludesRecallMenu() throws {
        let evt = ZaloWireParser.parseWireMessage(
            [
                "msgId": "8001",
                "cliMsgId": "4001",
                "uidFrom": "100",
                "idTo": "999",
                "msgType": "webchat",
                "content": "Ghi chú cá nhân",
                "ts": 1_700_000_000_000
            ],
            myUid: "100",
            fallbackConvId: "999",
            isGroupHint: false,
            selfConvId: "999"
        )
        guard case .message(let parsedMsg, let stored) = evt else {
            Issue.record("Expected parsed message for My Cloud")
            return
        }
        #expect(parsedMsg.conversationId == "999")
        let decoded = try #require(ZaloWireParser.decodeStoredMessage(stored))
        #expect(decoded.menu.recall == false)
        #expect(decoded.menu.delete == .plain)
    }

    /// Phone-synced info notices (pin / unpin …): `webchat` + object content with `action: msginfo.actionlist` is a
    /// system line, not a text bubble (Rust `webchat_msginfo_actionlist_is_system`).
    @Test func webchatMsgInfoActionListIsSystem() {
        let evt = ZaloWireParser.parseWireMessage(
            [
                "msgId": "8522", "cliMsgId": "1795", "uidFrom": "0", "idTo": "peer", "msgType": "webchat", "ts": 1_795_463_690_898,
                "content": ["action": "msginfo.actionlist", "title": "Hoàng Việt Linh đã ghim tin nhắn a đi dạy về ah.",
                            "description": "", "href": "", "params": "{}", "thumb": "", "type": "", "childnumber": 0]
            ],
            myUid: "me"
        )
        guard case .message(let msg, _) = evt else { Issue.record("expected message"); return }
        #expect(msg.kind == .system)
        #expect(msg.text == "Hoàng Việt Linh đã ghim tin nhắn a đi dạy về ah.")
        // A plain webchat (string or object content) stays text.
        for content: Any in ["hi", ["title": "hi"]] {
            let plain = ZaloWireParser.parseWireMessage(
                ["msgId": "8523", "uidFrom": "peer", "idTo": "me", "msgType": "webchat", "ts": 1, "content": content], myUid: "me")
            guard case .message(let m, _) = plain else { Issue.record("expected message"); return }
            #expect(m.kind == .text)
        }
    }

    /// `group.poll` events: actor + verb of `content.action` + question (Rust `group_poll_event_info_line`).
    @Test func groupPollEventInfoLine() {
        func header(_ action: String, from: String) -> String {
            let evt = ZaloWireParser.parseWireMessage(
                [
                    "msgId": "9\(action)", "uidFrom": from, "idTo": "3993665107146848278", "msgType": "group.poll", "ts": 1,
                    "content": ["action": action, "title": "", "description": "",
                                "params": #"{"pollId":1192926841,"question":"Khỏe không","uid":"x","dName":"Việt Linh","pollVer":2}"#]
                ],
                myUid: "me", isGroupHint: true
            )
            guard case .message(let msg, _) = evt, case .poll(let info) = msg.kind else { return "" }
            return info.header
        }
        #expect(header("create", from: "peer") == "Việt Linh tạo cuộc bình chọn mới: Khỏe không")
        #expect(header("vote", from: "peer") == "Việt Linh tham gia cuộc bình chọn: Khỏe không")
        #expect(header("update", from: "peer") == "Việt Linh đổi lựa chọn trong cuộc bình chọn: Khỏe không")
        #expect(header("vote", from: "0") == "Bạn tham gia cuộc bình chọn: Khỏe không")
    }

    @Test @MainActor func recallEnforces24hGuardAndApplyRemoteRecallUpdatesBubbleSQLiteAndPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-recall-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            CardActionCenter.shared.reset()
            try? FileManager.default.removeItem(at: root)
        }

        let engine = ZaloEngine(dataDirectory: root, useKeychain: false)
        let store = try ZaloSQLiteStore(path: root.appendingPathComponent("history.sqlite3").path)
        engine.sqliteStore = store

        let oldMsg = ChatMessage(
            id: "srv_old",
            conversationId: "200",
            senderId: "100",
            senderName: "Bạn",
            senderAvatar: nil,
            isMine: true,
            kind: .text,
            text: "Quá 24h",
            date: Date(timeIntervalSinceNow: -90_000),
            status: .sent,
            quote: nil,
            reactions: [],
            isE2EE: false,
            clientId: "cli_old"
        )
        CardActionCenter.shared.reset()
        await engine.performRecall(oldMsg)
        #expect(CardActionCenter.shared.notice?.text == "Bạn chỉ có thể thu hồi tin nhắn đã gửi trong vòng 24 giờ.")

        let freshMsg = ChatMessage(
            id: "srv_fresh",
            conversationId: "200",
            senderId: "100",
            senderName: "Bạn",
            senderAvatar: nil,
            isMine: true,
            kind: .text,
            text: "Tin mới gửi",
            date: Date(),
            status: .sent,
            quote: ChatMessage.Quote(senderName: "An", text: "Trước đó"),
            reactions: [ChatMessage.Reaction(icon: ReactionIcon(type: "like", key: "like", emoji: "👍", image: ""), count: 1, includesMe: true)],
            isE2EE: false,
            cardButtons: [CardButton(ref: "b1", label: "Btn", enabled: true)],
            suggestsStickers: false,
            menu: MessageMenu(json: ["forward": "ok", "recall": true, "delete": "forMe", "pin": true, "star": "star", "starred": true]),
            clientId: "cli_fresh"
        )
        engine.messages["200"] = [freshMsg]
        engine.conversations = [
            ZaloEngine.ConversationSummary(
                id: "200",
                isGroup: false,
                name: "An",
                avatar: nil,
                pinned: false,
                members: 0,
                unread: 0,
                preview: .init(text: "Tin mới gửi", date: freshMsg.date, fromMe: true)
            )
        ]
        if let stored = ZaloWireParser.encodeChatMessage(freshMsg) {
            try await store.saveMessages([stored])
        }

        await engine.applyRemoteRecall(convId: "200", msgId: "", cliMsgId: "cli_fresh")
        let updated = try #require(engine.messages["200"]?.first)
        #expect(updated.kind == .recalled)
        #expect(updated.text.isEmpty)
        #expect(updated.reactions.isEmpty)
        #expect(updated.quote == nil)
        #expect(updated.cardButtons.isEmpty)
        #expect(updated.menu.recall == false)
        #expect(updated.menu.forward == .hidden)
        #expect(engine.conversations.first?.preview?.text == "Tin nhắn đã được thu hồi")

        let storedAfter = try #require(try await store.message(convId: "200", idOrClientId: "srv_fresh"))
        #expect(storedAfter.kindTag == "recalled")
    }

    @Test func extractE2EESendResponseReadsMinGlobalMsgIdAndTimestamp() {
        let direct = ZaloSessionClient.extractE2EESendResponse([
            "error_code": 0,
            "data": [
                "clientId": "1795343225629",
                "minGlobalMsgId": "8517564749999",
                "ts": 1_795_343_225_631
            ]
        ])
        #expect(direct.msgId == "8517564749999")
        #expect(direct.tsMs == 1_795_343_225_631)

        let nested = ZaloSessionClient.extractE2EESendResponse([
            "data": [
                "data": [
                    "minGlobalMsgId": "8517564750001",
                    "ts": 1_795_343_300
                ]
            ]
        ])
        #expect(nested.msgId == "8517564750001")
        #expect(nested.tsMs == 1_795_343_300_000)
    }

    @Test @MainActor func temporaryClientIdRowUpgradesOnE2EELockedEchoInMemoryAndSQLite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-e2ee-upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try ZaloSQLiteStore(path: root.appendingPathComponent("history.sqlite3").path)
        let cliId = "1795343225629"
        let srvId = "8517564748888"

        let localPlain = ChatMessage(
            id: cliId,
            conversationId: "3161",
            senderId: "100",
            senderName: "Bạn",
            senderAvatar: nil,
            isMine: true,
            kind: .text,
            text: "Tin nhắn E2EE vừa gửi",
            date: Date(timeIntervalSince1970: 1_795_343_225),
            status: .sent,
            quote: nil,
            reactions: [],
            isE2EE: true,
            clientId: cliId
        )
        let localStored = try #require(ZaloWireParser.encodeChatMessage(localPlain, clientId: cliId))
        try await store.saveMessages([localStored])

        // Locked server echo arrives with real server msgId and matching clientId
        let lockedEcho = ChatMessage(
            id: srvId,
            conversationId: "3161",
            senderId: "100",
            senderName: "Bạn",
            senderAvatar: nil,
            isMine: true,
            kind: .placeholder(symbol: "lock.fill", text: "Tin nhắn mã hóa đầu cuối"),
            text: "Tin nhắn mã hóa đầu cuối",
            date: Date(timeIntervalSince1970: 1_795_343_225),
            status: .sent,
            quote: nil,
            reactions: [],
            isE2EE: true,
            clientId: cliId
        )
        var lockedStored = try #require(ZaloWireParser.encodeChatMessage(lockedEcho, clientId: cliId))
        lockedStored.status = "e2ee_locked"
        try await store.saveMessages([lockedStored])

        let rows = try await store.messages(convId: "3161", limit: 10)
        #expect(rows.count == 1)
        #expect(rows.first?.id == srvId)
        #expect(rows.first?.clientId == cliId)
        #expect(rows.first?.text == "Tin nhắn E2EE vừa gửi")
        #expect(rows.first?.status == "sent")

        // Same upgrade behavior in engine in-memory message list
        let engine = ZaloEngine(dataDirectory: root, useKeychain: false)
        engine.messages["3161"] = [localPlain]
        engine.mergeMessageIntoMemory(lockedEcho, replacingClientId: cliId)
        let memMsg = try #require(engine.messages["3161"]?.first)
        #expect(memMsg.id == srvId)
        #expect(memMsg.clientId == cliId)
        #expect(memMsg.text == "Tin nhắn E2EE vừa gửi")
    }

    /// Regression: own E2EE text sent from this Mac stays keyed by its clientId until the server echo
    /// (which this device cannot decrypt) arrives. That echo used to be skipped outright while the chat
    /// was open, so recall/react kept sending `msgId == cliMsgId` and the server answered error 112.
    @Test @MainActor func lockedOwnE2EEEchoInBatchUpgradesOpenChatMessageIdInMemoryAndSQLite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-e2ee-batch-upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = ZaloEngine(dataDirectory: root, useKeychain: false)
        let store = try ZaloSQLiteStore(path: root.appendingPathComponent("history.sqlite3").path)
        engine.sqliteStore = store
        var account = ZaloLoginAccount()
        account.userId = "100"
        account.displayName = "Minh"
        engine.applyAccountProfile(account)

        let cliId = "1795343225629"
        let srvId = "8517564748888"
        let sent = ChatMessage(
            id: cliId,
            conversationId: "3161",
            senderId: "100",
            senderName: "Minh",
            senderAvatar: nil,
            isMine: true,
            kind: .text,
            text: "Tin nhắn E2EE vừa gửi",
            date: Date(timeIntervalSince1970: 1_795_343_225),
            status: .sent,
            quote: nil,
            reactions: [],
            isE2EE: true,
            clientId: cliId
        )
        engine.messages["3161"] = [sent]
        try await store.saveMessages([try #require(ZaloWireParser.encodeChatMessage(sent, clientId: cliId))])

        // Signal whisper-shaped ciphertext (type 3, version 0x33, proto tag 0x0A) this device cannot decrypt.
        var cipherBytes: [UInt8] = [3, 0x33, 0x0A]
        cipherBytes.append(contentsOf: (0..<61).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) })
        let cipher = Data(cipherBytes).base64EncodedString()
        #expect(ZaloWireParser.isSignalCiphertext(cipher))

        let echoBatch: [String: Any] = [
            "data": [
                "msgs": [[
                    "msgId": srvId,
                    "cliMsgId": cliId,
                    "uidFrom": "0",
                    "idTo": "3161",
                    "msgType": "webchat",
                    "ts": 1_795_343_225_631,
                    "content": cipher,
                ]]
            ]
        ]
        _ = await engine.applyBatchResponse(echoBatch, persistConversations: false)

        let mem = try #require(engine.messages["3161"])
        #expect(mem.count == 1)
        #expect(mem.first?.id == srvId)
        #expect(mem.first?.clientId == cliId)
        #expect(mem.first?.text == "Tin nhắn E2EE vừa gửi")

        let rows = try await store.messages(convId: "3161", limit: 10)
        #expect(rows.count == 1)
        #expect(rows.first?.id == srvId)
        #expect(rows.first?.clientId == cliId)
        #expect(rows.first?.text == "Tin nhắn E2EE vừa gửi")
        #expect(rows.first?.status == "sent")

        let ids = await engine.resolveServerAndClientIds(for: try #require(mem.first))
        #expect(ids.msgId == srvId)
        #expect(ids.cliMsgId == cliId)
    }

    @Test func findServerMsgIdExtractsServerIdMatchingClientId() {
        let payload: [String: Any] = [
            "data": [
                "msgs": [
                    ["msgId": "8517564741111", "cliMsgId": "1795343000001"],
                    ["msgId": "8517564742222", "cliMsgId": "1795343225629"]
                ]
            ]
        ]
        #expect(ZaloEngine.findServerMsgId(in: payload, matchingClientId: "1795343225629") == "8517564742222")
        #expect(ZaloEngine.findServerMsgId(in: payload, matchingClientId: "9999999999") == nil)

        let preloadNested: [String: Any] = [
            "data": [
                "msgs": [
                    "3161_0": #"[{"msgId":"8517564743333","cliMsgId":"1795343225999"}]"#
                ]
            ]
        ]
        #expect(ZaloEngine.findServerMsgId(in: preloadNested, matchingClientId: "1795343225999") == "8517564743333")
    }
}

@Suite struct ZCloudQuotaTests {
    @Test func cloudAESRoundTripsWithRandomIVAndRejectsInvalidInputs() throws {
        let key16 = Data(repeating: 0x2A, count: 16).base64EncodedString()
        let key32 = Data(repeating: 0x5C, count: 32).base64EncodedString()
        let plain = #"{"plan":-1,"quota":1073741824,"usage":5242880}"#

        let c1 = try ZaloCrypto.encodeCloudAES(base64Key: key16, plaintext: plain)
        let c2 = try ZaloCrypto.encodeCloudAES(base64Key: key16, plaintext: plain)
        #expect(c1 != c2) // random 16-byte IV produces distinct ciphertexts
        #expect(try ZaloCrypto.decodeCloudAES(base64Key: key16, base64Cipher: c1) == plain)
        #expect(try ZaloCrypto.decodeCloudAES(base64Key: key16, base64Cipher: c2) == plain)

        let c32 = try ZaloCrypto.encodeCloudAES(base64Key: key32, plaintext: plain)
        #expect(try ZaloCrypto.decodeCloudAES(base64Key: key32, base64Cipher: c32) == plain)

        let badKey = Data([1, 2, 3]).base64EncodedString()
        #expect(throws: ZaloCryptoError.self) {
            _ = try ZaloCrypto.encodeCloudAES(base64Key: badKey, plaintext: "hi")
        }
        #expect(throws: ZaloCryptoError.self) {
            _ = try ZaloCrypto.decodeCloudAES(base64Key: key16, base64Cipher: Data(repeating: 1, count: 16).base64EncodedString())
        }
    }

    @Test func parseCloudUsageSnapshotHandlesFreePaidGraceAndAfterGracePlans() {
        let freeSnap = ZaloSessionClient.parseCloudUsageSnapshot(
            usagePayload: [
                "plan": -1,
                "quota": 1_073_741_824,
                "usage": 38_080_000_000,
                "service_usage": [
                    "cloud_media": 38_000_000_000,
                    "message_backup": 30_000_000,
                    "my_cloud": 50_000_000
                ]
            ],
            settingsPayload: ["opt_in": 2, "enable_offload": 0, "cloud_media_file_size_limit": 0],
            infoPayload: nil,
            familyUsagePayload: nil,
            myUid: "100"
        )
        #expect(freeSnap?.planKind == .free)
        #expect(freeSnap?.planName == "Cloud của tôi")
        #expect(freeSnap?.quota == 1_073_741_824)
        #expect(freeSnap?.usage == 50_000_000)
        #expect(freeSnap?.myCloud == 50_000_000)
        #expect(freeSnap?.cloudMedia == 0)
        #expect(freeSnap?.messageBackup == 0)
        #expect(freeSnap?.backupMedia == false)
        #expect(freeSnap?.backupMyCloud == true)
        #expect(freeSnap?.fileLimit == Int64(100 * 1_048_576))

        let paidSnap = ZaloSessionClient.parseCloudUsageSnapshot(
            usagePayload: [
                "plan": 0,
                "quota": 107_374_182_400,
                "usage": 12_500_000_000,
                "service_usage": [
                    "cloud_media": 10_000_000_000,
                    "message_backup": 500_000_000,
                    "my_cloud": 2_000_000_000
                ]
            ],
            settingsPayload: ["opt_in": 7, "enable_offload": 1, "cloud_media_file_size_limit": 2_147_483_648],
            infoPayload: [
                "package_name": "zCloud Tiêu chuẩn",
                "subscription_info": [
                    "expire_time": 1_800_000_000_000,
                    "cancelled_renew": false,
                    "auto_renew_product_id": "zap-z8559d3p",
                    "duration_months": 12
                ]
            ],
            familyUsagePayload: [
                ["uid": "100", "usage": 12_500_000_000],
                ["uid": "201", "usage": 3_000_000_000],
                ["uid": "202", "usage": 1_000_000_000]
            ],
            myUid: "100"
        )
        #expect(paidSnap?.planKind == .paid)
        #expect(paidSnap?.planName == "zCloud Tiêu chuẩn")
        #expect(paidSnap?.usage == 12_500_000_000)
        #expect(paidSnap?.cloudMedia == 10_000_000_000)
        #expect(paidSnap?.messageBackup == 500_000_000)
        #expect(paidSnap?.myCloud == 2_000_000_000)
        #expect(paidSnap?.family == 4_000_000_000)
        #expect(paidSnap?.backupMedia == true)
        #expect(paidSnap?.backupMessages == true)
        #expect(paidSnap?.enableOffload == true)
        #expect(paidSnap?.autoRenew == true)
        #expect(paidSnap?.months == 12)
        #expect(paidSnap?.fileLimit == 2_147_483_648)

        let graceSnap = ZaloSessionClient.parseCloudUsageSnapshot(
            usagePayload: [
                "plan": 100,
                "quota": 107_374_182_400,
                "usage": 5_000_000_000,
                "service_usage": ["cloud_media": 4_000_000_000, "my_cloud": 1_000_000_000]
            ],
            settingsPayload: nil,
            infoPayload: nil,
            familyUsagePayload: nil,
            myUid: "100"
        )
        #expect(graceSnap?.planKind == .grace)
        #expect(graceSnap?.usage == 5_000_000_000)

        let afterGraceSnap = ZaloSessionClient.parseCloudUsageSnapshot(
            usagePayload: [
                "plan": 69,
                "quota": 1_073_741_824,
                "usage": 39_000_000_000,
                "service_usage": ["cloud_media": 38_990_000_000, "my_cloud": 10_000_000]
            ],
            settingsPayload: nil,
            infoPayload: nil,
            familyUsagePayload: nil,
            myUid: "100"
        )
        #expect(afterGraceSnap?.planKind == .afterGrace)
        #expect(afterGraceSnap?.usage == 10_000_000)
        #expect(afterGraceSnap?.cloudMedia == 0)
    }

    @Test @MainActor func offlineFreeFallbackCountsOnlyMyCloudWhileKeepingMediaStats() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-cloud-free-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = ZaloEngine(dataDirectory: root, useKeychain: false)
        let store = try ZaloSQLiteStore(path: root.appendingPathComponent("history.sqlite3").path)
        engine.sqliteStore = store
        var acc = ZaloLoginAccount()
        acc.userId = "100"
        acc.send2MeId = "999"
        engine.applyAccountProfile(acc)

        let mOther = ChatMessage(
            id: "m_other",
            conversationId: "101",
            senderId: "101",
            senderName: "An",
            senderAvatar: nil,
            isMine: false,
            kind: .file(name: "Archive.zip", size: 5_000_000_000, url: nil),
            text: "Archive.zip",
            date: Date(timeIntervalSince1970: 10),
            status: .sent,
            quote: nil,
            reactions: [],
            isE2EE: false
        )
        let mCloud = ChatMessage(
            id: "m_cloud",
            conversationId: "999",
            senderId: "100",
            senderName: "Cloud của tôi",
            senderAvatar: nil,
            isMine: true,
            kind: .file(name: "Doc.pdf", size: 4_000_000, url: nil),
            text: "Doc.pdf",
            date: Date(timeIntervalSince1970: 20),
            status: .sent,
            quote: nil,
            reactions: [],
            isE2EE: false
        )
        try await store.saveMessages([
            try #require(ZaloWireParser.encodeChatMessage(mOther)),
            try #require(ZaloWireParser.encodeChatMessage(mCloud))
        ])

        await engine.performRefreshCloud()
        #expect(engine.cloud.media.file == 5_000_000_000)
        #expect(engine.cloud.myCloudTypes.file == 4_000_000)
        #expect(engine.cloud.plan?.kind == .free)
        #expect(engine.cloud.plan?.usage == 4_000_000)
        #expect(engine.cloud.plan?.myCloud == 4_000_000)
        #expect(engine.cloud.plan?.cloudMedia == 0)
    }
}

@Suite struct FileSendingTests {
    @Test func secureStreamEncryptE2EEFileRoundTripsAndDetectsTampering() throws {
        let plaintext = Data("Nội dung tệp bí mật 1234567890!".utf8)
        let encrypted = try SecureStream.encryptE2EEFile(plaintext)
        let sessionData = try #require(Data(base64Encoded: encrypted.base64Session))
        #expect(sessionData.count == 60)

        guard case .stream(let stream) = SecureStream.parseE2EESession(encrypted.base64Session) else {
            Issue.record("Expected valid AES-GCM SecureStream")
            return
        }
        let decrypted = try stream.decrypt(encrypted.ciphertext)
        #expect(decrypted == plaintext)

        var tampered = encrypted.ciphertext
        tampered[0] ^= 0xFF
        #expect(throws: (any Error).self) {
            _ = try stream.decrypt(tampered)
        }
    }

    @Test func asyncFilePayloadUsesFType1EvenForVideoFileAttachment() {
        let spec11 = ZaloSessionClient.buildAsyncFileMsgPayload(
            cleanConvId: "200",
            isGroup: false,
            fileId: "12345",
            fileUrl: "https://f.zdn.vn/clip.mp4",
            fileName: "clip.mp4",
            ext: "mp4",
            fileSize: 2048,
            checksum: "abcd",
            clientId: 9001,
            imei: "imei-x"
        )
        #expect(spec11.path == "/api/message/asyncfile/msg")
        #expect(spec11.payload["fType"] as? Int == 1)
        #expect(spec11.payload["toid"] as? String == "200")
        #expect(spec11.payload["fileId"] as? Int64 == 12345)

        let specGroup = ZaloSessionClient.buildAsyncFileMsgPayload(
            cleanConvId: "555",
            isGroup: true,
            fileId: "99",
            fileUrl: "https://f.zdn.vn/doc.pdf",
            fileName: "doc.pdf",
            ext: "pdf",
            fileSize: 512,
            checksum: "ef01",
            clientId: 9002,
            imei: "imei-x"
        )
        #expect(specGroup.path == "/api/group/asyncfile/msg")
        #expect(specGroup.payload["grid"] as? String == "555")
        #expect(specGroup.payload["fType"] as? Int == 1)
    }

    @Test func e2eeFileMsgParamsAndListParamEntryFormat() throws {
        let jsonStr = ZaloSessionClient.buildFileMsgParamsJSON(md5Hex: "deadbeef", fileExt: "pdf", fileSize: 4096)
        let jsonData = try #require(jsonStr.data(using: .utf8))
        let parsed = try #require(JSONSerialization.jsonObject(with: jsonData) as? [String: Any])
        #expect(parsed["checksum"] as? String == "deadbeef")
        #expect(parsed["fType"] as? Int == 1)
        #expect(parsed["fdata"] as? String == "{}")
        #expect(parsed["fileExt"] as? String == "pdf")
        #expect(parsed["fileSize"] as? Int == 4096)

        let entry = ZaloSessionClient.buildE2EEFileListParamEntry(
            toId: "300",
            platform: 1,
            clientId: 777,
            imei: "imei-1",
            registrationId: 12,
            senderIid: 34,
            rawFileUrl: "https://cdn.example.test/enc.bin",
            fileId: "987654",
            cipherSession: "CIPHER_SESS",
            cipherParams: "CIPHER_PRM",
            cipherFileName: "CIPHER_NAME",
            cipherThumb: "CIPHER_THUMB"
        )
        #expect(entry["toId"] as? String == "300")
        #expect(entry["fileUrl"] as? String == "https://cdn.example.test/enc.bin?e2esession=CIPHER_SESS")
        #expect(entry["prmE2EE"] as? String == "CIPHER_PRM")
        #expect(entry["fileName"] as? String == "CIPHER_NAME")
        #expect(entry["thumb"] as? String == "CIPHER_THUMB")
        #expect(entry["fileId"] as? Int64 == 987654)

        let extJSON = try #require((entry["e2eeExt"] as? String)?.data(using: .utf8))
        let extObj = try #require(JSONSerialization.jsonObject(with: extJSON) as? [String: Any])
        #expect(extObj["version"] as? Int == 0)
        #expect(extObj["compat_version"] as? Int == 0)
        #expect(extObj["iid"] as? Int == 12)
        #expect(extObj["sender_iid"] as? Int == 34)
    }

    @Test func webSocketExtractsFileDoneAndVideoDoneEvents() {
        let payload: [String: Any] = [
            "data": [
                "controls": [
                    [
                        "content": [
                            "act_type": "file_done",
                            "data": [
                                "fileId": "f1",
                                "data": ["url": "https://cdn.example.test/f1.pdf"]
                            ]
                        ]
                    ],
                    [
                        "content": #"{"act_type":"video_done","data":{"fileId":"v2","url":"https://cdn.example.test/v2.mp4"}}"#
                    ]
                ]
            ]
        ]
        let events = ZaloWebSocket.extractFileDoneEvents(payload)
        #expect(events.count == 2)
        #expect(events[0].fileId == "f1" && events[0].url == "https://cdn.example.test/f1.pdf")
        #expect(events[1].fileId == "v2" && events[1].url == "https://cdn.example.test/v2.mp4")
    }

    @Test func validateOutgoingFileRejectsDirectoryEmptyOversizeAndAcceptsValidFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-file-val-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(ZaloEngine.validateOutgoingFile(root, maxBytes: 1024) != nil)

        let emptyFile = root.appendingPathComponent("empty.txt")
        try Data().write(to: emptyFile)
        #expect(ZaloEngine.validateOutgoingFile(emptyFile, maxBytes: 1024) != nil)

        let bigFile = root.appendingPathComponent("big.bin")
        try Data(repeating: 0x41, count: 2048).write(to: bigFile)
        #expect(ZaloEngine.validateOutgoingFile(bigFile, maxBytes: 1024) != nil)

        let okFile = root.appendingPathComponent("ok.txt")
        try Data("hello".utf8).write(to: okFile)
        #expect(ZaloEngine.validateOutgoingFile(okFile, maxBytes: 1024) == nil)
    }
}

@Suite(.serialized) struct ReactionFixTests {
    @Test func reactionSpecAndIconMappings() {
        #expect(ZaloWireParser.reactionSpec(forEmoji: "😡") == (":-h", 20))
        #expect(ZaloWireParser.reactionSpec(forEmoji: "😠") == (":-h", 20))
        #expect(ZaloWireParser.reactionSpec(forEmoji: "❤️") == ("/-heart", 5))
        #expect(ZaloWireParser.reactionSpec(forEmoji: "❤") == ("/-heart", 5))
        #expect(ZaloWireParser.reactionSpec(forEmoji: "👍") == ("/-strong", 3))
        #expect(ZaloWireParser.reactionSpec(forEmoji: "😆") == (":>", 0))
        #expect(ZaloWireParser.reactionSpec(forEmoji: "😮") == (":o", 32))
        #expect(ZaloWireParser.reactionSpec(forEmoji: "😢") == (":-((", 2))

        #expect(ZaloWireParser.reactionIcon(rType: "20")?.emoji == "😡")
        #expect(ZaloWireParser.reactionIcon(rType: "-1") == nil)
        #expect(ZaloWireParser.reactionIcon(rType: "-1", rIcon: "") == nil)
        #expect(ZaloWireParser.reactionIcon(rType: "", rIcon: "") == nil)
        #expect(ZaloWireParser.reactionIcon(rType: "999", rIcon: "") == nil)
        #expect(ZaloWireParser.reactionIcon(rType: "34", rIcon: "/-weak")?.emoji == "/-weak")
    }

    @Test func reactionClientMsgTypeCoversMediaAndFiles() {
        #expect(ZaloWireParser.reactionClientMsgType(for: .text) == 1)
        #expect(ZaloWireParser.reactionClientMsgType(for: .voice(url: nil, duration: 5)) == 31)
        #expect(ZaloWireParser.reactionClientMsgType(for: .photo(url: nil, width: 100, height: 100)) == 32)
        #expect(ZaloWireParser.reactionClientMsgType(for: .sticker(url: nil)) == 36)
        #expect(ZaloWireParser.reactionClientMsgType(for: .link(title: "t", url: nil, thumbnail: nil)) == 38)
        #expect(ZaloWireParser.reactionClientMsgType(for: .contactCard(ChatMessage.ContactCard(name: "A"))) == 38)
        #expect(ZaloWireParser.reactionClientMsgType(for: .location(ChatMessage.LocationInfo())) == 43)
        #expect(ZaloWireParser.reactionClientMsgType(for: .video(thumbnail: nil, duration: 3)) == 44)
        #expect(ZaloWireParser.reactionClientMsgType(for: .file(name: "a.pdf", size: 10, url: nil)) == 46)
        #expect(ZaloWireParser.reactionClientMsgType(for: .gif(url: nil)) == 49)
    }

    @Test @MainActor func localReactEchoDuplicateDeliveryAndFileFallbackWorkReliably() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-react-fix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            CardActionCenter.shared.reset()
            try? FileManager.default.removeItem(at: root)
        }

        let key = Data("0123456789abcdef".utf8)
        let capturedMsgTypes = OSAllocatedUnfairLock<[Int]>(initialState: [])

        let server = try FakeZaloServer { req in
            let payload = req.decodeEncryptedParams(key: key) ?? [:]
            if let list = payload["react_list"] as? [[String: Any]],
               let msgStr = list.first?["message"] as? String,
               let inner = JSONLossless.parseObject(Data(msgStr.utf8)),
               let rMsg = (inner["rMsg"] as? [[String: Any]])?.first,
               let mType = (rMsg["msgType"] as? NSNumber)?.intValue {
                let count = capturedMsgTypes.withLock { arr in
                    arr.append(mType)
                    return arr.count
                }
                // Simulate server rejecting msgType=46 on first try to verify fallback to msgType=1.
                if mType == 46 && count == 3 {
                    return .json(200, ["error_code": 112, "error_message": "invalid msgType"])
                }
            }
            return .json(200, ["error_code": 0, "data": [:]])
        }
        try await server.start()
        defer { server.stop() }

        let engine = ZaloEngine(dataDirectory: root, useKeychain: false)
        let store = try ZaloSQLiteStore(path: root.appendingPathComponent("history.sqlite3").path)
        engine.sqliteStore = store

        let domains = server.domains(for: ["reaction", "chat", "group", "conversation", "group_cloud_message"])
        var account = ZaloLoginAccount()
        account.userId = "100"
        account.displayName = "Minh"
        engine.applyAccountProfile(account)
        await engine.sessionClient.updateCredentials(account: account, secretKey: key, zpwSek: "sek.1.2", domains: domains)

        let photoMsg = ChatMessage(
            id: "88001",
            conversationId: "200",
            senderId: "200",
            senderName: "Lan",
            senderAvatar: nil,
            isMine: false,
            kind: .photo(url: URL(string: "https://cdn.example/p.jpg"), width: 100, height: 100),
            text: "",
            date: Date(timeIntervalSince1970: 1_760_000_000),
            status: .sent,
            quote: nil,
            reactions: [],
            isE2EE: false,
            clientId: "17001"
        )
        let fileMsg = ChatMessage(
            id: "88002",
            conversationId: "200",
            senderId: "200",
            senderName: "Lan",
            senderAvatar: nil,
            isMine: false,
            kind: .file(name: "doc.pdf", size: 2048, url: URL(string: "https://cdn.example/doc.pdf")),
            text: "doc.pdf",
            date: Date(timeIntervalSince1970: 1_760_000_010),
            status: .sent,
            quote: nil,
            reactions: [],
            isE2EE: false,
            clientId: "17002"
        )
        engine.messages["200"] = [photoMsg, fileMsg]
        if let s1 = ZaloWireParser.encodeChatMessage(photoMsg),
           let s2 = ZaloWireParser.encodeChatMessage(fileMsg) {
            try await store.saveMessages([s1, s2])
        }

        // 1. React to photo -> sends msgType=32, count=1
        await engine.performReact("❤️", to: "88001", in: "200")
        var currentPhoto = try #require(engine.messages["200"]?.first(where: { $0.id == "88001" }))
        #expect(currentPhoto.reactions.count == 1)
        #expect(currentPhoto.reactions.first?.count == 1)
        #expect(currentPhoto.reactions.first?.includesMe == true)
        #expect(currentPhoto.reactions.first?.people == 1)

        // 2. WS echo + duplicate poll delivery must NOT double-count (remains 1)
        await engine.applyRemoteReaction(
            convId: "200",
            msgId: "88001",
            cliMsgId: "17001",
            senderId: "100",
            rType: "5",
            rIcon: "/-heart",
            eventId: "ev_echo_1"
        )
        await engine.applyRemoteReaction(
            convId: "200",
            msgId: "88001",
            cliMsgId: "17001",
            senderId: "100",
            rType: "5",
            rIcon: "/-heart",
            eventId: "ev_echo_1"
        )
        currentPhoto = try #require(engine.messages["200"]?.first(where: { $0.id == "88001" }))
        #expect(currentPhoto.reactions.count == 1)
        #expect(currentPhoto.reactions.first?.count == 1)

        // 3. Toggle off photo reaction -> removes completely from memory & SQLite
        await engine.performReact("❤️", to: "88001", in: "200")
        currentPhoto = try #require(engine.messages["200"]?.first(where: { $0.id == "88001" }))
        #expect(currentPhoto.reactions.isEmpty)
        let storedPhoto = try #require(try await store.message(convId: "200", idOrClientId: "88001"))
        let decodedPhoto = try #require(ZaloWireParser.decodeStoredMessage(storedPhoto))
        #expect(decodedPhoto.reactions.isEmpty)

        // 4. React to file -> tries msgType=46, falls back to msgType=1 on 112, succeeds with count=1
        await engine.performReact("😡", to: "88002", in: "200")
        let currentFile = try #require(engine.messages["200"]?.first(where: { $0.id == "88002" }))
        #expect(currentFile.reactions.count == 1)
        #expect(currentFile.reactions.first?.icon.emoji == "😡")
        #expect(currentFile.reactions.first?.count == 1)
        #expect(capturedMsgTypes.withLock { $0 } == [32, 32, 46, 1])
    }

    @Test @MainActor func removeAllMyReactionsKeepsOthers() {
        var reactions = [
            ChatMessage.Reaction(icon: ReactionIcon(type: "5", key: "/-heart", emoji: "❤️"), count: 2,
                                 includesMe: true, names: ["Bạn", "Lan"], people: 2, userCounts: ["100": 1, "200": 1]),
            ChatMessage.Reaction(icon: ReactionIcon(type: "3", key: "/-strong", emoji: "👍"), count: 1,
                                 includesMe: true, names: ["Bạn"], people: 1, userCounts: ["100": 1]),
        ]
        ZaloEngine.mutateReactions(&reactions, actorUid: "100", myUid: "100", isMe: true, rType: "-1", rIcon: "",
                                   allowDuplicateSameUser: true, nameLookup: { _ in "Lan" })
        #expect(reactions.count == 1)
        #expect(reactions[0].icon.type == "5")
        #expect(reactions[0].includesMe == false)
        #expect(reactions[0].userCounts == ["200": 1])
    }

    @Test @MainActor func remoteUnreactAndCorruptedGhostReactionsAreEliminated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-ghost-react-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = ZaloEngine(dataDirectory: root, useKeychain: false)
        let store = try ZaloSQLiteStore(path: root.appendingPathComponent("history.sqlite3").path)
        engine.sqliteStore = store
        var account = ZaloLoginAccount()
        account.userId = "100"
        account.displayName = "Minh"
        engine.applyAccountProfile(account)
        engine.contacts.friends = [
            ContactsState.Friend(
                id: "201",
                name: "An",
                zaloName: "An",
                avatar: nil,
                lastActive: nil,
                online: true,
                section: "A",
                sortKey: "an"
            )
        ]

        let msg = ChatMessage(
            id: "9001",
            conversationId: "201",
            senderId: "100",
            senderName: "Bạn",
            senderAvatar: nil,
            isMine: true,
            kind: .text,
            text: "Hello",
            date: Date(),
            status: .sent,
            quote: nil,
            reactions: [],
            isE2EE: false,
            clientId: "c9001"
        )
        engine.messages["201"] = [msg]
        if let s = ZaloWireParser.encodeChatMessage(msg) {
            try await store.saveMessages([s])
        }

        // Peer reacts twice via distinct eventIds, then unreacts once -> removes ALL their reactions (no ghost 1)
        await engine.applyRemoteReaction(convId: "201", msgId: "9001", cliMsgId: "c9001", senderId: "201", rType: "3", rIcon: "/-strong", eventId: "e1")
        await engine.applyRemoteReaction(convId: "201", msgId: "9001", cliMsgId: "c9001", senderId: "201", rType: "3", rIcon: "/-strong", eventId: "e2")
        #expect(engine.messages["201"]?.first?.reactions.first?.count == 2)

        await engine.applyRemoteReaction(convId: "201", msgId: "9001", cliMsgId: "c9001", senderId: "201", rType: "-1", rIcon: "", eventId: "e3")
        #expect(engine.messages["201"]?.first?.reactions.isEmpty == true)

        // Legacy reaction without userCounts (people=1, count=2, names=["An"]) -> peer unreact removes completely
        var legacyMsg = msg
        legacyMsg.id = "9002"
        legacyMsg.reactions = [
            ChatMessage.Reaction(
                icon: ReactionIcon(type: "3", key: "/-strong", emoji: "👍"),
                count: 2,
                includesMe: false,
                names: ["An"],
                people: 1
            )
        ]
        engine.messages["201"] = [legacyMsg]
        await engine.applyRemoteReaction(convId: "201", msgId: "9002", cliMsgId: "", senderId: "201", rType: "-1", rIcon: "", eventId: "e4")
        #expect(engine.messages["201"]?.first?.reactions.isEmpty == true)

        // Corrupted ghost reaction persisted in SQLite (`count: 1, people: 0, includesMe: false, names: []`) is dropped on decode
        let ghostDecoded = try #require(ChatMessage(
            json: [
                "id": "9003",
                "kind": ["type": "text"],
                "text": "Ghost check",
                "reactions": [[
                    "type": "3",
                    "key": "/-strong",
                    "emoji": "👍",
                    "image": "",
                    "count": 1,
                    "includesMe": false,
                    "names": [] as [String],
                    "people": 0
                ]]
            ],
            fallbackConversation: "201"
        ))
        #expect(ghostDecoded.reactions.isEmpty)
    }

    @Test @MainActor func historyRefetchAndSQLiteSavePreserveExistingReactions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-preserve-react-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = ZaloEngine(dataDirectory: root, useKeychain: false)
        let store = try ZaloSQLiteStore(path: root.appendingPathComponent("history.sqlite3").path)

        let withReaction = ChatMessage(
            id: "7001",
            conversationId: "200",
            senderId: "200",
            senderName: "Lan",
            senderAvatar: nil,
            isMine: false,
            kind: .text,
            text: "Test",
            date: Date(timeIntervalSince1970: 1_760_000_000),
            status: .sent,
            quote: nil,
            reactions: [
                ChatMessage.Reaction(
                    icon: ReactionIcon(type: "5", key: "/-heart", emoji: "❤️"),
                    count: 1,
                    includesMe: true,
                    names: ["Bạn"],
                    people: 1,
                    userCounts: ["100": 1]
                )
            ],
            isE2EE: false,
            clientId: "c7001"
        )
        engine.messages["200"] = [withReaction]
        let storedWith = try #require(ZaloWireParser.encodeChatMessage(withReaction))
        try await store.saveMessages([storedWith])

        var withoutReaction = withReaction
        withoutReaction.reactions = []
        engine.mergeMessageIntoMemory(withoutReaction, replacingClientId: "c7001")
        #expect(engine.messages["200"]?.first?.reactions.count == 1)

        let storedWithout = try #require(ZaloWireParser.encodeChatMessage(withoutReaction))
        try await store.saveMessages([storedWithout], preserveExistingReactions: true)
        let rowPreserve = try #require(try await store.message(convId: "200", idOrClientId: "7001"))
        let afterPreserve = try #require(ZaloWireParser.decodeStoredMessage(rowPreserve))
        #expect(afterPreserve.reactions.count == 1)

        try await store.saveMessages([storedWithout], preserveExistingReactions: false)
        let rowClear = try #require(try await store.message(convId: "200", idOrClientId: "7001"))
        let afterClear = try #require(ZaloWireParser.decodeStoredMessage(rowClear))
        #expect(afterClear.reactions.isEmpty)
    }

    @Test func webSocketHighestActionIdAdvancesAcrossReactQueues() {
        let highest = ZaloWebSocket.highestActionId(in: [
            "reacts": [["actionId": "505"]],
            "reactGroups": [["actId": "606"]]
        ])
        #expect(highest == "606")
    }

    @Test @MainActor func newestFirstReactionBatchesApplyChronologicallyWithoutResurrectingUnreacts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-chrono-react-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = ZaloEngine(dataDirectory: root, useKeychain: false)
        let store = try ZaloSQLiteStore(path: root.appendingPathComponent("history.sqlite3").path)
        engine.sqliteStore = store
        var account = ZaloLoginAccount()
        account.userId = "100"
        account.displayName = "Minh"
        engine.applyAccountProfile(account)

        let msg = ChatMessage(
            id: "6001",
            conversationId: "200",
            senderId: "200",
            senderName: "Lan",
            senderAvatar: nil,
            isMine: false,
            kind: .text,
            text: "Hello",
            date: Date(timeIntervalSince1970: 1_760_000_000),
            status: .sent,
            quote: nil,
            reactions: [],
            isE2EE: false,
            clientId: "c6001"
        )
        engine.messages["200"] = [msg]
        if let s = ZaloWireParser.encodeChatMessage(msg) {
            try await store.saveMessages([s])
        }

        // Batch returns unreact(t=2000) BEFORE react(t=1000) -> chronological sort applies react first, then unreact
        let newestFirstBatch: [String: Any] = [
            "data": [
                "reacts": [
                    [
                        "actionId": "20",
                        "uidFrom": "200",
                        "idTo": "100",
                        "ts": 2000,
                        "content": [
                            "rType": -1,
                            "rIcon": "",
                            "rMsg": [["gMsgID": "6001", "cMsgID": "c6001"]]
                        ]
                    ],
                    [
                        "actionId": "10",
                        "uidFrom": "200",
                        "idTo": "100",
                        "ts": 1000,
                        "content": [
                            "rType": 5,
                            "rIcon": "/-heart",
                            "rMsg": [["gMsgID": "6001", "cMsgID": "c6001"]]
                        ]
                    ]
                ]
            ]
        ]

        _ = await engine.applyBatchResponse(newestFirstBatch, persistConversations: false)
        let after = try #require(engine.messages["200"]?.first)
        #expect(after.reactions.isEmpty)
        let storedAfter = try #require(try await store.message(convId: "200", idOrClientId: "6001"))
        let decodedAfter = try #require(ZaloWireParser.decodeStoredMessage(storedAfter))
        #expect(decodedAfter.reactions.isEmpty)
    }

    @Test @MainActor func persistedReactionDedupPollStateAndWSCursorsSurviveRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-restart-react-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dbPath = root.appendingPathComponent("history.sqlite3").path
        do {
            let engine1 = ZaloEngine(dataDirectory: root, useKeychain: false)
            let store1 = try ZaloSQLiteStore(path: dbPath)
            engine1.sqliteStore = store1
            var account = ZaloLoginAccount()
            account.userId = "100"
            account.displayName = "Minh"
            engine1.applyAccountProfile(account)
            await engine1.loadLocalAccountState(from: store1)

            let msg = ChatMessage(
                id: "77001",
                conversationId: "200",
                senderId: "200",
                senderName: "Lan",
                senderAvatar: nil,
                isMine: false,
                kind: .text,
                text: "Ping",
                date: Date(timeIntervalSince1970: 1_760_000_000),
                status: .sent,
                quote: nil,
                reactions: [],
                isE2EE: false,
                clientId: "c77001"
            )
            engine1.messages["200"] = [msg]
            if let s = ZaloWireParser.encodeChatMessage(msg) {
                try await store1.saveMessages([s])
            }

            // Simulate remote reaction + local reaction + pollState + WS cursor persistence
            await engine1.applyRemoteReaction(
                convId: "200",
                msgId: "77001",
                cliMsgId: "c77001",
                senderId: "200",
                rType: "5",
                rIcon: "/-heart",
                eventId: "ev_900",
                reactClientId: "cli_peer_900"
            )
            await engine1.recordSeenReactionKeys(["200|77001|cli:local_react_77|3"])
            engine1.pollState.lastActionId = "456789"
            await engine1.persistPollState()
            await engine1.persistWSQueueCursors([
                "510_0": ZaloWSQueueCursorSnapshot(lastId: "998877", preIds: ["12"])
            ])
            await store1.close()
        }

        // Simulate cold restart with a brand new ZaloEngine opening the same SQLite store
        let engine2 = ZaloEngine(dataDirectory: root, useKeychain: false)
        let store2 = try ZaloSQLiteStore(path: dbPath)
        engine2.sqliteStore = store2
        var account2 = ZaloLoginAccount()
        account2.userId = "100"
        account2.displayName = "Minh"
        engine2.applyAccountProfile(account2)
        await engine2.loadLocalAccountState(from: store2)

        #expect(engine2.pollState.lastActionId == "456789")
        let restoredCursors = await engine2.webSocket.currentQueueCursors()
        #expect(restoredCursors["510_0"] == ZaloWSQueueCursorSnapshot(lastId: "998877", preIds: ["12"]))

        let storedBeforeReplay = try #require(try await store2.message(convId: "200", idOrClientId: "77001"))
        if let decodedBefore = ZaloWireParser.decodeStoredMessage(storedBeforeReplay) {
            engine2.messages["200"] = [decodedBefore]
        }

        // Replayed remote reaction & replayed local reactClientId must both be ignored without double-counting
        await engine2.applyRemoteReaction(
            convId: "200",
            msgId: "77001",
            cliMsgId: "c77001",
            senderId: "200",
            rType: "5",
            rIcon: "/-heart",
            eventId: "ev_900",
            reactClientId: "cli_peer_900"
        )
        await engine2.applyRemoteReaction(
            convId: "200",
            msgId: "77001",
            cliMsgId: "c77001",
            senderId: "100",
            rType: "3",
            rIcon: "/-strong",
            eventId: "ev_local_replay",
            reactClientId: "local_react_77"
        )
        let current = try #require(engine2.messages["200"]?.first)
        #expect(current.reactions.count == 1)
        #expect(current.reactions.first?.icon.type == "5")
        #expect(current.reactions.first?.count == 1)
    }

    @Test func repairLegacyReactionsCleansPreFixGhostsAndNormalizesUserCountsIdempotently() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-repair-react-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try ZaloSQLiteStore(path: root.appendingPathComponent("history.sqlite3").path)

        func makeStored(id: String, reactions: [[String: Any]]) throws -> StoredMessage {
            let dict: [String: Any] = [
                "id": id,
                "clientId": "c_\(id)",
                "conversationId": "200",
                "senderId": "200",
                "senderName": "Lan",
                "senderAvatar": "",
                "isMine": false,
                "kind": ["type": "text"],
                "text": "Msg \(id)",
                "date": 1_760_000_000_000,
                "status": "sent",
                "reactions": reactions,
                "isE2EE": false
            ]
            let data = try JSONSerialization.data(withJSONObject: dict)
            return StoredMessage(
                id: id, convId: "200", clientId: "c_\(id)",
                senderId: "200", senderName: "Lan", senderAvatar: "",
                isMine: false, text: "Msg \(id)", kindTag: "text",
                tsMs: 1_760_000_000_000, status: "sent", rawJSONData: data
            )
        }

        // Row 1: pre-fix ghost lacking userCounts -> must be stripped
        let ghostRow = try makeStored(id: "m1", reactions: [[
            "type": "5", "key": "/-heart", "emoji": "❤️", "image": "",
            "count": 1, "includesMe": false, "names": ["Người dùng Zalo"], "people": 1
        ]])
        // Row 2: has __legacy__ + "u200" + "0" + "Người dùng Zalo" -> cleaned & normalized
        let mixedRow = try makeStored(id: "m2", reactions: [[
            "type": "5", "key": "/-heart", "emoji": "❤️", "image": "",
            "count": 4, "includesMe": false, "names": ["Người dùng Zalo", "Lan"], "people": 3,
            "userCounts": ["__legacy__": 2, "u200": 1, "0": 1]
        ]])
        try await store.saveMessages([ghostRow, mixedRow])

        let firstCount = try await store.repairLegacyReactions(myUid: "100")
        #expect(firstCount == 2)
        // Idempotent second call returns 0
        let secondCount = try await store.repairLegacyReactions(myUid: "100")
        #expect(secondCount == 0)

        let row1 = try #require(try await store.message(convId: "200", idOrClientId: "m1"))
        let msg1 = try #require(ZaloWireParser.decodeStoredMessage(row1))
        #expect(msg1.reactions.isEmpty)

        let row2 = try #require(try await store.message(convId: "200", idOrClientId: "m2"))
        let msg2 = try #require(ZaloWireParser.decodeStoredMessage(row2))
        let r2 = try #require(msg2.reactions.first)
        #expect(r2.count == 2)
        #expect(r2.people == 2)
        #expect(r2.includesMe == true)
        #expect(r2.userCounts == ["200": 1, "100": 1])
        #expect(r2.names == ["Lan"])
    }

    @Test @MainActor func mutateReactionsNeverCreatesLegacySentinelOverPreFixRow() {
        var reactions = [
            ChatMessage.Reaction(
                icon: ReactionIcon(type: "5", key: "/-heart", emoji: "❤️"),
                count: 1,
                includesMe: false,
                names: [ReactionDetail.unknownName],
                people: 1,
                userCounts: [:]
            )
        ]

        ZaloEngine.mutateReactions(
            &reactions,
            actorUid: "100",
            myUid: "100",
            isMe: true,
            rType: "5",
            rIcon: "/-heart",
            allowDuplicateSameUser: true,
            nameLookup: { _ in "Bạn" }
        )
        #expect(reactions.count == 1)
        #expect(reactions.first?.userCounts["__legacy__"] == nil)
        #expect(reactions.first?.userCounts == ["100": 1])
        #expect(reactions.first?.count == 1)

        ZaloEngine.mutateReactions(
            &reactions,
            actorUid: "100",
            myUid: "100",
            isMe: true,
            rType: "-1",
            rIcon: "",
            allowDuplicateSameUser: false,
            nameLookup: { _ in "Bạn" }
        )
        #expect(reactions.isEmpty)
    }

    @Test @MainActor func reactorsResolvesPrefixedOneToOnePeerAndFetchesMissingGroupProfiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-reactors-fix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let key = Data("0123456789abcdef".utf8)
        let server = try FakeZaloServer { req in
            if req.path == "/api/social/group/members" {
                return .json(200, [
                    "error_code": 0,
                    "data": [
                        "profiles": [
                            "555": [
                                "userId": "555",
                                "displayName": "Hùng",
                                "avatar": "https://ava.example/555.jpg"
                            ]
                        ]
                    ]
                ])
            }
            return .json(200, ["error_code": 0, "data": [:]])
        }
        try await server.start()
        defer { server.stop() }

        let engine = ZaloEngine(dataDirectory: root, useKeychain: false)
        let store = try ZaloSQLiteStore(path: root.appendingPathComponent("history.sqlite3").path)
        engine.sqliteStore = store

        let domains = server.domains(for: ["profile", "reaction", "chat", "group", "conversation"])
        var account = ZaloLoginAccount()
        account.userId = "100"
        account.displayName = "Minh"
        engine.applyAccountProfile(account)
        await engine.sessionClient.updateCredentials(account: account, secretKey: key, zpwSek: "sek.1.2", domains: domains)

        engine.contacts.friends = [
            ContactsState.Friend(
                id: "200",
                name: "Lan",
                zaloName: "Lan",
                avatar: URL(string: "https://ava.example/200.jpg"),
                lastActive: nil,
                online: true,
                section: "L",
                sortKey: "lan"
            )
        ]

        // 1-1 message reacted by "u200" -> resolves to "Lan" (not "Người dùng Zalo")
        let oneToOneMsg = ChatMessage(
            id: "8100",
            conversationId: "200",
            senderId: "100",
            senderName: "Bạn",
            senderAvatar: nil,
            isMine: true,
            kind: .photo(url: URL(string: "https://cdn.example/p.jpg"), width: 100, height: 100),
            text: "",
            date: Date(timeIntervalSince1970: 1_760_000_000),
            status: .sent,
            quote: nil,
            reactions: [
                ChatMessage.Reaction(
                    icon: ReactionIcon(type: "5", key: "/-heart", emoji: "❤️"),
                    count: 1,
                    includesMe: false,
                    names: [],
                    people: 1,
                    userCounts: ["u200": 1]
                )
            ],
            isE2EE: false
        )
        engine.messages["200"] = [oneToOneMsg]

        let detail1 = try #require(await engine.reactors(for: "8100", in: "200"))
        #expect(detail1.users.count == 1)
        #expect(detail1.users.first?.uid == "200")
        #expect(detail1.users.first?.name == "Lan")
        #expect(detail1.users.first?.avatar?.absoluteString == "https://ava.example/200.jpg")

        // Group message reacted by non-friend UID "555" -> fetches profile and resolves "Hùng"
        let groupMsg = ChatMessage(
            id: "8200",
            conversationId: "g900",
            senderId: "555",
            senderName: "",
            senderAvatar: nil,
            isMine: false,
            kind: .text,
            text: "Group hi",
            date: Date(timeIntervalSince1970: 1_760_000_010),
            status: .sent,
            quote: nil,
            reactions: [
                ChatMessage.Reaction(
                    icon: ReactionIcon(type: "5", key: "/-heart", emoji: "❤️"),
                    count: 1,
                    includesMe: false,
                    names: [],
                    people: 1,
                    userCounts: ["555": 1]
                )
            ],
            isE2EE: false
        )
        engine.messages["g900"] = [groupMsg]

        let detailGroup = try #require(await engine.reactors(for: "8200", in: "g900"))
        #expect(detailGroup.users.count == 1)
        #expect(detailGroup.users.first?.uid == "555")
        #expect(detailGroup.users.first?.name == "Hùng")
        #expect(detailGroup.users.first?.avatar?.absoluteString == "https://ava.example/555.jpg")
        #expect(engine.messages["g900"]?.first?.reactions.first?.names == ["Hùng"])
    }
}

@Suite struct BatchMergeTests {
    private func msg(_ id: String, _ ts: TimeInterval, clientId: String = "") -> ChatMessage {
        ChatMessage(id: id, conversationId: "300", senderId: "300", senderName: "Lan", senderAvatar: nil, isMine: false,
                    kind: .text, text: id, date: Date(timeIntervalSince1970: ts), status: .sent, quote: nil, reactions: [],
                    isE2EE: false, clientId: clientId)
    }

    /// A jump to an old pin merges thousands of rows in one write: sorted, no duplicates, rows already shown kept.
    @Test @MainActor func batchMergeSortsAndSkipsKnownRows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-batch-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = ZaloEngine(dataDirectory: root, useKeychain: false)

        engine.messages["300"] = [msg("9000", 9000, clientId: "c9000")]
        var rows: [(message: ChatMessage, clientId: String?)] = (0..<3000).reversed().map { i in
            (message: msg(String(1000 + i), TimeInterval(1000 + i)), clientId: nil)
        }
        rows.append((message: msg("9000", 9000, clientId: "c9000"), clientId: "c9000"))
        engine.mergeMessagesIntoMemory(rows, in: "300")

        let list = try #require(engine.messages["300"])
        #expect(list.count == 3001)
        #expect(list.first?.id == "1000")
        #expect(list.last?.id == "9000")
        #expect(zip(list, list.dropFirst()).allSatisfy { $0.date <= $1.date })
    }
}
