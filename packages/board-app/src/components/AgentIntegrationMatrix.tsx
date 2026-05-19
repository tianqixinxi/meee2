import { RefreshCw, X } from 'lucide-react'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { fetchAgentScan, generateIntegrationRunbook, installIntegration } from '../api'
import type {
  AgentIntegrationStatus,
  AgentScanResult,
  IntegrationConnState,
  IntegrationInstall,
  IntegrationInstallResult,
  IntegrationRunbookResult,
} from '../types'
import { IntegrationArtifactPicker } from './IntegrationArtifactPicker'

/** Integrations whose backend exposes a browse endpoint (PRs / docs / …). */
const BROWSABLE: ReadonlySet<string> = new Set(['github', 'lark'])

const STATE_GLYPH: Record<IntegrationConnState, string> = {
  connected: '✓',
  partial: '◐',
  missing: '✗',
}
const STATE_LABEL: Record<IntegrationConnState, string> = {
  connected: 'Connected',
  partial: 'Partial',
  missing: 'Missing',
}
const AGENT_LABEL: Record<string, string> = {
  'claude-code': 'Claude Code',
  codex: 'Codex',
}

interface IntegrationRow {
  id: string
  name: string
  category: string
  byAgent: Record<string, AgentIntegrationStatus>
}

/**
 * Agent × integration detection matrix (agent-integration-detection P4).
 * Rows = integrations, columns = local agents, cells = connected/partial/
 * missing. A not-fully-connected row offers "Set up" → generates a runbook.
 */
