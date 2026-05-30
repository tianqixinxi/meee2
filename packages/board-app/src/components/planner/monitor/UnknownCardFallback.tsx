/**
 * UnknownCardFallback (§6.7) — graceful fallback for a `MonitorCardKind` the
 * planner emitted that this client build doesn't know how to render (e.g. a
 * newer card type shipped server-side first). Never crash — show a "需要更新
 * 客户端" hint with the raw type so the user can act / report.
 */

import type { MonitorCard } from '../../../types'

export function UnknownCardFallback({ card }: { card: MonitorCard }) {
  return (
    <div className="monitor-card monitor-card--unknown">
      <div className="monitor-card__unknown-title">未知卡片类型</div>
      <div className="monitor-card__unknown-type">
        <code>{(card as { type?: string }).type ?? '?'}</code>
      </div>
      <p className="monitor-card__unknown-hint">
        需要更新客户端才能显示这张卡片。
      </p>
    </div>
  )
}
