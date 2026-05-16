import type { SpawnProvider } from './types'

// 用户偏好：默认 global/new session provider。
// 全部 localStorage 托管，不走后端——这是每个 browser/用户的 UI 偏好。

const KEY_SPAWN_PROVIDER = 'meee2.spawn.provider.v1'
const LEGACY_KEY_SPAWN_COMMAND = 'meee2.spawn.defaultCommand.v1'
const KEY_BOARD_GRID = 'meee2.board.gridMode.v1'
export const BOARD_PREFERENCES_CHANGED = 'meee2:board-preferences-changed'

export const DEFAULT_SPAWN_PROVIDER: SpawnProvider = 'claude'

export function commandForSpawnProvider(provider: SpawnProvider): string {
  return provider === 'codex' ? 'codex' : 'claude'
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

/** Backward-compatible helper for older call sites. Prefer provider helpers. */
export function loadDefaultSpawnCommand(): string {
  return commandForSpawnProvider(loadSpawnProvider())
}

/** Backward-compatible helper for older call sites. Prefer provider helpers. */
export function saveDefaultSpawnCommand(value: string): void {
  saveSpawnProvider(value.trim().toLowerCase().startsWith('codex') ? 'codex' : 'claude')
}
