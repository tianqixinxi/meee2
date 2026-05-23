import type { SpawnProvider } from './types'

// 用户偏好：默认 global/new session provider。
// 全部 localStorage 托管，不走后端——这是每个 browser/用户的 UI 偏好。

const KEY_SPAWN_PROVIDER = 'meee2.spawn.provider.v1'
const LEGACY_KEY_SPAWN_COMMAND = 'meee2.spawn.defaultCommand.v1'
const KEY_BOARD_GRID = 'meee2.board.gridMode.v1'
const KEY_CANVAS_RECAP_INTERVAL_MINUTES = 'meee2.canvas.recapIntervalMinutes.v1'
// UI-5.2 — opt-in "lock viewport on switch". Default off preserves the
// historical fit-view-on-switch behavior. When on, switching canvas restores
// the prior viewport offset/scale from the per-canvas pose persisted in
// localStorage (see KEY_PLANNER_VIEWPORT_PREFIX below).
const KEY_LOCK_VIEWPORT_ON_SWITCH = 'meee2.canvas.lockViewportOnSwitch.v1'
export const KEY_PLANNER_VIEWPORT_PREFIX = 'meee2.planner.viewport.'
export const BOARD_PREFERENCES_CHANGED = 'meee2:board-preferences-changed'
export const CANVAS_RECAP_PREFERENCES_CHANGED = 'meee2:canvas-recap-preferences-changed'
export const LOCK_VIEWPORT_PREFERENCES_CHANGED = 'meee2:lock-viewport-preferences-changed'

export const DEFAULT_SPAWN_PROVIDER: SpawnProvider = 'claude'
export const DEFAULT_CANVAS_RECAP_INTERVAL_MINUTES = 5
export const DEFAULT_LOCK_VIEWPORT_ON_SWITCH = false

export function commandForSpawnProvider(provider: SpawnProvider): string {
  return provider === 'codex'
    ? 'codex --dangerously-bypass-approvals-and-sandbox'
    : 'claude --dangerously-skip-permissions'
}

export function spawnProviderLabel(provider: SpawnProvider): string {
  return provider === 'codex' ? 'Codex' : 'Claude'
}

export function loadSpawnProvider(): SpawnProvider {
  try {
    const v = localStorage.getItem(KEY_SPAWN_PROVIDER)
    if (v === 'claude' || v === 'codex') return v
    const previousCommand = localStorage.getItem(LEGACY_KEY_SPAWN_COMMAND)?.trim().toLowerCase() ?? ''
    if (previousCommand.startsWith('codex')) return 'codex'
  } catch {
    /* ignore */
  }
  return DEFAULT_SPAWN_PROVIDER
}

export function saveSpawnProvider(value: SpawnProvider): void {
  try {
    if (value === DEFAULT_SPAWN_PROVIDER) {
      localStorage.removeItem(KEY_SPAWN_PROVIDER)
    } else {
      localStorage.setItem(KEY_SPAWN_PROVIDER, value)
    }
  } catch {
    /* ignore */
  }
}

export function loadBoardGridEnabled(): boolean {
  try {
    return localStorage.getItem(KEY_BOARD_GRID) === '1'
  } catch {
    return false
  }
}

export function saveBoardGridEnabled(value: boolean): void {
  try {
    if (value) localStorage.setItem(KEY_BOARD_GRID, '1')
    else localStorage.removeItem(KEY_BOARD_GRID)
    window.dispatchEvent(new Event(BOARD_PREFERENCES_CHANGED))
  } catch {
    /* ignore */
  }
}

export function loadCanvasRecapIntervalMinutes(): number {
  try {
    const raw = localStorage.getItem(KEY_CANVAS_RECAP_INTERVAL_MINUTES)
    if (raw == null) return DEFAULT_CANVAS_RECAP_INTERVAL_MINUTES
    const parsed = Number.parseInt(raw, 10)
    if (!Number.isFinite(parsed)) return DEFAULT_CANVAS_RECAP_INTERVAL_MINUTES
    return Math.max(0, Math.min(120, parsed))
  } catch {
    return DEFAULT_CANVAS_RECAP_INTERVAL_MINUTES
  }
}

