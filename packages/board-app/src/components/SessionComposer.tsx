import { useEffect, useRef, useState } from 'react'
import type { Session } from '../types'
import { injectToSession, uploadAttachment } from '../api'
import { useToast } from '../App'

interface SessionComposerProps {
  /** 当前选中的 session；null 时不显示 */
  session: Session | null
  /** 种子内容（首个键盘字符或粘贴的文本）。初次挂载时作为 textarea 初始值 */
  seedContent: string
  /** 用户取消/发送完成后关闭 */
  onClose: () => void
}

/** 已上传的图片附件；path 是后端落盘后的绝对路径 */
interface AttachmentItem {
  /** 前端生成的一次性 id，仅供 React key / 本地删除 */
  id: string
  /** 后端落盘的绝对路径，发送时 `@<path>` 给 Claude */
  path: string
  /** 原始文件名（用于 chip 显示，允许为空回退到 "image"） */
  filename: string
}

/**
 * 固定在浏览器底部的消息输入条。
 *
 * 触发条件由 App 层决定（选中了 session + 键盘/粘贴事件）；本组件只负责渲染
 * 和发送：textarea 自动聚焦，`Enter` 发送、`Shift+Enter` 换行、`Esc` 取消。
 *
 * 额外支持：往 textarea 里粘贴图片会触发 `uploadAttachment`，成功后以 chip
 * 形式出现在 textarea 上方；发送时把 `@<path>` 每行一条前置到 content 前面，
 * Claude CLI 原生支持 `@绝对路径` 语法，下一轮会把这些文件当作附件读入。
 */
export function SessionComposer({
  session,
  seedContent,
  onClose,
}: SessionComposerProps) {
  const [value, setValue] = useState(seedContent)
  const [sending, setSending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [attachments, setAttachments] = useState<AttachmentItem[]>([])
  const textareaRef = useRef<HTMLTextAreaElement | null>(null)
  const toast = useToast()

  // seedContent 变化（切换 session）时重置内容。
  // 同时复位 sending：SessionComposer 挂在 App 顶层，`session=null` 时组件
  // 不 unmount 只 return null，useState 是粘的；上一次发送成功后忘了关
  // sending 就会让下一次打开组件时按钮一直卡在 "Sending…"。
  // attachments 同理：换 session 或重开 composer 时要清空，否则把上一个
  // session 的附件路径带到新 session 上。
  useEffect(() => {
    setValue(seedContent)
    setError(null)
    setSending(false)
    setAttachments([])
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
    const body = value.trim()
    // 允许"只附件不带文字"的发送 —— 例如：粘贴一张截图直接按 Send
    if (!body && attachments.length === 0) return

    // 拼最终 content：`@<path>` 每行一条在前，用户文本在后
    const atLines = attachments.map((a) => `@${a.path}`).join('\n')
    const content = atLines
      ? body
        ? `${atLines}\n${body}`
        : atLines
      : body

    setSending(true)
    setError(null)
    const shortId = session.id.slice(0, 8)
    // 打满日志，便于事后对账：发到哪个 full id、title 是什么
    console.log(
      '[Composer.submit] → injecting to sid=%s title=%s contentLen=%d attachments=%d',
      session.id,
      session.title,
      content.length,
      attachments.length,
    )
    try {
      await injectToSession(session.id, content)
      toast.push('success', `Sent to ${session.title} (${shortId})`)
      setAttachments([])
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

  const handlePaste = async (e: React.ClipboardEvent<HTMLTextAreaElement>) => {
    const items = e.clipboardData?.items
    if (!items || items.length === 0) return

    // 收集本次粘贴里所有 image/* 的 File —— Chrome 在截图时只塞一条，
    // 但某些来源（Finder 多选拖到剪贴板）可能塞多条
    const files: File[] = []
    for (let i = 0; i < items.length; i++) {
      const it = items[i]
      if (it.kind === 'file' && it.type.startsWith('image/')) {
        const f = it.getAsFile()
        if (f) files.push(f)
      }
    }

    if (files.length === 0) {
      // 没图片 → 不拦截，让默认的文本粘贴行为跑
      return
    }

    // 只在确实消费了图片时 preventDefault，保留纯文本粘贴的默认行为
    e.preventDefault()

    for (const f of files) {
      try {
        const r = await uploadAttachment(session.id, f)
        setAttachments((prev) => [
          ...prev,
          {
            id: `${Date.now()}-${Math.random().toString(16).slice(2, 8)}`,
            path: r.path,
            filename: r.filename || f.name || 'image',
          },
        ])
        setError(null)
      } catch (err) {
        const msg = (err as Error).message || 'Upload failed'
        console.error('[Composer.paste] upload failed', err)
        setError(`Upload failed: ${msg}`)
      }
    }
  }

  const removeAttachment = (id: string) => {
    setAttachments((prev) => prev.filter((a) => a.id !== id))
  }

  const truncateName = (name: string, max = 24): string =>
    name.length <= max ? name : name.slice(0, max - 1) + '…'

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
            Enter to send · Shift+Enter newline · Esc to cancel · Paste to attach image
          </span>
        </div>
        {attachments.length > 0 && (
          <div className="session-composer__attachments">
            {attachments.map((a) => (
              <span
                key={a.id}
                className="session-composer__chip"
                title={a.path}
              >
                <span className="session-composer__chip-name">
                  {truncateName(a.filename)}
                </span>
                <button
                  type="button"
                  className="session-composer__chip-remove"
                  onClick={() => removeAttachment(a.id)}
                  aria-label={`Remove ${a.filename}`}
                  disabled={sending}
                >
                  ×
                </button>
              </span>
            ))}
          </div>
        )}
        <div className="session-composer__row">
          <textarea
            ref={textareaRef}
            className="session-composer__textarea"
            value={value}
            placeholder="Type a message, it will land in the session's next turn…"
            disabled={sending}
            onChange={(e) => setValue(e.target.value)}
            onKeyDown={handleKeyDown}
            onPaste={handlePaste}
            rows={2}
          />
          <button
            className="session-composer__send"
            onClick={submit}
            disabled={sending || (!value.trim() && attachments.length === 0)}
          >
            {sending ? 'Sending…' : 'Send'}
          </button>
        </div>
        {error && <div className="session-composer__error">{error}</div>}
      </div>
    </div>
  )
}
