// Card-template presets. Users can click one in TemplateEditor to load its
// source into the textarea; they can then tweak & save.
//
// Keep each preset self-contained (no imports, all helpers inlined) since the
// runtime `new Function()` compiles them standalone — same constraints as
// defaultTemplate.ts.

import { DEFAULT_TEMPLATE } from './defaultTemplate'

export interface TemplatePreset {
  id: string
  label: string
  description: string
  source: string
}

// ── Preset: Minimal — "giant LED"，一个超大彩色圆 + 下方标题 ───────────
// 视觉签名：占满卡片的大号圆形状态灯。缩略图里一眼就是 "圆"。
const MINIMAL = `
export default function MinimalCard({ session }) {
  const isLive = session.status === 'active' || session.status === 'thinking' || session.status === 'tooling' || session.status === 'compacting'
  const urgent = session.status === 'permissionRequired'
  const color =
    urgent ? '#D4A373'
      : isLive ? '#22C55E'
      : session.status === 'dead' ? '#C26A6A'
      : '#5B5853'
  return (
    <div style={{
      width: '100%', height: '100%',
      background: '#262624',
      border: '1px solid ' + (isLive ? color : '#3A3A38'),
      borderRadius: 12,
      padding: 16,
      display: 'flex', flexDirection: 'column',
      alignItems: 'center', justifyContent: 'center',
      gap: 14,
      color: '#F5F4EF',
      fontFamily: '-apple-system, Inter, sans-serif',
    }}>
      {/* 占中间的大圆 —— 60px 直径，有脉冲光晕（活跃态才亮） */}
      <div style={{
        width: 72, height: 72, borderRadius: '50%',
        background: color,
        boxShadow: isLive
          ? '0 0 32px ' + color + '66, 0 0 0 4px ' + color + '22'
          : 'none',
        opacity: isLive ? 1 : 0.55,
        transition: 'opacity 0.2s ease',
      }} />
      {/* 标题：居中，serif 强调 */}
      <div style={{
        fontFamily: "ui-serif, 'Iowan Old Style', Palatino, Georgia, serif",
        fontSize: 16, fontWeight: 500, letterSpacing: -0.01,
        textAlign: 'center', maxWidth: '100%',
        overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
      }}>
        {session.title}
      </div>
      <div style={{
        fontSize: 9, color: '#A8A59B', textTransform: 'uppercase', letterSpacing: 1,
      }}>
        {urgent ? 'permission' : isLive ? 'live' : session.status || 'idle'}
      </div>
    </div>
  )
}
`.trim()

// ── Preset: Stats — token usage + turns + model ──────────────────────
const STATS = `
function fmt(n) {
  if (n == null) return '—'
  if (n < 1000) return String(n)
  if (n < 1_000_000) return (n / 1000).toFixed(1) + 'k'
  return (n / 1_000_000).toFixed(1) + 'M'
}

export default function StatsCard({ session }) {
  const u = session.usageStats || {}
  const input = (u.inputTokens || 0) + (u.cacheCreateTokens || 0)
  const output = u.outputTokens || 0
  const cached = u.cacheReadTokens || 0
  return (
    <div style={{
      width: '100%', height: '100%',
      background: 'linear-gradient(135deg, #1a2130 0%, #0f1218 100%)',
      border: '1px solid #2a3040',
      borderRadius: 12,
      padding: 14,
      color: '#e5e5e5',
      fontFamily: '-apple-system, sans-serif',
      display: 'flex', flexDirection: 'column',
    }}>
      <div style={{ fontSize: 14, fontWeight: 600, marginBottom: 2 }}>{session.title}</div>
      <div style={{ fontSize: 10, color: '#64748b', marginBottom: 12 }}>
        {session.pluginDisplayName} · {u.model || '—'}
      </div>
      <div style={{
        display: 'grid',
        gridTemplateColumns: '1fr 1fr',
        gap: 8,
        flex: 1,
        fontFamily: "'SF Mono', monospace",
      }}>
        <Stat label="Input ↑" value={fmt(input)} color="#60A5FA" />
        <Stat label="Output ↓" value={fmt(output)} color="#22C55E" />
        <Stat label="Cache ⟲" value={fmt(cached)} color="#A78BFA" />
        <Stat label="Turns" value={u.turns || 0} color="#F59E0B" />
      </div>
    </div>
  )
}

function Stat({ label, value, color }) {
  return (
    <div style={{
      background: 'rgba(255,255,255,0.03)',
      borderRadius: 8,
      padding: '8px 10px',
    }}>
      <div style={{ fontSize: 9, color: '#64748b', letterSpacing: 0.6, textTransform: 'uppercase' }}>
        {label}
      </div>
      <div style={{ fontSize: 18, fontWeight: 600, color: color, marginTop: 2 }}>
        {value}
      </div>
    </div>
  )
}
`.trim()

