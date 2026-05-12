// 画板上的统一浮窗 —— 既是"现有 session 的 transcript + chat"
// （SessionDock 老定位），也是"全局 AI 助手对话"（AssistantChat 老定位）。
//
// 两种模式共享：
//   - 外壳（毛玻璃 + 圆角 + box-shadow）
//   - expanded / collapsed 切换 + 浮动 actions（⤡ × 两按钮）
//   - <ChatComposer> 输入区（textarea + send + attachments + bottombar）
//   - 键盘 seed handle（DockHandle.appendAndFocus 透传给 ChatComposer）
//   - .session-dock CSS 类
//
// 区别只在中间区 + onSend 业务：
//   mode='session'   → <TranscriptPanel /> + jump-back context only
//   mode='assistant' → 自渲 chat log + streamAssistantChat
//
// 所以 App.tsx 现在只挂一个 <Dock>（按 selection / assistantOpen 决定 mode），
// 旧的 SessionDock.tsx / AssistantChat.tsx 都被它替代。

import {
  forwardRef,
  useEffect,
  useImperativeHandle,
  useMemo,
  useRef,
  useState,
} from 'react'
import type { BoardState, CanvasPatchProposal, SelectedCanvasElementContext, Session } from '../types'
import {
  activateSession,
  uploadAttachment,
  spawnSession,
  streamAssistantChat,
  type AssistantMessage,
} from '../api'
import { commandForSpawnProvider, loadSpawnProvider } from '../preferences'
import { readLlmSettings, activeTools } from '../lib/llmSettings'
import { useToast } from '../App'
import TranscriptPanel from './TranscriptPanel'
import { ChatComposer, type ChatComposerHandle } from './ChatComposer'
import { Tooltip } from './Tooltip'
import {
  TranscriptView,
  loadTranscriptVerbosity,
  saveTranscriptVerbosity,
  loadDockExpanded,
  saveDockExpanded,
  type TranscriptVerbosity,
} from '@meee1/board-ui'
import type {
  TranscriptBlockForView,
  TranscriptEntryForView,
} from '@meee1/board-core'

// ── Mode 类型 ──────────────────────────────────────────────────────────

export type DockMode =
  | {
      kind: 'session'
      state: BoardState
      session: Session
    }
  | {
      kind: 'assistant'
      /** spawn 成功 → 父组件 toast + 关 dock。 */
      onSpawned: (cwd: string) => void
      onError: (msg: string) => void
      /** Assistant chat 历史。lifted 到 App 才能跨 dock 开关持久化。 */
      messages: DisplayMessage[]
      setMessages: React.Dispatch<React.SetStateAction<DisplayMessage[]>>
      canvasId: string
      canvasName: string
      workspacePath: string
      selectedElements: SelectedCanvasElementContext[]
      onApplyCanvasPatch: (proposal: CanvasPatchProposal) => void
    }

export interface DockHandle {
  /** 把一个键 / 粘贴文本追加到 textarea 末尾并 focus。canvas 层
   *  截到的可打印键走这里，避免被 Excalidraw 吞。 */
  appendAndFocus: (text: string) => void
}

interface Props {
  mode: DockMode
  /** 用户在画板上敲的第一个键 / 粘贴的文本 —— mount 时塞进 textarea。 */
  initialSeed?: string
  onClose: () => void
}

// ── Assistant-mode 的 chat log 数据结构（export 给 App.tsx 持久化用）

export interface ToolEvent {
  id: string
  name: string
  args: unknown
  result?: unknown
  error?: string
}
export interface DisplayMessage extends AssistantMessage {
  kind?: 'context_reset'
  toolEvents?: ToolEvent[]
}

// ── 主组件 ────────────────────────────────────────────────────────────

