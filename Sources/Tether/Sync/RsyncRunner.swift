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

    static func push(project: ProjectConfig) -> RsyncResult {
        let localRoot = project.localCodePath.hasSuffix("/") ? project.localCodePath : project.localCodePath + "/"
        let remote = project.remoteCodePath
        let excludeFile = IgnoreRules.excludeFromFile(forProjectAt: project.localCodePath)

        var args = commonArgs() + ["--delete", "-e", sshCommand(project)]
        if let ef = excludeFile {
            args.append("--exclude-from=\(ef.path)")
        }
        args.append(contentsOf: project.extraRsyncArgs)
        args.append(localRoot)
        args.append(remote)
        return run(args: args)
    }

    static func pull(project: ProjectConfig) -> RsyncResult {
        let remote = project.remoteLogPath.hasSuffix("/") ? project.remoteLogPath : project.remoteLogPath + "/"
        let local = project.localLogPath

        // No --delete on the pull direction; we don't want to clobber local logs.
        var args = commonArgs() + ["-e", sshCommand(project)]
        args.append(remote)
        args.append(local)
        return run(args: args)
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
