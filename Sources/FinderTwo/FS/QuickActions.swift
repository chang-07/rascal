import AppKit
import PDFKit

/// Lightweight, no-AI "Quick Actions" on the selection — image rotate/convert
/// via `sips`, "Create PDF" via PDFKit, and running a user macOS Shortcut via
/// the `shortcuts` CLI.
enum QuickActions {
    static let imageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp"]

    static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Rotate images in place. `clockwise` 90° (right) or counter-clockwise (left).
    @discardableResult
    static func rotate(_ urls: [URL], clockwise: Bool) -> Bool {
        let degrees = clockwise ? "90" : "270"
        var allOK = true
        for u in urls where isImage(u) {
            if !run("/usr/bin/sips", ["-r", degrees, u.path]) { allOK = false }
        }
        return allOK
    }

    /// Convert images to `format` ("png" / "jpeg" / "heic"), writing a sibling
    /// file with the new extension. Returns the created URLs.
    @discardableResult
    static func convert(_ urls: [URL], to format: String) -> [URL] {
        let ext = format == "jpeg" ? "jpg" : format
        var created: [URL] = []
        for u in urls where isImage(u) {
            let out = FileOps.uniqueDestination(u.deletingPathExtension().appendingPathExtension(ext))
            if run("/usr/bin/sips", ["-s", "format", format, u.path, "--out", out.path]) {
                created.append(out)
            }
        }
        return created
    }

    /// Combine the given images into a single multi-page PDF next to the first
    /// one. Returns the PDF URL, or nil on failure.
    @discardableResult
    static func createPDF(from urls: [URL]) -> URL? {
        let images = urls.filter { isImage($0) }
        guard let first = images.first else { return nil }
        let doc = PDFDocument()
        for u in images {
            guard let img = NSImage(contentsOf: u), let page = PDFPage(image: img) else { continue }
            doc.insert(page, at: doc.pageCount)
        }
        guard doc.pageCount > 0 else { return nil }
        let out = FileOps.uniqueDestination(
            first.deletingLastPathComponent().appendingPathComponent("Combined.pdf"))
        return doc.write(to: out) ? out : nil
    }

    // MARK: macOS Shortcuts

    /// Names of the user's installed Shortcuts (via the `shortcuts` CLI).
    static func installedShortcuts() -> [String] {
        guard let out = capture("/usr/bin/shortcuts", ["list"]) else { return [] }
        return out.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
    }

    /// Run a Shortcut, passing each selected file as input.
    @discardableResult
    static func runShortcut(named name: String, on urls: [URL]) -> Bool {
        var args = ["run", name]
        for u in urls { args += ["-i", u.path] }
        return run("/usr/bin/shortcuts", args)
    }

    // MARK: Process helpers

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: tool) else { return false }
        let p = Process()
        p.launchPath = tool
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private static func capture(_ tool: String, _ args: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: tool) else { return nil }
        let p = Process()
        p.launchPath = tool
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
