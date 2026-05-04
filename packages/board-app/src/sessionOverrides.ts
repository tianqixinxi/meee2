/**
 * Session 用户级 override：title 重命名 + 置顶（pin）。
 * 都用 localStorage 持久化，不动后端——避免 rename 跟不同 plugin 的 title 来源
 * 冲突（Claude session 的 title 是 transcript 里 auto-generated 的，外部 web 的
 * 又是另一套）。前端 override 让 UI 显示用户起的名字。
 */

const TITLE_KEY = 'meee2.session.titleOverrides.v1'
const PINNED_KEY = 'meee2.session.pinned.v1'

export function loadTitleOverrides(): Record<string, string> {
  try {
    const raw = localStorage.getItem(TITLE_KEY)
    return raw ? (JSON.parse(raw) as Record<string, string>) : {}
  } catch {
    return {}
  }
}

export function saveTitleOverride(sessionId: string, title: string | null) {
  try {
    const cur = loadTitleOverrides()
    if (title && title.trim()) {
      cur[sessionId] = title.trim()
    } else {
      delete cur[sessionId]
    }
    localStorage.setItem(TITLE_KEY, JSON.stringify(cur))
    window.dispatchEvent(new CustomEvent('meee2:session-overrides-changed'))
  } catch {
    /* localStorage unavailable */
  }
}

export function loadPinnedSet(): Set<string> {
  try {
    const raw = localStorage.getItem(PINNED_KEY)
    if (!raw) return new Set()
    const arr = JSON.parse(raw) as string[]
    return new Set(arr)
  } catch {
    return new Set()
  }
}

export function togglePinned(sessionId: string): boolean {
  try {
    const cur = loadPinnedSet()
    const wasPinned = cur.has(sessionId)
    if (wasPinned) cur.delete(sessionId)
    else cur.add(sessionId)
    localStorage.setItem(PINNED_KEY, JSON.stringify([...cur]))
    window.dispatchEvent(new CustomEvent('meee2:session-overrides-changed'))
    return !wasPinned
  } catch {
    return false
  }
}
