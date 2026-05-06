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
import {
  Terminal as TerminalIcon,
  FileText,
  Pencil,
  Search,
  Folder,
  Globe,
  Bot,
  ListTodo,
  BookOpen,
  Settings as ToolFallbackIcon,
  ChevronRight,
  ChevronDown,
  Loader2,
  Diamond,
  Inbox as InjectedIcon,
  CheckSquare,
  Square,
  CircleDashed,
} from 'lucide-react'
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
  /** Live session status for the in-flight placeholder ("thinking" /
   *  "tooling" trigger a synthetic block at the tail; anything else
   *  hides it). The transcript file only catches up after PostToolUse /
   *  Stop hooks, so this gives the user something to watch in the
   *  meantime — same UX as Claude Code's native streaming view. */
  liveStatus?: string | null
  /** Tool currently running (only meaningful when liveStatus === 'tooling'). */
  liveCurrentTool?: string | null
  /** Optional one-line description of the current task / step. */
  liveCurrentTask?: string | null
  /** Optional controlled verbosity. If both `verbosity` and
   *  `onVerbosityChange` are provided, the in-search-bar segmented pill
   *  is hidden — parent owns the UI for it (e.g. meee2's Dock renders
   *  the pill in its ChatComposer's bottomLeft slot). When undefined,
   *  TranscriptView keeps its own pill + localStorage state, the
   *  original self-managed behavior. */
  verbosity?: TranscriptVerbosity
  onVerbosityChange?: (v: TranscriptVerbosity) => void
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
  return loadTranscriptVerbosity()
}

/// 给外部 owner 复用同一份 localStorage 存储——让 Dock 这种把 pill 渲在
/// 自己 toolbar 里、又想跟 TranscriptView 的 uncontrolled fallback 同 key 的
/// 场景能 hydrate / persist 同一个值。
export function loadTranscriptVerbosity(): TranscriptVerbosity {
  try {
    if (typeof localStorage === 'undefined') return 'normal'
    const v = localStorage.getItem(VERBOSITY_KEY)
    if (v === 'normal' || v === 'thinking' || v === 'verbose') return v
    // 迁移旧 showTools key（true → verbose, false → normal）
    const legacy = localStorage.getItem(LEGACY_TOOL_VIS_KEY)
    if (legacy === 'true') return 'verbose'
    if (legacy === 'false') return 'normal'
  } catch { /* ignore */ }
  return 'normal'
}

export function saveTranscriptVerbosity(v: TranscriptVerbosity): void {
  try {
    if (typeof localStorage === 'undefined') return
    localStorage.setItem(VERBOSITY_KEY, v)
    localStorage.removeItem(LEGACY_TOOL_VIS_KEY)
  } catch { /* ignore */ }
}

const DOCK_EXPANDED_KEY = 'meee2.dock.expanded.v1'

/// Dock 的"全屏 vs 底栏"展开状态——跨 session 切换共享一份偏好（用户希望
/// 在 A card 选 expanded 后，切到 B card 也保持 expanded）。
export function loadDockExpanded(fallback: boolean): boolean {
  try {
    if (typeof localStorage === 'undefined') return fallback
    const v = localStorage.getItem(DOCK_EXPANDED_KEY)
    if (v === 'true') return true
    if (v === 'false') return false
  } catch { /* ignore */ }
  return fallback
}

