import SwiftUI
import AppKit
import QuickLookUI
import UniformTypeIdentifiers

/// Preview of one cloud item: downloads it through the official downloader, then shows the photo (zoomable), plays the
/// video / voice message (the media viewer's player, without its full-screen button), or previews the file with
/// QuickLook. Save goes through an NSSavePanel.
struct CloudPreviewSheet: View {
    @Environment(ZaloEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    let item: CloudItem

    private enum Phase {
        case loading
        case ready(CloudFile, staged: URL?)
        case expired
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var playback: VideoPlayback?
    @State private var zoom = ZoomController()
    @State private var saved = false
    @State private var note: String?
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(minWidth: 720, idealWidth: 980, minHeight: 520, idealHeight: 700)
        .task(id: attempt) { await load() }
        .onDisappear { playback?.stop(); playback = nil }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind == .file ? item.fileSymbol : item.kind.symbol)
                .font(.system(size: 18)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text([CloudFormat.size(item.size), item.conversationLabel, CloudFormat.date(item.date)].joined(separator: " • "))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.glass).buttonBorderShape(.circle).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Đang tải từ zCloud…").font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
        case .expired:
            ContentUnavailableView("Nội dung đã hết hạn", systemImage: "clock.badge.xmark",
                                   description: Text("Nội dung này không còn trên zCloud."))
        case .failed(let message):
            ContentUnavailableView {
                Label("Không tải được", systemImage: "exclamationmark.icloud")
            } description: {
                Text(message)
            } actions: {
                Button("Thử lại") { phase = .loading; attempt += 1 }
            }
        case .ready(let file, let staged):
            switch item.kind {
            case .photo:
                RemoteImage(url: file.url, contentMode: .fit, maxPixelSize: 6144) { ProgressView() }
                    .uncached()
                    .rendering { image in ZoomableImageView(image: image, zoom: zoom) }
                    .overlay(alignment: .topTrailing) {
                        ZoomControls(zoom: zoom, showsShortcuts: false).padding(12)
                    }
            case .video, .voice:
                if let playback {
                    VideoPlayerView(playback: playback)
                } else {
                    ContentUnavailableView("Không phát được", systemImage: "play.slash",
                                           description: Text("Định dạng này không phát được trong ứng dụng. Hãy lưu về máy hoặc mở bằng ứng dụng khác."))
                }
            default:
                if let staged {
                    QuickLookPreview(url: staged)
                } else {
                    ContentUnavailableView(item.displayName, systemImage: item.fileSymbol)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if saved { Label("Đã lưu về máy", systemImage: "checkmark.circle.fill").font(.system(size: 12.5)).foregroundStyle(.green) }
            if let note { Text(note).font(.system(size: 12)).foregroundStyle(.orange).lineLimit(2) }
            Spacer()
            if case .ready(_, let staged) = phase {
                Button("Mở bằng ứng dụng khác") { openElsewhere(staged) }
                    .buttonStyle(.glass).disabled(staged == nil)
                Button("Lưu về máy…", systemImage: "square.and.arrow.down") { save() }
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func load() async {
        saved = false
        switch await engine.cloudFetch(item.id) {
        case .expired: phase = .expired
        case .failed(let message): phase = .failed(message)
        case .ready(let file):
            let container = CloudContainer(fileAt: file.url)
            let output = CloudFiles.outputName(item: item, container: container)
            let staged = CloudFiles.stage(file.url, name: output.name, ext: output.ext)
            if (item.kind == .video || item.kind == .voice), let staged {
                playback?.stop()
                playback = VideoPlayback(url: staged)
            }
            phase = .ready(file, staged: staged)
        }
    }

    private func save() {
        guard case .ready(let file, _) = phase else { return }
        note = nil
        Task {
            switch await CloudSaver.save(file, item: item) {
            case .saved: saved = true
            case .cancelled: break
            case .failed(let message): saved = false; note = message
            }
        }
    }

    /// Anything that could run code is revealed in Finder instead of opened (the name comes from the sender).
    private func openElsewhere(_ staged: URL?) {
        guard let staged else { return }
        if CloudFiles.mayExecute(staged, displayName: item.displayName) {
            NSWorkspace.shared.activateFileViewerSelecting([staged])
            note = "Đã mở trong Finder vì tệp có thể chạy mã"
        } else {
            NSWorkspace.shared.open(staged)
        }
    }
}

/// QuickLook preview of a local file.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }
}

@MainActor
enum ChatFileSavePanel {
    static func saveAs(staged: URL, displayName: String, window: NSWindow? = nil) async -> Result<URL?, Error> {
        let container = CloudContainer(fileAt: staged)
        let fallbackExt = staged.pathExtension.isEmpty ? container.fileExtension : staged.pathExtension
        let safeName = ChatFileResolver.sanitizedFileName(displayName, fallbackExtension: fallbackExt)

        let panel = NSSavePanel()
        panel.title = "Lưu tệp về máy"
        panel.prompt = "Lưu"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = safeName
        let ext = (safeName as NSString).pathExtension
        if !ext.isEmpty, let ut = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [ut]
        }

        let targetWindow = window ?? NSApp.keyWindow
        let response: NSApplication.ModalResponse
        if let targetWindow {
            response = await panel.beginSheetModal(for: targetWindow)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let destination = panel.url else {
            return .success(nil)
        }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: staged, to: destination)
            MediaLoader.applyQuarantine(to: destination, origin: URL(string: "https://chat.zalo.me/")!)
            return .success(destination)
        } catch {
            return .failure(error)
        }
    }
}

/// Preview sheet for chat & inspector file attachments ("Xem trước"): streams and decrypts `?e2esession=...` files,
/// stages them with their real filename + extension, renders via QuickLook / ZoomableImageView / VideoPlayerView,
/// and provides "Tải về (Downloads)", "Lưu về máy…", and "Mở bằng ứng dụng khác".
struct FilePreviewSheet: View {
    @Environment(ZaloEngine.self) private var engine: ZaloEngine?
    @Environment(\.dismiss) private var dismiss

