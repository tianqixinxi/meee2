// Notification system (release plan QC P1 / chunk D).
//
// Two layers in this file:
//
// 1) `WORKING_STATUSES` / `RESTING_STATUSES` — used by the per-session
//    unread state machine in App.tsx and WorkspaceRail. Unrelated to
//    OS-level notifications; kept here for historical reasons.
//
// 2) OS-level notifications (the rest of the file). Five trigger kinds:
//      - permission-request  session 需要人处理(permissionRequired / waitingForUser / inbox)
//      - session-blocked     session 进入 failed / dead / 长时间 stuck
//      - session-done        session 进入 completed/done 终态
//      - approval-needed     planner node workflowRunState=gate-wait 且有 approver
//      - recap-updated       session.latestRecap.timestamp 变化 (默认 off)
//
// User toggles persist to localStorage under `meee2.notifications.toggles.v1`.
// Permission gating: first request on first send-attempt; if denied,
// console.warn once and silently drop the rest.
// Dedup: same (sessionId, kind, transitionTag) within 30s collapses.

import type { PlanningNode, Session } from './types'

// ---- legacy unread state machine (kept for App.tsx / WorkspaceRail) ----

export const WORKING_STATUSES = new Set([
  'active', 'tooling', 'thinking', 'compacting',
])
export const RESTING_STATUSES = new Set([
  'idle', 'completed', 'waitingForUser',
])

// ---- OS notification kinds + toggles --------------------------------------

export type NotificationTriggerKind =
  | 'permission-request'
  | 'session-blocked'
  | 'session-done'
  | 'approval-needed'
  | 'recap-updated'

export const NOTIFICATION_TRIGGER_KINDS: NotificationTriggerKind[] = [
  'permission-request',
  'session-blocked',
  'session-done',
  'approval-needed',
  'recap-updated',
]

export type NotificationToggles = Record<NotificationTriggerKind, boolean>

export const DEFAULT_NOTIFICATION_TOGGLES: NotificationToggles = {
  'permission-request': true,
  'session-blocked': true,
  'session-done': true,
  'approval-needed': true,
  'recap-updated': false,
}

const TOGGLES_LS_KEY = 'meee2.notifications.toggles.v1'

export function loadNotificationToggles(): NotificationToggles {
  try {
    const raw = localStorage.getItem(TOGGLES_LS_KEY)
    if (!raw) return { ...DEFAULT_NOTIFICATION_TOGGLES }
    const parsed = JSON.parse(raw) as Partial<NotificationToggles>
    return { ...DEFAULT_NOTIFICATION_TOGGLES, ...parsed }
  } catch {
    return { ...DEFAULT_NOTIFICATION_TOGGLES }
  }
}

export function saveNotificationToggles(t: NotificationToggles): void {
  try {
    localStorage.setItem(TOGGLES_LS_KEY, JSON.stringify(t))
  } catch {
    /* ignore quota / private-mode failures */
  }
}

// ---- permission + dedup primitives ----------------------------------------

const DEDUP_WINDOW_MS = 30_000
const recentSends = new Map<string, number>()
let permissionWarned = false
let permissionRequested = false
let permissionCached: NotificationPermission | 'unsupported' = 'default'

function detectPermission(): NotificationPermission | 'unsupported' {
  if (typeof window === 'undefined' || typeof window.Notification === 'undefined') {
    return 'unsupported'
  }
  return Notification.permission
}

export function notificationsSupported(): boolean {
  return detectPermission() !== 'unsupported'
}

export async function ensureNotificationPermission(): Promise<NotificationPermission | 'unsupported'> {
  const cur = detectPermission()
  permissionCached = cur
  if (cur === 'unsupported' || cur === 'granted' || cur === 'denied') return cur
  if (permissionRequested) return cur
  permissionRequested = true
  try {
    const next = await Notification.requestPermission()
    permissionCached = next
    return next
  } catch {
    return cur
  }
}

