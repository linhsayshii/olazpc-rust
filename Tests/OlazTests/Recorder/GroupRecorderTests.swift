import Foundation
import XCTest
@testable import Olaz

final class GroupRecorderTests: XCTestCase {
    func testGroupScenarios() async throws {
        try await GroupRecorderHarness.runDomain(
            domain: "groups",
            scenarios: Self.groupScenarios()
        )
    }

    // MARK: - Helpers

    private static func emptySyncScripts(
        friends: [CaseJSON]? = nil,
        groupsVerMap: [String: CaseJSON]? = nil,
        removedGroups: [String] = [],
        groupsInfoMap: [String: CaseJSON]? = nil
    ) -> [CaseJSON] {
        var scripts: [CaseJSON] = [
            GroupRecorderHarness.httpScript(
                path: "/api/social/friend/getfriends",
                method: "GET",
                json: .object([
                    "error_code": .int(0),
                    "data": .object(["list": .array(friends ?? [])]),
                ])
            ),
        ]
        let verMap = groupsVerMap ?? [:]
        var dataObj: [String: CaseJSON] = ["gridVerMap": .object(verMap)]
        if !removedGroups.isEmpty {
            dataObj["removedsGroup"] = .array(removedGroups.map(CaseJSON.string))
        }
        scripts.append(GroupRecorderHarness.httpScript(
            path: "/api/group/getlg/v4",
            method: "GET",
            json: .object(["error_code": .int(0), "data": .object(dataObj)])
        ))
        let activeIds = verMap.keys.filter { !removedGroups.contains($0) }
        if !activeIds.isEmpty {
            scripts.append(GroupRecorderHarness.httpScript(
                path: "/api/group/getmg-v2",
                method: "POST",
                json: .object([
                    "error_code": .int(0),
                    "data": .object(["gridInfoMap": .object(groupsInfoMap ?? [:])]),
                ])
            ))
        }
        scripts.append(GroupRecorderHarness.httpScript(
            path: "/api/friend/requested/list",
            method: "GET",
            json: .object([
                "error_code": .int(0),
                "data": .object(["list": .array([])]),
            ])
        ))
        scripts.append(GroupRecorderHarness.httpScript(
            path: "/api/friend/recommendsv2/list",
            method: "GET",
            json: .object([
                "error_code": .int(0),
                "data": .object(["recommItems": .array([])]),
            ])
        ))
        return scripts
    }

    private static func localConv(
        id: String,
        isGroup: Bool = true,
        name: String,
        avatar: String = "",
        pinned: Bool = false,
        members: Int64 = 0,
        unread: Int64 = 0,
        previewText: String = "",
        previewTsMs: Int64 = 0,
        previewFromMe: Bool = false
    ) -> CaseJSON {
        .object([
            "id": .string(id),
            "is_group": .bool(isGroup),
            "name": .string(name),
            "avatar": .string(avatar),
            "pinned": .bool(pinned),
            "members": .int(members),
            "unread": .int(unread),
            "preview_text": .string(previewText),
            "preview_ts_ms": .int(previewTsMs),
            "preview_from_me": .bool(previewFromMe),
        ])
    }

    private static func seedFriend(id: String, name: String, avatar: String? = nil) -> CaseJSON {
        .object([
            "id": .string(id),
            "name": .string(name),
            "zalo_name": .string(name),
            "avatar": avatar.map(CaseJSON.string) ?? .null,
            "last_active_ms": .null,
            "online": .bool(false),
            "section": .string(String(name.prefix(1)).uppercased()),
            "sort_key": .string(name.lowercased()),
        ])
    }

    private static func seedGroup(id: String, name: String, avatar: String? = nil, members: Int64) -> CaseJSON {
        .object([
            "id": .string(id),
            "name": .string(name),
            "avatar": avatar.map(CaseJSON.string) ?? .null,
            "members": .int(members),
            "sort_key": .string(name.lowercased()),
        ])
    }

