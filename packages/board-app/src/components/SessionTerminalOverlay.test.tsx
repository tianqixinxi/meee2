import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { I18nProvider } from '../lib/i18n'
import type { CanvasInfo, Session } from '../types'
import { SessionTerminalOverlay } from './SessionTerminalOverlay'

const apiMocks = vi.hoisted(() => ({
  syncNativeSessionsWorkspace: vi.fn(),
}))

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return {
    ...actual,
    syncNativeSessionsWorkspace: apiMocks.syncNativeSessionsWorkspace,
  }
})

const session: Session = {
  id: 'session-1',
  title: 'Build terminal overlay',
  project: '/Users/kai/project-that-should-not-be-in-header',
  pluginId: 'claude',
  pluginDisplayName: 'Claude',
  pluginColor: '#ff9500',
  status: 'running',
  inboxPending: 0,
  recentMessages: [],
  currentTool: null,
  usageStats: null,
  backgroundAgents: [],
  latestRecap: null,
  terminalKind: 'internal',
  terminalBackend: 'ghostty-surface',
  nativeWorkspaceAvailable: true,
  openTarget: 'native-workspace',
  surfaceId: 'surface-1',
  surfaceStatus: 'running',
  syncEnabled: false,
  syncTeamId: null,
  syncTeamName: null,
}

const canvas: CanvasInfo = {
  id: 'canvas-1',
  name: 'Launch Canvas',
  scope: 'personal',
  kind: 'board',
  isDefault: false,
  workspacePath: '',
}

class ResizeObserverMock {
  observe = vi.fn()
  disconnect = vi.fn()
}

describe('SessionTerminalOverlay', () => {
  beforeEach(() => {
    apiMocks.syncNativeSessionsWorkspace.mockReset()
    apiMocks.syncNativeSessionsWorkspace.mockReturnValue(true)
    vi.stubGlobal('ResizeObserver', ResizeObserverMock)
  })

  it('renders a sparse native terminal modal and closes from backdrop or explicit close button', async () => {
    const onClose = vi.fn()
    render(
      <I18nProvider>
        <SessionTerminalOverlay
          target={{ sessionId: 'session-1', canvasId: 'canvas-1' }}
          session={session}
          canvas={canvas}
          onClose={onClose}
        />
      </I18nProvider>,
    )

    expect(screen.getByRole('dialog', { name: 'Session terminal' })).toBeInTheDocument()
    expect(screen.getByText('Build terminal overlay')).toBeInTheDocument()
    expect(screen.getByText('running')).toBeInTheDocument()
    expect(screen.queryByText('/Users/kai/project-that-should-not-be-in-header')).not.toBeInTheDocument()
    expect(screen.queryByText('Launch Canvas')).not.toBeInTheDocument()
    await waitFor(() => {
      expect(apiMocks.syncNativeSessionsWorkspace.mock.calls.some(([payload]) => (
        payload.phase === 'show'
        && payload.mode === 'terminal'
        && payload.sessionId === 'session-1'
        && payload.surfaceId === 'surface-1'
      ))).toBe(true)
    })

    fireEvent.mouseDown(document.querySelector('.session-terminal-overlay__scrim') as HTMLElement)
    expect(onClose).toHaveBeenCalledTimes(1)

    fireEvent.click(screen.getByRole('button', { name: 'Close' }))
    expect(onClose).toHaveBeenCalledTimes(2)
  })

  it('keeps ghostty-surface sessions on the native terminal sync path', async () => {
    const onClose = vi.fn()
    render(
      <I18nProvider>
        <SessionTerminalOverlay
          target={{ sessionId: 'session-1', canvasId: 'canvas-1' }}
          session={{ ...session, terminalBackend: 'ghostty-surface' }}
          canvas={canvas}
          onClose={onClose}
        />
      </I18nProvider>,
    )

    await waitFor(() => {
      expect(apiMocks.syncNativeSessionsWorkspace.mock.calls.some(([payload]) => (
        payload.phase === 'show'
        && payload.mode === 'terminal'
        && payload.sessionId === 'session-1'
        && payload.surfaceId === 'surface-1'
      ))).toBe(true)
    })
  })
})
