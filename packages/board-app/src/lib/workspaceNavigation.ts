import type { PlannerMonitorItem } from '../types'

export type MonitorItemOpenTarget =
  | { kind: 'node'; canvasId: string; nodeId: string }
  | { kind: 'proposal'; canvasId: string; proposalId: string }
  | { kind: 'delivery'; canvasId: string; deliveryId: string }
  | { kind: 'canvas'; canvasId: string }

export type MonitorItemOpenLabel = 'item' | 'canvas' | 'session'
export type MonitorItemSourceKind = 'canvas' | 'node' | 'approval' | 'live'

export function resolveMonitorItemOpenTarget(
  item: PlannerMonitorItem,
): MonitorItemOpenTarget {
  const nodeId = item.nodeId?.trim()
  if (nodeId) {
    return { kind: 'node', canvasId: item.canvasId, nodeId }
  }
  const proposalId = item.proposalId?.trim()
  if (proposalId) {
    return { kind: 'proposal', canvasId: item.canvasId, proposalId }
  }
  const deliveryId = item.deliveryId?.trim()
  if (deliveryId) {
    return { kind: 'delivery', canvasId: item.canvasId, deliveryId }
  }
  return {
    kind: 'canvas',
    canvasId: item.canvasId,
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
