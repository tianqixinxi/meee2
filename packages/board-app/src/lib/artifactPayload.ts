import type {
  ArtifactPayload,
  ArtifactReviewStatus,
  PlannerArtifact,
  PlannerArtifactContent,
} from '../types'

export function resolvedArtifactPayload(
  artifact: PlannerArtifact,
  content?: PlannerArtifactContent,
): ArtifactPayload | null {
  const fetchedPayload = normalizeArtifactPayload(content?.payload, artifact.reviewStatus, content?.type ?? artifact.kind)
    ?? normalizeArtifactPayload(parseJSONMaybe(content?.content), artifact.reviewStatus, content?.type ?? artifact.kind)
  const artifactPayload = normalizeArtifactPayload(artifact.payload, artifact.reviewStatus, artifact.kind)

  if (isJsonBlobMetadata(artifact.payload) && fetchedPayload?.type === 'json') {
    return normalizeArtifactPayload(artifact.typedPayload, artifact.reviewStatus)
      ?? fetchedPayload
      ?? artifactPayload
  }

  return normalizeArtifactPayload(artifact.typedPayload, artifact.reviewStatus)
    ?? artifactPayload
    ?? fetchedPayload
}

export function normalizeArtifactPayload(
  raw: unknown,
  reviewStatus?: ArtifactReviewStatus,
  typeHint?: string,
): ArtifactPayload | null {
  if (typeHint === 'json' && Array.isArray(raw)) {
    return withReview(normalizeJsonPayload(raw), reviewStatus)
  }
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null
  const obj = raw as Record<string, unknown>
  const type = semanticPayloadType(stringField(obj, 'type') ?? typeHint)
  if (!type) return null
  const status = reviewStatus ?? reviewStatusField(obj)

  switch (type) {
    case 'prd': {
      const tldr = stringField(obj, 'tldr')
        ?? stringField(obj, 'summary')
        ?? stringField(obj, 'preview')
        ?? stringField(obj, 'content')
        ?? ''
      const sections = arrayField(obj, 'sections')
        .map((section) => objectField(section))
        .filter((section): section is Record<string, unknown> => Boolean(section))
        .map((section) => ({
          heading: stringField(section, 'heading') ?? stringField(section, 'title') ?? 'Section',
          lines: numberField(section, 'lines') ?? 0,
        }))
      if (!tldr && sections.length === 0) return null
      return withReview({ type: 'prd', tldr, sections }, status)
    }
    case 'kanban': {
      const columns = normalizeKanbanColumns(obj)
      if (columns.length === 0) return null
      return withReview({ type: 'kanban', columns }, status)
    }
    case 'impl-pr': {
      return withReview({
        type: 'impl-pr',
        number: numberField(obj, 'number') ?? numberField(obj, 'prNumber') ?? 0,
        branch: stringField(obj, 'branch') ?? stringField(obj, 'headBranch') ?? '',
        baseBranch: stringField(obj, 'baseBranch') ?? stringField(obj, 'base') ?? '',
        filesChanged: numberField(obj, 'filesChanged') ?? numberField(obj, 'changedFiles') ?? 0,
        insertions: numberField(obj, 'insertions') ?? numberField(obj, 'additions') ?? 0,
        deletions: numberField(obj, 'deletions') ?? 0,
        ciStatus: ciStatusField(obj) ?? 'running',
        reviewers: stringArrayField(obj, 'reviewers'),
      }, status)
    }
    case 'check-result': {
      return withReview({
        type: 'check-result',
        pass: numberField(obj, 'pass') ?? numberField(obj, 'passed') ?? 0,
        fail: numberField(obj, 'fail') ?? numberField(obj, 'failed') ?? 0,
        skip: numberField(obj, 'skip') ?? numberField(obj, 'skipped') ?? 0,
        failing: stringArrayField(obj, 'failing').concat(stringArrayField(obj, 'failures')),
      }, status)
    }
    case 'file': {
      const filename = stringField(obj, 'filename') ?? stringField(obj, 'name') ?? 'file'
      return withReview({
        type: 'file',
        filename,
        mime: stringField(obj, 'mime') ?? stringField(obj, 'mimeType') ?? 'application/octet-stream',
        sizeBytes: numberField(obj, 'sizeBytes') ?? numberField(obj, 'size') ?? 0,
        lines: numberField(obj, 'lines'),
      }, status)
    }
    case 'json': {
      const value = obj.data ?? obj.value ?? obj.items ?? obj
      return withReview(normalizeJsonPayload(value), status)
    }
    case 'markdown': {
      const preview = stringField(obj, 'preview')
        ?? stringField(obj, 'markdown')
        ?? stringField(obj, 'content')
        ?? stringField(obj, 'text')
        ?? ''
      if (!preview) return null
      return withReview({ type: 'markdown', preview }, status)
    }
    case 'integration': {
      const connector = stringField(obj, 'connector') ?? stringField(obj, 'source') ?? 'external'
      const externalId = stringField(obj, 'externalId') ?? stringField(obj, 'id') ?? ''
      const fields = flatRecordField(obj, 'fields')
      return withReview({
        type: 'integration',
        connector,
        externalId,
        externalUrl: stringField(obj, 'externalUrl') ?? stringField(obj, 'url'),
        summary: stringField(obj, 'summary') ?? stringField(obj, 'preview'),
        ...(fields ? { fields } : {}),
      }, status)
    }
    default:
      return null
  }
}

