import { memo, useEffect, useMemo, useRef, useState, useCallback } from 'react'
import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import rehypeHighlight from 'rehype-highlight'
import ReactDiffViewer from 'react-diff-viewer-continued'
import { useVirtualizer } from '@tanstack/react-virtual'

// 暗色 syntax-highlight theme（只在这个组件挂载时生效，但实际上 CSS 是全局注入的，
// 所以一次加载即全局可用——无副作用）
import 'highlight.js/styles/github-dark.css'

import type { TranscriptBlock, TranscriptEntryFull } from '../api'
import { fetchTranscript } from '../api'

interface Props {
  sessionId: string
  /** 任何引用变化都会触发 debounced refetch（用于 WS state.changed 驱动） */
  refreshTrigger?: unknown
  /** 轮询间隔（fallback 兜底）；0 关闭 */
  pollMs?: number
  /** 最新 N 条；0/undefined = 全部 */
  limit?: number
}

// ─── 模块级缓存 ──────────────────────────────────────────────────────────
// 切换 session 后再切回来：不希望再看到 "Loading transcript…"、不希望从头重拉、
// 也不希望卷回顶部。把 entries + signature + scrollTop + 是否贴底保留在
// Map<sessionId, …> 里，组件挂载时直接种回去。
interface TxCacheEntry {
  entries: TranscriptEntryFull[]
  signature: string
  scrollTop: number
  stickyBottom: boolean
  /** 上一次真正看到的最末 entry id —— 重挂时用来判断有没有新消息 */
  lastSeenEntryId: string | null
}
const txCache = new Map<string, TxCacheEntry>()

/** 隐藏 tool_use / tool_result 的开关持久化；会话之间共享，用户不用每次点 */
const TOOL_VIS_KEY = 'meee2.transcript.showTools.v1'
function loadShowTools(): boolean {
  try {
    const v = localStorage.getItem(TOOL_VIS_KEY)
    if (v === 'true') return true
    if (v === 'false') return false
  } catch { /* ignore */ }
  return false  // 默认隐藏工具调用：只保留用户/Claude 的文字对话
}

/**
 * 富 transcript 面板。
 *
 * - Markdown：assistant text 块走 react-markdown + remark-gfm + rehype-highlight（代码
 *   块高亮用 github-dark）
 * - Diff：Edit / MultiEdit 走 react-diff-viewer-continued（dark theme, unified view）
 * - 增量刷新：listen `refreshTrigger`（由 SessionDetail 从 useBoardState.state 传入），
 *   debounce 500ms 再拉；同时 pollMs 兜底
 * - 虚拟滚动：@tanstack/react-virtual dynamic measurement
 * - 搜索：顶部输入框，对 tool 名 / 文本做子串匹配
 */
