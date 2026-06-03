import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import { I18nProvider } from '../lib/i18n'
import { WorkspaceRail } from './WorkspaceRail'
import type { CanvasInfo } from '../types'

const canvases: CanvasInfo[] = [{
  id: 'monitor',
  name: 'Monitor',
  scope: 'personal',
  kind: 'monitor',
  isDefault: true,
  workspacePath: '',
}]

describe('WorkspaceRail', () => {
  it('does not expose Sessions/Progress as a top-level workspace', () => {
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

    expect(screen.getByRole('button', { name: 'Canvas' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Artifacts' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Progress' })).not.toBeInTheDocument()
  })

  it('uses the avatar as a settings shortcut and removes the collapse control', () => {
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

    fireEvent.click(screen.getByRole('button', { name: 'User' }))

    expect(onModeChange).toHaveBeenCalledWith('settings')
  })
})