// ── Preset: Chat — transcript-focused, big messages ─────────────────
const CHAT = `
export default function ChatCard({ session }) {
  const msgs = (session.recentMessages || []).slice(-6)
  return (
    <div style={{
      width: '100%', height: '100%',
      background: '#0f1218',
      border: '1px solid ' + (session.pluginColor || '#334155'),
      borderRadius: 10,
      padding: 10,
      color: '#e5e5e5',
      fontFamily: '-apple-system, sans-serif',
      display: 'flex', flexDirection: 'column',
      overflow: 'hidden',
    }}>
      <div style={{ fontSize: 11, color: '#94a3b8', marginBottom: 8, flexShrink: 0 }}>
        {session.title}
      </div>
      <div style={{ flex: 1, overflow: 'hidden', display: 'flex', flexDirection: 'column', gap: 6 }}>
        {msgs.length === 0 && (
          <div style={{ color: '#64748b', fontSize: 11, fontStyle: 'italic' }}>
            (empty)
          </div>
        )}
        {msgs.map((m, i) => {
          const isUser = m.role === 'user'
          const isTool = m.role === 'tool'
          const bg = isUser ? '#1e3a5f' : isTool ? '#1a1a1a' : '#1a2a1f'
          const align = isUser ? 'flex-end' : 'flex-start'
          return (
            <div key={i} style={{
              alignSelf: align,
              maxWidth: '85%',
              background: bg,
              padding: '6px 10px',
              borderRadius: 10,
              fontSize: 11,
              lineHeight: 1.4,
              wordBreak: 'break-word',
              display: '-webkit-box',
              WebkitLineClamp: 3,
              WebkitBoxOrient: 'vertical',
              overflow: 'hidden',
            }}>
              {m.text}
            </div>
          )
        })}
      </div>
    </div>
  )
}
`.trim()

