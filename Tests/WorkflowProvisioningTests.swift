import XCTest
@testable import meee2Kit

final class WorkflowProvisioningTests: XCTestCase {
    func testProposalCreationIsIdempotentAndRevisionUsesOptimisticVersion() throws {
        let store = makeStore()
        let first = try store.create(
            requirement: "Build a venture research tracker",
            blueprint: blueprint(),
            idempotencyKey: "venture-research-v1"
        )
        let retry = try store.create(
            requirement: "A retry must not duplicate this",
            blueprint: blueprint(name: "Ignored retry"),
            idempotencyKey: "venture-research-v1"
        )
        XCTAssertEqual(retry.id, first.id)
        XCTAssertEqual(retry.requirement, first.requirement)

        let revised = try store.revise(
            id: first.id,
            requirement: "Build the approved venture tracker",
            blueprint: blueprint(name: "Venture Tracker v2"),
            expectedVersion: 1
        )
        XCTAssertEqual(revised.version, 2)
        XCTAssertEqual(revised.blueprint.name, "Venture Tracker v2")

        XCTAssertThrowsError(try store.revise(
            id: first.id,
            requirement: "stale edit",
            blueprint: nil,
            expectedVersion: 1
        )) { error in
            XCTAssertEqual(
                error as? WorkflowProvisioningError,
                .validation("proposal version conflict: expected 1, current 2")
            )
        }
    }

    func testBlueprintValidationRejectsCyclesAndDuplicateSchedules() throws {
        var cyclic = blueprint()
        cyclic.steps[0].dependsOn = ["research"]
        XCTAssertThrowsError(try WorkflowProposalStore.normalized(cyclic)) { error in
            XCTAssertTrue(error.localizedDescription.contains("dependency cycle"))
        }

        var duplicateSchedule = blueprint()
        duplicateSchedule.schedules.append(WorkflowBlueprintSchedule(
            id: "daily-duplicate",
            nodeId: "research",
            cadence: "daily",
            intervalMinutes: nil,
            timeZone: "Asia/Shanghai",
            hour: 11,
            minute: 0,
            dayOfMonth: nil,
            prompt: "Duplicate"
        ))
        XCTAssertThrowsError(try WorkflowProposalStore.normalized(duplicateSchedule)) { error in
            XCTAssertTrue(error.localizedDescription.contains("only one schedule"))
        }

        var humanSchedule = blueprint()
        humanSchedule.steps[1].runtime = "human"
        XCTAssertThrowsError(try WorkflowProposalStore.normalized(humanSchedule)) { error in
            XCTAssertTrue(error.localizedDescription.contains("claude or codex"))
        }
    }

    func testBlueprintNormalizationMakesCalendarDefaultsExplicit() throws {
        var raw = blueprint()
        raw.schedules[0].timeZone = nil
        raw.schedules[0].hour = nil
        raw.schedules[0].minute = nil
        raw.steps[1].requiresApproval = false
        raw.integrationPolicies = nil
        let normalized = try WorkflowProposalStore.normalized(raw)
        let schedule = try XCTUnwrap(normalized.schedules.first)
        XCTAssertNotNil(schedule.timeZone)
        XCTAssertEqual(schedule.hour, 9)
        XCTAssertEqual(schedule.minute, 0)
        XCTAssertEqual(normalized.trackers[0].fieldPolicies["status"], "ai_suggest")
        XCTAssertTrue(normalized.steps[1].requiresApproval)
        XCTAssertEqual(normalized.integrationPolicies?["google-sheets"], "read_only")
        XCTAssertEqual(normalized.integrationPolicies?["outlook-email"], "read_only")
    }

