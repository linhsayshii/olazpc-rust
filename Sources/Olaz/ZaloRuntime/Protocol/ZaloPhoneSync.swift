import Foundation
import os

// MARK: - ASAR libzproto WASM Reader

enum AsarWasmReader {
    private static let cachedWasm = OSAllocatedUnfairLock<Data?>(initialState: nil)

    static var cachedFileURL: URL {
        ZaloRuntime.root.appendingPathComponent("libzproto_wasm_bg.wasm")
    }

    static func loadZprotoWasm() -> Data? {
        if let hit = cachedWasm.withLock({ $0 }), isValidWasm(hit) {
            return hit
        }

        let fm = FileManager.default
        if let envPath = ProcessInfo.processInfo.environment["ZPROTO_WASM_PATH"],
           !envPath.isEmpty,
           let data = try? Data(contentsOf: URL(fileURLWithPath: envPath)),
           isValidWasm(data) {
            cachedWasm.withLock { $0 = data }
            return data
        }

        let localCache = cachedFileURL
        if fm.fileExists(atPath: localCache.path),
           let data = try? Data(contentsOf: localCache),
           isValidWasm(data) {
            cachedWasm.withLock { $0 = data }
            return data
        }

        let home = fm.homeDirectoryForCurrentUser
        let asarCandidates = [
            URL(fileURLWithPath: "/Applications/Zalo.app/Contents/Resources/app.asar"),
            home.appendingPathComponent("Applications/Zalo.app/Contents/Resources/app.asar"),
            ZaloRuntime.current.appendingPathComponent("Contents/Resources/app.asar"),
        ]
        for asarURL in asarCandidates where fm.fileExists(atPath: asarURL.path) {
            if let data = readWasmFromAsar(at: asarURL) {
                cacheToDisk(data)
                cachedWasm.withLock { $0 = data }
                return data
            }
        }
        return nil
    }

    @discardableResult
    static func cacheWasmIfPresent(inZaloApp appURL: URL) -> Bool {
        let asarURL = appURL.appendingPathComponent("Contents/Resources/app.asar")
        guard FileManager.default.fileExists(atPath: asarURL.path),
              let data = readWasmFromAsar(at: asarURL) else {
            return false
        }
        cacheToDisk(data)
        cachedWasm.withLock { $0 = data }
        return true
    }

    private static func cacheToDisk(_ data: Data) {
        let dst = cachedFileURL
        try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: dst, options: .atomic)
    }

    private static func isValidWasm(_ data: Data) -> Bool {
        data.count >= 8 && data.prefix(4) == Data([0x00, 0x61, 0x73, 0x6D])
    }

    /// Reads `pc-dist/libs/libzproto_wasm_bg.*.wasm` directly from an Electron ASAR archive without extraction.
    static func readWasmFromAsar(at asarURL: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: asarURL) else { return nil }
        defer { try? handle.close() }

        guard let head = try? handle.read(upToCount: 16), head.count == 16 else { return nil }
        let headerSize = readUInt32LE(head, at: 4)
        let jsonLen = readUInt32LE(head, at: 12)
        guard jsonLen > 0, jsonLen < 32_000_000, headerSize >= jsonLen else { return nil }

        guard let jsonBuf = try? handle.read(upToCount: Int(jsonLen)), jsonBuf.count == Int(jsonLen),
              let manifest = JSONLossless.parseObject(jsonBuf),
              let rootFiles = manifest["files"] as? [String: Any],
              let pcDist = rootFiles["pc-dist"] as? [String: Any],
              let pcDistFiles = pcDist["files"] as? [String: Any],
              let libs = pcDistFiles["libs"] as? [String: Any],
              let libFiles = libs["files"] as? [String: Any] else {
            return nil
        }

        guard let matchName = libFiles.keys.sorted().first(where: {
            $0.hasPrefix("libzproto_wasm_bg.") && $0.hasSuffix(".wasm")
        }),
              let entry = libFiles[matchName] as? [String: Any] else {
            return nil
        }
        if JSONLossless.bool(entry["unpacked"]) == true {
            return nil
        }
        guard let size = JSONLossless.int64(entry["size"]).map(Int.init),
              size > 8, size < 32_000_000,
              let offsetVal = JSONLossless.int64(entry["offset"]),
              offsetVal >= 0 else {
            return nil
        }

        let fileOffset = UInt64(8) + UInt64(headerSize) + UInt64(offsetVal)
        do {
            try handle.seek(toOffset: fileOffset)
            guard let wasm = try handle.read(upToCount: size), wasm.count == size, isValidWasm(wasm) else {
                return nil
            }
            return wasm
        } catch {
            return nil
        }
    }

    private static func readUInt32LE(_ data: Data, at index: Int) -> UInt32 {
        let base = data.startIndex + index
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }
}

// MARK: - Zstandard Decompression

enum ZstdDecompressor {
    private static let zstdMagic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]

    private struct ZstdOutBuffer {
        var dst: UnsafeMutableRawPointer?
        var size: Int
        var pos: Int
    }

    private struct ZstdInBuffer {
        var src: UnsafeRawPointer?
        var size: Int
        var pos: Int
    }

    private struct API: @unchecked Sendable {
        let createDStream: @convention(c) () -> OpaquePointer?
        let freeDStream: @convention(c) (OpaquePointer) -> Int
        let initDStream: @convention(c) (OpaquePointer) -> Int
        let decompressStream: @convention(c) (OpaquePointer, UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int
        let isError: @convention(c) (Int) -> UInt32
    }

    private static let loadedAPI = OSAllocatedUnfairLock<API?>(initialState: nil)
    private static let attemptedLoad = OSAllocatedUnfairLock<Bool>(initialState: false)

    static func hasZstdMagic(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4).elementsEqual(zstdMagic)
    }

    static func decompressIfNeeded(_ data: Data) -> Data {
        guard hasZstdMagic(data) else { return data }
        return decompressZstd(data) ?? data
    }

    static func decompressZstd(_ data: Data) -> Data? {
        guard !data.isEmpty else { return data }
        if let api = resolveAPI() {
            if let out = decompressWithAPI(api, data: data) {
                return out
            }
        }
        return decompressWithCLI(data)
    }

    private static func resolveAPI() -> API? {
        if let cached = loadedAPI.withLock({ $0 }) { return cached }
        let alreadyTried = attemptedLoad.withLock { val in
            let prev = val
            val = true
            return prev
        }
        if alreadyTried { return nil }

        let candidates = [
            "/opt/homebrew/lib/libzstd.dylib",
            "/usr/local/lib/libzstd.dylib",
            "libzstd.dylib",
            "libzstd.1.dylib",
        ]
        for path in candidates {
            guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { continue }
            guard let sCreate = dlsym(handle, "ZSTD_createDStream"),
                  let sFree = dlsym(handle, "ZSTD_freeDStream"),
                  let sInit = dlsym(handle, "ZSTD_initDStream"),
                  let sDecompress = dlsym(handle, "ZSTD_decompressStream"),
                  let sIsError = dlsym(handle, "ZSTD_isError") else {
                continue
            }
            let api = API(
                createDStream: unsafeBitCast(sCreate, to: (@convention(c) () -> OpaquePointer?).self),
                freeDStream: unsafeBitCast(sFree, to: (@convention(c) (OpaquePointer) -> Int).self),
                initDStream: unsafeBitCast(sInit, to: (@convention(c) (OpaquePointer) -> Int).self),
                decompressStream: unsafeBitCast(sDecompress, to: (@convention(c) (OpaquePointer, UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int).self),
                isError: unsafeBitCast(sIsError, to: (@convention(c) (Int) -> UInt32).self)
            )
            loadedAPI.withLock { $0 = api }
            return api
        }
        return nil
    }

    private static func decompressWithAPI(_ api: API, data: Data) -> Data? {
        guard let dstream = api.createDStream() else { return nil }
        defer { _ = api.freeDStream(dstream) }
        guard api.isError(api.initDStream(dstream)) == 0 else { return nil }

        var output = Data()
        let chunkCap = 65_536
        var chunk = [UInt8](repeating: 0, count: chunkCap)
        let maxDecompressedBytes = 64 * 1024 * 1024

        let ok = data.withUnsafeBytes { rawBuf -> Bool in
            guard let base = rawBuf.baseAddress else { return false }
            var inBuf = ZstdInBuffer(src: base, size: rawBuf.count, pos: 0)
            while inBuf.pos < inBuf.size {
                var produced = 0
                let ret = chunk.withUnsafeMutableBytes { outRaw -> Int in
                    var outBuf = ZstdOutBuffer(dst: outRaw.baseAddress, size: outRaw.count, pos: 0)
                    let code = withUnsafeMutablePointer(to: &outBuf) { outPtr in
                        withUnsafeMutablePointer(to: &inBuf) { inPtr in
                            api.decompressStream(dstream, UnsafeMutableRawPointer(outPtr), UnsafeMutableRawPointer(inPtr))
                        }
                    }
                    produced = outBuf.pos
                    return code
                }
                if api.isError(ret) != 0 {
                    return false
                }
                if produced > 0 {
                    guard output.count + produced <= maxDecompressedBytes else { return false }
                    output.append(contentsOf: chunk.prefix(produced))
                } else if inBuf.pos == inBuf.size {
                    break
                }
            }
            return true
        }
        return ok ? output : nil
    }

    private static func decompressWithCLI(_ data: Data) -> Data? {
        let candidates = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
        guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool)
        proc.arguments = ["-d", "-c", "-q"]
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            return nil
        }
        inPipe.fileHandleForWriting.write(data)
        try? inPipe.fileHandleForWriting.close()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return proc.terminationStatus == 0 ? outData : nil
    }
}

