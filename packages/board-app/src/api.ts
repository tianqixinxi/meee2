import type {
  BoardState,
  Channel,
  Message,
  MessageStatus,
  Mode,
  Meee2MCPStatus,
  Meee2AgentRuntimeInstallResult,
  Meee2AgentRuntimeStatus,
  CanvasList,
  CanvasScope,
  SelectedCanvasElementContext,
  SpawnProvider,
  CoordinationGroup,
  PlanProposal,
  PlannerActivity,
  PlannerCanvasState,
  PlannerGraphState,
  WorkflowRun,
  PlannerMonitorState,
  PlannerNodeContract,
  PlannerArtifactContent,
  PlannerArtifactVersion,
  PlannerNodeOutput,
  PlannerNodeOutputResult,
  PlanningNode,
  PlanningNodeStatus,
  PlannerNodeLayout,
  PlanChange,
  PlannerArtifactKind,
  PlannerDispatchRunner,
  PlannerCanvasVisibility,
  PlanningCanvas,
  ExternalItemsResult,
  AgentScanResult,
  CanvasSideEffectsResult,
  IntegrationInstallResult,
  IntegrationRunbookResult,
  ContextSourceKind,
  AssignPlannerNodeResult,
  OwnedCanvasSummary,
} from './types'

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: Record<string, { postMessage: (payload: unknown) => void } | undefined>
    }
  }
}

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

const PLANNER_DEMO_MODE = import.meta.env.VITE_PLANNER_DEMO === '1'
const DEMO_CANVAS_ID = 'demo-planner'
const DEMO_SUB_CANVAS_ID = 'demo-release-readiness'
const DEMO_OWNER_ID = 'demo-owner'

let demoActiveCanvasId = DEMO_CANVAS_ID
let demoProposal: PlanProposal | null = null
let demoCanvasRecords: Record<string, CanvasList['canvases'][number]> = {
  [DEMO_CANVAS_ID]: {
    id: DEMO_CANVAS_ID,
    name: 'meee2 AI Demo',
    scope: 'personal',
    kind: 'board',
    isDefault: true,
    workspacePath: '/demo/planner',
    ownerUserId: DEMO_OWNER_ID,
  },
  [DEMO_SUB_CANVAS_ID]: {
    id: DEMO_SUB_CANVAS_ID,
    name: 'Release Readiness',
    scope: 'personal',
    kind: 'board',
    isDefault: false,
    workspacePath: '/demo/release-readiness',
    ownerUserId: DEMO_OWNER_ID,
  },
}
let demoNodesByCanvasId: Record<string, PlanningNode[]> = {
  [DEMO_CANVAS_ID]: [
    demoNode({
      id: 'contract',
      title: 'meee2 AI Core Contract',
      status: 'done',
      executorType: 'human',
      executionMode: 'human',
      outputs: ['contract.md', 'meee2-ai-dto'],
    }),
    demoNode({
      id: 'state-api',
      title: 'Store-backed meee2 AI State API',
      status: 'working',
      executorType: 'codex',
      executionMode: 'auto',
      inputs: ['contract.md'],
      outputs: ['GET /api/planner/canvases/:id/state'],
      dependsOnNodeIds: ['contract'],
    }),
    demoNode({
      id: 'proposal-shell',
      title: 'Owner Proposal Shell',
      status: 'blocked',
      executorType: 'claude',
      executionMode: 'human',
      inputs: ['meee2-ai-dto'],
      outputs: ['proposal-preview'],
      dependsOnNodeIds: ['contract', 'state-api'],
    }),
    demoNode({
      id: 'react-flow-graph',
      title: 'React Flow meee2 AI Graph',
      status: 'working',
      executorType: 'codex',
      executionMode: 'auto',
      inputs: ['meee2-ai-state'],
      outputs: ['graph-ui'],
      dependsOnNodeIds: ['state-api'],
    }),
    demoNode({
      id: 'release-readiness',
      title: 'Release Readiness Sub-canvas',
      status: 'draft',
      executorType: 'openClaw',
      executionMode: 'human',
      inputs: ['graph-ui', 'proposal-preview'],
      outputs: ['review-checklist'],
      dependsOnNodeIds: ['proposal-shell', 'react-flow-graph'],
      subCanvasId: DEMO_SUB_CANVAS_ID,
    }),
  ],
  [DEMO_SUB_CANVAS_ID]: [
    demoNode({
      id: 'qa-pass',
      canvasId: DEMO_SUB_CANVAS_ID,
      title: 'Rendered QA Pass',
      status: 'working',
      executorType: 'codex',
      executionMode: 'auto',
      outputs: ['screenshot', 'dom-check'],
    }),
    demoNode({
      id: 'handoff',
      canvasId: DEMO_SUB_CANVAS_ID,
      title: 'Owner Handoff Notes',
      status: 'ready',
      executorType: 'human',
      executionMode: 'human',
      inputs: ['screenshot', 'dom-check'],
      outputs: ['handoff.md'],
      dependsOnNodeIds: ['qa-pass'],
    }),
  ],
}

function demoNode(input: {
  id: string
  canvasId?: string
  title: string
  status: PlanningNode['status']
  executorType: PlanningNode['executorType']
  executionMode: PlanningNode['executionMode']
  inputs?: string[]
  outputs?: string[]
  dependsOnNodeIds?: string[]
  sessionId?: string
  source?: PlanningNode['source']
  subCanvasId?: string
}): PlanningNode {
  const canvasId = input.canvasId ?? DEMO_CANVAS_ID
  return {
    id: input.id,
    canvasId,
    title: input.title,
    schema: {
      inputs: input.inputs ?? [],
      outputs: input.outputs ?? [],
      goal: `${input.id}.done`,
    },
    contextSources: [
      {
        kind: 'repository',
        title: 'meee2 AI branch',
        reference: 'codex/react-flow-planner-graph',
      },
    ],
    executionMode: input.executionMode,
    executorType: input.executorType,
    doerId: input.executorType === 'human' ? DEMO_OWNER_ID : `agent-${input.executorType}`,
    status: input.status,
    sessionId: input.sessionId ?? null,
    chatThreadId: input.sessionId ? `${input.sessionId}-thread` : null,
    source: input.source ?? 'planner',
    dependsOnNodeIds: input.dependsOnNodeIds ?? [],
    subCanvasId: input.subCanvasId ?? null,
  }
}

function demoCanvases(): CanvasList {
  return {
    activeCanvasId: demoActiveCanvasId,
    defaultCanvasIds: [DEMO_CANVAS_ID],
    memberships: [],
    canvases: Object.values(demoCanvasRecords),
  }
}

function demoBoardState(): BoardState {
  return {
    sessions: Object.values(demoNodesByCanvasId).flat().filter((node) => node.sessionId).map((node) => ({
      id: node.sessionId ?? node.id,
      title: node.title,
      project: '/demo/planner',
      pluginId: `demo.${node.executorType}`,
      pluginDisplayName: node.executorType,
      pluginColor: node.status === 'blocked' ? '#C26A6A' : '#8BA9C2',
      status: node.status === 'blocked' ? 'permissionRequired' : node.status,
      inboxPending: node.status === 'blocked' ? 1 : 0,
      recentMessages: [{ role: 'assistant', text: `${node.title} is ${node.status}` }],
      currentTool: null,
      usageStats: null,
      backgroundAgents: [],
      latestRecap: null,
      syncEnabled: false,
      syncTeamId: null,
      syncTeamName: null,
    })),
    channels: [],
    coordinationGroups: [],
  }
}

