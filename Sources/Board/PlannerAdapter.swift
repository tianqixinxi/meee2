import Foundation

/// Phase 1 planner-graph: a BYOA/CLI-backed proposal generator.
///
/// `PlannerAdapter` is the seam between the planner HTTP surface and a real
/// LLM. It takes the *full* graph context (canvas + nodes + edges + artifacts
/// + access) plus an owner goal and asks the model to return a strict
/// `PlanProposal` JSON. The output always flows through
/// `PlannerProposalValidator` before it can reach the store, so a malformed
/// or cross-canvas proposal can never be persisted.
///
/// The default implementation (`BYOAPlannerAdapter`) reuses the existing
/// `AssistantProvider` mechanism — same `runTurn` / `ProviderEvent` shape used
/// by the assistant chat and automations. It does **not** introduce a new HTTP
/// client; for `provider == .local` it shells out to `claude -p` exactly like
/// `LocalClaudeProvider`.
protocol PlannerAdapter {
    /// Generate a `PlanProposal` for `state` driven by `goal`.
    /// Throws `PlannerCoreError` on validation failure, or a provider error
    /// when the model/CLI is unavailable.
    func generateProposal(
        for state: PlannerGraphState,
        goal: String
    ) async throws -> PlanProposal
}

// MARK: - BYOA / CLI adapter

/// BYOA/CLI planner adapter built on top of `AssistantProvider`.
///
/// Flow:
/// 1. Serialize the graph context (`PlannerGraphContext`) into structured JSON.
/// 2. Send a strict-output system prompt + the JSON context to the provider.
/// 3. Collect the streamed text, decode + validate it via
///    `PlannerProposalValidator`.
struct BYOAPlannerAdapter: PlannerAdapter {
    let provider: AssistantProvider
    let settings: AssistantSettings

    /// Build an adapter for the given assistant settings, reusing the same
    /// provider factory the assistant chat uses (openai / anthropic / local).
    init(settings: AssistantSettings) {
        self.provider = AssistantProviderFactory.make(settings.provider)
        self.settings = settings
    }

    /// Test / advanced seam: inject a provider directly.
    init(provider: AssistantProvider, settings: AssistantSettings) {
        self.provider = provider
        self.settings = settings
    }

    func generateProposal(
        for state: PlannerGraphState,
        goal: String
    ) async throws -> PlanProposal {
        let context = PlannerGraphContext(state: state, goal: goal)
        let userPrompt = PlannerAdapterPromptFactory.generatePrompt(context: context)

        var output = ""
        let stream = provider.runTurn(
            systemPrompt: PlannerAdapterPromptFactory.systemPrompt,
            messages: [ChatMessage(role: .user, content: userPrompt)],
            tools: [],
            settings: settings
        )
        for try await event in stream {
            switch event {
            case .textDelta(let delta):
                output += delta
            case .turnDone:
                break
            case .toolCall:
                continue
            case .error(let message):
                throw NSError(
                    domain: "PlannerAdapter",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            }
        }

        NSLog("[PlannerAdapter] raw model output (%d chars):\n%@",
              output.count, String(output.prefix(4000)))
        let proposal: PlanProposal
        do {
            proposal = try PlannerProposalValidator.decodeProposal(from: output)
        } catch {
            NSLog("[PlannerAdapter] decodeProposal failed: %@", String(describing: error))
            throw error
        }
        try PlannerProposalValidator.validate(
            proposal,
            canvas: state.canvas,
            nodes: state.nodes
        )
        return proposal
    }
}

// MARK: - Serialized graph context

/// JSON-encodable projection of `PlannerGraphState` handed to the model.
/// Deliberately a *narrow* shape — only the fields the model needs to plan —
/// so the prompt stays compact and the model can't drift on internal state.
struct PlannerGraphContext: Codable, Equatable {
    struct Canvas: Codable, Equatable {
        var id: String
        var title: String
        var ownerId: String
        var plannerContext: String
    }

    struct Node: Codable, Equatable {
        var id: String
        var kind: String
        var title: String
        var status: String
        var doerId: String
        var dependsOnNodeIds: [String]
        /// Current IO contract of the node. Exposed so the model can *refine*
        /// an existing node's schema via `updateNode` — without it the model
        /// cannot see what it would be changing.
        var ioSchema: IOSchema
    }

    struct Edge: Codable, Equatable {
        var sourceNodeId: String
        var targetNodeId: String
        var kind: String
    }

    struct Artifact: Codable, Equatable {
        var id: String
        var nodeId: String
        var kind: String
        var title: String
        var reference: String
        var status: String
    }

    struct Access: Codable, Equatable {
        var actorId: String
        var role: String
        var canCreateProposal: Bool
    }

    var goal: String
    var canvas: Canvas
    var nodes: [Node]
    var edges: [Edge]
    var artifacts: [Artifact]
    var access: Access
    /// Known node `kind` values the model is allowed to emit.
    var allowedNodeKinds: [String]
    /// Known change `kind` values the model is allowed to emit.
    var allowedChangeKinds: [String]
    /// Allowed `executionMode` raw values.
    var allowedExecutionModes: [String]
    /// Allowed `executorType` raw values.
    var allowedExecutorTypes: [String]
    /// Allowed node `status` raw values.
    var allowedNodeStatuses: [String]