    let name: String
    let size: Int64
    let url: URL?
    var conversationId: String = ""
    var messageId: String = ""

    private enum Phase {
        case loading
        case ready(URL)
        case expired
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var progress: Double = 0
    @State private var playback: VideoPlayback?
    @State private var zoom = ZoomController()
    @State private var savedURL: URL?
    @State private var note: String?
    @State private var attempt = 0

    private var downloadKey: String {
        engine?.fileDownloadKey(conversationId: conversationId, messageId: messageId, url: url, name: name)
            ?? (url?.absoluteString ?? name)
    }

    private var fileExt: String {
        (name as NSString).pathExtension.lowercased()
    }

    private var symbol: String {
        FileCard.iconName(for: name)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.4)
            footer
        }
        .frame(minWidth: 720, idealWidth: 980, minHeight: 520, idealHeight: 700)
        .task(id: attempt) { await load(force: attempt > 0) }
        .onDisappear { playback?.stop(); playback = nil }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(name.isEmpty ? "Tệp đính kèm" : name)
                    .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                if size > 0 {
                    Text(CloudFormat.size(size))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.glass).buttonBorderShape(.circle).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: 10) {
                if progress > 0 && progress < 1 {
                    ProgressView(value: progress)
                        .frame(width: 220)
                    Text("Đang tải tệp… \(Int((progress * 100).rounded()))%")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                    Text("Đang tải tệp để xem trước…")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
            }
        case .expired:
            ContentUnavailableView(
                "Tệp đã quá hạn",
                systemImage: "clock.badge.xmark",
                description: Text("Tệp đính kèm này không còn lưu trên máy chủ Zalo.")
            )
        case .failed(let message):
            ContentUnavailableView {
                Label("Không xem trước được tệp", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Thử lại") { phase = .loading; progress = 0; attempt += 1 }
            }
        case .ready(let staged):
            previewBody(for: staged)
        }
    }

