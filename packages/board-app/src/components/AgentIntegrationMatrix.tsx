import { RefreshCw, Sparkles, X } from 'lucide-react'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  completeIntegrationAuth,
  fetchAgentScan,
  fetchCanvases,
  generateIntegrationRunbook,
  installIntegration,
  preauthIntegration,
  uploadIntegrationCredentials,
} from '../api'
import { useI18n, type TranslationKey } from '../lib/i18n'
import type {
  AgentIntegrationStatus,
  AgentScanResult,
  CanvasList,
  IntegrationConnState,
  IntegrationInstall,
  IntegrationInstallResult,
  IntegrationRunbookResult,
} from '../types'
import { IntegrationArtifactPicker } from './IntegrationArtifactPicker'
import { Notice } from './feedback/Notice'
import githubIcon from '../assets/integrations/github.svg'
import googleSheetsIcon from '../assets/integrations/google-sheets.svg'
import larkIcon from '../assets/integrations/lark.png'
import linearIcon from '../assets/integrations/linear.svg'
import notionIcon from '../assets/integrations/notion.svg'
import slackIcon from '../assets/integrations/slack.svg'

/** Integrations whose backend exposes a browse endpoint (PRs / docs / …). */
const BROWSABLE: ReadonlySet<string> = new Set(['github', 'lark'])

/** Curated integrations surfaced by meee2. The backend scan intentionally
 *  returns this catalog only; marketplace/registry long-tail entries are not
 *  part of the Integrations product surface. */
const FEATURED_INTEGRATION_IDS: ReadonlySet<string> = new Set([
  'github', 'linear', 'slack', 'lark', 'notion',
  'google-sheets',
])

const FEATURED_INTEGRATION_ORDER = [
  'github', 'linear', 'slack', 'lark', 'notion',
  'google-sheets',
]

const AGENT_LABEL: Record<string, string> = {
  'claude-code': 'Claude Code',
  codex: 'Codex',
}

const INTEGRATION_DESCRIPTION_KEY: Record<string, TranslationKey> = {
  github: 'integrations.description.github',
  linear: 'integrations.description.linear',
  slack: 'integrations.description.slack',
  lark: 'integrations.description.lark',
  notion: 'integrations.description.notion',
  'google-sheets': 'integrations.description.googleSheets',
}

const INTEGRATION_ICON: Record<string, string> = {
  github: githubIcon,
  linear: linearIcon,
  slack: slackIcon,
  lark: larkIcon,
  notion: notionIcon,
  'google-sheets': googleSheetsIcon,
}

interface IntegrationRow {
  id: string
  name: string
  category: string
  byAgent: Record<string, AgentIntegrationStatus>
}

interface Props {
  /** Jump to a canvas in planner mode — used by the post-install
   *  recommend-workflow flow to take the user straight to the new proposal. */
  onJumpToCanvas?: (canvasId: string) => void
}

/**
 * Agent × integration detection matrix (agent-integration-detection P4).
 * Rows = integrations, columns = local agents, cells = connected/partial/
 * missing. A not-fully-connected row offers "Set up" → generates a runbook.
 */