export function saveDockExpanded(v: boolean): void {
  try {
    if (typeof localStorage === 'undefined') return
    localStorage.setItem(DOCK_EXPANDED_KEY, v ? 'true' : 'false')
  } catch { /* ignore */ }
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

/// 稳定的合成 in-flight entry id —— 用 sentinel 不用 random，方便 virtualizer
/// 跨 render 复用同一个测量结果，不闪烁。
const LIVE_ENTRY_ID = '__live_in_flight__'

export function TranscriptView({
  entries,
  cacheKey,
  loading,
  error,
  refreshing,
  searchPlaceholder = 'Search in messages (tool name / text)…',
  liveStatus = null,
  liveCurrentTool = null,
  liveCurrentTask = null,
  verbosity: controlledVerbosity,
  onVerbosityChange,
}: TranscriptViewProps) {
  const initialCache = txCache.get(cacheKey)
  const [query, setQuery] = useState('')
  // Controlled vs uncontrolled verbosity. parent 既给 verbosity 又给
  // onVerbosityChange → 受控（隐藏自带 pill）。否则走 localStorage 自管。
  const isControlled = controlledVerbosity !== undefined && onVerbosityChange !== undefined
  const [internalVerbosity, setInternalVerbosity] = useState<TranscriptVerbosity>(loadVerbosity)
  const verbosity = isControlled ? controlledVerbosity : internalVerbosity
  const setVerbosity = (v: TranscriptVerbosity) => {
    if (isControlled) {
      onVerbosityChange!(v)
    } else {
      setInternalVerbosity(v)
    }
  }

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

  // Persist verbosity (uncontrolled mode only — controlled mode的
  // 持久化由 parent 负责，避免双方同时往 localStorage 写造成 race)
  useEffect(() => {
    if (isControlled) return
    try {
      localStorage.setItem(VERBOSITY_KEY, internalVerbosity)
      localStorage.removeItem(LEGACY_TOOL_VIS_KEY)
    } catch { /* ignore */ }
  }, [internalVerbosity, isControlled])

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

  // 按 verbosity 过滤 blocks + 丢弃纯 tool_result 的 user entry（orphan）。
  //
  // 三档语义（和 Claude Code 自带视图对齐）：
  //   normal:   text + tool_use（折叠成 summary 一行，点 ▸ 展开）
  //   thinking: 同 normal，再加 thinking 块（默认折叠）
  //   verbose:  全部块都保留 + tool_use 默认展开（点击可手动收起）
  //
  // tool_use 在所有模式都展示——只是默认展开 / 折叠状态不一样（由
  // EntryRow 渲染时根据 verbosity 决定）。tool_result 也都保留（极少落
  // 在 assistant entry 上，但保留以备 orphan 渲染）。
  //
  // 末尾根据 liveStatus 合成一条 in-flight 占位 entry（实时 toolcall 进度，
  // 模仿 Claude Code 自带的 streaming 渲染）。覆盖三种状态：
  //   tooling:  显示当前在跑的 tool 名 + spinner
  //   thinking: 显示 "Thinking…" 脉冲块
  //   else:     不合成
  // De-dup：search 中（query 非空）不合成。
  const visibleEntries = useMemo(() => {
    const out: TranscriptEntryForView[] = []
    for (const e of filteredEntries) {
      const isPureOrphan =
        e.type === 'user' && e.blocks.every((b) => b.type === 'tool_result')
      if (isPureOrphan) continue
      const kept = e.blocks.filter((b) => {
        if (b.type === 'text') return true
        if (b.type === 'thinking') return verbosity !== 'normal'
        if (b.type === 'tool_use') return true
        if (b.type === 'tool_result') return true
        return false
      })
      if (kept.length === 0) continue

      // Cross-entry tool-run 拼接：claude 经常拆 turn 成多条 assistant
      // entry（text + tool_use_A → 看 tool_result_A → 接 tool_use_B + ...）
      // 我们想把"上一条 entry 结尾的 tool_use"和"这条 entry 开头的 tool_use"
      // 视为同一连续 run，让 EntryRow 内部的 per-entry grouping 把它们一
      // 起 rollup。具体做法是把这条 entry 的 blocks 直接 splice 到上一条
      // 末尾——前提是两条都是 assistant entry，prev 末块是 tool_use，
      // current 首块是 tool_use（中间允许多 tool_use 和 text 混合，但起
      // 接缝两侧必须是 tool_use 才是真"continuation"）。
      const prev = out[out.length - 1]
      const isAssistant = e.type === 'assistant'
      const prevIsAssistant = prev?.type === 'assistant'
      const prevEndsWithTool = prev && prev.blocks[prev.blocks.length - 1]?.type === 'tool_use'
      const currStartsWithTool = kept[0]?.type === 'tool_use'
      if (
        isAssistant && prevIsAssistant && prevEndsWithTool && currStartsWithTool
      ) {
        out[out.length - 1] = { ...prev, blocks: [...prev.blocks, ...kept] }
        continue
      }

      // 连续的同类 user/injected 条目合并成一个气泡：用户在 Dock/终端连发
      // 多条而 Claude 还没回的情况下，原版会渲染成 N 个独立 "You" 卡片，
      // 视觉上既冗余又像系统漏处理。合并后变成一个气泡里多段文字，跟
      // 大多数 chat UI 的"用户连发"行为对齐。
      if (prev && prev.type === e.type && (e.type === 'user' || e.type === 'injected')) {
        out[out.length - 1] = { ...prev, blocks: [...prev.blocks, ...kept] }
        continue
      }

      out.push({ ...e, blocks: kept })
    }

    // ── 合成 in-flight entry ─────────────────────────────────────────
    if (query.trim()) return out  // search 中不混入合成条目，避免污染计数
    if (
      liveStatus !== 'tooling' &&
      liveStatus !== 'thinking' &&
      liveStatus !== 'permissionRequired'
    ) return out

    // 不做 toolName-based dedup —— 之前用 lastToolUse.toolName === liveCurrentTool
    // 来吞掉 PostToolUse 写完但 status 还没翻 idle 的瞬态，但 toolName 重复
    // 太常见（多轮 Bash 是日常），会把新的 in-flight 完全藏掉。Codex review
    // P2 的合理告诫。
    //
    // 现在的语义：liveStatus 是 tooling 就显示占位 —— 哪怕历史最后一条
    // entry 也是 Bash，"刚跑完 + 现在又跑一个" 在多步 turn 里是真实情况，
    // 两个块同时显示不算冲突，反而准确。占位条目有 tx-entry--live 视觉标记
    // 跟历史块区分得清楚。

    if (liveStatus === 'tooling' && liveCurrentTool) {
      out.push({
        id: LIVE_ENTRY_ID,
        type: 'assistant',
        timestamp: null,
        blocks: [
          {
            type: 'tool_use',
            toolName: liveCurrentTool,
            toolInputJSON: undefined,
            toolId: '__live__',
          },
        ],
      })
    } else if (liveStatus === 'thinking') {
      out.push({
        id: LIVE_ENTRY_ID,
        type: 'assistant',
        timestamp: null,
        blocks: [
          {
            type: 'text',
            text: liveCurrentTask || 'Thinking…',
          },
        ],
      })
    } else if (liveStatus === 'permissionRequired') {
      // Claude 在等用户在 terminal 里点 y/n 批准 tool 调用——transcript 文件
      // 还没把这一刻写进去（写要等 PostToolUse），但 UI 不能让用户盯着空。
      // 用一条带 attention 颜色的合成 entry 提示"等你点"。
      out.push({
        id: LIVE_ENTRY_ID,
        type: 'assistant',
        timestamp: null,
        blocks: [
          {
            type: 'text',
            text: liveCurrentTool
              ? `Waiting for permission to use ${liveCurrentTool}…`
              : 'Waiting for permission…',
          },
        ],
      })
    }
    return out
  }, [filteredEntries, verbosity, query, liveStatus, liveCurrentTool, liveCurrentTask])

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
        {!isControlled && (
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
        )}
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
                      isLive={e.id === LIVE_ENTRY_ID}
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
  isLive = false,
}: {
  entry: TranscriptEntryForView
  resultsByToolUseId: Map<string, TranscriptBlockForView>
  hideRoleChip: boolean
  verbosity: TranscriptVerbosity
  /** Synthetic in-flight entry — render with pending visual state. */
  isLive?: boolean
}) {
  let renderedFirstText = false

  // 历史 toolcall 折叠：连续 ≥1 个 tool_use 都用 ToolGroupBlock 包起来——
  // 这样单 tool 跟多 tool 视觉一模一样（同一个 chip 形状，summary 不同）。
  // 单 tool 时 summary 是"Edited X.tsx" / "Read Y.swift" / "Ran git status"
  // 这种"动词 + 对象"形式，多 tool 时是"Edited 3 files, ran a command"
  // 这种聚合形式（见 summarizeToolBlocks）。Live 占位 entry 维持原有的
  // PendingToolUseBlock 走绿色 chip。
  const renderItems = (() => {
    if (isLive) return entry.blocks.map((b, i) => ({ kind: 'block' as const, block: b, index: i }))
    type Item =
      | { kind: 'block'; block: TranscriptBlockForView; index: number }
      | { kind: 'tool-group'; blocks: TranscriptBlockForView[]; startIndex: number }
    const out: Item[] = []
    let i = 0
    while (i < entry.blocks.length) {
      const b = entry.blocks[i]
      if (b.type === 'tool_use') {
        // 收集连续的 tool_use
        let j = i
        const run: TranscriptBlockForView[] = []
        while (j < entry.blocks.length && entry.blocks[j].type === 'tool_use') {
          run.push(entry.blocks[j])
          j += 1
        }
        out.push({ kind: 'tool-group', blocks: run, startIndex: i })
        i = j
      } else {
        out.push({ kind: 'block', block: b, index: i })
        i += 1
      }
    }
    return out
  })()

  return (
    <div className={`tx-entry tx-entry--${entry.type}${hideRoleChip ? ' tx-entry--merged' : ''}${isLive ? ' tx-entry--live' : ''}`}>
      {renderItems.map((item, idx) => {
        if (item.kind === 'tool-group') {
          return (
            <ToolGroupBlock
              key={`tg-${item.startIndex}`}
              blocks={item.blocks}
              resultsByToolUseId={resultsByToolUseId}
              defaultOpen={verbosity === 'verbose'}
            />
          )
        }
        const b = item.block
        const i = item.index
        switch (b.type) {
          case 'text': {
            const hideLabel = hideRoleChip || renderedFirstText
            renderedFirstText = true
            return (
              <TextBlock
                key={i}
                role={entry.type}
                text={b.text ?? ''}
                hideLabel={hideLabel}
                isPending={isLive}
              />
            )
          }
          case 'thinking':
            return <ThinkingBlock key={i} text={b.text ?? ''} forceOpen={verbosity === 'verbose'} />
          case 'tool_use':
            // 非 isLive 路径不会走到这里——renderItems pre-pass 把所有
            // tool_use（包括单条）都打包成 'tool-group' item 了。这里只
            // 处理 isLive 占位的合成 entry（liveStatus === 'tooling'），
            // 它直接用 PendingToolUseBlock 走 in-flight 绿色 chip。
            return <PendingToolUseBlock key={i} toolName={b.toolName ?? 'Tool'} />
          case 'tool_result':
            return <OrphanToolResult key={i} block={b} />
          default:
            return null
        }
      })}
    </div>
  )
}

