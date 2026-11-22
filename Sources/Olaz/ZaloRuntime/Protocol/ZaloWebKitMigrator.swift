import Foundation
import SQLite3

/// Pure-Swift, read-only migrator for Olaz's own legacy WebKit IndexedDB (`zdb_<userId>`)
/// stored under `~/Library/WebKit/<bundleId>/WebsiteData/**/IndexedDB/*/IndexedDB.sqlite3`.
///
/// Decodes WebKit `CloneSerializer` binary records directly in Swift and decrypts `BasicEncryption`
/// (`ev == 0`, repeating UTF-16 code-unit XOR with `account.dkey` / `UIN`) with zero `WKWebView`,
/// zero JavaScript, and zero external helper processes.
enum ZaloWebKitMigrator {
    static let donePrefKey = "migratedWebKitZdbV1"
    static let cursorPrefKey = "webkitZdbCursorRecordID"

    struct CachedProfile: Codable, Equatable, Sendable {
        var name: String
        var avatar: String
    }

    struct CachedGroup: Codable, Equatable, Sendable {
        var name: String
        var avatar: String
        var members: Int
    }

    struct BootstrapMigrationResult: Sendable {
        var dbPath: String
        var importedProfiles: Int
        var importedGroups: Int
        var importedGlobalIds: Int
        var importedConversations: Int
        var importedMessages: Int
        var remainingCursorRecordID: Int64?
    }

    // MARK: - WebKit CloneDeserializer (v1..v32)

    static func xorDecryptUTF16(_ units: [UInt16], keyUnits: [UInt16]) -> String {
        guard !units.isEmpty else { return "" }
        guard !keyUnits.isEmpty else { return String(decoding: units, as: UTF16.self) }
        let kLen = keyUnits.count
        var out = [UInt16](repeating: 0, count: units.count)
        for i in 0..<units.count {
            out[i] = units[i] ^ keyUnits[i % kLen]
        }
        return String(decoding: out, as: UTF16.self)
    }

    static func xorDecryptString(_ cipher: String, key: String) -> String {
        let units = Array(cipher.utf16)
        let keyUnits = Array(key.utf16)
        return xorDecryptUTF16(units, keyUnits: keyUnits)
    }

    static func decodeCloneRecord(
        _ buffer: UnsafeRawBufferPointer,
        xorDecryptFields: Set<String> = [],
        xorKeyUnits: [UInt16] = []
    ) -> [String: Any]? {
        var decoder = CloneDecoder(
            buffer: buffer,
            xorDecryptFields: xorDecryptFields,
            xorKeyUnits: xorKeyUnits
        )
        return decoder.decodeRootObject()
    }

    static func decodeCloneRecord(
        _ data: Data,
        xorDecryptFields: Set<String> = [],
        xorKeyUnits: [UInt16] = []
    ) -> [String: Any]? {
        data.withUnsafeBytes { raw in
            decodeCloneRecord(raw, xorDecryptFields: xorDecryptFields, xorKeyUnits: xorKeyUnits)
        }
    }

    private struct CloneDecoder {
        let buffer: UnsafeRawBufferPointer
        let xorDecryptFields: Set<String>
        let xorKeyUnits: [UInt16]
        var pos: Int = 0
        var stringPool: [[UInt16]] = []
        var objectPool: [Any] = []

        mutating func decodeRootObject() -> [String: Any]? {
            guard let ver = readU32(), (1...32).contains(ver) else { return nil }
            guard let val = readValue(decryptWithXOR: false) else { return nil }
            return val as? [String: Any]
        }

        private mutating func readU8() -> UInt8? {
            guard pos + 1 <= buffer.count else { return nil }
            let v = buffer[pos]
            pos += 1
            return v
        }

        private mutating func readU16() -> UInt16? {
            guard pos + 2 <= buffer.count else { return nil }
            var raw: UInt16 = 0
            withUnsafeMutableBytes(of: &raw) { dst in
                dst.copyBytes(from: UnsafeRawBufferPointer(rebasing: buffer[pos..<(pos + 2)]))
            }
            pos += 2
            return UInt16(littleEndian: raw)
        }

        private mutating func readU32() -> UInt32? {
            guard pos + 4 <= buffer.count else { return nil }
            var raw: UInt32 = 0
            withUnsafeMutableBytes(of: &raw) { dst in
                dst.copyBytes(from: UnsafeRawBufferPointer(rebasing: buffer[pos..<(pos + 4)]))
            }
            pos += 4
            return UInt32(littleEndian: raw)
        }

        private mutating func readI32() -> Int32? {
            guard let u = readU32() else { return nil }
            return Int32(bitPattern: u)
        }

