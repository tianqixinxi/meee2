// Headless right-side detail panel — visual + layout from meee2's
// SessionDetail, abstracted via SessionForInspector and slot props so
// meee2 (or any consumer) can drop in custom buttons / blocks.
//
// Capability gating: any optional handler that's not provided just hides
// the corresponding button. e.g. meee2 only passes onOpenTerminal when
// the session belongs to the current user (and the user has meee2 running
// on this machine), otherwise the button is invisible.
//
// Style: imports SessionInspector.css. Apps must add this once at app
// boot:  import '@meee1/board-ui/SessionInspector.css'

import { useState, type ReactNode } from 'react'
import type {
  SessionForInspector,
  InboxItemForInspector,
  ChannelMembershipForInspector,
} from '@meee1/board-core'

export interface SessionInspectorProps {
  session: SessionForInspector

  // -- Capability slots: present = button shown; absent = button hidden ----

  /** Open the OS terminal for this session (meee2 jumps Ghostty). */
  onOpenTerminal?: () => Promise<void> | void
  /** Spawn a new agent session in the same cwd as this one. */
  onSpawnHere?: () => Promise<void> | void

  // -- Optional content slots ---------------------------------------------

  /** Pending inbox messages — when provided AND non-empty, the inbox chip
   *  reveals a popover with this list. */
  inboxItems?: InboxItemForInspector[]
  /** Channel memberships for the chip strip at the bottom. */
  memberships?: ChannelMembershipForInspector[]
  /** Render slot for the transcript area. Each app passes its own
   *  TranscriptPanel component (data sources differ — meee2 reads from
   *  Swift backend, meee2 reads from Supabase). */
  transcriptSlot: ReactNode
  /** Anything to render between live-strip and transcript — e.g.
   *  meee2's Archive / Move-to-team controls. */
  extraSections?: ReactNode
  /** Anything to render *after* the transcript section — e.g. meee2's
   *  Sync-history / Card-style controls that the user reaches less often. */
  extraSectionsAfterTranscript?: ReactNode

  // -- Status text mapper (lets apps customize labels per-locale) ---------

  /** Override status enum → display text. Default uses meee2's labels. */
  statusLabel?: (status: string) => string
  /** Override status enum → CSS modifier class (live/idle/perm/dead). */
  statusClassName?: (status: string) => string
}

