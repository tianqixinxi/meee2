export type RecapScope = 'session' | 'canvas'

export type RecapStatusTone =
  | 'ready'
  | 'running'
  | 'attention'
  | 'approval'
  | 'done'
  | 'failed'
  | 'neutral'

export type RecapStatusKind =
  | 'active'
  | 'idle'
  | 'blocked'
  | 'needs_approval'
  | 'failed'
  | 'done'
  | 'unknown'

export interface RecapStatusCount {
  label: string
  value: number
  tone: RecapStatusTone
}

export interface RecapStatusSignal {
  kind: RecapStatusKind
  label: string
  reason?: string
  subjectId?: string
}

export type EvidenceKind =
  | 'transcript'
  | 'artifact'
  | 'diff'
  | 'file'
  | 'command'
  | 'pr'
  | 'tool_call'
  | 'event'
  | 'note'

export interface EvidenceRef {
  id: string
  kind: EvidenceKind
  title: string
  reference: string
  createdAt?: string
  nodeId?: string
  sessionId?: string
}

export interface RecapBlocker {
  subjectId: string
  subjectKind: 'session' | 'node' | 'canvas' | 'artifact'
  title: string
  reason: string
  evidenceRefs: EvidenceRef[]
}

export interface RecapApproval {
  subjectId: string
  subjectKind: 'session' | 'node' | 'proposal' | 'gate'
  title: string
  requestedBy?: string
  requiredFrom?: string[]
  evidenceRefs: EvidenceRef[]
}

/**
 * 「等谁 / 等什么」语义。和 RecapBlocker(已经卡住)区分开:
 *  - awaiting-approval  : 节点 status==='awaiting' 或 workflowRunState==='gate-wait',
 *                         需要 reviewer/approver 点头
 *  - awaiting-input     : workflowRunState==='awaiting-input',
 *                         缺一段 input(可能是上游产物、用户反馈、外部 PR)
 *  - awaiting-upstream  : dependsOnNodeIds 里至少一个上游还没 done
 */
export type RecapAwaitingKind = 'awaiting-approval' | 'awaiting-input' | 'awaiting-upstream'

export interface RecapAwaiting {
  kind: RecapAwaitingKind
  subjectId: string
  subjectKind: 'node' | 'canvas'
  title: string
  /** 自由文本,UI 直接展示,例如 "@alice"、"#123 待 review"、"等 NodeX 完成"。 */
  reason: string
  /** awaiting-approval 时的审批人列表(open_id / handle / email,原样保留)。 */
  reviewers?: string[]
  /** awaiting-upstream 时:上游 node id 列表,UI 可以跳过去。 */
  upstreamNodeIds?: string[]
  /** awaiting-input 时:对应的 input 描述(取自 RecapNodeInput.inputs 第一条)。 */
  inputSource?: string
  evidenceRefs: EvidenceRef[]
}

export interface RecapSource {
  kind: 'deterministic' | 'ai' | 'provider' | 'mixed'
  provider?: string
  model?: string
  generatedFrom?: string[]
  error?: string
}

export type ProviderRecapIntent =
  | 'human_recap'
  | 'context_compaction'
  | 'final_summary'
  | 'manual_note'

export type RecapConfidence = 'high' | 'medium' | 'low'

export interface ProviderRecapSignal {
  id: string
  provider: string
  sessionId: string
  intent: ProviderRecapIntent
  content: string
  timestamp?: string | null
  sourceRef?: string | null
  confidence?: RecapConfidence
  metadata?: Record<string, string>
}

export interface SessionRecap {
  scope: 'session'
  sessionId: string
  provider: string
  headline: string
  displayTitle?: string
  details: string[]
  statusSignals: RecapStatusSignal[]
  evidenceRefs: EvidenceRef[]
  source: RecapSource
  intent?: ProviderRecapIntent
  confidence?: RecapConfidence
  updatedAt: string
  fingerprint: string
}

export interface SessionRecapBuildInput {
  now: string
  sessionId: string
  provider: string
  title?: string | null
  status?: string | null
  currentTask?: string | null
  signals?: ProviderRecapSignal[]
  recentMessages?: Array<{ role: string; text: string }>
  evidenceRefs?: EvidenceRef[]
}

