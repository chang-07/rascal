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
    let cancelFlag = TransferCancelFlag()

    // These progress fields are written by the transfer worker and read by the
    // activity UI on main, so each access is guarded — without this, the UI can
    // tear-read `currentName` (a String) mid-write and crash on a bad ARC
    // retain. Worker is the sole writer of each, so `+=` RMW stays correct.
    private let lock = NSLock()
    private var _state: State = .waiting
    private var _totalBytes: Int64 = 0
    private var _bytesDone: Int64 = 0
    private var _currentName: String = ""
    private var _failures = 0
    // Throughput/ETA bookkeeping: accumulate only time the op is actually
    // running (so pauses and queue-wait don't deflate the rate). `_startedAt`
    // marks the current running segment; `_accumulatedActive` banks prior ones.
    private var _startedAt: Date?
    private var _accumulatedActive: TimeInterval = 0
    var state: State {
        get { lock.lock(); defer { lock.unlock() }; return _state }
        set {
            lock.lock()
            let was = _state
            _state = newValue
            if newValue == .running {
                if _startedAt == nil { _startedAt = Date() }
            } else if was == .running, let s = _startedAt {
                _accumulatedActive += Date().timeIntervalSince(s)
                _startedAt = nil
            }
            lock.unlock()
        }
    }
    var totalBytes: Int64 {
        get { lock.lock(); defer { lock.unlock() }; return _totalBytes }
        set { lock.lock(); _totalBytes = newValue; lock.unlock() }
    }
    var bytesDone: Int64 {
        get { lock.lock(); defer { lock.unlock() }; return _bytesDone }
        set { lock.lock(); _bytesDone = newValue; lock.unlock() }
    }
    var currentName: String {
        get { lock.lock(); defer { lock.unlock() }; return _currentName }
        set { lock.lock(); _currentName = newValue; lock.unlock() }
    }
    var failures: Int {
        get { lock.lock(); defer { lock.unlock() }; return _failures }
        set { lock.lock(); _failures = newValue; lock.unlock() }
    }

    init(id: Int, move: Bool, plan: [(src: URL, dst: URL, merge: Bool)]) {
        self.id = id; self.move = move; self.plan = plan
        self.label = plan.count == 1 ? plan[0].src.lastPathComponent : "\(plan.count) items"
    }
    var fraction: Double {
        lock.lock(); defer { lock.unlock() }
        return _totalBytes > 0 ? min(1, Double(_bytesDone) / Double(_totalBytes)) : (_state == .done ? 1 : 0)
    }

    /// Seconds spent actually running. Caller must hold `lock`.
    private var activeElapsedLocked: TimeInterval {
        var t = _accumulatedActive
        if _state == .running, let s = _startedAt { t += Date().timeIntervalSince(s) }
        return t
    }

    /// Average copy throughput in bytes/sec, or 0 before there's a stable sample
    /// (first 250 ms are ignored to avoid wild early numbers).
    var bytesPerSecond: Double {
        lock.lock(); defer { lock.unlock() }
        let t = activeElapsedLocked
        return t > 0.25 ? Double(_bytesDone) / t : 0
    }

    /// Estimated seconds remaining while running, or nil if not computable yet.
    var eta: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard _state == .running, _totalBytes > _bytesDone else { return nil }
        let t = activeElapsedLocked
        guard t > 0.25 else { return nil }
        let rate = Double(_bytesDone) / t
        guard rate > 0 else { return nil }
        return Double(_totalBytes - _bytesDone) / rate
    }

    /// Compact ETA label: "8s", "3m 04s", "1h 02m".
    static func etaLabel(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
    }
}

/// A single serial queue of file transfers with global pause/resume and
/// per-op / all cancellation. Copies are streamed in chunks so the active
/// operation can pause or cancel mid-file (same-volume moves are instant
/// renames and need neither). The activity panel observes `onChange`.
final class TransferQueue {
    static let shared = TransferQueue()

    var onChange: (() -> Void)?            // always delivered on main
    private var ops: [TransferOp] = []   // read externally only via `snapshot` (locked)
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
                var ok = true
                for d in done {
                    if move {
                        // Re-create the source's parent if it vanished, then move back.
                        try? fm.createDirectory(at: d.src.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if (try? fm.moveItem(at: d.dst, to: d.src)) == nil { ok = false }
                    } else {
                        if (try? fm.trashItem(at: d.dst, resultingItemURL: nil)) == nil { ok = false }
                    }
                }
                return ok   // report REAL success so a failed undo doesn't corrupt the stack
            },
            redo: {
                var ok = true
                for d in done {
                    if move {
                        try? fm.createDirectory(at: d.dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if (try? fm.moveItem(at: d.src, to: d.dst)) == nil { ok = false }
                    } else {
                        if (try? fm.copyItem(at: d.src, to: d.dst)) == nil { ok = false }
                    }
                }
                return ok
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
            if n < 0 { try? fm.removeItem(at: dst); return false }   // read error → don't leave a stub
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
        // lastNotify is touched from both the worker and main; guard it.
        lock.lock()
        if !force && now - lastNotify < 1.0 / 30.0 { lock.unlock(); return }
        lastNotify = now
        lock.unlock()
        DispatchQueue.main.async { self.onChange?() }
    }
}
