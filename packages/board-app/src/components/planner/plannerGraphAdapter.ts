import { MarkerType, type Edge, type Node } from '@xyflow/react'
import type {
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

export type PlannerPreviewKind = 'none' | 'added' | 'updated'
export type PlannerNodePerception = 'done' | 'attention' | 'not-reached' | 'active' | 'neutral'
export type PlannerEdgePerception = PlannerNodePerception | 'preview' | 'flow'
export type IOArtifactDirection = 'input' | 'output'
export type IOArtifactKind = 'text' | 'integration' | 'html' | 'kanban'
export interface IOArtifactVisibility {
  inputs: string[]
  outputs: string[]
}
type PlannerGraphMode = 'design' | 'run'

export interface PlannerNodeData extends Record<string, unknown> {
  node: PlanningNode
  state: NodeStateSnapshot | null
  artifacts: PlannerArtifact[]
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
  onOpenDetails?: (nodeId: string) => void
  onOpenSubCanvas?: (canvasId: string) => void
  onOpenKanbanItem?: (artifact: PlannerArtifact, itemId: string, title: string, subCanvasId?: string | null) => void
  onBindInput?: (nodeId: string, input: string, reference: string) => void
  onChangeStatus?: (nodeId: string, status: PlanningNodeStatus) => void
  canChangeStatus?: boolean
  onCreateSession?: (nodeId: string, runner: PlannerDispatchRunner) => void
  onOpenSession?: (sessionId: string, nodeId: string) => void
  onReplaceSession?: (nodeId: string, runner: PlannerDispatchRunner) => void
  onCancelSessionCreation?: (nodeId: string) => void
  onDeleteNode?: (nodeId: string) => void
  onHideIOArtifact?: (nodeId: string, direction: IOArtifactDirection, item: string) => void
  creatingSession?: boolean
}

export type PlannerGraphNode = Node<PlannerNodeData, 'plannerNode'>
export type PlannerGraphEdge = Edge<{ preview: boolean; perception: PlannerEdgePerception }>

interface PlannerGraphInput {
  nodes: PlanningNode[]
  states: NodeStateSnapshot[]
  edges?: PlannerGraphStateEdge[]
  artifacts?: PlannerArtifact[]
  proposal?: PlanProposal | null
  ownerId?: string
  mode: PlannerGraphMode
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
  canChangeStatus?: boolean
  onCreateSession?: (nodeId: string, runner: PlannerDispatchRunner) => void
  onOpenSession?: (sessionId: string, nodeId: string) => void
  onReplaceSession?: (nodeId: string, runner: PlannerDispatchRunner) => void
  onCancelSessionCreation?: (nodeId: string) => void
  onDeleteNode?: (nodeId: string) => void
  onHideIOArtifact?: (nodeId: string, direction: IOArtifactDirection, item: string) => void
  creatingSessionNodeIds?: Set<string>
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
  const positionByNodeId = buildNodePositions(previewNodes.map((item) => item.node))
  const graphNodes = previewNodes.map(({ node, previewKind }, index) => {
    const position = node.layout
      ? { x: node.layout.x, y: node.layout.y }
      : positionByNodeId.get(node.id) ?? {
      x: (index % 3) * 340,
      y: Math.floor(index / 3) * 190,
    }
    return {
      id: node.id,
      type: 'plannerNode' as const,
      position,
      initialWidth: node.layout?.width ?? 320,
      initialHeight: node.layout?.height ?? 238,
      data: {
        node,
        state: stateByNodeId.get(node.id) ?? null,
        artifacts: artifactsByNodeId.get(node.id) ?? [],
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
        onOpenDetails: input.onOpenDetails,
        onOpenSubCanvas: input.onOpenSubCanvas,
        onOpenKanbanItem: input.onOpenKanbanItem,
        onChangeStatus: input.onChangeStatus,
        canChangeStatus: input.canChangeStatus ?? false,
        onCreateSession: input.onCreateSession,
        onOpenSession: input.onOpenSession,
        onReplaceSession: input.onReplaceSession,
        onCancelSessionCreation: input.onCancelSessionCreation,
        onDeleteNode: input.onDeleteNode,
        creatingSession: input.creatingSessionNodeIds?.has(node.id) ?? false,
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
    ...buildDependencyEdges(previewNodes, perceptionByNodeId, input.edges),
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
        return { item, index, direction: 'input' as const, artifact: null, reference: binding?.reference ?? item, inputReference: binding?.reference ?? null }
      })
    const outputCandidates = dedupeIOArtifactItems([
      ...(sourceNode.schema?.outputs ?? []),
      ...(sourceNode.artifactRefs ?? []),
      ...(sourceGraphNode.data.state?.artifactRefs ?? []),
      ...sourceGraphNode.data.artifacts.map((artifact) => artifact.reference),
    ])
    const outputs = visible.outputs
      .filter((item) => outputCandidates.includes(item))
      .map((item, index) => ({
        item,
        index,
        direction: 'output' as const,
        artifact: sourceGraphNode.data.artifacts.find((artifact) =>
          artifact.reference === item || normalizeIOKey(artifact.reference) === normalizeIOKey(item) || normalizeIOKey(artifact.title) === normalizeIOKey(item),
        ) ?? null,
        reference: item,
      }))
    for (const entry of [...inputs, ...outputs]) {
      const id = ioArtifactNodeId(sourceNode.id, entry.direction, entry.item)
      const artifactKind = entry.artifact?.kind === 'kanban' ? 'kanban' : artifactKindFor(entry.reference)
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
            state: null,
            artifacts: entry.artifact ? [entry.artifact] : [],
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
            onHideIOArtifact: input.onHideIOArtifact,
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

function artifactKindFor(value: string): IOArtifactKind {
  const normalized = value.toLowerCase()
  if (normalized.includes('kanban') || normalized.includes('看板')) {
    return 'kanban'
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
      gate: change.gate ?? overlay[index].node.gate,
      dispatch: change.dispatch ?? overlay[index].node.dispatch,
      approvers: change.approvers ?? overlay[index].node.approvers,
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
}): PlannerGraphEdge {
  return {
    id: input.id,
    source: input.source,
    target: input.target,
    type: 'smoothstep',
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

  if (state?.runState === 'blocked' || state?.runState === 'draft' || node.status === 'blocked' || node.status === 'draft') {
    return 'attention'
  }
  if (state?.runState === 'done' || node.status === 'done') return 'done'
  if (state?.runState === 'working' || node.status === 'working') return 'active'
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

  const rowByDepth = new Map<number, number>()
  const positionByNodeId = new Map<string, { x: number; y: number }>()
  for (const node of nodes) {
    const depth = depthFor(node)
    const row = rowByDepth.get(depth) ?? 0
    rowByDepth.set(depth, row + 1)
    positionByNodeId.set(node.id, {
      x: depth * 390,
      y: row * 270,
    })
  }
  return positionByNodeId
}
