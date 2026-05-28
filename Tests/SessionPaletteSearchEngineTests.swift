import XCTest
import Meee2PluginKit
@testable import meee2Kit

final class SessionPaletteSearchEngineTests: XCTestCase {
    func testSearchMatchesLiveSessionsAndFiltersHistorical() {
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

        XCTAssertEqual(results.map(\.sessionId), ["session-a"])
        XCTAssertEqual(results.first?.project, "checkout")
        XCTAssertEqual(results.first?.terminalKind, "external")
    }

    func testSearchIncludesInternalSurfacesAndBoardTarget() {
        let engine = SessionPaletteSearchEngine()
        engine.query = "writer"

        let duplicatePluginSession = PluginSession(
            id: "com.meee2.plugin.claude-internal-session-1",
            pluginId: "com.meee2.plugin.claude",
            title: "Writer node",
            status: .active,
            startedAt: Date(timeIntervalSince1970: 9),
            cwd: "/tmp/content/site"
        )
        let surface = InternalTerminalSurfaceSnapshot(
            surfaceId: "surface-1",
            sessionId: "internal-session-1",
            provider: "claude",
            title: "Writer node",
            cwd: "/tmp/content/site",
            command: "claude",
            canvasId: "canvas-a",
            nodeId: "node-a",
            status: "running",
            pid: 123,
            exitCode: nil,
            error: nil,
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
        XCTAssertFalse(results.first?.isTerminalJumpable ?? true)
    }
}
