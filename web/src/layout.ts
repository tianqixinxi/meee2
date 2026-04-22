// localStorage-backed position store for session rectangles on the canvas.

const STORAGE_KEY = 'meee2.board.layout.v1'

export interface Point {
  x: number
  y: number
}

export type LayoutMap = Record<string, Point>

export function loadLayout(): LayoutMap {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) return {}
    const parsed = JSON.parse(raw)
    if (parsed && typeof parsed === 'object') {
      return parsed as LayoutMap
    }
  } catch {
    // ignore
  }
  return {}
}

export function saveLayout(map: LayoutMap): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(map))
  } catch {
    // ignore (quota / private mode)
  }
}

/**
 * Given a set of session ids and an existing layout, produce a layout that
 * includes a soft grid position for any missing sessions. Doesn't mutate `map`.
 */
export function ensurePositions(
  sessionIds: string[],
  map: LayoutMap,
): LayoutMap {
  const result: LayoutMap = { ...map }
  const missing = sessionIds.filter((id) => !(id in result))
  if (missing.length === 0) return result

  // Find the next slot so we don't overlap known positions — simple grid.
  const COLS = 3
  const COL_W = 250
  const ROW_H = 160
  const ORIGIN_X = 80
  const ORIGIN_Y = 80

  // Count existing grid cells in use to continue from there.
  const existingCount = sessionIds.length - missing.length
  missing.forEach((id, idx) => {
    const n = existingCount + idx
    const col = n % COLS
    const row = Math.floor(n / COLS)
    result[id] = {
      x: ORIGIN_X + col * COL_W,
      y: ORIGIN_Y + row * ROW_H,
    }
  })
  return result
}

/**
 * Debounce helper — returns a function + flush.
 */
export function debounce<T extends (...args: any[]) => void>(
  fn: T,
  ms: number,
): T & { flush: () => void; cancel: () => void } {
  let timer: number | null = null
  let lastArgs: any[] | null = null

  const invoke = () => {
    if (lastArgs) {
      fn(...(lastArgs as Parameters<T>))
      lastArgs = null
    }
    timer = null
  }

  const debounced = ((...args: Parameters<T>) => {
    lastArgs = args
    if (timer !== null) window.clearTimeout(timer)
    timer = window.setTimeout(invoke, ms)
  }) as T & { flush: () => void; cancel: () => void }

  debounced.flush = () => {
    if (timer !== null) {
      window.clearTimeout(timer)
      invoke()
    }
  }
  debounced.cancel = () => {
    if (timer !== null) {
      window.clearTimeout(timer)
      timer = null
    }
    lastArgs = null
  }

  return debounced
}
