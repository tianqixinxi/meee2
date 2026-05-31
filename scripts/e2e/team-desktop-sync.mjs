#!/usr/bin/env node
import { spawn } from 'node:child_process'
import { createServer } from 'node:net'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { tmpdir } from 'node:os'
import { setTimeout as delay } from 'node:timers/promises'

const repoRoot = resolve(import.meta.dirname, '../..')
const workspaceRoot = resolve(repoRoot, '..')
const onlineDir = process.env.MEEE2_ONLINE_DIR || join(workspaceRoot, 'meee2-online')
const keepData = process.env.MEEE2_E2E_KEEP_DATA === '1'

function assert(condition, message) {
  if (!condition) throw new Error(message)
}

function readDotEnv(filePath) {
  if (!existsSync(filePath)) return {}
  const values = {}
  for (const rawLine of readFileSync(filePath, 'utf8').split(/\r?\n/)) {
    const line = rawLine.trim()
    if (!line || line.startsWith('#')) continue
    const match = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(line)
    if (!match) continue
    let value = match[2].trim()
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1)
    }
    values[match[1]] = value
  }
  return values
}

function loadOnlineEnv() {
  const file = readDotEnv(join(onlineDir, '.env.local'))
  for (const [key, value] of Object.entries(file)) {
    if (!process.env[key]) process.env[key] = value
  }
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY
  assert(supabaseUrl && anonKey && serviceRoleKey, 'Missing Supabase env in meee2-online/.env.local')
  return { supabaseUrl, anonKey, serviceRoleKey }
}

async function getFreePort() {
  return new Promise((resolvePort, reject) => {
    const server = createServer()
    server.on('error', reject)
    server.listen(0, '127.0.0.1', () => {
      const address = server.address()
      assert(address && typeof address === 'object', 'Failed to allocate free port')
      const port = address.port
      server.close(() => resolvePort(port))
    })
  })
}

async function waitFor(predicate, label, timeoutMs = 45_000, intervalMs = 500) {
  const startedAt = Date.now()
  let lastError
  while (Date.now() - startedAt < timeoutMs) {
    try {
      const value = await predicate()
      if (value) return value
    } catch (error) {
      lastError = error
    }
    await delay(intervalMs)
  }
  throw new Error(`${label} timed out${lastError ? `: ${lastError.message}` : ''}`)
}

