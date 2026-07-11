import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { I18nProvider } from '../lib/i18n'
import { SessionEnvironmentPanel } from './SessionEnvironmentPanel'

const api = vi.hoisted(() => ({
  fetchSessionEnvironment: vi.fn(),
  openSessionEnvironmentOutput: vi.fn(),
}))

vi.mock('../api', () => api)

describe('SessionEnvironmentPanel', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    localStorage.setItem('meee2.locale', 'zh-CN')
    api.fetchSessionEnvironment.mockResolvedValue({
      sessionId: 'environment-session',
      cwd: '/tmp/project',
      isGit: true,
      changes: { files: 3, additions: 21, deletions: 5 },
      branch: 'codex/environment-panel',
      outputs: [
        { path: '/tmp/project/report.md', relativePath: 'report.md' },
        { path: '/tmp/project/output/data.csv', relativePath: 'output/data.csv' },
      ],
    })
    api.openSessionEnvironmentOutput.mockResolvedValue({ ok: true, path: '/tmp/project/report.md', mode: 'opened' })
  })

  it('renders git changes, branch, and created output files', async () => {
    render(
      <I18nProvider>
        <SessionEnvironmentPanel sessionId="environment-session" refreshKey="activity-1" />
      </I18nProvider>,
    )

    await waitFor(() => expect(api.fetchSessionEnvironment).toHaveBeenCalledWith('environment-session'))
    expect(screen.getByRole('heading', { name: '环境信息' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: '输出' })).toBeInTheDocument()
    expect(screen.getByText('3 个文件')).toBeInTheDocument()
    expect(screen.getByText('+21')).toBeInTheDocument()
    expect(screen.getByText('-5')).toBeInTheDocument()
    expect(screen.getByText('codex/environment-panel')).toBeInTheDocument()
    expect(screen.getByText('report.md')).toBeInTheDocument()
    expect(screen.getByText('output/data.csv')).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: '使用默认应用打开: report.md' }))
    await waitFor(() => {
      expect(api.openSessionEnvironmentOutput).toHaveBeenCalledWith(
        'environment-session',
        '/tmp/project/report.md',
      )
    })
  })
})
