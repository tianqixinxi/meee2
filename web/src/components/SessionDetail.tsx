import { useEffect, useMemo, useState } from 'react'
import type { BoardState, Message, SessionRecap, UsageStats } from '../types'
import { listChannelMessages, activateSession, spawnSession } from '../api'
import { loadDefaultSpawnCommand } from '../preferences'
import { useToast } from '../App'
import TranscriptPanel from './TranscriptPanel'

interface Props {
  state: BoardState
  sessionId: string
}

/**
 * 右侧 session 详情面板。
 *
 * 布局分层：
 *   1. identity（永远不变）  : title + cwd + sid + open terminal
 *   2. live strip（变化快）  : status / tool / cost / background 计数
 *   3. recap（有就显示）     : Claude 的 away_summary
 *   4. transcript            : 消息列表（大块，切 session 时要有 loading）
 *   5. ops（次级：inbox + channels + background 列表）
 *
 * Transcript 组件强制 `key={sessionId}` 让它在切 session 时完整 remount——
 * 不然 useState 粘着上一条的 entries，用户会看到旧消息闪一下。
 */
export default function SessionDetail({ state, sessionId }: Props) {
  const toast = useToast()
  const session = state.sessions.find((s) => s.id === sessionId)
  const [inbox, setInbox] = useState<Array<{ ch: string; msg: Message }>>([])
  const [opening, setOpening] = useState(false)
  const [spawning, setSpawning] = useState(false)

  const memberships = useMemo(
    () =>
      state.channels
        .map((ch) => ({
          channel: ch.name,
          aliases: ch.members.filter((m) => m.sessionId === sessionId).map((m) => m.alias),
        }))
        .filter((m) => m.aliases.length > 0),
    [state.channels, sessionId],
  )

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

  const shortId = session.id.replace(/-/g, '').slice(0, 8)

  async function onOpenTerminal() {
    if (opening) return
    setOpening(true)
    try {
      const ok = await activateSession(session!.id)
      if (!ok) toast.push('error', 'Failed to open terminal')
    } finally {
      setOpening(false)
    }
  }

  /**
   * 在当前选中 session 的 cwd 下起一个新 Claude 会话——独立 sid、独立 PID、
   * 独立 Ghostty 窗口。不是 card 复制（card 只是同 session 的多个视图）。
   * 命令沿用 Preferences 里上次成功的 spawn command（默认 `claude`），用户
   * 想改可走 New Session dialog。
   */
  async function onSpawnHere() {
    if (spawning || !session) return
    setSpawning(true)
    try {
      const cmd = loadDefaultSpawnCommand() || 'claude'
      await spawnSession({ cwd: session.project, command: cmd, createIfMissing: false })
      toast.push('success', `Spawned new agent in ${prettyCwd(session.project)}`)
    } catch (e) {
      toast.push('error', `Spawn failed: ${(e as Error).message}`)
    } finally {
      setSpawning(false)
    }
  }

  const statusLabel = statusText(session.status)
  const tokenLabel = formatTokens(session.usageStats)
  const bgCount = session.backgroundAgents?.length ?? 0
  // cwd 和 title 经常是同一个 basename，避免两行重复；cwd 更长更信息化，title 只在两者不等时再出现
  const showTitleSeparately =
    session.title && session.project && !session.project.endsWith('/' + session.title) && session.title !== session.project

  return (
    <div className="session-detail sd">
      {/* ── 1. identity ── */}
      <div className="sd__sticky">
        <div className="sd__id-row">
          <span className="color-dot" style={{ background: session.pluginColor }} />
          <span className="sd__title" title={session.project}>
            {showTitleSeparately ? session.title : prettyCwd(session.project)}
          </span>
          <span className="sd__sid mono">{shortId}</span>
          <button
            className="sd__open-btn"
            onClick={onOpenTerminal}
            disabled={opening}
            title="Jump to this session's terminal"
          >
            {opening ? 'Opening…' : 'Open terminal'}
          </button>
          <button
            className="sd__open-btn"
            onClick={onSpawnHere}
            disabled={spawning}
            title={`Spawn a new independent Claude session in ${session.project}`}
          >
            {spawning ? 'Spawning…' : '+ Agent here'}
          </button>
        </div>
        {showTitleSeparately && (
          <div className="sd__cwd" title={session.project}>{session.project}</div>
        )}
      </div>

      {/* ── 2. live strip ── */}
      <div className="sd__live-strip">
        <span className={`sd__status sd__status--${statusClass(session.status)}`}>{statusLabel}</span>
        {session.currentTool && <span className="sd__chip">{session.currentTool}</span>}
        {tokenLabel && (
          <span className="sd__chip sd__chip--tokens sd__chip--popover">
            {tokenLabel.display}
            <span className="sd__chip-popover sd__chip-popover--tokens" role="tooltip">
              <span className="sd__chip-popover__title">
                Real tokens (this session)
              </span>
              <span className="sd__tokens-grid">
                <span className="sd__tokens-label">↑ Input</span>
                <span className="sd__tokens-value">{tokenLabel.stats.input.toLocaleString()}</span>
                <span className="sd__tokens-label">↓ Output</span>
                <span className="sd__tokens-value">{tokenLabel.stats.output.toLocaleString()}</span>
              </span>
              <span className="sd__chip-popover__title sd__chip-popover__title--sub">
                Cache
              </span>
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
                <span className="sd__chip-popover__title">
                  Inbox ({inbox.length})
                </span>
                {inbox.map(({ ch, msg }) => (
                  <span key={msg.id} className="sd__chip-popover__row">
                    <span className="sd__chip-popover__meta">
                      <span className="mono">{msg.fromAlias}</span>
                      <span className="muted">{ch}</span>
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

      {/* ── 4. transcript (main) ── */}
      <section className="sd__block">
        <div className="sd__block-head">
          <span>Transcript</span>
        </div>
        {/* key 强制 remount，避免跨 session 串状态 */}
        <TranscriptPanel
          key={session.id}
          sessionId={session.id}
          limit={200}
          refreshTrigger={state}
        />
      </section>

      {/* ── 5. secondary: background / inbox / channels ── */}
      {bgCount > 0 && (
        <section className="sd__block">
          <div className="sd__block-head">
            <span>Background</span>
            <span className="sd__block-count">{bgCount}</span>
          </div>
          <ul className="sd__list">
            {session.backgroundAgents!.map((a) => (
              <li key={a.id} className="sd__list-row">
                <span className="sd__bg-kind">{a.kind}</span>
                <span className="sd__list-main">
                  {a.description ?? <span className="muted mono">{a.id}</span>}
                </span>
                {a.startedAt && (
                  <span className="muted mono sd__list-age">{describeAge(new Date(a.startedAt))}</span>
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
          {inbox.map(({ ch, msg }) => (
            <div key={msg.id} className="sd__inbox-row">
              <div className="sd__inbox-meta">
                <span className="mono">{msg.fromAlias} → {msg.toAlias}</span>
                <span className="muted">{ch}</span>
                <span className="muted">{new Date(msg.createdAt).toLocaleTimeString()}</span>
              </div>
              <div className="sd__inbox-body">{msg.content}</div>
            </div>
          ))}
        </section>
      )}

      {memberships.length > 0 && (
        <div className="sd__channels">
          <span className="muted">Channels</span>
          {memberships.map((m) => (
            <span key={m.channel} className="sd__chip sd__chip--subtle" title={m.aliases.join(', ')}>
              {m.channel}
            </span>
          ))}
        </div>
      )}
    </div>
  )
}

// ─── helpers ──────────────────────────────────────────────────────────────

/**
 * 把 usageStats 压成一个紧凑 chip 文本 + tooltip。
 *
 * 默认展示**真正发生的 token**：
 *   ↑ = inputTokens（本 session 累计的新 prompt tokens，不含 cache create / read）
 *   ↓ = outputTokens（模型生成的 token）
 *
 * 把 cacheCreate / cacheRead 合进 ↑ 会严重放大数字 —— typical long session
 * 里 cacheRead 常达亿级，但它只是重复读同一份 prompt 的成本折扣，不反映
 * "这个 session 做了多少事"。cache 信息挪到 hover tooltip 里给需要的人查。
 */
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

function formatTokens(u: UsageStats | null): TokenLabel | null {
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

function statusText(s: string): string {
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

function statusClass(s: string): string {
  if (s === 'permissionRequired') return 'perm'
  if (s === 'dead') return 'dead'
  if (s === 'thinking' || s === 'tooling' || s === 'active' || s === 'compacting') return 'live'
  return 'idle'
}

function prettyCwd(path: string): string {
  // 主标题只显示最后两段（/Users/qc/projects/meee1_code/meee1 → meee1_code/meee1）——
  // 完整路径下方单独展示，第一屏省空间
  const parts = path.split('/').filter(Boolean)
  if (parts.length <= 2) return path
  return parts.slice(-2).join('/')
}

// ─── recap ────────────────────────────────────────────────────────────────

function Recap({ recap }: { recap: SessionRecap }) {
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
