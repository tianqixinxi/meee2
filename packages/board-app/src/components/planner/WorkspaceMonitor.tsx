import {
  AlertTriangle,
  CheckCircle2,
  ChevronDown,
  ChevronRight,
  Clock3,
  Filter,
  GitPullRequestArrow,
  LayoutGrid,
  List,
  PlayCircle,
  Route,
  Search,
  ShieldAlert,
  Signpost,
} from 'lucide-react'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { fetchPlannerWorkspaceMonitor } from '../../api'
import { useI18n } from '../../lib/i18n'
import { monitorItemOpenLabel, monitorItemSourceKind } from '../../lib/workspaceNavigation'
import type { CanvasInfo, NodeRunState, PlannerMonitorItem, PlannerMonitorState } from '../../types'
import { CanvasKindHint } from './CanvasKindHint'
import './planner.css'

const stateIcons: Partial<Record<NodeRunState, typeof AlertTriangle>> = {
  blocked: AlertTriangle,
  working: PlayCircle,
  draft: Route,
  ready: Clock3,
  done: CheckCircle2,
}

type MonitorLaneKey = 'blocked' | 'approval' | 'running' | 'ready' | 'done'
type MonitorSourceFilter = 'all' | 'live' | 'node' | 'canvas' | 'approval' | 'artifact'
type MonitorDensity = 'compact' | 'comfortable'
type MonitorSort = 'severity' | 'updated'
type Translator = ReturnType<typeof useI18n>['t']

interface MonitorLane {
  key: MonitorLaneKey
  label: string
  icon: typeof AlertTriangle
  items: PlannerMonitorItem[]
}

interface WorkspaceMonitorProps {
  activeCanvasId: string
  canvases: CanvasInfo[]
  refreshTick: number
  onOpenItem: (item: PlannerMonitorItem) => void
  onOpenAllSessions: () => void
}

