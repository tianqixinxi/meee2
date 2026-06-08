import { describe, expect, it } from 'vitest'
import { resolvedArtifactPayload } from './artifactPayload'
import type { PlannerArtifact, PlannerArtifactContent } from '../types'

function artifact(overrides: Partial<PlannerArtifact> = {}): PlannerArtifact {
  return {
    id: 'art-1',
    canvasId: 'c1',
    nodeId: 'n1',
    kind: 'generic',
    title: 'source_target_candidates.json',
    reference: 'file://source_target_candidates.json',
    status: 'done',
    createdAt: '2026-06-01T00:00:00.000Z',
    ...overrides,
  }
}

describe('resolvedArtifactPayload — json artifacts', () => {
  it('normalizes fetched JSON content into a structured typed payload', () => {
    const content: PlannerArtifactContent = {
      artifactId: 'art-1',
      type: 'json',
      mimeType: 'application/json',
      filename: 'source_target_candidates.json',
      size: 128,
      content: JSON.stringify([{ company: 'Acme', score: 91 }, { company: 'Globex', score: 82 }]),
    }

    const payload = resolvedArtifactPayload(artifact(), content)

    expect(payload?.type).toBe('json')
    if (payload?.type !== 'json') throw new Error('expected json payload')
    expect(payload.preview).toBe('JSON array · 2 items')
    expect(payload.entries[0]).toEqual({ key: '0', value: 'Object(2)' })
  })

  it('normalizes inline JSON object payloads', () => {
    const payload = resolvedArtifactPayload(artifact({
      payload: { type: 'json', data: { total: 44, source: 'search' } },
    }))

    expect(payload?.type).toBe('json')
    if (payload?.type !== 'json') throw new Error('expected json payload')
    expect(payload.preview).toBe('JSON object · 2 fields')
    expect(payload.entries).toContainEqual({ key: 'total', value: '44' })
  })

  it('prefers fetched JSON content over file-backed blob metadata', () => {
    const content: PlannerArtifactContent = {
      artifactId: 'art-1',
      type: 'json',
      mimeType: 'application/json',
      filename: 'source_target_candidates.json',
      size: 128,
      blobRef: 'artifact://c1/art-1/source_target_candidates.json',
      content: JSON.stringify([{ source: 'web', target: 'acme.com' }]),
    }

    const payload = resolvedArtifactPayload(artifact({
      payload: {
        type: 'json',
        blobRef: 'artifact://c1/art-1/source_target_candidates.json',
        filename: 'source_target_candidates.json',
        mimeType: 'application/json',
        size: 128,
      },
    }), content)

    expect(payload?.type).toBe('json')
    if (payload?.type !== 'json') throw new Error('expected json payload')
    expect(payload.preview).toBe('JSON array · 1 item')
    expect(payload.entries).toEqual([{ key: '0', value: 'Object(2)' }])
    expect(payload.entries).not.toContainEqual({ key: 'blobRef', value: 'artifact://c1/art-1/source_target_candidates.json' })
  })
})
