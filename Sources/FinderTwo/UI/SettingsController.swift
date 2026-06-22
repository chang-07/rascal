import AppKit

/// Multi-section settings window with a System-Settings-style toolbar:
/// General · Appearance · Keyboard · Hotbar · Advanced. Each section is its
/// own view controller swapped into the window; the window resizes to fit.
final class SettingsController: NSWindowController, NSToolbarDelegate, ThemeObserving {
    private static var instance: SettingsController?

    static func show(selecting section: Section? = nil) {
        if instance == nil { instance = SettingsController() }
        instance?.window?.center()
        instance?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let section { instance?.select(section) }
    }

    enum Section: String, CaseIterable {
        case general, appearance, keyboard, hotbar, developer, advanced
        var label: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "paintpalette"
            case .keyboard: return "keyboard"
            case .hotbar: return "square.grid.2x2"
            case .developer: return "terminal"
            case .advanced: return "wrench.and.screwdriver"
            }
        }
        func makeController() -> NSViewController {
            switch self {
            case .general: return GeneralPane()
            case .appearance: return AppearancePane()
            case .keyboard: return KeyboardPane()
            case .hotbar: return HotbarPane()
            case .developer: return DeveloperPane()
            case .advanced: return AdvancedPane()
            }
        }
    }

    private var current: Section = .general

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = "Rascal Settings"
        super.init(window: win)
        ThemeChrome.apply(to: window)
        let toolbar = NSToolbar(identifier: "FinderTwo.Settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        win.toolbarStyle = .preference
        win.toolbar = toolbar
        select(.general)
        subscribeToTheme(self)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func select(_ section: Section) {
        current = section
        let vc = section.makeController()
        window?.contentViewController = vc
        window?.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(section.rawValue)
        window?.title = "Rascal Settings — \(section.label)"
        (vc as? ThemeObserving)?.applyTheme()
    }

    @objc func applyTheme() {
        ThemeChrome.apply(to: window)
        if let cv = window?.contentView {
            ThemeChrome.updateColors(in: cv)
        }
        (window?.contentViewController as? ThemeObserving)?.applyTheme()
    }

    @objc private func toolbarItemClicked(_ sender: NSToolbarItem) {
        if let s = Section(rawValue: sender.itemIdentifier.rawValue) { select(s) }
    }

    // MARK: NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let section = Section(rawValue: id.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = section.label
        item.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: section.label)
        item.target = self
        item.action = #selector(toolbarItemClicked(_:))
        return item
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Section.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
}

// MARK: - Shared form helpers

/// Base pane that lays out labeled rows in an NSGridView (clean, no manual
/// constraint juggling).
class SettingsPane: NSViewController, ThemeObserving {
    let grid = NSGridView()
    private var rows: [[NSView]] = []

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 460))
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        root.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
        ])
        self.view = root
        build()
        grid.column(at: 0).xPlacement = .trailing
        if grid.numberOfColumns > 1 { grid.column(at: 1).xPlacement = .leading }
        subscribeToTheme(self)
    }

    /// Subclasses override to add rows via `addRow`.
    func build() {}

    func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = NSFont.systemFont(ofSize: 12)
        l.tag = 101
        l.alignment = .right
        return l
    }

    @discardableResult
    func addRow(_ title: String, _ control: NSView) -> NSGridRow {
        grid.addRow(with: [label(title), control])
    }

    @discardableResult
    func addFullWidth(_ view: NSView) -> NSGridRow {
        let row = grid.addRow(with: [view])
        row.cell(at: 0).xPlacement = .leading
        if grid.numberOfColumns > 1 {
            row.mergeCells(in: NSRange(location: 0, length: grid.numberOfColumns))
        }
        return row
    }

    func sectionHeader(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        l.tag = 100
        return l
    }

    @objc func applyTheme() {
        if isViewLoaded {
            ThemeChrome.updateColors(in: view)
        }
    }
}

// MARK: - General