export const Dock = forwardRef<DockHandle, Props>(function Dock(
  { mode, initialSeed, onClose },
  ref,
) {
  const toast = useToast()
  const selectedElementTags = useMemo(
    () => mode.kind === 'assistant'
      ? mode.selectedElements.map((el) => ({
          id: el.id,
          label: el.label,
          title: [
            el.label,
            `type=${el.type}`,
            `pos=(${el.x}, ${el.y})`,
            `size=${el.width}x${el.height}`,
            el.textPreview ? `text=${el.textPreview}` : null,
          ].filter(Boolean).join(' | '),
        }))
      : [],
    [mode],
  )

  // session 模式默认 expanded（看 transcript），assistant 模式默认折叠
  // （问 AI 是个轻交互，不该立刻占满整个画板）。
  // session 模式：跨 session 切换记住用户上次选的 expand 状态（localStorage）；
  // assistant 模式不持久化（轻交互，每次 spawn 都从折叠开始）。
  const [expandedState, setExpandedState] = useState(() =>
    mode.kind === 'session' ? loadDockExpanded(true) : false,
  )
  const expanded = expandedState
  const setExpanded = (next: boolean | ((prev: boolean) => boolean)) => {
    setExpandedState((prev) => {
      const v = typeof next === 'function' ? next(prev) : next
      if (mode.kind === 'session') saveDockExpanded(v)
      return v
    })
  }

  const composerRef = useRef<ChatComposerHandle | null>(null)

  // Transcript verbosity 在 Dock 这一级存——这样我们能把 segmented
  // pill 直接渲到 ChatComposer 的 bottomLeft 里（用户视觉惯性：filter
  // 跟 input box 在一起，搜索栏旁边没他要的设置）。TranscriptPanel/View
  // 在 controlled mode 下信我们的值，不再自己管。
  const [verbosity, setVerbosityState] = useState<TranscriptVerbosity>(loadTranscriptVerbosity)
  const setVerbosity = (v: TranscriptVerbosity) => {
    setVerbosityState(v)
    saveTranscriptVerbosity(v)
  }

  const sessionRefreshKey = mode.kind === 'session'
    ? [
        mode.session.id,
        mode.session.lastActivity ?? '',
        mode.session.status ?? '',
        mode.session.currentTool ?? '',
        mode.session.currentTask ?? '',
      ].join('|')
    : undefined
  const sessionPollMs = mode.kind === 'session' &&
    ['active', 'thinking', 'tooling', 'waitingForUser'].includes(mode.session.status ?? '')
    ? 5_000
    : 30_000

  // 命令式：转发到 ChatComposer
  useImperativeHandle(
    ref,
    () => ({
      appendAndFocus(text: string) {
        composerRef.current?.appendAndFocus(text)
      },
    }),
    [],
  )

  // ── Assistant 模式独占的 state（session 模式下也声明但不用，避免
  //    跨 mode 切换时 hook 数量变化触发 React error）
  // messages 从父组件传入（lifted 到 App.tsx），跨 dock 开关持久化；
  // busy / err / abortController 仍是 dock 实例本地（流是瞬时的，dock 一关就 abort）。
  const messages = mode.kind === 'assistant' ? mode.messages : []
  const setMessages =
    mode.kind === 'assistant' ? mode.setMessages : (() => { /* noop */ })
  const visibleAssistantMessages = useMemo(
    () => messagesAfterLastReset(messages),
    [messages],
  )
  const hasContextReset = useMemo(
    () => messages.some(isContextResetMessage),
    [messages],
  )
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [appliedPatchEventIds, setAppliedPatchEventIds] = useState<Set<string>>(() => new Set())
  const logRef = useRef<HTMLDivElement | null>(null)
  const abortRef = useRef<AbortController | null>(null)

  // chat log 滚到底
  useEffect(() => {
    if (mode.kind !== 'assistant') return
    const el = logRef.current
    if (!el) return
    el.scrollTop = el.scrollHeight
  }, [messages, busy, mode.kind])

  const handleClearAssistantContext = () => {
    if (mode.kind !== 'assistant' || busy) return
    setErr(null)
    setAppliedPatchEventIds(new Set())
    setMessages([makeContextResetMessage()])
  }

  // assistant busy 时按 Esc → cancel stream（textarea 已 disabled，键盘事件
  // 不会落到 textarea，走 window-level）
  useEffect(() => {
    if (mode.kind !== 'assistant' || !busy) return
    const onEsc = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault()
        abortRef.current?.abort()
      }
    }
    window.addEventListener('keydown', onEsc, true)
    return () => window.removeEventListener('keydown', onEsc, true)
  }, [busy, mode.kind])

  // ── handleSend：mode 分流业务 ────────────────────────────────────
  const handleSend = async (content: string) => {
    if (mode.kind === 'session') {
      toast.push('info', 'Session messaging is disabled. Jump back to the terminal or editor to continue this session.')
      return
    }

    // assistant 模式：把 content 当下一轮 user message，启动 stream
    const text = content.trim()
    if (!text || busy) return

    // Slash commands —— 不发给 LLM，直接本地处理。
    // /new-session / /new / /clear / /reset 都清空当前 assistant 历史，
    // 让用户开始一段全新的对话。这是用户主动"重启"assistant chat 的唯一
    // 方式（普通关闭 dock 不会清，跨 dock 开关 chat 历史保留）。
    if (text === '/new-session' || text === '/new' || text === '/clear' || text === '/reset') {
      setAppliedPatchEventIds(new Set())
      setMessages([makeContextResetMessage()])
      setErr(null)
      return
    }

    setErr(null)
    const userMsg: DisplayMessage = { role: 'user', content: text }
    const next: DisplayMessage[] = [...messages, userMsg]
    const assistantIndex = next.length
    next.push({ role: 'assistant', content: '', toolEvents: [] })
    setMessages(next)
    setBusy(true)

    const ctrl = new AbortController()
    abortRef.current = ctrl
    const settings = readLlmSettings()
    const wireSettings = {
      provider: settings.provider,
      apiKey: settings.apiKey,
      baseUrl: settings.baseUrl,
      model: settings.model,
      enabledTools: activeTools(settings),
      scope: 'this-mac',
      canvasId: mode.kind === 'assistant' ? mode.canvasId : undefined,
      workspacePath: mode.kind === 'assistant' ? mode.workspacePath : undefined,
      canvasName: mode.kind === 'assistant' ? mode.canvasName : undefined,
      selectedElements: mode.kind === 'assistant' ? mode.selectedElements : undefined,
    }
    const wireMessages: AssistantMessage[] = messagesAfterLastReset(next.slice(0, assistantIndex)).map((m) => ({
      role: m.role,
      content: m.content,
    }))

    try {
      for await (const ev of streamAssistantChat({
        messages: wireMessages,
        settings: wireSettings,
        signal: ctrl.signal,
      })) {
        if (ev.type === 'delta') {
          setMessages((prev) => {
            const out = [...prev]
            const cur = out[assistantIndex]
            if (!cur) return prev
            out[assistantIndex] = { ...cur, content: cur.content + ev.text }
            return out
          })
        } else if (ev.type === 'tool_call') {
          setMessages((prev) => {
            const out = [...prev]
            const cur = out[assistantIndex]
            if (!cur) return prev
            const events = [...(cur.toolEvents ?? []), {
              id: ev.id, name: ev.name, args: ev.args,
            }]
            out[assistantIndex] = { ...cur, toolEvents: events }
            return out
          })
        } else if (ev.type === 'tool_result') {
          setMessages((prev) => {
            const out = [...prev]
            const cur = out[assistantIndex]
            if (!cur || !cur.toolEvents) return prev
            const events = cur.toolEvents.map((te) =>
              te.id === ev.id ? { ...te, result: ev.result } : te,
            )
            out[assistantIndex] = { ...cur, toolEvents: events }
            return out
          })
        } else if (ev.type === 'error') {
          setErr(ev.message)
          break
        }
      }
    } catch (e) {
      if ((e as Error).name === 'AbortError') {
        // user cancelled — keep partial output, no error
      } else {
        const msg = (e as Error).message || 'assistant failed'
        setErr(msg)
      }
    } finally {
      abortRef.current = null
      setBusy(false)
    }
  }

  const handleSpawn = async (cwd: string, createIfMissing: boolean) => {
    if (mode.kind !== 'assistant') return
    setBusy(true)
    setErr(null)
    try {
      await spawnSession({
        cwd,
        command: commandForSpawnProvider(loadSpawnProvider()),
        createIfMissing,
      })
      mode.onSpawned(cwd)
    } catch (e) {
      const m = (e as Error).message || 'spawn failed'
      setErr(m)
      mode.onError(m)
      setBusy(false)
    }
  }

  // ── session 模式的 bottombar 元数据
  const sessionMeta = useMemo(() => {
    if (mode.kind !== 'session') return null
    return {
      modelLabel: formatModelLabel(mode.session.usageStats?.model ?? null),
      statusLabel: formatStatusLabel(mode.session.status ?? null),
      isActive: isStatusActive(mode.session.status ?? null),
      pluginDisplayName: mode.session.pluginDisplayName,
    }
  }, [mode])

  const canvasPatchProposals = useMemo(() => {
    if (mode.kind !== 'assistant') return []
    const rows: Array<{ key: string; eventId: string; proposal: CanvasPatchProposal }> = []
    visibleAssistantMessages.forEach((message, messageIndex) => {
      for (const event of message.toolEvents ?? []) {
        const proposal = canvasPatchProposalFromToolEvent(event)
        if (proposal) rows.push({ key: `${messageIndex}-${event.id}`, eventId: event.id, proposal })
      }
    })
    return rows
  }, [visibleAssistantMessages, mode])

  // ── render ────────────────────────────────────────────────────────
  return (
    <div
      className={
        'session-dock' +
        (mode.kind === 'assistant' ? ' session-dock--assistant' : '') +
        (expanded ? '' : ' session-dock--collapsed')
      }
      role={mode.kind === 'assistant' ? 'dialog' : undefined}
      aria-modal={mode.kind === 'assistant' ? 'true' : undefined}
      aria-label={mode.kind === 'assistant' ? 'Ask the assistant' : undefined}
    >
      {/* ── 右上角浮动按钮：toggle expand + close ─────────── */}
      <div className="session-dock__actions">
        {mode.kind === 'assistant' && (
          <Tooltip label="Clear assistant context">
            <button
              onClick={handleClearAssistantContext}
              aria-label="Clear assistant context"
              disabled={busy}
            >
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
                <path d="M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7l1-3h4l1 3"
                  stroke="currentColor" strokeWidth="1.8"
                  strokeLinecap="round" strokeLinejoin="round" />
              </svg>
            </button>
          </Tooltip>
        )}
        <Tooltip label={expanded ? 'Collapse to bottom' : 'Expand to fill canvas'}>
          <button
            onClick={() => setExpanded((v) => !v)}
            aria-label={expanded ? 'Collapse dock' : 'Expand dock'}
            aria-pressed={!expanded}
          >
            {expanded ? (
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
                <path d="M10 4v6H4M14 20v-6h6M4 4l7 7M20 20l-7-7"
                  stroke="currentColor" strokeWidth="2"
                  strokeLinecap="round" strokeLinejoin="round" />
              </svg>
            ) : (
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
                <path d="M4 14v6h6M14 4h6v6M4 20l7-7M20 4l-7 7"
                  stroke="currentColor" strokeWidth="2"
                  strokeLinecap="round" strokeLinejoin="round" />
              </svg>
            )}
          </button>
        </Tooltip>
        <Tooltip label="Close" shortcut="Esc">
          <button
            onClick={onClose}
            aria-label="Close dock"
            style={{ fontSize: 18, lineHeight: 1 }}
          >
            ×
          </button>
        </Tooltip>
      </div>

      {/* ── 中间区：mode 分流 ──────────────────────────────── */}
      <div className="session-dock__transcript">
        {mode.kind === 'session' ? (
          <TranscriptPanel
            key={mode.session.id}
            sessionId={mode.session.id}
            limit={200}
            pollMs={sessionPollMs}
            refreshTrigger={sessionRefreshKey}
            liveStatus={mode.session.status ?? null}
            liveCurrentTool={mode.session.currentTool ?? null}
            liveCurrentTask={mode.session.currentTask ?? null}
            assistantLabel={mode.session.pluginDisplayName || 'Assistant'}
            verbosity="normal"
            onVerbosityChange={() => undefined}
          />
        ) : (
          // Assistant 模式复用 TranscriptView —— 跟 session 模式视觉同源
          // （markdown 渲染 / 代码块 / tool block 折叠 / verbosity 控件）。
          // DisplayMessage[] 由下面 adapter 转成 TranscriptEntryForView[]。
          // Spawn fence 单独抽出来在底下渲一个 button 行（保留 ChatBubble
          // 时代的"⚡ Spawn here"功能 —— TranscriptView 不认这个 fence）。
          <div className="col" style={{ flex: 1, minHeight: 0, gap: 8 }}>
            {visibleAssistantMessages.length === 0 && !busy && !hasContextReset ? (
              <div className="assistant-empty">
                Ask about this canvas. I can summarize sessions, explain what changed,
                or help draft the next prompt.
              </div>
            ) : (
              <>
                {hasContextReset && <ContextResetDivider />}
                {(visibleAssistantMessages.length > 0 || busy) && (
                  <TranscriptView
                    entries={assistantMessagesToTranscriptEntries(visibleAssistantMessages)}
                    cacheKey="__assistant_dock__"
                    liveStatus={busy ? 'thinking' : null}
                    verbosity={verbosity}
                    onVerbosityChange={setVerbosity}
                  />
                )}
              </>
            )}
            {visibleAssistantMessages.map((m, i) => {
              if (m.role !== 'assistant') return null
              const { spawn } = splitSpawnFence(m.content)
              if (!spawn) return null
              return (
                <div key={`spawn-${i}`} className="row" style={{
                  gap: 8, padding: '6px 8px',
                  background: 'rgba(167, 139, 250, 0.08)',
                  border: '1px solid rgba(167, 139, 250, 0.3)',
                  borderRadius: 6, alignItems: 'center',
                }}>
                  <span style={{ fontSize: 11, color: '#A78BFA' }}>⚡ Spawn at</span>
                  <code style={{ fontSize: 11, flex: 1, wordBreak: 'break-all' }}>{spawn.cwd}</code>
                  <button
                    className="primary"
                    style={{ fontSize: 11, padding: '3px 10px' }}
                    onClick={() => handleSpawn(spawn.cwd, true)}
                  >
                    Spawn here
                  </button>
                </div>
              )
            })}
            {mode.kind === 'assistant' && canvasPatchProposals.map(({ key, eventId, proposal }) => (
              <CanvasPatchCard
                key={`patch-${key}`}
                proposal={proposal}
                activeCanvasId={mode.canvasId}
                applied={appliedPatchEventIds.has(eventId)}
                onApply={() => {
                  if (proposal.canvasId !== mode.canvasId) {
                    mode.onApplyCanvasPatch(proposal)
                    return
                  }
                  setAppliedPatchEventIds((prev) => new Set(prev).add(eventId))
                  mode.onApplyCanvasPatch(proposal)
                }}
              />
            ))}
            {err && <div className="inline-error" style={{ margin: '4px 4px 0' }}>{err}</div>}
          </div>
        )}
      </div>

      {/* ── input + bottombar：共享 ChatComposer ─────────── */}
      <ChatComposer
        ref={composerRef}
        initialValue={initialSeed}
        placeholder={mode.kind === 'assistant' ? 'Ask about this canvas…' : 'Type a message…'}
        onSend={handleSend}
        onEscape={onClose}
        contextTags={mode.kind === 'assistant' ? selectedElementTags : undefined}
        externalBusy={mode.kind === 'assistant' ? busy : undefined}
        uploadImage={
          mode.kind === 'session'
            ? (f) => uploadAttachment(mode.session.id, f)
            : undefined
        }
        onPush={undefined}
        pushTitle="Session messaging is disabled"
        bottomLeft={
          mode.kind === 'session' ? (
            <>
              <Tooltip label="Attach file (paste image)">
                <button className="cc-icon-btn" type="button" aria-label="Attach file">
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
                    <path d="M12 5v14m-7-7h14" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
                  </svg>
                </button>
              </Tooltip>
              <Tooltip label="Quick command">
                <button className="cc-icon-btn" type="button" aria-label="Quick command">
                  {/* slash-command 视觉：方框 + 内嵌 / —— 比纯空 rect 多一笔 */}
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
                    <rect x="4" y="4" width="16" height="16" rx="3"
                          stroke="currentColor" strokeWidth="1.6" />
                    <path d="M14 8l-4 8" stroke="currentColor"
                          strokeWidth="1.8" strokeLinecap="round" />
                  </svg>
                </button>
              </Tooltip>
            </>
          ) : (
            <span className="assistant-context-chip" title={mode.workspacePath || undefined}>
              This canvas · {mode.canvasName}
            </span>
          )
        }
        bottomRight={
          mode.kind === 'session' ? (
            <>
              <span className="cc-plugin-tag">{sessionMeta!.pluginDisplayName}</span>
              <span className="cc-model">
                {sessionMeta!.modelLabel ?? '—'}
                <span className="cc-model-sep">·</span>
                <span className={sessionMeta!.isActive ? 'cc-model-state cc-model-state--active' : 'cc-model-state'}>
                  {sessionMeta!.statusLabel}
                </span>
                {sessionMeta!.isActive && <span className="cc-spinner-mini" aria-hidden />}
              </span>
              {/* Open chip 移到 bottombar 最右 —— 跟 model/status 一行，
                * 视觉上属于 inputbox 右下角的 meta 区。 */}
              <Tooltip label="Open session terminal / Claude.app" placement="top">
                <button
                  className="session-dock__open"
                  onClick={() => {
                    if (mode.kind === 'session') void activateSession(mode.session.id)
                  }}
                  aria-label="Open session"
                  type="button"
                >
                  Open
                  <svg width="11" height="11" viewBox="0 0 24 24" fill="none"
                       stroke="currentColor" strokeWidth="1.8"
                       strokeLinecap="round" strokeLinejoin="round" aria-hidden>
                    <path d="M7 17 17 7M9 7h8v8"/>
                  </svg>
                </button>
              </Tooltip>
            </>
          ) : (
            <>
              {busy && <span className="cc-model">
                <span className={busy ? 'cc-model-state cc-model-state--active' : 'cc-model-state'}>
                  Thinking
                </span>
                <span className="cc-spinner-mini" aria-hidden />
              </span>}
            </>
          )
        }
      />
    </div>
  )
})

