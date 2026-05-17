import { GitBranch, User, UsersRound } from 'lucide-react'
import { useEffect, useMemo, useState } from 'react'
import { fetchPlannerGraphState, type UserProfile } from '../api'
import { buildTeamDirectory, type PlannerTeamMember } from '../teamDirectory'
import type { BoardState, CanvasInfo, PlannerGraphState } from '../types'

interface Props {
  state: BoardState | null
  activeCanvas: CanvasInfo | null
  userProfile: UserProfile | null
}

export function TeamView({ state, activeCanvas, userProfile }: Props) {
  const [graphState, setGraphState] = useState<PlannerGraphState | null>(null)
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

  const members = useMemo(() => buildTeamDirectory({
    userProfile,
    boardState: state,
    activeCanvas,
    canvasOwnerId: graphState?.canvas.ownerId ?? activeCanvas?.ownerUserId,
    nodes: graphState?.nodes ?? [],
    activities: graphState?.activities ?? [],
  }), [activeCanvas, graphState, state, userProfile])

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
            <TeamMemberCard key={member.userId} member={member} />
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

function TeamMemberCard({ member }: { member: PlannerTeamMember }) {
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
        </div>
      </div>
      <div className="team-member-card__meta">
        <strong>{member.assignedNodeCount}</strong>
        <span>assigned</span>
      </div>
    </article>
  )
}
