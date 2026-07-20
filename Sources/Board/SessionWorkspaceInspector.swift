import Foundation

struct SessionWorkspaceChangeSummary: Encodable, Equatable {
    let files: Int
    let additions: Int
    let deletions: Int
}

struct SessionWorkspaceOutputFile: Encodable, Equatable {
    let path: String
    let relativePath: String
}

struct SessionWorkspaceStatusEntry: Equatable {
    let relativePath: String
    let status: String
}

struct SessionWorkspaceChangedFile: Encodable, Equatable {
    let relativePath: String
    let status: String
    let additions: Int?
    let deletions: Int?
}

struct SessionWorkspaceSnapshot: Encodable, Equatable {
    let sessionId: String
    let cwd: String
    let isGit: Bool
    let changes: SessionWorkspaceChangeSummary?
    let branch: String?
    let files: [SessionWorkspaceChangedFile]
    let outputs: [SessionWorkspaceOutputFile]
}

enum SessionWorkspaceInspector {
    private struct CacheEntry {
        let snapshot: SessionWorkspaceSnapshot
        let capturedAt: Date
    }

    private static let cacheCondition = NSCondition()
    private static let cacheTTL: TimeInterval = 2
    private static let cacheLimit = 32
    private static var cache: [String: CacheEntry] = [:]
    private static var inFlightKeys = Set<String>()

    static func output(
        in snapshot: SessionWorkspaceSnapshot,
        matching rawPath: String
    ) -> SessionWorkspaceOutputFile? {
        let requestedPath = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        return snapshot.outputs.first {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == requestedPath
        }
    }

