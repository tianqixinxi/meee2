import Foundation
import Meee2CommKit

final class PlannerScheduleRunner {
    static let shared = PlannerScheduleRunner()

    private let queue = DispatchQueue(label: "com.meee2.planner-schedule-runner", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let tickSeconds: TimeInterval = 15

    private init() {}

    func start() {
        queue.async {
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.tickSeconds, repeating: self.tickSeconds)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
        }
    }

    func tick(now: Date = Date()) {
        let due = PlannerBoardBridge.store.dueScheduledNodes(now: now)
        guard !due.isEmpty else { return }
        for item in due {
            var createdRunId: String?
            do {
                let session = try BoardAPI.materializeScheduledPlannerNodeSession(
                    canvasId: item.canvasId,
                    nodeId: item.nodeId,
                    schedulePrompt: item.prompt
                )
                let existingRuns = try PlannerBoardBridge.store.runs(canvasId: item.canvasId)
                if existingRuns.last?.status != .active {
                    let run = try PlannerBoardBridge.store.startRun(
                        canvasId: item.canvasId,
                        trigger: "schedule:\(item.nodeId)",
                        title: "Scheduled · \(item.title)",
                        summary: "Recurring workflow tick",
                        responsibleUserId: nil,
                        linkedArtifactRefs: []
                    )
                    createdRunId = run.id
                }
                if !session.initialPromptIncludesSchedule {
                    try send(item, sessionId: session.sessionId)
                }
                _ = try PlannerBoardBridge.store.markScheduledTickSent(
                    canvasId: item.canvasId,
                    nodeId: item.nodeId,
                    sentAt: now
                )
                BoardServer.shared.broadcastStateChanged()
            } catch {
                if let createdRunId {
                    _ = try? PlannerBoardBridge.store.abortRun(runId: createdRunId)
                }
                _ = try? PlannerBoardBridge.store.markScheduledTickFailed(
                    canvasId: item.canvasId,
                    nodeId: item.nodeId,
                    error: error.localizedDescription,
                    attemptedAt: now
                )
                let session = item.sessionId.map { String($0.prefix(8)) } ?? "unbound"
                MWarn("[PlannerScheduleRunner] schedule tick failed canvas=\(item.canvasId) node=\(item.nodeId) sid=\(session): \(error.localizedDescription)")
            }
        }
    }

    private func send(_ item: PlannerStore.DueScheduledNode, sessionId: String) throws {
        let content = [
            item.prompt,
            "",
            "Schedule context:",
            "- canvasId: \(item.canvasId)",
            "- nodeId: \(item.nodeId)",
            "- intervalSeconds: \(item.intervalSeconds)"
        ].joined(separator: "\n")
        let channelName = try MessageRouter.shared.ensureOperatorChannel(sessionId: sessionId)
        _ = try MessageRouter.shared.send(
            channel: channelName,
            fromAlias: "operator",
            toAlias: "session",
            content: content,
            injectedByHuman: false
        )
    }
}
