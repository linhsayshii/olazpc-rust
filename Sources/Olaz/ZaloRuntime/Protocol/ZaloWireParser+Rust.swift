import Foundation
import OlazCore

/// Rust-core path of `ZaloWireParser.extractBatchEvents` (ADR-011). The Swift parser stays the default and the fallback:
/// any input the bridge cannot handle returns `nil` and the caller runs the Swift walk instead.
extension ZaloWireParser {
    /// Keys whose string values are sender / quote-owner uids; the Swift parser resolves each through `nameLookup`.
    private static let uidKeys: Set<String> = ["uidFrom", "senderId", "ownerId"]

    private static func collectUids(_ node: Any, into out: inout Set<String>, depth: Int = 0) {
        guard depth < 12 else { return }
        if let dict = node as? [String: Any] {
            for (key, value) in dict {
                if uidKeys.contains(key) {
                    let uid = stripUserPrefix(JSONLossless.string(value))
                    if !uid.isEmpty, uid != "0" { out.insert(uid) }
                } else if value is [String: Any] || value is [Any] {
                    collectUids(value, into: &out, depth: depth + 1)
                }
            }
        } else if let arr = node as? [Any] {
            for el in arr { collectUids(el, into: &out, depth: depth + 1) }
        }
    }

    /// Everything the parse needs, as `Sendable` values, so the parse itself can leave the caller's actor.
    struct RustBatchInput: Sendable {
        let json: String
        let myUid: String
        let options: WireOptions
    }

    /// Serializes `root` and pre-resolves contact names (the Swift `nameLookup` closure runs here, on the caller).
    static func rustBatchInput(
        _ root: Any,
        myUid: String,
        selfConvId: String?,
        defaultCmd: UInt16,
        fallbackConvId: String?,
        isGroupHint: Bool?,
        nameLookup: ((String) -> (name: String, avatar: String)?)?
    ) -> RustBatchInput? {
        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(withJSONObject: root),
              let json = String(data: data, encoding: .utf8) else { return nil }
        var names: [NameEntry] = []
        if let nameLookup {
            var uids = Set<String>()
            collectUids(root, into: &uids)
            for uid in uids.sorted() {
                if let hit = nameLookup(uid) { names.append(NameEntry(uid: uid, name: hit.name, avatar: hit.avatar)) }
            }
        }
        let options = WireOptions(cmd: defaultCmd, fallbackConvId: fallbackConvId, isGroupHint: isGroupHint, selfConvId: selfConvId, names: names)
        return RustBatchInput(json: json, myUid: myUid, options: options)
    }

    /// Maps typed core events to the Swift event type: a field-by-field `ChatMessage(record:)`, no JSON anywhere.
    /// `StoredMessage` is rebuilt from the record's own columns plus the canonical raw JSON the core produced.
    static func parsedEvents(from events: [WireEvent]) -> [ParsedWireEvent] {
        var out: [ParsedWireEvent] = []
        out.reserveCapacity(events.count)
        for event in events {
            switch event {
            case .message(let m, let s):
                let stored = StoredMessage(
                    id: m.id, convId: m.conversationId, clientId: m.clientId, senderId: m.senderId, senderName: m.senderName,
                    senderAvatar: s.senderAvatar, isMine: m.isMine, text: m.text, kindTag: s.kindTag, tsMs: m.dateMs,
                    status: s.locked ? "e2ee_locked" : "sent", rawJSONData: s.rawJson)
                out.append(.message(ChatMessage(record: m), stored))
            case .reaction(let convId, let msgId, let cliMsgId, let senderId, let rType, let rIcon, let eventId, let reactClientId, let tsMs, let seqId, let senderName):
                out.append(.reaction(
                    convId: convId, msgId: msgId, cliMsgId: cliMsgId, senderId: senderId, rType: rType, rIcon: rIcon,
                    eventId: eventId, reactClientId: reactClientId, tsMs: tsMs, seqId: seqId, senderName: senderName))
            case .undo(let convId, let msgId, let cliMsgId):
                out.append(.undo(convId: convId, msgId: msgId, cliMsgId: cliMsgId))
            case .delete(let convId, let msgId, let cliMsgId):
                out.append(.delete(convId: convId, msgId: msgId, cliMsgId: cliMsgId))
            case .typing(let convId, let senderId, let isGroup):
                out.append(.typing(convId: convId, senderId: senderId, isGroup: isGroup))
            case .ignore:
                break
            }
        }
        return out
    }

    /// Runs the Rust parser and maps its events to the Swift types; `nil` when the core rejects the input.
    static func rustParseBatch(_ input: RustBatchInput) -> [ParsedWireEvent]? {
        guard let events = try? parseWireBatch(json: input.json, myUid: input.myUid, options: input.options) else { return nil }
        return parsedEvents(from: events)
    }

    static func rustExtractBatchEvents(
        _ root: Any,
        myUid: String,
        selfConvId: String?,
        defaultCmd: UInt16,
        fallbackConvId: String?,
        isGroupHint: Bool?,
        nameLookup: ((String) -> (name: String, avatar: String)?)?
    ) -> [ParsedWireEvent]? {
        guard let input = rustBatchInput(
            root, myUid: myUid, selfConvId: selfConvId, defaultCmd: defaultCmd,
            fallbackConvId: fallbackConvId, isGroupHint: isGroupHint, nameLookup: nameLookup
        ) else { return nil }
        return rustParseBatch(input)
    }

    /// Same result as `extractBatchEvents`, but on the Rust path the parse and the `ChatMessage` decoding run off the
    /// caller's actor (only serialization and the name lookup stay on it). The Swift path runs inline as before.
    @MainActor
    static func extractBatchEventsAsync(
        _ root: Any,
        myUid: String,
        selfConvId: String? = nil,
        defaultCmd: UInt16 = 0,
        fallbackConvId: String? = nil,
        isGroupHint: Bool? = nil,
        nameLookup: ((String) -> (name: String, avatar: String)?)? = nil,
        useRustCore: Bool = RustCore.isEnabled
    ) async -> [ParsedWireEvent] {
        if useRustCore,
           let input = rustBatchInput(
               root, myUid: myUid, selfConvId: selfConvId, defaultCmd: defaultCmd,
               fallbackConvId: fallbackConvId, isGroupHint: isGroupHint, nameLookup: nameLookup
           ),
           let events = await Task.detached(priority: .userInitiated, operation: { rustParseBatch(input) }).value {
            return events
        }
        return extractBatchEvents(
            root, myUid: myUid, selfConvId: selfConvId, defaultCmd: defaultCmd, fallbackConvId: fallbackConvId,
            isGroupHint: isGroupHint, nameLookup: nameLookup, useRustCore: false)
    }
}
