import XCTest
@testable import meee2Kit

final class ReadinessDoctorTests: XCTestCase {
    func testDiagnoseIncludesM0RequiredChecks() {
        let report = ReadinessDoctor.diagnose()
        let checksById = Dictionary(uniqueKeysWithValues: report.checks.map { ($0.id, $0) })

        for id in [
            "provider.claude",
            "provider.codex",
            "provider-hook.claude",
            "surface.hook-socket",
            "surface.board-server",
            "runtime.meee2-mcp",
            "storage.sessions",
            "storage.board-layout",
            "storage.runtime"
        ] {
            XCTAssertNotNil(checksById[id], "missing readiness check \(id)")
        }

        XCTAssertEqual(checksById["provider-hook.claude"]?.severity, .required)
        XCTAssertEqual(checksById["surface.hook-socket"]?.severity, .required)
        XCTAssertEqual(checksById["surface.board-server"]?.severity, .required)
        XCTAssertEqual(checksById["storage.sessions"]?.severity, .required)
    }

    func testReadyMatchesRequiredFailures() {
        let report = ReadinessDoctor.diagnose()
        let requiredFailures = report.checks.filter { $0.severity == .required && $0.status == .fail }.count

        XCTAssertEqual(report.requiredFailed, requiredFailures)
        XCTAssertEqual(report.ready, requiredFailures == 0)
        XCTAssertEqual(report.overall, requiredFailures == 0 ? .ready : .needsSetup)
    }
}
