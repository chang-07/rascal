import AppKit

final class ToolbarView: NSView, NSTextFieldDelegate, NSSearchFieldDelegate, ThemeObserving {

    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onUp: (() -> Void)?
    var onCommit: ((String) -> Void)?
    var onSearchChanged: ((String) -> Void)?
    var onSearchCancelled: (() -> Void)?

    var canGoBack: Bool = false {
        didSet { backBtn.isEnabled = canGoBack }
    }
    var canGoForward: Bool = false {
        didSet { fwdBtn.isEnabled = canGoForward }
    }
    var pathText: String = "" {
        didSet { pathField.stringValue = pathText }
    }

    private let backBtn = NSButton()
    private let fwdBtn = NSButton()
    private let upBtn = NSButton()
    private let pathField = NSTextField()
    private let searchField = NSSearchField()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        subscribeToTheme(self)

        func chevron(_ symbol: String, action: Selector) -> NSButton {
            let b: NSButton
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                b = NSButton(image: img, target: self, action: action)
            } else {
                b = NSButton(title: symbol, target: self, action: action)
            }
            b.bezelStyle = .texturedRounded
            b.isBordered = true
            b.translatesAutoresizingMaskIntoConstraints = false
            return b
        }
        backBtn.target = self; backBtn.action = #selector(handleBack)
        fwdBtn.target = self; fwdBtn.action = #selector(handleForward)
        upBtn.target = self; upBtn.action = #selector(handleUp)
        // Explicit AX labels so VoiceOver announces the icon-only nav buttons.
        backBtn.setAccessibilityLabel("Back")
        fwdBtn.setAccessibilityLabel("Forward")
        upBtn.setAccessibilityLabel("Enclosing Folder")

        let backImg = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        let fwdImg = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")
        let upImg  = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Up")
        for (b, img) in [(backBtn, backImg), (fwdBtn, fwdImg), (upBtn, upImg)] {
            if let img { b.image = img }
            b.bezelStyle = .texturedRounded
            b.isBordered = true
            b.translatesAutoresizingMaskIntoConstraints = false
            b.imagePosition = .imageOnly
        }

        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathField.isBordered = true
        pathField.bezelStyle = .roundedBezel
        pathField.placeholderString = "Type a path or Cmd+L to edit"
        pathField.delegate = self
        pathField.font = NSFont.systemFont(ofSize: 12)
        pathField.refusesFirstResponder = false

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Filter…"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = false

        for v in [backBtn, fwdBtn, upBtn, pathField, searchField] {
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            backBtn.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            backBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            backBtn.widthAnchor.constraint(equalToConstant: 28),
            backBtn.heightAnchor.constraint(equalToConstant: 22),

            fwdBtn.leadingAnchor.constraint(equalTo: backBtn.trailingAnchor, constant: 4),
            fwdBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            fwdBtn.widthAnchor.constraint(equalToConstant: 28),
            fwdBtn.heightAnchor.constraint(equalToConstant: 22),

            upBtn.leadingAnchor.constraint(equalTo: fwdBtn.trailingAnchor, constant: 8),
            upBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            upBtn.widthAnchor.constraint(equalToConstant: 28),
            upBtn.heightAnchor.constraint(equalToConstant: 22),

            pathField.leadingAnchor.constraint(equalTo: upBtn.trailingAnchor, constant: 10),
            pathField.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathField.trailingAnchor.constraint(equalTo: searchField.leadingAnchor, constant: -8),
            pathField.heightAnchor.constraint(equalToConstant: 22),

            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 180),
            searchField.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    func focusPathField() {
        window?.makeFirstResponder(pathField)
        pathField.currentEditor()?.selectAll(nil)
    }

    /// Programmatically set the filter and propagate (used by AX-driven tests
    /// where setting the AXValue alone does not fire controlTextDidChange).
    func setFilterText(_ value: String) {
        searchField.stringValue = value
        onSearchChanged?(value)
    }

    func focusSearchField(insert initial: String? = nil) {
        if let initial {
            searchField.stringValue += initial
            onSearchChanged?(searchField.stringValue)
        }
        window?.makeFirstResponder(searchField)
        // Place insertion point at end
        if let editor = searchField.currentEditor() {
            editor.selectedRange = NSRange(location: searchField.stringValue.count, length: 0)
        }
    }

    func clearSearchField() {
        searchField.stringValue = ""
        onSearchChanged?("")
    }

    @objc private func handleBack() { onBack?() }
    @objc private func handleForward() { onForward?() }
    @objc private func handleUp() { onUp?() }

    @objc func applyTheme() {
        let t = ThemeManager.shared.current
        layer?.backgroundColor = t.toolbarBackground.cgColor
        pathField.font = ThemeManager.shared.font()
        
        let custom = t.id != "system"
        let bgColor = custom ? t.pathBarBackground : .controlBackgroundColor
        let textColor = custom ? t.labelPrimary : .controlTextColor
        
        pathField.textColor = textColor
        searchField.textColor = textColor
        
        if custom {
            pathField.isBezeled = false
            pathField.isBordered = false
            pathField.drawsBackground = false
            pathField.wantsLayer = true
            pathField.layer?.backgroundColor = bgColor.cgColor
            pathField.layer?.cornerRadius = 5
            
            searchField.isBezeled = false
            searchField.isBordered = false
            searchField.drawsBackground = false
            searchField.wantsLayer = true
            searchField.layer?.backgroundColor = bgColor.cgColor
            searchField.layer?.cornerRadius = 5
        } else {
            pathField.wantsLayer = false
            pathField.isBezeled = true
            pathField.bezelStyle = .roundedBezel
            pathField.drawsBackground = true
            pathField.backgroundColor = bgColor
            
            searchField.wantsLayer = false
            searchField.isBezeled = true
            searchField.drawsBackground = true
            searchField.backgroundColor = bgColor
        }
    }

    // NSTextFieldDelegate (path commit + ESC on search field)
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === pathField, commandSelector == #selector(NSResponder.insertNewline(_:)) {
            onCommit?(pathField.stringValue)
            window?.makeFirstResponder(nil)
            return true
        }
        if control === searchField, commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            searchField.stringValue = ""
            onSearchChanged?("")
            window?.makeFirstResponder(nil)
            onSearchCancelled?()
            return true
        }
        return false
    }

    // NSSearchFieldDelegate
    func controlTextDidChange(_ obj: Notification) {
        guard let sf = obj.object as? NSSearchField, sf === searchField else { return }
        onSearchChanged?(sf.stringValue)
    }

    /// Test hook: simulate Esc on the search field by calling the delegate method
    /// with the real searchField (needed because the delegate uses identity check).
    func testSimulateCancelSearch() -> Bool {
        return control(searchField, textView: NSTextView(),
                       doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    }
}
