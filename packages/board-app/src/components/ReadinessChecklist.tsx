import { CheckCircle2, CircleAlert, Loader2, XCircle } from 'lucide-react'
import type { ReadinessCheck, ReadinessReport } from '../types'

interface Props {
  report: ReadinessReport | null
  repairingAction: string | null
  onRepair: (actionId: string) => void
  compact?: boolean
}

export function ReadinessChecklist({
  report,
  repairingAction,
  onRepair,
  compact = false,
}: Props) {
  if (!report) {
    return (
      <div className="readiness-list" data-compact={compact}>
        <div className="readiness-check" data-state="loading">
          <div className="readiness-check__icon" aria-hidden>
            <Loader2 size={17} className="spin" />
          </div>
          <div className="readiness-check__copy">
            <strong>Checking local readiness</strong>
            <p>Looking at providers, hooks, socket, BoardServer, runtime, and local storage.</p>
          </div>
        </div>
      </div>
    )
  }

  const checks = compact
    ? report.checks.filter((check) => check.severity === 'required' || check.status !== 'pass')
    : report.checks

  return (
    <div className="readiness-list" data-compact={compact}>
      {checks.map((check) => (
        <ReadinessRow
          key={check.id}
          check={check}
          repairing={repairingAction === check.recoveryAction?.id}
          onRepair={onRepair}
        />
      ))}
    </div>
  )
}

function ReadinessRow({
  check,
  repairing,
  onRepair,
}: {
  check: ReadinessCheck
  repairing: boolean
  onRepair: (actionId: string) => void
}) {
  const state = check.status === 'pass'
    ? 'pass'
    : check.status === 'fail'
      ? 'fail'
      : 'warn'
  const action = check.recoveryAction
  return (
    <div className="readiness-check" data-state={state} data-severity={check.severity}>
      <div className="readiness-check__icon" aria-hidden>
        {state === 'pass' ? (
          <CheckCircle2 size={17} />
        ) : state === 'fail' ? (
          <XCircle size={17} />
        ) : (
          <CircleAlert size={17} />
        )}
      </div>
      <div className="readiness-check__copy">
        <div>
          <strong>{check.title}</strong>
          <span>{check.severity}</span>
        </div>
        <p>{check.message || check.detail}</p>
        {action?.command && <small>{action.command}</small>}
      </div>
      {action && (
        <button
          type="button"
          disabled={repairing}
          onClick={() => onRepair(action.id)}
        >
          {repairing ? <Loader2 size={14} className="spin" aria-hidden /> : action.label}
        </button>
      )}
    </div>
  )
}
