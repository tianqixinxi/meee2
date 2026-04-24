import { useCallback, useEffect, useRef, useState } from 'react'
import type { BoardState, Selection } from '../types'
import SessionDetail from './SessionDetail'
import ChannelDetail from './ChannelDetail'
import TemplateEditor from './TemplateEditor'

const WIDTH_KEY = 'meee2.sidebar.width.v1'
const WIDTH_MIN = 260
const WIDTH_MAX = 900
const WIDTH_DEFAULT = 360

function readStoredWidth(): number {
  try {
    const s = localStorage.getItem(WIDTH_KEY)
    if (!s) return WIDTH_DEFAULT
    const n = parseInt(s, 10)
    if (!Number.isFinite(n)) return WIDTH_DEFAULT
    return Math.min(Math.max(n, WIDTH_MIN), WIDTH_MAX)
  } catch {
    return WIDTH_DEFAULT
  }
}

function clampToViewport(w: number): number {
  const vw = typeof window !== 'undefined' ? window.innerWidth : 1200
  const max = Math.min(WIDTH_MAX, Math.floor(vw * 0.7))
  return Math.min(Math.max(w, WIDTH_MIN), max)
}

// 16x16 line icons — Feather-style, match the sidebar's neutral tone.
function EyeOpenIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor"
         strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8S1 12 1 12z" />
      <circle cx="12" cy="12" r="3" />
    </svg>
  )
}

function EyeClosedIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor"
         strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M17.94 17.94A10.94 10.94 0 0 1 12 20C5 20 1 12 1 12a21.77 21.77 0 0 1 5.17-6.17" />
      <path d="M22.54 12.88A21.82 21.82 0 0 0 23 12s-4-8-11-8a10.94 10.94 0 0 0-4.06.77" />
      <path d="M9.9 9.9a3 3 0 0 0 4.2 4.2" />
      <line x1="1" y1="1" x2="23" y2="23" />
    </svg>
  )
}

interface Props {
  state: BoardState | null
  selection: Selection
  open: boolean
  onOpen: () => void
  onClose: () => void
  onSelectionChange: (s: Selection) => void
  /** Count of embeddable elements currently on the canvas, keyed by sid. */
  onCanvasCounts: Record<string, number>
  /** Request to insert a new embeddable card for this session. */
  onAddToCanvas: (sessionId: string) => void
  /** Request to remove all cards for this session from the canvas. */
  onHideFromCanvas: (sessionId: string) => void
  /** Bulk show / hide all sessions at once (sidebar "Show all" / "Hide all" button). */
  onBulkVisibility: (mode: 'show' | 'hide') => void
  /** Write-through cache for template source edits (see App.tsx). */
  onTemplateSaved: (templateId: string, source: string) => void
}

