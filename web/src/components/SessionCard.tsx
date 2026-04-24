import type { Session, TranscriptEntry } from '../types'
import { shortenProject } from '../scene'

interface SessionCardProps {
  session: Session
  selected: boolean
  onSelect: () => void
  /** Fires on double-click (jump to terminal). */
  onActivate: () => void
}

const ROLE_LABELS: Record<string, string> = {
  user: 'You',
  assistant: 'Claude',
  tool: 'Tool',
}

const ROLE_COLOR_CLASS: Record<string, string> = {
  user: 'session-card__msg--user',
  assistant: 'session-card__msg--assistant',
  tool: 'session-card__msg--tool',
}

// 后端 SessionStatus 枚举值：
//   idle, thinking, tooling, active, waitingForUser, permissionRequired,
//   compacting, completed, dead

/**
 * session usage 压成 `↑in ↓out` 一行。cost USD 从数据模型里移掉了
 * （Claude CLI 的 cost 估算经常不准），token 更诚实。
 */
function tokensText(u: import('../types').UsageStats | null): string {
  if (!u) return ''
  const up = u.inputTokens + u.cacheCreateTokens + u.cacheReadTokens
  const down = u.outputTokens
  if (up === 0 && down === 0) return ''
  const s = (n: number) => {
    if (n >= 1_000_000) return (n / 1_000_000).toFixed(n >= 10_000_000 ? 0 : 1) + 'M'
    if (n >= 1_000) return (n / 1_000).toFixed(n >= 10_000 ? 0 : 1) + 'k'
    return String(n)
  }
  return `↑${s(up)} ↓${s(down)}`
}

// If the backend prefixed a tool message with "🔧 <ToolName>:" strip it and
// surface the tool name separately. Returns [toolName, remainingText].
function parseToolEntry(text: string): { toolName: string | null; body: string } {
  // Match "🔧 ToolName: rest" or "ToolName: rest" at start.
  const emojiMatch = text.match(/^🔧\s*([A-Za-z_][\w-]*)\s*:\s*(.*)$/s)
  if (emojiMatch) {
    return { toolName: emojiMatch[1], body: emojiMatch[2].trim() || emojiMatch[1] }
  }
  return { toolName: null, body: text }
}

function MessageRow({ entry }: { entry: TranscriptEntry }) {
  const isTool = entry.role === 'tool'
  const parsed = isTool ? parseToolEntry(entry.text) : { toolName: null, body: entry.text }
  const roleLabel = isTool
    ? parsed.toolName ?? ROLE_LABELS.tool
    : ROLE_LABELS[entry.role] ?? entry.role
  const roleClass = ROLE_COLOR_CLASS[entry.role] ?? 'session-card__msg--other'

  return (
    <div className={`session-card__msg ${roleClass}`}>
      <div className="session-card__msg-label">{roleLabel}</div>
      <div className="session-card__msg-body">{parsed.body}</div>
    </div>
  )
}

