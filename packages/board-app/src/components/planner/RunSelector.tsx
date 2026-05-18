import { ChevronDown, History, Pencil, Play, Square } from 'lucide-react'
import { useState } from 'react'
import type { RunNextAction, WorkflowRun, WorkflowRunStatus } from '../../types'

/** The two planner screen modes (workflow-run-spec §8.1). */
export type PlannerMode = 'design' | 'run'

/** Human-readable label for a node's run next-action (WorkflowRunEngine). */
export function runNextActionLabel(action: RunNextAction): string {
  switch (action) {
    case 'waiting-on-upstream':
      return 'Waiting on upstream steps'
    case 'ready-to-dispatch':
      return 'Ready — dispatch or bind a session'
    case 'in-progress':
      return 'In progress — open the session'
    case 'gate-review':
      return 'Awaiting gate review'
    case 'confirm-artifacts':
      return 'Done — confirm artifacts are attached'
    case 'needs-attention':
      return 'Failed — needs attention'
  }
}

interface Props {
  mode: PlannerMode
  onModeChange: (mode: PlannerMode) => void
  runs: WorkflowRun[]
  selectedRunId: string | null
  onSelectRun: (runId: string) => void
  onStartRun: () => void
  onAbortRun: (runId: string) => void
  onViewHistory: () => void
  busy: boolean
}

const STATUS_LABEL: Record<WorkflowRunStatus, string> = {
  active: 'In progress',
  completed: 'Completed',
  failed: 'Failed',
  aborted: 'Aborted',
}

const STATUS_GLYPH: Record<WorkflowRunStatus, string> = {
  active: '●',
  completed: '✓',
  failed: '✗',
  aborted: '⊘',
}

/** Count of `done` node-states over total — a run's coarse progress. */
function runProgress(run: WorkflowRun): { done: number; total: number } {
  const states = Object.values(run.nodeStates)
  return {
    done: states.filter((state) => state.runState === 'done').length,
    total: states.length,
  }
}

/**
 * Top-bar control for the planner: a Design/Run mode toggle plus, in Run mode,
 * a selector over the canvas's workflow runs (workflow-run-spec §8.2).
 */
export function RunSelector({
  mode,
  onModeChange,
  runs,
  selectedRunId,
  onSelectRun,
  onStartRun,
  onAbortRun,
  onViewHistory,
  busy,
}: Props) {
  const [open, setOpen] = useState(false)
  const selectedRun = runs.find((run) => run.id === selectedRunId) ?? null

  return (
    <div className="planner-run-selector">
      <div className="planner-run-selector__mode" role="group" aria-label="Planner mode">
        <button
          type="button"
          className={mode === 'design' ? 'is-active' : ''}
          onClick={() => onModeChange('design')}
          title="Design mode — edit the blueprint (steps, dependencies, gates). Changes go through proposals."
        >
          <Pencil size={12} aria-hidden /> Design
        </button>
        <button
          type="button"
          className={mode === 'run' ? 'is-active' : ''}
          onClick={() => onModeChange('run')}
          title="Run mode — watch one execution of the blueprint."
        >
          <Play size={12} aria-hidden /> Run
        </button>
      </div>

      {mode === 'run' && (
        <div className="planner-run-selector__runs">
          {runs.length === 0 ? (
            <button
              type="button"
              className="planner-run-selector__start primary"
              disabled={busy}
              onClick={onStartRun}
              title="A run executes this blueprint once — it tracks its own progress, sessions and artifacts."
            >
              <Play size={12} aria-hidden /> Start first run
            </button>
          ) : (
            <div className="planner-run-selector__picker">
              <button
                type="button"
                className="planner-run-selector__current"
                onClick={() => setOpen((value) => !value)}
                aria-expanded={open}
              >
                {selectedRun ? (
                  <>
                    <span>{STATUS_GLYPH[selectedRun.status]}</span>
                    Run #{selectedRun.runIndex}
                    <em>{STATUS_LABEL[selectedRun.status]}</em>
                  </>
                ) : (
                  <span>Select a run</span>
                )}
                <ChevronDown size={13} aria-hidden />
              </button>
              {open && (
                <div className="planner-run-selector__menu" role="menu">
                  {[...runs].reverse().map((run) => {
                    const progress = runProgress(run)
                    return (
                      <button
                        type="button"
                        key={run.id}
                        role="menuitem"
                        className={run.id === selectedRunId ? 'is-active' : ''}
                        onClick={() => {
                          onSelectRun(run.id)
                          setOpen(false)
                        }}
                      >
                        <span>{STATUS_GLYPH[run.status]}</span>
                        Run #{run.runIndex}
                        <em>
                          {progress.done}/{progress.total} steps · {STATUS_LABEL[run.status]}
                        </em>
                      </button>
                    )
                  })}
                  <div className="planner-run-selector__menu-divider" />
                  <button
                    type="button"
                    role="menuitem"
                    className="planner-run-selector__menu-action"
                    onClick={() => {
                      onViewHistory()
                      setOpen(false)
                    }}
                  >
                    <History size={12} aria-hidden /> View all runs
                  </button>
                  <button
                    type="button"
                    role="menuitem"
                    className="planner-run-selector__menu-action"
                    disabled={busy}
                    onClick={() => {
                      onStartRun()
                      setOpen(false)
                    }}
                  >
                    <Play size={12} aria-hidden /> Start new run
                  </button>
                  {selectedRun?.status === 'active' && (
                    <button
                      type="button"
                      role="menuitem"
                      className="planner-run-selector__menu-action"
                      disabled={busy}
                      onClick={() => {
                        onAbortRun(selectedRun.id)
                        setOpen(false)
                      }}
                    >
                      <Square size={12} aria-hidden /> Abort run #{selectedRun.runIndex}
                    </button>
                  )}
                </div>
              )}
            </div>
          )}
          {selectedRun && (
            <span className="planner-run-selector__progress" aria-label="Run progress">
              <History size={12} aria-hidden />
              {runProgress(selectedRun).done}/{runProgress(selectedRun).total} steps
            </span>
          )}
        </div>
      )}
    </div>
  )
}
