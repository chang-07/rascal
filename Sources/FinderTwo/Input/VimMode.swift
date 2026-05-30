import AppKit

/// Modal keyboard handler that mirrors a small but very useful subset of vim
/// for navigating the file list. Active when ON in settings AND the file list
/// has focus. Defers to the table view for any key it does not understand.
///
/// Normal mode bindings:
///   h           Enclosing folder
///   j / k       Move selection down / up   (prefix with count, e.g. 5j)
///   l           Open selection
///   gg          Top
///   G           Bottom
///   gt          Next tab
///   gT          Previous tab
///   t           New tab
///   r           Rename selected
///   yy          Copy selected
///   dd          Move-to-trash selected
///   p           Paste
///   /           Open filter (live filter)
///   :           Open command palette
///   v           Visual mode (extend selection by j/k)
///   Esc / <C-c> Cancel visual / clear pending count
final class VimMode {
    static let shared = VimMode()

    enum Mode { case normal, visual }
    private(set) var enabled: Bool = UserDefaults.standard.bool(forKey: "FinderTwo.vimEnabled")
    private(set) var mode: Mode = .normal
    private var pending: String = ""    // pending keystrokes (e.g. "g" awaiting "g" or "t")
    private var count: Int = 0          // numeric prefix (e.g. 5j)
    private var visualAnchor: Int?       // row anchor when in visual mode

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "FinderTwo.vimEnabled")
        reset()
    }

    func reset() {
        pending = ""
        count = 0
        mode = .normal
        visualAnchor = nil
    }

    /// Returns true if the event was consumed; false to let the table handle it.
    @discardableResult
    func handle(event: NSEvent, in pane: PaneController, fileList: FileListController) -> Bool {
        guard enabled else { return false }
        // Ignore if modifiers are present (we want pure-letter bindings)
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        if !mods.isEmpty { return false }
        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return false }

        // Esc cancels everything
        if chars == "\u{1b}" {
            reset()
            return true
        }
        // Return / Enter — open the selection (enter a folder or open a file).
        // In vim mode this takes priority over Finder's "Return = rename", which
        // is what made it impossible to enter folders with the keyboard.
        if chars == "\r" || chars == "\n" {
            reset()
            pane.openSelection()
            return true
        }
        // Pending two-char sequences
        if !pending.isEmpty {
            let combined = pending + chars
            pending = ""
            switch combined {
            case "gg":
                pane.vimSelectFirst()
                return true
            case "gt":
                stepTab(in: pane, forward: true)
                return true
            case "gT":
                stepTab(in: pane, forward: false)
                return true
            case "yy":
                pane.copySelection()
                return true
            case "dd":
                let urls = pane.selectedURLs()
                if !urls.isEmpty { FileOps.trashWithConfirmation(urls) }
                return true
            default:
                // unknown combo — fall through as no-op
                return true
            }
        }
        // Numeric count prefix
        if let n = Int(chars), chars.count == 1, n >= 0 && n <= 9 {
            if !(count == 0 && n == 0) {       // "0" alone goes to top-of-row, but for now we ignore
                count = count * 10 + n
                return true
            }
        }

        let repeatCount = max(1, count)
        defer { count = 0 }

        switch chars {
        case "h":
            pane.goUp()
            return true
        case "j":
            for _ in 0..<repeatCount { pane.vimMove(by: 1) }
            applyVisualExtend(fileList: fileList)
            return true
        case "k":
            for _ in 0..<repeatCount { pane.vimMove(by: -1) }
            applyVisualExtend(fileList: fileList)
            return true
        case "l":
            pane.openSelection()
            return true
        case "G":
            pane.vimSelectLast()
            return true
        case "t":
            pane.newTab(at: nil)
            return true
        case "r":
            pane.beginRenameSelection()
            return true
        case "p":
            pane.pasteHere()
            return true
        case "/":
            pane.focusFilterFromVim()
            return true
        case ":":
            if let wc = fileList.view.window?.windowController as? BrowserWindowController {
                wc.showCommandPalette(nil)
            }
            return true
        case "v":
            if mode == .normal {
                mode = .visual
                visualAnchor = fileList.tableView.selectedRow
            } else {
                mode = .normal
                visualAnchor = nil
            }
            return true
        case "g", "y", "d":
            // Start a two-char sequence
            pending = chars
            return true
        default:
            return false
        }
    }

    private func stepTab(in pane: PaneController, forward: Bool) {
        let n = pane.testTabCount
        guard n > 1 else { NSSound.beep(); return }
        let cur = pane.testActiveTabIndex
        let next = (cur + (forward ? 1 : -1) + n) % n
        pane.selectTab(at: next)
    }

    private func applyVisualExtend(fileList: FileListController) {
        guard mode == .visual, let anchor = visualAnchor else { return }
        let now = fileList.tableView.selectedRow
        let lo = min(anchor, now)
        let hi = max(anchor, now)
        fileList.tableView.selectRowIndexes(IndexSet(integersIn: lo...hi), byExtendingSelection: false)
    }
}
