import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { I18nProvider } from '../lib/i18n'
import { CanvasToolbar } from './CanvasToolbar'

const apiMocks = vi.hoisted(() => ({
  fetchTemplateCatalog: vi.fn(),
  setPlannerCanvasDescription: vi.fn(),
  streamAssistantChat: vi.fn(),
}))

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return {
    ...actual,
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
    apiMocks.setPlannerCanvasDescription.mockResolvedValue({ plannerContext: '' })
  })

  it('saves the active canvas as a template from canvas settings', async () => {
    const onSaveCanvasAsTemplate = vi.fn().mockResolvedValue('template-canvas')
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
        'monitor-canvas',
        expect.objectContaining({
          defaultCanvasKind: 'monitor',
          name: 'Monitor template',
          scope: 'personal',
        }),
      )
    })
  })
})
