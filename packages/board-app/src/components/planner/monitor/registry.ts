/**
 * Monitor card registry (§6.7) — maps `MonitorCardKind` → its renderer.
 *
 * `MonitorGrid` looks each card up here and falls through to
 * `UnknownCardFallback` for any kind this build doesn't know (newer planner).
 *
 * Each entry is typed against its own config via a per-kind component, but the
 * registry is stored as a loosely-typed map because the value types differ per
 * key. `MonitorGrid` re-narrows through the discriminated `card.type` before
 * rendering, so the loose map never leaks an untyped config to a card body.
 */

import type { ComponentType } from 'react'
import type { MonitorCardKind } from '../../../types'
import type { MonitorCardProps } from './cardTypes'

import { PeriodSelectorCard } from './cards/PeriodSelectorCard'
import { ProducerStatusGridCard } from './cards/ProducerStatusGridCard'
import { MeetingChecklistCard } from './cards/MeetingChecklistCard'
import { QueueDepthCard } from './cards/QueueDepthCard'
import { SnapshotTimelineCard } from './cards/SnapshotTimelineCard'
import { DownstreamDrillCard } from './cards/DownstreamDrillCard'
import { ContinuousBacklogCard } from './cards/ContinuousBacklogCard'
import { IntegrationHealthCard } from './cards/IntegrationHealthCard'
import { CadenceReminderChip } from './cards/CadenceReminderChip'

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type AnyCardComponent = ComponentType<MonitorCardProps<any>>

export const MONITOR_CARD_REGISTRY: Record<MonitorCardKind, AnyCardComponent> = {
  // 7 original core ledger cards
  'period-selector': PeriodSelectorCard,
  'producer-status-grid': ProducerStatusGridCard,
  'meeting-checklist': MeetingChecklistCard,
  'queue-depth': QueueDepthCard,
  'snapshot-timeline': SnapshotTimelineCard,
  'downstream-drill': DownstreamDrillCard,
  'continuous-backlog': ContinuousBacklogCard,
  // new core ledger card (addendum §5)
  'integration-health': IntegrationHealthCard,
  // PM-addon (gated in MonitorGrid by CANVAS_PM_ADDON)
  'cadence-reminder': CadenceReminderChip,
}

/** Card kinds that only render when the optional PM addon is enabled. */
export const PM_ADDON_CARD_KINDS: ReadonlySet<MonitorCardKind> = new Set(['cadence-reminder'])
