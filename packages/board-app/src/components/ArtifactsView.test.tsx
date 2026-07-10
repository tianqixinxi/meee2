import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import type { ComponentProps } from 'react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { I18nProvider } from '../lib/i18n'
import { ArtifactsView } from './ArtifactsView'
import type { ArtifactPageParams } from '../api'
import type {
  ArtifactPageEnvelope,
  ArtifactPageItem,
  CanvasInfo,
  PlannerArtifact,
  PlannerArtifactVersion,
  PlanningNode,
  SessionArtifactCandidate,
} from '../types'

const apiMocks = vi.hoisted(() => ({
  fetchArtifactsPage: vi.fn(),
  fetchPlannerGraphState: vi.fn(),
  fetchArtifactCandidates: vi.fn(),
  getPlannerArtifactContent: vi.fn(),
  listArtifactVersions: vi.fn(),
  getArtifactVersion: vi.fn(),
  proposePlannerGraphChange: vi.fn(),
}))

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return {
    ...actual,
    fetchArtifactsPage: apiMocks.fetchArtifactsPage,
    fetchPlannerGraphState: apiMocks.fetchPlannerGraphState,
    fetchArtifactCandidates: apiMocks.fetchArtifactCandidates,
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

function pageItem(
  canvas: CanvasInfo,
  artifacts: PlannerArtifact[],
  itemNode: PlanningNode | null,
): ArtifactPageItem {
  return {
    sourceKind: 'artifact',
    canvas,
    node: itemNode,
    sessionId: itemNode?.sessionId ?? null,
    artifacts,
    candidate: null,
  }
}

function candidatePageItem(candidate: SessionArtifactCandidate): ArtifactPageItem {
  return {
    sourceKind: 'candidate',
    canvas: {
      id: `session:${candidate.sessionId}`,
      name: 'Session',
      scope: 'personal',
      kind: 'monitor',
      isDefault: false,
      workspacePath: candidate.cwd ?? '',
    },
    node: null,
    sessionId: candidate.sessionId,
    artifacts: [],
    candidate,
  }
}

function artifactGroup(item: ArtifactPageItem): string {
  const kind = item.artifacts[0]?.kind ?? item.candidate?.kind
  if (kind === 'prd' || kind === 'lark-doc') return 'docs'
  if (kind === 'kanban' || kind === 'idea-draft') return 'boards'
  if (kind === 'impl-pr' || kind === 'main-merge') return 'implementation'
  if (kind === 'check-result' || kind === 'prerelease-verdict') return 'validation'
  return 'files-data'
}

function artifactPage(
  items: ArtifactPageItem[],
  params: ArtifactPageParams,
  candidates: SessionArtifactCandidate[],
): ArtifactPageEnvelope {
  const sessionIds = new Set(params.sessionId?.split(',').map((value) => value.toLowerCase()) ?? [])
  const project = params.project?.toLowerCase()
  let filtered = items.filter((item) => {
    if (params.canvasId && item.canvas.id !== params.canvasId) return false
    if (params.scope && params.scope !== 'all' && item.canvas.scope !== params.scope) return false
    if (params.group && params.group !== 'all' && artifactGroup(item) !== params.group) return false
    if (sessionIds.size || project) {
      const sessionMatch = item.sessionId ? sessionIds.has(item.sessionId.toLowerCase()) : false
      const projectMatch = project
        ? [item.canvas.id, item.canvas.name, item.canvas.workspacePath]
          .some((value) => value.toLowerCase().includes(project))
        : false
      if (!sessionMatch && !projectMatch) return false
    }
    if (params.query) {
      const haystack = [
        item.canvas.name,
        item.node?.title,
        item.artifacts[0]?.title,
        item.artifacts[0]?.reference,
        item.candidate?.title,
      ].filter(Boolean).join(' ').toLowerCase()
      if (!haystack.includes(params.query.toLowerCase())) return false
    }
    return true
  })
  if (params.status === 'candidate') {
    filtered = candidates.map(candidatePageItem).filter((item) => {
      if (!sessionIds.size && !project) return true
      return (item.sessionId ? sessionIds.has(item.sessionId.toLowerCase()) : false)
        || Boolean(project && item.canvas.workspacePath.toLowerCase().includes(project))
    })
  } else if (params.status === 'needs-review') {
    const prd = filtered.find((item) => item.artifacts[0]?.reference === 'release.md')
    filtered = prd ? [{
      ...prd,
      artifacts: prd.artifacts.map((value, index) => index === 0 ? { ...value, reviewStatus: 'pending' } : value),
    }] : []
  }
  const groupCounts = {
    docs: 0,
    boards: 0,
    implementation: 0,
    validation: 0,
    'files-data': 0,
    other: 0,
  }
  for (const item of filtered) groupCounts[artifactGroup(item) as keyof typeof groupCounts] += 1
  const offset = Number(params.cursor ?? '0')
  const limit = params.limit ?? 50
  const pageItems = filtered.slice(offset, offset + limit)
  const end = offset + pageItems.length
  return {
    items: pageItems,
    cursor: end < filtered.length ? String(end) : null,
    total: filtered.length,
    hasMore: end < filtered.length,
    candidateTotal: candidates.length,
    canvasCount: new Set(filtered.map((item) => item.canvas.id)).size,
    groupCounts,
  }
}

function formalPageItems(): ArtifactPageItem[] {
  const monitorNode = { ...node, sessionId: 'session-a' }
  const prdArtifacts = [
    artifact({
      id: 'prd-v2',
      kind: 'prd',
      title: 'Release PRD',
      reference: 'release.md',
      createdAt: '2026-06-03T10:00:00Z',
      reviewStatus: 'approved',
      typedPayload: {
        type: 'prd',
        reviewStatus: 'approved',
        tldr: 'Internal release plan and ownership',
        sections: [{ heading: 'Milestones', lines: 4 }],
      },
    }),
    artifact({
      id: 'prd-v1',
      kind: 'prd',
      title: 'Release PRD',
      reference: 'release.md',
      createdAt: '2026-06-02T10:00:00Z',
      reviewStatus: 'approved',
    }),
  ]
  return [
    pageItem(canvases[0], prdArtifacts, monitorNode),
    pageItem(canvases[0], [artifact({
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
    })], smokeNode),
    pageItem(canvases[1], [artifact({
      id: 'pr',
      canvasId: 'release',
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
    })], { ...node, canvasId: 'release', sessionId: 'session-other' }),
    pageItem(canvases[2], [artifact({
      id: 'team-doc',
      canvasId: 'team-canvas',
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
    })], { ...node, canvasId: 'team-canvas', sessionId: 'session-other' }),
    pageItem(canvases[2], [artifact({
      id: 'legacy-kanban',
      canvasId: 'team-canvas',
      kind: 'kanban',
      title: 'Legacy Kanban Payload',
      reference: 'legacy-kanban.json',
      createdAt: '2026-06-03T07:00:00Z',
    })], { ...node, canvasId: 'team-canvas', sessionId: 'session-other' }),
  ]
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

const candidateFixtures: SessionArtifactCandidate[] = []

describe('ArtifactsView global index', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    candidateFixtures.splice(0)
    apiMocks.fetchArtifactsPage.mockImplementation((params: ArtifactPageParams) => Promise.resolve(
      artifactPage(formalPageItems(), params, candidateFixtures),
    ))
    apiMocks.fetchArtifactCandidates.mockResolvedValue({ candidates: [] })
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

    const list = await screen.findByRole('region', { name: 'Artifact index list' })
    await waitFor(() => {
      expect(within(list).getByText('GitHub PR #128')).toBeInTheDocument()
      expect(screen.queryByText('Release PRD')).not.toBeInTheDocument()
    })
  })

  it('caps the mounted artifact rows and reveals additional pages on demand', async () => {
    const items = Array.from({ length: 120 }, (_, index) => pageItem(
      canvases[0],
      [artifact({
          id: `artifact-${index}`,
          kind: 'prd',
          title: `Artifact ${index}`,
          reference: `artifact-${index}.md`,
          createdAt: new Date(Date.UTC(2026, 5, 3, 10, index)).toISOString(),
      })],
      null,
    ))
    apiMocks.fetchArtifactsPage.mockImplementation((params: ArtifactPageParams) => Promise.resolve(
      artifactPage(items, params, []),
    ))

    renderView()

    const table = await screen.findByRole('table')
    expect(within(table).getAllByRole('row')).toHaveLength(51)
    expect(screen.getByText('Showing 50 of 120')).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Load 50 more' }))
    await screen.findByText('Showing 100 of 120')
    expect(within(table).getAllByRole('row').length).toBeLessThanOrEqual(61)
    expect(apiMocks.fetchPlannerGraphState).not.toHaveBeenCalled()
    expect(apiMocks.fetchArtifactsPage.mock.calls.every(([params]) => params.limit <= 50)).toBe(true)
  })

  it('keeps raw session candidates behind an explicit toggle', async () => {
    candidateFixtures.push({
        id: 'candidate-raw',
        sessionId: 'session-a',
        provider: 'codex',
        cwd: '/repo',
        title: 'Raw terminal candidate',
        kind: 'file',
        status: 'candidate',
        createdAt: '2026-06-18T00:00:00Z',
        updatedAt: '2026-06-18T00:00:00Z',
        sourceEvent: 'PostToolUse',
        toolName: 'apply_patch',
        toolUseId: 'tool-a',
        references: [],
        summary: 'Generated candidate artifact.',
    })

    renderView()

    const toggle = await screen.findByRole('button', { name: 'Raw candidates (1)' })
    expect(screen.queryByText('Raw terminal candidate')).not.toBeInTheDocument()
    fireEvent.click(toggle)
    expect(await screen.findAllByText('Raw terminal candidate')).not.toHaveLength(0)
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
    expect((await screen.findAllByText('Release PRD')).length).toBeGreaterThan(0)
    await waitFor(() => expect(screen.queryByText('Smoke Test')).not.toBeInTheDocument())

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

  it('filters session artifacts by provider resume id when the visible session id differs', async () => {
    renderView({
      sessionFilter: {
        sessionId: 'historical-session',
        providerResumeSessionId: 'session-a',
        title: '历史 Session',
      },
    })

    expect(await screen.findByText('Session: 历史 Session')).toBeInTheDocument()
    await screen.findAllByText('Release PRD')
    expect(screen.queryByText('Smoke Test')).not.toBeInTheDocument()
    expect(screen.queryByText('GitHub PR #128')).not.toBeInTheDocument()
  })

  it('falls back to project name when a session has no node-bound artifact id match', async () => {
    renderView({
      sessionFilter: {
        sessionId: 'unbound-session',
        title: 'Release project session',
        projectName: 'release',
      },
    })

    expect(await screen.findByText('Session: Release project session')).toBeInTheDocument()
    await screen.findAllByText('GitHub PR #128')
    expect(screen.queryByText('Smoke Test')).not.toBeInTheDocument()
    expect(screen.queryByText('Release PRD')).not.toBeInTheDocument()
  })

  it('creates a review proposal from the artifact detail actions', async () => {
    renderView()

    await screen.findAllByText('Release PRD')
    fireEvent.change(screen.getByLabelText(/State/), { target: { value: 'needs-review' } })
    const detail = await screen.findByRole('complementary', { name: 'Artifact detail' })
    await within(detail).findByRole('button', { name: /Approve/ })
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

    const detail = await screen.findByRole('complementary', { name: 'Artifact detail' })
    expect(await within(detail).findByRole('heading', { name: 'Team Review Notes' })).toBeInTheDocument()
    expect(within(detail).queryByText(/SHOULD_NOT_APPEAR_IN_DETAIL/)).not.toBeInTheDocument()

    fireEvent.click(within(detail).getByRole('button', { name: /Load content/ }))

    const modal = await screen.findByRole('dialog', { name: 'Artifact content preview' })
    expect(within(modal).getByText(/SHOULD_NOT_APPEAR_IN_DETAIL/)).toBeInTheDocument()
  })
})
