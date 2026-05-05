// Headless transcript view — full-fidelity port of meee2's TranscriptPanel.
// Apps own data fetching: pass `entries` already-loaded; this component
// owns search / tool-toggle / virtualization / sticky user / auto-scroll
// / Markdown / diff / collapsible code etc.
//
// Style: import '@meee1/board-ui/TranscriptView.css' once at app boot
// (sibling to SessionInspector.css).

import {
  memo,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from 'react'
import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import rehypeHighlight from 'rehype-highlight'
import ReactDiffViewer from 'react-diff-viewer-continued'
import { useVirtualizer } from '@tanstack/react-virtual'
import 'highlight.js/styles/github-dark.css'
import type {
  TranscriptBlockForView,
  TranscriptEntryForView,
} from '@meee1/board-core'

export interface TranscriptViewProps {
  /** Pre-fetched entries — caller (app) owns loading + polling. */
  entries: TranscriptEntryForView[]
  /** Cache key — module-level Map keys scroll/sticky state on this so
   *  switching between sessions and back doesn't lose position. Usually
   *  pass the session id. */
  cacheKey: string
  /** Optional: render a "Loading transcript…" placeholder while caller
   *  is doing the initial fetch. */
  loading?: boolean
  /** Optional: render an error message (caller decides retry strategy). */
  error?: string | null
  /** Optional: tiny "refreshing" indicator next to the entry count. */
  refreshing?: boolean
  /** Search input placeholder text. */
  searchPlaceholder?: string
}

// ─── module cache (cross-mount session memory) ───────────────────────────

interface TxCacheEntry {
  signature: string
  scrollTop: number
  stickyBottom: boolean
  lastSeenEntryId: string | null
}
const txCache = new Map<string, TxCacheEntry>()

// 三档 transcript 展示。和 Claude Code 自身的 verbosity 行为对齐：
//   - normal:   只看 user / assistant 的文本；藏 thinking + tool_use + tool_result
//   - thinking: normal + 展示 thinking 块（默认折叠）
//   - verbose:  展示一切。thinking 块默认展开；tool 块完整显示 input + output
//
// 旧的 boolean `showTools` (`meee2.transcript.showTools.v1`) 迁移：true →
// verbose，false → normal。Thinking 这一档之前不存在，迁移到这之后用户
// 想要中间态自己点。
export type TranscriptVerbosity = 'normal' | 'thinking' | 'verbose'

const VERBOSITY_KEY = 'meee2.transcript.verbosity.v1'
const LEGACY_TOOL_VIS_KEY = 'meee2.transcript.showTools.v1'

function loadVerbosity(): TranscriptVerbosity {
  try {
    if (typeof localStorage === 'undefined') return 'normal'
    const v = localStorage.getItem(VERBOSITY_KEY)
    if (v === 'normal' || v === 'thinking' || v === 'verbose') return v
    // 迁移旧 showTools key
    const legacy = localStorage.getItem(LEGACY_TOOL_VIS_KEY)
    if (legacy === 'true') return 'verbose'
    if (legacy === 'false') return 'normal'
  } catch { /* ignore */ }
  return 'normal'
}

function entrySignature(entries: TranscriptEntryForView[]): string {
  const last = entries[entries.length - 1]
  const lastBlock = last?.blocks[last.blocks.length - 1]
  return (
    entries.length +
    '|' + (last?.id ?? '') +
    '|' + (lastBlock?.type ?? '') +
    '|' + ((lastBlock?.text ?? lastBlock?.toolResultText ?? '').length)
  )
}

// ─── main component ──────────────────────────────────────────────────────

export function TranscriptView({
  entries,
  cacheKey,
  loading,
  error,
  refreshing,
  searchPlaceholder = 'Search in messages (tool name / text)…',
}: TranscriptViewProps) {
  const initialCache = txCache.get(cacheKey)
  const [query, setQuery] = useState('')
  const [verbosity, setVerbosity] = useState<TranscriptVerbosity>(loadVerbosity)

  const parentRef = useRef<HTMLDivElement | null>(null)
  const stickToBottomRef = useRef(initialCache?.stickyBottom ?? true)
  const lastEntryIdRef = useRef<string | null>(initialCache?.lastSeenEntryId ?? null)
  const pendingScrollTopRef = useRef<number | null>(
    initialCache ? initialCache.scrollTop : null,
  )
  const lastSignatureRef = useRef<string>(initialCache?.signature ?? '')

  // Cache-key change → reset transient state
  useEffect(() => {
    setQuery('')
    lastEntryIdRef.current = null
    stickToBottomRef.current = true
    pendingScrollTopRef.current = null
    lastSignatureRef.current = txCache.get(cacheKey)?.signature ?? ''

    return () => {
      const el = parentRef.current
      const cur = txCache.get(cacheKey)
      if (!cur) return
      txCache.set(cacheKey, {
        ...cur,
        scrollTop: el?.scrollTop ?? cur.scrollTop,
        stickyBottom: stickToBottomRef.current,
      })
    }
  }, [cacheKey])

  // Persist verbosity
  useEffect(() => {
    try {
      localStorage.setItem(VERBOSITY_KEY, verbosity)
      // 一并清掉 legacy key —— 迁移完就别留
      localStorage.removeItem(LEGACY_TOOL_VIS_KEY)
    } catch { /* ignore */ }
  }, [verbosity])

  // Update cache signature when entries change (so cross-mount re-entry knows
  // whether content moved on)
  useEffect(() => {
    const sig = entrySignature(entries)
    if (sig === lastSignatureRef.current) return
    lastSignatureRef.current = sig
    const last = entries[entries.length - 1]
    const prev = txCache.get(cacheKey)
    txCache.set(cacheKey, {
      signature: sig,
      scrollTop: prev?.scrollTop ?? 0,
      stickyBottom: prev?.stickyBottom ?? true,
      lastSeenEntryId: last?.id ?? null,
    })
  }, [entries, cacheKey])

  // Filter
  const filteredEntries = useMemo(() => {
    if (!query.trim()) return entries
    const q = query.toLowerCase()
    return entries.filter((e) => e.blocks.some((b) => blockMatchesQuery(b, q)))
  }, [entries, query])

  // Index tool_result by toolUseId for pairing
  const resultsByToolUseId = useMemo(() => {
    const m = new Map<string, TranscriptBlockForView>()
    for (const e of entries) {
      for (const b of e.blocks) {
        if (b.type === 'tool_result' && b.toolUseId) m.set(b.toolUseId, b)
      }
    }
    return m
  }, [entries])

  // 按 verbosity 过滤 blocks + 丢弃纯 tool_result 的 user entry（orphan）
  //   normal:   text 块（user/assistant 都算）
  //   thinking: text + thinking
  //   verbose:  全部块都保留
  const visibleEntries = useMemo(() => {
    const out: TranscriptEntryForView[] = []
    for (const e of filteredEntries) {
      const isPureOrphan =
        e.type === 'user' && e.blocks.every((b) => b.type === 'tool_result')
      if (isPureOrphan) continue
      if (verbosity === 'verbose') { out.push(e); continue }
      const kept = e.blocks.filter((b) => {
        if (b.type === 'text') return true
        if (b.type === 'thinking') return verbosity === 'thinking'
        // tool_use / tool_result 在 normal + thinking 都隐藏
        return false
      })
      if (kept.length === 0) continue
      out.push({ ...e, blocks: kept })
    }
    return out
  }, [filteredEntries, verbosity])

  // Continuous-role merging (hide chip on consecutive same-role entries)
  const hideRoleChipFor = useMemo(() => {
    const set = new Set<string>()
    for (let i = 1; i < visibleEntries.length; i++) {
      if (visibleEntries[i].type === visibleEntries[i - 1].type) {
        set.add(visibleEntries[i].id)
      }
    }
    return set
  }, [visibleEntries])

  // Virtualizer
  const virtualizer = useVirtualizer({
    count: visibleEntries.length,
    getScrollElement: () => parentRef.current,
    estimateSize: () => 280,
    overscan: 6,
    measureElement: (el) => el.getBoundingClientRect().height,
    getItemKey: (index) => visibleEntries[index]?.id ?? `idx-${index}`,
    useFlushSync: false,
  })

  const [atBottom, setAtBottom] = useState(true)
  const [stickyUser, setStickyUser] = useState<{ index: number; text: string } | null>(null)
  const userEndCacheRef = useRef<Map<string, number>>(new Map())

  useEffect(() => {
    userEndCacheRef.current = new Map()
  }, [cacheKey])

  // Warm user-end cache from currently-rendered virtual items
  useEffect(() => {
    for (const item of virtualizer.getVirtualItems()) {
      const entry = visibleEntries[item.index]
      if (entry?.type === 'user') userEndCacheRef.current.set(entry.id, item.end)
    }
  })

  const handleScroll = () => {
    const el = parentRef.current
    if (!el) return
    const dist = el.scrollHeight - el.scrollTop - el.clientHeight
    const isAtB = dist < 40
    stickToBottomRef.current = isAtB
    setAtBottom(isAtB)

    const top = el.scrollTop
    for (const item of virtualizer.getVirtualItems()) {
      const entry = visibleEntries[item.index]
      if (entry?.type === 'user') userEndCacheRef.current.set(entry.id, item.end)
    }

    let stickyIdx: number | null = null
    for (let i = visibleEntries.length - 1; i >= 0; i--) {
      const entry = visibleEntries[i]
      if (entry.type !== 'user') continue
      const end = userEndCacheRef.current.get(entry.id)
      if (end == null) continue
      if (end <= top + 2) { stickyIdx = i; break }
    }

    // Don't show sticky when the chosen user entry IS the most recent user
    // message in the conversation —— there's nothing "scrolled past" worth
    // reminding the user about; the bar would just duplicate whatever they
    // most recently typed (or the prompt they just scrolled away from).
    // Sticky is meaningful only when there's a NEWER user prompt below.
    if (stickyIdx != null) {
      let hasLaterUserMsg = false
      for (let i = stickyIdx + 1; i < visibleEntries.length; i++) {
        if (visibleEntries[i].type === 'user') { hasLaterUserMsg = true; break }
      }
      if (!hasLaterUserMsg) stickyIdx = null
    }

    let sticky: { index: number; text: string } | null = null
    if (stickyIdx != null) {
      let start = stickyIdx
      while (start > 0 && visibleEntries[start - 1].type === 'user') start--
      const anchor = visibleEntries[start]
      const textBlock = anchor.blocks.find((b) => b.type === 'text' && (b.text ?? '').trim())
      const preview = (textBlock?.text ?? '').trim()
      if (preview) sticky = { index: start, text: preview }
    }
    setStickyUser((prev) => {
      if (prev?.index === sticky?.index && prev?.text === sticky?.text) return prev
      return sticky
    })
  }

  const scrollToStickyUser = useCallback(() => {
    if (stickyUser == null) return
    virtualizer.scrollToIndex(stickyUser.index, { align: 'start' })
    requestAnimationFrame(() => {
      const node = parentRef.current
      if (node) node.scrollTop = Math.max(0, node.scrollTop - 8)
    })
  }, [stickyUser, virtualizer])

  const scrollToBottom = useCallback(() => {
    if (visibleEntries.length === 0) return
    const targetIndex = visibleEntries.length - 1
    let lastHeight = -1
    let stableFrames = 0
    let raf = 0
    const deadline = performance.now() + 1500
    const tick = () => {
      const node = parentRef.current
      if (!node) return
      node.scrollTop = node.scrollHeight
      virtualizer.scrollToIndex(targetIndex, { align: 'end' })
      const h = node.scrollHeight
      if (h === lastHeight) stableFrames++
      else { stableFrames = 0; lastHeight = h }
      if (stableFrames >= 4 || performance.now() >= deadline) {
        stickToBottomRef.current = true
        setAtBottom(true)
        return
      }
      raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
    void raf
  }, [visibleEntries.length, virtualizer])

  // Restore scrollTop on cache hit (1 frame after layout, 1 more after measurement)
  useEffect(() => {
    const target = pendingScrollTopRef.current
    if (target == null) return
    pendingScrollTopRef.current = null
    if (stickToBottomRef.current) return
    const r1 = requestAnimationFrame(() => {
      const el = parentRef.current
      if (!el) return
      el.scrollTop = target
      requestAnimationFrame(() => {
        const node = parentRef.current
        if (node) node.scrollTop = target
      })
    })
    return () => cancelAnimationFrame(r1)
  }, [cacheKey])

  // Auto-scroll on new entries
  useEffect(() => {
    if (visibleEntries.length === 0) return
    const newestId = visibleEntries[visibleEntries.length - 1].id
    const isFirstLoad = lastEntryIdRef.current === null
    const isNewContent = newestId !== lastEntryIdRef.current
    lastEntryIdRef.current = newestId
    if (!(isFirstLoad || (isNewContent && stickToBottomRef.current))) return

    const targetIndex = visibleEntries.length - 1
    const deadline = performance.now() + (isFirstLoad ? 2500 : 1200)
    let lastHeight = -1
    let stableFrames = 0
    let raf = 0
    let cancelled = false

    const tick = () => {
      if (cancelled) return
      const node = parentRef.current
      if (!node) return
      node.scrollTop = node.scrollHeight
      virtualizer.scrollToIndex(targetIndex, { align: 'end' })
      const h = node.scrollHeight
      if (h === lastHeight) stableFrames++
      else { stableFrames = 0; lastHeight = h }
      if (stableFrames >= 4 || performance.now() >= deadline) return
      raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
    return () => { cancelled = true; cancelAnimationFrame(raf) }
  }, [visibleEntries, virtualizer])

  if (loading && entries.length === 0) {
    return <div className="transcript-panel empty">Loading transcript…</div>
  }
  if (error) {
    return <div className="transcript-panel error">Error: {error}</div>
  }

  const totalH = virtualizer.getTotalSize()
  const vItems = virtualizer.getVirtualItems()

  return (
    <div className="transcript-wrap">
      <div className="transcript-search">
        <input
          type="text"
          placeholder={searchPlaceholder}
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Escape') {
              setQuery('')
              e.currentTarget.blur()
            }
          }}
        />
        <div
          className="transcript-search__verbosity"
          role="radiogroup"
          aria-label="Transcript verbosity"
        >
          {(['normal', 'thinking', 'verbose'] as TranscriptVerbosity[]).map((level) => (
            <button
              key={level}
              type="button"
              role="radio"
              aria-checked={verbosity === level}
              className={
                'transcript-search__verbosity-btn' +
                (verbosity === level ? ' transcript-search__verbosity-btn--active' : '')
              }
              title={
                level === 'normal'
                  ? 'Normal — text only (no thinking, no tool calls)'
                  : level === 'thinking'
                  ? 'Thinking — text + thinking blocks'
                  : 'Verbose — full transcript including tool inputs/outputs'
              }
              onClick={() => setVerbosity(level)}
            >
              {level}
            </button>
          ))}
        </div>
        <span className="transcript-search__count">
          {query
            ? `${filteredEntries.length}/${entries.length}`
            : `${entries.length} entries`}
        </span>
        {refreshing && (
          <span className="transcript-search__refreshing" title="Refreshing…">
            <span className="transcript-search__spinner" /> refreshing
          </span>
        )}
      </div>

      {visibleEntries.length === 0 ? (
        <div className="transcript-panel empty">
          {query ? 'No matches.' : 'No transcript messages yet.'}
        </div>
      ) : (
        <div className="transcript-panel-wrap">
          {stickyUser && (
            <button
              type="button"
              className="tx-sticky-user"
              onClick={scrollToStickyUser}
              title="Click to jump back to this message"
            >
              <span className="tx-sticky-user__chip">You</span>
              <span className="tx-sticky-user__text">{stickyUser.text}</span>
              <span className="tx-sticky-user__hint" aria-hidden>↑</span>
            </button>
          )}
          <div ref={parentRef} className="transcript-panel" onScroll={handleScroll}>
            <div style={{ height: totalH, width: '100%', position: 'relative' }}>
              {vItems.map((v) => {
                const e = visibleEntries[v.index]
                return (
                  <div
                    key={e.id}
                    data-index={v.index}
                    ref={virtualizer.measureElement}
                    style={{
                      position: 'absolute',
                      top: 0,
                      left: 0,
                      width: '100%',
                      transform: `translateY(${v.start}px)`,
                    }}
                  >
                    <EntryRow
                      entry={e}
                      resultsByToolUseId={resultsByToolUseId}
                      hideRoleChip={hideRoleChipFor.has(e.id)}
                      verbosity={verbosity}
                    />
                  </div>
                )
              })}
            </div>
          </div>
          {!atBottom && (
            <button
              className="transcript-scroll-latest"
              onClick={scrollToBottom}
              aria-label="Scroll to latest message"
              title="Scroll to latest message"
            >
              ↓ Latest
            </button>
          )}
        </div>
      )}
    </div>
  )
}

