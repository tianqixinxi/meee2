import {
  Archive,
  ExternalLink,
  FileText,
  GitCompare,
  Layers,
  Loader2,
  Search,
} from 'lucide-react'
import { useEffect, useMemo, useRef, useState } from 'react'
import {
  fetchPlannerGraphState,
  getArtifactVersion,
  getPlannerArtifactContent,
  listArtifactVersions,
} from '../api'
import { useI18n } from '../lib/i18n'
import type {
  CanvasInfo,
  PlannerArtifact,
  PlannerArtifactContent,
  PlannerArtifactKind,
  PlannerArtifactVersion,
  PlanningNode,
} from '../types'

type ArtifactFilter = 'all' | PlannerArtifactKind
type SlotDisplayMode = 'latest' | 'merged' | 'compare'

export interface ArtifactFocusTarget {
  id: number
  canvasId: string
  nodeId?: string | null
  nodeTitle?: string | null
  reference?: string | null
}

interface ArtifactsViewProps {
  canvases: CanvasInfo[]
  activeCanvasId: string
  focusTarget?: ArtifactFocusTarget | null
  onOpenCanvas: (canvasId: string) => void
}

interface CanvasArtifacts {
  canvas: CanvasInfo
  nodes: PlanningNode[]
  artifacts: PlannerArtifact[]
  error?: string
}

interface ArtifactSlot {
  key: string
  canvas: CanvasInfo
  node?: PlanningNode
  latest: PlannerArtifact
  artifacts: PlannerArtifact[]
}

const KIND_FILTERS: ArtifactFilter[] = [
  'all',
  'prd',
  'kanban',
  'impl-pr',
  'check-result',
  'lark-doc',
  'generic',
]

