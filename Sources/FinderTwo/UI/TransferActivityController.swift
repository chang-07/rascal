import AppKit

/// A ForkLift-style activity window listing every queued/active transfer with
/// a progress bar and per-op cancel, plus global Pause/Resume, Cancel All and
/// Clear. Observes TransferQueue.shared. One shared instance; shown on demand
/// (and auto-shown by FileOps for non-trivial transfers when not headless).
final class TransferActivityController: NSWindowController {
    static let shared = TransferActivityController()

    private let stack = NSStackView()
    private let pauseButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: "No active transfers.")

    private init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "Transfers"
        win.minSize = NSSize(width: 360, height: 200)
        super.init(window: win)
        ThemeChrome.apply(to: window)
        win.contentView = buildContent()
        TransferQueue.shared.onChange = { [weak self] in self?.refresh() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Show (and bring to front) the activity window.
    func present() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func buildContent() -> NSView {
        pauseButton.bezelStyle = .rounded
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        pauseButton.title = "Pause"

        let cancelAll = NSButton(title: "Cancel All", target: self, action: #selector(cancelAll))
        cancelAll.bezelStyle = .rounded
        let clear = NSButton(title: "Clear", target: self, action: #selector(clear))
        clear.bezelStyle = .rounded

        let bar = NSStackView(views: [pauseButton, cancelAll, NSView(), clear])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = stack
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(bar)
        root.addSubview(scroll)
        root.addSubview(emptyLabel)
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        return root
    }

    @objc private func togglePause() {
        TransferQueue.shared.setPaused(!TransferQueue.shared.isPaused)
    }
    @objc private func cancelAll() { TransferQueue.shared.cancelAll() }
    @objc private func clear() { TransferQueue.shared.clearFinished() }
    @objc private func cancelOp(_ sender: NSButton) {
        let ops = TransferQueue.shared.snapshot
        guard ops.indices.contains(sender.tag) else { return }
        TransferQueue.shared.cancel(ops[sender.tag])
    }

    /// Rebuild the rows. Called on main via TransferQueue.onChange.
    func refresh() {
        let ops = TransferQueue.shared.snapshot
        pauseButton.title = TransferQueue.shared.isPaused ? "Resume" : "Pause"
        emptyLabel.isHidden = !ops.isEmpty
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, op) in ops.enumerated() {
            stack.addArrangedSubview(rowView(for: op, index: i))
        }
    }

    private func rowView(for op: TransferOp, index: Int) -> NSView {
        let verb = op.move ? "Move" : "Copy"
        let title = NSTextField(labelWithString: "\(verb): \(op.label)")
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle

        let bar = NSProgressIndicator()
        bar.isIndeterminate = false
        bar.minValue = 0; bar.maxValue = 1
        bar.doubleValue = op.fraction
        bar.translatesAutoresizingMaskIntoConstraints = false

        let status = NSTextField(labelWithString: Self.statusText(op))
        status.font = .systemFont(ofSize: 10)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle

        let cancel = NSButton(title: "✕", target: self, action: #selector(cancelOp(_:)))
        cancel.bezelStyle = .circular
        cancel.tag = index
        cancel.isHidden = !(op.state == .running || op.state == .waiting || op.state == .paused)

        let top = NSStackView(views: [title, NSView(), cancel])
        top.orientation = .horizontal

        let col = NSStackView(views: [top, bar, status])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 3
        col.translatesAutoresizingMaskIntoConstraints = false
        col.widthAnchor.constraint(equalToConstant: 392).isActive = true
        bar.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        top.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        return col
    }

    static func statusText(_ op: TransferOp) -> String {
        switch op.state {
        case .waiting: return "Waiting…"
        case .paused: return "Paused — \(SizeFormatter.string(op.bytesDone)) of \(SizeFormatter.string(op.totalBytes))"
        case .running:
            let pct = Int(op.fraction * 100)
            return "\(op.currentName) — \(pct)% (\(SizeFormatter.string(op.bytesDone)) of \(SizeFormatter.string(op.totalBytes)))"
        case .done: return "Completed"
        case .cancelled: return "Cancelled"
        case .failed: return "Finished with \(op.failures) error\(op.failures == 1 ? "" : "s")"
        }
    }
}
