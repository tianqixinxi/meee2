import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { ArtifactViewTabs, resolveArtifactViews } from './ArtifactViewTabs'
import type { PlannerArtifact, PlannerArtifactContent } from '../../types'

function artifact(overrides: Partial<PlannerArtifact> = {}): PlannerArtifact {
  return {
    id: 'art-1',
    canvasId: 'canvas-a',
    nodeId: 'node-a',
    kind: 'generic',
    title: 'Candidates',
    reference: 'artifact://candidates',
    status: 'done',
    createdAt: '2026-06-10T00:00:00.000Z',
    ...overrides,
  }
}

const listContent: PlannerArtifactContent = {
  artifactId: 'art-1',
  type: 'json',
  mimeType: 'application/json',
  content: JSON.stringify([
    { company: 'Acme', stage: 'Seed' },
    { company: 'Beta', stage: 'A' },
  ]),
}

describe('ArtifactViewTabs', () => {
  it('uses saved views and deduplicates duplicate ids', () => {
    const views = resolveArtifactViews(artifact({
      views: [
        { id: 'table', title: 'Table', kind: 'table' },
        { id: 'table', title: 'Table Copy', kind: 'table' },
        { id: 'list', title: 'List', kind: 'list' },
      ],
    }), listContent)

    expect(views.map((item) => item.view.id)).toEqual(['table', 'list'])
  })

  it('derives table and list views for array-shaped artifacts', () => {
    const views = resolveArtifactViews(artifact(), listContent)

    expect(views.map((item) => item.view.kind)).toContain('table')
    expect(views.map((item) => item.view.kind)).toContain('list')
    expect(views[0].view.title).toBe('Table')
  })

  it('renders saved view tabs once on artifact surfaces', () => {
    render(
      <ArtifactViewTabs
        artifact={artifact({
          views: [
            { id: 'table', title: 'Table', kind: 'table' },
            { id: 'table', title: 'Duplicate Table', kind: 'table' },
            { id: 'list', title: 'List', kind: 'list' },
          ],
        })}
        content={listContent}
      />,
    )

    expect(screen.getAllByRole('tab')).toHaveLength(2)
    expect(screen.getByRole('tab', { name: 'Table' })).toBeTruthy()
    expect(screen.getByRole('tab', { name: 'List' })).toBeTruthy()
  })
})
