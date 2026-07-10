import { afterEach, describe, expect, it, vi } from 'vitest'
import { installControlPlaneFetch } from './controlPlane'

describe('control-plane fetch transport', () => {
  const originalFetch = globalThis.fetch

  afterEach(() => {
    globalThis.fetch = originalFetch
    document.head.innerHTML = ''
    vi.restoreAllMocks()
  })

  it('adds the launch token to every local mutation without leaking it to reads or external APIs', async () => {
    document.head.innerHTML = '<meta name="meee2-control-token" content="launch-secret">'
    const transport = vi.fn(async (_input: RequestInfo | URL, _init?: RequestInit) => (
      new Response('{}', { status: 200 })
    ))
    installControlPlaneFetch(transport as unknown as typeof fetch)

    await fetch('/api/canvases', { method: 'POST', body: '{}' })
    await fetch('/api/state')
    await fetch('https://example.com/api/write', { method: 'POST' })

    const mutationHeaders = new Headers(transport.mock.calls[0][1]?.headers)
    expect(mutationHeaders.get('X-Meee2-Control-Token')).toBe('launch-secret')
    expect(new Headers(transport.mock.calls[1][1]?.headers).has('X-Meee2-Control-Token')).toBe(false)
    expect(new Headers(transport.mock.calls[2][1]?.headers).has('X-Meee2-Control-Token')).toBe(false)
  })
})
