import Foundation
import OlazCore
import Testing
@testable import Olaz

/// U9 parity & mirror tests:
/// 1. 421-item / 347-distinct-key collation corpus comparing `ZaloEngine.contactFold` & live
///    Foundation `String.localizedStandardCompare` against Rust `contactFoldFfi` & `localizedStandardCmpFfi`.
/// 2. O(1) `@MainActor` local mirror `lookupPersonInfo` & `mentionDisplayName` parity against
///    `CoreEngine`'s lock-free `IdentitySnapshot` across aliases, friends, `globalId`s, cached profiles,
///    conversations fallback, `u`-prefixes, `_<digits>` suffixes, and reactive mutations.
/// 3. `ZaloWireParser.normalizeContactUid` & `ZaloEngine+CardActions` item-6.1 UID normalization.
@Suite(.serialized) struct CoreContactsMirrorTests {
    private struct CorpusEntry: Decodable {
        let raw: String
        let folded: String
        let section: String
        let sortKey: String
    }

    private struct CollationCorpus: Decodable {
        let entries: [CorpusEntry]
        let friendSortedRawOrder: [Int]
        let sortedDistinctSortKeys: [String]
    }

    private static func computeSection(_ sortKey: String) -> String {
        guard let first = sortKey.unicodeScalars.first,
              (0x61...0x7A).contains(first.value) || (0x41...0x5A).contains(first.value) else {
            return "#"
        }
        return String(first).uppercased()
    }

    private static func sign(_ cmp: ComparisonResult) -> Int8 {
        switch cmp {
        case .orderedAscending: return -1
        case .orderedSame: return 0
        case .orderedDescending: return 1
        }
    }