// ─── entry row ────────────────────────────────────────────────────────────

function EntryRow({
  entry,
  resultsByToolUseId,
  hideRoleChip,
  verbosity,
}: {
  entry: TranscriptEntryForView
  resultsByToolUseId: Map<string, TranscriptBlockForView>
  hideRoleChip: boolean
  verbosity: TranscriptVerbosity
}) {
  let renderedFirstText = false
  return (
    <div className={`tx-entry tx-entry--${entry.type}${hideRoleChip ? ' tx-entry--merged' : ''}`}>
      {entry.blocks.map((b, i) => {
        switch (b.type) {
          case 'text': {
            const hideLabel = hideRoleChip || renderedFirstText
            renderedFirstText = true
            return <TextBlock key={i} role={entry.type} text={b.text ?? ''} hideLabel={hideLabel} />
          }
          case 'thinking':
            return <ThinkingBlock key={i} text={b.text ?? ''} forceOpen={verbosity === 'verbose'} />
          case 'tool_use':
            return (
              <ToolUseBlock
                key={i}
                block={b}
                result={b.toolId ? resultsByToolUseId.get(b.toolId) : undefined}
              />
            )
          case 'tool_result':
            return <OrphanToolResult key={i} block={b} />
          default:
            return null
        }
      })}
    </div>
  )
}

