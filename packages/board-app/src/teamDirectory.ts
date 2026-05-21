import type { BoardState, CanvasInfo, PlannerActivity, PlannerCanvasRole, PlanningNode } from './types'
import type { TeamMember, UserProfile } from './api'

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
  /** Team-level membership role from `/api/team/members`, when known. */
  teamRole?: string | null
}

interface BuildTeamDirectoryInput {
  userProfile: UserProfile | null
  boardState?: BoardState | null
  activeCanvas?: CanvasInfo | null
  canvasOwnerId?: string | null
  nodes?: PlanningNode[]
  activities?: PlannerActivity[]
  /**
   * Authoritative team member identities from `/api/team/members`, keyed by
   * `userId`. When present these override the names/avatars inferred from
   * nodes + activities, so the graph resolves real people.
   */
  teamMembers?: TeamMember[]
}

export function buildTeamDirectory(input: BuildTeamDirectoryInput): PlannerTeamMember[] {
  const members = new Map<string, PlannerTeamMember>()
  const ownerId = input.canvasOwnerId || input.activeCanvas?.ownerUserId || 'local-owner'

  // Authoritative identity source — index by userId for fast override lookup.
  const realById = new Map<string, TeamMember>()
  for (const real of input.teamMembers ?? []) {
    const uid = real.userId?.trim()
    if (uid) realById.set(uid, real)
  }

  const ownerReal = realById.get(ownerId)
  upsertMember(members, {
    userId: ownerId,
    displayName: ownerReal?.displayName || ownerDisplayName(input.userProfile),
    avatarUrl: ownerReal?.avatarUrl
      || (input.userProfile?.connected ? input.userProfile.userAvatarUrl || undefined : undefined),
    roles: ['owner'],
    assignedNodeCount: 0,
    teamRole: ownerReal?.role ?? null,
  })

  for (const activity of input.activities ?? []) {
    const real = realById.get(activity.userId)
    upsertMember(members, {
      userId: activity.userId,
      displayName: real?.displayName
        || (activity.userId === ownerId ? ownerDisplayName(input.userProfile) : activity.displayName),
      avatarUrl: real?.avatarUrl
        || (activity.userId === ownerId && input.userProfile?.connected
          ? input.userProfile.userAvatarUrl || undefined
          : undefined),
      roles: [activity.userId === ownerId ? 'owner' : 'active'],
      assignedNodeCount: 0,
      selectedNodeId: activity.selectedNodeId,
      selectedSessionId: activity.selectedSessionId,
      lastActiveAt: activity.lastActiveAt,
      teamRole: real?.role ?? null,
    })
  }

  for (const node of input.nodes ?? []) {
    const doerId = node.doerId?.trim()
    if (!doerId) continue
    const existing = members.get(doerId)
    const real = realById.get(doerId)
    upsertMember(members, {
      userId: doerId,
      displayName: real?.displayName
        ?? existing?.displayName
        ?? inferMemberName(doerId, ownerId, input.userProfile),
      avatarUrl: real?.avatarUrl ?? existing?.avatarUrl,
      roles: [isAgentId(doerId) ? 'agent' : 'doer'],
      assignedNodeCount: 1,
      teamRole: real?.role ?? existing?.teamRole ?? null,
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

  // Fold in any authoritative members not yet discovered from local signals,
  // so the directory reflects the full team — not only people touching nodes.
  for (const real of realById.values()) {
    if (members.has(real.userId)) continue
    upsertMember(members, {
      userId: real.userId,
      displayName: real.displayName || real.userId,
      avatarUrl: real.avatarUrl || undefined,
      roles: [isAgentId(real.userId) ? 'agent' : 'active'],
      assignedNodeCount: 0,
      teamRole: real.role ?? null,
    })
  }

  return [...members.values()].sort((a, b) => {
    const rank = memberRank(a) - memberRank(b)
    if (rank !== 0) return rank
    return a.displayName.localeCompare(b.displayName)
  })
}

/**
 * Each member's role *on the current canvas* — owner / doer / suggestion /
 * viewer — derived the same way the backend `PlannerPermission.access` does:
 * the canvas owner is `owner`, anyone assigned to a node is a `doer`, the
 * canvas actor's own `access.role` is authoritative for themselves, everyone
 * else is a `viewer`.
 */
export function canvasRoleByUserId(input: {
  members: PlannerTeamMember[]
  ownerId?: string | null
  nodes?: PlanningNode[]
  access?: { actorId: string; role: PlannerCanvasRole } | null
}): Record<string, PlannerCanvasRole> {
  const ownerId = (input.ownerId ?? '').trim()
  const doerIds = new Set(
    (input.nodes ?? [])
      .map((node) => node.doerId?.trim())
      .filter((id): id is string => Boolean(id)),
  )
  const out: Record<string, PlannerCanvasRole> = {}
  for (const member of input.members) {
    if (input.access && member.userId === input.access.actorId) {
      out[member.userId] = input.access.role
    } else if (ownerId && member.userId === ownerId) {
      out[member.userId] = 'owner'
    } else if (doerIds.has(member.userId)) {
      out[member.userId] = 'doer'
    } else {
      out[member.userId] = 'viewer'
    }
  }
  return out
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
    teamRole: next.teamRole ?? existing.teamRole ?? null,
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
