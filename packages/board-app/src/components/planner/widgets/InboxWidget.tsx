/**
 * InboxWidget — flat priority-sorted list view.
 *
 * Default sort order surfaces the highest-attention rows first
 * (blocked > awaiting > todo > running > done). Visual lineage is the now
 * removed canvas-level `InboxCanvas`.
 */

import type { CSSProperties } from 'react'
import type { BaseWidgetProps, WidgetEntityStatus } from './types'
import { EMPTY_STATE_COPY, STATUS_LABEL } from './types'

const STATUS_PRIORITY: Record<WidgetEntityStatus, number> = {
  blocked: 0,
  awaiting: 1,
  todo: 2,
  running: 3,
  done: 4,
}

export function InboxWidget({ data, width, height, onEntityClick }: BaseWidgetProps) {
  const { entities, loading, error } = data

  if (error) {
    return <div className="widget-inbox__empty widget-inbox__empty--error">{error}</div>
  }
  if (loading && entities.length === 0) {
    return <div className="widget-inbox__empty">加载中…</div>
  }
  if (entities.length === 0) {
    return <div className="widget-inbox__empty">{EMPTY_STATE_COPY.collectionSource}</div>
  }

  const sorted = [...entities].sort(
    (a, b) => STATUS_PRIORITY[a.status] - STATUS_PRIORITY[b.status],
  )

  const containerStyle: CSSProperties = { width, height }

  return (
    <div className="widget-inbox" style={containerStyle}>
      <ul className="widget-inbox__list">
        {sorted.map((ent) => (
          <li key={ent.id} className="widget-inbox__row">
            <button
              type="button"
              className="widget-inbox__row-button"
              onClick={onEntityClick ? () => onEntityClick(ent) : undefined}
            >
              <span
                className={`widget-inbox__dot widget-inbox__dot--${ent.status}`}
                aria-hidden="true"
              />
              <span className="widget-inbox__title">{ent.title}</span>
              {ent.subtitle && (
                <span className="widget-inbox__subtitle">{ent.subtitle}</span>
              )}
              <span
                className={`widget-inbox__badge widget-inbox__badge--${ent.status}`}
              >
                {STATUS_LABEL[ent.status]}
              </span>
            </button>
          </li>
        ))}
      </ul>
    </div>
  )
}
