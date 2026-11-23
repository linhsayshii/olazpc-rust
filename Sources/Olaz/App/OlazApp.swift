import AppKit
import SwiftUI

@MainActor
final class OlazAppDelegate: NSObject, NSApplicationDelegate {
    var openMainWindow: (() -> Void)?
    var onLaunch: (() -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.setActivationPolicy(.regular)
        onLaunch?()
        DispatchQueue.main.async { [weak self] in
            if NSApp.windows.filter({ $0.canBecomeMain && $0.isVisible }).isEmpty {
                self?.openMainWindow?()
            }
            NSApp.activate()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openMainWindow?()
        }
        NSApp.activate()
        return true
    }
}

struct OlazApp: App {
    @NSApplicationDelegateAdaptor(OlazAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var engine = ZaloEngine()
    @State private var shell = ShellModel()

    var body: some Scene {
        let _ = {
            let open = openWindow
            let eng = engine
            appDelegate.openMainWindow = { open(id: "main") }
            appDelegate.onLaunch = { eng.start() }
        }()
        Window(AppBrand.name, id: "main") {
            RootView()
                .olazAppearance(engine: engine, shell: shell)
                // While the inspector shows, the window may not get narrower than what keeps the chat usable beside it.
                .frame(minWidth: shell.holdsInspectorRoom ? InspectorRoom.windowMinWidthWithInspector : InspectorRoom.windowMinWidth, minHeight: 620)
                .task {
                    engine.start()
                    await EngineProbe.runUISmokeIfRequested(engine: engine, shell: shell)
                    await PerfProbe.runIfRequested(engine: engine, shell: shell)
                }
        }
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .commands {
            OlazCommands(engine: engine, shell: shell)
            CommandGroup(before: .windowList) {
                Button("Cửa sổ chính") { openWindow(id: "main") }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
            }
            CommandMenu("Tài khoản") {
                Button("Lấy mã QR mới") { engine.refreshQR() }
                    .keyboardShortcut("R", modifiers: [.command, .shift])
                    .disabled(!engine.phase.isLogin)
                Button("Đăng xuất") { engine.logOut() }
                    .keyboardShortcut("L", modifiers: [.command, .shift])
                    .disabled(engine.profile == nil)
            }
            CommandMenu("Nhà phát triển") {
                Toggle("Hiện renderer Zalo chính thức", isOn: $engine.isDebugRendererVisible)
            }
        }

        Settings {
            SettingsView()
                .olazAppearance(engine: engine, shell: shell)
        }
    }
}

// MARK: - Appearance

/// Applies what Settings ▸ Giao diện picks (mode, accent, message text size, Dock icon) plus the shared environment, so the
/// main window and the Settings window always look the same and react live.
private struct OlazAppearance: ViewModifier {
    let engine: ZaloEngine
    let shell: ShellModel
    @AppStorage("olaz.appearance") private var appearance = Appearance.system
    @AppStorage(OlazPrefs.accent) private var accent = OlazAccent.blue
    @AppStorage(OlazPrefs.textSize) private var textSize = OlazTextSize.standard
    @AppStorage(OlazPrefs.appIcon) private var appIcon = OlazAppIcon.c

    func body(content: Content) -> some View {
        content
            .environment(engine)
            .environment(shell)
            .environment(\.locale, Locale(identifier: "vi_VN"))
            .environment(\.olazTextScale, textSize.scale)
            .tint(accent.color)
            .preferredColorScheme(appearance.colorScheme)
            // `initial` restores the chosen Dock icon on launch; the Settings window repeats it harmlessly.
            .onChange(of: appIcon, initial: true) { _, icon in icon.applyToDock() }
    }
}

extension View {
    /// Root styling and environment shared by every window of the app (see `OlazAppearance`).
    func olazAppearance(engine: ZaloEngine, shell: ShellModel) -> some View {
        modifier(OlazAppearance(engine: engine, shell: shell))
    }
}

extension OlazAppIcon {
    /// Shows this icon in the Dock. The primary icon (`c`) is the bundle's own, restored by clearing the override; outside a
    /// bundle (`swift run`) there is none to restore, so the image is set instead. The override lasts until the app quits.
    @MainActor func applyToDock() {
        let isBundled = Bundle.main.bundleURL.pathExtension == "app"
        NSApp.applicationIconImage = self == .c && isBundled ? nil : image
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Theo hệ thống"
        case .light: "Sáng"
        case .dark: "Tối"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
