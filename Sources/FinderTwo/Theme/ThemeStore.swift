import AppKit

/// Source of all themes: compiled-in built-ins (as data-driven specs) plus any
/// user JSON themes dropped into the Themes folder. A user theme whose `id`
/// matches a built-in overrides it, so the built-ins double as editable
/// templates.
enum ThemeStore {

    // MARK: Built-in specs (data, not hardcoded NSColors)

    static let builtInSpecs: [ThemeSpec] = [
        // Rascal's signature themes — matched to the landing page (warm white &
        // orange in light; a brown-black + cream + orange dark counterpart).
        ThemeSpec(id: "rascal-light", name: "Rascal Light", appearance: "light",
                  background: "#FFFBF6", sidebarBackground: "#FFF3E7", toolbarBackground: "#FFF7EF",
                  pathBarBackground: "#FFF3E7", rowAlternate: "#FFF5EB", labelPrimary: "#241A12",
                  labelSecondary: "#7A6A59", labelTertiary: "#AC9883", accent: "#FF6600",
                  selectionBackground: "#FF660033", baseFontPointSize: 13, rowHeight: 24),
        ThemeSpec(id: "rascal-dark", name: "Rascal Dark", appearance: "dark",
                  background: "#1E1611", sidebarBackground: "#17110B", toolbarBackground: "#251B12",
                  pathBarBackground: "#211711", rowAlternate: "#2A1E14", labelPrimary: "#FFE9D4",
                  labelSecondary: "#C9B6A2", labelTertiary: "#8A7762", accent: "#FF8A33",
                  selectionBackground: "#FF8A3340", baseFontPointSize: 13, rowHeight: 24),
        ThemeSpec(id: "midnight", name: "Midnight", appearance: "dark",
                  background: "#141826", sidebarBackground: "#0F1320", toolbarBackground: "#1A1F30",
                  pathBarBackground: "#161B2A", rowAlternate: "#1E2436", labelPrimary: "#E6E9F0",
                  labelSecondary: "#9AA3B8", labelTertiary: "#5E6678", accent: "#6FB7FF",
                  selectionBackground: "#2F5BD459"),
        ThemeSpec(id: "sepia", name: "Sepia", appearance: "light",
                  background: "#F7F1E3", sidebarBackground: "#EFE6D2", toolbarBackground: "#F2EAD8",
                  pathBarBackground: "#EEE5D0", rowAlternate: "#EFE6D2", labelPrimary: "#40341A",
                  labelSecondary: "#73603F", labelTertiary: "#A89372", accent: "#9A5B2E",
                  selectionBackground: "#D9A84D66", baseFontPointSize: 14, rowHeight: 24),
        ThemeSpec(id: "hacker", name: "Hacker (monospaced)", appearance: "dark",
                  background: "#060606", sidebarBackground: "#050505", toolbarBackground: "#0A0A0A",
                  pathBarBackground: "#0A0A0A", rowAlternate: "#111111", labelPrimary: "#46FF8C",
                  labelSecondary: "#36C46A", labelTertiary: "#2A8C4D", accent: "#5AFFA6",
                  selectionBackground: "#266B3A8C", monospaced: true),
        ThemeSpec(id: "nord", name: "Nord", appearance: "dark",
                  background: "#2E3440", sidebarBackground: "#272C36", toolbarBackground: "#3B4252",
                  pathBarBackground: "#2E3440", rowAlternate: "#3B4252", labelPrimary: "#ECEFF4",
                  labelSecondary: "#D8DEE9", labelTertiary: "#7B8494", accent: "#88C0D0",
                  selectionBackground: "#5E81AC66"),
        ThemeSpec(id: "dracula", name: "Dracula", appearance: "dark",
                  background: "#282A36", sidebarBackground: "#21222C", toolbarBackground: "#343746",
                  pathBarBackground: "#282A36", rowAlternate: "#343746", labelPrimary: "#F8F8F2",
                  labelSecondary: "#C6C6C0", labelTertiary: "#6272A4", accent: "#BD93F9",
                  selectionBackground: "#44475A99"),
        ThemeSpec(id: "solarized-light", name: "Solarized Light", appearance: "light",
                  background: "#FDF6E3", sidebarBackground: "#EEE8D5", toolbarBackground: "#FDF6E3",
                  pathBarBackground: "#EEE8D5", rowAlternate: "#EEE8D5", labelPrimary: "#586E75",
                  labelSecondary: "#657B83", labelTertiary: "#93A1A1", accent: "#268BD2",
                  selectionBackground: "#268BD233"),
        ThemeSpec(id: "solarized-dark", name: "Solarized Dark", appearance: "dark",
                  background: "#002B36", sidebarBackground: "#073642", toolbarBackground: "#002B36",
                  pathBarBackground: "#073642", rowAlternate: "#073642", labelPrimary: "#93A1A1",
                  labelSecondary: "#839496", labelTertiary: "#586E75", accent: "#2AA198",
                  selectionBackground: "#268BD24D"),
        ThemeSpec(id: "high-contrast", name: "High Contrast", appearance: "dark",
                  background: "#000000", sidebarBackground: "#000000", toolbarBackground: "#0A0A0A",
                  pathBarBackground: "#0A0A0A", rowAlternate: "#151515", labelPrimary: "#FFFFFF",
                  labelSecondary: "#D0D0D0", labelTertiary: "#9A9A9A", accent: "#FFD400",
                  selectionBackground: "#FFD40055"),
        ThemeSpec(id: "ocean", name: "Ocean", appearance: "light",
                  background: "#F0F6F8", sidebarBackground: "#DCEAEF", toolbarBackground: "#E8F2F5",
                  pathBarBackground: "#DCEAEF", rowAlternate: "#E2EEF1", labelPrimary: "#14323B",
                  labelSecondary: "#2F5763", labelTertiary: "#6F95A0", accent: "#0E7C86",
                  selectionBackground: "#2BB7C24D"),
        ThemeSpec(id: "cyberpunk", name: "Cyberpunk", appearance: "dark",
                  background: "#1A0B2E", sidebarBackground: "#120621", toolbarBackground: "#230F3B",
                  pathBarBackground: "#1A0B2E", rowAlternate: "#2B1348", labelPrimary: "#FF007F",
                  labelSecondary: "#00F0FF", labelTertiary: "#BC00DD", accent: "#00F0FF",
                  selectionBackground: "#00F0FF44"),
        ThemeSpec(id: "gruvbox", name: "Gruvbox", appearance: "dark",
                  background: "#282828", sidebarBackground: "#1D2021", toolbarBackground: "#3C3836",
                  pathBarBackground: "#282828", rowAlternate: "#32302F", labelPrimary: "#EBDBB2",
                  labelSecondary: "#A89984", labelTertiary: "#7C6F64", accent: "#D79921",
                  selectionBackground: "#D7992144"),
        ThemeSpec(id: "sage", name: "Sage", appearance: "light",
                  background: "#F4F7F5", sidebarBackground: "#E3EAE5", toolbarBackground: "#ECF1EE",
                  pathBarBackground: "#E3EAE5", rowAlternate: "#E8EFEA", labelPrimary: "#1E352F",
                  labelSecondary: "#3B5E55", labelTertiary: "#6A8D83", accent: "#2A6F54",
                  selectionBackground: "#2A6F5433"),
    ]

