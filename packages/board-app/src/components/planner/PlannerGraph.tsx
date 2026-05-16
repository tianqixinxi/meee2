import {
  Background,
  Controls,
  MiniMap,
  ReactFlow,
  ReactFlowProvider,
  useReactFlow,
} from '@xyflow/react'
import { ChevronLeft, ChevronRight, X } from 'lucide-react'
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
import { buildPlannerGraph } from './plannerGraphAdapter'
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
  const [nodeModalOpen, setNodeModalOpen] = useState(false)
  const [plannerPanelCollapsed, setPlannerPanelCollapsed] = useState(false)
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
      <div className={`planner-main${plannerPanelCollapsed ? ' planner-main--panel-collapsed' : ''}`}>
        <div className="planner-flow">
          {plannerState ? (
            <ReactFlow
              nodes={graph.nodes}
              edges={graph.edges}
              nodeTypes={nodeTypes}
              onNodeClick={(_, node) => {
                setSelectedNodeId(node.data.node.id)
                setNodeModalOpen(true)
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
                nodeColor={miniMapNodeColor}
                nodeStrokeColor="rgba(245, 244, 239, 0.34)"
                nodeBorderRadius={3}
                nodeStrokeWidth={2}
                bgColor="rgba(31, 31, 29, 0.96)"
                maskColor="rgba(245, 244, 239, 0.08)"
                maskStrokeColor="rgba(245, 244, 239, 0.24)"
                maskStrokeWidth={1}
                offsetScale={8}
                pannable
                zoomable
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
          <button
            type="button"
            className="planner-side__collapse"
            onClick={() => setPlannerPanelCollapsed((value) => !value)}
            aria-label={plannerPanelCollapsed ? 'Open planner dialog' : 'Collapse planner dialog'}
          >
            {plannerPanelCollapsed ? <ChevronLeft size={16} aria-hidden /> : <ChevronRight size={16} aria-hidden />}
          </button>
          {!plannerPanelCollapsed && (
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
          )}
        </div>
      </div>
      {nodeModalOpen && selectedNode && (
        <NodeInspectorModal
          node={selectedNode}
          state={plannerState?.states.find((item) => item.nodeId === selectedNode.id) ?? null}
          onClose={() => setNodeModalOpen(false)}
        />
      )}
    </section>
  )
}

function NodeInspectorModal({
  node,
  state,
  onClose,
}: {
  node: PlanningNode
  state: PlannerCanvasState['states'][number] | null
  onClose: () => void
}) {
  return (
    <div
      className="planner-modal-backdrop"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onClose()
      }}
    >
      <div className="planner-node-modal" role="dialog" aria-modal="true" aria-label="Node details">
        <button type="button" className="planner-node-modal__close" onClick={onClose} aria-label="Close node details">
          <X size={15} aria-hidden />
        </button>
        <div className="planner-node-modal__header">
          <span>{state?.runState ?? node.status}</span>
          <h2>{node.title}</h2>
        </div>
        <div className="planner-node-modal__grid">
          <span>Executor</span>
          <strong>{node.executorType} / {node.executionMode}</strong>
          <span>Doer</span>
          <strong>{node.doerId}</strong>
          <span>Consumes</span>
          <strong>{node.ioSchema.consumes.length > 0 ? node.ioSchema.consumes.join(', ') : 'none'}</strong>
          <span>Produces</span>
          <strong>{node.ioSchema.produces.length > 0 ? node.ioSchema.produces.join(', ') : 'none'}</strong>
          <span>Dependencies</span>
          <strong>{node.dependsOnNodeIds?.length ?? 0}</strong>
        </div>
        {state?.blockers.length ? (
          <div className="planner-node-modal__blockers">
            {state.blockers.map((blocker) => <span key={blocker}>{blocker}</span>)}
          </div>
        ) : null}
      </div>
    </div>
  )
}

function miniMapNodeColor(node: { data?: Record<string, unknown> }): string {
  const data = node.data
  const state = data?.state as { runState?: string; needsOwnerReview?: boolean } | null | undefined
  const plannerNode = data?.node as { status?: string } | null | undefined
  const status = state?.needsOwnerReview ? 'review' : state?.runState ?? plannerNode?.status
  switch (status) {
    case 'blocked':
    case 'review':
      return '#c26a6a'
    case 'running':
      return '#8ba9c2'
    case 'planning':
      return '#c9a45d'
    case 'done':
      return '#79ad87'
    case 'waiting':
    default:
      return '#8c8980'
  }
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
