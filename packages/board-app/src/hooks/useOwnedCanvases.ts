import { useCallback, useEffect, useRef, useState } from 'react'
import { getAssignedCanvases } from '../api'
import type { CanvasInfo } from '../types'

/**
 * API-1 (team-canvas-sharing) — desktop hook that pulls the sub-canvases the
 * current user received via assignment (`meee2_assign_node` → owned sub-canvas
 * with a `parentCanvasId`) and exposes them already tagged
 * `assignmentScope='assigned'` so the switcher can group them under "分派给我".
 *
 * Why a separate fetch from the main `/api/canvases` list: assigned
 * sub-canvases are owned by the current user but rooted under a *parent canvas
 * owned by someone else*, so they are not part of the local board's own canvas
 * tree. We merge them in client-side. The hook mirrors the existing
 * coalesced-refresh idiom in App.tsx (debounced refresh on demand + an
 * optional interval) without depending on react-query, which board-app does
 * not use.
 *
 * The hook is purely additive: a fetch failure leaves the list empty and never
 * blocks the primary canvas list. Callers concat `assignedCanvases` onto the
 * `CanvasList.canvases` they already render.
 */
export interface UseOwnedCanvasesOptions {
  /** Display name of the current user; stamped on assigned canvases. */
  selfDisplayName?: string | null
  /**
   * Only fetch when connected to an online team. When `false` the hook stays
   * idle and reports an empty list (a purely local board has no assignments).
   */
  enabled?: boolean
  /** Optional background poll interval (ms). Omit/0 to disable polling. */
  pollIntervalMs?: number
}

export interface UseOwnedCanvasesResult {
  /** Sub-canvases assigned to the current user, tagged `assignmentScope='assigned'`. */
  assignedCanvases: CanvasInfo[]
  loading: boolean
  error: string | null
  /** Force a re-fetch (e.g. after an assign succeeds, or on a realtime ping). */
  refresh: () => Promise<void>
}

export function useOwnedCanvases(
  options: UseOwnedCanvasesOptions = {},
): UseOwnedCanvasesResult {
  const { selfDisplayName = null, enabled = true, pollIntervalMs = 0 } = options
  const [assignedCanvases, setAssignedCanvases] = useState<CanvasInfo[]>([])
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  // Guard against setState after unmount and against overlapping fetches.
  const mountedRef = useRef(true)
  const inFlightRef = useRef(false)

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
    }
  }, [])

  const refresh = useCallback(async () => {
    if (!enabled) {
      if (mountedRef.current) setAssignedCanvases([])
      return
    }
    if (inFlightRef.current) return
    inFlightRef.current = true
    if (mountedRef.current) setLoading(true)
    try {
      const canvases = await getAssignedCanvases(selfDisplayName)
      if (mountedRef.current) {
        setAssignedCanvases(canvases)
        setError(null)
      }
    } catch (err) {
      if (mountedRef.current) {
        setError((err as Error).message || 'Failed to load assigned canvases')
      }
    } finally {
      inFlightRef.current = false
      if (mountedRef.current) setLoading(false)
    }
  }, [enabled, selfDisplayName])

  // Initial + on enablement / identity change.
  useEffect(() => {
    if (!enabled) {
      setAssignedCanvases([])
      return
    }
    void refresh()
  }, [enabled, refresh])

  // Optional background poll, mirroring the desktop's owned-canvas sync cadence.
  useEffect(() => {
    if (!enabled || !pollIntervalMs) return
    const timer = window.setInterval(() => {
      void refresh()
    }, pollIntervalMs)
    return () => window.clearInterval(timer)
  }, [enabled, pollIntervalMs, refresh])

  return { assignedCanvases, loading, error, refresh }
}
