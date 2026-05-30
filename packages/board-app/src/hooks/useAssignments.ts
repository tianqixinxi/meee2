import { useCallback, useEffect, useRef, useState } from 'react'
import { fetchCanvasAssignments, revokeNodeAssignment } from '../api'
import type { AssignmentDTO, RevokeAssignmentResult } from '../types'

/**
 * AS-2 / AS-3 (team-canvas-sharing) — desktop hook over a single canvas's node
 * assignments. It powers the node inspector's revoke control and (later) the
 * assignment-history view: it loads the active assignments a canvas owner has
 * handed out (`meee2_node_assignments` via the AS-2 proxy) and exposes a
 * {@link revoke} action that calls the AS-3 reverse-assign RPC.
 *
 * Mirrors the coalesced-refresh idiom in {@link useOwnedCanvases} (manual
 * refresh + guarded in-flight, no react-query). The hook is additive: a fetch
 * failure leaves the list empty and surfaces an `error` string without throwing
 * to the render tree. A purely local board (no team) keeps the hook idle via
 * `enabled = false`.
 */
export interface UseAssignmentsOptions {
  /** The source canvas whose handed-out assignments we track. */
  canvasId: string | null | undefined
  /**
   * Only fetch when connected to an online team / editing a shareable canvas.
   * When `false` the hook stays idle and reports an empty list.
   */
  enabled?: boolean
  /** Include revoked rows (AS-6 history). Default: active assignments only. */
  includeRevoked?: boolean
}

export interface UseAssignmentsResult {
  assignments: AssignmentDTO[]
  loading: boolean
  error: string | null
  /** Force a re-fetch (e.g. after an assign/revoke succeeds, or a realtime ping). */
  refresh: () => Promise<void>
  /**
   * Revoke the assignment on `nodeId` (AS-3). On success the local list is
   * refreshed so the just-revoked row drops out (or flips to revoked when
   * `includeRevoked`). Rejects with the underlying error so the caller can
   * surface its own toast / inline message.
   */
  revoke: (nodeId: string) => Promise<RevokeAssignmentResult>
}

export function useAssignments(options: UseAssignmentsOptions): UseAssignmentsResult {
  const { canvasId, enabled = true, includeRevoked = false } = options
  const [assignments, setAssignments] = useState<AssignmentDTO[]>([])
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const mountedRef = useRef(true)
  const inFlightRef = useRef(false)

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
    }
  }, [])

  const active = enabled && !!canvasId

  const refresh = useCallback(async () => {
    if (!active || !canvasId) {
      if (mountedRef.current) setAssignments([])
      return
    }
    if (inFlightRef.current) return
    inFlightRef.current = true
    if (mountedRef.current) setLoading(true)
    try {
      const { assignments: rows } = await fetchCanvasAssignments(canvasId, { includeRevoked })
      if (mountedRef.current) {
        setAssignments(rows)
        setError(null)
      }
    } catch (err) {
      if (mountedRef.current) {
        setError((err as Error).message || 'Failed to load assignments')
      }
    } finally {
      inFlightRef.current = false
      if (mountedRef.current) setLoading(false)
    }
  }, [active, canvasId, includeRevoked])

  const revoke = useCallback(
    async (nodeId: string): Promise<RevokeAssignmentResult> => {
      if (!canvasId) throw new Error('No canvas selected')
      const result = await revokeNodeAssignment(canvasId, nodeId)
      // Reflect the revoke locally before the round-trip completes.
      await refresh()
      return result
    },
    [canvasId, refresh],
  )

  useEffect(() => {
    if (!active) {
      setAssignments([])
      return
    }
    void refresh()
  }, [active, refresh])

  return { assignments, loading, error, refresh, revoke }
}
