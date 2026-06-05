import AppKit
import Quartz

/// Persistent right-side preview pane (Finder's "Show Preview"): a live
/// Quick Look render of the selected item plus its name and size.
///
/// The QLPreviewView is **recreated for every item** rather than reused. Swapping
/// `previewItem` on a live QLPreviewView trips its internal KVO
/// ("…displayedDisplayBundle… without an appropriate KVO notification…") and its
/// overlay scroller (`-[NSScrollerImp setKnobProportion:]` asserts
/// `isfinite(newKnobProportion)`), which crashes the app when previewing
/// scrollable content like PDFs. A fresh view per item — added only once the host
/// has a real, non-zero size — avoids both failure modes.
final class PreviewDrawerView: NSView, ThemeObserving {

    private let qlHost = NSView()
    private var ql: QLPreviewView?
    private let nameLabel = NSTextField(labelWithString: "")
    private let infoLabel = NSTextField(labelWithString: "")

    var url: URL? {
        didSet {
            nameLabel.stringValue = url?.lastPathComponent ?? "No selection"
            if let url {
                let rv = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .localizedTypeDescriptionKey])
                let kind = (rv?.isDirectory == true) ? "Folder" : (rv?.localizedTypeDescription ?? "")
                let size = (rv?.isDirectory == true) ? "" : SizeFormatter.string(Int64(rv?.fileSize ?? 0))
                infoLabel.stringValue = [kind, size].filter { !$0.isEmpty }.joined(separator: " · ")
            } else {
                infoLabel.stringValue = ""
            }
            reloadPreview()
        }
    }

    /// Tear down the previous QLPreviewView and build a fresh one for the current
    /// URL — but only once the host actually has a non-zero frame.
    private func reloadPreview() {
        ql?.close()
        ql?.removeFromSuperview()
        ql = nil

        guard let url else { return }
        layoutSubtreeIfNeeded()
        guard qlHost.bounds.width >= 1, qlHost.bounds.height >= 1 else { return }

        guard let v = QLPreviewView(frame: qlHost.bounds, style: .normal) else { return }
        v.autostarts = true
        v.translatesAutoresizingMaskIntoConstraints = false
        qlHost.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: qlHost.topAnchor),
            v.leadingAnchor.constraint(equalTo: qlHost.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: qlHost.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: qlHost.bottomAnchor),
        ])
        layoutSubtreeIfNeeded()          // give it a real frame before QuickLook loads
        v.previewItem = url as NSURL
        ql = v
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)

        qlHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(qlHost)

        nameLabel.font = .boldSystemFont(ofSize: 12)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.alignment = .center
        infoLabel.lineBreakMode = .byTruncatingTail
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(infoLabel)

        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.widthAnchor.constraint(equalToConstant: 1),

            qlHost.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            qlHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            qlHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            nameLabel.topAnchor.constraint(equalTo: qlHost.bottomAnchor, constant: 8),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            infoLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            infoLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            infoLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            infoLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        subscribeToTheme(self)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func applyTheme() {
        let t = ThemeManager.shared.current
        layer?.backgroundColor = (t.id == "system" ? NSColor.windowBackgroundColor : t.background).cgColor
        nameLabel.textColor = t.id == "system" ? .labelColor : t.labelPrimary
        infoLabel.textColor = t.id == "system" ? .secondaryLabelColor : t.labelSecondary
    }
}
