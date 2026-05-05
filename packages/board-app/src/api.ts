import type {
  BoardState,
  Channel,
  Message,
  MessageStatus,
  Mode,
} from './types'

/** Uniform error thrown by the API helpers. */
export class ApiRequestError extends Error {
  code: string
  status: number
  constructor(code: string, message: string, status: number) {
    super(message)
    this.code = code
    this.status = status
  }
}

async function jsonRequest<T>(
  input: string,
  init?: RequestInit,
): Promise<T> {
  const res = await fetch(input, {
    ...init,
    headers: {
      'Content-Type': 'application/json',
      ...(init?.headers ?? {}),
    },
  })
  const text = await res.text()
  let body: any = null
  if (text) {
    try {
      body = JSON.parse(text)
    } catch {
      body = null
    }
  }
  if (!res.ok) {
    const code: string = body?.error?.code ?? 'http_error'
    const msg: string = body?.error?.message ?? res.statusText ?? 'Request failed'
    throw new ApiRequestError(code, msg, res.status)
  }
  return body as T
}

// -- state -----------------------------------------------------------------

export function fetchState(): Promise<BoardState> {
  return jsonRequest<BoardState>('/api/state')
}

// -- channels --------------------------------------------------------------

export async function createChannel(input: {
  name: string
  mode?: Mode
  description?: string
}): Promise<Channel> {
  const r = await jsonRequest<{ channel: Channel }>('/api/channels', {
    method: 'POST',
    body: JSON.stringify(input),
  })
  return r.channel
}

export async function deleteChannel(name: string): Promise<void> {
  await jsonRequest<{ ok: boolean }>(
    `/api/channels/${encodeURIComponent(name)}`,
    { method: 'DELETE' },
  )
}

export async function addMember(
  channel: string,
  alias: string,
  sessionId: string,
): Promise<Channel> {
  const r = await jsonRequest<{ channel: Channel }>(
    `/api/channels/${encodeURIComponent(channel)}/members`,
    {
      method: 'POST',
      body: JSON.stringify({ alias, sessionId }),
    },
  )
  return r.channel
}

export async function removeMember(
  channel: string,
  alias: string,
): Promise<Channel> {
  const r = await jsonRequest<{ channel: Channel }>(
    `/api/channels/${encodeURIComponent(channel)}/members/${encodeURIComponent(alias)}`,
    { method: 'DELETE' },
  )
  return r.channel
}

export async function setChannelMode(
  channel: string,
  mode: Mode,
): Promise<Channel> {
  const r = await jsonRequest<{ channel: Channel }>(
    `/api/channels/${encodeURIComponent(channel)}/mode`,
    {
      method: 'POST',
      body: JSON.stringify({ mode }),
    },
  )
  return r.channel
}

// -- messages --------------------------------------------------------------

export async function sendMessage(input: {
  channel: string
  fromAlias: string
  toAlias: string
  content: string
  replyTo?: string
  injectedByHuman?: boolean
}): Promise<Message> {
  const r = await jsonRequest<{ message: Message }>('/api/messages/send', {
    method: 'POST',
    body: JSON.stringify(input),
  })
  return r.message
}

export async function holdMessage(id: string): Promise<Message> {
  const r = await jsonRequest<{ message: Message }>(
    `/api/messages/${encodeURIComponent(id)}/hold`,
    { method: 'POST' },
  )
  return r.message
}

export async function deliverMessage(id: string): Promise<Message> {
  const r = await jsonRequest<{ message: Message }>(
    `/api/messages/${encodeURIComponent(id)}/deliver`,
    { method: 'POST' },
  )
  return r.message
}

export async function dropMessage(id: string): Promise<Message> {
  const r = await jsonRequest<{ message: Message }>(
    `/api/messages/${encodeURIComponent(id)}/drop`,
    { method: 'POST' },
  )
  return r.message
}

