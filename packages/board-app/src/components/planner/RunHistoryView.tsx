import { X } from 'lucide-react'
import type { WorkflowRun, WorkflowRunStatus } from '../../types'

interface Props {
  runs: WorkflowRun[]
  selectedRunId: string | null
  onSelectRun: (runId: string) => void
  onClose: () => void
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

function progressOf(run: WorkflowRun): { done: number; total: number } {
  const states = Object.values(run.nodeStates)
  return {
    done: states.filter((state) => state.runState === 'done').length,
    total: states.length,
  }
}

function formatTime(iso: string | null | undefined): string {
  if (!iso) return '—'
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return '—'
  return date.toLocaleString()
}

/**
 * U6 — Run history. Lists every run of a canvas (newest first) with status,
 * progress and timeline. Selecting a run views it (workflow-run-spec §8.6).
 */
export function RunHistoryView({ runs, selectedRunId, onSelectRun, onClose }: Props) {
  return (
    <div
      className="planner-proposal-modal-backdrop"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onClose()
      }}
    >
      <div className="planner-run-history" role="dialog" aria-modal="true" aria-label="Run history">
        <button
          type="button"
          className="planner-proposal-modal__close"
          onClick={onClose}
          aria-label="Close run history"
        >
          <X size={15} aria-hidden />
        </button>
        <div className="planner-run-history__header">
          <span>Execution history</span>
          <h2>{runs.length} run{runs.length === 1 ? '' : 's'}</h2>
        </div>
        {runs.length === 0 ? (
          <p className="planner-node-modal__empty">This blueprint has not been run yet.</p>
        ) : (
          <ul className="planner-run-history__list">
            {[...runs].reverse().map((run) => {
              const progress = progressOf(run)
              return (
                <li key={run.id}>
                  <button
                    type="button"
                    className={run.id === selectedRunId ? 'is-active' : ''}
                    onClick={() => {
                      onSelectRun(run.id)
                      onClose()
                    }}
                  >
                    <span className={`planner-run-history__status is-${run.status}`}>
                      {STATUS_GLYPH[run.status]} Run #{run.runIndex}
                    </span>
                    <span className="planner-run-history__meta">
                      {STATUS_LABEL[run.status]} · {progress.done}/{progress.total} steps
                    </span>
                    <span className="planner-run-history__time">
                      {formatTime(run.startedAt)}
                      {run.finishedAt ? ` → ${formatTime(run.finishedAt)}` : ''}
                    </span>
                    <span className="planner-run-history__trigger">trigger: {run.trigger}</span>
                  </button>
                </li>
              )
            })}
          </ul>
        )}
      </div>
    </div>
  )
}
