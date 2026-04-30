// Canvas persistence abstraction.
// Replaces meee2's localStorage modules with a Supabase-backed store.

import type { LayoutMap } from './layout'

export interface PersistedViewport {
  scrollX: number
  scrollY: number
  zoom: number
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

  loadDismissed(): Promise<Set<string>>
  saveDismissed(s: Set<string>): Promise<void>

  loadUnreadSids(): Promise<Set<string>>
  saveUnreadSids(s: Set<string>): Promise<void>
}
