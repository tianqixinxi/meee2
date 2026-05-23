import {
  AlertTriangle,
  CalendarClock,
  ExternalLink,
  FileText,
  Layers,
  Route,
  Signpost,
  Sparkles,
  UserRound,
  X,
} from 'lucide-react'
import { useState } from 'react'
import {
  proposePlannerGraphChange,
  updatePlannerNodeSchedule,
} from '../../api'
import type { TeamMember } from '../../api'
import type {
  NodeContractExternalInput,
  NodeStateSnapshot,
  PlanProposal,
  PlannerAccess,
  PlannerArtifact,
  PlannerGraphState,
  PlanningNode,
} from '../../types'
import { InputCardSections } from './InputCardSections'
import { visibleOutputReferences, type IOArtifactVisibility } from './plannerGraphAdapter'

interface Props {
  node: PlanningNode
  canvasId: string
  variant?: 'board' | 'template'
  state: NodeStateSnapshot | null
  artifacts?: PlannerArtifact[]
  doerLabel?: string
  access?: PlannerAccess | null
  teamMembers?: TeamMember[]
  onClose: () => void
  onOpenSubCanvas?: (canvasId: string) => void
  onProposalCreated?: (proposal: PlanProposal) => void
  onGraphStateChanged?: (state: PlannerGraphState) => void
  onSendToAI?: (message: string) => void
  showOwnerInfo?: boolean
  visibleIOArtifacts?: IOArtifactVisibility
  onToggleIOArtifact?: (
    nodeId: string,
    direction: keyof IOArtifactVisibility,
    item: string,
    visible: boolean,
  ) => void
  /** UI-4: open the Attach Data Source popover for this node. */
  onAttachDataSource?: (nodeId: string) => void
  /** UI-4: refresh-now per external row. */
  onRefreshExternalInput?: (nodeId: string, external: NodeContractExternalInput) => void
  /** UI-4: configure dialogue retention. */
  onConfigureDialogue?: (nodeId: string) => void
}

