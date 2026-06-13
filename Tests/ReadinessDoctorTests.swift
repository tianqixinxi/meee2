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

        XCTAssertNotNil(checksById["provider-hook.claude"]?.severity)
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

    func testMissingBothProviderRuntimesBlocksOnboarding() {
        let checks = ReadinessDoctor.providerReadinessChecks(runtime: runtimeStatus(
            claude: provider(available: false, configured: false),
            codex: provider(available: false, configured: false)
        ))
        let byId = Dictionary(uniqueKeysWithValues: checks.map { ($0.id, $0) })

        XCTAssertEqual(byId["provider.claude"]?.status, .fail)
        XCTAssertEqual(byId["provider.claude"]?.severity, .required)
        XCTAssertEqual(byId["provider.claude"]?.recoveryAction?.id, "install-provider-claude")
        XCTAssertEqual(byId["provider.codex"]?.status, .fail)
        XCTAssertEqual(byId["provider.codex"]?.severity, .required)
        XCTAssertEqual(byId["provider.codex"]?.recoveryAction?.id, "install-provider-codex")
    }

    func testOneConfiguredProviderSatisfiesProviderReadiness() {
        let checks = ReadinessDoctor.providerReadinessChecks(runtime: runtimeStatus(
            claude: provider(available: false, configured: false),
            codex: provider(available: true, configured: true)
        ))
        let byId = Dictionary(uniqueKeysWithValues: checks.map { ($0.id, $0) })

        XCTAssertEqual(byId["provider.codex"]?.status, .pass)
        XCTAssertEqual(byId["provider.codex"]?.severity, .required)
        XCTAssertEqual(byId["provider.claude"]?.status, .info)
        XCTAssertEqual(byId["provider.claude"]?.severity, .recommended)
    }

    private func runtimeStatus(
        claude: AgentRuntimeComponentStatus,
        codex: AgentRuntimeComponentStatus
    ) -> Meee2AgentRuntimeStatus {
        Meee2AgentRuntimeStatus(
            marketplacePath: "/tmp/marketplace",
            pluginPath: "/tmp/marketplace/meee2",
            mcpServerPath: "/tmp/mcp/server.js",
            stagedMCPServerPath: nil,
            claude: claude,
            codex: codex,
            needsAttention: false,
            checkedAt: Date()
        )
    }

    private func provider(
        available: Bool,
        configured: Bool
    ) -> AgentRuntimeComponentStatus {
        AgentRuntimeComponentStatus(
            available: available,
            cliAvailable: available,
            appAvailable: false,
            cliPath: available ? "/usr/local/bin/provider" : nil,
            appPath: nil,
            installed: configured,
            configured: configured,
            detail: nil,
            command: available ? "provider plugin install meee2" : nil
        )
    }
}
