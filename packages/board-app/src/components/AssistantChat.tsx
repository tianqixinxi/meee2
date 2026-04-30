import { useEffect, useRef, useState } from 'react'
import { assistantChat, spawnSession, type AssistantMessage } from '../api'
import { loadDefaultSpawnCommand } from '../preferences'

interface Props {
  onClose: () => void
  onSpawned: (cwd: string) => void
  onError: (msg: string) => void
}

/**
 * "Ask & Spawn" —— 全局 AI 助手对话框。
 *
 * 用户用自然语言描述想开什么项目，后端跑本地 `claude -p`（不吃 API key，
 * 复用本地 Claude Code OAuth）来挑 cwd。Assistant 约定在确定答案后输出
 * 一段 ```spawn fence：
 *   ```spawn
 *   {"cwd": "/abs/path"}
 *   ```
 * 前端检测到这个 fence 就渲染 "Spawn here" 按钮，点击走原有 spawnSession
 * 接口——跟手动 New Claude session 最后一步同一入口。
 */
export function AssistantChat({ onClose, onSpawned, onError }: Props) {
  const [messages, setMessages] = useState<AssistantMessage[]>([])
  const [draft, setDraft] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const inputRef = useRef<HTMLTextAreaElement | null>(null)
  const logRef = useRef<HTMLDivElement | null>(null)

  useEffect(() => {
    inputRef.current?.focus()
  }, [])

  // 新消息到达时滚到底
  useEffect(() => {
    const el = logRef.current
    if (!el) return
    el.scrollTop = el.scrollHeight
  }, [messages, busy])

  const send = async () => {
    const text = draft.trim()
    if (!text || busy) return
    setErr(null)
    const next: AssistantMessage[] = [...messages, { role: 'user', content: text }]
    setMessages(next)
    setDraft('')
    setBusy(true)
    try {
      const r = await assistantChat(next)
      setMessages([...next, { role: 'assistant', content: r.content }])
    } catch (e) {
      const msg = (e as Error).message || 'assistant failed'
      setErr(msg)
      // 失败时撤回用户消息以便重试
      setMessages(messages)
      setDraft(text)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div
      className="modal-backdrop"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onClose()
      }}
    >
      <div
        className="modal"
        role="dialog"
        aria-modal="true"
        aria-label="Ask & Spawn"
        style={{ width: 560, maxWidth: '90vw' }}
      >
        <div className="modal-header">Ask &amp; Spawn <span className="muted" style={{ fontSize: 11, fontWeight: 400, marginLeft: 8 }}>powered by local `claude -p`</span></div>

        <div
          ref={logRef}
          className="col"
          style={{
            gap: 10,
            padding: '12px 16px',
            maxHeight: '50vh',
            overflowY: 'auto',
            background: '#0B0D14',
            borderTop: '1px solid #1f2432',
            borderBottom: '1px solid #1f2432',
          }}
        >
          {messages.length === 0 && !busy && (
            <div className="muted" style={{ fontSize: 12, lineHeight: 1.5 }}>
              告诉我你想在哪个项目开一个新 Claude session。
              <br />
              例：<span className="mono">在 meee1 下开一个</span> ·{' '}
              <span className="mono">新建一个 blog 项目的 session</span>
            </div>
          )}
          {messages.map((m, i) => (
            <ChatBubble key={i} message={m} onSpawn={async (cwd, createIfMissing) => {
              setBusy(true)
              setErr(null)
              try {
                // 和 NewSessionDialog 同源：从 Preferences 读默认命令
                await spawnSession({ cwd, command: loadDefaultSpawnCommand(), createIfMissing })
                onSpawned(cwd)
              } catch (e) {
                const msg = (e as Error).message || 'spawn failed'
                setErr(msg)
                onError(msg)
                setBusy(false)
              }
            }} />
          ))}
          {busy && <div className="muted" style={{ fontSize: 12 }}>…thinking</div>}
          {err && <div className="inline-error">{err}</div>}
        </div>

        <div className="modal-body col" style={{ gap: 8, padding: 12 }}>
          <textarea
            ref={inputRef}
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            rows={2}
            placeholder="Describe the project or cwd you want (Enter to send, Shift+Enter for newline)"
            style={{ width: '100%', resize: 'vertical', fontSize: 13 }}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && !e.shiftKey) {
                e.preventDefault()
                void send()
              }
              if (e.key === 'Escape') {
                e.preventDefault()
                onClose()
              }
            }}
            spellCheck={false}
          />
        </div>

        <div className="modal-footer">
          <button className="ghost" onClick={onClose} disabled={busy}>Close</button>
          <button className="primary" onClick={send} disabled={busy || !draft.trim()}>
            {busy ? '…' : 'Send'}
          </button>
        </div>
      </div>
    </div>
  )
}

function ChatBubble({
  message,
  onSpawn,
}: {
  message: AssistantMessage
  onSpawn: (cwd: string, createIfMissing: boolean) => void
}) {
  const isUser = message.role === 'user'
  const { body, spawn } = splitSpawnFence(message.content)
  return (
    <div
      className="col"
      style={{
        gap: 4,
        alignSelf: isUser ? 'flex-end' : 'flex-start',
        maxWidth: '88%',
      }}
    >
      <div
        style={{
          fontSize: 10,
          color: isUser ? '#64748B' : '#A78BFA',
          fontWeight: 600,
          letterSpacing: 0.4,
        }}
      >
        {isUser ? 'YOU' : 'ASSISTANT'}
      </div>
      <div
        style={{
          padding: '8px 10px',
          borderRadius: 8,
          fontSize: 13,
          lineHeight: 1.5,
          whiteSpace: 'pre-wrap',
          wordBreak: 'break-word',
          background: isUser ? '#1E293B' : '#13172130',
          border: isUser ? 'none' : '1px solid #2a3040',
          color: '#D4D8E1',
        }}
      >
        {body || <span className="muted">(empty)</span>}
      </div>
      {spawn && (
        <div
          className="row"
          style={{
            gap: 8,
            padding: '6px 8px',
            background: 'rgba(167, 139, 250, 0.08)',
            border: '1px solid rgba(167, 139, 250, 0.3)',
            borderRadius: 6,
            alignItems: 'center',
          }}
        >
          <span style={{ fontSize: 11, color: '#A78BFA' }}>⚡ Spawn at</span>
          <code style={{ fontSize: 11, flex: 1, wordBreak: 'break-all' }}>{spawn.cwd}</code>
          <button
            className="primary"
            style={{ fontSize: 11, padding: '3px 10px' }}
            onClick={() => onSpawn(spawn.cwd, true)}
          >
            Spawn here
          </button>
        </div>
      )}
    </div>
  )
}

/**
 * 扫 assistant 回复里有没有 ```spawn\n{...}\n``` fence；有的话解析出 cwd，
 * 并把 fence 本体从可读正文里剪掉（给用户看的是干净文字 + 按钮）。
 */
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
  } catch {
    /* ignore malformed fence */
  }
  return { body: text, spawn: null }
}
