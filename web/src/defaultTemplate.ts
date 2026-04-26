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
//             status, inboxPending, recentMessages, currentTool, usageStats }
// board:    entire BoardState — { sessions, channels } if you need cross-card info.
// helpers:  { formatCost, timeAgo, truncate, roleColor, shortenProject, statusLabel }
//
// Export default a React function component.

const ROLE_LABELS = {
  user: 'You',
  assistant: 'Claude',
  tool: 'Tool',
}

// 后端 SessionStatus 枚举值：
//   idle, thinking, tooling, active, waitingForUser, permissionRequired,
//   compacting, completed, dead
//
// Claude 视觉风：色板全部降饱和，暖色调主导，和 styles.css 的 tokens 对齐。
function statusStyle(status, urgent) {
  if (urgent) return { color: '#C26A6A', pulse: true }    // danger
  switch (status) {
    case 'active':
      return { color: '#7FA982', pulse: false }           // sage green
    case 'thinking':
    case 'compacting':
      return { color: '#8BA9C2', pulse: false }           // muted info blue
    case 'tooling':
      return { color: '#CC785C', pulse: false }           // Claude terracotta
    case 'permissionRequired':
      return { color: '#D4A373', pulse: true }            // sand amber
    // waitingForUser 等同 idle → 落到 default 分支
    case 'completed':
      return { color: '#7FA982', pulse: false }
    case 'dead':
      return { color: '#C26A6A', pulse: false }
    case 'idle':
    default:
      return { color: '#6B6862', pulse: false }           // text-faint
  }
}

function statusBarColor(status, urgent) {
  if (urgent) return '#C26A6A'
  switch (status) {
    case 'active':
    case 'thinking':
    case 'tooling':
    case 'compacting':
      return '#22C55E'                                     // LIVE 顶条与 halo 同色
    case 'permissionRequired':
      return '#D4A373'
    case 'completed':
      return '#7FA982'
    case 'dead':
      return '#C26A6A'
    default:
      return null
  }
}

