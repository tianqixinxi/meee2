import {
  AlertTriangle,
  ExternalLink,
  FileText,
  GitBranch,
  GitPullRequest,
  Layers,
  MessageSquareText,
  Plus,
  Rocket,
  Route,
  Signpost,
  Sparkles,
  UserRound,
  X,
} from 'lucide-react'
import { useEffect, useMemo, useState } from 'react'
import {
  bindPlannerSessionToNode,
  createPlannerSubCanvasFromNode,
  dispatchPlannerNodeSession,
  fetchPlannerNodeContract,
  proposePlannerGraphChange,
  refinePlannerNode,
  submitPlannerNodeOutput,
} from '../../api'
import type { TeamMember } from '../../api'
import type {
  NodeStateSnapshot,
  PlanProposal,
  PlannerAccess,
  PlannerArtifactKind,
  PlannerDispatchRunner,
  PlannerGraphState,
  PlannerNodeContract,
  PlannerNodeOutputNext,
  PlannerNodeOutputStatus,
  PlanningNode,
  Session,
} from '../../types'
import { IntegrationArtifactPicker } from '../IntegrationArtifactPicker'
import type { PlannerMode } from './RunSelector'
import { SessionPicker } from './SessionPicker'

const DISPATCH_RUNNERS: { value: PlannerDispatchRunner; label: string }[] = [
  { value: 'claude', label: 'Claude' },
  { value: 'codex', label: 'Codex' },
  { value: 'human', label: 'Human task' },
]

const ARTIFACT_KINDS: PlannerArtifactKind[] = [
  'prd',
  'impl-pr',
  'check-result',
  'main-merge',
  'lark-doc',
  'idea-draft',
  'prerelease-verdict',
  'generic',
]

type InspectorTab = 'execution' | 'plan' | 'evidence'
type ActionPanel = 'start' | 'bind' | 'subCanvas' | 'refine' | 'doer'

interface Props {
  node: PlanningNode
  canvasId: string
  mode: PlannerMode
  state: NodeStateSnapshot | null
  ownerLabel?: string
  ownerAvatarUrl?: string
  doerLabel?: string
  access?: PlannerAccess | null
  sessions?: Session[]
  teamMembers?: TeamMember[]
  onClose: () => void
  onOpenSubCanvas?: (canvasId: string) => void
  onArtifactAttached?: () => void
  onProposalCreated?: (proposal: PlanProposal) => void
  onNodeMutated?: (state: PlannerGraphState) => void
}

