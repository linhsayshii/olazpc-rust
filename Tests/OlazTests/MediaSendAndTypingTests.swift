import AppKit
import AVFoundation
import CoreVideo
import CryptoKit
import Foundation
import os
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Olaz

private func makeTinyVideoClip(
    at url: URL,
    fileType: AVFileType,
    width: Int = 160,
    height: Int = 90,
    frameCount: Int = 6,
    fps: Int32 = 12
) async -> Bool {
    try? FileManager.default.removeItem(at: url)
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: fileType) else {
        return false
    }
    let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
    ]
    guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
        return false
    }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let attrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: attrs
    )
    guard writer.canAdd(input) else { return false }
    writer.add(input)
    guard writer.startWriting() else { return false }
    writer.startSession(atSourceTime: .zero)

    for frameIdx in 0..<frameCount {
        var waits = 0
        while !input.isReadyForMoreMediaData && waits < 200 {
            try? await Task.sleep(for: .milliseconds(5))
            waits += 1
        }
        guard input.isReadyForMoreMediaData else {
            writer.cancelWriting()
            return false
        }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            writer.cancelWriting()
            return false
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            memset(base, Int32(40 + frameIdx * 20), bytesPerRow * height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let pts = CMTime(value: CMTimeValue(frameIdx), timescale: fps)
        if !adaptor.append(buffer, withPresentationTime: pts) {
            writer.cancelWriting()
            return false
        }
    }

    input.markAsFinished()
    await writer.finishWriting()
    return writer.status == .completed && FileManager.default.fileExists(atPath: url.path)
}

