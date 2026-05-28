import AppKit

/// Central, typed accessor for all user-tunable preferences (the ones the
/// Settings window exposes). Theme id, vim flag, hotbar order, and custom
/// shortcuts keep their existing stores (ThemeManager / VimMode / HotbarView /
/// ActionRegistry); this adds the General + Appearance prefs and a single
/// change notification panes can observe.
enum Settings {

    /// Fired whenever any setting here changes. Appearance-affecting changes
    /// also re-post ThemeManager.themeDidChangeNotification so existing
    /// ThemeObserving views refresh without extra wiring.
    static let didChange = Notification.Name("FinderTwo.settingsDidChange")

    private static let d = UserDefaults.standard

    // MARK: General

    enum DefaultLocation: String, CaseIterable {
        case lastSession, home, desktop, documents, downloads
        var label: String {
            switch self {
            case .lastSession: return "Last session"
            case .home: return "Home"
            case .desktop: return "Desktop"
            case .documents: return "Documents"
            case .downloads: return "Downloads"
            }
        }
        /// Concrete URL for the location, or nil for `.lastSession`.
        var url: URL? {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .lastSession: return nil
            case .home: return home
            case .desktop: return home.appendingPathComponent("Desktop")
            case .documents: return home.appendingPathComponent("Documents")
            case .downloads: return home.appendingPathComponent("Downloads")
            }
        }
    }

    static var defaultLocation: DefaultLocation {
        get { DefaultLocation(rawValue: d.string(forKey: "FinderTwo.defaultLocation") ?? "") ?? .lastSession }
        set { d.set(newValue.rawValue, forKey: "FinderTwo.defaultLocation"); notify() }
    }

    /// Whether to restore the previous session's windows/tabs on launch.
    static var restoreSession: Bool {
        get { d.object(forKey: "FinderTwo.restoreSession") as? Bool ?? true }
        set { d.set(newValue, forKey: "FinderTwo.restoreSession"); notify() }
    }

    static var showHiddenByDefault: Bool {
        get { d.bool(forKey: "FinderTwo.showHiddenByDefault") }
        set { d.set(newValue, forKey: "FinderTwo.showHiddenByDefault"); notify() }
    }

    enum DefaultView: String, CaseIterable {
        case list, columns
        var label: String { self == .list ? "List" : "Columns" }
    }
    static var defaultView: DefaultView {
        get { DefaultView(rawValue: d.string(forKey: "FinderTwo.defaultView") ?? "") ?? .list }
        set { d.set(newValue.rawValue, forKey: "FinderTwo.defaultView"); notify() }
    }

    // MARK: Appearance

    enum Density: String, CaseIterable {
        case compact, comfortable, spacious
        var label: String { rawValue.capitalized }
        var rowHeight: CGFloat {
            switch self {
            case .compact: return 20
            case .comfortable: return 24
            case .spacious: return 30
            }
        }
    }
    static var density: Density {
        get { Density(rawValue: d.string(forKey: "FinderTwo.density") ?? "") ?? .comfortable }
        set { d.set(newValue.rawValue, forKey: "FinderTwo.density"); notifyAppearance() }
    }

    /// Added to the active theme's base font point size. Range clamped -1…+4.
    static var fontSizeDelta: Int {
        get { d.object(forKey: "FinderTwo.fontSizeDelta") as? Int ?? 0 }
        set { d.set(max(-1, min(4, newValue)), forKey: "FinderTwo.fontSizeDelta"); notifyAppearance() }
    }

    enum Accent: String, CaseIterable {
        case system, graphite, red, orange, yellow, green, blue, purple, pink
        var label: String { rawValue.capitalized }
        /// nil = follow the theme/system accent.
        var color: NSColor? {
            switch self {
            case .system: return nil
            case .graphite: return .systemGray
            case .red: return .systemRed
            case .orange: return .systemOrange
            case .yellow: return .systemYellow
            case .green: return .systemGreen
            case .blue: return .systemBlue
            case .purple: return .systemPurple
            case .pink: return .systemPink
            }
        }
    }
    static var accent: Accent {
        get { Accent(rawValue: d.string(forKey: "FinderTwo.accent") ?? "") ?? .system }
        set { d.set(newValue.rawValue, forKey: "FinderTwo.accent"); notifyAppearance() }
    }

    // MARK: Behavior

    static var typeAheadEnabled: Bool {
        get { d.object(forKey: "FinderTwo.typeAhead") as? Bool ?? true }
        set { d.set(newValue, forKey: "FinderTwo.typeAhead"); notify() }
    }

    // MARK: Notifications

    private static func notify() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }
    /// For appearance prefs: also refresh all ThemeObserving views.
    private static func notifyAppearance() {
        notify()
        NotificationCenter.default.post(name: ThemeManager.themeDidChangeNotification, object: nil)
    }

    /// Reset every Settings-owned key (does not touch theme/vim/shortcuts/hotbar).
    static func resetGeneralAndAppearance() {
        for key in ["FinderTwo.defaultLocation", "FinderTwo.restoreSession",
                    "FinderTwo.showHiddenByDefault", "FinderTwo.defaultView",
                    "FinderTwo.density", "FinderTwo.fontSizeDelta", "FinderTwo.accent",
                    "FinderTwo.typeAhead"] {
            d.removeObject(forKey: key)
        }
        notifyAppearance()
    }
}
