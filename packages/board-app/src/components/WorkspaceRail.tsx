import {
  Cable,
  Archive,
  LayoutTemplate,
  Network,
  Settings,
  Terminal,
  User,
  UsersRound,
} from 'lucide-react'
import { type ReactNode, useEffect, useMemo } from 'react'
import type { CanvasInfo } from '../types'
import type { UserProfile } from '../api'
import { useI18n } from '../lib/i18n'

export type WorkspaceMode = 'session' | 'planner' | 'templates' | 'artifacts' | 'team' | 'integrations' | 'settings'

interface WorkspaceRailProps {
  canvases: CanvasInfo[]
  activeCanvasId: string
  mode: WorkspaceMode
  userProfile: UserProfile | null
  onModeChange: (mode: WorkspaceMode) => void
}

const RAIL_WIDTH = 176

export function WorkspaceRail({
  mode,
  userProfile,
  onModeChange,
}: WorkspaceRailProps) {
  const { t } = useI18n()
  useEffect(() => {
    document.documentElement.style.setProperty('--sidebar-width', `${RAIL_WIDTH}px`)
    document.documentElement.classList.add('board-sidebar-rail')
    return () => {
      document.documentElement.style.removeProperty('--sidebar-width')
      document.documentElement.classList.remove('board-sidebar-rail')
    }
  }, [])

  const showTeam = Boolean(userProfile?.connected)

  useEffect(() => {
    if (mode === 'team' && !showTeam) {
      onModeChange('planner')
    }
  }, [mode, showTeam, onModeChange])

  const avatarLabel = userProfile?.connected
    ? userProfile.displayName
    : t('rail.user')
  const avatarInitials = userProfile?.connected
    ? userProfile.initials || initialsFor(userProfile.displayName)
    : ''
  const avatarUrl = userProfile?.connected && userProfile.userAvatarUrl
    ? userProfile.userAvatarUrl
    : ''
  const showFallbackUserIcon = !avatarUrl && !avatarInitials

  return (
    <nav className="workspace-rail" aria-label={t('rail.workspace')}>
      <div className="workspace-rail__top">
        <button
          type="button"
          className={`workspace-rail__avatar${avatarUrl ? ' has-image' : ''}${showFallbackUserIcon ? ' has-user-icon' : ''}`}
          title={t('rail.settings')}
          aria-label={avatarLabel}
          onClick={() => onModeChange('settings')}
        >
          {avatarUrl ? <img src={avatarUrl} alt="" /> : showFallbackUserIcon ? <User size={20} /> : avatarInitials}
        </button>
      </div>

      <div className="workspace-rail__group">
        <RailButton
          label={t('rail.session')}
          active={mode === 'session'}
          onClick={() => onModeChange('session')}
        >
          <Terminal size={20} />
        </RailButton>
        <RailButton
          label={t('rail.planner')}
          active={mode === 'planner'}
          onClick={() => onModeChange('planner')}
        >
          <Network size={20} />
        </RailButton>
        <RailButton
          label={t('rail.templates')}
          active={mode === 'templates'}
          onClick={() => onModeChange('templates')}
        >
          <LayoutTemplate size={20} />
        </RailButton>
        <RailButton
          label={t('rail.artifacts')}
          active={mode === 'artifacts'}
          onClick={() => onModeChange('artifacts')}
        >
          <Archive size={20} />
        </RailButton>
        {showTeam && (
          <RailButton
            label={t('rail.team')}
            active={mode === 'team'}
            onClick={() => onModeChange('team')}
          >
            <UsersRound size={20} />
          </RailButton>
        )}
        <RailButton
          label={t('rail.integrations')}
          active={mode === 'integrations'}
          onClick={() => onModeChange('integrations')}
        >
          <Cable size={20} />
        </RailButton>
      </div>

      <div className="workspace-rail__spacer" />

      <RailButton label={t('rail.settings')} active={mode === 'settings'} onClick={() => onModeChange('settings')}>
        <Settings size={20} />
      </RailButton>
    </nav>
  )
}

function initialsFor(value: string): string {
  const name = value.trim() || 'MEEE2'
  const words = name.split(/\s+/).filter(Boolean)
  if (words.length >= 2) return `${words[0][0]}${words[1][0]}`.toUpperCase()
  return name.slice(0, 2).toUpperCase()
}

interface RailButtonProps {
  label: string
  active?: boolean
  tone?: 'default' | 'attention' | 'danger'
  onClick: () => void
  children: ReactNode
}

function RailButton({
  label,
  active = false,
  tone = 'default',
  onClick,
  children,
}: RailButtonProps) {
  return (
    <button
      type="button"
      className={`workspace-rail__button${active ? ' is-active' : ''}`}
      data-tone={tone}
      title={label}
      aria-label={label}
      aria-current={active ? 'page' : undefined}
      onClick={onClick}
    >
      {children}
      <span className="workspace-rail__label">{label}</span>
    </button>
  )
}
