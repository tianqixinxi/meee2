import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { ComponentProps } from 'react'
import { I18nProvider } from '../lib/i18n'
import { TemplatesView } from './TemplatesView'

const apiMocks = vi.hoisted(() => ({
  fetchCanvasTemplates: vi.fn(),
  fetchTemplateCatalog: vi.fn(),
  fetchClaudeWorkflows: vi.fn(),
  fetchTeamMembers: vi.fn(),
}))

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return {
    ...actual,
    fetchCanvasTemplates: apiMocks.fetchCanvasTemplates,
    fetchTemplateCatalog: apiMocks.fetchTemplateCatalog,
    fetchClaudeWorkflows: apiMocks.fetchClaudeWorkflows,
    fetchTeamMembers: apiMocks.fetchTeamMembers,
  }
})

vi.mock('./planner/PlannerGraph', () => ({
  PlannerGraph: () => null,
}))

function renderView(overrides: Partial<ComponentProps<typeof TemplatesView>> = {}) {
  const props: ComponentProps<typeof TemplatesView> = {
    canvases: [],
    activeCanvasId: 'canvas-1',
    userProfile: null,
    boardState: null,
    onOpenCanvas: vi.fn(),
    onApplyTemplate: vi.fn(),
    onCreateTemplateDraft: vi.fn().mockResolvedValue('draft-canvas'),
    onReplaceTemplate: vi.fn().mockResolvedValue('template-canvas'),
    onUpdateTemplateMetadata: vi.fn().mockResolvedValue('template-canvas'),
    onImportClaudeWorkflow: vi.fn().mockResolvedValue('imported-canvas'),
    onUploadClaudeWorkflow: vi.fn().mockResolvedValue('uploaded-canvas'),
    ...overrides,
  }
  render(
    <I18nProvider>
      <TemplatesView {...props} />
    </I18nProvider>,
  )
  return props
}

