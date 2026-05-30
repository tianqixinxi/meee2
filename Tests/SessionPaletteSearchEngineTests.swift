import XCTest
import Meee2PluginKit
@testable import meee2Kit

final class SessionPaletteSearchEngineTests: XCTestCase {
    func testSearchIncludesExternalPluginSessions() {
        let engine = SessionPaletteSearchEngine()
        engine.query = "checkout"

        let live = PluginSession(
            id: "com.meee2.plugin.claude-session-a",
            pluginId: "com.meee2.plugin.claude",
            title: "Checkout fix",
            status: .active,
            startedAt: Date(timeIntervalSince1970: 10),
            lastUpdated: Date(timeIntervalSince1970: 20),
            cwd: "/tmp/shop/checkout"
        )
        let historical = PluginSession(
            id: "com.meee2.plugin.claude-session-b",
            pluginId: "com.meee2.plugin.claude",
            title: "Checkout old",
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 1),
            cwd: "/tmp/shop/checkout"
        )

        let results = engine.search(sessions: [historical, live], storeSessions: [])

        XCTAssertEqual(results.map(\.sessionId), [live.id])
        XCTAssertEqual(results.first?.kind, .session)
        XCTAssertEqual(results.first?.terminalKind, "external")
    }

    func testSearchIncludesInternalSurfacesAndBoardTarget() {
        let engine = SessionPaletteSearchEngine()
        engine.query = "node-a"

        let duplicatePluginSession = PluginSession(
            id: "internal-session-1",
            pluginId: "com.meee2.plugin.claude",
            title: "Writer node",
            status: .active,
            startedAt: Date(timeIntervalSince1970: 9),
            cwd: "/tmp/content/site"
        )
        let surface = TerminalSessionSnapshot(
            sessionId: "internal-session-1",
            surfaceId: "surface-1",
            backend: .ghosttySurface,
            status: "running",
            pid: 123,
            cwd: "/tmp/content/site",
            command: "claude",
            provider: "claude",
            canvasId: "canvas-a",
            nodeId: "node-a",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 30)
        )

        let results = engine.search(
            sessions: [duplicatePluginSession],
            storeSessions: [],
            internalSurfaces: [surface]
        )

        XCTAssertEqual(results.map(\.sessionId), ["internal-session-1"])
        XCTAssertEqual(results.first?.surfaceId, "surface-1")
        XCTAssertEqual(results.first?.terminalKind, "internal")
    }

    func testSearchIncludesCanvasesAndArtifacts() {
        let engine = SessionPaletteSearchEngine()
        engine.query = "release"

        let canvas = BoardLayoutStore.Canvas(
            id: "canvas-release",
            name: "Release Plan",
            scope: .personal,
            ownerUserId: "local",
            teamId: nil,
            isDefault: false,
            workspaceFolderName: "release-plan",
            createdBy: "local",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let artifact = PlannerArtifact(
            id: "artifact-release",
            canvasId: canvas.id,
            nodeId: "node-release",
            kind: .prd,
            title: "Release checklist",
            reference: "artifact://release/checklist",
            status: "ready",
            createdAt: Date(timeIntervalSince1970: 3)
        )

        let results = engine.search(
            sessions: [],
            storeSessions: [],
            canvases: [canvas],
            artifacts: [artifact]
        )

        XCTAssertEqual(Set(results.map(\.kind)), Set([.canvas, .artifact]))
        XCTAssertEqual(results.first(where: { $0.kind == .artifact })?.artifactId, artifact.id)
        XCTAssertEqual(results.first(where: { $0.kind == .artifact })?.nodeId, artifact.nodeId)
    }

    func testDomainFilterLimitsResults() {
        let engine = SessionPaletteSearchEngine()
        engine.domainFilter = .artifacts

        let canvas = BoardLayoutStore.Canvas(
            id: "canvas-a",
            name: "Canvas A",
            scope: .personal,
            ownerUserId: "local",
            teamId: nil,
            isDefault: false,
            createdBy: "local",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let artifact = PlannerArtifact(
            id: "artifact-a",
            canvasId: canvas.id,
            nodeId: "node-a",
            kind: .generic,
            title: "Output A",
            reference: "artifact://a",
            status: "ready",
            createdAt: Date(timeIntervalSince1970: 3)
        )

        let results = engine.search(sessions: [], storeSessions: [], canvases: [canvas], artifacts: [artifact])

        XCTAssertEqual(results.map(\.kind), [.artifact])
    }
}
