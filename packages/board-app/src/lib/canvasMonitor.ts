import { useMemo } from 'react'
import {
  buildCanvasMonitor,
  type CanvasMonitor,
  type CanvasMonitorInput,
} from '@meee1/recap-core'
import type { BoardState, PlannerCanvasState } from '../types'

export function buildCanvasMonitorInput(input: {
  plannerState: PlannerCanvasState | null | undefined
  boardState: BoardState | null | undefined
  now?: string
}): CanvasMonitorInput | null {
  const plannerState = input.plannerState
  if (!plannerState) return null
  return {
    now: input.now ?? new Date().toISOString(),
    canvas: {
      id: plannerState.canvas.id,
      title: plannerState.canvas.title,
    },
    nodes: plannerState.nodes.map((node) => ({
      id: node.id,
      canvasId: node.canvasId,
      title: node.title,
      status: node.status,
      workflowRunState: node.workflowRunState ?? null,
      blockedReason: node.blockedReason ?? null,
      nextAction: node.nextAction ?? null,
      sessionId: node.sessionId ?? null,
    })),
    nodeStates: plannerState.states.map((state) => ({
      nodeId: state.nodeId,
      blockers: state.blockers,
      needsOwnerReview: state.needsOwnerReview,
    })),
    sessions: (input.boardState?.sessions ?? []).map((session) => ({
      id: session.id,
      title: session.title,
      status: session.status,
      inboxPending: session.inboxPending,
      currentTask: session.currentTask ?? null,
      pendingPermissionTool: session.pendingPermissionTool ?? null,
      pendingPermissionMessage: session.pendingPermissionMessage ?? null,
      recentMessages: session.recentMessages ?? [],
      lastActivity: session.lastActivity ?? null,
    })),
  }
}

export function useCanvasMonitor(input: {
  plannerState: PlannerCanvasState | null | undefined
  boardState: BoardState | null | undefined
}): CanvasMonitor | null {
  return useMemo(() => {
    const monitorInput = buildCanvasMonitorInput(input)
    return monitorInput ? buildCanvasMonitor(monitorInput) : null
  }, [input.plannerState, input.boardState])
}

export function monitorItemsByNodeId(monitor: CanvasMonitor | null | undefined) {
  return new Map((monitor?.items ?? []).map((item) => [item.nodeId, item]))
}
