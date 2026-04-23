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
import NewChannelDialog from './components/NewChannelDialog'
import { SessionComposer } from './components/SessionComposer'
import { NewSessionDialog } from './components/NewSessionDialog'
import { useBoardState } from './useBoardState'
import type { Selection } from './types'
import { DEFAULT_TEMPLATE } from './defaultTemplate'
import { getTemplate, templateIdForSession } from './cardTemplateStore'
import {
  loadUnreadSids,
  saveUnreadSids,
  WORKING_STATUSES,
  RESTING_STATUSES,
} from './notifications'

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
  const boardState = useBoardState()
  const [selection, setSelection] = useState<Selection>({ kind: 'none' })
  const [sidebarOpen, setSidebarOpen] = useState(true)
  const [newChannelOpen, setNewChannelOpen] = useState(false)
  const [newSessionOpen, setNewSessionOpen] = useState(false)
  // 每个 session 的"未读通知"集合：status 从工作态 → 休息态转换时加入；
  // 用户点击 session card 时移除。持久化到 localStorage。
  const [unreadSids, setUnreadSids] = useState<Set<string>>(loadUnreadSids)
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
  const [onCanvasCounts, setOnCanvasCounts] = useState<Record<string, number>>(
    {},
  )
  // 选中 session 时，任意键盘/粘贴输入会打开一个底部 composer，按 Enter 把
  // 消息直接注入该 session 的 inbox（下一轮 Claude 能看到）
  const [composer, setComposer] = useState<
    { sessionId: string; seed: string } | null
  >(null)
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
      if (changed) saveUnreadSids(newSet)
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
      saveUnreadSids(next)
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
    setAddToCanvasRequest({ sessionId, bump: Date.now() })
  }, [])

  const handleHideFromCanvas = useCallback((sessionId: string) => {
    setHideFromCanvasRequest({ sessionId, bump: Date.now() })
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

  // Global keyboard/paste hijack: when a session is selected, any printable
  // keystroke or paste opens the bottom composer seeded with that input.
  // Inputs/textareas (including the composer itself) keep normal behavior.
  //
  // 关键：用 capture 阶段 + stopImmediatePropagation —— Excalidraw 自己在
  // document 层装了 keydown/paste handler（按字母就造文本元素、粘贴生成
  // 图片等），如果我们走冒泡会被它抢先。capture 阶段先到、再 preventDefault +
  // stopImmediatePropagation 把事件彻底吃掉。
  const selectedSessionId =
    selection.kind === 'session' ? selection.sessionId : null
  useEffect(() => {
    if (!selectedSessionId) return

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

    const onKeyDown = (e: KeyboardEvent) => {
      const targetTag =
        e.target instanceof HTMLElement ? e.target.tagName : '(?)'
      // 所有 keydown 都打，方便用 DevTools Console 诊断
      console.log(
        '[Composer] keydown captured key=%s target=%s composer=%s inputTarget=%s',
        e.key,
        targetTag,
        composer ? 'open' : 'null',
        isInputTarget(e.target),
      )
      if (composer) return
      if (isInputTarget(e.target)) return
      if (e.metaKey || e.ctrlKey || e.altKey) return
      if (e.key.length !== 1) return
      console.log('[Composer] → opening with seed=%s', e.key)
      e.preventDefault()
      e.stopImmediatePropagation()
      setComposer({ sessionId: selectedSessionId, seed: e.key })
    }

    const onPaste = (e: ClipboardEvent) => {
      const targetTag =
        e.target instanceof HTMLElement ? e.target.tagName : '(?)'
      const text = e.clipboardData?.getData('text') ?? ''
      console.log(
        '[Composer] paste captured target=%s textLen=%d composer=%s inputTarget=%s',
        targetTag,
        text.length,
        composer ? 'open' : 'null',
        isInputTarget(e.target),
      )
      if (composer) return
      if (isInputTarget(e.target)) return
      if (!text) return
      console.log('[Composer] → opening with pasted text (len=%d)', text.length)
      e.preventDefault()
      e.stopImmediatePropagation()
      setComposer({ sessionId: selectedSessionId, seed: text })
    }

    // window + capture 是 DOM 事件流最早能 hook 的位置；Excalidraw 不管在
    // document 还是 canvas 上装 handler，都会晚于这里。
    window.addEventListener('keydown', onKeyDown, true)
    window.addEventListener('paste', onPaste, true)
    return () => {
      window.removeEventListener('keydown', onKeyDown, true)
      window.removeEventListener('paste', onPaste, true)
    }
  }, [selectedSessionId, composer])

  // 选中 session 切换 / 取消选择时，关掉正在输入的 composer
  useEffect(() => {
    if (composer && composer.sessionId !== selectedSessionId) {
      setComposer(null)
    }
  }, [selectedSessionId, composer])

  const composerSession =
    composer && boardState.state
      ? boardState.state.sessions.find((s) => s.id === composer.sessionId) ??
        null
      : null

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

  return (
    <ToastContext.Provider value={toastCtx}>
      <div className="app">
        <div className="board-area">
          <Board
            state={boardState.state}
            selection={selection}
            onSelectionChange={setSelection}
            fitSignal={fitSignal}
            addToCanvasRequest={addToCanvasRequest}
            hideFromCanvasRequest={hideFromCanvasRequest}
            onCountsChange={handleCountsChange}
            templateCache={templateCache}
            onNeedTemplate={ensureTemplate}
            unreadSids={unreadSids}
            onRefresh={() => boardState.refresh()}
            onNewChannel={() => setNewChannelOpen(true)}
            onNewSession={() => setNewSessionOpen(true)}
            onFit={() => setFitSignal((x) => x + 1)}
          />
          {boardState.error && (
            <div className="inline-error" style={{ position: 'absolute', bottom: 8, left: 12 }}>
              {boardState.error}
            </div>
          )}
        </div>
        <Sidebar
          state={boardState.state}
          selection={selection}
          open={sidebarOpen}
          onClose={() => setSidebarOpen(false)}
          onOpen={() => setSidebarOpen(true)}
          onSelectionChange={setSelection}
          onCanvasCounts={onCanvasCounts}
          onAddToCanvas={handleAddToCanvas}
          onHideFromCanvas={handleHideFromCanvas}
          onTemplateSaved={applyTemplateLocally}
        />
        {newChannelOpen && boardState.state && (
          <NewChannelDialog
            state={boardState.state}
            onClose={() => setNewChannelOpen(false)}
            onCreated={(name) => {
              setNewChannelOpen(false)
              setSelection({ kind: 'channel', channelName: name })
              pushToast('success', `Channel "${name}" created`)
            }}
          />
        )}
        {newSessionOpen && (
          <NewSessionDialog
            onClose={() => setNewSessionOpen(false)}
            onSpawned={(cwd) => {
              setNewSessionOpen(false)
              pushToast('success', `Spawning Claude in ${cwd}`)
            }}
            onError={(msg) => pushToast('error', msg)}
          />
        )}
        <SessionComposer
          session={composerSession}
          seedContent={composer?.seed ?? ''}
          onClose={() => setComposer(null)}
        />
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
