#!/usr/bin/env node
// PreToolUse hook (matcher: Workflow)
//
// 拦截 Claude Code 原生 Workflow 工具调用，把 orchestration 脚本复制到
// ~/.meee2/workflow-bridge/runs/<runId>/，再通过 meee2 BoardServer 的
// POST /api/sessions/spawn 拉起一个 relay 会话去执行，最后 deny 本地执行。
// relay 会话执行完会把结果写回 runDir/result.md 并 inject 通知来源会话。
//
// 防循环三重保险：
//   1. relay 会话以 MEEE2_WORKFLOW_RELAY=1 启动 → 放行
//   2. scriptPath 落在 bridge 目录下 → 放行（relay 按 instructions 用 scriptPath 形式）
//   3. meee2 planner 派发的会话（MEEE2_ASSISTANT_SESSION）→ 放行
//
// 关闭方式：export MEEE2_WORKFLOW_BRIDGE=off，或 touch ~/.meee2/workflow-bridge/disabled

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import crypto from 'node:crypto'

const HOME = os.homedir()
const BRIDGE_ROOT = path.join(HOME, '.meee2', 'workflow-bridge')
const LOG_FILE = path.join(BRIDGE_ROOT, 'bridge.log')

function log(msg) {
  try {
    fs.mkdirSync(BRIDGE_ROOT, { recursive: true })
    fs.appendFileSync(LOG_FILE, `${new Date().toISOString()} ${msg}\n`)
  } catch {
    // logging 失败不影响主流程
  }
}

// 放行 = 静默退出，走 Claude Code 正常 permission 流程，Workflow 本地执行
function allow(reason) {
  if (reason) log(`allow: ${reason}`)
  process.exit(0)
}

function expandHome(p) {
  return p.startsWith('~') ? path.join(HOME, p.slice(1)) : p
}

function shellQuote(value) {
  return `'${String(value).replaceAll("'", `'"'"'`)}'`
}

const RUNTIME_FILE = path.join(HOME, 'Library/Application Support/meee2/board-server.json')

// BoardServer 对所有 mutating /api/* 请求要求 X-Meee2-Control-Token（同用户
// 0600 运行时文件里下发）。base 和 token 必须一起读：token 每次 meee2 重启
// 轮换，缓存旧值必 401。
function apiRuntime() {
  if (process.env.MEEE2_API_URL) {
    return {
      base: process.env.MEEE2_API_URL.replace(/\/+$/, ''),
      token: process.env.MEEE2_CONTROL_TOKEN || null,
    }
  }
  try {
    const cfg = JSON.parse(fs.readFileSync(RUNTIME_FILE, 'utf8'))
    const token = typeof cfg.controlToken === 'string' && cfg.controlToken ? cfg.controlToken : null
    if (typeof cfg.url === 'string' && cfg.url) return { base: cfg.url.replace(/\/+$/, ''), token }
    if (cfg.port) return { base: `http://127.0.0.1:${cfg.port}`, token }
  } catch {
    // board-server.json 不存在/损坏 → 用默认端口（token 缺失时请求会被新版
    // meee2 拒掉，走 fail-open；旧版 meee2 无 token 门，照常工作）
  }
  return { base: 'http://127.0.0.1:9876', token: null }
}

function controlHeaders(token) {
  const headers = { 'Content-Type': 'application/json' }
  if (token) headers['X-Meee2-Control-Token'] = token
  return headers
}