// ── Helpers / sub-components for assistant chat log ───────────────────

function ChatBubble({
  message,
  onSpawn,
}: {
  message: DisplayMessage
  onSpawn: (cwd: string, createIfMissing: boolean) => void
}) {
  const isUser = message.role === 'user'
  const { body, spawn } = splitSpawnFence(message.content)
  const toolEvents = message.toolEvents ?? []
  if (!isUser && body === '' && toolEvents.length === 0 && !spawn) return null
  return (
    <div className="col" style={{ gap: 4, alignSelf: isUser ? 'flex-end' : 'flex-start', maxWidth: '88%' }}>
      <div style={{ fontSize: 10, color: isUser ? '#64748B' : '#A78BFA', fontWeight: 600, letterSpacing: 0.4 }}>
        {isUser ? 'YOU' : 'ASSISTANT'}
      </div>
      {body !== '' && (
        <div style={{
          padding: '8px 10px', borderRadius: 8, fontSize: 13, lineHeight: 1.5,
          whiteSpace: 'pre-wrap', wordBreak: 'break-word',
          background: isUser ? '#1E293B' : '#13172130',
          border: isUser ? 'none' : '1px solid #2a3040',
          color: '#D4D8E1',
        }}>
          {body}
        </div>
      )}
      {toolEvents.map((te) => <ToolChip key={te.id} event={te} />)}
      {spawn && (
        <div className="row" style={{
          gap: 8, padding: '6px 8px',
          background: 'rgba(167, 139, 250, 0.08)',
          border: '1px solid rgba(167, 139, 250, 0.3)',
          borderRadius: 6, alignItems: 'center',
        }}>
          <span style={{ fontSize: 11, color: '#A78BFA' }}>⚡ Spawn at</span>
          <code style={{ fontSize: 11, flex: 1, wordBreak: 'break-all' }}>{spawn.cwd}</code>
          <button className="primary" style={{ fontSize: 11, padding: '3px 10px' }} onClick={() => onSpawn(spawn.cwd, true)}>
            Spawn here
          </button>
        </div>
      )}
    </div>
  )
}

