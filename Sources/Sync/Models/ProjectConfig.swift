import Foundation

struct ProjectConfig: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var isEnabled: Bool

    /// Absolute path on this machine — the project's root directory.
    var localRootPath: String
    /// Remote project root, e.g. "user@host:/srv/myapp".
    var remoteRootPath: String

    /// Sub-paths relative to the roots above.
    var codeSubpath: String
    var logSubpath: String

    var pullIntervalSeconds: Int

    var sshIdentityFile: String?
    var extraRsyncArgs: [String]

    init(
        id: UUID = UUID(),
        name: String = "",
        isEnabled: Bool = false,
        localRootPath: String = "",
        remoteRootPath: String = "",
        codeSubpath: String = "code",
        logSubpath: String = "logs",
        pullIntervalSeconds: Int = 300,
        sshIdentityFile: String? = nil,
        extraRsyncArgs: [String] = []
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.localRootPath = localRootPath
        self.remoteRootPath = remoteRootPath
        self.codeSubpath = codeSubpath
        self.logSubpath = logSubpath
        self.pullIntervalSeconds = pullIntervalSeconds
        self.sshIdentityFile = sshIdentityFile
        self.extraRsyncArgs = extraRsyncArgs
    }

    var isComplete: Bool {
        !name.isEmpty
            && !localRootPath.isEmpty
            && !remoteRootPath.isEmpty
            && !codeSubpath.isEmpty
            && !logSubpath.isEmpty
            && pullIntervalSeconds > 0
    }

    /// Concrete resolved paths — roots + subpaths joined.
    var localCodePath: String  { ProjectConfig.join(localRootPath,  codeSubpath) }
    var localLogPath:  String  { ProjectConfig.join(localRootPath,  logSubpath)  }
    var remoteCodePath: String { ProjectConfig.joinRemote(remoteRootPath, codeSubpath) }
    var remoteLogPath:  String { ProjectConfig.joinRemote(remoteRootPath, logSubpath)  }

    private static func join(_ root: String, _ sub: String) -> String {
        let r = root.hasSuffix("/") ? String(root.dropLast()) : root
        let s = sub.hasPrefix("/") ? String(sub.dropFirst()) : sub
        return s.isEmpty ? r : "\(r)/\(s)"
    }

    /// Remote paths look like "user@host:/abs/path". Join the subpath onto the path part.
    private static func joinRemote(_ root: String, _ sub: String) -> String {
        let s = sub.hasPrefix("/") ? String(sub.dropFirst()) : sub
        guard let colon = root.firstIndex(of: ":") else {
            return join(root, s)
        }
        let host = root[..<colon]
        var path = String(root[root.index(after: colon)...])
        if path.hasSuffix("/") { path.removeLast() }
        return s.isEmpty ? "\(host):\(path)" : "\(host):\(path)/\(s)"
    }
}

struct AppConfig: Codable {
    var projects: [ProjectConfig] = []
}

enum SyncStatus: Equatable {
    case idle
    case syncing
    case ok(at: Date)
    case failed(at: Date, message: String)
    /// Last attempt failed; next attempt scheduled at `at`.
    case retryingAt(Date, reason: String)
}

enum SyncDirection: String, Hashable {
    case code   // local → remote push
    case log    // remote → local pull
}

struct ProjectStatus: Equatable {
    var code: SyncStatus = .idle
    var log: SyncStatus = .idle
}
