import { useMemo, useState, type CSSProperties } from 'react'
import {
  AlertTriangle,
  CheckCircle2,
  Clock3,
  ExternalLink,
  Map,
  PlayCircle,
  RefreshCw,
  Search,
  Settings,
  Wrench,
} from 'lucide-react'
import type { BoardState } from '../types'
import {
  buildSessionGraph,
  matchesSessionNode,
  SESSION_BUCKET_META,
  type SessionBucketId,
  type SessionGraphNode,
} from '../sessionGraph'
import { useI18n } from '../i18n'

interface PersonalCockpitProps {
  state: BoardState | null
  loading: boolean
  error: string | null
  onRefresh: () => void
  onOpenSession: (sessionId: string) => void
  onShowInMap: (sessionId: string) => void
  onOpenPreferences: () => void
}

const PRIMARY_BUCKETS: SessionBucketId[] = [
  'needsAttention',
  'running',
  'waitingBlocked',
  'recentlyCompleted',
  'failed',
]

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
  onRefresh,
  onOpenSession,
  onShowInMap,
  onOpenPreferences,
}: PersonalCockpitProps) {
  const { t } = useI18n()
  const [query, setQuery] = useState('')
  const graph = useMemo(() => buildSessionGraph(state?.sessions ?? []), [state])
  const filteredNodes = useMemo(
    () => graph.nodes.filter((node) => matchesSessionNode(node, query)),
    [graph.nodes, query],
  )
  const filteredIds = useMemo(
    () => new Set(filteredNodes.map((node) => node.session.id)),
    [filteredNodes],
  )

  const bucketNodes = (bucketId: SessionBucketId) =>
    graph.buckets[bucketId].filter((node) => filteredIds.has(node.session.id))

  const historyNodes = filteredNodes.slice(0, 30)

  return (
    <main className="personal-cockpit" aria-label="Personal AI Cockpit">
      <header className="cockpit-header">
        <div>
          <p className="cockpit-kicker">{t('cockpit.kicker')}</p>
          <h1>{t('cockpit.title')}</h1>
          <p className="cockpit-subtitle">
            {t('cockpit.subtitle')}
          </p>
        </div>
        <div className="cockpit-actions">
          <button className="ghost icon-label" type="button" onClick={onOpenPreferences}>
            <Settings size={15} aria-hidden />
            {t('action.settings')}
          </button>
          <button className="ghost icon-label" type="button" onClick={onRefresh} disabled={loading}>
            <RefreshCw size={15} aria-hidden />
            {t('action.refresh')}
          </button>
        </div>
      </header>

      <section className="cockpit-summary" aria-label="Session status summary">
        {PRIMARY_BUCKETS.map((bucketId) => {
          const meta = SESSION_BUCKET_META[bucketId]
          const Icon = BUCKET_ICONS[bucketId]
          const count = graph.buckets[bucketId].length
          return (
            <div key={bucketId} className={`cockpit-stat ${bucketId}`}>
              <div className="cockpit-stat__icon" aria-hidden>
                <Icon size={16} />
              </div>
              <div>
                <div className="cockpit-stat__value">{count}</div>
                <div className="cockpit-stat__label">{meta.shortTitle}</div>
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
          aria-label="Search session history"
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
              onOpenSession={onOpenSession}
              onShowInMap={onShowInMap}
            />
          ))}

          <section className="cockpit-section cockpit-history">
            <div className="cockpit-section__header">
              <div>
                <h2>{SESSION_BUCKET_META.history.title}</h2>
                <p>{filteredNodes.length} {t('cockpit.matching')}</p>
              </div>
            </div>
            {historyNodes.length === 0 ? (
              <div className="cockpit-empty-state">{SESSION_BUCKET_META.history.empty}</div>
            ) : (
              <div className="cockpit-history-list">
                {historyNodes.map((node) => (
                  <SessionHistoryRow
                    key={node.session.id}
                    node={node}
                    onOpenSession={onOpenSession}
                    onShowInMap={onShowInMap}
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
  onOpenSession,
  onShowInMap,
}: {
  bucketId: SessionBucketId
  nodes: SessionGraphNode[]
  onOpenSession: (sessionId: string) => void
  onShowInMap: (sessionId: string) => void
}) {
  const { t } = useI18n()
  const meta = SESSION_BUCKET_META[bucketId]
  return (
    <section className={`cockpit-section ${bucketId}`}>
      <div className="cockpit-section__header">
        <div>
          <h2>{meta.title}</h2>
          <p>{nodes.length} {t('cockpit.sessions')}</p>
        </div>
      </div>
      {nodes.length === 0 ? (
        <div className="cockpit-empty-state">{meta.empty}</div>
      ) : (
        <div className="cockpit-radar-list">
          {nodes.slice(0, 6).map((node) => (
            <SessionRadarRow
              key={node.session.id}
              node={node}
              onOpenSession={onOpenSession}
              onShowInMap={onShowInMap}
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
}: {
  node: SessionGraphNode
  onOpenSession: (sessionId: string) => void
  onShowInMap: (sessionId: string) => void
}) {
  const { t } = useI18n()
  const s = node.session
  const primaryRisk = node.risks[0] ?? null
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
          <span>{node.latestMessage?.role ?? 'message'}</span>
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
            {primaryRisk.label}
          </span>
        ) : (
          <span className="cockpit-muted-pill">No risk</span>
        )}
      </div>
      <div className="cockpit-radar-row__time">{formatRelativeTime(node.lastActivityMs, t)}</div>
      <div className="cockpit-radar-row__actions">
        <button className="ghost icon-only" type="button" onClick={() => onOpenSession(s.id)} aria-label={t('action.openDetail')}>
          <ExternalLink size={14} aria-hidden />
        </button>
        <button className="ghost icon-only" type="button" onClick={() => onShowInMap(s.id)} aria-label={t('action.showInMap')}>
          <Map size={15} aria-hidden />
        </button>
      </div>
    </article>
  )
}

function SessionHistoryRow({
  node,
  onOpenSession,
  onShowInMap,
}: {
  node: SessionGraphNode
  onOpenSession: (sessionId: string) => void
  onShowInMap: (sessionId: string) => void
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
        <button className="ghost icon-only" type="button" onClick={() => onShowInMap(s.id)} aria-label={t('action.showInMap')}>
          <Map size={15} aria-hidden />
        </button>
        <button className="ghost icon-only" type="button" onClick={() => onOpenSession(s.id)} aria-label={t('action.openDetail')}>
          <ExternalLink size={15} aria-hidden />
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
