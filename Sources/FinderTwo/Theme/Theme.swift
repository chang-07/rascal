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

    static let midnight = Theme(
        id: "midnight",
        name: "Midnight",
        appearance: .dark,
        background: NSColor(red: 0.08, green: 0.09, blue: 0.13, alpha: 1),
        sidebarBackground: NSColor(red: 0.06, green: 0.07, blue: 0.11, alpha: 1),
        toolbarBackground: NSColor(red: 0.10, green: 0.11, blue: 0.15, alpha: 1),
        pathBarBackground: NSColor(red: 0.09, green: 0.10, blue: 0.14, alpha: 1),
        rowAlternate: NSColor(red: 0.11, green: 0.12, blue: 0.16, alpha: 1),
        labelPrimary: NSColor(white: 0.92, alpha: 1),
        labelSecondary: NSColor(white: 0.62, alpha: 1),
        labelTertiary: NSColor(white: 0.42, alpha: 1),
        accent: NSColor(red: 0.55, green: 0.78, blue: 1.0, alpha: 1),
        selectionBackground: NSColor(red: 0.20, green: 0.40, blue: 0.85, alpha: 0.35),
        baseFontPointSize: 13,
        rowHeight: 22,
        monospaced: false
    )

    static let sepia = Theme(
        id: "sepia",
        name: "Sepia",
        appearance: .light,
        background: NSColor(red: 0.97, green: 0.94, blue: 0.88, alpha: 1),
        sidebarBackground: NSColor(red: 0.94, green: 0.90, blue: 0.83, alpha: 1),
        toolbarBackground: NSColor(red: 0.95, green: 0.92, blue: 0.85, alpha: 1),
        pathBarBackground: NSColor(red: 0.94, green: 0.91, blue: 0.84, alpha: 1),
        rowAlternate: NSColor(red: 0.94, green: 0.91, blue: 0.84, alpha: 1),
        labelPrimary: NSColor(red: 0.25, green: 0.20, blue: 0.10, alpha: 1),
        labelSecondary: NSColor(red: 0.45, green: 0.38, blue: 0.25, alpha: 1),
        labelTertiary: NSColor(red: 0.65, green: 0.58, blue: 0.45, alpha: 1),
        accent: NSColor(red: 0.50, green: 0.30, blue: 0.10, alpha: 1),
        selectionBackground: NSColor(red: 0.85, green: 0.65, blue: 0.30, alpha: 0.40),
        baseFontPointSize: 14,
        rowHeight: 24,
        monospaced: false
    )

    static let hacker = Theme(
        id: "hacker",
        name: "Hacker (monospaced)",
        appearance: .dark,
        background: NSColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1),
        sidebarBackground: NSColor(red: 0.03, green: 0.03, blue: 0.03, alpha: 1),
        toolbarBackground: NSColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1),
        pathBarBackground: NSColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1),
        rowAlternate: NSColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1),
        labelPrimary: NSColor(red: 0.30, green: 1.00, blue: 0.55, alpha: 1),
        labelSecondary: NSColor(red: 0.25, green: 0.75, blue: 0.40, alpha: 1),
        labelTertiary: NSColor(red: 0.20, green: 0.55, blue: 0.30, alpha: 1),
        accent: NSColor(red: 0.35, green: 1.0, blue: 0.65, alpha: 1),
        selectionBackground: NSColor(red: 0.15, green: 0.40, blue: 0.22, alpha: 0.55),
        baseFontPointSize: 13,
        rowHeight: 22,
        monospaced: true
    )

    static let all: [Theme] = [.system, .midnight, .sepia, .hacker]
}

/// Singleton observable theme controller. Views observe `themeDidChange`
/// notification and re-apply colors. New panes/cells read the active theme
/// at creation time.
final class ThemeManager {
    static let shared = ThemeManager()

    static let themeDidChangeNotification = Notification.Name("FinderTwo.themeDidChange")

    private(set) var current: Theme = Theme.system

    init() {
        if let id = UserDefaults.standard.string(forKey: "FinderTwo.theme"),
           let t = Theme.all.first(where: { $0.id == id }) {
            self.current = t
        }
    }

    func setTheme(id: String) {
        guard let t = Theme.all.first(where: { $0.id == id }) else { return }
        guard current.id != t.id else { return }    // skip redundant repaint
        current = t
        UserDefaults.standard.set(id, forKey: "FinderTwo.theme")
        applyAppearance()
        NotificationCenter.default.post(name: ThemeManager.themeDidChangeNotification, object: nil)
    }

    func cycle() {
        let order = Theme.all
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
