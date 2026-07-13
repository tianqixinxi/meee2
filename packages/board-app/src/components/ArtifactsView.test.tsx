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
} from '../types'

const apiMocks = vi.hoisted(() => ({
  fetchArtifactsPage: vi.fn(),
  fetchPlannerGraphState: vi.fn(),
  getPlannerArtifactContent: vi.fn(),
  getArtifactVersionContent: vi.fn(),
  listArtifactVersions: vi.fn(),
  proposePlannerGraphChange: vi.fn(),
}))

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return {
    ...actual,
    fetchArtifactsPage: apiMocks.fetchArtifactsPage,
    fetchPlannerGraphState: apiMocks.fetchPlannerGraphState,
    getPlannerArtifactContent: apiMocks.getPlannerArtifactContent,
    getArtifactVersionContent: apiMocks.getArtifactVersionContent,
    listArtifactVersions: apiMocks.listArtifactVersions,
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
    canvas,
    node: itemNode,
    sessionId: itemNode?.sessionId ?? null,
    artifacts,
  }
}

function artifactGroup(item: ArtifactPageItem): string {
  const kind = item.artifacts[0]?.kind
  if (kind === 'prd' || kind === 'lark-doc') return 'docs'
  if (kind === 'kanban' || kind === 'idea-draft') return 'boards'
  if (kind === 'impl-pr' || kind === 'main-merge') return 'implementation'
  if (kind === 'check-result' || kind === 'prerelease-verdict') return 'validation'
  return 'files-data'
}

