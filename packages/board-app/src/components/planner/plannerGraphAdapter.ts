import { MarkerType, type Edge, type Node } from '@xyflow/react'
import type {
  IntegrationEntity,
  NodeAssignment,
  NodeContractExternalInput,
  NodeStateSnapshot,
  PlanChange,
  PlanProposal,
  PlannerArtifact,
  PlannerDispatchRunner,
  PlannerGraphEdge as PlannerGraphStateEdge,
  PlanningNode,
  PlanningNodeStatus,
  RunNodeState,
} from '../../types'
import type { CanvasNodeMonitorItem } from '@meee1/recap-core'

export type PlannerPreviewKind = 'none' | 'added' | 'updated'
export type PlannerNodePerception = 'done' | 'attention' | 'not-reached' | 'active' | 'neutral'
export type PlannerEdgePerception = PlannerNodePerception | 'preview' | 'flow'
export type IOArtifactDirection = 'input' | 'output'
export type IOArtifactKind = 'text' | 'integration' | 'html' | 'kanban' | 'json' | 'file'
export interface IOArtifactVisibility {
  inputs: string[]
  outputs: string[]
}
type PlannerGraphMode = 'design' | 'run'

// Singleton empty artifacts array — stable reference so PlannerNodeCard's
// memoization sees props as unchanged when a node has no artifacts. Without
// this, `?? []` minted a fresh `[]` per adapter call and every poll/state
// update re-rendered all artifact-less nodes, which caused continuous edge
// flicker after Push 5(成果 row referenced data.artifacts).
const EMPTY_ARTIFACTS: PlannerArtifact[] = Object.freeze([]) as unknown as PlannerArtifact[]

/**
 * Default node size by widget kind (P2.5).
 *
 * Standard nodes (no widget) stay at 320×238 — the pre-widget default.
 * Widget kinds get larger canvas real estate per their typical layout.
 * `node.layout.width/height` (user / template overrides) always wins.
 */
function widgetDefaultSize(kind: string | undefined | null): { width: number; height: number } {
  switch (kind) {
    case 'kanban': return { width: 480, height: 320 }
    case 'matrix': return { width: 520, height: 280 }
    case 'inbox':  return { width: 400, height: 280 }
    case 'badge':  return { width: 220, height: 80 }
    case 'artifact-preview': return { width: 360, height: 240 }
    default: return { width: 320, height: 238 }
  }
}

export interface PlannerNodeData extends Record<string, unknown> {
  node: PlanningNode
  /** P2 fix · 完整 graph 节点列表,供 widget resolver 解析 upstream /
   *  subcanvas-aggregate widgets。card 把它原样传给 resolveWidgetData,
   *  让 source.inputKind === 'upstream' 或 'subcanvas-aggregate' 的 widget
   *  能按 dependsOnNodeIds[inputIndex] 找到目标节点,而不是只看到自己。 */
  allNodes: PlanningNode[]
  state: NodeStateSnapshot | null
  artifacts: PlannerArtifact[]
  /** P3.0 — canvas-level pool of integration entities, shared across all
   *  widget-bearing nodes. Resolver filters per-node via widget.source. */
  integrationEntities?: IntegrationEntity[]
  previewKind: PlannerPreviewKind
  perception: PlannerNodePerception
  /** Design vs Run mode — the card collapses execution fields in Design. */
  mode: PlannerGraphMode
  /** This node's state in the selected run, when one is being viewed. */
  runNodeState: RunNodeState | null
  hasSelectedDelivery: boolean
  responsibleLabel?: string
  responsibleAvatarUrl?: string
  virtual?: boolean
  artifactDirection?: IOArtifactDirection
  artifactKind?: IOArtifactKind
  sourceNodeId?: string
  ioItem?: string
  inputReference?: string | null
  /** UI-1 · Canvas id surfaced to the card so the version dropdown can call
   *  the artifact-versions endpoints without bubbling up. */
  canvasId?: string
  onOpenDetails?: (nodeId: string) => void
  onOpenSubCanvas?: (canvasId: string) => void
  onOpenKanbanItem?: (artifact: PlannerArtifact, itemId: string, title: string, subCanvasId?: string | null) => void
  onBindInput?: (nodeId: string, input: string, reference: string) => void
  onChangeStatus?: (nodeId: string, status: PlanningNodeStatus) => void
  onChangeGateMode?: (nodeId: string, mode: 'human' | 'auto') => void
  canChangeStatus?: boolean
  onCreateSession?: (nodeId: string, runner: PlannerDispatchRunner) => void
  onOpenSession?: (sessionId: string, nodeId: string) => void
  onReplaceSession?: (nodeId: string, runner: PlannerDispatchRunner) => void
  onCancelSessionCreation?: (nodeId: string) => void
  onDeleteNode?: (nodeId: string, title?: string) => void
  onHideIOArtifact?: (nodeId: string, direction: IOArtifactDirection, item: string) => void
  /** UI-1 · Re-run a node by appending a new artifact version. */
  onRerunNode?: (nodeId: string, reference?: string) => void
  /**
   * UI-4: pre-resolved title of the upstream source node, used by the
   * three-section Input card.
   */
  upstreamSourceLabel?: string | null
  /** UI-4: open the "Attach data source" popover for this node. */
  onAttachDataSource?: (nodeId: string) => void
  /** UI-4: trigger a one-off sync for a specific external input. */
  onRefreshExternalInput?: (nodeId: string, external: NodeContractExternalInput) => void
  /** UI-4: open the dialogue retention popover for this node. */
  onConfigureDialogue?: (nodeId: string) => void
  creatingSession?: boolean
  showResponsibleInfo?: boolean
  /** UI-2: active assignment for this node, when present. */
  assignment?: NodeAssignment | null
  /** UI-2: opens the assign dialog (top-right owner chip click). */
  onRequestAssign?: (nodeId: string) => void
  /** UI-2: opens the assigned sub-canvas from the chip. */
  onOpenAssignedSubCanvas?: (subCanvasId: string) => void
  /** UI-2: false when ENG-4 RLS would refuse internal edits. */
  canEditInternals?: boolean
  monitorItem?: CanvasNodeMonitorItem | null
}

