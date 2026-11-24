import Foundation
import os
import Testing
@testable import Olaz

@Suite struct GroupMgmtPayloadAndAPITests {
    @Test func payloadBuildersMatchWireSpecsAndSanitizeInputs() throws {
        let imei = "test-imei-123"

        // 1. upavatar
        let avatarSpec = try #require(
            ZaloSessionClient.buildUploadGroupAvatarRequest(groupId: "g998877", side: 512, clientId: 170000123, imei: imei)
        )
        #expect(avatarSpec.service == "file")
        #expect(avatarSpec.path == "/api/group/upavatar")
        #expect(avatarSpec.fieldName == "fileContent")
        #expect(avatarSpec.fileName == "avatar.jpg")
        #expect(avatarSpec.mimeType == "image/jpeg")
        #expect(avatarSpec.encryptedPayload["grid"] as? String == "998877")
        #expect(avatarSpec.encryptedPayload["avatarSize"] as? Int == 512)
        #expect(avatarSpec.encryptedPayload["clientId"] as? Int64 == 170000123)
        #expect(avatarSpec.encryptedPayload["originWidth"] as? Int == 512)
        #expect(avatarSpec.encryptedPayload["originHeight"] as? Int == 512)
        #expect(avatarSpec.encryptedPayload["imei"] as? String == imei)
        #expect(ZaloSessionClient.buildUploadGroupAvatarRequest(groupId: "g0", side: 512, clientId: 1, imei: imei) == nil)
        #expect(ZaloSessionClient.buildUploadGroupAvatarRequest(groupId: "g123", side: 0, clientId: 1, imei: imei) == nil)

