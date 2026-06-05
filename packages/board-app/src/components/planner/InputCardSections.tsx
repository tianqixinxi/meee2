/**
 * UI · step 节点输入面 —— 对齐 canvas runtime 数据模型(Edge/EdgeMode + DataSource +
 * sub-view),不再只从旧的 dependsOnNodeIds/contextSources 派生。
 *
 * 优先读真实一类边(canvasEdges)和画板数据源(canvasDataSources):
 *   1. 上游   —— 指向本节点的 Edge,显示「源节点 · sourceKey→inputKey · EdgeMode 时机」
 *   2. 外部源 —— Edge 的 sourceRef.dataSourceId 关联的 DataSource,显示 semantics/selector
 *   3. 子视图 —— node.schema.subViews,每个槽对数据的投影 + 语义(Part C)
 * 没拿到这些时回落旧派生(dependsOnNodeIds / contextSources),保证不破坏既有画面。
 */

import { ArrowUpRight, Layers, Plug, Plus, RefreshCw } from 'lucide-react'
import type {
  CanvasEdge,
  ContextSource,
  DataSourceRecord,
  NodeContractExternalInput,
  NodeContractUpstreamInput,
  PlanningNode,
} from '../../types'

export interface InputCardSectionsProps {
  node: PlanningNode
  upstreamLabel?: string | null
  variant?: 'card' | 'modal'
  interactive?: boolean
  onAttachDataSource?: (nodeId: string) => void
  onRefreshExternal?: (nodeId: string, external: NodeContractExternalInput) => void
  /** Canvas runtime 一类边 —— 读真实上游连接(命名槽 + EdgeMode);缺省回落 dependsOnNodeIds。 */
  canvasEdges?: CanvasEdge[]
  /** 画板数据源 —— 读 identity/selector/semantics;缺省回落 contextSources。 */
  canvasDataSources?: DataSourceRecord[]
  /** nodeId → 标题,给上游连接展示源节点名。 */
  nodeTitleById?: Record<string, string>
}

/** EdgeMode → 人类可读的「时机」标签(替代旧的硬编码「全量传入」)。 */
export function edgeModeLabel(mode?: CanvasEdge['edgeMode']): string {
  if (!mode) return ''
  switch (mode.mode) {
    case 'queue-claim':
      return mode.ordering ? `逐条认领 · ${mode.ordering}` : '逐条认领'
    case 'document-snapshot':
      return mode.strategy?.kind === 'pin-at-attempt-start' ? '开工时冻结' : '跟随最新'
    case 'dependency':
      return '依赖'
    default:
      return mode.mode
  }
}

interface UpstreamLink {
  sourceNodeId: string
  sourceKey?: string
  inputKey?: string
  /** 中介 artifact DataSource(Part C:数据流是 step → artifact → step)。 */
  artifactId?: string
  mode: CanvasEdge['edgeMode']
}

/** 上游连接:指向本节点的边。Part C 下数据流是 step → artifact → step —— 每条边带中介
 *  artifact 的 `sourceRef.dataSourceId`(不再排除它,而是把它当上游产物展示)。 */
export function deriveUpstreamLinks(node: PlanningNode, edges?: CanvasEdge[]): UpstreamLink[] {
  return (edges ?? [])
    .filter((e) => e.targetRef?.nodeId === node.id && e.sourceRef?.nodeId)
    .map((e) => ({
      sourceNodeId: e.sourceRef.nodeId,
      sourceKey: e.sourceRef.sourceKey,
      inputKey: e.targetRef.inputKey,
      artifactId: e.sourceRef.dataSourceId,
      mode: e.edgeMode,
    }))
}

interface DataSourceInputView {
  id: string
  label: string
  connectorKind?: string
  selectorHint?: string
  inputKey?: string
}

/** 真实外部数据源:本节点入边里带 dataSourceId 的,关联到画板 DataSource。 */
export function deriveDataSourceInputs(
  node: PlanningNode,
  edges?: CanvasEdge[],
  dataSources?: DataSourceRecord[],
): DataSourceInputView[] {
  const byId = new Map((dataSources ?? []).map((d) => [d.id, d]))
  const out: DataSourceInputView[] = []
  const seen = new Set<string>()
  for (const e of edges ?? []) {
    if (e.targetRef?.nodeId !== node.id) continue
    const dsId = e.sourceRef?.dataSourceId
    if (!dsId || seen.has(dsId)) continue
    const ds = byId.get(dsId)
    if (!ds) continue
    seen.add(dsId)
    out.push({
      id: ds.id,
      label: ds.semantics?.label ?? ds.title,
      connectorKind: ds.identity?.connectorKind ?? ds.kind,
      selectorHint: selectorHint(ds),
      inputKey: e.targetRef?.inputKey,
    })
  }
  return out
}

