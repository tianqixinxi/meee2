/**
 * UI-6 · AI Recap Drawer
 *
 * Expanded version of the canvas recap surface that lives on top of the
 * `PlannerGraph`. The collapsed/headline form continues to live in
 * `CanvasToolbar` — clicking it opens this drawer.
 *
 * Layout:
 *   - Top: pinned event highlights
 *       · Gate-blocked nodes               (today: planner blocked + ENG-2 stub)
 *       · Failed sessions                  (ENG-2 stub) — attention signal only
 *       · New artifact versions <1h        (live from ENG-3 once wired)
 *   - Middle: aggregated activity, groupable by owner / node / time
 *   - Bottom: CTA → hand off to the global `SessionsView` rail mode
 *
 * The full session list lives in `SessionsView` (left-rail mode). This drawer
 * intentionally does NOT re-list sessions — it only surfaces attention signals
 * (gate-blocked, failed) and quick-jumps; clicking the bottom CTA routes the
 * user to the canonical session list.
 *
 * Quick-jump URL contract (proposed for UI-1 coordination):
 *   ?node=<nodeId>&version=<versionId>
 * The drawer dispatches a `meee2:ai-recap:jump` CustomEvent on `window` with
 * `{ nodeId, versionId? }` and also patches the URL search params. UI-1's
 * version dropdown should listen to the CustomEvent OR read the URL on mount
 * to auto-open the matching version.
 */

import { useEffect, useMemo, useState } from 'react'
import {
  AlertTriangle,
  ArrowUpRight,
  Clock3,
  GitBranch,
  History,
  Layers,
  ShieldAlert,
  Users,
  X,
} from 'lucide-react'
import type { BoardState, PlannerGraphState } from '../../types'
import { fetchRecentArtifactVersions, type ArtifactVersionSummary, type UserProfile } from '../../api'
import './planner.css'

interface Props {
  open: boolean
  onClose: () => void
  canvasId: string
  canvasName: string
  plannerState: PlannerGraphState | null
  boardState: BoardState | null
  userProfile: UserProfile | null
  /**
   * Forwarded by PlannerGraph when the user clicks a quick-jump row. If absent
   * the drawer also patches the URL with `?node=<id>&version=<id>` and emits a
   * `meee2:ai-recap:jump` CustomEvent (UI-1 contract).
   */
  onJumpToNode?: (nodeId: string, versionId?: string) => void
  /**
   * Switch the workspace rail to the global `SessionsView`. Provided by
   * `CanvasToolbar`, which receives it from `App.tsx`. When wired, the bottom
   * CTA hands the user off there instead of duplicating the session list here.
   */
  onOpenAllSessions?: () => void
}

type GroupBy = 'time' | 'owner' | 'node'

const RECENT_VERSION_WINDOW_MS = 60 * 60 * 1000 // 1 hour
const RECENT_VERSION_POLL_MS = 60 * 1000 // 1 min, used until realtime is wired

