import type { Session, TranscriptEntry } from './types'

export type SessionBucketId =
  | 'needsAttention'
  | 'running'
  | 'waitingBlocked'
  | 'recentlyCompleted'
  | 'failed'
  | 'history'

export type SessionRiskType =
  | 'permission'
  | 'blocked'
  | 'failed'
  | 'stale'
  | 'background'

export interface SessionRisk {
  type: SessionRiskType
  severity: 'high' | 'medium' | 'low'
  label: string
  detail: string
}

export interface SessionGraphNode {
  session: Session
  provider: string
  repo: string
  branch: string | null
  currentStep: string
  latestMessage: TranscriptEntry | null
  latestMessageText: string
  risks: SessionRisk[]
  primaryBucket: SessionBucketId
  bucketIds: SessionBucketId[]
  lastActivityMs: number
}

export interface SessionGraph {
  nodes: SessionGraphNode[]
  buckets: Record<SessionBucketId, SessionGraphNode[]>
}

const RUNNING_STATUSES = new Set([
  'active',
  'thinking',
  'tooling',
  'compacting',
])

const WAITING_STATUSES = new Set([
  'idle',
  'waitingForUser',
])

const DONE_STATUSES = new Set([
  'completed',
  'done',
])

const FAILED_STATUSES = new Set([
  'dead',
  'failed',
  'error',
])

const STALE_RUNNING_MS = 30 * 60 * 1000

export const SESSION_BUCKET_META: Record<SessionBucketId, {
  title: string
  shortTitle: string
  empty: string
}> = {
  needsAttention: {
    title: 'Needs attention',
    shortTitle: 'Attention',
    empty: 'No permission, stale, or blocked sessions.',
  },
  running: {
    title: 'Running',
    shortTitle: 'Running',
    empty: 'No actively running sessions.',
  },
  waitingBlocked: {
    title: 'Waiting / Blocked',
    shortTitle: 'Waiting',
    empty: 'No sessions waiting for input.',
  },
  recentlyCompleted: {
    title: 'Recently completed',
    shortTitle: 'Done',
    empty: 'No completed sessions yet.',
  },
  failed: {
    title: 'Failed',
    shortTitle: 'Failed',
    empty: 'No failed sessions.',
  },
  history: {
    title: 'History',
    shortTitle: 'History',
    empty: 'No session history yet.',
  },
}

export function buildSessionGraph(sessions: Session[], now: number = Date.now()): SessionGraph {
  const nodes = sessions
    .map((session) => buildSessionGraphNode(session, now))
    .sort((a, b) => b.lastActivityMs - a.lastActivityMs)

  const buckets: Record<SessionBucketId, SessionGraphNode[]> = {
    needsAttention: [],
    running: [],
    waitingBlocked: [],
    recentlyCompleted: [],
    failed: [],
    history: nodes,
  }

  for (const node of nodes) {
    for (const bucketId of node.bucketIds) {
      if (bucketId === 'history') continue
      buckets[bucketId].push(node)
    }
  }

  return { nodes, buckets }
}

export function matchesSessionNode(node: SessionGraphNode, query: string): boolean {
  const q = query.trim().toLowerCase()
  if (!q) return true
  const s = node.session
  return [
    s.title,
    s.project,
    s.pluginDisplayName,
    s.pluginId,
    s.status,
    s.currentTool ?? '',
    s.currentTask ?? '',
    node.currentStep,
    node.latestMessageText,
  ].some((value) => value.toLowerCase().includes(q))
}

