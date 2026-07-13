import { act, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { I18nProvider } from '../lib/i18n'
import { SessionEnvironmentPanel, sessionEnvironmentRefreshInterval } from './SessionEnvironmentPanel'

const api = vi.hoisted(() => ({
  fetchSessionEnvironment: vi.fn(),
  openSessionEnvironmentOutput: vi.fn(),
}))

vi.mock('../api', () => api)

describe('SessionEnvironmentPanel', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.spyOn(document, 'hasFocus').mockReturnValue(true)
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

  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
  })

  it('uses a slower refresh interval for resting sessions', () => {
    expect(sessionEnvironmentRefreshInterval('thinking')).toBe(5_000)
    expect(sessionEnvironmentRefreshInterval('tooling')).toBe(5_000)
    expect(sessionEnvironmentRefreshInterval('compacting')).toBe(5_000)
    expect(sessionEnvironmentRefreshInterval('waitingForUser')).toBe(15_000)
    expect(sessionEnvironmentRefreshInterval('completed')).toBe(15_000)
  })

  it('polls only while focused and refreshes immediately when focus returns', async () => {
    vi.useFakeTimers()
    let focused = true
    vi.mocked(document.hasFocus).mockImplementation(() => focused)
    const view = render(
      <I18nProvider>
        <SessionEnvironmentPanel
          sessionId="polling-session"
          refreshKey="activity-polling"
          refreshStatus="thinking"
        />
      </I18nProvider>,
    )

    await act(async () => {
      await Promise.resolve()
      await Promise.resolve()
    })
    expect(api.fetchSessionEnvironment).toHaveBeenCalledTimes(1)

    await act(async () => {
      vi.advanceTimersByTime(5_000)
      await Promise.resolve()
      await Promise.resolve()
    })
    expect(api.fetchSessionEnvironment).toHaveBeenCalledTimes(2)

    focused = false
    await act(async () => {
      vi.advanceTimersByTime(5_000)
      await Promise.resolve()
    })
    expect(api.fetchSessionEnvironment).toHaveBeenCalledTimes(2)

    focused = true
    await act(async () => {
      window.dispatchEvent(new Event('focus'))
      await Promise.resolve()
      await Promise.resolve()
    })
    expect(api.fetchSessionEnvironment).toHaveBeenCalledTimes(3)
    view.unmount()
  })

  it('loads the selected session once even when the window is not focused', async () => {
    vi.mocked(document.hasFocus).mockReturnValue(false)

    render(
      <I18nProvider>
        <SessionEnvironmentPanel
          sessionId="background-session"
          refreshKey="activity-background"
          refreshStatus="running"
        />
      </I18nProvider>,
    )

    await waitFor(() => expect(api.fetchSessionEnvironment).toHaveBeenCalledWith('background-session'))
    expect(api.fetchSessionEnvironment).toHaveBeenCalledTimes(1)
  })

  it('does not let an older refresh overwrite a newer activity snapshot', async () => {
    type Snapshot = Awaited<ReturnType<typeof api.fetchSessionEnvironment>>
    let resolveFirst: (value: Snapshot) => void = () => undefined
    let resolveSecond: (value: Snapshot) => void = () => undefined
    const first = new Promise<Snapshot>((resolve) => { resolveFirst = resolve })
    const second = new Promise<Snapshot>((resolve) => { resolveSecond = resolve })
    api.fetchSessionEnvironment
      .mockReturnValueOnce(first)
      .mockReturnValueOnce(second)

    const view = render(
      <I18nProvider>
        <SessionEnvironmentPanel sessionId="racing-session" refreshKey="activity-old" />
      </I18nProvider>,
    )
    view.rerender(
      <I18nProvider>
        <SessionEnvironmentPanel sessionId="racing-session" refreshKey="activity-new" />
      </I18nProvider>,
    )
    await waitFor(() => expect(api.fetchSessionEnvironment).toHaveBeenCalledTimes(2))

    await act(async () => {
      resolveSecond({
        sessionId: 'racing-session',
        cwd: '/tmp/project',
        isGit: true,
        changes: { files: 1, additions: 2, deletions: 0 },
        branch: 'latest-branch',
        outputs: [],
      })
      await second
    })
    expect(await screen.findByText('latest-branch')).toBeInTheDocument()

    await act(async () => {
      resolveFirst({
        sessionId: 'racing-session',
        cwd: '/tmp/project',
        isGit: true,
        changes: { files: 9, additions: 99, deletions: 99 },
        branch: 'stale-branch',
        outputs: [],
      })
      await first
    })
    expect(screen.getByText('latest-branch')).toBeInTheDocument()
    expect(screen.queryByText('stale-branch')).not.toBeInTheDocument()
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
