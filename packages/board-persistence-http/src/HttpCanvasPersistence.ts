// HTTP + localStorage backed CanvasPersistence implementation for the meee2
// Swift backend.
//
// Strategy:
//   - localStorage is the fast boot cache for every slot — load() reads it
//     synchronously then (for the layout slots) awaits the authoritative GET
//     and merges. If the GET fails, the localStorage cache is the answer.
//   - save() writes localStorage immediately + schedules a debounced PUT to
//     /api/board/layout. Session and channel layout share one PUT envelope so
//     a single drag doesn't race a partial write.
//   - Viewport, userElements, dismissed, and unreadSids are also mirrored to
//     the backend so the native WKWebView can survive app restarts / storage
//     churn without losing the canvas.
//
// Compared to the previous separate boardLayoutRemote.ts / boardPersistence.ts
// / dismissed.ts modules: same wire behaviour, repackaged behind the
// CanvasPersistence interface from @meee1/board-core so the same Board UI can
// also accept e.g. a SupabaseCanvasPersistence (meee2).

import type {
  CanvasPersistence,
  LayoutMap,
  PersistedViewport,
} from '@meee1/board-core'
import { parseSessionFromElement } from '@meee1/board-core'

const ENDPOINT = '/api/board/layout'

const VIEWPORT_KEY = 'appstate'
const USER_SHAPES_KEY = 'user-shapes'
const SESSION_LAYOUT_KEY = 'layout'
const CHANNEL_LAYOUT_KEY = 'channel-layout'
const DISMISSED_KEY = 'dismissed'
const UNREAD_KEY = 'unreadSids'

interface LayoutEnvelope {
  layout: {
    sessions: LayoutMap
    channels: LayoutMap
    viewport?: PersistedViewport | null
    userElements?: any[]
    dismissedSids?: string[]
    unreadSids?: string[]
    updatedAt?: string
  }
}

interface RemoteLayout {
  sessions: LayoutMap
  channels: LayoutMap
  viewport: PersistedViewport | null
  userElements: any[]
  dismissedSids: string[]
  unreadSids: string[]
}

interface LayoutPatch {
  sessions?: LayoutMap
  channels?: LayoutMap
  viewport?: PersistedViewport | null
  userElements?: any[]
  dismissedSids?: string[]
  unreadSids?: string[]
}

function readJSON<T>(key: string): T | null {
  try {
    const raw = localStorage.getItem(key)
    if (!raw) return null
    return JSON.parse(raw) as T
  } catch {
    return null
  }
}

function writeJSON(key: string, value: unknown): void {
  try {
    localStorage.setItem(key, JSON.stringify(value))
  } catch {
    /* quota / private mode */
  }
}

export class HttpCanvasPersistence implements CanvasPersistence {
  // Buffered authoritative state for the combined PUT.
  private shadowSessions: LayoutMap = {}
  private shadowChannels: LayoutMap = {}
  private shadowViewport: PersistedViewport | null = null
  private shadowUserElements: any[] = []
  private shadowDismissedSids: string[] = []
  private shadowUnreadSids: string[] = []
  private loadedSessions = false
  private loadedChannels = false
  private loadedViewport = false
  private loadedUserElements = false
  private loadedDismissedSids = false
  private loadedUnreadSids = false
  private remoteCache: RemoteLayout | null | undefined
  private remotePromise: Promise<RemoteLayout | null> | null = null
  private pushTimer: number | null = null
  private lastPushError: string | null = null

  constructor(private readonly canvasId: string = 'personal-default') {}

  // -- Viewport (localStorage + backend) --------------------------------

  async loadViewport(): Promise<PersistedViewport | null> {
    const local = readValidViewport(this.key(VIEWPORT_KEY))
    this.shadowViewport = local
    this.loadedViewport = true
    const remote = await this.fetchRemote()
    if (remote?.viewport) {
      this.shadowViewport = remote.viewport
      writeJSON(this.key(VIEWPORT_KEY), remote.viewport)
      return remote.viewport
    }
    return local
  }

  async saveViewport(v: PersistedViewport): Promise<void> {
    this.shadowViewport = v
    this.loadedViewport = true
    writeJSON(this.key(VIEWPORT_KEY), v)
    this.schedulePush()
  }

  // -- User elements (localStorage + backend) ---------------------------

  async loadUserElements(): Promise<any[]> {
    const local = readJSON<unknown>(this.key(USER_SHAPES_KEY))
    const localElements = Array.isArray(local) ? local : []
    this.shadowUserElements = localElements
    this.loadedUserElements = true
    const remote = await this.fetchRemote()
    if (remote && remote.userElements.length > 0) {
      this.shadowUserElements = remote.userElements
      writeJSON(this.key(USER_SHAPES_KEY), remote.userElements)
      return remote.userElements
    }
    return localElements
  }

