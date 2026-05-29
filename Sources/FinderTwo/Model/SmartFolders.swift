import Foundation

/// A saved search ("smart folder"): a named query that re-runs on demand and
/// surfaces matching files as a synthetic listing in the file list — the same
/// mechanism the Tags and Recents sidebar entries use. Persisted in
/// UserDefaults as an ordered array of dictionaries.
struct SmartFolder: Equatable {
    let id: String
    var name: String
    /// Filename substring to match (case/diacritic-insensitive). Empty = any.
    var nameContains: String
    /// Full-text content substring to match. Empty = don't search content.
    var contentContains: String
    /// Subtree to scope the search to. Empty = whole Spotlight index.
    var rootPath: String

    var root: URL? { rootPath.isEmpty ? nil : URL(fileURLWithPath: rootPath) }

    /// True when the query would match nothing because every field is blank.
    var isEmptyQuery: Bool {
        nameContains.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        contentContains.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    fileprivate var dict: [String: String] {
        ["id": id, "name": name, "nameContains": nameContains,
         "contentContains": contentContains, "rootPath": rootPath]
    }
    fileprivate init?(dict: [String: String]) {
        guard let id = dict["id"], let name = dict["name"] else { return nil }
        self.id = id
        self.name = name
        self.nameContains = dict["nameContains"] ?? ""
        self.contentContains = dict["contentContains"] ?? ""
        self.rootPath = dict["rootPath"] ?? ""
    }
    init(id: String, name: String, nameContains: String,
         contentContains: String, rootPath: String) {
        self.id = id; self.name = name; self.nameContains = nameContains
        self.contentContains = contentContains; self.rootPath = rootPath
    }
}

enum SmartFolders {
    static let didChange = Notification.Name("FinderTwo.smartFoldersDidChange")
    private static let key = "FinderTwo.smartFolders"
    private static let d = UserDefaults.standard

    static func all() -> [SmartFolder] {
        let raw = d.array(forKey: key) as? [[String: String]] ?? []
        return raw.compactMap { SmartFolder(dict: $0) }
    }

    static func find(id: String) -> SmartFolder? { all().first { $0.id == id } }

    /// Add or replace (by id) and persist.
    static func upsert(_ folder: SmartFolder) {
        var list = all().filter { $0.id != folder.id }
        list.append(folder)
        save(list)
    }

    static func remove(id: String) {
        save(all().filter { $0.id != id })
    }

    private static func save(_ list: [SmartFolder]) {
        d.set(list.map { $0.dict }, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Derive a stable, unique id from a display name (no Date/random in this
    /// environment — disambiguate against existing ids with a counter).
    static func makeId(for name: String) -> String {
        let base = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let slug = base.isEmpty ? "search" : base
        let existing = Set(all().map { $0.id })
        if !existing.contains(slug) { return slug }
        var i = 2
        while existing.contains("\(slug)-\(i)") { i += 1 }
        return "\(slug)-\(i)"
    }

    // MARK: Query execution

    /// Run the saved query off the main thread, delivering matches on main.
    static func run(_ folder: SmartFolder, completion: @escaping ([URL]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let urls = runSync(folder)
            DispatchQueue.main.async { completion(urls) }
        }
    }

    /// Synchronous Spotlight query. Exposed for tests. Builds an `mdfind`
    /// expression from the non-empty fields and ANDs them together.
    static func runSync(_ folder: SmartFolder, limit: Int = 2000) -> [URL] {
        var clauses: [String] = []
        let nameQ = folder.nameContains.trimmingCharacters(in: .whitespacesAndNewlines)
        let contentQ = folder.contentContains.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nameQ.isEmpty { clauses.append("kMDItemFSName == \"*\(escape(nameQ))*\"cd") }
        if !contentQ.isEmpty { clauses.append("kMDItemTextContent == \"*\(escape(contentQ))*\"cd") }
        guard !clauses.isEmpty else { return [] }
        let query = clauses.joined(separator: " && ")
        return TagIndex.runMDFind(query: query, limit: limit,
                                  onlyIn: folder.rootPath.isEmpty ? nil : folder.rootPath)
    }

    /// Escape characters that would break out of the mdfind quoted value.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "*", with: "")   // wildcards are ours, not the user's
    }
}
