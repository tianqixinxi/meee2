import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { I18nProvider } from '../lib/i18n'
import { ArtifactsView } from './ArtifactsView'
import type { CanvasInfo, PlannerArtifact, PlannerArtifactVersion, PlanningNode } from '../types'

const apiMocks = vi.hoisted(() => ({
  fetchPlannerGraphState: vi.fn(),
  getPlannerArtifactContent: vi.fn(),
  listArtifactVersions: vi.fn(),
  getArtifactVersion: vi.fn(),
}))

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return {
    ...actual,
    fetchPlannerGraphState: apiMocks.fetchPlannerGraphState,
    getPlannerArtifactContent: apiMocks.getPlannerArtifactContent,
    listArtifactVersions: apiMocks.listArtifactVersions,
    getArtifactVersion: apiMocks.getArtifactVersion,
  }
})

const canvases: CanvasInfo[] = [
  {
    id: 'monitor',
    name: 'Monitor',
    scope: 'personal',
    kind: 'monitor',
    isDefault: true,
    workspacePath: '/repo',
  },
  {
    id: 'release',
    name: 'Release Canvas',
    scope: 'personal',
    kind: 'board',
    isDefault: false,
    workspacePath: '/repo/release',
  },
]

const node: PlanningNode = {
  id: 'release-node',
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
    nodeId: input.nodeId ?? 'release-node',
    kind: input.kind,
    title: input.title ?? input.id,
    reference: input.reference ?? `${input.id}.md`,
    status: input.status ?? 'done',
    createdAt: input.createdAt ?? '2026-06-03T10:00:00Z',
    typedPayload: input.typedPayload,
    payload: input.payload,
    reviewStatus: input.reviewStatus,
    positionTag: input.positionTag,
  }
}

const versions: PlannerArtifactVersion[] = [
  {
    version_id: 'v2',
    parent_version_id: 'v1',
    canvas_id: 'monitor',
    node_id: 'release-node',
    artifact_id: 'prd-v2',
    artifact_slot_key: 'release-prd',
    payload_ref: 'payload://release-v2',
    display_strategy: 'latest',
    force_new_version: false,
    submitted_by: 'codex',
    submitted_by_kind: 'agent',
    created_at: '2026-06-03T10:00:00Z',
  },
  {
    version_id: 'v1',
    canvas_id: 'monitor',
    node_id: 'release-node',
    artifact_id: 'prd-v1',
    artifact_slot_key: 'release-prd',
    payload_ref: 'payload://release-v1',
    display_strategy: 'latest',
    force_new_version: false,
    submitted_by: 'kai',
    submitted_by_kind: 'human',
    created_at: '2026-06-02T10:00:00Z',
  },
]

function renderView() {
  const onOpenCanvas = vi.fn()
  render(
    <I18nProvider>
      <ArtifactsView canvases={canvases} activeCanvasId="monitor" onOpenCanvas={onOpenCanvas} />
    </I18nProvider>,
  )
  return { onOpenCanvas }
}

describe('ArtifactsView global index', () => {
  beforeEach(() => {
    apiMocks.fetchPlannerGraphState.mockImplementation((canvasId: string) => Promise.resolve({
      canvas: { id: canvasId, ownerId: 'kai', title: canvasId, plannerContext: '' },
      nodes: [node],
      states: [],
      proposals: [],
      events: [],
      edges: [],
      artifacts: canvasId === 'monitor'
        ? [
          artifact({
            id: 'prd-v1',
            kind: 'prd',
            title: 'Release PRD',
            reference: 'release.md',
            createdAt: '2026-06-02T10:00:00Z',
            reviewStatus: 'approved',
          }),
          artifact({
            id: 'prd-v2',
            kind: 'prd',
            title: 'Release PRD',
            reference: 'release.md',
            createdAt: '2026-06-03T10:00:00Z',
            reviewStatus: 'pending',
            typedPayload: {
              type: 'prd',
              reviewStatus: 'pending',
              tldr: 'Internal release plan and ownership',
              sections: [{ heading: 'Milestones', lines: 4 }],
            },
          }),
          artifact({
            id: 'smoke',
            kind: 'check-result',
            title: 'Smoke Test',
            reference: 'smoke.json',
            createdAt: '2026-06-01T10:00:00Z',
            typedPayload: {
              type: 'check-result',
              pass: 10,
              fail: 1,
              skip: 0,
              failing: ['web smoke'],
            },
          }),
        ]
        : [
          artifact({
            id: 'pr',
            canvasId,
            kind: 'impl-pr',
            title: 'GitHub PR #128',
            reference: 'https://github.com/example/repo/pull/128',
            createdAt: '2026-06-03T09:00:00Z',
            typedPayload: {
              type: 'impl-pr',
              number: 128,
              branch: 'feat/artifacts',
              baseBranch: 'main',
              filesChanged: 5,
              insertions: 200,
              deletions: 20,
              ciStatus: 'running',
              reviewers: ['Kai'],
            },
          }),
        ],
    }))
    apiMocks.getPlannerArtifactContent.mockResolvedValue({
      artifactId: 'legacy',
      type: 'text',
      mimeType: 'text/plain',
      content: 'legacy preview',
    })
    apiMocks.listArtifactVersions.mockResolvedValue({ versions })
    apiMocks.getArtifactVersion.mockResolvedValue(versions[0])
  })

  it('renders type counts and switches the index by semantic group', async () => {
    renderView()

    expect(await screen.findByRole('button', { name: /Docs 1/ })).toBeInTheDocument()
    expect(await screen.findByText('Internal release plan and ownership')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Implementation 1/ })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Validation 1/ })).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: /Implementation 1/ }))

    const list = screen.getByRole('region', { name: 'Artifact index list' })
    await waitFor(() => {
      expect(within(list).getByText('GitHub PR #128')).toBeInTheDocument()
      expect(screen.queryByText('Release PRD')).not.toBeInTheDocument()
    })
  })

  it('shows selected artifact detail and dispatches open-in-canvas target', async () => {
    const opened: unknown[] = []
    const handler = (event: Event) => opened.push((event as CustomEvent).detail)
    window.addEventListener('meee2:open-board-target', handler)
    try {
      renderView()

      await screen.findAllByText('Release PRD')
      expect(await screen.findByText('Internal release plan and ownership')).toBeInTheDocument()
      expect((await screen.findAllByText('payload://release-v2')).length).toBeGreaterThan(0)

      const detail = screen.getByRole('complementary', { name: 'Artifact detail' })
      fireEvent.click(within(detail).getByRole('button', { name: /Open in Canvas/ }))

      expect(opened).toEqual([
        expect.objectContaining({
          kind: 'planner-artifact',
          canvasId: 'monitor',
          nodeId: 'release-node',
          artifactId: 'prd-v2',
        }),
      ])
    } finally {
      window.removeEventListener('meee2:open-board-target', handler)
    }
  })

  it('filters by review status and search text', async () => {
    renderView()

    await screen.findAllByText('Release PRD')
    fireEvent.change(screen.getByLabelText(/Review/), { target: { value: 'pending' } })
    expect(screen.getAllByText('Release PRD').length).toBeGreaterThan(0)
    expect(screen.queryByText('Smoke Test')).not.toBeInTheDocument()

    fireEvent.change(screen.getByPlaceholderText(/Search title/), { target: { value: 'github' } })
    await waitFor(() => {
      expect(screen.queryByText('Release PRD')).not.toBeInTheDocument()
    })
  })
})
