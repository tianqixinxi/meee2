import { Handle, Position, type NodeProps } from '@xyflow/react'
import { useEffect, useState } from 'react'
import {
  AlertTriangle,
  CalendarClock,
  ChevronDown,
  CheckCircle2,
  Clock3,
  Code2,
  FileText,
  MessageCircle,
  PlayCircle,
  Plug,
  Route,
  Signpost,
  Trash2,
  UserRound,
} from 'lucide-react'
import type {
  PlannerArtifactContent,
  KanbanArtifactPayload,
  PlannerArtifact,
  PlannerDispatchRunner,
  PlannerWorkflowRunState,
  PlanningNodeStatus,
  RunNextAction,
} from '../../types'
import { loadSpawnProvider, spawnProviderLabel } from '../../preferences'
import { getPlannerArtifactContent } from '../../api'
import type { PlannerGraphNode } from './plannerGraphAdapter'

type CanvasArtifactKind = 'text' | 'integration' | 'html' | 'kanban' | 'json' | 'file'
const DESIGN_STATUS_OPTIONS: PlanningNodeStatus[] = ['draft', 'ready', 'blocked', 'done']

interface CanvasIOItem {
  key: string
  label: string
  reference?: string | null
  artifactKind: CanvasArtifactKind
  pending?: boolean
}

const runStateIcons: Record<PlannerWorkflowRunState, typeof Clock3> = {
  pending: Clock3,
  ready_to_start: PlayCircle,
  dispatched: PlayCircle,
  running: PlayCircle,
  'awaiting-input': MessageCircle,
  'gate-wait': Signpost,
  done: CheckCircle2,
  failed: AlertTriangle,
}

function runStateClass(runState: PlannerWorkflowRunState): string {
  switch (runState) {
    case 'pending':
      return 'ready'
    case 'ready_to_start':
      return 'ready'
    case 'dispatched':
    case 'running':
      return 'working'
    case 'awaiting-input':
    case 'gate-wait':
    case 'failed':
      return 'blocked'
    case 'done':
      return 'done'
  }
}

