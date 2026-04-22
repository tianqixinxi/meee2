import { useCallback, useEffect, useRef, useState } from 'react'
import { connectEvents, fetchState } from './api'
import type { BoardState } from './types'

export interface BoardStateHook {
  state: BoardState | null
  loading: boolean
  error: string | null
  connected: boolean
  refresh: () => void
}

/**
 * Subscribes to /api/events and re-fetches /api/state on every frame (plus
 * initial fetch on mount). Auto-reconnects the socket.
 */
export function useBoardState(): BoardStateHook {
  const [state, setState] = useState<BoardState | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [connected, setConnected] = useState(false)
  const inFlight = useRef(false)
  const pendingRefetch = useRef(false)

  const refresh = useCallback(async () => {
    if (inFlight.current) {
      pendingRefetch.current = true
      return
    }
    inFlight.current = true
    try {
      const s = await fetchState()
      setState(s)
      setError(null)
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setLoading(false)
      inFlight.current = false
      if (pendingRefetch.current) {
        pendingRefetch.current = false
        // queue a follow-up to collapse bursts
        setTimeout(() => void refresh(), 0)
      }
    }
  }, [])

  useEffect(() => {
    // initial fetch (WS will also fire one immediately on connect; that's fine)
    void refresh()
    const dispose = connectEvents(
      () => void refresh(),
      (c) => setConnected(c),
    )
    return dispose
  }, [refresh])

  return { state, loading, error, connected, refresh }
}
