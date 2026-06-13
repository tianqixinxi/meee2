import { ArrowRight, CheckCircle2, CircleAlert, Loader2, PlugZap, RefreshCw, XCircle } from 'lucide-react'
import { useEffect, useMemo, useState } from 'react'
import { ReadinessChecklist } from './ReadinessChecklist'
import type { ReadinessAction, ReadinessCheck, ReadinessReport } from '../types'

interface Props {
  report: ReadinessReport | null
  repairingAction: string | null
  repairError: string | null
  repairLogs: string[]
  onRepair: (actionId: string) => void
  onRefresh: () => void
  onComplete: () => void
  onDegradedEntry: () => void
}

const SETUP_STEPS = [
  {
    id: 'providers',
    label: 'Providers',
    title: 'Choose a local provider',
    detail: 'Install and configure at least one local runtime: Claude Code or Codex.',
    checkIds: ['provider.claude', 'provider.codex'],
  },
  {
    id: 'hooks',
    label: 'Hooks',
    title: 'Wire session events',
    detail: 'Provider hooks and the local socket prove session activity can reach meee2.',
    checkIds: ['provider-hook.claude', 'surface.hook-socket'],
  },
  {
    id: 'runtime',
    label: 'Runtime',
    title: 'Start local services',
    detail: 'The BoardServer and meee2 sidecar runtime keep the workspace controllable.',
    checkIds: ['surface.board-server', 'runtime.meee2-mcp'],
  },
  {
    id: 'storage',
    label: 'Storage',
    title: 'Prepare local state',
    detail: 'Session files, board layout, and runtime storage need writable local paths.',
    checkIds: ['storage.sessions', 'storage.board-layout', 'storage.runtime'],
  },
] as const

type StepState = 'loading' | 'pass' | 'fail' | 'warn' | 'info'

