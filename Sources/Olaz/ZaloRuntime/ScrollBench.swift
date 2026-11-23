import AppKit
import ImageIO
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

/// `Olaz --scroll-bench <outdir> [label]`: an offline, repeatable benchmark of the chat message list.
///
/// It never starts the engine, opens no session, store or Keychain item and never reads `~/Library/Application Support/Olaz`:
/// a side-effect-free `ZaloEngine` (data directory and media cache inside `<outdir>`) is filled with a synthetic group chat of
/// mixed messages (text of every length, links, mentions, quotes, reactions, photos, stickers, files, link cards, voice,
/// video, calls, notices) whose images are JPEGs generated into `<outdir>`. The real `ChatView` is hosted in its own window,
/// and the list is scrolled programmatically at a steady speed, one step per display frame, through the whole history.
/// Every display-link frame interval and the main thread's busy time per run-loop pass are recorded; results go to stdout
/// and are appended to `<outdir>/bench.txt`. Safe to run while the real Olaz is running (it shares nothing with it).
///
/// Env: `OLAZ_BENCH_MSGS` (default 1200), `OLAZ_BENCH_SPEED` (pt/s, default 2400), `OLAZ_BENCH_SCREEN=builtin|main`,
/// `OLAZ_BENCH_POINTER=over|away` (window under the resting pointer or away from it), `OLAZ_BENCH_SHOT` (screenshots).
@MainActor
enum ScrollBench {
    static func runIfRequested() {
        guard let idx = CommandLine.arguments.firstIndex(of: "--scroll-bench") else { return }
        let args = Array(CommandLine.arguments.dropFirst(idx + 1))
        let out = URL(fileURLWithPath: args.first ?? NSTemporaryDirectory() + "olaz-scroll-bench", isDirectory: true)
        let label = args.count > 1 ? args[1] : "run"
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // Before anything touches MediaLoader.shared: its caches live in the bench folder, and the synthetic images there may be read.
        MediaLoader.sharedCacheDirectory = out.appendingPathComponent("cache", isDirectory: true)
        MediaLoader.allowedLocalRoots.append(out.resolvingSymlinksInPath().path)

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = BenchDelegate(out: out, label: label)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        exit(0)
    }

