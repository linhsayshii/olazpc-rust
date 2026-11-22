import Compression
import CryptoKit
import Foundation
import os
import Testing
@testable import Olaz

@Suite struct NativeCryptoTests {
    @Test func signKeyDeterminismAndSorting() {
        let p1 = ["b": "2", "a": "1", "imei": "abc"]
        let p2 = ["imei": "abc", "a": "1", "b": "2"]
        let k1 = ZaloCrypto.signKey(tag: "reqqr", params: p1)
        let k2 = ZaloCrypto.signKey(tag: "reqqr", params: p2)
        #expect(k1 == k2)
        #expect(k1.count == 32)
        // MD5("zsecure" + "reqqr" + "1" + "2" + "abc")
        #expect(k1 == ZaloCrypto.md5Hex("zsecurereqqr12abc"))
    }

    @Test func paramCipherAndAESCBCRoundTrip() throws {
        let imei = ZaloSessionClient.generateIMEI()
        #expect(imei.count == 69)
        let cipher = try ZaloCrypto.ParamCipher(apiType: "30", imei: imei, firstLaunchTimeMs: 1_700_000_000_000)
        let signed = try cipher.buildSignedParams(
            apiType: "30",
            clientVersion: ZaloDomains.zpwVer,
            payload: ["imei": imei, "computer_name": "Mac", "language": "vi"],
            tag: "getlogininfo"
        )
        #expect(signed["zcid"] != nil)
        #expect(signed["zcid_ext"] != nil)
        #expect(signed["enc_ver"] == "v2")
        #expect(signed["params"] != nil)
        #expect(signed["signkey"] == ZaloCrypto.signKey(tag: "getlogininfo", params: signed.filter { $0.key != "signkey" }))

        let rawKey = Data(repeating: 0x42, count: 16)
        let encrypted = try ZaloCrypto.encodeAES(key: rawKey, plaintext: "{\"ok\":true,\"id\":123}")
        let decrypted = try ZaloCrypto.decodeAES(key: rawKey, base64: encrypted)
        #expect(decrypted == "{\"ok\":true,\"id\":123}")
    }

    @Test func parseSecretKeyAndLiveVectorShape() throws {
        let raw16 = Data("0123456789abcdef".utf8)
        let parsedUTF8 = ZaloCrypto.parseSecretKey("0123456789abcdef")
        #expect(parsedUTF8 == raw16)

        let raw32 = Data((0..<32).map { UInt8($0) })
        let parsedB64 = ZaloCrypto.parseSecretKey(raw32.base64EncodedString())
        #expect(parsedB64 == raw32)
    }

    @Test func wsFrameAESGCMAndGzipDecryption() throws {
        let key = Data((0..<32).map { UInt8(($0 * 7) & 0xFF) })
        let iv = Data((0..<16).map { UInt8($0 + 1) })
        let aad = Data((0..<16).map { UInt8($0 + 17) })

        let jsonStr = #"{"error_code":0,"data":{"msgId":9876543210987654321}}"#
        let plainData = Data(jsonStr.utf8)

        // AES-GCM uncompressed encrypt=3 test (`gcmEncrypt16` already prepends `iv` + `aad`)
        let frame3 = try ZaloCrypto.gcmEncrypt16(key: key, plaintext: plainData, iv: iv, aad: aad)
        let b64Percent3 = frame3.base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let out3 = try ZaloCrypto.decryptWSFrame(cipherKey: key, encrypt: 3, dataField: b64Percent3)
        #expect(out3 == plainData)

        // Plain zlib encrypt=1 test
        let compressed = try zlibCompress(plainData)
        let out1 = try ZaloCrypto.decryptWSFrame(cipherKey: nil, encrypt: 1, dataField: compressed.base64EncodedString())
        #expect(out1 == plainData)

        // Compressed AES-GCM encrypt=2 test
        let frame2 = try ZaloCrypto.gcmEncrypt16(key: key, plaintext: compressed, iv: iv, aad: aad)
        let out2 = try ZaloCrypto.decryptWSFrame(cipherKey: key, encrypt: 2, dataField: frame2.base64EncodedString())
        #expect(out2 == plainData)
    }

    @Test func jsonLosslessPreserves64BitIntegers() {
        let raw = #"{"msgId":1731849600123456789,"cliMsgId":1731849600987654,"count":42}"#
        let parsed = JSONLossless.parseObject(Data(raw.utf8))
        #expect(JSONLossless.string(parsed?["msgId"]) == "1731849600123456789")
        #expect(JSONLossless.string(parsed?["cliMsgId"]) == "1731849600987654")
        #expect(JSONLossless.int64(parsed?["count"]) == 42)
    }

