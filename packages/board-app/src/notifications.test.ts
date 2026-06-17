import { beforeEach, describe, expect, it, vi } from 'vitest'
import {
  DEFAULT_NOTIFICATION_TOGGLES,
  loadNotificationToggles,
  runSessionTransitionNotifications,
} from './notifications'
import type { Session } from './types'

function session(overrides: Partial<Session> = {}): Session {
  return {
    id: 'session-a',
    title: 'Codex - project',
    project: '/tmp/project',
    pluginId: 'codex',
    pluginDisplayName: 'Codex',
    pluginColor: '#3B82F6',
    status: 'active',
    inboxPending: 0,
    recentMessages: [{ role: 'user', text: 'Ship row indicators' }],
    currentTool: null,
    usageStats: null,
    backgroundAgents: [],
    latestRecap: null,
    startedAt: '2026-06-14T00:00:00Z',
    lastActivity: '2026-06-14T00:00:00Z',
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

describe('notifications', () => {
  beforeEach(() => {
    localStorage.clear()
    vi.restoreAllMocks()
  })

  it('enables session-done by default', () => {
    expect(DEFAULT_NOTIFICATION_TOGGLES['session-done']).toBe(true)
    expect(loadNotificationToggles()['session-done']).toBe(true)
  })

  it('plays a local cue when a session needs input or completes', () => {
    const start = vi.fn()
    const stop = vi.fn()
    const connect = vi.fn()
    const setValueAtTime = vi.fn()
    const exponentialRampToValueAtTime = vi.fn()
    class AudioContextMock {
      state = 'running'
      currentTime = 1
      destination = {}
      createOscillator() {
        return {
          type: 'sine',
          frequency: { setValueAtTime },
          connect,
          start,
          stop,
        }
      }
      createGain() {
        return {
          gain: { setValueAtTime, exponentialRampToValueAtTime },
          connect,
        }
      }
      resume() {}
    }
    Object.defineProperty(window, 'AudioContext', {
      configurable: true,
      value: AudioContextMock,
    })

    runSessionTransitionNotifications(
      new Map([['needs-input', session({ id: 'needs-input', status: 'active' })]]),
      [session({ id: 'needs-input', status: 'waitingForUser' })],
      loadNotificationToggles(),
    )
    runSessionTransitionNotifications(
      new Map([['done', session({ id: 'done', status: 'active' })]]),
      [session({ id: 'done', status: 'completed' })],
      loadNotificationToggles(),
    )

    expect(start).toHaveBeenCalledTimes(2)
    expect(stop).toHaveBeenCalledTimes(2)
  })
})