    private final class BenchDelegate: NSObject, NSApplicationDelegate {
        let out: URL
        let label: String
        init(out: URL, label: String) { self.out = out; self.label = label }
        func applicationDidFinishLaunching(_ notification: Notification) {
            Task { @MainActor in
                if ProcessInfo.processInfo.environment["OLAZ_BENCH_MODE"] == "convlist" {
                    await ScrollBench.runConversationList(out: out, label: label)
                } else {
                    await ScrollBench.run(out: out, label: label)
                }
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: Run

    static let conversationId = "bench-conv"

    static func run(out: URL, label: String) async {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "scroll bench")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        var report: [String] = []
        func log(_ s: String) { print("bench: " + s); report.append(s) }

        let env = ProcessInfo.processInfo.environment
        let count = Int(env["OLAZ_BENCH_MSGS"] ?? "") ?? 1200
        let speed = Double(env["OLAZ_BENCH_SPEED"] ?? "") ?? 2400

        let images = makeImages(in: out.appendingPathComponent("img", isDirectory: true))
        let messages = synthesize(count: count, images: images)

        let data = out.appendingPathComponent("data", isDirectory: true)
        let engine = ZaloEngine(dataDirectory: data, useKeychain: false)
        let shell = ShellModel()
        engine.messages[conversationId] = messages
        engine.hasMoreHistory[conversationId] = false
        let conversation = ZaloEngine.ConversationSummary(
            id: conversationId, isGroup: true, name: "Nhóm thử cuộn", avatar: nil, pinned: false, members: 6, unread: 0, preview: nil)

        let screen = pickScreen(env["OLAZ_BENCH_SCREEN"])
        // The pointer decides whether rows passing under it are hovered, which changes the work of a frame a lot. The pointer
        // is never moved: OLAZ_BENCH_POINTER=over puts the window under it (a reader scrolling with the trackpad), the
        // default `away` on the side of the screen it is not on.
        let size = NSSize(width: min(760, screen.visibleFrame.width / 2 - 20), height: min(860, screen.visibleFrame.height - 80))
        let pointer = NSEvent.mouseLocation
        let pointerOver = env["OLAZ_BENCH_POINTER"] == "over"
        var origin = NSPoint(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 40)
        if pointerOver {
            origin = NSPoint(x: pointer.x - size.width / 2, y: pointer.y - size.height / 2)
        } else if pointer.x < screen.visibleFrame.midX, screen.frame.contains(pointer) {
            origin.x = screen.visibleFrame.maxX - size.width - 20
        }
        let frame = NSRect(origin: origin, size: size)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false, screen: screen)
        window.title = "Olaz scroll bench"
        window.isReleasedWhenClosed = false
        let root = ChatView(conversation: conversation).olazAppearance(engine: engine, shell: shell)
        let host = NSHostingView(rootView: root)
        window.contentView = host
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let clock = FrameClock()
        let link = host.displayLink(target: clock, selector: #selector(FrameClock.tick(_:)))
        link.add(to: .main, forMode: .common)
        defer { link.invalidate() }
        let busy = BusyMeter()
        busy.install()
        defer { busy.remove() }

        try? await Task.sleep(for: .seconds(2.5))
        let refresh = clock.refresh
        log(String(format: "label=%@ msgs=%d speed=%.0fpt/s screen=%@ maxFPS=%d refresh=%.2fms core=%@ window=%.0fx%.0f",
                   label, messages.count, speed, screen.localizedName, screen.maximumFramesPerSecond, refresh * 1000,
                   RustCore.isEnabled ? "rust" : "swift", frame.width, frame.height))

        guard let scroll = largestScrollView(in: host) else { log("no scroll view"); return }
        if let list = ChatListController.forScrollView(scroll) { log("list " + list.debugGeometry) }

        // OLAZ_BENCH_SHOT: window screenshots at the bottom and 2500 pt up, for comparing what the list draws.
        if env["OLAZ_BENCH_SHOT"] != nil {
            func shot(_ name: String) async {
                try? await Task.sleep(for: .seconds(1.5))
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", out.appendingPathComponent("\(label)-\(name).png").path]
                try? p.run(); p.waitUntilExit()
            }
            await shot("bottom")
            let clip = scroll.contentView
            let flipped = scroll.documentView?.isFlipped == true
            clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y + (flipped ? -2500 : 2500)))
            scroll.reflectScrolledClipView(clip)
            await shot("up2500")
            clip.scroll(to: NSPoint(x: 0, y: flipped ? (scroll.documentView?.frame.height ?? 0) : 0))
            scroll.reflectScrolledClipView(clip)
            try? await Task.sleep(for: .seconds(1))
        }

        // 1. Cold: drag from the newest message up through the whole history (rows and images never seen before).
        // 2. Warm: back down to the bottom. 3–4. A fast fling up and down (3x speed).
        let passes: [(String, Double, Double)] = [
            ("DRAG-UP-COLD", -1, speed), ("DRAG-DOWN-WARM", 1, speed), ("FLING-UP", -1, speed * 3), ("FLING-DOWN", 1, speed * 3),
        ]
        var all: [Double] = []
        var allBusy: [Double] = []
        var allCPU = 0.0
        var allInstr = 0.0
        for (name, direction, pts) in passes {
            let r = await scrollPass(scroll, clock: clock, busy: busy, direction: direction, speed: pts, maxSeconds: 12)
            all += r.intervals
            allBusy += r.busy
            allCPU += r.cpu
            allInstr += r.instructions
            log(stats(name, intervals: r.intervals, busy: r.busy, seconds: r.seconds, refresh: refresh, distance: r.distance, cpu: r.cpu, instructions: r.instructions))
            try? await Task.sleep(for: .milliseconds(600))
        }
        log("pointerOverWindow=\(window.frame.contains(NSEvent.mouseLocation)) asked=\(pointerOver ? "over" : "away")")
        log(stats("TOTAL", intervals: all, busy: allBusy, seconds: all.reduce(0, +) / 1000, refresh: refresh, distance: 0, cpu: allCPU, instructions: allInstr))

