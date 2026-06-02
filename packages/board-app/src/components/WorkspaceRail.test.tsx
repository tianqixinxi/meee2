import { render, screen } from '@testing-library/react'
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
          collapsed={false}
          onCollapsedChange={vi.fn()}
          onModeChange={vi.fn()}
        />
      </I18nProvider>,
    )

    expect(screen.getByRole('button', { name: 'Canvas' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Progress' })).not.toBeInTheDocument()
  })
})
