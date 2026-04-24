import Foundation
import Observation
import os

@MainActor
@Observable
final class ConfigStore {
    static let shared = ConfigStore()

    private static let log = Logger(subsystem: "app.tether", category: "ConfigStore")

    private(set) var projects: [ProjectConfig] = []
    private(set) var status: [UUID: ProjectStatus] = [:]

    private let fileURL: URL

    private init() {
        let fm = FileManager.default
        let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = (appSupport ?? URL(fileURLWithPath: NSHomeDirectory()))
            .appendingPathComponent("Tether", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("config.json")
        load()
    }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            projects = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let cfg = try JSONDecoder().decode(AppConfig.self, from: data)
            let cleaned = cfg.projects.filter { p in
                // Drop entries with no identifying fields at all — these are
                // leftovers from an earlier bug that persisted blank drafts.
                !(p.name.isEmpty && p.localRootPath.isEmpty && p.remoteRootPath.isEmpty)
            }
            projects = cleaned
            if cleaned.count != cfg.projects.count {
                persist()
            }
        } catch {
            Self.log.error("Failed to decode config: \(String(describing: error)). Quarantining.")
            let ts = Int(Date().timeIntervalSince1970)
            let quarantine = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(ts).json")
            try? FileManager.default.moveItem(at: fileURL, to: quarantine)
            projects = []
        }
    }

    func persist() {
        let cfg = AppConfig(projects: projects)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(cfg)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.log.error("Failed to persist config: \(String(describing: error))")
        }
    }

    func add(_ project: ProjectConfig) {
        projects.append(project)
        persist()
        NotificationCenter.default.post(name: .configProjectAdded, object: project.id)
    }

    func update(_ project: ProjectConfig) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        let previous = projects[idx]
        projects[idx] = project
        persist()
        if previous.isEnabled != project.isEnabled {
            let name: Notification.Name = project.isEnabled ? .configProjectEnabled : .configProjectDisabled
            NotificationCenter.default.post(name: name, object: project.id)
        } else {
            NotificationCenter.default.post(name: .configProjectUpdated, object: project.id)
        }
    }

    func remove(_ id: UUID) {
        projects.removeAll { $0.id == id }
        status.removeValue(forKey: id)
        persist()
        NotificationCenter.default.post(name: .configProjectRemoved, object: id)
    }

    func setEnabled(_ id: UUID, _ value: Bool) {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        guard projects[idx].isEnabled != value else { return }
        projects[idx].isEnabled = value
        persist()
        let name: Notification.Name = value ? .configProjectEnabled : .configProjectDisabled
        NotificationCenter.default.post(name: name, object: id)
    }

    func project(_ id: UUID) -> ProjectConfig? {
        projects.first(where: { $0.id == id })
    }

    func setStatus(_ id: UUID, _ direction: SyncDirection, _ value: SyncStatus) {
        var current = status[id] ?? ProjectStatus()
        switch direction {
        case .code: current.code = value
        case .log:  current.log  = value
        }
        status[id] = current
    }
}

extension Notification.Name {
    static let configProjectAdded    = Notification.Name("app.tether.configProjectAdded")
    static let configProjectRemoved  = Notification.Name("app.tether.configProjectRemoved")
    static let configProjectUpdated  = Notification.Name("app.tether.configProjectUpdated")
    static let configProjectEnabled  = Notification.Name("app.tether.configProjectEnabled")
    static let configProjectDisabled = Notification.Name("app.tether.configProjectDisabled")
}
