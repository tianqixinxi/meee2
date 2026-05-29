import { stableRecapFingerprint } from './fingerprint'
import type {
  CanvasRecap,
  CanvasStatusRecap,
  EvidenceRef,
  RecapApproval,
  RecapAwaiting,
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
  const blockers = policy.surfaceBlocked ? extractBlockers(input, policy) : []
  const approvals = policy.surfaceApprovals ? extractApprovals(input, policy) : []
  const awaitingItems = extractAwaitings(input)
  const statusCounts = buildStatusCounts(input, { blockers, approvals })
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
    details: deterministicDetails(input, blockers, approvals, awaitingItems, evidenceRefs),
    statusCounts,
    blockers,
    approvals,
    awaitingItems,
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
  if (elapsedMinutes < 60) return `${elapsedMinutes} 分钟前`
  const elapsedHours = Math.floor(elapsedMinutes / 60)
  if (elapsedHours < 24) return `${elapsedHours} 小时前`
  return `${Math.floor(elapsedHours / 24)} 天前`
}

function buildStatusCounts(
  input: RecapInput,
  surfaced: { blockers: RecapBlocker[]; approvals: RecapApproval[] },
): RecapStatusCount[] {
  const nodes = input.nodes
  const ready = nodes.filter((node) => node.status === 'ready')
  const running = nodes.filter((node) => node.status === 'working' || node.workflowRunState === 'running')
  const done = nodes.filter((node) => node.status === 'done' || node.workflowRunState === 'done')
  const failed = nodes.filter((node) => node.workflowRunState === 'failed')

  return [
    { label: 'Ready', value: ready.length, tone: 'ready' },
    { label: 'Running', value: running.length, tone: 'running' },
    { label: 'Approval', value: surfaced.approvals.length, tone: 'approval' },
    { label: 'Attention', value: surfaced.blockers.length, tone: 'attention' },
    { label: 'Done', value: done.length, tone: 'done' },
    { label: 'Failed', value: failed.length, tone: 'failed' },
    { label: 'Artifacts', value: input.artifacts.length, tone: 'neutral' },
  ]
}

function extractBlockers(input: RecapInput, policy: RecapTemplatePolicy): RecapBlocker[] {
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

  const subCanvasBlockers = policy.surfaceSubCanvasRollups ? input.subCanvases.flatMap((canvas): RecapBlocker[] => (
    canvas.recap?.blockers.map((blocker) => ({
      ...blocker,
      subjectKind: 'canvas' as const,
      subjectId: canvas.id,
      title: `${canvas.title}: ${blocker.title}`,
    })) ?? []
  )) : []

  return [...nodeBlockers, ...sessionBlockers, ...subCanvasBlockers]
}

function extractApprovals(input: RecapInput, policy: RecapTemplatePolicy): RecapApproval[] {
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

  const subCanvasApprovals = policy.surfaceSubCanvasRollups ? input.subCanvases.flatMap((canvas): RecapApproval[] => (
    canvas.recap?.approvals.map((approval) => ({
      ...approval,
      subjectKind: 'gate' as const,
      subjectId: canvas.id,
      title: `${canvas.title}: ${approval.title}`,
    })) ?? []
  )) : []

  return [...sessionApprovals, ...gateApprovals, ...proposalApprovals, ...subCanvasApprovals]
}

/**
 * 「在等谁/什么」语义抽取。比 extractBlockers 弱一档(还没硬卡住,可能马上就走),
 * 比 extractApprovals 强一档(approvals 只覆盖 gate 已成立的;awaitings 还覆盖
 * awaiting-input / awaiting-upstream 两类)。
 *
 * 三个桶按顺序拼:approval → input → upstream,UI 按这个顺序展示。
 * 同一 node 可能同时落进多个桶(例如既 awaiting-input 又有未完成上游),
 * 这里允许重复落 —— 上层 details 自行 slice 限长。
 */
