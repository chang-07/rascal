import Foundation
import CoreServices

/// Discovers existing tag names + colors used anywhere on the user's machine
/// (via Spotlight `kMDItemUserTags`) and queries files for each tag.
///
/// We use Spotlight (MDQuery) rather than walking the filesystem because
/// macOS already indexes tags, so this is millisecond-fast even with thousands
/// of tagged files.
enum TagIndex {

    struct TagSummary: Hashable {
        let tag: Tags.Tag
        let count: Int
    }

    /// Collect every distinct user tag currently present on this system.
    static func allTagSummaries(completion: @escaping ([TagSummary]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Spotlight query for "any file that has a user tag set".
            let query = "kMDItemUserTags == '*'"
            let urls = runMDFind(query: query, limit: 5000)
            var bucket: [String: (Tags.Color, Int)] = [:]
            for u in urls {
                for t in Tags.read(u) {
                    if let existing = bucket[t.name] {
                        bucket[t.name] = (existing.0, existing.1 + 1)
                    } else {
                        bucket[t.name] = (t.color, 1)
                    }
                }
            }
            let summaries = bucket
                .map { TagSummary(tag: Tags.Tag(name: $0.key, color: $0.value.0), count: $0.value.1) }
                .sorted { $0.tag.name.localizedStandardCompare($1.tag.name) == .orderedAscending }
            DispatchQueue.main.async { completion(summaries) }
        }
    }

    /// Files tagged with `name`. Uses Spotlight; returns paths.
    static func filesWithTag(_ name: String, completion: @escaping ([URL]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let safe = name.replacingOccurrences(of: "\"", with: "\\\"")
            let q = "kMDItemUserTags == \"\(safe)\""
            let urls = runMDFind(query: q, limit: 5000)
            DispatchQueue.main.async { completion(urls) }
        }
    }

    /// Run `mdfind` for a Spotlight query string and return matched URLs,
    /// capped at `limit`.
    private static func runMDFind(query: String, limit: Int) -> [URL] {
        let p = Process()
        p.launchPath = "/usr/bin/mdfind"
        p.arguments = [query]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let s = String(data: data, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").prefix(limit).map { URL(fileURLWithPath: String($0)) }
    }
}
