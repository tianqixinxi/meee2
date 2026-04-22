import { useEffect, useMemo, useRef, useState } from 'react'
import {
  Excalidraw,
  Footer,
  MainMenu,
  convertToExcalidrawElements,
} from '@excalidraw/excalidraw'
import type {
  ExcalidrawImperativeAPI,
  AppState,
} from '@excalidraw/excalidraw/types/types'
import type { ExcalidrawElement } from '@excalidraw/excalidraw/types/element/types'

import type { BoardState, Selection } from '../types'
import {
  buildScene,
  buildSessionEmbeddable,
  isManagedElementId,
  parseSessionLink,
  parseSessionFromElement,
  resolveChannelFromElementId,
  sessionRectId,
} from '../scene'
import {
  debounce,
  ensurePositions,
  loadLayout,
  saveLayout,
  type LayoutMap,
} from '../layout'
import { loadDismissed, saveDismissed } from '../dismissed'
import { activateSession } from '../api'
import { SessionOverlay } from './SessionOverlay'

// Inline feather-style icons used by MainMenu / Footer. 16px, stroke=1.75.
function RefreshIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor"
         strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round">
      <path d="M21 12a9 9 0 1 1-3-6.7" />
      <polyline points="21 3 21 9 15 9" />
    </svg>
  )
}
function PlusSquareIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor"
         strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round">
      <rect x="3" y="3" width="18" height="18" rx="2" />
      <line x1="12" y1="8" x2="12" y2="16" />
      <line x1="8" y1="12" x2="16" y2="12" />
    </svg>
  )
}
function ExternalLinkIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor"
         strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round">
      <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6" />
      <polyline points="15 3 21 3 21 9" />
      <line x1="10" y1="14" x2="21" y2="3" />
    </svg>
  )
}
function FitIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor"
         strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round">
      <polyline points="4 14 10 14 10 20" />
      <polyline points="20 10 14 10 14 4" />
      <line x1="14" y1="10" x2="21" y2="3" />
      <line x1="3" y1="21" x2="10" y2="14" />
    </svg>
  )
}

interface Props {
  state: BoardState | null
  selection: Selection
  onSelectionChange: (s: Selection) => void
  /** Increments each time Fit button is pressed. */
  fitSignal: number
  /**
   * Requests inserting a new embeddable for the given session id. The bump
   * counter changes on each request so the same session id can be inserted
   * multiple times back-to-back.
   */
  addToCanvasRequest: { sessionId: string; bump: number } | null
  /**
   * Requests removing all rects for the given session id. The bump counter
   * changes on each request so repeat clicks can re-trigger.
   */
  hideFromCanvasRequest: { sessionId: string; bump: number } | null
  /**
   * Reports how many embeddable instances exist per sessionId on the canvas.
   * Used by the sidebar to show "on canvas / off canvas" indicators.
   */
  onCountsChange: (counts: Record<string, number>) => void
  /** templateId → raw TSX source. App-level cache. */
  templateCache: Record<string, string>
  /** Fires on first render for a pluginId we haven't fetched yet. */
  onNeedTemplate: (pluginId: string) => void
  /** Invoked from the <Footer> refresh button. */
  onRefresh: () => void
  /** Invoked from the <MainMenu> "New channel" item. */
  onNewChannel: () => void
  /** Invoked from the <MainMenu> "Fit to content" item. */
  onFit: () => void
}

