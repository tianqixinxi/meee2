import type {
  ArtifactReviewStatus,
  CanvasInfo,
  CanvasScope,
  PlannerArtifact,
  SessionArtifactCandidate,
  PlanningNode,
} from '../types'
import { resolvedArtifactPayload } from './artifactPayload'

export type ArtifactTypeGroupId =
  | 'docs'
  | 'boards'
  | 'implementation'
  | 'validation'
  | 'files-data'
  | 'other'

export interface ArtifactTypeGroup {
  id: ArtifactTypeGroupId
  label: string
}

export const ARTIFACT_TYPE_GROUPS: ArtifactTypeGroup[] = [
  { id: 'docs', label: 'Docs' },
  { id: 'boards', label: 'Boards' },
  { id: 'implementation', label: 'Implementation' },
  { id: 'validation', label: 'Validation' },
  { id: 'files-data', label: 'Files/Data' },
  { id: 'other', label: 'Other' },
]

export interface CanvasArtifactsSource {
  canvas: CanvasInfo
  nodes: PlanningNode[]
  artifacts: PlannerArtifact[]
  error?: string
}

export interface ArtifactIndexItem {
  key: string
  sourceKind: 'artifact' | 'candidate'
  groupId: ArtifactTypeGroupId
  canvas: CanvasInfo
  node?: PlanningNode
  sessionId?: string | null
  candidate?: SessionArtifactCandidate
  latest: PlannerArtifact
  artifacts: PlannerArtifact[]
  reviewStatus: ArtifactReviewStatus
  displayState: ArtifactDisplayState
  typeLabel: string
  haystack: string
}

export type ArtifactDisplayState =
  | 'candidate'
  | 'ready'
  | 'needs-review'
  | 'rejected'
  | 'failed'
  | 'stale'
  | 'working'
  | 'other'

export interface ArtifactIndexFilters {
  query?: string
  groupId?: ArtifactTypeGroupId | 'all'
  scope?: CanvasScope | 'all'
  canvasId?: string | 'all'
  displayState?: ArtifactDisplayState | 'all'
  sessionId?: string | null
}

export function artifactSlotKey(artifact: PlannerArtifact): string {
  return `${artifact.canvasId}:${artifact.nodeId}:${artifact.reference.trim().toLowerCase()}`
}

export function artifactReviewStatus(artifact: PlannerArtifact): ArtifactReviewStatus {
  return artifact.reviewStatus ?? resolvedArtifactPayload(artifact)?.reviewStatus ?? 'approved'
}

export function artifactDisplayState(artifact: PlannerArtifact): ArtifactDisplayState {
  const reviewStatus = artifactReviewStatus(artifact)
  if (reviewStatus === 'pending') return 'needs-review'
  if (reviewStatus === 'rejected') return 'rejected'
  const status = artifact.status?.trim().toLowerCase() ?? ''
  if (status === 'failed' || status === 'error') return 'failed'
  if (status === 'stale' || status === 'superseded') return 'stale'
  if (status === 'running' || status === 'working' || status === 'pending') return 'working'
  if (!status || status === 'attached' || status === 'created' || status === 'updated' || status === 'done') {
    return 'ready'
  }
  return 'other'
}

export function artifactTypeLabel(artifact: PlannerArtifact): string {
  return resolvedArtifactPayload(artifact)?.type ?? artifact.kind
}

export function classifyArtifactGroup(artifact: PlannerArtifact): ArtifactTypeGroupId {
  const kind = artifact.kind
  const payloadType = resolvedArtifactPayload(artifact)?.type
  if (kind === 'prd' || kind === 'lark-doc' || payloadType === 'prd' || payloadType === 'markdown') {
    return 'docs'
  }
  if (kind === 'kanban' || kind === 'idea-draft' || payloadType === 'kanban') {
    return 'boards'
  }
  if (kind === 'impl-pr' || kind === 'main-merge' || payloadType === 'impl-pr') {
    return 'implementation'
  }
  if (kind === 'check-result' || kind === 'prerelease-verdict' || payloadType === 'check-result') {
    return 'validation'
  }
  if (kind === 'generic' || payloadType === 'file' || payloadType === 'integration') {
    return 'files-data'
  }
  return 'other'
}

export function buildCandidateArtifactIndex(candidates: SessionArtifactCandidate[]): ArtifactIndexItem[] {
  return candidates.map((candidate) => {
    const artifact = candidateToArtifact(candidate)
    const canvas = candidateCanvas(candidate)
    const item: ArtifactIndexItem = {
      key: `candidate:${candidate.id}`,
      sourceKind: 'candidate',
      groupId: classifyArtifactGroup(artifact),
      canvas,
      node: undefined,
      sessionId: candidate.sessionId,
      candidate,
      latest: artifact,
      artifacts: [artifact],
      reviewStatus: 'pending',
      displayState: 'candidate',
      typeLabel: candidate.kind || artifact.kind,
      haystack: '',
    }
    item.haystack = buildHaystack(item)
    return item
  }).sort((a, b) => sortArtifactsNewestFirst(a.latest, b.latest))
}

