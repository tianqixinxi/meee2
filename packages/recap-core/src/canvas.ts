import { stableRecapFingerprint } from './fingerprint'
import type {
  CanvasRecap,
  CanvasStatusRecap,
  EvidenceRef,
  RecapApproval,
  RecapBlocker,
  RecapInput,
  RecapStatusCount,
  RecapTemplatePolicy,
} from './types'

export const DEFAULT_RECAP_TEMPLATE_POLICY: RecapTemplatePolicy = {
  id: 'default-monitor',
  label: 'Default monitor',
  statusStrategy: 'monitor',
  doneRequiresEvidence: false,
  surfaceApprovals: true,
  surfaceBlocked: true,
  surfaceSubCanvasRollups: true,
  maxSessionRecaps: 6,
  maxEvidenceRefs: 12,
}

export interface CanvasStatusRecapState {
  canvas?: {
    plannerContext?: string | null
  } | null
  nodes?: Array<{
    status?: string | null
    workflowRunState?: string | null
    blockedReason?: string | null
    schedule?: { enabled?: boolean | null } | null
  }> | null
  artifacts?: unknown[] | null
}

export function buildCanvasStatusRecap(state: CanvasStatusRecapState, now = new Date()): CanvasStatusRecap {
  const nodes = state.nodes ?? []
  const artifacts = state.artifacts ?? []
  const ready = nodes.filter((node) => node.status === 'ready')
  const working = nodes.filter((node) => node.status === 'working' || node.workflowRunState === 'running')
  const blocked = nodes.filter((node) => node.status === 'blocked' || node.workflowRunState === 'failed' || node.blockedReason)
  const done = nodes.filter((node) => node.status === 'done')
  const scheduled = nodes.filter((node) => node.schedule?.enabled)
  const description = editableCanvasDescription(state.canvas?.plannerContext)

  return {
    description,
    headline: 'Generating AI recap...',
    statuses: [
      { label: 'Ready', value: ready.length, tone: 'ready' },
      { label: 'Running', value: working.length, tone: 'running' },
      { label: 'Attention', value: blocked.length, tone: 'attention' },
      { label: 'Done', value: done.length, tone: 'done' },
      { label: 'Artifacts', value: artifacts.length, tone: 'neutral' },
      { label: 'Scheduled', value: scheduled.length, tone: 'neutral' },
    ],
    details: [],
    updatedAt: now.toISOString(),
  }
}

export function buildCanvasRecap(input: RecapInput): CanvasRecap {
  const policy = input.template ?? DEFAULT_RECAP_TEMPLATE_POLICY
  const fingerprint = stableRecapFingerprint(recapFingerprintPayload(input, policy))
  const statusCounts = buildStatusCounts(input)
  const blockers = policy.surfaceBlocked ? extractBlockers(input) : []
  const approvals = policy.surfaceApprovals ? extractApprovals(input) : []
  const evidenceRefs = collectEvidenceRefs(input, policy.maxEvidenceRefs)
  const sessionRefs = unique([
    ...input.sessions.map((session) => session.id),
    ...input.nodes.flatMap((node) => node.sessionId ? [node.sessionId] : []),
  ])
  const subCanvasRefs = unique([
    ...input.subCanvases.map((canvas) => canvas.id),
    ...input.nodes.flatMap((node) => node.subCanvasId ? [node.subCanvasId] : []),
  ])

  return {
    scope: 'canvas',
    canvasId: input.canvas.id,
    headline: deterministicHeadline(statusCounts, blockers, approvals),
    details: deterministicDetails(input, blockers, approvals, evidenceRefs),
    statusCounts,
    blockers,
    approvals,
    evidenceRefs,
    sessionRefs,
    subCanvasRefs,
    source: {
      kind: 'deterministic',
      generatedFrom: ['canvas', 'nodes', 'sessions', 'artifacts', 'events', 'proposals', 'subCanvases'],
    },
    updatedAt: input.now,
    fingerprint,
    stale: false,
  }
}

export function buildEmptyCanvasRecap(
  headline = 'Generating AI recap...',
  now = new Date(),
): CanvasStatusRecap {
  return {
    description: '',
    headline,
    statuses: [
      { label: 'Ready', value: 0, tone: 'ready' },
      { label: 'Running', value: 0, tone: 'running' },
      { label: 'Attention', value: 0, tone: 'attention' },
      { label: 'Done', value: 0, tone: 'done' },
      { label: 'Artifacts', value: 0, tone: 'neutral' },
      { label: 'Scheduled', value: 0, tone: 'neutral' },
    ],
    details: [],
    updatedAt: now.toISOString(),
  }
}

export function editableCanvasDescription(value: string | null | undefined): string {
  const trimmed = value?.trim() ?? ''
  if (trimmed && !/^canvas:/i.test(trimmed)) return trimmed
  return ''
}