const TextBlock = memo(function TextBlock({
  role,
  text,
  hideLabel,
}: {
  role: string
  text: string
  hideLabel?: boolean
}) {
  const isAssistant = role === 'assistant'
  const isUser = role === 'user'
  const isInjected = role === 'injected'
  const roleLabel = isInjected ? '📨 Injected' : isUser ? 'You' : isAssistant ? 'Claude' : role
  const cls = isInjected
    ? 'tx-text--injected'
    : isUser ? 'tx-text--user' : isAssistant ? 'tx-text--assistant' : 'tx-text--other'
  return (
    <div className={`tx-text ${cls}${hideLabel ? ' tx-text--merged' : ''}`}>
      {!hideLabel && (
        <div className="tx-text__role">
          {isAssistant && <span className="tx-text__role-glyph" aria-hidden>◆</span>}
          <span className="tx-text__role-name">{roleLabel}</span>
        </div>
      )}
      <div className="tx-text__body">
        {isAssistant ? (
          <ReactMarkdown
            remarkPlugins={[remarkGfm]}
            rehypePlugins={[rehypeHighlight]}
            components={{
              a: ({ node: _node, ...props }: any) => (
                <a {...props} target="_blank" rel="noopener noreferrer" />
              ),
              pre: ({ node: _node, children, ...props }: any) => (
                <CollapsibleCode>
                  <pre {...props}>{children}</pre>
                </CollapsibleCode>
              ),
            }}
          >
            {text}
          </ReactMarkdown>
        ) : (
          text
        )}
      </div>
    </div>
  )
})

