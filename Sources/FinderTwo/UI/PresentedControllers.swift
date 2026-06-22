import AppKit

/// Keeps sheet / auxiliary-window controllers alive for as long as their
/// window is on screen.
///
/// Background: `NSWindow` does **not** keep a strong reference to its
/// `windowController`. So the common idiom
///
///     static func show(...) {
///         let c = SomeController(...)
///         wc.window?.beginSheet(c.window!)   // c goes out of scope here!
///     }
///
/// deallocates `c` as soon as `show` returns. The sheet's window survives
/// (the sheet machinery retains it), but every button whose `target` is the
/// now-dead controller becomes a dangling pointer → crash on click.
///
/// `PresentedControllers.retain(_:)` parks the controller in a set and frees
/// it when its window closes, so the controller lives exactly as long as the
/// UI it owns.
enum PresentedControllers {
    private static var retained: Set<NSWindowController> = []
    private static var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

    static func retain(_ controller: NSWindowController) {
        // Only park the controller once we can observe its window closing —
        // otherwise (window == nil) it would be inserted but never released,
        // a permanent leak.
        guard let window = controller.window else { return }
        retained.insert(controller)
        let id = ObjectIdentifier(controller)
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            release(controller, id: id)
        }
        observers[id] = token
    }

    /// The first on-screen retained controller of the given type, if any. Lets
    /// single-instance overlays (Command Palette, the search finders) find an
    /// already-open copy instead of stacking a second one.
    static func existing<T: NSWindowController>(_ type: T.Type) -> T? {
        retained.first { $0 is T } as? T
    }

    private static func release(_ controller: NSWindowController, id: ObjectIdentifier) {
        if let token = observers[id] {
            NotificationCenter.default.removeObserver(token)
            observers.removeValue(forKey: id)
        }
        retained.remove(controller)
    }
}
