/**
 * DownstreamDrillCard (§6.2) — rolled-up status for a parent node's subcanvas /
 * downstream tree, with a staleness watermark.
 *
 * Real data: the parent node's own run state renders today. The rolled-up
 * subcanvas status + per-child staleness (vs `stalenessMinutes`) requires the
 * subcanvas-aggregate backend, which isn't wired → graceful hint.
 */

import type { DownstreamDrillConfig } from '../../../../types'
import type { MonitorCardProps } from '../cardTypes'
import { CardPending } from '../CardShell'
import { RUN_STATE_LABEL, RUN_STATE_TONE } from './runStateLabel'

export function DownstreamDrillCard({ config, ctx }: MonitorCardProps<DownstreamDrillConfig>) {
  const parent = ctx.nodesById[config.parentNodeId]
  const snap = ctx.statesByNodeId[config.parentNodeId]
  const runState = snap?.runState ?? 'ready'
  const stalenessHrs = Math.round((config.stalenessMinutes ?? 60 * 24) / 60)

  return (
    <div className="monitor-downstream-drill">
      <div className="monitor-downstream-drill__parent">
        <span className="monitor-downstream-drill__parent-title">
          {parent?.title ?? config.parentNodeId}
        </span>
        {(config.showRolledUpStatus ?? true) && (
          <span className={`monitor-downstream-drill__state monitor-downstream-drill__state--${RUN_STATE_TONE[runState]}`}>
            {RUN_STATE_LABEL[runState]}
          </span>
        )}
      </div>
      <div className="monitor-downstream-drill__staleness">
        过期阈值:{stalenessHrs} 小时
      </div>
      <CardPending what="子画板/下游节点的汇总状态与各自的过期标记" />
    </div>
  )
}