export default function Board({
  state,
  selection,
  onSelectionChange,
  fitSignal,
  addToCanvasRequest,
  hideFromCanvasRequest,
  onCountsChange,
  templateCache,
  onNeedTemplate,
  onRefresh,
  onNewChannel,
  onFit,
}: Props) {
  const [api, setApi] = useState<ExcalidrawImperativeAPI | null>(null)
  const layoutRef = useRef<LayoutMap>(loadLayout())
  const saveLayoutDebounced = useMemo(
    () => debounce((m: LayoutMap) => saveLayout(m), 400),
    [],
  )
  // Sids the user has explicitly removed from canvas (last copy deleted).
  // Persisted so auto-re-add doesn't fight the user across WS ticks / reloads.
  const dismissedRef = useRef<Set<string>>(loadDismissed())
  // Previous per-sid card count, used to detect >0 → 0 transitions in onChange.
  const prevCountsRef = useRef<Record<string, number>>({})
  const lastAddBumpRef = useRef<number>(-1)
  const lastHideBumpRef = useRef<number>(-1)
  // Last Excalidraw selection signature we processed. Used to skip re-firing
  // sidebar updates on WS ticks where selection didn't actually change.
  const prevSelSigRef = useRef<string>('')
  // Tracks the last embeddable id we saw `activeEmbeddable.state === 'active'`
  // for. Prevents re-firing `activateSession` every frame while the embeddable
  // stays active.
  const lastActivatedElementIdRef = useRef<string | null>(null)

  // Reports per-session embeddable counts to the parent. Wrapped in a ref so
  // our effects don't capture stale callbacks across React re-renders.
  const onCountsChangeRef = useRef(onCountsChange)
  onCountsChangeRef.current = onCountsChange
  const reportCountsRef = useRef(
    (elements: readonly ExcalidrawElement[]) => {
      const counts: Record<string, number> = {}
      for (const el of elements) {
        // Session cards are plain rectangles with customData.sessionId.
        if (el.type !== 'rectangle') continue
        if ((el as any).isDeleted) continue
        const sid = parseSessionFromElement(el)
        if (!sid) continue
        counts[sid] = (counts[sid] ?? 0) + 1
      }

      // Detect last-card deletion: sid was present last tick, gone now →
      // remember user intent so next WS tick doesn't auto-re-add.
      const prev = prevCountsRef.current
      const dropped: string[] = []
      const appeared: string[] = []
      let dismissedChanged = false
      for (const sid of Object.keys(prev)) {
        if ((prev[sid] ?? 0) > 0 && !(sid in counts)) {
          dropped.push(sid)
          if (!dismissedRef.current.has(sid)) {
            dismissedRef.current.add(sid)
            dismissedChanged = true
          }
        }
      }
      // Reverse: sid that re-appears on canvas (e.g. via Add-to-canvas or Undo)
      // clears its dismissal. Only clear when sid was ABSENT before (transition
      // 0 → >0), not on every tick where the sid is present — otherwise the
      // forward pass would re-dismiss it next tick, then this reverse pass
      // would undo it, and we'd oscillate. On a plain "rect still there" tick
      // both prev and counts have the sid, so no transition, no touch.
      for (const sid of Object.keys(counts)) {
        if (counts[sid] > 0 && !(sid in prev)) {
          appeared.push(sid)
          if (dismissedRef.current.delete(sid)) {
            dismissedChanged = true
          }
        }
      }
      if (dropped.length || appeared.length) {
        console.log(
          '[Board.counts]',
          'dropped=', dropped.map(s => s.slice(0, 8)),
          'appeared=', appeared.map(s => s.slice(0, 8)),
          'dismissed=', [...dismissedRef.current].map(s => s.slice(0, 8)),
        )
      }
      if (dismissedChanged) saveDismissed(dismissedRef.current)
      prevCountsRef.current = counts

      onCountsChangeRef.current(counts)
    },
  )

  // -- Always-allow validator for our custom link scheme ------------------
  // Excalidraw normally checks embeddable links against an allowlist (known
  // hosts like YouTube, Figma, ...). Our `meee2://session/<id>` links don't
  // match, and the embeddable would render blank. Returning `true` lets our
  // `renderEmbeddable` callback own the render surface.
  const validateEmbeddable = useMemo(
    () => (_link: string) => true,
    [],
  )

  // -- Scene rebuild on state change -------------------------------------
  useEffect(() => {
    if (!api || !state) return

    const ids = state.sessions.map((s) => s.id)
    layoutRef.current = ensurePositions(ids, layoutRef.current)
    saveLayoutDebounced(layoutRef.current)

    // Current scene → classify existing elements.
    const existing = api.getSceneElements()
    const userShapes = existing.filter((e) => !isManagedElementId(e.id))
    const existingEmbeddables = existing.filter(
      (e) =>
        e.type === 'rectangle' &&
        parseSessionFromElement(e) !== null,
    )

    const knownSessionIds = new Set<string>()
    for (const e of existingEmbeddables) {
      const sid = parseSessionFromElement(e)
      if (sid) knownSessionIds.add(sid)
    }

    // A session appears first-time on the canvas → create one embeddable.
    // Sessions the user has explicitly removed (dismissed) are NOT re-added —
    // they stay off the canvas until the user clicks "Add to canvas" again.
    const newSessionIds: string[] = []
    for (const sid of ids) {
      if (knownSessionIds.has(sid)) continue
      if (dismissedRef.current.has(sid)) continue
      newSessionIds.push(sid)
    }

    // Only log when something interesting happens (new rects / dismissed
    // count). Keeps console clean on every WS tick.
    if (newSessionIds.length > 0 || dismissedRef.current.size > 0) {
      console.log(
        '[Board.scene] new=%d dismissed=%d',
        newSessionIds.length,
        dismissedRef.current.size,
      )
    }

    // Resolve "primary" embeddable id per session id for arrow binding.
    const primaryMap = new Map<string, string>()
    for (const e of existingEmbeddables) {
      const sid = parseSessionFromElement(e)
      if (sid && !primaryMap.has(sid)) primaryMap.set(sid, e.id)
    }
    for (const sid of newSessionIds) {
      if (!primaryMap.has(sid)) primaryMap.set(sid, sessionRectId(sid))
    }

    const { newEmbeddables, arrows } = buildScene(state, layoutRef.current, {
      newSessionIds,
      sessionIdToElementId: (sid) => primaryMap.get(sid) ?? null,
    })

    const converted = convertToExcalidrawElements(
      [...newEmbeddables, ...arrows] as any,
      { regenerateIds: false },
    )

    const preservedExisting = [
      ...userShapes,
      ...existingEmbeddables,
    ]

    const finalElements = [...preservedExisting, ...converted]
    api.updateScene({
      elements: finalElements as any,
    })
    // Report counts (preserved existing + newly converted embeddables).
    reportCountsRef.current(finalElements)
  }, [api, state, saveLayoutDebounced])

  // -- Fit-to-content --------------------------------------------------
  useEffect(() => {
    if (!api || fitSignal === 0) return
    const elements = api.getSceneElements()
    if (elements.length > 0) {
      api.scrollToContent(elements, { fitToContent: true, animate: true })
    }
  }, [api, fitSignal])

  // -- Sync sessions → Excalidraw library panel ------------------------
  // 让用户按 `9` 打开 library → 看到每个 session 作为 library item → 拖到画布
  // 就是一个新的 embeddable 实例。相当于原生的"Add to canvas"交互。
  // 每次 state 变化 replace 整个 library（`merge: false`），保证列表和 state
  // 同步（dead session 从 library 里消失，新 session 自动出现）。
  useEffect(() => {
    if (!api || !state) return
    const items = state.sessions.map((s) => {
      const skeleton = buildSessionEmbeddable(s, 0, 0, sessionRectId(s.id))
      const [el] = convertToExcalidrawElements([skeleton] as any, {
        regenerateIds: false,
      })
      return {
        id: `lib-session-${s.id}`,
        status: 'unpublished' as const,
        elements: [el] as any,
        created: Date.now(),
        name: `${s.title} · ${s.pluginDisplayName}`,
      }
    })
    api.updateLibrary({ libraryItems: items, merge: false }).catch((e) => {
      console.warn('[Board] updateLibrary failed', e)
    })
  }, [api, state])

  // -- Add-to-canvas from sidebar -------------------------------------
  useEffect(() => {
    if (!api || !state || !addToCanvasRequest) return
    if (addToCanvasRequest.bump === lastAddBumpRef.current) return
    lastAddBumpRef.current = addToCanvasRequest.bump

    const session = state.sessions.find(
      (s) => s.id === addToCanvasRequest.sessionId,
    )
    if (!session) return

    // User explicitly brought this session back — undo any prior dismissal.
    if (dismissedRef.current.delete(session.id)) {
      saveDismissed(dismissedRef.current)
    }

    const appState = api.getAppState()
    // Drop the new card near the current viewport center (in canvas coords).
    const viewW = appState.width ?? 800
    const viewH = appState.height ?? 600
    const zoom = appState.zoom.value || 1
    const cx = -appState.scrollX + viewW / zoom / 2
    const cy = -appState.scrollY + viewH / zoom / 2
    const jitter = () => Math.round((Math.random() - 0.5) * 60)
    const x = Math.round(cx - 180) + jitter()
    const y = Math.round(cy - 130) + jitter()

    // Generate a unique id so this is an independent instance alongside any
    // existing embeddable for the same session.
    const newId = `session-${session.id}-${Date.now().toString(36)}`
    const skeleton = buildSessionEmbeddable(session, x, y, newId)
    const [built] = convertToExcalidrawElements([skeleton] as any, {
      regenerateIds: false,
    })
    if (!built) return

    const next = [...api.getSceneElements(), built]
    api.updateScene({ elements: next as any })
    reportCountsRef.current(next)

    // Scroll the new element into view.
    api.scrollToContent([built], { fitToContent: false, animate: true })
  }, [api, state, addToCanvasRequest])

  // -- Hide-from-canvas from sidebar (eye 👁 toggle off) ---------------
  // Deletes all rects with customData.sessionId === sid. The
  // reportCountsRef's >0→0 detection will add sid to dismissed so next WS
  // tick doesn't auto-re-add.
  useEffect(() => {
    if (!api || !hideFromCanvasRequest) return
    if (hideFromCanvasRequest.bump === lastHideBumpRef.current) return
    lastHideBumpRef.current = hideFromCanvasRequest.bump

    const sid = hideFromCanvasRequest.sessionId
    const existing = api.getSceneElements()
    // Mark matching rects as deleted. Keeping them in the array (with
    // isDeleted: true) rather than splicing out preserves Excalidraw's Undo.
    const next = existing.map((el) => {
      if (el.type !== 'rectangle') return el
      if (parseSessionFromElement(el) !== sid) return el
      return { ...el, isDeleted: true }
    })
    api.updateScene({ elements: next as any })
    reportCountsRef.current(next)
  }, [api, hideFromCanvasRequest])

  // -- Multi-select all cards for the sidebar-selected session --------
  // When sidebar selects a session, highlight every rect on canvas with
  // that sessionId. Only runs when selection or state changes (not every
  // frame) to avoid fighting user's own click-selection.
  useEffect(() => {
    if (!api) return
    if (selection.kind !== 'session') return
    const sid = selection.sessionId
    const elements = api.getSceneElements()
    const matchIds: string[] = []
    for (const el of elements) {
      if (el.type !== 'rectangle') continue
      if ((el as any).isDeleted) continue
      if (parseSessionFromElement(el) !== sid) continue
      matchIds.push(el.id)
    }
    if (matchIds.length === 0) return
    const selected: Record<string, true> = {}
    for (const id of matchIds) selected[id] = true
    try {
      api.updateScene({
        appState: { selectedElementIds: selected } as any,
      })
    } catch (e) {
      console.warn('[Board] multi-select update failed', e)
    }
  }, [api, selection, state])

  // -- onChange: capture movement + selection --------------------------
  const handleChange = useMemo(() => {
    let dragging = false
    return (elements: readonly ExcalidrawElement[], appState: AppState) => {
      if (!state) return

      // -- Double-click → activate (terminal jump) --------------------------
      // Excalidraw sets `appState.activeEmbeddable` when the user double-clicks
      // an embeddable. We never actually want an "active" embeddable (we don't
      // render a native iframe), so we use that signal purely as an activation
      // gesture: call activateSession for the mapped sid and then clear the
      // active state on the next tick so the user can activate the same card
      // again.
      const active = (appState as any).activeEmbeddable as
        | { element: { id: string }; state: string }
        | null
        | undefined
      if (
        active &&
        active.state === 'active' &&
        active.element &&
        active.element.id !== lastActivatedElementIdRef.current
      ) {
        const activeElId = active.element.id
        const el = elements.find((e) => e.id === activeElId)
        const sid = el ? parseSessionFromElement(el) : null
        if (sid) {
          lastActivatedElementIdRef.current = activeElId
          console.log('[Board] activateSession via embeddable double-click', sid.slice(0, 8))
          void activateSession(sid)
          // Clear active state so the same card can be re-activated, and so
          // Excalidraw doesn't keep a no-op "activated" embeddable in memory.
          setTimeout(() => {
            if (!api) return
            try {
              api.updateScene({
                appState: { activeEmbeddable: null } as any,
              })
            } catch (e) {
              console.warn('[Board] clear activeEmbeddable failed', e)
            }
            lastActivatedElementIdRef.current = null
          }, 50)
        }
      } else if (!active || active.state !== 'active') {
        lastActivatedElementIdRef.current = null
      }

      // selection tracking — sidebar shows:
      //   • 1 rect of single session (or N rects all same session) → session detail
      //   • 1 channel arrow                                         → channel detail
      //   • 0 rects, or rects spanning 2+ sessions, or any mix     → session list
      //
      // We guard with a signature ref so WS ticks that don't actually change
      // the selection don't thrash the sidebar (see prevSelSigRef init).
      const selIds = Object.keys(appState.selectedElementIds ?? {})
      const selSig = selIds.slice().sort().join(',')
      if (selSig !== prevSelSigRef.current) {
        prevSelSigRef.current = selSig

        // Classify selection
        const uniqueSids = new Set<string>()
        let channelName: string | null = null
        let hasNonSessionNonChannel = false
        for (const id of selIds) {
          const el = elements.find((e) => e.id === id)
          if (!el) continue
          if (el.type === 'rectangle') {
            const sid = parseSessionFromElement(el)
            if (sid) {
              uniqueSids.add(sid)
              continue
            }
          }
          if (el.id.startsWith('channel-')) {
            const ch = resolveChannelFromElementId(el.id, state.channels)
            if (ch) {
              channelName = channelName ?? ch.name
              continue
            }
          }
          hasNonSessionNonChannel = true
        }

        let next: Selection = { kind: 'none' }
        if (
          !hasNonSessionNonChannel &&
          channelName === null &&
          uniqueSids.size === 1
        ) {
          const [sid] = [...uniqueSids]
          next = { kind: 'session', sessionId: sid }
        } else if (
          !hasNonSessionNonChannel &&
          uniqueSids.size === 0 &&
          channelName !== null &&
          selIds.length === 1
        ) {
          next = { kind: 'channel', channelName }
        }

        const cur = selection
        const same =
          (cur.kind === 'none' && next.kind === 'none') ||
          (cur.kind === 'session' && next.kind === 'session' && cur.sessionId === next.sessionId) ||
          (cur.kind === 'channel' && next.kind === 'channel' && cur.channelName === next.channelName)
        if (!same) {
          onSelectionChange(next)
        }
      }

      // 隐藏 Excalidraw 的 "选中样式面板" 仅当只选了我们托管的 session/channel
      // 元素（embeddable/channel-*）——不影响用户选自己 shape 的情况。
      const onlyManaged =
        selIds.length > 0 &&
        selIds.every((id) => {
          const el = elements.find((e) => e.id === id)
          if (!el) return false
          if (el.type === 'rectangle' && parseSessionFromElement(el)) {
            return true
          }
          return id.startsWith('channel-')
        })
      const host = document.querySelector('.excalidraw')
      if (host) {
        host.classList.toggle('board--hide-shape-actions', onlyManaged)
      }

      // Movement tracking. For layout persistence we save position *per
      // session id*, keyed to the first embeddable we see for that sid.
      const draggingNow = !!appState.draggingElement
      if (draggingNow) dragging = true
      const movementCaptureDue = dragging && !draggingNow
      if (draggingNow || movementCaptureDue) {
        let changed = false
        const next: LayoutMap = { ...layoutRef.current }
        // First rect per session → canonical position.
        const seen = new Set<string>()
        for (const el of elements) {
          if (el.type !== 'rectangle') continue
          if ((el as any).isDeleted) continue
          const sid = parseSessionFromElement(el)
          if (!sid || seen.has(sid)) continue
          seen.add(sid)
          const prev = next[sid]
          if (!prev || prev.x !== el.x || prev.y !== el.y) {
            next[sid] = { x: el.x, y: el.y }
            changed = true
          }
        }
        if (changed) {
          layoutRef.current = next
          saveLayoutDebounced(next)
        }
      }
      if (movementCaptureDue) {
        dragging = false
      }

      // Report counts on every change so sidebar stays in sync with
      // copy/paste/delete performed natively by Excalidraw.
      reportCountsRef.current(elements)
    }
  }, [state, selection, onSelectionChange, saveLayoutDebounced, api])

  // -- Minimal UI options --------------------------------------------
  const uiOptions = useMemo(
    () => ({
      canvasActions: {
        loadScene: false,
        saveToActiveFile: false,
        export: false,
        toggleTheme: false,
        clearCanvas: false,
        changeViewBackgroundColor: false,
      },
      tools: { image: false },
    }),
    [],
  )

  // -- renderEmbeddable: Wave 18 — the real card is rendered by
  // `<SessionOverlay>` (a sibling overlay div). We still need to pass
  // `renderEmbeddable` so Excalidraw doesn't attempt its default link-fetch
  // iframe behavior. Returning `null` keeps the embeddable in the scene
  // (for selection/copy/delete/library) but paints nothing in the hidden
  // native container.
  const renderEmbeddable = useMemo(
    () => (_element: unknown, _appState: AppState) => null,
    [],
  )

  return (
    <div style={{ width: '100%', height: '100%', position: 'relative' }}>
      <Excalidraw
        theme="dark"
        excalidrawAPI={(a) => setApi(a)}
        onChange={handleChange}
        UIOptions={uiOptions as any}
        viewModeEnabled={false}
        gridModeEnabled={false}
      >
        <MainMenu>
          <MainMenu.Item onSelect={onNewChannel} icon={<PlusSquareIcon />}>
            New channel
          </MainMenu.Item>
          <MainMenu.Item onSelect={onFit} icon={<FitIcon />}>
            Fit to content
          </MainMenu.Item>
          <MainMenu.Item onSelect={onRefresh} icon={<RefreshIcon />}>
            Refresh
          </MainMenu.Item>
          <MainMenu.Separator />
          <MainMenu.ItemLink
            href="https://two.meee1.com"
            icon={<ExternalLinkIcon />}
          >
            meee2 homepage
          </MainMenu.ItemLink>
          <MainMenu.ItemLink
            href="https://github.com/meee1/meee2"
            icon={<ExternalLinkIcon />}
          >
            GitHub
          </MainMenu.ItemLink>
          <MainMenu.Separator />
          <MainMenu.DefaultItems.Help />
        </MainMenu>
        <Footer>
          {/* Sits next to Excalidraw's native zoom/undo/redo cluster. */}
          <button
            className="excalidraw-footer-btn"
            onClick={onRefresh}
            title="Force refresh board state from backend"
            style={{
              background: 'transparent',
              border: 'none',
              color: 'var(--color-on-surface, #e5e5e5)',
              padding: '0 10px',
              cursor: 'pointer',
              fontSize: 13,
              display: 'inline-flex',
              alignItems: 'center',
              gap: 4,
              height: '100%',
            }}
          >
            <RefreshIcon />
            <span>Refresh</span>
          </button>
        </Footer>
      </Excalidraw>
      <SessionOverlay
        excalidrawAPI={api}
        state={state}
        templateCache={templateCache}
        onNeedTemplate={onNeedTemplate}
      />
    </div>
  )
}