export type PlannerGraphNode = Node<PlannerNodeData, 'plannerNode'>
export interface PlannerGraphEdgeData extends Record<string, unknown> {
  preview: boolean
  perception: PlannerEdgePerception
  /** UI-4: handler for the "+ Transform" floating button. */
  onInsertTransform?: (sourceNodeId: string, targetNodeId: string) => void
  /** UI-4: when true, suppresses the + insert button (artifact / preview edges). */
  suppressInsert?: boolean
}

export type PlannerGraphEdge = Edge<PlannerGraphEdgeData>

interface PlannerGraphInput {
  nodes: PlanningNode[]
  states: NodeStateSnapshot[]
  edges?: PlannerGraphStateEdge[]
  artifacts?: PlannerArtifact[]
  /** P3.0 — canvas-level integration entity pool. */
  integrationEntities?: IntegrationEntity[]
  proposal?: PlanProposal | null
  ownerId?: string
  mode: PlannerGraphMode
  /** UI-1 · Canvas id passed straight through to every node card so the
   *  version dropdown / re-run button can address the right canvas. */
  canvasId?: string
  /** nodeId → run state, from the run being viewed (Run mode only). */
  runNodeStates?: Record<string, RunNodeState>
  ioArtifactVisibility?: Record<string, IOArtifactVisibility>
  displayNameByUserId?: Record<string, string>
  avatarUrlByUserId?: Record<string, string>
  onOpenDetails?: (nodeId: string) => void
  onOpenSubCanvas?: (canvasId: string) => void
  onOpenKanbanItem?: (artifact: PlannerArtifact, itemId: string, title: string, subCanvasId?: string | null) => void
  onBindInput?: (nodeId: string, input: string, reference: string) => void
  onChangeStatus?: (nodeId: string, status: PlanningNodeStatus) => void
  onChangeGateMode?: (nodeId: string, mode: 'human' | 'auto') => void
  canChangeStatus?: boolean
  onCreateSession?: (nodeId: string, runner: PlannerDispatchRunner) => void
  onOpenSession?: (sessionId: string, nodeId: string) => void
  onReplaceSession?: (nodeId: string, runner: PlannerDispatchRunner) => void
  onCancelSessionCreation?: (nodeId: string) => void
  onDeleteNode?: (nodeId: string, title?: string) => void
  onHideIOArtifact?: (nodeId: string, direction: IOArtifactDirection, item: string) => void
  onRerunNode?: (nodeId: string, reference?: string) => void
  /** UI-4 hooks — see PlannerNodeData for descriptions. */
  onAttachDataSource?: (nodeId: string) => void
  onRefreshExternalInput?: (nodeId: string, external: NodeContractExternalInput) => void
  onConfigureDialogue?: (nodeId: string) => void
  /** UI-4: + Transform button on edge. */
  onInsertTransformBetween?: (sourceNodeId: string, targetNodeId: string) => void
  creatingSessionNodeIds?: Set<string>
  showResponsibleInfo?: boolean
  /** UI-2: assignments keyed by source node id. */
  nodeAssignmentsByNodeId?: Record<string, NodeAssignment>
  /** UI-2: open the assign dialog for a node. */
  onRequestAssign?: (nodeId: string) => void
  /** UI-2: navigate into an assigned sub-canvas. */
  onOpenAssignedSubCanvas?: (subCanvasId: string) => void
  /** UI-2: whether the parent canvas owner can still edit node internals. */
  canEditInternals?: boolean
  monitorItemsByNodeId?: Record<string, CanvasNodeMonitorItem>
}

