import { AlertCircle, ExternalLink, Search, Terminal as TerminalIcon } from 'lucide-react'
import { memo, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { createSessionSurface, syncNativeSessionsWorkspace, type NativeTerminalRect } from '../api'
import { useI18n } from '../lib/i18n'
import type { BoardState, Session } from '../types'

const COLLAPSE_OLD_AFTER_DAYS = 1
const COLLAPSE_OLD_AFTER_MS = COLLAPSE_OLD_AFTER_DAYS * 24 * 60 * 60 * 1000
type StatusFilter = 'all' | 'live' | 'attention' | 'idle' | 'exited'

interface Props {
  state: BoardState | null
  selectedSessionId?: string | null
  onSelectedSessionChange?: (id: string | null) => void
}

export function NativeSessionsWorkspaceHost({ state, selectedSessionId, onSelectedSessionChange }: Props) {
  const { t } = useI18n()
  const terminalHostRef = useRef<HTMLDivElement | null>(null)
  const layoutFrameRef = useRef<number | null>(null)
  const lastRectRef = useRef<NativeTerminalRect | null>(null)
  const switchStartedAtRef = useRef<Record<string, number>>({})
  const switchTraceIdRef = useRef<Record<string, string>>({})
  const latestSyncRef = useRef<(phase?: 'show' | 'layout' | 'focus') => void>(() => {})
  const [query, setQuery] = useState('')
  const [statusFilter, setStatusFilter] = useState<StatusFilter>('all')
  const [localSelectedId, setLocalSelectedId] = useState<string | null>(selectedSessionId ?? null)
  const [openingId, setOpeningId] = useState<string | null>(null)
  const [openErrorId, setOpenErrorId] = useState<string | null>(null)
  const [pendingNativeTarget, setPendingNativeTarget] = useState<{ sessionId?: string; surfaceId?: string } | null>(null)
  const [olderOpen, setOlderOpen] = useState(false)
  const [endedOpen, setEndedOpen] = useState(false)
  const sessions = state?.sessions ?? []
  const normalizedQuery = query.trim().toLowerCase()
  const visibleSessions = useMemo(() => (
    sessions
      .filter((session) => sessionControlState(session) === 'active')
      .filter((session) => sessionMatchesStatusFilter(session, statusFilter))
      .filter((session) => sessionMatchesQuery(session, normalizedQuery))
      .sort(compareSessions)
  ), [normalizedQuery, sessions, statusFilter])
  const statusFilters = useMemo(
    () => buildStatusFilters(sessions.filter((session) => sessionControlState(session) === 'active'), t),
    [sessions, t],
  )
  const recentSessions = useMemo(
    () => visibleSessions.filter((session) => !isEndedSession(session) && !isCollapsibleOldSession(session)),
    [visibleSessions],
  )
  const olderSessions = useMemo(
    () => visibleSessions.filter((session) => !isEndedSession(session) && isCollapsibleOldSession(session)),
    [visibleSessions],
  )
  const endedSessions = useMemo(
    () => visibleSessions.filter(isEndedSession),
    [visibleSessions],
  )
  const displayedSessions = useMemo(() => [
    ...recentSessions,
    ...(olderOpen ? olderSessions : []),
    ...(endedOpen ? endedSessions : []),
  ], [endedOpen, endedSessions, olderOpen, olderSessions, recentSessions])
  const selectedSession = useMemo(() => {
    const id = (selectedSessionId || localSelectedId || '').trim()
    if (!id) return null
    return sessions.find((session) => session.id === id || session.surfaceId === id) ?? null
  }, [localSelectedId, selectedSessionId, sessions])
  const selectionExists = useMemo(() => {
    const id = (selectedSessionId || localSelectedId || '').trim()
    if (!id) return false
    return sessions.some((session) => session.id === id || session.surfaceId === id)
  }, [localSelectedId, selectedSessionId, sessions])
  const pendingSelectedSessionId = selectedSessionId?.trim() && !selectedSession && !selectionExists
    ? selectedSessionId.trim()
    : null
  const terminalTarget = useMemo(() => {
    const resolved = nativeTargetForSession(selectedSession)
    if (resolved.sessionId || resolved.surfaceId) return resolved
    return pendingNativeTarget ?? {}
  }, [pendingNativeTarget, selectedSession])
  const selectedTrace = selectedSession ? switchTraceIdRef.current[selectedSession.id] : undefined
  const selectedStartedAt = selectedSession ? switchStartedAtRef.current[selectedSession.id] : undefined

  useEffect(() => {
    const id = selectedSessionId?.trim()
    if (id) setLocalSelectedId(id)
  }, [selectedSessionId])

  useEffect(() => {
    if (normalizedQuery) {
      setOlderOpen(true)
      setEndedOpen(true)
    }
  }, [normalizedQuery])

  useEffect(() => {
    if (statusFilter === 'exited') setEndedOpen(true)
  }, [statusFilter])

  useEffect(() => {
    if (!selectedSession) return
    if (olderSessions.some((session) => session.id === selectedSession.id)) {
      setOlderOpen(true)
    }
    if (endedSessions.some((session) => session.id === selectedSession.id)) {
      setEndedOpen(true)
    }
  }, [endedSessions, olderSessions, selectedSession])

  useEffect(() => {
    if (pendingSelectedSessionId) return
    if (pendingNativeTarget?.sessionId && localSelectedId === pendingNativeTarget.sessionId) return
    if (selectedSession) return
    const nextId = displayedSessions[0]?.id ?? null
    setLocalSelectedId(nextId)
    onSelectedSessionChange?.(nextId)
  }, [
    displayedSessions,
    localSelectedId,
    onSelectedSessionChange,
    pendingNativeTarget,
    pendingSelectedSessionId,
    selectedSession,
  ])

  useEffect(() => {
    if (!selectedSession || !pendingNativeTarget?.sessionId) return
    if (selectedSession.id === pendingNativeTarget.sessionId || selectedSession.surfaceId === pendingNativeTarget.surfaceId) {
      setPendingNativeTarget(null)
    }
  }, [pendingNativeTarget, selectedSession])

  const syncTerminal = useCallback((phase: 'show' | 'layout' | 'focus' = 'layout') => {
    const host = terminalHostRef.current
    if (!host) return
    if (!terminalTarget.sessionId && !terminalTarget.surfaceId) {
      syncNativeSessionsWorkspace({ phase: 'hide', mode: 'terminal', traceId: selectedTrace, clickStartedAtMs: selectedStartedAt, sentAtMs: Date.now(), webPhase: 'hide' })
      lastRectRef.current = null
      return
    }
    const rect = host.getBoundingClientRect()
    const nextRect = {
      x: rect.left,
      y: rect.top,
      width: rect.width,
      height: rect.height,
    }
    if (phase === 'layout' && sameRect(lastRectRef.current, nextRect)) return
    lastRectRef.current = nextRect
    const sentAtMs = Date.now()
    const traceId = selectedTrace ?? `workspace-${terminalTarget.sessionId?.slice(0, 8) ?? 'unknown'}-${sentAtMs.toString(36)}`
    console.debug('[TerminalSwitchPerf]', {
      traceId,
      phase: `web.workspace.${phase}.send`,
      sessionId: terminalTarget.sessionId,
      surfaceId: terminalTarget.surfaceId,
      clickToSendMs: selectedStartedAt === undefined ? undefined : sentAtMs - selectedStartedAt,
      rect: {
        width: Math.round(rect.width),
        height: Math.round(rect.height),
      },
    })
    syncNativeSessionsWorkspace({
      phase,
      mode: 'terminal',
      rect: nextRect,
      sessionId: terminalTarget.sessionId,
      surfaceId: terminalTarget.surfaceId,
      traceId,
      clickStartedAtMs: selectedStartedAt,
      sentAtMs,
      webPhase: `workspace.${phase}`,
    })
    if (terminalTarget.sessionId || terminalTarget.surfaceId) {
      window.__meee2PendingSessionsWorkspace = null
    }
  }, [selectedStartedAt, selectedTrace, terminalTarget.sessionId, terminalTarget.surfaceId])

  useEffect(() => {
    latestSyncRef.current = syncTerminal
  }, [syncTerminal])

  const scheduleLayout = useCallback(() => {
    if (layoutFrameRef.current !== null) return
    layoutFrameRef.current = window.requestAnimationFrame(() => {
      layoutFrameRef.current = null
      latestSyncRef.current('layout')
    })
  }, [])

  useLayoutEffect(() => {
    syncTerminal('show')
    const host = terminalHostRef.current
    if (!host) return undefined
    const resizeObserver = new ResizeObserver(() => scheduleLayout())
    resizeObserver.observe(host)
    const handleWindowLayout = () => scheduleLayout()
    window.addEventListener('resize', handleWindowLayout)
    window.addEventListener('meee2:layout-native-sessions-workspace', handleWindowLayout)
    return () => {
      if (layoutFrameRef.current !== null) {
        window.cancelAnimationFrame(layoutFrameRef.current)
        layoutFrameRef.current = null
      }
      resizeObserver.disconnect()
      window.removeEventListener('resize', handleWindowLayout)
      window.removeEventListener('meee2:layout-native-sessions-workspace', handleWindowLayout)
      syncNativeSessionsWorkspace({ phase: 'hide', mode: 'terminal' })
      lastRectRef.current = null
    }
  }, [scheduleLayout])

  useEffect(() => {
    syncTerminal('focus')
  }, [syncTerminal])

  const selectSession = useCallback((session: Session) => {
    const startedAt = Date.now()
    const traceId = `workspace-${session.id.slice(0, 8)}-${startedAt.toString(36)}-${Math.random().toString(36).slice(2, 8)}`
    switchStartedAtRef.current[session.id] = startedAt
    switchTraceIdRef.current[session.id] = traceId
    console.debug('[TerminalSwitchPerf]', {
      traceId,
      phase: 'web.workspace.select',
      sessionId: session.id,
      surfaceId: session.surfaceId,
    })
    setLocalSelectedId(session.id)
    onSelectedSessionChange?.(session.id)
  }, [onSelectedSessionChange])

  const openSession = useCallback(async (session: Session) => {
    selectSession(session)
    setOpeningId(session.id)
    setOpenErrorId(null)
    try {
      if (!isInternalSession(session)) {
        setOpenErrorId(session.id)
        return
      }
      if (isLiveInternalSession(session)) return
      const cwd = session.project?.trim()
      if (!cwd) {
        setOpenErrorId(session.id)
        return
      }
      const created = await createSessionSurface({
        provider: providerForSession(session),
        cwd,
        createIfMissing: false,
      })
      const target = {
        sessionId: created.sessionId,
        surfaceId: created.surfaceId,
      }
      setLocalSelectedId(created.sessionId)
      onSelectedSessionChange?.(created.sessionId)
      setPendingNativeTarget(target)
      window.__meee2PendingSessionsWorkspace = target
    } catch {
      setOpenErrorId(session.id)
    } finally {
      setOpeningId(null)
    }
  }, [onSelectedSessionChange, selectSession])

  return (
    <section className="native-sessions-workspace-host" aria-label={t('sessions.title')}>
      <aside className="sessions-web-rail">
        <div className="sessions-web-rail__header">
          <div className="sessions-web-rail__title">
            <strong>{t('sessions.title')}</strong>
            <span>{visibleSessions.length}</span>
          </div>
          <label className="sessions-web-search">
            <Search size={14} aria-hidden />
            <input
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder={t('sessions.searchPlaceholder')}
            />
          </label>
          <div className="sessions-web-filters" role="toolbar" aria-label={t('sessions.statusFilters')}>
            {statusFilters.map((filter) => (
              <button
                key={filter.id}
                type="button"
                className={filter.id === statusFilter ? 'is-active' : ''}
                onClick={() => setStatusFilter(filter.id)}
              >
                <span>{filter.label}</span>
                <em>{filter.count}</em>
              </button>
            ))}
          </div>
        </div>
        <div className="sessions-web-rail__list">
          {visibleSessions.length === 0 ? (
            <div className="sessions-web-empty">
              <Search size={16} aria-hidden />
              <span>{sessions.length === 0 ? t('sessions.empty') : t('sessions.noMatch')}</span>
            </div>
          ) : (
            <>
              <SessionGroup
                title={t('sessions.recentSessions')}
                sessions={recentSessions}
                selectedId={selectedSession?.id ?? null}
                onSelect={selectSession}
                onOpen={openSession}
                t={t}
              />
              <SessionGroup
                title={t('sessions.olderSessions')}
                sessions={olderSessions}
                selectedId={selectedSession?.id ?? null}
                onSelect={selectSession}
                onOpen={openSession}
                t={t}
                collapsible
                open={olderOpen}
                onOpenChange={setOlderOpen}
              />
              <SessionGroup
                title={t('sessions.endedSessions')}
                sessions={endedSessions}
                selectedId={selectedSession?.id ?? null}
                onSelect={selectSession}
                onOpen={openSession}
                t={t}
                collapsible
                open={endedOpen}
                onOpenChange={setEndedOpen}
              />
            </>
          )}
        </div>
        <SessionSummary
          session={selectedSession}
          opening={selectedSession ? openingId === selectedSession.id : false}
          openError={selectedSession ? openErrorId === selectedSession.id : false}
          onOpen={openSession}
        />
      </aside>
      <main className="sessions-web-terminal">
        <div ref={terminalHostRef} className="sessions-web-terminal__surface" />
        {!terminalTarget.sessionId && (
          <div className="sessions-web-terminal__placeholder">
            {selectedSession && !isInternalSession(selectedSession) ? (
              <>
                <ExternalLink size={18} aria-hidden />
                <span>{t('sessions.unmanagedSummary')}</span>
              </>
            ) : selectedSession ? (
              <>
                <TerminalIcon size={18} aria-hidden />
                <span>{t('sessions.internalEndedSummary')}</span>
              </>
            ) : (
              <>
                <TerminalIcon size={18} aria-hidden />
                <span>{t('sessions.selectSession')}</span>
              </>
            )}
          </div>
        )}
      </main>
    </section>
  )
}

const SessionGroup = memo(function SessionGroup({
  title,
  sessions,
  selectedId,
  onSelect,
  onOpen,
  t,
  collapsible = false,
  open = true,
  onOpenChange,
}: {
  title: string
  sessions: Session[]
  selectedId: string | null
  onSelect: (session: Session) => void
  onOpen: (session: Session) => void
  t: ReturnType<typeof useI18n>['t']
  collapsible?: boolean
  open?: boolean
  onOpenChange?: (open: boolean) => void
}) {
  if (sessions.length === 0) return null
  const body = (
    <>
      {sessions.map((session) => (
        <SessionRow
          key={session.id}
          session={session}
          selected={session.id === selectedId}
          onSelect={onSelect}
          onOpen={onOpen}
          t={t}
        />
      ))}
    </>
  )
  if (collapsible) {
    return (
      <details
        className="sessions-web-group sessions-web-group--collapsible"
        open={open}
        onToggle={(event) => onOpenChange?.(event.currentTarget.open)}
      >
        <summary className="sessions-web-group__heading">
          <span>{title}</span>
          <em>{sessions.length}</em>
        </summary>
        {body}
      </details>
    )
  }
  return (
    <section className="sessions-web-group" aria-label={title}>
      <div className="sessions-web-group__heading">
        <span>{title}</span>
        <em>{sessions.length}</em>
      </div>
      {body}
    </section>
  )
})

const SessionRow = memo(function SessionRow({
  session,
  selected,
  onSelect,
  onOpen,
  t,
}: {
  session: Session
  selected: boolean
  onSelect: (session: Session) => void
  onOpen: (session: Session) => void
  t: ReturnType<typeof useI18n>['t']
}) {
  const attention = sessionNeedsAttention(session)
  const status = sessionDisplayStatus(session)
  const caption = sessionListCaption(session, t)
  return (
    <button
      type="button"
      className={[
        'sessions-web-row',
        selected ? 'is-selected' : '',
        attention ? 'needs-attention' : '',
      ].filter(Boolean).join(' ')}
      onClick={() => onSelect(session)}
      onDoubleClick={() => onOpen(session)}
      title={session.id}
    >
      <span className="sessions-web-row__top">
        <strong>{session.title || shortSessionId(session.id)}</strong>
        <span className={`sessions-web-tag sessions-web-tag--${isInternalSession(session) ? 'internal' : 'external'}`}>
          {isInternalSession(session) ? t('sessions.internal') : t('sessions.external')}
        </span>
      </span>
      <span className="sessions-web-row__bottom">
        <span>{caption}</span>
        <em>{status}</em>
        {attention && <AlertCircle size={13} aria-hidden />}
      </span>
    </button>
  )
})

function SessionSummary({
  session,
  opening,
  openError,
  onOpen,
}: {
  session: Session | null
  opening: boolean
  openError: boolean
  onOpen: (session: Session) => void
}) {
  const { t } = useI18n()
  if (!session) {
    return (
      <section className="sessions-web-summary">
        <span className="sessions-web-summary__empty">{t('sessions.selectSession')}</span>
      </section>
    )
  }
  const recent = sessionSummaryText(session)
  const internal = isInternalSession(session)
  const liveInternal = internal && isLiveInternalSession(session)
  const canOpen = internal ? !liveInternal : false
  return (
    <section className="sessions-web-summary">
      <div className="sessions-web-summary__header">
        <span>{t('sessions.sessionInfo')}</span>
        <span className={`sessions-web-tag sessions-web-tag--${internal ? 'internal' : 'external'}`}>
          {internal ? t('sessions.internal') : t('sessions.external')}
        </span>
        <strong>{session.title || shortSessionId(session.id)}</strong>
      </div>
      <p>{recent || session.project || session.pluginDisplayName || session.id}</p>
      <div className="sessions-web-summary__divider" aria-hidden />
      <dl>
        <div>
          <dt>{t('sessions.columnStatus')}</dt>
          <dd>{sessionDisplayStatus(session)}</dd>
        </div>
        <div>
          <dt>{t('sessions.columnSignal')}</dt>
          <dd>{relativeTime(session.lastActivity, t)}</dd>
        </div>
      </dl>
      <div className="sessions-web-summary__actions">
        <button type="button" onClick={() => onOpen(session)} disabled={!canOpen || opening}>
          {opening ? t('common.opening') : t('sessions.openSession')}
        </button>
        {openError && <span>{t('common.openFailed')}</span>}
      </div>
    </section>
  )
}

function nativeTargetForSession(session: Session | null): { sessionId?: string; surfaceId?: string } {
  if (!session || !isInternalSession(session) || !isLiveInternalSession(session)) return {}
  return {
    sessionId: session.id,
    surfaceId: session.surfaceId ?? undefined,
  }
}

function isInternalSession(session: Session): boolean {
  return session.openTarget === 'native-workspace'
    || session.nativeWorkspaceAvailable === true
    || session.terminalKind === 'internal'
    || Boolean(session.surfaceId)
}

function isLiveInternalSession(session: Session): boolean {
  const status = (session.surfaceStatus || session.status || '').toLowerCase()
  return status !== 'exited' && status !== 'failed' && status !== 'dead'
}

function sessionControlState(session: Session): string {
  return session.controlState || 'active'
}

function buildStatusFilters(sessions: Session[], t: ReturnType<typeof useI18n>['t']): Array<{ id: StatusFilter; label: string; count: number }> {
  const counts: Record<StatusFilter, number> = {
    all: sessions.length,
    live: 0,
    attention: 0,
    idle: 0,
    exited: 0,
  }
  for (const session of sessions) {
    counts[sessionLifecycle(session)] += 1
  }
  return [
    { id: 'all', label: t('sessions.filterAll'), count: counts.all },
    { id: 'live', label: t('sessions.filterLive'), count: counts.live },
    { id: 'attention', label: t('sessions.filterAttention'), count: counts.attention },
    { id: 'idle', label: t('sessions.filterIdle'), count: counts.idle },
    { id: 'exited', label: t('sessions.filterExited'), count: counts.exited },
  ]
}

function sessionMatchesStatusFilter(session: Session, filter: StatusFilter): boolean {
  return filter === 'all' || sessionLifecycle(session) === filter
}

function sessionLifecycle(session: Session): Exclude<StatusFilter, 'all'> {
  if (sessionNeedsAttention(session)) return 'attention'
  const status = sessionDisplayStatus(session).toLowerCase()
  if (isEndedStatus(status)) return 'exited'
  if (status === 'thinking' || status === 'tooling' || status === 'active' || status === 'running' || status === 'starting' || status === 'compacting') return 'live'
  return 'idle'
}

function sessionMatchesQuery(session: Session, query: string): boolean {
  if (!query) return true
  return [
    session.id,
    session.surfaceId ?? '',
    session.title,
    session.project,
    session.pluginId,
    session.pluginDisplayName,
    session.status,
    session.surfaceStatus ?? '',
    session.currentTool ?? '',
    session.currentTask ?? '',
    session.latestRecap?.content ?? '',
    session.recentMessages[0]?.text ?? '',
  ].some((value) => value.toLowerCase().includes(query))
}

function compareSessions(a: Session, b: Session): number {
  const attentionDelta = Number(sessionNeedsAttention(b)) - Number(sessionNeedsAttention(a))
  if (attentionDelta !== 0) return attentionDelta
  const statusDelta = sessionStatusRank(a) - sessionStatusRank(b)
  if (statusDelta !== 0) return statusDelta
  const internalDelta = Number(isInternalSession(b)) - Number(isInternalSession(a))
  if (internalDelta !== 0) return internalDelta
  return timeValue(b.lastActivity || b.startedAt) - timeValue(a.lastActivity || a.startedAt)
}

function sessionStatusRank(session: Session): number {
  switch (sessionLifecycle(session)) {
    case 'attention': return 0
    case 'live': return 1
    case 'idle': return 2
    case 'exited': return 3
  }
}

function sessionNeedsAttention(session: Session): boolean {
  return session.status === 'permissionRequired'
    || session.status === 'waitingForUser'
    || session.inboxPending > 0
    || Boolean(session.pendingPermissionTool)
}

function isCollapsibleOldSession(session: Session): boolean {
  if (sessionNeedsAttention(session)) return false
  const value = timeValue(session.lastActivity || session.startedAt)
  return value > 0 && Date.now() - value >= COLLAPSE_OLD_AFTER_MS
}

function isEndedSession(session: Session): boolean {
  return isEndedStatus(sessionDisplayStatus(session).toLowerCase())
}

function isEndedStatus(status: string): boolean {
  return status === 'exited' || status === 'failed' || status === 'dead' || status === 'completed'
}

function sessionDisplayStatus(session: Session): string {
  return session.surfaceStatus || session.status
}

function sessionListCaption(session: Session, t: ReturnType<typeof useI18n>['t']): string {
  return sessionSummaryText(session) || session.pluginDisplayName || t('sessions.noActivity')
}

function sessionSummaryText(session: Session): string {
  const lastMessage = session.recentMessages.length > 0
    ? session.recentMessages[session.recentMessages.length - 1]?.text
    : ''
  return session.latestRecap?.content
    || session.currentTask
    || lastMessage
    || session.recentMessages[0]?.text
    || ''
}

function providerForSession(session: Session): 'claude' | 'codex' {
  const raw = `${session.pluginId} ${session.pluginDisplayName} ${session.id}`.toLowerCase()
  return raw.includes('codex') ? 'codex' : 'claude'
}

function sameRect(a: NativeTerminalRect | null, b: NativeTerminalRect): boolean {
  if (!a) return false
  return Math.abs(a.x - b.x) < 0.5
    && Math.abs(a.y - b.y) < 0.5
    && Math.abs(a.width - b.width) < 0.5
    && Math.abs(a.height - b.height) < 0.5
}

function shortSessionId(value: string): string {
  return value.length > 12 ? `${value.slice(0, 12)}...` : value
}

function timeValue(value?: string | null): number {
  if (!value) return 0
  const parsed = Date.parse(value)
  return Number.isNaN(parsed) ? 0 : parsed
}

function relativeTime(value: string | null | undefined, t: ReturnType<typeof useI18n>['t']): string {
  const ts = timeValue(value)
  if (!ts) return t('sessions.noActivity')
  const seconds = Math.round((ts - Date.now()) / 1000)
  const abs = Math.abs(seconds)
  const units: Array<[Intl.RelativeTimeFormatUnit, number]> = [
    ['day', 86400],
    ['hour', 3600],
    ['minute', 60],
  ]
  const formatter = new Intl.RelativeTimeFormat(undefined, { numeric: 'auto' })
  for (const [unit, size] of units) {
    if (abs >= size) return formatter.format(Math.round(seconds / size), unit)
  }
  return formatter.format(seconds, 'second')
}
