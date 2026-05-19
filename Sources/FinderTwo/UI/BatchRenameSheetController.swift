import AppKit
import AVFoundation

/// Batch rename sheet. Takes the active pane's selected items and offers:
///   - regex find / replace (Swift NSRegularExpression)
///   - sequence numbering token `{N}`     (with start, step, pad)
///   - original-name token `{name}`, extension `{ext}`
///   - file modtime token `{date:YYYY-MM-DD}`
///   - EXIF capture date token `{exif}` (best effort via NSImage metadata)
///   - MP3/M4A title token `{title}` via AVAsset
///
/// Live preview shows old → new per row with conflicts highlighted. On commit
/// each rename uses FileManager.moveItem; conflicts are skipped.
final class BatchRenameSheetController: NSWindowController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private weak var target: BrowserWindowController?
    private let items: [FileItem]

    private let findField = NSTextField()
    private let replField = NSTextField()
    private let templateField = NSTextField()
    private let regexCheck = NSButton(checkboxWithTitle: "Regex", target: nil, action: nil)
    private let startField = NSTextField()
    private let padField = NSTextField()
    private let previewTable = NSTableView()
    private let scroll = NSScrollView()
    private let applyButton = NSButton(title: "Rename", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    struct Row {
        let url: URL
        var oldName: String
        var newName: String
        var conflict: Bool
    }
    private var rows: [Row] = []

    /// Test hook: compute the preview rows for a set of items + rule, without
    /// presenting any UI.
    static func testPreview(items: [FileItem],
                            find: String, repl: String, template: String,
                            useRegex: Bool, start: Int, pad: Int) -> [Row] {
        let dummy = BatchRenameSheetController(target: BrowserWindowController(
            rootURL: FileManager.default.homeDirectoryForCurrentUser), items: items)
        dummy.findField.stringValue = find
        dummy.replField.stringValue = repl
        dummy.templateField.stringValue = template
        dummy.regexCheck.state = useRegex ? .on : .off
        dummy.startField.stringValue = String(start)
        dummy.padField.stringValue = String(pad)
        dummy.rebuildPreview()
        return dummy.rows
    }

    static func show(for wc: BrowserWindowController) {
        guard let pane = wc.testActivePane else { return }
        let selection = pane.selectedURLs().compactMap { url -> FileItem? in
            FileItem.load(url)
        }
        let toRename: [FileItem]
        if selection.isEmpty {
            toRename = pane.testCurrentItems
        } else {
            toRename = selection
        }
        guard !toRename.isEmpty, let parent = wc.window else { NSSound.beep(); return }
        let controller = BatchRenameSheetController(target: wc, items: toRename)
        guard let sheetWin = controller.window else { return }
        PresentedControllers.retain(controller)
        parent.beginSheet(sheetWin, completionHandler: { _ in })
        sheetWin.makeFirstResponder(controller.findField)
    }

    init(target: BrowserWindowController, items: [FileItem]) {
        self.target = target
        self.items = items
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered, defer: false
        )
        win.title = "Batch Rename — \(items.count) item\(items.count == 1 ? "" : "s")"
        super.init(window: win)
        layout()
        rebuildPreview()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func layout() {
        guard let cv = window?.contentView else { return }

        let findLbl = NSTextField(labelWithString: "Find:")
        let replLbl = NSTextField(labelWithString: "Replace:")
        let tmplLbl = NSTextField(labelWithString: "Template:")
        let startLbl = NSTextField(labelWithString: "Start #")
        let padLbl = NSTextField(labelWithString: "Pad")
        for l in [findLbl, replLbl, tmplLbl, startLbl, padLbl] {
            l.translatesAutoresizingMaskIntoConstraints = false
            l.font = NSFont.systemFont(ofSize: 12)
            l.alignment = .right
            l.textColor = .secondaryLabelColor
            cv.addSubview(l)
        }

        for f in [findField, replField, templateField, startField, padField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.bezelStyle = .roundedBezel
            f.font = NSFont.systemFont(ofSize: 12)
            f.delegate = self
            cv.addSubview(f)
        }
        templateField.stringValue = "{name}"
        templateField.placeholderString = "{name} {ext} {N} {date:YYYY-MM-DD} {exif} {title}"
        startField.stringValue = "1"
        startField.alignment = .right
        padField.stringValue = "3"
        padField.alignment = .right

        regexCheck.translatesAutoresizingMaskIntoConstraints = false
        regexCheck.target = self
        regexCheck.action = #selector(rebuildPreview)
        cv.addSubview(regexCheck)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        previewTable.style = .inset
        previewTable.rowHeight = 22
        previewTable.headerView = NSTableHeaderView()
        let c1 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("old")); c1.title = "Original"; c1.width = 280
        let c2 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("arrow")); c2.title = ""; c2.width = 18
        let c3 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("new")); c3.title = "New"; c3.width = 320
        for c in [c1, c2, c3] { previewTable.addTableColumn(c) }
        previewTable.dataSource = self
        previewTable.delegate = self
        scroll.documentView = previewTable
        cv.addSubview(scroll)

        applyButton.translatesAutoresizingMaskIntoConstraints = false
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.target = self
        applyButton.action = #selector(commit)
        cv.addSubview(applyButton)

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelSheet)
        cv.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            findLbl.topAnchor.constraint(equalTo: cv.topAnchor, constant: 14),
            findLbl.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 14),
            findLbl.widthAnchor.constraint(equalToConstant: 70),
            findField.centerYAnchor.constraint(equalTo: findLbl.centerYAnchor),
            findField.leadingAnchor.constraint(equalTo: findLbl.trailingAnchor, constant: 6),
            findField.widthAnchor.constraint(equalToConstant: 220),
            regexCheck.centerYAnchor.constraint(equalTo: findLbl.centerYAnchor),
            regexCheck.leadingAnchor.constraint(equalTo: findField.trailingAnchor, constant: 6),

            replLbl.topAnchor.constraint(equalTo: findLbl.bottomAnchor, constant: 8),
            replLbl.leadingAnchor.constraint(equalTo: findLbl.leadingAnchor),
            replLbl.widthAnchor.constraint(equalTo: findLbl.widthAnchor),
            replField.centerYAnchor.constraint(equalTo: replLbl.centerYAnchor),
            replField.leadingAnchor.constraint(equalTo: findField.leadingAnchor),
            replField.widthAnchor.constraint(equalTo: findField.widthAnchor),

            tmplLbl.topAnchor.constraint(equalTo: replLbl.bottomAnchor, constant: 8),
            tmplLbl.leadingAnchor.constraint(equalTo: findLbl.leadingAnchor),
            tmplLbl.widthAnchor.constraint(equalTo: findLbl.widthAnchor),
            templateField.centerYAnchor.constraint(equalTo: tmplLbl.centerYAnchor),
            templateField.leadingAnchor.constraint(equalTo: findField.leadingAnchor),
            templateField.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -14),

            startLbl.topAnchor.constraint(equalTo: tmplLbl.bottomAnchor, constant: 8),
            startLbl.leadingAnchor.constraint(equalTo: findLbl.leadingAnchor),
            startLbl.widthAnchor.constraint(equalTo: findLbl.widthAnchor),
            startField.centerYAnchor.constraint(equalTo: startLbl.centerYAnchor),
            startField.leadingAnchor.constraint(equalTo: findField.leadingAnchor),
            startField.widthAnchor.constraint(equalToConstant: 60),
            padLbl.centerYAnchor.constraint(equalTo: startLbl.centerYAnchor),
            padLbl.leadingAnchor.constraint(equalTo: startField.trailingAnchor, constant: 14),
            padField.centerYAnchor.constraint(equalTo: startLbl.centerYAnchor),
            padField.leadingAnchor.constraint(equalTo: padLbl.trailingAnchor, constant: 4),
            padField.widthAnchor.constraint(equalToConstant: 50),

            scroll.topAnchor.constraint(equalTo: startLbl.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: applyButton.topAnchor, constant: -12),

            applyButton.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -14),
            applyButton.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -14),
            cancelButton.trailingAnchor.constraint(equalTo: applyButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: applyButton.centerYAnchor),
        ])
    }

    func controlTextDidChange(_ obj: Notification) { rebuildPreview() }

    @objc private func rebuildPreview() {
        let find = findField.stringValue
        let repl = replField.stringValue
        let tmpl = templateField.stringValue.isEmpty ? "{name}" : templateField.stringValue
        let useRegex = regexCheck.state == .on
        let start = Int(startField.stringValue) ?? 1
        let pad = max(0, Int(padField.stringValue) ?? 3)

        var seen = Set<String>()
        rows = items.enumerated().map { (idx, item) in
            let baseName = (item.name as NSString).deletingPathExtension
            let ext = (item.name as NSString).pathExtension
            var working = applyFindReplace(in: baseName, find: find, repl: repl, useRegex: useRegex)
            working = applyTemplate(tmpl, base: working, ext: ext, item: item, idx: idx, start: start, pad: pad)
            // Append ext if template did not include one
            var final = working
            if !tmpl.contains("{ext}") && !ext.isEmpty {
                final = final + "." + ext
            }
            let conflict = seen.contains(final.lowercased())
            seen.insert(final.lowercased())
            return Row(url: item.url, oldName: item.name, newName: final, conflict: conflict)
        }
        previewTable.reloadData()
    }

    private func applyFindReplace(in s: String, find: String, repl: String, useRegex: Bool) -> String {
        if find.isEmpty { return s }
        if useRegex {
            guard let re = try? NSRegularExpression(pattern: find) else { return s }
            let range = NSRange(s.startIndex..., in: s)
            return re.stringByReplacingMatches(in: s, range: range, withTemplate: repl)
        }
        return s.replacingOccurrences(of: find, with: repl)
    }

    private func applyTemplate(_ tmpl: String, base: String, ext: String,
                               item: FileItem, idx: Int, start: Int, pad: Int) -> String {
        var s = tmpl
        s = s.replacingOccurrences(of: "{name}", with: base)
        s = s.replacingOccurrences(of: "{ext}", with: ext)
        let num = start + idx
        let numStr = pad > 0 ? String(format: "%0\(pad)d", num) : String(num)
        s = s.replacingOccurrences(of: "{N}", with: numStr)
        // {date:FORMAT}
        if s.contains("{date:") {
            let f = DateFormatter()
            // Find each occurrence and substitute
            while let lo = s.range(of: "{date:"),
                  let hi = s.range(of: "}", range: lo.upperBound..<s.endIndex) {
                let fmt = String(s[lo.upperBound..<hi.lowerBound])
                f.dateFormat = fmt
                let str = f.string(from: item.modified)
                s = s.replacingCharacters(in: lo.lowerBound..<hi.upperBound, with: str)
            }
        }
        if s.contains("{exif}") {
            let exif = exifDateString(at: item.url) ?? "noexif"
            s = s.replacingOccurrences(of: "{exif}", with: exif)
        }
        if s.contains("{title}") {
            let title = mediaTitle(at: item.url) ?? base
            s = s.replacingOccurrences(of: "{title}", with: title)
        }
        return s
    }

    private func exifDateString(at url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return nil }
        if let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let date = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            // EXIF format "YYYY:MM:DD HH:MM:SS"; turn into "YYYY-MM-DD"
            return date.replacingOccurrences(of: ":", with: "-").prefix(10).description
        }
        return nil
    }

    private func mediaTitle(at url: URL) -> String? {
        let asset = AVURLAsset(url: url)
        for key in [AVMetadataKey.commonKeyTitle.rawValue] {
            for item in asset.commonMetadata {
                if item.commonKey?.rawValue == key, let v = item.stringValue {
                    return v
                }
            }
        }
        return nil
    }

    @objc private func commit() {
        let fm = FileManager.default
        var renamed = 0
        for r in rows where !r.conflict && r.oldName != r.newName && !r.newName.isEmpty {
            let dst = r.url.deletingLastPathComponent().appendingPathComponent(r.newName)
            if fm.fileExists(atPath: dst.path) { continue }
            do {
                try fm.moveItem(at: r.url, to: dst)
                renamed += 1
            } catch { /* skip */ }
        }
        target?.testActivePane?.reload()
        cancelSheet()
        if renamed > 0 {
            NSSound(named: "Pop")?.play()
        }
    }

    @objc private func cancelSheet() {
        if let w = window, let parent = w.sheetParent {
            parent.endSheet(w)
        } else {
            window?.close()
        }
    }

    // MARK: NSTableViewDataSource
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        let id = tableColumn?.identifier.rawValue ?? ""
        let text: String
        let color: NSColor
        switch id {
        case "old":   text = r.oldName; color = .secondaryLabelColor
        case "arrow": text = "→";       color = .tertiaryLabelColor
        case "new":   text = r.newName; color = r.conflict ? .systemRed : .labelColor
        default:      text = "";        color = .labelColor
        }
        let cellId = NSUserInterfaceItemIdentifier("BRCell")
        let cell = (tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTableCellView) ?? {
            let v = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingMiddle
            tf.font = NSFont.systemFont(ofSize: 12)
            v.addSubview(tf); v.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: v.centerYAnchor)
            ])
            v.identifier = cellId
            return v
        }()
        cell.textField?.stringValue = text
        cell.textField?.textColor = color
        return cell
    }
}