@Suite struct MediaSendAndTypingTests {
    @Test func videoPayloadAndEndpointBuildersForOneOneAndGroup() throws {
        // 1-1 chunk upload spec
        let dmChunk = ZaloSessionClient.buildVideoChunkUploadSpec(
            convId: "123456789",
            fileName: "clip.mp4",
            totalChunk: 3,
            chunkId: 2,
            totalSize: 2_500_000,
            clientId: 777_001,
            imei: "IMEI-1"
        )
        #expect(dmChunk.service == "file")
        #expect(dmChunk.path == "/api/message/video/file/upload")
        #expect(dmChunk.queryParams == ["type": "2"])
        #expect(dmChunk.fieldName == "chunkContent")
        #expect(dmChunk.fileName == "clip.mp4")
        #expect(dmChunk.mimeType == "video/mp4")
        #expect(dmChunk.encryptedPayload["toid"] as? String == "123456789")
        #expect(dmChunk.encryptedPayload["grid"] == nil)
        #expect(dmChunk.encryptedPayload["totalChunk"] as? Int == 3)
        #expect(dmChunk.encryptedPayload["chunkId"] as? Int == 2)
        #expect(dmChunk.encryptedPayload["totalSize"] as? Int == 2_500_000)
        #expect(dmChunk.encryptedPayload["clientId"] as? Int64 == 777_001)
        #expect(dmChunk.encryptedPayload["imei"] as? String == "IMEI-1")
        #expect(dmChunk.encryptedPayload["isE2EE"] as? Int == 0)

        // Group chunk upload spec (`g...` and `group_...`)
        let grpChunk = ZaloSessionClient.buildVideoChunkUploadSpec(
            convId: "g998877",
            fileName: "demo.MOV",
            totalChunk: 1,
            chunkId: 1,
            totalSize: 512_000,
            clientId: 777_002,
            imei: "IMEI-1"
        )
        #expect(grpChunk.service == "file")
        #expect(grpChunk.path == "/api/group/video/file/upload")
        #expect(grpChunk.queryParams == ["type": "11"])
        #expect(grpChunk.fieldName == "chunkContent")
        #expect(grpChunk.mimeType == "video/quicktime")
        #expect(grpChunk.encryptedPayload["grid"] as? String == "998877")
        #expect(grpChunk.encryptedPayload["toid"] == nil)

        // Thumb upload specs (1-1 & group)
        let dmThumb = ZaloSessionClient.buildVideoThumbUploadSpec(
            convId: "123456789",
            totalSize: 12_345,
            clientId: 777_003,
            imei: "IMEI-1"
        )
        #expect(dmThumb.service == "file")
        #expect(dmThumb.path == "/api/message/video/thumb/upload")
        #expect(dmThumb.queryParams == ["type": "2"])
        #expect(dmThumb.fieldName == "chunkContent")
        #expect(dmThumb.fileName == "thumb.jpg")
        #expect(dmThumb.mimeType == "image/jpeg")
        #expect(dmThumb.encryptedPayload["toid"] as? String == "123456789")

        let grpThumb = ZaloSessionClient.buildVideoThumbUploadSpec(
            convId: "group_554433",
            totalSize: 12_345,
            clientId: 777_004,
            imei: "IMEI-1"
        )
        #expect(grpThumb.path == "/api/group/video/thumb/upload")
        #expect(grpThumb.queryParams == ["type": "11"])
        #expect(grpThumb.encryptedPayload["grid"] as? String == "554433")

        // Forward specs (1-1 & group)
        let dmForward = ZaloSessionClient.buildVideoForwardSpec(
            convId: "123456789",
            videoUrl: "https://cdn.example/v.mp4",
            thumbUrl: "https://cdn.example/t.jpg",
            durationMs: 4200,
            width: 1280,
            height: 720,
            fileSize: 987_654,
            clientId: 777_005,
            imei: "IMEI-1"
        )
        #expect(dmForward.service == "file")
        #expect(dmForward.path == "/api/message/forward")
        #expect(dmForward.encryptedPayload["msgType"] as? Int == 5)
        #expect(dmForward.encryptedPayload["ttl"] as? Int == 0)
        #expect(dmForward.encryptedPayload["clientId"] as? Int64 == 777_005)
        #expect(dmForward.encryptedPayload["toId"] as? String == "123456789")
        #expect(dmForward.encryptedPayload["grid"] == nil)
        #expect(dmForward.encryptedPayload["visibility"] == nil)
        let dmMsgInfoStr = try #require(dmForward.encryptedPayload["msgInfo"] as? String)
        let dmMsgInfo = try #require(JSONLossless.parseObject(Data(dmMsgInfoStr.utf8)))
        #expect(dmMsgInfo["videoUrl"] as? String == "https://cdn.example/v.mp4")
        #expect(dmMsgInfo["thumbUrl"] as? String == "https://cdn.example/t.jpg")
        #expect(JSONLossless.int64(dmMsgInfo["duration"]) == 4200)
        #expect(JSONLossless.int64(dmMsgInfo["width"]) == 1280)
        #expect(JSONLossless.int64(dmMsgInfo["height"]) == 720)
        #expect(JSONLossless.int64(dmMsgInfo["fileSize"]) == 987_654)
        #expect(dmMsgInfo["title"] as? String == "")

        let grpForward = ZaloSessionClient.buildVideoForwardSpec(
            convId: "g998877",
            videoUrl: "https://cdn.example/gv.mp4",
            thumbUrl: "https://cdn.example/gt.jpg",
            durationMs: 1500,
            width: 640,
            height: 480,
            fileSize: 100_000,
            clientId: 777_006,
            imei: "IMEI-1"
        )
        #expect(grpForward.service == "file")
        #expect(grpForward.path == "/api/group/forward")
        #expect(grpForward.encryptedPayload["grid"] as? String == "998877")
        #expect(grpForward.encryptedPayload["visibility"] as? Int == 0)
        #expect(grpForward.encryptedPayload["toId"] == nil)

        // asyncfile/msg fallback spec
        let asyncSpec = ZaloSessionClient.buildVideoAsyncFileMsgSpec(
            convId: "g998877",
            fileId: "445566",
            fileUrl: "https://cdn.example/gv.mp4",
            fileName: "clip.mp4",
            checksum: "deadbeef",
            totalSize: 100_000,
            clientId: 777_006,
            imei: "IMEI-1"
        )
        #expect(asyncSpec.service == "file")
        #expect(asyncSpec.path == "/api/group/asyncfile/msg")
        #expect(asyncSpec.encryptedPayload["fType"] as? Int == 2)
        #expect(asyncSpec.encryptedPayload["fileId"] as? Int64 == 445_566)
        #expect(asyncSpec.encryptedPayload["fileUrl"] as? String == "https://cdn.example/gv.mp4")
        #expect(asyncSpec.encryptedPayload["grid"] as? String == "998877")
    }

