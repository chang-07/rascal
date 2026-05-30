import AppKit

/// A small control that records a keyboard shortcut. Click it, press a combo,
/// and `onRecord` fires with the captured `KeyShortcut` (or nil if the user
/// pressed Delete/Backspace to clear). Esc cancels recording.
///
/// Recording rules:
///   - At least one of Command / Control / Option is required (Shift alone is
///     not a valid menu modifier).
///   - Bare modifier presses are ignored until a real key arrives.
///   - The captured `key` is the lowercased base character; Shift is kept as
///     an explicit modifier.
final class ShortcutRecorderView: NSView {

    var onRecord: ((KeyShortcut?) -> Void)?

    var shortcut: KeyShortcut? {
        didSet { needsDisplay = true }
    }

    private var recording = false {
        didSet { needsDisplay = true; updateTracking() }
    }
    private var trackingArea: NSTrackingArea?
    private var hovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 120, height: 22) }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTracking()
    }
    private func updateTracking() {
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        if recording {
            stopRecording()
        } else {
            window?.makeFirstResponder(self)
            recording = true
        }
    }

    override func becomeFirstResponder() -> Bool { true }
    override func resignFirstResponder() -> Bool {
        recording = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        // Esc cancels.
        if event.keyCode == 53 { stopRecording(); return }
        // Delete / Backspace clears the binding.
        if event.keyCode == 51 || event.keyCode == 117 {
            shortcut = nil
            onRecord?(nil)
            stopRecording()
            return
        }
        guard let chars = event.charactersIgnoringModifiers, let first = chars.first else { return }
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // Require at least one "real" modifier.
        guard !mods.intersection([.command, .control, .option]).isEmpty else {
            NSSound.beep()
            return
        }
        let key = String(first).lowercased()
        let captured = KeyShortcut(key, mods)
        shortcut = captured
        onRecord?(captured)
        stopRecording()
    }

    /// Swallow modifier-only flag changes during recording so they don't beep.
    override func flagsChanged(with event: NSEvent) {
        if !recording { super.flagsChanged(with: event) }
    }

    private func stopRecording() {
        recording = false
        window?.makeFirstResponder(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg: NSColor
        let border: NSColor
        if recording {
            bg = ThemeManager.shared.effectiveAccent.withAlphaComponent(0.15)
            border = ThemeManager.shared.effectiveAccent
        } else if hovering {
            bg = NSColor.labelColor.withAlphaComponent(0.06)
            border = NSColor.separatorColor
        } else {
            bg = NSColor.controlBackgroundColor
            border = NSColor.separatorColor
        }
        bg.setFill()
        border.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        path.fill()
        path.stroke()

        let text: String
        let color: NSColor
        if recording {
            text = "Type shortcut…"
            color = ThemeManager.shared.effectiveAccent
        } else if let s = shortcut {
            text = s.displayLabel
            color = .labelColor
        } else {
            text = "Click to set"
            color = .tertiaryLabelColor
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: recording ? .medium : .regular),
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let rect = NSRect(x: (bounds.width - size.width) / 2,
                          y: (bounds.height - size.height) / 2,
                          width: size.width, height: size.height)
        (text as NSString).draw(in: rect, withAttributes: attrs)
    }
}
