/**
 * BadgeWidget — compact one-line summary for small nodes.
 *
 * Renders the *first* entity in `data.entities`. If multiple are present we
 * show a `+N` chip so the node still hints at the full count. Intended for
 * the 220×80 default frame; it grows fluidly with the parent box.
 */

import type { CSSProperties } from 'react'
import type { BaseWidgetProps } from './types'
import { EMPTY_STATE_COPY } from './types'

export function BadgeWidget({ data, width, height, onEntityClick }: BaseWidgetProps) {
  const { entities, loading, error } = data

  const containerStyle: CSSProperties = { width, height }

  if (error) {
    return (
      <div className="widget-badge widget-badge--error" style={containerStyle}>
        {error}
      </div>
    )
  }
  if (loading && entities.length === 0) {
    return (
      <div className="widget-badge widget-badge--empty" style={containerStyle}>
        加载中…
      </div>
    )
  }
  const head = entities[0]
  if (!head) {
    return (
      <div className="widget-badge widget-badge--empty" style={containerStyle}>
        {EMPTY_STATE_COPY.artifactSource}
      </div>
    )
  }
  const overflow = entities.length - 1

  return (
    <button
      type="button"
      className={`widget-badge widget-badge--${head.status}`}
      style={containerStyle}
      onClick={onEntityClick ? () => onEntityClick(head) : undefined}
    >
      <span
        className={`widget-badge__dot widget-badge__dot--${head.status}`}
        aria-hidden="true"
      />
      <span className="widget-badge__body">
        <span className="widget-badge__title">{head.title}</span>
        {head.subtitle && (
          <span className="widget-badge__subtitle">{head.subtitle}</span>
        )}
      </span>
      {overflow > 0 && <span className="widget-badge__more">+{overflow}</span>}
    </button>
  )
}
