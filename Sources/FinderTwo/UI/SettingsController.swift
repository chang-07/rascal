import AppKit

/// Lightweight settings window. Currently exposes the theme picker and the
/// vim-mode toggle. The full custom-shortcut editor goes here in the next
/// iteration; for now the data layer (ActionRegistry.setShortcut) is ready.
final class SettingsController: NSWindowController {
    private static var instance: SettingsController?

    static func show() {
        if instance == nil {
            instance = SettingsController()
        }
        instance?.window?.center()
        instance?.window?.makeKeyAndOrderFront(nil)
    }

    private let themePopup = NSPopUpButton()
    private let vimCheck = NSButton(checkboxWithTitle: "Enable Vim navigation (hjkl, /, :, dd, yy, p, r, gt/gT)",
                                    target: nil, action: nil)

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 220),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        win.title = "FinderTwo Settings"
        super.init(window: win)
        layout()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func layout() {
        guard let cv = window?.contentView else { return }

        let header = NSTextField(labelWithString: "Appearance")
        header.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        header.translatesAutoresizingMaskIntoConstraints = false

        let themeLabel = NSTextField(labelWithString: "Theme:")
        themeLabel.translatesAutoresizingMaskIntoConstraints = false
        themeLabel.alignment = .right

        themePopup.translatesAutoresizingMaskIntoConstraints = false
        themePopup.removeAllItems()
        for t in Theme.all {
            themePopup.addItem(withTitle: t.name)
            themePopup.lastItem?.representedObject = t.id
        }
        if let idx = Theme.all.firstIndex(where: { $0.id == ThemeManager.shared.current.id }) {
            themePopup.selectItem(at: idx)
        }
        themePopup.target = self
        themePopup.action = #selector(themeChanged)

        let inputHeader = NSTextField(labelWithString: "Input")
        inputHeader.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        inputHeader.translatesAutoresizingMaskIntoConstraints = false

        vimCheck.translatesAutoresizingMaskIntoConstraints = false
        vimCheck.state = VimMode.shared.enabled ? .on : .off
        vimCheck.target = self
        vimCheck.action = #selector(vimChanged)

        let hint = NSTextField(labelWithString: "When vim mode is on and the file list has keyboard focus, plain letter keys are intercepted. Text fields and dialogs always pass through.")
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.preferredMaxLayoutWidth = 420
        hint.maximumNumberOfLines = 3

        for v in [header, themeLabel, themePopup, inputHeader, vimCheck, hint] { cv.addSubview(v) }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: cv.topAnchor, constant: 18),
            header.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),

            themeLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            themeLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            themeLabel.widthAnchor.constraint(equalToConstant: 100),
            themePopup.centerYAnchor.constraint(equalTo: themeLabel.centerYAnchor),
            themePopup.leadingAnchor.constraint(equalTo: themeLabel.trailingAnchor, constant: 6),
            themePopup.widthAnchor.constraint(equalToConstant: 250),

            inputHeader.topAnchor.constraint(equalTo: themeLabel.bottomAnchor, constant: 24),
            inputHeader.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),

            vimCheck.topAnchor.constraint(equalTo: inputHeader.bottomAnchor, constant: 8),
            vimCheck.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            hint.topAnchor.constraint(equalTo: vimCheck.bottomAnchor, constant: 4),
            hint.leadingAnchor.constraint(equalTo: vimCheck.leadingAnchor, constant: 22),
            hint.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
        ])
    }

    @objc private func themeChanged() {
        if let id = themePopup.selectedItem?.representedObject as? String {
            ThemeManager.shared.setTheme(id: id)
        }
    }

    @objc private func vimChanged() {
        VimMode.shared.setEnabled(vimCheck.state == .on)
    }
}
