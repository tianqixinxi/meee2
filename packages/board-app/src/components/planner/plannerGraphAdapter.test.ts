import { describe, expect, it } from 'vitest'
import { visibleOutputReferences } from './plannerGraphAdapter'
import type { PlannerArtifact, PlanningNode } from '../../types'

function node(overrides: Partial<PlanningNode> = {}): PlanningNode {
  return {
    id: 'node-1',
    canvasId: 'c1',
    title: 'Producer',
    schema: { inputs: [], outputs: [], goal: '' },
    contextSources: [],
    executionMode: 'auto',
    executorType: 'claude',
    doerId: '',
    reviewerIds: [],
    approverIds: [],
    handoffPolicy: 'none',
    status: 'ready',
    ...overrides,
  } as PlanningNode
}

function artifact(overrides: Partial<PlannerArtifact> = {}): PlannerArtifact {
  return {
    id: 'art-1',
    canvasId: 'c1',
    nodeId: 'node-1',
    kind: 'generic',
    title: 'Artifact',
    reference: 'repo://docs/prd/spec.md',
    status: 'attached',
    createdAt: new Date('2026-05-01T00:00:00Z').toISOString(),
    ...overrides,
  }
}

describe('visibleOutputReferences', () => {
  it('fills a templated slot with a matching concrete artifact and drops the template', () => {
    const n = node({ schema: { inputs: [], outputs: ['repo://docs/prd/<slug>.md'], goal: '' } })
    const arts = [artifact({ reference: 'repo://docs/prd/spec.md' })]
    expect(visibleOutputReferences(n, arts)).toEqual(['repo://docs/prd/spec.md'])
  })

  it('keeps an unfilled templated slot as a pending reference', () => {
    const n = node({ schema: { inputs: [], outputs: ['repo://docs/prd/<slug>.md'], goal: '' } })
    expect(visibleOutputReferences(n, [])).toEqual(['repo://docs/prd/<slug>.md'])
  })

  it('drops the superseded older artifact when two fill the same slot', () => {
    const n = node({ schema: { inputs: [], outputs: ['repo://docs/prd/<slug>.md'], goal: '' } })
    const older = artifact({
      id: 'old',
      reference: 'repo://docs/prd/v1.md',
      createdAt: new Date('2026-05-01T00:00:00Z').toISOString(),
    })
    const newer = artifact({
      id: 'new',
      reference: 'repo://docs/prd/v2.md',
      createdAt: new Date('2026-05-02T00:00:00Z').toISOString(),
    })
    // The newer artifact is `current`; the older is `superseded` and dropped.
    expect(visibleOutputReferences(n, [older, newer])).toEqual(['repo://docs/prd/v2.md'])
  })

  it('never surfaces the synthetic artifact://<nodeId>/output handle', () => {
    const n = node({
      id: 'node-1',
      schema: { inputs: [], outputs: [], goal: '' },
      artifactRefs: ['artifact://node-1/output', 'repo://real/output.md'],
    })
    const refs = visibleOutputReferences(n, [])
    expect(refs).not.toContain('artifact://node-1/output')
    expect(refs).toContain('repo://real/output.md')
  })

  it('surfaces runtime refs (e.g. subcanvas:<id>) that are not persisted on the node', () => {
    const n = node({ schema: { inputs: [], outputs: [], goal: '' } })
    expect(visibleOutputReferences(n, [], ['subcanvas:abc123'])).toEqual(['subcanvas:abc123'])
  })

  it('keeps an artifact-less output ref that does not match any declared slot', () => {
    const n = node({
      schema: { inputs: [], outputs: ['repo://docs/prd/<slug>.md'], goal: '' },
      artifactRefs: ['repo://misc/notes.md'],
    })
    const refs = visibleOutputReferences(n, [])
    expect(refs).toContain('repo://misc/notes.md')
    // The unfilled templated slot is still pending and surfaced too.
    expect(refs).toContain('repo://docs/prd/<slug>.md')
  })
})
