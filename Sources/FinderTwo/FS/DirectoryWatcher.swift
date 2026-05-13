import Foundation
import CoreServices

/// Thin FSEvents wrapper that calls a closure when the watched directory changes.
final class DirectoryWatcher {
    private let url: URL
    private let callback: () -> Void
    private var stream: FSEventStreamRef?

    init(url: URL, callback: @escaping () -> Void) {
        self.url = url
        self.callback = callback
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil, release: nil, copyDescription: nil
        )
        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let me = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            me.callback()
        }
        let paths = [url.path] as CFArray
        let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            cb,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25, // latency
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        )
        guard let s else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.global(qos: .userInitiated))
        FSEventStreamStart(s)
        self.stream = s
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit {
        stop()
    }
}
