// Mirror of Swift DTOs in Sources/Board/BoardDTO.swift. Keep in sync.

export type Mode = 'auto' | 'intercept' | 'paused'
export type MessageStatus = 'pending' | 'held' | 'delivered' | 'dropped'

export interface TranscriptEntry {
  role: string // "user" | "assistant" | "tool" | other
  text: string // already truncated server-side (~200 chars)
}

export interface BackgroundAgent {
  id: string          // agentId / taskId
  kind: 'agent' | 'monitor' | 'bash' | string
  description: string | null
  startedAt: string | null  // ISO8601
}

export interface SessionRecap {
  content: string
  timestamp: string | null  // ISO8601
}

export interface UsageStats {
  inputTokens: number
  outputTokens: number
  cacheCreateTokens: number
  cacheReadTokens: number
  turns: number
  model: string
}

export interface Session {
  id: string
  title: string
  project: string
  pluginId: string
  pluginDisplayName: string
  pluginColor: string // "#FF9500"
  status: string
  inboxPending: number
  recentMessages: TranscriptEntry[]
  currentTool: string | null
  /** Optional one-line description of the current step, used as the
   *  fallback caption for the live in-flight tail block when status is
   *  thinking. Mirrors SessionDTO.currentTask on the Swift side. */
  currentTask?: string | null
  // 关于 cost：后端曾经把 Claude CLI 的 usage.costUSD 原样透出，但那个数字
  // 经常不准（不同模型单价 / cache read-write / local OAuth 免费额度都没算进去），
  // 只会误导，已经从 DTO 里移掉。UI 上展示 usageStats.input/output tokens 就好。
  usageStats: UsageStats | null
  // 当前正在后台跑的 Claude Code 子 agent / task，和主 status 是正交维度
  backgroundAgents: BackgroundAgent[]
  // Claude CLI 最近一次 /recap 或 away_summary 产生的内容
  latestRecap: SessionRecap | null
  // 可选诊断/通知字段（SessionDTO 里有，但不是所有代码都需要）
  pendingPermissionTool?: string | null
  pendingPermissionMessage?: string | null
  startedAt?: string | null
  lastActivity?: string | null
  ghosttyTerminalId?: string | null
  tty?: string | null
  termProgram?: string | null
  /** Session 来源：cli (`claude` 终端) / desktop (Claude.app 内置 Code agent)
   *  / cowork (Claude.app local-agent-mode VM session) / null (其他 plugin) */
  clientKind?: ClientKind | null
  /** meee2 Online connected-mode sync metadata. Local board remains primary. */
  syncEnabled: boolean
  syncTeamId: string | null
  syncTeamName: string | null
}

/// "Older" / 折叠显示的判定：lastActivity ≥ 1h 前 → older。
/// 这是纯 webui 的呈现规则 —— 后端不再下发 displayGroup 字段。Sidebar 的
/// "Older" 分组、Board 的"默认不自动建卡片"过滤都用这个 helper。
/// `permissionRequired` 的 session 永远不算 older（阻塞用户响应的弹框就算
/// 挂超 1h 也得让用户能找到）。
export const OLDER_IDLE_MS = 60 * 60 * 1000
export function isOlderSession(s: Pick<Session, 'lastActivity' | 'status'>): boolean {
  if (s.status === 'permissionRequired') return false
  if (!s.lastActivity) return false
  const ts = Date.parse(s.lastActivity)
  if (Number.isNaN(ts)) return false
  return Date.now() - ts >= OLDER_IDLE_MS
}

export type ClientKind = 'cli' | 'desktop' | 'cowork'

export interface Member {
  alias: string
  sessionId: string
}

export interface Channel {
  /// Canonical id — also the on-disk filename / message envelope channel /
  /// member alias scope. Immutable; rename only changes `displayName`.
  name: string
  /// Optional human-friendly label. UI shows this when set, otherwise falls
  /// back to `name`. See issue #24.
  displayName: string | null
  mode: Mode
  members: Member[]
  pendingCount: number
  description: string | null
  createdAt: string // ISO8601
}

