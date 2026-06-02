import { act, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { CommandPalette } from './CommandPalette'
import type { BoardState, CanvasInfo, Session } from '../types'

const apiMocks = vi.hoisted(() => ({
  fetchPlannerWorkspaceMonitor: vi.fn(),
}))

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return {
    ...actual,
    fetchPlannerWorkspaceMonitor: apiMocks.fetchPlannerWorkspaceMonitor,
  }
})

const canvases: CanvasInfo[] = [{
  id: 'canvas-1',
  name: 'Launch Canvas',
  scope: 'personal',
  kind: 'board',
  isDefault: false,
  workspacePath: '',
}]

const session: Session = {
  id: 'session-1',
  title: 'Build terminal overlay',
  project: '/tmp/project',
  pluginId: 'claude',
  pluginDisplayName: 'Claude',
  pluginColor: '#ff9500',
  status: 'running',
  inboxPending: 0,
  recentMessages: [],
  currentTool: null,
  usageStats: null,
  backgroundAgents: [],
  latestRecap: null,
  terminalKind: 'internal',
  surfaceId: 'surface-1',
  surfaceStatus: 'running',
  syncEnabled: false,
  syncTeamId: null,
  syncTeamName: null,
}

const boardState: BoardState = {
  sessions: [session],
  channels: [],
  coordinationGroups: [],
}

describe('CommandPalette session routing', () => {
  beforeEach(() => {
    Element.prototype.scrollIntoView = vi.fn()
    apiMocks.fetchPlannerWorkspaceMonitor.mockResolvedValue({
      generatedAt: '2026-06-03T00:00:00.000Z',
      items: [{
        id: 'monitor-session-1',
        kind: 'session',
        canvasId: 'canvas-1',
        canvasTitle: 'Launch Canvas',
        nodeId: null,
        nodeTitle: null,
        sessionId: 'session-1',
        deliveryId: null,
        proposalId: null,
        proposalStatus: null,
        summary: 'Build terminal overlay',
        runState: 'working',
        blockers: [],
        needsOwnerReview: false,
        doerId: null,
        riskRank: 1,
        evidenceCount: 0,
        updatedAt: '2026-06-03T00:00:00.000Z',
        nextAction: null,
        awaitingInputSince: null,
      }],
    })
  })

  it('opens from the custom Quick event and passes the session canvas hint', async () => {
    const onOpenSession = vi.fn()
    render(
      <CommandPalette
        canvases={canvases}
        boardState={boardState}
        onOpenCanvas={vi.fn()}
        onOpenNodeInspector={vi.fn()}
        onOpenSession={onOpenSession}
      />,
    )

    act(() => {
      window.dispatchEvent(new CustomEvent('meee2:open-command-palette', { detail: { query: 'overlay' } }))
    })

    expect(await screen.findByText('Build terminal overlay')).toBeInTheDocument()
    await waitFor(() => expect(apiMocks.fetchPlannerWorkspaceMonitor).toHaveBeenCalled())

    fireEvent.mouseDown(screen.getByText('Build terminal overlay'))

    expect(onOpenSession).toHaveBeenCalledWith('session-1', 'canvas-1')
  })
})
