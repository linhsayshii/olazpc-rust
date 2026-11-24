import Foundation

/// Finds directories that SwiftPM copies into the target's resource bundle
/// (`resources: [.copy("JSModules"), .copy("Resources")]`).
///
/// `Bundle.module` alone breaks in a hand-assembled `.app` (its generated accessor
/// looks next to the bundle URL and otherwise at an absolute `.build` path), so the
/// app bundle's `Contents/Resources` is searched first; `scripts/make-app.sh` copies
/// `Olaz_Olaz.bundle` there.
enum ResourceLocator {
    static let resourceBundleName = "Olaz_Olaz.bundle"

    /// `<resource bundle>/<subdirectory>` (e.g. `"JSModules"`, `"Resources"`), or nil.
    static func url(forSubdirectory subdirectory: String) -> URL? {
        let fm = FileManager.default
        // A resource bundle's files sit either under Contents/Resources (what the swiftbuild
        // backend emits) or at its root (flat, what SwiftPM's native/llbuild backend emits).
        // Because this target copies a directory literally named `Resources/`, CFBundle's
        // `Bundle.resourceURL` mistakes `<bundle>/Resources` for a shallow bundle's resource
        // root on flat bundles — so search both `Bundle.resourceURL` and the bundle root itself.
        func candidateRoots(ofBundleAt url: URL) -> [URL] {
            guard fm.fileExists(atPath: url.path) else { return [] }
            var roots: [URL] = []
            if let res = Bundle(url: url)?.resourceURL { roots.append(res) }
            if !roots.contains(url) { roots.append(url) }
            return roots
        }
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(contentsOf: candidateRoots(ofBundleAt: res.appendingPathComponent(resourceBundleName)))
            candidates.append(res)
        }
        candidates.append(contentsOf: candidateRoots(ofBundleAt: Bundle.main.bundleURL.appendingPathComponent(resourceBundleName)))
        // Development / `swift test` fallback.
        if let res = Bundle.module.resourceURL { candidates.append(res) }
        candidates.append(Bundle.module.bundleURL)
        for base in candidates {
            let url = base.appendingPathComponent(subdirectory, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url
            }
        }
        return nil
    }

    /// A file inside a resource subdirectory, e.g. `url(for: "vendor/libsignal-protocol.js", in: "JSModules")`.
    static func url(for relativePath: String, in subdirectory: String) -> URL? {
        guard let dir = url(forSubdirectory: subdirectory) else { return nil }
        let url = dir.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