export interface DisplaySessionTitle {
  text: string
  source: 'manual_override' | 'session_recap' | 'current_task' | 'initial_prompt' | 'provider_title' | 'fallback'
  confidence: RecapConfidence
}

export interface DisplaySessionTitleInput {
  manualOverride?: string | null
  sessionRecap?: Pick<SessionRecap, 'headline' | 'displayTitle' | 'intent' | 'confidence'> | null
  currentTask?: string | null
  initialUserMessage?: string | null
  providerTitle?: string | null
  fallbackTitle?: string | null
  providerDisplayName?: string | null
}

export interface CanvasRecap {
  scope: 'canvas'
  canvasId: string
  headline: string
  details: string[]
  statusCounts: RecapStatusCount[]
  blockers: RecapBlocker[]
  approvals: RecapApproval[]
  /**
   * 「在等谁/什么」桶。和 blockers(硬卡住)、approvals(已经成 gate)互补。
   * 可选 — 旧调用方不会看到 undefined 上游不读这个字段。
   */
  awaitingItems?: RecapAwaiting[]
  evidenceRefs: EvidenceRef[]
  sessionRefs: string[]
  subCanvasRefs: string[]
  source: RecapSource
  updatedAt: string
  fingerprint: string
  stale: boolean
}

export interface RecapCanvasInput {
  id: string
  title: string
  context?: string | null
}

export interface RecapNodeInput {
  id: string
  title: string
  status?: string | null
  workflowRunState?: string | null
  blockedReason?: string | null
  nextAction?: string | null
  inputs?: string[]
  outputs?: string[]
  dependsOnNodeIds?: string[]
  sessionId?: string | null
  subCanvasId?: string | null
  scheduled?: boolean
  artifactRefs?: string[]
  /** Reviewers / approvers required to unblock the node (open_id / handle / email). */
  approvers?: string[]
}

export interface RecapSessionInput {
  id: string
  title: string
  provider: string
  status: string
  currentTask?: string | null
  pendingPermissionTool?: string | null
  pendingPermissionMessage?: string | null
  latestRecap?: SessionRecap | null
  recentMessages?: Array<{ role: string; text: string }>
}

export interface RecapEventInput {
  id: string
  type: string
  summary: string
  createdAt: string
  nodeId?: string | null
  artifactRefs?: string[]
}

export interface RecapProposalInput {
  id: string
  status: string
  summary: string
  changeCount?: number
}

export interface RecapSubCanvasInput {
  id: string
  title: string
  recap?: CanvasRecap | null
}

export interface RecapTemplatePolicy {
  id: string
  label: string
  statusStrategy: 'monitor' | 'workflow' | 'kanban' | 'dependency' | 'inbox'
  doneRequiresEvidence: boolean
  surfaceApprovals: boolean
  surfaceBlocked: boolean
  surfaceSubCanvasRollups: boolean
  maxSessionRecaps: number
  maxEvidenceRefs: number
}

export interface RecapInput {
  now: string
  canvas: RecapCanvasInput
  nodes: RecapNodeInput[]
  sessions: RecapSessionInput[]
  artifacts: EvidenceRef[]
  events: RecapEventInput[]
  proposals: RecapProposalInput[]
  subCanvases: RecapSubCanvasInput[]
  template?: RecapTemplatePolicy
}

export interface CanvasStatusRecap {
  description: string
  headline: string
  summary?: string
  statuses: RecapStatusCount[]
  details: string[]
  /** Surfaced 「等谁/等什么」items, parallel to CanvasRecap.awaitingItems. */
  awaitingItems?: RecapAwaiting[]
  updatedAt: string
}

export interface RecapGenerationInput {
  prompt: string
  canvasId?: string
  workspacePath?: string
  locale: 'zh-CN' | 'en-US'
  maxDetails: number
}

export interface RecapGenerationResult {
  headline: string
  summary?: string
  details: string[]
  model?: string
  raw?: string
}

export interface RecapGenerator {
  generate(input: RecapGenerationInput): Promise<RecapGenerationResult>
}
