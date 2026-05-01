// Structural types consumed by @meee1/board-ui's <SessionInspector>.
//
// Both meee2's `Session` (from BoardDTO) and a meee360 derived view
// (TeamSession + summary) satisfy these structurally — apps map their
// native session shape into `SessionForInspector` at the call site.

export interface UsageStatsForInspector {
  inputTokens: number
  outputTokens: number
  cacheCreateTokens: number
  cacheReadTokens: number
  turns: number
  model: string
}

export interface BackgroundAgentForInspector {
  id: string
  kind: string
  description: string | null
  startedAt: string | null
}

export interface SessionRecapForInspector {
  content: string
  timestamp: string | null
}

/** A single inbox message reference for the inspector's optional inbox block. */
export interface InboxItemForInspector {
  id: string
  channel: string
  fromAlias: string
  toAlias: string
  content: string
  createdAt: string
}

/** Channel name + the session's aliases in that channel — for the chip strip. */
export interface ChannelMembershipForInspector {
  channel: string
  aliases: string[]
}

/** Minimum session shape SessionInspector reads. */
export interface SessionForInspector {
  id: string
  title: string
  /** cwd or project path. */
  project: string
  /** hex color for the identity dot. */
  pluginColor: string
  /** Backend status enum: idle/thinking/tooling/active/waitingForUser/
   *  permissionRequired/compacting/completed/dead/... */
  status: string
  /** Currently-running tool name, if any. */
  currentTool: string | null
  usageStats: UsageStatsForInspector | null
  backgroundAgents: BackgroundAgentForInspector[]
  latestRecap: SessionRecapForInspector | null
  inboxPending: number
}
