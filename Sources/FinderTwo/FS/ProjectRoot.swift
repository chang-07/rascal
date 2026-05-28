import AppKit

/// Detects the "project root" for a path by walking up looking for common
/// project markers, and opens projects in installed code editors.
enum ProjectRoot {

    /// Marker files/dirs that signal a project root, in rough priority order.
    static let markers = [
        ".git", "package.json", "Cargo.toml", "go.mod", "pyproject.toml",
        "Package.swift", "pom.xml", "build.gradle", "build.gradle.kts",
        ".hg", "Gemfile", "requirements.txt", "composer.json", "CMakeLists.txt",
        "Makefile", ".project", "deno.json"
    ]

    /// Walk up from `url` (file or dir) to the nearest ancestor containing a
    /// project marker. Returns nil if none found before the filesystem root.
    static func find(for url: URL) -> URL? {
        var dir = url.standardizedFileURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), !isDir.boolValue {
            dir = dir.deletingLastPathComponent()
        }
        let fm = FileManager.default
        while dir.pathComponents.count > 1 {
            for marker in markers {
                if fm.fileExists(atPath: dir.appendingPathComponent(marker).path) {
                    return dir
                }
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}

/// Known code editors we can "Open in…". Detection is by bundle identifier so
/// it works regardless of install location.
enum Editor: String, CaseIterable {
    case cursor, vscode, zed, sublime, xcode

    var displayName: String {
        switch self {
        case .cursor: return "Cursor"
        case .vscode: return "VS Code"
        case .zed: return "Zed"
        case .sublime: return "Sublime Text"
        case .xcode: return "Xcode"
        }
    }

    /// Candidate bundle ids (some apps have shipped multiple over time).
    var bundleIds: [String] {
        switch self {
        case .cursor: return ["com.todesktop.230313mzl4w4u92", "com.cursor.Cursor"]
        case .vscode: return ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
        case .zed: return ["dev.zed.Zed", "dev.zed.Zed-Preview"]
        case .sublime: return ["com.sublimetext.4", "com.sublimetext.3"]
        case .xcode: return ["com.apple.dt.Xcode"]
        }
    }

    /// The installed app URL, if any.
    var appURL: URL? {
        for id in bundleIds {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return url
            }
        }
        return nil
    }

    /// Editors currently installed, in preference order.
    static var installed: [Editor] {
        allCases.filter { $0.appURL != nil }
    }

    /// Open `url` (a folder, ideally a project root) in this editor.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let app = appURL else { return false }
        let cfg = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: cfg, completionHandler: nil)
        return true
    }
}