    private static func sampleJpegBase64() -> String {
        // Minimal deterministic synthetic JPEG header+payload bytes for avatar upload tests.
        let bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0xFF, 0xD9]
        return Data(bytes).base64EncodedString()
    }

    private static func groupScenarios() -> [GroupRecorderHarness.ScenarioDef] {
        [
            // 1. create_ok
            GroupRecorderHarness.ScenarioDef(
                name: "create_ok",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2001001",
                    displayName: "Groups User",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(7001001),
                        "contacts": .object([
                            "friends": .array([
                                seedFriend(id: "3001001", name: "An Nguyễn"),
                                seedFriend(id: "3001002", name: "Bình Trần"),
                            ]),
                            "friends_loaded": .bool(true),
                            "groups_loaded": .bool(true),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2001001", displayName: "Groups User"),
                    MessageRecorderHarness.profileMeScript(uid: "2001001", displayName: "Groups User"),
                    // 1st create_group: trimmed name with spaces, members with u-prefix, me omitted
                    GroupRecorderHarness.httpScript(
                        path: "/api/group/create/v2",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "groupId": .string("500101"),
                            ]),
                        ])
                    ),
                    GroupRecorderHarness.httpScript(
                        path: "/api/group/getmg-v2",
                        method: "POST",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "gridInfoMap": .object([
                                    "500101": .object([
                                        "groupId": .string("500101"),
                                        "name": .string("Nhóm Dự Án"),
                                        "creatorId": .string("2001001"),
                                        "memIds": .array([.string("2001001"), .string("3001001"), .string("3001002")]),
                                        "totalMember": .int(3),
                                    ]),
                                ]),
                            ]),
                        ])
                    ),
                ] + emptySyncScripts(
                    friends: [
                        .object(["userId": .string("3001001"), "displayName": .string("An Nguyễn"), "zaloName": .string("An Nguyễn")]),
                        .object(["userId": .string("3001002"), "displayName": .string("Bình Trần"), "zaloName": .string("Bình Trần")]),
                    ],
                    groupsVerMap: ["500101": .int(1)],
                    groupsInfoMap: [
                        "500101": .object([
                            "groupId": .string("500101"),
                            "name": .string("Nhóm Dự Án"),
                            "creatorId": .string("2001001"),
                            "memIds": .array([.string("2001001"), .string("3001001"), .string("3001002")]),
                            "totalMember": .int(3),
                        ]),
                    ]
                ) + [
                    // 2nd create_group: whitespace-only name -> "Nhóm" fallback; getmg-v2 returns empty -> initial metadata kept
                    GroupRecorderHarness.httpScript(
                        path: "/api/group/create/v2",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "groupId": .string("g500102"),
                            ]),
                        ])
                    ),
                    GroupRecorderHarness.httpScript(
                        path: "/api/group/getmg-v2",
                        method: "POST",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object(["gridInfoMap": .object([:])]),
                        ])
                    ),
                ] + emptySyncScripts(
                    friends: [
                        .object(["userId": .string("3001001"), "displayName": .string("An Nguyễn"), "zaloName": .string("An Nguyễn")]),
                        .object(["userId": .string("3001002"), "displayName": .string("Bình Trần"), "zaloName": .string("Bình Trần")]),
                    ],
                    groupsVerMap: ["500101": .int(1), "500102": .int(1)],
                    groupsInfoMap: [
                        "500101": .object([
                            "groupId": .string("500101"),
                            "name": .string("Nhóm Dự Án"),
                            "creatorId": .string("2001001"),
                            "memIds": .array([.string("2001001"), .string("3001001"), .string("3001002")]),
                            "totalMember": .int(3),
                        ]),
                        "500102": .object([
                            "groupId": .string("500102"),
                            "name": .string("Nhóm"),
                            "creatorId": .string("2001001"),
                            "memIds": .array([.string("2001001"), .string("3001001")]),
                            "totalMember": .int(2),
                        ]),
                    ]
                ),
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")])]),
                    .object([
                        "cmd": .string("create_group"),
                        "now_ms": .int(1700010001000),
                        "args": .object([
                            "name": .string("  Nhóm Dự Án  "),
                            "members": .array([.string("u3001001"), .string("3001002")]),
                            "avatar": .null,
                        ]),
                    ]),
                    .object(["snapshot": .string("after_named_group")]),
                    .object([
                        "cmd": .string("create_group"),
                        "now_ms": .int(1700010002000),
                        "args": .object([
                            "name": .string("   "),
                            "members": .array([.string("3001001")]),
                            "avatar": .null,
                        ]),
                    ]),
                ]
            ),

            // 2. create_rejected_and_avatar
            GroupRecorderHarness.ScenarioDef(
                name: "create_rejected_and_avatar",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2001001",
                    displayName: "Groups User",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "next_client_id": .int(7002001),
                        "contacts": .object([
                            "friends": .array([
                                seedFriend(id: "3001001", name: "An"),
                                seedFriend(id: "3001002", name: "Bình"),
                                seedFriend(id: "3001003", name: "Chi"),
                            ]),
                            "friends_loaded": .bool(true),
                            "groups_loaded": .bool(true),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2001001", displayName: "Groups User"),
                    MessageRecorderHarness.profileMeScript(uid: "2001001", displayName: "Groups User"),
                    // Step A: 4 rejected members (>3 -> "và 1 người khác") + avatar upload succeeds
                    GroupRecorderHarness.httpScript(
                        path: "/api/group/create/v2",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "groupId": .string("500201"),
                                "rejectedMembers": .array([
                                    .string("3001001"),
                                    .string("3001002"),
                                    .string("3001004"), // unknown -> "Người dùng Zalo"
                                    .string("3001003"),
                                ]),
                            ]),
                        ])
                    ),
                    GroupRecorderHarness.httpScript(
                        path: "/api/group/upavatar",
                        method: "POST",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "avatar": .string("https://cdn.example.invalid/grp_500201.jpg"),
                            ]),
                        ])
                    ),
                    GroupRecorderHarness.httpScript(
                        path: "/api/group/getmg-v2",
                        method: "POST",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "gridInfoMap": .object([
                                    "500201": .object([
                                        "groupId": .string("500201"),
                                        "name": .string("Nhóm Avatar OK"),
                                        "avt": .string("https://cdn.example.invalid/grp_500201.jpg"),
                                        "memIds": .array([.string("2001001"), .string("3001005")]),
                                        "totalMember": .int(2),
                                    ]),
                                ]),
                            ]),
                        ])
                    ),
                ] + emptySyncScripts(
                    friends: [
                        .object(["userId": .string("3001001"), "displayName": .string("An"), "zaloName": .string("An")]),
                        .object(["userId": .string("3001002"), "displayName": .string("Bình"), "zaloName": .string("Bình")]),
                        .object(["userId": .string("3001003"), "displayName": .string("Chi"), "zaloName": .string("Chi")]),
                    ]
                ) + [
                    // Step B: avatar failure alone
                    GroupRecorderHarness.httpScript(
                        path: "/api/group/create/v2",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object(["groupId": .string("500202")]),
                        ])
                    ),
                    GroupRecorderHarness.httpScript(
                        path: "/api/group/upavatar",
                        method: "POST",
                        status: 500,
                        json: .object(["error_code": .int(500), "error_message": .string("Upload failed")])
                    ),
                    GroupRecorderHarness.httpScript(
                        path: "/api/group/getmg-v2",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["gridInfoMap": .object([:])])])
                    ),
                ] + emptySyncScripts(
                    friends: [
                        .object(["userId": .string("3001001"), "displayName": .string("An"), "zaloName": .string("An")]),
                        .object(["userId": .string("3001002"), "displayName": .string("Bình"), "zaloName": .string("Bình")]),
                        .object(["userId": .string("3001003"), "displayName": .string("Chi"), "zaloName": .string("Chi")]),
                    ]
                ) + [
                    // Step C: both some rejected + avatar failure
                    GroupRecorderHarness.httpScript(
                        path: "/api/group/create/v2",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object([
                                "groupId": .string("500203"),
                                "rejectedMembers": .array([.string("3001001"), .string("3001004")]),
                            ]),
                        ])
                    ),
                    GroupRecorderHarness.httpScript(
                        path: "/api/group/upavatar",
                        method: "POST",
                        status: 500,
                        json: .object(["error_code": .int(500), "error_message": .string("Upload failed")])
                    ),
                    GroupRecorderHarness.httpScript(
                        path: "/api/group/getmg-v2",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object(["gridInfoMap": .object([:])])])
                    ),
                ] + emptySyncScripts(),
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")])]),
                    .object([
                        "cmd": .string("create_group"),
                        "now_ms": .int(1700010011000),
                        "args": .object([
                            "name": .string("Nhóm Avatar OK"),
                            "members": .array([.string("3001001"), .string("3001002"), .string("3001003"), .string("3001004"), .string("3001005")]),
                            "avatar": .object(["jpeg_b64": .string(sampleJpegBase64()), "side": .int(240)]),
                        ]),
                    ]),
                    .object(["snapshot": .string("rejected_and_avatar_ok")]),
                    .object([
                        "cmd": .string("create_group"),
                        "now_ms": .int(1700010012000),
                        "args": .object([
                            "name": .string("Nhóm Avatar Fail"),
                            "members": .array([.string("3001005")]),
                            "avatar": .object(["jpeg_b64": .string(sampleJpegBase64()), "side": .int(240)]),
                        ]),
                    ]),
                    .object(["snapshot": .string("avatar_fail_alone")]),
                    .object([
                        "cmd": .string("create_group"),
                        "now_ms": .int(1700010013000),
                        "args": .object([
                            "name": .string("Nhóm Both Fail"),
                            "members": .array([.string("3001001"), .string("3001004"), .string("3001005")]),
                            "avatar": .object(["jpeg_b64": .string(sampleJpegBase64()), "side": .int(240)]),
                        ]),
                    ]),
                ]
            ),

            // 3. create_fail
            GroupRecorderHarness.ScenarioDef(
                name: "create_fail",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2001001",
                    displayName: "Groups User",
                    suppress: ["ws", "long_poll"],
                    extras: ["next_client_id": .int(7003001)]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2001001", displayName: "Groups User"),
                    MessageRecorderHarness.profileMeScript(uid: "2001001", displayName: "Groups User"),
                    GroupRecorderHarness.httpScript(
                        path: "/api/group/create/v2",
                        method: "GET",
                        status: 500,
                        json: .object(["error_code": .int(500), "error_message": .string("Create failed")])
                    ),
                    GroupRecorderHarness.httpScript(
                        path: "/api/group/create/v2",
                        method: "GET",
                        json: .object([
                            "error_code": .int(0),
                            "data": .object(["groupId": .string("")]),
                        ])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")])]),
                    .object([
                        "cmd": .string("create_group"),
                        "args": .object([
                            "name": .string("Nhóm Lỗi API"),
                            "members": .array([.string("3001001")]),
                            "avatar": .null,
                        ]),
                    ]),
                    .object(["snapshot": .string("after_api_error")]),
                    .object([
                        "cmd": .string("create_group"),
                        "args": .object([
                            "name": .string("Nhóm Empty ID"),
                            "members": .array([.string("3001001")]),
                            "avatar": .null,
                        ]),
                    ]),
                ]
            ),

            // 4. rename
            GroupRecorderHarness.ScenarioDef(
                name: "rename",
                seed: MessageRecorderHarness.readySessionSeed(
                    userId: "2001001",
                    displayName: "Groups User",
                    suppress: ["ws", "long_poll"],
                    extras: [
                        "local_conversations": .array([
                            localConv(id: "g500401", name: "Nhóm Cũ", members: 3),
                        ]),
                        "contacts": .object([
                            "groups": .array([
                                seedGroup(id: "g500401", name: "Nhóm Cũ", members: 3),
                            ]),
                            "cached_groups": .object([
                                "g500401": .object(["name": .string("Nhóm Cũ"), "avatar": .string(""), "members": .int(3)]),
                            ]),
                            "friends_loaded": .bool(true),
                            "groups_loaded": .bool(true),
                        ]),
                        "cached_group_details": .object([
                            "500401": .object([
                                "groupId": .string("500401"),
                                "name": .string("Nhóm Cũ"),
                                "creatorId": .string("2001001"),
                                "totalMember": .int(3),
                            ]),
                        ]),
                    ]
                ),
                server: [
                    MessageRecorderHarness.loginInfoScript(uid: "2001001", displayName: "Groups User"),
                    MessageRecorderHarness.profileMeScript(uid: "2001001", displayName: "Groups User"),
                    GroupRecorderHarness.httpScript(
                        path: "/api/group/updateinfo",
                        method: "POST",
                        json: .object(["error_code": .int(0), "data": .object([:])])
                    ),
                    GroupRecorderHarness.httpScript(
                        path: "/api/group/updateinfo",
                        method: "POST",
                        status: 500,
                        json: .object(["error_code": .int(500), "error_message": .string("Rename failed")])
                    ),
                ],
                steps: [
                    .object(["cmd": .string("start")]),
                    .object(["await": .object(["phase": .string("ready")])]),
                    .object([
                        "cmd": .string("rename_group"),
                        "now_ms": .int(1700010041000),
                        "args": .object(["id": .string("g500401"), "name": .string("  Nhóm Mới  ")]),
                    ]),
                    .object(["snapshot": .string("after_rename_ok")]),
                    .object([
                        "cmd": .string("rename_group"),
                        "args": .object(["id": .string("g500401"), "name": .string("   ")]),
                    ]),
                    .object(["snapshot": .string("after_blank_rename")]),
                    .object([
                        "cmd": .string("rename_group"),
                        "args": .object(["id": .string("g500401"), "name": .string("Nhóm Fail")]),
                    ]),
                ]
            ),
        ]
    }
}

