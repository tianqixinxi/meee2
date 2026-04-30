// Headless board canvas — Excalidraw shell + persistence wiring + scene sync,
// with render slots for app-specific UI (sidebars, inspectors, chat panels).
//
// Status: v0.1. Handles the cross-app subset: sessions on the canvas,
// viewport / user-shape persistence, selection sync. Does NOT yet handle
// channels (arrows, hub ellipses, member-arrow detection) — meee2's Board
// keeps its own implementation for now and will adopt this incrementally
// once channels are abstracted. meee360 can consume this as-is in Phase 7.
//
// Why headless: meee2 and meee360 need different chrome around the canvas —
// meee2 has a CardHost / SessionOverlay / ChannelDetail, meee360 has a
// TeamSidebar / Inspector / BoardChatPanel. Trying to ship a "complete board"
// would force one app's UI patterns onto the other. Slot-based composition
// keeps the shared piece (canvas plumbing) shared and lets each app render
// its own chrome.

import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { Excalidraw, convertToExcalidrawElements } from '@excalidraw/excalidraw'
import type {
  ExcalidrawImperativeAPI,
  AppState,
} from '@excalidraw/excalidraw/types'
import type { ExcalidrawElement } from '@excalidraw/excalidraw/element/types'
import {
  buildSessionRect,
  debounce,
  ensurePositions,
  isManagedElementId,
  parseSessionFromElement,
  RECT_W,
  RECT_H,
  sessionRectId,
  type BoardStateForScene,
  type CanvasPersistence,
  type LayoutMap,
  type PersistedViewport,
  type SessionForScene,
} from '@tianqixinxi/board-core'

export type Selection =
  | { kind: 'none' }
  | { kind: 'session'; sessionId: string }

/** Initial state hydrated by the parent — caller resolves persistence.loadXxx
 *  promises before mounting BoardCanvas so first render has values. */
export interface BoardCanvasInitial {
  sessionLayout: LayoutMap
  channelLayout: LayoutMap
  viewport: PersistedViewport | null
  userElements: ExcalidrawElement[] | any[]
}

export interface BoardCanvasProps {
  /** Sessions + channels in the structural shape board-core expects. App
   *  passes `{ sessions: TeamSession[], channels: [] }` (or its own derived
   *  ChannelForScene[]) and structural typing handles the rest. */
  state: BoardStateForScene
  /** Async storage interface — implementations live in
   *  @tianqixinxi/board-persistence-http (meee2) / a Supabase impl (meee360). */
  persistence: CanvasPersistence
  /** Hydrated initial values for every persisted slot. */
  initial: BoardCanvasInitial
  /** Current selection (driven by the parent). */
  selection: Selection
  /** Fires when the user clicks a session card or empty space. */
  onSelectionChange: (selection: Selection) => void
  /** Optional: render an absolutely-positioned DOM overlay above each session
   *  rectangle (for rich card UIs that don't render via Excalidraw). The
   *  caller positions itself; this slot just gives access to the API. */
  renderSessionOverlay?: (api: ExcalidrawImperativeAPI) => ReactNode
  /** Optional chrome slots — rendered above / beside the canvas. */
  renderTopBar?: () => ReactNode
  renderSidebar?: () => ReactNode
}

/**
 * Build a stable signature of user-drawn elements so we only persist when
 * something actually changed (id+version+versionNonce+isDeleted captures
 * Excalidraw's update events without false positives on render-only diffs).
 */
function userElementSignature(elements: readonly ExcalidrawElement[]): string {
  return elements
    .map((el: any) => `${el.id}:${el.version ?? 0}:${el.versionNonce ?? 0}:${el.isDeleted ? 1 : 0}`)
    .join('|')
}

function viewportChanged(
  prev: PersistedViewport | null,
  next: PersistedViewport,
): boolean {
  if (!prev) return true
  return (
    Math.abs(prev.scrollX - next.scrollX) >= 1 ||
    Math.abs(prev.scrollY - next.scrollY) >= 1 ||
    Math.abs(prev.zoom - next.zoom) >= 0.001
  )
}