    @Test func uploadAndSendVideoMultiChunkHappyPathAndForwardFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-video-http-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let key = Data("0123456789abcdef".utf8)
        let shouldFailForward = OSAllocatedUnfairLock<Bool>(initialState: false)
        let captured = OSAllocatedUnfairLock<[(path: String, query: String, payload: ZaloJSONBox)]>(initialState: [])

        let server = try FakeZaloServer { req in
            let box = ZaloJSONBox(req.decodeEncryptedParams(key: key) ?? [:])
            captured.withLock { $0.append((path: req.path, query: req.query, payload: box)) }

            if req.path == "/api/message/video/file/upload" || req.path == "/api/group/video/file/upload" {
                let chunkId = JSONLossless.int64(box.dict["chunkId"]) ?? 1
                let totalChunk = JSONLossless.int64(box.dict["totalChunk"]) ?? 1
                if chunkId == totalChunk {
                    return .json(200, ["error_code": 0, "data": ["fileId": "901234", "fileUrl": "https://cdn.example/video_901234.mp4"]])
                }
                return .json(200, ["error_code": 0, "data": [:]])
            }
            if req.path == "/api/message/video/thumb/upload" || req.path == "/api/group/video/thumb/upload" {
                return .json(200, ["error_code": 0, "data": ["url": "https://cdn.example/thumb_901234.jpg"]])
            }
            if req.path == "/api/message/forward" || req.path == "/api/group/forward" {
                if shouldFailForward.withLock({ $0 }) {
                    return .json(200, ["error_code": 114, "error_message": "Forward unavailable"])
                }
                return .json(200, ["error_code": 0, "data": ["msgId": "55001122"]])
            }
            if req.path == "/api/message/asyncfile/msg" || req.path == "/api/group/asyncfile/msg" {
                return .json(200, ["error_code": 0, "data": ["msgId": "55009999"]])
            }
            return .json(404, ["error_code": -1])
        }
        try await server.start()
        defer { server.stop() }

        let client = ZaloSessionClient(dataDirectory: root, useKeychain: false)
        let domains = server.domains(for: ["file"])
        var account = ZaloLoginAccount()
        account.userId = "100"
        await client.updateCredentials(account: account, secretKey: key, zpwSek: "sek.1.2", domains: domains)

        // 1) 1-1 multi-chunk (>1MB) happy path
        let videoBytes = Data(repeating: 0x2A, count: (1024 * 1024) + 256)
        let thumbBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let dmRes = try await client.uploadAndSendVideo(
            convId: "222333",
            fileName: "sample.mp4",
            data: videoBytes,
            thumbnailData: thumbBytes,
            durationMs: 3250,
            width: 1920,
            height: 1080
        )
        #expect(dmRes.url == "https://cdn.example/video_901234.mp4")
        #expect(dmRes.thumbUrl == "https://cdn.example/thumb_901234.jpg")
        #expect(dmRes.msgId == "55001122")
        #expect(dmRes.width == 1920)
        #expect(dmRes.height == 1080)
        #expect(dmRes.durationMs == 3250)

        let dmCalls = captured.withLock { $0 }
        let videoChunks = dmCalls.filter { $0.path == "/api/message/video/file/upload" }
        #expect(videoChunks.count == 2)
        #expect(videoChunks[0].query.contains("type=2"))
        #expect(JSONLossless.int64(videoChunks[0].payload.dict["chunkId"]) == 1)
        #expect(JSONLossless.int64(videoChunks[1].payload.dict["chunkId"]) == 2)
        #expect(dmCalls.contains(where: { $0.path == "/api/message/video/thumb/upload" && $0.query.contains("type=2") }))
        let fwdCall = try #require(dmCalls.first(where: { $0.path == "/api/message/forward" }))
        #expect(JSONLossless.int64(fwdCall.payload.dict["msgType"]) == 5)
        #expect(JSONLossless.string(fwdCall.payload.dict["toId"]) == "222333")

