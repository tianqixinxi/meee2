import { useEffect, useRef, useState } from 'react'
import type { Session } from '../types'
import { injectToSession } from '../api'
import { useToast } from '../App'

interface SessionComposerProps {
  /** 当前选中的 session；null 时不显示 */
  session: Session | null
  /** 种子内容（首个键盘字符或粘贴的文本）。初次挂载时作为 textarea 初始值 */
  seedContent: string
  /** 用户取消/发送完成后关闭 */
  onClose: () => void
}

/**
 * 固定在浏览器底部的消息输入条。
 *
 * 触发条件由 App 层决定（选中了 session + 键盘/粘贴事件）；本组件只负责渲染
 * 和发送：textarea 自动聚焦，`Enter` 发送、`Shift+Enter` 换行、`Esc` 取消。
 * 发送走 `POST /api/sessions/:id/inject`，消息在下一个 Stop hook 到达时被塞
 * 给 Claude 作为下一轮输入。
 */
export function SessionComposer({
  session,
  seedContent,
  onClose,
}: SessionComposerProps) {
  const [value, setValue] = useState(seedContent)
  const [sending, setSending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const textareaRef = useRef<HTMLTextAreaElement | null>(null)
  const toast = useToast()

  // seedContent 变化（切换 session）时重置内容。
  // 同时复位 sending：SessionComposer 挂在 App 顶层，`session=null` 时组件
  // 不 unmount 只 return null，useState 是粘的；上一次发送成功后忘了关
  // sending 就会让下一次打开组件时按钮一直卡在 "Sending…"。
  useEffect(() => {
    setValue(seedContent)
    setError(null)
    setSending(false)
  }, [seedContent, session?.id])

  // 挂载后自动聚焦并把光标放到末尾（种子字符之后）
  useEffect(() => {
    const el = textareaRef.current
    if (!el) return
    el.focus()
    const len = el.value.length
    el.setSelectionRange(len, len)
  }, [session?.id])

  if (!session) return null

  const submit = async () => {
    const content = value.trim()
    if (!content) return
    setSending(true)
    setError(null)
    const shortId = session.id.slice(0, 8)
    // 打满日志，便于事后对账：发到哪个 full id、title 是什么
    console.log(
      '[Composer.submit] → injecting to sid=%s title=%s contentLen=%d',
      session.id,
      session.title,
      content.length,
    )
    try {
      await injectToSession(session.id, content)
      toast.push('success', `Sent to ${session.title} (${shortId})`)
      onClose()
    } catch (e) {
      const msg = (e as Error).message || 'Send failed'
      setError(msg)
    } finally {
      // 永远关 sending——成功分支以前走 onClose() 就完事了，但 App 里
      // SessionComposer 是常驻、只是 `session=null` 时 return null，state
      // 会粘住；下次打开 textarea 会停在 disabled、按钮停在 "Sending…"。
      setSending(false)
    }
  }

  const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    // nativeEvent.isComposing → 避免 IME 输入中（拼音/日文等）按 Enter 误触发发送
    const composing = (e.nativeEvent as KeyboardEvent).isComposing
    if (e.key === 'Enter' && !e.shiftKey && !composing) {
      e.preventDefault()
      submit()
      return
    }
    if (e.key === 'Escape') {
      e.preventDefault()
      onClose()
      return
    }
  }

  return (
    <div className="session-composer">
      <div className="session-composer__inner">
        <div className="session-composer__header">
          <span className="session-composer__label">To:</span>
          <span className="session-composer__target" title={session.id}>
            {session.title}
            <span className="session-composer__plugin">
              {' · '}
              {session.pluginDisplayName}
              {' · '}
              <code style={{ fontSize: 10, opacity: 0.75 }}>
                {session.id.slice(0, 8)}
              </code>
            </span>
          </span>
          <span className="session-composer__hint">
            Enter to send · Shift+Enter newline · Esc to cancel
          </span>
        </div>
        <div className="session-composer__row">
          <textarea
            ref={textareaRef}
            className="session-composer__textarea"
            value={value}
            placeholder="Type a message, it will land in the session's next turn…"
            disabled={sending}
            onChange={(e) => setValue(e.target.value)}
            onKeyDown={handleKeyDown}
            rows={2}
          />
          <button
            className="session-composer__send"
            onClick={submit}
            disabled={sending || !value.trim()}
          >
            {sending ? 'Sending…' : 'Send'}
          </button>
        </div>
        {error && <div className="session-composer__error">{error}</div>}
      </div>
    </div>
  )
}
