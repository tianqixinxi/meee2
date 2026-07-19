import XCTest
@testable import meee2Kit

final class ArtifactPageAPITests: XCTestCase {
    func testTenThousandArtifactsReturnOnlyFirstFiftyAndStableNextCursor() throws {
        let artifacts = (0..<10_000).map { index in
            makeArtifact(
                id: "artifact-\(index)",
                reference: "slot-\(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        let source = ArtifactPageSource(canvas: makeCanvas(), artifacts: artifacts)
        let first = try ArtifactPageBuilder.build(
            sources: [source],
            query: ArtifactPageQuery(limit: 50, status: "all")
        )

        XCTAssertEqual(first.items.count, 50)
        XCTAssertEqual(first.total, 10_000)
        XCTAssertTrue(first.hasMore)
        let cursor = try XCTUnwrap(first.cursor)
        XCTAssertEqual(first.items.first?.artifacts.first?.id, "artifact-9999")

        let second = try ArtifactPageBuilder.build(
            sources: [source],
            query: ArtifactPageQuery(cursor: cursor, limit: 50, status: "all")
        )
        XCTAssertEqual(second.items.count, 50)
        XCTAssertEqual(second.items.first?.artifacts.first?.id, "artifact-9949")
        XCTAssertTrue(Set(first.items.flatMap(\.artifacts).map(\.id))
            .isDisjoint(with: Set(second.items.flatMap(\.artifacts).map(\.id))))
    }

    func testSlotVersionsAreDeduplicated() throws {
        let older = makeArtifact(
            id: "old",
            reference: "release.md",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let newer = makeArtifact(
            id: "new",
            reference: " RELEASE.md ",
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let source = ArtifactPageSource(canvas: makeCanvas(), artifacts: [older, newer])

        let artifactsPage = try ArtifactPageBuilder.build(
            sources: [source],
            query: ArtifactPageQuery(status: "all")
        )
        XCTAssertEqual(artifactsPage.total, 1)
        XCTAssertEqual(artifactsPage.items[0].artifacts.map(\.id), ["new", "old"])
    }

    func testFiltersStatusCanvasQueryAndSessionBeforePagination() throws {
        let ready = makeArtifact(id: "ready", reference: "release.md", createdAt: Date(timeIntervalSince1970: 2))
        var pending = makeArtifact(id: "pending", reference: "review.md", createdAt: Date(timeIntervalSince1970: 3))
        pending.reviewStatus = "pending"
        let source = ArtifactPageSource(
            canvas: makeCanvas(id: "release", name: "Release Canvas", workspacePath: "/repo/release"),
            artifacts: [ready, pending],
            sessionIdOverride: "session-a"
        )

        let page = try ArtifactPageBuilder.build(
            sources: [source],
            query: ArtifactPageQuery(
                status: "needs-review",
                canvasId: "release",
                query: "review",
                sessionIds: ["SESSION-A"]
            )
        )
        XCTAssertEqual(page.total, 1)
        XCTAssertEqual(page.availableTotal, 1)
        XCTAssertNil(page.statusCounts["ready"])
        XCTAssertEqual(page.statusCounts["needs-review"], 1)
        XCTAssertEqual(page.items[0].artifacts.first?.id, "pending")
        XCTAssertEqual(page.groupCounts["files-data"], 1)
    }

    func testAvailableTotalAndStatusCountsIgnoreStatusAndGroupFilters() throws {
        let ready = makeArtifact(id: "ready", reference: "release.md", createdAt: Date(timeIntervalSince1970: 2))
        var pending = makeArtifact(id: "pending", reference: "review.md", createdAt: Date(timeIntervalSince1970: 3))
        pending.reviewStatus = "pending"
        let source = ArtifactPageSource(canvas: makeCanvas(), artifacts: [ready, pending])

        let page = try ArtifactPageBuilder.build(
            sources: [source],
            query: ArtifactPageQuery(status: "needs-review", group: "files-data")
        )

        XCTAssertEqual(page.total, 1)
        XCTAssertEqual(page.availableTotal, 2)
        XCTAssertEqual(page.statusCounts["ready"], 1)
        XCTAssertEqual(page.statusCounts["needs-review"], 1)
    }

    func testInvalidCursorIsRejected() {
        XCTAssertThrowsError(try ArtifactPageBuilder.build(
            sources: [],
            query: ArtifactPageQuery(cursor: "not-base64", status: "all")
        )) { error in
            guard let pageError = error as? ArtifactPageBuilderError,
                  case .invalidCursor = pageError else {
                return XCTFail("expected invalid cursor, got \(error)")
            }
        }
    }

    private func makeArtifact(
        id: String,
        reference: String,
        createdAt: Date
    ) -> PlannerArtifact {
        PlannerArtifact(
            id: id,
            canvasId: "release",
            nodeId: "node-a",
            kind: .generic,
            title: id,
            reference: reference,
            status: "done",
            createdAt: createdAt
        )
    }

    private func makeCanvas(
        id: String = "release",
        name: String = "Release",
        workspacePath: String = "/repo/release"
    ) -> CanvasInfoDTO {
        CanvasInfoDTO(
            id: id,
            name: name,
            scope: "personal",
            visibility: "private",
            kind: "board",
            isDefault: false,
            workspacePath: workspacePath,
            parentCanvasId: nil,
            parentNodeId: nil,
            teamId: nil,
            ownerUserId: nil,
            remoteId: nil,
            remoteVersion: nil,
            syncStatus: nil,
            dirtySince: nil,
            lastSyncedAt: nil,
            lastRemoteUpdatedAt: nil,
            conflictRemoteVersion: nil,
            conflictRemoteDeleted: nil,
            draftOfTemplateId: nil
        )
    }
}
