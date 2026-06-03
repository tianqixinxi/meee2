import {
  Archive,
  ExternalLink,
  FileText,
  GitCompare,
  Loader2,
  Search,
} from 'lucide-react'
import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  fetchPlannerGraphState,
  getArtifactVersion,
  getPlannerArtifactContent,
  listArtifactVersions,
} from '../api'
import { requestBoardTarget } from '../lib/boardTarget'
import {
  ARTIFACT_TYPE_GROUPS,
  artifactGroupCounts,
  buildArtifactIndex,
  filterArtifactIndex,
  type ArtifactIndexItem,
  type ArtifactTypeGroupId,
  type CanvasArtifactsSource,
} from '../lib/artifactIndex'
import { useI18n } from '../lib/i18n'
import type {
  ArtifactReviewStatus,
  CanvasInfo,
  PlannerArtifact,
  PlannerArtifactContent,
  PlannerArtifactVersion,
} from '../types'
import { TypedPayloadPreview } from './artifacts/TypedPayloadPreview'

type ReviewFilter = ArtifactReviewStatus | 'all'
type StatusFilter = string | 'all'
type CanvasFilter = string | 'all'

interface ArtifactsViewProps {
  canvases: CanvasInfo[]
  activeCanvasId: string
  onOpenCanvas: (canvasId: string) => void
}

