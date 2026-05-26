import type { CanvasRecap, RecapScope, SessionRecap } from './types'

export interface CachedRecap {
  recap: CanvasRecap | SessionRecap
  storedAt: string
}

export interface RecapCache {
  get(key: string): Promise<CachedRecap | null>
  set(key: string, recap: CanvasRecap | SessionRecap): Promise<void>
  invalidate(scope: RecapScope, id: string): Promise<void>
}

export function recapCacheKey(input: {
  scope: RecapScope
  id: string
  fingerprint: string
  version?: number
}): string {
  return `recap:v${input.version ?? 1}:${input.scope}:${input.id}:${input.fingerprint}`
}
