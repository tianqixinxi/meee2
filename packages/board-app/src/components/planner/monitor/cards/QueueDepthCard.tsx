/**
 * QueueDepthCard (§6.2) — pending count on an edge or source queue, with
 * warn/block thresholds. The actual queue depth (claimable items waiting on an
 * edge / unprocessed source items) is not yet surfaced by the backend, so this
 * renders its binding + thresholds as a config summary plus the pending hint.
 * We do NOT fabricate a depth number.
 */

import type { QueueDepthConfig } from '../../../../types'
import type { MonitorCardProps } from '../cardTypes'
import { CardPending } from '../CardShell'

export function QueueDepthCard({ config, ctx }: MonitorCardProps<QueueDepthConfig>) {
  const binding = config.binding
  let bindingLabel: string
  if (binding.kind === 'edge') {
    const up = ctx.nodesById[binding.upstreamNodeId]?.title ?? binding.upstreamNodeId
    const down = ctx.nodesById[binding.downstreamNodeId]?.title ?? binding.downstreamNodeId
    bindingLabel = `${up} → ${down}`
  } else {
    const src = ctx.nodesById[binding.source.nodeId]?.title ?? binding.source.nodeId
    bindingLabel = `来源:${src}${binding.source.slotKey ? ` · ${binding.source.slotKey}` : ''}`
  }

  return (
    <div className="monitor-queue-depth">
      <div className="monitor-queue-depth__binding">{bindingLabel}</div>
      {config.thresholds && (
        <div className="monitor-queue-depth__thresholds">
          预警 ≥ {config.thresholds.warnAt} · 阻塞 ≥ {config.thresholds.blockAt}
        </div>
      )}
      <CardPending
        what={
          config.showClaimedByBreakdown
            ? '队列深度 + 认领人分布'
            : '队列深度(等待处理的条目数)'
        }
      />
    </div>
  )
}