function trackedSpawn(command, args, options, name) {
  const child = spawn(command, args, {
    ...options,
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  const lines = []
  const push = (chunk) => {
    for (const line of chunk.toString('utf8').split(/\r?\n/)) {
      if (!line.trim()) continue
      lines.push(line)
      if (lines.length > 120) lines.shift()
    }
  }
  child.stdout.on('data', push)
  child.stderr.on('data', push)
  child.once('exit', (code, signal) => {
    if (code !== 0 && signal !== 'SIGTERM') {
      console.error(`[${name}] exited with code=${code} signal=${signal}`)
      console.error(lines.join('\n'))
    }
  })
  return {
    child,
    output: () => lines.join('\n'),
    stop: async () => {
      if (child.exitCode !== null || child.signalCode !== null) return
      child.kill('SIGTERM')
      await Promise.race([
        new Promise((resolveStop) => child.once('exit', resolveStop)),
        delay(3_000).then(() => child.kill('SIGKILL')),
      ])
    },
  }
}

async function jsonFetch(url, init = {}) {
  const headers = new Headers(init.headers)
  if (init.body && !headers.has('content-type')) headers.set('content-type', 'application/json')
  const res = await fetch(url, { ...init, headers })
  const text = await res.text()
  let body = null
  if (text) {
    try {
      body = JSON.parse(text)
    } catch {
      body = { raw: text }
    }
  }
  return { status: res.status, body }
}

function requireOk(response, label) {
  if (response.status < 200 || response.status >= 300) {
    throw new Error(`${label} failed: HTTP ${response.status} ${JSON.stringify(response.body)}`)
  }
  return response.body
}

async function supabaseFetch(env, path, init = {}, service = true) {
  const key = service ? env.serviceRoleKey : env.anonKey
  return jsonFetch(`${env.supabaseUrl}${path}`, {
    ...init,
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      ...(init.headers || {}),
    },
  })
}

async function createUser(env, runId, label) {
  const email = `${label}-${runId}@desktop-team-e2e.local`
  const password = `meee2-Desktop-${runId}-${label}!`
  const created = requireOk(
    await supabaseFetch(env, '/auth/v1/admin/users', {
      method: 'POST',
      body: JSON.stringify({
        email,
        password,
        email_confirm: true,
        user_metadata: { name: `${label} ${runId}` },
      }),
    }),
    `create ${label} user`,
  )
  const signedIn = requireOk(
    await supabaseFetch(env, '/auth/v1/token?grant_type=password', {
      method: 'POST',
      body: JSON.stringify({ email, password }),
    }, false),
    `sign in ${label} user`,
  )
  return {
    id: created.id,
    email,
    password,
    accessToken: signedIn.access_token,
    refreshToken: signedIn.refresh_token,
  }
}

async function seedWorld(env) {
  const runId = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`
  const teamId = crypto.randomUUID()
  const owner = await createUser(env, runId, 'owner')
  const member = await createUser(env, runId, 'member')
  requireOk(
    await supabaseFetch(env, '/rest/v1/meee2_teams', {
      method: 'POST',
      headers: { Prefer: 'return=representation' },
      body: JSON.stringify({ id: teamId, name: `Desktop Team E2E ${runId}` }),
    }),
    'create team',
  )
  requireOk(
    await supabaseFetch(env, '/rest/v1/meee2_members', {
      method: 'POST',
      body: JSON.stringify([
        { team_id: teamId, user_id: owner.id, role: 'owner' },
        { team_id: teamId, user_id: member.id, role: 'member' },
      ]),
    }),
    'create memberships',
  )
  requireOk(
    await supabaseFetch(env, '/rest/v1/meee2_billing', {
      method: 'POST',
      body: JSON.stringify({
        team_id: teamId,
        plan: 'pro',
        status: 'active',
        billing_interval: 'month',
        currency: 'usd',
        seat_count: 8,
        created_by: owner.id,
        updated_by: owner.id,
      }),
    }),
    'create pro billing',
  )
  return { runId, teamId, owner, member }
}

async function cleanupWorld(env, world) {
  if (keepData) {
    console.log(`Keeping E2E data: team=${world.teamId}`)
    return
  }
  await supabaseFetch(env, `/rest/v1/meee2_teams?id=eq.${world.teamId}`, { method: 'DELETE' }).catch(() => {})
  for (const user of [world.owner, world.member]) {
    await supabaseFetch(env, `/auth/v1/admin/users/${user.id}`, { method: 'DELETE' }).catch(() => {})
  }
}

async function startOnline(env) {
  const explicit = process.env.MEEE2_ONLINE_E2E_BASE_URL
  if (explicit) {
    return { baseUrl: explicit.replace(/\/$/, ''), stop: async () => {} }
  }
  const port = await getFreePort()
  const baseUrl = `http://127.0.0.1:${port}`
  const proc = trackedSpawn(
    'pnpm',
    ['exec', 'next', 'dev', '-H', '127.0.0.1', '-p', String(port)],
    {
      cwd: onlineDir,
      env: {
        ...process.env,
        NEXT_PUBLIC_SUPABASE_URL: env.supabaseUrl,
        NEXT_PUBLIC_SUPABASE_ANON_KEY: env.anonKey,
        SUPABASE_SERVICE_ROLE_KEY: env.serviceRoleKey,
      },
    },
    'meee2-online',
  )
  await Promise.race([
    waitFor(async () => {
      try {
        const res = await fetch(`${baseUrl}/api/v1/connect/refresh`, {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: '{}',
        })
        return res.status >= 200 && res.status < 500
      } catch {
        return false
      }
    }, 'meee2-online dev server', 120_000),
    new Promise((_, reject) => proc.child.once('exit', () => reject(new Error(proc.output())))),
  ])
  return { baseUrl, stop: proc.stop }
}

async function swiftBuild() {
  const build = trackedSpawn('swift', ['build'], { cwd: repoRoot, env: process.env }, 'swift-build')
  await new Promise((resolveBuild, reject) => {
    build.child.once('exit', (code) => {
      if (code === 0) resolveBuild()
      else reject(new Error(build.output()))
    })
  })
  const binPath = await new Promise((resolveBin, reject) => {
    const proc = trackedSpawn('swift', ['build', '--show-bin-path'], { cwd: repoRoot, env: process.env }, 'swift-bin-path')
    let out = ''
    proc.child.stdout.on('data', (chunk) => { out += chunk.toString('utf8') })
    proc.child.once('exit', (code) => {
      if (code === 0) resolveBin(out.trim())
      else reject(new Error(proc.output()))
    })
  })
  return join(binPath, 'meee2')
}

function writeProfileSettings(home, env, onlineBaseUrl, teamId, user) {
  const meee2Dir = join(home, '.meee2')
  mkdirSync(meee2Dir, { recursive: true })
  mkdirSync(join(home, 'Library', 'Preferences'), { recursive: true })
  writeFileSync(join(meee2Dir, 'settings.json'), JSON.stringify({
    meee2: {
      supabaseUrl: env.supabaseUrl,
      supabaseKey: env.anonKey,
      onlineBaseUrl,
      accessToken: user.accessToken,
      refreshToken: user.refreshToken,
      teamId,
      userId: user.id,
    },
  }, null, 2))
}

async function startDesktop(binary, env, onlineBaseUrl, world, user, label, baseDir) {
  const port = await getFreePort()
  const home = join(baseDir, `${label}-home`)
  writeProfileSettings(home, env, onlineBaseUrl, world.teamId, user)
  const proc = trackedSpawn(binary, ['board'], {
    cwd: repoRoot,
    env: {
      ...process.env,
      HOME: home,
      MEEE2_E2E: '1',
      MEEE2_E2E_HEADLESS: '1',
      MEEE2_BOARD_PORT: String(port),
      MEEE2_ONLINE_BASE_URL: onlineBaseUrl,
      MEEE2_ONLINE_ACCESS_TOKEN: user.accessToken,
      MEEE2_ONLINE_REFRESH_TOKEN: user.refreshToken,
      MEEE2_ONLINE_TEAM_ID: world.teamId,
      MEEE2_ONLINE_USER_ID: user.id,
      MEEE2_SUPABASE_URL: env.supabaseUrl,
      MEEE2_SUPABASE_ANON_KEY: env.anonKey,
    },
  }, `desktop-${label}`)
  const baseUrl = `http://127.0.0.1:${port}`
  await Promise.race([
    waitFor(async () => {
      try {
        const res = await fetch(`${baseUrl}/api/canvases`)
        return res.status === 200
      } catch {
        return false
      }
    }, `${label} desktop BoardServer`, 45_000),
    new Promise((_, reject) => proc.child.once('exit', () => reject(new Error(proc.output())))),
  ])
  requireOk(
    await jsonFetch(`${baseUrl}/api/user-profile`, {
      method: 'PATCH',
      body: JSON.stringify({ defaultSyncEnabled: true }),
    }),
    `${label} enable default session sync`,
  )
  return { label, baseUrl, home, stop: proc.stop, output: proc.output }
}

async function desktopJson(desktop, path, init = {}) {
  return jsonFetch(`${desktop.baseUrl}${path}`, init)
}

async function onlineJson(online, user, path, init = {}) {
  return jsonFetch(`${online.baseUrl}${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${user.accessToken}`,
      ...(init.headers || {}),
    },
  })
}