function normalizeKanbanColumns(obj: Record<string, unknown>): Array<{ name: string; items: string[] }> {
  const columns = arrayField(obj, 'columns')
    .map((column) => objectField(column))
    .filter((column): column is Record<string, unknown> => Boolean(column))
  if (columns.length === 0) return []

  const legacyItemsByColumn = new Map<string, string[]>()
  for (const item of arrayField(obj, 'items')) {
    const itemObj = objectField(item)
    if (!itemObj) continue
    const columnId = stringField(itemObj, 'columnId') ?? stringField(itemObj, 'status') ?? ''
    const title = stringField(itemObj, 'title') ?? stringField(itemObj, 'name') ?? stringField(itemObj, 'text')
    if (!columnId || !title) continue
    legacyItemsByColumn.set(columnId, [...(legacyItemsByColumn.get(columnId) ?? []), title])
  }

  return columns.map((column) => {
    const id = stringField(column, 'id') ?? stringField(column, 'name') ?? stringField(column, 'title') ?? ''
    const inlineItems = [
      ...arrayField(column, 'items'),
      ...arrayField(column, 'cards'),
    ]
      .map(itemTitle)
      .filter(Boolean)
    return {
      name: stringField(column, 'name') ?? stringField(column, 'title') ?? (id || 'Column'),
      items: inlineItems.length > 0 ? inlineItems : legacyItemsByColumn.get(id) ?? [],
    }
  })
}

function semanticPayloadType(value: string | undefined): ArtifactPayload['type'] | undefined {
  if (
    value === 'prd'
    || value === 'kanban'
    || value === 'impl-pr'
    || value === 'check-result'
    || value === 'file'
    || value === 'json'
    || value === 'markdown'
    || value === 'integration'
  ) return value
  return undefined
}

function normalizeJsonPayload(value: unknown): Extract<ArtifactPayload, { type: 'json' }> {
  const rootKind = Array.isArray(value)
    ? 'array'
    : value && typeof value === 'object'
      ? 'object'
      : 'value'
  const entries = jsonEntries(value)
  return {
    type: 'json',
    rootKind,
    preview: jsonPreview(value, rootKind),
    entries,
  }
}