    /// System (dynamic AppKit colors) + the built-in specs.
    static func builtIns() -> [Theme] { [Theme.system] + builtInSpecs.map(Theme.init(spec:)) }

    // MARK: User themes (portable JSON files)

    static var themesDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("FinderTwo/Themes", isDirectory: true)
    }

    @discardableResult
    static func ensureDirectory() -> URL {
        try? FileManager.default.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
        return themesDirectory
    }

    /// Decode every `*.json` theme in `dir` (defaults to the Themes folder).
    static func userThemes(in dir: URL? = nil) -> [Theme] {
        let folder = dir ?? themesDirectory
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url -> Theme? in
                guard let data = try? Data(contentsOf: url),
                      let spec = decodeSpec(data) else { return nil }
                return Theme(spec: spec)
            }
    }

    /// Built-ins + user themes (user id overrides built-in, keeping order).
    static func all() -> [Theme] {
        var byId: [String: Theme] = [:]
        var order: [String] = []
        for t in builtIns() { if byId[t.id] == nil { order.append(t.id) }; byId[t.id] = t }
        for t in userThemes() { if byId[t.id] == nil { order.append(t.id) }; byId[t.id] = t }
        return order.compactMap { byId[$0] }
    }

    static func decodeSpec(_ data: Data) -> ThemeSpec? {
        try? JSONDecoder().decode(ThemeSpec.self, from: data)
    }

    /// Write a theme to `<Themes>/<id>.json` as a starting point for editing.
    @discardableResult
    static func export(_ theme: Theme, to dir: URL? = nil) -> URL? {
        let folder = dir ?? ensureDirectory()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(theme.spec) else { return nil }
        let url = folder.appendingPathComponent("\(theme.id).json")
        return (try? data.write(to: url)) != nil ? url : nil
    }
}
