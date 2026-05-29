/**
 * ArtifactPreviewWidget — show the head of a markdown / text artifact body.
 *
 * Treats `entity.details[0].value` as the body content (matching the producer
 * convention used by `submit_node_output` previews). The caption row reuses
 * `entity.title`; if no details/value is present we fall back to a short
 * "no preview available" hint so the widget never collapses to 0 height.
 */

import type { CSSProperties } from 'react'
import type { BaseWidgetProps, WidgetEntity } from './types'

const APPROX_LINE_HEIGHT_PX = 16
const CAPTION_OVERHEAD_PX = 36

function previewLinesFor(entity: WidgetEntity, height: number): string[] {
  const body = entity.details?.[0]?.value ?? ''
  if (!body) return []
  const usableHeight = Math.max(0, height - CAPTION_OVERHEAD_PX)
  const maxLines = Math.max(2, Math.floor(usableHeight / APPROX_LINE_HEIGHT_PX))
  return body
    .split(/\r?\n/)
    .slice(0, maxLines)
}

export function ArtifactPreviewWidget({
  data,
  width,
  height,
  onEntityClick,
}: BaseWidgetProps) {
  const { entities, loading, error } = data
  const containerStyle: CSSProperties = { width, height }

  if (error) {
    return (
      <div className="widget-artifact widget-artifact--error" style={containerStyle}>
        {error}
      </div>
    )
  }
  if (loading && entities.length === 0) {
    return (
      <div className="widget-artifact widget-artifact--empty" style={containerStyle}>
        加载中…
      </div>
    )
  }
  const head = entities[0]
  if (!head) {
    return (
      <div className="widget-artifact widget-artifact--empty" style={containerStyle}>
        这个节点还没有产物 — 等上游节点产出
      </div>
    )
  }

  const lines = previewLinesFor(head, height)

  return (
    <div
      className={`widget-artifact widget-artifact--${head.status}`}
      style={containerStyle}
      onClick={onEntityClick ? () => onEntityClick(head) : undefined}
      role={onEntityClick ? 'button' : undefined}
      tabIndex={onEntityClick ? 0 : undefined}
    >
      <div className="widget-artifact__caption">
        <span
          className={`widget-artifact__dot widget-artifact__dot--${head.status}`}
          aria-hidden="true"
        />
        <span className="widget-artifact__title">{head.title}</span>
      </div>
      <div className="widget-artifact__body">
        {lines.length === 0 ? (
          <span className="widget-artifact__placeholder">
            这份成果暂时没有可预览的正文 — 打开节点详情查看完整内容
          </span>
        ) : (
          lines.map((line, i) => (
            <div key={i} className="widget-artifact__line">
              {line.length > 0 ? line : ' '}
            </div>
          ))
        )}
      </div>
    </div>
  )
}
