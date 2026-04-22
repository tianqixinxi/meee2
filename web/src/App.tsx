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
import { useBoardState } from './useBoardState'
import type { Selection } from './types'
import { DEFAULT_TEMPLATE } from './defaultTemplate'
import { getTemplate, templateIdForPlugin } from './cardTemplateStore'

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
  // Template cache: templateId → raw TSX source. Missing keys fall back to
  // DEFAULT_TEMPLATE. Populated lazily as pluginIds show up on screen, and
  // refetched on WS state.changed ticks (Wave 17a backend signals template
  // changes via the same channel).
  const [templateCache, setTemplateCache] = useState<Record<string, string>>({})
  // Track in-flight fetches so we don't hammer the backend when many CardHosts
  // ask for the same pluginId at once.
  const pendingTemplatesRef = useRef<Set<string>>(new Set())

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

  // Lazily fetch a template for a given pluginId. Falls back to
  // DEFAULT_TEMPLATE on 404 and caches the result.
  const ensureTemplate = useCallback((pluginId: string) => {
    const id = templateIdForPlugin(pluginId)
    if (templateCache[id] !== undefined) return
    if (pendingTemplatesRef.current.has(id)) return
    pendingTemplatesRef.current.add(id)
    getTemplate(id)
      .then((entry) => {
        const src = entry?.source ?? DEFAULT_TEMPLATE
        setTemplateCache((prev) => ({ ...prev, [id]: src }))
      })
      .catch((e) => {
        // Fall back to the bundled default so cards still render when the
        // backend is unreachable or not implementing the endpoint yet.
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
            onRefresh={() => boardState.refresh()}
            onNewChannel={() => setNewChannelOpen(true)}
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