function ToolChip({ event }: { event: ToolEvent }) {
  const running = event.result === undefined && !event.error
  const errMsg = typeof (event.result as any)?.error === 'string' ? (event.result as any).error : null
  const failed = !!errMsg
  const label = running ? '…running' : failed ? 'error' : 'ok'
  const argsText = (() => { try { return JSON.stringify(event.args ?? {}) } catch { return '{…}' } })()
  return (
    <details style={{
      background: failed ? 'rgba(194, 106, 106, 0.08)' : running ? 'rgba(167, 139, 250, 0.06)' : 'rgba(127, 169, 130, 0.08)',
      border: '1px solid ' + (failed ? 'rgba(194, 106, 106, 0.3)' : running ? 'rgba(167, 139, 250, 0.25)' : 'rgba(127, 169, 130, 0.25)'),
      borderRadius: 6, padding: '4px 8px', fontSize: 11,
    }}>
      <summary style={{ cursor: 'pointer', listStyle: 'none', display: 'flex', gap: 6, alignItems: 'center' }}>
        <span style={{ fontWeight: 600 }}>⚡ {event.name}</span>
        <span className="muted" style={{ fontSize: 10 }}>{label}</span>
        {running && <span className="cc-spinner" aria-hidden style={{ width: 10, height: 10 }} />}
      </summary>
      <div style={{ marginTop: 4, fontFamily: 'var(--mono)', fontSize: 10, lineHeight: 1.4 }}>
        <div className="muted">args:</div>
        <div style={{ whiteSpace: 'pre-wrap', wordBreak: 'break-all', opacity: 0.9 }}>{argsText}</div>
        {!running && (
          <>
            <div className="muted" style={{ marginTop: 4 }}>result:</div>
            <div style={{ whiteSpace: 'pre-wrap', wordBreak: 'break-all', opacity: 0.9 }}>
              {(() => { try { return JSON.stringify(event.result, null, 2) } catch { return String(event.result) } })()}
            </div>
          </>
        )}
      </div>
    </details>
  )
}

