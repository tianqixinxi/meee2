/**
 * widgetDataResolver — node-widget data binding (2026-05-28 心智修正).
 *
 * Given a PlanningNode that declares a `widget`, compute the `WidgetData`
 * (a list of `WidgetEntity` items + loading/error state) that should be
 * rendered. Knows about three source kinds:
 *
 *   - `external`            walks `node.contextSources` for integration
 *                           entries; pulls matching IntegrationEntity items
 *                           by integrationId+entityRef. Falls back to chunk I
 *                           IntegrationViewSchema for per-entity rendering.
 *   - `upstream`            takes the most-recent artifact attached to the
 *                           node referenced by `dependsOnNodeIds[inputIndex]`
 *                           and projects its `typedPayload` items.
 *   - `subcanvas-aggregate` rolls up runtime state of one or more sibling
 *                           PlanningNode-sets identified by canvasId in
 *                           `widget.source.subcanvasIds`.
 *
 * Intentionally pure / synchronous. No fetches — caller passes the cached
 * canvas state + integration entity list. PlannerNodeCard (P2.4) wires this
 * in front of widget components.
 */

import type {
  PlannerArtifact,
  PlanningNode,
  PlanningNodeStatus,
  Widget,
} from '../../types'
import type { IntegrationEntity, IntegrationViewSchema } from '../../types'
import { getViewSchema } from '../../integrations/viewSchemas'
import type { WidgetData, WidgetEntity } from './widgets/types'

const STATUS_FROM_PLANNER: Record<PlanningNodeStatus, WidgetEntity['status']> = {
  draft: 'todo',
  ready: 'awaiting',
  working: 'running',
  blocked: 'blocked',
  done: 'done',
}

interface ResolverContext {
  node: PlanningNode
  widget: Widget
  /** Cached node set for the current canvas (used by upstream / subcanvas-aggregate). */
  allNodes: PlanningNode[]
  artifacts?: PlannerArtifact[]
  /** Optional in-page integration entity cache. */
  integrationEntities?: IntegrationEntity[]
}

export function resolveWidgetData(ctx: ResolverContext): WidgetData {
  const source = ctx.widget.source
  if (!source) {
    return emptyWithHint('还没指定要展示什么 — 到节点详情里挑一种数据来源')
  }
  switch (source.inputKind) {
    case 'external':
      return resolveFromIntegration(ctx)
    case 'upstream':
      return resolveFromUpstream(ctx)
    case 'subcanvas-aggregate':
      return resolveFromSubcanvasAggregate(ctx)
    default:
      return emptyWithHint('数据来源类型异常，请联系管理员')
  }
}

/**
 * External / integration source — pull matching IntegrationEntity rows from
 * the in-page cache. For v0.1 the wiring is:
 *
 *   1. The node may have a `contextSources[]` entry tagged `kind: 'artifact'`
 *      whose `reference` is `integration:<id>:<entityKind>` (informal, until
 *      NodeContractV2 input wiring lands).
 *   2. Failing that, we just match all entities whose `schemaId` exists in
 *      our registry — useful for monitor-style "show all GitHub PRs" demos.
 */
function resolveFromIntegration(ctx: ResolverContext): WidgetData {
  const entities: WidgetEntity[] = []
  for (const e of ctx.integrationEntities ?? []) {
    const sep = e.schemaId.indexOf(':')
    if (sep < 0) continue
    const integrationId = e.schemaId.slice(0, sep)
    const entityKind = e.schemaId.slice(sep + 1)
    const schema = getViewSchema(integrationId, entityKind)
    if (!schema) continue
    entities.push(entityFromSchema(e, schema, ctx.widget))
  }
  if (entities.length === 0) {
    return emptyWithHint('还没接到外部数据 — 到节点详情里连一个外部服务')
  }
  return { entities }
}

function entityFromSchema(
  entity: IntegrationEntity,
  schema: IntegrationViewSchema,
  widget: Widget,
): WidgetEntity {
  // mapping override > schema badge defaults
  const mapping = widget.mapping
  const title = mapping?.titleField
    ? readField(entity.payload, mapping.titleField, schema.badge.title)
    : schema.badge.title
  const subtitle = mapping?.subtitleField
    ? readField(entity.payload, mapping.subtitleField)
    : schema.badge.secondary
  const status = mapping?.statusField
    ? coerceStatus(readField(entity.payload, mapping.statusField)) ?? schema.badge.status
    : schema.badge.status
  return {
    id: `${entity.schemaId}:${readField(entity.payload, 'id') ?? schema.badge.title}`,
    title: title ?? schema.badge.title,
    subtitle,
    status,
    icon: schema.badge.icon,
    schema,
    details: schema.preview.details.slice(0, 4),
  }
}

/**
 * Upstream source — find the artifact attached to the dependency node and
 * project its items. For v0.1 we accept a payload shape of either:
 *   - `typedPayload.kind === 'kanban' | 'inbox-list'` → take items[]
 *   - `typedPayload.kind === 'markdown' | 'file'`     → single-item preview
 */
