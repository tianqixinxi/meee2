import type { GuideSource } from './guide'

export interface BoardTargetGuide {
  enabled?: boolean
  title?: string
  body?: string
  durationMs?: number
  openInspector?: boolean
}

export type BoardOpenTarget =
  | {
    kind: 'canvas'
    canvasId: string
    source?: GuideSource
    guide?: BoardTargetGuide
  }
  | {
    kind: 'planner-node'
    canvasId: string
    nodeId: string
    source?: GuideSource
    guide?: BoardTargetGuide
  }
  | {
    kind: 'planner-artifact'
    canvasId: string
    nodeId: string
    artifactId: string
    source?: GuideSource
    guide?: BoardTargetGuide
  }
  | {
    kind: 'planner-proposal'
    canvasId: string
    proposalId: string
    source?: GuideSource
    guide?: BoardTargetGuide
  }
  | {
    kind: 'planner-delivery'
    canvasId: string
    deliveryId: string
    source?: GuideSource
    guide?: BoardTargetGuide
  }
  | {
    kind: 'session'
    sessionId: string
    source?: GuideSource
  }

export function requestBoardTarget(target: BoardOpenTarget): void {
  if (typeof window === 'undefined') return
  window.dispatchEvent(new CustomEvent<BoardOpenTarget>('meee2:open-board-target', { detail: target }))
}

export function boardTargetFromPlannerItem(detail: {
  canvasId?: string | null
  nodeId?: string | null
  source?: GuideSource
  guide?: BoardTargetGuide
}): BoardOpenTarget | null {
  const canvasId = detail.canvasId?.trim()
  if (!canvasId) return null
  const nodeId = detail.nodeId?.trim()
  if (nodeId) {
    return {
      kind: 'planner-node',
      canvasId,
      nodeId,
      source: detail.source,
      guide: detail.guide,
    }
  }
  return {
    kind: 'canvas',
    canvasId,
    source: detail.source,
    guide: detail.guide,
  }
}