        private mutating func readF64() -> Double? {
            guard pos + 8 <= buffer.count else { return nil }
            var bits: UInt64 = 0
            withUnsafeMutableBytes(of: &bits) { dst in
                dst.copyBytes(from: UnsafeRawBufferPointer(rebasing: buffer[pos..<(pos + 8)]))
            }
            pos += 8
            return Double(bitPattern: UInt64(littleEndian: bits))
        }

        private mutating func readPoolIndex(poolSize: Int) -> Int? {
            if poolSize <= 0xFF {
                guard let b = readU8() else { return nil }
                return Int(b)
            } else if poolSize <= 0xFFFF {
                guard let w = readU16() else { return nil }
                return Int(w)
            } else {
                guard let d = readU32() else { return nil }
                return Int(d)
            }
        }

        /// Returns `nil` on decode failure, `.some(nil)` on `0xFFFFFFFF` terminator, or `.some(units)`.
        private mutating func readRawUTF16OrTerminator() -> [UInt16]?? {
            guard let u = readU32() else { return nil }
            if u == 0xFFFF_FFFF {
                return .some(nil)
            }
            if u == 0xFFFF_FFFE {
                guard let idx = readPoolIndex(poolSize: stringPool.count),
                      idx >= 0, idx < stringPool.count else {
                    return nil
                }
                return .some(stringPool[idx])
            }
            let is8Bit = (u & 0x8000_0000) != 0
            let charLen = Int(u & 0x7FFF_FFFF)
            if is8Bit {
                guard charLen >= 0, pos + charLen <= buffer.count else { return nil }
                var units = [UInt16]()
                units.reserveCapacity(charLen)
                for i in 0..<charLen {
                    units.append(UInt16(buffer[pos + i]))
                }
                pos += charLen
                if !units.isEmpty { stringPool.append(units) }
                return .some(units)
            } else {
                let byteLen = charLen * 2
                guard charLen >= 0, byteLen >= 0, pos + byteLen <= buffer.count else { return nil }
                var units = [UInt16](repeating: 0, count: charLen)
                if charLen > 0 {
                    units.withUnsafeMutableBytes { dst in
                        dst.copyBytes(from: UnsafeRawBufferPointer(rebasing: buffer[pos..<(pos + byteLen)]))
                    }
                    #if _endian(big)
                    for i in 0..<charLen { units[i] = UInt16(littleEndian: units[i]) }
                    #endif
                }
                pos += byteLen
                if !units.isEmpty { stringPool.append(units) }
                return .some(units)
            }
        }

        private mutating func readValue(decryptWithXOR: Bool) -> Any? {
            guard let tag = readU8() else { return nil }
            switch tag {
            case 0x01: // ArrayTag
                guard let lengthU32 = readU32() else { return nil }
                let capped = min(Int(lengthU32), 100_000)
                var arr = [Any](repeating: NSNull(), count: max(0, capped))
                let poolSlot = objectPool.count
                objectPool.append(arr)
                while true {
                    guard let idxU32 = readU32() else { return nil }
                    if idxU32 == 0xFFFF_FFFF { break }
                    guard let elem = readValue(decryptWithXOR: false) else { return nil }
                    let idx = Int(idxU32)
                    if idx >= 0 && idx < 100_000 {
                        while arr.count <= idx { arr.append(NSNull()) }
                        arr[idx] = elem
                    }
                }
                while true {
                    guard let keyOpt = readRawUTF16OrTerminator() else { return nil }
                    guard keyOpt != nil else { break }
                    guard readValue(decryptWithXOR: false) != nil else { return nil }
                }
                let cleaned = arr.filter { !($0 is NSNull) }
                objectPool[poolSlot] = cleaned
                return cleaned

            case 0x02: // ObjectTag
                var dict: [String: Any] = [:]
                let poolSlot = objectPool.count
                objectPool.append(dict)
                while true {
                    guard let keyOpt = readRawUTF16OrTerminator() else { return nil }
                    guard let keyUnits = keyOpt else { break }
                    let key = String(decoding: keyUnits, as: UTF16.self)
                    let shouldXOR = !xorKeyUnits.isEmpty && xorDecryptFields.contains(key)
                    guard let val = readValue(decryptWithXOR: shouldXOR) else { return nil }
                    if !(val is NSNull) {
                        dict[key] = val
                    }
                }
                objectPool[poolSlot] = dict
                return dict

            case 0x03, 0x04: // UndefinedTag, NullTag
                return NSNull()

            case 0x05: // IntTag
                guard let i = readI32() else { return nil }
                return Int(i)

            case 0x06: // ZeroTag
                return 0

            case 0x07: // OneTag
                return 1

            case 0x08: // FalseTag
                return false

            case 0x09: // TrueTag
                return true

            case 0x0A, 0x0B: // DoubleTag, DateTag
                guard let d = readF64() else { return nil }
                if d.isFinite, d == d.rounded(), d >= Double(Int64.min / 2), d <= Double(Int64.max / 2) {
                    return Int64(d)
                }
                return d

            case 0x10: // StringTag
                guard let strOpt = readRawUTF16OrTerminator(), let units = strOpt else { return nil }
                if decryptWithXOR {
                    return ZaloWebKitMigrator.xorDecryptUTF16(units, keyUnits: xorKeyUnits)
                }
                return String(decoding: units, as: UTF16.self)

            case 0x11: // EmptyStringTag
                return ""

            case 0x19: // ObjectReferenceTag
                guard let idx = readPoolIndex(poolSize: objectPool.count),
                      idx >= 0, idx < objectPool.count else {
                    return nil
                }
                return objectPool[idx]

            default:
                return nil
            }
        }
    }

