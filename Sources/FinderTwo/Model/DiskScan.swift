import Foundation

/// Recursive disk-usage scanner. Walks a directory tree in the background and
/// reports progress + a hierarchical size summary. Cancellable.
final class DiskScan {

    /// One folder/file in the scanned tree with rolled-up totals.
    final class Node {
        let url: URL
        let name: String
        let isDirectory: Bool
        var size: Int64 = 0
        var fileCount: Int = 0
        weak var parent: Node?
        var children: [Node] = []
        init(url: URL, name: String, isDirectory: Bool) {
            self.url = url; self.name = name; self.isDirectory = isDirectory
        }
    }

    let root: Node
    private(set) var totalFiles: Int = 0
    private(set) var totalSize: Int64 = 0
    private var cancelled = false
    private let queue = DispatchQueue(label: "FinderTwo.DiskScan", qos: .userInitiated)

    /// Identifies a physical file by (device, inode) so a hard-linked file —
    /// which appears under several paths — is only counted toward the total once.
    private struct INodeKey: Hashable { let dev: Int32; let ino: UInt64 }
    private var countedInodes = Set<INodeKey>()

    init(root: URL) {
        self.root = Node(url: root, name: root.lastPathComponent.isEmpty ? "/" : root.lastPathComponent,
                         isDirectory: true)
    }

    /// Run the scan; `onUpdate` fires occasionally with progress, `onFinish`
    /// fires once with the final root node.
    func run(onUpdate: @escaping (Int, Int64) -> Void,
             onFinish: @escaping (Node) -> Void) {
        let strong = self        // keep alive for the duration of the async work
        queue.async {
            strong.walk(strong.root, lastReportAt: 0, onUpdate: onUpdate)
            DispatchQueue.main.async {
                onFinish(strong.root)
            }
        }
    }

    /// Synchronous walk — used by tests and headless scans. The async `run`
    /// hop is fine for UI but ill-suited to deterministic test pumping.
    func runSync() -> Node {
        walk(root, lastReportAt: 0, onUpdate: { _, _ in })
        return root
    }

    func cancel() { cancelled = true }

    // MARK: - Internals

    private func walk(_ node: Node, lastReportAt: TimeInterval, onUpdate: @escaping (Int, Int64) -> Void) {
        if cancelled { return }
        let entries = FastDirScan.list(node.url)
        var lastReport = lastReportAt
        for e in entries {
            if cancelled { return }
            // A symlink is NOT a real directory for usage purposes: we count the
            // link's own (tiny) footprint and never recurse through it. This is
            // what `du` does, and it stops framework `Current → A` symlinks (and
            // any symlink cycles) from double-counting or looping forever.
            let isRealDir = e.isDirectory && !e.isSymlink
            let childNode = Node(url: e.url, name: e.name, isDirectory: isRealDir)
            childNode.parent = node
            if isRealDir {
                walk(childNode, lastReportAt: lastReport, onUpdate: onUpdate)
                node.children.append(childNode)
                node.size += childNode.size
                node.fileCount += childNode.fileCount
            } else {
                // Use the ALLOCATED size (blocks), not the apparent size, so
                // sparse files (disk images, VMs) count their real footprint.
                var s = max(e.physicalSize, 0)
                // De-duplicate hard links: a file with multiple links is only
                // charged to the total the first time we encounter it.
                if e.linkCount > 1 {
                    let key = INodeKey(dev: e.device, ino: e.inode)
                    if countedInodes.contains(key) { s = 0 } else { countedInodes.insert(key) }
                }
                childNode.size = s
                childNode.fileCount = 1
                node.children.append(childNode)
                node.size += s
                node.fileCount += 1
                totalSize += s
                totalFiles += 1
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastReport > 0.1 {
                lastReport = now
                let snapshotSize = totalSize
                let snapshotCount = totalFiles
                DispatchQueue.main.async {
                    onUpdate(snapshotCount, snapshotSize)
                }
            }
        }
        // After accumulating children, sort biggest-first so the treemap
        // layout doesn't have to do it again.
        node.children.sort { $0.size > $1.size }
    }
}
