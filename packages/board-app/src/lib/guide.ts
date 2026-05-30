export type GuideSource = 'island' | 'monitor' | 'palette' | 'system'

export interface PlannerNodeSelectionDetail {
  canvasId?: string
  nodeId?: string
  artifactId?: string
  guide?: boolean
  source?: GuideSource
  title?: string
  body?: string
  durationMs?: number
  openInspector?: boolean
}

export type BoardGuideTarget =
  | {
    kind: 'selector'
    selector: string
    title?: string
    body?: string
    durationMs?: number
    source?: GuideSource
  }
  | {
    kind: 'rect'
    rect: { x: number; y: number; width: number; height: number }
    title?: string
    body?: string
    durationMs?: number
    source?: GuideSource
  }
  | {
    kind: 'planner-node'
    canvasId?: string
    nodeId: string
    title?: string
    body?: string
    durationMs?: number
    source?: GuideSource
    openInspector?: boolean
  }

declare global {
  interface Window {
    __meee2PendingPlannerNodeSelection?: PlannerNodeSelectionDetail | null
  }
}

export function requestPlannerNodeSelection(detail: PlannerNodeSelectionDetail): void {
  if (typeof window === 'undefined' || !detail.nodeId) return
  window.__meee2PendingPlannerNodeSelection = detail
  window.dispatchEvent(new CustomEvent<PlannerNodeSelectionDetail>('meee2:select-node', { detail }))
}

export function requestBoardGuide(target: BoardGuideTarget): void {
  if (typeof window === 'undefined') return
  window.dispatchEvent(new CustomEvent<BoardGuideTarget>('meee2:guide-target', { detail: target }))
}

export function cssEscape(value: string): string {
  const escape = globalThis.CSS?.escape
  if (escape) return escape(value)
  return value.replace(/["\\]/g, '\\$&')
}