    // MARK: - Locating Olaz's Own WebKit IndexedDB (`zdb_<userId>`)

    static func locateOlazWebKitDatabase(userId: String, searchRoots: [URL]? = nil) -> URL? {
        guard !userId.isEmpty else { return nil }
        let targetDBName = "zdb_\(userId)"
        let roots: [URL] = searchRoots ?? defaultWebKitRoots()
        let fm = FileManager.default
        var bestMatch: (url: URL, size: Int64)?

        for root in roots {
            guard fm.fileExists(atPath: root.path),
                  let enumerator = fm.enumerator(
                      at: root,
                      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                      options: [.skipsHiddenFiles, .skipsPackageDescendants]
                  ) else {
                continue
            }
            for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "IndexedDB.sqlite3" {
                guard readIDBDatabaseName(at: fileURL.path) == targetDBName else { continue }
                let sz = Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                if bestMatch == nil || sz > (bestMatch?.size ?? 0) {
                    bestMatch = (fileURL, sz)
                }
            }
        }
        return bestMatch?.url
    }

    private static func defaultWebKitRoots() -> [URL] {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let webkitDir = library.appendingPathComponent("WebKit", isDirectory: true)
        var bundleIds: [String] = []
        if let mainId = Bundle.main.bundleIdentifier, !mainId.isEmpty {
            bundleIds.append(mainId)
        }
        for candidate in ["app.olaz.mac", "dev.swiftzalo.app"] where !bundleIds.contains(candidate) {
            bundleIds.append(candidate)
        }
        return bundleIds.map { webkitDir.appendingPathComponent($0, isDirectory: true) }
    }