function CanvasPatchCard({
  proposal,
  activeCanvasId,
  applied,
  onApply,
}: {
  proposal: CanvasPatchProposal
  activeCanvasId: string
  applied: boolean
  onApply: () => void
}) {
  const isCurrentCanvas = proposal.canvasId === activeCanvasId
  const count = proposal.operationCount ?? proposal.operations.length
  return (
    <div className={'canvas-patch-card' + (applied ? ' canvas-patch-card--applied' : '')}>
      <div className="canvas-patch-card__body">
        <div className="canvas-patch-card__title">
          {applied ? 'Canvas changes applied' : 'Canvas changes ready'}
        </div>
        <div className="canvas-patch-card__summary">{proposal.summary}</div>
        <div className="canvas-patch-card__meta">
          {count} change{count === 1 ? '' : 's'} · {applied ? 'Applied to this canvas' : 'Apply only changes this canvas'}
        </div>
        <ul className="canvas-patch-card__ops">
          {proposal.operations.slice(0, 4).map((op, index) => (
            <li key={index}>{operationLabel(op)}</li>
          ))}
          {proposal.operations.length > 4 && (
            <li>{proposal.operations.length - 4} more</li>
          )}
        </ul>
      </div>
      <button
        className="primary canvas-patch-card__apply"
        onClick={onApply}
        disabled={!isCurrentCanvas || applied}
        title={applied ? 'Already applied' : isCurrentCanvas ? 'Apply to this canvas' : 'Switch back to this canvas first'}
      >
        {applied ? 'Applied' : 'Apply'}
      </button>
    </div>
  )
}