    @Test func collationParityAgainstLiveFoundationAndGoldenCorpus() throws {
        let corpusURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("rust/crates/olaz-core/tests/fixtures/contact_collation_swift_corpus.json")
        let data = try Data(contentsOf: corpusURL)
        let corpus = try JSONDecoder().decode(CollationCorpus.self, from: data)
        #expect(corpus.entries.count >= 300)

        // 1. Fold, sortKey, and section parity across all 421 entries.
        for (idx, item) in corpus.entries.enumerated() {
            let swiftFold = ZaloEngine.contactFold(item.raw)
            let ffiFold = contactFoldFfi(text: item.raw)
            #expect(swiftFold == item.folded, "fold mismatch at #\(idx) raw=\(item.raw.debugDescription)")
            #expect(ffiFold == item.folded, "ffi fold mismatch at #\(idx) raw=\(item.raw.debugDescription)")

            let trimmedKey = swiftFold.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(trimmedKey == item.sortKey, "sortKey mismatch at #\(idx)")
            #expect(Self.computeSection(trimmedKey) == item.section, "section mismatch at #\(idx)")
        }

        // 2. Pairwise ordering parity across all 347 distinct sort keys vs live Foundation localizedStandardCompare.
        let keys = corpus.sortedDistinctSortKeys
        for i in 0..<keys.count {
            #expect(localizedStandardCmpFfi(a: keys[i], b: keys[i]) == 0)
            for j in (i + 1)..<keys.count {
                let foundationSign = Self.sign(keys[i].localizedStandardCompare(keys[j]))
                let rustSign = localizedStandardCmpFfi(a: keys[i], b: keys[j])
                #expect(
                    rustSign == -1,
                    "expected \(keys[i].debugDescription) < \(keys[j].debugDescription), got \(rustSign)"
                )
                #expect(
                    rustSign == foundationSign,
                    "Foundation vs Rust mismatch on (\(keys[i].debugDescription), \(keys[j].debugDescription)): foundation=\(foundationSign) rust=\(rustSign)"
                )
                #expect(localizedStandardCmpFfi(a: keys[j], b: keys[i]) == 1)
            }
        }

        // 3. Full friend-list sort order parity ('#' last, then localizedStandardCompare).
        var indices = Array(0..<corpus.entries.count)
        indices.sort { i, j in
            let a = corpus.entries[i]
            let b = corpus.entries[j]
            if a.section != b.section {
                if a.section == "#" { return false }
                if b.section == "#" { return true }
                return a.section < b.section
            }
            return localizedStandardCmpFfi(a: a.sortKey, b: b.sortKey) < 0
        }
        #expect(indices == corpus.friendSortedRawOrder)
    }

    @MainActor
    @Test func localMirrorLookupAndMentionParityWithCore() async throws {
        let myUid = "2000990"
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
                            "zpw_sek": .string("sek.contacts.mirror"),
                            "display_name": .string("Mirror Self"),
                            "send2me_id": .string("9200990"),
                            "zpw_ws": .array([.string("ws://fake")]),
                            "zpw_service_map_v3": .object([
                                "alias": .array([.string("http://fake")]),
                                "chat": .array([.string("http://fake")]),
                                "friend": .array([.string("http://fake")]),
                                "group": .array([.string("http://fake")]),
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
                            "displayName": .string("Mirror Self"),
                            "avatar": .string("https://cdn.example.invalid/me.jpg"),
                        ]),
                    ]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/social/friend/getfriends"),
                "response": .object([
                    "status": .int(200),
                    "json": .object([
                        "error_code": .int(0),
                        "data": .object([
                            "list": .array([
                                .object([
                                    "userId": .string("u3000901"),
                                    "zaloName": .string("Đào Anh"),
                                    "avatar": .string("https://cdn.example.invalid/f901.jpg"),
                                    "globalId": .string("gid_3000901"),
                                ]),
                                .object([
                                    "userId": .string("3000902"),
                                    "zaloName": .string("Ánh Tuyết"),
                                    "avatar": .string(""),
                                    "globalId": .string("gid_shared"),
                                ]),
                                .object([
                                    "userId": .string("3000903"),
                                    "zaloName": .string("Bình Minh"),
                                    "avatar": .string("https://cdn.example.invalid/f903.jpg"),
                                    "globalId": .string("gid_shared"),
                                ]),
                                .object([
                                    "userId": .string("3000904"),
                                    "zaloName": .string("Người dùng Zalo"),
                                    "avatar": .string(""),
                                ]),
                                .object([
                                    "userId": .string("3000905"),
                                    "zaloName": .string("Bạn"),
                                    "avatar": .string(""),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/group/getlg/v4"),
                "response": .object([
                    "status": .int(200),
                    "json": .object(["error_code": .int(0), "data": .object(["gridVerMap": .object([:])])]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/friend/requested/list"),
                "response": .object([
                    "status": .int(200),
                    "json": .object(["error_code": .int(0), "data": .object(["list": .array([])])]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/friend/recommendsv2/list"),
                "response": .object([
                    "status": .int(200),
                    "json": .object(["error_code": .int(0), "data": .object(["recommItems": .array([])])]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/alias/update"),
                "response": .object([
                    "status": .int(200),
                    "json": .object(["error_code": .int(0), "data": .object([:])]),
                ]),
            ]),
        ]

        let server = try FakeZaloServer(serverScript: serverScript, initialSecretKey: secretKey)
        try await server.start()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-u9-mirror-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let storage = RecorderStorageIsolation(prefix: "olaz.u9-mirror")
        defer {
            storage.cleanup()
            try? FileManager.default.removeItem(at: root)
        }

        let dbURL = root
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(myUid, isDirectory: true)
            .appendingPathComponent("history.sqlite3")
        let seedStore = try ZaloSQLiteStore(path: dbURL.path)
        try await seedStore.setPreferenceString(key: ZaloWebKitMigrator.donePrefKey, value: "1")
        let cachedProfilesSeed = #"{"3000902":{"name":"Profile Ánh","avatar":"https://cdn.example.invalid/p902.jpg"},"3000906":{"name":"Profile Stranger","avatar":"https://cdn.example.invalid/p906.jpg"}}"#
        try await seedStore.setPreferenceData(key: "cachedProfiles", data: Data(cachedProfilesSeed.utf8))
        try await seedStore.saveConversations([
            StoredConversation(
                id: "3000907",
                isGroup: false,
                name: "Conv Fallback Peer",
                avatar: "https://cdn.example.invalid/c907.jpg",
                pinned: false,
                members: 0,
                unread: 0,
                previewText: "Hello",
                previewTsMs: 1_700_000_000_000,
                previewFromMe: false,
                updatedAtMs: 1_700_000_000_000
            ),
        ])
        await seedStore.close()

        var domains = ZaloDomains()
        domains.auth = server.baseURLString
        domains.wpaChat = server.baseURLString
        domains.lpChat = server.baseURLString
        domains.lpControl = server.baseURLString
        domains.ws = [server.wsBaseURLString]
        domains.serviceCandidates = [
            "alias": [server.baseURLString],
            "chat": [server.baseURLString],
            "friend": [server.baseURLString],
            "group": [server.baseURLString],
            "profile": [server.baseURLString],
        ]
        domains.isolated = true

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
                    "alias": .array([.string(server.baseURLString)]),
                    "chat": .array([.string(server.baseURLString)]),
                    "friend": .array([.string(server.baseURLString)]),
                    "group": .array([.string(server.baseURLString)]),
                    "profile": .array([.string(server.baseURLString)]),
                ]),
                "preferredHosts": .object([:]),
                "isolated": .bool(true),
            ]),
            "sealedSecretsBase64": .null,
            "expiredAt": .null,
            "plainAccount": .object([
                "userId": .string(myUid),
                "displayName": .string("Mirror Self"),
                "avatar": .string("https://cdn.example.invalid/me.jpg"),
                "phone": .string(""),
                "send2MeId": .string("9200990"),
                "dkey": .string("dk-u9"),
                "zpwEnk": .string(testEnk),
                "zpwSek": .string("sek.contacts.mirror"),
            ]),
        ])
        try Data(savedSession.canonicalString().utf8)
            .write(to: root.appendingPathComponent("native-session.json"), options: .atomic)

        let engine = ZaloEngine(
            dataDirectory: root,
            useKeychain: false,
            domains: domains,
            userDefaultsSuiteName: storage.userDefaultsSuiteName,
            cookieStorage: storage.cookieStorage
        )
        engine.hostTrace = { name, _ in
            name == "prepare_store"
        }

        engine.start()
        _ = await engine.bootTask?.value
        await engine.performContactsSync()
        await engine.settleForRecording()

        let core = try #require(engine.coreLifecycle.core)
        let probes = [
            "", "0", "-1", "__legacy__", "unknown",
            myUid, "u\(myUid)", "\(myUid)_1",
            "3000901", "u3000901", "3000901_2", "gid_3000901",
            "3000902", "3000903", "gid_shared",
            "3000904", "3000905", "3000906", "3000907", "3000999",
        ]

        func assertAllProbesMatchCore(stage: String) {
            for q in probes {
                let localPerson = engine.lookupPersonInfo(q)
                let corePerson = core.lookupPersonInfo(uid: q)
                #expect(
                    localPerson?.name == corePerson?.name && localPerson?.avatar == corePerson?.avatar,
                    "[\(stage)] lookupPersonInfo(\(q.debugDescription)) local=\(String(describing: localPerson)) vs core=\(String(describing: corePerson))"
                )

                let localMention = engine.mentionDisplayName(q)
                let coreMention = core.mentionDisplayName(uid: q)
                #expect(
                    localMention == coreMention,
                    "[\(stage)] mentionDisplayName(\(q.debugDescription)) local=\(String(describing: localMention)) vs core=\(String(describing: coreMention))"
                )
            }
        }

        assertAllProbesMatchCore(stage: "after_sync")

        // Save an alias via u-prefixed UID and verify both mirror and core stay 100% aligned.
        let aliasRes = await engine.saveAlias(uid: "u3000901", name: "Biệt Danh Đào")
        #expect(aliasRes.ok)
        #expect(engine.lookupPersonInfo("3000901")?.name == "Biệt Danh Đào")
        #expect(engine.lookupPersonInfo("gid_3000901")?.name == "Biệt Danh Đào")
        #expect(engine.mentionDisplayName("u3000901") == "Biệt Danh Đào")
        assertAllProbesMatchCore(stage: "after_alias")

        // Verify CardActions UID normalization (item 6.1) on the live booted engine.
        engine.contacts.sent = [
            ContactsState.FriendRequest(id: "3000950", name: "Sent Peer", avatar: nil, message: "Hi", date: nil),
        ]
        engine.contacts.received = [
            ContactsState.FriendRequest(id: "3000951", name: "Recv Peer", avatar: nil, message: "Yo", date: nil),
        ]

        let selfState = await engine.contactCardState("u\(myUid)")
        #expect(selfState.isSelf && !selfState.isFriend)

        let friendState = await engine.contactCardState("u3000901")
        #expect(!friendState.isSelf && friendState.isFriend)

        let friendProfile = await engine.contactProfile("u3000901")
        #expect(friendProfile?.uid == "3000901")
        #expect(friendProfile?.name == "Đào Anh")
        #expect(friendProfile?.isFriend == true)

        let prepMe = await engine.prepareFriendRequest(to: "u\(myUid)", from: "3000901", via: .card)
        #expect(prepMe.state == .me)
        let prepFriend = await engine.prepareFriendRequest(to: "u3000901", from: "3000901", via: .card)
        #expect(prepFriend.state == .friend)
        let prepSent = await engine.prepareFriendRequest(to: "u3000950", from: "3000901", via: .add)
        #expect(prepSent.state == .requested)
        let prepRecv = await engine.prepareFriendRequest(to: "u3000951", from: "3000901", via: .add)
        #expect(prepRecv.state == .requesting)
        let prepReady = await engine.prepareFriendRequest(to: "u3000998", from: "3000901", via: .none)
        #expect(prepReady.state == .ready)

        engine.cancelTasksForRecording()
        server.stop()
        await engine.finishTearDownForRecording()
    }

    @Test func normalizeContactUidEdgeCases() {
        #expect(ZaloWireParser.normalizeContactUid("u3000901") == "3000901")
        #expect(ZaloWireParser.normalizeContactUid("  u2000111  ") == "2000111")
        #expect(ZaloWireParser.normalizeContactUid("u123456789012345678901234") == "123456789012345678901234")
        #expect(ZaloWireParser.normalizeContactUid("u1234567890123456789012345") == "u1234567890123456789012345")
        // Intentionally preserves _<digits> suffixes where only sanitizeProfileUid strips them.
        #expect(ZaloWireParser.normalizeContactUid("u3000901_2") == "u3000901_2")
        #expect(ZaloWireParser.normalizeContactUid("3000901_15") == "3000901_15")
        #expect(ZaloWireParser.normalizeContactUid("u_abc") == "u_abc")
        #expect(ZaloWireParser.normalizeContactUid("unknown") == "unknown")
        #expect(ZaloWireParser.normalizeContactUid("u0") == "u0")
        #expect(ZaloWireParser.normalizeContactUid("u000") == "u000")
        #expect(ZaloWireParser.normalizeContactUid("g500101") == "g500101")
    }

    @MainActor
    @Test func aliasEntryPointVisibilityAndPropagationAcrossChatListHeaderAndMentions() async throws {
        await RecorderSuiteLock.shared.acquire()
        defer { Task { await RecorderSuiteLock.shared.release() } }

        let myUid = "2000991"
        let selfConvId = "9200991"
        let friendUid = "3000911"
        let strangerUid = "3000999"
        let groupId = "g500111"
        let cleanGroupId = "500111"
        let testEnk = "0123456789abcdef"
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
                            "display_name": .string("Alias Self"),
                            "avatar": .string("https://cdn.example.invalid/self.jpg"),
                            "send2me_id": .string(selfConvId),
                            "zpw_enk": .string(testEnk),
                            "zpw_sek": .string("sek.alias.entry"),
                            "dkey": .string("dk-alias"),
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
                            "profile": .object([
                                "userId": .string(myUid),
                                "displayName": .string("Alias Self"),
                                "avatar": .string("https://cdn.example.invalid/self.jpg"),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/social/friend/getfriends"),
                "response": .object([
                    "status": .int(200),
                    "json": .object([
                        "error_code": .int(0),
                        "data": .array([
                            .object([
                                "userId": .string(friendUid),
                                "displayName": .string("Minh An"),
                                "zaloName": .string("Minh An Zalo"),
                                "avatar": .string("https://cdn.example.invalid/a911.jpg"),
                                "lastActionTime": .int(1_700_000_000_000),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/group/getlg/v4"),
                "response": .object([
                    "status": .int(200),
                    "json": .object([
                        "error_code": .int(0),
                        "data": .object(["gridVerMap": .object([cleanGroupId: .string("1")])]),
                    ]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/group/getmg-v2"),
                "response": .object([
                    "status": .int(200),
                    "json": .object([
                        "error_code": .int(0),
                        "data": .object([
                            "gridInfoMap": .object([
                                cleanGroupId: .object([
                                    "groupId": .string(cleanGroupId),
                                    "name": .string("Nhóm Dự Án"),
                                    "totalMember": .int(2),
                                    "memIds": .array([.string(myUid), .string(friendUid)]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/social/group/members"),
                "response": .object([
                    "status": .int(200),
                    "json": .object([
                        "error_code": .int(0),
                        "data": .object([
                            "profiles": .object([
                                friendUid: .object([
                                    "uid": .string(friendUid),
                                    "displayName": .string("Minh An"),
                                    "zaloName": .string("Minh An Zalo"),
                                    "avatar": .string("https://cdn.example.invalid/a911.jpg"),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/alias/list"),
                "response": .object([
                    "status": .int(200),
                    "json": .object(["error_code": .int(0), "data": .object(["items": .array([])])]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/friend/requested/list"),
                "response": .object([
                    "status": .int(200),
                    "json": .object(["error_code": .int(0), "data": .object(["list": .array([])])]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/friend/recommendsv2/list"),
                "response": .object([
                    "status": .int(200),
                    "json": .object(["error_code": .int(0), "data": .object(["recommItems": .array([])])]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/alias/update"),
                "response": .object([
                    "status": .int(200),
                    "json": .object(["error_code": .int(0), "data": .object([:])]),
                ]),
            ]),
            .object([
                "kind": .string("http"),
                "path": .string("/api/alias/remove"),
                "response": .object([
                    "status": .int(200),
                    "json": .object(["error_code": .int(0), "data": .object([:])]),
                ]),
            ]),
        ]

        let server = try FakeZaloServer(serverScript: serverScript, initialSecretKey: secretKey)
        try await server.start()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-alias-entry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let storage = RecorderStorageIsolation(prefix: "olaz.alias-entry")
        defer {
            storage.cleanup()
            try? FileManager.default.removeItem(at: root)
        }

        let dbURL = root
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(myUid, isDirectory: true)
            .appendingPathComponent("history.sqlite3")
        let seedStore = try ZaloSQLiteStore(path: dbURL.path)
        try await seedStore.setPreferenceString(key: ZaloWebKitMigrator.donePrefKey, value: "1")
        try await seedStore.saveConversations([
            StoredConversation(
                id: friendUid,
                isGroup: false,
                name: "Minh An",
                avatar: "https://cdn.example.invalid/a911.jpg",
                pinned: false,
                members: 0,
                unread: 0,
                previewText: "Chào bạn",
                previewTsMs: 1_700_000_000_000,
                previewFromMe: false,
                updatedAtMs: 1_700_000_000_000
            ),
            StoredConversation(
                id: groupId,
                isGroup: true,
                name: "Nhóm Dự Án",
                avatar: "",
                pinned: false,
                members: 2,
                unread: 0,
                previewText: "",
                previewTsMs: 1_700_000_000_000,
                previewFromMe: false,
                updatedAtMs: 1_700_000_000_000
            ),
            StoredConversation(
                id: strangerUid,
                isGroup: false,
                name: "Người Lạ",
                avatar: "",
                pinned: false,
                members: 0,
                unread: 0,
                previewText: "Xin chào",
                previewTsMs: 1_700_000_000_000,
                previewFromMe: false,
                updatedAtMs: 1_700_000_000_000
            ),
        ])
        await seedStore.close()

        var domains = ZaloDomains()
        domains.auth = server.baseURLString
        domains.wpaChat = server.baseURLString
        domains.lpChat = server.baseURLString
        domains.lpControl = server.baseURLString
        domains.ws = [server.wsBaseURLString]
        domains.serviceCandidates = [
            "alias": [server.baseURLString],
            "chat": [server.baseURLString],
            "friend": [server.baseURLString],
            "group": [server.baseURLString],
            "profile": [server.baseURLString],
        ]
        domains.isolated = true

        let savedSession: CaseJSON = .object([
            "zpwType": .string(ZaloDomains.zpwType),
            "imei": .string("00000000-0000-4000-8000-000000000000-00000000000000000000000000000000"),
            "computerName": .string("AliasMac"),
            "domains": .object([
                "auth": .string(server.baseURLString),
                "wpaChat": .string(server.baseURLString),
                "lpChat": .string(server.baseURLString),
                "lpControl": .string(server.baseURLString),
                "ws": .array([.string(server.wsBaseURLString)]),
                "serviceCandidates": .object([
                    "alias": .array([.string(server.baseURLString)]),
                    "chat": .array([.string(server.baseURLString)]),
                    "friend": .array([.string(server.baseURLString)]),
                    "group": .array([.string(server.baseURLString)]),
                    "profile": .array([.string(server.baseURLString)]),
                ]),
                "preferredHosts": .object([:]),
                "isolated": .bool(true),
            ]),
            "sealedSecretsBase64": .null,
            "expiredAt": .null,
            "plainAccount": .object([
                "userId": .string(myUid),
                "displayName": .string("Alias Self"),
                "avatar": .string("https://cdn.example.invalid/self.jpg"),
                "phone": .string(""),
                "send2MeId": .string(selfConvId),
                "dkey": .string("dk-alias"),
                "zpwEnk": .string(testEnk),
                "zpwSek": .string("sek.alias.entry"),
            ]),
        ])
        try Data(savedSession.canonicalString().utf8)
            .write(to: root.appendingPathComponent("native-session.json"), options: .atomic)

        let engine = ZaloEngine(
            dataDirectory: root,
            useKeychain: false,
            domains: domains,
            userDefaultsSuiteName: storage.userDefaultsSuiteName,
            cookieStorage: storage.cookieStorage
        )
        engine.hostTrace = { name, _ in
            name == "prepare_store"
        }

        engine.start()
        _ = await engine.bootTask?.value
        await engine.performContactsSync()
        await engine.settleForRecording()

        // Open the 1-1 chat so chat header mirrors the active conversation.
        engine.openConversation(friendUid)
        #expect(engine.openConversationId == friendUid)

        // 1. Menu visibility rules on the booted engine.
        #expect(engine.canEditAlias(for: friendUid))
        #expect(!engine.canEditAlias(for: groupId))
        #expect(!engine.canEditAlias(for: myUid))
        #expect(!engine.canEditAlias(for: selfConvId))
        #expect(!engine.canEditAlias(for: strangerUid))
        #expect(!engine.canEditAlias(for: friendUid, isOfficialAccount: true))

        // Initial draft has no alias yet.
        let initialDraft = engine.aliasDraft(for: friendUid)
        #expect(initialDraft.uid == friendUid)
        #expect(initialDraft.name == "Minh An Zalo")
        #expect(initialDraft.suggest.isEmpty)
        #expect(initialDraft.hasAlias == false)
        #expect(initialDraft.max == AliasDraft.fallbackMax)

        // Prime mention candidates in the group before setting the alias.
        let initialMentions = await engine.mentionCandidates(in: groupId, query: "")
        #expect(initialMentions.first { $0.id == friendUid }?.name == "Minh An Zalo")
        #expect(engine.conversations.first { $0.id == friendUid }?.displayName == "Minh An Zalo")

        // 2. Save a new alias and verify chat list, chat header, mention suggestions, and draft all update.
        let saveRes = await engine.saveAlias(uid: friendUid, name: "Anh Minh Dự Án")
        #expect(saveRes.ok)

        // Chat list row name
        #expect(engine.conversations.first { $0.id == friendUid }?.displayName == "Anh Minh Dự Án")
        // Open chat header name (ChatView / ChatHeaderTitle reads the active ConversationSummary)
        let headerConv = engine.conversations.first { $0.id == engine.openConversationId }
        #expect(headerConv?.displayName == "Anh Minh Dự Án")
        // Contact profile / list live display name
        #expect(engine.aliasDisplayName(for: friendUid, fallback: "Minh An") == "Anh Minh Dự Án")
        // Mention suggestions & search filtering in group chat
        let updatedMentions = await engine.mentionCandidates(in: groupId, query: "")
        #expect(updatedMentions.first { $0.id == friendUid }?.name == "Anh Minh Dự Án")
        let filteredByAlias = await engine.mentionCandidates(in: groupId, query: "du an")
        #expect(filteredByAlias.map { $0.id } == [friendUid])
        // Draft now reflects existing alias
        let editDraft = engine.aliasDraft(for: friendUid)
        #expect(editDraft.hasAlias == true)
        #expect(editDraft.suggest == "Anh Minh Dự Án")

        // 3. Remove the alias (empty string) and verify chat list, chat header, and mention suggestions revert.
        let removeRes = await engine.saveAlias(uid: friendUid, name: "")
        #expect(removeRes.ok)
        #expect(engine.conversations.first { $0.id == friendUid }?.displayName == "Minh An Zalo")
        #expect(engine.conversations.first { $0.id == engine.openConversationId }?.displayName == "Minh An Zalo")
        #expect(engine.aliasDisplayName(for: friendUid, fallback: "Minh An") == "Minh An")
        let revertedMentions = await engine.mentionCandidates(in: groupId, query: "")
        #expect(revertedMentions.first { $0.id == friendUid }?.name == "Minh An Zalo")
        #expect(engine.aliasDraft(for: friendUid).hasAlias == false)

        engine.cancelTasksForRecording()
        server.stop()
        await engine.finishTearDownForRecording()
    }
}
