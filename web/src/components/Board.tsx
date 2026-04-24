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
  buildChannelHub,
  buildScene,
  buildSessionEmbeddable,
  channelHubId,
  modeStrokeColor,
  modeStrokeStyle,
  RECT_W,
  RECT_H,
  CHANNEL_W,
  CHANNEL_H,
  isManagedElementId,
  parseChannelFromElement,
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
import {
  ensureChannelPositions,
  loadChannelLayout,
  saveChannelLayout,
} from '../channelLayout'
import { loadDismissed, saveDismissed } from '../dismissed'
import {
  loadAppState,
  saveAppState,
  loadUserShapes,
  saveUserShapes,
} from '../boardPersistence'
import { activateSession, addMember, removeMember } from '../api'
import { SessionOverlay } from './SessionOverlay'

/**
 * Derive a deterministic channel alias from a session's title + id so each
 * session gets a unique, stable alias when a user draws an arrow from the
 * session to a channel hub. Alias rules (backend): `[a-z0-9_-]{1,64}`.
 * Shape: `<kebab-title><-6char-shortid>` so two sessions with identical
 * titles still collide-free.
 */
function aliasFromSession(title: string, sid: string): string {
  const short = sid.replace(/-/g, '').slice(0, 6)
  const base = (title || 'session')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 30)
  return base ? `${base}-${short}` : `session-${short}`
}

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
function TerminalIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor"
         strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round">
      <polyline points="4 17 10 11 4 5" />
      <line x1="12" y1="19" x2="20" y2="19" />
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
   * Bulk "show all" / "hide all" sessions at once. Sidebar fires this; Board
   * handles the batch in a single effect so the requests don't race through
   * React's setState batching the way per-sid calls would.
   */
  bulkVisibilityRequest: { mode: 'show' | 'hide'; bump: number } | null
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
  /**
   * Requests placing a newly created channel's hub at the current viewport
   * center. Bumped once per create; the request is consumed in an effect that
   * writes the position into `channelLayoutRef` + persists. We can't just
   * compute the position in App.tsx because viewport math needs the imperative
   * Excalidraw API, which only Board owns.
   */
  placeChannelRequest: { channelName: string; bump: number } | null
  /** Invoked from the <MainMenu> "New Claude session" item. */
  onNewSession: () => void
  /** Invoked from the <MainMenu> "Ask AI to spawn…" item (claude -p driven). */
  onAskAndSpawn: () => void
  /** Invoked from the <MainMenu> "Preferences…" item. */
  onPreferences: () => void
  /** Invoked from the <MainMenu> "Fit to content" item. */
  onFit: () => void
  /** 未读通知的 session id 集合（Claude 刚回复完、用户还没点） */
  unreadSids: Set<string>
}