    static func readIDBDatabaseName(at sqlitePath: String) -> String? {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(sqlitePath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        defer { if let db { sqlite3_close(db) } }
        guard rc == SQLITE_OK, let db else { return nil }
        sqlite3_busy_timeout(db, 1500)

        var stmt: OpaquePointer?
        let sql = "SELECT value FROM IDBDatabaseInfo WHERE key = 'DatabaseName' LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let colType = sqlite3_column_type(stmt, 0)
        if colType == SQLITE_BLOB {
            let byteCount = Int(sqlite3_column_bytes(stmt, 0))
            guard byteCount > 0, let rawPtr = sqlite3_column_blob(stmt, 0) else { return nil }
            let u16Count = byteCount / 2
            var units = [UInt16](repeating: 0, count: u16Count)
            units.withUnsafeMutableBytes { dst in
                dst.copyBytes(from: UnsafeRawBufferPointer(start: rawPtr, count: u16Count * 2))
            }
            while units.last == 0 { units.removeLast() }
            return String(decoding: units, as: UTF16.self)
        } else if let cStr = sqlite3_column_text(stmt, 0) {
            return String(cString: cStr).replacingOccurrences(of: "\0", with: "")
        }
        return nil
    }

    // MARK: - Phase 1: Instant Metadata + Preview + Recent Messages Migration

    static func migrateBootstrapIfNeeded(
        account: ZaloLoginAccount,
        selfConvId: String,
        into store: ZaloSQLiteStore,
        existingAliases: [String: String] = [:],
        existingPinnedIds: Set<String> = [],
        initialMessageLimit: Int = 15_000,
        searchRoots: [URL]? = nil
    ) async -> BootstrapMigrationResult? {
        guard !account.userId.isEmpty, !account.dkey.isEmpty else { return nil }
        if (try? await store.getPreferenceString(key: donePrefKey)) == "1" {
            return nil
        }
        guard let idbURL = locateOlazWebKitDatabase(userId: account.userId, searchRoots: searchRoots) else {
            return nil
        }

        // If Phase 1 already completed earlier and only older message chunks remain, skip straight to Phase 2 cursor.
        if let savedCursorStr = try? await store.getPreferenceString(key: cursorPrefKey),
           let savedCursor = Int64(savedCursorStr), savedCursor > 0 {
            return BootstrapMigrationResult(
                dbPath: idbURL.path,
                importedProfiles: 0,
                importedGroups: 0,
                importedGlobalIds: 0,
                importedConversations: 0,
                importedMessages: 0,
                remainingCursorRecordID: savedCursor
            )
        }

        let startTime = Date()
        let keyUnits = Array(account.dkey.utf16)
        let myUid = account.userId

        var db: OpaquePointer?
        let openFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(idbURL.path, &db, openFlags, nil)
        defer { if let db { sqlite3_close(db) } }
        guard rc == SQLITE_OK, let db else { return nil }
        sqlite3_busy_timeout(db, 3000)

        let storeMap = loadObjectStoreIds(db: db)
        guard !storeMap.isEmpty else { return nil }

        // 1. global_noiseid -> gidToUid
        var gidToUid: [String: String] = [:]
        if let existingData = try? await store.getPreferenceData(key: "gidToUidMap"),
           let existingMap = (try? JSONSerialization.jsonObject(with: existingData)) as? [String: String] {
            gidToUid = existingMap
        }
        var importedGlobalCount = 0
        if let sid = storeMap["global_noiseid"] {
            forEachRecord(db: db, storeId: sid) { _, raw in
                guard let obj = decodeCloneRecord(raw) else { return }
                let uid = ZaloWireParser.stripUserPrefix(JSONLossless.string(obj["userId"]))
                let gid = JSONLossless.string(obj["globalId"])
                if !uid.isEmpty && !gid.isEmpty {
                    gidToUid[gid] = uid
                    importedGlobalCount += 1
                }
            }
        }
        if !gidToUid.isEmpty, let data = try? JSONSerialization.data(withJSONObject: gidToUid) {
            try? await store.setPreferenceData(key: "gidToUidMap", data: data)
        }

        // 2. friends_info -> cachedProfiles
        var profiles: [String: CachedProfile] = [:]
        if let existingData = try? await store.getPreferenceData(key: "cachedProfiles"),
           let decoded = try? JSONDecoder().decode([String: CachedProfile].self, from: existingData) {
            profiles = decoded
        }
        if let sid = storeMap["friends_info"] {
            forEachRecord(db: db, storeId: sid) { _, raw in
                guard let obj = decodeCloneRecord(raw) else { return }
                let uid = ZaloWireParser.stripUserPrefix(JSONLossless.string(obj["userId"]))
                guard !uid.isEmpty, uid != "0" else { return }
                let dName = JSONLossless.string(obj["displayName"])
                let zName = JSONLossless.string(obj["zaloName"])
                let bestName = !dName.isEmpty ? dName : zName
                let avt = JSONLossless.string(obj["avatar"])
                if !bestName.isEmpty || !avt.isEmpty {
                    profiles[uid] = CachedProfile(name: bestName, avatar: avt)
                }
            }
        }
        if !profiles.isEmpty, let data = try? JSONEncoder().encode(profiles) {
            try? await store.setPreferenceData(key: "cachedProfiles", data: data)
        }

        // 3. group -> cachedGroups
        var groups: [String: CachedGroup] = [:]
        if let existingData = try? await store.getPreferenceData(key: "cachedGroups"),
           let decoded = try? JSONDecoder().decode([String: CachedGroup].self, from: existingData) {
            groups = decoded
        }
        if let sid = storeMap["group"] {
            forEachRecord(db: db, storeId: sid) { _, raw in
                guard let obj = decodeCloneRecord(raw) else { return }
                let rawId = JSONLossless.string(obj["userId"] ?? obj["groupId"] ?? obj["id"])
                let gid = ZaloWireParser.groupConvId(rawId)
                guard !gid.isEmpty else { return }
                let name = JSONLossless.string(obj["displayName"] ?? obj["name"])
                let avt = JSONLossless.string(obj["avatar"] ?? obj["avt"])
                let members = Int(JSONLossless.int64(obj["totalMember"]) ?? 0)
                groups[gid] = CachedGroup(name: name, avatar: avt, members: members)
            }
        }
        if !groups.isEmpty, let data = try? JSONEncoder().encode(groups) {
            try? await store.setPreferenceData(key: "cachedGroups", data: data)
        }

        let nameLookup: (String) -> (name: String, avatar: String)? = { uid in
            let clean = ZaloWireParser.stripUserPrefix(uid)
            if clean == myUid { return ("Bạn", account.avatar) }
            if let alias = existingAliases[clean], !alias.isEmpty {
                return (alias, profiles[clean]?.avatar ?? "")
            }
            if let p = profiles[clean], !p.name.isEmpty {
                return (p.name, p.avatar)
            }
            return nil
        }

        // 4. preview_message -> preview map by convId
        struct PreviewSeed {
            var text: String
            var tsMs: Int64
            var fromMe: Bool
            var senderName: String
        }
        var previewsByConv: [String: PreviewSeed] = [:]
        let msgFields: Set<String> = ["message"]

        if let sid = storeMap["preview_message"] {
            forEachRecord(db: db, storeId: sid) { _, raw in
                guard let obj = decodeCloneRecord(raw, xorDecryptFields: msgFields, xorKeyUnits: keyUnits) else { return }
                let rawConv = JSONLossless.string(obj["convId"] ?? obj["toUid"])
                let isGrp = (obj["isGroup"] as? Bool == true) || ZaloWireParser.isGroupId(rawConv)
                let convId = isGrp ? ZaloWireParser.groupConvId(rawConv) : ZaloWireParser.stripUserPrefix(rawConv)
                guard !convId.isEmpty, convId != "0", convId != "g0", convId != "g\(selfConvId)" else { return }

                let fromUid = ZaloWireParser.stripUserPrefix(JSONLossless.string(obj["fromUid"]))
                let isMine = fromUid.isEmpty || fromUid == "0" || fromUid == myUid
                let tsMs = ZaloWireParser.normalizeTimestampMs(obj["messageTime"])
                let mTypeCode = Int(JSONLossless.int64(obj["messageType"]) ?? 1)
                let wireType = ZaloWireParser.zdbMsgType(for: mTypeCode)
                let dName = JSONLossless.string(obj["dName"])
                let computed = JSONLossless.string(obj["computedMessage"])

                let contentVal: Any = {
                    guard let mStr = obj["message"] as? String, !mStr.isEmpty else { return "" }
                    if let d = mStr.data(using: .utf8), let parsed = JSONLossless.parseAny(d) {
                        return parsed
                    }
                    return mStr
                }()

                let wire: [String: Any] = [
                    "msgId": JSONLossless.string(obj["msgId"]),
                    "cliMsgId": JSONLossless.string(obj["cliMsgId"]),
                    "uidFrom": isMine ? myUid : fromUid,
                    "idTo": isGrp ? ZaloWireParser.cleanGroupId(convId) : (isMine ? convId : myUid),
                    "dName": dName,
                    "msgType": wireType,
                    "ts": tsMs,
                    "content": contentVal,
                    "isMine": isMine,
                    "isGroup": isGrp,
                ]
                var previewText = computed
                if case .message(_, let stored) = ZaloWireParser.parseWireMessage(
                    wire,
                    myUid: myUid,
                    fallbackConvId: convId,
                    isGroupHint: isGrp,
                    selfConvId: selfConvId,
                    nameLookup: nameLookup
                ) {
                    previewText = ZaloWireParser.previewLabel(for: stored.kindTag, text: stored.text)
                } else if previewText.isEmpty {
                    previewText = "[Tin nhắn]"
                }
                if let existing = previewsByConv[convId], existing.tsMs > tsMs {
                    return
                }
                previewsByConv[convId] = PreviewSeed(
                    text: previewText,
                    tsMs: tsMs,
                    fromMe: isMine,
                    senderName: dName
                )
            }
        }

        // 5. Initial newest messages chunk (`ORDER BY recordID DESC LIMIT initialMessageLimit`)
        var importedMessagesCount = 0
        var lowestRecordID: Int64?
        var fetchedMsgRows = 0
        var latestMsgPreviewFallback: [String: PreviewSeed] = [:]

        if let msgSid = storeMap["message"], initialMessageLimit > 0 {
            var batch: [StoredMessage] = []
            batch.reserveCapacity(2500)
            forEachRecordDescending(db: db, storeId: msgSid, beforeRecordID: Int64.max, limit: initialMessageLimit) { recId, raw in
                fetchedMsgRows += 1
                lowestRecordID = recId
                guard let stored = parseZdbMessageRow(
                    raw: raw,
                    keyUnits: keyUnits,
                    myUid: myUid,
                    selfConvId: selfConvId,
                    nameLookup: nameLookup
                ) else { return }

                batch.append(stored)
                importedMessagesCount += 1
                if latestMsgPreviewFallback[stored.convId] == nil || stored.tsMs > (latestMsgPreviewFallback[stored.convId]?.tsMs ?? 0) {
                    latestMsgPreviewFallback[stored.convId] = PreviewSeed(
                        text: ZaloWireParser.previewLabel(for: stored.kindTag, text: stored.text),
                        tsMs: stored.tsMs,
                        fromMe: stored.isMine,
                        senderName: stored.senderName
                    )
                }
                if batch.count >= 2500 {
                    // Flush outside C callback below
                }
            }
            if !batch.isEmpty {
                for start in stride(from: 0, to: batch.count, by: 2500) {
                    let slice = Array(batch[start..<min(start + 2500, batch.count)])
                    try? await store.saveMessages(slice)
                }
            }
        }

        // 6. conversation -> StoredConversation list
        var convById: [String: StoredConversation] = [:]
        var discoveredPinned = existingPinnedIds
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        if let sid = storeMap["conversation"] {
            forEachRecord(db: db, storeId: sid) { _, raw in
                guard let obj = decodeCloneRecord(raw) else { return }
                let rawId = JSONLossless.string(obj["userId"])
                let isGrp = (obj["isGroup"] as? Bool == true) || ZaloWireParser.isGroupId(rawId)
                let convId: String = {
                    if !selfConvId.isEmpty && (rawId == selfConvId || ZaloWireParser.cleanGroupId(rawId) == selfConvId) {
                        return selfConvId
                    }
                    return isGrp ? ZaloWireParser.groupConvId(rawId) : ZaloWireParser.stripUserPrefix(rawId)
                }()
                guard !convId.isEmpty, convId != "0", convId != "g0", convId != "g\(selfConvId)" else { return }
                let effectiveGroup = convId != selfConvId && ZaloWireParser.isGroupId(convId)
                let isPinnedRow = (JSONLossless.int64(obj["pinned"]) ?? 0) > 0 || (obj["pinned"] as? Bool == true)
                if isPinnedRow { discoveredPinned.insert(convId) }

                let prev = previewsByConv[convId] ?? latestMsgPreviewFallback[convId]
                let resolved = resolveConvMeta(
                    convId: convId,
                    isGroup: effectiveGroup,
                    selfConvId: selfConvId,
                    aliases: existingAliases,
                    profiles: profiles,
                    groups: groups,
                    fallbackSenderName: (prev?.fromMe == false) ? (prev?.senderName ?? "") : ""
                )
                convById[convId] = StoredConversation(
                    id: convId,
                    isGroup: effectiveGroup,
                    name: resolved.name,
                    avatar: resolved.avatar,
                    pinned: discoveredPinned.contains(convId),
                    members: resolved.members,
                    unread: 0,
                    previewText: prev?.text ?? "",
                    previewTsMs: prev?.tsMs ?? 0,
                    previewFromMe: prev?.fromMe ?? false,
                    updatedAtMs: prev?.tsMs ?? nowMs
                )
            }
        }

        // Ensure any conversation present in `preview_message` or recent messages is also represented.
        for (convId, prev) in previewsByConv where convById[convId] == nil {
            let effectiveGroup = convId != selfConvId && ZaloWireParser.isGroupId(convId)
            let resolved = resolveConvMeta(
                convId: convId,
                isGroup: effectiveGroup,
                selfConvId: selfConvId,
                aliases: existingAliases,
                profiles: profiles,
                groups: groups,
                fallbackSenderName: prev.fromMe ? "" : prev.senderName
            )
            convById[convId] = StoredConversation(
                id: convId,
                isGroup: effectiveGroup,
                name: resolved.name,
                avatar: resolved.avatar,
                pinned: discoveredPinned.contains(convId),
                members: resolved.members,
                unread: 0,
                previewText: prev.text,
                previewTsMs: prev.tsMs,
                previewFromMe: prev.fromMe,
                updatedAtMs: prev.tsMs > 0 ? prev.tsMs : nowMs
            )
        }

        if !convById.isEmpty {
            try? await store.saveConversations(Array(convById.values))
        }
        if discoveredPinned != existingPinnedIds {
            try? await store.setPreferenceStrings(key: "pinnedIds", value: Array(discoveredPinned))
        }
        if importedMessagesCount > 0 || convById.count >= 10 {
            try? await store.setPreferenceString(key: "didOfferInitialSync", value: "1")
        }

        let hasMoreMessages = (fetchedMsgRows >= initialMessageLimit) && (lowestRecordID != nil)
        if let cursor = lowestRecordID, hasMoreMessages {
            try? await store.setPreferenceString(key: cursorPrefKey, value: String(cursor))
        } else {
            try? await store.deletePreference(key: cursorPrefKey)
            try? await store.setPreferenceString(key: donePrefKey, value: "1")
        }

        let elapsedMs = Int((Date().timeIntervalSince(startTime) * 1000).rounded())
        let cCount = convById.count
        let pCount = profiles.count
        let gCount = groups.count
        let mCount = importedMessagesCount
        await MainActor.run {
            EngineLog.shared.write("webkit-migrate: phase1 convs=\(cCount) profiles=\(pCount) groups=\(gCount) msgs=\(mCount) more=\(hasMoreMessages) in \(elapsedMs)ms")
        }

        return BootstrapMigrationResult(
            dbPath: idbURL.path,
            importedProfiles: pCount,
            importedGroups: gCount,
            importedGlobalIds: importedGlobalCount,
            importedConversations: cCount,
            importedMessages: mCount,
            remainingCursorRecordID: hasMoreMessages ? lowestRecordID : nil
        )
    }

    // MARK: - Phase 2: Streaming Remaining Historical Messages in Background

    static func migrateRemainingMessages(
        dbPath: String,
        startBeforeRecordID: Int64,
        account: ZaloLoginAccount,
        selfConvId: String,
        aliases: [String: String],
        profiles: [String: CachedProfile],
        into store: ZaloSQLiteStore,
        chunkSize: Int = 2_000
    ) async -> Int {
        guard !account.userId.isEmpty, !account.dkey.isEmpty else { return 0 }
        let keyUnits = Array(account.dkey.utf16)
        let myUid = account.userId

        var db: OpaquePointer?
        let rc = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        defer { if let db { sqlite3_close(db) } }
        guard rc == SQLITE_OK, let db else { return 0 }
        sqlite3_busy_timeout(db, 3000)

        let storeMap = loadObjectStoreIds(db: db)
        guard let msgSid = storeMap["message"] else {
            try? await store.deletePreference(key: cursorPrefKey)
            try? await store.setPreferenceString(key: donePrefKey, value: "1")
            return 0
        }

        let nameLookup: (String) -> (name: String, avatar: String)? = { uid in
            let clean = ZaloWireParser.stripUserPrefix(uid)
            if clean == myUid { return ("Bạn", account.avatar) }
            if let alias = aliases[clean], !alias.isEmpty {
                return (alias, profiles[clean]?.avatar ?? "")
            }
            if let p = profiles[clean], !p.name.isEmpty {
                return (p.name, p.avatar)
            }
            return nil
        }

        var cursor = startBeforeRecordID
        var totalImported = 0
        let t0 = Date()

        while !Task.isCancelled {
            var chunkRows = 0
            var nextCursor = cursor
            var batch: [StoredMessage] = []
            batch.reserveCapacity(chunkSize)

            forEachRecordDescending(db: db, storeId: msgSid, beforeRecordID: cursor, limit: chunkSize) { recId, raw in
                chunkRows += 1
                nextCursor = recId
                if let stored = parseZdbMessageRow(
                    raw: raw,
                    keyUnits: keyUnits,
                    myUid: myUid,
                    selfConvId: selfConvId,
                    nameLookup: nameLookup
                ) {
                    batch.append(stored)
                }
            }

            if !batch.isEmpty {
                try? await store.saveMessages(batch)
                totalImported += batch.count
            }

            if chunkRows < chunkSize || nextCursor >= cursor {
                try? await store.deletePreference(key: cursorPrefKey)
                try? await store.setPreferenceString(key: donePrefKey, value: "1")
                let secs = String(format: "%.2f", Date().timeIntervalSince(t0))
                let finalCount = totalImported
                await MainActor.run {
                    EngineLog.shared.write("webkit-migrate: phase2 completed imported=\(finalCount) in \(secs)s")
                }
                break
            } else {
                cursor = nextCursor
                try? await store.setPreferenceString(key: cursorPrefKey, value: String(cursor))
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        return totalImported
    }

    // MARK: - Internal Record Helpers

    private static func resolveConvMeta(
        convId: String,
        isGroup: Bool,
        selfConvId: String,
        aliases: [String: String],
        profiles: [String: CachedProfile],
        groups: [String: CachedGroup],
        fallbackSenderName: String
    ) -> (name: String, avatar: String, members: Int) {
        if convId == selfConvId {
            return ("Cloud của tôi", "", 0)
        }
        if isGroup {
            if let g = groups[convId] {
                return (g.name.isEmpty ? convId : g.name, g.avatar, g.members)
            }
            return (convId, "", 0)
        }
        if let alias = aliases[convId], !alias.isEmpty {
            return (alias, profiles[convId]?.avatar ?? "", 0)
        }
        if let p = profiles[convId], !p.name.isEmpty {
            return (p.name, p.avatar, 0)
        }
        if !fallbackSenderName.isEmpty {
            return (fallbackSenderName, profiles[convId]?.avatar ?? "", 0)
        }
        return (convId, profiles[convId]?.avatar ?? "", 0)
    }

    private static func parseZdbMessageRow(
        raw: UnsafeRawBufferPointer,
        keyUnits: [UInt16],
        myUid: String,
        selfConvId: String,
        nameLookup: ((String) -> (name: String, avatar: String)?)?
    ) -> StoredMessage? {
        let msgFields: Set<String> = ["message"]
        guard let obj = decodeCloneRecord(raw, xorDecryptFields: msgFields, xorKeyUnits: keyUnits) else {
            return nil
        }
        let rawToUid = JSONLossless.string(obj["toUid"] ?? obj["convId"])
        let isGrp = ZaloWireParser.isGroupId(rawToUid)
        let convId: String = {
            if !selfConvId.isEmpty && (rawToUid == selfConvId || ZaloWireParser.cleanGroupId(rawToUid) == selfConvId) {
                return selfConvId
            }
            return isGrp ? ZaloWireParser.groupConvId(rawToUid) : ZaloWireParser.stripUserPrefix(rawToUid)
        }()
        guard !convId.isEmpty, convId != "0", convId != "g0", convId != "g\(selfConvId)" else {
            return nil
        }
        let effectiveGroup = convId != selfConvId && ZaloWireParser.isGroupId(convId)

        let fromUid = ZaloWireParser.stripUserPrefix(JSONLossless.string(obj["fromUid"]))
        let isMine = fromUid.isEmpty || fromUid == "0" || fromUid == myUid
        let originType = JSONLossless.string(obj["originMsgType"])
        let mTypeCode = Int(JSONLossless.int64(obj["msgType"]) ?? 1)
        let wireType = !originType.isEmpty ? originType : ZaloWireParser.zdbMsgType(for: mTypeCode)
        let tsMs = ZaloWireParser.normalizeTimestampMs(obj["sendDttm"] ?? obj["serverTime"] ?? obj["localDttm"])

        let contentVal: Any = {
            guard let mStr = obj["message"] as? String, !mStr.isEmpty else { return "" }
            if (mStr.hasPrefix("{") || mStr.hasPrefix("[") || mStr.hasPrefix("\"")),
               let d = mStr.data(using: .utf8),
               let parsed = JSONLossless.parseAny(d) {
                return parsed
            }
            return mStr
        }()

        var wire: [String: Any] = [
            "msgId": JSONLossless.string(obj["msgId"]),
            "cliMsgId": JSONLossless.string(obj["cliMsgId"]),
            "uidFrom": isMine ? myUid : fromUid,
            "idTo": effectiveGroup ? ZaloWireParser.cleanGroupId(convId) : (isMine ? convId : myUid),
            "dName": JSONLossless.string(obj["dName"]),
            "msgType": wireType,
            "ts": tsMs,
            "content": contentVal,
            "isMine": isMine,
            "isGroup": effectiveGroup,
        ]
        if let quote = obj["quote"] as? [String: Any] {
            wire["quote"] = quote
        }
        if let mentions = obj["mentions"] as? [[String: Any]], !mentions.isEmpty {
            wire["mentions"] = mentions
        }

        if case .message(_, let stored) = ZaloWireParser.parseWireMessage(
            wire,
            myUid: myUid,
            fallbackConvId: convId,
            isGroupHint: effectiveGroup,
            selfConvId: selfConvId,
            nameLookup: nameLookup
        ) {
            return stored
        }
        return nil
    }

    private static func loadObjectStoreIds(db: OpaquePointer) -> [String: Int64] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, name FROM ObjectStoreInfo;", -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }
        var map: [String: Int64] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sid = sqlite3_column_int64(stmt, 0)
            if let cName = sqlite3_column_text(stmt, 1) {
                map[String(cString: cName)] = sid
            }
        }
        return map
    }

    private static func forEachRecord(
        db: OpaquePointer,
        storeId: Int64,
        body: (Int64, UnsafeRawBufferPointer) -> Void
    ) {
        var stmt: OpaquePointer?
        let sql = "SELECT recordID, value FROM Records WHERE objectStoreID = ?1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, storeId)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let recId = sqlite3_column_int64(stmt, 0)
            let len = Int(sqlite3_column_bytes(stmt, 1))
            guard len > 0, let ptr = sqlite3_column_blob(stmt, 1) else { continue }
            body(recId, UnsafeRawBufferPointer(start: ptr, count: len))
        }
    }

    private static func forEachRecordDescending(
        db: OpaquePointer,
        storeId: Int64,
        beforeRecordID: Int64,
        limit: Int,
        body: (Int64, UnsafeRawBufferPointer) -> Void
    ) {
        var stmt: OpaquePointer?
        let sql = """
        SELECT recordID, value FROM Records
        WHERE objectStoreID = ?1 AND recordID < ?2
        ORDER BY recordID DESC
        LIMIT ?3;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, storeId)
        sqlite3_bind_int64(stmt, 2, beforeRecordID)
        sqlite3_bind_int(stmt, 3, Int32(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            let recId = sqlite3_column_int64(stmt, 0)
            let len = Int(sqlite3_column_bytes(stmt, 1))
            guard len > 0, let ptr = sqlite3_column_blob(stmt, 1) else { continue }
            body(recId, UnsafeRawBufferPointer(start: ptr, count: len))
        }
    }
}
