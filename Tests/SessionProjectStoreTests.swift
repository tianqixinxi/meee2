import XCTest
@testable import meee2Kit

final class SessionProjectStoreTests: XCTestCase {
    private var tempDir: URL!
    private var projectDir: URL!
    private var store: SessionProjectStore!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("meee2-session-project-tests-\(UUID().uuidString)", isDirectory: true)
        projectDir = tempDir.appendingPathComponent("Project A", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        store = SessionProjectStore(fileURL: tempDir.appendingPathComponent("session-projects.json"))
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        projectDir = nil
        store = nil
    }

    func testUpsertPersistsAndDedupesByNormalizedPath() throws {
        let first = try store.upsert(path: projectDir.path, name: "Project A", preferredProvider: "codex")
        let second = try store.upsert(path: "\(projectDir.path)/", name: "Renamed", preferredProvider: "claude")

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.list().count, 1)
        XCTAssertEqual(store.list()[0].name, "Renamed")
        XCTAssertEqual(store.list()[0].preferredProvider, .claude)

        let reloaded = SessionProjectStore(fileURL: tempDir.appendingPathComponent("session-projects.json"))
        XCTAssertEqual(reloaded.list().count, 1)
        XCTAssertEqual(reloaded.list()[0].path, projectDir.path)
    }

    func testListDoesNotInferHistoricalPaths() throws {
        XCTAssertEqual(store.list().count, 0)

        let reloaded = SessionProjectStore(fileURL: tempDir.appendingPathComponent("session-projects.json"))
        XCTAssertEqual(reloaded.list().count, 0)
    }

    func testMarkUsedDoesNotCreateMissingProject() throws {
        XCTAssertThrowsError(try store.markUsed(projectId: "project-missing", path: projectDir.path, provider: "codex"))
        XCTAssertEqual(store.list().count, 0)
    }
}
