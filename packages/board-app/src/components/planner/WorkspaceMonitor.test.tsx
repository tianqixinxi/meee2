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

describe('WorkspaceMonitor comfortable view', () => {
  beforeEach(() => {
    apiMocks.fetchPlannerWorkspaceMonitor.mockReset()
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
      }, {
        id: 'monitor-node-ready',
        kind: 'node',
        canvasId: 'canvas-1',
        canvasTitle: 'Launch Monitor',
        nodeId: 'node-ready',
        nodeTitle: 'Ready for launch',
        sessionId: null,
        deliveryId: null,
        proposalId: null,
        proposalStatus: null,
        summary: 'Ready for launch',
        runState: 'ready',
        blockers: [],
        needsOwnerReview: false,
        doerId: 'member-b',
        riskRank: 3,
        evidenceCount: 1,
        updatedAt: '2026-05-31T04:20:00.000Z',
        nextAction: null,
        awaitingInputSince: null,
      }],
    })
  })

  it('renders comfortable diagnostic fields without a density switcher', async () => {
    render(
      <I18nProvider>
        <WorkspaceMonitor
          refreshTick={0}
          onOpenItem={vi.fn()}
          onOpenAllSessions={vi.fn()}
        />
      </I18nProvider>,
    )

    expect(await screen.findByText('Research launch sentiment')).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Monitor' })).toBeInTheDocument()
    const kanban = document.querySelector('.planner-monitor__kanban')
    expect(kanban).toBeInTheDocument()
    expect(kanban?.querySelectorAll('.planner-monitor-lane')).toHaveLength(5)
    expect(document.querySelector('.planner-monitor__feed')).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'All 3' })).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByText('Ready for launch').closest('.planner-monitor-lane')).toHaveClass('planner-monitor-lane--ready')
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

  it('keeps Meee2 AI controls outside the monitor table toolbar', async () => {
    render(
      <I18nProvider>
        <WorkspaceMonitor
          refreshTick={0}
          onOpenItem={vi.fn()}
          onOpenAllSessions={vi.fn()}
        />
      </I18nProvider>,
    )

    await screen.findByText('Research launch sentiment')
    expect(screen.queryByRole('button', { name: /Meee2 AI/ })).not.toBeInTheDocument()
  })

  it('keeps the last successful monitor visible and exposes retry after a request fails', async () => {
    const { rerender } = render(
      <I18nProvider>
        <WorkspaceMonitor
          refreshTick={0}
          onOpenItem={vi.fn()}
          onOpenAllSessions={vi.fn()}
        />
      </I18nProvider>,
    )
    expect(await screen.findByText('Research launch sentiment')).toBeInTheDocument()

    apiMocks.fetchPlannerWorkspaceMonitor.mockRejectedValueOnce(new Error('Monitor is offline'))
    rerender(
      <I18nProvider>
        <WorkspaceMonitor
          refreshTick={1}
          onOpenItem={vi.fn()}
          onOpenAllSessions={vi.fn()}
        />
      </I18nProvider>,
    )

    expect(await screen.findByRole('alert')).toHaveTextContent('Monitor is offline')
    expect(screen.getByText('Research launch sentiment')).toBeInTheDocument()
    apiMocks.fetchPlannerWorkspaceMonitor.mockResolvedValueOnce({ generatedAt: 'later', items: [] })
    fireEvent.click(screen.getByRole('button', { name: 'Retry' }))
    await waitFor(() => expect(apiMocks.fetchPlannerWorkspaceMonitor).toHaveBeenCalledTimes(3))
  })

  it('does not let a slower stale refresh replace the latest monitor state', async () => {
    let rejectFirst: (reason: Error) => void = () => undefined
    const first = new Promise<{ generatedAt: string; items: [] }>((_resolve, reject) => {
      rejectFirst = reject
    })
    apiMocks.fetchPlannerWorkspaceMonitor
      .mockReturnValueOnce(first)
      .mockResolvedValueOnce({ generatedAt: 'latest', items: [] })

    const view = render(
      <I18nProvider>
        <WorkspaceMonitor refreshTick={0} onOpenItem={vi.fn()} onOpenAllSessions={vi.fn()} />
      </I18nProvider>,
    )
    view.rerender(
      <I18nProvider>
        <WorkspaceMonitor refreshTick={1} onOpenItem={vi.fn()} onOpenAllSessions={vi.fn()} />
      </I18nProvider>,
    )

    await waitFor(() => expect(apiMocks.fetchPlannerWorkspaceMonitor).toHaveBeenCalledTimes(2))
    expect(await screen.findByText('No items')).toBeInTheDocument()
    rejectFirst(new Error('stale request failed'))
    await first.catch(() => undefined)
    expect(screen.getByText('No items')).toBeInTheDocument()
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })
})