export function formatRecapAge(updatedAt: string, nowMs: number): string {
  const updatedMs = Date.parse(updatedAt)
  if (Number.isNaN(updatedMs)) return ''
  const elapsedSeconds = Math.max(0, Math.floor((nowMs - updatedMs) / 1000))
  if (elapsedSeconds < 60) return '刚刚'
  const elapsedMinutes = Math.floor(elapsedSeconds / 60)
  if (elapsedMinutes < 60) return `${elapsedMinutes}m前`
  const elapsedHours = Math.floor(elapsedMinutes / 60)
  if (elapsedHours < 24) return `${elapsedHours}h前`
  return `${Math.floor(elapsedHours / 24)}d前`
}

function buildStatusCounts(input: RecapInput): RecapStatusCount[] {
  const nodes = input.nodes
  const ready = nodes.filter((node) => node.status === 'ready')
  const running = nodes.filter((node) => node.status === 'working' || node.workflowRunState === 'running')
  const approvals = extractApprovals(input)
  const attention = extractBlockers(input)
  const done = nodes.filter((node) => node.status === 'done' || node.workflowRunState === 'done')
  const failed = nodes.filter((node) => node.workflowRunState === 'failed')

  return [
    { label: 'Ready', value: ready.length, tone: 'ready' },
    { label: 'Running', value: running.length, tone: 'running' },
    { label: 'Approval', value: approvals.length, tone: 'approval' },
    { label: 'Attention', value: attention.length, tone: 'attention' },
    { label: 'Done', value: done.length, tone: 'done' },
    { label: 'Failed', value: failed.length, tone: 'failed' },
    { label: 'Artifacts', value: input.artifacts.length, tone: 'neutral' },
  ]
}

function extractBlockers(input: RecapInput): RecapBlocker[] {
  const nodeBlockers = input.nodes
    .filter((node) => node.status === 'blocked' || node.workflowRunState === 'failed' || node.blockedReason)
    .map((node): RecapBlocker => ({
      subjectId: node.id,
      subjectKind: 'node',
      title: node.title,
      reason: node.blockedReason ?? (node.workflowRunState === 'failed' ? 'workflow run failed' : 'node is blocked'),
      evidenceRefs: evidenceForSubject(input.artifacts, { nodeId: node.id }),
    }))

  const sessionBlockers = input.sessions
    .filter((session) => session.status === 'dead' || session.status === 'failed')
    .map((session): RecapBlocker => ({
      subjectId: session.id,
      subjectKind: 'session',
      title: session.title,
      reason: session.status === 'dead' ? 'session is dead' : 'session failed',
      evidenceRefs: evidenceForSubject(input.artifacts, { sessionId: session.id }),
    }))

  const subCanvasBlockers = input.subCanvases.flatMap((canvas): RecapBlocker[] => (
    canvas.recap?.blockers.map((blocker) => ({
      ...blocker,
      subjectKind: 'canvas' as const,
      subjectId: canvas.id,
      title: `${canvas.title}: ${blocker.title}`,
    })) ?? []
  ))

  return [...nodeBlockers, ...sessionBlockers, ...subCanvasBlockers]
}

function extractApprovals(input: RecapInput): RecapApproval[] {
  const sessionApprovals = input.sessions
    .filter((session) => session.status === 'permissionRequired' || session.pendingPermissionTool || session.pendingPermissionMessage)
    .map((session): RecapApproval => ({
      subjectId: session.id,
      subjectKind: 'session',
      title: session.pendingPermissionTool
        ? `${session.title}: ${session.pendingPermissionTool}`
        : session.title,
      requestedBy: session.provider,
      evidenceRefs: evidenceForSubject(input.artifacts, { sessionId: session.id }),
    }))

  const gateApprovals = input.nodes
    .filter((node) => node.workflowRunState === 'gate-wait')
    .map((node): RecapApproval => ({
      subjectId: node.id,
      subjectKind: 'gate',
      title: node.title,
      evidenceRefs: evidenceForSubject(input.artifacts, { nodeId: node.id }),
    }))

  const proposalApprovals = input.proposals
    .filter((proposal) => proposal.status === 'pending')
    .map((proposal): RecapApproval => ({
      subjectId: proposal.id,
      subjectKind: 'proposal',
      title: proposal.summary,
      evidenceRefs: [],
    }))

  const subCanvasApprovals = input.subCanvases.flatMap((canvas): RecapApproval[] => (
    canvas.recap?.approvals.map((approval) => ({
      ...approval,
      subjectKind: 'gate' as const,
      subjectId: canvas.id,
      title: `${canvas.title}: ${approval.title}`,
    })) ?? []
  ))

  return [...sessionApprovals, ...gateApprovals, ...proposalApprovals, ...subCanvasApprovals]
}

