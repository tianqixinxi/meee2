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
  completed: 'Done',
  failed: 'Needs attention',
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
 * Lists every Delivery of a canvas (newest first) with status and progress.
 */
export function RunHistoryView({ runs, selectedRunId, onSelectRun, onClose }: Props) {
  return (
    <div
      className="planner-proposal-modal-backdrop"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onClose()
      }}
    >
      <div className="planner-run-history" role="dialog" aria-modal="true" aria-label="Delivery history">
        <button
          type="button"
          className="planner-proposal-modal__close"
          onClick={onClose}
          aria-label="Close delivery history"
        >
          <X size={15} aria-hidden />
        </button>
        <div className="planner-run-history__header">
          <span>Deliveries</span>
          <h2>{runs.length} delivery{runs.length === 1 ? '' : 'ies'}</h2>
        </div>
        {runs.length === 0 ? (
          <p className="planner-node-modal__empty">This Plan has no Delivery yet.</p>
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
                      {STATUS_GLYPH[run.status]} {run.title?.trim() || `Delivery #${run.runIndex}`}
                    </span>
                    <span className="planner-run-history__meta">
                      {STATUS_LABEL[run.status]} · {progress.done}/{progress.total} steps
                    </span>
                    <span className="planner-run-history__time">
                      {formatTime(run.updatedAt || run.startedAt)}
                      {run.finishedAt ? ` → ${formatTime(run.finishedAt)}` : ''}
                    </span>
                    {run.summary && <span className="planner-run-history__trigger">{run.summary}</span>}
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