        // Live chat while the reader drags up from the bottom: every 200 ms a reaction changes on a recent message, every
        // second a new message arrives (it must neither move the list nor re-render the other rows).
        _ = await scrollPass(scroll, clock: clock, busy: busy, direction: 1, speed: speed * 3, maxSeconds: 12)
        try? await Task.sleep(for: .milliseconds(600))
        let live = Task { @MainActor in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                tick += 1
                guard var list = engine.messages[conversationId], list.count > 8 else { continue }
                let i = list.count - 6
                list[i].reactions = list[i].reactions.isEmpty
                    ? [.init(icon: ReactionIcon(type: "1", emoji: "👍"), count: tick, includesMe: false, names: [], people: 1)] : []
                if tick % 5 == 0 {
                    var m = list[list.count - 1]
                    m.id = "live-\(tick)"
                    m.text = "Tin mới \(tick)"
                    m.kind = .text
                    m.isMine = false
                    m.senderId = "u2"
                    m.date = m.date.addingTimeInterval(1)
                    list.append(m)
                }
                engine.messages[conversationId] = list
            }
        }
        let liveResult = await scrollPass(scroll, clock: clock, busy: busy, direction: -1, speed: speed, maxSeconds: 8)
        live.cancel()
        log(stats("DRAG-UP-LIVE", intervals: liveResult.intervals, busy: liveResult.busy, seconds: liveResult.seconds, refresh: refresh, distance: liveResult.distance, cpu: liveResult.cpu, instructions: liveResult.instructions))

        // 5. History page prepended while the reader is at the top (the official client pulls 50 messages per page).
        let keep = min(messages.count, 200)
        engine.messages[conversationId] = Array(messages.suffix(keep))
        try? await Task.sleep(for: .seconds(1.5))
        var pageIntervals: [Double] = []
        var pageBusy: [Double] = []
        var drift: [Double] = []
        var pageCPU = 0.0
        var pageInstr = 0.0
        var loaded = keep
        while loaded < messages.count, pageIntervals.count < 2000 {
            _ = await scrollPass(scroll, clock: clock, busy: busy, direction: -1, speed: speed, maxSeconds: 8, stopAtEdge: true)
            let anchorBefore = topVisibleAnchor(scroll)
            loaded = min(messages.count, loaded + 50)
            clock.stamps.removeAll()
            busy.reset()
            engine.messages[conversationId] = Array(messages.suffix(loaded))
            // Keep scrolling up slowly for 0.6 s while the page settles, as a reader still pulling would.
            let r = await scrollPass(scroll, clock: clock, busy: busy, direction: -1, speed: 300, maxSeconds: 0.6)
            pageIntervals += r.intervals
            pageBusy += r.busy
            pageCPU += r.cpu
            pageInstr += r.instructions
            if let a = anchorBefore, let after = position(of: a.view, in: scroll) { drift.append(abs(after - a.y) - 180) }
            if loaded - keep >= 250 { break }
        }
        log(String(format: "memory rss=%.0fMB", residentMB()))
        log(stats("PREPEND-PAGES", intervals: pageIntervals, busy: pageBusy, seconds: pageIntervals.reduce(0, +) / 1000, refresh: refresh, distance: 0, cpu: pageCPU, instructions: pageInstr))

