// 运行时 compile + 直接渲染用户 TSX template —— 无 iframe。
//
// 决策：这是单用户本地 dev 工具。iframe 沙箱的价值是"防不可信代码攻击 parent"，
// 但这里代码就是用户自己写给自己看的，没 XSS 输入面。扔掉 iframe 换成直接
// `new Function(code)(...)` 在主页面 JS 上下文里求值 + 作为普通 React 组件
// 渲染。收益：postMessage/DataClone/指针事件/z-index 的所有坑全部消失，
// 内存 5 → 1 个 browser context，热重载等于一次 setState。
//
// 崩溃保护用 React ErrorBoundary —— 用户代码 throw 时只影响这一张卡，不会
// 殃及整个 app。

import { Component as ReactComponent, useMemo } from 'react'
import * as React from 'react'
import type { BoardState, Session } from '../types'
import { compileCardSource } from '../cardCompile'

// ── helpers (暴露给 user code 的小工具集) ─────────────────────────

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
    tooling: '⚡ tooling',
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

// ── ErrorBoundary: 兜住用户 component throw ─────────────────────────

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
  // Reset when React re-mounts with a fresh key (source change)
  componentDidUpdate(prev: BoundaryProps) {
    if (prev.children !== this.props.children && this.state.error) {
      // noop — new children + existing error state kept until next throw-free render
    }
  }
  render() {
    if (this.state.error) {
      return <RuntimeErrorCard msg={this.state.error} />
    }
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

// ── CardHost ────────────────────────────────────────────────────────

export interface CardHostProps {
  sessionId: string
  session: Session
  board: BoardState | null
  /** User-authored TSX source (raw text, pre-compile). */
  source: string
  onError?: (msg: string | null) => void
}

export function CardHost({ session, board, source, onError }: CardHostProps) {
  // Compile source → component factory. Memoize so edits-in-editor don't
  // recompile on every props tick.
  const { Component, error } = useMemo(() => {
    console.log(
      '[CardHost] compile sid=%s srcLen=%d firstLine=%s',
      session.id.slice(0, 8),
      source.length,
      source.split('\n', 1)[0]?.slice(0, 60),
    )
    const out = compileCardSource(source)
    if (out.error) {
      return { Component: null, error: out.error }
    }
    try {
      const exports: any = {}
      const module: any = { exports }
      // `React` is injected as a global so user code using JSX works. The
      // classic-runtime Babel preset emits `React.createElement(...)` calls.
      // eslint-disable-next-line @typescript-eslint/no-implied-eval, no-new-func
      const factory = new Function('exports', 'module', 'React', out.code || '')
      factory(exports, module, React)
      const C =
        (module.exports && module.exports.default) ||
        exports.default ||
        (typeof module.exports === 'function' ? module.exports : null)
      if (typeof C !== 'function') {
        return { Component: null, error: 'Template must `export default` a component function.' }
      }
      return { Component: C as React.ComponentType<any>, error: undefined }
    } catch (e) {
      return { Component: null, error: (e as Error).message }
    }
  }, [source])

  // Surface compile errors to the editor
  React.useEffect(() => {
    onError?.(error ?? null)
  }, [error, onError])

  if (error || !Component) {
    return <RuntimeErrorCard msg={error || 'Unknown compile error'} />
  }

  const safeBoard: BoardState = board ?? { sessions: [], channels: [] }

  return (
    <CardErrorBoundary onError={(msg) => onError?.(msg)}>
      <Component
        session={session}
        board={safeBoard}
        helpers={helpers}
        React={React}
      />
    </CardErrorBoundary>
  )
}

// For backwards compat with other imports (if any reference this)
export type { CardProps }
interface CardProps {
  session: Session
  board: BoardState
  helpers: typeof helpers
}