function decodeStaticString(quote, raw) {
  if (quote === '"') {
    try { return JSON.parse(`"${raw}"`) } catch { return null }
  }
  // Metadata accepts JS single-quoted/template strings, but interpolation and
  // expressions are deliberately not evaluated in this hook process.
  if (quote === '`' && raw.includes('${')) return null
  return raw.replace(/\\(['"`\\nrt])/g, (_, ch) => ({ n: '\n', r: '\r', t: '\t' }[ch] ?? ch))
}

function staticStringProperty(source, key) {
  const escaped = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const match = new RegExp('(?:^|[,\\s])' + escaped + '\\s*:\\s*(["\'`])((?:\\\\.|(?!\\1)[\\s\\S])*)\\1').exec(source)
  return match ? decodeStaticString(match[1], match[2]) : null
}

function balancedObjects(source) {
  const objects = []
  let start = -1
  let depth = 0
  let quote = null
  for (let i = 0; i < source.length; i++) {
    const ch = source[i]
    if (quote) {
      if (ch === '\\') { i++; continue }
      if (ch === quote) quote = null
      continue
    }
    if (ch === '"' || ch === "'" || ch === '`') { quote = ch; continue }
    if (ch === '{') { if (depth === 0) start = i; depth++ }
    if (ch === '}' && depth > 0 && --depth === 0) objects.push(source.slice(start, i + 1))
  }
  return objects
}

// Statically read only string literals from `export const meta`. Never import,
// eval, or execute workflow text in the interception hook.
function parseWorkflowMeta(script) {
  try {
    const anchor = script.indexOf('export const meta')
    if (anchor < 0) return null
    const braceStart = script.indexOf('{', anchor)
    if (braceStart < 0) return null
    let depth = 0
    let end = -1
    let inString = null
    for (let i = braceStart; i < script.length; i++) {
      const ch = script[i]
      if (inString) {
        if (ch === '\\') { i++; continue }
        if (ch === inString) inString = null
        continue
      }
      if (ch === '"' || ch === "'" || ch === '`') { inString = ch; continue }
      if (ch === '{') depth++
      if (ch === '}') {
        depth--
        if (depth === 0) { end = i; break }
      }
    }
    if (end < 0) return null
    const literal = script.slice(braceStart, end + 1)
    const phasesAnchor = literal.search(/\bphases\s*:/)
    const phaseObjects = phasesAnchor >= 0 ? balancedObjects(literal.slice(phasesAnchor)) : []
    const phases = phaseObjects.slice(0, 20).map((phase) => ({
      title: staticStringProperty(phase, 'title')?.trim().slice(0, 120) || null,
      detail: staticStringProperty(phase, 'detail')?.slice(0, 500) || null,
    })).filter((phase) => phase.title)
    return {
      name: staticStringProperty(literal, 'name')?.slice(0, 120) || null,
      description: staticStringProperty(literal, 'description')?.slice(0, 500) || null,
      phases,
    }
  } catch {
    return null
  }
}

// 顺手 GC：只删除 runs/ 下超过 7 天且 status.json 明确标记为 done/failed
// 的目录；缺失或损坏的状态不能证明执行结束，必须保留供恢复/诊断。
function gcOldRuns() {
  try {
    const runsRoot = path.join(BRIDGE_ROOT, 'runs')
    const cutoff = Date.now() - 7 * 24 * 3600 * 1000
    for (const name of fs.readdirSync(runsRoot)) {
      const dir = path.join(runsRoot, name)
      try {
        const stat = fs.statSync(dir)
        if (!stat.isDirectory() || stat.mtimeMs > cutoff) continue
        let terminal = false
        try {
          const status = JSON.parse(fs.readFileSync(path.join(dir, 'status.json'), 'utf8'))
          terminal = status.state === 'done' || status.state === 'failed'
        } catch {
          // Missing/corrupt status is not proof of completion. Preserve it so
          // GC can never delete a long-running or diagnostically useful run.
        }
        if (terminal) fs.rmSync(dir, { recursive: true, force: true })
      } catch {
        // 单个目录失败跳过
      }
    }
  } catch {
    // runs/ 不存在等 → 忽略
  }
}

async function main() {
  let raw = ''
  for await (const chunk of process.stdin) raw += chunk
  let input
  try {
    input = JSON.parse(raw)
  } catch {
    allow('stdin not valid JSON')
  }

  if (input.tool_name !== 'Workflow') allow(`tool ${input.tool_name} is not Workflow`)

  // ---- 放行 guards ----
  const env = process.env
  if ((env.MEEE2_WORKFLOW_BRIDGE || '').toLowerCase() === 'off') allow('MEEE2_WORKFLOW_BRIDGE=off')
  if (fs.existsSync(path.join(BRIDGE_ROOT, 'disabled'))) allow('disabled marker file present')
  if (env.MEEE2_WORKFLOW_RELAY === '1') allow('relay session (MEEE2_WORKFLOW_RELAY)')
  if (env.MEEE2_ASSISTANT_SESSION) allow('meee2 planner-dispatched session')

  const toolInput = input.tool_input || {}
  const cwd = input.cwd || process.cwd()

  // resume 依赖同会话的 run journal，搬不动 → 本地执行
  if (toolInput.resumeFromRunId) allow('resumeFromRunId cannot be relayed')

  if (typeof toolInput.scriptPath === 'string' && toolInput.scriptPath) {
    const resolved = path.resolve(cwd, expandHome(toolInput.scriptPath))
    if (resolved === BRIDGE_ROOT || resolved.startsWith(BRIDGE_ROOT + path.sep)) {
      allow('scriptPath inside bridge dir (relay execution)')
    }
  }

  // ---- 物化 workflow 脚本 ----
  let script = null
  if (typeof toolInput.script === 'string' && toolInput.script.trim()) {
    script = toolInput.script
  } else if (typeof toolInput.scriptPath === 'string' && toolInput.scriptPath) {
    try {
      script = fs.readFileSync(path.resolve(cwd, expandHome(toolInput.scriptPath)), 'utf8')
    } catch (e) {
      log(`cannot read scriptPath ${toolInput.scriptPath}: ${e.message}`)
    }
  }
  const namedWorkflow = !script && typeof toolInput.name === 'string' && toolInput.name.trim()
    ? toolInput.name.trim()
    : null
  if (!script && !namedWorkflow) allow('nothing relayable in tool_input')

  gcOldRuns()

  const stamp = new Date().toISOString().replace(/[:.]/g, '-').toLowerCase()
  const runId = `wfbridge-${stamp}-${crypto.randomBytes(3).toString('hex')}`
  const runDir = path.join(BRIDGE_ROOT, 'runs', runId)
  fs.mkdirSync(runDir, { recursive: true })

  const hasArgs = toolInput.args !== undefined
  if (hasArgs) fs.writeFileSync(path.join(runDir, 'args.json'), JSON.stringify(toolInput.args, null, 2))

  // args 不能依赖 relay 会话在工具调用里原样传 JSON 值（实测会被降级成字符串）。
  // 有 args 时生成 wrapper：用脚本内 workflow({scriptPath}, args) 把 args 以真实
  // JS 值注入 payload，relay 只需零参数调 wrapper。payload 自己调 workflow() 时
  // 不能再嵌套（runtime 限一层），这种情况退回 relay 传 args。
  const scriptFile = script ? path.join(runDir, 'workflow.mjs') : null
  let argsBakedIn = false
  if (script) {
    const usesNestedWorkflow = /\bworkflow\s*\(/.test(script)
    if (hasArgs && !usesNestedWorkflow) {
      const payloadFile = path.join(runDir, 'payload.mjs')
      fs.writeFileSync(payloadFile, script)
      fs.writeFileSync(scriptFile, `export const meta = {
  name: 'wfbridge-args-wrapper',
  description: 'meee2-workflow-bridge wrapper: inject relayed args into the payload workflow as a real JSON value',
}
// args 由 bridge 拦截时固化，绕过 relay 工具调用边界的字符串化
return await workflow({ scriptPath: ${JSON.stringify(payloadFile)} }, ${JSON.stringify(toolInput.args)})
`)
      argsBakedIn = true
    } else {
      fs.writeFileSync(scriptFile, script)
    }
  }

  const { base, token } = apiRuntime()
  const originSessionId = input.session_id || ''

  fs.writeFileSync(path.join(runDir, 'meta.json'), JSON.stringify({
    runId,
    originSessionId,
    cwd,
    workflowName: toolInput.name ?? null,
    relayedAt: new Date().toISOString(),
    apiBase: base,
  }, null, 2))

  const relayPassesArgs = hasArgs && !argsBakedIn
  const workflowParams = JSON.stringify(
    script
      ? { scriptPath: scriptFile, ...(relayPassesArgs ? { args: toolInput.args } : {}) }
      : { name: namedWorkflow, ...(relayPassesArgs ? { args: toolInput.args } : {}) },
    null, 2)

  const instructions = `# meee2-workflow-bridge 转交的 Workflow 执行任务

你是 meee2 拉起的 relay 会话，负责执行一个从其他 Claude Code 会话拦截下来的 Workflow。

- run id: ${runId}
- 来源会话: ${originSessionId}（cwd: ${cwd}）
- 运行目录: ${runDir}

## 步骤（严格执行，不要做任何无关工作）

1. 调用 Workflow 工具，工具参数必须逐字使用以下 JSON（args 如存在必须保持为 JSON 值原样传入，绝对不能字符串化成 "args": "{...}"）：

\`\`\`json
${workflowParams}
\`\`\`

   - 必须用上面的 ${script ? 'scriptPath' : 'name'} 形式，禁止把脚本内容以 "script" 参数内联传入（内联会被 bridge 再次拦截，造成死循环）。
2. 等待 workflow 完成。如果脚本本身报语法/逻辑错误，可以直接编辑 ${argsBakedIn ? path.join(runDir, 'payload.mjs') + '（业务脚本；workflow.mjs 是 args 注入 wrapper，别动）' : (scriptFile ?? '（named workflow，不可编辑）')} 修复后用同一 scriptPath 重新调用。
3. 把执行结果写成 markdown 总结到 ${path.join(runDir, 'result.md')}（包含 workflow 返回值、关键发现、如失败则失败原因）。
4. 通知来源会话（尽力而为，失败直接忽略）。meee2 的写接口需要当前 control token（存在 ${RUNTIME_FILE}，每次 meee2 重启会轮换，所以要现读）。用 Bash 执行：
   TOKEN=$(node -pe 'JSON.parse(require("fs").readFileSync(${JSON.stringify(RUNTIME_FILE)},"utf8")).controlToken' 2>/dev/null)
   curl -s -X POST '${base}/api/sessions/${originSessionId}/inject' -H 'Content-Type: application/json' -H "X-Meee2-Control-Token: $TOKEN" --data '{"content":"[meee2-workflow-bridge] workflow run ${runId} 已执行完成，结果在 ${path.join(runDir, 'result.md')}，请读取后继续之前的工作。"}'
5. 结束会话，不要开始其他工作。
`
  const instructionsFile = path.join(runDir, 'instructions.md')
  fs.writeFileSync(instructionsFile, instructions)

  // ---- 让 meee2 接管 relay 会话 ----
  // env 前缀让 relay 会话里的本 hook 直接放行；instructions 里再用 scriptPath 形式兜底。
  const command = `MEEE2_WORKFLOW_RELAY=1 claude --dangerously-skip-permissions ${shellQuote(`读取文件 ${instructionsFile} 并严格按其中步骤执行。`)}`

  // 首选（meee2 ≥ 带 workflow-bridge 消费端）：注册 run —— meee2 建 canvas
  // 可视化骨架、spawn relay、tail journal、维护 runDir/status.json。
  let registered = null
  try {
    const resp = await fetch(`${base}/api/workflow-bridge/runs`, {
      method: 'POST',
      headers: controlHeaders(token),
      body: JSON.stringify({
        runId,
        runDir,
        originSessionId,
        cwd,
        command,
        workflowName: namedWorkflow,
        meta: script ? parseWorkflowMeta(script) : null,
      }),
      signal: AbortSignal.timeout(15_000),
    })
    if (resp.ok) {
      registered = await resp.json()
    } else {
      log(`run ${runId}: register returned HTTP ${resp.status} — falling back to bare spawn`)
    }
  } catch (e) {
    log(`run ${runId}: register failed (${e.message}) — falling back to bare spawn`)
  }

  let spawned
  if (registered) {
    spawned = registered
    // canvas 归属 merge 回 meta.json（排查/溯源用）
    try {
      const metaPath = path.join(runDir, 'meta.json')
      const cur = JSON.parse(fs.readFileSync(metaPath, 'utf8'))
      fs.writeFileSync(metaPath, JSON.stringify({
        ...cur,
        canvasId: registered.canvasId,
        canvasName: registered.canvasName,
        statusPath: registered.statusPath,
      }, null, 2))
    } catch {
      // 非致命
    }
    log(`run ${runId}: registered — canvas ${registered.canvasId} relay ${registered.sessionId} (origin ${originSessionId.slice(0, 8)})`)
  } else {
    // 降级（旧 meee2：无注册端点）：0.1.x 行为原样 —— 裸 spawn relay 会话。
    try {
      const resp = await fetch(`${base}/api/sessions/spawn`, {
        method: 'POST',
        headers: controlHeaders(token),
        body: JSON.stringify({ cwd, command }),
        signal: AbortSignal.timeout(10_000),
      })
      if (!resp.ok) throw new Error(`HTTP ${resp.status}: ${(await resp.text()).slice(0, 200)}`)
      spawned = await resp.json()
    } catch (e) {
      log(`run ${runId}: meee2 spawn failed (${e.message}) — falling back to local execution`)
      // meee2 不可达/出错 → 不拦截，workflow 照常本地执行
      allow(`meee2 unreachable: ${e.message}`)
    }
    log(`run ${runId}: relayed to meee2 session ${spawned.sessionId} (origin ${originSessionId.slice(0, 8)})`)
  }

  const canvasHint = registered
    ? `meee2 已创建 canvas「${registered.canvasName}」实时可视化本次执行（meee2 Board 已自动打开，phase/agent 会随执行逐个出现）。` +
      `你可以随时用 Read 工具查看 ${registered.statusPath} 获取结构化进度` +
      `（state/agentsTotal/agentsDone/lastEvent；state 变为 done/failed 即终态）。`
    : `可在 meee2 board 中查看 relay 会话进度。`

  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason:
        `[meee2-workflow-bridge] 这次 Workflow 调用已被拦截并复制到 meee2 执行：` +
        `relay 会话 ${spawned.sessionId}，run id ${runId}，脚本已落盘 ${scriptFile ?? `(named workflow: ${namedWorkflow})`}。` +
        `不要在本地重试或改写后重试这次 Workflow 调用。直接告诉用户：workflow 已转交 meee2 执行。` +
        canvasHint +
        `执行结果会写到 ${path.join(runDir, 'result.md')}，完成时本会话会收到 inject 通知。` +
        `然后继续做不依赖该 workflow 结果的其他工作，或结束本轮等待通知。`,
    },
  }))
  process.exit(0)
}

main().catch((e) => {
  // 任何未预期错误都 fail-open：宁可 workflow 本地跑，也不能把用户的 Workflow 工具搞坏
  log(`unexpected error: ${e.stack || e.message}`)
  process.exit(0)
})