        // 2) Group happy path (`type=11`, `grid`, `visibility=0`)
        captured.withLock { $0.removeAll() }
        let grpRes = try await client.uploadAndSendVideo(
            convId: "g888999",
            fileName: "group.mov",
            data: Data(repeating: 0x3B, count: 4096),
            thumbnailData: thumbBytes,
            durationMs: 1200,
            width: 720,
            height: 1280
        )
        #expect(grpRes.msgId == "55001122")
        let grpCalls = captured.withLock { $0 }
        #expect(grpCalls.contains(where: { $0.path == "/api/group/video/file/upload" && $0.query.contains("type=11") }))
        #expect(grpCalls.contains(where: { $0.path == "/api/group/video/thumb/upload" && $0.query.contains("type=11") }))
        let grpFwd = try #require(grpCalls.first(where: { $0.path == "/api/group/forward" }))
        #expect(JSONLossless.string(grpFwd.payload.dict["grid"]) == "888999")
        #expect(JSONLossless.int64(grpFwd.payload.dict["visibility"]) == 0)

        // 3) `/forward` failure falls back gracefully to `/asyncfile/msg`
        captured.withLock { $0.removeAll() }
        shouldFailForward.withLock { $0 = true }
        let smallVideo = Data(repeating: 0x4C, count: 2048)
        let expectedMD5 = Insecure.MD5.hash(data: smallVideo).map { String(format: "%02x", $0) }.joined()
        let fallbackRes = try await client.uploadAndSendVideo(
            convId: "222333",
            fileName: "fallback.mp4",
            data: smallVideo,
            thumbnailData: thumbBytes,
            durationMs: 2000,
            width: 640,
            height: 360
        )
        #expect(fallbackRes.msgId == "55009999")
        #expect(fallbackRes.url == "https://cdn.example/video_901234.mp4")
        let fbCalls = captured.withLock { $0 }
        #expect(fbCalls.contains(where: { $0.path == "/api/message/forward" }))
        let asyncCall = try #require(fbCalls.first(where: { $0.path == "/api/message/asyncfile/msg" }))
        #expect(JSONLossless.int64(asyncCall.payload.dict["fType"]) == 2)
        #expect(JSONLossless.string(asyncCall.payload.dict["checksum"]) == expectedMD5)
        #expect(JSONLossless.string(asyncCall.payload.dict["fileUrl"]) == "https://cdn.example/video_901234.mp4")
    }

    @Test func videoUTTypeDetectionMetadataExtractionAndOptimisticMessage() async throws {
        // UTType detection
        #expect(ZaloEngine.isVideoURL(URL(fileURLWithPath: "/tmp/clip.mp4")))
        #expect(ZaloEngine.isVideoURL(URL(fileURLWithPath: "/tmp/clip.MOV")))
        #expect(ZaloEngine.isVideoURL(URL(fileURLWithPath: "/tmp/clip.m4v")))
        #expect(ZaloEngine.isVideoUTType(.movie))
        #expect(ZaloEngine.isVideoUTType(.video))
        #expect(ZaloEngine.isVideoUTType(.mpeg4Movie))
        #expect(ZaloEngine.isVideoUTType(.quickTimeMovie))
        #expect(!ZaloEngine.isVideoURL(URL(fileURLWithPath: "/tmp/photo.png")))
        #expect(!ZaloEngine.isVideoURL(URL(fileURLWithPath: "/tmp/photo.jpg")))
        #expect(!ZaloEngine.isVideoURL(URL(fileURLWithPath: "/tmp/doc.pdf")))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-av-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Generate tiny real .mp4 and .mov clips via AVAssetWriter and verify duration, dimensions, and JPEG thumbnail
        let clipURL = dir.appendingPathComponent("tiny.mp4")
        let wroteClip = await makeTinyVideoClip(at: clipURL, fileType: .mp4, width: 160, height: 90, frameCount: 6, fps: 12)
        if wroteClip {
            let meta = await ZaloEngine.extractVideoMetadata(from: clipURL)
            #expect(meta.width == 160)
            #expect(meta.height == 90)
            #expect(meta.durationMs >= 300)
            #expect(meta.thumbnailData.starts(with: [0xFF, 0xD8, 0xFF]))
            #expect(NSImage(data: meta.thumbnailData) != nil)
        } else {
            // Fallback verification when headless encoder is unavailable
            let missingMeta = await ZaloEngine.extractVideoMetadata(from: dir.appendingPathComponent("missing.mp4"))
            #expect(missingMeta == VideoMetadata(durationMs: 0, width: 0, height: 0, thumbnailData: Data()))
        }

        let movURL = dir.appendingPathComponent("tiny.mov")
        let wroteMOV = await makeTinyVideoClip(at: movURL, fileType: .mov, width: 120, height: 120, frameCount: 6, fps: 12)
        if wroteMOV {
            let movMeta = await ZaloEngine.extractVideoMetadata(from: movURL)
            #expect(movMeta.width == 120)
            #expect(movMeta.height == 120)
            #expect(movMeta.durationMs >= 300)
            #expect(movMeta.thumbnailData.starts(with: [0xFF, 0xD8, 0xFF]))
        }

        // Non-video / corrupt file fails gracefully without crashing
        let corruptURL = dir.appendingPathComponent("broken.mp4")
        try Data("not a video".utf8).write(to: corruptURL)
        let corruptMeta = await ZaloEngine.extractVideoMetadata(from: corruptURL)
        #expect(corruptMeta.durationMs == 0)
        #expect(corruptMeta.thumbnailData.isEmpty)

        // Verify optimistic `.video(...)` recording + SQLite persistence on MainActor
        let engine = await MainActor.run { ZaloEngine(dataDirectory: dir, useKeychain: false) }
        let store = try ZaloSQLiteStore(path: dir.appendingPathComponent("history.sqlite3").path)
        await MainActor.run {
            engine.sqliteStore = store
        }
        await engine.recordUploadedMessage(
            convId: "333444",
            msgId: "srv_vid_1",
            cliId: "cli_vid_1",
            kind: .video(
                thumbnail: URL(string: "https://cdn.example/thumb.jpg"),
                duration: 4,
                url: URL(string: "https://cdn.example/vid.mp4")
            ),
            text: ""
        )
        let recorded = await MainActor.run { engine.messages["333444"]?.first }
        #expect(recorded?.id == "srv_vid_1")
        #expect(recorded?.kind == .video(
            thumbnail: URL(string: "https://cdn.example/thumb.jpg"),
            duration: 4,
            url: URL(string: "https://cdn.example/vid.mp4")
        ))
        let preview = await MainActor.run { engine.conversations.first(where: { $0.id == "333444" })?.preview?.text }
        #expect(preview == "[Video]")
        let persisted = try await store.message(convId: "333444", idOrClientId: "srv_vid_1")
        #expect(persisted?.kindTag == "video")
    }

    @MainActor
    @Test func outgoingTypingThrottleBehaviorAndEditGuards() {
        let throttle = OutgoingTypingThrottle(interval: 3.5)
        let t0 = Date(timeIntervalSince1970: 10_000)

        // Empty / whitespace conversation IDs never send
        #expect(!throttle.shouldSend(in: "", now: t0))
        #expect(!throttle.shouldSend(in: "   ", now: t0))

        // First edit sends; edits within 3.5s are throttled; >= 3.5s sends again
        #expect(throttle.shouldSend(in: "convA", now: t0))
        #expect(!throttle.shouldSend(in: "convA", now: t0.addingTimeInterval(0.5)))
        #expect(!throttle.shouldSend(in: "convA", now: t0.addingTimeInterval(3.49)))
        #expect(throttle.shouldSend(in: "convA", now: t0.addingTimeInterval(3.5)))
        #expect(!throttle.shouldSend(in: "convA", now: t0.addingTimeInterval(4.0)))

        // Other conversations remain independent
        #expect(throttle.shouldSend(in: "convB", now: t0.addingTimeInterval(0.5)))

        // Reset (e.g. when draft becomes empty or message is sent) lets the next edit send immediately
        throttle.reset(in: "convA")
        #expect(throttle.lastSentDate(for: "convA") == nil)
        #expect(throttle.shouldSend(in: "convA", now: t0.addingTimeInterval(4.1)))

        // Engine gating: unauthenticated / non-ready or empty convId skips cleanly
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("olaz-typing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = ZaloEngine(dataDirectory: dir, useKeychain: false)
        #expect(engine.phase == .starting)
        engine.notifyTyping(in: "")
        engine.notifyTyping(in: "123456")
        engine.resetOutgoingTyping(in: "")
        engine.resetOutgoingTyping(in: "123456")

        // ComposerTextView edit callback fires ONLY on real user edits (`textDidChange`), NOT on `setContent` or deferred `pending` replay
        var textStorage = "initial"
        var mentionsStorage: [Mention] = []
        var heightStorage: CGFloat = 20
        var recordedEdits: [String] = []

        let view = ComposerTextView(
            text: Binding(get: { textStorage }, set: { textStorage = $0 }),
            mentions: Binding(get: { mentionsStorage }, set: { mentionsStorage = $0 }),
            height: Binding(get: { heightStorage }, set: { heightStorage = $0 }),
            focusTick: 0,
            onUserTextEdit: { recordedEdits.append($0) },
            onSend: {}
        )
        let coordinator = view.makeCoordinator()
        let tv = NSTextView()

        // 1) Programmatic draft restore / conversation switch / clear via `setContent` must NOT fire `onUserTextEdit`
        ComposerTextView.setContent(tv, text: "restored draft", mentions: [])
        #expect(recordedEdits.isEmpty)
        ComposerTextView.setContent(tv, text: "", mentions: [])
        #expect(recordedEdits.isEmpty)

        // 2) Deferred external draft (`pending != nil`) in `textDidChange` must NOT fire `onUserTextEdit`
        coordinator.deferExternal(base: "a", text: "a restored", mentions: [])
        tv.string = "a"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: tv))
        #expect(recordedEdits.isEmpty)

        // 3) Real user edit in `textDidChange` fires `onUserTextEdit`
        tv.string = "xin chao"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: tv))
        #expect(recordedEdits == ["xin chao"])

        // 4) Deleting to empty fires `onUserTextEdit` with `""` (which ChatComposer turns into `resetOutgoingTyping`, not `notifyTyping`)
        tv.string = ""
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: tv))
        #expect(recordedEdits == ["xin chao", ""])
    }

    @MainActor
    @Test("sendFiles detects persisted e2eeThreadsV1 on cold start before start()")
    func sendFilesDetectsPersistedE2EEOnColdStartBeforeStart() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("olaz-cold-e2ee-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Persist native-session.json + accounts/<uid>/history.sqlite3 with e2eeThreadsV1, without calling start().
        let uid = "2009901"
        let peerId = "3009901"
        let sessionObj: [String: Any] = [
            "plainAccount": [
                "userId": uid,
                "displayName": "Cold User",
            ]
        ]
        let sessionData = try JSONSerialization.data(withJSONObject: sessionObj)
        try sessionData.write(to: dir.appendingPathComponent("native-session.json"))

        let dbURL = dir
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(uid, isDirectory: true)
            .appendingPathComponent("history.sqlite3")
        let seedStore = try ZaloSQLiteStore(path: dbURL.path)
        try await seedStore.setPreferenceStrings(key: "e2eeThreadsV1", value: [peerId])

        let fileURL = dir.appendingPathComponent("cold.pdf")
        try Data("hello e2ee".utf8).write(to: fileURL)

        let engine = ZaloEngine(dataDirectory: dir, useKeychain: false)
        var observedIsE2EE: Bool?
        engine.uploadFileHostHandler = { args in
            observedIsE2EE = args["is_e2ee"] as? Bool
            return UploadedMediaResult(
                url: "https://cdn.example.invalid/cold.pdf?e2esession=abc",
                msgId: "99001",
                cliMsgId: (args["client_id"] as? String) ?? "1",
                width: 0,
                height: 0
            )
        }

        let outcome = await engine.sendFiles([fileURL], to: peerId)
        #expect(outcome == .done)
        #expect(observedIsE2EE == true)
        let msg = engine.messages[peerId]?.first(where: { $0.id == "99001" })
        #expect(msg?.isE2EE == true)

        engine.stopCoreEngine()
    }
}
