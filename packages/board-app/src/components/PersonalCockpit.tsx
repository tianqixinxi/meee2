import { useMemo, useState, type CSSProperties } from 'react'
import {
  AlertTriangle,
  Archive,
  CheckCircle2,
  ChevronDown,
  ChevronUp,
  Clock3,
  LocateFixed,
  PanelRightOpen,
  PlayCircle,
  RotateCcw,
  Search,
  Wrench,
} from 'lucide-react'
import type { BoardState } from '../types'
import {
  buildSessionGraph,
  matchesSessionNode,
  type SessionBucketId,
  type SessionGraphNode,
} from '../sessionGraph'
import { useI18n } from '../i18n'

interface PersonalCockpitProps {
  state: BoardState | null
  loading: boolean
  error: string | null
  onOpenSession: (sessionId: string) => void
  onShowInMap: (sessionId: string) => void
}

const PRIMARY_BUCKETS: SessionBucketId[] = [
  'needsAttention',
  'running',
  'waitingBlocked',
  'recentlyCompleted',
  'failed',
]

const ARCHIVED_SESSIONS_STORAGE_KEY = 'meee2.archivedSessions.v1'

const BUCKET_ICONS: Record<SessionBucketId, typeof AlertTriangle> = {
  needsAttention: AlertTriangle,
  running: PlayCircle,
  waitingBlocked: Clock3,
  recentlyCompleted: CheckCircle2,
  failed: AlertTriangle,
  history: Clock3,
}