        let text = report.joined(separator: "\n") + "\n\n"
        let file = out.appendingPathComponent("bench.txt")
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
        _ = drift
    }

    // MARK: Scrolling

    private struct PassResult { var intervals: [Double]; var busy: [Double]; var seconds: Double; var distance: Double; var cpu: Double; var instructions: Double }

    /// Instructions the process has retired so far (all threads), in millions: a measure of work that, unlike time, does not
    /// change with other load on the machine or with the core the work ran on.
    private static func instructionsM() -> Double {
        var info = rusage_info_v4()
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return kr == 0 ? Double(info.ri_instructions) / 1_000_000 : 0
    }

    /// CPU time the main thread has used so far, in ms: unlike wall time it does not grow when other processes take the CPU.
    private static func mainThreadCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let port = pthread_mach_thread_np(pthread_self())
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds + info.system_time.seconds) * 1000
            + Double(info.user_time.microseconds + info.system_time.microseconds) / 1000
    }

    /// Moves the clip view by `speed * dt` every display frame (like a held trackpad drag) until the edge or `maxSeconds`.
    private static func scrollPass(_ scroll: NSScrollView, clock: FrameClock, busy: BusyMeter, direction: Double, speed: Double,
                                   maxSeconds: Double, stopAtEdge: Bool = true) async -> PassResult {
        clock.stamps.removeAll()
        busy.reset()
        let cpuStart = mainThreadCPU()
        let instrStart = instructionsM()
        let start = CACurrentMediaTime()
        var last = start
        var moved = 0.0
        let flipped = scroll.documentView?.isFlipped == true
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            clock.onFrame = {
                let now = CACurrentMediaTime()
                let dt = now - last
                last = now
                let clip = scroll.contentView
                var origin = clip.bounds.origin
                let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
                let step = direction * speed * dt * (flipped ? 1 : -1)
                let target = min(max(0, origin.y + step), maxY)
                moved += abs(target - origin.y)
                let atEdge = abs(target - origin.y) < 0.5 && (target <= 0.5 || target >= maxY - 0.5)
                origin.y = target
                clip.scroll(to: origin)
                scroll.reflectScrolledClipView(clip)
                if now - start > maxSeconds || (stopAtEdge && atEdge && now - start > 0.3) {
                    clock.onFrame = nil
                    c.resume()
                }
            }
        }
        let stamps = clock.stamps
        let intervals = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }
        return PassResult(intervals: intervals, busy: busy.take(), seconds: (stamps.last ?? start) - (stamps.first ?? start), distance: moved,
                          cpu: mainThreadCPU() - cpuStart, instructions: instructionsM() - instrStart)
    }

    private static func stats(_ label: String, intervals: [Double], busy: [Double], seconds: Double, refresh: Double, distance: Double, cpu: Double = 0, instructions: Double = 0) -> String {
        guard intervals.count > 2, seconds > 0 else { return "\(label) no frames" }
        let sorted = intervals.sorted()
        let expected = refresh * 1000
        let hitchMs = intervals.reduce(0) { $0 + max(0, $1 - expected * 1.05) }
        let missed = intervals.reduce(0) { $0 + max(0, Int(($1 / expected).rounded()) - 1) }
        let p = { (q: Double) in sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
        let busySorted = busy.sorted()
        let bp = { (q: Double) in busySorted.isEmpty ? 0 : busySorted[min(busySorted.count - 1, Int(Double(busySorted.count) * q))] }
        let busyTotal = busy.reduce(0, +)
        return String(format: "%@ frames=%d fps=%.1f p50=%.1f p95=%.1f p99=%.1f max=%.1fms dropped=%d (%.1f%%) hitch=%.1fms/s mainBusy=%.0f%% main=%.2fms/frame main=%.1fms/1000pt cpu=%.2fms/frame instr=%.1fM/frame passP50=%.1f passP99=%.1f passMax=%.1fms dist=%.0fpt",
                      label, intervals.count, Double(intervals.count) / seconds, p(0.5), p(0.95), p(0.99), sorted.last!,
                      missed, Double(missed) / Double(intervals.count + missed) * 100, hitchMs / seconds,
                      busyTotal / (seconds * 1000) * 100, busyTotal / Double(intervals.count), distance > 0 ? busyTotal / distance * 1000 : 0, cpu / Double(intervals.count), instructions / Double(intervals.count), bp(0.5), bp(0.99), busySorted.last ?? 0, distance)
    }

    private static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }

    // MARK: Anchor (prepend drift)

    private static func topVisibleAnchor(_ scroll: NSScrollView) -> (view: NSView, y: Double)? {
        guard let doc = scroll.documentView else { return nil }
        let visible = scroll.contentView.bounds
        var best: (NSView, Double)?
        for v in doc.subviews where v.frame.intersects(visible) {
            let y = scroll.convert(v.bounds, from: v).minY
            if best == nil || y < best!.1 { best = (v, y) }
        }
        return best.map { ($0.0, $0.1) }
    }

    private static func position(of view: NSView, in scroll: NSScrollView) -> Double? {
        guard view.window != nil else { return nil }
        return scroll.convert(view.bounds, from: view).minY
    }

    private static func largestScrollView(in root: NSView) -> NSScrollView? {
        var best: NSScrollView?
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, let doc = s.documentView,
               doc.frame.height > (best?.documentView?.frame.height ?? 0), s.bounds.height > 300 {
                best = s
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        return best
    }

    private static func pickScreen(_ choice: String?) -> NSScreen {
        let screens = NSScreen.screens
        if choice == "main" { return NSScreen.main ?? screens[0] }
        return screens.max(by: { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }) ?? screens[0]
    }

    // MARK: Clocks

    private final class FrameClock: NSObject {
        var stamps: [CFTimeInterval] = []
        var onFrame: (() -> Void)?
        var refresh: CFTimeInterval = 1.0 / 60
        @objc func tick(_ link: CADisplayLink) {
            stamps.append(CACurrentMediaTime())
            let d = link.targetTimestamp - link.timestamp
            if d > 0.002 { refresh = d }
            onFrame?()
        }
    }

    /// Main-thread busy time of each run-loop pass (after waking up → before sleeping again), in ms.
    private final class BusyMeter {
        private var observer: CFRunLoopObserver?
        private var began: CFTimeInterval = 0
        private var passes: [Double] = []
        func install() {
            observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
                                                          true, 0) { [weak self] _, activity in
                guard let self else { return }
                let now = CACurrentMediaTime()
                if activity == .afterWaiting { self.began = now } else if self.began > 0 {
                    self.passes.append((now - self.began) * 1000)
                    self.began = 0
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
        func remove() { if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) } }
        func reset() { passes.removeAll(); began = 0 }
        func take() -> [Double] { defer { passes.removeAll() }; return passes }
    }

    // MARK: Synthetic data

    /// Deterministic generator (SplitMix64) so every run scrolls the same chat.
    private struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
        mutating func chance(_ p: Double) -> Bool { Double(next() % 10_000) / 10_000 < p }
    }

    struct BenchImages { var photos: [(URL, Int, Int)]; var stickers: [URL]; var avatars: [URL] }

    /// Photos (several aspect ratios, camera-sized so decoding costs what a real photo does), stickers and avatars.
    static func makeImages(in dir: URL) -> BenchImages {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var rng = RNG(state: 7)
        func render(_ w: Int, _ h: Int, _ name: String, png: Bool = false) -> URL {
            let url = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
            let cs = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return url }
            func color() -> CGColor {
                CGColor(red: Double(rng.int(255)) / 255, green: Double(rng.int(255)) / 255, blue: Double(rng.int(255)) / 255, alpha: 1)
            }
            if let g = CGGradient(colorsSpace: cs, colors: [color(), color(), color()] as CFArray, locations: [0, 0.5, 1]) {
                ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
            }
            for _ in 0..<400 {   // detail, so JPEG decode is not trivially cheap
                ctx.setFillColor(color().copy(alpha: 0.35)!)
                let r = CGRect(x: rng.int(w), y: rng.int(h), width: 8 + rng.int(w / 6), height: 8 + rng.int(h / 6))
                if rng.chance(0.5) { ctx.fillEllipse(in: r) } else { ctx.fill(r) }
            }
            guard let image = ctx.makeImage(),
                  let dest = CGImageDestinationCreateWithURL(url as CFURL, (png ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil)
            else { return url }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            CGImageDestinationFinalize(dest)
            return url
        }
        let shapes = [(2048, 1536), (1536, 2048), (1920, 1080), (1080, 1920), (1600, 1600), (2048, 1152), (1200, 1600), (2400, 1080)]
        var photos: [(URL, Int, Int)] = []
        for i in 0..<16 {
            let (w, h) = shapes[i % shapes.count]
            photos.append((render(w, h, "photo-\(i).jpg"), w, h))
        }
        let stickers = (0..<6).map { render(320, 320, "sticker-\($0).png", png: true) }
        let avatars = (0..<6).map { render(240, 240, "avatar-\($0).jpg") }
        return BenchImages(photos: photos, stickers: stickers, avatars: avatars)
    }

    private static let words = """
    chào mọi người hôm nay mình gửi lại tài liệu cuộc họp nhé ai cần thì xem trước tối nay mình sẽ cập nhật bản mới \
    nhớ kiểm tra lại số liệu tháng trước trước khi gửi khách hàng cảm ơn bạn nhiều lắm đã hỗ trợ dự án tuần này \
    lịch đi công tác thay đổi sang thứ năm phòng họp tầng ba đặt lúc chín giờ sáng anh chị nào bận báo mình sớm \
    ok mình hiểu rồi để mình xử lý ngay sau giờ ăn trưa có gì cần thêm thì nhắn trong nhóm này luôn nhé
    """.split(separator: " ").map(String.init)

    /// A group chat of `count` messages over ~40 days, newest last, ids unique per message (also per image URL, so every photo
    /// is decoded once like a real chat's distinct photos).
    static func synthesize(count: Int, images: BenchImages) -> [ChatMessage] {
        var rng = RNG(state: 42)
        let senders: [(id: String, name: String)] = [("me", "Bạn"), ("u1", "Minh Anh"), ("u2", "Quốc Bảo"), ("u3", "Thu Trang"),
                                                     ("u4", "Hoàng Nam"), ("u5", "Lan Phương")]
        var date = Date().addingTimeInterval(-40 * 86_400)
        let step = 40 * 86_400 / Double(max(1, count))
        var out: [ChatMessage] = []
        out.reserveCapacity(count)
        var sender = 1
        func sentence(_ n: Int) -> String {
            var s = (0..<n).map { _ in words[rng.int(words.count)] }.joined(separator: " ")
            s = s.prefix(1).uppercased() + s.dropFirst()
            return s
        }
        for i in 0..<count {
            if rng.chance(0.35) { sender = rng.int(senders.count) }
            date = date.addingTimeInterval(step * (rng.chance(0.7) ? 0.2 : 2.5))
            let who = senders[sender]
            let mine = who.id == "me"
            var kind: ChatMessage.Kind = .text
            var text = ""
            var quote: ChatMessage.Quote?
            var mentions: [Mention] = []
            let roll = rng.int(100)
            switch roll {
            case 0..<22: text = sentence(3 + rng.int(8))
            case 22..<34: text = sentence(15 + rng.int(30))
            case 34..<38: text = sentence(60 + rng.int(80))
            case 38..<43: text = sentence(4 + rng.int(6)) + " https://example.com/tai-lieu/\(i) " + sentence(3)
            case 43..<46:
                text = "@Minh Anh " + sentence(6 + rng.int(10))
                mentions = [Mention(uid: "u1", pos: 0, len: 9)]
            case 46..<50:
                text = sentence(4 + rng.int(10))
                quote = ChatMessage.Quote(senderName: senders[1 + rng.int(5)].name, text: sentence(8 + rng.int(20)))
            case 50..<68:
                let p = images.photos[rng.int(images.photos.count)]
                kind = .photo(url: URL(string: p.0.absoluteString + "?m=\(i)"), width: p.1, height: p.2)
                text = rng.chance(0.2) ? sentence(5) : "[Hình ảnh]"
            case 68..<73: kind = .sticker(url: images.stickers[rng.int(images.stickers.count)])
            case 73..<78:
                kind = .file(name: "Bao-cao-thang-\(1 + rng.int(12)).xlsx", size: Int64(20_000 + rng.int(4_000_000)), url: URL(string: "https://example.invalid/f/\(i)"))
                text = "[File]"
            case 78..<83:
                let p = images.photos[rng.int(images.photos.count)]
                kind = .link(title: sentence(6), url: URL(string: "https://example.com/bai-viet/\(i)"),
                             thumbnail: URL(string: p.0.absoluteString + "?l=\(i)"), description: sentence(14), source: "example.com")
                text = "https://example.com/bai-viet/\(i)"
            case 83..<86: kind = .voice(url: nil, duration: 3 + rng.int(60)); text = "[Tin nhắn thoại]"
            case 86..<89:
                let p = images.photos[rng.int(images.photos.count)]
                kind = .video(thumbnail: URL(string: p.0.absoluteString + "?v=\(i)"), duration: 5 + rng.int(200)); text = "[Video]"
            case 89..<92: kind = .call(video: rng.chance(0.3), missed: rng.chance(0.3), duration: rng.int(600)); text = "[Cuộc gọi]"
            case 92..<94: kind = .system; text = "\(who.name) đã thêm \(senders[1 + rng.int(5)].name) vào nhóm"
            default: text = sentence(2)
            }
            var reactions: [ChatMessage.Reaction] = []
            if rng.chance(0.15) {
                reactions.append(.init(icon: ReactionIcon(type: "\(rng.int(6))", emoji: ["❤️", "👍", "😆", "😮", "😢", "😡"][rng.int(6)]),
                                       count: 1 + rng.int(4), includesMe: rng.chance(0.3), names: ["Minh Anh"], people: 1))
            }
            out.append(ChatMessage(
                id: "m\(100_000 + i)", conversationId: conversationId, senderId: who.id, senderName: who.name,
                senderAvatar: mine ? nil : images.avatars[sender % images.avatars.count],
                isMine: mine, kind: kind, text: text, date: date, status: .seen, quote: quote, reactions: reactions,
                isE2EE: false, mentions: mentions))
        }
        return out
    }
}