export function SessionInspector({
  session,
  onOpenTerminal,
  onSpawnHere,
  inboxItems,
  memberships,
  transcriptSlot,
  extraSections,
  extraSectionsAfterTranscript,
  statusLabel = defaultStatusLabel,
  statusClassName = defaultStatusClass,
}: SessionInspectorProps) {
  const [opening, setOpening] = useState(false)
  const [spawning, setSpawning] = useState(false)

  const shortId = session.id.replace(/-/g, '').slice(0, 8)
  const tokenLabel = formatTokens(session.usageStats)
  const bgCount = session.backgroundAgents?.length ?? 0
  const inbox = inboxItems ?? []
  const memberRows = memberships ?? []

  // cwd basename optimization — same trick as meee2 SessionDetail
  const showTitleSeparately =
    !!session.title &&
    !!session.project &&
    !session.project.endsWith('/' + session.title) &&
    session.title !== session.project

  return (
    <div className="session-detail sd meee2-session-inspector">
      {/* ── 1. identity ── */}
      <div className="sd__sticky">
        <div className="sd__id-row">
          <span className="color-dot" style={{ background: session.pluginColor }} />
          <span className="sd__title" title={session.project}>
            {showTitleSeparately ? session.title : prettyCwd(session.project)}
          </span>
          <span className="sd__sid mono">{shortId}</span>
          {onOpenTerminal && (
            <button
              className="sd__open-btn"
              disabled={opening}
              title="Jump to this session's terminal"
              onClick={async () => {
                if (opening) return
                setOpening(true)
                try { await onOpenTerminal() } finally { setOpening(false) }
              }}
            >
              {opening ? 'Opening…' : 'Open terminal'}
            </button>
          )}
          {onSpawnHere && (
            <button
              className="sd__open-btn"
              disabled={spawning}
              title={`Spawn a new independent agent in ${session.project}`}
              onClick={async () => {
                if (spawning) return
                setSpawning(true)
                try { await onSpawnHere() } finally { setSpawning(false) }
              }}
            >
              {spawning ? 'Spawning…' : '+ Agent here'}
            </button>
          )}
        </div>
        {showTitleSeparately && (
          <div className="sd__cwd" title={session.project}>{session.project}</div>
        )}
      </div>

      {/* ── 2. live strip ── */}
      <div className="sd__live-strip">
        <span className={`sd__status sd__status--${statusClassName(session.status)}`}>
          {statusLabel(session.status)}
        </span>
        {session.currentTool && <span className="sd__chip">{session.currentTool}</span>}
        {tokenLabel && (
          <span className="sd__chip sd__chip--tokens sd__chip--popover">
            {tokenLabel.display}
            <span className="sd__chip-popover sd__chip-popover--tokens" role="tooltip">
              <span className="sd__chip-popover__title">Real tokens (this session)</span>
              <span className="sd__tokens-grid">
                <span className="sd__tokens-label">↑ Input</span>
                <span className="sd__tokens-value">{tokenLabel.stats.input.toLocaleString()}</span>
                <span className="sd__tokens-label">↓ Output</span>
                <span className="sd__tokens-value">{tokenLabel.stats.output.toLocaleString()}</span>
              </span>
              <span className="sd__chip-popover__title sd__chip-popover__title--sub">Cache</span>
              <span className="sd__tokens-grid">
                <span className="sd__tokens-label">+ Create</span>
                <span className="sd__tokens-value sd__tokens-value--cache">
                  {tokenLabel.stats.cacheCreate.toLocaleString()}
                </span>
                <span className="sd__tokens-label">⟲ Read</span>
                <span className="sd__tokens-value sd__tokens-value--cache">
                  {tokenLabel.stats.cacheRead.toLocaleString()}
                </span>
              </span>
              <span className="sd__tokens-footer">
                {tokenLabel.stats.turns.toLocaleString()} turns
                {tokenLabel.stats.model && <> · <span className="mono">{tokenLabel.stats.model}</span></>}
              </span>
            </span>
          </span>
        )}
        {bgCount > 0 && <span className="sd__chip sd__chip--bg">{bgCount} background</span>}
        {session.inboxPending > 0 && (
          <span className="sd__chip sd__chip--inbox sd__chip--popover">
            {session.inboxPending} inbox
            {inbox.length > 0 && (
              <span className="sd__chip-popover" role="tooltip">
                <span className="sd__chip-popover__title">Inbox ({inbox.length})</span>
                {inbox.map((msg) => (
                  <span key={msg.id} className="sd__chip-popover__row">
                    <span className="sd__chip-popover__meta">
                      <span className="mono">{msg.fromAlias}</span>
                      <span className="muted">{msg.channel}</span>
                      <span className="muted">
                        {new Date(msg.createdAt).toLocaleTimeString()}
                      </span>
                    </span>
                    <span className="sd__chip-popover__body">{msg.content}</span>
                  </span>
                ))}
              </span>
            )}
          </span>
        )}
      </div>

      {/* ── 3. recap ── */}
      {session.latestRecap && <Recap recap={session.latestRecap} />}

      {/* ── 3b. app-specific blocks (e.g. meee2 Archive / Move) ── */}
      {extraSections}

      {/* ── 4. transcript (main) ── */}
      <section className="sd__block">
        <div className="sd__block-head"><span>Transcript</span></div>
        {transcriptSlot}
      </section>

      {/* ── 4b. app-specific blocks placed under the transcript — meee2
              uses this for Sync history / Card style (less-frequent ops). ── */}
      {extraSectionsAfterTranscript}

      {/* ── 5. secondary: background / inbox / channels ── */}
      {bgCount > 0 && (
        <section className="sd__block">
          <div className="sd__block-head">
            <span>Background</span>
            <span className="sd__block-count">{bgCount}</span>
          </div>
          <ul className="sd__list">
            {session.backgroundAgents.map((a) => (
              <li key={a.id} className="sd__list-row">
                <span className="sd__bg-kind">{a.kind}</span>
                <span className="sd__list-main">
                  {a.description ?? <span className="muted mono">{a.id}</span>}
                </span>
                {a.startedAt && (
                  <span className="muted mono sd__list-age">
                    {describeAge(new Date(a.startedAt))}
                  </span>
                )}
              </li>
            ))}
          </ul>
        </section>
      )}

      {inbox.length > 0 && (
        <section className="sd__block">
          <div className="sd__block-head">
            <span>Inbox</span>
            <span className="sd__block-count">{inbox.length}</span>
          </div>
          {inbox.map((msg) => (
            <div key={msg.id} className="sd__inbox-row">
              <div className="sd__inbox-meta">
                <span className="mono">{msg.fromAlias} → {msg.toAlias}</span>
                <span className="muted">{msg.channel}</span>
                <span className="muted">{new Date(msg.createdAt).toLocaleTimeString()}</span>
              </div>
              <div className="sd__inbox-body">{msg.content}</div>
            </div>
          ))}
        </section>
      )}

      {memberRows.length > 0 && (
        <div className="sd__channels">
          <span className="muted">Channels</span>
          {memberRows.map((m) => (
            <span
              key={m.channel}
              className="sd__chip sd__chip--subtle"
              title={m.aliases.join(', ')}
            >
              {m.channel}
            </span>
          ))}
        </div>
      )}
    </div>
  )
}

