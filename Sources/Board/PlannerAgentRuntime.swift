import Foundation

// Phase 8 planner-graph: a swappable **agent runtime** that sits *above* the
// Phase 1 `PlannerAdapter`.
//
// Where `PlannerAdapter` is a one-shot "graph context + goal → PlanProposal"
// translator, the `PlannerAgentRuntime` is the policy layer: it decides, given
// a planner *event* and the current graph state, *whether* to act and *what*
// proposals to produce. It never persists, never approves, never applies — it
// only ever returns pending `PlanProposal`s for the human approval gate.
//
// The seam is deliberately single-point: `PlannerAgentRuntimeRegistry.shared`.
// A user replacing meee2's planner with their own evolution engine swaps the
// whole runtime in one line; nothing else in the planner surface needs to
// change.

// MARK: - Events

/// The inputs a planner agent runtime reacts to.
///
/// Each case carries the `canvasId` it pertains to so a replacement runtime can
/// be canvas-aware without re-deriving it.
enum PlannerAgentEvent: Equatable {
    /// The owner asked the planner to (re)generate a plan from a goal.
    case userGoal(canvasId: String, goal: String, context: String?)
    /// A drift inspection was requested for a canvas (manual or scheduled).
    case driftInspection(canvasId: String)
    /// A planner node's workflow run-state changed (e.g. a bound session moved
    /// `running → failed`). Emitted from the Phase 2 run-state feedback path.
    case nodeRunStateChanged(canvasId: String, nodeId: String, runState: PlannerWorkflowRunState)
    /// A milestone node completed — the hook for rolling-milestone expansion.
    case milestoneCompleted(canvasId: String, nodeId: String)

    /// The canvas this event pertains to.
    var canvasId: String {
        switch self {
        case .userGoal(let canvasId, _, _):
            return canvasId
        case .driftInspection(let canvasId):
            return canvasId
        case .nodeRunStateChanged(let canvasId, _, _):
            return canvasId
        case .milestoneCompleted(let canvasId, _):
            return canvasId
        }
    }
}

// MARK: - Outcome

/// The result of a runtime handling one `PlannerAgentEvent`.
///
/// Every proposal in `proposals` is `pending` — the runtime never approves or
/// applies. When the runtime decides nothing is needed it returns an *empty*
/// `proposals` list and sets `noActionReason` to a human-readable explanation.
struct PlannerAgentOutcome: Equatable {
    /// Pending proposals produced by the runtime (may be empty).
    var proposals: [PlanProposal]
    /// Why the runtime produced these proposals (for logs / UI).
    var rationale: String?
    /// Risks the runtime wants a human to weigh before approving.
    var risks: [String]
    /// Set (with empty `proposals`) when the runtime decided no action is
    /// needed — e.g. a healthy graph or a non-failure run-state change.
    var noActionReason: String?

    init(
        proposals: [PlanProposal] = [],
        rationale: String? = nil,
        risks: [String] = [],
        noActionReason: String? = nil
    ) {
        self.proposals = proposals
        self.rationale = rationale
        self.risks = risks
        self.noActionReason = noActionReason
    }

    /// Convenience: a "did nothing, here's why" outcome.
    static func noAction(_ reason: String) -> PlannerAgentOutcome {
        PlannerAgentOutcome(proposals: [], noActionReason: reason)
    }
}

// MARK: - Runtime protocol

/// The swappable planner agent runtime.
///
/// One async entry point: react to a `PlannerAgentEvent` against a
/// `PlannerGraphState`, using the same `AssistantSettings` the Phase 1 adapter
/// consumes. Implementations MUST only ever produce `pending` proposals — the
/// human approval gate is not optional.
protocol PlannerAgentRuntime {
    func handle(
        _ event: PlannerAgentEvent,
        state: PlannerGraphState,
        settings: AssistantSettings
    ) async throws -> PlannerAgentOutcome
}

// MARK: - Default implementation