export function FirstRunOnboarding({
  report,
  repairingAction,
  repairError,
  repairLogs,
  onRepair,
  onRefresh,
  onComplete,
  onDegradedEntry,
}: Props) {
  const ready = report?.ready === true
  const busy = repairingAction !== null
  const steps = useMemo(() => buildSetupSteps(report), [report])
  const firstAttentionStep = steps.find((step) => step.state === 'fail' || step.state === 'warn') ?? steps[0]
  const [activeStepId, setActiveStepId] = useState<string | null>(null)

  useEffect(() => {
    if (!activeStepId && firstAttentionStep) {
      setActiveStepId(firstAttentionStep.id)
    }
  }, [activeStepId, firstAttentionStep])

  const activeStep = steps.find((step) => step.id === activeStepId) ?? firstAttentionStep
  const activeIndex = Math.max(0, steps.findIndex((step) => step.id === activeStep?.id))
  const activeReport = report && activeStep
    ? { ...report, checks: activeStep.checks }
    : null
  const currentAction = firstRecoveryAction(activeStep?.checks ?? [])
  const currentStepPassed = activeStep?.state === 'pass'
  const canGoBack = activeIndex > 0
  const canGoNext = activeIndex >= 0 && activeIndex < steps.length - 1
  const primaryLabel = ready
    ? 'Continue'
    : currentAction
      ? currentAction.label
      : currentStepPassed && canGoNext
        ? 'Next step'
        : 'Refresh'

  return (
    <main className="first-run" aria-label="meee2 setup">
      <div className="first-run__shell">
        <header className="first-run__brand">
          <div className="first-run__mark" aria-hidden>
            <PlugZap size={18} />
          </div>
          <span>meee2</span>
        </header>

        <section className="first-run__panel" aria-labelledby="first-run-title">
          <div className="first-run__intro">
            <span>{ready ? 'Ready' : `Step ${activeIndex + 1} of ${steps.length}`}</span>
            <h1 id="first-run-title">{ready ? 'Your workspace is ready' : activeStep?.title ?? 'Connect local AI sessions'}</h1>
            <p>
              {ready
                ? 'meee2 can receive real local session activity and persist workspace state.'
                : activeStep?.detail ?? 'Fix required checks for installed providers, hooks, socket, BoardServer, runtime, and local state.'}
            </p>
          </div>

          <nav className="first-run-steps" aria-label="Setup steps">
            {steps.map((step, index) => (
              <button
                key={step.id}
                type="button"
                className="first-run-step"
                data-active={step.id === activeStep?.id}
                data-state={step.state}
                onClick={() => setActiveStepId(step.id)}
              >
                <span className="first-run-step__index">{index + 1}</span>
                <span className="first-run-step__copy">
                  <strong>{step.label}</strong>
                  <small>{stepSummary(step)}</small>
                </span>
                <StepIcon state={step.state} />
              </button>
            ))}
          </nav>

          <ReadinessChecklist
            report={activeReport}
            repairingAction={repairingAction}
            onRepair={onRepair}
          />

          {repairError && (
            <div className="first-run__error" role="alert">
              {repairError}
            </div>
          )}

          {repairLogs.length > 0 && (
            <details className="first-run__logs" open={busy || Boolean(repairError)}>
              <summary>Repair log</summary>
              <pre>{repairLogs.join('\n')}</pre>
            </details>
          )}

          <div className="first-run__actions">
            <button
              type="button"
              className="ghost first-run__secondary"
              onClick={onDegradedEntry}
              disabled={busy}
            >
              Enter anyway
            </button>
            <button
              type="button"
              className="ghost first-run__secondary"
              onClick={onRefresh}
              disabled={busy}
            >
              <RefreshCw size={14} aria-hidden />
              Refresh
            </button>
            {ready ? (
              <button type="button" className="primary first-run__primary" onClick={onComplete}>
                {primaryLabel}
                <ArrowRight size={15} aria-hidden />
              </button>
            ) : (
              <>
                {canGoBack && (
                  <button
                    type="button"
                    className="ghost first-run__secondary"
                    onClick={() => setActiveStepId(steps[activeIndex - 1].id)}
                    disabled={busy}
                  >
                    Back
                  </button>
                )}
                <button
                  type="button"
                  className="primary first-run__primary"
                  disabled={busy}
                  onClick={() => {
                    if (currentAction) {
                      onRepair(currentAction.id)
                    } else if (currentStepPassed && canGoNext) {
                      setActiveStepId(steps[activeIndex + 1].id)
                    } else {
                      onRefresh()
                    }
                  }}
                >
                  {busy && currentAction && repairingAction === currentAction.id ? (
                    <Loader2 size={15} className="spin" aria-hidden />
                  ) : (
                    currentStepPassed && canGoNext
                      ? <ArrowRight size={15} aria-hidden />
                      : <PlugZap size={15} aria-hidden />
                  )}
                  {primaryLabel}
                </button>
              </>
            )}
          </div>
        </section>
      </div>
    </main>
  )
}

function buildSetupSteps(report: ReadinessReport | null) {
  return SETUP_STEPS.map((step) => {
    const checks = step.checkIds
      .map((id) => report?.checks.find((check) => check.id === id))
      .filter(Boolean) as ReadinessCheck[]
    return {
      ...step,
      checks,
      state: stepState(checks, report === null),
    }
  })
}

function stepState(checks: ReadinessCheck[], loading: boolean): StepState {
  if (loading || checks.length === 0) return 'loading'
  if (checks.some((check) => check.status === 'fail')) return 'fail'
  if (checks.some((check) => check.status === 'warn')) return 'warn'
  if (checks.every((check) => check.status === 'pass')) return 'pass'
  return 'info'
}

function firstRecoveryAction(checks: ReadinessCheck[]): ReadinessAction | null {
  return checks.find((check) => check.status === 'fail' && check.recoveryAction)?.recoveryAction ?? null
}

function stepSummary(step: { state: StepState; checks: ReadinessCheck[] }) {
  if (step.state === 'loading') return 'Checking'
  const failed = step.checks.filter((check) => check.status === 'fail').length
  if (failed > 0) return `${failed} issue${failed === 1 ? '' : 's'}`
  const warned = step.checks.filter((check) => check.status === 'warn').length
  if (warned > 0) return `${warned} warning${warned === 1 ? '' : 's'}`
  return 'Ready'
}

function StepIcon({ state }: { state: StepState }) {
  if (state === 'pass') return <CheckCircle2 size={15} aria-hidden />
  if (state === 'fail') return <XCircle size={15} aria-hidden />
  if (state === 'warn') return <CircleAlert size={15} aria-hidden />
  return <Loader2 size={15} className={state === 'loading' ? 'spin' : undefined} aria-hidden />
}
