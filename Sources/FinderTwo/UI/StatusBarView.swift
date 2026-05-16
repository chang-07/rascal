import AppKit

final class StatusBarView: NSView, ThemeObserving {

    /// Single-string convenience. Going forward prefer `setSegments(_:)` for
    /// richer multi-segment styling.
    var text: String = "" {
        didSet {
            setSegments([Segment(text)])
        }
    }

    struct Segment {
        let text: String
        let isMonospaced: Bool
        let isMuted: Bool
        init(_ text: String, isMonospaced: Bool = false, isMuted: Bool = true) {
            self.text = text
            self.isMonospaced = isMonospaced
            self.isMuted = isMuted
        }
    }
    /// Set the bar contents as a series of segments separated by " · ".
    func setSegments(_ segments: [Segment]) {
        let attr = NSMutableAttributedString()
        for (i, s) in segments.enumerated() {
            let font: NSFont = s.isMonospaced
                ? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
                : NSFont.systemFont(ofSize: 11)
            let color: NSColor = s.isMuted ? .secondaryLabelColor : .labelColor
            attr.append(NSAttributedString(string: s.text, attributes: [.font: font, .foregroundColor: color]))
            if i < segments.count - 1 {
                attr.append(NSAttributedString(
                    string: "  ·  ",
                    attributes: [.font: NSFont.systemFont(ofSize: 11),
                                 .foregroundColor: NSColor.tertiaryLabelColor]
                ))
            }
        }
        label.attributedStringValue = attr
    }

    private let label = NSTextField(labelWithString: "")
    private let topLine = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
        topLine.boxType = .separator
        topLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topLine)
        NSLayoutConstraint.activate([
            topLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            topLine.topAnchor.constraint(equalTo: topAnchor),
            topLine.heightAnchor.constraint(equalToConstant: 1),
        ])
        subscribeToTheme(self)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func applyTheme() {
        let t = ThemeManager.shared.current
        layer?.backgroundColor = t.background.cgColor
    }
}