export function AIRecapDrawer({
  open,
  onClose,
  canvasId,
  canvasName,
  plannerState,
  boardState,
  userProfile,
  onJumpToNode,
  onOpenAllSessions,
}: Props) {
  const [groupBy, setGroupBy] = useState<GroupBy>('time')
  const [recentVersions, setRecentVersions] = useState<ArtifactVersionSummary[]>([])
  const [versionsError, setVersionsError] = useState<string | null>(null)
  const [versionsLoading, setVersionsLoading] = useState(false)

  const teamId = userProfile?.defaultSyncTeamId ?? userProfile?.teams?.[0]?.id ?? null

  // ── ENG-3 live data: recent artifact versions ──────────────────────────
  // Polls every minute; will be replaced by a Supabase realtime subscription
  // (see realtimeChannel TODO below).
  useEffect(() => {
    if (!open || !teamId || !canvasId) return
    let cancelled = false
    const load = () => {
      setVersionsLoading(true)
      setVersionsError(null)
      fetchRecentArtifactVersions({ teamId, canvasId, windowMs: RECENT_VERSION_WINDOW_MS })
        .then((items) => {
          if (cancelled) return
          setRecentVersions(items)
        })
        .catch((err) => {
          if (cancelled) return
          // The proxy endpoint may not be wired yet (BoardServer side). We
          // surface the message but render the rest of the drawer fine.
          setVersionsError((err as Error).message || 'Version stream unavailable')
        })
        .finally(() => {
          if (!cancelled) setVersionsLoading(false)
        })
    }
    load()
    const timer = window.setInterval(load, RECENT_VERSION_POLL_MS)
    return () => {
      cancelled = true
      window.clearInterval(timer)
    }
  }, [open, teamId, canvasId])

  // ── ENG-3 realtime subscription (TODO: wire when supabase-js lands here) ──
  // Bundle: `import { createClient } from '@supabase/supabase-js'` then
  //   client.channel(`artifact-versions:${teamId}:${canvasId}`)
  //     .on('postgres_changes', { event: 'INSERT',
  //                                schema: 'public',
  //                                table:  'meee2_artifact_versions',
  //                                filter: `team_id=eq.${teamId}` },
  //         (payload) => prepend(payload.new))
  //     .subscribe()
  // The polling fallback above keeps the surface live until then.

  // ── ENG-2 lifecycle data ──────────────────────────────────────────────
  // Now that ENG-2 (session lifecycle) has landed we can derive these from
  // the existing `PlannerGraphState` / `BoardState` accessors. The full
  // session-lifecycle event stream (auto-create, force_new_version) will
  // arrive through Supabase realtime in a follow-up; for now the polling
  // adapter that already drives the rest of the drawer keeps these fresh.
  //
  // Mapping:
  //  - eng2GateBlocked  ← planner nodes with a gate (approvers required)
  //                       AND a blocking workflow/status signal. Differs
  //                       from `localBlockedNodes` (which catches every
  //                       blocked-status node) by isolating gate-review
  //                       stuck-points specifically.
  //  - eng2FailedSessions ← BoardState.sessions whose last surfaced status
  //                         indicates an error (free-form status string;
  //                         we match the well-known set the resolver emits)
  //                         OR whose linked planner node has
  //                         workflowRunState === 'failed'.
  //  - eng2ActiveSessions ← BoardState.sessions in an in-flight status
  //                         (thinking/tooling/running/etc.).
  //
  // TODO(ENG-2 follow-up): switch to the realtime
  //   `meee2_session_runs` channel once supabase-js is bundled here — the
  //   polling-derived view below is a baseline that works without a new
  //   transport but won't catch < poll-interval transitions.
  const eng2GateBlocked: GateBlockedItem[] = useMemo(() => {
    if (!plannerState) return []
    return plannerState.nodes
      .filter((n) => {
        const hasGate = ((n.gate?.approvers ?? []).length > 0) || n.executionMode === 'human'
        const isBlocked =
          n.status === 'blocked' ||
          n.workflowRunState === 'gate-wait' ||
          n.workflowRunState === 'awaiting-input'
        return hasGate && isBlocked
      })
      .map((n) => ({
        nodeId: n.id,
        nodeTitle: n.title,
        reason:
          n.blockedReason
          ?? n.nextAction
          ?? (n.workflowRunState === 'gate-wait' ? 'Waiting for gate approval' : 'Awaiting input'),
      }))
  }, [plannerState])

  const eng2FailedSessions: FailedSessionItem[] = useMemo(() => {
    if (!boardState) return []
    const failedNodeSessionIds = new Set(
      (plannerState?.nodes ?? [])
        .filter((n) => n.workflowRunState === 'failed' && n.sessionId)
        .map((n) => n.sessionId as string),
    )
    const sessionToNodeId = new Map<string, string>()
    for (const n of plannerState?.nodes ?? []) {
      if (n.sessionId) sessionToNodeId.set(n.sessionId, n.id)
    }
    return boardState.sessions
      .filter((s) => {
        const status = (s.status as string).toLowerCase()
        return (
          failedNodeSessionIds.has(s.id) ||
          status === 'error' ||
          status === 'failed' ||
          status === 'aborted'
        )
      })
      .map((s) => ({
        sessionId: s.id,
        title: s.title,
        reason: s.pendingPermissionMessage || (s.status as string) || 'failed',
        nodeId: sessionToNodeId.get(s.id) ?? null,
      }))
      .slice(0, 12)
  }, [boardState, plannerState?.nodes])

  // Active/recently-completed sessions are intentionally NOT listed here.
  // They live in the global `SessionsView` rail mode; the bottom CTA hands
  // off to that surface. We still surface failed sessions above as an
  // attention signal (different intent: "this needs a human").

  // ── Local-derived data (works today, no backend changes needed) ───────
  const localBlockedNodes = useMemo(() => {
    if (!plannerState) return []
    return plannerState.nodes
      .filter((n) => n.status === 'blocked' || n.workflowRunState === 'failed' || n.blockedReason)
      .map((n) => ({
        nodeId: n.id,
        nodeTitle: n.title,
        reason: n.blockedReason ?? n.nextAction ?? n.workflowRunState ?? 'blocked',
        doerId: n.doerId,
      }))
  }, [plannerState])

  const aggregatedActivity = useMemo(() => {
    return buildAggregatedActivity(plannerState, recentVersions, boardState, groupBy)
  }, [plannerState, recentVersions, boardState, groupBy])

  const handleJump = (nodeId: string, versionId?: string) => {
    // URL contract (proposed for UI-1):
    //   ?node=<id>&version=<id>
    try {
      const url = new URL(window.location.href)
      url.searchParams.set('node', nodeId)
      if (versionId) url.searchParams.set('version', versionId)
      window.history.replaceState({}, '', url.toString())
    } catch {
      // SSR or sandbox; harmless to skip.
    }
    window.dispatchEvent(
      new CustomEvent('meee2:ai-recap:jump', {
        detail: { nodeId, versionId, canvasId },
      }),
    )
    onJumpToNode?.(nodeId, versionId)
    onClose()
  }

  if (!open) return null

  return (
    <div className="ai-recap-drawer" role="dialog" aria-label={`AI recap for ${canvasName}`}>
      <header className="ai-recap-drawer__header">
        <div className="ai-recap-drawer__title">
          <strong>AI Recap</strong>
          <span>{canvasName}</span>
        </div>
        <button
          type="button"
          className="ai-recap-drawer__close"
          aria-label="Close AI recap drawer"
          onClick={onClose}
        >
          <X size={14} aria-hidden />
        </button>
      </header>

      {/* ── Top: pinned event highlights ─────────────────────────────── */}
      <section className="ai-recap-drawer__section ai-recap-drawer__highlights">
        <h3>
          <ShieldAlert size={12} aria-hidden /> Needs attention
        </h3>

        <SubSection
          icon={<AlertTriangle size={11} aria-hidden />}
          label="Gate-blocked nodes"
          count={localBlockedNodes.length + eng2GateBlocked.length}
        >
          {localBlockedNodes.length === 0 && eng2GateBlocked.length === 0 ? (
            <EmptyRow note="No blocked nodes right now. Gate-event stream coming with ENG-2." />
          ) : (
            <>
              {localBlockedNodes.map((b) => (
                <button
                  key={b.nodeId}
                  type="button"
                  className="ai-recap-drawer__row"
                  onClick={() => handleJump(b.nodeId)}
                >
                  <span className="ai-recap-drawer__row-title">{b.nodeTitle}</span>
                  <span className="ai-recap-drawer__row-meta">{b.reason}</span>
                </button>
              ))}
              {eng2GateBlocked.map((b) => (
                <button
                  key={b.nodeId}
                  type="button"
                  className="ai-recap-drawer__row"
                  onClick={() => handleJump(b.nodeId)}
                >
                  <span className="ai-recap-drawer__row-title">{b.nodeTitle}</span>
                  <span className="ai-recap-drawer__row-meta">{b.reason}</span>
                </button>
              ))}
            </>
          )}
        </SubSection>

        <SubSection
          icon={<AlertTriangle size={11} aria-hidden />}
          label="Failed sessions"
          count={eng2FailedSessions.length}
        >
          {eng2FailedSessions.length === 0 ? (
            <EmptyRow note="Session events coming in next release. (ENG-2)" />
          ) : (
            eng2FailedSessions.map((f) => (
              <button
                key={f.sessionId}
                type="button"
                className="ai-recap-drawer__row"
                onClick={() => f.nodeId && handleJump(f.nodeId)}
              >
                <span className="ai-recap-drawer__row-title">{f.title}</span>
                <span className="ai-recap-drawer__row-meta">{f.reason}</span>
              </button>
            ))
          )}
        </SubSection>

        <SubSection
          icon={<GitBranch size={11} aria-hidden />}
          label="New versions (last 1h)"
          count={recentVersions.length}
        >
          {versionsError && (
            <div className="ai-recap-drawer__warn">{versionsError}</div>
          )}
          {versionsLoading && recentVersions.length === 0 && (
            <EmptyRow note="Loading recent versions..." />
          )}
          {!versionsLoading && recentVersions.length === 0 && !versionsError && (
            <EmptyRow note="No new versions in the last hour." />
          )}
          {recentVersions.map((v) => (
            <button
              key={v.versionId}
              type="button"
              className="ai-recap-drawer__row"
              onClick={() => handleJump(v.nodeId, v.versionId)}
            >
              <span className="ai-recap-drawer__row-title">
                {v.nodeTitle ?? v.nodeId} · {v.artifactSlotKey}
              </span>
              <span className="ai-recap-drawer__row-meta">
                {relativeTime(v.createdAt)} · by {v.submittedByLabel}
              </span>
            </button>
          ))}
        </SubSection>
      </section>

      {/* ── Middle: grouped activity ─────────────────────────────────── */}
      <section className="ai-recap-drawer__section ai-recap-drawer__activity">
        <header className="ai-recap-drawer__activity-head">
          <h3>
            <History size={12} aria-hidden /> Activity
          </h3>
          <div className="ai-recap-drawer__group-tabs" role="tablist" aria-label="Group activity by">
            {(['time', 'owner', 'node'] as const).map((g) => (
              <button
                key={g}
                type="button"
                role="tab"
                aria-selected={groupBy === g}
                className={groupBy === g ? 'is-active' : ''}
                onClick={() => setGroupBy(g)}
              >
                {g === 'time' ? <Clock3 size={11} /> : g === 'owner' ? <Users size={11} /> : <Layers size={11} />}
                <span>{g}</span>
              </button>
            ))}
          </div>
        </header>
        {aggregatedActivity.length === 0 ? (
          <EmptyRow note="No recent activity on this canvas." />
        ) : (
          aggregatedActivity.map((group) => (
            <div key={group.key} className="ai-recap-drawer__group">
              <div className="ai-recap-drawer__group-header">
                <span>{group.label}</span>
                <small>{group.items.length}</small>
              </div>
              {group.items.map((item) => (
                <button
                  key={item.id}
                  type="button"
                  className="ai-recap-drawer__row"
                  onClick={() => item.nodeId && handleJump(item.nodeId, item.versionId ?? undefined)}
                  disabled={!item.nodeId}
                >
                  <span className="ai-recap-drawer__row-title">{item.title}</span>
                  <span className="ai-recap-drawer__row-meta">{item.meta}</span>
                </button>
              ))}
            </div>
          ))
        )}
      </section>

      {/* ── Bottom: hand off to the global SessionsView ─────────────── */}
      {onOpenAllSessions && (
        <section className="ai-recap-drawer__section ai-recap-drawer__footer">
          <button
            type="button"
            className="ai-recap-drawer__cta"
            onClick={() => {
              onOpenAllSessions()
              onClose()
            }}
          >
            <span>View all sessions</span>
            <ArrowUpRight size={12} aria-hidden />
          </button>
          <p className="ai-recap-drawer__cta-hint">
            Live status, search and filtering live in the Sessions rail.
          </p>
        </section>
      )}
    </div>
  )
}

