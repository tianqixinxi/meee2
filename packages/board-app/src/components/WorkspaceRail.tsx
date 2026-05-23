import {
  Cable,
  Archive,
  LayoutTemplate,
  List,
  Network,
  PanelLeftClose,
  PanelLeftOpen,
  Radar,
  Settings,
  User,
  UsersRound,
} from 'lucide-react'
import { type ReactNode, useEffect, useMemo } from 'react'
import { WORKING_STATUSES } from '../notifications'
import type { BoardState, CanvasInfo } from '../types'
import type { UserProfile } from '../api'

export type WorkspaceMode = 'planner' | 'templates' | 'sessions' | 'artifacts' | 'monitor' | 'team' | 'integrations'

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
  onPreferences: () => void
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
  onPreferences,
}: WorkspaceRailProps) {
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
    : 'User'
  const avatarInitials = userProfile?.connected
    ? userProfile.initials || initialsFor(userProfile.displayName)
    : ''
  const avatarUrl = userProfile?.connected && userProfile.userAvatarUrl
    ? userProfile.userAvatarUrl
    : ''
  const showFallbackUserIcon = !avatarUrl && !avatarInitials

  const counts = useMemo(() => {
    const sessions = state?.sessions ?? []
    const actionableSessionIds = new Set<string>()
    for (const session of sessions) {
      if (sessionNeedsAttention(session) || unreadSids.has(session.id)) {
        actionableSessionIds.add(session.id)
      }
    }
    return {
      sessions: actionableSessionIds.size,
    }
  }, [state?.sessions, unreadSids])

  return (
    <nav className={`workspace-rail${collapsed ? ' is-collapsed' : ''}`} aria-label="Workspace">
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
          aria-label={collapsed ? 'Expand workspace rail' : 'Collapse workspace rail'}
          title={collapsed ? 'Expand sidebar' : 'Collapse sidebar'}
          onClick={() => onCollapsedChange(!collapsed)}
        >
          {collapsed ? <PanelLeftOpen size={16} aria-hidden /> : <PanelLeftClose size={16} aria-hidden />}
        </button>
      </div>

      <div className="workspace-rail__group">
        <RailButton
          label="meee2 AI"
          active={mode === 'planner'}
          onClick={() => onModeChange('planner')}
        >
          <Network size={20} />
        </RailButton>
        <RailButton
          label="Templates"
          active={mode === 'templates'}
          onClick={() => onModeChange('templates')}
        >
          <LayoutTemplate size={20} />
        </RailButton>
        <RailButton
          label="Sessions"
          active={mode === 'sessions'}
          onClick={() => onModeChange('sessions')}
          badge={counts.sessions > 0 ? counts.sessions : undefined}
          tone={counts.sessions > 0 ? 'attention' : 'default'}
        >
          <List size={20} />
        </RailButton>
        <RailButton
          label="Artifacts"
          active={mode === 'artifacts'}
          onClick={() => onModeChange('artifacts')}
        >
          <Archive size={20} />
        </RailButton>
        <RailButton
          label="Monitor"
          active={mode === 'monitor'}
          onClick={() => onModeChange('monitor')}
        >
          <Radar size={20} />
        </RailButton>
        {showTeam && (
          <RailButton
            label="Team"
            active={mode === 'team'}
            onClick={() => onModeChange('team')}
          >
            <UsersRound size={20} />
          </RailButton>
        )}
        <RailButton
          label="Integrations"
          active={mode === 'integrations'}
          onClick={() => onModeChange('integrations')}
        >
          <Cable size={20} />
        </RailButton>
      </div>

      <div className="workspace-rail__spacer" />

      <RailButton label="Settings" onClick={onPreferences}>
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
  badge?: number
  tone?: 'default' | 'attention' | 'danger'
  onClick: () => void
  children: ReactNode
}

function RailButton({
  label,
  active = false,
  badge,
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
      {badge !== undefined && badge > 0 && (
        <span className="workspace-rail__badge">{badge > 99 ? '99+' : badge}</span>
      )}
    </button>
  )
}
