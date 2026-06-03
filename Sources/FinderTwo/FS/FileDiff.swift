import Foundation

/// Unified text diff of two files via `/usr/bin/diff -u`.
enum FileDiff {
    /// Returns the unified diff. "" means the files are identical; nil means
    /// diff failed (e.g. a binary file or a read error).
    static func unified(_ a: URL, _ b: URL) -> String? {
        let p = Process()
        p.launchPath = "/usr/bin/diff"
        p.arguments = ["-u", a.path, b.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        // diff exit status: 0 = identical, 1 = differences, 2 = trouble.
        if p.terminationStatus == 2 { return nil }
        let text = String(data: data, encoding: .utf8) ?? ""
        // `diff` reports binary files as a one-line "Binary files … differ" on
        // stdout (exit 1), not a unified diff — surface it as "can't compare".
        if text.hasPrefix("Binary files ") { return nil }
        return text
    }
}
