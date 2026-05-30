import XCTest
import Meee2PluginKit
@testable import meee2Kit

final class IslandAttentionStateTests: XCTestCase {
    func testIdleSessionDoesNotLeakSessionTitleIntoCompactState() {
        let session = pluginSession(id: "idle-session", title: "Secret Session", status: .idle)

        let state = IslandAttentionBuilder.build(sessions: [session], monitorItems: [])

        XCTAssertFalse(state.hasAttention)
        XCTAssertTrue(state.displayedItems.isEmpty)
        XCTAssertFalse(state.compactTitle.contains("Secret Session"))
        XCTAssertFalse(state.compactDetail.contains("Secret Session"))
    }

    func testPermissionSessionBeatsWorkspaceMonitorItemsAndCanRespond() {
        var decisions: [String] = []
        let session = pluginSession(
            id: "permission-session",
            title: "Permission Session",
            status: .permissionRequired,
            urgentEvent: UrgentEventInfo(
                id: "permission-a",
                eventType: "permission",
                message: "Approve Bash?",
                respond: { decision in
                    switch decision {
                    case .allow:
                        decisions.append("allow")
                    case .deny(let reason):
                        decisions.append("deny:\(reason ?? "")")
                    }
                }
            )
        )

        let state = IslandAttentionBuilder.build(
            sessions: [session],
            monitorItems: [blockedMonitorItem()]
        )

        XCTAssertEqual(state.totalAttentionCount, 2)
        XCTAssertEqual(state.displayedItems.first?.source, .permission)
        XCTAssertEqual(state.displayedItems.first?.sessionId, "permission-session")

        let manager = StatusManager()
        manager.respondToPermission(for: session, decision: .allow)
        manager.respondToPermission(for: session, decision: .deny(reason: "Nope"))
        XCTAssertEqual(decisions, ["allow", "deny:Nope"])
    }

    func testWorkspaceMonitorBlockedAndProposalItemsAreSortedBySeverity() {
        let state = IslandAttentionBuilder.build(
            sessions: [],
            monitorItems: [
                pendingProposalMonitorItem(),
                blockedMonitorItem()
            ]
        )

        XCTAssertEqual(state.totalAttentionCount, 2)
        XCTAssertEqual(state.displayedItems.map(\.source), [.canvas, .proposal])
        XCTAssertEqual(state.displayedItems.first?.title, "Blocked work")
        XCTAssertEqual(state.displayedItems.last?.title, "Proposal needs review")
        XCTAssertEqual(state.displayedItems.last?.proposalId, "proposal-a")
    }

    func testMonitorFailureFallsBackToUrgentSessionItems() {
        enum MonitorFailure: Error { case boom }
        let session = pluginSession(
            id: "urgent-session",
            title: "Urgent Session",
            status: .permissionRequired,
            urgentEvent: UrgentEventInfo(
                id: "permission-b",
                eventType: "permission",
                message: "Approve Edit?"
            )
        )

        let state = IslandAttentionBuilder.build(sessions: [session]) {
            throw MonitorFailure.boom
        }

        XCTAssertTrue(state.monitorFailed)
        XCTAssertEqual(state.totalAttentionCount, 1)
        XCTAssertEqual(state.displayedItems.first?.source, .permission)
    }

    private func pluginSession(
        id: String,
        title: String,
        status: SessionStatus,
        urgentEvent: UrgentEventInfo? = nil
    ) -> PluginSession {
        PluginSession(
            id: id,
            pluginId: "com.meee2.plugin.claude",
            title: title,
            status: status,
            startedAt: Date(timeIntervalSince1970: 1),
            urgentEvent: urgentEvent
        )
    }

    private func blockedMonitorItem() -> PlannerMonitorItem {
        PlannerMonitorItem(
            id: "canvas-canvas-a",
            kind: .delivery,
            canvasId: "canvas-a",
            canvasTitle: "Release Canvas",
            nodeId: nil,
            nodeTitle: nil,
            proposalId: nil,
            proposalStatus: nil,
            summary: "Release Canvas",
            runState: .blocked,
            blockers: ["Owner permission required"],
            needsOwnerReview: false,
            doerId: nil,
            riskRank: 0,
            evidenceCount: 1,
            updatedAt: Date(timeIntervalSince1970: 3),
            nextAction: "Review the blocked work"
        )
    }

    private func pendingProposalMonitorItem() -> PlannerMonitorItem {
        PlannerMonitorItem(
            id: "proposal-proposal-a",
            kind: .proposal,
            canvasId: "canvas-a",
            canvasTitle: "Release Canvas",
            nodeId: nil,
            nodeTitle: nil,
            proposalId: "proposal-a",
            proposalStatus: .pending,
            summary: "Update release plan",
            runState: nil,
            blockers: [],
            needsOwnerReview: true,
            doerId: nil,
            riskRank: 1,
            evidenceCount: 0,
            updatedAt: Date(timeIntervalSince1970: 2),
            nextAction: nil
        )
    }
}
