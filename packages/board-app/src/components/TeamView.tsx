import {
  Copy,
  ExternalLink,
  LockKeyhole,
  Settings,
  ShieldCheck,
  User,
  UsersRound,
} from 'lucide-react'
import { useEffect, useMemo, useState } from 'react'
import {
  fetchTeamMembers,
  openMeee2OnlineDashboard,
  openMeee2Settings,
  type TeamMember,
  type UserProfile,
} from '../api'

interface Props {
  userProfile: UserProfile | null
}

type TeamInfo = UserProfile['teams'][number]

export function TeamView({ userProfile }: Props) {
  const [teamMembers, setTeamMembers] = useState<TeamMember[]>([])
  const [error, setError] = useState<string | null>(null)
  const [copyState, setCopyState] = useState<'idle' | 'copied' | 'failed'>('idle')

  const connected = Boolean(userProfile?.connected)
  const currentTeam = useMemo(() => currentTeamFor(userProfile), [userProfile])
  const currentRole = currentTeam?.role ?? memberRoleFor(teamMembers, userProfile?.userId) ?? null
  const isOwner = currentRole === 'owner'

  useEffect(() => {
    if (!connected) {
      setTeamMembers([])
      return
    }

    let cancelled = false
    setError(null)
    fetchTeamMembers()
      .then((res) => {
        if (!cancelled) setTeamMembers(res.members)
      })
      .catch((err) => {
        if (!cancelled) {
          setTeamMembers([])
          setError((err as Error).message || 'Failed to load team members')
        }
      })
    return () => {
      cancelled = true
    }
  }, [connected])

  const members = useMemo(() => {
    if (!connected) return []
    return teamMembers.filter((member) => isHumanTeamMember(member, userProfile))
  }, [connected, teamMembers, userProfile])

  const inviteText = ''

  const copyInvite = async () => {
    if (!inviteText) return
    try {
      await navigator.clipboard.writeText(inviteText)
      setCopyState('copied')
    } catch {
      setCopyState('failed')
    }
    window.setTimeout(() => setCopyState('idle'), 1800)
  }

  if (!connected) {
    return (
      <section className="team-view" aria-label="Team">
        <div className="team-view__inner">
          <div className="team-view__gate">
            <LockKeyhole size={18} aria-hidden />
            <div>
              <strong>Sign in to manage a team</strong>
              <p>Team management is available after connecting meee2 Online.</p>
            </div>
          </div>
        </div>
      </section>
    )
  }

  return (
    <section className="team-view" aria-label="Team">
      <div className="team-view__inner">
        <div className="team-view__header">
          <div>
            <span>Team</span>
            <h1>{currentTeam?.name || userProfile?.defaultSyncTeamName || 'Current team'}</h1>
            <p>Manage people, invites, and team-wide configuration for the signed-in workspace.</p>
          </div>
          <div className="team-view__summary">
            <UsersRound size={15} aria-hidden />
            {members.length} human member{members.length === 1 ? '' : 's'}
            {currentRole ? ` · ${currentRole}` : ''}
          </div>
        </div>

        {error && <div className="team-view__error">{error}</div>}

        <div className="team-view__sections">
          <section className="team-panel-section" aria-label="Members">
            <div className="team-panel-section__header">
              <div>
                <span>Members</span>
                <h2>People in this team</h2>
              </div>
              <strong>{members.length}</strong>
            </div>
            {members.length === 0 ? (
              <div className="team-view__empty">
                <User size={16} aria-hidden />
                <span>No online team members are available from the desktop bridge yet.</span>
              </div>
            ) : (
              <div className="team-view__grid">
                {members.map((member) => (
                  <TeamMemberCard
                    key={member.userId}
                    member={member}
                    current={member.userId === userProfile?.userId}
                  />
                ))}
              </div>
            )}
          </section>

          <section className="team-panel-section" aria-label="Invite link">
            <div className="team-panel-section__header">
              <div>
                <span>Invite</span>
                <h2>Invite link</h2>
              </div>
            </div>
            <div className="team-invite">
              <code>{inviteText || 'Invite link is not available from desktop yet'}</code>
              <button
                type="button"
                className="team-view__icon-button"
                onClick={copyInvite}
                disabled={!inviteText}
                title="Copy invite link"
                aria-label="Copy invite link"
              >
                <Copy size={15} aria-hidden />
              </button>
            </div>
            <p className="team-panel-section__note">
              The online team already owns invite codes; the desktop bridge should expose that authoritative code/link here.
            </p>
            <div className="team-view__actions">
              <button type="button" className="team-view__action" onClick={() => void openMeee2OnlineDashboard()}>
                <ExternalLink size={14} aria-hidden />
                Open dashboard
              </button>
            </div>
            {copyState !== 'idle' && (
              <p className={`team-view__copy-state is-${copyState}`}>
                {copyState === 'copied' ? 'Copied' : 'Copy failed'}
              </p>
            )}
          </section>

          {isOwner && (
            <section className="team-panel-section" aria-label="Team settings">
              <div className="team-panel-section__header">
                <div>
                  <span>Settings</span>
                  <h2>Owner controls</h2>
                </div>
                <ShieldCheck size={16} aria-hidden />
              </div>
              <div className="team-settings-list">
                <TeamSettingRow label="Team id" value={currentTeam?.id || userProfile?.defaultSyncTeamId || 'Not set'} />
                <TeamSettingRow label="Default sync" value={userProfile?.defaultSyncEnabled ? 'Enabled' : 'Disabled'} />
                <TeamSettingRow label="Role" value={currentRole ?? 'Unknown'} />
              </div>
              <div className="team-view__actions">
                <button type="button" className="team-view__action" onClick={() => void openMeee2Settings()}>
                  <Settings size={14} aria-hidden />
                  Open settings
                </button>
                <button type="button" className="team-view__action" onClick={() => void openMeee2OnlineDashboard()}>
                  <ExternalLink size={14} aria-hidden />
                  Open dashboard
                </button>
              </div>
            </section>
          )}

          {!isOwner && (
            <section className="team-panel-section" aria-label="Team settings unavailable">
              <div className="team-panel-section__header">
                <div>
                  <span>Settings</span>
                  <h2>Owner controls</h2>
                </div>
                <LockKeyhole size={16} aria-hidden />
              </div>
              <p className="team-panel-section__note">
                Team configuration is visible only to the team owner.
              </p>
            </section>
          )}
        </div>
      </div>
    </section>
  )
}