function extractAwaitings(input: RecapInput): RecapAwaiting[] {
  const nodes = input.nodes
  const doneNodeIds = new Set(
    nodes.filter((n) => n.status === 'done' || n.workflowRunState === 'done').map((n) => n.id),
  )
  const titlesById = new Map(nodes.map((n) => [n.id, n.title] as const))

  const awaitings: RecapAwaiting[] = []

  for (const node of nodes) {
    const evidenceRefs = evidenceForSubject(input.artifacts, { nodeId: node.id })

    // 1) approval — node.status === 'awaiting' OR workflowRunState === 'gate-wait'.
    //    approvers 是 reviewer 推断主源,fallback 到 "needs reviewer"。
    const isApprovalAwait =
      node.status === 'awaiting' || node.workflowRunState === 'gate-wait'
    if (isApprovalAwait) {
      const reviewers = (node.approvers ?? []).filter((r) => r && r.trim().length > 0)
      awaitings.push({
        kind: 'awaiting-approval',
        subjectId: node.id,
        subjectKind: 'node',
        title: node.title,
        reason: reviewers.length > 0 ? `等待 ${reviewers.length} 位审批人` : '等待 reviewer 指派',
        reviewers: reviewers.length > 0 ? reviewers : undefined,
        evidenceRefs,
      })
    }

    // 2) input — workflowRunState === 'awaiting-input'.
    //    "等什么" = node.inputs[0] (人写的 input 描述),fallback 到 nextAction / 字面量。
    if (node.workflowRunState === 'awaiting-input') {
      const inputSource = firstNonEmpty(node.inputs) ?? node.nextAction ?? '外部反馈'
      awaitings.push({
        kind: 'awaiting-input',
        subjectId: node.id,
        subjectKind: 'node',
        title: node.title,
        reason: inputSource,
        inputSource,
        evidenceRefs,
      })
    }

    // 3) upstream — node.dependsOnNodeIds 里至少一个上游还没 done.
    //    只在节点本身还没 done / 还没 blocked 的时候算(blocked 已经走 blockers 桶)。
    const isBlocked =
      node.status === 'blocked' || node.workflowRunState === 'failed' || !!node.blockedReason
    const isDone = doneNodeIds.has(node.id)
    if (!isBlocked && !isDone) {
      const pendingUpstream = (node.dependsOnNodeIds ?? []).filter(
        (id) => id && !doneNodeIds.has(id),
      )
      if (pendingUpstream.length > 0) {
        const upstreamTitles = pendingUpstream
          .map((id) => titlesById.get(id) ?? id)
          .slice(0, 3)
          .join(', ')
        const more = pendingUpstream.length > 3 ? ` 等 ${pendingUpstream.length} 项` : ''
        awaitings.push({
          kind: 'awaiting-upstream',
          subjectId: node.id,
          subjectKind: 'node',
          title: node.title,
          reason: `${upstreamTitles}${more} 完成`,
          upstreamNodeIds: pendingUpstream,
          evidenceRefs,
        })
      }
    }
  }

  return awaitings
}

function firstNonEmpty(values?: string[] | null): string | undefined {
  if (!values) return undefined
  for (const v of values) {
    if (typeof v === 'string' && v.trim().length > 0) return v.trim()
  }
  return undefined
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
  awaitingItems: RecapAwaiting[],
  evidenceRefs: EvidenceRef[],
): string[] {
  const details: string[] = []
  for (const approval of approvals.slice(0, 2)) {
    details.push(`待审批：${approval.title}`)
  }
  for (const blocker of blockers.slice(0, Math.max(0, 3 - details.length))) {
    details.push(`阻塞：${blocker.title} - ${blocker.reason}`)
  }
  // 把「等谁」桶也铺进 details — 给 reviewer / input / upstream 三类各留位置。
  // 注意:approvals(已成 gate)和 awaiting-approval 可能重叠,这里允许显示,
  // 因为 awaiting 提供了 reviewer handle,信息密度比 approval.title 更高。
  for (const awaiting of awaitingItems.slice(0, Math.max(0, 6 - details.length))) {
    details.push(formatAwaitingDetail(awaiting))
  }
  if (details.length < 6 && evidenceRefs.length > 0) {
    details.push(`最近证据：${evidenceRefs[0].title}`)
  }
  if (details.length < 6) {
    const running = input.nodes.find((node) => node.status === 'working' || node.workflowRunState === 'running')
    if (running) details.push(`进行中：${running.title}`)
  }
  return details.slice(0, 6)
}

function formatAwaitingDetail(awaiting: RecapAwaiting): string {
  switch (awaiting.kind) {
    case 'awaiting-approval': {
      const reviewers = (awaiting.reviewers ?? [])
        .map((r) => (r.startsWith('@') || r.includes('@') ? r : `@${r}`))
        .join(', ')
      return reviewers
        ? `等审批：${awaiting.title} → ${reviewers}`
        : `等审批：${awaiting.title} → ${awaiting.reason}`
    }
    case 'awaiting-input': {
      const src = awaiting.inputSource ?? awaiting.reason
      return `等反馈：${awaiting.title} 需要 ${src}`
    }
    case 'awaiting-upstream': {
      return `等上游：${awaiting.title} 等 ${awaiting.reason}`
    }
  }
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