// ─── helpers ────────────────────────────────────────────────────────────

interface TokenLabel {
  display: string
  stats: {
    input: number
    output: number
    cacheCreate: number
    cacheRead: number
    turns: number
    model: string
  }
}

function formatTokens(u: SessionForInspector['usageStats']): TokenLabel | null {
  if (!u) return null
  const up = u.inputTokens
  const down = u.outputTokens
  if (up === 0 && down === 0) return null
  return {
    display: `↑${shortNum(up)}  ↓${shortNum(down)}`,
    stats: {
      input: u.inputTokens,
      output: u.outputTokens,
      cacheCreate: u.cacheCreateTokens,
      cacheRead: u.cacheReadTokens,
      turns: u.turns,
      model: u.model || '',
    },
  }
}

function shortNum(n: number): string {
  if (n >= 1_000_000) return (n / 1_000_000).toFixed(n >= 10_000_000 ? 0 : 1) + 'M'
  if (n >= 1_000) return (n / 1_000).toFixed(n >= 10_000 ? 0 : 1) + 'k'
  return String(n)
}

function describeAge(at: Date): string {
  const sec = Math.max(0, (Date.now() - at.getTime()) / 1000)
  if (sec < 60) return `${Math.round(sec)}s`
  if (sec < 3600) return `${Math.round(sec / 60)}m`
  return `${Math.round(sec / 3600)}h`
}

function defaultStatusLabel(s: string): string {
  switch (s) {
    case 'idle': return 'idle'
    case 'waitingForUser': return 'idle'
    case 'thinking': return 'thinking'
    case 'tooling': return 'tooling'
    case 'active': return 'active'
    case 'permissionRequired': return 'permission'
    case 'compacting': return 'compacting'
    case 'completed': return 'completed'
    case 'dead': return 'dead'
    default: return s
  }
}

function defaultStatusClass(s: string): string {
  if (s === 'permissionRequired') return 'perm'
  if (s === 'dead') return 'dead'
  if (s === 'thinking' || s === 'tooling' || s === 'active' || s === 'compacting') return 'live'
  return 'idle'
}

function prettyCwd(path: string): string {
  const parts = path.split('/').filter(Boolean)
  if (parts.length <= 2) return path
  return parts.slice(-2).join('/')
}

function Recap({ recap }: { recap: NonNullable<SessionForInspector['latestRecap']> }) {
  const [open, setOpen] = useState(true)
  const age = recap.timestamp ? describeAge(new Date(recap.timestamp)) + ' ago' : null
  return (
    <section className="sd__block sd__block--recap">
      <div className="sd__block-head">
        <span>Recap</span>
        {age && <span className="muted mono sd__block-age">{age}</span>}
        <button className="sd__block-toggle" onClick={() => setOpen((v) => !v)}>
          {open ? '−' : '+'}
        </button>
      </div>
      {open && <div className="sd__recap-body">{recap.content}</div>}
    </section>
  )
}
