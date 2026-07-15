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
        XCTAssertTrue(research.schema.outputs.contains("gsheet://venture-tracker"))
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

    func testApplyRequiresExplicitApprovalBeforeAnyCanvasMutation() throws {
        let proposal = try makeStore().create(
            requirement: "Build a tracker",
            blueprint: blueprint(),
            idempotencyKey: nil
        )
        XCTAssertThrowsError(try WorkflowProvisioner.apply(
            proposal: proposal,
            explicitlyApproved: false
        )) { error in
            XCTAssertEqual(error as? WorkflowProvisioningError, .approvalRequired)
        }
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
