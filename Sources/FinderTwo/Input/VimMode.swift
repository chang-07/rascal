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

    /// Posted whenever the visible vim state changes (enabled, mode, pending
    /// operator, or count) so the status bar can show a current indicator.
    static let stateDidChange = Notification.Name("FinderTwo.vimStateDidChange")

    enum Mode { case normal, visual }
    private(set) var enabled: Bool = UserDefaults.standard.bool(forKey: "FinderTwo.vimEnabled")
    private(set) var mode: Mode = .normal
    private var pending: String = ""    // pending keystrokes (e.g. "g" awaiting "g" or "t")
    private var count: Int = 0          // numeric prefix (e.g. 5j)
    private var visualAnchor: Int?       // row anchor when in visual mode

    /// Compact indicator for the status bar: "" when vim is off, otherwise the
    /// mode plus any in-progress count/operator (e.g. "NORMAL", "VISUAL",
    /// "NORMAL  3d"). Mirrors what vim shows in its bottom-right.
    var statusText: String {
        guard enabled else { return "" }
        var s = (mode == .visual) ? "VISUAL" : "NORMAL"
        var pend = ""
        if count > 0 { pend += "\(count)" }
        pend += (pending == "ctrl-b") ? "^b" : pending
        if !pend.isEmpty { s += "  " + pend }
        return s
    }

    private func postState() {
        NotificationCenter.default.post(name: VimMode.stateDidChange, object: nil)
    }

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
        postState()
    }

    /// Returns true if the event was consumed; false to let the table handle it.
    @discardableResult
    func handle(event: NSEvent, in pane: PaneController, fileList: FileListController) -> Bool {
        guard enabled else { return false }
        defer { postState() }   // refresh the status-bar indicator after any state change
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        let isCtrlB = mods == .control && event.charactersIgnoringModifiers == "b"
        if !mods.isEmpty && !isCtrlB && pending != "ctrl-b" { return false }
        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return false }

        // Esc cancels everything
        if chars == "\u{1b}" {
            reset()
            return true
        }

        // Handle Ctrl-b window command when it's pending
        if pending == "ctrl-b" {
            pending = ""
            reset()
            if let wc = fileList.view.window?.windowController as? BrowserWindowController {
                let char = chars.lowercased()
                let scalar = chars.unicodeScalars.first
                
                let isNextCtrlB = event.modifierFlags.contains(.control) && event.charactersIgnoringModifiers == "b"
                let isShift = event.modifierFlags.contains(.shift)
                
                if char == "b" || isNextCtrlB {
                    if isShift {
                        wc.focusPrevPane(nil)
                    } else {
                        wc.focusNextPane(nil)
                    }
                } else if char == "h" || scalar?.value == 0xF702 { // NSLeftArrowFunctionKey
                    wc.focusBufferLeft()
                } else if char == "l" || scalar?.value == 0xF703 { // NSRightArrowFunctionKey
                    wc.focusBufferRight()
                } else if char == "j" || scalar?.value == 0xF701 { // NSDownArrowFunctionKey
                    wc.focusBufferDown()
                } else if char == "k" || scalar?.value == 0xF700 { // NSUpArrowFunctionKey
                    wc.focusBufferUp()
                }
            }
            return true
        }

        // Initiate Ctrl-b sequence
        if isCtrlB {
            pending = "ctrl-b"
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
            let rep = max(1, count)
            count = 0
            switch combined {
            case "gg":
                pane.vimSelectFirst()
                return true
            case "gt":
                stepTab(in: pane, forward: true, count: rep)
                return true
            case "gT":
                stepTab(in: pane, forward: false, count: rep)
                return true
            case "yy":
                pane.copySelection()
                mode = .normal; visualAnchor = nil   // operator consumes the visual selection
                return true
            case "dd":
                let urls = pane.selectedURLs()
                if !urls.isEmpty { FileOps.trashWithConfirmation(urls) }
                mode = .normal; visualAnchor = nil   // exit visual; don't leave a stale anchor
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

        // Start a two-char sequence without clearing the count
        if chars == "g" || chars == "y" || chars == "d" {
            pending = chars
            return true
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
        case "/", "?":
            pane.focusFilterFromVim()
            return true
        case ":":
            if let wc = fileList.view.window?.windowController as? BrowserWindowController {
                wc.showCommandPalette(nil)
            }
            return true
        case "v":
            if mode == .normal {
                // selectedRow is -1 with no selection; entering visual mode then
                // would build IndexSet(integersIn:) from a negative bound and trap.
                guard fileList.tableView.selectedRow >= 0 else { NSSound.beep(); return true }
                mode = .visual
                visualAnchor = fileList.tableView.selectedRow
            } else {
                mode = .normal
                visualAnchor = nil
            }
            return true
        default:
            return false
        }
    }

    private func stepTab(in pane: PaneController, forward: Bool, count: Int = 1) {
        let n = pane.testTabCount
        guard n > 1 else { NSSound.beep(); return }
        let cur = pane.testActiveTabIndex
        let delta = (forward ? count : -count) % n
        let next = (cur + delta + n) % n
        pane.selectTab(at: next)
    }

    private func applyVisualExtend(fileList: FileListController) {
        guard mode == .visual, let anchor = visualAnchor, anchor >= 0 else { return }
        let now = fileList.tableView.selectedRow
        guard now >= 0 else { return }
        let lo = min(anchor, now)
        let hi = max(anchor, now)
        fileList.tableView.selectRowIndexes(IndexSet(integersIn: lo...hi), byExtendingSelection: false)
    }
}