export function SessionCard({
  session,
  selected,
  onSelect,
  onActivate,
}: SessionCardProps) {
  // waitingForUser 语义等同 idle，不算 urgent；只有真正的 permissionRequired
  // 或 inbox 里有待处理消息才算
  const urgent =
    session.inboxPending > 0 ||
    session.status === 'permissionRequired'

  // 新分类：是否 active（halo + 呼吸）/ waiting / completed / dead / idle。
  // 同时决定 halo 的颜色（live-color CSS 变量）。
  const liveKind = classifyLive(session.status, urgent)

  // [StateTrace] Web 端渲染日志
  console.log(
    '[StateTrace][web-card]',
    'sid=' + session.id.slice(0, 8),
    'status=' + session.status,
    'urgent=' + urgent,
    'badge=' + (liveKind.badge ?? '-'),
    'haloColor=' + (liveKind.haloColor ?? '-'),
    'dim=' + liveKind.dim
  )
  const tokens = tokensText(session.usageStats)
  const messages = session.recentMessages ?? []
  // 新设计更紧凑 → 多容一条消息
  const rows = messages.slice(-5)
  const sidShort = session.id.replace(/-/g, '').slice(0, 8)

  const footerStatus = session.currentTool
    ? `⚡ ${session.currentTool}`
    : session.status === 'active'
    ? '● active'
    : session.status === 'thinking'
    ? '✦ thinking'
    : session.status === 'tooling'
    ? '⚡ tooling'
    : session.status === 'compacting'
    ? '📦 compacting'
    : session.status === 'completed'
    ? '✓ completed'
    : session.status === 'idle'
    ? '○ idle'
    : session.status === 'waitingForUser'
    ? '○ idle'
    : session.status === 'permissionRequired'
    ? '🔒 permission'
    : session.status === 'dead'
    ? '✖ dead'
    : `● ${session.status}`

  const cardClass = [
    'session-card',
    selected ? 'session-card--selected' : '',
    liveKind.halo === 'active' ? 'session-card--active' : '',
    liveKind.dim ? 'session-card--dim' : '',
  ]
    .filter(Boolean)
    .join(' ')

  const inlineStyle = {
    '--card-accent': session.pluginColor,
    ...(liveKind.haloColor ? { '--live-color': liveKind.haloColor } : {}),
  } as React.CSSProperties

  return (
    <div
      className={cardClass}
      style={inlineStyle}
      onClick={(e) => {
        e.stopPropagation()
        console.log('[SessionCard] onClick → select', session.id.slice(0, 8), session.title)
        onSelect()
      }}
      onDoubleClick={(e) => {
        e.stopPropagation()
        console.log('[SessionCard] onDoubleClick → activate (jump terminal)', session.id.slice(0, 8), session.title)
        onActivate()
      }}
      title="Double-click to jump to terminal"
    >
      {/* active / waiting / dead 都有 LIVE badge（颜色跟着 halo）；
          idle / completed 没有，避免视觉噪音 */}
      {liveKind.badge && (
        <div className="session-card__live">{liveKind.badge}</div>
      )}

      <div className="session-card__header">
        <span className="session-card__title" title={session.title}>
          {session.title}
        </span>
        <span className="session-card__sep">·</span>
        <span className="session-card__plugin">{session.pluginDisplayName}</span>
        <span className="session-card__spacer" />
        {tokens && <span className="session-card__cost">{tokens}</span>}
      </div>

      <div className="session-card__subtitle" title={session.project}>
        {shortenProject(session.project)}
      </div>

      <div className="session-card__transcript">
        {rows.length === 0 ? (
          <div className="session-card__empty">No recent messages</div>
        ) : (
          rows.map((e, i) => <MessageRow key={i} entry={e} />)
        )}
      </div>

      <div className="session-card__footer">
        <span className="session-card__footer-status">{footerStatus}</span>
        {/* 后台子 agent / task：和主 status 正交，单独一个胶囊展示数量 + tooltip 列表。
            只在 ≥1 时出现，避免 idle 状态卡片被装饰塞满。 */}
        {session.backgroundAgents && session.backgroundAgents.length > 0 && (
          <span
            className="session-card__bg-agents"
            title={session.backgroundAgents
              .map((a) => `${bgKindGlyph(a.kind)} ${a.description ?? a.id}`)
              .join('\n')}
          >
            ⚙ {session.backgroundAgents.length} bg
          </span>
        )}
        {session.inboxPending > 0 && (
          <span className="session-card__pending">
            📨 {session.inboxPending}
          </span>
        )}
        <span className="session-card__sid">{sidShort}</span>
      </div>
    </div>
  )
}

/**
 * 把 resolved status 映射到视觉效果：
 *   - halo='active'：整卡发光呼吸（绿/黄/红任选色）
 *   - badge：右上角 LIVE 胶囊文字，null 时不显示
 *   - haloColor：halo 和 badge 的主色 CSS 变量值
 *   - dim：整卡降饱和（idle/completed 用）
 */
function bgKindGlyph(kind: string): string {
  if (kind === 'agent') return '🤖'
  if (kind === 'monitor') return '👁'
  if (kind === 'bash') return '$'
  return '⚙'
}

function classifyLive(status: string, urgent: boolean): {
  halo: 'active' | null
  badge: string | null
  haloColor: string | null
  dim: boolean
} {
  if (urgent) {
    return { halo: 'active', badge: 'ATTN', haloColor: '#EF4444', dim: false }
  }
  switch (status) {
    case 'active':
    case 'thinking':
    case 'tooling':
    case 'compacting':
      return { halo: 'active', badge: 'LIVE', haloColor: '#22C55E', dim: false }
    case 'permissionRequired':
      return { halo: 'active', badge: 'WAIT', haloColor: '#EAB308', dim: false }
    case 'dead':
      return { halo: null, badge: 'DEAD', haloColor: '#EF4444', dim: true }
    case 'completed':
      return { halo: null, badge: null, haloColor: null, dim: true }
    case 'idle':
    case 'waitingForUser':  // 语义等同 idle
    default:
      return { halo: null, badge: null, haloColor: null, dim: true }
  }
}
