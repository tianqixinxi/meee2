import { fireEvent, render, screen } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { I18nProvider } from '../lib/i18n'
import { WorkspaceRail } from './WorkspaceRail'
import type { UserProfile } from '../api'

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
  beforeEach(() => {
    window.localStorage.clear()
  })

  it('exposes Session as the default top-level workspace', () => {
    const onModeChange = vi.fn()
    render(
      <I18nProvider>
        <WorkspaceRail
          mode="planner"
          userProfile={null}
          onModeChange={onModeChange}
        />
      </I18nProvider>,
    )

    expect(screen.getByRole('button', { name: 'Session' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Canvas' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Monitor' })).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Monitor' }))
    expect(onModeChange).toHaveBeenCalledWith('monitor')
    expect(screen.getByRole('button', { name: 'Artifacts' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Progress' })).not.toBeInTheDocument()
    expect(screen.getByTestId('workspace-rail-detail')).toBeInTheDocument()
    expect(screen.getByTestId('workspace-rail-brand')).toHaveTextContent('')
    expect(screen.getByTestId('workspace-rail-brand').querySelector('.workspace-rail__brand-name')).not.toBeInTheDocument()
    expect(screen.getByTestId('workspace-rail-brand').querySelector('img.workspace-rail__brand-mark')).toBeInTheDocument()
    expect(screen.getByLabelText('Meee2')).toBeInTheDocument()
    expect(screen.getByRole('navigation', { name: 'Main navigation' })).toHaveClass('workspace-rail--compact')
    expect(document.documentElement.style.getPropertyValue('--sidebar-width')).toBe('72px')
    expect(screen.queryByRole('button', { name: 'Collapse sidebar' })).not.toBeInTheDocument()
  })

  it('expands only for the Session workspace', () => {
    const view = render(
      <I18nProvider>
        <WorkspaceRail
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
          mode="session"
          userProfile={null}
          onModeChange={vi.fn()}
        />
      </I18nProvider>,
    )

    expect(screen.getByRole('navigation', { name: 'Main navigation' })).not.toHaveClass('workspace-rail--compact')
    expect(document.documentElement.style.getPropertyValue('--sidebar-width')).toBe('288px')
    expect(screen.getByTestId('workspace-rail-brand')).toHaveTextContent('Meee2')
    expect(screen.getByTestId('workspace-rail-brand').querySelector('.workspace-rail__brand-mark')).not.toBeInTheDocument()
  })

  it('hides the whole rail and gives the workspace the full width', () => {
    render(
      <I18nProvider>
        <WorkspaceRail
          mode="session"
          userProfile={null}
          onModeChange={vi.fn()}
        />
      </I18nProvider>,
    )

    fireEvent.click(screen.getByRole('button', { name: 'Collapse sidebar' }))

    expect(document.querySelector('nav.workspace-rail')).not.toBeVisible()
    expect(screen.getByRole('button', { name: 'Expand sidebar' })).toHaveAttribute('aria-expanded', 'false')
    expect(document.documentElement).toHaveClass('board-sidebar-rail--collapsed')
    expect(document.documentElement.style.getPropertyValue('--sidebar-width')).toBe('0px')
    expect(window.localStorage.getItem('meee2.workspaceRail.collapsed')).toBe('1')

    fireEvent.click(screen.getByRole('button', { name: 'Expand sidebar' }))

    expect(screen.getByRole('navigation', { name: 'Main navigation' })).toBeVisible()
    expect(document.documentElement).not.toHaveClass('board-sidebar-rail--collapsed')
    expect(document.documentElement.style.getPropertyValue('--sidebar-width')).toBe('288px')
  })

  it('omits only the avatar shortcut when the user is not connected', () => {
    const onModeChange = vi.fn()
    render(
      <I18nProvider>
        <WorkspaceRail
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

  it('applies a stored collapsed state only to Session', () => {
    window.localStorage.setItem('meee2.workspaceRail.collapsed', '1')

    render(
      <I18nProvider>
        <WorkspaceRail
          mode="planner"
          userProfile={null}
          onModeChange={vi.fn()}
        />
      </I18nProvider>,
    )

    expect(screen.getByRole('navigation', { name: 'Main navigation' })).toBeVisible()
    expect(document.documentElement).not.toHaveClass('board-sidebar-rail--collapsed')
    expect(document.documentElement.style.getPropertyValue('--sidebar-width')).toBe('72px')
    expect(screen.queryByRole('button', { name: 'Expand sidebar' })).not.toBeInTheDocument()
  })

  it('uses the avatar as a settings shortcut when the user is connected', () => {
    const onModeChange = vi.fn()
    render(
      <I18nProvider>
        <WorkspaceRail
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