function demoPlannerState(canvasId: string): PlannerCanvasState {
  const safeCanvasId = demoCanvasRecords[canvasId] ? canvasId : DEMO_CANVAS_ID
  const canvas = demoCanvasRecords[safeCanvasId]
  const nodes = demoNodesByCanvasId[safeCanvasId] ?? []
  const now = new Date().toISOString()
  return {
    canvas: {
      id: safeCanvasId,
      ownerId: DEMO_OWNER_ID,
      title: canvas.name,
      plannerContext: 'Static public demo of the React Flow meee2 AI Graph.',
    },
    nodes,
    states: nodes.map(demoNodeState),
    proposals: demoProposal && demoProposal.canvasId === safeCanvasId ? [demoProposal] : [],
    access: {
      actorId: DEMO_OWNER_ID,
      role: 'owner',
      canCreateProposal: true,
      canApproveProposal: true,
      canApplyProposal: true,
      canRejectProposal: true,
      canUpdateAssignedNode: true,
    },
    activities: [
      {
        userId: DEMO_OWNER_ID,
        displayName: 'Owner',
        currentCanvasId: safeCanvasId,
        selectedNodeId: nodes.find((node) => node.status === 'blocked')?.id ?? nodes[0]?.id ?? null,
        selectedSessionId: null,
        lastActiveAt: now,
      },
      {
        userId: 'viewer-demo',
        displayName: 'Teammate viewer',
        currentCanvasId: safeCanvasId,
        selectedNodeId: nodes.find((node) => node.status === 'working')?.id ?? null,
        selectedSessionId: null,
        lastActiveAt: now,
      },
    ],
    events: [
      {
        id: 'event-contract',
        canvasId: safeCanvasId,
        type: 'node.created',
        nodeId: nodes[0]?.id ?? null,
        proposalId: null,
        summary: 'meee2 AI graph loaded from public demo fixtures.',
        artifactRefs: ['demo://planner'],
        createdAt: now,
      },
      ...(demoProposal && demoProposal.canvasId === safeCanvasId ? [{
        id: `event-${demoProposal.id}`,
        canvasId: safeCanvasId,
        type: 'proposal.created' as const,
        nodeId: null,
        proposalId: demoProposal.id,
        summary: demoProposal.summary,
        artifactRefs: [],
        createdAt: now,
      }] : []),
    ],
    artifacts: nodes.flatMap((node) => (node.artifactRefs ?? []).map((ref) => ({
      id: `artifact-${node.id}-${ref}`,
      canvasId: safeCanvasId,
      nodeId: node.id,
      kind: 'generic' as const,
      title: ref,
      reference: ref,
      status: node.status,
      createdAt: now,
    }))),
    edges: nodes.flatMap((node) => (node.dependsOnNodeIds ?? []).map((dependencyId) => ({
      id: `edge-${dependencyId}-${node.id}`,
      sourceNodeId: dependencyId,
      targetNodeId: node.id,
      kind: 'dependency',
    }))),
  }
}

function demoNodeState(node: PlanningNode) {
  const blocked = node.status === 'blocked'
  return {
    nodeId: node.id,
    runState: node.status,
    blockers: blocked ? ['Blocked before topology changes can apply.'] : [],
    artifactRefs: node.schema.outputs.map((item) => `demo://${item}`),
    needsOwnerReview: false,
  }
}

function nextDemoProposal(canvasId: string, summary: string, title: string): PlanProposal {
  const safeCanvasId = demoCanvasRecords[canvasId] ? canvasId : DEMO_CANVAS_ID
  return {
    id: `proposal-${Date.now()}`,
    canvasId: safeCanvasId,
    summary,
    status: 'pending',
    changes: [{
      kind: 'addNode',
      node: demoNode({
        id: `owner-review-${Date.now()}`,
        canvasId: safeCanvasId,
        title,
        status: 'ready',
        executorType: 'human',
        executionMode: 'human',
        inputs: ['proposal-preview'],
        outputs: ['owner-decision'],
        dependsOnNodeIds: demoNodesByCanvasId[safeCanvasId]?.slice(-1).map((node) => node.id) ?? [],
      }),
    }],
  }
}

function applyDemoChanges(nodes: PlanningNode[], proposal: PlanProposal): PlanningNode[] {
  let next = [...nodes]
  for (const change of proposal.changes) {
    if (change.kind === 'addNode' && change.node) {
      if (!next.some((node) => node.id === change.node?.id)) next.push(change.node)
    }
    if (change.kind === 'updateNode' && change.nodeId) {
      next = next.map((node) => node.id === change.nodeId ? {
        ...node,
        title: change.title ?? node.title,
        status: change.status ?? node.status,
        schema: change.schema ?? node.schema,
        contextSources: change.contextSources ?? node.contextSources,
        dependsOnNodeIds: change.dependsOnNodeIds ?? node.dependsOnNodeIds,
        subCanvasId: change.subCanvasId ?? node.subCanvasId,
        executionMode: change.executionMode ?? node.executionMode,
        gate: change.clearGate ? null : (change.gate ?? node.gate),
        approvers: change.clearGate ? null : (change.approvers ?? node.approvers),
      } : node)
    }
  }
  return next
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
  if (PLANNER_DEMO_MODE) return Promise.resolve(demoBoardState())
  return jsonRequest<BoardState>('/api/state')
}

export function fetchMeee2MCPStatus(): Promise<Meee2MCPStatus> {
  if (PLANNER_DEMO_MODE) {
    return Promise.resolve({
      configured: true,
      configCommand: 'node',
      configArgs: ['/demo/Bridge/mcp-meee2/server.js'],
      expectedServerPath: '/demo/Bridge/mcp-meee2/server.js',
      serverPath: '/demo/Bridge/mcp-meee2/server.js',
      serverExists: true,
      nodeAvailable: true,
      launches: true,
      tools: ['read_node_contract', 'submit_node_output', 'attach_artifact_to_node'],
      missingRequiredTools: [],
      error: null,
      checkedAt: new Date().toISOString(),
    })
  }
  return jsonRequest<Meee2MCPStatus>('/api/system/meee2-mcp-status')
}

export function fetchMeee2AgentRuntimeStatus(): Promise<Meee2AgentRuntimeStatus> {
  return jsonRequest<Meee2AgentRuntimeStatus>('/api/system/meee2-agent-runtime-status')
}

export function installMeee2AgentRuntime(target: 'claude' | 'codex' | 'all'): Promise<Meee2AgentRuntimeInstallResult> {
  return jsonRequest<Meee2AgentRuntimeInstallResult>('/api/system/meee2-agent-runtime-install', {
    method: 'POST',
    body: JSON.stringify({ target }),
  })
}

// -- coordination groups ---------------------------------------------------

export function fetchCoordinationGroups(): Promise<{ groups: CoordinationGroup[] }> {
  return jsonRequest<{ groups: CoordinationGroup[] }>('/api/coordination-groups')
}

export function syncCoordinationGroup(groupId: string): Promise<{ group: CoordinationGroup }> {
  return jsonRequest<{ group: CoordinationGroup }>(`/api/coordination-groups/${encodeURIComponent(groupId)}/sync`, {
    method: 'POST',
    body: JSON.stringify({}),
  })
}

export function askCoordinator(groupId: string, reason?: string): Promise<{ group: CoordinationGroup }> {
  return jsonRequest<{ group: CoordinationGroup }>(`/api/coordination-groups/${encodeURIComponent(groupId)}/ask`, {
    method: 'POST',
    body: JSON.stringify({ reason: reason ?? 'manual Ask coordinator' }),
  })
}

export function pauseCoordination(groupId: string): Promise<{ group: CoordinationGroup }> {
  return jsonRequest<{ group: CoordinationGroup }>(`/api/coordination-groups/${encodeURIComponent(groupId)}/pause`, {
    method: 'POST',
    body: JSON.stringify({}),
  })
}

export function resumeCoordination(groupId: string): Promise<{ group: CoordinationGroup }> {
  return jsonRequest<{ group: CoordinationGroup }>(`/api/coordination-groups/${encodeURIComponent(groupId)}/resume`, {
    method: 'POST',
    body: JSON.stringify({}),
  })
}

export function removeCoordinationMember(groupId: string, sessionId: string): Promise<{ group: CoordinationGroup }> {
  return jsonRequest<{ group: CoordinationGroup }>(
    `/api/coordination-groups/${encodeURIComponent(groupId)}/members/${encodeURIComponent(sessionId)}`,
    { method: 'DELETE' },
  )
}

// -- canvases --------------------------------------------------------------

export function fetchCanvases(): Promise<CanvasList> {
  if (PLANNER_DEMO_MODE) return Promise.resolve(demoCanvases())
  return jsonRequest<CanvasList>('/api/canvases')
}

export function createCanvas(input: { name: string; scope: CanvasScope; kind?: CanvasList['canvases'][number]['kind'] }): Promise<CanvasList> {
  if (PLANNER_DEMO_MODE) {
    const id = `demo-canvas-${Date.now()}`
    demoCanvasRecords = {
      ...demoCanvasRecords,
      [id]: {
        id,
        name: input.name,
        scope: input.scope,
        kind: input.kind ?? 'board',
        isDefault: false,
        workspacePath: `/demo/${id}`,
        ownerUserId: DEMO_OWNER_ID,
      },
    }
    demoNodesByCanvasId = {
      ...demoNodesByCanvasId,
      [id]: [],
    }
    demoActiveCanvasId = id
    return Promise.resolve(demoCanvases())
  }
  return jsonRequest<CanvasList>('/api/canvases', {
    method: 'POST',
    body: JSON.stringify(input),
  })
}

export function updateCanvas(
  id: string,
  input: { name?: string; active?: boolean },
): Promise<CanvasList> {
  if (PLANNER_DEMO_MODE) {
    if (input.active && demoCanvasRecords[id]) demoActiveCanvasId = id
    if (input.name && demoCanvasRecords[id]) {
      demoCanvasRecords = {
        ...demoCanvasRecords,
        [id]: { ...demoCanvasRecords[id], name: input.name },
      }
    }
    return Promise.resolve(demoCanvases())
  }
  return jsonRequest<CanvasList>(`/api/canvases/${encodeURIComponent(id)}`, {
    method: 'PATCH',
    body: JSON.stringify(input),
  })
}

