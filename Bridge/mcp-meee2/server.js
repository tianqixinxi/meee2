#!/usr/bin/env node
// meee2 MCP server — exposes A2A messaging to Claude/Codex sessions as
// native tools. Transport is stdio (the host app spawns us as a subprocess and
// speaks JSON-RPC over stdin/stdout).
//
// All tools are thin HTTP shims over the local BoardServer (127.0.0.1:9876
// by default; override with MEEE2_API_URL). If the BoardServer isn't
// running — meee2 app not launched — every tool returns an instructive
// error instead of crashing the MCP runtime.

import fs from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js'

const DEFAULT_PORT = 9876
const MAX_PORT = 9976
let cachedAPI = null

// ─── tool schemas ─────────────────────────────────────────────────────────
// Descriptions are the first thing the model sees when deciding whether to
// call; be specific about when to use, what fromAlias means, and how
// broadcast works.
const TOOLS = [
  {
    name: 'send_message',
    description:
      'Send a message on a meee2 A2A channel. `fromAlias` must be your own ' +
      'session\'s alias in that channel (see list_channels). `toAlias` is ' +
      'either a specific member alias or "*" for broadcast to everyone ' +
      'else. On auto-mode channels the message is delivered immediately; ' +
      'on intercept/paused channels it sits pending for human approval.',
    inputSchema: {
      type: 'object',
      properties: {
        channel: { type: 'string', description: 'Channel name.' },
        fromAlias: {
          type: 'string',
          description: 'Your own alias on this channel.',
        },
        toAlias: {
          type: 'string',
          description: 'Recipient alias, or "*" to broadcast.',
        },
        content: { type: 'string', description: 'Message body.' },
        replyTo: {
          type: 'string',
          description: 'Optional message id this is a reply to.',
        },
      },
      required: ['channel', 'fromAlias', 'toAlias', 'content'],
    },
  },
  {
    name: 'list_channels',
    description:
      'List every non-operator meee2 channel with its mode, members ' +
      '(alias + sessionId), and pending message count. Use this first to ' +
      'find your own alias before calling send_message.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'list_sessions',
    description:
      'List every agent session meee2 currently tracks — id, title, ' +
      'project cwd, status. Useful to find a target session before asking ' +
      'to add it to a channel.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'read_inbox',
    description:
      'Read pending A2A messages addressed to a given session (i.e. the ' +
      'union of delivered direct-inbox messages plus channel-pending messages ' +
      'where the session is a member and the sender is someone else). If ' +
      'sessionId is omitted, meee2 resolves the current Claude/Codex session ' +
      'from environment variables. For Codex current sessions, direct inbox ' +
      'messages are consumed by default because Codex has no Claude Stop hook.',
    inputSchema: {
      type: 'object',
      properties: {
        sessionId: {
          type: 'string',
          description:
            'Optional full session id, or a prefix meee2 can resolve uniquely.',
        },
        consume: {
          type: 'boolean',
          description:
            'When true, delivered direct-inbox messages are drained after reading. Defaults to true for the current Codex thread, false otherwise.',
        },
      },
    },
  },
  {
    name: 'create_channel',
    description:
      'Create a new A2A channel for ad-hoc multi-agent collaboration. Names ' +
      'must match [a-z0-9_-]{1,64}. Channel starts empty — call add_member ' +
      'next to bring sessions in. Use this when you need a fresh coordination ' +
      'space (e.g. "the four of us reviewing PR #42") rather than reusing an ' +
      'existing topic-mismatched channel. ' +
      'NOTE: there is no delete_channel from MCP — channel cleanup is human-only.',
    inputSchema: {
      type: 'object',
      properties: {
        name: {
          type: 'string',
          description: 'Channel name (lowercase, digits, _ -, ≤ 64 chars).',
        },
        mode: {
          type: 'string',
          enum: ['auto', 'intercept', 'paused'],
          description:
            'auto: deliver immediately (default). intercept: hold for human ' +
            'approval. paused: hold indefinitely.',
        },
        description: {
          type: 'string',
          description:
            'Short explanation of what this channel is for. Visible in UI + ' +
            'list_channels; helps other agents decide whether to join.',
        },
      },
      required: ['name'],
    },
  },
  {
    name: 'add_member',
    description:
      'Add a session as a member of an existing channel. The added session ' +
      'will receive an orientation message (synthetic operator → session) ' +
      'announcing membership + teammates + how to use send_message; existing ' +
      'members get a "<alias> joined" heads-up. So this IS visible to ' +
      'everyone — use it when you actually want the session aware of the ' +
      'collaboration. Pick an alias that disambiguates the session within ' +
      'this channel (e.g. project basename + sid prefix).',
    inputSchema: {
      type: 'object',
      properties: {
        channel: { type: 'string', description: 'Existing channel name.' },
        alias: {
          type: 'string',
          description:
            'Alias for the joining session within this channel ([a-z0-9_-]{1,64}). ' +
            'Must be unique within the channel.',
        },
        sessionId: {
          type: 'string',
          description:
            'Full session id, or a unique prefix (resolve via list_sessions).',
        },
      },
      required: ['channel', 'alias', 'sessionId'],
    },
  },
  {
    name: 'leave_channel',
    description:
      'Voluntarily leave a channel under your alias. Remaining members will ' +
      'be notified ("<alias> left"). Use this when the collaboration is done ' +
      'or no longer relevant to your task. NOTE: you can only remove ' +
      'YOURSELF — there is no kick-other-agent operation from MCP.',
    inputSchema: {
      type: 'object',
      properties: {
        channel: { type: 'string', description: 'Channel name.' },
        alias: { type: 'string', description: 'Your own alias on this channel.' },
      },
      required: ['channel', 'alias'],
    },
  },
]

