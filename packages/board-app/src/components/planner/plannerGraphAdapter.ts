import type { Edge, Node } from '@xyflow/react'
import type {
  NodeStateSnapshot,
  PlanChange,
  PlanProposal,
  PlanningNode,
} from '../../types'

export type PlannerPreviewKind = 'none' | 'added' | 'updated'

export interface PlannerNodeData extends Record<string, unknown> {
  node: PlanningNode
  state: NodeStateSnapshot | null
  previewKind: PlannerPreviewKind
}

export type PlannerGraphNode = Node<PlannerNodeData, 'plannerNode'>
export type PlannerGraphEdge = Edge<{ preview: boolean }>

interface PlannerGraphInput {
  nodes: PlanningNode[]
  states: NodeStateSnapshot[]
  proposal?: PlanProposal | null
}

export function buildPlannerGraph(input: PlannerGraphInput): {
  nodes: PlannerGraphNode[]
  edges: PlannerGraphEdge[]
} {
  const stateByNodeId = new Map(input.states.map((state) => [state.nodeId, state]))
  const previewNodes = applyPendingProposalOverlay(input.nodes, input.proposal)
  const graphNodes = previewNodes.map(({ node, previewKind }, index) => {
    const column = index % 3
    const row = Math.floor(index / 3)
    return {
      id: node.id,
      type: 'plannerNode' as const,
      position: {
        x: column * 340,
        y: row * 190,
      },
      data: {
        node,
        state: stateByNodeId.get(node.id) ?? null,
        previewKind,
      },
    }
  })

  const edges: PlannerGraphEdge[] = []
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
  return { nodes: graphNodes, edges }
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
    },
    previewKind: 'updated',
  }
}