// ── Internal types ──────────────────────────────────────────────────────

interface GateBlockedItem {
  nodeId: string
  nodeTitle: string
  reason: string
}

interface FailedSessionItem {
  sessionId: string
  title: string
  reason: string
  nodeId?: string | null
}

interface ActivityGroup {
  key: string
  label: string
  items: Array<{
    id: string
    title: string
    meta: string
    nodeId?: string | null
    versionId?: string | null
  }>
}

// ── Helpers ─────────────────────────────────────────────────────────────

function SubSection(props: {
  icon: React.ReactNode
  label: string
  count: number
  children: React.ReactNode
}) {
  return (
    <div className="ai-recap-drawer__subsection">
      <div className="ai-recap-drawer__subsection-head">
        {props.icon}
        <strong>{props.label}</strong>
        <small>{props.count}</small>
      </div>
      <div className="ai-recap-drawer__subsection-body">{props.children}</div>
    </div>
  )
}

function EmptyRow({ note }: { note: string }) {
  return <div className="ai-recap-drawer__empty">{note}</div>
}

function buildAggregatedActivity(
  plannerState: PlannerGraphState | null,
  versions: ArtifactVersionSummary[],
  boardState: BoardState | null,
  groupBy: GroupBy,
): ActivityGroup[] {
  const items: Array<{
    id: string
    title: string
    meta: string
    nodeId?: string | null
    versionId?: string | null
    ownerKey: string
    nodeKey: string
    createdAt: number
  }> = []

  // Versions feed the activity stream as well — they double as audit trail.
  for (const v of versions) {
    items.push({
      id: `version-${v.versionId}`,
      title: `${v.nodeTitle ?? v.nodeId} · ${v.artifactSlotKey}`,
      meta: `${relativeTime(v.createdAt)} · v${v.shortId} · ${v.submittedByLabel}`,
      nodeId: v.nodeId,
      versionId: v.versionId,
      ownerKey: v.submittedByLabel,
      nodeKey: v.nodeId,
      createdAt: Date.parse(v.createdAt) || 0,
    })
  }

  // Recent planner events (already on PlannerCanvasState.events).
  for (const ev of plannerState?.events?.slice(-30) ?? []) {
    const nodeId = (ev as { nodeId?: string | null }).nodeId ?? null
    const node = nodeId ? plannerState?.nodes.find((n) => n.id === nodeId) : null
    items.push({
      id: `event-${ev.id ?? `${ev.createdAt}-${ev.type}`}`,
      title: ev.summary ?? ev.type,
      meta: `${relativeTime(ev.createdAt)} · ${ev.type}`,
      nodeId,
      ownerKey: node?.doerId ?? 'system',
      nodeKey: nodeId ?? '_canvas',
      createdAt: Date.parse(ev.createdAt) || 0,
    })
  }

  // Session heartbeats (last activity on each session in this canvas).
  for (const s of boardState?.sessions ?? []) {
    const ts = Date.parse(s.lastActivity ?? '') || 0
    items.push({
      id: `session-${s.id}`,
      title: s.title || s.id.slice(0, 8),
      meta: `${relativeTime(s.lastActivity)} · ${s.status as string}`,
      ownerKey: s.pluginDisplayName || s.pluginId || 'unknown',
      nodeKey: '_session',
      createdAt: ts,
    })
  }

  items.sort((a, b) => b.createdAt - a.createdAt)

  if (groupBy === 'time') {
    return bucketByTime(items)
  }
  const groups = new Map<string, ActivityGroup>()
  for (const it of items) {
    const key = groupBy === 'owner' ? it.ownerKey : it.nodeKey
    if (!groups.has(key)) {
      groups.set(key, { key, label: prettyGroupLabel(groupBy, key, plannerState), items: [] })
    }
    groups.get(key)!.items.push({
      id: it.id,
      title: it.title,
      meta: it.meta,
      nodeId: it.nodeId,
      versionId: it.versionId,
    })
  }
  return Array.from(groups.values()).slice(0, 12)
}

