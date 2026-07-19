import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
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
  it('renders the same 72px icon rail in every workspace mode', () => {
    const view = render(
      <I18nProvider>
        <WorkspaceRail
          mode="planner"
          userProfile={null}
          onModeChange={vi.fn()}
        />
      </I18nProvider>,
    )

    expect(screen.getByRole('button', { name: 'Session' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Canvas' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Monitor' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Artifacts' })).toBeInTheDocument()
    expect(screen.getByTestId('workspace-rail-brand').querySelector('img.workspace-rail__brand-mark')).toBeInTheDocument()
    expect(screen.getByLabelText('Meee2')).toBeInTheDocument()

    // 切到 session 模式，rail 结构与图标态保持一致（会话列表走 flyout，不在 rail 里）
    view.rerender(
      <I18nProvider>
        <WorkspaceRail
          mode="session"
          userProfile={null}
          onModeChange={vi.fn()}
        />
      </I18nProvider>,
    )
    expect(screen.getByTestId('workspace-rail-brand').querySelector('img.workspace-rail__brand-mark')).toBeInTheDocument()
    expect(screen.queryByTestId('workspace-rail-detail')).not.toBeInTheDocument()
  })

  it('routes session button clicks to onSessionClick when provided', () => {
    const onModeChange = vi.fn()
    const onSessionClick = vi.fn()
    render(
      <I18nProvider>
        <WorkspaceRail
          mode="planner"
          userProfile={null}
          onModeChange={onModeChange}
          onSessionClick={onSessionClick}
        />
      </I18nProvider>,
    )

    fireEvent.click(screen.getByRole('button', { name: 'Session' }))
    expect(onSessionClick).toHaveBeenCalledTimes(1)
    expect(onModeChange).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole('button', { name: 'Monitor' }))
    expect(onModeChange).toHaveBeenCalledWith('monitor')
  })

  it('falls back to onModeChange for the session button without onSessionClick', () => {
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

    fireEvent.click(screen.getByRole('button', { name: 'Session' }))
    expect(onModeChange).toHaveBeenCalledWith('session')
  })

  it('omits only the avatar shortcut when the user is not connected', () => {
    render(
      <I18nProvider>
        <WorkspaceRail
          mode="planner"
          userProfile={null}
          onModeChange={vi.fn()}
        />
      </I18nProvider>,
    )

    expect(screen.queryByRole('button', { name: 'User' })).not.toBeInTheDocument()
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