export function deleteCanvas(id: string): Promise<CanvasList> {
  if (PLANNER_DEMO_MODE) {
    if (id !== DEMO_CANVAS_ID) {
      const nextCanvases = { ...demoCanvasRecords }
      const nextNodes = { ...demoNodesByCanvasId }
      delete nextCanvases[id]
      delete nextNodes[id]
      demoCanvasRecords = nextCanvases
      demoNodesByCanvasId = nextNodes
      if (demoActiveCanvasId === id) demoActiveCanvasId = DEMO_CANVAS_ID
    }
    return Promise.resolve(demoCanvases())
  }
  return jsonRequest<CanvasList>(`/api/canvases/${encodeURIComponent(id)}`, {
    method: 'DELETE',
  })
}

export function addSessionToCanvas(canvasId: string, sessionId: string): Promise<CanvasList> {
  return jsonRequest<CanvasList>(`/api/canvases/${encodeURIComponent(canvasId)}/sessions`, {
    method: 'POST',
    body: JSON.stringify({ sessionId }),
  })
}

export function removeSessionFromCanvas(
  canvasId: string,
  sessionId: string,
): Promise<CanvasList> {
  return jsonRequest<CanvasList>(
    `/api/canvases/${encodeURIComponent(canvasId)}/sessions/${encodeURIComponent(sessionId)}`,
    { method: 'DELETE' },
  )
}

export function resolveCanvasConflict(
  canvasId: string,
  choice: 'current' | 'remote',
): Promise<CanvasList> {
  return jsonRequest<CanvasList>(`/api/canvases/${encodeURIComponent(canvasId)}/conflict`, {
    method: 'POST',
    body: JSON.stringify({ choice }),
  })
}

export function spawnGlobalSession(
  canvasId: string,
  provider: SpawnProvider,
  cwd?: string,
): Promise<{ ok: boolean; cwd: string; command: string; sessionId?: string; surfaceId?: string; terminalKind?: string }> {
  return jsonRequest<{ ok: boolean; cwd: string; command: string; sessionId?: string; surfaceId?: string; terminalKind?: string }>(
    `/api/canvases/${encodeURIComponent(canvasId)}/sessions/spawn-global`,
    {
      method: 'POST',
      body: JSON.stringify({ provider, cwd }),
    },
  )
}

export interface SessionSurface {
  surfaceId: string
  sessionId: string
  provider: 'claude' | 'codex' | string
  title: string
  cwd: string
  command: string
  canvasId?: string | null
  nodeId?: string | null
  status: 'starting' | 'running' | 'exited' | 'failed' | string
  pid?: number | null
  exitCode?: number | null
  error?: string | null
  createdAt: string
  updatedAt: string
}

export function listSessionSurfaces(): Promise<SessionSurface[]> {
  return jsonRequest<{ surfaces: SessionSurface[] }>('/api/session-surfaces').then((result) => result.surfaces)
}

export function closeSessionSurface(id: string): Promise<{ ok: boolean }> {
  return jsonRequest<{ ok: boolean }>(`/api/session-surfaces/${encodeURIComponent(id)}/close`, {
    method: 'POST',
  })
}

export interface NativeTerminalRect {
  x: number
  y: number
  width: number
  height: number
}

export function openNativeTerminalSurface(input: {
  surfaceId?: string
  sessionId?: string
  rect?: NativeTerminalRect
  type?: 'attach' | 'layout' | 'hide' | 'detach' | 'focus' | 'prewarm'
  traceId?: string
  clickStartedAtMs?: number
  sentAtMs?: number
  webPhase?: string
}): boolean {
  const bridge = window.webkit?.messageHandlers?.meee2NativeTerminal
  if (!bridge) return false
  bridge.postMessage({
    type: input.type ?? 'attach',
    surfaceId: input.surfaceId,
    sessionId: input.sessionId,
    rect: input.rect,
    traceId: input.traceId,
    clickStartedAtMs: input.clickStartedAtMs,
    sentAtMs: input.sentAtMs,
    webPhase: input.webPhase,
  })
  return true
}

// -- planner ---------------------------------------------------------------

export function fetchPlannerCanvasState(canvasId: string): Promise<PlannerCanvasState> {
  if (PLANNER_DEMO_MODE) return Promise.resolve(demoPlannerState(canvasId))
  return jsonRequest<PlannerCanvasState>(`/api/planner/canvases/${encodeURIComponent(canvasId)}/state`)
}

export function fetchPlannerGraphState(canvasId: string): Promise<PlannerGraphState> {
  if (PLANNER_DEMO_MODE) {
    const state = demoPlannerState(canvasId)
    return Promise.resolve({
      ...state,
      artifacts: state.artifacts ?? [],
      edges: state.edges ?? [],
    })
  }
  return jsonRequest<PlannerGraphState>(`/api/planner/canvases/${encodeURIComponent(canvasId)}/graph`)
}

export function clearPlannerCanvasContent(canvasId: string): Promise<PlannerGraphState> {
  if (PLANNER_DEMO_MODE) {
    demoNodesByCanvasId[canvasId] = []
    if (demoProposal?.canvasId === canvasId) demoProposal = null
    const state = demoPlannerState(canvasId)
    return Promise.resolve({
      ...state,
      artifacts: state.artifacts ?? [],
      edges: state.edges ?? [],
    })
  }
  return jsonRequest<PlannerGraphState>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/clear`,
    {
      method: 'POST',
      body: JSON.stringify({}),
    },
  )
}

export function fetchPlannerWorkspaceMonitor(): Promise<PlannerMonitorState> {
  if (PLANNER_DEMO_MODE) {
    const generatedAt = new Date().toISOString()
    const items = Object.values(demoNodesByCanvasId).flat().map((node, index) => {
      const state = demoNodeState(node)
      return {
        id: `monitor-${node.id}`,
        kind: 'node' as const,
        canvasId: node.canvasId,
        canvasTitle: node.canvasId === DEMO_SUB_CANVAS_ID ? 'Release Readiness' : 'meee2 AI Demo',
        nodeId: node.id,
        nodeTitle: node.title,
        proposalId: null,
        proposalStatus: null,
        summary: node.title,
        runState: state.runState,
        blockers: state.blockers,
        needsOwnerReview: state.needsOwnerReview,
        doerId: node.doerId,
        riskRank: node.status === 'blocked' ? 0 : index + 2,
      }
    })
    return Promise.resolve({ generatedAt, items })
  }
  return jsonRequest<PlannerMonitorState>('/api/planner/monitor')
}

export function sendPlannerActivity(input: {
  canvasId: string
  selectedNodeId?: string | null
  selectedSessionId?: string | null
}): Promise<{ activity: PlannerActivity }> {
  if (PLANNER_DEMO_MODE) {
    return Promise.resolve({
      activity: {
        userId: DEMO_OWNER_ID,
        displayName: 'Owner',
        currentCanvasId: input.canvasId,
        selectedNodeId: input.selectedNodeId ?? null,
        selectedSessionId: input.selectedSessionId ?? null,
        lastActiveAt: new Date().toISOString(),
      },
    })
  }
  return jsonRequest('/api/planner/activity', {
    method: 'POST',
    body: JSON.stringify(input),
  })
}

export async function generatePlannerProposal(
  canvasId: string,
  goal: string,
  context?: string,
): Promise<PlanProposal | null> {
  if (PLANNER_DEMO_MODE) {
    demoProposal = nextDemoProposal(
      canvasId,
      `Generate meee2 AI graph for: ${goal || 'owner goal'}`,
      goal ? `Owner review: ${goal}` : 'Owner review checkpoint',
    )
    return demoProposal
  }
  const response = await jsonRequest<{ proposal: PlanProposal | null }>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/proposals/generate`,
    {
      method: 'POST',
      body: JSON.stringify(context?.trim() ? { goal, context } : { goal }),
    },
  )
  return response.proposal
}

