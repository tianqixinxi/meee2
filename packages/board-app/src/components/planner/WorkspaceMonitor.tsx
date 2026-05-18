import { AlertTriangle, CheckCircle2, Clock3, GitPullRequestArrow, PlayCircle, Route, Signpost } from 'lucide-react'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { fetchPlannerWorkspaceMonitor } from '../../api'
import type { NodeRunState, PlannerMonitorState } from '../../types'
import './planner.css'

const stateIcons: Partial<Record<NodeRunState, typeof AlertTriangle>> = {
  blocked: AlertTriangle,
  running: PlayCircle,
  planning: Route,
  waiting: Clock3,
  done: CheckCircle2,
}

export function WorkspaceMonitor() {
  const [monitor, setMonitor] = useState<PlannerMonitorState | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [query, setQuery] = useState('')

  const loadMonitor = useCallback(() => {
    setError(null)
    fetchPlannerWorkspaceMonitor()
      .then(setMonitor)
      .catch((err) => setError((err as Error).message || 'Failed to load meee2 AI monitor'))
  }, [])

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
      { key: 'delivery', label: 'Deliveries', items: items.filter((item) => item.kind === 'delivery') },
      { key: 'risk', label: 'Blocked / Review', items: items.filter((item) => item.riskRank <= 1) },
      { key: 'active', label: 'Running / Planning', items: items.filter((item) => item.riskRank === 2 || item.riskRank === 3) },
      { key: 'waiting', label: 'Waiting', items: items.filter((item) => item.riskRank >= 4) },
    ]
  }, [monitor, query])

  return (
    <section className="planner-monitor" aria-label="Workspace monitor">
      <div className="planner-monitor__body">
        <div className="planner-monitor__search">
          <input
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder="Search deliveries, canvases, nodes"
            aria-label="Search deliveries"
          />
        </div>
        {error && <div className="planner-proposal-panel__error">{error}</div>}
        {!monitor && !error ? (
          <div className="planner-empty-state">
            <div className="boot-spinner" />
            <span>Loading workspace monitor</span>
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
                    : stateIcons[item.runState ?? 'waiting'] ?? Clock3
                  return (
                    <article key={item.id} className={`planner-monitor-item planner-monitor-item--rank-${item.riskRank}`}>
                      <div className="planner-monitor-item__icon">
                        <Icon size={15} aria-hidden />
                      </div>
                      <div className="planner-monitor-item__main">
                        <div className="planner-monitor-item__meta">
                          <span>{item.canvasTitle}</span>
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
                        {item.needsOwnerReview && <em>review</em>}
                      </div>
                    </article>
                  )
                })}
                {group.items.length === 0 && (
                  <div className="planner-monitor__empty">No items</div>
                )}
              </div>
            </section>
          ))
        )}
      </div>
    </section>
  )
}
