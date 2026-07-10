import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { act, type ReactElement } from 'react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { I18nProvider } from '../lib/i18n'
import { SessionLauncherView } from './SessionLauncherView'
import type { BoardState, Session, SessionProject } from '../types'

const api = vi.hoisted(() => ({
  activateSession: vi.fn(),
  fetchSessionProjects: vi.fn(),
  createProjectSession: vi.fn(),
  createSessionProject: vi.fn(),
  createTemporarySession: vi.fn(),
  fetchSessionArtifacts: vi.fn(),
  forgetSessionProject: vi.fn(),
  pickSessionLaunchAttachments: vi.fn(),
  pickSessionProjectDirectory: vi.fn(),
  renameSessionProject: vi.fn(),
  reopenLauncherSession: vi.fn(),
  revealSessionProjectInFinder: vi.fn(),
  syncNativeSessionsWorkspace: vi.fn(),
  updateSessionControl: vi.fn(),
  uploadSessionLaunchAttachment: vi.fn(),
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

const providerResumeSessionId = '019ecba0-beb9-7dc3-b779-33f7f06453c0'
const lastSelectionKey = 'meee2.sessionLauncher.lastSelection'

function storeProjectSelection() {
  localStorage.setItem(lastSelectionKey, JSON.stringify({ kind: 'project', projectId: project.id }))
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
    providerResumeSessionId,
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
    storeProjectSelection()
    api.fetchSessionProjects.mockResolvedValue({ projects: [project] })
    api.activateSession.mockResolvedValue(true)
    api.fetchSessionArtifacts.mockResolvedValue({
      sessionId: 'session-a',
      candidates: [],
      artifacts: [],
      totalCount: 0,
      attachTargets: [],
    })
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
    api.pickSessionLaunchAttachments.mockResolvedValue({ ok: false, attachments: [] })
    api.uploadSessionLaunchAttachment.mockResolvedValue({
      path: '/Users/kai/Code/meee2-workspace/spec.png',
      filename: 'spec.png',
      contentType: 'image/png',
    })
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
    expect(screen.getByRole('button', { name: '权限模式' })).toHaveTextContent('执行前确认')
    expect(screen.getByPlaceholderText('随心输入')).toBeInTheDocument()
  })

  it('selects the latest session on first entry when no selection is stored', async () => {
    localStorage.removeItem(lastSelectionKey)
    const older = makeSession({
      id: 'older-session',
      recentMessages: [{ role: 'user', text: '较早的 Session' }],
      surfaceId: 'older-surface',
      lastActivity: '2026-06-14T08:00:00Z',
    })
    const latest = makeSession({
      id: 'latest-session',
      recentMessages: [{ role: 'user', text: '最近一次 Session' }],
      surfaceId: 'latest-surface',
      lastActivity: '2026-06-14T09:00:00Z',
    })
    const view = renderWithI18n(<SessionLauncherView state={makeState([older, latest])} />)

    const latestButton = await screen.findByRole('button', { name: '最近一次 Session' })
    await waitFor(() => expect(latestButton.closest('.session-launcher__session-item')).toHaveClass('is-selected'))
    expect(view.container.querySelector('.session-launcher-terminal__header strong')).toHaveTextContent('最近一次 Session')
    expect(screen.queryByText('我们应该在meee2-workspace中做些什么？')).not.toBeInTheDocument()
    await waitFor(() => {
      expect(api.syncNativeSessionsWorkspace).toHaveBeenCalledWith(expect.objectContaining({
        phase: 'show',
        mode: 'terminal',
        sessionId: 'latest-session',
        surfaceId: 'latest-surface',
      }))
    })
  })

  it('selects the requested session when opening the Sessions workspace', async () => {
    const requested = makeSession({
      id: 'requested-session',
      title: 'Claude Code - requested',
      recentMessages: [{ role: 'user', text: '来自 slash command 的 Session' }],
      surfaceId: 'requested-surface',
      lastActivity: '2026-06-14T09:00:00Z',
      pluginId: 'com.meee2.plugin.claude',
      pluginDisplayName: 'Claude Code',
      sessionScope: 'external',
    })

    const view = renderWithI18n(
      <SessionLauncherView
        state={makeState([makeSession(), requested])}
        openTarget={{ sessionId: 'requested-session', nonce: 1 }}
      />,
    )

    const requestedButton = await screen.findByRole('button', { name: '来自 slash command 的 Session' })
    await waitFor(() => expect(requestedButton.closest('.session-launcher__session-item')).toHaveClass('is-selected'))
    expect(view.container.querySelector('.session-launcher-terminal__header strong')).toHaveTextContent('来自 slash command 的 Session')
    expect(screen.queryByText('我们应该在meee2-workspace中做些什么？')).not.toBeInTheDocument()
  })

  it('keeps a stored stale selection passive until the user explicitly resumes it', async () => {
    localStorage.setItem(lastSelectionKey, JSON.stringify({
      kind: 'session',
      sessionId: 'stale-session',
      surfaceId: 'old-surface',
    }))
    const staleSession = makeSession({
      id: 'stale-session',
      title: 'Codex',
      project: '/Users/kai/Code/meee2-workspace',
      recentMessages: [{ role: 'user', text: '继续上次的 Session' }],
      terminalBackend: 'ghostty-surface',
      nativeWorkspaceAvailable: false,
      openTarget: 'web-fallback',
      surfaceId: null,
      providerResumeSessionId,
      surfaceStatus: 'exited',
    })

    renderWithI18n(<SessionLauncherView state={makeState([staleSession])} />)

    expect(await screen.findByRole('button', { name: '恢复会话' })).toBeInTheDocument()
    expect(api.reopenLauncherSession).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: '恢复会话' }))

    await waitFor(() => {
      expect(api.reopenLauncherSession).toHaveBeenCalledWith({
        sessionId: 'stale-session',
        providerResumeSessionId,
        provider: 'codex',
        permissionMode: 'onRequest',
        cwd: '/Users/kai/Code/meee2-workspace',
      })
    })
    expect(api.syncNativeSessionsWorkspace).not.toHaveBeenCalledWith(expect.objectContaining({
      phase: 'show',
      surfaceId: 'old-surface',
    }))
    await waitFor(() => {
      expect(api.syncNativeSessionsWorkspace).toHaveBeenCalledWith(expect.objectContaining({
        phase: 'show',
        mode: 'terminal',
        sessionId: 'restored-session',
        surfaceId: 'restored-surface',
      }))
    })
  })

  it('uses an explicitly remembered workspace permission when resuming', async () => {
    localStorage.setItem('meee2.sessionLauncher.permissionModes.v1', JSON.stringify({
      [project.id]: 'fullAccess',
    }))
    localStorage.setItem('meee2.sessionLauncher.rememberedFullAccess.v1', JSON.stringify([project.id]))
    localStorage.setItem(lastSelectionKey, JSON.stringify({
      kind: 'session',
      sessionId: 'full-access-session',
    }))
    const staleSession = makeSession({
      id: 'full-access-session',
      recentMessages: [{ role: 'user', text: '显式全权限会话' }],
      surfaceId: null,
      surfaceStatus: 'exited',
    })
    renderWithI18n(<SessionLauncherView state={makeState([staleSession])} />)

    expect(api.reopenLauncherSession).not.toHaveBeenCalled()
    fireEvent.click(await screen.findByRole('button', { name: '恢复会话' }))

    await waitFor(() => {
      expect(api.reopenLauncherSession).toHaveBeenCalledWith(expect.objectContaining({
        sessionId: 'full-access-session',
        permissionMode: 'fullAccess',
      }))
    })
  })

  it('resizes and fully collapses the launcher sidebar', async () => {
    renderWithI18n(<SessionLauncherView state={makeState()} />)

    await screen.findByText('我们应该在meee2-workspace中做些什么？')
    const launcher = document.querySelector('.session-launcher') as HTMLElement
    expect(launcher.style.getPropertyValue('--session-launcher-sidebar-width')).toBe('280px')

    fireEvent.pointerDown(screen.getByRole('button', { name: '调整会话侧边栏宽度' }), {
      clientX: 280,
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
      'codex --sandbox workspace-write --ask-for-approval on-request',
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

  it('remembers only an explicitly selected workspace permission mode', async () => {
    const first = renderWithI18n(<SessionLauncherView state={makeState()} />)

    await screen.findByText('我们应该在meee2-workspace中做些什么？')
    expect(screen.getByRole('button', { name: '权限模式' })).toHaveTextContent('执行前确认')
    fireEvent.click(screen.getByRole('button', { name: '权限模式' }))
    fireEvent.click(screen.getByRole('option', { name: /完全访问/ }))
    await waitFor(() => {
      expect(localStorage.getItem('meee2.sessionLauncher.permissionModes.v1') ?? '').not.toContain('fullAccess')
    })
    first.unmount()

    const second = renderWithI18n(<SessionLauncherView state={makeState()} />)
    await screen.findByText('我们应该在meee2-workspace中做些什么？')
    expect(screen.getByRole('button', { name: '权限模式' })).toHaveTextContent('执行前确认')
    fireEvent.click(screen.getByRole('button', { name: '权限模式' }))
    fireEvent.click(screen.getByRole('option', { name: /完全访问/ }))
    fireEvent.click(screen.getByRole('checkbox', { name: '为此工作区记住完全访问' }))
    await waitFor(() => {
      expect(localStorage.getItem('meee2.sessionLauncher.permissionModes.v1')).toContain('fullAccess')
      expect(localStorage.getItem('meee2.sessionLauncher.rememberedFullAccess.v1')).toContain(project.id)
    })
    second.unmount()

    renderWithI18n(<SessionLauncherView state={makeState()} />)
    await screen.findByText('我们应该在meee2-workspace中做些什么？')
    expect(screen.getByRole('button', { name: '权限模式' })).toHaveTextContent('完全访问')
  })

  it('shows compact nested project sessions and selects the native terminal target', async () => {
    renderWithI18n(<SessionLauncherView state={makeState()} />)

    await screen.findByText('我们应该在meee2-workspace中做些什么？')
    const projectButton = screen.getByRole('button', { name: 'meee2-workspace' })
    expect(within(projectButton).queryByText('/Users/kai/Code/meee2-workspace')).not.toBeInTheDocument()

    const sessionButton = await screen.findByRole('button', { name: '新增 Session 原生 Terminal' })
    expect(within(sessionButton).queryByText(/running|小时前|分钟前|天前|周前/)).not.toBeInTheDocument()
    expect(within(sessionButton).getByText(/小时|分|刚刚/)).toBeInTheDocument()
    expect(sessionButton).toHaveAttribute('title', expect.stringContaining('新增 Session 原生 Terminal'))
    expect(sessionButton).toHaveAttribute('title', expect.stringContaining('/Users/kai/Code/meee2-workspace'))
    expect(sessionButton).toHaveAttribute('title', expect.stringContaining('Codex'))
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

  it('restores the selected native terminal session after leaving and returning to the session page', async () => {
    const first = renderWithI18n(<SessionLauncherView state={makeState()} />)

    await screen.findByText('我们应该在meee2-workspace中做些什么？')
    fireEvent.click(await screen.findByRole('button', { name: '新增 Session 原生 Terminal' }))
    await waitFor(() => {
      expect(api.syncNativeSessionsWorkspace).toHaveBeenCalledWith(expect.objectContaining({
        phase: 'show',
        mode: 'terminal',
        sessionId: 'session-a',
        surfaceId: 'surface-a',
      }))
    })
    expect(localStorage.getItem('meee2.sessionLauncher.lastSelection')).toContain('session-a')

    first.unmount()
    api.syncNativeSessionsWorkspace.mockClear()

    const returned = renderWithI18n(<SessionLauncherView state={makeState()} />)

    await waitFor(() => {
      expect(returned.container.querySelector('.session-launcher-terminal__header strong')).toHaveTextContent('新增 Session 原生 Terminal')
      expect(api.syncNativeSessionsWorkspace).toHaveBeenCalledWith(expect.objectContaining({
        phase: 'show',
        mode: 'terminal',
        sessionId: 'session-a',
        surfaceId: 'surface-a',
      }))
    })
    expect(returned.container.querySelector('.session-launcher__main')).not.toHaveTextContent('我们应该在meee2-workspace中做些什么？')
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
        permissionMode: 'onRequest',
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
        command: 'codex --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust',
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
        permissionMode: 'onRequest',
        planMode: true,
        initialPrompt: undefined,
      })
    })
  })

  it('passes selected launch attachments when starting a project session', async () => {
    const attachment = {
      path: '/Users/kai/Code/meee2-workspace/spec.png',
      filename: 'spec.png',
      contentType: 'image/png',
    }
    api.pickSessionLaunchAttachments.mockResolvedValue({ ok: true, attachments: [attachment] })
    api.createProjectSession.mockResolvedValue({
      project,
      surface: {
        provider: 'codex',
        sessionId: 'attachment-session',
        surfaceId: 'attachment-surface',
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
    fireEvent.click(screen.getByRole('button', { name: '添加图片或文件' }))

    expect(await screen.findByText('spec.png')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: /启动会话/i }))

    await waitFor(() => {
      expect(api.createProjectSession).toHaveBeenCalledWith({
        projectId: 'project-a',
        provider: 'codex',
        permissionMode: 'onRequest',
        planMode: false,
        initialPrompt: undefined,
        attachments: [attachment],
      })
    })
  })

  it('resets the project composer draft after creating a session', async () => {
    const attachment = {
      path: '/Users/kai/Code/meee2-workspace/spec.png',
      filename: 'spec.png',
      contentType: 'image/png',
    }
    api.pickSessionLaunchAttachments.mockResolvedValue({ ok: true, attachments: [attachment] })
    api.createProjectSession.mockResolvedValue({
      project,
      surface: {
        provider: 'codex',
        sessionId: 'reset-session',
        surfaceId: 'reset-surface',
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
    fireEvent.change(screen.getByPlaceholderText('随心输入'), {
      target: { value: 'summarize these inputs' },
    })
    fireEvent.click(screen.getByRole('button', { name: '添加图片或文件' }))
    expect(await screen.findByText('spec.png')).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: /启动会话/i }))
    await waitFor(() => {
      expect(api.createProjectSession).toHaveBeenCalledWith(expect.objectContaining({
        initialPrompt: 'summarize these inputs',
        attachments: [attachment],
      }))
    })

    fireEvent.click(screen.getByRole('button', { name: '在 meee2-workspace 中新建会话' }))

    expect(screen.getByPlaceholderText('随心输入')).toHaveValue('')
    expect(screen.queryByText('spec.png')).not.toBeInTheDocument()
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
        permissionMode: 'onRequest',
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

  it('resumes only the explicitly confirmed temporary session when no live surface exists', async () => {
    const temporarySessions = [
      makeSession({
        id: 'temp-a',
        project: '/Users/kai/.meee2/workspaces/temporary/a',
        title: 'Claude Code',
        recentMessages: [{ role: 'user', text: '临时问题 A' }],
        surfaceId: null,
        providerResumeSessionId: '7c9a9e9e-1111-4111-8111-111111111111',
        surfaceStatus: 'exited',
      }),
      makeSession({
        id: 'temp-b',
        project: '/Users/kai/.meee2/workspaces/temporary/b',
        title: 'Claude Code',
        recentMessages: [{ role: 'user', text: '临时问题 B' }],
        surfaceId: null,
        providerResumeSessionId: '7c9a9e9e-2222-4222-8222-222222222222',
        surfaceStatus: 'exited',
      }),
    ]
    renderWithI18n(<SessionLauncherView state={makeState(temporarySessions)} />)

    fireEvent.click(await screen.findByRole('button', { name: '临时问题 B' }))

    expect(api.reopenLauncherSession).not.toHaveBeenCalled()
    fireEvent.click(await screen.findByRole('button', { name: '恢复会话' }))

    await waitFor(() => {
      expect(api.reopenLauncherSession).toHaveBeenCalledWith({
        sessionId: 'temp-b',
        providerResumeSessionId: '7c9a9e9e-2222-4222-8222-222222222222',
        provider: 'codex',
        permissionMode: 'onRequest',
        cwd: '/Users/kai/.meee2/workspaces/temporary/b',
      })
    })
    await waitFor(() => {
      expect(api.syncNativeSessionsWorkspace).toHaveBeenCalledWith(expect.objectContaining({
        phase: 'show',
        mode: 'terminal',
        sessionId: 'restored-session',
        surfaceId: 'restored-surface',
      }))
    })
  })

  it('reopens a stale launcher session only after explicit resume', async () => {
    let resolveReopen: (value: Awaited<ReturnType<typeof api.reopenLauncherSession>>) => void = () => {}
    api.reopenLauncherSession.mockReturnValueOnce(new Promise((resolve) => {
      resolveReopen = resolve
    }))
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
      providerResumeSessionId,
      surfaceStatus: 'exited',
    })
    renderWithI18n(<SessionLauncherView state={makeState([staleSession])} />)

    const row = await screen.findByRole('button', { name: '继续历史临时问题' })
    fireEvent.click(row)

    expect(api.reopenLauncherSession).not.toHaveBeenCalled()
    fireEvent.click(await screen.findByRole('button', { name: '恢复会话' }))
    expect(await screen.findByText('正在恢复原生 terminal session...')).toBeInTheDocument()
    await waitFor(() => {
      expect(api.reopenLauncherSession).toHaveBeenCalledWith({
        sessionId: 'stale-session',
        providerResumeSessionId,
        provider: 'claude',
        permissionMode: 'onRequest',
        cwd: '/Users/kai/.meee2/workspaces/temporary/stale',
      })
    })
    await act(async () => {
      resolveReopen({
        ok: true,
        action: 'resume',
        surface: {
          provider: 'claude',
          sessionId: 'restored-session',
          surfaceId: 'restored-surface',
          title: 'Claude Code - restored',
          cwd: '/Users/kai/.meee2/workspaces/temporary/stale',
          command: 'claude --resume restored --dangerously-skip-permissions',
          status: 'running',
          createdAt: '2026-06-14T00:00:00Z',
          updatedAt: '2026-06-14T00:00:00Z',
        },
      })
    })
    await waitFor(() => {
      expect(api.syncNativeSessionsWorkspace).toHaveBeenCalledWith(expect.objectContaining({
        phase: 'show',
        mode: 'terminal',
        sessionId: 'restored-session',
        surfaceId: 'restored-surface',
      }))
    })
  })

  it('opens an external terminal only after the explicit recovery action', async () => {
    const staleSession = makeSession({
      id: 'external-recovery-session',
      title: 'Claude Code',
      pluginDisplayName: 'Claude Code',
      pluginId: 'com.meee2.plugin.claude',
      project: '/Users/kai/.meee2/workspaces/temporary/external',
      recentMessages: [{ role: 'user', text: '在外部终端中继续' }],
      terminalBackend: 'ghostty-surface',
      nativeWorkspaceAvailable: false,
      openTarget: 'web-fallback',
      surfaceId: null,
      providerResumeSessionId,
      surfaceStatus: 'exited',
    })
    renderWithI18n(<SessionLauncherView state={makeState([staleSession])} />)

    fireEvent.click(await screen.findByRole('button', { name: '在外部终端中继续' }))

    expect(api.activateSession).not.toHaveBeenCalled()
    expect(api.reopenLauncherSession).not.toHaveBeenCalled()
    fireEvent.click(await screen.findByRole('button', { name: '打开外部终端' }))

    await waitFor(() => {
      expect(api.activateSession).toHaveBeenCalledWith('external-recovery-session')
    })
    expect(api.reopenLauncherSession).not.toHaveBeenCalled()
  })

  it('collapses the restored live surface into the clicked historical session row', async () => {
    const staleSession = makeSession({
      id: 'historical-session',
      title: 'Codex',
      project: project.path,
      recentMessages: [{ role: 'user', text: '继续旧的 Session' }],
      terminalBackend: 'ghostty-surface',
      nativeWorkspaceAvailable: false,
      openTarget: 'web-fallback',
      surfaceId: null,
      providerResumeSessionId,
      surfaceStatus: 'exited',
      lastActivity: new Date(Date.now() - 2 * 60_000).toISOString(),
    })
    const restoredSession = makeSession({
      id: 'restored-session',
      title: 'Codex - restored',
      project: project.path,
      recentMessages: [{ role: 'user', text: '新建出来的 restored surface' }],
      surfaceId: 'restored-surface',
      surfaceStatus: 'running',
      nativeWorkspaceAvailable: true,
      openTarget: 'native-workspace',
      lastActivity: new Date(Date.now() - 30_000).toISOString(),
    })
    const view = renderWithI18n(<SessionLauncherView state={makeState([staleSession])} />)

    await screen.findByText('我们应该在meee2-workspace中做些什么？')
    fireEvent.click(await screen.findByRole('button', { name: '继续旧的 Session' }))
    expect(api.reopenLauncherSession).not.toHaveBeenCalled()
    fireEvent.click(await screen.findByRole('button', { name: '恢复会话' }))

    await waitFor(() => {
      expect(api.syncNativeSessionsWorkspace).toHaveBeenCalledWith(expect.objectContaining({
        phase: 'show',
        mode: 'terminal',
        sessionId: 'restored-session',
        surfaceId: 'restored-surface',
      }))
    })

    view.rerender(<I18nProvider><SessionLauncherView state={makeState([restoredSession, staleSession])} /></I18nProvider>)

    expect(await screen.findByRole('button', { name: '继续旧的 Session' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: '新建出来的 restored surface' })).not.toBeInTheDocument()
    expect(view.container.querySelectorAll('.session-launcher__session-item.is-selected')).toHaveLength(1)
    expect(view.container.querySelector('.session-launcher-terminal__header strong')).toHaveTextContent('继续旧的 Session')
    expect(view.container.querySelector('.session-launcher-terminal__status')).toHaveTextContent('运行中')
  })

  it('hides a stale launcher session when no provider resume id is known', async () => {
    const staleSession = makeSession({
      id: 'historical-session-without-provider-id',
      recentMessages: [{ role: 'user', text: '没有 provider resume id 的旧 Session' }],
      terminalBackend: 'ghostty-surface',
      nativeWorkspaceAvailable: false,
      openTarget: 'web-fallback',
      surfaceId: null,
      providerResumeSessionId: null,
      surfaceStatus: 'exited',
    })

    renderWithI18n(<SessionLauncherView state={makeState([staleSession])} />)

    await screen.findByText('我们应该在meee2-workspace中做些什么？')
    expect(screen.queryByRole('button', { name: '没有 provider resume id 的旧 Session' })).not.toBeInTheDocument()
    expect(api.reopenLauncherSession).not.toHaveBeenCalled()
  })

  it('uses the user request instead of the plan-mode system prompt in resume toasts', async () => {
    const onToast = vi.fn()
    api.reopenLauncherSession.mockResolvedValueOnce({
      ok: true,
      action: 'resume',
      surface: {
        provider: 'codex',
        sessionId: 'restored-session',
        surfaceId: 'restored-surface',
        title: 'Codex - restored',
        cwd: '/Users/kai/Code/meee2-workspace',
        command: `codex resume ${providerResumeSessionId} --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust`,
        status: 'running',
        createdAt: '2026-06-14T00:00:00Z',
        updatedAt: '2026-06-14T00:00:00Z',
      },
    })
    const staleSession = makeSession({
      id: 'plan-mode-session',
      currentTask: [
        'Plan mode is enabled for this Codex session. First produce a plan.',
        '',
        'User request:',
        '支持Session新建页面输入图片，用户粘贴即可',
      ].join('\n'),
      recentMessages: [],
      terminalBackend: 'ghostty-surface',
      nativeWorkspaceAvailable: false,
      openTarget: 'web-fallback',
      surfaceId: null,
      providerResumeSessionId,
      surfaceStatus: 'exited',
    })

    renderWithI18n(<SessionLauncherView state={makeState([staleSession])} onToast={onToast} />)

    await screen.findByText('我们应该在meee2-workspace中做些什么？')
    const title = await screen.findByText('支持Session新建页面输入图片，用户粘贴即可')
    fireEvent.click(title.closest('button')!)
    expect(api.reopenLauncherSession).not.toHaveBeenCalled()
    fireEvent.click(await screen.findByRole('button', { name: '恢复会话' }))

    await waitFor(() => {
      expect(api.reopenLauncherSession).toHaveBeenCalledWith({
        sessionId: 'plan-mode-session',
        providerResumeSessionId,
        provider: 'codex',
        permissionMode: 'onRequest',
        cwd: '/Users/kai/Code/meee2-workspace',
      })
    })
    await waitFor(() => {
      expect(onToast).toHaveBeenCalledWith(
        'success',
        '已恢复 支持Session新建页面输入图片，用户粘贴即可',
      )
    })
    expect(onToast).not.toHaveBeenCalledWith(
      'success',
      expect.stringContaining('Plan mode is enabled'),
    )
  })

  it('labels reused restored terminals as switches instead of new terminal starts', async () => {
    const onToast = vi.fn()
    api.reopenLauncherSession.mockResolvedValueOnce({
      ok: true,
      action: 'reuse',
      surface: {
        provider: 'codex',
        sessionId: 'restored-session',
        surfaceId: 'restored-surface',
        title: 'Codex - restored',
        cwd: '/Users/kai/Code/meee2-workspace',
        command: `codex resume ${providerResumeSessionId} --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust`,
        status: 'running',
        createdAt: '2026-06-14T00:00:00Z',
        updatedAt: '2026-06-14T00:00:00Z',
      },
    })
    const staleSession = makeSession({
      id: 'already-restored-session',
      title: 'Codex',
      recentMessages: [{ role: 'user', text: '已经恢复过的 Session' }],
      terminalBackend: 'ghostty-surface',
      nativeWorkspaceAvailable: false,
      openTarget: 'web-fallback',
      surfaceId: null,
      providerResumeSessionId,
      surfaceStatus: 'exited',
    })

    renderWithI18n(<SessionLauncherView state={makeState([staleSession])} onToast={onToast} />)

    await screen.findByText('我们应该在meee2-workspace中做些什么？')
    fireEvent.click(await screen.findByRole('button', { name: '已经恢复过的 Session' }))
    expect(api.reopenLauncherSession).not.toHaveBeenCalled()
    fireEvent.click(await screen.findByRole('button', { name: '恢复会话' }))

    await waitFor(() => {
      expect(onToast).toHaveBeenCalledWith('success', '已切换到 已经恢复过的 Session')
    })
    expect(onToast).not.toHaveBeenCalledWith(
      'success',
      expect.stringContaining('启动新 terminal'),
    )
  })

  it('does not include the Codex /plan slash command in session titles', async () => {
    const planSession = makeSession({
      id: 'plan-slash-session',
      currentTask: '/plan hi',
      recentMessages: [],
      terminalBackend: 'ghostty-surface',
      nativeWorkspaceAvailable: false,
      openTarget: 'web-fallback',
      surfaceId: null,
      providerResumeSessionId,
      surfaceStatus: 'exited',
    })

    renderWithI18n(<SessionLauncherView state={makeState([planSession])} />)

    expect(screen.getByRole('button', { name: 'hi' })).toBeInTheDocument()
    await waitFor(() => expect(screen.queryByText('正在加载项目')).not.toBeInTheDocument())
    expect(screen.getByRole('button', { name: /^hi(?: ·|$)/ })).toBeInTheDocument()
    expect(screen.queryByText('/plan hi')).not.toBeInTheDocument()
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
    expect(api.syncNativeSessionsWorkspace.mock.calls.some(([payload]) => payload.phase === 'detach')).toBe(false)
  })

  it('forces native terminal show when an artifact modal restore event fires', async () => {
    const session = makeSession({
      currentTask: '修复 Session 标题',
      recentMessages: [],
    })
    renderWithI18n(<SessionLauncherView state={makeState([session])} />)

    await screen.findByText('修复 Session 标题')
    fireEvent.click(screen.getByRole('button', { name: '修复 Session 标题' }))
    await waitFor(() => {
      expect(api.syncNativeSessionsWorkspace).toHaveBeenCalledWith(expect.objectContaining({
        phase: 'show',
        sessionId: 'session-a',
        surfaceId: 'surface-a',
      }))
    })

    api.syncNativeSessionsWorkspace.mockClear()
    window.dispatchEvent(new Event('meee2:restore-native-sessions-workspace'))

    await waitFor(() => {
      expect(api.syncNativeSessionsWorkspace).toHaveBeenCalledWith(expect.objectContaining({
        phase: 'show',
        sessionId: 'session-a',
        surfaceId: 'surface-a',
        webPhase: 'sessionLauncher.show',
      }))
    })
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

    await screen.findByText('session 标题与终端显示修复')
    expect(screen.queryByText('用户发起的问题会在没有 recap 时使用')).not.toBeInTheDocument()
  })

  it('does not let a Codex context compaction signal override the active task title', async () => {
    renderWithI18n(<SessionLauncherView state={makeState([makeSession({
      currentTask: '优化 Artifact tab',
      recentMessages: [{ role: 'user', text: '不好看，而且 promote 为什么不能点击' }],
      latestRecap: null,
      providerRecapSignals: [{
        id: 'codex-compact-1',
        provider: 'codex',
        sessionId: 'session-a',
        intent: 'context_compaction',
        content: 'Summary: 已修改多个文件，下一步继续跑测试。',
        timestamp: new Date().toISOString(),
        confidence: 'medium',
      }],
    })])} />)

    await screen.findByText('优化 Artifact tab')
    expect(screen.queryByText(/已修改多个文件/)).not.toBeInTheDocument()
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
    fireEvent.contextMenu(sessionButton, { clientX: 321, clientY: 222 })

    const menu = await screen.findByRole('menu', { name: '新增 Session 原生 Terminal 的会话操作' })
    expect(menu.parentElement).toBe(document.body)
    expect(menu).toHaveStyle({ left: '321px', top: '222px' })
    expect(within(menu).getByRole('menuitem', { name: '归档会话' })).toBeInTheDocument()
    expect(within(menu).getByRole('menuitem', { name: '查看产物' })).toBeInTheDocument()
    expect(within(menu).getByRole('menuitem', { name: '置顶' })).toBeInTheDocument()
    expect(within(menu).getByRole('menuitem', { name: '重命名' })).toBeInTheDocument()

    fireEvent.click(within(menu).getByRole('menuitem', { name: '重命名' }))
    const input = await screen.findByLabelText('显示名称')
    fireEvent.change(input, { target: { value: 'Session 标题修复' } })
    fireEvent.click(screen.getByRole('button', { name: '重命名' }))

    expect(await screen.findByRole('button', { name: 'Session 标题修复' })).toBeInTheDocument()
    expect(localStorage.getItem('meee2.session.titleOverrides.v1')).toContain('Session 标题修复')
  })

  it('switches to the artifact tab from the context menu', async () => {
    const session = makeSession()
    const onOpenSessionArtifacts = vi.fn()
    renderWithI18n(<SessionLauncherView state={makeState([session])} onOpenSessionArtifacts={onOpenSessionArtifacts} />)

    await screen.findByText('我们应该在meee2-workspace中做些什么？')
    const sessionButton = await screen.findByRole('button', { name: '新增 Session 原生 Terminal' })
    fireEvent.keyDown(sessionButton, { key: 'F10', shiftKey: true })

    const menu = await screen.findByRole('menu', { name: '新增 Session 原生 Terminal 的会话操作' })
    fireEvent.click(within(menu).getByRole('menuitem', { name: '查看产物' }))

    const artifactTab = await screen.findByRole('tab', { name: 'Artifact' })
    expect(artifactTab).toHaveAttribute('aria-selected', 'true')
    expect(await screen.findByRole('heading', { name: '产物' })).toBeInTheDocument()
    expect(api.reopenLauncherSession).not.toHaveBeenCalled()
    expect(onOpenSessionArtifacts).not.toHaveBeenCalled()
  })

  it('renders artifacts inline without a details button in the artifact tab', async () => {
    const session = makeSession({
      currentTask: '修复 Session 标题',
      recentMessages: [],
    })
    const onOpenSessionArtifacts = vi.fn()
    renderWithI18n(<SessionLauncherView state={makeState([session])} onOpenSessionArtifacts={onOpenSessionArtifacts} />)

    await screen.findByText('修复 Session 标题')
    fireEvent.click(screen.getByRole('button', { name: '修复 Session 标题' }))

    fireEvent.click(await screen.findByRole('tab', { name: 'Artifact' }))
    expect(await screen.findByRole('heading', { name: '产物' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: '查看详情页' })).not.toBeInTheDocument()
    expect(onOpenSessionArtifacts).not.toHaveBeenCalled()
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
        permissionMode: 'onRequest',
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
