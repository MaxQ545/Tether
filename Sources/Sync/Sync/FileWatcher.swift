import Foundation
import CoreServices

final class FileWatcher {
    private let path: String
    private let debounce: TimeInterval
    private let queue: DispatchQueue
    private let onChange: () -> Void

    private var stream: FSEventStreamRef?
    private var pendingWork: DispatchWorkItem?

    init(
        path: String,
        debounceSeconds: TimeInterval = 2.0,
        queue: DispatchQueue = .main,
        onChange: @escaping () -> Void
    ) {
        self.path = path
        self.debounce = debounceSeconds
        self.queue = queue
        self.onChange = onChange
    }

    deinit { stopUnsafe() }

    func start() {
        guard stream == nil else { return }

        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, clientInfo, _, _, _, _ in
            guard let clientInfo else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
            watcher.handleEvent()
        }

        let pathsToWatch = [path] as CFArray
        let flags: FSEventStreamCreateFlags = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagWatchRoot
        )

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &ctx,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags
        ) else {
            return
        }
        self.stream = s
        FSEventStreamSetDispatchQueue(s, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(s)
    }

    func stop() { stopUnsafe() }

    private func stopUnsafe() {
        pendingWork?.cancel()
        pendingWork = nil
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
    }

    private func handleEvent() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.onChange()
            }
            self.pendingWork = work
            self.queue.asyncAfter(deadline: .now() + self.debounce, execute: work)
        }
    }
}
