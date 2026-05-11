// Thin meee2 wrapper around board-ui's <TranscriptView>. Owns the
// fetch / poll / WS-trigger logic; the rendering (search, virtualization,
// markdown, diff, sticky user, scroll-to-latest, tool blocks) all lives
// in @meee1/board-ui.

import { useCallback, useEffect, useRef, useState } from 'react'
import { TranscriptView, type TranscriptVerbosity } from '@meee1/board-ui'
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
  /** Live session status for the in-flight tail block (synthetic
   *  "Bash · running…" / "Thinking…" placeholder rendered while jsonl
   *  hasn't caught up yet). Pass the SessionDTO.status straight through. */
  liveStatus?: string | null
  /** SessionDTO.currentTool —— Bash / Edit / Read / etc. Only meaningful
   *  when liveStatus === 'tooling'. */
  liveCurrentTool?: string | null
  /** SessionDTO.currentTask —— optional one-line description of the
   *  active step (used when liveStatus === 'thinking'). */
  liveCurrentTask?: string | null
  /** Assistant turn label. For plugin sessions this should be Claude/Codex/etc. */
  assistantLabel?: string
  /** When provided, TranscriptView runs in controlled-verbosity mode
   *  and hides its in-search-bar pill — the parent renders the pill
   *  elsewhere (e.g. Dock's ChatComposer bottomLeft slot). */
  verbosity?: TranscriptVerbosity
  onVerbosityChange?: (v: TranscriptVerbosity) => void
}

export default function TranscriptPanel({
  sessionId,
  refreshTrigger,
  pollMs = 10_000,
  limit,
  liveStatus = null,
  liveCurrentTool = null,
  liveCurrentTask = null,
  assistantLabel,
  verbosity,
  onVerbosityChange,
}: Props) {
  const [entries, setEntries] = useState<TranscriptEntryForView[]>([])
  const [error, setError] = useState<string | null>(null)
  const [loaded, setLoaded] = useState(false)
  const [refreshing, setRefreshing] = useState(false)
  const loadedRef = useRef(false)
  const inFlightRef = useRef(false)
  const sawRefreshTriggerRef = useRef(false)

  // Reset on session switch — board-ui's TranscriptView handles cache via
  // its own module-level Map keyed on cacheKey, so the transition is
  // smooth even though we momentarily clear `entries` here.
  useEffect(() => {
    setEntries([])
    setLoaded(false)
    loadedRef.current = false
    setError(null)
  }, [sessionId])

  const load = useCallback(async () => {
    if (inFlightRef.current) return
    if (document.visibilityState === 'hidden' && loadedRef.current) return
    inFlightRef.current = true
    const slowTimer = window.setTimeout(() => setRefreshing(true), 500)
    try {
      const r = await fetchTranscript(sessionId, { limit })
      // Swift FullTranscriptEntry is structurally identical to
      // TranscriptEntryForView (same field names + block types) — pass through.
      setEntries(r.entries as unknown as TranscriptEntryForView[])
      setError(null)
      setLoaded(true)
      loadedRef.current = true
    } catch (e) {
      setError((e as Error).message || 'Failed to load transcript')
      setLoaded(true)
      loadedRef.current = true
    } finally {
      window.clearTimeout(slowTimer)
      setRefreshing(false)
      inFlightRef.current = false
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
    if (!sawRefreshTriggerRef.current) {
      sawRefreshTriggerRef.current = true
      return
    }
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
      liveStatus={liveStatus}
      liveCurrentTool={liveCurrentTool}
      liveCurrentTask={liveCurrentTask}
      verbosity={verbosity}
      onVerbosityChange={onVerbosityChange}
      assistantLabel={assistantLabel}
      startAtLatest
    />
  )
}
