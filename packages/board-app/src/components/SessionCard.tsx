import type { Session, TranscriptEntry } from '../types'
import { shortenProject } from '@meee1/board-core'
// Lucide icons replace inline emoji glyphs in status / inbox / bg-agent
// chips. Keeping size: 11 to match the ~11px font cards use.
import {
  Zap,
  Package,
  Inbox,
  Lock,
  Settings as SettingsIcon,
  Wrench,
} from 'lucide-react'

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

  // [StateTrace] Web card render log. Enable temporarily when debugging card
  // state classification; too noisy for normal use.
  // console.log(
  //   '[StateTrace][web-card]',
  //   'sid=' + session.id.slice(0, 8),
  //   'status=' + session.status,
  //   'urgent=' + urgent,
  //   'badge=' + (liveKind.badge ?? '-'),
  //   'haloColor=' + (liveKind.haloColor ?? '-'),
  //   'dim=' + liveKind.dim
  // )
  const tokens = tokensText(session.usageStats)
  const messages = session.recentMessages ?? []
  // 卡片只展示 user input + assistant output 这两端的"对话"，过滤掉 tool
  // call 噪音（read/write/bash 这类中间步对快速浏览没价值，且经常把
  // 真正的回复挤到 5 条窗口外面看不到）。先过滤再 slice(-5)，确保任意
  // 时刻都尽量给满 5 条 user/assistant 消息。
  const rows = messages
    .filter((e) => e.role === 'user' || e.role === 'assistant')
    .slice(-5)
  const sidShort = session.id.replace(/-/g, '').slice(0, 8)

  // 状态行：图标走 lucide，文字保留原 label。原本用 emoji 前缀字符串，
  // 改成 React 节点（icon + text）。idle / completed / dead 这种纯几何
  // 字符（○ ✓ ✖ ●）保留——它们不是 emoji，单字符渲染稳定。
  const footerStatus: React.ReactNode = session.currentTool ? (
    <span className="session-card__status-line">
      <Zap size={11} aria-hidden /> {session.currentTool}
    </span>
  ) : session.status === 'active' ? (
    '● active'
  ) : session.status === 'thinking' ? (
    '✦ thinking'
  ) : session.status === 'tooling' ? (
    <span className="session-card__status-line">
      <Zap size={11} aria-hidden /> tooling
    </span>
  ) : session.status === 'compacting' ? (
    <span className="session-card__status-line">
      <Package size={11} aria-hidden /> compacting
    </span>
  ) : session.status === 'completed' ? (
    '✓ completed'
  ) : session.status === 'idle' ? (
    '○ idle'
  ) : session.status === 'waitingForUser' ? (
    '○ idle'
  ) : session.status === 'permissionRequired' ? (
    <span className="session-card__status-line">
      <Lock size={11} aria-hidden /> permission
    </span>
  ) : session.status === 'dead' ? (
    '✖ dead'
  ) : (
    `● ${session.status}`
  )

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
        // console.log('[SessionCard] onClick → select', session.id.slice(0, 8), session.title)
        onSelect()
      }}
      onDoubleClick={(e) => {
        e.stopPropagation()
        // console.log('[SessionCard] onDoubleClick → activate (jump terminal)', session.id.slice(0, 8), session.title)
        onActivate()
      }}
      title="Double-click to jump to terminal"
    >
      {/* active / waiting / dead 都有 LIVE badge（颜色跟着 halo）；
          idle / completed 没有，避免视觉噪音。
          LIVE 态特殊处理：换成三个 staggered bounce 小点（和 Sidebar
          的 status-dots-live 视觉同源）；其它 badge (ATTN/WAIT/DEAD)
          保留文字胶囊—— 它们的 label 携带语义，比纯动效更明确。 */}
      {liveKind.badge && (
        liveKind.badge === 'LIVE' ? (
          <div className="session-card__live session-card__live--dots" aria-label="live">
            <span className="status-dots-live" aria-hidden>
              <span /><span /><span />
            </span>
          </div>
        ) : (
          <div className="session-card__live">{liveKind.badge}</div>
        )
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
            <SettingsIcon size={10} aria-hidden /> {session.backgroundAgents.length} bg
          </span>
        )}
        {session.inboxPending > 0 && (
          <span className="session-card__pending">
            <Inbox size={11} aria-hidden /> {session.inboxPending}
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
