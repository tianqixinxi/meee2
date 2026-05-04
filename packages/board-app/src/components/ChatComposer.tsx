// 共享的 chat 输入组件 —— 抽出 SessionDock 和 AssistantChat 共用的那套
// "textarea + 附件 chips + send 按钮 + bottombar" 输入框。
//
// 这之前两边各写了一份几乎一样的 JSX + 键盘 handler，只在"send 之后干嘛"
// 上不一样：SessionDock 调 injectToSession 把内容塞给现有 session；
// AssistantChat 把内容当成新一轮 user message 喂给 streaming chat。现在
// 把所有 input UX 收进这个组件里，两边都用 `<ChatComposer onSend={...}>`，
// 真·复用。
//
// 状态自管：value / attachments / sending / error。父组件唯一职责是收到
// `onSend(content)` 后做业务（inject / spawn / chat），并决定 bottombar
// 显示什么 chip / 标签（通过 `bottomLeft` / `bottomRight` slots）。
//
// 命令式 handle：暴露 `appendAndFocus(text)`，给 canvas 层"按可打印键
// 直接注入到正在 mount 的 chatbox"用 —— 现在 SessionDock 已经在用，
// AssistantChat 也能用同款机制（key/paste seed）。

import {
  forwardRef,
  useEffect,
  useImperativeHandle,
  useRef,
  useState,
} from 'react'

interface AttachmentItem {
  id: string
  path: string
  filename: string
}

export interface ChatComposerHandle {
  /** 把文本追加到 textarea 当前光标位置并 focus。 */
  appendAndFocus: (text: string) => void
  /** 直接 focus textarea（不改 value）。 */
  focus: () => void
}

interface Props {
  /** 用户按 Enter / 点 send 时调。content 已经把附件渲染成 `@<path>\n` 前缀。
   *  父组件返回的 promise 决定 sending 状态：成功 → 清空；失败 → 保留输入 + 显示 error。*/
  onSend: (content: string) => Promise<void> | void
  /** 用户按 Esc 且当前 value/附件都空时调（非空时优先清空）。可空 → 直接吞 Esc。 */
  onEscape?: () => void
  /** 上传粘贴的图片；返回路径。不传 → paste 图片不会处理（让浏览器原生粘贴行为）。 */
  uploadImage?: (file: File) => Promise<{ path: string; filename: string }>
  initialValue?: string
  placeholder?: string
  /** focus on mount。SessionDock / AssistantChat 都要 true，保留显式控制以备扩展。 */
  autoFocus?: boolean
  /** Bottombar 右下角内容。SessionDock 放 model/status；AssistantChat 放 "Assistant" 标签 + busy 指示。 */
  bottomRight?: React.ReactNode
  /** Bottombar 左下角内容。SessionDock 放 attach / quick-cmd 占位按钮；AssistantChat 一般空。 */
  bottomLeft?: React.ReactNode
  /** Sending 时禁用 textarea 并把 send 换成 spinner。父组件想强制独立控制 busy 时用。 */
  externalBusy?: boolean
}

