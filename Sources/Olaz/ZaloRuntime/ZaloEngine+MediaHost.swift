import Foundation
import ImageIO
import OlazCore
import UniformTypeIdentifiers
import os

/// Per-`op_id` Swift buffer for outgoing file bytes and video thumbnail data so zero media bytes
/// cross the UniFFI boundary (ADR-031 §2).
internal struct StagedOutgoingFile: @unchecked Sendable {
    var url: URL
    var scoped: Bool
    var data: Data
    var videoThumbData: Data
}

/// Lock-protected storage for U15 host I/O state (`stagedOutgoingFiles` and `resolveFile` progress
/// callbacks), accessible from `nonisolated` `CoreHost` methods running off the MainActor.
internal final class MediaHostIOState: Sendable {
    private struct Inner: @unchecked Sendable {
        var stagedOutgoingFiles: [UInt64: StagedOutgoingFile] = [:]
        var nextProgressToken: UInt64 = 1
        var resolveFileProgress: [UInt64: @Sendable (Double) -> Void] = [:]
    }

    private let inner = OSAllocatedUnfairLock(initialState: Inner())

    func stage(_ entry: StagedOutgoingFile, for opId: UInt64) {
        let old: StagedOutgoingFile? = inner.withLock { st in
            let prev = st.stagedOutgoingFiles.updateValue(entry, forKey: opId)
            return prev
        }
        if let old, old.scoped {
            old.url.stopAccessingSecurityScopedResource()
        }
    }

    func updateData(_ data: Data, for opId: UInt64) {
        inner.withLock { st in
            st.stagedOutgoingFiles[opId]?.data = data
        }
    }

    func updateVideoThumb(_ thumb: Data, for opId: UInt64) {
        inner.withLock { st in
            st.stagedOutgoingFiles[opId]?.videoThumbData = thumb
        }
    }

    func entry(for opId: UInt64) -> StagedOutgoingFile? {
        inner.withLock { $0.stagedOutgoingFiles[opId] }
    }

    func release(opId: UInt64) {
        let old: StagedOutgoingFile? = inner.withLock { st in
            st.stagedOutgoingFiles.removeValue(forKey: opId)
        }
        if let old, old.scoped {
            old.url.stopAccessingSecurityScopedResource()
        }
    }

    func releaseAll() {
        let entries: [StagedOutgoingFile] = inner.withLock { st in
            let list = Array(st.stagedOutgoingFiles.values)
            st.stagedOutgoingFiles.removeAll()
            return list
        }
        for entry in entries where entry.scoped {
            entry.url.stopAccessingSecurityScopedResource()
        }
    }

    func registerProgress(_ progress: (@Sendable (Double) -> Void)?) -> UInt64 {
        guard let progress else { return 0 }
        return inner.withLock { st in
            let token = st.nextProgressToken
            st.nextProgressToken &+= 1
            if st.nextProgressToken == 0 {
                st.nextProgressToken = 1
            }
            st.resolveFileProgress[token] = progress
            return token
        }
    }

    func unregisterProgress(token: UInt64) {
        guard token != 0 else { return }
        _ = inner.withLock { $0.resolveFileProgress.removeValue(forKey: token) }
    }

    func progressHandler(for token: UInt64) -> (@Sendable (Double) -> Void)? {
        guard token != 0 else { return nil }
        return inner.withLock { $0.resolveFileProgress[token] }
    }
}

// MARK: - U15 FFI Record Conversions

extension FileResolution {
    init(coreRecord record: FileResolutionRecord) {
        switch record {
        case .ready(let path):
            self = .ready(URL(fileURLWithPath: path))
        case .expired:
            self = .expired
        case .failed(let message):
            self = .failed(message)
        }
    }
}

extension SharedMediaPage {
    init(coreRecord record: SharedMediaPageRecord) {
        self.init(
            items: record.items.map(ChatMessage.init(record:)),
            cursor: record.cursor,
            more: record.more
        )
    }
}

extension FileLoadErrorKindRecord {
    nonisolated init(error: Error) {
        if error is CancellationError {
            self = .cancelled
            return
        }
        if let loadErr = error as? MediaLoader.LoadError {
            switch loadErr {
            case .http(let code):
                self = .http(code: UInt16(clamping: code))
            case .hostNotFound:
                self = .hostNotFound
            case .undecodable:
                self = .undecodable
            case .timedOut:
                self = .timedOut
            case .tooLarge:
                self = .tooLarge
            case .badURL:
                self = .badUrl
            }
            return
        }
        self = .other
    }
}

