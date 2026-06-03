import { describe, expect, it } from 'vitest'
import {
  artifactGroupCounts,
  buildArtifactIndex,
  classifyArtifactGroup,
  filterArtifactIndex,
} from './artifactIndex'
import type { CanvasInfo, PlannerArtifact, PlanningNode } from '../types'

const canvas: CanvasInfo = {
  id: 'monitor',
  name: 'Monitor',
  scope: 'personal',
  kind: 'monitor',
  isDefault: true,
  workspacePath: '/repo',
}

const node: PlanningNode = {
  id: 'release',
  canvasId: 'monitor',
  title: 'Release planning',
  schema: { inputs: [], outputs: [], goal: 'ship' },
  contextSources: [],
  executionMode: 'human',
  executorType: 'human',
  doerId: 'kai',
  reviewerIds: [],
  approverIds: [],
  handoffPolicy: 'none',
  status: 'done',
  sessionId: null,
  chatThreadId: null,
  source: 'planner',
  dependsOnNodeIds: [],
  subCanvasId: null,
}

function artifact(input: Partial<PlannerArtifact> & { id: string; kind: PlannerArtifact['kind'] }): PlannerArtifact {
  return {
    id: input.id,
    canvasId: input.canvasId ?? 'monitor',
    nodeId: input.nodeId ?? 'release',
    kind: input.kind,
    title: input.title ?? input.id,
    reference: input.reference ?? 'release.md',
    status: input.status ?? 'done',
    createdAt: input.createdAt ?? '2026-06-03T10:00:00Z',
    payload: input.payload,
    typedPayload: input.typedPayload,
    reviewStatus: input.reviewStatus,
    positionTag: input.positionTag,
  }
}

describe('artifactIndex', () => {
  it('classifies artifacts into semantic groups', () => {
    expect(classifyArtifactGroup(artifact({ id: 'prd', kind: 'prd' }))).toBe('docs')
    expect(classifyArtifactGroup(artifact({ id: 'board', kind: 'idea-draft' }))).toBe('boards')
    expect(classifyArtifactGroup(artifact({ id: 'pr', kind: 'impl-pr' }))).toBe('implementation')
    expect(classifyArtifactGroup(artifact({ id: 'check', kind: 'check-result' }))).toBe('validation')
    expect(classifyArtifactGroup(artifact({
      id: 'file',
      kind: 'generic',
      typedPayload: { type: 'file', filename: 'report.md', mime: 'text/markdown', sizeBytes: 120 },
    }))).toBe('files-data')
    expect(classifyArtifactGroup(artifact({ id: 'future', kind: 'future-kind' as PlannerArtifact['kind'] }))).toBe('other')
  })

  it('merges versions by canvas node and reference with newest first', () => {
    const older = artifact({
      id: 'old',
      kind: 'prd',
      title: 'Release PRD v1',
      reference: 'release.md',
      createdAt: '2026-06-02T10:00:00Z',
    })
    const newer = artifact({
      id: 'new',
      kind: 'prd',
      title: 'Release PRD v2',
      reference: 'release.md',
      createdAt: '2026-06-03T10:00:00Z',
      reviewStatus: 'pending',
    })

    const items = buildArtifactIndex([{ canvas, nodes: [node], artifacts: [older, newer] }])

    expect(items).toHaveLength(1)
    expect(items[0].latest.id).toBe('new')
    expect(items[0].artifacts.map((item) => item.id)).toEqual(['new', 'old'])
    expect(items[0].reviewStatus).toBe('pending')
  })

  it('filters by query group review and status', () => {
    const items = buildArtifactIndex([{
      canvas,
      nodes: [node],
      artifacts: [
        artifact({ id: 'prd', kind: 'prd', title: 'Release PRD', status: 'done', reviewStatus: 'approved' }),
        artifact({
          id: 'check',
          kind: 'check-result',
          title: 'Smoke Test',
          reference: 'smoke.json',
          status: 'needs_review',
          reviewStatus: 'pending',
        }),
      ],
    }])

    expect(artifactGroupCounts(items).docs).toBe(1)
    expect(artifactGroupCounts(items).validation).toBe(1)
    expect(filterArtifactIndex(items, { groupId: 'validation' }).map((item) => item.latest.id)).toEqual(['check'])
    expect(filterArtifactIndex(items, { query: 'release', reviewStatus: 'approved' }).map((item) => item.latest.id)).toEqual(['prd'])
    expect(filterArtifactIndex(items, { status: 'needs_review' }).map((item) => item.latest.id)).toEqual(['check'])
  })
})
