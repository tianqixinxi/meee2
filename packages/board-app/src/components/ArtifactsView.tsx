import {
  Archive,
  ExternalLink,
  FileText,
  GitCompare,
  Layers,
  Loader2,
  Search,
} from 'lucide-react'
import { useEffect, useMemo, useState } from 'react'
import {
  fetchPlannerGraphState,
  getArtifactVersion,
  getPlannerArtifactContent,
  listArtifactVersions,
} from '../api'
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

interface ArtifactsViewProps {
  canvases: CanvasInfo[]
  activeCanvasId: string
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
  onOpenCanvas,
}: ArtifactsViewProps) {
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
          error: (err as Error).message || 'Failed to load artifacts',
        } satisfies CanvasArtifacts
      }
    }))
      .then((items) => {
        if (cancelled) return
        setCanvasArtifacts(items)
        const failures = items.filter((item) => item.error)
        setError(failures.length ? `${failures.length} canvas artifact group(s) failed to load.` : null)
      })
      .catch((err) => {
        if (!cancelled) setError((err as Error).message || 'Failed to load artifacts')
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [canvasSignature])

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

  return (
    <section className="artifacts-workspace" aria-label="Artifacts">
      <div className="artifacts-workspace__inner">
        <header className="artifacts-workspace__header">
          <div>
            <span>All canvases</span>
            <h1>Artifacts</h1>
            <p>{loading ? 'Loading artifact slots' : `${totalSlots} artifact slot${totalSlots === 1 ? '' : 's'} across ${canvasArtifacts.length} canvas${canvasArtifacts.length === 1 ? '' : 'es'}`}</p>
          </div>
          <div className="artifacts-workspace__tools">
            <label className="artifacts-search">
              <Search size={14} aria-hidden />
              <input
                value={query}
                onChange={(event) => setQuery(event.target.value)}
                placeholder="Search title, reference, kind, canvas, or node"
              />
            </label>
            <div className="artifacts-filters" aria-label="Artifact kind filter">
              {KIND_FILTERS.map((filter) => (
                <button
                  type="button"
                  key={filter}
                  className={`artifacts-filter${kindFilter === filter ? ' is-active' : ''}`}
                  onClick={() => setKindFilter(filter)}
                >
                  {filter === 'all' ? 'All' : filter}
                </button>
              ))}
            </div>
          </div>
        </header>

        {error && <div className="artifacts-banner" role="status">{error}</div>}
        {loading && (
          <div className="artifacts-empty" role="status">
            <Loader2 size={15} className="spin" aria-hidden />
            <span>Gathering artifacts from visible canvases</span>
          </div>
        )}
        {!loading && canvasGroups.length === 0 && (
          <div className="artifacts-empty">
            <Archive size={15} aria-hidden />
            <span>No artifacts match this view.</span>
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
                  aria-label={`Open ${group.canvas.name}`}
                >
                  <ExternalLink size={14} aria-hidden />
                  <span>{group.canvas.id === activeCanvasId ? 'Current canvas' : 'Open canvas'}</span>
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
                  return (
                    <article className="artifacts-card" key={slot.key}>
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
                          <dt>Node</dt>
                          <dd>{slot.node?.title ?? slot.latest.nodeId}</dd>
                        </div>
                        <div>
                          <dt>Latest</dt>
                          <dd>{formatDate(slot.latest.createdAt)}</dd>
                        </div>
                      </dl>
                      <div className="artifacts-card__actions" aria-label="Artifact display controls">
                        <button
                          type="button"
                          className={mode === 'latest' ? 'is-active' : ''}
                          onClick={() => setDisplayModes((current) => ({ ...current, [slot.key]: 'latest' }))}
                        >
                          <FileText size={13} aria-hidden />
                          <span>Show latest</span>
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
                          <span>Show merged view</span>
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
                          <span>Compare versions</span>
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
                          {isExpanded ? 'Hide details' : 'View details'}
                        </button>
                        <button
                          type="button"
                          className="artifacts-link-button"
                          onClick={() => loadVersions(slot)}
                        >
                          {versionsLoading.has(slot.key) ? 'Loading versions' : 'Load versions'}
                        </button>
                      </div>
                      {isExpanded && (
                        <div className="artifacts-details">
                          {contentLoading.has(slot.latest.id) ? (
                            <div className="artifacts-preview artifacts-preview--loading">
                              <Loader2 size={14} className="spin" aria-hidden />
                              <span>Loading latest artifact</span>
                            </div>
                          ) : (
                            <ArtifactContentPreview content={content} />
                          )}
                        </div>
                      )}
                      {versions && (
                        <div className="artifacts-versions">
                          <label>
                            <span>Version</span>
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
                          {mode === 'latest' && <VersionSummary version={selectedVersion} />}
                          {mode === 'merged' && <MergedVersionView versions={versions} />}
                          {mode === 'compare' && <CompareVersionView versions={versions} />}
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

function ArtifactContentPreview({ content }: { content?: PlannerArtifactContent }) {
  if (!content) {
    return (
      <div className="artifacts-preview">
        <span>Open details to load latest content.</span>
      </div>
    )
  }
  if (content.type === 'file') {
    return (
      <dl className="artifacts-file-meta">
        <div>
          <dt>Filename</dt>
          <dd>{content.filename ?? 'file artifact'}</dd>
        </div>
        <div>
          <dt>Mime type</dt>
          <dd>{content.mimeType || 'application/octet-stream'}</dd>
        </div>
        <div>
          <dt>Size</dt>
          <dd>{formatBytes(content.size)}</dd>
        </div>
        <div>
          <dt>SHA-256</dt>
          <dd>{content.sha256 ?? 'not recorded'}</dd>
        </div>
      </dl>
    )
  }
  const preview = content.content ?? stringifyPreview(content.payload)
  return (
    <pre className="artifacts-preview">
      {preview || 'No inline preview available.'}
    </pre>
  )
}

function VersionSummary({ version }: { version?: PlannerArtifactVersion }) {
  if (!version) return null
  return (
    <dl className="artifacts-version-summary">
      <div>
        <dt>Payload</dt>
        <dd>{version.payload_ref}</dd>
      </div>
      <div>
        <dt>Strategy</dt>
        <dd>{version.display_strategy}</dd>
      </div>
      <div>
        <dt>Submitted by</dt>
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

function CompareVersionView({ versions }: { versions: PlannerArtifactVersion[] }) {
  const [latest, previous] = versions
  if (!latest || !previous) {
    return <div className="artifacts-preview">Need at least two versions to compare.</div>
  }
  return (
    <div className="artifacts-compare">
      {[latest, previous].map((version, index) => (
        <div key={version.version_id}>
          <strong>{index === 0 ? 'Latest' : 'Previous'}</strong>
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

function formatBytes(value?: number | null): string {
  if (value == null) return 'not recorded'
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