// MARK: - Protobuf Parser for Phone Sync Chunks (`proto.Sync2.Conversation` & `proto.Sync2.Message`)

enum ZaloSyncProtobufParser {
    struct ProtoConversation: Sendable, Equatable {
        /// Global ID (`convId` field 1): group globalId when `convType == 2`, user globalId when `convType == 1`.
        var globalId: String = ""
        /// `1` = 1-1 (`CONV_TYPE_ONEONE`), `2` = group (`CONV_TYPE_GROUP`).
        var convType: Int32 = 0
        var respondedByMe: Bool = false
        var lastTs: UInt64 = 0
        var lastGlobalId: String = ""
        var lastClientId: UInt64 = 0

        var isGroup: Bool { convType == 2 }
    }

    struct ProtoAttach: Sendable, Equatable {
        var type: Int32 = 0
        var typeName: String = ""
        var extInfo: String = ""
        var action: String = ""
        var params: String = ""
        var title: String = ""
        var href: String = ""
        var thumb: String = ""
        var description: String = ""
        var catId: Int32 = 0
        var id: Int32 = 0
        var childNumber: Int32 = 0
    }

    struct ProtoMention: Sendable, Equatable {
        var uid: String = ""
        var pos: Int32 = 0
        var len: Int32 = 0
        var type: Int32 = 0
    }

    struct ProtoQuote: Sendable, Equatable {
        var attach: String = ""
        var ownerId: String = ""
        var ts: Int64 = 0
        var fromD: String = ""
        var cliMsgId: Int64 = 0
        var globalMsgId: String = ""
        var msg: String = ""
        var cliMsgType: Int32 = 0
    }

    struct ProtoMetaData: Sendable, Equatable {
        var attaches: [ProtoAttach] = []
        var mentions: [ProtoMention] = []
        var quote: ProtoQuote?
        var ttl: Int32 = 0
    }

    struct ProtoMsg: Sendable, Equatable {
        var senderId: String = ""
        var clientId: UInt64 = 0
        var msgStatus: Int32 = 0
        var msgType: Int32 = 0
        var timestamp: UInt64 = 0
        var globalId: String = ""
        var content: String = ""
        var metaData: ProtoMetaData?
    }

    struct ProtoPartition: Sendable, Equatable {
        var id: String = ""
        var messages: [ProtoMsg] = []
    }

    // MARK: Conversation SyncChunk

    static func parseConversationSyncChunk(_ data: Data) -> [ProtoConversation] {
        let bytes = [UInt8](data)
        return parseConversationSyncChunk(bytes[bytes.startIndex..<bytes.endIndex]) ?? []
    }

    private static func parseConversationSyncChunk(_ slice: ArraySlice<UInt8>) -> [ProtoConversation]? {
        var items: [ProtoConversation] = []
        var offset = slice.startIndex
        while offset < slice.endIndex {
            guard let (tag, next) = parseVarint(slice, offset: offset) else { return nil }
            offset = next
            let fieldNum = tag >> 3
            let wireType = tag & 0x07
            switch (fieldNum, wireType) {
            case (2, 2):
                guard let (sub, after) = parseLengthDelimited(slice, offset: offset) else { return nil }
                if let c = parseConversation(sub), !c.globalId.isEmpty {
                    items.append(c)
                }
                offset = after
            default:
                guard let after = skipField(slice, offset: offset, wireType: wireType) else { return nil }
                offset = after
            }
        }
        return items
    }

    private static func parseConversation(_ slice: ArraySlice<UInt8>) -> ProtoConversation? {
        var c = ProtoConversation()
        var offset = slice.startIndex
        while offset < slice.endIndex {
            guard let (tag, next) = parseVarint(slice, offset: offset) else { return nil }
            offset = next
            let fieldNum = tag >> 3
            let wireType = tag & 0x07
            switch (fieldNum, wireType) {
            case (1, 2):
                guard let (sub, after) = parseLengthDelimited(slice, offset: offset) else { return nil }
                c.globalId = String(decoding: sub, as: UTF8.self)
                offset = after
            case (2, 0):
                guard let (v, after) = parseVarint(slice, offset: offset) else { return nil }
                c.convType = Int32(truncatingIfNeeded: v)
                offset = after
            case (3, 0):
                guard let (v, after) = parseVarint(slice, offset: offset) else { return nil }
                c.respondedByMe = (v != 0)
                offset = after
            case (4, 0):
                guard let (v, after) = parseVarint(slice, offset: offset) else { return nil }
                c.lastTs = v
                offset = after
            case (5, 0):
                guard let (v, after) = parseVarint(slice, offset: offset) else { return nil }
                c.lastGlobalId = v > 0 ? String(v) : ""
                offset = after
            case (5, 2):
                guard let (sub, after) = parseLengthDelimited(slice, offset: offset) else { return nil }
                c.lastGlobalId = String(decoding: sub, as: UTF8.self)
                offset = after
            case (6, 0):
                guard let (v, after) = parseVarint(slice, offset: offset) else { return nil }
                c.lastClientId = v
                offset = after
            default:
                guard let after = skipField(slice, offset: offset, wireType: wireType) else { return nil }
                offset = after
            }
        }
        return c
    }

    // MARK: Message SyncChunk

