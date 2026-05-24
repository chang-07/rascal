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
            let childNode = Node(url: e.url, name: e.name, isDirectory: e.isDirectory)
            childNode.parent = node
            if e.isDirectory {
                walk(childNode, lastReportAt: lastReport, onUpdate: onUpdate)
                node.children.append(childNode)
                node.size += childNode.size
                node.fileCount += childNode.fileCount
            } else {
                let s = max(e.size, 0)
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

    // MARK: - Treemap layout

    /// "Squarified" treemap layout (Bruls/Huijing/van Wijk) that fits children
    /// of `node` into `bounds` and returns each child's rect.
    static func squarify(_ node: Node, in bounds: CGRect) -> [(Node, CGRect)] {
        let nonEmpty = node.children.filter { $0.size > 0 }
        guard node.size > 0, !nonEmpty.isEmpty else { return [] }
        // Scale child sizes to area
        let area = Double(bounds.width * bounds.height)
        let scaled = nonEmpty.map { Double($0.size) / Double(node.size) * area }
        var rects: [(Node, CGRect)] = []
        layout(children: Array(zip(nonEmpty, scaled)), inside: bounds, into: &rects)
        return rects
    }

    private static func layout(children: [(Node, Double)], inside rect: CGRect,
                               into out: inout [(Node, CGRect)]) {
        if children.isEmpty { return }
        if children.count == 1 {
            out.append((children[0].0, rect))
            return
        }
        // Split horizontally vs vertically based on shorter side
        let horizontal = rect.width < rect.height
        let total = children.reduce(0.0) { $0 + $1.1 }
        // Approximate: just split half/half by count weighted by size
        // (full squarified algorithm is more nuanced; this gives "good enough"
        // proportions for visual scanning).
        var firstHalf: [(Node, Double)] = []
        var secondHalf: [(Node, Double)] = []
        var acc = 0.0
        for c in children {
            if acc + c.1 / 2 < total / 2 {
                firstHalf.append(c)
                acc += c.1
            } else {
                secondHalf.append(c)
            }
        }
        if firstHalf.isEmpty { firstHalf.append(secondHalf.removeFirst()) }
        if secondHalf.isEmpty { return layout(children: firstHalf, inside: rect, into: &out) }
        let firstFraction = CGFloat(firstHalf.reduce(0.0) { $0 + $1.1 } / total)
        if horizontal {
            let h = rect.height * firstFraction
            let r1 = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h)
            let r2 = CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h)
            layout(children: firstHalf, inside: r1, into: &out)
            layout(children: secondHalf, inside: r2, into: &out)
        } else {
            let w = rect.width * firstFraction
            let r1 = CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height)
            let r2 = CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height)
            layout(children: firstHalf, inside: r1, into: &out)
            layout(children: secondHalf, inside: r2, into: &out)
        }
    }
}
