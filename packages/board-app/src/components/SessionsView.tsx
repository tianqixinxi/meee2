import { AlertCircle, CheckCircle2, Clock3, ExternalLink, Search, Terminal } from 'lucide-react'
import { useMemo, useState } from 'react'
import { activateSession } from '../api'
import { useI18n } from '../lib/i18n'
import type { BoardState, Session } from '../types'

interface Props {
  state: BoardState | null
  unreadSids: Set<string>
}

type SessionFilter = 'all' | 'attention' | 'unread'

export function SessionsView({ state, unreadSids }: Props) {
  const { t } = useI18n()
  const [query, setQuery] = useState('')
  const [filter, setFilter] = useState<SessionFilter>('attention')
  const [openingId, setOpeningId] = useState<string | null>(null)
  const [openErrorId, setOpenErrorId] = useState<string | null>(null)
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

  const openSession = async (session: Session) => {
    setOpeningId(session.id)
    setOpenErrorId(null)
    const ok = await activateSession(session.id)
    setOpeningId(null)
    if (!ok) setOpenErrorId(session.id)
  }

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
            <Terminal size={18} aria-hidden />
            <span>{t('sessions.empty')}</span>
          </div>
        ) : visibleSessions.length === 0 ? (
          <div className="sessions-empty">
            <Search size={18} aria-hidden />
            <span>{t('sessions.noMatch')}</span>
          </div>
        ) : (
          <div className="sessions-table" role="table" aria-label={t('sessions.table')}>
            <div className="sessions-table__head" role="row">
              <span>{t('sessions.columnSession')}</span>
              <span>{t('sessions.columnStatus')}</span>
              <span>{t('sessions.columnContext')}</span>
              <span>{t('sessions.columnSignal')}</span>
              <span />
            </div>
            <div className="sessions-table__body">
              {visibleSessions.map((session) => (
                <SessionRow
                  key={session.id}
                  session={session}
                  opening={openingId === session.id}
                  openError={openErrorId === session.id}
                  unread={unreadSids.has(session.id)}
                  onOpen={() => openSession(session)}
                  t={t}
                />
              ))}
            </div>
          </div>
        )}
      </div>
    </section>
  )
}

function SessionRow({
  session,
  opening,
  openError,
  unread,
  onOpen,
  t,
}: {
  session: Session
  opening: boolean
  openError: boolean
  unread: boolean
  onOpen: () => void
  t: ReturnType<typeof useI18n>['t']
}) {
  const attention = sessionNeedsAttention(session) || unread
  const context = session.currentTask || session.latestRecap?.content || session.recentMessages[0]?.text || ''
  return (
    <article
      className={[
        'sessions-row',
        attention ? 'sessions-row--attention' : '',
        unread ? 'sessions-row--unread' : '',
      ].filter(Boolean).join(' ')}
      onDoubleClick={onOpen}
      title={t('sessions.doubleClickOpen')}
    >
      <div className="sessions-row__identity">
        <div className="sessions-row__icon" style={{ color: session.pluginColor || undefined }}>
          {sessionIcon(session)}
        </div>
        <div className="sessions-row__main">
          <div className="sessions-row__title">
            <strong>{session.title || shortId(session.id)}</strong>
            <div className="sessions-row__badges">
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
        <strong>{session.status}</strong>
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
        <button type="button" onClick={onOpen} disabled={opening}>
          <ExternalLink size={13} aria-hidden />
          {opening ? t('common.opening') : t('common.open')}
        </button>
      </div>
    </article>
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

function sessionNeedsAttention(session: Session): boolean {
  return session.status === 'permissionRequired'
    || session.status === 'waitingForUser'
    || session.inboxPending > 0
    || Boolean(session.pendingPermissionTool)
}

function attentionReason(session: Session, unread: boolean, t: ReturnType<typeof useI18n>['t']): string {
  if (session.pendingPermissionTool) {
    return t('sessions.permissionRequiredFor', { tool: session.pendingPermissionTool })
  }
  if (session.pendingPermissionMessage) {
    return session.pendingPermissionMessage
  }
  if (session.inboxPending > 0) {
    return t('sessions.pendingMessages', { count: session.inboxPending })
  }
  if (session.status === 'waitingForUser') {
    return t('sessions.waitingUser')
  }
  if (unread) {
    return t('sessions.unreadActivity')
  }
  return t('sessions.permissionRequired')
}

function sessionIcon(session: Session) {
  if (session.status === 'permissionRequired' || session.status === 'waitingForUser') {
    return <AlertCircle size={16} aria-hidden />
  }
  if (session.status === 'completed' || session.status === 'done') {
    return <CheckCircle2 size={16} aria-hidden />
  }
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
    session.pluginId,
    session.pluginDisplayName,
    session.project,
    session.status,
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
  const workingDelta = Number(isWorkingSession(b)) - Number(isWorkingSession(a))
  if (workingDelta !== 0) return workingDelta
  return timestamp(b.lastActivity) - timestamp(a.lastActivity)
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