function ContextResetDivider() {
  return (
    <div className="assistant-context-reset" role="status" aria-label="上下文已重置">
      <span>上下文已重置</span>
    </div>
  )
}

function canvasPatchProposalFromToolEvent(event: ToolEvent): CanvasPatchProposal | null {
  const raw = event.result
  if (!raw || typeof raw !== 'object') return null
  const obj = raw as Record<string, unknown>
  const rawProposal =
    event.name === 'propose_canvas_patch'
      ? obj
      : event.name === 'create_coordinator_session'
        ? obj.canvasPatchProposal
        : null
  if (!rawProposal || typeof rawProposal !== 'object') return null
  const proposal = rawProposal as Record<string, unknown>
  if (proposal.type !== 'canvas_patch_proposal') return null
  if (typeof proposal.canvasId !== 'string') return null
  if (!Array.isArray(proposal.operations)) return null
  return {
    type: 'canvas_patch_proposal',
    canvasId: proposal.canvasId,
    canvasName: typeof proposal.canvasName === 'string' ? proposal.canvasName : undefined,
    summary: typeof proposal.summary === 'string' ? proposal.summary : 'Canvas changes ready.',
    operations: proposal.operations as CanvasPatchProposal['operations'],
    operationCount: typeof proposal.operationCount === 'number' ? proposal.operationCount : undefined,
    requiresApply: proposal.requiresApply === true,
  }
}

