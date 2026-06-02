/**
 * UI-6 · AI Recap Drawer
 *
 * Expanded version of the canvas recap surface that lives on top of the
 * `PlannerGraph`. The collapsed/headline form continues to live in
 * `CanvasToolbar` — clicking it opens this drawer.
 *
 * Layout:
 *   - Top: pinned monitor signals
 *       · Nodes that need a human reply    (live from recap-core monitor)
 *       · Blocked / failed nodes           (live from recap-core monitor)
 *       · New artifact versions <1h        (live from ENG-3 once wired)
 *   - Middle: aggregated activity, groupable by owner / node / time
 *   - Bottom: CTA → open Quick for session search
 *
 * The full session search path lives in Quick. This drawer intentionally does
 * NOT re-list sessions — it only surfaces attention signals (gate-blocked,
 * failed) and quick-jumps; clicking the bottom CTA opens the command palette.
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
import type { CanvasMonitor, CanvasNodeMonitorItem } from '@meee1/recap-core'
import { fetchRecentArtifactVersions, type ArtifactVersionSummary, type UserProfile } from '../../api'
import './planner.css'

interface Props {
  /**
   * UI-simplification §4.3: drawer is always-mounted, collapsed/expanded toggled
   * by clicking the header. `open` retained for back-compat with CanvasToolbar
   * but now treated as "expanded" — false collapses to a 44px header bar.
   */
  open: boolean
  onClose: () => void
  canvasId: string
  canvasName: string
  plannerState: PlannerGraphState | null
  monitor?: CanvasMonitor | null
  boardState: BoardState | null
  userProfile: UserProfile | null
  /**
   * Forwarded by PlannerGraph when the user clicks a quick-jump row. If absent
   * the drawer also patches the URL with `?node=<id>&version=<id>` and emits a
   * `meee2:ai-recap:jump` CustomEvent (UI-1 contract).
   */
  onJumpToNode?: (nodeId: string, versionId?: string) => void
  /**
   * Open Quick so the bottom CTA can hand off session search without
   * duplicating the session list here.
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
  monitor = null,
  boardState,
  userProfile,
  onJumpToNode,
  onOpenAllSessions,
}: Props) {
  const [groupBy, setGroupBy] = useState<GroupBy>('time')
  const [recentVersions, setRecentVersions] = useState<ArtifactVersionSummary[]>([])
  const [versionsError, setVersionsError] = useState<string | null>(null)
  const [versionsLoading, setVersionsLoading] = useState(false)

  const teamId = userProfile?.teams?.find((team) => team.isDefault)?.id ?? userProfile?.teams?.[0]?.id ?? null

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

  const needsReplyItems = useMemo(() => {
    return (monitor?.items ?? []).filter((item) => item.needsHumanReply).slice(0, 12)
  }, [monitor?.items])

  const attentionItems = useMemo(() => {
    return (monitor?.items ?? [])
      .filter((item) => !item.needsHumanReply && item.severity === 'attention')
      .slice(0, 12)
  }, [monitor?.items])

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

  const handleMonitorJump = (item: CanvasNodeMonitorItem) => {
    handleJump(item.nodeId)
  }

  // UI-simplification §4.3 revisit:retain modal-style opt-in mount.
  // Earlier change(218245b) made the drawer always-mounted but the real
  // canvas has other absolute-positioned banners(canvas-toolbar /
  // PreviewOverlay / RecapRefreshing toast)at the same top-left coord with
  // z-index 260+ — multiple floats overlap and the page becomes unreadable.
  // Keep open/close behavior; the canvas summary section is still surfaced
  // here(see below)— users see it the moment they open the drawer.
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

      {/* Canvas summary 段已移除 —— CanvasToolbar 的 preview recap 卡片(parseRecapJSON
       *  + headline/details/formatRecapAge,见 CanvasToolbar.tsx ~line 820)已经在被动
       *  展示同样信息(headline + details + 「刚刚」时间戳)。
       *  把 summary 也塞进 drawer 顶部等于两套 recap overlay 重叠。
       *  Spec §4.3 的「每 5min BYOA narrative」是数据源升级,不需要 UI 新位置 —— 等
       *  /api/v1/canvas/:id/recap-summary endpoint 落地后,直接喂给现有 toolbar banner 即可。
       *  drawer 里仍提供 Needs attention + Activity 的细节聚合(下方两段)。 */}

      {/* ── Top: pinned event highlights ─────────────────────────────── */}
      <section className="ai-recap-drawer__section ai-recap-drawer__highlights">
        <h3>
          <ShieldAlert size={12} aria-hidden /> Canvas monitor
        </h3>

        <SubSection
          icon={<ShieldAlert size={11} aria-hidden />}
          label="Needs reply"
          count={needsReplyItems.length}
        >
          {needsReplyItems.length === 0 ? (
            <EmptyRow note="当前没有需要你回复的节点" />
          ) : (
            needsReplyItems.map((item) => (
              <button
                key={item.id}
                type="button"
                className="ai-recap-drawer__row"
                onClick={() => handleMonitorJump(item)}
              >
                <span className="ai-recap-drawer__row-title">{item.nodeTitle}</span>
                <span className="ai-recap-drawer__row-meta">{monitorMeta(item)}</span>
                <span className="ai-recap-drawer__row-action">
                  {item.sessionId ? 'Open session' : 'Open node'}
                  <ArrowUpRight size={10} aria-hidden />
                </span>
              </button>
            ))
          )}
        </SubSection>

        <SubSection
          icon={<AlertTriangle size={11} aria-hidden />}
          label="Blocked / failed"
          count={attentionItems.length}
        >
          {attentionItems.length === 0 ? (
            <EmptyRow note="No blocked or failed nodes right now." />
          ) : (
            attentionItems.map((item) => (
              <button
                key={item.id}
                type="button"
                className="ai-recap-drawer__row"
                onClick={() => handleMonitorJump(item)}
              >
                <span className="ai-recap-drawer__row-title">{item.nodeTitle}</span>
                <span className="ai-recap-drawer__row-meta">{monitorMeta(item)}</span>
                <span className="ai-recap-drawer__row-action">
                  {item.sessionId ? 'Open session' : 'Open node'}
                  <ArrowUpRight size={10} aria-hidden />
                </span>
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

      {/* ── Bottom: hand off to Quick session search ─────────────────── */}
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
            <span>Quick Open sessions</span>
            <ArrowUpRight size={12} aria-hidden />
          </button>
          <p className="ai-recap-drawer__cta-hint">
            Search sessions, canvases and nodes from Quick Open.
          </p>
        </section>
      )}
    </div>
  )
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

function monitorMeta(item: CanvasNodeMonitorItem): string {
  return item.replyPrompt
    || item.nextAction
    || item.blockers[0]
    || monitorReasonLabel(item.reasonKind)
}

function monitorReasonLabel(reason: CanvasNodeMonitorItem['reasonKind']): string {
  switch (reason) {
  case 'permission_required':
    return 'Permission required'
  case 'waiting_for_user':
    return 'Waiting for user response'
  case 'inbox_pending':
    return 'Pending message'
  case 'gate_wait':
    return 'Waiting for gate review'
  case 'awaiting_input':
    return 'Awaiting input'
  case 'blocked':
    return 'Blocked'
  case 'failed':
    return 'Failed'
  default:
    return 'Normal'
  }
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
