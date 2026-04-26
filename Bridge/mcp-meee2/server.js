#!/usr/bin/env node
// meee2 MCP server — exposes A2A messaging to any Claude Code session as
// native tools. Transport is stdio (Claude CLI spawns us as a subprocess and
// speaks JSON-RPC over stdin/stdout).
//
// All tools are thin HTTP shims over the local BoardServer (127.0.0.1:9876
// by default; override with MEEE2_API_URL). If the BoardServer isn't
// running — meee2 app not launched — every tool returns an instructive
// error instead of crashing the MCP runtime.

import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js'

const API = process.env.MEEE2_API_URL || 'http://localhost:9876'

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
      'List every Claude session meee2 currently tracks — id, title, ' +
      'project cwd, status. Useful to find a target session before asking ' +
      'to add it to a channel.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'read_inbox',
    description:
      'Read pending A2A messages addressed to a given session (i.e. the ' +
      'union of channel-pending messages where the session is a member ' +
      'and the sender is someone else). Does NOT drain the inbox — the ' +
      'Claude CLI Stop hook still owns drainage.',
    inputSchema: {
      type: 'object',
      properties: {
        sessionId: {
          type: 'string',
          description:
            'Full session id, or a prefix meee2 can resolve uniquely.',
        },
      },
      required: ['sessionId'],
    },
  },
]

// ─── HTTP shim ────────────────────────────────────────────────────────────

async function callApi(method, path, body) {
  let res
  try {
    res = await fetch(`${API}${path}`, {
      method,
      headers: { 'content-type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined,
    })
  } catch (e) {
    throw new Error(
      `meee2 BoardServer unreachable at ${API} — is the meee2 app running? ` +
        `(${e.message || e})`,
    )
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

async function handleReadInbox(args) {
  const { sessionId } = args
  const state = await callApi('GET', '/api/state')
  const sess =
    state.sessions.find((s) => s.id === sessionId) ||
    state.sessions.find((s) => s.id.startsWith(sessionId))
  if (!sess) throw new Error(`session not found: ${sessionId}`)

  const out = []
  for (const ch of state.channels || []) {
    const myAliases = ch.members
      .filter((m) => m.sessionId === sess.id)
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
        out.push({ channel: ch.name, message: msg })
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
  'You are a member of a meee2 multi-agent runtime. Other Claude sessions',
  '(and the operator / human user) can send you messages over named',
  'channels via the four tools below: read_inbox, list_channels,',
  'list_sessions, send_message.',
  '',
  'Behavior expectations:',
  '  - At the start of any new turn, briefly call read_inbox to see if you',
  '    have unconsumed messages. If yes, prioritize processing them before',
  '    continuing your previous task — incoming agent/operator messages are',
  '    the highest-priority signal you can get.',
  '  - When asked to coordinate with another agent or "send to <alias>", use',
  '    send_message rather than asking the user to do it manually.',
  '  - When you finish a unit of work that another agent might be waiting on,',
  '    proactively send a status message on the relevant channel.',
  '  - If the user references "the other session" / "that session" / a',
  '    project name, use list_sessions to disambiguate before guessing.',
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
