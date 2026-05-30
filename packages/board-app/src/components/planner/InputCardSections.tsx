/**
 * UI-4 · Two-section Input card surface (Upstream / External).
 *
 * Replaces the legacy field-level Mapping/Inputs binding surface. Per ENG-1's
 * `NodeContractV2`, an executable node now consumes two concrete input
 * sources, in declared order:
 *
 *   1. Upstream   — output of one source canvas node (read-only badge here)
 *   2. External   — N attached connector refs (each backed by a sync session)
 *
 * The Dialogue (rolling chat window) section was removed in the
 * ui-simplification PR2 pass — dialogue retention is no longer surfaced on
 * the input card; it remains a node-contract concern handled elsewhere.
 *
 * The component intentionally derives sections from existing `PlanningNode`
 * fields when the `v2` contract envelope is not yet propagated to the
 * canvas-state DTO (it lives inside `read_node_contract` today). When the
 * graph DTO grows a `node.contract.v2` field, swap the `derive*` helpers for
 * the real values — the visual contract is unchanged.
 */

import {
  ArrowUpRight,
  Plug,
  Plus,
  RefreshCw,
} from 'lucide-react'
import type {
  ContextSource,
  NodeContractExternalInput,
  NodeContractUpstreamInput,
  PlanningNode,
} from '../../types'

export interface InputCardSectionsProps {
  node: PlanningNode
  /** Resolved title of the upstream source node (rendered in the badge). */
  upstreamLabel?: string | null
  /** Compact mode renders inside the canvas card body (no headers etc.). */
  variant?: 'card' | 'modal'
  /**
   * If true, the External attach CTA and Refresh-now buttons are interactive.
   * Defaults to true; tests / read-only previews can disable.
   */
  interactive?: boolean
  /**
   * Open the connector-pick popover for the parent node. Wired by container —
   * UI-4 emits a no-op API call (see PlannerGraph.handleAttachDataSource); the
   * binding side is INT-2's responsibility.
   */
  onAttachDataSource?: (nodeId: string) => void
  /**
   * Trigger a one-off sync run for an external row. No-op stub today; emits a
   * TODO log line. Real implementation will dispatch the bound sync session.
   */
  onRefreshExternal?: (nodeId: string, external: NodeContractExternalInput) => void
}

export function InputCardSections({
  node,
  upstreamLabel,
  variant = 'card',
  interactive = true,
  onAttachDataSource,
  onRefreshExternal,
}: InputCardSectionsProps) {
  const upstream = deriveUpstream(node)
  const external = deriveExternalInputs(node)

  return (
    <div
      className={[
        'planner-input-card',
        `planner-input-card--${variant}`,
      ].join(' ')}
      aria-label="Node inputs"
      onClick={(event) => event.stopPropagation()}
      onPointerDown={(event) => event.stopPropagation()}
    >
      {/* Upstream row */}
      <section className="planner-input-card__section planner-input-card__section--upstream">
        <div className="planner-input-card__section-head">
          <span className="planner-input-card__badge planner-input-card__badge--upstream">
            上游
          </span>
        </div>
        <div className="planner-input-card__upstream-row">
          {upstream.source_node ? (
            <span
              className="planner-input-card__upstream-pill"
              title={upstreamLabel || upstream.source_node}
            >
              <ArrowUpRight size={11} aria-hidden />
              <span>{upstreamLabel || upstream.source_node}</span>
            </span>
          ) : (
            <span className="planner-input-card__muted">画板入口</span>
          )}
          <em className="planner-input-card__upstream-mode">
            {upstream.mode === 'item_scoped' ? '按项隔离' : '全量传入'}
          </em>
        </div>
      </section>

      {/* External sources */}
      <section className="planner-input-card__section planner-input-card__section--external">
        <div className="planner-input-card__section-head">
          <span className="planner-input-card__badge planner-input-card__badge--external">
            外部源
          </span>
          {external.length > 0 && (
            <em className="planner-input-card__section-count">{external.length}</em>
          )}
        </div>
        {external.length > 0 ? (
          <ul className="planner-input-card__external-list">
            {external.map((row, index) => {
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

    </div>
  )
}

/* -------- derivation helpers -------- */

function deriveUpstream(node: PlanningNode): NodeContractUpstreamInput {
  const firstDependency = (node.dependsOnNodeIds ?? [])[0] ?? null
  return {
    mode: 'passthrough',
    source_node: firstDependency,
  }
}

function deriveExternalInputs(node: PlanningNode): NodeContractExternalInput[] {
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

function connectorFromSource(source: ContextSource): string {
  // Heuristic: pick scheme from reference when present (e.g. `github://repo`),
  // otherwise fall back to `kind`. INT-2 will replace this with the actual
  // connector slug stored on `NodeContractExternalInput.connector`.
  const ref = source.reference || ''
  const schemeMatch = ref.match(/^([a-z][a-z0-9+.-]*):/i)
  if (schemeMatch) return schemeMatch[1].toLowerCase()
  return source.kind
}

function shortRef(ref: string): string {
  const trimmed = (ref || '').trim()
  if (!trimmed) return '—'
  if (trimmed.length <= 36) return trimmed
  return `${trimmed.slice(0, 16)}…${trimmed.slice(-16)}`
}
