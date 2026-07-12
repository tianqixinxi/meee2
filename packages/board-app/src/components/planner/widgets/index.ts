/**
 * Widget registry — maps `WidgetKind` to its React component.
 *
 * Consumers (PlannerNodeCard etc.) should call `getWidgetComponent(kind)`
 * rather than importing concrete components directly, so adding a new widget
 * only requires touching this file + the new component module.
 */

import type { ComponentType } from 'react'
import type { WidgetKind } from '../../../types'

import { KanbanWidget } from './KanbanWidget'
import { InboxWidget } from './InboxWidget'
import { MatrixWidget } from './MatrixWidget'
import { BadgeWidget } from './BadgeWidget'
import { ArtifactPreviewWidget } from './ArtifactPreviewWidget'
import type { BaseWidgetProps } from './types'

export * from './types'
export { KanbanWidget } from './KanbanWidget'
export { InboxWidget } from './InboxWidget'
export { MatrixWidget } from './MatrixWidget'
export { BadgeWidget } from './BadgeWidget'
export { ArtifactPreviewWidget } from './ArtifactPreviewWidget'

// Partial: legacy `html` widgets are intentionally not executable in the
// simplified Canvas renderer and resolve to the BadgeWidget fallback.
const REGISTRY: Partial<Record<WidgetKind, ComponentType<BaseWidgetProps>>> = {
  'kanban': KanbanWidget,
  'inbox': InboxWidget,
  'matrix': MatrixWidget,
  'badge': BadgeWidget,
  'artifact-preview': ArtifactPreviewWidget,
}

/**
 * Resolve a `WidgetKind` to its React component.
 * Falls back to `BadgeWidget` for unknown kinds so a stale node referencing
 * a since-removed widget shape still renders something instead of throwing.
 */
export function getWidgetComponent(
  kind: WidgetKind,
): ComponentType<BaseWidgetProps> {
  return REGISTRY[kind] ?? BadgeWidget
}
