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

export interface Meee2MCPStatus {
  configured: boolean
  configCommand: string | null
  configArgs: string[]
  expectedServerPath: string
  serverPath: string | null
  serverExists: boolean
  nodeAvailable: boolean
  launches: boolean
  tools: string[]
  missingRequiredTools: string[]
  error: string | null
  checkedAt: string
}

export interface AgentRuntimeComponentStatus {
  available: boolean
  cliAvailable: boolean
  appAvailable: boolean
  cliPath: string | null
  appPath: string | null
  installed: boolean
  configured: boolean
  detail: string | null
  command: string | null
}

export interface Meee2AgentRuntimeStatus {
  marketplacePath: string
  pluginPath: string
  mcpServerPath: string
  stagedMCPServerPath: string | null
  claude: AgentRuntimeComponentStatus
  codex: AgentRuntimeComponentStatus
  needsAttention: boolean
  checkedAt: string
}

export interface Meee2AgentRuntimeInstallResult {
  ok: boolean
  target: 'claude' | 'codex' | 'all' | string
  messages: string[]
  logs: string[]
  status: Meee2AgentRuntimeStatus
}

export type ReadinessStatus = 'pass' | 'fail' | 'warn' | 'info'
export type ReadinessSeverity = 'required' | 'recommended' | 'informational'
export type ReadinessOverallStatus = 'ready' | 'needsSetup' | 'broken'

export interface ReadinessAction {
  id: string
  label: string
  kind: string
  command: string | null
}

export interface ReadinessCheck {
  id: string
  title: string
  status: ReadinessStatus
  severity: ReadinessSeverity
  detail: string
  recoveryAction: ReadinessAction | null
  metadata: Record<string, string>
}

export interface ReadinessReport {
  overall: ReadinessOverallStatus
  ready: boolean
  requiredFailed: number
  checks: ReadinessCheck[]
  checkedAt: string
}

export interface ReadinessRepairResult {
  ok: boolean
  actionId: string
  messages: string[]
  logs: string[]
  report: ReadinessReport
}

export interface SessionIntakeDiagnosticItem {
  id: string
  severity: 'info' | 'warn' | 'error' | string
  title: string
  detail: string
  sessionId: string | null
  recoveryAction: string | null
}

