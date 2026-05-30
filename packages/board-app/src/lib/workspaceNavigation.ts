import type { PlannerMonitorItem, Session } from '../types'

export type MonitorItemOpenTarget =
  | { kind: 'canvas'; canvasId: string; nodeId?: string | null }
  | { kind: 'external-session'; sessionId: string }

export type MonitorItemOpenLabel = 'item' | 'canvas' | 'session'
export type MonitorItemSourceKind = 'canvas' | 'node' | 'approval' | 'live'

export function resolveMonitorItemOpenTarget(
  item: PlannerMonitorItem,
  sessions: Session[] | null | undefined,
): MonitorItemOpenTarget {
  const sessionId = item.sessionId?.trim()
  if (sessionId && !isCanvasScopedMonitorItem(item)) {
    const session = sessions?.find((candidate) => (
      candidate.id === sessionId || candidate.surfaceId === sessionId
    ))
    if (session && isExternalMonitorSession(session)) {
      return { kind: 'external-session', sessionId: session.id }
    }
  }
  return {
    kind: 'canvas',
    canvasId: item.canvasId,
    nodeId: item.nodeId?.trim() || null,
  }
}

export function monitorItemOpenLabel(item: PlannerMonitorItem): MonitorItemOpenLabel {
  if (item.kind === 'session') return 'session'
  if (item.nodeId?.trim()) return 'item'
  if (item.deliveryId?.trim() || item.proposalId?.trim()) return 'canvas'
  return item.sessionId?.trim() ? 'session' : 'canvas'
}

export function monitorItemSourceKind(item: PlannerMonitorItem): MonitorItemSourceKind {
  if (item.kind === 'proposal' || item.proposalId?.trim()) {
    return 'approval'
  }
  if (item.kind === 'session') {
    return 'live'
  }
  if (item.kind === 'delivery' || item.deliveryId?.trim()) {
    return 'canvas'
  }
  if (item.kind === 'node' || item.nodeId?.trim()) {
    return 'node'
  }
  if (item.needsOwnerReview) {
    return 'approval'
  }
  return item.sessionId?.trim() ? 'live' : 'canvas'
}

export function isCanvasScopedMonitorItem(item: PlannerMonitorItem): boolean {
  if (item.kind === 'session') return false
  return Boolean(
    item.nodeId?.trim()
      || item.deliveryId?.trim()
      || item.proposalId?.trim(),
  )
}

export function isExternalMonitorSession(
  session: Pick<Session, 'terminalKind' | 'surfaceId' | 'canOpenExternal'>,
): boolean {
  return session.terminalKind !== 'internal'
    && !session.surfaceId?.trim()
    && session.canOpenExternal !== false
}
