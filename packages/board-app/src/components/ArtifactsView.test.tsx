import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import type { ComponentProps } from 'react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { I18nProvider } from '../lib/i18n'
import { ArtifactsView } from './ArtifactsView'
import type { CanvasInfo, PlannerArtifact, PlannerArtifactVersion, PlanningNode } from '../types'

const apiMocks = vi.hoisted(() => ({
  fetchPlannerGraphState: vi.fn(),
  getPlannerArtifactContent: vi.fn(),
  listArtifactVersions: vi.fn(),
  getArtifactVersion: vi.fn(),
  proposePlannerGraphChange: vi.fn(),
}))

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return {
    ...actual,
    fetchPlannerGraphState: apiMocks.fetchPlannerGraphState,
    getPlannerArtifactContent: apiMocks.getPlannerArtifactContent,
    listArtifactVersions: apiMocks.listArtifactVersions,
    getArtifactVersion: apiMocks.getArtifactVersion,
    proposePlannerGraphChange: apiMocks.proposePlannerGraphChange,
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
  {
    id: 'team-canvas',
    name: 'Team Canvas',
    scope: 'team',
    kind: 'board',
    isDefault: false,
    workspacePath: '/repo/team',
    teamId: 'team-1',
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

const smokeNode: PlanningNode = {
  ...node,
  id: 'smoke-node',
  title: 'Smoke validation',
  sessionId: 'session-other',
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

function renderView(props: Partial<ComponentProps<typeof ArtifactsView>> = {}) {
  const onOpenCanvas = vi.fn()
  render(
    <I18nProvider>
      <ArtifactsView canvases={canvases} activeCanvasId="monitor" onOpenCanvas={onOpenCanvas} {...props} />
    </I18nProvider>,
  )
  return { onOpenCanvas }
}

describe('ArtifactsView global index', () => {
  beforeEach(() => {
    apiMocks.fetchPlannerGraphState.mockImplementation((canvasId: string) => Promise.resolve({
      canvas: { id: canvasId, ownerId: 'kai', title: canvasId, plannerContext: '' },
      nodes: canvasId === 'monitor'
        ? [
          {
            ...node,
            sessionId: 'session-a',
          },
          smokeNode,
        ]
        : [
          {
            ...node,
            canvasId,
            sessionId: 'session-other',
          },
        ],
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
            nodeId: 'smoke-node',
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
        : canvasId === 'release' ? [
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
        ] : [
          artifact({
            id: 'team-doc',
            canvasId,
            kind: 'lark-doc',
            title: 'Team Review Notes',
            reference: 'https://example.com/team-review',
            createdAt: '2026-06-03T08:00:00Z',
            typedPayload: {
              type: 'markdown',
              preview: `# Team Review
Ready for review

${'Detailed team review context. '.repeat(30)}
SHOULD_NOT_APPEAR_IN_DETAIL`,
            },
          }),
          artifact({
            id: 'legacy-kanban',
            canvasId,
            kind: 'kanban',
            title: 'Legacy Kanban Payload',
            reference: 'legacy-kanban.json',
            createdAt: '2026-06-03T07:00:00Z',
          }),
        ],
    }))
    apiMocks.getPlannerArtifactContent.mockImplementation((_canvasId: string, artifactId: string) => Promise.resolve(
      artifactId === 'legacy-kanban'
        ? {
          artifactId,
          type: 'kanban',
          mimeType: 'application/json',
          content: JSON.stringify({
            columns: [
              {
                id: 'col:todo',
                title: '待处理',
                cards: [
                  { id: 'card-1', status: 'todo', title: 'Scope fallback' },
                ],
              },
              {
                id: 'col:done',
                title: '已生成',
                cards: [
                  { id: 'card-2', status: 'done', title: 'Render typed preview' },
                ],
              },
            ],
            items: [],
            version: 6,
          }),
        }
        : {
          artifactId,
          type: 'text',
          mimeType: 'text/plain',
          content: 'legacy preview',
        },
    ))
    apiMocks.listArtifactVersions.mockResolvedValue({ versions })
    apiMocks.getArtifactVersion.mockResolvedValue(versions[0])
    apiMocks.proposePlannerGraphChange.mockResolvedValue({
      id: 'proposal-review',
      canvasId: 'monitor',
      summary: 'Approve Release PRD',
      changes: [],
      status: 'pending',
    })
  })

  it('renders type counts and switches the index by semantic group', async () => {
    renderView()

    expect(await screen.findByRole('button', { name: /Docs 2/ })).toBeInTheDocument()
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
      fireEvent.click(within(detail).getByRole('button', { name: /Reveal source/ }))

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

  it('filters by unified state and search text', async () => {
    renderView()

    await screen.findAllByText('Release PRD')
    fireEvent.change(screen.getByLabelText(/State/), { target: { value: 'needs-review' } })
    expect(screen.getAllByText('Release PRD').length).toBeGreaterThan(0)
    expect(screen.queryByText('Smoke Test')).not.toBeInTheDocument()

    fireEvent.change(screen.getByPlaceholderText(/Search title/), { target: { value: 'github' } })
    await waitFor(() => {
      expect(screen.queryByText('Release PRD')).not.toBeInTheDocument()
    })
  })

  it('filters the artifact index to one session when launched from a session', async () => {
    const onClearSessionFilter = vi.fn()
    renderView({
      sessionFilter: { sessionId: 'session-a', title: '新增 Session 原生 Terminal' },
      onClearSessionFilter,
    })

    expect(await screen.findByText('Session: 新增 Session 原生 Terminal')).toBeInTheDocument()
    await screen.findAllByText('Release PRD')
    expect(screen.queryByText('Smoke Test')).not.toBeInTheDocument()
    expect(screen.queryByText('GitHub PR #128')).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Session: 新增 Session 原生 Terminal' }))
    expect(onClearSessionFilter).toHaveBeenCalled()
  })

  it('creates a review proposal from the artifact detail actions', async () => {
    renderView()

    await screen.findAllByText('Release PRD')
    const detail = screen.getByRole('complementary', { name: 'Artifact detail' })
    fireEvent.click(within(detail).getByRole('button', { name: /Approve/ }))

    await waitFor(() => {
      expect(apiMocks.proposePlannerGraphChange).toHaveBeenCalledWith('monitor', expect.objectContaining({
        summary: 'Approve Release PRD',
        changes: [
          expect.objectContaining({
            kind: 'attachArtifact',
            nodeId: 'release-node',
            artifact: expect.objectContaining({
              reference: 'release.md',
              reviewStatus: 'approved',
            }),
          }),
        ],
      }))
    })
  })

  it('filters artifacts by personal and team scope', async () => {
    renderView()

    await screen.findAllByText('Release PRD')
    fireEvent.change(screen.getByLabelText(/Scope/), { target: { value: 'team' } })

    await waitFor(() => {
      expect(screen.getAllByText('Team Review Notes').length).toBeGreaterThan(0)
      expect(screen.queryByText('Release PRD')).not.toBeInTheDocument()
    })

    fireEvent.change(screen.getByLabelText(/Scope/), { target: { value: 'personal' } })

    await waitFor(() => {
      expect(screen.getAllByText('Release PRD').length).toBeGreaterThan(0)
      expect(screen.queryByText('Team Review Notes')).not.toBeInTheDocument()
    })
  })

  it('opens typed artifact content in a rendered modal with support notes', async () => {
    renderView()

    await screen.findAllByText('Release PRD')
    const detail = screen.getByRole('complementary', { name: 'Artifact detail' })
    fireEvent.click(within(detail).getByRole('button', { name: /Load content/ }))

    const modal = await screen.findByRole('dialog', { name: 'Artifact content preview' })
    expect(within(modal).getByText('Internal release plan and ownership')).toBeInTheDocument()
    expect(within(modal).getByText('Preview support')).toBeInTheDocument()
    expect(within(modal).getByText(/prd, kanban, impl-pr/)).toBeInTheDocument()
  })

  it('renders legacy JSON payloads with semantic type as structured previews', async () => {
    renderView()

    await screen.findAllByText('Release PRD')
    fireEvent.change(screen.getByLabelText(/Scope/), { target: { value: 'team' } })
    fireEvent.click(await screen.findByRole('button', { name: /Boards 1/ }))

    expect((await screen.findAllByText('Legacy Kanban Payload')).length).toBeGreaterThan(0)
    expect(await screen.findByText('待处理')).toBeInTheDocument()
    expect(screen.queryByText('Scope fallback')).not.toBeInTheDocument()

    const detail = screen.getByRole('complementary', { name: 'Artifact detail' })
    fireEvent.click(within(detail).getByRole('button', { name: /Load content/ }))

    const modal = await screen.findByRole('dialog', { name: 'Artifact content preview' })
    expect(within(modal).getByText('已生成')).toBeInTheDocument()
    expect(within(modal).getByText('Render typed preview')).toBeInTheDocument()
    expect(within(modal).queryByText(/"columns"/)).not.toBeInTheDocument()
  })

  it('keeps the detail preview summarized while the content modal renders the full payload', async () => {
    renderView()

    await screen.findAllByText('Release PRD')
    fireEvent.change(screen.getByLabelText(/Scope/), { target: { value: 'team' } })

    const detail = screen.getByRole('complementary', { name: 'Artifact detail' })
    expect(await within(detail).findByRole('heading', { name: 'Team Review Notes' })).toBeInTheDocument()
    expect(within(detail).queryByText(/SHOULD_NOT_APPEAR_IN_DETAIL/)).not.toBeInTheDocument()

    fireEvent.click(within(detail).getByRole('button', { name: /Load content/ }))

    const modal = await screen.findByRole('dialog', { name: 'Artifact content preview' })
    expect(within(modal).getByText(/SHOULD_NOT_APPEAR_IN_DETAIL/)).toBeInTheDocument()
  })
})
