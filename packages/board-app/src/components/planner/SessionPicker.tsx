import { AlertCircle, CheckCircle2, Clock3, Search, Terminal, X } from 'lucide-react'
import { useMemo, useState } from 'react'
import type { Session } from '../../types'

interface Props {
  /** Local sessions to pick from — usually `boardState.sessions`. */
  sessions: Session[]
  /** Disables the picker rows while a bind request is in flight. */
  busy?: boolean
  onPick: (sessionId: string) => void
  onClose: () => void
}

/**
 * Reusable local-session picker. Mirrors `SessionsView` styling but is a compact
 * modal: search + a scrollable list, one click attaches an existing session to
 * a planner node's single active-session slot.
 */
export function SessionPicker({ sessions, busy = false, onPick, onClose }: Props) {
  const [query, setQuery] = useState('')
  const visibleSessions = useMemo(() => {
    const normalized = query.trim().toLowerCase()
    return sessions.filter((session) => sessionMatchesQuery(session, normalized))
  }, [query, sessions])

  return (
    <div
      className="planner-session-picker-backdrop"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onClose()
      }}
    >
      <div
        className="planner-session-picker"
        role="dialog"
        aria-modal="true"
        aria-label="Attach an existing session"
      >
        <button
          type="button"
          className="planner-session-picker__close"
          onClick={onClose}
          aria-label="Close session picker"
        >
          <X size={15} aria-hidden />
        </button>
        <div className="planner-session-picker__header">
          <h3>Attach an existing session</h3>
          <p>Pick one local session for this node. A node can have only one active session.</p>
        </div>
        <label className="planner-session-picker__search">
          <Search size={13} aria-hidden />
          <input
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder="Search title, plugin, project, status"
            autoFocus
          />
        </label>
        {sessions.length === 0 ? (
          <div className="planner-session-picker__empty">
            <Terminal size={16} aria-hidden />
            <span>No local sessions to attach.</span>
          </div>
        ) : visibleSessions.length === 0 ? (
          <div className="planner-session-picker__empty">
            <Search size={16} aria-hidden />
            <span>No matching sessions.</span>
          </div>
        ) : (
          <div className="planner-session-picker__list" role="listbox" aria-label="Local sessions">
            {visibleSessions.map((session) => (
              <button
                key={session.id}
                type="button"
                className="planner-session-picker__row"
                role="option"
                aria-selected={false}
                disabled={busy}
                onClick={() => onPick(session.id)}
              >
                <span
                  className="planner-session-picker__icon"
                  style={{ color: session.pluginColor || undefined }}
                >
                  {sessionIcon(session)}
                </span>
                <span className="planner-session-picker__main">
                  <strong>{session.title || shortId(session.id)}</strong>
                  <em>
                    {session.pluginDisplayName || session.pluginId}
                    {' · '}
                    {session.project || 'No project'}
                  </em>
                </span>
                <span className="planner-session-picker__status">{session.status}</span>
              </button>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}

function sessionIcon(session: Session) {
  if (session.status === 'permissionRequired' || session.status === 'waitingForUser') {
    return <AlertCircle size={14} aria-hidden />
  }
  if (session.status === 'completed' || session.status === 'done') {
    return <CheckCircle2 size={14} aria-hidden />
  }
  return <Clock3 size={14} aria-hidden />
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
  ]
  return values.some((value) => value?.toLowerCase().includes(query))
}
