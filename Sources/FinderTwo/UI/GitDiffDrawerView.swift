import AppKit

/// A custom NSTextView subclass that draws full-width backgrounds for diff lines
/// (green for additions, red for deletions, blue for hunk headers) matching GitHub's style.
final class DiffTextView: NSTextView {
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        
        guard let layoutManager = self.layoutManager,
              let textContainer = self.textContainer,
              let textStorage = self.textStorage else { return }
              
        let string = textStorage.string as NSString
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: rect, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)
        
        let isDark = DiffTextView.isDark
        let addBg = isDark ? NSColor(red: 0.12, green: 0.28, blue: 0.16, alpha: 1.0) : NSColor(red: 0.88, green: 0.97, blue: 0.89, alpha: 1.0)
        let delBg = isDark ? NSColor(red: 0.35, green: 0.12, blue: 0.13, alpha: 1.0) : NSColor(red: 0.99, green: 0.88, blue: 0.88, alpha: 1.0)
        let hunkBg = isDark ? NSColor(red: 0.15, green: 0.22, blue: 0.33, alpha: 1.0) : NSColor(red: 0.94, green: 0.96, blue: 1.00, alpha: 1.0)
        
        var index = visibleCharRange.location
        while index < NSMaxRange(visibleCharRange) {
            let prevIndex = index
            var lineRange = NSRange()
            string.getLineStart(&lineRange.location, end: &index, contentsEnd: nil, for: NSRange(location: index, length: 0))
            if index <= prevIndex {
                break
            }
            guard lineRange.location < string.length else { break }
            
            // Check prefix
            let prefixLength = min(string.length - lineRange.location, 4)
            let lineStr = string.substring(with: NSRange(location: lineRange.location, length: prefixLength))
            var bgColor: NSColor? = nil
            if lineStr.hasPrefix("+") && !lineStr.hasPrefix("+++") {
                bgColor = addBg
            } else if lineStr.hasPrefix("-") && !lineStr.hasPrefix("---") {
                bgColor = delBg
            } else if lineStr.hasPrefix("@@") {
                bgColor = hunkBg
            }
            
            if let color = bgColor {
                let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineRange.location)
                var lineRectRange = NSRange()
                let rect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineRectRange)
                
                // Draw full-width background
                color.setFill()
                let fullWidthRect = NSRect(x: 0, y: rect.origin.y, width: bounds.width, height: rect.height)
                fullWidthRect.fill()
            }
        }
    }
    
    static var isDark: Bool {
        let t = ThemeManager.shared.current
        if t.appearance == .dark { return true }
        if t.appearance == .light { return false }
        if #available(macOS 10.14, *) {
            let app = NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua)!
            let name = app.bestMatch(from: [.darkAqua, .aqua])
            return name == .darkAqua
        }
        return false
    }
}

/// A right-side drawer that shows the git diff of a selected file.
final class GitDiffDrawerView: NSView, ThemeObserving {
    var onClose: (() -> Void)?
    var fileURL: URL? {
        didSet { reload() }
    }
    
    private let scroll = NSScrollView()
    let textView = DiffTextView()
    private let header = NSTextField(labelWithString: "")
    private let closeBtn = NSButton()
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        
        header.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false
        header.stringValue = "Git Diff"
        
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.bezelStyle = .shadowlessSquare
        closeBtn.isBordered = false
        closeBtn.attributedTitle = NSAttributedString(string: "✕", attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 10, weight: .bold)
        ])
        closeBtn.target = self
        closeBtn.action = #selector(onCloseClicked)
        
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        
        textView.isEditable = false
        textView.isRichText = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        
        scroll.documentView = textView
        
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        
        addSubview(header)
        addSubview(closeBtn)
        addSubview(sep)
        addSubview(scroll)
        
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(lessThanOrEqualTo: closeBtn.leadingAnchor, constant: -12),
            
            closeBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            closeBtn.widthAnchor.constraint(equalToConstant: 16),
            closeBtn.heightAnchor.constraint(equalToConstant: 16),
            
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
    
    @objc private func onCloseClicked() {
        onClose?()
    }
    
    func reload() {
        guard let url = fileURL,
              let root = GitStatus.repoRoot(for: url) else {
            textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
            header.stringValue = "Git Diff"
            return
        }
        header.stringValue = "Git Diff — \(url.lastPathComponent)"
        
        let targetURL = url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let diff = GitStatus.gitDiff(repoRoot: root, fileURL: targetURL)
            DispatchQueue.main.async {
                guard self?.fileURL == targetURL else { return }
                self?.render(diff)
            }
        }
    }
    
    private func render(_ diff: String?) {
        guard let diff else {
            let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.textStorage?.setAttributedString(NSAttributedString(string: "Couldn't retrieve git diff.", attributes: [.font: font]))
            return
        }
        if diff.isEmpty {
            let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.textStorage?.setAttributedString(NSAttributedString(string: "No changes compared to Git HEAD.", attributes: [.font: font]))
            return
        }
        
        let isDark = DiffTextView.isDark
        let normalColor = isDark ? NSColor.white : NSColor.black
        let addColor = isDark ? NSColor(red: 0.25, green: 0.73, blue: 0.31, alpha: 1.0) : NSColor(red: 0.10, green: 0.50, blue: 0.22, alpha: 1.0)
        let delColor = isDark ? NSColor(red: 0.97, green: 0.32, blue: 0.29, alpha: 1.0) : NSColor(red: 0.81, green: 0.13, blue: 0.18, alpha: 1.0)
        let hunkColor = isDark ? NSColor(red: 0.35, green: 0.65, blue: 1.0, alpha: 1.0) : NSColor(red: 0.04, green: 0.41, blue: 0.85, alpha: 1.0)
        let metaColor = isDark ? NSColor.lightGray : NSColor.darkGray
        
        let out = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        
        for line in diff.components(separatedBy: "\n") {
            var color = normalColor
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                color = addColor
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                color = delColor
            } else if line.hasPrefix("@@") {
                color = hunkColor
            } else if line.hasPrefix("diff") || line.hasPrefix("index") || line.hasPrefix("---") || line.hasPrefix("+++") {
                color = metaColor
            }
            
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color
            ]
            out.append(NSAttributedString(string: line + "\n", attributes: attrs))
        }
        textView.textStorage?.setAttributedString(out)
    }
    
    func focus() {
        window?.makeFirstResponder(textView)
    }

    @objc func applyTheme() {
        let t = ThemeManager.shared.current
        layer?.backgroundColor = t.background.cgColor
        textView.backgroundColor = t.background
        header.textColor = t.labelSecondary
        closeBtn.attributedTitle = NSAttributedString(string: "✕", attributes: [
            .foregroundColor: t.labelSecondary,
            .font: NSFont.systemFont(ofSize: 10, weight: .bold)
        ])
        reload()
    }
}