// ─── tool group rollup ────────────────────────────────────────────────────

/// 多个连续 tool_use 折叠成单条摘要。模仿 Claude Code 自带 "Ran 3 commands,
/// read 2 files" 的视觉。点开后逐条展示完整 ToolUseBlock。
function ToolGroupBlock({
  blocks,
  resultsByToolUseId,
  defaultOpen = false,
}: {
  blocks: TranscriptBlockForView[]
  resultsByToolUseId: Map<string, TranscriptBlockForView>
  defaultOpen?: boolean
}) {
  const [open, setOpen] = useState(defaultOpen)
  const summary = summarizeToolBlocks(blocks)
  return (
    <div className={`tx-tool-group${open ? ' tx-tool-group--open' : ''}`}>
      <button
        type="button"
        className="tx-tool-group__header"
        onClick={() => setOpen(!open)}
        aria-expanded={open}
      >
        <span className="tx-tool-group__chevron" aria-hidden>
          {open ? <ChevronDown size={12} /> : <ChevronRight size={12} />}
        </span>
        <span className="tx-tool-group__summary">{summary}</span>
      </button>
      {open && (
        <div className="tx-tool-group__body">
          {blocks.map((b, i) => (
            <ToolUseBlock
              key={i}
              block={b}
              result={b.toolId ? resultsByToolUseId.get(b.toolId) : undefined}
              defaultOpen
            />
          ))}
        </div>
      )}
    </div>
  )
}