export function AgentIntegrationMatrix({ onJumpToCanvas }: Props = {}) {
  const { t } = useI18n()
  const [scan, setScan] = useState<AgentScanResult | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)
  const [runbook, setRunbook] = useState<IntegrationRunbookResult | null>(null)
  const [installResult, setInstallResult] = useState<IntegrationInstallResult | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [browsingId, setBrowsingId] = useState<'github' | 'lark' | null>(null)
  const [canvasList, setCanvasList] = useState<CanvasList | null>(null)
  /** Persistent Notice for the one-click "Complete auth" flow — shows
   *  "Browser opening…" + fallback link, auto-clears once a re-scan flips
   *  the row to `connected`. */
  const [authNotice, setAuthNotice] = useState<
    { id: string; message: string; authUrl?: string | null } | null
  >(null)

  const load = useCallback(() => {
    setLoading(true)
    setError(null)
    fetchAgentScan()
      .then(setScan)
      .catch((err: unknown) => setError(err instanceof Error ? err.message : t('integrations.scanFailed')))
      .finally(() => setLoading(false))
  }, [t])
  useEffect(() => {
    load()
  }, [load])

  /** Canvas list for the post-install "try in canvas" CTA — we only need
   *  `activeCanvasId` to know where to drop the user. ui-simplification removed
   *  the per-canvas picker + planner-proposal sub-flow from this modal. */
  useEffect(() => {
    let cancelled = false
    fetchCanvases()
      .then((list) => {
        if (cancelled) return
        setCanvasList(list)
      })
      .catch(() => {
        /* canvas list is best-effort — the CTA just hides if missing */
      })
    return () => {
      cancelled = true
    }
  }, [])

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
    return [...byId.values()].sort(
      (a, b) => a.category.localeCompare(b.category) || a.name.localeCompare(b.name),
    )
  }, [scan])

  const featuredRows = useMemo(() => rows
    .filter((row) => FEATURED_INTEGRATION_IDS.has(row.id))
    .sort((a, b) => FEATURED_INTEGRATION_ORDER.indexOf(a.id) - FEATURED_INTEGRATION_ORDER.indexOf(b.id)),
  [rows])

  const handleSetup = (id: string) => {
    setBusyId(id)
    setError(null)
    generateIntegrationRunbook(id)
      .then(setRunbook)
      .catch((err: unknown) => setError(err instanceof Error ? err.message : t('integrations.runbookFailed')))
      .finally(() => setBusyId(null))
  }

  /** One-click "Complete auth" — server spawns mcp-remote, browser pops,
   *  user clicks Allow, token caches to ~/.mcp-auth/. We poll with re-scans
   *  for ~30s so the matrix flips to `connected` without the user needing
   *  to hit Re-scan themselves. */
  const handleCompleteAuth = (id: string) => {
    setBusyId(id)
    setError(null)
    setAuthNotice(null)
    completeIntegrationAuth(id)
      .then((result) => {
        setAuthNotice({ id, message: result.message, authUrl: result.authUrl })
        if (!result.spawned) return // bail polling — nothing to wait for
        // Poll re-scan a few times — OAuth usually completes within ~15s of
        // browser auth-click; we don't want the user staring at a stale row.
        let attempts = 0
        const poll = () => {
          attempts += 1
          fetchAgentScan()
            .then((freshScan) => {
              setScan(freshScan)
              const stillNeedsAuth = freshScan.statuses.some(
                (s) => s.integrationId === id && s.state === 'needs_auth',
              )
              if (stillNeedsAuth && attempts < 10) {
                setTimeout(poll, 3000)
              } else if (!stillNeedsAuth) {
                setAuthNotice({ id, message: `${id} ${t('integrations.connected').toLowerCase()}.` })
                setTimeout(() => setAuthNotice(null), 4000)
              }
            })
            .catch(() => { /* best-effort — manual Re-scan still works */ })
        }
        setTimeout(poll, 3000)
      })
      .catch((err: unknown) => setError(err instanceof Error ? err.message : t('integrations.completeAuthFailed')))
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
      .catch((err: unknown) => setError(err instanceof Error ? err.message : t('integrations.installFailed')))
      .finally(() => setBusyId(null))
  }

  // localStdio Connect — credentials.json file picker + install + pre-auth.
  const fileInputRef = useRef<HTMLInputElement | null>(null)
  const connectPendingId = useRef<string | null>(null)

  /** localStdio connector Connect entry. OAuth-via-server connectors (envKeys
   *  include CREDENTIALS_PATH, e.g. google-sheets) need the user's OAuth client
   *  credentials.json first → file picker. Others (e.g. lark, creds via ccops)
   *  install directly. */
  const handleConnectLocalStdio = (id: string, install: IntegrationInstall) => {
    if (install.kind !== 'localStdio') return
    if (install.envKeys.includes('CREDENTIALS_PATH')) {
      connectPendingId.current = id
      fileInputRef.current?.click()
      return
    }
    handleInstall(id)
  }

  /** credentials.json chosen → upload, install (registers + injects env), then
   *  pre-auth (provoke the server's browser OAuth). Aggregate the step messages
   *  into the install-result modal. */
  const onCredentialsFileChosen = async (file: File) => {
    const id = connectPendingId.current
    connectPendingId.current = null
    if (!id) return
    setBusyId(id)
    setError(null)
    try {
      const content = await file.text()
      const messages: string[] = []
      const cred = await uploadIntegrationCredentials(id, content)
      messages.push(cred.message)
      const installed = await installIntegration(id)
      messages.push(...installed.messages)
      const preauth = await preauthIntegration(id)
      messages.push(preauth.message)
      setInstallResult({
        integrationId: id,
        claudeOK: installed.claudeOK,
        codexOK: installed.codexOK,
        messages,
      })
      load()
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : t('integrations.installFailed'))
    } finally {
      setBusyId(null)
    }
  }

  const rowFullyConnected = (row: IntegrationRow) =>
    agents.length > 0 && agents.every((agent) => row.byAgent[agent]?.state === 'connected')

  /** Any cell on this row is OAuth-pending — server installed but token not
   *  exchanged. Distinct from "missing": skip the Install button, go straight
   *  to the Complete-auth runbook. */
  const rowNeedsAuth = (row: IntegrationRow) =>
    agents.some((agent) => row.byAgent[agent]?.state === 'needs_auth')

  /** Browse uses the credential (gh / lark-cli) — MCP need not be configured. */
  const rowHasBrowse = (row: IntegrationRow) =>
    BROWSABLE.has(row.id) && agents.some((agent) => row.byAgent[agent]?.credentialPresent)

  /** Install spec is per-integration; pick from any agent row (all the same). */
  const installFor = (row: IntegrationRow): IntegrationInstall | undefined =>
    agents.map((agent) => row.byAgent[agent]?.install).find((spec) => spec !== undefined)

  const featuredSummary = {
    connected: featuredRows.filter((row) => rowFullyConnected(row)).length,
    available: featuredRows.filter((row) => !rowFullyConnected(row)).length,
  }

  const renderRowActions = (row: IntegrationRow) => (
    <>
      {rowNeedsAuth(row) ? (
        <button
          type="button"
          className="agent-matrix__setup is-needs-auth"
          disabled={busyId === row.id}
          onClick={() => handleCompleteAuth(row.id)}
          title={t('integrations.finishOauth')}
          aria-label={`${t('integrations.completeAuth')} ${row.name}`}
        >
          {busyId === row.id ? t('integrations.openingBrowser') : t('integrations.completeAuth')}
        </button>
      ) : (
        !rowFullyConnected(row) &&
        (() => {
          const install = installFor(row)
          if (install?.kind === 'claudePlugin' || install?.kind === 'remoteHttp') {
            return (
              <button
                type="button"
                className="agent-matrix__install"
                disabled={busyId === row.id}
                onClick={() => handleInstall(row.id)}
                title={install.kind === 'remoteHttp'
                  ? t('integrations.oneClickInstallRemote')
                  : t('integrations.oneClickInstall')}
                aria-label={`${t('integrations.install')} ${row.name}`}
              >
                {busyId === row.id ? '...' : t('integrations.install')}
              </button>
            )
          }
          if (install?.kind === 'localStdio') {
            const needsCredentials = install.envKeys.includes('CREDENTIALS_PATH')
            return (
              <button
                type="button"
                className="agent-matrix__install"
                disabled={busyId === row.id}
                onClick={() => handleConnectLocalStdio(row.id, install)}
                title={needsCredentials ? t('integrations.connectOAuthHint') : t('integrations.oneClickInstall')}
                aria-label={`${t('integrations.connect')} ${row.name}`}
              >
                {busyId === row.id ? '...' : t('integrations.connect')}
              </button>
            )
          }
          return (
            <button
              type="button"
              className="agent-matrix__setup"
              disabled={busyId === row.id}
              onClick={() => handleSetup(row.id)}
              aria-label={`${t('common.setUp')} ${row.name}`}
            >
              {busyId === row.id ? '...' : t('common.setUp')}
            </button>
          )
        })()
      )}
      {rowHasBrowse(row) && (
        <button
          type="button"
          className="agent-matrix__browse"
          onClick={() => setBrowsingId(row.id as 'github' | 'lark')}
          title={t('integrations.browseItems', { name: row.name })}
        >
          {t('integrations.browse')}
        </button>
      )}
    </>
  )

  const renderIntegrationCard = (row: IntegrationRow) => {
    const connected = rowFullyConnected(row)
    const descriptionKey = INTEGRATION_DESCRIPTION_KEY[row.id]
    return (
      <article key={row.id} className={`agent-matrix__card${connected ? ' is-connected' : ''}`}>
        <span className="agent-matrix__card-mark" aria-hidden>
          <img src={INTEGRATION_ICON[row.id]} alt="" />
        </span>
        <div className="agent-matrix__card-copy">
          <header className="agent-matrix__card-head">
            <h3>{row.name}</h3>
          </header>
          <p>{descriptionKey ? t(descriptionKey) : row.name}</p>
          <div className="agent-matrix__card-agents">
            {agents.map((agent) => {
              const cell = row.byAgent[agent]
              const state: IntegrationConnState = cell?.state ?? 'missing'
              return (
                <span key={agent} className={`agent-matrix__agent-state is-${state}`} title={cell?.evidence}>
                  <i className={`agent-matrix__conn-dot is-${state}`} aria-hidden />
                  {AGENT_LABEL[agent] ?? agent} · {stateLabel(state, t)}
                </span>
              )
            })}
          </div>
        </div>
        <div className="agent-matrix__card-actions">{renderRowActions(row)}</div>
      </article>
    )
  }

  return (
    <section className="agent-matrix" aria-label={t('integrations.agentMatrix')}>
      {/* localStdio Connect: hidden picker for the OAuth client credentials.json. */}
      <input
        ref={fileInputRef}
        type="file"
        accept="application/json,.json"
        style={{ display: 'none' }}
        onChange={(event) => {
          const file = event.target.files?.[0]
          event.target.value = '' // allow re-picking the same file
          if (file) void onCredentialsFileChosen(file)
        }}
      />
      <div className="agent-matrix__toolbar">
        <span>
          {scan
            ? t('integrations.statusSummary', {
                connected: featuredSummary.connected,
                available: featuredSummary.available,
              })
            : t('integrations.scanning')}
        </span>
        <button type="button" className="agent-matrix__rescan" disabled={loading} onClick={load}>
          <RefreshCw size={13} aria-hidden /> {loading ? t('integrations.scanning') : t('integrations.rescan')}
        </button>
      </div>

      {error && <p className="agent-matrix__error">{error}</p>}

      {scan && featuredRows.length > 0 && (
        <div className="agent-matrix__cards">
          {featuredRows.map((row) => renderIntegrationCard(row))}
        </div>
      )}

      {authNotice && (
        <Notice
          tone="warning"
          placement="panel"
          icon={<Sparkles size={13} />}
          onDismiss={() => setAuthNotice(null)}
          className="agent-matrix__auth-notice"
        >
          <span>{authNotice.message}</span>
          {authNotice.authUrl && (
            <a
              href={authNotice.authUrl}
              target="_blank"
              rel="noreferrer noopener"
              className="agent-matrix__auth-link"
            >
              {t('integrations.openAuthPage')}
            </a>
          )}
        </Notice>
      )}

      {browsingId && (
        <div className="agent-matrix__browse-panel">
          <div className="agent-matrix__browse-header">
            <strong>{t('integrations.browse')} {browsingId}</strong>
            <button
              type="button"
              onClick={() => setBrowsingId(null)}
              aria-label={t('integrations.closeBrowse')}
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
          <div className="agent-matrix__runbook" role="dialog" aria-modal="true" aria-label={t('integrations.installResult')}>
            <button
              type="button"
              className="agent-matrix__runbook-close"
              onClick={() => setInstallResult(null)}
              aria-label={t('integrations.closeInstallResult')}
            >
              <X size={15} aria-hidden />
            </button>
            {/* ui-simplification: post-install modal carries execution-result only.
             *  Per-agent status + raw server messages move under <details>; the
             *  canvas-picker + planner-proposal sub-flow is gone — governance now
             *  lives at its own entry (PlannerAgentChatPanel in the canvas dock). */}
            <h3 style={{ marginBottom: 4 }}>
              {t('integrations.installed', { id: installResult.integrationId })}
            </h3>
            <p style={{ margin: '0 0 12px', fontSize: 12, color: 'var(--text-dim)' }}>
              {t('integrations.installedSubtitle')}
            </p>

            <div className="agent-matrix__install-actions" style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 12 }}>
              {canvasList && canvasList.activeCanvasId && installResult.claudeOK && (
                <button
                  type="button"
                  className="agent-matrix__install"
                  onClick={() => {
                    if (onJumpToCanvas && canvasList.activeCanvasId) {
                      onJumpToCanvas(canvasList.activeCanvasId)
                    }
                    setInstallResult(null)
                  }}
                >
                  {t('integrations.tryInCanvas')}
                </button>
              )}
              {canvasList && canvasList.activeCanvasId && installResult.claudeOK && (
                <button
                  type="button"
                  className="agent-matrix__governance-link"
                  style={{
                    background: 'transparent',
                    border: 'none',
                    padding: 0,
                    fontSize: 12,
                    color: 'var(--text-dim)',
                    cursor: 'pointer',
                    textDecoration: 'underline',
                  }}
                  onClick={() => {
                    // Demoted entry point: route the user back to the canvas
                    // where PlannerAgentChatPanel lives, so the "ask governance
                    // agent" intent is handled by the regular chat dock and not
                    // by an inline proposal sub-flow inside this modal.
                    if (onJumpToCanvas && canvasList.activeCanvasId) {
                      onJumpToCanvas(canvasList.activeCanvasId)
                    }
                    setInstallResult(null)
                  }}
                >
                  {t('integrations.askGovernanceAgent')}
                </button>
              )}
            </div>

            <details style={{ marginTop: 16, fontSize: 12, color: 'var(--text-dim)' }}>
              <summary style={{ cursor: 'pointer', userSelect: 'none' }}>
                {t('integrations.advancedDetails')}
              </summary>
              <div style={{ marginTop: 8 }}>
                <div style={{ marginBottom: 6, color: 'var(--text-faint)' }}>
                  {t('integrations.perAgentResult')}: Claude {installResult.claudeOK ? '✓' : '✗'} · Codex {installResult.codexOK ? '✓' : '✗'}
                </div>
                {installResult.messages.length > 0 && (
                  <ul style={{ margin: 0, paddingLeft: 18, lineHeight: 1.55 }}>
                    {installResult.messages.map((msg, idx) => (<li key={idx}>{msg}</li>))}
                  </ul>
                )}
              </div>
            </details>
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
          <div className="agent-matrix__runbook" role="dialog" aria-modal="true" aria-label={t('integrations.connectRunbook')}>
            <button
              type="button"
              className="agent-matrix__runbook-close"
              onClick={() => setRunbook(null)}
              aria-label={t('integrations.closeRunbook')}
            >
              <X size={15} aria-hidden />
            </button>
            <h3>{t('integrations.runbookTitle', { id: runbook.integrationId })}</h3>
            <p className="agent-matrix__runbook-path">
              {t('integrations.generated')}<code>{runbook.path}</code>
            </p>
            <pre className="agent-matrix__runbook-content">{runbook.content}</pre>
            <div className="agent-matrix__dispatch">
              <span>{t('integrations.dispatch')}</span>
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

function stateLabel(state: IntegrationConnState, t: ReturnType<typeof useI18n>['t']): string {
  switch (state) {
    case 'connected':
      return t('integrations.connected')
    case 'partial':
      return t('integrations.partial')
    case 'needs_auth':
      return t('integrations.needsAuth')
    case 'missing':
      return t('integrations.missing')
  }
}