/// The DEFAULT planner agent runtime.
///
/// Design contract — read before replacing:
/// - **No autonomous loop.** This runtime is purely *event-triggered*: it acts
///   only when `handle(_:state:settings:)` is called. It never schedules
///   itself, never polls, never runs in the background.
/// - **Proposals only, never applies.** Every outcome contains `pending`
///   proposals (or `noActionReason`). The runtime never approves or applies a
///   proposal — the human approval gate stays in full force.
/// - **Conservative on run-state.** A `.nodeRunStateChanged` event only yields
///   a proposal for an outright failure/blocked state; everything else is a
///   `noActionReason`.
/// - **Expected to be replaced.** This implementation is intentionally minimal.
///   A user bringing their own evolution engine swaps it in via
///   `PlannerAgentRuntimeRegistry.shared`; `.milestoneCompleted` in particular
///   is a no-op here precisely so a replacement runtime can own rolling
///   milestone expansion.
final class DefaultPlannerAgentRuntime: PlannerAgentRuntime {
    /// Builds the Phase 1 adapter for a given settings object. Injectable so
    /// tests can substitute a `FakeAssistantProvider`-backed adapter.
    private let adapterFactory: (AssistantSettings) -> PlannerAdapter

    /// Default: a real `BYOAPlannerAdapter`.
    init() {
        self.adapterFactory = { settings in BYOAPlannerAdapter(settings: settings) }
    }

    /// Test / advanced seam: inject an adapter factory.
    init(adapterFactory: @escaping (AssistantSettings) -> PlannerAdapter) {
        self.adapterFactory = adapterFactory
    }

    func handle(
        _ event: PlannerAgentEvent,
        state: PlannerGraphState,
        settings: AssistantSettings
    ) async throws -> PlannerAgentOutcome {
        switch event {
        case .userGoal(_, let goal, let context):
            return try await handleUserGoal(goal: goal, context: context, state: state, settings: settings)
        case .driftInspection:
            return handleDriftInspection(state: state)
        case .nodeRunStateChanged(_, let nodeId, let runState):
            return try await handleNodeRunStateChanged(
                nodeId: nodeId,
                runState: runState,
                state: state,
                settings: settings
            )
        case .milestoneCompleted:
            // Deliberately minimal: rolling-milestone expansion is left for a
            // replacement runtime. The event exists so that replacement can
            // implement it without changing this protocol.
            return .noAction("milestone evolution not yet implemented in DefaultPlannerAgentRuntime")
        }
    }

    // MARK: .userGoal

