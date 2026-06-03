import AppKit

/// A minimal "terminal panel" — not a full PTY, just a command-and-output
/// scrollback. The user types a shell command, hits Return, we run it via
/// `/bin/sh -c` in the pane's current directory, and stream stdout/stderr
/// into the scrollback. Cmd+` toggles. Plenty for `git status`, `ls -la`,
/// `make`, `npm test` — quick checks without leaving the file manager.
final class TerminalDrawerView: NSView, NSTextFieldDelegate, ThemeObserving {

    var cwd: URL = FileManager.default.homeDirectoryForCurrentUser {
        didSet { prompt.stringValue = shortPrompt(for: cwd) + " ❯ " }
    }

    private let scroll = NSScrollView()
    private let textView = NSTextView()
    let inputField = NSTextField()
    private let prompt = NSTextField(labelWithString: "")
    private var history: [String] = []
    private var historyCursor: Int = 0
    private var runningTask: Process?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 6)
        scroll.documentView = textView

        prompt.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        prompt.textColor = .systemGreen
        prompt.translatesAutoresizingMaskIntoConstraints = false

        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        inputField.bezelStyle = .roundedBezel
        inputField.isBordered = false
        inputField.drawsBackground = false
        inputField.focusRingType = .none
        inputField.placeholderString = "command"
        inputField.delegate = self

        let topLine = SeparatorView()
        topLine.translatesAutoresizingMaskIntoConstraints = false

        addSubview(topLine)
        addSubview(scroll)
        addSubview(prompt)
        addSubview(inputField)

        NSLayoutConstraint.activate([
            topLine.topAnchor.constraint(equalTo: topAnchor),
            topLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            topLine.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: prompt.topAnchor, constant: -4),
            prompt.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            prompt.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            inputField.leadingAnchor.constraint(equalTo: prompt.trailingAnchor, constant: 0),
            inputField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            inputField.centerYAnchor.constraint(equalTo: prompt.centerYAnchor),
        ])
        subscribeToTheme(self)
    }
    required init?(coder: NSCoder) { fatalError() }

    func focusInput() {
        window?.makeFirstResponder(inputField)
    }

    private func shortPrompt(for url: URL) -> String {
        let p = (url.path as NSString).abbreviatingWithTildeInPath
        return p
    }

    private func append(_ s: String, color: NSColor? = nil) {
        let actualColor = color ?? ThemeChrome.primary
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: actualColor,
        ]
        let attr = NSAttributedString(string: s, attributes: attrs)
        textView.textStorage?.append(attr)
        textView.scrollToEndOfDocument(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === inputField {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                let cmd = inputField.stringValue
                inputField.stringValue = ""
                if !cmd.isEmpty { runCommand(cmd) }
                return true
            case #selector(NSResponder.moveUp(_:)):
                if historyCursor > 0 { historyCursor -= 1; inputField.stringValue = history[historyCursor] }
                return true
            case #selector(NSResponder.moveDown(_:)):
                if historyCursor < history.count - 1 { historyCursor += 1; inputField.stringValue = history[historyCursor] }
                else { historyCursor = history.count; inputField.stringValue = "" }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                if let task = runningTask, task.isRunning {
                    task.terminate()
                    append("^C\n", color: .systemRed)
                    inputField.stringValue = ""
                    return true
                }
                return false
            default: return false
            }
        }
        return false
    }

    private func runCommand(_ cmd: String) {
        // Special "cd": change cwd without spawning a shell.
        let trimmed = cmd.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("cd ") || trimmed == "cd" {
            let arg = String(trimmed.dropFirst("cd".count)).trimmingCharacters(in: .whitespaces)
            let target: URL
            if arg.isEmpty {
                target = FileManager.default.homeDirectoryForCurrentUser
            } else if arg.hasPrefix("/") {
                target = URL(fileURLWithPath: arg)
            } else if arg.hasPrefix("~") {
                target = URL(fileURLWithPath: (arg as NSString).expandingTildeInPath)
            } else {
                target = cwd.appendingPathComponent(arg)
            }
            if FileManager.default.fileExists(atPath: target.path) {
                cwd = target.standardizedFileURL
                append("\(shortPrompt(for: cwd)) ❯ cd \(arg)\n", color: ThemeChrome.secondary)
            } else {
                append("cd: no such directory: \(arg)\n", color: .systemRed)
            }
            history.append(cmd); historyCursor = history.count
            return
        }

        // Interrupt any existing running task before starting a new one
        if let task = runningTask, task.isRunning {
            task.terminate()
            append("^C\n", color: .systemRed)
        }

        append("\(shortPrompt(for: cwd)) ❯ \(cmd)\n", color: ThemeChrome.secondary)

        let p = Process()
        p.launchPath = Settings.terminalShell
        p.arguments = ["-l", "-c", cmd]
        p.currentDirectoryURL = cwd
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        runningTask = p


        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.append(s) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.append(s, color: .systemRed) }
        }

        do { try p.run() }
        catch {
            // Clear the readability handlers so the pipe FDs + dispatch sources
            // don't leak when the shell fails to launch (they're otherwise only
            // cleared on the success path's waitUntilExit).
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            runningTask = nil
            append("failed to launch: \(error)\n", color: .systemRed)
            return
        }
        history.append(cmd)
        historyCursor = history.count
        // Capture the process (to keep it alive for the wait) but NOT self —
        // otherwise a long/hung command pins the whole pane/view tree and
        // defeats deinit's terminate() until the command exits.
        DispatchQueue.global().async { [weak self] in
            p.waitUntilExit()
            DispatchQueue.main.async {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                if p.terminationStatus != 0 {
                    self?.append("exit \(p.terminationStatus)\n", color: ThemeChrome.secondary)
                }
            }
        }
    }

    @objc func applyTheme() {
        let t = ThemeManager.shared.current
        layer?.backgroundColor = t.background.cgColor
        textView.backgroundColor = .clear
        textView.textColor = t.labelPrimary
        textView.insertionPointColor = t.accent
        prompt.textColor = t.accent
        inputField.textColor = t.labelPrimary
    }

    /// Terminate any in-flight command. Called when the drawer is hidden so a
    /// long-running command (e.g. `tail -f`) doesn't keep running off-screen
    /// until the next command, Ctrl-C, or window teardown.
    func terminateRunning() {
        if runningTask?.isRunning == true { runningTask?.terminate() }
    }

    deinit {
        // Don't leave a child process running if the drawer/window is torn down.
        if runningTask?.isRunning == true { runningTask?.terminate() }
    }
}