export function AgentIntegrationMatrix() {
  const [scan, setScan] = useState<AgentScanResult | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)
  const [runbook, setRunbook] = useState<IntegrationRunbookResult | null>(null)
  const [installResult, setInstallResult] = useState<IntegrationInstallResult | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [browsingId, setBrowsingId] = useState<'github' | 'lark' | null>(null)

  const load = useCallback(() => {
    setLoading(true)
    setError(null)
    fetchAgentScan()
      .then(setScan)
      .catch((err: unknown) => setError(err instanceof Error ? err.message : 'scan failed'))
      .finally(() => setLoading(false))
  }, [])
  useEffect(() => {
    load()
  }, [load])

  const agents = scan?.agents ?? []

  const rows = useMemo<IntegrationRow[]>(() => {
    if (!scan) return []
    const byId = new Map<string, IntegrationRow>()
    for (const status of scan.statuses) {
      let row = byId.get(status.integrationId)
      if (!row) {
        row = {
          id: status.integrationId,
          name: status.integrationName,
          category: status.category,
          byAgent: {},
        }
        byId.set(status.integrationId, row)
      }
      row.byAgent[status.agent] = status
    }
    return [...byId.values()].sort((a, b) => a.name.localeCompare(b.name))
  }, [scan])

  const handleSetup = (id: string) => {
    setBusyId(id)
    setError(null)
    generateIntegrationRunbook(id)
      .then(setRunbook)
      .catch((err: unknown) => setError(err instanceof Error ? err.message : 'runbook failed'))
      .finally(() => setBusyId(null))
  }

  /** Pattern A — true one-click install for `.remoteHttp` integrations. */
  const handleInstall = (id: string) => {
    setBusyId(id)
    setError(null)
    installIntegration(id)
      .then((result) => {
        setInstallResult(result)
        load() // re-scan so the matrix reflects the new state
      })
      .catch((err: unknown) => setError(err instanceof Error ? err.message : 'install failed'))
      .finally(() => setBusyId(null))
  }

  const rowFullyConnected = (row: IntegrationRow) =>
    agents.length > 0 && agents.every((agent) => row.byAgent[agent]?.state === 'connected')

  /** Browse uses the credential (gh / lark-cli) — MCP need not be configured. */
  const rowHasBrowse = (row: IntegrationRow) =>
    BROWSABLE.has(row.id) && agents.some((agent) => row.byAgent[agent]?.credentialPresent)

  /** Install spec is per-integration; pick from any agent row (all the same). */
  const installFor = (row: IntegrationRow): IntegrationInstall | undefined =>
    agents.map((agent) => row.byAgent[agent]?.install).find((spec) => spec !== undefined)

  return (
    <section className="agent-matrix" aria-label="Agent integration matrix">
      <header className="agent-matrix__header">
        <div>
          <span>Agent integrations</span>
          <h2>本地 agent 接入体检</h2>
        </div>
        <button type="button" className="agent-matrix__rescan" disabled={loading} onClick={load}>
          <RefreshCw size={13} aria-hidden /> {loading ? 'Scanning…' : 'Re-scan'}
        </button>
      </header>

      {error && <p className="agent-matrix__error">{error}</p>}

      {scan && rows.length > 0 && (
        <table className="agent-matrix__table">
          <thead>
            <tr>
              <th>Integration</th>
              {agents.map((agent) => (
                <th key={agent}>{AGENT_LABEL[agent] ?? agent}</th>
              ))}
              <th aria-label="actions" />
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr key={row.id}>
                <td className="agent-matrix__name">
                  {row.name}
                  <em>{row.category}</em>
                </td>
                {agents.map((agent) => {
                  const cell = row.byAgent[agent]
                  const state: IntegrationConnState = cell?.state ?? 'missing'
                  return (
                    <td
                      key={agent}
                      className={`agent-matrix__cell is-${state}`}
                      title={cell?.evidence}
                    >
                      <span aria-hidden>{STATE_GLYPH[state]}</span> {STATE_LABEL[state]}
                    </td>
                  )
                })}
                <td className="agent-matrix__action">
                  {!rowFullyConnected(row) && (() => {
                    const install = installFor(row)
                    if (install?.kind === 'remoteHttp') {
                      return (
                        <button
                          type="button"
                          className="agent-matrix__install"
                          disabled={busyId === row.id}
                          onClick={() => handleInstall(row.id)}
                          title={`One-click install via ${install.url} (OAuth on first use)`}
                        >
                          {busyId === row.id ? '…' : 'Install'}
                        </button>
                      )
                    }
                    if (install?.kind === 'unsupported') {
                      return (
                        <button type="button" className="agent-matrix__setup" disabled title={install.reason}>
                          Unsupported
                        </button>
                      )
                    }
                    // localStdio (token-based) — fall back to runbook flow.
                    return (
                      <button
                        type="button"
                        className="agent-matrix__setup"
                        disabled={busyId === row.id}
                        onClick={() => handleSetup(row.id)}
                      >
                        {busyId === row.id ? '…' : 'Set up'}
                      </button>
                    )
                  })()}
                  {rowHasBrowse(row) && (
                    <button
                      type="button"
                      className="agent-matrix__browse"
                      onClick={() => setBrowsingId(row.id as 'github' | 'lark')}
                      title={`Browse ${row.name} items`}
                    >
                      Browse
                    </button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {browsingId && (
        <div className="agent-matrix__browse-panel">
          <div className="agent-matrix__browse-header">
            <strong>Browse {browsingId}</strong>
            <button
              type="button"
              onClick={() => setBrowsingId(null)}
              aria-label="Close browse"
              className="agent-matrix__browse-close"
            >
              <X size={14} aria-hidden />
            </button>
          </div>
          <IntegrationArtifactPicker
            provider={browsingId}
            onClose={() => setBrowsingId(null)}
          />
        </div>
      )}

      {installResult && (
        <div
          className="agent-matrix__runbook-backdrop"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) setInstallResult(null)
          }}
        >
          <div className="agent-matrix__runbook" role="dialog" aria-modal="true" aria-label="Install result">
            <button
              type="button"
              className="agent-matrix__runbook-close"
              onClick={() => setInstallResult(null)}
              aria-label="Close install result"
            >
              <X size={15} aria-hidden />
            </button>
            <h3>
              Installed {installResult.integrationId}
              {' '}
              <em style={{ fontStyle: 'normal', fontSize: 12, color: 'var(--text-faint)' }}>
                Claude {installResult.claudeOK ? '✓' : '✗'} · Codex {installResult.codexOK ? '✓' : '✗'}
              </em>
            </h3>
            <ul style={{ margin: 0, paddingLeft: 18, fontSize: 12, lineHeight: 1.55, color: 'var(--text-dim)' }}>
              {installResult.messages.map((msg, idx) => (<li key={idx}>{msg}</li>))}
            </ul>
          </div>
        </div>
      )}

      {runbook && (
        <div
          className="agent-matrix__runbook-backdrop"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) setRunbook(null)
          }}
        >
          <div className="agent-matrix__runbook" role="dialog" aria-modal="true" aria-label="Connect runbook">
            <button
              type="button"
              className="agent-matrix__runbook-close"
              onClick={() => setRunbook(null)}
              aria-label="Close runbook"
            >
              <X size={15} aria-hidden />
            </button>
            <h3>Runbook — connect {runbook.integrationId}</h3>
            <p className="agent-matrix__runbook-path">
              已生成:<code>{runbook.path}</code>
            </p>
            <pre className="agent-matrix__runbook-content">{runbook.content}</pre>
            <div className="agent-matrix__dispatch">
              <span>派给 agent 执行(在终端运行):</span>
              {Object.entries(runbook.dispatch).map(([agent, command]) => (
                <div key={agent}>
                  <strong>{AGENT_LABEL[agent] ?? agent}</strong>
                  <code>{command}</code>
                </div>
              ))}
            </div>
          </div>
        </div>
      )}
    </section>
  )
}