    func testMaterializationPreservesTrackerContractApprovalAndDisabledSchedule() throws {
        let normalized = try WorkflowProposalStore.normalized(blueprint())
        let nodes = WorkflowProvisioner.materializeNodes(
            blueprint: normalized,
            canvasId: "canvas-vc",
            ownerId: "partner"
        )
        XCTAssertEqual(nodes.count, 2)

        let source = try XCTUnwrap(nodes.first { $0.id == "canvas-vc-wf-source" })
        let research = try XCTUnwrap(nodes.first { $0.id == "canvas-vc-wf-research" })
        XCTAssertEqual(research.dependsOnNodeIds, [source.id])
        XCTAssertEqual(research.contextSources.map(\.reference), ["gsheet://venture-tracker"])
        XCTAssertTrue(research.contextSources[0].title.contains("financial=human_only"))
        XCTAssertTrue(research.schema.outputs.contains("workflow-draft://venture-tracker"))
        XCTAssertEqual(research.workflowPolicy?.externalWriteMode, .prohibited)
        let contract = NodeContractV2.derive(from: research).contract
        XCTAssertNil(contract.output.externalWriteTarget)
        XCTAssertEqual(contract.output.externalWriteMode, .prohibited)
        XCTAssertEqual(contract.output.fieldPolicies?["financial"], "human_only")
        XCTAssertTrue(research.schema.goal.contains("outlook-email=read_only"))
        XCTAssertEqual(research.handoffPolicy, .anyApprover)
        XCTAssertEqual(research.approverIds, ["partner"])
        XCTAssertEqual(research.schedule?.cadence, .daily)
        XCTAssertEqual(research.schedule?.timeZoneIdentifier, "Asia/Shanghai")
        XCTAssertEqual(research.schedule?.enabled, false)
        XCTAssertNil(research.schedule?.nextRunAt)
    }

    func testDailyAndMonthlyCalendarCadence() throws {
        let daily = PlannerNodeSchedule(
            enabled: true,
            intervalSeconds: 86_400,
            prompt: "Daily overview",
            cadence: .daily,
            timeZoneIdentifier: "UTC",
            hour: 9,
            minute: 30
        )
        XCTAssertEqual(
            daily.nextOccurrence(after: date(2024, 1, 1, 10, 0)),
            date(2024, 1, 2, 9, 30)
        )

        let monthly = PlannerNodeSchedule(
            enabled: true,
            intervalSeconds: 2_678_400,
            prompt: "Monthly market research",
            cadence: .monthly,
            timeZoneIdentifier: "UTC",
            hour: 9,
            minute: 0,
            dayOfMonth: 31
        )
        XCTAssertEqual(
            monthly.nextOccurrence(after: date(2024, 1, 31, 10, 0)),
            date(2024, 2, 29, 9, 0)
        )
    }

    func testUnboundScheduledNodeIsDueSoRunnerCanMaterializeItsFirstSession() throws {
        let canvasId = "scheduled-\(UUID().uuidString.lowercased())"
        let nodeId = "\(canvasId)-node"
        let node = PlanningNode(
            id: nodeId,
            canvasId: canvasId,
            title: "Daily overview",
            schema: NodeSchema(inputs: [], outputs: ["overview"], goal: "Refresh overview"),
            contextSources: [],
            executionMode: .auto,
            executorType: .claude,
            doerId: "owner",
            status: .ready,
            schedule: PlannerNodeSchedule(
                enabled: true,
                intervalSeconds: 60,
                prompt: "Refresh now",
                nextRunAt: Date(timeIntervalSince1970: 1)
            )
        )
        _ = try PlannerBoardBridge.store.record(
            for: PlanningCanvas(
                id: canvasId,
                ownerId: "owner",
                title: "Scheduled",
                plannerContext: "test"
            ),
            seedNodes: [node]
        )
        let due = PlannerBoardBridge.store.dueScheduledNodes(now: Date())
        let item = try XCTUnwrap(due.first { $0.nodeId == nodeId })
        XCTAssertNil(item.sessionId)
    }