export async function inspectPlannerDrift(canvasId: string): Promise<PlanProposal | null> {
  if (PLANNER_DEMO_MODE) {
    const blocked = demoNodesByCanvasId[canvasId]?.find((node) => node.status === 'blocked')
      ?? demoNodesByCanvasId[DEMO_CANVAS_ID].find((node) => node.status === 'blocked')
    if (!blocked) return null
    demoProposal = {
      id: `drift-${Date.now()}`,
      canvasId: blocked.canvasId,
      summary: `Resolve drift around ${blocked.title}`,
      status: 'pending',
      changes: [{
        kind: 'updateNode',
        nodeId: blocked.id,
        title: `${blocked.title} - needs attention`,
        status: 'draft',
      }],
    }
    return demoProposal
  }
  const response = await jsonRequest<{ proposal: PlanProposal | null }>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/proposals/inspect-drift`,
    {
      method: 'POST',
      body: JSON.stringify({}),
    },
  )
  return response.proposal
}

export async function refinePlannerNode(
  canvasId: string,
  nodeId: string,
  reason: string,
): Promise<PlanProposal | null> {
  if (PLANNER_DEMO_MODE) {
    const node = demoNodesByCanvasId[canvasId]?.find((item) => item.id === nodeId)
    if (!node) return null
    demoProposal = nextDemoProposal(canvasId, `Refine ${node.title}: ${reason}`, `Refined follow-up for ${node.title}`)
    return demoProposal
  }
  const response = await jsonRequest<{ proposal: PlanProposal | null }>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/proposals/refine`,
    {
      method: 'POST',
      body: JSON.stringify({ nodeId, reason }),
    },
  )
  return response.proposal
}

export function applyPlannerProposalPreview(
  canvasId: string,
  proposal: PlanProposal,
): Promise<{
  proposal: PlanProposal
  nodes: PlannerCanvasState['nodes']
  states: PlannerCanvasState['states']
}> {
  if (PLANNER_DEMO_MODE) {
    const nodes = applyDemoChanges(demoNodesByCanvasId[canvasId] ?? demoNodesByCanvasId[DEMO_CANVAS_ID], proposal)
    return Promise.resolve({
      proposal: { ...proposal, status: proposal.status === 'pending' ? 'approved' : proposal.status },
      nodes,
      states: nodes.map(demoNodeState),
    })
  }
  return jsonRequest(`/api/planner/canvases/${encodeURIComponent(canvasId)}/proposals/apply-preview`, {
    method: 'POST',
    body: JSON.stringify({ proposal }),
  })
}

export async function approvePlannerProposal(
  canvasId: string,
  proposalId: string,
): Promise<PlanProposal | null> {
  if (PLANNER_DEMO_MODE && demoProposal?.id === proposalId) {
    demoProposal = { ...demoProposal, status: 'approved' }
    return demoProposal
  }
  const response = await jsonRequest<{ proposal: PlanProposal | null }>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/proposals/${encodeURIComponent(proposalId)}/approve`,
    {
      method: 'POST',
      body: JSON.stringify({}),
    },
  )
  return response.proposal
}

export function applyPlannerProposal(
  canvasId: string,
  proposalId: string,
): Promise<{
  proposal: PlanProposal
  nodes: PlannerCanvasState['nodes']
  states: PlannerCanvasState['states']
}> {
  if (PLANNER_DEMO_MODE && demoProposal?.id === proposalId) {
    const canvasIdToApply = demoProposal.canvasId
    const nodes = applyDemoChanges(demoNodesByCanvasId[canvasIdToApply] ?? [], demoProposal)
    demoNodesByCanvasId = {
      ...demoNodesByCanvasId,
      [canvasIdToApply]: nodes,
    }
    demoProposal = { ...demoProposal, status: 'applied' }
    return Promise.resolve({
      proposal: demoProposal,
      nodes,
      states: nodes.map(demoNodeState),
    })
  }
  return jsonRequest(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/proposals/${encodeURIComponent(proposalId)}/apply`,
    {
      method: 'POST',
      body: JSON.stringify({}),
    },
  )
}

export async function rejectPlannerProposal(
  canvasId: string,
  proposalId: string,
): Promise<PlanProposal | null> {
  if (PLANNER_DEMO_MODE && demoProposal?.id === proposalId) {
    demoProposal = { ...demoProposal, status: 'rejected' }
    return demoProposal
  }
  const response = await jsonRequest<{ proposal: PlanProposal | null }>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/proposals/${encodeURIComponent(proposalId)}/reject`,
    {
      method: 'POST',
      body: JSON.stringify({}),
    },
  )
  return response.proposal
}

export async function proposePlannerGraphChange(
  canvasId: string,
  input: { summary?: string; changes: PlanChange[] },
): Promise<PlanProposal | null> {
  const response = await jsonRequest<{ proposal: PlanProposal | null }>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/proposals/graph-change`,
    {
      method: 'POST',
      body: JSON.stringify(input),
    },
  )
  return response.proposal
}

export async function createPlannerDeliveryPipeline(canvasId: string): Promise<PlanProposal | null> {
  const response = await jsonRequest<{ proposal: PlanProposal | null }>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/templates/delivery-pipeline`,
    {
      method: 'POST',
      body: JSON.stringify({}),
    },
  )
  return response.proposal
}

// bind-session and dispatch are EXECUTION-LAYER actions: they apply DIRECTLY
// (no proposal / owner-approval gate, gated only by canUpdateAssignedNode) and
// return the updated graph state — same shape as attach-artifact / layout.

export function bindPlannerSessionToNode(
  canvasId: string,
  nodeId: string,
  sessionId: string,
): Promise<PlannerGraphState> {
  return jsonRequest<PlannerGraphState>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/nodes/${encodeURIComponent(nodeId)}/bind-session`,
    {
      method: 'POST',
      body: JSON.stringify({ sessionId }),
    },
  )
}

export function dispatchPlannerNodeSession(
  canvasId: string,
  nodeId: string,
  runner: PlannerDispatchRunner = 'claude',
  cwd?: string,
): Promise<PlannerGraphState> {
  return jsonRequest<PlannerGraphState>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/nodes/${encodeURIComponent(nodeId)}/dispatch`,
    {
      method: 'POST',
      body: JSON.stringify({ runner, cwd }),
    },
  )
}

export interface PlannerNodeInternalSessionResult {
  ok: boolean
  sessionId: string
  surfaceId: string
  cwd: string
  command: string
  terminalKind: 'internal' | string
  action?: 'reuse' | 'create' | 'resume' | 'recreate' | string
  graph: PlannerGraphState
}

export function ensurePlannerNodeInternalSession(
  canvasId: string,
  nodeId: string,
  input?: {
    runner?: PlannerDispatchRunner
    cwd?: string
  },
): Promise<PlannerNodeInternalSessionResult> {
  return jsonRequest<PlannerNodeInternalSessionResult>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/nodes/${encodeURIComponent(nodeId)}/internal-session`,
    {
      method: 'POST',
      body: JSON.stringify(input ?? {}),
    },
  )
}

export function updatePlannerNodeGate(
  canvasId: string,
  nodeId: string,
  executionMode: 'human' | 'auto',
): Promise<PlannerGraphState> {
  return jsonRequest<PlannerGraphState>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/nodes/${encodeURIComponent(nodeId)}/gate`,
    {
      method: 'PATCH',
      body: JSON.stringify({ executionMode }),
    },
  )
}

export function abandonPlannerNodeSession(
  canvasId: string,
  nodeId: string,
): Promise<PlannerGraphState> {
  return jsonRequest<PlannerGraphState>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/nodes/${encodeURIComponent(nodeId)}/abandon-session`,
    {
      method: 'POST',
      body: JSON.stringify({}),
    },
  )
}

export function detachPlannerNodeSession(
  canvasId: string,
  nodeId: string,
): Promise<PlannerGraphState> {
  return jsonRequest<PlannerGraphState>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/nodes/${encodeURIComponent(nodeId)}/detach-session`,
    {
      method: 'POST',
      body: JSON.stringify({}),
    },
  )
}

export interface ResumeClosedPlannerSessionResult {
  sessionId: string
  surfaceId: string
  nodeIds: string[]
  cwd: string
  command: string
  terminalKind: 'internal' | string
  action?: 'resume' | 'recreate' | string
}

export interface ResumeClosedPlannerSessionsResponse {
  resumed: ResumeClosedPlannerSessionResult[]
  skipped: Array<{ sessionId: string; reason: string }>
}

export function resumeClosedPlannerSessions(
  canvasId: string,
  sessionIds: string[],
): Promise<ResumeClosedPlannerSessionsResponse> {
  return jsonRequest<ResumeClosedPlannerSessionsResponse>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/sessions/resume-closed`,
    {
      method: 'POST',
      body: JSON.stringify({ sessionIds }),
    },
  )
}

// -- P1/P3: Workflow Run layer --------------------------------------------

export interface StartPlannerDeliveryInput {
  title: string
  summary?: string
  responsibleUserId?: string | null
  linkedArtifactRefs?: string[]
}

/** Start a new Delivery over the canvas's current Plan. */
export async function startPlannerRun(
  canvasId: string,
  input?: StartPlannerDeliveryInput,
): Promise<WorkflowRun> {
  const res = await jsonRequest<{ run: WorkflowRun }>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/deliveries`,
    { method: 'POST', body: JSON.stringify(input ?? {}) },
  )
  return res.run
}

/** Delivery history for a canvas (creation order). */
export async function fetchPlannerRuns(canvasId: string): Promise<WorkflowRun[]> {
  const res = await jsonRequest<{ runs: WorkflowRun[] }>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/deliveries`,
  )
  return res.runs
}

