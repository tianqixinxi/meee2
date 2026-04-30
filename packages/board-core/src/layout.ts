// Position store for session rectangles on the canvas.
// Ported from meee2/web/src/layout.ts — persistence delegated to CanvasPersistence.

export interface Point {
  x: number
  y: number
}

export type LayoutMap = Record<string, Point>

const CARD_W = 360
const CARD_H = 260
const GAP_X = 40
const GAP_Y = 40
const COLS = 3
const COL_W = CARD_W + GAP_X
const ROW_H = CARD_H + GAP_Y
const ORIGIN_X = 80
const ORIGIN_Y = 80

const LEGACY_COL_W = 250
const LEGACY_ROW_H = 160

function autoGridPoint(index: number, colWidth: number, rowHeight: number): Point {
  const col = index % COLS
  const row = Math.floor(index / COLS)
  return {
    x: ORIGIN_X + col * colWidth,
    y: ORIGIN_Y + row * rowHeight,
  }
}

function isSamePoint(a: Point | undefined, b: Point): boolean {
  return Boolean(a && Math.abs(a.x - b.x) < 0.5 && Math.abs(a.y - b.y) < 0.5)
}

function nextAdjacentPoints(existing: Point[], count: number): Point[] {
  if (count <= 0) return []
  const points: Point[] = []
  const baseX = existing.length > 0 ? Math.min(...existing.map((p) => p.x)) : ORIGIN_X
  const baseY = existing.length > 0 ? Math.min(...existing.map((p) => p.y)) : ORIGIN_Y
  const occupied = new Set<string>()

  const slotKey = (col: number, row: number) => `${col}:${row}`
  const pointForSlot = (col: number, row: number): Point => ({
    x: baseX + col * COL_W,
    y: baseY + row * ROW_H,
  })

  for (const point of existing) {
    const col = Math.max(0, Math.round((point.x - baseX) / COL_W))
    const row = Math.max(0, Math.round((point.y - baseY) / ROW_H))
    occupied.add(slotKey(col, row))
  }

  let cursor = 0
  while (points.length < count) {
    const col = cursor % COLS
    const row = Math.floor(cursor / COLS)
    const key = slotKey(col, row)
    if (!occupied.has(key)) {
      occupied.add(key)
      points.push(pointForSlot(col, row))
    }
    cursor += 1
  }

  return points
}

export function arrangePositions(sessionIds: string[]): LayoutMap {
  const result: LayoutMap = {}
  sessionIds.forEach((id, idx) => {
    result[id] = autoGridPoint(idx, COL_W, ROW_H)
  })
  return result
}

/**
 * Given a set of session ids and an existing layout, produce a layout that
 * includes a soft grid position for any missing sessions.
 */
export function ensurePositions(
  sessionIds: string[],
  map: LayoutMap,
): LayoutMap {
  const result: LayoutMap = { ...map }
  for (const [idx, id] of sessionIds.entries()) {
    if (isSamePoint(result[id], autoGridPoint(idx, LEGACY_COL_W, LEGACY_ROW_H))) {
      delete result[id]
    }
  }

  const missing = sessionIds.filter((id) => !(id in result))
  if (missing.length === 0) return result

  const existingPoints = sessionIds
    .filter((id) => !missing.includes(id))
    .map((id) => result[id])
    .filter((point): point is Point => Boolean(point))
  const nextPoints = nextAdjacentPoints(existingPoints, missing.length)
  missing.forEach((id, idx) => {
    result[id] = nextPoints[idx] ?? autoGridPoint(idx, COL_W, ROW_H)
  })
  return result
}

/**
 * Debounce helper — returns a function + flush + cancel.
 */
export function debounce<Args extends unknown[]>(
  fn: (...args: Args) => void,
  ms: number,
): ((...args: Args) => void) & { flush: () => void; cancel: () => void } {
  let timer: ReturnType<typeof setTimeout> | null = null
  let lastArgs: Args | null = null

  const invoke = () => {
    if (lastArgs) {
      fn(...lastArgs)
      lastArgs = null
    }
    timer = null
  }

  const debounced = ((...args: Args) => {
    lastArgs = args
    if (timer !== null) clearTimeout(timer)
    timer = setTimeout(invoke, ms)
  }) as ((...args: Args) => void) & { flush: () => void; cancel: () => void }

  debounced.flush = () => {
    if (timer !== null) {
      clearTimeout(timer)
      invoke()
    }
  }
  debounced.cancel = () => {
    if (timer !== null) {
      clearTimeout(timer)
      timer = null
    }
    lastArgs = null
  }

  return debounced
}
