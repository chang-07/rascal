import AppKit

/// A named color/font/density scheme. Themes are pure data so users (and
/// eventually a Theme Editor sheet) can author new ones.
struct Theme: Equatable {
    let id: String
    let name: String
    let appearance: Appearance

    let background: NSColor
    let sidebarBackground: NSColor
    let toolbarBackground: NSColor
    let pathBarBackground: NSColor
    let rowAlternate: NSColor
    let labelPrimary: NSColor
    let labelSecondary: NSColor
    let labelTertiary: NSColor
    let accent: NSColor
    let selectionBackground: NSColor

    let baseFontPointSize: CGFloat
    let rowHeight: CGFloat
    let monospaced: Bool

    enum Appearance: String { case light, dark, automatic }

    static let system = Theme(
        id: "system",
        name: "System",
        appearance: .automatic,
        background: .windowBackgroundColor,
        sidebarBackground: NSColor.windowBackgroundColor.withAlphaComponent(0.5),
        toolbarBackground: .windowBackgroundColor,
        pathBarBackground: NSColor.windowBackgroundColor.withAlphaComponent(0.5),
        rowAlternate: NSColor.alternatingContentBackgroundColors[1],
        labelPrimary: .labelColor,
        labelSecondary: .secondaryLabelColor,
        labelTertiary: .tertiaryLabelColor,
        accent: .controlAccentColor,
        selectionBackground: NSColor.controlAccentColor.withAlphaComponent(0.25),
        baseFontPointSize: 13,
        rowHeight: 22,
        monospaced: false
    )

    /// All available themes (built-ins + user JSON themes). Resolved by
    /// ThemeStore so themes are data-driven and user-extensible.
    static var all: [Theme] { ThemeStore.all() }
}

/// Singleton observable theme controller. Views observe `themeDidChange`
/// notification and re-apply colors. New panes/cells read the active theme
/// at creation time.
final class ThemeManager {
    static let shared = ThemeManager()

    static let themeDidChangeNotification = Notification.Name("FinderTwo.themeDidChange")

    private(set) var current: Theme = Theme.system
    /// Cached so views don't hit the Themes folder on every access. Refreshed
    /// by `reloadThemes()`.
    private(set) var available: [Theme] = ThemeStore.all()

    init() {
        if let id = UserDefaults.standard.string(forKey: "FinderTwo.theme"),
           let t = available.first(where: { $0.id == id }) {
            self.current = t
        }
    }

    func setTheme(id: String) {
        guard let t = available.first(where: { $0.id == id }) else { return }
        guard current.id != t.id else { return }    // skip redundant repaint
        current = t
        UserDefaults.standard.set(id, forKey: "FinderTwo.theme")
        applyAppearance()
        NotificationCenter.default.post(name: ThemeManager.themeDidChangeNotification, object: nil)
    }

    /// Re-scan the Themes folder (picks up newly added/edited JSON themes) and
    /// re-apply the active theme in case its definition changed.
    func reloadThemes() {
        available = ThemeStore.all()
        if let refreshed = available.first(where: { $0.id == current.id }) {
            current = refreshed
        }
        applyAppearance()
        NotificationCenter.default.post(name: ThemeManager.themeDidChangeNotification, object: nil)
    }

    func cycle() {
        let order = available
        guard !order.isEmpty else { return }
        let idx = order.firstIndex(where: { $0.id == current.id }) ?? 0
        let next = order[(idx + 1) % order.count]
        setTheme(id: next.id)
    }

    private func applyAppearance() {
        switch current.appearance {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:  NSApp.appearance = NSAppearance(named: .darkAqua)
        case .automatic: NSApp.appearance = nil
        }
    }

    // MARK: Effective values (theme + user Appearance overrides)

    /// Accent honoring the user's Settings override; falls back to the theme's.
    var effectiveAccent: NSColor {
        Settings.accent.color ?? current.accent
    }

    /// Row height from the density setting (overrides the theme's default).
    var effectiveRowHeight: CGFloat {
        Settings.density.rowHeight
    }

    /// Base font point size: theme base + user delta.
    var effectiveFontSize: CGFloat {
        max(9, current.baseFontPointSize + CGFloat(Settings.fontSizeDelta))
    }

    func font(_ weight: NSFont.Weight = .regular) -> NSFont {
        let size = effectiveFontSize
        if current.monospaced {
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }
}

/// Mix-in for any view that wants to update colors / fonts when the active
/// theme changes. Subscribers should call `subscribeToTheme()` once during
/// setup; they will receive an `applyTheme(_:)` callback immediately and on
/// every subsequent change.
@objc protocol ThemeObserving: AnyObject {
    @objc func applyTheme()
}

extension NSObject {
    /// Convenience: register `self` for theme updates and invoke once now.
    func subscribeToTheme(_ obj: ThemeObserving) {
        obj.applyTheme()
        NotificationCenter.default.addObserver(
            obj, selector: #selector(ThemeObserving.applyTheme),
            name: ThemeManager.themeDidChangeNotification, object: nil
        )
    }
}