    func testApplyRequiresDurableHumanApprovalRequest() throws {
        let proposal = try makeStore().create(
            requirement: "Build a tracker",
            blueprint: blueprint(),
            idempotencyKey: nil
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meee2-workflow-approval-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let approvals = WorkflowApprovalStore(fileURL: directory.appendingPathComponent("approvals.json"))
        let first = try approvals.request(action: .apply, proposal: proposal, actorId: "owner")
        let retry = try approvals.request(action: .apply, proposal: proposal, actorId: "owner")
        XCTAssertEqual(first.id, retry.id)
        XCTAssertEqual(first.status, .pending)
        XCTAssertEqual(try approvals.list(), [first])
        XCTAssertThrowsError(try approvals.beginResolution(
            id: first.id, approved: true, actorId: "different-user"
        ))
    }

    func testScheduledTickStaysRunningAfterVerifiedDelivery() throws {
        let canvasId = "scheduled-running-\(UUID().uuidString.lowercased())"
        let nodeId = "\(canvasId)-node"
        let node = PlanningNode(
            id: nodeId,
            canvasId: canvasId,
            title: "Daily overview",
            schema: NodeSchema(inputs: [], outputs: ["overview"], goal: "Refresh overview"),
            contextSources: [],
            executionMode: .auto,
            executorType: .claude,
            doerId: "owner",
            status: .ready,
            schedule: PlannerNodeSchedule(
                enabled: true,
                intervalSeconds: 60,
                prompt: "Refresh now",
                nextRunAt: Date(timeIntervalSince1970: 1)
            )
        )
        _ = try PlannerBoardBridge.store.record(
            for: PlanningCanvas(id: canvasId, ownerId: "owner", title: "Scheduled", plannerContext: "test"),
            seedNodes: [node]
        )
        let record = try PlannerBoardBridge.store.markScheduledTickSent(
            canvasId: canvasId, nodeId: nodeId, sentAt: Date()
        )
        let updated = try XCTUnwrap(record.nodes.first { $0.id == nodeId })
        XCTAssertEqual(updated.workflowRunState, .running)
        XCTAssertNotNil(updated.schedule?.lastSentAt)
        XCTAssertNotNil(updated.schedule?.nextRunAt)
    }

    func testScheduledFailureRecordsBoundedRetryState() throws {
        let canvasId = "scheduled-retry-\(UUID().uuidString.lowercased())"
        let nodeId = "\(canvasId)-node"
        let attemptedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let node = PlanningNode(
            id: nodeId,
            canvasId: canvasId,
            title: "Daily overview",
            schema: NodeSchema(inputs: [], outputs: ["overview"], goal: "Refresh overview"),
            contextSources: [],
            executionMode: .auto,
            executorType: .claude,
            doerId: "owner",
            status: .ready,
            schedule: PlannerNodeSchedule(
                enabled: true,
                intervalSeconds: 60,
                prompt: "Refresh now",
                nextRunAt: attemptedAt
            )
        )
        _ = try PlannerBoardBridge.store.record(
            for: PlanningCanvas(id: canvasId, ownerId: "owner", title: "Scheduled", plannerContext: "test"),
            seedNodes: [node]
        )

        let first = try PlannerBoardBridge.store.markScheduledTickFailed(
            canvasId: canvasId,
            nodeId: nodeId,
            error: "session unavailable",
            attemptedAt: attemptedAt
        )
        let firstNode = try XCTUnwrap(first.nodes.first { $0.id == nodeId })
        XCTAssertEqual(firstNode.workflowRunState, .failed)
        XCTAssertEqual(firstNode.schedule?.consecutiveFailures, 1)
        XCTAssertEqual(firstNode.schedule?.lastError, "session unavailable")
        XCTAssertEqual(firstNode.schedule?.retryAt, attemptedAt.addingTimeInterval(15))
        XCTAssertTrue(PlannerBoardBridge.store.dueScheduledNodes(now: attemptedAt).allSatisfy { $0.nodeId != nodeId })
        XCTAssertTrue(PlannerBoardBridge.store.dueScheduledNodes(now: attemptedAt.addingTimeInterval(15)).contains { $0.nodeId == nodeId })
    }

    func testProtectedTrackerOutputRejectsDirectWriteAndHumanOnlyFields() throws {
        let canvasId = "protected-tracker-\(UUID().uuidString.lowercased())"
        let normalized = try WorkflowProposalStore.normalized(blueprint())
        let nodes = WorkflowProvisioner.materializeNodes(
            blueprint: normalized,
            canvasId: canvasId,
            ownerId: "owner"
        )
        let node = try XCTUnwrap(nodes.first { $0.id == "\(canvasId)-wf-research" })
        _ = try PlannerBoardBridge.store.record(
            for: PlanningCanvas(id: canvasId, ownerId: "owner", title: "Protected", plannerContext: "test"),
            seedNodes: nodes
        )

        XCTAssertThrowsError(try PlannerBoardBridge.store.submitNodeOutput(
            canvasId: canvasId,
            nodeId: node.id,
            output: PlannerNodeOutput(
                nodeId: node.id,
                status: .done,
                message: PlannerNodeOutputMessage(summary: "Direct write", routeTo: ["owner"]),
                artifacts: [PlannerNodeOutputArtifact(
                    kind: .generic,
                    title: "Tracker",
                    reference: "gsheet://venture-tracker",
                    payload: nil,
                    routeTo: ["owner"]
                )],
                next: .complete
            )
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("not authorized"))
        }

        XCTAssertThrowsError(try PlannerBoardBridge.store.submitNodeOutput(
            canvasId: canvasId,
            nodeId: node.id,
            output: PlannerNodeOutput(
                nodeId: node.id,
                status: .done,
                message: PlannerNodeOutputMessage(summary: "Draft write", routeTo: ["owner"]),
                artifacts: [PlannerNodeOutputArtifact(
                    kind: .generic,
                    title: "Draft",
                    reference: "workflow-draft://venture-tracker",
                    payload: .object(["fields": .object(["financial": .string("Series A")])]),
                    routeTo: ["owner"]
                )],
                next: .complete
            )
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("human_only"))
        }
    }

    func testCorruptProposalStoreFailsClosedAndPreservesBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meee2-workflow-corrupt-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("proposals.json")
        let corrupt = Data(#"{"proposals":["#.utf8)
        try corrupt.write(to: url)
        let store = WorkflowProposalStore(fileURL: url)

        XCTAssertThrowsError(try store.create(
            requirement: "must not overwrite",
            blueprint: blueprint(),
            idempotencyKey: nil
        )) { error in
            guard case .storeCorrupted = error as? WorkflowProvisioningError else {
                return XCTFail("expected storeCorrupted, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    private func makeStore() -> WorkflowProposalStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meee2-workflow-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return WorkflowProposalStore(fileURL: directory.appendingPathComponent("proposals.json"))
    }

    private func blueprint(name: String = "Venture Research") -> WorkflowBlueprint {
        WorkflowBlueprint(
            name: name,
            summary: "Source, research, and track startups.",
            scope: "team",
            steps: [
                WorkflowBlueprintStep(
                    id: "source",
                    title: "Source startups",
                    goal: "Create a verified startup list.",
                    dependsOn: [],
                    inputs: ["industry"],
                    outputs: ["startup-list"],
                    runtime: "claude",
                    ownerId: nil,
                    reviewerIds: [],
                    approverIds: [],
                    requiresApproval: false
                ),
                WorkflowBlueprintStep(
                    id: "research",
                    title: "Research and update tracker",
                    goal: "Write verified technical research into the shared tracker.",
                    dependsOn: ["source"],
                    inputs: ["startup-list"],
                    outputs: ["research-summary"],
                    runtime: "claude",
                    ownerId: nil,
                    reviewerIds: [],
                    approverIds: [],
                    requiresApproval: true
                ),
            ],
            trackers: [
                WorkflowBlueprintTracker(
                    id: "venture-tracker",
                    title: "Venture Tracker",
                    connector: "google-sheets",
                    reference: "gsheet://venture-tracker",
                    tabs: [
                        WorkflowBlueprintTrackerTab(
                            id: "basic-info",
                            title: "Basic Info",
                            columns: ["status", "owner", "financial"]
                        ),
                        WorkflowBlueprintTrackerTab(
                            id: "research",
                            title: "Research",
                            columns: ["core approach", "advantage", "limitation"]
                        ),
                    ],
                    readerStepIds: ["research"],
                    writerStepIds: ["research"],
                    fieldPolicies: [
                        "financial": "human_only",
                        "core approach": "ai_suggest",
                    ]
                ),
            ],
            schedules: [
                WorkflowBlueprintSchedule(
                    id: "daily-overview",
                    nodeId: "research",
                    cadence: "daily",
                    intervalMinutes: nil,
                    timeZone: "Asia/Shanghai",
                    hour: 9,
                    minute: 0,
                    dayOfMonth: nil,
                    prompt: "Refresh today's overview without sending email."
                ),
            ],
            integrations: ["google-sheets", "outlook-email"],
            integrationPolicies: [
                "google-sheets": "write",
                "outlook-email": "read_only",
            ]
        )
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }
}
