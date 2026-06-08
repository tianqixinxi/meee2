export type MonitorReasonKind =
  | 'permission_required'
  | 'waiting_for_user'
  | 'inbox_pending'
  | 'gate_wait'
  | 'awaiting_input'
  | 'blocked'
  | 'failed'
  | 'normal'

export type MonitorSeverity = 'critical' | 'attention' | 'normal'

export interface CanvasMonitor {
  canvasId: string
  generatedAt: string
  items: CanvasNodeMonitorItem[]
  counts: {
    needsHumanReply: number
    blocked: number
    failed: number
    running: number
  }
}

export interface CanvasNodeMonitorItem {
  id: string
  canvasId: string
  nodeId: string
  nodeTitle: string
  sessionId?: string | null
  needsHumanReply: boolean
  reasonKind: MonitorReasonKind
  replyPrompt?: string | null
  pendingTool?: string | null
  nextAction?: string | null
  blockers: string[]
  severity: MonitorSeverity
  updatedAt?: string | null
}

export interface CanvasMonitorInput {
  now: string
  canvas: {
    id: string
    title?: string | null
  }
  nodes: CanvasMonitorNodeInput[]
  nodeStates?: CanvasMonitorNodeStateInput[]
  sessions?: CanvasMonitorSessionInput[]
}

export interface CanvasMonitorNodeInput {
  id: string
  canvasId?: string | null
  title: string
  status?: string | null
  workflowRunState?: string | null
  blockedReason?: string | null
  nextAction?: string | null
  sessionId?: string | null
}

export interface CanvasMonitorNodeStateInput {
  nodeId: string
  blockers?: string[] | null
  needsOwnerReview?: boolean | null
}

export interface CanvasMonitorSessionInput {
  id: string
  title?: string | null
  status?: string | null
  inboxPending?: number | null
  currentTask?: string | null
  pendingPermissionTool?: string | null
  pendingPermissionMessage?: string | null
  recentMessages?: Array<{ role: string; text: string }>
  lastActivity?: string | null
}

export function buildCanvasMonitor(input: CanvasMonitorInput): CanvasMonitor {
  const nodeStateByNodeId = new Map((input.nodeStates ?? []).map((state) => [state.nodeId, state]))
  const sessions = input.sessions ?? []
  const items = input.nodes
    .map((node): CanvasNodeMonitorItem => {
      const nodeState = nodeStateByNodeId.get(node.id)
      const session = findSessionForNode(sessions, node.sessionId)
      return buildNodeMonitorItem(input.canvas.id, input.now, node, nodeState, session)
    })

  return {
    canvasId: input.canvas.id,
    generatedAt: input.now,
    items,
    counts: {
      needsHumanReply: items.filter((item) => item.needsHumanReply).length,
      blocked: items.filter((item) => item.reasonKind === 'blocked').length,
      failed: items.filter((item) => item.reasonKind === 'failed').length,
      running: input.nodes.filter((node) =>
        node.status === 'working'
        || node.workflowRunState === 'running'
        || node.workflowRunState === 'dispatched',
      ).length,
    },
  }
}

function buildNodeMonitorItem(
  canvasId: string,
  now: string,
  node: CanvasMonitorNodeInput,
  nodeState: CanvasMonitorNodeStateInput | undefined,
  session: CanvasMonitorSessionInput | undefined,
): CanvasNodeMonitorItem {
  const blockers = uniqueStrings([
    ...(nodeState?.blockers ?? []),
    node.blockedReason ?? '',
  ])
  const status = session?.status ?? ''
  const inboxPending = Math.max(0, session?.inboxPending ?? 0)
  const pendingTool = clean(session?.pendingPermissionTool)
  const permissionMessage = clean(session?.pendingPermissionMessage)
  const assistantTail = latestAssistantMessage(session)
  const nodeNextAction = clean(node.nextAction)
  const blockerText = blockers[0] ?? null
  const replyFallback = permissionMessage ?? pendingTool ?? assistantTail ?? nodeNextAction ?? blockerText

  const reasonKind = resolveReasonKind({ node, session, status, inboxPending, pendingTool, blockers })
  const needsHumanReply = reasonKind === 'permission_required'
    || reasonKind === 'waiting_for_user'
    || reasonKind === 'inbox_pending'
    || reasonKind === 'gate_wait'
    || reasonKind === 'awaiting_input'
  const severity: MonitorSeverity = needsHumanReply
    ? 'critical'
    : reasonKind === 'blocked' || reasonKind === 'failed'
      ? 'attention'
      : 'normal'

  return {
    id: `node-${node.id}`,
    canvasId: node.canvasId ?? canvasId,
    nodeId: node.id,
    nodeTitle: node.title,
    sessionId: session?.id ?? clean(node.sessionId),
    needsHumanReply,
    reasonKind,
    replyPrompt: needsHumanReply ? replyFallback : null,
    pendingTool,
    nextAction: nodeNextAction,
    blockers,
    severity,
    updatedAt: session?.lastActivity ?? now,
  }
}

function resolveReasonKind(input: {
  node: CanvasMonitorNodeInput
  session: CanvasMonitorSessionInput | undefined
  status: string
  inboxPending: number
  pendingTool: string | null
  blockers: string[]
}): MonitorReasonKind {
  const normalizedStatus = input.status.toLowerCase()
  const workflowRunState = input.node.workflowRunState ?? ''
  if (nodeIsComplete(input.node)) return 'normal'
  if (normalizedStatus === 'permissionrequired' || input.pendingTool) return 'permission_required'
  if (normalizedStatus === 'waitingforuser') return 'waiting_for_user'
  if (input.inboxPending > 0) return 'inbox_pending'
  if (workflowRunState === 'gate-wait') return 'gate_wait'
  if (workflowRunState === 'awaiting-input') return 'awaiting_input'
  if (input.node.status === 'blocked' || input.blockers.length > 0) return 'blocked'
  if (workflowRunState === 'failed' || normalizedStatus === 'failed' || normalizedStatus === 'dead') return 'failed'
  return 'normal'
}

function nodeIsComplete(node: CanvasMonitorNodeInput): boolean {
  return node.workflowRunState === 'done' || node.status === 'done'
}

function findSessionForNode(
  sessions: CanvasMonitorSessionInput[],
  nodeSessionId: string | null | undefined,
): CanvasMonitorSessionInput | undefined {
  const boundId = clean(nodeSessionId)
  if (!boundId) return undefined
  return sessions.find((session) => sessionMatchesBoundId(session.id, boundId))
}

function sessionMatchesBoundId(liveId: string, boundId: string): boolean {
  return liveId === boundId
    || liveId.endsWith(`-${boundId}`)
    || boundId.endsWith(`-${liveId}`)
}

function latestAssistantMessage(session: CanvasMonitorSessionInput | undefined): string | null {
  const messages = session?.recentMessages ?? []
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index]
    if (message.role === 'user') continue
    const text = clean(message.text)
    if (text) return text
  }
  return clean(session?.currentTask)
}

function uniqueStrings(values: Array<string | null | undefined>): string[] {
  return [...new Set(values.map((value) => clean(value)).filter((value): value is string => Boolean(value)))]
}

function clean(value: string | null | undefined): string | null {
  const trimmed = value?.trim() ?? ''
  return trimmed.length > 0 ? trimmed : null
}
