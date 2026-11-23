import AppKit

// `Olaz --engine-probe [login|main] [seconds]` runs the runtime harness;
// otherwise the SwiftUI app starts.
if CommandLine.arguments.contains("--engine-probe") {
    // Same data as the app: never run beside it (see InstanceLock).
    guard InstanceLock.acquire() else {
        FileHandle.standardError.write(Data("Olaz is already running on this data directory; quit it first.\n".utf8))
        exit(2)
    }
    MainActor.assumeIsolated {
        EngineProbe.run(arguments: Array(CommandLine.arguments.dropFirst()))
    }
} else {
    // Before anything opens cookies, WebKit storage or preferences: they are keyed by bundle id.
    MainActor.assumeIsolated { LegacyMigration.runIfNeeded() }
    // After the migration (it may still be moving the data folder), before anything opens the store or session.
    MainActor.assumeIsolated { InstanceLock.ensureSingleAppInstance() }
    OlazApp.main()
}
