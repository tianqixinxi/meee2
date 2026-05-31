import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { I18nProvider } from '../lib/i18n'
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

  it('keeps AI recap available on monitor canvases', () => {
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

    expect(screen.getByRole('button', { name: 'Open AI recap' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Refresh canvas recap' })).toBeInTheDocument()
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
            defaultSyncEnabled: true,
            defaultSyncTeamId: 'team-1',
            defaultSyncTeamName: 'Demo Team',
            teams: [],
            sessionSync: [],
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
})