/// `forceOpen` 是 verbose 模式的契约：处于 verbose 时永远展开 thinking 块，
/// 不管该实例之前手动点过收起没——这跟 Codex review 指出的 P2 bug 相关：
/// 之前用 `useState(defaultOpen)` 只在 mount 取一次，从 thinking 切到 verbose
/// 时已经 mount 的实例不会响应 prop 翻转，留着收起态违反 verbose 契约。
///
/// 行为定义：
///   - forceOpen=true（verbose 模式）→ 一律 open，按钮还能点但视觉总是展开
///   - forceOpen=false（thinking 模式）→ 走用户手动 toggle 的本地状态，
///     默认收起；切回 verbose 又会被强制展开。
function ThinkingBlock({ text, forceOpen = false }: { text: string; forceOpen?: boolean }) {
  const [userOpen, setUserOpen] = useState(false)
  const open = forceOpen || userOpen
  return (
    <div className="tx-thinking">
      <button
        className="tx-thinking__toggle"
        onClick={() => setUserOpen(!open)}
        title={forceOpen ? 'Verbose mode auto-expands thinking — toggle disabled' : undefined}
      >
        {open ? '▾' : '▸'} thinking
      </button>
      {open && <div className="tx-thinking__body">{text}</div>}
    </div>
  )
}