export interface Message {
  id: string
  channel: string
  fromAlias: string
  toAlias: string // alias or "*"
  content: string
  replyTo: string | null
  status: MessageStatus
  createdAt: string
  deliveredAt: string | null
  deliveredTo: string[]
  injectedByHuman: boolean
}

export interface MemberDigest {
  sessionId: string
  summary: string
  currentTask: string
  status: string
  blockers: string[]
  lastDecision: string
  lastTranscriptCursor: string
  lastActivity: string | null
}

export interface CoordinationEvent {
  id: string
  groupId: string
  kind: string
  reason: string
  sessionIds: string[]
  contextPreview: string
  createdAt: string
}

export interface CoordinationGroup {
  id: string
  canvasId: string
  coordinatorSessionId: string | null
  pendingSpawnIntentId: string | null
  memberSessionIds: string[]
  mode: 'hybrid' | string
  goal: string
  paused: boolean
  memberDigests: Record<string, MemberDigest>
  events: CoordinationEvent[]
  lastWakeAt: string | null
  lastRoutedAction: string | null
  createdAt: string
  updatedAt: string
}

export interface BoardState {
  sessions: Session[]
  channels: Channel[]
  coordinationGroups: CoordinationGroup[]
}

export type CanvasScope = 'personal' | 'team'
export type SpawnProvider = 'claude' | 'codex'
export type CanvasRelationStylePreset = 'coordination' | 'review' | 'dependency' | 'handoff' | 'group'
export type CanvasShapeKind = 'rectangle' | 'ellipse' | 'diamond'

export interface CanvasInfo {
  id: string
  name: string
  scope: CanvasScope
  isDefault: boolean
  workspacePath: string
  teamId?: string | null
  ownerUserId?: string | null
  remoteId?: string | null
  remoteVersion?: number | null
  syncStatus?: 'pending' | 'synced' | 'conflict' | 'force-pending' | string | null
  dirtySince?: string | null
  lastSyncedAt?: string | null
  lastRemoteUpdatedAt?: string | null
}

export interface CanvasSessionMembership {
  canvasId: string
  sessionId: string
  visible: boolean
  layout?: { x: number; y: number } | null
}

export type CanvasPatchOperation =
  | { type: 'move_session'; sessionId: string; x: number; y: number }
  | { type: 'move_channel'; channelName: string; x: number; y: number }
  | { type: 'show_session'; sessionId: string; x?: number; y?: number }
  | { type: 'hide_session'; sessionId: string }
  | { type: 'add_note'; text: string; x: number; y: number }
  | { type: 'update_note'; elementId: string; text?: string; x?: number; y?: number }
  | {
      type: 'add_frame'
      elementId?: string
      sessionIds?: string[]
      title?: string
      x?: number
      y?: number
      width?: number
      height?: number
      padding?: number
      stylePreset?: CanvasRelationStylePreset
    }
  | {
      type: 'add_connector'
      fromSessionId?: string
      toSessionId?: string
      fromElementId?: string
      toElementId?: string
      label?: string
      direction?: 'forward' | 'backward' | 'none'
      stylePreset?: CanvasRelationStylePreset
    }
  | {
      type: 'add_shape'
      elementId?: string
      shape: CanvasShapeKind
      text?: string
      x: number
      y: number
      width?: number
      height?: number
      stylePreset?: CanvasRelationStylePreset
    }
  | {
      type: 'add_label'
      elementId?: string
      text: string
      x: number
      y: number
      stylePreset?: CanvasRelationStylePreset
    }
  | {
      type: 'update_element'
      elementId: string
      text?: string
      x?: number
      y?: number
      width?: number
      height?: number
      stylePreset?: CanvasRelationStylePreset
    }

export interface CanvasPatchProposal {
  type: 'canvas_patch_proposal'
  canvasId: string
  canvasName?: string
  summary: string
  operations: CanvasPatchOperation[]
  operationCount?: number
  requiresApply?: boolean
}

export interface CanvasPatchRequest {
  proposal: CanvasPatchProposal
  bump: number
}

export interface CanvasList {
  canvases: CanvasInfo[]
  activeCanvasId: string
  defaultCanvasIds: string[]
  memberships: CanvasSessionMembership[]
}