export function buildPlannerGraph(input: PlannerGraphInput): {
  nodes: PlannerGraphNode[]
  edges: PlannerGraphEdge[]
} {
  const stateByNodeId = new Map(input.states.map((state) => [state.nodeId, state]))
  const previewArtifacts = proposalArtifactsForPreview(input.proposal)
  const allArtifacts = [...(input.artifacts ?? []), ...previewArtifacts]
  const artifactsByNodeId = new Map<string, PlannerArtifact[]>()
  for (const artifact of allArtifacts) {
    const artifacts = artifactsByNodeId.get(artifact.nodeId) ?? []
    artifacts.push(artifact)
    artifactsByNodeId.set(artifact.nodeId, artifacts)
  }
  const previewNodes = applyPendingProposalOverlay(input.nodes, input.proposal)
  const titleByNodeId = new Map(previewNodes.map(({ node }) => [node.id, node.title]))
  const positionByNodeId = buildNodePositions(previewNodes.map((item) => item.node))
  // P2 fix · widget resolver needs the full canvas node list (upstream /
  // subcanvas-aggregate widgets follow dependsOnNodeIds → other nodes). Build
  // a stable, shared array once and hand it to every card; previously each
  // card only saw `[node]` and resolvers failed with 找不到指定的上游节点.
  const allCanvasNodes = previewNodes.map(({ node }) => node)
  const graphNodes = previewNodes.map(({ node, previewKind }, index) => {
    const position = node.layout
      ? { x: node.layout.x, y: node.layout.y }
      : positionByNodeId.get(node.id) ?? {
      x: (index % 3) * 340,
      y: Math.floor(index / 3) * 190,
    }
    const widgetSize = widgetDefaultSize(node.widget?.kind)
    return {
      id: node.id,
      type: 'plannerNode' as const,
      position,
      initialWidth: node.layout?.width ?? widgetSize.width,
      initialHeight: node.layout?.height ?? widgetSize.height,
      data: {
        node,
        allNodes: allCanvasNodes,
        state: stateByNodeId.get(node.id) ?? null,
        artifacts: artifactsByNodeId.get(node.id) ?? EMPTY_ARTIFACTS,
        integrationEntities: input.integrationEntities,
        previewKind,
        perception: perceptionForNode(
          node,
          stateByNodeId.get(node.id) ?? null,
          input.mode,
          input.runNodeStates?.[node.id] ?? null,
        ),
        mode: input.mode,
        runNodeState: input.runNodeStates?.[node.id] ?? null,
        hasSelectedDelivery: Boolean(input.runNodeStates),
        responsibleLabel: resolveUserLabel(
          input.mode === 'run'
            ? input.runNodeStates?.[node.id]?.assigneeId ?? node.doerId
            : node.doerId,
          input.displayNameByUserId,
        ),
        responsibleAvatarUrl: resolveUserAvatar(
          input.mode === 'run'
            ? input.runNodeStates?.[node.id]?.assigneeId ?? node.doerId
            : node.doerId,
          input.avatarUrlByUserId,
        ),
        virtual: false,
        canvasId: input.canvasId,
        onOpenDetails: input.onOpenDetails,
        onOpenSubCanvas: input.onOpenSubCanvas,
        onOpenKanbanItem: input.onOpenKanbanItem,
        onChangeStatus: input.onChangeStatus,
        onChangeGateMode: input.onChangeGateMode,
        canChangeStatus: input.canChangeStatus ?? false,
        onCreateSession: input.onCreateSession,
        onOpenSession: input.onOpenSession,
        onReplaceSession: input.onReplaceSession,
        onCancelSessionCreation: input.onCancelSessionCreation,
        onDeleteNode: input.onDeleteNode,
        onRerunNode: input.onRerunNode,
        upstreamSourceLabel: (() => {
          const firstDep = (node.dependsOnNodeIds ?? [])[0]
          return firstDep ? titleByNodeId.get(firstDep) ?? firstDep : null
        })(),
        onAttachDataSource: input.onAttachDataSource,
        onRefreshExternalInput: input.onRefreshExternalInput,
        onConfigureDialogue: input.onConfigureDialogue,
        creatingSession: input.creatingSessionNodeIds?.has(node.id) ?? false,
        showResponsibleInfo: input.showResponsibleInfo ?? true,
        assignment: input.nodeAssignmentsByNodeId?.[node.id] ?? null,
        onRequestAssign: input.onRequestAssign,
        onOpenAssignedSubCanvas: input.onOpenAssignedSubCanvas,
        canEditInternals: input.canEditInternals ?? true,
        monitorItem: input.monitorItemsByNodeId?.[node.id] ?? null,
      },
    }
  })
  const virtualArtifactNodes = buildVisibleIOArtifactNodes({
    previewNodes,
    graphNodes,
    visibility: input.ioArtifactVisibility ?? {},
    onOpenDetails: input.onOpenDetails,
    onOpenKanbanItem: input.onOpenKanbanItem,
    onBindInput: input.onBindInput,
    onHideIOArtifact: input.onHideIOArtifact,
  })

  const perceptionByNodeId = new Map(graphNodes.map((node) => [node.id, node.data.perception]))
  const edges = [
    ...buildDependencyEdges(previewNodes, perceptionByNodeId, input.edges, input.onInsertTransformBetween),
    ...buildIOArtifactEdges(virtualArtifactNodes),
  ]
  return { nodes: [...graphNodes, ...virtualArtifactNodes.map((item) => item.node)], edges }
}