    @Test func qrPNGGenerationProducesValidPNGHeader() {
        let data = ZaloCrypto.generateQRPNG(payload: "https://zalo.me/qr/test")
        #expect(data != nil)
        #expect((data?.count ?? 0) > 100)
        #expect(data?.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }

    private func zlibCompress(_ source: Data) throws -> Data {
        var out = Data(count: max(64, source.count * 2))
        let count = source.withUnsafeBytes { srcPtr in
            out.withUnsafeMutableBytes { dstPtr in
                compression_encode_buffer(
                    dstPtr.bindMemory(to: UInt8.self).baseAddress!,
                    dstPtr.count,
                    srcPtr.bindMemory(to: UInt8.self).baseAddress!,
                    srcPtr.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard count > 0 else { return source }
        return out.prefix(count)
    }
}

@Suite struct NativeDomainsAndWSTests {
    @Test func serviceCandidateFailoverAndWinnerPromotion() {
        #expect(ZaloDomains.zpwType == "23")
        #expect(ZaloDomains.userAgent == "ZaloPC-darwin-23v694")
        #expect(ZaloDomains.wsOrigin == "file://")

        var domains = ZaloDomains()
        let initial = domains.candidates(for: "chat")
        #expect(initial.first == "https://tt-chat3-wpa.api.zaloapp.com")
        #expect(domains.candidates(for: "group_board").first == "https://groupboard-wpa.api.zaloapp.com")
        #expect(initial.count >= 2)

        domains.rememberWinner(for: "chat", host: "https://tt-chat1-wpa.api.zaloapp.com")
        #expect(domains.candidates(for: "chat").first == "https://tt-chat1-wpa.api.zaloapp.com")

        var custom = ZaloDomains()
        custom.applyServerInfo([
            "zpw_service_map_v3": [
                "chat": ["https://custom-chat.api.zaloapp.com"]
            ],
            "zpw_ws": ["wss://ws1-msg.zaloapp.com"]
        ])
        #expect(custom.candidates(for: "chat").first == "https://custom-chat.api.zaloapp.com")
        #expect(custom.ws.first == "wss://ws1-msg.zaloapp.com")
    }

    @Test func wsFrameCodecURLSlashAndAuthQueues() {
        let encoded = ZaloWebSocket.encodeFrame(cmd: 510, subCmd: 1, version: 1, data: ["first": true])
        let decoded = ZaloWebSocket.decodeFrame(encoded)
        #expect(decoded?.version == 1)
        #expect(decoded?.cmd == 510)
        #expect(decoded?.subCmd == 1)
        #expect((decoded?.envelope["first"] as? Bool) == true)

        let url = ZaloWebSocket.buildSocketURL(base: "wss://ws1-msg.chat.zalo.me", nowMs: 123456)
        #expect(url?.absoluteString.hasPrefix("wss://ws1-msg.chat.zalo.me/?") == true)

        let queues = ZaloWebSocket.queuesFromAuth([
            "data": [
                "ctrl_qCmds": [["cmd": 603, "subCmd": 1], ["cmd": 604, "subCmd": 0]],
                "qCmds": [["cmd": 510, "subCmd": 1], ["cmd": 510, "subCmd": 1], ["cmd": 511, "subCmd": 0]]
            ]
        ])
        #expect(queues.count == 4)
        #expect(queues.contains(ZaloWSQueue(cmd: 603, subCmd: 1)))
        #expect(queues.contains(ZaloWSQueue(cmd: 510, subCmd: 1)))
    }
}

@Suite struct NativeSQLiteAndWireTests {
    @Test func sqliteStoreConversationsMessagesMediaAndPrefs() async throws {
        let store = try ZaloSQLiteStore(path: ":memory:")
        try await store.saveConversations([
            StoredConversation(id: "u1", isGroup: false, name: "An", avatar: "", pinned: false, members: 0, unread: 2, previewText: "Hi", previewTsMs: 1000, previewFromMe: false, updatedAtMs: 1000),
            StoredConversation(id: "g2", isGroup: true, name: "Team", avatar: "", pinned: true, members: 5, unread: 0, previewText: "Yo", previewTsMs: 500, previewFromMe: true, updatedAtMs: 500)
        ])
        let convs = try await store.loadConversations()
        #expect(convs.map(\.id) == ["g2", "u1"])

        let ev1 = ZaloWireParser.parseWireMessage([
            "msgId": "101", "cliMsgId": "c1", "uidFrom": "u1", "idTo": "me", "msgType": "webchat",
            "content": "Tin 1", "ts": 1000
        ], myUid: "me")
        let ev2 = ZaloWireParser.parseWireMessage([
            "msgId": "102", "cliMsgId": "c2", "uidFrom": "me", "idTo": "u1", "msgType": "chat.photo",
            "content": ["hd": "https://cdn.example/p.jpg", "title": "Anh"], "ts": 2000
        ], myUid: "me")
        let ev3 = ZaloWireParser.parseWireMessage([
            "msgId": "103", "cliMsgId": "c3", "uidFrom": "u1", "idTo": "me", "msgType": "chat.recommended",
            "content": ["action": "recommened.link", "href": "https://example.com", "title": "Example"], "ts": 3000
        ], myUid: "me")

        guard case .message(_, let s1) = ev1,
              case .message(_, let s2) = ev2,
              case .message(_, let s3) = ev3 else {
            Issue.record("Expected parsed messages")
            return
        }
        try await store.saveMessages([s1, s2, s3])

        let latestTwo = try await store.messages(convId: "u1", limit: 2)
        #expect(latestTwo.map(\.id) == ["102", "103"])

        let older = try await store.messages(convId: "u1", beforeTsMs: 2_000_000, limit: 5)
        #expect(older.map(\.id) == ["101"])

        let imgMedia = try await store.sharedMediaRaw(convId: "u1", kindTags: ["photo", "video"], afterCursor: nil, limit: 10)
        #expect(imgMedia.rows.count == 1)

        try await store.markRecalled(convId: "u1", id: "101")
        let recalled = try await store.message(convId: "u1", idOrClientId: "101")
        #expect(recalled?.kindTag == "recalled")

        try await store.deleteMessage(convId: "u1", id: "103")
        let remaining = try await store.messages(convId: "u1", limit: 10)
        #expect(remaining.map(\.id) == ["101", "102"])

        try await store.setPreferenceStrings(key: "pinnedIds", value: ["g2"])
        #expect(try await store.getPreferenceStrings(key: "pinnedIds") == ["g2"])
    }

    @Test func wireParserControlTypesAndRoundTrip() {
        let undo = ZaloWireParser.parseWireMessage([
            "msgType": "chat.undo", "uidFrom": "u9", "idTo": "me",
            "content": ["globalMsgId": "555", "cliMsgId": "c555"]
        ], myUid: "me")
        if case .undo(let conv, let mid, let cid) = undo {
            #expect(conv == "u9" && mid == "555" && cid == "c555")
        } else {
            Issue.record("Expected undo")
        }

        let reaction = ZaloWireParser.parseWireMessage([
            "msgType": "chat.reaction", "uidFrom": "u9", "idTo": "g123",
            "content": ["rType": 5, "rIcon": "/-heart", "rMsg": [["gMsgID": "777", "cMsgID": "c777"]]]
        ], myUid: "me", cmd: ZaloWebSocket.cmdPushMsgGroup)
        if case .reaction(let conv, let mid, _, _, let rType, _) = reaction {
            #expect(conv == "g123" && mid == "777" && rType == "5")
        } else {
            Issue.record("Expected reaction")
        }

        // Self-cloud push arriving over `cmdPushMsgGroup` must route to `selfConvId` (`217477...`), never `"g217477..."`.
        let selfCloudPush = ZaloWireParser.parseWireMessage([
            "msgId": "888", "cliMsgId": "c888", "uidFrom": "me", "idTo": "2174771368031376212",
            "msgType": "share.file", "content": ["title": "probe.txt", "href": "https://cdn.example/probe.txt"], "ts": 4000
        ], myUid: "me", cmd: ZaloWebSocket.cmdPushMsgGroup, selfConvId: "2174771368031376212")
        if case .message(let msg, _) = selfCloudPush {
            #expect(msg.conversationId == "2174771368031376212")
            #expect(msg.isMine)
        } else {
            Issue.record("Expected self-cloud message")
        }
    }

    @MainActor
    @Test func engineInitIsSideEffectFreeAndListOrderWorks() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-engine-test-\(UUID())")
        let engine = ZaloEngine(dataDirectory: dir, useKeychain: false)
        #expect(engine.phase == .starting)
        #expect(engine.conversations.isEmpty)
        #expect(engine.clientVersion == "694 (Native)")
        #expect(!engine.isInCall)

        let a = ZaloEngine.ConversationSummary(id: "u1", isGroup: false, name: "A", avatar: nil, pinned: false, members: 0, unread: 0,
                                               preview: .init(text: "hi", date: Date(timeIntervalSince1970: 200), fromMe: false))
        let b = ZaloEngine.ConversationSummary(id: "u2", isGroup: false, name: "B", avatar: nil, pinned: true, members: 0, unread: 0,
                                               preview: .init(text: "old", date: Date(timeIntervalSince1970: 100), fromMe: false))
        #expect(ZaloEngine.listOrder([a, b]).map(\.id) == ["u2", "u1"])

        // Verify `cachedActivityRanks` orders active un-previewed threads chronologically, and `rebuildConversationExtras` collapses strangers into `stranger_box`.
        engine.contacts.friendsLoaded = true
        engine.contacts.friends = [.init(id: "f1", name: "Friend 1", zaloName: "Friend 1", avatar: nil, lastActive: nil, online: false, section: "F", sortKey: "friend 1")]
        engine.cachedActivityRanks = ["s1": 900, "f1": 500, "s2": 300]
        engine.ensureKnownContactsInConversations()
        engine.rebuildConversationExtras()
        #expect(engine.conversationExtras.strangerFolderIds == ["s1", "s2"])
        #expect(engine.conversationExtras.listIds == [ConversationExtras.strangerBoxId, "f1"])
    }

    @Test func domainHealAndNestedStringDataDecryption() throws {
        var domains = ZaloDomains()
        domains.rememberWinner(for: "chat", host: "https://tt-chat3-wpa.chat.zalo.me")
        domains.rememberWinner(for: "group_board", host: "https://groupboard-wpa.api.zaloapp.com")
        domains.healFromVerified()
        #expect(domains.preferredHosts["chat"] == nil)
        #expect(domains.preferredHosts["group_board"] == "https://groupboard-wpa.api.zaloapp.com")

        let key = Data("0123456789abcdef".utf8)
        let inner = #"{"error_code":0,"data":"{\"groupMsgs\":[{\"msgId\":\"10\"}]}"}"#
        let enc = try ZaloCrypto.encodeAES(key: key, plaintext: inner)
        let unwrapped = ZaloSessionClient.unwrapDecryptedResponse(["error_code": 0, "data": enc], key: key)
        let dataDict = unwrapped["data"] as? [String: Any]
        let groupMsgs = dataDict?["groupMsgs"] as? [[String: Any]]
        #expect(groupMsgs?.count == 1)
    }

    @Test func pollStateEncodesAndIgnoresSocketQueue15() {
        var state = ZaloPollState()
        let initial = state.encodedParams()
        #expect(initial.hasPrefix("1,1,"))
        let res = state.applyResponse([
            "lastActionId": "42",
            "lastActionIdOther": "43",
            "more": 1,
            "queueStatus": [
                "1": ["lastId": "100", "ids": ["a"]],
                "15": ["lastId": "999", "ids": ["skip"]]
            ]
        ])
        #expect(res.more == true)
        #expect(state.lastActionId == "42")
        #expect(state.queues["1"]?.lastId == "100")
        #expect(state.queues["15"] == nil)
    }

    @Test func wsExtractFileDoneControls() {
        let events = ZaloWebSocket.extractFileDoneEvents([
            "data": [
                "controls": [
                    ["content": ["act_type": "file_done", "data": ["fileId": "987654", "url": "https://cdn.example/f.pdf"]]]
                ]
            ]
        ])
        #expect(events.count == 1)
        #expect(events.first?.fileId == "987654")
        #expect(events.first?.url == "https://cdn.example/f.pdf")
    }

    @Test func extractBatchEventsCloudRoutingIntTypesContactCardsAndReactions() {
        // 1. 0->0 Cloud routing + integer msgTypes (text=1, sticker=5, undo=31)
        let events = ZaloWireParser.extractBatchEvents([
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
                        ["msgId": "204", "uidFrom": "peer1", "idTo": "0", "msgType": 31, "content": ["globalMsgId": "202"], "ts": 4000]
                    ]
                ]
            ]
        ], myUid: "me123", selfConvId: "cloud999")

        #expect(events.count == 4)
        var seenCloudText = false
        var seenSticker = false
        var seenContactCard = false
        var seenUndo = false
        for ev in events {
            switch ev {
            case .message(let msg, _):
                if msg.id == "201" {
                    seenCloudText = (msg.conversationId == "cloud999" && msg.isMine && msg.text == "Cloud note")
                } else if msg.id == "202" {
                    if case .sticker(let u) = msg.kind {
                        seenSticker = u?.absoluteString == "https://stc-chat.zdn.vn/images/stickers/default/thumb/3.png"
                    }
                } else if msg.id == "203" {
                    if case .contactCard(let card) = msg.kind {
                        seenContactCard = (card.uid == "777888" && card.name == "Nguyen Van B")
                    }
                }
            case .undo(_, let mid, _):
                if mid == "202" { seenUndo = true }
            default:
                break
            }
        }
        #expect(seenCloudText)
        #expect(seenSticker)
        #expect(seenContactCard)
        #expect(seenUndo)

        // Live reactGroups dict extraction
        let reactEvents = ZaloWireParser.extractBatchEvents([
            "data": [
                "reactGroups": [
                    ["uidFrom": "peer2", "idTo": "999", "content": ["rIcon": "/-heart", "rType": 5, "rMsg": [["gMsgID": "300", "cMsgID": "300"]]]]
                ]
            ]
        ], myUid: "me123", selfConvId: "cloud999")
        #expect(reactEvents.count == 1)
        if case .reaction(let c, let mid, _, let sender, let rType, _) = reactEvents.first! {
            #expect(c == "g999" && mid == "300" && sender == "peer2" && rType == "5")
        }

        // Profiles dict extraction
        let profiles = ZaloWireParser.extractProfilesMap([
            "data": [
                "profiles": [
                    "111": ["userId": "111", "displayName": "Alice"],
                    "222": ["uid": "222", "zaloName": "Bob"]
                ]
            ]
        ])
        #expect(profiles["111"]?["displayName"] as? String == "Alice")
        #expect(profiles["222"]?["zaloName"] as? String == "Bob")
    }

    @MainActor
    @Test func openConversationInitializesEmptyMessagesAndUpdatesExtras() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-openconv-test-\(UUID())")
        let engine = ZaloEngine(dataDirectory: dir, useKeychain: false)
        engine.openConversation("conv_1")
        #expect(engine.messages["conv_1"] != nil)

        let msg = ChatMessage(
            id: "m1", conversationId: "conv_1", senderId: "u1", senderName: "Test",
            senderAvatar: nil, isMine: false, kind: .text, text: "Hello",
            date: Date(), status: .sent, quote: nil, reactions: [],
            isE2EE: false, mentions: [], cardButtons: [], suggestsStickers: false,
            menu: MessageMenu(json: [:])
        )
        engine.updateConversationOnMessage(msg, incrementUnread: true)
        #expect(engine.conversationExtras.loaded)
        #expect(engine.conversationExtras.listIds.contains("conv_1"))
    }
}

@Suite struct PhoneSyncAndAuthFixTests {
    @Test func extractZpwSekRejectsWpskVapidKeyAndAcceptsRealSek() {
        let vapidLike = String(repeating: "B", count: 87)
        let badResp: [String: Any] = [
            "error_code": 0,
            "data": [
                "zpw_wpsk": vapidLike,
                "zpw_enk": "abcd1234abcd1234",
                "zpw_kt": "some_kt_token",
                "token": "unrelated_token",
            ]
        ]
        #expect(ZaloSessionClient.extractZpwSek(from: badResp) == nil)
        #expect(!ZaloSessionClient.isValidZpwSek(vapidLike))
        #expect(!ZaloSessionClient.isValidZpwSek("EXPIRED"))
        #expect(!ZaloSessionClient.isValidZpwSek(""))

        let goodResp: [String: Any] = [
            "error_code": 0,
            "data": [
                "zpw_wpsk": vapidLike,
                "zpw_sek": "abcd.123456.a0.xyz789"
            ]
        ]
        #expect(ZaloSessionClient.extractZpwSek(from: goodResp) == "abcd.123456.a0.xyz789")
    }

    @Test func extractZpwSekCookieHandlesExpiresCommaAndSkipsMaxAgeZero() {
        let authURL = URL(string: "https://wpa.chat.zalo.me/api/login/getLoginInfo")!
        let onlyExpiredHeaders = [
            "Set-Cookie": "zpw_sek=; Domain=.zalo.me; Path=/; Expires=Thu, 01-Jan-1970 00:00:01 GMT; Max-Age=0, zpw_sek=; Domain=.chat.zalo.me; Path=/; Expires=Thu, 01-Jan-1970 00:00:01 GMT; Max-Age=0"
        ]
        #expect(ZaloSessionClient.extractZpwSekCookie(headers: onlyExpiredHeaders, url: authURL) == nil)

        let mixedHeaders = [
            "Set-Cookie": "zpw_sek=; Domain=.zalo.me; Path=/; Expires=Thu, 01-Jan-1970 00:00:01 GMT; Max-Age=0, zpw_sek=hdr.999999.a0.validToken; Domain=.zalo.me; Path=/; HttpOnly"
        ]
        #expect(ZaloSessionClient.extractZpwSekCookie(headers: mixedHeaders, url: authURL) == "hdr.999999.a0.validToken")
    }

