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
  constructor(url: string) {
    this.url = url
    FakeWebSocket.instances.push(this)
  }
  open() { this.onopen?.() }
  message(data: unknown) { this.onmessage?.({ data: JSON.stringify(data) }) }
  fail() { this.onclose?.() }
}

describe('connectEvents — resync on (re)connect', () => {
  beforeEach(() => {
    FakeWebSocket.instances = []
    vi.stubGlobal('WebSocket', FakeWebSocket as unknown as typeof WebSocket)
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
    vi.unstubAllGlobals()
  })

  it('fetches fresh state when the socket first opens', () => {
    const onChange = vi.fn()
    const onStatus = vi.fn()
    const dispose = connectEvents(onChange, onStatus)

    const ws = FakeWebSocket.instances[0]
    expect(ws).toBeTruthy()
    ws.open()

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
  it('re-fetches on reconnect so sessions created during the outage are picked up', () => {
    const onChange = vi.fn()
    const onStatus = vi.fn()
    const dispose = connectEvents(onChange, onStatus)

    // initial connect + open
    FakeWebSocket.instances[0].open()
    expect(onChange).toHaveBeenCalledTimes(1)

    // socket drops (e.g. window backgrounded / server blip)
    FakeWebSocket.instances[0].fail()
    expect(onStatus).toHaveBeenLastCalledWith(false)

    // auto-reconnect timer fires and a new socket is created + opened
    vi.advanceTimersByTime(1500)
    expect(FakeWebSocket.instances.length).toBe(2)
    FakeWebSocket.instances[1].open()

    // The reconnect must have forced a fresh state sync.
    expect(onStatus).toHaveBeenLastCalledWith(true)
    expect(onChange).toHaveBeenCalledTimes(2)
    dispose()
  })

  it('still forwards live state.changed frames', () => {
    const onChange = vi.fn()
    const dispose = connectEvents(onChange, vi.fn())
    const ws = FakeWebSocket.instances[0]
    ws.open()
    onChange.mockClear()

    ws.message({ type: 'state.changed' })
    expect(onChange).toHaveBeenCalledTimes(1)

    ws.message({ type: 'something.else' })
    expect(onChange).toHaveBeenCalledTimes(1) // unchanged — only state.changed counts
    dispose()
  })
})
