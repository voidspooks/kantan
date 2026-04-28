import Foundation
import os.log

private let gitLog = OSLog(subsystem: "com.kantan.editor", category: "GitStatus")

// MARK: - Git status (per-file untracked/modified flags)

/// Snapshots `git status --porcelain` for a project root and exposes per-URL
/// flags for the sidebar to color rows. Synchronous on purpose — typical repos
/// finish in tens of milliseconds and we want results before the next render.
/// Untracked directories cascade their state down to descendants because git
/// reports an untracked directory as a single entry rather than enumerating
/// every file inside it.
final class GitStatus {
    enum Kind {
        case untracked
        case modified
    }

    private let lock = NSLock()
    private var statuses: [String: Kind] = [:]
    private var rootURL: URL?

    /// Current branch name for the project root, or nil if the root isn't a git
    /// repo (or HEAD is detached). Refreshed alongside per-file statuses so the
    /// sidebar footer stays consistent with row colors.
    private(set) var currentBranch: String?

    func setRoot(_ url: URL?) {
        os_log(.info, log: gitLog, "setRoot called: %{public}@", url?.path ?? "<nil>")
        lock.lock()
        rootURL = url
        lock.unlock()
        refresh()
    }

    func refresh() {
        let start = CFAbsoluteTimeGetCurrent()
        os_log(.info, log: gitLog, "refresh() called on thread %{public}@",
               Thread.isMainThread ? "MAIN" : "background")
        lock.lock()
        statuses = [:]
        currentBranch = nil
        let root = rootURL
        lock.unlock()
        guard let root = root else {
            os_log(.info, log: gitLog, "refresh() bailing — rootURL is nil")
            return
        }

        os_log(.info, log: gitLog, "refresh() running git status for root: %{public}@", root.path)
        guard let statusOutput = runGit(["status", "--porcelain"], in: root) else {
            os_log(.error, log: gitLog, "refresh() git status returned nil (not a repo or error)")
            return
        }
        let statusElapsed = CFAbsoluteTimeGetCurrent() - start
        os_log(.info, log: gitLog, "refresh() git status took %.3f s, output length: %d",
               statusElapsed, statusOutput.count)

        if let branch = runGit(["branch", "--show-current"], in: root), !branch.isEmpty {
            lock.lock()
            currentBranch = branch
            lock.unlock()
            os_log(.info, log: gitLog, "refresh() branch: %{public}@", branch)
        }

        var newStatuses: [String: Kind] = [:]
        for line in statusOutput.components(separatedBy: "\n") where line.count >= 4 {
            let xy = String(line.prefix(2))
            var path = String(line.dropFirst(3))

            if xy.hasPrefix("R") || xy.hasPrefix("C") {
                if let arrow = path.range(of: " -> ") {
                    path = String(path[arrow.upperBound...])
                }
            }
            if path.hasPrefix("\"") && path.hasSuffix("\"") && path.count >= 2 {
                path = String(path.dropFirst().dropLast())
            }
            if path.hasSuffix("/") { path = String(path.dropLast()) }

            let absolute = root.appendingPathComponent(path).path
            let kind: Kind = (xy == "??" ? .untracked : .modified)
            newStatuses[absolute] = kind
            os_log(.info, log: gitLog, "  parsed: [%{public}@] absolute=%{public}@",
                   xy, absolute)
        }

        let totalElapsed = CFAbsoluteTimeGetCurrent() - start
        os_log(.info, log: gitLog, "refresh() done — %d entries, total %.3f s",
               newStatuses.count, totalElapsed)

        lock.lock()
        statuses = newStatuses
        lock.unlock()
    }

    func status(for url: URL) -> Kind? {
        lock.lock()
        let snap = statuses
        lock.unlock()
        let directPath = url.path
        if let direct = snap[directPath] {
            return direct
        }
        // Walk up to inherit untracked status from an ancestor directory.
        var path = directPath
        while !path.isEmpty && path != "/" {
            path = (path as NSString).deletingLastPathComponent
            if snap[path] == .untracked {
                return .untracked
            }
        }
        // For directories, check if any descendant has a status. Modified takes
        // priority over untracked so the directory reflects the "strongest" change.
        let prefix = directPath.hasSuffix("/") ? directPath : directPath + "/"
        var result: Kind?
        for (storedPath, kind) in snap {
            guard storedPath.hasPrefix(prefix) else { continue }
            if kind == .modified { return .modified }
            result = kind
        }
        return result
    }

