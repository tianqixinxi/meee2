import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { useState, type ReactElement } from 'react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { I18nProvider } from '../lib/i18n'
import type { BoardState, Session } from '../types'
import { SessionsView } from './SessionsView'

const api = vi.hoisted(() => ({
  closeSession: vi.fn(),
  closeSessionSurface: vi.fn(),
  createMemoryRecord: vi.fn(),
  deleteMemoryRecord: vi.fn(),
  fetchMemoryRecords: vi.fn(),
  fetchSessionIntakeDiagnostics: vi.fn(),
  fetchTranscript: vi.fn(),
  injectToSession: vi.fn(),
  listSessionSurfaces: vi.fn(),
  openAccessibilitySettings: vi.fn(),
  openNativeTerminalSurface: vi.fn(),
  pushToDesktopNow: vi.fn(),
  respondToSessionPermission: vi.fn(),
  updateMemoryRecord: vi.fn(),
  updateSessionControl: vi.fn(),
}))

vi.mock('../api', () => api)
vi.mock('../lib/theme', () => ({
  useTheme: () => ({ resolvedTheme: 'dark' }),
}))

function makeSession(overrides: Partial<Session> = {}): Session {
  return {
    id: 'session-a',
    title: 'Codex - A',
    project: '/Users/kai/Code/meee2-workspace',
    pluginId: 'com.meee2.plugin.codex',
    pluginDisplayName: 'Codex',
    pluginColor: '#8b5cf6',
    status: 'running',
    inboxPending: 0,
    recentMessages: [{ role: 'user', text: 'Work A' }],
    currentTool: 'terminal',
    usageStats: null,
    backgroundAgents: [],
    latestRecap: null,
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

function makeState(sessions: Session[]): BoardState {
  return {
    sessions,
    channels: [],
    coordinationGroups: [],
  }
}

function renderWithI18n(ui: ReactElement) {
  return render(<I18nProvider>{ui}</I18nProvider>)
}

function internalRail(): HTMLElement {
  const rail = document.querySelector('.sessions-list--internal')
  expect(rail).not.toBeNull()
  return rail as HTMLElement
}

function ControlledSessionsView({ state, initialSelectedId }: { state: BoardState; initialSelectedId: string }) {
  const [selectedSessionId, setSelectedSessionId] = useState<string | null>(initialSelectedId)
  return (
    <SessionsView
      state={state}
      unreadSids={new Set()}
      selectedSessionId={selectedSessionId}
      onSelectedSessionChange={setSelectedSessionId}
    />
  )
}

describe('SessionsView terminal core', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    localStorage.clear()
    localStorage.setItem('meee2.locale', 'en')
    api.fetchSessionIntakeDiagnostics.mockResolvedValue({
      ok: true,
      items: [],
      liveSessions: 2,
      storedSessions: 2,
      historicalSessions: 0,
    })
    api.listSessionSurfaces.mockResolvedValue({
      surfaces: [
        { surfaceId: 'surface-a', sessionId: 'session-a', provider: 'codex', status: 'running' },
        { surfaceId: 'surface-b', sessionId: 'session-b', provider: 'codex', status: 'running' },
      ],
    })
    api.openNativeTerminalSurface.mockReturnValue(true)
  })

  it('switches live internal sessions without requesting destructive detach', async () => {
    const sessionA = makeSession()
    const sessionB = makeSession({
      id: 'session-b',
      title: 'Codex - B',
      recentMessages: [{ role: 'user', text: 'Work B' }],
      surfaceId: 'surface-b',
      lastActivity: new Date(Date.now() - 30_000).toISOString(),
    })

    renderWithI18n(
      <ControlledSessionsView state={makeState([sessionA, sessionB])} initialSelectedId="session-a" />,
    )

    await screen.findByText('Work A')
    await waitFor(() => {
      expect(api.openNativeTerminalSurface).toHaveBeenCalledWith(expect.objectContaining({
        type: 'attach',
        sessionId: 'session-a',
        surfaceId: 'surface-a',
      }))
    })

    api.openNativeTerminalSurface.mockClear()
    const sessionBRow = screen.getByText('Work B').closest('.sessions-row')
    expect(sessionBRow).not.toBeNull()
    fireEvent.click(sessionBRow as HTMLElement)

    await waitFor(() => {
      expect(api.openNativeTerminalSurface).toHaveBeenCalledWith(expect.objectContaining({
        type: 'attach',
        sessionId: 'session-b',
        surfaceId: 'surface-b',
      }))
    })
    expect(api.openNativeTerminalSurface).not.toHaveBeenCalledWith(expect.objectContaining({
      type: 'prewarm',
      sessionId: 'session-b',
      webPhase: 'react.rowSelect.prewarm',
    }))
    await new Promise((resolve) => window.setTimeout(resolve, 180))
    expect(api.openNativeTerminalSurface).not.toHaveBeenCalledWith(expect.objectContaining({
      type: 'hide',
      sessionId: 'session-a',
      surfaceId: 'surface-a',
    }))
    expect(api.openNativeTerminalSurface).not.toHaveBeenCalledWith(expect.objectContaining({
      type: 'detach',
    }))
  })

  it('does not insert a selected hidden session into the active rail', async () => {
    const activeSession = makeSession({
      id: 'session-active',
      title: 'Codex - Active',
      recentMessages: [{ role: 'user', text: 'Visible active session' }],
      surfaceId: 'surface-active',
      lastActivity: new Date(Date.now() - 10_000).toISOString(),
    })
    const hiddenSession = makeSession({
      id: 'session-hidden',
      title: 'Codex - Hidden',
      recentMessages: [{ role: 'user', text: 'Hidden selected session' }],
      surfaceId: 'surface-hidden',
      controlState: 'hidden',
      lastActivity: new Date(Date.now() - 5_000).toISOString(),
    })

    renderWithI18n(
      <ControlledSessionsView
        state={makeState([activeSession, hiddenSession])}
        initialSelectedId="session-hidden"
      />,
    )

    await screen.findByText('Visible active session')
    const rail = internalRail()
    expect(rail).toHaveTextContent('Visible active session')
    expect(rail).not.toHaveTextContent('Hidden selected session')
  })

  it('dedupes transient aliases that point at the same internal surface', async () => {
    const liveSurface = makeSession({
      id: 'session-live',
      title: 'Codex - Live',
      recentMessages: [{ role: 'user', text: 'Same native surface' }],
      surfaceId: 'surface-shared',
      providerResumeSessionId: 'provider-shared',
      lastActivity: new Date(Date.now() - 5_000).toISOString(),
    })
    const transientAlias = makeSession({
      id: 'provider-shared',
      title: 'Codex - Alias',
      recentMessages: [{ role: 'user', text: 'Transient alias row' }],
      surfaceId: 'surface-shared',
      providerResumeSessionId: 'provider-shared',
      lastActivity: new Date(Date.now() - 1_000).toISOString(),
    })

    renderWithI18n(
      <ControlledSessionsView
        state={makeState([liveSurface, transientAlias])}
        initialSelectedId="session-live"
      />,
    )

    await screen.findByText('Same native surface')
    const rail = internalRail()
    expect(rail).toHaveTextContent('Same native surface')
    expect(rail).not.toHaveTextContent('Transient alias row')
  })
})
