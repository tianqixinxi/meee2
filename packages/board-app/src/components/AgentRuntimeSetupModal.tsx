import { CheckCircle2, Loader2, PlugZap, XCircle } from 'lucide-react'
import type { Meee2AgentRuntimeStatus } from '../types'

interface Props {
  status: Meee2AgentRuntimeStatus
  installingTarget: 'claude' | 'codex' | 'all' | null
  installError: string | null
  installLogs: string[]
  onInstall: (target: 'claude' | 'codex' | 'all') => void
  onClose: () => void
}

export function AgentRuntimeSetupModal({
  status,
  installingTarget,
  installError,
  installLogs,
  onInstall,
  onClose,
}: Props) {
  const hasPendingInstall =
    (status.claude.available && !status.claude.configured)
    || (status.codex.available && !status.codex.configured)
  return (
    <div className="modal-backdrop" role="presentation" onMouseDown={(event) => {
      if (event.target === event.currentTarget) onClose()
    }}>
      <section
        className="modal agent-runtime-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="agent-runtime-title"
      >
        <div className="modal-header agent-runtime-modal__header">
          <div className="agent-runtime-modal__icon" aria-hidden>
            <PlugZap size={19} />
          </div>
          <div>
            <div id="agent-runtime-title" className="modal-title">Set up Meee2 Agent Runtime</div>
            <div className="modal-subtitle">Install the local plugin/skill bridge for Claude Code and Codex.</div>
          </div>
        </div>
        <div className="modal-body agent-runtime-modal__body">
          <RuntimeRow
            title="Claude Code"
            ready={status.claude.configured}
            available={status.claude.available}
            cliAvailable={status.claude.cliAvailable}
            appAvailable={status.claude.appAvailable}
            detail={status.claude.detail}
            busy={installingTarget === 'claude' || installingTarget === 'all'}
            onInstall={() => onInstall('claude')}
          />
          <RuntimeRow
            title="Codex"
            ready={status.codex.configured}
            available={status.codex.available}
            cliAvailable={status.codex.cliAvailable}
            appAvailable={status.codex.appAvailable}
            detail={status.codex.detail}
            busy={installingTarget === 'codex' || installingTarget === 'all'}
            onInstall={() => onInstall('codex')}
          />
          {installError && <div className="agent-runtime-modal__error">{installError}</div>}
          {installLogs.length > 0 && (
            <details className="agent-runtime-modal__logs" open={installingTarget !== null || !!installError}>
              <summary>Install log</summary>
              <pre>{installLogs.join('\n')}</pre>
            </details>
          )}
          <details className="agent-runtime-modal__path">
            <summary>Plugin source</summary>
            <code>{status.marketplacePath}</code>
          </details>
        </div>
        <div className="modal-footer">
          <button type="button" className="ghost" onClick={onClose}>Later</button>
          <button
            type="button"
            className="primary"
            disabled={!hasPendingInstall || installingTarget !== null}
            onClick={() => onInstall('all')}
          >
            {installingTarget === 'all' ? 'Installing...' : hasPendingInstall ? 'Install missing' : 'All set'}
          </button>
        </div>
      </section>
    </div>
  )
}

function RuntimeRow({
  title,
  ready,
  available,
  cliAvailable,
  appAvailable,
  detail,
  busy,
  onInstall,
}: {
  title: string
  ready: boolean
  available: boolean
  cliAvailable: boolean
  appAvailable: boolean
  detail: string | null
  busy: boolean
  onInstall: () => void
}) {
  const actionLabel = ready ? 'Installed' : available ? 'Install' : 'Unavailable'
  return (
    <div className="agent-runtime-row" data-ready={ready}>
      <div className="agent-runtime-row__status" aria-hidden>
        {ready ? <CheckCircle2 size={18} /> : <XCircle size={18} />}
      </div>
      <div className="agent-runtime-row__copy">
        <strong>{title}</strong>
        <span>{detail ?? (ready ? 'Ready' : 'Not configured')}</span>
        <small>CLI {cliAvailable ? 'found' : 'missing'} · App {appAvailable ? 'found' : 'missing'}</small>
      </div>
      <button type="button" disabled={!available || ready || busy} onClick={onInstall}>
        {busy ? <Loader2 size={14} className="spin" aria-hidden /> : actionLabel}
      </button>
    </div>
  )
}
