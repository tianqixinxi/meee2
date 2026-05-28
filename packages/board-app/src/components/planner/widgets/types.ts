/**
 * Shared widget types (chunk P2.2).
 *
 * Widgets are pure presentational components: they receive a `WidgetData`
 * payload via props and render it according to their `WidgetKind`. They never
 * fetch — the planner runtime is responsible for materializing `WidgetEntity`
 * rows from the upstream input (artifact / integration / sub-canvas-aggregate)
 * before handing them to the React layer.
 *
 * See `doc/goals/node-widget-model.md` chunk 2.2 for the broader rationale.
 */

import type { IntegrationViewSchema } from '../../../types'

/**
 * Status mirrors `IntegrationBadgeStatus` so widgets can render the same
 * five-bucket color/dot semantics regardless of where the row originates
 * (artifact slot, integration entity, sub-canvas digest, etc.).
 */
export type WidgetEntityStatus =
  | 'todo'
  | 'running'
  | 'awaiting'
  | 'blocked'
  | 'done'

/**
 * Canonical 5-state badge labels per ui-simplification.md §1
 * (`待办 / 运行中 / 等反馈 / 卡住 / 完成`). All status widgets (Inbox / Matrix /
 * Kanban / Badge) must read from this table — do NOT inline alternate
 * translations like `就绪` / `已就绪` / `运行` per surface.
 */
export const STATUS_LABEL: Record<WidgetEntityStatus, string> = {
  todo: '待办',
  running: '运行中',
  awaiting: '等反馈',
  blocked: '卡住',
  done: '完成',
} as const

/**
 * Canonical "数据源接通但暂无项" copy for widgets, per
 * ui-simplification.md §1 (terminology) and node-widget-concepts.md
 * §「数据没接通的提示」.
 *
 * This handles the SECOND case only — the data source is wired and the
 * widget produced zero rows. The "未接通" case (no integration bound,
 * upstream ref empty, subcanvas-aggregate unspecified) is signaled via
 * the resolver `hint` string and rendered as `data.error` upstream;
 * widgets just echo that string.
 *
 * All widgets reading from the same conceptual source should pick the
 * same constant so the user sees stable language across surfaces.
 */
export const EMPTY_STATE_COPY = {
  /** Artifact-style sources (ArtifactPreview, Badge often hangs on artifact). */
  artifactSource: '暂无成果',
  /** Collection-style sources (Inbox, Matrix — lists of progress items). */
  collectionSource: '暂无进展项',
  /** Generic badge fallback when no upstream artifact is in play. */
  badgeSource: '暂无内容',
} as const

export interface WidgetEntityDetail {
  label: string
  value: string
}

/**
 * Normalized row for any widget. Producers fill what they can; widgets
 * tolerate missing optional fields (subtitle / icon / schema / details).
 */
export interface WidgetEntity {
  id: string
  title: string
  subtitle?: string
  status: WidgetEntityStatus
  icon?: string
  /** Present when the entity originates from an integration view-schema. */
  schema?: IntegrationViewSchema
  /** Richer payload for hover preview / artifact-preview widget body. */
  details?: WidgetEntityDetail[]
}

export interface WidgetData {
  entities: WidgetEntity[]
  loading?: boolean
  error?: string | null
}

export interface BaseWidgetProps {
  data: WidgetData
  /** Node card-allocated frame; widget should fill it but stay fluid. */
  width: number
  height: number
  /** Click handler for an entity — usually opens preview / source URL. */
  onEntityClick?: (entity: WidgetEntity) => void
}