function selectorHint(ds: DataSourceRecord): string | undefined {
  const s = ds.selector
  if (!s) return undefined
  if (s.mode === 'curated') return s.intent ? `聚合 · ${s.intent}` : '聚合'
  return s.expr
}

export function InputCardSections({
  node,
  upstreamLabel,
  variant = 'card',
  interactive = true,
  onAttachDataSource,
  onRefreshExternal,
  canvasEdges,
  canvasDataSources,
  nodeTitleById,
}: InputCardSectionsProps) {
  const upstreamLinks = deriveUpstreamLinks(node, canvasEdges)
  const artifactLabelById = new Map(
    (canvasDataSources ?? []).map((d) => [d.id, d.semantics?.label ?? d.title] as const),
  )
  // 回落:没有一类边数据时,沿用旧派生(dependsOnNodeIds / contextSources)。
  const legacyUpstream = deriveUpstream(node)
  const legacyExternal = deriveExternalInputs(node)
  const subViews = node.schema?.subViews ?? {}
  const subViewKeys = Object.keys(subViews)

  return (
    <div
      className={['planner-input-card', `planner-input-card--${variant}`].join(' ')}
      aria-label="Node inputs"
      onClick={(event) => event.stopPropagation()}
      onPointerDown={(event) => event.stopPropagation()}
    >
      {/* Upstream */}
      <section className="planner-input-card__section planner-input-card__section--upstream">
        <div className="planner-input-card__section-head">
          <span className="planner-input-card__badge planner-input-card__badge--upstream">上游</span>
          {upstreamLinks.length > 1 && (
            <em className="planner-input-card__section-count">{upstreamLinks.length}</em>
          )}
        </div>
        {upstreamLinks.length > 0 ? (
          <ul className="planner-input-card__upstream-list">
            {upstreamLinks.map((link, i) => (
              <li
                key={`${link.sourceNodeId}:${link.inputKey ?? i}`}
                className="planner-input-card__upstream-row"
              >
                <span
                  className="planner-input-card__upstream-pill"
                  title={nodeTitleById?.[link.sourceNodeId] || link.sourceNodeId}
                >
                  <ArrowUpRight size={11} aria-hidden />
                  <span>{nodeTitleById?.[link.sourceNodeId] || link.sourceNodeId}</span>
                </span>
                {link.artifactId && (
                  <span
                    className="planner-input-card__artifact-pill"
                    title={`经产物 artifact:${artifactLabelById.get(link.artifactId) ?? link.artifactId}`}
                  >
                    {artifactLabelById.get(link.artifactId) ?? '产物'}
                  </span>
                )}
                {(link.sourceKey || link.inputKey) && (
                  <span
                    className="planner-input-card__slot-wire"
                    title={`${link.sourceKey ?? '?'} → ${link.inputKey ?? '?'}`}
                  >
                    {link.sourceKey ?? '·'} → {link.inputKey ?? '·'}
                  </span>
                )}
                <em className="planner-input-card__upstream-mode">{edgeModeLabel(link.mode)}</em>
              </li>
            ))}
          </ul>
        ) : (
          <div className="planner-input-card__upstream-row">
            {legacyUpstream.source_node ? (
              <span
                className="planner-input-card__upstream-pill"
                title={upstreamLabel || legacyUpstream.source_node}
              >
                <ArrowUpRight size={11} aria-hidden />
                <span>{upstreamLabel || legacyUpstream.source_node}</span>
              </span>
            ) : (
              <span className="planner-input-card__muted">画板入口</span>
            )}
          </div>
        )}
      </section>

      {/* External —— 纯外部源(contextSources,无 producer step 的 connector 引用)。
          上游 step 产出的 artifact 已在「上游」区块以中介 artifact 展示,不在此重复。 */}
      <section className="planner-input-card__section planner-input-card__section--external">
        <div className="planner-input-card__section-head">
          <span className="planner-input-card__badge planner-input-card__badge--external">外部源</span>
          {legacyExternal.length > 0 && (
            <em className="planner-input-card__section-count">{legacyExternal.length}</em>
          )}
        </div>
        {legacyExternal.length > 0 ? (
          <ul className="planner-input-card__external-list">
            {legacyExternal.map((row, index) => {
              const lastSync = row.sync_session
                ? `已同步 · 来自 ${shortRef(row.sync_session)}`
                : '尚未同步'
              return (
                <li
                  key={`${row.connector}:${row.ref}:${index}`}
                  className="planner-input-card__external-row"
                >
                  <Plug size={11} aria-hidden />
                  <span className="planner-input-card__external-ref" title={`${row.connector}:${row.ref}`}>
                    <strong>{row.connector}</strong>
                    <em>{shortRef(row.ref)}</em>
                  </span>
                  <button
                    type="button"
                    className="planner-input-card__refresh nodrag"
                    title="立即刷新这个外部源"
                    aria-label={`刷新 ${row.connector} ${row.ref}`}
                    disabled={!interactive}
                    onClick={(event) => {
                      event.stopPropagation()
                      onRefreshExternal?.(node.id, row)
                    }}
                  >
                    <RefreshCw size={10} aria-hidden />
                  </button>
                  <span className="planner-input-card__last-sync" title={lastSync}>
                    {lastSync}
                  </span>
                </li>
              )
            })}
          </ul>
        ) : null}
        <button
          type="button"
          className="planner-input-card__cta nodrag"
          disabled={!interactive}
          onClick={(event) => {
            event.stopPropagation()
            onAttachDataSource?.(node.id)
          }}
        >
          <Plus size={11} aria-hidden />
          接入数据源
        </button>
      </section>

      {/* Sub-views (Part C) —— 每个槽对数据的投影 + 语义 */}
      {subViewKeys.length > 0 && (
        <section className="planner-input-card__section planner-input-card__section--subview">
          <div className="planner-input-card__section-head">
            <span className="planner-input-card__badge planner-input-card__badge--subview">子视图</span>
            <em className="planner-input-card__section-count">{subViewKeys.length}</em>
          </div>
          <ul className="planner-input-card__subview-list">
            {subViewKeys.map((slot) => {
              const sv = subViews[slot]
              return (
                <li key={slot} className="planner-input-card__subview-row">
                  <Layers size={11} aria-hidden />
                  <span
                    className="planner-input-card__subview-ref"
                    title={sv.semantics?.purpose || slot}
                  >
                    <strong>{sv.semantics?.label || slot}</strong>
                    {sv.project && sv.project.length > 0 && <em>{sv.project.join(' · ')}</em>}
                  </span>
                </li>
              )
            })}
          </ul>
        </section>
      )}
    </div>
  )
}