// ─── HTTP shim ────────────────────────────────────────────────────────────

function runtimeInfoPath() {
  return path.join(os.homedir(), 'Library', 'Application Support', 'meee2', 'board-server.json')
}

async function isMeee2API(api) {
  try {
    const res = await fetch(`${api}/api/health`, { signal: AbortSignal.timeout(1200) })
    if (!res.ok) return false
    const json = await res.json().catch(() => null)
    return json?.name === 'meee2'
  } catch {
    return false
  }
}

async function apiFromRuntimeInfo() {
  try {
    const raw = await fs.readFile(runtimeInfoPath(), 'utf8')
    const json = JSON.parse(raw)
    return typeof json?.url === 'string' ? json.url : null
  } catch {
    return null
  }
}

async function discoverAPI(force = false) {
  if (process.env.MEEE2_API_URL) return process.env.MEEE2_API_URL

  if (!force && cachedAPI && await isMeee2API(cachedAPI)) {
    return cachedAPI
  }

  const runtimeAPI = await apiFromRuntimeInfo()
  if (runtimeAPI && await isMeee2API(runtimeAPI)) {
    cachedAPI = runtimeAPI
    return runtimeAPI
  }

  for (let port = DEFAULT_PORT; port <= MAX_PORT; port += 1) {
    const api = `http://127.0.0.1:${port}`
    if (await isMeee2API(api)) {
      cachedAPI = api
      return api
    }
  }

  return `http://127.0.0.1:${DEFAULT_PORT}`
}