export default function Sidebar({
  state,
  selection,
  open,
  onOpen,
  onClose,
  onSelectionChange,
  onCanvasCounts,
  onAddToCanvas,
  onHideFromCanvas,
  onBulkVisibility,
  onTemplateSaved,
}: Props) {
  const [width, setWidth] = useState<number>(readStoredWidth)
  const dragStartRef = useRef<{ x: number; w: number } | null>(null)

  const onResizerMouseDown = useCallback((e: React.MouseEvent) => {
    e.preventDefault()
    dragStartRef.current = { x: e.clientX, w: width }
    document.body.style.cursor = 'ew-resize'
    document.body.style.userSelect = 'none'
  }, [width])

  useEffect(() => {
    function onMove(e: MouseEvent) {
      const s = dragStartRef.current
      if (!s) return
      // sidebar 在右侧：鼠标往左移 → width 增大
      const raw = s.w + (s.x - e.clientX)
      setWidth(clampToViewport(raw))
    }
    function onUp() {
      if (!dragStartRef.current) return
      dragStartRef.current = null
      document.body.style.cursor = ''
      document.body.style.userSelect = ''
      try {
        localStorage.setItem(WIDTH_KEY, String(width))
      } catch { /* localStorage unavailable */ }
    }
    window.addEventListener('mousemove', onMove)
    window.addEventListener('mouseup', onUp)
    return () => {
      window.removeEventListener('mousemove', onMove)
      window.removeEventListener('mouseup', onUp)
    }
  }, [width])

  // 窗口缩小时收紧 sidebar 宽度
  useEffect(() => {
    function onResize() {
      setWidth((w) => clampToViewport(w))
    }
    window.addEventListener('resize', onResize)
    return () => window.removeEventListener('resize', onResize)
  }, [])

  if (!open) {
    return (
      <aside className="sidebar collapsed">
        <button
          className="sidebar-header"
          style={{ border: 'none', background: 'transparent', cursor: 'pointer' }}
          onClick={onOpen}
          title="Expand sidebar"
        >
          «
        </button>
      </aside>
    )
  }

  const inDetail = selection.kind === 'session' || selection.kind === 'channel'

  return (
    <aside className="sidebar" style={{ width }}>
      <div
        className="sidebar-resizer"
        onMouseDown={onResizerMouseDown}
        title="Drag to resize"
      />
      <div className="sidebar-header row space">
        <div className="row" style={{ gap: 6, alignItems: 'center' }}>
          {inDetail && (
            <button
              className="ghost"
              style={{ padding: '2px 6px' }}
              onClick={() => onSelectionChange({ kind: 'none' })}
              title="Back to session list"
            >
              ‹
            </button>
          )}
          <span>
            {selection.kind === 'session'
              ? 'Session'
              : selection.kind === 'channel'
              ? 'Channel'
              : 'Inspector'}
          </span>
        </div>
        <button className="ghost" style={{ padding: '2px 6px' }} onClick={onClose} title="Collapse">
          »
        </button>
      </div>
      <div className="sidebar-body">
        {!state && <div className="muted">Loading…</div>}
        {state && selection.kind === 'none' && (
          <div className="col" style={{ gap: 10 }}>
            <div className="muted">
              Click a session card or channel arrow to inspect. Drag cards to
              reposition. Use ⊕ to create a channel.
            </div>
            <div className="section">
              {/* 顶部 header：标题 + 一个 toggle。当前至少有一张 card 在画布上 → "Hide all"；
                  全部不在 → "Show all"。按钮走 onBulkVisibility，由 Board 的 effect 一次性处理
                  所有 sids，避免单个触发跟 WS tick 竞争。 */}
              <div
                className="row space"
                style={{ marginBottom: 6, alignItems: 'baseline' }}
              >
                <h4 style={{ margin: 0 }}>Sessions ({state.sessions.length})</h4>
                {(() => {
                  const total = state.sessions.length
                  if (total === 0) return null
                  const anyOnCanvas = state.sessions.some(
                    (s) => (onCanvasCounts[s.id] ?? 0) > 0,
                  )
                  const mode: 'show' | 'hide' = anyOnCanvas ? 'hide' : 'show'
                  return (
                    <button
                      className="ghost"
                      style={{ padding: '2px 8px', fontSize: 10 }}
                      onClick={() => onBulkVisibility(mode)}
                      title={
                        mode === 'hide'
                          ? 'Remove all session cards from the canvas'
                          : 'Add every session card back to the canvas'
                      }
                    >
                      {mode === 'hide' ? 'Hide all' : 'Show all'}
                    </button>
                  )
                })()}
              </div>
              {state.sessions.map((s) => {
                const count = onCanvasCounts[s.id] ?? 0
                const onCanvas = count > 0
                const sidShort = s.id.replace(/-/g, '').slice(0, 8)
                return (
                  <div
                    key={s.id}
                    className="row space"
                    style={{ marginBottom: 6, cursor: 'pointer' }}
                  >
                    <div
                      className="row"
                      style={{ flex: 1, minWidth: 0 }}
                      onClick={() =>
                        onSelectionChange({ kind: 'session', sessionId: s.id })
                      }
                    >
                      <span
                        className="color-dot"
                        style={{ background: s.pluginColor }}
                      />
                      <span
                        style={{
                          overflow: 'hidden',
                          textOverflow: 'ellipsis',
                          whiteSpace: 'nowrap',
                        }}
                      >
                        {s.title}
                      </span>
                      {s.inboxPending > 0 && (
                        <span className="badge warn">📨 {s.inboxPending}</span>
                      )}
                    </div>
                    <div className="row" style={{ gap: 4, flexShrink: 0 }}>
                      <button
                        className="ghost"
                        style={{
                          padding: '2px 6px',
                          display: 'inline-flex',
                          alignItems: 'center',
                          opacity: onCanvas ? 1 : 0.55,
                        }}
                        title={
                          onCanvas
                            ? `Hide from canvas (${count} card${count === 1 ? '' : 's'})`
                            : 'Show on canvas'
                        }
                        onClick={(e) => {
                          e.stopPropagation()
                          if (onCanvas) onHideFromCanvas(s.id)
                          else onAddToCanvas(s.id)
                        }}
                      >
                        {onCanvas ? <EyeOpenIcon /> : <EyeClosedIcon />}
                      </button>
                      <span
                        className="mono muted"
                        style={{ fontSize: 10 }}
                        title={s.id}
                      >
                        {sidShort}
                      </span>
                    </div>
                  </div>
                )
              })}
            </div>
            <div className="section">
              <h4>Channels ({state.channels.length})</h4>
              {state.channels.length === 0 && (
                <div className="muted">No channels yet.</div>
              )}
              {state.channels.map((ch) => (
                <div
                  key={ch.name}
                  className="row space"
                  style={{ marginBottom: 4, cursor: 'pointer' }}
                  onClick={() =>
                    onSelectionChange({ kind: 'channel', channelName: ch.name })
                  }
                >
                  <span>{ch.name}</span>
                  <span className="mono muted">
                    {ch.members.length}m · {ch.mode}
                    {ch.pendingCount > 0 ? ` ·⏳${ch.pendingCount}` : ''}
                  </span>
                </div>
              ))}
            </div>
          </div>
        )}
        {state && selection.kind === 'session' && (() => {
          const s = state.sessions.find((x) => x.id === selection.sessionId)
          return (
            <div className="col" style={{ gap: 16 }}>
              <SessionDetail state={state} sessionId={selection.sessionId} />
              {s && (
                <details className="section" style={{ cursor: 'pointer' }}>
                  <summary style={{
                    margin: 0, fontSize: 11, textTransform: 'uppercase',
                    letterSpacing: '0.6px', color: 'var(--text-dim)',
                    fontWeight: 600, listStyle: 'none', outline: 'none',
                  }}>
                    Card template ▸
                  </summary>
                  <div style={{ marginTop: 8 }}>
                    <TemplateEditor
                      sessionId={s.id}
                      pluginDisplayName={s.pluginDisplayName}
                      onSaved={onTemplateSaved}
                    />
                  </div>
                </details>
              )}
            </div>
          )
        })()}
        {state && selection.kind === 'channel' && (
          <ChannelDetail state={state} channelName={selection.channelName} />
        )}
      </div>
    </aside>
  )
}