function bucketByTime(
  items: Array<{
    id: string
    title: string
    meta: string
    nodeId?: string | null
    versionId?: string | null
    createdAt: number
  }>,
): ActivityGroup[] {
  const now = Date.now()
  const buckets: Array<{ label: string; max: number; items: ActivityGroup['items'] }> = [
    { label: 'Last hour', max: 60 * 60 * 1000, items: [] },
    { label: 'Today', max: 24 * 60 * 60 * 1000, items: [] },
    { label: 'This week', max: 7 * 24 * 60 * 60 * 1000, items: [] },
    { label: 'Older', max: Number.POSITIVE_INFINITY, items: [] },
  ]
  for (const it of items) {
    const age = now - it.createdAt
    const bucket = buckets.find((b) => age <= b.max)!
    bucket.items.push({
      id: it.id,
      title: it.title,
      meta: it.meta,
      nodeId: it.nodeId,
      versionId: it.versionId,
    })
  }
  return buckets
    .filter((b) => b.items.length > 0)
    .map((b) => ({ key: b.label, label: b.label, items: b.items.slice(0, 25) }))
}

function prettyGroupLabel(
  groupBy: GroupBy,
  key: string,
  plannerState: PlannerGraphState | null,
): string {
  if (groupBy === 'node') {
    if (key === '_session') return 'Sessions'
    if (key === '_canvas') return 'Canvas-level'
    return plannerState?.nodes.find((n) => n.id === key)?.title ?? key
  }
  if (key === 'system') return 'System'
  if (key === 'unknown') return 'Unknown owner'
  return key
}

function relativeTime(iso: string | null | undefined): string {
  if (!iso) return ''
  const ms = Date.parse(iso)
  if (Number.isNaN(ms)) return ''
  const diff = Math.max(0, Date.now() - ms)
  const min = Math.floor(diff / 60000)
  if (min < 1) return 'just now'
  if (min < 60) return `${min}m ago`
  const h = Math.floor(min / 60)
  if (h < 24) return `${h}h ago`
  return `${Math.floor(h / 24)}d ago`
}
