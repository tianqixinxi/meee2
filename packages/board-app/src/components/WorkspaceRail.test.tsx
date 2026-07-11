import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import { I18nProvider } from '../lib/i18n'
import { WorkspaceRail } from './WorkspaceRail'
import type { CanvasInfo } from '../types'
import type { UserProfile } from '../api'

const canvases: CanvasInfo[] = [{
  id: 'monitor',
  name: 'Monitor',
  scope: 'personal',
  kind: 'monitor',
  isDefault: true,
  workspacePath: '',
}]

const connectedProfile: UserProfile = {
  connected: true,
  userId: 'user-1',
  displayName: 'Kai User',
  userName: 'kai',
  userEmail: 'kai@example.com',
  userAvatarUrl: '',
  initials: 'KU',
  dashboardUrl: '',
  connectUrl: '',
  teams: [],
}

describe('WorkspaceRail', () => {
  it('exposes Session as the default top-level workspace', () => {
    render(
      <I18nProvider>
        <WorkspaceRail
          canvases={canvases}
          activeCanvasId="monitor"
          mode="planner"
          userProfile={null}
          onModeChange={vi.fn()}
        />
      </I18nProvider>,
    )

    expect(screen.getByRole('button', { name: 'Session' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Canvas' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Artifacts' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Progress' })).not.toBeInTheDocument()
    expect(screen.getByTestId('workspace-rail-detail')).toBeInTheDocument()
    expect(screen.getByTestId('workspace-rail-brand')).toHaveTextContent('')
    expect(screen.getByTestId('workspace-rail-brand').querySelector('.workspace-rail__brand-name')).not.toBeInTheDocument()
    expect(screen.getByTestId('workspace-rail-brand').querySelector('img.workspace-rail__brand-mark')).toBeInTheDocument()
    expect(screen.getByLabelText('Meee2')).toBeInTheDocument()
    expect(screen.getByRole('navigation', { name: 'Main navigation' })).toHaveClass('workspace-rail--compact')
    expect(document.documentElement.style.getPropertyValue('--sidebar-width')).toBe('72px')
  })

  it('expands only for the Session workspace', () => {
    const view = render(
      <I18nProvider>
        <WorkspaceRail
          canvases={canvases}
          activeCanvasId="monitor"
          mode="planner"
          userProfile={null}
          onModeChange={vi.fn()}
        />
      </I18nProvider>,
    )

    expect(screen.getByRole('navigation', { name: 'Main navigation' })).toHaveClass('workspace-rail--compact')
    view.rerender(
      <I18nProvider>
        <WorkspaceRail
          canvases={canvases}
          activeCanvasId="monitor"
          mode="session"
          userProfile={null}
          onModeChange={vi.fn()}
        />
      </I18nProvider>,
    )

    expect(screen.getByRole('navigation', { name: 'Main navigation' })).not.toHaveClass('workspace-rail--compact')
    expect(document.documentElement.style.getPropertyValue('--sidebar-width')).toBe('320px')
    expect(screen.getByTestId('workspace-rail-brand')).toHaveTextContent('Meee2')
    expect(screen.getByTestId('workspace-rail-brand').querySelector('.workspace-rail__brand-mark')).not.toBeInTheDocument()
  })

  it('omits the avatar shortcut when the user is not connected', () => {
    const onModeChange = vi.fn()
    render(
      <I18nProvider>
        <WorkspaceRail
          canvases={canvases}
          activeCanvasId="monitor"
          mode="planner"
          userProfile={null}
          onModeChange={onModeChange}
        />
      </I18nProvider>,
    )

    expect(screen.queryByRole('button', { name: 'Collapse sidebar' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Expand sidebar' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'User' })).not.toBeInTheDocument()
  })

  it('uses the avatar as a settings shortcut when the user is connected', () => {
    const onModeChange = vi.fn()
    render(
      <I18nProvider>
        <WorkspaceRail
          canvases={canvases}
          activeCanvasId="monitor"
          mode="planner"
          userProfile={connectedProfile}
          onModeChange={onModeChange}
        />
      </I18nProvider>,
    )

    fireEvent.click(screen.getByRole('button', { name: 'Kai User' }))

    expect(onModeChange).toHaveBeenCalledWith('settings')
  })
})