export function WorkspaceMonitor({
  activeCanvasId,
  canvases,
  refreshTick,
  onOpenItem,
  onOpenAllSessions,
}: WorkspaceMonitorProps) {
  const { t } = useI18n()
  const [monitor, setMonitor] = useState<PlannerMonitorState | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [query, setQuery] = useState('')
  const [laneFilter, setLaneFilter] = useState<MonitorLaneKey | 'all'>('all')
  const [sourceFilter, setSourceFilter] = useState<MonitorSourceFilter>('all')
  const [evidenceOnly, setEvidenceOnly] = useState(false)
  const [density, setDensity] = useState<MonitorDensity>('compact')
  const [sortMode, setSortMode] = useState<MonitorSort>('severity')
  const [collapsedLanes, setCollapsedLanes] = useState<MonitorLaneKey[]>([])
  const activeCanvasName = monitorCanvasName(canvases.find((canvas) => canvas.id === activeCanvasId)?.name ?? t('monitor.title'))

  const loadMonitor = useCallback(() => {
    setError(null)
    fetchPlannerWorkspaceMonitor()
      .then(setMonitor)
      .catch((err) => setError((err as Error).message || t('monitor.loadFailed')))
  }, [t])

  useEffect(() => {
    loadMonitor()
  }, [loadMonitor, refreshTick])

  const lanes = useMemo<MonitorLane[]>(() => {
    const term = query.trim().toLowerCase()
    const filteredItems = (monitor?.items ?? [])
      .filter((item) => matchesSearch(item, term))
      .filter((item) => laneFilter === 'all' || laneForItem(item) === laneFilter)
      .filter((item) => sourceMatches(item, sourceFilter))
      .filter((item) => !evidenceOnly || evidenceCount(item) > 0)
      .sort((a, b) => sortMonitorItems(a, b, sortMode))

    const itemLanes: MonitorLane[] = [
      { key: 'blocked', label: t('monitor.laneBlocked'), icon: ShieldAlert, items: [] },
      { key: 'approval', label: t('monitor.laneApproval'), icon: GitPullRequestArrow, items: [] },
      { key: 'running', label: t('monitor.laneRunning'), icon: PlayCircle, items: [] },
      { key: 'ready', label: t('monitor.laneReady'), icon: Clock3, items: [] },
      { key: 'done', label: t('monitor.laneDone'), icon: CheckCircle2, items: [] },
    ]
    const byKey = new Map(itemLanes.map((lane) => [lane.key, lane]))
    for (const item of filteredItems) {
      byKey.get(laneForItem(item))?.items.push(item)
    }
    return itemLanes
  }, [evidenceOnly, laneFilter, monitor, query, sortMode, sourceFilter, t])

  const totalItems = lanes.reduce((count, lane) => count + lane.items.length, 0)

  const toggleLane = (lane: MonitorLaneKey) => {
    setCollapsedLanes((current) => (
      current.includes(lane) ? current.filter((key) => key !== lane) : [...current, lane]
    ))
  }

  const setQuickLane = (lane: MonitorLaneKey) => {
    setLaneFilter((current) => current === lane ? 'all' : lane)
  }

  return (
    <section className="planner-monitor" aria-label={t('monitor.title')}>
      <CanvasKindHint kind="monitor" />
      <div className="planner-monitor__body">
        <div className="planner-monitor__tools">
          <div className="planner-monitor__search">
            <Search size={13} aria-hidden />
            <input
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder={t('monitor.searchPlaceholder')}
              aria-label={t('monitor.searchLabel')}
            />
          </div>
          <div className="planner-monitor__tool-group" role="group" aria-label={t('monitor.quickFilters')}>
            <button
              type="button"
              className={laneFilter === 'blocked' ? 'is-active' : ''}
              onClick={() => setQuickLane('blocked')}
            >
              <ShieldAlert size={12} aria-hidden />
              <span>{t('monitor.blockedOnly')}</span>
            </button>
            <button
              type="button"
              className={laneFilter === 'approval' ? 'is-active' : ''}
              onClick={() => setQuickLane('approval')}
            >
              <GitPullRequestArrow size={12} aria-hidden />
              <span>{t('monitor.approvalOnly')}</span>
            </button>
            <button
              type="button"
              className={evidenceOnly ? 'is-active' : ''}
              onClick={() => setEvidenceOnly((value) => !value)}
            >
              <Filter size={12} aria-hidden />
              <span>{t('monitor.evidenceOnly')}</span>
            </button>
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

        <div className="planner-monitor__filters" aria-label={t('monitor.filters')}>
          <label>
            <span>{t('monitor.status')}</span>
            <select value={laneFilter} onChange={(event) => setLaneFilter(event.target.value as MonitorLaneKey | 'all')}>
              <option value="all">{t('monitor.allStatus')}</option>
              <option value="blocked">{t('monitor.laneBlocked')}</option>
              <option value="approval">{t('monitor.laneApproval')}</option>
              <option value="running">{t('monitor.laneRunning')}</option>
              <option value="ready">{t('monitor.laneReady')}</option>
              <option value="done">{t('monitor.laneDone')}</option>
            </select>
          </label>
          <label>
            <span>{t('monitor.source')}</span>
            <select value={sourceFilter} onChange={(event) => setSourceFilter(event.target.value as MonitorSourceFilter)}>
              <option value="all">{t('monitor.sourceAll')}</option>
              <option value="live">{t('monitor.sourceLive')}</option>
              <option value="node">{t('monitor.sourceNode')}</option>
              <option value="canvas">{t('monitor.sourceCanvas')}</option>
              <option value="approval">{t('monitor.sourceApproval')}</option>
              <option value="artifact">{t('monitor.sourceArtifact')}</option>
            </select>
          </label>
          <label>
            <span>{t('monitor.sort')}</span>
            <select value={sortMode} onChange={(event) => setSortMode(event.target.value as MonitorSort)}>
              <option value="severity">{t('monitor.sortSeverity')}</option>
              <option value="updated">{t('monitor.sortUpdated')}</option>
            </select>
          </label>
          <div className="planner-monitor__density" role="group" aria-label={t('monitor.density')}>
            <button
              type="button"
              className={density === 'compact' ? 'is-active' : ''}
              onClick={() => setDensity('compact')}
            >
              <LayoutGrid size={12} aria-hidden />
              <span>{t('monitor.compact')}</span>
            </button>
            <button
              type="button"
              className={density === 'comfortable' ? 'is-active' : ''}
              onClick={() => setDensity('comfortable')}
            >
              <span>{t('monitor.comfortable')}</span>
            </button>
          </div>
          <span className="planner-monitor__result-count">{t('monitor.resultCount', { count: String(totalItems) })}</span>
        </div>

        {error && <div className="planner-proposal-panel__error">{error}</div>}
        {!monitor && !error ? (
          <div className="planner-empty-state">
            <div className="boot-spinner" />
            <span>{t('monitor.loading')}</span>
          </div>
        ) : (
          <div className="planner-monitor__kanban" data-density={density}>
            {lanes.map((lane) => {
              const collapsed = collapsedLanes.includes(lane.key)
              const Icon = lane.icon
              return (
                <section key={lane.key} className={`planner-monitor-lane planner-monitor-lane--${lane.key}`}>
                  <button
                    type="button"
                    className="planner-monitor-lane__header"
                    onClick={() => toggleLane(lane.key)}
                    aria-expanded={!collapsed}
                    title={collapsed ? t('monitor.expandLane') : t('monitor.collapseLane')}
                  >
                    <Icon size={14} aria-hidden />
                    <span>{lane.label}</span>
                    <strong>{lane.items.length}</strong>
                    {collapsed ? <ChevronRight size={14} aria-hidden /> : <ChevronDown size={14} aria-hidden />}
                  </button>
                  {!collapsed && (
                    <div className="planner-monitor-lane__items">
                      {lane.items.map((item) => (
                        <MonitorCard
                          key={item.id}
                          item={item}
                          generatedAt={monitor?.generatedAt}
                          onOpenItem={onOpenItem}
                          t={t}
                        />
                      ))}
                      {lane.items.length === 0 && (
                        <div className="planner-monitor__empty">{activeCanvasName}: {t('monitor.empty')}</div>
                      )}
                    </div>
                  )}
                </section>
              )
            })}
          </div>
        )}
      </div>
    </section>
  )
}

