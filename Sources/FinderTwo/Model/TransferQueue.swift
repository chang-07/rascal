import AppKit

/// Thread-safe cancel flag shared between the activity UI (main) and the
/// transfer worker (background).
final class TransferCancelFlag {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func cancel() { lock.lock(); _value = true; lock.unlock() }
}

/// One queued copy/move (the resolved plan from one `FileOps.transfer` call).
final class TransferOp {
    enum State { case waiting, running, paused, done, cancelled, failed }
    let id: Int
    let move: Bool
    let plan: [(src: URL, dst: URL, merge: Bool)]
    let label: String
    var state: State = .waiting
    var totalBytes: Int64 = 0
    var bytesDone: Int64 = 0
    var currentName: String = ""
    var failures = 0
    let cancelFlag = TransferCancelFlag()

    init(id: Int, move: Bool, plan: [(src: URL, dst: URL, merge: Bool)]) {
        self.id = id; self.move = move; self.plan = plan
        self.label = plan.count == 1 ? plan[0].src.lastPathComponent : "\(plan.count) items"
    }
    var fraction: Double { totalBytes > 0 ? min(1, Double(bytesDone) / Double(totalBytes)) : (state == .done ? 1 : 0) }
}

/// A single serial queue of file transfers with global pause/resume and
/// per-op / all cancellation. Copies are streamed in chunks so the active
/// operation can pause or cancel mid-file (same-volume moves are instant
/// renames and need neither). The activity panel observes `onChange`.
final class TransferQueue {
    static let shared = TransferQueue()

    var onChange: (() -> Void)?            // always delivered on main
    private(set) var ops: [TransferOp] = []
    var snapshot: [TransferOp] { lock.lock(); defer { lock.unlock() }; return ops }
    var activeCount: Int { snapshot.filter { $0.state == .running || $0.state == .waiting || $0.state == .paused }.count }

    private let lock = NSLock()
    private let worker = DispatchQueue(label: "FinderTwo.transferqueue", qos: .userInitiated)
    private let cond = NSCondition()
    private var paused = false
    private var active = false
    private var nextId = 1
    private var lastNotify: TimeInterval = 0
    private let fm = FileManager.default

    var isPaused: Bool { cond.lock(); defer { cond.unlock() }; return paused }

    // MARK: Public control

    @discardableResult
    func enqueue(plan: [(src: URL, dst: URL, merge: Bool)], move: Bool) -> TransferOp {
        lock.lock()
        let op = TransferOp(id: nextId, move: move, plan: plan)
        nextId += 1
        ops.append(op)
        lock.unlock()
        
        let opCopy = op
        DispatchQueue.global(qos: .userInitiated).async {
            let bytes = plan.reduce(0) { $0 + Self.size(of: $1.src) }
            DispatchQueue.main.async {
                opCopy.totalBytes = bytes
                self.notify(force: true)
            }
        }
        
        notify(force: true)
        kick()
        return op
    }

    func setPaused(_ p: Bool) {
        cond.lock(); paused = p; cond.broadcast(); cond.unlock()
        notify(force: true)
    }

    func cancel(_ op: TransferOp) {
        op.cancelFlag.cancel()
        if op.state == .waiting { op.state = .cancelled }
        cond.lock(); cond.broadcast(); cond.unlock()   // wake if paused
        notify(force: true)
    }

    func cancelAll() {
        for op in snapshot { op.cancelFlag.cancel(); if op.state == .waiting { op.state = .cancelled } }
        cond.lock(); cond.broadcast(); cond.unlock()
        notify(force: true)
    }

    /// Drop finished/cancelled/failed rows from the list.
    func clearFinished() {
        lock.lock()
        ops.removeAll { $0.state == .done || $0.state == .cancelled || $0.state == .failed }
        lock.unlock()
        notify(force: true)
    }

    // MARK: Worker

    private func kick() {
        lock.lock()
        if active { lock.unlock(); return }
        active = true
        lock.unlock()
        worker.async { [weak self] in self?.drain() }
    }

    private func drain() {
        while true {
            guard let op = nextWaiting() else {
                lock.lock()
                if ops.contains(where: { $0.state == .waiting }) { lock.unlock(); continue }
                active = false; lock.unlock(); return
            }
            if op.cancelFlag.value { op.state = .cancelled; notify(force: true); continue }
            run(op)
        }
    }

    private func nextWaiting() -> TransferOp? {
        lock.lock(); defer { lock.unlock() }
        return ops.first { $0.state == .waiting }
    }

