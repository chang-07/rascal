import AppKit

/// Thread-safe cancel flag shared between the progress UI (main) and the
/// transfer worker (background).
final class TransferCancelFlag {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func cancel() { lock.lock(); _value = true; lock.unlock() }
}

/// A small progress sheet (or standalone panel) shown while a multi-item or
/// folder copy/move runs off the main thread. Cancellable.
final class TransferProgressController: NSWindowController {

    let cancelFlag = TransferCancelFlag()
    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private let total: Int
    private let verb: String
    private weak var parentWindow: NSWindow?

    init(total: Int, move: Bool, parent: NSWindow?) {
        self.total = total
        self.verb = move ? "Moving" : "Copying"
        self.parentWindow = parent
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 110),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.title = verb
        super.init(window: win)
        win.contentView = buildContent()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() -> NSView {
        label.stringValue = "\(verb) \(total) item\(total == 1 ? "" : "s")…"
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false

        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = Double(total)
        bar.doubleValue = 0
        bar.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(handleCancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}" // esc
        cancel.translatesAutoresizingMaskIntoConstraints = false

        let v = NSView()
        v.addSubview(label); v.addSubview(bar); v.addSubview(cancel)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: v.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16),
            bar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16),
            cancel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 12),
            cancel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16),
        ])
        return v
    }

    func present() {
        guard let window else { return }
        if let parent = parentWindow {
            parent.beginSheet(window)
        } else {
            window.center(); showWindow(nil); window.makeKeyAndOrderFront(nil)
        }
        PresentedControllers.retain(self)
    }

    func advance(to done: Int, name: String) {
        bar.doubleValue = Double(done)
        label.stringValue = "\(verb) “\(name)” (\(done) of \(total))"
    }

    func finish() {
        guard let window else { return }
        if let parent = parentWindow, parent.attachedSheet == window {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }

    @objc private func handleCancel() {
        cancelFlag.cancel()
        label.stringValue = "Cancelling…"
    }
}