// MARK: - Conversation list (OLAZ_BENCH_MODE=convlist)

extension ScrollBench {
    /// The conversation column with `OLAZ_BENCH_CONVS` (default 700) synthetic chats. Passes: messages arriving while idle
    /// (one every 250 ms moves a chat from lower down to the top, as `applyParsedEvents` does), a drag down and up, and both at
    /// once. Same metrics as the chat bench; `upd` is per arriving message.
    static func runConversationList(out: URL, label: String) async {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "list bench")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        var report: [String] = []
        func log(_ s: String) { print("bench: " + s); report.append(s) }
        let env = ProcessInfo.processInfo.environment
        let count = Int(env["OLAZ_BENCH_CONVS"] ?? "") ?? 700
        let speed = Double(env["OLAZ_BENCH_SPEED"] ?? "") ?? 2400

        let images = makeImages(in: out.appendingPathComponent("img", isDirectory: true))
        let engine = ZaloEngine(dataDirectory: out.appendingPathComponent("data", isDirectory: true), useKeychain: false)
        let shell = ShellModel()
        var rng = RNG(state: 11)
        let start = Date()
        var list: [ZaloEngine.ConversationSummary] = (0..<count).map { i in
            let group = rng.chance(0.3)
            return ZaloEngine.ConversationSummary(
                id: group ? "g\(100_000 + i)" : "\(200_000 + i)", isGroup: group, name: (group ? "Nhóm " : "Bạn ") + "\(i)",
                avatar: images.avatars.isEmpty ? nil : images.avatars[i % images.avatars.count], pinned: false,
                members: group ? 3 + rng.int(200) : 0, unread: rng.chance(0.2) ? 1 + rng.int(9) : 0,
                preview: .init(text: "Tin nhắn \(i) " + String(repeating: "chữ ", count: rng.int(12)),
                               date: start.addingTimeInterval(-Double(i) * 600), fromMe: rng.chance(0.3)))
        }
        func publish() {
            engine.conversations = list
            engine.rebuildConversationFlags()
            engine.rebuildConversationExtras()
        }
        publish()
        shell.destination = .inbox

