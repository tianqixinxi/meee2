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

export interface RecapSource {
  kind: 'deterministic' | 'ai' | 'provider' | 'mixed'
  provider?: string
  model?: string
  generatedFrom?: string[]
  error?: string
}

export interface SessionRecap {
  scope: 'session'
  sessionId: string
  provider: string
  headline: string
  details: string[]
  statusSignals: RecapStatusSignal[]
  evidenceRefs: EvidenceRef[]
  source: RecapSource
  updatedAt: string
  fingerprint: string
}

export interface CanvasRecap {
  scope: 'canvas'
  canvasId: string
  headline: string
  details: string[]
  statusCounts: RecapStatusCount[]
  blockers: RecapBlocker[]
  approvals: RecapApproval[]
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
  statuses: RecapStatusCount[]
  details: string[]
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
  details: string[]
  model?: string
  raw?: string
}

export interface RecapGenerator {
  generate(input: RecapGenerationInput): Promise<RecapGenerationResult>
}