function dedupKey(kind: NotificationTriggerKind, scopeId: string, transitionTag: string): string {
  return `${kind}::${scopeId}::${transitionTag}`
}

function shouldSkipDedup(key: string): boolean {
  const now = Date.now()
  const last = recentSends.get(key)
  if (last && now - last < DEDUP_WINDOW_MS) return true
  recentSends.set(key, now)
  // periodically prune
  if (recentSends.size > 256) {
    for (const [k, ts] of recentSends.entries()) {
      if (now - ts > DEDUP_WINDOW_MS * 4) recentSends.delete(k)
    }
  }
  return false
}

interface FireOpts {
  kind: NotificationTriggerKind
  toggles: NotificationToggles
  scopeId: string         // sessionId or nodeId — dedup scope
  transitionTag: string   // e.g. status string — distinguishes transitions
  title: string
  body?: string
}

let audioCtx: AudioContext | null = null

function playCue(kind: NotificationTriggerKind): void {
  if (kind === 'recap-updated') return
  try {
    const AudioCtor = globalThis.AudioContext ?? (window as Window & { webkitAudioContext?: typeof AudioContext }).webkitAudioContext
    if (!AudioCtor) return
    if (!audioCtx) audioCtx = new AudioCtor()
    const ctx = audioCtx
    if (ctx.state === 'suspended') void ctx.resume()
    const osc = ctx.createOscillator()
    const gain = ctx.createGain()
    const now = ctx.currentTime
    const frequency = kind === 'session-done' ? 660 : kind === 'session-blocked' ? 220 : 520
    osc.type = 'sine'
    osc.frequency.setValueAtTime(frequency, now)
    gain.gain.setValueAtTime(0.0001, now)
    gain.gain.exponentialRampToValueAtTime(0.14, now + 0.015)
    gain.gain.exponentialRampToValueAtTime(0.0001, now + 0.18)
    osc.connect(gain)
    gain.connect(ctx.destination)
    osc.start(now)
    osc.stop(now + 0.2)
  } catch {
    // Audio is best-effort; OS notification still carries the event.
  }
}

function fire(opts: FireOpts): void {
  const { kind, toggles, scopeId, transitionTag, title, body } = opts
  if (!toggles[kind]) return
  if (shouldSkipDedup(dedupKey(kind, scopeId, transitionTag))) return
  playCue(kind)
  const support = detectPermission()
  if (support === 'unsupported') {
    if (!permissionWarned) {
      permissionWarned = true
      console.warn('[notifications] Notification API unsupported; skipping all OS notifications.')
    }
    return
  }
  if (support === 'denied') {
    if (!permissionWarned) {
      permissionWarned = true
      console.warn('[notifications] Notification permission denied; OS notifications will be silently dropped.')
    }
    return
  }
  if (support === 'default') {
    // first time — request, then send subsequent ones (this one is skipped).
    void ensureNotificationPermission()
    return
  }
  try {
    const n = new Notification(title, {
      body: body ?? '',
      tag: `meee2:${kind}:${scopeId}`,
    })
    // Optional: auto-close after a few seconds. WKWebView ignores `requireInteraction`.
    setTimeout(() => { try { n.close() } catch { /* noop */ } }, 8000)
  } catch (err) {
    if (!permissionWarned) {
      permissionWarned = true
      console.warn('[notifications] Notification ctor threw:', (err as Error).message)
    }
  }
}

// ---- session-level diff -> trigger -----------------------------------------

const BLOCKED_STATUSES = new Set(['failed', 'dead'])
const DONE_STATUSES = new Set(['completed', 'done'])
const INTERACTION_STATUSES = new Set(['permissionRequired', 'waitingForUser'])

function sessionNotificationTitle(session: Session): string {
  return session.currentTask
    || session.latestRecap?.content
    || session.recentMessages.find((entry) => entry.role.toLowerCase() === 'user')?.text
    || session.title
    || 'Session'
}