/** A single run's full execution state. */
export async function fetchPlannerRun(runId: string): Promise<WorkflowRun> {
  const res = await jsonRequest<{ run: WorkflowRun }>(
    `/api/planner/runs/${encodeURIComponent(runId)}`,
  )
  return res.run
}

/** Human-terminate a run. */
export async function abortPlannerRun(runId: string): Promise<WorkflowRun> {
  const res = await jsonRequest<{ run: WorkflowRun }>(
    `/api/planner/runs/${encodeURIComponent(runId)}/abort`,
    { method: 'POST', body: '{}' },
  )
  return res.run
}

export async function updatePlannerDeliveryNodeAssignee(
  canvasId: string,
  deliveryId: string,
  nodeId: string,
  assigneeId: string | null,
): Promise<WorkflowRun> {
  const res = await jsonRequest<{ run: WorkflowRun }>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/deliveries/${encodeURIComponent(deliveryId)}/nodes/${encodeURIComponent(nodeId)}/assignee`,
    { method: 'PATCH', body: JSON.stringify({ assigneeId }) },
  )
  return res.run
}

export function fetchPlannerNodeContract(
  canvasId: string,
  nodeId: string,
): Promise<PlannerNodeContract> {
  return jsonRequest<PlannerNodeContract>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/nodes/${encodeURIComponent(nodeId)}/contract`,
  )
}

export function submitPlannerNodeOutput(
  canvasId: string,
  nodeId: string,
  output: PlannerNodeOutput,
): Promise<PlannerNodeOutputResult> {
  return jsonRequest<PlannerNodeOutputResult>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/nodes/${encodeURIComponent(nodeId)}/output`,
    {
      method: 'POST',
      body: JSON.stringify(output),
    },
  )
}

export function getPlannerArtifactContent(
  canvasId: string,
  artifactId: string,
): Promise<PlannerArtifactContent> {
  return jsonRequest<PlannerArtifactContent>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/artifacts/${encodeURIComponent(artifactId)}/content`,
  )
}

// UI-1 (ENG-3) — version chain read API. The dropdown calls listArtifactVersions
// once per artifact slot; selecting a non-latest entry calls getArtifactVersion
// to fetch its full payload + input snapshot.
export function listArtifactVersions(
  canvasId: string,
  nodeId: string,
  reference: string,
): Promise<{ versions: PlannerArtifactVersion[] }> {
  return jsonRequest<{ versions: PlannerArtifactVersion[] }>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/nodes/${encodeURIComponent(nodeId)}/artifact-versions?reference=${encodeURIComponent(reference)}`,
  )
}

export function getArtifactVersion(
  canvasId: string,
  versionId: string,
): Promise<PlannerArtifactVersion> {
  return jsonRequest<PlannerArtifactVersion>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/artifact-versions/${encodeURIComponent(versionId)}`,
  )
}

// UI-1 — Re-run a node. The desktop takes the latest artifact for the node
// (or the slot pinned by `reference`) and resubmits with force_new_version=true,
// producing a fresh version row visible in the dropdown within one broadcast tick.
export function rerunPlannerNode(
  canvasId: string,
  nodeId: string,
  options?: { reference?: string },
): Promise<PlannerNodeOutputResult> {
  return jsonRequest<PlannerNodeOutputResult>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/nodes/${encodeURIComponent(nodeId)}/rerun`,
    {
      method: 'POST',
      body: JSON.stringify(options ?? {}),
    },
  )
}

export function attachPlannerArtifactToNode(
  canvasId: string,
  nodeId: string,
  input: {
    kind?: PlannerArtifactKind
    title?: string
    reference: string
    status?: string
    payload?: unknown
  },
): Promise<PlannerGraphState> {
  return jsonRequest<PlannerGraphState>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/nodes/${encodeURIComponent(nodeId)}/artifacts`,
    {
      method: 'POST',
      body: JSON.stringify(input),
    },
  )
}

export function updatePlannerNodeStatus(
  canvasId: string,
  nodeId: string,
  status: PlanningNodeStatus,
): Promise<PlannerGraphState> {
  return jsonRequest<PlannerGraphState>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/nodes/${encodeURIComponent(nodeId)}/status`,
    {
      method: 'PATCH',
      body: JSON.stringify({ status }),
    },
  )
}

export function updatePlannerNodeSchedule(
  canvasId: string,
  nodeId: string,
  input: { enabled: boolean; intervalSeconds?: number; prompt?: string },
): Promise<PlannerGraphState> {
  return jsonRequest<PlannerGraphState>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/nodes/${encodeURIComponent(nodeId)}/schedule`,
    {
      method: 'PATCH',
      body: JSON.stringify(input),
    },
  )
}

export function deletePlannerNode(
  canvasId: string,
  nodeId: string,
): Promise<PlannerGraphState> {
  if (PLANNER_DEMO_MODE) {
    const nodes = demoNodesByCanvasId[canvasId] ?? []
    demoNodesByCanvasId = {
      ...demoNodesByCanvasId,
      [canvasId]: nodes
        .filter((node) => node.id !== nodeId)
        .map((node) => ({
          ...node,
          dependsOnNodeIds: node.dependsOnNodeIds?.filter((dependencyId) => dependencyId !== nodeId),
        })),
    }
    return fetchPlannerGraphState(canvasId)
  }
  return jsonRequest<PlannerGraphState>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/nodes/${encodeURIComponent(nodeId)}`,
    { method: 'DELETE' },
  )
}

export function bindPlannerNodeInput(
  canvasId: string,
  nodeId: string,
  input: {
    input: string
    reference: string
    kind?: ContextSourceKind
    title?: string
  },
): Promise<PlannerGraphState> {
  return jsonRequest<PlannerGraphState>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/nodes/${encodeURIComponent(nodeId)}/inputs`,
    {
      method: 'PATCH',
      body: JSON.stringify(input),
    },
  )
}

/**
 * UI-2: Assign a node to a teammate. Server proxies to the SECURITY DEFINER
 * `meee2_assign_node` RPC (ENG-4). The call is atomic — on failure no
 * sub-canvas, no session re-bind, no event row is committed.
 *
 * If the source canvas was `private`, the server is expected to upgrade it
 * to `public` as part of the same transaction so the assignee can see it;
 * the returned `visibilityUpgraded` flag tells the UI whether the
 * private→public modal's promise was kept.
 */
export interface AssignPlannerNodeInput {
  /** Optional override for the new sub-canvas's display name. */
  subCanvasName?: string | null
  /**
   * Acknowledgement that the source canvas was private and the user accepted
   * the upgrade. Server refuses the call without it when the canvas is
   * private — protects against accidentally publishing a private board.
   */
  acceptPrivateUpgrade?: boolean
}
export function assignPlannerNode(
  canvasId: string,
  nodeId: string,
  assigneeUserId: string,
  input: AssignPlannerNodeInput = {},
): Promise<AssignPlannerNodeResult> {
  return jsonRequest<AssignPlannerNodeResult>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/nodes/${encodeURIComponent(nodeId)}/assign`,
    {
      method: 'POST',
      body: JSON.stringify({
        assigneeUserId,
        subCanvasName: input.subCanvasName ?? null,
        acceptPrivateUpgrade: input.acceptPrivateUpgrade === true,
      }),
    },
  )
}

/** UI-2: List sub-canvases the current user owns (proxy for `meee2_list_owned_canvases`). */
export function fetchOwnedCanvases(): Promise<{ canvases: OwnedCanvasSummary[] }> {
  return jsonRequest<{ canvases: OwnedCanvasSummary[] }>('/api/planner/owned-canvases')
}

export function openKanbanItemSubCanvas(
  canvasId: string,
  artifactId: string,
  itemId: string,
  input: { title?: string; scope?: CanvasScope; existingSubCanvasId?: string | null },
): Promise<{ subCanvasId: string; action: 'opened' | 'created' | 'replaced_missing'; message: string; graph: PlannerGraphState }> {
  return jsonRequest<{ subCanvasId: string; action: 'opened' | 'created' | 'replaced_missing'; message: string; graph: PlannerGraphState }>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/artifacts/${encodeURIComponent(artifactId)}/kanban-items/${encodeURIComponent(itemId)}/sub-canvas`,
    {
      method: 'POST',
      body: JSON.stringify(input),
    },
  )
}

// -- integrations (Phase 5: 真接入) ----------------------------------------
//
// Read-only browsing endpoints. The actual attach still goes through
// attachPlannerArtifactToNode above — these only let the user pick an item.

/** Demo fixtures, consistent with the PLANNER_DEMO_MODE pattern elsewhere. */
function demoGithubRepos(): ExternalItemsResult {
  return {
    provider: 'github',
    items: [
      {
        id: 'tianqixinxi/meee2',
        title: 'tianqixinxi/meee2',
        subtitle: 'private',
        reference: 'https://github.com/tianqixinxi/meee2',
        suggestedArtifactKind: 'generic',
      },
    ],
    notice: null,
  }
}