export function ArtifactsView({
  canvases,
  activeCanvasId,
  onOpenCanvas,
}: ArtifactsViewProps) {
  const { t } = useI18n()
  const [query, setQuery] = useState('')
  const [activeGroup, setActiveGroup] = useState<ArtifactTypeGroupId | 'all'>('all')
  const [canvasFilter, setCanvasFilter] = useState<CanvasFilter>('all')
  const [reviewFilter, setReviewFilter] = useState<ReviewFilter>('all')
  const [statusFilter, setStatusFilter] = useState<StatusFilter>('all')
  const [sources, setSources] = useState<CanvasArtifactsSource[]>([])
  const [selectedKey, setSelectedKey] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [contentByArtifactId, setContentByArtifactId] = useState<Record<string, PlannerArtifactContent>>({})
  const [contentLoading, setContentLoading] = useState<Set<string>>(() => new Set())
  const [versionsBySlot, setVersionsBySlot] = useState<Record<string, PlannerArtifactVersion[]>>({})
  const [versionsLoading, setVersionsLoading] = useState<Set<string>>(() => new Set())
  const [selectedVersionBySlot, setSelectedVersionBySlot] = useState<Record<string, string>>({})
  const [versionDetailById, setVersionDetailById] = useState<Record<string, PlannerArtifactVersion>>({})

  const canvasSignature = useMemo(
    () => canvases.map((canvas) => `${canvas.id}:${canvas.name}`).join('|'),
    [canvases],
  )

  useEffect(() => {
    let cancelled = false
    setLoading(true)
    setError(null)
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
    }))
      .then((items) => {
        if (cancelled) return
        setSources(items)
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
  }, [canvasSignature, t])

  const allItems = useMemo(() => buildArtifactIndex(sources), [sources])
  const counts = useMemo(() => artifactGroupCounts(allItems), [allItems])
  const filteredItems = useMemo(
    () => filterArtifactIndex(allItems, {
      query,
      groupId: activeGroup,
      canvasId: canvasFilter,
      reviewStatus: reviewFilter,
      status: statusFilter,
    }),
    [activeGroup, allItems, canvasFilter, query, reviewFilter, statusFilter],
  )
  const selectedItem = useMemo(
    () => filteredItems.find((item) => item.key === selectedKey) ?? filteredItems[0] ?? null,
    [filteredItems, selectedKey],
  )
  const canvasOptions = useMemo(
    () => canvases.filter((canvas) => allItems.some((item) => item.canvas.id === canvas.id)),
    [allItems, canvases],
  )
  const statusOptions = useMemo(
    () => Array.from(new Set(allItems.map((item) => item.latest.status).filter(Boolean))).sort(),
    [allItems],
  )

  useEffect(() => {
    if (!selectedItem) {
      setSelectedKey(null)
    } else if (selectedItem.key !== selectedKey) {
      setSelectedKey(selectedItem.key)
    }
  }, [selectedItem, selectedKey])

  const loadContent = useCallback((artifact: PlannerArtifact) => {
    if (artifact.typedPayload || contentByArtifactId[artifact.id] || contentLoading.has(artifact.id)) return
    setContentLoading((current) => new Set(current).add(artifact.id))
    getPlannerArtifactContent(artifact.canvasId, artifact.id)
      .then((content) => {
        setContentByArtifactId((current) => ({ ...current, [artifact.id]: content }))
      })
      .catch((err) => {
        setContentByArtifactId((current) => ({
          ...current,
          [artifact.id]: {
            artifactId: artifact.id,
            type: 'text',
            mimeType: 'text/plain',
            content: (err as Error).message || 'Failed to load artifact content',
          },
        }))
      })
      .finally(() => {
        setContentLoading((current) => {
          const next = new Set(current)
          next.delete(artifact.id)
          return next
        })
      })
  }, [contentByArtifactId, contentLoading])

  const loadVersions = useCallback((item: ArtifactIndexItem) => {
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

  const openSourceArtifact = (item: ArtifactIndexItem) => {
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
  }

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
                label={t('artifacts.reviewFilter')}
                value={reviewFilter}
                onChange={(value) => setReviewFilter(value as ReviewFilter)}
                options={[
                  { value: 'all', label: t('artifacts.filterAll') },
                  { value: 'approved', label: 'approved' },
                  { value: 'pending', label: 'pending' },
                  { value: 'rejected', label: 'rejected' },
                ]}
              />
              <SelectFilter
                label={t('artifacts.statusFilter')}
                value={statusFilter}
                onChange={setStatusFilter}
                options={[
                  { value: 'all', label: t('artifacts.filterAll') },
                  ...statusOptions.map((status) => ({ value: status, label: status })),
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
                <strong>{allItems.length}</strong>
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
                          <ArtifactBadges item={item} />
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
              onLoadContent={(artifact) => loadContent(artifact)}
              onLoadVersions={(item) => loadVersions(item)}
              onSelectVersion={selectVersion}
              onOpenCanvas={onOpenCanvas}
              onOpenSource={openSourceArtifact}
              t={t}
            />
          </div>
        )}
      </div>
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

function ArtifactBadges({ item }: { item: ArtifactIndexItem }) {
  return (
    <div className="artifacts-badges">
      <span>{item.typeLabel}</span>
      <span className={`artifacts-review-badge is-${item.reviewStatus}`}>{item.reviewStatus}</span>
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
  onLoadContent,
  onLoadVersions,
  onSelectVersion,
  onOpenCanvas,
  onOpenSource,
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
  onLoadContent: (artifact: PlannerArtifact) => void
  onLoadVersions: (item: ArtifactIndexItem) => void
  onSelectVersion: (item: ArtifactIndexItem, versionId: string) => void
  onOpenCanvas: (canvasId: string) => void
  onOpenSource: (item: ArtifactIndexItem) => void
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

  return (
    <aside className="artifacts-detail" aria-label={t('artifacts.detailPanel')}>
      <header className="artifacts-detail__header">
        <div>
          <span>{item.typeLabel}</span>
          <h2>{item.latest.title}</h2>
          <p>{item.latest.reference}</p>
        </div>
        <ArtifactBadges item={item} />
      </header>

      <dl className="artifacts-detail__meta">
        <div>
          <dt>{t('artifacts.tableCanvas')}</dt>
          <dd>{item.canvas.name || item.canvas.id}</dd>
        </div>
        <div>
          <dt>{t('artifacts.node')}</dt>
          <dd>{item.node?.title ?? item.latest.nodeId}</dd>
        </div>
        <div>
          <dt>{t('artifacts.latest')}</dt>
          <dd>{formatDate(item.latest.createdAt)}</dd>
        </div>
        <div>
          <dt>{t('artifacts.versionCount')}</dt>
          <dd>{item.artifacts.length}</dd>
        </div>
      </dl>

      <section className="artifacts-detail__section">
        <h3>{t('artifacts.preview')}</h3>
        {contentLoading ? (
          <div className="artifacts-preview artifacts-preview--loading">
            <Loader2 size={14} className="spin" aria-hidden />
            <span>{t('artifacts.loadingLatest')}</span>
          </div>
        ) : item.latest.typedPayload ? (
          <TypedPayloadPreview payload={item.latest.typedPayload} />
        ) : (
          <ArtifactContentPreview content={content} t={t} />
        )}
      </section>

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

      <footer className="artifacts-detail__actions">
        <button
          type="button"
          className="artifacts-open-button"
          onClick={() => onOpenSource(item)}
        >
          <ExternalLink size={14} aria-hidden />
          <span>{t('artifacts.openInCanvas')}</span>
        </button>
        <button
          type="button"
          className="artifacts-link-button"
          onClick={() => onOpenCanvas(item.canvas.id)}
        >
          <FileText size={13} aria-hidden />
          <span>{item.canvas.id === activeCanvasId ? t('artifacts.currentCanvas') : t('artifacts.openCanvasButton')}</span>
        </button>
        {!item.latest.typedPayload && (
          <button
            type="button"
            className="artifacts-link-button"
            onClick={() => onLoadContent(item.latest)}
          >
            <GitCompare size={13} aria-hidden />
            <span>{t('artifacts.loadContent')}</span>
          </button>
        )}
      </footer>
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

function stringifyPreview(value: unknown): string {
  if (value == null) return ''
  if (typeof value === 'string') return value
  try {
    return JSON.stringify(value, null, 2)
  } catch {
    return String(value)
  }
}
