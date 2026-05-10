import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react'
import Board from './components/Board'
import Sidebar from './components/Sidebar'
import { Dock, type DockHandle, type DockMode, type DisplayMessage } from './components/Dock'
import NewChannelDialog from './components/NewChannelDialog'
import { NewSessionDialog } from './components/NewSessionDialog'
import { PreferencesDialog } from './components/PreferencesDialog'
import { useBoardState } from './useBoardState'
import type { Selection } from './types'
import type { CanvasList, CanvasScope } from './types'
import { DEFAULT_TEMPLATE, getTemplate, templateIdForSession } from '@meee1/board-cards'
import { WORKING_STATUSES, RESTING_STATUSES } from './notifications'
import type {
  CanvasPersistence,
  LayoutMap,
  PersistedViewport,
} from '@meee1/board-core'
import { HttpCanvasPersistence } from '@meee1/board-persistence-http'
import {
  addSessionToCanvas,
  createCanvas,
  fetchCanvases,
  removeSessionFromCanvas,
  updateCanvas,
} from './api'

interface HydratedState {
  sessionLayout: LayoutMap
  channelLayout: LayoutMap
  viewport: PersistedViewport | null
  userElements: any[]
  dismissed: Set<string>
  unreadSids: Set<string>
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
  const activeCanvasId = canvasList?.activeCanvasId ?? 'personal-default'
  // 整个应用的持久化层。CanvasPersistence interface 来自 @meee1/board-core；
  // meee2 走 HTTP / localStorage 双层实现，meee2 改用 SupabaseCanvasPersistence。
  const persistence = useMemo<CanvasPersistence>(
    () => new HttpCanvasPersistence(activeCanvasId),
    [activeCanvasId],
  )
  // 启动时一次性把所有 storage slot 拉好再 mount Board。
  // 历史上 Board 在 useRef 初值里同步 loadXxx() 拿 localStorage —— 现在改成
  // async 接口后必须先 hydrate 完才能渲染（否则 useRef 拿不到值）。
  const [hydrated, setHydrated] = useState<HydratedState | null>(null)
  useEffect(() => {
    let cancelled = false
    fetchCanvases()
      .then((list) => { if (!cancelled) setCanvasList(list) })
      .catch((err) => {
        console.warn('[App] fetchCanvases failed:', (err as Error).message)
      })
    return () => { cancelled = true }
  }, [])

  const refreshCanvases = useCallback(() => {
    return fetchCanvases()
      .then((list) => {
        setCanvasList(list)
        return list
      })
  }, [])

  useEffect(() => {
    let cancelled = false
    setHydrated(null)
    Promise.all([
      persistence.loadSessionLayout(),
      persistence.loadChannelLayout(),
      persistence.loadViewport(),
      persistence.loadUserElements(),
      persistence.loadDismissed(),
      persistence.loadUnreadSids(),
    ]).then(([sessionLayout, channelLayout, viewport, userElements, dismissed, unreadSids]) => {
      if (cancelled) return
      setHydrated({ sessionLayout, channelLayout, viewport, userElements, dismissed, unreadSids })
    })
    return () => { cancelled = true }
  }, [persistence])