export interface SessionIntakeDiagnostics {
  ok: boolean
  liveSessions: number
  storedSessions: number
  historicalSessions: number
  items: SessionIntakeDiagnosticItem[]
  checkedAt: string
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
  terminalKind?: 'internal' | 'external' | string
  surfaceId?: string | null
  surfaceStatus?: 'starting' | 'running' | 'exited' | 'failed' | string | null
  canOpenExternal?: boolean
  controlState?: 'active' | 'hidden' | 'archived' | string
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
export type CanvasKind = 'board' | 'monitor' | 'template'
export type SpawnProvider = 'claude' | 'codex'
export type CanvasRelationStylePreset = 'coordination' | 'review' | 'dependency' | 'handoff' | 'group'
export type CanvasShapeKind = 'rectangle' | 'ellipse' | 'diamond'

export interface CanvasInfo {
  id: string
  name: string
  scope: CanvasScope
  kind?: CanvasKind
  isDefault: boolean
  workspacePath: string
  parentCanvasId?: string | null
  parentNodeId?: string | null
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

/** Who can see a planning canvas. Mirrors Swift `PlannerCanvasVisibility`. */
export type PlannerCanvasVisibility = 'public' | 'private'

export interface PlanningCanvas {
  id: string
  ownerId: string
  title: string
  plannerContext: string
  /** Visibility tier for the canvas. */
  visibility?: PlannerCanvasVisibility
  /** ENG-4: parent canvas if this canvas is a sub-canvas (`null` for top-level). */
  parentCanvasId?: string | null
  /** ENG-4: id of the parent canvas's node that owns this sub-canvas. */
  parentNodeId?: string | null
  /** ENG-4: frozen Node Contract v2 snapshot, written at assign time. */
  frozenIOContract?: NodeContractV2 | null
}

export interface NodeSchema {
  inputs: string[]
  outputs: string[]
  goal: string
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

export type ExecutionMode = 'auto' | 'human'
export type ExecutorType =
  | 'claude'
  | 'codex'
  | 'cursor'
  | 'openClaw'
  | 'devin'
  | 'human'
  | 'mock'
// 3-tai cut (2026-05-29): collapsed to `ready / blocked / done`.
// - `draft` removed — ready is the initial state. Legacy data decodes via the
//   Swift normalizer; UI maps any in-memory `'draft'` to `'ready'` at render.
// - `working` removed (state-machine PR-A 2026-05-28) — runtime in-flight
//   state lives on NodeAttempt, not on the node status.
export type PlanningNodeStatus = 'ready' | 'blocked' | 'done'
export type PlanningNodeSource = 'planner' | 'session'
export type PlanningNodeKind = 'step' | 'session' | 'artifact' | 'subCanvas' | 'external'
export type PlannerCanvasRole = 'owner' | 'doer' | 'viewer' | 'suggestion'
export type PlannerWorkflowRunState = 'pending' | 'ready_to_start' | 'dispatched' | 'running' | 'awaiting-input' | 'gate-wait' | 'done' | 'failed'
export type PlannerDispatchRunner = 'claude' | 'codex' | 'byoa-local' | 'ci-agent' | 'human'
export type PlannerArtifactKind =
  | 'idea-draft'
  | 'kanban'
  | 'prd'
  | 'impl-pr'
  | 'prerelease-verdict'
  | 'main-merge'
  | 'lark-doc'
  | 'check-result'
  | 'generic'

export interface PlannerNodeLayout {
  x: number
  y: number
  width?: number | null
  height?: number | null
}

export interface PlannerNodeTrigger {
  type: string
  label: string
  eventSource?: string | null
}

export interface PlannerNodeSchedule {
  enabled: boolean
  intervalSeconds: number
  prompt: string
  lastSentAt?: string | number | null
  nextRunAt?: string | number | null
}

export interface PlannerNodeGate {
  type: string
  label: string
  requiredArtifactRefs: string[]
  approvers: string[]
  onFailGotoNodeId?: string | null
}

export interface PlannerNodeDispatch {
  runner: PlannerDispatchRunner
  skill?: string | null
  actor: string
  command?: string | null
  fallbackRunner?: PlannerDispatchRunner | null
}

/**
 * Artifact 在剪贴板里的位置标签(UI-simplification §3.C).
 * 跟 status (freeform string) 互补:status 描述「这份成果完成度」,
 * positionTag 描述「这份成果在 inspector 剪贴板里的角色」。
 */
export type ArtifactPositionTag =
  | 'latest'      // 默认引用的那份(主推)
  | 'candidate'   // 同节点的其他版本
  | 'discarded'   // 不再考虑但留档
  | 'promoted'    // 已被提升为独立画板节点(原 kanban item 等)
  | 'proposed'    // agent 提议要提升,等 owner 批

/**
 * Artifact payload discriminated union(UI-simplification §3.E).
 * 替代原来的 `payload: unknown`:用 type tag 区分,每种 payload 自带强类型字段。
 *
 * 现有 PlannerArtifactPayloadType('text'|'html'|'kanban'|'integration'|'json'|'file')
 * 是「技术形态」分类;ArtifactPayload 是「语义形态」分类。两者并存:旧的
 * payload(写到 PlannerArtifactContent.payload)保留兼容;新写入走 typed
 * ArtifactPayload。Consumers 优先看 ArtifactPayload,缺失则 fallback 到旧 payload。
 */
export type ArtifactPayload =
  | { type: 'prd';          tldr: string; sections: Array<{ heading: string; lines: number }> }
  | { type: 'kanban';       columns: Array<{ name: string; items: string[] }> }
  | { type: 'impl-pr';      number: number; branch: string; baseBranch: string;
                            filesChanged: number; insertions: number; deletions: number;
                            ciStatus: 'pass' | 'fail' | 'running';
                            reviewers: string[] }
  | { type: 'check-result'; pass: number; fail: number; skip: number;
                            failing: string[] }
  | { type: 'file';         filename: string; mime: string; sizeBytes: number;
                            lines?: number | null }
  | { type: 'markdown';     preview: string }
  | { type: 'integration';  connector: string;   // 'notion' / 'slack' / 'linear' / ...
                            externalId: string; externalUrl?: string | null;
                            summary?: string | null }

export type ArtifactPayloadType = ArtifactPayload['type']

export interface PlannerArtifact {
  id: string
  canvasId: string
  nodeId: string
  kind: PlannerArtifactKind
  title: string
  reference: string
  status: string
  createdAt: string
  /** Legacy free-form payload(`PlannerArtifactPayloadType` 系统),保留向后兼容。新写入用 `typedPayload`。 */
  payload?: unknown
  /** UI-simplification §3.E: 强类型 payload。Consumer 优先用这个,缺失则 fallback `payload`. */
  typedPayload?: ArtifactPayload | null
  /** UI-simplification §3.C: position tag for clipboard model. Defaults to 'latest' if missing. */
  positionTag?: ArtifactPositionTag
}

export type PlannerArtifactPayloadType = 'text' | 'html' | 'kanban' | 'integration' | 'json' | 'file'

export interface PlannerArtifactContent {
  artifactId: string
  type: PlannerArtifactPayloadType | string
  mimeType: string
  filename?: string | null
  size?: number | null
  sha256?: string | null
  blobRef?: string | null
  content?: string | null
  payload?: unknown
}

// ENG-3 · Artifact version chain — every submit_node_output appends a new
// version row keyed by (canvasId, nodeId, normalized reference). The desktop
// exposes these through `/api/planner/canvases/:id/nodes/:nodeId/artifact-versions`
// and `/api/planner/canvases/:id/artifact-versions/:versionId`. UI-1 consumes
// them for the version dropdown.
export type PlannerArtifactDisplayStrategy = 'latest' | 'merged_view'
export type PlannerArtifactVersionSubmitterKind = 'agent' | 'human' | 'system' | 'integration'

export interface PlannerArtifactInputSnapshot {
  upstream_artifact_ref?: string | null
  external_outputs?: unknown[]
  dialogue_window?: unknown
}

export interface PlannerArtifactVersion {
  version_id: string
  parent_version_id?: string | null
  canvas_id: string
  node_id: string
  artifact_id: string
  artifact_slot_key: string
  payload_ref: string
  payload_inline?: unknown
  input_snapshot?: PlannerArtifactInputSnapshot | null
  display_strategy: PlannerArtifactDisplayStrategy
  force_new_version: boolean
  submitted_by?: string | null
  submitted_by_kind: PlannerArtifactVersionSubmitterKind
  metadata?: unknown
  created_at: string
}

export interface KanbanArtifactPayload {
  version: 1
  columns: Array<{ id: string; title: string }>
  items: Array<{
    id: string
    columnId: string
    title: string
    description?: string
    subCanvasId?: string | null
  }>
}

export interface PlannerGraphEdge {
  id: string
  sourceNodeId: string
  targetNodeId: string
  kind: string
}

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

export type PlannerEventType =
  | 'node.created'
  | 'node.updated'
  | 'node.state_changed'
  | 'node.output_submitted'
  | 'proposal.created'
  | 'proposal.approved'
  | 'proposal.applied'
  | 'proposal.rejected'
  | 'artifact.attached'

export interface PlannerEvent {
  id: string
  canvasId: string
  type: PlannerEventType
  nodeId?: string | null
  proposalId?: string | null
  summary: string
  artifactRefs: string[]
  createdAt: string
}

export type PlannerNodeOutputStatus = 'done' | 'blocked' | 'needs_review'
export type PlannerNodeOutputNext = 'complete' | 'blocked' | 'needs_owner_review'

export interface PlannerNodeOutputMessage {
  summary: string
  routeTo: string[]
}

export interface PlannerNodeOutputArtifact {
  kind: PlannerArtifactKind
  title: string
  reference: string
  payload?: unknown
  routeTo: string[]
}

export interface PlannerNodeOutput {
  nodeId: string
  status: PlannerNodeOutputStatus
  message?: PlannerNodeOutputMessage | null
  artifacts: PlannerNodeOutputArtifact[]
  next: PlannerNodeOutputNext
}

export interface PlannerRouteTarget {
  id: string
  label: string
  kind: string
  hasDoer: boolean
  hasSession: boolean
}

export interface PlannerNodeContract {
  canvas: PlanningCanvas
  node: PlanningNode
  upstreamNodes: PlanningNode[]
  downstreamNodes: PlanningNode[]
  allowedRouteTargets: PlannerRouteTarget[]
  expectedArtifactKinds: PlannerArtifactKind[]
  inlinePayloadLimitBytes?: number
  artifactPayloadTypes?: PlannerArtifactPayloadType[]
  completionCriteria: string[]
  /**
   * Node Contract v2 (ENG-1). Three-source input合流 +
   * cardinality/payload_kind output. Embedded alongside the v1 envelope so
   * downstream consumers can migrate incrementally; the runtime always
   * populates this for new contracts.
   */
  v2: NodeContractV2
}

/* ---------- Node Contract v2 (ENG-1) ---------- */

export type NodeContractUpstreamMode = 'passthrough' | 'item_scoped'

export interface NodeContractUpstreamInput {
  mode: NodeContractUpstreamMode
  /** Source node id; `null` means canvas root entry. */
  source_node: string | null
}

export interface NodeContractExternalInput {
  connector: string
  ref: string
  sync_session: string | null
}

export type NodeContractDialogueWindowKind = 'rolling'

export interface NodeContractDialogueWindow {
  kind: NodeContractDialogueWindowKind
  n_turns: number
}

export interface NodeContractDialogueInput {
  enabled: boolean
  window: NodeContractDialogueWindow
}

export interface NodeContractInput {
  upstream: NodeContractUpstreamInput
  external: NodeContractExternalInput[]
  dialogue: NodeContractDialogueInput
}

export type NodeContractCardinality = 'single' | 'list'
export type NodeContractPayloadKind = 'artifact_ref' | 'inline'

export interface NodeContractExternalWriteTarget {
  connector: string
  ref: string
}

export interface NodeContractOutput {
  cardinality: NodeContractCardinality
  payload_kind: NodeContractPayloadKind
  external_write_target?: NodeContractExternalWriteTarget | null
}

export interface NodeContractV2 {
  /** Contract schema version. Always `2` for the v2 shape. */
  version: number
  input: NodeContractInput
  output: NodeContractOutput
}

/* ---------- Node Contract v2 · external input source (chunk I) ----------
 *
 * Distinct from `NodeContractExternalInput` above which is the post-fetch
 * *snapshot* shape stored on a node version. The discriminated union below
 * is the *proposal-level* declaration of an external input source — its
 * Zod twin lives in `meee2-online/src/planner-runtime/contract/proposal.ts`
 * (`NodeContractExternalInput`). Swift twin: `NodeContractExternalInputSource`
 * in PlannerCore.swift. PRD: `doc/prd/integration.md` §5.
 */
export type NodeContractExternalInputSyncPolicy = 'poll' | 'webhook' | 'manual'

export interface NodeContractExternalInputSourceURL {
  kind: 'url'
  url: string
  refreshSeconds?: number
}

export interface NodeContractExternalInputSourceIntegration {
  kind: 'integration'
  /** Matches `IntegrationViewSchema.integrationId`. */
  integrationId: string
  /** Matches `IntegrationViewSchema.entityKind`. */
  entityKind: string
  /** Integration-specific stable reference (e.g. `owner/repo#123`). */
  entityRef: string
  /** Defaults to `'poll'` server-side. */
  syncPolicy: NodeContractExternalInputSyncPolicy
  /** Defaults to `60` server-side. */
  pollSeconds: number
}

export type NodeContractExternalInputSource =
  | NodeContractExternalInputSourceURL
  | NodeContractExternalInputSourceIntegration

/* ---------- Integration view-schema (chunk I) ----------
 *
 * Zod twin: `meee2-online/src/planner-runtime/contract/integration-view.ts`.
 * Swift twin: `IntegrationViewSchema` in PlannerCore.swift.
 * Per-(integration, entityKind) literals: `src/integrations/viewSchemas/`.
 */
export type IntegrationBadgeStatus = 'todo' | 'running' | 'awaiting' | 'blocked' | 'done'
export type IntegrationPreviewDetailKind = 'text' | 'link' | 'code' | 'diff' | 'image'
export type IntegrationAffordanceKind = 'link' | 'mcp_call' | 'shell' | 'copy'

export interface IntegrationBadge {
  title: string
  secondary?: string
  status: IntegrationBadgeStatus
  icon: string
  accentColor?: string
}

export interface IntegrationPreviewDetail {
  label: string
  value: string
  kind: IntegrationPreviewDetailKind
}

export interface IntegrationPreview {
  summary: string
  details: IntegrationPreviewDetail[]
  sourceUrl?: string
  lastSyncedAt?: string
}

export interface IntegrationAffordance {
  id: string
  label: string
  kind: IntegrationAffordanceKind
  payload: unknown
}

export interface IntegrationViewSchema {
  integrationId: string
  entityKind: string
  badge: IntegrationBadge
  preview: IntegrationPreview
  affordances: IntegrationAffordance[]
}

/**
 * A concrete external entity rendered on a canvas (chunk I v0.1).
 *
 * `schemaId` follows the `<integrationId>:<entityKind>` convention used by
 * `getViewSchema()`. `payload` is integration-specific — the renderer reads
 * it through the matching view-schema to extract title / status / preview
 * details. v0.1 the canvas just consumes the badge for placement; richer
 * preview rendering comes in a later wave.
 */
export interface IntegrationEntity {
  schemaId: string
  payload: unknown
}

export interface PlannerOutputRoute {
  target: string
  targetNodeId?: string | null
  targetSessionId?: string | null
  routedMessage?: string | null
  artifactRefs: string[]
}

export interface PlannerNodeOutputResult {
  graph: PlannerGraphState
  routes: PlannerOutputRoute[]
  hint?: string | null
}

/**
 * Team-ready handoff policy (release-plan-qc #5 chunk B). Mirror of Zod
 * `HandoffPolicy` in meee2-online/src/planner-runtime/contract/proposal.ts.
 */
export type HandoffPolicy =
  | 'none'
  | 'reviewer-must-approve'
  | 'any-approver'
  | 'all-approvers'

/**
 * Node-level widget (2026-05-28 心智修正).
 *
 * Twin of Zod `meee2-online/src/planner-runtime/contract/widget.ts`.
 * Absence on PlanningNode = default `standard` view (title + assignee + run
 * state). Presence = render as the declared kind, backed by `source` (with
 * optional `mapping` overrides on top of integration view-schema defaults).
 */
export type WidgetKind = 'kanban' | 'inbox' | 'matrix' | 'badge' | 'artifact-preview'
export type WidgetSourceKind = 'external' | 'upstream' | 'subcanvas-aggregate'
export interface WidgetSource {
  inputKind: WidgetSourceKind
  inputIndex: number
  /** Only used when `inputKind === 'subcanvas-aggregate'`. */
  subcanvasIds?: string[]
}
export interface WidgetMapping {
  statusField?: string
  titleField?: string
  subtitleField?: string
  sortField?: string
  rowGroupField?: string
  colGroupField?: string
}
export interface Widget {
  kind: WidgetKind
  source?: WidgetSource
  mapping?: WidgetMapping
}

export interface PlanningNode {
  id: string
  canvasId: string
  title: string
  /** 1-2 line description shown on the canvas node card under the title.
   *  Optional; UI hides the line when empty. UI-simplification §2.6/§3.1. */
  desc?: string | null
  schema: NodeSchema
  contextSources: ContextSource[]
  executionMode: ExecutionMode
  executorType: ExecutorType
  doerId: string
  /** Team-ready (#5): reviewer user ids. Default `[]`. See `handoffPolicy`. */
  reviewerIds: string[]
  /** Team-ready (#5): approver user ids. Default `[]`. See `handoffPolicy`. */
  approverIds: string[]
  /** Team-ready (#5): how reviewer/approver signals gate hand-off. Default `'none'`. */
  handoffPolicy: HandoffPolicy
  status: PlanningNodeStatus
  sessionId?: string | null
  chatThreadId?: string | null
  source?: PlanningNodeSource | null
  dependsOnNodeIds?: string[] | null
  subCanvasId?: string | null
  nodeKind?: PlanningNodeKind | null
  layout?: PlannerNodeLayout | null
  trigger?: PlannerNodeTrigger | null
  schedule?: PlannerNodeSchedule | null
  gate?: PlannerNodeGate | null
  dispatch?: PlannerNodeDispatch | null
  approvers?: string[] | null
  artifactRefs?: string[] | null
  eventRefs?: string[] | null
  workflowRunState?: PlannerWorkflowRunState | null
  blockedReason?: string | null
  /**
   * Derived workflow-guidance line ("what to do next"), computed server-side
   * from `workflowRunState` + node context. Encode-only / read-only — never
   * persisted, never set by the LLM or the adapter. May be absent for nodes
   * with no actionable workflow state.
   */
  nextAction?: string | null
  /**
   * Node-level view widget (2026-05-28). Absent = standard view (title +
   * assignee + run state). Present = render as kanban / inbox / matrix /
   * badge / artifact-preview backed by widget.source. See `Widget` above.
   */
  widget?: Widget | null
}

export type PlanProposalStatus = 'pending' | 'approved' | 'applied' | 'rejected'
export type PlanChangeKind = 'addNode' | 'updateNode' | 'attachArtifact'

export interface PlanArtifactDraft {
  nodeId?: string | null
  kind: PlannerArtifactKind
  title: string
  reference: string
  status?: string | null
  payload?: unknown
}

export interface PlanChange {
  kind: PlanChangeKind
  node?: PlanningNode | null
  nodeId?: string | null
  title?: string | null
  /** UI-simplification §3.1: proposals can attach a new 1-2 line desc to a node. */
  desc?: string | null
  status?: PlanningNodeStatus | null
  schema?: NodeSchema | null
  contextSources?: ContextSource[] | null
  dependsOnNodeIds?: string[] | null
  subCanvasId?: string | null
  nodeKind?: PlanningNodeKind | null
  layout?: PlannerNodeLayout | null
  trigger?: PlannerNodeTrigger | null
  schedule?: PlannerNodeSchedule | null
  executionMode?: ExecutionMode | null
  clearGate?: boolean | null
  gate?: PlannerNodeGate | null
  dispatch?: PlannerNodeDispatch | null
  approvers?: string[] | null
  artifactRefs?: string[] | null
  eventRefs?: string[] | null
  workflowRunState?: PlannerWorkflowRunState | null
  sessionId?: string | null
  chatThreadId?: string | null
  source?: PlanningNodeSource | null
  /**
   * Reassigns a node's doer. Used by the assign-doer UI (Gap 6) to produce a
   * lightweight `updateNode` proposal that touches only `doerId`.
   */
  doerId?: string | null
  /** Team-ready (#5): proposal-driven update of `PlanningNode.reviewerIds`. */
  reviewerIds?: string[] | null
  /** Team-ready (#5): proposal-driven update of `PlanningNode.approverIds`. */
  approverIds?: string[] | null
  /** Team-ready (#5): proposal-driven update of `PlanningNode.handoffPolicy`. */
  handoffPolicy?: HandoffPolicy | null
  /** Node-widget (2026-05-28): proposal-driven update of `PlanningNode.widget`. */
  widget?: Widget | null
  artifact?: PlanArtifactDraft | null
}

export interface PlanProposal {
  id: string
  canvasId: string
  summary: string
  changes: PlanChange[]
  status: PlanProposalStatus
}

export type NodeRunState = 'draft' | 'ready' | 'working' | 'blocked' | 'done'

export interface NodeStateSnapshot {
  nodeId: string
  runState: NodeRunState
  blockers: string[]
  artifactRefs: string[]
  needsOwnerReview: boolean
}

export type PlannerMonitorItemKind = 'node' | 'proposal' | 'delivery'

export interface PlannerMonitorItem {
  id: string
  kind: PlannerMonitorItemKind
  canvasId: string
  canvasTitle: string
  nodeId?: string | null
  nodeTitle?: string | null
  deliveryId?: string | null
  proposalId?: string | null
  proposalStatus?: PlanProposalStatus | null
  summary: string
  runState?: NodeRunState | null
  blockers: string[]
  needsOwnerReview: boolean
  doerId?: string | null
  riskRank: number
  evidenceCount?: number
  /**
   * Derived workflow-guidance line for `node`-kind items (Phase 6). Absent
   * for proposal items or nodes with no actionable workflow state.
   */
  nextAction?: string | null
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
  events?: PlannerEvent[]
  artifacts?: PlannerArtifact[]
  edges?: PlannerGraphEdge[]
  /**
   * UI-2: Active assignments rooted in this canvas. Each row collapses the
   * matching node to a sub-canvas ref chip in `PlannerGraph`.
   */
  nodeAssignments?: NodeAssignment[]
  /**
   * UI-2: Whether the calling user can mutate this canvas's internals
   * (mirror of `meee2_can_edit_canvas_internals(canvas_id)`). Used to gate
   * edit affordances on the parent canvas after the owner reassigned a node
   * (the owner keeps SELECT but loses UPDATE on the sub-canvas; ENG-4 RLS
   * is authoritative — this flag only suppresses the UI affordance).
   */
  canEditInternals?: boolean
}

export type PlannerGraphState = PlannerCanvasState & {
  artifacts: PlannerArtifact[]
  edges: PlannerGraphEdge[]
  /**
   * Integration entity pool (P3.0). Backend provides entities for nodes that
   * have a widget with `source.inputKind === 'external'`. Widget resolver
   * filters by node-specific binding (v0.1: all nodes share the same pool).
   * v0.1 backend mocks 5 GitHub PRs; phase 3 swaps to real fetch.
   */
  integrationEntities?: IntegrationEntity[]
}

// -- P1/P3: Workflow Run layer --------------------------------------------

export type WorkflowRunStatus = 'active' | 'completed' | 'failed' | 'aborted'

/** What the user should do next for a node within a run (WorkflowRunEngine). */
export type RunNextAction =
  | 'waiting-on-upstream'
  | 'ready-to-dispatch'
  | 'in-progress'
  | 'gate-review'
  | 'confirm-artifacts'
  | 'needs-attention'

export interface NodeAttempt {
  index: number
  sessionId?: string | null
  runState: PlannerWorkflowRunState
  startedAt: string
  finishedAt?: string | null
  outcome?: string | null
}

export interface RunNodeState {
  nodeId: string
  runState: PlannerWorkflowRunState
  attempts: NodeAttempt[]
  sessionId?: string | null
  chatThreadId?: string | null
  assigneeId?: string | null
  artifactIds: string[]
  outputRefs: string[]
  startedAt?: string | null
  finishedAt?: string | null
  nextAction?: RunNextAction | null
}

export interface WorkflowRun {
  id: string
  canvasId: string
  runIndex: number
  title: string
  summary?: string | null
  responsibleUserId?: string | null
  linkedArtifactRefs: string[]
  updatedAt: string
  status: WorkflowRunStatus
  trigger: string
  startedAt: string
  finishedAt?: string | null
  nodeStates: Record<string, RunNodeState>
  events: PlannerEvent[]
}

// -- Phase 5: Integrations (真接入) ----------------------------------------

/** Provider id for an integration browse endpoint (GitHub PRs / Lark docs). */
export type IntegrationId = 'github' | 'lark'

/** A selectable external item (GitHub repo/PR/issue, Lark doc, ...). */
export interface ExternalItem {
  /** Stable identifier, e.g. "owner/repo#42". */
  id: string
  title: string
  subtitle?: string | null
  /** The value written into the artifact's reference field (usually a URL). */
  reference: string
  /** Backend-suggested PlannerArtifactKind; the user may override it. */
  suggestedArtifactKind: PlannerArtifactKind
}

/** Envelope returned by the integration browsing endpoints. */
export interface ExternalItemsResult {
  provider: string
  items: ExternalItem[]
  /** Set when data degraded (upstream unreachable / not wired); else null. */
  notice?: string | null
}

// -- agent-integration-detection (检测 + runbook + 节点副作用) --------------

export type IntegrationConnState = 'connected' | 'partial' | 'missing' | 'needs_auth'

/** Structured install spec per integration. Frontend picks the primary
 *  action(Install / Set up / disabled)from `kind`. */
export type IntegrationInstall =
  | { kind: 'claudePlugin'; marketplace: string; name: string }
  | { kind: 'remoteHttp'; url: string }
  | { kind: 'localStdio'; command: string; args: string[]; envKeys: string[] }
  | { kind: 'unsupported'; reason: string }

/** One (agent, integration) cell of the detection matrix. */
export interface AgentIntegrationStatus {
  agent: string
  integrationId: string
  integrationName: string
  category: string
  state: IntegrationConnState
  mcpConfigured: boolean
  credentialPresent: boolean
  via: string[]
  evidence: string
  install: IntegrationInstall
}

/** Result of `POST /api/integrations/:id/install` (Pattern A one-click). */
export interface IntegrationInstallResult {
  integrationId: string
  claudeOK: boolean
  codexOK: boolean
  messages: string[]
}

export interface AgentScanResult {
  agents: string[]
  statuses: AgentIntegrationStatus[]
}

/** A node side-effect crossed with the detection matrix. */
export interface NodeSideEffectCoverage {
  integrationId: string
  direction: string // 'reads' | 'writes'
  connected: boolean
}

export interface NodeSideEffectInfo {
  nodeId: string
  title: string
  sideEffects: NodeSideEffectCoverage[]
}

export interface CanvasSideEffectsResult {
  canvasId: string
  nodes: NodeSideEffectInfo[]
}

export interface IntegrationRunbookResult {
  integrationId: string
  path: string
  content: string
  /** agent id → shell command that drives that agent through the runbook. */
  dispatch: Record<string, string>
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

/**
 * UI-2: Active assignment of a node to a person. When present, the node card
 * collapses to a sub-canvas reference chip; the source node is no longer
 * editable in-place by the parent canvas owner (ENG-4 RLS enforces this on
 * the server). One active row per (sourceCanvasId, sourceNodeId).
 */
export interface NodeAssignment {
  sourceCanvasId: string
  sourceNodeId: string
  assigneeUserId: string
  subCanvasId: string
  subCanvasName: string
  /** Snapshot of the parent node's I/O contract — what the assignee owes back. */
  frozenIOContract: NodeContractV2 | null
  /** Billing team that pays for sub-canvas work (inherits from the parent). */
  billingTeamId: string
  /** Server-side count of session links re-bound to the new sub-canvas. */
  sessionCountRebound?: number | null
  assignedAt?: string | null
}

/** UI-2: Result of a successful assign call, mirrored from the ENG-4 event payload. */
export interface AssignPlannerNodeResult {
  assignment: NodeAssignment
  /**
   * Whether the source canvas was upgraded from `private` to `public` as part
   * of this assign. UI-2 surfaces a different success toast when this happens.
   */
  visibilityUpgraded: boolean
  graph: PlannerGraphState
}

/** UI-2: One sub-canvas the calling user owns (from `meee2_list_owned_canvases`). */
export interface OwnedCanvasSummary {
  id: string
  teamId: string
  name: string
  parentCanvasId: string | null
  parentNodeId: string | null
  frozenIOContract: NodeContractV2 | null
  updatedAt: string | null
}

// Selection state — what's picked on the board.
export type Selection =
  | { kind: 'none' }
  | { kind: 'session'; sessionId: string }
  | { kind: 'channel'; channelName: string }
