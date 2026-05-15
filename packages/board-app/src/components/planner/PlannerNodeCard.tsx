import { Handle, Position, type NodeProps } from '@xyflow/react'
import {
  AlertTriangle,
  CheckCircle2,
  Clock3,
  ExternalLink,
  GitBranch,
  PlayCircle,
  Route,
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

  return (
    <div
      className={[
        'planner-node',
        `planner-node--${runState}`,
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
        {data.previewKind !== 'none' && (
          <span className="planner-node__badge">
            {data.previewKind === 'added' ? 'new' : 'changed'}
          </span>
        )}
        {node.source === 'session' && <span className="planner-node__badge session">session</span>}
        {needsOwnerReview && <span className="planner-node__badge review">review</span>}
      </div>

      <div className="planner-node__title">{node.title}</div>

      <div className="planner-node__meta">
        <span>
          <GitBranch size={12} aria-hidden />
          {node.executorType} / {node.executionMode}
        </span>
        <span>
          <UserRound size={12} aria-hidden />
          {node.doerId}
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
          {blockers.map((blocker) => (
            <div key={blocker}>{blocker}</div>
          ))}
        </div>
      )}

      <div className="planner-node__io">
        <div>
          <span>Consumes</span>
          {node.ioSchema.consumes.slice(0, 2).join(', ') || 'none'}
        </div>
        <div>
          <span>Produces</span>
          {node.ioSchema.produces.slice(0, 2).join(', ') || 'none'}
        </div>
      </div>
      <Handle type="source" position={Position.Right} className="planner-node__handle" />
    </div>
  )
}
