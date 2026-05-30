/**
 * DataSourceRail (Atom 1) — read-only "数据源" rail on the canvas.
 *
 * Renders each `canvas.dataSources` entry as a compact cylinder-style chip
 * (title + partition badge + version). Positioning choice: a left-anchored,
 * collapsible rail rather than free-floating ReactFlow nodes — DataSources are
 * canvas-level addressable locations not tied to a single node position, and
 * the wire payload doesn't carry a node-anchor, so a rail reads as intentional
 * without guessing coordinates. Renders nothing when there are no dataSources,
 * so legacy canvases are visually unchanged.
 *
 * Style follows the monitor-panel conventions in planner.css (blurred elevated
 * panel, foldable bar, count pill).
 */

import { useState } from 'react'
import { Database } from 'lucide-react'
import type { DataSourceRecord } from '../../types'

export interface DataSourceRailProps {
  canvasId: string
  dataSources: DataSourceRecord[] | undefined
}

/** Partition rule → compact badge. `none` / absent / unknown → no badge. */
function partitionBadge(rule: DataSourceRecord['partitionRule']): string | null {
  switch (rule) {
    case 'iso-week': return '周'
    case 'day': return '日'
    case 'month': return '月'
    case 'fiscal-quarter': return '季'
    case 'custom': return '自定义'
    default: return null
  }
}

const RAIL_PREFIX = 'meee2.datasource.rail.'

function readCollapsed(canvasId: string): boolean {
  try {
    const raw = window.localStorage.getItem(`${RAIL_PREFIX}${canvasId}`)
    if (raw === '1') return true
    if (raw === '0') return false
  } catch {
    /* ignore */
  }
  return false // default open — the rail is compact and informative
}

function writeCollapsed(canvasId: string, collapsed: boolean): void {
  try {
    window.localStorage.setItem(`${RAIL_PREFIX}${canvasId}`, collapsed ? '1' : '0')
  } catch {
    /* private mode / quota */
  }
}

export function DataSourceRail({ canvasId, dataSources }: DataSourceRailProps) {
  const [collapsed, setCollapsed] = useState<boolean | null>(null)
  const isCollapsed = collapsed ?? readCollapsed(canvasId)

  if (!dataSources || dataSources.length === 0) return null

  const toggle = () => {
    const next = !isCollapsed
    writeCollapsed(canvasId, next)
    setCollapsed(next)
  }

  return (
    <div
      className={`datasource-rail${isCollapsed ? ' datasource-rail--collapsed' : ''}`}
      role="region"
      aria-label="数据源"
    >
      <button
        type="button"
        className="datasource-rail__bar"
        onClick={toggle}
        aria-expanded={!isCollapsed}
      >
        <Database size={13} aria-hidden />
        <span className="datasource-rail__title">数据源</span>
        <span className="datasource-rail__count">{dataSources.length}</span>
        <span className="datasource-rail__chevron" aria-hidden>{isCollapsed ? '▸' : '▾'}</span>
      </button>
      {!isCollapsed && (
        <ul className="datasource-rail__list" role="list">
          {dataSources.map((source) => {
            const badge = partitionBadge(source.partitionRule)
            return (
              <li key={source.id} className="datasource-chip" title={`${source.title} · ${source.kind}`}>
                <span className="datasource-chip__cylinder" aria-hidden>
                  <Database size={14} />
                </span>
                <span className="datasource-chip__body">
                  <span className="datasource-chip__title">{source.title}</span>
                  <span className="datasource-chip__meta">
                    {badge && <span className="datasource-chip__partition">{badge}</span>}
                    <span className="datasource-chip__version">v{source.currentVersion}</span>
                  </span>
                </span>
              </li>
            )
          })}
        </ul>
      )}
    </div>
  )
}
