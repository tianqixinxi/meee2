import { AlertCircle, CheckCircle2, Clock3, ExternalLink, Search, Terminal } from 'lucide-react'
import { useMemo, useState } from 'react'
import { activateSession } from '../api'
import type { BoardState, Session } from '../types'

interface Props {
  state: BoardState | null
}

export function SessionsView({ state }: Props) {
  const [query, setQuery] = useState('')
  const [openingId, setOpeningId] = useState<string | null>(null)
  const [openErrorId, setOpenErrorId] = useState<string | null>(null)
  const sessions = state?.sessions ?? []
  const visibleSessions = useMemo(() => {
    const normalized = query.trim().toLowerCase()
    return sessions
      .filter((session) => sessionMatchesQuery(session, normalized))
      .sort(compareSessions)
  }, [query, sessions])

  const openSession = async (session: Session) => {
    setOpeningId(session.id)
    setOpenErrorId(null)
    const ok = await activateSession(session.id)
    setOpeningId(null)
    if (!ok) setOpenErrorId(session.id)
  }

  return (
    <section className="sessions-workspace" aria-label="Sessions">
      <div className="sessions-workspace__inner">
        <div className="sessions-workspace__header">
          <div>
            <h1>Sessions</h1>
            <p>Live local AI sessions. meee2 AI nodes only attach after explicit binding.</p>
          </div>
          <label className="sessions-search">
            <Search size={14} aria-hidden />
            <input
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder="Search title, plugin, project, status"
            />
          </label>
        </div>
        {sessions.length === 0 ? (
          <div className="sessions-empty">
            <Terminal size={18} aria-hidden />
            <span>No local sessions</span>
          </div>
        ) : visibleSessions.length === 0 ? (
          <div className="sessions-empty">
            <Search size={18} aria-hidden />
            <span>No matching sessions</span>
          </div>
        ) : (
          <div className="sessions-table" role="table" aria-label="Local sessions">
            <div className="sessions-table__head" role="row">
              <span>Session</span>
              <span>Status</span>
              <span>Context</span>
              <span>Signal</span>
              <span />
            </div>
            <div className="sessions-table__body">
              {visibleSessions.map((session) => (
                <SessionRow
                  key={session.id}
                  session={session}
                  opening={openingId === session.id}
                  openError={openErrorId === session.id}
                  onOpen={() => openSession(session)}
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
  onOpen,
}: {
  session: Session
  opening: boolean
  openError: boolean
  onOpen: () => void
}) {
  const attention = sessionNeedsAttention(session)
  const context = session.currentTask || session.latestRecap?.content || session.recentMessages[0]?.text || ''
  return (
    <article
      className={`sessions-row${attention ? ' sessions-row--attention' : ''}`}
      onDoubleClick={onOpen}
      title="Double-click to open original session"
    >
      <div className="sessions-row__identity">
        <div className="sessions-row__icon" style={{ color: session.pluginColor || undefined }}>
          {sessionIcon(session)}
        </div>
        <div className="sessions-row__main">
          <div className="sessions-row__title">
            <strong>{session.title || shortId(session.id)}</strong>
            <div className="sessions-row__badges">
              {attention && <span className="sessions-row__attention">Attention</span>}
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
        <strong>{session.project || 'No project'}</strong>
        {context && <span>{context}</span>}
      </div>
      <div className="sessions-row__signal">
        {attention ? attentionReason(session) : session.lastActivity ? relativeTime(session.lastActivity) : 'No activity'}
      </div>
      <div className="sessions-row__actions">
        {openError && <span>Open failed</span>}
        <button type="button" onClick={onOpen} disabled={opening}>
          <ExternalLink size={13} aria-hidden />
          {opening ? 'Opening' : 'Open'}
        </button>
      </div>
    </article>
  )
}

function sessionNeedsAttention(session: Session): boolean {
  return session.status === 'permissionRequired'
    || session.status === 'waitingForUser'
    || session.inboxPending > 0
    || Boolean(session.pendingPermissionTool)
}

function attentionReason(session: Session): string {
  if (session.pendingPermissionTool) {
    return `Permission required: ${session.pendingPermissionTool}`
  }
  if (session.pendingPermissionMessage) {
    return session.pendingPermissionMessage
  }
  if (session.inboxPending > 0) {
    return `${session.inboxPending} pending message${session.inboxPending === 1 ? '' : 's'}`
  }
  if (session.status === 'waitingForUser') {
    return 'Waiting for user response'
  }
  return 'Permission required'
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

function compareSessions(a: Session, b: Session): number {
  const attentionDelta = Number(sessionNeedsAttention(b)) - Number(sessionNeedsAttention(a))
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

function relativeTime(value: string): string {
  const delta = Date.now() - timestamp(value)
  if (delta < 60_000) return 'just now'
  if (delta < 3_600_000) return `${Math.floor(delta / 60_000)}m ago`
  if (delta < 86_400_000) return `${Math.floor(delta / 3_600_000)}h ago`
  return `${Math.floor(delta / 86_400_000)}d ago`
}
