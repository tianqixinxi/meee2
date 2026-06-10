import { RefreshCw, Sparkles, X } from 'lucide-react'
import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  completeIntegrationAuth,
  fetchAgentScan,
  fetchCanvases,
  generateIntegrationRunbook,
  installIntegration,
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
import { ALL_INTEGRATION_VIEW_SCHEMAS } from '../integrations/viewSchemas'

/** Integrations whose backend exposes a browse endpoint (PRs / docs / …). */
const BROWSABLE: ReadonlySet<string> = new Set(['github', 'lark'])

/** PRD §1 — the 8 "Featured" integrations meee2 catalog知道 + 给一等公民待遇。
 *  其余 ~500 个来自 Claude plugin marketplace 全量扫描,折到「Other」抽屉。 */
const FEATURED_INTEGRATION_IDS: ReadonlySet<string> = new Set([
  'github', 'linear', 'slack', 'notion',
  'figma', 'supabase', 'sentry', 'postgres',
  'google-sheets',
])

/** 哪些 integrationId 已经有 canvas view-schema(可拖进 canvas 用),
 *  动态读自 chunk I 的 registry,确保跟视图层一致。 */
const HAS_VIEW_SCHEMA: ReadonlySet<string> = new Set(
  ALL_INTEGRATION_VIEW_SCHEMAS.map((s) => s.integrationId),
)

const AGENT_LABEL: Record<string, string> = {
  'claude-code': 'Claude Code',
  codex: 'Codex',
}

/** Server categories are raw English tokens (devtools / communication / …).
 *  Map known buckets to localized labels; unknown categories fall back to the
 *  raw key so new connectors aren't blocked on translation. */
