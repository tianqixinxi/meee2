import { useEffect, useMemo, useRef, useState } from 'react'
import { connectEvents, type BoardEventFrame } from '../api'

/**
 * RT-3 + RT-5 (team-canvas-sharing) — desktop board realtime over the local
 * BoardServer `/api/events` socket.
 *
 * The board-app never opens its own Supabase Realtime socket; the Swift
 * BoardServer is the single fan-in/fan-out point. It already pushed coarse
 * `state.changed` ticks (consumed by {@link useBoardState}). This hook adds the
 * two finer signals Phase 3 introduces:
 *
 * - RT-3 `node.changed` — a single node on a single canvas changed. We bump a
 *   per-node revision counter so a node view can re-render *only itself*
 *   (`useNodeRevision(canvasId, nodeId)`), avoiding a full board rehydrate when
 *   only one teammate's sub-canvas node moved.
 * - RT-5 `presence.update` — short-TTL "who is editing which node". We keep a
 *   live, self-expiring map keyed by `userId`, scoped to the active canvas, so
 *   the board can paint presence dots on nodes.
 *
 * The hook owns a *single* extra socket subscription for the whole board; node
 * views read from its return value rather than each opening their own.
 */

/** RT-5 presence entry, already TTL-filtered to "currently active" editors. */
export interface PresenceEntry {
  userId: string
  displayName: string | null
  /** The node the user is editing; null = editing the canvas at large. */
  nodeId: string | null
  /** Epoch ms of the last beacon; used for TTL expiry. */
  lastSeen: number
}

export interface UseCanvasRealtimeOptions {
  /** The canvas currently shown; presence + node revisions are scoped to it. */
  activeCanvasId: string | null | undefined
  /** Drop presence entries older than this (ms). Default 15s (short TTL). */
  presenceTtlMs?: number
  /** Ignore our own presence beacons (we know we are editing). */
  selfUserId?: string | null
}

export interface UseCanvasRealtimeResult {
  /**
   * Monotonic revision per `"${canvasId}:${nodeId}"`. A node view keys an
   * effect on `nodeRevisions[`${canvasId}:${nodeId}`]` to refetch just itself.
   */
  nodeRevisions: Record<string, number>
  /** Live presence for the active canvas (TTL-filtered, self excluded). */
  presence: PresenceEntry[]
  /** Presence grouped by nodeId for quick per-node lookup (null key = canvas). */
  presenceByNode: Map<string | null, PresenceEntry[]>
}

const DEFAULT_PRESENCE_TTL_MS = 15_000

export function useCanvasRealtime(
  options: UseCanvasRealtimeOptions,
): UseCanvasRealtimeResult {
  const { activeCanvasId, presenceTtlMs = DEFAULT_PRESENCE_TTL_MS, selfUserId = null } = options

  const [nodeRevisions, setNodeRevisions] = useState<Record<string, number>>({})
  // Raw presence keyed by userId; we re-derive the TTL-filtered view on a timer
  // so entries expire even without a new frame arriving.
  const presenceRef = useRef<Map<string, PresenceEntry>>(new Map())
  const [presenceTick, setPresenceTick] = useState(0)

  // Keep the active-canvas id in a ref so the long-lived socket handler always
  // reads the latest value without re-subscribing on every canvas switch.
  const activeCanvasIdRef = useRef<string | null>(activeCanvasId ?? null)
  useEffect(() => {
    activeCanvasIdRef.current = activeCanvasId ?? null
  }, [activeCanvasId])

  const selfUserIdRef = useRef<string | null>(selfUserId)
  useEffect(() => {
    selfUserIdRef.current = selfUserId
  }, [selfUserId])

  useEffect(() => {
    const handleFrame = (frame: BoardEventFrame) => {
      if (frame.type === 'node.changed') {
        const key = `${frame.canvasId}:${frame.nodeId}`
        setNodeRevisions((prev) => ({ ...prev, [key]: (prev[key] ?? 0) + 1 }))
        return
      }
      if (frame.type === 'presence.update') {
        // Only track presence for the canvas the user is currently looking at,
        // and never our own beacons.
        if (frame.canvasId !== activeCanvasIdRef.current) return
        if (selfUserIdRef.current && frame.userId === selfUserIdRef.current) return
        const map = presenceRef.current
        if (frame.gone) {
          map.delete(frame.userId)
        } else {
          map.set(frame.userId, {
            userId: frame.userId,
            displayName: frame.displayName,
            nodeId: frame.nodeId,
            lastSeen: Date.parse(frame.at) || Date.now(),
          })
        }
        setPresenceTick((value) => value + 1)
      }
    }

    // connectEvents auto-reconnects; the no-op onChange/onStatus keep this
    // subscription independent of useBoardState's (which owns the refetch loop).
    const dispose = connectEvents(
      () => {},
      () => {},
      handleFrame,
    )
    return dispose
  }, [])

  // When the active canvas changes, drop presence for the old canvas — a new
  // canvas starts with a clean presence slate.
  useEffect(() => {
    presenceRef.current.clear()
    setPresenceTick((value) => value + 1)
  }, [activeCanvasId])

  // Expiry sweep: re-derive the filtered presence view on a short interval so
  // stale beacons disappear even if no new frame arrives.
  useEffect(() => {
    const timer = window.setInterval(() => {
      const now = Date.now()
      let pruned = false
      for (const [userId, entry] of presenceRef.current) {
        if (now - entry.lastSeen > presenceTtlMs) {
          presenceRef.current.delete(userId)
          pruned = true
        }
      }
      if (pruned) setPresenceTick((value) => value + 1)
    }, Math.max(1_000, Math.floor(presenceTtlMs / 3)))
    return () => window.clearInterval(timer)
  }, [presenceTtlMs])

  const presence = useMemo(() => {
    const now = Date.now()
    return Array.from(presenceRef.current.values())
      .filter((entry) => now - entry.lastSeen <= presenceTtlMs)
      .sort((a, b) => b.lastSeen - a.lastSeen)
    // presenceTick is the dependency that re-derives this on every change.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [presenceTick, presenceTtlMs])

  const presenceByNode = useMemo(() => {
    const grouped = new Map<string | null, PresenceEntry[]>()
    for (const entry of presence) {
      const list = grouped.get(entry.nodeId)
      if (list) list.push(entry)
      else grouped.set(entry.nodeId, [entry])
    }
    return grouped
  }, [presence])

  return { nodeRevisions, presence, presenceByNode }
}
