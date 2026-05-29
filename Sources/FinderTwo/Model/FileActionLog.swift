import Foundation

/// A lightweight, app-wide undo/redo stack for file operations. Each action
/// carries an inverse (and a redo) closure; both return success so a failed
/// undo doesn't corrupt the stack. Used instead of NSUndoManager because file
/// ops run off the main thread and aren't tied to a responder.
final class FileActionLog {
    static let shared = FileActionLog()

    struct Action {
        let name: String
        let undo: () -> Bool
        let redo: () -> Bool
    }

    private var _undoStack: [Action] = []
    private var _redoStack: [Action] = []
    // Stacks are touched from the main thread (menu) AND the transfer worker,
    // so guard them with a lock.
    private let lock = NSLock()
    /// Posted (on main) whenever the stacks change, so menus can refresh.
    static let didChange = Notification.Name("FinderTwo.fileActionLogDidChange")

    var canUndo: Bool { lock.lock(); defer { lock.unlock() }; return !_undoStack.isEmpty }
    var canRedo: Bool { lock.lock(); defer { lock.unlock() }; return !_redoStack.isEmpty }
    var undoName: String? { lock.lock(); defer { lock.unlock() }; return _undoStack.last?.name }
    var redoName: String? { lock.lock(); defer { lock.unlock() }; return _redoStack.last?.name }

    /// Record a new action. Clears the redo stack (a fresh action forks history).
    /// Safe to call from any thread.
    func record(_ name: String, undo: @escaping () -> Bool, redo: @escaping () -> Bool) {
        lock.lock()
        _undoStack.append(Action(name: name, undo: undo, redo: redo))
        if _undoStack.count > 100 { _undoStack.removeFirst() }
        _redoStack.removeAll()
        lock.unlock()
        notify()
    }

    @discardableResult
    func performUndo() -> Bool {
        lock.lock(); let a = _undoStack.popLast(); lock.unlock()
        guard let a else { return false }
        let ok = a.undo()
        if ok { lock.lock(); _redoStack.append(a); lock.unlock() }
        notify()
        return ok
    }

    @discardableResult
    func performRedo() -> Bool {
        lock.lock(); let a = _redoStack.popLast(); lock.unlock()
        guard let a else { return false }
        let ok = a.redo()
        if ok { lock.lock(); _undoStack.append(a); lock.unlock() }
        notify()
        return ok
    }

    func clear() {
        lock.lock(); _undoStack.removeAll(); _redoStack.removeAll(); lock.unlock()
        notify()
    }

    private func notify() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: FileActionLog.didChange, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: FileActionLog.didChange, object: nil)
            }
        }
    }

    // MARK: Reversible-op helpers (build the inverse closures for callers)

    private static let fm = FileManager.default

    /// Record a rename/move A→B that's undone by moving B→A.
    func recordMove(from src: URL, to dst: URL, name: String) {
        record(name,
            undo: { Self.safeMove(dst, src) },
            redo: { Self.safeMove(src, dst) })
    }

    /// Record creation of `url` (new file/folder/copy) — undo trashes it,
    /// redo can't reliably recreate arbitrary content, so it's a no-op that
    /// simply keeps the stack consistent.
    func recordCreate(_ url: URL, name: String) {
        record(name,
            undo: { (try? Self.fm.trashItem(at: url, resultingItemURL: nil)) != nil },
            redo: { true })
    }

    /// Record a move-to-trash: `original` was trashed to `trashedURL`.
    /// Undo restores it; redo re-trashes.
    func recordTrash(original: URL, trashedURL: URL, name: String) {
        record(name,
            undo: { Self.safeMove(trashedURL, original) },
            redo: {
                if let u = try? Self.fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: original, create: false) {
                    _ = u  // best-effort; trashItem below is the real work
                }
                return (try? Self.fm.trashItem(at: original, resultingItemURL: nil)) != nil
            })
    }

    private static func safeMove(_ from: URL, _ to: URL) -> Bool {
        guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { return false }
        try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? fm.moveItem(at: from, to: to)) != nil
    }
}
