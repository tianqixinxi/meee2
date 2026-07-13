import XCTest
@testable import meee2Kit

final class SessionWorkspaceInspectorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SessionWorkspaceInspector.resetCacheForTests()
    }

    override func tearDown() {
        SessionWorkspaceInspector.resetCacheForTests()
        super.tearDown()
    }

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

    func testNonGitWorkspaceHasNoInferredOutputs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meee2-environment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = SessionWorkspaceInspector.inspect(
            sessionId: "session-a",
            cwd: root.path
        )

        XCTAssertFalse(snapshot.isGit)
        XCTAssertNil(snapshot.branch)
        XCTAssertNil(snapshot.changes)
        XCTAssertEqual(snapshot.outputs, [])
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

    func testCachedInspectionReusesFreshSnapshotAndRefreshesAfterTTL() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meee2-cached-environment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try runGit(["init", "-b", "main"], cwd: root)
        try runGit(["config", "user.email", "tests@meee2.local"], cwd: root)
        try runGit(["config", "user.name", "Meee2 Tests"], cwd: root)
        let tracked = root.appendingPathComponent("tracked.txt")
        try Data("first\n".utf8).write(to: tracked)
        try runGit(["add", "tracked.txt"], cwd: root)
        try runGit(["commit", "-m", "initial"], cwd: root)

        let startedAt = Date()
        try Data("first\nsecond\n".utf8).write(to: tracked)
        let initial = SessionWorkspaceInspector.inspectCached(
            sessionId: "session-a",
            cwd: root.path,
            now: startedAt
        )
        XCTAssertEqual(initial.changes?.additions, 1)

        try Data("first\nsecond\nthird\n".utf8).write(to: tracked)
        let cached = SessionWorkspaceInspector.inspectCached(
            sessionId: "session-b",
            cwd: root.path,
            now: startedAt.addingTimeInterval(1)
        )
        XCTAssertEqual(cached.sessionId, "session-b")
        XCTAssertEqual(cached.changes?.additions, 1)

        let refreshed = SessionWorkspaceInspector.inspectCached(
            sessionId: "session-b",
            cwd: root.path,
            now: startedAt.addingTimeInterval(3)
        )
        XCTAssertEqual(refreshed.changes?.additions, 2)
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