    static func parseSyncChunk(_ data: Data) -> [ProtoPartition] {
        let bytes = [UInt8](data)
        return parseSyncChunk(bytes[bytes.startIndex..<bytes.endIndex]) ?? []
    }

    private static func parseSyncChunk(_ slice: ArraySlice<UInt8>) -> [ProtoPartition]? {
        var parts: [ProtoPartition] = []
        var offset = slice.startIndex
        while offset < slice.endIndex {
            guard let (tag, next) = parseVarint(slice, offset: offset) else { return nil }
            offset = next
            let fieldNum = tag >> 3
            let wireType = tag & 0x07
            switch (fieldNum, wireType) {
            case (2, 2):
                guard let (sub, after) = parseLengthDelimited(slice, offset: offset) else { return nil }
                if let p = parsePartition(sub) {
                    parts.append(p)
                }
                offset = after
            default:
                guard let after = skipField(slice, offset: offset, wireType: wireType) else { return nil }
                offset = after
            }
        }
        return parts
    }

    private static func parsePartition(_ slice: ArraySlice<UInt8>) -> ProtoPartition? {
        var part = ProtoPartition()
        var offset = slice.startIndex
        while offset < slice.endIndex {
            guard let (tag, next) = parseVarint(slice, offset: offset) else { return nil }
            offset = next
            let fieldNum = tag >> 3
            let wireType = tag & 0x07
            switch (fieldNum, wireType) {
            case (1, 2):
                guard let (sub, after) = parseLengthDelimited(slice, offset: offset) else { return nil }
                part.id = String(decoding: sub, as: UTF8.self)
                offset = after
            case (2, 2):
                guard let (sub, after) = parseLengthDelimited(slice, offset: offset) else { return nil }
                if let m = parseMessage(sub) {
                    part.messages.append(m)
                }
                offset = after
            default:
                guard let after = skipField(slice, offset: offset, wireType: wireType) else { return nil }
                offset = after
            }
        }
        return part
    }

    private static func parseMessage(_ slice: ArraySlice<UInt8>) -> ProtoMsg? {
        var msg = ProtoMsg()
        var offset = slice.startIndex
        while offset < slice.endIndex {
            guard let (tag, next) = parseVarint(slice, offset: offset) else { return nil }
            offset = next
            let fieldNum = tag >> 3
            let wireType = tag & 0x07
            switch (fieldNum, wireType) {
            case (1, 2):
                guard let (sub, after) = parseLengthDelimited(slice, offset: offset) else { return nil }
                msg.senderId = String(decoding: sub, as: UTF8.self)
                offset = after
            case (2, 0):
                guard let (val, after) = parseVarint(slice, offset: offset) else { return nil }
                msg.clientId = val
                offset = after
            case (3, 0):
                guard let (val, after) = parseVarint(slice, offset: offset) else { return nil }
                msg.msgStatus = Int32(truncatingIfNeeded: val)
                offset = after
            case (4, 0):
                guard let (val, after) = parseVarint(slice, offset: offset) else { return nil }
                msg.msgType = Int32(truncatingIfNeeded: val)
                offset = after
            case (5, 0):
                guard let (val, after) = parseVarint(slice, offset: offset) else { return nil }
                msg.timestamp = val
                offset = after
            case (6, 0):
                // Official `proto.Sync2.Message.globalId` is `int64` varint (`wireType == 0`).
                guard let (val, after) = parseVarint(slice, offset: offset) else { return nil }
                if val > 0 {
                    let signed = Int64(bitPattern: val)
                    msg.globalId = signed >= 0 ? String(signed) : String(val)
                }
                offset = after
            case (6, 2):
                // Legacy string fallback for synthetic unit test fixtures.
                guard let (sub, after) = parseLengthDelimited(slice, offset: offset) else { return nil }
                msg.globalId = String(decoding: sub, as: UTF8.self)
                offset = after
            case (7, 2):
                guard let (sub, after) = parseLengthDelimited(slice, offset: offset) else { return nil }
                msg.content = String(decoding: sub, as: UTF8.self)
                offset = after
            case (8, 2):
                guard let (sub, after) = parseLengthDelimited(slice, offset: offset) else { return nil }
                msg.metaData = parseMetaData(sub)
                offset = after
            default:
                guard let after = skipField(slice, offset: offset, wireType: wireType) else { return nil }
                offset = after
            }
        }
        return msg
    }

    private static func parseMetaData(_ slice: ArraySlice<UInt8>) -> ProtoMetaData? {
        var meta = ProtoMetaData()
        var offset = slice.startIndex
        while offset < slice.endIndex {
            guard let (tag, next) = parseVarint(slice, offset: offset) else { return nil }
            offset = next
            let fieldNum = tag >> 3
            let wireType = tag & 0x07
            switch (fieldNum, wireType) {
            case (1, 2):
                guard let (sub, after) = parseLengthDelimited(slice, offset: offset) else { return nil }
                if let att = parseAttach(sub) { meta.attaches.append(att) }
                offset = after
            case (2, 2):
                guard let (sub, after) = parseLengthDelimited(slice, offset: offset) else { return nil }
                if let m = parseMention(sub) { meta.mentions.append(m) }
                offset = after
            case (4, 2):
                guard let (sub, after) = parseLengthDelimited(slice, offset: offset) else { return nil }
                meta.quote = parseQuote(sub)
                offset = after
            case (6, 0):
                guard let (v, after) = parseVarint(slice, offset: offset) else { return nil }
                meta.ttl = Int32(truncatingIfNeeded: v)
                offset = after
            default:
                guard let after = skipField(slice, offset: offset, wireType: wireType) else { return nil }
                offset = after
            }
        }
        return meta
    }

    private static func parseAttach(_ slice: ArraySlice<UInt8>) -> ProtoAttach? {
        var att = ProtoAttach()
        var offset = slice.startIndex
        while offset < slice.endIndex {
            guard let (tag, next) = parseVarint(slice, offset: offset) else { return nil }
            offset = next
            let fieldNum = tag >> 3
            let wireType = tag & 0x07
            switch (fieldNum, wireType) {
            case (1, 0):
                guard let (v, after) = parseVarint(slice, offset: offset) else { return nil }
                att.type = Int32(truncatingIfNeeded: v)
                offset = after
            case (1, 2):
                guard let (sub, after) = parseLengthDelimited(slice, offset: offset) else { return nil }
                att.typeName = String(decoding: sub, as: UTF8.self)
                offset = after
            case (2, 2):
                guard let (sub, after) = parseLengthDelimited(slice, offset: offset) else { return nil }
                att.extInfo = String(decoding: sub, as: UTF8.self)
                offset = after
            case (3, 2):
                guard let (sub, after) = parseLengthDelimited(slice, offset: offset) else { return nil }
                att.action = String(decoding: sub, as: UTF8.self)
                offset = after
            case (4, 2):
                guard let (sub, after) = parseLengthDelimited(slice, offset: offset) else { return nil }
                att.params = String(decoding: sub, as: UTF8.self)
                offset = after
            case (5, 2):
                guard let (sub, after) = parseLengthDelimited(slice, offset: offset) else { return nil }
                att.title = String(decoding: sub, as: UTF8.self)
                offset = after
            case (6, 2):
                guard let (sub, after) = parseLengthDelimited(slice, offset: offset) else { return nil }
                att.href = String(decoding: sub, as: UTF8.self)
                offset = after
            case (7, 2):
                guard let (sub, after) = parseLengthDelimited(slice, offset: offset) else { return nil }
                att.thumb = String(decoding: sub, as: UTF8.self)
                offset = after
            case (8, 2):
                guard let (sub, after) = parseLengthDelimited(slice, offset: offset) else { return nil }
                att.description = String(decoding: sub, as: UTF8.self)
                offset = after
            case (9, 0):
                guard let (v, after) = parseVarint(slice, offset: offset) else { return nil }
                att.catId = Int32(truncatingIfNeeded: v)
                offset = after
            case (10, 0):
                guard let (v, after) = parseVarint(slice, offset: offset) else { return nil }
                att.id = Int32(truncatingIfNeeded: v)
                offset = after
            case (11, 0):
                guard let (v, after) = parseVarint(slice, offset: offset) else { return nil }
                att.childNumber = Int32(truncatingIfNeeded: v)
                offset = after
            default:
                guard let after = skipField(slice, offset: offset, wireType: wireType) else { return nil }
                offset = after
            }
        }
        return att
    }