function resolveFromUpstream(ctx: ResolverContext): WidgetData {
  const idx = ctx.widget.source?.inputIndex ?? 0
  const upstreamId = ctx.node.dependsOnNodeIds?.[idx]
  if (!upstreamId) {
    return emptyWithHint('这个节点还没声明上游节点')
  }
  const upstream = ctx.allNodes.find((n) => n.id === upstreamId)
  if (!upstream) {
    return emptyWithHint('找不到指定的上游节点')
  }
  const artifact = pickLatestArtifact(ctx.artifacts ?? [], upstream.id)
  if (!artifact) {
    return emptyWithHint(`上游节点「${upstream.title}」还没产生成果`)
  }
  return projectArtifactToEntities(artifact, upstream)
}

function pickLatestArtifact(
  artifacts: PlannerArtifact[],
  nodeId: string,
): PlannerArtifact | undefined {
  // PlannerArtifact has `nodeId` (producer) + `createdAt` (timestamp) — no
  // separate `producerNodeId` / `updatedAt`.
  const candidates = artifacts.filter((a) => a.nodeId === nodeId)
  if (candidates.length === 0) return undefined
  return candidates.reduce((a, b) =>
    (a.createdAt ?? '') >= (b.createdAt ?? '') ? a : b,
  )
}

function projectArtifactToEntities(
  artifact: PlannerArtifact,
  upstream: PlanningNode,
): WidgetData {
  const payload = artifact.typedPayload
  if (!payload) {
    return {
      entities: [
        {
          id: artifact.id,
          title: artifact.title || upstream.title,
          status: STATUS_FROM_PLANNER[upstream.status] ?? 'todo',
        },
      ],
    }
  }
  // Conservative: only branch on a couple known kinds. ArtifactPayload is a
  // discriminated union keyed by `type` (not `kind`).
  if (payload.type === 'kanban' && Array.isArray(payload.columns)) {
    const items: Array<{ title: string; columnName: string }> = []
    for (const col of payload.columns) {
      for (const itemTitle of col.items) {
        items.push({ title: itemTitle, columnName: col.name })
      }
    }
    return {
      entities: items.map((it, i) => ({
        id: `${artifact.id}:${i}`,
        title: it.title,
        subtitle: it.columnName,
        status: coerceStatus(it.columnName) ?? 'todo',
      })),
    }
  }
  return {
    entities: [
      {
        id: artifact.id,
        title: artifact.title || upstream.title,
        subtitle: payload.type,
        status: STATUS_FROM_PLANNER[upstream.status] ?? 'todo',
        details: [{ label: 'type', value: payload.type }],
      },
    ],
  }
}

/**
 * Subcanvas-aggregate — roll up *all node statuses* across the listed canvas
 * ids. Each subcanvas becomes one WidgetEntity (title = canvas-ish name,
 * status = worst-status of its nodes). For v0.1 we don't fetch the
 * subcanvases (the resolver is sync) — instead, we expect `allNodes` to
 * include nodes whose `canvasId` matches the requested ids.
 */
function resolveFromSubcanvasAggregate(ctx: ResolverContext): WidgetData {
  const ids = ctx.widget.source?.subcanvasIds ?? []
  if (ids.length === 0) {
    return emptyWithHint('还没指定要聚合哪些子画板')
  }
  const entities: WidgetEntity[] = []
  for (const canvasId of ids) {
    const subset = ctx.allNodes.filter((n) => n.canvasId === canvasId)
    if (subset.length === 0) continue
    const worst = worstStatus(subset.map((n) => n.status))
    const counts = countByStatus(subset)
    entities.push({
      id: `subcanvas:${canvasId}`,
      title: canvasId.slice(0, 8),
      subtitle: `${subset.length} 节点 · ${humanCounts(counts)}`,
      status: worst,
      details: Object.entries(counts).map(([k, v]) => ({ label: k, value: String(v) })),
    })
  }
  if (entities.length === 0) {
    return emptyWithHint('指定的子画板里还没有节点')
  }
  return { entities }
}

function worstStatus(statuses: PlanningNodeStatus[]): WidgetEntity['status'] {
  const order: PlanningNodeStatus[] = ['blocked', 'working', 'ready', 'draft', 'done']
  for (const s of order) {
    if (statuses.includes(s)) return STATUS_FROM_PLANNER[s]
  }
  return 'todo'
}

function countByStatus(nodes: PlanningNode[]): Record<string, number> {
  const out: Record<string, number> = {}
  for (const n of nodes) {
    const key = STATUS_FROM_PLANNER[n.status] ?? 'todo'
    out[key] = (out[key] ?? 0) + 1
  }
  return out
}

function humanCounts(counts: Record<string, number>): string {
  return Object.entries(counts)
    .map(([k, v]) => `${k} ${v}`)
    .join(' · ')
}

// ── helpers ────────────────────────────────────────────────────────────────

function emptyWithHint(hint: string): WidgetData {
  return { entities: [], error: hint }
}

/** Read a dotted field path from a JSON-like payload. */
function readField(payload: unknown, path: string, fallback?: string): string | undefined {
  const segments = path.split('.')
  let cur: unknown = payload
  for (const seg of segments) {
    if (cur && typeof cur === 'object' && seg in (cur as Record<string, unknown>)) {
      cur = (cur as Record<string, unknown>)[seg]
    } else {
      return fallback
    }
  }
  if (cur == null) return fallback
  return String(cur)
}

function coerceStatus(s: string | undefined): WidgetEntity['status'] | undefined {
  if (!s) return undefined
  const v = s.toLowerCase()
  if (v === 'todo' || v === 'running' || v === 'awaiting' || v === 'blocked' || v === 'done') {
    return v
  }
  return undefined
}
