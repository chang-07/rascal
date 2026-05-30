import AppKit

/// Shared theming helpers so every surface picks up the active theme with one
/// line instead of hand-rolling colors. The two reusable pieces are a selection
/// row view (renders the theme's `selectionBackground`) and a window themer.
enum ThemeChrome {

    private static var current: Theme { ThemeManager.shared.current }
    static var isSystem: Bool { current.id == "system" }

    static var background: NSColor { isSystem ? .windowBackgroundColor : current.background }
    static var primary: NSColor    { isSystem ? .labelColor          : current.labelPrimary }
    static var secondary: NSColor  { isSystem ? .secondaryLabelColor : current.labelSecondary }
    static var tertiary: NSColor   { isSystem ? .tertiaryLabelColor  : current.labelTertiary }

    static var appearance: NSAppearance? {
        switch current.appearance {
        case .light: return NSAppearance(named: .aqua)
        case .dark:  return NSAppearance(named: .darkAqua)
        case .automatic: return nil
        }
    }

    /// Theme a window's background + control appearance to match the active
    /// theme. With the appearance set, the system label/control colors resolve
    /// correctly (light vs dark), and the background gives the warm themed
    /// surface. Safe to call repeatedly.
    static func apply(to window: NSWindow?) {
        guard let window else { return }
        window.appearance = appearance
        window.backgroundColor = background
    }

    /// Recolor a set of labels to the theme's primary/secondary text colors.
    static func tint(primary primaries: [NSTextField] = [], secondary secondaries: [NSTextField] = []) {
        primaries.forEach { $0.textColor = primary }
        secondaries.forEach { $0.textColor = secondary }
    }

    /// Recursively update all text fields inside a view based on their tags:
    /// - Tag 100: primary theme color
    /// - Tag 101: secondary theme color
    /// - Tag 102: tertiary theme color
    static func updateColors(in view: NSView) {
        if let tf = view as? NSTextField {
            if tf.tag == 100 {
                tf.textColor = primary
            } else if tf.tag == 101 {
                tf.textColor = secondary
            } else if tf.tag == 102 {
                tf.textColor = tertiary
            }
        }
        for sub in view.subviews {
            updateColors(in: sub)
        }
    }
}

/// A table/outline row that highlights the selected row with the theme's
/// `selectionBackground` (Rascal's orange tint), falling back to the native
/// system highlight under the System theme. Used by the file list, sidebar,
/// and the overlay finders so selection looks the same everywhere.
final class ThemedRowView: NSTableRowView {
    /// Slight inset + rounding for a modern "pill" look; pass false for a
    /// full-width band (classic list selection).
    var pill: Bool = true

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let t = ThemeManager.shared.current
        guard t.id != "system" else { super.drawSelection(in: dirtyRect); return }
        t.selectionBackground.setFill()
        if pill {
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6).fill()
        } else {
            bounds.fill()
        }
    }
}
