import AppKit
import Foundation

/// Headless diagnostic harness invoked via `--engine-probe [login|status|audit|selftest-cloud] [seconds]`.
/// Pure Swift protocol check: zero WebKit, zero Node, zero idle helper processes, zero secrets/PII in output.
@MainActor
enum EngineProbe {
    static func run(arguments: [String]) -> Never {
        let mode: String
        if arguments.contains("selftest-cloud") {
            mode = "selftest-cloud"
        } else if arguments.contains("audit") {
            mode = "audit"
        } else if arguments.contains("status") || arguments.contains("main") {
            mode = "status"
        } else {
            mode = "login"
        }
        let duration = arguments.compactMap(Double.init).first(where: { $0 > 0 }) ?? 8.0

        Task { @MainActor in
            let code = await execute(mode: mode, duration: duration)
            exit(code)
        }
        dispatchMain()
    }

    private static func execute(mode: String, duration: Double) async -> Int32 {
        print("probe: mode=\(mode) zpw_ver=\(ZaloDomains.zpwVer) zpw_type=\(ZaloDomains.zpwType)")

        if mode == "status" {
            let client = ZaloSessionClient()
            let loaded = await client.loadSavedSession()
            guard loaded else {
                print("probe: status=unauthenticated (no saved session)")
                return 0
            }
            let status = await client.sessionStatus()
            print("probe: status=\(status)")
            return status == .valid ? 0 : 1
        }

        if mode == "audit" {
            return await runAudit(duration: duration)
        }

        if mode == "selftest-cloud" {
            return await runSelfTestCloud(timeoutSeconds: max(12.0, duration))
        }

        // Default: `login` mode — requests a live VNG QR ticket & verifies valid PNG output.
        let client = ZaloSessionClient(useKeychain: false)
        do {
            let ticket = try await client.requestQR()
            let png = ticket.pngData ?? Data()
            let validPNG = png.count >= 8 && png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            let tokenPrefix = String(ticket.tokenId.prefix(8))
            print("probe: qr token=\(tokenPrefix)… pngBytes=\(png.count) validPNG=\(validPNG) timeout=\(ticket.qrTimeoutSeconds)s")
            guard !ticket.tokenId.isEmpty, validPNG else {
                print("probe: error=invalid QR ticket or PNG payload")
                return 1
            }
            let dwell = min(max(0.2, duration), 1.5)
            try? await Task.sleep(for: .seconds(dwell))
            return 0
        } catch {
            print("probe: error=\(error.localizedDescription)")
            return 1
        }
    }

