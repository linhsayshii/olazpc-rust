import Foundation
@testable import Olaz

enum ConversationSnapshot {
    @MainActor
    static func capture(
        from engine: ZaloEngine,
        pinBoard: PinBoard? = nil,
        lastActionResult: ConversationActionResult? = nil
    ) async -> CaseJSON {
        var out = SessionSnapshot.capture(from: engine).objectValue ?? [:]

        // 1. conversations
        let convsJSON: [CaseJSON] = engine.conversations.map { c in
            let previewJSON: CaseJSON = c.preview.map { p in
                .object([
                    "text": .string(p.text),
                    "date_ms": p.date.map { .int(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? .null,
                    "from_me": .bool(p.fromMe),
                ])
            } ?? .null

            return .object([
                "id": .string(c.id),
                "is_group": .bool(c.isGroup),
                "name": .string(c.name),
                "avatar": c.avatar.map { .string($0.absoluteString) } ?? .null,
                "pinned": .bool(c.pinned),
                "members": .int(Int64(c.members)),
                "unread": .int(Int64(c.unread)),
                "preview": previewJSON,
            ])
        }
        out["conversations"] = .array(convsJSON)

        // 2. flags (ConversationActionsState + ConversationActionUI lock/removal)
        let ca = engine.conversationActions
        let ui = engine.conversationUI
        let flagsMap = ca.flags.mapValues { CaseJSON.int(Int64($0.rawValue)) }
        let leftMap = ca.left.mapValues { CaseJSON.string($0.rawValue) }
        let removalVal: CaseJSON = ui.removal.map { r in
            .object([
                "seq": .int(Int64(r.seq)),
                "ids": .array(r.ids.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map(CaseJSON.string)),
            ])
        } ?? .null

        out["flags"] = .object([
            "loaded": .bool(ca.loaded),
            "hidden_known": .bool(ca.hiddenKnown),
            "hidden_enabled": .bool(ca.hiddenEnabled),
            "has_hidden_pin": .bool(ca.hasHiddenPIN),
            "hidden_ids": .array(ca.hiddenIds.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map(CaseJSON.string)),
            "mark_unread_enabled": .bool(ca.markUnreadEnabled),
            "flags": .object(flagsMap),
            "left": .object(leftMap),
            "late_epoch": .int(ca.lateEpoch),
            "late_seq": .int(Int64(ca.lateSeq)),
            "unlocked_id": ui.unlockedId.map(CaseJSON.string) ?? .null,
            "pin_search_ids": .array(ui.pinSearchIds.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map(CaseJSON.string)),
            "removal": removalVal,
        ])

        // 3. labels (ConversationExtras)
        let ce = engine.conversationExtras
        let labelItems: [CaseJSON] = ce.labels.map { l in
            .object([
                "id": .string(l.id),
                "name": .string(l.name),
                "color_hex": .string(l.colorHex),
                "conv_ids": .array(l.convIds.map(CaseJSON.string)),
            ])
        }
        let strangerBox: CaseJSON = .object([
            "chats": .int(Int64(ce.strangerBox.chats)),
            "unread_chats": .int(Int64(ce.strangerBox.unreadChats)),
            "unread_messages": .int(Int64(ce.strangerBox.unreadMessages)),
            "newest_id": ce.strangerBox.newestId.map(CaseJSON.string) ?? .null,
        ])
        out["labels"] = .object([
            "loaded": .bool(ce.loaded),
            "archived_enabled": .bool(ce.archivedEnabled),
            "labels": .array(labelItems),
            "label_by_conversation": .object(ce.labelByConversation.mapValues(CaseJSON.string)),
            "type_filter": .int(Int64(ce.typeFilter)),
            "label_filter_ids": .array(ce.labelFilterIds.map(CaseJSON.string)),
            "list_ids": .array(ce.listIds.map(CaseJSON.string)),
            "stranger_ids": .array(ce.strangerIds.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map(CaseJSON.string)),
            "stranger_folder_ids": .array(ce.strangerFolderIds.map(CaseJSON.string)),
            "stranger_box": strangerBox,
        ])

        // 4. store (read directly from SQLiteStore, not traced)
        if let store = engine.sqliteStore {
            let storedConvs = ((try? await store.loadConversations()) ?? [])
                .sorted { $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) }
            let convRowsJSON: [CaseJSON] = storedConvs.map { row in
                .object([
                    "id": .string(row.id),
                    "is_group": .bool(row.isGroup),
                    "name": .string(row.name),
                    "avatar": .string(row.avatar),
                    "pinned": .bool(row.pinned),
                    "members": .int(Int64(row.members)),
                    "unread": .int(Int64(row.unread)),
                    "preview_text": .string(row.previewText),
                    "preview_ts_ms": .int(row.previewTsMs),
                    "preview_from_me": .bool(row.previewFromMe),
                    "updated_at_ms": .string("<volatile>"),
                ])
            }

            let pinnedIds = ((try? await store.getPreferenceStrings(key: "pinnedIds")) ?? [])
                .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            let archivedIds = ((try? await store.getPreferenceStrings(key: "archivedIds")) ?? [])
                .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            let unreadMarks = ((try? await store.getPreferenceStrings(key: "unreadMarks")) ?? [])
                .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            let hiddenIds = ((try? await store.getPreferenceStrings(key: "hiddenIds")) ?? [])
                .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }

            let labelsData = try? await store.getPreferenceData(key: "labels")
            let labelsJSON: CaseJSON = labelsData.flatMap { try? CaseJSON.parse($0) } ?? .array([])

            let profilesData = try? await store.getPreferenceData(key: "cachedProfiles")
            let profilesJSON: CaseJSON = profilesData.flatMap { try? CaseJSON.parse($0) } ?? .object([:])

            let md5Str = try? await store.getPreferenceString(key: "hiddenPinMD5")
            let hashStr = try? await store.getPreferenceString(key: "hiddenPinHash")

            out["store"] = .object([
                "conversations": .array(convRowsJSON),
                "prefs": .object([
                    "pinned_ids": .array(pinnedIds.map(CaseJSON.string)),
                    "archived_ids": .array(archivedIds.map(CaseJSON.string)),
                    "unread_marks": .array(unreadMarks.map(CaseJSON.string)),
                    "hidden_ids": .array(hiddenIds.map(CaseJSON.string)),
                    "labels": labelsJSON,
                    "cached_profiles": profilesJSON,
                    "hidden_pin_md5": (md5Str?.isEmpty == false) ? .string(md5Str!) : .null,
                    "hidden_pin_hash": (hashStr?.isEmpty == false) ? .string(hashStr!) : .null,
                ]),
            ])
        } else {
            out["store"] = .null
        }

        // 5. toast
        out["toast"] = ui.toast.map { t in
            let kindStr: String = {
                switch t.kind {
                case .success: return "success"
                case .neutral: return "neutral"
                case .failure: return "failure"
                }
            }()
            return .object([
                "seq": .int(Int64(t.seq)),
                "kind": .string(kindStr),
                "ok": .bool(t.kind != .failure),
                "text": .string(t.text),
            ])
        } ?? .null

        // 6. prompt
        out["prompt"] = engine.conversationPrompt.map { p in
            let (kind, id): (String, String) = {
                switch p {
                case .delete(let id): return ("delete", id)
                case .pinBoard(let id): return ("pin_board", id)
                case .hide(let id): return ("hide", id)
                case .unhide(let id): return ("unhide", id)
                case .unlock(let id): return ("unlock", id)
                }
            }()
            return .object(["kind": .string(kind), "id": .string(id)])
        } ?? .null

        // 7. pin_board & last_action_result
        out["pin_board"] = pinBoard.map { b in
            .object([
                "tab": .int(Int64(b.tab)),
                "limit": .int(Int64(b.limit)),
                "total": .int(Int64(b.total)),
                "need": .int(Int64(b.need)),
                "items": .array(b.items.map(CaseJSON.string)),
            ])
        } ?? .null

        out["last_action_result"] = lastActionResult.map { r in
            .object([
                "ok": .bool(r.ok),
                "text": .string(r.text),
                "full": .bool(r.full),
                "bad_pin": .bool(r.badPIN),
                "pin_exists": .bool(r.pinExists),
                "neutral": .bool(r.neutral),
            ])
        } ?? .null

        return .object(out)
    }
}
