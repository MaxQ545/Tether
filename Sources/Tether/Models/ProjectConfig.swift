import Foundation

struct ProjectConfig: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var isEnabled: Bool

    /// Absolute path on this machine — the project's root directory.
    var localRootPath: String
    /// Remote project root, e.g. "user@host:/srv/myapp".
    var remoteRootPath: String

    /// Sub-paths relative to the roots above. Symmetric: each entry is used for
    /// both the local and the remote side.
    var codeSubpaths: [String]
    var logSubpaths:  [String]

    /// Per-direction toggles. When false the corresponding watcher/timer is not
    /// started and any call to push/pull is a no-op.
    var pushCodeEnabled: Bool
    var pullLogEnabled:  Bool

    /// Extra rsync `--exclude=<name>` entries, on top of the project's .gitignore.
    /// Entries are matched by rsync as file-or-directory names at any depth.
    var codeExcludes: [String]
    var logExcludes:  [String]

    var pullIntervalSeconds: Int

    var sshIdentityFile: String?
    var extraRsyncArgs: [String]

    init(
        id: UUID = UUID(),
        name: String = "",
        isEnabled: Bool = false,
        localRootPath: String = "",
        remoteRootPath: String = "",
        codeSubpaths: [String] = ["code"],
        logSubpaths:  [String] = ["logs"],
        pushCodeEnabled: Bool = true,
        pullLogEnabled:  Bool = true,
        codeExcludes: [String] = [],
        logExcludes:  [String] = [],
        pullIntervalSeconds: Int = 300,
        sshIdentityFile: String? = nil,
        extraRsyncArgs: [String] = []
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.localRootPath = localRootPath
        self.remoteRootPath = remoteRootPath
        self.codeSubpaths = codeSubpaths
        self.logSubpaths = logSubpaths
        self.pushCodeEnabled = pushCodeEnabled
        self.pullLogEnabled = pullLogEnabled
        self.codeExcludes = codeExcludes
        self.logExcludes = logExcludes
        self.pullIntervalSeconds = pullIntervalSeconds
        self.sshIdentityFile = sshIdentityFile
        self.extraRsyncArgs = extraRsyncArgs
    }

    var isComplete: Bool {
        guard !name.isEmpty,
              !localRootPath.isEmpty,
              !remoteRootPath.isEmpty,
              pullIntervalSeconds > 0 else { return false }
        let codeSubs = codeSubpaths.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let logSubs  = logSubpaths.filter  { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if pushCodeEnabled && codeSubs.isEmpty { return false }
        if pullLogEnabled  && logSubs.isEmpty  { return false }
        return pushCodeEnabled || pullLogEnabled
    }

    /// Concrete resolved paths — roots + each subpath joined.
    var localCodePaths:  [String] { codeSubpaths.map { Self.join(localRootPath, $0) } }
    var remoteCodePaths: [String] { codeSubpaths.map { Self.joinRemote(remoteRootPath, $0) } }
    var localLogPaths:   [String] { logSubpaths.map  { Self.join(localRootPath, $0) } }
    var remoteLogPaths:  [String] { logSubpaths.map  { Self.joinRemote(remoteRootPath, $0) } }

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

    // MARK: - Codable (with backward compat for singular keys)

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled
        case localRootPath, remoteRootPath
        case codeSubpaths, logSubpaths
        case codeSubpath, logSubpath   // legacy singular keys
        case pushCodeEnabled, pullLogEnabled
        case codeExcludes, logExcludes
        case pullIntervalSeconds
        case sshIdentityFile, extraRsyncArgs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        self.localRootPath = try c.decodeIfPresent(String.self, forKey: .localRootPath) ?? ""
        self.remoteRootPath = try c.decodeIfPresent(String.self, forKey: .remoteRootPath) ?? ""

        if let arr = try c.decodeIfPresent([String].self, forKey: .codeSubpaths) {
            self.codeSubpaths = arr
        } else if let single = try c.decodeIfPresent(String.self, forKey: .codeSubpath) {
            self.codeSubpaths = [single]
        } else {
            self.codeSubpaths = ["code"]
        }

        if let arr = try c.decodeIfPresent([String].self, forKey: .logSubpaths) {
            self.logSubpaths = arr
        } else if let single = try c.decodeIfPresent(String.self, forKey: .logSubpath) {
            self.logSubpaths = [single]
        } else {
            self.logSubpaths = ["logs"]
        }

        self.pushCodeEnabled = try c.decodeIfPresent(Bool.self, forKey: .pushCodeEnabled) ?? true
        self.pullLogEnabled  = try c.decodeIfPresent(Bool.self, forKey: .pullLogEnabled)  ?? true
        self.codeExcludes = try c.decodeIfPresent([String].self, forKey: .codeExcludes) ?? []
        self.logExcludes  = try c.decodeIfPresent([String].self, forKey: .logExcludes)  ?? []

        self.pullIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .pullIntervalSeconds) ?? 300
        self.sshIdentityFile = try c.decodeIfPresent(String.self, forKey: .sshIdentityFile)
        self.extraRsyncArgs = try c.decodeIfPresent([String].self, forKey: .extraRsyncArgs) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(localRootPath, forKey: .localRootPath)
        try c.encode(remoteRootPath, forKey: .remoteRootPath)
        try c.encode(codeSubpaths, forKey: .codeSubpaths)
        try c.encode(logSubpaths, forKey: .logSubpaths)
        try c.encode(pushCodeEnabled, forKey: .pushCodeEnabled)
        try c.encode(pullLogEnabled, forKey: .pullLogEnabled)
        try c.encode(codeExcludes, forKey: .codeExcludes)
        try c.encode(logExcludes, forKey: .logExcludes)
        try c.encode(pullIntervalSeconds, forKey: .pullIntervalSeconds)
        try c.encodeIfPresent(sshIdentityFile, forKey: .sshIdentityFile)
        try c.encode(extraRsyncArgs, forKey: .extraRsyncArgs)
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