// ── Preset: Compact — "task row"，三分层 grid，数据密度高 ────────────
// 视觉签名：上下两条横线分层（header / body / footer），每层 info dense；
// 整张卡是一个小型 dashboard row，不是一条单线。
const COMPACT = `
export default function CompactCard({ session }) {
  const u = session.usageStats || {}
  const isLive = session.status === 'active' || session.status === 'thinking' || session.status === 'tooling' || session.status === 'compacting'
  const urgent = session.status === 'permissionRequired'
  const accent = urgent ? '#D4A373' : isLive ? '#22C55E' : '#5B5853'
  const msgs = (session.recentMessages || []).slice(-1)[0]
  return (
    <div style={{
      width: '100%', height: '100%',
      background: '#262624',
      border: '1px solid ' + (isLive ? accent : '#3A3A38'),
      borderRadius: 10,
      display: 'flex', flexDirection: 'column',
      color: '#F5F4EF',
      fontFamily: '-apple-system, Inter, sans-serif',
      overflow: 'hidden',
      boxShadow: isLive ? '0 0 16px ' + accent + '22' : 'none',
    }}>
      {/* 顶栏：colored bar + title + sid */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: 8,
        padding: '8px 12px',
        background: 'rgba(255,255,255,0.02)',
        borderBottom: '1px solid #3A3A38',
      }}>
        <div style={{
          width: 3, height: 14, borderRadius: 2, background: accent, flexShrink: 0,
        }} />
        <span style={{
          fontSize: 13, fontWeight: 600, flex: 1,
          overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
        }}>{session.title}</span>
        <span style={{
          fontSize: 9, color: accent, fontWeight: 600, letterSpacing: 0.6,
          textTransform: 'uppercase', flexShrink: 0,
        }}>
          {urgent ? 'wait' : isLive ? 'live' : 'idle'}
        </span>
      </div>
      {/* 主体：最近一条消息缩略（tool / user / assistant 三色 chip） */}
      <div style={{
        flex: 1,
        padding: '6px 12px',
        display: 'flex', alignItems: 'center', gap: 8,
        fontSize: 11, color: '#A8A59B',
        overflow: 'hidden',
      }}>
        {msgs ? (
          <>
            <span style={{
              fontSize: 9, fontWeight: 600, letterSpacing: 0.4,
              textTransform: 'uppercase', flexShrink: 0,
              color: msgs.role === 'user' ? '#F0D5C7'
                   : msgs.role === 'assistant' ? '#E6C9A8'
                   : '#CC785C',
            }}>{msgs.role === 'user' ? 'you' : msgs.role === 'assistant' ? 'claude' : 'tool'}</span>
            <span style={{
              flex: 1, minWidth: 0,
              overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
              color: '#E8E5DC',
            }}>{msgs.text}</span>
          </>
        ) : (
          <span style={{ fontStyle: 'italic' }}>No messages</span>
        )}
      </div>
      {/* 底栏：数据条 —— tool · turns · cost */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: 10,
        padding: '6px 12px',
        background: 'rgba(255,255,255,0.02)',
        borderTop: '1px solid #3A3A38',
        fontSize: 10, color: '#7A7670',
        fontFamily: "'SF Mono', monospace",
      }}>
        <span style={{ color: session.currentTool ? accent : '#7A7670' }}>
          ⚡ {session.currentTool || '—'}
        </span>
        <span style={{ opacity: 0.5 }}>·</span>
        <span>{u.turns || 0}t</span>
        <span style={{ opacity: 0.5 }}>·</span>
        <span>{'$' + (session.costUSD || 0).toFixed(session.costUSD >= 1 ? 2 : 3)}</span>
        <span style={{ flex: 1 }} />
      </div>
    </div>
  )
}
`.trim()

