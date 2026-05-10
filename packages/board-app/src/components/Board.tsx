import { useEffect, useMemo, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import {
  Excalidraw,
  MainMenu,
  convertToExcalidrawElements,
} from '@excalidraw/excalidraw'
import type {
  ExcalidrawImperativeAPI,
  AppState,
} from '@excalidraw/excalidraw/types'
import type { ExcalidrawElement } from '@excalidraw/excalidraw/element/types'

import type { BoardState, Selection } from '../types'
import { isOlderSession } from '../types'
import {
  buildChannelHub,
  buildScene,
  buildSessionEmbeddable,
  channelHubId,
  panToChannelHub,
  modeStrokeColor,
  modeStrokeStyle,
  RECT_W,
  RECT_H,
  CHANNEL_FRAME_W,
  CHANNEL_FRAME_H,
  isManagedElementId,
  parseChannelFromElement,
  parseSessionLink,
  parseSessionFromElement,
  resolveChannelFromElementId,
  sessionRectId,
  debounce,
  ensurePositions,
  ensureChannelPositions,
  dmChannelName,
  isDmChannelName,
  DM_LINE_STROKE_COLOR,
  DM_LINE_STROKE_WIDTH_BASE,
  DM_LINE_STROKE_WIDTH_PENDING,
  type LayoutMap,
  type CanvasPersistence,
} from '@meee1/board-core'
import {
  activateSession,
  addMember,
  createChannel,
  deleteChannel,
  removeMember,
} from '../api'
import { SessionOverlay } from './SessionOverlay'
import { Tooltip } from './Tooltip'

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

const SIDEBAR_FOCUS_ZOOM = 1.25

/** Annotation written into a card-to-card arrow's customData so we can
 *  recognise it as a "DM line" across refreshes -- Excalidraw can briefly
 *  drop bindings on load (user shapes restore before managed rects rebuild),
 *  and without a persisted hint the arrow temporarily looks like a vanilla
 *  shape. */
const DM_ARROW_META_KEY = 'dmArrow'

interface DmMeta {
  channel: string
  sidA: string
  sidB: string
}

function readDmMeta(el: any): DmMeta | null {
  const meta = el?.customData?.[DM_ARROW_META_KEY]
  if (!meta || typeof meta !== 'object') return null
  const channel = typeof meta.channel === 'string' ? meta.channel : null
  const sidA = typeof meta.sidA === 'string' ? meta.sidA : null
  const sidB = typeof meta.sidB === 'string' ? meta.sidB : null
  if (!channel || !sidA || !sidB) return null
  return { channel, sidA, sidB }
}

function withDmMeta(el: any, meta: DmMeta): any {
  const customData = {
    ...(el.customData ?? {}),
    [DM_ARROW_META_KEY]: meta,
  }
  return { ...el, customData }
}

function liveSessionRects(
  elements: readonly ExcalidrawElement[],
  sid: string,
): ExcalidrawElement[] {
  return elements.filter(
    (el) =>
      el.type === 'rectangle' &&
      !(el as any).isDeleted &&
      parseSessionFromElement(el) === sid,
  )
}

function focusSceneElement(
  api: ExcalidrawImperativeAPI,
  el: ExcalidrawElement,
): void {
  const appState = api.getAppState()
  const currentZoom = appState.zoom?.value ?? 1
  const zoom = Math.max(currentZoom, SIDEBAR_FOCUS_ZOOM)
  const viewW = appState.width ?? window.innerWidth
  const viewH = appState.height ?? window.innerHeight
  const centerX = (el.x ?? 0) + ((el.width ?? RECT_W) / 2)
  const centerY = (el.y ?? 0) + ((el.height ?? RECT_H) / 2)
  const scrollX = -centerX + viewW / zoom / 2
  const scrollY = -centerY + viewH / zoom / 2

  api.updateScene({
    appState: {
      scrollX,
      scrollY,
      zoom: { value: zoom },
      selectedElementIds: { [el.id]: true },
    } as any,
  })
}

/** Resolve a session sid from an Excalidraw element id of the form
 *  `session-<sid>` or `session-<sid>-<copyId>`. Greedy longest-match so a
 *  copy id with hyphens doesn't accidentally swallow a real sid. */
function resolveSessionIdFromElementId(
  id: string,
  sessionIds: readonly string[],
): string | null {
  if (!id.startsWith('session-')) return null
  const rest = id.slice('session-'.length)
  let best: string | null = null
  for (const sid of sessionIds) {
    if (rest === sid || rest.startsWith(`${sid}-`)) {
      if (!best || sid.length > best.length) best = sid
    }
  }
  return best
}

/** Read a binding endpoint and return the session sid it points to (or
 *  null). Tolerates the brief tick where Excalidraw drops bindings during
 *  scene rebuild by falling back to the element id pattern. */
function endpointSid(
  endpointElementId: string | undefined,
  elementsById: ReadonlyMap<string, ExcalidrawElement>,
  sessionIds: readonly string[],
): string | null {
  if (!endpointElementId) return null
  const el = elementsById.get(endpointElementId)
  if (el && !(el as any).isDeleted) {
    const sid = parseSessionFromElement(el)
    if (sid && sessionIds.includes(sid)) return sid
  }
  return resolveSessionIdFromElementId(endpointElementId, sessionIds)
}

/** Identify a card-to-card arrow, i.e. one whose start AND end bindings both
 *  resolve to (different) session rects -- that's the gesture for creating a
 *  1-on-1 DM channel. Falls back to persisted DM meta so a refreshed arrow
 *  remains classified even if Excalidraw dropped its bindings. */
function classifyDmArrow(
  el: any,
  elementsById: ReadonlyMap<string, ExcalidrawElement>,
  sessionIds: readonly string[],
): { sidA: string; sidB: string } | null {
  if (!el || el.type !== 'arrow' || el.isDeleted) return null
  const sStart = endpointSid(el.startBinding?.elementId, elementsById, sessionIds)
  const sEnd = endpointSid(el.endBinding?.elementId, elementsById, sessionIds)
  if (sStart && sEnd && sStart !== sEnd) {
    return { sidA: sStart, sidB: sEnd }
  }
  const meta = readDmMeta(el)
  if (meta && sessionIds.includes(meta.sidA) && sessionIds.includes(meta.sidB)) {
    return { sidA: meta.sidA, sidB: meta.sidB }
  }
  return null
}

/** Match a frameId on a session rect to its channel name, if any. The frame
 *  id is the deterministic `channel-<name>` string we put on every channel
 *  frame. */
function frameIdToChannelName(
  frameId: string | null | undefined,
  channelNames: readonly string[],
): string | null {
  if (!frameId || !frameId.startsWith('channel-')) return null
  const rest = frameId.slice('channel-'.length)
  // Greedy longest-match; channels named e.g. `foo` and `foo-bar` both match
  // an id of `channel-foo-bar`, prefer the longer.
  let best: string | null = null
  for (const name of channelNames) {
    if (rest === name) {
      if (!best || name.length > best.length) best = name
    }
  }
  return best
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
  bulkVisibilityRequest: { mode: 'show' | 'hide'; bump: number; sids?: string[] } | null
  /** Sidebar session click: select, center, and zoom onto the matching card. */
  focusSessionRequest: { sessionId: string; bump: number } | null
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
  /** Async storage interface (HTTP + localStorage in meee2; Supabase in meee2). */
  persistence: CanvasPersistence
  /** Hydrated initial values for every persisted slot — App.tsx has already
   *  resolved these via persistence.loadXxx() so Board can take them in
   *  useRef synchronously at first render. */
  initial: {
    sessionLayout: LayoutMap
    channelLayout: LayoutMap
    viewport: { scrollX: number; scrollY: number; zoom: number } | null
    userElements: any[]
    dismissed: Set<string>
  }
}

export default function Board({
  state,
  selection,
  onSelectionChange,
  fitSignal,
  addToCanvasRequest,
  hideFromCanvasRequest,
  bulkVisibilityRequest,
  focusSessionRequest,
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
  persistence,
  initial,
}: Props) {
  const [api, setApi] = useState<ExcalidrawImperativeAPI | null>(null)
  // 把 Create channel / DM line 两个按钮 portal 到 Excalidraw 自己的
  // 横向 shape tool 行 (`.App-toolbar .Stack_horizontal`) 里 ——
  // Excalidraw 不暴露添加 shape tool 的公开 API（issue #7583 / #6697 已
  // 确认），所以走 React Portal 直接 attach 到那个 flex 行的 DOM 节点。
  // 必须挂到 .Stack_horizontal 而不是 .App-toolbar 本身，否则会成为
  // toolbar 的另一行子元素，被 wrap 到第二行去（实测过）。
  const [toolbarRowEl, setToolbarRowEl] = useState<HTMLElement | null>(null)
  useEffect(() => {
    const find = () => {
      const el = document.querySelector('.excalidraw .App-toolbar .Stack_horizontal') as HTMLElement | null
      setToolbarRowEl((prev) => (prev === el ? prev : el))
    }
    find()
    const obs = new MutationObserver(find)
    obs.observe(document.body, { childList: true, subtree: true })
    return () => obs.disconnect()
  }, [])
  // Persistence is fully async via CanvasPersistence. App.tsx hydrates all
  // slots up-front (Promise.all of loadXxx) and passes them in as `initial`,
  // so these useRefs can take values synchronously at first render — same
  // semantics the old loadLayout()/loadChannelLayout() had, just hoisted up.
  const layoutRef = useRef<LayoutMap>(initial.sessionLayout)
  const channelLayoutRef = useRef<LayoutMap>(initial.channelLayout)
  // Save wrappers fire-and-forget the async persistence call; debounce coalesces
  // bursty drag updates. 400ms matches the old layout.ts / channelLayout.ts
  // debounce, so PUT traffic during a drag stays bounded.
  const saveLayoutDebounced = useMemo(
    () => debounce((m: LayoutMap) => { void persistence.saveSessionLayout(m) }, 400),
    [persistence],
  )
  const saveChannelLayoutDebounced = useMemo(
    () => debounce((m: LayoutMap) => { void persistence.saveChannelLayout(m) }, 400),
    [persistence],
  )

  // Persisted Excalidraw appState + user-drawn shapes.
  // 只读一次 —— Excalidraw 的 initialData 只在首次挂载生效。
  const initialDataRef = useRef<{ elements: any[]; appState: any }>({
    elements: initial.userElements,
    appState: initial.viewport
      ? {
          scrollX: initial.viewport.scrollX,
          scrollY: initial.viewport.scrollY,
          zoom: { value: initial.viewport.zoom },
        }
      : undefined,
  })
  const saveAppStateDebounced = useMemo(
    () => debounce((s: { scrollX: number; scrollY: number; zoom: number }) => { void persistence.saveViewport(s) }, 400),
    [persistence],
  )
  const saveShapesDebounced = useMemo(
    () => debounce((els: readonly any[]) => { void persistence.saveUserElements(els) }, 400),
    [persistence],
  )
  // Sids the user has explicitly removed from canvas (last copy deleted).
  // Persisted via persistence.saveDismissed so auto-re-add doesn't fight the
  // user across WS ticks / reloads.
  const dismissedRef = useRef<Set<string>>(initial.dismissed)
  // Previous per-sid card count, used to detect >0 → 0 transitions in onChange.
  const prevCountsRef = useRef<Record<string, number>>({})
  const lastAddBumpRef = useRef<number>(-1)
  const lastHideBumpRef = useRef<number>(-1)
  const lastBulkBumpRef = useRef<number>(-1)
  const lastFocusSessionBumpRef = useRef<number>(-1)
  // Frame-membership snapshot from the previous tick: sid -> channel name.
  // Used to detect a card moving between frames so we can issue the right
  // addMember/removeMember pair against the backend.
  const knownFrameMembershipsRef = useRef<Map<string, string>>(new Map())
  // DM channels we know exist on the canvas this tick: channel name -> sids.
  // Diff against state.channels to detect new lines (createChannel +
  // addMember x2) and removed lines (deleteChannel).
  const knownDmChannelsRef = useRef<Map<string, { sidA: string; sidB: string }>>(new Map())
  // 上一次 onChange 看到的非-DM channel frame 名集合。当用户在画板上选中
  // channel frame 并按 Delete 后，本 tick 这个 frame 没了但 state.channels
  // 还有该 channel —— 触发 deleteChannel(...) 让 backend 也删掉，否则下一
  // 次 scene rebuild 又会把 frame 补回来（"删了又冒"），用户感知就是删不掉。
  const knownChannelFramesRef = useRef<Set<string>>(new Set())
  // In-flight DM channel mutations, keyed by channel name. Prevents the same
  // line being created or deleted twice while the network round-trip is
  // pending.
  const pendingDmOpsRef = useRef<Set<string>>(new Set())
  // In-flight frame-membership mutations, keyed by `${channel}|${sid}`.
  const pendingFrameOpsRef = useRef<Set<string>>(new Set())
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
      if (dismissedChanged) void persistence.saveDismissed(dismissedRef.current)
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
  // Reconciles Excalidraw scene with backend state. Two managed shapes:
  //   - session rectangles (one or more per session; the DOM overlay paints
  //     the live card on top)
  //   - channel frames (one per non-DM channel; cards inside the frame =
  //     channel members; Excalidraw assigns frameId on drag-into-frame)
  // DM channels are visualised as user-drawn arrows between two session
  // rects -- they don't get their own managed shape; styling is normalised
  // here so a refreshed DM arrow keeps the violet/dashed look.
  useEffect(() => {
    if (!api || !state) return

    const ids = state.sessions.map((s) => s.id)
    layoutRef.current = ensurePositions(ids, layoutRef.current)
    saveLayoutDebounced(layoutRef.current)

    // Channel names (filter out operator '__…' defensively; backend already
    // strips them but guard anyway). DM channels get filtered separately
    // below: they don't render as frames.
    const channelNames = state.channels
      .map((c) => c.name)
      .filter((n) => !n.startsWith('__'))
    const frameChannelNames = channelNames.filter((n) => !isDmChannelName(n))
    channelLayoutRef.current = ensureChannelPositions(
      frameChannelNames,
      channelLayoutRef.current,
    )
    saveChannelLayoutDebounced(channelLayoutRef.current)

    const sessionById = new Map(
      state.sessions.map((s) => [s.id, { id: s.id, title: s.title }]),
    )
    const liveChannelByName = new Map(
      state.channels
        .filter((c) => !c.name.startsWith('__'))
        .map((c) => [c.name, c]),
    )
    const sessionIdsArr = state.sessions.map((s) => s.id)

    // -- Bucket existing elements --------------------------------------
    const existing = api.getSceneElements()
    const elementsById = new Map(existing.map((el) => [el.id, el]))

    // userShapes: anything not on the managed-id allowlist (sessions and
    // channel-* shapes). Filters out orphaned channel-text labels so they
    // don't accumulate one-per-refresh.
    const userShapesRaw = existing.filter((e) => {
      if (isManagedElementId(e.id)) return false
      if (e.type === 'text') {
        const cid = (e as any).containerId as string | undefined
        if (cid && cid.startsWith('channel-') && !e.id.startsWith('channel-')) {
          return false
        }
      }
      return true
    })
    // Restyle DM arrows: any user-drawn arrow whose start AND end bind to
    // session rects is a DM line. Apply distinctive violet/dashed style and
    // persist DM meta into customData so the next rebuild can keep it
    // recognised even if Excalidraw drops bindings.
    const dmStyleStrokeWidth = (channel: string) => {
      const ch = liveChannelByName.get(channel)
      return ch && ch.pendingCount > 0
        ? DM_LINE_STROKE_WIDTH_PENDING
        : DM_LINE_STROKE_WIDTH_BASE
    }
    const userShapes = userShapesRaw.map((el: any) => {
      if (el.type !== 'arrow') return el
      const sb = el.startBinding ? { ...el.startBinding } : null
      const eb = el.endBinding ? { ...el.endBinding } : null
      let touched = false
      if (sb && sb.elementId && sb.gap == null) { sb.gap = 1; touched = true }
      if (sb && sb.elementId && sb.focus == null) { sb.focus = 0; touched = true }
      if (eb && eb.elementId && eb.gap == null) { eb.gap = 1; touched = true }
      if (eb && eb.elementId && eb.focus == null) { eb.focus = 0; touched = true }

      const dm = classifyDmArrow(el, elementsById, sessionIdsArr)
      if (dm) {
        const channel = dmChannelName(dm.sidA, dm.sidB)
        return withDmMeta({
          ...el,
          startBinding: sb,
          endBinding: eb,
          strokeColor: DM_LINE_STROKE_COLOR,
          strokeWidth: dmStyleStrokeWidth(channel),
          strokeStyle: 'dashed',
          startArrowhead: null,
          endArrowhead: null,
        }, { channel, sidA: dm.sidA, sidB: dm.sidB })
      }
      if (!touched) return el
      return { ...el, startBinding: sb, endBinding: eb }
    })

    // Session rects.
    const existingEmbeddables = existing.filter(
      (e) =>
        e.type === 'rectangle' &&
        !(e as any).isDeleted &&
        parseSessionFromElement(e) !== null,
    )

    // Current channel frames (the new shape) + legacy hubs/labels/spokes
    // that we tombstone on this rebuild.
    const existingChannelFrames = existing.filter(
      (e) =>
        (e as any).type === 'frame' &&
        !(e as any).isDeleted &&
        parseChannelFromElement(e) !== null,
    )
    const legacyHubEllipses = existing.filter(
      (e) =>
        e.type === 'ellipse' &&
        !(e as any).isDeleted &&
        parseChannelFromElement(e) !== null,
    )
    const legacyHubLabels = existing.filter(
      (e) =>
        e.type === 'text' &&
        !(e as any).isDeleted &&
        typeof e.id === 'string' &&
        e.id.startsWith('channel-') &&
        e.id.endsWith('-label'),
    )
    const legacySpokes = existing.filter(
      (e) =>
        e.type === 'arrow' &&
        !(e as any).isDeleted &&
        typeof e.id === 'string' &&
        e.id.startsWith('channel-') &&
        e.id.includes('-spoke-'),
    )
    const legacySpokeLabels = existing.filter((e) => {
      if (e.type !== 'text') return false
      if ((e as any).isDeleted) return true
      const cid = (e as any).containerId as string | undefined
      if (!cid) return false
      return cid.startsWith('channel-') && cid.includes('-spoke-')
    })

    const knownSessionIds = new Set<string>()
    for (const e of existingEmbeddables) {
      const sid = parseSessionFromElement(e)
      if (sid) knownSessionIds.add(sid)
    }
    const knownFrameChannelNames = new Set<string>()
    for (const e of existingChannelFrames) {
      const name = parseChannelFromElement(e)
      if (name) knownFrameChannelNames.add(name)
    }

    const newSessionIds: string[] = []
    for (const s of state.sessions) {
      // 「自动建卡」的两条隐藏规则全部由前端决定 (types.ts:isOlderSession +
      // dismissedRef)。后端不再下发 displayGroup —— Board / Sidebar 共用同
      // 一个 helper 保持一致。
      if (isOlderSession(s)) continue
      if (knownSessionIds.has(s.id)) continue
      if (dismissedRef.current.has(s.id)) continue
      newSessionIds.push(s.id)
    }

    if (newSessionIds.length > 0 || dismissedRef.current.size > 0) {
      console.log(
        '[Board.scene] new=%d dismissed=%d',
        newSessionIds.length,
        dismissedRef.current.size,
      )
    }

    // Channels needing a fresh frame: every non-DM channel that hasn't been
    // built yet.
    const newChannelNames = frameChannelNames.filter(
      (n) => !knownFrameChannelNames.has(n),
    )
    if (newChannelNames.length > 0) {
      console.log(
        '[Board] rebuilding missing channel frames:',
        newChannelNames,
        '(known:',
        Array.from(knownFrameChannelNames),
        ')',
      )
    }

    const { newEmbeddables, newChannelHubs } = buildScene(
      state,
      layoutRef.current,
      channelLayoutRef.current,
      {
        newSessionIds,
        newChannelNames,
      },
    )

    const converted = convertToExcalidrawElements(
      [...newEmbeddables, ...newChannelHubs] as any,
      { regenerateIds: false },
    )

    // -- Normalize existing rects --------------------------------------
    // Force the meee2 background colors so legacy rects don't leak grey
    // halos around the DOM overlay; tombstone rects whose session is gone.
    // Also sync `frameId` from backend state: every session that's a
    // member of a (non-DM) frame channel should have its rects belong to
    // that frame visually. This is essential for the upgrade path where
    // pre-existing channel memberships load before the user has dragged
    // anything -- without it, handleChange's frame-membership diff would
    // see "no frameId on rects" vs "memberships in state" and start
    // removing those memberships. We skip the sync for sessions whose
    // frame ops are currently in-flight to preserve the user's drag intent
    // while the network round-trip is pending.
    const liveSids = new Set(ids)
    const stateFrameMembershipBySid = new Map<string, string>()
    for (const ch of state.channels) {
      if (ch.name.startsWith('__')) continue
      if (isDmChannelName(ch.name)) continue
      for (const m of ch.members) {
        stateFrameMembershipBySid.set(m.sessionId, ch.name)
      }
    }
    const sidHasPendingFrameOp = (sid: string): boolean => {
      for (const opKey of pendingFrameOpsRef.current) {
        if (opKey.endsWith(`|${sid}`)) return true
      }
      return false
    }
    const normalizedExisting = existingEmbeddables.map((el: any) => {
      const sid = parseSessionFromElement(el)
      if (sid && !liveSids.has(sid)) {
        return { ...el, isDeleted: true }
      }
      const next: any = {
        ...el,
        strokeColor: '#262624',
        backgroundColor: '#262624',
        fillStyle: 'solid',
      }
      if (sid && !sidHasPendingFrameOp(sid)) {
        const expectedChannel = stateFrameMembershipBySid.get(sid) ?? null
        const expectedFrameId = expectedChannel ? channelHubId(expectedChannel) : null
        next.frameId = expectedFrameId
      }
      return next
    })

    // -- Normalize existing channel frames -----------------------------
    // Preserve user-positioned x/y/width/height (frame is a user-resizable
    // container) but re-sync stroke color / strokeStyle based on mode +
    // pending. Tombstone if its channel was deleted.
    const normalizedChannelFrames = existingChannelFrames.map((el: any) => {
      const name = parseChannelFromElement(el)
      const ch = name ? liveChannelByName.get(name) : null
      if (!ch) {
        return { ...el, isDeleted: true }
      }
      return {
        ...el,
        type: 'frame',
        name: `#${ch.name}`,
        strokeColor: modeStrokeColor(ch.mode),
        backgroundColor: 'transparent',
        fillStyle: 'solid',
        strokeWidth: 2,
        strokeStyle: modeStrokeStyle(ch),
        roundness: null,
        opacity: 100,
        locked: false,
        customData: { channelName: ch.name },
      }
    })

    // -- Tombstone legacy ellipse hubs / labels / spokes ---------------
    const tombstone = (el: any) => ({ ...el, isDeleted: true })
    const tombstonedLegacyHubs = legacyHubEllipses.map(tombstone)
    const tombstonedLegacyHubLabels = legacyHubLabels.map(tombstone)
    const tombstonedLegacySpokes = legacySpokes.map(tombstone)
    const tombstonedLegacySpokeLabels = legacySpokeLabels.map(tombstone)

    const preservedExisting = [
      ...userShapes,
      ...normalizedExisting,
      ...normalizedChannelFrames,
      ...tombstonedLegacyHubs,
      ...tombstonedLegacyHubLabels,
      ...tombstonedLegacySpokes,
      ...tombstonedLegacySpokeLabels,
    ]

    const finalElements = [...preservedExisting, ...converted]
    api.updateScene({
      elements: finalElements as any,
    })
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
      void persistence.saveDismissed(dismissedRef.current)
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

    // Optional sid scope — when present, the operation only affects the
    // listed session ids (sidebar's per-category toggle). Absent / empty =
    // operate on every session (top-level "Hide all" / "Show all").
    const scope = bulkVisibilityRequest.sids
    const inScope = scope && scope.length > 0
      ? (sid: string | null) => sid != null && scope.includes(sid)
      : (sid: string | null) => sid != null

    if (bulkVisibilityRequest.mode === 'hide') {
      // 全部隐藏（或 scope 内的全部）：标 isDeleted:true。reportCountsRef 在
      // 一次调用里算每个 sid 的 >0→0 transition，把对应 sid 加入 dismissedRef +
      // 持久化（scope 外的 session 不受影响）。
      const next = all.map((el) => {
        if (el.type !== 'rectangle') return el
        const sid = parseSessionFromElement(el)
        if (!inScope(sid)) return el
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

    // pass 2：完全没 rect 的新建（scope 外的 session 不受影响）
    const needCreate: string[] = []
    for (const s of state.sessions) {
      if (!inScope(s.id)) continue
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

    // 清 dismissed 标记 —— 仅 scope 内的，scope 外的 session 保持原 dismiss 状态
    let dismissedChanged = false
    for (const s of state.sessions) {
      if (!inScope(s.id)) continue
      if (dismissedRef.current.delete(s.id)) dismissedChanged = true
    }
    if (dismissedChanged) void persistence.saveDismissed(dismissedRef.current)

    api.updateScene({ elements: next as any })
    reportCountsRef.current(next)
  }, [api, state, bulkVisibilityRequest, saveLayoutDebounced])

  // -- Place a freshly-created channel frame at the current viewport center --
  // The dialog calls onCreated(name) in App.tsx, which sets
  // placeChannelRequest. We consume it here: compute viewport center (same
  // math as add-to-canvas), write into channelLayoutRef + persist, then
  // schedule a scene rebuild so the frame materialises at that point. The
  // scene-rebuild effect above sees a new-channel-name and builds the frame
  // from channelLayoutRef[name]. DM channels skip this path -- they're
  // visualised as arrows and don't get a managed frame.
  useEffect(() => {
    if (!api || !state || !placeChannelRequest) return
    if (placeChannelRequest.bump === lastPlaceChannelBumpRef.current) return
    lastPlaceChannelBumpRef.current = placeChannelRequest.bump

    const name = placeChannelRequest.channelName
    if (!name || name.startsWith('__')) return
    if (isDmChannelName(name)) return

    const appState = api.getAppState()
    const viewW = appState.width ?? 800
    const viewH = appState.height ?? 600
    const zoom = appState.zoom.value || 1
    const cx = -appState.scrollX + viewW / zoom / 2
    const cy = -appState.scrollY + viewH / zoom / 2
    // Center the frame on viewport center.
    const x = Math.round(cx - CHANNEL_FRAME_W / 2)
    const y = Math.round(cy - CHANNEL_FRAME_H / 2)

    channelLayoutRef.current = {
      ...channelLayoutRef.current,
      [name]: { x, y },
    }
    saveChannelLayoutDebounced(channelLayoutRef.current)

    // If the frame already exists (e.g. the channel was re-created with the
    // same name after a short delete), move it and re-scroll into view.
    const frameEl = api.getSceneElements().find(
      (el) => el.id === channelHubId(name) && (el as any).type === 'frame',
    ) as any
    if (frameEl) {
      const next = api.getSceneElements().map((el) => {
        if (el.id === channelHubId(name) && (el as any).type === 'frame') {
          return { ...el, x, y } as any
        }
        return el
      })
      api.updateScene({ elements: next as any })
      api.scrollToContent([frameEl], { fitToContent: false, animate: true })
    } else {
      // Build and insert immediately using whatever channel snapshot we
      // have; the scene-rebuild effect will normalise it once state updates.
      const ch = state.channels.find((c) => c.name === name)
      if (ch) {
        const skeletons = buildChannelHub(ch, x, y)
        const built = convertToExcalidrawElements(skeletons as any, {
          regenerateIds: false,
        })
        if (built.length > 0) {
          const next = [...api.getSceneElements(), ...built]
          api.updateScene({ elements: next as any })
          api.scrollToContent([built[0]], { fitToContent: false, animate: true })
        }
      }
    }
  }, [api, state, placeChannelRequest, saveChannelLayoutDebounced])

  // -- Focus session card from sidebar click -----------------------------
  useEffect(() => {
    if (!api || !state || !focusSessionRequest) return
    if (focusSessionRequest.bump === lastFocusSessionBumpRef.current) return
    lastFocusSessionBumpRef.current = focusSessionRequest.bump

    const sid = focusSessionRequest.sessionId
    let target = liveSessionRects(api.getSceneElements(), sid)[0]

    if (!target) {
      const all = (api.getSceneElementsIncludingDeleted?.() ?? api.getSceneElements()) as readonly ExcalidrawElement[]
      const prior = all.find(
        (el) =>
          el.type === 'rectangle' &&
          (el as any).isDeleted === true &&
          parseSessionFromElement(el) === sid,
      )

      if (prior) {
        const restored = { ...prior, isDeleted: false } as ExcalidrawElement
        const nextAll = all.map((el) => (el === prior ? restored : el))
        api.updateScene({ elements: nextAll as any })
        reportCountsRef.current(nextAll)
        target = restored
      } else {
        const session = state.sessions.find((s) => s.id === sid)
        if (!session) return

        const saved = layoutRef.current[sid]
        let x: number
        let y: number
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
          x = Math.round(cx - RECT_W / 2)
          y = Math.round(cy - RECT_H / 2)
        }

        const allIds = new Set(
          (api.getSceneElementsIncludingDeleted?.() ?? api.getSceneElements()).map((el) => el.id),
        )
        const preferredId = sessionRectId(session.id)
        const id = allIds.has(preferredId)
          ? `session-${session.id}-${Date.now().toString(36)}`
          : preferredId
        const skeleton = buildSessionEmbeddable(session, x, y, id)
        const [built] = convertToExcalidrawElements([skeleton] as any, {
          regenerateIds: false,
        })
        if (!built) return

        target = built
        const next = [...api.getSceneElements(), built]
        api.updateScene({ elements: next as any })
        reportCountsRef.current(next)
      }
    }

    if (dismissedRef.current.delete(sid)) {
      void persistence.saveDismissed(dismissedRef.current)
    }
    // 关键：focusSceneElement 推到下一帧。否则跟下面 multi-select push-back
    // effect 在同一同步批里跑，Excalidraw 处理 selectedElementIds 时偶发会
    // 把 scroll/zoom 一起重算，导致 focus 改的 scrollX/scrollY 立刻被覆盖
    // —— 用户感受到的"点很多次才切过去"就是这个 race。延后一帧让 focus
    // 单独成 batch，scroll/zoom 改动稳稳生效。
    const targetEl = target
    requestAnimationFrame(() => {
      focusSceneElement(api, targetEl)
    })
  }, [api, state, focusSessionRequest, persistence])

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

  // -- Pan board to the channel hub when sidebar selects a channel ----
  // The hub element may not exist on the very first state delivery; depending
  // on `state` re-runs the effect after the scene-rebuild adds the ellipse.
  // The helper itself is in @meee1/board-core so meee2 can wire the
  // identical effect against its own Sidebar selection.
  useEffect(() => {
    if (!api) return
    if (selection.kind !== 'channel') return
    panToChannelHub(api, selection.channelName)
  }, [api, selection, state])

  // -- onChange: capture movement + selection --------------------------
  const handleChange = useMemo(() => {
    return (elements: readonly ExcalidrawElement[], appState: AppState) => {
      if (!state) return
      let elementsForPersistence: readonly ExcalidrawElement[] = elements

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
      // -- Frame channel membership via Excalidraw frameId --------------
      // Excalidraw assigns frameId on every element when its bbox lands
      // inside a frame's bbox (drag-into-frame gesture). We treat that as
      // an addMember; frameId becoming null (drag-out) as removeMember.
      // Per the user's spec each session card belongs to at most ONE frame
      // channel: if a session has multiple rects spread across different
      // frames, the lexically smallest channel name wins so the choice is
      // deterministic.
      {
        const channelNamesLocal = state.channels
          .map((c) => c.name)
          .filter((n) => !n.startsWith('__') && !isDmChannelName(n))
        const frameChannelByFrameId = new Map<string, string>()
        for (const el of elements) {
          if ((el as any).type !== 'frame' || (el as any).isDeleted) continue
          const name = parseChannelFromElement(el)
          if (name && channelNamesLocal.includes(name)) {
            frameChannelByFrameId.set(el.id, name)
          }
        }
        // sid -> channel currently expressed by frameId on at least one rect
        const desiredFrameMembership = new Map<string, string>()
        for (const el of elements) {
          if (el.type !== 'rectangle' || (el as any).isDeleted) continue
          const sid = parseSessionFromElement(el)
          if (!sid) continue
          const fid = (el as any).frameId as string | null | undefined
          const channel = fid ? frameChannelByFrameId.get(fid) : null
          if (!channel) continue
          const prior = desiredFrameMembership.get(sid)
          if (!prior || channel < prior) desiredFrameMembership.set(sid, channel)
        }
        // Diff against state: each session has at most one frame-channel
        // membership in our world. Channels not in desired -> leave; new
        // -> join.
        const currentFrameMembership = new Map<string, string>()
        for (const ch of state.channels) {
          if (ch.name.startsWith('__')) continue
          if (isDmChannelName(ch.name)) continue
          for (const m of ch.members) {
            currentFrameMembership.set(m.sessionId, ch.name)
          }
        }
        const allSids = new Set<string>([
          ...desiredFrameMembership.keys(),
          ...currentFrameMembership.keys(),
        ])
        for (const sid of allSids) {
          const want = desiredFrameMembership.get(sid) ?? null
          const have = currentFrameMembership.get(sid) ?? null
          if (want === have) continue
          const session = state.sessions.find((s) => s.id === sid)
          const alias = session ? aliasFromSession(session.title, session.id) : null
          if (!alias) continue
          if (have && have !== want) {
            const opKey = `leave|${have}|${sid}`
            if (!pendingFrameOpsRef.current.has(opKey)) {
              pendingFrameOpsRef.current.add(opKey)
              const ch = state.channels.find((c) => c.name === have)
              const aliases = ch
                ? ch.members.filter((m) => m.sessionId === sid).map((m) => m.alias)
                : [alias]
              console.log('[Board.frame] removeMember', { channel: have, sid, aliases })
              void Promise.all(aliases.map((a) => removeMember(have, a)))
                .then(() => {
                  pendingFrameOpsRef.current.delete(opKey)
                  onRefresh()
                })
                .catch((e) => {
                  pendingFrameOpsRef.current.delete(opKey)
                  console.warn('[Board.frame] removeMember failed:', (e as Error).message)
                })
            }
          }
          if (want && want !== have) {
            const opKey = `join|${want}|${sid}`
            if (!pendingFrameOpsRef.current.has(opKey)) {
              pendingFrameOpsRef.current.add(opKey)
              console.log('[Board.frame] addMember', { channel: want, sid, alias })
              void addMember(want, alias, sid)
                .then(() => {
                  pendingFrameOpsRef.current.delete(opKey)
                  onRefresh()
                })
                .catch((e) => {
                  pendingFrameOpsRef.current.delete(opKey)
                  console.warn('[Board.frame] addMember failed:', (e as Error).message)
                })
            }
          }
        }
        knownFrameMembershipsRef.current = desiredFrameMembership
      }

      // -- DM channel via card-to-card arrow ------------------------------
      // Detect every user-drawn arrow whose start AND end bind to session
      // rects -> ensure a `dm-<a>-<b>` channel exists with those two
      // members. When the arrow is deleted, delete the channel.
      {
        const elementsByIdLocal = new Map(elements.map((el) => [el.id, el]))
        const sessionIdsLocal = state.sessions.map((s) => s.id)
        const presentDmChannels = new Map<string, { sidA: string; sidB: string }>()
        const dmAnnotations = new Map<string, DmMeta>()
        for (const el of elements) {
          if (el.type !== 'arrow' || (el as any).isDeleted) continue
          const dm = classifyDmArrow(el, elementsByIdLocal, sessionIdsLocal)
          if (!dm) continue
          const channel = dmChannelName(dm.sidA, dm.sidB)
          presentDmChannels.set(channel, dm)
          dmAnnotations.set(el.id, { channel, sidA: dm.sidA, sidB: dm.sidB })
        }

        if (dmAnnotations.size > 0) {
          elementsForPersistence = elements.map((el) => {
            if (el.type !== 'arrow') return el
            const meta = dmAnnotations.get(el.id)
            return meta ? withDmMeta(el, meta) : el
          }) as readonly ExcalidrawElement[]
        }

        const stateDmChannels = new Set<string>(
          state.channels.filter((c) => isDmChannelName(c.name)).map((c) => c.name),
        )

        // Additions: arrow exists on canvas but channel doesn't.
        for (const [channel, info] of presentDmChannels) {
          if (stateDmChannels.has(channel)) continue
          if (pendingDmOpsRef.current.has(channel)) continue
          const sessionA = state.sessions.find((s) => s.id === info.sidA)
          const sessionB = state.sessions.find((s) => s.id === info.sidB)
          if (!sessionA || !sessionB) continue
          const aliasA = aliasFromSession(sessionA.title, sessionA.id)
          const aliasB = aliasFromSession(sessionB.title, sessionB.id)
          pendingDmOpsRef.current.add(channel)
          console.log('[Board.dm] createChannel', channel, info)
          void createChannel({ name: channel })
            .then(() =>
              Promise.all([
                addMember(channel, aliasA, info.sidA),
                addMember(channel, aliasB, info.sidB),
              ]),
            )
            .then(() => {
              pendingDmOpsRef.current.delete(channel)
              onRefresh()
            })
            .catch((e) => {
              pendingDmOpsRef.current.delete(channel)
              console.warn('[Board.dm] createChannel failed:', (e as Error).message)
            })
        }

        // Removals: channel exists but arrow gone.
        for (const channel of knownDmChannelsRef.current.keys()) {
          if (presentDmChannels.has(channel)) continue
          if (!stateDmChannels.has(channel)) continue
          if (pendingDmOpsRef.current.has(channel)) continue
          pendingDmOpsRef.current.add(channel)
          console.log('[Board.dm] deleteChannel', channel)
          void deleteChannel(channel)
            .then(() => {
              pendingDmOpsRef.current.delete(channel)
              onRefresh()
            })
            .catch((e) => {
              pendingDmOpsRef.current.delete(channel)
              console.warn('[Board.dm] deleteChannel failed:', (e as Error).message)
            })
        }
        knownDmChannelsRef.current = presentDmChannels
      }

      // -- 非-DM channel frames：用户在画板上删 frame ⇔ 删 channel ----
      // 与 DM 段对齐的逻辑：本 tick 看到的非-DM channel frame 名集合，对比
      // 上一 tick 的 known 集合 + 当前 state.channels。
      //   - frame 出现且 channel 也存在 → 不动（创建路径走 NewChannelDialog）
      //   - frame 消失但 channel 还在 → 用户按 Delete 删掉了 frame → 调
      //     deleteChannel 让 backend 同步删，否则下一次 scene 重建又冒回来
      {
        const presentChannelFrames = new Set<string>()
        for (const el of elements) {
          if ((el as any).type !== 'frame' || (el as any).isDeleted) continue
          const name = parseChannelFromElement(el)
          if (!name) continue
          if (isDmChannelName(name)) continue
          presentChannelFrames.add(name)
        }
        const stateChannelNames = new Set<string>(
          state.channels.filter((c) => !isDmChannelName(c.name)).map((c) => c.name),
        )
        for (const name of knownChannelFramesRef.current) {
          if (presentChannelFrames.has(name)) continue
          if (!stateChannelNames.has(name)) continue
          if (pendingDmOpsRef.current.has(name)) continue
          pendingDmOpsRef.current.add(name)
          console.log('[Board.channelFrame] deleteChannel', name)
          void deleteChannel(name)
            .then(() => {
              pendingDmOpsRef.current.delete(name)
              onRefresh()
            })
            .catch((e) => {
              pendingDmOpsRef.current.delete(name)
              console.warn('[Board.channelFrame] deleteChannel failed:', (e as Error).message)
            })
        }
        knownChannelFramesRef.current = presentChannelFrames
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
      saveShapesDebounced(elementsForPersistence)
    }
  }, [state, selection, onSelectionChange, saveLayoutDebounced, saveChannelLayoutDebounced, api, saveAppStateDebounced, saveShapesDebounced, onRefresh])

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
        {/* 之前 Footer 里有个手动 Refresh 按钮（贴 Excalidraw 原生 zoom/
            undo/redo 旁边）。WS state.changed 已经把状态推到位，按用户
            要求去掉了。MainMenu 里的 "Refresh" 入口保留作为兜底。 */}
      </Excalidraw>
      {/* Channel actions —— portal 进 Excalidraw 自己的 .App-toolbar，
          作为 shape tool 旁边的两个图标按钮，视觉上完全融合。
          Excalidraw 没暴露 shape tool 注册 API（社区 issue #7583 / #6697
          确认只有 MainMenu/Footer/renderTopRightUI 三个公开口子），所以
          走 React Portal 直接 attach 到 toolbar DOM 节点，是目前唯一
          能做到"加一个图标按钮跟 rectangle/ellipse 同列"的办法。 */}
      {toolbarRowEl && createPortal(
        <>
          {/* className 跟 native shape tool 一致：`ToolIcon ToolIcon_size_medium`。
              不加 `ToolIcon_type_floating` —— 那条会让 .ToolIcon__icon 套一个
              深色背景，和原生 shape tool（透明背景）不一致。 */}
          <Tooltip label="Create a new channel">
            <button
              className="ToolIcon ToolIcon_size_medium board-channel-tool"
              onClick={onNewChannel}
              type="button"
              aria-label="Create channel"
            >
              <div className="ToolIcon__icon" tabIndex={-1}>
                <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
                  <rect x="3" y="3" width="18" height="18" rx="3" stroke="currentColor" strokeWidth="1.6"/>
                  <path d="M12 8v8M8 12h8" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
                </svg>
              </div>
            </button>
          </Tooltip>
          <Tooltip label="Create DM line: drag from one session card to another">
          <button
            className="ToolIcon ToolIcon_size_medium board-channel-tool"
            onClick={() => {
              if (!api) return
              try {
                ;(api as any).setActiveTool({ type: 'arrow' })
              } catch (e) {
                console.warn('[Board] setActiveTool(arrow) failed', e)
              }
            }}
            type="button"
            aria-label="Create DM line"
          >
            <div className="ToolIcon__icon" tabIndex={-1}>
              <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
                <circle cx="6" cy="12" r="2" stroke="currentColor" strokeWidth="1.6"/>
                <circle cx="18" cy="12" r="2" stroke="currentColor" strokeWidth="1.6"/>
                <path d="M8 12h8" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round"/>
              </svg>
            </div>
          </button>
          </Tooltip>
        </>,
        toolbarRowEl,
      )}
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
