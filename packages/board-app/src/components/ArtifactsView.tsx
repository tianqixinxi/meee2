import {
  Archive,
  CheckCircle2,
  ExternalLink,
  FileText,
  GitCompare,
  Loader2,
  Search,
  X,
  XCircle,
} from 'lucide-react'
import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  fetchPlannerGraphState,
  fetchArtifactCandidates,
  getArtifactVersion,
  getPlannerArtifactContent,
  listArtifactVersions,
  proposePlannerGraphChange,
} from '../api'
import { useToast } from '../App'
import { requestBoardTarget } from '../lib/boardTarget'
import {
  ARTIFACT_TYPE_GROUPS,
  artifactGroupCounts,
  buildCandidateArtifactIndex,
  buildArtifactIndex,
  filterArtifactIndex,
  type ArtifactDisplayState,
  type ArtifactIndexItem,
  type ArtifactTypeGroupId,
  type CanvasArtifactsSource,
} from '../lib/artifactIndex'
import { resolvedArtifactPayload } from '../lib/artifactPayload'
import { useI18n } from '../lib/i18n'
import type {
  ArtifactPayload,
  ArtifactReviewStatus,
  CanvasInfo,
  CanvasScope,
  PlanProposal,
  PlannerArtifact,
  PlannerArtifactContent,
  PlannerArtifactVersion,
} from '../types'
import { ArtifactViewTabs } from './artifacts/ArtifactViewTabs'

type StateFilter = ArtifactDisplayState | 'all'
type CanvasFilter = string | 'all'
type ScopeFilter = CanvasScope | 'all'

export interface ArtifactSessionFilter {
  sessionId: string
  title: string
  providerResumeSessionId?: string | null
  surfaceId?: string | null
  project?: string | null
  projectName?: string | null
}

