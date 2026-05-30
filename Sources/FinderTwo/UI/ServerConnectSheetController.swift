import AppKit

/// "Mount Network Volume…" — Finder ⌘K-style connect for SMB / FTP / AFP /
/// WebDAV via NetFS. On success the active pane navigates into the mount.
/// (SFTP has its own in-app libssh2 browser; use Connect to SFTP Server.)
final class ServerConnectSheetController: NSWindowController, ThemeObserving {

    private weak var target: BrowserWindowController?
    private let addressField = NSTextField()
    private let userField = NSTextField()
    private let passField = NSSecureTextField()
    private let status = NSTextField(labelWithString: "")
    private var connectButton: NSButton!

    static func show(for wc: BrowserWindowController) {
        guard let parent = wc.window else { return }
        let s = ServerConnectSheetController(target: wc)
        guard let sheet = s.window else { return }
        PresentedControllers.retain(s)
        parent.beginSheet(sheet, completionHandler: { _ in })
    }

    init(target: BrowserWindowController) {
        self.target = target
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 240),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Mount Network Volume"
        super.init(window: win)
        ThemeChrome.apply(to: window)
        win.contentView = buildContent()
        subscribeToTheme(self)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() -> NSView {
        addressField.placeholderString = "smb://server/share, ftp://…, https://… (WebDAV), afp://…"
        userField.placeholderString = "username (optional)"
        passField.placeholderString = "password (optional)"
        for f in [addressField, userField, passField] { f.font = .systemFont(ofSize: 12) }
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.tag = 101
        status.lineBreakMode = .byTruncatingTail

        func labeled(_ t: String, _ field: NSView) -> NSStackView {
            let l = NSTextField(labelWithString: t)
            l.alignment = .right; l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: 80).isActive = true
            l.tag = 101
            let s = NSStackView(views: [l, field]); s.orientation = .horizontal; s.spacing = 8
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
            return s
        }

        connectButton = NSButton(title: "Connect", target: self, action: #selector(connect))
        connectButton.bezelStyle = .rounded; connectButton.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), cancel, connectButton])
        buttons.orientation = .horizontal; buttons.spacing = 10

        let stack = NSStackView(views: [
            labeled("Address:", addressField),
            labeled("User:", userField),
            labeled("Password:", passField),
            status,
            buttons,
        ])
        stack.orientation = .vertical; stack.spacing = 12; stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        let v = NSView()
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -18),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
        return v
    }

    @objc private func connect() {
        let addr = addressField.stringValue.trimmingCharacters(in: .whitespaces)
        guard NetMount.isSupportedURL(addr) else {
            status.stringValue = "Enter a valid address, e.g. smb://server/share"
            NSSound.beep(); return
        }
        status.stringValue = "Connecting…"
        connectButton.isEnabled = false
        NetMount.mount(addr, user: userField.stringValue, password: passField.stringValue) { [weak self] result in
            guard let self else { return }
            self.connectButton.isEnabled = true
            switch result {
            case .mounted(let url):
                self.target?.testActivePane?.navigate(to: url)
                SidebarBookmarks.add(url)
                self.dismiss()
            case .systemHandoff:
                self.status.stringValue = "Continuing in the system connect dialog…"
                self.dismiss()
            case .failure(let msg):
                self.status.stringValue = msg
                NSSound.beep()
            }
        }
    }

    @objc private func cancel() { dismiss() }

    private func dismiss() {
        guard let win = window else { return }
        if let parent = win.sheetParent { parent.endSheet(win) } else { close() }
    }

    @objc func applyTheme() {
        ThemeChrome.apply(to: window)
        if let cv = window?.contentView {
            ThemeChrome.updateColors(in: cv)
        }
    }
}
