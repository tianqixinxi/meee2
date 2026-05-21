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
import readline from 'node:readline'

const DEFAULT_PORT = 9876
const MAX_PORT = 9976
let cachedAPI = null

// ─── tool schemas ─────────────────────────────────────────────────────────
// Descriptions are the first thing the model sees when deciding whether to
// call; be specific about when to use, what fromAlias means, and how
// broadcast works.
const TOOLS = [
  {
    name: 'list_sessions',
    description:
      'List every agent session meee2 currently tracks — id, title, ' +
      'project cwd, status. Useful to disambiguate a referenced native ' +
      'Claude/Codex session.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'read_inbox',
    description:
      'Read pending direct messages addressed to a given session. If ' +
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
    name: 'read_node_contract',
    description:
      'Read the execution contract for a meee2 planner node. Use this first ' +
      'when you are spawned to execute a planner step. It returns inputs, ' +
      'outputs, allowed route targets, artifact kinds, payload types, and the ' +
      'inline payload size limit. If omitted, cwd is not needed; canvasId and ' +
      'nodeId should come from the task prompt.',
    inputSchema: {
      type: 'object',
      properties: {
        canvasId: { type: 'string', description: 'Planner canvas id.' },
        nodeId: { type: 'string', description: 'Planner step node id.' },
      },
      required: ['canvasId', 'nodeId'],
    },
  },
  {
    name: 'submit_node_output',
    description:
      'Submit structured output for your assigned meee2 planner node. Use this ' +
      'when the node is complete, blocked, or needs owner review. Small payloads ' +
      'may be inline. Large text/html/json/file content should be written to a ' +
      'file inside your cwd/canvas workspace and referenced as payload.file.path; ' +
      'meee2 will copy it into its artifact blob store.',
    inputSchema: {
      type: 'object',
      properties: {
        canvasId: { type: 'string', description: 'Planner canvas id.' },
        nodeId: { type: 'string', description: 'Planner step node id.' },
        status: { type: 'string', enum: ['done', 'blocked', 'needs_review'] },
        message: {
          type: 'object',
          properties: {
            summary: { type: 'string' },
            routeTo: { type: 'array', items: { type: 'string' } },
          },
        },
        artifacts: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              kind: { type: 'string' },
              title: { type: 'string' },
              reference: { type: 'string' },
              payload: { type: 'object' },
              routeTo: { type: 'array', items: { type: 'string' } },
            },
          },
        },
        next: { type: 'string', enum: ['complete', 'blocked', 'needs_owner_review'] },
      },
      required: ['canvasId', 'nodeId', 'status', 'next'],
    },
  },
  {
    name: 'attach_artifact_to_node',
    description:
      'Attach an artifact to your meee2 planner node as evidence without ' +
      'marking the node complete. Use submit_node_output for final results.',
    inputSchema: {
      type: 'object',
      properties: {
        canvasId: { type: 'string', description: 'Planner canvas id.' },
        nodeId: { type: 'string', description: 'Planner step node id.' },
        kind: { type: 'string' },
        title: { type: 'string' },
        reference: { type: 'string' },
        status: { type: 'string' },
        payload: { type: 'object' },
      },
      required: ['canvasId', 'nodeId', 'reference'],
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

async function assertPlannerToolScope(canvasId, nodeId) {
  const candidates = envSessionCandidates()
  if (candidates.length === 0) return
  const graph = await callApi(
    'GET',
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/graph`,
  )
  const node = (graph.nodes || []).find((n) => n.id === nodeId)
  if (!node) throw new Error(`planner node not found: ${nodeId}`)
  const boundSessionId = node.sessionId
  if (!boundSessionId) return
  const allowed = candidates.some((candidate) =>
    boundSessionId === candidate || boundSessionId.endsWith(candidate) || candidate.endsWith(boundSessionId),
  )
  if (!allowed) {
    throw new Error('planner MCP tools can only mutate the node bound to the current session')
  }
}

// ─── tool handlers ────────────────────────────────────────────────────────

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
  const sess = resolveSession(state, sessionId)
  const consume = args.consume ?? isCurrentCodexSession(sess)

  const out = []
  const inbox = await callApi(
    'GET',
    `/api/sessions/${encodeURIComponent(sess.id)}/inbox?drain=${
      consume ? 'true' : 'false'
    }`,
  )
  for (const msg of inbox.messages || []) {
    out.push({ source: 'inbox', consumed: consume, message: msg })
  }
  return out
}

async function handleReadNodeContract(args) {
  const { canvasId, nodeId } = args
  if (!canvasId || !nodeId) throw new Error('canvasId and nodeId are required')
  await assertPlannerToolScope(canvasId, nodeId)
  return await callApi(
    'GET',
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/nodes/${encodeURIComponent(nodeId)}/contract`,
  )
}

function withFileCwd(payload) {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return payload
  const file = payload.file
  if (!file || typeof file !== 'object' || Array.isArray(file) || file.cwd) return payload
  return { ...payload, file: { ...file, cwd: process.cwd() } }
}

async function handleSubmitNodeOutput(args) {
  const { canvasId, nodeId } = args
  if (!canvasId || !nodeId) throw new Error('canvasId and nodeId are required')
  await assertPlannerToolScope(canvasId, nodeId)
  const artifacts = (args.artifacts || []).map((artifact) => ({
    ...artifact,
    routeTo: artifact.routeTo || [],
    payload: withFileCwd(artifact.payload),
  }))
  return await callApi(
    'POST',
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/nodes/${encodeURIComponent(nodeId)}/output`,
    {
      nodeId,
      status: args.status,
      message: args.message || null,
      artifacts,
      next: args.next,
    },
  )
}

async function handleAttachArtifactToNode(args) {
  const { canvasId, nodeId } = args
  if (!canvasId || !nodeId) throw new Error('canvasId and nodeId are required')
  await assertPlannerToolScope(canvasId, nodeId)
  return await callApi(
    'POST',
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/nodes/${encodeURIComponent(nodeId)}/artifacts`,
    {
      kind: args.kind,
      title: args.title,
      reference: args.reference,
      status: args.status,
      payload: withFileCwd(args.payload),
    },
  )
}

// ─── server plumbing ──────────────────────────────────────────────────────

// `instructions` 是 MCP 协议在 InitializeResult 里返回的 system-level hint
// (spec 2024-11-05+)。Claude Code 把它合进 system prompt context，让 agent
// 知道这套工具的存在意义和何时该主动用。没这段提示的话，Claude 默认是
// 反应式的——只在用户明确问时才用工具，未必会先读取 planner contract 或
// 把产物结构化回传。
const INSTRUCTIONS = [
  'Meee2 Runtime is the source of truth for planner nodes and artifacts.',
  'If the Meee2 Skill is available, follow it. These MCP tools are the writeback',
  'interface for reading node contracts and submitting structured canvas output.',
  '',
  'Core tools: read_node_contract, submit_node_output, attach_artifact_to_node,',
  'read_inbox, list_sessions.',
  'Planner rule: first read_node_contract; final state must be submitted through',
  'submit_node_output. Large text/html/json/file artifacts should be written to',
  'a workspace file and submitted as payload.file.path.',
].join('\n')

async function dispatchToolCall(name, args = {}) {
  try {
    let result
    switch (name) {
      case 'list_sessions':
        result = await handleListSessions()
        break
      case 'read_inbox':
        result = await handleReadInbox(args)
        break
      case 'read_node_contract':
        result = await handleReadNodeContract(args)
        break
      case 'submit_node_output':
        result = await handleSubmitNodeOutput(args)
        break
      case 'attach_artifact_to_node':
        result = await handleAttachArtifactToNode(args)
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
}

function writeMessage(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`)
}

function success(id, result) {
  writeMessage({ jsonrpc: '2.0', id, result })
}

function failure(id, code, message) {
  writeMessage({ jsonrpc: '2.0', id, error: { code, message } })
}

async function handleRequest(req) {
  if (!req || typeof req !== 'object') return
  const { id, method, params = {} } = req
  if (!method) return
  try {
    switch (method) {
      case 'initialize':
        success(id, {
          protocolVersion: params.protocolVersion || '2024-11-05',
          capabilities: { tools: {} },
          serverInfo: { name: 'meee2', version: '0.1.0' },
          instructions: INSTRUCTIONS,
        })
        break
      case 'notifications/initialized':
      case 'notifications/cancelled':
        break
      case 'tools/list':
        success(id, { tools: TOOLS })
        break
      case 'tools/call':
        success(id, await dispatchToolCall(params.name, params.arguments || {}))
        break
      default:
        if (id !== undefined) failure(id, -32601, `Method not found: ${method}`)
    }
  } catch (e) {
    if (id !== undefined) {
      failure(id, -32603, e instanceof Error ? e.message : String(e))
    }
  }
}

const rl = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
})

rl.on('line', (line) => {
  const trimmed = line.trim()
  if (!trimmed) return
  try {
    void handleRequest(JSON.parse(trimmed))
  } catch (e) {
    failure(null, -32700, e instanceof Error ? e.message : String(e))
  }
})
