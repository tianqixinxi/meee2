import { render, screen, within } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { I18nProvider } from '../lib/i18n'
import type { AgentIntegrationStatus } from '../types'
import { AgentIntegrationMatrix } from './AgentIntegrationMatrix'

const apiMocks = vi.hoisted(() => ({
  fetchAgentScan: vi.fn(),
  fetchCanvases: vi.fn(),
}))

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return {
    ...actual,
    fetchAgentScan: apiMocks.fetchAgentScan,
    fetchCanvases: apiMocks.fetchCanvases,
  }
})

function status(
  agent: string,
  integrationId: string,
  integrationName: string,
  state: AgentIntegrationStatus['state'],
): AgentIntegrationStatus {
  return {
    agent,
    integrationId,
    integrationName,
    category: integrationId === 'github' ? 'devtools' : 'productivity',
    state,
    mcpConfigured: state === 'connected',
    credentialPresent: state === 'connected',
    via: [],
    evidence: `${agent} ${state}`,
    install: { kind: 'remoteHttp', url: `https://example.com/${integrationId}` },
  }
}

describe('AgentIntegrationMatrix', () => {
  beforeEach(() => {
    apiMocks.fetchCanvases.mockResolvedValue({ canvases: [], activeCanvasId: null })
    apiMocks.fetchAgentScan.mockResolvedValue({
      agents: ['claude-code', 'codex'],
      statuses: [
        status('claude-code', 'github', 'GitHub', 'connected'),
        status('codex', 'github', 'GitHub', 'connected'),
        status('claude-code', 'lark', 'Lark', 'missing'),
        status('codex', 'lark', 'Lark', 'missing'),
        status('claude-code', 'calendar', 'Calendar', 'missing'),
        status('codex', 'calendar', 'Calendar', 'missing'),
      ],
    })
  })

  it('renders a compact integration directory without canvas implementation labels', async () => {
    render(
      <I18nProvider>
        <AgentIntegrationMatrix />
      </I18nProvider>,
    )

    expect(await screen.findByText('1 connected · 1 available to connect')).toBeInTheDocument()

    const cards = screen.getAllByRole('article')
    expect(cards).toHaveLength(2)
    expect(document.querySelectorAll('.agent-matrix__card-mark img')).toHaveLength(2)
    expect(within(cards[0]).getByRole('heading', { name: 'GitHub' })).toBeInTheDocument()
    expect(within(cards[0]).getByText('Pull requests, issues, checks, and repositories')).toBeInTheDocument()
    expect(within(cards[0]).getByText('Claude Code · Connected')).toBeInTheDocument()
    expect(within(cards[0]).getByText('Codex · Connected')).toBeInTheDocument()
    expect(within(cards[1]).getByRole('heading', { name: 'Lark' })).toBeInTheDocument()
    expect(screen.queryByText('Canvas view')).not.toBeInTheDocument()
    expect(screen.queryByText('Usable in the canvas')).not.toBeInTheDocument()
    expect(screen.queryByText('Agent-session only')).not.toBeInTheDocument()
    expect(screen.queryByText('Calendar')).not.toBeInTheDocument()
  })
})