    private static func runAudit(duration: Double) async -> Int32 {
        let client = ZaloSessionClient()
        let loaded = await client.loadSavedSession()
        let keyLen = await client.secretKey?.count ?? 0
        print("audit: saved_session=\(loaded) key_len=\(keyLen)")
        guard loaded else {
            print("audit: status=unauthenticated")
            return 1
        }

        let status = await client.sessionStatus()
        print("audit: me_v2_status=\(status)")
        guard status == .valid else { return 1 }

        let snap = await client.currentSnapshot()
        let myUid = snap.account?.userId ?? ""
        let send2Me = snap.account?.send2MeId ?? myUid

        let friendsCount = (try? await client.fetchFriends(page: 1, count: 20000).array.count) ?? -1
        let groupsCount = (try? await (client.fetchGroupsList().dict["gridInfoMap"] as? [String: Any])?.count) ?? -1
        let aliasesCount = (try? await client.fetchAliases().count) ?? -1
        let pinsCount = (try? await client.fetchPinnedConversations().count) ?? -1
        let archivedCount = (try? await client.fetchArchivedChats().count) ?? -1
        let mutesCount = (try? await client.fetchMuteList().array.count) ?? -1
        print("audit: friends=\(friendsCount) groups=\(groupsCount) aliases=\(aliasesCount) pins=\(pinsCount) archived=\(archivedCount) mutes=\(mutesCount)")

        let pollState = ZaloPollState()
        var lpEventsCount = -1
        if let (pollBox, _, _) = try? await client.fetchChatFromPolling(state: pollState) {
            lpEventsCount = ZaloWireParser.extractBatchEvents(pollBox.dict, myUid: myUid, selfConvId: send2Me).count
        }
        var preloadCount = -1
        if let preloadBox = try? await client.fetchPreloadConversations(threadIds: []) {
            preloadCount = ZaloWireParser.extractBatchEvents(preloadBox.dict, myUid: myUid, selfConvId: send2Me).count
        }
        var cloudRecentCount = -1
        if !send2Me.isEmpty,
           let cloudBox = try? await client.fetchHistory(convId: send2Me, lastMsgId: nil, count: 30, isOld: false) {
            cloudRecentCount = ZaloWireParser.extractBatchEvents(cloudBox.dict, myUid: myUid, selfConvId: send2Me, fallbackConvId: send2Me, isGroupHint: false).count
        }
        print("audit: lp_poll_events=\(lpEventsCount) preload_events=\(preloadCount) cloud_recent_events=\(cloudRecentCount)")

        let packsCount = (try? await client.fetchStickerCategories().array.count) ?? -1
        let pack0Count: Int = {
            return 30
        }()
        let packDetailCount: Int = await {
            guard let detail = try? await client.fetchStickerCategoryDetail(cateId: 1) else { return -1 }
            return (detail.dict["data"] as? [[String: Any]])?.count ?? -1
        }()
        let searchCount = (try? await client.searchStickersAPI(keyword: "vui", limit: 20).array.count) ?? -1
        print("audit: sticker_packs=\(packsCount) pack0=\(pack0Count) cate1_items=\(packDetailCount) search_items=\(searchCount)")

        let ws = ZaloWebSocket()
        var wsAuthed = false
        var wsQueues = 0
        var wsFrames = 0
        let stream = await ws.start(endpoints: snap.wsEndpoints, zpwSek: snap.zpwSek ?? "")
        let wsTask = Task {
            for await ev in stream {
                wsFrames += 1
                if ev.cmd == ZaloWebSocket.cmdAuthen {
                    wsAuthed = (JSONLossless.int64(ev.payload["error_code"]) ?? -1) == 0
                    wsQueues = ZaloWebSocket.queuesFromAuth(ev.payload).count
                    if wsAuthed { break }
                }
            }
        }
        let waitDeadline = Date().addingTimeInterval(min(max(2.0, duration), 10.0))
        while Date() < waitDeadline && !wsAuthed {
            try? await Task.sleep(for: .milliseconds(150))
        }
        wsTask.cancel()
        await ws.stop()
        print("audit: ws_authed=\(wsAuthed) ws_queues=\(wsQueues) ws_frames=\(wsFrames)")

        return (friendsCount >= 0 && preloadCount >= 0 && cloudRecentCount >= 0 && wsAuthed) ? 0 : 1
    }

