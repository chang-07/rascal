import AppKit

final class HelpGuideController: NSWindowController, ThemeObserving {

    static func show(parent: NSWindow?) {
        let c = HelpGuideController()
        c.window?.center()
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        PresentedControllers.retain(c)
    }

    private let titleLabel = NSTextField(labelWithString: "Rascal Help Guide")
    private let subtitleLabel = NSTextField(labelWithString: "Learn how to access features and drive Rascal from the keyboard.")
    private let mainStack = NSStackView()
    let vimGuideContainer = NSStackView()
    private var isVimGuideExpanded = false
    let toggleButton = NSButton()

    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "Rascal Help"
        win.minSize = NSSize(width: 400, height: 400)
        super.init(window: win)
        ThemeChrome.apply(to: window)
        win.contentView = buildContent()
        subscribeToTheme(self)
        applyTheme()
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    private func buildContent() -> NSView {
        let root = NSView()
        
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.cell?.wraps = true
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 14
        mainStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        
        // Add Title & Subtitle to mainStack
        mainStack.addArrangedSubview(titleLabel)
        mainStack.addArrangedSubview(subtitleLabel)
        
        // Separator
        let sep = NSBox()
        sep.boxType = .separator
        mainStack.addArrangedSubview(sep)
        
        // Accessing Features Section Header
        let featuresHeader = NSTextField(labelWithString: "Accessing Features & Shortcuts")
        featuresHeader.font = .systemFont(ofSize: 14, weight: .semibold)
        featuresHeader.textColor = .labelColor
        mainStack.addArrangedSubview(featuresHeader)
        
        let shortcutItems = [
            ("⌘⇧P", "Command Palette — Search and run all actions"),
            ("⌘,", "Settings — Customize hotkeys, appearance, general config"),
            ("⌘\\", "Toggle Extra Pane — Open second pane for dual-pane mode"),
            ("⌃Tab", "Focus Next Pane — Shift keyboard focus between panes"),
            ("⌃⇧Tab", "Focus Previous Pane — Shift focus back to previous pane"),
            ("⌘`", "Toggle Terminal — Open terminal panel at active path"),
            ("⌘⇧E", "Toggle Notes Drawer — Write markdown notes for folder"),
            ("⌘⌥P", "Toggle Preview Drawer — View file info & quick previews"),
            ("⌘⌥S", "Toggle Sidebar — Show or hide the navigation sidebar")
        ]
        
        for (keys, desc) in shortcutItems {
            let row = makeShortcutRow(keys: keys, desc: desc)
            mainStack.addArrangedSubview(row)
        }
        
        // Separator 2
        let sep2 = NSBox()
        sep2.boxType = .separator
        mainStack.addArrangedSubview(sep2)
        
        // Collapsible Vim Section
        toggleButton.title = "▶  Vim Navigation Guide"
        toggleButton.target = self
        toggleButton.action = #selector(toggleVimGuide(_:))
        toggleButton.font = .systemFont(ofSize: 14, weight: .bold)
        toggleButton.alignment = .left
        toggleButton.isBordered = false
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(toggleButton)
        
        // Vim Guide Container
        vimGuideContainer.orientation = .vertical
        vimGuideContainer.alignment = .leading
        vimGuideContainer.spacing = 8
        vimGuideContainer.isHidden = true
        vimGuideContainer.translatesAutoresizingMaskIntoConstraints = false
        
        let vimItems = [
            ("h", "Go to enclosing folder (up)"),
            ("j", "Move selection down (e.g. 5j)"),
            ("k", "Move selection up (e.g. 5k)"),
            ("l", "Open selection (enter folder / open file)"),
            ("Return", "Open selection (same as l)"),
            ("gg", "Jump to top of file list"),
            ("G", "Jump to bottom of file list"),
            ("gt", "Switch to next tab"),
            ("gT", "Switch to previous tab"),
            ("t", "Open a new tab"),
            ("r", "Rename selected item"),
            ("yy", "Yank (copy) selection"),
            ("dd", "Move selection to Trash"),
            ("p", "Paste yanked items"),
            ("/", "Focus the live search filter"),
            (":", "Open command palette"),
            ("v", "Visual select mode (extend select with j/k)"),
            ("⌃b b", "Cycle focus to next split pane"),
            ("⌃b h", "Focus sidebar outline"),
            ("⌃b j", "Focus terminal drawer"),
            ("⌃b k", "Focus main file list"),
            ("⌃b l", "Focus git diff drawer")
        ]
        
        for (keys, desc) in vimItems {
            let row = makeShortcutRow(keys: keys, desc: desc)
            vimGuideContainer.addArrangedSubview(row)
        }
        mainStack.addArrangedSubview(vimGuideContainer)
        
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = mainStack
        scroll.translatesAutoresizingMaskIntoConstraints = false
        
        root.addSubview(scroll)
        
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            mainStack.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -32),
            sep.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            sep2.widthAnchor.constraint(equalTo: mainStack.widthAnchor)
        ])
        
        return root
    }
    
    @objc private func toggleVimGuide(_ sender: NSButton) {
        isVimGuideExpanded.toggle()
        // Toggle view visibility
        vimGuideContainer.isHidden = !isVimGuideExpanded
        sender.title = (isVimGuideExpanded ? "▼" : "▶") + "  Vim Navigation Guide"
        
        // Force relayout so scroll view content updates instantly
        window?.layoutIfNeeded()
    }
    
    private func makeKeyBadge(_ keys: String) -> NSView {
        let tf = NSTextField(labelWithString: keys)
        tf.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        tf.textColor = .labelColor
        tf.alignment = .center
        tf.translatesAutoresizingMaskIntoConstraints = false
        
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 4
        box.borderWidth = 1
        box.borderColor = ThemeChrome.isSystem ? NSColor.separatorColor : ThemeManager.shared.effectiveAccent.withAlphaComponent(0.3)
        box.fillColor = ThemeChrome.isSystem ? NSColor.controlBackgroundColor : NSColor.textColor.withAlphaComponent(0.05)
        box.contentView = tf
        box.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            tf.topAnchor.constraint(equalTo: box.topAnchor, constant: 3),
            tf.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -3),
            tf.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
            tf.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
            box.heightAnchor.constraint(equalToConstant: 20)
        ])
        return box
    }
    
    private func makeShortcutRow(keys: String, desc: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        
        let badge = makeKeyBadge(keys)
        badge.translatesAutoresizingMaskIntoConstraints = false
        
        let label = NSTextField(labelWithString: desc)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.cell?.wraps = true
        label.translatesAutoresizingMaskIntoConstraints = false
        
        row.addArrangedSubview(badge)
        row.addArrangedSubview(label)
        
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 85),
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor)
        ])
        
        return row
    }
    
    @objc func applyTheme() {
        ThemeChrome.apply(to: window)
        if let cv = window?.contentView {
            ThemeChrome.updateColors(in: cv)
        }
        
        toggleButton.contentTintColor = ThemeChrome.isSystem ? nil : ThemeManager.shared.effectiveAccent
        
        func updateBadges(in view: NSView) {
            if let box = view as? NSBox, box.boxType == .custom {
                box.borderColor = ThemeChrome.isSystem ? NSColor.separatorColor : ThemeManager.shared.effectiveAccent.withAlphaComponent(0.3)
                box.fillColor = ThemeChrome.isSystem ? NSColor.controlBackgroundColor : NSColor.textColor.withAlphaComponent(0.05)
            }
            for sub in view.subviews {
                updateBadges(in: sub)
            }
        }
        
        if let cv = window?.contentView {
            updateBadges(in: cv)
        }
    }
}