/**
 * Spawn 一个新 Claude CLI session：按 cwd 打开一个新的 Ghostty 窗口，里面自动
 * 跑 `claude`（沿用本地 `~/.claude/` 的 OAuth，无需重新登录）。
 */
export async function spawnSession(input: {
  cwd: string
  command?: string
  createIfMissing?: boolean
  termProgram?: string
}): Promise<{ ok: boolean; cwd: string; command: string }> {
  return jsonRequest<{ ok: boolean; cwd: string; command: string }>(
    '/api/sessions/spawn',
    {
      method: 'POST',
      body: JSON.stringify(input),
    },
  )
}

// -- assistant (chat with tools, streamed via SSE) -------------------------

/** 一条对话消息（用户 / assistant） */
export interface AssistantMessage {
  role: 'user' | 'assistant'
  content: string
}

/** SSE event from the assistant orchestrator (mirror of backend payloads). */
export type AssistantEvent =
  | { type: 'delta'; text: string }
  | { type: 'tool_call'; id: string; name: string; args: unknown }
  | { type: 'tool_result'; id: string; result: unknown }
  | { type: 'error'; message: string }
  | { type: 'done' }

/** Settings payload sent with each chat request — mirrors Swift `AssistantSettings`. */
export interface AssistantChatSettings {
  provider: 'openai' | 'anthropic' | 'local'
  apiKey?: string
  baseUrl?: string
  model?: string
  enabledTools?: string[]
}

/**
 * Stream the assistant's reply as a sequence of SSE events. Caller consumes
 * via `for await (const ev of streamAssistantChat({...}))` and accumulates
 * `delta.text` into the current assistant bubble, renders tool_call /
 * tool_result chips, and stops on `done` / `error`.
 *
 * EventSource is GET-only and we need to POST messages, so this is a
 * fetch + manual SSE parser. Cancellation: `signal` aborts the underlying
 * request — the orchestrator on the server side notices the closed socket
 * within a heartbeat.
 */
export async function* streamAssistantChat(input: {
  messages: AssistantMessage[]
  settings: AssistantChatSettings
  signal?: AbortSignal
}): AsyncGenerator<AssistantEvent, void, void> {
  const res = await fetch('/api/assistant/chat', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ messages: input.messages, settings: input.settings }),
    signal: input.signal,
  })
  if (!res.ok) {
    const body = await res.text().catch(() => '')
    throw new ApiRequestError('http_error', `assistant HTTP ${res.status}: ${body.slice(0, 300)}`, res.status)
  }
  const reader = res.body?.getReader()
  if (!reader) {
    throw new ApiRequestError('no_body', 'assistant response had no body', 0)
  }
  const decoder = new TextDecoder('utf-8')
  let buffer = ''
  while (true) {
    const { done, value } = await reader.read()
    if (done) return
    buffer += decoder.decode(value, { stream: true })
    // SSE events are separated by `\n\n`. Each event has lines like
    // `event: <type>` and `data: <json>`. We only emit the data line —
    // the type is also encoded inside the data envelope from the server.
    let sepIndex: number
    while ((sepIndex = buffer.indexOf('\n\n')) >= 0) {
      const raw = buffer.slice(0, sepIndex)
      buffer = buffer.slice(sepIndex + 2)
      const ev = parseSSEEvent(raw)
      if (ev) yield ev
      if (ev?.type === 'done') return
    }
  }
}

function parseSSEEvent(raw: string): AssistantEvent | null {
  let evType = ''
  let dataLine = ''
  for (const line of raw.split('\n')) {
    if (line.startsWith('event: ')) evType = line.slice(7).trim()
    else if (line.startsWith('data: ')) dataLine += line.slice(6)
  }
  if (!evType) return null
  let data: any = {}
  if (dataLine) {
    try { data = JSON.parse(dataLine) } catch { /* fall through with empty */ }
  }
  switch (evType) {
    case 'delta':
      return { type: 'delta', text: typeof data.text === 'string' ? data.text : '' }
    case 'tool_call':
      return {
        type: 'tool_call',
        id: String(data.id ?? ''),
        name: String(data.name ?? ''),
        args: data.args,
      }
    case 'tool_result':
      return { type: 'tool_result', id: String(data.id ?? ''), result: data.result }
    case 'error':
      return { type: 'error', message: typeof data.message === 'string' ? data.message : 'unknown error' }
    case 'done':
      return { type: 'done' }
    default:
      return null
  }
}