async function callApi(method, path, body) {
  let res
  let api = await discoverAPI()
  try {
    res = await fetch(`${api}${path}`, {
      method,
      headers: { 'content-type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined,
    })
  } catch (e) {
    cachedAPI = null
    api = await discoverAPI(true)
    try {
      res = await fetch(`${api}${path}`, {
        method,
        headers: { 'content-type': 'application/json' },
        body: body ? JSON.stringify(body) : undefined,
      })
    } catch (retryError) {
      throw new Error(
        `meee2 BoardServer unreachable at ${api} — is the meee2 app running? ` +
          `(${retryError.message || retryError})`,
      )
    }
  }
  const text = await res.text()
  let json = null
  if (text) {
    try {
      json = JSON.parse(text)
    } catch {
      // non-JSON body (shouldn't happen for /api/*) — carry the raw text
      if (!res.ok) throw new Error(`${res.status} ${res.statusText}: ${text}`)
      return text
    }
  }
  if (!res.ok) {
    const msg = json?.error?.message || res.statusText || 'request failed'
    throw new Error(`${res.status} ${msg}`)
  }
  return json
}

const CODEX_PREFIX = 'com.meee2.plugin.codex-'
const CLAUDE_PREFIX = 'com.meee2.plugin.claude-'

function unique(values) {
  return [...new Set(values.filter(Boolean))]
}

function rawPluginId(session) {
  const prefix = `${session.pluginId}-`
  return session.id?.startsWith(prefix) ? session.id.slice(prefix.length) : null
}

function sessionIdCandidates(session) {
  return unique([session.id, rawPluginId(session)])
}

function envSessionCandidates() {
  const claudeSid = process.env.CLAUDE_SESSION_ID
  if (claudeSid) return unique([claudeSid, `${CLAUDE_PREFIX}${claudeSid}`])

  const codexThreadId = process.env.CODEX_THREAD_ID || process.env.CODEX_SESSION_ID
  if (codexThreadId) {
    return unique([`${CODEX_PREFIX}${codexThreadId}`, codexThreadId])
  }
  return []
}

function sessionMatches(session, input) {
  return sessionIdCandidates(session).some(
    (id) => id === input || id.startsWith(input),
  )
}

function resolveSession(state, input) {
  const inputs = input ? [input] : envSessionCandidates()
  if (inputs.length === 0) {
    throw new Error(
      'sessionId required (or set CLAUDE_SESSION_ID / CODEX_THREAD_ID)',
    )
  }

  const exact = (state.sessions || []).filter((s) =>
    inputs.some((candidate) => sessionIdCandidates(s).includes(candidate)),
  )
  if (exact.length === 1) return exact[0]
  if (exact.length > 1) {
    throw new Error(`ambiguous session id '${inputs[0]}' — matched ${exact.length}`)
  }

  const matches = (state.sessions || []).filter((s) =>
    inputs.some((candidate) => sessionMatches(s, candidate)),
  )
  if (matches.length === 0) {
    throw new Error(`session not found: ${inputs[0]}`)
  }
  if (matches.length > 1) {
    throw new Error(
      `ambiguous session prefix '${inputs[0]}' — matched ${matches.length}`,
    )
  }
  return matches[0]
}

function isCurrentCodexSession(session) {
  const codexThreadId = process.env.CODEX_THREAD_ID || process.env.CODEX_SESSION_ID
  if (!codexThreadId) return false
  return sessionIdCandidates(session).includes(codexThreadId)
}

// ─── tool handlers ────────────────────────────────────────────────────────

async function handleSendMessage(args) {
  const { channel, fromAlias, toAlias, content, replyTo } = args
  const r = await callApi('POST', '/api/messages/send', {
    channel,
    fromAlias,
    toAlias,
    content,
    ...(replyTo ? { replyTo } : {}),
    // agent-initiated — not a human injection
    injectedByHuman: false,
  })
  return r.message || r
}

async function handleListChannels() {
  const state = await callApi('GET', '/api/state')
  return (state.channels || []).map((ch) => ({
    name: ch.name,
    mode: ch.mode,
    pendingCount: ch.pendingCount,
    members: ch.members,
    description: ch.description,
  }))
}

async function handleListSessions() {
  const state = await callApi('GET', '/api/state')
  return (state.sessions || []).map((s) => ({
    id: s.id,
    title: s.title,
    project: s.project,
    status: s.status,
  }))
}

async function handleCreateChannel(args) {
  const { name, mode, description } = args
  const r = await callApi('POST', '/api/channels', {
    name,
    ...(mode ? { mode } : {}),
    ...(description ? { description } : {}),
  })
  return r.channel || r
}

async function handleAddMember(args) {
  const { channel, alias, sessionId } = args
  // Resolve sessionId prefix if needed (orientation push needs the full sid
  // to reach the right inbox).
  const state = await callApi('GET', '/api/state')
  const fullSid = resolveSession(state, sessionId).id
  const r = await callApi(
    'POST',
    `/api/channels/${encodeURIComponent(channel)}/members`,
    { alias, sessionId: fullSid },
  )
  return r.channel || r
}

async function handleLeaveChannel(args) {
  const { channel, alias } = args
  const r = await callApi(
    'DELETE',
    `/api/channels/${encodeURIComponent(channel)}/members/${encodeURIComponent(alias)}`,
  )
  return r.channel || r
}

async function handleReadInbox(args) {
  const { sessionId } = args
  const state = await callApi('GET', '/api/state')
  const sess = resolveSession(state, sessionId)
  const consume = args.consume ?? isCurrentCodexSession(sess)
  const mySessionIds = new Set(sessionIdCandidates(sess))

  const out = []
  const inbox = await callApi(
    'GET',
    `/api/sessions/${encodeURIComponent(sess.id)}/inbox?drain=${
      consume ? 'true' : 'false'
    }`,
  )
  for (const msg of inbox.messages || []) {
    out.push({ channel: msg.channel, source: 'inbox', consumed: consume, message: msg })
  }

  for (const ch of state.channels || []) {
    const myAliases = ch.members
      .filter((m) => mySessionIds.has(m.sessionId))
      .map((m) => m.alias)
    if (myAliases.length === 0) continue
    const q = 'status=pending,held&limit=20'
    const r = await callApi(
      'GET',
      `/api/channels/${encodeURIComponent(ch.name)}/messages?${q}`,
    )
    for (const msg of r.messages || []) {
      if (msg.fromAlias && myAliases.includes(msg.fromAlias)) continue // my own
      if (msg.toAlias === '*' || myAliases.includes(msg.toAlias)) {
        out.push({ channel: ch.name, source: 'channel-pending', message: msg })
      }
    }
  }
  return out
}

// ─── server plumbing ──────────────────────────────────────────────────────

// `instructions` 是 MCP 协议在 InitializeResult 里返回的 system-level hint
// (spec 2024-11-05+)。Claude Code 把它合进 system prompt context，让 agent
// 知道这套工具的存在意义和何时该主动用。没这段提示的话，Claude 默认是
// 反应式的——只在用户明确问"帮我看一下 channel"才用工具，永远不会主动
// 检查自己的 inbox 或回应别的 agent。
const INSTRUCTIONS = [
  'You are a member of a meee2 multi-agent runtime. Other Claude/Codex sessions',
  '(and the operator / human user) can send you messages over named',
  'channels via the seven tools below.',
  '',
  'READ / OBSERVE:',
  '  - read_inbox     — pending messages addressed to you',
  '  - list_channels  — all channels + members + your alias in each',
  '  - list_sessions  — all live Claude sessions',
  '',
  'SEND:',
  '  - send_message   — message a teammate (or "*" broadcast) on a channel',
  '',
  'BUILD COLLABORATION (constructive only — by design there is NO',
  'delete_channel and NO remove_member; channel cleanup and kicking are',
  'human-only operations):',
  '  - create_channel — open a fresh coordination space',
  '  - add_member     — pull a session in (they get a system orientation msg)',
  '  - leave_channel  — voluntarily exit (only your own alias)',
  '',
  'Behavior expectations:',
  '  - At the start of any new turn, briefly call read_inbox with no sessionId',
  '    to see if you have unconsumed messages. If yes, prioritize processing',
  '    them before continuing your previous task — incoming agent/operator',
  '    messages are the highest-priority signal you can get.',
  '  - When asked to coordinate with another agent or "send to <alias>", use',
  '    send_message rather than asking the user to do it manually.',
  '  - When you finish a unit of work that another agent might be waiting on,',
  '    proactively send a status message on the relevant channel.',
  '  - If the user references "the other session" / "that session" / a',
  '    project name, use list_sessions to disambiguate before guessing.',
  '  - When you spin up a new collaboration (e.g. "let me get session X to',
  '    review this"), prefer create_channel + add_member over hand-waving',
  '    "please tell session X". Adding a session triggers an orientation',
  '    message so they immediately know about the channel + you.',
  '  - When a collaboration ends or you no longer need to be in a channel,',
  '    leave_channel keeps the noise down for everyone else.',
  '',
  'Do not announce that you are about to use these tools — just use them.',
  'Do not ask the user "what do you want me to do" before calling the tools',
  'unless the request is genuinely ambiguous.',
].join('\n')

const server = new Server(
  { name: 'meee2', version: '0.1.0' },
  {
    capabilities: { tools: {} },
    instructions: INSTRUCTIONS,
  },
)

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: TOOLS,
}))

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const { name, arguments: args = {} } = req.params
  try {
    let result
    switch (name) {
      case 'send_message':
        result = await handleSendMessage(args)
        break
      case 'list_channels':
        result = await handleListChannels()
        break
      case 'list_sessions':
        result = await handleListSessions()
        break
      case 'read_inbox':
        result = await handleReadInbox(args)
        break
      case 'create_channel':
        result = await handleCreateChannel(args)
        break
      case 'add_member':
        result = await handleAddMember(args)
        break
      case 'leave_channel':
        result = await handleLeaveChannel(args)
        break
      default:
        throw new Error(`unknown tool: ${name}`)
    }
    return {
      content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
    }
  } catch (e) {
    return {
      content: [
        { type: 'text', text: `Error: ${e instanceof Error ? e.message : e}` },
      ],
      isError: true,
    }
  }
})

const transport = new StdioServerTransport()
await server.connect(transport)
