import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { SessionLauncherView } from './SessionLauncherView'
import type { BoardState, Session, SessionProject } from '../types'

const api = vi.hoisted(() => ({
  fetchSessionProjects: vi.fn(),
  createProjectSession: vi.fn(),
  createSessionProject: vi.fn(),
  createTemporarySession: vi.fn(),
  forgetSessionProject: vi.fn(),
  openNativeTerminalSurface: vi.fn(),
  pickSessionProjectDirectory: vi.fn(),
}))

vi.mock('../api', () => api)

const project: SessionProject = {
  id: 'project-a',
  name: 'meee2-workspace',
  path: '/Users/kai/Code/meee2-workspace',
  preferredProvider: 'codex',
  explicit: true,
  createdAt: '2026-06-13T00:00:00Z',
  updatedAt: '2026-06-13T00:00:00Z',
  lastUsedAt: null,
}

function makeSession(overrides: Partial<Session> = {}): Session {
  return {
    id: 'session-a',
    title: 'Codex - meee2-workspace',
    project: '/Users/kai/Code/meee2-workspace',
    pluginId: 'com.meee2.plugin.codex',
    pluginDisplayName: 'Codex',
    pluginColor: '#8b5cf6',
    status: 'running',
    inboxPending: 0,
    recentMessages: [],
    currentTool: 'terminal',
    usageStats: null,
    backgroundAgents: [],
    latestRecap: null,
    startedAt: new Date(Date.now() - 2 * 3_600_000).toISOString(),
    lastActivity: new Date(Date.now() - 60 * 60_000).toISOString(),
    terminalKind: 'internal',
    terminalBackend: 'ghostty-surface',
    surfaceId: 'surface-a',
    surfaceStatus: 'running',
    nativeWorkspaceAvailable: true,
    openTarget: 'native-workspace',
    syncEnabled: false,
    syncTeamId: null,
    syncTeamName: null,
    ...overrides,
  }
}

function makeState(sessions: Session[] = [makeSession()]): BoardState {
  return {
    sessions,
    channels: [],
    coordinationGroups: [],
  }
}

describe('SessionLauncherView', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    localStorage.clear()
    api.fetchSessionProjects.mockResolvedValue({ projects: [project] })
  })

  it('renders the selected project composer with the Codex runtime selected', async () => {
    render(<SessionLauncherView state={makeState()} />)

    expect(await screen.findByText('我们应该在 meee2-workspace 中构建什么？')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Codex' })).toHaveClass('is-selected')
    expect(screen.getByPlaceholderText('描述你想让本地 agent 完成的工作...')).toBeInTheDocument()
  })

  it('shows nested project sessions with time on session rows and selects the native terminal target', async () => {
    render(<SessionLauncherView state={makeState()} />)

    await screen.findByText('我们应该在 meee2-workspace 中构建什么？')
    const projectButton = screen.getByRole('button', { name: /meee2-workspace \/Users\/kai\/Code\/meee2-workspace/i })
    expect(within(projectButton).queryByText(/小时前|分钟前|天前|周前/)).not.toBeInTheDocument()

    const sessionButton = await screen.findByRole('button', { name: /Codex - meee2-workspace running .*前/i })
    fireEvent.click(sessionButton)

    await waitFor(() => {
      expect(api.openNativeTerminalSurface).toHaveBeenCalledWith(expect.objectContaining({
        sessionId: 'session-a',
        surfaceId: 'surface-a',
      }))
    })
  })

  it('shows pinned sessions globally without duplicating them in the project group', async () => {
    localStorage.setItem('meee2.session.pinned.v1', JSON.stringify(['session-a']))

    render(<SessionLauncherView state={makeState()} />)

    await screen.findByText('置顶')
    expect(screen.getAllByRole('button', { name: /Codex - meee2-workspace running .*前/i })).toHaveLength(1)
    expect(screen.getByRole('button', { name: /meee2-workspace \/Users\/kai\/Code\/meee2-workspace/i })).toBeInTheDocument()
  })

  it('limits project sessions to five until expanded', async () => {
    const sessions = Array.from({ length: 6 }, (_, index) => makeSession({
      id: `session-${index + 1}`,
      title: `Task ${index + 1}`,
      surfaceId: `surface-${index + 1}`,
      lastActivity: new Date(Date.now() - index * 60_000).toISOString(),
    }))

    render(<SessionLauncherView state={makeState(sessions)} />)

    await screen.findByText('meee2-workspace')
    const expandProject = screen.queryByRole('button', { name: 'Expand meee2-workspace' })
    if (expandProject) fireEvent.click(expandProject)
    await screen.findByText('Task 1')
    expect(screen.queryByText('Task 6')).not.toBeInTheDocument()
    fireEvent.click(await screen.findByRole('button', { name: '展开显示' }))
    expect(await screen.findByText('Task 6')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: '收起' }))
    await waitFor(() => expect(screen.queryByText('Task 6')).not.toBeInTheDocument())
  })

  it('opens a temporary composer and creates a temporary native session', async () => {
    api.fetchSessionProjects.mockResolvedValue({ projects: [] })
    api.createTemporarySession.mockResolvedValue({
      ok: true,
      cwd: '/Users/kai/.meee2/workspaces/temporary/20260614-153012-a1b2c3',
      surface: {
        provider: 'codex',
        sessionId: 'temp-session',
        surfaceId: 'temp-surface',
        title: 'Codex - temporary',
        cwd: '/Users/kai/.meee2/workspaces/temporary/20260614-153012-a1b2c3',
        command: 'codex --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust',
        status: 'running',
        createdAt: '2026-06-14T00:00:00Z',
        updatedAt: '2026-06-14T00:00:00Z',
      },
    })

    render(<SessionLauncherView state={makeState([])} />)

    fireEvent.click(await screen.findByRole('button', { name: 'New temporary session' }))
    expect(await screen.findByText('我们应该在临时工作区中构建什么？')).toBeInTheDocument()
    fireEvent.change(screen.getByPlaceholderText('描述你想让本地 agent 完成的工作...'), {
      target: { value: 'try a temporary idea' },
    })
    fireEvent.click(screen.getByRole('button', { name: /Start session/i }))

    await waitFor(() => {
      expect(api.createTemporarySession).toHaveBeenCalledWith({
        provider: 'codex',
        initialPrompt: 'try a temporary idea',
      })
      expect(api.openNativeTerminalSurface).toHaveBeenCalledWith(expect.objectContaining({
        sessionId: 'temp-session',
        surfaceId: 'temp-surface',
      }))
    })
  })
})