function TeamMemberCard({
  member,
  current,
}: {
  member: TeamMember
  current: boolean
}) {
  return (
    <article className="team-member-card">
      <div className={`team-member-card__avatar${member.avatarUrl ? ' has-image' : ''}`}>
        {member.avatarUrl ? <img src={member.avatarUrl} alt="" /> : <User size={17} aria-hidden />}
      </div>
      <div className="team-member-card__main">
        <div className="team-member-card__title">
          <strong>{member.displayName || member.userId}</strong>
          <span>{member.userId}</span>
        </div>
      </div>
      <div className="team-member-card__meta">
        {current && <span>You</span>}
        <strong>{member.role ?? 'member'}</strong>
      </div>
    </article>
  )
}

function TeamSettingRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="team-setting-row">
      <span>{label}</span>
      <strong>{value}</strong>
    </div>
  )
}

function currentTeamFor(userProfile: UserProfile | null): TeamInfo | null {
  if (!userProfile?.connected) return null
  return userProfile.teams.find((team) => team.isDefault)
    ?? userProfile.teams.find((team) => team.id === userProfile.defaultSyncTeamId)
    ?? userProfile.teams[0]
    ?? null
}

function memberRoleFor(members: TeamMember[], userId?: string): string | null {
  if (!userId) return null
  return members.find((member) => member.userId === userId)?.role ?? null
}

function isHumanTeamMember(member: TeamMember, userProfile: UserProfile | null): boolean {
  return Boolean(member.role) || member.userId === userProfile?.userId
}