function findCanvas(envelope, predicate) {
  return (envelope.canvases || []).find(predicate)
}

async function forceTeamSync(desktop) {
  return requireOk(
    await desktopJson(desktop, '/api/_e2e/team-sync', { method: 'POST', body: '{}' }),
    `${desktop.label} force team sync`,
  )
}

async function createTeamCanvas(ownerDesktop, name) {
  const envelope = requireOk(
    await desktopJson(ownerDesktop, '/api/canvases', {
      method: 'POST',
      body: JSON.stringify({ name, scope: 'team' }),
    }),
    'create team canvas on owner desktop',
  )
  const canvas = findCanvas(envelope, (item) => item.name === name && item.scope === 'team')
  assert(canvas, 'created Team Canvas is missing from owner desktop')
  return canvas
}

function nodePayload(canvasId, nodeId, title, ownerId, sessionId = null) {
  return {
    id: nodeId,
    canvasId,
    title,
    schema: { inputs: ['brief'], outputs: ['report'], goal: 'team sync e2e node' },
    contextSources: [],
    executionMode: 'human',
    executorType: 'human',
    doerId: ownerId,
    reviewerIds: [],
    approverIds: [],
    handoffPolicy: 'none',
    status: 'ready',
    ...(sessionId ? { sessionId, chatThreadId: sessionId } : {}),
    source: 'planner',
    dependsOnNodeIds: [],
    nodeKind: 'step',
    layout: { x: 120, y: 160, width: 360, height: 180 },
  }
}