  const boardState = useBoardState()
  const [selection, setSelection] = useState<Selection>({ kind: 'none' })
  const [sidebarOpen, setSidebarOpen] = useState(true)
  const [newChannelOpen, setNewChannelOpen] = useState(false)
  const [newSessionOpen, setNewSessionOpen] = useState(false)
  const [newSessionDefaultCwd, setNewSessionDefaultCwd] = useState<string | undefined>(undefined)
  // 用户显式请求 dock 进入 assistant 模式（Ask AI 按钮 / sidebar New session
  // 按钮 / group + 按钮）。selection.kind === 'session' 时若 dockOpen 但
  // assistantRequested=false → mode='session'；assistantRequested=true → mode='assistant'。
  // 键盘 hijack 在画板空白时也会 setAssistantRequested(true)。
  // 替换了原来独立的 `assistantOpen` state，让所有触发路径汇到同一个 dock 入口。
  const [assistantRequested, setAssistantRequested] = useState(false)
  // Assistant 模式 chat 历史 lift 到 App level，跨 dock 开关持久化。只有
  // 用户在 dock 里打 `/new-session`（或 /clear / /reset）才会清空。
  const [assistantMessages, setAssistantMessages] = useState<DisplayMessage[]>([])
  const [preferencesOpen, setPreferencesOpen] = useState(false)
  // 每个 session 的"未读通知"集合：status 从工作态 → 休息态转换时加入；
  // 用户点击 session card 时移除。持久化通过 persistence.saveUnreadSids。
  // 初值在 hydrate 完成前是空集合 —— 但 hydrate 不完成就不渲染（return null 保护），
  // 所以 transition 检测用到的旧值不会丢。
  const [unreadSids, setUnreadSids] = useState<Set<string>>(() => new Set())
  useEffect(() => {
    if (hydrated) setUnreadSids(hydrated.unreadSids)
  }, [hydrated])
  // 上一次看到的每个 session 的 status，用来检测转换
  const prevStatusRef = useRef<Record<string, string>>({})
  const [fitSignal, setFitSignal] = useState(0)
  const [toasts, setToasts] = useState<Toast[]>([])
  const [addToCanvasRequest, setAddToCanvasRequest] = useState<
    { sessionId: string; bump: number } | null
  >(null)
  const [hideFromCanvasRequest, setHideFromCanvasRequest] = useState<
    { sessionId: string; bump: number } | null
  >(null)
  // Sidebar 的 "Show all / Hide all" 按钮 —— 一次性处理所有 session，避免
  // 逐个 setAddToCanvasRequest 被 React setState 批处理吞掉只生效最后一次
  //
  // sids: 可选过滤集合 —— 缺省 / undefined 时影响全部 session（保留旧行为，
  // 顶部 "Hide all" 按钮的语义不变）；带 sids 时只动这一批（per-category
  // toggle 用）。
  const [bulkVisibilityRequest, setBulkVisibilityRequest] = useState<
    { mode: 'show' | 'hide'; bump: number; sids?: string[] } | null
  >(null)
  // Channel creation → Board places the hub at viewport center. App doesn't
  // own the Excalidraw imperative API, so we can't compute viewport coords
  // here — we fire this request and Board consumes it in an effect.
  const [placeChannelRequest, setPlaceChannelRequest] = useState<
    { channelName: string; bump: number } | null
  >(null)
  const [focusSessionRequest, setFocusSessionRequest] = useState<
    { sessionId: string; bump: number } | null
  >(null)
  const [onCanvasCounts, setOnCanvasCounts] = useState<Record<string, number>>(
    {},
  )
  // Dock：统一的画板浮窗。两种触发方式：
  //   - dockOpen + selection.kind === 'session' + !assistantRequested → mode='session'
  //   - dockOpen + (assistantRequested || no session)                  → mode='assistant'
  // 用户在画板上按可打印键 / 粘贴会触发 dock 挂载（mode 由当前 selection
  // 决定）。Click Ask AI / New session / group `+` → assistantRequested=true。
  // dock × 按钮关 dock：session 模式保留 selection；assistant 模式 reset
  // assistantRequested。
  const [dockOpen, setDockOpen] = useState(false)
  // session-mode dock 绑定的 sessionId —— 跟 `selection` 解耦：用户点画板
  // 空白处取消选中（selection → none）时 dock 不该收起，所以记一份 dock 自
  // 己锚定的 id。explicit close（× / Esc / 切到不同 session）时才更新。
  const [dockSessionId, setDockSessionId] = useState<string | null>(null)
  const dockSeedRef = useRef<string>('')
  const dockRef = useRef<DockHandle | null>(null)
  // Template cache: templateId → raw TSX source. Missing keys fall back to
  // DEFAULT_TEMPLATE. Populated lazily as pluginIds show up on screen, and
  // refetched on WS state.changed ticks (Wave 17a backend signals template
  // changes via the same channel).
  const [templateCache, setTemplateCache] = useState<Record<string, string>>({})
  // Track in-flight fetches so we don't hammer the backend when many CardHosts
  // ask for the same pluginId at once.
  const pendingTemplatesRef = useRef<Set<string>>(new Set())

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