    private func run(_ op: TransferOp) {
        op.state = .running; notify(force: true)
        // Successfully-completed, non-merge steps, for undo registration.
        var done: [(src: URL, dst: URL)] = []
        for step in op.plan {
            if op.cancelFlag.value { break }
            waitWhilePaused(op)
            if op.cancelFlag.value { break }
            op.currentName = step.src.lastPathComponent; notify(force: true)
            var ok = true
            if step.merge {
                ok = FileOps.mergeDirectory(src: step.src, into: step.dst, move: op.move) == 0
                op.bytesDone += Self.size(of: step.dst)
            } else if op.move && sameVolume(step.src, step.dst) {
                ok = (try? fm.moveItem(at: step.src, to: step.dst)) != nil
                op.bytesDone += Self.size(of: step.dst)
            } else if isDir(step.src) {
                ok = copyTree(step.src, into: step.dst, op: op)
                if ok && op.move { try? fm.removeItem(at: step.src) }
            } else {
                ok = copyFile(step.src, to: step.dst, op: op)
                if ok && op.move { try? fm.removeItem(at: step.src) }
            }
            if ok && !step.merge { done.append((step.src, step.dst)) }
            if !ok && !op.cancelFlag.value { op.failures += 1 }
            notify(force: true)
        }
        op.state = op.cancelFlag.value ? .cancelled : (op.failures > 0 ? .failed : .done)
        registerUndo(op, done: done)
        notify(force: true)
    }

    /// Register an undo for the completed steps: a move reverses src↔dst; a
    /// copy is undone by trashing the destinations (merges are not recorded).
    private func registerUndo(_ op: TransferOp, done: [(src: URL, dst: URL)]) {
        guard !done.isEmpty else { return }
        let fm = self.fm
        let move = op.move
        let name = (move ? "Move " : "Copy ") + (done.count == 1 ? "Item" : "\(done.count) Items")
        // FileActionLog is thread-safe, so record straight from the worker.
        FileActionLog.shared.record(name,
            undo: {
                if move {
                    done.forEach { try? fm.moveItem(at: $0.dst, to: $0.src) }
                } else {
                    done.forEach { try? fm.trashItem(at: $0.dst, resultingItemURL: nil) }
                }
                return true
            },
            redo: {
                done.forEach {
                    if move { try? fm.moveItem(at: $0.src, to: $0.dst) }
                    else { try? fm.copyItem(at: $0.src, to: $0.dst) }
                }
                return true
            })
    }

    private func waitWhilePaused(_ op: TransferOp) {
        cond.lock()
        while paused && !op.cancelFlag.value {
            op.state = .paused
            DispatchQueue.main.async { self.onChange?() }
            cond.wait()
        }
        if !op.cancelFlag.value && op.state == .paused { op.state = .running }
        cond.unlock()
    }

    // MARK: Streamed copy (pausable / cancellable mid-file)

    private func copyFile(_ src: URL, to dst: URL, op: TransferOp) -> Bool {
        guard let input = InputStream(url: src) else { return false }
        fm.createFile(atPath: dst.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: dst) else { input.close(); return false }
        input.open()
        defer { input.close(); try? out.close() }
        let cap = 256 * 1024
        var buf = [UInt8](repeating: 0, count: cap)
        while true {
            if op.cancelFlag.value { try? fm.removeItem(at: dst); return false }
            waitWhilePaused(op)
            if op.cancelFlag.value { try? fm.removeItem(at: dst); return false }
            let n = input.read(&buf, maxLength: cap)
            if n < 0 { return false }
            if n == 0 { break }
            do { try out.write(contentsOf: Data(buf[0..<n])) } catch { return false }
            op.bytesDone += Int64(n)
            notify(force: false)
        }
        // Preserve mode + modification date.
        if let attrs = try? fm.attributesOfItem(atPath: src.path) {
            var keep: [FileAttributeKey: Any] = [:]
            if let m = attrs[.posixPermissions] { keep[.posixPermissions] = m }
            if let d = attrs[.modificationDate] { keep[.modificationDate] = d }
            try? fm.setAttributes(keep, ofItemAtPath: dst.path)
        }
        return true
    }

    private func copyTree(_ src: URL, into dst: URL, op: TransferOp) -> Bool {
        if op.cancelFlag.value { return false }
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
        var ok = true
        let kids = (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        for child in kids {
            if op.cancelFlag.value { return false }
            let target = dst.appendingPathComponent(child.lastPathComponent)
            if isDir(child) { if !copyTree(child, into: target, op: op) { ok = false } }
            else { if !copyFile(child, to: target, op: op) { ok = false } }
        }
        return ok
    }

    // MARK: Helpers

    private func isDir(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let va = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let vb = try? b.deletingLastPathComponent().resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        guard let va = va as? NSObject, let vb = vb as? NSObject else { return false }
        return va.isEqual(vb)
    }

    static func size(of url: URL) -> Int64 {
        let rv = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if rv?.isDirectory == true { return FileListController.recursiveSize(url) }
        return Int64(rv?.fileSize ?? 0)
    }

    private func notify(force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if !force && now - lastNotify < 1.0 / 30.0 { return }
        lastNotify = now
        DispatchQueue.main.async { self.onChange?() }
    }
}
