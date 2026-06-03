// Minimal in-browser telemetry shim for planner intent decisions.
// There is no shared telemetry bus in this package yet (TODO: replace with a
// real sink once one exists — likely a `/api/telemetry` POST or a shared
// PostHog/Datadog client). For now we log to console and dispatch a window
// CustomEvent so anyone (Playwright tests, dev console, future bridge) can
// observe planner intent decisions without us hand-wiring callsites.

export type PlannerTelemetryEvent =
  | 'planner.canvas_mutated'
  | 'planner.answer_only'
  | 'planner.user_revert_within_30s'
  | 'planner.promote_into_session_prompt'
  | 'planner.scene_template_applied'

export interface PlannerTelemetryPayload {
  canvasId?: string
  nodeId?: string
  sessionId?: string
  templateId?: string
  intent?: 'answer' | 'edit' | 'inspect' | 'promote'
  reason?: string
  message?: string
  /** ms since the canvas mutation that this revert undoes (only for revert events). */
  revertedAfterMs?: number
}

const MUTATION_TIMESTAMPS = new Map<string, number>()
const REVERT_WINDOW_MS = 30_000

export function emitPlannerEvent(event: PlannerTelemetryEvent, payload: PlannerTelemetryPayload = {}): void {
  // Track the most recent canvas mutation per canvas so we can spot quick reverts.
  if (event === 'planner.canvas_mutated' && payload.canvasId) {
    MUTATION_TIMESTAMPS.set(payload.canvasId, Date.now())
  }

  try {
    // eslint-disable-next-line no-console
    console.info('[planner.telemetry]', event, payload)
  } catch {
    // ignore — telemetry must never throw
  }

  if (typeof window !== 'undefined' && typeof window.dispatchEvent === 'function') {
    try {
      window.dispatchEvent(new CustomEvent('meee2:telemetry', { detail: { event, payload } }))
    } catch {
      // ignore — CustomEvent unsupported (e.g. very old SSR shim)
    }
  }
}

/**
 * Call when the user undoes a planner action (reject / withdraw / manual edit-back).
 * If a canvas mutation happened within REVERT_WINDOW_MS, emit a revert telemetry event
 * tagged with the elapsed time — this is the signal the spec asks for ("how often
 * the user immediately reverts a planner-imposed change").
 */
export function reportPlannerRevert(canvasId: string, extra: PlannerTelemetryPayload = {}): void {
  const last = MUTATION_TIMESTAMPS.get(canvasId)
  if (!last) return
  const elapsed = Date.now() - last
  if (elapsed > REVERT_WINDOW_MS) return
  emitPlannerEvent('planner.user_revert_within_30s', { ...extra, canvasId, revertedAfterMs: elapsed })
  MUTATION_TIMESTAMPS.delete(canvasId)
}