export function saveCanvasRecapIntervalMinutes(value: number): void {
  const normalized = Math.max(0, Math.min(120, Math.round(value)))
  try {
    if (normalized === DEFAULT_CANVAS_RECAP_INTERVAL_MINUTES) {
      localStorage.removeItem(KEY_CANVAS_RECAP_INTERVAL_MINUTES)
    } else {
      localStorage.setItem(KEY_CANVAS_RECAP_INTERVAL_MINUTES, String(normalized))
    }
    window.dispatchEvent(new Event(CANVAS_RECAP_PREFERENCES_CHANGED))
  } catch {
    /* ignore */
  }
}

// UI-5.2 — viewport opt-out helpers.
//
// `loadLockViewportOnSwitch` is a global user preference. Default false keeps
// the historical fit-view-on-switch behavior; flipping it on means the planner
// will restore the saved per-canvas pose instead of auto-fitting.
//
// `load/savePlannerViewport` persist the last known viewport per canvas under
// `meee2.planner.viewport.<canvasId>`. PlannerGraph writes here on user pan/
// zoom and reads on canvas entry. We keep the save unconditional (cheap, lets
// users flip the lock on later and still get a sensible restore), but only
// honor the saved pose on switch when the lock preference is on.
export function loadLockViewportOnSwitch(): boolean {
  try {
    return localStorage.getItem(KEY_LOCK_VIEWPORT_ON_SWITCH) === '1'
  } catch {
    return DEFAULT_LOCK_VIEWPORT_ON_SWITCH
  }
}

export function saveLockViewportOnSwitch(value: boolean): void {
  try {
    if (value === DEFAULT_LOCK_VIEWPORT_ON_SWITCH) {
      localStorage.removeItem(KEY_LOCK_VIEWPORT_ON_SWITCH)
    } else {
      localStorage.setItem(KEY_LOCK_VIEWPORT_ON_SWITCH, value ? '1' : '0')
    }
    window.dispatchEvent(new Event(LOCK_VIEWPORT_PREFERENCES_CHANGED))
  } catch {
    /* ignore */
  }
}

export interface PlannerViewportPose {
  x: number
  y: number
  zoom: number
}

export function loadPlannerViewport(canvasId: string): PlannerViewportPose | null {
  if (!canvasId) return null
  try {
    const raw = localStorage.getItem(KEY_PLANNER_VIEWPORT_PREFIX + canvasId)
    if (!raw) return null
    const parsed = JSON.parse(raw)
    if (
      parsed &&
      typeof parsed.x === 'number' && Number.isFinite(parsed.x) &&
      typeof parsed.y === 'number' && Number.isFinite(parsed.y) &&
      typeof parsed.zoom === 'number' && Number.isFinite(parsed.zoom) && parsed.zoom > 0
    ) {
      return { x: parsed.x, y: parsed.y, zoom: parsed.zoom }
    }
  } catch {
    /* ignore */
  }
  return null
}

export function savePlannerViewport(canvasId: string, pose: PlannerViewportPose): void {
  if (!canvasId) return
  try {
    localStorage.setItem(
      KEY_PLANNER_VIEWPORT_PREFIX + canvasId,
      JSON.stringify({ x: pose.x, y: pose.y, zoom: pose.zoom }),
    )
  } catch {
    /* ignore */
  }
}

/** Backward-compatible helper for older call sites. Prefer provider helpers. */
export function loadDefaultSpawnCommand(): string {
  return commandForSpawnProvider(loadSpawnProvider())
}

/** Backward-compatible helper for older call sites. Prefer provider helpers. */
export function saveDefaultSpawnCommand(value: string): void {
  saveSpawnProvider(value.trim().toLowerCase().startsWith('codex') ? 'codex' : 'claude')
}