    private func encodeVarint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var b = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
        } while v != 0
        return out
    }

    private func encodeFieldBytes(fieldNum: UInt64, data: [UInt8]) -> [UInt8] {
        var out = encodeVarint((fieldNum << 3) | 2)
        out.append(contentsOf: encodeVarint(UInt64(data.count)))
        out.append(contentsOf: data)
        return out
    }

    private func encodeFieldVarint(fieldNum: UInt64, value: UInt64) -> [UInt8] {
        var out = encodeVarint((fieldNum << 3) | 0)
        out.append(contentsOf: encodeVarint(value))
        return out
    }

    private func buildSampleSyncChunk(
        partitionId: String,
        messages: [(sender: String, clientId: UInt64, msgType: UInt64, ts: UInt64, globalId: UInt64, content: String, metaBytes: [UInt8])]
    ) -> Data {
        var partBytes = encodeFieldBytes(fieldNum: 1, data: Array(partitionId.utf8))
        for m in messages {
            var msgBytes: [UInt8] = []
            msgBytes.append(contentsOf: encodeFieldBytes(fieldNum: 1, data: Array(m.sender.utf8)))
            msgBytes.append(contentsOf: encodeFieldVarint(fieldNum: 2, value: m.clientId))
            msgBytes.append(contentsOf: encodeFieldVarint(fieldNum: 3, value: 1))
            msgBytes.append(contentsOf: encodeFieldVarint(fieldNum: 4, value: m.msgType))
            msgBytes.append(contentsOf: encodeFieldVarint(fieldNum: 5, value: m.ts))
            msgBytes.append(contentsOf: encodeFieldVarint(fieldNum: 6, value: m.globalId))
            msgBytes.append(contentsOf: encodeFieldBytes(fieldNum: 7, data: Array(m.content.utf8)))
            if !m.metaBytes.isEmpty {
                msgBytes.append(contentsOf: encodeFieldBytes(fieldNum: 8, data: m.metaBytes))
            }
            partBytes.append(contentsOf: encodeFieldBytes(fieldNum: 2, data: msgBytes))
        }
        return Data(encodeFieldBytes(fieldNum: 2, data: partBytes))
    }

    @Test func zstdDecompressorAndProtobufSyncChunkRoundTrip() {
        // Build rich MetaData with Attach (photo) + Quote
        var attachBytes: [UInt8] = []
        attachBytes.append(contentsOf: encodeFieldBytes(fieldNum: 5, data: Array("Ảnh kỷ niệm".utf8)))
        attachBytes.append(contentsOf: encodeFieldBytes(fieldNum: 6, data: Array("https://cdn.example/photo.jpg".utf8)))
        var quoteBytes: [UInt8] = []
        quoteBytes.append(contentsOf: encodeFieldBytes(fieldNum: 2, data: Array("G_PARTNER".utf8)))
        quoteBytes.append(contentsOf: encodeFieldBytes(fieldNum: 4, data: Array("Bạn A".utf8)))
        quoteBytes.append(contentsOf: encodeFieldVarint(fieldNum: 6, value: 5001))
        quoteBytes.append(contentsOf: encodeFieldBytes(fieldNum: 7, data: Array("xin chao".utf8)))
        var metaBytes: [UInt8] = []
        metaBytes.append(contentsOf: encodeFieldBytes(fieldNum: 1, data: attachBytes))
        metaBytes.append(contentsOf: encodeFieldBytes(fieldNum: 4, data: quoteBytes))

        let chunkData = buildSampleSyncChunk(
            partitionId: "oneone/G_PARTNER",
            messages: [
                ("G_PARTNER", 101, 0, 1_700_000_001_000, 5001, "xin chao", []),
                ("G_ME", 102, 3, 1_700_000_002_000, 5002, "", metaBytes),
            ]
        )

        let parsedPlain = ZaloSyncProtobufParser.parseSyncChunk(chunkData)
        #expect(parsedPlain.count == 1)
        #expect(parsedPlain.first?.id == "oneone/G_PARTNER")
        #expect(parsedPlain.first?.messages.count == 2)
        #expect(parsedPlain.first?.messages[0].globalId == "5001")
        #expect(parsedPlain.first?.messages[0].content == "xin chao")
        #expect(parsedPlain.first?.messages[1].globalId == "5002")
        #expect(parsedPlain.first?.messages[1].metaData?.attaches.first?.href == "https://cdn.example/photo.jpg")
        #expect(parsedPlain.first?.messages[1].metaData?.quote?.msg == "xin chao")

        if let photoProto = parsedPlain.first?.messages[1],
           let (builtMsg, _) = ZaloSyncProtobufParser.buildChatMessage(
               from: photoProto,
               convId: "111",
               senderUid: "999",
               senderName: "Tôi",
               senderAvatar: nil,
               isMine: true,
               myUid: "999",
               globalIdToUserId: ["G_PARTNER": "111"]
           ) {
            #expect(builtMsg.id == "5002")
            #expect(builtMsg.quote?.text == "xin chao")
            if case .photo(let u, _, _) = builtMsg.kind {
                #expect(u?.absoluteString == "https://cdn.example/photo.jpg")
            } else {
                Issue.record("Expected photo kind from MetaData.Attach")
            }
        } else {
            Issue.record("Failed to build rich synced photo message")
        }

        // Also verify `proto.Sync2.Conversation.SyncChunk` parsing (`CONV_TYPE_ONEONE=1`, `CONV_TYPE_GROUP=2`)
        var conv1: [UInt8] = []
        conv1.append(contentsOf: encodeFieldBytes(fieldNum: 1, data: Array("G_PARTNER".utf8)))
        conv1.append(contentsOf: encodeFieldVarint(fieldNum: 2, value: 1))
        conv1.append(contentsOf: encodeFieldVarint(fieldNum: 3, value: 1))
        conv1.append(contentsOf: encodeFieldVarint(fieldNum: 4, value: 1_700_000_005_000))
        conv1.append(contentsOf: encodeFieldVarint(fieldNum: 5, value: 5002))
        var conv2: [UInt8] = []
        conv2.append(contentsOf: encodeFieldBytes(fieldNum: 1, data: Array("G_GROUP_1".utf8)))
        conv2.append(contentsOf: encodeFieldVarint(fieldNum: 2, value: 2))
        conv2.append(contentsOf: encodeFieldVarint(fieldNum: 4, value: 1_700_000_009_000))
        let convChunk = Data(encodeFieldBytes(fieldNum: 2, data: conv1) + encodeFieldBytes(fieldNum: 2, data: conv2))
        let parsedConvs = ZaloSyncProtobufParser.parseConversationSyncChunk(convChunk)
        #expect(parsedConvs.count == 2)
        #expect(parsedConvs[0].globalId == "G_PARTNER" && !parsedConvs[0].isGroup && parsedConvs[0].lastGlobalId == "5002")
        #expect(parsedConvs[1].globalId == "G_GROUP_1" && parsedConvs[1].isGroup)

        // If `zstd` CLI is installed, verify real Zstandard compression -> ZstdDecompressor -> protobuf parse round-trip.
        let zstdCandidates = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
        if let zstdBin = zstdCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: zstdBin)
            p.arguments = ["-c", "-q"]
            let inP = Pipe()
            let outP = Pipe()
            p.standardInput = inP
            p.standardOutput = outP
            if (try? p.run()) != nil {
                inP.fileHandleForWriting.write(chunkData)
                try? inP.fileHandleForWriting.close()
                let compressed = outP.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                #expect(ZstdDecompressor.hasZstdMagic(compressed))
                let restored = ZstdDecompressor.decompressIfNeeded(compressed)
                #expect(restored == chunkData)
            }
        }
    }

    @Test func zprotoWasmKeysAndMetadataMessageRoundTripInJSRuntime() async throws {
        guard let wasmData = AsarWasmReader.loadZprotoWasm() else {
            return
        }
        let coordinator = ZaloPhoneSyncCoordinator()
        let ok = await coordinator.prepareWasm()
        #expect(ok)

        let convReg = try await coordinator.registerConversationRequest(deviceName: "TestMac", ussidx: 0)
        let chunk = [PlannedSyncPartition(partition: "oneone/G_PEER", convId: "111", isGroup: false, globalId: "G_PEER")]
        let reg = try await coordinator.registerChunkRequest(
            chunk: chunk,
            globalIdToUserId: ["G_PEER": "111"],
            deviceName: "TestMac",
            ussidx: 1
        )
        // Verify `ik` is reused across `ussidx = 0` and `ussidx = 1` while `ek` rotates!
        #expect((convReg.innerData.dict["ik"] as? String) == (reg.innerData.dict["ik"] as? String))
        #expect((convReg.innerData.dict["ek"] as? String) != (reg.innerData.dict["ek"] as? String))
        #expect(await coordinator.hasActiveRequest(syncId: reg.syncId))
        #expect(!(await coordinator.hasActiveRequest(syncId: "stale_old_sync_id")))

        let keys = try await coordinator.generateKeyPairForTesting()
        #expect(keys.ikPub.count == 33)
        let ekPubRaw = try #require(Data(base64Encoded: keys.ekPubB64))
        #expect(ekPubRaw.count == 33)
        #expect(ekPubRaw.first == 0x05)
        #expect(keys.ikPub.first == 0x05)
        #expect(keys.ikPubB64.hasPrefix("B"))

        let ikB64 = try #require(reg.innerData.dict["ik"] as? String)
        let ekB64 = try #require(reg.innerData.dict["ek"] as? String)
        let ikPubData = try #require(Data(base64Encoded: ikB64))
        let ekPubData = try #require(Data(base64Encoded: ekB64))
        #expect(ikPubData.count == 33 && ekPubData.count == 33)

        let metaPlain = buildSampleSyncChunk(
            partitionId: "oneone/G_PEER",
            messages: [("G_PEER", 1, 0, 1_700_000_010_000, 9001, "chao ban", [])]
        )
        let msgPlain = buildSampleSyncChunk(
            partitionId: "oneone/G_PEER",
            messages: [("G_SELF", 2, 0, 1_700_000_011_000, 9002, "chao lai", [])]
        )

        let senderRT = try JSRuntime(name: "test-zproto-sender")
        try await senderRT.loadModule("zalo-zproto-sync.js")
        _ = try await senderRT.callAsync("ZaloZprotoSync.init", [.bytes(wasmData)])
        let packedVal = try await senderRT.callAsync("ZaloZprotoSync.createTestRoundTripBatch", [
            .bytes(ikPubData),
            .bytes(ekPubData),
            .bytes(metaPlain),
            .bytes(msgPlain),
        ])
        let packedBytes = try #require(packedVal.dataValue)
        #expect(packedBytes.count > 16)

        let decrypted = try await coordinator.decryptAndParseBatch(
            syncId: reg.syncId,
            rawBytes: packedBytes,
            url: "https://example.invalid/batch",
            idx: 0,
            isLast: true,
            myUid: "999"
        )
        #expect(decrypted.metaRecords == 1)
        #expect(decrypted.messageRecords == 1)
        #expect(decrypted.failedRecords == 0)
        #expect(decrypted.parsedMessages.count == 2)
        #expect(decrypted.parsedMessages[0].convId == "111")
        #expect(!decrypted.parsedMessages[0].isMine)
        #expect(decrypted.parsedMessages[0].senderUid == "111")
        #expect(decrypted.parsedMessages[0].proto.globalId == "9001")
        #expect(decrypted.parsedMessages[0].proto.content == "chao ban")
        #expect(decrypted.parsedMessages[1].isMine)
        #expect(decrypted.parsedMessages[1].senderUid == "999")
        #expect(decrypted.parsedMessages[1].proto.globalId == "9002")
        #expect(decrypted.parsedMessages[1].proto.content == "chao lai")
    }

    @Test func extractMobileSyncEventsAndPlan() {
        let payload: [String: Any] = [
            "data": [
                "controls": [
                    ["content": ["act_type": "transfer_msg", "act": "transfer_after_login", "data": "{\"temp_key\":\"tk_123\"}"]],
                    ["content": ["act_type": "transfer_sync2", "act": "transfer_status", "data": ["status": 3, "syncId": "s1"]]],
                    ["content": ["act_type": "transfer_sync2", "act": "transfer_status", "data": ["status": 4]]],
                    ["content": ["act_type": "transfer_sync2", "act": "upload_batch", "data": ["msgUrl": "https://dl.example/b", "syncId": "s1", "batchType": 1, "idx": 2, "isLast": 1]]],
                ]
            ]
        ]
        let evs = ZaloPhoneSync.extractMobileSyncEvents(payload)
        #expect(evs == [
            .transferAfterLogin(tempKey: "tk_123"),
            .waitingConfirmOnPhone(syncId: "s1"),
            .userConfirmed,
            .uploadBatch(syncId: "s1", url: "https://dl.example/b", batchType: 1, idx: 2, isLast: true),
        ])

        let plan = ZaloPhoneSync.buildPlan(
            conversations: [("111", false), ("g222", true), ("333", false), ("cloud_me", false)],
            userGlobalIds: ["111": "G111"],
            groupGlobalIds: ["222": "G222"],
            send2MeId: "cloud_me"
        )
        #expect(plan.partitions.map(\.partition) == ["oneone/G111", "group/G222"])
        #expect(plan.globalIdToUserId["G111"] == "111")
        #expect(plan.skipped == 1)
    }

    @Test func batchEnvelopeNeverRoutes1on1ToGhostG0AndPrefersAlias() {
        let pollingEnvelope: [String: Any] = [
            "data": [
                "msgs": [
                    [
                        "msgId": "8500861956467",
                        "cliMsgId": "1795000000001",
                        "uidFrom": "31612076530602762",
                        "idTo": "0",
                        "dName": "Ha",
                        "msgType": "chat.recommended",
                        "ts": 1795000000000 as Int64,
                        "content": [
                            "action": "recommened.calltime",
                            "params": "{\"duration\":42,\"callType\":1}",
                        ],
                    ]
                ],
                "groupMsgs": [] as [[String: Any]],
            ]
        ]

        let events = ZaloWireParser.extractBatchEvents(
            pollingEnvelope,
            myUid: "2072032406797762235",
            selfConvId: "2174771368031376212",
            nameLookup: { uid in
                uid == "31612076530602762" ? ("Mẹ", "https://ava.example/me.jpg") : nil
            }
        )
        #expect(events.count == 1)
        if case .message(let chatMsg, let stored) = events[0] {
            #expect(chatMsg.conversationId == "31612076530602762")
            #expect(stored.convId == "31612076530602762")
            #expect(chatMsg.senderName == "Mẹ")
            #expect(chatMsg.senderAvatar?.absoluteString == "https://ava.example/me.jpg")
            #expect(chatMsg.text == "Cuộc gọi thoại")
        } else {
            Issue.record("Expected parsed 1-1 call message")
        }
        #expect(ZaloWireParser.groupConvId("0") == "")
        #expect(ZaloWireParser.groupConvId("g0") == "")
        #expect(!ZaloWireParser.isGroupId("g0"))

        // Explicit 1-1 uidFrom must never be overridden by an unrelated fallbackConvId
        let crossPeerCheck = ZaloWireParser.parseWireMessage(
            [
                "msgId": "8500861956467",
                "uidFrom": "31612076530602762",
                "idTo": "0",
                "msgType": "webchat",
                "ts": 1795000000000 as Int64,
                "content": "Alo con",
            ],
            myUid: "2072032406797762235",
            fallbackConvId: "8964177950559533085",
            isGroupHint: false
        )
        if case .message(let m, _) = crossPeerCheck {
            #expect(m.conversationId == "31612076530602762")
        } else {
            Issue.record("Expected 1-1 message routed to uidFrom")
        }
    }

    @Test func webKitCloneDecoderAndUTF16XOR() {
        let dkey = "2f7a91bc00112233445566778899aabb"
        let plainJSON = "{\"title\":\"Chúc mừng 🎁 năm mới\",\"count\":18}"
        let plainUnits = Array(plainJSON.utf16)
        let keyUnits = Array(dkey.utf16)
        let cipherUnits = plainUnits.enumerated().map { idx, u in u ^ keyUnits[idx % keyUnits.count] }
        #expect(ZaloWebKitMigrator.xorDecryptUTF16(cipherUnits, keyUnits: keyUnits) == plainJSON)

        // Build a real WebKit CloneSerializer v16 object with pooled string + UTF-16 XOR field:
        var bytes = Data()
        func putU32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { bytes.append(contentsOf: $0) }
        }
        func putAscii(_ s: String) {
            let utf8 = Array(s.utf8)
            putU32(UInt32(utf8.count) | 0x8000_0000)
            bytes.append(contentsOf: utf8)
        }
        func putUTF16(_ units: [UInt16]) {
            putU32(UInt32(units.count))
            for u in units {
                var le = u.littleEndian
                withUnsafeBytes(of: &le) { bytes.append(contentsOf: $0) }
            }
        }

        putU32(16) // version 16
        bytes.append(0x02) // ObjectTag
        putAscii("userId") // pool[0]
        bytes.append(0x10); putAscii("31612076530602762") // pool[1]
        putAscii("toUid") // pool[2]
        bytes.append(0x10); putU32(0xFFFF_FFFE); bytes.append(0x01) // StringPoolTag -> pool[1]
        putAscii("message") // pool[3]
        bytes.append(0x10); putUTF16(cipherUnits) // pool[4]
        putU32(0xFFFF_FFFF) // Object terminator

        let decoded = ZaloWebKitMigrator.decodeCloneRecord(
            bytes,
            xorDecryptFields: ["message"],
            xorKeyUnits: keyUnits
        )
        #expect(decoded?["userId"] as? String == "31612076530602762")
        #expect(decoded?["toUid"] as? String == "31612076530602762")
        #expect(decoded?["message"] as? String == plainJSON)
    }
}