const ARTIFACT_STATE_ORDER: ArtifactDisplayState[] = [
  'candidate',
  'needs-review',
  'ready',
  'working',
  'failed',
  'stale',
  'rejected',
  'other',
]

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
  const [activeGroup, setActiveGroup] = useState<ArtifactTypeGroupId | 'all'>('all')
  const [scopeFilter, setScopeFilter] = useState<ScopeFilter>('all')
  const [canvasFilter, setCanvasFilter] = useState<CanvasFilter>('all')
  const [stateFilter, setStateFilter] = useState<StateFilter>('all')
  const [sources, setSources] = useState<CanvasArtifactsSource[]>([])
  const [candidateItems, setCandidateItems] = useState<ArtifactIndexItem[]>([])
  const [selectedKey, setSelectedKey] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [reviewActionKey, setReviewActionKey] = useState<string | null>(null)
  const [contentByArtifactId, setContentByArtifactId] = useState<Record<string, PlannerArtifactContent>>({})
  const [contentLoading, setContentLoading] = useState<Set<string>>(() => new Set())
  const [versionsBySlot, setVersionsBySlot] = useState<Record<string, PlannerArtifactVersion[]>>({})
  const [versionsLoading, setVersionsLoading] = useState<Set<string>>(() => new Set())
  const [selectedVersionBySlot, setSelectedVersionBySlot] = useState<Record<string, string>>({})
  const [versionDetailById, setVersionDetailById] = useState<Record<string, PlannerArtifactVersion>>({})
  const [contentModalKey, setContentModalKey] = useState<string | null>(null)
  const [refreshTick, setRefreshTick] = useState(0)

  const canvasSignature = useMemo(
    () => canvases.map((canvas) => `${canvas.id}:${canvas.name}`).join('|'),
    [canvases],
  )

  useEffect(() => {
    let cancelled = false
    setLoading(true)
    setError(null)
    Promise.all([
      Promise.all(canvases.map(async (canvas) => {
      try {
        const state = await fetchPlannerGraphState(canvas.id)
        return {
          canvas,
          nodes: state.nodes,
          artifacts: state.artifacts ?? [],
        } satisfies CanvasArtifactsSource
      } catch (err) {
        return {
          canvas,
          nodes: [],
          artifacts: [],
          error: (err as Error).message || t('artifacts.loadFailed'),
        } satisfies CanvasArtifactsSource
      }
    })),
      fetchArtifactCandidates(sessionFilter?.sessionId).catch(() => ({ candidates: [] })),
    ])
      .then(([items, candidateEnvelope]) => {
        if (cancelled) return
        setSources(items)
        setCandidateItems(buildCandidateArtifactIndex(candidateEnvelope.candidates))
        const failures = items.filter((item) => item.error)
        setError(failures.length ? t('artifacts.groupLoadFailed', { count: failures.length }) : null)
      })
      .catch((err) => {
        if (!cancelled) setError((err as Error).message || t('artifacts.loadFailed'))
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [canvasSignature, refreshTick, sessionFilter?.sessionId, t])

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

  const allItems = useMemo(() => [
    ...buildArtifactIndex(sources),
    ...candidateItems,
  ].sort((a, b) => new Date(b.latest.createdAt).getTime() - new Date(a.latest.createdAt).getTime()), [candidateItems, sources])
  const sessionScopedItems = useMemo(
    () => sessionFilter?.sessionId
      ? allItems.filter((item) => artifactMatchesSessionFilter(item, sessionFilter))
      : allItems,
    [allItems, sessionFilter],
  )
  const counts = useMemo(() => artifactGroupCounts(sessionScopedItems), [sessionScopedItems])
  const filteredItems = useMemo(
    () => filterArtifactIndex(sessionScopedItems, {
      query,
      groupId: activeGroup,
      scope: scopeFilter,
      canvasId: canvasFilter,
      displayState: stateFilter,
    }),
    [activeGroup, canvasFilter, query, scopeFilter, sessionScopedItems, stateFilter],
  )
  const selectedItem = useMemo(
    () => filteredItems.find((item) => item.key === selectedKey) ?? filteredItems[0] ?? null,
    [filteredItems, selectedKey],
  )
  const canvasOptions = useMemo(
    () => canvases.filter((canvas) => (
      (scopeFilter === 'all' || canvas.scope === scopeFilter)
      && sessionScopedItems.some((item) => item.canvas.id === canvas.id)
    )),
    [canvases, scopeFilter, sessionScopedItems],
  )
  const stateOptions = useMemo(
    () => ARTIFACT_STATE_ORDER.filter((state) => sessionScopedItems.some((item) => item.displayState === state)),
    [sessionScopedItems],
  )

  useEffect(() => {
    if (!selectedItem) {
      setSelectedKey(null)
    } else if (selectedItem.key !== selectedKey) {
      setSelectedKey(selectedItem.key)
    }
  }, [selectedItem, selectedKey])

  const loadContent = useCallback((artifact: PlannerArtifact): Promise<PlannerArtifactContent | undefined> => {
    if (artifact.typedPayload) return Promise.resolve(undefined)
    if (contentByArtifactId[artifact.id]) return Promise.resolve(contentByArtifactId[artifact.id])
    if (contentLoading.has(artifact.id)) return Promise.resolve(undefined)
    setContentLoading((current) => new Set(current).add(artifact.id))
    return getPlannerArtifactContent(artifact.canvasId, artifact.id)
      .then((content) => {
        setContentByArtifactId((current) => ({ ...current, [artifact.id]: content }))
        return content
      })
      .catch((err) => {
        const fallback: PlannerArtifactContent = {
          artifactId: artifact.id,
          type: 'text',
          mimeType: 'text/plain',
          content: (err as Error).message || 'Failed to load artifact content',
        }
        setContentByArtifactId((current) => ({
          ...current,
          [artifact.id]: fallback,
        }))
        return fallback
      })
      .finally(() => {
        setContentLoading((current) => {
          const next = new Set(current)
          next.delete(artifact.id)
          return next
        })
      })
  }, [contentByArtifactId, contentLoading])

  const contentModalItem = useMemo(
    () => allItems.find((item) => item.key === contentModalKey) ?? null,
    [allItems, contentModalKey],
  )

  const openExternalArtifact = useCallback((item: ArtifactIndexItem): boolean => {
    if (item.sourceKind === 'candidate') {
      const ref = item.candidate?.references.find((reference) => reference.kind === 'url')
      if (!ref) return false
      window.open(ref.value, '_blank', 'noopener,noreferrer')
      return true
    }
    const url = artifactExternalUrl(item.latest)
    if (!url) return false
    window.open(url, '_blank', 'noopener,noreferrer')
    return true
  }, [])

  const loadVersions = useCallback((item: ArtifactIndexItem) => {
    if (item.sourceKind === 'candidate') return
    if (versionsBySlot[item.key] || versionsLoading.has(item.key)) return
    setVersionsLoading((current) => new Set(current).add(item.key))
    listArtifactVersions(item.canvas.id, item.latest.nodeId, item.latest.reference)
      .then(({ versions }) => {
        setVersionsBySlot((current) => ({ ...current, [item.key]: versions }))
        const newest = versions[0]
        if (newest) {
          setSelectedVersionBySlot((current) => ({ ...current, [item.key]: newest.version_id }))
          setVersionDetailById((current) => ({ ...current, [newest.version_id]: newest }))
        }
      })
      .catch(() => {
        setVersionsBySlot((current) => ({ ...current, [item.key]: [] }))
      })
      .finally(() => {
        setVersionsLoading((current) => {
          const next = new Set(current)
          next.delete(item.key)
          return next
        })
      })
  }, [versionsBySlot, versionsLoading])

  useEffect(() => {
    if (!selectedItem) return
    if (selectedItem.sourceKind === 'candidate') return
    loadContent(selectedItem.latest)
    loadVersions(selectedItem)
  }, [loadContent, loadVersions, selectedItem])

  const selectVersion = (item: ArtifactIndexItem, versionId: string) => {
    setSelectedVersionBySlot((current) => ({ ...current, [item.key]: versionId }))
    if (versionDetailById[versionId]) return
    getArtifactVersion(item.canvas.id, versionId)
      .then((version) => setVersionDetailById((current) => ({ ...current, [version.version_id]: version })))
      .catch(() => undefined)
  }

  const openSourceArtifact = useCallback((item: ArtifactIndexItem) => {
    if (item.sourceKind === 'candidate') {
      openExternalArtifact(item)
      return
    }
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
  }, [openExternalArtifact])

  const openContentPreview = useCallback((item: ArtifactIndexItem) => {
    if (item.sourceKind === 'candidate') {
      setContentModalKey(item.key)
      return
    }
    if (resolvedArtifactPayload(item.latest)) {
      setContentModalKey(item.key)
      return
    }
    void loadContent(item.latest).then((content) => {
      const nextContent = content ?? contentByArtifactId[item.latest.id]
      if (nextContent && !isRenderableArtifactContent(nextContent)) {
        if (openExternalArtifact(item)) return
        openSourceArtifact(item)
        return
      }
      setContentModalKey(item.key)
    })
  }, [contentByArtifactId, loadContent, openExternalArtifact, openSourceArtifact])

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
    <section className="artifacts-workspace" aria-label={t('artifacts.title')}>
      <div className="artifacts-workspace__inner artifacts-index">
        <header className="artifacts-workspace__header artifacts-index__header">
          <div>
            <span>{t('artifacts.scope')}</span>
            <h1>{t('artifacts.title')}</h1>
            <p>
              {loading
                ? t('artifacts.loadingSlots')
                : t('artifacts.summary', { slots: filteredItems.length, canvases: sources.length })}
            </p>
            {sessionFilter && (
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
          </div>
          <div className="artifacts-workspace__tools">
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
                label={t('artifacts.scopeFilter')}
                value={scopeFilter}
                onChange={(value) => {
                  setScopeFilter(value as ScopeFilter)
                  setCanvasFilter('all')
                }}
                options={[
                  { value: 'all', label: t('artifacts.scopeAll') },
                  { value: 'personal', label: t('artifacts.scopePersonal') },
                  { value: 'team', label: t('artifacts.scopeTeam') },
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
        </header>

        {error && <div className="artifacts-banner" role="status">{error}</div>}
        {loading && (
          <div className="artifacts-empty" role="status">
            <Loader2 size={15} className="spin" aria-hidden />
            <span>{t('artifacts.loading')}</span>
          </div>
        )}

        {!loading && (
          <div className="artifacts-index__body">
            <aside className="artifacts-index__types" aria-label={t('artifacts.typeDirectory')}>
              <button
                type="button"
                className={`artifacts-type-button${activeGroup === 'all' ? ' is-active' : ''}`}
                onClick={() => setActiveGroup('all')}
              >
                <span>{t('artifacts.typeAll')}</span>
                <strong>{sessionScopedItems.length}</strong>
              </button>
              {ARTIFACT_TYPE_GROUPS.map((group) => (
                <button
                  type="button"
                  key={group.id}
                  className={`artifacts-type-button${activeGroup === group.id ? ' is-active' : ''}`}
                  onClick={() => setActiveGroup(group.id)}
                >
                  <span>{group.label}</span>
                  <strong>{counts[group.id]}</strong>
                </button>
              ))}
            </aside>

            <div className="artifacts-index__list" role="region" aria-label={t('artifacts.indexList')}>
              {filteredItems.length === 0 ? (
                <div className="artifacts-empty">
                  <Archive size={15} aria-hidden />
                  <span>{t('artifacts.empty')}</span>
                </div>
              ) : (
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
                    {filteredItems.map((item) => (
                      <tr
                        key={item.key}
                        className={item.key === selectedItem?.key ? 'is-selected' : ''}
                      >
                        <td>
                          <button
                            type="button"
                            className="artifacts-row-button"
                            onClick={() => setSelectedKey(item.key)}
                          >
                            <span>{item.latest.title}</span>
                            <small>{item.node?.title ?? item.latest.nodeId}</small>
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
                  </tbody>
                </table>
              )}
            </div>

            <ArtifactDetailPanel
              item={selectedItem}
              activeCanvasId={activeCanvasId}
              content={selectedItem ? contentByArtifactId[selectedItem.latest.id] : undefined}
              contentLoading={selectedItem ? contentLoading.has(selectedItem.latest.id) : false}
              versions={selectedItem ? versionsBySlot[selectedItem.key] : undefined}
              versionsLoading={selectedItem ? versionsLoading.has(selectedItem.key) : false}
              selectedVersionId={selectedItem ? selectedVersionBySlot[selectedItem.key] : undefined}
              selectedVersion={selectedItem && selectedVersionBySlot[selectedItem.key]
                ? versionDetailById[selectedVersionBySlot[selectedItem.key]]
                : undefined}
              onOpenContent={openContentPreview}
              onLoadVersions={(item) => loadVersions(item)}
              onSelectVersion={selectVersion}
              onOpenCanvas={onOpenCanvas}
              onOpenSource={openSourceArtifact}
              onReviewArtifact={reviewArtifact}
              reviewActionKey={reviewActionKey}
              t={t}
            />
          </div>
        )}
      </div>
      {contentModalItem && (
        <ArtifactContentModal
          item={contentModalItem}
          content={contentByArtifactId[contentModalItem.latest.id]}
          loading={contentLoading.has(contentModalItem.latest.id)}
          onClose={() => setContentModalKey(null)}
          onOpenExternal={() => {
            if (!openExternalArtifact(contentModalItem)) openSourceArtifact(contentModalItem)
          }}
          onOpenSource={() => openSourceArtifact(contentModalItem)}
          t={t}
        />
      )}
    </section>
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

function artifactMatchesSessionFilter(item: ArtifactIndexItem, filter: ArtifactSessionFilter): boolean {
  const ids = [
    filter.sessionId,
    filter.providerResumeSessionId,
    filter.surfaceId,
  ].map(normalizeToken).filter(Boolean)
  const itemSessionId = normalizeToken(item.sessionId)
  if (itemSessionId && ids.includes(itemSessionId)) return true

  const projectTokens = [
    filter.project,
    filter.projectName,
  ].flatMap(projectMatchTokens)
  if (projectTokens.length === 0) return false

  const canvasTokens = [
    item.canvas.workspacePath,
    item.canvas.name,
    item.canvas.id,
  ].flatMap(projectMatchTokens)
  return canvasTokens.some((token) => projectTokens.includes(token))
}

function projectMatchTokens(value: string | null | undefined): string[] {
  const normalized = normalizePathToken(value)
  if (!normalized) return []
  const base = normalized.split('/').filter(Boolean).pop()
  return [normalized, base].filter((token): token is string => Boolean(token))
}

function normalizeToken(value: string | null | undefined): string {
  return value?.trim().toLowerCase() ?? ''
}

function normalizePathToken(value: string | null | undefined): string {
  return normalizeToken(value).replace(/\/+$/, '')
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
      <span>{item.typeLabel}</span>
      <span className={`artifacts-state-badge is-${item.displayState}`}>{artifactStateLabel(item.displayState, t)}</span>
      {item.latest.positionTag && item.latest.positionTag !== 'latest' && (
        <span className={`artifacts-card__position artifacts-card__position--${item.latest.positionTag}`}>
          {item.latest.positionTag}
        </span>
      )}
    </div>
  )
}

function ArtifactDetailPanel({
  item,
  activeCanvasId,
  content,
  contentLoading,
  versions,
  versionsLoading,
  selectedVersionId,
  selectedVersion,
  onOpenContent,
  onLoadVersions,
  onSelectVersion,
  onOpenCanvas,
  onOpenSource,
  onReviewArtifact,
  reviewActionKey,
  t,
}: {
  item: ArtifactIndexItem | null
  activeCanvasId: string
  content?: PlannerArtifactContent
  contentLoading: boolean
  versions?: PlannerArtifactVersion[]
  versionsLoading: boolean
  selectedVersionId?: string
  selectedVersion?: PlannerArtifactVersion
  onOpenContent: (item: ArtifactIndexItem) => void
  onLoadVersions: (item: ArtifactIndexItem) => void
  onSelectVersion: (item: ArtifactIndexItem, versionId: string) => void
  onOpenCanvas: (canvasId: string) => void
  onOpenSource: (item: ArtifactIndexItem) => void
  onReviewArtifact: (item: ArtifactIndexItem, reviewStatus: ArtifactReviewStatus) => void
  reviewActionKey: string | null
  t: ReturnType<typeof useI18n>['t']
}) {
  if (!item) {
    return (
      <aside className="artifacts-detail" aria-label={t('artifacts.detailPanel')}>
        <div className="artifacts-detail__empty">
          <Archive size={16} aria-hidden />
          <span>{t('artifacts.empty')}</span>
        </div>
      </aside>
    )
  }
  const isCandidate = item.sourceKind === 'candidate'

  return (
    <aside className="artifacts-detail" aria-label={t('artifacts.detailPanel')}>
      <header className="artifacts-detail__header">
        <div>
          <span>{item.typeLabel}</span>
          <h2>{item.latest.title}</h2>
          <p>{item.latest.reference}</p>
        </div>
        <ArtifactBadges item={item} t={t} />
      </header>

      <dl className="artifacts-detail__meta">
        <div>
          <dt>{t('artifacts.tableCanvas')}</dt>
          <dd>{item.canvas.name || item.canvas.id}</dd>
        </div>
        <div>
          <dt>{t('artifacts.node')}</dt>
          <dd>{isCandidate ? item.latest.nodeId.slice(0, 8) : (item.node?.title ?? item.latest.nodeId)}</dd>
        </div>
        <div>
          <dt>{t('artifacts.latest')}</dt>
          <dd>{formatDate(item.latest.createdAt)}</dd>
        </div>
        <div>
          <dt>{t('artifacts.versionCount')}</dt>
          <dd>{isCandidate ? t('artifacts.candidate') : item.artifacts.length}</dd>
        </div>
      </dl>

      <section className="artifacts-detail__section">
        <h3>{t('artifacts.preview')}</h3>
        {contentLoading ? (
          <div className="artifacts-preview artifacts-preview--loading">
            <Loader2 size={14} className="spin" aria-hidden />
            <span>{t('artifacts.loadingLatest')}</span>
          </div>
        ) : (
          <ArtifactDetailPreview artifact={item.latest} content={content} t={t} />
        )}
      </section>

      {isCandidate ? (
        <section className="artifacts-detail__section">
          <h3>{t('artifacts.references')}</h3>
          <CandidateReferences item={item} />
        </section>
      ) : (
      <section className="artifacts-detail__section">
        <div className="artifacts-detail__section-head">
          <h3>{t('artifacts.versions')}</h3>
          <button
            type="button"
            className="artifacts-link-button"
            onClick={() => onLoadVersions(item)}
          >
            {versionsLoading ? t('artifacts.loadingVersions') : t('artifacts.loadVersions')}
          </button>
        </div>
        {versionsLoading && !versions ? (
          <div className="artifacts-preview artifacts-preview--loading">
            <Loader2 size={14} className="spin" aria-hidden />
            <span>{t('artifacts.loadingVersions')}</span>
          </div>
        ) : versions && versions.length > 0 ? (
          <div className="artifacts-versions">
            <label>
              <span>{t('artifacts.version')}</span>
              <select
                value={selectedVersionId ?? ''}
                onChange={(event) => onSelectVersion(item, event.target.value)}
              >
                {versions.map((version) => (
                  <option value={version.version_id} key={version.version_id}>
                    {formatDate(version.created_at)} - {version.submitted_by_kind}
                  </option>
                ))}
              </select>
            </label>
            <VersionSummary version={selectedVersion} t={t} />
            <CompareVersionView versions={versions} t={t} />
          </div>
        ) : (
          <div className="artifacts-preview">{t('artifacts.noVersions')}</div>
        )}
      </section>
      )}

      <footer className="artifacts-detail__actions">
        {item.displayState === 'needs-review' && !isCandidate && (
          <>
            <button
              type="button"
              className="artifacts-open-button"
              disabled={Boolean(reviewActionKey)}
              onClick={() => onReviewArtifact(item, 'approved')}
            >
              <CheckCircle2 size={14} aria-hidden />
              <span>{reviewActionKey === `${item.key}:approved` ? t('artifacts.reviewSubmitting') : t('artifacts.approve')}</span>
            </button>
            <button
              type="button"
              className="artifacts-link-button danger"
              disabled={Boolean(reviewActionKey)}
              onClick={() => onReviewArtifact(item, 'rejected')}
            >
              <XCircle size={14} aria-hidden />
              <span>{reviewActionKey === `${item.key}:rejected` ? t('artifacts.reviewSubmitting') : t('artifacts.reject')}</span>
            </button>
          </>
        )}
        <button
          type="button"
          className="artifacts-open-button"
          onClick={() => onOpenSource(item)}
        >
          <ExternalLink size={14} aria-hidden />
          <span>{t('artifacts.revealSource')}</span>
        </button>
        {!isCandidate && (
          <button
            type="button"
            className="artifacts-link-button"
            onClick={() => onOpenCanvas(item.canvas.id)}
          >
            <FileText size={13} aria-hidden />
            <span>{item.canvas.id === activeCanvasId ? t('artifacts.currentCanvas') : t('artifacts.openCanvasButton')}</span>
          </button>
        )}
        <button
          type="button"
          className="artifacts-load-button"
          onClick={() => onOpenContent(item)}
        >
          <GitCompare size={13} aria-hidden />
          <span>{t('artifacts.loadContent')}</span>
        </button>
      </footer>
    </aside>
  )
}

function ArtifactContentModal({
  item,
  content,
  loading,
  onClose,
  onOpenExternal,
  onOpenSource,
  t,
}: {
  item: ArtifactIndexItem
  content?: PlannerArtifactContent
  loading: boolean
  onClose: () => void
  onOpenExternal: () => void
  onOpenSource: () => void
  t: ReturnType<typeof useI18n>['t']
}) {
  const canRender = Boolean(resolvedArtifactPayload(item.latest, content) || (content && isRenderableArtifactContent(content)))
  return (
    <div className="artifacts-content-modal-backdrop" role="presentation" onClick={onClose}>
      <section
        className="artifacts-content-modal"
        role="dialog"
        aria-modal="true"
        aria-label={t('artifacts.contentModalTitle')}
        onClick={(event) => event.stopPropagation()}
      >
        <header className="artifacts-content-modal__header">
          <div>
            <span>{item.typeLabel}</span>
            <h2>{item.latest.title}</h2>
            <p>{item.latest.reference}</p>
          </div>
          <button
            type="button"
            className="artifacts-content-modal__close"
            aria-label={t('common.close')}
            onClick={onClose}
          >
            <X size={16} aria-hidden />
          </button>
        </header>
        <div className="artifacts-content-modal__body">
          <div className="artifacts-content-modal__preview">
            {loading ? (
              <div className="artifacts-preview artifacts-preview--loading">
                <Loader2 size={14} className="spin" aria-hidden />
                <span>{t('artifacts.loadingLatest')}</span>
              </div>
            ) : canRender ? (
              <ArtifactRenderedContent artifact={item.latest} content={content} t={t} />
            ) : (
              <div className="artifacts-content-modal__unsupported">
                <strong>{t('artifacts.unsupportedPreview')}</strong>
                <p>{t('artifacts.unsupportedPreviewHint')}</p>
                <div>
                  <button type="button" className="artifacts-open-button" onClick={onOpenExternal}>
                    <ExternalLink size={14} aria-hidden />
                    <span>{t('artifacts.openExternally')}</span>
                  </button>
                  <button type="button" className="artifacts-link-button" onClick={onOpenSource}>
                    <FileText size={13} aria-hidden />
                    <span>{t('artifacts.revealSource')}</span>
                  </button>
                </div>
              </div>
            )}
          </div>
          <ArtifactSupportList t={t} />
        </div>
      </section>
    </div>
  )
}

function CandidateReferences({ item }: { item: ArtifactIndexItem }) {
  const refs = item.candidate?.references ?? []
  if (refs.length === 0) {
    return <TextSummary text={item.candidate?.summary ?? ''} fallback={item.latest.reference} />
  }
  return (
    <div className="artifacts-candidate-refs">
      {refs.map((reference, index) => (
        <button
          type="button"
          key={`${reference.kind}:${reference.value}:${index}`}
          onClick={() => openCandidateReference(reference.value)}
          title={reference.value}
        >
          <span>{reference.kind}</span>
          <strong>{reference.label ?? reference.value}</strong>
        </button>
      ))}
    </div>
  )
}

function openCandidateReference(value: string) {
  if (/^https?:\/\//i.test(value) || /^file:\/\//i.test(value)) {
    window.open(value, '_blank', 'noopener,noreferrer')
    return
  }
  if (value.startsWith('/')) {
    window.open(`file://${value}`, '_blank', 'noopener,noreferrer')
  }
}

function ArtifactRenderedContent({
  artifact,
  content,
  t,
}: {
  artifact: PlannerArtifact
  content?: PlannerArtifactContent
  t: ReturnType<typeof useI18n>['t']
}) {
  const typedPayload = resolvedArtifactPayload(artifact, content)
  // typedPayload 在手时不需要 content 也能渲染(openContentPreview 对带
  // typedPayload 的 artifact 会跳过 loadContent 直接开 modal)— 只有真的
  // 什么都没有才提示去加载。
  if (!content && !typedPayload && artifact.payload == null) {
    return <div className="artifacts-preview">{t('artifacts.openDetailsPrompt')}</div>
  }
  if (content?.type === 'html' && !artifact.views?.length) {
    return (
      <iframe
        className="artifacts-html-preview"
        title={artifact.title}
        sandbox=""
        srcDoc={content.content ?? ''}
      />
    )
  }
  if (typedPayload || content || artifact.payload != null) {
    return <ArtifactViewTabs artifact={artifact} content={content} />
  }
  return <ArtifactContentPreview content={content} t={t} />
}

function ArtifactSupportList({ t }: { t: ReturnType<typeof useI18n>['t'] }) {
  return (
    <aside className="artifacts-content-modal__support">
      <h3>{t('artifacts.supportedTitle')}</h3>
      <dl>
        <div>
          <dt>{t('artifacts.supportedModal')}</dt>
          <dd>prd, kanban, impl-pr, check-result, file metadata, markdown, integration, text, json, html</dd>
        </div>
        <div>
          <dt>{t('artifacts.unsupportedModal')}</dt>
          <dd>binary file blobs, unknown payloads without text/html/json content</dd>
        </div>
      </dl>
    </aside>
  )
}

function ArtifactContentPreview({ content, t }: { content?: PlannerArtifactContent; t: ReturnType<typeof useI18n>['t'] }) {
  if (!content) {
    return (
      <div className="artifacts-preview">
        <span>{t('artifacts.openDetailsPrompt')}</span>
      </div>
    )
  }
  if (content.type === 'file') {
    return (
      <dl className="artifacts-file-meta">
        <div>
          <dt>{t('artifacts.filename')}</dt>
          <dd>{content.filename ?? t('artifacts.fileArtifact')}</dd>
        </div>
        <div>
          <dt>{t('artifacts.mimeType')}</dt>
          <dd>{content.mimeType || 'application/octet-stream'}</dd>
        </div>
        <div>
          <dt>{t('artifacts.size')}</dt>
          <dd>{formatBytes(content.size, t)}</dd>
        </div>
        <div>
          <dt>SHA-256</dt>
          <dd>{content.sha256 ?? t('artifacts.notRecorded')}</dd>
        </div>
      </dl>
    )
  }
  const preview = content.content ?? stringifyPreview(content.payload)
  return (
    <pre className="artifacts-preview">
      {preview || t('artifacts.noPreview')}
    </pre>
  )
}

function ArtifactDetailPreview({
  artifact,
  content,
  t,
}: {
  artifact: PlannerArtifact
  content?: PlannerArtifactContent
  t: ReturnType<typeof useI18n>['t']
}) {
  const payload = resolvedArtifactPayload(artifact, content)
  if (payload) return <TypedArtifactSummary payload={payload} t={t} />
  if (content) return <ContentSummary content={content} t={t} />
  if (artifact.payload != null) {
    return <TextSummary text={stringifyPreview(artifact.payload)} fallback={t('artifacts.noPreview')} />
  }
  return <ArtifactContentPreview content={content} t={t} />
}

function TypedArtifactSummary({ payload, t }: { payload: ArtifactPayload; t: ReturnType<typeof useI18n>['t'] }) {
  switch (payload.type) {
    case 'prd':
      return (
        <div className="artifacts-summary-preview">
          <TextSummary text={payload.tldr} fallback={t('artifacts.noPreview')} />
          {payload.sections.length > 0 && (
            <SummaryRows rows={payload.sections.slice(0, 4).map((section) => ({
              label: section.heading,
              value: `${section.lines} line${section.lines === 1 ? '' : 's'}`,
            }))} />
          )}
        </div>
      )
    case 'kanban': {
      const itemCount = payload.columns.reduce((sum, column) => sum + column.items.length, 0)
      return (
        <div className="artifacts-summary-preview">
          <SummaryRows rows={[
            { label: 'Columns', value: String(payload.columns.length) },
            { label: 'Items', value: String(itemCount) },
            ...payload.columns.slice(0, 4).map((column) => ({
              label: column.name,
              value: `${column.items.length} item${column.items.length === 1 ? '' : 's'}`,
            })),
          ]} />
        </div>
      )
    }
    case 'impl-pr':
      return (
        <div className="artifacts-summary-preview">
          <SummaryRows rows={[
            { label: 'PR', value: payload.number ? `#${payload.number}` : 'not recorded' },
            { label: 'Branch', value: payload.branch || 'not recorded' },
            { label: 'Base', value: payload.baseBranch || 'not recorded' },
            { label: 'Changed', value: `${payload.filesChanged} files, +${payload.insertions} / -${payload.deletions}` },
            { label: 'CI', value: payload.ciStatus },
          ]} />
        </div>
      )
    case 'check-result':
      return (
        <div className="artifacts-summary-preview">
          <SummaryRows rows={[
            { label: 'Passed', value: String(payload.pass) },
            { label: 'Failed', value: String(payload.fail) },
            { label: 'Skipped', value: String(payload.skip) },
          ]} />
          {payload.failing.length > 0 && <TextSummary text={payload.failing.slice(0, 4).join('\n')} fallback="" />}
        </div>
      )
    case 'file':
      return (
        <div className="artifacts-summary-preview">
          <SummaryRows rows={[
            { label: t('artifacts.filename'), value: payload.filename },
            { label: t('artifacts.mimeType'), value: payload.mime },
            { label: t('artifacts.size'), value: formatBytes(payload.sizeBytes, t) },
            ...(payload.lines != null ? [{ label: 'Lines', value: String(payload.lines) }] : []),
          ]} />
        </div>
      )
    case 'json':
      return (
        <div className="artifacts-summary-preview">
          <TextSummary text={payload.preview} fallback={t('artifacts.noPreview')} />
          <SummaryRows rows={payload.entries.slice(0, 5)} />
        </div>
      )
    case 'markdown':
      return <TextSummary text={payload.preview} fallback={t('artifacts.noPreview')} />
    case 'integration': {
      const fieldCount = payload.fields ? Object.keys(payload.fields).length : 0
      return (
        <div className="artifacts-summary-preview">
          <SummaryRows rows={[
            { label: 'Connector', value: payload.connector },
            { label: 'External ID', value: payload.externalId || 'not recorded' },
            ...(fieldCount > 0 ? [{ label: 'Fields', value: String(fieldCount) }] : []),
          ]} />
          {payload.summary && <TextSummary text={payload.summary} fallback="" />}
        </div>
      )
    }
  }
}

function ContentSummary({ content, t }: { content: PlannerArtifactContent; t: ReturnType<typeof useI18n>['t'] }) {
  if (content.type === 'file') return <ArtifactContentPreview content={content} t={t} />
  if (content.type === 'json' || content.type === 'kanban') {
    return <TextSummary text={summarizeStructuredContent(content)} fallback={t('artifacts.noPreview')} />
  }
  if (content.type === 'html') {
    return <TextSummary text={stripHtml(content.content ?? '')} fallback={t('artifacts.noPreview')} />
  }
  return <TextSummary text={content.content ?? stringifyPreview(content.payload)} fallback={t('artifacts.noPreview')} />
}

function SummaryRows({ rows }: { rows: Array<{ label?: string; key?: string; value: string }> }) {
  if (rows.length === 0) return null
  return (
    <dl className="artifacts-summary-rows">
      {rows.map((row, index) => (
        <div key={`${row.label ?? row.key ?? index}:${index}`}>
          <dt>{row.label ?? row.key}</dt>
          <dd>{row.value}</dd>
        </div>
      ))}
    </dl>
  )
}

function TextSummary({ text, fallback }: { text: string; fallback: string }) {
  const preview = truncatePreview(cleanPreviewText(text), 420)
  return (
    <pre className="artifacts-preview artifacts-preview--summary">
      {preview || fallback}
    </pre>
  )
}

function VersionSummary({ version, t }: { version?: PlannerArtifactVersion; t: ReturnType<typeof useI18n>['t'] }) {
  if (!version) return null
  return (
    <dl className="artifacts-version-summary">
      <div>
        <dt>{t('artifacts.payload')}</dt>
        <dd>{version.payload_ref}</dd>
      </div>
      <div>
        <dt>{t('artifacts.strategy')}</dt>
        <dd>{version.display_strategy}</dd>
      </div>
      <div>
        <dt>{t('artifacts.submittedBy')}</dt>
        <dd>{version.submitted_by ?? version.submitted_by_kind}</dd>
      </div>
    </dl>
  )
}

function CompareVersionView({ versions, t }: { versions: PlannerArtifactVersion[]; t: ReturnType<typeof useI18n>['t'] }) {
  const [latest, previous] = versions
  if (!latest || !previous) {
    return <div className="artifacts-preview">{t('artifacts.needTwoVersions')}</div>
  }
  return (
    <div className="artifacts-compare">
      {[latest, previous].map((version, index) => (
        <div key={version.version_id}>
          <strong>{index === 0 ? t('artifacts.latest') : t('artifacts.previous')}</strong>
          <span>{formatDate(version.created_at)}</span>
          <code>{version.payload_ref}</code>
        </div>
      ))}
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

function formatBytes(value: number | null | undefined, t: ReturnType<typeof useI18n>['t']): string {
  if (value == null) return t('artifacts.notRecorded')
  if (value < 1024) return `${value} B`
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`
  return `${(value / (1024 * 1024)).toFixed(1)} MB`
}

function artifactStateLabel(state: ArtifactDisplayState, t: ReturnType<typeof useI18n>['t']): string {
  switch (state) {
    case 'candidate':
      return t('artifacts.candidate')
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

function isRenderableArtifactContent(content: PlannerArtifactContent): boolean {
  const type = content.type.toLowerCase()
  if (type === 'text' || type === 'json' || type === 'kanban' || type === 'html') return true
  return Boolean(content.content && content.mimeType.toLowerCase().startsWith('text/'))
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

function summarizeStructuredContent(content: PlannerArtifactContent): string {
  const raw = content.content ?? stringifyPreview(content.payload)
  if (!raw) return ''
  try {
    const parsed = JSON.parse(raw)
    if (Array.isArray(parsed)) return `JSON array · ${parsed.length} item${parsed.length === 1 ? '' : 's'}`
    if (parsed && typeof parsed === 'object') {
      const obj = parsed as Record<string, unknown>
      if (Array.isArray(obj.columns)) {
        const columns = obj.columns
          .map((column) => column && typeof column === 'object' ? column as Record<string, unknown> : null)
          .filter((column): column is Record<string, unknown> => Boolean(column))
        const itemCount = columns.reduce((sum, column) => {
          const inline = Array.isArray(column.items) ? column.items.length : 0
          const cards = Array.isArray(column.cards) ? column.cards.length : 0
          return sum + inline + cards
        }, Array.isArray(obj.items) ? obj.items.length : 0)
        const names = columns
          .map((column) => String(column.title ?? column.name ?? column.id ?? 'Column'))
          .slice(0, 4)
          .join(', ')
        return `Kanban · ${columns.length} column${columns.length === 1 ? '' : 's'} · ${itemCount} item${itemCount === 1 ? '' : 's'}${names ? `\n${names}` : ''}`
      }
      const entries = Object.entries(obj).slice(0, 6).map(([key, value]) => `${key}: ${compactValue(value)}`)
      return `JSON object · ${Object.keys(obj).length} field${Object.keys(obj).length === 1 ? '' : 's'}\n${entries.join('\n')}`
    }
    return compactValue(parsed)
  } catch {
    return raw
  }
}

function compactValue(value: unknown): string {
  if (value == null) return 'null'
  if (typeof value === 'string') return truncatePreview(cleanPreviewText(value), 80)
  if (typeof value === 'number' || typeof value === 'boolean') return String(value)
  if (Array.isArray(value)) return `Array(${value.length})`
  if (typeof value === 'object') return `Object(${Object.keys(value as Record<string, unknown>).length})`
  return String(value)
}

function cleanPreviewText(value: string): string {
  return value
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/\r/g, '')
    .replace(/[ \t]+/g, ' ')
    .replace(/\n{3,}/g, '\n\n')
    .trim()
}

function stripHtml(value: string): string {
  return cleanPreviewText(value.replace(/<[^>]+>/g, ' '))
}

function truncatePreview(value: string, max: number): string {
  if (value.length <= max) return value
  return `${value.slice(0, Math.max(0, max - 1)).trimEnd()}...`
}

function stringifyPreview(value: unknown): string {
  if (value == null) return ''
  if (typeof value === 'string') return value
  try {
    return JSON.stringify(value, null, 2)
  } catch {
    return String(value)
  }
}
