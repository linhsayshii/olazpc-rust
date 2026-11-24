import Foundation
@testable import Olaz

enum SendSnapshot {
    @MainActor
    static func capture(
        from engine: ZaloEngine,
        pinBoard: PinBoard? = nil,
        lastActionResult: ConversationActionResult? = nil,
        bootstrapLogs: [String] = [],
        lastSendResult: Bool? = nil,
        sendLogs: [String] = []
    ) async -> CaseJSON {
        var out = await MessageSnapshot.capture(
            from: engine,
            pinBoard: pinBoard,
            lastActionResult: lastActionResult,
            bootstrapLogs: bootstrapLogs
        ).objectValue ?? [:]

        if var msgsObj = out["messages"]?.objectValue {
            for (convId, list) in engine.messages {
                guard let existingArr = msgsObj[convId]?.arrayValue, existingArr.count == list.count else { continue }
                let enriched: [CaseJSON] = zip(list, existingArr).map { m, base in
                    var dict = base.objectValue ?? [:]
                    dict["status"] = .string(m.status.rawValue)
                    if let q = m.quote {
                        dict["quote"] = .object([
                            "sender_name": .string(q.senderName),
                            "text": .string(q.text),
                            "msg_id": .string(q.msgId),
                            "cli_msg_id": .string(q.cliMsgId),
                        ])
                    } else {
                        dict["quote"] = .null
                    }
                    dict["mentions"] = .array(m.mentions.map { mention in
                        .object([
                            "uid": .string(mention.uid),
                            "pos": .int(Int64(mention.pos)),
                            "len": .int(Int64(mention.len)),
                            "is_all": .bool(mention.isAll),
                        ])
                    })
                    dict["text_styles"] = .array(m.textStyles.map { st in
                        .object([
                            "start": .int(Int64(st.start)),
                            "len": .int(Int64(st.len)),
                            "st": .string(st.st),
                        ])
                    })
                    dict["ttl_ms"] = .int(m.ttlMs)
                    dict["urgency"] = .int(Int64(m.urgency))
                    let deleteVal: CaseJSON = m.menu.delete.map { del in
                        .string(del == .forMe ? "for_me" : del.rawValue)
                    } ?? .null
                    dict["menu"] = .object([
                        "forward": .string(m.menu.forward.rawValue),
                        "recall": .bool(m.menu.recall),
                        "delete": deleteVal,
                        "pin": .bool(m.menu.pin),
                        "star": m.menu.star.map { .string($0.rawValue) } ?? .null,
                        "starred": .bool(m.menu.starred),
                        "pinned": .bool(m.menu.pinned),
                        "protected": .bool(m.menu.isProtected),
                    ])
                    return .object(dict)
                }
                msgsObj[convId] = .array(enriched)
            }
            out["messages"] = .object(msgsObj)
        }

        var typingObj: [String: CaseJSON] = [:]
        for (convId, t) in engine.typing {
            typingObj[convId] = .object([
                "name": .string(t.name),
                "on_pc": .bool(t.onPC),
            ])
        }
        out["typing"] = .object(typingObj)
        out["last_send_result"] = lastSendResult.map(CaseJSON.bool) ?? .null
        out["send_logs"] = .array(sendLogs.map(CaseJSON.string))

        return .object(out)
    }
}