    init(state: PlannerGraphState, goal: String) {
        self.goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        self.canvas = Canvas(
            id: state.canvas.id,
            title: state.canvas.title,
            ownerId: state.canvas.ownerId,
            plannerContext: state.canvas.plannerContext
        )
        self.nodes = state.nodes.map { node in
            Node(
                id: node.id,
                kind: (node.nodeKind ?? .step).rawValue,
                title: node.title,
                status: node.status.rawValue,
                doerId: node.doerId,
                dependsOnNodeIds: node.dependsOnNodeIds ?? [],
                ioSchema: node.ioSchema
            )
        }
        self.edges = state.edges.map { edge in
            Edge(
                sourceNodeId: edge.sourceNodeId,
                targetNodeId: edge.targetNodeId,
                kind: edge.kind
            )
        }
        self.artifacts = state.artifacts.map { artifact in
            Artifact(
                id: artifact.id,
                nodeId: artifact.nodeId,
                kind: artifact.kind.rawValue,
                title: artifact.title,
                reference: artifact.reference,
                status: artifact.status
            )
        }
        self.access = Access(
            actorId: state.access.actorId,
            role: state.access.role.rawValue,
            canCreateProposal: state.access.canCreateProposal
        )
        self.allowedNodeKinds = PlannerProposalValidator.knownNodeKinds.sorted()
        self.allowedChangeKinds = PlannerProposalValidator.knownChangeKinds.sorted()
        self.allowedExecutionModes = ExecutionMode.allCases.map { $0.rawValue }.sorted()
        self.allowedExecutorTypes = ExecutorType.allCases.map { $0.rawValue }.sorted()
        self.allowedNodeStatuses = PlanningNodeStatus.allCases.map { $0.rawValue }.sorted()
    }

    /// Compact, sorted-keys JSON for embedding into the prompt.
    func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

// MARK: - Prompt factory

enum PlannerAdapterPromptFactory {
    static let systemPrompt = """
    You are meee2 AI, the planner-graph proposal generator.
    You are given the full state of one planning canvas as JSON and an owner goal.
    Return ONLY strict JSON for a PlanProposal — no prose, no markdown fences.

    The PlanProposal shape is:
    {
      "id": "<unique proposal id>",
      "canvasId": "<MUST equal context.canvas.id>",
      "summary": "<one-line description of the change>",
      "changes": [ <PlanChange>, ... ],
      "status": "pending"
    }

    A PlanChange is either:
    - addNode:    {"kind": "addNode", "node": <PlanningNode>}
    - updateNode: {"kind": "updateNode", "nodeId": "<existing node id>", <changed design fields>}
      updateNode may change ONLY these design fields — include only the ones
      you actually change: title, status, ioSchema, contextSources,
      dependsOnNodeIds.
      To refine a node's IO contract, set its ioSchema. Every node's CURRENT
      ioSchema is given in context.nodes[].ioSchema, so you can adjust it in
      place rather than guessing.
      Do NOT set execution-layer fields (sessionId / workflowRunState) via
      updateNode — those belong to a workflow run, not the graph design.

    A PlanningNode requires at least:
      id, canvasId, title,
      ioSchema { "consumes": [string], "produces": [string], "completionSignal": string },
      contextSources, executionMode, executorType, doerId, status, nodeKind.

    contextSources is an array of OBJECTS — never bare strings:
      { "kind": "chatHistory"|"repository"|"web"|"document"|"artifact",
        "title": string, "reference": string }
    Use an empty array [] unless you have a concrete source.

    Enum fields MUST use ONLY these exact raw values — do not invent others:
    - nodeKind      ∈ context.allowedNodeKinds
    - executionMode ∈ context.allowedExecutionModes
    - executorType  ∈ context.allowedExecutorTypes
    - status        ∈ context.allowedNodeStatuses
    Any value outside these sets makes the whole proposal invalid.

    Hard rules:
    - canvasId on the proposal AND on every added node MUST equal context.canvas.id.
    - Never reference a node id that belongs to another canvas.
    - updateNode.nodeId MUST be an existing node id from context.nodes.
    - Only use node kinds from context.allowedNodeKinds.
    - Only use change kinds from context.allowedChangeKinds.
    - executionMode / executorType / status must be exact values from the
      matching context.allowed* list (e.g. executionMode is one of auto /
      sign-off / human — there is no "manual").
    - Keep changes small, executable, and at least one change.
    - dependsOnNodeIds may only reference nodes in this canvas (existing or added).
    """

    static func generatePrompt(context: PlannerGraphContext) -> String {
        """
        Owner goal:
        \(context.goal.isEmpty ? "(no explicit goal — propose the most useful next step)" : context.goal)

        Planner graph context (JSON):
        \(context.jsonString())

        Return the PlanProposal JSON now.
        """
    }
}
