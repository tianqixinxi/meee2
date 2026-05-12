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
} from 'lucide-react'
import type { BoardState } from '../types'
import {
  buildSessionGraph,
  matchesSessionNode,
  SESSION_BUCKET_META,
  type SessionBucketId,
  type SessionGraphNode,
} from '../sessionGraph'

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
          <p className="cockpit-kicker">Personal AI Cockpit</p>
          <h1>AI Work in Progress</h1>
          <p className="cockpit-subtitle">
            Local sessions first: status, evidence, risks, and jump-back points.
          </p>
        </div>
        <div className="cockpit-actions">
          <button className="ghost icon-label" type="button" onClick={onOpenPreferences}>
            <Settings size={15} aria-hidden />
            Settings
          </button>
          <button className="ghost icon-label" type="button" onClick={onRefresh} disabled={loading}>
            <RefreshCw size={15} aria-hidden />
            Refresh
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
          placeholder="Search repo, session, provider, status, or latest message"
          aria-label="Search session history"
        />
      </div>

      {error && <div className="cockpit-inline-error">{error}</div>}

      {!state && loading ? (
        <div className="cockpit-empty-state">Loading local sessions...</div>
      ) : (
        <div className="cockpit-content">
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
                <p>{filteredNodes.length} matching sessions</p>
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
  const meta = SESSION_BUCKET_META[bucketId]
  return (
    <section className={`cockpit-section ${bucketId}`}>
      <div className="cockpit-section__header">
        <div>
          <h2>{meta.title}</h2>
          <p>{nodes.length} sessions</p>
        </div>
      </div>
      {nodes.length === 0 ? (
        <div className="cockpit-empty-state">{meta.empty}</div>
      ) : (
        <div className="cockpit-card-grid">
          {nodes.slice(0, 6).map((node) => (
            <SessionRadarCard
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

function SessionRadarCard({
  node,
  onOpenSession,
  onShowInMap,
}: {
  node: SessionGraphNode
  onOpenSession: (sessionId: string) => void
  onShowInMap: (sessionId: string) => void
}) {
  const s = node.session
  return (
    <article className={`cockpit-card status-${s.status}`}>
      <div className="cockpit-card__top">
        <span className="cockpit-provider" style={{ '--provider-color': s.pluginColor } as CSSProperties}>
          {node.provider}
        </span>
        <span className="cockpit-status">{statusLabel(s.status)}</span>
      </div>
      <h3 title={s.title}>{s.title}</h3>
      <div className="cockpit-card__meta">
        <span>{node.repo}</span>
        {node.branch && <span>{node.branch}</span>}
        <span>{formatRelativeTime(node.lastActivityMs)}</span>
      </div>
      <p className="cockpit-current-step">{node.currentStep}</p>
      {node.latestMessageText && (
        <p className="cockpit-latest-message">
          <span>{node.latestMessage?.role ?? 'message'}</span>
          {node.latestMessageText}
        </p>
      )}
      {node.risks.length > 0 && (
        <div className="cockpit-risks">
          {node.risks.slice(0, 3).map((risk) => (
            <span key={`${risk.type}:${risk.label}`} className={`cockpit-risk ${risk.severity}`} title={risk.detail}>
              {risk.label}
            </span>
          ))}
        </div>
      )}
      <div className="cockpit-card__actions">
        <button className="primary icon-label" type="button" onClick={() => onOpenSession(s.id)}>
          <ExternalLink size={14} aria-hidden />
          Jump back
        </button>
        <button className="ghost icon-only" type="button" onClick={() => onShowInMap(s.id)} aria-label="Show in Work Map">
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
  const s = node.session
  return (
    <div className="cockpit-history-row">
      <div>
        <div className="cockpit-history-row__title">{s.title}</div>
        <div className="cockpit-history-row__meta">
          {node.provider} · {node.repo} · {statusLabel(s.status)} · {formatRelativeTime(node.lastActivityMs)}
        </div>
      </div>
      <div className="cockpit-history-row__actions">
        <button className="ghost icon-only" type="button" onClick={() => onShowInMap(s.id)} aria-label="Show in Work Map">
          <Map size={15} aria-hidden />
        </button>
        <button className="ghost icon-only" type="button" onClick={() => onOpenSession(s.id)} aria-label="Jump back">
          <ExternalLink size={15} aria-hidden />
        </button>
      </div>
    </div>
  )
}

function statusLabel(status: string): string {
  switch (status) {
    case 'permissionRequired':
      return 'Permission'
    case 'waitingForUser':
      return 'Waiting'
    case 'tooling':
      return 'Tooling'
    case 'thinking':
      return 'Thinking'
    case 'compacting':
      return 'Compacting'
    case 'completed':
      return 'Completed'
    case 'dead':
      return 'Failed'
    default:
      return status
  }
}

function formatRelativeTime(ms: number): string {
  if (!ms) return 'No activity'
  const delta = Date.now() - ms
  if (delta < 60 * 1000) return 'just now'
  const minutes = Math.floor(delta / (60 * 1000))
  if (minutes < 60) return `${minutes}m ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}h ago`
  const days = Math.floor(hours / 24)
  return `${days}d ago`
}
