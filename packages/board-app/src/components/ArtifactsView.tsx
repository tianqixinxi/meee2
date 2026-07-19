import {
  Archive,
  Database,
  ExternalLink,
  FileText,
  GitPullRequest,
  LayoutDashboard,
  Loader2,
  Search,
  ShieldCheck,
  X,
  type LucideIcon,
} from 'lucide-react'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  fetchArtifactsPage,
  proposePlannerGraphChange,
} from '../api'
import { useToast } from '../App'
import { requestBoardTarget } from '../lib/boardTarget'
import {
  ARTIFACT_TYPE_GROUPS,
  artifactGroupCounts,
  buildArtifactIndex,
  type ArtifactDisplayState,
  type ArtifactIndexItem,
  type ArtifactTypeGroupId,
} from '../lib/artifactIndex'
import { useI18n } from '../lib/i18n'
import type {
  ArtifactPageItem,
  ArtifactReviewStatus,
  CanvasInfo,
  PlanProposal,
  PlannerArtifact,
} from '../types'
import { ArtifactPreviewDialog } from './artifacts/ArtifactPreviewDialog'
import { PageShell } from './PageShell'

type StateFilter = ArtifactDisplayState | 'all'
type CanvasFilter = string | 'all'

export interface ArtifactSessionFilter {
  sessionId: string
  title: string
  providerResumeSessionId?: string | null
  surfaceId?: string | null
  project?: string | null
  projectName?: string | null
}

const ARTIFACT_STATE_ORDER: ArtifactDisplayState[] = [
  'needs-review',
  'ready',
  'working',
  'failed',
  'stale',
  'rejected',
  'other',
]
const ARTIFACT_PAGE_SIZE = 50
const ARTIFACT_WINDOW_SIZE = 60
const ARTIFACT_ROW_HEIGHT = 56

/* 分组图标 + 配色（与 styles.css 的 --group-color 映射一致） */
const ARTIFACT_GROUP_ICONS: Record<string, LucideIcon> = {
  docs: FileText,
  boards: LayoutDashboard,
  implementation: GitPullRequest,
  validation: ShieldCheck,
  'files-data': Database,
  other: Archive,
}
const ARTIFACT_SEARCH_DELAY_MS = 200

interface ArtifactsViewProps {
  canvases: CanvasInfo[]
  activeCanvasId: string
  sessionFilter?: ArtifactSessionFilter | null
  onClearSessionFilter?: () => void
  onOpenCanvas: (canvasId: string) => void
  onProposalCreated?: (proposal: PlanProposal) => void
}

