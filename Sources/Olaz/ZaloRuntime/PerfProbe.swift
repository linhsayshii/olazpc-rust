import AppKit
import QuartzCore
import os

/// Signposts for Instruments (subsystem `app.olaz.mac`, category `perf`): chat open (selection → first frame) and scrolling.
enum PerfSignposts {
    static let signposter = OSSignposter(subsystem: "app.olaz.mac", category: .pointsOfInterest)
}

/// `--perf-probe <outdir>`: a scripted, repeatable measurement of the chat UI on the live session.
/// (a) opens conversations one after another and times selection → first presented frame with the chat on screen;
/// (b) scrolls the longest loaded chat at a steady speed and records every frame interval (hitches).
/// Results go to stdout and `<outdir>/perf.txt`; the app quits when done.
@MainActor
enum PerfProbe {
    /// Set by `MessageList.onAppear`: the chat list for this conversation is in the hierarchy.
    static var appearedChat: String? {
        didSet { if appearedChat != nil { PerfSignposts.signposter.emitEvent("chat-appeared") } }
    }

    private final class FrameClock: NSObject {
        var stamps: [CFTimeInterval] = []
        var onFrame: ((CADisplayLink) -> Void)?
        @objc func tick(_ link: CADisplayLink) {
            stamps.append(CACurrentMediaTime())
            onFrame?(link)
        }
    }

