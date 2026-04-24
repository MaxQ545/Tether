import Foundation
import Network
import AppKit
import os

@MainActor
final class SyncEngine {
    static let shared = SyncEngine()

    private static let log = Logger(subsystem: "app.sync", category: "Engine")

    private var workers: [UUID: SyncWorker] = [:]
    private var observers: [NSObjectProtocol] = []

    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "app.sync.pathMonitor", qos: .utility)
    private var lastPathSatisfied: Bool = true

    private init() {}

    func bootstrap() {
        let store = ConfigStore.shared
        let nc = NotificationCenter.default

        observers.append(nc.addObserver(
            forName: .configProjectAdded, object: nil, queue: .main
        ) { [weak self] note in
            guard let id = note.object as? UUID else { return }
            Task { @MainActor in self?.reconcile(id: id, store: store) }
        })

        observers.append(nc.addObserver(
            forName: .configProjectEnabled, object: nil, queue: .main
        ) { [weak self] note in
            guard let id = note.object as? UUID else { return }
            Task { @MainActor in self?.reconcile(id: id, store: store) }
        })

        observers.append(nc.addObserver(
            forName: .configProjectDisabled, object: nil, queue: .main
        ) { [weak self] note in
            guard let id = note.object as? UUID else { return }
            Task { @MainActor in self?.stopWorker(id: id) }
        })

        observers.append(nc.addObserver(
            forName: .configProjectRemoved, object: nil, queue: .main
        ) { [weak self] note in
            guard let id = note.object as? UUID else { return }
            Task { @MainActor in self?.stopWorker(id: id) }
        })

        observers.append(nc.addObserver(
            forName: .configProjectUpdated, object: nil, queue: .main
        ) { [weak self] note in
            guard let id = note.object as? UUID else { return }
            Task { @MainActor in
                self?.stopWorker(id: id)
                self?.reconcile(id: id, store: store)
            }
        })

        // Wake / sleep hooks — use the NSWorkspace-specific notification center.
        let wsnc = NSWorkspace.shared.notificationCenter
        observers.append(wsnc.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.flushAll(reason: "wake") }
        })
        observers.append(wsnc.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWillSleep() }
        })

        // Reachability — track transitions, don't spam on every path update.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = (path.status == .satisfied)
            Task { @MainActor in
                self?.handlePath(satisfied: satisfied)
            }
        }
        pathMonitor.start(queue: pathQueue)
        lastPathSatisfied = (pathMonitor.currentPath.status == .satisfied)

        for project in store.projects where project.isEnabled {
            reconcile(id: project.id, store: store)
        }
    }

    func syncAllNow() {
        for worker in workers.values {
            worker.syncNow()
        }
    }

    // MARK: - Reachability / wake

    @MainActor
    private func handlePath(satisfied: Bool) {
        let previous = lastPathSatisfied
        lastPathSatisfied = satisfied
        guard !previous, satisfied else { return }  // only on transition to satisfied
        Self.log.info("network reachable — flushing")
        flushAll(reason: "reachable")
    }

    @MainActor
    private func handleWillSleep() {
        Self.log.info("will sleep — nothing to do (pending retries resume on wake)")
        // Pending DispatchWorkItems continue ticking down even across sleep; on wake the
        // flushAll triggered by didWakeNotification supersedes them by resetting backoff.
    }

    @MainActor
    private func flushAll(reason: String) {
        for worker in workers.values {
            worker.flushDirty(reason: reason)
        }
    }

    // MARK: - Worker lifecycle

    private func reconcile(id: UUID, store: ConfigStore) {
        guard let project = store.project(id) else { return }
        guard project.isEnabled, project.isComplete else {
            stopWorker(id: id)
            return
        }
        if workers[id] == nil {
            let w = SyncWorker(project: project, store: store)
            workers[id] = w
            w.start()
            Self.log.info("worker started for \(project.name, privacy: .public)")
        }
    }

    private func stopWorker(id: UUID) {
        if let w = workers.removeValue(forKey: id) {
            w.stop()
            Self.log.info("worker stopped for \(id.uuidString, privacy: .public)")
        }
    }
}
