/**
 * Feature flags for the canvas-runtime 5-atom data-model frontend (PR8 / 8.5 /
 * 9.5). board-app has no dedicated flag infrastructure — the established
 * pattern is `import.meta.env.VITE_*` reads (see `App.tsx` / `api.ts`
 * `VITE_PLANNER_DEMO`). We follow that here.
 *
 * Spec flag names:
 *   - `canvas.monitor.v2` — the MonitorGrid + card registry (PR8).
 *
 * Env wiring (Vite only forwards `VITE_`-prefixed vars to the bundle):
 *   - `VITE_CANVAS_MONITOR_V2=1`
 *
 * Until the backend is wired, both default OFF in production builds and ON in
 * the Vite dev server (`import.meta.env.DEV`) so the renderer is exercised
 * during development without lighting it up for end users.
 */

function readBoolEnv(key: string): boolean | undefined {
  const raw = (import.meta.env as Record<string, string | undefined>)[key]
  if (raw === undefined) return undefined
  return raw === '1' || raw === 'true'
}

/** `canvas.monitor.v2` — MonitorGrid + card registry. */
export const CANVAS_MONITOR_V2: boolean =
  readBoolEnv('VITE_CANVAS_MONITOR_V2') ?? Boolean(import.meta.env.DEV)

/**
 * PM-addon gate (Principle 15). The `cadence-reminder` card asserts an
 * expectation rather than recording activity, so the core ledger never emits
 * it — it only renders when the canvas's optional PM addon is enabled. No
 * backend addon flag exists yet, so this is a standalone const gate defaulting
 * OFF; flip via `VITE_CANVAS_PM_ADDON=1` to exercise the renderer.
 */
export const CANVAS_PM_ADDON: boolean =
  readBoolEnv('VITE_CANVAS_PM_ADDON') ?? false