/**
 * @deprecated kept for backward compat. New callers should use
 * `streamAssistantChat` to get streaming + tool events. This wrapper drains
 * the stream and returns the concatenated assistant text only.
 */
export async function assistantChat(
  messages: AssistantMessage[],
): Promise<{ content: string }> {
  let content = ''
  for await (const ev of streamAssistantChat({
    messages,
    settings: { provider: 'local' },
  })) {
    if (ev.type === 'delta') content += ev.text
    if (ev.type === 'error') throw new ApiRequestError('assistant', ev.message, 500)
  }
  return { content }
}

// -- transcript ------------------------------------------------------------

/** 富 transcript block（对应 Swift FullTranscriptBlock） */
export interface TranscriptBlock {
  type: 'text' | 'thinking' | 'tool_use' | 'tool_result'
  text?: string
  toolId?: string
  toolName?: string
  toolInputJSON?: string
  toolUseId?: string
  toolResultText?: string
  toolResultTruncated?: boolean
}

/** 富 transcript entry（对应 Swift FullTranscriptEntry） */
export interface TranscriptEntryFull {
  id: string
  type: 'user' | 'assistant' | 'system' | 'injected'
  timestamp: string | null
  blocks: TranscriptBlock[]
}

export async function fetchTranscript(
  sessionId: string,
  opts: { limit?: number } = {},
): Promise<{ entries: TranscriptEntryFull[]; sessionId: string }> {
  const qs = opts.limit ? `?limit=${opts.limit}` : ''
  return jsonRequest<{ entries: TranscriptEntryFull[]; sessionId: string }>(
    `/api/sessions/${encodeURIComponent(sessionId)}/transcript${qs}`,
  )
}

/**
 * 把一条消息直接注入到某个 Claude session 的 inbox。
 *
 * - **CLI session**：AgentInboxShell 立刻通过 Ghostty/iTerm/Apple Terminal
 *   typeIn 推到终端，session 看上去就像用户敲进去的。`delivery` 为 nil。
 * - **Desktop session**：claude-desktop 子进程没 tty 可以 typeIn，消息只能
 *   等下一个 Stop hook 触发 drainResponseForDesktopStop 转成 block-decision
 *   reason 才被 Claude.app 看到。`delivery: 'queued_until_next_turn'` 表示
 *   "已收下、待 desktop 这条 turn 结束才生效"。session 空闲时可能等很久。
 */
export interface InjectResult {
  message: Message
  delivery: 'queued_until_next_turn' | null
}

export async function injectToSession(
  id: string,
  content: string,
): Promise<InjectResult> {
  const r = await jsonRequest<{ message: Message; delivery?: string | null }>(
    `/api/sessions/${encodeURIComponent(id)}/inject`,
    {
      method: 'POST',
      body: JSON.stringify({ content }),
    },
  )
  const delivery: InjectResult['delivery'] =
    r.delivery === 'queued_until_next_turn' ? r.delivery : null
  return { message: r.message, delivery }
}

/**
 * 把一张图片附件上传到 session，得到一个后端落盘后的绝对路径。
 *
 * 后端期望的是 base64 JSON 而不是 multipart —— 原因在 `Sources/Board/AttachmentsAPI.swift`
 * 的顶注里：Swifter multipart 支持烂，base64 的 33% 膨胀对几 MB 图片不是问题。
 *
 * 成功时返回 `{path, filename}`；path 可以直接 `@<path>` 前置到下一条 inject
 * 的 content 里，Claude CLI 会把它当作下一轮 user message 的附件读入。
 */