function MonitorCard({
  item,
  generatedAt,
  onOpenItem,
  t,
}: {
  item: PlannerMonitorItem
  generatedAt?: string
  onOpenItem: (item: PlannerMonitorItem) => void
  t: Translator
}) {
  const sourceKind = monitorItemSourceKind(item)
  const Icon = item.kind === 'proposal'
    ? GitPullRequestArrow
    : item.kind === 'session'
      ? List
      : sourceKind === 'canvas'
        ? Route
        : stateIcons[item.runState ?? 'ready'] ?? Clock3
  const evidence = evidenceCount(item)
  return (
    <button
      type="button"
      className={`planner-monitor-card planner-monitor-card--${laneForItem(item)} planner-monitor-card--rank-${item.riskRank}`}
      onClick={() => onOpenItem(item)}
      aria-label={`${monitorOpenLabel(item, t)}: ${item.nodeTitle ?? item.summary}`}
      title={`${monitorOpenLabel(item, t)}: ${item.canvasTitle}`}
    >
      <div className="planner-monitor-card__top">
        <span className="planner-monitor-card__source">
          <Icon size={12} aria-hidden />
          {sourceLabel(item, t)}
        </span>
        <span className="planner-monitor-card__time">{formatRelativeTimestamp(item.updatedAt ?? generatedAt)}</span>
      </div>
      <h3>{item.nodeTitle ?? item.summary}</h3>
      <div className="planner-monitor-card__meta">
        <span>{monitorCanvasName(item.canvasTitle)}</span>
        <span>{item.doerId || t('monitor.unassigned')}</span>
        <span>{statusLabel(item, t)}</span>
      </div>
      {(item.blockers.length > 0 || item.nextAction) && (
        <p className={item.blockers.length > 0 ? 'is-blocker' : ''}>
          {item.blockers.length > 0 ? item.blockers.join('; ') : item.nextAction}
        </p>
      )}
      <div className="planner-monitor-card__footer">
        <span className={evidence > 0 ? 'has-evidence' : ''}>
          {t('monitor.evidenceCount', { count: String(evidence) })}
        </span>
        {item.nextAction && item.blockers.length > 0 && (
          <span className="planner-monitor-card__next">
            <Signpost size={11} aria-hidden />
            {item.nextAction}
          </span>
        )}
      </div>
    </button>
  )
}

function monitorOpenLabel(item: PlannerMonitorItem, t: Translator): string {
  switch (monitorItemOpenLabel(item)) {
    case 'item':
      return t('monitor.openItem')
    case 'session':
      return t('monitor.openSession')
    case 'canvas':
      return t('monitor.openCanvas')
  }
}

