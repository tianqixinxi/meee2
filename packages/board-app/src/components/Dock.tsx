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
//   mode='session'   → <TranscriptPanel /> + injectToSession
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
import type { BoardState, Session } from '../types'
import {
  activateSession,
  injectToSession,
  uploadAttachment,
  spawnSession,
  streamAssistantChat,
  type AssistantMessage,
} from '../api'
import { loadDefaultSpawnCommand } from '../preferences'
import { readLlmSettings, activeTools } from '../lib/llmSettings'
import { useToast } from '../App'
import TranscriptPanel from './TranscriptPanel'
import { ChatComposer, type ChatComposerHandle } from './ChatComposer'
import {
  loadTranscriptVerbosity,
  saveTranscriptVerbosity,
  type TranscriptVerbosity,
} from '@meee1/board-ui'

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
  toolEvents?: ToolEvent[]
}

// ── 主组件 ────────────────────────────────────────────────────────────

export const Dock = forwardRef<DockHandle, Props>(function Dock(
  { mode, initialSeed, onClose },
  ref,
) {
  const toast = useToast()

  // session 模式默认 expanded（看 transcript），assistant 模式默认折叠
  // （问 AI 是个轻交互，不该立刻占满整个画板）。
  const [expanded, setExpanded] = useState(mode.kind === 'session')

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
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const logRef = useRef<HTMLDivElement | null>(null)
  const abortRef = useRef<AbortController | null>(null)

  // chat log 滚到底
  useEffect(() => {
    if (mode.kind !== 'assistant') return
    const el = logRef.current
    if (!el) return
    el.scrollTop = el.scrollHeight
  }, [messages, busy, mode.kind])

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
      const shortId = mode.session.id.slice(0, 8)
      await injectToSession(mode.session.id, content)
      toast.push('success', `Sent to ${mode.session.title} (${shortId})`)
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
      setMessages([])
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
    }
    const wireMessages: AssistantMessage[] = next.slice(0, assistantIndex).map((m) => ({
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
        command: loadDefaultSpawnCommand(),
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
      inboxCount: mode.session.inboxPending ?? 0,
    }
  }, [mode])

  // ── render ────────────────────────────────────────────────────────
  return (
    <div
      className={'session-dock' + (expanded ? '' : ' session-dock--collapsed')}
      role={mode.kind === 'assistant' ? 'dialog' : undefined}
      aria-modal={mode.kind === 'assistant' ? 'true' : undefined}
      aria-label={mode.kind === 'assistant' ? 'Ask the assistant' : undefined}
    >
      {/* ── 右上角浮动按钮：toggle expand + close ─────────── */}
      <div className="session-dock__actions">
        <button
          onClick={() => setExpanded((v) => !v)}
          title={expanded ? 'Collapse to bottom' : 'Expand to fill canvas'}
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
        <button
          onClick={onClose}
          title="Close (Esc when input is empty)"
          aria-label="Close dock"
          style={{ fontSize: 18, lineHeight: 1 }}
        >
          ×
        </button>
      </div>

      {/* ── 中间区：mode 分流 ──────────────────────────────── */}
      <div className="session-dock__transcript">
        {mode.kind === 'session' ? (
          <TranscriptPanel
            key={mode.session.id}
            sessionId={mode.session.id}
            limit={200}
            refreshTrigger={mode.state}
            liveStatus={mode.session.status ?? null}
            liveCurrentTool={mode.session.currentTool ?? null}
            liveCurrentTask={mode.session.currentTask ?? null}
            verbosity={verbosity}
            onVerbosityChange={setVerbosity}
          />
        ) : (
          <div
            ref={logRef}
            className="col"
            style={{ gap: 12, overflowY: 'auto', flex: 1, marginTop: 'auto' }}
          >
            {messages.length === 0 && !busy && (
              <div className="muted" style={{ fontSize: 12, lineHeight: 1.5, padding: '8px 4px' }}>
                Ask anything — summarise sessions, draft a prompt, or describe
                a project to spawn a new Claude session in.
              </div>
            )}
            {messages.map((m, i) => (
              <ChatBubble key={i} message={m} onSpawn={handleSpawn} />
            ))}
            {busy && messages[messages.length - 1]?.content === '' &&
              !(messages[messages.length - 1]?.toolEvents?.length) && (
                <div className="muted" style={{ fontSize: 12, padding: '0 4px' }}>
                  …thinking
                </div>
              )}
            {err && <div className="inline-error" style={{ margin: '4px 4px 0' }}>{err}</div>}
          </div>
        )}
      </div>

      {/* ── input + bottombar：共享 ChatComposer ─────────── */}
      <ChatComposer
        ref={composerRef}
        initialValue={initialSeed}
        onSend={handleSend}
        onEscape={onClose}
        externalBusy={mode.kind === 'assistant' ? busy : undefined}
        uploadImage={
          mode.kind === 'session'
            ? (f) => uploadAttachment(mode.session.id, f)
            : undefined
        }
        bottomLeft={
          mode.kind === 'session' ? (
            <>
              <button className="cc-icon-btn" title="Attach file (paste image)" type="button">
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
                  <path d="M12 5v14m-7-7h14" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
                </svg>
              </button>
              <button className="cc-icon-btn" title="Quick command" type="button">
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
                  <rect x="4" y="4" width="16" height="16" rx="2" stroke="currentColor" strokeWidth="1.8" />
                </svg>
              </button>
              {/* Transcript verbosity segmented pill —— 跟 input 同行的左下，
                  user 期待 filter 跟 input box 在一起。同 storage key
                  跟 TranscriptView uncontrolled fallback 共享，保留以前的
                  user 偏好。*/}
              <div
                className="cc-verbosity"
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
                      'cc-verbosity-btn' +
                      (verbosity === level ? ' cc-verbosity-btn--active' : '')
                    }
                    title={
                      level === 'normal'
                        ? 'Normal — text only'
                        : level === 'thinking'
                        ? 'Thinking — text + thinking blocks'
                        : 'Verbose — full transcript with tool inputs/outputs'
                    }
                    onClick={() => setVerbosity(level)}
                  >
                    {level}
                  </button>
                ))}
              </div>
            </>
          ) : null
        }
        bottomRight={
          mode.kind === 'session' ? (
            <>
              {sessionMeta!.inboxCount > 0 && (
                <span className="cc-stat cc-stat--add">+{sessionMeta!.inboxCount}</span>
              )}
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
              <button
                className="session-dock__open"
                onClick={() => {
                  if (mode.kind === 'session') void activateSession(mode.session.id)
                }}
                title="Open session terminal / Claude.app"
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
            </>
          ) : (
            <>
              <span className="cc-plugin-tag">Assistant</span>
              <span className="cc-model">
                <span className={busy ? 'cc-model-state cc-model-state--active' : 'cc-model-state'}>
                  {busy ? 'streaming' : 'temporary'}
                </span>
                {busy && <span className="cc-spinner-mini" aria-hidden />}
              </span>
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

/** 扫 assistant 回复里有没有 ```spawn\n{...}\n``` fence；有的话解析出 cwd。 */
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
