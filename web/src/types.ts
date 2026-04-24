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
  costUSD: number | null
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
}

export interface Member {
  alias: string
  sessionId: string
}

export interface Channel {
  name: string
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

export interface BoardState {
  sessions: Session[]
  channels: Channel[]
}

export interface ApiError {
  error: { code: string; message: string }
}

// Selection state — what's picked on the board.
export type Selection =
  | { kind: 'none' }
  | { kind: 'session'; sessionId: string }
  | { kind: 'channel'; channelName: string }