function buildVisibleIOArtifactNodes(input: {
  previewNodes: Array<{ node: PlanningNode; previewKind: PlannerPreviewKind }>
  graphNodes: PlannerGraphNode[]
  visibility: Record<string, IOArtifactVisibility>
  onOpenDetails?: (nodeId: string) => void
  onOpenKanbanItem?: (artifact: PlannerArtifact, itemId: string, title: string, subCanvasId?: string | null) => void
  onBindInput?: (nodeId: string, input: string, reference: string) => void
  onHideIOArtifact?: (nodeId: string, direction: IOArtifactDirection, item: string) => void
}): Array<{ node: PlannerGraphNode; sourceNodeId: string; direction: IOArtifactDirection }> {
  const graphNodeById = new Map(input.graphNodes.map((node) => [node.id, node]))
  const result: Array<{ node: PlannerGraphNode; sourceNodeId: string; direction: IOArtifactDirection }> = []
  for (const { node: sourceNode } of input.previewNodes) {
    if ((sourceNode.nodeKind ?? 'step') !== 'step') continue
    const visible = input.visibility[sourceNode.id]
    if (!visible) continue
    const sourceGraphNode = graphNodeById.get(sourceNode.id)
    if (!sourceGraphNode) continue
    const inputs = visible.inputs
      .filter((item) => (sourceNode.schema?.inputs ?? []).includes(item))
      .map((item, index) => {
        const binding = sourceNode.contextSources.find((source) => normalizeIOKey(source.title) === normalizeIOKey(item))
        return { item, index, direction: 'input' as const, artifact: null, artifacts: [] as PlannerArtifact[], reference: binding?.reference ?? item, inputReference: binding?.reference ?? null }
      })
    const outputCandidates = dedupeIOArtifactItems([
      ...(sourceNode.schema?.outputs ?? []),
      ...(sourceNode.artifactRefs ?? []),
      ...(sourceGraphNode.data.state?.artifactRefs ?? []),
      ...sourceGraphNode.data.artifacts.map((artifact) => artifact.reference),
    ])
    const outputs = visible.outputs
      .filter((item) => outputCandidates.includes(item))
      .map((item, index) => {
        const artifacts = sortArtifactsForDisplay(sourceGraphNode.data.artifacts.filter((artifact) =>
          artifact.reference === item || normalizeIOKey(artifact.reference) === normalizeIOKey(item) || normalizeIOKey(artifact.title) === normalizeIOKey(item),
        ))
        return {
          item,
          index,
          direction: 'output' as const,
          artifact: artifacts[0] ?? null,
          artifacts,
          reference: item,
        }
      })
    for (const entry of [...inputs, ...outputs]) {
      const id = ioArtifactNodeId(sourceNode.id, entry.direction, entry.item)
      const artifactKind = entry.artifact ? artifactKindForArtifact(entry.artifact, entry.reference) : artifactKindFor(entry.reference)
      const xOffset = entry.direction === 'input' ? -300 : 360
      const height = artifactKind === 'kanban' ? 280 : 120
      const yOffset = entry.index * (artifactKind === 'kanban' ? 292 : 112)
      const artifactNode: PlanningNode = {
        id,
        canvasId: sourceNode.canvasId,
        title: entry.artifact?.title ?? displayIOArtifactTitle(entry.item),
        schema: {
          inputs: [],
          outputs: [],
          goal: entry.reference,
        },
        contextSources: [],
        executionMode: 'auto',
        executorType: 'mock',
        doerId: '',
        reviewerIds: [],
        approverIds: [],
        handoffPolicy: 'none',
        status: 'ready',
        dependsOnNodeIds: [],
        nodeKind: 'artifact',
        artifactRefs: [entry.item],
      }
      result.push({
        sourceNodeId: sourceNode.id,
        direction: entry.direction,
        node: {
          id,
          type: 'plannerNode' as const,
          position: {
            x: sourceGraphNode.position.x + xOffset,
            y: sourceGraphNode.position.y + yOffset,
          },
          initialWidth: artifactKind === 'kanban' ? 420 : 240,
          initialHeight: height,
          data: {
            node: artifactNode,
            // Virtual IO-artifact nodes don't render widgets — the field is
            // type-required for PlannerNodeData, so seed with the singleton.
            allNodes: [artifactNode],
            state: null,
            previewKind: 'none',
            perception: 'neutral',
            mode: sourceGraphNode.data.mode,
            runNodeState: null,
            hasSelectedDelivery: false,
            virtual: true,
            artifactDirection: entry.direction,
            artifactKind,
            sourceNodeId: sourceNode.id,
            ioItem: entry.item,
            inputReference: entry.direction === 'input' && 'inputReference' in entry ? entry.inputReference : null,
            onOpenDetails: input.onOpenDetails,
            onOpenKanbanItem: input.onOpenKanbanItem,
            onBindInput: input.onBindInput,
            canChangeStatus: false,
            artifacts: entry.artifacts,
            onHideIOArtifact: input.onHideIOArtifact,
            monitorItem: null,
          },
        },
      })
    }
  }
  return result
}

function buildIOArtifactEdges(
  artifactNodes: Array<{ node: PlannerGraphNode; sourceNodeId: string; direction: IOArtifactDirection }>,
): PlannerGraphEdge[] {
  return artifactNodes.map((item) => edgeFor({
    id: item.direction === 'input'
      ? `planner-edge-${item.node.id}-${item.sourceNodeId}`
      : `planner-edge-${item.sourceNodeId}-${item.node.id}`,
    source: item.direction === 'input' ? item.node.id : item.sourceNodeId,
    target: item.direction === 'input' ? item.sourceNodeId : item.node.id,
    perception: 'neutral',
    preview: false,
  }))
}

function ioArtifactNodeId(nodeId: string, direction: IOArtifactDirection, item: string): string {
  return `io-artifact-${nodeId}-${direction}-${stableId(item)}`
}