  async saveUserElements(elements: readonly any[]): Promise<void> {
    // Strip elements that the scene rebuilds from authoritative state —
    // session rectangles, channel hubs/labels/spokes, and any text label
    // whose containerId points at a managed element. Without this filter
    // these elements get persisted into localStorage and accumulate
    // duplicates across reloads.
    const keep = elements.filter((el: any) => {
      if (!el) return false
      if (el.isDeleted) return false
      if (el.type === 'rectangle' && parseSessionFromElement(el)) return false
      if (typeof el.id === 'string' && el.id.startsWith('channel-')) return false
      if (el.type === 'text') {
        const cid = el.containerId
        if (
          typeof cid === 'string' &&
          (cid.startsWith('channel-') || cid.startsWith('session-'))
        ) {
          return false
        }
      }
      return true
    })
    this.shadowUserElements = [...keep]
    this.loadedUserElements = true
    writeJSON(this.key(USER_SHAPES_KEY), keep)
    this.schedulePush()
  }

  // -- Layout: session + channel share one PUT envelope -----------------

  async loadSessionLayout(): Promise<LayoutMap> {
    const local = readJSON<LayoutMap>(this.key(SESSION_LAYOUT_KEY)) ?? {}
    this.shadowSessions = local
    this.loadedSessions = true
    const remote = await this.fetchRemote()
    if (remote) {
      // Server is authoritative — remote keys overwrite local; unknown
      // local keys are preserved in case the user dragged offline before
      // server was reachable.
      const merged = { ...local, ...remote.sessions }
      this.shadowSessions = merged
      writeJSON(this.key(SESSION_LAYOUT_KEY), merged)
      return merged
    }
    return local
  }

  async saveSessionLayout(map: LayoutMap): Promise<void> {
    this.shadowSessions = map
    this.loadedSessions = true
    writeJSON(this.key(SESSION_LAYOUT_KEY), map)
    await this.pushNow()
  }

  async loadChannelLayout(): Promise<LayoutMap> {
    const local = readJSON<LayoutMap>(this.key(CHANNEL_LAYOUT_KEY)) ?? {}
    this.shadowChannels = local
    this.loadedChannels = true
    const remote = await this.fetchRemote()
    if (remote) {
      const merged = { ...local, ...remote.channels }
      this.shadowChannels = merged
      writeJSON(this.key(CHANNEL_LAYOUT_KEY), merged)
      return merged
    }
    return local
  }

  async saveChannelLayout(map: LayoutMap): Promise<void> {
    this.shadowChannels = map
    this.loadedChannels = true
    writeJSON(this.key(CHANNEL_LAYOUT_KEY), map)
    await this.pushNow()
  }

  // -- Dismissed sids (localStorage + backend) --------------------------

  async loadDismissed(): Promise<Set<string>> {
    const local = readStringSet(this.key(DISMISSED_KEY))
    this.shadowDismissedSids = [...local]
    this.loadedDismissedSids = true
    const remote = await this.fetchRemote()
    if (remote && remote.dismissedSids.length > 0) {
      this.shadowDismissedSids = remote.dismissedSids
      writeJSON(this.key(DISMISSED_KEY), remote.dismissedSids)
      return new Set(remote.dismissedSids)
    }
    return local
  }

  async saveDismissed(s: Set<string>): Promise<void> {
    this.shadowDismissedSids = [...s]
    this.loadedDismissedSids = true
    writeJSON(this.key(DISMISSED_KEY), this.shadowDismissedSids)
    this.schedulePush()
  }

  // -- Unread sids (localStorage + backend) -----------------------------

  async loadUnreadSids(): Promise<Set<string>> {
    const local = readStringSet(this.key(UNREAD_KEY))
    this.shadowUnreadSids = [...local]
    this.loadedUnreadSids = true
    const remote = await this.fetchRemote()
    if (remote && remote.unreadSids.length > 0) {
      this.shadowUnreadSids = remote.unreadSids
      writeJSON(this.key(UNREAD_KEY), remote.unreadSids)
      return new Set(remote.unreadSids)
    }
    return local
  }

  async saveUnreadSids(s: Set<string>): Promise<void> {
    this.shadowUnreadSids = [...s]
    this.loadedUnreadSids = true
    writeJSON(this.key(UNREAD_KEY), this.shadowUnreadSids)
    this.schedulePush()
  }

  async flushPendingWrites(): Promise<void> {
    if (this.pushTimer !== null) {
      window.clearTimeout(this.pushTimer)
      this.pushTimer = null
    }
    await this.doPush()
  }

  // -- Internals --------------------------------------------------------

