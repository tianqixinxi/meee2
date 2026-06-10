import { useMemo, useState } from 'react'
import type {
  ArtifactPayload,
  PlannerArtifact,
  PlannerArtifactContent,
  PlannerArtifactView,
} from '../../types'
import { resolvedArtifactPayload } from '../../lib/artifactPayload'
import {
  TabularArtifactPreview,
  parseArtifactJSON,
  parseTabular,
  type TabularData,
} from '../planner/TabularArtifactPreview'
import { TypedPayloadPreview } from './TypedPayloadPreview'

export interface ResolvedArtifactView {
  view: PlannerArtifactView
  table?: TabularData | null
  payload?: ArtifactPayload | null
  raw?: string | null
}

interface Props {
  artifact: PlannerArtifact
  content?: PlannerArtifactContent | null
  emptyLabel?: string
  compact?: boolean
}

export function ArtifactViewTabs({
  artifact,
  content,
  emptyLabel = 'No previewable artifact content',
  compact = false,
}: Props) {
  const views = useMemo(() => resolveArtifactViews(artifact, content), [artifact, content])
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const active = views.find((item) => item.view.id === selectedId) ?? views[0] ?? null

  if (!active) return <div className="artifacts-preview">{emptyLabel}</div>

  return (
    <div className="artifact-view-tabs" data-compact={compact}>
      {views.length > 1 && (
        <div className="artifact-view-tabs__list" role="tablist" aria-label="Artifact views">
          {views.map((item) => (
            <button
              key={item.view.id}
              type="button"
              role="tab"
              aria-selected={item.view.id === active.view.id}
              className={item.view.id === active.view.id ? 'is-active' : undefined}
              onClick={() => setSelectedId(item.view.id)}
            >
              {item.view.title}
            </button>
          ))}
        </div>
      )}
      <div className="artifact-view-tabs__body" role="tabpanel">
        <ArtifactViewBody item={active} emptyLabel={emptyLabel} />
      </div>
    </div>
  )
}

export function resolveArtifactViews(
  artifact: PlannerArtifact,
  content?: PlannerArtifactContent | null,
): ResolvedArtifactView[] {
  const payload = resolvedArtifactPayload(artifact, content ?? undefined)
  const rawData = artifactDataValue(artifact, content)
  const saved = uniqueViews(artifact.views ?? [])
  const baseViews = saved.length > 0 ? saved : deriveDefaultViews(payload, rawData, content)
  return baseViews.map((view) => {
    const projected = projectSource(rawData, view.sourcePath)
    const table = view.kind === 'table' || view.kind === 'list'
      ? filterTableColumns(parseTabular(projected), view.columns ?? undefined)
      : null
    return {
      view,
      table,
      payload,
      raw: rawText(projected, content, artifact),
    }
  })
}

function ArtifactViewBody({ item, emptyLabel }: { item: ResolvedArtifactView; emptyLabel: string }) {
  if ((item.view.kind === 'table' || item.view.kind === 'list') && item.table) {
    return <TabularArtifactPreview data={item.table} />
  }
  if (item.view.kind === 'kanban' && item.payload?.type === 'kanban') {
    return <TypedPayloadPreview payload={item.payload} />
  }
  if (item.view.kind === 'json' || item.view.kind === 'raw') {
    return item.raw ? <pre className="artifacts-preview">{item.raw}</pre> : <div className="artifacts-preview">{emptyLabel}</div>
  }
  if (item.payload) return <TypedPayloadPreview payload={item.payload} />
  return item.raw ? <pre className="artifacts-preview">{item.raw}</pre> : <div className="artifacts-preview">{emptyLabel}</div>
}

function uniqueViews(views: PlannerArtifactView[]): PlannerArtifactView[] {
  const seen = new Set<string>()
  const result: PlannerArtifactView[] = []
  for (const view of views) {
    const id = view.id?.trim()
    if (!id || seen.has(id)) continue
    seen.add(id)
    result.push({
      ...view,
      id,
      title: view.title?.trim() || id,
    })
  }
  return result
}

function deriveDefaultViews(
  payload: ArtifactPayload | null,
  rawData: unknown,
  content?: PlannerArtifactContent | null,
): PlannerArtifactView[] {
  if (payload?.type === 'kanban') return [view('kanban', 'Kanban', 'kanban')]
  const table = parseTabular(rawData)
  if (table) {
    const hasMultipleColumns = table.columns.length > 1
    const views = hasMultipleColumns
      ? [view('table', 'Table', 'table'), view('list', 'List', 'list')]
      : [view('list', 'List', 'list')]
    return [...views, view('raw', 'Raw', 'raw')]
  }
  if (payload?.type === 'json' || content?.type === 'json') return [view('json', 'JSON', 'json')]
  if (payload) return [view(payload.type, labelForPayload(payload.type), 'raw')]
  return [view('raw', 'Raw', 'raw')]
}

function view(id: string, title: string, kind: PlannerArtifactView['kind']): PlannerArtifactView {
  return { id, title, kind }
}

function labelForPayload(type: ArtifactPayload['type']): string {
  switch (type) {
    case 'impl-pr': return 'Pull Request'
    case 'check-result': return 'Checks'
    default: return type.charAt(0).toUpperCase() + type.slice(1)
  }
}

function artifactDataValue(artifact: PlannerArtifact, content?: PlannerArtifactContent | null): unknown {
  const contentValue = parseArtifactJSON(content?.content)
  if (contentValue != null) return contentValue
  if (content?.payload != null) return extractPayloadData(content.payload)
  return extractPayloadData(artifact.payload)
}

function extractPayloadData(raw: unknown): unknown {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return raw
  const obj = raw as Record<string, unknown>
  if (typeof obj.json === 'string') {
    const parsed = parseArtifactJSON(obj.json)
    if (parsed != null) return parsed
  }
  return obj.data ?? obj.value ?? obj.items ?? raw
}

function projectSource(value: unknown, sourcePath?: string | null): unknown {
  const path = sourcePath?.trim()
  if (!path) return value
  return path.split('.').filter(Boolean).reduce((current, key) => {
    if (current && typeof current === 'object' && !Array.isArray(current)) {
      return (current as Record<string, unknown>)[key]
    }
    return undefined
  }, value)
}

function filterTableColumns(table: TabularData | null, columns?: string[] | null): TabularData | null {
  const wanted = columns?.map((item) => item.trim()).filter(Boolean)
  if (!table || !wanted?.length) return table
  const indexes = wanted
    .map((column) => table.columns.indexOf(column))
    .filter((idx) => idx >= 0)
  if (indexes.length === 0) return table
  return {
    ...table,
    columns: indexes.map((idx) => table.columns[idx]),
    rows: table.rows.map((row) => indexes.map((idx) => row[idx] ?? '')),
  }
}

function rawText(value: unknown, content?: PlannerArtifactContent | null, artifact?: PlannerArtifact): string | null {
  if (content?.content) return content.content
  if (typeof value === 'string') return value
  if (value == null) return null
  try {
    return JSON.stringify(value, null, 2)
  } catch {
    return String(artifact?.payload ?? value)
  }
}
