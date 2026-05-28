import AppKit

/// Right-side drawer that reads / writes `.ftnote.md` in the current folder.
/// Plain text by default; we render a small subset of markdown (headings +
/// bullets) into NSAttributedString for read mode, and a plain NSTextView
/// for edit mode. Cmd+Shift+E toggles the drawer; the note saves on blur
/// and on every 2-second idle.
final class FolderNoteView: NSView, NSTextViewDelegate, ThemeObserving {

    /// The folder this note belongs to. Setting it loads the contents.
    var folderURL: URL? {
        didSet { reload() }
    }
    /// Visibility — caller toggles this via a constraint on the right edge.

    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private let header = NSTextField(labelWithString: "")
    private var saveTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        header.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false
        header.stringValue = "Notes"

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.delegate = self
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        scroll.documentView = textView

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(sep)
        addSubview(scroll)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            sep.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            sep.leadingAnchor.constraint(equalTo: leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: sep.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        subscribeToTheme(self)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var noteURL: URL? {
        folderURL?.appendingPathComponent(".ftnote.md")
    }

    private func reload() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard let url = noteURL else {
            textView.string = ""
            header.stringValue = "Notes"
            return
        }
        header.stringValue = "Notes — \(folderURL?.lastPathComponent ?? "")"
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            textView.string = text
        } else {
            textView.string = ""
        }
    }

    func textDidChange(_ notification: Notification) {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.save()
        }
    }

    /// Save now (called by timer + on blur via window resign).
    private func save() {
        guard let url = noteURL else { return }
        let text = textView.string
        if text.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    @objc func applyTheme() {
        let t = ThemeManager.shared.current
        layer?.backgroundColor = t.background.cgColor
        textView.backgroundColor = t.background
        textView.textColor = t.labelPrimary
        textView.insertionPointColor = t.accent
        header.textColor = t.labelSecondary
    }

    /// Called by PaneController when the drawer is being hidden — make sure
    /// pending edits are persisted.
    func saveNow() { save() }

    /// Persist pending edits when the view leaves its window (window close,
    /// drawer removal) so the 1.5 s debounce can't drop the last keystrokes.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            saveTimer?.invalidate()
            saveTimer = nil
            save()
        }
    }

    deinit {
        saveTimer?.invalidate()
    }
}
