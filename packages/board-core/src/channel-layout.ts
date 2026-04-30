// Position store for channel hub ellipses on the canvas.
// Ported from meee2/web/src/channelLayout.ts — persistence delegated to CanvasPersistence.

import type { LayoutMap, Point } from './layout'

/**
 * Given channel names + an existing layout, produce a layout that includes a
 * position for any missing channel. Channels stack in a single column to the
 * right of the session grid.
 */
export function ensureChannelPositions(
  channelNames: string[],
  map: LayoutMap,
): LayoutMap {
  const result: LayoutMap = { ...map }
  const missing = channelNames.filter((name) => !(name in result))
  if (missing.length === 0) return result

  const COL_W = 250
  const ROW_H = 160
  const ORIGIN_X = 80
  const ORIGIN_Y = 80
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
