import XCTest
@testable import meee2Kit

/// P1–P3 agent-integration-detection — detection engine, side-effect
/// inference, runbook generation.
final class IntegrationDetectionTests: XCTestCase {
    private func node(
        contextSources: [ContextSource] = [],
        artifactRefs: [String]? = nil,
        outputs: [String] = [],
        inputs: [String] = []
    ) -> PlanningNode {
        var node = PlanningNode(
            id: "n1", canvasId: "c", title: "step",
            schema: NodeSchema(inputs: inputs, outputs: outputs, goal: "done"),
            contextSources: contextSources,
            executionMode: .human, executorType: .mock, doerId: "owner", status: .ready
        )
        node.artifactRefs = artifactRefs
        return node
    }

    // MARK: catalog

    func testCatalogIdsUniqueAndNonEmpty() {
        let ids = IntegrationCatalog.all.map { $0.id }
        XCTAssertFalse(ids.isEmpty)
        XCTAssertEqual(Set(ids).count, ids.count, "catalog ids must be unique")
    }

    // MARK: localStdio install spec (connector-localstdio-install)

    func testGoogleSheetsIsLocalStdioWithOAuthEnvKeys() throws {
        let sheets = try XCTUnwrap(IntegrationCatalog.all.first { $0.id == "google-sheets" })
        guard case let .localStdio(command, args, envKeys) = sheets.install else {
            return XCTFail("google-sheets should be a localStdio connector now, got \(sheets.install)")
        }
        XCTAssertEqual(command, "uvx")
        XCTAssertEqual(args, ["mcp-google-sheets@latest"])
        // OAuth-via-server model: server reads the client + caches the token.
        XCTAssertTrue(envKeys.contains("CREDENTIALS_PATH"))
        XCTAssertTrue(envKeys.contains("TOKEN_PATH"))
    }

    func testLarkRemainsLocalStdio() throws {
        let lark = try XCTUnwrap(IntegrationCatalog.all.first { $0.id == "lark" })
        guard case .localStdio = lark.install else {
            return XCTFail("lark should remain a localStdio connector, got \(lark.install)")
        }
    }

    func testConnectorDirIsUnderMeee2Connectors() {
        let dir = IntegrationInstaller.connectorDir("google-sheets")
        XCTAssertTrue(dir.path.hasSuffix("/.meee2/connectors/google-sheets"), "got \(dir.path)")
    }

    /// P2 fix — google-sheets must gate `connected` on a cached OAuth token,
    /// not flip to connected the moment the MCP config entry is written.
    func testGoogleSheetsNotConnectedUntilTokenPresent() throws {
        let sheets = try XCTUnwrap(IntegrationCatalog.all.first { $0.id == "google-sheets" })
        XCTAssertFalse(sheets.credentialProbes.isEmpty, "needs a token probe so connected ⇒ authorized")
        // Config written (mcpConfigured) but no token yet (credentialPresent=false)
        // ⇒ partial, never connected.
        let pending = IntegrationDetector.resolveState(
            descriptor: sheets, mcpConfigured: true, credentialPresent: false
        )
        XCTAssertNotEqual(pending, .connected)
        // Token cached ⇒ connected.
        let authed = IntegrationDetector.resolveState(
            descriptor: sheets, mcpConfigured: true, credentialPresent: true
        )
        XCTAssertEqual(authed, .connected)
    }

    // MARK: side-effect inference (P2)

    func testRepositoryContextSourceInfersGithubRead() {
        let n = node(contextSources: [
            ContextSource(kind: .repository, title: "the repo", reference: "/path/to/repo"),
        ])
        let effects = NodeSideEffectInferrer.infer(node: n)
        XCTAssertTrue(effects.contains { $0.integrationId == "github" && $0.direction == "reads" })
    }

    func testArtifactRefInfersGithubWrite() {
        let n = node(artifactRefs: ["https://github.com/owner/repo/pull/12"])
        let effects = NodeSideEffectInferrer.infer(node: n)
        XCTAssertTrue(effects.contains { $0.integrationId == "github" && $0.direction == "writes" })
    }

    func testLarkDocContextSourceInfersLarkRead() {
        let n = node(contextSources: [
            ContextSource(kind: .document, title: "PRD", reference: "https://x.larksuite.com/docx/abc"),
        ])
        let effects = NodeSideEffectInferrer.infer(node: n)
        XCTAssertTrue(effects.contains { $0.integrationId == "lark" && $0.direction == "reads" })
    }

    func testNoIntegrationSignalsInfersNothing() {
        let n = node(contextSources: [
            ContextSource(kind: .web, title: "a page", reference: "https://example.com/x"),
        ])
        XCTAssertTrue(NodeSideEffectInferrer.infer(node: n).isEmpty)
    }

    // MARK: runbook (P3)

