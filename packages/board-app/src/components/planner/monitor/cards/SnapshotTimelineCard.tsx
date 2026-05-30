/**
 * SnapshotTimelineCard (§6.2) — version timeline for a DataSource slot. Also
 * absorbs the pre-widget review-status header that used to live on
 * PlannerNodeCard (§9.5 remove list).
 *
 * Real data: renders the bound node's artifacts as timeline rows (newest
 * first), surfacing each artifact's review status. The richer per-version
 * diff preview (`showDiffPreview`) needs the artifact-version chain endpoint
 * wired into the monitor → graceful hint.
 */

import type { PlannerArtifact, SnapshotTimelineConfig } from '../../../../types'
import type { MonitorCardProps } from '../cardTypes'
import { CardEmpty, CardPending } from '../CardShell'

function reviewBadge(a: PlannerArtifact): { label: string; tone: string } {
  const rs = a.reviewStatus ?? 'approved'
  if (rs === 'pending') return { label: '待确认', tone: 'awaiting' }
  if (rs === 'rejected') return { label: '已退回', tone: 'blocked' }
  return { label: '已确认', tone: 'done' }
}

export function SnapshotTimelineCard({ config, ctx }: MonitorCardProps<SnapshotTimelineConfig>) {
  const all = ctx.artifactsByNodeId[config.source.nodeId] ?? []
  // Optionally narrow to a slot when the artifact reference carries the slot.
  const slot = config.source.slotKey
  const scoped = slot ? all.filter((a) => a.reference.includes(slot) || a.title.includes(slot)) : all
  const visible = scoped.slice(0, Math.max(1, config.visibleVersionCount ?? 10))
  const pinned = new Set(config.pinnedVersionIds ?? [])

  if (scoped.length === 0) {
    return <CardEmpty message="暂无快照版本" />
  }

  return (
    <div className="monitor-snapshot-timeline">
      <ol className="monitor-snapshot-timeline__list">
        {visible.map((a) => {
          const badge = reviewBadge(a)
          return (
            <li
              key={a.id}
              className={`monitor-snapshot-row${pinned.has(a.id) ? ' monitor-snapshot-row--pinned' : ''}`}
            >
              <span className={`monitor-snapshot-row__review monitor-snapshot-row__review--${badge.tone}`}>
                {badge.label}
              </span>
              <span className="monitor-snapshot-row__title">{a.title}</span>
              <span className="monitor-snapshot-row__time">
                {new Date(a.createdAt).toLocaleString()}
              </span>
            </li>
          )
        })}
      </ol>
      {config.showDiffPreview && <CardPending what="版本间 diff 预览" />}
    </div>
  )
}
