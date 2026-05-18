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
      return 'Ready to start work'
    case 'in-progress':
      return 'In progress — open the session'
    case 'gate-review':
      return 'Awaiting gate review'
    case 'confirm-artifacts':
      return 'Done — review output'
    case 'needs-attention':
      return 'Failed — needs attention'
  }
}

export interface StartDeliveryInput {
  title: string
  summary?: string
}

interface Props {
  mode: PlannerMode
  onModeChange: (mode: PlannerMode) => void
  runs: WorkflowRun[]
  selectedRunId: string | null
  onSelectRun: (runId: string) => void
  onStartRun: (input: StartDeliveryInput) => void
  onAbortRun: (runId: string) => void
  onViewHistory: () => void
  busy: boolean
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

/** Count of `done` node-states over total — a run's coarse progress. */
function runProgress(run: WorkflowRun): { done: number; total: number } {
  const states = Object.values(run.nodeStates)
  return {
    done: states.filter((state) => state.runState === 'done').length,
    total: states.length,
  }
}

function runTitle(run: WorkflowRun): string {
  return run.title?.trim() || `Delivery #${run.runIndex}`
}

function runRiskCount(run: WorkflowRun): number {
  return Object.values(run.nodeStates).filter(
    (state) =>
      state.runState === 'failed' ||
      state.runState === 'gate-wait' ||
      state.nextAction === 'needs-attention' ||
      state.nextAction === 'gate-review',
  ).length
}

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
  const [startOpen, setStartOpen] = useState(false)
  const [titleDraft, setTitleDraft] = useState('')
  const [summaryDraft, setSummaryDraft] = useState('')
  const selectedRun = runs.find((run) => run.id === selectedRunId) ?? null
  const submitStart = () => {
    const title = titleDraft.trim()
    if (!title) return
    onStartRun({ title, summary: summaryDraft.trim() || undefined })
    setTitleDraft('')
    setSummaryDraft('')
    setStartOpen(false)
    setOpen(false)
  }

  return (
    <div className="planner-run-selector">
      <div className="planner-run-selector__mode" role="group" aria-label="Planner mode">
        <button
          type="button"
          className={mode === 'design' ? 'is-active' : ''}
          onClick={() => onModeChange('design')}
          title="Plan mode — edit the workflow blueprint. Changes go through proposals."
        >
          <Pencil size={12} aria-hidden /> Plan
        </button>
        <button
          type="button"
          className={mode === 'run' ? 'is-active' : ''}
          onClick={() => onModeChange('run')}
          title="Work mode — execute one named delivery from this Plan."
        >
          <Play size={12} aria-hidden /> Work
        </button>
      </div>

      {mode === 'run' && (
        <div className="planner-run-selector__runs">
          {runs.length === 0 ? (
            <button
              type="button"
              className="planner-run-selector__start primary"
              disabled={busy}
              onClick={() => setStartOpen(true)}
              title="Start a named Delivery from this Plan."
            >
              <Play size={12} aria-hidden /> Start delivery
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
                    {runTitle(selectedRun)}
                    <em>{STATUS_LABEL[selectedRun.status]}</em>
                  </>
                ) : (
                  <span>Select delivery</span>
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
                        {runTitle(run)}
                        <em>
                          {progress.done}/{progress.total} steps · {STATUS_LABEL[run.status]}
                          {runRiskCount(run) > 0 ? ` · ${runRiskCount(run)} needs attention` : ''}
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
                    <History size={12} aria-hidden /> View all deliveries
                  </button>
                  <button
                    type="button"
                    role="menuitem"
                    className="planner-run-selector__menu-action"
                    disabled={busy}
                    onClick={() => {
                      setStartOpen(true)
                    }}
                  >
                    <Play size={12} aria-hidden /> Start delivery
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
                      <Square size={12} aria-hidden /> Abort delivery
                    </button>
                  )}
                </div>
              )}
            </div>
          )}
          {selectedRun && (
            <span className="planner-run-selector__progress" aria-label="Delivery progress">
              <History size={12} aria-hidden />
              {runProgress(selectedRun).done}/{runProgress(selectedRun).total} steps
            </span>
          )}
        </div>
      )}
      {startOpen && (
        <div className="planner-delivery-start" role="dialog" aria-label="Start delivery">
          <label>
            Delivery name
            <input
              autoFocus
              value={titleDraft}
              onChange={(event) => setTitleDraft(event.target.value)}
              placeholder="e.g. Planner MVP"
              onKeyDown={(event) => {
                if (event.key === 'Enter') submitStart()
                if (event.key === 'Escape') setStartOpen(false)
              }}
            />
          </label>
          <label>
            Summary
            <textarea
              value={summaryDraft}
              onChange={(event) => setSummaryDraft(event.target.value)}
              placeholder="What should this delivery accomplish?"
            />
          </label>
          <div className="planner-delivery-start__actions">
            <button type="button" onClick={() => setStartOpen(false)}>
              Cancel
            </button>
            <button type="button" className="primary" disabled={busy || !titleDraft.trim()} onClick={submitStart}>
              Start delivery
            </button>
          </div>
        </div>
      )}
    </div>
  )
}
