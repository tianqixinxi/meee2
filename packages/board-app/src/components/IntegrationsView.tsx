import { BookOpenText, CheckCircle2, GitPullRequest, KeyRound, MessageSquareText, ShieldCheck } from 'lucide-react'
import type { CSSProperties } from 'react'
import type { BoardState } from '../types'

interface Props {
  state: BoardState | null
}

type IntegrationStatus = 'ready' | 'not-configured'

interface IntegrationCard {
  id: string
  name: string
  status: IntegrationStatus
  accent: string
  description: string
  scopes: string[]
  signals: string[]
  Icon: typeof GitPullRequest
}

export function IntegrationsView({ state }: Props) {
  const plugins = new Set((state?.sessions ?? []).map((session) => session.pluginId.toLowerCase()))
  const githubReady = [...plugins].some((plugin) => plugin.includes('github'))
  const larkReady = [...plugins].some((plugin) => plugin.includes('lark') || plugin.includes('feishu'))

  const cards: IntegrationCard[] = [
    {
      id: 'github',
      name: 'GitHub',
      status: githubReady ? 'ready' : 'not-configured',
      accent: '#D6D2CA',
      description: 'PRs, commits, checks, releases',
      scopes: ['Repository', 'Pull requests', 'CI checks'],
      signals: ['artifact: impl-pr', 'artifact: main-merge', 'event: check-result'],
      Icon: GitPullRequest,
    },
    {
      id: 'lark',
      name: 'Lark',
      status: larkReady ? 'ready' : 'not-configured',
      accent: '#8BA9C2',
      description: 'Docs, meetings, sign-off records',
      scopes: ['Wiki / Docs', 'Meetings', 'Approval notes'],
      signals: ['artifact: idea-draft', 'artifact: prd', 'gate: sign-off'],
      Icon: MessageSquareText,
    },
  ]

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

      <div className="integrations-view__grid">
        {cards.map((card) => (
          <IntegrationCardView key={card.id} card={card} />
        ))}
      </div>

      <section className="integrations-view__contract">
        <div>
          <KeyRound size={15} aria-hidden />
          <strong>Runtime boundary</strong>
        </div>
        <p>Integrations provide readable artifacts and dispatch context. They do not auto-link existing sessions to graph nodes.</p>
      </section>
    </section>
  )
}

function IntegrationCardView({ card }: { card: IntegrationCard }) {
  const Icon = card.Icon
  return (
    <article className="integration-card" style={{ '--integration-accent': card.accent } as CSSProperties}>
      <div className="integration-card__top">
        <div className="integration-card__icon">
          <Icon size={19} aria-hidden />
        </div>
        <div>
          <h2>{card.name}</h2>
          <p>{card.description}</p>
        </div>
        <span className={`integration-card__status is-${card.status}`}>
          {card.status === 'ready' ? 'Detected' : 'Setup needed'}
        </span>
      </div>

      <div className="integration-card__section">
        <span>Access</span>
        <div className="integration-card__chips">
          {card.scopes.map((scope) => <em key={scope}>{scope}</em>)}
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

      <div className="integration-card__footer">
        <div>
          {card.status === 'ready' ? <CheckCircle2 size={13} aria-hidden /> : <KeyRound size={13} aria-hidden />}
          {card.status === 'ready' ? 'Available to meee2 AI' : 'Connection flow next'}
        </div>
        <button type="button" disabled>
          Configure
        </button>
      </div>
    </article>
  )
}