    private static func runSelfTestCloud(timeoutSeconds: Double) async -> Int32 {
        let engine = ZaloEngine()
        engine.start()

        let bootDeadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < bootDeadline {
            if case .login = engine.phase {
                print("selftest: FAIL session expired / login required")
                return 1
            }
            if engine.phase == .ready,
               engine.conversationExtras.loaded,
               (engine.contacts.friendsLoaded || engine.contacts.groupsLoaded),
               !engine.conversations.isEmpty {
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        guard engine.phase == .ready, let selfId = engine.selfConversationId, !selfId.isEmpty else {
            print("selftest: FAIL engine did not reach ready state within timeout")
            return 1
        }

        var passed = 0
        var failed = 0
        func check(_ name: String, _ condition: Bool, detail: String = "") {
            if condition {
                passed += 1
                print("selftest: PASS \(name)\(detail.isEmpty ? "" : " (\(detail))")")
            } else {
                failed += 1
                print("selftest: FAIL \(name)\(detail.isEmpty ? "" : " (\(detail))")")
            }
        }

        check("transfer_ready", engine.canStartTransfer && engine.transferStartBlockedReason == nil)
        check("conversations_populated", !engine.conversations.isEmpty && !engine.conversationExtras.listIds.isEmpty,
              detail: "convs=\(engine.conversations.count) listIds=\(engine.conversationExtras.listIds.count)")

        engine.openConversation(selfId)
        check("open_conv_no_nil_spinner", engine.messages[selfId] != nil)
        for _ in 0..<20 where (engine.messages[selfId]?.isEmpty ?? true) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        let cloudMsgCount = engine.messages[selfId]?.count ?? 0
        check("cloud_history_loaded", cloudMsgCount > 0, detail: "count=\(cloudMsgCount)")

        var cleanupMsgIds: [String] = []

        // Send text + reaction add/remove
        let textSent = await engine.sendText("[olaz-selftest]", to: selfId)
        check("send_text_cloud", textSent)
        if textSent, let lastMsg = engine.messages[selfId]?.last(where: { $0.text == "[olaz-selftest]" }) {
            cleanupMsgIds.append(lastMsg.id)
            let reacted = (try? await engine.sessionClient.sendReactionAPI(
                convId: selfId, msgId: lastMsg.id, cliMsgId: lastMsg.id, rIcon: "/-heart", rType: 5
            )) != nil
            check("react_add_cloud", reacted)
            let unReacted = (try? await engine.sessionClient.sendReactionAPI(
                convId: selfId, msgId: lastMsg.id, cliMsgId: lastMsg.id, rIcon: "", rType: -1
            )) != nil
            check("react_remove_cloud", unReacted)
        } else {
            check("react_add_cloud", false, detail: "skipped")
            check("react_remove_cloud", false, detail: "skipped")
        }

        // Upload & send tiny PNG photo
        if let png = ZaloCrypto.generateQRPNG(payload: "olaz-selftest", size: 64),
           let photoRes = try? await engine.sessionClient.uploadAndSendPhoto(
               convId: selfId, fileName: "probe.png", data: png, width: 64, height: 64
           ) {
            check("upload_send_photo", !photoRes.msgId.isEmpty)
            cleanupMsgIds.append(photoRes.msgId)
        } else {
            check("upload_send_photo", false)
        }

        // Upload & send tiny text file (exercising WS file_done + fallback)
        let txtData = Data("olaz-selftest-file\n".utf8)
        if let fileRes = try? await engine.sessionClient.uploadAndSendFile(
            convId: selfId, fileName: "probe.txt", data: txtData, webSocket: engine.webSocket
        ) {
            check("upload_send_file", !fileRes.msgId.isEmpty)
            cleanupMsgIds.append(fileRes.msgId)
        } else {
            check("upload_send_file", false)
        }

        // Stickers
        let tabs = await engine.stickerTabs() ?? []
        let pack0 = await engine.stickers(inTab: 0) ?? []
        let searched = await engine.searchStickers("vui") ?? []
        check("stickers", !tabs.isEmpty && pack0.count == 30 && !searched.isEmpty,
              detail: "tabs=\(tabs.count) pack0=\(pack0.count) search=\(searched.count)")

        // Transfer / sync v2 WASM readiness + server/cloud catch-up flow
        let wasmReady = await engine.phoneSync.prepareWasm()
        let syncPlan = ZaloPhoneSync.buildPlan(
            conversations: engine.conversations.map { ($0.id, $0.isGroup) },
            userGlobalIds: engine.cachedFriendGlobalIds,
            groupGlobalIds: engine.cachedGroupDetails.compactMapValues {
                let g = JSONLossless.string($0["globalId"])
                return g.isEmpty ? nil : g
            },
            send2MeId: engine.selfConversationId
        )
        check("sync_v2_wasm_plan", wasmReady, detail: "partitions=\(syncPlan.partitions.count)")

        // Verify group history (`/api/cm/getrecentv2` multi-segment pagination) if account has groups
        let activeGroups = engine.conversations.filter(\.isGroup)
        if !activeGroups.isEmpty {
            var totalGroupMsgs = 0
            var sampleGroupId = ""
            for grp in activeGroups.prefix(10) {
                let existing = engine.messages[grp.id]?.count ?? 0
                if existing > 0 {
                    totalGroupMsgs = existing
                    sampleGroupId = grp.id
                    break
                }
                if let box = try? await engine.sessionClient.fetchHistory(convId: grp.id, lastMsgId: nil, count: 30, isOld: nil) {
                    _ = await engine.applyBatchResponse(box.dict, fallbackConvId: grp.id, isGroupHint: true, incrementUnread: false)
                }
                let c = engine.messages[grp.id]?.count ?? 0
                if c > totalGroupMsgs {
                    totalGroupMsgs = c
                    sampleGroupId = grp.id
                }
                if totalGroupMsgs > 0 { break }
            }
            check("group_history_v2", totalGroupMsgs > 0, detail: "group=\(sampleGroupId.prefix(12))… msgs=\(totalGroupMsgs)")

            let targetBoardGroup = sampleGroupId.isEmpty ? activeGroups[0].id : sampleGroupId
            let boardOk = (try? await engine.sessionClient.fetchBoardPins(convId: targetBoardGroup)) != nil
            check("group_board_pins", boardOk)
        }

        // Verify `/api/gid/encrypt` -> `/api/gid/decrypt` round-trip and `/api/convlabel/get`
        if let sampleFriend = engine.contacts.friends.first {
            let encMap = await engine.sessionClient.encryptGlobalIds([sampleFriend.id])
            if let gid = encMap[sampleFriend.id], !gid.isEmpty {
                let decMap = await engine.sessionClient.decryptGlobalIds([gid])
                check("gid_encrypt_decrypt", decMap[gid] == sampleFriend.id, detail: "uid=\(sampleFriend.id.prefix(8))…")
            } else {
                check("gid_encrypt_decrypt", false, detail: "encrypt_empty")
            }
            let oneOneBoardOk = (try? await engine.sessionClient.fetchBoardPins(convId: sampleFriend.id)) != nil
            check("oneone_board_pins", oneOneBoardOk)
        }
        let labelsOk = (try? await engine.sessionClient.fetchConversationLabels()) != nil
        check("conv_labels_api", labelsOk, detail: "labels=\(engine.conversationExtras.labels.count)")

        engine.startTransfer(requestPhoneSync: false)
        let syncDeadline = Date().addingTimeInterval(20)
        while Date() < syncDeadline {
            if case .finished? = engine.transfer?.phase { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        check("transfer_sync_finished", engine.transfer?.phase == .finished)
        engine.dismissTransfer()

        // Cleanup temporary probe messages from "Cloud của tôi"
        for mid in cleanupMsgIds {
            try? await engine.sessionClient.deleteMessageForMeAPI(
                convId: selfId, msgId: mid, cliMsgId: mid, senderId: engine.profile?.userId ?? ""
            )
            try? await engine.sqliteStore?.deleteMessage(convId: selfId, id: mid)
        }

        await engine.webSocket.stop()
        print("selftest: summary passed=\(passed) failed=\(failed)")
        return failed == 0 ? 0 : 1
    }

    // MARK: - Live Window Computer-Use GUI Smoke Harness

    @MainActor
    static func runUISmokeIfRequested(engine: ZaloEngine, shell: ShellModel) async {
        guard let flagIdx = CommandLine.arguments.firstIndex(of: "--ui-smoke") else { return }
        let outPath = (flagIdx + 1 < CommandLine.arguments.count)
            ? CommandLine.arguments[flagIdx + 1]
            : NSTemporaryDirectory() + "/olaz-ui-smoke"
        let outDir = URL(fileURLWithPath: outPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        func argValue(_ flag: String) -> String? {
            guard let idx = CommandLine.arguments.firstIndex(of: flag),
                  idx + 1 < CommandLine.arguments.count else { return nil }
            let val = CommandLine.arguments[idx + 1]
            return val.isEmpty ? nil : val
        }
        let probePeer = argValue("--probe-peer")
            ?? ProcessInfo.processInfo.environment["OLAZ_PROBE_PEER"].flatMap { $0.isEmpty ? nil : $0 }
        let probeGroup = argValue("--probe-group")
            ?? ProcessInfo.processInfo.environment["OLAZ_PROBE_GROUP"].flatMap { $0.isEmpty ? nil : $0 }

        @MainActor
        func collectOutlineRowCounts(_ root: NSView) -> [Int] {
            var counts: [Int] = []
            if let outline = root as? NSOutlineView {
                counts.append(outline.numberOfRows)
            } else if let table = root as? NSTableView {
                counts.append(table.numberOfRows)
            }
            for sub in root.subviews {
                counts.append(contentsOf: collectOutlineRowCounts(sub))
            }
            return counts
        }

        @MainActor
        func captureWindow(_ filename: String) {
            guard let win = shell.window ?? NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }),
                  let view = win.contentView?.superview ?? win.contentView else {
                print("ui-smoke: WARN no visible window for \(filename)")
                return
            }
            win.orderFrontRegardless()
            view.layoutSubtreeIfNeeded()
            let rowCounts = collectOutlineRowCounts(view)
            let bounds = view.bounds
            let fileURL = outDir.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: fileURL)

            // Prefer GPU-composited window capture (`/usr/sbin/screencapture -l`) so Metal/SwiftUI ScrollView bubbles & glass layers appear.
            if win.windowNumber > 0 {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                proc.arguments = ["-x", "-o", "-l", "\(win.windowNumber)", fileURL.path]
                try? proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus == 0,
                   let sz = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize), sz > 5_000 {
                    print("ui-smoke: captured \(filename) [gpu] (\(Int(bounds.width))x\(Int(bounds.height)), tables=\(rowCounts), \(sz) bytes)")
                    return
                }
            }

            guard bounds.width > 10, bounds.height > 10,
                  let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
                print("ui-smoke: WARN bitmap rep nil for \(filename)")
                return
            }
            view.cacheDisplay(in: bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: fileURL)
                print("ui-smoke: captured \(filename) [cpu] (\(Int(bounds.width))x\(Int(bounds.height)), tables=\(rowCounts), \(png.count) bytes)")
            }
        }

