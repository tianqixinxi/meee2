import {
  Cable,
  Archive,
  LayoutTemplate,
  List,
  Network,
  PanelLeftClose,
  PanelLeftOpen,
  Settings,
  User,
  UsersRound,
} from 'lucide-react'
import { type ReactNode, useEffect, useMemo } from 'react'
import { WORKING_STATUSES } from '../notifications'
import type { BoardState, CanvasInfo } from '../types'
import type { UserProfile } from '../api'
import { useI18n } from '../lib/i18n'

export type WorkspaceMode = 'planner' | 'templates' | 'sessions' | 'artifacts' | 'team' | 'integrations' | 'settings'

interface WorkspaceRailProps {
  state: BoardState | null
  canvases: CanvasInfo[]
  activeCanvasId: string
  mode: WorkspaceMode
  unreadSids: Set<string>
  userProfile: UserProfile | null
  collapsed: boolean
  onCollapsedChange: (collapsed: boolean) => void
  onModeChange: (mode: WorkspaceMode) => void
}

const RAIL_WIDTH = 208
const RAIL_COLLAPSED_WIDTH = 52

export function WorkspaceRail({
  state,
  mode,
  unreadSids,
  userProfile,
  collapsed,
  onCollapsedChange,
  onModeChange,
}: WorkspaceRailProps) {
  const { t } = useI18n()
  useEffect(() => {
    document.documentElement.style.setProperty('--sidebar-width', `${collapsed ? RAIL_COLLAPSED_WIDTH : RAIL_WIDTH}px`)
    document.documentElement.classList.add('board-sidebar-rail')
    document.documentElement.classList.toggle('board-sidebar-collapsed', collapsed)
    return () => {
      document.documentElement.style.removeProperty('--sidebar-width')
      document.documentElement.classList.remove('board-sidebar-rail')
      document.documentElement.classList.remove('board-sidebar-collapsed')
    }
  }, [collapsed])

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

  const hasSessionAttention = useMemo(() => {
    const sessions = state?.sessions ?? []
    return sessions.some((session) => sessionNeedsAttention(session) || unreadSids.has(session.id))
  }, [state?.sessions, unreadSids])

  return (
    <nav className={`workspace-rail${collapsed ? ' is-collapsed' : ''}`} aria-label={t('rail.workspace')}>
      <div className="workspace-rail__top">
        <button
          type="button"
          className={`workspace-rail__avatar${avatarUrl ? ' has-image' : ''}${showFallbackUserIcon ? ' has-user-icon' : ''}`}
          title={avatarLabel}
          aria-label={avatarLabel}
        >
          {avatarUrl ? <img src={avatarUrl} alt="" /> : showFallbackUserIcon ? <User size={20} /> : avatarInitials}
        </button>
        <button
          type="button"
          className="workspace-rail__collapse"
          aria-label={collapsed ? t('rail.expand') : t('rail.collapse')}
          title={collapsed ? t('rail.expand') : t('rail.collapse')}
          onClick={() => onCollapsedChange(!collapsed)}
        >
          {collapsed ? <PanelLeftOpen size={16} aria-hidden /> : <PanelLeftClose size={16} aria-hidden />}
        </button>
      </div>

      <div className="workspace-rail__group">
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
          label={t('rail.sessions')}
          active={mode === 'sessions'}
          onClick={() => onModeChange('sessions')}
          tone={hasSessionAttention ? 'attention' : 'default'}
        >
          <List size={20} />
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

function sessionNeedsAttention(session: { status: string; inboxPending: number; pendingPermissionTool?: string | null }): boolean {
  return session.status === 'permissionRequired'
    || session.status === 'waitingForUser'
    || session.inboxPending > 0
    || Boolean(session.pendingPermissionTool)
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
