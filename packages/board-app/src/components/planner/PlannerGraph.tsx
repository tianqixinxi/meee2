import {
  Background,
  Controls,
  ReactFlow,
  ReactFlowProvider,
  applyNodeChanges,
  type NodeChange,
  useReactFlow,
} from '@xyflow/react'
import { AlertTriangle, PanelRightClose, PanelRightOpen, RefreshCw } from 'lucide-react'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { CSSProperties, PointerEvent as ReactPointerEvent } from 'react'
import {
  applyPlannerProposal,
  approvePlannerProposal,
  activateSession,
  abandonPlannerNodeSession,
  bindPlannerSessionToNode,
  bindPlannerNodeInput,
  deletePlannerNode,
  detachPlannerNodeSession,
  dispatchPlannerNodeSession,
  fetchMeee2MCPStatus,
  fetchPlannerGraphState,
  fetchState,
  fetchTeamMembers,
  generatePlannerProposal,
  inspectPlannerDrift,
  openKanbanItemSubCanvas,
  rejectPlannerProposal,
  sendPlannerActivity,
  updatePlannerNodeGate,
  updatePlannerNodeLayout,
  updatePlannerNodeStatus,
} from '../../api'
import type {
  PlanProposal,
  PlannerCanvasState,
  PlannerArtifact,
  PlannerDispatchRunner,
  PlannerGraphState,
  Meee2MCPStatus,
  PlanningNode,
  PlanningNodeStatus,
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
import { buildPlannerGraph, type IOArtifactDirection, type IOArtifactVisibility, type PlannerGraphNode } from './plannerGraphAdapter'
import './planner.css'

interface Props {
  canvasId: string
  canvasName: string
  workspacePath?: string
  variant?: 'board' | 'template'
  userProfile?: UserProfile | null
  boardState?: BoardState | null
  clearRevision?: number
  onOpenSubCanvas?: (canvasId: string) => void
  onNotify?: (kind: 'success' | 'error', text: string) => void
}

const nodeTypes = {
  plannerNode: PlannerNodeCard,
}

const PANEL_WIDTH_KEY = 'meee2.planner.aiPanelWidth'
const PANEL_COLLAPSED_KEY = 'meee2.planner.aiPanelCollapsed'
const IO_ARTIFACT_VISIBILITY_KEY_PREFIX = 'meee2.planner.ioArtifacts'
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

function PlannerGraphInner({
  canvasId,
  canvasName,
  workspacePath = '',
  variant = 'board',
  userProfile = null,
  boardState = null,
  clearRevision = 0,
  onOpenSubCanvas,
  onNotify,
}: Props) {
  const reactFlow = useReactFlow()
  const [plannerState, setPlannerState] = useState<PlannerCanvasState | null>(null)
  const [proposal, setProposal] = useState<PlanProposal | null>(null)
  const [selectedNodeId, setSelectedNodeId] = useState<string | null>(null)
  const [nodeModalOpen, setNodeModalOpen] = useState(false)
  const [plannerPanelCollapsed, setPlannerPanelCollapsed] = useState(() => readStoredPanelCollapsed())
  const [plannerPanelWidth, setPlannerPanelWidth] = useState(() => readStoredPanelWidth())
  const [ioArtifactVisibility, setIOArtifactVisibility] = useState<Record<string, IOArtifactVisibility>>(
    () => readStoredIOArtifactVisibility(canvasId),
  )
  const ioArtifactVisibilityCanvasRef = useRef(canvasId)
  const handledClearRevisionRef = useRef(0)
  const fitViewCanvasRef = useRef<string | null>(null)
  const [flowNodes, setFlowNodes] = useState<PlannerGraphNode[]>([])
  const [teamMembers, setTeamMembers] = useState<TeamMember[]>([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [plannerDraftMessage, setPlannerDraftMessage] = useState<{ id: number; text: string } | null>(null)
  const [creatingSessionNodeIds, setCreatingSessionNodeIds] = useState<Set<string>>(() => new Set())
  const [mcpStatus, setMCPStatus] = useState<Meee2MCPStatus | null>(null)
  const [mcpStatusError, setMCPStatusError] = useState<string | null>(null)
  // Bumped whenever a new proposal is created from chat, drift inspection, or
  // node actions. PlannerProposalPanel watches this to auto-open review.
  const [reviewRequestTick, setReviewRequestTick] = useState(0)

  const loadState = useCallback(() => {
    setBusy(true)
    setError(null)
    fetchPlannerGraphState(canvasId)
      .then((state) => {
        setPlannerState(state)
        setProposal(state.proposals.find((item) => item.status === 'pending' || item.status === 'approved') ?? null)
      })
      .catch((err) => setError((err as Error).message || 'Failed to load meee2 AI state'))
      .finally(() => setBusy(false))
  }, [canvasId])

  useEffect(() => {
    loadState()
  }, [loadState])

  const refreshMCPStatus = useCallback(() => {
    setMCPStatusError(null)
    fetchMeee2MCPStatus()
      .then((status) => setMCPStatus(status))
      .catch((err) => {
        setMCPStatus(null)
        setMCPStatusError((err as Error).message || 'Failed to check Meee2 MCP status')
      })
  }, [])

  useEffect(() => {
    refreshMCPStatus()
  }, [refreshMCPStatus, canvasId])

  useEffect(() => {
    if (clearRevision <= 0) return
    if (handledClearRevisionRef.current === clearRevision) return
    handledClearRevisionRef.current = clearRevision
    setProposal(null)
    setSelectedNodeId(null)
    setNodeModalOpen(false)
    setIOArtifactVisibility({})
    if (typeof window !== 'undefined') {
      window.localStorage.removeItem(ioArtifactVisibilityKey(canvasId))
    }
    loadState()
  }, [canvasId, clearRevision, loadState])

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

  const notifyError = useCallback((message: string) => {
    onNotify?.('error', message)
  }, [onNotify])

  const warnMCPWritebackIfNeeded = useCallback(() => {
    if (!mcpStatusError && mcpStatus?.launches !== false) return
    const detail = mcpStatusError || mcpStatus?.error || 'Meee2 MCP is not available.'
    onNotify?.('error', `Artifact write-back is unavailable: ${detail}`)
  }, [mcpStatus, mcpStatusError, onNotify])

  const teamDirectory = useMemo(() => {
    const members = buildTeamDirectory({
      userProfile,
      boardState,
      canvasOwnerId: plannerState?.canvas.ownerId,
      nodes: plannerState?.nodes ?? [],
      activities: [],
      teamMembers,
    })
    return {
      displayNameByUserId: teamDisplayNameByUserId(members),
      avatarUrlByUserId: teamAvatarUrlByUserId(members),
    }
  }, [boardState, plannerState?.canvas.ownerId, plannerState?.nodes, userProfile, teamMembers])

  const handleGraphStateChanged = useCallback((state: PlannerGraphState) => {
    setPlannerState(state)
    setProposal(state.proposals.find((item) => item.status === 'pending' || item.status === 'approved') ?? null)
  }, [])

  const handleOpenKanbanItem = useCallback((
    artifact: PlannerArtifact,
    itemId: string,
    title: string,
    subCanvasId?: string | null,
  ) => {
    setBusy(true)
    setError(null)
    openKanbanItemSubCanvas(canvasId, artifact.id, itemId, {
      title,
      scope: plannerState?.canvas.visibility === 'public' ? 'team' : 'personal',
      existingSubCanvasId: subCanvasId ?? null,
    })
      .then((result) => {
        handleGraphStateChanged(result.graph)
        if (result.action === 'created') {
          onNotify?.('success', 'Sub-canvas created and linked.')
        } else if (result.action === 'replaced_missing') {
          onNotify?.('success', result.message || 'Previous sub-canvas was missing; created and linked a new one.')
        }
        onOpenSubCanvas?.(result.subCanvasId)
      })
      .catch((err) => notifyError((err as Error).message || 'Failed to open kanban item sub-canvas'))
      .finally(() => setBusy(false))
  }, [canvasId, handleGraphStateChanged, notifyError, onNotify, onOpenSubCanvas, plannerState?.canvas.visibility])

  const handleChangeNodeStatus = useCallback((nodeId: string, status: PlanningNodeStatus) => {
    const node = plannerState?.nodes.find((item) => item.id === nodeId)
    const validationMessage = node ? validateStatusChange(node, status) : null
    if (validationMessage) {
      notifyError(validationMessage)
      return
    }
    setBusy(true)
    setError(null)
    updatePlannerNodeStatus(canvasId, nodeId, status)
      .then(handleGraphStateChanged)
      .catch((err) => notifyError((err as Error).message || 'Failed to update node status'))
      .finally(() => setBusy(false))
  }, [canvasId, handleGraphStateChanged, notifyError, plannerState?.nodes])

  const handleChangeNodeGateMode = useCallback((nodeId: string, mode: 'human' | 'auto') => {
    const node = plannerState?.nodes.find((item) => item.id === nodeId)
    if (!node || gateModeForPlanningNode(node) === mode) return
    setBusy(true)
    setError(null)
    updatePlannerNodeGate(canvasId, nodeId, mode)
      .then(handleGraphStateChanged)
      .catch((err) => notifyError((err as Error).message || 'Failed to update gate mode'))
      .finally(() => setBusy(false))
  }, [canvasId, handleGraphStateChanged, notifyError, plannerState?.nodes])

  const handleBindNodeInput = useCallback((nodeId: string, input: string, reference: string) => {
    const trimmed = reference.trim()
    if (!trimmed) return
    setBusy(true)
    setError(null)
    bindPlannerNodeInput(canvasId, nodeId, {
      input,
      reference: trimmed,
      title: input,
    })
      .then(handleGraphStateChanged)
      .catch((err) => notifyError((err as Error).message || 'Failed to save input'))
      .finally(() => setBusy(false))
  }, [canvasId, handleGraphStateChanged, notifyError])

  const handleCreateNodeSession = useCallback((nodeId: string, runner: PlannerDispatchRunner) => {
    const cwd = workspacePath.trim()
    if (!cwd) {
      notifyError('Current canvas workspace is not ready yet.')
      return
    }
    warnMCPWritebackIfNeeded()
    setBusy(true)
    setError(null)
    fetchState()
      .catch(() => null)
      .then((beforeState) => {
        const existingSessionIds = new Set((beforeState?.sessions ?? []).map((session) => session.id))
        return dispatchPlannerNodeSession(canvasId, nodeId, runner, cwd)
          .then((state) => {
            handleGraphStateChanged(state)
            setCreatingSessionNodeIds((current) => new Set(current).add(nodeId))
            void pollForBoundNodeSession(canvasId, nodeId, existingSessionIds, handleGraphStateChanged, () => {
              setCreatingSessionNodeIds((current) => {
                const next = new Set(current)
                next.delete(nodeId)
                return next
              })
            })
          })
      })
      .catch((err) => notifyError((err as Error).message || 'Failed to create node session'))
      .finally(() => setBusy(false))
  }, [canvasId, handleGraphStateChanged, notifyError, warnMCPWritebackIfNeeded, workspacePath])

  const handleReplaceNodeSession = useCallback((nodeId: string, runner: PlannerDispatchRunner) => {
    const cwd = workspacePath.trim()
    if (!cwd) {
      notifyError('Current canvas workspace is not ready yet.')
      return
    }
    warnMCPWritebackIfNeeded()
    setBusy(true)
    setError(null)
    fetchState()
      .catch(() => null)
      .then((beforeState) => {
        const existingSessionIds = new Set((beforeState?.sessions ?? []).map((session) => session.id))
        return detachPlannerNodeSession(canvasId, nodeId)
          .then(handleGraphStateChanged)
          .then(() => dispatchPlannerNodeSession(canvasId, nodeId, runner, cwd))
          .then((state) => {
            handleGraphStateChanged(state)
            setCreatingSessionNodeIds((current) => new Set(current).add(nodeId))
            void pollForBoundNodeSession(canvasId, nodeId, existingSessionIds, handleGraphStateChanged, () => {
              setCreatingSessionNodeIds((current) => {
                const next = new Set(current)
                next.delete(nodeId)
                return next
              })
            })
          })
      })
      .catch((err) => notifyError((err as Error).message || 'Failed to create a new node session'))
      .finally(() => setBusy(false))
  }, [canvasId, handleGraphStateChanged, notifyError, warnMCPWritebackIfNeeded, workspacePath])

  const handleOpenNodeSession = useCallback((sessionId: string, nodeId: string) => {
    const trimmed = sessionId.trim()
    if (!trimmed) return
    setBusy(true)
    setError(null)
    activateSession(trimmed)
      .then((ok) => {
        if (ok) return
        const sessionStillVisible = (boardState?.sessions ?? []).some((session) => session.id === trimmed)
        if (!sessionStillVisible && nodeId) {
          detachPlannerNodeSession(canvasId, nodeId)
            .then(handleGraphStateChanged)
            .catch(() => undefined)
          notifyError('Session was stale and has been unbound. Replace the session to continue.')
          return
        }
        notifyError('Failed to open session')
      })
      .finally(() => setBusy(false))
  }, [boardState?.sessions, canvasId, handleGraphStateChanged, notifyError])

  const handleCancelNodeSessionCreation = useCallback((nodeId: string) => {
    setBusy(true)
    setError(null)
    abandonPlannerNodeSession(canvasId, nodeId)
      .then((state) => {
        handleGraphStateChanged(state)
        setCreatingSessionNodeIds((current) => {
          const next = new Set(current)
          next.delete(nodeId)
          return next
        })
      })
      .catch((err) => notifyError((err as Error).message || 'Failed to cancel session creation'))
      .finally(() => setBusy(false))
  }, [canvasId, handleGraphStateChanged, notifyError])

  const handleDeleteNode = useCallback((nodeId: string) => {
    setBusy(true)
    setError(null)
    deletePlannerNode(canvasId, nodeId)
      .then((state) => {
        handleGraphStateChanged(state)
        setSelectedNodeId((current) => current === nodeId ? null : current)
        setNodeModalOpen((open) => selectedNodeId === nodeId ? false : open)
        setIOArtifactVisibility((current) => {
          const next = { ...current }
          delete next[nodeId]
          for (const [sourceNodeId, visible] of Object.entries(next)) {
            const sourceNode = state.nodes.find((node) => node.id === sourceNodeId)
            if (!sourceNode) {
              delete next[sourceNodeId]
              continue
            }
            next[sourceNodeId] = {
              inputs: visible.inputs.filter((item) => sourceNode.schema.inputs.includes(item)),
              outputs: visible.outputs.filter((item) => sourceNode.schema.outputs.includes(item)),
            }
            if (next[sourceNodeId].inputs.length === 0 && next[sourceNodeId].outputs.length === 0) {
              delete next[sourceNodeId]
            }
          }
          return next
        })
      })
      .catch((err) => notifyError((err as Error).message || 'Failed to delete node'))
      .finally(() => setBusy(false))
  }, [canvasId, handleGraphStateChanged, notifyError, selectedNodeId])

  const handleHideIOArtifact = useCallback((
    nodeId: string,
    direction: IOArtifactDirection,
    item: string,
  ) => {
    setIOArtifactVisibility((current) => {
      const existing = current[nodeId]
      if (!existing) return current
      const directionKey: keyof IOArtifactVisibility = direction === 'input' ? 'inputs' : 'outputs'
      const nextEntry = {
        ...existing,
        [directionKey]: existing[directionKey].filter((value) => value !== item),
      }
      const next = { ...current }
      if (nextEntry.inputs.length === 0 && nextEntry.outputs.length === 0) {
        delete next[nodeId]
      } else {
        next[nodeId] = nextEntry
      }
      return next
    })
  }, [])

  const graph = useMemo(() => {
    return buildPlannerGraph({
      nodes: plannerState?.nodes ?? [],
      states: plannerState?.states ?? [],
      edges: plannerState?.edges ?? [],
      artifacts: plannerState?.artifacts ?? [],
      proposal: null,
      ownerId: plannerState?.canvas.ownerId,
      mode: 'design',
      runNodeStates: undefined,
      ioArtifactVisibility,
      displayNameByUserId: teamDirectory.displayNameByUserId,
      avatarUrlByUserId: teamDirectory.avatarUrlByUserId,
      onOpenDetails: handleOpenNodeDetails,
      onOpenSubCanvas,
      onOpenKanbanItem: handleOpenKanbanItem,
      onBindInput: handleBindNodeInput,
      onChangeStatus: handleChangeNodeStatus,
      onChangeGateMode: handleChangeNodeGateMode,
      canChangeStatus: variant !== 'template',
      onCreateSession: handleCreateNodeSession,
      onOpenSession: handleOpenNodeSession,
      onReplaceSession: handleReplaceNodeSession,
      onCancelSessionCreation: handleCancelNodeSessionCreation,
      onDeleteNode: handleDeleteNode,
      onHideIOArtifact: handleHideIOArtifact,
      creatingSessionNodeIds,
      showResponsibleInfo: plannerState?.canvas.visibility !== 'private',
    })
  }, [
    plannerState?.nodes,
    plannerState?.states,
    plannerState?.edges,
    plannerState?.artifacts,
    plannerState?.canvas.ownerId,
    plannerState?.canvas.visibility,
    ioArtifactVisibility,
    teamDirectory,
    handleOpenNodeDetails,
    onOpenSubCanvas,
    handleOpenKanbanItem,
    handleBindNodeInput,
    handleChangeNodeStatus,
    handleChangeNodeGateMode,
    handleCreateNodeSession,
    handleOpenNodeSession,
    handleReplaceNodeSession,
    handleCancelNodeSessionCreation,
    handleDeleteNode,
    handleHideIOArtifact,
    creatingSessionNodeIds,
    variant,
  ])

  const reviewGraph = useMemo(() => {
    if (!plannerState || !proposal) return { nodes: [], edges: [] }
    return buildPlannerGraph({
      nodes: plannerState.nodes,
      states: plannerState.states,
      edges: plannerState.edges,
      artifacts: plannerState.artifacts,
      proposal,
      ownerId: plannerState.canvas.ownerId,
      mode: 'design',
      runNodeStates: undefined,
      ioArtifactVisibility,
      displayNameByUserId: teamDirectory.displayNameByUserId,
      avatarUrlByUserId: teamDirectory.avatarUrlByUserId,
    })
  }, [
    plannerState?.nodes,
    plannerState?.states,
    plannerState?.edges,
    plannerState?.artifacts,
    plannerState?.canvas.ownerId,
    proposal,
    ioArtifactVisibility,
    teamDirectory,
  ])

  useEffect(() => {
    setFlowNodes((current) => mergeGraphNodesPreservingPositions(graph.nodes, current))
  }, [graph.nodes])

  const handleNodesChange = useCallback((changes: NodeChange<PlannerGraphNode>[]) => {
    setFlowNodes((current) => applyNodeChanges(changes, current) as PlannerGraphNode[])
  }, [])

  const handleNodeDragStop = useCallback((node: PlannerGraphNode) => {
    if (node.data.virtual) return
    const layout = {
      x: node.position.x,
      y: node.position.y,
      width: node.width ?? node.measured?.width ?? null,
      height: node.height ?? node.measured?.height ?? null,
    }
    setPlannerState((current) => current
      ? {
        ...current,
        nodes: current.nodes.map((item) => item.id === node.data.node.id ? { ...item, layout } : item),
      }
      : current)
    updatePlannerNodeLayout(canvasId, node.data.node.id, layout)
      .then(handleGraphStateChanged)
      .catch((err) => notifyError((err as Error).message || 'Failed to save node position'))
  }, [canvasId, handleGraphStateChanged, notifyError])

  useEffect(() => {
    window.localStorage.setItem(PANEL_COLLAPSED_KEY, plannerPanelCollapsed ? '1' : '0')
  }, [plannerPanelCollapsed])

  useEffect(() => {
    window.localStorage.setItem(PANEL_WIDTH_KEY, String(plannerPanelWidth))
  }, [plannerPanelWidth])

  useEffect(() => {
    if (ioArtifactVisibilityCanvasRef.current !== canvasId) return
    writeStoredIOArtifactVisibility(canvasId, ioArtifactVisibility)
  }, [canvasId, ioArtifactVisibility])

  useEffect(() => {
    ioArtifactVisibilityCanvasRef.current = canvasId
    setIOArtifactVisibility(readStoredIOArtifactVisibility(canvasId))
  }, [canvasId])

  const handleToggleIOArtifact = useCallback((
    nodeId: string,
    direction: keyof IOArtifactVisibility,
    item: string,
    visible: boolean,
  ) => {
    const normalized = item.trim()
    if (!normalized) return
    setIOArtifactVisibility((current) => {
      const existing = current[nodeId] ?? { inputs: [], outputs: [] }
      const nextList = visible
        ? Array.from(new Set([...existing[direction], normalized]))
        : existing[direction].filter((value) => value !== normalized)
      const nextEntry = { ...existing, [direction]: nextList }
      const next = { ...current }
      if (nextEntry.inputs.length === 0 && nextEntry.outputs.length === 0) {
        delete next[nodeId]
      } else {
        next[nodeId] = nextEntry
      }
      return next
    })
  }, [])

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
    if (plannerState && graph.nodes.length === 0) {
      fitViewCanvasRef.current = canvasId
      return
    }
    if (!plannerState || graph.nodes.length === 0 || fitViewCanvasRef.current === canvasId) return
    fitViewCanvasRef.current = canvasId
    const timer = window.setTimeout(() => {
      if (window.matchMedia('(max-width: 720px)').matches) {
        reactFlow.setViewport({ x: 18, y: 52, zoom: 0.9 }, { duration: 220 })
        return
      }
      reactFlow.fitView({ padding: 0.12, duration: 220 })
    }, 120)
    return () => window.clearTimeout(timer)
  }, [plannerState, graph.nodes.length, canvasId, reactFlow])

  const selectedNode = useMemo(() => {
    if (!selectedNodeId) return null
    return plannerState?.nodes.find((node) => node.id === selectedNodeId)
      ?? graph.nodes.find((node) => node.id === selectedNodeId)?.data.node
      ?? null
  }, [graph.nodes, plannerState, selectedNodeId])

  const hasActionableDrift = useMemo(() => {
    return (plannerState?.states ?? []).some((state) =>
      state.runState === 'blocked' || state.runState === 'draft',
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
    generatePlannerProposal(canvasId, goal, buildPlannerGenerationContext(plannerState, proposal))
      .then((next) => {
        setProposal(next)
        setPlannerState((current) => current && next
          ? { ...current, proposals: upsertProposal(current.proposals, next) }
          : current)
        if (next) setReviewRequestTick((tick) => tick + 1)
      })
      .catch((err) => setError((err as Error).message || 'Failed to generate meee2 AI proposal'))
      .finally(() => setBusy(false))
  }, [canvasId, plannerState, proposal])

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
              return generatePlannerProposal(canvasId, trimmed, buildPlannerGenerationContext(plannerState, proposal)).then((generated) => {
                setProposal(generated)
                setPlannerState((current) => current && generated
                  ? { ...current, proposals: upsertProposal(current.proposals, generated) }
                  : current)
                if (generated) setReviewRequestTick((tick) => tick + 1)
              })
            }
            setError('No blocked or draft state found.')
            return undefined
          }
          setProposal(next)
          setPlannerState((current) => current
            ? { ...current, proposals: upsertProposal(current.proposals, next) }
            : current)
          setReviewRequestTick((tick) => tick + 1)
          return undefined
        })
        .catch((err) => setError((err as Error).message || 'Failed to inspect meee2 AI drift'))
        .finally(() => setBusy(false))
      return
    }

    if (!trimmed) return
    handleGenerate(trimmed)
  }, [canvasId, handleGenerate, hasActionableDrift, plannerState, proposal])

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
            edges: [],
          }
        })
        window.setTimeout(() => {
          if (window.matchMedia('(max-width: 720px)').matches) {
            reactFlow.setViewport({ x: 18, y: 52, zoom: 0.9 }, { duration: 260 })
            return
          }
          reactFlow.fitView({ padding: 0.14, duration: 260 })
        }, 80)
      })
      .catch((err) => setError((err as Error).message || 'Failed to approve and apply meee2 AI proposal'))
      .finally(() => setBusy(false))
  }, [canvasId, canvasName, proposal, reactFlow])

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

  // GOVERNANCE-layer node actions (sub-canvas / refine / assign doer) return a
  // PlanProposal. Thread it into the same proposal state the generate / drift /
  // AI-dialog flows feed, so the user lands in the existing approve/apply gate.
  const handleNodeActionProposal = useCallback((next: PlanProposal) => {
    setProposal(next)
    setPlannerState((current) => current
      ? { ...current, proposals: upsertProposal(current.proposals, next) }
      : current)
    setNodeModalOpen(false)
    setReviewRequestTick((tick) => tick + 1)
  }, [])

  const handleSendNodeActionToAI = useCallback((message: string) => {
    setPlannerPanelCollapsed(false)
    setPlannerDraftMessage({ id: Date.now(), text: message })
    setNodeModalOpen(false)
  }, [])

  const plannerMainStyle = {
    '--planner-panel-width': `${plannerPanelWidth}px`,
  } as CSSProperties
  const mcpWarning = mcpStatusError || (mcpStatus && !mcpStatus.launches ? mcpStatus.error || 'Meee2 MCP is not available.' : null)

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
          {mcpWarning && (
            <div className="planner-mcp-banner" role="status">
              <AlertTriangle size={16} aria-hidden />
              <div className="planner-mcp-banner__copy">
                <strong>Meee2 MCP is not connected</strong>
                <span>
                  Native sessions can run, but node artifacts cannot be submitted back to this canvas.
                  Reconnect or restart the session after fixing MCP.
                </span>
                <em>{mcpWarning}</em>
              </div>
              <button type="button" onClick={refreshMCPStatus} aria-label="Check Meee2 MCP again">
                <RefreshCw size={14} aria-hidden />
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
              onNodeDragStop={(_, node) => handleNodeDragStop(node)}
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
              canvasId={canvasId}
              proposal={proposal}
              variant={variant}
              previewGraph={reviewGraph}
              busy={busy}
              error={error}
              access={plannerState?.access ?? null}
              nodeCount={plannerState?.nodes.length ?? 0}
              hasActionableDrift={hasActionableDrift}
              onSubmit={handlePlannerSubmit}
              onApproveAndApply={handleApproveAndApply}
              onReject={handleReject}
              draftMessage={plannerDraftMessage}
              clearRevision={clearRevision}
              reviewRequestTick={reviewRequestTick}
            />
          </div>
        )}
      </div>
      {nodeModalOpen && selectedNode && (
        <NodeInspectorModal
          node={selectedNode}
          canvasId={canvasId}
          variant={variant}
          state={plannerState?.states.find((item) => item.nodeId === selectedNode.id) ?? null}
          doerLabel={
            selectedNode.doerId
              ? teamDirectory.displayNameByUserId[selectedNode.doerId] ?? selectedNode.doerId
              : undefined
          }
          access={plannerState?.access ?? null}
          teamMembers={teamMembers}
          onProposalCreated={handleNodeActionProposal}
          onGraphStateChanged={handleGraphStateChanged}
          onSendToAI={handleSendNodeActionToAI}
          showOwnerInfo={plannerState?.canvas.visibility !== 'private'}
          visibleIOArtifacts={ioArtifactVisibility[selectedNode.id] ?? { inputs: [], outputs: [] }}
          onToggleIOArtifact={handleToggleIOArtifact}
          onClose={() => setNodeModalOpen(false)}
          onOpenSubCanvas={onOpenSubCanvas}
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

function ioArtifactVisibilityKey(canvasId: string): string {
  return `${IO_ARTIFACT_VISIBILITY_KEY_PREFIX}.${canvasId}`
}

function readStoredIOArtifactVisibility(canvasId: string): Record<string, IOArtifactVisibility> {
  if (typeof window === 'undefined') return {}
  try {
    return normalizeIOArtifactVisibility(JSON.parse(window.localStorage.getItem(ioArtifactVisibilityKey(canvasId)) ?? '{}'))
  } catch {
    return {}
  }
}

function writeStoredIOArtifactVisibility(canvasId: string, value: Record<string, IOArtifactVisibility>) {
  if (typeof window === 'undefined') return
  window.localStorage.setItem(ioArtifactVisibilityKey(canvasId), JSON.stringify(value))
}

function normalizeIOArtifactVisibility(raw: unknown): Record<string, IOArtifactVisibility> {
  if (!raw || typeof raw !== 'object') return {}
  const result: Record<string, IOArtifactVisibility> = {}
  for (const [nodeId, entry] of Object.entries(raw as Record<string, unknown>)) {
    if (!entry || typeof entry !== 'object') continue
    const input = entry as Partial<Record<keyof IOArtifactVisibility, unknown>>
    const inputs = normalizeStringList(input.inputs)
    const outputs = normalizeStringList(input.outputs)
    if (inputs.length > 0 || outputs.length > 0) {
      result[nodeId] = { inputs, outputs }
    }
  }
  return result
}

function normalizeStringList(value: unknown): string[] {
  return Array.isArray(value)
    ? Array.from(new Set(value.map((item) => typeof item === 'string' ? item.trim() : '').filter(Boolean)))
    : []
}

function gateModeForPlanningNode(node: PlanningNode): 'human' | 'auto' {
  if (node.executionMode === 'human') return 'human'
  if ((node.gate?.approvers ?? []).length > 0) return 'human'
  return 'auto'
}

function buildPlannerGenerationContext(
  state: PlannerCanvasState | null,
  activeProposal: PlanProposal | null,
): string | undefined {
  if (!state) return undefined
  const openProposals = state.proposals.filter((item) =>
    item.status === 'pending' || item.status === 'approved',
  )
  const activeOpenProposal = activeProposal && (activeProposal.status === 'pending' || activeProposal.status === 'approved')
    ? activeProposal
    : null
  const context = {
    instruction: [
      'Evolve the current canvas; do not replace it.',
      'Use committedNodes as existing canvas content.',
      'Use activeProposal as the current UI preview if present.',
      'If activeProposal has addNode changes that should remain, include those addNode definitions again in the new proposal, with refinements folded in.',
      'For committed nodes, prefer updateNode over adding duplicates.',
    ],
    canvas: {
      id: state.canvas.id,
      title: state.canvas.title,
    },
    committedNodes: state.nodes.map(compactPlanningNode),
    edges: (state.edges ?? []).map((edge) => ({
      sourceNodeId: edge.sourceNodeId,
      targetNodeId: edge.targetNodeId,
      kind: edge.kind,
    })),
    activeProposal: activeOpenProposal ? compactProposal(activeOpenProposal) : null,
    openProposals: openProposals
      .filter((item) => item.id !== activeOpenProposal?.id)
      .slice(-3)
      .map(compactProposal),
  }
  return JSON.stringify(context)
}

function compactProposal(proposal: PlanProposal) {
  return {
    id: proposal.id,
    summary: proposal.summary,
    status: proposal.status,
    changes: proposal.changes.map((change) => ({
      kind: change.kind,
      nodeId: change.nodeId,
      title: change.title,
      status: change.status,
      schema: change.schema,
      dependsOnNodeIds: change.dependsOnNodeIds,
      executionMode: change.executionMode,
      clearGate: change.clearGate,
      gate: change.gate,
      node: change.node ? compactPlanningNode(change.node) : undefined,
    })),
  }
}

function compactPlanningNode(node: PlanningNode) {
  return {
    id: node.id,
    title: node.title,
    nodeKind: node.nodeKind ?? 'step',
    status: node.status,
    executionMode: node.executionMode,
    schema: node.schema,
    dependsOnNodeIds: node.dependsOnNodeIds ?? [],
    doerId: node.doerId,
  }
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

function validateStatusChange(node: PlanningNode, status: PlanningNodeStatus): string | null {
  if ((node.nodeKind ?? 'step') !== 'step') return null
  if (status !== 'ready' && status !== 'working' && status !== 'done') return null

  const missingInputs = missingRequiredInputs(node)
  if (missingInputs.length > 0) {
    return `Cannot mark "${node.title}" as ${status}: missing required input ${missingInputs.join(', ')}.`
  }

  const needsSession = status === 'working' || status === 'done'
  const humanStep = node.executionMode === 'human' || node.executorType === 'human'
  const hasSession = Boolean(node.sessionId?.trim())
  if (needsSession && !humanStep && !hasSession) {
    return `Cannot mark "${node.title}" as ${status}: create or bind a run session first.`
  }

  return null
}

function missingRequiredInputs(node: PlanningNode): string[] {
  const inputs = node.schema?.inputs ?? []
  if (inputs.length === 0) return []
  const bound = new Set(
    (node.contextSources ?? [])
      .filter((source) => source.reference.trim().length > 0)
      .map((source) => normalizeInputName(source.title)),
  )
  return inputs.filter((input) => !bound.has(normalizeInputName(input)))
}

function normalizeInputName(value: string): string {
  return value.trim().toLowerCase().replace(/\s+/g, ' ')
}

function upsertProposal(proposals: PlanProposal[], proposal: PlanProposal): PlanProposal[] {
  const index = proposals.findIndex((item) => item.id === proposal.id)
  if (index < 0) return [...proposals, proposal]
  return proposals.map((item, itemIndex) => itemIndex === index ? proposal : item)
}

function mergeGraphNodesPreservingPositions(
  nextNodes: PlannerGraphNode[],
  currentNodes: PlannerGraphNode[],
): PlannerGraphNode[] {
  if (currentNodes.length === 0) return nextNodes
  const currentById = new Map(currentNodes.map((node) => [node.id, node]))
  return nextNodes.map((nextNode) => {
    const current = currentById.get(nextNode.id)
    if (!current) return nextNode
    return {
      ...nextNode,
      position: current.position,
      selected: current.selected,
      dragging: current.dragging,
    }
  })
}

async function pollForBoundNodeSession(
  canvasId: string,
  nodeId: string,
  existingSessionIds: Set<string>,
  onState: (state: PlannerGraphState) => void,
  onDone: () => void,
) {
  let sawNewSession = false
  try {
    for (let attempt = 0; attempt < 36; attempt += 1) {
      await delay(attempt < 4 ? 900 : 1800)
      try {
        const boardState = await fetchState()
        const newSession = boardState.sessions.find((session) => !existingSessionIds.has(session.id))
        if (newSession) {
          sawNewSession = true
          try {
            const bound = await bindPlannerSessionToNode(canvasId, nodeId, newSession.id)
            onState(bound)
            if (bound.nodes.find((item) => item.id === nodeId)?.sessionId) return
          } catch {
            // The backend spawn-intent matcher may still bind it on the next state refresh.
          }
        }
        const state = await fetchPlannerGraphState(canvasId)
        onState(state)
        const node = state.nodes.find((item) => item.id === nodeId)
        if (node?.sessionId) return
        if (node?.workflowRunState !== 'dispatched' && node?.workflowRunState !== 'running') return
      } catch {
        // The terminal session may not have reported yet; keep polling.
      }
    }
    if (sawNewSession) return
    const state = await fetchPlannerGraphState(canvasId)
    onState(state)
  } finally {
    onDone()
  }
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => window.setTimeout(resolve, ms))
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