export function NodeInspectorModal({
  node,
  canvasId,
  mode,
  state,
  ownerLabel,
  ownerAvatarUrl,
  doerLabel,
  access = null,
  sessions = [],
  teamMembers = [],
  onClose,
  onOpenSubCanvas,
  onArtifactAttached,
  onProposalCreated,
  onNodeMutated,
}: Props) {
  const [activeTab, setActiveTab] = useState<InspectorTab>('execution')
  const [openPanel, setOpenPanel] = useState<ActionPanel | null>(null)
  const [actionBusy, setActionBusy] = useState(false)
  const [actionError, setActionError] = useState<string | null>(null)
  const [dispatchRunner, setDispatchRunner] = useState<PlannerDispatchRunner>('claude')
  const [subCanvasTitle, setSubCanvasTitle] = useState('')
  const [refineReason, setRefineReason] = useState('')
  const [attachProvider, setAttachProvider] = useState<'github' | 'lark' | null>(null)
  const [contract, setContract] = useState<PlannerNodeContract | null>(null)
  const [outputSummary, setOutputSummary] = useState('')
  const [outputReference, setOutputReference] = useState('')
  const [outputTitle, setOutputTitle] = useState('')
  const [outputKind, setOutputKind] = useState<PlannerArtifactKind>('generic')
  const [outputStatus, setOutputStatus] = useState<PlannerNodeOutputStatus>('done')
  const [outputNext, setOutputNext] = useState<PlannerNodeOutputNext>('complete')
  const [routeTo, setRouteTo] = useState<string[]>([])

  const runState = state?.runState ?? node.status
  const nodeKind = node.nodeKind ?? (node.source === 'session' ? 'session' : node.subCanvasId ? 'subCanvas' : 'step')
  const artifactRefs = node.artifactRefs ?? state?.artifactRefs ?? []
  const blockers = state?.blockers ?? []
  const consumes = node.ioSchema?.consumes ?? []
  const produces = node.ioSchema?.produces ?? []
  const deps = node.dependsOnNodeIds ?? []
  const runnerLabel = displayRunner(node.dispatch?.runner ?? null)
  const nextAction = node.nextAction?.trim() || null
  const activeSessionId = node.sessionId?.trim() || null
  const isDesignMode = mode === 'design'
  const isRunMode = mode === 'run'

  const role = access?.role ?? 'owner'
  const isOwner = role === 'owner'
  const isAssignedDoer = role === 'doer' && Boolean(access?.actorId) && node.doerId === access?.actorId
  const canActOnNode = isOwner || isAssignedDoer
  const permissionTooltip = canActOnNode
    ? undefined
    : role === 'viewer'
      ? 'Viewers cannot change planner nodes.'
      : 'Only the canvas owner or this node’s assigned doer can run node actions.'
  const isStepNode = nodeKind === 'step'

  useEffect(() => {
    let cancelled = false
    fetchPlannerNodeContract(canvasId, node.id)
      .then((next) => {
        if (cancelled) return
        setContract(next)
        const first = next.allowedRouteTargets.find((target) => target.id !== 'owner')
        setRouteTo(first ? [first.id] : ['owner'])
      })
      .catch(() => {
        if (!cancelled) setContract(null)
      })
    return () => {
      cancelled = true
    }
  }, [canvasId, node.id])

  const routeTargets = useMemo(() => contract?.allowedRouteTargets ?? [{
    id: 'owner',
    label: 'Canvas owner',
    kind: 'owner',
    hasDoer: true,
    hasSession: false,
  }], [contract])

  const finishProposal = (proposal: PlanProposal | null) => {
    setActionBusy(false)
    if (!proposal) {
      setActionError('No proposal returned for this action.')
      return
    }
    setOpenPanel(null)
    onProposalCreated?.(proposal)
    onClose()
  }

  const runProposalAction = (work: () => Promise<PlanProposal | null>) => {
    setActionBusy(true)
    setActionError(null)
    work()
      .then(finishProposal)
      .catch((err) => {
        setActionBusy(false)
        setActionError((err as Error).message || 'Action failed')
      })
  }

  const runDirectAction = (work: () => Promise<PlannerGraphState>) => {
    setActionBusy(true)
    setActionError(null)
    work()
      .then((state) => {
        setActionBusy(false)
        setOpenPanel(null)
        onNodeMutated?.(state)
        onClose()
      })
      .catch((err) => {
        setActionBusy(false)
        setActionError((err as Error).message || 'Action failed')
      })
  }

  const togglePanel = (panel: ActionPanel) => {
    setActionError(null)
    setOpenPanel((current) => (current === panel ? null : panel))
  }

  const submitOutput = () => {
    const summary = outputSummary.trim()
    const reference = outputReference.trim()
    if (!summary && !reference) {
      setActionError('Add a message summary or output reference.')
      return
    }
    setActionBusy(true)
    setActionError(null)
    submitPlannerNodeOutput(canvasId, node.id, {
      nodeId: node.id,
      status: outputStatus,
      message: summary ? { summary, routeTo } : null,
      artifacts: reference ? [{
        kind: outputKind,
        title: outputTitle.trim() || reference,
        reference,
        routeTo,
      }] : [],
      next: outputNext,
    })
      .then((result) => {
        setActionBusy(false)
        onNodeMutated?.(result.graph)
        onClose()
      })
      .catch((err) => {
        setActionBusy(false)
        setActionError((err as Error).message || 'Output was not accepted')
      })
  }

  return (
    <div
      className="planner-node-modal-backdrop"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onClose()
      }}
    >
      <div className="planner-node-modal" role="dialog" aria-modal="true" aria-label="Node details">
        <button type="button" className="planner-node-modal__close" onClick={onClose} aria-label="Close node details">
          <X size={15} aria-hidden />
        </button>

        <div className="planner-node-modal__header">
          <div className="planner-node-modal__header-tags">
            <span className={`planner-node-modal__state planner-node-modal__state--${runState}`}>{runState}</span>
            <span className="planner-node-modal__kind">{nodeKind}</span>
            {state?.needsOwnerReview && <span className="planner-node-modal__state planner-node-modal__state--review">owner review</span>}
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

        {nextAction && (
          <div className="planner-node-modal__next-action">
            <Signpost size={13} aria-hidden />
            <div><em>Next step</em><strong>{nextAction}</strong></div>
          </div>
        )}

        <div className="planner-node-modal__tabs" role="tablist" aria-label="Node detail sections">
          <button type="button" className={activeTab === 'execution' ? 'is-active' : ''} onClick={() => setActiveTab('execution')}>Execution</button>
          <button type="button" className={activeTab === 'plan' ? 'is-active' : ''} onClick={() => setActiveTab('plan')}>Plan</button>
          <button type="button" className={activeTab === 'evidence' ? 'is-active' : ''} onClick={() => setActiveTab('evidence')}>Evidence</button>
        </div>

        {activeTab === 'execution' && (
          <>
            <div className="planner-node-modal__section">
              <h3>Responsible people</h3>
              <div className="planner-node-modal__people">
                <span className={`planner-node-modal__avatar${ownerAvatarUrl ? ' has-image' : ''}`} aria-hidden>
                  {ownerAvatarUrl ? <img src={ownerAvatarUrl} alt="" /> : <UserRound size={14} />}
                </span>
                <div><em>Owner</em><strong>{ownerLabel ?? 'canvas owner'}</strong></div>
                <div><em>Doer</em><strong>{(doerLabel ?? node.doerId) || 'Unassigned'}</strong></div>
                <button
                  type="button"
                  className="planner-node-modal__assign-doer"
                  disabled={!canActOnNode || actionBusy || !isDesignMode}
                  title={isDesignMode ? permissionTooltip : 'Assign doer from Design mode.'}
                  onClick={() => togglePanel('doer')}
                >
                  <UserRound size={12} aria-hidden /> Assign doer
                </button>
              </div>
              {openPanel === 'doer' && (
                <div className="planner-node-actions__panel">
                  {teamMembers.length === 0 ? (
                    <p className="planner-node-modal__empty">No team members available to assign.</p>
                  ) : (
                    <div className="planner-node-actions__members">
                      {teamMembers.map((member) => {
                        const current = member.userId === node.doerId
                        return (
                          <button
                            key={member.userId}
                            type="button"
                            className={`planner-node-actions__member${current ? ' is-current' : ''}`}
                            disabled={actionBusy || current}
                            onClick={() =>
                              runProposalAction(() =>
                                proposePlannerGraphChange(canvasId, {
                                  summary: `Assign ${member.displayName} as doer of ${node.title}`,
                                  changes: [{ kind: 'updateNode', nodeId: node.id, doerId: member.userId }],
                                }),
                              )
                            }
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
            </div>

            <div className="planner-node-modal__section planner-node-actions">
              <h3><Rocket size={13} aria-hidden /> Work session</h3>
              <div className="planner-node-actions__buttons">
                <button
                  type="button"
                  disabled={!isRunMode || !canActOnNode || actionBusy || !isStepNode || Boolean(activeSessionId)}
                  title={
                    !isRunMode ? 'Start work from Run mode.'
                      : activeSessionId ? 'This node already has an active session. Complete or split it before starting another.'
                        : !canActOnNode ? permissionTooltip
                          : !isStepNode ? 'Only step nodes can start work.'
                            : undefined
                  }
                  onClick={() => togglePanel('start')}
                >
                  <Rocket size={12} aria-hidden /> Start work
                </button>
                <button
                  type="button"
                  disabled={!isRunMode || !canActOnNode || actionBusy || Boolean(activeSessionId)}
                  title={!isRunMode ? 'Attach sessions from Run mode.' : activeSessionId ? 'This node already has an active session.' : permissionTooltip}
                  onClick={() => togglePanel('bind')}
                >
                  <GitBranch size={12} aria-hidden /> Attach existing session
                </button>
              </div>

              {openPanel === 'start' && (
                <div className="planner-node-actions__panel">
                  <label className="planner-node-actions__field">
                    <span>Runner</span>
                    <select
                      value={dispatchRunner}
                      onChange={(event) => setDispatchRunner(event.target.value as PlannerDispatchRunner)}
                      disabled={actionBusy}
                    >
                      {DISPATCH_RUNNERS.map((runner) => (
                        <option key={runner.value} value={runner.value}>{runner.label}</option>
                      ))}
                    </select>
                  </label>
                  <button
                    type="button"
                    className="primary planner-node-actions__submit"
                    disabled={actionBusy}
                    onClick={() => runDirectAction(() => dispatchPlannerNodeSession(canvasId, node.id, dispatchRunner))}
                  >
                    <Rocket size={12} aria-hidden /> Start session
                  </button>
                </div>
              )}

              {actionError && <p className="planner-node-actions__error">{actionError}</p>}
            </div>

            <div className="planner-node-modal__section">
              <h3>Current run</h3>
              <div className="planner-node-modal__grid">
                <span>Active session</span>
                <strong className="is-mono">{activeSessionId ?? 'none'}</strong>
                <span>Runner</span>
                <strong><GitBranch size={12} aria-hidden /> {runnerLabel}</strong>
                <span>Run state</span>
                <strong>{displayRunState(node.workflowRunState ?? 'pending')}</strong>
                <span>Mode</span>
                <strong>{node.executionMode}</strong>
              </div>
            </div>
          </>
        )}

        {activeTab === 'plan' && (
          <>
            <div className="planner-node-modal__section planner-node-actions">
              <h3><Sparkles size={13} aria-hidden /> Plan changes</h3>
              <div className="planner-node-actions__buttons">
                <button type="button" disabled={!isDesignMode || !canActOnNode || actionBusy} title={isDesignMode ? permissionTooltip : 'Revise topology from Design mode.'} onClick={() => togglePanel('refine')}>
                  <Sparkles size={12} aria-hidden /> Revise this step
                </button>
                <button type="button" disabled={!isDesignMode || !canActOnNode || actionBusy} title={isDesignMode ? permissionTooltip : 'Expand topology from Design mode.'} onClick={() => togglePanel('subCanvas')}>
                  <Layers size={12} aria-hidden /> Expand into sub-flow
                </button>
              </div>

              {openPanel === 'refine' && (
                <div className="planner-node-actions__panel">
                  <label className="planner-node-actions__field">
                    <span>What should meee2 AI revise?</span>
                    <textarea
                      value={refineReason}
                      onChange={(event) => setRefineReason(event.target.value)}
                      placeholder="Describe what should change about this step."
                      rows={3}
                      disabled={actionBusy}
                    />
                  </label>
                  <button
                    type="button"
                    className="primary planner-node-actions__submit"
                    disabled={actionBusy || refineReason.trim().length === 0}
                    onClick={() => runProposalAction(() => refinePlannerNode(canvasId, node.id, refineReason.trim()))}
                  >
                    <Sparkles size={12} aria-hidden /> Create revision proposal
                  </button>
                </div>
              )}

              {openPanel === 'subCanvas' && (
                <div className="planner-node-actions__panel">
                  <label className="planner-node-actions__field">
                    <span>Sub-flow title</span>
                    <input
                      value={subCanvasTitle}
                      onChange={(event) => setSubCanvasTitle(event.target.value)}
                      placeholder={`${node.title} - sub-flow`}
                      disabled={actionBusy}
                    />
                  </label>
                  <button
                    type="button"
                    className="primary planner-node-actions__submit"
                    disabled={actionBusy}
                    onClick={() =>
                      runProposalAction(() =>
                        createPlannerSubCanvasFromNode(canvasId, node.id, subCanvasTitle.trim() || undefined),
                      )
                    }
                  >
                    <Layers size={12} aria-hidden /> Create sub-flow proposal
                  </button>
                </div>
              )}
              {actionError && <p className="planner-node-actions__error">{actionError}</p>}
            </div>

            {node.gate && (
              <div className="planner-node-modal__section">
                <h3><Signpost size={13} aria-hidden /> Gate</h3>
                <div className="planner-node-modal__grid">
                  <span>Gate</span><strong>{node.gate.label}</strong>
                  <span>Type</span><strong>{node.gate.type}</strong>
                  <span>Approvers</span><strong>{node.gate.approvers.length > 0 ? node.gate.approvers.join(', ') : 'none'}</strong>
                  <span>Requires</span><strong>{node.gate.requiredArtifactRefs.length > 0 ? node.gate.requiredArtifactRefs.join(', ') : 'none'}</strong>
                </div>
              </div>
            )}

            <div className="planner-node-modal__section">
              <h3>IO contract</h3>
              <div className="planner-node-modal__grid">
                <span>Consumes</span><strong>{consumes.length > 0 ? consumes.join(', ') : 'none'}</strong>
                <span>Produces</span><strong>{produces.length > 0 ? produces.join(', ') : 'none'}</strong>
                <span>Completion</span><strong>{node.ioSchema.completionSignal || 'submit valid output'}</strong>
              </div>
            </div>

            <div className="planner-node-modal__section">
              <h3><Route size={13} aria-hidden /> Dependencies</h3>
              {deps.length > 0 ? (
                <ul className="planner-node-modal__list">
                  {deps.map((dep) => <li key={dep} className="is-mono">{dep}</li>)}
                </ul>
              ) : (
                <p className="planner-node-modal__empty">No upstream dependencies.</p>
              )}
            </div>
          </>
        )}

        {activeTab === 'evidence' && (
          <>
            <div className="planner-node-modal__section planner-node-output">
              <h3><Plus size={13} aria-hidden /> Add output</h3>
              <label className="planner-node-actions__field">
                <span>Message</span>
                <textarea
                  value={outputSummary}
                  onChange={(event) => setOutputSummary(event.target.value)}
                  placeholder="Summarize the output for downstream work."
                  rows={3}
                  disabled={actionBusy}
                />
              </label>
              <div className="planner-node-output__grid">
                <label className="planner-node-actions__field">
                  <span>Status</span>
                  <select value={outputStatus} onChange={(event) => setOutputStatus(event.target.value as PlannerNodeOutputStatus)}>
                    <option value="done">Done</option>
                    <option value="blocked">Blocked</option>
                    <option value="needs_review">Needs review</option>
                  </select>
                </label>
                <label className="planner-node-actions__field">
                  <span>Next</span>
                  <select value={outputNext} onChange={(event) => setOutputNext(event.target.value as PlannerNodeOutputNext)}>
                    <option value="complete">Complete</option>
                    <option value="blocked">Blocked</option>
                    <option value="needs_owner_review">Needs owner review</option>
                  </select>
                </label>
              </div>
              <div className="planner-node-output__grid">
                <label className="planner-node-actions__field">
                  <span>Output kind</span>
                  <select value={outputKind} onChange={(event) => setOutputKind(event.target.value as PlannerArtifactKind)}>
                    {ARTIFACT_KINDS.map((kind) => <option key={kind} value={kind}>{kind}</option>)}
                  </select>
                </label>
                <label className="planner-node-actions__field">
                  <span>Reference</span>
                  <input
                    value={outputReference}
                    onChange={(event) => setOutputReference(event.target.value)}
                    placeholder="lark://doc/... or git://..."
                    disabled={actionBusy}
                  />
                </label>
              </div>
              <label className="planner-node-actions__field">
                <span>Title</span>
                <input
                  value={outputTitle}
                  onChange={(event) => setOutputTitle(event.target.value)}
                  placeholder="Optional output title"
                  disabled={actionBusy}
                />
              </label>
              <div className="planner-node-output__routes">
                <span>Route to</span>
                {routeTargets.map((target) => (
                  <label key={target.id}>
                    <input
                      type="checkbox"
                      checked={routeTo.includes(target.id)}
                      onChange={(event) => {
                        setRouteTo((current) =>
                          event.target.checked
                            ? [...new Set([...current, target.id])]
                            : current.filter((item) => item !== target.id),
                        )
                      }}
                    />
                    {target.label}
                  </label>
                ))}
              </div>
              <button
                type="button"
                className="primary planner-node-actions__submit"
                disabled={actionBusy || routeTo.length === 0}
                onClick={submitOutput}
              >
                <Plus size={12} aria-hidden /> Submit output
              </button>
              {actionError && <p className="planner-node-actions__error">{actionError}</p>}
            </div>

            <div className="planner-node-modal__section">
              <h3><FileText size={13} aria-hidden /> Outputs ({artifactRefs.length})</h3>
              {artifactRefs.length > 0 ? (
                <ul className="planner-node-modal__artifacts">
                  {artifactRefs.map((ref) => (
                    <li key={ref} title={ref}><FileText size={11} aria-hidden /><span>{ref}</span></li>
                  ))}
                </ul>
              ) : (
                <p className="planner-node-modal__empty">No outputs yet.</p>
              )}

              <div className="planner-node-modal__attach">
                <span className="planner-node-modal__attach-label">
                  <Plus size={11} aria-hidden /> Add output from
                </span>
                <div className="planner-node-modal__attach-providers">
                  <button type="button" className={attachProvider === 'github' ? 'is-active' : ''} onClick={() => setAttachProvider((current) => (current === 'github' ? null : 'github'))}>
                    <GitPullRequest size={12} aria-hidden /> GitHub
                  </button>
                  <button type="button" className={attachProvider === 'lark' ? 'is-active' : ''} onClick={() => setAttachProvider((current) => (current === 'lark' ? null : 'lark'))}>
                    <MessageSquareText size={12} aria-hidden /> Lark
                  </button>
                </div>
                {attachProvider && (
                  <div className="planner-node-modal__attach-picker">
                    <IntegrationArtifactPicker
                      provider={attachProvider}
                      attachTarget={{ canvasId, nodeId: node.id, nodeTitle: node.title }}
                      onAttached={() => {
                        setAttachProvider(null)
                        onArtifactAttached?.()
                      }}
                      onClose={() => setAttachProvider(null)}
                    />
                  </div>
                )}
              </div>
            </div>
          </>
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

      {openPanel === 'bind' && (
        <SessionPicker
          sessions={sessions}
          busy={actionBusy}
          onClose={() => setOpenPanel(null)}
          onPick={(sessionId) =>
            runDirectAction(() => bindPlannerSessionToNode(canvasId, node.id, sessionId))
          }
        />
      )}
    </div>
  )
}

function displayRunner(runner: PlannerDispatchRunner | null): string {
  switch (runner) {
    case 'claude':
      return 'Claude'
    case 'codex':
      return 'Codex'
    case 'human':
      return 'Human task'
    case 'ci-agent':
      return 'CI agent'
    case 'byoa-local':
      return 'Claude'
    default:
      return 'Not started'
  }
}

function displayRunState(runState: string): string {
  switch (runState) {
    case 'dispatched':
      return 'starting'
    case 'ready_to_start':
      return 'ready to start'
    case 'gate-wait':
      return 'waiting for review'
    default:
      return runState.replace(/_/g, ' ')
  }
}
