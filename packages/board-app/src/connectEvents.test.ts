import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { connectEvents } from './api'

// Minimal controllable WebSocket double. connectEvents only uses
// onopen/onmessage/onclose/onerror + close(), so we capture the instance and
// drive its lifecycle by hand.
class FakeWebSocket {
  static instances: FakeWebSocket[] = []
  url: string
  onopen: (() => void) | null = null
  onmessage: ((e: { data: string }) => void) | null = null
  onclose: (() => void) | null = null
  onerror: (() => void) | null = null
  close = vi.fn()
  send = vi.fn()
  constructor(url: string) {
    this.url = url
    FakeWebSocket.instances.push(this)
  }
  open() { this.onopen?.() }
  message(data: unknown) { this.onmessage?.({ data: JSON.stringify(data) }) }
  fail() { this.onclose?.() }
}

async function flushSocketBootstrap() {
  // getControlToken (async) -> controlPlaneWebSocketURL (.then) -> connectEvents
  // (.then) spans several microtask turns even when the token is in a meta tag.
  for (let i = 0; i < 4; i += 1) await Promise.resolve()
}

describe('connectEvents — resync on (re)connect', () => {
  beforeEach(() => {
    FakeWebSocket.instances = []
    document.head.innerHTML = '<meta name="meee2-control-token" content="test-control-token">'
    vi.stubGlobal('WebSocket', FakeWebSocket as unknown as typeof WebSocket)
    vi.stubGlobal('fetch', vi.fn(async () => new Response(
      JSON.stringify({ controlToken: 'refreshed-control-token' }),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    )))
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
    vi.unstubAllGlobals()
  })

  it('fetches fresh state when the authenticated socket first opens', async () => {
    const onChange = vi.fn()
    const onStatus = vi.fn()
    const dispose = connectEvents(onChange, onStatus)

    await flushSocketBootstrap()
    const ws = FakeWebSocket.instances[0]
    expect(ws).toBeTruthy()
    expect(ws.url).not.toContain('controlToken')
    ws.open()

    expect(ws.send).toHaveBeenCalledWith(JSON.stringify({
      type: 'auth',
      controlToken: 'test-control-token',
    }))
    expect(onStatus).not.toHaveBeenCalledWith(true)
    expect(onChange).not.toHaveBeenCalled()
    ws.message({ type: 'auth.ok' })
    expect(onStatus).toHaveBeenCalledWith(true)
    // Root cause: an open must trigger a resync, not just a status flip.
    expect(onChange).toHaveBeenCalledTimes(1)
    dispose()
  })

  // Regression for the canvas-123 "打开会话查看进展 跳不过去" bug: the board WS
  // dropped while the window was backgrounded, a planner node was dispatched
  // (new session created server-side) during the gap, and the socket then
  // reconnected. Because the server does not replay historical 'state.changed'
  // frames, the only way the long-lived board picks up the new session is a
  // resync triggered by the reconnect itself. Without it the session list stays
  // stale and the jump target is absent from the list.
  it('re-fetches on reconnect so sessions created during the outage are picked up', async () => {
    const onChange = vi.fn()
    const onStatus = vi.fn()
    const dispose = connectEvents(onChange, onStatus)

    await flushSocketBootstrap()
    // initial connect + open
    FakeWebSocket.instances[0].open()
    FakeWebSocket.instances[0].message({ type: 'auth.ok' })
    expect(onChange).toHaveBeenCalledTimes(1)

    // socket drops (e.g. window backgrounded / server blip)
    FakeWebSocket.instances[0].fail()
    expect(onStatus).toHaveBeenLastCalledWith(false)

    // auto-reconnect timer fires and a new socket is created + opened
    await vi.advanceTimersByTimeAsync(1500)
    await flushSocketBootstrap()
    expect(FakeWebSocket.instances.length).toBe(2)
    expect(FakeWebSocket.instances[1].url).not.toContain('controlToken')
    FakeWebSocket.instances[1].open()
    expect(FakeWebSocket.instances[1].send).toHaveBeenCalledWith(JSON.stringify({
      type: 'auth',
      controlToken: 'refreshed-control-token',
    }))
    FakeWebSocket.instances[1].message({ type: 'auth.ok' })

    // The reconnect must have forced a fresh state sync.
    expect(onStatus).toHaveBeenLastCalledWith(true)
    expect(onChange).toHaveBeenCalledTimes(2)
    dispose()
  })

  it('still forwards live state.changed frames', async () => {
    const onChange = vi.fn()
    const dispose = connectEvents(onChange, vi.fn())
    await flushSocketBootstrap()
    const ws = FakeWebSocket.instances[0]
    ws.open()
    ws.message({ type: 'auth.ok' })
    onChange.mockClear()

    ws.message({ type: 'state.changed', revision: 7 })
    expect(onChange).toHaveBeenCalledTimes(1)
    expect(onChange).toHaveBeenLastCalledWith(7, {
      timestamp: undefined,
      changedSessionIds: [],
      removedSessionIds: [],
      changedSessions: [],
      snapshotRequired: true,
    })

    ws.message({ type: 'something.else' })
    expect(onChange).toHaveBeenCalledTimes(1) // unchanged — only state.changed counts
    dispose()
  })
})
