import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { BoardState, ClientKind, Selection, Session } from '../types'
import SessionDetail from './SessionDetail'
import ChannelDetail from './ChannelDetail'
import TemplateEditor from './TemplateEditor'

const CATEGORY_FILTER_KEY = 'meee2.sidebar.categoryFilter.v2'
const OLDER_SESSIONS_KEY = 'meee2.sidebar.olderSessionsExpanded.v1'

/// Session 分类 key —— 动态从 session 列表里推导。规则：
/// - `com.meee2.plugin.claude` 这种"伞 plugin"内部按 clientKind 拆 (CLI/Desktop/Cowork)
/// - 其他 plugin（Cursor / Codex / OpenClaw / 第三方）每个 pluginId 自成一类
/// 这样既覆盖 plugin 维度（用户主问），又在 Claude 内部保留 source 区分。
type CategoryKey = string  // e.g. "claude:cli", "claude:desktop", "com.meee2.plugin.codex"

const CLAUDE_PLUGIN_ID = 'com.meee2.plugin.claude'

/// 把 session.clientKind 规范化（缺字段 / 未知值 → 'cli'，因为 cli 是默认）
function normalizeKind(k: string | null | undefined): ClientKind {
  if (k === 'desktop' || k === 'cowork') return k
  return 'cli'
}

/// 计算 session 的 category key：Claude 拆 sub-source，其他 plugin 用 pluginId
function categoryKey(s: Session): CategoryKey {
  if (s.pluginId === CLAUDE_PLUGIN_ID) {
    return `claude:${normalizeKind(s.clientKind)}`
  }
  return s.pluginId
}

const KIND_ICON: Record<ClientKind, string> = {
  cli: '⌨',
  desktop: '🖥',
  cowork: '🤝',
}

interface CategoryDescriptor {
  key: CategoryKey
  label: string  // "Claude CLI" / "Cursor" / "Codex" 等显示用
  icon?: string  // optional emoji
}

/// 把 category key 翻成显示文本 + icon。Claude sub-source 走专门 label，
/// 其他 plugin 用 pluginDisplayName（DTO 里有）。
function describeCategory(
  key: CategoryKey,
  pluginDisplayNames: Record<string, string>,
): CategoryDescriptor {
  if (key.startsWith('claude:')) {
    const sub = key.slice('claude:'.length) as ClientKind
    const sublabel = sub === 'cli' ? 'CLI' : sub === 'desktop' ? 'Desktop' : 'Cowork'
    return { key, label: `Claude · ${sublabel}`, icon: KIND_ICON[sub] }
  }
  return { key, label: pluginDisplayNames[key] ?? key, icon: undefined }
}

function readStoredCategoryFilter(): CategoryKey | 'all' {
  try {
    const s = localStorage.getItem(CATEGORY_FILTER_KEY)
    if (s) return s
  } catch {}
  return 'all'
}

function persistCategoryFilter(f: CategoryKey | 'all') {
  try { localStorage.setItem(CATEGORY_FILTER_KEY, f) } catch {}
}

function readOlderExpanded(): boolean {
  try {
    return localStorage.getItem(OLDER_SESSIONS_KEY) === '1'
  } catch {}
  return false
}

