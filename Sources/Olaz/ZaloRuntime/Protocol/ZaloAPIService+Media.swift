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
        imei: String
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
            imei: imei
        )
    }

    /// Builds the endpoint, query parameters, and encrypted payload for a video JPEG thumbnail upload.
    static func buildVideoThumbUploadSpec(
        convId: String,
        totalChunk: Int = 1,
        chunkId: Int = 1,
        totalSize: Int,
        clientId: Int64,
        imei: String
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
            imei: imei
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
        imei: String
    ) -> VideoUploadRequestSpec {
        let isGroup = ZaloWireParser.isGroupId(convId)
        let cleanId = isGroup ? ZaloWireParser.cleanGroupId(convId) : ZaloWireParser.stripUserPrefix(convId)
        var payload: [String: Any] = [
            "totalChunk": totalChunk,
            "fileName": fileName,
            "clientId": clientId,
            "totalSize": totalSize,
            "imei": imei,
            "isE2EE": 0,
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
