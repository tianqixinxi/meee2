import { AlertTriangle, CheckCircle2, Clock3, GitPullRequestArrow, List, PlayCircle, Route, Signpost } from 'lucide-react'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { fetchPlannerWorkspaceMonitor } from '../../api'
import { useI18n } from '../../lib/i18n'
import type { CanvasInfo, NodeRunState, PlannerMonitorState } from '../../types'
import './planner.css'

const stateIcons: Partial<Record<NodeRunState, typeof AlertTriangle>> = {
  blocked: AlertTriangle,
  working: PlayCircle,
  draft: Route,
  ready: Clock3,
  done: CheckCircle2,
}

interface WorkspaceMonitorProps {
  activeCanvasId: string
  canvases: CanvasInfo[]
  onOpenCanvas: (canvasId: string) => void
  onOpenAllSessions: () => void
}

export function WorkspaceMonitor({
  activeCanvasId,
  canvases,
  onOpenCanvas,
  onOpenAllSessions,
}: WorkspaceMonitorProps) {
  const { t } = useI18n()
  const [monitor, setMonitor] = useState<PlannerMonitorState | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [query, setQuery] = useState('')
  const activeCanvasName = monitorCanvasName(canvases.find((canvas) => canvas.id === activeCanvasId)?.name ?? t('monitor.title'))

  const loadMonitor = useCallback(() => {
    setError(null)
    fetchPlannerWorkspaceMonitor()
      .then(setMonitor)
      .catch((err) => setError((err as Error).message || t('monitor.loadFailed')))
  }, [t])

  useEffect(() => {
    loadMonitor()
  }, [loadMonitor])

  const groups = useMemo(() => {
    const term = query.trim().toLowerCase()
    const items = (monitor?.items ?? []).filter((item) => {
      if (!term) return true
      return [
        item.summary,
        item.canvasTitle,
        item.nodeTitle ?? '',
        item.nextAction ?? '',
      ].some((value) => value.toLowerCase().includes(term))
    })
    return [
      { key: 'delivery', label: t('monitor.deliveries'), items: items.filter((item) => item.kind === 'delivery') },
      { key: 'risk', label: t('monitor.blocked'), items: items.filter((item) => item.riskRank <= 1) },
      { key: 'active', label: t('monitor.workingDraft'), items: items.filter((item) => item.riskRank === 2 || item.riskRank === 3) },
      { key: 'ready', label: t('monitor.ready'), items: items.filter((item) => item.riskRank >= 4) },
    ]
  }, [monitor, query, t])

  return (
    <section className="planner-monitor" aria-label={t('monitor.title')}>
      <div className="planner-monitor__body">
        <div className="planner-monitor__tools">
          <div className="planner-monitor__search">
            <input
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder={t('monitor.searchPlaceholder')}
              aria-label={t('monitor.searchLabel')}
            />
          </div>
          <button
            type="button"
            className="planner-monitor__sessions-button"
            onClick={onOpenAllSessions}
            title={t('monitor.openSessions')}
          >
            <List size={13} aria-hidden />
            <span>{t('monitor.openSessions')}</span>
          </button>
        </div>
        {error && <div className="planner-proposal-panel__error">{error}</div>}
        {!monitor && !error ? (
          <div className="planner-empty-state">
            <div className="boot-spinner" />
            <span>{t('monitor.loading')}</span>
          </div>
        ) : (
          groups.map((group) => (
            <section key={group.key} className="planner-monitor__group">
              <div className="planner-monitor__group-header">
                <h2>{group.label}</h2>
                <span>{group.items.length}</span>
              </div>
              <div className="planner-monitor__items">
                {group.items.map((item) => {
                  const Icon = item.kind === 'proposal'
                    ? GitPullRequestArrow
                    : stateIcons[item.runState ?? 'ready'] ?? Clock3
                  return (
                    <button
                      key={item.id}
                      type="button"
                      className={`planner-monitor-item planner-monitor-item--rank-${item.riskRank}`}
                      onClick={() => onOpenCanvas(item.canvasId)}
                      aria-label={`${t('monitor.openCanvas')}: ${item.nodeTitle ?? item.summary}`}
                      title={`${t('monitor.openCanvas')}: ${item.canvasTitle}`}
                    >
                      <div className="planner-monitor-item__icon">
                        <Icon size={15} aria-hidden />
                      </div>
                      <div className="planner-monitor-item__main">
                        <div className="planner-monitor-item__meta">
                          <span>{monitorCanvasName(item.canvasTitle)}</span>
                          <span>{item.kind}</span>
                          {item.runState && <span>{item.runState}</span>}
                          {item.proposalStatus && <span>{item.proposalStatus}</span>}
                        </div>
                        <h3>{item.nodeTitle ?? item.summary}</h3>
                        {item.blockers.length > 0 && (
                          <p>{item.blockers.join('; ')}</p>
                        )}
                        {item.nextAction && (
                          <p className="planner-monitor-item__next-action">
                            <Signpost size={11} aria-hidden />
                            <span>{item.nextAction}</span>
                          </p>
                        )}
                      </div>
                      <div className="planner-monitor-item__side">
                        {item.doerId && <span>{item.doerId}</span>}
                      </div>
                    </button>
                  )
                })}
                {group.items.length === 0 && (
                  <div className="planner-monitor__empty">{activeCanvasName}: {t('monitor.empty')}</div>
                )}
              </div>
            </section>
          ))
        )}
      </div>
    </section>
  )
}

function monitorCanvasName(name: string): string {
  return name === 'Default canvas' ? 'Monitor' : name
}