  // 用户选中 session card → 清未读
  useEffect(() => {
    if (selection.kind !== 'session') return
    const sid = selection.sessionId
    setUnreadSids((oldSet) => {
      if (!oldSet.has(sid)) return oldSet
      const next = new Set(oldSet)
      next.delete(sid)
      void persistence.saveUnreadSids(next)
      return next
    })
  }, [selection])

  const pushToast: ToastCtx['push'] = useCallback((kind, text) => {
    const id = Date.now() + Math.random()
    setToasts((t) => [...t, { id, kind, text }])
    setTimeout(() => {
      setToasts((t) => t.filter((x) => x.id !== id))
    }, 4000)
  }, [])

  const toastCtx = useMemo(() => ({ push: pushToast }), [pushToast])

  const handleAddToCanvas = useCallback((sessionId: string) => {
    addSessionToCanvas(activeCanvasId, sessionId)
      .then(setCanvasList)
      .catch((err) => pushToast('error', (err as Error).message || 'Failed to add session to canvas'))
    setAddToCanvasRequest({ sessionId, bump: Date.now() })
  }, [activeCanvasId, pushToast])

  const handleHideFromCanvas = useCallback((sessionId: string) => {
    removeSessionFromCanvas(activeCanvasId, sessionId)
      .then(setCanvasList)
      .catch((err) => pushToast('error', (err as Error).message || 'Failed to hide session from canvas'))
    setHideFromCanvasRequest({ sessionId, bump: Date.now() })
  }, [activeCanvasId, pushToast])

  const handleBulkVisibility = useCallback((mode: 'show' | 'hide', sids?: string[]) => {
    const targetSids = sids ?? boardState.state?.sessions.map((s) => s.id) ?? []
    if (targetSids.length > 0) {
      Promise.all(
        targetSids.map((sid) =>
          mode === 'show'
            ? addSessionToCanvas(activeCanvasId, sid)
            : removeSessionFromCanvas(activeCanvasId, sid),
        ),
      )
        .then((results) => setCanvasList(results[results.length - 1]))
        .catch((err) => pushToast('error', (err as Error).message || 'Failed to update canvas sessions'))
    }
    setBulkVisibilityRequest({ mode, bump: Date.now(), sids })
  }, [activeCanvasId, boardState.state, pushToast])

  const handleSetActiveCanvas = useCallback((canvasId: string) => {
    updateCanvas(canvasId, { active: true })
      .then((list) => {
        setSelection({ kind: 'none' })
        setOnCanvasCounts({})
        setCanvasList(list)
      })
      .catch((err) => pushToast('error', (err as Error).message || 'Failed to switch canvas'))
  }, [pushToast])

  const handleCreateCanvas = useCallback((name: string, scope: CanvasScope) => {
    return createCanvas({ name, scope })
      .then((list) => {
        setSelection({ kind: 'none' })
        setOnCanvasCounts({})
        setCanvasList(list)
      })
  }, [])

  const handleCountsChange = useCallback(
    (counts: Record<string, number>) => {
      setOnCanvasCounts((prev) => {
        // Avoid causing re-renders when counts haven't actually changed.
        const keys = new Set([...Object.keys(prev), ...Object.keys(counts)])
        for (const k of keys) {
          if ((prev[k] ?? 0) !== (counts[k] ?? 0)) return counts
        }
        return prev
      })
    },
    [],
  )

  const handleSidebarSelectionChange = useCallback((next: Selection) => {
    setSelection(next)
    if (next.kind === 'session') {
      setFocusSessionRequest({ sessionId: next.sessionId, bump: performance.now() })
    }
  }, [])