function stableId(value: string): string {
  const normalized = value.trim().toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '')
  return normalized || 'item'
}

function displayIOArtifactTitle(value: string): string {
  const trimmed = value.trim()
  if (!trimmed) return 'Untitled artifact'
  const withoutQuery = trimmed.split('?')[0]
  const parts = withoutQuery.split(/[/:#]/).filter(Boolean)
  return parts[parts.length - 1]?.replace(/[-_]+/g, ' ') || trimmed
}

function dedupeIOArtifactItems(values: Array<string | null | undefined>): string[] {
  const seen = new Set<string>()
  const result: string[] = []
  for (const value of values) {
    const normalized = value?.trim()
    if (!normalized || seen.has(normalized)) continue
    seen.add(normalized)
    result.push(normalized)
  }
  return result
}

/** A schema output slot may carry `<token>` placeholders (e.g. `<slug>`,
 *  `<date>`, `<id>`). True when the reference still has an unfilled token. */
export function hasTemplateToken(reference: string): boolean {
  return /<[^<>]+>/.test(reference)
}

/** Treat each `<token>` in a slot as a wildcard within one path segment, so a
 *  concrete `…/prd/monitor-session-block-status.md` is recognised as filling
 *  the declared slot `…/prd/<slug>.md`. Scheme-agnostic — works for
 *  `repo://`, `lark://`, `git://…/pull/<id>`, `artifact://…` alike. */
export function referenceFulfillsSlot(reference: string, slot: string): boolean {
  const ref = reference.trim()
  const slotTrimmed = slot.trim()
  if (!ref || !slotTrimmed) return false
  if (!hasTemplateToken(slotTrimmed)) {
    return ref.toLowerCase() === slotTrimmed.toLowerCase()
  }
  const pattern = slotTrimmed
    .replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    .replace(/<[^<>]+>/g, '[^/]*')
  return new RegExp(`^${pattern}$`, 'i').test(ref)
}

export type ResolvedOutputStatus = 'pending' | 'current' | 'superseded'

export interface ResolvedNodeOutput {
  /** Reference to display and to key the visibility toggle on. */
  reference: string
  status: ResolvedOutputStatus
  artifact: PlannerArtifact | null
  /** The schema slot this output fills, when it fills one. */
  fromSlot: string | null
}

/** A concrete output a node produced — either a `PlannerArtifact` record or a
 *  bare reference persisted on `node.artifactRefs` with no artifact object. */
interface ConcreteNodeOutput {
  reference: string
  artifact: PlannerArtifact | null
  /** Sort key for supersession ordering (artifact `createdAt`; 0 otherwise). */
  order: number
}

/** Reconcile a node's declared output slots with the outputs it actually
 *  produced. A concrete output that matches a templated slot *fills* it
 *  (the template stops showing alongside it); when several outputs fill the
 *  same slot the newest is `current` and the rest are `superseded`. The
 *  synthetic `artifact://<nodeId>/output` handle and template-token
 *  placeholder references are never surfaced as real outputs.
 *
 *  Outputs come from three sources: `PlannerArtifact` records (the primary
 *  source — they carry `createdAt` for supersession ordering), bare
 *  `node.artifactRefs` persisted via `updateNode`, and `runtimeRefs` —
 *  state-time output references (e.g. `subcanvas:<id>` injected by
 *  `serviceArtifactRefs`) that are neither persisted on the node nor backed
 *  by an artifact object. A node can legitimately hold outputs in any of
 *  these without a matching artifact, so all are kept as artifact-less
 *  outputs — otherwise those references would silently vanish from the
 *  inspector. */
export function resolveNodeOutputs(
  node: PlanningNode,
  artifacts: PlannerArtifact[],
  runtimeRefs: string[] = [],
): ResolvedNodeOutput[] {
  const slots = (node.schema?.outputs ?? []).map((s) => s.trim()).filter(Boolean)
  const syntheticOutput = `artifact://${node.id}/output`
  const isRealOutput = (reference: string): boolean => {
    const ref = reference.trim()
    return ref !== '' && ref !== syntheticOutput && !hasTemplateToken(ref)
  }

  const fromArtifacts: ConcreteNodeOutput[] = artifacts
    .filter((a) => a.nodeId === node.id && isRealOutput(a.reference))
    .map((a) => ({ reference: a.reference.trim(), artifact: a, order: Date.parse(a.createdAt) || 0 }))
  const seen = new Set(fromArtifacts.map((o) => o.reference.toLowerCase()))
  const fromRefs: ConcreteNodeOutput[] = dedupeIOArtifactItems([
    ...(node.artifactRefs ?? []),
    ...runtimeRefs,
  ])
    .filter((ref) => isRealOutput(ref) && !seen.has(ref.trim().toLowerCase()))
    .map((ref) => ({ reference: ref.trim(), artifact: null, order: 0 }))
  // Artifact-less refs sort first — treated as the oldest known outputs, so a
  // later real artifact filling the same slot supersedes them, not vice versa.
  const concrete = [...fromRefs, ...fromArtifacts].sort((a, b) => a.order - b.order)

  const claimed = new Set<ConcreteNodeOutput>()
  const result: ResolvedNodeOutput[] = []

  for (const slot of slots) {
    const matches = concrete.filter((o) => !claimed.has(o) && referenceFulfillsSlot(o.reference, slot))
    matches.forEach((o) => claimed.add(o))
    if (matches.length === 0) {
      result.push({ reference: slot, status: 'pending', artifact: null, fromSlot: slot })
      continue
    }
    const current = matches[matches.length - 1]
    result.push({ reference: current.reference, status: 'current', artifact: current.artifact, fromSlot: slot })
    for (const old of matches.slice(0, -1)) {
      result.push({ reference: old.reference, status: 'superseded', artifact: old.artifact, fromSlot: slot })
    }
  }
  for (const o of concrete) {
    if (claimed.has(o)) continue
    result.push({ reference: o.reference, status: 'current', artifact: o.artifact, fromSlot: null })
  }
  return result
}

/** The output references worth surfacing — `current` artifacts plus
 *  still-unfilled slot templates. Superseded artifacts are dropped. */
export function visibleOutputReferences(
  node: PlanningNode,
  artifacts: PlannerArtifact[],
  runtimeRefs: string[] = [],
): string[] {
  return resolveNodeOutputs(node, artifacts, runtimeRefs)
    .filter((output) => output.status !== 'superseded')
    .map((output) => output.reference)
}

function artifactKindFor(value: string): IOArtifactKind {
  const normalized = value.toLowerCase()
  if (normalized.includes('kanban') || normalized.includes('看板')) {
    return 'kanban'
  }
  if (normalized.includes('json') || normalized.endsWith('.json')) {
    return 'json'
  }
  if (normalized.includes('html') || normalized.includes('webpage') || normalized.includes('web-page')) {
    return 'html'
  }
  if (
    normalized.includes('://')
    || normalized.startsWith('github:')
    || normalized.startsWith('git:')
    || normalized.startsWith('lark')
    || normalized.startsWith('http:')
    || normalized.startsWith('https:')
  ) {
    return 'integration'
  }
  return 'text'
}

function artifactKindForArtifact(artifact: PlannerArtifact, fallback: string): IOArtifactKind {
  const payload = artifact.payload && typeof artifact.payload === 'object' && !Array.isArray(artifact.payload)
    ? artifact.payload as Record<string, unknown>
    : null
  const type = payload?.type
  if (artifact.kind === 'kanban') return 'kanban'
  if (type === 'text' || type === 'integration' || type === 'html' || type === 'kanban' || type === 'json' || type === 'file') {
    return type
  }
  if (payload?.blobRef && typeof payload.blobRef === 'string') {
    return artifactKindFor(String(payload.filename ?? payload.mimeType ?? fallback))
  }
  return artifactKindFor(artifact.reference || fallback)
}

function sortArtifactsForDisplay(artifacts: PlannerArtifact[]): PlannerArtifact[] {
  return [...artifacts].sort((a, b) => artifactDisplayScore(b) - artifactDisplayScore(a))
}

function artifactDisplayScore(artifact: PlannerArtifact): number {
  const payload = artifact.payload && typeof artifact.payload === 'object' && !Array.isArray(artifact.payload)
    ? artifact.payload as Record<string, unknown>
    : null
  const columns = Array.isArray(payload?.columns) ? payload.columns.length : 0
  const items = Array.isArray(payload?.items) ? payload.items.length : 0
  const hasBlob = typeof payload?.blobRef === 'string' && payload.blobRef.length > 0
  const createdAt = Date.parse(String(artifact.createdAt))
  return (items > 0 ? 10_000 + items : 0)
    + (hasBlob ? 5_000 : 0)
    + (payload?.type === 'kanban' ? 2_000 : 0)
    + (artifact.kind === 'kanban' ? 1_000 : 0)
    + (columns > 0 ? 100 : 0)
    + (Number.isFinite(createdAt) ? createdAt / 1_000_000_000_000 : 0)
}

function normalizeIOKey(value: string): string {
  return value.trim().toLowerCase()
}

function resolveUserAvatar(
  userId: string | null | undefined,
  avatarUrlByUserId: Record<string, string> | undefined,
): string | undefined {
  if (!userId) return undefined
  const normalized = userId.trim()
  if (!normalized) return undefined
  return avatarUrlByUserId?.[normalized]
}

function resolveUserLabel(
  userId: string | null | undefined,
  displayNameByUserId: Record<string, string> | undefined,
): string | undefined {
  if (!userId) return undefined
  const normalized = userId.trim()
  if (!normalized) return undefined
  return displayNameByUserId?.[normalized] ?? normalized
}

export function groupStatesByRisk(
  nodes: PlanningNode[],
  states: NodeStateSnapshot[],
): Array<{ key: string; label: string; nodes: PlanningNode[] }> {
  const stateByNodeId = new Map(states.map((state) => [state.nodeId, state]))
  const groups = [
    { key: 'blocked', label: 'Blocked', nodes: [] as PlanningNode[] },
    { key: 'working', label: 'Working', nodes: [] as PlanningNode[] },
    { key: 'draft', label: 'Draft', nodes: [] as PlanningNode[] },
    { key: 'ready', label: 'Ready', nodes: [] as PlanningNode[] },
    { key: 'done', label: 'Done', nodes: [] as PlanningNode[] },
  ]
  const groupByKey = new Map(groups.map((group) => [group.key, group]))
  for (const node of nodes) {
    const state = stateByNodeId.get(node.id)
    if (state?.runState === 'blocked') {
      groupByKey.get('blocked')?.nodes.push(node)
      continue
    }
    const key = state?.runState ?? node.status
    groupByKey.get(key)?.nodes.push(node)
  }
  return groups.filter((group) => group.nodes.length > 0)
}

function applyPendingProposalOverlay(
  nodes: PlanningNode[],
  proposal?: PlanProposal | null,
): Array<{ node: PlanningNode; previewKind: PlannerPreviewKind }> {
  const overlay = nodes.map((node) => ({ node, previewKind: 'none' as PlannerPreviewKind }))
  if (!proposal) return overlay

  for (const change of proposal.changes) {
    if (change.kind === 'addNode' && change.node) {
      overlay.push({ node: change.node, previewKind: 'added' })
      continue
    }
    if (change.kind === 'updateNode') {
      applyUpdateOverlay(overlay, change)
    }
  }
  return overlay
}

function proposalArtifactsForPreview(proposal?: PlanProposal | null): PlannerArtifact[] {
  if (!proposal) return []
  return proposal.changes.flatMap((change, index): PlannerArtifact[] => {
    if (change.kind !== 'attachArtifact' || !change.artifact) return []
    const nodeId = change.artifact.nodeId ?? change.nodeId
    if (!nodeId) return []
    return [{
      id: `preview-artifact-${proposal.id}-${index}`,
      canvasId: proposal.canvasId,
      nodeId,
      kind: change.artifact.kind,
      title: change.artifact.title,
      reference: change.artifact.reference,
      status: change.artifact.status ?? 'attached',
      createdAt: new Date(0).toISOString(),
      payload: change.artifact.payload,
    }]
  })
}

function applyUpdateOverlay(
  overlay: Array<{ node: PlanningNode; previewKind: PlannerPreviewKind }>,
  change: PlanChange,
) {
  if (!change.nodeId) return
  const index = overlay.findIndex((item) => item.node.id === change.nodeId)
  if (index < 0) return
  overlay[index] = {
    node: {
      ...overlay[index].node,
      title: change.title ?? overlay[index].node.title,
      status: change.status ?? overlay[index].node.status,
      schema: change.schema ?? overlay[index].node.schema,
      contextSources: change.contextSources ?? overlay[index].node.contextSources,
      dependsOnNodeIds: change.dependsOnNodeIds ?? overlay[index].node.dependsOnNodeIds,
      subCanvasId: change.subCanvasId ?? overlay[index].node.subCanvasId,
      nodeKind: change.nodeKind ?? overlay[index].node.nodeKind,
      layout: change.layout ?? overlay[index].node.layout,
      trigger: change.trigger ?? overlay[index].node.trigger,
      executionMode: change.executionMode ?? overlay[index].node.executionMode,
      gate: change.clearGate ? null : (change.gate ?? overlay[index].node.gate),
      dispatch: change.dispatch ?? overlay[index].node.dispatch,
      approvers: change.clearGate ? null : (change.approvers ?? overlay[index].node.approvers),
      artifactRefs: change.artifactRefs ?? overlay[index].node.artifactRefs,
      eventRefs: change.eventRefs ?? overlay[index].node.eventRefs,
      workflowRunState: change.workflowRunState ?? overlay[index].node.workflowRunState,
      sessionId: change.sessionId ?? overlay[index].node.sessionId,
      chatThreadId: change.chatThreadId ?? overlay[index].node.chatThreadId,
      source: change.source ?? overlay[index].node.source,
    },
    previewKind: 'updated',
  }
}

function buildDependencyEdges(
  previewNodes: Array<{ node: PlanningNode; previewKind: PlannerPreviewKind }>,
  perceptionByNodeId: Map<string, PlannerNodePerception>,
  stateEdges?: PlannerGraphStateEdge[],
  onInsertTransform?: (sourceNodeId: string, targetNodeId: string) => void,
): PlannerGraphEdge[] {
  const nodeIds = new Set(previewNodes.map((item) => item.node.id))
  if (stateEdges?.length) {
    return stateEdges
      .filter((edge) => nodeIds.has(edge.sourceNodeId) && nodeIds.has(edge.targetNodeId))
      .map((edge) => edgeFor({
        id: edge.id,
        source: edge.sourceNodeId,
        target: edge.targetNodeId,
        perception: edgePerception(edge.sourceNodeId, edge.targetNodeId, perceptionByNodeId, false),
        preview: false,
        forceAnimated: edge.kind === 'subCanvas',
        onInsertTransform,
      }))
  }
  const edges: PlannerGraphEdge[] = []
  for (const current of previewNodes) {
    for (const dependencyId of current.node.dependsOnNodeIds ?? []) {
      if (!nodeIds.has(dependencyId)) continue
      edges.push(edgeFor({
        id: `planner-edge-${dependencyId}-${current.node.id}`,
        source: dependencyId,
        target: current.node.id,
        perception: edgePerception(dependencyId, current.node.id, perceptionByNodeId, current.previewKind !== 'none'),
        preview: current.previewKind !== 'none',
        onInsertTransform,
      }))
    }
  }

  if (edges.length > 0) return edges
  for (let index = 1; index < previewNodes.length; index += 1) {
    const previous = previewNodes[index - 1]
    const current = previewNodes[index]
    edges.push(edgeFor({
      id: `planner-edge-${previous.node.id}-${current.node.id}`,
      source: previous.node.id,
      target: current.node.id,
      perception: edgePerception(previous.node.id, current.node.id, perceptionByNodeId, current.previewKind !== 'none'),
      preview: current.previewKind !== 'none',
      onInsertTransform,
    }))
  }
  return edges
}

function edgeFor(input: {
  id: string
  source: string
  target: string
  perception: PlannerEdgePerception
  preview: boolean
  forceAnimated?: boolean
  onInsertTransform?: (sourceNodeId: string, targetNodeId: string) => void
}): PlannerGraphEdge {
  return {
    id: input.id,
    source: input.source,
    target: input.target,
    // UI-4: use the transform-insert edge type so hovered edges expose a +
    // button. The renderer falls back to a plain bezier path; behaviour is
    // identical when `onInsertTransform` is undefined or `preview` is true.
    type: 'transformInsert',
    animated: false,
    markerEnd: {
      type: MarkerType.ArrowClosed,
      color: 'rgba(178, 174, 163, 0.62)',
      width: 18,
      height: 18,
    },
    data: {
      preview: input.preview,
      perception: input.perception,
      onInsertTransform: input.onInsertTransform,
      // Preview edges and subCanvas edges should not show the + (would
      // try to mutate a state that doesn't exist yet).
      suppressInsert: input.preview || Boolean(input.forceAnimated),
    },
    className: [
      'planner-flow__edge',
      `planner-flow__edge--${input.perception}`,
      input.preview ? 'planner-flow__edge--preview' : '',
    ].filter(Boolean).join(' '),
  }
}

function edgePerception(
  sourceNodeId: string,
  targetNodeId: string,
  perceptionByNodeId: Map<string, PlannerNodePerception>,
  preview: boolean,
): PlannerEdgePerception {
  if (preview) return 'preview'
  const source = perceptionByNodeId.get(sourceNodeId)
  const target = perceptionByNodeId.get(targetNodeId)
  if (target === 'attention') return 'attention'
  if (source === 'active' || target === 'active') return 'flow'
  if (source === 'done' && target === 'done') return 'done'
  if (target === 'not-reached') return 'not-reached'
  return target ?? 'not-reached'
}

function perceptionForNode(
  node: PlanningNode,
  state: NodeStateSnapshot | null,
  mode: PlannerGraphMode,
  runNodeState: RunNodeState | null,
): PlannerNodePerception {
  if (mode === 'run') {
    switch (runNodeState?.runState) {
      case 'done':
        return 'done'
      case 'failed':
      case 'gate-wait':
      case 'awaiting-input':
      case 'ready_to_start':
        return 'attention'
      case 'dispatched':
      case 'running':
        return 'active'
      case 'pending':
      case undefined:
      case null:
        return runNodeState?.nextAction === 'ready-to-dispatch' ? 'attention' : 'not-reached'
    }
  }

  // 3-tai cut (2026-05-29): node.status no longer contains 'draft' / 'working'
  // (collapsed to ready / blocked / done). state.runState still carries the
  // full NodeRunState union including legacy 'draft' / 'working' for runtime
  // attention surfacing — leave those branches.
  if (state?.runState === 'blocked' || state?.runState === 'draft' || node.status === 'blocked') {
    return 'attention'
  }
  if (state?.runState === 'done' || node.status === 'done') return 'done'
  if (state?.runState === 'working') return 'active'
  return 'not-reached'
}

function buildNodePositions(nodes: PlanningNode[]): Map<string, { x: number; y: number }> {
  const nodeById = new Map(nodes.map((node) => [node.id, node]))
  const depthCache = new Map<string, number>()
  const visiting = new Set<string>()

  const depthFor = (node: PlanningNode): number => {
    const cached = depthCache.get(node.id)
    if (cached !== undefined) return cached
    if (visiting.has(node.id)) return 0
    visiting.add(node.id)
    const depth = Math.max(
      0,
      ...((node.dependsOnNodeIds ?? [])
        .map((dependencyId) => nodeById.get(dependencyId))
        .filter((dependency): dependency is PlanningNode => Boolean(dependency))
        .map((dependency) => depthFor(dependency) + 1)),
    )
    visiting.delete(node.id)
    depthCache.set(node.id, depth)
    return depth
  }

  const nodesByDepth = new Map<number, PlanningNode[]>()
  for (const node of nodes) {
    const depth = depthFor(node)
    const depthNodes = nodesByDepth.get(depth) ?? []
    depthNodes.push(node)
    nodesByDepth.set(depth, depthNodes)
  }

  const positionByNodeId = new Map<string, { x: number; y: number }>()
  for (const [depth, depthNodes] of nodesByDepth) {
    const sorted = [...depthNodes].sort((a, b) => a.title.localeCompare(b.title))
    const startY = -((sorted.length - 1) * 270) / 2
    sorted.forEach((node, row) => {
      positionByNodeId.set(node.id, {
        x: depth * 390,
        y: startY + row * 270,
      })
    })
  }
  return positionByNodeId
}