    private static func parseMention(_ slice: ArraySlice<UInt8>) -> ProtoMention? {
        var m = ProtoMention()
        var offset = slice.startIndex
        while offset < slice.endIndex {
            guard let (tag, next) = parseVarint(slice, offset: offset) else { return nil }
            offset = next
            let fieldNum = tag >> 3
            let wireType = tag & 0x07
            switch (fieldNum, wireType) {
            case (1, 2):
                guard let (sub, after) = parseLengthDelimited(slice, offset: offset) else { return nil }
                m.uid = String(decoding: sub, as: UTF8.self)
                offset = after
            case (2, 0):
                guard let (v, after) = parseVarint(slice, offset: offset) else { return nil }
                m.pos = Int32(truncatingIfNeeded: v)
                offset = after
            case (3, 0):
                guard let (v, after) = parseVarint(slice, offset: offset) else { return nil }
                m.len = Int32(truncatingIfNeeded: v)
                offset = after
            case (4, 0):
                guard let (v, after) = parseVarint(slice, offset: offset) else { return nil }
                m.type = Int32(truncatingIfNeeded: v)
                offset = after
            default:
                guard let after = skipField(slice, offset: offset, wireType: wireType) else { return nil }
                offset = after
            }
        }
        return m
    }

    private static func parseQuote(_ slice: ArraySlice<UInt8>) -> ProtoQuote? {
        var q = ProtoQuote()
        var offset = slice.startIndex
        while offset < slice.endIndex {
            guard let (tag, next) = parseVarint(slice, offset: offset) else { return nil }
            offset = next
            let fieldNum = tag >> 3
            let wireType = tag & 0x07
            switch (fieldNum, wireType) {
            case (1, 2):
                guard let (sub, after) = parseLengthDelimited(slice, offset: offset) else { return nil }
                q.attach = String(decoding: sub, as: UTF8.self)
                offset = after
            case (2, 2):
                guard let (sub, after) = parseLengthDelimited(slice, offset: offset) else { return nil }
                q.ownerId = String(decoding: sub, as: UTF8.self)
                offset = after
            case (3, 0):
                guard let (v, after) = parseVarint(slice, offset: offset) else { return nil }
                q.ts = Int64(bitPattern: v)
                offset = after
            case (4, 2):
                guard let (sub, after) = parseLengthDelimited(slice, offset: offset) else { return nil }
                q.fromD = String(decoding: sub, as: UTF8.self)
                offset = after
            case (5, 0):
                guard let (v, after) = parseVarint(slice, offset: offset) else { return nil }
                q.cliMsgId = Int64(bitPattern: v)
                offset = after
            case (6, 0):
                guard let (v, after) = parseVarint(slice, offset: offset) else { return nil }
                q.globalMsgId = v > 0 ? String(v) : ""
                offset = after
            case (6, 2):
                guard let (sub, after) = parseLengthDelimited(slice, offset: offset) else { return nil }
                q.globalMsgId = String(decoding: sub, as: UTF8.self)
                offset = after
            case (7, 2):
                guard let (sub, after) = parseLengthDelimited(slice, offset: offset) else { return nil }
                q.msg = String(decoding: sub, as: UTF8.self)
                offset = after
            case (8, 0):
                guard let (v, after) = parseVarint(slice, offset: offset) else { return nil }
                q.cliMsgType = Int32(truncatingIfNeeded: v)
                offset = after
            default:
                guard let after = skipField(slice, offset: offset, wireType: wireType) else { return nil }
                offset = after
            }
        }
        return q
    }

    private static func parseLengthDelimited(_ slice: ArraySlice<UInt8>, offset: Int) -> (ArraySlice<UInt8>, Int)? {
        guard let (len, afterLen) = parseVarint(slice, offset: offset),
              let intLen = Int(exactly: len),
              intLen >= 0,
              afterLen + intLen <= slice.endIndex else {
            return nil
        }
        return (slice[afterLen..<(afterLen + intLen)], afterLen + intLen)
    }

    private static func skipField(_ slice: ArraySlice<UInt8>, offset: Int, wireType: UInt64) -> Int? {
        switch wireType {
        case 0:
            return parseVarint(slice, offset: offset)?.1
        case 1:
            return (offset + 8 <= slice.endIndex) ? (offset + 8) : nil
        case 2:
            return parseLengthDelimited(slice, offset: offset)?.1
        case 5:
            return (offset + 4 <= slice.endIndex) ? (offset + 4) : nil
        default:
            return nil
        }
    }

