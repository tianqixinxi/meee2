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
import { SessionsView } from './components/SessionsView'
import { IntegrationsView } from './components/IntegrationsView'
import { TeamView } from './components/TeamView'
import { PreferencesDialog } from './components/PreferencesDialog'
import { WorkspaceRail, type WorkspaceMode } from './components/WorkspaceRail'
import { useBoardState } from './useBoardState'
import type {
  CanvasList,
  CanvasScope,
} from './types'
import { spawnProviderLabel } from './preferences'
import { WORKING_STATUSES, RESTING_STATUSES } from './notifications'
import type {
  CanvasPersistence,
  LayoutMap,
  PersistedViewport,
} from '@meee1/board-core'
import { HttpCanvasPersistence } from '@meee1/board-persistence-http'
import {
  createCanvas,
  deleteCanvas,
  fetchCanvases,
  fetchUserProfile,
  updateCanvas,
  type UserProfile,
} from './api'

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
const MIN_CANVAS_LOADING_MS = import.meta.env.VITE_PLANNER_DEMO === '1' ? 0 : 3000

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
      name: 'My',
      scope: 'personal',
      isDefault: true,
      workspacePath: '',
      ownerUserId: 'local-user',
      teamId: null,
    }],
  }
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
        isDefault: canvas.isDefault,
        workspacePath: canvas.workspacePath,
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
  const scheduleCanvasListRefresh = useCallback(() => {
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
  const [workspaceMode, setWorkspaceMode] = useState<WorkspaceMode>('planner')
  const [preferencesOpen, setPreferencesOpen] = useState(false)
  const [userProfile, setUserProfile] = useState<UserProfile | null>(null)
  // Session unread dots still drive the compact rail badges.
  const [unreadSids, setUnreadSids] = useState<Set<string>>(() => new Set())
  useEffect(() => {
    if (hydrated) setUnreadSids(hydrated.unreadSids)
  }, [hydrated])
  const prevStatusRef = useRef<Record<string, string>>({})
  const [toasts, setToasts] = useState<Toast[]>([])

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

  const pushToast: ToastCtx['push'] = useCallback((kind, text) => {
    const id = Date.now() + Math.random()
    setToasts((t) => [...t, { id, kind, text }])
    setTimeout(() => {
      setToasts((t) => t.filter((x) => x.id !== id))
    }, 4000)
  }, [])

  const toastCtx = useMemo(() => ({ push: pushToast }), [pushToast])

  const handleSetActiveCanvas = useCallback((canvasId: string) => {
    updateCanvas(canvasId, { active: true })
      .then((list) => {
        applyCanvasList(list)
      })
      .catch((err) => pushToast('error', (err as Error).message || 'Failed to switch canvas'))
  }, [applyCanvasList, pushToast])

  const handleCreateCanvas = useCallback((name: string, scope: CanvasScope) => {
    return createCanvas({ name, scope })
      .then((list) => {
        applyCanvasList(list)
      })
  }, [applyCanvasList])

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

  if (!hydrated || !canvasList) {
    return (
      <div className="app boot">
        <div className="boot-spinner" />
      </div>
    )
  }

  const activeCanvas = canvasList.canvases.find((canvas) => canvas.id === activeCanvasId)
  const activeCanvasLoading = canvasLoading || hydrated.canvasId !== activeCanvasId

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
          onModeChange={handleWorkspaceModeChange}
          onPreferences={() => setPreferencesOpen(true)}
        />
        <div className="board-area">
          {workspaceMode === 'planner' ? (
            <PlannerGraph
              canvasId={activeCanvasId}
              canvasName={activeCanvas?.name ?? 'Canvas'}
              userProfile={userProfile}
              boardState={boardState.state}
              onOpenSubCanvas={handleSetActiveCanvas}
            />
          ) : workspaceMode === 'sessions' ? (
            <SessionsView state={boardState.state} unreadSids={unreadSids} />
          ) : workspaceMode === 'integrations' ? (
            <IntegrationsView state={boardState.state} />
          ) : workspaceMode === 'team' ? (
            <TeamView
              state={boardState.state}
              activeCanvas={activeCanvas ?? null}
              userProfile={userProfile}
            />
          ) : (
            <WorkspaceMonitor />
          )}
          {workspaceMode === 'planner' && (
            <CanvasToolbar
              canvases={canvasList.canvases}
              activeCanvasId={activeCanvasId}
              onActiveCanvasChange={handleSetActiveCanvas}
              onCreateCanvas={handleCreateCanvas}
              onRenameCanvas={handleRenameCanvas}
              onDeleteCanvas={handleDeleteCanvas}
            />
          )}
          {activeCanvasLoading && (
            <div className="canvas-global-loading" role="status" aria-live="polite">
              <div className="canvas-global-loading__ring" aria-hidden />
              <div className="canvas-global-loading__label">Switching canvas</div>
            </div>
          )}
          {boardState.error && (
            <div className="inline-error" style={{ position: 'absolute', bottom: 8, left: 12 }}>
              {boardState.error}
            </div>
          )}
        </div>
        {preferencesOpen && (
          <PreferencesDialog
            onClose={() => setPreferencesOpen(false)}
            onSaved={(provider) => {
              pushToast('success', `Default spawn provider: ${spawnProviderLabel(provider)}`)
              refreshUserProfile()
            }}
            onToast={pushToast}
          />
        )}
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
