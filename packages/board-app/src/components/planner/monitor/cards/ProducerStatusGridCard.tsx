/**
 * ProducerStatusGridCard (§6.2) — a grid of producer nodes with their current
 * run state. This renders REAL data today: each cell reads the producer node's
 * `NodeStateSnapshot.runState` + the awaiting timestamp where available.
 *
 * `awaitingSince` / `artifactPreviewLink` cells degrade gracefully when the
 * underlying data isn't present on the snapshot yet.
 */

import type { ProducerStatusGridConfig } from '../../../../types'
import type { MonitorCardProps } from '../cardTypes'
import { RUN_STATE_LABEL, RUN_STATE_TONE } from './runStateLabel'

export function ProducerStatusGridCard({ config, ctx }: MonitorCardProps<ProducerStatusGridConfig>) {
  const cellShows = config.cellShows ?? ['runState', 'awaitingSince']
  const columnCount = Math.min(12, Math.max(1, config.columnCount ?? 4))

  return (
    <div
      className="monitor-producer-grid"
      style={{ gridTemplateColumns: `repeat(${columnCount}, minmax(0, 1fr))` }}
    >
      {config.producerNodeIds.map((nodeId) => {
        const node = ctx.nodesById[nodeId]
        const snap = ctx.statesByNodeId[nodeId]
        const runState = snap?.runState ?? 'ready'
        const artifacts = ctx.artifactsByNodeId[nodeId] ?? []
        const firstArtifact = artifacts[0]
        return (
          <div key={nodeId} className={`monitor-producer-cell monitor-producer-cell--${RUN_STATE_TONE[runState]}`}>
            <div className="monitor-producer-cell__title">{node?.title ?? nodeId}</div>
            {cellShows.includes('runState') && (
              <div className="monitor-producer-cell__state">{RUN_STATE_LABEL[runState]}</div>
            )}
            {cellShows.includes('awaitingSince') && (
              <div className="monitor-producer-cell__awaiting">
                {snap?.needsOwnerReview ? '待你确认' : runState === 'blocked' ? (snap?.blockers[0] ?? '受阻') : ''}
              </div>
            )}
            {cellShows.includes('artifactPreviewLink') && (
              <div className="monitor-producer-cell__artifact">
                {firstArtifact ? firstArtifact.title : '—'}
              </div>
            )}
          </div>
        )
      })}
    </div>
  )
}