export interface PlanningCanvas {
  id: string
  ownerId: string
  title: string
  plannerContext: string
}

export interface IOSchema {
  consumes: string[]
  produces: string[]
  completionSignal: string
}

export type ContextSourceKind =
  | 'chatHistory'
  | 'repository'
  | 'web'
  | 'document'
  | 'artifact'

export interface ContextSource {
  kind: ContextSourceKind
  title: string
  reference: string
}

export type ExecutionMode = 'auto' | 'sign-off' | 'human'
export type ExecutorType =
  | 'claude'
  | 'codex'
  | 'cursor'
  | 'openClaw'
  | 'devin'
  | 'human'
  | 'mock'
export type PlanningNodeStatus = 'waiting' | 'running' | 'blocked' | 'done' | 'planning'
export type PlanningNodeSource = 'planner' | 'session'
export type PlannerCanvasRole = 'owner' | 'doer' | 'viewer' | 'suggestion'

export interface PlannerAccess {
  actorId: string
  role: PlannerCanvasRole
  canCreateProposal: boolean
  canApproveProposal: boolean
  canApplyProposal: boolean
  canRejectProposal: boolean
  canUpdateAssignedNode: boolean
}

export interface PlannerActivity {
  userId: string
  displayName: string
  currentCanvasId: string
  selectedNodeId?: string | null
  selectedSessionId?: string | null
  lastActiveAt: string
}

export interface PlanningNode {
  id: string
  canvasId: string
  title: string
  ioSchema: IOSchema
  contextSources: ContextSource[]
  executionMode: ExecutionMode
  executorType: ExecutorType
  doerId: string
  status: PlanningNodeStatus
  sessionId?: string | null
  chatThreadId?: string | null
  source?: PlanningNodeSource | null
  dependsOnNodeIds?: string[] | null
  subCanvasId?: string | null
}

export type PlanProposalStatus = 'pending' | 'approved' | 'applied' | 'rejected'
export type PlanChangeKind = 'addNode' | 'updateNode'

export interface PlanChange {
  kind: PlanChangeKind
  node?: PlanningNode | null
  nodeId?: string | null
  title?: string | null
  status?: PlanningNodeStatus | null
  ioSchema?: IOSchema | null
  contextSources?: ContextSource[] | null
  dependsOnNodeIds?: string[] | null
  subCanvasId?: string | null
}

export interface PlanProposal {
  id: string
  canvasId: string
  summary: string
  changes: PlanChange[]
  status: PlanProposalStatus
}

export type NodeRunState = 'waiting' | 'running' | 'blocked' | 'done' | 'planning'

export interface NodeStateSnapshot {
  nodeId: string
  runState: NodeRunState
  blockers: string[]
  artifactRefs: string[]
  needsOwnerReview: boolean
}

export type PlannerMonitorItemKind = 'node' | 'proposal'

export interface PlannerMonitorItem {
  id: string
  kind: PlannerMonitorItemKind
  canvasId: string
  canvasTitle: string
  nodeId?: string | null
  nodeTitle?: string | null
  proposalId?: string | null
  proposalStatus?: PlanProposalStatus | null
  summary: string
  runState?: NodeRunState | null
  blockers: string[]
  needsOwnerReview: boolean
  doerId?: string | null
  riskRank: number
}

export interface PlannerMonitorState {
  generatedAt: string
  items: PlannerMonitorItem[]
}

export interface PlannerCanvasState {
  canvas: PlanningCanvas
  nodes: PlanningNode[]
  states: NodeStateSnapshot[]
  proposals: PlanProposal[]
  access: PlannerAccess
  activities?: PlannerActivity[]
}

export interface SelectedCanvasElementContext {
  id: string
  type: string
  label: string
  textPreview?: string
  sessionId?: string
  channelName?: string
  x: number
  y: number
  width: number
  height: number
}

export interface ApiError {
  error: { code: string; message: string }
}

// Selection state — what's picked on the board.
export type Selection =
  | { kind: 'none' }
  | { kind: 'session'; sessionId: string }
  | { kind: 'channel'; channelName: string }