// ── Preset: Focus — Linear-style，serif 主标题 + 极简数据行 ─────────────
// 参考 Linear 的 issue card：大量留白、一个主色、活跃时才上饱和色。
// 目标读者："我就想快速扫一眼谁在干活"。
// ── Preset: Focus — "Hero metric"，一个巨大的数字主角 ───────────────
// 视觉签名：card 左侧一个超大的 cost 数字（32-44px），右侧细节。
// 灵感：Apple Numbers / Notion KPI widget。专治"打开画板第一眼要知道多贵"。
const FOCUS = `
function isLive(s) {
  return s === 'active' || s === 'thinking' || s === 'tooling' || s === 'compacting'
}
function fmtCost(c) {
  if (c == null) return '$0'
  if (c >= 100) return '$' + Math.round(c)
  if (c >= 10) return '$' + c.toFixed(1)
  if (c >= 1) return '$' + c.toFixed(2)
  return '$' + c.toFixed(3)
}

export default function FocusCard({ session }) {
  const live = isLive(session.status)
  const urgent = session.status === 'permissionRequired'
  const accent = urgent ? '#C26A6A' : live ? '#22C55E' : '#5B5853'
  const u = session.usageStats || {}

  return (
    <div style={{
      width: '100%', height: '100%',
      background: '#262624',
      border: '1px solid ' + (live ? accent : '#3A3A38'),
      borderRadius: 12,
      padding: 16,
      display: 'grid',
      gridTemplateColumns: '1fr 1fr',
      gridTemplateRows: 'auto 1fr auto',
      gap: 10,
      color: '#F5F4EF',
      fontFamily: '-apple-system, Inter, sans-serif',
      boxShadow: live ? '0 0 20px ' + accent + '22' : 'none',
    }}>
      {/* title 跨两栏，serif 小号 */}
      <div style={{
        gridColumn: '1 / -1',
        fontFamily: "ui-serif, 'Iowan Old Style', Palatino, Georgia, serif",
        fontSize: 13, fontWeight: 500, color: '#A8A59B',
        overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
      }}>
        {session.title}
      </div>

      {/* 左侧：Hero 数字 —— cost */}
      <div style={{
        gridRow: '2',
        display: 'flex', flexDirection: 'column', justifyContent: 'center',
      }}>
        <div style={{
          fontFamily: "ui-serif, 'Iowan Old Style', Palatino, Georgia, serif",
          fontSize: 40, fontWeight: 400, lineHeight: 1,
          color: live ? accent : '#E8E5DC',
          letterSpacing: -0.02,
          fontVariantNumeric: 'tabular-nums',
        }}>
          {fmtCost(session.costUSD)}
        </div>
        <div style={{ fontSize: 9, color: '#7A7670', textTransform: 'uppercase', letterSpacing: 1, marginTop: 4 }}>
          spent
        </div>
      </div>

      {/* 右侧：副指标纵列 */}
      <div style={{
        gridRow: '2',
        display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 6,
        alignItems: 'flex-end',
      }}>
        <SubMetric label="turns" value={String(u.turns || 0)} />
        <SubMetric label="output" value={fmtK(u.outputTokens || 0)} />
        <SubMetric label="tool" value={session.currentTool || '—'} accent={live ? accent : undefined} />
      </div>

      {/* footer：status pill 横跨两栏 */}
      <div style={{ gridColumn: '1 / -1' }}>
        <div style={{
          display: 'inline-flex', alignItems: 'center', gap: 5,
          fontSize: 10, fontWeight: 600, letterSpacing: 0.5,
          color: accent,
          border: '1px solid ' + accent,
          background: (live || urgent) ? accent + '14' : 'transparent',
          padding: '3px 9px',
          borderRadius: 999,
        }}>
          <span style={{
            width: 6, height: 6, borderRadius: 3, background: accent,
          }} />
          {urgent ? 'NEEDS INPUT' : live ? (session.status || 'LIVE').toUpperCase() : 'IDLE'}
        </div>
      </div>
    </div>
  )
}

function fmtK(n) {
  if (n < 1000) return String(n)
  if (n < 1_000_000) return (n / 1000).toFixed(n < 10000 ? 1 : 0) + 'k'
  return (n / 1_000_000).toFixed(1) + 'M'
}

function SubMetric({ label, value, accent }) {
  return (
    <div style={{ display: 'flex', gap: 6, alignItems: 'baseline', fontSize: 11 }}>
      <span style={{ color: '#7A7670', fontSize: 9, textTransform: 'uppercase', letterSpacing: 0.5 }}>
        {label}
      </span>
      <span style={{
        color: accent || '#E8E5DC', fontWeight: 500,
        fontFamily: "'SF Mono', monospace",
        maxWidth: 80,
        overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
      }}>
        {value}
      </span>
    </div>
  )
}

`.trim()