export function PersonalCockpit({
  state,
  loading,
  error,
  onOpenSession,
  onShowInMap,
}: PersonalCockpitProps) {
  const { t } = useI18n()
  const [query, setQuery] = useState('')
  const [archivedIds, setArchivedIds] = useState<Set<string>>(loadArchivedSessionIds)
  const [expandedBuckets, setExpandedBuckets] = useState<Set<SessionBucketId>>(() => new Set())
  const [archiveExpanded, setArchiveExpanded] = useState(false)
  const graph = useMemo(() => buildSessionGraph(state?.sessions ?? []), [state])
  const filteredNodes = useMemo(
    () => graph.nodes.filter((node) => matchesSessionNode(node, query)),
    [graph.nodes, query],
  )
  const filteredIds = useMemo(
    () => new Set(filteredNodes.filter((node) => !archivedIds.has(node.session.id)).map((node) => node.session.id)),
    [archivedIds, filteredNodes],
  )
  const archivedNodes = useMemo(
    () => filteredNodes.filter((node) => archivedIds.has(node.session.id)),
    [archivedIds, filteredNodes],
  )
  const archivedTotal = graph.nodes.filter((node) => archivedIds.has(node.session.id)).length
  const hasArchiveSearch = query.trim().length > 0
  const archiveVisible = hasArchiveSearch || archiveExpanded

  const toggleBucket = (bucketId: SessionBucketId) => {
    setExpandedBuckets((current) => {
      const next = new Set(current)
      if (next.has(bucketId)) {
        next.delete(bucketId)
      } else {
        next.add(bucketId)
      }
      return next
    })
  }

  const archiveSession = (sessionId: string) => {
    setArchivedIds((current) => {
      const next = new Set(current)
      next.add(sessionId)
      saveArchivedSessionIds(next)
      return next
    })
  }

  const restoreSession = (sessionId: string) => {
    setArchivedIds((current) => {
      const next = new Set(current)
      next.delete(sessionId)
      saveArchivedSessionIds(next)
      return next
    })
  }

  const bucketNodes = (bucketId: SessionBucketId) =>
    graph.buckets[bucketId].filter((node) => filteredIds.has(node.session.id))

  return (
    <main className="personal-cockpit" aria-label={t('cockpit.kicker')}>
      <header className="cockpit-header">
        <div>
          <p className="cockpit-kicker">{t('cockpit.kicker')}</p>
          <h1>{t('cockpit.title')}</h1>
          <p className="cockpit-subtitle">
            {t('cockpit.subtitle')}
          </p>
        </div>
      </header>

      <section className="cockpit-summary" aria-label={t('cockpit.summaryAria')}>
        {PRIMARY_BUCKETS.map((bucketId) => {
          const Icon = BUCKET_ICONS[bucketId]
          const count = graph.buckets[bucketId].filter((node) => !archivedIds.has(node.session.id)).length
          return (
            <div key={bucketId} className={`cockpit-stat ${bucketId}`} title={bucketRule(bucketId, t)}>
              <div className="cockpit-stat__icon" aria-hidden>
                <Icon size={16} />
              </div>
              <div>
                <div className="cockpit-stat__value">{count}</div>
                <div className="cockpit-stat__label">{bucketShortTitle(bucketId, t)}</div>
              </div>
            </div>
          )
        })}
      </section>

      <div className="cockpit-search">
        <Search size={16} aria-hidden />
        <input
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder={t('cockpit.search')}
          aria-label={t('cockpit.searchAria')}
        />
      </div>

      {error && <div className="cockpit-inline-error">{error}</div>}

      {!state && loading ? (
        <div className="cockpit-empty-state">{t('cockpit.loading')}</div>
      ) : (
        <div className="cockpit-content cockpit-content--radar">
          {PRIMARY_BUCKETS.map((bucketId) => (
            <SessionBucket
              key={bucketId}
              bucketId={bucketId}
              nodes={bucketNodes(bucketId)}
              expanded={expandedBuckets.has(bucketId)}
              onToggleExpanded={() => toggleBucket(bucketId)}
              onOpenSession={onOpenSession}
              onShowInMap={onShowInMap}
              onArchiveSession={archiveSession}
            />
          ))}

          <section className="cockpit-section cockpit-history">
            <div className="cockpit-section__header">
              <div>
                <h2>{t('archive.title')}</h2>
                <p>
                  {archiveVisible
                    ? hasArchiveSearch
                      ? t('archive.matching', { count: archivedNodes.length })
                      : t('archive.expanded', { count: archivedNodes.length })
                    : t('archive.collapsed', { count: archivedTotal })}
                </p>
              </div>
              {archivedTotal > 0 && (
                <button
                  className="ghost cockpit-section__toggle"
                  type="button"
                  onClick={() => setArchiveExpanded((current) => !current)}
                  title={archiveExpanded ? t('bucket.collapse') : t('archive.expand')}
                >
                  {archiveExpanded ? (
                    <>
                      <ChevronUp size={14} aria-hidden />
                      {t('bucket.collapse')}
                    </>
                  ) : (
                    <>
                      <ChevronDown size={14} aria-hidden />
                      {t('archive.expand')}
                    </>
                  )}
                </button>
              )}
            </div>
            {!archiveVisible ? (
              <div className="cockpit-empty-state">{t('archive.searchHint')}</div>
            ) : archivedNodes.length === 0 ? (
              <div className="cockpit-empty-state">{t('archive.empty')}</div>
            ) : (
              <div className="cockpit-history-list">
                {archivedNodes.slice(0, 30).map((node) => (
                  <SessionArchiveRow
                    key={node.session.id}
                    node={node}
                    onOpenSession={onOpenSession}
                    onShowInMap={onShowInMap}
                    onRestoreSession={restoreSession}
                  />
                ))}
              </div>
            )}
          </section>
        </div>
      )}
    </main>
  )
}