function interactionCount(session: Session | undefined): number {
  if (!session) return 0
  return (INTERACTION_STATUSES.has(session.status) ? 1 : 0)
    + (session.pendingPermissionTool || session.pendingPermissionMessage ? 1 : 0)
    + Math.max(0, session.inboxPending ?? 0)
}

export function runSessionTransitionNotifications(
  prev: Map<string, Session>,
  next: readonly Session[],
  toggles: NotificationToggles,
): void {
  for (const s of next) {
    const old = prev.get(s.id)
    const oldStatus = old?.status
    const newStatus = s.status
    const oldInteractionCount = interactionCount(old)
    const newInteractionCount = interactionCount(s)
    if (oldStatus !== newStatus) {
      if (INTERACTION_STATUSES.has(newStatus)) {
        fire({
          kind: 'permission-request',
          toggles,
          scopeId: s.id,
          transitionTag: `interaction:${newStatus}`,
          title: `${sessionNotificationTitle(s)} needs input`,
          body: s.pendingPermissionMessage
            ?? (s.pendingPermissionTool ? `Approve: ${s.pendingPermissionTool}` : 'Session is waiting for your response.'),
        })
      } else if (BLOCKED_STATUSES.has(newStatus)) {
        fire({
          kind: 'session-blocked',
          toggles,
          scopeId: s.id,
          transitionTag: newStatus,
          title: `${sessionNotificationTitle(s)} is ${newStatus}`,
          body: 'Session entered a blocked state.',
        })
      } else if (DONE_STATUSES.has(newStatus)) {
        fire({
          kind: 'session-done',
          toggles,
          scopeId: s.id,
          transitionTag: newStatus,
          title: `${sessionNotificationTitle(s)} finished`,
          body: 'Session completed the task.',
        })
      }
    }
    if (newInteractionCount > 0 && oldInteractionCount === 0 && oldStatus === newStatus) {
      fire({
        kind: 'permission-request',
        toggles,
        scopeId: s.id,
        transitionTag: `interaction:${newInteractionCount}`,
        title: `${sessionNotificationTitle(s)} needs input`,
        body: s.pendingPermissionMessage
          ?? (s.pendingPermissionTool ? `Approve: ${s.pendingPermissionTool}` : 'Session has pending input.'),
      })
    }
    // recap timestamp change
    const oldTs = old?.latestRecap?.timestamp ?? null
    const newTs = s.latestRecap?.timestamp ?? null
    if (newTs && newTs !== oldTs) {
      fire({
        kind: 'recap-updated',
        toggles,
        scopeId: s.id,
        transitionTag: newTs,
        title: `${s.title || 'Session'} recap updated`,
        body: (s.latestRecap?.content ?? '').slice(0, 120),
      })
    }
  }
}

// ---- planner-level diff -> trigger -----------------------------------------

export function runPlannerApprovalNotifications(
  prev: Map<string, PlanningNode>,
  next: readonly PlanningNode[],
  toggles: NotificationToggles,
): void {
  for (const n of next) {
    const old = prev.get(n.id)
    const wasGate = old?.workflowRunState === 'gate-wait'
    const isGate = n.workflowRunState === 'gate-wait'
    const hasApprovers = (n.approvers?.length ?? 0) > 0
    if (!wasGate && isGate && hasApprovers) {
      fire({
        kind: 'approval-needed',
        toggles,
        scopeId: n.id,
        transitionTag: 'gate-wait',
        title: `Approval needed: ${n.title || 'node'}`,
        body: n.gate?.label ?? 'A planner node is waiting for approver review.',
      })
    }
  }
}

// ---- convenience: snapshot helper ------------------------------------------

export function indexSessions(sessions: readonly Session[]): Map<string, Session> {
  const m = new Map<string, Session>()
  for (const s of sessions) m.set(s.id, s)
  return m
}

export function indexNodes(nodes: readonly PlanningNode[]): Map<string, PlanningNode> {
  const m = new Map<string, PlanningNode>()
  for (const n of nodes) m.set(n.id, n)
  return m
}