        // 2. updateinfo
        let renameSpec = try #require(
            ZaloSessionClient.buildRenameGroupRequest(groupId: "group_554433", name: "Team Olaz", imei: imei)
        )
        #expect(renameSpec.service == "group")
        #expect(renameSpec.path == "/api/group/updateinfo")
        #expect(renameSpec.payload["grid"] as? String == "554433")
        #expect(renameSpec.payload["gname"] as? String == "Team Olaz")
        #expect(renameSpec.payload["imei"] as? String == imei)
        #expect(ZaloSessionClient.buildRenameGroupRequest(groupId: "", name: "X", imei: imei) == nil)

        // 3. invite/v2
        let inviteSpec = try #require(
            ZaloSessionClient.buildInviteGroupMembersRequest(
                groupId: "g1122",
                memberIds: ["u101", " 202 ", "101", "", "0", "303"],
                imei: imei
            )
        )
        #expect(inviteSpec.service == "group")
        #expect(inviteSpec.path == "/api/group/invite/v2")
        #expect(inviteSpec.payload["grid"] as? String == "1122")
        #expect(inviteSpec.payload["members"] as? [String] == ["101", "202", "303"])
        #expect(inviteSpec.payload["memberTypes"] as? [Int] == [-1, -1, -1])
        #expect(inviteSpec.payload["imei"] as? String == imei)
        #expect(inviteSpec.payload["clientLang"] as? String == "vi")
        #expect(ZaloSessionClient.buildInviteGroupMembersRequest(groupId: "g1122", memberIds: ["", "0"], imei: imei) == nil)

        // 4. kickout
        let kickSpec = try #require(
            ZaloSessionClient.buildKickGroupMembersRequest(groupId: "1122", memberIds: ["u404", "404", "505"], imei: imei)
        )
        #expect(kickSpec.service == "group")
        #expect(kickSpec.path == "/api/group/kickout")
        #expect(kickSpec.payload["grid"] as? String == "1122")
        #expect(kickSpec.payload["members"] as? [String] == ["404", "505"])
        #expect(kickSpec.payload["imei"] as? String == imei)
        #expect(ZaloSessionClient.buildKickGroupMembersRequest(groupId: "0", memberIds: ["404"], imei: imei) == nil)

        // 5. leave
        let leaveLoudSpec = try #require(
            ZaloSessionClient.buildLeaveGroupRequest(groupId: "g7788", silent: false, imei: imei)
        )
        #expect(leaveLoudSpec.service == "group")
        #expect(leaveLoudSpec.path == "/api/group/leave")
        #expect(leaveLoudSpec.payload["grids"] as? [String] == ["7788"])
        #expect(leaveLoudSpec.payload["imei"] as? String == imei)
        #expect(leaveLoudSpec.payload["silent"] as? Int == 0)
        #expect(leaveLoudSpec.payload["language"] as? String == "vi")

        let leaveSilentSpec = try #require(
            ZaloSessionClient.buildLeaveGroupRequest(groupId: "g7788", silent: true, imei: imei)
        )
        #expect(leaveSilentSpec.payload["silent"] as? Int == 1)
        #expect(ZaloSessionClient.buildLeaveGroupRequest(groupId: "g0", silent: false, imei: imei) == nil)
    }

    @Test func networkMethodsSendExpectedEncryptedPayloadsAndMultipartAvatar() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-grpmgmt-http-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let key = Data("0123456789abcdef".utf8)
        struct RecordedCall: Sendable {
            let path: String
            let payload: ZaloJSONBox
            let contentType: String
            let body: Data
        }
        let recorded = OSAllocatedUnfairLock<[RecordedCall]>(initialState: [])

        let server = try FakeZaloServer { req in
            let box = ZaloJSONBox(req.decodeEncryptedParams(key: key) ?? [:])
            let contentType = req.header("content-type") ?? ""
            recorded.withLock {
                $0.append(RecordedCall(path: req.path, payload: box, contentType: contentType, body: req.body))
            }
            return .json(200, ["error_code": 0, "data": ["ok": true]])
        }
        try await server.start()
        defer { server.stop() }

        let client = ZaloSessionClient(dataDirectory: root, useKeychain: false)
        let domains = server.domains(for: ["file", "group"])
        var account = ZaloLoginAccount()
        account.userId = "100"
        await client.updateCredentials(account: account, secretKey: key, zpwSek: "sek.1.2", domains: domains)

        let fakeJPEG = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        _ = try await client.uploadGroupAvatarAPI(groupId: "g555", jpegData: fakeJPEG, side: 320)
        _ = try await client.renameGroupAPI(groupId: "g555", name: "Nhóm Mới")
        _ = try await client.inviteGroupMembersAPI(groupId: "g555", memberIds: ["201", "202"])
        _ = try await client.kickGroupMembersAPI(groupId: "g555", memberIds: ["202"])
        _ = try await client.leaveGroupAPI(groupId: "g555", silent: true)

        let calls = recorded.withLock { $0 }
        #expect(calls.count == 5)

        // upavatar multipart
        #expect(calls[0].path == "/api/group/upavatar")
        #expect(calls[0].contentType.hasPrefix("multipart/form-data; boundary="))
        #expect(JSONLossless.string(calls[0].payload.dict["grid"]) == "555")
        #expect(JSONLossless.int64(calls[0].payload.dict["avatarSize"]) == 320)
        #expect(JSONLossless.int64(calls[0].payload.dict["originWidth"]) == 320)
        #expect(JSONLossless.int64(calls[0].payload.dict["originHeight"]) == 320)
        let multipartText = String(decoding: calls[0].body, as: UTF8.self)
        #expect(multipartText.contains(#"name="fileContent"; filename="avatar.jpg""#))
        #expect(multipartText.contains("Content-Type: image/jpeg"))
        #expect(calls[0].body.range(of: fakeJPEG) != nil)

        // updateinfo
        #expect(calls[1].path == "/api/group/updateinfo")
        #expect(JSONLossless.string(calls[1].payload.dict["grid"]) == "555")
        #expect(JSONLossless.string(calls[1].payload.dict["gname"]) == "Nhóm Mới")

        // invite/v2
        #expect(calls[2].path == "/api/group/invite/v2")
        #expect(JSONLossless.string(calls[2].payload.dict["grid"]) == "555")
        #expect(calls[2].payload.dict["members"] as? [String] == ["201", "202"])
        #expect(calls[2].payload.dict["memberTypes"] as? [Int] == [-1, -1])
        #expect(JSONLossless.string(calls[2].payload.dict["clientLang"]) == "vi")

        // kickout
        #expect(calls[3].path == "/api/group/kickout")
        #expect(JSONLossless.string(calls[3].payload.dict["grid"]) == "555")
        #expect(calls[3].payload.dict["members"] as? [String] == ["202"])

        // leave
        #expect(calls[4].path == "/api/group/leave")
        #expect(calls[4].payload.dict["grids"] as? [String] == ["555"])
        #expect(JSONLossless.int64(calls[4].payload.dict["silent"]) == 1)
        #expect(JSONLossless.string(calls[4].payload.dict["language"]) == "vi")
    }
}

