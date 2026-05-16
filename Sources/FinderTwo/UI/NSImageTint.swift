import AppKit

extension NSImage {
    /// Returns a copy of the receiver tinted by `color`. Used for sidebar tag
    /// dots and SF Symbol coloring.
    func tinted(_ color: NSColor) -> NSImage {
        let copy = self.copy() as! NSImage
        copy.lockFocus()
        color.set()
        let imgRect = NSRect(origin: .zero, size: copy.size)
        imgRect.fill(using: .sourceAtop)
        copy.unlockFocus()
        copy.isTemplate = false
        return copy
    }
}