async function proposeApproveApply(desktop, canvasId, changes, summary) {
  const proposed = requireOk(
    await desktopJson(desktop, `/api/planner/canvases/${canvasId}/proposals/graph-change`, {
      method: 'POST',
      body: JSON.stringify({ summary, changes }),
    }),
    `propose ${summary}`,
  )
  const proposalId = proposed.proposal.id
  requireOk(
    await desktopJson(desktop, `/api/planner/canvases/${canvasId}/proposals/${proposalId}/approve`, {
      method: 'POST',
      body: '{}',
    }),
    `approve ${summary}`,
  )
  return requireOk(
    await desktopJson(desktop, `/api/planner/canvases/${canvasId}/proposals/${proposalId}/apply`, {
      method: 'POST',
      body: '{}',
    }),
    `apply ${summary}`,
  )
}

async function graph(desktop, canvasId) {
  return requireOk(
    await desktopJson(desktop, `/api/planner/canvases/${canvasId}/graph`),
    `${desktop.label} read graph ${canvasId}`,
  )
}

async function e2eUpsertSession(desktop, sessionId, payload) {
  return requireOk(
    await desktopJson(desktop, `/api/_e2e/sessions/${encodeURIComponent(sessionId)}`, {
      method: 'POST',
      body: JSON.stringify(payload),
    }),
    `${desktop.label} upsert e2e session`,
  )
}

async function enableSessionSync(desktop, sessionId) {
  return requireOk(
    await desktopJson(desktop, '/api/user-profile', {
      method: 'PATCH',
      body: JSON.stringify({ sessionSync: { sessionId, enabled: true } }),
    }),
    `${desktop.label} enable session sync ${sessionId}`,
  )
}

async function e2eAppendSessionMessage(desktop, sessionId, role, text) {
  return requireOk(
    await desktopJson(desktop, `/api/_e2e/sessions/${encodeURIComponent(sessionId)}/messages`, {
      method: 'POST',
      body: JSON.stringify({ role, text }),
    }),
    `${desktop.label} append e2e session message`,
  )
}

async function listOnlineSessions(online, user, teamId) {
  return requireOk(
    await onlineJson(online, user, `/api/v1/sessions?teamId=${encodeURIComponent(teamId)}&limit=100`),
    'list online sessions as member',
  ).sessions || []
}