function matchesSearch(item: PlannerMonitorItem, term: string): boolean {
  if (!term) return true
  return [
    item.summary,
    item.canvasTitle,
    item.nodeTitle ?? '',
    item.nextAction ?? '',
    item.doerId ?? '',
    item.kind,
    item.runState ?? '',
    item.proposalStatus ?? '',
    ...item.blockers,
  ].some((value) => value.toLowerCase().includes(term))
}

function sourceMatches(item: PlannerMonitorItem, source: MonitorSourceFilter): boolean {
  const sourceKind = monitorItemSourceKind(item)
  switch (source) {
    case 'all':
      return true
    case 'live':
      return sourceKind === 'live'
    case 'node':
      return sourceKind === 'node'
    case 'canvas':
      return sourceKind === 'canvas'
    case 'approval':
      return sourceKind === 'approval' || item.needsOwnerReview
    case 'artifact':
      return evidenceCount(item) > 0
  }
}

function laneForItem(item: PlannerMonitorItem): MonitorLaneKey {
  if (item.runState === 'blocked' || item.riskRank <= 0 || item.blockers.length > 0) return 'blocked'
  if (item.needsOwnerReview || item.proposalStatus === 'pending') return 'approval'
  if (item.runState === 'working' || item.runState === 'draft' || item.riskRank === 2 || item.riskRank === 3) return 'running'
  if (item.runState === 'done' || item.riskRank >= 5) return 'done'
  return 'ready'
}

function evidenceCount(item: PlannerMonitorItem): number {
  return Math.max(0, item.evidenceCount ?? 0)
}

function awaitingBoost(item: PlannerMonitorItem, now: number): number {
  if (!item.awaitingInputSince) return 0
  const since = Date.parse(item.awaitingInputSince)
  if (!Number.isFinite(since)) return 0
  const hours = Math.max(0, (now - since) / (1000 * 60 * 60))
  if (hours >= 72) return 500
  if (hours >= 24) return 100
  return 0
}

function sortMonitorItems(a: PlannerMonitorItem, b: PlannerMonitorItem, sortMode: MonitorSort): number {
  if (sortMode === 'severity') {
    const now = Date.now()
    const leftRank = a.riskRank - awaitingBoost(a, now)
    const rightRank = b.riskRank - awaitingBoost(b, now)
    if (leftRank !== rightRank) return leftRank - rightRank
  }
  if (sortMode === 'updated') {
    const delta = timestampForItem(b) - timestampForItem(a)
    if (delta !== 0) return delta
  }
  if (a.canvasTitle !== b.canvasTitle) return a.canvasTitle.localeCompare(b.canvasTitle)
  return a.summary.localeCompare(b.summary)
}

function sourceLabel(item: PlannerMonitorItem, t: Translator): string {
  switch (monitorItemSourceKind(item)) {
    case 'live':
      return t('monitor.sourceLive')
    case 'canvas':
      return t('monitor.sourceCanvas')
    case 'approval':
      return t('monitor.sourceApproval')
    case 'node':
      return t('monitor.sourceNode')
  }
}

function statusLabel(item: PlannerMonitorItem, t: Translator): string {
  if (item.proposalStatus) return item.proposalStatus
  if (item.runState) return item.runState
  switch (laneForItem(item)) {
    case 'blocked':
      return t('monitor.laneBlocked')
    case 'approval':
      return t('monitor.laneApproval')
    case 'running':
      return t('monitor.laneRunning')
    case 'ready':
      return t('monitor.laneReady')
    case 'done':
      return t('monitor.laneDone')
  }
}

function timestampForItem(item: PlannerMonitorItem): number {
  const timestamp = Date.parse(item.updatedAt ?? '')
  return Number.isNaN(timestamp) ? 0 : timestamp
}

function formatRelativeTimestamp(value?: string | null): string {
  if (!value) return ''
  const timestamp = Date.parse(value)
  if (Number.isNaN(timestamp)) return ''
  const seconds = Math.max(0, Math.round((Date.now() - timestamp) / 1000))
  if (seconds < 60) return 'now'
  const minutes = Math.round(seconds / 60)
  if (minutes < 60) return `${minutes}m`
  const hours = Math.round(minutes / 60)
  if (hours < 24) return `${hours}h`
  return `${Math.round(hours / 24)}d`
}

function monitorCanvasName(name: string): string {
  return name === 'Default canvas' ? 'Monitor' : name
}