function classifyLive(status, urgent) {
  if (urgent) return { halo: 'active', badge: 'ATTN', haloColor: '#C26A6A', dim: false }
  switch (status) {
    case 'active':
    case 'thinking':
    case 'tooling':
    case 'compacting':
      // LIVE 用饱和绿 —— 赤陶 accent 在画板一片暖褐里反而不够跳，需要跟主
      // 色形成对比才能"一眼看见 card 在跑"。
      return { halo: 'active', badge: 'LIVE', haloColor: '#22C55E', dim: false }
    case 'permissionRequired':
      return { halo: 'active', badge: 'WAIT', haloColor: '#D4A373', dim: false }
    case 'dead':
      return { halo: null, badge: 'DEAD', haloColor: '#C26A6A', dim: true }
    case 'completed':
      return { halo: null, badge: null, haloColor: null, dim: true }
    case 'idle':
    case 'waitingForUser':  // 语义等同 idle
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
  // 默认只显示"真正发送 / 真正生成"的 token：
  //   ↑ = 本轮新发给模型的 prompt tokens（不含从 cache 命中 + 不含 cache-create）
  //   ↓ = 模型生成的 output tokens
  // cache create / cache read 归到 hover tooltip 里，避免主视图被 cache 量
  // 放大得看起来很夸张（典型场景 cache 总量能到几 M，但本轮实际只算几 k）。
  const up = usage.inputTokens || 0
  const down = usage.outputTokens || 0
  if (up === 0 && down === 0) return ''
  return '↑' + fmtTokens(up) + ' ↓' + fmtTokens(down)
}

function tokenTooltip(usage) {
  if (!usage) return ''
  const input = usage.inputTokens || 0
  const output = usage.outputTokens || 0
  const cCreate = usage.cacheCreateTokens || 0
  const cRead = usage.cacheReadTokens || 0
  const turns = usage.turns || 0
  const model = usage.model || '—'
  // 用换行符连接，原生 title 在 Chrome/Safari/Firefox 里都会正确换行
  const lines = [
    'Real tokens (this turn)',
    '  ↑ Input:  ' + fmtTokens(input),
    '  ↓ Output: ' + fmtTokens(output),
    '',
    'Cache',
    '  + Create: ' + fmtTokens(cCreate),
    '  ⟲ Read:   ' + fmtTokens(cRead),
    '',
    'Turns: ' + turns + '  ·  Model: ' + model,
  ]
  return lines.join('\\n')
}

function parseToolEntry(text) {
  // Strip leading "🔧 ToolName:" so we can label tool rows nicely.
  const m = text.match(/^🔧\\s*([A-Za-z_][\\w-]*)\\s*:\\s*([\\s\\S]*)$/)
  if (m) return { toolName: m[1], body: m[2].trim() || m[1] }
  return { toolName: null, body: text }
}

function roleBadgeColor(role) {
  switch (role) {
    case 'user': return '#F0D5C7'       // 暖米（User 用偏亮的暖调）
    case 'assistant': return '#E6C9A8'   // 米驼（Claude 自己的色）
    case 'tool': return '#CC785C'        // 赤陶（tool = action = accent）
    default: return '#A8A59B'
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

function MessageRow({ entry, isLatest }) {
  const isTool = entry.role === 'tool'
  const parsed = isTool ? parseToolEntry(entry.text) : { toolName: null, body: entry.text }
  const label = isTool
    ? (parsed.toolName || ROLE_LABELS.tool)
    : (ROLE_LABELS[entry.role] || entry.role)
  const color = roleBadgeColor(entry.role)

  // 卡片总高 ~260px，留给 transcript 的空间约 175px。旧消息作为上下文
  // 压到单行 + ellipsis 省空间；最新一条 flex:1 占剩余，配合 overflow:hidden
  // 能完整显示 ~6 行，超出再 clip。
  const bodyStyle = isLatest
    ? {
        color: '#E8E5DC',
        fontSize: 11,
        whiteSpace: 'pre-wrap',
        wordBreak: 'break-word',
        overflow: 'hidden',
        flex: 1,
        minWidth: 0,
      }
    : {
        color: '#E8E5DC',
        fontSize: 11,
        overflow: 'hidden',
        textOverflow: 'ellipsis',
        whiteSpace: 'nowrap',
        flex: 1,
        minWidth: 0,
      }

  return (
    <div style={{
      display: 'flex',
      gap: 6,
      marginBottom: 3,
      lineHeight: 1.35,
      // 最新消息给 flex:1 去抢剩余空间，这样就算撑高也不会超出卡片
      flex: isLatest ? 1 : '0 0 auto',
      minHeight: 0,
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
      <div style={bodyStyle}>
        {parsed.body}
      </div>
    </div>
  )
}

// 卡片 body 在没有 recentMessages 时的占位。原版本只渲染斜体 "No recent
// messages"，body 整片留白——一张刚启动还没发过 prompt 的 session 卡看
// 上去就跟坏掉了一样。这里给三类有用信息：
//   1. latestRecap.content 如果有（任务完成时 Claude 自己生成的总结）
//   2. 否则展示 "Started <duration> ago" + 友好的 cta 文案
//   3. 实在没数据兜底回原文案
function EmptyState({ session }) {
  if (session.latestRecap && session.latestRecap.content) {
    return (
      <div style={{ color: '#A8A59B', fontSize: 11, lineHeight: 1.45 }}>
        <div style={{ color: '#7A7670', textTransform: 'uppercase', fontSize: 9, letterSpacing: 0.5, marginBottom: 3 }}>
          Recap
        </div>
        <div style={{ display: '-webkit-box', WebkitLineClamp: 5, WebkitBoxOrient: 'vertical', overflow: 'hidden' }}>
          {session.latestRecap.content}
        </div>
      </div>
    )
  }
  // duration 文本：从 startedAt 到现在多长
  let agoText = ''
  if (session.startedAt) {
    const elapsedMs = Date.now() - new Date(session.startedAt).getTime()
    const minutes = Math.floor(elapsedMs / 60000)
    if (minutes < 1) agoText = 'just now'
    else if (minutes < 60) agoText = minutes + 'm ago'
    else if (minutes < 60 * 24) agoText = Math.floor(minutes / 60) + 'h ago'
    else agoText = Math.floor(minutes / (60 * 24)) + 'd ago'
  }
  return (
    <div style={{ color: '#7A7670', fontSize: 11, lineHeight: 1.5 }}>
      <div style={{ fontStyle: 'italic', marginBottom: 4 }}>
        Session ready, no activity yet
      </div>
      {agoText && (
        <div style={{ color: '#5B5853', fontSize: 10 }}>
          Started {agoText}
        </div>
      )}
    </div>
  )
}

function SessionCard({ session, board, helpers }) {
  // 卡片的"需要注意"只看权限阻塞；inbox 的信号由 SessionOverlay 的
  // 小红点负责（见 App.tsx 的 unreadSids 检测 status 转换）。
  const urgent = session.status === 'permissionRequired'

  const live = classifyLive(session.status, urgent)
  const dot = statusStyle(session.status, urgent)
  const tokens = tokenText(session.usageStats)
  const messages = session.recentMessages || []
  const rows = messages.slice(-5)
  const sidShort = session.id.replace(/-/g, '').slice(0, 8)
  const bar = statusBarColor(session.status, urgent)

  const footerStatus = session.currentTool
    ? '⚡ ' + session.currentTool
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
    : '● ' + session.status

  // Claude 风：休息态用柔和暖褐边，活跃态才用 haloColor。
  const borderColor = live.haloColor || '#3A3A38'
  const outerStyle = {
    position: 'relative',
    width: '100%',
    height: '100%',
    // 暖褐"纸页"底色渐变 —— 上浅下深一点点，像一张被灯光斜照的信纸
    background: 'linear-gradient(180deg, #2E2D2B 0%, #262624 100%)',
    border: '1px solid ' + borderColor,
    borderRadius: 12,
    padding: '11px 14px 9px',
    display: 'flex',
    flexDirection: 'column',
    overflow: 'hidden',
    opacity: live.dim ? 0.78 : 1,
    boxShadow: live.halo === 'active'
      ? '0 0 14px ' + live.haloColor + '33, 0 1px 2px rgba(0,0,0,0.25)'
      : '0 1px 2px rgba(0,0,0,0.22)',
    fontFamily: "-apple-system, 'Inter', BlinkMacSystemFont, 'Segoe UI', sans-serif",
    color: '#F5F4EF',
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
        {/* session 标题 —— Claude 风：serif + 略大，像章节标题。 */}
        <span style={{
          fontFamily: "ui-serif, 'Iowan Old Style', 'Palatino', 'Charter', Georgia, serif",
          fontWeight: 500,
          fontSize: 14,
          letterSpacing: '-0.01em',
          overflow: 'hidden',
          textOverflow: 'ellipsis',
          whiteSpace: 'nowrap',
          minWidth: 0,
          flex: 1,
        }} title={session.title}>
          {session.title}
        </span>
        <span style={{ color: '#6B6862', fontSize: 10 }}>·</span>
        <span style={{
          fontSize: 9.5,
          color: '#A8A59B',
          fontWeight: 500,
          textTransform: 'uppercase',
          letterSpacing: 0.8,
          flexShrink: 0,
        }}>
          {session.pluginDisplayName}
        </span>
        {tokens && (() => {
          const u = session.usageStats || {}
          const hasCache = (u.cacheCreateTokens || 0) > 0 || (u.cacheReadTokens || 0) > 0
          return (
            <span style={{
              fontSize: 10,
              color: '#A8A59B',
              fontVariantNumeric: 'tabular-nums',
              fontFamily: "'SF Mono', Consolas, monospace",
              flexShrink: 0,
              cursor: hasCache ? 'help' : 'default',
            }} title={tokenTooltip(session.usageStats)}>
              {tokens}
              {hasCache && (
                <span style={{
                  marginLeft: 4,
                  opacity: 0.55,
                  fontSize: 9,
                }} aria-hidden>⟲</span>
              )}
            </span>
          )
        })()}
      </div>

      <div style={{
        fontSize: 10,
        color: '#7A7670',
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
          <EmptyState session={session} />
        ) : (
          rows.map((entry, i) => (
            <MessageRow key={i} entry={entry} isLatest={i === rows.length - 1} />
          ))
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
        color: '#A8A59B',
      }}>
        <span style={{ color: dot.color, fontWeight: 600 }}>{footerStatus}</span>
        {/* 后台子 agent / task 胶囊——和主 status 正交，主 idle 时也应该可见 */}
        {session.backgroundAgents && session.backgroundAgents.length > 0 && (
          <span
            title={session.backgroundAgents.map(a =>
              (a.kind === 'agent' ? '🤖 ' : a.kind === 'monitor' ? '👁 ' : '$ ') +
              (a.description || a.id)
            ).join(' · ')}
            style={{
              color: '#A78BFA',
              fontWeight: 600,
              padding: '1px 6px',
              borderRadius: 4,
              background: 'rgba(167,139,250,0.10)',
              border: '1px solid rgba(167,139,250,0.30)',
              fontSize: 9.5,
            }}
          >
            ⚙ {session.backgroundAgents.length} bg
          </span>
        )}
        <span style={{ flex: 1 }} />
        <span style={{
          fontFamily: "'SF Mono', Consolas, monospace",
          fontSize: 9,
          color: '#5B5853',
        }}>
          {sidShort}
        </span>
      </div>
    </div>
  )
}

export default SessionCard
`