async function onlineSessionMessages(online, user, sessionId) {
  return requireOk(
    await onlineJson(online, user, `/api/v1/sessions/${encodeURIComponent(sessionId)}/messages?limit=20`),
    'read online session transcript as member',
  ).messages || []
}

function sessionSummary(session) {
  return session?.summary && typeof session.summary === 'object' ? session.summary : {}
}

async function main() {
  const env = loadOnlineEnv()
  const authHealth = await supabaseFetch(env, '/auth/v1/health', {}, false)
  assert(authHealth.status === 200, 'Local Supabase is not healthy; run pnpm --dir ../meee2-online local:supabase')

  const online = await startOnline(env)
  const world = await seedWorld(env)
  const baseDir = join(tmpdir(), `meee2-desktop-team-e2e-${world.runId}`)
  mkdirSync(baseDir, { recursive: true })
  let ownerDesktop
  let memberDesktop
  try {
    console.log(`Using meee2-online API at ${online.baseUrl}`)
    const binary = await swiftBuild()
    ownerDesktop = await startDesktop(binary, env, online.baseUrl, world, world.owner, 'owner', baseDir)
    memberDesktop = await startDesktop(binary, env, online.baseUrl, world, world.member, 'member', baseDir)
    console.log(`Owner desktop: ${ownerDesktop.baseUrl}`)
    console.log(`Member desktop: ${memberDesktop.baseUrl}`)

    const canvasName = `Meee2 Desktop Team Sync ${world.runId}`
    const canvas = await createTeamCanvas(ownerDesktop, canvasName)
    const canvasId = canvas.id
    const nodeId = `node-${world.runId.replace(/[^a-z0-9]/gi, '-')}`
    const runtimeSessionId = `e2e-session-${world.runId.replace(/[^a-z0-9]/gi, '-')}`
    await proposeApproveApply(ownerDesktop, canvasId, [
      { kind: 'addNode', node: nodePayload(canvasId, nodeId, 'Owner draft node', world.owner.id, runtimeSessionId) },
    ], 'Add E2E node')
    let ownerEnvelope = await forceTeamSync(ownerDesktop)
    let ownerCanvas = findCanvas(ownerEnvelope, (item) => item.id === canvasId)
    assert(ownerCanvas?.syncStatus === 'synced', `owner canvas should sync, got ${ownerCanvas?.syncStatus}`)
    console.log('✓ owner desktop created and synced Team Canvas graph')

    await waitFor(async () => {
      const memberEnvelope = await forceTeamSync(memberDesktop)
      return findCanvas(memberEnvelope, (item) => item.id === canvasId)
    }, 'member desktop pulls owner Team Canvas', 30_000)
    const memberGraph = await graph(memberDesktop, canvasId)
    assert(memberGraph.access?.role === 'viewer', `member should open owner canvas as viewer, got ${memberGraph.access?.role}`)
    assert(memberGraph.access?.canApplyProposal === false, 'member should not be able to apply proposals on owner canvas')
    assert((memberGraph.nodes || []).some((node) => node.id === nodeId && node.title === 'Owner draft node'), 'member graph missed owner node')
    assert((memberGraph.nodes || []).some((node) => node.id === nodeId && node.sessionId === runtimeSessionId), 'member graph missed bound sessionId')
    console.log('✓ member desktop pulled owner canvas as read-only')

    await enableSessionSync(ownerDesktop, runtimeSessionId)
    await e2eUpsertSession(ownerDesktop, runtimeSessionId, {
      status: 'active',
      project: 'Meee2舆情洞察',
      cwd: repoRoot,
      currentTool: 'WebFetch',
      currentTask: 'Collecting product sentiment',
    })
    const remoteSession = await waitFor(async () => {
      const sessions = await listOnlineSessions(online, world.member, world.teamId)
      return sessions.find((session) => session.session_key === runtimeSessionId && session.status === 'active')
    }, 'member sees owner session runtime', 30_000)
    let remoteSummary = sessionSummary(remoteSession)
    assert(remoteSummary.currentTool === 'WebFetch', `member session currentTool mismatch: ${remoteSummary.currentTool}`)
    assert(remoteSummary.currentTask === 'Collecting product sentiment', `member session currentTask mismatch: ${remoteSummary.currentTask}`)
    console.log('✓ member token can read owner session runtime status')

    const transcriptText = `Owner session transcript marker ${world.runId}: ` +
      `${'transcript-body-'.repeat(24)}tail-visible`
    await e2eAppendSessionMessage(ownerDesktop, runtimeSessionId, 'assistant', transcriptText)
    const transcriptRows = await waitFor(async () => {
      const rows = await onlineSessionMessages(online, world.member, remoteSession.id)
      return rows.some((row) => JSON.stringify(row.content).includes('tail-visible')) ? rows : null
    }, 'member sees owner session transcript', 30_000)
    assert(transcriptRows.some((row) => JSON.stringify(row.content).includes('tail-visible')), 'member transcript missed full message tail')
    const sessionWithRecent = await waitFor(async () => {
      const sessions = await listOnlineSessions(online, world.member, world.teamId)
      return sessions.find((session) => {
        if (session.session_key !== runtimeSessionId) return false
        const summary = sessionSummary(session)
        return JSON.stringify(summary.recentMessages || []).includes('tail-visible')
      })
    }, 'member sees owner session recent message', 30_000)
    remoteSummary = sessionSummary(sessionWithRecent)
    assert(JSON.stringify(remoteSummary.recentMessages || []).includes('tail-visible'), 'member recentMessages missed transcript marker')
    console.log('✓ member token can read owner session transcript and recent message')

    const forbidden = await desktopJson(memberDesktop, `/api/planner/canvases/${canvasId}/proposals/graph-change`, {
      method: 'POST',
      body: JSON.stringify({
        summary: 'Member should not mutate owner graph',
        changes: [{ kind: 'updateNode', nodeId, title: 'Member mutation should fail' }],
      }),
    })
    assert(forbidden.status === 403 || forbidden.status === 400, `member mutation should fail, got HTTP ${forbidden.status}`)
    console.log('✓ member desktop cannot mutate owner Team Canvas')

    await proposeApproveApply(ownerDesktop, canvasId, [
      { kind: 'updateNode', nodeId, title: 'Owner updated node' },
    ], 'Update E2E node')
    ownerEnvelope = await forceTeamSync(ownerDesktop)
    ownerCanvas = findCanvas(ownerEnvelope, (item) => item.id === canvasId)
    assert(ownerCanvas?.remoteVersion >= 2, `owner remote version should bump, got ${ownerCanvas?.remoteVersion}`)
    await forceTeamSync(memberDesktop)
    await waitFor(async () => {
      const next = await graph(memberDesktop, canvasId)
      return (next.nodes || []).some((node) => node.id === nodeId && node.title === 'Owner updated node')
    }, 'member desktop sees owner graph update', 30_000)
    console.log('✓ member desktop refreshed updated owner graph')

    console.log('Desktop Team mode E2E passed.')
  } catch (error) {
    if (ownerDesktop) {
      console.error('--- owner desktop output ---')
      console.error(ownerDesktop.output())
    }
    if (memberDesktop) {
      console.error('--- member desktop output ---')
      console.error(memberDesktop.output())
    }
    throw error
  } finally {
    if (memberDesktop) await memberDesktop.stop()
    if (ownerDesktop) await ownerDesktop.stop()
    await cleanupWorld(env, world)
    await online.stop()
  }
}

main().catch((error) => {
  console.error(error.stack || error.message)
  process.exitCode = 1
})
