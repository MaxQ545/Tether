import Foundation
import os

@MainActor
final class SyncWorker {
    private let id: UUID
    private let store: ConfigStore
    private let log: Logger
    private let queue: DispatchQueue

    private var watcher: FileWatcher?
    private var pullTimer: Timer?

    // Dirty / backoff state, per direction.
    private var codeDirty: Bool = false
    private var logDirty:  Bool = true     // first run should pull immediately
    private var codeBackoff: TimeInterval = 0
    private var logBackoff:  TimeInterval = 0
    private var codeRetry: DispatchWorkItem?
    private var logRetry:  DispatchWorkItem?
    // True while an rsync is in flight for that direction; prevents overlapping launches.
    private var codeRunning: Bool = false
    private var logRunning:  Bool = false

    // 15s, 30s, 60s, 2m, 5m, 10m, cap.
    private static let backoffLadder: [TimeInterval] = [15, 30, 60, 120, 300, 600]

    init(project: ProjectConfig, store: ConfigStore) {
        self.id = project.id
        self.store = store
        self.log = Logger(subsystem: "app.sync", category: "worker.\(project.name)")
        self.queue = DispatchQueue(label: "app.sync.worker.\(project.id.uuidString)", qos: .utility)
    }

    func start() {
        guard let project = store.project(id) else { return }

        if watcher == nil {
            let w = FileWatcher(path: project.localCodePath) { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.codeDirty = true
                    // A fresh FS event is user activity — bypass backoff.
                    self.codeBackoff = 0
                    self.cancelCodeRetry()
                    self.attemptPush()
                }
            }
            w.start()
            watcher = w
        }

        if pullTimer == nil {
            let interval = max(10, TimeInterval(project.pullIntervalSeconds))
            let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.logDirty = true
                    self.attemptPull()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            pullTimer = t
            // Kick an initial pull so new log data shows up without waiting a full interval.
            attemptPull()
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        pullTimer?.invalidate()
        pullTimer = nil
        cancelCodeRetry()
        cancelLogRetry()
    }

    /// Fired by the engine on network reachability ↑ and wake-from-sleep.
    func flushDirty(reason: String) {
        cancelCodeRetry()
        cancelLogRetry()
        codeBackoff = 0
        logBackoff = 0
        log.info("flushing (\(reason, privacy: .public)) codeDirty=\(self.codeDirty) logDirty=\(self.logDirty)")
        if codeDirty { attemptPush() }
        if logDirty  { attemptPull() }
    }

    func syncNow() {
        codeDirty = true
        logDirty = true
        codeBackoff = 0
        logBackoff = 0
        cancelCodeRetry()
        cancelLogRetry()
        attemptPush()
        attemptPull()
    }

    // MARK: - Push

    private func attemptPush() {
        guard codeDirty, !codeRunning else { return }
        guard let project = store.project(id), project.isComplete else { return }

        codeRunning = true
        store.setStatus(id, .code, .syncing)

        queue.async { [weak self] in
            let result = RsyncRunner.push(project: project)
            Task { @MainActor in
                self?.afterPush(result: result)
            }
        }
    }

    @MainActor
    private func afterPush(result: RsyncResult) {
        codeRunning = false
        if result.ok {
            log.info("push ok")
            codeDirty = false
            codeBackoff = 0
            store.setStatus(id, .code, .ok(at: Date()))
            // If more FS events arrived during the rsync and flipped codeDirty back on,
            // run another immediately.
            if codeDirty { attemptPush() }
        } else {
            let msg = errorMessage(from: result)
            log.error("push failed: \(msg, privacy: .public)")
            scheduleCodeRetry(reason: msg)
        }
    }

    private func scheduleCodeRetry(reason: String) {
        let delay = nextBackoff(current: &codeBackoff)
        let fireAt = Date().addingTimeInterval(delay)
        store.setStatus(id, .code, .retryingAt(fireAt, reason: reason))
        cancelCodeRetry()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.attemptPush() }
        }
        codeRetry = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelCodeRetry() {
        codeRetry?.cancel()
        codeRetry = nil
    }

    // MARK: - Pull

    private func attemptPull() {
        guard logDirty, !logRunning else { return }
        guard let project = store.project(id), project.isComplete else { return }

        logRunning = true
        store.setStatus(id, .log, .syncing)

        queue.async { [weak self] in
            let result = RsyncRunner.pull(project: project)
            Task { @MainActor in
                self?.afterPull(result: result)
            }
        }
    }

    @MainActor
    private func afterPull(result: RsyncResult) {
        logRunning = false
        if result.ok {
            log.info("pull ok")
            logDirty = false
            logBackoff = 0
            store.setStatus(id, .log, .ok(at: Date()))
        } else {
            let msg = errorMessage(from: result)
            log.error("pull failed: \(msg, privacy: .public)")
            scheduleLogRetry(reason: msg)
        }
    }

    private func scheduleLogRetry(reason: String) {
        let delay = nextBackoff(current: &logBackoff)
        let fireAt = Date().addingTimeInterval(delay)
        store.setStatus(id, .log, .retryingAt(fireAt, reason: reason))
        cancelLogRetry()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.attemptPull() }
        }
        logRetry = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelLogRetry() {
        logRetry?.cancel()
        logRetry = nil
    }

    // MARK: - Helpers

    private func nextBackoff(current: inout TimeInterval) -> TimeInterval {
        let ladder = Self.backoffLadder
        if current <= 0 {
            current = ladder[0]
        } else if let idx = ladder.firstIndex(of: current), idx + 1 < ladder.count {
            current = ladder[idx + 1]
        } else {
            current = ladder.last ?? 600
        }
        return current
    }

    private func errorMessage(from result: RsyncResult) -> String {
        if result.timedOut { return "timed out" }
        let raw = result.stderr.isEmpty ? "rsync exit \(result.exitCode)" : result.stderr
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
        return firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