    /// Delegate to the Phase 1 adapter; on adapter/provider failure fall back to
    /// the heuristic proposal — the same graceful-degradation behavior the
    /// `generatePlannerProposal` HTTP handler already had.
    private func handleUserGoal(
        goal: String,
        context: String?,
        state: PlannerGraphState,
        settings: AssistantSettings
    ) async throws -> PlannerAgentOutcome {
        let adapter = adapterFactory(settings)
        // Fold any extra context into the goal so the adapter prompt sees it
        // without widening the Phase 1 adapter signature.
        let effectiveGoal: String = {
            guard let context, !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return goal
            }
            return goal.isEmpty ? context : "\(goal)\n\nContext:\n\(context)"
        }()
        if let proposal = targetedNodeRevisionProposal(goal: effectiveGoal, state: state) {
            return PlannerAgentOutcome(
                proposals: [proposal],
                rationale: "Converted an explicit node revision into a focused updateNode proposal."
            )
        }
        if let proposal = workflowProposal(goal: effectiveGoal, state: state) {
            return PlannerAgentOutcome(
                proposals: [proposal],
                rationale: "Parsed an explicit workflow chain from the owner goal."
            )
        }
        if let proposal = explicitNodeProposal(goal: effectiveGoal, state: state) {
            return PlannerAgentOutcome(
                proposals: [proposal],
                rationale: "Parsed an explicit node contract from the owner goal."
            )
        }
        do {
            let proposal = try await adapter.generateProposal(for: state, goal: effectiveGoal)
            return PlannerAgentOutcome(
                proposals: [proposal],
                rationale: "Generated a plan from the owner goal via the planner adapter."
            )
        } catch let error as PlannerCoreError {
            // Validation / RBAC failures are real client errors — surface them.
            throw error
        } catch {
            // Provider / CLI unavailable — fall back to the heuristic proposal.
            let fallback = heuristicProposal(goal: goal, state: state)
            return PlannerAgentOutcome(
                proposals: [fallback],
                rationale: "Planner adapter unavailable (\(error.localizedDescription)); produced a heuristic proposal instead.",
                risks: ["Proposal was generated by the offline heuristic, not an LLM — review it carefully."]
            )
        }
    }

    private func targetedNodeRevisionProposal(goal: String, state: PlannerGraphState) -> PlanProposal? {
        guard goal.localizedCaseInsensitiveContains("#revise"),
              let nodeId = taggedNodeId(in: goal),
              let node = state.nodes.first(where: { $0.id == nodeId }) else {
            return nil
        }
        let normalizedGoal = goal.lowercased()
        guard normalizedGoal.contains("html") else { return nil }

        let outputs = node.schema.outputs.isEmpty
            ? ["html_file"]
            : node.schema.outputs.map(htmlArtifactName)
        let schema = NodeSchema(
            inputs: node.schema.inputs,
            outputs: dedupeStrings(outputs),
            goal: htmlRevisionGoal(node.schema.goal)
        )
        return PlanProposal(
            id: "proposal-\(node.canvasId)-revise-\(node.id)-\(UUID().uuidString.lowercased())",
            canvasId: node.canvasId,
            summary: "Revise \(node.title) to output HTML",
            changes: [
                .updateNode(id: node.id, status: .draft, schema: schema)
            ],
            status: .pending
        )
    }

    private func taggedNodeId(in value: String) -> String? {
        guard let range = value.range(of: "@node:") else { return nil }
        let tail = value[range.upperBound...]
        let id = tail.prefix { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
        }
        let result = String(id).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private func htmlArtifactName(_ value: String) -> String {
        let slugged = slug(value).replacingOccurrences(of: "-", with: "_")
        guard !slugged.isEmpty else { return "html_file" }
        if slugged.contains("html") { return slugged }
        return "\(slugged)_html"
    }

    private func htmlRevisionGoal(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().contains("html") {
            return trimmed.isEmpty ? "Produce an HTML artifact." : trimmed
        }
        if trimmed.isEmpty {
            return "Produce an HTML artifact."
        }
        return "\(trimmed). Produce an HTML artifact instead of plain text."
    }

    private func dedupeStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            result.append(normalized)
        }
        return result
    }

    // MARK: .driftInspection

    /// Reuse the existing drift heuristic: produce a corrective proposal for the
    /// first blocked node, or `noActionReason` if the graph is
    /// healthy.
    private func handleDriftInspection(state: PlannerGraphState) -> PlannerAgentOutcome {
        guard let blocked = state.states.first(where: { $0.runState == .blocked }),
              let node = state.nodes.first(where: { $0.id == blocked.nodeId }) else {
            return .noAction("planner graph is healthy — no blocked nodes")
        }
        let proposal = PlanProposal(
            id: "proposal-\(node.id)-drift-\(UUID().uuidString.lowercased())",
            canvasId: node.canvasId,
            summary: "meee2 AI detected drift for \(node.title)",
            changes: [
                .updateNode(id: node.id, title: "\(node.title) (needs attention)", status: .draft)
            ],
            status: .pending
        )
        return PlannerAgentOutcome(
            proposals: [proposal],
            rationale: "Node \(node.id) is blocked; proposed moving it back to draft for replanning."
        )
    }

    // MARK: .nodeRunStateChanged

    /// CONSERVATIVE: only act on an outright failure/blocked run-state. For any
    /// other state, return a `noActionReason` — the runtime never reacts to
    /// healthy progress. When it does act, it produces exactly ONE pending
    /// corrective proposal via the adapter, prompted with the failed node.
    private func handleNodeRunStateChanged(
        nodeId: String,
        runState: PlannerWorkflowRunState,
        state: PlannerGraphState,
        settings: AssistantSettings
    ) async throws -> PlannerAgentOutcome {
        guard runState == .failed else {
            return .noAction("run-state \(runState.rawValue) is not a failure — no corrective action needed")
        }
        guard let node = state.nodes.first(where: { $0.id == nodeId }) else {
            return .noAction("run-state change references unknown node \(nodeId)")
        }
        let correctiveGoal = """
        Node "\(node.title)" (id: \(node.id)) reported run-state "failed".
        Propose ONE small corrective change to recover this node — e.g. retry, \
        rescope, or flag it for human diagnosis. Keep the proposal pending.
        """
        let adapter = adapterFactory(settings)
        do {
            let proposal = try await adapter.generateProposal(for: state, goal: correctiveGoal)
            return PlannerAgentOutcome(
                proposals: [proposal],
                rationale: "Node \(node.id) failed; proposed a corrective change via the planner adapter.",
                risks: ["Corrective proposal — review before approving; the failure may need a human diagnosis."]
            )
        } catch let error as PlannerCoreError {
            throw error
        } catch {
            // Adapter unavailable — fall back to a heuristic "flag for review"
            // proposal so a failure is never silently dropped.
            let fallback = PlanProposal(
                id: "proposal-\(node.id)-runstate-\(UUID().uuidString.lowercased())",
                canvasId: node.canvasId,
                summary: "meee2 AI flagged \(node.title) after a run failure",
                changes: [
                    .updateNode(id: node.id, title: "\(node.title) (failed — needs attention)", status: .draft)
                ],
                status: .pending
            )
            return PlannerAgentOutcome(
                proposals: [fallback],
                rationale: "Node \(node.id) failed; planner adapter unavailable (\(error.localizedDescription)), flagged the node for replanning instead.",
                risks: ["Heuristic fallback — the failed node needs human diagnosis."]
            )
        }
    }

    // MARK: Heuristic fallback

    private func explicitNodeProposal(goal: String, state: PlannerGraphState) -> PlanProposal? {
        guard let spec = parseExplicitNodeSpec(goal) else { return nil }
        let canvas = state.canvas
        let proposalUUID = UUID().uuidString.lowercased()
        let schema = NodeSchema(
            inputs: spec.inputs,
            outputs: spec.outputs,
            goal: explicitNodeGoal(title: spec.title, inputs: spec.inputs, outputs: spec.outputs)
        )

        if let existing = state.nodes.first(where: { $0.title.caseInsensitiveCompare(spec.title) == .orderedSame }) {
            let changes: [PlanChange] = [
                .updateNode(id: existing.id, status: .draft, schema: schema)
            ] + kanbanArtifactChanges(for: spec, nodeId: existing.id)
            return PlanProposal(
                id: "proposal-\(canvas.id)-node-\(proposalUUID)",
                canvasId: canvas.id,
                summary: "Update \(existing.title) contract",
                changes: changes,
                status: .pending
            )
        }

        var existingIds = Set(state.nodes.map(\.id))
        let node = PlanningNode(
            id: uniqueNodeId(canvasId: canvas.id, title: spec.title, existingIds: &existingIds),
            canvasId: canvas.id,
            title: spec.title,
            schema: schema,
            contextSources: [],
            executionMode: .auto,
            executorType: .claude,
            doerId: canvas.ownerId,
            status: .ready,
            nodeKind: .step
        )
        let changes: [PlanChange] = [
            .addNode(node)
        ] + kanbanArtifactChanges(for: spec, nodeId: node.id)
        return PlanProposal(
            id: "proposal-\(canvas.id)-node-\(proposalUUID)",
            canvasId: canvas.id,
            summary: "Create \(spec.title)",
            changes: changes,
            status: .pending
        )
    }

    private struct ExplicitNodeSpec {
        var title: String
        var inputs: [String]
        var outputs: [String]
    }

    private func parseExplicitNodeSpec(_ goal: String) -> ExplicitNodeSpec? {
        let firstLine = goal
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !firstLine.isEmpty else { return nil }

        let pattern = #"^\s*(?:create|add)(?:\s+node)?\s*:\s*(.+?)\s*\(\s*input\s*=\s*([^,)]*)\s*,\s*output\s*=\s*([^)]+)\)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(firstLine.startIndex..<firstLine.endIndex, in: firstLine)
        guard let match = regex.firstMatch(in: firstLine, range: range), match.numberOfRanges == 4,
              let titleRange = Range(match.range(at: 1), in: firstLine),
              let inputRange = Range(match.range(at: 2), in: firstLine),
              let outputRange = Range(match.range(at: 3), in: firstLine) else {
            return nil
        }

        let title = String(firstLine[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let inputs = parseContractItems(String(firstLine[inputRange]))
        let outputs = parseContractItems(String(firstLine[outputRange]))
        guard !title.isEmpty, !inputs.isEmpty, !outputs.isEmpty else { return nil }
        return ExplicitNodeSpec(title: title, inputs: inputs, outputs: outputs)
    }

    private func parseContractItems(_ raw: String) -> [String] {
        dedupeStrings(
            raw
                .split(whereSeparator: { character in
                    character == "|" || character == ";" || character == "+"
                })
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        )
    }

    private func explicitNodeGoal(title: String, inputs: [String], outputs: [String]) -> String {
        let inputText = inputs.joined(separator: ", ")
        let outputText = outputs.joined(separator: ", ")
        return "\(displayTitle(title)) takes \(inputText) and produces \(outputText)."
    }

    private func kanbanArtifactChanges(for spec: ExplicitNodeSpec, nodeId: String) -> [PlanChange] {
        spec.outputs
            .filter { isKanbanLikeOutput($0) }
            .map { output in
                .attachArtifact(
                    nodeId: nodeId,
                    kind: .kanban,
                    title: output,
                    reference: output,
                    payload: defaultKanbanPayload(for: output, nodeTitle: spec.title)
                )
            }
    }

    private func isKanbanLikeOutput(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized.contains("kanban")
            || normalized.contains("看板")
            || normalized.contains("list")
            || normalized.contains("board")
    }

    private func defaultKanbanPayload(for output: String, nodeTitle: String) -> BoardJSONValue {
        let semanticText = "\(nodeTitle) \(output)".lowercased()
        let columnTitle: String
        if semanticText.contains("idea") || semanticText.contains("灵感") || semanticText.contains("想法") {
            columnTitle = "Idea list"
        } else if semanticText.contains("prd") {
            columnTitle = "PRD list"
        } else if semanticText.contains("release") {
            columnTitle = "Release list"
        } else {
            columnTitle = "Items"
        }
        let columnId = slug(columnTitle)
        return .object([
            "version": .number(1),
            "columns": .array([
                .object([
                    "id": .string(columnId),
                    "title": .string(columnTitle)
                ])
            ]),
            "items": .array([])
        ])
    }

    private func workflowProposal(goal: String, state: PlannerGraphState) -> PlanProposal? {
        guard let steps = parseWorkflowSteps(goal), steps.count >= 2 else { return nil }
        let canvas = state.canvas
        let proposalUUID = UUID().uuidString.lowercased()
        var existingIds = Set(state.nodes.map(\.id))
        var changes: [PlanChange] = []
        var previousId: String?
        var previousOutput: String?

        for (index, rawStep) in steps.enumerated() {
            let title = displayTitle(rawStep)
            let id = uniqueNodeId(canvasId: canvas.id, title: title, existingIds: &existingIds)
            let output = slug(title)
            let node = PlanningNode(
                id: id,
                canvasId: canvas.id,
                title: title,
                schema: NodeSchema(
                    inputs: index == 0 ? ["owner idea"] : [previousOutput ?? "upstream output"],
                    outputs: [output],
                    goal: "Complete \(title)"
                ),
                contextSources: [],
                executionMode: .human,
                executorType: .mock,
                doerId: canvas.ownerId,
                status: .ready,
                dependsOnNodeIds: previousId.map { [$0] } ?? [],
                nodeKind: .step
            )
            changes.append(.addNode(node))
            previousId = id
            previousOutput = output
        }

        return PlanProposal(
            id: "proposal-\(canvas.id)-workflow-\(proposalUUID)",
            canvasId: canvas.id,
            summary: "Create workflow: \(steps.map(displayTitle).joined(separator: " -> "))",
            changes: changes,
            status: .pending
        )
    }

    private func parseWorkflowSteps(_ goal: String) -> [String]? {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("->") else { return nil }
        let lower = trimmed.lowercased()
        let chain: Substring
        if let range = trimmed.range(of: "workflow:", options: .caseInsensitive) {
            chain = trimmed[range.upperBound...]
        } else if lower.hasPrefix("workflow ") {
            chain = trimmed.dropFirst("workflow ".count)
        } else if lower.hasPrefix("create nodes ") {
            chain = trimmed.dropFirst("create nodes ".count)
        } else {
            chain = Substring(trimmed)
        }

        let steps = chain
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)[0]
            .split(separator: "->")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return steps.count >= 2 ? steps : nil
    }

    private func uniqueNodeId(canvasId: String, title: String, existingIds: inout Set<String>) -> String {
        let base = "\(canvasId)-\(slug(title))"
        var candidate = base
        var suffix = 2
        while existingIds.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        existingIds.insert(candidate)
        return candidate
    }

    private func slug(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let parts = value.lowercased().unicodeScalars.reduce(into: [String]()) { result, scalar in
            if allowed.contains(scalar) {
                result.append(String(scalar))
            } else if result.last != "-" {
                result.append("-")
            }
        }
        let slug = parts.joined().trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "step" : slug
    }

    private func displayTitle(_ value: String) -> String {
        value
            .split(separator: " ")
            .map { word in
                let lower = word.lowercased()
                switch lower {
                case "prd-draft":
                    return "PRD Draft"
                case "pre-release":
                    return "Pre-release"
                case "prd":
                    return "PRD"
                case "pr":
                    return "PR"
                case "to":
                    return "to"
                default:
                    return word.prefix(1).uppercased() + word.dropFirst()
                }
            }
            .joined(separator: " ")
    }

    /// The heuristic single-node proposal — mirrors `PlannerBoardBridge`'s
    /// offline `generateProposal` shape so the fallback is indistinguishable
    /// from the existing demo/offline behavior.
    private func heuristicProposal(goal: String, state: PlannerGraphState) -> PlanProposal {
        let canvas = state.canvas
        let title = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let proposalUUID = UUID().uuidString.lowercased()
        let node = PlanningNode(
            id: "\(canvas.id)-proposal-node-\(proposalUUID)",
            canvasId: canvas.id,
            title: title.isEmpty ? "Generated meee2 AI node" : title,
            schema: NodeSchema(
                inputs: ["owner goal", "meee2 AI context"],
                outputs: ["executable node output"],
                goal: "complete the generated node"
            ),
            contextSources: [
                ContextSource(kind: .document, title: "meee2 AI context", reference: canvas.plannerContext)
            ],
            executionMode: .human,
            executorType: .mock,
            doerId: canvas.ownerId,
            status: .ready
        )
        return PlanProposal(
            id: "proposal-\(canvas.id)-generate-\(proposalUUID)",
            canvasId: canvas.id,
            summary: "Generate meee2 AI graph for \(canvas.title)",
            changes: [.addNode(node)],
            status: .pending
        )
    }
}

// MARK: - Registry (the single injection seam)

/// THE seam.
///
/// Every planner entry point routes through `PlannerAgentRuntimeRegistry.shared`
/// instead of touching a `PlannerAdapter` or heuristic directly. To replace
/// meee2's planner brain with your own evolution engine, do exactly one thing:
///
/// ```swift
/// PlannerAgentRuntimeRegistry.shared = MyEvolutionRuntime()
/// ```
///
/// Nothing else in the planner HTTP surface or board bridge needs to change.
enum PlannerAgentRuntimeRegistry {
    /// The active planner agent runtime. Defaults to the no-autonomous-loop
    /// `DefaultPlannerAgentRuntime`; assign to swap the whole runtime.
    static var shared: PlannerAgentRuntime = DefaultPlannerAgentRuntime()
}