export function PlannerNodeCard({ data, selected }: NodeProps<PlannerGraphNode>) {
  const [artifactInputDraft, setArtifactInputDraft] = useState(data.inputReference ?? '')
  useEffect(() => {
    setArtifactInputDraft(data.inputReference ?? '')
  }, [data.inputReference])
  const node = data.node
  const [deleteArmed, setDeleteArmed] = useState(false)
  useEffect(() => {
    setDeleteArmed(false)
  }, [node.id])
  useEffect(() => {
    if (!deleteArmed) return undefined
    const timer = window.setTimeout(() => setDeleteArmed(false), 2500)
    return () => window.clearTimeout(timer)
  }, [deleteArmed])
  const virtualArtifact = data.virtual && designKind(data.node) === 'artifact'
  const primaryArtifact = virtualArtifact ? selectPrimaryArtifact(data.artifacts) : undefined
  const renderKind = artifactRenderKind(primaryArtifact, data.artifactKind ?? 'text')
  const [artifactContent, setArtifactContent] = useState<PlannerArtifactContent | null>(null)
  const [artifactContentError, setArtifactContentError] = useState<string | null>(null)
  useEffect(() => {
    setArtifactContent(null)
    setArtifactContentError(null)
    if (!virtualArtifact || !primaryArtifact) return undefined
    let cancelled = false
    getPlannerArtifactContent(primaryArtifact.canvasId, primaryArtifact.id)
      .then((content) => {
        if (!cancelled) setArtifactContent(content)
      })
      .catch((error) => {
        if (!cancelled) setArtifactContentError(error?.message || 'Failed to load artifact')
      })
    return () => {
      cancelled = true
    }
  }, [virtualArtifact, primaryArtifact?.canvasId, primaryArtifact?.id])
  const isRunMode = data.mode === 'run'
  const runNodeState = data.runNodeState
  const nodeKind = designKind(node)
  const designStatus = data.state?.runState ?? node.status
  const runStatus: PlannerWorkflowRunState = runNodeState?.runState ?? 'pending'
  const Icon = isRunMode ? runStateIcons[runStatus] : Route
  if (data.virtual && nodeKind === 'artifact') {
    const artifact = primaryArtifact
    const inlineKanban = renderKind === 'kanban'
      ? parseKanbanPayload(artifact?.payload) ?? parseKanbanPayload(artifactContent?.payload)
      : null
    const contentKanban = renderKind === 'kanban'
      ? parseMarkdownKanbanPayload(artifactContent?.content)
      : null
    const kanban = renderKind === 'kanban'
      ? (contentKanban && (inlineKanban?.items.length ?? 0) === 0 ? contentKanban : inlineKanban ?? contentKanban ?? (artifact ? emptyKanbanPayload(node.title) : null))
      : null
    return (
      <div
        className={[
          'planner-node',
          'planner-node--artifact-node',
          `planner-node--artifact-${renderKind}`,
          `planner-node--artifact-${data.artifactDirection ?? 'output'}`,
          selected ? 'is-selected' : '',
        ].filter(Boolean).join(' ')}
      >
        <Handle type="target" position={Position.Left} className="planner-node__handle" />
        <div className="planner-node__header">
          <span className="planner-node__status planner-node__status--design">
            <ArtifactIcon kind={renderKind} size={13} />
            Artifact
          </span>
          <div className="planner-node__header-actions">
            <span className="planner-node__badge kind kind-artifact">
              {data.artifactDirection === 'input' ? 'Input' : 'Output'}
            </span>
            {data.sourceNodeId && data.ioItem && data.artifactDirection && (
              <button
                type="button"
                className="planner-node__delete nodrag"
                title="Remove from canvas"
                aria-label={`Remove ${node.title} from canvas`}
                onClick={(event) => {
                  event.stopPropagation()
                  data.onHideIOArtifact?.(
                    data.sourceNodeId as string,
                    data.artifactDirection as 'input' | 'output',
                    data.ioItem as string,
                  )
                }}
                onPointerDown={(event) => event.stopPropagation()}
              >
                <Trash2 size={13} aria-hidden />
              </button>
            )}
          </div>
        </div>
        <div className="planner-node__title">{node.title}</div>
        {data.artifactDirection !== 'input' && (
          <div className="planner-node__artifact-ref" title={node.schema?.goal || node.title}>
            {node.schema?.goal || node.title}
          </div>
        )}
        {data.artifactDirection === 'input' && data.sourceNodeId && data.ioItem && (
          <div
            className="planner-node__artifact-input nodrag"
            onClick={(event) => event.stopPropagation()}
            onPointerDown={(event) => event.stopPropagation()}
          >
            <textarea
              value={artifactInputDraft}
              onChange={(event) => setArtifactInputDraft(event.target.value)}
              placeholder="Paste document URL or artifact reference"
              rows={3}
            />
            <button
              type="button"
              className="planner-node__artifact-save"
              disabled={artifactInputDraft.trim().length === 0 || artifactInputDraft.trim() === (data.inputReference ?? '').trim()}
              onClick={() => data.onBindInput?.(data.sourceNodeId as string, data.ioItem as string, artifactInputDraft)}
            >
              Save input
            </button>
          </div>
        )}
        <ArtifactPreview
          artifact={artifact}
          kind={renderKind}
          kanban={kanban}
          content={artifactContent}
          error={artifactContentError}
          onOpenKanbanItem={data.onOpenKanbanItem}
        />
        <Handle type="source" position={Position.Right} className="planner-node__handle" />
      </div>
    )
  }
  const statusLabel = isRunMode
    ? workStatusLabel(runStatus, data.hasSelectedDelivery)
    : planStatusLabel(designStatus)
  const borderClass = isRunMode ? runStateClass(runStatus) : designStatus
  const blockers = data.state?.blockers?.length
    ? data.state.blockers
    : node.status === 'blocked' && node.blockedReason?.trim()
      ? [node.blockedReason.trim()]
      : []
  const sessionId = isRunMode
    ? (runNodeState?.sessionId ?? node.sessionId ?? null)
    : node.sessionId?.trim() || null
  const nextAction = isRunMode
    ? nextWorkAction(runNodeState, data.hasSelectedDelivery)
    : nextPlanAction(node, data.responsibleLabel)
  const io = buildCanvasIOItems(data)
  const primaryAction = primaryActionLabel({
    mode: data.mode,
    hasSelectedDelivery: data.hasSelectedDelivery,
    runStatus,
    sessionId,
    workflowRunState: node.workflowRunState ?? null,
    responsibleLabel: data.responsibleLabel,
    nodeKind,
    blockers,
    canCreateSession: Boolean(data.canChangeStatus && data.onCreateSession),
    creatingSession: Boolean(data.creatingSession),
  })
  const primaryActionDisabled = primaryAction === 'Creating session...'
  const showResponsibleInfo = data.showResponsibleInfo ?? true
  const gateLabel = gateModeLabel(node)
  const scheduleEnabled = node.schedule?.enabled === true
  const scheduleLabel = scheduleEnabled ? scheduleIntervalLabel(node.schedule?.intervalSeconds ?? 0) : null

  return (
    <div
      className={[
        'planner-node',
        scheduleEnabled ? 'planner-node--scheduled' : '',
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
        {!isRunMode && nodeKind === 'step' && data.canChangeStatus ? (
          <label
            className="planner-node__status-select nodrag"
            title="Change node status"
            onClick={(event) => event.stopPropagation()}
            onPointerDown={(event) => event.stopPropagation()}
          >
            <Icon size={13} aria-hidden />
            <span>{statusLabel}</span>
            <select
              value={designStatus}
              aria-label={`Status for ${node.title}`}
              onChange={(event) => data.onChangeStatus?.(node.id, event.target.value as PlanningNodeStatus)}
            >
              {DESIGN_STATUS_OPTIONS.map((status) => (
                <option key={status} value={status}>{planStatusLabel(status)}</option>
              ))}
            </select>
            <ChevronDown size={12} aria-hidden />
          </label>
        ) : (
          <span className={`planner-node__status${isRunMode ? '' : ' planner-node__status--design'}`}>
            <Icon size={13} aria-hidden />
            {statusLabel}
          </span>
        )}
        {data.previewKind !== 'none' && (
          <span className="planner-node__badge">
            {data.previewKind === 'added' ? 'new' : 'changed'}
          </span>
        )}
        <div className="planner-node__header-actions">
          {scheduleLabel && (
            <span
              className="planner-node__badge planner-node__badge--schedule"
              title={`Scheduled session tick: ${scheduleLabel}`}
            >
              <CalendarClock size={12} aria-hidden />
              {scheduleLabel}
            </span>
          )}
          {showResponsibleInfo && (
            <span className="planner-node__owner-pill" title={`Owner: ${data.responsibleLabel || 'Unassigned'}`}>
              <span className={`planner-node__mini-avatar${data.responsibleAvatarUrl ? ' has-image' : ''}`} aria-hidden>
                {data.responsibleAvatarUrl ? <img src={data.responsibleAvatarUrl} alt="" /> : <UserRound size={12} />}
              </span>
              <span>{data.responsibleLabel || 'Unassigned'}</span>
            </span>
          )}
        </div>
      </div>

      <div className="planner-node__title">{node.title}</div>

      {nodeKind === 'step' && (
        <div className="planner-node__meta" aria-label="Runtime">
          <span className="planner-node__chip">
            <Code2 size={10} aria-hidden />
            Runtime: {runtimeLabelForNode(node.executorType)}
          </span>
          {scheduleLabel && (
            <span className="planner-node__chip planner-node__chip--schedule" title="This node periodically sends a message to its bound session.">
              <CalendarClock size={10} aria-hidden />
              Scheduled: {scheduleLabel}
            </span>
          )}
          {!isRunMode && data.canChangeStatus && data.onChangeGateMode ? (
            <label
              className="planner-node__chip planner-node__gate-select nodrag nopan"
              title="Change gate mode"
              onClick={(event) => event.stopPropagation()}
            >
              <Signpost size={10} aria-hidden />
              Gate: {gateLabel}
              <select
                value={gateLabel.toLowerCase()}
                aria-label={`Gate mode for ${node.title}`}
                onChange={(event) => data.onChangeGateMode?.(node.id, event.target.value as 'human' | 'auto')}
                onClick={(event) => event.stopPropagation()}
                onPointerDown={(event) => event.stopPropagation()}
              >
                <option value="human">Human</option>
                <option value="auto">Auto</option>
              </select>
              <ChevronDown size={10} aria-hidden />
            </label>
          ) : (
            <span className="planner-node__chip">
              <Signpost size={10} aria-hidden />
              Gate: {gateLabel}
            </span>
          )}
        </div>
      )}

      {nextAction && (
        <div className="planner-node__next-action" title={nextAction}>
          <Signpost size={11} aria-hidden />
          <span>{nextAction}</span>
        </div>
      )}

      {io.hasIO && (
        <div className="planner-node__io" aria-label="Node inputs and outputs">
          <IOColumn title="Input" items={io.inputs} emptyLabel="No input" />
          <IOColumn title="Output" items={io.outputs} emptyLabel="No output" />
        </div>
      )}

      {blockers.length > 0 && (
        <div className="planner-node__blockers">
          <AlertTriangle size={12} aria-hidden />
          <span>{blockers[0]}</span>
          {blockers.length > 1 && <em>+{blockers.length - 1}</em>}
        </div>
      )}

      {(primaryAction || (!data.virtual && data.onDeleteNode)) && (
        <div className="planner-node__footer">
          {primaryAction && (
            <button
              type="button"
              className="planner-node__primary-action nodrag"
              disabled={primaryActionDisabled}
              onClick={(event) => {
                event.stopPropagation()
                if (primaryActionDisabled) return
                if (primaryAction === 'Open sub-flow' && node.subCanvasId) {
                  data.onOpenSubCanvas?.(node.subCanvasId)
                } else if (primaryAction === 'Create session') {
                  data.onCreateSession?.(node.id, dispatchRunnerForNode(node.executorType))
                } else if (primaryAction === 'Open session' && sessionId) {
                  data.onOpenSession?.(sessionId, node.id)
                } else {
                  data.onOpenDetails?.(node.id)
                }
              }}
              aria-label={`${primaryAction} for ${node.title}`}
              title={primaryAction}
            >
              {primaryAction}
            </button>
          )}
          {primaryAction === 'Creating session...' && data.onCancelSessionCreation && (
            <button
              type="button"
              className="planner-node__secondary-action nodrag"
              onClick={(event) => {
                event.stopPropagation()
                data.onCancelSessionCreation?.(node.id)
              }}
              aria-label={`Cancel session creation for ${node.title}`}
              title="Cancel session creation"
            >
              Cancel
            </button>
          )}
          {primaryAction === 'Open session' && data.onReplaceSession && (
            <button
              type="button"
              className="planner-node__secondary-action nodrag"
              onClick={(event) => {
                event.stopPropagation()
                data.onReplaceSession?.(node.id, dispatchRunnerForNode(node.executorType))
              }}
              aria-label={`Replace session for ${node.title}`}
              title="Replace the current session binding"
            >
              Replace session
            </button>
          )}
          {!data.virtual && data.onDeleteNode && (
            <button
              type="button"
              className={`planner-node__delete planner-node__delete--footer nodrag nopan${deleteArmed ? ' is-confirming' : ''}`}
              title={deleteArmed ? 'Click again to delete' : 'Delete node'}
              aria-label={deleteArmed ? `Confirm delete ${node.title}` : `Delete ${node.title}`}
              onClick={(event) => {
                event.stopPropagation()
                event.preventDefault()
                if (!deleteArmed) {
                  setDeleteArmed(true)
                  return
                }
                setDeleteArmed(false)
                data.onDeleteNode?.(node.id, node.title)
              }}
              onPointerDown={(event) => {
                event.stopPropagation()
              }}
              onMouseDown={(event) => {
                event.stopPropagation()
              }}
            >
              <Trash2 size={13} aria-hidden />
              <span>{deleteArmed ? 'Confirm' : 'Delete'}</span>
            </button>
          )}
        </div>
      )}
      <Handle type="source" position={Position.Right} className="planner-node__handle" />
    </div>
  )
}

function IOColumn({
  title,
  items,
  emptyLabel,
}: {
  title: string
  items: CanvasIOItem[]
  emptyLabel: string
}) {
  return (
    <div className="planner-node__io-column">
      <span className="planner-node__io-title">{title}</span>
      <div className="planner-node__io-list">
        {items.length > 0 ? items.map((item) => {
          return (
            <span
              key={item.key}
              className={[
                'planner-node__io-item',
                `is-${item.artifactKind}`,
                item.pending ? 'is-pending' : '',
              ].filter(Boolean).join(' ')}
              title={item.reference || item.label}
            >
              <ArtifactIcon kind={item.artifactKind} size={11} />
              <span>{item.label}</span>
              <em>{item.artifactKind}</em>
            </span>
          )
        }) : (
          <span className="planner-node__io-empty">{emptyLabel}</span>
        )}
      </div>
    </div>
  )
}

function ArtifactIcon({ kind, size }: { kind: CanvasArtifactKind; size: number }) {
  if (kind === 'integration') return <Plug size={size} aria-hidden />
  if (kind === 'html') return <Code2 size={size} aria-hidden />
  if (kind === 'kanban') return <Route size={size} aria-hidden />
  if (kind === 'json' || kind === 'file') return <Code2 size={size} aria-hidden />
  return <FileText size={size} aria-hidden />
}

function ArtifactPreview({
  artifact,
  kind,
  kanban,
  content,
  error,
  onOpenKanbanItem,
}: {
  artifact?: PlannerArtifact
  kind: CanvasArtifactKind
  kanban: KanbanArtifactPayload | null
  content: PlannerArtifactContent | null
  error: string | null
  onOpenKanbanItem?: (artifact: PlannerArtifact, itemId: string, title: string, subCanvasId?: string | null) => void
}) {
  if (!artifact) {
    return <div className="planner-node__artifact-empty">Waiting for output</div>
  }
  if (error) {
    return <div className="planner-node__artifact-empty">{error}</div>
  }
  if (kind === 'kanban' && kanban) {
    return <KanbanArtifactPreview artifact={artifact} payload={kanban} onOpenItem={onOpenKanbanItem} />
  }
  if (kind === 'html') {
    const html = content?.content ?? inlineString(artifact.payload, 'html')
    return html ? (
      <iframe
        className="planner-node__html-preview"
        title={artifact.title}
        sandbox=""
        srcDoc={html}
      />
    ) : (
      <ArtifactMetadata artifact={artifact} content={content} label="HTML artifact" />
    )
  }
  if (kind === 'json') {
    const value = content?.content ?? inlineString(artifact.payload, 'json') ?? JSON.stringify(content?.payload ?? artifact.payload ?? {}, null, 2)
    return <pre className="planner-node__artifact-pre">{value}</pre>
  }
  if (kind === 'integration') {
    return <IntegrationArtifactPreview artifact={artifact} content={content} />
  }
  if (kind === 'file') {
    return <ArtifactMetadata artifact={artifact} content={content} label="File artifact" />
  }
  const text = content?.content ?? inlineString(artifact.payload, 'text')
  return text ? <pre className="planner-node__artifact-pre">{text}</pre> : <ArtifactMetadata artifact={artifact} content={content} label="Text artifact" />
}

function IntegrationArtifactPreview({ artifact, content }: { artifact: PlannerArtifact; content: PlannerArtifactContent | null }) {
  const payload = objectPayload(artifact.payload)
  const url = stringField(payload, 'url') ?? (artifact.reference.includes('://') ? artifact.reference : null)
  const provider = stringField(payload, 'provider') ?? artifact.kind
  const summary = stringField(payload, 'summary') ?? content?.content
  return (
    <div className="planner-node__integration-preview">
      <strong>{provider}</strong>
      {summary && <span>{summary}</span>}
      {url ? (
        <a href={url} target="_blank" rel="noreferrer" onClick={(event) => event.stopPropagation()}>
          {url}
        </a>
      ) : (
        <code>{artifact.reference}</code>
      )}
    </div>
  )
}

function ArtifactMetadata({
  artifact,
  content,
  label,
}: {
  artifact: PlannerArtifact
  content: PlannerArtifactContent | null
  label: string
}) {
  return (
    <div className="planner-node__artifact-meta">
      <strong>{label}</strong>
      <span>{content?.filename ?? artifact.reference}</span>
      {typeof content?.size === 'number' && <small>{formatBytes(content.size)}</small>}
    </div>
  )
}

function KanbanArtifactPreview({
  artifact,
  payload,
  onOpenItem,
}: {
  artifact?: PlannerArtifact
  payload: KanbanArtifactPayload
  onOpenItem?: (artifact: PlannerArtifact, itemId: string, title: string, subCanvasId?: string | null) => void
}) {
  return (
    <div className="planner-node__kanban">
      {payload.columns.map((column) => {
        const items = payload.items.filter((item) => item.columnId === column.id)
        return (
          <section key={column.id} className="planner-node__kanban-column">
            <div className="planner-node__kanban-column-title">
              <span>{column.title}</span>
              <em>{items.length}</em>
            </div>
            <div className="planner-node__kanban-items">
              {items.length > 0 ? items.map((item) => (
                <button
                  key={item.id}
                  type="button"
                  className="planner-node__kanban-item"
                  onClick={(event) => {
                    event.stopPropagation()
                    if (artifact) onOpenItem?.(artifact, item.id, item.title, item.subCanvasId)
                  }}
                >
                  <span>{item.title}</span>
                  {item.description && <small>{item.description}</small>}
                  <em>{item.subCanvasId ? 'Open sub canvas' : 'Create sub canvas'}</em>
                </button>
              )) : (
                <div className="planner-node__kanban-empty">No items</div>
              )}
            </div>
          </section>
        )
      })}
    </div>
  )
}

function artifactRenderKind(artifact: PlannerArtifact | undefined, fallback: CanvasArtifactKind): CanvasArtifactKind {
  const payload = objectPayload(artifact?.payload)
  const type = stringField(payload, 'type')
  if (artifact?.kind === 'kanban') return 'kanban'
  if (type === 'text' || type === 'html' || type === 'kanban' || type === 'integration' || type === 'json' || type === 'file') {
    return type
  }
  return fallback
}

function selectPrimaryArtifact(artifacts: PlannerArtifact[]): PlannerArtifact | undefined {
  return [...artifacts].sort((a, b) => artifactDisplayScore(b) - artifactDisplayScore(a))[0]
}

function artifactDisplayScore(artifact: PlannerArtifact): number {
  const payload = objectPayload(artifact.payload)
  const inlineKanban = parseKanbanPayload(artifact.payload)
  const hasBlob = typeof payload?.blobRef === 'string' && payload.blobRef.trim().length > 0
  const createdAt = Date.parse(String(artifact.createdAt))
  return ((inlineKanban?.items.length ?? 0) > 0 ? 10_000 + inlineKanban!.items.length : 0)
    + (hasBlob ? 5_000 : 0)
    + (payload?.type === 'kanban' ? 2_000 : 0)
    + (artifact.kind === 'kanban' ? 1_000 : 0)
    + ((inlineKanban?.columns.length ?? 0) > 0 ? 100 : 0)
    + (Number.isFinite(createdAt) ? createdAt / 1_000_000_000_000 : 0)
}

function inlineString(payload: unknown, field: 'text' | 'html' | 'json'): string | null {
  const object = objectPayload(payload)
  return stringField(object, field)
}

function objectPayload(payload: unknown): Record<string, unknown> | null {
  return payload && typeof payload === 'object' && !Array.isArray(payload)
    ? payload as Record<string, unknown>
    : null
}

function stringField(object: Record<string, unknown> | null, field: string): string | null {
  const value = object?.[field]
  return typeof value === 'string' && value.trim() ? value : null
}

function formatBytes(value: number): string {
  if (value < 1024) return `${value} B`
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`
  return `${(value / (1024 * 1024)).toFixed(1)} MB`
}

function parseKanbanPayload(payload: unknown): KanbanArtifactPayload | null {
  if (!payload || typeof payload !== 'object') return null
  const candidate = payload as Partial<KanbanArtifactPayload>
  if (candidate.version !== 1 || !Array.isArray(candidate.columns) || !Array.isArray(candidate.items)) {
    return null
  }
  const columns = candidate.columns
    .filter((column): column is { id: string; title: string } =>
      Boolean(column)
      && typeof column.id === 'string'
      && typeof column.title === 'string',
    )
  const items = candidate.items
    .filter((item): item is KanbanArtifactPayload['items'][number] =>
      Boolean(item)
      && typeof item.id === 'string'
      && typeof item.columnId === 'string'
      && typeof item.title === 'string',
    )
    .map((item) => ({
      id: item.id,
      columnId: item.columnId,
      title: item.title,
      description: typeof item.description === 'string' ? item.description : undefined,
      subCanvasId: typeof item.subCanvasId === 'string' ? item.subCanvasId : null,
    }))
  if (columns.length === 0) return null
  return { version: 1, columns, items }
}

function parseMarkdownKanbanPayload(content: string | null | undefined): KanbanArtifactPayload | null {
  if (!content?.trim()) return null
  const tableRows = content
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.startsWith('|') && line.endsWith('|'))
    .map(splitMarkdownTableRow)
  if (tableRows.length < 2) return null

  const header = tableRows[0].map((cell) => cell.toLowerCase())
  const rows = tableRows.slice(1).filter((row) => !isMarkdownSeparatorRow(row))
  const titleIndex = header.findIndex((cell) => cell.includes('idea') || cell.includes('title') || cell.includes('name'))
  if (titleIndex < 0) return null
  const descriptionIndex = header.findIndex((cell) => cell.includes('description') || cell.includes('note') || cell.includes('summary'))
  const priorityIndex = header.findIndex((cell) => cell.includes('priority'))
  const statusIndex = header.findIndex((cell) => cell.includes('status') || cell.includes('column'))

  const columns = new Map<string, { id: string; title: string }>()
  const items: KanbanArtifactPayload['items'] = []
  rows.forEach((row, index) => {
    const title = row[titleIndex]?.trim()
    if (!title) return
    const rawStatus = statusIndex >= 0 ? cleanupMarkdownCell(row[statusIndex]) : ''
    const columnTitle = rawStatus || 'Backlog'
    const columnId = slugifyKanbanId(columnTitle, columns.size + 1)
    if (!columns.has(columnId)) columns.set(columnId, { id: columnId, title: columnTitle })
    const description = descriptionIndex >= 0 ? cleanupMarkdownCell(row[descriptionIndex]) : ''
    const priority = priorityIndex >= 0 ? cleanupMarkdownCell(row[priorityIndex]) : ''
    const details = [
      priority ? `Priority: ${priority}` : '',
      description,
    ].filter(Boolean).join('\n')
    items.push({
      id: `item-${index + 1}`,
      columnId,
      title: cleanupMarkdownCell(title),
      description: details || undefined,
      subCanvasId: null,
    })
  })

  if (items.length === 0 || columns.size === 0) return null
  return { version: 1, columns: Array.from(columns.values()), items }
}

function splitMarkdownTableRow(line: string): string[] {
  return line.slice(1, -1).split('|').map(cleanupMarkdownCell)
}

function isMarkdownSeparatorRow(row: string[]): boolean {
  return row.every((cell) => /^:?-{3,}:?$/.test(cell.trim()))
}

function cleanupMarkdownCell(value: string): string {
  return value
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/\*\*/g, '')
    .trim()
}

function slugifyKanbanId(value: string, fallbackIndex: number): string {
  const slug = value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
  return slug || `column-${fallbackIndex}`
}

function emptyKanbanPayload(title: string): KanbanArtifactPayload {
  return {
    version: 1,
    columns: [
      {
        id: 'idea-list',
        title: title.toLowerCase().includes('idea') ? 'Idea list' : 'List',
      },
    ],
    items: [],
  }
}

function buildCanvasIOItems(data: PlannerGraphNode['data']): {
  inputs: CanvasIOItem[]
  outputs: CanvasIOItem[]
  hasIO: boolean
} {
  const node = data.node
  const schemaInputs = node.schema?.inputs ?? []
  const inputItems = dedupeIOItems([
    ...(schemaInputs.length > 0 ? [] : (node.contextSources ?? []).map((source, index): CanvasIOItem => ({
      key: `context:${source.reference || source.title || index}`,
      label: compactArtifactLabel(source.title || source.reference),
      reference: source.reference,
      artifactKind: classifyArtifactKind(source.reference || source.kind),
    }))),
    ...(schemaInputs.map((input, index): CanvasIOItem => ({
      key: `consume:${input}:${index}`,
      label: compactArtifactLabel(input),
      reference: input,
      artifactKind: classifyArtifactKind(input),
    }))),
  ])

  const actualRefs = dedupeStrings([
    ...(node.artifactRefs ?? []),
    ...(data.state?.artifactRefs ?? []),
    ...data.artifacts.map((artifact) => artifact.reference),
  ])
  const richArtifactsByRef = new Map(data.artifacts.map((artifact) => [artifact.reference, artifact]))
  const actualOutputItems = actualRefs.map((ref, index): CanvasIOItem => {
    const artifact = richArtifactsByRef.get(ref)
    return {
      key: `output:${ref || index}`,
      label: compactArtifactLabel(artifactTitle(artifact, ref)),
      reference: artifact?.reference ?? ref,
      artifactKind: artifactRenderKind(artifact, classifyArtifactKind(artifact?.reference ?? ref)),
    }
  })
  const pendingOutputItems = (node.schema?.outputs ?? [])
    .filter((output) => !actualRefs.some((ref) => artifactMatchesExpectation(ref, output)))
    .map((output, index): CanvasIOItem => ({
      key: `pending:${output}:${index}`,
      label: compactArtifactLabel(output),
      reference: output,
      artifactKind: classifyArtifactKind(output),
      pending: true,
    }))
  const outputItems = dedupeIOItems([...actualOutputItems, ...pendingOutputItems])
  return {
    inputs: inputItems,
    outputs: outputItems,
    hasIO: inputItems.length > 0 || outputItems.length > 0 || (node.schema?.outputs?.length ?? 0) > 0,
  }
}

function artifactTitle(artifact: PlannerArtifact | undefined, fallback: string): string {
  return artifact?.title?.trim() || fallback
}

function dedupeStrings(values: Array<string | null | undefined>): string[] {
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

function dedupeIOItems(items: CanvasIOItem[]): CanvasIOItem[] {
  const seen = new Set<string>()
  const result: CanvasIOItem[] = []
  for (const item of items) {
    const key = `${item.reference || item.label}`.toLowerCase()
    if (seen.has(key)) continue
    seen.add(key)
    result.push(item)
  }
  return result
}

function compactArtifactLabel(value: string): string {
  const trimmed = value.trim()
  if (!trimmed) return 'Untitled'
  const withoutQuery = trimmed.split('?')[0]
  const parts = withoutQuery.split(/[/:#]/).filter(Boolean)
  return parts[parts.length - 1]?.trim() || trimmed
}

function classifyArtifactKind(reference: string): CanvasArtifactKind {
  const normalized = reference.toLowerCase()
  if (normalized.includes('kanban') || normalized.includes('看板')) {
    return 'kanban'
  }
  if (normalized.includes('json') || normalized.endsWith('.json')) {
    return 'json'
  }
  if (normalized.includes('html') || normalized.includes('webpage') || normalized.includes('web-page')) {
    return 'html'
  }
  if (normalized.includes('file') || normalized.includes('attachment')) {
    return 'file'
  }
  if (
    normalized.includes('://')
    || normalized.startsWith('github:')
    || normalized.startsWith('git:')
    || normalized.startsWith('lark:')
    || normalized.startsWith('http:')
    || normalized.startsWith('https:')
  ) {
    return 'integration'
  }
  return 'text'
}

function artifactMatchesExpectation(reference: string, expected: string): boolean {
  const normalize = (value: string) => value
    .toLowerCase()
    .replace(/^[a-z][a-z0-9+.-]*:\/\//, '')
    .replace(/[^a-z0-9]+/g, '')
  const ref = normalize(reference)
  const target = normalize(expected)
  return Boolean(target) && (ref === target || ref.endsWith(target) || ref.includes(target))
}

function planStatusLabel(status: string): string {
  switch (status) {
    case 'draft':
      return 'Draft'
    case 'ready':
      return 'Ready'
    case 'blocked':
      return 'Needs attention'
    case 'done':
      return 'Done'
    case 'working':
      return 'In progress'
    default:
      return 'Draft'
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
    case 'awaiting-input':
      return 'Awaiting your reply'
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
  return node.nextAction?.trim() || 'Review this step'
}

function nextWorkAction(
  runNodeState: PlannerGraphNode['data']['runNodeState'],
  hasSelectedDelivery: boolean,
): string {
  if (!hasSelectedDelivery) return 'Choose a Delivery to see execution state'
  if (!runNodeState?.nextAction) return 'Ready for the next action'
  return runNextActionLabel(runNodeState.nextAction)
}

function runNextActionLabel(action: RunNextAction): string {
  switch (action) {
    case 'waiting-on-upstream':
      return 'Waiting on upstream steps'
    case 'ready-to-dispatch':
      return 'Ready to start'
    case 'in-progress':
      return 'In progress'
    case 'gate-review':
      return 'Awaiting review'
    case 'confirm-artifacts':
      return 'Done - review output'
    case 'needs-attention':
      return 'Needs attention'
  }
}

function primaryActionLabel(input: {
  mode: PlannerGraphNode['data']['mode']
  hasSelectedDelivery: boolean
  runStatus: PlannerWorkflowRunState
  workflowRunState: PlannerWorkflowRunState | null
  sessionId: string | null
  responsibleLabel?: string
  nodeKind: string
  blockers: string[]
  canCreateSession: boolean
  creatingSession: boolean
}): string {
  if (input.mode === 'design') {
    if (input.nodeKind === 'subCanvas') return 'Open sub-flow'
    if (input.nodeKind === 'step') {
      if (input.sessionId) return 'Open session'
      if (input.creatingSession) return 'Creating session...'
      return input.canCreateSession ? 'Create session' : ''
    }
    return ''
  }
  if (!input.hasSelectedDelivery) return 'Select delivery'
  if (!input.responsibleLabel) return 'Assign person'
  if (input.runStatus === 'done') return 'View output'
  if (input.runStatus === 'failed' || input.runStatus === 'gate-wait' || input.blockers.length > 0) {
    return 'Resolve'
  }
  if (input.sessionId) return 'Open session'
  if (input.creatingSession) return 'Creating session...'
  if (input.runStatus === 'ready_to_start' || input.runStatus === 'pending') return 'Open'
  return 'Open'
}

function designKind(node: PlannerGraphNode['data']['node']): string {
  return node.nodeKind ?? (node.source === 'session' ? 'session' : node.subCanvasId ? 'subCanvas' : 'step')
}

function dispatchRunnerForNode(executorType: PlannerGraphNode['data']['node']['executorType']): PlannerDispatchRunner {
  if (executorType === 'codex') return 'codex'
  if (executorType === 'claude') return 'claude'
  return loadSpawnProvider()
}

function runtimeLabelForNode(executorType: PlannerGraphNode['data']['node']['executorType']): string {
  if (executorType === 'codex') return 'Codex'
  if (executorType === 'claude') return 'Claude'
  if (executorType === 'human') return `Default: ${spawnProviderLabel(loadSpawnProvider())}`
  if (executorType === 'mock') return `Default: ${spawnProviderLabel(loadSpawnProvider())}`
  return `${executorType} / fallback ${spawnProviderLabel(loadSpawnProvider())}`
}

function scheduleIntervalLabel(intervalSeconds: number): string {
  const seconds = Math.max(60, Math.round(intervalSeconds || 60))
  if (seconds % 3600 === 0) return `${seconds / 3600}h`
  if (seconds % 60 === 0) return `${seconds / 60}m`
  return `${seconds}s`
}

function gateModeLabel(node: PlannerGraphNode['data']['node']): 'Human' | 'Auto' {
  if (node.executionMode === 'human') return 'Human'
  if ((node.gate?.approvers ?? []).length > 0) return 'Human'
  return 'Auto'
}
