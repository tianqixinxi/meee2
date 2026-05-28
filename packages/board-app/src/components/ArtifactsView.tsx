import {
  AlertCircle,
  Archive,
  CheckCircle2,
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
import { useI18n, type TranslationKey } from '../lib/i18n'
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
type RequirementFitFilter = 'all' | ArtifactRequirementSummary['fitStatus']

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
  refreshTick?: number
  focusTarget?: ArtifactFocusTarget | null
  onOpenCanvas: (canvasId: string) => void
  onOpenPlannerNode?: (canvasId: string, nodeId: string) => void
  onClearFocus?: () => void
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
  reference: string
  latest: PlannerArtifact | null
  artifacts: PlannerArtifact[]
  expectedKinds?: ArtifactExpectedKind[]
}

interface ArtifactRequirementSummary {
  fitStatus: 'complete' | 'partial' | 'missing'
  expectedOutputs: string[]
  requiredRefs: string[]
  producedKinds: string[]
  producedRefs: string[]
  matchedExpectedOutputs: string[]
  missingExpectedOutputs: string[]
  matchedRequiredRefs: string[]
  missingRequiredRefs: string[]
}

type ArtifactExpectedKind = 'schema-output' | 'gate-ref'

const KIND_FILTERS: ArtifactFilter[] = [
  'all',
  'prd',
  'kanban',
  'impl-pr',
  'check-result',
  'lark-doc',
  'generic',
]
const FIT_FILTERS: RequirementFitFilter[] = ['all', 'missing', 'partial', 'complete']