@Suite struct SQLiteAndEngineSearchTests {
    private func storedText(
        id: String,
        convId: String,
        clientId: String = "",
        text: String,
        tsMs: Int64,
        status: String = "sent",
        kindTag: String = "text",
        rawDict: [String: Any]? = nil
    ) throws -> StoredMessage {
        let canonical: [String: Any] = rawDict ?? [
            "id": id,
            "clientId": clientId,
            "conversationId": convId,
            "senderId": "u1",
            "senderName": "An",
            "senderAvatar": "",
            "isMine": false,
            "kind": ["type": kindTag == "recalled" ? "recalled" : "text"],
            "text": text,
            "date": tsMs,
            "status": status,
            "reactions": [] as [[String: Any]],
            "isE2EE": status == "e2ee_locked",
            "mentions": [] as [[String: Any]],
            "buttons": [] as [[String: Any]],
            "stickers": false,
            "menu": [:] as [String: Any]
        ]
        let rawData = try JSONSerialization.data(withJSONObject: canonical, options: [])
        return StoredMessage(
            id: id,
            convId: convId,
            clientId: clientId,
            senderId: "u1",
            senderName: "An",
            senderAvatar: "",
            isMine: false,
            text: text,
            kindTag: kindTag,
            tsMs: tsMs,
            status: status,
            rawJSONData: rawData
        )
    }

