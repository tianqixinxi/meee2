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

// Status → dot color class + whether it pulses.
interface StatusStyle {
  className: string
  pulse: boolean
}
function statusStyle(status: string, urgent: boolean): StatusStyle {
  if (urgent) {
    return { className: 'session-card__dot--urgent', pulse: true }
  }
  const map: Record<string, StatusStyle> = {
    running: { className: 'session-card__dot--running', pulse: false },
    active: { className: 'session-card__dot--running', pulse: false },
    thinking: { className: 'session-card__dot--thinking', pulse: false },
    tooling: { className: 'session-card__dot--tooling', pulse: false },
    waiting: { className: 'session-card__dot--urgent', pulse: true },
    waitingInput: { className: 'session-card__dot--urgent', pulse: true },
    waiting_input: { className: 'session-card__dot--urgent', pulse: true },
    permissionRequest: { className: 'session-card__dot--urgent', pulse: true },
    permission_request: { className: 'session-card__dot--urgent', pulse: true },
    completed: { className: 'session-card__dot--completed', pulse: false },
    compacting: { className: 'session-card__dot--thinking', pulse: false },
    idle: { className: 'session-card__dot--idle', pulse: false },
    failed: { className: 'session-card__dot--urgent', pulse: false },
    dead: { className: 'session-card__dot--urgent', pulse: false },
    unknown: { className: 'session-card__dot--idle', pulse: false },
  }
  return map[status] ?? { className: 'session-card__dot--idle', pulse: false }
}

// Status → top running-indicator-bar class. `null` → no bar rendered.
function statusBarClass(status: string): string | null {
  switch (status) {
    case 'active':
    case 'running':
    case 'thinking':
    case 'tooling':
    case 'compacting':
      return 'session-card__status-bar session-card__status-bar--active'
    case 'waiting':
    case 'waitingInput':
    case 'waiting_input':
    case 'permissionRequest':
    case 'permission_request':
      return 'session-card__status-bar session-card__status-bar--waiting'
    case 'completed':
      return 'session-card__status-bar session-card__status-bar--completed'
    case 'dead':
    case 'failed':
      return 'session-card__status-bar session-card__status-bar--dead'
    default:
      // idle / unknown → no bar
      return null
  }
}

function costText(cost: number | null): string {
  if (cost == null) return ''
  if (cost >= 1) return '$' + cost.toFixed(2)
  if (cost >= 0.01) return '$' + cost.toFixed(3)
  return '$' + cost.toFixed(4)
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
  const urgent =
    session.inboxPending > 0 ||
    session.status === 'permissionRequest' ||
    session.status === 'permission_request' ||
    session.status === 'waitingInput' ||
    session.status === 'waiting_input'

  // 新分类：是否 active（halo + 呼吸）/ waiting / completed / dead / idle。
  // 同时决定 halo 的颜色（live-color CSS 变量）。
  const liveKind = classifyLive(session.status, urgent)
  const cost = costText(session.costUSD)
  const messages = session.recentMessages ?? []
  // 新设计更紧凑 → 多容一条消息
  const rows = messages.slice(-5)
  const sidShort = session.id.replace(/-/g, '').slice(0, 8)

  const footerStatus = session.currentTool
    ? `⚡ ${session.currentTool}`
    : session.status === 'running' || session.status === 'active'
    ? '● running'
    : session.status === 'thinking'
    ? '✦ thinking'
    : session.status === 'tooling'
    ? '⚡ tooling'
    : session.status === 'completed'
    ? '✓ completed'
    : session.status === 'idle'
    ? '○ idle'
    : session.status === 'waiting'
    ? '⚠ waiting'
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
        {cost && <span className="session-card__cost">{cost}</span>}
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
    case 'running':
    case 'thinking':
    case 'tooling':
    case 'compacting':
      return { halo: 'active', badge: 'LIVE', haloColor: '#22C55E', dim: false }
    case 'waiting':
    case 'waitingInput':
    case 'waiting_input':
    case 'permissionRequest':
    case 'permission_request':
      return { halo: 'active', badge: 'WAIT', haloColor: '#EAB308', dim: false }
    case 'dead':
    case 'failed':
      return { halo: null, badge: 'DEAD', haloColor: '#EF4444', dim: true }
    case 'completed':
      return { halo: null, badge: null, haloColor: null, dim: true }
    case 'idle':
    case 'unknown':
    default:
      return { halo: null, badge: null, haloColor: null, dim: true }
  }
}