        let screen = pickScreen(env["OLAZ_BENCH_SCREEN"])
        let size = NSSize(width: 380, height: min(860, screen.visibleFrame.height - 80))
        let frame = NSRect(origin: NSPoint(x: screen.visibleFrame.maxX - size.width - 20, y: screen.visibleFrame.minY + 40), size: size)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false, screen: screen)
        window.title = "Olaz list bench"
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ConversationListColumn().olazAppearance(engine: engine, shell: shell))
        window.contentView = host
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let clock = FrameClock()
        let link = host.displayLink(target: clock, selector: #selector(FrameClock.tick(_:)))
        link.add(to: .main, forMode: .common)
        defer { link.invalidate() }
        let busy = BusyMeter()
        busy.install()
        defer { busy.remove() }
        try? await Task.sleep(for: .seconds(2.5))
        let refresh = clock.refresh
        log(String(format: "label=%@ mode=convlist convs=%d speed=%.0fpt/s refresh=%.2fms", label, count, speed, refresh * 1000))
        guard let scroll = largestScrollView(in: host) else { log("no scroll view"); return }
        if env["OLAZ_BENCH_SHOT"] != nil {
            shell.selection = list[3].id
            try? await Task.sleep(for: .seconds(1.5))
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", out.appendingPathComponent("\(label)-list.png").path]
            try? p.run(); p.waitUntilExit()
        }

        var tick = 0
        func arrive() {
            tick += 1
            let idx = 5 + rng.int(max(1, list.count - 5))
            var c = list.remove(at: idx)
            c.preview = .init(text: "Tin mới \(tick)", date: Date(), fromMe: false)
            c.unread += 1
            list.insert(c, at: 0)
            publish()
        }
        func arrivals() -> Task<Void, Never> {
            Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    if !Task.isCancelled { arrive() }
                }
            }
        }

        // 1. Messages arriving while the list sits still.
        clock.stamps.removeAll(); busy.reset()
        let cpu0 = mainThreadCPU(), instr0 = instructionsM(), tick0 = tick
        let idle = arrivals()
        try? await Task.sleep(for: .seconds(10))
        idle.cancel()
        let updates = max(1, tick - tick0)
        let stamps = clock.stamps
        let intervals = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }
        let cpu = mainThreadCPU() - cpu0, instr = instructionsM() - instr0
        log(stats("NEWMSG-IDLE", intervals: intervals, busy: busy.take(), seconds: (stamps.last ?? 0) - (stamps.first ?? 0),
                  refresh: refresh, distance: 0, cpu: cpu, instructions: instr)
            + String(format: " upd=%d cpu=%.2fms/upd instr=%.1fM/upd", updates, cpu / Double(updates), instr / Double(updates)))
        try? await Task.sleep(for: .milliseconds(600))

        // 2–3. Drag down through the list and back up.
        for (name, direction) in [("SCROLL-DOWN", 1.0), ("SCROLL-UP", -1.0)] {
            let r = await scrollPass(scroll, clock: clock, busy: busy, direction: direction, speed: speed, maxSeconds: 10)
            log(stats(name, intervals: r.intervals, busy: r.busy, seconds: r.seconds, refresh: refresh, distance: r.distance,
                      cpu: r.cpu, instructions: r.instructions))
            try? await Task.sleep(for: .milliseconds(600))
        }

        // 4. Dragging while messages arrive.
        let tick1 = tick
        let live = arrivals()
        let r = await scrollPass(scroll, clock: clock, busy: busy, direction: 1, speed: speed, maxSeconds: 8)
        live.cancel()
        let liveUpdates = max(1, tick - tick1)
        log(stats("SCROLL-NEWMSG", intervals: r.intervals, busy: r.busy, seconds: r.seconds, refresh: refresh, distance: r.distance,
                  cpu: r.cpu, instructions: r.instructions)
            + String(format: " upd=%d instr=%.1fM/upd", liveUpdates, r.instructions / Double(liveUpdates)))
        log(String(format: "memory rss=%.0fMB", residentMB()))

        let text = report.joined(separator: "\n") + "\n\n"
        let file = out.appendingPathComponent("bench.txt")
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