export function buildArtifactIndex(sources: CanvasArtifactsSource[]): ArtifactIndexItem[] {
  const slots = new Map<string, ArtifactIndexItem>()
  for (const source of sources) {
    const nodesById = new Map(source.nodes.map((node) => [node.id, node]))
    for (const artifact of source.artifacts) {
      const key = artifactSlotKey(artifact)
      const node = nodesById.get(artifact.nodeId)
      const current = slots.get(key)
      if (current) {
        current.artifacts.push(artifact)
        current.artifacts.sort(sortArtifactsNewestFirst)
        current.latest = current.artifacts[0]
        current.reviewStatus = artifactReviewStatus(current.latest)
        current.displayState = artifactDisplayState(current.latest)
        current.groupId = classifyArtifactGroup(current.latest)
        current.typeLabel = artifactTypeLabel(current.latest)
        current.haystack = buildHaystack(current)
      } else {
        const item: ArtifactIndexItem = {
          key,
          sourceKind: 'artifact',
          groupId: classifyArtifactGroup(artifact),
          canvas: source.canvas,
          node,
          sessionId: node?.sessionId ?? null,
          candidate: undefined,
          latest: artifact,
          artifacts: [artifact],
          reviewStatus: artifactReviewStatus(artifact),
          displayState: artifactDisplayState(artifact),
          typeLabel: artifactTypeLabel(artifact),
          haystack: '',
        }
        item.haystack = buildHaystack(item)
        slots.set(key, item)
      }
    }
  }
  return Array.from(slots.values()).sort((a, b) => sortArtifactsNewestFirst(a.latest, b.latest))
}

export function filterArtifactIndex(
  items: ArtifactIndexItem[],
  filters: ArtifactIndexFilters,
): ArtifactIndexItem[] {
  const query = filters.query?.trim().toLowerCase() ?? ''
  return items.filter((item) => {
    if (filters.groupId && filters.groupId !== 'all' && item.groupId !== filters.groupId) return false
    if (filters.scope && filters.scope !== 'all' && item.canvas.scope !== filters.scope) return false
    if (filters.canvasId && filters.canvasId !== 'all' && item.canvas.id !== filters.canvasId) return false
    if (filters.displayState && filters.displayState !== 'all' && item.displayState !== filters.displayState) return false
    if (filters.sessionId && item.sessionId !== filters.sessionId) return false
    return !query || item.haystack.includes(query)
  })
}

export function artifactGroupCounts(items: ArtifactIndexItem[]): Record<ArtifactTypeGroupId, number> {
  const counts = Object.fromEntries(ARTIFACT_TYPE_GROUPS.map((group) => [group.id, 0])) as Record<
    ArtifactTypeGroupId,
    number
  >
  for (const item of items) counts[item.groupId] += 1
  return counts
}

export function sortArtifactsNewestFirst(a: PlannerArtifact, b: PlannerArtifact): number {
  return new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime()
}

function buildHaystack(item: ArtifactIndexItem): string {
  return [
    item.sourceKind,
    item.latest.title,
    item.latest.reference,
    item.latest.kind,
    item.latest.status,
    item.latest.positionTag,
    item.reviewStatus,
    item.displayState,
    item.typeLabel,
    item.canvas.name,
    item.canvas.id,
    item.canvas.workspacePath,
    item.node?.title,
    item.node?.id,
    item.sessionId,
    item.candidate?.summary,
    item.candidate?.provider,
    item.candidate?.toolName,
    ...(item.candidate?.references.map((reference) => `${reference.kind} ${reference.label ?? ''} ${reference.value}`) ?? []),
  ].filter(Boolean).join(' ').toLowerCase()
}

function candidateToArtifact(candidate: SessionArtifactCandidate): PlannerArtifact {
  const reference = candidate.references[0]?.value ?? candidate.id
  return {
    id: candidate.id,
    canvasId: `session:${candidate.sessionId}`,
    nodeId: candidate.sessionId,
    kind: candidateKindToArtifactKind(candidate.kind),
    title: candidate.title,
    reference,
    status: candidate.status,
    createdAt: candidate.createdAt,
    positionTag: 'candidate',
    reviewStatus: 'pending',
    payload: {
      type: 'text',
      text: candidate.summary,
      references: candidate.references,
    },
  }
}

function candidateCanvas(candidate: SessionArtifactCandidate): CanvasInfo {
  return {
    id: `session:${candidate.sessionId}`,
    name: 'Session',
    scope: 'personal',
    kind: 'monitor',
    isDefault: false,
    workspacePath: candidate.cwd ?? '',
    ownerUserId: null,
    teamId: null,
  }
}

function candidateKindToArtifactKind(kind: string): PlannerArtifact['kind'] {
  switch (kind) {
    case 'impl-pr':
      return 'impl-pr'
    case 'check-result':
      return 'check-result'
    case 'prd':
      return 'prd'
    case 'kanban':
      return 'kanban'
    default:
      return 'generic'
  }
}