/// 把一组 tool_use 块按工具类别归并成一句人话。
///
/// 单条特殊处理（match Claude Code 自带视图）：直接说"动词 + 对象"，
/// 不用 generic "Edited 1 file"——
///   - Bash         → "Ran <command>" （cmd 截到 60 字符）
///   - Edit/MultiEdit/Write → "Edited <basename>"
///   - Read         → "Read <basename>"
///   - Grep         → "Searched for \"<pattern>\""
///   - Glob         → "Listed <pattern>"
///
/// 多条按桶聚合：
///   - Bash / BashOutput     → "ran N command(s)"
///   - Read                  → "read N file(s)"
///   - Edit / MultiEdit /
///     Write                 → "edited N file(s)"
///   - Grep / Glob           → "searched N time(s)"
///   - 其它                  → "called N <toolName>"（按 toolName 分桶）
/// 输出例子：「Ran 2 commands, read 3 files, edited 1 file」
function summarizeToolBlocks(blocks: TranscriptBlockForView[]): string {
  if (blocks.length === 1) {
    return summarizeSingleTool(blocks[0])
  }
  const buckets: { ran: number; read: number; edited: number; searched: number; other: Map<string, number> } = {
    ran: 0,
    read: 0,
    edited: 0,
    searched: 0,
    other: new Map(),
  }
  for (const b of blocks) {
    const name = b.toolName ?? ''
    switch (name) {
      case 'Bash':
      case 'BashOutput':
        buckets.ran += 1
        break
      case 'Read':
        buckets.read += 1
        break
      case 'Edit':
      case 'MultiEdit':
      case 'Write':
        buckets.edited += 1
        break
      case 'Grep':
      case 'Glob':
        buckets.searched += 1
        break
      default: {
        const key = name || 'tool'
        buckets.other.set(key, (buckets.other.get(key) ?? 0) + 1)
      }
    }
  }
  const parts: string[] = []
  // 第一个分句首字母大写（"Ran 2 commands"），后续小写衔接（"read 3 files"）
  const verbs: Array<[number, string]> = [
    [buckets.ran, 'command'],
    [buckets.read, 'file'],
    [buckets.edited, 'file'],
    [buckets.searched, 'search'],
  ]
  const verbWords = ['Ran', 'read', 'edited', 'searched']
  for (let i = 0; i < verbs.length; i++) {
    const [count, noun] = verbs[i]
    if (count === 0) continue
    const verb = parts.length === 0 ? verbWords[i] : verbWords[i].toLowerCase()
    const verbCapitalized = parts.length === 0
      ? verb.charAt(0).toUpperCase() + verb.slice(1)
      : verb
    parts.push(`${verbCapitalized} ${count} ${noun}${count !== 1 ? 's' : ''}`)
  }
  for (const [name, count] of buckets.other) {
    const verbHead = parts.length === 0 ? 'Called' : 'called'
    parts.push(`${verbHead} ${count} ${name}${count !== 1 ? 's' : ''}`)
  }
  if (parts.length === 0) return `${blocks.length} tool calls`
  return parts.join(', ')
}

