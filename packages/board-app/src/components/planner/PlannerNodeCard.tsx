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
import type { PlannerWorkflowRunState } from '../../types'
import type { PlannerGraphNode } from './plannerGraphAdapter'
import { runNextActionLabel } from './RunSelector'

const runStateIcons: Record<PlannerWorkflowRunState, typeof Clock3> = {
  pending: Clock3,
  ready_to_start: PlayCircle,
  dispatched: PlayCircle,
  running: PlayCircle,
  'gate-wait': Signpost,
  done: CheckCircle2,
  failed: AlertTriangle,
}

function runStateClass(runState: PlannerWorkflowRunState): string {
  switch (runState) {
    case 'pending':
      return 'waiting'
    case 'ready_to_start':
    case 'dispatched':
    case 'running':
      return 'running'
    case 'gate-wait':
    case 'failed':
      return 'blocked'
    case 'done':
      return 'done'
  }
}

export function PlannerNodeCard({ data, selected }: NodeProps<PlannerGraphNode>) {
  const node = data.node
  const isRunMode = data.mode === 'run'
  const runNodeState = data.runNodeState
  const nodeKind = designKind(node)
  const designStatus = data.state?.runState ?? node.status
  const runStatus: PlannerWorkflowRunState = runNodeState?.runState ?? 'pending'
  const Icon = isRunMode ? runStateIcons[runStatus] : Route
  const statusLabel = isRunMode ? runStatus : kindLabel(nodeKind)
  const borderClass = isRunMode ? runStateClass(runStatus) : designStatus
  const blockers = data.state?.blockers ?? []
  const needsOwnerReview = Boolean(data.state?.needsOwnerReview)
  const artifactRefs = isRunMode
    ? (runNodeState?.artifactIds ?? [])
    : (node.artifactRefs ?? data.state?.artifactRefs ?? [])
  const sessionId = isRunMode
    ? (runNodeState?.sessionId ?? node.sessionId ?? null)
    : node.sessionId?.trim() || null
  const startingSession = !sessionId && node.workflowRunState === 'dispatched'
  const nextAction = isRunMode
    ? (runNodeState?.nextAction ? runNextActionLabel(runNodeState.nextAction) : null)
    : (node.nextAction?.trim() || null)

  return (
    <div
      className={[
        'planner-node',
        `planner-node--${borderClass}`,
        `planner-node--kind-${nodeKind}`,
        `planner-node--mode-${data.mode}`,
        selected ? 'is-selected' : '',
        data.previewKind !== 'none' ? `planner-node--preview-${data.previewKind}` : '',
      ].filter(Boolean).join(' ')}
    >
      <Handle type="target" position={Position.Left} className="planner-node__handle" />

      <div className="planner-node__header">
        <span className={`planner-node__status${isRunMode ? '' : ' planner-node__status--design'}`}>
          <Icon size={13} aria-hidden />
          {statusLabel}
        </span>
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

      <div className="planner-node__meta" aria-label="Node metadata">
        <span className="planner-node__chip" title={`Owner: ${data.ownerLabel ?? 'canvas owner'}`}>
          <span className={`planner-node__mini-avatar${data.ownerAvatarUrl ? ' has-image' : ''}`} aria-hidden>
            {data.ownerAvatarUrl ? <img src={data.ownerAvatarUrl} alt="" /> : <UserRound size={9} />}
          </span>
          {data.ownerLabel ?? 'Owner'}
        </span>
        <span className="planner-node__chip" title={`Doer: ${data.doerLabel ?? node.doerId}`}>
          <span className={`planner-node__mini-avatar${data.doerAvatarUrl ? ' has-image' : ''}`} aria-hidden>
            {data.doerAvatarUrl ? <img src={data.doerAvatarUrl} alt="" /> : <UserRound size={9} />}
          </span>
          {(data.doerLabel ?? node.doerId) || 'Unassigned'}
        </span>
        {(sessionId || startingSession) && (
          <span className="planner-node__chip is-mono" title={sessionId ? `Session ${sessionId}` : 'Session starting'}>
            <GitBranch size={10} aria-hidden />
            {sessionId ? 'session' : 'starting'}
          </span>
        )}
        {artifactRefs.length > 0 && (
          <span className="planner-node__chip is-artifact" title={artifactRefs.join('\n')}>
            <FileText size={10} aria-hidden />
            {artifactRefs.length} output{artifactRefs.length > 1 ? 's' : ''}
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
          className="planner-node__subcanvas nodrag"
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

      {needsOwnerReview && (
        <div className="planner-node__owner-action">
          <AlertTriangle size={12} aria-hidden />
          Owner action required
        </div>
      )}

      <div className="planner-node__footer">
        <button
          type="button"
          className="planner-node__details nodrag"
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

function designKind(node: PlannerGraphNode['data']['node']): string {
  return node.nodeKind ?? (node.source === 'session' ? 'session' : node.subCanvasId ? 'subCanvas' : 'step')
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