export function BoardCanvas({
  state,
  persistence,
  initial,
  selection,
  onSelectionChange,
  renderSessionOverlay,
  renderTopBar,
  renderSidebar,
}: BoardCanvasProps) {
  const [api, setApi] = useState<ExcalidrawImperativeAPI | null>(null)

  const sessionLayoutRef = useRef<LayoutMap>(initial.sessionLayout)
  const lastUserSigRef = useRef<string>(userElementSignature(initial.userElements))
  const lastViewportRef = useRef<PersistedViewport | null>(initial.viewport)

  // Initial scene + appState passed to Excalidraw at mount. Excalidraw only
  // reads initialData once — subsequent updates go through the imperative API.
  const initialData = useMemo(() => ({
    elements: initial.userElements,
    appState: initial.viewport
      ? {
          scrollX: initial.viewport.scrollX,
          scrollY: initial.viewport.scrollY,
          zoom: { value: initial.viewport.zoom },
        }
      : undefined,
  }), [initial])

  const saveLayoutDebounced = useMemo(
    () => debounce((m: LayoutMap) => { void persistence.saveSessionLayout(m) }, 400),
    [persistence],
  )
  const saveUserShapesDebounced = useMemo(
    () => debounce((els: readonly any[]) => { void persistence.saveUserElements(els) }, 400),
    [persistence],
  )
  const saveViewportDebounced = useMemo(
    () => debounce((v: PersistedViewport) => { void persistence.saveViewport(v) }, 400),
    [persistence],
  )

  // Sync sessions → canvas rects. Adds rects for new sessions, removes rects
  // for sessions that disappeared, and updates the layout map with current
  // positions (so dragged sessions are persisted on the next debounce tick).
  useEffect(() => {
    if (!api) return
    const sessionIds = state.sessions.map((s) => s.id)
    const currentElements = api.getSceneElements()

    const currentLayout = { ...sessionLayoutRef.current }
    for (const el of currentElements) {
      if (el.type !== 'rectangle' || (el as any).isDeleted) continue
      const sid = parseSessionFromElement(el as any)
      if (sid) currentLayout[sid] = { x: el.x, y: el.y }
    }
    const sessionLayout = ensurePositions(sessionIds, currentLayout)
    sessionLayoutRef.current = sessionLayout
    saveLayoutDebounced(sessionLayout)

    const existingSids = new Set<string>()
    for (const el of currentElements) {
      const sid = parseSessionFromElement(el as any)
      if (sid) existingSids.add(sid)
    }
    const newSids = sessionIds.filter((id) => !existingSids.has(id))
    const idsToRemove: string[] = []
    for (const el of currentElements) {
      const sid = parseSessionFromElement(el as any)
      if (sid && !sessionIds.includes(sid)) idsToRemove.push(el.id)
    }

    if (newSids.length === 0 && idsToRemove.length === 0) return

    const newSkeletons = newSids.map((sid) => {
      const pos = sessionLayout[sid] ?? { x: 80, y: 80 }
      return buildSessionRect(sid, pos.x, pos.y)
    })
    const newElements = convertToExcalidrawElements(newSkeletons as any)

    const removeSet = new Set(idsToRemove)
    const next = currentElements
      .filter((el) => !removeSet.has(el.id))
      .concat(newElements as any)

    api.updateScene({ elements: next })
  }, [api, state.sessions, saveLayoutDebounced])

  // Selection sync: read Excalidraw's selectedElementIds → emit
  // onSelectionChange when the picked session changes.
  useEffect(() => {
    if (!api) return
    const off = api.onChange((elements: readonly ExcalidrawElement[], appState: AppState) => {
      // Persist user-drawn shapes (everything except managed session/channel ids).
      const userElements = elements.filter(
        (el: any) => !el.isDeleted && !isManagedElementId(el.id),
      )
      const sig = userElementSignature(userElements as ExcalidrawElement[])
      if (sig !== lastUserSigRef.current) {
        lastUserSigRef.current = sig
        saveUserShapesDebounced(userElements)
      }

      // Viewport: only debounce-save when scroll/zoom actually moved.
      const nextVp: PersistedViewport = {
        scrollX: appState.scrollX,
        scrollY: appState.scrollY,
        zoom: appState.zoom?.value ?? 1,
      }
      if (viewportChanged(lastViewportRef.current, nextVp)) {
        lastViewportRef.current = nextVp
        saveViewportDebounced(nextVp)
      }

      // Selection bridge: pick the first session rect (if any) under selection.
      const selectedIds = Object.keys(appState.selectedElementIds ?? {})
      let nextSelection: Selection = { kind: 'none' }
      for (const id of selectedIds) {
        const el = elements.find((e) => e.id === id) as any
        const sid = el ? parseSessionFromElement(el) : null
        if (sid) {
          nextSelection = { kind: 'session', sessionId: sid }
          break
        }
      }
      // Only fire when actually different — caller can re-render freely.
      if (
        (nextSelection.kind === 'none' && selection.kind !== 'none') ||
        (nextSelection.kind === 'session' &&
          (selection.kind !== 'session' || selection.sessionId !== nextSelection.sessionId))
      ) {
        onSelectionChange(nextSelection)
      }
    })
    return off
  }, [api, selection, onSelectionChange, saveUserShapesDebounced, saveViewportDebounced])

  return (
    <div className="meee2-board-canvas">
      {renderTopBar?.()}
      <div className="meee2-board-canvas__main">
        <div className="meee2-board-canvas__excalidraw">
          <Excalidraw
            initialData={initialData as any}
            excalidrawAPI={(handle) => setApi(handle)}
            theme="dark"
          />
          {api && renderSessionOverlay?.(api)}
        </div>
        {renderSidebar?.()}
      </div>
    </div>
  )
}

// Re-export the consts that overlay implementations need to position
// themselves over a session rect.
export { RECT_W, RECT_H, sessionRectId }
export type { SessionForScene }