@Suite struct MediaFileAndSync2RegressionTests {
    // Minimal valid 1x1 PNG
    private static let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    @Test func sync2BatchLimitOneTimeKeyAndHdPreservation() async throws {
        #expect(ZaloPhoneSync.partitionsPerRequest == 30)

        // Verify `params.hd` is preserved as primary photo URL and `att.href` + `att.thumb` become fallbacks.
        let att = ZaloSyncProtobufParser.ProtoAttach(
            typeName: "chat.photo",
            params: #"{"hd":"https://photo-stal-f10.zdn.vn/jpg/hd_full.jpg","width":1200,"height":900}"#,
            title: "",
            href: "https://photo-stal-f10.zdn.vn/jpg/normal_mid.jpg",
            thumb: "https://f16-zpcloud.zdn.vn/jpg/thumb_small.jpg"
        )
        let proto = ZaloSyncProtobufParser.ProtoMsg(
            senderId: "G_PEER",
            clientId: 777,
            msgStatus: 1,
            msgType: 3,
            timestamp: 1_760_000_000_000,
            globalId: "888999",
            content: "",
            metaData: .init(attaches: [att])
        )
        let built = try #require(ZaloSyncProtobufParser.buildChatMessage(
            from: proto,
            convId: "111",
            senderUid: "111",
            senderName: "Peer",
            senderAvatar: nil,
            isMine: false,
            myUid: "999"
        ))
        if case .photo(let url, let w, let h) = built.0.kind {
            #expect(url?.absoluteString == "https://photo-stal-f10.zdn.vn/jpg/hd_full.jpg")
            #expect(w == 1200 && h == 900)
        } else {
            Issue.record("Expected photo kind")
        }
        #expect(built.0.fallbackURLs.map(\.absoluteString) == [
            "https://photo-stal-f10.zdn.vn/jpg/normal_mid.jpg",
            "https://f16-zpcloud.zdn.vn/jpg/thumb_small.jpg",
        ])

        // Round-trip through SQLite StoredMessage keeps fallbackURLs intact
        let decoded = try #require(ZaloWireParser.decodeStoredMessage(built.1))
        #expect(decoded.fallbackURLs == built.0.fallbackURLs)

        // Verify oneTimeKey (`tempKey`) is sent ONLY on `ussidx == 0` and cleared for `ussidx >= 1`
        if AsarWasmReader.loadZprotoWasm() != nil {
            let coord = ZaloPhoneSyncCoordinator()
            _ = await coord.prepareWasm()
            await coord.setLatestTempKey("ONE_TIME_SECRET_KEY")
            let r0 = try await coord.registerConversationRequest(deviceName: "Mac", ussidx: 0)
            let r1 = try await coord.registerChunkRequest(
                chunk: [PlannedSyncPartition(partition: "oneone/G1", convId: "111", isGroup: false, globalId: "G1")],
                globalIdToUserId: ["G1": "111"],
                deviceName: "Mac",
                ussidx: 1
            )
            #expect(r0.innerData.dict["tempKey"] as? String == "ONE_TIME_SECRET_KEY")
            #expect(r1.innerData.dict["tempKey"] as? String == "")
        }
    }

    @Test func e2eSessionGCMAndCTRUrlParsingAndDecryption() throws {
        #expect(MediaLoader.isZaloCDN("file-stal-f5.dlfl.vn"))
        #expect(MediaLoader.isZaloCDN("photo-stal-f10.zdn.vn"))

        // 1. 60-byte AES-256-GCM (`[key:32][iv:12][tag:16]`) on `dlfl.vn` file URL
        let keyData = Data((0..<32).map { UInt8($0 + 1) })
        let ivData = Data((0..<12).map { UInt8($0 + 101) })
        let plaintext = Data("Hello Olaz Decrypted File Content 2026!".utf8)
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: keyData), nonce: AES.GCM.Nonce(data: ivData))
        let session60 = (keyData + ivData + sealed.tag).base64EncodedString()

        let fileURL = try #require(URL(string: "https://file-stal-f5.dlfl.vn/deadbeef1234?e2esession=\(session60)"))
        let parsedGCM = try #require(ZaloMediaURL.parse(fileURL))
        #expect(parsedGCM.networkURL.absoluteString == "https://file-stal-f5.dlfl.vn/deadbeef1234")
        #expect(parsedGCM.jxlTranscodedURL == nil)
        guard case .stream(let gcmCipher) = parsedGCM.encryption else {
            Issue.record("Expected GCM stream cipher")
            return
        }
        #expect(try gcmCipher.decrypt(sealed.ciphertext) == plaintext)

        // Streaming file decrypt verification
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-gcm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let cipherFile = tmpDir.appendingPathComponent("cipher.bin")
        let plainFile = tmpDir.appendingPathComponent("plain.bin")
        try sealed.ciphertext.write(to: cipherFile)
        try gcmCipher.decryptFile(at: cipherFile, to: plainFile)
        #expect(try Data(contentsOf: plainFile) == plaintext)

        // 2. 48-byte AES-256-CTR (`[key:32][iv:16]`) + malformed double `?` (`.jxl?jxlstatus=1?e2esession=...`)
        let ctrIV = Data((0..<16).map { UInt8($0 + 50) })
        let session48 = (keyData + ctrIV).base64EncodedString()
        let doubleQURL = try #require(URL(string: "http://photo-stal-f10.zdn.vn/jxl/123/pic.jxl?jxlstatus=1?e2esession=\(session48)&version=2"))
        let parsedCTR = try #require(ZaloMediaURL.parse(doubleQURL))
        #expect(parsedCTR.networkURL.absoluteString == "https://photo-stal-f10.zdn.vn/jxl/123/pic.jxl")
        if case .stream(let ctrCipher) = parsedCTR.encryption {
            #expect(ctrCipher.algorithm == .ctr && ctrCipher.block && ctrCipher.blockSize == 4096)
        } else {
            Issue.record("Expected CTR stream cipher")
        }

        // 3. Unencrypted `.jxl?jxlstatus=1` produces clean `.jxl` networkURL AND `/jpg/.../*.jpg` fallback URL
        let jxlURL = try #require(URL(string: "https://photo-stal-f10.zdn.vn/jxl/2026/sample.jxl?jxlstatus=1"))
        let parsedJXL = try #require(ZaloMediaURL.parse(jxlURL))
        #expect(parsedJXL.networkURL.absoluteString == "https://photo-stal-f10.zdn.vn/jxl/2026/sample.jxl")
        #expect(parsedJXL.jxlTranscodedURL?.absoluteString == "https://photo-stal-f10.zdn.vn/jpg/2026/sample.jpg")
    }

    @Test func wireFileExtensionNormalizationAndPhotoGroupArrayParsing() throws {
        let evFile = ZaloWireParser.parseWireMessage([
            "msgId": "701",
            "uidFrom": "peer1",
            "idTo": "me1",
            "msgType": "share.file",
            "ts": 1_760_000_001_000 as Int64,
            "content": [
                "title": "Báo cáo quý 4",
                "fileUrl": "https://file-stal-f5.dlfl.vn/hash_without_ext",
                "params": #"{"fileSize":20480,"fileExt":".xlsx"}"#,
            ]
        ], myUid: "me1")
        if case .message(let msg, _) = evFile, case .file(let name, let size, let url) = msg.kind {
            #expect(name == "Báo cáo quý 4.xlsx")
            #expect(size == 20480)
            #expect(url?.absoluteString == "https://file-stal-f5.dlfl.vn/hash_without_ext")
        } else {
            Issue.record("Expected normalized share.file message")
        }

        // MSG.PHOTO_GROUP (`zdbMsgType(for: 11)`) with JSON array content
        #expect(ZaloWireParser.zdbMsgType(for: 11) == "chat.photo")
        #expect(ZaloWireParser.zdbMsgType(for: 12) == "chat.photo")
        let evAlbum = ZaloWireParser.parseWireMessage([
            "msgId": "702",
            "uidFrom": "peer1",
            "idTo": "me1",
            "msgType": ZaloWireParser.zdbMsgType(for: 11),
            "ts": 1_760_000_002_000 as Int64,
            "content": #"[{"hdUrl":"https://photo-stal.zdn.vn/album1.jpg","thumbUrl":"https://photo-stal.zdn.vn/album1_t.jpg","width":800,"height":600}]"#
        ], myUid: "me1")
        if case .message(let albumMsg, _) = evAlbum, case .photo(let u, let w, let h) = albumMsg.kind {
            #expect(u?.absoluteString == "https://photo-stal.zdn.vn/album1.jpg")
            #expect(w == 800 && h == 600)
            #expect(albumMsg.fallbackURLs.map(\.absoluteString) == ["https://photo-stal.zdn.vn/album1_t.jpg"])
        } else {
            Issue.record("Expected parsed photo from MSG.PHOTO_GROUP array")
        }
    }

    @MainActor
    @Test func resolveMediaQueriesSQLiteWhenNotInMemoryAndSaveToDownloadsDisambiguates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-media-sqlite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let prevAllowed = MediaLoader.allowedLocalRoots
        MediaLoader.allowedLocalRoots.append(root.resolvingSymlinksInPath().path)
        defer {
            MediaLoader.allowedLocalRoots = prevAllowed
            try? FileManager.default.removeItem(at: root)
        }

        let localImg = root.appendingPathComponent("local_photo.png")
        try Self.onePixelPNG.write(to: localImg)

        let engine = ZaloEngine(dataDirectory: root, useKeychain: false)
        let dbPath = root.appendingPathComponent("history.sqlite3")
        let store = try ZaloSQLiteStore(path: dbPath.path)
        engine.sqliteStore = store

        let msg = ChatMessage(
            id: "db_only_msg_1",
            conversationId: "conv_archive",
            senderId: "u1",
            senderName: "Sender",
            senderAvatar: nil,
            isMine: false,
            kind: .photo(url: localImg, width: 100, height: 100),
            text: "",
            date: Date(),
            status: .sent,
            quote: nil,
            reactions: [],
            isE2EE: false
        )
        let stored = try #require(ZaloWireParser.encodeChatMessage(msg))
        try await store.saveMessages([stored])

        // `engine.messages["conv_archive"]` is nil — `resolveMedia` must find it in SQLite!
        #expect(engine.messages["conv_archive"] == nil)
        let res = await engine.resolveMedia(conversationId: "conv_archive", messageId: "db_only_msg_1", kind: .photo)
        #expect(res == .file(localImg))

        // Verify `saveToDownloads` preserves real filename/ext and disambiguates duplicates (`name (1).ext`)
        let dlDir = root.appendingPathComponent("Downloads", isDirectory: true)
        let saved1 = try ChatFileResolver.saveToDownloads(staged: localImg, displayName: "Ảnh chụp/màn hình", downloadsDirectory: dlDir)
        let saved2 = try ChatFileResolver.saveToDownloads(staged: localImg, displayName: "Ảnh chụp/màn hình", downloadsDirectory: dlDir)
        #expect(saved1.lastPathComponent == "Ảnh chụp-màn hình.png")
        #expect(saved2.lastPathComponent == "Ảnh chụp-màn hình (1).png")
    }

    @MainActor
    @Test func fastPhoneSyncPlanFiltersAndSortsNewestFirstAndBulkIngestsFast() async throws {
        let threads: [(id: String, isGroup: Bool)] = [
            (id: "u_empty_friend", isGroup: false),
            (id: "u_older", isGroup: false),
            (id: "g_newest", isGroup: true),
            (id: "u_middle", isGroup: false),
        ]
        let plan = ZaloPhoneSync.buildPlan(
            conversations: threads,
            userGlobalIds: [
                "u_empty_friend": "GID_EMPTY",
                "u_older": "GID_OLD",
                "u_middle": "GID_MID",
            ],
            groupGlobalIds: ["g_newest": "GID_GRP_NEW"],
            send2MeId: nil,
            phoneTimestamps: [
                "GID_OLD": 1_700_000_001_000,
                "GID_MID": 1_700_000_050_000,
                "GID_GRP_NEW": 1_700_000_099_000,
            ]
        )
        // `u_empty_friend` is not on the phone, so it is skipped cleanly; remaining 3 are ordered newest-first!
        #expect(plan.partitions.map(\.convId) == ["gg_newest", "u_middle", "u_older"])

        // Verify `extractMobileSyncEvents` preserves `batchType=2, idx=0` vs `batchType=1, idx=0`
        let events = ZaloPhoneSync.extractMobileSyncEvents([
            "data": [
                "controls": [
                    ["content": ["act_type": "transfer_sync2", "act": "upload_batch", "data": ["syncId": "s1", "msgUrl": "https://dlfl.vn/meta", "batchType": 2, "idx": 0, "isLast": 1]]],
                    ["content": ["act_type": "transfer_sync2", "act": "upload_batch", "data": ["syncId": "s1", "msgUrl": "https://dlfl.vn/msg0", "batchType": 1, "idx": 0, "isLast": 1]]],
                ]
            ]
        ])
        #expect(events.count == 2)
        if case .uploadBatch(_, _, let bt0, let i0, _) = events[0],
           case .uploadBatch(_, _, let bt1, let i1, _) = events[1] {
            #expect(bt0 == 2 && i0 == 0)
            #expect(bt1 == 1 && i1 == 0)
        } else {
            Issue.record("Expected two uploadBatch events")
        }

        // Verify 2,000-message batch ingestion completes quickly, saves all to SQLite, and keeps unopened memory clean!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-fast-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = ZaloEngine(dataDirectory: root, useKeychain: false)
        let store = try ZaloSQLiteStore(path: root.appendingPathComponent("history.sqlite3").path)
        engine.sqliteStore = store
        engine.openConversationId = "u_open"
        engine.messages["u_open"] = []

        var batch: [ParsedPhoneMessage] = []
        for idx in 1...2_000 {
            let conv = (idx % 2 == 0) ? "u_open" : "u_background"
            let proto = ZaloSyncProtobufParser.ProtoMsg(
                senderId: "GID_PEER",
                clientId: UInt64(10_000 + idx),
                msgStatus: 1,
                msgType: 0,
                timestamp: UInt64(1_700_000_000_000 + idx * 1000),
                globalId: "\(900_000 + idx)",
                content: "Tin nhắn \(idx)",
                metaData: nil
            )
            batch.append(ParsedPhoneMessage(
                convId: conv,
                isGroup: false,
                isMine: false,
                senderGlobalId: "GID_PEER",
                senderUid: conv,
                proto: proto
            ))
        }

        let start = Date()
        await engine.ingestParsedPhoneMessages(batch)
        let elapsed = Date().timeIntervalSince(start)

        // Should complete in well under 2 seconds (previously degraded to 53s+!)
        #expect(elapsed < 2.5)
        // Unopened conversation is NOT bloated in `@Observable messages`, yet all 1,000 messages are in SQLite!
        #expect(engine.messages["u_background"] == nil)
        let bgStored = try await store.messages(convId: "u_background", limit: 50)
        #expect(bgStored.count == 50)
        // Open conversation IS updated in memory (capped cleanly to 200 latest messages)
        #expect(engine.messages["u_open"]?.count == 200)
        #expect(engine.messages["u_open"]?.last?.text == "Tin nhắn 2000")
    }

    @MainActor
    @Test func nativeVoiceAndVideoCallProtocolAndVoipControlsMatchOfficialSchema() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-call-proto-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // 1. Verify `init` JSON schema for VNG `ZaloCall`
        let initJSON = ZaloVoiceCallProtocol.buildInitJSON(uid: "12345", name: "Linh", avatar: "https://a.vn/1.jpg", dataDirectory: root)
        let initObj = try #require(JSONLossless.parseObject(Data(initJSON.utf8)))
        #expect(JSONLossless.string(initObj["type"]) == "update")
        #expect(JSONLossless.string(initObj["command"]) == "init")
        let initData = try #require(initObj["data"] as? [String: Any])
        let local = try #require(initData["local"] as? [String: Any])
        #expect(JSONLossless.string(local["id"]) == "12345")
        #expect(JSONLossless.string(local["name"]) == "Linh")
        #expect(JSONLossless.int64(initData["clientVersion"]) == Int64(ZaloDomains.zpwVer))

        // 2. Verify `makeCall` 1-1 audio (`type=1`), 1-1 video (`type=3`), and group video (`type=6`)
        let audio11 = try #require(JSONLossless.parseObject(Data(
            ZaloVoiceCallProtocol.buildMakeCallJSON(partners: [(id: "u_99", name: "An", avatar: "")], video: false).utf8
        )))
        #expect(JSONLossless.string(audio11["type"]) == "request")
        #expect(JSONLossless.string(audio11["command"]) == "makeCall")
        #expect(JSONLossless.int64((audio11["data"] as? [String: Any])?["type"]) == 1)

        let video11 = try #require(JSONLossless.parseObject(Data(
            ZaloVoiceCallProtocol.buildMakeCallJSON(partners: [(id: "99", name: "An", avatar: "")], video: true).utf8
        )))
        #expect(JSONLossless.int64((video11["data"] as? [String: Any])?["type"]) == 3)

        let groupVideo = try #require(JSONLossless.parseObject(Data(
            ZaloVoiceCallProtocol.buildMakeCallJSON(
                partners: [(id: "99", name: "An", avatar: ""), (id: "88", name: "Bình", avatar: "")],
                video: true,
                groupInfo: (id: "g777", name: "Team", avatar: "", maxUsers: 11)
            ).utf8
        )))
        let gvData = try #require(groupVideo["data"] as? [String: Any])
        #expect(JSONLossless.int64(gvData["type"]) == 6)
        #expect(JSONLossless.string((gvData["groupInfo"] as? [String: Any])?["id"]) == "777")

        // 3. Verify `/api/voicecall/*` endpoint & payload mapping (`OU7N` + `fBUP`)
        let req401 = try #require(ZaloVoiceCallProtocol.buildSignalRequest(
            command: 401,
            params: ["calleeId": "99", "callId": 42, "type": 1],
            imei: "IMEI_TEST"
        ))
        #expect(req401.path == "/api/voicecall/requestcall")
        #expect(JSONLossless.int64(req401.payload["typeRequest"]) == 1)
        #expect(JSONLossless.string(req401.payload["imei"]) == "IMEI_TEST")

        let req402 = try #require(ZaloVoiceCallProtocol.buildSignalRequest(
            command: 402,
            params: ["callerId": "99", "callId": 42, "status": 0, "session": "sess1", "extendData": "{\"sdp\":1}"],
            imei: "IMEI_TEST"
        ))
        #expect(req402.path == "/api/voicecall/answer")
        #expect(req402.activateApp == true)
        #expect(JSONLossless.string(req402.payload["session_id"]) == "sess1")
        #expect(JSONLossless.int64(req402.payload["subCommand"]) == 3)

        let req12433 = try #require(ZaloVoiceCallProtocol.buildSignalRequest(
            command: 12433,
            params: ["groupId": "777", "callId": 55, "typeRequest": 6, "partners": ["99", "88"]],
            imei: "IMEI_TEST"
        ))
        #expect(req12433.path == "/api/voicecall/group/requestcall")

        let recvJSON = ZaloVoiceCallProtocol.buildRecvSignalJSON(command: 401, data: ["callId": 42, "servers": []])
        let recvObj = try #require(JSONLossless.parseObject(Data(recvJSON.utf8)))
        #expect(JSONLossless.string(recvObj["type"]) == "recvSignal")
        #expect(JSONLossless.int64(recvObj["command"]) == 401)

        // 4. Verify incoming VoIP control envelope (`act_type == "voip"`) sets & clears ringing banner and skips >60s stale events
        let engine = ZaloEngine(dataDirectory: root, useKeychain: false)
        engine.call.helperInstalled = true
        engine.call.rendererReady = true
        engine.call.supported = true
        engine.call.videoSupported = true

        // Open conversation before friends load -> call buttons available!
        engine.updateCallGateForConversation("99")
        let conv99 = ZaloEngine.ConversationSummary(id: "99", isGroup: false, name: "An", avatar: nil, pinned: false, members: 0, unread: 0, preview: nil)
        #expect(engine.callAvailability(for: conv99, video: false) == .available)
        #expect(engine.callAvailability(for: conv99, video: true) == .available)

        // Open group conversation -> video call button available, voice hidden!
        engine.updateCallGateForConversation("g777")
        let convG777 = ZaloEngine.ConversationSummary(id: "g777", isGroup: true, name: "Team", avatar: nil, pinned: false, members: 5, unread: 0, preview: nil)
        #expect(engine.callAvailability(for: convG777, video: true) == .available)
        #expect(engine.callAvailability(for: convG777, video: false) == .hidden)

        // Stale request (> 60s old) is ignored
        let staleTs = Int64(Date().timeIntervalSince1970 * 1000) - 120_000
        await engine.processControlEnvelope([
            "data": ["controls": [["content": ["act_type": "voip", "act": "request", "data": ["callerId": "99", "callerName": "An", "ts": staleTs]]]]]
        ])
        #expect(engine.call.incoming == nil)

        // Fresh incoming request rings!
        let freshTs = Int64(Date().timeIntervalSince1970 * 1000)
        await engine.processControlEnvelope([
            "data": ["controls": [["content": ["act_type": "voip", "act": "request", "data": ["callerId": "99", "callerName": "An", "ts": freshTs]]]]]
        ])
        #expect(engine.call.incoming?.name == "An")
        #expect(engine.call.incoming?.group == false)

        // Cancel control clears incoming banner!
        await engine.processControlEnvelope([
            "data": ["controls": [["content": ["act_type": "voip", "act": "cancel", "data": ["callerId": "99"]]]]]
        ])
        #expect(engine.call.incoming == nil)
    }

    @Test func e2eeSignalDecryptionPlaceholderProtectionAndSQLiteSelfHealing() async throws {
        let samplePreKeyCipher = "AzMovwMIpFUwoVUSIQVNUKcMqQKEDdK1jcEt8He7V15D1iWl9ngJgOPtsXiUIRohBZSX4D1qiBhXbdSPciObevx/DTnpfki5s5eI0wzTTQp/InIzCiEFCFnb614YZfaOg7R9/7/DIagW4nsLw5V5jK1ELLEbY1IQCBgAIkDL6XqJXgMKkj5gMtM5+CCkjt5p+Xm4q0wQjhLXMOgyl8M137oQAjyDi9fCjALZOCaCQpyjgm5/eW2crnxEu3JybU+y/enV2FQ="
        let sampleWhisperCipher = "AjMKIQXfGtZEt75pr2/KWoTA8W8Bu0oNpGDv9ITalIBSb69UaxAOGAAiENtYix7GNUB1eR/LgY4IuK2Blmqxld2njA=="
        let brokenStickerURL = "https://api.zaloapp.com/api/emoticon/sticker/webpc?eid=\(samplePreKeyCipher)&size=130"

        #expect(ZaloWireParser.isSignalCiphertext(samplePreKeyCipher))
        #expect(ZaloWireParser.isSignalCiphertext(sampleWhisperCipher))
        #expect(!ZaloWireParser.isSignalCiphertext("miế ngan trộn"))
        #expect(!ZaloWireParser.isSignalCiphertext("https://api.zaloapp.com/api/emoticon/sticker/webpc?eid=34840&size=130"))
        #expect(ZaloWireParser.urlHasUndecryptedSignalCipher(brokenStickerURL))

        // 1. Undecryptable Signal ciphertext becomes a clean `.placeholder(symbol: "lock.fill", ...)` with `e2ee_locked`, NEVER raw Base64 or broken sticker URL!
        let lockedTextEvent = ZaloWireParser.parseWireMessage([
            "msgId": "8502116332010",
            "cliMsgId": "1794982452921",
            "uidFrom": "31612076530602762",
            "idTo": "2072032406797762235",
            "msgType": "webchat",
            "ts": 1_794_982_453_589,
            "content": samplePreKeyCipher,
        ], myUid: "2072032406797762235")
        guard case .message(let lockedChatMsg, let lockedStored) = lockedTextEvent else {
            Issue.record("Expected locked placeholder message"); return
        }
        #expect(lockedChatMsg.isE2EE == true)
        #expect(lockedStored.status == "e2ee_locked")
        if case .placeholder(let sym, let label) = lockedChatMsg.kind {
            #expect(sym == "lock.fill")
            #expect(label.contains("mã hóa đầu cuối"))
        } else {
            Issue.record("Expected .placeholder kind, got \(lockedChatMsg.kind)")
        }

        let lockedStickerEvent = ZaloWireParser.parseWireMessage([
            "msgId": "8502117270115",
            "cliMsgId": "1794982471828",
            "uidFrom": "31612076530602762",
            "idTo": "2072032406797762235",
            "msgType": "chat.sticker",
            "ts": 1_794_982_472_463,
            "content": ["id": samplePreKeyCipher, "catId": samplePreKeyCipher, "type": samplePreKeyCipher],
        ], myUid: "2072032406797762235")
        if case .message(let sMsg, let sStored) = lockedStickerEvent {
            #expect(sStored.status == "e2ee_locked")
            if case .placeholder(_, let label) = sMsg.kind {
                #expect(label.contains("Sticker mã hóa đầu cuối"))
            } else {
                Issue.record("Sticker with Signal eid must render as lock placeholder, not broken image")
            }
        } else {
            Issue.record("Expected locked sticker placeholder")
        }

        // 2. Verify SQLite plaintext protection + Sync2 replacement + boot self-healing (`repairUndecryptedE2EEMessages`)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-e2ee-sql-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try ZaloSQLiteStore(path: root.appendingPathComponent("history.sqlite3").path)
        try await store.saveMessages([lockedStored])

        // Sync2 arrives with real plaintext for the exact same message -> replaces `e2ee_locked`!
        let plainEvent = ZaloWireParser.parseWireMessage([
            "msgId": "8502116332010",
            "cliMsgId": "1794982452921",
            "uidFrom": "31612076530602762",
            "idTo": "2072032406797762235",
            "msgType": "webchat",
            "ts": 1_794_982_453_589,
            "content": "Con về ăn cơm nhé",
        ], myUid: "2072032406797762235")
        guard case .message(_, let plainStored) = plainEvent else { Issue.record("Expected plain"); return }
        try await store.saveMessages([plainStored])

        // Now server preload/polling re-sends `lockedStored` -> MUST NOT overwrite `"Con về ăn cơm nhé"`!
        try await store.saveMessages([lockedStored])
        let loadedAfter = try await store.messages(convId: "31612076530602762", limit: 10)
        #expect(loadedAfter.count == 1)
        #expect(loadedAfter.first?.text == "Con về ăn cơm nhé")
        #expect(loadedAfter.first?.status == "sent")

        // Legacy poisoned row in SQLite (stored before this fix with status='sent' and raw Base64) is repaired on boot!
        let poisonedRaw = try JSONSerialization.data(withJSONObject: [
            "id": "legacy_poison_1",
            "clientId": "999111",
            "conversationId": "31612076530602762",
            "senderId": "31612076530602762",
            "senderName": "Mẹ",
            "senderAvatar": "",
            "isMine": false,
            "kind": ["type": "sticker", "url": brokenStickerURL],
            "text": "[Sticker]",
            "date": 1_794_982_472_463,
            "status": "sent",
            "isE2EE": false,
        ] as [String: Any])
        try await store.saveMessages([StoredMessage(
            id: "legacy_poison_1",
            convId: "31612076530602762",
            clientId: "999111",
            senderId: "31612076530602762",
            senderName: "Mẹ",
            senderAvatar: "",
            isMine: false,
            text: "[Sticker]",
            kindTag: "sticker",
            tsMs: 1_794_982_472_463,
            status: "sent",
            rawJSONData: poisonedRaw
        )])
        let repaired = try await store.repairUndecryptedE2EEMessages()
        #expect(repaired >= 1)
        let afterRepair = try await store.messages(convId: "31612076530602762", limit: 10)
        let repairedSticker = try #require(afterRepair.first(where: { $0.id == "legacy_poison_1" }))
        #expect(repairedSticker.kindTag == "placeholder")
        #expect(repairedSticker.status == "e2ee_locked")

        // 3. Real libsignal-protocol PC E2EE round-trip (`ZaloE2EEManager` decrypting live text & 4-byte LE uint32 sticker!)
        let e2eeMgr = ZaloE2EEManager()
        await e2eeMgr.prepare(uid: "me_uid", store: store)
        let savedStoreJSON = try #require(try await store.getPreferenceString(key: ZaloE2EEManager.storePrefKey))

        // Simulate sender ("mom_uid", deviceId = 0) encrypting a text message + a 4-byte LE sticker ID (34840) to our PC bundle!
        let senderRT = try JSRuntime(name: "test-mom-sender")
        try await senderRT.loadModule("vendor/libsignal-protocol.js")
        try await senderRT.loadModule("zalo-e2ee.js")
        _ = try await senderRT.evaluate("""
        globalThis.__testEncryptToPC = async function(pcJSON) {
          const pc = JSON.parse(pcJSON);
          const b64ToBuf = (b64) => {
            const bin = atob(b64);
            const u = new Uint8Array(bin.length);
            for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i);
            return u.buffer;
          };
          const wrapZalo = (msg) => {
            const head = String.fromCharCode(msg.type === 3 ? 3 : 2);
            return btoa(head + msg.body);
          };
          const sStore = {
            s: {},
            Direction: { SENDING: 1, RECEIVING: 2 },
            getIdentityKeyPair() { return Promise.resolve(this.s.ik); },
            getLocalRegistrationId() { return Promise.resolve(this.s.reg); },
            isTrustedIdentity() { return Promise.resolve(true); },
            loadIdentityKey(k) { return Promise.resolve(this.s['ik_' + k]); },
            saveIdentity(k, v) { this.s['ik_' + k] = v; return Promise.resolve(false); },
            loadPreKey(k) { return Promise.resolve(this.s['pk_' + k]); },
            storePreKey(k, v) { this.s['pk_' + k] = v; return Promise.resolve(); },
            removePreKey(k) { delete this.s['pk_' + k]; return Promise.resolve(); },
            loadSignedPreKey(k) { return Promise.resolve(this.s['spk_' + k]); },
            storeSignedPreKey(k, v) { this.s['spk_' + k] = v; return Promise.resolve(); },
            loadSession(k) { return Promise.resolve(this.s['sess_' + k]); },
            storeSession(k, v) { this.s['sess_' + k] = v; return Promise.resolve(); },
            getSessionTs() { return undefined; }
          };
          sStore.s.reg = 777;
          sStore.s.ik = await libsignal.KeyHelper.generateIdentityKeyPair();
          const spkEntry = pc.signedPreKeys['1'];
          const pkEntry = pc.preKeys['1'];
          const toAddr = new libsignal.SignalProtocolAddress('me_uid_2', 2);
          const builder = new libsignal.SessionBuilder(sStore, toAddr, { logger: console });
          await builder.processPreKey({
            registrationId: pc.registrationId,
            identityKey: b64ToBuf(pc.identity.pubKey),
            signedPreKey: { keyId: 1, publicKey: b64ToBuf(spkEntry.pubKey), signature: b64ToBuf(spkEntry.signature) },
            preKey: { keyId: 1, publicKey: b64ToBuf(pkEntry.pubKey) }
          });
          const cipher = new libsignal.SessionCipher(sStore, toAddr, { logger: console });
          const textMsg = await cipher.encrypt(new TextEncoder().encode('Mẹ nấu canh chua rồi!').buffer);
          const idBytes = new Uint8Array([34840 & 0xff, (34840 >> 8) & 0xff, 0, 0]);
          const catBytes = new Uint8Array([420 & 0xff, (420 >> 8) & 0xff, 0, 0]);
          const typeBytes = new Uint8Array([7, 0, 0, 0]);
          const sId = await cipher.encrypt(idBytes.buffer);
          const sCat = await cipher.encrypt(catBytes.buffer);
          const sType = await cipher.encrypt(typeBytes.buffer);
          return {
            text: wrapZalo(textMsg),
            stickerId: wrapZalo(sId),
            stickerCat: wrapZalo(sCat),
            stickerType: wrapZalo(sType)
          };
        };
        """)
        let ciphersVal = try await senderRT.callAsync("__testEncryptToPC", [.string(savedStoreJSON)])

        let encText = try #require(ciphersVal["text"]?.stringValue)
        let encStickerId = try #require(ciphersVal["stickerId"]?.stringValue)
        let encStickerCat = try #require(ciphersVal["stickerCat"]?.stringValue)
        let encStickerType = try #require(ciphersVal["stickerType"]?.stringValue)

        let rawEnvelope: [String: Any] = [
            "data": [
                "msgs": [
                    [
                        "msgId": "9001",
                        "cliMsgId": "9001",
                        "uidFrom": "mom_uid",
                        "idTo": "me_uid",
                        "msgType": "webchat",
                        "ts": 1_795_000_001_000,
                        "paramsExt": ["platformType": 0],
                        "content": encText,
                    ],
                    [
                        "msgId": "9002",
                        "cliMsgId": "9002",
                        "uidFrom": "mom_uid",
                        "idTo": "me_uid",
                        "msgType": "chat.sticker",
                        "ts": 1_795_000_002_000,
                        "paramsExt": ["platformType": 0],
                        "content": ["id": encStickerId, "catId": encStickerCat, "type": encStickerType],
                    ],
                ]
            ]
        ]

        let decryptedBox = await e2eeMgr.decryptEnvelopeIfNeeded(ZaloJSONBox(rawEnvelope), myUid: "me_uid", store: store)
        let parsedEvents = ZaloWireParser.extractBatchEvents(decryptedBox.dict, myUid: "me_uid")
        #expect(parsedEvents.count == 2)

        if case .message(let m1, _) = parsedEvents[0] {
            #expect(m1.text == "Mẹ nấu canh chua rồi!")
            #expect(m1.isE2EE == true)
        } else {
            Issue.record("Expected decrypted E2EE text message")
        }

        if case .message(let m2, _) = parsedEvents[1], case .sticker(let sURL) = m2.kind {
            #expect(sURL?.absoluteString.contains("eid=34840") == true)
            #expect(m2.isE2EE == true)
        } else {
            Issue.record("Expected decrypted E2EE sticker URL with eid=34840")
        }
    }
}

