// Runtime-compile + direct-render of user TSX template — no iframe.
//
// Why no iframe: this is a single-user dev tool. iframe sandboxing protects
// "untrusted code from attacking the parent" — but here the code is the
// user's own, no XSS surface. Direct `new Function(code)(...)` evaluation
// removes postMessage / DataClone / pointer-event / z-index headaches.
// Crashes are contained by a React ErrorBoundary so a buggy template only
// breaks its own card, not the whole app.

import { Component as ReactComponent, useMemo } from 'react'
import * as React from 'react'
import { compileCardSource, getAnimationsFor } from '@meee1/board-cards'

// ── helpers exposed to user code ────────────────────────────────────────

function formatCost(n: number | null): string {
  if (n == null) return ''
  if (n >= 1) return '$' + n.toFixed(2)
  if (n >= 0.01) return '$' + n.toFixed(3)
  return '$' + n.toFixed(4)
}

function timeAgo(iso: string): string {
  if (!iso) return ''
  const t = Date.parse(iso)
  if (!Number.isFinite(t)) return ''
  const diff = Date.now() - t
  if (diff < 10_000) return 'just now'
  if (diff < 60_000) return Math.floor(diff / 1000) + 's ago'
  if (diff < 3_600_000) return Math.floor(diff / 60_000) + 'm ago'
  if (diff < 86_400_000) return Math.floor(diff / 3_600_000) + 'h ago'
  return Math.floor(diff / 86_400_000) + 'd ago'
}

function truncate(s: string, n: number): string {
  if (!s) return ''
  return s.length > n ? s.slice(0, Math.max(0, n - 1)) + '…' : s
}

function roleColor(role: string): string {
  switch (role) {
    case 'user': return '#60A5FA'
    case 'assistant': return '#22C55E'
    case 'tool': return '#F59E0B'
    default: return '#94A3B8'
  }
}

function shortenProjectHelper(p: string): string {
  if (!p) return ''
  let s = p
  if (s.startsWith('/Users/')) {
    const rest = s.slice('/Users/'.length)
    const i = rest.indexOf('/')
    s = '~' + (i >= 0 ? rest.slice(i) : '')
  }
  return s.length > 40 ? '…' + s.slice(-39) : s
}

function statusLabelHelper(status: string): string {
  const map: Record<string, string> = {
    running: '● running',
    idle: '○ idle',
    thinking: '✦ thinking',
    tooling: '▸ tooling',
    waitingInput: '⌛ waiting',
    waiting_input: '⌛ waiting',
    permissionRequest: '⚠ permission',
    permission_request: '⚠ permission',
    completed: '✓ completed',
    compacting: '⇣ compacting',
    failed: '✖ failed',
  }
  return map[status] ?? status
}

const helpers = {
  formatCost,
  timeAgo,
  truncate,
  roleColor,
  shortenProject: shortenProjectHelper,
  statusLabel: statusLabelHelper,
}

// ── ErrorBoundary ───────────────────────────────────────────────────────

interface BoundaryProps {
  children: React.ReactNode
  onError?: (msg: string) => void
}
interface BoundaryState {
  error: string | null
}
class CardErrorBoundary extends ReactComponent<BoundaryProps, BoundaryState> {
  state: BoundaryState = { error: null }
  static getDerivedStateFromError(err: Error): BoundaryState {
    return { error: err.message || String(err) }
  }
  componentDidCatch(err: Error) {
    this.props.onError?.(err.message || String(err))
  }
  render() {
    if (this.state.error) return <RuntimeErrorCard msg={this.state.error} />
    return this.props.children as any
  }
}

function RuntimeErrorCard({ msg }: { msg: string }) {
  return (
    <pre style={{
      color: '#EF4444',
      padding: 10,
      fontSize: 11,
      fontFamily: 'monospace',
      whiteSpace: 'pre-wrap',
      margin: 0,
      height: '100%',
      overflow: 'auto',
      background: '#1e0e0e',
      boxSizing: 'border-box',
      border: '1px solid rgba(239,68,68,0.3)',
      borderRadius: 4,
    }}>
      {msg}
    </pre>
  )
}

// ── CardHost ────────────────────────────────────────────────────────────

/** Minimum board shape templates can read. Apps pass whatever they have —
 *  templates just iterate `board.sessions` and `board.channels`. */
export interface CardBoardLike {
  sessions: any[]
  channels: any[]
}

export interface CardHostProps {
  sessionId: string
  /** Session payload passed to the template. Apps can pass meee2's `Session`,
   *  or a meee2-mapped equivalent — the template decides what to read. */
  session: any
  board: CardBoardLike | null
  /** User-authored TSX source (raw text, pre-compile). */
  source: string
  onError?: (msg: string | null) => void
}

export function CardHost({ session, board, source, onError }: CardHostProps) {
  const { Component, error } = useMemo(() => {
    const out = compileCardSource(source)
    if (out.error) return { Component: null, error: out.error }
    try {
      const exports: any = {}
      const mod: any = { exports }
      // eslint-disable-next-line @typescript-eslint/no-implied-eval, no-new-func
      const factory = new Function('exports', 'module', 'React', out.code || '')
      factory(exports, mod, React)
      const C =
        (mod.exports && mod.exports.default) ||
        exports.default ||
        (typeof mod.exports === 'function' ? mod.exports : null)
      if (typeof C !== 'function') {
        return { Component: null, error: 'Template must `export default` a component function.' }
      }
      return { Component: C as React.ComponentType<any>, error: undefined as string | undefined }
    } catch (e) {
      return { Component: null, error: (e as Error).message }
    }
  }, [source])

  React.useEffect(() => {
    onError?.(error ?? null)
  }, [error, onError])

  if (error || !Component) {
    return <RuntimeErrorCard msg={error || 'Unknown compile error'} />
  }

  const safeBoard: CardBoardLike = board ?? { sessions: [], channels: [] }
  const animations = useMemo(() => getAnimationsFor(session.id), [session.id])
  const sessionWithAnim = useMemo(
    () => ({ ...session, _animations: animations }),
    [session, animations],
  )

  return (
    <CardErrorBoundary onError={(msg) => onError?.(msg)}>
      <Component
        session={sessionWithAnim}
        board={safeBoard}
        helpers={helpers}
        React={React}
      />
    </CardErrorBoundary>
  )
}
