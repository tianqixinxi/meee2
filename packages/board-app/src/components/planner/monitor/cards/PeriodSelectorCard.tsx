/**
 * PeriodSelectorCard (§6.2) — drives the active partition period for the cards
 * it `controlsCardIds`. Renders the PeriodChipBar; the real period list comes
 * from the bound DataSource's partition index (待后端接入), so until then the
 * bar shows the pending hint rather than inventing weeks.
 */

import type { PeriodSelectorConfig } from '../../../../types'
import type { MonitorCardProps } from '../cardTypes'
import { PeriodChipBar } from '../PeriodChipBar'

export function PeriodSelectorCard({ card, config, ctx }: MonitorCardProps<PeriodSelectorConfig>) {
  const sourceNode = ctx.nodesById[config.source.nodeId]
  return (
    <div className="monitor-period-selector">
      <PeriodChipBar
        canvasId={ctx.canvasId}
        cardId={card.id}
        // Backend does not yet surface the partition index for the bound
        // source — pass undefined to render the pending hint, never faked weeks.
        periods={undefined}
        defaultPeriod={config.defaultPeriod}
        visibleCount={config.visibleCount}
      />
      <p className="monitor-period-selector__source">
        来源:{sourceNode?.title ?? config.source.nodeId}
        {config.source.slotKey ? ` · ${config.source.slotKey}` : ''}
      </p>
      {config.controlsCardIds && config.controlsCardIds.length > 0 && (
        <p className="monitor-period-selector__controls">
          联动 {config.controlsCardIds.length} 张卡片
        </p>
      )}
    </div>
  )
}
