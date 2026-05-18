import {
  Background,
  Controls,
  ReactFlow,
  ReactFlowProvider,
  applyNodeChanges,
  type NodeChange,
  useReactFlow,
} from '@xyflow/react'
import { PanelRightClose, PanelRightOpen } from 'lucide-react'
import { useCallback, useEffect, useMemo, useState } from 'react'
import type { CSSProperties, PointerEvent as ReactPointerEvent } from 'react'
import {
  abortPlannerRun,
  applyPlannerProposal,
  applyPlannerProposalPreview,
  approvePlannerProposal,
  createPlannerDeliveryPipeline,
  fetchPlannerGraphState,
  fetchPlannerRuns,
  fetchTeamMembers,
  generatePlannerProposal,
  inspectPlannerDrift,
  rejectPlannerProposal,
  sendPlannerActivity,
  setPlannerCanvasVisibility,
  startPlannerRun,
  updatePlannerNodeLayout,
} from '../../api'
import type {
  PlanProposal,
  PlannerCanvasState,
  PlannerCanvasVisibility,
  WorkflowRun,
} from '../../types'
import type { BoardState } from '../../types'
import type { TeamMember, UserProfile } from '../../api'
import {
  buildTeamDirectory,
  teamAvatarUrlByUserId,
  teamDisplayNameByUserId,
} from '../../teamDirectory'
import { NodeInspectorModal } from './NodeInspectorModal'
import { PlannerNodeCard } from './PlannerNodeCard'
import { PlannerOverviewMap } from './PlannerOverviewMap'
import { PlannerProposalPanel } from './PlannerProposalPanel'
import { RunHistoryView } from './RunHistoryView'
import { RunSelector, type PlannerMode, type StartDeliveryInput } from './RunSelector'
import { buildPlannerGraph, type PlannerGraphNode } from './plannerGraphAdapter'
import './planner.css'

interface Props {
  canvasId: string
  canvasName: string
  userProfile?: UserProfile | null
  boardState?: BoardState | null
  onOpenSubCanvas?: (canvasId: string) => void
}

const nodeTypes = {
  plannerNode: PlannerNodeCard,
}

const PANEL_WIDTH_KEY = 'meee2.planner.aiPanelWidth'
const PANEL_COLLAPSED_KEY = 'meee2.planner.aiPanelCollapsed'
const DEFAULT_PANEL_WIDTH = 420
const MIN_PANEL_WIDTH = 340
const MAX_PANEL_WIDTH = 680

export function PlannerGraph(props: Props) {
  return (
    <ReactFlowProvider>
      <PlannerGraphInner {...props} />
    </ReactFlowProvider>
  )
}