  // Lazily fetch a template for a given sessionId. Per-card storage via
  // templateIdForSession. Falls back to DEFAULT_TEMPLATE when backend has
  // no entry for this session.
  const ensureTemplate = useCallback((sessionId: string) => {
    const id = templateIdForSession(sessionId)
    if (templateCache[id] !== undefined) return
    if (pendingTemplatesRef.current.has(id)) return
    pendingTemplatesRef.current.add(id)
    getTemplate(id)
      .then((entry) => {
        const src = entry?.source ?? DEFAULT_TEMPLATE
        setTemplateCache((prev) => ({ ...prev, [id]: src }))
      })
      .catch((e) => {
        console.warn('[App] getTemplate failed, using default:', (e as Error).message)
        setTemplateCache((prev) => ({ ...prev, [id]: DEFAULT_TEMPLATE }))
      })
      .finally(() => {
        pendingTemplatesRef.current.delete(id)
      })
  }, [templateCache])

  // Locally applied template source (from the editor) — write-through cache.
  const applyTemplateLocally = useCallback(
    (templateId: string, source: string) => {
      setTemplateCache((prev) => {
        if (prev[templateId] === source) {
          console.log('[App] applyTemplate noop (same) templateId=%s', templateId)
          return prev
        }
        console.log(
          '[App] applyTemplate templateId=%s prevLen=%d nextLen=%d',
          templateId,
          prev[templateId]?.length ?? 0,
          source.length,
        )
        return { ...prev, [templateId]: source }
      })
    },
    [],
  )

  // Global keyboard hijack: 选中 session 时画板上的可打印键决定 dock 的可见性：
  //   - dock 没开 → 把这次键值当 seed，setDockOpen(true)；mount 后 dock
  //     会消费 dockSeedRef 里的初始值。
  //   - dock 已开 → 直接调 appendAndFocus 注入到现有 textarea。
  //
  // 关键：用 capture 阶段 + stopImmediatePropagation —— Excalidraw 自己在
  // document 层装了 keydown handler（按字母就造文本元素），冒泡会被它抢先。
  // capture 先到再吃掉事件即可。
  //
  // ⚠️ 不再 hijack `paste` 事件 —— 之前为了"canvas 上 cmd+V 直接 seed dock"
  // 装了 window-level paste listener，但代价是 cmd+V 永远落不到 excalidraw
  // 自己的剪贴板 handler 上，"复制 session card / 粘贴图片到画板"全断。
  // 字母键 seed dock 的 affordance 已经够直观，cmd+V 让回 excalidraw 原生路径。
  const selectedSessionId =
    selection.kind === 'session' ? selection.sessionId : null

  // 切到另一个 session 时把 dock 重新指向新 session（issue #21：点画板空白
  // selection → none 不算切换，dock 保持打开 + 锚在原 session）。
  useEffect(() => {
    if (!selectedSessionId) return
    setDockSessionId(selectedSessionId)
    setAssistantRequested(false)
    dockSeedRef.current = ''
  }, [selectedSessionId])