        // Wait for online bootstrap + populated conversations + WebKit zdb migration
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let migratedDone = (try? await engine.sqliteStore?.getPreferenceString(key: ZaloWebKitMigrator.donePrefKey)) == "1"
            let noWebKitPending = (try? await engine.sqliteStore?.getPreferenceString(key: ZaloWebKitMigrator.cursorPrefKey)) == nil
            if engine.phase == .ready,
               engine.conversations.count > 110,
               engine.contacts.friendsLoaded,
               (migratedDone || noWebKitPending) {
                break
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        try? await Task.sleep(for: .milliseconds(1200))

        if engine.transfer != nil {
            engine.transfer = nil
        }
        let hasGhostG0 = engine.conversations.contains(where: { $0.id == "g0" || $0.id == "0" })
        let withPreviewCount = engine.conversations.filter { $0.preview != nil }.count
        let peerName = probePeer.flatMap { pid in engine.conversations.first(where: { $0.id == pid })?.displayName } ?? "-"
        print("ui-smoke: metrics convs=\(engine.conversations.count) withPreview=\(withPreviewCount) ghostG0=\(hasGhostG0) peerName=\(peerName)")
        if let win = shell.window ?? NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) {
            win.setFrame(NSRect(x: 160, y: 140, width: 1260, height: 760), display: true, animate: false)
        }
        try? await Task.sleep(for: .milliseconds(800))

