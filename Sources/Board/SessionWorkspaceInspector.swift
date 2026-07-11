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

struct SessionWorkspaceSnapshot: Encodable, Equatable {
    let sessionId: String
    let cwd: String
    let isGit: Bool
    let changes: SessionWorkspaceChangeSummary?
    let branch: String?
    let outputs: [SessionWorkspaceOutputFile]
}

enum SessionWorkspaceInspector {
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
        cwd: String,
        candidateFilePaths: [String] = []
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
                outputs: candidateOutputs(paths: candidateFilePaths, cwd: normalizedCwd)
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
        let branch = resolvedBranch(cwd: root)
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        let outputs = status.createdPaths.compactMap { relativePath in
            workspaceOutput(
                url: rootURL.appendingPathComponent(relativePath).standardizedFileURL,
                relativePath: relativePath,
                root: rootURL
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
            outputs: outputs
        )
    }

    static func parseNumstat(_ output: String) -> (additions: Int, deletions: Int) {
        output.split(separator: "\n").reduce(into: (additions: 0, deletions: 0)) { totals, line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { return }
            totals.additions += Int(fields[0]) ?? 0
            totals.deletions += Int(fields[1]) ?? 0
        }
    }

    static func parseStatus(_ output: String) -> (changedFiles: Int, createdPaths: [String]) {
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var changedFiles = 0
        var createdPaths: [String] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            guard record.count >= 3 else {
                index += 1
                continue
            }
            let status = String(record.prefix(2))
            let path = String(record.dropFirst(3))
            changedFiles += 1
            if status == "??" || status.first == "A" || status.last == "A" {
                createdPaths.append(path)
            }
            if status.contains("R") || status.contains("C") {
                index += 1
            }
            index += 1
        }
        return (changedFiles, Array(Set(createdPaths)).sorted())
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

    private static func candidateOutputs(paths: [String], cwd: String) -> [SessionWorkspaceOutputFile] {
        let root = URL(fileURLWithPath: cwd).standardizedFileURL
        return Array(Set(paths)).compactMap { rawPath in
            let absolute = rawPath.hasPrefix("/")
                ? URL(fileURLWithPath: rawPath).standardizedFileURL
                : root.appendingPathComponent(rawPath).standardizedFileURL
            guard FileManager.default.fileExists(atPath: absolute.path) else { return nil }
            guard absolute.path.hasPrefix(root.path + "/") else { return nil }
            let relative = String(absolute.path.dropFirst(root.path.count + 1))
            return workspaceOutput(url: absolute, relativePath: relative, root: root)
        }.sorted { $0.relativePath < $1.relativePath }
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
