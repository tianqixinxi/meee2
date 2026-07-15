import {
  AlertCircle,
  Archive,
  CheckCircle2,
  ChevronDown,
  CircleStop,
  Clock3,
  EyeOff,
  ExternalLink,
  FileText,
  HelpCircle,
  MessageSquareText,
  Pencil,
  RefreshCw,
  RotateCw,
  RotateCcw,
  Save,
  Search,
  Send,
  ShieldCheck,
  ShieldX,
  Terminal as TerminalIcon,
  Trash2,
  Wrench,
  Zap,
} from 'lucide-react'
import { memo, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { closeSession, closeSessionSurface, createMemoryRecord, deleteMemoryRecord, fetchMemoryRecords, fetchSessionIntakeDiagnostics, fetchTranscript, injectToSession, listSessionSurfaces, openAccessibilitySettings, openNativeTerminalSurface, pushToDesktopNow, respondToSessionPermission, updateMemoryRecord, updateSessionControl, type NativeTerminalPrewarmAck, type NativeTerminalRect, type NativeTerminalSyncAck, type SessionMemoryRecord, type SessionSurface, type TranscriptBlock, type TranscriptEntryFull } from '../api'
import { useI18n, type TranslationKey } from '../lib/i18n'
import { NATIVE_TERMINAL_STABILIZED_LAYOUT_DELAYS_MS } from '../lib/nativeTerminalLayout'
import { sessionRecapProgressText } from '../lib/sessionRecap'
import { useTheme } from '../lib/theme'
import type { BoardState, CanvasInfo, Session, SessionIntakeDiagnostics } from '../types'

interface Props {
  state: BoardState | null
  canvases?: CanvasInfo[]
  unreadSids: Set<string>
  selectedSessionId?: string | null
  onSelectedSessionChange?: (id: string | null) => void
  onOpenPlannerNode?: (canvasId: string, nodeId: string) => void
  onOpenArtifacts?: (focus: { canvasId: string; nodeId: string; nodeTitle?: string | null }) => void
}

type SessionFilter = 'all' | 'attention' | 'unread'
type SessionKindTab = 'internal' | 'external'
type SessionControlState = 'active' | 'hidden' | 'archived'
type SessionVisibilityFilter = 'current' | 'history' | 'hidden' | 'archived'
type SessionGroup = 'attention' | 'active' | 'recent'
type NativeTerminalSyncType = 'attach' | 'layout' | 'focus'

const SESSION_TERMINAL_RELEASE_DELAY_MS = 120
let activeSessionsNativeSurface: { surfaceId: string; generation: number } | null = null
let activeSessionsNativeSurfaceGeneration = 0

export function SessionsView({
  state,
  canvases = [],
  unreadSids,
  selectedSessionId,
  onSelectedSessionChange,
  onOpenPlannerNode,
  onOpenArtifacts,
}: Props) {
  const { t } = useI18n()
  const { resolvedTheme } = useTheme()
  const [query, setQuery] = useState('')
  const [filter, setFilter] = useState<SessionFilter>('all')
  const [controlFilter, setControlFilter] = useState<SessionVisibilityFilter>('current')
  const [activeKindTab, setActiveKindTab] = useState<SessionKindTab>('internal')
  const [openingId, setOpeningId] = useState<string | null>(null)
  const [openErrorId, setOpenErrorId] = useState<string | null>(null)
  const [diagnostics, setDiagnostics] = useState<SessionIntakeDiagnostics | null>(null)
  const [diagnosticsError, setDiagnosticsError] = useState<string | null>(null)
  const [diagnosticsLoading, setDiagnosticsLoading] = useState(false)
  const [surfaces, setSurfaces] = useState<SessionSurface[]>([])
  const routedSelectedSessionIdRef = useRef<string | null>(null)
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
  const controlCounts = useMemo(() => ({
    current: sessions.filter((session) => sessionControlState(session) === 'active' && !isHistoricalSession(session)).length,
    history: sessions.filter((session) => sessionControlState(session) === 'active' && isHistoricalSession(session)).length,
    hidden: sessions.filter((session) => sessionControlState(session) === 'hidden').length,
    archived: sessions.filter((session) => sessionControlState(session) === 'archived').length,
  }), [sessions])
  const visibleSessions = useMemo(() => {
    const normalized = query.trim().toLowerCase()
    return uniqueSessionsByDisplayIdentity(sessions
      .filter(isInternalSession)
      .filter((session) => sessionMatchesVisibility(session, controlFilter))
      .filter((session) => sessionMatchesQuery(session, normalized))
      .filter((session) => {
        if (filter === 'attention') return sessionNeedsAttention(session) || unreadSids.has(session.id)
        if (filter === 'unread') return unreadSids.has(session.id)
        return true
      }))
      .sort((a, b) => compareSessions(a, b, unreadSids))
  }, [controlFilter, filter, query, sessions, unreadSids])
  const selectedSession = useMemo(() => {
    if (!selectedSessionId) return null
    return sessions.find((session) => (
      session.id === selectedSessionId || session.surfaceId === selectedSessionId
    )) ?? null
  }, [selectedSessionId, sessions])
  const pendingSelectedSessionId = selectedSessionId?.trim() && !selectedSession
    ? selectedSessionId.trim()
    : null
  const internalSessions = useMemo(() => {
    return visibleSessions.filter(isInternalSession)
  }, [visibleSessions])
  const internalSessionGroups = useMemo(
    () => controlFilter === 'history'
      ? [{ group: 'recent' as const, sessions: internalSessions }]
      : groupSessionsForDisplay(internalSessions, unreadSids),
    [controlFilter, internalSessions, unreadSids],
  )
  const selectedSessionOnActiveTab = useMemo(() => {
    if (!selectedSession) return null
    return isInternalSession(selectedSession) ? selectedSession : null
  }, [selectedSession])
  const sessionSurfaceSignature = useMemo(
    () => sessions.map((session) => `${session.id}:${session.surfaceId ?? ''}:${session.surfaceStatus ?? ''}`).sort().join('|'),
    [sessions],
  )
  useEffect(() => {
    let cancelled = false
    listSessionSurfaces()
      .then((items) => {
        if (!cancelled) setSurfaces(Array.isArray(items) ? items : [])
      })
      .catch(() => {
        if (!cancelled) setSurfaces([])
      })
    return () => {
      cancelled = true
    }
  }, [sessionSurfaceSignature])
  const selectedSurface = useMemo(() => (
    selectedSessionOnActiveTab
      ? surfaces.find((surface) => surfaceMatchesSession(surface, selectedSessionOnActiveTab)) ?? null
      : null
  ), [selectedSessionOnActiveTab, surfaces])
  const selectedSurfaceCanvas = useMemo(() => (
    selectedSurface?.canvasId
      ? canvases.find((canvas) => canvas.id === selectedSurface.canvasId) ?? null
      : null
  ), [canvases, selectedSurface?.canvasId])

  useEffect(() => {
    const selectedKey = selectedSessionId?.trim() || null
    if (routedSelectedSessionIdRef.current === selectedKey) return
    routedSelectedSessionIdRef.current = selectedKey
    if (!selectedSession) return
    setActiveKindTab('internal')
  }, [selectedSession, selectedSessionId])

  const prewarmInternalSession = useCallback((session: Session, reason = 'react.prewarm') => {
    if (!session.surfaceId || !isLiveInternalSession(session)) return false
    if (reason === 'react.idleTabPrewarm') return false
    const criticalInteraction = reason.startsWith('react.rowSelect') || reason.startsWith('react.rowOpen')
    if (!criticalInteraction && prewarmedInternalSurfaceIdsRef.current.has(session.surfaceId)) return true
    const ok = openNativeTerminalSurface({
      type: 'prewarm',
      surfaceId: session.surfaceId,
      sessionId: session.id,
      theme: resolvedTheme,
      webPhase: reason,
    })
    return ok
  }, [resolvedTheme])

  const refreshDiagnostics = useCallback(() => {
    setDiagnosticsLoading(true)
    setDiagnosticsError(null)
    fetchSessionIntakeDiagnostics()
      .then(setDiagnostics)
      .catch((err: unknown) => setDiagnosticsError((err as Error).message || 'Failed to load diagnostics'))
      .finally(() => setDiagnosticsLoading(false))
  }, [])

  useEffect(() => {
    refreshDiagnostics()
  }, [refreshDiagnostics, sessions.length])

  useEffect(() => {
    const handlePrewarmAck = (event: Event) => {
      const detail = (event as CustomEvent<NativeTerminalPrewarmAck>).detail
      const surfaceId = detail?.surfaceId?.trim()
      if (!surfaceId) return
      if (detail.ready) {
        prewarmedInternalSurfaceIdsRef.current.add(surfaceId)
      } else {
        prewarmedInternalSurfaceIdsRef.current.delete(surfaceId)
      }
    }
    window.addEventListener('meee2:native-terminal-prewarm', handlePrewarmAck)
    return () => window.removeEventListener('meee2:native-terminal-prewarm', handlePrewarmAck)
  }, [])

  useEffect(() => {
    if (pendingSelectedSessionId) return
    if (activeKindTab !== 'internal' || selectedSessionOnActiveTab || internalSessions.length === 0) return
    const next = internalSessions[0]
    if (selectedSessionId === next.id || selectedSessionId === next.surfaceId) return
    onSelectedSessionChange?.(next?.id ?? null)
  }, [activeKindTab, internalSessions, onSelectedSessionChange, pendingSelectedSessionId, selectedSessionId, selectedSessionOnActiveTab])

  useEffect(() => {
    if (activeKindTab !== 'internal') return
    const targets = uniqueSessionsById([
      ...(selectedSessionOnActiveTab ? [selectedSessionOnActiveTab] : []),
      ...internalSessions,
    ])
      .filter((session) => session.surfaceId && isLiveInternalSession(session))
      .slice(0, 1)
    if (targets.length === 0) return
    return scheduleInternalTabPrewarm(targets[0], prewarmInternalSession)
  }, [activeKindTab, internalSessions, prewarmInternalSession, selectedSessionOnActiveTab])

  const selectInternalSession = useCallback((session: Session, phase = 'react.rowSelect') => {
    const startedAt = Date.now()
    const traceId = `switch-${startedAt.toString(36)}-${Math.random().toString(36).slice(2, 8)}`
    switchStartedAtRef.current[session.id] = startedAt
    switchTraceIdRef.current[session.id] = traceId
    console.debug('[TerminalSwitchPerf]', {
      traceId,
      phase,
      sessionId: session.id,
      surfaceId: session.surfaceId,
    })
    onSelectedSessionChange?.(session.id)
  }, [onSelectedSessionChange])

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
    setOpeningId(null)
    setOpenErrorId(session.id)
  }, [selectInternalSession])

  return (
    <section className="sessions-workspace" aria-label={t('sessions.title')}>
      <div className="sessions-workspace__inner">
        <div className="sessions-workspace__header">
          <div className="sessions-workspace__title">
            <h1>{t('sessions.title')}</h1>
            <span>{t('sessions.sessionCount', { visible: visibleSessions.length, total: sessions.length })}</span>
          </div>
          <div className="sessions-workspace__filters">
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
            <div className="sessions-filters" aria-label={t('sessions.visibilityFilters')}>
              <FilterButton label={t('sessions.controlActive')} count={controlCounts.current} active={controlFilter === 'current'} onClick={() => setControlFilter('current')} />
              <FilterButton label={t('sessions.controlHistory')} count={controlCounts.history} active={controlFilter === 'history'} onClick={() => setControlFilter('history')} />
              <FilterButton label={t('sessions.controlHidden')} count={controlCounts.hidden} active={controlFilter === 'hidden'} onClick={() => setControlFilter('hidden')} />
              <FilterButton label={t('sessions.controlArchived')} count={controlCounts.archived} active={controlFilter === 'archived'} onClick={() => setControlFilter('archived')} />
            </div>
          </div>
          <div className="sessions-workspace__tools">
            <SessionIntakeStatus
              diagnostics={diagnostics}
              error={diagnosticsError}
              loading={diagnosticsLoading}
              onRefresh={refreshDiagnostics}
              t={t}
            />
          </div>
        </div>
        {sessions.length === 0 && !pendingSelectedSessionId ? (
          <div className="sessions-empty">
            <TerminalIcon size={18} aria-hidden />
            <span>{t('sessions.empty')}</span>
          </div>
        ) : (
          <div className="sessions-board">
            {pendingSelectedSessionId && sessions.length === 0 ? (
              <SessionDetail
                session={null}
                pendingSessionId={pendingSelectedSessionId}
                opening={false}
                openError={false}
                onOpen={noopVoid}
                onOpenPlannerNode={onOpenPlannerNode}
                onOpenArtifacts={onOpenArtifacts}
                t={t}
              />
            ) : visibleSessions.length === 0 ? (
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
                  </div>
                  <SessionsSection
                    title={t('sessions.internalSessions')}
                    subtitle={t('sessions.internalSubtitle')}
                    count={internalSessions.length}
                    emptyIcon={<TerminalIcon size={18} aria-hidden />}
                    emptyText={t('sessions.noInternalSessions')}
                  >
                    <div className="sessions-list sessions-list--internal" aria-label={t('sessions.internalSessions')}>
                      {internalSessionGroups.map(({ group, sessions: groupedSessions }) => (
                        <div className="sessions-list__group" key={group}>
                          <div className="sessions-list__group-heading">
                            <span>{sessionGroupLabel(group, controlFilter, t)}</span>
                            <em>{groupedSessions.length}</em>
                          </div>
                          {groupedSessions.map((session) => (
                            <SessionRow
                              key={session.id}
                              session={session}
                              selected={selectedSessionOnActiveTab?.id === session.id}
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
                      ))}
                    </div>
                  </SessionsSection>
                </aside>
                <SessionDetail
                  session={selectedSessionOnActiveTab}
                  pendingSessionId={pendingSelectedSessionId}
                  opening={openingId === selectedSessionOnActiveTab?.id}
                  openError={openErrorId === selectedSessionOnActiveTab?.id}
                  switchStartedAt={selectedSessionOnActiveTab ? switchStartedAtRef.current[selectedSessionOnActiveTab.id] : undefined}
                  switchTraceId={selectedSessionOnActiveTab ? switchTraceIdRef.current[selectedSessionOnActiveTab.id] : undefined}
                  surface={selectedSurface}
                  surfaceCanvas={selectedSurfaceCanvas}
                  onOpen={() => selectedSessionOnActiveTab && openSession(selectedSessionOnActiveTab)}
                  onOpenPlannerNode={onOpenPlannerNode}
                  onOpenArtifacts={onOpenArtifacts}
                  t={t}
                />
              </div>
            )}
          </div>
        )}
      </div>
    </section>
  )
}

function SessionIntakeStatus({
  diagnostics,
  error,
  loading,
  onRefresh,
  t,
}: {
  diagnostics: SessionIntakeDiagnostics | null
  error: string | null
  loading: boolean
  onRefresh: () => void
  t: (key: TranslationKey, vars?: Record<string, string | number>) => string
}) {
  const diagnosticItems = Array.isArray(diagnostics?.items) ? diagnostics.items : []
  const liveSessions = diagnostics?.liveSessions ?? 0
  const storedSessions = diagnostics?.storedSessions ?? 0
  const historicalSessions = diagnostics?.historicalSessions ?? 0
  const tone = error ? 'error' : diagnostics?.ok === false ? 'warn' : 'ok'
  const summary = error
    ? error
    : diagnostics
      ? t('sessions.intakeSummary', {
          live: liveSessions,
          stored: storedSessions,
          historical: historicalSessions,
        })
      : t('sessions.intakeLoading')
  const title = diagnostics?.ok === false
    ? t('sessions.intakeNeedsAttention')
    : tone === 'ok'
      ? t('sessions.intakeOk')
      : t('sessions.intakeTitle')
  const detail = diagnosticItems.slice(0, 2).map((item) => `${item.title}: ${item.detail}`).join('\n') || summary

  return (
    <button
      type="button"
      className={`session-intake-status session-intake-status--${tone}`}
      onClick={onRefresh}
      disabled={loading}
      title={detail}
      aria-label={t('sessions.intakeTitle')}
    >
      {tone === 'ok' ? <CheckCircle2 size={13} aria-hidden /> : <AlertCircle size={13} aria-hidden />}
      <span>{title}</span>
      <em>{summary}</em>
      <span className="session-intake-status__refresh">
        <RefreshCw size={13} className={loading ? 'spin' : undefined} aria-hidden />
      </span>
    </button>
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
  const needsChoice = sessionNeedsChoice(session)
  const done = session.status === 'completed' || session.status === 'done'
  const context = session.currentTask || sessionRecapProgressText(session) || session.recentMessages[0]?.text || ''
  const bgAgents = session.backgroundAgents ?? []
  const bgWorkflow = bgAgents.find((agent) => agent.kind === 'workflow')
  const bgOtherCount = bgAgents.filter((agent) => agent.kind !== 'workflow').length
  return (
    <article
      className={[
        'sessions-row',
        isInternalSession(session) ? 'sessions-row--internal' : 'sessions-row--external',
        selected ? 'is-selected' : '',
        needsChoice ? 'sessions-row--choice' : (attention ? 'sessions-row--attention' : ''),
        done ? 'sessions-row--done' : '',
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
              {needsChoice && <span className="sessions-row__choice">{t('sessions.needsChoice')}</span>}
              {attention && !needsChoice && <span className="sessions-row__attention">{t('sessions.attention')}</span>}
              {done && <span className="sessions-row__done">{t('common.done')}</span>}
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
        {bgWorkflow && (
          <span className="sessions-row__bg-workflow" title={bgWorkflow.description || undefined}>
            {t('sessions.backgroundWorkflow')}
          </span>
        )}
        {bgOtherCount > 0 && (
          <span className="sessions-row__bg-count">{bgOtherCount} {t('sessions.backgroundTasks')}</span>
        )}
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
  pendingSessionId,
  opening,
  openError,
  switchStartedAt,
  switchTraceId,
  surface,
  surfaceCanvas,
  onOpen,
  onOpenPlannerNode,
  onOpenArtifacts,
  t,
}: {
  session: Session | null
  pendingSessionId?: string | null
  opening: boolean
  openError: boolean
  switchStartedAt?: number
  switchTraceId?: string
  surface?: SessionSurface | null
  surfaceCanvas?: CanvasInfo | null
  onOpen: () => void
  onOpenPlannerNode?: (canvasId: string, nodeId: string) => void
  onOpenArtifacts?: (focus: { canvasId: string; nodeId: string; nodeTitle?: string | null }) => void
  t: ReturnType<typeof useI18n>['t']
}) {
  const [stopping, setStopping] = useState(false)
  const [stopConfirming, setStopConfirming] = useState(false)
  const [stopError, setStopError] = useState<string | null>(null)
  const [draft, setDraft] = useState('')
  const [sending, setSending] = useState(false)
  const [pushing, setPushing] = useState(false)
  const [controlStatus, setControlStatus] = useState<string | null>(null)
  const [controlError, setControlError] = useState<string | null>(null)
  const [timeline, setTimeline] = useState<TranscriptEntryFull[]>([])
  const [timelineLoaded, setTimelineLoaded] = useState(false)
  const [timelineLoading, setTimelineLoading] = useState(false)
  const [timelineError, setTimelineError] = useState<string | null>(null)
  const [memoryRecords, setMemoryRecords] = useState<SessionMemoryRecord[]>([])
  const [memoryLoaded, setMemoryLoaded] = useState(false)
  const [memoryDraft, setMemoryDraft] = useState('')
  const [memoryBusyId, setMemoryBusyId] = useState<string | null>(null)
  const [memoryEditingId, setMemoryEditingId] = useState<string | null>(null)
  const [memoryEditDraft, setMemoryEditDraft] = useState('')
  const [memoryError, setMemoryError] = useState<string | null>(null)
  const refreshTimeline = useCallback(async () => {
    if (!session) {
      setTimeline([])
      return
    }
    setTimelineLoading(true)
    setTimelineError(null)
    try {
      const response = await fetchTranscript(session.id, { limit: 48 })
      setTimeline(response.entries)
      setTimelineLoaded(true)
    } catch (err) {
      setTimeline([])
      setTimelineLoaded(true)
      setTimelineError((err as Error).message || t('sessions.timelineLoadFailed'))
    } finally {
      setTimelineLoading(false)
    }
  }, [session, t])
  const refreshMemory = useCallback(async () => {
    if (!session) {
      setMemoryRecords([])
      return
    }
    setMemoryError(null)
    try {
      setMemoryRecords(await fetchMemoryRecords('session', session.id))
      setMemoryLoaded(true)
    } catch (err) {
      setMemoryLoaded(true)
      setMemoryError((err as Error).message || t('sessions.memoryLoadFailed'))
    }
  }, [session, t])
  useEffect(() => {
    setDraft('')
    setMemoryDraft('')
    setMemoryEditingId(null)
    setMemoryEditDraft('')
    setControlStatus(null)
    setControlError(null)
    setStopError(null)
    setStopConfirming(false)
    setTimeline([])
    setTimelineLoaded(false)
    setTimelineError(null)
    setMemoryRecords([])
    setMemoryLoaded(false)
    setMemoryError(null)
  }, [session?.id])
  if (!session) {
    if (pendingSessionId) {
      return (
        <aside className="sessions-detail sessions-detail--empty sessions-detail--pending">
          <RefreshCw size={18} className="spin" aria-hidden />
          <strong>{t('sessions.pendingSelectedSession', { id: shortId(pendingSessionId) })}</strong>
          <span>{t('sessions.pendingSelectedSessionHint')}</span>
        </aside>
      )
    }
    return (
      <aside className="sessions-detail sessions-detail--empty">
        <TerminalIcon size={18} aria-hidden />
        <span>{t('sessions.selectSession')}</span>
      </aside>
    )
  }
  const internal = isInternalSession(session)
  const liveInternal = internal && isLiveInternalSession(session)
  const desktopSession = session.clientKind === 'desktop' && !internal
  const controlState = sessionControlState(session)
  const hasPermissionAction = Boolean(session.pendingPermissionTool || session.pendingPermissionMessage)
  const showActionDrawer = hasPermissionAction || desktopSession || Boolean(controlStatus || controlError)
  const boundCanvasId = surface?.canvasId?.trim() || ''
  const boundNodeId = surface?.nodeId?.trim() || ''
  const boundNodeTitle = surface?.title?.trim() || session.title || boundNodeId
  const timelineItemCount = buildTimelineItems(timeline, session, t).length
  const runControlAction = async (action: 'hide' | 'archive' | 'restore') => {
    setControlError(null)
    setControlStatus(null)
    try {
      await updateSessionControl(session.id, action)
      setControlStatus(t(action === 'restore' ? 'sessions.restored' : action === 'archive' ? 'sessions.archived' : 'sessions.hidden'))
    } catch (err) {
      setControlError((err as Error).message || t('sessions.controlActionFailed'))
    }
  }
  const answerPermission = async (decision: 'allow' | 'deny') => {
    setControlError(null)
    setControlStatus(null)
    try {
      await respondToSessionPermission(session.id, decision, decision === 'deny' ? 'Denied from Meee2 Board' : undefined)
      setControlStatus(t(decision === 'allow' ? 'sessions.permissionAllowed' : 'sessions.permissionDenied'))
      void refreshTimeline()
    } catch (err) {
      setControlError((err as Error).message || t('sessions.permissionActionFailed'))
    }
  }
  const addMemory = async () => {
    const content = memoryDraft.trim()
    if (!content) return
    setMemoryBusyId('new')
    setMemoryError(null)
    try {
      const record = await createMemoryRecord({
        scope: 'session',
        subjectId: session.id,
        kind: 'lesson',
        content,
        source: 'operator',
        evidenceRef: session.latestRecap?.content ? 'latest-recap' : 'session-detail',
      })
      setMemoryRecords((records) => [record, ...records])
      setMemoryDraft('')
    } catch (err) {
      setMemoryError((err as Error).message || t('sessions.memorySaveFailed'))
    } finally {
      setMemoryBusyId(null)
    }
  }
  const saveMemory = async (record: SessionMemoryRecord) => {
    const content = memoryEditDraft.trim()
    if (!content) return
    setMemoryBusyId(record.id)
    setMemoryError(null)
    try {
      const updated = await updateMemoryRecord(record.id, { content, kind: record.kind })
      setMemoryRecords((records) => records.map((item) => item.id === updated.id ? updated : item))
      setMemoryEditingId(null)
      setMemoryEditDraft('')
    } catch (err) {
      setMemoryError((err as Error).message || t('sessions.memorySaveFailed'))
    } finally {
      setMemoryBusyId(null)
    }
  }
  const removeMemory = async (record: SessionMemoryRecord) => {
    setMemoryBusyId(record.id)
    setMemoryError(null)
    try {
      await deleteMemoryRecord(record.id)
      setMemoryRecords((records) => records.filter((item) => item.id !== record.id))
    } catch (err) {
      setMemoryError((err as Error).message || t('sessions.memoryDeleteFailed'))
    } finally {
      setMemoryBusyId(null)
    }
  }
  const sendMessage = async () => {
    const content = draft.trim()
    if (!content) return
    setSending(true)
    setControlError(null)
    setControlStatus(null)
    try {
      const result = await injectToSession(session.id, content)
      setDraft('')
      setControlStatus(result.delivery === 'queued_until_next_turn' ? t('sessions.queuedUntilNextTurn') : t('sessions.sent'))
      void refreshTimeline()
    } catch (err) {
      setControlError((err as Error).message || t('sessions.sendFailed'))
    } finally {
      setSending(false)
    }
  }
  const pushNow = async () => {
    const content = draft.trim()
    setPushing(true)
    setControlError(null)
    setControlStatus(null)
    try {
      const result = await pushToDesktopNow(session.id, content)
      if (result.error) {
        setControlError(result.error)
        if (result.errorCode === 'accessibility_denied') void openAccessibilitySettings()
        return
      }
      if (content) setDraft('')
      setControlStatus(t('sessions.pushDelivered', { count: result.delivered }))
      void refreshTimeline()
    } catch (err) {
      setControlError((err as Error).message || t('sessions.pushFailed'))
    } finally {
      setPushing(false)
    }
  }
  const stopSession = async () => {
    if (!stopConfirming) {
      setStopConfirming(true)
      return
    }
    setStopping(true)
    setStopError(null)
    try {
      if (internal && session.surfaceId) {
        await closeSessionSurface(session.surfaceId)
      } else {
        const result = await closeSession(session.id)
        if (!result.ok) {
          setStopError(result.errorCode === 'no_pid' ? t('sessions.stopUnsupported') : (result.error || t('sessions.stopFailed')))
        }
      }
    } catch (err) {
      setStopError((err as Error).message || t('sessions.stopFailed'))
    } finally {
      setStopping(false)
      setStopConfirming(false)
    }
  }
  return (
    <aside className="sessions-detail">
      <div className="sessions-detail__header">
        <div className="sessions-detail__identity">
          <span>{internal ? t('sessions.internal') : t('sessions.external')}</span>
          <h2>{session.title || shortId(session.id)}</h2>
          <p>
            <strong>{session.surfaceStatus || session.status}</strong>
            <span>{session.project || t('sessions.noProject')}</span>
            <em>{shortId(session.id)}</em>
          </p>
        </div>
        <div className="sessions-detail__actions">
          <button type="button" onClick={onOpen} disabled={opening} title={t('sessions.openSession')} aria-label={t('sessions.openSession')}>
            {internal ? <TerminalIcon size={14} aria-hidden /> : <ExternalLink size={14} aria-hidden />}
            <span>{opening ? t('common.opening') : t('sessions.openSession')}</span>
          </button>
          <button
            type="button"
            className={stopConfirming ? 'sessions-detail__danger' : undefined}
            onClick={stopSession}
            disabled={stopping || (internal && (session.surfaceStatus === 'exited' || session.surfaceStatus === 'failed'))}
            title={stopConfirming ? t('sessions.confirmStop') : t('sessions.stop')}
            aria-label={stopConfirming ? t('sessions.confirmStop') : t('sessions.stop')}
          >
            <CircleStop size={14} aria-hidden />
            <span>{stopping ? t('sessions.stopping') : stopConfirming ? t('sessions.confirmStop') : t('sessions.stop')}</span>
          </button>
          {controlState === 'active' ? (
            <>
              <button type="button" onClick={() => void runControlAction('hide')} title={t('sessions.hide')} aria-label={t('sessions.hide')}>
                <EyeOff size={14} aria-hidden />
                <span>{t('sessions.hide')}</span>
              </button>
              <button type="button" onClick={() => void runControlAction('archive')} title={t('sessions.archive')} aria-label={t('sessions.archive')}>
                <Archive size={14} aria-hidden />
                <span>{t('sessions.archive')}</span>
              </button>
            </>
          ) : (
            <button type="button" onClick={() => void runControlAction('restore')} title={t('sessions.restore')} aria-label={t('sessions.restore')}>
              <RotateCcw size={14} aria-hidden />
              <span>{t('sessions.restore')}</span>
            </button>
          )}
        </div>
      </div>
      {boundCanvasId && boundNodeId && (
        <div className="sessions-detail__context">
          <div>
            <span>{t('sessions.boundNode')}</span>
            <strong>{boundNodeTitle}</strong>
            <em>{surfaceCanvas?.name ?? shortId(boundCanvasId)}</em>
          </div>
          <button
            type="button"
            onClick={() => onOpenPlannerNode?.(boundCanvasId, boundNodeId)}
            disabled={!onOpenPlannerNode}
          >
            <ExternalLink size={13} aria-hidden />
            {t('sessions.openNode')}
          </button>
          <button
            type="button"
            onClick={() => onOpenArtifacts?.({
              canvasId: boundCanvasId,
              nodeId: boundNodeId,
              nodeTitle: boundNodeTitle,
            })}
            disabled={!onOpenArtifacts}
          >
            <FileText size={13} aria-hidden />
            {t('sessions.openArtifacts')}
          </button>
        </div>
      )}
      <section className="sessions-terminal-stage">
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
            <span>{t('sessions.unmanagedSummary')}</span>
          </div>
        )}
      </section>
      <div className="sessions-detail__drawers">
        {(openError || stopError) && (
          <div className="sessions-detail__alerts">
            {openError && <p className="sessions-detail__error">{t('common.openFailed')}</p>}
            {stopError && <p className="sessions-detail__error">{stopError}</p>}
          </div>
        )}
        {showActionDrawer && (
          <SessionDrawer
            title={hasPermissionAction ? t('sessions.permissionRequired') : t('sessions.fallbackInput')}
            meta={session.pendingPermissionTool
              ? t('sessions.permissionRequiredFor', { tool: session.pendingPermissionTool })
              : desktopSession
                ? t('sessions.fallbackInputMeta')
                : t('sessions.actionsReady')}
            defaultOpen={Boolean(hasPermissionAction || controlStatus || controlError)}
          >
            <section className="sessions-control" aria-label={t('sessions.control')}>
              {hasPermissionAction && (
                <div className="sessions-control__permission-actions">
                  <span className="sessions-control__permission">
                    {session.pendingPermissionTool
                      ? t('sessions.permissionRequiredFor', { tool: session.pendingPermissionTool })
                      : t('sessions.permissionRequired')}
                  </span>
                  <button type="button" onClick={() => void answerPermission('allow')}>
                    <ShieldCheck size={13} aria-hidden />
                    {t('sessions.allowPermission')}
                  </button>
                  <button type="button" onClick={() => void answerPermission('deny')}>
                    <ShieldX size={13} aria-hidden />
                    {t('sessions.denyPermission')}
                  </button>
                </div>
              )}
              {desktopSession && (
                <div className="sessions-composer">
                  <textarea
                    value={draft}
                    onChange={(event) => setDraft(event.target.value)}
                    placeholder={t('sessions.messagePlaceholder')}
                    rows={2}
                  />
                  <div className="sessions-composer__actions">
                    <button type="button" onClick={sendMessage} disabled={sending || draft.trim().length === 0}>
                      <Send size={13} aria-hidden />
                      {sending ? t('sessions.sending') : t('sessions.sendMessage')}
                    </button>
                    <button type="button" onClick={pushNow} disabled={pushing}>
                      <Zap size={13} aria-hidden />
                      {pushing ? t('sessions.pushing') : t('sessions.pushNow')}
                    </button>
                  </div>
                </div>
              )}
              {controlStatus && <p className="sessions-detail__status">{controlStatus}</p>}
              {controlError && <p className="sessions-detail__error">{controlError}</p>}
            </section>
          </SessionDrawer>
        )}
        <SessionDrawer
          title={t('sessions.timeline')}
          meta={timelineLoading
            ? t('sessions.timelineLoading')
            : timelineLoaded
              ? t('sessions.timelineCount', { count: timelineItemCount })
              : t('sessions.openToLoad')}
          onOpen={() => {
            if (!timelineLoaded && !timelineLoading) void refreshTimeline()
          }}
        >
          <SessionTimeline
            entries={timeline}
            loading={timelineLoading}
            error={timelineError}
            session={session}
            onRefresh={refreshTimeline}
            t={t}
          />
        </SessionDrawer>
        <SessionDrawer
          title={t('sessions.memory')}
          meta={memoryLoaded ? t('sessions.memoryCount', { count: memoryRecords.length }) : t('sessions.openToLoad')}
          onOpen={() => {
            if (!memoryLoaded) void refreshMemory()
          }}
        >
          <SessionMemoryPanel
            records={memoryRecords}
            draft={memoryDraft}
            busyId={memoryBusyId}
            editingId={memoryEditingId}
            editDraft={memoryEditDraft}
            error={memoryError}
            onDraftChange={setMemoryDraft}
            onAdd={addMemory}
            onEdit={(record) => {
              setMemoryEditingId(record.id)
              setMemoryEditDraft(record.content)
            }}
            onEditDraftChange={setMemoryEditDraft}
            onSave={saveMemory}
            onCancelEdit={() => {
              setMemoryEditingId(null)
              setMemoryEditDraft('')
            }}
            onDelete={removeMemory}
            t={t}
          />
        </SessionDrawer>
      </div>
    </aside>
  )
}

function SessionDrawer({
  title,
  meta,
  defaultOpen = false,
  onOpen,
  children,
}: {
  title: string
  meta?: string
  defaultOpen?: boolean
  onOpen?: () => void
  children: ReactNode
}) {
  const detailsRef = useRef<HTMLDetailsElement | null>(null)
  useEffect(() => {
    if (!defaultOpen || !detailsRef.current) return
    detailsRef.current.open = true
    onOpen?.()
  }, [defaultOpen, onOpen])
  return (
    <details
      ref={detailsRef}
      className="sessions-drawer"
      onToggle={(event) => {
        if ((event.currentTarget as HTMLDetailsElement).open) onOpen?.()
      }}
    >
      <summary>
        <strong>{title}</strong>
        {meta && <span>{meta}</span>}
        <ChevronDown size={13} aria-hidden />
      </summary>
      <div className="sessions-drawer__body">{children}</div>
    </details>
  )
}

function SessionTimeline({
  entries,
  loading,
  error,
  session,
  onRefresh,
  t,
}: {
  entries: TranscriptEntryFull[]
  loading: boolean
  error: string | null
  session: Session
  onRefresh: () => void
  t: ReturnType<typeof useI18n>['t']
}) {
  const timelineItems = buildTimelineItems(entries, session, t)
  return (
    <section className="sessions-timeline" aria-label={t('sessions.timeline')}>
      <div className="sessions-timeline__heading">
        <div>
          <strong>{t('sessions.timeline')}</strong>
          <span>{loading ? t('sessions.timelineLoading') : t('sessions.timelineCount', { count: timelineItems.length })}</span>
        </div>
        <button type="button" onClick={onRefresh} disabled={loading}>
          <RotateCw size={13} className={loading ? 'spin' : undefined} aria-hidden />
          {t('sessions.refreshTimeline')}
        </button>
      </div>
      {error && <p className="sessions-detail__error">{error}</p>}
      {timelineItems.length === 0 && !loading ? (
        <div className="sessions-timeline__empty">
          <MessageSquareText size={16} aria-hidden />
          <span>{t('sessions.timelineEmpty')}</span>
        </div>
      ) : (
        <ol className="sessions-timeline__list">
          {timelineItems.map((item) => (
            <li key={item.id} className={`sessions-timeline__item sessions-timeline__item--${item.kind}`}>
              <span className="sessions-timeline__icon">{item.icon}</span>
              <div>
                <header>
                  <strong>{item.title}</strong>
                  {item.time && <span>{item.time}</span>}
                </header>
                <p>{item.body}</p>
              </div>
            </li>
          ))}
        </ol>
      )}
    </section>
  )
}

function SessionMemoryPanel({
  records,
  draft,
  busyId,
  editingId,
  editDraft,
  error,
  onDraftChange,
  onAdd,
  onEdit,
  onEditDraftChange,
  onSave,
  onCancelEdit,
  onDelete,
  t,
}: {
  records: SessionMemoryRecord[]
  draft: string
  busyId: string | null
  editingId: string | null
  editDraft: string
  error: string | null
  onDraftChange: (value: string) => void
  onAdd: () => void
  onEdit: (record: SessionMemoryRecord) => void
  onEditDraftChange: (value: string) => void
  onSave: (record: SessionMemoryRecord) => void
  onCancelEdit: () => void
  onDelete: (record: SessionMemoryRecord) => void
  t: ReturnType<typeof useI18n>['t']
}) {
  return (
    <section className="sessions-memory" aria-label={t('sessions.memory')}>
      <div className="sessions-timeline__heading">
        <div>
          <strong>{t('sessions.memory')}</strong>
          <span>{t('sessions.memoryCount', { count: records.length })}</span>
        </div>
      </div>
      <div className="sessions-memory__composer">
        <textarea
          value={draft}
          onChange={(event) => onDraftChange(event.target.value)}
          placeholder={t('sessions.memoryPlaceholder')}
          rows={2}
        />
        <button type="button" onClick={onAdd} disabled={busyId === 'new' || draft.trim().length === 0}>
          <Save size={13} aria-hidden />
          {t('sessions.addMemory')}
        </button>
      </div>
      {error && <p className="sessions-detail__error">{error}</p>}
      {records.length === 0 ? (
        <div className="sessions-timeline__empty">
          <MessageSquareText size={16} aria-hidden />
          <span>{t('sessions.memoryEmpty')}</span>
        </div>
      ) : (
        <ol className="sessions-memory__list">
          {records.map((record) => (
            <li key={record.id} className="sessions-memory__item">
              {editingId === record.id ? (
                <>
                  <textarea value={editDraft} onChange={(event) => onEditDraftChange(event.target.value)} rows={2} />
                  <div className="sessions-memory__actions">
                    <button type="button" onClick={() => onSave(record)} disabled={busyId === record.id || editDraft.trim().length === 0}>
                      <Save size={13} aria-hidden />
                      {t('common.save')}
                    </button>
                    <button type="button" onClick={onCancelEdit}>{t('common.cancel')}</button>
                  </div>
                </>
              ) : (
                <>
                  <header>
                    <strong>{record.kind}</strong>
                    <span>{record.source}{record.evidenceRef ? ` · ${record.evidenceRef}` : ''}</span>
                  </header>
                  <p>{record.content}</p>
                  <div className="sessions-memory__actions">
                    <button type="button" onClick={() => onEdit(record)}>
                      <Pencil size={13} aria-hidden />
                      {t('common.edit')}
                    </button>
                    <button type="button" onClick={() => onDelete(record)} disabled={busyId === record.id}>
                      <Trash2 size={13} aria-hidden />
                      {t('common.delete')}
                    </button>
                  </div>
                </>
              )}
            </li>
          ))}
        </ol>
      )}
    </section>
  )
}

interface TimelineItem {
  id: string
  kind: 'message' | 'tool' | 'permission' | 'recap'
  title: string
  body: string
  time: string | null
  icon: ReactNode
}

function buildTimelineItems(
  entries: TranscriptEntryFull[],
  session: Session,
  t: ReturnType<typeof useI18n>['t'],
): TimelineItem[] {
  const items: TimelineItem[] = []
  if (session.pendingPermissionTool || session.pendingPermissionMessage) {
    items.push({
      id: `${session.id}:permission`,
      kind: 'permission',
      title: session.pendingPermissionTool
        ? t('sessions.permissionRequiredFor', { tool: session.pendingPermissionTool })
        : t('sessions.permissionRequired'),
      body: session.pendingPermissionMessage || t('sessions.waitingUser'),
      time: session.lastActivity ? relativeTime(session.lastActivity, t) : null,
      icon: <AlertCircle size={13} aria-hidden />,
    })
  }
  if (session.latestRecap?.content) {
    items.push({
      id: `${session.id}:recap`,
      kind: 'recap',
      title: t('sessions.recap'),
      body: compactTimelineText(session.latestRecap.content),
      time: session.latestRecap.timestamp ? relativeTime(session.latestRecap.timestamp, t) : null,
      icon: <MessageSquareText size={13} aria-hidden />,
    })
  }
  for (const entry of entries) {
    const primaryTool = entry.blocks.find((block) => block.type === 'tool_use' || block.type === 'tool_result')
    const title = primaryTool
      ? timelineToolTitle(primaryTool, t)
      : timelineEntryTitle(entry.type, t)
    items.push({
      id: entry.id,
      kind: primaryTool ? 'tool' : 'message',
      title,
      body: compactTimelineText(entry.blocks.map(timelineBlockText).filter(Boolean).join(' · ')),
      time: entry.timestamp ? relativeTime(entry.timestamp, t) : null,
      icon: primaryTool ? <Wrench size={13} aria-hidden /> : <MessageSquareText size={13} aria-hidden />,
    })
  }
  return items.filter((item) => item.body.length > 0).slice(0, 60)
}

function timelineToolTitle(block: TranscriptBlock, t: ReturnType<typeof useI18n>['t']): string {
  if (block.type === 'tool_result') return t('sessions.toolResult')
  return block.toolName ? t('sessions.toolCallNamed', { tool: block.toolName }) : t('sessions.toolCall')
}

function timelineEntryTitle(type: TranscriptEntryFull['type'], t: ReturnType<typeof useI18n>['t']): string {
  if (type === 'user') return t('sessions.userMessage')
  if (type === 'assistant') return t('sessions.assistantMessage')
  if (type === 'injected') return t('sessions.injectedMessage')
  return t('sessions.systemMessage')
}

function timelineBlockText(block: TranscriptBlock): string {
  if (block.type === 'text' || block.type === 'thinking') return block.text ?? ''
  if (block.type === 'tool_use') return block.toolInputJSON ? `${block.toolName ?? 'tool'} ${block.toolInputJSON}` : (block.toolName ?? '')
  if (block.type === 'tool_result') return block.toolResultText ?? ''
  return ''
}

function compactTimelineText(value: string): string {
  const normalized = value.replace(/\s+/g, ' ').trim()
  return normalized.length > 220 ? `${normalized.slice(0, 220)}...` : normalized
}

function surfaceMatchesSession(surface: SessionSurface, session: Session): boolean {
  return surface.surfaceId === session.surfaceId
    || surface.sessionId === session.id
    || Boolean(session.surfaceId && surface.sessionId === session.surfaceId)
    || Boolean(session.surfaceId && surface.surfaceId === session.id)
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
  const { resolvedTheme } = useTheme()
  const hostRef = useRef<HTMLDivElement | null>(null)
  const layoutFrameRef = useRef<number | null>(null)
  const layoutTimerRefs = useRef<number[]>([])
  const lastSentRectRef = useRef<NativeTerminalRect | null>(null)
  const lastObservedSizeRef = useRef<{ width: number; height: number } | null>(null)
  const [openError, setOpenError] = useState(false)

  useEffect(() => {
    const handleSyncAck = (event: Event) => {
      const detail = (event as CustomEvent<NativeTerminalSyncAck>).detail
      const surfaceId = detail?.surfaceId?.trim()
      if (!surfaceId || surfaceId !== session.surfaceId) return
      if (detail.sessionId && detail.sessionId !== session.id) return
      if (detail.type === 'attach') {
        setOpenError(detail.ok === false)
      }
      if (detail.traceId) {
        console.debug('[TerminalSwitchPerf]', {
          traceId: detail.traceId,
          phase: `web.${detail.type ?? 'terminal'}.ack`,
          sessionId: session.id,
          surfaceId,
          ok: detail.ok,
          reason: detail.reason,
          cacheHit: detail.cacheHit,
          activeChanged: detail.activeChanged,
        })
      }
    }
    window.addEventListener('meee2:native-terminal-sync', handleSyncAck)
    return () => window.removeEventListener('meee2:native-terminal-sync', handleSyncAck)
  }, [session.id, session.surfaceId])

  const syncNative = useCallback((type: NativeTerminalSyncType = 'attach', options?: { force?: boolean }) => {
    if (!session.surfaceId || !hostRef.current) return false
    const rect = hostRef.current.getBoundingClientRect()
    const nativeRect = {
      x: rect.left,
      y: rect.top,
      width: rect.width,
      height: rect.height,
    }
    if (type === 'layout' && !options?.force && sameNativeRect(lastSentRectRef.current, nativeRect)) {
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
      theme: resolvedTheme,
      traceId,
      clickStartedAtMs: switchStartedAt,
      sentAtMs,
      webPhase: type,
      rect: nativeRect,
    })
    if (ok && type === 'attach') {
      activeSessionsNativeSurface = {
        surfaceId: session.surfaceId,
        generation: ++activeSessionsNativeSurfaceGeneration,
      }
    }
    if (ok) lastSentRectRef.current = nativeRect
    setOpenError(!ok)
    return ok
  }, [resolvedTheme, session.id, session.surfaceId, switchStartedAt, switchTraceId])

  const scheduleLayout = useCallback(() => {
    if (layoutFrameRef.current !== null) return
    layoutFrameRef.current = window.requestAnimationFrame(() => {
      layoutFrameRef.current = null
      syncNative('layout')
    })
  }, [syncNative])

  const scheduleStabilizedLayouts = useCallback(() => {
    layoutTimerRefs.current.forEach((timer) => window.clearTimeout(timer))
    layoutTimerRefs.current = NATIVE_TERMINAL_STABILIZED_LAYOUT_DELAYS_MS.map((delay) => window.setTimeout(() => {
      syncNative('layout', { force: true })
    }, delay))
  }, [syncNative])

  useLayoutEffect(() => {
    if (!session.surfaceId) return
    lastSentRectRef.current = null
    lastObservedSizeRef.current = null
    syncNative('attach')
    scheduleStabilizedLayouts()
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
      layoutTimerRefs.current.forEach((timer) => window.clearTimeout(timer))
      layoutTimerRefs.current = []
      resizeObserver?.disconnect()
      window.removeEventListener('resize', scheduleLayout)
      window.removeEventListener('meee2:layout-native-terminal', scheduleLayout)
      const releasedGeneration = activeSessionsNativeSurface?.surfaceId === surfaceId
        ? activeSessionsNativeSurface.generation
        : null
      window.setTimeout(() => {
        if (
          activeSessionsNativeSurface?.surfaceId === surfaceId
          && activeSessionsNativeSurface.generation === releasedGeneration
        ) {
          activeSessionsNativeSurface = null
          openNativeTerminalSurface({ type: 'hide', surfaceId, sessionId, theme: resolvedTheme })
        }
      }, SESSION_TERMINAL_RELEASE_DELAY_MS)
    }
  }, [resolvedTheme, scheduleLayout, scheduleStabilizedLayouts, session.id, session.surfaceId, syncNative])

  return (
    <div
      ref={hostRef}
      className={`sessions-native-terminal${openError ? ' is-unavailable' : ''}`}
      aria-label={t('sessions.terminal')}
      tabIndex={0}
      onFocus={() => {
        syncNative('focus')
        scheduleStabilizedLayouts()
      }}
      onDoubleClick={() => {
        syncNative('focus')
        scheduleStabilizedLayouts()
      }}
    >
      {openError && (
        <div className="sessions-native-terminal__fallback" role="status">
          <TerminalIcon size={18} aria-hidden />
          <span>{t('sessions.nativeTerminalUnavailable')}</span>
          <button type="button" onClick={() => syncNative('attach')}>
            {t('sessions.openNativeTerminal')}
          </button>
        </div>
      )}
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

// 等用户「做选择」（AskUserQuestion 选项 / ExitPlanMode 批准计划）——区别于
// 「需要权限」（allow/deny 工具门）。两者都需要人介入，但语义和提示不同。
function sessionNeedsChoice(session: Session): boolean {
  return session.status === 'awaitingChoice' || Boolean(session.pendingChoiceTool)
}

function sessionNeedsAttention(session: Session): boolean {
  return session.status === 'permissionRequired'
    || session.status === 'waitingForUser'
    || session.inboxPending > 0
    || Boolean(session.pendingPermissionTool)
    || sessionNeedsChoice(session)
}

function choiceReason(session: Session, t: ReturnType<typeof useI18n>['t']): string {
  if (session.pendingChoiceTool === 'ExitPlanMode') return t('sessions.choicePlan')
  if (session.pendingChoiceMessage) return t('sessions.choiceFor', { question: session.pendingChoiceMessage })
  return t('sessions.needsChoice')
}

function attentionReason(session: Session, unread: boolean, t: ReturnType<typeof useI18n>['t']): string {
  if (sessionNeedsChoice(session)) return choiceReason(session, t)
  if (session.pendingPermissionTool) return t('sessions.permissionRequiredFor', { tool: session.pendingPermissionTool })
  if (session.pendingPermissionMessage) return session.pendingPermissionMessage
  if (session.inboxPending > 0) return t('sessions.pendingMessages', { count: session.inboxPending })
  if (session.status === 'waitingForUser') return t('sessions.waitingUser')
  if (unread) return t('sessions.unreadActivity')
  return t('sessions.permissionRequired')
}

function sessionIcon(session: Session) {
  if (isInternalSession(session)) return <TerminalIcon size={16} aria-hidden />
  if (sessionNeedsChoice(session)) return <HelpCircle size={16} aria-hidden />
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

function uniqueSessionsByDisplayIdentity(sessions: Session[]): Session[] {
  const seen = new Set<string>()
  const result: Session[] = []
  for (const session of sessions) {
    const aliases = [
      session.id,
      session.surfaceId,
      session.providerResumeSessionId,
    ]
      .map((value) => value?.trim())
      .filter((value): value is string => Boolean(value))
    if (aliases.some((alias) => seen.has(alias))) continue
    aliases.forEach((alias) => seen.add(alias))
    result.push(session)
  }
  return result
}

function scheduleInternalTabPrewarm(
  session: Session,
  prewarm: (session: Session, reason?: string) => boolean,
): () => void {
  let cancelled = false
  const cancelTimers: Array<() => void> = []
  const timeoutId = window.setTimeout(() => {
    if (cancelled) return
    const idleWindow = window as Window & {
      requestIdleCallback?: (callback: () => void, options?: { timeout?: number }) => number
      cancelIdleCallback?: (handle: number) => void
    }
    const run = () => {
      if (!cancelled) prewarm(session, 'react.tabPrewarm')
    }
    if (idleWindow.requestIdleCallback) {
      const idleHandle = idleWindow.requestIdleCallback(run, { timeout: 900 })
      cancelTimers.push(() => idleWindow.cancelIdleCallback?.(idleHandle))
    } else {
      run()
    }
  }, 180)
  cancelTimers.push(() => window.clearTimeout(timeoutId))
  return () => {
    cancelled = true
    for (const cancel of cancelTimers) cancel()
  }
}

function noopVoid() {}

const SESSION_HISTORY_AGE_MS = 25 * 24 * 60 * 60 * 1000

function sessionControlState(session: Session): SessionControlState {
  return session.controlState === 'hidden' || session.controlState === 'archived'
    ? session.controlState
    : 'active'
}

function sessionMatchesVisibility(session: Session, visibility: SessionVisibilityFilter): boolean {
  const controlState = sessionControlState(session)
  if (visibility === 'hidden' || visibility === 'archived') return controlState === visibility
  if (controlState !== 'active') return false
  return visibility === 'history' ? isHistoricalSession(session) : !isHistoricalSession(session)
}

function isHistoricalSession(session: Session): boolean {
  const status = (session.surfaceStatus || session.status || '').trim().toLowerCase()
  if (status === 'exited' || status === 'failed' || status === 'dead') return true
  const activity = timestamp(session.lastActivity || session.startedAt)
  return activity > 0 && Date.now() - activity >= SESSION_HISTORY_AGE_MS
}

function groupSessionsForDisplay(
  sessions: Session[],
  unreadSids: Set<string>,
): Array<{ group: SessionGroup; sessions: Session[] }> {
  const grouped: Record<SessionGroup, Session[]> = {
    attention: [],
    active: [],
    recent: [],
  }
  for (const session of sessions) {
    if (sessionNeedsAttention(session) || unreadSids.has(session.id)) {
      grouped.attention.push(session)
    } else if (isWorkingSession(session) && isLiveInternalSession(session)) {
      grouped.active.push(session)
    } else {
      grouped.recent.push(session)
    }
  }
  return (['attention', 'active', 'recent'] as const)
    .map((group) => ({ group, sessions: grouped[group] }))
    .filter(({ sessions: items }) => items.length > 0)
}

function sessionGroupLabel(
  group: SessionGroup,
  visibility: SessionVisibilityFilter,
  t: ReturnType<typeof useI18n>['t'],
): string {
  if (visibility === 'history') return t('sessions.groupHistory')
  if (group === 'attention') return t('sessions.groupNeedsAttention')
  if (group === 'active') return t('sessions.groupActive')
  return t('sessions.groupRecent')
}

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
