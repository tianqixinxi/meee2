// CommandPalette — global Cmd+K / Ctrl+K launcher.
//
// Surfaces three search domains:
//   - canvases  (from CanvasList: name + kind)
//   - nodes     (from PlannerMonitorState.items: title + status + canvas)
//   - sessions  (from BoardState.sessions: title)
//
// Substring (case-insensitive, fzf-lite: simple subsequence fallback) — no
// third-party fuzzy search dependency, per release plan QC P1 chunk C.
//
// Wire-up: rendered at the top of App.tsx; handlers come from there.

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { fetchPlannerWorkspaceMonitor } from '../api'
import type { BoardState, CanvasInfo, PlannerMonitorItem } from '../types'

type ItemKind = 'canvas' | 'node' | 'session'

interface PaletteItem {
  kind: ItemKind
  id: string
  /** Primary text shown on the row. */
  label: string
  /** Secondary muted text (kind / status / canvas). */
  detail?: string
  /** Internal search corpus (lower-cased). */
  haystack: string
  /** Original record (used to dispatch). */
  payload:
    | { kind: 'canvas'; canvas: CanvasInfo }
    | { kind: 'node'; item: PlannerMonitorItem }
    | { kind: 'session'; sessionId: string; canvasIdHint?: string | null }
}

interface CommandPaletteProps {
  canvases: CanvasInfo[]
  boardState: BoardState | null
  onOpenCanvas: (canvasId: string) => void
  onOpenNodeInspector: (canvasId: string, nodeId: string) => void
  onOpenSession: (sessionId: string) => void
}

const MAX_PER_SECTION = 5

/**
 * Naive but predictable scorer:
 *   - exact substring → big bonus + position weight
 *   - subsequence (every char of query appears in order) → small bonus
 *   - otherwise → not a match
 *
 * Higher = better. Returns null if not a match.
 */
function score(query: string, haystack: string): number | null {
  if (!query) return 0
  const q = query.toLowerCase()
  const h = haystack
  const idx = h.indexOf(q)
  if (idx >= 0) {
    // earlier match is better; bonus for word-boundary
    const boundaryBonus = idx === 0 || /\s|[/_\-:.]/.test(h[idx - 1] ?? '') ? 50 : 0
    return 1000 - idx + boundaryBonus + q.length
  }
  // subsequence
  let j = 0
  let lastPos = -1
  let spread = 0
  for (let i = 0; i < h.length && j < q.length; i++) {
    if (h[i] === q[j]) {
      if (lastPos >= 0) spread += i - lastPos - 1
      lastPos = i
      j++
    }
  }
  if (j === q.length) {
    return Math.max(0, 200 - spread)
  }
  return null
}