function demoGithubPulls(): ExternalItemsResult {
  return {
    provider: 'github',
    items: [
      {
        id: 'tianqixinxi/meee2#42',
        title: '#42 Add planner graph shell',
        subtitle: 'merged → main',
        reference: 'https://github.com/tianqixinxi/meee2/pull/42',
        suggestedArtifactKind: 'main-merge',
      },
      {
        id: 'tianqixinxi/meee2#48',
        title: '#48 Phase 5 integrations',
        subtitle: 'open → main',
        reference: 'https://github.com/tianqixinxi/meee2/pull/48',
        suggestedArtifactKind: 'impl-pr',
      },
    ],
    notice: null,
  }
}

function demoGithubIssues(): ExternalItemsResult {
  return {
    provider: 'github',
    items: [
      {
        id: 'tianqixinxi/meee2#7',
        title: '#7 Planner artifact picker',
        subtitle: 'open',
        reference: 'https://github.com/tianqixinxi/meee2/issues/7',
        suggestedArtifactKind: 'idea-draft',
      },
    ],
    notice: null,
  }
}

function demoLarkDocs(): ExternalItemsResult {
  return {
    provider: 'lark',
    items: [],
    notice: 'TODO(lark): doc search not wired yet. Contract is final; list is empty.',
  }
}

/** GET /api/integrations/status — per-integration connection status. */
/** GET /api/integrations/github/repos — repos the GitHub token can see. */
export function fetchGithubRepos(): Promise<ExternalItemsResult> {
  if (PLANNER_DEMO_MODE) return Promise.resolve(demoGithubRepos())
  return jsonRequest<ExternalItemsResult>('/api/integrations/github/repos')
}

/** GET /api/integrations/github/repos/:owner/:repo/pulls */
export function fetchGithubPulls(owner: string, repo: string): Promise<ExternalItemsResult> {
  if (PLANNER_DEMO_MODE) return Promise.resolve(demoGithubPulls())
  return jsonRequest<ExternalItemsResult>(
    `/api/integrations/github/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/pulls`,
  )
}

/** GET /api/integrations/github/repos/:owner/:repo/issues */
export function fetchGithubIssues(owner: string, repo: string): Promise<ExternalItemsResult> {
  if (PLANNER_DEMO_MODE) return Promise.resolve(demoGithubIssues())
  return jsonRequest<ExternalItemsResult>(
    `/api/integrations/github/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/issues`,
  )
}

/** GET /api/integrations/lark/docs — see TODO(lark) on the backend. */
export function fetchLarkDocs(): Promise<ExternalItemsResult> {
  if (PLANNER_DEMO_MODE) return Promise.resolve(demoLarkDocs())
  return jsonRequest<ExternalItemsResult>('/api/integrations/lark/docs')
}

// -- agent-integration-detection -------------------------------------------

/** GET /api/integrations/agent-scan — agent × integration detection matrix. */
export function fetchAgentScan(): Promise<AgentScanResult> {
  return jsonRequest<AgentScanResult>('/api/integrations/agent-scan')
}

/** GET /api/integrations/side-effects?canvasId= — per-node side effects. */
export function fetchCanvasSideEffects(canvasId: string): Promise<CanvasSideEffectsResult> {
  return jsonRequest<CanvasSideEffectsResult>(
    `/api/integrations/side-effects?canvasId=${encodeURIComponent(canvasId)}`,
  )
}

/** POST /api/integrations/:id/install — Pattern A one-click install. */
export function installIntegration(integrationId: string): Promise<IntegrationInstallResult> {
  return jsonRequest<IntegrationInstallResult>(
    `/api/integrations/${encodeURIComponent(integrationId)}/install`,
    { method: 'POST', body: '{}' },
  )
}

/** POST /api/integrations/:id/recommend-workflow —— planner agent 提议
 *  一份使用刚装好这个 integration 的小流程到 `canvasId`,产物是一条
 *  pending PlanProposal,会在 planner UI 的审批闸门里出现。 */
export async function recommendIntegrationWorkflow(
  integrationId: string,
  canvasId: string,
): Promise<PlanProposal | null> {
  const result = await jsonRequest<{ proposal: PlanProposal | null }>(
    `/api/integrations/${encodeURIComponent(integrationId)}/recommend-workflow`,
    { method: 'POST', body: JSON.stringify({ canvasId }) },
  )
  return result?.proposal ?? null
}

/** POST /api/integrations/:id/runbook — generate the connect runbook. */
export function generateIntegrationRunbook(integrationId: string): Promise<IntegrationRunbookResult> {
  return jsonRequest<IntegrationRunbookResult>(
    `/api/integrations/${encodeURIComponent(integrationId)}/runbook`,
    { method: 'POST', body: '{}' },
  )
}

/** POST /api/integrations/:id/complete-auth — one-click OAuth: kick off the
 *  `mcp-remote` shim against the integration's URL, which opens the browser
 *  for the user to authorize and caches the token to `~/.mcp-auth/`. After
 *  that, both Claude Code and Codex pick up the token transparently. */
export interface CompleteAuthResult {
  integrationId: string
  spawned: boolean
  /** The MCP server URL (e.g. https://mcp.clickhouse.cloud/mcp). */
  url: string
  /** OAuth URL extracted from the spawned shim's log. Open this if the
   *  browser didn't pop automatically. Null when extraction timed out. */
  authUrl: string | null
  logPath: string
  message: string
}

export function completeIntegrationAuth(integrationId: string): Promise<CompleteAuthResult> {
  return jsonRequest<CompleteAuthResult>(
    `/api/integrations/${encodeURIComponent(integrationId)}/complete-auth`,
    { method: 'POST', body: '{}' },
  )
}

export async function createPlannerSubCanvasFromNode(
  canvasId: string,
  nodeId: string,
  title?: string,
): Promise<PlanProposal | null> {
  const response = await jsonRequest<{ proposal: PlanProposal | null }>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/nodes/${encodeURIComponent(nodeId)}/sub-canvas`,
    {
      method: 'POST',
      body: JSON.stringify({ title }),
    },
  )
  return response.proposal
}

/**
 * PATCH …/canvases/:id/visibility — owner-only public/private toggle. This is
 * canvas metadata, not a graph proposal, so it applies immediately and returns
 * the updated canvas record.
 */
export async function setPlannerCanvasVisibility(
  canvasId: string,
  visibility: PlannerCanvasVisibility,
): Promise<PlanningCanvas> {
  if (PLANNER_DEMO_MODE) {
    return Promise.resolve({
      id: canvasId,
      ownerId: DEMO_OWNER_ID,
      title: demoCanvasRecords[canvasId]?.name ?? 'meee2 AI Demo',
      plannerContext: `canvas:${canvasId}`,
      visibility,
    })
  }
  const response = await jsonRequest<{ canvas: PlanningCanvas }>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/visibility`,
    {
      method: 'PATCH',
      body: JSON.stringify({ visibility }),
    },
  )
  return response.canvas
}

