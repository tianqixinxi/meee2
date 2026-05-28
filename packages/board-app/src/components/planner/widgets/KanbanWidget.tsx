/**
 * KanbanWidget — 5-column status board.
 *
 * Pure presentational: groups `data.entities` by `status` into the canonical
 * five buckets (todo / awaiting / running / blocked / done). Visual lineage is
 * the now-removed canvas-level `KanbanCanvas`; here it is scoped to a single
 * planner node card.
 */

import type { CSSProperties } from 'react'
import type { BaseWidgetProps, WidgetEntity, WidgetEntityStatus } from './types'
import { STATUS_LABEL } from './types'

interface ColumnDef {
  status: WidgetEntityStatus
  label: string
}

const COLUMN_ORDER: readonly WidgetEntityStatus[] = [
  'todo',
  'awaiting',
  'running',
  'blocked',
  'done',
] as const

const COLUMNS: readonly ColumnDef[] = COLUMN_ORDER.map((status) => ({
  status,
  label: STATUS_LABEL[status],
}))

export function KanbanWidget({ data, width, height, onEntityClick }: BaseWidgetProps) {
  const { entities, loading, error } = data

  if (error) {
    return <div className="widget-kanban__empty widget-kanban__empty--error">{error}</div>
  }
  if (loading && entities.length === 0) {
    return <div className="widget-kanban__empty">加载中…</div>
  }

  const grouped = new Map<WidgetEntityStatus, WidgetEntity[]>()
  for (const col of COLUMNS) grouped.set(col.status, [])
  for (const ent of entities) {
    const bucket = grouped.get(ent.status) ?? grouped.get('todo')!
    bucket.push(ent)
  }

  const containerStyle: CSSProperties = { width, height }

  return (
    <div className="widget-kanban" style={containerStyle}>
      {COLUMNS.map((col) => {
        const items = grouped.get(col.status) ?? []
        return (
          <div key={col.status} className="widget-kanban__column">
            <div className="widget-kanban__column-header">
              <span
                className={`widget-kanban__dot widget-kanban__dot--${col.status}`}
                aria-hidden="true"
              />
              <span className="widget-kanban__column-label">{col.label}</span>
              <span className="widget-kanban__column-count">{items.length}</span>
            </div>
            <div className="widget-kanban__column-body">
              {items.length === 0 ? (
                <div className="widget-kanban__column-empty">—</div>
              ) : (
                items.map((ent) => (
                  <button
                    key={ent.id}
                    type="button"
                    className={`widget-kanban__card widget-kanban__card--${ent.status}`}
                    onClick={onEntityClick ? () => onEntityClick(ent) : undefined}
                  >
                    <span className="widget-kanban__card-title">{ent.title}</span>
                    {ent.subtitle && (
                      <span className="widget-kanban__card-subtitle">{ent.subtitle}</span>
                    )}
                  </button>
                ))
              )}
            </div>
          </div>
        )
      })}
    </div>
  )
}