function collectEvidenceRefs(input: RecapInput, maxRefs: number): EvidenceRef[] {
  const refs = [
    ...input.artifacts,
    ...input.events.map((event): EvidenceRef => ({
      id: event.id,
      kind: 'event',
      title: event.summary,
      reference: event.id,
      createdAt: event.createdAt,
      nodeId: event.nodeId ?? undefined,
    })),
  ]
  return uniqueById(refs)
    .sort((a, b) => Date.parse(b.createdAt ?? '') - Date.parse(a.createdAt ?? ''))
    .slice(0, Math.max(0, maxRefs))
}

function deterministicHeadline(
  statusCounts: RecapStatusCount[],
  blockers: RecapBlocker[],
  approvals: RecapApproval[],
): string {
  const running = statusCounts.find((item) => item.tone === 'running')?.value ?? 0
  const done = statusCounts.find((item) => item.tone === 'done')?.value ?? 0

  if (approvals.length > 0) return `有 ${approvals.length} 个审批需要处理`
  if (blockers.length > 0) return `有 ${blockers.length} 个阻塞需要处理`
  if (running > 0) return `${running} 个节点正在推进`
  if (done > 0) return `${done} 个节点已完成`
  return '画板暂无活跃事项'
}

function deterministicDetails(
  input: RecapInput,
  blockers: RecapBlocker[],
  approvals: RecapApproval[],
  evidenceRefs: EvidenceRef[],
): string[] {
  const details: string[] = []
  for (const approval of approvals.slice(0, 2)) {
    details.push(`待审批：${approval.title}`)
  }
  for (const blocker of blockers.slice(0, Math.max(0, 3 - details.length))) {
    details.push(`阻塞：${blocker.title} - ${blocker.reason}`)
  }
  if (details.length < 4 && evidenceRefs.length > 0) {
    details.push(`最近证据：${evidenceRefs[0].title}`)
  }
  if (details.length < 4) {
    const running = input.nodes.find((node) => node.status === 'working' || node.workflowRunState === 'running')
    if (running) details.push(`进行中：${running.title}`)
  }
  return details.slice(0, 4)
}

function evidenceForSubject(
  evidenceRefs: EvidenceRef[],
  subject: { nodeId?: string; sessionId?: string },
): EvidenceRef[] {
  return evidenceRefs.filter((ref) => {
    if (subject.nodeId && ref.nodeId === subject.nodeId) return true
    if (subject.sessionId && ref.sessionId === subject.sessionId) return true
    return false
  })
}

function recapFingerprintPayload(input: RecapInput, policy: RecapTemplatePolicy): unknown {
  return {
    canvas: input.canvas,
    policy: policy.id,
    nodes: input.nodes.map((node) => ({
      id: node.id,
      title: node.title,
      status: node.status,
      workflowRunState: node.workflowRunState,
      blockedReason: node.blockedReason,
      sessionId: node.sessionId,
      subCanvasId: node.subCanvasId,
      artifactRefs: node.artifactRefs,
    })),
    sessions: input.sessions.map((session) => ({
      id: session.id,
      title: session.title,
      provider: session.provider,
      status: session.status,
      currentTask: session.currentTask,
      pendingPermissionTool: session.pendingPermissionTool,
      pendingPermissionMessage: session.pendingPermissionMessage,
      latestRecapFingerprint: session.latestRecap?.fingerprint,
    })),
    artifacts: input.artifacts.map((artifact) => ({
      id: artifact.id,
      kind: artifact.kind,
      title: artifact.title,
      reference: artifact.reference,
      createdAt: artifact.createdAt,
      nodeId: artifact.nodeId,
      sessionId: artifact.sessionId,
    })),
    events: input.events.map((event) => ({
      id: event.id,
      type: event.type,
      summary: event.summary,
      createdAt: event.createdAt,
      nodeId: event.nodeId,
      artifactRefs: event.artifactRefs,
    })),
    proposals: input.proposals.map((proposal) => ({
      id: proposal.id,
      status: proposal.status,
      summary: proposal.summary,
      changeCount: proposal.changeCount,
    })),
    subCanvases: input.subCanvases.map((canvas) => ({
      id: canvas.id,
      title: canvas.title,
      recapFingerprint: canvas.recap?.fingerprint,
    })),
  }
}

function unique(values: string[]): string[] {
  return [...new Set(values)]
}

function uniqueById<T extends { id: string }>(values: T[]): T[] {
  const seen = new Set<string>()
  const result: T[] = []
  for (const value of values) {
    if (seen.has(value.id)) continue
    seen.add(value.id)
    result.push(value)
  }
  return result
}
