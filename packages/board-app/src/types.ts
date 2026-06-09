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

export interface BoardPerfMetric {
  id: string
  title: string
  category: string
  count: number
  totalMs: number
  averageMs: number | null
  p50Ms: number | null
  p95Ms: number | null
  maxMs: number | null
  totalBytes: number
  lastDetail: string | null
  lastAt: string | null
}

export interface BoardPerfEvent {
  id: string
  metricId: string
  title: string
  category: string
  durationMs: number | null
  bytes: number | null
  detail: string | null
  at: string
}

export interface BoardPerfSnapshot {
  enabled: boolean
  pid: number
  startedAt: string
  capturedAt: string
  metrics: BoardPerfMetric[]
  recentEvents: BoardPerfEvent[]
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
  providerResumeSessionId?: string | null
  surfaceStatus?: 'starting' | 'running' | 'exited' | 'failed' | string | null
  canOpenExternal?: boolean
  terminalBackend?: 'ghostty-surface' | 'external' | string
  nativeWorkspaceAvailable?: boolean
  openTarget?: 'native-workspace' | 'external' | 'web-fallback' | string
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
export type CanvasKind = 'board' | 'monitor'
export type SpawnProvider = 'claude' | 'codex'
export type CanvasRelationStylePreset = 'coordination' | 'review' | 'dependency' | 'handoff' | 'group'
export type CanvasShapeKind = 'rectangle' | 'ellipse' | 'diamond'

export interface CanvasInfo {
  id: string
  name: string
  scope: CanvasScope
  visibility?: 'private' | 'public'
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
  conflictRemoteVersion?: number | null
  conflictRemoteDeleted?: boolean | null
  draftOfTemplateId?: string | null
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

export type CanvasSceneKind = 'travel-squad' | 'poker-table' | string

export interface CanvasSceneArtifactBinding {
  id: string
  nodeId: string
  reference: string
  mode?: 'merge' | 'replace' | string
}

export interface CanvasSceneNodeAnchor {
  id: string
  label: string
  nodeId: string
  x: number
  y: number
  role?: string | null
}

export interface CanvasSceneAction {
  id: string
  label: string
  nodeId: string
  prompt?: string | null
}

export interface CanvasSceneOrchestration {
  kind: 'poker-rules-v1' | string
  stateNodeId?: string | null
  stateReference?: string | null
  logReference?: string | null
}

export interface CanvasSceneSpec {
  kind: CanvasSceneKind
  assets?: Record<string, unknown>
  initialState?: unknown
  artifactBindings?: CanvasSceneArtifactBinding[]
  nodeAnchors?: CanvasSceneNodeAnchor[]
  actions?: CanvasSceneAction[]
  orchestration?: CanvasSceneOrchestration | null
}

export type CanvasRenderLayoutKind = 'spatial' | 'graph' | 'collection'
export type CanvasRenderRendererId =
  | 'card'
  | 'document'
  | 'avatar'
  | 'container'
  | 'asset'
  | 'label'
  | 'list'
  | 'kanban'
  | 'matrix'
  | 'grid'
  | 'directed-edge'
  | 'group-boundary'
export type CanvasRenderActionId = 'openInspector' | 'openSession' | 'showVersions' | 'runSceneAction' | 'revealProfile'
export type CanvasObjectEntityKind = 'node' | 'artifact' | 'session' | 'dataSource' | 'subCanvas' | 'integrationEntity'
export type CanvasRenderOnlyKind = 'background' | 'region' | 'container' | 'label' | 'asset'
export type CanvasRelationKind = 'dependency' | 'dataflow' | 'membership' | 'projection' | 'spatial-link' | 'grouping'

export interface CanvasObjectEntityRef {
  kind: CanvasObjectEntityKind
  id: string
  nodeId?: string | null
  reference?: string | null
}

export interface CanvasRenderOnlyObject {
  kind: CanvasRenderOnlyKind
  id: string
}

export interface CanvasObjectRule {
  id: string
  entityKind?: CanvasObjectEntityKind | null
  renderOnlyKind?: CanvasRenderOnlyKind | null
  renderer: CanvasRenderRendererId
}

export interface CanvasRendererRule {
  id: string
  renderer: CanvasRenderRendererId
  entityKind?: CanvasObjectEntityKind | null
  renderOnlyKind?: CanvasRenderOnlyKind | null
  variant?: string | null
  density?: string | null
}

export interface CanvasRelationRule {
  id: string
  kind: CanvasRelationKind
  renderer: CanvasRenderRendererId
  visible: boolean
}

export interface CanvasRenderActionRule {
  id: string
  action: CanvasRenderActionId
  label?: string | null
  targetObjectId?: string | null
  sceneActionId?: string | null
}

export interface CanvasRenderLogic {
  layout: CanvasRenderLayoutKind
  objectRules: CanvasObjectRule[]
  relationRules: CanvasRelationRule[]
  rendererRules: CanvasRendererRule[]
  actions: CanvasRenderActionRule[]
}

export interface CanvasRenderObjectValues {
  x?: number | null
  y?: number | null
  width?: number | null
  height?: number | null
  zIndex?: number | null
  hidden?: boolean | null
  collapsed?: boolean | null
  pinned?: boolean | null
  rendererVariant?: string | null
  density?: string | null
  icon?: string | null
  designToken?: string | null
}

export interface CanvasRenderRelationValues {
  visible?: boolean | null
  label?: string | null
  routeStyle?: string | null
}

export interface CanvasObject {
  id: string
  label: string
  entityRef?: CanvasObjectEntityRef | null
  renderOnly?: CanvasRenderOnlyObject | null
  renderer: CanvasRenderRendererId
  values?: CanvasRenderObjectValues | null
  metadata?: unknown
}

export interface CanvasRenderValues {
  objects: Record<string, CanvasRenderObjectValues>
  relations: Record<string, CanvasRenderRelationValues>
  renderOnlyObjects: CanvasObject[]
}

export interface CanvasRenderProfile {
  version: 1
  logic: CanvasRenderLogic
  values: CanvasRenderValues
}

export interface CanvasRenderProfileStatus {
  state: 'valid' | 'missing-migrated' | 'invalid-using-last-valid'
  path: string
  error?: string | null
  updatedAt?: string | null
}

export interface CanvasRelationEndpoint {
  objectId: string
}

export interface CanvasRelation {
  id: string
  kind: CanvasRelationKind
  source: CanvasRelationEndpoint
  target: CanvasRelationEndpoint
  renderer: CanvasRenderRendererId
  values?: CanvasRenderRelationValues | null
  metadata?: unknown
}

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
  /**
   * Canvas runtime 5-atom model (canvas-runtime-data-model.md). Store-owned,
   * decode-tolerant — absent on legacy canvases. Surfaced by the Swift
   * PlannerGraphStateEnvelope.canvas once a proposal creates it. Drives the
   * MonitorGrid.
   */
  monitorSpec?: MonitorSpec | null
  /**
   * Atom 1 — named addressable storage locations on this canvas. Rendered as a
   * read-only "数据源" rail on the canvas. Absent / `[]` on legacy canvases.
   * Twin of Zod contract/datasource.ts `DataSource` (only the fields we render
   * are mirrored). */
  dataSources?: DataSourceRecord[]
  /**
   * Canvas-level presentation layer for scene templates. It is not a node
   * widget: scene state starts from the template and is advanced by artifacts
   * produced by executable nodes.
   */
  sceneSpec?: CanvasSceneSpec | null
  /**
   * Atom 2 — first-class consumption edges. AUTHORITATIVE: includes both real
   * mode edges (queue-claim / document-snapshot) AND synthetic
   * `edgeMode.mode === "dependency"` edges (id prefix `dep-`) mirroring node
   * dependencies. Twin of Zod contract/edge.ts `Edge` (rendered fields only).
   * Named `CanvasEdge` to avoid clashing with the legacy projected
   * `PlannerGraphEdge` / ReactFlow `Edge`. */
  edges?: CanvasEdge[]
}

/**
 * Twin of Zod contract/datasource.ts `DataSource` — only the fields the canvas
 * rail renders are mirrored. `partitionRule` is an open-ish enum; we accept the
 * known set plus `string` forward-compat. */
export type DataSourcePartitionRule =
  | 'none'
  | 'iso-week'
  | 'day'
  | 'month'
  | 'fiscal-quarter'
  | 'custom'

export interface DataSourceRecord {
  id: string
  title: string
  kind: string
  partitionRule?: DataSourcePartitionRule | string
  partitionTimezone?: string
  currentVersion: number
  // Canvas runtime addendum (Part A/G) —— 已随 `canvas.dataSources` 一起发到前端,
  // 这里把类型补齐让 UI 能读真实身份/选择器/语义,而不是只靠旧的 title/kind。
  identity?: { connectorKind: string; realm: string }
  selector?: {
    mode: 'declarative' | 'curated'
    dialect?: string
    expr?: string
    /** curated:AI 梳理的聚合意图。 */
    intent?: string
  }
  semantics?: { label: string; purpose?: string }
}

/**
 * Twin of Zod contract/edge.ts `Edge`. Earlier this only mirrored the
 * edge-mode-badging subset; the step-IO inspector needs the named slot keys
 * (`sourceKey → inputKey`), the optional `dataSourceId` (when the source is a
 * DataSource rather than a node), and the EdgeMode strategy (to label timing).
 */
export interface CanvasEdge {
  id: string
  sourceRef: { nodeId: string; sourceKey?: string; dataSourceId?: string }
  targetRef: { nodeId: string; inputKey?: string; dataSourceId?: string }
  edgeMode: {
    mode: 'queue-claim' | 'document-snapshot' | 'dependency' | string
    /** document-snapshot: `follow-latest` | `pin-at-attempt-start`. */
    strategy?: { kind?: string; resolveAt?: string }
    /** queue-claim: `fifo` | `lifo` | `priority`. */
    ordering?: string
  }
}

export interface NodeSchema {
  inputs: string[]
  outputs: string[]
  goal: string
  /**
   * Part C —— 每个输入/输出槽对数据源的子视图(投影 + 语义)。key = 槽名。
   * `project` = 投影出的字段子集;`semantics` = 这个槽给人/agent 看的语义。
   */
  subViews?: Record<string, { semantics: { label: string; purpose?: string }; project?: string[] }>
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
 * theta (2026-05-29) — Artifact review status.
 * Mirrors Zod `ArtifactReviewStatus`.
 *  pending  — agent submitted, owner has not yet promoted (UI shows badge + Promote)
 *  approved — owner-promoted, or auto-approved for snapshot-style payloads
 *  rejected — owner rejected; downstream consumers should fall back
 * Absence ≡ 'approved' for back-compat with legacy artifacts.
 */
export type ArtifactReviewStatus = 'pending' | 'approved' | 'rejected'

/**
 * Artifact payload discriminated union(UI-simplification §3.E).
 * 替代原来的 `payload: unknown`:用 type tag 区分,每种 payload 自带强类型字段。
 *
 * 现有 PlannerArtifactPayloadType('text'|'html'|'kanban'|'integration'|'json'|'file')
 * 是「技术形态」分类;ArtifactPayload 是「语义形态」分类。两者并存:旧的
 * payload(写到 PlannerArtifactContent.payload)保留兼容;新写入走 typed
 * ArtifactPayload。Consumers 优先看 ArtifactPayload,缺失则 fallback 到旧 payload。
 */
/**
 * theta (2026-05-29) — common fields applied to every ArtifactPayload variant.
 * Hoisted to a single intersect so future common gates (review / visibility /
 * lock) only need to extend this one type.
 */
type ArtifactPayloadCommon = {
  /**
   * Review gate; absence ≡ 'approved'. Mirrors Zod `ArtifactReviewStatus`.
   * widgetDataResolver prefers `approved` payloads; pending payloads show
   * a "Promote" affordance in the inspector before being treated as
   * canonical by downstream consumers.
   */
  reviewStatus?: ArtifactReviewStatus
}

export type ArtifactPayload =
  | (ArtifactPayloadCommon & { type: 'prd';          tldr: string; sections: Array<{ heading: string; lines: number }> })
  | (ArtifactPayloadCommon & { type: 'kanban';       columns: Array<{ name: string; items: string[] }> })
  | (ArtifactPayloadCommon & { type: 'impl-pr';      number: number; branch: string; baseBranch: string;
                                                     filesChanged: number; insertions: number; deletions: number;
                                                     ciStatus: 'pass' | 'fail' | 'running';
                                                     reviewers: string[] })
  | (ArtifactPayloadCommon & { type: 'check-result'; pass: number; fail: number; skip: number;
                                                     failing: string[] })
  | (ArtifactPayloadCommon & { type: 'file';         filename: string; mime: string; sizeBytes: number;
                                                     lines?: number | null })
  | (ArtifactPayloadCommon & { type: 'json';         rootKind: 'object' | 'array' | 'value'; preview: string;
                                                     entries: Array<{ key: string; value: string }> })
  | (ArtifactPayloadCommon & { type: 'markdown';     preview: string })
  | (ArtifactPayloadCommon & { type: 'integration';  connector: string;   // 'notion' / 'slack' / 'linear' / 'google-sheets' / ...
                                                     externalId: string; externalUrl?: string | null;
                                                     summary?: string | null;
                                                     /** 扁平明细(如 sheet 的 tab/rows/columns)。view-schema preview
                                                      *  的 detail 行按 label 从这里取值 — integration 层只带 schema+view
                                                      *  需要的元数据,不带行级真实数据。 */
                                                     fields?: Record<string, string | number> | null })

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
  /**
   * theta (2026-05-29): review gate on the typed payload. Absence ≡ 'approved'.
   * widgetDataResolver prefers `approved` artifacts; InspectorArtifactBody
   * shows a pending badge + Promote button when this is 'pending'.
   */
  reviewStatus?: ArtifactReviewStatus
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
    /** slice 3 — 订阅下游消费源(queue-claim): 绑定一个 managed 队列项,其消费态
     *  (ready/claimed/in-progress/done)派生成列。与 subCanvasId 二选一。 */
    consumptionSourceId?: string | null
    consumptionItemId?: string | null
    /** 派生态(slice 2/3 后端读时注入,不落库): item 绑定状态源(下钻 subcanvas 或
     *  下游消费)时 = 回卷的 §6 列(not_started/in_progress/needs_response/blocked/done)。
     *  缺省 = 用手动 columnId。前端摆放优先用它,并渲染派生态徽章。 */
    derivedColumnId?: string | null
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
export type WidgetKind = 'kanban' | 'inbox' | 'matrix' | 'badge' | 'artifact-preview' | 'html'
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
  /**
   * canvas-spec §7.2 — only meaningful when `kind === 'html'` (a Monitor:
   * Artifact{source:canvas-runtime, widget:html}). Planner-authored HTML string
   * rendered SAFELY in a sandboxed iframe (MonitorHtmlFrame) with the read-only
   * CanvasRuntimeView injected via postMessage. Ignored for other kinds.
   */
  html?: string
}

/** One upstream whose head version is newer than what this node consumed. */
export interface StaleUpstream {
  nodeId: string
  title: string
  /** versionIndex of the upstream version this node actually ran on. */
  consumedVersion: number
  /** versionIndex of the upstream's current head (done) version. */
  latestVersion: number
}

/**
 * Derived (read-only) upstream-staleness signal — see PlanningNode.upstreamFreshness.
 */
export interface UpstreamFreshness {
  state: 'fresh' | 'stale'
  staleUpstreams: StaleUpstream[]
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
   * Derived upstream-staleness signal, computed server-side at read time from
   * the append-only `nodeVersions` log. Encode-only / read-only — never
   * persisted. `state: 'stale'` means an upstream this node already consumed has
   * since produced a newer (done) version; `staleUpstreams` lists which, with
   * the consumed vs latest version index. Absent on nodes with no upstream or
   * that never ran.
   */
  upstreamFreshness?: UpstreamFreshness | null
  /**
   * Node-level view widget (2026-05-28). Absent = standard view (title +
   * assignee + run state). Present = render as kanban / inbox / matrix /
   * badge / artifact-preview backed by widget.source. See `Widget` above.
   */
  widget?: Widget | null
  /**
   * Unified `Artifact.source` (canvas-spec §7 — artifact-unified-model). The
   * canonical data origin, written server-side. Folds the legacy two-mode
   * `artifactConfig.dataSource` (authored | mirrored) into one shape:
   *   - `slot`           a node input/output slot (authored seed = output)
   *   - `dataSource`     a managed/integration DataSource (legacy `mirrored`)
   *   - `canvas-runtime` whole-canvas runtime snapshot (Monitor)
   * Absent on legacy data — readers fall back to the loose
   * `artifactDataSource` / `artifactConfig.dataSource` lookup.
   */
  artifactSource?: ArtifactSource | null
}

/** Unified artifact data origin (canvas-spec §7). Mirrors the Zod + Swift twins. */
export type ArtifactSource =
  | { kind: 'slot'; nodeId: string; slotKey: string; direction: 'input' | 'output' }
  | { kind: 'dataSource'; sourceId: string }
  | { kind: 'canvas-runtime' }

export type PlanProposalStatus = 'pending' | 'approved' | 'applied' | 'rejected'
export type PlanChangeKind = 'addNode' | 'updateNode' | 'attachArtifact'

export interface PlanArtifactDraft {
  nodeId?: string | null
  kind: PlannerArtifactKind
  title: string
  reference: string
  status?: string | null
  payload?: unknown
  /**
   * theta (2026-05-29): optional review-status hint. When set, apply-path
   * stamps it on the resulting PlannerArtifact.reviewStatus. Lets the Promote
   * button flip review state without re-shipping payload (which would clobber
   * original content when typedPayload is absent on the wire envelope).
   */
  reviewStatus?: ArtifactReviewStatus | null
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

export type PlannerMonitorItemKind = 'node' | 'proposal' | 'delivery' | 'session'

export interface PlannerMonitorItem {
  id: string
  kind: PlannerMonitorItemKind
  canvasId: string
  canvasTitle: string
  nodeId?: string | null
  nodeTitle?: string | null
  sessionId?: string | null
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
  updatedAt?: string | null
  /**
   * Derived workflow-guidance line for `node`-kind items (Phase 6). Absent
   * for proposal items or nodes with no actionable workflow state.
   */
  nextAction?: string | null
  /**
   * Wall-clock timestamp of the active run's live attempt entry into
   * `awaiting-input` / `gate-wait`. Surfaced by the monitor so the sort
   * function can boost stale-awaiting items (24h+ +100, 72h+ +500) and the
   * UI can render duration labels. Absent on non-awaiting items.
   */
  awaitingInputSince?: string | null
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

// -- canvas-spec §7.2: CanvasRuntimeView (Monitor read-only snapshot) ---------
//
// The read-only whole-canvas runtime snapshot a Monitor (Artifact{source:
// canvas-runtime, widget:html}) consumes. Surfaced additively on
// PlannerGraphState.canvasRuntime; the board injects it into the sandboxed
// monitor iframe via postMessage. Twin: meee2-online contract/canvas-runtime-view.ts
// + Swift CanvasRuntimeView.swift.

export interface CanvasRuntimeNode {
  id: string
  title: string
  status: string
  workflowRunState?: string | null
  doerId: string
  awaitingInputSince?: string | null
}
export interface CanvasRuntimeAttempt {
  nodeId: string
  index: number
  originKind?: string | null
  runState: string
  startedAt?: string | null
  finishedAt?: string | null
}
export interface CanvasRuntimeArtifact {
  nodeId: string
  reference: string
  title: string
  versionIndex?: number | null
  versionCount?: number | null
  positionTag?: string | null
}
export interface CanvasRuntimeEdge {
  sourceRef: string
  targetRef: string
  mode: string
}
export interface CanvasRuntimeDataSource {
  id: string
  title: string
  partitionRule: string
  currentVersion: number
  queueReadyDepth?: number | null
}
export interface CanvasRuntimeView {
  canvasId: string
  generatedAt: string
  nodes: CanvasRuntimeNode[]
  attempts: CanvasRuntimeAttempt[]
  artifacts: CanvasRuntimeArtifact[]
  edges: CanvasRuntimeEdge[]
  dataSources: CanvasRuntimeDataSource[]
}

export type PlannerGraphState = PlannerCanvasState & {
  artifacts: PlannerArtifact[]
  edges: PlannerGraphEdge[]
  renderProfile?: CanvasRenderProfile | null
  renderProfileStatus?: CanvasRenderProfileStatus | null
  renderObjects?: CanvasObject[]
  renderRelations?: CanvasRelation[]
  /**
   * canvas-spec §7.2 — read-only whole-canvas runtime snapshot consumed by a
   * Monitor html widget. Additive; absent on legacy backends.
   */
  canvasRuntime?: CanvasRuntimeView | null
  /**
   * Integration entity pool (P3.0). Backend provides entities for nodes that
   * have a widget with `source.inputKind === 'external'`. Widget resolver
   * filters by node-specific binding (v0.1: all nodes share the same pool).
   * Real integration entities are derived from artifacts attached by AI sessions.
   * Widget resolver filters by node-specific binding; see integrations/artifactEntity.ts.
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
  /**
   * Wall-clock timestamp of the most recent transition into `awaiting-input`
   * / `gate-wait`. Nil while running / dispatched / done. UI uses this to
   * render "等了 X 小时" durations and the monitor uses it to boost stale
   * awaiting items in the sort lane.
   */
  awaitingInputSince?: string | null
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
   * Legacy compatibility field. Team Mode now requires the parent to already
   * be a Team Canvas; assign no longer creates a distinct team-private state.
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

// ===========================================================================
// Atom 4 — MonitorSpec + Card Registry (canvas-runtime-data-model.md §6).
//
// Mirror of the Zod schemas at
//   meee2-online/src/planner-runtime/contract/monitor.ts
//   meee2-online/src/planner-runtime/contract/monitor-cards.ts
// (contract version 3). board-app keeps its own structural twin rather than
// importing from meee2-online — same convention as `Widget` / `PlanningNode`
// above. Keep field names byte-identical to the Zod source so the wire shape
// decodes without a translation layer. These types are read-only renderer
// inputs; all *edits* to a MonitorSpec go through the proposal pipeline
// (governance), never direct mutation — see §6.5.
// ===========================================================================

/** §6.1 — which trigger origins a card surfaces. `hidden` keeps auto-attempts
 *  in the audit log while removing them from the owner's grid. */
export type AttemptVisibility = 'all' | 'human-only' | 'auto-only' | 'hidden'

/** §6.1 — render-time projection: filter rows against the viewer's identity. */
export type ViewerFilter =
  | { kind: 'none' }
  | { kind: 'assignee-is-viewer' }
  | { kind: 'owner-is-viewer' }
  | { kind: 'field-equals-viewer'; fieldPath: string }

/** §6.1 — points a card at a node's DataSource (+ optional slot). The 5-atom
 *  data model's universal "where does this card read from" reference. */
export interface DataSourceRef {
  nodeId: string
  slotKey?: string
}

/** §6.1 — 12-col grid placement. `collapsed` defaults to false; the live
 *  collapsed state is local UI (localStorage), this is only the default. */
export interface CardLayout {
  col: number
  row: number
  width: number
  height: number
  collapsed?: boolean
}

/** §6.1 + addendum §5 — discriminator for the card registry. 8 core ledger
 *  cards (the 7 original + `integration-health`) plus the PM-addon
 *  `cadence-reminder`. Unknown values from a newer planner fall through to
 *  UnknownCardFallback — never crash. */
export type MonitorCardKind =
  | 'period-selector'
  | 'producer-status-grid'
  | 'meeting-checklist'
  | 'queue-depth'
  | 'snapshot-timeline'
  | 'downstream-drill'
  | 'continuous-backlog'
  | 'integration-health'
  // PM-addon (Principle 15) — renderable only when the canvas PM addon is on.
  | 'cadence-reminder'

// -- §6.2 card config shapes -------------------------------------------------

export interface PeriodSelectorConfig {
  source: DataSourceRef
  defaultPeriod?: string
  visibleCount?: number
  controlsCardIds?: string[]
}

export type ProducerCellShow = 'runState' | 'awaitingSince' | 'artifactPreviewLink'

export interface ProducerStatusGridConfig {
  producerNodeIds: string[]
  periodSource?: DataSourceRef
  columnCount?: number
  cellShows?: ProducerCellShow[]
}

export interface MeetingChecklistDecisionSlot {
  slotKey: string
  label: string
  requiredBefore?: 'meeting-start' | 'meeting-end'
}

export interface MeetingChecklistConfig {
  meetingNodeId: string
  agendaArtifactSlot: DataSourceRef
  decisionSlots: MeetingChecklistDecisionSlot[]
  showDownstreamBlockers?: boolean
}

export type QueueDepthBinding =
  | { kind: 'edge'; upstreamNodeId: string; downstreamNodeId: string }
  | { kind: 'source'; source: DataSourceRef }

export interface QueueDepthConfig {
  binding: QueueDepthBinding
  thresholds?: { warnAt: number; blockAt: number }
  showClaimedByBreakdown?: boolean
}

export interface SnapshotTimelineConfig {
  source: DataSourceRef
  visibleVersionCount?: number
  pinnedVersionIds?: string[]
  showDiffPreview?: boolean
}

export interface DownstreamDrillConfig {
  parentNodeId: string
  stalenessMinutes?: number
  showRolledUpStatus?: boolean
}

export type CadenceExpectation =
  | { kind: 'every-period' }
  | { kind: 'every-n-days'; n: number }
  | { kind: 'before-date'; isoDate: string }

export interface CadenceReminderConfig {
  nodeId: string
  expectedCadence: CadenceExpectation
  reminderCopy?: string
}

export interface ContinuousBacklogConfig {
  nodeId: string
  backlogSource: DataSourceRef
  rateWindow?: '1h' | '24h' | '7d'
  topStuckCount?: number
}

/** addendum §5 — core ledger card recording observed health of bound
 *  integrations (last probe, auth state, circuit-breaker). 待后端接入. */
export interface IntegrationHealthConfig {
  /** IntegrationRef ids to watch; empty = every integration bound on canvas. */
  integrationIds?: string[]
  showCredentialActor?: boolean
}

// -- §6.1 discriminated MonitorCard ------------------------------------------

interface MonitorCardBase {
  id: string
  layout: CardLayout
  title?: string
  attemptVisibility?: AttemptVisibility
  viewerFilter?: ViewerFilter
}

export type MonitorCard =
  | (MonitorCardBase & { type: 'period-selector'; config: PeriodSelectorConfig })
  | (MonitorCardBase & { type: 'producer-status-grid'; config: ProducerStatusGridConfig })
  | (MonitorCardBase & { type: 'meeting-checklist'; config: MeetingChecklistConfig })
  | (MonitorCardBase & { type: 'queue-depth'; config: QueueDepthConfig })
  | (MonitorCardBase & { type: 'snapshot-timeline'; config: SnapshotTimelineConfig })
  | (MonitorCardBase & { type: 'downstream-drill'; config: DownstreamDrillConfig })
  | (MonitorCardBase & { type: 'continuous-backlog'; config: ContinuousBacklogConfig })
  | (MonitorCardBase & { type: 'integration-health'; config: IntegrationHealthConfig })
  | (MonitorCardBase & { type: 'cadence-reminder'; config: CadenceReminderConfig })

export interface MonitorSpec {
  canvasId: string
  version: number
  globalFilters?: {
    statusIn?: PlanningNodeStatus[]
    assigneeIn?: string[]
  }
  cards: MonitorCard[]
  appliedFromProposalId?: string
}
