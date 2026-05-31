import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react'
import { CanvasToolbar } from './components/CanvasToolbar'
import { PlannerGraph } from './components/planner/PlannerGraph'
import { WorkspaceMonitor } from './components/planner/WorkspaceMonitor'
import { ArtifactsView } from './components/ArtifactsView'
import { NativeSessionsWorkspaceHost } from './components/NativeSessionsWorkspaceHost'
import { IntegrationsView } from './components/IntegrationsView'
import { TemplatesView } from './components/TemplatesView'
import { TeamView } from './components/TeamView'
import { SettingsView } from './components/SettingsView'
import { FirstRunOnboarding } from './components/FirstRunOnboarding'
import { WorkspaceRail, type WorkspaceMode } from './components/WorkspaceRail'
import { AgentRuntimeSetupModal } from './components/AgentRuntimeSetupModal'
import { CommandPalette } from './components/CommandPalette'
import { GuideOverlay } from './components/GuideOverlay'
import { useI18n } from './lib/i18n'
import {
  boardTargetFromPlannerItem,
  requestBoardTarget,
  type BoardOpenTarget,
} from './lib/boardTarget'
import { requestBoardGuide, requestPlannerNodeSelection } from './lib/guide'
import { resolveMonitorItemOpenTarget } from './lib/workspaceNavigation'
import { useBoardState } from './useBoardState'
import { useCanvasMonitor } from './lib/canvasMonitor'
import type {
  CanvasList,
  CanvasKind,
  CanvasScope,
  Meee2AgentRuntimeStatus,
  PlannerGraphState,
  PlannerMonitorItem,
  ReadinessReport,
  Session,
  SpawnProvider,
} from './types'
import {
  WORKING_STATUSES,
  RESTING_STATUSES,
  ensureNotificationPermission,
  indexSessions,
  loadNotificationToggles,
  runSessionTransitionNotifications,
} from './notifications'
import type {
  CanvasPersistence,
  LayoutMap,
  PersistedViewport,
} from '@meee1/board-core'
import { HttpCanvasPersistence } from '@meee1/board-persistence-http'
import {
	  applyCanvasTemplate,
	  createCanvas,
	  createTemplateEditDraft,
	  createTemplateFromCanvas,
	  clearPlannerCanvasContent,
	  deleteCanvas,
  fetchCanvases,
  fetchMeee2AgentRuntimeStatus,
  fetchReadiness,
  fetchUserProfile,
  importClaudeWorkflow,
  installMeee2AgentRuntime,
	  repairReadiness,
	  replaceTemplateFromCanvas,
	  uploadClaudeWorkflow,
	  updateCanvas,
	  updateTemplateMetadata,
	  type UserProfile,
	  type TemplateMetadataInput,
	} from './api'

declare global {
  interface Window {
    __meee2PendingSessionsWorkspace?: { sessionId?: string; surfaceId?: string } | null
  }
}

interface HydratedState {
  canvasId: string
  sessionLayout: LayoutMap
  channelLayout: LayoutMap
  viewport: PersistedViewport | null
  userElements: any[]
  dismissed: Set<string>
  unreadSids: Set<string>
}

const FALLBACK_CANVAS_ID = 'personal-default'
const WORKSPACE_RAIL_COLLAPSED_KEY = 'meee2.workspaceRail.collapsed'
const FIRST_RUN_ONBOARDING_COMPLETED_KEY = 'meee2.onboarding.completed.v1'
const BOARD_DEV_MODE = readBoardDevMode()
// Minimum loading-overlay duration when an uncached canvas is hydrated.
// Previously 3000ms — that made every fresh canvas switch feel sluggish even
// when the real fetch returned in <100ms. 250ms is enough to smooth flicker
// for sub-perceptual loads without an artificial wait.
const MIN_CANVAS_LOADING_MS = import.meta.env.VITE_PLANNER_DEMO === '1' ? 0 : 250

async function loadCanvasHydratedState(
  canvasId: string,
  persistence: CanvasPersistence = new HttpCanvasPersistence(canvasId),
): Promise<HydratedState> {
  const [
    sessionLayout,
    channelLayout,
    viewport,
    userElements,
    dismissed,
    unreadSids,
  ] = await Promise.all([
    persistence.loadSessionLayout(),
    persistence.loadChannelLayout(),
    persistence.loadViewport(),
    persistence.loadUserElements(),
    persistence.loadDismissed(),
    persistence.loadUnreadSids(),
  ])
  return {
    canvasId,
    sessionLayout,
    channelLayout,
    viewport,
    userElements,
    dismissed,
    unreadSids,
  }
}

function emptyHydratedState(canvasId: string): HydratedState {
  return {
    canvasId,
    sessionLayout: {},
    channelLayout: {},
    viewport: null,
    userElements: [],
    dismissed: new Set(),
    unreadSids: new Set(),
  }
}

function fallbackCanvasList(): CanvasList {
  return {
    activeCanvasId: FALLBACK_CANVAS_ID,
    defaultCanvasIds: [FALLBACK_CANVAS_ID],
    memberships: [],
    canvases: [{
      id: FALLBACK_CANVAS_ID,
      name: 'Monitor',
      scope: 'personal',
      kind: 'monitor',
      isDefault: true,
      workspacePath: '',
      ownerUserId: 'local-user',
      teamId: null,
    }],
  }
}

function canvasKind(canvas: CanvasList['canvases'][number] | null | undefined): CanvasKind {
  if (canvas?.kind === 'template') return 'template'
  if (canvas?.kind === 'monitor') return 'monitor'
  return 'board'
}

function isWorkspaceCanvas(canvas: CanvasList['canvases'][number] | null | undefined): boolean {
  return canvasKind(canvas) !== 'template'
}

function canvasListSignature(list: CanvasList): string {
  return JSON.stringify({
    activeCanvasId: list.activeCanvasId,
    defaultCanvasIds: [...list.defaultCanvasIds].sort(),
    canvases: [...list.canvases]
      .sort((a, b) => a.id.localeCompare(b.id))
      .map((canvas) => ({
        id: canvas.id,
        name: canvas.name,
        scope: canvas.scope,
        kind: canvasKind(canvas),
        isDefault: canvas.isDefault,
        workspacePath: canvas.workspacePath,
        parentCanvasId: canvas.parentCanvasId ?? null,
        parentNodeId: canvas.parentNodeId ?? null,
        ownerUserId: canvas.ownerUserId ?? null,
        teamId: canvas.teamId ?? null,
        remoteId: canvas.remoteId ?? null,
        remoteVersion: canvas.remoteVersion ?? null,
        syncStatus: canvas.syncStatus ?? null,
        dirtySince: canvas.dirtySince ?? null,
        lastSyncedAt: canvas.lastSyncedAt ?? null,
        lastRemoteUpdatedAt: canvas.lastRemoteUpdatedAt ?? null,
      })),
    memberships: [...list.memberships]
      .sort((a, b) => `${a.canvasId}:${a.sessionId}`.localeCompare(`${b.canvasId}:${b.sessionId}`))
      .map((membership) => ({
        canvasId: membership.canvasId,
        sessionId: membership.sessionId,
        visible: membership.visible,
        layout: membership.layout ?? null,
      })),
  })
}