/// 单 tool 的"动词 + 对象"摘要，用在 ToolGroupBlock header 当 summary 文字。
/// 设计意图：跟 Claude Code 自带视图一致，单 tool 显示具体在干啥的最相关
/// 信息（filename / command），不重复显示 tool 名（Edit/Read/Bash 太冗）。
function summarizeSingleTool(b: TranscriptBlockForView): string {
  const name = b.toolName ?? 'Tool'
  const input = safeParse(b.toolInputJSON) ?? {}
  const trim = (s: string, n: number) => (s.length <= n ? s : s.slice(0, n).trimEnd() + '…')
  const basename = (p: string) => p.split('/').pop() || p
  switch (name) {
    case 'Bash':
    case 'BashOutput': {
      const cmd = (input.command as string) ?? ''
      return cmd ? `Ran ${trim(cmd, 70)}` : 'Ran command'
    }
    case 'Edit':
    case 'MultiEdit':
    case 'Write': {
      const path = (input.file_path as string) ?? ''
      return path ? `Edited ${basename(path)}` : 'Edited file'
    }
    case 'Read': {
      const path = (input.file_path as string) ?? ''
      return path ? `Read ${basename(path)}` : 'Read file'
    }
    case 'Grep': {
      const pat = (input.pattern as string) ?? ''
      return pat ? `Searched for "${trim(pat, 40)}"` : 'Searched'
    }
    case 'Glob': {
      const pat = (input.pattern as string) ?? ''
      return pat ? `Listed ${trim(pat, 40)}` : 'Listed files'
    }
    case 'WebFetch': {
      const url = (input.url as string) ?? ''
      return url ? `Fetched ${trim(url, 60)}` : 'Fetched URL'
    }
    case 'WebSearch': {
      const q = (input.query as string) ?? ''
      return q ? `Searched web for "${trim(q, 40)}"` : 'Searched web'
    }
    default: return name
  }
}