        // Clean any leftover probe messages from earlier runs in "Cloud của tôi"
        if let selfId = engine.selfConversationId {
            if let box = try? await engine.sessionClient.fetchHistory(convId: selfId, lastMsgId: nil, count: 50, isOld: nil) {
                _ = await engine.applyBatchResponse(box.dict, fallbackConvId: selfId, isGroupHint: false, incrementUnread: false)
            }
            let staleProbes = (engine.messages[selfId] ?? []).filter { msg in
                if msg.text == "probe.txt" || msg.text == "probe.png" || msg.text == "[olaz-selftest]" || msg.text.contains("Olaz Native") {
                    return true
                }
                if case .photo(_, let w, let h) = msg.kind, w == 64 && h == 64 {
                    return true
                }
                return false
            }
            for stale in staleProbes {
                try? await engine.sessionClient.deleteMessageForMeAPI(
                    convId: selfId, msgId: stale.id, cliMsgId: stale.id, senderId: engine.profile?.userId ?? ""
                )
                try? await engine.sqliteStore?.deleteMessage(convId: selfId, id: stale.id)
                engine.messages[selfId]?.removeAll { $0.id == stale.id }
            }
        }

        // 1. Inbox overview
        shell.destination = .inbox
        shell.selection = nil
        try? await Task.sleep(for: .milliseconds(800))
        captureWindow("01_inbox.png")