export function ArtifactsView({
  canvases,
  activeCanvasId,
  refreshTick = 0,
  focusTarget = null,
  onOpenCanvas,
  onOpenPlannerNode,
  onClearFocus,
}: ArtifactsViewProps) {
  const { t } = useI18n()
  const handledFocusRef = useRef(0)
  const [query, setQuery] = useState('')
  const [kindFilter, setKindFilter] = useState<ArtifactFilter>('all')
  const [fitFilter, setFitFilter] = useState<RequirementFitFilter>('all')
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
  }, [canvasSignature, refreshTick, t])

  const canvasGroups = useMemo(() => {
    const normalizedQuery = query.trim().toLowerCase()
    return canvasArtifacts.map((item) => {
      const nodesById = new Map(item.nodes.map((node) => [node.id, node]))
      const artifactsByNodeId = new Map<string, PlannerArtifact[]>()
      for (const artifact of item.artifacts) {
        const list = artifactsByNodeId.get(artifact.nodeId) ?? []
        list.push(artifact)
        artifactsByNodeId.set(artifact.nodeId, list)
      }
      const slots = new Map<string, ArtifactSlot>()
      for (const artifact of item.artifacts) {
        if (kindFilter !== 'all' && artifact.kind !== kindFilter) continue
        const node = nodesById.get(artifact.nodeId)
        const haystack = [
          artifact.title,
          artifact.reference,
          artifact.kind,
          artifact.status,
          ...artifactPayloadTextCandidates(artifact.payload),
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
            reference: artifact.reference,
            latest: artifact,
            artifacts: [artifact],
          })
        }
      }
      if (kindFilter === 'all') {
        for (const node of item.nodes) {
          const nodeArtifacts = artifactsByNodeId.get(node.id) ?? []
          const expectedSlots = [
            ...uniqueNonEmpty(node.schema?.outputs ?? []).map((reference) => ({ reference, expectedKind: 'schema-output' as const })),
            ...uniqueNonEmpty(node.gate?.requiredArtifactRefs ?? []).map((reference) => ({ reference, expectedKind: 'gate-ref' as const })),
          ]
          for (const expected of expectedSlots) {
            const satisfied = expected.expectedKind === 'gate-ref'
              ? nodeArtifacts.some((artifact) => artifactSatisfiesRequiredRef(artifact, expected.reference))
              : nodeArtifacts.some((artifact) => artifactSatisfiesExpectation(artifact, expected.reference))
            if (satisfied) continue
            const key = expectedSlotKey(item.canvas.id, node.id, expected.reference)
            const existing = slots.get(key)
            if (existing) {
              existing.expectedKinds = mergeExpectedKinds(existing.expectedKinds, expected.expectedKind)
              continue
            }
            const haystack = [
              expected.reference,
              expected.expectedKind,
              item.canvas.name,
              item.canvas.id,
              node.title,
              node.id,
            ].filter(Boolean).join(' ').toLowerCase()
            if (normalizedQuery && !haystack.includes(normalizedQuery)) continue
            slots.set(key, {
              key,
              canvas: item.canvas,
              node,
              reference: expected.reference,
              latest: null,
              artifacts: [],
              expectedKinds: [expected.expectedKind],
            })
          }
        }
      }
      return {
        ...item,
        slots: Array.from(slots.values())
          .sort(sortSlotsForDisplay)
          .filter((slot) => slotMatchesFitFilter(slot, artifactsByNodeId, fitFilter)),
      }
    }).filter((item) => item.slots.length > 0 || item.error)
  }, [canvasArtifacts, fitFilter, kindFilter, query])

  const totalSlots = canvasGroups.reduce((count, group) => count + group.slots.length, 0)
  const focusSummary = useMemo(() => {
    if (!focusTarget) return null
    const canvas = canvases.find((item) => item.id === focusTarget.canvasId) ?? null
    const node = canvasArtifacts
      .find((item) => item.canvas.id === focusTarget.canvasId)
      ?.nodes.find((item) => item.id === focusTarget.nodeId) ?? null
    const nodeLabel = focusTarget.nodeTitle?.trim() || node?.title || focusTarget.nodeId || focusTarget.reference || t('artifacts.focusFallback')
    const matchingSlots = canvasGroups
      .flatMap((group) => group.slots)
      .filter((slot) => slotMatchesFocus(slot, focusTarget))
    const canvasArtifactGroup = canvasArtifacts.find((item) => item.canvas.id === focusTarget.canvasId)
    const matchingArtifacts = node
      ? (canvasArtifactGroup?.artifacts ?? []).filter((artifact) => artifact.nodeId === node.id)
      : matchingSlots.flatMap((slot) => slot.artifacts)
    return {
      canvasId: focusTarget.canvasId,
      nodeId: focusTarget.nodeId?.trim() || null,
      canvas,
      node,
      nodeLabel,
      matchingSlots,
      requirement: buildRequirementSummary(node, matchingArtifacts),
    }
  }, [canvasArtifacts, canvasGroups, canvases, focusTarget, t])

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
    if (!slot.latest) return
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

  const showAllArtifacts = () => {
    setKindFilter('all')
    setFitFilter('all')
    setQuery('')
    onClearFocus?.()
  }

  useEffect(() => {
    if (!focusTarget || handledFocusRef.current === focusTarget.id) return
    handledFocusRef.current = focusTarget.id
    setKindFilter('all')
    setFitFilter('all')
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
    matchingSlots.slice(0, 3).forEach((slot) => {
      if (slot.latest) loadContent(slot.latest)
    })
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
            <div className="artifacts-filters" aria-label={t('artifacts.fitFilterLabel')}>
              {FIT_FILTERS.map((filter) => (
                <button
                  type="button"
                  key={filter}
                  className={`artifacts-filter${fitFilter === filter ? ' is-active' : ''}`}
                  onClick={() => setFitFilter(filter)}
                >
                  {filter === 'all' ? t('artifacts.fitFilterAll') : t(`artifacts.fit.${filter}` as TranslationKey)}
                </button>
              ))}
            </div>
          </div>
        </header>

        {error && <div className="artifacts-banner" role="status">{error}</div>}
        {focusSummary && (
          <div className="artifacts-focus" role="status">
            <div>
              <span className="artifacts-focus__eyebrow">{t('artifacts.focusLabel')}</span>
              <strong>{focusSummary.nodeLabel}</strong>
              <em>
                {loading
                  ? t('artifacts.focusLoading', { canvas: focusSummary.canvas?.name ?? shortId(focusSummary.canvasId) })
                  : t('artifacts.focusMeta', {
                    canvas: focusSummary.canvas?.name ?? shortId(focusSummary.canvasId),
                    count: String(focusSummary.matchingSlots.length),
                  })}
              </em>
              <ArtifactRequirementStrip summary={focusSummary.requirement} t={t} />
            </div>
            {focusSummary.nodeId && (
              <button
                type="button"
                onClick={() => onOpenPlannerNode?.(focusSummary.canvasId, focusSummary.nodeId ?? '')}
                disabled={!onOpenPlannerNode}
              >
                <ExternalLink size={13} aria-hidden />
                <span>{t('artifacts.openNode')}</span>
              </button>
            )}
            <button type="button" onClick={showAllArtifacts}>
              <Layers size={13} aria-hidden />
              <span>{t('artifacts.showAll')}</span>
            </button>
          </div>
        )}
        {loading && (
          <div className="artifacts-empty" role="status">
            <Loader2 size={15} className="spin" aria-hidden />
            <span>{t('artifacts.loading')}</span>
          </div>
        )}
        {!loading && canvasGroups.length === 0 && (
          <div className="artifacts-empty">
            <Archive size={15} aria-hidden />
            <span>{focusSummary ? t('artifacts.focusEmpty', { node: focusSummary.nodeLabel }) : t('artifacts.empty')}</span>
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
                  const content = slot.latest ? contentByArtifactId[slot.latest.id] : undefined
                  const versions = versionsBySlot[slot.key]
                  const selectedVersionId = selectedVersionBySlot[slot.key]
                  const selectedVersion = selectedVersionId ? versionDetailById[selectedVersionId] : undefined
                  const isExpanded = expandedSlots.has(slot.key)
                  const isFocused = focusTarget ? slotMatchesFocus(slot, focusTarget) : false
                  const nodeArtifacts = slot.node
                    ? group.artifacts.filter((artifact) => artifact.nodeId === slot.node?.id)
                    : slot.artifacts
                  const requirement = buildSlotRequirementSummary(slot, nodeArtifacts)
                  const hasArtifact = Boolean(slot.latest)
                  return (
                    <article
                      className={`artifacts-card${isFocused ? ' is-focused' : ''}${hasArtifact ? '' : ' is-missing-slot'}`}
                      id={artifactSlotDomId(slot.key)}
                      key={slot.key}
                    >
                      <div className="artifacts-card__top">
                        <div>
                          <div className="artifacts-card__eyebrow">
                            <span>{slot.latest?.kind ?? t('artifacts.expectedSlot')}</span>
                            <span>{slot.latest?.status ?? t('artifacts.fit.missing')}</span>
                          </div>
                          <h3>{slot.latest?.title ?? slot.reference}</h3>
                          <p>{slot.reference}</p>
                        </div>
                        <span className="artifacts-card__count">{slot.artifacts.length}</span>
                      </div>
                      <dl className="artifacts-meta">
                        <div>
                          <dt>{t('artifacts.node')}</dt>
                          <dd>{slot.node?.title ?? slot.latest?.nodeId ?? t('artifacts.focusFallback')}</dd>
                        </div>
                        <div>
                          <dt>{t('artifacts.latest')}</dt>
                          <dd>{slot.latest ? formatDate(slot.latest.createdAt) : t('artifacts.notProduced')}</dd>
                        </div>
                      </dl>
                      <ArtifactRequirementPanel summary={requirement} t={t} />
                      {slot.latest && (
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
                      )}
                      <div className="artifacts-card__footer">
                        {slot.latest && (
                          <button
                            type="button"
                            className="artifacts-link-button"
                            onClick={() => {
                              toggleSlot(slot.key)
                              if (slot.latest) loadContent(slot.latest)
                            }}
                          >
                            {isExpanded ? t('artifacts.hideDetails') : t('artifacts.viewDetails')}
                          </button>
                        )}
                        {slot.node && (
                          <button
                            type="button"
                            className="artifacts-link-button"
                            onClick={() => onOpenPlannerNode?.(slot.canvas.id, slot.node?.id ?? '')}
                            disabled={!onOpenPlannerNode}
                          >
                            <ExternalLink size={13} aria-hidden />
                            {t('artifacts.openNode')}
                          </button>
                        )}
                        {slot.latest && (
                          <button
                            type="button"
                            className="artifacts-link-button"
                            onClick={() => loadVersions(slot)}
                          >
                            {versionsLoading.has(slot.key) ? t('artifacts.loadingVersions') : t('artifacts.loadVersions')}
                          </button>
                        )}
                      </div>
                      {isExpanded && slot.latest && (
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

function ArtifactRequirementStrip({
  summary,
  t,
}: {
  summary: ArtifactRequirementSummary | null
  t: ReturnType<typeof useI18n>['t']
}) {
  if (!summary) return null
  return (
    <div
      className={`artifacts-requirement-strip artifacts-requirement-strip--${summary.fitStatus}`}
      aria-label={t('artifacts.requirements')}
    >
      <span className="artifacts-requirement-strip__fit">
        {summary.fitStatus === 'complete'
          ? <CheckCircle2 size={11} aria-hidden />
          : <AlertCircle size={11} aria-hidden />}
        {t(`artifacts.fit.${summary.fitStatus}` as TranslationKey)}
      </span>
      <span>
        {t('artifacts.producedCount', { count: String(summary.producedRefs.length) })}
      </span>
      {summary.expectedOutputs.length > 0 && (
        <span>{t('artifacts.expectedCount', { count: String(summary.expectedOutputs.length) })}</span>
      )}
      {summary.requiredRefs.length > 0 && (
        <span>{t('artifacts.requiredMatch', {
          matched: String(summary.matchedRequiredRefs.length),
          total: String(summary.requiredRefs.length),
        })}</span>
      )}
    </div>
  )
}

function ArtifactRequirementPanel({
  summary,
  t,
}: {
  summary: ArtifactRequirementSummary | null
  t: ReturnType<typeof useI18n>['t']
}) {
  if (!summary) return null
  return (
    <section
      className={`artifacts-requirements artifacts-requirements--${summary.fitStatus}`}
      aria-label={t('artifacts.requirements')}
    >
      <div className="artifacts-requirements__head">
        <span>{t('artifacts.requirements')}</span>
        <strong>{t(`artifacts.fit.${summary.fitStatus}` as TranslationKey)}</strong>
      </div>
      {(summary.missingExpectedOutputs.length > 0 || summary.missingRequiredRefs.length > 0) && (
        <RequirementChipRow
          label={t('artifacts.missing')}
          values={[...summary.missingExpectedOutputs, ...summary.missingRequiredRefs]}
          limit={4}
          tone="missing"
        />
      )}
      {summary.expectedOutputs.length > 0 && (
        <RequirementChipRow
          label={t('artifacts.expected')}
          values={summary.expectedOutputs.map((output) => requirementMatchLabel(
            output,
            summary.matchedExpectedOutputs,
          ))}
          limit={3}
        />
      )}
      {summary.producedKinds.length > 0 && (
        <RequirementChipRow
          label={t('artifacts.produced')}
          values={summary.producedKinds}
          limit={4}
        />
      )}
      {summary.requiredRefs.length > 0 && (
        <RequirementChipRow
          label={t('artifacts.gateRefs')}
          values={summary.requiredRefs.map((ref) => requirementMatchLabel(ref, summary.matchedRequiredRefs))}
          limit={3}
        />
      )}
    </section>
  )
}

function RequirementChipRow({
  label,
  values,
  limit,
  tone,
}: {
  label: string
  values: string[]
  limit: number
  tone?: 'missing'
}) {
  const visible = values.slice(0, limit)
  const hidden = values.length - visible.length
  return (
    <div className={`artifacts-requirements__row${tone ? ` artifacts-requirements__row--${tone}` : ''}`}>
      <span>{label}</span>
      <div>
        {visible.map((value) => (
          <em key={value}>{value}</em>
        ))}
        {hidden > 0 && <em>+{hidden}</em>}
      </div>
    </div>
  )
}

function buildRequirementSummary(
  node: PlanningNode | null | undefined,
  artifacts: PlannerArtifact[],
): ArtifactRequirementSummary | null {
  const expectedOutputs = uniqueNonEmpty(node?.schema?.outputs ?? [])
  const requiredRefs = uniqueNonEmpty(node?.gate?.requiredArtifactRefs ?? [])
  const producedKinds = uniqueNonEmpty(artifacts.map((artifact) => artifact.kind))
  const producedRefs = uniqueNonEmpty(artifacts.map((artifact) => artifact.reference))
  const matchedExpectedOutputs = expectedOutputs.filter((output) => (
    artifacts.some((artifact) => artifactSatisfiesExpectation(artifact, output))
  ))
  const missingExpectedOutputs = expectedOutputs.filter((output) => (
    !matchedExpectedOutputs.some((matched) => sameRequirement(matched, output))
  ))
  const matchedRequiredRefs = requiredRefs.filter((ref) => (
    artifacts.some((artifact) => artifactSatisfiesRequiredRef(artifact, ref))
  ))
  const missingRequiredRefs = requiredRefs.filter((ref) => (
    !matchedRequiredRefs.some((matched) => sameRequirement(matched, ref))
  ))
  if (
    expectedOutputs.length === 0
    && requiredRefs.length === 0
    && producedKinds.length === 0
    && producedRefs.length === 0
  ) {
    return null
  }
  const hasRequirements = expectedOutputs.length > 0 || requiredRefs.length > 0
  const missingCount = missingExpectedOutputs.length + missingRequiredRefs.length
  const matchedCount = matchedExpectedOutputs.length + matchedRequiredRefs.length
  return {
    fitStatus: hasRequirements
      ? missingCount === 0
        ? 'complete'
        : matchedCount > 0 || producedRefs.length > 0
          ? 'partial'
          : 'missing'
      : producedRefs.length > 0 || producedKinds.length > 0
        ? 'complete'
        : 'missing',
    expectedOutputs,
    requiredRefs,
    producedKinds,
    producedRefs,
    matchedExpectedOutputs,
    missingExpectedOutputs,
    matchedRequiredRefs,
    missingRequiredRefs,
  }
}

function buildSlotRequirementSummary(
  slot: ArtifactSlot,
  nodeArtifacts: PlannerArtifact[],
): ArtifactRequirementSummary | null {
  if (slot.latest || !slot.expectedKinds?.length) return buildRequirementSummary(slot.node, nodeArtifacts)
  const producedKinds = uniqueNonEmpty(nodeArtifacts.map((artifact) => artifact.kind))
  const producedRefs = uniqueNonEmpty(nodeArtifacts.map((artifact) => artifact.reference))
  const reference = slot.reference.trim()
  if (!reference) return buildRequirementSummary(slot.node, nodeArtifacts)
  const isSchemaOutput = slot.expectedKinds.includes('schema-output')
  const isGateRef = slot.expectedKinds.includes('gate-ref')
  return {
    fitStatus: 'missing',
    expectedOutputs: isSchemaOutput ? [reference] : [],
    requiredRefs: isGateRef ? [reference] : [],
    producedKinds,
    producedRefs,
    matchedExpectedOutputs: [],
    missingExpectedOutputs: isSchemaOutput ? [reference] : [],
    matchedRequiredRefs: [],
    missingRequiredRefs: isGateRef ? [reference] : [],
  }
}

function mergeExpectedKinds(
  current: ArtifactExpectedKind[] | undefined,
  nextKind: ArtifactExpectedKind,
): ArtifactExpectedKind[] {
  if (!current?.length) return [nextKind]
  return current.includes(nextKind) ? current : [...current, nextKind]
}

function uniqueNonEmpty(values: Array<string | null | undefined>): string[] {
  const seen = new Set<string>()
  const result: string[] = []
  for (const value of values) {
    const normalized = value?.trim()
    if (!normalized || seen.has(normalized.toLowerCase())) continue
    seen.add(normalized.toLowerCase())
    result.push(normalized)
  }
  return result
}

function artifactSatisfiesExpectation(artifact: PlannerArtifact, expectation: string): boolean {
  const expected = normalizeRequirementToken(expectation)
  if (!expected) return false
  return artifactRequirementCandidates(artifact).some((candidate) => {
    const normalized = normalizeRequirementToken(candidate)
    if (!normalized) return false
    return normalized === expected
      || normalized.includes(expected)
      || expected.includes(normalized)
  })
}

function artifactSatisfiesRequiredRef(artifact: PlannerArtifact, requiredRef: string): boolean {
  return sameRequirement(artifact.reference, requiredRef)
    || sameRequirement(artifact.title, requiredRef)
    || artifactSatisfiesExpectation(artifact, requiredRef)
}

function artifactRequirementCandidates(artifact: PlannerArtifact): string[] {
  return uniqueNonEmpty([
    artifact.kind,
    artifact.reference,
    artifact.title,
    artifact.status,
    ...artifactPayloadTextCandidates(artifact.payload),
  ])
}

function artifactPayloadTextCandidates(payload: unknown): string[] {
  if (typeof payload === 'string') return [payload]
  if (!payload || typeof payload !== 'object') return []
  const item = payload as Record<string, unknown>
  const direct = [
    item.summary,
    item.description,
    item.content,
    item.text,
    item.markdown,
    item.html,
    item.json,
  ].filter((value): value is string => typeof value === 'string')
  const nested = ['result', 'output', 'evidence', 'payload']
    .flatMap((key) => artifactPayloadTextCandidates(item[key]))
  return [...direct, ...nested]
}

function sameRequirement(left: string, right: string): boolean {
  return normalizeRequirementToken(left) === normalizeRequirementToken(right)
}

function normalizeRequirementToken(value: string | null | undefined): string {
  return (value ?? '')
    .trim()
    .toLowerCase()
    .replace(/[\s_-]+/g, '-')
}

function requirementMatchLabel(value: string, matchedValues: string[]): string {
  return matchedValues.some((matched) => sameRequirement(matched, value)) ? `ok ${value}` : value
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

function expectedSlotKey(canvasId: string, nodeId: string, reference: string): string {
  return `${canvasId}:${nodeId}:expected:${normalizeRequirementToken(reference)}`
}

function sortSlotsForDisplay(left: ArtifactSlot, right: ArtifactSlot): number {
  if (left.latest && right.latest) return sortArtifactsNewestFirst(left.latest, right.latest)
  if (left.latest) return -1
  if (right.latest) return 1
  return left.reference.localeCompare(right.reference)
}

function slotMatchesFitFilter(
  slot: ArtifactSlot,
  artifactsByNodeId: Map<string, PlannerArtifact[]>,
  fitFilter: RequirementFitFilter,
): boolean {
  if (fitFilter === 'all') return true
  const nodeArtifacts = slot.node ? artifactsByNodeId.get(slot.node.id) ?? [] : slot.artifacts
  const summary = buildSlotRequirementSummary(slot, nodeArtifacts)
  const fitStatus = summary?.fitStatus ?? (slot.latest ? 'complete' : 'missing')
  return fitStatus === fitFilter
}

function slotMatchesFocus(slot: ArtifactSlot, focus: ArtifactFocusTarget): boolean {
  if (slot.canvas.id !== focus.canvasId) return false
  const nodeId = focus.nodeId?.trim()
  const reference = focus.reference?.trim().toLowerCase()
  if (reference && slot.reference.trim().toLowerCase() === reference) return true
  if (reference) return false
  if (nodeId && (slot.latest?.nodeId === nodeId || slot.node?.id === nodeId)) return true
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

function shortId(value: string): string {
  return value.length > 8 ? value.slice(0, 8).toUpperCase() : value.toUpperCase()
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
