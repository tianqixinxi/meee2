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

// -- assistant (ask & spawn) -----------------------------------------------

/** 一条对话消息（用户 / assistant） */
export interface AssistantMessage {
  role: 'user' | 'assistant'
  content: string
}

/**
 * 全局 "ask & spawn" assistant：跑本地 `claude -p` 帮你挑 cwd。
 * 全部历史每次整体 POST；assistant 判断足够了就在回复末尾吐 ```spawn fence。
 */
export async function assistantChat(
  messages: AssistantMessage[],
): Promise<{ content: string }> {
  return jsonRequest<{ content: string }>('/api/assistant/chat', {
    method: 'POST',
    body: JSON.stringify({ messages }),
  })
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
  type: 'user' | 'assistant' | 'system'
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
 * 把一条消息直接注入到某个 Claude session 的 inbox。下一个 Stop hook
 * 到达时会被塞给 Claude 作为 block-decision 输入（= 下一轮的 user message）。
 */
export async function injectToSession(
  id: string,
  content: string,
): Promise<Message> {
  const r = await jsonRequest<{ message: Message }>(
    `/api/sessions/${encodeURIComponent(id)}/inject`,
    {
      method: 'POST',
      body: JSON.stringify({ content }),
    },
  )
  return r.message
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
