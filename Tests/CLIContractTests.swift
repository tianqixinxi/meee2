import XCTest
import Meee2PluginKit
@testable import meee2Kit

final class CLIContractTests: XCTestCase {
    func testTopLevelParserUsesStableUsageCodes() {
        XCTAssertEqual(CLI.run(args: []), .runGUI)
        XCTAssertEqual(CLI.run(args: ["gui"]), .runGUI)
        XCTAssertEqual(CLI.run(args: ["unknown"]), .exit(.usage))
        XCTAssertEqual(CLI.run(args: ["jump"]), .exit(.usage))
        XCTAssertEqual(CLI.run(args: ["list", "--json", "--simple"]), .exit(.usage))
    }

    func testVersionUsesBundleValueAndStableDevelopmentFallback() {
        XCTAssertEqual(
            BuildInfo.resolveVersion(
                infoDictionary: ["CFBundleShortVersionString": "0.6.0"],
                environment: [:]
            ),
            "0.6.0"
        )
        XCTAssertEqual(BuildInfo.resolveVersion(infoDictionary: nil, environment: [:]), "0.0.0-dev")
        XCTAssertEqual(
            BuildInfo.resolveVersion(
                infoDictionary: ["CFBundleShortVersionString": "0.6.0"],
                environment: ["MEEE2_VERSION": "0.6.1-rc1"]
            ),
            "0.6.1-rc1"
        )
    }

    func testDefaultListHidesHistoricalAndOldIdleSessions() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let recentIdle = session(id: "recent", status: .idle, activity: now.addingTimeInterval(-60))
        let oldIdle = session(id: "old-idle", status: .idle, activity: now.addingTimeInterval(-10 * 86_400))
        let working = session(id: "working", status: .active, activity: now.addingTimeInterval(-10 * 86_400))
        let dead = session(id: "dead", status: .dead, activity: now.addingTimeInterval(-60))
        let all = [recentIdle, oldIdle, working, dead]

        XCTAssertEqual(
            Set(ListCommand.sessionsForDisplay(all, includeAll: false, now: now).map(\.sessionId)),
            Set(["recent", "working"])
        )
        XCTAssertEqual(ListCommand.sessionsForDisplay(all, includeAll: true, now: now).count, 4)
    }

    private func session(id: String, status: SessionStatus, activity: Date) -> SessionData {
        SessionData(
            sessionId: id,
            project: "fixture",
            startedAt: activity.addingTimeInterval(-60),
            lastActivity: activity,
            status: status
        )
    }
}