export const ChatComposer = forwardRef<ChatComposerHandle, Props>(function ChatComposer(
  {
    onSend,
    onEscape,
    uploadImage,
    initialValue,
    placeholder = 'Type a message…',
    autoFocus = true,
    bottomRight,
    bottomLeft,
    externalBusy,
  },
  ref,
) {
  const [value, setValue] = useState<string>(() => initialValue ?? '')
  const [attachments, setAttachments] = useState<AttachmentItem[]>([])
  const [sending, setSending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const textareaRef = useRef<HTMLTextAreaElement | null>(null)

  const busy = sending || !!externalBusy

  useEffect(() => {
    if (!autoFocus) return
    const el = textareaRef.current
    if (!el) return
    el.focus()
    const pos = el.value.length
    el.setSelectionRange(pos, pos)
    // 仅在 mount 时跑一次
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  useImperativeHandle(
    ref,
    () => ({
      focus() {
        textareaRef.current?.focus()
      },
      appendAndFocus(text: string) {
        const el = textareaRef.current
        if (!el) {
          setValue((v) => v + text)
          return
        }
        const start = el.selectionStart ?? el.value.length
        const end = el.selectionEnd ?? el.value.length
        const next = el.value.slice(0, start) + text + el.value.slice(end)
        setValue(next)
        // 等 React 把 next 写回 DOM 再 focus + 移光标
        requestAnimationFrame(() => {
          if (!textareaRef.current) return
          const pos = start + text.length
          textareaRef.current.focus()
          textareaRef.current.setSelectionRange(pos, pos)
        })
      },
    }),
    [],
  )

  const submit = async () => {
    const body = value.trim()
    if (!body && attachments.length === 0) return
    if (busy) return

    const atLines = attachments.map((a) => `@${a.path}`).join('\n')
    const content = atLines ? (body ? `${atLines}\n${body}` : atLines) : body

    setSending(true)
    setError(null)
    try {
      await onSend(content)
      setValue('')
      setAttachments([])
    } catch (e) {
      setError((e as Error).message || 'Send failed')
    } finally {
      setSending(false)
    }
  }

  // IME 组词期间不能 submit。仅靠 `e.nativeEvent.isComposing` 在 WKWebView
  // + macOS 中文 IME 下不可靠（确认候选词时 Enter 已经收到 compositionend，
  // isComposing 翻成 false，但用户感觉还在选词），所以三重叠保：
  //   1. composing ref —— 我们自己 track compositionstart / compositionend
  //   2. e.nativeEvent.isComposing —— React 标准检查
  //   3. e.nativeEvent.keyCode === 229 —— IME 吃住 keydown 时浏览器送的占位
  // 任一为真都不 submit。compositionend 后我们再 setTimeout 0 才把 ref 置回，
  // 让"刚刚确认候选词的那个 Enter"也被吞掉（它在 compositionend 之后同帧到达）。
  const composingRef = useRef(false)

  const handleCompositionStart = () => {
    composingRef.current = true
  }
  const handleCompositionEnd = () => {
    // 推迟一拍：Enter 提交候选词时 compositionend 先到、Enter 的 keydown
    // 紧跟其后；用 setTimeout 0 让 keydown handler 还能读到 ref=true。
    setTimeout(() => { composingRef.current = false }, 0)
  }

  const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    const native = e.nativeEvent as KeyboardEvent
    const composing = composingRef.current || native.isComposing || native.keyCode === 229
    if (e.key === 'Enter' && !e.shiftKey && !composing) {
      e.preventDefault()
      void submit()
      return
    }
    if (e.key === 'Escape') {
      // IME 还在组词时 Esc 是给 IME 取消候选用的，别吃掉。
      if (composing) return
      e.preventDefault()
      if (value || attachments.length > 0) {
        setValue('')
        setAttachments([])
      } else {
        onEscape?.()
      }
    }
  }

  const handlePaste = async (e: React.ClipboardEvent<HTMLTextAreaElement>) => {
    if (!uploadImage) return
    const items = e.clipboardData?.items
    if (!items || items.length === 0) return

    const files: File[] = []
    for (let i = 0; i < items.length; i++) {
      const it = items[i]
      if (it.kind === 'file' && it.type.startsWith('image/')) {
        const f = it.getAsFile()
        if (f) files.push(f)
      }
    }
    if (files.length === 0) return
    e.preventDefault()

    for (const f of files) {
      try {
        const r = await uploadImage(f)
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
        setError(`Upload failed: ${(err as Error).message || 'unknown'}`)
      }
    }
  }

  const removeAttachment = (id: string) => {
    setAttachments((prev) => prev.filter((a) => a.id !== id))
  }

  const truncateName = (name: string, max = 24): string =>
    name.length <= max ? name : name.slice(0, max - 1) + '…'

  const canSend = !busy && (!!value.trim() || attachments.length > 0)

  return (
    <>
      {/* ── input box（attachments + textarea + send button）─────── */}
      <div className="session-dock__input-box">
        {attachments.length > 0 && (
          <div className="cc-attachments">
            {attachments.map((a) => (
              <span key={a.id} className="cc-chip" title={a.path}>
                <span className="cc-chip-name">{truncateName(a.filename)}</span>
                <button
                  type="button"
                  className="cc-chip-remove"
                  onClick={() => removeAttachment(a.id)}
                  aria-label={`Remove ${a.filename}`}
                  disabled={busy}
                >
                  ×
                </button>
              </span>
            ))}
          </div>
        )}
        <textarea
          ref={textareaRef}
          className="cc-textarea"
          value={value}
          placeholder={placeholder}
          disabled={busy}
          onChange={(e) => setValue(e.target.value)}
          onKeyDown={handleKeyDown}
          onCompositionStart={handleCompositionStart}
          onCompositionEnd={handleCompositionEnd}
          onPaste={uploadImage ? handlePaste : undefined}
          rows={2}
        />
        <button
          className="cc-send-arrow"
          onClick={submit}
          disabled={!canSend}
          title={busy ? 'Sending…' : 'Send (Enter)'}
          aria-label="Send message"
          type="button"
        >
          {busy ? (
            <span className="cc-spinner" aria-hidden />
          ) : (
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" aria-hidden>
              <path
                d="M9 17l-4-4m0 0l4-4m-4 4h11a4 4 0 0 0 4-4V6"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
              />
            </svg>
          )}
        </button>
      </div>

      {/* ── bottombar（左/右槽位由父组件填）──────────────────────── */}
      <div className="session-dock__bottombar">
        <div className="cc-bottom-left">{bottomLeft}</div>
        <div className="cc-bottom-right">{bottomRight}</div>
      </div>

      {error && <div className="cc-error">{error}</div>}
    </>
  )
})
