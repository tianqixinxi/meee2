// localStorage-backed position store for channel hub ellipses on the canvas.
//
// Separate from session layout (see layout.ts) because:
//   - Channel identity is the channel name (string keys, no session id space).
//   - We want to evolve the two seeding grids independently (channels tuck to
//     the right of the session grid; sessions stay in their own column set).
//   - Keeping them in distinct storage slots means clearing one layout for
//     debugging doesn't nuke the other.

import type { LayoutMap, Point } from './layout'

const STORAGE_KEY = 'meee2.board.channel-layout.v1'

export function loadChannelLayout(): LayoutMap {
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

export function saveChannelLayout(map: LayoutMap): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(map))
  } catch {
    // ignore (quota / private mode)
  }
}

/**
 * Given channel names + an existing layout, produce a layout that includes a
 * position for any missing channel. Doesn't mutate the input map.
 *
 * Layout strategy: channels stack in a single column *to the right* of the
 * session grid (which occupies columns 0-2 in `ensurePositions`). We start at
 * the equivalent of "column 4" (leaving one column of breathing room between
 * the last session column and the hub column) and walk down by `ROW_H`.
 */
export function ensureChannelPositions(
  channelNames: string[],
  map: LayoutMap,
): LayoutMap {
  const result: LayoutMap = { ...map }
  const missing = channelNames.filter((name) => !(name in result))
  if (missing.length === 0) return result

  // Align constants with layout.ts:ensurePositions so rows line up visually.
  const COL_W = 250
  const ROW_H = 160
  const ORIGIN_X = 80
  const ORIGIN_Y = 80
  // Session grid uses 3 columns (0,1,2). Skip column 3 as a gutter, land hubs
  // in column 4. Ellipse is smaller than a session rect, so also center it a
  // touch within the cell (+ (COL_W - CHANNEL_W_APPROX)/2) — but we don't have
  // the channel dims in this file; the magic number keeps it close enough.
  const HUB_COLUMN = 4
  const existingCount = channelNames.length - missing.length
  missing.forEach((name, idx) => {
    const n = existingCount + idx
    const x = ORIGIN_X + HUB_COLUMN * COL_W
    const y = ORIGIN_Y + n * ROW_H
    result[name] = { x, y } satisfies Point
  })
  return result
}
