import { Handle, Position, type NodeProps } from '@xyflow/react'
import {
  AlertTriangle,
  CheckCircle2,
  Clock3,
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
  const statusLabel = isRunMode
    ? workStatusLabel(runStatus, data.hasSelectedDelivery)
    : planStatusLabel(designStatus)
  const borderClass = isRunMode ? runStateClass(runStatus) : designStatus
  const blockers = data.state?.blockers ?? []
  const needsOwnerReview = Boolean(data.state?.needsOwnerReview)
  const sessionId = isRunMode
    ? (runNodeState?.sessionId ?? node.sessionId ?? null)
    : node.sessionId?.trim() || null
  const nextAction = isRunMode
    ? nextWorkAction(runNodeState, data.hasSelectedDelivery)
    : nextPlanAction(node, data.responsibleLabel)
  const primaryAction = primaryActionLabel({
    mode: data.mode,
    hasSelectedDelivery: data.hasSelectedDelivery,
    runStatus,
    sessionId,
    responsibleLabel: data.responsibleLabel,
    nodeKind,
    blockers,
    needsOwnerReview,
  })

  return (
    <div
      className={[
        'planner-node',
        `planner-node--${borderClass}`,
        `planner-node--kind-${nodeKind}`,
        `planner-node--mode-${data.mode}`,
        `planner-node--perception-${data.perception}`,
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
      </div>

      <div className="planner-node__title">{node.title}</div>

      <div className="planner-node__responsible" aria-label="Responsible person">
        <span className={`planner-node__person-avatar${data.responsibleAvatarUrl ? ' has-image' : ''}`} aria-hidden>
          {data.responsibleAvatarUrl ? <img src={data.responsibleAvatarUrl} alt="" /> : <UserRound size={13} />}
        </span>
        <span>{data.responsibleLabel || 'Unassigned'}</span>
      </div>

      {nextAction && (
        <div className="planner-node__next-action" title={nextAction}>
          <Signpost size={11} aria-hidden />
          <span>{nextAction}</span>
        </div>
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
          Needs approval
        </div>
      )}

      <div className="planner-node__footer">
        <button
          type="button"
          className="planner-node__primary-action nodrag"
          onClick={(event) => {
            event.stopPropagation()
            if (primaryAction === 'Open sub-flow' && node.subCanvasId) {
              data.onOpenSubCanvas?.(node.subCanvasId)
            } else {
              data.onOpenDetails?.(node.id)
            }
          }}
          aria-label={`${primaryAction} for ${node.title}`}
          title={primaryAction}
        >
          {primaryAction}
        </button>
      </div>
      <Handle type="source" position={Position.Right} className="planner-node__handle" />
    </div>
  )
}

function planStatusLabel(status: string): string {
  switch (status) {
    case 'blocked':
      return 'Needs attention'
    case 'done':
      return 'Done'
    case 'running':
      return 'In progress'
    case 'planning':
      return 'Planning'
    case 'waiting':
    default:
      return 'Not started'
  }
}

function workStatusLabel(status: PlannerWorkflowRunState, hasSelectedDelivery: boolean): string {
  if (!hasSelectedDelivery) return 'Select delivery'
  switch (status) {
    case 'pending':
      return 'Not started'
    case 'ready_to_start':
      return 'Ready'
    case 'dispatched':
    case 'running':
      return 'In progress'
    case 'gate-wait':
    case 'failed':
      return 'Needs attention'
    case 'done':
      return 'Done'
  }
}

function nextPlanAction(node: PlannerGraphNode['data']['node'], responsibleLabel?: string): string {
  if (!responsibleLabel) return 'Assign a responsible person'
  if (node.subCanvasId) return 'Sub-flow available'
  return node.nextAction?.trim() || 'Review the step plan'
}

function nextWorkAction(
  runNodeState: PlannerGraphNode['data']['runNodeState'],
  hasSelectedDelivery: boolean,
): string {
  if (!hasSelectedDelivery) return 'Choose a Delivery to see execution state'
  if (!runNodeState?.nextAction) return 'Ready for the next action'
  return runNextActionLabel(runNodeState.nextAction)
}

function primaryActionLabel(input: {
  mode: PlannerGraphNode['data']['mode']
  hasSelectedDelivery: boolean
  runStatus: PlannerWorkflowRunState
  sessionId: string | null
  responsibleLabel?: string
  nodeKind: string
  blockers: string[]
  needsOwnerReview: boolean
}): string {
  if (input.mode === 'design') {
    if (!input.responsibleLabel) return 'Assign person'
    if (input.nodeKind === 'subCanvas') return 'Open sub-flow'
    return 'Edit plan'
  }
  if (!input.hasSelectedDelivery) return 'Select delivery'
  if (!input.responsibleLabel) return 'Assign person'
  if (input.runStatus === 'done') return 'View output'
  if (input.runStatus === 'failed' || input.runStatus === 'gate-wait' || input.needsOwnerReview || input.blockers.length > 0) {
    return 'Resolve'
  }
  if (input.sessionId || input.runStatus === 'running' || input.runStatus === 'dispatched') return 'Open session'
  if (input.runStatus === 'ready_to_start' || input.runStatus === 'pending') return 'Start work'
  return 'Open'
}

function designKind(node: PlannerGraphNode['data']['node']): string {
  return node.nodeKind ?? (node.source === 'session' ? 'session' : node.subCanvasId ? 'subCanvas' : 'step')
}
