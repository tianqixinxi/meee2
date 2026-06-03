import { act, renderHook, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { BoardState } from './types'

const apiMocks = vi.hoisted(() => ({
  fetchState: vi.fn(),
  connectEvents: vi.fn(() => () => {}),
}))

vi.mock('./api', async () => {
  const actual = await vi.importActual<typeof import('./api')>('./api')
  return { ...actual, fetchState: apiMocks.fetchState, connectEvents: apiMocks.connectEvents }
})

import { useBoardState } from './useBoardState'

function boardWith(ids: string[]): BoardState {
  return {
    sessions: ids.map((id) => ({
      id,
      title: id,
      project: '',
      pluginId: 'p',
      pluginDisplayName: 'p',
      pluginColor: '#000',
      status: 'idle',
      inboxPending: 0,
      recentMessages: [],
      currentTool: null,
      usageStats: null,
      backgroundAgents: [],
      latestRecap: null,
      syncEnabled: false,
      syncTeamId: null,
      syncTeamName: null,
    })) as unknown as BoardState['sessions'],
    channels: [],
    coordinationGroups: [],
  }
}

function setVisibility(value: 'visible' | 'hidden') {
  Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => value })
}

describe('useBoardState.forceRefresh', () => {
  beforeEach(() => {
    apiMocks.fetchState.mockReset()
    apiMocks.connectEvents.mockClear()
    setVisibility('visible')
  })
  afterEach(() => setVisibility('visible'))

  it('fetches and commits a fresh session list even while the document is hidden', async () => {
    // initial mount fetch lands the stale (pre-dispatch) list
    apiMocks.fetchState.mockResolvedValueOnce(boardWith(['old-1', 'old-2']))
    const { result } = renderHook(() => useBoardState())
    await waitFor(() => expect(result.current.state?.sessions.length).toBe(2))

    // window goes to background; the freshly-dispatched session appears server-side
    setVisibility('hidden')
    apiMocks.fetchState.mockResolvedValue(boardWith(['old-1', 'old-2', 'claude-internal-NEW']))

    // guarded refresh() is suppressed while hidden -> state stays stale
    await act(async () => { result.current.refresh(); await Promise.resolve() })
    expect(result.current.state?.sessions.some((s) => s.id === 'claude-internal-NEW')).toBe(false)

    // forceRefresh() bypasses the guard and pulls the new session in — this is
    // what makes "jump to a just-dispatched session" land on a populated list.
    await act(async () => { await result.current.forceRefresh() })
    expect(result.current.state?.sessions.some((s) => s.id === 'claude-internal-NEW')).toBe(true)
  })

  it('does not let a stale refresh that resolves late clobber the forced snapshot', async () => {
    // mount lands the stale list
    apiMocks.fetchState.mockResolvedValueOnce(boardWith(['old-1']))
    const { result } = renderHook(() => useBoardState())
    await waitFor(() => expect(result.current.state?.sessions.length).toBe(1))

    // refresh()'s fetch is held pending so it resolves *after* forceRefresh's —
    // the exact ordering codex flagged (older request commits a stale snapshot).
    let releaseStale: (s: BoardState) => void = () => {}
    const staleInFlight = new Promise<BoardState>((res) => { releaseStale = res })
    apiMocks.fetchState.mockReturnValueOnce(staleInFlight)                   // refresh() — seq=2
    apiMocks.fetchState.mockResolvedValueOnce(boardWith(['old-1', 'NEW']))   // forceRefresh() — seq=3

    await act(async () => {
      result.current.refresh()              // issues seq=2, fetch stays pending
      await result.current.forceRefresh()   // issues seq=3, resolves fresh, commits
    })
    expect(result.current.state?.sessions.some((s) => s.id === 'NEW')).toBe(true)

    // the older refresh finally resolves (stale, seq=2 < committed 3) → must be dropped
    await act(async () => {
      releaseStale(boardWith(['old-1']))
      await staleInFlight
      await Promise.resolve()
    })
    expect(result.current.state?.sessions.some((s) => s.id === 'NEW')).toBe(true)
  })
})