    /// Run `git -C <root> <args...>` synchronously. Returns trimmed stdout, or
    /// nil if the process couldn't start or exited non-zero (e.g. not a repo).
    private func runGit(_ args: [String], in root: URL) -> String? {
        let process = Process()
        process.launchPath = "/usr/bin/env"
        process.arguments = ["git", "-C", root.path] + args
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard var str = String(data: data, encoding: .utf8) else { return nil }
        // Only strip trailing whitespace — leading spaces are significant in
        // porcelain output (e.g. " M" means unstaged-only modification).
        while str.last?.isWhitespace == true { str.removeLast() }
        return str
    }
}

// MARK: - Git diff (per-line change info for one file)

/// Describes a line in the working-tree version of a file that's added or
/// modified relative to HEAD. Line numbers are 1-based.
struct LineChange {
    enum Kind { case added, modified }
    let line: Int
    let kind: Kind
}

/// Computes per-line change info by running `git diff --unified=0` and parsing
/// hunk headers. Untracked files (or files outside a git repo) are reported as
/// "every line is added". Synchronous like `GitStatus` — the editor calls this
/// only on file open + save, never on keystrokes.
enum GitDiff {
    static func changes(for url: URL) -> [LineChange] {
        guard let root = repoRoot(containing: url) else { return [] }
        let relative = relativePath(of: url, from: root)

        if !isTracked(relative, in: root) {
            return allLinesAdded(in: url)
        }

        guard let output = runGit(["diff", "--unified=0", "--no-color", "--", relative], in: root),
              !output.isEmpty else {
            return []
        }
        return parseUnifiedDiff(output)
    }

    private static func repoRoot(containing url: URL) -> URL? {
        let fm = FileManager.default
        var dir = url.deletingLastPathComponent()
        while dir.path != "/" && !dir.path.isEmpty {
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private static func relativePath(of url: URL, from root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if url.path.hasPrefix(rootPath) {
            return String(url.path.dropFirst(rootPath.count))
        }
        return url.path
    }

    private static func isTracked(_ relative: String, in root: URL) -> Bool {
        return runGit(["ls-files", "--error-unmatch", "--", relative], in: root) != nil
    }

    private static func allLinesAdded(in url: URL) -> [LineChange] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        // Count newline-separated lines, treating a trailing newline as terminating
        // the previous line rather than starting a new empty one.
        if content.isEmpty { return [] }
        var n = content.components(separatedBy: "\n").count
        if content.hasSuffix("\n") { n -= 1 }
        guard n > 0 else { return [] }
        return (1...n).map { LineChange(line: $0, kind: .added) }
    }

    /// Parse hunk headers (`@@ -A,B +C,D @@`). For each hunk:
    ///   - newCount > 0, oldCount == 0  → pure addition (added)
    ///   - newCount > 0, oldCount > 0   → replacement (modified)
    ///   - newCount == 0                 → pure deletion (no current lines to mark)
    private static let hunkRegex = try! NSRegularExpression(
        pattern: #"^@@\s+-(\d+)(?:,(\d+))?\s+\+(\d+)(?:,(\d+))?\s+@@"#)

    private static func parseUnifiedDiff(_ output: String) -> [LineChange] {
        var changes: [LineChange] = []
        for raw in output.components(separatedBy: "\n") {
            let nsLine = raw as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)
            guard let m = hunkRegex.firstMatch(in: raw, range: fullRange) else { continue }

            func intAt(_ groupIndex: Int, default fallback: Int) -> Int {
                let r = m.range(at: groupIndex)
                if r.location == NSNotFound { return fallback }
                return Int(nsLine.substring(with: r)) ?? fallback
            }

            let oldCount = intAt(2, default: 1)
            let newStart = intAt(3, default: 0)
            let newCount = intAt(4, default: 1)
            if newCount == 0 || newStart == 0 { continue }

            let kind: LineChange.Kind = (oldCount == 0) ? .added : .modified
            for i in 0..<newCount {
                changes.append(LineChange(line: newStart + i, kind: kind))
            }
        }
        return changes
    }

    private static func runGit(_ args: [String], in root: URL) -> String? {
        let process = Process()
        process.launchPath = "/usr/bin/env"
        process.arguments = ["git", "-C", root.path] + args
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