export function NodeInspectorModal({
  node,
  canvasId,
  variant = 'board',
  state,
  artifacts = [],
  doerLabel,
  access = null,
  teamMembers = [],
  onClose,
  onOpenSubCanvas,
  onProposalCreated,
  onGraphStateChanged,
  onSendToAI,
  showOwnerInfo = true,
  visibleIOArtifacts = { inputs: [], outputs: [] },
  onToggleIOArtifact,
  onAttachDataSource,
  onRefreshExternalInput,
  onConfigureDialogue,
}: Props) {
  const [assignOpen, setAssignOpen] = useState(false)
  const [scheduleOpen, setScheduleOpen] = useState(false)
  const [scheduleInterval, setScheduleInterval] = useState(() => String(Math.max(1, Math.round((node.schedule?.intervalSeconds ?? 900) / 60))))
  const [schedulePrompt, setSchedulePrompt] = useState(() => node.schedule?.prompt ?? defaultSchedulePrompt(node))
  const [actionBusy, setActionBusy] = useState(false)
  const [actionError, setActionError] = useState<string | null>(null)
  const isTemplate = variant === 'template'
  const nodeKind = node.nodeKind ?? (node.source === 'session' ? 'session' : node.subCanvasId ? 'subCanvas' : 'step')
  const runState = state?.runState ?? node.status
  const blockers = isTemplate
    ? []
    : state?.blockers?.length
      ? state.blockers
      : node.status === 'blocked' && node.blockedReason?.trim()
        ? [node.blockedReason.trim()]
        : []
  // UI-4: the legacy `schema.inputs` slot list + per-input binding editor
  // were removed. Inputs are now rendered through the three-section card
  // (Upstream / External / Dialogue). Outputs continue to use SchemaList.
  // Output slots reconciled with produced artifacts: a concrete artifact
  // fills its templated slot (the `<slug>` template stops showing alongside
  // it), superseded artifacts and the synthetic `…/output` handle are dropped.
  // `state.artifactRefs` carries state-time outputs (e.g. `subcanvas:<id>`)
  // that are not persisted on the node — pass them as runtime refs.
  const outputItems = dedupeStrings(
    visibleOutputReferences(node, artifacts, state?.artifactRefs ?? []),
  )
  const nextAction = node.nextAction?.trim() || null
  const responsibleId = node.doerId?.trim() ?? ''
  const responsibleMember = teamMembers.find((member) => member.userId === responsibleId)
  const responsibleFallback = (doerLabel ?? node.doerId).trim()
  const responsibleLabel = (responsibleMember?.displayName ?? responsibleFallback) || 'Unassigned'
  const role = access?.role ?? 'owner'
  const canAssignOwner = role === 'owner'
  const canShowIOArtifactSwitches = nodeKind === 'step'
  const canUseStepActions = nodeKind === 'step'
  const permissionTooltip = canAssignOwner ? undefined : 'Only the canvas owner can assign this node.'
  const scheduleEnabled = node.schedule?.enabled === true
  const scheduleNextRun = formatScheduleDate(node.schedule?.nextRunAt)

  const runProposalAction = (work: () => Promise<PlanProposal | null>) => {
    setActionBusy(true)
    setActionError(null)
    work()
      .then((proposal) => {
        setActionBusy(false)
        if (!proposal) {
          setActionError('No proposal returned for this action.')
          return
        }
        onProposalCreated?.(proposal)
        onClose()
      })
      .catch((err) => {
        setActionBusy(false)
        setActionError((err as Error).message || 'Action failed')
      })
  }

  const sendNodeActionToAI = (operation: 'revise' | 'expand-sub-canvas') => {
    onSendToAI?.(buildNodeActionPrompt(node, operation))
    onClose()
  }

  const saveSchedule = (enabled: boolean) => {
    const minutes = Math.max(1, Number.parseInt(scheduleInterval, 10) || 15)
    setActionBusy(true)
    setActionError(null)
    updatePlannerNodeSchedule(canvasId, node.id, {
      enabled,
      intervalSeconds: minutes * 60,
      prompt: schedulePrompt.trim(),
    })
      .then((state) => {
        setActionBusy(false)
        onGraphStateChanged?.(state)
        if (!enabled) setScheduleOpen(false)
      })
      .catch((err) => {
        setActionBusy(false)
        setActionError((err as Error).message || 'Schedule was not saved')
      })
  }

  return (
    <div
      className="planner-node-modal-backdrop"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onClose()
      }}
    >
      <div className="planner-node-modal planner-node-modal--info" role="dialog" aria-modal="true" aria-label="Node info">
        <button type="button" className="planner-node-modal__close" onClick={onClose} aria-label="Close node details">
          <X size={15} aria-hidden />
        </button>

        <div className="planner-node-modal__header">
          <div className="planner-node-modal__header-tags">
            {!isTemplate && <span className={`planner-node-modal__state planner-node-modal__state--${runState}`}>{runState}</span>}
            <span className="planner-node-modal__kind">{nodeKind}</span>
          </div>
          <h2>{node.title}</h2>
        </div>

        {blockers.length > 0 && (
          <div className="planner-node-modal__blockers">
            {blockers.map((blocker) => (
              <span key={blocker}><AlertTriangle size={12} aria-hidden />{blocker}</span>
            ))}
          </div>
        )}

        <div className="planner-node-modal__info-grid">
          {!isTemplate && (
            <InfoTile label="Status" value={displayRunState(String(runState))} />
          )}
          {showOwnerInfo && <InfoTile label="Owner" value={responsibleLabel} />}
          <InfoTile label="Gate" value={gateModeLabel(node)} />
          <InfoTile label="Schedule" value={scheduleEnabled ? `Every ${Math.round((node.schedule?.intervalSeconds ?? 60) / 60)}m` : 'Off'} />
          <InfoTile label="Type" value={nodeKind} />
        </div>

        <div className="planner-node-modal__section">
          <h3><Route size={13} aria-hidden /> Inputs</h3>
          <InputCardSections
            node={node}
            variant="modal"
            onAttachDataSource={onAttachDataSource}
            onRefreshExternal={onRefreshExternalInput}
            onConfigureDialogue={onConfigureDialogue}
          />
        </div>

        <div className="planner-node-modal__section">
          <h3><Route size={13} aria-hidden /> Output</h3>
          <div className="planner-node-modal__schema">
            <SchemaList
              title="Outputs"
              items={outputItems}
              empty="No expected output"
              visibleItems={visibleIOArtifacts.outputs}
              switchesEnabled={canShowIOArtifactSwitches}
              onToggle={(item, visible) => onToggleIOArtifact?.(node.id, 'outputs', item, visible)}
            />
            <div className="planner-node-modal__schema-row planner-node-modal__schema-row--wide">
              <span>Do what</span>
              <strong>{node.schema?.goal || nextAction || 'Discuss with meee2 AI to define this step.'}</strong>
            </div>
          </div>
        </div>

        {nextAction && !isTemplate && (
          <div className="planner-node-modal__next-action">
            <Signpost size={13} aria-hidden />
            <div><em>Next step</em><strong>{nextAction}</strong></div>
          </div>
        )}

        {canUseStepActions && (
          <div className="planner-node-modal__section">
            <h3><Sparkles size={13} aria-hidden /> Actions</h3>
            <div className="planner-node-actions__buttons">
              <button
                type="button"
                className="primary"
                disabled={actionBusy}
                onClick={() => sendNodeActionToAI('revise')}
              >
                <Sparkles size={12} aria-hidden /> Revise with AI
              </button>
              <button
                type="button"
                disabled={actionBusy}
                onClick={() => sendNodeActionToAI('expand-sub-canvas')}
              >
                <Layers size={12} aria-hidden /> Expand sub-canvas
              </button>
              {showOwnerInfo && (
                <button
                  type="button"
                  disabled={actionBusy || !canAssignOwner}
                  title={permissionTooltip}
                  onClick={() => {
                    setActionError(null)
                    setAssignOpen((value) => !value)
                  }}
                >
                  <UserRound size={12} aria-hidden /> Assign owner
                </button>
              )}
              <button
                type="button"
                disabled={actionBusy || !node.sessionId}
                title={node.sessionId ? undefined : 'Create or bind a session before scheduling this node.'}
                onClick={() => {
                  setActionError(null)
                  setScheduleOpen((value) => !value)
                }}
              >
                <CalendarClock size={12} aria-hidden /> Schedule session
              </button>
            </div>
            {scheduleOpen && (
              <div className="planner-node-actions__panel planner-node-actions__panel--schedule">
                <label>
                  <span>Every</span>
                  <input
                    type="number"
                    min={1}
                    max={1440}
                    value={scheduleInterval}
                    disabled={actionBusy}
                    onChange={(event) => setScheduleInterval(event.target.value)}
                  />
                  <em>minutes</em>
                </label>
                <textarea
                  value={schedulePrompt}
                  disabled={actionBusy}
                  rows={5}
                  onChange={(event) => setSchedulePrompt(event.target.value)}
                />
                {scheduleEnabled && scheduleNextRun && (
                  <p className="planner-node-actions__schedule-note">Next tick: {scheduleNextRun}</p>
                )}
                <div className="planner-node-modal__input-editor-actions">
                  {scheduleEnabled && (
                    <button type="button" disabled={actionBusy} onClick={() => saveSchedule(false)}>
                      Turn off
                    </button>
                  )}
                  <button
                    type="button"
                    className="primary"
                    disabled={actionBusy || schedulePrompt.trim().length === 0}
                    onClick={() => saveSchedule(true)}
                  >
                    {scheduleEnabled ? 'Save schedule' : 'Turn on schedule'}
                  </button>
                </div>
              </div>
            )}
            {showOwnerInfo && assignOpen && (
              <div className="planner-node-actions__panel">
                {teamMembers.length === 0 ? (
                  <p className="planner-node-modal__empty">No team members available to assign.</p>
                ) : (
                  <div className="planner-node-actions__members">
                    {teamMembers.map((member) => {
                      const current = member.userId === responsibleId
                      return (
                        <button
                          key={member.userId}
                          type="button"
                          className={`planner-node-actions__member${current ? ' is-current' : ''}`}
                          disabled={actionBusy || current}
                          onClick={() => {
                            runProposalAction(() =>
                              proposePlannerGraphChange(canvasId, {
                                summary: `Assign ${member.displayName} as owner of ${node.title}`,
                                changes: [{ kind: 'updateNode', nodeId: node.id, doerId: member.userId }],
                              }),
                            )
                          }}
                        >
                          <span className="planner-node-modal__avatar" aria-hidden>
                            {member.avatarUrl ? <img src={member.avatarUrl} alt="" /> : <UserRound size={12} />}
                          </span>
                          <span>{member.displayName}</span>
                          {current && <em>current</em>}
                        </button>
                      )
                    })}
                  </div>
                )}
              </div>
            )}
            {actionError && <p className="planner-node-actions__error">{actionError}</p>}
          </div>
        )}

        {node.subCanvasId && (
          <button
            type="button"
            className="planner-node-modal__subcanvas"
            onClick={() => {
              onOpenSubCanvas?.(node.subCanvasId as string)
              onClose()
            }}
          >
            <ExternalLink size={13} aria-hidden /> Open sub-flow
          </button>
        )}
      </div>
    </div>
  )
}

