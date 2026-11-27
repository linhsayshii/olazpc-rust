import CryptoKit
import Foundation

/// Result of uploading and sending a native video message.
struct UploadedVideoResult: Sendable, Equatable {
    var url: String
    var thumbUrl: String
    var msgId: String
    var cliMsgId: String
    var width: Int
    var height: Int
    var durationMs: Int
}

/// Pure specification for a multipart video or thumbnail chunk upload request.
struct VideoUploadRequestSpec: @unchecked Sendable {
    let service: String
    let path: String
    let queryParams: [String: String]
    let encryptedPayload: [String: Any]
    let fieldName: String
    let fileName: String
    let mimeType: String
}

/// Pure specification for a video forward or asyncfile message send request.
struct VideoForwardRequestSpec: @unchecked Sendable {
    let service: String
    let path: String
    let encryptedPayload: [String: Any]
}

extension ZaloSessionClient {
    /// Resolves the MIME type for common video file extensions.
    static func videoMimeType(forFileName fileName: String) -> String {
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "m4v": return "video/x-m4v"
        case "webm": return "video/webm"
        case "mkv": return "video/x-matroska"
        case "avi": return "video/x-msvideo"
        case "3gp": return "video/3gpp"
        default: return "application/octet-stream"
        }
    }

    /// Builds the endpoint, query parameters, and encrypted payload for one 1MB video chunk upload.
    static func buildVideoChunkUploadSpec(
        convId: String,
        fileName: String,
        totalChunk: Int,
        chunkId: Int,
        totalSize: Int,
        clientId: Int64,
        imei: String,
        isE2EE: Bool = false
    ) -> VideoUploadRequestSpec {
        buildMultipartSpec(
            convId: convId,
            groupPath: "/api/group/video/file/upload",
            directPath: "/api/message/video/file/upload",
            fileName: fileName,
            mimeType: videoMimeType(forFileName: fileName),
            totalChunk: totalChunk,
            chunkId: chunkId,
            totalSize: totalSize,
            clientId: clientId,
            imei: imei,
            isE2EE: isE2EE
        )
    }

    /// Builds the endpoint, query parameters, and encrypted payload for a video JPEG thumbnail upload.
    static func buildVideoThumbUploadSpec(
        convId: String,
        totalChunk: Int = 1,
        chunkId: Int = 1,
        totalSize: Int,
        clientId: Int64,
        imei: String,
        isE2EE: Bool = false
    ) -> VideoUploadRequestSpec {
        buildMultipartSpec(
            convId: convId,
            groupPath: "/api/group/video/thumb/upload",
            directPath: "/api/message/video/thumb/upload",
            fileName: "thumb.jpg",
            mimeType: "image/jpeg",
            totalChunk: totalChunk,
            chunkId: chunkId,
            totalSize: totalSize,
            clientId: clientId,
            imei: imei,
            isE2EE: isE2EE
        )
    }

    private static func buildMultipartSpec(
        convId: String,
        groupPath: String,
        directPath: String,
        fileName: String,
        mimeType: String,
        totalChunk: Int,
        chunkId: Int,
        totalSize: Int,
        clientId: Int64,
        imei: String,
        isE2EE: Bool = false
    ) -> VideoUploadRequestSpec {
        let isGroup = ZaloWireParser.isGroupId(convId)
        let cleanId = isGroup ? ZaloWireParser.cleanGroupId(convId) : ZaloWireParser.stripUserPrefix(convId)
        var payload: [String: Any] = [
            "totalChunk": totalChunk,
            "fileName": fileName,
            "clientId": clientId,
            "totalSize": totalSize,
            "imei": imei,
            "isE2EE": isE2EE ? 1 : 0,
            "chunkId": chunkId,
        ]
        if isGroup {
            payload["grid"] = cleanId
        } else {
            payload["toid"] = cleanId
        }
        return VideoUploadRequestSpec(
            service: "file",
            path: isGroup ? groupPath : directPath,
            queryParams: ["type": isGroup ? "11" : "2"],
            encryptedPayload: payload,
            fieldName: "chunkContent",
            fileName: fileName,
            mimeType: mimeType
        )
    }

    /// Serializes the `msgInfo` JSON payload expected by `/api/*/forward` for video messages.
    static func buildVideoMsgInfoJSON(
        videoUrl: String,
        thumbUrl: String,
        durationMs: Int,
        width: Int,
        height: Int,
        fileSize: Int,
        title: String = ""
    ) -> String {
        let info: [String: Any] = [
            "videoUrl": videoUrl,
            "thumbUrl": thumbUrl,
            "duration": max(0, durationMs),
            "width": max(0, width),
            "height": max(0, height),
            "fileSize": max(0, fileSize),
            "title": title,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: info,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Builds the `/api/group/forward` or `/api/message/forward` request specification for sending an uploaded video.
    static func buildVideoForwardSpec(
        convId: String,
        videoUrl: String,
        thumbUrl: String,
        durationMs: Int,
        width: Int,
        height: Int,
        fileSize: Int,
        clientId: Int64,
        imei: String,
        title: String = ""
    ) -> VideoForwardRequestSpec {
        let isGroup = ZaloWireParser.isGroupId(convId)
        let cleanId = isGroup ? ZaloWireParser.cleanGroupId(convId) : ZaloWireParser.stripUserPrefix(convId)
        let msgInfo = buildVideoMsgInfoJSON(
            videoUrl: videoUrl,
            thumbUrl: thumbUrl,
            durationMs: durationMs,
            width: width,
            height: height,
            fileSize: fileSize,
            title: title
        )
        var payload: [String: Any] = [
            "msgType": 5,
            "msgInfo": msgInfo,
            "clientId": clientId,
            "ttl": 0,
            "imei": imei,
        ]
        if isGroup {
            payload["grid"] = cleanId
            payload["visibility"] = 0
        } else {
            payload["toId"] = cleanId
        }
        return VideoForwardRequestSpec(
            service: "file",
            path: isGroup ? "/api/group/forward" : "/api/message/forward",
            encryptedPayload: payload
        )
    }

    /// Builds the fallback `/api/*/asyncfile/msg` request specification matching `uploadAndSendFile` conventions.
    static func buildVideoAsyncFileMsgSpec(
        convId: String,
        fileId: String,
        fileUrl: String,
        fileName: String,
        checksum: String,
        totalSize: Int,
        clientId: Int64,
        imei: String
    ) -> VideoForwardRequestSpec {
        let isGroup = ZaloWireParser.isGroupId(convId)
        let cleanId = isGroup ? ZaloWireParser.cleanGroupId(convId) : ZaloWireParser.stripUserPrefix(convId)
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        let fidVal: Any = Int64(fileId) ?? fileId
        var payload: [String: Any] = [
            "fileId": fidVal,
            "checksum": checksum,
            "checksumSha": "",
            "extension": ext,
            "totalSize": totalSize,
            "fileName": fileName,
            "clientId": clientId,
            "fType": 2,
            "fileCount": 0,
            "fdata": "{}",
            "ttl": 0,
            "imei": imei,
        ]
        if !fileUrl.isEmpty {
            payload["fileUrl"] = fileUrl
        }
        if isGroup {
            payload["grid"] = cleanId
        } else {
            payload["toid"] = cleanId
        }
        return VideoForwardRequestSpec(
            service: "file",
            path: isGroup ? "/api/group/asyncfile/msg" : "/api/message/asyncfile/msg",
            encryptedPayload: payload
        )
    }

    private func uploadChunkedMultipart(
        data: Data,
        chunkSize: Int = 1024 * 1024,
        makeSpec: (_ totalChunk: Int, _ chunkId: Int) -> VideoUploadRequestSpec,
        onData: ([String: Any]) -> Void
    ) async throws {
        let totalChunk = max(1, (data.count + chunkSize - 1) / chunkSize)
        for chunkIndex in 0..<totalChunk {
            let start = chunkIndex * chunkSize
            let end = min(start + chunkSize, data.count)
            let slice = data.subdata(in: start..<end)
            let spec = makeSpec(totalChunk, chunkIndex + 1)
            do {
                let resp = try await postMultipart(
                    service: spec.service,
                    path: spec.path,
                    queryParams: spec.queryParams,
                    encryptedPayload: spec.encryptedPayload,
                    fieldName: spec.fieldName,
                    fileName: spec.fileName,
                    mimeType: spec.mimeType,
                    chunkData: slice
                )
                if let d = resp["data"] as? [String: Any] {
                    onData(d)
                }
            } catch let err as ZaloSessionError where err.isAuthError {
                throw err
            } catch {
                // Non-auth chunk failures allow fallback handling by caller.
            }
        }
    }

    /// Official `_extractForwardContent(MSGTYPE_FORWARD_VIDEO)` `prmE2EE` JSON payload for cmd `16012`.
    static func buildE2EEVideoParamsJSON(
        durationMs: Int,
        fileSize: Int,
        width: Int,
        height: Int,
        rotation: Int = 0
    ) -> String {
        let obj: [String: Any] = [
            "duration": max(0, durationMs),
            "fileSize": max(0, fileSize),
            "video_height": max(0, height),
            "video_rotation": rotation,
            "video_width": max(0, width),
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Official `forwardMessage(..., MSGTYPE_FORWARD_VIDEO)` `listParams` entry for `/api/e2ee/pc/message/forward` (cmd `16012`, `msgType: 5`).
    static func buildE2EEVideoForwardListParamEntry(
        toId: String,
        platform: Int,
        clientId: Int64,
        imei: String,
        registrationId: Int,
        senderIid: Int,
        rawVideoUrl: String,
        rawThumbUrl: String,
        durationMs: Int,
        width: Int,
        height: Int,
        fileSize: Int,
        cipherTitle: String,
        cipherVideoKey: String,
        cipherThumbKey: String,
        cipherParams: String,
        ttl: Int = 0
    ) -> [String: Any] {
        let info: [String: Any] = [
            "videoUrl": appendE2EESession(rawVideoUrl, session: cipherVideoKey),
            "thumbUrl": rawThumbUrl.isEmpty ? "" : appendE2EESession(rawThumbUrl, session: cipherThumbKey),
            "prmE2EE": cipherParams,
            "title": cipherTitle,
            "duration": max(0, durationMs),
            "width": max(0, width),
            "height": max(0, height),
            "fileSize": max(0, fileSize),
        ]
        let msgInfoJSON: String
        if let data = try? JSONSerialization.data(
            withJSONObject: info,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) {
            msgInfoJSON = String(decoding: data, as: UTF8.self)
        } else {
            msgInfoJSON = "{}"
        }
        return buildE2EEListParamEntry(
            toId: toId,
            platform: platform,
            clientId: clientId,
            imei: imei,
            registrationId: registrationId,
            senderIid: senderIid,
            ttl: ttl,
            version: 0,
            compatVersion: 0,
            extraFields: [
                "msgInfo": msgInfoJSON,
            ]
        )
    }

    /// Encrypts video bytes + thumbnail with separate AES-256-GCM keys, uploads with `isE2EE: 1`,
    /// sends via `/api/e2ee/pc/message/forward` (cmd `16012`, `msgType: 5`), and falls back ONLY to
    /// `uploadAndSendE2EEFile` (cmd `16005`) — never plaintext. Fails closed when no E2EE session exists.
    func uploadAndSendE2EEVideo(
        convId: String,
        fileName: String,
        plaintextData: Data,
        thumbnailData: Data,
        durationMs: Int,
        width: Int,
        height: Int,
        e2eeManager: ZaloE2EEManager,
        store: ZaloSQLiteStore?,
        webSocket: ZaloWebSocket
    ) async throws -> UploadedVideoResult {
        guard !ZaloWireParser.isGroupId(convId) else {
            throw ZaloSessionError(
                code: -1,
                message: "Video nhóm không dùng mã hóa đầu cuối 1-1.",
                url: "/api/e2ee/pc/message/forward"
            )
        }
        let cleanId = ZaloWireParser.stripUserPrefix(convId)
        guard let rawMyUid = account?.userId, !rawMyUid.isEmpty else {
            throw ZaloSessionError(
                code: -108,
                message: "Chưa đăng nhập.",
                url: "/api/e2ee/pc/message/forward"
            )
        }
        let myUid = ZaloWireParser.stripUserPrefix(rawMyUid)

        // Fail closed before uploading any bytes if no Signal session exists for recipient.
        let ready = await e2eeManager.ensureSessions(
            forPeer: cleanId,
            myUid: myUid,
            webSocket: webSocket,
            store: store
        )
        guard ready else {
            throw ZaloSessionError(
                code: -1,
                message: "Chưa có phiên mã hóa đầu cuối với người nhận.",
                url: "/api/e2ee/pc/message/forward"
            )
        }

        let (encVideoData, videoSessionB64) = try SecureStream.encryptE2EEFile(plaintextData)
        let cliInt = nextClientId()
        let cliId = "\(cliInt)"
        var uploadDataDict: [String: Any] = [:]

        try await uploadChunkedMultipart(
            data: encVideoData,
            makeSpec: { totalChunk, chunkId in
                Self.buildVideoChunkUploadSpec(
                    convId: cleanId,
                    fileName: fileName,
                    totalChunk: totalChunk,
                    chunkId: chunkId,
                    totalSize: encVideoData.count,
                    clientId: cliInt,
                    imei: imei,
                    isE2EE: true
                )
            },
            onData: { d in
                if !JSONLossless.string(d["fileId"] ?? d["clientFileId"]).isEmpty
                    || !JSONLossless.string(d["fileUrl"] ?? d["videoUrl"] ?? d["url"]).isEmpty {
                    uploadDataDict = d
                }
            }
        )

        let fileId = JSONLossless.string(uploadDataDict["fileId"] ?? uploadDataDict["clientFileId"])
        var rawVideoUrl = JSONLossless.string(uploadDataDict["fileUrl"] ?? uploadDataDict["videoUrl"] ?? uploadDataDict["url"])
        if rawVideoUrl.isEmpty, !fileId.isEmpty {
            for _ in 0..<20 where !(await webSocket.isAuthed) {
                try? await Task.sleep(for: .milliseconds(150))
            }
            if await webSocket.isAuthed {
                rawVideoUrl = await webSocket.waitForFileDone(fileId: fileId, timeoutSeconds: 15) ?? ""
            }
        }

        var rawThumbUrl = ""
        var thumbSessionB64 = ""
        if !thumbnailData.isEmpty, !rawVideoUrl.isEmpty,
           let (encThumbData, genThumbSession) = try? SecureStream.encryptE2EEFile(thumbnailData) {
            let thumbCliInt = nextClientId()
            try await uploadChunkedMultipart(
                data: encThumbData,
                makeSpec: { totalChunk, chunkId in
                    Self.buildVideoThumbUploadSpec(
                        convId: cleanId,
                        totalChunk: totalChunk,
                        chunkId: chunkId,
                        totalSize: encThumbData.count,
                        clientId: thumbCliInt,
                        imei: imei,
                        isE2EE: true
                    )
                },
                onData: { td in
                    let candidate = JSONLossless.string(
                        td["thumbUrl"] ?? td["url"] ?? td["normalUrl"] ?? td["hdUrl"] ?? td["fileUrl"] ?? td["oriUrl"]
                    )
                    if !candidate.isEmpty {
                        rawThumbUrl = candidate
                        thumbSessionB64 = genThumbSession
                    }
                }
            )
        }

        let localThumbUrl = rawThumbUrl.isEmpty ? "" : Self.appendE2EESession(rawThumbUrl, session: thumbSessionB64)

        if !rawVideoUrl.isEmpty {
            let videoParamsJSON = Self.buildE2EEVideoParamsJSON(
                durationMs: durationMs,
                fileSize: plaintextData.count,
                width: width,
                height: height
            )
            let targets = await e2eeManager.encryptVideoForwardMessage(
                peerUid: cleanId,
                myUid: myUid,
                title: "",
                videoSessionB64: videoSessionB64,
                thumbSessionB64: thumbSessionB64,
                videoParamsJSON: videoParamsJSON,
                store: store
            )
            if !targets.isEmpty {
                let senderIid = await e2eeManager.localRegistrationId()
                let listParams: [[String: Any]] = targets.compactMap { target in
                    guard target.ciphers.count >= 4 else { return nil }
                    return Self.buildE2EEVideoForwardListParamEntry(
                        toId: target.toId,
                        platform: target.platform,
                        clientId: cliInt,
                        imei: imei,
                        registrationId: target.registrationId,
                        senderIid: senderIid,
                        rawVideoUrl: rawVideoUrl,
                        rawThumbUrl: rawThumbUrl,
                        durationMs: durationMs,
                        width: width,
                        height: height,
                        fileSize: plaintextData.count,
                        cipherTitle: target.ciphers[0],
                        cipherVideoKey: target.ciphers[1],
                        cipherThumbKey: target.ciphers[2],
                        cipherParams: target.ciphers[3]
                    )
                }
                if !listParams.isEmpty {
                    do {
                        let sendRes = try await sendE2EEMessageAPI(
                            endpoint: "forward",
                            threadId: cleanId,
                            isGroup: false,
                            clientId: cliInt,
                            listParams: ZaloJSONArrayBox(listParams),
                            destType: 3,
                            msgType: 5
                        )
                        let msgId = sendRes.msgId.isEmpty ? cliId : sendRes.msgId
                        return UploadedVideoResult(
                            url: Self.appendE2EESession(rawVideoUrl, session: videoSessionB64),
                            thumbUrl: localThumbUrl,
                            msgId: msgId,
                            cliMsgId: cliId,
                            width: width,
                            height: height,
                            durationMs: durationMs
                        )
                    } catch let err as ZaloSessionError where err.isAuthError {
                        throw err
                    } catch {
                        // Fall through to E2EE file fallback (`16005`) below — never plaintext.
                    }
                }
            }
        }

        // Fallback: send as E2EE file (`16005`, `/api/e2ee/pc/message/file`) — never plaintext.
        let fallback = try await uploadAndSendE2EEFile(
            convId: cleanId,
            fileName: fileName,
            plaintextData: plaintextData,
            clientId: cliInt,
            e2eeManager: e2eeManager,
            store: store,
            webSocket: webSocket
        )
        return UploadedVideoResult(
            url: fallback.url,
            thumbUrl: localThumbUrl,
            msgId: fallback.msgId,
            cliMsgId: fallback.cliMsgId,
            width: width,
            height: height,
            durationMs: durationMs
        )
    }

    /// Uploads a video in 1MB chunks plus its JPEG thumbnail, sends via `/forward`, and falls back to `asyncfile/msg`.
    func uploadAndSendVideo(
        convId: String,
        fileName: String,
        data: Data,
        thumbnailData: Data,
        durationMs: Int,
        width: Int,
        height: Int,
        webSocket: ZaloWebSocket? = nil
    ) async throws -> UploadedVideoResult {
        let cliInt = nextClientId()
        let cliId = "\(cliInt)"
        var uploadDataDict: [String: Any] = [:]

        try await uploadChunkedMultipart(
            data: data,
            makeSpec: { totalChunk, chunkId in
                Self.buildVideoChunkUploadSpec(
                    convId: convId,
                    fileName: fileName,
                    totalChunk: totalChunk,
                    chunkId: chunkId,
                    totalSize: data.count,
                    clientId: cliInt,
                    imei: imei
                )
            },
            onData: { d in
                if !JSONLossless.string(d["fileId"] ?? d["clientFileId"]).isEmpty
                    || !JSONLossless.string(d["fileUrl"] ?? d["videoUrl"] ?? d["url"]).isEmpty {
                    uploadDataDict = d
                }
            }
        )

        let fileId = JSONLossless.string(uploadDataDict["fileId"] ?? uploadDataDict["clientFileId"])
        var fileUrl = JSONLossless.string(uploadDataDict["fileUrl"] ?? uploadDataDict["videoUrl"] ?? uploadDataDict["url"])
        if fileUrl.isEmpty, !fileId.isEmpty, let webSocket {
            for _ in 0..<20 where !(await webSocket.isAuthed) {
                try? await Task.sleep(for: .milliseconds(150))
            }
            if await webSocket.isAuthed {
                fileUrl = await webSocket.waitForFileDone(fileId: fileId, timeoutSeconds: 15) ?? ""
            }
        }

        var thumbUrl = ""
        if !thumbnailData.isEmpty, !fileUrl.isEmpty {
            let thumbCliInt = nextClientId()
            try await uploadChunkedMultipart(
                data: thumbnailData,
                makeSpec: { totalChunk, chunkId in
                    Self.buildVideoThumbUploadSpec(
                        convId: convId,
                        totalChunk: totalChunk,
                        chunkId: chunkId,
                        totalSize: thumbnailData.count,
                        clientId: thumbCliInt,
                        imei: imei
                    )
                },
                onData: { td in
                    let candidate = JSONLossless.string(
                        td["thumbUrl"] ?? td["url"] ?? td["normalUrl"] ?? td["hdUrl"] ?? td["fileUrl"] ?? td["oriUrl"]
                    )
                    if !candidate.isEmpty { thumbUrl = candidate }
                }
            )
        }

        var sendResp: [String: Any]?
        if !fileUrl.isEmpty {
            let forwardSpec = Self.buildVideoForwardSpec(
                convId: convId,
                videoUrl: fileUrl,
                thumbUrl: thumbUrl,
                durationMs: durationMs,
                width: width,
                height: height,
                fileSize: data.count,
                clientId: cliInt,
                imei: imei
            )
            do {
                sendResp = try await post(
                    service: forwardSpec.service,
                    path: forwardSpec.path,
                    encryptedPayload: forwardSpec.encryptedPayload
                )
            } catch let err as ZaloSessionError where err.isAuthError {
                throw err
            } catch {
                sendResp = nil
            }
        }

        if sendResp == nil {
            if !fileId.isEmpty && !fileUrl.isEmpty {
                let checksum = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let asyncSpec = Self.buildVideoAsyncFileMsgSpec(
                    convId: convId,
                    fileId: fileId,
                    fileUrl: fileUrl,
                    fileName: fileName,
                    checksum: checksum,
                    totalSize: data.count,
                    clientId: cliInt,
                    imei: imei
                )
                do {
                    sendResp = try await post(
                        service: asyncSpec.service,
                        path: asyncSpec.path,
                        encryptedPayload: asyncSpec.encryptedPayload
                    )
                } catch let err as ZaloSessionError where err.isAuthError {
                    throw err
                } catch {
                    sendResp = nil
                }
            }
            if sendResp == nil {
                let fallback = try await uploadAndSendFile(
                    convId: convId,
                    fileName: fileName,
                    data: data,
                    webSocket: webSocket
                )
                return UploadedVideoResult(
                    url: fallback.url,
                    thumbUrl: thumbUrl,
                    msgId: fallback.msgId,
                    cliMsgId: fallback.cliMsgId,
                    width: width,
                    height: height,
                    durationMs: durationMs
                )
            }
        }

        let d = sendResp?["data"] as? [String: Any] ?? [:]
        let msgId = JSONLossless.string(d["msgId"])
        let finalUrl = fileUrl.isEmpty ? JSONLossless.string(d["videoUrl"] ?? d["fileUrl"] ?? d["url"]) : fileUrl
        return UploadedVideoResult(
            url: finalUrl,
            thumbUrl: thumbUrl,
            msgId: msgId.isEmpty ? cliId : msgId,
            cliMsgId: cliId,
            width: width,
            height: height,
            durationMs: durationMs
        )
    }
}
