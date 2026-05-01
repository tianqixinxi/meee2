// Thin meee2 wrapper around board-ui's <TranscriptView>. Owns the
// fetch / poll / WS-trigger logic; the rendering (search, virtualization,
// markdown, diff, sticky user, scroll-to-latest, tool blocks) all lives
// in @meee1/board-ui.

import { useCallback, useEffect, useRef, useState } from 'react'
import { TranscriptView } from '@meee1/board-ui'
import type { TranscriptEntryForView } from '@meee1/board-core'
import { fetchTranscript } from '../api'

interface Props {
  sessionId: string
  /** Any reference change triggers a debounced refetch (e.g. the WS state). */
  refreshTrigger?: unknown
  /** Polling fallback in ms; 0 disables. */
  pollMs?: number
  /** Last N entries; 0/undefined = full transcript. */
  limit?: number
}

export default function TranscriptPanel({
  sessionId,
  refreshTrigger,
  pollMs = 10_000,
  limit,
}: Props) {
  const [entries, setEntries] = useState<TranscriptEntryForView[]>([])
  const [error, setError] = useState<string | null>(null)
  const [loaded, setLoaded] = useState(false)
  const [refreshing, setRefreshing] = useState(false)

  // Reset on session switch — board-ui's TranscriptView handles cache via
  // its own module-level Map keyed on cacheKey, so the transition is
  // smooth even though we momentarily clear `entries` here.
  useEffect(() => {
    setEntries([])
    setLoaded(false)
    setError(null)
  }, [sessionId])

  const load = useCallback(async () => {
    const slowTimer = window.setTimeout(() => setRefreshing(true), 500)
    try {
      const r = await fetchTranscript(sessionId, { limit })
      // Swift FullTranscriptEntry is structurally identical to
      // TranscriptEntryForView (same field names + block types) — pass through.
      setEntries(r.entries as unknown as TranscriptEntryForView[])
      setError(null)
      setLoaded(true)
    } catch (e) {
      setError((e as Error).message || 'Failed to load transcript')
      setLoaded(true)
    } finally {
      window.clearTimeout(slowTimer)
      setRefreshing(false)
    }
  }, [sessionId, limit])

  // Initial fetch + poll fallback
  useEffect(() => {
    void load()
    if (!pollMs) return
    const h = window.setInterval(load, pollMs)
    return () => window.clearInterval(h)
  }, [load, pollMs])

  // WS-driven debounced refetch
  const debounceRef = useRef<number | null>(null)
  useEffect(() => {
    if (refreshTrigger === undefined) return
    if (debounceRef.current) window.clearTimeout(debounceRef.current)
    debounceRef.current = window.setTimeout(load, 1500)
    return () => {
      if (debounceRef.current) window.clearTimeout(debounceRef.current)
    }
  }, [refreshTrigger, load])

  return (
    <TranscriptView
      entries={entries}
      cacheKey={sessionId}
      loading={!loaded}
      error={error}
      refreshing={refreshing}
      searchPlaceholder="Search in terminal messages (tool name / text)…"
    />
  )
}
