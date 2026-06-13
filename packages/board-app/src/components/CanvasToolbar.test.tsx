import { act, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { I18nProvider } from '../lib/i18n'
import { loadCanvasRecapPosition } from '../preferences'
import { CanvasToolbar } from './CanvasToolbar'

const apiMocks = vi.hoisted(() => ({
  fetchTeamMembers: vi.fn(),
  fetchTemplateCatalog: vi.fn(),
  setPlannerCanvasDescription: vi.fn(),
  streamAssistantChat: vi.fn(),
}))

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return {
    ...actual,
    fetchTeamMembers: apiMocks.fetchTeamMembers,
    fetchTemplateCatalog: apiMocks.fetchTemplateCatalog,
    setPlannerCanvasDescription: apiMocks.setPlannerCanvasDescription,
    streamAssistantChat: apiMocks.streamAssistantChat,
  }
})

describe('CanvasToolbar template save flow', () => {
  beforeEach(() => {
    vi.useRealTimers()
    window.localStorage.clear()
    vi.clearAllMocks()
    apiMocks.fetchTemplateCatalog.mockResolvedValue({
      templates: [],
      tags: ['monitor', 'ops'],
    })
    apiMocks.fetchTeamMembers.mockResolvedValue({ members: [] })
    apiMocks.setPlannerCanvasDescription.mockResolvedValue({ plannerContext: '' })
  })

  it('saves the active canvas as a template from canvas settings', async () => {
    const onSaveCanvasAsTemplate = vi.fn().mockResolvedValue('template-canvas')
    render(
      <I18nProvider>
        <CanvasToolbar
          canvases={[{
            id: 'board-canvas',
            name: 'Launch Plan',
            scope: 'personal',
            kind: 'board',
            isDefault: false,
            workspacePath: '',
            ownerUserId: 'local-user',
            teamId: null,
          }]}
          activeCanvasId="board-canvas"
          onActiveCanvasChange={vi.fn()}
          onCreateCanvas={vi.fn()}
          onRenameCanvas={vi.fn()}
          onDeleteCanvas={vi.fn()}
          onSaveCanvasAsTemplate={onSaveCanvasAsTemplate}
        />
      </I18nProvider>,
    )

    fireEvent.click(screen.getByRole('button', { name: 'Canvas info' }))
    fireEvent.click(screen.getByRole('button', { name: 'Settings' }))
    fireEvent.click(screen.getByRole('button', { name: 'Save as template' }))

    expect(await screen.findByRole('dialog', { name: 'Save as template' })).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Save template' }))

    await waitFor(() => {
      expect(onSaveCanvasAsTemplate).toHaveBeenCalledWith(
        'board-canvas',
        expect.objectContaining({
          defaultCanvasKind: 'board',
          name: 'Launch Plan template',
          scope: 'personal',
        }),
      )
    })
  })

  it('does not offer template saving for monitor canvases', () => {
    render(
      <I18nProvider>
        <CanvasToolbar
          canvases={[{
            id: 'monitor-canvas',
            name: 'Monitor',
            scope: 'personal',
            kind: 'monitor',
            isDefault: true,
            workspacePath: '',
            ownerUserId: 'local-user',
            teamId: null,
          }]}
          activeCanvasId="monitor-canvas"
          onActiveCanvasChange={vi.fn()}
          onCreateCanvas={vi.fn()}
          onRenameCanvas={vi.fn()}
          onDeleteCanvas={vi.fn()}
          onSaveCanvasAsTemplate={vi.fn()}
        />
      </I18nProvider>,
    )

    fireEvent.click(screen.getByRole('button', { name: 'Canvas info' }))
    fireEvent.click(screen.getByRole('button', { name: 'Settings' }))

    expect(screen.queryByRole('button', { name: 'Save as template' })).not.toBeInTheDocument()
  })

  it('keeps AI recap visible on monitor canvases without opening a drawer', () => {
    render(
      <I18nProvider>
        <CanvasToolbar
          canvases={[{
            id: 'monitor-canvas',
            name: 'Monitor',
            scope: 'personal',
            kind: 'monitor',
            isDefault: true,
            workspacePath: '',
            ownerUserId: 'local-user',
            teamId: null,
          }]}
          activeCanvasId="monitor-canvas"
          onActiveCanvasChange={vi.fn()}
          onCreateCanvas={vi.fn()}
          onRenameCanvas={vi.fn()}
          onDeleteCanvas={vi.fn()}
        />
      </I18nProvider>,
    )

    const recap = document.querySelector('.canvas-toolbar__recap-trigger')
    expect(recap).toBeInstanceOf(HTMLButtonElement)
    expect(recap).toHaveTextContent(/AI recap|Reading canvas state/i)
    expect(screen.queryByRole('button', { name: 'Open AI recap' })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Refresh canvas recap' })).toBeInTheDocument()
    fireEvent.click(recap as HTMLElement)
    expect(screen.queryByRole('dialog', { name: /AI recap/i })).not.toBeInTheDocument()
  })

  it('places the Meee2 AI collapse control before canvas navigation', () => {
    const onTogglePlannerDialog = vi.fn()
    render(
      <I18nProvider>
        <CanvasToolbar
          canvases={[{
            id: 'board-canvas',
            name: 'Launch Plan',
            scope: 'personal',
            kind: 'board',
            isDefault: false,
            workspacePath: '',
            ownerUserId: 'local-user',
            teamId: null,
          }]}
          activeCanvasId="board-canvas"
          plannerDialogCollapsed={false}
          onTogglePlannerDialog={onTogglePlannerDialog}
          onActiveCanvasChange={vi.fn()}
          onCreateCanvas={vi.fn()}
          onRenameCanvas={vi.fn()}
          onDeleteCanvas={vi.fn()}
        />
      </I18nProvider>,
    )

    fireEvent.click(screen.getByRole('button', { name: 'Collapse Meee2 AI dialog' }))

    expect(onTogglePlannerDialog).toHaveBeenCalledTimes(1)
  })

  it('generates an AI recap once for canvases without cached recap', async () => {
    apiMocks.streamAssistantChat.mockImplementation(async function* () {
      yield {
        type: 'delta',
        text: JSON.stringify({
          headline: 'AI summary ready',
          summary: 'Generated once for this canvas.',
          details: ['No repeated generation when switching back.'],
        }),
      }
    })
    const canvases = [
      {
        id: 'canvas-a',
        name: 'Canvas A',
        scope: 'personal' as const,
        kind: 'board' as const,
        isDefault: false,
        workspacePath: '',
        ownerUserId: 'local-user',
        teamId: null,
      },
      {
        id: 'canvas-b',
        name: 'Canvas B',
        scope: 'personal' as const,
        kind: 'board' as const,
        isDefault: false,
        workspacePath: '',
        ownerUserId: 'local-user',
        teamId: null,
      },
    ]
    const stateFor = (id: string, title: string) => ({
      canvas: { id, title, plannerContext: '' },
      nodes: [{
        id: `${id}-node`,
        canvasId: id,
        title: 'Prepare brief',
        status: 'ready',
        workflowRunState: 'idle',
        blockedReason: null,
        nextAction: 'Start work',
        schema: { inputs: [], outputs: [] },
        dependsOnNodeIds: [],
        sessionId: null,
        schedule: null,
      }],
      artifacts: [],
      proposals: [],
      events: [],
    })
    const { rerender } = render(
      <I18nProvider>
        <CanvasToolbar
          canvases={canvases}
          activeCanvasId="canvas-a"
          plannerState={stateFor('canvas-a', 'Canvas A') as any}
          onActiveCanvasChange={vi.fn()}
          onCreateCanvas={vi.fn()}
          onRenameCanvas={vi.fn()}
          onDeleteCanvas={vi.fn()}
        />
      </I18nProvider>,
    )

    await waitFor(() => {
      expect(apiMocks.streamAssistantChat).toHaveBeenCalledTimes(1)
    })
    rerender(
      <I18nProvider>
        <CanvasToolbar
          canvases={canvases}
          activeCanvasId="canvas-b"
          plannerState={stateFor('canvas-b', 'Canvas B') as any}
          onActiveCanvasChange={vi.fn()}
          onCreateCanvas={vi.fn()}
          onRenameCanvas={vi.fn()}
          onDeleteCanvas={vi.fn()}
        />
      </I18nProvider>,
    )

    await waitFor(() => {
      expect(apiMocks.streamAssistantChat).toHaveBeenCalledTimes(2)
    })
    rerender(
      <I18nProvider>
        <CanvasToolbar
          canvases={canvases}
          activeCanvasId="canvas-a"
          plannerState={stateFor('canvas-a', 'Canvas A') as any}
          onActiveCanvasChange={vi.fn()}
          onCreateCanvas={vi.fn()}
          onRenameCanvas={vi.fn()}
          onDeleteCanvas={vi.fn()}
        />
      </I18nProvider>,
    )

    await act(async () => {})
    expect(apiMocks.streamAssistantChat).toHaveBeenCalledTimes(2)
  })

  it('collapses AI recap details behind the toolbar summary', async () => {
    apiMocks.streamAssistantChat.mockImplementation(async function* () {
      yield {
        type: 'delta',
        text: JSON.stringify({
          headline: '发布风险集中在评审',
          summary: '摘要只保留当前最重要的判断，默认不展开细节。',
          details: [
            '详细说明一：两个节点仍在等待人工确认。',
            '详细说明二：最新 artifact 已产出但还没有被验收。',
          ],
        }),
      }
    })

    render(
      <I18nProvider>
        <CanvasToolbar
          canvases={[{
            id: 'board-canvas',
            name: 'Launch Plan',
            scope: 'personal',
            kind: 'board',
            isDefault: false,
            workspacePath: '',
            ownerUserId: 'local-user',
            teamId: null,
          }]}
          activeCanvasId="board-canvas"
          plannerState={{
            canvas: { id: 'board-canvas', title: 'Launch Plan', plannerContext: '' },
            nodes: [{
              id: 'node-1',
              canvasId: 'board-canvas',
              title: 'Review launch notes',
              status: 'ready',
              workflowRunState: 'running',
              blockedReason: null,
              nextAction: 'Confirm evidence',
              schema: { inputs: [], outputs: [] },
              dependsOnNodeIds: [],
              sessionId: 'session-1',
              schedule: null,
            }],
            artifacts: [],
            proposals: [],
            events: [],
          } as any}
          onActiveCanvasChange={vi.fn()}
          onCreateCanvas={vi.fn()}
          onRenameCanvas={vi.fn()}
          onDeleteCanvas={vi.fn()}
        />
      </I18nProvider>,
    )

    fireEvent.click(screen.getByRole('button', { name: 'Refresh canvas recap' }))
    expect(await screen.findByText('发布风险集中在评审')).toBeInTheDocument()
    expect(screen.getByText('摘要只保留当前最重要的判断，默认不展开细节。')).toBeInTheDocument()
    expect(screen.queryByText('详细说明一：两个节点仍在等待人工确认。')).not.toBeInTheDocument()

    vi.useFakeTimers()
    const recap = document.querySelector('.canvas-toolbar__recap-trigger')
    expect(recap).toBeInstanceOf(HTMLButtonElement)
    fireEvent.click(recap as HTMLElement)

    expect(screen.getByText('详细说明一：两个节点仍在等待人工确认。')).toBeInTheDocument()
    expect(screen.getByText('详细说明二：最新 artifact 已产出但还没有被验收。')).toBeInTheDocument()

    act(() => {
      vi.advanceTimersByTime(3000)
    })
    expect(screen.queryByText('详细说明一：两个节点仍在等待人工确认。')).not.toBeInTheDocument()
    vi.useRealTimers()
  })

  it('persists AI recap position per canvas after dragging', () => {
    render(
      <I18nProvider>
        <CanvasToolbar
          canvases={[{
            id: 'board-canvas',
            name: 'Launch Plan',
            scope: 'personal',
            kind: 'board',
            isDefault: false,
            workspacePath: '',
            ownerUserId: 'local-user',
            teamId: null,
          }]}
          activeCanvasId="board-canvas"
          onActiveCanvasChange={vi.fn()}
          onCreateCanvas={vi.fn()}
          onRenameCanvas={vi.fn()}
          onDeleteCanvas={vi.fn()}
        />
      </I18nProvider>,
    )

    const recapContext = document.querySelector('.canvas-toolbar__context') as HTMLElement
    vi.spyOn(recapContext, 'getBoundingClientRect').mockReturnValue({
      x: 40,
      y: 50,
      left: 40,
      top: 50,
      right: 400,
      bottom: 150,
      width: 360,
      height: 100,
      toJSON: () => ({}),
    } as DOMRect)

    const dragHandle = screen.getByRole('button', { name: 'Move AI recap' })
    fireEvent(dragHandle, pointerEventWithCoords('pointerdown', 100, 100))
    fireEvent(dragHandle, pointerEventWithCoords('pointermove', 160, 150))
    fireEvent(dragHandle, pointerEventWithCoords('pointerup', 160, 150))

    expect(loadCanvasRecapPosition('board-canvas')).toEqual({ x: 100, y: 100 })
    expect(recapContext).toHaveStyle({ position: 'fixed', left: '100px', top: '100px' })
  })

  it('switches between My and Team canvas tabs in the canvas menu', async () => {
    render(
      <I18nProvider>
        <CanvasToolbar
          canvases={[
            {
              id: 'my-canvas',
              name: 'Own Canvas',
              scope: 'personal',
              kind: 'board',
              isDefault: false,
              workspacePath: '',
              ownerUserId: 'local-user',
              teamId: null,
            },
            {
              id: 'team-canvas',
              name: 'Team Canvas',
              scope: 'team',
              kind: 'board',
              isDefault: false,
              workspacePath: '',
              ownerUserId: 'other-user',
              teamId: 'team-1',
            },
            {
              id: 'published-canvas',
              name: 'Published Mine',
              scope: 'team',
              kind: 'board',
              isDefault: false,
              workspacePath: '',
              ownerUserId: 'local-user',
              teamId: 'team-1',
              syncStatus: 'synced',
            },
          ]}
          activeCanvasId="my-canvas"
          onActiveCanvasChange={vi.fn()}
          onCreateCanvas={vi.fn()}
          onRenameCanvas={vi.fn()}
          onDeleteCanvas={vi.fn()}
          userProfile={{
            connected: false,
            userId: 'local-user',
            userEmail: 'local@example.com',
            userName: 'Local User',
            displayName: 'Local User',
            userAvatarUrl: '',
            initials: 'LU',
            dashboardUrl: '',
            connectUrl: '',
            teams: [],
          }}
        />
      </I18nProvider>,
    )

    fireEvent.click(screen.getByText('Own Canvas'))

    const list = document.querySelector('.canvas-toolbar__list')
    expect(list).toBeInstanceOf(HTMLElement)

    expect(screen.getByRole('tab', { name: /My\s+1/ })).toHaveAttribute('aria-selected', 'true')
    expect(screen.getByRole('tab', { name: /Team\s+2/ })).toHaveAttribute('aria-selected', 'false')
    expect(within(list as HTMLElement).getByRole('button', { name: /Own Canvas/ })).toBeInTheDocument()
    expect(within(list as HTMLElement).queryByRole('button', { name: /Team Canvas/ })).not.toBeInTheDocument()
    expect(within(list as HTMLElement).queryByRole('button', { name: /Published Mine/ })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole('tab', { name: /Team\s+2/ }))

    expect(screen.getByRole('tab', { name: /Team\s+2/ })).toHaveAttribute('aria-selected', 'true')
    expect(within(list as HTMLElement).getByRole('button', { name: /Team Canvas/ })).toBeInTheDocument()
    expect(within(list as HTMLElement).getByRole('button', { name: /Published Mine/ })).toBeInTheDocument()
    expect(within(within(list as HTMLElement).getByRole('button', { name: /Published Mine/ })).getByText('Mine')).toBeInTheDocument()
    expect(within(within(list as HTMLElement).getByRole('button', { name: /Team Canvas/ })).queryByText('Mine')).not.toBeInTheDocument()
    expect(within(list as HTMLElement).queryByRole('button', { name: /Own Canvas/ })).not.toBeInTheDocument()
  })

  it('keeps the Team tab visible for connected users when no team canvases exist yet', async () => {
    render(
      <I18nProvider>
        <CanvasToolbar
          canvases={[{
            id: 'my-canvas',
            name: 'Own Canvas',
            scope: 'personal',
            kind: 'board',
            isDefault: false,
            workspacePath: '',
            ownerUserId: 'local-user',
            teamId: null,
          }]}
          activeCanvasId="my-canvas"
          onActiveCanvasChange={vi.fn()}
          onCreateCanvas={vi.fn()}
          onRenameCanvas={vi.fn()}
          onDeleteCanvas={vi.fn()}
          userProfile={{
            connected: true,
            userId: 'local-user',
            userEmail: 'local@example.com',
            userName: 'Local User',
            displayName: 'Local User',
            userAvatarUrl: '',
            initials: 'LU',
            dashboardUrl: '',
            connectUrl: '',
            teams: [{ id: 'team-1', name: 'Local Team', role: 'owner', isDefault: true }],
          }}
        />
      </I18nProvider>,
    )

    await waitFor(() => {
      expect(apiMocks.fetchTeamMembers).toHaveBeenCalled()
    })

    fireEvent.click(screen.getByText('Own Canvas'))

    expect(screen.getByRole('tab', { name: /My\s+1/ })).toHaveAttribute('aria-selected', 'true')
    expect(screen.getByRole('tab', { name: /Team\s+0/ })).toHaveAttribute('aria-selected', 'false')

    fireEvent.click(screen.getByRole('tab', { name: /Team\s+0/ }))

    expect(screen.getByText('No Team Canvas yet')).toBeInTheDocument()
  })

  it('lets the team canvas owner resolve a sync conflict from the menu hover', async () => {
    const onResolveCanvasConflict = vi.fn().mockResolvedValue(undefined)
    render(
      <I18nProvider>
        <CanvasToolbar
          canvases={[
            {
              id: 'conflict-canvas',
              name: 'Published Mine',
              scope: 'team',
              kind: 'board',
              isDefault: false,
              workspacePath: '',
              ownerUserId: 'local-user',
              teamId: 'team-1',
              remoteVersion: 1,
              conflictRemoteVersion: 2,
              syncStatus: 'conflict',
            },
          ]}
          activeCanvasId="conflict-canvas"
          onActiveCanvasChange={vi.fn()}
          onCreateCanvas={vi.fn()}
          onRenameCanvas={vi.fn()}
          onDeleteCanvas={vi.fn()}
          onResolveCanvasConflict={onResolveCanvasConflict}
          userProfile={{
            connected: true,
            userId: 'local-user',
            userEmail: 'local@example.com',
            userName: 'Local User',
            displayName: 'Local User',
            userAvatarUrl: '',
            initials: 'LU',
            dashboardUrl: '',
            connectUrl: '',
            teams: [],
          }}
        />
      </I18nProvider>,
    )

    fireEvent.click(screen.getByText('Published Mine'))
    const list = document.querySelector('.canvas-toolbar__list')
    expect(list).toBeInstanceOf(HTMLElement)
    fireEvent.mouseEnter(within(list as HTMLElement).getByRole('button', { name: /Published Mine/ }))

    await waitFor(() => {
      expect(screen.getAllByText('Sync conflict').length).toBeGreaterThan(0)
    })
    expect(screen.getByText('local v1 / team v2')).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Keep local' }))

    await waitFor(() => {
      expect(onResolveCanvasConflict).toHaveBeenCalledWith('conflict-canvas', 'current')
    })
  })

  it('shows the canvas hover card for regular canvas rows', () => {
    render(
      <I18nProvider>
        <CanvasToolbar
          canvases={[{
            id: 'hover-canvas',
            name: 'Hover Canvas',
            scope: 'personal',
            kind: 'board',
            isDefault: false,
            workspacePath: '',
            ownerUserId: 'local-user',
            teamId: null,
          }]}
          activeCanvasId="hover-canvas"
          onActiveCanvasChange={vi.fn()}
          onCreateCanvas={vi.fn()}
          onRenameCanvas={vi.fn()}
          onDeleteCanvas={vi.fn()}
          userProfile={{
            connected: false,
            userId: 'local-user',
            userEmail: 'local@example.com',
            userName: 'Local User',
            displayName: 'Local User',
            userAvatarUrl: '',
            initials: 'LU',
            dashboardUrl: '',
            connectUrl: '',
            teams: [],
          }}
        />
      </I18nProvider>,
    )

    fireEvent.click(screen.getByText('Hover Canvas'))
    const list = document.querySelector('.canvas-toolbar__list')
    expect(list).toBeInstanceOf(HTMLElement)
    const item = within(list as HTMLElement).getByRole('button', { name: /Hover Canvas/ })

    fireEvent.mouseEnter(item)

    expect(screen.getByText('Access')).toBeInTheDocument()
    expect(document.querySelector('.canvas-toolbar__hover-recap')).toBeInstanceOf(HTMLElement)
  })
})

function pointerEventWithCoords(type: string, clientX: number, clientY: number): Event {
  const event = new Event(type, { bubbles: true, cancelable: true })
  Object.defineProperties(event, {
    pointerId: { value: 1 },
    clientX: { value: clientX },
    clientY: { value: clientY },
  })
  return event
}
