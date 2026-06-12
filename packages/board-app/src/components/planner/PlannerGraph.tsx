import {
  Background,
  Controls,
  MarkerType,
  NodeResizer,
  ReactFlow,
  ReactFlowProvider,
  applyNodeChanges,
  type Edge,
  type Node,
  type NodeChange,
  type NodeProps,
  useReactFlow,
} from '@xyflow/react'
import { AlertTriangle, Database, EyeOff, FileText, Layers, Maximize2, Minimize2, Pin, PlayCircle, RefreshCw, UserCircle } from 'lucide-react'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { CSSProperties, PointerEvent as ReactPointerEvent, ReactNode } from 'react'
import {
  applyPlannerProposal,
  approvePlannerProposal,
  abandonPlannerNodeSession,
  assignPlannerNode,
  bindPlannerSessionToNode,
  bindPlannerNodeInput,
  createPlannerDeliveryPipeline,
  deletePlannerNode,
  detachPlannerNodeSession,
  dispatchPlannerNodeSession,
  ensurePlannerNodeInternalSession,
  fetchCanvasTemplates,
  fetchMeee2MCPStatus,
  fetchPlannerGraphState,
  fetchState,
  fetchTeamMembers,
  generatePlannerProposal,
  injectToSession,
  inspectPlannerDrift,
  openKanbanItemSubCanvas,
  patchCanvasRenderValues,
  proposePlannerGraphChange,
  rejectPlannerProposal,
  rerunPlannerNode,
  resumeClosedPlannerSessions,
  runCanvasSceneAction,
  sendPlannerActivity,
  updatePlannerNodeGate,
  updatePlannerNodeStatus,
  ApiRequestError,
} from '../../api'
import { AssignNodeDialog } from './AssignNodeDialog'
import type {
  NodeAssignment,
  PlanProposal,
  PlannerCanvasState,
  PlannerArtifact,
  PlannerDispatchRunner,
  PlannerGraphState,
  Meee2MCPStatus,
  PlanningNode,
  PlanningNodeStatus,
  Session,
  CanvasScope,
  CanvasSceneAction,
  CanvasSceneSpec,
  CanvasObject,
  CanvasRelation,
  CanvasRenderObjectValues,
} from '../../types'
import type { BoardState } from '../../types'
import type { CanvasTemplate, TeamMember, UserProfile } from '../../api'
import type { CanvasMonitor } from '@meee1/recap-core'
import {
  LOCK_VIEWPORT_PREFERENCES_CHANGED,
  loadLockViewportOnSwitch,
  loadPlannerViewport,
  loadSpawnProvider,
  savePlannerViewport,
} from '../../preferences'
import {
  buildTeamDirectory,
  teamAvatarUrlByUserId,
  teamDisplayNameByUserId,
} from '../../teamDirectory'
import { classifyPlannerIntent } from '../../lib/plannerIntent'
import {
  buildConfirmedPlanGraphChanges,
  isScenePlanDraft,
  parseConfirmedPlanDraft,
} from '../../lib/plannerPlanDraft'
import {
  indexNodes,
  loadNotificationToggles,
  runPlannerApprovalNotifications,
} from '../../notifications'
import { useI18n } from '../../lib/i18n'
import {
  cssEscape,
  requestBoardGuide,
  type BoardGuideTarget,
  type PlannerNodeSelectionDetail,
} from '../../lib/guide'
import { emitPlannerEvent, reportPlannerRevert } from '../../lib/plannerTelemetry'
import { AttachDataSourcePopover } from './AttachDataSourcePopover'
import { DataSourceRail } from './DataSourceRail'
import { NodeInspectorModal, truncateMessageText } from './NodeInspectorModal'
import { PlannerNodeCard } from './PlannerNodeCard'
import { CanvasSceneLayer, resolveCanvasSceneState, type CanvasSceneActionPayload } from './CanvasSceneLayer'
import { MonitorGrid } from './monitor/MonitorGrid'
import { MonitorHtmlFrame } from './monitor/MonitorHtmlFrame'
import { PlannerOverviewMap } from './PlannerOverviewMap'
import { PlannerAgentChatPanel } from './PlannerAgentChatPanel'
import { PlannerProposalPanel } from './PlannerProposalPanel'
import { TransformInsertEdge } from './TransformInsertEdge'
import { buildPlannerGraph, sessionMatchesBoundId, type IOArtifactDirection, type IOArtifactVisibility, type NodeLiveProgress, type PlannerGraphEdge, type PlannerGraphNode } from './plannerGraphAdapter'
import type { NodeContractExternalInput } from '../../types'
import './planner.css'

interface Props {
  canvasId: string
  canvasName: string
  workspacePath?: string
  variant?: 'board' | 'template'
  userProfile?: UserProfile | null
  boardState?: BoardState | null
  clearRevision?: number
  /**
   * U5.1 — auto-refresh on notification.
   * Parent bumps this counter every time a WS `state.changed` event arrives so
   * the active canvas can re-fetch its planner graph and reflect remote
   * changes within ~1s, without forcing the user to manually switch canvas.
   */
  refreshTick?: number
  onOpenSubCanvas?: (canvasId: string) => void
  onNotify?: (kind: 'success' | 'error', text: string) => void
  onApplyTemplate?: (templateId: string, name: string, scope: CanvasScope, adaptationPrompt?: string) => Promise<string>
  onPlannerStateChange?: (state: PlannerGraphState | null) => void
  canvasMonitor?: CanvasMonitor | null
  flowContent?: ReactNode
  forceDialogOpenTick?: number
  dialogCollapsed?: boolean
  onDialogCollapsedChange?: (collapsed: boolean) => void
}

type CanvasObjectAction = 'open' | 'hide' | 'toggleCollapsed' | 'togglePinned'

interface CanvasObjectNodeData extends Record<string, unknown> {
  object: CanvasObject
  subtitle: string
  detail?: string | null
  badge: string
  collapsed: boolean
  pinned: boolean
  canEdit: boolean
  onAction: (object: CanvasObject, action: CanvasObjectAction) => void
}

type CanvasObjectFlowNode = Node<CanvasObjectNodeData, 'canvasObject'>
type CanvasFlowNode = PlannerGraphNode | CanvasObjectFlowNode
type CanvasFlowEdge = PlannerGraphEdge | Edge<NonNullable<PlannerGraphEdge['data']>>

const nodeTypes = {
  plannerNode: PlannerNodeCard,
  canvasObject: CanvasObjectCard,
}

const edgeTypes = {
  transformInsert: TransformInsertEdge,
}

