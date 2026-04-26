// Server-side persistence for board positions (session cards + channel hubs).
//
// Why server-side: localStorage is per-browser — switching browsers or clearing
// storage loses the layout. A single server file at ~/.meee2/board-layout.json
// keeps positions across tabs, browsers, and reinstalls (until the user wipes
// ~/.meee2 explicitly).
//
// Strategy: localStorage stays as the fast boot cache; on mount we kick an
// async GET that fills the same refs. Writes go to BOTH localStorage (instant)
// and the server (debounced PUT, combined sessions + channels in one call).

import type { LayoutMap } from './layout'

const ENDPOINT = '/api/board/layout'

interface LayoutEnvelope {
  layout: {
    sessions: LayoutMap
    channels: LayoutMap
    updatedAt?: string
  }
}

// In-memory shadow — the coordinator buffers both maps so any single saveX
// call can push them together without racing a partial write.
let shadowSessions: LayoutMap = {}
let shadowChannels: LayoutMap = {}

// 400ms drag-coalescing window matches the existing localStorage debounce
// in layout.ts / channelLayout.ts — keeps the PUT traffic bounded while
// a user drags a card.
let pushTimer: number | null = null

let lastPushError: string | null = null

export async function fetchRemoteLayout(): Promise<{
  sessions: LayoutMap
  channels: LayoutMap
} | null> {
  try {
    const r = await fetch(ENDPOINT, { method: 'GET' })
    if (!r.ok) return null
    const body = (await r.json()) as LayoutEnvelope
    const sessions = body.layout?.sessions ?? {}
    const channels = body.layout?.channels ?? {}
    shadowSessions = sessions
    shadowChannels = channels
    return { sessions, channels }
  } catch (e) {
    console.warn('[boardLayoutRemote] fetch failed:', (e as Error).message)
    return null
  }
}

export function seedRemoteShadow(sessions: LayoutMap, channels: LayoutMap) {
  shadowSessions = sessions
  shadowChannels = channels
}

export function pushSessions(sessions: LayoutMap) {
  shadowSessions = sessions
  schedulePush()
}

export function pushChannels(channels: LayoutMap) {
  shadowChannels = channels
  schedulePush()
}

function schedulePush() {
  if (pushTimer !== null) window.clearTimeout(pushTimer)
  pushTimer = window.setTimeout(doPush, 400)
}

async function doPush() {
  pushTimer = null
  try {
    const r = await fetch(ENDPOINT, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        sessions: shadowSessions,
        channels: shadowChannels,
      }),
    })
    if (!r.ok) {
      const msg = `HTTP ${r.status}`
      if (lastPushError !== msg) {
        console.warn('[boardLayoutRemote] push failed:', msg)
        lastPushError = msg
      }
      return
    }
    lastPushError = null
  } catch (e) {
    const msg = (e as Error).message
    if (lastPushError !== msg) {
      console.warn('[boardLayoutRemote] push error:', msg)
      lastPushError = msg
    }
  }
}