function ToolUseBlock({
  block,
  result,
}: {
  block: TranscriptBlockForView
  result: TranscriptBlockForView | undefined
}) {
  const name = block.toolName ?? 'Tool'
  const input = safeParse(block.toolInputJSON) ?? {}
  return (
    <div className="tx-tool">
      <div className="tx-tool__header">
        <span className="tx-tool__icon">{toolIcon(name)}</span>
        <span className="tx-tool__name">{name}</span>
        <span className="tx-tool__summary">{summarizeToolInput(name, input)}</span>
      </div>
      <ToolInputBody name={name} input={input} />
      {result && <ToolResultBody block={result} />}
    </div>
  )
}

function OrphanToolResult({ block }: { block: TranscriptBlockForView }) {
  return (
    <div className="tx-tool tx-tool--orphan">
      <div className="tx-tool__header">
        <span className="tx-tool__icon">⚙</span>
        <span className="tx-tool__name">tool result</span>
      </div>
      <ToolResultBody block={block} />
    </div>
  )
}

function ToolInputBody({ name, input }: { name: string; input: Record<string, any> }) {
  if (name === 'Bash') {
    const cmd = typeof input.command === 'string' ? input.command : ''
    if (!cmd) return null
    return (
      <CollapsibleCode>
        <pre className="tx-tool__code tx-tool__code--bash">
          <span className="tx-tool__prompt">$ </span>{cmd}
        </pre>
      </CollapsibleCode>
    )
  }
  if (name === 'Edit') {
    const oldStr = (input.old_string as string) ?? ''
    const newStr = (input.new_string as string) ?? ''
    if (!oldStr && !newStr) return null
    return <DiffView oldStr={oldStr} newStr={newStr} />
  }
  if (name === 'MultiEdit') {
    const edits = (input.edits as Array<{ old_string: string; new_string: string }>) ?? []
    if (!edits.length) return null
    return (
      <div className="tx-tool__multiedit">
        {edits.map((ed, i) => (
          <div key={i} className="tx-tool__multiedit-item">
            <div className="tx-tool__multiedit-label">Edit #{i + 1}</div>
            <DiffView oldStr={ed.old_string ?? ''} newStr={ed.new_string ?? ''} />
          </div>
        ))}
      </div>
    )
  }
  if (name === 'Write') {
    const content = (input.content as string) ?? ''
    if (!content) return null
    return (
      <CollapsibleCode>
        <pre className="tx-tool__code tx-tool__code--write">
          {truncateForPreview(content, 2000)}
        </pre>
      </CollapsibleCode>
    )
  }
  if (name === 'Read') {
    const off = input.offset ? ` offset=${input.offset}` : ''
    const lim = input.limit ? ` limit=${input.limit}` : ''
    return (
      <div className="tx-tool__meta">
        <span className="mono">{input.file_path}</span>
        <span className="tx-tool__meta-flags">{off}{lim}</span>
      </div>
    )
  }
  if (name === 'Grep') {
    return (
      <div className="tx-tool__meta mono">
        <span className="tx-tool__pat">{String(input.pattern ?? '')}</span>
        {input.path && <span className="muted"> in {input.path}</span>}
        {input.glob && <span className="muted"> glob={input.glob}</span>}
        {input.type && <span className="muted"> type={input.type}</span>}
      </div>
    )
  }
  if (name === 'Glob') {
    return (
      <div className="tx-tool__meta mono">
        <span className="tx-tool__pat">{String(input.pattern ?? '')}</span>
        {input.path && <span className="muted"> in {input.path}</span>}
      </div>
    )
  }
  if (name === 'WebSearch' || name === 'WebFetch') {
    return (
      <div className="tx-tool__meta mono">
        {input.url && <span>{String(input.url)}</span>}
        {input.query && <span>{String(input.query)}</span>}
      </div>
    )
  }
  if (name === 'Agent' || name === 'Task') {
    return (
      <div className="tx-tool__agent">
        {input.subagent_type && (
          <div className="muted">subagent: <span className="mono">{String(input.subagent_type)}</span></div>
        )}
        {input.description && <div className="tx-tool__agent-desc">{String(input.description)}</div>}
        {input.prompt && (
          <details className="tx-tool__agent-prompt">
            <summary>prompt ▸</summary>
            <pre>{String(input.prompt)}</pre>
          </details>
        )}
      </div>
    )
  }
  if (name === 'TodoWrite' && Array.isArray(input.todos)) {
    return (
      <ul className="tx-tool__todos">
        {input.todos.map((t: any, i: number) => (
          <li key={i} className={`tx-tool__todo tx-tool__todo--${t.status}`}>
            {todoGlyph(t.status)} {t.content ?? t.activeForm ?? ''}
          </li>
        ))}
      </ul>
    )
  }
  return (
    <CollapsibleCode>
      <pre className="tx-tool__code tx-tool__code--generic">
        {truncateForPreview(JSON.stringify(input, null, 2), 1500)}
      </pre>
    </CollapsibleCode>
  )
}