function CanvasObjectCard({ data, selected }: NodeProps<CanvasObjectFlowNode>) {
  const object = data.object
  const kind = object.entityRef?.kind ?? object.renderOnly?.kind ?? 'object'
  const Icon = iconForCanvasObject(object)
  return (
    <div
      className={[
        'canvas-object-card',
        `canvas-object-card--${cssClassToken(kind)}`,
        data.collapsed ? 'is-collapsed' : '',
        data.pinned ? 'is-pinned' : '',
        selected ? 'is-selected' : '',
      ].filter(Boolean).join(' ')}
      data-renderer={object.renderer}
    >
      <NodeResizer
        minWidth={160}
        minHeight={data.collapsed ? 64 : 96}
        handleClassName="planner-node__resize-handle"
        lineClassName="planner-node__resize-line"
      />
      <div className="canvas-object-card__header">
        <span className="canvas-object-card__icon" aria-hidden>
          <Icon size={15} />
        </span>
        <div className="canvas-object-card__title">
          <strong>{object.label}</strong>
          <span>{data.subtitle}</span>
        </div>
        <div className="canvas-object-card__actions nodrag">
          <button
            type="button"
            title={data.collapsed ? 'Expand' : 'Collapse'}
            aria-label={data.collapsed ? 'Expand object' : 'Collapse object'}
            onClick={(event) => {
              event.stopPropagation()
              data.onAction(object, 'toggleCollapsed')
            }}
          >
            {data.collapsed ? <Maximize2 size={13} /> : <Minimize2 size={13} />}
          </button>
          <button
            type="button"
            title={data.pinned ? 'Unpin' : 'Pin'}
            aria-label={data.pinned ? 'Unpin object' : 'Pin object'}
            onClick={(event) => {
              event.stopPropagation()
              data.onAction(object, 'togglePinned')
            }}
          >
            <Pin size={13} />
          </button>
          {data.canEdit && (
            <button
              type="button"
              title="Hide"
              aria-label="Hide object"
              onClick={(event) => {
                event.stopPropagation()
                data.onAction(object, 'hide')
              }}
            >
              <EyeOff size={13} />
            </button>
          )}
        </div>
      </div>
      {!data.collapsed && (
        <div className="canvas-object-card__body">
          <span className="canvas-object-card__badge">{data.badge}</span>
          {data.detail && <p>{data.detail}</p>}
          <button
            type="button"
            className="canvas-object-card__open nodrag"
            onClick={(event) => {
              event.stopPropagation()
              data.onAction(object, 'open')
            }}
          >
            Open
          </button>
        </div>
      )}
    </div>
  )
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
  refreshTick = 0,
  onOpenSubCanvas,
  onNotify,
  onApplyTemplate,
  onPlannerStateChange,
  canvasMonitor = null,
  flowContent = null,
  forceDialogOpenTick = 0,
  dialogCollapsed,
  onDialogCollapsedChange,
}: Props) {
  const { t } = useI18n()
  const reactFlow = useReactFlow()
  const [plannerState, setPlannerState] = useState<PlannerGraphState | null>(null)
  const [officialCanvasTemplates, setOfficialCanvasTemplates] = useState<CanvasTemplate[]>([])
  // Chunk D: planner-side approval notifications. Diff node workflowRunState
  // for gate-wait transitions across PlannerGraph re-fetches.
  const prevPlannerNodesRef = useRef<Map<string, import('../../types').PlanningNode>>(new Map())
  const processedPokerActionKeysRef = useRef<Set<string>>(new Set())
  const processedPokerDispatchKeysRef = useRef<Set<string>>(new Set())
  useEffect(() => {
    const nodes = plannerState?.nodes
    if (!nodes) return
    const toggles = loadNotificationToggles()
    queueMicrotask(() => {
      runPlannerApprovalNotifications(prevPlannerNodesRef.current, nodes, toggles)
      prevPlannerNodesRef.current = indexNodes(nodes)
    })
  }, [plannerState?.nodes])
  const [proposal, setProposal] = useState<PlanProposal | null>(null)
  const [selectedNodeId, setSelectedNodeId] = useState<string | null>(null)
  const [guidedNodeId, setGuidedNodeId] = useState<string | null>(null)
  const guidedNodeTimerRef = useRef<number | null>(null)
  const guideDispatchTimerRef = useRef<number | null>(null)
  const [nodeModalOpen, setNodeModalOpen] = useState(false)
  // 2026-06-02 · session overlay 与 inspector 绑定:inspector 关闭(true→false)时广播
  // 事件,App 据此一并关掉 session terminal overlay(仅 UI 关闭,不杀会话进程)。
  const prevNodeModalOpenRef = useRef(nodeModalOpen)
  useEffect(() => {
    if (prevNodeModalOpenRef.current && !nodeModalOpen) {
      window.dispatchEvent(new CustomEvent('meee2:node-inspector-closed'))
    }
    prevNodeModalOpenRef.current = nodeModalOpen
  }, [nodeModalOpen])
  /**
   * 2026-05-29 (PR #91 codex P2 fix): when a non-latest artifact chip on the
   * card is clicked, we want the inspector to open with that artifact
   * preselected (not always latest). This state piggybacks on nodeModalOpen
   * and is read by InspectorArtifactBody as its initial selectedArtifactId.
   */
  const [initialInspectorArtifactId, setInitialInspectorArtifactId] = useState<string | null>(null)
  const [internalPlannerPanelCollapsed, setInternalPlannerPanelCollapsed] = useState(() => readStoredPanelCollapsed())
  const plannerPanelCollapsed = dialogCollapsed ?? internalPlannerPanelCollapsed
  const setPlannerPanelCollapsed = useCallback((next: boolean | ((current: boolean) => boolean)) => {
    const resolved = typeof next === 'function' ? next(plannerPanelCollapsed) : next
    if (onDialogCollapsedChange) {
      onDialogCollapsedChange(resolved)
    } else {
      setInternalPlannerPanelCollapsed(resolved)
    }
  }, [onDialogCollapsedChange, plannerPanelCollapsed])
  const [plannerPanelWidth, setPlannerPanelWidth] = useState(() => readStoredPanelWidth())
  const [ioArtifactVisibility, setIOArtifactVisibility] = useState<Record<string, IOArtifactVisibility>>(
    () => readStoredIOArtifactVisibility(canvasId),
  )
  const ioArtifactVisibilityCanvasRef = useRef(canvasId)
  const handledClearRevisionRef = useRef(0)
  const fitViewCanvasRef = useRef<string | null>(null)
  // UI-5.2 — viewport opt-out. Track the user preference reactively so flipping
  // it in PreferencesDialog affects the *next* canvas switch without reload.
  const [lockViewportOnSwitch, setLockViewportOnSwitch] = useState(() => loadLockViewportOnSwitch())
  useEffect(() => {
    const onChange = () => setLockViewportOnSwitch(loadLockViewportOnSwitch())
    window.addEventListener(LOCK_VIEWPORT_PREFERENCES_CHANGED, onChange)
    return () => window.removeEventListener(LOCK_VIEWPORT_PREFERENCES_CHANGED, onChange)
  }, [])
  // Debounced viewport-save handle; reset on canvas change.
  const viewportSaveTimerRef = useRef<number | null>(null)
  const [flowNodes, setFlowNodes] = useState<CanvasFlowNode[]>([])
  const [teamMembers, setTeamMembers] = useState<TeamMember[]>([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [plannerDraftMessage, setPlannerDraftMessage] = useState<{ id: number; text: string; visibleText?: string; contextLabel?: string } | null>(null)
  const [creatingSessionNodeIds, setCreatingSessionNodeIds] = useState<Set<string>>(() => new Set())
  const [sessionHealthBoardState, setSessionHealthBoardState] = useState<BoardState | null>(boardState)
  const [resumingClosedSessions, setResumingClosedSessions] = useState(false)
  const [startingReadySessions, setStartingReadySessions] = useState(false)
  const [mcpStatus, setMCPStatus] = useState<Meee2MCPStatus | null>(null)
  const [mcpStatusError, setMCPStatusError] = useState<string | null>(null)
  // UI-4: which node is showing the "Attach data source" popover (nodeId | null).
  const [attachDataSourceNodeId, setAttachDataSourceNodeId] = useState<string | null>(null)
  // Bumped whenever a new proposal is created from chat, drift inspection, or
  // node actions. PlannerProposalPanel watches this to auto-open review.
  const [reviewRequestTick, setReviewRequestTick] = useState(0)
  // ENG-5: when the heuristic decides the user's message is a question, we
  // push an answer-only reply to the panel instead of generating a proposal.
  const [answerOnlyReply, setAnswerOnlyReply] = useState<{ id: number; markdown: string } | null>(null)
  // UI-2: assign-dialog state. `assignDialogNodeId` keys which node's chip
  // was clicked; the dialog reads its node + frozen contract from plannerState.
  const [assignDialogNodeId, setAssignDialogNodeId] = useState<string | null>(null)
  const [assignBusy, setAssignBusy] = useState(false)
  const [assignError, setAssignError] = useState<string | null>(null)

  useEffect(() => {
    if (!plannerState) {
      onPlannerStateChange?.(null)
      return
    }
    onPlannerStateChange?.({
      ...plannerState,
      artifacts: plannerState.artifacts ?? [],
      edges: plannerState.edges ?? [],
    })
  }, [onPlannerStateChange, plannerState])

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

  // U5.1 — auto-refresh on notification.
  // When the parent signals (via `refreshTick`) that a WS `state.changed` event
  // arrived for this canvas, silently re-fetch the planner graph and apply the
  // diff. We deliberately don't toggle `busy` here so the canvas doesn't flicker
  // on every backend tick; the planner state setter is idempotent for unchanged
  // graphs.
  const lastHandledRefreshTickRef = useRef(refreshTick)
  useEffect(() => {
    if (refreshTick === lastHandledRefreshTickRef.current) return
    lastHandledRefreshTickRef.current = refreshTick
    if (!canvasId) return
    let cancelled = false
    fetchPlannerGraphState(canvasId)
      .then((state) => {
        if (cancelled) return
        setPlannerState(state)
        setProposal(
          state.proposals.find(
            (item) => item.status === 'pending' || item.status === 'approved',
          ) ?? null,
        )
      })
      .catch((err) => {
        if (cancelled) return
        // Soft-fail: a failed background refresh shouldn't blow away the UI;
        // log only so the next tick / manual interaction retries cleanly.
        console.warn(
          '[PlannerGraph] auto-refresh on notification failed:',
          (err as Error).message,
        )
      })
    return () => {
      cancelled = true
    }
  }, [canvasId, refreshTick])

  const refreshMCPStatus = useCallback(() => {
    setMCPStatusError(null)
    fetchMeee2MCPStatus()
      .then((status) => setMCPStatus(status))
      .catch((err) => {
        setMCPStatus(null)
        setMCPStatusError((err as Error).message || 'Failed to check Meee2 MCP status')
      })
  }, [userProfile?.teams, userProfile?.userId])

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
  }, [userProfile?.teams, userProfile?.userId])

  const handleOpenNodeDetails = useCallback((nodeId: string) => {
    setSelectedNodeId(nodeId)
    setInitialInspectorArtifactId(null)
    setNodeModalOpen(true)
  }, [])

  /** PR #91 codex P2 — open inspector with a specific artifact preselected. */
  const handleOpenNodeArtifact = useCallback((nodeId: string, artifactId: string) => {
    setSelectedNodeId(nodeId)
    setInitialInspectorArtifactId(artifactId)
    setNodeModalOpen(true)
  }, [])

  const clearGuidedNode = useCallback(() => {
    if (guidedNodeTimerRef.current !== null) {
      window.clearTimeout(guidedNodeTimerRef.current)
      guidedNodeTimerRef.current = null
    }
    if (guideDispatchTimerRef.current !== null) {
      window.clearTimeout(guideDispatchTimerRef.current)
      guideDispatchTimerRef.current = null
    }
    setGuidedNodeId(null)
  }, [])

  const focusPlannerNode = useCallback((detail: PlannerNodeSelectionDetail): boolean => {
    const nodeId = detail.nodeId?.trim()
    if (!nodeId) return false
    if (detail.canvasId && detail.canvasId !== canvasId) return false
    if (plannerState?.canvas.id !== canvasId) return false
    const nodeExists = flowNodes.some((node) => node.id === nodeId)
      || plannerState.nodes.some((node) => node.id === nodeId)
    if (!nodeExists) return false

    if (detail.openInspector !== false) {
      setSelectedNodeId(nodeId)
      setInitialInspectorArtifactId(detail.artifactId?.trim() || null)
      setNodeModalOpen(true)
    }

    if (detail.guide) {
      if (guidedNodeTimerRef.current !== null) {
        window.clearTimeout(guidedNodeTimerRef.current)
      }
      if (guideDispatchTimerRef.current !== null) {
        window.clearTimeout(guideDispatchTimerRef.current)
      }
      setGuidedNodeId(nodeId)
      reactFlow.fitView({
        nodes: [{ id: nodeId }],
        duration: 420,
        padding: 0.34,
        minZoom: 0.45,
        maxZoom: 1.18,
      })
      guideDispatchTimerRef.current = window.setTimeout(() => {
        requestBoardGuide({
          kind: 'selector',
          selector: `.react-flow__node[data-id="${cssEscape(nodeId)}"] .planner-node`,
          title: detail.title,
          body: detail.body,
          durationMs: detail.durationMs,
          source: detail.source,
        })
        guideDispatchTimerRef.current = null
      }, 460)
      guidedNodeTimerRef.current = window.setTimeout(() => {
        setGuidedNodeId((current) => (current === nodeId ? null : current))
        guidedNodeTimerRef.current = null
      }, detail.durationMs ?? 5200)
    }
    return true
  }, [canvasId, flowNodes, plannerState, reactFlow])

  useEffect(() => clearGuidedNode, [clearGuidedNode])

  // External hook for the command palette / native bridge. App.tsx may switch
  // canvases first, so the latest request is also kept as a one-shot pending
  // selection until this graph has the target node mounted.
  useEffect(() => {
    const onSelectNode = (event: Event) => {
      const detail = (event as CustomEvent<PlannerNodeSelectionDetail>).detail
      if (!detail?.nodeId) return
      window.__meee2PendingPlannerNodeSelection = detail
      if (focusPlannerNode(detail)) window.__meee2PendingPlannerNodeSelection = null
    }
    window.addEventListener('meee2:select-node', onSelectNode)
    return () => window.removeEventListener('meee2:select-node', onSelectNode)
  }, [focusPlannerNode])

  useEffect(() => {
    const onGuideTarget = (event: Event) => {
      const target = (event as CustomEvent<BoardGuideTarget>).detail
      if (!target || target.kind !== 'planner-node') return
      const detail: PlannerNodeSelectionDetail = {
        canvasId: target.canvasId,
        nodeId: target.nodeId,
        artifactId: undefined,
        guide: true,
        source: target.source,
        title: target.title,
        body: target.body,
        durationMs: target.durationMs,
        openInspector: target.openInspector ?? false,
      }
      window.__meee2PendingPlannerNodeSelection = detail
      if (focusPlannerNode(detail)) window.__meee2PendingPlannerNodeSelection = null
    }
    window.addEventListener('meee2:guide-target', onGuideTarget)
    return () => window.removeEventListener('meee2:guide-target', onGuideTarget)
  }, [focusPlannerNode])

  useEffect(() => {
    const pending = window.__meee2PendingPlannerNodeSelection
    if (!pending?.nodeId) return
    if (focusPlannerNode(pending)) window.__meee2PendingPlannerNodeSelection = null
  }, [focusPlannerNode])

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
  const monitorItemsByNodeId = useMemo(() => {
    return Object.fromEntries((canvasMonitor?.items ?? []).map((item) => [item.nodeId, item]))
  }, [canvasMonitor?.items])

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

  // UI-1 · Re-run the node by asking the desktop to append a fresh artifact
  // version (force_new_version: true). The state refresh shows the new entry
  // at the top of the version dropdown within one broadcast tick.
  const handleRerunNode = useCallback((nodeId: string, reference?: string) => {
    setBusy(true)
    setError(null)
    rerunPlannerNode(canvasId, nodeId, reference ? { reference } : undefined)
      .then((result) => handleGraphStateChanged(result.graph))
      .catch((err) => notifyError((err as Error).message || 'Failed to re-run node'))
      .finally(() => setBusy(false))
  }, [canvasId, handleGraphStateChanged, notifyError])

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

  const openInternalSessionForNode = useCallback((
    nodeId: string,
    runner?: PlannerDispatchRunner,
    openOnly?: boolean,
  ) => {
    const cwd = workspacePath.trim()
    return ensurePlannerNodeInternalSession(canvasId, nodeId, {
      runner,
      cwd: cwd || undefined,
      openOnly,
    })
      .then((result) => {
        handleGraphStateChanged(result.graph)
        window.dispatchEvent(new CustomEvent('meee2:open-session', {
          detail: {
            sessionId: result.sessionId,
            surfaceId: result.surfaceId,
            canvasId,
          },
        }))
        void fetchState().then(setSessionHealthBoardState).catch(() => undefined)
        return true
      })
      .catch((err) => {
        // BUG 1.2 — the bound session ended; do not silently spawn a fresh one.
        // Surface it and refresh state so the demoted (awaiting) node shows up.
        if ((err as ApiRequestError)?.code === 'session_ended') {
          onNotify?.('error', 'This session has ended. Re-dispatch the node to start a new one.')
          void fetchState().then(setSessionHealthBoardState).catch(() => undefined)
          return false
        }
        notifyError((err as Error).message || 'Failed to open internal session')
        return false
      })
  }, [canvasId, handleGraphStateChanged, notifyError, onNotify, workspacePath])

  const handleCreateNodeSession = useCallback((nodeId: string, runner: PlannerDispatchRunner, initialPrompt?: string) => {
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
        return dispatchPlannerNodeSession(canvasId, nodeId, runner, cwd, initialPrompt)
          .then((state) => {
            handleGraphStateChanged(state)
            setCreatingSessionNodeIds((current) => new Set(current).add(nodeId))
            void pollForBoundNodeSession(canvasId, nodeId, existingSessionIds, handleGraphStateChanged, () => {
              setCreatingSessionNodeIds((current) => {
                const next = new Set(current)
                next.delete(nodeId)
                return next
              })
            }, (sessionId) => {
              void sessionId
              // openOnly: dispatch already created the surface (backend
              // createInternalSessionSurface createIfMissing:true). Opening
              // WITHOUT openOnly makes `ensure` spawn a SECOND surface —
              // the「两个 internal session」double-dispatch bug. Just open
              // the one the node is already bound to.
              void openInternalSessionForNode(nodeId, runner, true)
            })
          })
      })
      .catch((err) => notifyError((err as Error).message || 'Failed to create node session'))
      .finally(() => setBusy(false))
  }, [canvasId, handleGraphStateChanged, notifyError, openInternalSessionForNode, warnMCPWritebackIfNeeded, workspacePath])

  const handleSceneAction = useCallback((nodeId: string, actionId: string, payload?: CanvasSceneActionPayload) => {
    const scene = plannerState?.canvas.sceneSpec
    if (scene?.kind === 'poker-table'
        && ['start-game', 'step', 'resume-auto', 'pause-auto'].includes(actionId)) {
      setBusy(true)
      setError(null)
      runCanvasSceneAction(canvasId, { actionId, ...payload })
        .then((result) => {
          handleGraphStateChanged(result.graph)
          if (actionId !== 'pause-auto') {
            dispatchNextPokerAutoNode(result.graph, handleCreateNodeSession, { force: actionId === 'step' })
          }
        })
        .catch((err) => notifyError((err as Error).message || 'Failed to run scene action'))
        .finally(() => setBusy(false))
      return
    }
    const node = plannerState?.nodes.find((item) => item.id === nodeId)
    if (!node) {
      notifyError('Scene action target node is missing.')
      return
    }
    const action = scene?.actions?.find((item) => item.id === actionId)
    const pokerPrompt = scene?.kind === 'poker-table' && action
      ? buildPokerSceneActionPrompt(scene, plannerState?.artifacts ?? [], action, node)
      : ''
    const initialPrompt = pokerPrompt
      || action?.prompt?.trim()
      || (action ? `${action.label} (${action.id})` : `Run scene action ${actionId}`)
    handleCreateNodeSession(nodeId, dispatchRunnerForExecutor(node.executorType), initialPrompt)
  }, [canvasId, handleCreateNodeSession, handleGraphStateChanged, notifyError, plannerState?.artifacts, plannerState?.canvas.sceneSpec, plannerState?.nodes])

  useEffect(() => {
    if (!plannerState) return
    const request = pokerAutoStepRequest(plannerState)
    if (request && !processedPokerActionKeysRef.current.has(request.key)) {
      processedPokerActionKeysRef.current.add(request.key)
      runCanvasSceneAction(canvasId, { actionId: 'step' })
        .then((result) => {
          handleGraphStateChanged(result.graph)
          dispatchNextPokerAutoNode(result.graph, handleCreateNodeSession)
        })
        .catch((err) => notifyError((err as Error).message || 'Failed to advance Poker scene'))
      return
    }
    const dispatchRequest = pokerAutoDispatchRequest(plannerState)
    if (!dispatchRequest || processedPokerDispatchKeysRef.current.has(dispatchRequest.key)) return
    processedPokerDispatchKeysRef.current.add(dispatchRequest.key)
    dispatchNextPokerAutoNode(plannerState, handleCreateNodeSession)
  }, [canvasId, handleCreateNodeSession, handleGraphStateChanged, notifyError, plannerState])

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
            }, (sessionId) => {
              void sessionId
              // openOnly: dispatch already created the surface (backend
              // createInternalSessionSurface createIfMissing:true). Opening
              // WITHOUT openOnly makes `ensure` spawn a SECOND surface —
              // the「两个 internal session」double-dispatch bug. Just open
              // the one the node is already bound to.
              void openInternalSessionForNode(nodeId, runner, true)
            })
          })
      })
      .catch((err) => notifyError((err as Error).message || 'Failed to create a new node session'))
      .finally(() => setBusy(false))
  }, [canvasId, handleGraphStateChanged, notifyError, openInternalSessionForNode, warnMCPWritebackIfNeeded, workspacePath])

  const handleOpenNodeSession = useCallback((sessionId: string, nodeId: string) => {
    const trimmed = sessionId.trim()
    if (!trimmed) return
    setBusy(true)
    setError(null)
    // BUG 1.2 — "open progress": open the ALREADY-bound session only. If it has
    // genuinely died (not a reusable internal surface AND not live in the board
    // sessions), the server reports `session_ended` (handled in
    // openInternalSessionForNode) instead of silently spawning a replacement.
    openInternalSessionForNode(nodeId, undefined, true)
      .then((ok) => {
        if (ok) {
          const sessionStillVisible = (boardState?.sessions ?? []).some((session) => (
            session.terminalKind === 'internal' && sessionMatchesBoundId(session.id, trimmed)
          ))
          if (!sessionStillVisible) onNotify?.('success', 'Opening this node in an internal terminal.')
        }
      })
      .finally(() => setBusy(false))
  }, [boardState?.sessions, onNotify, openInternalSessionForNode])

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
            // Keep visibility for declared slots AND for concrete produced
            // artifacts (their reference is not in `schema.outputs`).
            const validOutputs = new Set([
              ...sourceNode.schema.outputs,
              ...(sourceNode.artifactRefs ?? []),
            ])
            next[sourceNodeId] = {
              inputs: visible.inputs.filter((item) => sourceNode.schema.inputs.includes(item)),
              outputs: visible.outputs.filter((item) => validOutputs.has(item)),
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

  // canvas-spec §7.1 — toggle an I/O slot artifact on/off the canvas. Defined
  // here (above the `graph` useMemo) so the adapter can wire it onto every node
  // card's 「查看输出」 button; the useMemo factory executes during render,
  // before any later const declaration would have initialized.
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

  // UI-2 · F1.1 — open the assign dialog from a node's owner chip.
  const handleRequestAssign = useCallback((nodeId: string) => {
    if (plannerState?.canvas.visibility !== 'public') {
      onNotify?.('error', 'Publish this canvas to Team before assigning a node.')
      return
    }
    setAssignError(null)
    setAssignDialogNodeId(nodeId)
  }, [onNotify, plannerState?.canvas.visibility])

  const handleCancelAssign = useCallback(() => {
    if (assignBusy) return
    setAssignDialogNodeId(null)
    setAssignError(null)
  }, [assignBusy])

  // UI-2 · F1.2 + U2.2 — wire the dialog to the assign RPC. On success the
  // graph state is re-loaded so the just-assigned node renders as a sub-canvas
  // ref chip (per ENG-4 `node_assigned` payload). On failure we keep the
  // dialog open with the error so the user can retry or cancel.
  const handleConfirmAssign = useCallback((input: { assigneeUserId: string; acceptPrivateUpgrade: boolean }) => {
    if (!assignDialogNodeId) return
    setAssignBusy(true)
    setAssignError(null)
    assignPlannerNode(canvasId, assignDialogNodeId, input.assigneeUserId, {
      acceptPrivateUpgrade: input.acceptPrivateUpgrade,
    })
      .then((result) => {
        handleGraphStateChanged(result.graph)
        setAssignDialogNodeId(null)
        if (result.visibilityUpgraded) {
          onNotify?.('success', 'Canvas published and node assigned.')
        } else {
          onNotify?.('success', 'Node assigned.')
        }
      })
      .catch((err) => {
        setAssignError((err as Error).message || 'Failed to assign node')
      })
      .finally(() => setAssignBusy(false))
  }, [assignDialogNodeId, canvasId, handleGraphStateChanged, onNotify])

  // UI-2: when a sub-canvas chip's "Open" button fires, hand off to the
  // existing sub-canvas navigator. Reuses the same callback the kanban-item
  // path uses so we land in the same canvas viewer.
  const handleOpenAssignedSubCanvas = useCallback((subCanvasId: string) => {
    onOpenSubCanvas?.(subCanvasId)
  }, [onOpenSubCanvas])

  // UI-2: derive an in-memory map for the adapter from plannerState.
  const nodeAssignmentsByNodeId = useMemo(() => {
    const result: Record<string, NodeAssignment> = {}
    for (const assignment of plannerState?.nodeAssignments ?? []) {
      result[assignment.sourceNodeId] = assignment
    }
    return result
  }, [plannerState?.nodeAssignments])

  /* ---------- UI-4 handlers ---------- */

  // "+ Transform" on an edge: produce a proposal that inserts a session-kind
  // step node between `sourceNodeId` and `targetNodeId`, rewires the target
  // to depend on the new node, and preserves the upstream connection.
  // The new node is a regular session step — its prompt slot is editable as
  // usual once the user opens it.
  const handleInsertTransformBetween = useCallback((sourceNodeId: string, targetNodeId: string) => {
    const sourceNode = plannerState?.nodes.find((node) => node.id === sourceNodeId)
    const targetNode = plannerState?.nodes.find((node) => node.id === targetNodeId)
    if (!sourceNode || !targetNode) return
    const newNodeId = `transform-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`
    const title = `Transform ${sourceNode.title} → ${targetNode.title}`
    const newDepends = Array.from(
      new Set([...(targetNode.dependsOnNodeIds ?? []).filter((id) => id !== sourceNodeId), newNodeId]),
    )
    const newNode: PlanningNode = {
      id: newNodeId,
      canvasId,
      title,
      schema: {
        inputs: [],
        outputs: [],
        goal: `Transform upstream output before passing to ${targetNode.title}.`,
      },
      contextSources: [],
      executionMode: 'auto',
      executorType: 'claude',
      doerId: targetNode.doerId,
      reviewerIds: [],
      approverIds: [],
      handoffPolicy: 'none',
      // 3-tai cut (2026-05-29): `draft` 被移除,ready 是初始态。
      status: 'ready',
      sessionId: null,
      chatThreadId: null,
      source: 'planner',
      dependsOnNodeIds: [sourceNodeId],
      subCanvasId: null,
      nodeKind: 'step',
    }
    setBusy(true)
    setError(null)
    proposePlannerGraphChange(canvasId, {
      summary: `Insert transform session between "${sourceNode.title}" and "${targetNode.title}"`,
      changes: [
        { kind: 'addNode', node: newNode },
        { kind: 'updateNode', nodeId: targetNode.id, dependsOnNodeIds: newDepends },
      ],
    })
      .then((next) => {
        if (next) {
          setProposal(next)
          setReviewRequestTick((tick) => tick + 1)
        }
      })
      .catch((err) => notifyError((err as Error).message || 'Failed to insert transform session'))
      .finally(() => setBusy(false))
  }, [canvasId, notifyError, plannerState?.nodes])

  // Open the "Attach data source" popover.
  const handleOpenAttachDataSource = useCallback((nodeId: string) => {
    setAttachDataSourceNodeId(nodeId)
  }, [])

  // Submit handler from the popover. No-op + TODO today: real wiring lives
  // in INT-2 (Notion + 6 others) once the connector hub exposes both the
  // connector list and a `POST /api/planner/.../nodes/:id/external-bindings`
  // endpoint. The call is best-effort so the popover can close cleanly.
  const handleSubmitAttachDataSource = useCallback(async (
    nodeId: string,
    input: { connectorSlug: string; ref: string },
  ) => {
    // TODO(INT-2 / ENG-3 follow-up): replace this with the real
    // bind-external-input API. Today the canvas DTO has no field for the
    // resulting `NodeContractExternalInput[]` either; once it does, refresh
    // graph state here.
    try {
      await fetch(
        `/api/planner/canvases/${encodeURIComponent(canvasId)}/nodes/${encodeURIComponent(nodeId)}/external-bindings`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ connector: input.connectorSlug, ref: input.ref }),
        },
      )
    } catch {
      // Swallow — the endpoint may not exist yet. The popover surfaces no
      // network error so the user sees the action as accepted; INT-2 will
      // upgrade this to a real bind that returns the new contract state.
    }
    // eslint-disable-next-line no-console
    console.info(
      '[UI-4 TODO] attach data source no-op',
      { canvasId, nodeId, connector: input.connectorSlug, ref: input.ref },
    )
  }, [canvasId])

  // Refresh-now per external row. Stub today; INT-2 / ENG-3 will dispatch
  // the bound sync session and bump a "last synced at" timestamp on the row.
  const handleRefreshExternalInput = useCallback((
    nodeId: string,
    external: NodeContractExternalInput,
  ) => {
    // eslint-disable-next-line no-console
    console.info(
      '[UI-4 TODO] refresh external input (no-op until INT-2)',
      { canvasId, nodeId, connector: external.connector, ref: external.ref, syncSession: external.sync_session },
    )
  }, [canvasId])

  // Dialogue retention popover: hook is currently a logger; the real wiring
  // will dispatch a refine-session-prompt proposal (ENG-2 endpoint) or a
  // dedicated update-contract endpoint when ENG-3 lands.
  const handleConfigureDialogue = useCallback((nodeId: string) => {
    // eslint-disable-next-line no-console
    console.info('[UI-4] configure dialogue retention (popover handled in-card)', { canvasId, nodeId })
  }, [canvasId])

  // 2026-06-02 状态跟会话走:从实时 boardState 收集仍存活(可打开)的会话 id/surfaceId。
  // surfaceStatus running/starting = 进程还在、终端可 attach。喂给 buildPlannerGraph 派生
  // 每个节点的 boundSessionLive,让 done/未启动 但会话还活的节点显示「在线待命」。
  const liveSessionIds = useMemo(() => {
    const ids = new Set<string>()
    for (const session of boardState?.sessions ?? []) {
      const surface = (session.surfaceStatus ?? '').toLowerCase()
      if (surface === 'running' || surface === 'starting') {
        if (session.id) ids.add(session.id)
        if (session.surfaceId) ids.add(session.surfaceId)
      }
    }
    return ids
  }, [boardState?.sessions])

  // 简略进展 — 和 inspector「进展」段共享同一个数据源:实时 boardState.sessions,
  // 按 node.sessionId 用 sessionMatchesBoundId 匹配。这里只蒸馏出卡片放大后要露出
  // 的极少信息(目前=最近一条 AI 回复),按 nodeId 建表。刻意不喂进 buildPlannerGraph
  // 的结构 memo(那条路径只吃稳定的 liveSessionIds Set),否则每次会话轮询都会重建
  // 整张图(连边一起)。注入走下面的 effect,只动到内容变了的那几张卡。
  const nodeProgressByNodeId = useMemo(() => {
    const map = new Map<string, NodeLiveProgress>()
    const sessions = boardState?.sessions ?? []
    if (sessions.length === 0) return map
    for (const node of plannerState?.nodes ?? []) {
      const sid = node.sessionId?.trim()
      if (!sid) continue
      const session = sessions.find((s) => sessionMatchesBoundId(s.id, sid))
      if (!session) continue
      const summary = summarizeSessionProgress(session)
      if (summary.lastReply) map.set(node.id, summary)
    }
    return map
  }, [boardState?.sessions, plannerState?.nodes])

  const renderAwareNodes = useMemo(
    () => nodesWithRenderValues(plannerState),
    [plannerState],
  )
  const renderSceneSpec = useMemo(
    () => sceneSpecForRender(plannerState),
    [plannerState],
  )

  const persistNodeLayout = useCallback((
    nodeId: string,
    layout: { x: number; y: number; width: number | null; height: number | null },
  ) => {
    setPlannerState((current) => current
      ? {
        ...current,
        nodes: current.nodes.map((item) => item.id === nodeId ? { ...item, layout } : item),
      }
      : current)
    patchCanvasRenderValues(canvasId, {
      objects: {
        [`node:${nodeId}`]: {
          x: layout.x,
          y: layout.y,
          width: layout.width,
          height: layout.height,
        },
      },
    })
      .then(handleGraphStateChanged)
      .catch((err) => notifyError((err as Error).message || 'Failed to save node layout'))
  }, [canvasId, handleGraphStateChanged, notifyError])

  const persistRenderObjectValues = useCallback((
    objectId: string,
    patch: CanvasRenderObjectValues,
  ) => {
    setPlannerState((current) => current
      ? applyRenderObjectValuePatch(current, objectId, patch)
      : current)
    patchCanvasRenderValues(canvasId, {
      objects: {
        [objectId]: patch,
      },
    })
      .then(handleGraphStateChanged)
      .catch((err) => notifyError((err as Error).message || 'Failed to save render values'))
  }, [canvasId, handleGraphStateChanged, notifyError])

  const handleCanvasObjectAction = useCallback((object: CanvasObject, action: CanvasObjectAction) => {
    const values = object.values ?? {}
    if (action === 'hide') {
      persistRenderObjectValues(object.id, { ...values, hidden: true })
      return
    }
    if (action === 'toggleCollapsed') {
      persistRenderObjectValues(object.id, { ...values, collapsed: !values.collapsed })
      return
    }
    if (action === 'togglePinned') {
      const pinned = !values.pinned
      persistRenderObjectValues(object.id, { ...values, pinned, zIndex: pinned ? 1000 : 0 })
      return
    }
    const ref = object.entityRef
    if (!ref) return
    if (ref.kind === 'node') {
      handleOpenNodeDetails(ref.nodeId || ref.id)
      return
    }
    if (ref.kind === 'artifact' && ref.nodeId) {
      handleOpenNodeArtifact(ref.nodeId, ref.id)
      return
    }
    if (ref.kind === 'session') {
      handleOpenNodeSession(ref.id, ref.nodeId ?? '')
      return
    }
    if (ref.kind === 'subCanvas') {
      onOpenSubCanvas?.(ref.id)
    }
  }, [
    handleOpenNodeArtifact,
    handleOpenNodeDetails,
    handleOpenNodeSession,
    onOpenSubCanvas,
    persistRenderObjectValues,
  ])

  const graph = useMemo(() => {
    const built = buildPlannerGraph({
      nodes: renderAwareNodes,
      states: plannerState?.states ?? [],
      edges: plannerState?.edges ?? [],
      firstClassEdges: plannerState?.canvas.edges ?? [],
      artifacts: plannerState?.artifacts ?? [],
      integrationEntities: plannerState?.integrationEntities,
      proposal: null,
      ownerId: plannerState?.canvas.ownerId,
      mode: 'design',
      canvasId,
      runNodeStates: undefined,
      liveSessionIds,
      ioArtifactVisibility,
      displayNameByUserId: teamDirectory.displayNameByUserId,
      avatarUrlByUserId: teamDirectory.avatarUrlByUserId,
      onOpenDetails: handleOpenNodeDetails,
      onOpenArtifact: handleOpenNodeArtifact,
      onOpenSubCanvas,
      onOpenKanbanItem: handleOpenKanbanItem,
      onBindInput: handleBindNodeInput,
      onChangeStatus: handleChangeNodeStatus,
      onChangeGateMode: handleChangeNodeGateMode,
      canChangeStatus: variant !== 'template' && (plannerState?.canEditInternals ?? true),
      onCreateSession: handleCreateNodeSession,
      onOpenSession: handleOpenNodeSession,
      onReplaceSession: handleReplaceNodeSession,
      onCancelSessionCreation: handleCancelNodeSessionCreation,
      onDeleteNode: handleDeleteNode,
      onHideIOArtifact: handleHideIOArtifact,
      onToggleIOArtifact: handleToggleIOArtifact,
      onRerunNode: handleRerunNode,
      onAttachDataSource: handleOpenAttachDataSource,
      onRefreshExternalInput: handleRefreshExternalInput,
      onConfigureDialogue: handleConfigureDialogue,
      onInsertTransformBetween: handleInsertTransformBetween,
      creatingSessionNodeIds,
      showResponsibleInfo: plannerState?.canvas.visibility !== 'private',
      nodeAssignmentsByNodeId,
      onRequestAssign: (plannerState?.canEditInternals ?? true) ? handleRequestAssign : undefined,
      onOpenAssignedSubCanvas: handleOpenAssignedSubCanvas,
      canEditInternals: plannerState?.canEditInternals ?? true,
      monitorItemsByNodeId,
    })
    const nodeObjects = applyRenderValuesToFlowNodes(built.nodes, plannerState)
    const overlay = buildCanvasObjectOverlay({
      state: plannerState,
      baseNodes: nodeObjects,
      onAction: handleCanvasObjectAction,
      canEdit: variant !== 'template' && (plannerState?.canEditInternals ?? true),
    })
    const withObjects = {
      nodes: [...nodeObjects, ...overlay.nodes],
      edges: [...built.edges, ...overlay.edges],
    }
    if (!guidedNodeId) return withObjects
    return {
      ...withObjects,
      nodes: withObjects.nodes.map((node) => isPlannerGraphNode(node) && node.id === guidedNodeId
        ? { ...node, data: { ...node.data, guided: true } }
        : node),
    }
  }, [
    renderAwareNodes,
    plannerState?.states,
    plannerState?.edges,
    plannerState?.canvas.edges,
    plannerState?.artifacts,
    plannerState?.canvas.ownerId,
    plannerState?.canvas.visibility,
    plannerState?.renderObjects,
    plannerState?.renderRelations,
    plannerState?.renderProfile,
    canvasId,
    liveSessionIds,
    ioArtifactVisibility,
    teamDirectory,
    handleOpenNodeDetails,
    handleOpenNodeArtifact,
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
    handleToggleIOArtifact,
    handleRerunNode,
    handleOpenAttachDataSource,
    handleRefreshExternalInput,
    handleConfigureDialogue,
    handleInsertTransformBetween,
    creatingSessionNodeIds,
    variant,
    nodeAssignmentsByNodeId,
    handleRequestAssign,
    handleOpenAssignedSubCanvas,
    handleCanvasObjectAction,
    plannerState?.canEditInternals,
    monitorItemsByNodeId,
    guidedNodeId,
  ])

  const reviewGraph = useMemo(() => {
    if (!plannerState || !proposal) return { nodes: [], edges: [] }
    return buildPlannerGraph({
      nodes: renderAwareNodes,
      states: plannerState.states,
      edges: plannerState.edges,
      firstClassEdges: plannerState.canvas.edges ?? [],
      artifacts: plannerState.artifacts,
      integrationEntities: plannerState.integrationEntities,
      proposal,
      ownerId: plannerState.canvas.ownerId,
      mode: 'design',
      canvasId,
      runNodeStates: undefined,
      ioArtifactVisibility,
      displayNameByUserId: teamDirectory.displayNameByUserId,
      avatarUrlByUserId: teamDirectory.avatarUrlByUserId,
    })
  }, [
    renderAwareNodes,
    plannerState?.states,
    plannerState?.edges,
    plannerState?.canvas.edges,
    plannerState?.artifacts,
    plannerState?.canvas.ownerId,
    proposal,
    ioArtifactVisibility,
    teamDirectory,
  ])
  const activeProposal = proposal && (proposal.status === 'pending' || proposal.status === 'approved') ? proposal : null
  // propose_add_node · 来源归属:节点工作会话发起的提案,面板与审批模态显示
  // 「来自节点 X 的提议」。节点已被删时回落显示原始 id。
  const proposalOriginTitle = useMemo(() => {
    const originId = proposal?.originNodeId
    if (!originId) return null
    return plannerState?.nodes.find((node) => node.id === originId)?.title ?? originId
  }, [plannerState, proposal])
  const emptyCanvasMode = Boolean(
    plannerState
    && plannerState.canvas.id === canvasId
    && isPlannerCanvasEmptyForOnboarding(plannerState)
    && !activeProposal,
  )
  const showWorkspacePreview = Boolean(activeProposal && reviewGraph.nodes.length > 0)
  const starterSuggestions = useMemo(() => buildStarterSuggestions(
    canvasName,
    plannerState?.canvas.plannerContext,
    officialCanvasTemplates,
    t,
  ), [
    canvasName,
    officialCanvasTemplates,
    plannerState?.canvas.plannerContext,
    t,
  ])

  useEffect(() => {
    if (!emptyCanvasMode || officialCanvasTemplates.length > 0) return
    let cancelled = false
    fetchCanvasTemplates()
      .then((templates) => {
        if (!cancelled) setOfficialCanvasTemplates(templates)
      })
      .catch(() => {
        if (!cancelled) setOfficialCanvasTemplates([])
      })
    return () => {
      cancelled = true
    }
  }, [emptyCanvasMode, officialCanvasTemplates.length])

  useEffect(() => {
    setFlowNodes((current) => mergeGraphNodesPreservingPositions(graph.nodes, current))
  }, [graph.nodes])

  // 简略进展注入 —— 把 nodeProgressByNodeId 合进 flowNodes 的 data.liveProgress。
  // 单独一个 effect、deps 只有 nodeProgressByNodeId(每次会话轮询变一次):用
  // liveProgressEqual 做浅比较,只给内容真的变了的节点换新对象,其余保持引用不变,
  // 这样 react-flow 只重渲染那几张卡,而不是每次轮询全图重渲染。结构重建(上面的
  // merge effect)会从 current 带过 liveProgress,避免 plannerState 变更时闪掉。
  useEffect(() => {
    setFlowNodes((current) => {
      let changed = false
      const next = current.map((node) => {
        if (!isPlannerGraphNode(node)) return node
        if (node.data.virtual) return node
        const progress = nodeProgressByNodeId.get(node.id) ?? null
        if (liveProgressEqual(node.data.liveProgress ?? null, progress)) return node
        changed = true
        return { ...node, data: { ...node.data, liveProgress: progress } }
      })
      return changed ? next : current
    })
  }, [nodeProgressByNodeId])

  const handleNodesChange = useCallback((changes: NodeChange<CanvasFlowNode>[]) => {
    setFlowNodes((current) => {
      const next = applyNodeChanges(changes, current) as CanvasFlowNode[]
      // 宽高自由调整 — NodeResizer 拖动过程中发 type:'dimensions' & resizing:true,
      // 松手那一帧 resizing:false。只在松手时落库,避免拖动途中狂刷后端。
      // 用 next(已应用本帧变更)取最终 position + 尺寸;从顶/左边把手缩放也会改
      // position,所以要读应用后的值。虚拟 I/O artifact 节点不落库(派生节点)。
      const finished = changes.filter(
        (change): change is Extract<NodeChange<CanvasFlowNode>, { type: 'dimensions' }> =>
          change.type === 'dimensions' && change.resizing === false,
      )
      if (finished.length > 0) {
        const pending = finished
          .map((change) => next.find((node) => node.id === change.id))
          .filter((node): node is CanvasFlowNode => Boolean(node))
        if (pending.length > 0) {
          // setState updater 里不能直接触发别的 state 更新 / 网络请求,推到微任务。
          queueMicrotask(() => {
            for (const node of pending) {
              if (isPlannerGraphNode(node)) {
                if (node.data.virtual) continue
                persistNodeLayout(node.data.node.id, {
                  x: node.position.x,
                  y: node.position.y,
                  width: node.width ?? node.measured?.width ?? null,
                  height: node.height ?? node.measured?.height ?? null,
                })
              } else {
                persistRenderObjectValues(node.data.object.id, {
                  ...(node.data.object.values ?? {}),
                  x: node.position.x,
                  y: node.position.y,
                  width: node.width ?? node.measured?.width ?? null,
                  height: node.height ?? node.measured?.height ?? null,
                })
              }
            }
          })
        }
      }
      return next
    })
  }, [persistNodeLayout, persistRenderObjectValues])

  // UI-5.2 — persist per-canvas viewport pose after every pan/zoom so the user
  // can opt in to "Lock viewport on switch" later and still get the right
  // restore. Saving unconditionally keeps the storage payload tiny (~40 bytes
  // per canvas) and behaves correctly when the preference is flipped on.
  const handleViewportMoveEnd = useCallback((
    _event: unknown,
    viewport: { x: number; y: number; zoom: number },
  ) => {
    if (!canvasId) return
    if (viewportSaveTimerRef.current !== null) {
      window.clearTimeout(viewportSaveTimerRef.current)
    }
    viewportSaveTimerRef.current = window.setTimeout(() => {
      viewportSaveTimerRef.current = null
      savePlannerViewport(canvasId, viewport)
    }, 250)
  }, [canvasId])

  useEffect(() => {
    return () => {
      if (viewportSaveTimerRef.current !== null) {
        window.clearTimeout(viewportSaveTimerRef.current)
        viewportSaveTimerRef.current = null
      }
    }
  }, [])

  const handleNodeDragStop = useCallback((node: CanvasFlowNode) => {
    if (!isPlannerGraphNode(node)) {
      persistRenderObjectValues(node.data.object.id, {
        ...(node.data.object.values ?? {}),
        x: node.position.x,
        y: node.position.y,
        width: node.width ?? node.measured?.width ?? node.data.object.values?.width ?? null,
        height: node.height ?? node.measured?.height ?? node.data.object.values?.height ?? null,
      })
      return
    }
    if (node.data.virtual) return
    // 拖动只改位置 —— 尺寸保留 layout 里已有的值(可能为空)。不要把当时测量到的
    // 内容高度写进 layout,否则一拖动就把高度冻死,后续内容变多会被裁切。宽高只由
    // NodeResizer 调整结束时落库(见 handleNodesChange)。
    const prior = node.data.node.layout
    persistNodeLayout(node.data.node.id, {
      x: node.position.x,
      y: node.position.y,
      width: prior?.width ?? null,
      height: prior?.height ?? null,
    })
  }, [persistNodeLayout, persistRenderObjectValues])

  useEffect(() => {
    if (dialogCollapsed === undefined) {
      window.localStorage.setItem(PANEL_COLLAPSED_KEY, plannerPanelCollapsed ? '1' : '0')
    }
  }, [dialogCollapsed, plannerPanelCollapsed])

  useEffect(() => {
    if (forceDialogOpenTick > 0) setPlannerPanelCollapsed(false)
  }, [forceDialogOpenTick])

  useEffect(() => {
    document.documentElement.style.setProperty('--planner-chat-width', plannerPanelCollapsed ? '0px' : `${plannerPanelWidth}px`)
    document.documentElement.classList.toggle('board-planner-chat-collapsed', plannerPanelCollapsed)
    return () => {
      document.documentElement.style.removeProperty('--planner-chat-width')
      document.documentElement.classList.remove('board-planner-chat-collapsed')
    }
  }, [plannerPanelCollapsed, plannerPanelWidth])

  useEffect(() => {
    document.documentElement.classList.toggle('board-empty-omni', emptyCanvasMode)
    return () => {
      document.documentElement.classList.remove('board-empty-omni')
    }
  }, [emptyCanvasMode])

  const loadedPlannerCanvasId = plannerState?.canvas.id
  useEffect(() => {
    if (!loadedPlannerCanvasId || loadedPlannerCanvasId !== canvasId || graph.nodes.length === 0) return undefined
    // UI-5.2 — when the user enabled "Lock viewport on switch" and we have a
    // saved pose for this canvas, do not auto-re-center on node-count / panel-
    // width changes. Pan/zoom stays exactly where the user left it. Keep this
    // keyed to stable layout signals instead of the whole plannerState object:
    // background status refreshes must not steal the user's zoomed-in view.
    if (lockViewportOnSwitch && loadPlannerViewport(canvasId)) return undefined
    const timer = window.setTimeout(() => {
      if (window.matchMedia('(max-width: 720px)').matches) {
        reactFlow.setViewport({ x: 18, y: 52, zoom: 0.9 }, { duration: 220 })
        return
      }
      reactFlow.fitView({ padding: 0.14, duration: 220 })
    }, 180)
    return () => window.clearTimeout(timer)
  }, [graph.nodes.length, plannerPanelCollapsed, loadedPlannerCanvasId, reactFlow, lockViewportOnSwitch, canvasId])

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


  const handlePanelResizeStart = useCallback((event: ReactPointerEvent<HTMLButtonElement>) => {
    event.preventDefault()
    const startX = event.clientX
    const startWidth = plannerPanelWidth
    const onPointerMove = (moveEvent: PointerEvent) => {
      setPlannerPanelWidth(clampPanelWidth(startWidth + moveEvent.clientX - startX))
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
    if (!plannerState || loadedPlannerCanvasId !== canvasId || fitViewCanvasRef.current === canvasId) return
    fitViewCanvasRef.current = canvasId
    // UI-5.2 — opt-out for auto-center-on-switch.
    // When the user enabled "Lock viewport on switch" and we have a previous
    // viewport pose for this canvas, restore it and skip the fitView. Default
    // behavior (lock off / no saved pose) is unchanged: auto-fit on switch.
    const savedPose = lockViewportOnSwitch ? loadPlannerViewport(canvasId) : null
    if (savedPose) {
      reactFlow.setViewport(savedPose, { duration: 0 })
      return undefined
    }
    const timer = window.setTimeout(() => {
      if (graph.nodes.length === 0 || window.matchMedia('(max-width: 720px)').matches) {
        reactFlow.setViewport({ x: 18, y: 52, zoom: 0.9 }, { duration: 220 })
        return
      }
      reactFlow.fitView({ padding: 0.12, duration: 220 })
    }, 120)
    return () => window.clearTimeout(timer)
  }, [plannerState, loadedPlannerCanvasId, graph.nodes.length, canvasId, reactFlow, lockViewportOnSwitch])

  const selectedNode = useMemo(() => {
    if (!selectedNodeId) return null
    const graphNode = graph.nodes.find((node) => node.id === selectedNodeId)
    return plannerState?.nodes.find((node) => node.id === selectedNodeId)
      ?? (graphNode && isPlannerGraphNode(graphNode) ? graphNode.data.node : null)
      ?? null
  }, [graph.nodes, plannerState, selectedNodeId])

  // UI-2: planner node currently targeted by the assign dialog, if any.
  const assignDialogNode = useMemo(() => {
    if (!assignDialogNodeId) return null
    const graphNode = graph.nodes.find((node) => node.id === assignDialogNodeId)
    return plannerState?.nodes.find((node) => node.id === assignDialogNodeId)
      ?? (graphNode && isPlannerGraphNode(graphNode) ? graphNode.data.node : null)
      ?? null
  }, [assignDialogNodeId, graph.nodes, plannerState])

  useEffect(() => {
    setSessionHealthBoardState(boardState)
  }, [boardState])

  const closedBoundSessions = useMemo(() => {
    return collectClosedBoundSessions(plannerState?.nodes ?? [], sessionHealthBoardState?.sessions ?? [])
  }, [plannerState?.nodes, sessionHealthBoardState?.sessions])

  const readySessionPlan = useMemo(() => {
    return collectReadySessionPlan(plannerState?.nodes ?? [], sessionHealthBoardState?.sessions ?? [])
  }, [plannerState?.nodes, sessionHealthBoardState?.sessions])

  useEffect(() => {
    if (!plannerState || plannerState.nodes.every((node) => !node.sessionId?.trim())) return
    let cancelled = false
    const probe = () => {
      fetchState()
        .then((state) => {
          if (!cancelled) setSessionHealthBoardState(state)
        })
        .catch(() => {
          // Health probe is advisory; keep the last known state.
        })
    }
    probe()
    const timer = window.setInterval(probe, 20_000)
    return () => {
      cancelled = true
      window.clearInterval(timer)
    }
  }, [canvasId, plannerState])

  const handleResumeClosedSessions = useCallback(() => {
    const sessionIds = closedBoundSessions.map((item) => item.sessionId)
    if (sessionIds.length === 0) return
    setResumingClosedSessions(true)
    setError(null)
    resumeClosedPlannerSessions(canvasId, sessionIds)
      .then((result) => {
        if (result.resumed.length > 0) {
          onNotify?.('success', formatRecoveredSessionToast(result.resumed))
          const first = result.resumed[0]
          window.dispatchEvent(new CustomEvent('meee2:open-session', {
            detail: {
              sessionId: first.sessionId,
              surfaceId: first.surfaceId,
              canvasId,
            },
          }))
          loadState()
          void fetchState().then(setSessionHealthBoardState).catch(() => undefined)
        }
        if (result.skipped.length > 0) {
          notifyError(result.skipped.map((item) => item.reason).join('; '))
        }
      })
      .catch((err) => notifyError((err as Error).message || 'Failed to restore closed sessions'))
      .finally(() => setResumingClosedSessions(false))
  }, [canvasId, closedBoundSessions, loadState, notifyError, onNotify])

  const handleStartReadySessions = useCallback(() => {
    if (!workspacePath.trim()) {
      notifyError('Current canvas workspace is not ready yet.')
      return
    }
    if (readySessionPlan.total === 0) return
    warnMCPWritebackIfNeeded()
    setStartingReadySessions(true)
    setError(null)
    const createNodeIds = readySessionPlan.create.map((node) => node.id)
    const missingBoundSessionIds = [
      ...readySessionPlan.resume.map((item) => item.sessionId),
      ...readySessionPlan.recreate.map((item) => item.sessionId),
    ]
    fetchState()
      .catch(() => null)
      .then((beforeState) => {
        const work: Promise<unknown>[] = []
        if (missingBoundSessionIds.length > 0) {
          work.push(resumeClosedPlannerSessions(canvasId, missingBoundSessionIds).then((result) => {
            if (result.resumed.length > 0 && createNodeIds.length === 0) {
              const first = result.resumed[0]
              window.dispatchEvent(new CustomEvent('meee2:open-session', {
                detail: {
                  sessionId: first.sessionId,
                  surfaceId: first.surfaceId,
                  canvasId,
                },
              }))
            }
            if (result.skipped.length > 0) {
              notifyError(result.skipped.map((item) => item.reason).join('; '))
            }
          }))
        }
        for (const node of readySessionPlan.create) {
          work.push(dispatchPlannerNodeSession(canvasId, node.id, dispatchRunnerForExecutor(node.executorType), workspacePath.trim())
            .then((state) => {
              handleGraphStateChanged(state)
              setCreatingSessionNodeIds((current) => new Set(current).add(node.id))
            }))
        }
        return Promise.all(work).then(() => beforeState)
      })
      .then((beforeState) => {
        if (readySessionPlan.total > 0) {
          onNotify?.('success', `Starting ${readySessionPlan.total} ready node${readySessionPlan.total === 1 ? '' : 's'}.`)
        }
        if (createNodeIds.length === 0) {
          loadState()
          void fetchState().then(setSessionHealthBoardState).catch(() => undefined)
          return
        }
        void beforeState
        void pollForReadyNodeSessions(canvasId, createNodeIds, handleGraphStateChanged, () => {
          setCreatingSessionNodeIds((current) => {
            const next = new Set(current)
            createNodeIds.forEach((nodeId) => next.delete(nodeId))
            return next
          })
          void fetchState().then(setSessionHealthBoardState).catch(() => undefined)
        })
      })
      .catch((err) => notifyError((err as Error).message || 'Failed to start ready sessions'))
      .finally(() => setStartingReadySessions(false))
  }, [
    canvasId,
    handleGraphStateChanged,
    loadState,
    notifyError,
    onNotify,
    readySessionPlan,
    warnMCPWritebackIfNeeded,
    workspacePath,
  ])

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
        if (next) {
          setReviewRequestTick((tick) => tick + 1)
          // ENG-5: emit canvas_mutated telemetry every time we land a proposal
          // through the chat composer — this is the signal we want to compare
          // against revert/30s to validate the heuristic.
          emitPlannerEvent('planner.canvas_mutated', { canvasId, message: goal, intent: 'edit' })
        }
      })
      .catch((err) => notifyError(formatPlannerProposalError(err, 'Failed to generate meee2 AI proposal')))
      .finally(() => setBusy(false))
  }, [canvasId, notifyError, plannerState, proposal])

  const handlePlannerSubmit = useCallback((message: string) => {
    const trimmed = message.trim()
    const confirmedPlan = parseConfirmedPlanDraft(trimmed)
    if (confirmedPlan) {
      if (isScenePlanDraft(confirmedPlan)) {
        if (!onApplyTemplate) {
          notifyError('Scene template creation is not available in this surface.')
          return
        }
        setBusy(true)
        setError(null)
        onApplyTemplate(
          confirmedPlan.templateId,
          confirmedPlan.title,
          'personal',
          confirmedPlan.adaptationPrompt ?? confirmedPlan.prompt,
        )
          .then(() => {
            emitPlannerEvent('planner.scene_template_applied', {
              canvasId,
              templateId: confirmedPlan.templateId,
              message: confirmedPlan.title,
              intent: 'edit',
            })
            onNotify?.('success', `Created scene canvas from ${confirmedPlan.templateId}.`)
          })
          .catch((err) => notifyError((err as Error).message || 'Failed to create scene canvas'))
          .finally(() => setBusy(false))
        return
      }
      setBusy(true)
      setError(null)
      const actorId = plannerState?.access.actorId
        ?? plannerState?.canvas.ownerId
        ?? userProfile?.userId
        ?? 'local-owner'
      const changes = buildConfirmedPlanGraphChanges({
        canvasId,
        actorId,
        draft: confirmedPlan,
        existingNodeIds: plannerState?.nodes.map((node) => node.id) ?? [],
      })
      proposePlannerGraphChange(canvasId, {
        summary: `Draft canvas: ${confirmedPlan.title}`,
        changes,
      })
        .then((next) => {
          setProposal(next)
          setPlannerState((current) => current && next
            ? { ...current, proposals: upsertProposal(current.proposals, next) }
            : current)
          if (next) {
            setReviewRequestTick((tick) => tick + 1)
            emitPlannerEvent('planner.canvas_mutated', { canvasId, message: confirmedPlan.title, intent: 'edit', reason: 'confirmed-plan' })
          }
        })
        .catch((err) => notifyError(formatPlannerProposalError(err, 'Failed to draft canvas')))
        .finally(() => setBusy(false))
      return
    }
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
                if (generated) {
                  setReviewRequestTick((tick) => tick + 1)
                  emitPlannerEvent('planner.canvas_mutated', { canvasId, message: trimmed, intent: 'inspect' })
                }
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
          emitPlannerEvent('planner.canvas_mutated', { canvasId, message: trimmed || '(drift)', intent: 'inspect' })
          return undefined
        })
        .catch((err) => notifyError(formatPlannerProposalError(err, 'Failed to inspect meee2 AI drift')))
        .finally(() => setBusy(false))
      return
    }

    if (!trimmed) return

    // ENG-5: classify the user's intent before deciding whether to mutate the
    // canvas. Three new outcomes vs the original "always mutate":
    //   - 'answer'  → push a text reply to the panel, do not call generate.
    //   - 'promote' → inject the directive into the selected node's bound
    //                 session prompt (no schema mutation).
    //   - 'edit'    → existing generate-proposal path.
    const intent = classifyPlannerIntent(trimmed, {
      hasSelectedNodeWithSession: Boolean(selectedNode?.sessionId?.trim()),
    })

    if (intent === 'answer') {
      // Don't bulldoze the canvas. Surface a short clarification in the
      // chat panel so the user can decide whether to re-ask with an edit
      // verb. The panel auto-expands on first reply (see PlannerProposalPanel).
      emitPlannerEvent('planner.answer_only', { canvasId, message: trimmed, intent: 'answer' })
      const markdown = answerOnlyClarification(trimmed)
      setAnswerOnlyReply({ id: Date.now(), markdown })
      return
    }

    if (intent === 'promote' && selectedNode?.sessionId) {
      // Refine an existing session's prompt instead of reshaping the schema.
      // This is the "在这个 session NODE 里面去做 promote 的注入" path that
      // the spec calls out — today there is no dedicated planner-engine API
      // for this, so we route through the operator-channel inject endpoint
      // (the same one used to deliver initial spawn prompts).
      const sessionId = selectedNode.sessionId
      const nodeId = selectedNode.id
      setBusy(true)
      setError(null)
      injectToSession(sessionId, trimmed)
        .then(() => {
          emitPlannerEvent('planner.promote_into_session_prompt', {
            canvasId,
            nodeId,
            sessionId,
            intent: 'promote',
            message: trimmed,
          })
          setAnswerOnlyReply({
            id: Date.now(),
            markdown: [
              `Injected into the session prompt for **${selectedNode.title}** (session \`${sessionId.slice(0, 8)}\`).`,
              '',
              'The session can use meee2 MCP to read its node contract and write back schema-aware artifacts with `submit_node_output`; file artifacts should use `payload.file.path` so meee2 can copy them into the artifact store.',
              '',
              'If you want to change this node\'s inputs, outputs, artifact slots, gate, or task requirements, ask meee2 AI for that change here and it will create a graph proposal instead of only injecting the live session.',
            ].join('\n'),
          })
        })
        .catch((err) => setError((err as Error).message || 'Failed to inject prompt into session'))
        .finally(() => setBusy(false))
      return
    }

    handleGenerate(trimmed)
  }, [canvasId, handleGenerate, hasActionableDrift, notifyError, onApplyTemplate, onNotify, plannerState, proposal, selectedNode, userProfile?.userId])

  const handleUseRecommendedTemplate = useCallback((recommendation?: { id?: string; title?: string; templateId?: string; adaptationPrompt?: string }) => {
    if (recommendation?.templateId) {
      if (!onApplyTemplate) {
        notifyError('Scene template creation is not available in this surface.')
        return
      }
      setBusy(true)
      setError(null)
      const name = recommendation.title?.trim() || canvasName || 'Scene Canvas'
      onApplyTemplate(recommendation.templateId, name, 'personal', recommendation.adaptationPrompt)
        .then(() => {
          emitPlannerEvent('planner.scene_template_applied', {
            canvasId,
            templateId: recommendation.templateId,
            message: name,
            intent: 'edit',
            reason: 'recommended-template',
          })
          onNotify?.('success', `Created scene canvas from ${recommendation.templateId}.`)
        })
        .catch((err) => notifyError((err as Error).message || 'Failed to create scene canvas'))
        .finally(() => setBusy(false))
      return
    }
    setBusy(true)
    setError(null)
    createPlannerDeliveryPipeline(canvasId)
      .then((next) => {
        setProposal(next)
        setPlannerState((current) => current && next
          ? { ...current, proposals: upsertProposal(current.proposals, next) }
          : current)
        if (next) setReviewRequestTick((tick) => tick + 1)
      })
      .catch((err) => setError((err as Error).message || 'Failed to create recommended template proposal'))
      .finally(() => setBusy(false))
  }, [canvasId, canvasName, notifyError, onApplyTemplate, onNotify])

  const handleApproveAndApply = useCallback(() => {
    if (!proposal || busy) return
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
  }, [busy, canvasId, canvasName, proposal, reactFlow])

  const handleReject = useCallback(() => {
    if (!proposal) return
    setBusy(true)
    setError(null)
    // ENG-5: track quick reverts. If the user rejects a proposal within 30s
    // of it landing, we emit `planner.user_revert_within_30s` — this is the
    // signal the spec asks for to validate the answer-vs-edit heuristic.
    reportPlannerRevert(canvasId, { reason: 'rejected_proposal' })
    rejectPlannerProposal(canvasId, proposal.id)
      .then((next) => {
        if (!next) return
        setProposal(next.status === 'pending' || next.status === 'approved' ? next : null)
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
    // ENG-5: node-action proposals also mutate the canvas — count them.
    emitPlannerEvent('planner.canvas_mutated', { canvasId, intent: 'edit', reason: 'node_action' })
    setProposal(next)
    setPlannerState((current) => current
      ? { ...current, proposals: upsertProposal(current.proposals, next) }
      : current)
    setNodeModalOpen(false)
    setReviewRequestTick((tick) => tick + 1)
  }, [])

  const handleSendNodeActionToAI = useCallback((message: string, display?: { visibleText?: string; contextLabel?: string }) => {
    setPlannerPanelCollapsed(false)
    setPlannerDraftMessage({ id: Date.now(), text: message, ...display })
    setNodeModalOpen(false)
  }, [])

  const plannerMainStyle = {
    '--planner-chat-width': `${plannerPanelWidth}px`,
  } as CSSProperties
  const mcpWarning = mcpStatusError || (mcpStatus && !mcpStatus.launches ? mcpStatus.error || 'Meee2 MCP is not available.' : null)
  const hasSessionActionBanner = readySessionPlan.total > 0 || closedBoundSessions.length > 0
  const sessionActionBannerTitle = [
    readySessionPlan.total > 0
      ? `${readySessionPlan.total} ready node${readySessionPlan.total === 1 ? '' : 's'} can start`
      : null,
    closedBoundSessions.length > 0
      ? `${closedBoundSessions.length} bound session${closedBoundSessions.length === 1 ? '' : 's'} closed`
      : null,
  ].filter(Boolean).join(' · ')
  const readySessionActionSummary = readySessionPlan.total > 0
    ? formatSessionActionSummary([
      [readySessionPlan.create.length, 'create'],
      [readySessionPlan.recreate.length, 'recreate'],
      [readySessionPlan.resume.length, 'resume'],
    ])
    : null
  const closedBoundSessionSummary = closedBoundSessions.length > 0
    ? `${formatClosedBoundSessionActions(closedBoundSessions)} · ${closedBoundSessions.slice(0, 2).map((item) => item.nodeTitles.join(', ')).join('; ')}${closedBoundSessions.length > 2 ? ` and ${closedBoundSessions.length - 2} more` : ''}`
    : null
  const closedBoundSessionButtonLabel = closedBoundSessions.some((item) => item.action === 'resume')
    ? 'Recover missing'
    : 'Recreate missing'

  return (
    <section className="planner-workspace" aria-label="meee2 AI graph" data-guide-target="planner-workspace">
      {emptyCanvasMode ? (
        <div className="planner-empty-omni" data-guide-target="planner-proposal">
          <PlannerProposalPanel
            canvasId={canvasId}
            canvasName={plannerState?.canvas.title ?? canvasName}
            canvasTask={plannerState?.canvas.plannerContext ?? ''}
            proposal={proposal}
            proposalOriginTitle={proposalOriginTitle}
            variant={variant}
            previewGraph={reviewGraph}
            busy={busy}
            error={error}
            access={plannerState?.access ?? null}
            nodeCount={plannerState?.nodes.length ?? 0}
            hasActionableDrift={hasActionableDrift}
            onSubmit={handlePlannerSubmit}
            onUseRecommendedTemplate={handleUseRecommendedTemplate}
            onApproveAndApply={handleApproveAndApply}
            onReject={handleReject}
            draftMessage={plannerDraftMessage}
            clearRevision={clearRevision}
            reviewRequestTick={reviewRequestTick}
            answerOnlyReply={answerOnlyReply}
            layout="omni"
            emptyMode
            starterSuggestions={starterSuggestions}
            autoFocus
          />
        </div>
      ) : (
        <div
          className={`planner-main${plannerPanelCollapsed ? ' planner-main--panel-collapsed' : ''}`}
          style={plannerMainStyle}
        >
        {!plannerPanelCollapsed && (
          <div className="planner-side" data-guide-target="planner-proposal">
            <button
              type="button"
              className="planner-side__resize"
              aria-label="Resize meee2 AI panel"
              onPointerDown={handlePanelResizeStart}
            />
            <PlannerProposalPanel
              canvasId={canvasId}
              canvasName={plannerState?.canvas.title ?? canvasName}
              canvasTask={plannerState?.canvas.plannerContext ?? ''}
              proposal={proposal}
              proposalOriginTitle={proposalOriginTitle}
              variant={variant}
              previewGraph={reviewGraph}
              busy={busy}
              error={error}
              access={plannerState?.access ?? null}
              nodeCount={plannerState?.nodes.length ?? 0}
              hasActionableDrift={hasActionableDrift}
              onSubmit={handlePlannerSubmit}
              onUseRecommendedTemplate={handleUseRecommendedTemplate}
              onApproveAndApply={handleApproveAndApply}
              onReject={handleReject}
              draftMessage={plannerDraftMessage}
              clearRevision={clearRevision}
              reviewRequestTick={reviewRequestTick}
              answerOnlyReply={answerOnlyReply}
              layout="left-rail"
              emptyMode={emptyCanvasMode}
              starterSuggestions={starterSuggestions}
              autoFocus={emptyCanvasMode}
            />
            {import.meta.env.VITE_PLANNER_RUNTIME_URL && (
              <PlannerAgentChatPanel
                runtimeBaseUrl={import.meta.env.VITE_PLANNER_RUNTIME_URL as string}
                boardBaseUrl={
                  (import.meta.env.VITE_BOARD_BASE_URL as string | undefined) ??
                  window.location.origin
                }
                canvasId={canvasId}
                harness={
                  (import.meta.env.VITE_PLANNER_HARNESS as 'stub' | 'anthropic' | undefined) ??
                  'stub'
                }
              />
            )}
          </div>
        )}
        <div
          className={[
            'planner-flow',
            renderSceneSpec ? 'planner-flow--scene' : '',
          ].filter(Boolean).join(' ')}
          data-guide-target="planner-flow"
        >
          {flowContent ? (
            flowContent
          ) : renderSceneSpec ? (
            <CanvasSceneLayer
              sceneSpec={renderSceneSpec}
              nodes={plannerState?.nodes ?? []}
              artifacts={plannerState?.artifacts ?? []}
              onOpenNode={handleOpenNodeDetails}
              onSceneAction={handleSceneAction}
            />
          ) : (
            <>
          {/* Canvas runtime Atom 4 — owner-curated monitor grid. Self-gates on
              the canvas.monitor.v2 flag and renders nothing when the canvas has
              no monitorSpec, so legacy canvases are visually unchanged. */}
          {plannerState && plannerState.canvas.id === canvasId && (
            <MonitorGrid
              spec={plannerState.canvas.monitorSpec}
              nodes={plannerState.nodes ?? []}
              states={plannerState.states ?? []}
              artifacts={plannerState.artifacts ?? []}
              viewerId={userProfile?.userId}
            />
          )}
          {/* canvas-spec §7.2 — planner-authored HTML Monitor(s). A monitor is an
              artifact node with artifactSource=canvas-runtime + widget.kind='html';
              its planner-authored HTML renders SANDBOXED in MonitorHtmlFrame and
              consumes the read-only canvasRuntime snapshot. Additive — the card
              MonitorGrid above is unchanged. */}
          {plannerState &&
            plannerState.canvas.id === canvasId &&
            (plannerState.nodes ?? [])
              .filter(
                (n) =>
                  n.widget?.kind === 'html' &&
                  n.widget?.html &&
                  n.artifactSource?.kind === 'canvas-runtime',
              )
              .map((n) => (
                <div key={`monitor-html-${n.id}`} className="planner-monitor-html">
                  <MonitorHtmlFrame
                    title={n.title}
                    html={n.widget!.html!}
                    runtime={plannerState.canvasRuntime}
                  />
                </div>
              ))}
          {/* Canvas runtime Atom 1 — read-only "数据源" rail. Renders nothing
              when the canvas has no dataSources, so legacy canvases are
              visually unchanged. */}
          {plannerState && plannerState.canvas.id === canvasId && (
            <DataSourceRail
              canvasId={canvasId}
              dataSources={plannerState.canvas.dataSources}
            />
          )}
          {(hasSessionActionBanner || mcpWarning) && (
            <div className="planner-banner-stack">
              {hasSessionActionBanner && (
                <div
                  className={`planner-mcp-banner planner-session-action-banner${closedBoundSessions.length > 0 ? ' is-warning' : ' is-ready'}`}
                  role="status"
                >
                  {closedBoundSessions.length > 0
                    ? <AlertTriangle size={16} aria-hidden />
                    : <PlayCircle size={16} aria-hidden />}
                  <div className="planner-mcp-banner__copy">
                    <strong>{sessionActionBannerTitle}</strong>
                    {readySessionActionSummary && <span>Ready: {readySessionActionSummary}</span>}
                    {closedBoundSessionSummary && <span>Closed: {closedBoundSessionSummary}</span>}
                    <em>Recreates missing internal sessions; resumes only when a real provider resume id exists.</em>
                  </div>
                  <div className="planner-session-action-banner__actions">
                    {readySessionPlan.total > 0 && (
                      <button
                        type="button"
                        onClick={handleStartReadySessions}
                        disabled={startingReadySessions}
                      >
                        <PlayCircle size={14} className={startingReadySessions ? 'spin' : undefined} aria-hidden />
                        Start ready
                      </button>
                    )}
                    {closedBoundSessions.length > 0 && (
                      <button
                        type="button"
                        onClick={handleResumeClosedSessions}
                        disabled={resumingClosedSessions}
                      >
                        <RefreshCw size={14} className={resumingClosedSessions ? 'spin' : undefined} aria-hidden />
                        {closedBoundSessionButtonLabel}
                      </button>
                    )}
                  </div>
                </div>
              )}
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
            </div>
          )}
          {/*
            UI-5.3 — canvas-switch loading skeleton.
            Two conditions show the skeleton:
              (a) initial mount, no plannerState yet
              (b) the user just switched canvas — plannerState belongs to the
                  prior canvas, the fetch for `canvasId` is in flight.
            Rendering the skeleton (instead of keeping stale nodes / a bare
            spinner) cuts perceived switch latency: it paints in <16ms after
            the click because no network round-trip is needed, and the
            background placeholder cards prime the user's eye for what's
            about to fill in. Default fixture content first-paint is unchanged
            (~<400ms median against the local board server).
          */}
          {showWorkspacePreview && activeProposal ? (
            <PlannerWorkspacePreview
              graph={reviewGraph}
              proposal={activeProposal}
              onApply={handleApproveAndApply}
              onReject={handleReject}
              busy={busy}
            />
          ) : plannerState && plannerState.canvas.id === canvasId ? (
            <ReactFlow
              nodes={flowNodes}
              edges={graph.edges}
              nodeTypes={nodeTypes}
              edgeTypes={edgeTypes}
              onNodesChange={handleNodesChange}
              onNodeClick={(_, node) => {
                if (isPlannerGraphNode(node)) {
                  setSelectedNodeId(node.data.node.id)
                  setNodeModalOpen(true)
                } else {
                  handleCanvasObjectAction(node.data.object, 'open')
                }
              }}
              onNodeDragStop={(_, node) => handleNodeDragStop(node)}
              onPaneClick={() => {
                setSelectedNodeId(null)
                setNodeModalOpen(false)
              }}
              onMoveEnd={handleViewportMoveEnd}
              nodesDraggable
              fitView={
                !window.matchMedia('(max-width: 720px)').matches
                && !(lockViewportOnSwitch && !!loadPlannerViewport(canvasId))
              }
              minZoom={0.35}
              maxZoom={1.6}
              proOptions={{ hideAttribution: true }}
            >
              <Background color="rgba(168, 165, 155, 0.10)" gap={32} />
              <PlannerOverviewMap nodes={flowNodes} edges={graph.edges} />
              <Controls className="planner-flow__controls" />
            </ReactFlow>
          ) : (
            <PlannerCanvasSkeleton canvasName={canvasName} />
          )}
            </>
          )}
        </div>
        </div>
      )}
      {nodeModalOpen && selectedNode && (
        <NodeInspectorModal
          node={selectedNode}
          canvasId={canvasId}
          canvasEdges={plannerState?.canvas.edges ?? []}
          canvasDataSources={plannerState?.canvas.dataSources ?? []}
          nodeTitleById={Object.fromEntries((plannerState?.nodes ?? []).map((n) => [n.id, n.title]))}
          variant={variant}
          state={plannerState?.states.find((item) => item.nodeId === selectedNode.id) ?? null}
          artifacts={plannerState?.artifacts ?? []}
          /** PR #91 codex P2: open at this artifact id if version chip was clicked. */
          initialSelectedArtifactId={initialInspectorArtifactId}
          doerLabel={
            selectedNode.doerId
              ? teamDirectory.displayNameByUserId[selectedNode.doerId] ?? selectedNode.doerId
              : undefined
          }
          access={plannerState?.access ?? null}
          teamMembers={teamMembers}
          onReplaceSession={handleReplaceNodeSession}
          onOpenSession={handleOpenNodeSession}
          onProposalCreated={handleNodeActionProposal}
          onGraphStateChanged={handleGraphStateChanged}
          onSendToAI={handleSendNodeActionToAI}
          showOwnerInfo={plannerState?.canvas.visibility !== 'private'}
          visibleIOArtifacts={ioArtifactVisibility[selectedNode.id] ?? { inputs: [], outputs: [] }}
          onToggleIOArtifact={handleToggleIOArtifact}
          onClose={() => setNodeModalOpen(false)}
          onOpenSubCanvas={onOpenSubCanvas}
          onAttachDataSource={handleOpenAttachDataSource}
          onRefreshExternalInput={handleRefreshExternalInput}
          onConfigureDialogue={handleConfigureDialogue}
          onRerunNode={handleRerunNode}
          onChangeStatus={handleChangeNodeStatus}
          canChangeStatus={variant !== 'template' && (plannerState?.canEditInternals ?? true)}
          boundSession={
            (boardState?.sessions ?? []).find((s) =>
              sessionMatchesBoundId(s.id, selectedNode?.sessionId ?? ''),
            ) ?? null
          }
        />
      )}
      {attachDataSourceNodeId && (
        <AttachDataSourcePopover
          nodeId={attachDataSourceNodeId}
          onClose={() => setAttachDataSourceNodeId(null)}
          onSubmit={(input) => handleSubmitAttachDataSource(attachDataSourceNodeId, input)}
        />
      )}
      {assignDialogNodeId && assignDialogNode && (
        <AssignNodeDialog
          node={assignDialogNode}
          frozenIOContract={
            // Prefer the frozen contract already attached to the parent canvas
            // (set when a previous assign happened); fall back to deriving a
            // minimal one from the node's schema so the dialog can still preview.
            plannerState?.canvas.frozenIOContract ?? null
          }
          teamMembers={teamMembers}
          excludedUserIds={[
            ...(plannerState?.canvas.ownerId ? [plannerState.canvas.ownerId] : []),
            ...(userProfile?.userId ? [userProfile.userId] : []),
          ]}
          busy={assignBusy}
          errorMessage={assignError}
          onCancel={handleCancelAssign}
          onConfirm={handleConfirmAssign}
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

// ENG-5: answer-only reply body. We don't have a full LLM round-trip on this
// path — we deliberately keep the canvas untouched. The reply explains what
// the heuristic decided and tells the user how to escalate to an actual
// edit if they really did want one. This is a placeholder until a textual
// answer-only LLM call is wired in (TODO: route through `/api/llm/chat`
// without the proposal-generation system prompt).
function answerOnlyClarification(message: string): string {
  return [
    'I read your message as a **question** about the current graph, not a request to change it, so I did not modify the canvas.',
    '',
    `> ${message.replace(/\n/g, ' ')}`,
    '',
    'If you want me to actually edit the graph, re-send with an explicit verb — e.g. "add a review step", "rename node X to …", "split this node into …", "改成 …", "加一个 …".',
  ].join('\n')
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
  // 3-tai cut (2026-05-29): `working` 已从 PlanningNodeStatus 移除;运行中
  // 状态走 NodeAttempt。这里只验 ready / done。
  if (status !== 'ready' && status !== 'done') return null

  const missingInputs = missingRequiredInputs(node)
  if (missingInputs.length > 0) {
    return `Cannot mark "${node.title}" as ${status}: missing required input ${missingInputs.join(', ')}.`
  }

  const needsSession = status === 'done'
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

interface ClosedBoundSession {
  sessionId: string
  nodeIds: string[]
  nodeTitles: string[]
  action: 'resume' | 'recreate'
}

interface ReadySessionPlan {
  create: PlanningNode[]
  resume: ClosedBoundSession[]
  recreate: ClosedBoundSession[]
  total: number
}

function collectReadySessionPlan(
  nodes: PlanningNode[],
  sessions: BoardState['sessions'],
): ReadySessionPlan {
  const create: PlanningNode[] = []
  const resumeBySessionId = new Map<string, ClosedBoundSession>()
  const recreateBySessionId = new Map<string, ClosedBoundSession>()
  for (const node of nodes) {
    if ((node.nodeKind ?? 'step') !== 'step' || node.status !== 'ready') continue
    if (plannerNodeDoesNotNeedLiveSession(node)) continue
    const sessionId = node.sessionId?.trim()
    if (!sessionId) {
      create.push(node)
      continue
    }
    if (sessions.some((session) => sessionMatchesBoundId(session.id, sessionId))) continue
    const action = missingBoundSessionAction(sessionId)
    const target = action === 'resume' ? resumeBySessionId : recreateBySessionId
    const existing = target.get(sessionId) ?? { sessionId, nodeIds: [], nodeTitles: [], action }
    existing.nodeIds.push(node.id)
    existing.nodeTitles.push(node.title)
    target.set(sessionId, existing)
  }
  const resume = [...resumeBySessionId.values()]
  const recreate = [...recreateBySessionId.values()]
  return { create, resume, recreate, total: create.length + resume.length + recreate.length }
}

function collectClosedBoundSessions(
  nodes: PlanningNode[],
  sessions: BoardState['sessions'],
): ClosedBoundSession[] {
  if (nodes.length === 0) return []
  const result = new Map<string, ClosedBoundSession>()
  for (const node of nodes) {
    const sessionId = node.sessionId?.trim()
    if (!sessionId || plannerNodeDoesNotNeedLiveSession(node)) continue
    if (sessions.some((session) => sessionMatchesBoundId(session.id, sessionId))) continue
    const existing = result.get(sessionId) ?? {
      sessionId,
      nodeIds: [],
      nodeTitles: [],
      action: missingBoundSessionAction(sessionId),
    }
    existing.nodeIds.push(node.id)
    existing.nodeTitles.push(node.title)
    result.set(sessionId, existing)
  }
  return [...result.values()]
}

function missingBoundSessionAction(sessionId: string): ClosedBoundSession['action'] {
  return isLikelyProviderResumeSessionId(sessionId) ? 'resume' : 'recreate'
}

function isMeee2InternalSessionId(sessionId: string): boolean {
  const lower = sessionId.trim().toLowerCase()
  return lower.startsWith('claude-internal-') || lower.startsWith('codex-internal-')
}

function isLikelyProviderResumeSessionId(sessionId: string): boolean {
  const trimmed = sessionId.trim()
  if (!trimmed || isMeee2InternalSessionId(trimmed)) return false
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(trimmed)
}

function formatSessionActionSummary(items: Array<[number, string]>): string {
  const parts = items
    .filter(([count]) => count > 0)
    .map(([count, label]) => `${count} ${label}`)
  return parts.length > 0 ? parts.join(' · ') : '0 create'
}

function formatClosedBoundSessionActions(items: ClosedBoundSession[]): string {
  const recreateCount = items.filter((item) => item.action === 'recreate').length
  const resumeCount = items.length - recreateCount
  return formatSessionActionSummary([
    [recreateCount, 'recreate'],
    [resumeCount, 'resume'],
  ])
}

function formatRecoveredSessionToast(items: Array<{ action?: string }>): string {
  const recreated = items.filter((item) => item.action === 'recreate').length
  const resumed = items.length - recreated
  const summary = formatSessionActionSummary([
    [recreated, 'recreated'],
    [resumed, 'resumed'],
  ])
  return `${summary} missing session${items.length === 1 ? '' : 's'}.`
}

function plannerNodeDoesNotNeedLiveSession(node: PlanningNode): boolean {
  if (node.executorType === 'mock') return true
  if (node.schedule?.enabled) return false
  return node.status === 'done' || node.workflowRunState === 'done'
}

// sessionMatchesBoundId 下沉到 plannerGraphAdapter(与 boundSessionLive 共用同一
// 别名匹配规则),改从那里 import — 见文件顶部 import。

function dispatchRunnerForExecutor(executorType: PlanningNode['executorType']): PlannerDispatchRunner {
  if (executorType === 'codex') return 'codex'
  if (executorType === 'claude') return 'claude'
  return loadSpawnProvider()
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
  nextNodes: CanvasFlowNode[],
  currentNodes: CanvasFlowNode[],
): CanvasFlowNode[] {
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
      // 宽高自由调整 — NodeResizer 把用户调整后的尺寸记在 width/height 上。和
      // position 一样要保留:落库还没回来的那个间隙里若来一次无关轮询重建,
      // 不保留就会把正在调整的卡片弹回默认尺寸。
      width: current.width ?? nextNode.width,
      height: current.height ?? nextNode.height,
      // measured 也必须保留:react-flow 见到没有 measured 的节点会重置
      // handleBounds 并按 initialHeight 渲染一帧再重测(adoptUserNodes →
      // parseHandles),节点高度闪一下、连接线端点跟着每次轮询抖一次。内容变化
      // 不靠丢 measured 兜底——ResizeObserver 发现真实尺寸变化会发 dimensions
      // change,经 handleNodesChange/applyNodeChanges 持续写回 measured。
      measured: current.measured,
      // 简略进展 — liveProgress 由 nodeProgressByNodeId 注入到 flowNodes(见上面的
      // 注入 effect),buildPlannerGraph 不产出它。结构重建时从 current 带过来,
      // 否则 plannerState 一变就把卡片上的「最近 AI 回复」清掉、要等下一次轮询才回填。
      data: isPlannerGraphNode(nextNode) && isPlannerGraphNode(current) && current.data.liveProgress != null
        ? { ...nextNode.data, liveProgress: current.data.liveProgress }
        : nextNode.data,
    } as CanvasFlowNode
  })
}

function applyRenderValuesToFlowNodes(
  nodes: PlannerGraphNode[],
  state: PlannerGraphState | null,
): PlannerGraphNode[] {
  const objectByNodeId = new Map<string, CanvasObject>()
  for (const object of state?.renderObjects ?? []) {
    if (object.entityRef?.kind !== 'node') continue
    const nodeId = object.entityRef.nodeId || object.entityRef.id
    if (nodeId) objectByNodeId.set(nodeId, object)
  }
  if (objectByNodeId.size === 0) return nodes
  return nodes
    .filter((node) => objectByNodeId.get(node.data.node.id)?.values?.hidden !== true)
    .map((node) => {
      const values = objectByNodeId.get(node.data.node.id)?.values
      if (!values) return node
      return {
        ...node,
        zIndex: values.pinned ? 1000 : values.zIndex ?? node.zIndex,
        className: [
          node.className,
          values.pinned ? 'is-render-pinned' : '',
          values.collapsed ? 'is-render-collapsed' : '',
        ].filter(Boolean).join(' '),
      }
    })
}

function buildCanvasObjectOverlay(input: {
  state: PlannerGraphState | null
  baseNodes: PlannerGraphNode[]
  onAction: (object: CanvasObject, action: CanvasObjectAction) => void
  canEdit: boolean
}): { nodes: CanvasObjectFlowNode[]; edges: CanvasFlowEdge[] } {
  const state = input.state
  if (!state) return { nodes: [], edges: [] }
  const baseByObjectId = new Map<string, PlannerGraphNode>()
  const flowNodeIds = new Set<string>()
  for (const node of input.baseNodes) {
    baseByObjectId.set(`node:${node.data.node.id}`, node)
    flowNodeIds.add(node.id)
  }
  const artifactsById = new Map((state.artifacts ?? []).map((artifact) => [artifact.id, artifact]))
  const dataSourcesById = new Map((state.canvas.dataSources ?? []).map((source) => [source.id, source]))
  const objects = (state.renderObjects ?? []).filter((object) =>
    object.entityRef?.kind !== 'node'
    && object.entityRef?.kind !== 'session'
    && object.values?.hidden !== true
    && object.renderOnly?.kind !== 'background',
  )
  const nodes = objects.map((object, index): CanvasObjectFlowNode => {
    const values = object.values ?? {}
    const position = positionForCanvasObject(object, index, baseByObjectId)
    const size = defaultCanvasObjectSize(object)
    const artifact = object.entityRef?.kind === 'artifact' ? artifactsById.get(object.entityRef.id) : undefined
    const dataSource = object.entityRef?.kind === 'dataSource' ? dataSourcesById.get(object.entityRef.id) : undefined
    const collapsed = values.collapsed === true
    return {
      id: object.id,
      type: 'canvasObject',
      position,
      width: typeof values.width === 'number' ? values.width : size.width,
      height: typeof values.height === 'number' ? values.height : (collapsed ? 72 : size.height),
      zIndex: values.pinned ? 1000 : values.zIndex ?? 0,
      data: {
        object,
        subtitle: subtitleForCanvasObject(object),
        detail: detailForCanvasObject(object, artifact, dataSource),
        badge: badgeForCanvasObject(object),
        collapsed,
        pinned: values.pinned === true,
        canEdit: input.canEdit,
        onAction: input.onAction,
      },
    }
  })
  for (const node of nodes) flowNodeIds.add(node.id)
  const edges = buildRenderRelationEdges(state.renderRelations ?? [], flowNodeIds)
  return { nodes, edges }
}

function buildRenderRelationEdges(
  relations: CanvasRelation[],
  flowNodeIds: Set<string>,
): CanvasFlowEdge[] {
  const result: CanvasFlowEdge[] = []
  const seen = new Set<string>()
  for (const relation of relations) {
    if (relation.values?.visible === false) continue
    const source = flowNodeIdForObjectId(relation.source.objectId)
    const target = flowNodeIdForObjectId(relation.target.objectId)
    if (!flowNodeIds.has(source) || !flowNodeIds.has(target)) continue
    if (relation.kind === 'dependency' && !source.includes(':') && !target.includes(':')) continue
    const id = `render-relation:${relation.id}`
    const pairKey = `${source}->${target}:${relation.kind}`
    if (seen.has(pairKey)) continue
    seen.add(pairKey)
    result.push({
      id,
      source,
      target,
      type: 'transformInsert',
      animated: relation.kind === 'dataflow',
      markerEnd: {
        type: MarkerType.ArrowClosed,
        color: 'rgba(178, 174, 163, 0.52)',
        width: 16,
        height: 16,
      },
      data: {
        preview: false,
        perception: relation.kind === 'dataflow' ? 'flow' : 'neutral',
        suppressInsert: true,
      },
      className: [
        'planner-flow__edge',
        'planner-flow__edge--render',
        `planner-flow__edge--render-${cssClassToken(relation.kind)}`,
      ].join(' '),
      label: relation.values?.label,
    })
  }
  return result
}

function flowNodeIdForObjectId(objectId: string): string {
  return objectId.startsWith('node:') ? objectId.slice('node:'.length) : objectId
}

function positionForCanvasObject(
  object: CanvasObject,
  index: number,
  baseByObjectId: Map<string, PlannerGraphNode>,
): { x: number; y: number } {
  const values = object.values ?? {}
  if (typeof values.x === 'number' && typeof values.y === 'number') {
    return { x: values.x, y: values.y }
  }
  const ownerNodeId = object.entityRef?.nodeId
  const owner = ownerNodeId ? baseByObjectId.get(`node:${ownerNodeId}`) : undefined
  if (owner) {
    const lane = index % 3
    const kind = object.entityRef?.kind
    if (kind === 'session') return { x: owner.position.x, y: owner.position.y - 96 }
    if (kind === 'subCanvas') return { x: owner.position.x, y: owner.position.y + (owner.height ?? 220) + 90 }
    return { x: owner.position.x + (owner.width ?? 320) + 96, y: owner.position.y + lane * 132 }
  }
  if (object.entityRef?.kind === 'dataSource') {
    return { x: -420, y: index * 132 }
  }
  return { x: 80 + (index % 4) * 260, y: 80 + Math.floor(index / 4) * 160 }
}

function defaultCanvasObjectSize(object: CanvasObject): { width: number; height: number } {
  switch (object.entityRef?.kind ?? object.renderOnly?.kind) {
    case 'artifact': return { width: 300, height: 132 }
    case 'session': return { width: 220, height: 104 }
    case 'dataSource': return { width: 280, height: 128 }
    case 'subCanvas': return { width: 300, height: 132 }
    case 'label': return { width: 220, height: 72 }
    case 'asset': return { width: 260, height: 140 }
    case 'region':
    case 'container': return { width: 360, height: 220 }
    default: return { width: 260, height: 116 }
  }
}

function subtitleForCanvasObject(object: CanvasObject): string {
  const kind = object.entityRef?.kind
  if (kind === 'artifact') return object.entityRef?.reference ?? 'Artifact'
  if (kind === 'session') return object.entityRef?.nodeId ? `Session for ${object.entityRef.nodeId}` : 'Session'
  if (kind === 'dataSource') return 'Data source'
  if (kind === 'subCanvas') return 'Sub-canvas'
  if (kind === 'integrationEntity') return 'Integration'
  return object.renderOnly?.kind ?? 'Render object'
}

function detailForCanvasObject(
  object: CanvasObject,
  artifact?: PlannerArtifact,
  dataSource?: NonNullable<PlannerGraphState['canvas']['dataSources']>[number],
): string | null {
  if (artifact) return `${artifact.kind} · ${artifact.status || 'attached'}`
  if (dataSource) return `${dataSource.kind} · v${dataSource.currentVersion}`
  if (object.entityRef?.reference) return object.entityRef.reference
  return null
}

function badgeForCanvasObject(object: CanvasObject): string {
  return object.entityRef?.kind ?? object.renderOnly?.kind ?? object.renderer
}

function iconForCanvasObject(object: CanvasObject) {
  switch (object.entityRef?.kind ?? object.renderOnly?.kind) {
    case 'artifact': return FileText
    case 'session': return UserCircle
    case 'dataSource': return Database
    case 'subCanvas':
    case 'container':
    case 'region': return Layers
    default: return FileText
  }
}

function cssClassToken(value: string): string {
  return value.replace(/([a-z])([A-Z])/g, '$1-$2').replace(/[^a-zA-Z0-9_-]+/g, '-').toLowerCase()
}

function isPlannerGraphNode(node: CanvasFlowNode): node is PlannerGraphNode {
  return node.type === 'plannerNode'
}

function applyRenderObjectValuePatch(
  state: PlannerGraphState,
  objectId: string,
  patch: CanvasRenderObjectValues,
): PlannerGraphState {
  const mergeValues = (current: CanvasRenderObjectValues | null | undefined): CanvasRenderObjectValues => ({
    ...(current ?? {}),
    ...patch,
  })
  const nextProfile = state.renderProfile
    ? {
      ...state.renderProfile,
      values: {
        ...state.renderProfile.values,
        objects: {
          ...(state.renderProfile.values.objects ?? {}),
          [objectId]: mergeValues(state.renderProfile.values.objects?.[objectId]),
        },
      },
    }
    : state.renderProfile
  return {
    ...state,
    renderProfile: nextProfile,
    renderObjects: (state.renderObjects ?? []).map((object) => object.id === objectId
      ? { ...object, values: mergeValues(object.values) }
      : object),
  }
}

function nodesWithRenderValues(state: PlannerGraphState | null): PlanningNode[] {
  const nodes = state?.nodes ?? []
  const objects = state?.renderObjects ?? []
  if (nodes.length === 0 || objects.length === 0) return nodes
  const valuesByNodeId = new Map<string, { x?: number | null; y?: number | null; width?: number | null; height?: number | null }>()
  for (const object of objects) {
    if (object.entityRef?.kind !== 'node') continue
    const nodeId = object.entityRef.nodeId || object.entityRef.id
    if (!nodeId || !object.values) continue
    valuesByNodeId.set(nodeId, object.values)
  }
  if (valuesByNodeId.size === 0) return nodes
  return nodes.map((node) => {
    const values = valuesByNodeId.get(node.id)
    if (!values) return node
    const x = typeof values.x === 'number' ? values.x : node.layout?.x
    const y = typeof values.y === 'number' ? values.y : node.layout?.y
    if (typeof x !== 'number' || typeof y !== 'number') return node
    return {
      ...node,
      layout: {
        x,
        y,
        width: typeof values.width === 'number' ? values.width : (node.layout?.width ?? null),
        height: typeof values.height === 'number' ? values.height : (node.layout?.height ?? null),
      },
    }
  })
}

function sceneSpecForRender(state: PlannerGraphState | null): CanvasSceneSpec | null {
  if (!state) return null
  if (state.canvas.sceneSpec) return state.canvas.sceneSpec
  if (state.renderProfile?.logic.layout !== 'spatial') return null
  for (const object of state.renderObjects ?? []) {
    if (object.renderOnly?.kind !== 'background') continue
    const metadata = object.metadata
    if (!isRecord(metadata)) continue
    const sceneSpec = metadata.sceneSpec
    if (isCanvasSceneSpec(sceneSpec)) return sceneSpec
  }
  return null
}

function isCanvasSceneSpec(value: unknown): value is CanvasSceneSpec {
  return isRecord(value) && (value.kind === 'travel-squad' || value.kind === 'poker-table')
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

// 简略进展蒸馏 —— 从实时会话 DTO 里挑出卡片放大后要露的最少信息。优先使用
// session recap / summary,避免把最近一条原始 assistant 消息(常带 markdown
// 和完成报告全文)贴到节点卡片上；没有 summary 时才短 fallback 到 assistant tail。
function summarizeSessionProgress(session: Session): NodeLiveProgress {
  const recap = cleanProgressText(session.latestRecap?.content)
  if (recap) {
    return { lastReply: { role: 'summary', text: truncateMessageText(recap, 160) } }
  }
  const messages = session.recentMessages ?? []
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    const m = messages[i]
    const text = cleanProgressText(m.text)
    if (m.role === 'assistant' && text) {
      return { lastReply: { role: m.role, text: truncateMessageText(text, 160) } }
    }
  }
  return { lastReply: null }
}

function cleanProgressText(value: string | null | undefined): string | null {
  const text = value
    ?.replace(/```[\s\S]*?```/g, ' ')
    .replace(/[#*_`>[\]()]/g, '')
    .replace(/\s+/g, ' ')
    .trim()
  return text || null
}

// 浅比较两份简略进展,决定注入 effect 要不要给该节点换新 data 对象(换了才重渲染)。
function liveProgressEqual(a: NodeLiveProgress | null, b: NodeLiveProgress | null): boolean {
  if (a === b) return true
  if (!a || !b) return false
  const ra = a.lastReply
  const rb = b.lastReply
  if (ra === rb) return true
  if (!ra || !rb) return false
  return ra.role === rb.role && ra.text === rb.text
}

async function pollForBoundNodeSession(
  canvasId: string,
  nodeId: string,
  existingSessionIds: Set<string>,
  onState: (state: PlannerGraphState) => void,
  onDone: () => void,
  onBound?: (sessionId: string) => void,
) {
  let sawNewSession = false
  let notifiedSessionId: string | null = null
  const notifyBound = (sessionId: string | null | undefined) => {
    if (!sessionId || notifiedSessionId === sessionId) return
    notifiedSessionId = sessionId
    onBound?.(sessionId)
  }
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
            const boundSessionId = bound.nodes.find((item) => item.id === nodeId)?.sessionId
            if (boundSessionId) {
              notifyBound(boundSessionId)
              return
            }
          } catch {
            // The backend spawn-intent matcher may still bind it on the next state refresh.
          }
        }
        const state = await fetchPlannerGraphState(canvasId)
        onState(state)
        const node = state.nodes.find((item) => item.id === nodeId)
        if (node?.sessionId) {
          notifyBound(node.sessionId)
          return
        }
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

async function pollForReadyNodeSessions(
  canvasId: string,
  nodeIds: string[],
  onState: (state: PlannerGraphState) => void,
  onDone: () => void,
) {
  const pending = new Set(nodeIds)
  try {
    for (let attempt = 0; attempt < 36 && pending.size > 0; attempt += 1) {
      await delay(attempt < 4 ? 900 : 1800)
      try {
        await fetchState()
        const state = await fetchPlannerGraphState(canvasId)
        onState(state)
        for (const nodeId of [...pending]) {
          const node = state.nodes.find((item) => item.id === nodeId)
          if (!node) {
            pending.delete(nodeId)
            continue
          }
          if (node.sessionId?.trim()) {
            pending.delete(nodeId)
            continue
          }
          if (node.workflowRunState !== 'dispatched' && node.workflowRunState !== 'running') {
            pending.delete(nodeId)
          }
        }
      } catch {
        // Session discovery is eventually consistent; keep polling.
      }
    }
    if (pending.size > 0) {
      const state = await fetchPlannerGraphState(canvasId)
      onState(state)
    }
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

/**
 * UI-5.3 — canvas-switch loading skeleton.
 *
 * Pure presentational placeholder: a faint background grid plus a handful of
 * shimmering node-shaped cards. Rendered immediately (no async, no fetch) so
 * the first paint after a canvas-switch click is the skeleton, not blank
 * dead time. Once `plannerState.canvas.id === canvasId` we swap to the real
 * ReactFlow surface.
 *
 * Targeting `<= 16ms` skeleton paint and `<= 400ms` median content first
 * paint on the default local-board fixture (see UI-5.3 acceptance).
 */
function PlannerCanvasSkeleton({ canvasName }: { canvasName?: string }) {
  // Hand-tuned positions / sizes mimic a typical planner topology (root +
  // a column of children) so the user immediately recognizes "the same kind
  // of canvas is loading", not a generic spinner.
  const cards: Array<{
    top: string
    left: string
    width: number
    height: number
    delayMs: number
  }> = [
    { top: '22%', left: '18%', width: 220, height: 96, delayMs: 0 },
    { top: '22%', left: '52%', width: 220, height: 96, delayMs: 120 },
    { top: '52%', left: '32%', width: 240, height: 110, delayMs: 60 },
    { top: '52%', left: '66%', width: 220, height: 96, delayMs: 180 },
    { top: '78%', left: '50%', width: 260, height: 110, delayMs: 240 },
  ]
  return (
    <div
      className="planner-canvas-skeleton"
      role="status"
      aria-live="polite"
      aria-label={canvasName ? `Loading ${canvasName}` : 'Loading canvas'}
    >
      <div className="planner-canvas-skeleton__grid" aria-hidden />
      {cards.map((card, index) => (
        <div
          key={index}
          className="planner-canvas-skeleton__card"
          style={{
            top: card.top,
            left: card.left,
            width: card.width,
            height: card.height,
            animationDelay: `${card.delayMs}ms`,
          }}
          aria-hidden
        />
      ))}
      <span className="planner-canvas-skeleton__label">
        {canvasName ? `Loading ${canvasName}…` : 'Loading canvas…'}
      </span>
    </div>
  )
}

function PlannerWorkspacePreview({
  graph,
  proposal,
  onApply,
  onReject,
  busy,
}: {
  graph: { nodes: PlannerGraphNode[]; edges: PlannerGraphEdge[] }
  proposal: PlanProposal
  onApply?: () => void
  onReject?: () => void
  busy?: boolean
}) {
  return (
    <div className="planner-workspace-preview" aria-label="Proposal preview" data-guide-target="planner-workspace-preview">
      <div className="planner-workspace-preview__notice" role="status">
        <span>Preview only</span>
        <strong>{proposal.summary || 'meee2 AI proposed canvas changes'}</strong>
        <em>Review and apply from the modal before these nodes become the real canvas.</em>
      </div>
      {/* UI-simplification — user 反馈:preview 模式 canvas 是只读的(elementsSelectable=false)
       *  会卡死 —— 没明显的退出入口。把 Apply / Reject 显式放在画板右上角。 */}
      {(onApply || onReject) && (
        <div className="planner-workspace-preview__actions" role="group" aria-label="Preview controls">
          {onReject && (
            <button
              type="button"
              className="planner-workspace-preview__btn planner-workspace-preview__btn--reject"
              onClick={onReject}
              disabled={busy}
              aria-busy={busy}
              title="Reject this proposal — revert to previous canvas"
            >
              {busy ? '…' : '✕ Reject'}
            </button>
          )}
          {onApply && (
            <button
              type="button"
              className="planner-workspace-preview__btn planner-workspace-preview__btn--apply"
              onClick={onApply}
              disabled={busy}
              aria-busy={busy}
              title="Approve & apply this proposal — make these changes real"
            >
              {busy ? 'Applying…' : '✓ Apply'}
            </button>
          )}
        </div>
      )}
      <ReactFlow
        nodes={graph.nodes}
        edges={graph.edges}
        nodeTypes={nodeTypes}
        edgeTypes={edgeTypes}
        nodesDraggable={false}
        nodesConnectable={false}
        elementsSelectable={false}
        panOnDrag
        zoomOnScroll
        fitView
        minZoom={0.25}
        maxZoom={1.4}
        proOptions={{ hideAttribution: true }}
      >
        <Background color="rgba(168, 165, 155, 0.10)" gap={32} />
      </ReactFlow>
    </div>
  )
}

function buildPokerSceneActionPrompt(
  scene: CanvasSceneSpec,
  artifacts: PlannerArtifact[],
  action: CanvasSceneAction,
  node: PlanningNode,
): string {
  if (!action.id.startsWith('ask-')) return ''
  const playerId = action.id.replace(/^ask-/, '').toLowerCase()
  if (!playerId || playerId === 'dealer') return ''
  const state = resolveCanvasSceneState(scene, artifacts)
  const players = Array.isArray(state.players) ? state.players : []
  const actor = players
    .map((item) => item && typeof item === 'object' && !Array.isArray(item) ? item as Record<string, unknown> : null)
    .find((item) => String(item?.id ?? '').toLowerCase() === playerId)
  if (!actor) return action.prompt?.trim() ?? ''
  const publicPlayers = players
    .map((item) => item && typeof item === 'object' && !Array.isArray(item) ? item as Record<string, unknown> : null)
    .filter(Boolean)
    .map((item) => ({
      id: String(item?.id ?? ''),
      name: String(item?.name ?? ''),
      stack: item?.stack ?? null,
      status: String(item?.status ?? ''),
      seat: String(item?.seat ?? ''),
      style: String(item?.style ?? ''),
      holeCards: String(item?.id ?? '').toLowerCase() === playerId ? item?.holeCards ?? [] : ['hidden', 'hidden'],
    }))
  const pack = {
    nodeContract: {
      nodeId: node.id,
      title: node.title,
      goal: node.schema.goal,
      output: `${playerId}-action.json`,
    },
    roleSlice: {
      playerId,
      phase: state.phase ?? 'Pre-flop',
      pot: state.pot ?? 0,
      nextActor: state.nextActor ?? state.nextAction ?? '',
      communityCards: state.communityCards ?? [],
      legalActions: state.legalActions ?? ['fold', 'call', 'raise'],
      players: publicPlayers,
      recentActionLog: Array.isArray(state.actionLog) ? state.actionLog.slice(-8) : [],
    },
    outputSchema: {
      artifact: `${playerId}-action.json`,
      playerId,
      action: 'fold | call | raise | check',
      amount: 'number | null',
      rationale: 'string',
    },
  }
  return [
    action.prompt?.trim() || `现在轮到 ${playerId} 行动。`,
    '',
    'Use this deterministic Poker Context Pack. Do not assume hidden cards outside your role slice.',
    JSON.stringify(pack, null, 2),
  ].join('\n')
}

function dispatchNextPokerAutoNode(
  graph: PlannerGraphState,
  createSession: (nodeId: string, runner: PlannerDispatchRunner, initialPrompt?: string) => void,
  options: { force?: boolean } = {},
) {
  const scene = graph.canvas.sceneSpec
  if (!scene || scene.kind !== 'poker-table') return
  const state = resolveCanvasSceneState(scene, graph.artifacts ?? [])
  const setup = state.setup && typeof state.setup === 'object' && !Array.isArray(state.setup)
    ? state.setup as Record<string, unknown>
    : {}
  if (setup.autoRun === false && !options.force) return
  const nextActor = String(state.nextActor ?? state.nextAction ?? '').trim().toLowerCase()
  if (!nextActor || nextActor === 'setup') return
  const action = (scene.actions ?? []).find((item) => item.id === `ask-${nextActor}`)
  if (!action) return
  const node = (graph.nodes ?? []).find((item) => item.id === action.nodeId)
  if (!node || node.executionMode === 'human' || node.executorType === 'human') return
  if (node.status !== 'ready') return
  createSession(node.id, dispatchRunnerForExecutor(node.executorType), buildPokerSceneActionPrompt(scene, graph.artifacts ?? [], action, node))
}

function pokerAutoDispatchRequest(graph: PlannerGraphState): { key: string } | null {
  const scene = graph.canvas.sceneSpec
  if (!scene || scene.kind !== 'poker-table') return null
  const state = resolveCanvasSceneState(scene, graph.artifacts ?? [])
  const setup = state.setup && typeof state.setup === 'object' && !Array.isArray(state.setup)
    ? state.setup as Record<string, unknown>
    : {}
  if (setup.autoRun === false) return null
  const nextActor = String(state.nextActor ?? state.nextAction ?? '').trim().toLowerCase()
  if (!['ada', 'bruno', 'mina'].includes(nextActor)) return null
  const action = (scene.actions ?? []).find((item) => item.id === `ask-${nextActor}`)
  if (!action) return null
  const node = (graph.nodes ?? []).find((item) => item.id === action.nodeId)
  if (!node || node.executionMode === 'human' || node.executorType === 'human' || node.status !== 'ready') return null
  const dealerNodeId = scene.orchestration?.stateNodeId
    ?? (scene.artifactBindings ?? []).find((item) => item.id === 'game-state')?.nodeId
    ?? ''
  const gameStateArtifact = latestArtifactForSlot(graph.artifacts ?? [], dealerNodeId, scene.orchestration?.stateReference ?? 'game-state.json')
  return {
    key: [
      graph.canvas.id,
      nextActor,
      node.id,
      gameStateArtifact?.id ?? 'no-game-state',
    ].join(':'),
  }
}

function pokerAutoStepRequest(graph: PlannerGraphState): { key: string } | null {
  const scene = graph.canvas.sceneSpec
  if (!scene || scene.kind !== 'poker-table') return null
  const state = resolveCanvasSceneState(scene, graph.artifacts ?? [])
  const setup = state.setup && typeof state.setup === 'object' && !Array.isArray(state.setup)
    ? state.setup as Record<string, unknown>
    : {}
  if (setup.autoRun === false) return null
  const nextActor = String(state.nextActor ?? state.nextAction ?? '').trim().toLowerCase()
  if (!['ada', 'bruno', 'mina'].includes(nextActor)) return null
  const action = (scene.actions ?? []).find((item) => item.id === `ask-${nextActor}`)
  if (!action) return null
  const node = (graph.nodes ?? []).find((item) => item.id === action.nodeId)
  if (!node || node.status !== 'done') return null
  const actionArtifact = latestArtifactForSlot(graph.artifacts ?? [], node.id, `${nextActor}-action.json`)
  if (!actionArtifact) return null
  const dealerNodeId = scene.orchestration?.stateNodeId
    ?? (scene.artifactBindings ?? []).find((item) => item.id === 'game-state')?.nodeId
    ?? ''
  const gameStateArtifact = latestArtifactForSlot(graph.artifacts ?? [], dealerNodeId, scene.orchestration?.stateReference ?? 'game-state.json')
  return {
    key: [
      graph.canvas.id,
      nextActor,
      node.id,
      actionArtifact.id,
      gameStateArtifact?.id ?? 'no-game-state',
    ].join(':'),
  }
}

function latestArtifactForSlot(
  artifacts: PlannerArtifact[],
  nodeId: string,
  reference: string,
): PlannerArtifact | null {
  return artifacts
    .filter((artifact) => artifact.nodeId === nodeId && artifact.reference === reference)
    .sort((a, b) => String(a.createdAt).localeCompare(String(b.createdAt)))
    .slice(-1)[0] ?? null
}

function isPlannerCanvasEmptyForOnboarding(state: PlannerCanvasState): boolean {
  const activeProposals = (state.proposals ?? []).filter((proposal) =>
    proposal.status === 'pending' || proposal.status === 'approved',
  )
  return (
    (state.nodes ?? []).length === 0
    && (state.artifacts ?? []).length === 0
    && activeProposals.length === 0
  )
}

function formatPlannerProposalError(error: unknown, fallback: string): string {
  const message = error instanceof Error ? error.message : String(error || '')
  if (/proposal output is not valid JSON/i.test(message)) {
    const prefix = /draft canvas/i.test(fallback)
      ? 'Draft canvas failed'
      : fallback
    return `${prefix}: meee2 AI returned an invalid proposal format. Your canvas was not changed.`
  }
  return message || fallback
}

function buildStarterSuggestions(
  canvasName: string,
  canvasTask: string | null | undefined,
  templates: CanvasTemplate[],
  t: ReturnType<typeof useI18n>['t'],
) {
  const target = readableCanvasStarterTarget(canvasName, canvasTask, t)
  return templates.map((template) => {
    const nodeTitles = template.defaultNodes.map((node) => node.title)
    return {
      id: `official-${template.id}`,
      label: template.name,
      value: t('planner.officialTemplateValue', {
        target,
        name: template.name,
        description: template.description,
        nodes: nodeTitles.length > 0 ? nodeTitles.join(', ') : t('planner.noStarterNodes'),
      }),
      description: template.description,
      preview: nodeTitles.slice(0, 4),
      nodeCount: nodeTitles.length,
    }
  })
}

function readableCanvasStarterTarget(
  canvasName: string,
  canvasTask: string | null | undefined,
  t: ReturnType<typeof useI18n>['t'],
): string {
  const title = canvasName.trim()
  const context = canvasTask?.trim() ?? ''
  if (context && !context.startsWith('canvas:')) return context
  if (title && !/^(untitled|new canvas|default canvas|my|personal canvas)$/i.test(title)) return title
  return t('planner.thisCanvas')
}