// MARK: - MainActor Test-Hook Dispatch Helpers

extension ZaloEngine {
    @MainActor private func tryReadOutgoingFileHook(
        path: String,
        name: String,
        mode: String
    ) async -> OutgoingFileProbeResult? {
        guard let handler = readOutgoingFileHostHandler else { return nil }
        let readArgs: [String: Any] = [
            "path": path,
            "name": name,
            "mode": mode,
        ]
        _ = traceHost("read_file", args: readArgs)
        return await handler(readArgs)
    }

    @MainActor private func tryImageDimensionsHook(
        path: String,
        name: String,
        size: Int64
    ) async -> (width: Int, height: Int)? {
        guard let handler = imageDimensionsHostHandler else { return nil }
        let dimArgs: [String: Any] = [
            "path": path,
            "name": name,
            "size": size,
        ]
        _ = traceHost("image_dimensions", args: dimArgs)
        return await handler(dimArgs)
    }

    @MainActor private func tryVideoMetadataHook(
        path: String,
        name: String,
        size: Int64
    ) async -> VideoMetadata? {
        guard let handler = videoMetadataHostHandler else { return nil }
        let metaArgs: [String: Any] = [
            "path": path,
            "name": name,
            "size": size,
        ]
        _ = traceHost("video_metadata", args: metaArgs)
        return await handler(metaArgs)
    }

    @MainActor private func tryUploadPhotoHook(
        convId: String,
        fileName: String,
        size: Int64,
        width: Int64,
        height: Int64,
        isE2ee: Bool
    ) async throws -> UploadedMediaResult? {
        guard let handler = uploadPhotoHostHandler else { return nil }
        var uploadArgs: [String: Any] = [
            "conv_id": convId,
            "file_name": fileName,
            "size": size,
            "width": Int(width),
            "height": Int(height),
        ]
        if isE2ee {
            uploadArgs["is_e2ee"] = true
        }
        _ = traceHost("upload_photo", args: uploadArgs)
        return try await handler(uploadArgs)
    }

    @MainActor private func tryUploadVideoHook(
        convId: String,
        fileName: String,
        size: Int64,
        durationMs: Int64,
        width: Int64,
        height: Int64,
        hasThumb: Bool,
        isE2ee: Bool
    ) async throws -> UploadedVideoResult? {
        guard let handler = uploadVideoHostHandler else { return nil }
        var uploadArgs: [String: Any] = [
            "conv_id": convId,
            "file_name": fileName,
            "size": size,
            "duration_ms": Int(durationMs),
            "width": Int(width),
            "height": Int(height),
            "has_thumb": hasThumb,
        ]
        if isE2ee {
            uploadArgs["is_e2ee"] = true
        }
        _ = traceHost("upload_video", args: uploadArgs)
        return try await handler(uploadArgs)
    }

    @MainActor private func tryUploadFileHook(
        convId: String,
        fileName: String,
        size: Int64,
        clientId: String?,
        isE2ee: Bool
    ) async throws -> UploadedMediaResult? {
        guard let handler = uploadFileHostHandler else { return nil }
        let uploadArgs: [String: Any] = [
            "conv_id": convId,
            "file_name": fileName,
            "size": size,
            "client_id": clientId ?? NSNull(),
            "is_e2ee": isE2ee,
        ]
        _ = traceHost("upload_file", args: uploadArgs)
        return try await handler(uploadArgs)
    }

    @MainActor private func tryMediaCacheLookupHook(
        key: String,
        hashPrefix: String,
        convId: String,
        msgId: String,
        kind: String
    ) async -> (handled: Bool, url: URL?) {
        guard let handler = mediaCacheLookupHostHandler else { return (false, nil) }
        let cacheArgs: [String: Any] = [
            "key": key,
            "hash_prefix": hashPrefix,
            "conv_id": convId,
            "msg_id": msgId,
            "kind": kind,
        ]
        _ = traceHost("media_cache_lookup", args: cacheArgs)
        return (true, await handler(cacheArgs))
    }

    @MainActor private func tryAllowedLocalFileHook(url: String) async -> Bool? {
        guard let handler = allowedLocalFileHostHandler else { return nil }
        let checkArgs: [String: Any] = ["url": url]
        _ = traceHost("check_local_file", args: checkArgs)
        return await handler(checkArgs)
    }