function InfoTile({ label, value }: { label: string; value: string }) {
  return (
    <div className="planner-node-modal__info-tile">
      <em>{label}</em>
      <strong>{value}</strong>
    </div>
  )
}

// UI-4: SchemaList is now Output-only. The Input axis is rendered via
// `InputCardSections` (Upstream / External / Dialogue). All field-level
// binding props (`inputBindings`, `editingItem`, `onSaveInput`, etc.) were
// removed; ENG-1's contract validator rejects field-level mapping anyway.
function SchemaList({
  title,
  items,
  empty,
  visibleItems = [],
  switchesEnabled = false,
  onToggle,
}: {
  title: string
  items: string[]
  empty: string
  visibleItems?: string[]
  switchesEnabled?: boolean
  onToggle?: (item: string, visible: boolean) => void
}) {
  const normalized = dedupeStrings(items)
  const visibleSet = new Set(visibleItems.map((item) => item.trim()).filter(Boolean))
  return (
    <div className="planner-node-modal__schema-row">
      <span>{title}</span>
      {normalized.length > 0 ? (
        <div className="planner-node-modal__schema-chips">
          {normalized.map((item) => {
            const checked = visibleSet.has(item)
            return (
              <div key={item} className="planner-node-modal__schema-item">
                <div className="planner-node-modal__schema-item-main">
                  <strong title={item}><FileText size={11} aria-hidden />{compactLabel(item)}</strong>
                </div>
                {switchesEnabled && (
                  <button
                    type="button"
                    className={`planner-node-modal__switch${checked ? ' is-on' : ''}`}
                    aria-pressed={checked}
                    aria-label={`${checked ? 'Hide' : 'Show'} ${item} as artifact node`}
                    onClick={() => onToggle?.(item, !checked)}
                  >
                    <span />
                  </button>
                )}
              </div>
            )
          })}
        </div>
      ) : (
        <strong>{empty}</strong>
      )}
    </div>
  )
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

function buildNodeActionPrompt(node: PlanningNode, operation: 'revise' | 'expand-sub-canvas'): string {
  const tag = `@node:${node.id}`
  const opTag = operation === 'revise' ? '#revise' : '#expand-sub-canvas'
  const input = (node.schema?.inputs ?? []).join(', ') || 'none'
  const output = (node.schema?.outputs ?? []).join(', ') || 'none'
  const doWhat = node.schema?.goal || node.nextAction || node.title
  return [
    `${tag} ${opTag}`,
    `Node: ${node.title}`,
    `Inputs: ${input}`,
    `Outputs: ${output}`,
    `Do what: ${doWhat}`,
    '',
    operation === 'revise'
      ? 'Revise this node with me.'
      : 'Expand this node into a sub-canvas with me.',
  ].join('\n')
}

function defaultSchedulePrompt(node: PlanningNode): string {
  return [
    'Scheduled meee2 planner tick.',
    `Node ID: ${node.id}`,
    `Node: ${node.title}`,
    `Goal: ${node.schema?.goal || node.title}`,
    'Call read_node_contract first. If this tick produces new output, call submit_node_output; if there is nothing to update, reply with a brief status summary.',
  ].join('\n')
}

function formatScheduleDate(value: string | number | null | undefined): string | null {
  if (value == null) return null
  const date = typeof value === 'number' ? new Date(value * 1000) : new Date(value)
  if (Number.isNaN(date.getTime())) return null
  return date.toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })
}

function compactLabel(value: string): string {
  const withoutQuery = value.trim().split('?')[0]
  const parts = withoutQuery.split(/[/:#]/).filter(Boolean)
  return parts[parts.length - 1]?.trim() || value
}

function gateModeLabel(node: PlanningNode): 'Human' | 'Auto' {
  if (node.executionMode === 'human') return 'Human'
  if ((node.gate?.approvers ?? []).length > 0) return 'Human'
  return 'Auto'
}

function displayRunState(runState: string): string {
  switch (runState) {
    case 'dispatched':
      return 'starting'
    case 'ready_to_start':
      return 'ready to start'
    case 'gate-wait':
      return 'review output'
    case 'awaiting-input':
      return 'awaiting your reply'
    default:
      return runState.replace(/_/g, ' ')
  }
}
