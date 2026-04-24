import Foundation

enum IgnoreRules {
    /// If the project's local code folder has a .gitignore, copy it into a tempfile
    /// suitable for rsync's --exclude-from. Returns nil if no .gitignore is present.
    static func excludeFromFile(forProjectAt root: String) -> URL? {
        let fm = FileManager.default
        let gitignore = (root as NSString).appendingPathComponent(".gitignore")
        guard fm.fileExists(atPath: gitignore) else { return nil }

        guard let raw = try? String(contentsOfFile: gitignore, encoding: .utf8) else {
            return nil
        }

        // Keep the file largely verbatim — rsync understands gitignore-style globs
        // well enough for common cases. Strip blank lines and comments.
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        let tmpDir = fm.temporaryDirectory
            .appendingPathComponent("sync-excludes", isDirectory: true)
        try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let outURL = tmpDir.appendingPathComponent("\(UUID().uuidString).txt")
        let joined = lines.joined(separator: "\n") + "\n"
        try? joined.write(to: outURL, atomically: true, encoding: .utf8)
        return outURL
    }
}
