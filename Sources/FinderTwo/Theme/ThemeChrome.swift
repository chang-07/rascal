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

    /// Theme all columns of a table view using ThemedTableHeaderCell.
    static func themeHeaders(of tableView: NSTableView) {
        for col in tableView.tableColumns {
            let title = col.headerCell.stringValue
            let align = col.headerCell.alignment
            let customCell = ThemedTableHeaderCell(textCell: title)
            customCell.alignment = align
            col.headerCell = customCell
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
    var alternating: Bool = false

    override func drawBackground(in dirtyRect: NSRect) {
        let t = ThemeManager.shared.current
        
        if isGroupRowStyle {
            if superview is NSOutlineView {
                // Sidebar group header: transparent for system (vibrancy), solid theme color for custom
                if t.id != "system" {
                    t.sidebarBackground.setFill()
                    bounds.fill()
                }
                return
            } else {
                // File list group header: flat theme background or native system header background
                if t.id != "system" {
                    t.background.setFill()
                    bounds.fill()
                } else {
                    super.drawBackground(in: dirtyRect)
                }
                return
            }
        }

        guard t.id != "system" else {
            super.drawBackground(in: dirtyRect)
            return
        }
        if alternating, Settings.alternatingRows, let tableView = superview as? NSTableView {
            let row = tableView.row(for: self)
            if row >= 0 {
                let isAlternate = row % 2 == 1
                let bgColor = isAlternate ? t.rowAlternate : t.background
                bgColor.setFill()
                bounds.fill()
                return
            }
        }
        t.background.setFill()
        bounds.fill()
    }

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

/// A split view that colors its divider to match the active custom theme,
/// falling back to native split divider styling under the System theme.
final class ThemedSplitView: NSSplitView {
    override var dividerColor: NSColor {
        let t = ThemeManager.shared.current
        return t.id == "system" ? super.dividerColor : t.rowAlternate
    }
}

/// A split view controller that hosts a ThemedSplitView.
class ThemedSplitViewController: NSSplitViewController {
    override func loadView() {
        let sv = ThemedSplitView()
        sv.isVertical = true
        sv.dividerStyle = .thin
        self.view = sv
    }
}

/// A table header cell that matches the active theme. Renders flat backgrounds
/// with no gradients, grid divider borders, and themed sort indicator arrows.
final class ThemedTableHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let t = ThemeManager.shared.current
        if t.id == "system" {
            super.draw(withFrame: cellFrame, in: controlView)
            return
        }
        
        t.toolbarBackground.setFill()
        cellFrame.fill()
        
        // Draw vertical column divider on the right
        t.rowAlternate.setStroke()
        let dividerPath = NSBezierPath()
        dividerPath.move(to: NSPoint(x: cellFrame.maxX - 1, y: cellFrame.minY + 4))
        dividerPath.line(to: NSPoint(x: cellFrame.maxX - 1, y: cellFrame.maxY - 4))
        dividerPath.lineWidth = 1
        dividerPath.stroke()
        
        // Draw bottom border separator line
        let bottomPath = NSBezierPath()
        bottomPath.move(to: NSPoint(x: cellFrame.minX, y: cellFrame.maxY - 1))
        bottomPath.line(to: NSPoint(x: cellFrame.maxX, y: cellFrame.maxY - 1))
        bottomPath.lineWidth = 1
        bottomPath.stroke()
        
        drawInterior(withFrame: cellFrame, in: controlView)
    }
    
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let t = ThemeManager.shared.current
        if t.id == "system" {
            super.drawInterior(withFrame: cellFrame, in: controlView)
            return
        }
        
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = self.alignment
        paragraphStyle.lineBreakMode = .byTruncatingTail
        
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: t.labelSecondary,
            .paragraphStyle: paragraphStyle
        ]
        
        let titleRect = cellFrame.insetBy(dx: 6, dy: 4)
        stringValue.draw(in: titleRect, withAttributes: attrs)
        
        if let tableView = controlView as? NSTableView,
           let column = tableView.tableColumns.first(where: { $0.headerCell === self }) {
            let sortDescriptors = tableView.sortDescriptors
            if let first = sortDescriptors.first, first.key == column.identifier.rawValue {
                let ascending = first.ascending
                drawSortIndicator(withFrame: cellFrame, in: controlView, ascending: ascending, priority: 0)
            }
        }
    }
    
    override func drawSortIndicator(withFrame cellFrame: NSRect, in controlView: NSView, ascending: Bool, priority: Int) {
        let t = ThemeManager.shared.current
        if t.id == "system" {
            super.drawSortIndicator(withFrame: cellFrame, in: controlView, ascending: ascending, priority: priority)
            return
        }
        
        let size: CGFloat = 8
        let x = cellFrame.maxX - size - 8
        let y = cellFrame.midY - (size / 2)
        
        let path = NSBezierPath()
        if ascending {
            path.move(to: NSPoint(x: x, y: y + size))
            path.line(to: NSPoint(x: x + size, y: y + size))
            path.line(to: NSPoint(x: x + (size / 2), y: y))
        } else {
            path.move(to: NSPoint(x: x, y: y))
            path.line(to: NSPoint(x: x + size, y: y))
            path.line(to: NSPoint(x: x + (size / 2), y: y + size))
        }
        path.close()
        
        t.accent.setFill()
        path.fill()
    }
}

/// A line view that automatically colors itself as a separator matching the theme.
final class SeparatorView: NSView, ThemeObserving {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        subscribeToTheme(self)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc func applyTheme() {
        let t = ThemeManager.shared.current
        layer?.backgroundColor = (t.id == "system" ? NSColor.separatorColor : t.rowAlternate).cgColor
    }
}

