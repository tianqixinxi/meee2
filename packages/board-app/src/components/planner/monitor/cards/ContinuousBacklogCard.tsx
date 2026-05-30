/**
 * ContinuousBacklogCard (§6.2) — for always-on (non-partitioned) flows: the
 * inflow/outflow rate over a window + the top-N stuck items.
 *
 * Backlog rate + stuck-item ranking are computed from the source's
 * EdgeConsumption / claim ledger, which isn't surfaced yet → the card renders
 * its node + window config plus the pending hint. No fabricated rates.
 */

import type { ContinuousBacklogConfig } from '../../../../types'
import type { MonitorCardProps } from '../cardTypes'
import { CardPending } from '../CardShell'

const WINDOW_LABEL: Record<NonNullable<ContinuousBacklogConfig['rateWindow']>, string> = {
  '1h': '近 1 小时',
  '24h': '近 24 小时',
  '7d': '近 7 天',
}

export function ContinuousBacklogCard({ config, ctx }: MonitorCardProps<ContinuousBacklogConfig>) {
  const node = ctx.nodesById[config.nodeId]
  const window = config.rateWindow ?? '24h'
  const topN = config.topStuckCount ?? 5

  return (
    <div className="monitor-continuous-backlog">
      <div className="monitor-continuous-backlog__node">{node?.title ?? config.nodeId}</div>
      <div className="monitor-continuous-backlog__window">{WINDOW_LABEL[window]} · Top {topN} 卡住项</div>
      <CardPending what="进/出速率与最久未处理的积压项" />
    </div>
  )
}