function ToolResultBody({ block }: { block: TranscriptBlockForView }) {
  const text = block.toolResultText ?? ''
  if (!text) return null
  return (
    <div className="tx-tool__result">
      <div className="tx-tool__result-label">
        result{block.toolResultTruncated ? ' (truncated)' : ''}
      </div>
      <CollapsibleCode>
        <pre className="tx-tool__result-body">{text}</pre>
      </CollapsibleCode>
    </div>
  )
}

const COLLAPSIBLE_DEFAULT_LINES = 6

function CollapsibleCode({
  children,
  maxLines = COLLAPSIBLE_DEFAULT_LINES,
  className,
}: {
  children: ReactNode
  maxLines?: number
  className?: string
}) {
  const [open, setOpen] = useState(false)
  const [overflows, setOverflows] = useState(false)
  const [totalLines, setTotalLines] = useState<number | null>(null)
  const innerRef = useRef<HTMLDivElement | null>(null)

  useLayoutEffect(() => {
    const el = innerRef.current
    if (!el) return
    const pre = el.querySelector('pre, code') as HTMLElement | null
    const target = pre ?? el
    const cs = getComputedStyle(target)
    const lineHeight = parseFloat(cs.lineHeight)
    if (!isFinite(lineHeight) || lineHeight <= 0) {
      setOverflows(false); setTotalLines(null); return
    }
    const maxH = lineHeight * maxLines
    setOverflows(target.scrollHeight > maxH + 2)
    setTotalLines(Math.max(1, Math.round(target.scrollHeight / lineHeight)))
  }, [children, maxLines])

  return (
    <div
      ref={innerRef}
      className={
        'tx-collapsible' +
        (open ? ' tx-collapsible--open' : '') +
        (overflows ? ' tx-collapsible--overflows' : '') +
        (className ? ' ' + className : '')
      }
      style={{ ['--tx-col-max-lines' as any]: String(maxLines) }}
    >
      {children}
      {overflows && (
        <button
          type="button"
          className="tx-collapsible__toggle"
          onClick={() => setOpen((v) => !v)}
        >
          {open
            ? '▾ Show less'
            : `▸ Show all${totalLines ? ` (${totalLines} lines)` : ''}`}
        </button>
      )}
    </div>
  )
}