// ── Preset: Pulse — Grafana-style，数据密集，sparkline + 趋势 ─────────
// 适合把 board 当监控面板用。每个 card 是一个 KPI panel，清楚地把 token /
// 时间 / 状态并列起来。sparkline 用活跃消息的 text 长度作 fake 指标。
const PULSE = `
function isLive(s) {
  return s === 'active' || s === 'thinking' || s === 'tooling' || s === 'compacting'
}

function fmtN(n) {
  if (n == null) return '—'
  if (n < 1000) return String(n)
  if (n < 1_000_000) return (n / 1000).toFixed(n < 10000 ? 1 : 0) + 'k'
  return (n / 1_000_000).toFixed(1) + 'M'
}

function Sparkline({ values, color, height }) {
  if (!values || values.length < 2) return null
  const w = 60, h = height || 14
  const max = Math.max(...values, 1)
  const step = w / (values.length - 1)
  const pts = values.map((v, i) => (i * step) + ',' + (h - (v / max) * h)).join(' ')
  return (
    <svg width={w} height={h} style={{ display: 'block' }}>
      <polyline fill="none" stroke={color} strokeWidth={1.5}
        strokeLinecap="round" strokeLinejoin="round" points={pts} />
    </svg>
  )
}

export default function PulseCard({ session }) {
  const live = isLive(session.status)
  const urgent = session.status === 'permissionRequired'
  const accent = urgent ? '#C26A6A' : live ? '#22C55E' : '#7A7670'
  const u = session.usageStats || {}
  const msgs = session.recentMessages || []
  // Fake sparkline：最近几条消息的长度
  const spark = msgs.slice(-8).map(m => Math.min(100, (m.text || '').length))

  return (
    <div style={{
      width: '100%', height: '100%',
      background: 'linear-gradient(180deg, #2E2D2B 0%, #262624 100%)',
      border: '1px solid ' + (live ? accent : '#3A3A38'),
      borderRadius: 10,
      padding: 12,
      display: 'grid',
      gridTemplateColumns: '1fr 1fr',
      gridTemplateRows: 'auto 1fr auto',
      gap: 8,
      color: '#F5F4EF',
      fontFamily: '-apple-system, Inter, sans-serif',
      fontSize: 11,
      boxShadow: live ? '0 0 14px ' + accent + '33' : 'none',
    }}>
      {/* title 跨两栏 */}
      <div style={{ gridColumn: '1 / -1', display: 'flex', alignItems: 'baseline', gap: 8, minWidth: 0 }}>
        <span style={{
          fontSize: 13, fontWeight: 600,
          overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
          minWidth: 0, flex: 1,
        }}>{session.title}</span>
        <span style={{
          fontSize: 9, color: accent, fontWeight: 600, letterSpacing: 0.4,
          textTransform: 'uppercase', flexShrink: 0,
        }}>
          {urgent ? '⚠ wait' : live ? '● live' : '○ idle'}
        </span>
      </div>

      {/* 左 KPI: tokens */}
      <KPI label="Tokens ↓" value={fmtN(u.outputTokens || 0)}
           trend="↑ 12%" accent={accent} spark={spark} />
      {/* 右 KPI: turns */}
      <KPI label="Turns" value={String(u.turns || 0)}
           trend={session.currentTool ? '⚡ ' + session.currentTool : ''}
           accent={accent} spark={spark.slice().reverse()} />

      {/* 底部行：cost + project */}
      <div style={{
        gridColumn: '1 / -1',
        display: 'flex', alignItems: 'center', gap: 8,
        paddingTop: 6, borderTop: '1px solid #3A3A38',
        fontSize: 10, color: '#7A7670',
      }}>
        <span>{'$' + (session.costUSD || 0).toFixed(session.costUSD >= 1 ? 2 : 4)}</span>
        <span style={{ opacity: 0.5 }}>·</span>
        <span style={{
          overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
          flex: 1, minWidth: 0,
        }}>{(session.project || '').replace(/^\\/Users\\/[^/]+/, '~')}</span>
      </div>
    </div>
  )
}

function KPI({ label, value, trend, accent, spark }) {
  return (
    <div style={{
      background: 'rgba(255,255,255,0.03)',
      border: '1px solid #3A3A38',
      borderRadius: 6,
      padding: '6px 8px',
      display: 'flex', flexDirection: 'column', gap: 3,
      minWidth: 0,
    }}>
      <div style={{ fontSize: 9, color: '#7A7670', textTransform: 'uppercase', letterSpacing: 0.5 }}>
        {label}
      </div>
      <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', gap: 4 }}>
        <span style={{ fontSize: 15, fontWeight: 600, fontFamily: "'SF Mono', monospace" }}>
          {value}
        </span>
        <Sparkline values={spark} color={accent} />
      </div>
      {trend && (
        <div style={{ fontSize: 9, color: accent, opacity: 0.85 }}>
          {trend}
        </div>
      )}
    </div>
  )
}
`.trim()

export const TEMPLATE_PRESETS: TemplatePreset[] = [
  {
    id: 'default',
    label: 'Default',
    description: 'Full card with halo, transcript rows, live badge',
    source: DEFAULT_TEMPLATE,
  },
  {
    id: 'focus',
    label: 'Focus',
    description: 'Linear-style — serif title, 3-metric row, whitespace-heavy',
    source: FOCUS,
  },
  {
    id: 'pulse',
    label: 'Pulse',
    description: 'Grafana-style — KPI grid with sparklines and trend hints',
    source: PULSE,
  },
  {
    id: 'minimal',
    label: 'Minimal',
    description: 'One-line title + status dot',
    source: MINIMAL,
  },
  {
    id: 'stats',
    label: 'Stats',
    description: 'Token usage grid (input / output / cache / turns)',
    source: STATS,
  },
  {
    id: 'chat',
    label: 'Chat',
    description: 'Transcript as chat bubbles',
    source: CHAT,
  },
  {
    id: 'compact',
    label: 'Compact',
    description: 'Single-row horizontal layout',
    source: COMPACT,
  },
]
