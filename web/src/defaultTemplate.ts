// Default card template. Ships as a source string that the sandboxed iframe
// compiles via Babel + evaluates. Users see this text in the TemplateEditor
// panel and can freely customize.
//
// IMPORTANT — this string is EVALUATED in a cross-origin iframe. It may not
// reference any project imports; it only has:
//   - `React` (UMD global)
//   - `ReactDOM` (UMD global)
//   - props: { session, board, helpers }
//
// The template below is a faithful port of the current <SessionCard/>
// component with all its helpers inlined.

export const DEFAULT_TEMPLATE = `// meee2 — default session card template.
// Receives props: { session, board, helpers }
// session:  { id, title, project, pluginId, pluginDisplayName, pluginColor,
//             status, inboxPending, recentMessages, currentTool, costUSD }
// board:    entire BoardState — { sessions, channels } if you need cross-card info.
// helpers:  { formatCost, timeAgo, truncate, roleColor, shortenProject, statusLabel }
//
// Export default a React function component.

const ROLE_LABELS = {
  user: 'You',
  assistant: 'Claude',
  tool: 'Tool',
}

function statusStyle(status, urgent) {
  if (urgent) return { color: '#EF4444', pulse: true }
  switch (status) {
    case 'running':
    case 'active':
      return { color: '#22C55E', pulse: false }
    case 'thinking':
    case 'compacting':
      return { color: '#60A5FA', pulse: false }
    case 'tooling':
      return { color: '#F59E0B', pulse: false }
    case 'waiting':
    case 'waitingInput':
    case 'waiting_input':
    case 'permissionRequest':
    case 'permission_request':
      return { color: '#EAB308', pulse: true }
    case 'completed':
      return { color: '#22C55E', pulse: false }
    case 'dead':
    case 'failed':
      return { color: '#EF4444', pulse: false }
    case 'idle':
    default:
      return { color: '#64748B', pulse: false }
  }
}

function statusBarColor(status, urgent) {
  if (urgent) return '#EF4444'
  switch (status) {
    case 'active':
    case 'running':
    case 'thinking':
    case 'tooling':
    case 'compacting':
      return '#22C55E'
    case 'waiting':
    case 'waitingInput':
    case 'waiting_input':
    case 'permissionRequest':
    case 'permission_request':
      return '#EAB308'
    case 'completed':
      return '#22C55E'
    case 'dead':
    case 'failed':
      return '#EF4444'
    default:
      return null
  }
}

function classifyLive(status, urgent) {
  if (urgent) return { halo: 'active', badge: 'ATTN', haloColor: '#EF4444', dim: false }
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

function costText(cost) {
  if (cost == null) return ''
  if (cost >= 1) return '$' + cost.toFixed(2)
  if (cost >= 0.01) return '$' + cost.toFixed(3)
  return '$' + cost.toFixed(4)
}

// 紧凑格式化 token 数（K / M）。使用箭头 ↑ 表示上行（input + cache create,
// 即发给模型的 token）、↓ 表示下行（output, 即模型生成的 token）。cache read
// 折算为 ~10% 成本的 input，这里显示成独立的 ⟲ 标记以便区分。
function fmtTokens(n) {
  if (n == null) return '—'
  if (n < 1000) return String(n)
  if (n < 1_000_000) return (n / 1000).toFixed(n < 10000 ? 1 : 0) + 'k'
  return (n / 1_000_000).toFixed(1) + 'M'
}

function tokenText(usage) {
  if (!usage) return ''
  // 上行 = input + cache_create（cache_read 有单独图标）
  const up = (usage.inputTokens || 0) + (usage.cacheCreateTokens || 0)
  const down = usage.outputTokens || 0
  if (up === 0 && down === 0) return ''
  return '↑' + fmtTokens(up) + ' ↓' + fmtTokens(down)
}

function parseToolEntry(text) {
  // Strip leading "🔧 ToolName:" so we can label tool rows nicely.
  const m = text.match(/^🔧\\s*([A-Za-z_][\\w-]*)\\s*:\\s*([\\s\\S]*)$/)
  if (m) return { toolName: m[1], body: m[2].trim() || m[1] }
  return { toolName: null, body: text }
}

function roleBadgeColor(role) {
  switch (role) {
    case 'user': return '#60A5FA'
    case 'assistant': return '#22C55E'
    case 'tool': return '#F59E0B'
    default: return '#94A3B8'
  }
}

function shortenProject(p) {
  if (!p) return ''
  let s = p
  if (s.startsWith('/Users/')) {
    const rest = s.slice('/Users/'.length)
    const i = rest.indexOf('/')
    s = '~' + (i >= 0 ? rest.slice(i) : '')
  }
  return s.length > 40 ? '…' + s.slice(-39) : s
}

function MessageRow({ entry }) {
  const isTool = entry.role === 'tool'
  const parsed = isTool ? parseToolEntry(entry.text) : { toolName: null, body: entry.text }
  const label = isTool
    ? (parsed.toolName || ROLE_LABELS.tool)
    : (ROLE_LABELS[entry.role] || entry.role)
  const color = roleBadgeColor(entry.role)

  return (
    <div style={{
      display: 'flex',
      gap: 6,
      marginBottom: 3,
      lineHeight: 1.35,
    }}>
      <div style={{
        flexShrink: 0,
        fontSize: 10,
        fontWeight: 600,
        color,
        textTransform: 'uppercase',
        letterSpacing: 0.4,
        minWidth: 52,
      }}>
        {label}
      </div>
      <div style={{
        color: '#cbd5e1',
        fontSize: 11,
        overflow: 'hidden',
        textOverflow: 'ellipsis',
        display: '-webkit-box',
        WebkitLineClamp: 2,
        WebkitBoxOrient: 'vertical',
        wordBreak: 'break-word',
      }}>
        {parsed.body}
      </div>
    </div>
  )
}

function SessionCard({ session, board, helpers }) {
  const urgent =
    session.inboxPending > 0 ||
    session.status === 'permissionRequest' ||
    session.status === 'permission_request' ||
    session.status === 'waitingInput' ||
    session.status === 'waiting_input'

  const live = classifyLive(session.status, urgent)
  const dot = statusStyle(session.status, urgent)
  const tokens = tokenText(session.usageStats)
  const messages = session.recentMessages || []
  const rows = messages.slice(-5)
  const sidShort = session.id.replace(/-/g, '').slice(0, 8)
  const bar = statusBarColor(session.status, urgent)

  const footerStatus = session.currentTool
    ? '⚡ ' + session.currentTool
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
    : '● ' + session.status

  const borderColor = live.haloColor || session.pluginColor || '#334155'
  const outerStyle = {
    position: 'relative',
    width: '100%',
    height: '100%',
    background: 'linear-gradient(180deg,#1b2030 0%,#141824 100%)',
    border: '1px solid ' + borderColor,
    borderRadius: 10,
    padding: '10px 12px 8px',
    display: 'flex',
    flexDirection: 'column',
    overflow: 'hidden',
    opacity: live.dim ? 0.7 : 1,
    boxShadow: live.halo === 'active' ? ('0 0 12px ' + live.haloColor + '55') : 'none',
    fontFamily: "-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif",
    color: '#e5e5e5',
  }

  return (
    <div style={outerStyle}>
      {bar && (
        <div style={{
          position: 'absolute',
          top: 0,
          left: 0,
          right: 0,
          height: 2,
          background: bar,
          opacity: dot.pulse ? 0.85 : 1,
        }} />
      )}

      {live.badge && (
        <div style={{
          position: 'absolute',
          top: 6,
          right: 8,
          fontSize: 9,
          fontWeight: 700,
          letterSpacing: 0.6,
          color: live.haloColor,
          background: 'rgba(0,0,0,0.35)',
          border: '1px solid ' + live.haloColor,
          padding: '1px 6px',
          borderRadius: 4,
        }}>
          {live.badge}
        </div>
      )}

      <div style={{
        display: 'flex',
        alignItems: 'center',
        gap: 6,
        marginBottom: 2,
        paddingRight: 44,
      }}>
        <span style={{
          width: 8,
          height: 8,
          borderRadius: '50%',
          background: dot.color,
          flexShrink: 0,
        }} />
        <span style={{
          fontWeight: 600,
          fontSize: 12,
          overflow: 'hidden',
          textOverflow: 'ellipsis',
          whiteSpace: 'nowrap',
          minWidth: 0,
          flex: 1,
        }} title={session.title}>
          {session.title}
        </span>
        <span style={{ color: '#64748b', fontSize: 10 }}>·</span>
        <span style={{
          fontSize: 10,
          color: session.pluginColor || '#94a3b8',
          fontWeight: 600,
          textTransform: 'uppercase',
          letterSpacing: 0.4,
          flexShrink: 0,
        }}>
          {session.pluginDisplayName}
        </span>
        {tokens && (
          <span style={{
            fontSize: 10,
            color: '#94a3b8',
            fontVariantNumeric: 'tabular-nums',
            fontFamily: "'SF Mono', Consolas, monospace",
            flexShrink: 0,
          }} title={session.usageStats
            ? 'input=' + (session.usageStats.inputTokens||0)
              + ' output=' + (session.usageStats.outputTokens||0)
              + ' cacheCreate=' + (session.usageStats.cacheCreateTokens||0)
              + ' cacheRead=' + (session.usageStats.cacheReadTokens||0)
              + ' turns=' + (session.usageStats.turns||0)
              + ' model=' + (session.usageStats.model||'?')
            : ''}>
            {tokens}
          </span>
        )}
      </div>

      <div style={{
        fontSize: 10,
        color: '#64748b',
        overflow: 'hidden',
        textOverflow: 'ellipsis',
        whiteSpace: 'nowrap',
        marginBottom: 6,
      }} title={session.project}>
        {shortenProject(session.project)}
      </div>

      <div style={{
        flex: 1,
        overflow: 'hidden',
        display: 'flex',
        flexDirection: 'column',
        gap: 1,
        fontSize: 11,
      }}>
        {rows.length === 0 ? (
          <div style={{ color: '#64748b', fontStyle: 'italic', fontSize: 11 }}>
            No recent messages
          </div>
        ) : (
          rows.map((entry, i) => <MessageRow key={i} entry={entry} />)
        )}
      </div>

      <div style={{
        display: 'flex',
        alignItems: 'center',
        gap: 8,
        marginTop: 6,
        paddingTop: 6,
        borderTop: '1px solid rgba(255,255,255,0.06)',
        fontSize: 10,
        color: '#94a3b8',
      }}>
        <span style={{ color: dot.color, fontWeight: 600 }}>{footerStatus}</span>
        {session.inboxPending > 0 && (
          <span style={{
            background: '#EF4444',
            color: '#fff',
            padding: '1px 6px',
            borderRadius: 8,
            fontSize: 9,
            fontWeight: 700,
          }}>
            📨 {session.inboxPending}
          </span>
        )}
        <span style={{ flex: 1 }} />
        <span style={{
          fontFamily: "'SF Mono', Consolas, monospace",
          fontSize: 9,
          color: '#475569',
        }}>
          {sidShort}
        </span>
      </div>
    </div>
  )
}

export default SessionCard
`