final class GeneralPane: SettingsPane {
    override func build() {
        let loc = NSPopUpButton()
        for l in Settings.DefaultLocation.allCases { loc.addItem(withTitle: l.label); loc.lastItem?.representedObject = l.rawValue }
        loc.selectItem(withTitle: Settings.defaultLocation.label)
        loc.target = self; loc.action = #selector(locChanged(_:))
        addRow("Open new windows at:", loc)

        let hidden = NSButton(checkboxWithTitle: "Show hidden files by default",
                              target: self, action: #selector(hiddenChanged(_:)))
        hidden.state = Settings.showHiddenByDefault ? .on : .off
        addRow("Files:", hidden)

        let typeAhead = NSButton(checkboxWithTitle: "Type to filter the file list",
                                 target: self, action: #selector(typeAheadChanged(_:)))
        typeAhead.state = Settings.typeAheadEnabled ? .on : .off
        addRow("", typeAhead)



        let view = NSPopUpButton()
        for v in Settings.DefaultView.allCases { view.addItem(withTitle: v.label) }
        view.selectItem(withTitle: Settings.defaultView.label)
        view.target = self; view.action = #selector(viewChanged(_:))
        addRow("Default view:", view)

        let foldersTop = NSButton(checkboxWithTitle: "Keep folders on top",
                                  target: self, action: #selector(foldersTopChanged(_:)))
        foldersTop.state = Settings.foldersFirst ? .on : .off
        addRow("Sorting:", foldersTop)



        let titleBar = NSButton(checkboxWithTitle: "Show window title bar",
                                target: self, action: #selector(titleBarChanged(_:)))
        titleBar.state = Settings.showTitleBar ? .on : .off
        addRow("Window chrome:", titleBar)

        let statusBar = NSButton(checkboxWithTitle: "Show status bar",
                                 target: self, action: #selector(statusBarChanged(_:)))
        statusBar.state = Settings.showStatusBar ? .on : .off
        addRow("", statusBar)

        let pathBar = NSButton(checkboxWithTitle: "Show path bar (breadcrumb)",
                               target: self, action: #selector(pathBarChanged(_:)))
        pathBar.state = Settings.showPathBar ? .on : .off
        addRow("", pathBar)



        let alwaysShowTab = NSButton(checkboxWithTitle: "Always show tab bar",
                                     target: self, action: #selector(alwaysShowTabChanged(_:)))
        alwaysShowTab.state = Settings.alwaysShowTabBar ? .on : .off
        addRow("", alwaysShowTab)

        let doubleClickTab = NSButton(checkboxWithTitle: "Double-click folder opens in new tab",
                                      target: self, action: #selector(doubleClickTabChanged(_:)))
        doubleClickTab.state = Settings.doubleClickFolderOpensNewTab ? .on : .off
        addRow("Navigation:", doubleClickTab)
    }

    @objc private func foldersTopChanged(_ s: NSButton) { Settings.foldersFirst = s.state == .on }
    @objc private func titleBarChanged(_ s: NSButton) { Settings.showTitleBar = s.state == .on }
    @objc private func statusBarChanged(_ s: NSButton) { Settings.showStatusBar = s.state == .on }
    @objc private func pathBarChanged(_ s: NSButton) { Settings.showPathBar = s.state == .on }
    @objc private func alwaysShowTabChanged(_ s: NSButton) { Settings.alwaysShowTabBar = s.state == .on }
    @objc private func doubleClickTabChanged(_ s: NSButton) { Settings.doubleClickFolderOpensNewTab = s.state == .on }

    @objc private func locChanged(_ s: NSPopUpButton) {
        if let raw = s.selectedItem?.representedObject as? String,
            let v = Settings.DefaultLocation(rawValue: raw) { Settings.defaultLocation = v }
    }
    @objc private func hiddenChanged(_ s: NSButton) { Settings.showHiddenByDefault = s.state == .on }
    @objc private func typeAheadChanged(_ s: NSButton) { Settings.typeAheadEnabled = s.state == .on }
    @objc private func viewChanged(_ s: NSPopUpButton) {
        if let v = Settings.DefaultView(rawValue: (s.titleOfSelectedItem ?? "").lowercased()) {
            Settings.defaultView = v
        }
    }
}

// MARK: - Appearance

final class AppearancePane: SettingsPane {
    private let preview = AppearancePreview()

    override func build() {
        let theme = NSPopUpButton()
        for t in Theme.all { theme.addItem(withTitle: t.name); theme.lastItem?.representedObject = t.id }
        theme.selectItem(withTitle: ThemeManager.shared.current.name)
        theme.target = self; theme.action = #selector(themeChanged(_:))
        addRow("Theme:", theme)

        let accent = NSPopUpButton()
        for a in Settings.Accent.allCases {
            accent.addItem(withTitle: a.label)
            if let c = a.color {
                accent.lastItem?.image = AppearancePane.swatch(c)
            }
            accent.lastItem?.representedObject = a.rawValue
        }
        accent.selectItem(withTitle: Settings.accent.label)
        accent.target = self; accent.action = #selector(accentChanged(_:))
        addRow("Accent color:", accent)

        let density = NSSegmentedControl(labels: Settings.Density.allCases.map { $0.label },
                                         trackingMode: .selectOne, target: self,
                                         action: #selector(densityChanged(_:)))
        density.selectedSegment = Settings.Density.allCases.firstIndex(of: Settings.density) ?? 1
        addRow("Density:", density)

        let stepperStack = NSStackView()
        stepperStack.orientation = .horizontal
        stepperStack.spacing = 8
        let sizeLabel = NSTextField(labelWithString: fontLabel())
        sizeLabel.font = NSFont.systemFont(ofSize: 12)
        sizeLabel.tag = 99
        let stepper = NSStepper()
        stepper.minValue = -1; stepper.maxValue = 4; stepper.increment = 1
        stepper.integerValue = Settings.fontSizeDelta
        stepper.valueWraps = false
        stepper.target = self; stepper.action = #selector(fontChanged(_:))
        stepperStack.addArrangedSubview(sizeLabel)
        stepperStack.addArrangedSubview(stepper)
        addRow("Font size:", stepperStack)

        let altRows = NSButton(checkboxWithTitle: "Use alternating row background colors",
                               target: self, action: #selector(altRowsChanged(_:)))
        altRows.state = Settings.alternatingRows ? .on : .off
        addRow("List style:", altRows)

        addFullWidth(NSBox.divider())
        let header = sectionHeader("Preview")
        addFullWidth(header)
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.heightAnchor.constraint(equalToConstant: 130).isActive = true
        preview.widthAnchor.constraint(equalToConstant: 460).isActive = true
        addFullWidth(preview)
    }

    private func fontLabel() -> String {
        let pt = Int(ThemeManager.shared.effectiveFontSize)
        return "\(pt) pt"
    }

    static func swatch(_ color: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 14, height: 14))
        img.lockFocus()
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 14, height: 14), xRadius: 3, yRadius: 3).fill()
        img.unlockFocus()
        return img
    }

    @objc private func themeChanged(_ s: NSPopUpButton) {
        if let id = s.selectedItem?.representedObject as? String { ThemeManager.shared.setTheme(id: id) }
        refreshFontLabel()
    }
    @objc private func accentChanged(_ s: NSPopUpButton) {
        if let raw = s.selectedItem?.representedObject as? String,
           let a = Settings.Accent(rawValue: raw) { Settings.accent = a }
    }
    @objc private func densityChanged(_ s: NSSegmentedControl) {
        let all = Settings.Density.allCases
        if all.indices.contains(s.selectedSegment) { Settings.density = all[s.selectedSegment] }
    }
    @objc private func fontChanged(_ s: NSStepper) {
        Settings.fontSizeDelta = s.integerValue
        refreshFontLabel()
    }
    @objc private func altRowsChanged(_ s: NSButton) {
        Settings.alternatingRows = s.state == .on
        preview.needsDisplay = true
    }
    private func refreshFontLabel() {
        if let lbl = view.viewWithTag(99) as? NSTextField { lbl.stringValue = fontLabel() }
    }
}

/// A tiny mock file list that reflects the live theme/accent/density/font.
final class AppearancePreview: NSView, ThemeObserving {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        subscribeToTheme(self)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func applyTheme() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let t = ThemeManager.shared.current
        t.background.setFill()
        bounds.fill()
        layer?.borderColor = NSColor.separatorColor.cgColor

        let rowH = ThemeManager.shared.effectiveRowHeight
        let font = ThemeManager.shared.font()
        let names = ["Documents", "report.pdf", "photo.jpg", "notes.md"]
        var y = bounds.height - rowH
        for (i, name) in names.enumerated() {
            let rowRect = NSRect(x: 0, y: y, width: bounds.width, height: rowH)
            if i == 1 {
                ThemeManager.shared.effectiveAccent.withAlphaComponent(0.30).setFill()
                rowRect.fill()
            } else if i % 2 == 0, Settings.alternatingRows {
                t.rowAlternate.withAlphaComponent(0.5).setFill()
                rowRect.fill()
            }
            let color = i == 1 ? t.labelPrimary : t.labelSecondary
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let s = (i == 0 ? "📁 " : "") + name
            (s as NSString).draw(at: NSPoint(x: 10, y: y + (rowH - font.pointSize) / 2 - 2), withAttributes: attrs)
            y -= rowH
            if y < 0 { break }
        }
    }
}

private extension NSBox {
    static func divider() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 460).isActive = true
        return b
    }
}