  // Two distinct keystroke flows depending on selection:
  //   - A session is selected → the keystroke seeds the SessionDock for that
  //     session (existing behaviour).
  //   - Nothing selected (just the canvas) → the keystroke opens the
  //     "Ask & Spawn" assistant as a temporary global chatbox seeded with
  //     the keystroke. Same gesture, different target.
  // Don't fire when the user already has an open Excalidraw shape selected
  // (so they can still type into Excalidraw text shapes etc.). The
  // `selection.kind === 'session'` vs `'none'` split handles that.
  useEffect(() => {
    const isInputTarget = (t: EventTarget | null) => {
      if (!(t instanceof HTMLElement)) return false
      const tag = t.tagName
      return (
        tag === 'INPUT' ||
        tag === 'TEXTAREA' ||
        tag === 'SELECT' ||
        t.isContentEditable
      )
    }

    const dispatch = (text: string) => {
      if (dockOpen) {
        dockRef.current?.appendAndFocus(text)
        return
      }
      // Mount a fresh dock with this seed. selection 是 session → 自动走
      // session 模式；selection none → 强制 assistant 模式（hijack 只在
      // session-or-none 时触发，channel 选中时已经被前面的 guard 挡掉）。
      dockSeedRef.current = text
      if (!selectedSessionId) setAssistantRequested(true)
      setDockOpen(true)
    }

    const onKeyDown = (e: KeyboardEvent) => {
      if (isInputTarget(e.target)) return
      if (e.metaKey || e.ctrlKey || e.altKey) return
      // Plain Enter on empty canvas → open assistant with no seed (gesture
      // is "I want to chat", not "I typed Enter as content").
      if (
        e.key === 'Enter' &&
        !selectedSessionId &&
        selection.kind === 'none' &&
        !dockOpen
      ) {
        e.preventDefault()
        e.stopImmediatePropagation()
        setAssistantRequested(true)
        dockSeedRef.current = ''
        setDockOpen(true)
        return
      }
      // Plain Enter on a selected session → open Dock (transcript view) for
      // that session. Mirrors the double-click gesture; gives keyboard users
      // the same "show transcript" affordance.
      if (e.key === 'Enter' && selectedSessionId && !dockOpen) {
        e.preventDefault()
        e.stopImmediatePropagation()
        dockSeedRef.current = ''
        setDockOpen(true)
        return
      }
      if (e.key.length !== 1) return
      if (!selectedSessionId && selection.kind !== 'none') return
      e.preventDefault()
      e.stopImmediatePropagation()
      dispatch(e.key)
    }

    // Double-click anywhere on the canvas while a session is selected → open
    // its Dock. Excalidraw's own dblclick on a rect does selection but no
    // navigation; we layer the Dock-open gesture on top. We only fire when
    // the target is *outside* an input/composer (keep textarea dblclick =
    // word-select behaviour), and when a session is currently selected.
    const onDblClick = (e: MouseEvent) => {
      if (isInputTarget(e.target)) return
      if (!selectedSessionId) return
      if (dockOpen) return
      // Don't fight the Dock or any modal that explicitly absorbs dblclicks
      // (`.session-dock` is the Dock root; nothing else uses it).
      if (e.target instanceof Element && e.target.closest('.session-dock')) return
      dockSeedRef.current = ''
      setDockOpen(true)
    }

    // Canvas-level cmd+V hijack —— 选中 session card 后粘贴 → 自动开
    // dock + 把内容当 seed 灌进 textarea，不用先点输入框。三档分流：
    //   - target 是输入框（INPUT/TEXTAREA/contentEditable）：完全 pass-
    //       through（不 preventDefault / 不 stopPropagation），让原生
    //       paste flow 把内容插进 textarea。这条以前每次有人 stopPropagation
    //       都会把客户端里 textarea 粘贴一起搞挂。
    //   - 选中 session card + 非输入框：preventDefault + stopImmediate
    //       夺过事件 → dispatch 把文本灌进 dock（dock 没开就开 + seed，
    //       已开就 appendAndFocus）。
    //   - 没选 session（或 channel 选中等）+ 非输入框：完全放手，让
    //       Excalidraw 自己处理 canvas 上的粘贴。
    const onPaste = (e: ClipboardEvent) => {
      if (isInputTarget(e.target)) return
      if (!selectedSessionId) return
      // Excalidraw 自己的 clipboard payload（{"type":"excalidraw/clipboard"...}）
      // 不能塞进 dock，让它原生接。
      const types = e.clipboardData?.types ?? []
      if (
        types.includes('application/vnd.excalidraw+json') ||
        types.includes('application/vnd.excalidrawlib+json')
      ) {
        return
      }
      const text = e.clipboardData?.getData('text') ?? ''
      if (text.startsWith('{"type":"excalidraw/clipboard"')) return
      if (!text) return
      e.preventDefault()
      e.stopImmediatePropagation()
      dispatch(text)
    }

    window.addEventListener('keydown', onKeyDown, true)
    window.addEventListener('paste', onPaste, true)
    window.addEventListener('dblclick', onDblClick, true)
    return () => {
      window.removeEventListener('keydown', onKeyDown, true)
      window.removeEventListener('paste', onPaste, true)
      window.removeEventListener('dblclick', onDblClick, true)
    }
  }, [selectedSessionId, selection.kind, dockOpen])