private final class MockProfileURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data) -> (Int, [String: Any])
    static let handlers = OSAllocatedUnfairLock<[String: Handler]>(initialState: [:])

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return handlers.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let host = url.host,
              let handler = Self.handlers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        var bodyData = request.httpBody ?? Data()
        if bodyData.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n > 0 { bodyData.append(contentsOf: buf.prefix(n)) }
                else { break }
            }
        }
        let (status, jsonObj) = handler(request, bodyData)
        let respData = (try? JSONSerialization.data(withJSONObject: jsonObj)) ?? Data("{}".utf8)
        let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: respData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite struct SyncProfilesAndSQLiteIndexTests {
    @Test func sanitizeProfileUidAndExtractProfilesMapVariants() {
        // Rejects invalid / group / zero / stranger / global IDs / overlong
        #expect(ZaloWireParser.sanitizeProfileUid("") == nil)
        #expect(ZaloWireParser.sanitizeProfileUid("   ") == nil)
        #expect(ZaloWireParser.sanitizeProfileUid("0") == nil)
        #expect(ZaloWireParser.sanitizeProfileUid("000") == nil)
        #expect(ZaloWireParser.sanitizeProfileUid("-1") == nil)
        #expect(ZaloWireParser.sanitizeProfileUid("g123") == nil)
        #expect(ZaloWireParser.sanitizeProfileUid("G123456") == nil)
        #expect(ZaloWireParser.sanitizeProfileUid("stranger_box") == nil)
        #expect(ZaloWireParser.sanitizeProfileUid("u") == nil)
        #expect(ZaloWireParser.sanitizeProfileUid("u0") == nil)
        #expect(ZaloWireParser.sanitizeProfileUid("123_abc") == nil)
        #expect(ZaloWireParser.sanitizeProfileUid("123_") == nil)
        #expect(ZaloWireParser.sanitizeProfileUid("2000.globalEncryptedId==") == nil)
        #expect(ZaloWireParser.sanitizeProfileUid(String(repeating: "9", count: 25)) == nil)

        // Accepts numeric UIDs, u-prefixed UIDs, and _<version> suffixed UIDs
        #expect(ZaloWireParser.sanitizeProfileUid("123456") == "123456")
        #expect(ZaloWireParser.sanitizeProfileUid("  123456  ") == "123456")
        #expect(ZaloWireParser.sanitizeProfileUid("u123456") == "123456")
        #expect(ZaloWireParser.sanitizeProfileUid("123456_0") == "123456")
        #expect(ZaloWireParser.sanitizeProfileUid("u123456_12") == "123456")
        #expect(ZaloWireParser.sanitizeProfileUid(String(repeating: "7", count: 24)) == String(repeating: "7", count: 24))

        // Parses `profiles`, `changed_profiles`, `unchanged_profiles`, and `list`
        let v2Combined = ZaloWireParser.extractProfilesMap([
            "data": [
                "changed_profiles": [
                    "111_0": ["userId": "111", "displayName": "Changed Alice", "avatar": "https://a.vn/1.jpg"]
                ],
                "unchanged_profiles": [
                    "222_0": ["uid": "222", "zaloName": "Unchanged Bob", "avt": "https://a.vn/2.jpg"]
                ]
            ]
        ])
        #expect(v2Combined["111"]?["displayName"] as? String == "Changed Alice")
        #expect(v2Combined["222"]?["zaloName"] as? String == "Unchanged Bob")

        let fromList = ZaloWireParser.extractProfilesMap([
            "data": [
                "list": [
                    ["id": "333", "dName": "Charlie"]
                ]
            ]
        ])
        #expect(fromList["333"]?["dName"] as? String == "Charlie")
    }

    @Test func fetchProfilesSanitizesFallsBackToGetProfilesV2AndSplitsOn114() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-prof-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let host = "mock-prof-\(UUID().uuidString.lowercased()).invalid"
        let key = Data("0123456789abcdef".utf8)
        let callLog = OSAllocatedUnfairLock<[(path: String, uids: [String])]>(initialState: [])

        MockProfileURLProtocol.handlers.withLock { handlers in
            handlers[host] = { req, bodyData in
                let path = req.url?.path ?? ""
                let bodyStr = String(decoding: bodyData, as: UTF8.self)
                var requestedUids: [String] = []
                if let paramsPart = bodyStr.split(separator: "&").first(where: { $0.hasPrefix("params=") }) {
                    let encoded = String(paramsPart.dropFirst("params=".count))
                    let decodedB64 = encoded.removingPercentEncoding ?? encoded
                    if let plain = try? ZaloCrypto.decodeAES(key: key, base64: decodedB64),
                       let obj = JSONLossless.parseObject(Data(plain.utf8)),
                       let arr = obj["friend_pversion_map"] as? [String] {
                        requestedUids = arr
                    }
                }
                let uids = requestedUids
                callLog.withLock { $0.append((path: path, uids: uids)) }

                // Poison UID "999" triggers 114 on both endpoints so recursive split isolates it
                if requestedUids.contains("999_0") {
                    return (200, ["error_code": 114, "error_message": "Invalid parameter"])
                }
                // Primary endpoint rejects with 114 even for valid batch -> triggers fallback to getprofiles/v2
                if path == "/api/social/group/members" {
                    return (200, ["error_code": 114, "error_message": "Group members fallback"])
                }
                if path == "/api/social/friend/getprofiles/v2" {
                    var changed: [String: [String: Any]] = [:]
                    for pver in requestedUids {
                        let uid = String(pver.split(separator: "_").first ?? "")
                        changed[uid] = ["userId": uid, "displayName": "User \(uid)", "avatar": "https://ava.example/\(uid).jpg"]
                    }
                    return (200, ["error_code": 0, "data": ["changed_profiles": changed, "unchanged_profiles": [:]]])
                }
                return (404, ["error_code": -1])
            }
        }
        defer { _ = MockProfileURLProtocol.handlers.withLock { $0.removeValue(forKey: host) } }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProfileURLProtocol.self]
        let session = URLSession(configuration: config)

        let client = ZaloSessionClient(dataDirectory: root, useKeychain: false, urlSession: session)
        var domains = ZaloDomains()
        domains.serviceCandidates["profile"] = ["https://\(host)"]
        var account = ZaloLoginAccount()
        account.userId = "100"
        await client.updateCredentials(account: account, secretKey: key, zpwSek: "sek.1.2", domains: domains)

        // 1. All-invalid UIDs short-circuit without network calls
        let emptyBox = try await client.fetchProfiles(uids: ["0", "-1", "g123", "stranger_box", "2000.noise=="])
        #expect(emptyBox.dict.isEmpty)
        #expect(callLog.withLock { $0.isEmpty })

        // 2. Valid UIDs + one poison UID "999": fallback + binary split returns all valid profiles and drops only "999"
        let resBox = try await client.fetchProfiles(uids: ["u111", "222_0", "999", "333", "0", "g888", "222"])
        let profiles = ZaloWireParser.extractProfilesMap(resBox.dict)
        #expect(Set(profiles.keys) == Set(["111", "222", "333"]))
        #expect(profiles["111"]?["displayName"] as? String == "User 111")
        #expect(profiles["222"]?["displayName"] as? String == "User 222")
        #expect(profiles["333"]?["displayName"] as? String == "User 333")
        #expect(callLog.withLock { $0.contains(where: { $0.path == "/api/social/friend/getprofiles/v2" }) })

        // 3. >50 UIDs are chunked into batches of at most 50 and merged seamlessly
        callLog.withLock { $0.removeAll() }
        let sixtyUids = (1...60).map { "\(10_000 + $0)" }
        let chunkedBox = try await client.fetchProfiles(uids: sixtyUids)
        let chunkedProfiles = ZaloWireParser.extractProfilesMap(chunkedBox.dict)
        #expect(chunkedProfiles.count == 60)
        let chunkCounts = callLog.withLock { $0.filter { $0.path == "/api/social/friend/getprofiles/v2" }.map(\.uids.count) }
        #expect(chunkCounts == [50, 10])
    }

    @Test func sqliteClientIdIndexExistsBulkSaveIsFastAndE2EETwinProtectionIntact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-sql-idx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try ZaloSQLiteStore(path: root.appendingPathComponent("history.sqlite3").path)
        let indexes = try await store.messageIndexNames()
        #expect(indexes.contains("idx_messages_conv_client"))

        func makeMsg(id: String, clientId: String, ts: Int64, text: String = "Hello", status: String = "sent") -> StoredMessage {
            StoredMessage(
                id: id,
                convId: "conv_bulk",
                clientId: clientId,
                senderId: "111",
                senderName: "Alice",
                senderAvatar: "",
                isMine: false,
                text: text,
                kindTag: "text",
                tsMs: ts,
                status: status,
                rawJSONData: Data("{\"id\":\"\(id)\",\"text\":\"\(text)\"}".utf8)
            )
        }

        // Seed 2,000 existing rows in the same conversation so an unindexed twin scan would be O(N^2)
        let seedBatch = (1...2_000).map { i in
            makeMsg(id: "seed_\(i)", clientId: "cli_seed_\(i)", ts: Int64(1_700_000_000_000 + i))
        }
        try await store.saveMessages(seedBatch)

        // Bulk save another 2,500 rows with `skipTwinChecks: false` (default) -> indexed O(log N) completes well under 0.5s!
        let nextBatch = (2_001...4_500).map { i in
            makeMsg(id: "msg_\(i)", clientId: "cli_\(i)", ts: Int64(1_700_000_000_000 + i))
        }
        let t0 = Date()
        try await store.saveMessages(nextBatch)
        let indexedElapsed = Date().timeIntervalSince(t0)
        #expect(indexedElapsed < 0.5)

        // Also test fast-path `skipTwinChecks: true` on 2,500 rows
        let fastBatch = (4_501...7_000).map { i in
            makeMsg(id: "msg_\(i)", clientId: "cli_\(i)", ts: Int64(1_700_000_000_000 + i))
        }
        let t1 = Date()
        try await store.saveMessages(fastBatch, skipTwinChecks: true)
        let fastElapsed = Date().timeIntervalSince(t1)
        #expect(fastElapsed < 0.5)

        // Verify E2EE twin protection remains 100% intact:
        // 1) Locked twin arriving after plaintext twin with matching clientId is ignored
        try await store.saveMessages([makeMsg(id: "e2ee_dup_1", clientId: "cli_2001", ts: 1_700_000_002_001, text: "Locked", status: "e2ee_locked")])
        #expect(try await store.message(convId: "conv_bulk", idOrClientId: "e2ee_dup_1") == nil)

        // 2) Locked placeholder stored first is deleted when plaintext twin arrives with different id and matching clientId
        try await store.saveMessages([makeMsg(id: "locked_temp_99", clientId: "cli_twin_99", ts: 1_700_000_999_000, text: "Locked", status: "e2ee_locked")])
        #expect(try await store.message(convId: "conv_bulk", idOrClientId: "locked_temp_99") != nil)
        try await store.saveMessages([makeMsg(id: "plain_real_99", clientId: "cli_twin_99", ts: 1_700_000_999_000, text: "Decrypted!", status: "sent")])
        #expect(try await store.message(convId: "conv_bulk", idOrClientId: "locked_temp_99") == nil)
        let real99 = try await store.message(convId: "conv_bulk", idOrClientId: "plain_real_99")
        #expect(real99?.text == "Decrypted!")
    }

    @Test func phoneSyncIdleWaitAndMultiChunkProgressLogic() {
        let start = Date(timeIntervalSince1970: 1_000)

        // 1. Unanswered waits up to 120s, then times out unconfirmed
        let waitUnanswered = ZaloEngine.evaluateWaitStep(
            signal: nil,
            snapshot: SyncRequestSnapshot(batchesCount: 0, importedCount: 0, syncedConversationsCount: 0, lastActivity: nil, lastSeen: false, inFlightCount: 0, isFulfilled: false),
            now: start.addingTimeInterval(60),
            start: start,
            answeredAt: nil
        )
        #expect(waitUnanswered == .keepWaiting(answeredAt: nil))

        let timedOutUnanswered = ZaloEngine.evaluateWaitStep(
            signal: nil,
            snapshot: SyncRequestSnapshot(batchesCount: 0, importedCount: 0, syncedConversationsCount: 0, lastActivity: nil, lastSeen: false, inFlightCount: 0, isFulfilled: false),
            now: start.addingTimeInterval(121),
            start: start,
            answeredAt: nil
        )
        #expect(timedOutUnanswered == .finished(outcome: .timedOutUnconfirmed, reason: "unconfirmed_timeout"))

        // 2. User confirmation arriving at t=25s does NOT prematurely trigger 8s empty timeout at t=26s
        let t25 = start.addingTimeInterval(25)
        let justConfirmed = ZaloEngine.evaluateWaitStep(
            signal: .userConfirmed,
            snapshot: SyncRequestSnapshot(batchesCount: 0, importedCount: 0, syncedConversationsCount: 0, lastActivity: nil, lastSeen: false, inFlightCount: 0, isFulfilled: false),
            now: t25,
            start: start,
            answeredAt: nil
        )
        #expect(justConfirmed == .keepWaiting(answeredAt: t25))

        let oneSecAfterConfirm = ZaloEngine.evaluateWaitStep(
            signal: .userConfirmed,
            snapshot: SyncRequestSnapshot(batchesCount: 0, importedCount: 0, syncedConversationsCount: 0, lastActivity: nil, lastSeen: false, inFlightCount: 0, isFulfilled: false),
            now: t25.addingTimeInterval(1),
            start: start,
            answeredAt: t25
        )
        #expect(oneSecAfterConfirm == .keepWaiting(answeredAt: t25))

        // 3. Large chunk with active batches in flight keeps waiting well past 35s (e.g. 50s, 120s), up to 180s ceiling
        let activeAt50s = ZaloEngine.evaluateWaitStep(
            signal: .userConfirmed,
            snapshot: SyncRequestSnapshot(batchesCount: 30, importedCount: 1500, syncedConversationsCount: 10, lastActivity: start.addingTimeInterval(49), lastSeen: false, inFlightCount: 4, isFulfilled: false),
            now: start.addingTimeInterval(50),
            start: start,
            answeredAt: start
        )
        #expect(activeAt50s == .keepWaiting(answeredAt: start))

        let ceilingAt181s = ZaloEngine.evaluateWaitStep(
            signal: .userConfirmed,
            snapshot: SyncRequestSnapshot(batchesCount: 30, importedCount: 1500, syncedConversationsCount: 10, lastActivity: start.addingTimeInterval(180), lastSeen: false, inFlightCount: 1, isFulfilled: false),
            now: start.addingTimeInterval(181),
            start: start,
            answeredAt: start
        )
        #expect(ceilingAt181s == .finished(outcome: .completed, reason: "ceiling_timeout"))

        // 4. Fulfilled or lastSeen with inFlight==0 completes immediately; idle<=4 waits, idle>4 completes
        let fulfilled = ZaloEngine.evaluateWaitStep(
            signal: .userConfirmed,
            snapshot: SyncRequestSnapshot(batchesCount: 65, importedCount: 5000, syncedConversationsCount: 30, lastActivity: start.addingTimeInterval(55), lastSeen: true, inFlightCount: 0, isFulfilled: true),
            now: start.addingTimeInterval(55),
            start: start,
            answeredAt: start
        )
        #expect(fulfilled == .finished(outcome: .completed, reason: "fulfilled"))

        let idleShort = ZaloEngine.evaluateWaitStep(
            signal: .userConfirmed,
            snapshot: SyncRequestSnapshot(batchesCount: 10, importedCount: 500, syncedConversationsCount: 5, lastActivity: start.addingTimeInterval(40), lastSeen: false, inFlightCount: 0, isFulfilled: false),
            now: start.addingTimeInterval(42),
            start: start,
            answeredAt: start
        )
        #expect(idleShort == .keepWaiting(answeredAt: start))

        let idleDone = ZaloEngine.evaluateWaitStep(
            signal: .userConfirmed,
            snapshot: SyncRequestSnapshot(batchesCount: 10, importedCount: 500, syncedConversationsCount: 5, lastActivity: start.addingTimeInterval(40), lastSeen: false, inFlightCount: 0, isFulfilled: false),
            now: start.addingTimeInterval(44.5),
            start: start,
            answeredAt: start
        )
        #expect(idleDone == .finished(outcome: .completed, reason: "idle_after_batches"))

        let emptyTimeout = ZaloEngine.evaluateWaitStep(
            signal: .userConfirmed,
            snapshot: SyncRequestSnapshot(batchesCount: 0, importedCount: 0, syncedConversationsCount: 0, lastActivity: nil, lastSeen: false, inFlightCount: 0, isFulfilled: false),
            now: start.addingTimeInterval(8.5),
            start: start,
            answeredAt: start
        )
        #expect(emptyTimeout == .finished(outcome: .completed, reason: "empty_chunk_timeout"))

        // 5. Rejected and Busy signals terminate immediately
        #expect(ZaloEngine.evaluateWaitStep(signal: .userRejected, snapshot: nil, now: start, start: start, answeredAt: nil) == .finished(outcome: .rejected, reason: "user_rejected"))
        #expect(ZaloEngine.evaluateWaitStep(signal: .mobileBusy, snapshot: nil, now: start, start: start, answeredAt: nil) == .finished(outcome: .busy, reason: "mobile_busy"))

        // 6. Multi-chunk progress smoothly advances inside [0.14, 0.72] across chunks and batches
        let p0 = ZaloEngine.computeStage2BatchProgress(completedPartitionsBeforeChunk: 0, currentChunkPartitions: 30, totalPartitions: 90, batchesCompletedInChunk: 1, expectedBatchesInChunk: nil, previousProgress: 0.14)
        let p1 = ZaloEngine.computeStage2BatchProgress(completedPartitionsBeforeChunk: 0, currentChunkPartitions: 30, totalPartitions: 90, batchesCompletedInChunk: 10, expectedBatchesInChunk: nil, previousProgress: p0.progress)
        let p2 = ZaloEngine.computeStage2BatchProgress(completedPartitionsBeforeChunk: 0, currentChunkPartitions: 30, totalPartitions: 90, batchesCompletedInChunk: 65, expectedBatchesInChunk: 65, previousProgress: p1.progress)
        let p3 = ZaloEngine.computeStage2BatchProgress(completedPartitionsBeforeChunk: 30, currentChunkPartitions: 30, totalPartitions: 90, batchesCompletedInChunk: 10, expectedBatchesInChunk: 20, previousProgress: p2.progress)
        let p4 = ZaloEngine.computeStage2BatchProgress(completedPartitionsBeforeChunk: 60, currentChunkPartitions: 30, totalPartitions: 90, batchesCompletedInChunk: 10, expectedBatchesInChunk: 10, previousProgress: p3.progress)

        #expect(p0.progress > 0.14 && p0.progress < p1.progress)
        #expect(p1.progress > 0.16 && p1.progress < p2.progress)
        #expect(p2.progress < p3.progress && p3.progress < p4.progress)
        #expect(abs(p4.progress - 0.72) < 0.0001)
    }

    @MainActor
    @Test func phoneSyncDiagnosticsAndWasmUnavailableMessaging() {
        let diag = ZaloPhoneSync.diagnostics()
        #expect((diag.wasmAvailable && diag.wasmBytes > 8) || (!diag.wasmAvailable && diag.wasmBytes == 0))
        #expect((diag.zstdAvailable && diag.zstdBackend != nil) || (!diag.zstdAvailable && diag.zstdBackend == nil))

        let blockedText = ZaloEngine.transferBlockedText("WASM_UNAVAILABLE")
        let errorText = ZaloEngine.transferErrorText(code: nil, name: "WASM_UNAVAILABLE")
        #expect(blockedText.contains("libzproto_wasm_bg.wasm"))
        #expect(errorText == blockedText)
    }

    @MainActor
    @Test func startTransferResetsAttemptedProfileUidsAndStage2Progress() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-reset-uids-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = ZaloEngine(dataDirectory: root, useKeychain: false)
        engine.syncAttemptedProfileUids = ["111", "222"]
        engine.syncStage2Progress = SyncStage2ProgressState(activeSyncId: "old", totalPartitions: 30, completedPartitionsBeforeChunk: 10, currentChunkPartitionCount: 20, chunkIndex: 1, totalChunks: 2, cumulativeMessagesBeforeChunk: 500, cumulativeConvIdsBeforeChunk: ["111"])

        engine.startTransfer(requestPhoneSync: false)
        #expect(engine.syncAttemptedProfileUids.isEmpty)
        #expect(engine.syncStage2Progress == SyncStage2ProgressState())
        engine.cancelTransfer()
    }
}