function SessionBucket({
  bucketId,
  nodes,
  expanded,
  onToggleExpanded,
  onOpenSession,
  onShowInMap,
  onArchiveSession,
}: {
  bucketId: SessionBucketId
  nodes: SessionGraphNode[]
  expanded: boolean
  onToggleExpanded: () => void
  onOpenSession: (sessionId: string) => void
  onShowInMap: (sessionId: string) => void
  onArchiveSession: (sessionId: string) => void
}) {
  const { t } = useI18n()
  const visibleNodes = expanded ? nodes : nodes.slice(0, 6)
  return (
    <section className={`cockpit-section ${bucketId}`}>
      <div className="cockpit-section__header">
        <div>
          <h2>{bucketTitle(bucketId, t)}</h2>
          <p>{t('bucket.showing', { shown: Math.min(visibleNodes.length, nodes.length), total: nodes.length })}</p>
          <p className="cockpit-section__rule">{bucketRule(bucketId, t)}</p>
        </div>
        {nodes.length > 6 && (
          <button
            className="ghost cockpit-section__toggle"
            type="button"
            onClick={onToggleExpanded}
            title={expanded ? t('bucket.collapse') : t('bucket.showAll', { count: nodes.length })}
          >
            {expanded ? (
              <>
                <ChevronUp size={14} aria-hidden />
                {t('bucket.collapse')}
              </>
            ) : (
              <>
                <ChevronDown size={14} aria-hidden />
                {t('bucket.showAll', { count: nodes.length })}
              </>
            )}
          </button>
        )}
      </div>
      {nodes.length === 0 ? (
        <div className="cockpit-empty-state">{bucketEmpty(bucketId, t)}</div>
      ) : (
        <div className="cockpit-radar-list">
          {visibleNodes.map((node) => (
            <SessionRadarRow
              key={node.session.id}
              node={node}
              onOpenSession={onOpenSession}
              onShowInMap={onShowInMap}
              onArchiveSession={onArchiveSession}
            />
          ))}
        </div>
      )}
    </section>
  )
}

function SessionRadarRow({
  node,
  onOpenSession,
  onShowInMap,
  onArchiveSession,
}: {
  node: SessionGraphNode
  onOpenSession: (sessionId: string) => void
  onShowInMap: (sessionId: string) => void
  onArchiveSession: (sessionId: string) => void
}) {
  const { t } = useI18n()
  const s = node.session
  const primaryRisk = node.risks[0] ?? null
  const archiveTitle = t('archive.archiveAction')
  const archive = () => {
    if (window.confirm(t('archive.confirm', { title: s.title }))) {
      onArchiveSession(s.id)
    }
  }
  return (
    <article className={`cockpit-radar-row status-${s.status}`}>
      <div className="cockpit-radar-row__status">
        <span className={`cockpit-state-dot ${node.primaryBucket}`} aria-hidden />
        <span>{statusLabel(s.status, t)}</span>
      </div>
      <div className="cockpit-radar-row__identity">
        <span className="cockpit-provider" style={{ '--provider-color': s.pluginColor } as CSSProperties}>
          {node.provider}
        </span>
        <button className="cockpit-radar-row__title" type="button" onClick={() => onOpenSession(s.id)} title={s.title}>
          {s.title}
        </button>
        <div className="cockpit-radar-row__meta">
          <span title={node.repo}>{node.repo}</span>
          {node.branch && <span title={node.branch}>{node.branch}</span>}
        </div>
      </div>
      <p className="cockpit-current-step" title={node.currentStep}>{node.currentStep}</p>
      {node.latestMessageText && (
        <p className="cockpit-latest-message" title={node.latestMessageText}>
          <span>{node.latestMessage?.role ?? t('session.message')}</span>
          {node.latestMessageText}
        </p>
      )}
      <div className="cockpit-radar-row__tool" title={s.currentTool || s.currentTask || ''}>
        <Wrench size={13} aria-hidden />
        <span>{s.currentTool || s.currentTask || '—'}</span>
      </div>
      <div className="cockpit-radar-row__risk">
        {primaryRisk ? (
          <span className={`cockpit-risk ${primaryRisk.severity}`} title={primaryRisk.detail}>
            {riskLabel(primaryRisk, t)}
          </span>
        ) : (
          <span className="cockpit-muted-pill">{t('risk.none')}</span>
        )}
      </div>
      <div className="cockpit-radar-row__time">{formatRelativeTime(node.lastActivityMs, t)}</div>
      <div className="cockpit-radar-row__actions">
        <button className="ghost icon-only" type="button" onClick={() => onOpenSession(s.id)} aria-label={t('action.openDetail')} title={t('action.openDetail')}>
          <PanelRightOpen size={14} aria-hidden />
        </button>
        <button className="ghost icon-only" type="button" onClick={() => onShowInMap(s.id)} aria-label={t('action.showInMap')} title={t('action.showInMap')}>
          <LocateFixed size={15} aria-hidden />
        </button>
        <button className="ghost icon-only" type="button" onClick={archive} aria-label={archiveTitle} title={archiveTitle}>
          <Archive size={14} aria-hidden />
        </button>
      </div>
    </article>
  )
}

