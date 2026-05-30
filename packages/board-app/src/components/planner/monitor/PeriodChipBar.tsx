/**
 * PeriodChipBar — the period chip strip (W22 / W21 / …) for partition-aware
 * cards (§6.4).
 *
 * Selecting a period is *execution / local UI* (§6.5): the choice is persisted
 * to `localStorage` keyed by `canvasId + cardId`, never proposed. The actual
 * list of available periods comes from the bound DataSource's partition index
 * — which the backend does not surface yet — so when no `periods` prop is
 * provided the bar renders a graceful "（待后端接入）" hint instead of
 * fabricating week labels.
 */

import { useCallback, useEffect, useState } from 'react'
import { PENDING_BACKEND_HINT } from './cardTypes'

function storageKey(canvasId: string, cardId: string): string {
  return `meee2.monitor.period.${canvasId}.${cardId}`
}

/** Read the persisted period for a (canvas, card). SSR-safe / quota-safe. */
export function readPersistedPeriod(canvasId: string, cardId: string): string | null {
  try {
    return window.localStorage.getItem(storageKey(canvasId, cardId))
  } catch {
    return null
  }
}

function writePersistedPeriod(canvasId: string, cardId: string, period: string): void {
  try {
    window.localStorage.setItem(storageKey(canvasId, cardId), period)
  } catch {
    /* private mode / quota — period selection just won't persist */
  }
}

export interface PeriodChipBarProps {
  canvasId: string
  cardId: string
  /**
   * Available period keys, newest-first (e.g. ['2026-W22','2026-W21', …]).
   * Undefined = backend has not surfaced the partition index yet → pending
   * hint. Empty array = source has no partitions yet → empty hint.
   */
  periods?: string[]
  /** Server default period when nothing is persisted. */
  defaultPeriod?: string
  /** Max chips to render (the rest collapse behind a +N affordance). */
  visibleCount?: number
  /** Fired whenever the active period changes (host re-filters its rows). */
  onChange?: (period: string) => void
}

export function PeriodChipBar({
  canvasId,
  cardId,
  periods,
  defaultPeriod,
  visibleCount = 4,
  onChange,
}: PeriodChipBarProps) {
  const [active, setActive] = useState<string | null>(() => {
    const persisted = readPersistedPeriod(canvasId, cardId)
    return persisted ?? defaultPeriod ?? null
  })

  // Reconcile when the available period set arrives / changes: if the active
  // period is no longer offered, fall back to the newest available one.
  useEffect(() => {
    if (!periods || periods.length === 0) return
    if (active && periods.includes(active)) return
    const next = defaultPeriod && periods.includes(defaultPeriod) ? defaultPeriod : periods[0]
    setActive(next)
  }, [periods, active, defaultPeriod])

  const select = useCallback(
    (period: string) => {
      setActive(period)
      writePersistedPeriod(canvasId, cardId, period)
      onChange?.(period)
    },
    [canvasId, cardId, onChange],
  )

  if (periods === undefined) {
    return <div className="period-chip-bar period-chip-bar--pending">分区周期 {PENDING_BACKEND_HINT}</div>
  }
  if (periods.length === 0) {
    return <div className="period-chip-bar period-chip-bar--empty">暂无分区周期</div>
  }

  const visible = periods.slice(0, Math.max(1, visibleCount))
  const overflow = periods.length - visible.length

  return (
    <div className="period-chip-bar" role="tablist" aria-label="周期">
      {visible.map((p) => (
        <button
          key={p}
          type="button"
          role="tab"
          aria-selected={p === active}
          className={`period-chip${p === active ? ' period-chip--active' : ''}`}
          onClick={() => select(p)}
        >
          {p}
        </button>
      ))}
      {overflow > 0 && <span className="period-chip-bar__more">+{overflow}</span>}
    </div>
  )
}