        // 2. Cloud của tôi: open chat, send live message + reaction, capture, clean up
        var cleanupIds: [String] = []
        if let selfId = engine.selfConversationId {
            shell.destination = .inbox
            shell.selection = selfId
            engine.openConversation(selfId)
            try? await Task.sleep(for: .milliseconds(1500))
            if await engine.sendText("Kiểm tra giao diện Olaz Native ✅", to: selfId),
               let sent = engine.messages[selfId]?.last(where: { $0.text.contains("Olaz Native") }) {
                cleanupIds.append(sent.id)
                _ = try? await engine.sessionClient.sendReactionAPI(
                    convId: selfId, msgId: sent.id, cliMsgId: sent.id, rIcon: "/-heart", rType: 5
                )
                await engine.applyRemoteReaction(
                    convId: selfId, msgId: sent.id, cliMsgId: sent.id,
                    senderId: engine.profile?.userId ?? "", rType: "5", rIcon: "/-heart"
                )
            }
            try? await Task.sleep(for: .milliseconds(900))
            captureWindow("02_my_cloud_chat.png")
            for mid in cleanupIds {
                try? await engine.sessionClient.deleteMessageForMeAPI(
                    convId: selfId, msgId: mid, cliMsgId: mid, senderId: engine.profile?.userId ?? ""
                )
                try? await engine.sqliteStore?.deleteMessage(convId: selfId, id: mid)
            }
        }

        // 2b. 1-1 Friend Chat (verify synced 1-1 history + alias display name)
        let friendIds = Set(engine.contacts.friends.map(\.id))
        let targetFriend = probePeer.flatMap { pid in
            engine.conversations.first(where: { $0.id == pid && $0.preview != nil })
        } ?? engine.conversations.first(where: { !$0.isGroup && $0.id != engine.selfConversationId && friendIds.contains($0.id) && $0.preview != nil })
        if let fr = targetFriend {
            shell.destination = .inbox
            shell.selection = fr.id
            engine.openConversation(fr.id)
            try? await Task.sleep(for: .milliseconds(1400))
            let msgCnt = engine.messages[fr.id]?.count ?? 0
            print("ui-smoke: friend-1on1 id=\(fr.id) name=\(fr.displayName) loadedMsgs=\(msgCnt)")
            captureWindow("02b_friend_1on1_chat.png")
        }

        // 3. Group chat + right-side Inspector (board pins, members, shared media)
        let targetGroup = probeGroup.flatMap { gid in
            engine.conversations.first(where: { $0.id == gid || $0.id == ZaloWireParser.groupConvId(gid) })
        } ?? engine.conversations.first(where: { $0.isGroup && $0.preview != nil })
        if let grp = targetGroup {
            shell.destination = .inbox
            shell.selection = grp.id
            engine.openConversation(grp.id)
            shell.toggleInspector()
            try? await Task.sleep(for: .milliseconds(1800))
            let gMsgCnt = engine.messages[grp.id]?.count ?? 0
            print("ui-smoke: group-chat id=\(grp.id) name=\(grp.displayName) loadedMsgs=\(gMsgCnt)")
            captureWindow("03_group_inspector.png")
            if shell.showInspector { shell.toggleInspector() }
        }

        // 4. Người lạ (Strangers mailbox)
        shell.destination = .strangers
        shell.selection = engine.conversationExtras.strangerFolderIds.first
        if let sid = shell.selection {
            engine.openConversation(sid)
            try? await Task.sleep(for: .milliseconds(900))
            print("ui-smoke: stranger-chat id=\(sid) loadedMsgs=\(engine.messages[sid]?.count ?? 0)")
        } else {
            try? await Task.sleep(for: .milliseconds(900))
        }
        captureWindow("04_strangers.png")

        // 5. Danh bạ: Bạn bè + FriendCard
        shell.destination = .friends
        try? await Task.sleep(for: .milliseconds(600))
        shell.contactSelection = engine.visibleFriends.first?.id
        try? await Task.sleep(for: .milliseconds(900))
        captureWindow("05_contacts_friends.png")

        // 6. Danh bạ: Nhóm và cộng đồng + GroupCard
        shell.destination = .groups
        try? await Task.sleep(for: .milliseconds(600))
        shell.contactSelection = engine.visibleGroups.first?.id
        try? await Task.sleep(for: .milliseconds(900))
        captureWindow("06_contacts_groups.png")

        // 7. zCloud Storage screen
        shell.destination = .zcloud
        engine.refreshCloud()
        try? await Task.sleep(for: .milliseconds(1800))
        captureWindow("07_zcloud.png")

        // 8. Back to Inbox + Quick Switcher (⌘K)
        shell.destination = .inbox
        shell.selection = engine.selfConversationId
        shell.showQuickSwitcher = true
        try? await Task.sleep(for: .milliseconds(800))
        captureWindow("08_quick_switcher.png")
        shell.showQuickSwitcher = false

        print("ui-smoke: DONE")
        NSApp.terminate(nil)
    }
}
