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
      <div className="planner-node__header">
        <span className="planner-node__status">
          <Icon size={14} aria-hidden />
          {runState}
        </span>
        <span
          className={`planner-node__owner-avatar${data.ownerAvatarUrl ? ' has-image' : ''}`}
          title={`Owner: ${data.ownerLabel ?? 'canvas owner'}`}
          aria-label={`Owner: ${data.ownerLabel ?? 'canvas owner'}`}
        >
          {data.ownerAvatarUrl && <img src={data.ownerAvatarUrl} alt="" />}
        </span>
        <span className="planner-node__header-badges">
          {data.previewKind !== 'none' && (
            <span className="planner-node__badge">
              {data.previewKind === 'added' ? 'new' : 'changed'}
            </span>
          )}
          {needsOwnerReview && <span className="planner-node__badge review">review</span>}
        </span>
      </div>

      <div className={`planner-node__kind-label kind-${nodeKind}`}>{kindLabel(nodeKind)}</div>
      <div className="planner-node__title">{node.title}</div>

      {node.gate && (
        <div className="planner-node__gate">
          <Signpost size={12} aria-hidden />
          {node.gate.label}
        </div>
      )}

      <div className="planner-node__meta">
        <span>
          <GitBranch size={12} aria-hidden />
          {executorLabel}
        </span>
        <span>
          <UserRound size={12} aria-hidden />
          Doer {data.doerLabel ?? node.doerId}
        </span>
        {(node.dependsOnNodeIds?.length ?? 0) > 0 && (
          <span>
            <Route size={12} aria-hidden />
            {node.dependsOnNodeIds?.length} deps
          </span>
        )}
      </div>

      {node.sessionId && (
        <div className="planner-node__session-ref">
          session {node.sessionId}
        </div>
      )}

      {artifactRefs.length > 0 && (
        <div className="planner-node__artifacts" aria-label="Artifacts">
          {artifactRefs.slice(0, 2).map((ref) => (
            <span key={ref} title={ref}>
              <FileText size={11} aria-hidden />
              {artifactLabel(ref)}
            </span>
          ))}
          {artifactRefs.length > 2 && <span>+{artifactRefs.length - 2}</span>}
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

      {blockers.length > 0 && (
        <div className="planner-node__blockers">
          <AlertTriangle size={12} aria-hidden />
          <span>{blockers[0]}</span>
          {blockers.length > 1 && <em>+{blockers.length - 1}</em>}
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
  return compact.length > 22 ? `${compact.slice(0, 19)}...` : compact
}