  private async fetchRemote(): Promise<RemoteLayout | null> {
    if (this.remoteCache !== undefined) return this.remoteCache
    if (this.remotePromise) return this.remotePromise
    this.remotePromise = this.fetchRemoteUncached()
    this.remoteCache = await this.remotePromise
    this.remotePromise = null
    return this.remoteCache
  }

  private async fetchRemoteUncached(): Promise<RemoteLayout | null> {
    try {
      const r = await fetch(this.endpoint(), { method: 'GET' })
      if (!r.ok) return null
      const body = (await r.json()) as LayoutEnvelope
      return {
        sessions: body.layout?.sessions ?? {},
        channels: body.layout?.channels ?? {},
        viewport: normalizeViewport(body.layout?.viewport),
        userElements: Array.isArray(body.layout?.userElements) ? body.layout.userElements : [],
        dismissedSids: normalizeStringArray(body.layout?.dismissedSids),
        unreadSids: normalizeStringArray(body.layout?.unreadSids),
      }
    } catch (e) {
      console.warn('[HttpCanvasPersistence] fetch failed:', (e as Error).message)
      return null
    }
  }

  private schedulePush(): void {
    if (this.pushTimer !== null) window.clearTimeout(this.pushTimer)
    // 400ms drag-coalescing window — matches the original debounce in
    // layout.ts / channelLayout.ts so a drag still produces one PUT.
    this.pushTimer = window.setTimeout(() => this.doPush(), 400)
  }

  private async pushNow(): Promise<void> {
    if (this.pushTimer !== null) {
      window.clearTimeout(this.pushTimer)
      this.pushTimer = null
    }
    await this.doPush()
  }

  private async doPush(): Promise<void> {
    this.pushTimer = null
    const payload: LayoutPatch = {}
    if (this.loadedSessions) payload.sessions = this.shadowSessions
    if (this.loadedChannels) payload.channels = this.shadowChannels
    if (this.loadedViewport) payload.viewport = this.shadowViewport
    if (this.loadedUserElements) payload.userElements = this.shadowUserElements
    if (this.loadedDismissedSids) payload.dismissedSids = this.shadowDismissedSids
    if (this.loadedUnreadSids) payload.unreadSids = this.shadowUnreadSids
    try {
      const r = await fetch(this.endpoint(), {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      })
      if (!r.ok) {
        const msg = `HTTP ${r.status}`
        if (this.lastPushError !== msg) {
          console.warn('[HttpCanvasPersistence] push failed:', msg)
          this.lastPushError = msg
        }
        return
      }
      this.remoteCache = {
        sessions: payload.sessions ?? this.remoteCache?.sessions ?? {},
        channels: payload.channels ?? this.remoteCache?.channels ?? {},
        viewport: payload.viewport ?? this.remoteCache?.viewport ?? null,
        userElements: payload.userElements ?? this.remoteCache?.userElements ?? [],
        dismissedSids: payload.dismissedSids ?? this.remoteCache?.dismissedSids ?? [],
        unreadSids: payload.unreadSids ?? this.remoteCache?.unreadSids ?? [],
      }
      this.lastPushError = null
    } catch (e) {
      const msg = (e as Error).message
      if (this.lastPushError !== msg) {
        console.warn('[HttpCanvasPersistence] push error:', msg)
        this.lastPushError = msg
      }
    }
  }

  private endpoint(): string {
    return `${ENDPOINT}?canvasId=${encodeURIComponent(this.canvasId)}`
  }

  private key(slot: string): string {
    return `meee2.board.canvas.${this.canvasId}.${slot}.v1`
  }
}

function readValidViewport(key: string): PersistedViewport | null {
  const p = readJSON<{ scrollX: unknown; scrollY: unknown; zoom: unknown }>(key)
  if (
    p &&
    typeof p.scrollX === 'number' &&
      typeof p.scrollY === 'number' &&
      typeof p.zoom === 'number'
  ) {
    return { scrollX: p.scrollX, scrollY: p.scrollY, zoom: p.zoom }
  }
  return null
}

function readStringSet(key: string): Set<string> {
  return new Set(normalizeStringArray(readJSON<unknown>(key)))
}

function normalizeStringArray(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((x): x is string => typeof x === 'string') : []
}

function normalizeViewport(value: unknown): PersistedViewport | null {
  if (
    value &&
    typeof value === 'object' &&
    typeof (value as PersistedViewport).scrollX === 'number' &&
    typeof (value as PersistedViewport).scrollY === 'number' &&
    typeof (value as PersistedViewport).zoom === 'number'
  ) {
    const v = value as PersistedViewport
    return { scrollX: v.scrollX, scrollY: v.scrollY, zoom: v.zoom }
  }
  return null
}