export default function TranscriptPanel({
  sessionId,
  refreshTrigger,
  pollMs = 10_000,
  limit,
}: Props) {
  // 命中缓存：entries / signature / scroll 位置全部种回去，loaded 直接 true
  const initialCache = txCache.get(sessionId)
  const [entries, setEntries] = useState<TranscriptEntryFull[]>(
    initialCache?.entries ?? [],
  )
  const [error, setError] = useState<string | null>(null)
  const [loaded, setLoaded] = useState<boolean>(initialCache != null)
  // `fetching` 独立于 `loaded`：只有当 fetch 超过 500ms 仍未完成才翻 true，
  // 正常 poll 的 200-300ms 不会点亮 refreshing 灯。否则用户一直看到 spinner
  // 在转，以为数据有问题——实际上只是后台定期 poll。
  const [fetching, setFetching] = useState<boolean>(false)
  const [query, setQuery] = useState('')
  const [showTools, setShowTools] = useState<boolean>(loadShowTools)

  const parentRef = useRef<HTMLDivElement | null>(null)
  const stickToBottomRef = useRef(initialCache?.stickyBottom ?? true)
  const lastEntryIdRef = useRef<string | null>(initialCache?.lastSeenEntryId ?? null)
  // 待还原的 scrollTop —— 命中缓存时挂载后 rAF 里消费一次
  const pendingScrollTopRef = useRef<number | null>(
    initialCache ? initialCache.scrollTop : null,
  )

  // session 切换：保存当前 session 到 cache（通过 effect cleanup，老 sessionId 在闭包里），
  // 进入新 session 时 setState 成新 session 的缓存值
  useEffect(() => {
    const id = sessionId
    const seeded = txCache.get(id)
    setEntries(seeded?.entries ?? [])
    setError(null)
    setLoaded(seeded != null)
    setQuery('')
    lastEntryIdRef.current = seeded?.lastSeenEntryId ?? null
    stickToBottomRef.current = seeded?.stickyBottom ?? true
    pendingScrollTopRef.current = seeded ? seeded.scrollTop : null
    lastSignatureRef.current = seeded?.signature ?? ''

    return () => {
      // 离开当前 session 时记录 scrollTop / stickyBottom，entries 由 fetch 路径持续写回
      const el = parentRef.current
      const cur = txCache.get(id)
      if (!cur) return
      txCache.set(id, {
        ...cur,
        scrollTop: el?.scrollTop ?? cur.scrollTop,
        stickyBottom: stickToBottomRef.current,
      })
    }
  }, [sessionId])

  // showTools 持久化
  useEffect(() => {
    try { localStorage.setItem(TOOL_VIS_KEY, showTools ? 'true' : 'false') } catch { /* ignore */ }
  }, [showTools])

  // 稳定的 fetch + "只有数据真的变了才 setState"，避免每次 WS tick 都触发
  // 整棵树（ReactMarkdown/ReactDiffViewer/virtualizer re-measure）重算
  const lastSignatureRef = useRef<string>(initialCache?.signature ?? '')
  const load = useCallback(async () => {
    // 500ms 内完成不点亮 refreshing 灯 —— 避免 poll 频率 × 正常 fetch 耗时造成的
    // 持续闪烁感。超 500ms 还没回来才翻 true（说明后端确实慢）。
    const slowTimer = window.setTimeout(() => setFetching(true), 500)
    try {
      const r = await fetchTranscript(sessionId, { limit })
      // 轻量指纹：entries 数 + 最后一条的 id + 最后一条最后一个 block 的 text/result 长度
      // 足以检测"有新消息到达"或"工具结果追加"这两种真变化
      const last = r.entries[r.entries.length - 1]
      const lastBlock = last?.blocks[last.blocks.length - 1]
      const sig =
        r.entries.length +
        '|' + (last?.id ?? '') +
        '|' + (lastBlock?.type ?? '') +
        '|' + ((lastBlock?.text ?? lastBlock?.toolResultText ?? '').length)
      if (sig !== lastSignatureRef.current) {
        lastSignatureRef.current = sig
        setEntries(r.entries)
      }
      // 永远写回 cache（即使 sig 没变，也要刷新 scrollTop/stickyBottom）
      const prev = txCache.get(sessionId)
      txCache.set(sessionId, {
        entries: r.entries,
        signature: sig,
        scrollTop: prev?.scrollTop ?? 0,
        stickyBottom: prev?.stickyBottom ?? true,
        lastSeenEntryId: last?.id ?? null,
      })
      setError(null)
      setLoaded(true)
    } catch (e) {
      setError((e as Error).message || 'Failed to load transcript')
      setLoaded(true)
    } finally {
      window.clearTimeout(slowTimer)
      setFetching(false)
    }
  }, [sessionId, limit])

  // 首次加载 + pollMs 兜底
  useEffect(() => {
    void load()
    if (!pollMs) return
    const h = window.setInterval(load, pollMs)
    return () => window.clearInterval(h)
  }, [load, pollMs])

  // WS trigger → debounce 1500ms refetch（用户正在跟 Claude 互动时 WS 会 1/s 推
  // state.changed，短 debounce 会让大 transcript 的 session 每秒都 re-render）
  useEffect(() => {
    if (refreshTrigger === undefined) return
    const h = window.setTimeout(load, 1500)
    return () => window.clearTimeout(h)
  }, [refreshTrigger, load])

  // 过滤
  const filteredEntries = useMemo(() => {
    if (!query.trim()) return entries
    const q = query.toLowerCase()
    return entries.filter((e) =>
      e.blocks.some((b) => blockMatchesQuery(b, q)),
    )
  }, [entries, query])

  // 索引 tool_result 给 tool_use 配对
  const resultsByToolUseId = useMemo(() => {
    const m = new Map<string, TranscriptBlock>()
    for (const e of entries) {
      for (const b of e.blocks) {
        if (b.type === 'tool_result' && b.toolUseId) {
          m.set(b.toolUseId, b)
        }
      }
    }
    return m
  }, [entries])

  // 两条过滤规则合在一起：
  //   1. 永远丢掉"纯 tool_result"的 user entry（这些由上一条 tool_use 内嵌显示）
  //   2. showTools=false 时，把 tool_use / tool_result block 从每个 entry 里剥掉；
  //      剥空的 entry 整条丢掉
  const visibleEntries = useMemo(() => {
    const out: TranscriptEntryFull[] = []
    for (const e of filteredEntries) {
      const isPureOrphan =
        e.type === 'user' && e.blocks.every((b) => b.type === 'tool_result')
      if (isPureOrphan) continue

      if (showTools) {
        out.push(e)
        continue
      }
      const kept = e.blocks.filter(
        (b) => b.type !== 'tool_use' && b.type !== 'tool_result',
      )
      if (kept.length === 0) continue
      out.push({ ...e, blocks: kept })
    }
    return out
  }, [filteredEntries, showTools])

  // 连续同角色合并：tool calls 隐藏后常见 assistant → assistant → assistant，
  // 每条都画 "◆ Claude" chip 就像盖章，噪声。把连续 run 里除首条外的 role
  // label 全部隐藏，但保留各自的竖条 / 气泡——视觉上仍是独立段落，只是
  // 说话人指示归并了一次。按 entry id 做 O(1) lookup，虚拟化时也稳定。
  const hideRoleChipFor = useMemo(() => {
    const set = new Set<string>()
    for (let i = 1; i < visibleEntries.length; i++) {
      if (visibleEntries[i].type === visibleEntries[i - 1].type) {
        set.add(visibleEntries[i].id)
      }
    }
    return set
  }, [visibleEntries])

  // 虚拟化
  // useFlushSync: false —— 默认 true 会在 measurement 回调里调 flushSync()，
  // 当回调发生在 commit 阶段时 React 会警告 "flushSync was called from inside
  // a lifecycle method"。关掉后走常规 rerender，没副作用。
  const virtualizer = useVirtualizer({
    count: visibleEntries.length,
    getScrollElement: () => parentRef.current,
    // 实测 transcript 条目（带 Markdown / 工具 diff）的典型高度远大于 140。
    // estimateSize 偏小 → 首渲染时 totalSize 严重偏小 → scrollTop = scrollHeight
    // 只能滚到"假的底部"，等 measurement 回填后真底部又远了一截。
    estimateSize: () => 280,
    overscan: 6,
    measureElement: (el) => el.getBoundingClientRect().height,
    // 用 entry.id 作为 measurement cache key。不加的话，新消息到达时
    // 虚拟化器会把"index 处的旧测量值"套到"同 index 的新 entry"上，
    // 新旧高度不等 → translateY 偏移累计错位 → 视觉上新消息和前一条重叠。
    getItemKey: (index) => visibleEntries[index]?.id ?? `idx-${index}`,
    useFlushSync: false,
  })

  // 是否贴底。既存在 ref 里（auto-scroll / cache 都读它，不需要 rerender），
  // 又存在 state 里（控制 "↓ Latest" 按钮显隐；React 的 setState 对相等值
  // 自动 bail-out，scroll 事件里 100/s 调也不会触发 rerender）。
  const [atBottom, setAtBottom] = useState(true)

  const handleScroll = () => {
    const el = parentRef.current
    if (!el) return
    const dist = el.scrollHeight - el.scrollTop - el.clientHeight
    const isAtB = dist < 40
    stickToBottomRef.current = isAtB
    setAtBottom(isAtB)
  }

  /**
   * 跳到最新一条消息。跟 auto-scroll effect 一样走 rAF poll + 高度收敛探测
   * （Markdown/Diff 异步 layout 要好几帧才稳），触达底部后回写 stickToBottom
   * 让后续新消息继续自动贴底。
   *
   * 性能：只在用户点按钮时 run 一次；rAF 循环上限 1.5s 或高度稳定 4 帧收工。
   */
  const scrollToBottom = useCallback(() => {
    if (visibleEntries.length === 0) return
    const targetIndex = visibleEntries.length - 1
    let lastHeight = -1
    let stableFrames = 0
    let raf = 0
    let cancelled = false
    const deadline = performance.now() + 1500
    const tick = () => {
      if (cancelled) return
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
    // fire-and-forget；没处理 cancel，因为这个回调只响应一次点击、不在 effect 里
    void raf
    void cancelled
  }, [visibleEntries.length, virtualizer])

  // 命中缓存时还原 scrollTop —— 组件重新挂载后 layout 刚出来就跳回上次位置，
  // 不要让用户每次切回来都从底部重新滚。只在 pendingScrollTopRef 非 null 时做
  // 一次，然后清空（后续新消息走下面的 auto-scroll 逻辑）。
  //
  // rAF 两次：第一次等 layout，第二次等 virtualizer dynamic measurement。
  useEffect(() => {
    const target = pendingScrollTopRef.current
    if (target == null) return
    pendingScrollTopRef.current = null
    // 如果上次是贴底的，交给下面的 auto-scroll effect 处理，别自己跳到旧 scrollTop
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
  }, [sessionId])

  // 新 entry 到达时 auto-scroll。首次加载必滚底（把用户带到最新消息），
  // 后续更新只在用户还停留在底部时才滚底（防止把他们正在翻看的历史冲掉）。
  //
  // 难点：虚拟化 measurement + Markdown / Diff 异步 layout 分好几帧才收敛，
  // 「只滚一次」会落空。这里用 rAF poll：
  //   每帧强制 scrollTop = scrollHeight，记录高度；高度连续 4 帧稳定就停，
  //   或到达硬超时（首次 2.5s、后续 1.2s）无论如何结束。
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

      // 直接把 scrollTop 推到底；virtualizer.scrollToIndex 同步它内部 range。
      node.scrollTop = node.scrollHeight
      virtualizer.scrollToIndex(targetIndex, { align: 'end' })

      const h = node.scrollHeight
      if (h === lastHeight) {
        stableFrames++
      } else {
        stableFrames = 0
        lastHeight = h
      }
      // 高度连续 4 帧不变 = layout 已收敛；或超时；否则继续 poll
      if (stableFrames >= 4 || performance.now() >= deadline) return
      raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)

    return () => {
      cancelled = true
      cancelAnimationFrame(raf)
    }
  }, [visibleEntries, virtualizer])

  if (!loaded) {
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
          placeholder="Search in terminal messages (tool name / text)…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Escape') {
              setQuery('')
              e.currentTarget.blur()
            }
          }}
        />
        <label className="transcript-search__toggle" title="Show tool_use / tool_result blocks">
          <input
            type="checkbox"
            checked={showTools}
            onChange={(e) => setShowTools(e.target.checked)}
          />
          <span>Tool calls</span>
        </label>
        <span className="transcript-search__count">
          {query
            ? `${filteredEntries.length}/${entries.length}`
            : `${entries.length} entries`}
        </span>
        {fetching && (
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
          <div
            ref={parentRef}
            className="transcript-panel"
            onScroll={handleScroll}
          >
            <div
              style={{
                height: totalH,
                width: '100%',
                position: 'relative',
              }}
            >
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
                    />
                  </div>
                )
              })}
            </div>
          </div>
          {/* 不在底部时显示跳到最新按钮；回到底部自动消失 */}
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
}: {
  entry: TranscriptEntryFull
  resultsByToolUseId: Map<string, TranscriptBlock>
  hideRoleChip: boolean
}) {
  // 同一 entry 里多个 text block 只有第一条显示 chip —— 同 entry 天然同角色
  let renderedFirstText = false
  return (
    <div className={`tx-entry tx-entry--${entry.type}${hideRoleChip ? ' tx-entry--merged' : ''}`}>
      {entry.blocks.map((b, i) => {
        switch (b.type) {
          case 'text': {
            // 跨 entry 合并（hideRoleChip）+ 同 entry 内连续 text 合并
            const hideLabel = hideRoleChip || renderedFirstText
            renderedFirstText = true
            return (
              <TextBlock
                key={i}
                role={entry.type}
                text={b.text ?? ''}
                hideLabel={hideLabel}
              />
            )
          }
          case 'thinking':
            return <ThinkingBlock key={i} text={b.text ?? ''} />
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

// ─── text block ───────────────────────────────────────────────────────────

// memo 意义：ReactMarkdown + rehype-highlight 是整个 transcript 里最贵的渲染。
// 每次 WS tick entries 数组都是新引用，子孙 component 默认会重新 render；但
// {role, text} 都是 primitive，string 比较走值相等 —— 只要 Claude 的这条文本
// 没变，memo 就能把整棵 markdown 树从 re-render 路径上摘掉。
const TextBlock = memo(function TextBlock({
  role,
  text,
  hideLabel,
}: {
  role: string
  text: string
  /** 同角色连续时抑制 "◆ Claude" / "You" chip，避免每条都盖个章 */
  hideLabel?: boolean
}) {
  const isAssistant = role === 'assistant'
  const isUser = role === 'user'
  const roleLabel = isUser ? 'You' : isAssistant ? 'Claude' : role
  const cls = isUser ? 'tx-text--user' : isAssistant ? 'tx-text--assistant' : 'tx-text--other'
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
              a: ({ node: _node, ...props }) => (
                <a {...props} target="_blank" rel="noopener noreferrer" />
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

function ThinkingBlock({ text }: { text: string }) {
  const [open, setOpen] = useState(false)
  return (
    <div className="tx-thinking">
      <button className="tx-thinking__toggle" onClick={() => setOpen(!open)}>
        {open ? '▾' : '▸'} thinking
      </button>
      {open && <div className="tx-thinking__body">{text}</div>}
    </div>
  )
}

// ─── tool use/result ──────────────────────────────────────────────────────

function ToolUseBlock({
  block,
  result,
}: {
  block: TranscriptBlock
  result: TranscriptBlock | undefined
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

function OrphanToolResult({ block }: { block: TranscriptBlock }) {
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

// ─── tool-input renderers ─────────────────────────────────────────────────

function ToolInputBody({
  name,
  input,
}: {
  name: string
  input: Record<string, any>
}) {
  if (name === 'Bash') {
    const cmd = typeof input.command === 'string' ? input.command : ''
    if (!cmd) return null
    return (
      <pre className="tx-tool__code tx-tool__code--bash">
        <span className="tx-tool__prompt">$ </span>
        {cmd}
      </pre>
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
      <pre className="tx-tool__code tx-tool__code--write">
        {truncateForPreview(content, 2000)}
      </pre>
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
          <div className="muted">
            subagent: <span className="mono">{String(input.subagent_type)}</span>
          </div>
        )}
        {input.description && (
          <div className="tx-tool__agent-desc">{String(input.description)}</div>
        )}
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
    <pre className="tx-tool__code tx-tool__code--generic">
      {truncateForPreview(JSON.stringify(input, null, 2), 1500)}
    </pre>
  )
}

function ToolResultBody({ block }: { block: TranscriptBlock }) {
  const text = block.toolResultText ?? ''
  const [open, setOpen] = useState(text.length < 600)
  if (!text) return null
  return (
    <div className="tx-tool__result">
      <button
        className="tx-tool__result-toggle"
        onClick={() => setOpen(!open)}
      >
        {open ? '▾' : '▸'} result{block.toolResultTruncated ? ' (truncated)' : ''}
      </button>
      {open && <pre className="tx-tool__result-body">{text}</pre>}
    </div>
  )
}

// ─── diff viewer wrapper ──────────────────────────────────────────────────

// memo 意义：ReactDiffViewer 对长文本 diff 递归建树，不便宜。{oldStr, newStr}
// 都是 string，WS tick 换 entries 时同内容 === 成立 → 默认 memo 直接 bail。
const DiffView = memo(function DiffView({ oldStr, newStr }: { oldStr: string; newStr: string }) {
  // 统一小号字体 + 暗色主题，unified view（不 split，sidebar 太窄）
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

function blockMatchesQuery(b: TranscriptBlock, q: string): boolean {
  if (b.type === 'text' || b.type === 'thinking') {
    return (b.text ?? '').toLowerCase().includes(q)
  }
  if (b.type === 'tool_use') {
    if ((b.toolName ?? '').toLowerCase().includes(q)) return true
    if ((b.toolInputJSON ?? '').toLowerCase().includes(q)) return true
    return false
  }
  if (b.type === 'tool_result') {
    return (b.toolResultText ?? '').toLowerCase().includes(q)
  }
  return false
}

function safeParse(s: string | undefined): Record<string, any> | null {
  if (!s) return null
  try {
    return JSON.parse(s)
  } catch {
    return null
  }
}

function toolIcon(name: string): string {
  const map: Record<string, string> = {
    Bash: '$',
    Read: '📄',
    Write: '✏️',
    Edit: '✂',
    MultiEdit: '✂',
    Grep: '🔍',
    Glob: '📁',
    WebSearch: '🔎',
    WebFetch: '🌐',
    Agent: '🤖',
    Task: '🤖',
    TodoWrite: '☑',
    NotebookEdit: '📓',
  }
  return map[name] ?? '⚙'
}

function summarizeToolInput(
  name: string,
  input: Record<string, any>,
): string {
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