export function ArtifactsView({
  canvases,
  activeCanvasId,
  sessionFilter,
  onClearSessionFilter,
  onOpenCanvas,
  onProposalCreated,
}: ArtifactsViewProps) {
  const { t } = useI18n()
  const toast = useToast()
  const [query, setQuery] = useState('')
  const [debouncedQuery, setDebouncedQuery] = useState('')
  const [activeGroup, setActiveGroup] = useState<ArtifactTypeGroupId | 'all'>('all')
  const [canvasFilter, setCanvasFilter] = useState<CanvasFilter>('all')
  const [stateFilter, setStateFilter] = useState<StateFilter>('all')
  const [artifactItems, setArtifactItems] = useState<ArtifactIndexItem[]>([])
  const [artifactTotal, setArtifactTotal] = useState(0)
  const [availableTotal, setAvailableTotal] = useState(0)
  const [canvasCount, setCanvasCount] = useState(0)
  const [counts, setCounts] = useState(() => artifactGroupCounts([]))
  const [artifactCursor, setArtifactCursor] = useState<string | null>(null)
  const [artifactHasMore, setArtifactHasMore] = useState(false)
  const [previewKey, setPreviewKey] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)
  const [loadingMore, setLoadingMore] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [reviewActionKey, setReviewActionKey] = useState<string | null>(null)
  const [refreshTick, setRefreshTick] = useState(0)
  const [windowStart, setWindowStart] = useState(0)
  const pageRequestSequenceRef = useRef(0)

  useEffect(() => () => {
    pageRequestSequenceRef.current += 1
  }, [])

  useEffect(() => {
    const timer = window.setTimeout(() => setDebouncedQuery(query.trim()), ARTIFACT_SEARCH_DELAY_MS)
    return () => window.clearTimeout(timer)
  }, [query])

  const canvasSignature = useMemo(
    () => canvases.map((canvas) => `${canvas.id}:${canvas.name}`).join('|'),
    [canvases],
  )

  const pageParams = useMemo(() => {
    const sessionIds = [
      sessionFilter?.sessionId,
      sessionFilter?.providerResumeSessionId,
      sessionFilter?.surfaceId,
    ].map((value) => value?.trim()).filter((value): value is string => Boolean(value))
    return {
      canvasId: canvasFilter === 'all' ? undefined : canvasFilter,
      query: debouncedQuery,
      sessionId: sessionIds.length ? sessionIds.join(',') : undefined,
      project: sessionFilter?.project ?? sessionFilter?.projectName ?? undefined,
      group: activeGroup,
    } as const
  }, [
    activeGroup,
    canvasFilter,
    debouncedQuery,
    sessionFilter?.project,
    sessionFilter?.projectName,
    sessionFilter?.providerResumeSessionId,
    sessionFilter?.sessionId,
    sessionFilter?.surfaceId,
  ])

  useEffect(() => {
    const sequence = ++pageRequestSequenceRef.current
    let cancelled = false
    setLoading(true)
    setLoadingMore(false)
    setError(null)
    fetchArtifactsPage({
      ...pageParams,
      limit: ARTIFACT_PAGE_SIZE,
      status: stateFilter,
    })
      .then((page) => {
        if (cancelled || pageRequestSequenceRef.current !== sequence) return
        setArtifactItems(pageItemsToIndex(page.items))
        setArtifactTotal(page.total)
        setAvailableTotal(page.availableTotal ?? page.total)
        setCanvasCount(page.canvasCount)
        setCounts(normalizedGroupCounts(page.groupCounts))
        setArtifactCursor(page.cursor ?? null)
        setArtifactHasMore(page.hasMore)
      })
      .catch((err) => {
        if (!cancelled && pageRequestSequenceRef.current === sequence) {
          setError((err as Error).message || t('artifacts.loadFailed'))
        }
      })
      .finally(() => {
        if (!cancelled && pageRequestSequenceRef.current === sequence) setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [canvasSignature, pageParams, refreshTick, stateFilter, t])

  useEffect(() => {
    const handleArtifactsChanged = (event: Event) => {
      const changedSessionId = (event as CustomEvent<{ sessionId?: string }>).detail?.sessionId
      if (!sessionFilter?.sessionId || !changedSessionId || changedSessionId === sessionFilter.sessionId) {
        setRefreshTick((value) => value + 1)
      }
    }
    window.addEventListener('meee2:session-artifacts-changed', handleArtifactsChanged)
    return () => window.removeEventListener('meee2:session-artifacts-changed', handleArtifactsChanged)
  }, [sessionFilter?.sessionId])

  const allItems = artifactItems
  const mountedItems = useMemo(
    () => allItems.slice(windowStart, windowStart + ARTIFACT_WINDOW_SIZE),
    [allItems, windowStart],
  )
  const previewItem = useMemo(
    () => allItems.find((item) => item.key === previewKey) ?? null,
    [allItems, previewKey],
  )
  const canvasOptions = canvases
  const stateOptions = ARTIFACT_STATE_ORDER
  const hasMore = artifactHasMore

  useEffect(() => {
    setWindowStart(0)
    setPreviewKey(null)
  }, [activeGroup, canvasFilter, debouncedQuery, sessionFilter?.sessionId, stateFilter])

  const loadMore = useCallback(() => {
    if (loadingMore || !hasMore) return
    const sequence = pageRequestSequenceRef.current
    setLoadingMore(true)
    const requests: Promise<void>[] = []
    if (artifactHasMore && artifactCursor) {
      requests.push(fetchArtifactsPage({
        ...pageParams,
        cursor: artifactCursor,
        limit: ARTIFACT_PAGE_SIZE,
        status: stateFilter,
      }).then((page) => {
        if (pageRequestSequenceRef.current !== sequence) return
        setArtifactItems((current) => mergeIndexItems(current, pageItemsToIndex(page.items)))
        setArtifactCursor(page.cursor ?? null)
        setArtifactHasMore(page.hasMore)
      }))
    }
    Promise.all(requests)
      .catch((err) => {
        if (pageRequestSequenceRef.current === sequence) {
          setError((err as Error).message || t('artifacts.loadFailed'))
        }
      })
      .finally(() => {
        if (pageRequestSequenceRef.current === sequence) setLoadingMore(false)
      })
  }, [
    artifactCursor,
    artifactHasMore,
    hasMore,
    loadingMore,
    pageParams,
    stateFilter,
    t,
  ])

  const openExternalArtifact = useCallback((item: ArtifactIndexItem): boolean => {
    const url = artifactExternalUrl(item.latest)
    if (!url) return false
    window.open(url, '_blank', 'noopener,noreferrer')
    return true
  }, [])

  const openSourceArtifact = useCallback((item: ArtifactIndexItem) => {
    requestBoardTarget({
      kind: 'planner-artifact',
      canvasId: item.canvas.id,
      nodeId: item.latest.nodeId,
      artifactId: item.latest.id,
      source: 'system',
      guide: {
        enabled: true,
        title: item.latest.title,
        body: item.latest.reference,
      },
    })
  }, [])

  const reviewArtifact = useCallback((item: ArtifactIndexItem, reviewStatus: ArtifactReviewStatus) => {
    if (reviewActionKey) return
    setReviewActionKey(`${item.key}:${reviewStatus}`)
    proposePlannerGraphChange(item.canvas.id, {
      summary: `${reviewStatus === 'approved' ? 'Approve' : 'Reject'} ${item.latest.title}`,
      changes: [
        {
          kind: 'attachArtifact',
          nodeId: item.latest.nodeId,
          artifact: {
            kind: item.latest.kind,
            title: item.latest.title,
            reference: item.latest.reference,
            status: item.latest.status,
            payload: item.latest.payload,
            reviewStatus,
          },
        },
      ],
    })
      .then((proposal) => {
        if (!proposal) {
          toast.push('error', t('artifacts.reviewProposalFailed'))
          return
        }
        onProposalCreated?.(proposal)
        toast.push('success', t('artifacts.reviewProposalCreated'))
        requestBoardTarget({
          kind: 'planner-proposal',
          canvasId: item.canvas.id,
          proposalId: proposal.id,
          source: 'system',
          guide: {
            enabled: true,
            title: t('artifacts.reviewProposalGuideTitle'),
            body: proposal.summary,
          },
        })
      })
      .catch((err) => {
        toast.push('error', (err as Error).message || t('artifacts.reviewProposalFailed'))
      })
      .finally(() => setReviewActionKey(null))
  }, [onProposalCreated, reviewActionKey, t, toast])

  return (
    <PageShell
      ariaLabel={t('artifacts.title')}
      title={t('artifacts.title')}
      hint={loading
        ? t('artifacts.loadingSlots')
        : t('artifacts.summary', { slots: artifactTotal, canvases: canvasCount })}
      headerExtra={sessionFilter && (
        <button
          type="button"
          className="artifacts-session-filter"
          onClick={onClearSessionFilter}
          title={t('artifacts.clearSessionFilter')}
        >
          <span>{t('artifacts.sessionFilter', { title: sessionFilter.title })}</span>
          {onClearSessionFilter && <X size={13} aria-hidden />}
        </button>
      )}
      tools={(
        <div className="artifacts-toolbar">
          <label className="artifacts-search">
            <Search size={14} aria-hidden />
            <input
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder={t('artifacts.searchPlaceholder')}
            />
          </label>
          <div className="artifacts-index__filters" aria-label={t('artifacts.filterLabel')}>
            <SelectFilter
              label={t('artifacts.canvasFilter')}
              value={canvasFilter}
              onChange={setCanvasFilter}
              options={[
                { value: 'all', label: t('artifacts.filterAll') },
                ...canvasOptions.map((canvas) => ({ value: canvas.id, label: canvas.name || canvas.id })),
              ]}
            />
            <SelectFilter
              label={t('artifacts.stateFilter')}
              value={stateFilter}
              onChange={(value) => setStateFilter(value as StateFilter)}
              options={[
                { value: 'all', label: t('artifacts.filterAll') },
                ...stateOptions.map((state) => ({ value: state, label: artifactStateLabel(state, t) })),
              ]}
            />
          </div>
        </div>
      )}
    >
        <nav className="artifacts-index__types" aria-label={t('artifacts.typeDirectory')}>
          <button
            type="button"
            data-group="all"
            className={`artifacts-type-button${activeGroup === 'all' ? ' is-active' : ''}`}
            onClick={() => setActiveGroup('all')}
          >
            <span>{t('artifacts.typeAll')}</span>
            <strong>{artifactTotal}</strong>
          </button>
          {ARTIFACT_TYPE_GROUPS.filter((group) => counts[group.id] > 0 || activeGroup === group.id).map((group) => (
            <button
              type="button"
              key={group.id}
              data-group={group.id}
              className={`artifacts-type-button${activeGroup === group.id ? ' is-active' : ''}`}
              onClick={() => setActiveGroup(group.id)}
            >
              <span>{group.label}</span>
              <strong>{counts[group.id]}</strong>
            </button>
          ))}
        </nav>

        {error && (
          <div className="artifacts-banner" role="alert">
            <span>{error}</span>
            <button type="button" className="ghost" onClick={() => setRefreshTick((value) => value + 1)}>
              {t('common.retry')}
            </button>
          </div>
        )}
        {loading && (
          <div className="artifacts-empty" role="status">
            <Loader2 size={15} className="spin" aria-hidden />
            <span>{t('artifacts.loading')}</span>
          </div>
        )}

        {!loading && (
          <div className="artifacts-index__body">
            <div
              className="artifacts-index__list"
              role="region"
              aria-label={t('artifacts.indexList')}
              onScroll={(event) => {
                const estimatedStart = Math.floor(event.currentTarget.scrollTop / ARTIFACT_ROW_HEIGHT) - 10
                const maxStart = Math.max(0, allItems.length - ARTIFACT_WINDOW_SIZE)
                setWindowStart(Math.min(maxStart, Math.max(0, estimatedStart)))
              }}
            >
              {allItems.length === 0 && !error ? (
                <div className="artifacts-empty">
                  <Archive size={15} aria-hidden />
                  <span>{availableTotal > 0 ? t('artifacts.filteredEmpty') : t('artifacts.neverProduced')}</span>
                  {availableTotal > 0 ? (
                    <button type="button" className="ghost" onClick={() => {
                      setQuery('')
                      setDebouncedQuery('')
                      setActiveGroup('all')
                      setCanvasFilter('all')
                      setStateFilter('all')
                      onClearSessionFilter?.()
                    }}>
                      {t('artifacts.clearFilters')}
                    </button>
                  ) : activeCanvasId ? (
                    <button type="button" className="ghost" onClick={() => onOpenCanvas(activeCanvasId)}>
                      {t('artifacts.openCanvasButton')}
                    </button>
                  ) : null}
                </div>
              ) : allItems.length > 0 ? (
                <table className="artifacts-table">
                  <thead>
                    <tr>
                      <th>{t('artifacts.tableTitle')}</th>
                      <th>{t('artifacts.tableType')}</th>
                      <th>{t('artifacts.tableCanvas')}</th>
                      <th>{t('artifacts.tableLatest')}</th>
                    </tr>
                  </thead>
                  <tbody>
                    {windowStart > 0 && (
                      <tr className="artifacts-table__spacer" role="presentation" aria-hidden>
                        <td colSpan={4} style={{ height: windowStart * ARTIFACT_ROW_HEIGHT }} />
                      </tr>
                    )}
                    {mountedItems.map((item) => (
                      <tr
                        key={item.key}
                        onClick={() => setPreviewKey(item.key)}
                      >
                        <td>
                          <button
                            type="button"
                            className="artifacts-row-button"
                            onClick={() => setPreviewKey(item.key)}
                          >
                            <span className="artifacts-row-icon" data-group={item.groupId} aria-hidden>
                              {(() => {
                                const GroupIcon = ARTIFACT_GROUP_ICONS[item.groupId] ?? Archive
                                return <GroupIcon size={14} />
                              })()}
                            </span>
                            <span className="artifacts-row-text">
                              <span>{item.latest.title}</span>
                              <small>{item.node?.title ?? item.latest.nodeId}</small>
                            </span>
                          </button>
                        </td>
                        <td>
                          <ArtifactBadges item={item} t={t} />
                        </td>
                        <td>
                          <span className="artifacts-table__canvas">{item.canvas.name || item.canvas.id}</span>
                        </td>
                        <td>
                          <span className="artifacts-table__date">{formatDate(item.latest.createdAt)}</span>
                        </td>
                      </tr>
                    ))}
                    {windowStart + mountedItems.length < allItems.length && (
                      <tr className="artifacts-table__spacer" role="presentation" aria-hidden>
                        <td
                          colSpan={4}
                          style={{ height: (allItems.length - windowStart - mountedItems.length) * ARTIFACT_ROW_HEIGHT }}
                        />
                      </tr>
                    )}
                  </tbody>
                </table>
              ) : null}
              {hasMore && (
                <div className="artifacts-index__pagination" role="status" aria-live="polite">
                  <button
                    type="button"
                    className="ghost"
                    disabled={loadingMore}
                    onClick={loadMore}
                  >
                    {loadingMore ? t('common.loading') : t('artifacts.loadMore')}
                  </button>
                </div>
              )}
            </div>

          </div>
        )}
      {previewItem && (
        <ArtifactPreviewDialog
          key={previewItem.key}
          item={previewItem}
          activeCanvasId={activeCanvasId}
          reviewActionKey={reviewActionKey}
          onClose={() => setPreviewKey(null)}
          onOpenCanvas={onOpenCanvas}
          onOpenSource={openSourceArtifact}
          onOpenExternal={openExternalArtifact}
          onReviewArtifact={reviewArtifact}
        />
      )}
    </PageShell>
  )
}

function SelectFilter({
  label,
  value,
  options,
  onChange,
}: {
  label: string
  value: string
  options: Array<{ value: string; label: string }>
  onChange: (value: string) => void
}) {
  return (
    <label className="artifacts-select-filter">
      <span>{label}</span>
      <select value={value} onChange={(event) => onChange(event.target.value)}>
        {options.map((option) => (
          <option key={option.value} value={option.value}>{option.label}</option>
        ))}
      </select>
    </label>
  )
}

function pageItemsToIndex(items: ArtifactPageItem[]): ArtifactIndexItem[] {
  return items.flatMap((item) => {
    const indexed = buildArtifactIndex([{
      canvas: item.canvas,
      nodes: item.node ? [item.node] : [],
      artifacts: item.artifacts,
    }])[0]
    if (!indexed) return []
    return [{
      ...indexed,
      sessionId: item.sessionId ?? indexed.sessionId,
    }]
  })
}

function mergeIndexItems(current: ArtifactIndexItem[], incoming: ArtifactIndexItem[]): ArtifactIndexItem[] {
  const byKey = new Map(current.map((item) => [item.key, item]))
  for (const item of incoming) byKey.set(item.key, item)
  return Array.from(byKey.values()).sort(
    (a, b) => new Date(b.latest.createdAt).getTime() - new Date(a.latest.createdAt).getTime(),
  )
}

function normalizedGroupCounts(raw: Record<string, number>): Record<ArtifactTypeGroupId, number> {
  const counts = artifactGroupCounts([])
  for (const group of ARTIFACT_TYPE_GROUPS) {
    counts[group.id] = Math.max(0, raw[group.id] ?? 0)
  }
  return counts
}

function ArtifactBadges({
  item,
  t,
}: {
  item: ArtifactIndexItem
  t: ReturnType<typeof useI18n>['t']
}) {
  return (
    <div className="artifacts-badges">
      <span className="artifacts-type-label" data-group={item.groupId}>{item.typeLabel}</span>
      <span className={`artifacts-state-badge is-${item.displayState}`}>{artifactStateLabel(item.displayState, t)}</span>
      {item.latest.positionTag && item.latest.positionTag !== 'latest' && (
        <span className={`artifacts-card__position artifacts-card__position--${item.latest.positionTag}`}>
          {item.latest.positionTag}
        </span>
      )}
    </div>
  )
}

function formatDate(value: string): string {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return date.toLocaleString(undefined, {
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

function artifactStateLabel(state: ArtifactDisplayState, t: ReturnType<typeof useI18n>['t']): string {
  switch (state) {
    case 'ready':
      return t('artifacts.stateReady')
    case 'needs-review':
      return t('artifacts.stateNeedsReview')
    case 'rejected':
      return t('artifacts.stateRejected')
    case 'failed':
      return t('artifacts.stateFailed')
    case 'stale':
      return t('artifacts.stateStale')
    case 'working':
      return t('artifacts.stateWorking')
    case 'other':
      return t('artifacts.stateOther')
  }
}

function artifactExternalUrl(artifact: PlannerArtifact): string | null {
  const typedUrl = artifact.typedPayload?.type === 'integration'
    ? artifact.typedPayload.externalUrl
    : null
  if (typedUrl && isHttpUrl(typedUrl)) return typedUrl
  if (isHttpUrl(artifact.reference)) return artifact.reference
  return null
}

function isHttpUrl(value: string | null | undefined): value is string {
  if (!value) return false
  try {
    const url = new URL(value)
    return url.protocol === 'http:' || url.protocol === 'https:'
  } catch {
    return false
  }
}
