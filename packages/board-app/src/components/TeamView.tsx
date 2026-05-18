import { GitBranch, ShieldCheck, User, UsersRound } from 'lucide-react'
import { useEffect, useMemo, useState } from 'react'
import { fetchPlannerGraphState, fetchTeamMembers, type TeamMember, type UserProfile } from '../api'
import { buildTeamDirectory, canvasRoleByUserId, type PlannerTeamMember } from '../teamDirectory'
import type { BoardState, CanvasInfo, PlannerCanvasRole, PlannerGraphState } from '../types'

interface Props {
  state: BoardState | null
  activeCanvas: CanvasInfo | null
  userProfile: UserProfile | null
}

export function TeamView({ state, activeCanvas, userProfile }: Props) {
  const [graphState, setGraphState] = useState<PlannerGraphState | null>(null)
  const [teamMembers, setTeamMembers] = useState<TeamMember[]>([])
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!activeCanvas) {
      setGraphState(null)
      return
    }
    let cancelled = false
    setError(null)
    fetchPlannerGraphState(activeCanvas.id)
      .then((next) => {
        if (!cancelled) setGraphState(next)
      })
      .catch((err) => {
        if (!cancelled) setError((err as Error).message || 'Failed to load team graph context')
      })
    return () => {
      cancelled = true
    }
  }, [activeCanvas?.id])

  // Authoritative member identities (display name + avatar + team role).
  useEffect(() => {
    let cancelled = false
    fetchTeamMembers()
      .then((res) => {
        if (!cancelled) setTeamMembers(res.members)
      })
      .catch(() => {
        if (!cancelled) setTeamMembers([])
      })
    return () => {
      cancelled = true
    }
  }, [])

  const members = useMemo(() => buildTeamDirectory({
    userProfile,
    boardState: state,
    activeCanvas,
    canvasOwnerId: graphState?.canvas.ownerId ?? activeCanvas?.ownerUserId,
    nodes: graphState?.nodes ?? [],
    activities: graphState?.activities ?? [],
    teamMembers,
  }), [activeCanvas, graphState, state, userProfile, teamMembers])

  // Each member's role on the *current* canvas (owner / doer / viewer /
  // suggestion) — derived from planner access + node doerIds + canvas owner.
  const canvasRoles = useMemo(() => canvasRoleByUserId({
    members,
    ownerId: graphState?.canvas.ownerId ?? activeCanvas?.ownerUserId,
    nodes: graphState?.nodes ?? [],
    access: graphState?.access ?? null,
  }), [members, graphState, activeCanvas])

  const assignedCount = members.reduce((total, member) => total + member.assignedNodeCount, 0)

  return (
    <section className="team-view" aria-label="Team">
      <div className="team-view__inner">
        <div className="team-view__header">
          <div>
            <span>Team</span>
            <h1>{activeCanvas?.name ?? 'Canvas'} members</h1>
            <p>Owner and doer labels on Planner cards resolve from this member directory.</p>
          </div>
          <div className="team-view__summary">
            <UsersRound size={15} aria-hidden />
            {members.length} member{members.length === 1 ? '' : 's'} · {assignedCount} assigned node{assignedCount === 1 ? '' : 's'}
          </div>
        </div>

        {error && <div className="team-view__error">{error}</div>}

        <div className="team-view__grid">
          {members.map((member) => (
            <TeamMemberCard
              key={member.userId}
              member={member}
              canvasRole={canvasRoles[member.userId] ?? 'viewer'}
            />
          ))}
        </div>

        <div className="team-view__contract">
          <GitBranch size={15} aria-hidden />
          <div>
            <strong>Assignment contract</strong>
            <p>
              Planner nodes store stable ids in <code>ownerId</code> and <code>doerId</code>.
              The graph resolves those ids through this directory for avatar, name, and role display.
              Actual reassignment should be a proposal or owner-approved node update, not an automatic session guess.
            </p>
          </div>
        </div>
      </div>
    </section>
  )
}

/** Human-readable explanation of what a canvas role can do. */
const CANVAS_ROLE_DETAIL: Record<PlannerCanvasRole, string> = {
  owner: 'Full control — approve, apply and reject proposals.',
  doer: 'May update their assigned nodes; proposals need owner approval.',
  suggestion: 'May create proposals only — no direct node edits.',
  viewer: 'Read-only on this canvas.',
}

function TeamMemberCard({
  member,
  canvasRole,
}: {
  member: PlannerTeamMember
  canvasRole: PlannerCanvasRole
}) {
  return (
    <article className="team-member-card">
      <div className={`team-member-card__avatar${member.avatarUrl ? ' has-image' : ''}`}>
        {member.avatarUrl ? <img src={member.avatarUrl} alt="" /> : <User size={17} aria-hidden />}
      </div>
      <div className="team-member-card__main">
        <div className="team-member-card__title">
          <strong>{member.displayName}</strong>
          <span>{member.userId}</span>
        </div>
        <div className="team-member-card__roles">
          {member.roles.map((role) => <em key={role}>{role}</em>)}
          {member.teamRole && <em className="team-member-card__team-role">team: {member.teamRole}</em>}
        </div>
        <div
          className={`team-member-card__access team-member-card__access--${canvasRole}`}
          title={CANVAS_ROLE_DETAIL[canvasRole]}
        >
          <ShieldCheck size={13} aria-hidden />
          <span>Canvas access: <strong>{canvasRole}</strong></span>
        </div>
      </div>
      <div className="team-member-card__meta">
        <strong>{member.assignedNodeCount}</strong>
        <span>assigned</span>
      </div>
    </article>
  )
}