    @ViewBuilder private func previewBody(for staged: URL) -> some View {
        let ext = staged.pathExtension.lowercased()
        let isImage = ["jpg", "jpeg", "png", "gif", "webp", "heic", "jxl", "bmp", "tiff"].contains(ext)
        let isAV = ["mp4", "mov", "m4v", "m4a", "mp3", "wav", "aac"].contains(ext)
        if isImage {
            RemoteImage(url: staged, contentMode: .fit, maxPixelSize: 6144) { ProgressView() }
                .uncached()
                .rendering { image in ZoomableImageView(image: image, zoom: zoom) }
                .overlay(alignment: .topTrailing) {
                    ZoomControls(zoom: zoom, showsShortcuts: false).padding(12)
                }
        } else if isAV, let playback {
            VideoPlayerView(playback: playback)
        } else {
            QuickLookPreview(url: staged)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let existing = activeSavedURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([existing])
                } label: {
                    Label("Đã tải • Hiện trong Finder", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
            }
            if let note {
                Text(note).font(.system(size: 12)).foregroundStyle(.orange).lineLimit(2)
            }
            Spacer()
            if case .ready(let staged) = phase {
                Button("Mở bằng ứng dụng khác") { openElsewhere(staged) }
                    .buttonStyle(.glass)
                Button("Lưu về máy…", systemImage: "folder") { saveAs(staged) }
                    .buttonStyle(.glass)
                Button("Tải về", systemImage: "arrow.down.circle") { downloadToDownloads(staged) }
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var activeSavedURL: URL? {
        if let savedURL, FileManager.default.fileExists(atPath: savedURL.path) {
            return savedURL
        }
        return engine?.rememberedDownloadedFile(for: downloadKey)
    }

    private func load(force: Bool) async {
        note = nil
        savedURL = engine?.rememberedDownloadedFile(for: downloadKey)
        let onProgress: @Sendable (Double) -> Void = { frac in
            Task { @MainActor in self.progress = frac }
        }
        let res: FileResolution
        if let engine {
            res = await engine.resolveFile(
                conversationId: conversationId,
                messageId: messageId,
                name: name,
                url: url,
                force: force,
                progress: onProgress
            )
        } else {
            res = await ChatFileResolver.resolve(name: name, url: url, force: force, progress: onProgress)
        }
        switch res {
        case .expired:
            phase = .expired
        case .failed(let msg):
            phase = .failed(msg)
        case .ready(let staged):
            let ext = staged.pathExtension.lowercased()
            if ["mp4", "mov", "m4v", "m4a", "mp3", "wav", "aac"].contains(ext) {
                playback?.stop()
                playback = VideoPlayback(url: staged)
            }
            phase = .ready(staged)
        }
    }

    private func downloadToDownloads(_ staged: URL) {
        note = nil
        do {
            let dest = try ChatFileResolver.saveToDownloads(staged: staged, displayName: name)
            savedURL = dest
            engine?.downloadedFilePaths[downloadKey] = dest
        } catch {
            note = "Không lưu được vào thư mục Downloads: \(error.localizedDescription)"
        }
    }

    private func saveAs(_ staged: URL) {
        note = nil
        Task {
            switch await ChatFileSavePanel.saveAs(staged: staged, displayName: name) {
            case .success(let chosen?):
                savedURL = chosen
                engine?.downloadedFilePaths[downloadKey] = chosen
            case .success(nil):
                break
            case .failure(let error):
                note = "Không lưu được tệp: \(error.localizedDescription)"
            }
        }
    }

    private func openElsewhere(_ staged: URL) {
        if CloudFiles.mayExecute(staged, displayName: name) {
            NSWorkspace.shared.activateFileViewerSelecting([staged])
            note = "Đã mở trong Finder vì tệp có thể chạy mã"
        } else {
            NSWorkspace.shared.open(staged)
        }
    }
}
