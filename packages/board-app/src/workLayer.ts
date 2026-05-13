import type { Session, SyncPolicy } from './types'
import type { SessionGraphNode } from './sessionGraph'

export interface SyncPolicyOption {
  id: SyncPolicy
  label: string
  description: string
}

export interface WorkroomComment {
  id: string
  author: string
  body: string
  createdAt: string
}

export interface Workroom {
  id: string
  name: string
  purpose: string
  linkedRepo: string
  linkedPr: string
  selectedSessionIds: string[]
  sharedContext: string
  comments: WorkroomComment[]
  createdAt: string
  updatedAt: string
}

export interface SyncPayloadPreview {
  policy: SyncPolicy
  fields: string[]
  payload: Record<string, unknown>
}

const WORKROOM_STORAGE_KEY = 'meee2.workrooms.v1'

export const SYNC_POLICY_OPTIONS: SyncPolicyOption[] = [
  {
    id: 'private',
    label: 'Private',
    description: 'Only visible on this Mac.',
  },
  {
    id: 'metadata',
    label: 'Metadata only',
    description: 'Owner, repo, provider, status, blocker only.',
  },
  {
    id: 'summary',
    label: 'Summary',
    description: 'Metadata plus current step and summary.',
  },
  {
    id: 'recentContext',
    label: 'Recent context',
    description: 'Summary plus recent message previews.',
  },
  {
    id: 'fullTranscript',
    label: 'Full transcript',
    description: 'Explicitly allow full transcript sync.',
  },
  {
    id: 'artifactsOnly',
    label: 'Artifacts only',
    description: 'Only PR, diff, test, and deploy evidence.',
  },
]

export function effectiveSyncPolicy(session: Session): SyncPolicy {
  return session.syncPolicy ?? (session.syncEnabled ? 'metadata' : 'private')
}

export function buildSyncPayloadPreview(
  node: SessionGraphNode,
  policy: SyncPolicy,
): SyncPayloadPreview {
  const session = node.session
  const blocker = node.risks.find((risk) => risk.severity !== 'low')?.label ?? null
  const metadata = {
    sessionId: session.id,
    owner: 'local-user',
    provider: node.provider,
    repo: node.repo,
    branch: node.branch,
    status: session.status,
    blocker,
    lastActivity: session.lastActivity ?? null,
  }

  if (policy === 'private') {
    return { policy, fields: [], payload: {} }
  }

  if (policy === 'metadata') {
    return {
      policy,
      fields: Object.keys(metadata),
      payload: metadata,
    }
  }

  if (policy === 'artifactsOnly') {
    const payload = {
      sessionId: session.id,
      repo: node.repo,
      status: session.status,
      artifacts: inferArtifacts(node),
    }
    return { policy, fields: Object.keys(payload), payload }
  }

  const summaryPayload = {
    ...metadata,
    title: session.title,
    currentStep: node.currentStep,
    recentSummary: session.latestRecap?.content ?? node.currentStep,
    risks: node.risks.map((risk) => ({
      type: risk.type,
      severity: risk.severity,
      label: risk.label,
    })),
  }

  if (policy === 'summary') {
    return {
      policy,
      fields: Object.keys(summaryPayload),
      payload: summaryPayload,
    }
  }

  if (policy === 'recentContext') {
    const payload = {
      ...summaryPayload,
      recentMessages: session.recentMessages.slice(-5).map((message) => ({
        role: message.role,
        text: message.text,
      })),
    }
    return { policy, fields: Object.keys(payload), payload }
  }

  return {
    policy,
    fields: [...Object.keys(summaryPayload), 'fullTranscriptAllowed'],
    payload: {
      ...summaryPayload,
      fullTranscriptAllowed: true,
    },
  }
}

export function inferArtifacts(node: SessionGraphNode): Array<{
  type: 'diff' | 'commit' | 'pr' | 'test' | 'deploy' | 'summary'
  title: string
  status: 'unknown' | 'passed' | 'failed' | 'created'
}> {
  const text = [
    node.session.title,
    node.currentStep,
    node.latestMessageText,
    node.session.latestRecap?.content ?? '',
  ].join('\n').toLowerCase()
  const artifacts: Array<{
    type: 'diff' | 'commit' | 'pr' | 'test' | 'deploy' | 'summary'
    title: string
    status: 'unknown' | 'passed' | 'failed' | 'created'
  }> = []

  if (text.includes('pr') || text.includes('pull request')) {
    artifacts.push({ type: 'pr', title: 'Pull request mentioned', status: 'created' })
  }
  if (text.includes('test')) {
    artifacts.push({
      type: 'test',
      title: 'Test result mentioned',
      status: text.includes('failed') || text.includes('failing') ? 'failed' : 'unknown',
    })
  }
  if (text.includes('deploy') || text.includes('vercel')) {
    artifacts.push({ type: 'deploy', title: 'Deploy status mentioned', status: 'unknown' })
  }
  if (node.session.status === 'completed') {
    artifacts.push({ type: 'summary', title: 'Session completed', status: 'passed' })
  }

  return artifacts
}

export function loadWorkrooms(): Workroom[] {
  return readJson<Workroom[]>(WORKROOM_STORAGE_KEY, [])
}

export function saveWorkrooms(workrooms: Workroom[]): Workroom[] {
  writeJson(WORKROOM_STORAGE_KEY, workrooms)
  return workrooms
}

export function createWorkroom(input: {
  name: string
  purpose: string
  linkedRepo: string
  linkedPr: string
  selectedSessionIds: string[]
}): Workroom {
  const now = new Date().toISOString()
  return {
    id: `workroom-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 7)}`,
    name: input.name.trim() || 'Untitled workroom',
    purpose: input.purpose.trim() || 'Coordinate selected AI sessions.',
    linkedRepo: input.linkedRepo.trim(),
    linkedPr: input.linkedPr.trim(),
    selectedSessionIds: input.selectedSessionIds,
    sharedContext: '',
    comments: [],
    createdAt: now,
    updatedAt: now,
  }
}

export function generateHandoffSummary(workroom: Workroom, nodes: SessionGraphNode[]): string {
  const selected = nodes.filter((node) => workroom.selectedSessionIds.includes(node.session.id))
  const changed = selected.map((node) => `- ${node.session.title}: ${node.currentStep}`).join('\n') || '- No selected sessions.'
  const risks = selected
    .flatMap((node) => node.risks.map((risk) => `- ${node.session.title}: ${risk.label} (${risk.severity})`))
    .join('\n') || '- No visible risks.'
  const next = selected
    .filter((node) => node.risks.some((risk) => risk.severity !== 'low'))
    .map((node) => `- Rescue ${node.session.title}: jump back and resolve ${node.risks[0]?.label ?? 'blocker'}.`)
    .join('\n') || '- Continue review from latest completed/running sessions.'

  return [
    `Goal: ${workroom.purpose}`,
    '',
    'Current status:',
    changed,
    '',
    'Risks / blockers:',
    risks,
    '',
    'Suggested next steps:',
    next,
  ].join('\n')
}

function readJson<T>(key: string, fallback: T): T {
  try {
    const raw = window.localStorage.getItem(key)
    if (!raw) return fallback
    return JSON.parse(raw) as T
  } catch {
    return fallback
  }
}

function writeJson<T>(key: string, value: T) {
  try {
    window.localStorage.setItem(key, JSON.stringify(value))
  } catch {
    // Local storage can be disabled in hardened webviews. Keep runtime usable.
  }
}
