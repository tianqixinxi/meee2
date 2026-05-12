#!/usr/bin/env node
// meee2 MCP server — exposes read-only local session discovery to Claude/Codex
// sessions as native tools. Transport is stdio.
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
const TOOLS = [
  {
    name: 'list_sessions',
    description:
      'List every agent session meee2 currently tracks — id, title, ' +
      'project cwd, status. Useful to find a target session before asking ' +
      'the user to jump back to the real terminal or editor.',
    inputSchema: { type: 'object', properties: {} },
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

const INSTRUCTIONS = [
  'meee2 exposes local AI coding session visibility.',
  'Available tool:',
  '  - list_sessions — all live local Claude/Codex/etc. sessions tracked by meee2.',
  '',
  'Behavior expectations:',
  '  - If the user references "the other session" / "that session" / a',
  '    project name, use list_sessions to disambiguate before guessing.',
  '  - Channel/inbox messaging is disabled. Do not try to send messages',
  '    between sessions; ask the user to jump back to the real terminal/editor.',
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
      case 'list_sessions':
        result = await handleListSessions()
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
