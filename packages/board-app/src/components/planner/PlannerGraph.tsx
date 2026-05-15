import {
  Background,
  Controls,
  MiniMap,
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
  rejectPlannerProposal,
} from '../../api'
import type { PlanProposal, PlannerCanvasState, PlanningNode } from '../../types'
import { PlannerNodeCard } from './PlannerNodeCard'
import { PlannerProposalPanel } from './PlannerProposalPanel'
import { buildPlannerGraph, groupStatesByRisk } from './plannerGraphAdapter'
import './planner.css'

interface Props {
  canvasId: string
  canvasName: string
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

function PlannerGraphInner({ canvasId, canvasName }: Props) {
  const reactFlow = useReactFlow()
  const [plannerState, setPlannerState] = useState<PlannerCanvasState | null>(null)
  const [proposal, setProposal] = useState<PlanProposal | null>(null)
  const [previewActive, setPreviewActive] = useState(false)
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
    })
  }, [plannerState, previewActive, proposal])

  useEffect(() => {
    window.setTimeout(() => {
      reactFlow.fitView({ padding: 0.18, duration: 220 })
    }, 0)
  }, [graph.nodes.length, canvasId, reactFlow])

  const groupedStates = useMemo(() => {
    if (!plannerState) return []
    return groupStatesByRisk(plannerState.nodes, plannerState.states)
  }, [plannerState])

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
          <h1>{plannerState?.canvas.title ?? canvasName}</h1>
          <p>React Flow Planner Graph · owner-controlled topology</p>
        </div>
        <button type="button" onClick={loadState} disabled={busy}>
          <RefreshCw size={14} aria-hidden />
          Refresh
        </button>
      </div>

      <div className="planner-main">
        <div className="planner-flow">
          {plannerState ? (
            <ReactFlow
              nodes={graph.nodes}
              edges={graph.edges}
              nodeTypes={nodeTypes}
              fitView
              minZoom={0.35}
              maxZoom={1.6}
              proOptions={{ hideAttribution: true }}
            >
              <Background color="rgba(168, 165, 155, 0.16)" gap={28} />
              <MiniMap
                className="planner-flow__minimap"
                pannable
                zoomable
                nodeStrokeWidth={2}
              />
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
            onGenerate={handleGenerate}
            onInspectDrift={handleInspectDrift}
            onApplyPreview={handleApplyPreview}
            onApprove={handleApprove}
            onApply={handleApply}
            onReject={handleReject}
          />
          <StatesList groups={groupedStates} />
        </div>
      </div>
    </section>
  )
}

function upsertProposal(proposals: PlanProposal[], proposal: PlanProposal): PlanProposal[] {
  const index = proposals.findIndex((item) => item.id === proposal.id)
  if (index < 0) return [...proposals, proposal]
  return proposals.map((item, itemIndex) => itemIndex === index ? proposal : item)
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