function jsonEntries(value: unknown): Array<{ key: string; value: string }> {
  if (Array.isArray(value)) {
    return value.slice(0, 8).map((item, index) => ({
      key: String(index),
      value: jsonCell(item),
    }))
  }
  if (value && typeof value === 'object') {
    return Object.entries(value as Record<string, unknown>).slice(0, 12).map(([key, item]) => ({
      key,
      value: jsonCell(item),
    }))
  }
  return [{ key: 'value', value: jsonCell(value) }]
}

function jsonPreview(value: unknown, rootKind: 'object' | 'array' | 'value'): string {
  if (Array.isArray(value)) return `JSON array · ${value.length} item${value.length === 1 ? '' : 's'}`
  if (value && typeof value === 'object') {
    const count = Object.keys(value as Record<string, unknown>).length
    return `JSON object · ${count} field${count === 1 ? '' : 's'}`
  }
  return `JSON ${rootKind} · ${jsonCell(value)}`
}

function jsonCell(value: unknown): string {
  if (value == null) return 'null'
  if (typeof value === 'string') return value.length > 80 ? `${value.slice(0, 80)}...` : value
  if (typeof value === 'number' || typeof value === 'boolean') return String(value)
  if (Array.isArray(value)) return `Array(${value.length})`
  if (typeof value === 'object') return `Object(${Object.keys(value as Record<string, unknown>).length})`
  return String(value)
}

function itemTitle(item: unknown): string {
  if (typeof item === 'string') return item
  const obj = objectField(item)
  return stringField(obj, 'title') ?? stringField(obj, 'name') ?? stringField(obj, 'text') ?? ''
}

function withReview(
  payload: ArtifactPayload,
  reviewStatus?: ArtifactReviewStatus,
): ArtifactPayload {
  return reviewStatus ? { ...payload, reviewStatus } : payload
}

function parseJSONMaybe(raw: string | null | undefined): unknown {
  if (!raw) return null
  try {
    return JSON.parse(raw)
  } catch {
    return null
  }
}

function isJsonBlobMetadata(raw: unknown): boolean {
  const obj = objectField(raw)
  if (!obj) return false
  if (semanticPayloadType(stringField(obj, 'type')) !== 'json') return false
  if (!stringField(obj, 'blobRef')) return false
  return obj.data === undefined && obj.value === undefined && obj.items === undefined && obj.json === undefined
}

function objectField(value: unknown): Record<string, unknown> | null {
  return value && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null
}

function stringField(obj: Record<string, unknown> | null | undefined, key: string): string | undefined {
  const value = obj?.[key]
  return typeof value === 'string' && value.trim() ? value : undefined
}

function numberField(obj: Record<string, unknown>, key: string): number | undefined {
  const value = obj[key]
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined
}

function arrayField(obj: Record<string, unknown>, key: string): unknown[] {
  const value = obj[key]
  return Array.isArray(value) ? value : []
}

/** 只保留 string/number 值的扁平对象(integration.fields — view detail 行的数据面)。 */
function flatRecordField(
  obj: Record<string, unknown>,
  key: string,
): Record<string, string | number> | undefined {
  const value = objectField(obj[key])
  if (!value) return undefined
  const out: Record<string, string | number> = {}
  for (const [k, v] of Object.entries(value)) {
    if (typeof v === 'string' || (typeof v === 'number' && Number.isFinite(v))) out[k] = v
  }
  return Object.keys(out).length > 0 ? out : undefined
}

function stringArrayField(obj: Record<string, unknown>, key: string): string[] {
  return arrayField(obj, key).filter((value): value is string => typeof value === 'string')
}

function reviewStatusField(obj: Record<string, unknown>): ArtifactReviewStatus | undefined {
  const value = obj.reviewStatus
  return value === 'pending' || value === 'approved' || value === 'rejected' ? value : undefined
}

function ciStatusField(obj: Record<string, unknown>): 'pass' | 'fail' | 'running' | undefined {
  const value = obj.ciStatus
  return value === 'pass' || value === 'fail' || value === 'running' ? value : undefined
}
