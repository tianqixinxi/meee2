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
import { useI18n } from '../lib/i18n'

interface Props {
  userProfile: UserProfile | null
}

type TeamInfo = UserProfile['teams'][number]

export function TeamView({ userProfile }: Props) {
  const { t } = useI18n()
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
          setError((err as Error).message || t('team.loadFailed'))
        }
      })
    return () => {
      cancelled = true
    }
  }, [connected, t])

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
      <section className="team-view" aria-label={t('team.title')}>
        <div className="team-view__inner">
          <div className="team-view__gate">
            <LockKeyhole size={18} aria-hidden />
            <div>
              <strong>{t('team.signInTitle')}</strong>
              <p>{t('team.signInSubtitle')}</p>
            </div>
          </div>
        </div>
      </section>
    )
  }

  return (
    <section className="team-view" aria-label={t('team.title')}>
      <div className="team-view__inner">
        <div className="team-view__header">
          <div>
            <span>{t('team.title')}</span>
            <h1>{currentTeam?.name || userProfile?.defaultSyncTeamName || t('team.currentTeam')}</h1>
            <p>{t('team.subtitle')}</p>
          </div>
          <div className="team-view__summary">
            <UsersRound size={15} aria-hidden />
            {t('team.summary', { count: members.length, role: currentRole ? ` · ${currentRole}` : '' })}
          </div>
        </div>

        {error && <div className="team-view__error">{error}</div>}

        <div className="team-view__sections">
          <section className="team-panel-section" aria-label={t('team.members')}>
            <div className="team-panel-section__header">
              <div>
                <span>{t('team.members')}</span>
                <h2>{t('team.people')}</h2>
              </div>
              <strong>{members.length}</strong>
            </div>
            {members.length === 0 ? (
              <div className="team-view__empty">
                <User size={16} aria-hidden />
                <span>{t('team.noMembers')}</span>
              </div>
            ) : (
              <div className="team-view__grid">
                {members.map((member) => (
                  <TeamMemberCard
                    key={member.userId}
                    member={member}
                    current={member.userId === userProfile?.userId}
                    currentLabel={t('team.you')}
                  />
                ))}
              </div>
            )}
          </section>

          <section className="team-panel-section" aria-label={t('team.inviteLink')}>
            <div className="team-panel-section__header">
              <div>
                <span>{t('team.invite')}</span>
                <h2>{t('team.inviteLink')}</h2>
              </div>
            </div>
            <div className="team-invite">
              <code>{inviteText || t('team.inviteUnavailable')}</code>
              <button
                type="button"
                className="team-view__icon-button"
                onClick={copyInvite}
                disabled={!inviteText}
                title={t('team.copyInvite')}
                aria-label={t('team.copyInvite')}
              >
                <Copy size={15} aria-hidden />
              </button>
            </div>
            <p className="team-panel-section__note">
              {t('team.inviteNote')}
            </p>
            <div className="team-view__actions">
              <button type="button" className="team-view__action" onClick={() => void openMeee2OnlineDashboard()}>
                <ExternalLink size={14} aria-hidden />
                {t('team.openDashboard')}
              </button>
            </div>
            {copyState !== 'idle' && (
              <p className={`team-view__copy-state is-${copyState}`}>
                {copyState === 'copied' ? t('common.copied') : t('common.copyFailed')}
              </p>
            )}
          </section>

          {isOwner && (
            <section className="team-panel-section" aria-label={t('settings.team')}>
              <div className="team-panel-section__header">
                <div>
                  <span>{t('rail.settings')}</span>
                  <h2>{t('team.ownerControls')}</h2>
                </div>
                <ShieldCheck size={16} aria-hidden />
              </div>
              <div className="team-settings-list">
                <TeamSettingRow label={t('team.teamId')} value={currentTeam?.id || userProfile?.defaultSyncTeamId || t('team.notSet')} />
                <TeamSettingRow label={t('team.defaultSync')} value={userProfile?.defaultSyncEnabled ? t('team.enabled') : t('team.disabled')} />
                <TeamSettingRow label={t('team.role')} value={currentRole ?? t('team.unknown')} />
              </div>
              <div className="team-view__actions">
                <button type="button" className="team-view__action" onClick={() => void openMeee2Settings()}>
                  <Settings size={14} aria-hidden />
                  {t('team.openSettings')}
                </button>
                <button type="button" className="team-view__action" onClick={() => void openMeee2OnlineDashboard()}>
                  <ExternalLink size={14} aria-hidden />
                  {t('team.openDashboard')}
                </button>
              </div>
            </section>
          )}

          {!isOwner && (
            <section className="team-panel-section" aria-label={t('settings.team')}>
              <div className="team-panel-section__header">
                <div>
                  <span>{t('rail.settings')}</span>
                  <h2>{t('team.ownerControls')}</h2>
                </div>
                <LockKeyhole size={16} aria-hidden />
              </div>
              <p className="team-panel-section__note">
                {t('team.ownerOnly')}
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
  currentLabel,
}: {
  member: TeamMember
  current: boolean
  currentLabel: string
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
        {current && <span>{currentLabel}</span>}
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
