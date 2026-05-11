// Canvas persistence abstraction.
// Replaces meee2's localStorage modules with a Supabase-backed store.

import type { LayoutMap } from './layout'

export interface PersistedViewport {
  scrollX: number
  scrollY: number
  zoom: number
}

export type CanvasScope = 'personal' | 'team'

export interface CanvasInfo {
  id: string
  name: string
  scope: CanvasScope
  isDefault: boolean
  teamId?: string | null
  ownerUserId?: string | null
}

export interface CanvasSessionMembership {
  canvasId: string
  sessionId: string
  layout?: { x: number; y: number } | null
  visible: boolean
}

export interface CanvasPersistence {
  loadViewport(): Promise<PersistedViewport | null>
  saveViewport(v: PersistedViewport): Promise<void>

  loadUserElements(): Promise<any[]>
  saveUserElements(elements: readonly any[]): Promise<void>

  loadSessionLayout(): Promise<LayoutMap>
  saveSessionLayout(map: LayoutMap): Promise<void>

  loadChannelLayout(): Promise<LayoutMap>
  saveChannelLayout(map: LayoutMap): Promise<void>

  flushPendingWrites?(): Promise<void>

  loadDismissed(): Promise<Set<string>>
  saveDismissed(s: Set<string>): Promise<void>

  loadUnreadSids(): Promise<Set<string>>
  saveUnreadSids(s: Set<string>): Promise<void>
}
