import AppKit
import Quartz

/// Persistent right-side preview pane (Finder's "Show Preview"): a live
/// Quick Look render of the selected item plus its name and size.
final class PreviewDrawerView: NSView, ThemeObserving {

    private let ql = QLPreviewView(frame: .zero, style: .normal)
    private let nameLabel = NSTextField(labelWithString: "")
    private let infoLabel = NSTextField(labelWithString: "")

    var url: URL? {
        didSet {
            ql?.previewItem = url as NSURL?
            nameLabel.stringValue = url?.lastPathComponent ?? "No selection"
            if let url {
                let rv = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .localizedTypeDescriptionKey])
                let kind = (rv?.isDirectory == true) ? "Folder" : (rv?.localizedTypeDescription ?? "")
                let size = (rv?.isDirectory == true) ? "" : SizeFormatter.string(Int64(rv?.fileSize ?? 0))
                infoLabel.stringValue = [kind, size].filter { !$0.isEmpty }.joined(separator: " · ")
            } else {
                infoLabel.stringValue = ""
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)

        ql?.translatesAutoresizingMaskIntoConstraints = false
        ql?.autostarts = true
        if let ql { addSubview(ql) }

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

        let qlView = ql ?? NSView()
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.widthAnchor.constraint(equalToConstant: 1),

            qlView.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            qlView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            qlView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            nameLabel.topAnchor.constraint(equalTo: qlView.bottomAnchor, constant: 8),
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
