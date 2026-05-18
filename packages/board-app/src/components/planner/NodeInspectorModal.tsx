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
import { useState } from 'react'
import {
  bindPlannerSessionToNode,
  createPlannerSubCanvasFromNode,
  dispatchPlannerNodeSession,
  proposePlannerGraphChange,
  refinePlannerNode,
} from '../../api'
import type { TeamMember } from '../../api'
import type {
  NodeStateSnapshot,
  PlanProposal,
  PlannerAccess,
  PlannerDispatchRunner,
  PlannerGraphState,
  PlanningNode,
  Session,
} from '../../types'
import { IntegrationArtifactPicker } from '../IntegrationArtifactPicker'
import { SessionPicker } from './SessionPicker'

/** Runner choices offered for Gap 1 dispatch. Mirrors the spec's list. */
const DISPATCH_RUNNERS: { value: PlannerDispatchRunner; label: string }[] = [
  { value: 'claude', label: 'claude' },
  { value: 'codex', label: 'codex' },
  { value: 'byoa-local', label: 'byoa-local' },
  { value: 'human', label: 'human' },
]

interface Props {
  node: PlanningNode
  /** Canvas the node belongs to — required to attach artifacts. */
  canvasId: string
  state: NodeStateSnapshot | null
  ownerLabel?: string
  ownerAvatarUrl?: string
  doerLabel?: string
  /** Permission descriptor for the active canvas (owner / doer / viewer). */
  access?: PlannerAccess | null
  /** Local sessions available to bind (Gap 2). Usually `boardState.sessions`. */
  sessions?: Session[]
  /** Team member directory for the doer picker (Gap 6). */
  teamMembers?: TeamMember[]
  onClose: () => void
  onOpenSubCanvas?: (canvasId: string) => void
  /** Called after an artifact is attached via the existing attach endpoint. */
  onArtifactAttached?: () => void
  /**
   * Fires when a GOVERNANCE-layer node action (sub-canvas / refine / assign
   * doer) produces a `PlanProposal`. PlannerGraph threads it into the existing
   * proposal → preview → approve → apply gate.
   */
  onProposalCreated?: (proposal: PlanProposal) => void
  /**
   * Fires when an EXECUTION-layer node action (bind session / dispatch) applies
   * DIRECTLY — no proposal, no owner approval. PlannerGraph re-fetches the
   * graph state. Distinct from `onProposalCreated`.
   */
  onNodeMutated?: (state: PlannerGraphState) => void
}

/**
 * Full node detail surface. The graph card only shows a compressed summary;
 * everything else (full artifact list, gate config, IO schema, dispatch) lives here.
 */
