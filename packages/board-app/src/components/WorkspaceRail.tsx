import {
  Cable,
  Archive,
  LayoutTemplate,
  Network,
  Settings,
  Terminal,
  UsersRound,
} from 'lucide-react'
import { type ReactNode, useEffect, useLayoutEffect } from 'react'
import type { CanvasInfo } from '../types'
import type { UserProfile } from '../api'
import { useI18n } from '../lib/i18n'
import { Tooltip } from './Tooltip'
import meee2AppIcon from '../../../../Resources/AppIcon.iconset/icon_32x32@2x.png'

export type WorkspaceMode = 'session' | 'planner' | 'templates' | 'artifacts' | 'team' | 'integrations' | 'settings'

interface WorkspaceRailProps {
  canvases: CanvasInfo[]
  activeCanvasId: string
  mode: WorkspaceMode
  userProfile: UserProfile | null
  onModeChange: (mode: WorkspaceMode) => void
  detailRef?: (node: HTMLDivElement | null) => void
}

const EXPANDED_RAIL_WIDTH = 320
const COMPACT_RAIL_WIDTH = 72

export function WorkspaceRail({
  mode,
  userProfile,
  onModeChange,
  detailRef,
}: WorkspaceRailProps) {
  const { t } = useI18n()
  const compact = mode !== 'session'
  const railWidth = compact ? COMPACT_RAIL_WIDTH : EXPANDED_RAIL_WIDTH

  useLayoutEffect(() => {
    document.documentElement.style.setProperty('--sidebar-width', `${railWidth}px`)
    document.documentElement.classList.add('board-sidebar-rail')
    document.documentElement.classList.toggle('board-sidebar-rail--compact', compact)
    return () => {
      document.documentElement.style.removeProperty('--sidebar-width')
      document.documentElement.classList.remove('board-sidebar-rail')
      document.documentElement.classList.remove('board-sidebar-rail--compact')
    }
  }, [compact, railWidth])

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
    <nav className={`workspace-rail${compact ? ' workspace-rail--compact' : ''}`} aria-label={t('rail.workspace')}>
      <div className="workspace-rail__top">
        <div className="workspace-rail__brand" data-testid="workspace-rail-brand" aria-label="Meee2">
          {compact
            ? <img className="workspace-rail__brand-mark" src={meee2AppIcon} alt="" aria-hidden />
            : <strong className="workspace-rail__brand-name">Meee2</strong>}
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

      <div ref={detailRef} className="workspace-rail__detail" data-testid="workspace-rail-detail" />

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
      aria-label={label}
      aria-current={active ? 'page' : undefined}
      onClick={onClick}
    >
      {children}
      <span className="workspace-rail__label">{label}</span>
    </button>
  )
}