function makeContextResetMessage(): DisplayMessage {
  return { role: 'assistant', content: '', kind: 'context_reset' }
}

function isContextResetMessage(message: DisplayMessage): boolean {
  return message.kind === 'context_reset'
}

function messagesAfterLastReset(messages: DisplayMessage[]): DisplayMessage[] {
  const lastReset = messages.reduce(
    (last, message, index) => isContextResetMessage(message) ? index : last,
    -1,
  )
  return messages.slice(lastReset + 1).filter((message) => !isContextResetMessage(message))
}

function operationLabel(op: CanvasPatchProposal['operations'][number]): string {
  switch (op.type) {
    case 'move_session': return `Move session ${shortId(op.sessionId)}`
    case 'move_channel': return `Move channel ${op.channelName}`
    case 'show_session': return `Show session ${shortId(op.sessionId)}`
    case 'hide_session': return `Hide session ${shortId(op.sessionId)}`
    case 'add_note': return `Add note "${op.text.slice(0, 36)}${op.text.length > 36 ? '…' : ''}"`
    case 'update_note': return `Update note ${shortId(op.elementId)}`
    case 'add_frame': return `Add ${op.title ? `"${op.title}" ` : ''}frame`
    case 'add_connector': {
      const from = op.fromSessionId ? shortId(op.fromSessionId) : op.fromElementId ? shortId(op.fromElementId) : '?'
      const to = op.toSessionId ? shortId(op.toSessionId) : op.toElementId ? shortId(op.toElementId) : '?'
      return `Connect ${from} → ${to}${op.label ? ` (${op.label})` : ''}`
    }
    case 'add_shape': return `Add ${op.shape}${op.text ? ` "${op.text.slice(0, 28)}${op.text.length > 28 ? '…' : ''}"` : ''}`
    case 'add_label': return `Add label "${op.text.slice(0, 36)}${op.text.length > 36 ? '…' : ''}"`
    case 'update_element': return `Update element ${shortId(op.elementId)}`
  }
}

function shortId(id: string): string {
  return id.length <= 8 ? id : id.slice(0, 8)
}

const HIDDEN_ASSISTANT_TOOL_BLOCKS = new Set([
  'get_canvas_context',
  'propose_canvas_patch',
])

