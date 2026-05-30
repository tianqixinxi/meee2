import Foundation
import Meee2PluginKit

enum IslandAttentionSeverity: Int, Comparable {
    case critical = 0
    case attention = 1
    case review = 2
    case running = 3

    static func < (lhs: IslandAttentionSeverity, rhs: IslandAttentionSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum IslandAttentionSource: String {
    case permission
    case urgent
    case proposal
    case canvas
    case node
}

struct IslandAttentionItem: Identifiable, Equatable {
    let id: String
    let source: IslandAttentionSource
    let severity: IslandAttentionSeverity
    let title: String
    let subtitle: String
    let detail: String?
    let canvasId: String?
    let nodeId: String?
    let deliveryId: String?
    let proposalId: String?
    let sessionId: String?
    let eventId: String?

    var requiresAttention: Bool {
        severity == .critical || severity == .attention || severity == .review
    }
}

struct IslandAttentionState: Equatable {
    let generatedAt: Date
    let displayedItems: [IslandAttentionItem]
    let totalAttentionCount: Int
    let activeSessionCount: Int
    let monitorFailed: Bool

    var hasAttention: Bool { totalAttentionCount > 0 }

    var compactTitle: String {
        if totalAttentionCount == 1 { return "1 needs attention" }
        if totalAttentionCount > 1 { return "\(totalAttentionCount) need attention" }
        return activeSessionCount > 0 ? "Running quietly" : "All quiet"
    }

    var compactDetail: String {
        if let first = displayedItems.first {
            return first.title
        }
        if monitorFailed {
            return "Monitor temporarily unavailable"
        }
        return activeSessionCount > 0 ? "No action needed" : "No active work needs you"
    }

    static func empty(activeSessionCount: Int = 0) -> IslandAttentionState {
        IslandAttentionState(
            generatedAt: Date(),
            displayedItems: [],
            totalAttentionCount: 0,
            activeSessionCount: activeSessionCount,
            monitorFailed: false
        )
    }
}

enum IslandAttentionBuilder {
    static func build(
        sessions: [PluginSession],
        maxDisplayedItems: Int = 3,
        monitorItemsProvider: () throws -> [PlannerMonitorItem]
    ) -> IslandAttentionState {
        let monitorItems: [PlannerMonitorItem]
        let monitorFailed: Bool
        do {
            monitorItems = try monitorItemsProvider()
            monitorFailed = false
        } catch {
            monitorItems = []
            monitorFailed = true
        }
        return build(
            sessions: sessions,
            monitorItems: monitorItems,
            monitorFailed: monitorFailed,
            maxDisplayedItems: maxDisplayedItems
        )
    }

    static func build(
        sessions: [PluginSession],
        monitorItems: [PlannerMonitorItem],
        monitorFailed: Bool = false,
        maxDisplayedItems: Int = 3
    ) -> IslandAttentionState {
        _ = maxDisplayedItems
        let sessionItems = sessions.compactMap(sessionAttentionItem)
        let monitorAttentionItems = monitorItems.compactMap(monitorAttentionItem)
        let allItems = (sessionItems + monitorAttentionItems)
            .filter(\.requiresAttention)
            .sorted(by: sortAttentionItems)
        return IslandAttentionState(
            generatedAt: Date(),
            displayedItems: allItems,
            totalAttentionCount: allItems.count,
            activeSessionCount: sessions.filter { !$0.status.isHistorical }.count,
            monitorFailed: monitorFailed
        )
    }

    private static func sessionAttentionItem(_ session: PluginSession) -> IslandAttentionItem? {
        guard let event = session.urgentEvent else { return nil }
        let isPermission = event.eventType == "permission"
        let title = isPermission ? "Permission required" : "Needs attention"
        return IslandAttentionItem(
            id: "session-\(session.id)-\(event.id)",
            source: isPermission ? .permission : .urgent,
            severity: isPermission ? .critical : .attention,
            title: title,
            subtitle: session.title,
            detail: event.message,
            canvasId: nil,
            nodeId: nil,
            deliveryId: nil,
            proposalId: nil,
            sessionId: session.id,
            eventId: event.id
        )
    }

    private static func monitorAttentionItem(_ item: PlannerMonitorItem) -> IslandAttentionItem? {
        guard let severity = monitorSeverity(for: item) else { return nil }
        let title: String
        let source: IslandAttentionSource
        if item.proposalStatus == .pending {
            title = "Proposal needs review"
            source = .proposal
        } else if item.needsOwnerReview {
            title = "Owner review needed"
            source = item.nodeId == nil ? .canvas : .node
        } else if item.runState == .blocked || !item.blockers.isEmpty || item.riskRank <= 0 {
            title = "Blocked work"
            source = item.nodeId == nil ? .canvas : .node
        } else {
            title = "Work needs attention"
            source = item.nodeId == nil ? .canvas : .node
        }
        return IslandAttentionItem(
            id: "monitor-\(item.id)",
            source: source,
            severity: severity,
            title: title,
            subtitle: item.nodeTitle ?? item.summary,
            detail: item.blockers.first ?? item.nextAction,
            canvasId: item.canvasId,
            nodeId: item.nodeId,
            deliveryId: item.deliveryId,
            proposalId: item.proposalId,
            sessionId: item.sessionId,
            eventId: nil
        )
    }

    private static func monitorSeverity(for item: PlannerMonitorItem) -> IslandAttentionSeverity? {
        if item.runState == .blocked || !item.blockers.isEmpty || item.riskRank <= 0 {
            return .attention
        }
        if item.needsOwnerReview || item.proposalStatus == .pending {
            return .review
        }
        if item.runState == .working && item.riskRank <= 2 {
            return .running
        }
        return nil
    }

    private static func sortAttentionItems(_ lhs: IslandAttentionItem, _ rhs: IslandAttentionItem) -> Bool {
        if lhs.severity != rhs.severity { return lhs.severity < rhs.severity }
        if lhs.title != rhs.title { return lhs.title < rhs.title }
        return lhs.subtitle < rhs.subtitle
    }
}
