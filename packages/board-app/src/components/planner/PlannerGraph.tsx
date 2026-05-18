import {
  Background,
  Controls,
  MiniMap,
  ReactFlow,
  ReactFlowProvider,
  applyNodeChanges,
  type NodeChange,
  useReactFlow,
} from '@xyflow/react'
import { MessageSquare, X } from 'lucide-react'
import { useCallback, useEffect, useMemo, useState } from 'react'
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
import { PlannerProposalPanel } from './PlannerProposalPanel'
import { RunHistoryView } from './RunHistoryView'
import { RunSelector, type PlannerMode } from './RunSelector'
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
  const [plannerPanelCollapsed, setPlannerPanelCollapsed] = useState(false)
  const [flowNodes, setFlowNodes] = useState<PlannerGraphNode[]>([])
  const [teamMembers, setTeamMembers] = useState<TeamMember[]>([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
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

  // Gap 5 — owner-only canvas visibility. Applies immediately (canvas metadata,
  // not a graph proposal); the updated canvas record is merged back into state.
  const handleSetVisibility = useCallback((visibility: PlannerCanvasVisibility) => {
    setBusy(true)
    setError(null)
    setPlannerCanvasVisibility(canvasId, visibility)
      .then((canvas) => {
        setPlannerState((current) => current ? { ...current, canvas } : current)
      })
      .catch((err) => setError((err as Error).message || 'Failed to update canvas visibility'))
      .finally(() => setBusy(false))
  }, [canvasId])

  // P2 Run layer — start / select / abort a workflow run. Decision A: a run
  // is one execution of the blueprint; the graph itself stays the design.
  const handleStartRun = useCallback(() => {
    setBusy(true)
    setError(null)
    startPlannerRun(canvasId)
      .then((run) => {
        setRuns((current) => [...current, run])
        setSelectedRunId(run.id)
        setMode('run')
        // The fresh run resets per-node execution state — re-pull the graph.
        loadState()
      })
      .catch((err) => setError((err as Error).message || 'Failed to start run'))
      .finally(() => setBusy(false))
  }, [canvasId, loadState])

  const handleAbortRun = useCallback((runId: string) => {
    setBusy(true)
    setError(null)
    abortPlannerRun(runId)
      .then((run) => {
        setRuns((current) => current.map((item) => (item.id === run.id ? run : item)))
      })
      .catch((err) => setError((err as Error).message || 'Failed to abort run'))
      .finally(() => setBusy(false))
  }, [])

  const canvasVisibility: PlannerCanvasVisibility = plannerState?.canvas.visibility ?? 'private'
  const isCanvasOwner = (plannerState?.access?.role ?? 'owner') === 'owner'

  return (
    <section className="planner-workspace" aria-label="meee2 AI graph">
      <div className={`planner-main${plannerPanelCollapsed ? ' planner-main--panel-collapsed' : ''}`}>
        <button
          type="button"
          className={`planner-dialog-toggle${plannerPanelCollapsed ? ' is-collapsed' : ''}`}
          onClick={() => setPlannerPanelCollapsed((value) => !value)}
          aria-label={plannerPanelCollapsed ? 'Open meee2 AI dialog' : 'Collapse meee2 AI dialog'}
        >
          {plannerPanelCollapsed ? <MessageSquare size={16} aria-hidden /> : <X size={15} aria-hidden />}
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
                  className={canvasVisibility === 'private' ? 'is-active' : ''}
                  disabled={busy || canvasVisibility === 'private'}
                  onClick={() => handleSetVisibility('private')}
                >
                  Private
                </button>
                <button
                  type="button"
                  className={canvasVisibility === 'public' ? 'is-active' : ''}
                  disabled={busy || canvasVisibility === 'public'}
                  onClick={() => handleSetVisibility('public')}
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
          {/* U5 — onboarding: blueprint exists but has never been executed. */}
          {mode === 'run' && runs.length === 0 && (plannerState?.nodes.length ?? 0) > 0 && (
            <div className="planner-onboarding-card" role="note">
              <strong>Blueprint is ready ✓</strong>
              <p>
                A <b>run</b> executes this blueprint once — each run tracks its own
                progress, AI sessions and artifacts. The blueprint itself never runs.
              </p>
              <button type="button" className="primary" disabled={busy} onClick={handleStartRun}>
                ▶ Start the first run
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
              fitView={!window.matchMedia('(max-width: 720px)').matches}
              minZoom={0.35}
              maxZoom={1.6}
              proOptions={{ hideAttribution: true }}
            >
              <Background color="rgba(168, 165, 155, 0.10)" gap={32} />
              <MiniMap
                className="planner-flow__minimap"
                position="bottom-right"
                nodeColor={miniMapNodeFill}
                nodeStrokeColor={miniMapNodeColor}
                nodeBorderRadius={4}
                nodeStrokeWidth={3}
                bgColor="rgba(31, 31, 29, 0.96)"
                maskColor="rgba(20, 20, 18, 0.62)"
                maskStrokeColor="rgba(204, 120, 92, 0.55)"
                maskStrokeWidth={2}
                offsetScale={6}
                pannable
                zoomable
              />
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

function miniMapNodeFill(node: { data?: Record<string, unknown> }): string {
  const data = node.data
  const plannerNode = data?.node as { nodeKind?: string; source?: string } | null | undefined
  const kind = plannerNode?.nodeKind ?? (plannerNode?.source === 'session' ? 'session' : 'step')
  switch (kind) {
    case 'session':
      return 'rgba(38, 45, 50, 0.94)'
    case 'artifact':
      return 'rgba(48, 43, 34, 0.94)'
    case 'subCanvas':
      return 'rgba(51, 44, 40, 0.94)'
    case 'external':
      return 'rgba(54, 53, 50, 0.72)'
    default:
      return 'rgba(44, 43, 41, 0.94)'
  }
}

// Stroke colors mirror the .planner-node--<runState> border-left tokens so the
// minimap reads as a faithful miniature of the graph's status coloring.
function miniMapNodeColor(node: { data?: Record<string, unknown> }): string {
  const data = node.data
  const state = data?.state as { runState?: string; needsOwnerReview?: boolean } | null | undefined
  const plannerNode = data?.node as { status?: string } | null | undefined
  const status = state?.needsOwnerReview ? 'review' : state?.runState ?? plannerNode?.status
  switch (status) {
    case 'blocked':
    case 'review':
      return '#C26A6A' // --danger
    case 'running':
      return '#8BA9C2' // --info
    case 'planning':
      return '#D4A373' // --warning
    case 'done':
      return '#7FA982' // --success
    case 'waiting':
    default:
      return '#A8A59B' // --text-dim
  }
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
