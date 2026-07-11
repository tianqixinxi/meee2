import XCTest
@testable import meee2Kit

final class SessionWorkspaceInspectorTests: XCTestCase {
    func testParseNumstatSumsTextChangesAndIgnoresBinaryMarkers() {
        let result = SessionWorkspaceInspector.parseNumstat("""
        12\t3\tSources/App.swift
        -\t-\tAssets/icon.png
        4\t0\tREADME.md
        """)

        XCTAssertEqual(result.additions, 16)
        XCTAssertEqual(result.deletions, 3)
    }

    func testParseStatusCountsChangesAndReturnsOnlyCreatedFiles() {
        let result = SessionWorkspaceInspector.parseStatus(
            " M Sources/App.swift\0A  Sources/New.swift\0?? output/report.md\0D  old.txt\0"
        )

        XCTAssertEqual(result.changedFiles, 4)
        XCTAssertEqual(result.createdPaths, ["Sources/New.swift", "output/report.md"])
    }

    func testNonGitWorkspaceUsesExistingSessionFileOutputs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meee2-environment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("result.md")
        try Data("done".utf8).write(to: output)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("meee2-external-output-\(UUID().uuidString).md")
        try Data("outside".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let escapingLink = root.appendingPathComponent("external-link.md")
        try FileManager.default.createSymbolicLink(at: escapingLink, withDestinationURL: outside)

        let snapshot = SessionWorkspaceInspector.inspect(
            sessionId: "session-a",
            cwd: root.path,
            candidateFilePaths: [
                output.path,
                outside.path,
                escapingLink.path,
                root.appendingPathComponent("missing.md").path
            ]
        )

        XCTAssertFalse(snapshot.isGit)
        XCTAssertNil(snapshot.branch)
        XCTAssertNil(snapshot.changes)
        XCTAssertEqual(snapshot.outputs, [
            SessionWorkspaceOutputFile(path: output.path, relativePath: "result.md")
        ])
    }

    func testGitWorkspaceReportsBranchChangesAndCreatedFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meee2-git-environment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try runGit(["init", "-b", "main"], cwd: root)
        try runGit(["config", "user.email", "tests@meee2.local"], cwd: root)
        try runGit(["config", "user.name", "Meee2 Tests"], cwd: root)
        let tracked = root.appendingPathComponent("tracked.txt")
        try Data("first\n".utf8).write(to: tracked)
        try runGit(["add", "tracked.txt"], cwd: root)
        try runGit(["commit", "-m", "initial"], cwd: root)
        try Data("first\nsecond\n".utf8).write(to: tracked)
        let created = root.appendingPathComponent("result.md")
        try Data("output\n".utf8).write(to: created)

        let snapshot = SessionWorkspaceInspector.inspect(sessionId: "session-git", cwd: root.path)

        XCTAssertTrue(snapshot.isGit)
        XCTAssertEqual(snapshot.branch, "main")
        XCTAssertEqual(snapshot.changes, SessionWorkspaceChangeSummary(files: 2, additions: 1, deletions: 0))
        XCTAssertEqual(snapshot.outputs, [
            SessionWorkspaceOutputFile(path: created.path, relativePath: "result.md")
        ])
    }

    func testOutputLookupOnlyAcceptsPathsPresentInSnapshot() {
        let snapshot = SessionWorkspaceSnapshot(
            sessionId: "session-a",
            cwd: "/tmp/project",
            isGit: true,
            changes: nil,
            branch: "main",
            outputs: [SessionWorkspaceOutputFile(path: "/tmp/project/result.md", relativePath: "result.md")]
        )

        XCTAssertEqual(
            SessionWorkspaceInspector.output(in: snapshot, matching: "/tmp/project/./result.md"),
            snapshot.outputs[0]
        )
        XCTAssertNil(SessionWorkspaceInspector.output(in: snapshot, matching: "/tmp/project/secret.md"))
    }

    private func runGit(_ arguments: [String], cwd: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", cwd.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }
}
