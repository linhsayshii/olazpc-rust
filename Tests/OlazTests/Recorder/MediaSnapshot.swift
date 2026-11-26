import Foundation
@testable import Olaz

enum MediaSnapshot {
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
                    let (kindMap, _) = ZaloWireParser.serializeKind(m.kind)
                    dict["kind_detail"] = CaseJSON.fromAny(kindMap)
                    dict["fallback_urls"] = .array(m.fallbackURLs.map { .string($0.absoluteString) })
                    return .object(dict)
                }
                msgsObj[convId] = .array(enriched)
            }
            out["messages"] = .object(msgsObj)
        }

        if let store = engine.sqliteStore, var storeObj = out["store"]?.objectValue {
            let storedMsgs = ((try? await store.loadAllMessages()) ?? []).sorted { a, b in
                if a.convId != b.convId {
                    return a.convId.utf8.lexicographicallyPrecedes(b.convId.utf8)
                }
                if a.tsMs != b.tsMs {
                    return a.tsMs < b.tsMs
                }
                return a.id.utf8.lexicographicallyPrecedes(b.id.utf8)
            }
            if let existingStoreMsgs = storeObj["messages"]?.arrayValue,
               existingStoreMsgs.count == storedMsgs.count {
                let enrichedStoreMsgs: [CaseJSON] = zip(storedMsgs, existingStoreMsgs).map { row, base in
                    var dict = base.objectValue ?? [:]
                    if let decoded = ZaloWireParser.decodeStoredMessage(row) {
                        let (kindMap, _) = ZaloWireParser.serializeKind(decoded.kind)
                        dict["kind_detail"] = CaseJSON.fromAny(kindMap)
                        dict["fallback_urls"] = .array(decoded.fallbackURLs.map { .string($0.absoluteString) })
                    } else {
                        dict["kind_detail"] = .null
                        dict["fallback_urls"] = .array([])
                    }
                    return .object(dict)
                }
                storeObj["messages"] = .array(enrichedStoreMsgs)
            }
            out["store"] = .object(storeObj)
        }

        out["cloud_file_limit"] = engine.cloud.plan.map { .int($0.fileLimit) } ?? .null
        out["downloaded_file_paths"] = .object(engine.downloadedFilePaths.mapValues { .string($0.path) })
        out["results"] = .object(results)

        return .object(out)
    }

    static func encodeComposerOutcome(_ outcome: ComposerOutcome) -> CaseJSON {
        switch outcome {
        case .done:
            return .object(["status": .string("done")])
        case .cancelled:
            return .object(["status": .string("cancelled")])
        case .failed(let text):
            return .object(["status": .string("failed"), "text": .string(text)])
        case .pending(let text):
            return .object(["status": .string("pending"), "text": .string(text)])
        }
    }

    static func encodeMediaResolution(_ resolution: MediaResolution) -> CaseJSON {
        switch resolution {
        case .file(let url):
            return .object(["state": .string("file"), "path": .string(url.path)])
        case .expired:
            return .object(["state": .string("expired")])
        case .unavailable:
            return .object(["state": .string("unavailable")])
        case .unsupported:
            return .object(["state": .string("unsupported")])
        }
    }

    static func encodeFileResolution(_ resolution: FileResolution) -> CaseJSON {
        switch resolution {
        case .ready(let url):
            return .object(["state": .string("ready"), "path": .string(url.path)])
        case .expired:
            return .object(["state": .string("expired")])
        case .failed(let text):
            return .object(["state": .string("failed"), "text": .string(text)])
        }
    }

    static func encodeSharedMediaPage(_ page: SharedMediaPage?) -> CaseJSON {
        guard let page else { return .null }
        let items: [CaseJSON] = page.items.map { m in
            let (kindMap, kindTag) = ZaloWireParser.serializeKind(m.kind)
            return .object([
                "id": .string(m.id),
                "conv_id": .string(m.conversationId),
                "kind_tag": .string(kindTag),
                "kind_detail": CaseJSON.fromAny(kindMap),
                "text": .string(m.text),
                "date_ms": .int(Int64((m.date.timeIntervalSince1970 * 1000).rounded())),
            ])
        }
        return .object([
            "items": .array(items),
            "cursor": page.cursor.map(CaseJSON.string) ?? .null,
            "more": .bool(page.more),
        ])
    }
}
