import {
  Network,
  Radar,
  Settings,
} from 'lucide-react'
import { type ReactNode, useEffect, useMemo } from 'react'
import { WORKING_STATUSES } from '../notifications'
import type { BoardState, CanvasInfo } from '../types'

export type WorkspaceMode = 'planner' | 'monitor'

interface WorkspaceRailProps {
  state: BoardState | null
  canvases: CanvasInfo[]
  activeCanvasId: string
  mode: WorkspaceMode
  unreadSids: Set<string>
  onModeChange: (mode: WorkspaceMode) => void
  onPreferences: () => void
}

const RAIL_WIDTH = 64

export function WorkspaceRail({
  state,
  canvases,
  activeCanvasId,
  mode,
  onModeChange,
  onPreferences,
}: WorkspaceRailProps) {
  useEffect(() => {
    document.documentElement.style.setProperty('--sidebar-width', `${RAIL_WIDTH}px`)
    document.documentElement.classList.add('board-sidebar-rail')
    document.documentElement.classList.remove('board-sidebar-collapsed')
    return () => {
      document.documentElement.style.removeProperty('--sidebar-width')
      document.documentElement.classList.remove('board-sidebar-rail')
    }
  }, [])

  const activeCanvas = canvases.find((canvas) => canvas.id === activeCanvasId)
  const canvasInitial = useMemo(() => {
    const name = displayCanvasName(activeCanvas).trim() || 'MEEE2'
    const words = name.split(/\s+/).filter(Boolean)
    if (words.length >= 2) return `${words[0][0]}${words[1][0]}`.toUpperCase()
    return name.slice(0, 2).toUpperCase()
  }, [activeCanvas?.name])

  const counts = useMemo(() => {
    const sessions = state?.sessions ?? []
    return {
      attention: sessions.filter((session) =>
        session.status === 'permissionRequired' || session.status === 'waitingForUser',
      ).length,
    }
  }, [state?.sessions])

  return (
    <nav className="workspace-rail" aria-label="Workspace">
      <button
        type="button"
        className="workspace-rail__avatar"
        title={displayCanvasName(activeCanvas)}
        aria-label={displayCanvasName(activeCanvas)}
      >
        {canvasInitial}
      </button>

      <div className="workspace-rail__group">
        <RailButton
          label="Planner"
          active={mode === 'planner'}
          onClick={() => onModeChange('planner')}
          badge={counts.attention > 0 ? counts.attention : undefined}
          tone={counts.attention > 0 ? 'attention' : 'default'}
        >
          <Network size={20} />
        </RailButton>
        <RailButton
          label="Monitor"
          active={mode === 'monitor'}
          onClick={() => onModeChange('monitor')}
        >
          <Radar size={20} />
        </RailButton>
      </div>

      <div className="workspace-rail__spacer" />

      <RailButton label="Preferences" onClick={onPreferences}>
        <Settings size={20} />
      </RailButton>
    </nav>
  )
}

function displayCanvasName(canvas: CanvasInfo | undefined): string {
  if (!canvas) return 'Canvas'
  return canvas.name === 'Default canvas' ? 'My' : canvas.name
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
      {badge !== undefined && badge > 0 && (
        <span className="workspace-rail__badge">{badge > 99 ? '99+' : badge}</span>
      )}
    </button>
  )
}