function PlannerGraphInner({ canvasId, canvasName, userProfile = null, boardState = null, onOpenSubCanvas }: Props) {
  const reactFlow = useReactFlow()
  const [plannerState, setPlannerState] = useState<PlannerCanvasState | null>(null)
  const [proposal, setProposal] = useState<PlanProposal | null>(null)
  const [previewActive, setPreviewActive] = useState(false)
  const [selectedNodeId, setSelectedNodeId] = useState<string | null>(null)
  const [nodeModalOpen, setNodeModalOpen] = useState(false)
  const [plannerPanelCollapsed, setPlannerPanelCollapsed] = useState(() => readStoredPanelCollapsed())
  const [plannerPanelWidth, setPlannerPanelWidth] = useState(() => readStoredPanelWidth())
  const [flowNodes, setFlowNodes] = useState<PlannerGraphNode[]>([])
  const [teamMembers, setTeamMembers] = useState<TeamMember[]>([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [pendingVisibility, setPendingVisibility] = useState<PlannerCanvasVisibility | null>(null)
  // P2 Run layer — Design vs Run mode + the run being viewed.
  const [mode, setMode] = useState<PlannerMode>('design')
  const [runs, setRuns] = useState<WorkflowRun[]>([])
  const [selectedRunId, setSelectedRunId] = useState<string | null>(null)
  const [historyOpen, setHistoryOpen] = useState(false)

  const loadState = useCallback(() => {
    setBusy(true)
    setError(null)
    fetchPlannerGraphState(canvasId)
      .then((state) => {
        setPlannerState(state)
        setProposal(state.proposals.find((item) => item.status === 'pending' || item.status === 'approved') ?? null)
        setPreviewActive(false)
      })
      .catch((err) => setError((err as Error).message || 'Failed to load meee2 AI state'))
      .finally(() => setBusy(false))
  }, [canvasId])

  const loadRuns = useCallback(() => {
    fetchPlannerRuns(canvasId)
      .then((next) => {
        setRuns(next)
        setSelectedRunId((current) => {
          if (current && next.some((run) => run.id === current)) return current
          const active = next.find((run) => run.status === 'active')
          return active?.id ?? next[next.length - 1]?.id ?? null
        })
      })
      .catch(() => setRuns([]))
  }, [canvasId])

  useEffect(() => {
    loadState()
    loadRuns()
  }, [loadState, loadRuns])

  // Authoritative team member identities — used for avatar / name resolution.
  useEffect(() => {
    let cancelled = false
    fetchTeamMembers()
      .then((res) => {
        if (!cancelled) setTeamMembers(res.members)
      })
      .catch(() => {
        if (!cancelled) setTeamMembers([])
      })
    return () => {
      cancelled = true
    }
  }, [])

  const handleOpenNodeDetails = useCallback((nodeId: string) => {
    setSelectedNodeId(nodeId)
    setNodeModalOpen(true)
  }, [])

  const teamDirectory = useMemo(() => {
    const members = buildTeamDirectory({
      userProfile,
      boardState,
      canvasOwnerId: plannerState?.canvas.ownerId,
      nodes: plannerState?.nodes ?? [],
      activities: plannerState?.activities ?? [],
      teamMembers,
    })
    return {
      displayNameByUserId: teamDisplayNameByUserId(members),
      avatarUrlByUserId: teamAvatarUrlByUserId(members),
    }
  }, [boardState, plannerState, userProfile, teamMembers])

  const selectedRun = useMemo(
    () => runs.find((run) => run.id === selectedRunId) ?? null,
    [runs, selectedRunId],
  )

  const graph = useMemo(() => {
    return buildPlannerGraph({
      nodes: plannerState?.nodes ?? [],
      states: plannerState?.states ?? [],
      edges: plannerState?.edges ?? [],
      proposal: previewActive ? null : proposal,
      ownerId: plannerState?.canvas.ownerId,
      mode,
      runNodeStates: selectedRun?.nodeStates,
      displayNameByUserId: teamDirectory.displayNameByUserId,
      avatarUrlByUserId: teamDirectory.avatarUrlByUserId,
      onOpenDetails: handleOpenNodeDetails,
      onOpenSubCanvas,
    })
  }, [plannerState, previewActive, proposal, mode, selectedRun, teamDirectory, handleOpenNodeDetails, onOpenSubCanvas])

  useEffect(() => {
    setFlowNodes(graph.nodes)
  }, [graph.nodes])

  const handleNodesChange = useCallback((changes: NodeChange<PlannerGraphNode>[]) => {
    setFlowNodes((current) => applyNodeChanges(changes, current) as PlannerGraphNode[])
  }, [])

  useEffect(() => {
    window.localStorage.setItem(PANEL_COLLAPSED_KEY, plannerPanelCollapsed ? '1' : '0')
  }, [plannerPanelCollapsed])

  useEffect(() => {
    window.localStorage.setItem(PANEL_WIDTH_KEY, String(plannerPanelWidth))
  }, [plannerPanelWidth])

  const handlePanelResizeStart = useCallback((event: ReactPointerEvent<HTMLButtonElement>) => {
    event.preventDefault()
    const startX = event.clientX
    const startWidth = plannerPanelWidth
    const onPointerMove = (moveEvent: PointerEvent) => {
      setPlannerPanelWidth(clampPanelWidth(startWidth + startX - moveEvent.clientX))
    }
    const onPointerUp = () => {
      window.removeEventListener('pointermove', onPointerMove)
      window.removeEventListener('pointerup', onPointerUp)
      document.body.classList.remove('planner-panel-resizing')
    }
    document.body.classList.add('planner-panel-resizing')
    window.addEventListener('pointermove', onPointerMove)
    window.addEventListener('pointerup', onPointerUp)
  }, [plannerPanelWidth])

  useEffect(() => {
    const timer = window.setTimeout(() => {
      if (window.matchMedia('(max-width: 720px)').matches) {
        reactFlow.setViewport({ x: 18, y: 52, zoom: 0.9 }, { duration: 220 })
        return
      }
      reactFlow.fitView({ padding: 0.12, duration: 220 })
    }, 120)
    return () => window.clearTimeout(timer)
  }, [graph.nodes.length, graph.edges.length, canvasId, reactFlow])

  const selectedNode = useMemo(() => {
    if (!selectedNodeId) return null
    return plannerState?.nodes.find((node) => node.id === selectedNodeId)
      ?? graph.nodes.find((node) => node.id === selectedNodeId)?.data.node
      ?? null
  }, [graph.nodes, plannerState, selectedNodeId])

  const hasActionableDrift = useMemo(() => {
    return (plannerState?.states ?? []).some((state) =>
      state.needsOwnerReview || state.runState === 'blocked' || state.runState === 'planning',
    )
  }, [plannerState])

  useEffect(() => {
    let cancelled = false
    const heartbeat = () => {
      sendPlannerActivity({
        canvasId,
        selectedNodeId,
        selectedSessionId: selectedNode?.sessionId ?? null,
      })
        .then(({ activity }) => {
          if (cancelled) return
          setPlannerState((current) => {
            if (!current) return current
            const others = (current.activities ?? []).filter((item) => item.userId !== activity.userId)
            return { ...current, activities: [activity, ...others] }
          })
        })
        .catch(() => {
          // Presence is best-effort; graph state should keep working offline.
        })
    }
    heartbeat()
    const timer = window.setInterval(heartbeat, 20_000)
    return () => {
      cancelled = true
      window.clearInterval(timer)
    }
  }, [canvasId, selectedNode?.sessionId, selectedNodeId])

  const handleGenerate = useCallback((goal: string) => {
    setBusy(true)
    setError(null)
    generatePlannerProposal(canvasId, goal)
      .then((next) => {
        setProposal(next)
        setPlannerState((current) => current && next
          ? { ...current, proposals: upsertProposal(current.proposals, next) }
          : current)
        setPreviewActive(false)
      })
      .catch((err) => setError((err as Error).message || 'Failed to generate meee2 AI proposal'))
      .finally(() => setBusy(false))
  }, [canvasId])

  const handlePlannerSubmit = useCallback((message: string) => {
    const trimmed = message.trim()
    const shouldInspect = shouldInspectDrift(trimmed, plannerState, hasActionableDrift)
    if (shouldInspect) {
      setBusy(true)
      setError(null)
      inspectPlannerDrift(canvasId)
        .then((next) => {
          if (!next) {
            if (trimmed) {
              return generatePlannerProposal(canvasId, trimmed).then((generated) => {
                setProposal(generated)
                setPlannerState((current) => current && generated
                  ? { ...current, proposals: upsertProposal(current.proposals, generated) }
                  : current)
                setPreviewActive(false)
              })
            }
            setError('No blocked, planning, or owner-review state found.')
            return undefined
          }
          setProposal(next)
          setPlannerState((current) => current
            ? { ...current, proposals: upsertProposal(current.proposals, next) }
            : current)
          setPreviewActive(false)
          return undefined
        })
        .catch((err) => setError((err as Error).message || 'Failed to inspect meee2 AI drift'))
        .finally(() => setBusy(false))
      return
    }

    if (!trimmed) return
    handleGenerate(trimmed)
  }, [canvasId, handleGenerate, hasActionableDrift, plannerState])

  const handleApplyPreview = useCallback(() => {
    if (!proposal) return
    setBusy(true)
    setError(null)
    applyPlannerProposalPreview(canvasId, proposal)
      .then((preview) => {
        setPlannerState((current) => {
          const canvas = current?.canvas ?? {
            id: canvasId,
            ownerId: 'local-owner',
            title: canvasName,
            plannerContext: `canvas:${canvasId}`,
          }
          return {
            canvas,
            nodes: preview.nodes,
            states: preview.states,
            proposals: current?.proposals ?? [],
            access: current?.access ?? defaultPlannerAccess(),
            activities: current?.activities ?? [],
            artifacts: current?.artifacts ?? [],
            edges: current?.edges ?? [],
          }
        })
        setPreviewActive(true)
      })
      .catch((err) => setError((err as Error).message || 'Failed to apply meee2 AI preview'))
      .finally(() => setBusy(false))
  }, [canvasId, canvasName, proposal])

  const handleApprove = useCallback(() => {
    if (!proposal) return
    setBusy(true)
    setError(null)
    approvePlannerProposal(canvasId, proposal.id)
      .then((next) => {
        if (!next) return
        setProposal(next)
        setPlannerState((current) => current
          ? { ...current, proposals: upsertProposal(current.proposals, next) }
          : current)
      })
      .catch((err) => setError((err as Error).message || 'Failed to approve meee2 AI proposal'))
      .finally(() => setBusy(false))
  }, [canvasId, proposal])

  const handleApply = useCallback(() => {
    if (!proposal) return
    setBusy(true)
    setError(null)
    applyPlannerProposal(canvasId, proposal.id)
      .then((result) => {
        setProposal(result.proposal)
        setPlannerState((current) => {
          const canvas = current?.canvas ?? {
            id: canvasId,
            ownerId: 'local-owner',
            title: canvasName,
            plannerContext: `canvas:${canvasId}`,
          }
          return {
            canvas,
            nodes: result.nodes,
            states: result.states,
            proposals: upsertProposal(current?.proposals ?? [], result.proposal),
            access: current?.access ?? defaultPlannerAccess(),
            activities: current?.activities ?? [],
            artifacts: current?.artifacts ?? [],
            edges: current?.edges ?? [],
          }
        })
        setPreviewActive(false)
      })
      .catch((err) => setError((err as Error).message || 'Failed to apply meee2 AI proposal'))
      .finally(() => setBusy(false))
  }, [canvasId, canvasName, proposal])

  const handleApproveAndApply = useCallback(() => {
    if (!proposal) return
    setBusy(true)
    setError(null)
    const applyApproved = (proposalId: string) => applyPlannerProposal(canvasId, proposalId)
    const work = proposal.status === 'pending'
      ? approvePlannerProposal(canvasId, proposal.id).then((next) => {
          if (!next) throw new Error('Proposal approval did not return an approved proposal')
          return applyApproved(next.id)
        })
      : applyApproved(proposal.id)
    work
      .then((result) => {
        setProposal(result.proposal)
        setPlannerState((current) => {
          const canvas = current?.canvas ?? {
            id: canvasId,
            ownerId: 'local-owner',
            title: canvasName,
            plannerContext: `canvas:${canvasId}`,
          }
          return {
            canvas,
            nodes: result.nodes,
            states: result.states,
            proposals: upsertProposal(current?.proposals ?? [], result.proposal),
            access: current?.access ?? defaultPlannerAccess(),
            activities: current?.activities ?? [],
            artifacts: current?.artifacts ?? [],
            edges: current?.edges ?? [],
          }
        })
        setPreviewActive(false)
      })
      .catch((err) => setError((err as Error).message || 'Failed to approve and apply meee2 AI proposal'))
      .finally(() => setBusy(false))
  }, [canvasId, canvasName, proposal])

  const handleReject = useCallback(() => {
    if (!proposal) return
    setBusy(true)
    setError(null)
    rejectPlannerProposal(canvasId, proposal.id)
      .then((next) => {
        if (!next) return
        setProposal(next)
        setPlannerState((current) => current
          ? { ...current, proposals: upsertProposal(current.proposals, next) }
          : current)
      })
      .catch((err) => setError((err as Error).message || 'Failed to reject meee2 AI proposal'))
      .finally(() => setBusy(false))
  }, [canvasId, proposal])

  const handleCreateDeliveryPipeline = useCallback(() => {
    setBusy(true)
    setError(null)
    createPlannerDeliveryPipeline(canvasId)
      .then((next) => {
        if (!next) return
        setProposal(next)
        setPlannerState((current) => current
          ? { ...current, proposals: upsertProposal(current.proposals, next) }
          : current)
        setPreviewActive(false)
      })
      .catch((err) => setError((err as Error).message || 'Failed to create delivery pipeline proposal'))
      .finally(() => setBusy(false))
  }, [canvasId])

  // GOVERNANCE-layer node actions (sub-canvas / refine / assign doer) return a
  // PlanProposal. Thread it into the same proposal state the generate / drift /
  // delivery-pipeline flows feed, so the user lands in the existing
  // PlannerProposalPanel approve/apply gate.
  // Bumped whenever a governance node action creates a proposal —
  // PlannerProposalPanel watches this to auto-open the review modal.
  const [reviewRequestTick, setReviewRequestTick] = useState(0)
  const handleNodeActionProposal = useCallback((next: PlanProposal) => {
    setProposal(next)
    setPlannerState((current) => current
      ? { ...current, proposals: upsertProposal(current.proposals, next) }
      : current)
    setPreviewActive(false)
    setNodeModalOpen(false)
    setReviewRequestTick((tick) => tick + 1)
  }, [])

  // EXECUTION-layer node actions (bind session / dispatch) apply DIRECTLY — no
  // proposal, no owner approval. Just merge the returned graph state. Must NOT
  // touch `reviewRequestTick` / the proposal review modal.
  const handleNodeMutated = useCallback((next: PlannerCanvasState) => {
    setPlannerState(next)
  }, [])

  // Gap 5 — owner-only canvas visibility. This is canvas metadata rather than
  // graph topology, but it changes who can see the planning space, so require
  // explicit confirmation before applying.
  const handleConfirmVisibility = useCallback((visibility: PlannerCanvasVisibility) => {
    setBusy(true)
    setError(null)
    setPlannerCanvasVisibility(canvasId, visibility)
      .then((canvas) => {
        setPlannerState((current) => current ? { ...current, canvas } : current)
        setPendingVisibility(null)
      })
      .catch((err) => setError((err as Error).message || 'Failed to update canvas visibility'))
      .finally(() => setBusy(false))
  }, [canvasId])

  const handleStartRun = useCallback((input: StartDeliveryInput) => {
    setBusy(true)
    setError(null)
    startPlannerRun(canvasId, input)
      .then((run) => {
        setRuns((current) => [...current, run])
        setSelectedRunId(run.id)
        setMode('run')
        // The fresh Delivery resets per-node execution state — re-pull the graph.
        loadState()
      })
      .catch((err) => setError((err as Error).message || 'Failed to start delivery'))
      .finally(() => setBusy(false))
  }, [canvasId, loadState])

  const handleAbortRun = useCallback((runId: string) => {
    setBusy(true)
    setError(null)
    abortPlannerRun(runId)
      .then((run) => {
        setRuns((current) => current.map((item) => (item.id === run.id ? run : item)))
      })
      .catch((err) => setError((err as Error).message || 'Failed to abort delivery'))
      .finally(() => setBusy(false))
  }, [])

  const canvasVisibility: PlannerCanvasVisibility = plannerState?.canvas.visibility ?? 'private'
  const isCanvasOwner = (plannerState?.access?.role ?? 'owner') === 'owner'
  const plannerMainStyle = {
    '--planner-panel-width': `${plannerPanelWidth}px`,
  } as CSSProperties

  return (
    <section className="planner-workspace" aria-label="meee2 AI graph">
      <div
        className={`planner-main${plannerPanelCollapsed ? ' planner-main--panel-collapsed' : ''}`}
        style={plannerMainStyle}
      >
        <button
          type="button"
          className={`planner-dialog-toggle${plannerPanelCollapsed ? ' is-collapsed' : ''}`}
          onClick={() => setPlannerPanelCollapsed((value) => !value)}
          aria-label={plannerPanelCollapsed ? 'Open meee2 AI dialog' : 'Collapse meee2 AI dialog'}
        >
          {plannerPanelCollapsed ? <PanelRightOpen size={16} aria-hidden /> : <PanelRightClose size={16} aria-hidden />}
        </button>
        <div className="planner-flow">
          <div className="planner-flow__header">
            <RunSelector
              mode={mode}
              onModeChange={setMode}
              runs={runs}
              selectedRunId={selectedRunId}
              onSelectRun={setSelectedRunId}
              onStartRun={handleStartRun}
              onAbortRun={handleAbortRun}
              onViewHistory={() => setHistoryOpen(true)}
              busy={busy}
            />
            <div className={`planner-flow__state-badge${previewActive ? ' is-preview' : ''}`}>
              <span>{previewActive ? 'Preview' : 'Live graph'}</span>
              {previewActive && <em>not applied</em>}
            </div>
            {/* Gap 5 — canvas visibility. Owner gets a toggle; others see a badge. */}
            {isCanvasOwner ? (
              <div
                className="planner-flow__visibility"
                role="group"
                aria-label="Canvas visibility"
              >
                <button
                  type="button"
                  className={`planner-flow__visibility-option is-private${canvasVisibility === 'private' ? ' is-active' : ''}`}
                  disabled={busy || canvasVisibility === 'private'}
                  onClick={() => setPendingVisibility('private')}
                >
                  Private
                </button>
                <button
                  type="button"
                  className={`planner-flow__visibility-option is-public${canvasVisibility === 'public' ? ' is-active' : ''}`}
                  disabled={busy || canvasVisibility === 'public'}
                  onClick={() => setPendingVisibility('public')}
                >
                  Public
                </button>
              </div>
            ) : (
              <span
                className="planner-flow__visibility-badge"
                title="Only the canvas owner can change visibility."
              >
                {canvasVisibility === 'public' ? 'Public' : 'Private'}
              </span>
            )}
          </div>
          {pendingVisibility && (
            <div
              className="planner-visibility-confirm-backdrop"
              onMouseDown={(event) => {
                if (event.target === event.currentTarget) setPendingVisibility(null)
              }}
            >
              <div
                className={`planner-visibility-confirm planner-visibility-confirm--${pendingVisibility}`}
                role="dialog"
                aria-modal="true"
                aria-label="Confirm canvas visibility"
              >
                <div className="planner-visibility-confirm__header">
                  <span>{pendingVisibility === 'public' ? 'Make canvas public?' : 'Make canvas private?'}</span>
                  <strong>{plannerState?.canvas.title ?? canvasName}</strong>
                </div>
                <p>
                  {pendingVisibility === 'public'
                    ? 'People with workspace access will be able to view this canvas. Topology edits still stay owner-controlled.'
                    : 'Only you and explicitly allowed local access can view this canvas. Shared viewers may lose visibility.'}
                </p>
                <div className="planner-visibility-confirm__actions">
                  <button type="button" className="ghost" onClick={() => setPendingVisibility(null)}>
                    Cancel
                  </button>
                  <button
                    type="button"
                    className={pendingVisibility === 'public' ? 'primary' : 'ghost'}
                    disabled={busy}
                    onClick={() => handleConfirmVisibility(pendingVisibility)}
                  >
                    {pendingVisibility === 'public' ? 'Confirm public' : 'Confirm private'}
                  </button>
                </div>
              </div>
            </div>
          )}
          {/* U5 — onboarding: blueprint exists but has never been executed. */}
          {mode === 'run' && runs.length === 0 && (plannerState?.nodes.length ?? 0) > 0 && (
            <div className="planner-onboarding-card" role="note">
              <strong>Plan is ready</strong>
              <p>
                Start a named <b>Delivery</b> when you have a real request to execute.
                Sessions and outputs belong to that Delivery, not to the Plan.
              </p>
              <button
                type="button"
                className="primary"
                disabled={busy}
                onClick={() => handleStartRun({ title: `${canvasName} delivery` })}
              >
                ▶ Start delivery
              </button>
            </div>
          )}
          {plannerState ? (
            <ReactFlow
              nodes={flowNodes}
              edges={graph.edges}
              nodeTypes={nodeTypes}
              onNodesChange={handleNodesChange}
              onNodeClick={(_, node) => {
                setSelectedNodeId(node.data.node.id)
                setNodeModalOpen(true)
              }}
              onNodeDragStop={(_, node) => {
                updatePlannerNodeLayout(canvasId, node.data.node.id, {
                  x: node.position.x,
                  y: node.position.y,
                  width: node.width ?? node.measured?.width ?? null,
                  height: node.height ?? node.measured?.height ?? null,
                }).catch(() => {
                  // Layout persistence should not interrupt graph interaction.
                })
              }}
              onPaneClick={() => {
                setSelectedNodeId(null)
                setNodeModalOpen(false)
              }}
              nodesDraggable
              fitView={!window.matchMedia('(max-width: 720px)').matches}
              minZoom={0.35}
              maxZoom={1.6}
              proOptions={{ hideAttribution: true }}
            >
              <Background color="rgba(168, 165, 155, 0.10)" gap={32} />
              <PlannerOverviewMap nodes={flowNodes} edges={graph.edges} />
              <Controls className="planner-flow__controls" />
            </ReactFlow>
          ) : (
            <div className="planner-empty-state">
              <div className="boot-spinner" />
              <span>Loading meee2 AI graph</span>
            </div>
          )}
        </div>

        {!plannerPanelCollapsed && (
          <div className="planner-side">
            <button
              type="button"
              className="planner-side__resize"
              aria-label="Resize meee2 AI panel"
              onPointerDown={handlePanelResizeStart}
            />
            <PlannerProposalPanel
              proposal={proposal}
              previewActive={previewActive}
              busy={busy}
              error={error}
              access={plannerState?.access ?? null}
              nodeCount={plannerState?.nodes.length ?? 0}
              hasActionableDrift={hasActionableDrift}
              onSubmit={handlePlannerSubmit}
              onApplyPreview={handleApplyPreview}
              onApprove={handleApprove}
              onApply={handleApply}
              onApproveAndApply={handleApproveAndApply}
              onReject={handleReject}
              onCreateDeliveryPipeline={handleCreateDeliveryPipeline}
              reviewRequestTick={reviewRequestTick}
            />
          </div>
        )}
      </div>
      {nodeModalOpen && selectedNode && (
        <NodeInspectorModal
          node={selectedNode}
          canvasId={canvasId}
          mode={mode}
          selectedDeliveryId={selectedRun?.id ?? null}
          runNodeState={selectedRun?.nodeStates[selectedNode.id] ?? null}
          onArtifactAttached={() => {
            // Re-pull graph state so the new artifact shows in the node list.
            fetchPlannerGraphState(canvasId)
              .then((state) => setPlannerState(state))
              .catch(() => {
                // Best-effort; the attach itself already succeeded.
              })
          }}
          state={plannerState?.states.find((item) => item.nodeId === selectedNode.id) ?? null}
          ownerLabel={
            plannerState?.canvas.ownerId
              ? teamDirectory.displayNameByUserId[plannerState.canvas.ownerId]
              : undefined
          }
          ownerAvatarUrl={
            plannerState?.canvas.ownerId
              ? teamDirectory.avatarUrlByUserId[plannerState.canvas.ownerId]
              : undefined
          }
          doerLabel={
            selectedNode.doerId
              ? teamDirectory.displayNameByUserId[selectedNode.doerId] ?? selectedNode.doerId
              : undefined
          }
          access={plannerState?.access ?? null}
          sessions={boardState?.sessions ?? []}
          teamMembers={teamMembers}
          onProposalCreated={handleNodeActionProposal}
          onNodeMutated={handleNodeMutated}
          onDeliveryMutated={(run) => {
            setRuns((current) => current.map((item) => (item.id === run.id ? run : item)))
          }}
          onClose={() => setNodeModalOpen(false)}
          onOpenSubCanvas={onOpenSubCanvas}
        />
      )}
      {historyOpen && (
        <RunHistoryView
          runs={runs}
          selectedRunId={selectedRunId}
          onSelectRun={(runId) => {
            setSelectedRunId(runId)
            setMode('run')
          }}
          onClose={() => setHistoryOpen(false)}
        />
      )}
    </section>
  )
}

function readStoredPanelCollapsed(): boolean {
  if (typeof window === 'undefined') return false
  return window.localStorage.getItem(PANEL_COLLAPSED_KEY) === '1'
}

function readStoredPanelWidth(): number {
  if (typeof window === 'undefined') return DEFAULT_PANEL_WIDTH
  const stored = Number(window.localStorage.getItem(PANEL_WIDTH_KEY))
  if (!Number.isFinite(stored)) return DEFAULT_PANEL_WIDTH
  return clampPanelWidth(stored)
}

function clampPanelWidth(width: number): number {
  return Math.min(MAX_PANEL_WIDTH, Math.max(MIN_PANEL_WIDTH, Math.round(width)))
}

function shouldInspectDrift(
  message: string,
  state: PlannerCanvasState | null,
  hasActionableDrift: boolean,
): boolean {
  if (!state || state.nodes.length === 0) return false
  if (!message.trim()) return hasActionableDrift
  const normalized = message.toLowerCase()
  return hasActionableDrift && [
    'blocked',
    'drift',
    'fix',
    'repair',
    'review',
    'stuck',
    '卡',
    '修',
    '检查',
    '跑偏',
    '阻塞',
  ].some((keyword) => normalized.includes(keyword))
}

function upsertProposal(proposals: PlanProposal[], proposal: PlanProposal): PlanProposal[] {
  const index = proposals.findIndex((item) => item.id === proposal.id)
  if (index < 0) return [...proposals, proposal]
  return proposals.map((item, itemIndex) => itemIndex === index ? proposal : item)
}

function defaultPlannerAccess() {
  return {
    actorId: 'local-owner',
    role: 'owner' as const,
    canCreateProposal: true,
    canApproveProposal: true,
    canApplyProposal: true,
    canRejectProposal: true,
    canUpdateAssignedNode: true,
  }
}