const DiffView = memo(function DiffView({ oldStr, newStr }: { oldStr: string; newStr: string }) {
  return (
    <div className="tx-tool__diff-wrap">
      <ReactDiffViewer
        oldValue={oldStr}
        newValue={newStr}
        splitView={false}
        useDarkTheme
        showDiffOnly
        hideLineNumbers={false}
        styles={{
          variables: {
            dark: {
              diffViewerBackground: '#0B0D14',
              diffViewerColor: '#DDE1EA',
              addedBackground: 'rgba(34,197,94,0.12)',
              addedColor: '#86EFAC',
              removedBackground: 'rgba(239,68,68,0.12)',
              removedColor: '#FCA5A5',
              wordAddedBackground: 'rgba(34,197,94,0.28)',
              wordRemovedBackground: 'rgba(239,68,68,0.28)',
              addedGutterBackground: 'rgba(34,197,94,0.18)',
              removedGutterBackground: 'rgba(239,68,68,0.18)',
              gutterBackground: '#10131C',
              gutterColor: '#4B5367',
              codeFoldGutterBackground: '#10131C',
              codeFoldBackground: '#10131C',
              emptyLineBackground: '#0B0D14',
            },
          },
          contentText: { fontSize: 11, fontFamily: 'var(--mono, ui-monospace, Menlo, monospace)' },
          line: { padding: '1px 0' },
          gutter: { padding: '0 6px', minWidth: 24 },
        }}
      />
    </div>
  )
})

