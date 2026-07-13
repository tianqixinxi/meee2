import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { I18nProvider } from '../lib/i18n'
import {
  invalidateSessionArtifactsCache,
  SessionArtifactsModal,
  type SessionArtifactsModalTarget,
} from './SessionArtifactsModal'

const apiMocks = vi.hoisted(() => ({
  fetchSessionArtifacts: vi.fn(),
  syncNativeSessionsWorkspace: vi.fn(),
}))

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return {
    ...actual,
    fetchSessionArtifacts: apiMocks.fetchSessionArtifacts,
    syncNativeSessionsWorkspace: apiMocks.syncNativeSessionsWorkspace,
  }
})

const target: SessionArtifactsModalTarget = {
  sessionId: 'session-a',
  title: 'Codex - meee2',
  providerResumeSessionId: 'provider-session-a',
  surfaceId: 'surface-a',
  project: '/Users/kai/Code/meee2-workspace/meee2',
  projectName: 'meee2',
}

function renderWithI18n(ui: React.ReactElement) {
  return render(<I18nProvider>{ui}</I18nProvider>)
}

describe('SessionArtifactsModal', () => {
  beforeEach(() => {
    invalidateSessionArtifactsCache()
    apiMocks.fetchSessionArtifacts.mockResolvedValue({
      sessionId: 'session-a',
      artifacts: [],
      totalCount: 0,
    })
    apiMocks.syncNativeSessionsWorkspace.mockReturnValue(true)
  })

  afterEach(() => {
    vi.clearAllMocks()
  })

  it('obscures the native terminal layer while the modal is open and requests restore on close', async () => {
    const relayout = vi.fn()
    const restore = vi.fn()
    window.addEventListener('meee2:layout-native-sessions-workspace', relayout)
    window.addEventListener('meee2:restore-native-sessions-workspace', restore)

    const { unmount } = renderWithI18n(
      <SessionArtifactsModal target={target} onClose={() => {}} />,
    )

    await screen.findByRole('dialog', { name: /Artifacts for Codex - meee2/i })
    await waitFor(() => expect(apiMocks.fetchSessionArtifacts).toHaveBeenCalledWith('session-a'))
    expect(apiMocks.syncNativeSessionsWorkspace).toHaveBeenCalledWith(expect.objectContaining({
      phase: 'obscure',
      mode: 'terminal',
      webPhase: 'sessionArtifactsModal.obscureNativeTerminal',
    }))

    unmount()

    expect(restore).toHaveBeenCalledTimes(1)
    expect(relayout).toHaveBeenCalledTimes(1)
    window.removeEventListener('meee2:layout-native-sessions-workspace', relayout)
    window.removeEventListener('meee2:restore-native-sessions-workspace', restore)
  })

  it('uses a simple Artifacts title and opens the detailed artifacts page', async () => {
    const onOpenDetails = vi.fn()
    renderWithI18n(
      <SessionArtifactsModal target={target} onClose={() => {}} onOpenDetails={onOpenDetails} />,
    )

    await screen.findByRole('heading', { name: 'Artifacts' })
    expect(screen.queryByText(/Artifacts\[/)).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Open details' }))
    expect(onOpenDetails).toHaveBeenCalledWith(target)
  })

  it('reuses a fresh artifact response when the panel is reopened', async () => {
    const first = renderWithI18n(<SessionArtifactsModal target={target} onClose={() => {}} />)
    await screen.findByText('No artifacts match this view.')
    expect(apiMocks.fetchSessionArtifacts).toHaveBeenCalledTimes(1)
    first.unmount()

    renderWithI18n(<SessionArtifactsModal target={target} onClose={() => {}} />)
    expect(screen.getByText('No artifacts match this view.')).toBeInTheDocument()
    expect(screen.queryByText('Gathering artifacts from visible canvases')).not.toBeInTheDocument()
    expect(apiMocks.fetchSessionArtifacts).toHaveBeenCalledTimes(1)
  })

  it('renders only formal artifacts bound to the session', async () => {
    apiMocks.fetchSessionArtifacts.mockResolvedValue({
      sessionId: 'session-a',
      artifacts: [makeArtifact({ title: 'Release report' })],
      totalCount: 1,
    })

    renderWithI18n(<SessionArtifactsModal target={target} onClose={() => {}} />)

    expect(await screen.findByText('Release report')).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Formal Artifacts' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Promote' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Discard' })).not.toBeInTheDocument()
  })
})

function makeArtifact(overrides: Partial<{ id: string; title: string }> = {}) {
  return {
    id: overrides.id ?? 'artifact-1',
    canvasId: 'canvas-a',
    nodeId: 'node-a',
    kind: 'file',
    title: overrides.title ?? 'Release report',
    reference: 'release-report.txt',
    status: 'attached',
    createdAt: '2026-06-18T00:00:01Z',
    payload: { type: 'text', text: 'Generated formal artifact.' },
    typedPayload: { type: 'text', text: 'Generated formal artifact.' },
    reviewStatus: 'approved',
  }
}