    func testRunbookGeneratorRejectsUnknownIntegration() {
        XCTAssertThrowsError(try IntegrationRunbookGenerator.generate(integrationId: "nonsense-xyz"))
    }

    // MARK: config readers (P1) — smoke: must not crash on a real machine

    func testConfigReadersDoNotCrash() {
        _ = IntegrationDetector.claudeMCPServerNames()
        _ = IntegrationDetector.codexMCPServerNames()
    }

    // MARK: needs-auth state machine + tools/list probe

    private var oauthShapedDescriptor: IntegrationDescriptor {
        IntegrationDescriptor(
            id: "test-oauth", name: "Test OAuth", category: "test",
            mcpServerNames: ["test-oauth"], credentialProbes: [],
            install: .remoteHttp(url: "https://example.invalid/mcp"),
            setupHint: "n/a"
        )
    }

    func testResolveStateNeedsAuthWhenProbeSeesOnlyBootstrapTools() {
        let state = IntegrationDetector.resolveState(
            descriptor: oauthShapedDescriptor,
            mcpConfigured: true, credentialPresent: false,
            probeResult: .onlyAuthBootstrap(tools: ["authenticate", "complete_authentication"])
        )
        XCTAssertEqual(state, .needsAuth)
    }

    func testResolveStateConnectedWhenProbeSeesRealTools() {
        let state = IntegrationDetector.resolveState(
            descriptor: oauthShapedDescriptor,
            mcpConfigured: true, credentialPresent: false,
            probeResult: .hasRealTools(tools: ["run_query", "list_tables"])
        )
        XCTAssertEqual(state, .connected)
    }

    /// Probe failure (offline / 5xx / timeout) MUST NOT downgrade the row —
    /// matrix should keep the pre-probe state (`.connected` for MCP-only).
    func testResolveStateProbeUnreachableDoesNotRegress() {
        let state = IntegrationDetector.resolveState(
            descriptor: oauthShapedDescriptor,
            mcpConfigured: true, credentialPresent: false,
            probeResult: .unreachable(reason: "timeout")
        )
        XCTAssertEqual(state, .connected)
    }

    /// And without any probe at all (the call site decided not to probe) the
    /// state machine must match its pre-existing behavior.
    func testResolveStateWithoutProbeUnchanged() {
        let state = IntegrationDetector.resolveState(
            descriptor: oauthShapedDescriptor,
            mcpConfigured: true, credentialPresent: false,
            probeResult: nil
        )
        XCTAssertEqual(state, .connected)
    }

    func testResolveStateMissingTrumpsProbe() {
        let state = IntegrationDetector.resolveState(
            descriptor: oauthShapedDescriptor,
            mcpConfigured: false, credentialPresent: false,
            probeResult: .onlyAuthBootstrap(tools: ["authenticate"])
        )
        XCTAssertEqual(state, .missing)
    }

    func testClassifyTreatsAllBootstrapAsNeedsAuth() {
        let result = MCPToolListProbe.classify(["authenticate", "complete_authentication"])
        if case .onlyAuthBootstrap = result {
            return
        }
        XCTFail("expected .onlyAuthBootstrap, got \(result)")
    }

    func testClassifyTreatsBootstrapNamesCaseInsensitively() {
        let result = MCPToolListProbe.classify(["Authenticate", "completeAuthentication"])
        if case .onlyAuthBootstrap = result {
            return
        }
        XCTFail("expected .onlyAuthBootstrap from case-mismatched names")
    }

    func testClassifyTreatsAnyRealToolAsConnected() {
        let result = MCPToolListProbe.classify(["authenticate", "run_query"])
        if case .hasRealTools = result {
            return
        }
        XCTFail("expected .hasRealTools when a non-bootstrap tool is present")
    }

    func testClassifyEmptyListIsUnreachable() {
        let result = MCPToolListProbe.classify([])
        if case .unreachable = result {
            return
        }
        XCTFail("expected .unreachable for empty tool list")
    }

    func testParseToolNamesPlainJSON() {
        let body = """
        {"jsonrpc":"2.0","id":1,"result":{"tools":[
          {"name":"authenticate","description":"x"},
          {"name":"complete_authentication","description":"y"}
        ]}}
        """.data(using: .utf8)!
        let names = MCPToolListProbe.parseToolNames(data: body, contentType: "application/json")
        XCTAssertEqual(names, ["authenticate", "complete_authentication"])
    }

    func testParseToolNamesSSEStream() {
        let body = """
        event: message
        data: {"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"run_query"},{"name":"list_tables"}]}}

        """.data(using: .utf8)!
        let names = MCPToolListProbe.parseToolNames(data: body, contentType: "text/event-stream")
        XCTAssertEqual(names, ["run_query", "list_tables"])
    }

    func testParseToolNamesGarbageReturnsNil() {
        let body = "not json".data(using: .utf8)!
        XCTAssertNil(MCPToolListProbe.parseToolNames(data: body, contentType: "application/json"))
    }
}