/** 扫 assistant 回复里有没有 ```spawn\n{...}\n``` fence；有的话解析出 cwd。 */
/// LLM 流式回复时，tool-call 的 JSON 经常跟着 delta text 一起进 content
/// 字符串（"{"name": "X", "args": {...}}"），同时又另有结构化 tool_call
/// 事件 —— 渲染时会出现三份重复。这里把 content 里 tool-call JSON 噪音
/// 剥掉，只留真正的 prose 给 TranscriptView 走 markdown 渲染。
///   - 行首 `{"name":..., "args":{...}}` 整行删
///   - 被孤立的开 fence ` ``` ` 后面跟非空字符（造成 markdown 把后面整段
///     当 code block）也修一下：把那行的开 fence 砍掉留 markdown 内容
function cleanAssistantContent(text: string): string {
  if (!text) return text
  // strip lines that look like {"name": "tool", "args": {...}}
  let cleaned = text.replace(
    /^\s*\{\s*"name"\s*:\s*"[^"]+"\s*,\s*"args"\s*:\s*\{[\s\S]*?\}\s*\}\s*$\n?/gm,
    '',
  )
  // 落单的 "```<text>" 开 fence —— 通常 LLM 把 tool result 包了 fence 没闭，
  // 导致后面 markdown 全被 react-markdown 当代码块渲。简单粗暴：行首 ```
  // 后面紧跟非空字符 → 把那 ``` 去掉，保留后面的内容当普通 markdown。
  cleaned = cleaned.replace(/^\s*```([^\n`].*)$/gm, '$1')
  return cleaned.trim()
}

/// 把 assistant 模式的 DisplayMessage[] 适配成 TranscriptView 吃的
/// TranscriptEntryForView[] —— 复用 session 模式同款渲染（markdown /
/// 代码块 / tool block 折叠）。每条 message 一个 entry：
///   - role 直传（user / assistant）
///   - content 进 text block；spawn fence 文字 + tool-call JSON 噪音预先剥掉
///   - toolEvents → 一对 tool_use + tool_result block；result 序列化成 JSON
///     文本（TranscriptView 自己会 truncate 显示）
function assistantMessagesToTranscriptEntries(
  messages: DisplayMessage[],
): TranscriptEntryForView[] {
  return messages.map((m, i) => {
    const blocks: TranscriptBlockForView[] = []
    const { body } = splitSpawnFence(m.content)
    const cleanedBody = m.role === 'assistant' ? cleanAssistantContent(body) : body
    if (cleanedBody) {
      blocks.push({ type: 'text', text: cleanedBody })
    }
    for (const te of m.toolEvents ?? []) {
      if (HIDDEN_ASSISTANT_TOOL_BLOCKS.has(te.name)) continue
      const argsJSON = (() => {
        if (typeof te.args === 'string') return te.args
        try { return JSON.stringify(te.args ?? {}, null, 2) } catch { return '{}' }
      })()
      blocks.push({
        type: 'tool_use',
        toolId: te.id,
        toolUseId: te.id,
        toolName: te.name,
        toolInputJSON: argsJSON,
      })
      if (te.result !== undefined || te.error) {
        const resultText = te.error
          ? `Error: ${te.error}`
          : (typeof te.result === 'string'
              ? te.result
              : (() => { try { return JSON.stringify(te.result, null, 2) } catch { return String(te.result) } })())
        blocks.push({
          type: 'tool_result',
          toolUseId: te.id,
          toolName: te.name,
          toolResultText: resultText,
        })
      }
    }
    return {
      id: `assistant-${i}`,
      type: m.role,
      timestamp: null,
      blocks,
    }
  })
}

function splitSpawnFence(text: string): { body: string; spawn: { cwd: string } | null } {
  const re = /```spawn\s*\n([\s\S]*?)\n```/
  const m = text.match(re)
  if (!m) return { body: text, spawn: null }
  try {
    const obj = JSON.parse(m[1].trim())
    if (obj && typeof obj.cwd === 'string' && obj.cwd.length > 0) {
      const body = (text.slice(0, m.index) + text.slice((m.index ?? 0) + m[0].length)).trim()
      return { body, spawn: { cwd: obj.cwd } }
    }
  } catch { /* malformed fence */ }
  return { body: text, spawn: null }
}

/** "claude-opus-4-7[1m]" → "Opus 4.7 1M" */
function formatModelLabel(model: string | null): string | null {
  if (!model) return null
  const m = model.match(/claude-([a-z]+)-(\d+)-?(\d+)?/i)
  if (!m) return model
  const family = m[1].charAt(0).toUpperCase() + m[1].slice(1)
  const ver = m[3] ? `${m[2]}.${m[3]}` : m[2]
  const ctx = model.match(/\[(\d+)([mk])\]/i)
  const ctxStr = ctx ? ` ${ctx[1]}${ctx[2].toUpperCase()}` : ''
  return `${family} ${ver}${ctxStr}`
}

function formatStatusLabel(status: string | null): string {
  if (!status) return 'unknown'
  switch (status) {
    case 'idle': return 'idle'
    case 'thinking': return 'thinking'
    case 'tooling': return 'tooling'
    case 'waitingForUser': return 'waiting'
    case 'spawning': return 'spawning'
    case 'error': return 'error'
    default: return status
  }
}

function isStatusActive(status: string | null): boolean {
  return status === 'thinking' || status === 'tooling' || status === 'spawning'
}
