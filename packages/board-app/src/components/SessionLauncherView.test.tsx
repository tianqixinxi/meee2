import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { act, type ReactElement } from 'react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { I18nProvider } from '../lib/i18n'
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
vi.mock('../lib/theme', () => ({
  useTheme: () => ({ resolvedTheme: 'dark' }),
}))

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
    sessionScope: 'meee2',
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

function renderWithI18n(ui: ReactElement) {
  return render(<I18nProvider>{ui}</I18nProvider>)
}

describe('SessionLauncherView', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    localStorage.clear()
    localStorage.setItem('meee2.locale', 'zh-CN')
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
    renderWithI18n(<SessionLauncherView state={makeState()} />)

    expect(await screen.findByText('我们应该在meee2-workspace中做些什么？')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Codex' })).toHaveClass('is-selected')
    expect(screen.getByRole('button', { name: '权限模式' })).toHaveTextContent('完全访问')
    expect(screen.getByPlaceholderText('随心输入')).toBeInTheDocument()
  })

  it('resizes and fully collapses the launcher sidebar', async () => {
    renderWithI18n(<SessionLauncherView state={makeState()} />)

    await screen.findByText('我们应该在meee2-workspace中做些什么？')
    const launcher = document.querySelector('.session-launcher') as HTMLElement
    expect(launcher.style.getPropertyValue('--session-launcher-sidebar-width')).toBe('324px')

    fireEvent.pointerDown(screen.getByRole('button', { name: '调整会话侧边栏宽度' }), {
      clientX: 324,
      pointerId: 1,
    })
    const moveEvent = new Event('pointermove') as PointerEvent
    Object.defineProperty(moveEvent, 'clientX', { value: 404 })
    await act(async () => {
      window.dispatchEvent(moveEvent)
      window.dispatchEvent(new Event('pointerup'))
    })

    await waitFor(() => {
      expect(launcher.style.getPropertyValue('--session-launcher-sidebar-width')).toBe('404px')
    })
    expect(localStorage.getItem('meee2.sessionLauncher.sidebarWidth')).toBe('404')

    fireEvent.click(screen.getByRole('button', { name: '折叠会话侧边栏' }))

    expect(launcher).toHaveClass('session-launcher--sidebar-collapsed')
    expect(localStorage.getItem('meee2.sessionLauncher.sidebarCollapsed')).toBe('1')
    expect(screen.getByRole('button', { name: '展开会话侧边栏' })).toBeInTheDocument()
  })

  it('switches permission choices with the selected runtime', async () => {
    renderWithI18n(<SessionLauncherView state={makeState()} />)

    await screen.findByText('我们应该在meee2-workspace中做些什么？')
    fireEvent.click(screen.getByRole('button', { name: '权限模式' }))
    expect(screen.getByRole('option', { name: /执行前确认/ })).toHaveAttribute(
      'title',
      'codex --sandbox workspace-write --ask-for-approval on-request --dangerously-bypass-hook-trust',
    )
    expect(screen.queryByRole('option', { name: '自动接受编辑' })).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('option', { name: /完全访问/ }))

    fireEvent.click(screen.getByRole('button', { name: 'Claude' }))

    expect(screen.getByRole('button', { name: 'Claude' })).toHaveClass('is-selected')
    expect(screen.getByRole('button', { name: '权限模式' })).toHaveTextContent('完全访问')
    fireEvent.click(screen.getByRole('button', { name: '权限模式' }))
    expect(screen.getByRole('option', { name: /自动接受编辑/ })).toHaveAttribute(
      'title',
      'claude --permission-mode acceptEdits',
    )
    expect(screen.queryByRole('option', { name: '只读沙盒' })).not.toBeInTheDocument()
  })

  it('shows compact nested project sessions and selects the native terminal target', async () => {
    renderWithI18n(<SessionLauncherView state={makeState()} />)

    await screen.findByText('我们应该在meee2-workspace中做些什么？')
    const projectButton = screen.getByRole('button', { name: 'meee2-workspace' })
    expect(within(projectButton).queryByText('/Users/kai/Code/meee2-workspace')).not.toBeInTheDocument()

    const sessionButton = await screen.findByRole('button', { name: '新增 Session 原生 Terminal' })
    expect(within(sessionButton).queryByText(/running|小时前|分钟前|天前|周前/)).not.toBeInTheDocument()
    expect(within(sessionButton).getByText(/小时|分|刚刚/)).toBeInTheDocument()
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

    renderWithI18n(<SessionLauncherView state={makeState()} />)

    await screen.findByText('置顶')
    expect(screen.getAllByRole('button', { name: '新增 Session 原生 Terminal' })).toHaveLength(1)
    expect(screen.getByRole('button', { name: 'meee2-workspace' })).toBeInTheDocument()
  })

  it('archives a session from the launcher row without deleting it', async () => {
    renderWithI18n(<SessionLauncherView state={makeState()} />)

    const sessionButton = await screen.findByRole('button', { name: '新增 Session 原生 Terminal' })
    fireEvent.click(sessionButton)
    fireEvent.click(await screen.findByRole('button', { name: '归档 新增 Session 原生 Terminal' }))

    expect(await screen.findByRole('dialog', { name: '归档会话？' })).toBeInTheDocument()
    expect(api.updateSessionControl).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: '归档会话' }))

    expect(screen.queryByRole('button', { name: '新增 Session 原生 Terminal' })).not.toBeInTheDocument()
    await waitFor(() => {
      expect(api.updateSessionControl).toHaveBeenCalledWith('session-a', 'archive')
    })
    expect(await screen.findByText('我们应该在meee2-workspace中做些什么？')).toBeInTheDocument()
  })

  it('cancels archive confirmation without archiving the session', async () => {
    renderWithI18n(<SessionLauncherView state={makeState()} />)

    fireEvent.click(await screen.findByRole('button', { name: '新增 Session 原生 Terminal' }))
    fireEvent.click(await screen.findByRole('button', { name: '归档 新增 Session 原生 Terminal' }))
    expect(await screen.findByRole('dialog', { name: '归档会话？' })).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: '取消' }))

    expect(screen.queryByRole('dialog', { name: '归档会话？' })).not.toBeInTheDocument()
    expect(api.updateSessionControl).not.toHaveBeenCalled()
    expect(screen.getByRole('button', { name: '新增 Session 原生 Terminal' })).toBeInTheDocument()
  })

  it('limits project sessions to eight until expanded', async () => {
    const sessions = Array.from({ length: 9 }, (_, index) => makeSession({
      id: `session-${index + 1}`,
      title: `Task ${index + 1}`,
      recentMessages: [{ role: 'user', text: `Task ${index + 1}` }],
      surfaceId: `surface-${index + 1}`,
      lastActivity: new Date(Date.now() - index * 60_000).toISOString(),
    }))

    renderWithI18n(<SessionLauncherView state={makeState(sessions)} />)

    await screen.findByRole('button', { name: 'meee2-workspace' })
    const expandProject = screen.queryByRole('button', { name: '展开 meee2-workspace' })
    if (expandProject) fireEvent.click(expandProject)
    await screen.findByText('Task 1')
    expect(screen.queryByText('Task 9')).not.toBeInTheDocument()
    fireEvent.click(await screen.findByRole('button', { name: '展开显示' }))
    expect(await screen.findByText('Task 9')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: '收起' }))
    await waitFor(() => expect(screen.queryByText('Task 9')).not.toBeInTheDocument())
  })

  it('keeps other expanded projects open after starting a project session', async () => {
    const stocksProject: SessionProject = {
      ...project,
      id: 'project-stocks',
      name: 'stocks',
      path: '/Users/kai/Code/stocks',
    }
    api.fetchSessionProjects.mockResolvedValue({ projects: [project, stocksProject] })
    api.createProjectSession.mockResolvedValue({
      project,
      surface: {
        provider: 'codex',
        sessionId: 'new-session',
        surfaceId: 'new-surface',
        title: 'Codex - meee2-workspace',
        cwd: project.path,
        command: 'codex --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust',
        status: 'running',
        createdAt: '2026-06-14T00:00:00Z',
        updatedAt: '2026-06-14T00:00:00Z',
      },
    })
    const sessions = [
      makeSession({
        id: 'project-session',
        recentMessages: [{ role: 'user', text: '当前项目会话' }],
        project: project.path,
        lastActivity: new Date(Date.now() - 60_000).toISOString(),
      }),
      makeSession({
        id: 'stocks-session',
        recentMessages: [{ role: 'user', text: '股票项目会话' }],
        project: stocksProject.path,
        surfaceId: 'stocks-surface',
        lastActivity: new Date(Date.now() - 5 * 60_000).toISOString(),
      }),
    ]

    renderWithI18n(<SessionLauncherView state={makeState(sessions)} />)

    await screen.findByText('当前项目会话')
    fireEvent.click(screen.getByRole('button', { name: '展开 stocks' }))
    expect(await screen.findByText('股票项目会话')).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: /启动会话/i }))

    await waitFor(() => {
      expect(api.createProjectSession).toHaveBeenCalledWith({
        projectId: 'project-a',
        provider: 'codex',
        permissionMode: 'fullAccess',
        planMode: false,
        initialPrompt: undefined,
      })
    })
    expect(screen.getByText('股票项目会话')).toBeInTheDocument()
  })

  it('passes plan mode when starting a project session', async () => {
    api.createProjectSession.mockResolvedValue({
      project,
      surface: {
        provider: 'codex',
        sessionId: 'plan-session',
        surfaceId: 'plan-surface',
        title: 'Codex - meee2-workspace',
        cwd: project.path,
        command: 'codex -c \'collaboration_mode="plan"\' --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust',
        status: 'running',
        createdAt: '2026-06-14T00:00:00Z',
        updatedAt: '2026-06-14T00:00:00Z',
      },
    })

    renderWithI18n(<SessionLauncherView state={makeState()} />)

    await screen.findByText('我们应该在meee2-workspace中做些什么？')
    const planSwitch = screen.getByRole('switch', { name: /Plan 模式/ })
    expect(planSwitch).toHaveAttribute('aria-checked', 'false')
    fireEvent.click(planSwitch)
    expect(planSwitch).toHaveAttribute('aria-checked', 'true')
    fireEvent.click(screen.getByRole('button', { name: /启动会话/i }))

    await waitFor(() => {
      expect(api.createProjectSession).toHaveBeenCalledWith({
        projectId: 'project-a',
        provider: 'codex',
        permissionMode: 'fullAccess',
        planMode: true,
        initialPrompt: undefined,
      })
    })
  })

  it('arms submit on first Enter and starts the project session on second Enter', async () => {
    api.createProjectSession.mockResolvedValue({
      project,
      surface: {
        provider: 'codex',
        sessionId: 'enter-session',
        surfaceId: 'enter-surface',
        title: 'Codex - meee2-workspace',
        cwd: project.path,
        command: 'codex --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust',
        status: 'running',
        createdAt: '2026-06-14T00:00:00Z',
        updatedAt: '2026-06-14T00:00:00Z',
      },
    })

    renderWithI18n(<SessionLauncherView state={makeState()} />)

    await screen.findByText('我们应该在meee2-workspace中做些什么？')
    const textarea = screen.getByPlaceholderText('随心输入')
    fireEvent.change(textarea, { target: { value: 'ship the launcher fix' } })

    fireEvent.keyDown(textarea, { key: 'Enter', code: 'Enter' })

    expect(api.createProjectSession).not.toHaveBeenCalled()
    expect(screen.getByRole('status')).toHaveTextContent('短时间内再按一次 Enter 即启动')

    fireEvent.keyDown(textarea, { key: 'Enter', code: 'Enter' })

    await waitFor(() => {
      expect(api.createProjectSession).toHaveBeenCalledWith({
        projectId: 'project-a',
        provider: 'codex',
        permissionMode: 'fullAccess',
        planMode: false,
        initialPrompt: 'ship the launcher fix',
      })
    })
  })

  it('does not show counts and does not indent temporary sessions', async () => {
    const temporarySession = makeSession({
      id: 'temp-existing',
      project: '/Users/kai/.meee2/workspaces/temporary/20260614-153012-a1b2c3',
      recentMessages: [{ role: 'user', text: '查看本地 omlx' }],
    })

    const { container } = renderWithI18n(<SessionLauncherView state={makeState([temporarySession])} />)

    await screen.findByText('查看本地 omlx')
    expect(container.querySelector('.session-launcher__sidebar-header span')).not.toBeInTheDocument()
    expect(container.querySelector('.session-launcher__group-header em')).not.toBeInTheDocument()
    expect(container.querySelector('.session-launcher__project-actions span')).not.toBeInTheDocument()
    const sessionList = container.querySelector('.session-launcher__session-list')
    expect(sessionList).not.toHaveClass('session-launcher__session-list--nested')
  })

  it('filters hidden sessions out of project and temporary launcher lists', async () => {
    const sessions = [
      makeSession({
        id: 'visible-project-session',
        recentMessages: [{ role: 'user', text: '继续可见项目会话' }],
      }),
      makeSession({
        id: 'hidden-project-session',
        recentMessages: [{ role: 'user', text: '隐藏项目会话' }],
        controlState: 'hidden',
      }),
      makeSession({
        id: 'hidden-temporary-session',
        project: '/Users/kai/.meee2/workspaces/temporary/hidden',
        recentMessages: [{ role: 'user', text: '隐藏临时会话' }],
        controlState: 'hidden',
      }),
    ]

    renderWithI18n(<SessionLauncherView state={makeState(sessions)} />)

    expect(await screen.findAllByText('meee2-workspace')).not.toHaveLength(0)
    const expandButton = screen.queryByRole('button', { name: '展开 meee2-workspace' })
    if (expandButton) fireEvent.click(expandButton)
    expect(await screen.findByRole('button', { name: '继续可见项目会话' })).toBeInTheDocument()
    expect(screen.queryByText('隐藏项目会话')).not.toBeInTheDocument()
    expect(screen.queryByText('隐藏临时会话')).not.toBeInTheDocument()
  })

  it('selects only the clicked temporary session when sessions have no surface id without reopening it', async () => {
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
    const { container } = renderWithI18n(<SessionLauncherView state={makeState(temporarySessions)} />)

    fireEvent.click(await screen.findByRole('button', { name: '临时问题 B' }))

    const selectedItems = container.querySelectorAll('.session-launcher__session-item.is-selected')
    expect(selectedItems).toHaveLength(1)
    expect(selectedItems[0]).toHaveTextContent('临时问题 B')
    expect(api.reopenLauncherSession).not.toHaveBeenCalled()
    expect(api.syncNativeSessionsWorkspace).not.toHaveBeenCalledWith(expect.objectContaining({
      phase: 'show',
      sessionId: expect.any(String),
    }))
  })

  it('does not auto-reopen a stale launcher session when selected', async () => {
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
    renderWithI18n(<SessionLauncherView state={makeState([staleSession])} />)

    const row = await screen.findByRole('button', { name: '继续历史临时问题' })
    fireEvent.click(row)

    expect(api.reopenLauncherSession).not.toHaveBeenCalled()
    expect(api.syncNativeSessionsWorkspace).not.toHaveBeenCalledWith(expect.objectContaining({
      phase: 'show',
      mode: 'terminal',
      sessionId: expect.any(String),
      surfaceId: expect.any(String),
    }))
    expect(await screen.findByText('这个 session 还没有可挂载的原生 terminal surface')).toBeInTheDocument()
  })

  it('switches live native terminal targets without hiding the current pane first', async () => {
    const sessions = [
      makeSession({
        id: 'live-a',
        recentMessages: [{ role: 'user', text: '继续 A' }],
        surfaceId: 'surface-a',
        lastActivity: new Date(Date.now() - 60_000).toISOString(),
      }),
      makeSession({
        id: 'live-b',
        recentMessages: [{ role: 'user', text: '继续 B' }],
        surfaceId: 'surface-b',
        lastActivity: new Date(Date.now() - 30_000).toISOString(),
      }),
    ]
    renderWithI18n(<SessionLauncherView state={makeState(sessions)} />)

    await screen.findByText('我们应该在meee2-workspace中做些什么？')
    fireEvent.click(await screen.findByRole('button', { name: '继续 A' }))
    await waitFor(() => {
      expect(api.syncNativeSessionsWorkspace).toHaveBeenCalledWith(expect.objectContaining({
        phase: 'show',
        sessionId: 'live-a',
        surfaceId: 'surface-a',
      }))
    })

    api.syncNativeSessionsWorkspace.mockClear()
    fireEvent.click(await screen.findByRole('button', { name: '继续 B' }))

    await waitFor(() => {
      expect(api.syncNativeSessionsWorkspace).toHaveBeenCalledWith(expect.objectContaining({
        phase: 'show',
        sessionId: 'live-b',
        surfaceId: 'surface-b',
      }))
    })
    expect(api.syncNativeSessionsWorkspace.mock.calls.some(([payload]) => payload.phase === 'hide')).toBe(false)
  })

  it('uses task context instead of internal node transcript titles', async () => {
    const session = makeSession({
      title: 'Node node-mpwdr7mh-2-node-2-transcript',
      currentTask: '修复 Session 标题',
      recentMessages: [],
    })
    const { container } = renderWithI18n(<SessionLauncherView state={makeState([session])} />)

    await screen.findByText('修复 Session 标题')
    expect(screen.queryByText(/Node node-mpwdr7mh/)).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: '修复 Session 标题' }))

    const terminalHeader = container.querySelector('.session-launcher-terminal__header strong')
    expect(terminalHeader).toHaveTextContent('修复 Session 标题')
    expect(container.querySelector('.session-launcher-terminal__header span')).toHaveTextContent('Codex')
    expect(container.querySelector('.session-launcher-terminal__header span')).toHaveTextContent('meee2-workspace')
    expect(container.querySelector('.session-launcher-terminal__status')).toHaveTextContent('运行中')
  })

  it('uses recap over the initial user question when recap exists', async () => {
    renderWithI18n(<SessionLauncherView state={makeState([makeSession({
      currentTask: '用户发起的问题会在没有 recap 时使用',
      recentMessages: [{ role: 'user', text: '用户发起的问题会在没有 recap 时使用' }],
      latestRecap: { content: '已经完成 session 标题与终端显示修复', timestamp: new Date().toISOString() },
    })])} />)

    await screen.findByText('已经完成 session 标题与终端显示修复')
    expect(screen.queryByText('用户发起的问题会在没有 recap 时使用')).not.toBeInTheDocument()
  })

  it('marks session rows that need input or are done', async () => {
    renderWithI18n(<SessionLauncherView state={makeState([
      makeSession({
        id: 'waiting-session',
        recentMessages: [{ role: 'user', text: '等待用户处理的任务' }],
        status: 'waitingForUser',
      }),
      makeSession({
        id: 'done-session',
        recentMessages: [{ role: 'user', text: '已经完成的任务' }],
        status: 'completed',
      }),
    ])} />)

    await screen.findByText('等待用户处理的任务')
    expect(screen.getByText('等待用户回复')).toBeInTheDocument()
    expect(screen.getByText('完成')).toBeInTheDocument()
  })

  it('opens a session context menu and renames the session through a modal', async () => {
    renderWithI18n(<SessionLauncherView state={makeState()} />)

    await screen.findByText('我们应该在meee2-workspace中做些什么？')
    const sessionButton = await screen.findByRole('button', { name: '新增 Session 原生 Terminal' })
    fireEvent.keyDown(sessionButton, { key: 'F10', shiftKey: true })

    const menu = await screen.findByRole('menu', { name: '新增 Session 原生 Terminal 的会话操作' })
    expect(within(menu).getByRole('menuitem', { name: '归档会话' })).toBeInTheDocument()
    expect(within(menu).getByRole('menuitem', { name: '置顶' })).toBeInTheDocument()
    expect(within(menu).getByRole('menuitem', { name: '重命名' })).toBeInTheDocument()

    fireEvent.click(within(menu).getByRole('menuitem', { name: '重命名' }))
    const input = await screen.findByLabelText('显示名称')
    fireEvent.change(input, { target: { value: 'Session 标题修复' } })
    fireEvent.click(screen.getByRole('button', { name: '重命名' }))

    expect(await screen.findByRole('button', { name: 'Session 标题修复' })).toBeInTheDocument()
    expect(localStorage.getItem('meee2.session.titleOverrides.v1')).toContain('Session 标题修复')
  })

  it('pins and archives from the session context menu', async () => {
    renderWithI18n(<SessionLauncherView state={makeState()} />)

    await screen.findByText('我们应该在meee2-workspace中做些什么？')
    const sessionButton = await screen.findByRole('button', { name: '新增 Session 原生 Terminal' })
    fireEvent.keyDown(sessionButton, { key: 'F10', shiftKey: true })
    fireEvent.click(await screen.findByRole('menuitem', { name: '置顶' }))
    expect(localStorage.getItem('meee2.session.pinned.v1')).toContain('session-a')

    const pinnedButton = await screen.findByRole('button', { name: '新增 Session 原生 Terminal' })
    fireEvent.keyDown(pinnedButton, { key: 'F10', shiftKey: true })
    fireEvent.click(await screen.findByRole('menuitem', { name: '归档会话' }))
    expect(await screen.findByRole('dialog', { name: '归档会话？' })).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: '归档会话' }))

    await waitFor(() => {
      expect(api.updateSessionControl).toHaveBeenCalledWith('session-a', 'archive')
    })
  })

  it('hides internal node ids when no task context is available', async () => {
    renderWithI18n(<SessionLauncherView state={makeState([makeSession({
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

    renderWithI18n(<SessionLauncherView state={makeState()} />)

    await screen.findByRole('button', { name: 'meee2-workspace' })
    fireEvent.click(screen.getByRole('button', { name: 'meee2-workspace 的更多操作' }))
    expect(screen.getByRole('menuitem', { name: '重命名' })).toBeInTheDocument()
    expect(screen.getByRole('menuitem', { name: '在 Finder 中显示' })).toBeInTheDocument()
    expect(screen.getByRole('menuitem', { name: '移除项目 - 保留文件' })).toBeInTheDocument()

    fireEvent.click(screen.getByRole('menuitem', { name: '重命名' }))
    const input = await screen.findByLabelText('显示名称')
    fireEvent.change(input, { target: { value: 'Launcher Lab' } })
    fireEvent.click(screen.getByRole('button', { name: '重命名' }))

    await waitFor(() => {
      expect(api.renameSessionProject).toHaveBeenCalledWith('project-a', { name: 'Launcher Lab' })
    })
    expect(await screen.findByText('我们应该在Launcher Lab中做些什么？')).toBeInTheDocument()
  })

  it('adds a folder from the project group hover action', async () => {
    renderWithI18n(<SessionLauncherView state={makeState()} />)

    await screen.findByText('项目')
    fireEvent.click(screen.getByRole('button', { name: '添加文件夹' }))

    await waitFor(() => {
      expect(api.pickSessionProjectDirectory).toHaveBeenCalled()
      expect(api.createSessionProject).toHaveBeenCalledWith({
        path: '/Users/kai/Code/new-project',
        preferredProvider: 'codex',
      })
    })
    expect(await screen.findByText('我们应该在new-project中做些什么？')).toBeInTheDocument()
  })

  it('confirms before forgetting a project from the actions menu', async () => {
    renderWithI18n(<SessionLauncherView state={makeState()} />)

    await screen.findByRole('button', { name: 'meee2-workspace' })
    fireEvent.click(screen.getByRole('button', { name: 'meee2-workspace 的更多操作' }))
    fireEvent.click(screen.getByRole('menuitem', { name: '移除项目 - 保留文件' }))

    expect(await screen.findByRole('dialog', { name: '移除项目？' })).toBeInTheDocument()
    expect(api.forgetSessionProject).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: '取消' }))
    expect(screen.queryByRole('dialog', { name: '移除项目？' })).not.toBeInTheDocument()
    expect(api.forgetSessionProject).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole('button', { name: 'meee2-workspace 的更多操作' }))
    fireEvent.click(screen.getByRole('menuitem', { name: '移除项目 - 保留文件' }))
    fireEvent.click(await screen.findByRole('button', { name: '移除项目' }))

    await waitFor(() => {
      expect(api.forgetSessionProject).toHaveBeenCalledWith('project-a')
    })
    expect(screen.queryByRole('button', { name: 'meee2-workspace' })).not.toBeInTheDocument()
  })

  it('reveals a project in Finder from the project actions menu', async () => {
    renderWithI18n(<SessionLauncherView state={makeState()} />)

    await screen.findByRole('button', { name: 'meee2-workspace' })
    fireEvent.click(screen.getByRole('button', { name: 'meee2-workspace 的更多操作' }))
    fireEvent.click(screen.getByRole('menuitem', { name: '在 Finder 中显示' }))

    await waitFor(() => {
      expect(api.revealSessionProjectInFinder).toHaveBeenCalledWith('project-a')
    })
  })

  it('project compose action opens the composer without changing collapse state', async () => {
    renderWithI18n(<SessionLauncherView state={makeState()} />)

    await screen.findByText('新增 Session 原生 Terminal')
    fireEvent.click(screen.getByRole('button', { name: '收起 meee2-workspace' }))
    await waitFor(() => expect(screen.queryByText('新增 Session 原生 Terminal')).not.toBeInTheDocument())

    fireEvent.click(screen.getByRole('button', { name: '在 meee2-workspace 中新建会话' }))

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

    renderWithI18n(<SessionLauncherView state={makeState([])} />)

    fireEvent.click(await screen.findByRole('button', { name: '新建临时会话' }))
    expect(await screen.findByText('我们该做什么？')).toBeInTheDocument()
    fireEvent.change(screen.getByPlaceholderText('随心输入'), {
      target: { value: 'try a temporary idea' },
    })
    fireEvent.click(screen.getByRole('button', { name: /启动会话/i }))

    await waitFor(() => {
      expect(api.createTemporarySession).toHaveBeenCalledWith({
        provider: 'codex',
        permissionMode: 'fullAccess',
        planMode: false,
        initialPrompt: 'try a temporary idea',
      })
      expect(api.syncNativeSessionsWorkspace).toHaveBeenCalledWith(expect.objectContaining({
        phase: 'show',
        mode: 'terminal',
        sessionId: 'temp-session',
        surfaceId: 'temp-surface',
        theme: 'dark',
      }))
    })
  })
})
