// 用户偏好：目前只有一个默认 spawn command（后续加 profile 的话从这里扩）。
// 全部 localStorage 托管，不走后端——这是每个 browser/用户的 UI 偏好。

const KEY_SPAWN_COMMAND = 'meee2.spawn.defaultCommand.v1'

/** 默认 command：原生沿用 "claude"。 */
export const DEFAULT_SPAWN_COMMAND = 'claude'

export function loadDefaultSpawnCommand(): string {
  try {
    const v = localStorage.getItem(KEY_SPAWN_COMMAND)
    if (typeof v === 'string' && v.trim().length > 0) return v
  } catch {
    /* ignore */
  }
  return DEFAULT_SPAWN_COMMAND
}

export function saveDefaultSpawnCommand(value: string): void {
  try {
    const v = value.trim()
    if (v.length === 0 || v === DEFAULT_SPAWN_COMMAND) {
      localStorage.removeItem(KEY_SPAWN_COMMAND)
    } else {
      localStorage.setItem(KEY_SPAWN_COMMAND, v)
    }
  } catch {
    /* ignore */
  }
}
