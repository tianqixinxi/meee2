import { useMemo } from 'react'
import { ChevronRight, CornerDownRight } from 'lucide-react'
import { useI18n } from '../../lib/i18n'
import type { CanvasInfo } from '../../types'

/**
 * UI-7 (team-canvas-sharing) — sub-canvas breadcrumb navigation.
 *
 * A node assigned to a teammate becomes a NEW SUBCANVAS owned by the assignee
 * (`meee2_assign_node`). On the assignee's board that sub-canvas is rooted under
 * a `parentCanvasId` / `parentNodeId` chain. This breadcrumb surfaces that chain
 * — "Parent canvas › … › this sub-canvas" — so the user can jump back up the
 * tree with a click, instead of hunting for the parent in the switcher.
 *
 * It is purely a *navigation* affordance over the canvas list the switcher
 * already loads; it owns no fetching and no state. When the active canvas has no
 * parent (a top-level / owned canvas) the component renders nothing, so callers
 * can mount it unconditionally next to the switcher.
 *
 * Single-owner invariant (I-1): a parent canvas is owned by someone else, so its
 * row may not be present in the local switcher list (we only hold our own
 * canvases + sub-canvases assigned to us). When an ancestor id is not resolvable
 * to a known canvas we render a non-clickable placeholder crumb rather than a
 * dead link — the user keeps the orientation even when the parent is not
 * locally navigable.
 */
export interface CanvasBreadcrumbProps {
  /** The full switcher canvas list (owned + assigned-to-me sub-canvases). */
  canvases: CanvasInfo[]
  /** The id of the canvas currently shown in the workspace. */
  activeCanvasId: string
  /** Navigate to `canvasId` (same handler the switcher uses). */
  onNavigate: (canvasId: string) => void
}

interface Crumb {
  /** Canvas id when the ancestor is locally known and navigable; null otherwise. */
  id: string | null
  label: string
  /** Whether this crumb is the active (leaf) canvas — rendered as plain text. */
  isCurrent: boolean
}

/**
 * Walk `parentCanvasId` from the active canvas up to the root, building an
 * ordered ancestor→leaf crumb list. Guards against cycles (malformed parent
 * pointers) with a visited set and a hard depth cap.
 */
function buildCrumbs(
  canvases: CanvasInfo[],
  activeCanvasId: string,
  unknownParentLabel: string,
): Crumb[] {
  const byId = new Map(canvases.map((canvas) => [canvas.id, canvas]))
  const active = byId.get(activeCanvasId)
  if (!active || !active.parentCanvasId) return []

  const chain: CanvasInfo[] = [active]
  const visited = new Set<string>([active.id])
  let cursor: string | null | undefined = active.parentCanvasId
  // Cap the walk: deeply nested sub-canvases are rare, and the cap also caps a
  // cycle that slipped past the visited set.
  while (cursor && chain.length < 16) {
    if (visited.has(cursor)) break
    visited.add(cursor)
    const parent = byId.get(cursor)
    if (!parent) {
      // Ancestor owned by someone else (I-1): not in our list. Emit a single
      // placeholder root crumb so the user still sees they are nested, then stop
      // — we cannot resolve further ancestors we do not hold.
      chain.unshift({
        id: cursor,
        name: unknownParentLabel,
        scope: active.scope,
        isDefault: false,
        workspacePath: '',
      } as CanvasInfo)
      cursor = null
      break
    }
    chain.unshift(parent)
    cursor = parent.parentCanvasId
  }

  return chain.map((canvas, index) => {
    const isCurrent = index === chain.length - 1
    const known = byId.has(canvas.id)
    return {
      id: !isCurrent && known ? canvas.id : null,
      label: canvas.name?.trim() || unknownParentLabel,
      isCurrent,
    }
  })
}

export function CanvasBreadcrumb({
  canvases,
  activeCanvasId,
  onNavigate,
}: CanvasBreadcrumbProps) {
  const { t } = useI18n()
  const crumbs = useMemo(
    () => buildCrumbs(canvases, activeCanvasId, t('canvas.breadcrumbParent')),
    [canvases, activeCanvasId, t],
  )

  if (crumbs.length === 0) return null

  return (
    <nav className="canvas-breadcrumb" aria-label={t('canvas.breadcrumbNav')}>
      <CornerDownRight size={13} aria-hidden className="canvas-breadcrumb__icon" />
      {crumbs.map((crumb, index) => (
        <span className="canvas-breadcrumb__segment" key={`${crumb.id ?? 'unknown'}:${index}`}>
          {index > 0 && (
            <ChevronRight size={12} aria-hidden className="canvas-breadcrumb__sep" />
          )}
          {crumb.id && !crumb.isCurrent ? (
            <button
              type="button"
              className="canvas-breadcrumb__crumb"
              onClick={() => onNavigate(crumb.id as string)}
              title={crumb.label}
            >
              {crumb.label}
            </button>
          ) : (
            <span
              className={[
                'canvas-breadcrumb__crumb',
                crumb.isCurrent ? 'is-current' : 'is-unresolved',
              ].join(' ')}
              aria-current={crumb.isCurrent ? 'page' : undefined}
              title={crumb.label}
            >
              {crumb.label}
            </span>
          )}
        </span>
      ))}
    </nav>
  )
}
