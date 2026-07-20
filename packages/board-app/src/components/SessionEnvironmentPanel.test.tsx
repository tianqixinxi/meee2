import { act, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { I18nProvider } from '../lib/i18n'
import type { Session } from '../types'
import { SessionContextPanel, sessionContextRefreshInterval } from './SessionContextPanel'

const api = vi.hoisted(() => ({
  fetchSessionEnvironment: vi.fn(),
  fetchSessionArtifacts: vi.fn(),
  openSessionEnvironmentOutput: vi.fn(),
  fetchTranscript: vi.fn(),
  syncNativeSessionsWorkspace: vi.fn(),
}))

vi.mock('../api', () => api)

function session(overrides: Partial<Session> = {}): Session {
  return {
    id: 'environment-session',
    title: 'Improve session context',
    project: '/tmp/project',
    pluginId: 'codex',
    pluginDisplayName: 'Codex',
    pluginColor: '#fff',
    status: 'thinking',
    inboxPending: 0,
    recentMessages: [
      { role: 'user', text: 'Make the right side useful' },
      { role: 'assistant', text: 'Inspecting the workspace context' },
    ],
    currentTool: 'Read',
    currentTask: 'Building Session Context',
    usageStats: {
      inputTokens: 1_200,
      outputTokens: 350,
      cacheCreateTokens: 100,
      cacheReadTokens: 500,
      turns: 6,
      model: 'gpt-5',
    },
    tasks: [{ id: 'task-1', name: 'Build panel', status: 'in_progress' }],
    backgroundAgents: [{ id: 'agent-1', kind: 'agent', description: 'Inspect transcript', startedAt: null }],
    latestRecap: null,
    startedAt: '2026-07-21T00:00:00Z',
    lastActivity: '2026-07-21T01:00:00Z',
    syncEnabled: false,
    syncTeamId: null,
    syncTeamName: null,
    ...overrides,
  }
}

describe('SessionContextPanel', () => {
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
      files: [
        { relativePath: 'src/App.tsx', status: 'modified', additions: 12, deletions: 3 },
        { relativePath: 'src/Context.tsx', status: 'added', additions: 9, deletions: 0 },
      ],
      outputs: [
        { path: '/tmp/project/report.md', relativePath: 'report.md' },
        { path: '/tmp/project/output/data.csv', relativePath: 'output/data.csv' },
      ],
    })
    api.fetchSessionArtifacts.mockResolvedValue({
      sessionId: 'environment-session',
      artifacts: [],
      totalCount: 2,
    })
    api.fetchTranscript.mockResolvedValue({ sessionId: 'environment-session', entries: [] })
    api.openSessionEnvironmentOutput.mockResolvedValue({ ok: true, path: '/tmp/project/report.md', mode: 'opened' })
  })

  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
  })

  it('uses a slower refresh interval for resting sessions', () => {
    expect(sessionContextRefreshInterval('thinking')).toBe(5_000)
    expect(sessionContextRefreshInterval('tooling')).toBe(5_000)
    expect(sessionContextRefreshInterval('compacting')).toBe(5_000)
    expect(sessionContextRefreshInterval('waitingForUser')).toBe(15_000)
    expect(sessionContextRefreshInterval('completed')).toBe(15_000)
  })

  it('polls only while focused and refreshes immediately when focus returns', async () => {
    vi.useFakeTimers()
    let focused = true
    vi.mocked(document.hasFocus).mockImplementation(() => focused)
    const view = render(
      <I18nProvider>
        <SessionContextPanel session={session({ id: 'polling-session', lastActivity: 'activity-polling' })} />
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
        <SessionContextPanel session={session({ id: 'background-session', lastActivity: 'activity-background', status: 'running' })} />
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
        <SessionContextPanel session={session({ id: 'racing-session', lastActivity: 'activity-old' })} />
      </I18nProvider>,
    )
    view.rerender(
      <I18nProvider>
        <SessionContextPanel session={session({ id: 'racing-session', lastActivity: 'activity-new' })} />
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
        files: [],
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
        files: [],
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
        <SessionContextPanel session={session({ lastActivity: 'activity-1' })} />
      </I18nProvider>,
    )

    await waitFor(() => expect(api.fetchSessionEnvironment).toHaveBeenCalledWith('environment-session'))
    expect(screen.getByRole('heading', { name: '会话上下文' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: '当前状态' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: '最近动态' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Agent 与任务' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: '工作区' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: '输出与产物' })).toBeInTheDocument()
    expect(screen.getByText('3 个文件')).toBeInTheDocument()
    expect(screen.getByText('+21')).toBeInTheDocument()
    expect(screen.getByText('-5')).toBeInTheDocument()
    expect(screen.getByText('codex/environment-panel')).toBeInTheDocument()
    expect(screen.getByText('report.md')).toBeInTheDocument()
    expect(screen.getByText('output/data.csv')).toBeInTheDocument()
    expect(screen.getByText('src/App.tsx')).toBeInTheDocument()
    expect(screen.getByText('2 个产物')).toBeInTheDocument()
    expect(screen.getByText('Building Session Context')).toBeInTheDocument()
    expect(screen.getByText('Inspect transcript')).toBeInTheDocument()
    expect(screen.getByText('gpt-5')).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: '使用默认应用打开: report.md' }))
    await waitFor(() => {
      expect(api.openSessionEnvironmentOutput).toHaveBeenCalledWith(
        'environment-session',
        '/tmp/project/report.md',
      )
    })
  })
})