export default function Board({
  state,
  selection,
  onSelectionChange,
  fitSignal,
  addToCanvasRequest,
  hideFromCanvasRequest,
  bulkVisibilityRequest,
  onCountsChange,
  templateCache,
  onNeedTemplate,
  onRefresh,
  onNewChannel,
  placeChannelRequest,
  onNewSession,
  onAskAndSpawn,
  onPreferences,
  onFit,
  unreadSids,
}: Props) {
  const [api, setApi] = useState<ExcalidrawImperativeAPI | null>(null)
  const layoutRef = useRef<LayoutMap>(loadLayout())
  const channelLayoutRef = useRef<LayoutMap>(loadChannelLayout())
  const saveLayoutDebounced = useMemo(
    () => debounce((m: LayoutMap) => saveLayout(m), 400),
    [],
  )
  const saveChannelLayoutDebounced = useMemo(
    () => debounce((m: LayoutMap) => saveChannelLayout(m), 400),
    [],
  )
  // Persisted Excalidraw appState + user-drawn shapes.
  // 只读一次 —— Excalidraw 的 initialData 只在首次挂载生效。
  const initialDataRef = useRef<{ elements: any[]; appState: any }>({
    elements: loadUserShapes(),
    appState: (() => {
      const s = loadAppState()
      if (!s) return undefined
      return {
        scrollX: s.scrollX,
        scrollY: s.scrollY,
        zoom: { value: s.zoom },
      }
    })(),
  })
  const saveAppStateDebounced = useMemo(
    () => debounce((s: { scrollX: number; scrollY: number; zoom: number }) => saveAppState(s), 400),
    [],
  )
  const saveShapesDebounced = useMemo(
    () => debounce((els: readonly any[]) => saveUserShapes(els), 400),
    [],
  )
  // Sids the user has explicitly removed from canvas (last copy deleted).
  // Persisted so auto-re-add doesn't fight the user across WS ticks / reloads.
  const dismissedRef = useRef<Set<string>>(loadDismissed())
  // Previous per-sid card count, used to detect >0 → 0 transitions in onChange.
  const prevCountsRef = useRef<Record<string, number>>({})
  const lastAddBumpRef = useRef<number>(-1)
  const lastHideBumpRef = useRef<number>(-1)
  const lastBulkBumpRef = useRef<number>(-1)
  // Arrow-bind tracking: user drags an arrow from a session rect to a channel
  // hub (or vice versa) → we treat it as a new membership and POST addMember.
  // Deleting that arrow later → DELETE removeMember. Keyed by Excalidraw
  // arrow id so we can diff per-tick.
  const knownMemberArrowsRef = useRef<Map<string, { sid: string; channel: string; alias: string }>>(new Map())
  const lastPlaceChannelBumpRef = useRef<number>(-1)
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

    // Channel names (filter out operator '__…' defensively; backend already
    // strips them but guard anyway).
    const channelNames = state.channels
      .map((c) => c.name)
      .filter((n) => !n.startsWith('__'))
    channelLayoutRef.current = ensureChannelPositions(
      channelNames,
      channelLayoutRef.current,
    )
    saveChannelLayoutDebounced(channelLayoutRef.current)

    // Current scene → classify existing elements.
    const existing = api.getSceneElements()
    const userShapes = existing.filter((e) => !isManagedElementId(e.id))
    const existingEmbeddables = existing.filter(
      (e) =>
        e.type === 'rectangle' &&
        parseSessionFromElement(e) !== null,
    )
    const existingChannelHubs = existing.filter(
      (e) =>
        e.type === 'ellipse' &&
        parseChannelFromElement(e) !== null,
    )

    const knownSessionIds = new Set<string>()
    for (const e of existingEmbeddables) {
      const sid = parseSessionFromElement(e)
      if (sid) knownSessionIds.add(sid)
    }
    const knownChannelNames = new Set<string>()
    for (const e of existingChannelHubs) {
      const name = parseChannelFromElement(e)
      if (name) knownChannelNames.add(name)
    }

    // 规则：
    //   - 从没 dismiss 过的 session → 默认给它加一张 card（首次加载 / 新 session 会命中）
    //   - 用户 hide 过（sid 在 dismissedRef 里）→ 不要自动加回来，尊重隐藏意图
    //   - 用户重新点 "Add to canvas" → addToCanvas effect 里会把 sid 从 dismissedRef
    //     删掉，然后 reportCountsRef 的 "appeared" 路径也会兜底清理，下一轮 rebuild
    //     这里就会再走默认加卡的分支
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

    // Channels that are new to this scene (no hub ellipse yet).
    const newChannelNames = channelNames.filter(
      (n) => !knownChannelNames.has(n),
    )

    const { newEmbeddables, newChannelHubs, arrows } = buildScene(
      state,
      layoutRef.current,
      channelLayoutRef.current,
      {
        newSessionIds,
        newChannelNames,
        sessionIdToElementId: (sid) => primaryMap.get(sid) ?? null,
      },
    )

    const converted = convertToExcalidrawElements(
      [...newEmbeddables, ...newChannelHubs, ...arrows] as any,
      { regenerateIds: false },
    )

    // Migration：把旧版本遗留在画板上的 session rect（半透明灰底）强制归一到
    // 当前配色。Excalidraw 的 element state 是持久化的，旧 rect 如果不刷，
    // 就会一直从 overlay 四周漏出 rgba(30,30,30,0.4) 这层灰影。
    // 值必须和 scene.ts 里 buildSessionEmbeddable 保持一致。
    //
    // 同时在这里兜底：如果一个 rect 对应的 sid 已经不在 state.sessions 里
    //（session 被 kill / 终端关了、ClaudePlugin.syncToStore 删掉了记录），
    // 上面的 SessionOverlay 会 `if (!session) continue` 跳过渲染 → 画板上
    // 只剩个没有 CardHost 贴图的白矩形。把它们标 isDeleted:true 收走，
    // 用户看到的就是"session 关了 → 卡片消失"的预期体感。Undo 仍能恢复。
    const liveSids = new Set(ids)
    const normalizedExisting = existingEmbeddables.map((el: any) => {
      const sid = parseSessionFromElement(el)
      if (sid && !liveSids.has(sid)) {
        return { ...el, isDeleted: true }
      }
      return {
        ...el,
        strokeColor: '#262624',
        backgroundColor: '#262624',
        fillStyle: 'solid',
      }
    })

    // Keep existing channel hubs in place (preserve user-positioned x/y), but
    // re-sync stroke color / stroke style to the current channel mode +
    // pending count. If a channel has been removed from state (or renamed),
    // retire its hub via isDeleted so Excalidraw's Undo can still restore it.
    const liveChannelByName = new Map(
      state.channels
        .filter((c) => !c.name.startsWith('__'))
        .map((c) => [c.name, c]),
    )
    const normalizedChannelHubs = existingChannelHubs.map((el: any) => {
      const name = parseChannelFromElement(el)
      const ch = name ? liveChannelByName.get(name) : null
      if (!ch) {
        return { ...el, isDeleted: true }
      }
      return {
        ...el,
        strokeColor: modeStrokeColor(ch.mode),
        strokeStyle: modeStrokeStyle(ch),
      }
    })

    const preservedExisting = [
      ...userShapes,
      ...normalizedExisting,
      ...normalizedChannelHubs,
    ]

    const finalElements = [...preservedExisting, ...converted]
    api.updateScene({
      elements: finalElements as any,
    })
    // Report counts (preserved existing + newly converted embeddables).
    reportCountsRef.current(finalElements)
  }, [api, state, saveLayoutDebounced, saveChannelLayoutDebounced])

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

    // 优先级 1：如果 hide 留下的 `isDeleted:true` rect 还在（通常都在——
    // Excalidraw 保留 deleted 元素供 Undo），把它 undelete 回来。这样位置、
    // 连着的 arrow、element id 全部保持；用户的视觉直觉是"把刚才藏起来的
    // 那张卡拿回来"，而不是"凭空又多了一张"。
    const all = (api.getSceneElementsIncludingDeleted?.() ?? api.getSceneElements()) as readonly ExcalidrawElement[]
    const prior = all.find(
      (el) =>
        el.type === 'rectangle' &&
        (el as any).isDeleted === true &&
        parseSessionFromElement(el) === session.id,
    )
    if (prior) {
      const restored = { ...prior, isDeleted: false } as ExcalidrawElement
      const nextAll = all.map((el) => (el === prior ? restored : el))
      api.updateScene({ elements: nextAll as any })
      reportCountsRef.current(nextAll)
      api.scrollToContent([restored], { fitToContent: false, animate: true })
      return
    }

    // 优先级 2：layoutRef 里有上次记录的位置（用户之前移动过 / scene rebuild
    // 曾给它分过格子）→ 复用那个位置。否则才落到 viewport center + jitter。
    const saved = layoutRef.current[session.id]
    let x: number, y: number
    if (saved) {
      x = saved.x
      y = saved.y
    } else {
      const appState = api.getAppState()
      const viewW = appState.width ?? 800
      const viewH = appState.height ?? 600
      const zoom = appState.zoom.value || 1
      const cx = -appState.scrollX + viewW / zoom / 2
      const cy = -appState.scrollY + viewH / zoom / 2
      const jitter = () => Math.round((Math.random() - 0.5) * 60)
      x = Math.round(cx - 180) + jitter()
      y = Math.round(cy - 130) + jitter()
    }

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

  // -- Bulk show/hide from sidebar "Show all" / "Hide all" ------------
  // Walks every session, hides all rects (mark isDeleted:true) or ensures
  // each session has a visible rect (undelete existing or create new at the
  // saved layout position). Dismissed-set is cleaned up on "show" so the
  // scene-rebuild branch doesn't immediately hide them again.
  useEffect(() => {
    if (!api || !state || !bulkVisibilityRequest) return
    if (bulkVisibilityRequest.bump === lastBulkBumpRef.current) return
    lastBulkBumpRef.current = bulkVisibilityRequest.bump

    const all = (api.getSceneElementsIncludingDeleted?.() ?? api.getSceneElements()) as readonly ExcalidrawElement[]

    if (bulkVisibilityRequest.mode === 'hide') {
      // 全部隐藏：标 isDeleted:true。reportCountsRef 在一次调用里算每个 sid 的
      // >0→0 transition，把所有 sid 一次性加入 dismissedRef + 持久化。
      const next = all.map((el) => {
        if (el.type !== 'rectangle') return el
        if (parseSessionFromElement(el) == null) return el
        if ((el as any).isDeleted) return el
        return { ...el, isDeleted: true }
      })
      api.updateScene({ elements: next as any })
      reportCountsRef.current(next)
      return
    }

    // show：对每个 session
    //   (a) 如果画布上已经有一张非 deleted 的 rect → 什么都不做
    //   (b) 有 isDeleted:true 的 rect → undelete 它（保留位置 + 连着的 arrow）
    //   (c) 完全没 rect（dismissedRef 里彻底清过） → buildSessionEmbeddable 新建
    //       一张到 layoutRef 里记住的位置，没记录就走 ensurePositions 的默认网格
    const hasVisible = new Set<string>()
    const firstDeleted = new Map<string, ExcalidrawElement>()
    for (const el of all) {
      if (el.type !== 'rectangle') continue
      const sid = parseSessionFromElement(el)
      if (!sid) continue
      if (!(el as any).isDeleted) {
        hasVisible.add(sid)
      } else if (!firstDeleted.has(sid)) {
        firstDeleted.set(sid, el)
      }
    }

    // pass 1：undelete 存在的 deleted rect
    const undeleted = new Set<string>()
    const next = all.map((el) => {
      if (el.type !== 'rectangle') return el
      const sid = parseSessionFromElement(el)
      if (!sid) return el
      if (hasVisible.has(sid) || undeleted.has(sid)) return el
      const dup = firstDeleted.get(sid)
      if (dup && el === dup && (el as any).isDeleted) {
        undeleted.add(sid)
        return { ...el, isDeleted: false }
      }
      return el
    })

    // pass 2：完全没 rect 的新建
    const needCreate: string[] = []
    for (const s of state.sessions) {
      if (!hasVisible.has(s.id) && !undeleted.has(s.id)) {
        needCreate.push(s.id)
      }
    }
    if (needCreate.length > 0) {
      layoutRef.current = ensurePositions(state.sessions.map((s) => s.id), layoutRef.current)
      saveLayoutDebounced(layoutRef.current)
      const skeletons = needCreate
        .map((sid) => {
          const sess = state.sessions.find((x) => x.id === sid)
          if (!sess) return null
          const pos = layoutRef.current[sid] ?? { x: 80, y: 80 }
          const newId = `session-${sid}-${Date.now().toString(36)}`
          return buildSessionEmbeddable(sess, pos.x, pos.y, newId)
        })
        .filter((x): x is NonNullable<typeof x> => x != null)
      const built = convertToExcalidrawElements(skeletons as any, { regenerateIds: false })
      next.push(...built)
    }

    // 清所有 sid 的 dismissed 标记，scene-rebuild 才不会立刻把刚恢复的再藏掉
    let dismissedChanged = false
    for (const s of state.sessions) {
      if (dismissedRef.current.delete(s.id)) dismissedChanged = true
    }
    if (dismissedChanged) saveDismissed(dismissedRef.current)

    api.updateScene({ elements: next as any })
    reportCountsRef.current(next)
  }, [api, state, bulkVisibilityRequest, saveLayoutDebounced])

  // -- Place a freshly-created channel hub at the current viewport center --
  // The dialog calls onCreated(name) in App.tsx, which sets
  // placeChannelRequest. We consume it here: compute viewport center (same
  // math as add-to-canvas), write into channelLayoutRef + persist, then
  // schedule a scene rebuild so the hub materialises at that point. The
  // scene-rebuild effect above sees a new-channel-name and builds the hub
  // from channelLayoutRef[name].
  useEffect(() => {
    if (!api || !state || !placeChannelRequest) return
    if (placeChannelRequest.bump === lastPlaceChannelBumpRef.current) return
    lastPlaceChannelBumpRef.current = placeChannelRequest.bump

    const name = placeChannelRequest.channelName
    if (!name || name.startsWith('__')) return

    const appState = api.getAppState()
    const viewW = appState.width ?? 800
    const viewH = appState.height ?? 600
    const zoom = appState.zoom.value || 1
    const cx = -appState.scrollX + viewW / zoom / 2
    const cy = -appState.scrollY + viewH / zoom / 2
    // Center the ellipse on viewport center.
    const x = Math.round(cx - CHANNEL_W / 2)
    const y = Math.round(cy - CHANNEL_H / 2)

    channelLayoutRef.current = {
      ...channelLayoutRef.current,
      [name]: { x, y },
    }
    saveChannelLayoutDebounced(channelLayoutRef.current)

    // If the hub hasn't been built yet (state may not have been delivered
    // over WS on this tick), the scene-rebuild effect will pick up the
    // saved position the next time it fires with the channel present.
    // If the hub already exists (e.g. the channel was re-created with the
    // same name after a short delete), move it and re-scroll into view.
    const hubEl = api.getSceneElements().find(
      (el) => el.id === channelHubId(name) && el.type === 'ellipse',
    ) as any
    if (hubEl) {
      const next = api.getSceneElements().map((el) => {
        if (el.id === channelHubId(name) && el.type === 'ellipse') {
          return { ...el, x, y } as any
        }
        return el
      })
      api.updateScene({ elements: next as any })
      api.scrollToContent([hubEl], { fitToContent: false, animate: true })
    } else {
      // Build and insert immediately using whatever channel snapshot we
      // have; the scene-rebuild effect will normalise it once state updates.
      const ch = state.channels.find((c) => c.name === name)
      if (ch) {
        const skeleton = buildChannelHub(ch, x, y)
        const [built] = convertToExcalidrawElements([skeleton] as any, {
          regenerateIds: false,
        })
        if (built) {
          const next = [...api.getSceneElements(), built]
          api.updateScene({ elements: next as any })
          api.scrollToContent([built], { fitToContent: false, animate: true })
        }
      }
    }
  }, [api, state, placeChannelRequest, saveChannelLayoutDebounced])

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
    console.log(
      '[SelectionTrace] push-back effect sid=%s matchIds=%o stateTick=%s',
      sid.slice(0, 8),
      matchIds,
      !!state,
    )
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
          if (el.type === 'ellipse') {
            const name = parseChannelFromElement(el)
            if (name) {
              channelName = channelName ?? name
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
        console.log(
          '[SelectionTrace] onChange selIds=%s selSig=%s cur=%o next=%o same=%s',
          selIds.length,
          selSig || '(empty)',
          cur,
          next,
          same,
        )
        if (!same) {
          console.log('[SelectionTrace] → firing onSelectionChange to', next)
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
      //
      // 之前靠 `appState.draggingElement` 触发 —— 这个字段在新版 Excalidraw
      // 里常为 undefined，导致 drag 结束后根本没 trigger 保存，位置刷新即丢。
      // 改成：每次 onChange 里都 diff 对比 layoutRef，发现 x/y 变了就 save。
      // debounce 400ms 会把连续拖动合并掉。
      {
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
      // Same diff-and-save pattern for channel hubs (ellipses with
      // customData.channelName). Keeps hub positions sticky across reloads
      // just like session cards.
      {
        let changed = false
        const next: LayoutMap = { ...channelLayoutRef.current }
        for (const el of elements) {
          if (el.type !== 'ellipse') continue
          if ((el as any).isDeleted) continue
          const name = parseChannelFromElement(el)
          if (!name) continue
          const prev = next[name]
          if (!prev || prev.x !== el.x || prev.y !== el.y) {
            next[name] = { x: el.x, y: el.y }
            changed = true
          }
        }
        if (changed) {
          channelLayoutRef.current = next
          saveChannelLayoutDebounced(next)
        }
      }
      // ── Channel membership via arrows (phase 3.3) ─────────────────────
      // Any user-drawn arrow whose endpoints bind a session rect to a channel
      // hub (or vice versa) is treated as a membership claim. We diff vs last
      // tick so each arrow add/remove fires exactly one REST call.
      //
      // Our auto-generated spokes have deterministic ids
      // (`channel-<name>-spoke-<sid>`); we skip them so rebuild traffic doesn't
      // create duplicate members.
      {
        const nextMember = new Map<string, { sid: string; channel: string; alias: string }>()
        for (const el of elements) {
          if (el.type !== 'arrow') continue
          if ((el as any).isDeleted) continue
          if (el.id.startsWith('channel-') && el.id.includes('-spoke-')) continue
          const startId = (el as any).startBinding?.elementId as string | undefined
          const endId = (el as any).endBinding?.elementId as string | undefined
          if (!startId || !endId) continue
          const startEl = elements.find((e) => e.id === startId)
          const endEl = elements.find((e) => e.id === endId)
          if (!startEl || !endEl) continue
          const startSid = startEl.type === 'rectangle' ? parseSessionFromElement(startEl) : null
          const endSid = endEl.type === 'rectangle' ? parseSessionFromElement(endEl) : null
          const startCh = startEl.type === 'ellipse' ? parseChannelFromElement(startEl) : null
          const endCh = endEl.type === 'ellipse' ? parseChannelFromElement(endEl) : null
          let sid: string | null = null
          let chName: string | null = null
          if (startSid && endCh) { sid = startSid; chName = endCh }
          else if (endSid && startCh) { sid = endSid; chName = startCh }
          else continue
          const session = state.sessions.find((s) => s.id === sid)
          if (!session) continue
          const alias = aliasFromSession(session.title, session.id)
          nextMember.set(el.id, { sid, channel: chName, alias })
        }

        // additions
        for (const [arrowId, info] of nextMember) {
          if (knownMemberArrowsRef.current.has(arrowId)) continue
          const ch = state.channels.find((c) => c.name === info.channel)
          const already = ch?.members.some((m) => m.sessionId === info.sid && m.alias === info.alias)
          if (already) continue
          console.log('[Board.arrow] addMember', info)
          void addMember(info.channel, info.alias, info.sid).catch((e) => {
            console.warn('[Board.arrow] addMember failed:', (e as Error).message)
          })
        }
        // removals
        for (const [arrowId, info] of knownMemberArrowsRef.current) {
          if (nextMember.has(arrowId)) continue
          const ch = state.channels.find((c) => c.name === info.channel)
          const stillMember = ch?.members.some((m) => m.sessionId === info.sid && m.alias === info.alias)
          if (!stillMember) continue
          console.log('[Board.arrow] removeMember', info)
          void removeMember(info.channel, info.alias).catch((e) => {
            console.warn('[Board.arrow] removeMember failed:', (e as Error).message)
          })
        }
        knownMemberArrowsRef.current = nextMember
      }

      // Report counts on every change so sidebar stays in sync with
      // copy/paste/delete performed natively by Excalidraw.
      reportCountsRef.current(elements)

      // 强制等比例缩放：session card 的 aspect ratio 锁成 RECT_W:RECT_H。
      // 用户拖任意 handle 时 Excalidraw 会允许宽高独立变，这里检测到比例偏离
      // 就把 width/height 纠正回来（以较大的那一维为准，让用户"拉大"的意图
      // 更直观）。feedback 循环由"发现已经对就不更新"天然避免。
      const RATIO = RECT_W / RECT_H
      let aspectNeedsFix = false
      const fixedElements = elements.map((el) => {
        if (el.type !== 'rectangle') return el
        if (!parseSessionFromElement(el)) return el
        const w = el.width
        const h = el.height
        if (!w || !h) return el
        const actual = w / h
        if (Math.abs(actual - RATIO) < 0.01) return el // 已经比例正确
        aspectNeedsFix = true
        // 以较大的那一维为基准
        const newW = Math.max(w, h * RATIO)
        const newH = newW / RATIO
        return { ...el, width: newW, height: newH } as ExcalidrawElement
      })
      if (aspectNeedsFix && api) {
        try {
          api.updateScene({ elements: fixedElements as any })
        } catch (e) {
          console.warn('[Board] aspect-ratio clamp updateScene failed', e)
        }
      }

      // 持久化 viewport + 用户画的非 session 元素
      saveAppStateDebounced({
        scrollX: appState.scrollX ?? 0,
        scrollY: appState.scrollY ?? 0,
        zoom: appState.zoom?.value ?? 1,
      })
      saveShapesDebounced(elements)
    }
  }, [state, selection, onSelectionChange, saveLayoutDebounced, saveChannelLayoutDebounced, api, saveAppStateDebounced, saveShapesDebounced])

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
        initialData={initialDataRef.current as any}
        excalidrawAPI={(a) => setApi(a)}
        onChange={handleChange}
        UIOptions={uiOptions as any}
        viewModeEnabled={false}
        gridModeEnabled={false}
      >
        <MainMenu>
          <MainMenu.Item onSelect={onNewSession} icon={<TerminalIcon />}>
            New Claude session…
          </MainMenu.Item>
          <MainMenu.Item onSelect={onAskAndSpawn} icon={<TerminalIcon />}>
            Ask AI to spawn…
          </MainMenu.Item>
          <MainMenu.Item onSelect={onPreferences} icon={<PlusSquareIcon />}>
            Preferences…
          </MainMenu.Item>
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
      {/*
        Floating toolbar (DOM level, not an Excalidraw tool). Parked in the
        top-right of the board area so it doesn't collide with the left-side
        Excalidraw tool pill and has breathing room from the upper-right
        collaboration/help cluster. We keep the MainMenu "New channel" item
        too — this is phase 1 UX sugar, not a replacement.
      */}
      <div
        className="board-floating-toolbar"
        style={{
          position: 'absolute',
          top: 12,
          right: 16,
          display: 'flex',
          gap: 8,
          zIndex: 5,
          pointerEvents: 'auto',
        }}
      >
        <button
          onClick={onNewChannel}
          title="Create a new channel"
          style={{
            background: 'var(--bg-paper, #2C2B29)',
            color: 'var(--text, #F5F4EF)',
            border: '1px solid var(--border, #3A3A38)',
            borderRadius: 8,
            padding: '6px 12px',
            cursor: 'pointer',
            fontSize: 12,
            fontFamily: 'var(--sans)',
            display: 'inline-flex',
            alignItems: 'center',
            gap: 4,
            boxShadow: '0 2px 6px rgba(0,0,0,0.3)',
          }}
        >
          <span style={{ fontSize: 14, lineHeight: 1 }}>+</span>
          <span>New channel</span>
        </button>
        {/*
          Channel arrow = Excalidraw 原生 arrow 工具，我们 CSS 藏掉了它自带
          的入口，改由这个按钮激活，措辞直接点明"只用来连接 session → channel
          hub"。用户画完的 arrow 会被上面 handleChange 里的 arrow-bind 检测
          自动变成 addMember 请求。 */}
        <button
          onClick={() => {
            if (!api) return
            try {
              ;(api as any).setActiveTool({ type: 'arrow' })
            } catch (e) {
              console.warn('[Board] setActiveTool(arrow) failed', e)
            }
          }}
          title="Channel arrow: drag from a session card to a channel hub to add it as a member"
          style={{
            background: 'var(--bg-paper, #2C2B29)',
            color: 'var(--text, #F5F4EF)',
            border: '1px solid var(--border, #3A3A38)',
            borderRadius: 8,
            padding: '6px 12px',
            cursor: 'pointer',
            fontSize: 12,
            fontFamily: 'var(--sans)',
            display: 'inline-flex',
            alignItems: 'center',
            gap: 6,
            boxShadow: '0 2px 6px rgba(0,0,0,0.3)',
          }}
        >
          <span style={{ fontSize: 13, lineHeight: 1 }}>→</span>
          <span>Channel arrow</span>
        </button>
      </div>
      <SessionOverlay
        excalidrawAPI={api}
        state={state}
        templateCache={templateCache}
        onNeedTemplate={onNeedTemplate}
        unreadSids={unreadSids}
      />
    </div>
  )
}
