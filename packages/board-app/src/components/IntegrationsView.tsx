import {
  BookOpenText,
  CheckCircle2,
  GitPullRequest,
  KeyRound,
  MessageSquareText,
  ShieldCheck,
} from 'lucide-react'
import type { CSSProperties } from 'react'
import { useEffect, useState } from 'react'
import { fetchIntegrationStatus } from '../api'
import type { BoardState, IntegrationId, IntegrationStatus } from '../types'
import { IntegrationArtifactPicker } from './IntegrationArtifactPicker'

interface Props {
  state: BoardState | null
}

interface IntegrationCard {
  id: IntegrationId
  name: string
  accent: string
  description: string
  scopes: string[]
  signals: string[]
  Icon: typeof GitPullRequest
}

const CARDS: IntegrationCard[] = [
  {
    id: 'github',
    name: 'GitHub',
    accent: '#D6D2CA',
    description: 'Browse PRs, commits and checks as explicit node output sources',
    scopes: ['Repository', 'Pull requests', 'CI checks'],
    signals: ['artifact: impl-pr', 'artifact: main-merge', 'event: check-result'],
    Icon: GitPullRequest,
  },
  {
    id: 'lark',
    name: 'Lark',
    accent: '#8BA9C2',
    description: 'Browse docs and meeting records as explicit node output sources',
    scopes: ['Wiki / Docs', 'Meetings', 'Approval notes'],
    signals: ['artifact: idea-draft', 'artifact: prd', 'gate: sign-off'],
    Icon: MessageSquareText,
  },
]

export function IntegrationsView(_props: Props) {
  const [statuses, setStatuses] = useState<IntegrationStatus[] | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [openProvider, setOpenProvider] = useState<IntegrationId | null>(null)
  // U7 — bump to re-probe connection status after the user runs `ccops set`.
  const [reloadKey, setReloadKey] = useState(0)

  useEffect(() => {
    let cancelled = false
    setStatuses(null)
    setLoadError(null)
    fetchIntegrationStatus()
      .then((res) => {
        if (!cancelled) setStatuses(res.integrations)
      })
      .catch((err: unknown) => {
        if (!cancelled) setLoadError(err instanceof Error ? err.message : 'Failed to load status')
      })
    return () => {
      cancelled = true
    }
  }, [reloadKey])

  const statusById = (id: IntegrationId): IntegrationStatus | null =>
    statuses?.find((item) => item.id === id) ?? null

  return (
    <section className="integrations-view" aria-label="Integrations">
      <header className="integrations-view__header">
        <div>
          <span>Integrations</span>
          <h1>External systems</h1>
        </div>
        <div className="integrations-view__summary">
          <ShieldCheck size={14} aria-hidden />
          Explicit binding only
        </div>
      </header>

      {loadError && <p className="integration-picker__error">{loadError}</p>}

      <div className="integrations-view__grid">
        {CARDS.map((card) => (
          <IntegrationCardView
            key={card.id}
            card={card}
            status={statusById(card.id)}
            loading={statuses === null && loadError === null}
            open={openProvider === card.id}
            onToggle={() =>
              setOpenProvider((current) => (current === card.id ? null : card.id))
            }
            onRecheck={() => setReloadKey((key) => key + 1)}
          />
        ))}
      </div>

      <section className="integrations-view__contract">
        <div>
          <KeyRound size={15} aria-hidden />
          <strong>Runtime boundary</strong>
        </div>
        <p>
          Integrations are not new Planner node types. They provide readable output sources only.
          To use GitHub or Lark in a workflow, open a node, go to Evidence, and add the selected
          item as output. Existing sessions are never auto-linked to nodes.
        </p>
      </section>
    </section>
  )
}

function IntegrationCardView({
  card,
  status,
  loading,
  open,
  onToggle,
  onRecheck,
}: {
  card: IntegrationCard
  status: IntegrationStatus | null
  loading: boolean
  open: boolean
  onToggle: () => void
  onRecheck: () => void
}) {
  const Icon = card.Icon
  const connected = status?.connected ?? false
  const statusLabel = loading ? 'Checking…' : connected ? 'Connected' : 'Setup needed'

  return (
    <article
      className="integration-card"
      style={{ '--integration-accent': card.accent } as CSSProperties}
    >
      <div className="integration-card__top">
        <div className="integration-card__icon">
          <Icon size={19} aria-hidden />
        </div>
        <div>
          <h2>{card.name}</h2>
          <p>{card.description}</p>
        </div>
        <span className={`integration-card__status is-${connected ? 'ready' : 'not-configured'}`}>
          {statusLabel}
        </span>
      </div>

      <div className="integration-card__section">
        <span>Access</span>
        <div className="integration-card__chips">
          {card.scopes.map((scope) => (
            <em key={scope}>{scope}</em>
          ))}
        </div>
      </div>

      <div className="integration-card__section">
        <span>Planner signals</span>
        <div className="integration-card__signals">
          {card.signals.map((signal) => (
            <div key={signal}>
              <BookOpenText size={12} aria-hidden />
              {signal}
            </div>
          ))}
        </div>
      </div>

      {/* U7 — Configure: when not connected, surface the exact auth step
          (GitHub = ccops token, Lark = install lark-cli) + a re-check. */}
      {!connected && status?.reason && (
        <div className="integration-card__configure">
          <span className="integration-card__configure-label">
            <KeyRound size={12} aria-hidden /> Configure
          </span>
          <code>{status.reason}</code>
          <p className="integration-card__configure-hint">
            {card.id === 'github'
              ? 'Run the command above in a terminal, then re-check.'
              : 'Install / sign in to lark-cli, then re-check.'}
          </p>
        </div>
      )}

      <div className="integration-card__footer">
        <div>
          {connected ? <CheckCircle2 size={13} aria-hidden /> : <KeyRound size={13} aria-hidden />}
          {connected ? 'Available to meee2 AI' : 'Connection required'}
        </div>
        <div className="integration-card__footer-actions">
          {!connected && (
            <button type="button" onClick={onRecheck} disabled={loading}>
              {loading ? 'Checking…' : 'Re-check'}
            </button>
          )}
          <button type="button" onClick={onToggle} disabled={loading || !connected}>
            {open ? 'Hide' : 'Browse'}
          </button>
        </div>
      </div>

      {open && connected && (
        <div className="integration-card__panel">
          <IntegrationArtifactPicker provider={card.id} onClose={onToggle} />
        </div>
      )}
    </article>
  )
}
