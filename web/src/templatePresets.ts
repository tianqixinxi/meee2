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

// ── Preset: Minimal — just title + status dot + one-liner ─────────────
const MINIMAL = `
export default function MinimalCard({ session }) {
  const color =
    session.status === 'active' || session.status === 'running' || session.status === 'thinking' || session.status === 'tooling'
      ? '#22C55E'
      : session.status === 'waiting' || session.status === 'permissionRequest' ? '#EAB308'
      : session.status === 'dead' ? '#EF4444'
      : '#64748b'
  return (
    <div style={{
      width: '100%', height: '100%',
      background: '#141824',
      border: '1px solid #2a3040',
      borderRadius: 10,
      padding: 14,
      display: 'flex', alignItems: 'center', gap: 10,
      color: '#e5e5e5',
      fontFamily: '-apple-system, sans-serif',
    }}>
      <div style={{
        width: 10, height: 10, borderRadius: 5,
        background: color, flexShrink: 0,
        boxShadow: '0 0 8px ' + color + '80',
      }} />
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 14, fontWeight: 600, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
          {session.title}
        </div>
        <div style={{ fontSize: 11, color: '#94a3b8', marginTop: 2 }}>
          {session.currentTool ? '⚡ ' + session.currentTool : session.status}
        </div>
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
  const cost = session.costUSD
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
      {cost != null && (
        <div style={{
          marginTop: 10, paddingTop: 10, borderTop: '1px solid #2a3040',
          fontSize: 11, textAlign: 'center',
          color: '#22C55E', fontFamily: "'SF Mono', monospace",
        }}>
          $ {cost.toFixed(cost >= 1 ? 2 : 4)}
        </div>
      )}
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

// ── Preset: Compact — one-row horizontal ────────────────────────────
const COMPACT = `
export default function CompactCard({ session }) {
  const u = session.usageStats || {}
  const isLive = session.status === 'active' || session.status === 'running' || session.status === 'thinking' || session.status === 'tooling'
  return (
    <div style={{
      width: '100%', height: '100%',
      background: '#141824',
      border: '1px solid ' + (isLive ? '#22C55E' : '#2a3040'),
      boxShadow: isLive ? '0 0 10px rgba(34,197,94,0.25)' : 'none',
      borderRadius: 8,
      padding: '8px 12px',
      display: 'flex', alignItems: 'center', gap: 10,
      color: '#e5e5e5',
      fontFamily: '-apple-system, sans-serif',
    }}>
      <div style={{
        width: 8, height: 8, borderRadius: 4,
        background: isLive ? '#22C55E' : '#64748b',
        flexShrink: 0,
      }} />
      <div style={{ fontSize: 13, fontWeight: 600, flexShrink: 0 }}>
        {session.title}
      </div>
      <div style={{ flex: 1, fontSize: 11, color: '#94a3b8', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
        {session.currentTool || session.status}
      </div>
      <div style={{ fontSize: 10, color: '#64748b', fontFamily: "'SF Mono', monospace", flexShrink: 0 }}>
        {u.turns || 0} turns
      </div>
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
    id: 'minimal',
    label: 'Minimal',
    description: 'One-line title + status dot',
    source: MINIMAL,
  },
  {
    id: 'stats',
    label: 'Stats',
    description: 'Token usage grid + cost',
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
