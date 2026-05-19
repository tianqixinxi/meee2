import XCTest
@testable import meee2Kit

/// P1–P3 agent-integration-detection — detection engine, side-effect
/// inference, runbook generation.
final class IntegrationDetectionTests: XCTestCase {
    private func node(
        contextSources: [ContextSource] = [],
        artifactRefs: [String]? = nil,
        produces: [String] = [],
        consumes: [String] = []
    ) -> PlanningNode {
        var node = PlanningNode(
            id: "n1", canvasId: "c", title: "step",
            ioSchema: IOSchema(consumes: consumes, produces: produces, completionSignal: "done"),
            contextSources: contextSources,
            executionMode: .signOff, executorType: .mock, doerId: "owner", status: .waiting
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
}
