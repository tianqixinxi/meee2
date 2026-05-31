import { fireEvent, render, screen, waitFor } from '@testing-library/react'
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

describe('WorkspaceMonitor density modes', () => {
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
      }],
    })
  })

  it('uses compact for scan-only fields and comfortable for diagnostic context', async () => {
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
    expect(screen.getByText('blocked')).toBeInTheDocument()
    expect(screen.getByText('3 evidence')).toBeInTheDocument()
    expect(screen.getByText('2/4 nodes')).toBeInTheDocument()
    expect(screen.queryByText('member-a')).not.toBeInTheDocument()
    expect(screen.queryByText('AI recap says owner needs updated evidence before publishing.')).not.toBeInTheDocument()
    expect(screen.queryByText('Missing source links')).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Comfortable' }))

    await waitFor(() => {
      expect(screen.getByText('member-a')).toBeInTheDocument()
    })
    expect(screen.getByText('Recap')).toBeInTheDocument()
    expect(screen.getByText('AI recap says owner needs updated evidence before publishing.')).toBeInTheDocument()
    expect(screen.getByText('Attention')).toBeInTheDocument()
    expect(screen.getByText('Missing source links')).toBeInTheDocument()
    expect(screen.getByText('Open item')).toBeInTheDocument()
  })
})
