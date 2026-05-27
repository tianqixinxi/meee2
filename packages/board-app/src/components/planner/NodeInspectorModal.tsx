import {
  AlertTriangle,
  CalendarClock,
  ExternalLink,
  FileText,
  Layers,
  RefreshCw,
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
import { loadSpawnProvider } from '../../preferences'
import type { TeamMember } from '../../api'
import type {
  NodeContractExternalInput,
  NodeStateSnapshot,
  PlanProposal,
  PlannerAccess,
  PlannerArtifact,
  PlannerDispatchRunner,
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
  onSendToAI?: (message: string, display?: { visibleText?: string; contextLabel?: string }) => void
  onReplaceSession?: (nodeId: string, runner: PlannerDispatchRunner) => void
  /** UI-simplification — open the bound session(replaces the「Open session」 button
   *  that used to live on the node card). Surfaced as a hover-revealed link on
   *  the 进展 group label so it's reachable without cluttering canvas. */
  onOpenSession?: (sessionId: string, nodeId: string) => void
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
  onReplaceSession,
  onOpenSession,
  showOwnerInfo = true,
  visibleIOArtifacts = { inputs: [], outputs: [] },
  onToggleIOArtifact,
  onAttachDataSource,
  onRefreshExternalInput,
  onConfigureDialogue,
}: Props) {
  const [assignOpen, setAssignOpen] = useState(false)
  const [scheduleOpen, setScheduleOpen] = useState(false)
  const [replaceConfirmOpen, setReplaceConfirmOpen] = useState(false)
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
    onSendToAI?.(buildNodeActionPrompt(node, operation), {
      visibleText: operation === 'revise'
        ? 'Revise this node with me.'
        : 'Expand this node into a sub-canvas with me.',
      contextLabel: `Node: ${node.title}`,
    })
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

        {/* UI-simplification §2.9 — three-section reorg: 进展 / 成果 / 足迹.
         *  Existing content is grouped under the new headers without dropping
         *  functionality. Each section's old contents stay; we just give them
         *  semantic group labels so the inspector reads as one progressive
         *  story (where am I / what came out / how did I get here).
         *
         *  Group 1 · 进展(progress): blockers + info grid + AI callout +
         *  next-action.  Group 2 · 成果(output/artifact clipboard): inputs +
         *  output schema + downstream version chain.  Group 3 · 足迹: covered
         *  further down by activity / version history sections (out of view
         *  in this hunk). */}

        <div className="planner-node-modal__group-label planner-node-modal__group-label--progress">
          <span>进展</span>
          <small>progress · session 当前态</small>
          {/* UI-simplification — 「Open session」 hover-revealed shortcut here,
           *  replaces the canvas card button per user spec. Only shown when a
           *  session is bound;按钮在 group label hover 时淡入。 */}
          {node.sessionId && onOpenSession && (
            <button
              type="button"
              className="planner-node-modal__open-session"
              onClick={(e) => {
                e.stopPropagation()
                onOpenSession(node.sessionId!, node.id)
              }}
            >
              → Open session
            </button>
          )}
        </div>

        {/* UI-simplification — 进展 段精简:
         *  - blockers 保留(stuck 提醒优先级最高)
         *  - 原 5-tile info grid(Status/Owner/Gate/Schedule/Type)→ 单 Status tile,
         *    其他维度都在节点卡片 header / mode badge / owner chip 已展示
         *  - next-action 从下面独立块移上来,跟 status 一起在 进展 段
         *  - AI callout 保留(是个核心动作,但 padding 收紧)*/}
        {blockers.length > 0 && (
          <div className="planner-node-modal__blockers">
            {blockers.map((blocker) => (
              <span key={blocker}><AlertTriangle size={12} aria-hidden />{blocker}</span>
            ))}
          </div>
        )}

        {!isTemplate && (
          <div className="planner-node-modal__progress-line">
            <span className={`planner-node-modal__state planner-node-modal__state--${runState}`}>
              {displayRunState(String(runState))}
            </span>
            {nextAction && (
              <span className="planner-node-modal__progress-next">
                <Signpost size={11} aria-hidden /> {nextAction}
              </span>
            )}
          </div>
        )}

        {canUseStepActions && (
          <div className="planner-node-modal__ai-callout">
            <div>
              <span><Sparkles size={12} aria-hidden /> meee2 AI</span>
              <strong>Revise this node with AI</strong>
            </div>
            <button
              type="button"
              className="primary"
              disabled={actionBusy}
              onClick={() => sendNodeActionToAI('revise')}
            >
              <Sparkles size={13} aria-hidden /> Revise
            </button>
          </div>
        )}

        <div className="planner-node-modal__group-label">
          <span>成果 · 剪贴板</span>
          <small>artifacts · inputs / outputs / 版本</small>
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
            {/* UI-simplification — 「Do what」 wide row 移除,信息已在节点 title/desc 体现;
             *  next-action 也不再独立块,已并入 进展 段(.planner-node-modal__progress-line)。 */}
          </div>
        </div>

        {canUseStepActions && (
          <div className="planner-node-modal__section">
            <h3><Sparkles size={13} aria-hidden /> Actions</h3>
            <div className="planner-node-actions__buttons">
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
              {node.sessionId && onReplaceSession && (
                <button
                  type="button"
                  className="planner-node-actions__danger"
                  disabled={actionBusy}
                  onClick={() => {
                    setActionError(null)
                    setReplaceConfirmOpen((value) => !value)
                  }}
                >
                  <RefreshCw size={12} aria-hidden /> Replace session
                </button>
              )}
            </div>
            {replaceConfirmOpen && node.sessionId && (
              <div className="planner-node-actions__panel planner-node-actions__panel--danger">
                <div className="planner-node-actions__warning">
                  <AlertTriangle size={14} aria-hidden />
                  <div>
                    <strong>Replace the bound session?</strong>
                    <p>This detaches the current session and starts a new one for this node. Keep the old session only if you still need its context.</p>
                  </div>
                </div>
                <div className="planner-node-modal__input-editor-actions">
                  <button type="button" disabled={actionBusy} onClick={() => setReplaceConfirmOpen(false)}>
                    Cancel
                  </button>
                  <button
                    type="button"
                    className="primary danger"
                    disabled={actionBusy}
                    onClick={() => {
                      onReplaceSession?.(node.id, dispatchRunnerForNode(node.executorType))
                      onClose()
                    }}
                  >
                    Replace session
                  </button>
                </div>
              </div>
            )}
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

function dispatchRunnerForNode(executorType: PlanningNode['executorType']): PlannerDispatchRunner {
  if (executorType === 'codex') return 'codex'
  if (executorType === 'claude') return 'claude'
  return loadSpawnProvider()
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