    @MainActor private func tryMediaLoaderFetchHook(
        mode: String,
        url: String,
        force: Bool
    ) async throws -> MediaLoaderFetchResult? {
        guard let handler = mediaLoaderFetchHostHandler else { return nil }
        let fetchArgs: [String: Any] = [
            "mode": mode,
            "url": url,
            "force": force,
        ]
        _ = traceHost("loader_fetch", args: fetchArgs)
        return try await handler(fetchArgs)
    }

    @MainActor private func tryVideoPosterHook(path: String) async -> (handled: Bool, url: URL?) {
        guard let handler = videoPosterHostHandler else { return (false, nil) }
        let args: [String: Any] = ["path": path]
        _ = traceHost("video_poster", args: args)
        return (true, await handler(args))
    }

    @MainActor private func tryStageFileHook(
        source: URL,
        stem: String,
        ext: String?
    ) async -> (handled: Bool, url: URL?) {
        guard let handler = stageFileHostHandler else { return (false, nil) }
        return (true, await handler(source, stem, ext))
    }
}

// MARK: - U15 Host I/O Adapters on ZaloEngine

extension ZaloEngine {
    /// Hydrates persisted `e2eeThreadsV1` from SQLite on cold start (before `start()` /
    /// `prepareStoreAndLocalCache` has attached `sqliteStore`) so 1-1 sends wait for persisted
    /// E2EE threads instead of falling back to plaintext.
    nonisolated internal func hostMediaLoadPersistedE2eeThreads() async -> [String] {
        if await e2eeManager.hasLoadedPersistedThreads() {
            return e2eeManager.e2eeThreadIdsSync()
        }
        if let store = await MainActor.run(body: { self.sqliteStore }) {
            await e2eeManager.loadPersistedThreads(store: store)
            return e2eeManager.e2eeThreadIdsSync()
        }
        let sessionURL = dataDirectory.appendingPathComponent("native-session.json")
        if let raw = try? Data(contentsOf: sessionURL),
           let root = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
           let plain = root["plainAccount"] as? [String: Any],
           let uid = plain["userId"] as? String,
           !uid.isEmpty {
            let dbURL = dataDirectory
                .appendingPathComponent("accounts", isDirectory: true)
                .appendingPathComponent(uid, isDirectory: true)
                .appendingPathComponent("history.sqlite3")
            if FileManager.default.fileExists(atPath: dbURL.path),
               let tempStore = try? ZaloSQLiteStore(path: dbURL.path) {
                await e2eeManager.loadPersistedThreads(store: tempStore)
            }
        }
        return e2eeManager.e2eeThreadIdsSync()
    }