// ─── helpers ──────────────────────────────────────────────────────────────

function blockMatchesQuery(b: TranscriptBlockForView, q: string): boolean {
  if (b.type === 'text' || b.type === 'thinking') return (b.text ?? '').toLowerCase().includes(q)
  if (b.type === 'tool_use') {
    if ((b.toolName ?? '').toLowerCase().includes(q)) return true
    if ((b.toolInputJSON ?? '').toLowerCase().includes(q)) return true
    return false
  }
  if (b.type === 'tool_result') return (b.toolResultText ?? '').toLowerCase().includes(q)
  return false
}

function safeParse(s: string | undefined): Record<string, any> | null {
  if (!s) return null
  try { return JSON.parse(s) } catch { return null }
}

function toolIcon(name: string): string {
  const map: Record<string, string> = {
    Bash: '$', Read: '📄', Write: '✏️', Edit: '✂', MultiEdit: '✂',
    Grep: '🔍', Glob: '📁', WebSearch: '🔎', WebFetch: '🌐',
    Agent: '🤖', Task: '🤖', TodoWrite: '☑', NotebookEdit: '📓',
  }
  return map[name] ?? '⚙'
}

function summarizeToolInput(name: string, input: Record<string, any>): string {
  if (name === 'Bash') return (input.description as string) ?? ''
  if (name === 'Read' || name === 'Write' || name === 'Edit' || name === 'MultiEdit') {
    const p = input.file_path as string | undefined
    return p ? p.split('/').slice(-2).join('/') : ''
  }
  if (name === 'Grep' || name === 'Glob') return (input.pattern as string) ?? ''
  if (name === 'Agent' || name === 'Task') return (input.description as string) ?? ''
  if (name === 'WebFetch') return (input.url as string) ?? ''
  if (name === 'WebSearch') return (input.query as string) ?? ''
  return ''
}

function todoGlyph(status: string): string {
  switch (status) {
    case 'completed': return '☑'
    case 'in_progress': return '◐'
    default: return '☐'
  }
}

function truncateForPreview(s: string, max: number): string {
  if (s.length <= max) return s
  return s.slice(0, max) + '\n…(truncated, ' + (s.length - max) + ' more chars)'
}