function artifactPage(
  items: ArtifactPageItem[],
  params: ArtifactPageParams,
  _legacyItems: unknown[] = [],
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
      ].filter(Boolean).join(' ').toLowerCase()
      if (!haystack.includes(params.query.toLowerCase())) return false
    }
    return true
  })
  if (params.status === 'needs-review') {
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
    payload_inline: { type: 'markdown', preview: 'Historical release plan' },
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
    vi.clearAllMocks()
    apiMocks.fetchArtifactsPage.mockImplementation((params: ArtifactPageParams) => Promise.resolve(
      artifactPage(formalPageItems(), params),
    ))
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
    apiMocks.getArtifactVersionContent.mockResolvedValue({
      artifactId: 'prd-v1',
      type: 'text',
      mimeType: 'text/plain',
      content: 'Historical file body',
    })
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
    expect(screen.queryByRole('complementary', { name: 'Artifact detail' })).not.toBeInTheDocument()
    expect(screen.queryByRole('dialog', { name: 'Artifact content preview' })).not.toBeInTheDocument()
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

  it('opens a focused artifact preview and dispatches the source target', async () => {
    const opened: unknown[] = []
    const handler = (event: Event) => opened.push((event as CustomEvent).detail)
    window.addEventListener('meee2:open-board-target', handler)
    try {
      renderView()

      fireEvent.click(await screen.findByRole('button', { name: /Release PRD/ }))
      const preview = await screen.findByRole('dialog', { name: 'Artifact content preview' })
      expect(within(preview).getByText('Internal release plan and ownership')).toBeInTheDocument()
      fireEvent.click(within(preview).getByRole('button', { name: /Reveal source/ }))

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

  it('debounces search requests instead of fetching on every keystroke', async () => {
    renderView()
    await screen.findAllByText('Release PRD')
    apiMocks.fetchArtifactsPage.mockClear()

    const search = screen.getByPlaceholderText(/Search title/)
    fireEvent.change(search, { target: { value: 'g' } })
    fireEvent.change(search, { target: { value: 'gi' } })
    fireEvent.change(search, { target: { value: 'github' } })

    await waitFor(() => expect(apiMocks.fetchArtifactsPage).toHaveBeenCalledTimes(1))
    expect(apiMocks.fetchArtifactsPage).toHaveBeenCalledWith(expect.objectContaining({ query: 'github' }))
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

  it('creates a review proposal from the artifact preview actions', async () => {
    renderView()

    await screen.findAllByText('Release PRD')
    fireEvent.change(screen.getByLabelText(/State/), { target: { value: 'needs-review' } })
    fireEvent.click(await screen.findByRole('button', { name: /Release PRD/ }))
    const preview = await screen.findByRole('dialog', { name: 'Artifact content preview' })
    fireEvent.click(within(preview).getByRole('button', { name: /Approve/ }))

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

  it('opens typed artifact content directly in the unified preview', async () => {
    renderView()

    fireEvent.click(await screen.findByRole('button', { name: /Release PRD/ }))

    const modal = await screen.findByRole('dialog', { name: 'Artifact content preview' })
    expect(within(modal).getByText('Internal release plan and ownership')).toBeInTheDocument()
    expect(within(modal).queryByText('Preview support')).not.toBeInTheDocument()
  })

  it('switches historical versions inside the same preview surface', async () => {
    renderView()

    fireEvent.click(await screen.findByRole('button', { name: /Release PRD/ }))
    const modal = await screen.findByRole('dialog', { name: 'Artifact content preview' })
    fireEvent.change(within(modal).getByLabelText('Version'), { target: { value: 'v1' } })

    expect(await within(modal).findByText('Historical release plan')).toBeInTheDocument()
    expect(apiMocks.getArtifactVersionContent).not.toHaveBeenCalled()
  })

  it('loads historical file content instead of rendering only blob metadata', async () => {
    const historicalFile: PlannerArtifactVersion = {
      ...versions[1],
      version_id: 'v-file',
      payload_inline: {
        type: 'file',
        blobRef: 'meee2-artifact://monitor/prd-v2/archive.md',
        filename: 'archive.md',
      },
    }
    apiMocks.listArtifactVersions.mockResolvedValueOnce({ versions: [versions[0], historicalFile] })
    renderView()

    fireEvent.click(await screen.findByRole('button', { name: /Release PRD/ }))
    const modal = await screen.findByRole('dialog', { name: 'Artifact content preview' })
    fireEvent.change(within(modal).getByLabelText('Version'), { target: { value: 'v-file' } })

    expect(await within(modal).findByText('Historical file body')).toBeInTheDocument()
    expect(apiMocks.getArtifactVersionContent).toHaveBeenCalledWith('monitor', 'v-file')
  })

  it('renders legacy JSON payloads with semantic type as structured previews', async () => {
    renderView()

    await screen.findAllByText('Release PRD')
    fireEvent.change(screen.getByLabelText(/Scope/), { target: { value: 'team' } })
    fireEvent.click(await screen.findByRole('button', { name: /Boards 1/ }))

    fireEvent.click(await screen.findByRole('button', { name: /Legacy Kanban Payload/ }))

    const modal = await screen.findByRole('dialog', { name: 'Artifact content preview' })
    expect(await within(modal).findByText('已生成')).toBeInTheDocument()
    expect(await within(modal).findByText('Render typed preview')).toBeInTheDocument()
    expect(within(modal).queryByText(/"columns"/)).not.toBeInTheDocument()
  })

  it('shows a recoverable preview error when remote content loading fails', async () => {
    apiMocks.getPlannerArtifactContent
      .mockRejectedValueOnce(new Error('preview service unavailable'))
      .mockResolvedValueOnce({
        artifactId: 'legacy-kanban',
        type: 'text',
        mimeType: 'text/plain',
        content: 'Recovered preview content',
      })
    renderView()

    await screen.findAllByText('Release PRD')
    fireEvent.change(screen.getByLabelText(/Scope/), { target: { value: 'team' } })
    fireEvent.click(await screen.findByRole('button', { name: /Boards 1/ }))
    fireEvent.click(await screen.findByRole('button', { name: /Legacy Kanban Payload/ }))

    const modal = await screen.findByRole('dialog', { name: 'Artifact content preview' })
    expect(await within(modal).findByText('Could not load this preview')).toBeInTheDocument()
    fireEvent.click(within(modal).getByRole('button', { name: 'Retry' }))
    expect(await within(modal).findByText('Recovered preview content')).toBeInTheDocument()
  })

  it('does not render payload content until the unified preview is opened', async () => {
    renderView()

    await screen.findAllByText('Release PRD')
    fireEvent.change(screen.getByLabelText(/Scope/), { target: { value: 'team' } })

    expect(screen.queryByText(/SHOULD_NOT_APPEAR_IN_DETAIL/)).not.toBeInTheDocument()
    fireEvent.click(await screen.findByRole('button', { name: /Team Review Notes/ }))

    const modal = await screen.findByRole('dialog', { name: 'Artifact content preview' })
    expect(within(modal).getByText(/SHOULD_NOT_APPEAR_IN_DETAIL/)).toBeInTheDocument()
  })
})