export function NodeInspectorModal({
  node,
  canvasId,
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
  // Which integration the artifact picker is browsing, if any. The picker is
  // node-scoped: attaching is always an explicit user action through the
  // existing attach endpoint — nothing is auto-guessed.
  const [attachProvider, setAttachProvider] = useState<'github' | 'lark' | null>(null)
  const runState = state?.runState ?? node.status
  const nodeKind = node.nodeKind ?? (node.source === 'session' ? 'session' : node.subCanvasId ? 'subCanvas' : 'step')
  const artifactRefs = node.artifactRefs ?? state?.artifactRefs ?? []
  const blockers = state?.blockers ?? []
  const consumes = node.ioSchema?.consumes ?? []
  const produces = node.ioSchema?.produces ?? []
  const deps = node.dependsOnNodeIds ?? []
  const executorLabel = node.executorType === 'mock' ? 'local' : node.executorType
  // Phase 6 — server-derived workflow guidance ("what to do next").
  const nextAction = node.nextAction?.trim() || null

  // -- Node actions (Gaps 1-4 + 6) ------------------------------------------
  // Which action sub-panel is open, if any.
  type ActionPanel = 'dispatch' | 'bind' | 'subCanvas' | 'refine' | 'doer'
  const [openPanel, setOpenPanel] = useState<ActionPanel | null>(null)
  const [actionBusy, setActionBusy] = useState(false)
  const [actionError, setActionError] = useState<string | null>(null)
  const [dispatchRunner, setDispatchRunner] = useState<PlannerDispatchRunner>('claude')
  const [subCanvasTitle, setSubCanvasTitle] = useState('')
  const [refineReason, setRefineReason] = useState('')

  // Permission: owner can act on any node; a doer only on nodes assigned to it;
  // viewers are fully disabled. `requireNodeUpdate` semantics from Phase 3.
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
  const alreadyDispatched = Boolean(node.sessionId)

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

  // Governance-layer actions (sub-canvas / refine / assign doer) — funnel into
  // the proposal → preview → approve → apply gate.
  const runAction = (work: () => Promise<PlanProposal | null>) => {
    setActionBusy(true)
    setActionError(null)
    work()
      .then(finishProposal)
      .catch((err) => {
        setActionBusy(false)
        setActionError((err as Error).message || 'Action failed')
      })
  }

  // Execution-layer actions (bind session / dispatch) — apply DIRECTLY, no
  // proposal gate. On success: refresh the graph, flash a success note, close.
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

  return (
    <div
      className="planner-node-modal-backdrop"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onClose()
      }}
    >
      <div className="planner-node-modal" role="dialog" aria-modal="true" aria-label="Node details">
        <button
          type="button"
          className="planner-node-modal__close"
          onClick={onClose}
          aria-label="Close node details"
        >
          <X size={15} aria-hidden />
        </button>

        <div className="planner-node-modal__header">
          <div className="planner-node-modal__header-tags">
            <span className={`planner-node-modal__state planner-node-modal__state--${runState}`}>{runState}</span>
            <span className="planner-node-modal__kind">{nodeKind}</span>
            {state?.needsOwnerReview && (
              <span className="planner-node-modal__state planner-node-modal__state--review">owner review</span>
            )}
          </div>
          <h2>{node.title}</h2>
        </div>

        {blockers.length > 0 && (
          <div className="planner-node-modal__blockers">
            {blockers.map((blocker) => (
              <span key={blocker}>
                <AlertTriangle size={12} aria-hidden />
                {blocker}
              </span>
            ))}
          </div>
        )}

        {nextAction && (
          <div className="planner-node-modal__next-action">
            <Signpost size={13} aria-hidden />
            <div>
              <em>Next step</em>
              <strong>{nextAction}</strong>
            </div>
          </div>
        )}

        <div className="planner-node-modal__section">
          <h3>Ownership</h3>
          <div className="planner-node-modal__people">
            <span className={`planner-node-modal__avatar${ownerAvatarUrl ? ' has-image' : ''}`} aria-hidden>
              {ownerAvatarUrl ? <img src={ownerAvatarUrl} alt="" /> : <UserRound size={14} />}
            </span>
            <div>
              <em>Owner</em>
              <strong>{ownerLabel ?? 'canvas owner'}</strong>
            </div>
            <div>
              <em>Doer</em>
              <strong>{doerLabel ?? node.doerId}</strong>
            </div>
            {/* Gap 6 — assign doer through a lightweight updateNode proposal. */}
            <button
              type="button"
              className="planner-node-modal__assign-doer"
              disabled={!canActOnNode || actionBusy}
              title={permissionTooltip}
              onClick={() => togglePanel('doer')}
            >
              <UserRound size={12} aria-hidden />
              Assign doer
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
                          runAction(() =>
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

        {/* Node-level actions. Dispatch / bind are execution-layer (apply
            directly); sub-canvas / refine are governance-layer (proposal gate). */}
        <div className="planner-node-modal__section planner-node-actions">
          <h3>
            <Rocket size={13} aria-hidden /> Node actions
          </h3>
          <div className="planner-node-actions__buttons">
            <button
              type="button"
              disabled={!canActOnNode || actionBusy || !isStepNode}
              title={
                !canActOnNode
                  ? permissionTooltip
                  : !isStepNode
                    ? 'Only step nodes can be dispatched.'
                    : alreadyDispatched
                      ? 'This node already has a bound session — dispatching starts another runner.'
                      : undefined
              }
              onClick={() => togglePanel('dispatch')}
            >
              <Rocket size={12} aria-hidden /> Dispatch
            </button>
            <button
              type="button"
              disabled={!canActOnNode || actionBusy}
              title={permissionTooltip}
              onClick={() => togglePanel('bind')}
            >
              <GitBranch size={12} aria-hidden /> Bind session
            </button>
            <button
              type="button"
              disabled={!canActOnNode || actionBusy}
              title={permissionTooltip}
              onClick={() => togglePanel('subCanvas')}
            >
              <Layers size={12} aria-hidden /> Break into sub-canvas
            </button>
            <button
              type="button"
              disabled={!canActOnNode || actionBusy}
              title={permissionTooltip}
              onClick={() => togglePanel('refine')}
            >
              <Sparkles size={12} aria-hidden /> Refine with meee2 AI
            </button>
          </div>

          {openPanel === 'dispatch' && (
            <div className="planner-node-actions__panel">
              {alreadyDispatched && (
                <p className="planner-node-actions__notice">
                  This node already has session <strong>{node.sessionId}</strong>. Dispatch spawns an additional runner.
                </p>
              )}
              <label className="planner-node-actions__field">
                <span>Runner</span>
                <select
                  value={dispatchRunner}
                  onChange={(event) => setDispatchRunner(event.target.value as PlannerDispatchRunner)}
                  disabled={actionBusy}
                >
                  {DISPATCH_RUNNERS.map((runner) => (
                    <option key={runner.value} value={runner.value}>
                      {runner.label}
                    </option>
                  ))}
                </select>
              </label>
              <button
                type="button"
                className="primary planner-node-actions__submit"
                disabled={actionBusy}
                onClick={() => runDirectAction(() => dispatchPlannerNodeSession(canvasId, node.id, dispatchRunner))}
              >
                <Rocket size={12} aria-hidden /> Dispatch now
              </button>
            </div>
          )}

          {openPanel === 'subCanvas' && (
            <div className="planner-node-actions__panel">
              <label className="planner-node-actions__field">
                <span>Sub-canvas title (optional)</span>
                <input
                  value={subCanvasTitle}
                  onChange={(event) => setSubCanvasTitle(event.target.value)}
                  placeholder={`${node.title} — sub-canvas`}
                  disabled={actionBusy}
                />
              </label>
              <button
                type="button"
                className="primary planner-node-actions__submit"
                disabled={actionBusy}
                onClick={() =>
                  runAction(() =>
                    createPlannerSubCanvasFromNode(canvasId, node.id, subCanvasTitle.trim() || undefined),
                  )
                }
              >
                <Layers size={12} aria-hidden /> Create sub-canvas proposal
              </button>
            </div>
          )}

          {openPanel === 'refine' && (
            <div className="planner-node-actions__panel">
              <label className="planner-node-actions__field">
                <span>What should meee2 AI refine?</span>
                <textarea
                  value={refineReason}
                  onChange={(event) => setRefineReason(event.target.value)}
                  placeholder="Describe what this node should become or clarify."
                  rows={3}
                  disabled={actionBusy}
                />
              </label>
              <button
                type="button"
                className="primary planner-node-actions__submit"
                disabled={actionBusy || refineReason.trim().length === 0}
                onClick={() => runAction(() => refinePlannerNode(canvasId, node.id, refineReason.trim()))}
              >
                <Sparkles size={12} aria-hidden /> Create refine proposal
              </button>
            </div>
          )}

          {actionError && <p className="planner-node-actions__error">{actionError}</p>}
        </div>

        <div className="planner-node-modal__section">
          <h3>Execution</h3>
          <div className="planner-node-modal__grid">
            <span>Executor</span>
            <strong>
              <GitBranch size={12} aria-hidden /> {executorLabel}
            </strong>
            <span>Mode</span>
            <strong>{node.executionMode}</strong>
            <span>Run state</span>
            <strong>{node.workflowRunState ?? 'pending'}</strong>
            <span>Trigger</span>
            <strong>{node.trigger?.label ?? 'manual / none'}</strong>
            {node.dispatch && (
              <>
                <span>Dispatch</span>
                <strong>
                  {node.dispatch.runner}
                  {node.dispatch.skill ? ` · ${node.dispatch.skill}` : ''}
                  {node.dispatch.command ? ` · ${node.dispatch.command}` : ''}
                </strong>
              </>
            )}
          </div>
        </div>

        <div className="planner-node-modal__section">
          <h3>Session binding</h3>
          <div className="planner-node-modal__grid">
            <span>Session</span>
            <strong className="is-mono">{node.sessionId ?? 'not bound'}</strong>
            <span>Chat thread</span>
            <strong className="is-mono">{node.chatThreadId ?? 'none'}</strong>
            <span>Source</span>
            <strong>{node.source ?? 'planner'}</strong>
          </div>
        </div>

        {node.gate && (
          <div className="planner-node-modal__section">
            <h3>
              <Signpost size={13} aria-hidden /> Gate
            </h3>
            <div className="planner-node-modal__grid">
              <span>Gate</span>
              <strong>{node.gate.label}</strong>
              <span>Type</span>
              <strong>{node.gate.type}</strong>
              <span>Approvers</span>
              <strong>{node.gate.approvers.length > 0 ? node.gate.approvers.join(', ') : 'none'}</strong>
              <span>Requires</span>
              <strong>
                {node.gate.requiredArtifactRefs.length > 0
                  ? node.gate.requiredArtifactRefs.join(', ')
                  : 'none'}
              </strong>
            </div>
          </div>
        )}

        <div className="planner-node-modal__section">
          <h3>IO schema</h3>
          <div className="planner-node-modal__grid">
            <span>Consumes</span>
            <strong>{consumes.length > 0 ? consumes.join(', ') : 'none'}</strong>
            <span>Produces</span>
            <strong>{produces.length > 0 ? produces.join(', ') : 'none'}</strong>
          </div>
        </div>

        <div className="planner-node-modal__section">
          <h3>
            <Route size={13} aria-hidden /> Dependencies
          </h3>
          {deps.length > 0 ? (
            <ul className="planner-node-modal__list">
              {deps.map((dep) => (
                <li key={dep} className="is-mono">{dep}</li>
              ))}
            </ul>
          ) : (
            <p className="planner-node-modal__empty">No upstream dependencies.</p>
          )}
        </div>

        <div className="planner-node-modal__section">
          <h3>
            <FileText size={13} aria-hidden /> Artifacts ({artifactRefs.length})
          </h3>
          {artifactRefs.length > 0 ? (
            <ul className="planner-node-modal__artifacts">
              {artifactRefs.map((ref) => (
                <li key={ref} title={ref}>
                  <FileText size={11} aria-hidden />
                  <span>{ref}</span>
                </li>
              ))}
            </ul>
          ) : (
            <p className="planner-node-modal__empty">No artifacts attached.</p>
          )}

          {/* Phase 5 — explicit, node-scoped artifact attach from integrations. */}
          <div className="planner-node-modal__attach">
            <span className="planner-node-modal__attach-label">
              <Plus size={11} aria-hidden /> Attach artifact from
            </span>
            <div className="planner-node-modal__attach-providers">
              <button
                type="button"
                className={attachProvider === 'github' ? 'is-active' : ''}
                onClick={() =>
                  setAttachProvider((current) => (current === 'github' ? null : 'github'))
                }
              >
                <GitPullRequest size={12} aria-hidden /> GitHub
              </button>
              <button
                type="button"
                className={attachProvider === 'lark' ? 'is-active' : ''}
                onClick={() =>
                  setAttachProvider((current) => (current === 'lark' ? null : 'lark'))
                }
              >
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

        {node.subCanvasId && (
          <button
            type="button"
            className="planner-node-modal__subcanvas"
            onClick={() => {
              onOpenSubCanvas?.(node.subCanvasId as string)
              onClose()
            }}
          >
            <ExternalLink size={13} aria-hidden />
            Open sub-canvas
          </button>
        )}
      </div>

      {/* Gap 2 — pick a local session; bind applies directly (execution layer). */}
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