const TextBlock = memo(function TextBlock({
  role,
  text,
  hideLabel,
  isPending = false,
}: {
  role: string
  text: string
  hideLabel?: boolean
  /** When true, render with the live in-flight visual state (pulsing
   *  three-dot suffix for the "Thinking…" placeholder). */
  isPending?: boolean
}) {
  const isAssistant = role === 'assistant'
  const isUser = role === 'user'
  const isInjected = role === 'injected'
  // Injected 行用 lucide Inbox icon + "Injected" 文字代替 emoji 前缀。
  const roleLabel: ReactNode = isInjected
    ? (<><InjectedIcon size={11} aria-hidden /> Injected</>)
    : isUser ? 'You' : isAssistant ? 'Claude' : role
  const cls = isInjected
    ? 'tx-text--injected'
    : isUser ? 'tx-text--user' : isAssistant ? 'tx-text--assistant' : 'tx-text--other'
  return (
    <div className={`tx-text ${cls}${hideLabel ? ' tx-text--merged' : ''}${isPending ? ' tx-text--pending' : ''}`}>
      {!hideLabel && (
        <div className="tx-text__role">
          {isAssistant && <span className="tx-text__role-glyph" aria-hidden><Diamond size={11} /></span>}
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
        {open ? <ChevronDown size={11} aria-hidden /> : <ChevronRight size={11} aria-hidden />} thinking
      </button>
      {open && <div className="tx-thinking__body">{text}</div>}
    </div>
  )
}

/// 单个 tool_use 块，跟 Claude Code 本体一样 collapsible：
///   - Header: icon + name + summary（"Bash · ./scripts/validate.sh"）+ 末尾 chevron
///   - Body:   ToolInputBody + ToolResultBody（input 详情 + result 输出）
/// `defaultOpen` 默认 false（normal/thinking 折叠成一行）；verbose 模式 EntryRow
/// 会传 true 让所有 tool 默认展开。Header 整条点击 toggle —— 因此样式上
/// 把它从 div 升级成 button 给键盘可达 + cursor:pointer。
function ToolUseBlock({
  block,
  result,
  defaultOpen = false,
}: {
  block: TranscriptBlockForView
  result: TranscriptBlockForView | undefined
  defaultOpen?: boolean
}) {
  const [open, setOpen] = useState(defaultOpen)
  const name = block.toolName ?? 'Tool'
  const input = safeParse(block.toolInputJSON) ?? {}
  return (
    <div className={`tx-tool${open ? ' tx-tool--open' : ' tx-tool--collapsed'}`}>
      <button
        type="button"
        className="tx-tool__header"
        onClick={() => setOpen(!open)}
        aria-expanded={open}
      >
        <span className="tx-tool__icon"><ToolIcon name={name} /></span>
        <span className="tx-tool__name">{name}</span>
        <span className="tx-tool__summary">{summarizeToolInput(name, input)}</span>
        <span className="tx-tool__chevron" aria-hidden>
          {open ? <ChevronDown size={12} /> : <ChevronRight size={12} />}
        </span>
      </button>
      {open && (
        <div className="tx-tool__body">
          <ToolInputBody name={name} input={input} />
          {result && <ToolResultBody block={result} />}
        </div>
      )}
    </div>
  )
}

/// In-flight tool_use 占位：单行 chip 视觉，跟历史 rollup 同一级（don't
/// expand into a full tool block with input / result chrome since both are
/// pending）。一旦 PostToolUse 把真 entry 写进 jsonl + status 翻 idle，这条
/// 会被替换成正式的 ToolUseBlock。
function PendingToolUseBlock({ toolName }: { toolName: string }) {
  return (
    <div className="tx-tool-pending">
      <span className="tx-tool-pending__icon"><ToolIcon name={toolName} /></span>
      <span className="tx-tool-pending__label">{toolName}</span>
      <span className="tx-tool-pending__spinner" aria-hidden />
      <span className="tx-tool-pending__caption">running…</span>
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
            <TodoGlyph status={t.status} /> {t.content ?? t.activeForm ?? ''}
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

/// Lucide icon component for a given tool name. Renders a small (size:12)
/// icon. Pass `name` lowercased or as recorded — case-sensitive against the
/// Claude CLI tool registry (Bash, Read, Edit, MultiEdit, Write, Grep, Glob,
/// WebFetch, WebSearch, Agent / Task, TodoWrite, NotebookEdit). Unknown
/// tools fall back to ToolFallbackIcon.
function ToolIcon({ name, size = 12 }: { name: string; size?: number }) {
  const props = { size, 'aria-hidden': true } as const
  switch (name) {
    case 'Bash':
    case 'BashOutput':
      return <TerminalIcon {...props} />
    case 'Read':
      return <FileText {...props} />
    case 'Edit':
    case 'MultiEdit':
    case 'Write':
    case 'NotebookEdit':
      return <Pencil {...props} />
    case 'Grep':
    case 'WebSearch':
      return <Search {...props} />
    case 'Glob':
      return <Folder {...props} />
    case 'WebFetch':
      return <Globe {...props} />
    case 'Agent':
    case 'Task':
      return <Bot {...props} />
    case 'TodoWrite':
      return <ListTodo {...props} />
    default:
      return <ToolFallbackIcon {...props} />
  }
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

/// Lucide icon for a todo entry. Used in TodoWrite tool result rendering.
/// Returns a sized React node so it can be inline-prefixed to the text.
function TodoGlyph({ status }: { status: string }) {
  const props = { size: 11, 'aria-hidden': true } as const
  switch (status) {
    case 'completed':
      return <CheckSquare {...props} />
    case 'in_progress':
      return <CircleDashed {...props} />
    default:
      return <Square {...props} />
  }
}

function truncateForPreview(s: string, max: number): string {
  if (s.length <= max) return s
  return s.slice(0, max) + '\n…(truncated, ' + (s.length - max) + ' more chars)'
}
