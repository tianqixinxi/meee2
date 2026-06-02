import type { CanvasInfo, CanvasSessionMembership, PlannerGraphState, Session } from '../types'

export interface SessionOpenTarget {
  sessionId?: string
  surfaceId?: string
  canvasId?: string
}

export function sessionMatchesId(session: Session, id: string): boolean {
  const trimmed = id.trim()
  if (!trimmed) return false
  return session.id === trimmed || session.surfaceId === trimmed
}

export function isInternalTerminalSession(session: Session): boolean {
  return session.openTarget === 'native-workspace'
    || session.nativeWorkspaceAvailable === true
    || session.terminalKind === 'internal'
    || Boolean(session.surfaceId)
}

export function isLiveInternalTerminalSession(session: Session): boolean {
  if (!isInternalTerminalSession(session)) return false
  const status = (session.surfaceStatus || session.status || '').toLowerCase()
  return status !== 'exited' && status !== 'failed' && status !== 'dead'
}

export function nativeTerminalTargetForSession(session: Session | null): { sessionId?: string; surfaceId?: string } {
  if (!session || !isLiveInternalTerminalSession(session)) return {}
  return {
    sessionId: session.id,
    surfaceId: session.surfaceId ?? undefined,
  }
}

export function findSessionByTarget(
  sessions: readonly Session[],
  target: SessionOpenTarget | null,
): Session | null {
  const ids = [target?.sessionId, target?.surfaceId]
    .map((id) => id?.trim())
    .filter((id): id is string => Boolean(id))
  if (ids.length === 0) return null
  return sessions.find((session) => ids.some((id) => sessionMatchesId(session, id))) ?? null
}

export function resolveSessionCanvasId(input: {
  target: SessionOpenTarget
  session: Session | null
  memberships: readonly CanvasSessionMembership[]
  canvases: readonly CanvasInfo[]
  activePlannerState: PlannerGraphState | null
  fallbackCanvasId: string
}): string {
  const explicit = input.target.canvasId?.trim()
  if (explicit && input.canvases.some((canvas) => canvas.id === explicit)) return explicit

  const ids = new Set<string>()
  const add = (id: string | null | undefined) => {
    const trimmed = id?.trim()
    if (trimmed) ids.add(trimmed)
  }
  add(input.target.sessionId)
  add(input.target.surfaceId)
  add(input.session?.id)
  add(input.session?.surfaceId)

  const membership = input.memberships.find((item) => ids.has(item.sessionId))
  if (membership && input.canvases.some((canvas) => canvas.id === membership.canvasId)) {
    return membership.canvasId
  }

  const activeCanvas = input.activePlannerState?.canvas
  const boundNode = input.activePlannerState?.nodes.find((node) => {
    const sessionId = node.sessionId?.trim()
    return sessionId ? ids.has(sessionId) : false
  })
  if (boundNode && activeCanvas && input.canvases.some((canvas) => canvas.id === activeCanvas.id)) {
    return activeCanvas.id
  }

  const monitorCanvas = input.canvases.find((canvas) => canvas.kind === 'monitor')
  return monitorCanvas?.id ?? input.fallbackCanvasId
}
