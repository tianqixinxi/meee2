import type { Edge, Node } from '@xyflow/react'
import type {
  NodeStateSnapshot,
  PlanChange,
  PlanProposal,
  PlannerGraphEdge as PlannerGraphStateEdge,
  PlanningNode,
  RunNodeState,
} from '../../types'
import type { PlannerMode } from './RunSelector'

export type PlannerPreviewKind = 'none' | 'added' | 'updated'

export interface PlannerNodeData extends Record<string, unknown> {
  node: PlanningNode
  state: NodeStateSnapshot | null
  previewKind: PlannerPreviewKind
  /** Design vs Run mode — the card collapses execution fields in Design. */
  mode: PlannerMode
  /** This node's state in the selected run, when one is being viewed. */
  runNodeState: RunNodeState | null
  ownerLabel?: string
  ownerAvatarUrl?: string
  doerLabel?: string
  doerAvatarUrl?: string
  onOpenDetails?: (nodeId: string) => void
  onOpenSubCanvas?: (canvasId: string) => void
}

export type PlannerGraphNode = Node<PlannerNodeData, 'plannerNode'>
export type PlannerGraphEdge = Edge<{ preview: boolean }>

interface PlannerGraphInput {
  nodes: PlanningNode[]
  states: NodeStateSnapshot[]
  edges?: PlannerGraphStateEdge[]
  proposal?: PlanProposal | null
  ownerId?: string
  mode: PlannerMode
  /** nodeId → run state, from the run being viewed (Run mode only). */
  runNodeStates?: Record<string, RunNodeState>
  displayNameByUserId?: Record<string, string>
  avatarUrlByUserId?: Record<string, string>
  onOpenDetails?: (nodeId: string) => void
  onOpenSubCanvas?: (canvasId: string) => void
}

export function buildPlannerGraph(input: PlannerGraphInput): {
  nodes: PlannerGraphNode[]
  edges: PlannerGraphEdge[]
} {
  const stateByNodeId = new Map(input.states.map((state) => [state.nodeId, state]))
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
      initialWidth: node.layout?.width ?? 286,
      initialHeight: node.layout?.height ?? (node.status === 'blocked' ? 170 : 142),
      data: {
        node,
        state: stateByNodeId.get(node.id) ?? null,
        previewKind,
        mode: input.mode,
        runNodeState: input.runNodeStates?.[node.id] ?? null,
        ownerLabel: resolveUserLabel(input.ownerId, input.displayNameByUserId),
        ownerAvatarUrl: resolveUserAvatar(input.ownerId, input.avatarUrlByUserId),
        doerLabel: resolveUserLabel(node.doerId, input.displayNameByUserId),
        doerAvatarUrl: resolveUserAvatar(node.doerId, input.avatarUrlByUserId),
        onOpenDetails: input.onOpenDetails,
        onOpenSubCanvas: input.onOpenSubCanvas,
      },
    }
  })

  const edges = buildDependencyEdges(previewNodes, input.edges)
  return { nodes: graphNodes, edges }
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
    { key: 'blocked', label: 'Blocked / review', nodes: [] as PlanningNode[] },
    { key: 'running', label: 'Running', nodes: [] as PlanningNode[] },
    { key: 'planning', label: 'Planning', nodes: [] as PlanningNode[] },
    { key: 'waiting', label: 'Waiting', nodes: [] as PlanningNode[] },
    { key: 'done', label: 'Done', nodes: [] as PlanningNode[] },
  ]
  const groupByKey = new Map(groups.map((group) => [group.key, group]))
  for (const node of nodes) {
    const state = stateByNodeId.get(node.id)
    if (state?.runState === 'blocked' || state?.needsOwnerReview) {
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
      ioSchema: change.ioSchema ?? overlay[index].node.ioSchema,
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
  stateEdges?: PlannerGraphStateEdge[],
): PlannerGraphEdge[] {
  const nodeIds = new Set(previewNodes.map((item) => item.node.id))
  if (stateEdges?.length) {
    return stateEdges
      .filter((edge) => nodeIds.has(edge.sourceNodeId) && nodeIds.has(edge.targetNodeId))
      .map((edge) => ({
        id: edge.id,
        source: edge.sourceNodeId,
        target: edge.targetNodeId,
        type: 'smoothstep',
        animated: edge.kind === 'subCanvas',
        data: { preview: false },
      }))
  }
  const edges: PlannerGraphEdge[] = []
  for (const current of previewNodes) {
    for (const dependencyId of current.node.dependsOnNodeIds ?? []) {
      if (!nodeIds.has(dependencyId)) continue
      edges.push({
        id: `planner-edge-${dependencyId}-${current.node.id}`,
        source: dependencyId,
        target: current.node.id,
        type: 'smoothstep',
        animated: current.previewKind !== 'none',
        data: {
          preview: current.previewKind !== 'none',
        },
        className: current.previewKind !== 'none' ? 'planner-flow__edge--preview' : undefined,
      })
    }
  }

  if (edges.length > 0) return edges
  for (let index = 1; index < previewNodes.length; index += 1) {
    const previous = previewNodes[index - 1]
    const current = previewNodes[index]
    edges.push({
      id: `planner-edge-${previous.node.id}-${current.node.id}`,
      source: previous.node.id,
      target: current.node.id,
      type: 'smoothstep',
      animated: current.previewKind !== 'none',
      data: {
        preview: current.previewKind !== 'none',
      },
      className: current.previewKind !== 'none' ? 'planner-flow__edge--preview' : undefined,
    })
  }
  return edges
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
      x: depth * 340,
      y: row * 190,
    })
  }
  return positionByNodeId
}
