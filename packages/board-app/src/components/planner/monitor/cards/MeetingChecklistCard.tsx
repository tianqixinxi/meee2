/**
 * MeetingChecklistCard (§6.2) — a pre-meeting readiness checklist: the agenda
 * artifact + the required decision slots, plus downstream blockers.
 *
 * Partial real data: agenda presence + decision-slot fulfilment are inferred
 * from the meeting node's artifacts (matched by slotKey against artifact
 * reference / title). The per-slot "who owes this" attribution and downstream
 * blocker rollup need backend wiring → graceful hint.
 */

import { Check, Circle } from 'lucide-react'
import type { MeetingChecklistConfig } from '../../../../types'
import type { MonitorCardProps } from '../cardTypes'
import { CardPending } from '../CardShell'

function hasArtifactForSlot(
  artifacts: Array<{ title: string; reference: string }>,
  slotKey: string,
): boolean {
  return artifacts.some(
    (a) => a.reference.includes(slotKey) || a.title.includes(slotKey),
  )
}

export function MeetingChecklistCard({ config, ctx }: MonitorCardProps<MeetingChecklistConfig>) {
  const meeting = ctx.nodesById[config.meetingNodeId]
  const artifacts = ctx.artifactsByNodeId[config.meetingNodeId] ?? []
  const agendaReady = hasArtifactForSlot(artifacts, config.agendaArtifactSlot.slotKey ?? 'agenda')

  return (
    <div className="monitor-meeting-checklist">
      <div className="monitor-meeting-checklist__meeting">{meeting?.title ?? config.meetingNodeId}</div>
      <ul className="monitor-meeting-checklist__list">
        <li className={`monitor-checklist-item${agendaReady ? ' monitor-checklist-item--done' : ''}`}>
          {agendaReady ? <Check size={13} aria-hidden /> : <Circle size={13} aria-hidden />}
          <span>议程</span>
        </li>
        {config.decisionSlots.map((slot) => {
          const ready = hasArtifactForSlot(artifacts, slot.slotKey)
          return (
            <li
              key={slot.slotKey}
              className={`monitor-checklist-item${ready ? ' monitor-checklist-item--done' : ''}`}
            >
              {ready ? <Check size={13} aria-hidden /> : <Circle size={13} aria-hidden />}
              <span>{slot.label}</span>
              <span className="monitor-checklist-item__when">
                {(slot.requiredBefore ?? 'meeting-end') === 'meeting-start' ? '会前' : '会中'}
              </span>
            </li>
          )
        })}
      </ul>
      {(config.showDownstreamBlockers ?? true) && (
        <CardPending what="下游阻塞汇总(哪些后续节点在等这次会议拍板)" />
      )}
    </div>
  )
}
