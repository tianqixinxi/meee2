import type { BoardState, CanvasInfo, PlannerActivity, PlanningNode } from './types'
import type { UserProfile } from './api'

export type PlannerTeamRole = 'owner' | 'doer' | 'active' | 'agent'

export interface PlannerTeamMember {
  userId: string
  displayName: string
  avatarUrl?: string
  roles: PlannerTeamRole[]
  assignedNodeCount: number
  selectedNodeId?: string | null
  selectedSessionId?: string | null
  lastActiveAt?: string | null
}

interface BuildTeamDirectoryInput {
  userProfile: UserProfile | null
  boardState?: BoardState | null
  activeCanvas?: CanvasInfo | null
  canvasOwnerId?: string | null
  nodes?: PlanningNode[]
  activities?: PlannerActivity[]
}

export function buildTeamDirectory(input: BuildTeamDirectoryInput): PlannerTeamMember[] {
  const members = new Map<string, PlannerTeamMember>()
  const ownerId = input.canvasOwnerId || input.activeCanvas?.ownerUserId || 'local-owner'

  upsertMember(members, {
    userId: ownerId,
    displayName: ownerDisplayName(input.userProfile),
    avatarUrl: input.userProfile?.connected ? input.userProfile.userAvatarUrl || undefined : undefined,
    roles: ['owner'],
    assignedNodeCount: 0,
  })

  for (const activity of input.activities ?? []) {
    upsertMember(members, {
      userId: activity.userId,
      displayName: activity.userId === ownerId ? ownerDisplayName(input.userProfile) : activity.displayName,
      avatarUrl: activity.userId === ownerId && input.userProfile?.connected
        ? input.userProfile.userAvatarUrl || undefined
        : undefined,
      roles: [activity.userId === ownerId ? 'owner' : 'active'],
      assignedNodeCount: 0,
      selectedNodeId: activity.selectedNodeId,
      selectedSessionId: activity.selectedSessionId,
      lastActiveAt: activity.lastActiveAt,
    })
  }

  for (const node of input.nodes ?? []) {
    const doerId = node.doerId?.trim()
    if (!doerId) continue
    const existing = members.get(doerId)
    upsertMember(members, {
      userId: doerId,
      displayName: existing?.displayName ?? inferMemberName(doerId, ownerId, input.userProfile),
      avatarUrl: existing?.avatarUrl,
      roles: [isAgentId(doerId) ? 'agent' : 'doer'],
      assignedNodeCount: 1,
    })
  }

  for (const session of input.boardState?.sessions ?? []) {
    const agentId = `agent-${session.pluginId}`
    upsertMember(members, {
      userId: agentId,
      displayName: session.pluginDisplayName || agentName(session.pluginId),
      roles: ['agent'],
      assignedNodeCount: 0,
    })
  }

  return [...members.values()].sort((a, b) => {
    const rank = memberRank(a) - memberRank(b)
    if (rank !== 0) return rank
    return a.displayName.localeCompare(b.displayName)
  })
}

export function teamDisplayNameByUserId(members: PlannerTeamMember[]): Record<string, string> {
  return Object.fromEntries(members.map((member) => [member.userId, member.displayName]))
}

export function teamAvatarUrlByUserId(members: PlannerTeamMember[]): Record<string, string> {
  return Object.fromEntries(
    members
      .filter((member) => Boolean(member.avatarUrl))
      .map((member) => [member.userId, member.avatarUrl as string]),
  )
}

function upsertMember(map: Map<string, PlannerTeamMember>, next: PlannerTeamMember) {
  const existing = map.get(next.userId)
  if (!existing) {
    map.set(next.userId, {
      ...next,
      roles: uniqueRoles(next.roles),
    })
    return
  }
  map.set(next.userId, {
    ...existing,
    displayName: next.displayName || existing.displayName,
    avatarUrl: next.avatarUrl || existing.avatarUrl,
    roles: uniqueRoles([...existing.roles, ...next.roles]),
    assignedNodeCount: existing.assignedNodeCount + next.assignedNodeCount,
    selectedNodeId: next.selectedNodeId ?? existing.selectedNodeId,
    selectedSessionId: next.selectedSessionId ?? existing.selectedSessionId,
    lastActiveAt: latestTime(existing.lastActiveAt, next.lastActiveAt),
  })
}

function uniqueRoles(roles: PlannerTeamRole[]): PlannerTeamRole[] {
  return [...new Set(roles)]
}

function ownerDisplayName(userProfile: UserProfile | null): string {
  if (userProfile?.connected && userProfile.displayName.trim()) return userProfile.displayName
  return 'Canvas owner'
}

function inferMemberName(userId: string, ownerId: string, userProfile: UserProfile | null): string {
  if (userId === ownerId) return ownerDisplayName(userProfile)
  if (isAgentId(userId)) return agentName(userId.replace(/^agent-/, ''))
  return userId
}

function isAgentId(userId: string): boolean {
  return userId.startsWith('agent-')
}

function agentName(value: string): string {
  const normalized = value.replace(/^agent-/, '')
  switch (normalized) {
    case 'openClaw':
    case 'openclaw':
      return 'OpenClaw'
    case 'claude':
      return 'Claude'
    case 'codex':
      return 'Codex'
    case 'cursor':
      return 'Cursor'
    case 'human':
      return 'Human'
    default:
      return normalized ? normalized[0].toUpperCase() + normalized.slice(1) : 'Agent'
  }
}

function memberRank(member: PlannerTeamMember): number {
  if (member.roles.includes('owner')) return 0
  if (member.roles.includes('doer')) return 1
  if (member.roles.includes('active')) return 2
  return 3
}

function latestTime(left?: string | null, right?: string | null): string | null | undefined {
  if (!left) return right
  if (!right) return left
  return Date.parse(left) >= Date.parse(right) ? left : right
}
