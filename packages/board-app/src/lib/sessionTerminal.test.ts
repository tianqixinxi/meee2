import { describe, expect, it } from 'vitest'
import {
  isLiveInternalTerminalSession,
  resolveSessionCanvasId,
} from './sessionTerminal'
import type { CanvasInfo, Session } from '../types'

const monitorCanvas: CanvasInfo = {
  id: 'monitor',
  name: 'Monitor',
  scope: 'personal',
  kind: 'monitor',
  isDefault: true,
  workspacePath: '',
}

const boardCanvas: CanvasInfo = {
  id: 'canvas-1',
  name: 'Canvas',
  scope: 'personal',
  kind: 'board',
  isDefault: false,
  workspacePath: '',
}

function session(overrides: Partial<Session> = {}): Session {
  return {
    id: 'session-1',
    title: 'Session',
    project: '',
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
    surfaceId: 'surface-1',
    surfaceStatus: 'running',
    nativeWorkspaceAvailable: true,
    openTarget: 'native-workspace',
    syncEnabled: false,
    syncTeamId: null,
    syncTeamName: null,
    ...overrides,
  }
}

describe('session terminal routing helpers', () => {
  it('routes unbound local sessions to the monitor canvas', () => {
    const canvasId = resolveSessionCanvasId({
      target: { sessionId: 'session-1' },
      session: session(),
      memberships: [],
      canvases: [boardCanvas, monitorCanvas],
      activePlannerState: null,
      fallbackCanvasId: 'canvas-1',
    })

    expect(canvasId).toBe('monitor')
  })

  it('recognizes unmanaged external sessions as not overlay-capable', () => {
    expect(isLiveInternalTerminalSession(session({
      terminalKind: 'external',
      terminalBackend: 'external',
      surfaceId: null,
      nativeWorkspaceAvailable: false,
      openTarget: 'external',
    }))).toBe(false)
  })

  it('rejects legacy replay terminals as overlay-capable', () => {
    expect(isLiveInternalTerminalSession(session({
      terminalBackend: 'legacy-internal',
      nativeWorkspaceAvailable: false,
      openTarget: 'web-fallback',
    }))).toBe(false)
  })
})