    static func runIfRequested(engine: ZaloEngine, shell: ShellModel) async {
        guard let flagIdx = CommandLine.arguments.firstIndex(of: "--perf-probe") else { return }
        let outPath = flagIdx + 1 < CommandLine.arguments.count ? CommandLine.arguments[flagIdx + 1] : NSTemporaryDirectory() + "olaz-perf"
        try? FileManager.default.createDirectory(atPath: outPath, withIntermediateDirectories: true)
        var report: [String] = []
        // Keep the run on performance cores: an occluded window lets App Nap move the main thread to efficiency cores, which
        // multiplies every number by ~5 and has nothing to do with the code under test.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "perf probe")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        func log(_ s: String) { print("perf: " + s); report.append(s) }

        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !(engine.phase == .ready && engine.conversations.count > 20 && engine.conversationActions.hiddenKnown) {
            try? await Task.sleep(for: .milliseconds(300))
        }
        try? await Task.sleep(for: .seconds(3))
        guard let win = shell.window ?? NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }),
              let root = win.contentView else { log("no window"); return }
        win.setFrame(NSRect(x: 120, y: 100, width: 1260, height: 820), display: true)
        shell.destination = .inbox
        shell.selection = nil
        if experiment.contains("noinspector") { shell.hideInspector() }
        try? await Task.sleep(for: .seconds(1))
        log("inspector=\(shell.showInspector) convs=\(engine.conversations.count)")

        let clock = FrameClock()
        let link = root.displayLink(target: clock, selector: #selector(FrameClock.tick(_:)))
        link.add(to: .main, forMode: .common)
        defer { link.invalidate() }

        active = true
        // OLAZ_PERF_APP=active|inactive: run with Olaz frontmost, or behind another app (Finder).
        switch ProcessInfo.processInfo.environment["OLAZ_PERF_APP"] {
        case "active": NSApp.activate(ignoringOtherApps: true); win.makeKeyAndOrderFront(nil)
        case "inactive":
            NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }?.activate()
        default: break
        }
        try? await Task.sleep(for: .seconds(1))
        log("app active=\(NSApp.isActive) key=\(win.isKeyWindow)")
        watch(engine, shell)
        try? await Task.sleep(for: .seconds(2))
        log("idle-2s mutations: " + takeCounts())
        // OLAZ_PERF_INSPECTOR: only time the inspector's open / close (frame intervals over each transition), then quit.
        if ProcessInfo.processInfo.environment["OLAZ_PERF_INSPECTOR"] != nil {
            await inspectorToggles(engine: engine, shell: shell, clock: clock, link: link, log: log)
            try? report.joined(separator: "\n").write(toFile: outPath + "/perf.txt", atomically: true, encoding: .utf8)
            if ProcessInfo.processInfo.environment["OLAZ_PERF_KEEP"] == nil { NSApp.terminate(nil) }
            return
        }
        // (a) Chat open latency.
        let candidates = engine.visibleConversations.filter { $0.preview != nil && !engine.isConversationLocked($0.id) }.prefix(12)
        let passes = Int(ProcessInfo.processInfo.environment["OLAZ_PERF_PASSES"] ?? "2") ?? 2
        var opens: [Double] = []
        for pass in 0..<passes {
            for conv in candidates {
                appearedChat = nil
                let state = PerfSignposts.signposter.beginInterval("chat-open", id: PerfSignposts.signposter.makeSignpostID())
                let t0 = CACurrentMediaTime()
                shell.selection = conv.id
                // First display-link frame after the chat list appeared: the main thread was free to present it.
                var tFrame: CFTimeInterval?
                let waitUntil = t0 + 5
                while CACurrentMediaTime() < waitUntil {
                    let before = clock.stamps.count
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                        clock.onFrame = { _ in clock.onFrame = nil; c.resume() }
                    }
                    if appearedChat == conv.id || engine.messages[conv.id]?.isEmpty == true, clock.stamps.count > before {
                        tFrame = clock.stamps.last
                        break
                    }
                }
                PerfSignposts.signposter.endInterval("chat-open", state)
                let ms = ((tFrame ?? CACurrentMediaTime()) - t0) * 1000
                opens.append(ms)
                log(String(format: "open pass=%d conv=%@ msgs=%d ms=%.1f toolbarItems=%d views=%d", pass, String(conv.id.suffix(4)), engine.messages[conv.id]?.count ?? 0, ms,
                           win.toolbar?.items.count ?? -1, countViews(win.contentView?.superview ?? root)))
                // Let the async refresh (history fetch, mark read) land, like a reader would.
                var trail: [String] = []
                for _ in 0..<12 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if let s = chatScrollView(in: root), let doc = s.documentView {
                        let v = s.contentView.bounds
                        trail.append(String(format: "%.0f/%.0f/%d", doc.isFlipped ? doc.frame.height - v.maxY : v.minY, doc.frame.height, engine.messages[conv.id]?.count ?? 0))
                    }
                }
                if ProcessInfo.processInfo.environment["OLAZ_PERF_TRAIL"] != nil { log("  trail " + trail.joined(separator: " ")) }
                log("  mutations: " + takeCounts())
                if let s = chatScrollView(in: root), let doc = s.documentView {
                    let visible = s.contentView.bounds
                    let fromBottom = doc.isFlipped ? doc.frame.height - visible.maxY : visible.minY
                    log(String(format: "  position fromBottom=%.0f", fromBottom))
                    if fromBottom > 100, ProcessInfo.processInfo.environment["OLAZ_PERF_SHOTS"] != nil {
                        let p = Process()
                        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        p.arguments = ["-x", "-o", "-l", "\(win.windowNumber)", outPath + "/off-\(pass)-\(conv.id.suffix(4)).png"]
                        try? p.run(); p.waitUntilExit()
                    }
                }
                if pass == 0, ProcessInfo.processInfo.environment["OLAZ_PERF_SHOTS_ALL"] != nil {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    p.arguments = ["-x", "-o", "-l", "\(win.windowNumber)", outPath + "/open-\(conv.id.suffix(4)).png"]
                    try? p.run(); p.waitUntilExit()
                }
            }
        }
        let sortedOpens = opens.sorted()
        if !sortedOpens.isEmpty {
            log(String(format: "OPEN n=%d median=%.1fms p90=%.1fms max=%.1fms", sortedOpens.count,
                       sortedOpens[sortedOpens.count / 2], sortedOpens[min(sortedOpens.count - 1, Int(Double(sortedOpens.count) * 0.9))], sortedOpens.last!))
        }

        // (b) Scroll a long chat.
        let longest = candidates.max(by: { (engine.messages[$0.id]?.count ?? 0) < (engine.messages[$1.id]?.count ?? 0) })
        if let conv = longest {
            shell.selection = conv.id
            try? await Task.sleep(for: .seconds(2))
            // Pull a few older pages so the chat is long.
            for _ in 0..<4 where engine.hasMoreHistory[conv.id] == true {
                let before = engine.messages[conv.id]?.count ?? 0
                engine.loadOlderMessages(conv.id)
                for _ in 0..<30 where (engine.messages[conv.id]?.count ?? 0) == before { try? await Task.sleep(for: .milliseconds(200)) }
            }
            try? await Task.sleep(for: .seconds(2))
            log("scroll conv=\(conv.id.suffix(4)) msgs=\(engine.messages[conv.id]?.count ?? 0)")
            guard let scroll = chatScrollView(in: root) else { log("no chat scroll view"); return }
            let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
            // OLAZ_PERF_CHURN: while scrolling, other chats "receive" messages and typing every 100 ms (an in-memory dummy
            // entry, never saved), like a busy account; the open chat must not re-render for them.
            let churn = ProcessInfo.processInfo.environment["OLAZ_PERF_CHURN"] != nil
            let dummy = "perf-probe-dummy"
            let churnTask: Task<Void, Never>? = churn ? Task { @MainActor in
                var on = false
                while !Task.isCancelled {
                    on.toggle()
                    engine.messages[dummy] = on ? [] : nil
                    engine.typing[dummy] = on ? TypingStatus(name: "x", onPC: false) : nil
                    try? await Task.sleep(for: .milliseconds(100))
                }
            } : nil
            defer { churnTask?.cancel(); engine.messages[dummy] = nil; engine.typing[dummy] = nil }
            for direction in [-1.0, 1.0] {
                // Up from the bottom, then back down: 1600 pt/s, like a brisk trackpad flick held steady.
                let speed = 1600.0
                let duration = min(6.0, max(1.5, maxY / speed))
                clock.stamps.removeAll()
                let state = PerfSignposts.signposter.beginInterval("chat-scroll", id: PerfSignposts.signposter.makeSignpostID())
                let start = CACurrentMediaTime()
                var last = start
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    clock.onFrame = { _ in
                        let now = CACurrentMediaTime()
                        let dt = now - last
                        last = now
                        let clip = scroll.contentView
                        var origin = clip.bounds.origin
                        let docH = (scroll.documentView?.frame.height ?? 0) - clip.bounds.height
                        origin.y = min(max(0, origin.y + direction * speed * dt * (scroll.documentView?.isFlipped == true ? 1 : -1)), max(0, docH))
                        clip.scroll(to: origin)
                        scroll.reflectScrolledClipView(clip)
                        if now - start > duration { clock.onFrame = nil; c.resume() }
                    }
                }
                PerfSignposts.signposter.endInterval("chat-scroll", state)
                log(frameStats(clock.stamps, label: direction < 0 ? "SCROLL-UP" : "SCROLL-DOWN", refresh: link.duration))
                log("  mutations: " + takeCounts())
            }
        }
        try? report.joined(separator: "\n").write(toFile: outPath + "/perf.txt", atomically: true, encoding: .utf8)
        if ProcessInfo.processInfo.environment["OLAZ_PERF_KEEP"] == nil { NSApp.terminate(nil) }
    }

    /// Opens and closes the inspector on a group and a 1-1 chat, recording the frames of each 0.6 s transition.
    private static func inspectorToggles(engine: ZaloEngine, shell: ShellModel, clock: FrameClock, link: CADisplayLink,
                                         log: (String) -> Void) async {
        let usable = engine.visibleConversations.filter { $0.preview != nil && !engine.isConversationLocked($0.id) }
        let picks = [usable.first(where: \.isGroup), usable.first(where: { !$0.isGroup })].compactMap { $0 }
        let width = Double(ProcessInfo.processInfo.environment["OLAZ_PERF_WIDTH"] ?? "") ?? 1372
        if let win = shell.window { win.setFrame(NSRect(x: 80, y: 80, width: width, height: 873), display: true) }
        for conv in picks {
            shell.selection = conv.id
            try? await Task.sleep(for: .seconds(3))
            for round in 0..<3 {
                for opening in [true, false] {
                    clock.stamps.removeAll()
                    var columns: [String] = []
                    let splits = shell.window?.contentView.map(splitViews(in:)) ?? []
                    clock.onFrame = { _ in
                        columns.append(splits.map { s in s.arrangedSubviews.map { String(format: "%.0f+%.0f", $0.frame.minX, $0.frame.width) }.joined(separator: ",") }.joined(separator: " / "))
                    }
                    let t0 = CACurrentMediaTime()
                    shell.toggleInspector()
                    try? await Task.sleep(for: .milliseconds(600))
                    clock.onFrame = nil
                    if round == 0 { log("  columns " + columns.joined(separator: " | ")) }
                    let firstFrameMs = ((clock.stamps.first ?? t0) - t0) * 1000
                    log(frameStats([t0] + clock.stamps, label: String(format: "%@ %@ r%d", conv.isGroup ? "group" : "1-1",
                                                                         opening ? "OPEN " : "CLOSE", round), refresh: link.duration)
                        + String(format: " first=%.1fms", firstFrameMs))
                    log("  mutations: " + takeCounts())
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
        }
    }

    /// The split views of the shell (outer first).
    private static func splitViews(in root: NSView) -> [NSSplitView] {
        var found: [NSSplitView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSSplitView { found.append(s) }
            v.subviews.forEach(walk)
        }
        walk(root.superview ?? root)
        return found
    }

    /// Counts observable mutations per engine property (re-arming `withObservationTracking` after each one).
    static var mutationCounts: [String: Int] = [:]
    /// OLAZ_PERF_EXPERIMENT: A/B switches for measurements only.
    nonisolated static let experiment = ProcessInfo.processInfo.environment["OLAZ_PERF_EXPERIMENT"] ?? ""

    /// View callbacks (geometry, hover) that may feed a layout loop; counted only while the probe runs.
    static var active = false
    static func bump(_ name: String) { if active { mutationCounts[name, default: 0] += 1 } }
    static func watch(_ engine: ZaloEngine, _ shell: ShellModel) {
        let probes: [(String, @MainActor @Sendable () -> Void)] = [
            ("conversations", { _ = engine.conversations }), ("messages", { _ = engine.messages }),
            ("hasMoreHistory", { _ = engine.hasMoreHistory }), ("historyTicks", { _ = engine.historyTicks }),
            ("typing", { _ = engine.typing }), ("conversationExtras", { _ = engine.conversationExtras }),
            ("conversationActions", { _ = engine.conversationActions }), ("contacts", { _ = engine.contacts }),
            ("notificationSettings", { _ = engine.notificationSettings }), ("call", { _ = engine.call }),
            ("pins", { _ = engine.pins }), ("polls", { _ = engine.polls }), ("cloud", { _ = engine.cloud }),
            ("openConversationId", { _ = engine.openConversationId }), ("canStartTransfer", { _ = engine.canStartTransfer }),
            ("profile", { _ = engine.profile }), ("downloadedFilePaths", { _ = engine.downloadedFilePaths }),
            ("shell.selection", { _ = shell.selection }),
            ("shell.showInspector", { _ = shell.showInspector }), ("shell.columns", { _ = shell.columns }),
        ]
        for (name, read) in probes { arm(name, read) }
    }
    private static func arm(_ name: String, _ read: @escaping @MainActor @Sendable () -> Void) {
        withObservationTracking(read) {
            Task { @MainActor in mutationCounts[name, default: 0] += 1; arm(name, read) }
        }
    }
    static func takeCounts() -> String {
        defer { mutationCounts = [:] }
        return mutationCounts.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }

    private static func countViews(_ v: NSView) -> Int { 1 + v.subviews.reduce(0) { $0 + countViews($1) } }

    /// The tallest vertical scroll view in the detail area: the message list.
    private static func chatScrollView(in root: NSView) -> NSScrollView? {
        var best: NSScrollView?
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, !(s.documentView is NSTableView), !(s.documentView is NSOutlineView),
               let doc = s.documentView, doc.frame.height > (best?.documentView?.frame.height ?? 0),
               s.convert(s.bounds, to: nil).minX > 400 {
                best = s
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        return best
    }

    private static func frameStats(_ stamps: [CFTimeInterval], label: String, refresh: CFTimeInterval) -> String {
        guard stamps.count > 2 else { return "\(label) no frames" }
        let intervals = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }.sorted()
        let expected = (refresh > 0 ? refresh : 1.0 / 60) * 1000
        let total = (stamps.last! - stamps.first!)
        let hitchMs = intervals.reduce(0) { $0 + max(0, $1 - expected) }
        let hitches = intervals.filter { $0 > expected * 1.5 }.count
        let p = { (q: Double) in intervals[min(intervals.count - 1, Int(Double(intervals.count) * q))] }
        return String(format: "%@ frames=%d fps=%.1f expected=%.1fms p50=%.1f p95=%.1f p99=%.1f max=%.1f hitches=%d hitchRatio=%.1fms/s",
                      label, intervals.count, Double(intervals.count) / total, expected, p(0.5), p(0.95), p(0.99), intervals.last!,
                      hitches, hitchMs / total)
    }
}