const CATEGORY_LABEL_KEY: Record<string, TranslationKey> = {
  devtools: 'integrations.category.devtools',
  communication: 'integrations.category.communication',
  data: 'integrations.category.data',
  design: 'integrations.category.design',
  observability: 'integrations.category.observability',
  productivity: 'integrations.category.productivity',
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
  const [searchQuery, setSearchQuery] = useState('')
  const [categoryFilter, setCategoryFilter] = useState<string | null>(null)
  const [canvasList, setCanvasList] = useState<CanvasList | null>(null)
  /** Transient toast for the one-click "Complete auth" flow — shows
   *  "Browser opening…" + fallback link, auto-clears once a re-scan flips
   *  the row to `connected`. */
  const [authToast, setAuthToast] = useState<
    { id: string; message: string; authUrl?: string | null } | null
  >(null)
  /** PRD §1 Featured/Other 分组:Other 默认折叠(514 个 connector 视觉太重)。 */
  const [otherCollapsed, setOtherCollapsed] = useState(true)

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

  /** Category histogram for the filter chips. */
  const categoryCounts = useMemo(() => {
    const counts = new Map<string, number>()
    for (const row of rows) counts.set(row.category, (counts.get(row.category) ?? 0) + 1)
    return [...counts.entries()].sort((a, b) => b[1] - a[1])
  }, [rows])

  /** Filtered + search-narrowed rows actually rendered in the table. */
  const visibleRows = useMemo(() => {
    const q = searchQuery.trim().toLowerCase()
    return rows.filter((row) => {
      if (categoryFilter && row.category !== categoryFilter) return false
      if (q && !row.name.toLowerCase().includes(q) && !row.id.toLowerCase().includes(q)) return false
      return true
    })
  }, [rows, searchQuery, categoryFilter])

  /** PRD §1 split: 8 个 meee2-catalog 主 integration 进 Featured,
   *  其余 ~500 个 plugin-marketplace 自动扫到的进 Other。 */
  const { featuredRows, otherRows } = useMemo(() => {
    const featured = visibleRows.filter((r) => FEATURED_INTEGRATION_IDS.has(r.id))
    const other = visibleRows.filter((r) => !FEATURED_INTEGRATION_IDS.has(r.id))
    // Featured 区按 PRD 顺序排,而不是字母序 / category 序
    const order = ['github', 'linear', 'slack', 'notion', 'figma', 'supabase', 'sentry', 'postgres', 'google-sheets']
    featured.sort((a, b) => order.indexOf(a.id) - order.indexOf(b.id))
    return { featuredRows: featured, otherRows: other }
  }, [visibleRows])

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
    setAuthToast(null)
    completeIntegrationAuth(id)
      .then((result) => {
        setAuthToast({ id, message: result.message, authUrl: result.authUrl })
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
                setAuthToast({ id, message: `${id} ${t('integrations.connected').toLowerCase()}.` })
                setTimeout(() => setAuthToast(null), 4000)
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

  /** PRD §1 — row JSX 提到一个 helper,Featured 区和 Other 区都用同一份。 */
  const renderIntegrationRow = (row: IntegrationRow) => {
    const hasViewSchema = HAS_VIEW_SCHEMA.has(row.id)
    return (
      <tr key={row.id}>
        <td className="agent-matrix__name">
          {row.name}
          {hasViewSchema && (
            <span
              className="agent-matrix__view-schema-badge"
              title={t('integrations.canvasReadyTooltip')}
              aria-label={t('integrations.canvasReadyAria')}
            >
              <span className="agent-matrix__view-schema-dot" aria-hidden />
              {t('integrations.canvasReady')}
            </span>
          )}
          <em>{row.category}</em>
        </td>
        {agents.map((agent) => {
          const cell = row.byAgent[agent]
          const state: IntegrationConnState = cell?.state ?? 'missing'
          return (
            <td key={agent} className={`agent-matrix__cell is-${state}`} title={cell?.evidence}>
              <span className={`agent-matrix__conn-dot is-${state}`} aria-hidden /> {stateLabel(state, t)}
            </td>
          )
        })}
        <td className="agent-matrix__action">
          {rowNeedsAuth(row) ? (
            <button
              type="button"
              className="agent-matrix__setup is-needs-auth"
              disabled={busyId === row.id}
              onClick={() => handleCompleteAuth(row.id)}
              title={t('integrations.finishOauth')}
            >
              {busyId === row.id ? t('integrations.openingBrowser') : t('integrations.completeAuth')}
            </button>
          ) : (
            !rowFullyConnected(row) &&
            (() => {
              const install = installFor(row)
              if (install?.kind === 'claudePlugin') {
                return (
                  <button
                    type="button"
                    className="agent-matrix__install"
                    disabled={busyId === row.id}
                    onClick={() => handleInstall(row.id)}
                    title={t('integrations.oneClickInstall')}
                  >
                    {busyId === row.id ? '...' : t('integrations.install')}
                  </button>
                )
              }
              if (install?.kind === 'remoteHttp') {
                return (
                  <button
                    type="button"
                    className="agent-matrix__install"
                    disabled={busyId === row.id}
                    onClick={() => handleInstall(row.id)}
                    title={t('integrations.oneClickInstallRemote')}
                  >
                    {busyId === row.id ? '...' : t('integrations.install')}
                  </button>
                )
              }
              if (install?.kind === 'unsupported') {
                return (
                  <button type="button" className="agent-matrix__setup" disabled title={install.reason}>
                    {t('integrations.unsupported')}
                  </button>
                )
              }
              return (
                <button
                  type="button"
                  className="agent-matrix__setup"
                  disabled={busyId === row.id}
                  onClick={() => handleSetup(row.id)}
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
        </td>
      </tr>
    )
  }

  return (
    <section className="agent-matrix" aria-label={t('integrations.agentMatrix')}>
      <header className="agent-matrix__header">
        <div>
          <span>{t('integrations.agentKicker')}</span>
          <h2>{t('integrations.localHealth')}</h2>
        </div>
        <button type="button" className="agent-matrix__rescan" disabled={loading} onClick={load}>
          <RefreshCw size={13} aria-hidden /> {loading ? t('integrations.scanning') : t('integrations.rescan')}
        </button>
      </header>

      {error && <p className="agent-matrix__error">{error}</p>}

      {/* PRD §1 — Featured 区(8 个 meee2 一等公民 integration)+ Other 抽屉。
       *  visibleRows 仍是搜索/分类后的全集,这里只是按 FEATURED_INTEGRATION_IDS 切两段。
       *  ui-simplification: 搜索/分类/计数条只在 Other 抽屉里出现 ——
       *  Featured 固定 8 行一眼能看完,不需要数据库式浏览语言。 */}
      {scan && (featuredRows.length > 0 || otherRows.length > 0) && (
        <>
          {featuredRows.length > 0 && (
            <section className="agent-matrix__section">
              <header className="agent-matrix__section-head">
                <Sparkles size={13} aria-hidden />
                <strong>{t('integrations.featuredTitle')}</strong>
                <span className="agent-matrix__section-hint">
                  {t('integrations.featuredHint')}
                </span>
              </header>
              <table className="agent-matrix__table">
                <thead>
                  <tr>
                    <th>{t('integrations.integration')}</th>
                    {agents.map((agent) => (
                      <th key={agent}>{AGENT_LABEL[agent] ?? agent}</th>
                    ))}
                    <th aria-label={t('integrations.actions')} />
                  </tr>
                </thead>
                <tbody>{featuredRows.map((row) => renderIntegrationRow(row))}</tbody>
              </table>
            </section>
          )}

          {otherRows.length > 0 && (
            <section className="agent-matrix__section">
              <header className="agent-matrix__section-head">
                <button
                  type="button"
                  className="agent-matrix__section-toggle"
                  onClick={() => setOtherCollapsed((v) => !v)}
                  aria-expanded={!otherCollapsed}
                >
                  <strong>{t('integrations.otherTitle')}</strong>
                  <span className="muted">({otherRows.length})</span>
                  <span aria-hidden>{otherCollapsed ? '▾' : '▴'}</span>
                </button>
                <span className="agent-matrix__section-hint">
                  {t('integrations.otherHint')}
                </span>
              </header>
              {!otherCollapsed && (
                <>
                  <div className="agent-matrix__filters">
                    <input
                      type="search"
                      className="agent-matrix__search"
                      placeholder={t('integrations.searchPlaceholder')}
                      value={searchQuery}
                      onChange={(event) => setSearchQuery(event.target.value)}
                    />
                    <div className="agent-matrix__categories" role="group" aria-label={t('integrations.categoryFilter')}>
                      <button
                        type="button"
                        className={categoryFilter === null ? 'is-active' : ''}
                        onClick={() => setCategoryFilter(null)}
                      >
                        {t('artifacts.filterAll')} ({rows.length})
                      </button>
                      {categoryCounts.map(([cat, count]) => (
                        <button
                          key={cat}
                          type="button"
                          className={categoryFilter === cat ? 'is-active' : ''}
                          onClick={() => setCategoryFilter(cat === categoryFilter ? null : cat)}
                        >
                          {CATEGORY_LABEL_KEY[cat] ? t(CATEGORY_LABEL_KEY[cat]) : cat} ({count})
                        </button>
                      ))}
                    </div>
                  </div>
                  <table className="agent-matrix__table">
                    <thead>
                      <tr>
                        <th>{t('integrations.integration')}</th>
                        {agents.map((agent) => (
                          <th key={agent}>{AGENT_LABEL[agent] ?? agent}</th>
                        ))}
                        <th aria-label={t('integrations.actions')} />
                      </tr>
                    </thead>
                    <tbody>{otherRows.map((row) => renderIntegrationRow(row))}</tbody>
                  </table>
                </>
              )}
            </section>
          )}
        </>
      )}

      {authToast && (
        <div className="agent-matrix__auth-toast" role="status">
          <Sparkles size={13} aria-hidden />
          <span>{authToast.message}</span>
          {authToast.authUrl && (
            <a
              href={authToast.authUrl}
              target="_blank"
              rel="noreferrer noopener"
              className="agent-matrix__auth-link"
            >
              {t('integrations.openAuthPage')}
            </a>
          )}
          <button
            type="button"
            className="agent-matrix__auth-dismiss"
            onClick={() => setAuthToast(null)}
            aria-label={t('integrations.dismiss')}
          >
            <X size={11} aria-hidden />
          </button>
        </div>
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
