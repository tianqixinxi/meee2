import {
  Activity,
  Cable,
  Archive,
  LayoutTemplate,
  Network,
  Settings,
  Terminal,
  UsersRound,
} from 'lucide-react'
import { type ReactNode, useEffect } from 'react'
import type { UserProfile } from '../api'
import { useI18n } from '../lib/i18n'
import { Tooltip } from './Tooltip'
import meee2AppIcon from '../../../../Resources/AppIcon.iconset/icon_32x32@2x.png'

export type WorkspaceMode = 'session' | 'planner' | 'monitor' | 'templates' | 'artifacts' | 'team' | 'integrations' | 'settings'

interface WorkspaceRailProps {
  mode: WorkspaceMode
  userProfile: UserProfile | null
  onModeChange: (mode: WorkspaceMode) => void
  /** Session 按钮语义特殊：它同时控制会话列表 flyout，而不只是切页。 */
  onSessionClick?: () => void
  onSessionHover?: () => void
}

export function WorkspaceRail({
  mode,
  userProfile,
  onModeChange,
  onSessionClick,
  onSessionHover,
}: WorkspaceRailProps) {
  const { t } = useI18n()
  const showTeam = Boolean(userProfile?.connected)
  const showAvatarShortcut = Boolean(userProfile?.connected)

  useEffect(() => {
    if (mode === 'team' && !showTeam) {
      onModeChange('planner')
    }
  }, [mode, showTeam, onModeChange])

  const avatarLabel = userProfile?.displayName || t('rail.settings')
  const avatarInitials = userProfile?.connected
    ? userProfile.initials || initialsFor(userProfile.displayName)
    : ''
  const avatarUrl = userProfile?.connected && userProfile.userAvatarUrl
    ? userProfile.userAvatarUrl
    : ''
  const showFallbackUserIcon = !avatarUrl && !avatarInitials

  return (
    <nav
      className="workspace-rail"
      aria-label={t('rail.workspace')}
    >
      <div className="workspace-rail__top">
        <div className="workspace-rail__brand" data-testid="workspace-rail-brand" aria-label="Meee2">
          <img className="workspace-rail__brand-mark" src={meee2AppIcon} alt="" aria-hidden />
        </div>
        {showAvatarShortcut && (
          <Tooltip label={t('rail.settings')} placement="right" delay={120}>
            <button
              type="button"
              className={`workspace-rail__avatar${avatarUrl ? ' has-image' : ''}${showFallbackUserIcon ? ' has-user-icon' : ''}`}
              aria-label={avatarLabel}
              onClick={() => onModeChange('settings')}
            >
              {avatarUrl ? <img src={avatarUrl} alt="" /> : avatarInitials}
            </button>
          </Tooltip>
        )}
      </div>

      <div className="workspace-rail__group">
        <RailButton
          label={t('rail.session')}
          active={mode === 'session'}
          onClick={() => (onSessionClick ? onSessionClick() : onModeChange('session'))}
          onHover={onSessionHover}
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
          label={t('rail.monitor')}
          active={mode === 'monitor'}
          onClick={() => onModeChange('monitor')}
        >
          <Activity size={20} />
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
  onHover?: () => void
  children: ReactNode
}

function RailButton({
  label,
  active = false,
  tone = 'default',
  onClick,
  onHover,
  children,
}: RailButtonProps) {
  return (
    <Tooltip label={label} placement="right" delay={120}>
      <button
        type="button"
        className={`workspace-rail__button${active ? ' is-active' : ''}`}
        data-tone={tone}
        aria-label={label}
        aria-current={active ? 'page' : undefined}
        onClick={onClick}
        onMouseEnter={onHover}
      >
        {children}
        <span className="workspace-rail__label">{label}</span>
      </button>
    </Tooltip>
  )
}