function persistOlderExpanded(v: boolean) {
  try { localStorage.setItem(OLDER_SESSIONS_KEY, v ? '1' : '0') } catch {}
}

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
  /** Bulk show / hide sessions on the canvas in one shot.
   *  - omit `sids` → operates on every session (top "Hide all" button)
   *  - pass `sids` → operates only on that subset (per-category toggle) */
  onBulkVisibility: (mode: 'show' | 'hide', sids?: string[]) => void
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
  const [categoryFilter, setCategoryFilter] = useState<CategoryKey | 'all'>(readStoredCategoryFilter)
  const [olderExpanded, setOlderExpanded] = useState<boolean>(readOlderExpanded)
  const dragStartRef = useRef<{ x: number; w: number } | null>(null)

  /// 按当前 sessions 推导出 category 列表（带计数）+ pluginId → displayName 索引。
  const categoryDescriptors = useMemo(() => {
    const names: Record<string, string> = {}
    const counts: Record<CategoryKey, number> = {}
    if (state) {
      for (const s of state.sessions) {
        names[s.pluginId] = s.pluginDisplayName
        const k = categoryKey(s)
        counts[k] = (counts[k] ?? 0) + 1
      }
    }
    // 按一个稳定的顺序展示：Claude sub-categories 先（cli/desktop/cowork），
    // 然后其他 plugin 按 displayName 字母序
    const claudeKeys = ['claude:cli', 'claude:desktop', 'claude:cowork'].filter(k => counts[k] > 0)
    const otherKeys = Object.keys(counts)
      .filter(k => !k.startsWith('claude:'))
      .sort((a, b) => (names[a] ?? a).localeCompare(names[b] ?? b))
    const orderedKeys = [...claudeKeys, ...otherKeys]
    const descs = orderedKeys.map(k => ({
      ...describeCategory(k, names),
      count: counts[k],
    }))
    return descs
  }, [state])

  /// 当前 filter 对应的 session 列表
  const filterByCategory = useCallback(
    (sessions: BoardState['sessions']) => {
      if (categoryFilter === 'all') return sessions
      return sessions.filter((s) => categoryKey(s) === categoryFilter)
    },
    [categoryFilter],
  )

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
                  // Top button respects the active category filter — when a
                  // filter is set, "Hide all" only hides sessions in that
                  // category. "All" → unscoped (legacy behaviour).
                  const scopedSessions =
                    categoryFilter === 'all'
                      ? state.sessions
                      : state.sessions.filter((s) => categoryKey(s) === categoryFilter)
                  if (scopedSessions.length === 0) return null
                  const anyOnCanvas = scopedSessions.some(
                    (s) => (onCanvasCounts[s.id] ?? 0) > 0,
                  )
                  const mode: 'show' | 'hide' = anyOnCanvas ? 'hide' : 'show'
                  const scopeLabel = categoryFilter === 'all' ? 'all' : 'category'
                  const sidsArg =
                    categoryFilter === 'all' ? undefined : scopedSessions.map((s) => s.id)
                  return (
                    <button
                      className="ghost"
                      style={{ padding: '2px 8px', fontSize: 10 }}
                      onClick={() => onBulkVisibility(mode, sidsArg)}
                      title={
                        mode === 'hide'
                          ? `Remove ${scopeLabel} session cards from the canvas`
                          : `Add ${scopeLabel} session cards back to the canvas`
                      }
                    >
                      {mode === 'hide' ? 'Hide all' : 'Show all'}
                    </button>
                  )
                })()}
              </div>
              {/* Plugin-动态分类过滤器：按 plugin 拆，Claude 内部再按
                  CLI/Desktop/Cowork sub-source 拆。Cursor / Codex / OpenClaw
                  等其他 plugin 各自一个 button。只显示 count > 0 的 category。
                  localStorage 持久化选择。 */}
              {categoryDescriptors.length > 1 && (
                <div
                  className="row"
                  style={{ gap: 4, marginBottom: 8, flexWrap: 'wrap' }}
                >
                  <button
                    className={'ghost' + (categoryFilter === 'all' ? ' active' : '')}
                    style={{
                      padding: '3px 9px',
                      fontSize: 11,
                      opacity: categoryFilter === 'all' ? 1 : 0.65,
                      fontWeight: categoryFilter === 'all' ? 600 : 400,
                    }}
                    onClick={() => {
                      setCategoryFilter('all')
                      persistCategoryFilter('all')
                    }}
                    title="Show all sessions"
                  >
                    All {state.sessions.length}
                  </button>
                  {categoryDescriptors.map((d) => {
                    const active = categoryFilter === d.key
                    // Per-category visibility toggle. Compute scope sids and
                    // current canvas presence so we can flip 👁 / 👁‍🗨 on the
                    // small button without the user changing the filter.
                    const sidsInCat = state.sessions
                      .filter((s) => categoryKey(s) === d.key)
                      .map((s) => s.id)
                    const anyOnCanvas = sidsInCat.some(
                      (id) => (onCanvasCounts[id] ?? 0) > 0,
                    )
                    const eyeMode: 'show' | 'hide' = anyOnCanvas ? 'hide' : 'show'
                    return (
                      <span
                        key={d.key}
                        style={{
                          display: 'inline-flex',
                          alignItems: 'center',
                          border: '1px solid transparent',
                          borderRadius: 4,
                        }}
                      >
                        <button
                          className={'ghost' + (active ? ' active' : '')}
                          style={{
                            padding: '3px 6px 3px 9px',
                            fontSize: 11,
                            opacity: active ? 1 : 0.65,
                            fontWeight: active ? 600 : 400,
                            border: 'none',
                            borderTopRightRadius: 0,
                            borderBottomRightRadius: 0,
                          }}
                          onClick={() => {
                            setCategoryFilter(d.key)
                            persistCategoryFilter(d.key)
                          }}
                          title={`Show only ${d.label} sessions in the list`}
                        >
                          {d.icon ? `${d.icon} ` : ''}{d.label} {d.count}
                        </button>
                        <button
                          className="ghost"
                          style={{
                            padding: '3px 6px',
                            fontSize: 11,
                            opacity: active ? 0.9 : 0.55,
                            border: 'none',
                            borderLeft: '1px solid rgba(255,255,255,0.06)',
                            borderTopLeftRadius: 0,
                            borderBottomLeftRadius: 0,
                          }}
                          onClick={(e) => {
                            e.stopPropagation()
                            onBulkVisibility(eyeMode, sidsInCat)
                          }}
                          title={
                            eyeMode === 'hide'
                              ? `Remove all ${d.label} cards from the canvas`
                              : `Add all ${d.label} cards back to the canvas`
                          }
                        >
                          {eyeMode === 'hide' ? '🙈' : '👁'}
                        </button>
                      </span>
                    )
                  })}
                </div>
              )}
              {(() => {
                const filtered = filterByCategory(state.sessions)
                const primary = filtered.filter((s) => s.displayGroup !== 'older')
                const older = filtered.filter((s) => s.displayGroup === 'older')
                const renderSessionRow = (s: Session) => {
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
                        {(() => {
                          // Claude session 多 source（CLI/Desktop/Cowork）共用一个
                          // pluginColor，加 source icon 才能视觉上分清。其他 plugin
                          // 自己有独立 pluginColor 不需要补。
                          if (s.pluginId !== CLAUDE_PLUGIN_ID) return null
                          const k = normalizeKind(s.clientKind)
                          if (k === 'cli') return null
                          return (
                            <span
                              style={{ fontSize: 10, opacity: 0.7, marginRight: 2 }}
                              title={k === 'desktop' ? 'Desktop' : 'Cowork'}
                            >
                              {KIND_ICON[k]}
                            </span>
                          )
                        })()}
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
                }
                if (filtered.length === 0) {
                  return (
                    <div className="muted" style={{ padding: '8px 0', fontSize: 11 }}>
                      No sessions for this filter.
                    </div>
                  )
                }
                return (
                  <>
                    {primary.map(renderSessionRow)}
                    {older.length > 0 && (
                      <div style={{ marginTop: primary.length > 0 ? 8 : 0 }}>
                        <button
                          className="ghost"
                          style={{
                            width: '100%',
                            padding: '4px 2px',
                            justifyContent: 'space-between',
                            display: 'flex',
                            alignItems: 'center',
                            fontSize: 11,
                            color: 'var(--text-dim)',
                          }}
                          onClick={() => {
                            setOlderExpanded((v) => {
                              persistOlderExpanded(!v)
                              return !v
                            })
                          }}
                          title="Sessions idle for more than 1 hour"
                        >
                          <span>{olderExpanded ? '⌄' : '›'} Older ({older.length})</span>
                          <span className="mono muted">1h-24h</span>
                        </button>
                        {olderExpanded && (
                          <div style={{ marginTop: 4 }}>
                            {older.map(renderSessionRow)}
                          </div>
                        )}
                      </div>
                    )}
                  </>
                )
              })()}
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