    @Test func sqliteSearchEscapesWildcardsIsCaseInsensitiveScopedAndOrdered() async throws {
        let dbDir = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-sqlite-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dbDir) }
        let store = try ZaloSQLiteStore(path: dbDir.appendingPathComponent("history.sqlite3").path)
        try await store.saveMessages([
            try storedText(id: "m1", convId: "c1", text: "Hello World", tsMs: 1000),
            try storedText(id: "m2", convId: "c1", text: "Đà Nẵng cuối tuần", tsMs: 2000),
            try storedText(id: "m3", convId: "c1", text: "Discount 50% today", tsMs: 3000),
            try storedText(id: "m4", convId: "c1", text: "Discount 500 today", tsMs: 3100),
            try storedText(id: "m5", convId: "c1", text: "file_name_v1 and path\\to\\doc", tsMs: 4000),
            try storedText(id: "m6", convId: "c1", text: "fileXnameXv1", tsMs: 4100),
            try storedText(id: "m7", convId: "c1", text: "", tsMs: 5000, kindTag: "link", rawDict: [
                "id": "m7", "conversationId": "c1", "senderId": "u1", "senderName": "An",
                "isMine": false, "text": "Example", "date": 5000, "status": "sent",
                "kind": ["type": "link", "title": "Example", "url": "https://example.com", "description": "Special Caption Body"]
            ]),
            try storedText(id: "m8", convId: "c1", text: "HELLO again", tsMs: 6000),
            try storedText(id: "m9", convId: "c1", text: "hello recalled", tsMs: 7000, kindTag: "recalled"),
            try storedText(id: "m10", convId: "c1", text: "hello locked", tsMs: 8000, status: "e2ee_locked", kindTag: "placeholder"),
            try storedText(id: "other", convId: "c2", text: "hello from other conv", tsMs: 9000)
        ])

        // 1. Case-insensitive ASCII, newest-first, conversation-scoped, excludes recalled/e2ee_locked
        let helloMatches = try await store.searchMessages(conversationId: "c1", query: "hello", limit: 50)
        #expect(helloMatches.map(\.id) == ["m8", "m1"])

        // 2. Limit enforcement (newest-first preserved)
        let limited = try await store.searchMessages(conversationId: "c1", query: "hello", limit: 1)
        #expect(limited.map(\.id) == ["m8"])

        // 3. Case-insensitive Vietnamese Đ/đ
        let vnMatches = try await store.searchMessages(conversationId: "c1", query: "đà nẵng", limit: 50)
        #expect(vnMatches.map(\.id) == ["m2"])

        // 4. Escapes `%`, `_`, `\`
        let pctMatches = try await store.searchMessages(conversationId: "c1", query: "50%", limit: 50)
        #expect(pctMatches.map(\.id) == ["m3"])

        let underscoreMatches = try await store.searchMessages(conversationId: "c1", query: "file_name", limit: 50)
        #expect(underscoreMatches.map(\.id) == ["m5"])

        let slashMatches = try await store.searchMessages(conversationId: "c1", query: #"path\to"#, limit: 50)
        #expect(slashMatches.map(\.id) == ["m5"])

        // 5. Searches caption/description inside raw_json
        let captionMatches = try await store.searchMessages(conversationId: "c1", query: "caption body", limit: 50)
        #expect(captionMatches.map(\.id) == ["m7"])

        // 6. Searches oaMessage parts & handles malformed raw_json safely
        try await store.saveMessages([
            try storedText(id: "m11", convId: "c1", text: "", tsMs: 6500, kindTag: "oaMessage", rawDict: [
                "id": "m11", "conversationId": "c1", "senderId": "u1", "senderName": "OA",
                "isMine": false, "text": "", "date": 6500, "status": "sent",
                "kind": [
                    "type": "oaMessage",
                    "parts": [["header": true, "title": "Weekly Digest", "description": "Summary inside OA"]]
                ]
            ]),
            StoredMessage(
                id: "m12",
                convId: "c1",
                clientId: "",
                senderId: "u1",
                senderName: "An",
                senderAvatar: "",
                isMine: false,
                text: "Fallback plain body",
                kindTag: "text",
                tsMs: 6600,
                status: "sent",
                rawJSONData: Data("not-valid-json".utf8)
            )
        ])
        let oaMatches = try await store.searchMessages(conversationId: "c1", query: "summary inside oa", limit: 50)
        #expect(oaMatches.map(\.id) == ["m11"])
        let malformedMatches = try await store.searchMessages(conversationId: "c1", query: "fallback plain", limit: 50)
        #expect(malformedMatches.map(\.id) == ["m12"])

        // 7. Blank query returns empty
        #expect((try await store.searchMessages(conversationId: "c1", query: "   ", limit: 50)).isEmpty)
        #expect((try await store.searchMessages(conversationId: "c1", query: "hello", limit: 0)).isEmpty)
    }

    @Test func messageMatchesSearchQueryHandlesAllSupportedKinds() {
        func msg(kind: ChatMessage.Kind, text: String = "", isE2EE: Bool = false) -> ChatMessage {
            ChatMessage(
                id: "1",
                conversationId: "c1",
                senderId: "u1",
                senderName: "An",
                senderAvatar: nil,
                isMine: false,
                kind: kind,
                text: text,
                date: Date(),
                status: .sent,
                quote: nil,
                reactions: [],
                isE2EE: isE2EE,
                mentions: [],
                cardButtons: [],
                suggestsStickers: false
            )
        }

        #expect(ZaloEngine.messageMatchesSearchQuery(msg(kind: .text, text: "Họp nhóm 15h"), query: "họp nhóm"))
        #expect(ZaloEngine.messageMatchesSearchQuery(msg(kind: .file(name: "BaoCao_Q4.pdf", size: 1024, url: nil)), query: "baocao_q4"))
        #expect(ZaloEngine.messageMatchesSearchQuery(msg(kind: .link(title: "Docs", url: nil, thumbnail: nil, description: "API Reference", source: "")), query: "reference"))
        #expect(ZaloEngine.messageMatchesSearchQuery(msg(kind: .location(.init(title: "Cafe", address: "Nguyễn Huệ", coordinate: nil, thumbnail: nil))), query: "nguyễn huệ"))
        #expect(ZaloEngine.messageMatchesSearchQuery(msg(kind: .poll(.init(question: "Ăn trưa đâu?", header: "", anonymous: false, pollId: "p1", conversationId: "c1"))), query: "ăn trưa"))
        #expect(!ZaloEngine.messageMatchesSearchQuery(msg(kind: .recalled, text: "Họp nhóm"), query: "họp"))
        #expect(!ZaloEngine.messageMatchesSearchQuery(msg(kind: .placeholder(symbol: "lock.fill", text: "locked"), text: "Tin nhắn mã hóa", isE2EE: true), query: "mã hóa"))
    }

    @MainActor
    @Test func engineSearchCombinesMemoryAndSQLiteDedupesAndLoadsOlderTargets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-search-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = ZaloEngine(dataDirectory: root, useKeychain: false)
        let store = try ZaloSQLiteStore(path: root.appendingPathComponent("history.sqlite3").path)
        engine.sqliteStore = store

        // Seed 60 messages in SQLite so older hits (ts 1000..3000) are not in the newest 10 loaded in memory.
        var batch: [StoredMessage] = []
        for i in 1...60 {
            let ts = Int64(i * 1000)
            let body = (i == 5 || i == 58) ? "Release target #\(i)" : "Chatter #\(i)"
            batch.append(try storedText(id: "srv_\(i)", convId: "u9", clientId: "cli_\(i)", text: body, tsMs: ts))
        }
        try await store.saveMessages(batch)

        // Load only the newest 5 messages into memory (56..60), plus one unsaved/optimistic match in memory.
        let recent = try await store.messages(convId: "u9", limit: 5).compactMap { ZaloWireParser.decodeStoredMessage($0) }
        var mem = recent
        // Also simulate a message in memory whose ID matches `cli_58` (clientId dedup check!) or `srv_58`
        mem.append(ChatMessage(
            id: "cli_99",
            conversationId: "u9",
            senderId: "me",
            senderName: "Bạn",
            senderAvatar: nil,
            isMine: true,
            kind: .text,
            text: "Release target optimistic",
            date: Date(timeIntervalSince1970: 70),
            status: .sending,
            quote: nil,
            reactions: [],
            isE2EE: false,
            mentions: [],
            cardButtons: [],
            suggestsStickers: false
        ))
        engine.messages["u9"] = mem

        let results = await engine.searchMessages(in: "u9", query: "release target", limit: 50)
        // Expected newest-first: cli_99 (ts 70s), srv_58 (ts 58s), srv_5 (ts 5s)
        #expect(results.map(\.id) == ["cli_99", "srv_58", "srv_5"])

        // Also test clientId dedup when memory has `cli_58` instead of `srv_58`
        var memWithCli = mem.filter { $0.id != "srv_58" }
        memWithCli.append(ChatMessage(
            id: "cli_58",
            conversationId: "u9",
            senderId: "me",
            senderName: "Bạn",
            senderAvatar: nil,
            isMine: true,
            kind: .text,
            text: "Release target #58",
            date: Date(timeIntervalSince1970: 58),
            status: .sent,
            quote: nil,
            reactions: [],
            isE2EE: false,
            mentions: [],
            cardButtons: [],
            suggestsStickers: false
        ))
        engine.messages["u9"] = memWithCli
        let deduped = await engine.searchMessages(in: "u9", query: "release target", limit: 50)
        #expect(deduped.map(\.id) == ["cli_99", "cli_58", "srv_5"])

        // Reset memory to newest 5 (`srv_56`..`srv_60`) and ensure older `srv_5` is loaded on jump!
        engine.messages["u9"] = recent
        #expect(engine.messages["u9"]?.contains(where: { $0.id == "srv_5" }) == false)
        let olderMatch = try #require(results.last(where: { $0.id == "srv_5" }))
        let loaded = await engine.ensureMessageLoaded(olderMatch, in: "u9")
        #expect(loaded == true)
        #expect(engine.messages["u9"]?.contains(where: { $0.id == "srv_5" }) == true)
        // Surrounding context earlier than srv_5 (`srv_1`..`srv_4`) and up to newest (`srv_60`) are present
        #expect(engine.messages["u9"]?.contains(where: { $0.id == "srv_1" }) == true)
        #expect(engine.messages["u9"]?.contains(where: { $0.id == "srv_60" }) == true)
    }

    @MainActor
    @Test func engineGroupKickSelfGuardAndMemberIdExtraction() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-grpguard-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = ZaloEngine(dataDirectory: root, useKeychain: false)
        // Inject cached group details & verify member extraction
        engine.cachedGroupDetails["777"] = [
            "memVerList": ["100_0", "200_1", "300_2"]
        ]
        #expect(engine.groupMemberIds(in: "g777") == ["100", "200", "300"])

        // Attempting to kick empty/invalid group or member returns false cleanly
        #expect(await engine.kickMember("", from: "g777") == false)
        #expect(await engine.kickMember("200", from: "") == false)
        #expect(await engine.renameGroup("g777", to: "   ") == false)
        #expect(await engine.inviteMembers([], to: "g777") == false)
        #expect(await engine.leaveGroup("") == false)
    }
}