/* -------- legacy derivation helpers (fallback + 既有测试) -------- */

export function deriveUpstream(node: PlanningNode): NodeContractUpstreamInput {
  const firstDependency = (node.dependsOnNodeIds ?? [])[0] ?? null
  return {
    mode: 'passthrough',
    source_node: firstDependency,
  }
}

export function deriveExternalInputs(node: PlanningNode): NodeContractExternalInput[] {
  const sources = node.contextSources ?? []
  return sources
    .filter((source) => isExternalSource(source))
    .map((source) => ({
      connector: connectorFromSource(source),
      ref: source.reference || source.title || 'unknown',
      sync_session: null,
    }))
}

function isExternalSource(source: ContextSource): boolean {
  if (source.kind === 'chatHistory') return false
  return true
}

export function connectorFromSource(source: ContextSource): string {
  // Heuristic: pick scheme from reference when present (e.g. `github://repo`),
  // otherwise fall back to `kind`.
  const ref = source.reference || ''
  const schemeMatch = ref.match(/^([a-z][a-z0-9+.-]*):/i)
  if (schemeMatch) return schemeMatch[1].toLowerCase()
  return source.kind
}

export function shortRef(ref: string): string {
  const trimmed = (ref || '').trim()
  if (!trimmed) return '—'
  if (trimmed.length <= 36) return trimmed
  return `${trimmed.slice(0, 16)}…${trimmed.slice(-16)}`
}
