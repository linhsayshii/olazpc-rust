import Foundation
@testable import Olaz

enum StickerSnapshot {
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

        if var msgsObj = out["messages"]?.objectValue {
            for (convId, list) in engine.messages {
                guard let existingArr = msgsObj[convId]?.arrayValue, existingArr.count == list.count else { continue }
                let enriched: [CaseJSON] = zip(list, existingArr).map { m, base in
                    var dict = base.objectValue ?? [:]
                    switch m.kind {
                    case .sticker(let url):
                        dict["sticker_url"] = url.map { .string($0.absoluteString) } ?? .null
                        dict["contact_card"] = .null
                    case .contactCard(let card):
                        dict["sticker_url"] = .null
                        dict["contact_card"] = .object([
                            "name": .string(card.name),
                            "uid": .string(card.uid),
                            "avatar": card.avatar.map { .string($0.absoluteString) } ?? .null,
                            "phone": .string(card.phone),
                        ])
                    default:
                        dict["sticker_url"] = .null
                        dict["contact_card"] = .null
                    }
                    return .object(dict)
                }
                msgsObj[convId] = .array(enriched)
            }
            out["messages"] = .object(msgsObj)
        }

        if let store = engine.sqliteStore, var storeObj = out["store"]?.objectValue {
            var prefsObj = storeObj["prefs"]?.objectValue ?? [:]
            if let recentData = try? await store.getPreferenceData(key: "recentStickers"),
               let recentJSON = try? CaseJSON.parse(recentData) {
                prefsObj["recent_stickers"] = recentJSON
            } else {
                prefsObj["recent_stickers"] = .array([])
            }

            if let suggestData = try? await store.getPreferenceData(key: "stickerSuggest"),
               let suggestVal = try? JSONDecoder().decode(Bool.self, from: suggestData) {
                prefsObj["sticker_suggest"] = .bool(suggestVal)
            } else {
                prefsObj["sticker_suggest"] = .null
            }

            storeObj["prefs"] = .object(prefsObj)
            out["store"] = .object(storeObj)
        }

        out["sticker_suggest_state"] = encodeSuggestSetting(StickerSuggestState.shared.setting)
        out["composer_confirm"] = engine.composerConfirm.map(encodeConfirm) ?? .null
        out["queued_composer_confirms"] = .array(engine.queuedComposerConfirms.map(encodeConfirm))
        out["results"] = .object(results)

        return .object(out)
    }

    static func encodeStickerTabs(_ tabs: [StickerTab]?) -> CaseJSON {
        guard let tabs else { return .null }
        return .array(tabs.map { t in
            .object([
                "id": .int(Int64(t.id)),
                "name": .string(t.name),
                "icon": t.icon.map { .string($0.absoluteString) } ?? .null,
                "count": .int(Int64(t.count)),
            ])
        })
    }

    static func encodeStickers(_ list: [StickerEntry]?) -> CaseJSON {
        guard let list else { return .null }
        return .array(list.map { s in
            let animVal: CaseJSON = {
                switch s.animation {
                case nil:
                    return .null
                case .sprite(let url, let frames, let frameMs):
                    return .object([
                        "kind": .string("sprite"),
                        "url": .string(url.absoluteString),
                        "frames": .int(Int64(frames)),
                        "ms": .int(Int64(frameMs)),
                    ])
                case .animated(let url):
                    return .object([
                        "kind": .string("animated"),
                        "url": .string(url.absoluteString),
                    ])
                }
            }()
            return .object([
                "cate_id": .int(Int64(s.cateId)),
                "id": .int(Int64(s.stickerId)),
                "url": .string(s.url.absoluteString),
                "anim": animVal,
            ])
        })
    }

    static func encodeSuggestSetting(_ s: StickerSuggestSetting?) -> CaseJSON {
        guard let s else { return .null }
        return .object([
            "enabled": .bool(s.enabled),
            "debounce": .int(Int64(s.debounce)),
        ])
    }

    static func encodeCardActionOutcome(_ outcome: CardActionOutcome) -> CaseJSON {
        switch outcome {
        case .done:
            return .object(["status": .string("done"), "text": .null])
        case .openChat(let id):
            return .object(["status": .string("open_chat"), "text": .string(id)])
        case .openProfile(let uid):
            return .object(["status": .string("open_profile"), "text": .string(uid)])
        case .openURL(let url):
            return .object(["status": .string("open_url"), "text": .string(url.absoluteString)])
        case .copy(let text):
            return .object(["status": .string("copy"), "text": .string(text)])
        case .present:
            return .object(["status": .string("present"), "text": .null])
        case .unsupported(let text):
            return .object(["status": .string("unsupported"), "text": .string(text)])
        case .locked(let text):
            return .object(["status": .string("locked"), "text": .string(text)])
        case .failed(let text):
            return .object(["status": .string("failed"), "text": .string(text)])
        case .pending(let text):
            return .object(["status": .string("pending"), "text": .string(text)])
        }
    }

    static func encodeComposerOutcome(_ outcome: ComposerOutcome) -> CaseJSON {
        switch outcome {
        case .done:
            return .object(["status": .string("done"), "text": .null])
        case .cancelled:
            return .object(["status": .string("cancelled"), "text": .null])
        case .failed(let text):
            return .object(["status": .string("failed"), "text": .string(text)])
        case .pending(let text):
            return .object(["status": .string("pending"), "text": .string(text)])
        }
    }

    static func encodeMyCard(_ info: MyCardInfo?) -> CaseJSON {
        guard let info else { return .null }
        return .object([
            "uid": .string(info.uid),
            "name": .string(info.name),
            "avatar": info.avatar.map { .string($0.absoluteString) } ?? .null,
            "phone": .string(info.phone),
            "with_phone": .bool(info.withPhone),
        ])
    }

    static func encodeReminderInfo(_ info: ReminderComposeInfo?) -> CaseJSON {
        guard let info else { return .null }
        return .object([
            "allowed": .bool(info.allowed),
            "hidden": .bool(info.hidden),
            "text": .string(info.text),
            "is_group": .bool(info.isGroup),
            "can_pin": .bool(info.canPin),
            "pin_toggle": .bool(info.pinToggle),
            "title_max_chars": .int(Int64(info.titleMaxChars)),
            "title_max_bytes": .int(Int64(info.titleMaxBytes)),
        ])
    }

    static func encodeConfirm(_ confirm: ComposerConfirm) -> CaseJSON {
        .object([
            "id": .string(confirm.id),
            "conv_id": .string(confirm.conversationId),
            "title": .string(confirm.title),
            "message": .string(confirm.message),
            "ok": .string(confirm.ok),
            "cancel": .string(confirm.cancel),
        ])
    }
}
