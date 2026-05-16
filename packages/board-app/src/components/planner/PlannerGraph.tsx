import {
  Background,
  Controls,
  ReactFlow,
  ReactFlowProvider,
  useReactFlow,
} from '@xyflow/react'
import { RefreshCw } from 'lucide-react'
import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  applyPlannerProposal,
  applyPlannerProposalPreview,
  approvePlannerProposal,
  fetchPlannerCanvasState,
  generatePlannerProposal,
  inspectPlannerDrift,
  refinePlannerNode,
  rejectPlannerProposal,
  sendPlannerActivity,
} from '../../api'
import type { PlanProposal, PlannerCanvasState, PlanningNode } from '../../types'
import { PlannerNodeCard } from './PlannerNodeCard'
import { PlannerProposalPanel } from './PlannerProposalPanel'
import { buildPlannerGraph, groupStatesByRisk } from './plannerGraphAdapter'
import './planner.css'

interface Props {
  canvasId: string
  canvasName: string
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

function PlannerGraphInner({ canvasId, canvasName, onOpenSubCanvas }: Props) {
  const reactFlow = useReactFlow()
  const [plannerState, setPlannerState] = useState<PlannerCanvasState | null>(null)
  const [proposal, setProposal] = useState<PlanProposal | null>(null)
  const [previewActive, setPreviewActive] = useState(false)
  const [selectedNodeId, setSelectedNodeId] = useState<string | null>(null)
  const [statesOpen, setStatesOpen] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const loadState = useCallback(() => {
    setBusy(true)
    setError(null)
    fetchPlannerCanvasState(canvasId)
      .then((state) => {
        setPlannerState(state)
        setProposal(state.proposals.find((item) => item.status === 'pending' || item.status === 'approved') ?? null)
        setPreviewActive(false)
      })
      .catch((err) => setError((err as Error).message || 'Failed to load planner state'))
      .finally(() => setBusy(false))
  }, [canvasId])

  useEffect(() => {
    loadState()
  }, [loadState])

  const graph = useMemo(() => {
    return buildPlannerGraph({
      nodes: plannerState?.nodes ?? [],
      states: plannerState?.states ?? [],
      proposal: previewActive ? null : proposal,
      onOpenSubCanvas,
    })
  }, [plannerState, previewActive, proposal, onOpenSubCanvas])

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

  const groupedStates = useMemo(() => {
    if (!plannerState) return []
    return groupStatesByRisk(plannerState.nodes, plannerState.states)
  }, [plannerState])

  const selectedNode = useMemo(() => {
    if (!selectedNodeId || !plannerState) return null
    return plannerState.nodes.find((node) => node.id === selectedNodeId) ?? null
  }, [plannerState, selectedNodeId])

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
      .catch((err) => setError((err as Error).message || 'Failed to generate planner proposal'))
      .finally(() => setBusy(false))
  }, [canvasId])

  const handleInspectDrift = useCallback(() => {
    setBusy(true)
    setError(null)
    inspectPlannerDrift(canvasId)
      .then((next) => {
        setProposal(next)
        setPlannerState((current) => current && next
          ? { ...current, proposals: upsertProposal(current.proposals, next) }
          : current)
        setPreviewActive(false)
        if (!next) setError('No blocked or owner-review state found.')
      })
      .catch((err) => setError((err as Error).message || 'Failed to inspect planner drift'))
      .finally(() => setBusy(false))
  }, [canvasId])

  const handleRefineNode = useCallback((reason: string) => {
    if (!selectedNode) return
    setBusy(true)
    setError(null)
    refinePlannerNode(canvasId, selectedNode.id, reason)
      .then((next) => {
        setProposal(next)
        setPlannerState((current) => current && next
          ? { ...current, proposals: upsertProposal(current.proposals, next) }
          : current)
        setPreviewActive(false)
      })
      .catch((err) => setError((err as Error).message || 'Failed to refine planner node'))
      .finally(() => setBusy(false))
  }, [canvasId, selectedNode])

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
          }
        })
        setPreviewActive(true)
      })
      .catch((err) => setError((err as Error).message || 'Failed to apply planner preview'))
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
      .catch((err) => setError((err as Error).message || 'Failed to approve planner proposal'))
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
          }
        })
        setPreviewActive(false)
      })
      .catch((err) => setError((err as Error).message || 'Failed to apply planner proposal'))
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
      .catch((err) => setError((err as Error).message || 'Failed to reject planner proposal'))
      .finally(() => setBusy(false))
  }, [canvasId, proposal])

  return (
    <section className="planner-workspace" aria-label="Planner graph">
      <div className="planner-topbar">
        <div>
          <h1>{displayPlannerTitle(plannerState?.canvas.title ?? canvasName)}</h1>
          <p>Planner proposes. Owner approves.</p>
        </div>
        {plannerState?.access && (
          <span className={`planner-role-badge planner-role-badge--${plannerState.access.role}`}>
            {plannerState.access.role}
          </span>
        )}
        <button type="button" onClick={loadState} disabled={busy}>
          <RefreshCw size={14} aria-hidden />
          Refresh
        </button>
      </div>
      <ActivityStrip activities={plannerState?.activities ?? []} />

      <div className="planner-main">
        <div className="planner-flow">
          {plannerState ? (
            <ReactFlow
              nodes={graph.nodes}
              edges={graph.edges}
              nodeTypes={nodeTypes}
              onNodeClick={(_, node) => setSelectedNodeId(node.data.node.id)}
              onPaneClick={() => setSelectedNodeId(null)}
              fitView={!window.matchMedia('(max-width: 720px)').matches}
              minZoom={0.35}
              maxZoom={1.6}
              proOptions={{ hideAttribution: true }}
            >
              <Background color="rgba(168, 165, 155, 0.10)" gap={32} />
              <Controls className="planner-flow__controls" />
            </ReactFlow>
          ) : (
            <div className="planner-empty-state">
              <div className="boot-spinner" />
              <span>Loading planner graph</span>
            </div>
          )}
        </div>

        <div className="planner-side">
          <PlannerProposalPanel
            proposal={proposal}
            previewActive={previewActive}
            busy={busy}
            error={error}
            access={plannerState?.access ?? null}
            selectedNode={selectedNode}
            onGenerate={handleGenerate}
            onInspectDrift={handleInspectDrift}
            onRefineNode={handleRefineNode}
            onApplyPreview={handleApplyPreview}
            onApprove={handleApprove}
            onApply={handleApply}
            onReject={handleReject}
          />
          <StatesSummary
            groups={groupedStates}
            open={statesOpen}
            onToggle={() => setStatesOpen((value) => !value)}
          />
          {statesOpen && <StatesList groups={groupedStates} />}
        </div>
      </div>
    </section>
  )
}