  // Refetch currently-cached templates on every state tick. The backend may
  // emit a single state.changed frame after a template edit; rather than
  // tracking a diff, we just re-read what we already care about. This is
  // cheap because the cache set is small (one entry per unique pluginId).
  const stateChangedTick = boardState.state // proxy — changes on every WS tick
  useEffect(() => {
    // 只 refetch 已经从 backend 拉到真实 template 的条目。对 404 回退到
    // DEFAULT_TEMPLATE 的 id 跳过——否则每秒 WS tick 都会打一发 404，
    // 日志和网络都会被刷爆。用户在 editor 里存过之后 cache 变非默认值，
    // 自动进入 refetch 路径，热重载依旧工作。
    const ids = Object.keys(templateCache).filter(
      (id) => templateCache[id] !== DEFAULT_TEMPLATE,
    )
    if (ids.length === 0) return
    let cancelled = false
    ;(async () => {
      for (const id of ids) {
        try {
          const entry = await getTemplate(id)
          if (cancelled) return
          const next = entry?.source ?? DEFAULT_TEMPLATE
          setTemplateCache((prev) =>
            prev[id] === next ? prev : { ...prev, [id]: next },
          )
        } catch {
          // network blip — keep old cache; next tick will retry
        }
      }
    })()
    return () => {
      cancelled = true
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [stateChangedTick])

  // 等到所有 storage slot hydrate 完才渲染 Board —— Board 内部用 useRef 一次性
  // 接住 initial 值，hydrate 之前给它就只能拿空状态 / 闪屏。
  const canvasSessionIds = useMemo(() => {
    const ids = new Set<string>()
    for (const membership of canvasList?.memberships ?? []) {
      if (membership.canvasId === activeCanvasId && membership.visible) ids.add(membership.sessionId)
    }
    return ids
  }, [activeCanvasId, canvasList])

  const canvasBoardState = useMemo(() => {
    if (!boardState.state) return null
    return {
      ...boardState.state,
      sessions: boardState.state.sessions.filter((s) => canvasSessionIds.has(s.id)),
    }
  }, [boardState.state, canvasSessionIds])

  if (!hydrated || !canvasList) {
    return (
      <div className="app boot">
        <div className="boot-spinner" />
      </div>
    )
  }

  return (
    <ToastContext.Provider value={toastCtx}>
      <div className="app">
        <div className="board-area">
          <Board
            key={activeCanvasId}
            persistence={persistence}
            initial={hydrated}
            state={canvasBoardState}
            selection={selection}
            onSelectionChange={setSelection}
            fitSignal={fitSignal}
            addToCanvasRequest={addToCanvasRequest}
            hideFromCanvasRequest={hideFromCanvasRequest}
            bulkVisibilityRequest={bulkVisibilityRequest}
            focusSessionRequest={focusSessionRequest}
            onCountsChange={handleCountsChange}
            templateCache={templateCache}
            onNeedTemplate={ensureTemplate}
            unreadSids={unreadSids}
            onRefresh={() => {
              boardState.refresh()
              void refreshCanvases()
            }}
            onNewChannel={() => setNewChannelOpen(true)}
            placeChannelRequest={placeChannelRequest}
            onNewSession={() => setNewSessionOpen(true)}
            onAskAndSpawn={() => {
              setSelection({ kind: 'none' })
              setAssistantRequested(true)
              dockSeedRef.current = ''
              setDockOpen(true)
            }}
            onPreferences={() => setPreferencesOpen(true)}
            onFit={() => setFitSignal((x) => x + 1)}
          />
          {boardState.error && (
            <div className="inline-error" style={{ position: 'absolute', bottom: 8, left: 12 }}>
              {boardState.error}
            </div>
          )}
          {/* 统一 Dock 入口：mode 由 selection + assistantRequested 决定。
              session-mode：现有 session 的 transcript + injectToSession。
              assistant-mode：AI 对话 + spawnSession。
              Esc / × 关闭：session 模式保留 selection，assistant 模式清
              assistantRequested。下次再按键又能重开。 */}
          {dockOpen && boardState.state && (() => {
            // dockSessionId 是 dock 自己锚定的 session（不跟随 selection 清空），
            // 这样画板空白点击不会让 transcript 收起。
            const sessionForDock = dockSessionId
              ? boardState.state.sessions.find((x) => x.id === dockSessionId)
              : undefined
            const useAssistant = assistantRequested || !sessionForDock
            const mode: DockMode = useAssistant
              ? {
                  kind: 'assistant',
                  messages: assistantMessages,
                  setMessages: setAssistantMessages,
                  onSpawned: (cwd) => {
                    setDockOpen(false)
                    setDockSessionId(null)
                    setAssistantRequested(false)
                    pushToast('success', `Spawning Claude in ${cwd}`)
                  },
                  onError: (msg) => pushToast('error', msg),
                }
              : {
                  kind: 'session',
                  state: boardState.state,
                  session: sessionForDock!,
                }
            return (
              <Dock
                ref={dockRef}
                mode={mode}
                initialSeed={dockSeedRef.current}
                onClose={() => {
                  setDockOpen(false)
                  setDockSessionId(null)
                  if (useAssistant) setAssistantRequested(false)
                }}
              />
            )
          })()}
        </div>
        <Sidebar
          state={boardState.state}
          canvases={canvasList.canvases}
          activeCanvasId={activeCanvasId}
          onActiveCanvasChange={handleSetActiveCanvas}
          onCreateCanvas={handleCreateCanvas}
          selection={selection}
          open={sidebarOpen}
          onClose={() => setSidebarOpen(false)}
          onOpen={() => setSidebarOpen(true)}
          onSelectionChange={handleSidebarSelectionChange}
          onCanvasCounts={onCanvasCounts}
          unreadSids={unreadSids}
          onAddToCanvas={handleAddToCanvas}
          onHideFromCanvas={handleHideFromCanvas}
          onBulkVisibility={handleBulkVisibility}
          onNewSession={() => {
            // New session 入口 = 打开 Dock 的 assistant 模式（无 seed）
            setSelection({ kind: 'none' })
            setAssistantRequested(true)
            dockSeedRef.current = ''
            setDockOpen(true)
          }}
          onCreateInProject={(cwd) => {
            // 同一个入口，只是 seed 里把 cwd 写死，AI 直接出 spawn fence
            setSelection({ kind: 'none' })
            setAssistantRequested(true)
            dockSeedRef.current = `在 ${cwd} 下新建一个 session，`
            setDockOpen(true)
          }}
        />
        {newChannelOpen && boardState.state && (
          <NewChannelDialog
            state={boardState.state}
            onClose={() => setNewChannelOpen(false)}
            onCreated={(name) => {
              setNewChannelOpen(false)
              setSelection({ kind: 'channel', channelName: name })
              setPlaceChannelRequest({ channelName: name, bump: Date.now() })
              pushToast('success', `Channel "${name}" created`)
            }}
          />
        )}
        {newSessionOpen && (
          <NewSessionDialog
            defaultCwd={newSessionDefaultCwd}
            onClose={() => {
              setNewSessionOpen(false)
              setNewSessionDefaultCwd(undefined)
            }}
            onSpawned={(cwd) => {
              setNewSessionOpen(false)
              setNewSessionDefaultCwd(undefined)
              pushToast('success', `Spawning Claude in ${cwd}`)
            }}
            onError={(msg) => pushToast('error', msg)}
          />
        )}
        {/* 旧的独立 AssistantChat 模态已合并进上面的 <Dock mode='assistant'>。 */}
        {preferencesOpen && (
          <PreferencesDialog
            onClose={() => setPreferencesOpen(false)}
            onSaved={(cmd) => pushToast('success', `Default spawn command: ${cmd}`)}
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