private final class GroupTransitionRecorder: @unchecked Sendable {
    private let scenarioName: String
    private let captureState: @MainActor () async -> CaseJSON
    private var history: [CaseJSON] = []
    private var lastSerialized: String?
    private var searchFromIndex = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(scenarioName: String, captureState: @escaping @MainActor () async -> CaseJSON) {
        self.scenarioName = scenarioName
        self.captureState = captureState
    }

    @MainActor
    func recordTransition() {
        Task { @MainActor in
            let state = await captureState()
            let canonical = state.canonicalString()
            if canonical == self.lastSerialized {
                return
            }
            self.lastSerialized = canonical
            self.history.append(state)
            let pending = self.waiters
            self.waiters.removeAll()
            for cont in pending.values {
                cont.resume()
            }
        }
    }

    @MainActor
    func cancelWaiters() {
        let pending = waiters
        waiters.removeAll()
        for cont in pending.values {
            cont.resume()
        }
    }

    @MainActor
    func awaitPredicate(_ pred: CaseJSON, timeoutMs: Int) async throws {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        let targetKind = pred["phase"]?.stringValue
        let targetStep = pred["step"]?.stringValue

        func matches(_ state: CaseJSON) -> Bool {
            guard let phase = state["phase"],
                  let kind = phase["kind"]?.stringValue else { return false }
            if let targetKind, kind != targetKind { return false }
            if let targetStep, phase["step"]?.stringValue != targetStep { return false }
            return true
        }

        while true {
            recordTransition()
            if let hit = (searchFromIndex..<history.count).first(where: { matches(history[$0]) }) {
                searchFromIndex = hit + 1
                return
            }
            let remaining = deadline - ContinuousClock.now
            if remaining <= .zero {
                throw GroupRecorderHarness.RecorderError.timeout(
                    scenario: scenarioName,
                    detail: "timed out awaiting \(pred.canonicalString()); latest phase: \(history.last?["phase"]?.canonicalString() ?? "none")"
                )
            }
            let waiterId = UUID()
            let timeoutTask = Task { @MainActor in
                try? await Task.sleep(for: min(remaining, .milliseconds(50)))
                if let cont = self.waiters.removeValue(forKey: waiterId) {
                    cont.resume()
                }
            }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                waiters[waiterId] = cont
            }
            timeoutTask.cancel()
        }
    }
}

enum GroupRecorderHarness {
    enum RecorderError: Error, CustomStringConvertible {
        case timeout(scenario: String, detail: String)
        case unscriptedRequest(scenario: String, detail: String)
        case invalidSeed(scenario: String, detail: String)
        case invalidStep(scenario: String, detail: String)

        var description: String {
            switch self {
            case .timeout(let s, let d): return "[\(s)] timeout: \(d)"
            case .unscriptedRequest(let s, let d): return "[\(s)] unscripted HTTP request(s): \(d)"
            case .invalidSeed(let s, let d): return "[\(s)] invalid seed: \(d)"
            case .invalidStep(let s, let d): return "[\(s)] invalid step: \(d)"
            }
        }
    }

    struct ScenarioDef {
        let name: String
        let seed: CaseJSON
        let server: [CaseJSON]
        let steps: [CaseJSON]
        let slow: Bool

        init(name: String, seed: CaseJSON, server: [CaseJSON], steps: [CaseJSON], slow: Bool = false) {
            self.name = name
            self.seed = seed
            self.server = server
            self.steps = steps
            self.slow = slow
        }
    }