    static func inspect(
        sessionId: String,
        cwd: String
    ) -> SessionWorkspaceSnapshot {
        let normalizedCwd = URL(fileURLWithPath: cwd).standardizedFileURL.path
        guard let root = runGit(cwd: normalizedCwd, arguments: ["rev-parse", "--show-toplevel"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !root.isEmpty else {
            return SessionWorkspaceSnapshot(
                sessionId: sessionId,
                cwd: normalizedCwd,
                isGit: false,
                changes: nil,
                branch: nil,
                files: [],
                outputs: []
            )
        }

        let status = parseStatus(
            runGit(cwd: root, arguments: ["status", "--porcelain=v1", "-z", "--untracked-files=all"]) ?? ""
        )
        let numstat = runGit(cwd: root, arguments: ["diff", "--numstat", "HEAD", "--"])
            ?? [
                runGit(cwd: root, arguments: ["diff", "--numstat", "--"]) ?? "",
                runGit(cwd: root, arguments: ["diff", "--cached", "--numstat", "--"]) ?? ""
            ].joined(separator: "\n")
        let totals = parseNumstat(numstat)
        let numstatByPath = parseNumstatByPath(numstat)
        let branch = resolvedBranch(cwd: root)
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        let outputs = status.createdPaths.compactMap { relativePath in
            workspaceOutput(
                url: rootURL.appendingPathComponent(relativePath).standardizedFileURL,
                relativePath: relativePath,
                root: rootURL
            )
        }
        let files = status.files.prefix(200).map { file in
            let stats = numstatByPath[file.relativePath]
            return SessionWorkspaceChangedFile(
                relativePath: file.relativePath,
                status: file.status,
                additions: stats?.additions,
                deletions: stats?.deletions
            )
        }

        return SessionWorkspaceSnapshot(
            sessionId: sessionId,
            cwd: normalizedCwd,
            isGit: true,
            changes: SessionWorkspaceChangeSummary(
                files: status.changedFiles,
                additions: totals.additions,
                deletions: totals.deletions
            ),
            branch: branch,
            files: files,
            outputs: outputs
        )
    }

    /// Environment polling can arrive from focus changes and timers at nearly
    /// the same moment. Cache by workspace and make a cache
    /// miss single-flight so those requests share one set of Git processes.
    static func inspectCached(
        sessionId: String,
        cwd: String,
        now: Date = Date()
    ) -> SessionWorkspaceSnapshot {
        let key = cacheKey(cwd: cwd)

        cacheCondition.lock()
        while true {
            if let entry = cache[key], now.timeIntervalSince(entry.capturedAt) < cacheTTL {
                cacheCondition.unlock()
                return replacingSessionId(in: entry.snapshot, with: sessionId)
            }
            if !inFlightKeys.contains(key) {
                inFlightKeys.insert(key)
                cacheCondition.unlock()
                break
            }
            cacheCondition.wait()
        }

        let snapshot = inspect(
            sessionId: sessionId,
            cwd: cwd
        )

        cacheCondition.lock()
        cache[key] = CacheEntry(snapshot: snapshot, capturedAt: now)
        if cache.count > cacheLimit,
           let oldest = cache.min(by: { $0.value.capturedAt < $1.value.capturedAt })?.key {
            cache.removeValue(forKey: oldest)
        }
        inFlightKeys.remove(key)
        cacheCondition.broadcast()
        cacheCondition.unlock()
        return snapshot
    }

    static func resetCacheForTests() {
        cacheCondition.lock()
        cache.removeAll()
        inFlightKeys.removeAll()
        cacheCondition.broadcast()
        cacheCondition.unlock()
    }

    static func parseNumstat(_ output: String) -> (additions: Int, deletions: Int) {
        output.split(separator: "\n").reduce(into: (additions: 0, deletions: 0)) { totals, line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { return }
            totals.additions += Int(fields[0]) ?? 0
            totals.deletions += Int(fields[1]) ?? 0
        }
    }

    static func parseNumstatByPath(_ output: String) -> [String: (additions: Int, deletions: Int)] {
        output.split(separator: "\n").reduce(into: [:]) { files, line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3,
                  let additions = Int(fields[0]),
                  let deletions = Int(fields[1]) else { return }
            let path = fields.dropFirst(2).joined(separator: "\t")
            guard !path.isEmpty else { return }
            let previous = files[path] ?? (additions: 0, deletions: 0)
            files[path] = (previous.additions + additions, previous.deletions + deletions)
        }
    }

    static func parseStatus(
        _ output: String
    ) -> (changedFiles: Int, createdPaths: [String], files: [SessionWorkspaceStatusEntry]) {
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var createdPaths: [String] = []
        var files: [SessionWorkspaceStatusEntry] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            guard record.count >= 3 else {
                index += 1
                continue
            }
            let status = String(record.prefix(2))
            let path = String(record.dropFirst(3))
            if status == "??" || status.first == "A" || status.last == "A" {
                createdPaths.append(path)
            }
            files.append(SessionWorkspaceStatusEntry(
                relativePath: path,
                status: changedFileStatus(status)
            ))
            if status.contains("R") || status.contains("C") {
                index += 1
            }
            index += 1
        }
        return (
            files.count,
            Array(Set(createdPaths)).sorted(),
            files.sorted { $0.relativePath < $1.relativePath }
        )
    }

    private static func changedFileStatus(_ porcelainStatus: String) -> String {
        if porcelainStatus == "??" { return "untracked" }
        if porcelainStatus.contains("R") || porcelainStatus.contains("C") { return "renamed" }
        if porcelainStatus.contains("D") { return "deleted" }
        if porcelainStatus.contains("A") { return "added" }
        return "modified"
    }

    private static func resolvedBranch(cwd: String) -> String? {
        let branch = runGit(cwd: cwd, arguments: ["branch", "--show-current"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let branch, !branch.isEmpty { return branch }
        guard let commit = runGit(cwd: cwd, arguments: ["rev-parse", "--short", "HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !commit.isEmpty else { return nil }
        return "@\(commit)"
    }

    private static func cacheKey(cwd: String) -> String {
        URL(fileURLWithPath: cwd).standardizedFileURL.path
    }

    private static func replacingSessionId(
        in snapshot: SessionWorkspaceSnapshot,
        with sessionId: String
    ) -> SessionWorkspaceSnapshot {
        SessionWorkspaceSnapshot(
            sessionId: sessionId,
            cwd: snapshot.cwd,
            isGit: snapshot.isGit,
            changes: snapshot.changes,
            branch: snapshot.branch,
            files: snapshot.files,
            outputs: snapshot.outputs
        )
    }

    private static func workspaceOutput(
        url: URL,
        relativePath: String,
        root: URL
    ) -> SessionWorkspaceOutputFile? {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedOutput = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedOutput.hasPrefix(resolvedRoot + "/") else { return nil }
        return SessionWorkspaceOutputFile(path: url.path, relativePath: relativePath)
    }

    private static func runGit(cwd: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", cwd] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            MDebug("[SessionWorkspaceInspector] git inspection failed: \(error.localizedDescription)")
            return nil
        }
    }
}