function buildSessionGraphNode(session: Session, now: number): SessionGraphNode {
  const latestMessage = lastMessage(session.recentMessages)
  const latestMessageText = latestMessage?.text?.trim() ?? ''
  const lastActivityMs = parseTime(session.lastActivity) ?? parseTime(session.startedAt) ?? 0
  const risks = extractRisks(session, now, lastActivityMs)
  const primaryBucket = bucketFor(session, risks)
  const bucketIds = new Set<SessionBucketId>([primaryBucket, 'history'])

  if (risks.some((risk) => risk.severity !== 'low')) bucketIds.add('needsAttention')
  if (FAILED_STATUSES.has(session.status)) bucketIds.add('failed')

  return {
    session,
    provider: session.pluginDisplayName || session.pluginId || 'Unknown',
    repo: session.project || session.title || 'Unknown workspace',
    branch: null,
    currentStep: currentStepFor(session, latestMessageText),
    latestMessage,
    latestMessageText,
    risks,
    primaryBucket,
    bucketIds: [...bucketIds],
    lastActivityMs,
  }
}

function bucketFor(session: Session, risks: SessionRisk[]): SessionBucketId {
  if (risks.some((risk) => risk.severity === 'high')) return 'needsAttention'
  if (FAILED_STATUSES.has(session.status)) return 'failed'
  if (DONE_STATUSES.has(session.status)) return 'recentlyCompleted'
  if (RUNNING_STATUSES.has(session.status) || session.backgroundAgents.length > 0) return 'running'
  if (WAITING_STATUSES.has(session.status) || session.status === 'permissionRequired') return 'waitingBlocked'
  return 'history'
}

function extractRisks(session: Session, now: number, lastActivityMs: number): SessionRisk[] {
  const risks: SessionRisk[] = []

  if (session.status === 'permissionRequired' || session.pendingPermissionTool) {
    risks.push({
      type: 'permission',
      severity: 'high',
      label: 'Permission required',
      detail: session.pendingPermissionMessage || session.pendingPermissionTool || 'Waiting for local approval.',
    })
  }

  if (FAILED_STATUSES.has(session.status)) {
    risks.push({
      type: 'failed',
      severity: 'high',
      label: 'Failed',
      detail: 'The underlying agent process ended or reported failure.',
    })
  }

  if (session.status === 'waitingForUser') {
    risks.push({
      type: 'blocked',
      severity: 'medium',
      label: 'Waiting for user',
      detail: 'The agent is waiting for input before it can continue.',
    })
  }

  if (
    lastActivityMs > 0 &&
    RUNNING_STATUSES.has(session.status) &&
    now - lastActivityMs >= STALE_RUNNING_MS
  ) {
    risks.push({
      type: 'stale',
      severity: 'medium',
      label: 'Stale running',
      detail: 'No visible activity for more than 30 minutes.',
    })
  }

  if (session.backgroundAgents.length > 0) {
    risks.push({
      type: 'background',
      severity: 'low',
      label: `${session.backgroundAgents.length} background`,
      detail: 'Background agents or tools are still running.',
    })
  }

  return risks
}

function currentStepFor(session: Session, latestMessageText: string): string {
  if (session.currentTask?.trim()) return session.currentTask.trim()
  if (session.currentTool?.trim()) return `Using ${session.currentTool.trim()}`
  if (session.latestRecap?.content?.trim()) return session.latestRecap.content.trim()
  if (latestMessageText) return latestMessageText
  return statusLabel(session.status)
}

function statusLabel(status: string): string {
  switch (status) {
    case 'permissionRequired':
      return 'Waiting for permission'
    case 'waitingForUser':
      return 'Waiting for user'
    case 'tooling':
      return 'Running tool'
    case 'thinking':
      return 'Thinking'
    case 'compacting':
      return 'Compacting context'
    case 'completed':
      return 'Completed'
    case 'dead':
      return 'Failed or closed'
    default:
      return status
  }
}

function lastMessage(messages: TranscriptEntry[]): TranscriptEntry | null {
  if (!messages.length) return null
  return messages[messages.length - 1] ?? null
}

function parseTime(value: string | null | undefined): number | null {
  if (!value) return null
  const ms = Date.parse(value)
  return Number.isNaN(ms) ? null : ms
}
