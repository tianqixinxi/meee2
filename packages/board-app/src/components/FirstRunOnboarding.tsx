import { ArrowRight, CheckCircle2, Loader2, PlugZap, RefreshCw, XCircle } from 'lucide-react'
import type { Meee2AgentRuntimeStatus } from '../types'

interface Props {
  status: Meee2AgentRuntimeStatus | null
  installingTarget: 'claude' | 'codex' | 'all' | null
  installError: string | null
  installLogs: string[]
  onInstall: (target: 'claude' | 'codex' | 'all') => void
  onRefresh: () => void
  onComplete: () => void
  onSkip: () => void
}

export function FirstRunOnboarding({
  status,
  installingTarget,
  installError,
  installLogs,
  onInstall,
  onRefresh,
  onComplete,
  onSkip,
}: Props) {
  const allReady = Boolean(status && status.claude.configured && status.codex.configured)
  const hasPendingInstall = Boolean(status && (
    (status.claude.available && !status.claude.configured)
    || (status.codex.available && !status.codex.configured)
  ))
  const busy = installingTarget !== null

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
            <span>Local setup</span>
            <h1 id="first-run-title">Set up your agent runtime</h1>
            <p>Connect the local bridge for Claude Code and Codex, then enter your workspace.</p>
          </div>

          <div className="first-run__status-list" aria-label="Runtime status">
            <RuntimeStatusRow
              title="Claude Code"
              component={status?.claude ?? null}
              busy={installingTarget === 'claude' || installingTarget === 'all'}
              onInstall={() => onInstall('claude')}
            />
            <RuntimeStatusRow
              title="Codex"
              component={status?.codex ?? null}
              busy={installingTarget === 'codex' || installingTarget === 'all'}
              onInstall={() => onInstall('codex')}
            />
          </div>

          {installError && (
            <div className="first-run__error" role="alert">
              {installError}
            </div>
          )}

          {installLogs.length > 0 && (
            <details className="first-run__logs" open={busy || Boolean(installError)}>
              <summary>Install log</summary>
              <pre>{installLogs.join('\n')}</pre>
            </details>
          )}

          <div className="first-run__actions">
            <button
              type="button"
              className="ghost first-run__secondary"
              onClick={onSkip}
              disabled={busy}
            >
              Skip for now
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
            {allReady ? (
              <button type="button" className="primary first-run__primary" onClick={onComplete}>
                Continue
                <ArrowRight size={15} aria-hidden />
              </button>
            ) : (
              <button
                type="button"
                className="primary first-run__primary"
                disabled={!hasPendingInstall || busy}
                onClick={() => onInstall('all')}
              >
                {busy && installingTarget === 'all' ? (
                  <Loader2 size={15} className="spin" aria-hidden />
                ) : (
                  <PlugZap size={15} aria-hidden />
                )}
                {status ? 'Set up missing' : 'Checking...'}
              </button>
            )}
          </div>
        </section>
      </div>
    </main>
  )
}

function RuntimeStatusRow({
  title,
  component,
  busy,
  onInstall,
}: {
  title: string
  component: Meee2AgentRuntimeStatus['claude'] | null
  busy: boolean
  onInstall: () => void
}) {
  const ready = Boolean(component?.configured)
  const available = Boolean(component?.available)
  const loading = !component
  const stateLabel = loading ? 'Checking' : ready ? 'Ready' : available ? 'Needs setup' : 'Unavailable'
  const detail = loading
    ? 'Looking for the local app and CLI.'
    : component.detail ?? (ready ? 'Configured' : available ? 'Ready to install the bridge.' : 'App or CLI not found.')

  return (
    <div className="first-run-runtime" data-state={loading ? 'loading' : ready ? 'ready' : available ? 'missing' : 'unavailable'}>
      <div className="first-run-runtime__icon" aria-hidden>
        {loading || busy ? (
          <Loader2 size={18} className="spin" />
        ) : ready ? (
          <CheckCircle2 size={18} />
        ) : (
          <XCircle size={18} />
        )}
      </div>
      <div className="first-run-runtime__copy">
        <div>
          <strong>{title}</strong>
          <span>{stateLabel}</span>
        </div>
        <p>{detail}</p>
        {component && (
          <small>CLI {component.cliAvailable ? 'found' : 'missing'} · App {component.appAvailable ? 'found' : 'missing'}</small>
        )}
      </div>
      <button
        type="button"
        disabled={loading || ready || !available || busy}
        onClick={onInstall}
      >
        {busy ? <Loader2 size={14} className="spin" aria-hidden /> : ready ? 'Ready' : 'Install'}
      </button>
    </div>
  )
}
