import AppKit

/// A user-customizable numeric layout dimension.
///
/// Deliberately parallel to `ActionRegistry`'s shortcut customization: a stable
/// string id, a built-in default, and a clamp range. Keeping every dimension in
/// one registry lets the Layout settings pane be a single generic table of
/// steppers, exactly the way the Keyboard pane is one generic table of shortcut
/// recorders — instead of a bespoke control per dimension.
enum LayoutToken: String, CaseIterable {
    // Overlay finders (command palette, Find Files, Search Contents)
    case paletteWidth
    case paletteHeight
    case overlayRowHeight
    // Split-view geometry
    case sidebarWidth
    case paneMinWidth
    case extraPaneMinWidth
    case previewPaneWidth

    var title: String {
        switch self {
        case .paletteWidth:      return "Command palette width"
        case .paletteHeight:     return "Command palette height"
        case .overlayRowHeight:  return "Overlay row height"
        case .sidebarWidth:      return "Sidebar width"
        case .paneMinWidth:      return "Pane minimum width"
        case .extraPaneMinWidth: return "Extra pane minimum width"
        case .previewPaneWidth:  return "Preview pane width"
        }
    }

    /// Built-in value — matches what the code used before customization existed,
    /// so an untouched install looks identical.
    var defaultValue: CGFloat {
        switch self {
        case .paletteWidth:      return 640
        case .paletteHeight:     return 440
        case .overlayRowHeight:  return 36
        case .sidebarWidth:      return 165
        case .paneMinWidth:      return 360
        case .extraPaneMinWidth: return 280
        case .previewPaneWidth:  return 260
        }
    }

    /// Hard clamp. Values outside this are pinned, so a bad stored value (or a
    /// hand-edited defaults plist) can never render the app unusable.
    var range: ClosedRange<CGFloat> {
        switch self {
        case .paletteWidth:      return 420...1200
        case .paletteHeight:     return 280...1000
        case .overlayRowHeight:  return 24...56
        case .sidebarWidth:      return 130...400
        case .paneMinWidth:      return 240...800
        case .extraPaneMinWidth: return 200...600
        case .previewPaneWidth:  return 180...700
        }
    }

    /// Increment for the settings stepper.
    var step: CGFloat {
        switch self {
        case .overlayRowHeight: return 2
        default:                return 10
        }
    }
}

/// Resolves layout dimensions as "user override, else built-in default".
///
/// Mirrors `ActionRegistry.shortcut(for:)` / `setShortcut(_:forId:)` /
/// `isCustomized(_:)` but over a `[String: Double]` dictionary at
/// `"FinderTwo.layout"`.
///
/// Changing a value posts the same notification pair as `Settings`'
/// appearance path (`Settings.didChange` + `themeDidChangeNotification`), which
/// every chrome view already observes via `ThemeObserving` — so customization
/// relayouts the app live without introducing a new observer mechanism.
enum LayoutMetrics {
    private static let key = "FinderTwo.layout"

    /// Posted alongside the appearance notifications for consumers that want to
    /// react specifically to a layout change.
    static let didChange = Notification.Name("FinderTwo.layoutDidChange")

    private static var overrides: [String: Double] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
    }

    /// Memo of resolved values. `value(_:)` sits on hot paths (e.g. a table's
    /// per-row height), and reading UserDefaults re-deserializes the dictionary
    /// each call. Cleared by `notifyChanged()`, which is the only in-app writer.
    private static var cache: [String: CGFloat] = [:]

    /// Effective value: the user's override clamped to the token's range, or the
    /// built-in default when unset.
    static func value(_ token: LayoutToken) -> CGFloat {
        if let hit = cache[token.rawValue] { return hit }
        let resolved: CGFloat
        if let raw = overrides[token.rawValue] {
            resolved = clamp(CGFloat(raw), to: token.range)
        } else {
            resolved = token.defaultValue
        }
        cache[token.rawValue] = resolved
        return resolved
    }

    /// Set an override, or pass nil to clear it and fall back to the default.
    static func set(_ token: LayoutToken, _ newValue: CGFloat?) {
        var dict = overrides
        if let v = newValue {
            dict[token.rawValue] = Double(clamp(v, to: token.range))
        } else {
            dict.removeValue(forKey: token.rawValue)
        }
        UserDefaults.standard.set(dict, forKey: key)
        notifyChanged()
    }

    /// True when the token has a stored override (drives the per-row "Reset").
    static func isCustomized(_ token: LayoutToken) -> Bool {
        overrides[token.rawValue] != nil
    }

    static var hasAnyCustomization: Bool { !overrides.isEmpty }

    /// Clear every override — the "Reset Layout" button.
    static func resetAll() {
        UserDefaults.standard.removeObject(forKey: key)
        notifyChanged()
    }

    private static func clamp(_ v: CGFloat, to r: ClosedRange<CGFloat>) -> CGFloat {
        min(max(v, r.lowerBound), r.upperBound)
    }

    /// Post the same pair `Settings.notifyAppearance()` posts (it's private, so
    /// we replicate rather than call it): the general settings change plus the
    /// theme notification that drives every `ThemeObserving` view to re-apply.
    private static func notifyChanged() {
        cache.removeAll()
        let nc = NotificationCenter.default
        nc.post(name: didChange, object: nil)
        nc.post(name: Settings.didChange, object: nil)
        nc.post(name: ThemeManager.themeDidChangeNotification, object: nil)
    }
}
