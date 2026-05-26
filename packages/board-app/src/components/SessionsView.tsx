import {
  AlertCircle,
  CheckCircle2,
  CircleStop,
  Clock3,
  ExternalLink,
  Search,
  Terminal as TerminalIcon,
} from 'lucide-react'
import { memo, useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { activateSession, closeSessionSurface, openNativeTerminalSurface, type NativeTerminalRect } from '../api'
import { useI18n } from '../lib/i18n'
import type { BoardState, Session } from '../types'

interface Props {
  state: BoardState | null
  unreadSids: Set<string>
  selectedSessionId?: string | null
  onSelectedSessionChange?: (id: string | null) => void
}

type SessionFilter = 'all' | 'attention' | 'unread'
type SessionKindTab = 'internal' | 'external'
type NativeTerminalSyncType = 'attach' | 'layout' | 'focus'

export function SessionsView({
  state,
  unreadSids,
  selectedSessionId,
  onSelectedSessionChange,
}: Props) {
  const { t } = useI18n()
  const [query, setQuery] = useState('')
  const [filter, setFilter] = useState<SessionFilter>('all')
  const [activeKindTab, setActiveKindTab] = useState<SessionKindTab>('internal')
  const [openingId, setOpeningId] = useState<string | null>(null)
  const [openErrorId, setOpenErrorId] = useState<string | null>(null)
  const switchStartedAtRef = useRef<Record<string, number>>({})
  const switchTraceIdRef = useRef<Record<string, string>>({})
  const prewarmedInternalSurfaceIdsRef = useRef<Set<string>>(new Set())
  const sessions = state?.sessions ?? []
  const attentionCount = useMemo(
    () => sessions.filter((session) => sessionNeedsAttention(session) || unreadSids.has(session.id)).length,
    [sessions, unreadSids],
  )
  const unreadCount = useMemo(
    () => sessions.filter((session) => unreadSids.has(session.id)).length,
    [sessions, unreadSids],
  )
  const visibleSessions = useMemo(() => {
    const normalized = query.trim().toLowerCase()
    return sessions
      .filter((session) => sessionMatchesQuery(session, normalized))
      .filter((session) => {
        if (filter === 'attention') return sessionNeedsAttention(session) || unreadSids.has(session.id)
        if (filter === 'unread') return unreadSids.has(session.id)
        return true
      })
      .sort((a, b) => compareSessions(a, b, unreadSids))
  }, [filter, query, sessions, unreadSids])
  const selectedSession = useMemo(() => {
    if (!selectedSessionId) return null
    return sessions.find((session) => (
      isInternalSession(session)
      && (session.id === selectedSessionId || session.surfaceId === selectedSessionId)
    )) ?? null
  }, [selectedSessionId, sessions])
  const internalSessions = useMemo(() => {
    const list = visibleSessions.filter(isInternalSession)
    if (selectedSession && !list.some((session) => session.id === selectedSession.id)) {
      return [selectedSession, ...list]
    }
    return list
  }, [selectedSession, visibleSessions])
  const externalSessions = useMemo(
    () => visibleSessions.filter((session) => !isInternalSession(session)),
    [visibleSessions],
  )

  const prewarmInternalSession = useCallback((session: Session, reason = 'react.prewarm') => {
    if (!session.surfaceId || !isLiveInternalSession(session)) return false
    if (reason === 'react.idleTabPrewarm') return false
    const criticalInteraction = reason.startsWith('react.rowSelect') || reason.startsWith('react.rowOpen')
    if (!criticalInteraction && prewarmedInternalSurfaceIdsRef.current.has(session.surfaceId)) return true
    const ok = openNativeTerminalSurface({
      type: 'prewarm',
      surfaceId: session.surfaceId,
      sessionId: session.id,
      webPhase: reason,
    })
    if (ok) prewarmedInternalSurfaceIdsRef.current.add(session.surfaceId)
    return ok
  }, [])

  useEffect(() => {
    if (activeKindTab !== 'internal' || selectedSession || internalSessions.length === 0) return
    const next = internalSessions[0]
    if (selectedSessionId === next.id || selectedSessionId === next.surfaceId) return
    onSelectedSessionChange?.(next?.id ?? null)
  }, [activeKindTab, internalSessions, onSelectedSessionChange, selectedSession, selectedSessionId])

  useEffect(() => {
    if (selectedSessionId && selectedSession) setActiveKindTab('internal')
  }, [selectedSession, selectedSessionId])

  useEffect(() => {
    if (activeKindTab !== 'internal') return
    const targets = uniqueSessionsById([
      ...(selectedSession ? [selectedSession] : []),
      ...internalSessions,
    ])
      .filter((session) => session.surfaceId && isLiveInternalSession(session))
      .slice(0, 6)
    if (targets.length === 0) return
    return scheduleStaggeredInternalPrewarm(targets, prewarmInternalSession)
  }, [activeKindTab, internalSessions, prewarmInternalSession, selectedSession])

  const selectInternalSession = useCallback((session: Session, phase = 'react.rowSelect') => {
    const startedAt = Date.now()
    const traceId = `switch-${startedAt.toString(36)}-${Math.random().toString(36).slice(2, 8)}`
    switchStartedAtRef.current[session.id] = startedAt
    switchTraceIdRef.current[session.id] = traceId
    prewarmInternalSession(session, `${phase}.prewarm`)
    console.debug('[TerminalSwitchPerf]', {
      traceId,
      phase,
      sessionId: session.id,
      surfaceId: session.surfaceId,
    })
    onSelectedSessionChange?.(session.id)
  }, [onSelectedSessionChange, prewarmInternalSession])

  const prewarmSessionRow = useCallback((session: Session) => {
    if (isInternalSession(session)) prewarmInternalSession(session, 'react.rowHoverPrewarm')
  }, [prewarmInternalSession])

  const openSession = useCallback(async (session: Session) => {
    if (isInternalSession(session)) {
      selectInternalSession(session, 'react.rowOpen')
      return
    }
    setOpeningId(session.id)
    setOpenErrorId(null)
    const ok = await activateSession(session.id)
    setOpeningId(null)
    if (!ok) setOpenErrorId(session.id)
  }, [selectInternalSession])

  return (
    <section className="sessions-workspace" aria-label={t('sessions.title')}>
      <div className="sessions-workspace__inner">
        <div className="sessions-workspace__header">
          <div>
            <h1>{t('sessions.title')}</h1>
            <p>{t('sessions.subtitle')}</p>
          </div>
          <div className="sessions-workspace__tools">
            <label className="sessions-search">
              <Search size={14} aria-hidden />
              <input
                value={query}
                onChange={(event) => setQuery(event.target.value)}
                placeholder={t('sessions.searchPlaceholder')}
              />
            </label>
            <div className="sessions-filters" aria-label={t('sessions.filters')}>
              <FilterButton label={t('sessions.filterAll')} count={sessions.length} active={filter === 'all'} onClick={() => setFilter('all')} />
              <FilterButton label={t('sessions.filterAttention')} count={attentionCount} active={filter === 'attention'} onClick={() => setFilter('attention')} />
              <FilterButton label={t('sessions.filterUnread')} count={unreadCount} active={filter === 'unread'} onClick={() => setFilter('unread')} />
            </div>
          </div>
        </div>
        {sessions.length === 0 ? (
          <div className="sessions-empty">
            <TerminalIcon size={18} aria-hidden />
            <span>{t('sessions.empty')}</span>
          </div>
        ) : (
          <div className="sessions-board">
            {visibleSessions.length === 0 ? (
              <div className="sessions-empty sessions-empty--compact">
                <Search size={18} aria-hidden />
                <span>{t('sessions.noMatch')}</span>
              </div>
            ) : (
              <div className={`sessions-console sessions-console--${activeKindTab}`}>
                <aside className="sessions-console__sidebar">
                  <div className="sessions-kind-tabs" role="tablist" aria-label={t('sessions.kindTabs')}>
                    <KindTabButton
                      label={t('sessions.internalSessions')}
                      count={internalSessions.length}
                      icon={<TerminalIcon size={13} aria-hidden />}
                      active={activeKindTab === 'internal'}
                      onClick={() => setActiveKindTab('internal')}
                    />
                    <KindTabButton
                      label={t('sessions.externalSessions')}
                      count={externalSessions.length}
                      icon={<ExternalLink size={13} aria-hidden />}
                      active={activeKindTab === 'external'}
                      onClick={() => setActiveKindTab('external')}
                    />
                  </div>
                  {activeKindTab === 'internal' ? (
                    <SessionsSection
                      title={t('sessions.internalSessions')}
                      subtitle={t('sessions.internalSubtitle')}
                      count={internalSessions.length}
                      emptyIcon={<TerminalIcon size={18} aria-hidden />}
                      emptyText={t('sessions.noInternalSessions')}
                    >
                      <div className="sessions-list sessions-list--internal" aria-label={t('sessions.internalSessions')}>
                        {internalSessions.map((session) => (
                          <SessionRow
                            key={session.id}
                            session={session}
                            selected={selectedSession?.id === session.id}
                            opening={openingId === session.id}
                            openError={openErrorId === session.id}
                            unread={unreadSids.has(session.id)}
                            onSelect={selectInternalSession}
                            onOpen={openSession}
                            onPrewarm={prewarmSessionRow}
                            t={t}
                          />
                        ))}
                      </div>
                    </SessionsSection>
                  ) : (
                    <SessionsSection
                      title={t('sessions.externalSessions')}
                      subtitle={t('sessions.externalSubtitle')}
                      count={externalSessions.length}
                      emptyIcon={<ExternalLink size={18} aria-hidden />}
                      emptyText={t('sessions.noExternalSessions')}
                    >
                      <div className="sessions-list sessions-list--external" aria-label={t('sessions.externalSessions')}>
                        {externalSessions.map((session) => (
                          <SessionRow
                            key={session.id}
                            session={session}
                            selected={false}
                            opening={openingId === session.id}
                            openError={openErrorId === session.id}
                            unread={unreadSids.has(session.id)}
                            onSelect={noopSessionAction}
                            onOpen={openSession}
                            onPrewarm={noopSessionAction}
                            t={t}
                          />
                        ))}
                      </div>
                    </SessionsSection>
                  )}
                </aside>
                {activeKindTab === 'internal' && (
                  <SessionDetail
                    session={selectedSession}
                    opening={openingId === selectedSession?.id}
                    openError={openErrorId === selectedSession?.id}
                    switchStartedAt={selectedSession ? switchStartedAtRef.current[selectedSession.id] : undefined}
                    switchTraceId={selectedSession ? switchTraceIdRef.current[selectedSession.id] : undefined}
                    onOpen={() => selectedSession && openSession(selectedSession)}
                    t={t}
                  />
                )}
              </div>
            )}
          </div>
        )}
      </div>
    </section>
  )
}

function KindTabButton({
  label,
  count,
  icon,
  active,
  onClick,
}: {
  label: string
  count: number
  icon: ReactNode
  active: boolean
  onClick: () => void
}) {
  return (
    <button
      type="button"
      role="tab"
      aria-selected={active}
      className={`sessions-kind-tab${active ? ' is-active' : ''}`}
      onClick={onClick}
    >
      {icon}
      <span>{label}</span>
      <em>{count}</em>
    </button>
  )
}

function SessionsSection({
  title,
  subtitle,
  count,
  emptyIcon,
  emptyText,
  children,
}: {
  title: string
  subtitle: string
  count: number
  emptyIcon: ReactNode
  emptyText: string
  children: ReactNode
}) {
  return (
    <section className="sessions-section" aria-label={title}>
      <div className="sessions-section__heading">
        <div>
          <h2>{title}</h2>
          <p>{subtitle}</p>
        </div>
        <span>{count}</span>
      </div>
      {count === 0 ? (
        <div className="sessions-empty sessions-empty--compact">
          {emptyIcon}
          <span>{emptyText}</span>
        </div>
      ) : children}
    </section>
  )
}

const SessionRow = memo(function SessionRow({
  session,
  selected,
  opening,
  openError,
  unread,
  onSelect,
  onOpen,
  onPrewarm,
  t,
}: {
  session: Session
  selected: boolean
  opening: boolean
  openError: boolean
  unread: boolean
  onSelect: (session: Session) => void
  onOpen: (session: Session) => void
  onPrewarm: (session: Session) => void
  t: ReturnType<typeof useI18n>['t']
}) {
  const attention = sessionNeedsAttention(session) || unread
  const context = session.currentTask || session.latestRecap?.content || session.recentMessages[0]?.text || ''
  return (
    <article
      className={[
        'sessions-row',
        isInternalSession(session) ? 'sessions-row--internal' : 'sessions-row--external',
        selected ? 'is-selected' : '',
        attention ? 'sessions-row--attention' : '',
        unread ? 'sessions-row--unread' : '',
      ].filter(Boolean).join(' ')}
      onClick={() => onSelect(session)}
      onDoubleClick={() => onOpen(session)}
      onMouseEnter={() => onPrewarm(session)}
      onFocus={() => onPrewarm(session)}
      tabIndex={0}
      aria-label={isInternalSession(session) ? t('sessions.doubleClickSelect') : t('sessions.doubleClickOpen')}
    >
      <div className="sessions-row__identity">
        <div className="sessions-row__icon" style={{ color: session.pluginColor || undefined }}>
          {sessionIcon(session)}
        </div>
        <div className="sessions-row__main">
          <div className="sessions-row__title">
            <strong>{session.title || shortId(session.id)}</strong>
            <div className="sessions-row__badges">
              <span className="sessions-row__kind">{isInternalSession(session) ? t('sessions.internal') : t('sessions.external')}</span>
              {unread && <span className="sessions-row__unread">{t('sessions.unread')}</span>}
              {attention && <span className="sessions-row__attention">{t('sessions.attention')}</span>}
              {session.inboxPending > 0 && <span className="sessions-row__count">{session.inboxPending}</span>}
            </div>
          </div>
          <div className="sessions-row__meta">
            <span>{session.pluginDisplayName || session.pluginId}</span>
            <span>{shortId(session.id)}</span>
          </div>
        </div>
      </div>
      <div className="sessions-row__status">
        <strong>{session.surfaceStatus || session.status}</strong>
        {session.currentTool && <span>{session.currentTool}</span>}
      </div>
      <div className="sessions-row__context">
        <strong>{session.project || t('sessions.noProject')}</strong>
        {context && <span>{context}</span>}
      </div>
      <div className="sessions-row__signal">
        {attention ? attentionReason(session, unread, t) : session.lastActivity ? relativeTime(session.lastActivity, t) : t('sessions.noActivity')}
      </div>
      <div className="sessions-row__actions">
        {openError && <span>{t('common.openFailed')}</span>}
        {!isInternalSession(session) && (
          <button type="button" onClick={(event) => { event.stopPropagation(); onOpen(session) }} disabled={opening}>
            <ExternalLink size={13} aria-hidden />
            {opening ? t('common.opening') : t('sessions.openExternal')}
          </button>
        )}
      </div>
    </article>
  )
})

function SessionDetail({
  session,
  opening,
  openError,
  switchStartedAt,
  switchTraceId,
  onOpen,
  t,
}: {
  session: Session | null
  opening: boolean
  openError: boolean
  switchStartedAt?: number
  switchTraceId?: string
  onOpen: () => void
  t: ReturnType<typeof useI18n>['t']
}) {
  const [stopping, setStopping] = useState(false)
  const [stopError, setStopError] = useState<string | null>(null)
  if (!session) {
    return (
      <aside className="sessions-detail sessions-detail--empty">
        <TerminalIcon size={18} aria-hidden />
        <span>{t('sessions.selectSession')}</span>
      </aside>
    )
  }
  const internal = isInternalSession(session)
  const liveInternal = internal && isLiveInternalSession(session)
  const stopInternal = async () => {
    if (!session.surfaceId) return
    setStopping(true)
    setStopError(null)
    try {
      await closeSessionSurface(session.surfaceId)
    } catch (err) {
      setStopError((err as Error).message || t('sessions.stopFailed'))
    } finally {
      setStopping(false)
    }
  }
  return (
    <aside className="sessions-detail">
      <div className="sessions-detail__header">
        <div>
          <span>{internal ? t('sessions.internal') : t('sessions.external')}</span>
          <h2>{session.title || shortId(session.id)}</h2>
        </div>
        <div className="sessions-detail__actions">
          {internal ? (
            <button
              type="button"
              onClick={stopInternal}
              disabled={stopping || session.surfaceStatus === 'exited' || session.surfaceStatus === 'failed'}
            >
              <CircleStop size={14} aria-hidden />
              {stopping ? t('sessions.stopping') : t('sessions.stop')}
            </button>
          ) : (
            <button type="button" onClick={onOpen} disabled={opening}>
              <ExternalLink size={14} aria-hidden />
              {opening ? t('common.opening') : t('sessions.openExternal')}
            </button>
          )}
        </div>
      </div>
      <dl className="sessions-detail__meta">
        <div>
          <dt>{t('sessions.columnStatus')}</dt>
          <dd>{session.surfaceStatus || session.status}</dd>
        </div>
        <div>
          <dt>{t('sessions.columnContext')}</dt>
          <dd>{session.project || t('sessions.noProject')}</dd>
        </div>
        <div>
          <dt>{t('sessions.id')}</dt>
          <dd>{session.id}</dd>
        </div>
      </dl>
      {openError && <p className="sessions-detail__error">{t('common.openFailed')}</p>}
      {stopError && <p className="sessions-detail__error">{stopError}</p>}
      {internal && session.surfaceId && liveInternal ? (
        <NativeTerminalPanel session={session} switchStartedAt={switchStartedAt} switchTraceId={switchTraceId} />
      ) : internal ? (
        <div className="sessions-external">
          <TerminalIcon size={18} aria-hidden />
          <span>{t('sessions.internalEndedSummary')}</span>
        </div>
      ) : (
        <div className="sessions-external">
          <ExternalLink size={18} aria-hidden />
          <span>{t('sessions.externalSummary')}</span>
        </div>
      )}
    </aside>
  )
}

function NativeTerminalPanel({
  session,
  switchStartedAt,
  switchTraceId,
}: {
  session: Session
  switchStartedAt?: number
  switchTraceId?: string
}) {
  const { t } = useI18n()
  const hostRef = useRef<HTMLDivElement | null>(null)
  const layoutFrameRef = useRef<number | null>(null)
  const lastSentRectRef = useRef<NativeTerminalRect | null>(null)
  const lastObservedSizeRef = useRef<{ width: number; height: number } | null>(null)
  const [openError, setOpenError] = useState(false)

  const syncNative = useCallback((type: NativeTerminalSyncType = 'attach') => {
    if (!session.surfaceId || !hostRef.current) return false
    const rect = hostRef.current.getBoundingClientRect()
    const nativeRect = {
      x: rect.left,
      y: rect.top,
      width: rect.width,
      height: rect.height,
    }
    if (type === 'layout' && sameNativeRect(lastSentRectRef.current, nativeRect)) {
      return true
    }
    const sentAtMs = Date.now()
    const traceId = switchTraceId ?? `terminal-${session.id.slice(0, 8)}-${sentAtMs.toString(36)}`
    console.debug('[TerminalSwitchPerf]', {
      traceId,
      phase: `web.${type}.send`,
      sessionId: session.id,
      surfaceId: session.surfaceId,
      clickToSendMs: switchStartedAt === undefined ? undefined : sentAtMs - switchStartedAt,
      rect: {
        width: Math.round(rect.width),
        height: Math.round(rect.height),
      },
    })
    const ok = openNativeTerminalSurface({
      type,
      surfaceId: session.surfaceId,
      sessionId: session.id,
      traceId,
      clickStartedAtMs: switchStartedAt,
      sentAtMs,
      webPhase: type,
      rect: nativeRect,
    })
    if (ok) lastSentRectRef.current = nativeRect
    setOpenError(!ok)
    return ok
  }, [session.id, session.surfaceId, switchStartedAt, switchTraceId])

  const scheduleLayout = useCallback(() => {
    if (layoutFrameRef.current !== null) return
    layoutFrameRef.current = window.requestAnimationFrame(() => {
      layoutFrameRef.current = null
      syncNative('layout')
    })
  }, [syncNative])

  useEffect(() => {
    if (!session.surfaceId) return
    lastSentRectRef.current = null
    lastObservedSizeRef.current = null
    syncNative('attach')
    const surfaceId = session.surfaceId
    const sessionId = session.id
    const resizeObserver = hostRef.current ? new ResizeObserver((entries) => {
      const entry = entries[0]
      if (!entry) return
      const width = Math.round(entry.contentRect.width)
      const height = Math.round(entry.contentRect.height)
      const last = lastObservedSizeRef.current
      if (last && last.width === width && last.height === height) return
      lastObservedSizeRef.current = { width, height }
      scheduleLayout()
    }) : null
    if (hostRef.current) {
      const initial = hostRef.current.getBoundingClientRect()
      lastObservedSizeRef.current = {
        width: Math.round(initial.width),
        height: Math.round(initial.height),
      }
      resizeObserver?.observe(hostRef.current)
    }
    window.addEventListener('resize', scheduleLayout)
    window.addEventListener('meee2:layout-native-terminal', scheduleLayout)
    return () => {
      if (layoutFrameRef.current !== null) {
        window.cancelAnimationFrame(layoutFrameRef.current)
        layoutFrameRef.current = null
      }
      resizeObserver?.disconnect()
      window.removeEventListener('resize', scheduleLayout)
      window.removeEventListener('meee2:layout-native-terminal', scheduleLayout)
      openNativeTerminalSurface({ type: 'hide', surfaceId, sessionId })
    }
  }, [scheduleLayout, session.id, session.surfaceId, syncNative])

  return (
    <div
      ref={hostRef}
      className="sessions-native-terminal"
      aria-label={t('sessions.terminal')}
      onDoubleClick={() => syncNative('focus')}
    >
      <TerminalIcon size={28} aria-hidden />
      <div>
        <h3>{t('sessions.nativeTerminalTitle')}</h3>
        <p>{t('sessions.nativeTerminalBody')}</p>
        {openError && <span>{t('sessions.nativeTerminalUnavailable')}</span>}
      </div>
      <button type="button" onClick={() => syncNative('attach')}>
        <TerminalIcon size={14} aria-hidden />
        {t('sessions.openNativeTerminal')}
      </button>
    </div>
  )
}

function FilterButton({
  label,
  count,
  active,
  onClick,
}: {
  label: string
  count: number
  active: boolean
  onClick: () => void
}) {
  return (
    <button
      type="button"
      className={`sessions-filter${active ? ' is-active' : ''}`}
      aria-pressed={active}
      onClick={onClick}
    >
      <span>{label}</span>
      <em>{count}</em>
    </button>
  )
}

function sameNativeRect(a: NativeTerminalRect | null, b: NativeTerminalRect): boolean {
  if (!a) return false
  return Math.abs(a.x - b.x) < 0.5
    && Math.abs(a.y - b.y) < 0.5
    && Math.abs(a.width - b.width) < 0.5
    && Math.abs(a.height - b.height) < 0.5
}

function isInternalSession(session: Session): boolean {
  return session.terminalKind === 'internal' || Boolean(session.surfaceId)
}

function isLiveInternalSession(session: Session): boolean {
  const status = (session.surfaceStatus || session.status || '').toLowerCase()
  return status !== 'exited' && status !== 'failed' && status !== 'dead'
}

function sessionNeedsAttention(session: Session): boolean {
  return session.status === 'permissionRequired'
    || session.status === 'waitingForUser'
    || session.inboxPending > 0
    || Boolean(session.pendingPermissionTool)
}

function attentionReason(session: Session, unread: boolean, t: ReturnType<typeof useI18n>['t']): string {
  if (session.pendingPermissionTool) return t('sessions.permissionRequiredFor', { tool: session.pendingPermissionTool })
  if (session.pendingPermissionMessage) return session.pendingPermissionMessage
  if (session.inboxPending > 0) return t('sessions.pendingMessages', { count: session.inboxPending })
  if (session.status === 'waitingForUser') return t('sessions.waitingUser')
  if (unread) return t('sessions.unreadActivity')
  return t('sessions.permissionRequired')
}

function sessionIcon(session: Session) {
  if (isInternalSession(session)) return <TerminalIcon size={16} aria-hidden />
  if (session.status === 'permissionRequired' || session.status === 'waitingForUser') return <AlertCircle size={16} aria-hidden />
  if (session.status === 'completed' || session.status === 'done') return <CheckCircle2 size={16} aria-hidden />
  return <Clock3 size={16} aria-hidden />
}

function shortId(id: string): string {
  return id.length > 10 ? `${id.slice(0, 10)}...` : id
}

function sessionMatchesQuery(session: Session, query: string): boolean {
  if (!query) return true
  const values = [
    session.title,
    session.id,
    session.surfaceId,
    session.pluginId,
    session.pluginDisplayName,
    session.project,
    session.status,
    session.surfaceStatus,
    session.currentTool,
    session.currentTask,
    session.latestRecap?.content,
    ...session.recentMessages.map((entry) => entry.text),
  ]
  return values.some((value) => value?.toLowerCase().includes(query))
}

function compareSessions(a: Session, b: Session, unreadSids: Set<string>): number {
  const attentionDelta =
    Number(sessionNeedsAttention(b) || unreadSids.has(b.id)) -
    Number(sessionNeedsAttention(a) || unreadSids.has(a.id))
  if (attentionDelta !== 0) return attentionDelta
  const internalDelta = Number(isInternalSession(b)) - Number(isInternalSession(a))
  if (internalDelta !== 0) return internalDelta
  const workingDelta = Number(isWorkingSession(b)) - Number(isWorkingSession(a))
  if (workingDelta !== 0) return workingDelta
  return timestamp(b.lastActivity) - timestamp(a.lastActivity)
}

function uniqueSessionsById(sessions: Session[]): Session[] {
  const seen = new Set<string>()
  const result: Session[] = []
  for (const session of sessions) {
    if (seen.has(session.id)) continue
    seen.add(session.id)
    result.push(session)
  }
  return result
}

function scheduleStaggeredInternalPrewarm(
  sessions: Session[],
  prewarm: (session: Session, reason?: string) => boolean,
): () => void {
  let cancelled = false
  const cancelTimers: Array<() => void> = []
  sessions.forEach((session, index) => {
    const timeoutId = window.setTimeout(() => {
      if (cancelled) return
      const idleWindow = window as Window & {
        requestIdleCallback?: (callback: () => void, options?: { timeout?: number }) => number
        cancelIdleCallback?: (handle: number) => void
      }
      const run = () => {
        if (!cancelled) prewarm(session, index === 0 ? 'react.tabPrewarm' : 'react.idleTabPrewarm')
      }
      if (idleWindow.requestIdleCallback) {
        const idleHandle = idleWindow.requestIdleCallback(run, { timeout: 900 })
        cancelTimers.push(() => idleWindow.cancelIdleCallback?.(idleHandle))
      } else {
        run()
      }
    }, index === 0 ? 180 : 420 + index * 260)
    cancelTimers.push(() => window.clearTimeout(timeoutId))
  })
  return () => {
    cancelled = true
    for (const cancel of cancelTimers) cancel()
  }
}

function noopSessionAction(_session: Session) {}

function isWorkingSession(session: Session): boolean {
  return !['completed', 'done', 'idle'].includes(session.status)
}

function timestamp(value: string | null | undefined): number {
  if (!value) return 0
  const parsed = Date.parse(value)
  return Number.isNaN(parsed) ? 0 : parsed
}

function relativeTime(value: string, t: ReturnType<typeof useI18n>['t']): string {
  const delta = Date.now() - timestamp(value)
  if (delta < 60_000) return t('sessions.justNow')
  if (delta < 3_600_000) return t('sessions.minutesAgo', { count: Math.floor(delta / 60_000) })
  if (delta < 86_400_000) return t('sessions.hoursAgo', { count: Math.floor(delta / 3_600_000) })
  return t('sessions.daysAgo', { count: Math.floor(delta / 86_400_000) })
}
