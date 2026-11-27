import Foundation
@testable import Olaz

enum NotifySnapshot {
    @MainActor
    static func capture(
        from engine: ZaloEngine,
        pinBoard: PinBoard? = nil,
        lastActionResult: ConversationActionResult? = nil,
        bootstrapLogs: [String] = [],
        lastSendResult: Bool? = nil,
        sendLogs: [String] = [],
        pruneNextExpiryMs: Int64? = nil,
        actionLogs: [String] = [],
        banners: [NotifyBannerRecord] = [],
        results: [String: CaseJSON] = [:]
    ) async -> CaseJSON {
        var out = await MessageActionSnapshot.capture(
            from: engine,
            pinBoard: pinBoard,
            lastActionResult: lastActionResult,
            bootstrapLogs: bootstrapLogs,
            lastSendResult: lastSendResult,
            sendLogs: sendLogs,
            pruneNextExpiryMs: pruneNextExpiryMs,
            actionLogs: actionLogs
        ).objectValue ?? [:]

        if let store = engine.sqliteStore, var storeObj = out["store"]?.objectValue {
            var prefsObj = storeObj["prefs"]?.objectValue ?? [:]

            if let enabledData = try? await store.getPreferenceData(key: "notifEnabled"),
               let enabledVal = try? JSONDecoder().decode(Bool.self, from: enabledData) {
                prefsObj["notif_enabled"] = .bool(enabledVal)
            } else {
                prefsObj["notif_enabled"] = .null
            }

            if let soundData = try? await store.getPreferenceData(key: "notifSound"),
               let soundVal = try? JSONDecoder().decode(Bool.self, from: soundData) {
                prefsObj["notif_sound"] = .bool(soundVal)
            } else {
                prefsObj["notif_sound"] = .null
            }

            if let mutedData = try? await store.getPreferenceData(key: "mutedThreads"),
               let parsed = try? CaseJSON.parse(mutedData),
               let arr = parsed.arrayValue {
                let sorted = arr.sorted {
                    let a = $0["id"]?.stringValue ?? ""
                    let b = $1["id"]?.stringValue ?? ""
                    return a.utf8.lexicographicallyPrecedes(b.utf8)
                }
                prefsObj["muted_threads"] = .array(sorted)
            } else {
                prefsObj["muted_threads"] = .array([])
            }

            if let aliasesData = try? await store.getPreferenceData(key: "aliases"),
               let aliasesJSON = try? CaseJSON.parse(aliasesData) {
                prefsObj["aliases"] = aliasesJSON
            } else {
                prefsObj["aliases"] = .object([:])
            }

            storeObj["prefs"] = .object(prefsObj)
            out["store"] = .object(storeObj)
        }

        let s = engine.notificationSettings
        out["notification_settings"] = .object([
            "is_loaded": .bool(s.isLoaded),
            "enabled": .bool(s.enabled),
            "sound": .bool(s.sound),
            "has_sound_setting": .bool(s.hasSoundSetting),
            "shows_preview": .bool(s.showsPreview),
            "authorization": .string(s.authorization.rawValue),
            "mutes": .object(s.mutes.mapValues(encodeMuteInfo)),
        ])

        let now = Date(timeIntervalSince1970: Double(engine.nowMs()) / 1000.0)
        let activeMutes = s.activeMutes(now: now).map { entry in
            CaseJSON.object([
                "id": .string(entry.id),
                "start_time": encodeSeconds(entry.info.startTime),
                "duration": encodeSeconds(entry.info.duration),
                "until_ms": entry.info.until.map { .int(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? .null,
                "status_text": .string(entry.info.statusText(now: now, calendar: engine.notificationCalendar)),
            ])
        }
        out["active_mutes"] = .array(activeMutes)
        out["banners"] = .array(banners.map(encodeBanner))
        out["cached_aliases"] = .object(engine.cachedAliases.mapValues(CaseJSON.string))
        out["results"] = .object(results)

        return .object(out)
    }

    static func encodeSeconds(_ value: TimeInterval) -> CaseJSON {
        if value.isFinite, value.rounded() == value, value >= -9e15, value <= 9e15 {
            return .int(Int64(value))
        }
        return .double(value, raw: String(value))
    }

    static func encodeMuteInfo(_ info: MuteInfo) -> CaseJSON {
        .object([
            "start_time": encodeSeconds(info.startTime),
            "duration": encodeSeconds(info.duration),
        ])
    }

    static func encodeBanner(_ b: NotifyBannerRecord) -> CaseJSON {
        .object([
            "title": .string(b.title),
            "body": .string(b.body),
            "conv_id": .string(b.convId),
            "sender_id": .string(b.senderId),
            "sender_name": .string(b.senderName),
            "is_group": .bool(b.isGroup),
            "avatar_url": b.avatarURL.map(CaseJSON.string) ?? .null,
            "silent": .bool(b.silent),
        ])
    }

    static func encodeSuggestedStickers(_ list: [SuggestedSticker]) -> CaseJSON {
        .array(list.map { item in
            .object([
                "ref": .string(item.ref),
                "url": .string(item.url.absoluteString),
            ])
        })
    }

    static func encodeContactProfile(_ p: ContactProfile?) -> CaseJSON {
        guard let p else { return .null }
        return .object([
            "uid": .string(p.uid),
            "name": .string(p.name),
            "zalo_name": .string(p.zaloName),
            "avatar": p.avatar.map { .string($0.absoluteString) } ?? .null,
            "bio": .string(p.bio),
            "is_self": .bool(p.isSelf),
            "is_friend": .bool(p.isFriend),
            "is_oa": .bool(p.isOfficialAccount),
        ])
    }

    static func encodeFriendRequestPrep(_ prep: FriendRequestPrep) -> CaseJSON {
        .object([
            "state": .string(prep.state.rawValue),
            "default_message": .string(prep.defaultMessage),
            "max_message": .int(Int64(prep.maxMessage)),
        ])
    }

    static func encodeGroupInvitePreview(_ preview: GroupInvitePreview) -> CaseJSON {
        let stateStr: String = switch preview.state {
        case .preview: "preview"
        case .member: "member"
        case .error: "error"
        }
        return .object([
            "state": .string(stateStr),
            "group_id": .string(preview.groupId),
            "name": .string(preview.name),
            "avatar": preview.avatar.map { .string($0.absoluteString) } ?? .null,
            "total_member": .int(Int64(preview.totalMember)),
            "desc": .string(preview.desc),
            "community": .bool(preview.community),
            "creator_name": .string(preview.creatorName),
            "members": .array(preview.members.map { m in
                .object([
                    "id": .string(m.id),
                    "name": .string(m.name),
                    "avatar": m.avatar.map { .string($0.absoluteString) } ?? .null,
                    "admin": .bool(m.admin),
                ])
            }),
            "text": .string(preview.text),
        ])
    }

    static func encodeGroupJoinResult(_ res: GroupJoinResult) -> CaseJSON {
        let stateStr: String = switch res.state {
        case .joined: "joined"
        case .pending: "pending"
        case .already: "already"
        case .error: "error"
        }
        return .object([
            "state": .string(stateStr),
            "group_id": .string(res.groupId),
            "text": .string(res.text),
        ])
    }

    static func encodeReminderSnapshot(_ snap: ReminderSnapshot?) -> CaseJSON {
        guard let snap else { return .null }
        return .object([
            "variant": .string(snap.variant.rawValue),
            "id": .string(snap.id),
            "title": .string(snap.title),
            "start_ms": snap.start.map { .int(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? .null,
            "repeat_label": .string(snap.repeatLabel),
            "creator_name": .string(snap.creatorName),
            "only_me": .bool(snap.onlyMe),
            "is_group": .bool(snap.isGroup),
            "mine": .string(snap.mine?.rawValue ?? ""),
            "accepted_count": .int(Int64(snap.acceptedCount)),
            "rejected_count": .int(Int64(snap.rejectedCount)),
            "can_rsvp": .bool(snap.canRsvp),
            "can_view": .bool(snap.canView),
            "deleted": .bool(snap.deleted),
            "sig": .string(snap.sig),
        ])
    }

    static func encodeReminderResponders(_ resp: ReminderResponders?) -> CaseJSON {
        guard let resp else { return .null }
        func encodePeople(_ list: [ReminderResponders.Person]) -> CaseJSON {
            .array(list.map { p in
                .object([
                    "uid": .string(p.uid),
                    "name": .string(p.name),
                    "avatar": p.avatar.map { .string($0.absoluteString) } ?? .null,
                    "is_me": .bool(p.isMe),
                ])
            })
        }
        return .object([
            "accept": encodePeople(resp.accept),
            "reject": encodePeople(resp.reject),
            "accept_total": .int(Int64(resp.acceptTotal)),
            "reject_total": .int(Int64(resp.rejectTotal)),
            "accept_more": .int(Int64(resp.acceptMore)),
            "reject_more": .int(Int64(resp.rejectMore)),
        ])
    }
}