// -- toast context ---------------------------------------------------------

interface Toast {
  id: number
  kind: 'info' | 'error' | 'success'
  text: string
}
interface ToastCtx {
  push: (kind: Toast['kind'], text: string) => void
}
const ToastContext = createContext<ToastCtx>({ push: () => {} })
export const useToast = () => useContext(ToastContext)

export default function App() {
  const { t } = useI18n()
  const [canvasList, setCanvasList] = useState<CanvasList | null>(null)
  const canvasListSignatureRef = useRef('')
  const applyCanvasList = useCallback((list: CanvasList) => {
    const nextSignature = canvasListSignature(list)
    if (nextSignature !== canvasListSignatureRef.current) {
      canvasListSignatureRef.current = nextSignature
      setCanvasList(list)
    }
    return list
  }, [])
  const activeCanvasId = canvasList?.activeCanvasId ?? FALLBACK_CANVAS_ID
  // 整个应用的持久化层。CanvasPersistence interface 来自 @meee1/board-core；
  // meee2 桌面端通过本地 HTTP API 写入 BoardLayoutStore。
  const persistence = useMemo<CanvasPersistence>(
    () => new HttpCanvasPersistence(activeCanvasId),
    [activeCanvasId],
  )
  // 启动时一次性把所有 storage slot 拉好再 mount Board。
  // 历史上 Board 在 useRef 初值里同步 loadXxx() 拿 localStorage —— 现在改成
  // async 接口后必须先 hydrate 完才能渲染（否则 useRef 拿不到值）。
  const [hydrated, setHydrated] = useState<HydratedState | null>(null)
  const canvasSceneCacheRef = useRef<Record<string, HydratedState>>({})
  const [canvasLoading, setCanvasLoading] = useState(true)
  useEffect(() => {
    let cancelled = false
    let retryTimer: number | null = null
    const load = (allowFallback: boolean) => {
      fetchCanvases()
        .then((list) => { if (!cancelled) applyCanvasList(list) })
        .catch((err) => {
          console.warn('[App] fetchCanvases failed:', (err as Error).message)
          if (cancelled) return
          if (allowFallback) {
            setCanvasList((current) => current ?? fallbackCanvasList())
            retryTimer = window.setTimeout(() => load(false), 1500)
          }
        })
    }
    load(true)
    return () => {
      cancelled = true
      if (retryTimer !== null) window.clearTimeout(retryTimer)
    }
  }, [applyCanvasList])

  const refreshCanvases = useCallback(() => {
    return fetchCanvases()
      .then((list) => {
        applyCanvasList(list)
        return list
      })
  }, [applyCanvasList])
  const refreshCanvasesTimerRef = useRef<number | null>(null)
  // U5.1 — auto-refresh on notification.
  // bump this counter whenever a WS state.changed event arrives. Anything that
  // renders the active canvas (PlannerGraph etc.) takes it as a prop and uses
  // it as an effect dep to refetch its server state without a manual canvas
  // switch.
  const [activeCanvasRefreshTick, setActiveCanvasRefreshTick] = useState(0)
  const scheduleCanvasListRefresh = useCallback(() => {
    // bump the per-canvas refresh tick immediately so consumers diff against
    // the server in <1s of the notification (acceptance #1).
    setActiveCanvasRefreshTick((value) => value + 1)
    if (refreshCanvasesTimerRef.current !== null) {
      window.clearTimeout(refreshCanvasesTimerRef.current)
    }
    refreshCanvasesTimerRef.current = window.setTimeout(() => {
      refreshCanvasesTimerRef.current = null
      refreshCanvases().catch((err) => {
        console.warn('[App] refreshCanvases after state update failed:', (err as Error).message)
      })
    }, 350)
  }, [refreshCanvases])

  useEffect(() => {
    return () => {
      if (refreshCanvasesTimerRef.current !== null) {
        window.clearTimeout(refreshCanvasesTimerRef.current)
      }
    }
  }, [])

  useEffect(() => {
    let cancelled = false
    let loadingTimer: number | null = null
    const cached = canvasSceneCacheRef.current[activeCanvasId]
    const loadingStartedAt = performance.now()
    if (cached) {
      setHydrated(cached)
      setCanvasLoading(false)
    } else {
      setCanvasLoading(true)
    }

    const rememberCanvasState = (next: HydratedState) => {
      const updated = {
        ...canvasSceneCacheRef.current,
        [next.canvasId]: next,
      }
      canvasSceneCacheRef.current = updated
    }
    const finishLoading = (next: HydratedState) => {
      const remainingMs = Math.max(0, MIN_CANVAS_LOADING_MS - (performance.now() - loadingStartedAt))
      const apply = () => {
        if (cancelled) return
        setHydrated(next)
        setCanvasLoading(false)
      }
      if (cached) {
        apply()
      } else {
        loadingTimer = window.setTimeout(apply, remainingMs)
      }
    }

    loadCanvasHydratedState(activeCanvasId, persistence).then((next) => {
      if (cancelled) return
      rememberCanvasState(next)
      finishLoading(next)
    }).catch((err) => {
      console.warn('[App] hydrate canvas failed:', (err as Error).message)
      if (cancelled) return
      const next = emptyHydratedState(activeCanvasId)
      rememberCanvasState(next)
      finishLoading(next)
    })
    return () => {
      cancelled = true
      if (loadingTimer !== null) window.clearTimeout(loadingTimer)
    }
  }, [activeCanvasId, persistence])

  useEffect(() => {
    if (!canvasList) return
    let cancelled = false
    const ids = canvasList.canvases
      .map((canvas) => canvas.id)
      .filter((canvasId) => canvasId !== activeCanvasId && !canvasSceneCacheRef.current[canvasId])

    for (const canvasId of ids) {
      loadCanvasHydratedState(canvasId)
        .then((next) => {
          if (cancelled) return
          if (canvasSceneCacheRef.current[canvasId]) return
          const updated = {
            ...canvasSceneCacheRef.current,
            [canvasId]: next,
          }
          canvasSceneCacheRef.current = updated
        })
        .catch(() => {
          // Prefetch is opportunistic; active canvas loading still reports errors.
        })
    }

    return () => {
      cancelled = true
    }
  }, [activeCanvasId, canvasList])

  const boardState = useBoardState(scheduleCanvasListRefresh)
  const workspaceCanvases = useMemo(() => (canvasList?.canvases ?? []).filter(isWorkspaceCanvas), [canvasList])
  const activeWorkspaceCanvasId = workspaceCanvases.some((canvas) => canvas.id === activeCanvasId)
    ? activeCanvasId
    : workspaceCanvases[0]?.id ?? activeCanvasId
  const activeWorkspaceCanvas = canvasList?.canvases.find((canvas) => canvas.id === activeWorkspaceCanvasId)
  const activeWorkspaceCanvasKind = canvasKind(activeWorkspaceCanvas)
  const [activePlannerState, setActivePlannerState] = useState<PlannerGraphState | null>(null)
  useEffect(() => {
    setActivePlannerState(null)
  }, [activeWorkspaceCanvasId])
  const currentPlannerState = activePlannerState?.canvas.id === activeWorkspaceCanvasId ? activePlannerState : null
  const activeCanvasMonitor = useCanvasMonitor({
    plannerState: currentPlannerState,
    boardState: boardState.state,
  })
  const [workspaceMode, setWorkspaceMode] = useState<WorkspaceMode>('planner')
  const [workspaceRailCollapsed, setWorkspaceRailCollapsed] = useState(() => readWorkspaceRailCollapsed())
  const [firstRunOnboardingCompleted, setFirstRunOnboardingCompleted] = useState(() => readFirstRunOnboardingCompleted())
  const [degradedEntry, setDegradedEntry] = useState(false)
  const [selectedSessionId, setSelectedSessionId] = useState<string | null>(null)
  const firstRunOnboardingCompletedAtMountRef = useRef(firstRunOnboardingCompleted)
  const [agentRuntimeStatus, setAgentRuntimeStatus] = useState<Meee2AgentRuntimeStatus | null>(null)
  const [agentRuntimeModalOpen, setAgentRuntimeModalOpen] = useState(false)
  const [agentRuntimeInstallTarget, setAgentRuntimeInstallTarget] = useState<'claude' | 'codex' | 'all' | null>(null)
  const [agentRuntimeInstallError, setAgentRuntimeInstallError] = useState<string | null>(null)
  const [agentRuntimeInstallLogs, setAgentRuntimeInstallLogs] = useState<string[]>([])
  const [readinessReport, setReadinessReport] = useState<ReadinessReport | null>(null)
  const [readinessRepairAction, setReadinessRepairAction] = useState<string | null>(null)
  const [readinessRepairError, setReadinessRepairError] = useState<string | null>(null)
  const [readinessRepairLogs, setReadinessRepairLogs] = useState<string[]>([])
  const [userProfile, setUserProfile] = useState<UserProfile | null>(null)
  // Session unread dots still drive the compact rail badges.
  const [unreadSids, setUnreadSids] = useState<Set<string>>(() => new Set())
  useEffect(() => {
    if (hydrated) setUnreadSids(hydrated.unreadSids)
  }, [hydrated])
  const prevStatusRef = useRef<Record<string, string>>({})
  const [toasts, setToasts] = useState<Toast[]>([])
  const [plannerClearRevision, setPlannerClearRevision] = useState(0)

  // 检测 status 转换，同步红点：
  //   工作态 → 休息态 = "Claude 刚回复完"       → 标未读
  //   休息态 → 非休息态 = "用户已回应（新 prompt / terminal 内手动回复）" → 清未读
  // 第二条覆盖的场景：用户没点 web 卡片，而是直接在 terminal 里回了一句——
  //   那一瞬间 session 从 completed/idle/waitingForUser 回到 thinking/tooling，
  //   数据源本身已经告诉我们"用户已经处理过上一轮"，红点理应自动消失。
  //
  // prevStatusRef 只在内存里；页面刷新后 transition 历史丢失是 OK 的——
  // 已标过红点的 sid 从 localStorage 取回，但不会因此错误地清除：清除只在
  // 真实观测到 resting → non-resting 转换时发生，首次观测到 session 不算。
  useEffect(() => {
    const st = boardState.state
    if (!st) return
    const prev = prevStatusRef.current
    const nextPrev: Record<string, string> = {}
    let changed = false
    setUnreadSids((oldSet) => {
      const newSet = new Set(oldSet)
      for (const s of st.sessions) {
        const oldStatus = prev[s.id]
        const newStatus = s.status
        nextPrev[s.id] = newStatus
        // 首次看到这个 session（oldStatus undefined）→ 不触发任何转换，只记录
        if (!oldStatus) continue
        if (oldStatus === newStatus) continue

        const wasWorking = WORKING_STATUSES.has(oldStatus)
        const wasResting = RESTING_STATUSES.has(oldStatus)
        const nowResting = RESTING_STATUSES.has(newStatus)

        // 加红点：Claude 刚完成一轮
        if (wasWorking && nowResting) {
          if (!newSet.has(s.id)) {
            newSet.add(s.id)
            changed = true
          }
          continue
        }
        // 清红点：用户已回应（terminal 手动回复 / 审批通过 permission / 重新提问）
        if (wasResting && !nowResting) {
          if (newSet.has(s.id)) {
            newSet.delete(s.id)
            changed = true
          }
        }
      }
      prevStatusRef.current = nextPrev
      if (changed) void persistence.saveUnreadSids(newSet)
      return changed ? newSet : oldSet
    })
  }, [boardState.state])

  // Chunk D: OS-level notifications. Diff session snapshots, fire system
  // notifications for permission-request / session-blocked / session-done /
  // recap-updated. Approval (planner gate-wait) is dispatched separately from
  // PlannerGraph since planner state isn't part of BoardState.
  const prevSessionsRef = useRef<Map<string, Session>>(new Map())
  useEffect(() => {
    // Request permission on first BoardState arrival (lazy — only once).
    void ensureNotificationPermission()
  }, [])
  useEffect(() => {
    const st = boardState.state
    if (!st) return
    const toggles = loadNotificationToggles()
    // Defer to a microtask so the diff never blocks render.
    queueMicrotask(() => {
      runSessionTransitionNotifications(prevSessionsRef.current, st.sessions, toggles)
      prevSessionsRef.current = indexSessions(st.sessions)
    })
  }, [boardState.state])

  const pushToast: ToastCtx['push'] = useCallback((kind, text) => {
    const id = Date.now() + Math.random()
    setToasts((t) => [...t, { id, kind, text }])
    setTimeout(() => {
      setToasts((t) => t.filter((x) => x.id !== id))
    }, 4000)
  }, [])

  const toastCtx = useMemo(() => ({ push: pushToast }), [pushToast])

  const refreshAgentRuntimeStatus = useCallback((showModal: boolean) => {
    fetchMeee2AgentRuntimeStatus()
      .then((status) => {
        setAgentRuntimeInstallError(null)
        setAgentRuntimeStatus(status)
        if (showModal && status.needsAttention) setAgentRuntimeModalOpen(true)
      })
      .catch((err) => {
        console.warn('[App] fetchMeee2AgentRuntimeStatus failed:', (err as Error).message)
        setAgentRuntimeStatus(null)
        setAgentRuntimeInstallError((err as Error).message || 'Failed to check Meee2 Agent Runtime')
      })
  }, [])

  const refreshReadiness = useCallback(() => {
    fetchReadiness()
      .then((report) => {
        setReadinessReport(report)
        setReadinessRepairError(null)
      })
      .catch((err) => {
        console.warn('[App] fetchReadiness failed:', (err as Error).message)
        setReadinessReport(null)
        setReadinessRepairError((err as Error).message || 'Failed to check local session readiness')
      })
  }, [])

  const handleRepairReadiness = useCallback((actionId: string) => {
    setReadinessRepairAction(actionId)
    setReadinessRepairError(null)
    setReadinessRepairLogs([`Starting recovery action: ${actionId}`])
    repairReadiness(actionId)
      .then((result) => {
        setReadinessReport(result.report)
        setReadinessRepairLogs(result.logs?.length ? result.logs : result.messages)
        refreshAgentRuntimeStatus(false)
        if (result.ok && result.report.ready) {
          pushToast('success', 'Local session readiness is complete')
        } else if (!result.ok) {
          setReadinessRepairError(result.messages[result.messages.length - 1] ?? 'Readiness repair failed')
        }
      })
      .catch((err) => {
        setReadinessRepairError((err as Error).message || 'Readiness repair failed')
        setReadinessRepairLogs((current) => [...current, (err as Error).message || 'Readiness repair failed'])
      })
      .finally(() => setReadinessRepairAction(null))
  }, [pushToast, refreshAgentRuntimeStatus])

  useEffect(() => {
    refreshAgentRuntimeStatus(firstRunOnboardingCompletedAtMountRef.current)
    refreshReadiness()
  }, [refreshAgentRuntimeStatus, refreshReadiness])

  useEffect(() => {
    const openSettings = () => setWorkspaceMode('settings')
    window.addEventListener('meee2:open-settings', openSettings)
    return () => window.removeEventListener('meee2:open-settings', openSettings)
  }, [])

  // UI-simplification chunk G — CanvasToolbar 「+ New canvas」 modal 顶部
  // 「从模板新建」CTA 通过 window event 切到 Templates view。沿用上面 open-settings
  // 同款 isolated listener,不动 routing 主链。
  useEffect(() => {
    const navTemplates = () => setWorkspaceMode('templates')
    window.addEventListener('meee2:nav-templates', navTemplates)
    return () => window.removeEventListener('meee2:nav-templates', navTemplates)
  }, [])

  const openSessionsWorkspaceFromDetail = useCallback((detail?: { sessionId?: string; surfaceId?: string } | null) => {
    const surfaceId = detail?.surfaceId?.trim()
    const sessionId = detail?.sessionId?.trim()
    setDegradedEntry(true)
    setSelectedSessionId(sessionId || surfaceId || null)
    setWorkspaceMode('sessions')
    boardState.refresh()
  }, [boardState.refresh])

  useEffect(() => {
    const openSession = (event: Event) => {
      const detail = (event as CustomEvent<{ sessionId?: string; surfaceId?: string }>).detail
      openSessionsWorkspaceFromDetail(detail)
    }
    window.addEventListener('meee2:open-session', openSession)
    return () => window.removeEventListener('meee2:open-session', openSession)
  }, [openSessionsWorkspaceFromDetail])

  useEffect(() => {
    const openSessionsWorkspace = (event: Event) => {
      const detail = (event as CustomEvent<{ sessionId?: string; surfaceId?: string }>).detail
      openSessionsWorkspaceFromDetail(detail)
    }
    window.addEventListener('meee2:open-sessions-workspace', openSessionsWorkspace)
    if (window.__meee2PendingSessionsWorkspace) {
      openSessionsWorkspaceFromDetail(window.__meee2PendingSessionsWorkspace)
    }
    return () => window.removeEventListener('meee2:open-sessions-workspace', openSessionsWorkspace)
  }, [openSessionsWorkspaceFromDetail])

  const completeFirstRunOnboarding = useCallback(() => {
    if (readinessReport?.ready !== true) return
    setFirstRunOnboardingCompleted(true)
    try {
      window.localStorage.setItem(FIRST_RUN_ONBOARDING_COMPLETED_KEY, '1')
    } catch {
      // Persistence is best-effort; entering the app should still work.
    }
  }, [readinessReport])

  const enterDegradedWorkspace = useCallback(() => {
    setDegradedEntry(true)
  }, [])

  const restartFirstRunOnboarding = useCallback(() => {
    try {
      window.localStorage.removeItem(FIRST_RUN_ONBOARDING_COMPLETED_KEY)
    } catch {
      // Persistence is best-effort; the in-memory flag still reopens onboarding.
    }
    setAgentRuntimeInstallError(null)
    setAgentRuntimeInstallLogs([])
    setAgentRuntimeInstallTarget(null)
    setReadinessRepairError(null)
    setReadinessRepairLogs([])
    setReadinessRepairAction(null)
    setDegradedEntry(false)
    setFirstRunOnboardingCompleted(false)
    refreshAgentRuntimeStatus(false)
    refreshReadiness()
  }, [refreshAgentRuntimeStatus, refreshReadiness])

  const handleInstallAgentRuntime = useCallback((target: 'claude' | 'codex' | 'all') => {
    setAgentRuntimeInstallTarget(target)
    setAgentRuntimeInstallError(null)
    setAgentRuntimeInstallLogs([`Starting install for ${target}...`])
    installMeee2AgentRuntime(target)
      .then((result) => {
        setAgentRuntimeStatus(result.status)
        setAgentRuntimeInstallLogs(result.logs?.length ? result.logs : result.messages)
        if (result.ok) {
          pushToast('success', t('toast.runtimeReady'))
          if (!result.status.needsAttention) setAgentRuntimeModalOpen(false)
        } else {
          const message = result.messages.find((item) => /failed|skipped/i.test(item))
            ?? result.messages[result.messages.length - 1]
            ?? 'Agent runtime setup is incomplete'
          setAgentRuntimeInstallError(message)
        }
      })
      .catch((err) => {
        setAgentRuntimeInstallError((err as Error).message || 'Failed to install Meee2 Agent Runtime')
        setAgentRuntimeInstallLogs((current) => [...current, (err as Error).message || 'Failed to install Meee2 Agent Runtime'])
      })
      .finally(() => setAgentRuntimeInstallTarget(null))
  }, [pushToast, t])

  const handleOpenAgentRuntimeSetup = useCallback((_target?: SpawnProvider) => {
    refreshAgentRuntimeStatus(false)
    setAgentRuntimeInstallError(null)
    setAgentRuntimeInstallLogs([])
    setAgentRuntimeModalOpen(true)
    setAgentRuntimeInstallTarget(null)
  }, [refreshAgentRuntimeStatus])

  const handleSetActiveCanvas = useCallback((canvasId: string) => {
    updateCanvas(canvasId, { active: true })
      .then((list) => {
        applyCanvasList(list)
      })
      .catch((err) => pushToast('error', (err as Error).message || 'Failed to switch canvas'))
  }, [applyCanvasList, pushToast])

  const handleOpenBoardTarget = useCallback((target: BoardOpenTarget) => {
    if (target.kind === 'session') {
      setWorkspaceMode('sessions')
      window.dispatchEvent(new CustomEvent('meee2:open-session', {
        detail: { sessionId: target.sessionId },
      }))
      return
    }

    setWorkspaceMode('planner')
    if (target.canvasId !== activeCanvasId) {
      handleSetActiveCanvas(target.canvasId)
    }

    if (target.kind === 'canvas') {
      if (target.guide?.enabled) {
        window.setTimeout(() => {
          requestBoardGuide({
            kind: 'selector',
            selector: '[data-guide-target="planner-flow"]',
            title: target.guide?.title,
            body: target.guide?.body,
            durationMs: target.guide?.durationMs,
            source: target.source,
          })
        }, 180)
      }
      return
    }

    if (target.kind === 'planner-proposal') {
      window.setTimeout(() => {
        requestBoardGuide({
          kind: 'selector',
          selector: '[data-guide-target="planner-proposal"], [data-guide-target="planner-workspace-preview"]',
          title: target.guide?.title ?? 'Review proposal',
          body: target.guide?.body,
          durationMs: target.guide?.durationMs,
          source: target.source,
        })
      }, 220)
      return
    }

    if (target.kind === 'planner-delivery') {
      window.setTimeout(() => {
        requestBoardGuide({
          kind: 'selector',
          selector: '[data-guide-target="planner-flow"]',
          title: target.guide?.title ?? 'Delivery canvas',
          body: target.guide?.body,
          durationMs: target.guide?.durationMs,
          source: target.source,
        })
      }, 220)
      return
    }

    if (target.kind === 'planner-artifact') {
      window.setTimeout(() => {
        requestPlannerNodeSelection({
          canvasId: target.canvasId,
          nodeId: target.nodeId,
          artifactId: target.artifactId,
          guide: target.guide?.enabled ?? true,
          source: target.source,
          title: target.guide?.title ?? 'Opened artifact',
          body: target.guide?.body,
          durationMs: target.guide?.durationMs,
          openInspector: true,
        })
      }, 50)
      return
    }

    window.setTimeout(() => {
      requestPlannerNodeSelection({
        canvasId: target.canvasId,
        nodeId: target.nodeId,
        guide: target.guide?.enabled ?? false,
        source: target.source,
        title: target.guide?.title,
        body: target.guide?.body,
        durationMs: target.guide?.durationMs,
        openInspector: target.guide?.openInspector,
      })
    }, 50)
  }, [activeCanvasId, handleSetActiveCanvas])

  const handleOpenMonitorItem = useCallback((item: PlannerMonitorItem) => {
    const target = resolveMonitorItemOpenTarget(item)
    if (target.kind === 'node') {
      requestBoardTarget({
        kind: 'planner-node',
        canvasId: target.canvasId,
        nodeId: target.nodeId,
        source: 'monitor',
        guide: {
          enabled: true,
          title: 'Needs attention',
          body: item.summary,
          openInspector: false,
        },
      })
      return
    }
    if (target.kind === 'proposal') {
      requestBoardTarget({
        kind: 'planner-proposal',
        canvasId: target.canvasId,
        proposalId: target.proposalId,
        source: 'monitor',
        guide: {
          enabled: true,
          title: 'Review proposal',
          body: item.summary,
        },
      })
      return
    }
    if (target.kind === 'delivery') {
      requestBoardTarget({
        kind: 'planner-delivery',
        canvasId: target.canvasId,
        deliveryId: target.deliveryId,
        source: 'monitor',
        guide: {
          enabled: true,
          title: 'Delivery needs attention',
          body: item.summary,
        },
      })
      return
    }
    requestBoardTarget({
      kind: 'canvas',
      canvasId: target.canvasId,
      source: 'monitor',
      guide: {
        enabled: true,
        title: 'Canvas needs attention',
        body: item.summary,
      },
    })
  }, [])

  useEffect(() => {
    const openBoardTarget = (event: Event) => {
      const target = (event as CustomEvent<BoardOpenTarget>).detail
      if (!target?.kind) return
      handleOpenBoardTarget(target)
    }
    const openPlannerItem = (event: Event) => {
      const detail = (event as CustomEvent<{ canvasId?: string; nodeId?: string }>).detail
      const target = boardTargetFromPlannerItem({
        canvasId: detail?.canvasId,
        nodeId: detail?.nodeId,
        source: 'island',
        guide: {
          enabled: true,
          title: 'Opened from Dynamic Island',
          body: 'This is the node that needs your attention.',
          openInspector: false,
        },
      })
      if (target) handleOpenBoardTarget(target)
    }
    window.addEventListener('meee2:open-board-target', openBoardTarget)
    window.addEventListener('meee2:open-planner-item', openPlannerItem)
    return () => {
      window.removeEventListener('meee2:open-board-target', openBoardTarget)
      window.removeEventListener('meee2:open-planner-item', openPlannerItem)
    }
  }, [handleOpenBoardTarget])

  // Command palette and native bridge share the same board-target path. The
  // target handler owns canvas switching; PlannerGraph consumes the pending
  // node selection once that canvas has hydrated.
  const handlePaletteOpenCanvas = useCallback((canvasId: string) => {
    handleOpenBoardTarget({ kind: 'canvas', canvasId, source: 'palette' })
  }, [handleOpenBoardTarget])

  const handlePaletteOpenNode = useCallback((canvasId: string, nodeId: string) => {
    handleOpenBoardTarget({ kind: 'planner-node', canvasId, nodeId, source: 'palette' })
  }, [handleOpenBoardTarget])

  const handlePaletteOpenSession = useCallback((sessionId: string) => {
    handleOpenBoardTarget({ kind: 'session', sessionId, source: 'palette' })
  }, [handleOpenBoardTarget])

  const initialMonitorCanvasSelectedRef = useRef(false)
  useEffect(() => {
    if (initialMonitorCanvasSelectedRef.current || !canvasList || workspaceMode !== 'planner') return
    initialMonitorCanvasSelectedRef.current = true
    const monitorCanvas = canvasList.canvases.find((canvas) => canvas.kind === 'monitor' && canvas.isDefault)
      ?? canvasList.canvases.find((canvas) => canvas.kind === 'monitor')
    if (monitorCanvas && monitorCanvas.id !== activeCanvasId) {
      handleSetActiveCanvas(monitorCanvas.id)
    }
  }, [activeCanvasId, canvasList, handleSetActiveCanvas, workspaceMode])

  const workspaceCanvasIds = useMemo(() => (
    (canvasList?.canvases ?? [])
      .filter(isWorkspaceCanvas)
      .map((canvas) => canvas.id)
  ), [canvasList])
  const activeHistoryCanvasId = workspaceCanvasIds.includes(activeCanvasId)
    ? activeCanvasId
    : workspaceCanvasIds[0] ?? activeCanvasId
  const [canvasHistory, setCanvasHistory] = useState<string[]>([])
  const [canvasHistoryIndex, setCanvasHistoryIndex] = useState(-1)
  const canvasHistoryNavigationTargetRef = useRef<string | null>(null)

  useEffect(() => {
    if (!canvasList || workspaceCanvasIds.length === 0) return
    const navigationTarget = canvasHistoryNavigationTargetRef.current
    if (navigationTarget) {
      if (activeHistoryCanvasId === navigationTarget) {
        canvasHistoryNavigationTargetRef.current = null
      }
      return
    }
    setCanvasHistory((current) => {
      const currentAtIndex = canvasHistoryIndex >= 0 ? current[canvasHistoryIndex] : null
      if (currentAtIndex === activeHistoryCanvasId) return current
      const next = current.slice(0, Math.max(0, canvasHistoryIndex + 1)).filter((id) => workspaceCanvasIds.includes(id))
      if (next[next.length - 1] !== activeHistoryCanvasId) next.push(activeHistoryCanvasId)
      setCanvasHistoryIndex(next.length - 1)
      return next
    })
  }, [activeHistoryCanvasId, canvasHistoryIndex, canvasList, workspaceCanvasIds])

  const handleCanvasHistoryBack = useCallback(() => {
    const nextIndex = canvasHistoryIndex - 1
    const targetCanvasId = canvasHistory[nextIndex]
    if (nextIndex < 0 || !targetCanvasId || !workspaceCanvasIds.includes(targetCanvasId)) return
    canvasHistoryNavigationTargetRef.current = targetCanvasId
    setCanvasHistoryIndex(nextIndex)
    handleSetActiveCanvas(targetCanvasId)
    window.setTimeout(() => {
      if (canvasHistoryNavigationTargetRef.current === targetCanvasId) canvasHistoryNavigationTargetRef.current = null
    }, 2000)
  }, [canvasHistory, canvasHistoryIndex, handleSetActiveCanvas, workspaceCanvasIds])

  const handleCanvasHistoryForward = useCallback(() => {
    const nextIndex = canvasHistoryIndex + 1
    const targetCanvasId = canvasHistory[nextIndex]
    if (nextIndex >= canvasHistory.length || !targetCanvasId || !workspaceCanvasIds.includes(targetCanvasId)) return
    canvasHistoryNavigationTargetRef.current = targetCanvasId
    setCanvasHistoryIndex(nextIndex)
    handleSetActiveCanvas(targetCanvasId)
    window.setTimeout(() => {
      if (canvasHistoryNavigationTargetRef.current === targetCanvasId) canvasHistoryNavigationTargetRef.current = null
    }, 2000)
  }, [canvasHistory, canvasHistoryIndex, handleSetActiveCanvas, workspaceCanvasIds])

  const handleCreateCanvas = useCallback((name: string, scope: CanvasScope, kind?: CanvasKind) => {
    return createCanvas({ name, scope, kind })
      .then((list) => {
        applyCanvasList(list)
      })
  }, [applyCanvasList])

  const handleCreateTemplate = useCallback((name: string, scope: CanvasScope) => {
    return createCanvas({ name, scope, kind: 'template' })
      .then((list) => {
        applyCanvasList(list)
        return list.activeCanvasId
      })
  }, [applyCanvasList])

  // Chunk F: spawn a canvas from a builtin gallery template, then jump to it.
  const handleApplyTemplate = useCallback(
    (templateId: string, name: string, scope: CanvasScope) => {
      return applyCanvasTemplate(templateId, { name, scope }).then((list) => {
        applyCanvasList(list)
        setWorkspaceMode('planner')
        handleSetActiveCanvas(list.activeCanvasId)
        return list.activeCanvasId
      })
    },
    [applyCanvasList, handleSetActiveCanvas],
  )

  const handleSaveCanvasAsTemplate = useCallback(
    (canvasId: string, input: TemplateMetadataInput) => {
      return createTemplateFromCanvas({ ...input, canvasId }).then((list) => {
        applyCanvasList(list)
        setWorkspaceMode('templates')
        return list.activeCanvasId
      })
    },
    [applyCanvasList],
  )

  const handleCreateTemplateDraft = useCallback(
    (templateId: string) => {
      return createTemplateEditDraft(templateId).then((list) => {
        applyCanvasList(list)
        setWorkspaceMode('planner')
        handleSetActiveCanvas(list.activeCanvasId)
        return list.activeCanvasId
      })
    },
    [applyCanvasList, handleSetActiveCanvas],
  )

  const handleReplaceTemplate = useCallback(
    (templateId: string, canvasId: string, input: TemplateMetadataInput) => {
      return replaceTemplateFromCanvas(templateId, { ...input, canvasId }).then((list) => {
        applyCanvasList(list)
        setWorkspaceMode('templates')
        handleSetActiveCanvas(templateId)
        return templateId
      })
    },
    [applyCanvasList, handleSetActiveCanvas],
  )

  const handleUpdateTemplateMetadata = useCallback(
    (templateId: string, input: TemplateMetadataInput) => {
      return updateTemplateMetadata(templateId, input).then((list) => {
        applyCanvasList(list)
        return templateId
      })
    },
    [applyCanvasList],
  )

  const handleImportClaudeWorkflow = useCallback(
    (workflowId: string, name: string, scope: CanvasScope) => {
      return importClaudeWorkflow(workflowId, { name, scope }).then((list) => {
        applyCanvasList(list)
        setWorkspaceMode('planner')
        handleSetActiveCanvas(list.activeCanvasId)
        return list.activeCanvasId
      })
    },
    [applyCanvasList, handleSetActiveCanvas],
  )

  const handleUploadClaudeWorkflow = useCallback(
    (filename: string, source: string, name: string, scope: CanvasScope) => {
      return uploadClaudeWorkflow({ filename, source, name, scope }).then((list) => {
        applyCanvasList(list)
        setWorkspaceMode('planner')
        handleSetActiveCanvas(list.activeCanvasId)
        return list.activeCanvasId
      })
    },
    [applyCanvasList, handleSetActiveCanvas],
  )

  const handleRenameCanvas = useCallback((canvasId: string, name: string) => {
    return updateCanvas(canvasId, { name })
      .then((list) => {
        applyCanvasList(list)
      })
      .catch((err) => pushToast('error', (err as Error).message || 'Failed to rename canvas'))
  }, [applyCanvasList, pushToast])

  const handleDeleteCanvas = useCallback((canvasId: string) => {
    return deleteCanvas(canvasId)
      .then((list) => {
        const nextCache = { ...canvasSceneCacheRef.current }
        delete nextCache[canvasId]
        canvasSceneCacheRef.current = nextCache
        applyCanvasList(list)
        pushToast('success', 'Canvas deleted')
      })
      .catch((err) => pushToast('error', (err as Error).message || 'Failed to delete canvas'))
  }, [applyCanvasList, pushToast])

  const handleClearCanvas = useCallback((canvasId: string) => {
    return clearPlannerCanvasContent(canvasId)
      .then(() => {
        setPlannerClearRevision((value) => value + 1)
        pushToast('success', 'Canvas cleared')
      })
      .catch((err) => pushToast('error', (err as Error).message || 'Failed to clear canvas'))
  }, [pushToast])

  const boardSessionSignature = useMemo(() => {
    if (!boardState.state) return ''
    return boardState.state.sessions.map((s) => s.id).sort().join('|')
  }, [boardState.state])

  useEffect(() => {
    if (!boardSessionSignature) return
    refreshCanvases().catch((err) => {
      console.warn('[App] refreshCanvases after session update failed:', (err as Error).message)
    })
  }, [boardSessionSignature, refreshCanvases])

  const handleWorkspaceModeChange = useCallback((nextMode: WorkspaceMode) => {
    setWorkspaceMode(nextMode)
    if (nextMode !== 'planner' || !canvasList) return
    const currentCanvas = canvasList.canvases.find((canvas) => canvas.id === activeCanvasId)
    if (canvasKind(currentCanvas) !== 'template') return
    const firstWorkspaceCanvas = canvasList.canvases.find(isWorkspaceCanvas)
    if (firstWorkspaceCanvas) handleSetActiveCanvas(firstWorkspaceCanvas.id)
  }, [activeCanvasId, canvasList, handleSetActiveCanvas])

  const handleWorkspaceRailCollapsedChange = useCallback((collapsed: boolean) => {
    setWorkspaceRailCollapsed(collapsed)
    try {
      window.localStorage.setItem(WORKSPACE_RAIL_COLLAPSED_KEY, collapsed ? '1' : '0')
    } catch {
      // Persistence is nice-to-have; keep the in-memory state.
    }
  }, [])

  const refreshUserProfile = useCallback(() => {
    fetchUserProfile()
      .then(setUserProfile)
      .catch(() => setUserProfile(null))
  }, [])

  useEffect(() => {
    refreshUserProfile()
    window.addEventListener('focus', refreshUserProfile)
    return () => window.removeEventListener('focus', refreshUserProfile)
  }, [refreshUserProfile])

  if (!firstRunOnboardingCompleted && !degradedEntry) {
    return (
      <ToastContext.Provider value={toastCtx}>
        <FirstRunOnboarding
          report={readinessReport}
          repairingAction={readinessRepairAction}
          repairError={readinessRepairError}
          repairLogs={readinessRepairLogs}
          onRepair={handleRepairReadiness}
          onRefresh={refreshReadiness}
          onComplete={completeFirstRunOnboarding}
          onDegradedEntry={enterDegradedWorkspace}
        />
        <div className="toasts">
          {toasts.map((t) => (
            <div key={t.id} className={`toast ${t.kind}`}>
              {t.text}
            </div>
          ))}
        </div>
      </ToastContext.Provider>
    )
  }

  if (!hydrated || !canvasList) {
    return (
      <div className="app boot">
        <div className="boot-spinner" />
      </div>
    )
  }

  const activeCanvasLoading = canvasLoading || hydrated.canvasId !== activeCanvasId
  const showCanvasLoading = activeCanvasLoading && (workspaceMode === 'planner' || workspaceMode === 'templates')

  return (
    <ToastContext.Provider value={toastCtx}>
      <div className="app">
        <WorkspaceRail
          state={boardState.state}
          canvases={canvasList.canvases}
          activeCanvasId={activeCanvasId}
          mode={workspaceMode}
          unreadSids={unreadSids}
          userProfile={userProfile}
          collapsed={workspaceRailCollapsed}
          onCollapsedChange={handleWorkspaceRailCollapsedChange}
          onModeChange={handleWorkspaceModeChange}
        />
        <div className="board-area">
          {readinessReport && !readinessReport.ready && (
            <div className="readiness-banner" role="status">
              <div>
                <strong>Local session readiness needs setup</strong>
                <span>{readinessReport.requiredFailed} required check{readinessReport.requiredFailed === 1 ? '' : 's'} failing. Workspace is in degraded entry.</span>
              </div>
              <button type="button" className="ghost" onClick={() => setWorkspaceMode('settings')}>
                Open Settings
              </button>
            </div>
          )}
          {workspaceMode === 'planner' ? (
            activeWorkspaceCanvasKind === 'monitor' ? (
              <WorkspaceMonitor
                activeCanvasId={activeWorkspaceCanvasId}
                canvases={workspaceCanvases}
                refreshTick={activeCanvasRefreshTick}
                onOpenItem={handleOpenMonitorItem}
                onOpenAllSessions={() => setWorkspaceMode('sessions')}
              />
            ) : (
              <PlannerGraph
                canvasId={activeWorkspaceCanvasId}
                canvasName={activeWorkspaceCanvas?.name ?? 'Canvas'}
                workspacePath={activeWorkspaceCanvas?.workspacePath ?? ''}
                userProfile={userProfile}
                boardState={boardState.state}
                clearRevision={plannerClearRevision}
                refreshTick={activeCanvasRefreshTick}
                onPlannerStateChange={setActivePlannerState}
                onOpenSubCanvas={handleSetActiveCanvas}
                onNotify={pushToast}
                canvasMonitor={activeCanvasMonitor}
              />
            )
          ) : workspaceMode === 'templates' ? (
            <TemplatesView
              canvases={canvasList.canvases}
              activeCanvasId={activeCanvasId}
              userProfile={userProfile}
              boardState={boardState.state}
	              onOpenCanvas={handleSetActiveCanvas}
	              onCreateTemplate={handleCreateTemplate}
	              onApplyTemplate={handleApplyTemplate}
	              onSaveCanvasAsTemplate={handleSaveCanvasAsTemplate}
	              onCreateTemplateDraft={handleCreateTemplateDraft}
	              onReplaceTemplate={handleReplaceTemplate}
	              onUpdateTemplateMetadata={handleUpdateTemplateMetadata}
	              onImportClaudeWorkflow={handleImportClaudeWorkflow}
	              onUploadClaudeWorkflow={handleUploadClaudeWorkflow}
	            />
          ) : workspaceMode === 'sessions' ? (
            <NativeSessionsWorkspaceHost
              state={boardState.state}
              selectedSessionId={selectedSessionId}
              onSelectedSessionChange={setSelectedSessionId}
            />
          ) : workspaceMode === 'artifacts' ? (
            <ArtifactsView
              canvases={workspaceCanvases}
              activeCanvasId={activeWorkspaceCanvasId}
              onOpenCanvas={(canvasId) => {
                handleSetActiveCanvas(canvasId)
                setWorkspaceMode('planner')
              }}
            />
          ) : workspaceMode === 'integrations' ? (
            <IntegrationsView
              state={boardState.state}
              onJumpToCanvas={(canvasId) => {
                handleSetActiveCanvas(canvasId)
                setWorkspaceMode('planner')
              }}
            />
          ) : workspaceMode === 'team' ? (
            <TeamView userProfile={userProfile} />
          ) : workspaceMode === 'settings' ? (
            <SettingsView
              onSaved={() => {
                refreshUserProfile()
                refreshAgentRuntimeStatus(false)
                refreshReadiness()
              }}
              onToast={pushToast}
              agentRuntimeStatus={agentRuntimeStatus}
              onOpenAgentRuntime={handleOpenAgentRuntimeSetup}
              onRefreshAgentRuntime={() => refreshAgentRuntimeStatus(false)}
              readinessReport={readinessReport}
              readinessRepairAction={readinessRepairAction}
              readinessRepairError={readinessRepairError}
              readinessRepairLogs={readinessRepairLogs}
              onRepairReadiness={handleRepairReadiness}
              onRefreshReadiness={refreshReadiness}
              devMode={BOARD_DEV_MODE}
              onRestartOnboarding={restartFirstRunOnboarding}
            />
          ) : null}
          {workspaceMode === 'planner' && (
            <CanvasToolbar
              canvases={workspaceCanvases}
              activeCanvasId={activeWorkspaceCanvasId}
              canGoBack={canvasHistoryIndex > 0}
              canGoForward={canvasHistoryIndex >= 0 && canvasHistoryIndex < canvasHistory.length - 1}
              onActiveCanvasChange={handleSetActiveCanvas}
              onGoBack={handleCanvasHistoryBack}
              onGoForward={handleCanvasHistoryForward}
              onCreateCanvas={handleCreateCanvas}
              onRenameCanvas={handleRenameCanvas}
              onClearCanvas={handleClearCanvas}
              onDeleteCanvas={handleDeleteCanvas}
              onReplaceTemplate={handleReplaceTemplate}
              userProfile={userProfile}
              boardState={boardState.state}
              plannerState={currentPlannerState}
              canvasMonitor={activeCanvasMonitor}
              onOpenAllSessions={() => setWorkspaceMode('sessions')}
            />
          )}
          {showCanvasLoading && (
            <div className="canvas-global-loading" role="status" aria-live="polite">
              <div className="canvas-global-loading__ring" aria-hidden />
              <div className="canvas-global-loading__label">{t('common.switchingCanvas')}</div>
            </div>
          )}
          {boardState.error && (
            <div className="inline-error" style={{ position: 'absolute', bottom: 8, left: 12 }}>
              {boardState.error}
            </div>
          )}
        </div>
        {agentRuntimeModalOpen && agentRuntimeStatus && (
          <AgentRuntimeSetupModal
            status={agentRuntimeStatus}
            installingTarget={agentRuntimeInstallTarget}
            installError={agentRuntimeInstallError}
            installLogs={agentRuntimeInstallLogs}
            onInstall={handleInstallAgentRuntime}
            onClose={() => setAgentRuntimeModalOpen(false)}
          />
        )}
        <CommandPalette
          canvases={canvasList.canvases}
          boardState={boardState.state}
          onOpenCanvas={handlePaletteOpenCanvas}
          onOpenNodeInspector={handlePaletteOpenNode}
          onOpenSession={handlePaletteOpenSession}
        />
        <GuideOverlay />
        <div className="toasts">
          {toasts.map((t) => (
            <div key={t.id} className={`toast ${t.kind}`}>
              {t.text}
            </div>
          ))}
        </div>
      </div>
    </ToastContext.Provider>
  )
}

function readWorkspaceRailCollapsed(): boolean {
  if (typeof window === 'undefined') return false
  try {
    const stored = window.localStorage.getItem(WORKSPACE_RAIL_COLLAPSED_KEY)
    if (stored === '1') return true
    if (stored === '0') return false
    return window.matchMedia('(max-width: 720px)').matches
  } catch {
    return false
  }
}

function readFirstRunOnboardingCompleted(): boolean {
  if (typeof window === 'undefined') return true
  try {
    return window.localStorage.getItem(FIRST_RUN_ONBOARDING_COMPLETED_KEY) === '1'
  } catch {
    return true
  }
}

function readBoardDevMode(): boolean {
  if ((import.meta as { env?: { DEV?: boolean } }).env?.DEV === true) return true
  if (typeof window === 'undefined') return false
  try {
    const params = new URLSearchParams(window.location.search)
    if (params.get('devUpdate') === '1') return true
    return window.localStorage.getItem('meee2.devUpdate') === '1'
  } catch {
    return false
  }
}