    private static func parseVarint(_ slice: ArraySlice<UInt8>, offset: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var cur = offset
        while cur < slice.endIndex {
            let b = slice[cur]
            cur += 1
            result |= UInt64(b & 0x7F) << shift
            if (b & 0x80) == 0 {
                return (result, cur)
            }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    /// Maps `proto.Sync2.Message.msgType` (`shared-worker.js` `je`) to Zalo wire `msgType`.
    static func wireMsgType(for syncMsgType: Int32) -> String {
        switch syncMsgType {
        case 0, 20: return "webchat"
        case 2: return "chat.doodle"
        case 3, 4, 31: return "chat.photo"
        case 6: return "chat.voice"
        case 10: return "chat.sticker"
        case 12: return "chat.recommended"
        case 15: return "chat.list.action"
        case 18: return "chat.location.new"
        case 19: return "chat.video.msg"
        case 21: return "chat.ecard"
        case 22: return "share.file"
        case 23: return "chat.gif"
        case 24: return "chat.webcontent"
        case 25: return "chat.video.live.msg"
        case 26: return "group.poll"
        case 33: return "chat.delete"
        case 36: return "chat.undo"
        case 53: return "chat.webcontent.v2"
        default: return "webchat"
        }
    }

    static func buildChatMessage(
        from proto: ProtoMsg,
        convId: String,
        senderUid: String,
        senderName: String,
        senderAvatar: URL?,
        isMine: Bool,
        myUid: String = "",
        selfConvId: String? = nil,
        globalIdToUserId: [String: String] = [:],
        nameLookup: ((String) -> (name: String, avatar: String)?)? = nil
    ) -> (ChatMessage, StoredMessage)? {
        guard proto.timestamp > 0 else { return nil }
        let rawMapped = wireMsgType(for: proto.msgType)
        let mappedType: String = {
            if proto.msgType == 0, let attType = proto.metaData?.attaches.first?.typeName, !attType.isEmpty {
                return ZaloWireParser.normalizedMsgType(attType)
            }
            return rawMapped
        }()
        if mappedType == "chat.delete" || mappedType == "chat.undo" {
            return nil
        }

        let trimmedContent = proto.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let contentValue: Any = {
            if let att = proto.metaData?.attaches.first {
                var dict: [String: Any] = [:]
                if !att.action.isEmpty { dict["action"] = att.action }
                if !att.params.isEmpty { dict["params"] = att.params }
                if !att.title.isEmpty {
                    dict["title"] = att.title
                } else if !trimmedContent.isEmpty && !trimmedContent.hasPrefix("{") {
                    dict["title"] = trimmedContent
                }
                if !att.href.isEmpty {
                    dict["href"] = att.href
                    if mappedType == "chat.photo" {
                        dict["normalUrl"] = att.href
                    } else if mappedType == "share.file" || mappedType == "chat.video.msg" {
                        dict["fileUrl"] = att.href
                    }
                }
                if !att.thumb.isEmpty {
                    dict["thumb"] = att.thumb
                    dict["thumbUrl"] = att.thumb
                }
                if !att.description.isEmpty { dict["description"] = att.description }
                if att.catId != 0 { dict["catId"] = Int(att.catId); dict["cateId"] = Int(att.catId) }
                if att.id != 0 { dict["id"] = Int(att.id); dict["stickerId"] = Int(att.id) }
                if mappedType == "chat.recommended" && att.action.isEmpty && !att.href.isEmpty {
                    dict["action"] = "recommened.link"
                }
                return dict
            }
            if trimmedContent.hasPrefix("{"),
               let d = trimmedContent.data(using: .utf8),
               let parsed = JSONLossless.parseObject(d) {
                return parsed
            }
            return trimmedContent
        }()

        var rawWire: [String: Any] = [
            "msgId": (!proto.globalId.isEmpty && proto.globalId != "0") ? proto.globalId : "",
            "cliMsgId": proto.clientId > 0 ? String(proto.clientId) : "",
            "uidFrom": isMine ? (myUid.isEmpty ? "0" : myUid) : senderUid,
            "idTo": ZaloWireParser.isGroupId(convId) ? ZaloWireParser.cleanGroupId(convId) : (isMine ? convId : myUid),
            "msgType": mappedType,
            "ts": Int64(proto.timestamp),
            "content": contentValue,
            "isMine": isMine,
            "isGroup": ZaloWireParser.isGroupId(convId),
        ]
        if !senderName.isEmpty { rawWire["dName"] = senderName }
        if let avt = senderAvatar?.absoluteString, !avt.isEmpty { rawWire["avt"] = avt }

        if let mentions = proto.metaData?.mentions, !mentions.isEmpty {
            rawWire["mentions"] = mentions.map { m -> [String: Any] in
                let mappedUid = (m.type == 1 || m.uid == "-1") ? "-1" : (globalIdToUserId[m.uid] ?? m.uid)
                return [
                    "uid": mappedUid,
                    "pos": Int(m.pos),
                    "len": Int(m.len),
                    "type": Int(m.type),
                ]
            }
        }
        if let q = proto.metaData?.quote, (!q.msg.isEmpty || !q.attach.isEmpty) {
            let mappedOwner = globalIdToUserId[q.ownerId] ?? q.ownerId
            rawWire["quote"] = [
                "ownerId": mappedOwner,
                "fromD": q.fromD,
                "msg": q.msg.isEmpty ? "[Đính kèm]" : q.msg,
                "ts": q.ts,
                "cliMsgId": q.cliMsgId,
                "globalMsgId": q.globalMsgId,
            ]
        }

        let parsedEvent = ZaloWireParser.parseWireMessage(
            rawWire,
            myUid: myUid,
            fallbackConvId: convId,
            isGroupHint: ZaloWireParser.isGroupId(convId),
            selfConvId: selfConvId,
            nameLookup: nameLookup
        )
        if case .message(let chatMsg, let stored) = parsedEvent {
            return (chatMsg, stored)
        }
        return nil
    }
}

// MARK: - Sync v2 Control Event Extraction & Request Planning

enum ZaloMobileSyncEvent: Sendable, Equatable {
    case transferAfterLogin(tempKey: String)
    case waitingConfirmOnPhone(syncId: String)
    case userConfirmed
    case userRejected
    case mobileBusy
    case uploadBatch(syncId: String, url: String, batchType: Int, idx: Int, isLast: Bool)
}

struct PlannedSyncPartition: Sendable, Equatable {
    let partition: String
    let convId: String
    let isGroup: Bool
    let globalId: String
}

struct ParsedPhoneMessage: Sendable {
    let convId: String
    let isGroup: Bool
    let isMine: Bool
    let senderGlobalId: String
    let senderUid: String
    let proto: ZaloSyncProtobufParser.ProtoMsg
}

struct DecryptedSyncBatchResult: Sendable {
    var databaseType: String
    var metaRecords: Int
    var messageRecords: Int
    var failedRecords: Int
    var deferred: Bool
    var parsedConversations: [ZaloSyncProtobufParser.ProtoConversation]
    var parsedMessages: [ParsedPhoneMessage]
    var syncedConvIds: Set<String>
    var replayedBatches: [(url: String, batchType: Int, idx: Int, isLast: Bool)]
}

struct SyncRequestSnapshot: Sendable {
    var batchesCount: Int
    var importedCount: Int
    var syncedConversationsCount: Int
    var syncedConvIds: Set<String> = []
    var lastActivity: Date?
    var lastSeen: Bool
    var inFlightCount: Int
    var isFulfilled: Bool
}

enum ZaloPhoneSync {
    static let noLimit: Int64 = 2_147_483_647
    static let maxTimestamp: Int64 = 9_007_199_254_740_991
    static let transferBatchSize: Int = 2000
    /// Official `shared-worker.js` `buildPrepareQuery` enforces `e.getQueryCount() < 30` (at most 30 partitions per `cmd 590` request).
    static let partitionsPerRequest: Int = 30

    static func partitionName(globalId: String, isGroup: Bool) -> String {
        "\(isGroup ? "group" : "oneone")/\(globalId)"
    }

    static func extractMobileSyncEvents(_ root: [String: Any]) -> [ZaloMobileSyncEvent] {
        let dataNode = (root["data"] as? [String: Any]) ?? root
        var candidates: [[String: Any]] = []

        if let controls = dataNode["controls"] as? [[String: Any]] {
            candidates.append(contentsOf: controls)
        }
        if let actions = dataNode["actions"] as? [[String: Any]] {
            candidates.append(contentsOf: actions)
        }
        if let dataArr = root["data"] as? [[String: Any]] {
            for item in dataArr {
                if let sub = item["controls"] as? [[String: Any]] {
                    candidates.append(contentsOf: sub)
                } else {
                    candidates.append(item)
                }
            }
        }
        if candidates.isEmpty {
            candidates.append(dataNode)
        }

        var events: [ZaloMobileSyncEvent] = []
        for item in candidates {
            let contentObj: [String: Any] = {
                if let c = item["content"] as? [String: Any] { return c }
                if let s = item["content"] as? String,
                   let d = s.data(using: .utf8),
                   let p = JSONLossless.parseObject(d) {
                    return p
                }
                return item
            }()

            let actType = JSONLossless.string(contentObj["act_type"] ?? item["act_type"])
            guard actType == "transfer_msg" || actType == "syncmsgmb" || actType == "transfer_sync2" else {
                continue
            }

            let act = JSONLossless.string(contentObj["act"] ?? item["act"] ?? item["action"])
            let parsedData: [String: Any] = {
                if let d = contentObj["data"] as? [String: Any] { return d }
                if let s = contentObj["data"] as? String {
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    let wrapped = trimmed.hasPrefix("{") ? trimmed : "{\(trimmed)}"
                    if let d = wrapped.data(using: .utf8), let p = JSONLossless.parseObject(d) {
                        return p
                    }
                }
                return [:]
            }()

            switch act {
            case "transfer_after_login":
                let tk = JSONLossless.string(parsedData["temp_key"]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !tk.isEmpty {
                    events.append(.transferAfterLogin(tempKey: tk))
                }
            case "user_confirm":
                let ua = JSONLossless.int64(parsedData["user_action"]) ?? -1
                if ua == 1 || ua == 3 {
                    events.append(.userConfirmed)
                } else if ua == 2 {
                    events.append(.mobileBusy)
                } else if ua == 0 {
                    events.append(.userRejected)
                }
            case "transfer_status":
                let st = JSONLossless.int64(parsedData["status"]) ?? -1
                let sid = JSONLossless.string(parsedData["syncId"])
                switch st {
                case 3: events.append(.waitingConfirmOnPhone(syncId: sid))
                case 4, 5: events.append(.userConfirmed)
                case 6, 7: events.append(.userRejected)
                case 8: events.append(.mobileBusy)
                default: break
                }
            case "upload_batch":
                let url = JSONLossless.string(parsedData["msgUrl"] ?? parsedData["url"]).trimmingCharacters(in: .whitespacesAndNewlines)
                let sid = JSONLossless.string(parsedData["syncId"]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty, !sid.isEmpty else { continue }
                let batchType = Int(JSONLossless.int64(parsedData["batchType"]) ?? 0)
                let idx = Int(JSONLossless.int64(parsedData["idx"]) ?? -1)
                let isLast = JSONLossless.int64(parsedData["isLast"]) == 1 || (parsedData["isLast"] as? Bool == true)
                events.append(.uploadBatch(syncId: sid, url: url, batchType: batchType, idx: idx, isLast: isLast))
            default:
                break
            }
        }
        return events
    }

    static func buildPlan(
        conversations: [(id: String, isGroup: Bool)],
        userGlobalIds: [String: String],
        groupGlobalIds: [String: String],
        send2MeId: String?,
        phoneTimestamps: [String: UInt64] = [:]
    ) -> (partitions: [PlannedSyncPartition], globalIdToUserId: [String: String], skipped: Int) {
        var globalIdToUserId: [String: String] = [:]
        globalIdToUserId.reserveCapacity(userGlobalIds.count)
        for (uid, gid) in userGlobalIds where !uid.isEmpty && !gid.isEmpty {
            globalIdToUserId[gid] = uid
        }

        var indexed: [(order: Int, ts: UInt64, part: PlannedSyncPartition)] = []
        var seen = Set<String>()
        var skipped = 0
        let filterByPhone = !phoneTimestamps.isEmpty

        for (idx, item) in conversations.enumerated() {
            guard !item.id.isEmpty, item.id != send2MeId else { continue }
            let key = "\(item.isGroup ? "g" : "u"):\(item.id)"
            guard seen.insert(key).inserted else { continue }

            if item.isGroup {
                let cleanGrid = ZaloWireParser.cleanGroupId(item.id)
                if let gid = groupGlobalIds[cleanGrid], !gid.isEmpty {
                    if filterByPhone && phoneTimestamps[gid] == nil {
                        continue
                    }
                    indexed.append((
                        order: idx,
                        ts: phoneTimestamps[gid] ?? 0,
                        part: PlannedSyncPartition(
                            partition: partitionName(globalId: gid, isGroup: true),
                            convId: ZaloWireParser.groupConvId(cleanGrid),
                            isGroup: true,
                            globalId: gid
                        )
                    ))
                } else {
                    skipped += 1
                }
            } else {
                let cleanUid = ZaloWireParser.stripUserPrefix(item.id)
                if let gid = userGlobalIds[cleanUid], !gid.isEmpty {
                    if filterByPhone && phoneTimestamps[gid] == nil {
                        continue
                    }
                    indexed.append((
                        order: idx,
                        ts: phoneTimestamps[gid] ?? 0,
                        part: PlannedSyncPartition(
                            partition: partitionName(globalId: gid, isGroup: false),
                            convId: cleanUid,
                            isGroup: false,
                            globalId: gid
                        )
                    ))
                } else {
                    skipped += 1
                }
            }
        }

        if filterByPhone {
            indexed.sort { a, b in
                if a.ts != b.ts { return a.ts > b.ts }
                return a.order < b.order
            }
        }

        return (indexed.map(\.part), globalIdToUserId, skipped)
    }

    static func buildConversationSyncPayload(
        syncId: String,
        ikPubB64: String,
        ekPubB64: String,
        tempKey: String,
        deviceName: String,
        ussidx: Int
    ) -> [String: Any] {
        [
            "syncId": syncId,
            "syncType": 0,
            "ek": ekPubB64,
            "ik": ikPubB64,
            "toDevice": 0,
            "tempKey": tempKey,
            "deviceName": deviceName.isEmpty ? "Mac" : deviceName,
            "req": [
                "type": "conversation",
                "priority": 1,
                "queries": [[
                    "partition": "",
                    "from": 0,
                    "to": maxTimestamp,
                    "limit": noLimit,
                ]],
                "batchSize": transferBatchSize,
            ],
            "ver": 1,
            "ussidx": ussidx,
        ]
    }

    static func buildSyncRequestPayload(
        syncId: String,
        ikPubB64: String,
        ekPubB64: String,
        tempKey: String,
        deviceName: String,
        partitions: [PlannedSyncPartition],
        ussidx: Int,
        batchSize: Int = transferBatchSize
    ) -> [String: Any] {
        let queries: [[String: Any]] = partitions.map {
            [
                "partition": $0.partition,
                "from": 0,
                "to": maxTimestamp,
                "limit": noLimit,
            ]
        }
        return [
            "syncId": syncId,
            "syncType": 0,
            "ek": ekPubB64,
            "ik": ikPubB64,
            "toDevice": 0,
            "tempKey": tempKey,
            "deviceName": deviceName.isEmpty ? "Mac" : deviceName,
            "req": [
                "type": "message",
                "priority": 1,
                "queries": queries,
                "batchSize": batchSize,
            ],
            "ver": 1,
            "ussidx": ussidx,
        ]
    }
}

// MARK: - Sync Coordinator Actor

actor ZaloPhoneSyncCoordinator {
    enum CoordinatorError: Error, LocalizedError {
        case wasmUnavailable
        case keyGenerationFailed
        case unknownSyncRequest
        case decryptFailed(String)

        var errorDescription: String? {
            switch self {
            case .wasmUnavailable: "Không tìm thấy mô-đun giải mã đồng bộ (libzproto)."
            case .keyGenerationFailed: "Không tạo được khoá đồng bộ."
            case .unknownSyncRequest: "Gói đồng bộ không thuộc yêu cầu nào đang chạy."
            case .decryptFailed(let msg): "Không giải mã được gói đồng bộ: \(msg)"
            }
        }
    }

    struct PersistedIdentityKey: Codable, Sendable {
        var ikPubB64: String
        var ikPub: Data
        var ikPriv: Data
    }

    private struct ActiveSyncRequest {
        let syncId: String
        let databaseType: String
        let createdAt: Date
        let ikPub: Data
        let ikPriv: Data
        let ekPriv: Data
        var sessionBytes: Data?
        let partitionsById: [String: PlannedSyncPartition]
        var globalIdToUserId: [String: String]
        var seenBatchKeys: Set<String> = []
        var pendingURLs: [(url: String, batchType: Int, idx: Int, isLast: Bool)] = []
        var batchesCount: Int = 0
        var importedCount: Int = 0
        var syncedConvIds: Set<String> = []
        var lastActivity: Date?
        var lastSeen: Bool = false
        var metaReceived: Bool = false
        var expectedDataBatches: Int?
        var completedDataBatches: Set<Int> = []
        var inFlightCount: Int = 0
    }

    private var jsRuntime: JSRuntime?
    private var wasmReady = false
    private(set) var latestTempKey: String = ""
    private var ownGlobalId: String = ""
    private var identityKey: PersistedIdentityKey?
    private var activeRequests: [String: ActiveSyncRequest] = [:]

    func setLatestTempKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            latestTempKey = trimmed
        }
    }

    func clearLatestTempKey() {
        latestTempKey = ""
    }

    func setOwnGlobalId(_ gid: String) {
        if !gid.isEmpty {
            ownGlobalId = gid
        }
    }

    func loadIdentityKey(_ key: PersistedIdentityKey?) {
        if let key, !key.ikPubB64.isEmpty, !key.ikPub.isEmpty, !key.ikPriv.isEmpty {
            identityKey = key
        }
    }

    func currentIdentityKey() -> PersistedIdentityKey? {
        identityKey
    }

    func resetAll() {
        activeRequests.removeAll()
    }

    func activeSyncIds() -> [String] {
        Array(activeRequests.keys)
    }

    func removeRequest(syncId: String) {
        activeRequests.removeValue(forKey: syncId)
    }

    func hasActiveRequest(syncId: String) -> Bool {
        activeRequests[syncId] != nil
    }

    func prepareWasm() async -> Bool {
        if wasmReady, jsRuntime != nil { return true }
        guard let wasmData = AsarWasmReader.loadZprotoWasm() else {
            Task { @MainActor in
                EngineLog.shared.write("sync-v2: libzproto_wasm_bg not found")
            }
            return false
        }
        do {
            let rt: JSRuntime
            if let existing = jsRuntime {
                rt = existing
            } else {
                rt = try JSRuntime(name: "zproto-sync")
                try await rt.loadModule("zalo-zproto-sync.js")
                jsRuntime = rt
            }
            let ok = try await rt.callAsync("ZaloZprotoSync.init", [.bytes(wasmData)])
            wasmReady = (ok.boolValue == true)
            return wasmReady
        } catch {
            Task { @MainActor in
                EngineLog.shared.write("sync-v2: wasm init failed \(error.localizedDescription)")
            }
            return false
        }
    }

    private func ensureIdentityAndNewEphemeral() async throws -> (ik: PersistedIdentityKey, ekPubB64: String, ekPriv: Data) {
        guard await prepareWasm(), let rt = jsRuntime else {
            throw CoordinatorError.wasmUnavailable
        }
        let keysVal = try await rt.callAsync("ZaloZprotoSync.generateKeys")
        guard let genIkPubB64 = keysVal["ikPubB64"]?.stringValue, !genIkPubB64.isEmpty,
              let ekPubB64 = keysVal["ekPubB64"]?.stringValue, !ekPubB64.isEmpty,
              let genIkPub = keysVal["ikPub"]?.dataValue, !genIkPub.isEmpty,
              let genIkPriv = keysVal["ikPriv"]?.dataValue, !genIkPriv.isEmpty,
              let ekPriv = keysVal["ekPriv"]?.dataValue, !ekPriv.isEmpty else {
            throw CoordinatorError.keyGenerationFailed
        }
        let ik: PersistedIdentityKey
        if let existing = identityKey {
            ik = existing
        } else {
            let created = PersistedIdentityKey(ikPubB64: genIkPubB64, ikPub: genIkPub, ikPriv: genIkPriv)
            identityKey = created
            ik = created
        }
        return (ik, ekPubB64, ekPriv)
    }

    private static func makeSyncId() -> String {
        var rngBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &rngBytes)
        return rngBytes.map { String(format: "%02x", $0) }.joined()
    }

    func registerConversationRequest(
        deviceName: String,
        ussidx: Int
    ) async throws -> (syncId: String, innerData: ZaloJSONBox) {
        let (ik, ekPubB64, ekPriv) = try await ensureIdentityAndNewEphemeral()
        let syncId = Self.makeSyncId()

        activeRequests[syncId] = ActiveSyncRequest(
            syncId: syncId,
            databaseType: "conversation",
            createdAt: Date(),
            ikPub: ik.ikPub,
            ikPriv: ik.ikPriv,
            ekPriv: ekPriv,
            sessionBytes: nil,
            partitionsById: [:],
            globalIdToUserId: [:]
        )

        let oneTimeKey = ussidx == 0 ? latestTempKey : ""
        if ussidx == 0 { latestTempKey = "" }

        let payload = ZaloPhoneSync.buildConversationSyncPayload(
            syncId: syncId,
            ikPubB64: ik.ikPubB64,
            ekPubB64: ekPubB64,
            tempKey: oneTimeKey,
            deviceName: deviceName,
            ussidx: ussidx
        )
        return (syncId, ZaloJSONBox(payload))
    }

    func registerChunkRequest(
        chunk: [PlannedSyncPartition],
        globalIdToUserId: [String: String],
        deviceName: String,
        ussidx: Int,
        batchSize: Int = ZaloPhoneSync.transferBatchSize
    ) async throws -> (syncId: String, innerData: ZaloJSONBox) {
        let (ik, ekPubB64, ekPriv) = try await ensureIdentityAndNewEphemeral()
        let syncId = Self.makeSyncId()

        let partMap = Dictionary(uniqueKeysWithValues: chunk.map { ($0.partition, $0) })
        activeRequests[syncId] = ActiveSyncRequest(
            syncId: syncId,
            databaseType: "message",
            createdAt: Date(),
            ikPub: ik.ikPub,
            ikPriv: ik.ikPriv,
            ekPriv: ekPriv,
            sessionBytes: nil,
            partitionsById: partMap,
            globalIdToUserId: globalIdToUserId
        )

        let oneTimeKey = ussidx == 0 ? latestTempKey : ""
        if ussidx == 0 { latestTempKey = "" }

        let payload = ZaloPhoneSync.buildSyncRequestPayload(
            syncId: syncId,
            ikPubB64: ik.ikPubB64,
            ekPubB64: ekPubB64,
            tempKey: oneTimeKey,
            deviceName: deviceName,
            partitions: chunk,
            ussidx: ussidx,
            batchSize: batchSize
        )
        return (syncId, ZaloJSONBox(payload))
    }

    func generateKeyPairForTesting() async throws -> (ikPubB64: String, ikPub: Data, ikPriv: Data, ekPubB64: String, ekPriv: Data) {
        let (ik, ekPubB64, ekPriv) = try await ensureIdentityAndNewEphemeral()
        return (ik.ikPubB64, ik.ikPub, ik.ikPriv, ekPubB64, ekPriv)
    }

    func noteBatchStarted(syncId: String) {
        guard var req = activeRequests[syncId] else { return }
        req.inFlightCount += 1
        req.lastActivity = Date()
        activeRequests[syncId] = req
    }

    func noteBatchFinished(syncId: String) {
        guard var req = activeRequests[syncId] else { return }
        req.inFlightCount = max(0, req.inFlightCount - 1)
        req.lastActivity = Date()
        activeRequests[syncId] = req
    }

    func decryptAndParseBatch(
        syncId: String,
        rawBytes: Data,
        url: String,
        batchType: Int = 0,
        idx: Int = -1,
        isLast: Bool,
        myUid: String
    ) async throws -> DecryptedSyncBatchResult {
        guard var req = activeRequests[syncId] else {
            throw CoordinatorError.unknownSyncRequest
        }
        let dedupKey = idx >= 0 ? "\(batchType):\(idx)" : url
        if idx >= 0 {
            if req.seenBatchKeys.contains(dedupKey) {
                return DecryptedSyncBatchResult(
                    databaseType: req.databaseType,
                    metaRecords: 0,
                    messageRecords: 0,
                    failedRecords: 0,
                    deferred: false,
                    parsedConversations: [],
                    parsedMessages: [],
                    syncedConvIds: [],
                    replayedBatches: []
                )
            }
            req.seenBatchKeys.insert(dedupKey)
            activeRequests[syncId] = req
        }
        guard await prepareWasm(), let rt = jsRuntime else {
            throw CoordinatorError.wasmUnavailable
        }

        let hadSession = (req.sessionBytes != nil)
        let resultVal = try await rt.callAsync("ZaloZprotoSync.decryptBatch", [
            .bytes(rawBytes),
            .bytes(req.ikPub),
            .bytes(req.ikPriv),
            .bytes(req.ekPriv),
            req.sessionBytes.map { .bytes($0) } ?? .null,
        ])

        let nextSession = resultVal["session"]?.dataValue
        let metaCount = resultVal["metaCount"]?.intValue ?? 0
        let msgCount = resultVal["msgCount"]?.intValue ?? 0
        let failedCount = resultVal["failedCount"]?.intValue ?? 0
        let recordsArr = resultVal["records"]?.arrayValue ?? []

        if recordsArr.isEmpty && failedCount > 0 && !hadSession {
            if var mut = activeRequests[syncId] {
                if idx >= 0 { mut.seenBatchKeys.remove(dedupKey) }
                mut.pendingURLs.append((url: url, batchType: batchType, idx: idx, isLast: isLast))
                activeRequests[syncId] = mut
            }
            let shortId = String(syncId.prefix(8))
            Task { @MainActor in
                EngineLog.shared.write("sync-v2: deferred batch sync=\(shortId) bytes=\(rawBytes.count)")
            }
            return DecryptedSyncBatchResult(
                databaseType: req.databaseType,
                metaRecords: metaCount,
                messageRecords: msgCount,
                failedRecords: failedCount,
                deferred: true,
                parsedConversations: [],
                parsedMessages: [],
                syncedConvIds: [],
                replayedBatches: []
            )
        }

        var parsedConversations: [ZaloSyncProtobufParser.ProtoConversation] = []
        var parsedMessages: [ParsedPhoneMessage] = []
        var touchedConvs = Set<String>()
        var unknownPartitions = 0

        if req.databaseType == "conversation" {
            for entry in recordsArr {
                guard let plainData = entry["plain"]?.dataValue else { continue }
                let decompressed = ZstdDecompressor.decompressIfNeeded(plainData)
                let convs = ZaloSyncProtobufParser.parseConversationSyncChunk(decompressed)
                parsedConversations.append(contentsOf: convs)
            }
        } else {
            for entry in recordsArr {
                guard let plainData = entry["plain"]?.dataValue else { continue }
                let decompressed = ZstdDecompressor.decompressIfNeeded(plainData)
                let partitions = ZaloSyncProtobufParser.parseSyncChunk(decompressed)
                for part in partitions {
                    guard let target = req.partitionsById[part.id] else {
                        if !part.messages.isEmpty { unknownPartitions += 1 }
                        continue
                    }
                    if !target.isGroup && ownGlobalId.isEmpty {
                        if let discovered = part.messages.map(\.senderId).first(where: { !$0.isEmpty && $0 != target.globalId }) {
                            ownGlobalId = discovered
                        }
                    }
                    for m in part.messages where m.timestamp > 0 {
                        let isMine: Bool = target.isGroup
                            ? (!ownGlobalId.isEmpty && m.senderId == ownGlobalId)
                            : (m.senderId != target.globalId)
                        let senderUid: String = {
                            if isMine { return myUid }
                            if target.isGroup {
                                return req.globalIdToUserId[m.senderId] ?? m.senderId
                            }
                            return target.convId
                        }()
                        parsedMessages.append(ParsedPhoneMessage(
                            convId: target.convId,
                            isGroup: target.isGroup,
                            isMine: isMine,
                            senderGlobalId: m.senderId,
                            senderUid: senderUid,
                            proto: m
                        ))
                        touchedConvs.insert(target.convId)
                    }
                }
            }
        }

        var toReplay: [(url: String, batchType: Int, idx: Int, isLast: Bool)] = []
        let recordItemCount = req.databaseType == "conversation" ? parsedConversations.count : parsedMessages.count
        let isDataBatch = (batchType == 1) || (msgCount > 0 && metaCount == 0)
        if var mut = activeRequests[syncId] {
            if let nextSession, !nextSession.isEmpty {
                mut.sessionBytes = nextSession
            }
            if !hadSession && mut.sessionBytes != nil && !mut.pendingURLs.isEmpty {
                toReplay = mut.pendingURLs
                mut.pendingURLs.removeAll()
            }
            mut.batchesCount += 1
            mut.importedCount += recordItemCount
            mut.syncedConvIds.formUnion(touchedConvs)
            mut.lastActivity = Date()
            if metaCount > 0 || batchType == 2 {
                mut.metaReceived = true
            }
            if isDataBatch {
                if idx >= 0 {
                    mut.completedDataBatches.insert(idx)
                }
                if isLast {
                    mut.lastSeen = true
                    if idx >= 0 {
                        mut.expectedDataBatches = idx + 1
                    }
                }
            }
            activeRequests[syncId] = mut
        }

        let shortId = String(syncId.prefix(8))
        let dbLabel = req.databaseType
        Task { @MainActor in
            EngineLog.shared.write("sync-v2: batch db=\(dbLabel) sync=\(shortId) bytes=\(rawBytes.count) meta=\(metaCount) msg=\(msgCount) failed=\(failedCount) parsed=\(recordItemCount) unknown_part=\(unknownPartitions)")
        }

        return DecryptedSyncBatchResult(
            databaseType: req.databaseType,
            metaRecords: metaCount,
            messageRecords: msgCount,
            failedRecords: failedCount,
            deferred: false,
            parsedConversations: parsedConversations,
            parsedMessages: parsedMessages,
            syncedConvIds: touchedConvs,
            replayedBatches: toReplay
        )
    }

    func requestSnapshot(syncId: String) -> SyncRequestSnapshot? {
        guard let req = activeRequests[syncId] else { return nil }
        let fulfilled: Bool = {
            guard req.inFlightCount == 0, req.pendingURLs.isEmpty else { return false }
            if let expected = req.expectedDataBatches {
                return req.completedDataBatches.count >= expected
            }
            return false
        }()
        return SyncRequestSnapshot(
            batchesCount: req.batchesCount,
            importedCount: req.importedCount,
            syncedConversationsCount: req.syncedConvIds.count,
            syncedConvIds: req.syncedConvIds,
            lastActivity: req.lastActivity,
            lastSeen: req.lastSeen,
            inFlightCount: req.inFlightCount,
            isFulfilled: fulfilled
        )
    }
}
