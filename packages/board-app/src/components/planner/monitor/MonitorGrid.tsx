/**
 * MonitorGrid (§6.7) — the canvas monitor card grid.
 *
 * Renders `spec.cards.map(card => Registry[card.type] ?? UnknownCardFallback)`
 * onto a 12-column CSS grid positioned from each card's `layout`
 * (col/row/width/height). It is the ONLY place that knows about flag gating,
 * collapse persistence, and the discriminated-union narrowing — the cards
 * themselves stay pure.
 *
 * Gating:
 *   - The whole grid is behind `canvas.monitor.v2` (CANVAS_MONITOR_V2). When
 *     off, renders nothing.
 *   - `cadence-reminder` (PM-addon) requires `CANVAS_PM_ADDON`.
 *   Gated-out cards are skipped (not faulted) so a spec authored on a
 *   feature-richer canvas still renders its visible subset.
 *
 * Local UI state (§6.5):
 *   - `collapsed` per card is persisted to localStorage keyed by
 *     `canvasId+cardId`, seeded from `layout.collapsed`. Toggling is execution,
 *     never a proposal.
 */

import { useCallback, useState } from 'react'
import type {
  MonitorCard,
  MonitorSpec,
  NodeStateSnapshot,
  PlannerArtifact,
  PlanningNode,
} from '../../../types'
import { buildMonitorCardContext } from './cardTypes'
import { CardShell } from './CardShell'
import { CANVAS_MONITOR_V2, CANVAS_PM_ADDON } from './flags'
import { MONITOR_CARD_REGISTRY, PM_ADDON_CARD_KINDS } from './registry'
import { UnknownCardFallback } from './UnknownCardFallback'

export interface MonitorGridProps {
  spec: MonitorSpec | null | undefined
  nodes: PlanningNode[]
  states: NodeStateSnapshot[]
  artifacts: PlannerArtifact[]
  viewerId?: string | null
}

const COLLAPSE_PREFIX = 'meee2.monitor.collapsed.'

function collapseKey(canvasId: string, cardId: string): string {
  return `${COLLAPSE_PREFIX}${canvasId}.${cardId}`
}

function readCollapsed(canvasId: string, card: MonitorCard): boolean {
  try {
    const raw = window.localStorage.getItem(collapseKey(canvasId, card.id))
    if (raw === '1') return true
    if (raw === '0') return false
  } catch {
    /* ignore */
  }
  return card.layout.collapsed ?? false
}

function writeCollapsed(canvasId: string, cardId: string, collapsed: boolean): void {
  try {
    window.localStorage.setItem(collapseKey(canvasId, cardId), collapsed ? '1' : '0')
  } catch {
    /* private mode / quota */
  }
}

// Whole-panel collapse — anchored at the bottom of the canvas, the panel can be
// folded down to just its bar so it never eats canvas real estate. Persisted
// per canvas. Default collapsed so the canvas opens unobstructed.
const PANEL_PREFIX = 'meee2.monitor.panel.'

function readPanelCollapsed(canvasId: string): boolean {
  try {
    const raw = window.localStorage.getItem(`${PANEL_PREFIX}${canvasId}`)
    if (raw === '1') return true
    if (raw === '0') return false
  } catch {
    /* ignore */
  }
  return true // default folded
}

function writePanelCollapsed(canvasId: string, collapsed: boolean): void {
  try {
    window.localStorage.setItem(`${PANEL_PREFIX}${canvasId}`, collapsed ? '1' : '0')
  } catch {
    /* ignore */
  }
}

/** Is this card kind currently renderable given the active feature flags? */
function cardKindEnabled(type: MonitorCard['type']): boolean {
  if (PM_ADDON_CARD_KINDS.has(type) && !CANVAS_PM_ADDON) return false
  return true
}

export function MonitorGrid({ spec, nodes, states, artifacts, viewerId }: MonitorGridProps) {
  // Collapsed state per cardId, lazily seeded from localStorage / layout.
  const [collapsedMap, setCollapsedMap] = useState<Record<string, boolean>>({})
  // Whole-panel folded state, keyed by canvasId (lazy from localStorage).
  const [panelMap, setPanelMap] = useState<Record<string, boolean>>({})

  const togglePanel = useCallback((canvasId: string) => {
    setPanelMap((prev) => {
      const current = canvasId in prev ? prev[canvasId] : readPanelCollapsed(canvasId)
      const next = !current
      writePanelCollapsed(canvasId, next)
      return { ...prev, [canvasId]: next }
    })
  }, [])

  const toggleCollapsed = useCallback(
    (canvasId: string, card: MonitorCard) => {
      setCollapsedMap((prev) => {
        const current = card.id in prev ? prev[card.id] : readCollapsed(canvasId, card)
        const next = !current
        writeCollapsed(canvasId, card.id, next)
        return { ...prev, [card.id]: next }
      })
    },
    [],
  )

  if (!CANVAS_MONITOR_V2 || !spec) return null

  const ctx = buildMonitorCardContext({
    canvasId: spec.canvasId,
    nodes,
    states,
    artifacts,
    viewerId,
  })

  const renderable = spec.cards.filter((c) => cardKindEnabled(c.type))

  if (renderable.length === 0) return null

  const panelCollapsed = spec.canvasId in panelMap ? panelMap[spec.canvasId] : readPanelCollapsed(spec.canvasId)

  return (
    <div
      className={`monitor-panel${panelCollapsed ? ' monitor-panel--collapsed' : ''}`}
      role="region"
      aria-label="画板监控"
    >
      <button
        type="button"
        className="monitor-panel__bar"
        onClick={() => togglePanel(spec.canvasId)}
        aria-expanded={!panelCollapsed}
      >
        <span className="monitor-panel__chevron" aria-hidden>{panelCollapsed ? '▴' : '▾'}</span>
        <span className="monitor-panel__title">画板监控</span>
        <span className="monitor-panel__count">{renderable.length}</span>
      </button>
      {!panelCollapsed && (
    <div className="monitor-grid" role="group" aria-label="监控卡片">
      {renderable.map((card) => {
        const collapsed = card.id in collapsedMap ? collapsedMap[card.id] : readCollapsed(spec.canvasId, card)
        const { col, row, width, height } = card.layout
        const style = {
          gridColumn: `${col + 1} / span ${Math.min(12, Math.max(1, width))}`,
          gridRow: `${row + 1} / span ${Math.max(1, height)}`,
        }
        const Comp = MONITOR_CARD_REGISTRY[card.type] ?? null
        const title = card.title ?? card.type

        return (
          <div key={card.id} className="monitor-grid__cell" style={style}>
            {Comp ? (
              <CardShell
                title={title}
                collapsed={collapsed}
                onToggleCollapsed={() => toggleCollapsed(spec.canvasId, card)}
              >
                {/* card.config is pre-narrowed by the discriminated union; the
                 *  registry component for this `type` consumes exactly that
                 *  config shape. The cast bridges the loosely-typed registry
                 *  map back to the concrete card props. */}
                <Comp card={card} config={card.config} ctx={ctx} />
              </CardShell>
            ) : (
              <UnknownCardFallback card={card} />
            )}
          </div>
        )
      })}
    </div>
      )}
    </div>
  )
}
