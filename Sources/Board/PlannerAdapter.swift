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

        // Meee2 AI is a Claude Code runtime harness — on a rejected proposal we
        // DON'T silently drop bad changes; we feed the validation error back and
        // let the model self-correct, then retry.
        var messages: [ChatMessage] = [ChatMessage(role: .user, content: userPrompt)]
        let maxAttempts = 2
        var lastError: Error?

        for attempt in 1...maxAttempts {
            var output = ""
            let stream = provider.runTurn(
                systemPrompt: PlannerAdapterPromptFactory.systemPrompt,
                messages: messages,
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

            NSLog("[PlannerAdapter] attempt %d raw model output (%d chars):\n%@",
                  attempt, output.count, String(output.prefix(4000)))
            do {
                var proposal = try PlannerProposalValidator.decodeProposal(from: output)
                // State-machine PR-A · validate takes inout so it can fold
                // deprecated-status warnings into proposal.warnings.
                try PlannerProposalValidator.validate(
                    &proposal,
                    canvas: state.canvas,
                    nodes: state.nodes
                )
                return proposal
            } catch {
                lastError = error
                NSLog("[PlannerAdapter] attempt %d decode/validate failed: %@",
                      attempt, String(describing: error))
                guard attempt < maxAttempts else { break }
                // Self-correction turn: echo the rejected output + the precise
                // failure, ask for a corrected complete proposal.
                messages.append(ChatMessage(role: .assistant, content: output))
                messages.append(ChatMessage(role: .user, content: """
                Your previous proposal was REJECTED by the validator:
                \(String(describing: error))

                Re-emit the COMPLETE corrected PlanProposal as strict JSON (no prose, no fences). Common fixes:
                - Use ONLY change kinds listed in context.allowedChangeKinds.
                - For "B depends on A", set dependsOnNodeIds:["A"] on B's addNode — do NOT invent edge/connection changes.
                - Every enum field must use an exact allowed raw value.
                - canvasId on the proposal and every added node MUST equal context.canvas.id.
                """))
            }
        }
        throw lastError ?? PlannerCoreError.invalidPlannerProposalJSON
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
        var schema: NodeSchema
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
    /// Pending / approved proposals are part of the working canvas in the UI.
    /// The model must see them so follow-up messages evolve the current
    /// proposed graph instead of replacing it with an unrelated proposal.
    var openProposals: [PlanProposal]
    /// Known node `kind` values the model is allowed to emit.
    var allowedNodeKinds: [String]
    /// Known change `kind` values the model is allowed to emit.
    var allowedChangeKinds: [String]
    /// Allowed completion mode raw values.
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
                schema: node.schema
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
        self.openProposals = Array(state.proposals.filter { proposal in
            proposal.status == .pending || proposal.status == .approved
        }.suffix(5))
        self.allowedNodeKinds = PlannerProposalValidator.knownNodeKinds.sorted()
        // Only expose the change kinds this adapter's PROMPT actually documents.
        // The contract knows ~18 kinds (addEdge / addDataSource / setMonitorSpec /
        // …) but this BYOA prompt only teaches addNode / updateNode /
        // attachArtifact + dependencies-via-dependsOnNodeIds. Exposing the
        // undocumented kinds made the model GUESS their shape (e.g. an addEdge
        // missing the required `sourceRef`) → strict decode rejected the whole
        // proposal → silent "搭建失败". The richer 5-atom changes (Edge /
        // DataSource / Monitor) are produced by the meee2-online sidecar agent,
        // which carries the full schema + self-corrects on validation error.
        self.allowedChangeKinds = ["addNode", "updateNode", "attachArtifact"]
            .filter(PlannerProposalValidator.knownChangeKinds.contains)
            .sorted()
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
    You are Meee2 AI, the planner-graph proposal generator.
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
    - attachArtifact:
      {"kind": "attachArtifact", "nodeId": "<existing or added node id>",
       "artifact": {"kind": "kanban"|"generic"|..., "title": string,
                    "reference": string, "status": "attached",
                    "payload": <JSON object>}}
      updateNode may change ONLY these design fields — include only the ones
      you actually change: title, status, schema, contextSources,
      dependsOnNodeIds.
      To refine a node's IO contract, set its schema. Every node's CURRENT
      schema is given in context.nodes[].schema, so you can adjust it in
      place rather than guessing.
      Do NOT set execution-layer fields (sessionId / workflowRunState) via
      updateNode — those belong to a workflow run, not the graph design.

    A PlanningNode requires at least:
      id, canvasId, title,
      schema { "inputs": [string], "outputs": [string], "goal": string },
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
    - This is graph evolution, not graph replacement. Treat context.nodes plus
      context.openProposals as the current working canvas.
    - Preserve existing working content unless the owner explicitly asks to
      remove or replace it.
    - If the owner goal contains "@node:<id> #revise", treat it as an edit of
      that node, not a request for a new step. If <id> exists in context.nodes,
      return updateNode for that id unless the owner explicitly asks to add a
      downstream step.
    - For committed nodes in context.nodes, refine them with updateNode instead
      of adding duplicate nodes.
    - Inputs and outputs are NOT workflow steps. Do not add an "artifact" node
      just to represent an input or output. Put resources in schema.inputs,
      schema.outputs, contextSources, or artifactRefs; the UI can render those
      resources as artifact cards when the owner turns them on.
    - If the owner describes a node like "idea fetch(input=lark_doc,
      output=idea_list_kanban)", create or update ONE step node with
      schema.inputs=["lark_doc"] and schema.outputs=["idea_list_kanban"].
    - If the owner asks for a kanban/list board output, prefer a schema output
      named like "idea_list_kanban". Also add an attachArtifact change for
      the same step node with kind="kanban" and payload:
      {"version":1,"columns":[{"id":"...", "title":"..."}],"items":[]}.
      Choose column titles from the user's semantics. For an idea list, start
      with an empty "Idea list" column; for review/workflow boards choose the
      natural stages implied by the user. Do not create a separate
      stamp/artifact workflow step for the kanban itself.
    - For "idea fetch(input=lark_doc, output=html kanban)", still create ONE
      step node. The output is a kanban artifact payload that can later render
      HTML/list items; it is not a second step.
    - Nodes introduced only by context.openProposals are not committed yet, so
      updateNode cannot target them. If they should remain, re-emit the desired
      addNode definition in the new proposal, with any refinements folded into
      that addNode.
    - updateNode.nodeId MUST be an existing node id from context.nodes.
    - Only use node kinds from context.allowedNodeKinds.
    - Only use change kinds from context.allowedChangeKinds.
    - executionMode / executorType / status must be exact values from the
      matching context.allowed* list. executionMode is the completion mode:
      "auto" means produced outputs can complete the node automatically;
      "human" means a human confirms completion after output is produced.
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