    static func httpScript(
        path: String,
        method: String = "GET",
        status: Int = 200,
        json: CaseJSON? = nil,
        raw: String? = nil,
        error: String? = nil,
        hold: Bool = false,
        repeatResponse: Bool = false
    ) -> CaseJSON {
        var resp: [String: CaseJSON] = ["status": .int(Int64(status))]
        if let json { resp["json"] = json }
        if let raw { resp["raw"] = .string(raw) }
        if let error { resp["error"] = .string(error) }
        var obj: [String: CaseJSON] = [
            "kind": .string("http"),
            "path": .string(path),
            "method": .string(method),
            "response": .object(resp),
        ]
        if hold { obj["hold"] = .bool(true) }
        if repeatResponse { obj["repeat"] = .bool(true) }
        return .object(obj)
    }

    private static var shouldRecord: Bool {
        ProcessInfo.processInfo.environment["OLAZ_RECORD"] == "1"
    }

    private static var shouldRunSlowCases: Bool {
        shouldRecord || ProcessInfo.processInfo.environment["OLAZ_SLOW_CASES"] == "1"
    }

    @MainActor
    static func runDomain(domain: String, scenarios: [ScenarioDef]) async throws {
        let sorted = scenarios.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
        let url = CaseFile.casesURL(domain: domain)

        if shouldRecord {
            var recorded: [CaseJSON] = []
            recorded.reserveCapacity(sorted.count)
            for scenario in sorted {
                recorded.append(try await recordScenario(domain: domain, scenario))
            }
            try CaseFile.write(recorded, to: url)
            return
        }

        let existing = try CaseFile.load(url: url)
        var byName: [String: CaseJSON] = [:]
        for item in existing {
            if let name = item["name"]?.stringValue {
                byName[name] = item
            }
        }
        XCTAssertEqual(byName.count, sorted.count, "\(domain).jsonl case count mismatch (run with OLAZ_RECORD=1 to regenerate)")

        for scenario in sorted {
            if scenario.slow && !shouldRunSlowCases {
                print("skipped slow: \(scenario.name)")
                continue
            }
            guard let expected = byName[scenario.name] else {
                XCTFail("Missing recorded case '\(scenario.name)' in \(url.path)")
                continue
            }
            let actual = try await recordScenario(domain: domain, scenario)
            if let diff = CaseJSON.firstDiff(expected: expected, actual: actual) {
                XCTFail("\(scenario.name): \(diff)")
            }
        }
    }

    @MainActor
    static func recordScenario(domain: String, _ scenario: ScenarioDef) async throws -> CaseJSON {
        try await RecorderSuiteLock.shared.withLock {
            try await recordScenarioLocked(domain: domain, scenario)
        }
    }

