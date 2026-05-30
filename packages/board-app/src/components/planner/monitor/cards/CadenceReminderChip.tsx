/**
 * CadenceReminderChip (§6.2) — PM-ADDON card (Principle 15).
 *
 * Unlike the core ledger cards, this asserts an *expectation* ("this node
 * should have produced something this period") rather than recording activity.
 * The core canvas never curates it into a MonitorSpec — it only renders when
 * the canvas's optional PM addon is enabled. The registry still routes it so
 * the addon and core share one fallback path; the actual addon gate lives in
 * `MonitorGrid` (it skips this card type when `CANVAS_PM_ADDON` is off).
 *
 * "Has the node met its cadence?" requires the activity ledger (待后端接入); we
 * render the configured expectation + reminder copy, not a fabricated verdict.
 */

import type { CadenceReminderConfig } from '../../../../types'
import type { MonitorCardProps } from '../cardTypes'
import { PENDING_BACKEND_HINT } from '../cardTypes'

function cadenceLabel(c: CadenceReminderConfig['expectedCadence']): string {
  switch (c.kind) {
    case 'every-period':
      return '每个周期'
    case 'every-n-days':
      return `每 ${c.n} 天`
    case 'before-date':
      return `截止 ${c.isoDate}`
  }
}

export function CadenceReminderChip({ config, ctx }: MonitorCardProps<CadenceReminderConfig>) {
  const node = ctx.nodesById[config.nodeId]
  return (
    <div className="monitor-cadence-chip">
      <span className="monitor-cadence-chip__addon" title="PM 插件卡片(非核心账本)">PM</span>
      <span className="monitor-cadence-chip__node">{node?.title ?? config.nodeId}</span>
      <span className="monitor-cadence-chip__cadence">{cadenceLabel(config.expectedCadence)}</span>
      <span className="monitor-cadence-chip__status">
        {config.reminderCopy ?? '是否按期'} {PENDING_BACKEND_HINT}
      </span>
    </div>
  )
}
