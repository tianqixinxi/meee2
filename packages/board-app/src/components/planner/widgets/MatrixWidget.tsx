/**
 * MatrixWidget — owner × status grid.
 *
 * Rows = distinct owners (taken from `entity.subtitle` as a v0.1 fallback);
 * columns = the same 5 status buckets as KanbanWidget. Each cell stacks at
 * most three mini-cards and rolls the remainder into a `+N` chip.
 *
 * v0.1 keeps the dimensions hard-coded; the `widget.mapping` overrides
 * (rowGroupField / colGroupField) will land once nodes can declare them.
 */

import type { CSSProperties } from 'react'
import { useI18n } from '../../../lib/i18n'
import type { BaseWidgetProps, WidgetEntity, WidgetEntityStatus } from './types'
import { EMPTY_STATE_COPY, STATUS_LABEL } from './types'

const COLUMN_ORDER: readonly WidgetEntityStatus[] = [
  'todo',
  'awaiting',
  'running',
  'blocked',
  'done',
] as const

const COLUMNS: ReadonlyArray<{ status: WidgetEntityStatus; label: string }> =
  COLUMN_ORDER.map((status) => ({ status, label: STATUS_LABEL[status] }))

const MAX_CARDS_PER_CELL = 3

/**
 * v0.1 limitation: we use `entity.subtitle` as the owner row group because
 * widgets don't yet receive a typed owner field. Once `widget.mapping.rowGroupField`
 * (per node-widget-model.md chunk 2.2) lands we'll switch to that. The empty
 * label reuses `monitor.unassigned` so the locale matches WorkspaceMonitor's
 * "未分配 / Unassigned" — keep these in sync, don't introduce a third wording.
 */
function ownerOf(ent: WidgetEntity, unassignedLabel: string): string {
  const owner = ent.subtitle?.trim()
  return owner && owner.length > 0 ? owner : unassignedLabel
}

export function MatrixWidget({ data, width, height, onEntityClick }: BaseWidgetProps) {
  const { t } = useI18n()
  const unassignedLabel = t('monitor.unassigned')
  const { entities, loading, error } = data

  if (error) {
    return <div className="widget-matrix__empty widget-matrix__empty--error">{error}</div>
  }
  if (loading && entities.length === 0) {
    return <div className="widget-matrix__empty">加载中…</div>
  }
  if (entities.length === 0) {
    return <div className="widget-matrix__empty">{EMPTY_STATE_COPY.collectionSource}</div>
  }

  // Build owner row order: first-seen order, stable for repeated renders.
  const ownerOrder: string[] = []
  const cells = new Map<string, WidgetEntity[]>()
  for (const ent of entities) {
    const owner = ownerOf(ent, unassignedLabel)
    if (!ownerOrder.includes(owner)) ownerOrder.push(owner)
    const key = `${owner}::${ent.status}`
    const bucket = cells.get(key) ?? []
    bucket.push(ent)
    cells.set(key, bucket)
  }

  const containerStyle: CSSProperties = { width, height }

  return (
    <div className="widget-matrix" style={containerStyle}>
      <div className="widget-matrix__grid">
        <div className="widget-matrix__corner" />
        {COLUMNS.map((col) => (
          <div key={col.status} className="widget-matrix__col-header">
            <span
              className={`widget-matrix__dot widget-matrix__dot--${col.status}`}
              aria-hidden="true"
            />
            <span>{col.label}</span>
          </div>
        ))}
        {ownerOrder.map((owner) => (
          <RowFragment
            key={owner}
            owner={owner}
            cells={cells}
            onEntityClick={onEntityClick}
          />
        ))}
      </div>
    </div>
  )
}

function RowFragment({
  owner,
  cells,
  onEntityClick,
}: {
  owner: string
  cells: Map<string, WidgetEntity[]>
  onEntityClick?: (entity: WidgetEntity) => void
}) {
  return (
    <>
      <div className="widget-matrix__row-header" title={owner}>
        {owner}
      </div>
      {COLUMNS.map((col) => {
        const list = cells.get(`${owner}::${col.status}`) ?? []
        const visible = list.slice(0, MAX_CARDS_PER_CELL)
        const overflow = list.length - visible.length
        return (
          <div key={col.status} className="widget-matrix__cell">
            {visible.map((ent) => (
              <button
                key={ent.id}
                type="button"
                className={`widget-matrix__mini-card widget-matrix__mini-card--${ent.status}`}
                title={ent.title}
                onClick={onEntityClick ? () => onEntityClick(ent) : undefined}
              >
                {ent.title}
              </button>
            ))}
            {overflow > 0 && (
              <span className="widget-matrix__more">+{overflow}</span>
            )}
            {list.length === 0 && <span className="widget-matrix__cell-empty">·</span>}
          </div>
        )
      })}
    </>
  )
}
