import Foundation
import os

struct RsyncResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    /// True when our own hard-kill deadline fired (hung connection, blackholed network).
    let timedOut: Bool
    var ok: Bool { exitCode == 0 && !timedOut }
}

/// Result of a multi-subpath push: the overall rsync result plus which input
/// subpath indexes actually completed successfully before the run aborted.
struct MultiSyncResult {
    let result: RsyncResult
    let succeededIndexes: Set<Int>
}

enum RsyncRunner {
    private static let log = Logger(subsystem: "app.tether", category: "Rsync")

    /// Hard upper bound on a single rsync invocation. Guards against ssh hanging
    /// during auth / DNS / blackholed TCP that the rsync/ssh built-in timeouts miss.
    private static let hardDeadline: TimeInterval = 120

    /// Run rsync with the given arguments. Blocking — call from a background queue.
    static func run(args: [String]) -> RsyncResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        p.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        log.debug("rsync \(args.joined(separator: " "), privacy: .public)")

        do {
            try p.run()
        } catch {
            return RsyncResult(
                exitCode: -1,
                stdout: "",
                stderr: "failed to launch rsync: \(error)",
                timedOut: false
            )
        }

        // Schedule a hard kill. The `DispatchWorkItem` captures the process by value.
        // If the process has already exited by the time the item fires, `terminate()`
        // is a no-op and `p.isRunning` is false — safe.
        let killFlag = KillFlag()
        let killItem = DispatchWorkItem {
            if p.isRunning {
                killFlag.fired = true
                p.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + hardDeadline, execute: killItem)

        p.waitUntilExit()
        killItem.cancel()

        let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
        var stderr = String(data: errData, encoding: .utf8) ?? ""
        if killFlag.fired && !stderr.contains("timed out") {
            stderr = "timed out after \(Int(hardDeadline))s\n" + stderr
        }
        return RsyncResult(
            exitCode: p.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: stderr,
            timedOut: killFlag.fired
        )
    }

    static func push(project: ProjectConfig, subpathIndexes: Set<Int>) -> MultiSyncResult {
        let indexed = zip(project.localCodePaths, project.remoteCodePaths)
            .enumerated()
            .compactMap { entry -> (Int, SubpathPair)? in
                let (idx, paths) = entry
                guard subpathIndexes.contains(idx) else { return nil }
                let (local, remote) = paths
                return (idx, SubpathPair(
                    label: labelFor(localPath: local),
                    source: ensureTrailingSlash(local),
                    dest: remote,
                    gitignoreRoot: local
                ))
            }
        return runIndexedPairs(
            indexed,
            project: project,
            withDelete: true,
            userExcludes: project.normalizedCodeExcludes
        )
    }

    static func pull(project: ProjectConfig) -> RsyncResult {
        let indexed = zip(project.remoteLogPaths, project.localLogPaths)
            .enumerated()
            .map { entry -> (Int, SubpathPair) in
                let (idx, paths) = entry
                let (remote, local) = paths
                return (idx, SubpathPair(
                    label: labelFor(remotePath: remote),
                    source: ensureTrailingSlash(remote),
                    dest: local,
                    gitignoreRoot: nil
                ))
            }
        return runIndexedPairs(
            indexed,
            project: project,
            withDelete: false,
            userExcludes: project.normalizedLogExcludes
        ).result
    }

    // MARK: - Multi-subpath runner

    private struct SubpathPair {
        /// Short name used in error messages (e.g. "frontend").
        let label: String
        /// rsync source argument (trailing-slash if a local directory).
        let source: String
        /// rsync destination argument.
        let dest: String
        /// If set, read this local directory's .gitignore as an --exclude-from.
        /// nil for the pull direction (remote filesystem — no .gitignore to read).
        let gitignoreRoot: String?
    }

    private static func runIndexedPairs(
        _ pairs: [(Int, SubpathPair)],
        project: ProjectConfig,
        withDelete: Bool,
        userExcludes: [String]
    ) -> MultiSyncResult {
        guard !pairs.isEmpty else {
            return MultiSyncResult(
                result: RsyncResult(exitCode: 0, stdout: "", stderr: "", timedOut: false),
                succeededIndexes: []
            )
        }

        var aggregatedOut = ""
        var succeeded: Set<Int> = []
        let ssh = sshCommand(project)

        for (index, pair) in pairs {
            var args = commonArgs()
            if withDelete { args.append("--delete") }
            args.append(contentsOf: ["-e", ssh])

            if let root = pair.gitignoreRoot,
               let ef = IgnoreRules.excludeFromFile(forProjectAt: root) {
                args.append("--exclude-from=\(ef.path)")
            }
            for name in userExcludes {
                args.append("--exclude=\(name)")
            }
            args.append(contentsOf: project.extraRsyncArgs)
            args.append(pair.source)
            args.append(pair.dest)

            let result = run(args: args)
            aggregatedOut += result.stdout
            if !result.ok {
                // Prefix stderr with the subpath label so MenuBar errors stay identifiable.
                let prefixed = "[\(pair.label)] " + result.stderr
                return MultiSyncResult(
                    result: RsyncResult(
                        exitCode: result.exitCode == 0 ? -1 : result.exitCode,
                        stdout: aggregatedOut,
                        stderr: prefixed,
                        timedOut: result.timedOut
                    ),
                    succeededIndexes: succeeded
                )
            }
            succeeded.insert(index)
        }

        return MultiSyncResult(
            result: RsyncResult(exitCode: 0, stdout: aggregatedOut, stderr: "", timedOut: false),
            succeededIndexes: succeeded
        )
    }

    private static func ensureTrailingSlash(_ s: String) -> String {
        s.hasSuffix("/") ? s : s + "/"
    }

    /// Last path component of a local path. Used as the error-message label.
    private static func labelFor(localPath: String) -> String {
        (localPath as NSString).lastPathComponent
    }

    /// Last path component of a remote path ("user@host:/a/b" → "b").
    private static func labelFor(remotePath: String) -> String {
        let pathPart: String
        if let colon = remotePath.firstIndex(of: ":") {
            pathPart = String(remotePath[remotePath.index(after: colon)...])
        } else {
            pathPart = remotePath
        }
        return (pathPart as NSString).lastPathComponent
    }

    private static func commonArgs() -> [String] {
        // --timeout     idle timeout; aborts if no data flows for N seconds
        // --contimeout  daemon-mode connect timeout; harmless over ssh, useful when it applies
        [
            "-az",
            "--timeout=30",
            "--contimeout=15",
        ]
    }

    private static func sshCommand(_ project: ProjectConfig) -> String {
        // ConnectTimeout   ssh-level TCP-open timeout
        // ServerAliveInterval/CountMax  detects dead peers within ~45s on silent drops
        // BatchMode=yes    never prompt for a password (fail fast if no key)
        var parts = [
            "ssh",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
        ]
        if let id = project.sshIdentityFile, !id.isEmpty {
            parts.append(contentsOf: ["-i", shellQuote(id)])
        }
        return parts.joined(separator: " ")
    }

    private static func shellQuote(_ s: String) -> String {
        if s.rangeOfCharacter(from: CharacterSet(charactersIn: " \t\"'\\")) == nil {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Reference-typed bool so the kill DispatchWorkItem can flip a flag
/// that the caller sees after waitUntilExit returns.
private final class KillFlag {
    var fired: Bool = false
}
