import { afterEach, describe, expect, it, vi } from 'vitest'
import { fetchArtifactsPage } from './api'

describe('fetchArtifactsPage', () => {
  afterEach(() => vi.unstubAllGlobals())

  it('encodes cursor pagination and server-side filters with a 100-row cap', async () => {
    const fetchMock = vi.fn(async (_input: RequestInfo | URL, _init?: RequestInit) => new Response(JSON.stringify({
      items: [],
      cursor: null,
      total: 0,
      hasMore: false,
      candidateTotal: 0,
      canvasCount: 0,
      groupCounts: {},
    }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
    vi.stubGlobal('fetch', fetchMock)

    await fetchArtifactsPage({
      cursor: 'opaque-cursor',
      limit: 1_000,
      status: 'needs-review',
      canvasId: 'canvas / 1',
      query: 'release notes',
      sessionId: 'session-a,session-b',
      project: '/repo/release',
      scope: 'team',
      group: 'docs',
    })

    const url = new URL(String(fetchMock.mock.calls[0][0]), 'http://127.0.0.1')
    expect(url.pathname).toBe('/api/artifacts')
    expect(Object.fromEntries(url.searchParams)).toEqual({
      cursor: 'opaque-cursor',
      limit: '100',
      status: 'needs-review',
      canvasId: 'canvas / 1',
      query: 'release notes',
      sessionId: 'session-a,session-b',
      project: '/repo/release',
      scope: 'team',
      group: 'docs',
    })
  })
})