function SessionArchiveRow({
  node,
  onOpenSession,
  onShowInMap,
  onRestoreSession,
}: {
  node: SessionGraphNode
  onOpenSession: (sessionId: string) => void
  onShowInMap: (sessionId: string) => void
  onRestoreSession: (sessionId: string) => void
}) {
  const { t } = useI18n()
  const s = node.session
  return (
    <div className="cockpit-history-row">
      <div>
        <div className="cockpit-history-row__title">{s.title}</div>
        <div className="cockpit-history-row__meta">
          {node.provider} · {node.repo} · {statusLabel(s.status, t)} · {formatRelativeTime(node.lastActivityMs, t)}
        </div>
      </div>
      <div className="cockpit-history-row__actions">
        <button className="ghost icon-only" type="button" onClick={() => onShowInMap(s.id)} aria-label={t('action.showInMap')} title={t('action.showInMap')}>
          <LocateFixed size={15} aria-hidden />
        </button>
        <button className="ghost icon-only" type="button" onClick={() => onRestoreSession(s.id)} aria-label={t('archive.restoreAction')} title={t('archive.restoreAction')}>
          <RotateCcw size={14} aria-hidden />
        </button>
        <button className="ghost icon-only" type="button" onClick={() => onOpenSession(s.id)} aria-label={t('action.openDetail')} title={t('action.openDetail')}>
          <PanelRightOpen size={15} aria-hidden />
        </button>
      </div>
    </div>
  )
}

function statusLabel(status: string, t: (key: string, params?: Record<string, string | number>) => string): string {
  switch (status) {
    case 'permissionRequired':
      return t('status.permissionRequired')
    case 'waitingForUser':
      return t('status.waitingForUser')
    case 'tooling':
      return t('status.tooling')
    case 'thinking':
      return t('status.thinking')
    case 'compacting':
      return t('status.compacting')
    case 'completed':
      return t('status.completed')
    case 'dead':
      return t('status.dead')
    default:
      return status
  }
}

function bucketTitle(bucketId: SessionBucketId, t: (key: string) => string): string {
  return t(`bucket.${bucketId}.title`)
}

function bucketShortTitle(bucketId: SessionBucketId, t: (key: string) => string): string {
  return t(`bucket.${bucketId}.short`)
}

function bucketEmpty(bucketId: SessionBucketId, t: (key: string) => string): string {
  return t(`bucket.${bucketId}.empty`)
}

function bucketRule(bucketId: SessionBucketId, t: (key: string) => string): string {
  return t(`bucket.${bucketId}.rule`)
}

function riskLabel(
  risk: SessionGraphNode['risks'][number],
  t: (key: string, params?: Record<string, string | number>) => string,
): string {
  return t(`risk.${risk.type}`)
}

function formatRelativeTime(ms: number, t: (key: string, params?: Record<string, string | number>) => string): string {
  if (!ms) return t('time.none')
  const delta = Date.now() - ms
  if (delta < 60 * 1000) return t('time.justNow')
  const minutes = Math.floor(delta / (60 * 1000))
  if (minutes < 60) return t('time.minutesAgo', { count: minutes })
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return t('time.hoursAgo', { count: hours })
  const days = Math.floor(hours / 24)
  return t('time.daysAgo', { count: days })
}

function loadArchivedSessionIds(): Set<string> {
  try {
    const raw = window.localStorage.getItem(ARCHIVED_SESSIONS_STORAGE_KEY)
    const parsed = raw ? JSON.parse(raw) : []
    return new Set(Array.isArray(parsed) ? parsed.filter((value): value is string => typeof value === 'string') : [])
  } catch {
    return new Set()
  }
}

function saveArchivedSessionIds(ids: Set<string>) {
  try {
    window.localStorage.setItem(ARCHIVED_SESSIONS_STORAGE_KEY, JSON.stringify([...ids]))
  } catch {
    // Local archive is best-effort; sessions remain visible if storage is blocked.
  }
}
