import { Handle, Position, type NodeProps } from '@xyflow/react'
import {
  AlertTriangle,
  CheckCircle2,
  Clock3,
  ExternalLink,
  FileText,
  GitBranch,
  Info,
  PlayCircle,
  Route,
  Signpost,
  UserRound,
} from 'lucide-react'
import type { PlannerGraphNode } from './plannerGraphAdapter'

const statusIcons = {
  blocked: AlertTriangle,
  running: PlayCircle,
  planning: Route,
  waiting: Clock3,
  done: CheckCircle2,
}

export function PlannerNodeCard({ data, selected }: NodeProps<PlannerGraphNode>) {
  const node = data.node
  const runState = data.state?.runState ?? node.status
  const Icon = statusIcons[runState]
  const blockers = data.state?.blockers ?? []
  const needsOwnerReview = Boolean(data.state?.needsOwnerReview)
  const executorLabel = node.executorType === 'mock' ? 'local' : node.executorType
  const nodeKind = node.nodeKind ?? (node.source === 'session' ? 'session' : node.subCanvasId ? 'subCanvas' : 'step')
  const artifactRefs = node.artifactRefs ?? data.state?.artifactRefs ?? []
  const depCount = node.dependsOnNodeIds?.length ?? 0
  // Phase 6 — server-derived workflow-guidance line. Read-only; never edited here.
  const nextAction = node.nextAction?.trim() || null

  return (
    <div
      className={[
        'planner-node',
        `planner-node--${runState}`,
        `planner-node--kind-${nodeKind}`,
        selected ? 'is-selected' : '',
        data.previewKind !== 'none' ? `planner-node--preview-${data.previewKind}` : '',
      ].filter(Boolean).join(' ')}
    >
      <Handle type="target" position={Position.Left} className="planner-node__handle" />

      {/* Primary row: status + kind tag stay prominent, owner avatar anchored right. */}
      <div className="planner-node__header">
        <span className="planner-node__status">
          <Icon size={13} aria-hidden />
          {runState}
        </span>
        <span className={`planner-node__kind-tag kind-${nodeKind}`}>{kindLabel(nodeKind)}</span>
        {data.previewKind !== 'none' && (
          <span className="planner-node__badge">
            {data.previewKind === 'added' ? 'new' : 'changed'}
          </span>
        )}
        <span
          className={`planner-node__owner-avatar${data.ownerAvatarUrl ? ' has-image' : ''}`}
          title={`Owner: ${data.ownerLabel ?? 'canvas owner'}`}
          aria-label={`Owner: ${data.ownerLabel ?? 'canvas owner'}`}
        >
          {data.ownerAvatarUrl ? <img src={data.ownerAvatarUrl} alt="" /> : <UserRound size={12} aria-hidden />}
        </span>
      </div>

      <div className="planner-node__title">{node.title}</div>

      {node.gate && (
        <div className="planner-node__gate">
          <Signpost size={11} aria-hidden />
          {node.gate.label}
        </div>
      )}

      {/* Secondary metadata compacted into a single wrapping chip row. */}
      <div className="planner-node__meta" aria-label="Node metadata">
        <span className="planner-node__chip" title={`Owner: ${data.ownerLabel ?? 'canvas owner'}`}>
          <UserRound size={10} aria-hidden />
          {data.ownerLabel ?? 'Owner'}
        </span>
        <span className="planner-node__chip" title={`Doer: ${data.doerLabel ?? node.doerId}`}>
          <UserRound size={10} aria-hidden />
          {data.doerLabel ?? node.doerId}
        </span>
        <span className="planner-node__chip" title={`Executor: ${executorLabel}`}>
          <GitBranch size={10} aria-hidden />
          {executorLabel}
        </span>
        {depCount > 0 && (
          <span className="planner-node__chip" title={`${depCount} dependencies`}>
            <Route size={10} aria-hidden />
            {depCount} deps
          </span>
        )}
        {node.sessionId && (
          <span className="planner-node__chip is-mono" title={`Session ${node.sessionId}`}>
            {node.sessionId}
          </span>
        )}
        {artifactRefs.length > 0 && (
          <span
            className="planner-node__chip is-artifact"
            title={artifactRefs.join('\n')}
          >
            <FileText size={10} aria-hidden />
            {artifactLabel(artifactRefs[0])}
            {artifactRefs.length > 1 && ` +${artifactRefs.length - 1}`}
          </span>
        )}
      </div>

      {nextAction && (
        <div className="planner-node__next-action" title={nextAction}>
          <Signpost size={11} aria-hidden />
          <span>{nextAction}</span>
        </div>
      )}

      {node.subCanvasId && (
        <button
          type="button"
          className="planner-node__subcanvas"
          onClick={(event) => {
            event.stopPropagation()
            data.onOpenSubCanvas?.(node.subCanvasId as string)
          }}
          title="Open sub-canvas"
        >
          <ExternalLink size={12} aria-hidden />
          Open sub-canvas
        </button>
      )}

      {/* Status-critical alerts kept full-width and prominent. */}
      {blockers.length > 0 && (
        <div className="planner-node__blockers">
          <AlertTriangle size={12} aria-hidden />
          <span>{blockers[0]}</span>
          {blockers.length > 1 && <em>+{blockers.length - 1}</em>}
        </div>
      )}

      {needsOwnerReview && (
        <div className="planner-node__owner-action">
          <AlertTriangle size={12} aria-hidden />
          Owner action required
        </div>
      )}

      <div className="planner-node__footer">
        <span>{node.executionMode}</span>
        <button
          type="button"
          className="planner-node__details"
          onClick={(event) => {
            event.stopPropagation()
            data.onOpenDetails?.(node.id)
          }}
          aria-label={`Open details for ${node.title}`}
          title="Node details"
        >
          <Info size={12} aria-hidden />
          Details
        </button>
      </div>
      <Handle type="source" position={Position.Right} className="planner-node__handle" />
    </div>
  )
}

function kindLabel(kind: string): string {
  switch (kind) {
    case 'session':
      return 'session'
    case 'artifact':
      return 'artifact'
    case 'subCanvas':
      return 'sub-canvas'
    case 'external':
      return 'external'
    case 'step':
    default:
      return 'step'
  }
}

function artifactLabel(ref: string): string {
  const compact = ref.split('/').filter(Boolean).pop() ?? ref
  return compact.length > 18 ? `${compact.slice(0, 15)}...` : compact
}