export async function uploadAttachment(
  sessionId: string,
  file: File,
): Promise<{ path: string; filename: string }> {
  const dataBase64 = await fileToBase64(file)
  return jsonRequest<{ path: string; filename: string }>(
    `/api/sessions/${encodeURIComponent(sessionId)}/attachments`,
    {
      method: 'POST',
      body: JSON.stringify({
        filename: file.name || 'paste',
        contentType: file.type || 'application/octet-stream',
        dataBase64,
      }),
    },
  )
}

/** 读取 File 为不含 data:URL 前缀的 base64 字符串 */
function fileToBase64(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onerror = () => reject(reader.error ?? new Error('FileReader error'))
    reader.onload = () => {
      const result = reader.result
      if (typeof result !== 'string') {
        reject(new Error('FileReader did not return a string'))
        return
      }
      // `data:<mime>;base64,<payload>` → payload
      const comma = result.indexOf(',')
      resolve(comma >= 0 ? result.slice(comma + 1) : result)
    }
    reader.readAsDataURL(file)
  })
}

/**
 * 触发该 session 的 terminal 跳转（等同于 Island 点击卡片）。
 * 成功返回 true；失败 toast 错误并返回 false。
 */
export async function activateSession(id: string): Promise<boolean> {
  console.log('[activateSession] POST /api/sessions/' + id.slice(0, 8) + '/activate')
  try {
    await jsonRequest<{ ok: boolean }>(
      `/api/sessions/${encodeURIComponent(id)}/activate`,
      { method: 'POST' },
    )
    console.log('[activateSession] OK for', id.slice(0, 8))
    return true
  } catch (e) {
    console.error('[activateSession] FAILED for', id.slice(0, 8), e)
    return false
  }
}

export async function listChannelMessages(
  channel: string,
  opts: { statuses?: MessageStatus[]; limit?: number } = {},
): Promise<Message[]> {
  const params = new URLSearchParams()
  if (opts.statuses && opts.statuses.length > 0) {
    params.set('status', opts.statuses.join(','))
  }
  if (typeof opts.limit === 'number') {
    params.set('limit', String(opts.limit))
  }
  const qs = params.toString()
  const url =
    `/api/channels/${encodeURIComponent(channel)}/messages` +
    (qs ? `?${qs}` : '')
  const r = await jsonRequest<{ messages: Message[] }>(url)
  return r.messages
}

// -- WS --------------------------------------------------------------------

/**
 * Connect to /api/events. The server broadcasts `{type:"state.changed"}` frames
 * (plus one on open). We call `onChange` for each of those. Auto-reconnect
 * with 1.5s backoff.
 *
 * Returns a disposer.
 */
export function connectEvents(
  onChange: () => void,
  onStatus: (connected: boolean) => void,
): () => void {
  let ws: WebSocket | null = null
  let reconnectTimer: number | null = null
  let stopped = false

  const connect = () => {
    const proto = location.protocol === 'https:' ? 'wss' : 'ws'
    const url = `${proto}://${location.host}/api/events`
    ws = new WebSocket(url)
    ws.onopen = () => onStatus(true)
    ws.onmessage = (e) => {
      try {
        const parsed = JSON.parse(e.data)
        if (parsed && parsed.type === 'state.changed') {
          onChange()
        }
      } catch {
        // ignore malformed frames
      }
    }
    ws.onclose = () => {
      onStatus(false)
      if (!stopped) {
        reconnectTimer = window.setTimeout(connect, 1500)
      }
    }
    ws.onerror = () => {
      /* onclose will fire */
    }
  }
  connect()

  return () => {
    stopped = true
    if (reconnectTimer) {
      clearTimeout(reconnectTimer)
      reconnectTimer = null
    }
    ws?.close()
  }
}
