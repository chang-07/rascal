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
        retained.insert(controller)
        guard let window = controller.window else { return }
        let id = ObjectIdentifier(controller)
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            release(controller, id: id)
        }
        observers[id] = token
    }

    private static func release(_ controller: NSWindowController, id: ObjectIdentifier) {
        if let token = observers[id] {
            NotificationCenter.default.removeObserver(token)
            observers.removeValue(forKey: id)
        }
        retained.remove(controller)
    }
}