    @MainActor
    private static func recordScenarioLocked(domain: String, _ scenario: ScenarioDef) async throws -> CaseJSON {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-group-recorder-\(scenario.name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let storage = RecorderStorageIsolation(prefix: "olaz.group-recorder")
        EngineLog.shared.onAppend = nil

        defer {
            EngineLog.shared.onAppend = nil
            storage.cleanup()
            try? FileManager.default.removeItem(at: dataDir)
        }

        let initialSecretKey = extractInitialSecretKey(from: scenario.seed)
        let wsAuthManual = scenario.seed["ws_auth"]?.stringValue == "manual"
        let server = try FakeZaloServer(
            serverScript: scenario.server,
            initialSecretKey: initialSecretKey,
            wsAuthManual: wsAuthManual
        )
        try await server.start()

        let baseURL = server.baseURLString
        let wsURL = server.wsBaseURLString

        func substituteRuntimeURLs(_ json: CaseJSON) -> CaseJSON {
            json
                .replacingString("http://fake", with: baseURL)
                .replacingString("ws://fake", with: wsURL)
        }

        func normalizeRecordedURLs(_ json: CaseJSON) -> CaseJSON {
            json
                .replacingString(baseURL, with: "http://fake")
                .replacingString(wsURL, with: "ws://fake")
        }

        var seededUserId: String?
        if let savedSession = scenario.seed["saved_session"], savedSession != .null {
            seededUserId = savedSession["plainAccount"]?["userId"]?.stringValue
            let sub = substituteRuntimeURLs(savedSession)
            let fileURL = dataDir.appendingPathComponent("native-session.json")
            try Data(sub.canonicalString().utf8).write(to: fileURL, options: .atomic)
        }

        if let uid = seededUserId, !uid.isEmpty {
            try await seedSQLiteStore(userId: uid, dataDir: dataDir, seed: substituteRuntimeURLs(scenario.seed))
        }

        let domainsJSON = substituteRuntimeURLs(scenario.seed["domains"] ?? defaultFakeDomainsJSON())
        let domainsData = Data(domainsJSON.canonicalString().utf8)
        let domains = try JSONDecoder().decode(ZaloDomains.self, from: domainsData)
        try assertOnlyLocalFakeHosts(domains, scenario: scenario.name, stage: "initial seed")

        let engine = ZaloEngine(
            dataDirectory: dataDir,
            useKeychain: false,
            domains: domains,
            userDefaultsSuiteName: storage.userDefaultsSuiteName,
            cookieStorage: storage.cookieStorage
        )
        if let nextClientId = scenario.seed["next_client_id"]?.int64Value {
            await engine.sessionClient.seedNextClientId(nextClientId)
        }
        if let prefsObj = scenario.seed["prefs"]?.objectValue {
            for (k, v) in prefsObj {
                if let s = v.stringValue {
                    engine.recordedSessionPrefs[k] = s
                }
            }
        }
        if let pollSeed = scenario.seed["poll_state"], pollSeed != .null {
            let decoded = try JSONDecoder().decode(ZaloPollState.self, from: Data(pollSeed.canonicalString().utf8))
            engine.pollState = decoded
        }
        if let cursorsSeed = scenario.seed["ws_cursors"], cursorsSeed != .null {
            let decoded = try JSONDecoder().decode([String: ZaloWSQueueCursorSnapshot].self, from: Data(cursorsSeed.canonicalString().utf8))
            await engine.webSocket.seedQueueCursors(decoded)
        }
        if let contactsSeed = scenario.seed["contacts"], contactsSeed != .null {
            applyContactsSeed(substituteRuntimeURLs(contactsSeed), to: engine)
        }
        if let detailsObj = scenario.seed["cached_group_details"]?.objectValue {
            var seededDetails: [String: [String: Any]] = [:]
            for (k, v) in detailsObj {
                let sub = substituteRuntimeURLs(v)
                if let parsed = try? JSONSerialization.jsonObject(with: Data(sub.canonicalString().utf8)) as? [String: Any] {
                    seededDetails[k] = parsed
                }
            }
            engine.cachedGroupDetails = seededDetails
        }
        if let memberCacheObj = scenario.seed["group_member_cache"]?.objectValue {
            var seededCache: [String: [MentionCandidate]] = [:]
            for (gid, arrVal) in memberCacheObj {
                let arr = substituteRuntimeURLs(arrVal).arrayValue ?? []
                seededCache[gid] = arr.compactMap { row in
                    guard let id = row["id"]?.stringValue else { return nil }
                    let name = row["name"]?.stringValue ?? ""
                    let avt = row["avatar"]?.stringValue.flatMap(URL.init(string:))
                    let isAll = row["is_all"]?.boolValue ?? false
                    return MentionCandidate(id: id, name: name, avatar: avt, isAll: isAll)
                }
            }
            engine.groupMemberCache = seededCache
        }
        if let openConvId = scenario.seed["open_conversation_id"]?.stringValue, !openConvId.isEmpty {
            engine.openConversationId = openConvId
        }
        if let freshnessObj = scenario.seed["history_freshness"]?.objectValue {
            var map: [String: HistoryFreshness] = [:]
            for (k, v) in freshnessObj {
                switch v.stringValue {
                case "up_to_date": map[k] = .upToDate
                case "stale": map[k] = .stale
                default: break
                }
            }
            engine.historyFreshness = map
        }

        var bootstrapLogs: [String] = []
        var sendLogs: [String] = []
        var actionLogs: [String] = []
        var groupLogs: [String] = []
        var results: [String: CaseJSON] = [:]

        func installLogHooks(forwardingTo existing: ((String) -> Void)?) {
            EngineLog.shared.onAppend = { rawLine in
                existing?(rawLine)
                if let sp = rawLine.firstIndex(of: " ") {
                    let msg = String(rawLine[rawLine.index(after: sp)...])
                    if msg.hasPrefix("bootstrap: ") {
                        bootstrapLogs.append(msg)
                    }
                    if msg.hasPrefix("sendText ") {
                        sendLogs.append(msg)
                    }
                    if msg.hasPrefix("react failed") || msg.hasPrefix("recall failed") || msg.hasPrefix("autodelete: ") {
                        actionLogs.append(msg)
                    }
                    if msg.hasPrefix("group create failed: ")
                        || msg.hasPrefix("group avatar upload failed: ")
                        || msg.hasPrefix("rename group failed: ")
                        || msg.hasPrefix("invite group members failed: ")
                        || msg.hasPrefix("kick group member failed: ")
                        || msg.hasPrefix("leave group failed: ")
                        || msg.hasPrefix("group admin: failed code=")
                    {
                        groupLogs.append(msg)
                    }
                }
            }
        }
        installLogHooks(forwardingTo: nil)

        let suppressedTransports = Set(
            scenario.seed["suppress"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )

        var hostCalls: [CaseJSON] = []
        var hostSettleTargets: [Int] = []
        var hostCursor = 0
        var settleCount = 0
        var signalWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        func notifySignal() {
            let pending = signalWaiters
            signalWaiters.removeAll()
            for cont in pending.values {
                cont.resume()
            }
        }

        engine.traceU4HostEnabled = true
        engine.hostTrace = { name, args in
            let normalizedArgs = normalizeRecordedURLs(CaseJSON.fromAny(args))
            hostCalls.append(.object([
                "call": .string(name),
                "args": normalizedArgs,
            ]))
            hostSettleTargets.append(settleCount)
            notifySignal()
            switch name {
            case "prepare_store":
                return true
            case "apply_batch", "apply_parsed_events":
                return true
            case "start_ws":
                return !suppressedTransports.contains("ws")
            case "start_long_poll":
                return !suppressedTransports.contains("long_poll")
            default:
                return false
            }
        }

        let transitionRecorder = GroupTransitionRecorder(scenarioName: scenario.name) {
            normalizeRecordedURLs(await GroupSnapshot.capture(from: engine))
        }
        engine.stateTrace = { [weak transitionRecorder] in
            transitionRecorder?.recordTransition()
        }
        engine.transportSettleTrace = {
            settleCount += 1
            notifySignal()
        }

        func waitForCondition(timeoutMs: Int, description: String, _ pred: @MainActor () -> Bool) async throws {
            let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
            while !pred() {
                let remaining = deadline - ContinuousClock.now
                if remaining <= .zero {
                    throw RecorderError.timeout(scenario: scenario.name, detail: "Timed out waiting for \(description)")
                }
                let waitId = UUID()
                let sleeper = Task { @MainActor in
                    try? await Task.sleep(for: remaining)
                    if let cont = signalWaiters.removeValue(forKey: waitId) {
                        cont.resume()
                    }
                }
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    signalWaiters[waitId] = cont
                }
                sleeper.cancel()
            }
        }

        var snapshots: [String: CaseJSON] = [:]

        do {
            for (stepIndex, step) in scenario.steps.enumerated() {
                if let cmd = step["cmd"]?.stringValue {
                    let args = step["args"]?.objectValue
                    if let stepNowMs = step["now_ms"]?.int64Value {
                        engine.nowMs = { stepNowMs }
                    }
                    defer {
                        if step["now_ms"] != nil {
                            engine.nowMs = { Int64(Date().timeIntervalSince1970 * 1000) }
                        }
                    }

                    switch cmd {
                    case "start":
                        engine.start()
                        installLogHooks(forwardingTo: EngineLog.shared.onAppend)
                    case "open":
                        _ = await engine.bootTask?.value
                        let id = args?["id"]?.stringValue ?? ""
                        engine.openConversation(id)
                        _ = await engine.openConversationTask?.value
                        _ = await engine.persistConversationsTask?.value
                    case "close":
                        engine.closeConversation()
                    case "create_group":
                        _ = await engine.bootTask?.value
                        let name = args?["name"]?.stringValue ?? ""
                        let members = args?["members"]?.arrayValue?.compactMap(\.stringValue) ?? []
                        var avatar: GroupAvatarImage?
                        if let avtObj = args?["avatar"], avtObj != .null {
                            let b64 = avtObj["jpeg_b64"]?.stringValue ?? ""
                            let side = Int(avtObj["side"]?.int64Value ?? 240)
                            if let data = Data(base64Encoded: b64) {
                                avatar = GroupAvatarImage(jpeg: data, side: side)
                            }
                        }
                        let outcome = await engine.createGroup(name: name, members: members, avatar: avatar)
                        await engine.awaitContactsTasksForRecording()
                        _ = await engine.persistConversationsTask?.value
                        let outcomeJSON: CaseJSON
                        switch outcome {
                        case .created(let id, let failed):
                            outcomeJSON = .object([
                                "status": .string("created"),
                                "id": .string(id),
                                "failed": .array(failed.map(CaseJSON.string)),
                            ])
                        case .exists(let id, let text):
                            outcomeJSON = .object([
                                "status": .string("exists"),
                                "id": .string(id),
                                "text": .string(text),
                            ])
                        case .invalid(let text, let dropped):
                            outcomeJSON = .object([
                                "status": .string("invalid"),
                                "text": .string(text),
                                "dropped": .array(dropped.map(CaseJSON.string)),
                            ])
                        case .failed(let title, let message, let closes):
                            outcomeJSON = .object([
                                "status": .string("failed"),
                                "title": title.map(CaseJSON.string) ?? .null,
                                "message": .string(message),
                                "closes": .bool(closes),
                            ])
                        case .pending(let text):
                            outcomeJSON = .object([
                                "status": .string("pending"),
                                "text": .string(text),
                            ])
                        }
                        results["\(stepIndex)"] = outcomeJSON
                    case "rename_group":
                        _ = await engine.bootTask?.value
                        let id = args?["id"]?.stringValue ?? ""
                        let name = args?["name"]?.stringValue ?? ""
                        _ = await engine.renameGroup(id, to: name)
                        _ = await engine.persistConversationsTask?.value
                    case "invite":
                        _ = await engine.bootTask?.value
                        let id = args?["id"]?.stringValue ?? ""
                        let members = args?["members"]?.arrayValue?.compactMap(\.stringValue) ?? []
                        _ = await engine.inviteMembers(members, to: id)
                        _ = await engine.persistConversationsTask?.value
                    case "kick":
                        _ = await engine.bootTask?.value
                        let id = args?["id"]?.stringValue ?? ""
                        let member = args?["member"]?.stringValue ?? ""
                        _ = await engine.kickMember(member, from: id)
                        _ = await engine.persistConversationsTask?.value
                    case "leave_group":
                        _ = await engine.bootTask?.value
                        let id = args?["id"]?.stringValue ?? ""
                        let silent = args?["silent"]?.boolValue ?? false
                        _ = await engine.leaveGroup(id, silent: silent)
                        _ = await engine.persistConversationsTask?.value
                    case "refresh_group":
                        _ = await engine.bootTask?.value
                        let id = args?["id"]?.stringValue ?? ""
                        await engine.refreshGroupMetadata(id)
                        _ = await engine.persistConversationsTask?.value
                    case "load_members":
                        _ = await engine.bootTask?.value
                        let id = args?["id"]?.stringValue ?? ""
                        let members = await engine.loadGroupMembers(in: id)
                        results["\(stepIndex)"] = normalizeRecordedURLs(.array(members.map { c in
                            .object([
                                "id": .string(c.id),
                                "name": .string(c.name),
                                "avatar": c.avatar.map { .string($0.absoluteString) } ?? .null,
                                "is_all": .bool(c.isAll),
                            ])
                        }))
                        _ = await engine.persistConversationsTask?.value
                    case "set_admin":
                        _ = await engine.bootTask?.value
                        let id = args?["id"]?.stringValue ?? ""
                        let uid = args?["uid"]?.stringValue ?? ""
                        let admin = args?["admin"]?.boolValue ?? true
                        _ = await engine.setGroupAdmin(id, uid: uid, admin: admin)
                        _ = await engine.persistConversationsTask?.value
                    case "change_owner":
                        _ = await engine.bootTask?.value
                        let id = args?["id"]?.stringValue ?? ""
                        let uid = args?["uid"]?.stringValue ?? ""
                        _ = await engine.changeGroupOwner(id, uid: uid)
                        _ = await engine.persistConversationsTask?.value
                    case "block_member":
                        _ = await engine.bootTask?.value
                        let id = args?["id"]?.stringValue ?? ""
                        let uid = args?["uid"]?.stringValue ?? ""
                        _ = await engine.blockGroupMember(id, uid: uid)
                        _ = await engine.persistConversationsTask?.value
                    case "pending":
                        _ = await engine.bootTask?.value
                        let id = args?["id"]?.stringValue ?? ""
                        let list = await engine.groupPendingMembers(id)
                        results["\(stepIndex)"] = normalizeRecordedURLs(list.map { items in
                            .array(items.map { p in
                                .object([
                                    "id": .string(p.id),
                                    "name": .string(p.name),
                                    "avatar": p.avatar.map { .string($0.absoluteString) } ?? .null,
                                ])
                            })
                        } ?? .null)
                    case "review_pending":
                        _ = await engine.bootTask?.value
                        let id = args?["id"]?.stringValue ?? ""
                        let uids = args?["uids"]?.arrayValue?.compactMap(\.stringValue) ?? []
                        let approve = args?["approve"]?.boolValue ?? true
                        _ = await engine.reviewGroupPending(id, uids: uids, approve: approve)
                        _ = await engine.persistConversationsTask?.value
                    case "join_approval":
                        _ = await engine.bootTask?.value
                        let id = args?["id"]?.stringValue ?? ""
                        let on = args?["on"]?.boolValue ?? true
                        _ = await engine.setGroupJoinApproval(id, on: on)
                        _ = await engine.persistConversationsTask?.value
                    case "group_link":
                        _ = await engine.bootTask?.value
                        let id = args?["id"]?.stringValue ?? ""
                        let link = await engine.groupLink(id)
                        results["\(stepIndex)"] = normalizeRecordedURLs(link.map { l in
                            .object(["link": .string(l.link), "enabled": .bool(l.enabled)])
                        } ?? .null)
                    case "set_group_link":
                        _ = await engine.bootTask?.value
                        let id = args?["id"]?.stringValue ?? ""
                        let renew = args?["renew"]?.boolValue ?? true
                        let link = await engine.setGroupLink(id, renew: renew)
                        results["\(stepIndex)"] = normalizeRecordedURLs(link.map { l in
                            .object(["link": .string(l.link), "enabled": .bool(l.enabled)])
                        } ?? .null)
                    case "group_notice":
                        _ = await engine.bootTask?.value
                        let act = args?["act"]?.stringValue ?? ""
                        let dataJSON = substituteRuntimeURLs(args?["data"] ?? .object([:]))
                        let dataObj = (try? JSONSerialization.jsonObject(with: Data(dataJSON.canonicalString().utf8)) as? [String: Any]) ?? [:]
                        let ts = args?["ts"]?.int64Value ?? 0
                        await engine.handleGroupEventNotice(act: act, data: dataObj, ts: ts)
                        await engine.settleForRecording()
                        _ = await engine.persistConversationsTask?.value
                    default:
                        throw RecorderError.invalidStep(scenario: scenario.name, detail: "Unknown cmd: \(cmd)")
                    }
                } else if let pred = step["await"] {
                    let timeoutMs = Int(step["timeout_ms"]?.int64Value ?? 5000)
                    try await transitionRecorder.awaitPredicate(pred, timeoutMs: timeoutMs)
                } else if let targetCall = step["await_host"]?.stringValue {
                    let timeoutMs = Int(step["timeout_ms"]?.int64Value ?? 5000)
                    var matchedIdx: Int?
                    try await waitForCondition(timeoutMs: timeoutMs, description: "host call '\(targetCall)'") {
                        if let idx = (hostCursor..<hostCalls.count).first(where: {
                            hostCalls[$0]["call"]?.stringValue == targetCall
                        }) {
                            matchedIdx = idx
                            return true
                        }
                        return false
                    }
                    if let idx = matchedIdx {
                        hostCursor = idx + 1
                        if targetCall == "apply_parsed_events" || targetCall == "apply_batch" {
                            let targetSettle = hostSettleTargets[idx] + 1
                            try await waitForCondition(timeoutMs: timeoutMs, description: "settle after '\(targetCall)'") {
                                settleCount >= targetSettle
                            }
                        }
                    }
                } else if let pushCount = step["ws_push"]?.int64Value {
                    let timeoutMs = Int(step["timeout_ms"]?.int64Value ?? 5000)
                    do {
                        try await server.pushWebSocketActions(count: Int(pushCount), timeoutMs: timeoutMs)
                    } catch {
                        throw RecorderError.timeout(scenario: scenario.name, detail: "\(error)")
                    }
                } else if let releaseCount = step["http_release"]?.int64Value {
                    let timeoutMs = Int(step["timeout_ms"]?.int64Value ?? 5000)
                    do {
                        try await server.releaseHeldHTTPResponses(count: Int(releaseCount), timeoutMs: timeoutMs)
                    } catch {
                        throw RecorderError.timeout(scenario: scenario.name, detail: "\(error)")
                    }
                } else if let label = step["snapshot"]?.stringValue {
                    await engine.settleForRecording()
                    await Task.yield()
                    let snap = await GroupSnapshot.capture(
                        from: engine,
                        bootstrapLogs: bootstrapLogs,
                        sendLogs: sendLogs,
                        actionLogs: actionLogs,
                        results: results,
                        groupLogs: groupLogs
                    )
                    snapshots[label] = normalizeRecordedURLs(snap)
                } else {
                    throw RecorderError.invalidStep(scenario: scenario.name, detail: "Unknown step: \(step.canonicalString())")
                }
            }

            _ = await engine.bootTask?.value
            _ = await engine.openConversationTask?.value
            _ = await engine.loadOlderTask?.value
            await engine.awaitContactsTasksForRecording()
            await engine.awaitMarkReadTasksForRecording()
            await engine.awaitNotifyTypingTaskForRecording()
            await engine.awaitMessageActionTasksForRecording()
            _ = await engine.persistConversationsTask?.value
            _ = await engine.pendingCleanupTask?.value
            await server.waitForScriptedRequests(timeoutMs: 2000)
            if !suppressedTransports.contains("ws") {
                try? await Task.sleep(for: .milliseconds(50))
            }
            await engine.settleForRecording()
            await Task.yield()

            try assertOnlyLocalFakeHosts(await engine.sessionClient.domains, scenario: scenario.name, stage: "final")

            let finalState = normalizeRecordedURLs(
                await GroupSnapshot.capture(
                    from: engine,
                    bootstrapLogs: bootstrapLogs,
                    sendLogs: sendLogs,
                    actionLogs: actionLogs,
                    results: results,
                    groupLogs: groupLogs
                )
            )
            let requests = server.canonicalRequests().map { normalizeRecordedURLs($0) }

            engine.cancelTasksForRecording()
            engine.transportSettleTrace = nil
            server.stop()
            await engine.finishTearDownForRecording()

            if server.hadUnscriptedRequest {
                let unscripted = requests.filter { $0["unscripted"]?.boolValue == true }
                throw RecorderError.unscriptedRequest(scenario: scenario.name, detail: CaseJSON.array(unscripted).canonicalString())
            }

            var caseDict: [String: CaseJSON] = [
                "format": .int(1),
                "domain": .string(domain),
                "name": .string(scenario.name),
                "seed": scenario.seed,
                "server": .array(scenario.server),
                "steps": .array(scenario.steps),
                "expect": .object([
                    "snapshots": .object(snapshots),
                    "final": finalState,
                    "requests": .array(requests),
                    "host": .array(hostCalls),
                ]),
            ]
            if scenario.slow {
                caseDict["slow"] = .bool(true)
            }
            return .object(caseDict)
        } catch {
            transitionRecorder.cancelWaiters()
            let pending = signalWaiters
            signalWaiters.removeAll()
            for cont in pending.values { cont.resume() }
            engine.cancelTasksForRecording()
            engine.transportSettleTrace = nil
            server.stop()
            await engine.finishTearDownForRecording()
            throw error
        }
    }

    // MARK: - Seed & Script Helpers

    private static func seedSQLiteStore(userId: String, dataDir: URL, seed: CaseJSON) async throws {
        let dbURL = dataDir
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(userId, isDirectory: true)
            .appendingPathComponent("history.sqlite3")
        let store = try ZaloSQLiteStore(path: dbURL.path)
        try await store.setPreferenceString(key: ZaloWebKitMigrator.donePrefKey, value: "1")

        if let pinned = seed["pinned_ids"]?.arrayValue?.compactMap(\.stringValue) {
            try await store.setPreferenceStrings(key: "pinnedIds", value: pinned)
        }
        if let archived = seed["archived_ids"]?.arrayValue?.compactMap(\.stringValue) {
            try await store.setPreferenceStrings(key: "archivedIds", value: archived)
        }
        if let unreadMarks = seed["unread_marks"]?.arrayValue?.compactMap(\.stringValue) {
            try await store.setPreferenceStrings(key: "unreadMarks", value: unreadMarks)
        }
        if let hidden = seed["hidden_ids"]?.arrayValue?.compactMap(\.stringValue) {
            try await store.setPreferenceStrings(key: "hiddenIds", value: hidden)
        }
        if let ranks = seed["activity_ranks"], ranks != .null {
            try await store.setPreferenceData(key: "activityRanks", data: Data(ranks.canonicalString().utf8))
        }
        if let contacts = seed["contacts"] {
            if let aliases = contacts["aliases"], aliases != .null {
                try await store.setPreferenceData(key: "aliases", data: Data(aliases.canonicalString().utf8))
            }
            if let profiles = contacts["cached_profiles"], profiles != .null {
                try await store.setPreferenceData(key: "cachedProfiles", data: Data(profiles.canonicalString().utf8))
            }
            if let groups = contacts["cached_groups"], groups != .null {
                try await store.setPreferenceData(key: "cachedGroups", data: Data(groups.canonicalString().utf8))
            }
            if let gidMap = contacts["gid_to_uid_map"], gidMap != .null {
                try await store.setPreferenceData(key: "gidToUidMap", data: Data(gidMap.canonicalString().utf8))
            }
        }
        if let convRows = seed["local_conversations"]?.arrayValue, !convRows.isEmpty {
            let stored: [StoredConversation] = convRows.compactMap { row in
                guard let id = row["id"]?.stringValue else { return nil }
                return StoredConversation(
                    id: id,
                    isGroup: row["is_group"]?.boolValue ?? false,
                    name: row["name"]?.stringValue ?? "",
                    avatar: row["avatar"]?.stringValue ?? "",
                    pinned: row["pinned"]?.boolValue ?? false,
                    members: Int(row["members"]?.int64Value ?? 0),
                    unread: Int(row["unread"]?.int64Value ?? 0),
                    previewText: row["preview_text"]?.stringValue ?? "",
                    previewTsMs: row["preview_ts_ms"]?.int64Value ?? 0,
                    previewFromMe: row["preview_from_me"]?.boolValue ?? false,
                    updatedAtMs: row["updated_at_ms"]?.int64Value ?? 1700000000000
                )
            }
            try await store.saveConversations(stored)
        }
        if let msgRows = seed["local_messages"]?.arrayValue, !msgRows.isEmpty {
            let stored: [StoredMessage] = msgRows.compactMap { row in
                guard let id = row["id"]?.stringValue, let convId = row["conv_id"]?.stringValue else { return nil }
                let status = row["status"]?.stringValue ?? "sent"
                let rawJSON: Data = {
                    if let rawObj = row["raw_json"], rawObj != .null {
                        return Data(rawObj.canonicalString().utf8)
                    }
                    var obj: [String: CaseJSON] = [
                        "id": .string(id),
                        "conversationId": .string(convId),
                        "clientId": .string(row["client_id"]?.stringValue ?? id),
                        "senderId": .string(row["sender_id"]?.stringValue ?? ""),
                        "senderName": .string(row["sender_name"]?.stringValue ?? ""),
                        "senderAvatar": .string(row["sender_avatar"]?.stringValue ?? ""),
                        "isMine": .bool(row["is_mine"]?.boolValue ?? false),
                        "text": .string(row["text"]?.stringValue ?? ""),
                        "date": .int(row["ts_ms"]?.int64Value ?? 0),
                        "status": .string(status),
                        "isE2EE": .bool(row["is_e2ee"]?.boolValue ?? false),
                        "kind": .object(["type": .string(row["kind_tag"]?.stringValue ?? "text")]),
                    ]
                    if let reactions = row["reactions"], reactions != .null {
                        obj["reactions"] = reactions
                    }
                    return Data(CaseJSON.object(obj).canonicalString().utf8)
                }()
                return StoredMessage(
                    id: id,
                    convId: convId,
                    clientId: row["client_id"]?.stringValue ?? id,
                    senderId: row["sender_id"]?.stringValue ?? "",
                    senderName: row["sender_name"]?.stringValue ?? "",
                    senderAvatar: row["sender_avatar"]?.stringValue ?? "",
                    isMine: row["is_mine"]?.boolValue ?? false,
                    text: row["text"]?.stringValue ?? "",
                    kindTag: row["kind_tag"]?.stringValue ?? "text",
                    tsMs: row["ts_ms"]?.int64Value ?? 0,
                    status: status,
                    rawJSONData: rawJSON
                )
            }
            try await store.saveMessages(stored)
        }
        await store.close()
    }

    @MainActor
    private static func applyContactsSeed(_ contacts: CaseJSON, to engine: ZaloEngine) {
        if let loaded = contacts["friends_loaded"]?.boolValue {
            engine.contacts.friendsLoaded = loaded
        }
        if let loaded = contacts["groups_loaded"]?.boolValue {
            engine.contacts.groupsLoaded = loaded
        }
        if let friendsArr = contacts["friends"]?.arrayValue {
            engine.contacts.friends = friendsArr.compactMap { row in
                guard let id = row["id"]?.stringValue else { return nil }
                let name = row["name"]?.stringValue ?? id
                let zaloName = row["zalo_name"]?.stringValue ?? name
                let avatar = row["avatar"]?.stringValue.flatMap(URL.init(string:))
                let lastActive = row["last_active_ms"]?.int64Value.map { Date(timeIntervalSince1970: Double($0) / 1000.0) }
                let online = row["online"]?.boolValue ?? false
                let section = row["section"]?.stringValue ?? String(name.prefix(1)).uppercased()
                let sortKey = row["sort_key"]?.stringValue ?? name.lowercased()
                return ContactsState.Friend(
                    id: id,
                    name: name,
                    zaloName: zaloName,
                    avatar: avatar,
                    lastActive: lastActive,
                    online: online,
                    section: section.isEmpty ? "#" : section,
                    sortKey: sortKey
                )
            }
        }
        if let groupsArr = contacts["groups"]?.arrayValue {
            engine.contacts.groups = groupsArr.compactMap { row in
                guard let id = row["id"]?.stringValue else { return nil }
                let name = row["name"]?.stringValue ?? id
                let avatar = row["avatar"]?.stringValue.flatMap(URL.init(string:))
                let members = Int(row["members"]?.int64Value ?? 0)
                let sortKey = row["sort_key"]?.stringValue ?? name.lowercased()
                return ContactsState.Group(
                    id: id,
                    name: name,
                    avatar: avatar,
                    members: members,
                    sortKey: sortKey
                )
            }
        }
    }

    private static func extractInitialSecretKey(from seed: CaseJSON) -> Data? {
        guard let enk = seed["saved_session"]?["plainAccount"]?["zpwEnk"]?.stringValue,
              !enk.isEmpty else { return nil }
        let key = ZaloCrypto.parseSecretKey(enk)
        return (key.count == 16 || key.count == 32) ? key : nil
    }

    private static func defaultFakeDomainsJSON() -> CaseJSON {
        let fakeServices: [String: CaseJSON] = [
            "alias": .array([.string("http://fake")]),
            "auto_reply": .array([.string("http://fake")]),
            "chat": .array([.string("http://fake")]),
            "chat_e2e": .array([.string("http://fake")]),
            "conversation": .array([.string("http://fake")]),
            "emoji_status": .array([.string("http://fake")]),
            "file": .array([.string("http://fake")]),
            "friend": .array([.string("http://fake")]),
            "friend_lan": .array([.string("http://fake")]),
            "group": .array([.string("http://fake")]),
            "group_board": .array([.string("http://fake")]),
            "group_cloud_message": .array([.string("http://fake")]),
            "group_e2e": .array([.string("http://fake")]),
            "group_poll": .array([.string("http://fake")]),
            "label": .array([.string("http://fake")]),
            "media_store": .array([.string("http://fake")]),
            "media_store_send2me": .array([.string("http://fake")]),
            "profile": .array([.string("http://fake")]),
            "quick_message": .array([.string("http://fake")]),
            "reaction": .array([.string("http://fake")]),
            "sticker": .array([.string("http://fake")]),
            "up_file": .array([.string("http://fake")]),
            "voice_call": .array([.string("http://fake")]),
            "zcloud": .array([.string("http://fake")]),
            "zcloud_up_file": .array([.string("http://fake")]),
            "znoise": .array([.string("http://fake")]),
        ]
        return .object([
            "auth": .string("http://fake"),
            "lpChat": .string("http://fake"),
            "lpControl": .string("http://fake"),
            "wpaChat": .string("http://fake"),
            "ws": .array([.string("ws://fake")]),
            "serviceCandidates": .object(fakeServices),
            "preferredHosts": .object([:]),
            "isolated": .bool(true),
        ])
    }

    private static func assertOnlyLocalFakeHosts(_ domains: ZaloDomains, scenario: String, stage: String) throws {
        let urls = [domains.auth, domains.lpChat, domains.lpControl, domains.wpaChat]
            + domains.ws
            + domains.serviceCandidates.values.flatMap { $0 }
            + domains.preferredHosts.values
        for raw in urls {
            guard let parsed = URL(string: raw),
                  let host = parsed.host?.lowercased(),
                  host == "127.0.0.1" || host == "localhost" || host == "fake" else {
                throw RecorderError.invalidSeed(scenario: scenario, detail: "Non-local host '\(raw)' at \(stage)")
            }
        }
        guard domains.isolated else {
            throw RecorderError.invalidSeed(scenario: scenario, detail: "domains.isolated must be true at \(stage)")
        }
    }
}
