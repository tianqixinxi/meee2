/**
 * SubcanvasStalenessBanner (§9.5) — surfaced inside a subcanvas when its pinned
 * upstream DataSource version has advanced past what this subcanvas was frozen
 * against (§7.5 source-version stale alerts).
 *
 * This is a pure presentational banner: the host passes whether the subcanvas
 * is stale + the relevant version labels. The host computes staleness from the
 * `dataSourceVersionAdvanced` event / the frozen `consumedSourceVersion`; that
 * backend signal isn't wired yet, so callers pass `stale={false}` until it is
 * (the banner self-hides). When `stale` is unknown the banner can render a
 * pending hint via `pending`.
 *
 * "Rebind / refresh" is governance — the action opens the planner chat dock to
 * draft a proposal (§9.5 [change] pattern), it does not mutate directly. The
 * host wires `onRebind`.
 */

import { AlertTriangle } from 'lucide-react'

export interface SubcanvasStalenessBannerProps {
  /** Upstream source advanced past the pinned version. */
  stale: boolean
  /** The version this subcanvas is pinned to (frozen at attempt start). */
  pinnedVersionLabel?: string
  /** The current upstream version. */
  currentVersionLabel?: string
  /** Optional source title for context. */
  sourceTitle?: string
  /**
   * True when staleness can't be determined yet (backend signal not wired).
   * Renders a muted hint instead of the alert. Default false.
   */
  pending?: boolean
  /** Opens the planner chat dock to draft a rebind/refresh proposal. */
  onRebind?: () => void
}

export function SubcanvasStalenessBanner({
  stale,
  pinnedVersionLabel,
  currentVersionLabel,
  sourceTitle,
  pending = false,
  onRebind,
}: SubcanvasStalenessBannerProps) {
  if (pending) {
    return (
      <div className="subcanvas-staleness-banner subcanvas-staleness-banner--pending">
        上游版本状态（待后端接入）
      </div>
    )
  }
  if (!stale) return null

  return (
    <div className="subcanvas-staleness-banner subcanvas-staleness-banner--stale" role="status">
      <AlertTriangle size={14} aria-hidden />
      <span className="subcanvas-staleness-banner__text">
        上游{sourceTitle ? `「${sourceTitle}」` : ''}已更新
        {pinnedVersionLabel && currentVersionLabel
          ? `（固定版本 ${pinnedVersionLabel} → 最新 ${currentVersionLabel}）`
          : ''}
        ,本子画板基于旧版本。
      </span>
      {onRebind && (
        <button type="button" className="subcanvas-staleness-banner__action" onClick={onRebind}>
          重新绑定
        </button>
      )}
    </div>
  )
}
