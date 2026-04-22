import { useEffect, useState } from 'react'
import type { BoardState, Message, TranscriptEntry } from '../types'
import { listChannelMessages, activateSession } from '../api'
import { useToast } from '../App'

const ROLE_PREFIX: Record<string, string> = {
  user: '▶',
  assistant: '◀',
  tool: '⚡',
}
const ROLE_COLOR: Record<string, string> = {
  user: '#7DD3FC',
  assistant: '#E5E5E5',
  tool: '#C084FC',
}

function TranscriptPreview({ entries }: { entries: TranscriptEntry[] }) {
  if (entries.length === 0) {
    return <div className="muted">No recent messages.</div>
  }
  return (
    <div className="col" style={{ gap: 6 }}>
      {entries.map((e, i) => {
        const prefix = ROLE_PREFIX[e.role] ?? '·'
        const color = ROLE_COLOR[e.role] ?? '#BBBBBB'
        return (
          <div
            key={i}
            className="mono"
            style={{
              fontSize: 12,
              color,
              whiteSpace: 'pre-wrap',
              wordBreak: 'break-word',
              lineHeight: 1.45,
            }}
          >
            <span style={{ opacity: 0.85, marginRight: 6 }}>{prefix}</span>
            {e.text}
          </div>
        )
      })}
    </div>
  )
}

interface Props {
  state: BoardState
  sessionId: string
}

export default function SessionDetail({ state, sessionId }: Props) {
  const toast = useToast()
  const session = state.sessions.find((s) => s.id === sessionId)
  const [inbox, setInbox] = useState<Array<{ ch: string; msg: Message }>>([])

  // Membership across channels → used to fetch inbox for the alias list.
  const memberships = state.channels
    .map((ch) => ({
      channel: ch.name,
      aliases: ch.members
        .filter((m) => m.sessionId === sessionId)
        .map((m) => m.alias),
    }))
    .filter((m) => m.aliases.length > 0)

  useEffect(() => {
    let cancelled = false
    async function load() {
      if (!session) return
      const out: Array<{ ch: string; msg: Message }> = []
      for (const m of memberships) {
        try {
          const msgs = await listChannelMessages(m.channel, {
            statuses: ['pending', 'held'],
            limit: 20,
          })
          for (const msg of msgs) {
            if (msg.fromAlias && m.aliases.includes(msg.fromAlias)) continue
            if (msg.toAlias === '*' || m.aliases.includes(msg.toAlias)) {
              out.push({ ch: m.channel, msg })
            }
          }
        } catch (e) {
          toast.push('error', (e as Error).message)
        }
      }
      if (!cancelled) setInbox(out)
    }
    void load()
    return () => {
      cancelled = true
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionId, state])

  if (!session) {
    return <div className="muted">Session no longer exists.</div>
  }

  const shortId = session.id.slice(0, 8)

  return (
    <div className="col" style={{ gap: 12 }}>
      <div>
        <div
          className="row"
          style={{ fontSize: 15, fontWeight: 600, marginBottom: 4 }}
        >
          <span className="color-dot" style={{ background: session.pluginColor }} />
          <span>{session.title}</span>
        </div>
        <div className="muted mono" style={{ marginBottom: 2 }}>
          {session.pluginDisplayName} · <code>{shortId}</code>
        </div>
        <div className="muted" style={{ wordBreak: 'break-all' }}>
          {session.project}
        </div>
      </div>

      <div className="row" style={{ gap: 6 }}>
        <span className="muted">Status:</span>
        <span className="badge">{session.status}</span>
        {session.currentTool && (
          <span className="badge">⚡ {session.currentTool}</span>
        )}
        {session.costUSD != null && (
          <span className="badge" style={{ color: '#22C55E' }}>
            ${session.costUSD.toFixed(session.costUSD >= 1 ? 2 : 4)}
          </span>
        )}
      </div>

      <div className="section">
        <h4>
          Recent messages{' '}
          <span className="muted" style={{ fontWeight: 400 }}>
            (latest 5)
          </span>
        </h4>
        <TranscriptPreview entries={session.recentMessages ?? []} />
      </div>

      <div className="section">
        <h4>
          Inbox{' '}
          {session.inboxPending > 0 && (
            <span className="badge warn">📨 {session.inboxPending}</span>
          )}
        </h4>
        {inbox.length === 0 && <div className="muted">No pending messages.</div>}
        {inbox.map(({ ch, msg }) => (
          <div key={msg.id} className="message-row">
            <div className="meta">
              <span>
                {msg.fromAlias} → {msg.toAlias}
              </span>
              <span>{ch}</span>
            </div>
            <div className="content">{msg.content}</div>
            <div className="meta">
              <span className="badge warn">{msg.status}</span>
              <span>{new Date(msg.createdAt).toLocaleTimeString()}</span>
            </div>
          </div>
        ))}
      </div>

      <div className="section">
        <h4>Memberships</h4>
        {memberships.length === 0 && (
          <div className="muted">Not in any channel.</div>
        )}
        {memberships.map((m) => (
          <div key={m.channel} className="row space" style={{ marginBottom: 3 }}>
            <span>{m.channel}</span>
            <span className="mono muted">{m.aliases.join(', ')}</span>
          </div>
        ))}
      </div>

      <div>
        <button
          onClick={async () => {
            console.group('🪟 [Open terminal] ' + session.id.slice(0, 8) + ' · ' + session.title)
            console.log('session data from state:', {
              id: session.id,
              title: session.title,
              pluginId: session.pluginId,
              project: session.project,
              ghosttyTerminalId: (session as any).ghosttyTerminalId,
              tty: (session as any).tty,
              termProgram: (session as any).termProgram,
              status: session.status,
            })
            const t0 = performance.now()
            const ok = await activateSession(session.id)
            const dt = (performance.now() - t0).toFixed(0)
            console.log(`→ activateSession returned ok=${ok} in ${dt}ms`)
            console.log(
              '💡 backend flow is logged to /tmp/meee2-gui.log:\n' +
              '    grep -E "TerminalManager|TerminalJumper|activateTerminal" /tmp/meee2-gui.log | tail -20',
            )
            console.groupEnd()
            if (!ok) toast.push('error', 'Failed to open terminal')
          }}
        >
          Open terminal
        </button>
      </div>
    </div>
  )
}