export function ArtifactsView({
  canvases,
  activeCanvasId,
  focusTarget = null,
  onOpenCanvas,
}: ArtifactsViewProps) {
  const { t } = useI18n()
  const handledFocusRef = useRef(0)
  const [query, setQuery] = useState('')
  const [kindFilter, setKindFilter] = useState<ArtifactFilter>('all')
  const [canvasArtifacts, setCanvasArtifacts] = useState<CanvasArtifacts[]>([])
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [displayModes, setDisplayModes] = useState<Record<string, SlotDisplayMode>>({})
  const [expandedSlots, setExpandedSlots] = useState<Set<string>>(() => new Set())
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
        } satisfies CanvasArtifacts
      } catch (err) {
        return {
          canvas,
          nodes: [],
          artifacts: [],
          error: (err as Error).message || t('artifacts.loadFailed'),
        } satisfies CanvasArtifacts
      }
    }))
      .then((items) => {
        if (cancelled) return
        setCanvasArtifacts(items)
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

  const canvasGroups = useMemo(() => {
    const normalizedQuery = query.trim().toLowerCase()
    return canvasArtifacts.map((item) => {
      const nodesById = new Map(item.nodes.map((node) => [node.id, node]))
      const slots = new Map<string, ArtifactSlot>()
      for (const artifact of item.artifacts) {
        if (kindFilter !== 'all' && artifact.kind !== kindFilter) continue
        const node = nodesById.get(artifact.nodeId)
        const haystack = [
          artifact.title,
          artifact.reference,
          artifact.kind,
          artifact.status,
          item.canvas.name,
          item.canvas.id,
          node?.title,
          node?.id,
        ].filter(Boolean).join(' ').toLowerCase()
        if (normalizedQuery && !haystack.includes(normalizedQuery)) continue
        const key = slotKey(artifact)
        const current = slots.get(key)
        if (current) {
          current.artifacts.push(artifact)
          current.artifacts.sort(sortArtifactsNewestFirst)
          current.latest = current.artifacts[0]
        } else {
          slots.set(key, {
            key,
            canvas: item.canvas,
            node,
            latest: artifact,
            artifacts: [artifact],
          })
        }
      }
      return {
        ...item,
        slots: Array.from(slots.values()).sort((a, b) => sortArtifactsNewestFirst(a.latest, b.latest)),
      }
    }).filter((item) => item.slots.length > 0 || item.error)
  }, [canvasArtifacts, kindFilter, query])

  const totalSlots = canvasGroups.reduce((count, group) => count + group.slots.length, 0)

  const toggleSlot = (key: string) => {
    setExpandedSlots((current) => {
      const next = new Set(current)
      if (next.has(key)) next.delete(key)
      else next.add(key)
      return next
    })
  }

  const loadContent = (artifact: PlannerArtifact) => {
    if (contentByArtifactId[artifact.id] || contentLoading.has(artifact.id)) return
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
  }

  const loadVersions = (slot: ArtifactSlot) => {
    if (versionsBySlot[slot.key] || versionsLoading.has(slot.key)) return
    setVersionsLoading((current) => new Set(current).add(slot.key))
    listArtifactVersions(slot.canvas.id, slot.latest.nodeId, slot.latest.reference)
      .then(({ versions }) => {
        setVersionsBySlot((current) => ({ ...current, [slot.key]: versions }))
        const newest = versions[0]
        if (newest) {
          setSelectedVersionBySlot((current) => ({ ...current, [slot.key]: newest.version_id }))
          setVersionDetailById((current) => ({ ...current, [newest.version_id]: newest }))
        }
      })
      .catch(() => {
        setVersionsBySlot((current) => ({ ...current, [slot.key]: [] }))
      })
      .finally(() => {
        setVersionsLoading((current) => {
          const next = new Set(current)
          next.delete(slot.key)
          return next
        })
      })
  }

  const selectVersion = (slot: ArtifactSlot, versionId: string) => {
    setSelectedVersionBySlot((current) => ({ ...current, [slot.key]: versionId }))
    if (versionDetailById[versionId]) return
    getArtifactVersion(slot.canvas.id, versionId)
      .then((version) => setVersionDetailById((current) => ({ ...current, [version.version_id]: version })))
      .catch(() => undefined)
  }

  useEffect(() => {
    if (!focusTarget || handledFocusRef.current === focusTarget.id) return
    handledFocusRef.current = focusTarget.id
    setKindFilter('all')
    setQuery(focusTarget.reference?.trim() || focusTarget.nodeTitle?.trim() || focusTarget.nodeId?.trim() || '')
  }, [focusTarget])

  useEffect(() => {
    if (!focusTarget || loading || canvasGroups.length === 0) return
    const matchingSlots = canvasGroups
      .flatMap((group) => group.slots)
      .filter((slot) => slotMatchesFocus(slot, focusTarget))
    if (matchingSlots.length === 0) return
    setExpandedSlots((current) => {
      const next = new Set(current)
      matchingSlots.forEach((slot) => next.add(slot.key))
      return next
    })
    matchingSlots.slice(0, 3).forEach((slot) => loadContent(slot.latest))
    window.requestAnimationFrame(() => {
      document.getElementById(artifactSlotDomId(matchingSlots[0].key))?.scrollIntoView({
        block: 'center',
        behavior: 'smooth',
      })
    })
  }, [canvasGroups, focusTarget, loading])

  return (
    <section className="artifacts-workspace" aria-label={t('artifacts.title')}>
      <div className="artifacts-workspace__inner">
        <header className="artifacts-workspace__header">
          <div>
            <span>{t('artifacts.scope')}</span>
            <h1>{t('artifacts.title')}</h1>
            <p>{loading ? t('artifacts.loadingSlots') : t('artifacts.summary', { slots: totalSlots, canvases: canvasArtifacts.length })}</p>
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
            <div className="artifacts-filters" aria-label={t('artifacts.filterLabel')}>
              {KIND_FILTERS.map((filter) => (
                <button
                  type="button"
                  key={filter}
                  className={`artifacts-filter${kindFilter === filter ? ' is-active' : ''}`}
                  onClick={() => setKindFilter(filter)}
                >
                  {filter === 'all' ? t('artifacts.filterAll') : filter}
                </button>
              ))}
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
        {!loading && canvasGroups.length === 0 && (
          <div className="artifacts-empty">
            <Archive size={15} aria-hidden />
            <span>{t('artifacts.empty')}</span>
          </div>
        )}

        <div className="artifacts-groups">
          {canvasGroups.map((group) => (
            <section className="artifacts-group" key={group.canvas.id}>
              <div className="artifacts-group__heading">
                <div>
                  <h2>{group.canvas.name}</h2>
                  <p>{group.canvas.workspacePath}</p>
                </div>
                <button
                  type="button"
                  className="artifacts-open-button"
                  onClick={() => onOpenCanvas(group.canvas.id)}
                  aria-label={t('artifacts.openCanvas', { name: group.canvas.name })}
                >
                  <ExternalLink size={14} aria-hidden />
                  <span>{group.canvas.id === activeCanvasId ? t('artifacts.currentCanvas') : t('artifacts.openCanvasButton')}</span>
                </button>
              </div>
              {group.error && <div className="artifacts-banner">{group.error}</div>}
              <div className="artifacts-grid">
                {group.slots.map((slot) => {
                  const mode = displayModes[slot.key] ?? 'latest'
                  const content = contentByArtifactId[slot.latest.id]
                  const versions = versionsBySlot[slot.key]
                  const selectedVersionId = selectedVersionBySlot[slot.key]
                  const selectedVersion = selectedVersionId ? versionDetailById[selectedVersionId] : undefined
                  const isExpanded = expandedSlots.has(slot.key)
                  const isFocused = focusTarget ? slotMatchesFocus(slot, focusTarget) : false
                  return (
                    <article
                      className={`artifacts-card${isFocused ? ' is-focused' : ''}`}
                      id={artifactSlotDomId(slot.key)}
                      key={slot.key}
                    >
                      <div className="artifacts-card__top">
                        <div>
                          <div className="artifacts-card__eyebrow">
                            <span>{slot.latest.kind}</span>
                            <span>{slot.latest.status}</span>
                          </div>
                          <h3>{slot.latest.title}</h3>
                          <p>{slot.latest.reference}</p>
                        </div>
                        <span className="artifacts-card__count">{slot.artifacts.length}</span>
                      </div>
                      <dl className="artifacts-meta">
                        <div>
                          <dt>{t('artifacts.node')}</dt>
                          <dd>{slot.node?.title ?? slot.latest.nodeId}</dd>
                        </div>
                        <div>
                          <dt>{t('artifacts.latest')}</dt>
                          <dd>{formatDate(slot.latest.createdAt)}</dd>
                        </div>
                      </dl>
                      <div className="artifacts-card__actions" aria-label={t('artifacts.controls')}>
                        <button
                          type="button"
                          className={mode === 'latest' ? 'is-active' : ''}
                          onClick={() => setDisplayModes((current) => ({ ...current, [slot.key]: 'latest' }))}
                        >
                          <FileText size={13} aria-hidden />
                          <span>{t('artifacts.showLatest')}</span>
                        </button>
                        <button
                          type="button"
                          className={mode === 'merged' ? 'is-active' : ''}
                          onClick={() => {
                            setDisplayModes((current) => ({ ...current, [slot.key]: 'merged' }))
                            loadVersions(slot)
                          }}
                        >
                          <Layers size={13} aria-hidden />
                          <span>{t('artifacts.showMerged')}</span>
                        </button>
                        <button
                          type="button"
                          className={mode === 'compare' ? 'is-active' : ''}
                          onClick={() => {
                            setDisplayModes((current) => ({ ...current, [slot.key]: 'compare' }))
                            loadVersions(slot)
                          }}
                        >
                          <GitCompare size={13} aria-hidden />
                          <span>{t('artifacts.compareVersions')}</span>
                        </button>
                      </div>
                      <div className="artifacts-card__footer">
                        <button
                          type="button"
                          className="artifacts-link-button"
                          onClick={() => {
                            toggleSlot(slot.key)
                            loadContent(slot.latest)
                          }}
                        >
                          {isExpanded ? t('artifacts.hideDetails') : t('artifacts.viewDetails')}
                        </button>
                        <button
                          type="button"
                          className="artifacts-link-button"
                          onClick={() => loadVersions(slot)}
                        >
                          {versionsLoading.has(slot.key) ? t('artifacts.loadingVersions') : t('artifacts.loadVersions')}
                        </button>
                      </div>
                      {isExpanded && (
                        <div className="artifacts-details">
                          {contentLoading.has(slot.latest.id) ? (
                            <div className="artifacts-preview artifacts-preview--loading">
                              <Loader2 size={14} className="spin" aria-hidden />
                              <span>{t('artifacts.loadingLatest')}</span>
                            </div>
                          ) : (
                            <ArtifactContentPreview content={content} t={t} />
                          )}
                        </div>
                      )}
                      {versions && (
                        <div className="artifacts-versions">
                          <label>
                            <span>{t('artifacts.version')}</span>
                            <select
                              value={selectedVersionId ?? ''}
                              onChange={(event) => selectVersion(slot, event.target.value)}
                            >
                              {versions.map((version) => (
                                <option value={version.version_id} key={version.version_id}>
                                  {formatDate(version.created_at)} - {version.submitted_by_kind}
                                </option>
                              ))}
                            </select>
                          </label>
                          {mode === 'latest' && <VersionSummary version={selectedVersion} t={t} />}
                          {mode === 'merged' && <MergedVersionView versions={versions} />}
                          {mode === 'compare' && <CompareVersionView versions={versions} t={t} />}
                        </div>
                      )}
                    </article>
                  )
                })}
              </div>
            </section>
          ))}
        </div>
      </div>
    </section>
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

function MergedVersionView({ versions }: { versions: PlannerArtifactVersion[] }) {
  return (
    <div className="artifacts-version-stack">
      {versions.map((version) => (
        <div key={version.version_id}>
          <strong>{formatDate(version.created_at)}</strong>
          <span>{version.payload_ref}</span>
        </div>
      ))}
    </div>
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

function slotKey(artifact: PlannerArtifact): string {
  return `${artifact.canvasId}:${artifact.nodeId}:${artifact.reference.trim().toLowerCase()}`
}

function slotMatchesFocus(slot: ArtifactSlot, focus: ArtifactFocusTarget): boolean {
  if (slot.canvas.id !== focus.canvasId) return false
  const nodeId = focus.nodeId?.trim()
  const reference = focus.reference?.trim().toLowerCase()
  if (nodeId && slot.latest.nodeId === nodeId) return true
  if (reference && slot.latest.reference.trim().toLowerCase() === reference) return true
  return false
}

function artifactSlotDomId(key: string): string {
  return `artifact-slot-${key.replace(/[^a-zA-Z0-9_-]/g, '_')}`
}

function sortArtifactsNewestFirst(a: PlannerArtifact, b: PlannerArtifact): number {
  return new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime()
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