export async function setPlannerCanvasDescription(
  canvasId: string,
  description: string,
): Promise<PlanningCanvas> {
  if (PLANNER_DEMO_MODE) {
    return Promise.resolve({
      id: canvasId,
      ownerId: DEMO_OWNER_ID,
      title: demoCanvasRecords[canvasId]?.name ?? 'meee2 AI Demo',
      plannerContext: description.trim() || `canvas:${canvasId}`,
      visibility: demoCanvasRecords[canvasId]?.scope === 'team' ? 'public' : 'private',
    })
  }
  const response = await jsonRequest<{ canvas: PlanningCanvas }>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/description`,
    {
      method: 'PATCH',
      body: JSON.stringify({ description }),
    },
  )
  return response.canvas
}

export function updatePlannerNodeLayout(
  canvasId: string,
  nodeId: string,
  layout: PlannerNodeLayout,
): Promise<PlannerGraphState> {
  return jsonRequest<PlannerGraphState>(
    `/api/planner/canvases/${encodeURIComponent(canvasId)}/nodes/${encodeURIComponent(nodeId)}/layout`,
    {
      method: 'PATCH',
      body: JSON.stringify(layout),
    },
  )
}

export interface UserProfile {
  connected: boolean
  userId: string
  displayName: string
  userName: string
  userEmail: string
  userAvatarUrl: string
  initials: string
  dashboardUrl: string
  connectUrl: string
  defaultSyncEnabled: boolean
  defaultSyncTeamId: string
  defaultSyncTeamName: string
  teams: Array<{
    id: string
    name: string
    role: string | null
    isDefault: boolean
  }>
  sessionSync: Array<{
    sessionId: string
    title: string
    pluginDisplayName: string
    project: string
    enabled: boolean
  }>
}

export function fetchUserProfile(): Promise<UserProfile> {
  if (PLANNER_DEMO_MODE) {
    return Promise.resolve({
      connected: false,
      userId: DEMO_OWNER_ID,
      displayName: 'Demo User',
      userName: 'demo',
      userEmail: '',
      userAvatarUrl: '',
      initials: 'DU',
      dashboardUrl: '',
      connectUrl: '',
      defaultSyncEnabled: false,
      defaultSyncTeamId: '',
      defaultSyncTeamName: '',
      teams: [],
      sessionSync: [],
    })
  }
  return jsonRequest<UserProfile>('/api/user-profile')
}

/** One identity in the team member directory, keyed by `userId`. */
export interface TeamMember {
  userId: string
  displayName: string
  avatarUrl?: string | null
  /** Team-level membership role, or null when known only from local signals. */
  role?: string | null
}

/**
 * Authoritative team member directory for the planner graph. The graph keys
 * avatar / displayName lookups by `userId` from this source.
 */
export function fetchTeamMembers(): Promise<{ members: TeamMember[] }> {
  if (PLANNER_DEMO_MODE) {
    return Promise.resolve({
      members: [
        {
          userId: DEMO_OWNER_ID,
          displayName: 'Demo Owner',
          avatarUrl: null,
          role: 'owner',
        },
        {
          userId: 'demo-doer-anna',
          displayName: 'Anna Doer',
          avatarUrl: null,
          role: 'member',
        },
        {
          userId: 'demo-doer-ben',
          displayName: 'Ben Builder',
          avatarUrl: null,
          role: 'member',
        },
      ],
    })
  }
  return jsonRequest<{ members: TeamMember[] }>('/api/team/members')
}

export function openMeee2OnlineConnect(): Promise<{ ok: boolean }> {
  return jsonRequest<{ ok: boolean }>('/api/user-profile/connect', { method: 'POST' })
}

export function openMeee2OnlineDashboard(): Promise<{ ok: boolean }> {
  return jsonRequest<{ ok: boolean }>('/api/user-profile/dashboard', { method: 'POST' })
}

export function openMeee2Settings(): Promise<{ ok: boolean }> {
  return jsonRequest<{ ok: boolean }>('/api/user-profile/settings', { method: 'POST' })
}

export function updateUserProfile(input: {
  defaultSyncEnabled?: boolean
  sessionSync?: { sessionId: string; enabled: boolean }
}): Promise<UserProfile> {
  return jsonRequest<UserProfile>('/api/user-profile', {
    method: 'PATCH',
    body: JSON.stringify(input),
  })
}

export function disconnectMeee2Online(): Promise<{ ok: boolean }> {
  return jsonRequest<{ ok: boolean }>('/api/user-profile', { method: 'DELETE' })
}

export interface AppSettings {
  theme: 'system' | 'light' | 'dark'
  locale: 'en' | 'zh-CN'
  devMode?: boolean
  showIsland: boolean
  selectedScreenId: string
  availableScreens: Array<{
    id: string
    name: string
    hasNotch: boolean
  }>
  autoExpandEnabled: boolean
  autoCloseInterval: number
  showSessionInCompact: boolean
  carouselInterval: number
}

export type AppSettingsPatch = Partial<Omit<AppSettings, 'availableScreens'>>

export function fetchAppSettings(): Promise<AppSettings> {
  if (PLANNER_DEMO_MODE) {
    return Promise.resolve({
      theme: 'system',
      locale: 'en',
      devMode: true,
      showIsland: true,
      selectedScreenId: 'builtin',
      availableScreens: [{ id: 'builtin', name: 'Built-in Display', hasNotch: true }],
      autoExpandEnabled: true,
      autoCloseInterval: 8,
      showSessionInCompact: true,
      carouselInterval: 10,
    })
  }
  return jsonRequest<AppSettings>('/api/app-settings')
}

export function updateAppSettings(input: AppSettingsPatch): Promise<AppSettings> {
  return jsonRequest<AppSettings>('/api/app-settings', {
    method: 'PATCH',
    body: JSON.stringify(input),
  })
}

// -- whoami (system user running meee2) ------------------------------------

export interface WhoamiInfo {
  username: string
  fullName: string
  hostname: string
}

export function fetchWhoami(): Promise<WhoamiInfo> {
  return jsonRequest<WhoamiInfo>('/api/whoami')
}

// -- automations -----------------------------------------------------------

export interface AutomationTemplate {
  id: string
  product: 'meee2' | string
  category: string
  icon: string
  title: string
  description: string
  prompt: string
  cadence: string
}

export interface AutomationDefinition {
  id: string
  title: string
  description: string
  prompt: string
  cadence: string
  scope: string
  templateId: string | null
  enabled: boolean
  createdAt: string
  updatedAt: string
  lastRunAt: string | null
  lastRunStatus: 'succeeded' | 'failed' | string | null
  lastRunSummary: string | null
}

export interface AutomationRun {
  id: string
  automationId: string
  status: 'succeeded' | 'failed' | string
  output: string
  error: string | null
  startedAt: string
  finishedAt: string
}

export async function fetchAutomations(): Promise<{
  templates: AutomationTemplate[]
  automations: AutomationDefinition[]
}> {
  return jsonRequest('/api/automations')
}

export async function createAutomation(input: {
  title?: string
  description?: string
  prompt?: string
  cadence?: string
  scope?: string
  templateId?: string
  enabled?: boolean
}): Promise<AutomationDefinition> {
  const response = await jsonRequest<{ automation: AutomationDefinition }>('/api/automations', {
    method: 'POST',
    body: JSON.stringify(input),
  })
  return response.automation
}

export async function deleteAutomation(id: string): Promise<void> {
  await jsonRequest<{ ok: boolean }>(`/api/automations/${encodeURIComponent(id)}`, {
    method: 'DELETE',
  })
}

export async function runAutomation(id: string): Promise<{
  automation: AutomationDefinition
  run: AutomationRun
}> {
  return jsonRequest(`/api/automations/${encodeURIComponent(id)}/run`, {
    method: 'POST',
    body: JSON.stringify({ settings: { provider: 'local' } }),
  })
}

// -- app version / Sparkle update ------------------------------------------

export interface VersionInfo {
  current: string
  latest: string | null
  hasUpdate: boolean
  isChecking: boolean
  lastError: string | null
  /// codex-style 信号:Sparkle 后台已经下完 + verify + stage,点 pill 就秒
  /// 重启,不再下载。生产 UI 只在 isStaged=true 时渲染 Update pill。
  isStaged: boolean
  /// 当前 staged 包的版本号(showUpdateFound 时 Sparkle 给的)。dev e2e
  /// 测试"staged 过时"场景时对比 latest != stagedVersion。
  stagedVersion: string | null
}

export function fetchVersion(): Promise<VersionInfo> {
  return jsonRequest<VersionInfo>('/api/version')
}

/// 强制刷一遍 appcast(后端会重新拉 raw.githubusercontent),返回最新 cache。
export function checkForVersionUpdate(): Promise<VersionInfo> {
  return jsonRequest<VersionInfo>('/api/version/check', { method: 'POST' })
}

/// 触发 Sparkle 安装流程。如果 SUAutomaticallyUpdate=YES 且后台已下载 + 验签
/// 完成,Sparkle 会跳过下载步直接弹 "Install and Relaunch" 一键确认框,
/// 用户点一下立刻 apply + relaunch。
export function installAppUpdate(): Promise<{ ok: boolean }> {
  return jsonRequest<{ ok: boolean }>('/api/update/install', { method: 'POST' })
}

/// 让 Sparkle 在后台 silent 走完整 cycle:fetch appcast → 下载 DMG → 验签 →
/// stage 到本地。无 UI。dev 测试 codex-style 预下载体验时,先调这个等几秒
/// 让 Sparkle 把包下好,再调 installAppUpdate() 才能体验"立刻 Install and Relaunch"。
export function checkUpdateInBackground(): Promise<{ ok: boolean }> {
  return jsonRequest<{ ok: boolean }>('/api/update/check-in-background', { method: 'POST' })
}

/// **DEV-ONLY** 后门:override VersionChecker.shared.latestVersion 假造"远端
/// 出了更新版"场景。`version=null` / 不传 → 清掉 override(下次 background
/// check 拉到的真实 latest 会接管)。
export function devOverrideLatest(version: string | null): Promise<{ ok: boolean }> {
  const qs = version ? `?version=${encodeURIComponent(version)}` : ''
  return jsonRequest<{ ok: boolean }>(`/api/_dev/override-latest${qs}`, { method: 'POST' })
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

/**
 * Rename a channel's display label. The canonical id (`name`) stays put —
 * passing `null` or empty string clears `displayName` and the UI falls back
 * to showing the canonical name. See issue #24.
 */
export async function renameChannel(
  name: string,
  displayName: string | null,
): Promise<Channel> {
  const r = await jsonRequest<{ channel: Channel }>(
    `/api/channels/${encodeURIComponent(name)}/rename`,
    {
      method: 'POST',
      body: JSON.stringify({ displayName }),
    },
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
 * Spawn 一个新 CLI session。默认创建 meee2 内置终端；传
 * `terminalMode: "external"` 时保留旧的外部终端行为。
 */
export async function spawnSession(input: {
  cwd: string
  command?: string
  createIfMissing?: boolean
  termProgram?: string
  terminalMode?: 'internal' | 'external'
}): Promise<{ ok: boolean; cwd: string; command: string; sessionId?: string; surfaceId?: string; terminalKind?: string }> {
  return jsonRequest<{ ok: boolean; cwd: string; command: string; sessionId?: string; surfaceId?: string; terminalKind?: string }>(
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
  scope?: string
  canvasId?: string
  workspacePath?: string
  canvasName?: string
  selectedElements?: SelectedCanvasElementContext[]
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

export interface LocalAssistantSessionMessage {
  id: string
  role: 'user' | 'assistant' | 'injected'
  content: string
  timestamp?: string | null
}

export async function fetchLocalAssistantSessionMessages(
  canvasId: string,
  limit = 80,
): Promise<{ sessionId: string; messages: LocalAssistantSessionMessage[] }> {
  const params = new URLSearchParams()
  if (canvasId) params.set('canvasId', canvasId)
  params.set('limit', String(limit))
  return jsonRequest(`/api/assistant/local-session/messages?${params.toString()}`)
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
 * Explicit "Push to Desktop" —— 只对 Desktop session 有意义。
 *
 * 把 content（如有）写进 inbox，然后立刻通过 AppleScript keystroke 把
 * inbox 里所有 pending 消息注入 Claude.app 当前 focused 输入框。会让
 * Claude.app 跳到前台 → 切到目标 session → 自动键入 → 自动回车 → 产生
 * 真 user entry 进 transcript。
 *
 * 用户主动触发（webui Dock 的 ⚡ 按钮）—— 默认 send path 不走这条避免
 * 抢焦点。
 *
 * 失败模式（返回 `error` 字段非空）：
 *   - meee2 没 Accessibility 权限 → System Settings → Privacy & Security →
 *     Accessibility 里给 meee2 勾上
 *   - Claude.app 没在跑
 *   - session 不是 Desktop（API 端 400）
 *
 * 服务端最多阻塞 15s 等 keystroke 完成。`delivered` 是成功推送的条数。
 */
export interface PushNowResult {
  delivered: number
  message: Message | null
  error: string | null
  /** Server-routed error category: `accessibility_denied` /
   *  `claude_not_running` / `keystroke_failed` / null. WebUI uses this to
   *  decide whether to offer "Open Settings" affordance vs plain toast. */
  errorCode:
    | 'accessibility_denied'
    | 'claude_not_running'
    | 'keystroke_failed'
    | null
}

export async function pushToDesktopNow(
  id: string,
  content: string,
): Promise<PushNowResult> {
  const r = await jsonRequest<{
    delivered?: number
    message?: Message | null
    error?: string | null
    errorCode?: string | null
  }>(
    `/api/sessions/${encodeURIComponent(id)}/push-now`,
    {
      method: 'POST',
      body: JSON.stringify({ content }),
    },
  )
  const code = r.errorCode
  const errorCode =
    code === 'accessibility_denied' ||
    code === 'claude_not_running' ||
    code === 'keystroke_failed'
      ? code
      : null
  return {
    delivered: r.delivered ?? 0,
    message: r.message ?? null,
    error: r.error ?? null,
    errorCode,
  }
}

/// 让用户跳到 macOS System Settings → Privacy & Security → Accessibility，
/// 给 meee2 授权 keystroke。配合 push-now 失败时 errorCode='accessibility_denied'
/// 的 toast 一起用。
export async function openAccessibilitySettings(): Promise<void> {
  await jsonRequest('/api/system/open-accessibility-settings', { method: 'POST' })
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
  // console.log('[activateSession] POST /api/sessions/' + id.slice(0, 8) + '/activate')
  try {
    const response = await jsonRequest<{ ok: boolean; terminalKind?: string; surfaceId?: string; sessionId?: string }>(
      `/api/sessions/${encodeURIComponent(id)}/activate`,
      { method: 'POST' },
    )
    if (response.terminalKind === 'internal' && response.surfaceId) {
      window.dispatchEvent(new CustomEvent('meee2:open-session', {
        detail: {
          sessionId: response.sessionId ?? id,
          surfaceId: response.surfaceId,
        },
      }))
    }
    // console.log('[activateSession] OK for', id.slice(0, 8))
    return true
  } catch (e) {
    console.error('[activateSession] FAILED for', id.slice(0, 8), e)
    return false
  }
}

/** Result shape from `closeSession`. Caller decides whether to surface
 *  success / "already dead" / failure differently in the UI. */
export interface CloseSessionResult {
  ok: boolean
  alreadyDead?: boolean
  errorCode?: string
  error?: string
}

/**
 * DELETE /api/sessions/:id —— SIGTERM the underlying process and drop the
 * session record. The backend rejects sessions that have no controllable pid
 * (Desktop / Cowork / external chat) with `errorCode === 'no_pid'` so the
 * caller can tell the user to close it manually in its host app.
 */
export async function closeSession(id: string): Promise<CloseSessionResult> {
  try {
    const r = await jsonRequest<{ ok: boolean; alreadyDead: boolean }>(
      `/api/sessions/${encodeURIComponent(id)}`,
      { method: 'DELETE' },
    )
    return { ok: true, alreadyDead: r.alreadyDead }
  } catch (e) {
    if (e instanceof ApiRequestError) {
      return { ok: false, errorCode: e.code, error: e.message }
    }
    return { ok: false, errorCode: 'unknown', error: (e as Error).message ?? String(e) }
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
    ws.onopen = () => {
      // issue #25 诊断：记录每一次 (re)connect。Board flash 时如果紧跟一次
      // 'reconnected'，说明是断线触发的初始 fetch 撞上了 server 半态。
      // console.log('[StateTrace][board-ws] reconnected')
      onStatus(true)
    }
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
      // console.log('[StateTrace][board-ws] disconnected')
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

// -- UI-6 · AI Recap · ENG-3 artifact version stream -----------------------

/**
 * One row from `meee2_artifact_versions` (or its `_latest` view), shaped for
 * the AI Recap drawer. Mirrors the read schema of meee2-online's
 * `GET /api/v1/artifact-versions` (see ENG-3).
 */
export interface ArtifactVersionSummary {
  versionId: string
  parentVersionId: string | null
  nodeId: string
  nodeTitle: string | null
  artifactSlotKey: string
  submittedByLabel: string
  shortId: string
  createdAt: string
}

interface FetchRecentArtifactVersionsArgs {
  teamId: string
  canvasId: string
  /** Lookback window in ms. The endpoint returns newest-first; we filter client-side. */
  windowMs: number
}

/**
 * Fetches recent artifact versions for the AI Recap drawer.
 *
 * Routing strategy:
 *   1. Try the local BoardServer proxy at `/api/cloud/artifact-versions/recent`.
 *      This proxy is intentionally *not implemented yet* — see TODO below.
 *      Until it exists this resolves to an empty list (caller renders the
 *      "no recent versions" empty state, drawer otherwise functions).
 *   2. (Future) Once supabase-js is bundled into board-app, the drawer will
 *      open a Realtime channel directly and this polling helper goes away.
 *
 * TODO(UI-6 follow-up): expose `GET /api/cloud/artifact-versions/recent`
 *   on BoardServer that forwards to meee2-online's
 *   `GET /api/v1/artifact-versions` using the connect token stored in
 *   `~/.meee2/settings.json`. The handler should aggregate across all nodes
 *   in the canvas (the upstream endpoint is per-slot).
 */
export async function fetchRecentArtifactVersions(
  args: FetchRecentArtifactVersionsArgs,
): Promise<ArtifactVersionSummary[]> {
  if (PLANNER_DEMO_MODE) return []
  const params = new URLSearchParams({
    teamId: args.teamId,
    canvasId: args.canvasId,
    windowMs: String(args.windowMs),
  })
  try {
    const data = await jsonRequest<{ versions?: ArtifactVersionSummary[] }>(
      `/api/cloud/artifact-versions/recent?${params.toString()}`,
    )
    return data.versions ?? []
  } catch (err) {
    // The proxy endpoint is not wired yet. Surface a friendly empty list
    // unless this is a transient error we should re-throw.
    if (err instanceof ApiRequestError && (err.status === 404 || err.status === 501)) {
      return []
    }
    throw err
  }
}
