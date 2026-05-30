/**
 * Shared types + helpers for MonitorSpec card components (PR8).
 *
 * Cards are pure renderers: they receive their typed `config` (already
 * narrowed by `MonitorGrid` via the discriminated `MonitorCard.type`) plus a
 * read-only slice of whatever planner graph state exists today (nodes, run
 * states, attempts, artifacts). They NEVER fetch and NEVER mutate — all
 * structural edits to a MonitorSpec go through the proposal pipeline.
 *
 * Where a card needs data that the backend does not yet provide (real
 * partition data, queue depth, skill invocations, integration probes), it
 * renders a graceful placeholder with the canonical `（待后端接入）` hint via
 * `<CardPending/>` — we do NOT fabricate numbers.
 */

import type {
  MonitorCard,
  NodeStateSnapshot,
  PlannerArtifact,
  PlanningNode,
  ViewerFilter,
} from '../../../types'

/**
 * Read-only context handed to every card. A superset of what any single card
 * needs; cards pick the slices they render from. All fields optional/defaulted
 * so a card degrades gracefully when the host passes a partial slice.
 */
export interface MonitorCardContext {
  canvasId: string
  /** All planner nodes on the canvas, by id (for title / status lookup). */
  nodesById: Record<string, PlanningNode>
  /** Derived run-state snapshots, by nodeId. */
  statesByNodeId: Record<string, NodeStateSnapshot>
  /** Artifacts grouped by nodeId (latest-first is the host's responsibility). */
  artifactsByNodeId: Record<string, PlannerArtifact[]>
  /** The viewer's user id, for `viewerFilter` projection. */
  viewerId?: string | null
}

/** Props passed to a concrete card component. `config` is pre-narrowed. */
export interface MonitorCardProps<C> {
  /** The card's structural row (id, layout, visibility, title). */
  card: MonitorCard
  config: C
  ctx: MonitorCardContext
}

/** Canonical "data not wired yet" copy — keep stable across all cards. */
export const PENDING_BACKEND_HINT = '（待后端接入）'

/** Build the lookup maps a card context needs from raw graph state arrays. */
export function buildMonitorCardContext(input: {
  canvasId: string
  nodes: PlanningNode[]
  states: NodeStateSnapshot[]
  artifacts: PlannerArtifact[]
  viewerId?: string | null
}): MonitorCardContext {
  const nodesById: Record<string, PlanningNode> = {}
  for (const n of input.nodes) nodesById[n.id] = n

  const statesByNodeId: Record<string, NodeStateSnapshot> = {}
  for (const s of input.states) statesByNodeId[s.nodeId] = s

  const artifactsByNodeId: Record<string, PlannerArtifact[]> = {}
  for (const a of input.artifacts) {
    ;(artifactsByNodeId[a.nodeId] ??= []).push(a)
  }

  return {
    canvasId: input.canvasId,
    nodesById,
    statesByNodeId,
    artifactsByNodeId,
    viewerId: input.viewerId ?? null,
  }
}

/**
 * Evaluate a card's `viewerFilter` against a row's identity fields. Returns
 * true when the row should be visible to the current viewer. Render-time
 * projection only — does not touch governance (§6.3).
 */
export function passesViewerFilter(
  filter: ViewerFilter | undefined,
  viewerId: string | null | undefined,
  row: { assigneeId?: string | null; ownerId?: string | null; fields?: Record<string, unknown> },
): boolean {
  if (!filter || filter.kind === 'none') return true
  if (!viewerId) return true // no identity → don't hide anything
  switch (filter.kind) {
    case 'assignee-is-viewer':
      return row.assigneeId === viewerId
    case 'owner-is-viewer':
      return row.ownerId === viewerId
    case 'field-equals-viewer':
      return row.fields?.[filter.fieldPath] === viewerId
    default:
      return true
  }
}
