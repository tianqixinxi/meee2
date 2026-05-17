import { AlertCircle, CheckCircle2, Clock3, Terminal } from 'lucide-react'
import type { BoardState, Session } from '../types'
import { isOlderSession } from '../types'

interface Props {
  state: BoardState | null
}

export function SessionsView({ state }: Props) {
  const sessions = state?.sessions ?? []
  const active = sessions.filter((session) => !isOlderSession(session))
  const older = sessions.filter((session) => isOlderSession(session))

  return (
    <section className="sessions-workspace" aria-label="Sessions">
      <div className="sessions-workspace__inner">
        <div className="sessions-workspace__header">
          <h1>Sessions</h1>
          <p>Live local AI sessions. meee2 AI nodes only attach after explicit binding.</p>
        </div>
        {sessions.length === 0 ? (
          <div className="sessions-empty">
            <Terminal size={18} aria-hidden />
            <span>No local sessions</span>
          </div>
        ) : (
          <div className="sessions-groups">
            <SessionGroup title="Active" sessions={active} />
            {older.length > 0 && <SessionGroup title="Older" sessions={older} />}
          </div>
        )}
      </div>
    </section>
  )
}

function SessionGroup({ title, sessions }: { title: string; sessions: Session[] }) {
  if (sessions.length === 0) return null
  return (
    <section className="sessions-group">
      <div className="sessions-group__title">
        <span>{title}</span>
        <em>{sessions.length}</em>
      </div>
      <div className="sessions-list">
        {sessions.map((session) => (
          <article key={session.id} className="sessions-row">
            <div className="sessions-row__icon" style={{ color: session.pluginColor || undefined }}>
              {sessionIcon(session)}
            </div>
            <div className="sessions-row__main">
              <div className="sessions-row__title">
                <strong>{session.title || shortId(session.id)}</strong>
                {session.inboxPending > 0 && <span>{session.inboxPending}</span>}
              </div>
              <div className="sessions-row__meta">
                <span>{session.pluginDisplayName || session.pluginId}</span>
                <span>{session.status}</span>
                {session.project && <span>{session.project}</span>}
              </div>
            </div>
          </article>
        ))}
      </div>
    </section>
  )
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
