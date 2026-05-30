/**
 * CardShell — shared chrome for every MonitorSpec card.
 *
 * Renders the card title bar + collapse toggle and wraps the card body. The
 * collapsed state is *local UI* (§6.5) — persisted per `canvasId+cardId` in
 * localStorage by `MonitorGrid`, seeded from `layout.collapsed`. The shell
 * itself is presentational; the host owns the collapsed boolean + toggle.
 */

import type { ReactNode } from 'react'
import { ChevronDown, ChevronRight } from 'lucide-react'
import { PENDING_BACKEND_HINT } from './cardTypes'

export interface CardShellProps {
  title: string
  /** Optional badge text shown right of the title (e.g. a count or window). */
  badge?: string
  collapsed: boolean
  onToggleCollapsed: () => void
  children: ReactNode
}

export function CardShell({ title, badge, collapsed, onToggleCollapsed, children }: CardShellProps) {
  return (
    <section className="monitor-card">
      <header className="monitor-card__header">
        <button
          type="button"
          className="monitor-card__collapse"
          onClick={onToggleCollapsed}
          aria-expanded={!collapsed}
          aria-label={collapsed ? '展开卡片' : '收起卡片'}
        >
          {collapsed ? <ChevronRight size={14} aria-hidden /> : <ChevronDown size={14} aria-hidden />}
        </button>
        <span className="monitor-card__title">{title}</span>
        {badge && <span className="monitor-card__badge">{badge}</span>}
      </header>
      {!collapsed && <div className="monitor-card__body">{children}</div>}
    </section>
  )
}

/**
 * CardPending — the canonical empty/placeholder body for data the backend
 * does not yet provide. Never fabricates numbers; states plainly what will
 * appear once wiring lands.
 */
export function CardPending({ what }: { what: string }) {
  return (
    <div className="monitor-card__pending">
      <p className="monitor-card__pending-what">{what}</p>
      <p className="monitor-card__pending-hint">{PENDING_BACKEND_HINT}</p>
    </div>
  )
}

/** CardEmpty — a card whose config resolved but produced zero rows. */
export function CardEmpty({ message }: { message: string }) {
  return <div className="monitor-card__empty">{message}</div>
}