export function CommandPalette({
  canvases,
  boardState,
  onOpenCanvas,
  onOpenNodeInspector,
  onOpenSession,
}: CommandPaletteProps) {
  const [open, setOpen] = useState(false)
  const [query, setQuery] = useState('')
  const [selectedIndex, setSelectedIndex] = useState(0)
  const [monitorItems, setMonitorItems] = useState<PlannerMonitorItem[]>([])
  const inputRef = useRef<HTMLInputElement | null>(null)
  const listRef = useRef<HTMLDivElement | null>(null)

  // Global hotkey: Cmd+K / Ctrl+K → toggle; Esc → close.
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      // Toggle (cmd/ctrl + K)
      if ((event.metaKey || event.ctrlKey) && !event.altKey && !event.shiftKey && event.key.toLowerCase() === 'k') {
        event.preventDefault()
        setOpen((value) => !value)
        return
      }
      if (event.key === 'Escape' && open) {
        event.preventDefault()
        setOpen(false)
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [open])

  // Refresh planner monitor (cross-canvas nodes) each time the palette opens
  // so search reflects current workflow state without a hot reactive feed.
  useEffect(() => {
    if (!open) return
    let cancelled = false
    fetchPlannerWorkspaceMonitor()
      .then((state) => {
        if (!cancelled) setMonitorItems(state.items ?? [])
      })
      .catch(() => {
        if (!cancelled) setMonitorItems([])
      })
    return () => {
      cancelled = true
    }
  }, [open])

  // Focus the input on open; reset on close.
  useEffect(() => {
    if (open) {
      // Defer to next paint so the input is mounted & autoFocus has settled.
      const id = window.setTimeout(() => inputRef.current?.focus(), 0)
      return () => window.clearTimeout(id)
    }
    setQuery('')
    setSelectedIndex(0)
  }, [open])

  // Build candidate corpora.
  const allCanvasItems = useMemo<PaletteItem[]>(
    () =>
      canvases.map((canvas) => {
        const kindLabel = canvas.kind ? String(canvas.kind) : 'canvas'
        return {
          kind: 'canvas',
          id: canvas.id,
          label: canvas.name || canvas.id,
          detail: kindLabel,
          haystack: `${canvas.name} ${kindLabel} ${canvas.id}`.toLowerCase(),
          payload: { kind: 'canvas', canvas },
        }
      }),
    [canvases],
  )

  const allNodeItems = useMemo<PaletteItem[]>(
    () =>
      monitorItems
        .filter((item) => item.kind === 'node' && item.nodeId)
        .map((item) => ({
          kind: 'node',
          id: `${item.canvasId}:${item.nodeId}`,
          label: item.nodeTitle || item.summary || item.nodeId || 'node',
          detail: `${item.runState ?? ''}${item.runState && item.canvasTitle ? ' · ' : ''}${item.canvasTitle ?? ''}`.trim(),
          haystack: `${item.nodeTitle ?? ''} ${item.summary ?? ''} ${item.runState ?? ''} ${item.canvasTitle ?? ''}`.toLowerCase(),
          payload: { kind: 'node', item },
        })),
    [monitorItems],
  )

  const allSessionItems = useMemo<PaletteItem[]>(
    () =>
      (boardState?.sessions ?? []).map((session) => ({
        kind: 'session',
        id: session.id,
        label: session.title || session.id,
        detail: session.status,
        haystack: `${session.title ?? ''} ${session.project ?? ''} ${session.status ?? ''} ${session.id}`.toLowerCase(),
        payload: { kind: 'session', sessionId: session.id },
      })),
    [boardState],
  )

  // Filter + score within each domain, cap to MAX_PER_SECTION.
  const sections = useMemo(() => {
    const q = query.trim()
    const rank = (items: PaletteItem[]): PaletteItem[] => {
      if (!q) return items.slice(0, MAX_PER_SECTION)
      const scored = items
        .map((item) => ({ item, s: score(q, item.haystack) }))
        .filter((row): row is { item: PaletteItem; s: number } => row.s !== null)
        .sort((a, b) => b.s - a.s)
        .slice(0, MAX_PER_SECTION)
        .map((row) => row.item)
      return scored
    }
    return [
      { key: 'canvas' as const, title: 'Canvas', items: rank(allCanvasItems) },
      { key: 'node' as const, title: 'Node', items: rank(allNodeItems) },
      { key: 'session' as const, title: 'Session', items: rank(allSessionItems) },
    ]
  }, [allCanvasItems, allNodeItems, allSessionItems, query])

  // Flatten for keyboard navigation (skips empty sections).
  const flatItems = useMemo<PaletteItem[]>(
    () => sections.flatMap((section) => section.items),
    [sections],
  )

  // Clamp selectedIndex when results change.
  useEffect(() => {
    if (selectedIndex >= flatItems.length) {
      setSelectedIndex(0)
    }
  }, [flatItems.length, selectedIndex])

  const activate = useCallback(
    (item: PaletteItem | undefined) => {
      if (!item) return
      setOpen(false)
      const payload = item.payload
      if (payload.kind === 'canvas') {
        onOpenCanvas(payload.canvas.id)
      } else if (payload.kind === 'node') {
        const canvasId = payload.item.canvasId
        const nodeId = payload.item.nodeId
        if (!canvasId || !nodeId) return
        onOpenNodeInspector(canvasId, nodeId)
      } else if (payload.kind === 'session') {
        onOpenSession(payload.sessionId)
      }
    },
    [onOpenCanvas, onOpenNodeInspector, onOpenSession],
  )

  const onInputKeyDown = useCallback(
    (event: React.KeyboardEvent<HTMLInputElement>) => {
      if (event.key === 'ArrowDown') {
        event.preventDefault()
        setSelectedIndex((idx) => (flatItems.length === 0 ? 0 : (idx + 1) % flatItems.length))
        return
      }
      if (event.key === 'ArrowUp') {
        event.preventDefault()
        setSelectedIndex((idx) => (flatItems.length === 0 ? 0 : (idx - 1 + flatItems.length) % flatItems.length))
        return
      }
      if (event.key === 'Enter') {
        event.preventDefault()
        activate(flatItems[selectedIndex])
        return
      }
    },
    [activate, flatItems, selectedIndex],
  )

  // Scroll the selected row into view as the user navigates.
  useEffect(() => {
    if (!open) return
    const container = listRef.current
    if (!container) return
    const target = container.querySelector<HTMLElement>(`[data-cp-index="${selectedIndex}"]`)
    if (target) {
      target.scrollIntoView({ block: 'nearest' })
    }
  }, [open, selectedIndex])

  if (!open) return null

  let runningIndex = 0
  return (
    <div
      className="command-palette__backdrop"
      role="dialog"
      aria-modal="true"
      aria-label="Command palette"
      onMouseDown={(event) => {
        // Clicking outside the surface closes the palette.
        if (event.target === event.currentTarget) setOpen(false)
      }}
    >
      <div className="command-palette__surface">
        <div className="command-palette__input-row">
          <span className="command-palette__hint" aria-hidden>{'>'}</span>
          <input
            ref={inputRef}
            className="command-palette__input"
            type="text"
            autoFocus
            placeholder="Search canvases, nodes, sessions..."
            value={query}
            spellCheck={false}
            onChange={(event) => {
              setQuery(event.target.value)
              setSelectedIndex(0)
            }}
            onKeyDown={onInputKeyDown}
          />
          <kbd className="command-palette__kbd">Esc</kbd>
        </div>
        <div className="command-palette__list" ref={listRef}>
          {flatItems.length === 0 ? (
            <div className="command-palette__empty">No matches.</div>
          ) : (
            sections.map((section) => {
              if (section.items.length === 0) return null
              return (
                <div key={section.key} className="command-palette__section">
                  <div className="command-palette__section-title">{section.title}</div>
                  {section.items.map((item) => {
                    const myIndex = runningIndex
                    runningIndex += 1
                    const isSelected = myIndex === selectedIndex
                    return (
                      <div
                        key={`${item.kind}:${item.id}`}
                        data-cp-index={myIndex}
                        className={`command-palette__row${isSelected ? ' command-palette__row--selected' : ''}`}
                        onMouseEnter={() => setSelectedIndex(myIndex)}
                        onMouseDown={(event) => {
                          // Use mouseDown so we activate before blur/cleanup.
                          event.preventDefault()
                          activate(item)
                        }}
                      >
                        <span className="command-palette__row-label">{item.label}</span>
                        {item.detail && (
                          <span className="command-palette__row-detail">{item.detail}</span>
                        )}
                      </div>
                    )
                  })}
                </div>
              )
            })
          )}
        </div>
      </div>
    </div>
  )
}
