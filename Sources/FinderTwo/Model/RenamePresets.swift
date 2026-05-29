import Foundation

/// A saved batch-rename configuration (find/replace + template + numbering).
struct RenamePreset: Equatable {
    var name: String
    var find: String
    var repl: String
    var template: String
    var useRegex: Bool
    var start: Int
    var pad: Int

    fileprivate var dict: [String: String] {
        ["name": name, "find": find, "repl": repl, "template": template,
         "useRegex": useRegex ? "1" : "0", "start": String(start), "pad": String(pad)]
    }
    fileprivate init?(dict: [String: String]) {
        guard let name = dict["name"] else { return nil }
        self.name = name
        self.find = dict["find"] ?? ""
        self.repl = dict["repl"] ?? ""
        self.template = dict["template"] ?? ""
        self.useRegex = dict["useRegex"] == "1"
        self.start = Int(dict["start"] ?? "1") ?? 1
        self.pad = Int(dict["pad"] ?? "0") ?? 0
    }
    init(name: String, find: String, repl: String, template: String,
         useRegex: Bool, start: Int, pad: Int) {
        self.name = name; self.find = find; self.repl = repl; self.template = template
        self.useRegex = useRegex; self.start = start; self.pad = pad
    }
}

enum RenamePresets {
    static let didChange = Notification.Name("FinderTwo.renamePresetsDidChange")
    private static let key = "FinderTwo.renamePresets.v1"
    private static let d = UserDefaults.standard

    static func all() -> [RenamePreset] {
        (d.array(forKey: key) as? [[String: String]] ?? []).compactMap { RenamePreset(dict: $0) }
    }
    static func find(name: String) -> RenamePreset? { all().first { $0.name == name } }

    /// Add or replace by name.
    static func upsert(_ preset: RenamePreset) {
        var list = all().filter { $0.name != preset.name }
        list.append(preset)
        list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        save(list)
    }
    static func remove(name: String) { save(all().filter { $0.name != name }) }

    private static func save(_ list: [RenamePreset]) {
        d.set(list.map { $0.dict }, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
