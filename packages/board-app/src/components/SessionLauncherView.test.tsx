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
  pickSessionProjectDirectory: vi.fn(),
  renameSessionProject: vi.fn(),
  reopenLauncherSession: vi.fn(),
  revealSessionProjectInFinder: vi.fn(),
  syncNativeSessionsWorkspace: vi.fn(),
  updateSessionControl: vi.fn(),
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
    recentMessages: [{ role: 'user', text: '新增 Session 原生 Terminal' }],
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
    api.renameSessionProject.mockResolvedValue(project)
    api.reopenLauncherSession.mockResolvedValue({
      ok: true,
      action: 'resume',
      surface: {
        provider: 'claude',
        sessionId: 'restored-session',
        surfaceId: 'restored-surface',
        title: 'Claude Code - restored',
        cwd: '/Users/kai/Code/meee2-workspace',
        command: 'claude --resume restored --dangerously-skip-permissions',
        status: 'running',
        createdAt: '2026-06-14T00:00:00Z',
        updatedAt: '2026-06-14T00:00:00Z',
      },
    })
    api.revealSessionProjectInFinder.mockResolvedValue({ ok: true, path: project.path })
    api.updateSessionControl.mockResolvedValue(undefined)
    api.pickSessionProjectDirectory.mockResolvedValue({ ok: true, path: '/Users/kai/Code/new-project' })
    api.createSessionProject.mockResolvedValue({
      ...project,
      id: 'project-new',
      name: 'new-project',
      path: '/Users/kai/Code/new-project',
    })
  })

  it('renders the selected project composer with the Codex runtime selected', async () => {
    render(<SessionLauncherView state={makeState()} />)

    expect(await screen.findByText('我们应该在meee2-workspace中做些什么？')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Codex' })).toHaveClass('is-selected')
    expect(screen.getByPlaceholderText('随心输入')).toBeInTheDocument()
  })

  it('shows nested project sessions with time on session rows and selects the native terminal target', async () => {
    render(<SessionLauncherView state={makeState()} />)

    await screen.findByText('我们应该在meee2-workspace中做些什么？')
    const projectButton = screen.getByRole('button', { name: /meee2-workspace \/Users\/kai\/Code\/meee2-workspace/i })
    expect(within(projectButton).queryByText(/小时前|分钟前|天前|周前/)).not.toBeInTheDocument()

    const sessionButton = await screen.findByRole('button', { name: /新增 Session 原生 Terminal running .*前/i })
    fireEvent.click(sessionButton)

    await waitFor(() => {
      expect(api.syncNativeSessionsWorkspace).toHaveBeenCalledWith(expect.objectContaining({
        phase: 'show',
        mode: 'terminal',
        sessionId: 'session-a',
        surfaceId: 'surface-a',
      }))
    })
    expect(api.reopenLauncherSession).not.toHaveBeenCalled()
  })

  it('shows pinned sessions globally without duplicating them in the project group', async () => {
    localStorage.setItem('meee2.session.pinned.v1', JSON.stringify(['session-a']))

    render(<SessionLauncherView state={makeState()} />)

    await screen.findByText('置顶')
    expect(screen.getAllByRole('button', { name: /新增 Session 原生 Terminal running .*前/i })).toHaveLength(1)
    expect(screen.getByRole('button', { name: /meee2-workspace \/Users\/kai\/Code\/meee2-workspace/i })).toBeInTheDocument()
  })

  it('archives a session from the launcher row without deleting it', async () => {
    render(<SessionLauncherView state={makeState()} />)

    const sessionButton = await screen.findByRole('button', { name: /新增 Session 原生 Terminal running .*前/i })
    fireEvent.click(sessionButton)
    fireEvent.click(await screen.findByRole('button', { name: 'Archive 新增 Session 原生 Terminal' }))

    expect(screen.queryByRole('button', { name: /新增 Session 原生 Terminal running .*前/i })).not.toBeInTheDocument()
    await waitFor(() => {
      expect(api.updateSessionControl).toHaveBeenCalledWith('session-a', 'archive')
    })
    expect(await screen.findByText('我们应该在meee2-workspace中做些什么？')).toBeInTheDocument()
  })

  it('limits project sessions to five until expanded', async () => {
    const sessions = Array.from({ length: 6 }, (_, index) => makeSession({
      id: `session-${index + 1}`,
      title: `Task ${index + 1}`,
      recentMessages: [{ role: 'user', text: `Task ${index + 1}` }],
      surfaceId: `surface-${index + 1}`,
      lastActivity: new Date(Date.now() - index * 60_000).toISOString(),
    }))

    render(<SessionLauncherView state={makeState(sessions)} />)

    await screen.findByRole('button', { name: /meee2-workspace \/Users\/kai\/Code\/meee2-workspace/i })
    const expandProject = screen.queryByRole('button', { name: 'Expand meee2-workspace' })
    if (expandProject) fireEvent.click(expandProject)
    await screen.findByText('Task 1')
    expect(screen.queryByText('Task 6')).not.toBeInTheDocument()
    fireEvent.click(await screen.findByRole('button', { name: '展开显示' }))
    expect(await screen.findByText('Task 6')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: '收起' }))
    await waitFor(() => expect(screen.queryByText('Task 6')).not.toBeInTheDocument())
  })

  it('does not show counts and does not indent temporary sessions', async () => {
    const temporarySession = makeSession({
      id: 'temp-existing',
      project: '/Users/kai/.meee2/workspaces/temporary/20260614-153012-a1b2c3',
      recentMessages: [{ role: 'user', text: '查看本地 omlx' }],
    })

    const { container } = render(<SessionLauncherView state={makeState([temporarySession])} />)

    await screen.findByText('查看本地 omlx')
    expect(container.querySelector('.session-launcher__sidebar-header span')).not.toBeInTheDocument()
    expect(container.querySelector('.session-launcher__group-header em')).not.toBeInTheDocument()
    expect(container.querySelector('.session-launcher__project-actions span')).not.toBeInTheDocument()
    const sessionList = container.querySelector('.session-launcher__session-list')
    expect(sessionList).not.toHaveClass('session-launcher__session-list--nested')
  })

  it('selects only the clicked temporary session when sessions have no surface id', async () => {
    const temporarySessions = [
      makeSession({
        id: 'temp-a',
        project: '/Users/kai/.meee2/workspaces/temporary/a',
        title: 'Claude Code',
        recentMessages: [{ role: 'user', text: '临时问题 A' }],
        surfaceId: null,
        surfaceStatus: 'exited',
      }),
      makeSession({
        id: 'temp-b',
        project: '/Users/kai/.meee2/workspaces/temporary/b',
        title: 'Claude Code',
        recentMessages: [{ role: 'user', text: '临时问题 B' }],
        surfaceId: null,
        surfaceStatus: 'exited',
      }),
    ]
    const { container } = render(<SessionLauncherView state={makeState(temporarySessions)} />)

    fireEvent.click(await screen.findByRole('button', { name: /临时问题 B running/i }))
    await waitFor(() => {
      expect(api.reopenLauncherSession).toHaveBeenCalledWith({
        sessionId: 'temp-b',
        provider: 'codex',
        cwd: '/Users/kai/.meee2/workspaces/temporary/b',
      })
    })

    const selectedItems = container.querySelectorAll('.session-launcher__session-item.is-selected')
    expect(selectedItems).toHaveLength(1)
    expect(selectedItems[0]).toHaveTextContent('临时问题 B')
  })

  it('reopens a stale launcher session through the native terminal restore path', async () => {
    const staleSession = makeSession({
      id: 'stale-session',
      title: 'Claude Code',
      pluginDisplayName: 'Claude Code',
      pluginId: 'com.meee2.plugin.claude',
      project: '/Users/kai/.meee2/workspaces/temporary/stale',
      recentMessages: [{ role: 'user', text: '继续历史临时问题' }],
      terminalBackend: 'ghostty-surface',
      nativeWorkspaceAvailable: false,
      openTarget: 'web-fallback',
      surfaceId: null,
      surfaceStatus: 'exited',
    })
    render(<SessionLauncherView state={makeState([staleSession])} />)

    const row = await screen.findByRole('button', { name: /继续历史临时问题 running/i })
    fireEvent.click(row)

    await waitFor(() => {
      expect(api.reopenLauncherSession).toHaveBeenCalledWith({
        sessionId: 'stale-session',
        provider: 'claude',
        cwd: '/Users/kai/.meee2/workspaces/temporary/stale',
      })
      expect(api.syncNativeSessionsWorkspace).toHaveBeenCalledWith(expect.objectContaining({
        phase: 'show',
        mode: 'terminal',
        sessionId: 'restored-session',
        surfaceId: 'restored-surface',
      }))
    })
  })

  it('uses task context instead of internal node transcript titles', async () => {
    const session = makeSession({
      title: 'Node node-mpwdr7mh-2-node-2-transcript',
      currentTask: '修复 Session 标题',
      recentMessages: [],
    })
    const { container } = render(<SessionLauncherView state={makeState([session])} />)

    await screen.findByText('修复 Session 标题')
    expect(screen.queryByText(/Node node-mpwdr7mh/)).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: /修复 Session 标题 running/i }))

    const terminalHeader = container.querySelector('.session-launcher-terminal__header strong')
    expect(terminalHeader).toHaveTextContent('修复 Session 标题')
  })

  it('uses recap over the initial user question when recap exists', async () => {
    render(<SessionLauncherView state={makeState([makeSession({
      currentTask: '用户发起的问题会在没有 recap 时使用',
      recentMessages: [{ role: 'user', text: '用户发起的问题会在没有 recap 时使用' }],
      latestRecap: { content: '已经完成 session 标题与终端显示修复', timestamp: new Date().toISOString() },
    })])} />)

    await screen.findByText('已经完成 session 标题与终端显示修复')
    expect(screen.queryByText('用户发起的问题会在没有 recap 时使用')).not.toBeInTheDocument()
  })

  it('hides internal node ids when no task context is available', async () => {
    render(<SessionLauncherView state={makeState([makeSession({
      title: 'Node f9ed3716-5255-4a74-98fa-cd2f1d989aae-poker-table-2',
      currentTask: null,
      recentMessages: [],
    })])} />)

    await screen.findByText('Codex')
    expect(screen.queryByText(/Node f9ed3716/)).not.toBeInTheDocument()
  })

  it('opens project actions from the hover toolbar and renames the display name', async () => {
    const renamed = { ...project, name: 'Launcher Lab', updatedAt: '2026-06-14T00:00:00Z' }
    api.renameSessionProject.mockResolvedValue(renamed)

    render(<SessionLauncherView state={makeState()} />)

    await screen.findByRole('button', { name: /meee2-workspace \/Users\/kai\/Code\/meee2-workspace/i })
    fireEvent.click(screen.getByRole('button', { name: 'More actions for meee2-workspace' }))
    expect(screen.getByRole('menuitem', { name: 'Rename' })).toBeInTheDocument()
    expect(screen.getByRole('menuitem', { name: 'Reveal in Finder' })).toBeInTheDocument()
    expect(screen.getByRole('menuitem', { name: 'Forget project - keeps files' })).toBeInTheDocument()

    fireEvent.click(screen.getByRole('menuitem', { name: 'Rename' }))
    const input = await screen.findByLabelText('Display name')
    fireEvent.change(input, { target: { value: 'Launcher Lab' } })
    fireEvent.click(screen.getByRole('button', { name: 'Rename' }))

    await waitFor(() => {
      expect(api.renameSessionProject).toHaveBeenCalledWith('project-a', { name: 'Launcher Lab' })
    })
    expect(await screen.findByText('我们应该在Launcher Lab中做些什么？')).toBeInTheDocument()
  })

  it('adds a folder from the project group hover action', async () => {
    render(<SessionLauncherView state={makeState()} />)

    await screen.findByText('项目')
    fireEvent.click(screen.getByRole('button', { name: 'Add folder' }))

    await waitFor(() => {
      expect(api.pickSessionProjectDirectory).toHaveBeenCalled()
      expect(api.createSessionProject).toHaveBeenCalledWith({
        path: '/Users/kai/Code/new-project',
        preferredProvider: 'codex',
      })
    })
    expect(await screen.findByText('我们应该在new-project中做些什么？')).toBeInTheDocument()
  })

  it('reveals a project in Finder from the project actions menu', async () => {
    render(<SessionLauncherView state={makeState()} />)

    await screen.findByRole('button', { name: /meee2-workspace \/Users\/kai\/Code\/meee2-workspace/i })
    fireEvent.click(screen.getByRole('button', { name: 'More actions for meee2-workspace' }))
    fireEvent.click(screen.getByRole('menuitem', { name: 'Reveal in Finder' }))

    await waitFor(() => {
      expect(api.revealSessionProjectInFinder).toHaveBeenCalledWith('project-a')
    })
  })

  it('project compose action opens the composer without changing collapse state', async () => {
    render(<SessionLauncherView state={makeState()} />)

    await screen.findByText('新增 Session 原生 Terminal')
    fireEvent.click(screen.getByRole('button', { name: 'Collapse meee2-workspace' }))
    await waitFor(() => expect(screen.queryByText('新增 Session 原生 Terminal')).not.toBeInTheDocument())

    fireEvent.click(screen.getByRole('button', { name: 'Compose in meee2-workspace' }))

    expect(await screen.findByText('我们应该在meee2-workspace中做些什么？')).toBeInTheDocument()
    expect(screen.queryByText('新增 Session 原生 Terminal')).not.toBeInTheDocument()
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
    expect(await screen.findByText('我们应该在临时工作区中做些什么？')).toBeInTheDocument()
    fireEvent.change(screen.getByPlaceholderText('随心输入'), {
      target: { value: 'try a temporary idea' },
    })
    fireEvent.click(screen.getByRole('button', { name: /Start session/i }))

    await waitFor(() => {
      expect(api.createTemporarySession).toHaveBeenCalledWith({
        provider: 'codex',
        initialPrompt: 'try a temporary idea',
      })
      expect(api.syncNativeSessionsWorkspace).toHaveBeenCalledWith(expect.objectContaining({
        phase: 'show',
        mode: 'terminal',
        sessionId: 'temp-session',
        surfaceId: 'temp-surface',
      }))
    })
  })
})