    nonisolated internal func hostMediaReadOutgoingFile(
        opId: UInt64,
        path: String,
        name: String,
        mode: String
    ) async -> OutgoingFileProbeRecord {
        let url = URL(fileURLWithPath: path)
        if let probe = await tryReadOutgoingFileHook(path: path, name: name, mode: mode) {
            let effectiveMediaType: String?
            if let hint = probe.mediaType {
                effectiveMediaType = hint
            } else if mode == "media", probe.exists, !probe.isDirectory, probe.readable {
                let utType = UTType(filenameExtension: url.pathExtension)
                let isImage = utType?.conforms(to: .image) ?? false
                let isVideo = !isImage && Self.isVideoURL(url)
                effectiveMediaType = isImage ? "image" : (isVideo ? "video" : "file")
            } else {
                effectiveMediaType = nil
            }
            mediaHostIO.stage(
                StagedOutgoingFile(url: url, scoped: false, data: probe.data, videoThumbData: Data()),
                for: opId
            )
            return OutgoingFileProbeRecord(
                exists: probe.exists,
                isDir: probe.isDirectory,
                readable: probe.readable,
                size: probe.size,
                mediaType: effectiveMediaType
            )
        }

        let scoped = url.startAccessingSecurityScopedResource()
        mediaHostIO.stage(
            StagedOutgoingFile(url: url, scoped: scoped, data: Data(), videoThumbData: Data()),
            for: opId
        )

        if mode == "media" {
            guard let raw = try? Data(contentsOf: url) else {
                return OutgoingFileProbeRecord(
                    exists: false,
                    isDir: false,
                    readable: false,
                    size: 0,
                    mediaType: nil
                )
            }
            let utType = UTType(filenameExtension: url.pathExtension)
            let isImage = utType?.conforms(to: .image) ?? false
            let isVideo = !isImage && Self.isVideoURL(url)
            let mediaType = isImage ? "image" : (isVideo ? "video" : "file")
            mediaHostIO.updateData(raw, for: opId)
            return OutgoingFileProbeRecord(
                exists: true,
                isDir: false,
                readable: true,
                size: Int64(raw.count),
                mediaType: mediaType
            )
        }

        // mode == "file"
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            return OutgoingFileProbeRecord(
                exists: true,
                isDir: true,
                readable: false,
                size: 0,
                mediaType: nil
            )
        }
        guard exists,
              let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]) else {
            return OutgoingFileProbeRecord(
                exists: false,
                isDir: false,
                readable: false,
                size: 0,
                mediaType: nil
            )
        }
        if vals.isDirectory == true {
            return OutgoingFileProbeRecord(
                exists: true,
                isDir: true,
                readable: false,
                size: 0,
                mediaType: nil
            )
        }
        let size = Int64(vals.fileSize ?? 0)
        if size <= 0 {
            return OutgoingFileProbeRecord(
                exists: true,
                isDir: false,
                readable: true,
                size: 0,
                mediaType: nil
            )
        }
        let planLimit = await MainActor.run { self.cloud.plan?.fileLimit ?? 0 }
        let maxBytes = max(planLimit, 100 * 1_048_576)
        if maxBytes > 0 && size > maxBytes {
            return OutgoingFileProbeRecord(
                exists: true,
                isDir: false,
                readable: true,
                size: size,
                mediaType: nil
            )
        }
        guard let raw = try? Data(contentsOf: url) else {
            return OutgoingFileProbeRecord(
                exists: true,
                isDir: false,
                readable: false,
                size: size,
                mediaType: nil
            )
        }
        if raw.isEmpty {
            return OutgoingFileProbeRecord(
                exists: true,
                isDir: false,
                readable: true,
                size: 0,
                mediaType: nil
            )
        }
        mediaHostIO.updateData(raw, for: opId)
        return OutgoingFileProbeRecord(
            exists: true,
            isDir: false,
            readable: true,
            size: Int64(raw.count),
            mediaType: nil
        )
    }

    nonisolated internal func hostMediaReleaseOutgoingFile(opId: UInt64) async {
        mediaHostIO.release(opId: opId)
    }

    nonisolated internal func hostMediaImageDimensions(
        opId: UInt64,
        path: String,
        name: String,
        size: Int64
    ) async -> ImageDimensionsRecord {
        if let dims = await tryImageDimensionsHook(path: path, name: name, size: size) {
            return ImageDimensionsRecord(width: Int64(dims.width), height: Int64(dims.height))
        }
        let data = mediaHostIO.entry(for: opId)?.data ?? Data()
        let dims = Self.computeImageDimensions(data)
        return ImageDimensionsRecord(width: Int64(dims.width), height: Int64(dims.height))
    }

    nonisolated internal func hostMediaVideoMetadata(
        opId: UInt64,
        path: String,
        name: String,
        size: Int64
    ) async -> VideoMetadataRecord {
        if let meta = await tryVideoMetadataHook(path: path, name: name, size: size) {
            mediaHostIO.updateVideoThumb(meta.thumbnailData, for: opId)
            return VideoMetadataRecord(
                durationMs: Int64(meta.durationMs),
                width: Int64(meta.width),
                height: Int64(meta.height),
                hasThumb: !meta.thumbnailData.isEmpty
            )
        }
        let url = mediaHostIO.entry(for: opId)?.url ?? URL(fileURLWithPath: path)
        let meta = await Self.extractVideoMetadata(from: url)
        mediaHostIO.updateVideoThumb(meta.thumbnailData, for: opId)
        return VideoMetadataRecord(
            durationMs: Int64(meta.durationMs),
            width: Int64(meta.width),
            height: Int64(meta.height),
            hasThumb: !meta.thumbnailData.isEmpty
        )
    }

    nonisolated internal func hostMediaUploadPhoto(
        opId: UInt64,
        convId: String,
        fileName: String,
        size: Int64,
        width: Int64,
        height: Int64,
        isE2ee: Bool
    ) async -> UploadPhotoOutcomeRecord {
        do {
            let res: UploadedMediaResult
            if let hooked = try await tryUploadPhotoHook(
                convId: convId,
                fileName: fileName,
                size: size,
                width: width,
                height: height,
                isE2ee: isE2ee
            ) {
                res = hooked
            } else {
                let data = mediaHostIO.entry(for: opId)?.data ?? Data()
                if isE2ee {
                    let store = await MainActor.run { self.sqliteStore }
                    res = try await sessionClient.uploadAndSendE2EEPhoto(
                        convId: convId,
                        fileName: fileName,
                        plaintextData: data,
                        width: Int(width),
                        height: Int(height),
                        e2eeManager: e2eeManager,
                        store: store,
                        webSocket: webSocket
                    )
                } else {
                    res = try await sessionClient.uploadAndSendPhoto(
                        convId: convId,
                        fileName: fileName,
                        data: data,
                        width: Int(width),
                        height: Int(height)
                    )
                }
            }
            return .ok(
                url: res.url,
                msgId: res.msgId,
                cliMsgId: res.cliMsgId,
                width: Int64(res.width),
                height: Int64(res.height)
            )
        } catch {
            await MainActor.run {
                EngineLog.shared.write("sendMedia failed: \(error.localizedDescription)")
            }
            return .err(message: error.localizedDescription)
        }
    }

    nonisolated internal func hostMediaUploadVideo(
        opId: UInt64,
        convId: String,
        fileName: String,
        size: Int64,
        durationMs: Int64,
        width: Int64,
        height: Int64,
        hasThumb: Bool,
        isE2ee: Bool
    ) async -> UploadVideoOutcomeRecord {
        do {
            let res: UploadedVideoResult
            if let hooked = try await tryUploadVideoHook(
                convId: convId,
                fileName: fileName,
                size: size,
                durationMs: durationMs,
                width: width,
                height: height,
                hasThumb: hasThumb,
                isE2ee: isE2ee
            ) {
                res = hooked
            } else {
                let entry = mediaHostIO.entry(for: opId)
                let data = entry?.data ?? Data()
                let thumb = entry?.videoThumbData ?? Data()
                if isE2ee {
                    let store = await MainActor.run { self.sqliteStore }
                    res = try await sessionClient.uploadAndSendE2EEVideo(
                        convId: convId,
                        fileName: fileName,
                        plaintextData: data,
                        thumbnailData: thumb,
                        durationMs: Int(durationMs),
                        width: Int(width),
                        height: Int(height),
                        e2eeManager: e2eeManager,
                        store: store,
                        webSocket: webSocket
                    )
                } else {
                    res = try await sessionClient.uploadAndSendVideo(
                        convId: convId,
                        fileName: fileName,
                        data: data,
                        thumbnailData: thumb,
                        durationMs: Int(durationMs),
                        width: Int(width),
                        height: Int(height),
                        webSocket: webSocket
                    )
                }
            }
            return .ok(
                url: res.url,
                thumbUrl: res.thumbUrl,
                msgId: res.msgId,
                cliMsgId: res.cliMsgId,
                width: Int64(res.width),
                height: Int64(res.height),
                durationMs: Int64(res.durationMs)
            )
        } catch {
            await MainActor.run {
                EngineLog.shared.write("sendMedia failed: \(error.localizedDescription)")
            }
            return .err(message: error.localizedDescription)
        }
    }

    nonisolated internal func hostMediaUploadFile(
        opId: UInt64,
        convId: String,
        fileName: String,
        size: Int64,
        clientId: String?,
        isE2ee: Bool
    ) async -> UploadFileOutcomeRecord {
        do {
            let hasHook = await MainActor.run { self.uploadFileHostHandler != nil }
            if hasHook && clientId != nil {
                await waitForCoreMirrorDrain()
            }
            let res: UploadedMediaResult
            if let hooked = try await tryUploadFileHook(
                convId: convId,
                fileName: fileName,
                size: size,
                clientId: clientId,
                isE2ee: isE2ee
            ) {
                res = hooked
            } else {
                let entry = mediaHostIO.entry(for: opId)
                let data: Data
                if let existing = entry, !existing.data.isEmpty {
                    data = existing.data
                } else if let url = entry?.url, let loaded = try? Data(contentsOf: url) {
                    data = loaded
                } else {
                    data = Data()
                }
                let cliInt = clientId.flatMap(Int64.init)
                if isE2ee {
                    let store = await MainActor.run { self.sqliteStore }
                    res = try await sessionClient.uploadAndSendE2EEFile(
                        convId: convId,
                        fileName: fileName,
                        plaintextData: data,
                        clientId: cliInt,
                        e2eeManager: e2eeManager,
                        store: store,
                        webSocket: webSocket
                    )
                } else {
                    res = try await sessionClient.uploadAndSendFile(
                        convId: convId,
                        fileName: fileName,
                        data: data,
                        clientId: cliInt,
                        webSocket: webSocket
                    )
                }
            }
            return .ok(url: res.url, msgId: res.msgId, cliMsgId: res.cliMsgId)
        } catch let sessionErr as ZaloSessionError {
            await MainActor.run {
                if clientId != nil {
                    EngineLog.shared.write("sendFiles failed: code=\(sessionErr.code) msg=\(sessionErr.message)")
                } else {
                    EngineLog.shared.write("sendMedia failed: \(sessionErr.localizedDescription)")
                }
            }
            return .sessionError(code: Int64(sessionErr.code), message: sessionErr.message)
        } catch is URLError {
            await MainActor.run {
                if clientId != nil {
                    EngineLog.shared.write("sendFiles failed: network error")
                } else {
                    EngineLog.shared.write("sendMedia failed: network error")
                }
            }
            return .networkError
        } catch {
            await MainActor.run {
                if clientId != nil {
                    EngineLog.shared.write("sendFiles failed: \(error.localizedDescription)")
                } else {
                    EngineLog.shared.write("sendMedia failed: \(error.localizedDescription)")
                }
            }
            return .otherError(message: error.localizedDescription)
        }
    }

    nonisolated internal func hostMediaRemoveOwnLocalFile(path: String) async {
        let url = URL(fileURLWithPath: path)
        if MediaLoader.isOwnLocalFile(url) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    nonisolated internal func hostMediaFileExists(path: String) async -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    nonisolated internal func hostMediaCacheLookup(
        key: String,
        hashPrefix: String,
        convId: String,
        msgId: String,
        kind: String
    ) async -> MediaCacheHitRecord? {
        let mediaKind = MediaKind(rawValue: kind) ?? .photo
        let cacheDir = dataDirectory.appendingPathComponent("MediaCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let existing: URL?
        let hookResult = await tryMediaCacheLookupHook(
            key: key,
            hashPrefix: hashPrefix,
            convId: convId,
            msgId: msgId,
            kind: kind
        )
        if hookResult.handled {
            existing = hookResult.url
        } else {
            existing = Self.findCachedMediaFile(hashPrefix: hashPrefix, in: cacheDir, kind: mediaKind)
        }

        guard let existing else { return nil }
        return MediaCacheHitRecord(path: existing.path, isVideo: VideoPoster.isVideo(existing))
    }

    nonisolated internal func hostMediaCheckLocalFile(url: String) async -> LocalFileCheckRecord {
        guard let parsed = URL(string: url), parsed.isFileURL else {
            return LocalFileCheckRecord(allowed: false, path: "", isVideo: false)
        }
        let allowed: Bool
        if let hookAllowed = await tryAllowedLocalFileHook(url: url) {
            allowed = hookAllowed
        } else {
            allowed = MediaLoader.isAllowedLocalFile(parsed) && FileManager.default.fileExists(atPath: parsed.path)
        }
        let isVideo = allowed && VideoPoster.isVideo(parsed)
        return LocalFileCheckRecord(allowed: allowed, path: parsed.path, isVideo: isVideo)
    }

    nonisolated internal func hostMediaLoaderFetchMedia(
        url: String,
        kind: String,
        hashPrefix: String,
        force: Bool
    ) async -> MediaFetchOutcomeRecord {
        guard let remoteURL = URL(string: url) else { return .transient }
        let mediaKind = MediaKind(rawValue: kind) ?? .photo
        let cacheDir = dataDirectory.appendingPathComponent("MediaCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let hasFetchHook = await MainActor.run { self.mediaLoaderFetchHostHandler != nil }
        if force && !hasFetchHook {
            await MediaLoader.shared.forgetFailures(for: remoteURL)
            await MediaLoader.shared.evictCachedFile(for: remoteURL)
        }

        if mediaKind == .video {
            do {
                let fetchedFile: URL
                if let hooked = try await tryMediaLoaderFetchHook(mode: "file", url: url, force: force) {
                    switch hooked {
                    case .file(let u):
                        fetchedFile = u
                    case .data(let bytes):
                        let probe = cacheDir.appendingPathComponent(".\(UUID().uuidString).probe")
                        try bytes.write(to: probe, options: .atomic)
                        let container = CloudContainer(fileAt: probe)
                        let ext = Self.mediaExtension(for: container, fallbackKind: .video)
                        let dest = cacheDir.appendingPathComponent("\(hashPrefix).\(ext)")
                        try? FileManager.default.removeItem(at: dest)
                        try FileManager.default.moveItem(at: probe, to: dest)
                        return .cached(path: dest.path, isVideo: true)
                    }
                } else {
                    fetchedFile = try await MediaLoader.shared.localFile(for: remoteURL)
                }
                let container = CloudContainer(fileAt: fetchedFile)
                let ext = Self.mediaExtension(for: container, fallbackKind: .video)
                let dest = cacheDir.appendingPathComponent("\(hashPrefix).\(ext)")
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: fetchedFile, to: dest)
                return .cached(path: dest.path, isVideo: true)
            } catch {
                return ChatFileResolver.isPermanentGone(error) ? .permanentGone : .transient
            }
        }

        // .photo or .videoThumb
        do {
            let data: Data
            if let hooked = try await tryMediaLoaderFetchHook(mode: "data", url: url, force: force) {
                switch hooked {
                case .data(let bytes):
                    data = bytes
                case .file(let u):
                    data = try Data(contentsOf: u)
                }
            } else {
                data = try await MediaLoader.shared.data(for: remoteURL)
            }
            guard !data.isEmpty else { return .transient }
            let tempProbe = cacheDir.appendingPathComponent(".\(UUID().uuidString).probe")
            try data.write(to: tempProbe, options: .atomic)
            guard Self.isValidMediaFile(tempProbe, kind: mediaKind) else {
                try? FileManager.default.removeItem(at: tempProbe)
                return .transient
            }
            let container = CloudContainer(fileAt: tempProbe)
            let ext = Self.mediaExtension(for: container, fallbackKind: mediaKind)
            let dest = cacheDir.appendingPathComponent("\(hashPrefix).\(ext)")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tempProbe, to: dest)
            return .cached(path: dest.path, isVideo: VideoPoster.isVideo(dest))
        } catch {
            return ChatFileResolver.isPermanentGone(error) ? .permanentGone : .transient
        }
    }

    nonisolated internal func hostMediaVideoPoster(path: String) async -> String? {
        let video = URL(fileURLWithPath: path)
        let hookResult = await tryVideoPosterHook(path: path)
        if hookResult.handled {
            return hookResult.url?.path
        }
        return (await VideoPoster.poster(for: video))?.path
    }

    nonisolated internal func hostMediaLoaderFetchFile(
        url: String,
        force: Bool,
        requestToken: UInt64
    ) async -> FileFetchOutcomeRecord {
        guard let remoteURL = URL(string: url) else {
            return .error(kind: .badUrl)
        }
        let progress = mediaHostIO.progressHandler(for: requestToken)
        do {
            let cachedFile: URL
            if let hooked = try await tryMediaLoaderFetchHook(mode: "file", url: url, force: force) {
                switch hooked {
                case .file(let u):
                    cachedFile = u
                case .data(let bytes):
                    let tempDir = dataDirectory.appendingPathComponent("MediaCache", isDirectory: true)
                    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    let temp = tempDir.appendingPathComponent(".\(UUID().uuidString).dl")
                    try bytes.write(to: temp, options: .atomic)
                    cachedFile = temp
                }
            } else {
                if force, !remoteURL.isFileURL {
                    await MediaLoader.shared.evictCachedFile(for: remoteURL)
                }
                cachedFile = try await MediaLoader.shared.localFile(for: remoteURL, progress: progress)
            }
            let container = CloudContainer(fileAt: cachedFile)
            return .fetched(cachedPath: cachedFile.path, containerExt: container.fileExtension)
        } catch {
            return .error(kind: FileLoadErrorKindRecord(error: error))
        }
    }

    nonisolated internal func hostMediaStageFile(
        sourcePath: String,
        stem: String,
        ext: String?
    ) async -> String? {
        let source = URL(fileURLWithPath: sourcePath)
        let hookResult = await tryStageFileHook(source: source, stem: stem, ext: ext)
        if hookResult.handled {
            return hookResult.url?.path
        }
        return await MainActor.run {
            CloudFiles.stage(source, name: stem, ext: ext)?.path
        }
    }
}
