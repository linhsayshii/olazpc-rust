import Foundation
import OlazCore
import Testing
@testable import Olaz

/// U10 groups mirror, PR #29 non-bounce, and constraint (c) trace-only notice tests.
@Suite(.serialized) struct CoreGroupsMirrorTests {
    private static func emptyChanges(
        version: UInt64,
        groups: GroupsStateRecord? = nil
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
            groups: groups,
            typing: nil,
            forwardRequest: nil,
            clearSelection: false,
            deleteUndo: nil,
            messageConfirm: nil,
            autoDelete: nil,
            starredIds: nil,
            cachedProfiles: nil,
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
    @Test func groupsMirrorUpdatesStateAndPreservesNonGroupNavigationRequest() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-u10-mirror-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = ZaloEngine(dataDirectory: dir, useKeychain: false)
        // Non-group navigation request already pending in Swift.
        engine.navigationRequest = "2000101"

        let gRec1 = GroupsStateRecord(
            detailsJson: [
                StringPairEntry(
                    key: "500100",
                    value: #"{"creatorId":"100","adminIds":["200"],"setting":{"joinAppr":1},"memVerList":["100_0","200_1"]}"#
                ),
            ],
            memberCache: [
                GroupMemberCacheEntry(
                    groupId: "g500100",
                    members: [
                        MentionCandidateRecord(id: "-1", name: "All", avatar: nil, isAll: true),
                        MentionCandidateRecord(id: "200", name: "An", avatar: "https://cdn.example.invalid/a.jpg", isAll: false),
                    ]
                ),
            ],
            cachedGroups: [
                CachedGroupEntry(gid: "g500100", name: "Team Rust", avatar: "https://cdn.example.invalid/g.jpg", members: 2),
            ],
            navigationRequest: nil
        )
        engine.applyCoreChanges(Self.emptyChanges(version: 1, groups: gRec1))

        #expect(engine.cachedGroupDetails["500100"] != nil)
        #expect(engine.groupMemberCache["g500100"]?.map(\.id) == ["-1", "200"])
        #expect(engine.cachedGroups["g500100"]?.name == "Team Rust")
        #expect(engine.cachedGroups["g500100"]?.members == 2)
        // Non-group navigationRequest must survive a groups mirror with navigationRequest == nil.
        #expect(engine.navigationRequest == "2000101")
        #expect(engine.groupRoles("g500100") == GroupRoles(owner: "100", admins: ["200"], joinApproval: true))
        #expect(engine.groupMemberIds(in: "g500100") == ["100", "200"])

        // When core requests navigation to a newly created group, Swift mirrors it.
        let gRec2 = GroupsStateRecord(
            detailsJson: gRec1.detailsJson,
            memberCache: gRec1.memberCache,
            cachedGroups: gRec1.cachedGroups,
            navigationRequest: "g500999"
        )
        engine.applyCoreChanges(Self.emptyChanges(version: 2, groups: gRec2))
        #expect(engine.navigationRequest == "g500999")
        #expect(engine.lastMirroredGroupNavigationRequest == "g500999")

        // Consuming navigationRequest in UI clears lastMirroredGroupNavigationRequest so a subsequent
        // request to the same group will still apply.
        engine.navigationRequest = nil
        #expect(engine.lastMirroredGroupNavigationRequest == nil)
    }

    @MainActor
    @Test func groupsMirrorUpdatesIdentityPushKeyWithoutBouncing() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-u10-nonbounce-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = ZaloEngine(dataDirectory: dir, useKeychain: false)
        guard let core = await engine.ensureCoreEngine() else {
            Issue.record("expected live CoreEngine")
            return
        }
        defer { engine.stopCoreEngine() }

        var pushCount = 0
        engine.onCoreUpdateIdentities = { pushCount += 1 }

        let gRec = GroupsStateRecord(
            detailsJson: [],
            memberCache: [],
            cachedGroups: [
                CachedGroupEntry(gid: "g500200", name: "Coalesced Group", avatar: "", members: 4),
            ],
            navigationRequest: nil
        )
        engine.applyCoreChanges(Self.emptyChanges(version: 10, groups: gRec))
        #expect(engine.cachedGroups["g500200"]?.name == "Coalesced Group")
        #expect(pushCount == 0)

        // Calling sendIdentitiesToCore without force must see the updated key and stay silent (PR #29).
        engine.sendIdentitiesToCore(core, force: false)
        #expect(pushCount == 0)
    }

    @MainActor
    @Test func hostHandleGroupNoticeIsTraceOnly() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-u10-traceonly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = ZaloEngine(dataDirectory: dir, useKeychain: false)
        engine.cachedGroupDetails["500300"] = ["name": "Old"]
        engine.groupMemberCache["g500300"] = [
            MentionCandidate(id: "-1", name: "All", avatar: nil, isAll: true),
        ]

        var tracedCalls: [String] = []
        engine.traceU4HostEnabled = true
        engine.hostTrace = { name, _ in
            tracedCalls.append(name)
            return true
        }

        await engine.hostHandleGroupNotice(
            act: "join",
            dataBox: ZaloJSONBox([
                "groupId": "500300",
                "sourceId": "200",
                "updateMembers": [["id": "300", "dName": "Lan"]],
            ]),
            ts: 1_700_000_000_000
        )

        #expect(tracedCalls == ["group_notice"])
        // Constraint (c): no Swift-side state mutation from HostCall::GroupNotice.
        #expect(engine.messages["g500300"] == nil)
        #expect(engine.cachedGroupDetails["500300"] != nil)
        #expect(engine.groupMemberCache["g500300"]?.count == 1)
    }
}