function ActivityStrip({
  activities,
}: {
  activities: NonNullable<PlannerCanvasState['activities']>
}) {
  if (activities.length === 0) return null
  return (
    <div className="planner-activity-strip" aria-label="Planner activity">
      {activities.map((activity) => (
        <div key={`${activity.userId}-${activity.currentCanvasId}`} className="planner-activity-pill">
          <span>{activity.displayName || activity.userId}</span>
          {activity.selectedNodeId && <em>node {shortId(activity.selectedNodeId)}</em>}
          {activity.selectedSessionId && <em>session {shortId(activity.selectedSessionId)}</em>}
        </div>
      ))}
    </div>
  )
}

function shortId(id: string) {
  return id.length > 14 ? `${id.slice(0, 10)}...` : id
}

function displayPlannerTitle(title: string): string {
  return title === 'Default canvas' ? 'My' : title
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

function StatesSummary({
  groups,
  open,
  onToggle,
}: {
  groups: Array<{ key: string; label: string; nodes: PlanningNode[] }>
  open: boolean
  onToggle: () => void
}) {
  const blocked = groups
    .filter((group) => group.key === 'blocked')
    .reduce((sum, group) => sum + group.nodes.length, 0)
  const running = groups
    .filter((group) => group.key === 'running')
    .reduce((sum, group) => sum + group.nodes.length, 0)
  const total = groups.reduce((sum, group) => sum + group.nodes.length, 0)
  return (
    <button
      type="button"
      className="planner-states-summary"
      aria-expanded={open}
      onClick={onToggle}
    >
      <span>
        <strong>{blocked}</strong>
        Review
      </span>
      <span>
        <strong>{running}</strong>
        Running
      </span>
      <em>{open ? 'Hide states' : `${total} nodes`}</em>
    </button>
  )
}

function StatesList({
  groups,
}: {
  groups: Array<{ key: string; label: string; nodes: PlanningNode[] }>
}) {
  return (
    <aside className="planner-states-list">
      <div className="planner-states-list__header">
        <h2>States</h2>
        <span>{groups.reduce((sum, group) => sum + group.nodes.length, 0)} nodes</span>
      </div>
      {groups.map((group) => (
        <div key={group.key} className="planner-states-group">
          <div className="planner-states-group__title">{group.label}</div>
          {group.nodes.map((node) => (
            <div key={node.id} className={`planner-states-row planner-states-row--${node.status}`}>
              <span>{node.title}</span>
              <em>{node.doerId}</em>
            </div>
          ))}
        </div>
      ))}
    </aside>
  )
}