describe('TemplatesView Claude Code workflow imports', () => {
  beforeEach(() => {
    apiMocks.fetchTeamMembers.mockResolvedValue({ members: [] })
    apiMocks.fetchCanvasTemplates.mockResolvedValue([])
    apiMocks.fetchTemplateCatalog.mockResolvedValue({ templates: [], tags: ['engineering', 'release', 'ops'] })
    apiMocks.fetchClaudeWorkflows.mockResolvedValue({
      root: '/Users/kai/.claude/workflows',
      workflows: [],
      error: null,
    })
  })

  it('renders empty global workflow state with scan root', async () => {
    renderView()

    expect(await screen.findByText('Claude Code workflows')).toBeInTheDocument()
    expect(screen.getByText('/Users/kai/.claude/workflows')).toBeInTheDocument()
    expect(screen.getByText(/No global/)).toBeInTheDocument()
  })

  it('opens import modal and calls import callback', async () => {
    apiMocks.fetchClaudeWorkflows.mockResolvedValue({
      root: '/Users/kai/.claude/workflows',
      workflows: [
        {
          id: 'global:abc',
          name: 'deep-research',
          commandName: '/deep-research',
          description: 'Run a focused deep research workflow',
          phases: [
            { title: 'Plan', detail: 'Define research question' },
            { title: 'Collect', detail: 'Gather sources' },
            { title: 'Report', detail: 'Summarize findings' },
          ],
          path: '/Users/kai/.claude/workflows/deep-research.js',
          sizeBytes: 128,
          modifiedAt: '2026-05-31T00:00:00Z',
          preview: 'export default async function workflow() {}',
          readable: true,
          error: null,
        },
      ],
      error: null,
    })
    const onImportClaudeWorkflow = vi.fn().mockResolvedValue('canvas-imported')
    renderView({ onImportClaudeWorkflow })

    expect(await screen.findByText('deep-research')).toBeInTheDocument()
    expect(screen.getByText('Run a focused deep research workflow')).toBeInTheDocument()
    expect(screen.getByText('Plan')).toBeInTheDocument()
    expect(screen.getByText('Collect')).toBeInTheDocument()
    expect(screen.getByText('Report')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Import' }))
    expect(screen.getByRole('dialog', { name: /Import \/deep-research/ })).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Import workflow' }))

    await waitFor(() => {
      expect(onImportClaudeWorkflow).toHaveBeenCalledWith('global:abc', 'deep-research', 'personal')
    })
  })

  it('uploads a workflow js file and calls upload callback', async () => {
    const onUploadClaudeWorkflow = vi.fn().mockResolvedValue('canvas-uploaded')
    renderView({ onUploadClaudeWorkflow })

    await screen.findByText('Claude Code workflows')
    const input = document.querySelector<HTMLInputElement>('input[type="file"]')
    expect(input).not.toBeNull()
    const file = new File(['export default async () => {}'], 'uploaded-flow.js', { type: 'text/javascript' })
    Object.defineProperty(file, 'text', {
      value: vi.fn().mockResolvedValue('export default async () => {}'),
    })
    fireEvent.change(input!, { target: { files: [file] } })

    expect(await screen.findByRole('dialog', { name: /Import \/uploaded-flow/ })).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Import workflow' }))

    await waitFor(() => {
      expect(onUploadClaudeWorkflow).toHaveBeenCalledWith(
        'uploaded-flow.js',
        'export default async () => {}',
        'uploaded-flow',
        'personal',
      )
    })
  })

  it('filters catalog templates by source and tags', async () => {
    apiMocks.fetchTemplateCatalog.mockResolvedValue({
      tags: ['engineering', 'release', 'ops'],
      templates: [
        {
          id: 'official-release',
          name: 'Release Checklist',
          description: 'Ship safely',
          icon: 'rocket',
          source: 'official',
          kind: 'board',
          defaultCanvasKind: 'board',
          category: 'official',
          tags: ['engineering', 'release'],
          ownerUserId: null,
          ownerName: 'Meee2',
          version: 1,
          readOnly: true,
          canEdit: false,
          canReplace: false,
          defaultNodesCount: 3,
          updatedAt: null,
          defaultNodes: [],
        },
        {
          id: 'team-ops',
          name: 'Ops Tower',
          description: 'Team view',
          icon: 'users',
          source: 'team',
          kind: 'board',
          defaultCanvasKind: 'board',
          category: 'team',
          tags: ['ops'],
          ownerUserId: 'owner-a',
          ownerName: 'Alice',
          version: 2,
          readOnly: false,
          canEdit: false,
          canReplace: false,
          defaultNodesCount: 1,
          updatedAt: null,
          defaultNodes: [],
        },
      ],
    })
    renderView()

    expect(await screen.findByText('Release Checklist')).toBeInTheDocument()
    expect(screen.queryByText('Ops Tower')).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('tab', { name: /Team/ }))
    expect(await screen.findByText('Ops Tower')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'ops' }))
    expect(screen.getByText('Ops Tower')).toBeInTheDocument()
  })

  it('previews a template canvas without applying it', async () => {
    const onApplyTemplate = vi.fn().mockResolvedValue('new-canvas')
    apiMocks.fetchTemplateCatalog.mockResolvedValue({
      tags: ['engineering'],
      templates: [
        {
          id: 'official-release',
          name: 'Release Checklist',
          description: 'Ship safely',
          icon: 'rocket',
          source: 'official',
          kind: 'board',
          defaultCanvasKind: 'board',
          category: 'official',
          tags: ['engineering'],
          ownerUserId: null,
          ownerName: 'Meee2',
          version: 1,
          readOnly: true,
          canEdit: false,
          canReplace: false,
          defaultNodesCount: 2,
          updatedAt: null,
          defaultNodes: [],
          renderObjects: [
            {
              id: 'node:a',
              label: 'Run CI suite',
              entityRef: { kind: 'node', id: 'a', nodeId: 'a' },
              renderer: 'card',
              values: { x: 0, y: 0, width: 240, height: 120 },
            },
            {
              id: 'node:b',
              label: 'Tag release',
              entityRef: { kind: 'node', id: 'b', nodeId: 'b' },
              renderer: 'card',
              values: { x: 300, y: 0, width: 240, height: 120 },
            },
          ],
          renderRelations: [
            {
              id: 'dep:a:b',
              kind: 'dependency',
              source: { objectId: 'node:a' },
              target: { objectId: 'node:b' },
              renderer: 'directed-edge',
            },
          ],
        },
      ],
    })
    renderView({ onApplyTemplate })

    expect(await screen.findByText('Release Checklist')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Preview template Release Checklist' }))

    expect(screen.getByRole('dialog', { name: /Preview - Release Checklist/ })).toBeInTheDocument()
    expect(screen.getByText('Run CI suite')).toBeInTheDocument()
    expect(screen.getByText('Tag release')).toBeInTheDocument()
    expect(onApplyTemplate).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole('button', { name: 'Use template' }))
    expect(screen.getByRole('dialog', { name: /Use template - Release Checklist/ })).toBeInTheDocument()
    expect(onApplyTemplate).not.toHaveBeenCalled()
  })

  it('shows owner-gated team template editing', async () => {
    apiMocks.fetchTemplateCatalog.mockResolvedValue({
      tags: ['ops'],
      templates: [
        {
          id: 'team-ops',
          name: 'Ops Tower',
          description: 'Team view',
          icon: 'users',
          source: 'team',
          kind: 'board',
          defaultCanvasKind: 'board',
          category: 'team',
          tags: ['ops'],
          ownerUserId: 'owner-a',
          ownerName: 'Alice',
          version: 2,
          readOnly: false,
          canEdit: false,
          canReplace: false,
          defaultNodesCount: 1,
          updatedAt: null,
          defaultNodes: [],
        },
      ],
    })
    renderView()

    fireEvent.click(await screen.findByRole('tab', { name: /Team/ }))
    expect(await screen.findByText('Ops Tower')).toBeInTheDocument()
    expect(screen.getByText('Alice')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Edit draft' })).toBeDisabled()
  })

  it('keeps template creation out of the catalog header', async () => {
    renderView()

    await screen.findByText('Claude Code workflows')
    expect(screen.queryByRole('button', { name: 'Save current' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Blank template' })).not.toBeInTheDocument()
  })
})
