import { render, screen } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { I18nProvider } from '../../lib/i18n'
import { WorkspaceMonitor } from './WorkspaceMonitor'

const apiMocks = vi.hoisted(() => ({
  fetchPlannerWorkspaceMonitor: vi.fn(),
}))

vi.mock('../../api', async () => {
  const actual = await vi.importActual<typeof import('../../api')>('../../api')
  return {
    ...actual,
    fetchPlannerWorkspaceMonitor: apiMocks.fetchPlannerWorkspaceMonitor,
  }
})

const canvas = {
  id: 'canvas-1',
  name: 'Launch Monitor',
  scope: 'personal' as const,
  kind: 'board' as const,
  isDefault: false,
  workspacePath: '',
  ownerUserId: 'owner-user',
  teamId: null,
}

describe('WorkspaceMonitor comfortable view', () => {
  beforeEach(() => {
    apiMocks.fetchPlannerWorkspaceMonitor.mockResolvedValue({
      generatedAt: '2026-05-31T05:00:00.000Z',
      items: [{
        id: 'monitor-node-1',
        kind: 'node',
        canvasId: 'canvas-1',
        canvasTitle: 'Launch Monitor',
        nodeId: 'node-1',
        nodeTitle: 'Research launch sentiment',
        sessionId: null,
        deliveryId: null,
        proposalId: null,
        proposalStatus: null,
        summary: 'AI recap says owner needs updated evidence before publishing.',
        runState: 'blocked',
        blockers: ['Missing source links'],
        needsOwnerReview: true,
        doerId: 'member-a',
        riskRank: 0,
        evidenceCount: 3,
        updatedAt: '2026-05-31T04:45:00.000Z',
        nextAction: '2/4 nodes',
        awaitingInputSince: '2026-05-31T03:45:00.000Z',
      }, {
        id: 'monitor-node-placeholder',
        kind: 'node',
        canvasId: 'canvas-1',
        canvasTitle: 'Launch Monitor',
        nodeId: 'node-placeholder',
        nodeTitle: 'Placeholder blocker node',
        sessionId: null,
        deliveryId: null,
        proposalId: null,
        proposalStatus: null,
        summary: 'Blocked without a useful reason.',
        runState: 'blocked',
        blockers: ['Blocked: no reason was provided by the session.'],
        needsOwnerReview: false,
        doerId: null,
        riskRank: 0,
        evidenceCount: 0,
        updatedAt: '2026-05-31T04:30:00.000Z',
        nextAction: '1/2 nodes',
        awaitingInputSince: null,
      }],
    })
  })

  it('renders comfortable diagnostic fields without a density switcher', async () => {
    render(
      <I18nProvider>
        <WorkspaceMonitor
          activeCanvasId="canvas-1"
          canvases={[canvas]}
          refreshTick={0}
          onOpenItem={vi.fn()}
          onOpenAllSessions={vi.fn()}
        />
      </I18nProvider>,
    )

    expect(await screen.findByText('Research launch sentiment')).toBeInTheDocument()
    expect(screen.getAllByText('Launch Monitor').length).toBeGreaterThan(0)
    expect(screen.getAllByText('blocked').length).toBeGreaterThan(0)
    expect(screen.getByText('3 evidence')).toBeInTheDocument()
    expect(screen.getByText('2/4 nodes')).toBeInTheDocument()
    expect(screen.getByText('member-a')).toBeInTheDocument()
    expect(screen.getAllByText('Recap').length).toBeGreaterThan(0)
    expect(screen.getByText('AI recap says owner needs updated evidence before publishing.')).toBeInTheDocument()
    expect(screen.getByText('Attention')).toBeInTheDocument()
    expect(screen.getByText('Missing source links')).toBeInTheDocument()
    expect(screen.getAllByText('Open item').length).toBeGreaterThan(0)
    expect(screen.getByText('Placeholder blocker node')).toBeInTheDocument()
    expect(screen.queryByText('Blocked: no reason was provided by the session.')).not.toBeInTheDocument()
    expect(screen.queryByRole('group', { name: 'Density' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Compact' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Comfortable' })).not.toBeInTheDocument()
  })

  it('keeps meee2 AI controls outside the monitor table toolbar', async () => {
    render(
      <I18nProvider>
        <WorkspaceMonitor
          activeCanvasId="canvas-1"
          canvases={[canvas]}
          refreshTick={0}
          onOpenItem={vi.fn()}
          onOpenAllSessions={vi.fn()}
        />
      </I18nProvider>,
    )

    await screen.findByText('Research launch sentiment')
    expect(screen.queryByRole('button', { name: /meee2 AI/ })).not.toBeInTheDocument()
  })
})
